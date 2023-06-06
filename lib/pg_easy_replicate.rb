# frozen_string_literal: true

require "json"
require "ougai"
require "lockbox"
require "pg"
require "sequel"

require "pg_easy_replicate/helper"
require "pg_easy_replicate/version"
require "pg_easy_replicate/query"
require "pg_easy_replicate/group"
require "pg_easy_replicate/cli"

Sequel.default_timezone = :utc
module PgEasyReplicate
  class Error < StandardError
  end

  extend Helper

  class << self
    def config
      abort_with("SOURCE_DB_URL is missing") if source_db_url.nil?
      abort_with("TARGET_DB_URL is missing") if target_db_url.nil?
      @config ||=
        begin
          q =
            "select name, setting from pg_settings where name in  ('max_wal_senders', 'max_worker_processes', 'wal_level',  'max_replication_slots', 'max_logical_replication_workers');"

          {
            source_db_is_superuser: is_super_user?(source_db_url),
            target_db_is_superuser: is_super_user?(target_db_url),
            source_db: Query.run(query: q, connection_url: source_db_url),
            target_db: Query.run(query: q, connection_url: target_db_url),
          }
        rescue => e
          abort_with("Unable to check config: #{e.message}")
        end
    end

    def assert_config
      unless assert_wal_level_logical(config.dig(:source_db))
        abort_with("WAL_LEVEL should be LOGICAL on source DB")
      end

      unless assert_wal_level_logical(config.dig(:target_db))
        abort_with("WAL_LEVEL should be LOGICAL on target DB")
      end

      unless config.dig(:source_db_is_superuser)
        abort_with("User on source database should be a superuser")
      end

      return if config.dig(:target_db_is_superuser)
      abort_with("User on target database should be a superuser")
    end

    def bootstrap
      assert_config
      logger.info("Setting up schema")
      setup_schema
      logger.info("Setting up groups tables")
      Group.setup

      logger.info("Setting up replication user on source database")
      create_user(source_db_url)

      logger.info("Setting up replication user on target database")
      create_user(target_db_url)
    rescue => e
      abort_with("Unable to bootstrap: #{e.message}")
    end

    def cleanup(options)
      Group.drop
      if options[:everything]
        drop_schema
        drop_user # TODO create user with group name?
      end
      # drop publication and subscriptions from both DBs - if everything or sync
    rescue => e
      abort_with("Unable to cleanup: #{e.message}")
    end

    def drop_schema
      Query.run(
        query: "DROP SCHEMA IF EXISTS #{internal_schema_name} CASCADE",
        connection_url: source_db_url,
        schema: internal_schema_name,
      )
    end

    def setup_schema
      sql = <<~SQL
        create schema if not exists #{internal_schema_name};
        grant usage on schema #{internal_schema_name} to #{db_user(source_db_url)};
        grant create on schema #{internal_schema_name} to #{db_user(source_db_url)};
      SQL

      Query.run(
        query: sql,
        connection_url: source_db_url,
        schema: internal_schema_name,
      )
    end

    def logger
      @logger ||=
        begin
          logger = Ougai::Logger.new($stdout)
          logger.level =
            ENV["DEBUG"] ? Ougai::Logger::TRACE : Ougai::Logger::INFO
          logger.with_fields = { version: PgEasyReplicate::VERSION }
          logger
        end
    end

    private

    def assert_wal_level_logical(db_config)
      db_config&.find do |r|
        r.dig(:name) == "wal_level" && r.dig(:setting) == "logical"
      end
    end

    def is_super_user?(url)
      Query.run(
        query:
          "select usesuper from pg_user where usename = '#{db_user(url)}';",
        connection_url: url,
      ).first[
        :usesuper
      ]
    end

    def create_user(conn_string)
      password = connection_info(conn_string)[:user]
      sql = <<~SQL
        drop role if exists #{internal_user_name};
        create role #{internal_user_name} with password '#{password}' login superuser createdb createrole;
      SQL

      Query.run(query: sql, connection_url: conn_string)
    end

    def drop_user
      sql = "drop role if exists #{internal_user_name};"

      logger.info("Dropping replication user on source database")
      Query.run(query: sql, connection_url: source_db_url)

      logger.info("Dropping replication user on target database")
      Query.run(query: sql, connection_url: target_db_url)
    end
  end
end
