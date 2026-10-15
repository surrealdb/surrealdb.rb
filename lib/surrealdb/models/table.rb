# frozen_string_literal: true

module SurrealDB
  # Wraps a table name to distinguish table-level operations from
  # record-level operations that take a string "table:id".
  class Table
    # @return [String]
    attr_reader :name

    # @param name [String]
    def initialize(name)
      raise ArgumentError, 'table name must be a non-empty string' if name.nil? || name.empty?

      @name = -name.to_s # a frozen copy: the caller keeps their string as it was
    end

    def to_s
      @name
    end

    def inspect
      "SurrealDB::Table(#{@name})"
    end

    def ==(other)
      other.is_a?(Table) && other.name == @name
    end
    alias eql? ==

    def hash
      [self.class, @name].hash
    end
  end
end
