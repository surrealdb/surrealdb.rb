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
      include ReliableRestore

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
        # Sessions whose credentials could not be restored, by the generation
        # that lost them.
        @auth_lost = {}
        @on_reconnect = nil
        # Requests between sending and recording their result.
        @delivering = 0
        @delivered = ConditionVariable.new
        @inner.on_disconnect { |reason| reconnect_in_background(reason) } if @inner.respond_to?(:on_disconnect)
      end

      # Connecting again after {#close} restores what the client still holds
      # (sessions, live queries), as a reconnect does: the new connection
      # has none of it.
      def connect
        @reconnect_mutex.synchronize do
          @closed = false
          @inner.connect
          reopened = @opened
          @opened = true
          @connected = true
          if reopened
            check_new_connection
            restore_state
          end
        end
      end

      # Registers a check run on each new connection before anything is
      # restored on it, such as the client's server version check. When it
      # raises, the connection is closed again and the error reaches the
      # request that was waiting for the reconnect.
      # @yield [WebSocket] the new connection, to send the check on
      def on_reconnect(&block)
        @on_reconnect = block
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

      def supports_streaming?
        @inner.supports_streaming?
      end

      def streaming_unavailable!
        @inner.streaming_unavailable!
      end

      # A stream that never started is started on the new connection; one
      # the connection dropped under is not restarted, since its statements
      # may have run.
      def stream_request(method, params = [], session: nil, txn: nil, timeout: nil, &)
        since = generation_seen
        deadline = call_deadline(timeout)
        await_restore(deadline, method)
        begin
          start_stream(method, params, session, txn, since, deadline, &)
        rescue NotConnectedError
          recover(deadline, method)
          start_stream(method, params, session, txn, since, deadline, &)
        end
      rescue NotConnectedError, RequestInterruptedError, AuthenticationError
        raise
      rescue ConnectionError => e
        interrupted!(method, e, deadline)
      end

      def http_endpoint
        @inner.http_endpoint
      end

      # The request goes over HTTP, but renewing the session's token first
      # needs the WebSocket, so it waits for a reconnect like {#send_request}.
      def http_request(verb, path, session: nil, timeout: nil, **, &)
        since = generation_seen
        deadline = call_deadline(timeout)
        recover(deadline, path)
        check_auth_kept(path, session, since)
        begin
          @inner.http_request(verb, path, session: session, **time_left(deadline, path), **, &)
        rescue NotConnectedError # renewing the token; the request was not sent
          recover(deadline, path)
          check_auth_kept(path, session, since)
          @inner.http_request(verb, path, session: session, **time_left(deadline, path), **, &)
        end
      end

      def health(timeout: nil)
        @inner.health(**time_left(call_deadline(timeout), 'health'))
      end

      def session_state(session = nil)
        @inner.session_state(session)
      end

      def attached_sessions
        @inner.attached_sessions
      end

      # A timeout covers waiting for a reconnect as well as the response.
      def send_request(method, params = [], session: nil, txn: nil, timeout: nil)
        since = generation_seen
        deadline = call_deadline(timeout)
        await_restore(deadline, method)
        deliver(method, params, session, txn, since, deadline)
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
      # Neither is sent when a reconnect since the request was made left its
      # session signed out.
      def deliver(method, params, session, txn, since, deadline) # rubocop:disable Metrics/ParameterLists
        transaction = txn || (params[0] if TXN_FINISH.include?(method))
        check_transaction_alive(transaction)
        check_auth_kept(method, session, since)
        attempt(method, params, session, txn, deadline)
      rescue NotConnectedError
        recover(deadline, method)
        check_transaction_alive(transaction)
        check_auth_kept(method, session, since)
        attempt(method, params, session, txn, deadline)
      rescue RequestInterruptedError, AuthenticationError
        raise
      rescue ConnectionError => e
        return ended_with_connection(method, params, session, since, deadline) if ends_with_connection?(method, session)

        interrupted!(method, e, deadline) unless txn.nil? && Protocol::Methods::SAFE_TO_REPEAT.include?(method)
        recover(deadline, method)

        check_auth_kept(method, session, since)
        attempt(method, params, session, txn, deadline)
      end

      # The connection generation a new request belongs to. A request made
      # during a restore belongs to the one before: it was made expecting the
      # state the restore is bringing back.
      def generation_seen
        generation = @generation
        @restoring ? generation - 1 : generation
      end

      # Signing in, out or again needs no previous identity.
      def check_auth_kept(request, session, since)
        return if Base::NO_RENEWAL.include?(request)

        lost = @state_mutex.synchronize { @auth_lost[session] }
        return if lost.nil? || lost <= since

        raise AuthenticationError,
              "#{session ? "session #{session}" : 'the default session'} could not authenticate again after " \
              "the connection was lost, so it is signed out; '#{request}' was not sent"
      end

      def start_stream(method, params, session, txn, since, deadline, &) # rubocop:disable Metrics/ParameterLists
        check_transaction_alive(txn)
        check_auth_kept(method, session, since)
        @inner.stream_request(method, params, session: session, txn: txn, **time_left(deadline, method), &)
      end

      # Sends one request, translating live query ids the caller holds into
      # the ids they have on the current connection.
      def attempt(method, params, session, txn, deadline)
        @state_mutex.synchronize { @delivering += 1 }
        params = [current_live_id(params[0])] + params.drop(1) if method == Protocol::Methods::KILL
        result = @inner.send_request(method, params, session: session, txn: txn, **time_left(deadline, method))
        track_live(method, params, session, result)
        result
      ensure
        @state_mutex.synchronize { @delivered.broadcast if (@delivering -= 1).zero? }
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
        when Protocol::Methods::DETACH then forget_lives(session) if session
        end
      end

      def track_transaction(method, params, result)
        case method
        when Protocol::Methods::BEGIN_TXN
          @state_mutex.synchronize { @transactions[result.to_s] = @generation }
        when *TXN_FINISH
          @state_mutex.synchronize { @transactions.delete(params[0].to_s) }
        end
      end

      # The server ended the session's live queries (reset, detach); drop them and
      # their handlers, which would otherwise never run again but stay
      # reachable, and would be restored into a session that no longer exists.
      def forget_lives(session)
        gone = @state_mutex.synchronize do
          keys = @lives.select { |_, live| live[:session] == session }.keys
          keys.map { |key| @lives.delete(key) }
        end
        gone.each { |live| @inner.remove_notification_handler(live[:current].to_s) }
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

      # Reconnects, waiting no longer than the deadline, and reports the
      # request that was in flight as interrupted.
      def interrupted!(method, error, deadline)
        begin
          recover(deadline, method)
        rescue TimeoutError
          nil # the reconnect carries on in the background
        end
        raise RequestInterruptedError,
              "connection lost while '#{method}' was in flight (#{error.message}); " \
              'it was not sent again because it may already have run'
      end

      def reconnect_in_background(reason)
        return if @closed

        log(:warn, "WebSocket connection lost (#{reason}); reconnecting")
        ensure_connected!
      rescue Error => e
        log(@closed ? :debug : :error, "Reconnection failed: #{e.message}")
      end

      # Reconnects and restores state, once, however many threads notice the
      # drop at the same time.
      def ensure_connected!
        @reconnect_mutex.synchronize do
          return if @inner.connected?
          raise NotConnectedError, 'not connected' if @closed || !@opened

          # Requests wait (see #await_restore) until the new connection is
          # checked and restored, not only while it is being restored.
          @restoring = true
          begin
            reconnect!
            check_new_connection
            restore_state
          ensure
            @restoring = false
          end
          log(:info, 'Reconnected')
        end
      end

      # A request made while a reconnect is restoring sessions would reach a
      # session that is not back yet; wait for the restore to finish.
      def await_restore(deadline, request)
        recover(deadline, request) if @restoring
      end

      # Reconnects and restores state, or waits for the reconnect already
      # under way. A request with a deadline stops waiting at the deadline;
      # the reconnect carries on in the background.
      # @raise [TimeoutError] when the deadline passes first
      def recover(deadline, request)
        return ensure_connected! if deadline.nil?

        worker = Thread.new { ensure_connected! }
        worker.report_on_exception = false
        left = deadline - monotonic_now
        return if worker.join(left.clamp(0, nil))

        raise TimeoutError.new("'#{request}' timed out waiting for the connection to come back", sent: false)
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
    end
  end
end
