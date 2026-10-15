# frozen_string_literal: true

module SurrealDB
  module Connections
    # Wraps a WebSocket connection with automatic reconnection.
    #
    # When the connection drops, it reconnects with exponential backoff (as
    # soon as the drop is noticed, not only on the next request) and restores
    # what the server lost with it:
    #
    # - every attached session, with its namespace, database, variables and
    #   credentials (re-authenticating with the token, or signing in again
    #   when the token is no longer accepted);
    # - every live query started with {RequestMethods#live}, which is issued
    #   again; notifications keep arriving under the id the caller was given.
    #
    # A request that was never sent is sent once the connection is back. A
    # request that was in flight when the connection dropped may or may not
    # have run, so it is only sent again when that is harmless (reads, `use`,
    # variables, `authenticate`, ...). Queries, writes and anything inside a
    # transaction raise {RequestInterruptedError} instead. Transactions do not
    # survive a reconnect.
    #
    # Live queries started by a LIVE SELECT statement inside {#query} are not
    # tracked and are not restored.
    class ReliableWebSocket < Base
      TXN_FINISH = [Protocol::Methods::COMMIT, Protocol::Methods::CANCEL].freeze

      # @return [Integer] max reconnection attempts before giving up
      attr_reader :max_retries

      # @return [Float] base delay between reconnection attempts (seconds)
      attr_reader :reconnect_delay

      # @return [WebSocket] the wrapped connection
      attr_reader :inner

      def initialize(inner, **options)
        super(inner.url, **options)
        @inner = inner
        @max_retries = options.fetch(:reconnect_max_retries, 5)
        @reconnect_delay = options.fetch(:reconnect_delay, 1.0)
        @reconnect_mutex = Mutex.new
        @closed = false
        @opened = false
        @restoring = false
        # Live queries started with `live`, by the id the caller was given:
        # { params:, session:, current: id on the current connection, handler: }
        @lives = {}
        # Transactions, by id, with the connection generation they began on.
        @generation = 0
        @transactions = {}
        @inner.on_disconnect { |reason| reconnect_in_background(reason) } if @inner.respond_to?(:on_disconnect)
      end

      def connect
        @closed = false
        @inner.connect
        @opened = true
        @connected = true
      end

      def close
        @closed = true
        @inner.close
        @connected = false
      end

      # False while state is being restored after a reconnect.
      def connected?
        @inner.connected? && !@restoring
      end

      def supports_live_queries?
        true
      end

      def supports_transactions?
        true
      end

      def http_endpoint
        @inner.http_endpoint
      end

      def http_request(...)
        @inner.http_request(...)
      end

      def health
        @inner.health
      end

      def session_state(session = nil)
        @inner.session_state(session)
      end

      def attached_sessions
        @inner.attached_sessions
      end

      def send_request(method, params = [], session: nil, txn: nil, timeout: nil)
        await_restore
        deliver(method, params, session, txn, timeout)
      rescue RequestInterruptedError
        # Ending a lost transaction ends our record of it too.
        @state_mutex.synchronize { @transactions.delete(params[0].to_s) } if TXN_FINISH.include?(method)
        raise
      end

      def on_notification(live_query_id, handler)
        key = live_query_id.to_s
        current = @state_mutex.synchronize do
          live = @lives[key]
          live[:handler] = handler if live
          live ? live[:current].to_s : key
        end
        @inner.on_notification(current, relabel(key, handler))
      end

      def remove_notification_handler(live_query_id)
        key = live_query_id.to_s
        current = @state_mutex.synchronize do
          live = @lives[key]
          live&.delete(:handler)
          live ? live[:current].to_s : key
        end
        @inner.remove_notification_handler(current)
      end

      private

      # Sends a request, reconnecting when the connection is gone: a request
      # that never left is sent on the new connection, one that was in flight
      # only when repeating it is harmless.
      def deliver(method, params, session, txn, timeout)
        transaction = txn || (params[0] if TXN_FINISH.include?(method))
        check_transaction_alive(transaction)
        attempt(method, params, session, txn, timeout)
      rescue NotConnectedError
        ensure_connected!
        check_transaction_alive(transaction)
        attempt(method, params, session, txn, timeout)
      rescue RequestInterruptedError
        raise
      rescue ConnectionError => e
        ensure_connected!
        raise_interrupted(method, e) unless txn.nil? && Protocol::Methods::SAFE_TO_REPEAT.include?(method)

        attempt(method, params, session, txn, timeout)
      end

      # Sends one request, translating live query ids the caller holds into
      # the ids they have on the current connection.
      def attempt(method, params, session, txn, timeout)
        params = [current_live_id(params[0])] + params.drop(1) if method == Protocol::Methods::KILL
        result = @inner.send_request(method, params, session: session, txn: txn,
                                                     **(timeout ? { timeout: timeout } : {}))
        track_live(method, params, session, result)
        result
      end

      def track_live(method, params, session, result)
        track_transaction(method, params, result)
        case method
        when Protocol::Methods::LIVE
          @state_mutex.synchronize { @lives[result.to_s] = { params: params, session: session, current: result } }
        when Protocol::Methods::KILL
          id = params[0].to_s
          @state_mutex.synchronize { @lives.delete_if { |_, live| live[:current].to_s == id } }
        when Protocol::Methods::RESET then forget_lives(session)
        end
      end

      # The server killed the session's live queries; drop them and their
      # handlers, which would otherwise never run again but stay reachable.
      def forget_lives(session)
        gone = @state_mutex.synchronize do
          keys = @lives.select { |_, live| live[:session] == session }.keys
          keys.map { |key| @lives.delete(key) }
        end
        gone.each { |live| @inner.remove_notification_handler(live[:current].to_s) }
      end

      def track_transaction(method, params, result)
        case method
        when Protocol::Methods::BEGIN_TXN
          @state_mutex.synchronize { @transactions[result.to_s] = @generation }
        when *TXN_FINISH
          @state_mutex.synchronize { @transactions.delete(params[0].to_s) }
        end
      end

      # A transaction lives on the connection it began on; once that is gone,
      # so is the transaction, and sending its id to the new connection would
      # only get a confusing "Transaction not found".
      def check_transaction_alive(txn)
        return if txn.nil?

        began = @state_mutex.synchronize { @transactions[txn.to_s] }
        return if began.nil? || began == @generation

        raise RequestInterruptedError,
              "the connection dropped, which ended transaction #{txn}; nothing in it was committed"
      end

      def current_live_id(id)
        @state_mutex.synchronize { @lives[id.to_s]&.fetch(:current) } || id
      end

      # Notifications for a re-issued live query arrive under its new id;
      # hand them on under the id the caller was given.
      def relabel(key, handler)
        lambda do |notification|
          notification = notification.merge('id' => Uuid.parse(key)) if notification['id'].to_s != key
          case handler
          when Queue then handler.push(notification)
          when Proc then handler.call(notification)
          end
        end
      end

      def raise_interrupted(method, error)
        raise RequestInterruptedError,
              "connection lost while '#{method}' was in flight (#{error.message}); " \
              'it was not sent again because it may already have run'
      end

      def reconnect_in_background(reason)
        return if @closed

        log(:warn, "WebSocket connection lost (#{reason}); reconnecting")
        ensure_connected!
      rescue ConnectionError => e
        log(@closed ? :debug : :error, "Reconnection failed: #{e.message}")
      end

      # Reconnects and restores state, once, however many threads notice the
      # drop at the same time.
      def ensure_connected!
        @reconnect_mutex.synchronize do
          return if @inner.connected?
          raise NotConnectedError, 'not connected' if @closed || !@opened

          @restoring = true
          begin
            reconnect!
            @generation += 1
            restore_sessions
            restore_live_queries
          ensure
            @restoring = false
          end
          log(:info, 'Reconnected')
        end
      end

      # A request made while a reconnect is restoring sessions would reach a
      # session that is not back yet; wait for the restore to finish.
      def await_restore
        @reconnect_mutex.synchronize { nil } if @restoring
      end

      # @raise [ConnectionError] if all attempts fail
      # @raise [NotConnectedError] if {#close} is called meanwhile
      def reconnect!
        reconnected = @max_retries.times.any? do |i|
          # The first attempt is immediate; later ones back off exponentially.
          delay = i.zero? ? 0 : @reconnect_delay * (2**(i - 1))
          log(:debug, "Reconnection attempt #{i + 1}/#{@max_retries} in #{delay}s")
          sleep delay if delay.positive?
          stop_if_closed
          reconnect_once(i + 1).tap { stop_if_closed }
        end
        @connected = reconnected
        raise ConnectionError, "reconnection failed after #{@max_retries} attempts" unless reconnected
      end

      # {#close} does not wait for a reconnect in progress, so the reconnect
      # checks between steps and drops a socket it opened after the close.
      def stop_if_closed
        return unless @closed

        @inner.close
        @connected = false
        raise NotConnectedError, 'connection closed while reconnecting'
      end

      def reconnect_once(attempt)
        @inner.close
        @inner.connect
        true
      rescue ConnectionError => e
        log(:warn, "Reconnection attempt #{attempt} failed: #{e.message}")
        false
      end

      # One session failing to restore does not stop the others.
      def restore_sessions
        restore_session(nil, @inner.session_state(nil))
        @inner.attached_sessions.each do |id, state|
          @inner.send_request(Protocol::Methods::ATTACH, [], session: id)
          restore_session(id, state)
        rescue ServerError => e
          log(:error, "Could not restore session #{id}: #{e.message}")
        end
      end

      def restore_session(id, state)
        state = state.copy
        restore_auth(id, state)
        @inner.send_request(Protocol::Methods::USE, [state.namespace, state.database], session: id) if
          state.namespace || state.database
        state.variables.each { |key, value| @inner.send_request(Protocol::Methods::LET, [key, value], session: id) }
      end

      # Re-presents the token; when the server no longer accepts it (it
      # expired while we were away), uses the refresh token, or signs in again
      # with the credentials the session last signed in with. A signup is
      # never repeated. A session that cannot authenticate again is left
      # signed out, and the rest of its state is still restored.
      def restore_auth(id, state)
        return unless state.access_token

        @inner.send_request(Protocol::Methods::AUTHENTICATE, [state.access_token], session: id)
      rescue ServerError => e
        return drop_auth(id, e) unless state.renewable?

        log(:info, "Stored token rejected after reconnect (#{e.message}); renewing it")
        renew_auth(id, state)
      end

      def renew_auth(id, state)
        if state.refresh_token
          begin
            return @inner.send_request(Protocol::Methods::REFRESH, [state.tokens], session: id)
          rescue ServerError => e
            return drop_auth(id, e) unless state.signin
          end
        end
        @inner.send_request(*state.signin, session: id)
      rescue ServerError => e
        drop_auth(id, e)
      end

      # Forgets the credentials, so the session state says what the server
      # now has: an unauthenticated session.
      def drop_auth(id, error)
        log(:warn, "#{id ? "Session #{id}" : 'The default session'} could not authenticate again after " \
                   "reconnecting (#{error.message}); it is now signed out")
        @inner.send_request(Protocol::Methods::INVALIDATE, [], session: id)
      end

      def restore_live_queries
        lives = @state_mutex.synchronize { @lives.map { |key, live| [key, live.dup] } }
        lives.each do |key, live|
          @inner.remove_notification_handler(live[:current].to_s)
          fresh = @inner.send_request(Protocol::Methods::LIVE, live[:params], session: live[:session])
          @state_mutex.synchronize { @lives[key][:current] = fresh if @lives.key?(key) }
          @inner.on_notification(fresh.to_s, relabel(key, live[:handler])) if live[:handler]
        rescue ServerError => e
          log(:error, "Could not restore live query #{key}: #{e.message}")
        end
      end
    end
  end
end
