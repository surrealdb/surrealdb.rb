# frozen_string_literal: true

module SurrealDB
  module Native
    # Ruby-side checks for the options passed to libsurrealdb_c, kept apart
    # from the FFI bindings so they can be used without loading the library.
    module Options
      # The C library takes its timeouts as whole seconds in a uint8_t.
      MAX_TIMEOUT = 255

      module_function

      # Converts a timeout to the whole seconds the C library expects.
      # nil and 0 mean no timeout; fractions round up, so a short timeout
      # never becomes "no timeout".
      # @param value [Numeric, nil] seconds
      # @param name [Symbol] the option, for the error message
      # @return [Integer] 0..255
      # @raise [ArgumentError] for anything but a finite, real, non-negative
      #   number up to 255
      def timeout_seconds(value, name)
        return 0 if value.nil?
        unless value.is_a?(Numeric) && value.real? && value.finite?
          raise ArgumentError, "#{name} must be a finite number of seconds, got #{value.inspect}"
        end
        raise ArgumentError, "#{name} must not be negative, got #{value}" if value.negative?

        seconds = value.ceil
        return seconds if seconds <= MAX_TIMEOUT

        raise ArgumentError,
              "#{name} of #{value}s is too long for an embedded connection: the engine takes at most " \
              "#{MAX_TIMEOUT}s (0 means no timeout)"
      end
    end
  end
end
