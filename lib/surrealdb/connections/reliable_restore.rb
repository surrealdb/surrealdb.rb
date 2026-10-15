# frozen_string_literal: true

module SurrealDB
  module Connections
    # What {ReliableWebSocket} brings back after a reconnect: every session
    # with its namespace, database, variables and credentials, and every
    # live query started with `live`; and what it must not bring back, as a
    # kill or detach ended it with the connection.
    module ReliableRestore
      # How long a restore waits for requests whose response already arrived
      # to record it (see #await_deliveries).
      DELIVERY_WAIT = 1.0

      private

      # Brings the state the server lost back on the new connection. Its
      # transactions are gone, so they belong to the previous generation.
      def restore_state
        @restoring = true
        await_deliveries
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
        sessions = @state_mutex.synchronize do
          @ending_sessions.clear
          @inner.attached_sessions
        end
        sessions.each do |id, state|
          @inner.send_request(Protocol::Methods::ATTACH, [], session: id)
          begin
            restore_session(id, state)
          ensure
            settle_session(id)
          end
        rescue ServerError => e
          log(:error, "Could not restore session #{id}: #{e.message}")
        end
      end

      # Records the session as attached on this connection, unless a detach
      # the dropped connection ended forgot it meanwhile: then the caller was
      # told it is gone, so it is detached again.
      def settle_session(id)
        ended = @state_mutex.synchronize do
          next true if @ending_sessions.delete?(id)

          @session_generations[id] = @generation
          false
        end
        end_again(Protocol::Methods::DETACH, [], id) if ended
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

      # The handler is read once the fresh id is in place: one registered
      # meanwhile went under the old id, whose handler is dropped. A live
      # query killed meanwhile is killed again (see #kill_lost).
      def restore_live_queries
        lives = @state_mutex.synchronize { @lives.map { |key, live| [key, live.dup] } }
        lives.each do |key, live|
          fresh = @inner.send_request(Protocol::Methods::LIVE, live[:params], session: live[:session])
          killed, handler = @state_mutex.synchronize do
            next [true] unless @lives.key?(key)

            @lives[key].merge!(current: fresh, generation: @generation)
            [false, @lives[key][:handler]]
          end
          @inner.remove_notification_handler(live[:current].to_s)
          next end_again(Protocol::Methods::KILL, [fresh], live[:session]) if killed

          @inner.on_notification(fresh.to_s, relabel(key, handler)) if handler
        rescue ServerError => e
          log(:error, "Could not restore live query #{key}: #{e.message}")
        end
      end

      # A response can arrive just before the connection drops, and the
      # thread that asked for it records its effect (a `use`, a new live
      # query) after that. A restore waits for such requests, so it brings
      # back the state they changed. Requests still waiting for a response
      # fail with the old connection; those made on the new one meanwhile
      # are waited for only up to DELIVERY_WAIT.
      def await_deliveries
        deadline = monotonic_now + DELIVERY_WAIT
        @state_mutex.synchronize do
          while @delivering.positive? && (left = deadline - monotonic_now).positive?
            @delivered.wait(@state_mutex, left)
          end
        end
      end

      # Live queries and attached sessions end with the connection, so a
      # kill or detach the connection dropped under has done its job.
      def ends_with_connection?(method, session)
        method == Protocol::Methods::KILL || (method == Protocol::Methods::DETACH && !session.nil?)
      end

      # A reconnect another thread made after the drop may have restored the
      # live query or session before this request forgot it; it is ended
      # again on the new connection then.
      def ended_with_connection(method, params, session, since, deadline)
        again = method == Protocol::Methods::KILL ? kill_lost(params[0], since) : detach_lost(session, since)
        recover(deadline, method)
        end_again(method, *again, deadline) if again
        nil
      rescue TimeoutError
        nil # the reconnect carries on in the background
      end

      # A live query ends with the connection it was started on, so a kill
      # the connection dropped under has done its job either way, as long as
      # the reconnect does not start the live query again. Forgetting it is
      # atomic with a restore's record of it: either the restore has started
      # it again on a newer connection (and it is killed again here) or the
      # restore finds it gone and kills what it started itself.
      # @return [Array, nil] the kill to send again, if it was restored
      def kill_lost(id, since)
        live = @state_mutex.synchronize { @lives.delete(id.to_s) }
        return unless live

        @inner.remove_notification_handler(live[:current].to_s)
        [[live[:current]], live[:session]] if live[:generation] > since
      end

      # The same goes for a detach: the session ended with the connection, so
      # forget it and its live queries rather than restoring them; one a
      # restore is attaching meanwhile it detaches again itself.
      def detach_lost(session, since)
        restored = @state_mutex.synchronize do
          @inner.track_request(Protocol::Methods::DETACH, [], nil, session)
          @ending_sessions << session
          @session_generations.delete(session).to_i > since
        end
        forget_session(session)
        [[], session] if restored
      end

      def end_again(method, params, session, deadline = nil)
        @inner.send_request(method, params, session: session, **time_left(deadline, method))
      rescue Error => e
        log(:warn, "Could not #{method} on the new connection what the dropped one ended: #{e.message}")
      end
    end
  end
end
