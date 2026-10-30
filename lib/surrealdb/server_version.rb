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
      # Not /(\d+)\.(\d+)\.(\d+)/: unanchored, its backtracking is quadratic
      # in a long run of digits. Each run of digits and dots is scanned once.
      version.to_s.scan(/[\d.]+/) do |run|
        run.split('.').each_cons(3) do |parts|
          return Gem::Version.new(parts.join('.')) if parts.none?(&:empty?)
        end
      end
      nil
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
