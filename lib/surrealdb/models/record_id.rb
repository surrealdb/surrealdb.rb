# frozen_string_literal: true

module SurrealDB
  # Represents a SurrealDB record identifier (table + id).
  #
  # A RecordID uniquely identifies a record within a table.
  # The id component can be a string, integer, array, or object.
  #
  # Record ids are always sent to the server as typed values (CBOR tag 8).
  # Plain strings are never treated as record ids: use {.parse} or
  # {StringRecordID} to turn a "table:id" string into one explicitly.
  class RecordID
    # Characters an identifier may contain without being escaped.
    IDENT = /\A[a-zA-Z0-9_]+\z/

    # How characters are escaped inside ⟨...⟩. SurrealQL writes a backspace
    # as \u{8}; a closing bracket must be \u{27e9}, as SurrealDB 3 rejects
    # \⟩.
    ESCAPES = {
      '\\' => '\\\\', "\0" => '\\0', "\r" => '\\r', "\t" => '\\t', "\n" => '\\n', "\f" => '\\f', "\b" => '\\u{8}',
      '⟩' => '\\u{27e9}'
    }.freeze
    # The escapes SurrealQL reads inside ⟨...⟩ and `...`, besides \u{...}
    # and \uXXXX; any other is invalid. (\⟩ is read as newer servers do.)
    UNESCAPES = {
      '0' => "\0", 'r' => "\r", 't' => "\t", 'n' => "\n", 'f' => "\f", 'b' => "\b",
      '\\' => '\\', "'" => "'", '"' => '"', '`' => '`', '⟩' => '⟩'
    }.freeze

    # @return [String] table name
    attr_reader :table

    # @return [Object] record identifier (String, Integer, Array, Hash)
    attr_reader :id

    # @param table [String]
    # @param id [Object]
    def initialize(table, id)
      raise ArgumentError, 'table must be a non-empty string' if table.nil? || table.to_s.empty?

      @table = -table.to_s
      @id = id
    end

    # Parses a "table:id" string into a RecordID on the client.
    #
    # Handles plain, numeric, and escaped (⟨...⟩ or `...`) table names and
    # ids. Array, object, and range ids cannot be parsed here: build those
    # with {#initialize}, or let the server parse them with {StringRecordID}.
    #
    # @param str [String] e.g. "user:john", "post:123", "user:⟨john doe⟩"
    # @return [RecordID]
    # @raise [ArgumentError] if the string is not a valid record ID
    def self.parse(str)
      str = str.to_s
      table, rest = split_table(str)
      raise ArgumentError, "invalid record ID: #{str}" if table.nil? || table.empty? || rest.nil? || rest.empty?

      new(table, parse_id(rest, str))
    end

    def to_s
      "#{escape_ident(@table)}:#{format_id(@id)}"
    end

    def inspect
      "SurrealDB::RecordID(#{self})"
    end

    def ==(other)
      other.is_a?(RecordID) && other.table == @table && other.id == @id
    end
    alias eql? ==

    def hash
      [self.class, @table, @id].hash
    end

    class << self
      private

      def parse_id(rest, str)
        if rest.start_with?('⟨', '`')
          value, finish = read_escaped(rest)
          raise ArgumentError, "invalid record ID: #{str}" unless finish == rest.length

          value
        elsif rest.match?(/\A[+-]\d+\z/) # a signed number; IDENT has no sign
          Integer(rest, 10)
        elsif rest.match?(IDENT)
          try_numeric(rest)
        else
          raise ArgumentError, "cannot parse record ID #{str.inspect} on the client; " \
                               'use SurrealDB::StringRecordID to let the server parse it'
        end
      end

      # Splits on the first colon outside an escaped table name.
      def split_table(str)
        return str.split(':', 2) unless str.start_with?('⟨', '`')

        table, finish = read_escaped(str)
        return [nil, nil] unless finish && str[finish] == ':'

        [table, str[(finish + 1)..]]
      end

      # Reads the ⟨...⟩ or `...` identifier at the start of str, undoing its
      # backslash escapes. Returns the identifier and the index just past
      # the closing delimiter, or nil if it is never closed.
      def read_escaped(str)
        close = str.start_with?('`') ? '`' : '⟩'
        out = +''
        i = 1
        while i < str.length
          char = str[i]
          return [out, i + 1] if char == close

          if char == '\\'
            i += 1
            return nil if i >= str.length

            char, i = read_escape(str, i)
            out << char
          else
            out << char
            i += 1
          end
        end
        nil
      end

      # Decodes the escape whose character (after the backslash) is at pos.
      def read_escape(str, pos)
        char = str[pos]
        return read_unicode_escape(str, pos) if char == 'u'
        raise ArgumentError, "invalid escape \\#{char}" unless UNESCAPES.key?(char)

        [UNESCAPES[char], pos + 1]
      end

      # \u{...} with 1 to 6 hex digits, or \u with exactly 4.
      def read_unicode_escape(str, pos)
        if str[pos + 1] == '{'
          close = str.index('}', pos + 2)
          raise ArgumentError, 'unterminated unicode escape \\u{' unless close

          return [unicode_char(str[(pos + 2)...close]), close + 1]
        end
        hex = str[pos + 1, 4].to_s
        raise ArgumentError, "invalid unicode escape \\u#{hex}" unless hex.match?(/\A\h{4}\z/)

        [unicode_char(hex), pos + 5]
      end

      # The character a unicode escape names: hex digits giving a Unicode
      # scalar value (not a surrogate).
      def unicode_char(hex)
        code = Integer(hex, 16) if hex.match?(/\A\h{1,6}\z/)
        valid = code && code <= 0x10FFFF && !code.between?(0xD800, 0xDFFF)
        raise ArgumentError, "invalid unicode escape \\u{#{hex}}" unless valid

        code.chr(Encoding::UTF_8)
      end

      def try_numeric(str)
        Integer(str, 10)
      rescue ArgumentError, TypeError
        str
      end
    end

    private

    def format_id(value)
      case value
      when String then escape_ident(value)
      when Array then "[#{value.map { |v| format_value(v) }.join(', ')}]"
      when Hash then format_object_id(value)
      else value.to_s
      end
    end

    def format_value(value)
      case value
      when String then value.inspect
      when Array then "[#{value.map { |v| format_value(v) }.join(', ')}]"
      when Hash then format_object_id(value)
      else value.to_s
      end
    end

    # Escapes the way SurrealQL does: anything that is not a plain identifier,
    # or that would read back as a number, goes in ⟨...⟩.
    def escape_ident(str)
      return str if str.match?(IDENT) && !str.match?(/\A\d+\z/)

      "⟨#{str.gsub(/[\\\0\r\t\n\f\b⟩]/) { |c| ESCAPES.fetch(c, "\\#{c}") }}⟩"
    end

    def format_object_id(obj)
      inner = obj.map { |k, v| "#{k}: #{format_value(v)}" }.join(', ')
      "{ #{inner} }"
    end
  end

  # A record id given as a "table:id" string, for the server to parse.
  #
  # Use this when the id is only available as text and may be complex
  # (array, object, or range ids) that {RecordID.parse} cannot handle.
  # It is sent as CBOR tag 8 carrying the string, and the server parses it.
  class StringRecordID
    # @return [String]
    attr_reader :value

    # @param value [String] e.g. "person:alice", "temp:['London', d'2026-01-01']"
    def initialize(value)
      raise ArgumentError, 'record ID string must be non-empty' if value.nil? || value.to_s.empty?

      @value = -value.to_s
    end

    def to_s
      @value
    end

    def inspect
      "SurrealDB::StringRecordID(#{@value})"
    end

    def ==(other)
      other.is_a?(StringRecordID) && other.value == @value
    end
    alias eql? ==

    def hash
      [self.class, @value].hash
    end
  end
end
