# frozen_string_literal: true

module SurrealDB
  module Protocol
    module Methods
      PING            = 'ping'
      USE             = 'use'
      INFO            = 'info'
      VERSION         = 'version'
      SIGNIN          = 'signin'
      SIGNUP          = 'signup'
      AUTHENTICATE    = 'authenticate'
      INVALIDATE      = 'invalidate'
      RESET           = 'reset'
      REFRESH         = 'refresh'
      REVOKE          = 'revoke'
      LET             = 'let'
      UNSET           = 'unset'
      LIVE            = 'live'
      KILL            = 'kill'
      QUERY           = 'query'
      QUERY_STREAM    = 'query_stream'
      QUERY_CANCEL    = 'query_cancel'
      GQL             = 'gql'
      SELECT          = 'select'
      CREATE          = 'create'
      INSERT          = 'insert'
      INSERT_RELATION = 'insert_relation'
      UPDATE          = 'update'
      UPSERT          = 'upsert'
      MERGE           = 'merge'
      PATCH           = 'patch'
      DELETE          = 'delete'
      RELATE          = 'relate'
      RUN             = 'run'
      ATTACH          = 'attach'
      DETACH          = 'detach'
      SESSIONS        = 'sessions'
      BEGIN_TXN       = 'begin'
      COMMIT          = 'commit'
      CANCEL          = 'cancel'
    end
  end
end
