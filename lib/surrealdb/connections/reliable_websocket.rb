# frozen_string_literal: true

module SurrealDB
  module Connections
    # Wraps a WebSocket connection with automatic reconnection.
    #
    # On disconnect, transparently reconnects using the same URL and options,
    # replays state-restoring calls (use, signin, let), re-subscribes live
    # query handlers, and retries the failed request once.
    #
    # Modeled on the Go SDK's contrib/rews (reliable WebSocket).
    class ReliableWebSocket < Base
      # @return [Integer] max reconnection attempts before giving up
      attr_reader :max_retries

      # @return [Float] base delay between reconnection attempts (seconds)
      attr_reader :reconnect_delay

      def initialize(inner, **options)
        super(inner.url, **options)
        @inner = inner
        @max_retries = options.fetch(:reconnect_max_retries, 5)
        @reconnect_delay = options.fetch(:reconnect_delay, 1.0)
        @state_mutex = Mutex.new
        @last_ns = nil
        @last_db = nil
        @last_auth_method = nil
        @last_auth_params = nil
        @variables = {}
        @live_subscriptions = {}
      end

      def connect
        @inner.connect
        @connected = true
      end

      def close
        @inner.close
        @connected = false
      end

      def connected?
        @inner.connected?
      end

      def supports_live_queries?
        true
      end

      def supports_transactions?
        true
      end

      def send_request(method, params = [], session: nil, txn: nil)
        track_state(method, params) if session.nil?
        @inner.send_request(method, params, session: session, txn: txn)
      rescue ConnectionError => e
        reconnect!
        log(:info, "Reconnected after: #{e.message}")
        replay_state
        @inner.send_request(method, params, session: session, txn: txn)
      end

      def session_state(session = nil)
        @inner.session_state(session)
      end

      def attached_sessions
        @inner.attached_sessions
      end

      def on_notification(live_query_id, handler)
        @state_mutex.synchronize { @live_subscriptions[live_query_id] = handler }
        @inner.on_notification(live_query_id, handler)
      end

      def remove_notification_handler(live_query_id)
        @state_mutex.synchronize { @live_subscriptions.delete(live_query_id) }
        @inner.remove_notification_handler(live_query_id)
      end

      private

      def track_state(method, params) # rubocop:disable Metrics/CyclomaticComplexity
        @state_mutex.synchronize do
          case method
          when Protocol::Methods::USE
            @last_ns = params[0]
            @last_db = params[1]
          when Protocol::Methods::SIGNIN
            @last_auth_method = :signin
            @last_auth_params = params
          when Protocol::Methods::SIGNUP
            @last_auth_method = :signup
            @last_auth_params = params
          when Protocol::Methods::AUTHENTICATE
            @last_auth_method = :authenticate
            @last_auth_params = params
          when Protocol::Methods::INVALIDATE
            @last_auth_method = nil
            @last_auth_params = nil
          when Protocol::Methods::LET
            @variables[params[0]] = params[1]
          when Protocol::Methods::UNSET
            @variables.delete(params[0])
          end
        end
      end

      # Attempts to reconnect with exponential backoff.
      # @raise [ConnectionError] if all attempts fail
      def reconnect!
        attempt = 0
        while attempt < @max_retries
          attempt += 1
          delay = @reconnect_delay * (2**(attempt - 1))
          log(:debug, "Reconnection attempt #{attempt}/#{@max_retries} in #{delay}s")
          sleep delay

          begin
            @inner.close
            @inner.connect
            @connected = true
            return
          rescue ConnectionError => e
            log(:warn, "Reconnection attempt #{attempt} failed: #{e.message}")
          end
        end

        @connected = false
        raise ConnectionError, "reconnection failed after #{@max_retries} attempts"
      end

      # Replays tracked state onto the fresh connection.
      def replay_state # rubocop:disable Metrics/CyclomaticComplexity
        ns, db, auth_method, auth_params, vars, live_subs = @state_mutex.synchronize do
          [@last_ns, @last_db, @last_auth_method, @last_auth_params,
           @variables.dup, @live_subscriptions.dup]
        end

        if auth_method && auth_params
          case auth_method
          when :signin then @inner.send_request(Protocol::Methods::SIGNIN, auth_params, session: nil)
          when :signup       then @inner.send_request(Protocol::Methods::SIGNUP, auth_params, session: nil)
          when :authenticate then @inner.send_request(Protocol::Methods::AUTHENTICATE, auth_params, session: nil)
          end
        end

        @inner.send_request(Protocol::Methods::USE, [ns, db], session: nil) if ns && db

        vars.each do |key, value|
          @inner.send_request(Protocol::Methods::LET, [key, value], session: nil)
        end

        live_subs.each do |live_id, handler|
          @inner.on_notification(live_id, handler)
        end
      end

      def log(level, message)
        SurrealDB.configuration.logger&.send(level, message)
      end
    end
  end
end
