# frozen_string_literal: true

# A driver for the surrealdb-protocol SDK conformance suite.
#
# The suite's runner starts this process once per scenario and transport, and
# talks to it in JSON lines on stdin and stdout: `{"id":1,"op":"query","args":{...}}`
# in, `{"id":1,"ok":true,"result":...}` or `{"id":1,"ok":false,"error":{"kind":...}}`
# out. Every op goes through the SDK's public API. An op the SDK has no API
# for answers `Unsupported`, which the runner reports as a skip.
#
#   conformance/fetch-protocol
#   cd tmp/surrealdb-protocol && bun install
#   bun conformance/runner/cli.ts --driver "bundle exec ruby $PWD/../../conformance/driver.rb"
#
# See conformance/README.md in surrealdb-protocol for the ops and their
# arguments.

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'json'
require 'surrealdb'
require_relative 'typed_json'

module SurrealDB
  module Conformance
    # Answers the runner's ops through a SurrealDB::Client.
    class Driver
      OPS = %w[
        connect close version signin signup authenticate invalidate info use set unset query query_stream
        run live live_of live_id next_notification kill new_session fork_session list_sessions
        close_session begin commit cancel import export
      ].freeze

      # An answer the driver gives instead of a result.
      class Failure < StandardError
        attr_reader :info

        def initialize(info)
          @info = info
          super(info['message'] || info['kind'])
        end
      end

      def initialize
        @client = nil
        reset
      end

      # Reads requests until stdin closes.
      def run(input = $stdin, output = $stdout)
        output.sync = true
        input.each_line do |line|
          next if line.strip.empty?

          request = JSON.parse(line)
          output.puts(JSON.generate(answer(request)))
        end
      ensure
        shutdown
      end

      def answer(request)
        { 'id' => request['id'], 'ok' => true, 'result' => call(request['op'], request['args'] || {}) }
      rescue StandardError => e
        { 'id' => request['id'], 'ok' => false, 'error' => error_info(e) }
      end

      private

      def reset
        @sessions = {}
        @txns = {}
        @subs = {}
        @next_handle = 1
      end

      def shutdown
        @client&.close
      rescue StandardError
        nil
      end

      def call(name, args) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
        case name
        when 'hello' then { 'name' => 'surrealdb.rb', 'version' => SurrealDB::VERSION, 'ops' => OPS }
        when 'connect' then connect(args)
        when 'close' then client.close.then { nil }
        when 'version' then client.version
        when 'signin' then to_json(session_only(name, args).signin(from_json(args['credentials'])))
        when 'signup' then to_json(session_only(name, args).signup(from_json(args['credentials'])))
        when 'authenticate' then session_only(name, args).authenticate(from_json(args['token'])).then { nil }
        when 'invalidate' then session_only(name, args).invalidate.then { nil }
        when 'info' then to_json(session_only(name, args).info)
        when 'use' then use(args)
        when 'set' then session_only(name, args).set(args['name'], from_json(args['value'])).then { nil }
        when 'unset' then session_only(name, args).unset(args['name']).then { nil }
        when 'query' then query(args)
        when 'query_stream' then query_stream(args)
        when 'run' then run_function(args)
        when 'live' then subscribe(args, session_only(name, args).live(args['table'], diff: args['diff'] == true))
        when 'live_of' then subscribe(args, from_json(args['id']))
        when 'live_id' then to_json(subscription(args)[:id])
        when 'next_notification' then next_notification(args)
        when 'kill' then kill(args)
        when 'new_session' then keep(client.new_session)
        when 'fork_session' then keep(args['from'] ? session(args['from']).fork_session : client.fork_session)
        when 'list_sessions' then client.sessions.map(&:to_s)
        when 'close_session' then close_session(args)
        when 'begin' then begin_transaction(args)
        when 'commit', 'cancel' then finish(name, args)
        when 'import' then session_only(name, args).import(args['surql']).then { nil }
        when 'export' then session_only(name, args).export(**export_options(args))
        else raise unsupported(name)
        end
      end

      def connect(args)
        shutdown
        reset
        @client = SurrealDB::Client.new(args['url'], reconnect: false)
        @client.connect
        nil
      end

      def client
        @client or raise Failure, { 'kind' => 'Internal', 'message' => 'not connected' }
      end

      # The namespace and database are left as they are when absent, and
      # cleared when null.
      def use(args)
        scope = session_only('use', args)
        namespace = args.key?('namespace') ? args['namespace'] : SurrealDB::NONE
        database = args.key?('database') ? args['database'] : SurrealDB::NONE
        to_json(scope.use(namespace: namespace, database: database))
      end

      def query(args)
        scope(args).query_raw(args['sql'], from_json(args['vars']) || {}).map do |result|
          if result.ok?
            { 'ok' => true, 'result' => to_json(result.result) }
          else
            { 'ok' => false, 'error' => error_info(result.to_error) }
          end
        end
      end

      # Collects the chunks into one result per statement, as `query` gives.
      def query_stream(args)
        statements = []
        begin
          scope(args).query_stream(args['sql'], from_json(args['vars']) || {}) do |chunk|
            collect_chunk(statements, chunk)
          end
        rescue SurrealDB::ServerError
          raise if statements.empty? # the call failed, not a statement
        end
        statements.map do |statement|
          next { 'ok' => false, 'error' => statement[:error] } if statement[:error]

          { 'ok' => true, 'result' => statement[:result] }
        end
      end

      def collect_chunk(statements, chunk)
        statement = statements[chunk.index] ||= { rows: [] }
        case chunk.kind
        when :rows then statement[:rows].concat(chunk.values)
        when :value then statement[:value] = chunk.values.first
        when :finished
          statement[:error] = error_info(chunk.error) if chunk.error?
          statement[:result] = to_json(statement.key?(:value) ? statement[:value] : statement[:rows])
        end
      end

      def run_function(args)
        version = args['version']
        to_json(scope(args).run(args['name'], *from_json(args['args'] || []), version: version))
      end

      def subscribe(args, live_id)
        queue = Queue.new
        scope = session_only('live', args)
        scope.subscribe(live_id) { |notification| queue << notification }
        handle = "live-#{next_handle}"
        @subs[handle] = { id: live_id, queue: queue, session: args['session'] }
        handle
      end

      def subscription(args)
        @subs.fetch(args['subscription']) do
          raise Failure, { 'kind' => 'NotFound', 'message' => "no subscription #{args['subscription']}" }
        end
      end

      def next_notification(args)
        timeout = (args['timeout'] || 5000) / 1000.0
        notification = subscription(args)[:queue].pop(timeout: timeout)
        return nil unless notification
        return { 'action' => 'KILLED' } if notification['action'] == 'KILLED'

        { 'action' => notification['action'], 'record' => to_json(notification['record']),
          'result' => to_json(notification['result']) }
      end

      def kill(args)
        sub = subscription(args)
        raise unsupported('kill in a transaction') if args['txn']
        raise unsupported("kill from a session other than the subscription's") if args['session'] != sub[:session]

        session(args['session']).kill(sub[:id])
        nil
      end

      def close_session(args)
        session_only('close_session', args).close
        @sessions.delete(args['session'])
        nil
      end

      def begin_transaction(args)
        handle = "txn-#{next_handle}"
        @txns[handle] = { txn: session_only('begin', args).begin_transaction, session: args['session'] }
        handle
      end

      def finish(name, args)
        txn = transaction(args)
        name == 'commit' ? txn.commit : txn.cancel
        nil
      end

      def export_options(args)
        (args['options'] || {}).to_h { |k, v| [k.to_sym, from_json(v)] }
      end

      def keep(session)
        handle = session.id.to_s
        @sessions[handle] = session
        handle
      end

      def session(handle)
        return client if handle.nil?

        @sessions.fetch(handle) { raise Failure, { 'kind' => 'NotFound', 'message' => "no session #{handle}" } }
      end

      def transaction(args)
        entry = @txns.fetch(args['txn']) do
          raise Failure, { 'kind' => 'NotFound', 'message' => "no transaction #{args['txn']}" }
        end
        if entry[:session] != args['session']
          raise Failure, { 'kind' => 'NotFound', 'message' => "no transaction #{args['txn']} in that session" }
        end

        entry[:txn]
      end

      # Where an op runs: the transaction when one is named, else the session.
      def scope(args)
        args['txn'] ? transaction(args) : session(args['session'])
      end

      # For an op the SDK has only on a session: a transaction is refused
      # rather than ignored, so the op never runs outside it.
      def session_only(name, args)
        raise unsupported("#{name} in a transaction") if args['txn']

        session(args['session'])
      end

      def next_handle
        @next_handle += 1
        @next_handle - 1
      end

      def unsupported(what)
        Failure.new('kind' => 'Unsupported', 'message' => "surrealdb.rb has no API for #{what}")
      end

      def from_json(json)
        TypedJson.from_json(json)
      end

      def to_json(value)
        TypedJson.to_json(value)
      end

      def error_info(error)
        case error
        when Failure then error.info
        when SurrealDB::UnsupportedError, TypedJson::Unrepresentable
          { 'kind' => 'Unsupported', 'message' => error.message }
        when SurrealDB::ImportError
          { 'kind' => 'Query', 'message' => error.message, 'failures' => error.failures.map { |f| error_info(f) } }
        when SurrealDB::ServerError then server_error_info(error)
        # The SDK refuses a finished transaction itself, where the server
        # would answer Validation.
        when SurrealDB::TransactionError then { 'kind' => 'Validation', 'message' => error.message }
        else { 'kind' => 'Internal', 'message' => "#{error.class}: #{error.message}" }
        end
      end

      # An error from an HTTP route (/import, /export) has no kind, only its
      # status: 401 and 403 raise NotAllowedError, 404 NotFoundError, and
      # another 4xx is the request's fault.
      def server_error_info(error)
        kind = error.kind || SurrealDB::ServerError::KIND_TO_CLASS.key(error.class) ||
               (error.code.to_i.between?(400, 499) ? 'Validation' : 'Internal')
        info = { 'kind' => kind, 'message' => error.message }
        info['details'] = to_json(error.details) unless error.details.nil?
        info['code'] = error.code if error.code
        info
      end
    end
  end
end

SurrealDB::Conformance::Driver.new.run if $PROGRAM_NAME == __FILE__
