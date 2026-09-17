# frozen_string_literal: true

require "test_helper"

module Sidekiq
  module Locking
    class InstallTest < Minitest::Test
      def setup
        @original_prefix = Locking.redis_key_prefix
        Locking.redis_key_prefix = Locking::DEFAULT_REDIS_KEY_PREFIX
        flush_lock_keys

        @client_config = Sidekiq::Config.new
        @server_config = Sidekiq::Config.new

        Sidekiq.stubs(:configure_client).yields(@client_config)
        Sidekiq.stubs(:configure_server).yields(@server_config)
      end

      def teardown
        flush_lock_keys
        Locking.redis_key_prefix = @original_prefix
      end

      def flush_lock_keys
        Sidekiq.redis do |conn|
          keys = conn.call("KEYS", "#{Locking.redis_key_prefix}*")
          conn.del(*keys) if keys.any?
        end
      end

      def test_install_registers_client_and_server_middleware_on_client_configuration
        # The client config also gets the server middleware so `perform_inline`
        # releases locks too.
        Locking.install!

        assert_equal [Middleware::Client], middleware_classes(@client_config.client_middleware)
        assert_equal [Middleware::Server], middleware_classes(@client_config.server_middleware)
      end

      def test_install_registers_client_and_server_middleware_on_server_configuration
        Locking.install!

        assert_equal [Middleware::Client], middleware_classes(@server_config.client_middleware)
        assert_equal [Middleware::Server], middleware_classes(@server_config.server_middleware)
      end

      def test_install_registers_a_death_handler_that_releases_the_lock
        Locking.install!

        jid = "dead-jid"
        digest = "dead-digest"
        Sidekiq.redis { |conn| conn.set("#{Locking.redis_key_prefix}#{digest}", jid) }

        handler = @server_config.death_handlers.last
        refute_nil handler, "install! should append a death handler"
        handler.call({ Locking::TOKEN_KEY => digest, "jid" => jid }, RuntimeError.new("boom"))

        assert_nil Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }
      end

      def test_install_death_handler_is_a_no_op_for_jobs_without_a_token
        Locking.install!

        handler = @server_config.death_handlers.last

        # No token on the job → the handler must not raise and must touch nothing.
        assert_nil handler.call({ "jid" => "no-token-jid" }, RuntimeError.new("boom"))
      end

      def test_install_middleware_registration_is_idempotent
        # chain.add removes an existing entry before re-adding, so registering
        # twice does not duplicate the middleware. (Death handlers are a plain
        # array and are intentionally not covered here.)
        Locking.install!
        Locking.install!

        assert_equal [Middleware::Client], middleware_classes(@client_config.client_middleware)
        assert_equal [Middleware::Server], middleware_classes(@client_config.server_middleware)
        assert_equal [Middleware::Client], middleware_classes(@server_config.client_middleware)
        assert_equal [Middleware::Server], middleware_classes(@server_config.server_middleware)
      end

      private

        def middleware_classes(chain)
          chain.entries.map(&:klass)
        end
    end
  end
end
