# frozen_string_literal: true

# Opt-in entrypoint for the embedded SurrealDB connection.
# Loads the FFI bindings and the Embedded connection class.
#
# Usage:
#   require "surrealdb"
#   require "surrealdb/embedded"
#
#   SurrealDB.connect("mem://") do |db|
#     db.use("test", "test")
#     # ...
#   end
#
# Requires the `ffi` gem and either:
# - SURREALDB_LIB_PATH env var pointing to libsurrealdb_c
# - libsurrealdb_c installed in the system library path

require_relative 'native/platform'
require_relative 'native/options'
require_relative 'native/ffi'
require_relative 'connections/embedded'
