# frozen_string_literal: true

require 'base64'
require 'json'

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
      attr_reader :access_token

      # @return [Time, nil] when the access token expires, when it says
      attr_reader :access_expires_at

      # @return [String, nil] current refresh token
      attr_reader :refresh_token

      # @return [Hash{String => Object}]
      attr_reader :variables

      # @return [Array, nil] the last signin call ([method, params]), kept so an
      #   expired session can sign in again
      attr_accessor :signin

      def initialize
        @namespace = nil
        @database = nil
        self.access_token = nil
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
          signed_in(params[0], result)
        when Protocol::Methods::SIGNUP
          @signin = nil # a new identity; the previous credentials are not its own
          signed_in(params[0], result)
        when Protocol::Methods::REFRESH then refreshed(params[0], result)
        when Protocol::Methods::AUTHENTICATE then authenticated_with(params[0])
        when Protocol::Methods::REVOKE then forget_revoked(params[0])
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

      # Kept as a copy: the caller's string may change later.
      # @param token [String, nil]
      def refresh_token=(token)
        @refresh_token = snapshot(token)
      end

      # @param token [String, nil]
      def access_token=(token)
        @access_token = token
        claims = self.class.token_claims(token) || {}
        exp = claims['exp']
        iat = claims['iat']
        @access_expires_at = (Time.at(exp) if exp.is_a?(Numeric))
        @access_lifetime = (exp - iat if exp.is_a?(Numeric) && iat.is_a?(Numeric))
      end

      # The access token as a pair with the refresh token, as the server's
      # `refresh` and `revoke` methods take them.
      # @return [Hash, nil]
      def tokens
        return nil unless @access_token

        { 'access' => @access_token, 'refresh' => @refresh_token }.compact
      end

      # Whether the access token expires within `margin` seconds. The margin
      # is capped at a quarter of the token's lifetime, so a short-lived token
      # is not renewed on every request.
      # @param margin [Numeric]
      # @param now [Time]
      # @return [Boolean]
      def expiring?(margin, now = Time.now)
        return false unless @access_expires_at

        margin = [margin, @access_lifetime / 4.0].min if @access_lifetime
        @access_expires_at - now <= margin
      end

      # Whether the access token has expired.
      # @param now [Time]
      # @return [Boolean]
      def expired?(now = Time.now)
        !@access_expires_at.nil? && @access_expires_at <= now
      end

      # Whether an expiring token can be renewed: with the refresh token, or
      # by signing in again.
      # @return [Boolean]
      def renewable?
        !@refresh_token.nil? || !@signin.nil?
      end

      # The claims of a JWT, decoded but not verified: the SDK only reads
      # them to follow what the server does with the token.
      # @param token [String, nil]
      # @return [Hash, nil] nil for a token that is not a JWT
      def self.token_claims(token)
        payload = token.to_s.split('.')[1]
        return nil unless payload

        claims = JSON.parse(Base64.urlsafe_decode64(payload + ('=' * (-payload.length % 4))))
        claims.is_a?(Hash) ? claims : nil
      rescue ArgumentError, JSON::ParserError
        nil
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
        self.access_token = nil
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
        when SurrealDB::None then value
        else sdk_value?(value) ? snapshot_fields(value) : value
        end
      end

      # The SDK's own types (a RecordID, a Range, a geometry) can hold
      # mutable values too, such as an Array id.
      def sdk_value?(value)
        value.class.name&.start_with?('SurrealDB::')
      end

      def snapshot_fields(value)
        copy = value.dup
        value.instance_variables.each do |name|
          copy.instance_variable_set(name, snapshot(value.instance_variable_get(name)))
        end
        copy
      end

      # The server answers `use` with the resulting namespace and database
      # (NONE for one that is not set). Older servers answer with nothing, so
      # fall back to the params, where a String sets a value, nil clears it
      # and NONE leaves it alone.
      def track_use(params, result)
        if result.is_a?(Hash) && (result.key?('namespace') || result.key?('database'))
          @namespace = snapshot(present(result['namespace']))
          @database = snapshot(present(result['database']))
        else
          @namespace = snapshot(use_value(params[0], @namespace))
          @database = snapshot(use_value(params[1], @database))
        end
      end

      def present(value)
        value.is_a?(SurrealDB::None) ? nil : value
      end

      def use_value(value, current)
        return current if value.is_a?(SurrealDB::None)

        value
      end

      # Signing in or up at namespace or database level also selects that
      # namespace (and database) on the server, as `use` would; the rest of
      # the selection is left as it was.
      def signed_in(credentials, result)
        store_tokens(result)
        select_scope(credentials.is_a?(Hash) ? credentials.transform_keys(&:to_s) : {})
      end

      def select_scope(source)
        namespace = source['NS'] || source['ns']
        database = source['DB'] || source['db']
        @namespace = snapshot(namespace) if namespace.is_a?(String)
        @database = snapshot(database) if database.is_a?(String)
      end

      def store_tokens(result)
        case result
        when String
          self.access_token = snapshot(result)
          @refresh_token = nil
        when Hash
          self.access_token = snapshot(result['access'] || result['token'])
          @refresh_token = snapshot(result['refresh'])
        end
      end

      # Refreshing another identity's token pair switches to that identity,
      # whose sign-in credentials are not the ones kept, and to the scope its
      # token names.
      def refreshed(tokens, result)
        @signin = nil unless tokens.is_a?(Hash) && tokens['access'] == @access_token
        store_tokens(result)
        select_scope(self.class.token_claims(@access_token) || {})
      end

      # Re-presenting the current token (as a reconnect does) changes
      # nothing; a different token is a different identity, so the refresh
      # token and sign-in credentials of the previous one are dropped, and
      # the scope the token names is selected.
      def authenticated_with(token)
        return if token == @access_token

        store_tokens(token)
        @signin = nil
        select_scope(self.class.token_claims(token) || {})
      end

      def forget_revoked(tokens)
        @refresh_token = nil if tokens.is_a?(Hash) && tokens['refresh'] == @refresh_token
      end
    end
  end
end
