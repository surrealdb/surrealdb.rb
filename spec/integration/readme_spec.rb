# frozen_string_literal: true

require 'stringio'
require 'tmpdir'

# Runs the Ruby examples in README.md against the test server, so the
# documentation cannot drift from what the SDK does.
#
# Every ```ruby block runs, except installation snippets and the embedded
# examples (which need libsurrealdb_c). Fragments may use `db` or `client`,
# which are provided connected and signed in. Each block gets its own
# database, so examples can create the same records on every run.
README_PATH = File.expand_path('../../README.md', __dir__)

# [code, line] for every ```ruby block in the README worth running.
README_EXAMPLES = File.read(README_PATH).to_enum(:scan, /^```ruby\n(.*?)^```/m).filter_map do
  match = Regexp.last_match
  code = match[1]
  next if code.match?(/^gem /) || code.include?('surrealdb/embedded')

  [code, match.pre_match.count("\n") + 2]
end.freeze

RSpec.describe 'README examples', :integration do
  let(:database) { unique_table('readme') }
  let(:namespace) { SurrealHelper::SURREAL_NS }

  def adapt(code)
    code.gsub('"ws://localhost:8000"', SurrealHelper::SURREAL_WS_URL.inspect)
        .gsub('"http://localhost:8000"', SurrealHelper::SURREAL_HTTP_URL.inspect)
        .gsub('"user" => "root", "pass" => "root"',
              "\"user\" => #{SurrealHelper::SURREAL_USER.inspect}, \"pass\" => #{SurrealHelper::SURREAL_PASS.inspect}")
        .gsub('.use("test", "test")', ".use(#{namespace.inspect}, #{database.inspect})")
        .gsub('"my_namespace"', namespace.inspect)
        .gsub('"my_database"', database.inspect)
  end

  # Users and the record access the Authentication example signs in with.
  def define_example_users(client)
    client.query(<<~SQL)
      DEFINE USER OVERWRITE ns_user ON NAMESPACE PASSWORD 'ns_pass' ROLES OWNER;
      DEFINE USER OVERWRITE db_user ON DATABASE PASSWORD 'db_pass' ROLES OWNER;
      DEFINE ACCESS OVERWRITE user_access ON DATABASE TYPE RECORD
        SIGNUP (CREATE user SET username = $username, password = crypto::argon2::generate($password))
        SIGNIN (SELECT * FROM user WHERE username = $username AND crypto::argon2::compare(password, $password))
        WITH REFRESH;
    SQL
  end

  def example_binding(db)
    binding.tap { |b| b.local_variable_set(:client, db) }
  end

  # Runs one example in a scratch directory and returns what it printed;
  # global configuration it changes is put back.
  def run_example(code, line, db)
    config = SurrealDB.configuration
    saved = [config.timeout, config.logger]
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        capture_stdout { eval(adapt(code), example_binding(db), README_PATH, line) } # rubocop:disable Security/Eval
      end
    end
  ensure
    config.timeout, config.logger = saved
  end

  def capture_stdout
    out = StringIO.new
    original = $stdout
    $stdout = out
    yield
    out.string
  ensure
    $stdout = original
  end

  README_EXAMPLES.each do |code, line|
    it "runs the example at README.md:#{line}" do
      db = new_test_client(SurrealHelper::SURREAL_WS_URL)
      db.use(namespace, database)
      define_example_users(db) if code.include?('user_access')

      expect { run_example(code, line, db) }.not_to raise_error
    ensure
      db&.close
    end
  end
end
