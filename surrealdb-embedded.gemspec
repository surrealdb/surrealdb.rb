# frozen_string_literal: true

require_relative 'lib/surrealdb/version'

Gem::Specification.new do |spec|
  spec.name = 'surrealdb-embedded'
  spec.version = SurrealDB::VERSION
  spec.authors = ['SurrealDB']
  spec.email = ['stu.schwartz@surrealdb.com']

  spec.summary = 'Embedded SurrealDB engine for the Ruby SDK'
  spec.description = 'Adds embedded database support (mem://, surrealkv://, file://) to the ' \
                     'SurrealDB Ruby SDK via FFI bindings to libsurrealdb_c. Requires ' \
                     'libsurrealdb_c to be installed or SURREALDB_LIB_PATH to be set.'
  spec.homepage = 'https://github.com/surrealdb/surrealdb.rb'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => 'https://github.com/surrealdb/surrealdb.rb',
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir[
    'lib/surrealdb/embedded.rb',
    'lib/surrealdb/native/**/*',
    'lib/surrealdb/connections/embedded.rb'
  ]
  spec.require_paths = ['lib']

  spec.add_dependency 'ffi', '~> 1.15'
  spec.add_dependency 'surrealdb', "= #{SurrealDB::VERSION}"
end
