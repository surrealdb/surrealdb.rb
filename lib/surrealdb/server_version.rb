# frozen_string_literal: true

module SurrealDB
  # The SurrealDB server versions this SDK supports, and a check against them.
  module ServerVersion
    # The oldest supported server version.
    MINIMUM = '3.0.0'

    # The first unsupported server version (exclusive upper bound).
    MAXIMUM = '5.0.0'

    module_function

    # The numeric version in a server version string, as the server's
    # `version` method reports it.
    # @example
    #   ServerVersion.parse("surrealdb-3.4.0-nightly+20261014.4f7fa16") # => Gem::Version("3.4.0")
    # @param version [String]
    # @return [Gem::Version, nil] nil when there is no version number in it
    def parse(version)
      match = version.to_s.match(/(\d+)\.(\d+)\.(\d+)/)
      Gem::Version.new(match[0]) if match
    end

    # @param version [String] e.g. "surrealdb-3.3.4"
    # @return [Boolean] whether the SDK supports it; a pre-release counts as
    #   the release it leads to, so 5.0.0-alpha is not supported
    def supported?(version)
      parsed = parse(version)
      !parsed.nil? && parsed >= Gem::Version.new(MINIMUM) && parsed < Gem::Version.new(MAXIMUM)
    end

    # @param version [String]
    # @raise [UnsupportedVersionError] unless {.supported?}
    def check!(version)
      raise UnsupportedVersionError.new(version, MINIMUM, MAXIMUM) unless supported?(version)
    end
  end
end
