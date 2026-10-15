# frozen_string_literal: true

module SurrealDB
  module Protocol
    module Methods
      USE             = 'use'
      INFO            = 'info'
      VERSION         = 'version'
      SIGNIN          = 'signin'
      SIGNUP          = 'signup'
      AUTHENTICATE    = 'authenticate'
      INVALIDATE      = 'invalidate'
      LET             = 'let'
      UNSET           = 'unset'
      LIVE            = 'live'
      KILL            = 'kill'
      QUERY           = 'query'
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

      # Methods that can be sent again without changing anything when it is
      # not known whether the first attempt ran.
      SAFE_TO_REPEAT = [
        'ping', VERSION, INFO, SELECT, USE, LET, 'set', UNSET, AUTHENTICATE, INVALIDATE, SESSIONS, DETACH
      ].freeze
    end
  end
end
