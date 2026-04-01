# frozen_string_literal: true

require_relative 'lib/surrealdb/version'

Gem::Specification.new do |spec|
  spec.name = 'surrealdb'
  spec.version = SurrealDB::VERSION
  spec.authors = ['SurrealDB']
  spec.email = ['stu.schwartz@surrealdb.com']

  spec.summary = 'Official SurrealDB SDK for Ruby'
  spec.description = 'Ruby client for SurrealDB with WebSocket and HTTP transports, ' \
                     'CBOR serialization, and full support for queries, CRUD operations, ' \
                     'authentication, and live queries.'
  spec.homepage = 'https://github.com/surrealdb/surrealdb.rb'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => 'https://github.com/surrealdb/surrealdb.rb',
    'changelog_uri' => 'https://github.com/surrealdb/surrealdb.rb/blob/main/CHANGELOG.md',
    'bug_tracker_uri' => 'https://github.com/surrealdb/surrealdb.rb/issues',
    'documentation_uri' => 'https://surrealdb.com/docs/sdk/ruby',
    'rubygems_mfa_required' => 'true'
  }

  spec.files = Dir['lib/**/*', 'LICENSE', 'README.md', 'CHANGELOG.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'bigdecimal'
  spec.add_dependency 'cbor', '~> 0.5'
  spec.add_dependency 'websocket-driver', '~> 0.7'
end
