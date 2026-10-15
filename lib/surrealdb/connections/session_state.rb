# frozen_string_literal: true

module SurrealDB
  module Connections
    # What the client has told one server session: its namespace and database,
    # its variables, and its credentials.
    #
    # Connections keep one of these per session (the default session under
    # the key `nil`) and update it after every successful request. It is what
    # lets the SDK fork a session, replay a session after a reconnect, and
    # carry state over stateless HTTP.
    class SessionState
      # @return [String, nil]
      attr_accessor :namespace, :database

      # @return [String, nil] current access token
      attr_accessor :access_token

      # @return [String, nil] current refresh token
      attr_accessor :refresh_token

      # @return [Hash{String => Object}]
      attr_reader :variables

      # @return [Array, nil] the last signin call ([method, params]), kept so an
      #   expired session can sign in again
      attr_reader :signin

      def initialize
        @namespace = nil
        @database = nil
        @access_token = nil
        @refresh_token = nil
        @variables = {}
        @signin = nil
      end

      # Records the effect of a successful request.
      # @param method [String]
      # @param params [Array]
      # @param result [Object]
      def track(method, params, result) # rubocop:disable Metrics/CyclomaticComplexity
        case method
        when Protocol::Methods::USE then track_use(params, result)
        when Protocol::Methods::SIGNIN
          @signin = [method, snapshot(params)]
          store_tokens(result)
        when Protocol::Methods::SIGNUP
          @signin = nil # a new identity; the previous credentials are not its own
          store_tokens(result)
        when Protocol::Methods::AUTHENTICATE then authenticated_with(params[0])
        when Protocol::Methods::INVALIDATE then clear_auth
        when Protocol::Methods::RESET then reset
        when Protocol::Methods::LET, 'set' then @variables[params[0].to_s] = snapshot(params[1])
        when Protocol::Methods::UNSET then @variables.delete(params[0].to_s)
        end
      end

      # @return [Boolean] whether the session holds credentials
      def authenticated?
        !@access_token.nil?
      end

      # An independent copy, for forking a session.
      # @return [SessionState]
      def copy
        other = SessionState.new
        other.namespace = @namespace
        other.database = @database
        other.access_token = @access_token
        other.refresh_token = @refresh_token
        @variables.each { |k, v| other.variables[k] = v }
        other.instance_variable_set(:@signin, @signin)
        other
      end

      def clear_auth
        @access_token = nil
        @refresh_token = nil
        @signin = nil
      end

      # Forgets everything, as the server does on `reset`.
      def reset
        clear_auth
        @namespace = nil
        @database = nil
        @variables.clear
      end

      private

      # The value as it was sent: later changes to the caller's object must
      # not change what a fork or a replay sends.
      def snapshot(value) # rubocop:disable Metrics/CyclomaticComplexity
        case value
        when Hash then value.to_h { |k, v| [snapshot(k), snapshot(v)] }
        when Array then value.map { |v| snapshot(v) }
        when Set then Set.new(value) { |v| snapshot(v) }
        when String then value.frozen? ? value : value.dup
        else value
        end
      end

      # The server answers `use` with the resulting namespace and database
      # (NONE for one that is not set). Older servers answer with nothing, so
      # fall back to the params, where a String sets a value, nil clears it
      # and NONE leaves it alone.
      def track_use(params, result)
        if result.is_a?(Hash) && (result.key?('namespace') || result.key?('database'))
          @namespace = present(result['namespace'])
          @database = present(result['database'])
        else
          @namespace = use_value(params[0], @namespace)
          @database = use_value(params[1], @database)
        end
      end

      def present(value)
        value.is_a?(SurrealDB::None) ? nil : value
      end

      def use_value(value, current)
        return current if value.is_a?(SurrealDB::None)

        value
      end

      def store_tokens(result)
        case result
        when String
          @access_token = result
          @refresh_token = nil
        when Hash
          @access_token = result['access'] || result['token']
          @refresh_token = result['refresh']
        end
      end

      # Re-presenting the current token (as a reconnect does) changes
      # nothing; a different token is a different identity, so the refresh
      # token and sign-in credentials of the previous one are dropped.
      def authenticated_with(token)
        return if token == @access_token

        store_tokens(token)
        @signin = nil
      end
    end
  end
end
