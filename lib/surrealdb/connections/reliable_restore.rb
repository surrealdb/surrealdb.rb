# frozen_string_literal: true

module SurrealDB
  module Connections
    # What {ReliableWebSocket} brings back after a reconnect: every session
    # with its namespace, database, variables and credentials, and every
    # live query started with `live`.
    module ReliableRestore
      private

      # Brings the state the server lost back on the new connection. Its
      # transactions are gone, so they belong to the previous generation.
      def restore_state
        @restoring = true
        @generation += 1
        restore_sessions
        restore_live_queries
      ensure
        @restoring = false
      end

      # Runs the check registered with {ReliableWebSocket#on_reconnect}; a
      # connection that fails it is closed again.
      def check_new_connection
        @on_reconnect&.call(@inner)
      rescue StandardError
        @inner.close
        @connected = false
        raise
      end

      # One session failing to restore does not stop the others.
      def restore_sessions
        begin
          restore_session(nil, @inner.session_state(nil))
        rescue ServerError => e
          log(:error, "Could not restore the default session: #{e.message}")
        end
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
        @state_mutex.synchronize { @auth_lost[id] = @generation }
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
