# frozen_string_literal: true

require "test_helper"

module Sidekiq
  module Locking
    class AcquirerTest < Minitest::Test
      # Emulates a pre-7.0 Redis server (neeto staging runs 6.2.12), where the
      # GET option of SET is rejected when combined with NX. Redis 7.0 was the
      # first release to allow that combination; 6.2 answers "ERR syntax error".
      class Redis62Connection
        def initialize(connection)
          @connection = connection
        end

        def set(key, value, *options)
          reject_nx_with_get!(options)

          @connection.set(key, value, *options)
        end

        def call(*args)
          reject_nx_with_get!(args.drop(3)) if args.first.to_s.casecmp("set").zero?

          @connection.call(*args)
        end

        private

          def reject_nx_with_get!(options)
            flags = options.map { |option| option.to_s.downcase }
            return unless flags.include?("nx") && flags.include?("get")

            raise RedisClient::CommandError, "ERR syntax error"
          end
      end

      def setup
        @original_prefix = Locking.redis_key_prefix
        Locking.redis_key_prefix = Locking::DEFAULT_REDIS_KEY_PREFIX
        flush_lock_keys
      end

      def teardown
        flush_lock_keys
        Locking.redis_key_prefix = @original_prefix
      end

      def test_acquires_a_free_lock
        assert_equal :acquired, Acquirer.try_acquire(key_for("free"), "jid-1", 10_000)
      end

      def test_reports_the_holding_jid_when_the_lock_is_taken
        key = key_for("taken")
        Acquirer.try_acquire(key, "jid-1", 10_000)

        held = Acquirer.try_acquire(key, "jid-2", 10_000)

        assert_predicate held, :held?
        assert_equal "jid-1", held.jid
      end

      def test_sets_the_lock_ttl_in_milliseconds
        key = key_for("ttl")
        Acquirer.try_acquire(key, "jid-1", 30_000)

        ttl = Sidekiq.redis { |conn| conn.call("PTTL", key.redis_key) }

        assert_operator ttl, :>, 25_000
        assert_operator ttl, :<=, 30_000
      end

      def test_acquires_on_redis_below_seven
        with_redis_62 do
          assert_equal :acquired, Acquirer.try_acquire(key_for("old-free"), "jid-1", 10_000)
        end
      end

      def test_reports_the_holding_jid_on_redis_below_seven
        key = key_for("old-taken")

        with_redis_62 do
          Acquirer.try_acquire(key, "jid-1", 10_000)
          held = Acquirer.try_acquire(key, "jid-2", 10_000)

          assert_predicate held, :held?
          assert_equal "jid-1", held.jid
        end
      end

      private

        def key_for(name)
          Key.new("class" => "AcquirerTestJob", "queue" => "default", "args" => [name])
        end

        def flush_lock_keys
          Sidekiq.redis do |conn|
            keys = conn.call("KEYS", "#{Locking.redis_key_prefix}*")
            conn.del(*keys) if keys.any?
          end
        end

        # Routes every Sidekiq.redis checkout through the 6.2 emulator.
        def with_redis_62
          connection = nil
          Sidekiq.redis { |conn| connection = conn }
          emulated = Redis62Connection.new(connection)

          singleton = Sidekiq.singleton_class
          original = singleton.instance_method(:redis)
          singleton.send(:define_method, :redis) { |&block| block.call(emulated) }

          yield
        ensure
          singleton.send(:define_method, :redis, original)
        end
    end
  end
end
