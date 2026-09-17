# frozen_string_literal: true

require "test_helper"

module Sidekiq
  module Locking
    module Middleware
      class ServerTest < Minitest::Test
        def setup
          @original_prefix = Locking.redis_key_prefix
          Locking.redis_key_prefix = Locking::DEFAULT_REDIS_KEY_PREFIX
          flush_lock_keys
          @middleware = Server.new
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

        def seed_lock(jid)
          digest = "test-#{SecureRandom.hex(4)}"
          Sidekiq.redis { |conn| conn.set("#{Locking.redis_key_prefix}#{digest}", jid) }
          digest
        end

        def test_yields_unchanged_when_job_has_no_lock_for
          job = { "jid" => "abc", "args" => [] }
          yielded = false

          @middleware.call(nil, job, "default") { yielded = true }

          assert yielded
        end

        def test_yields_unchanged_when_job_has_no_token
          job = { "jid" => "abc", Locking::LOCK_FOR_KEY => 600, "args" => [] }
          yielded = false

          @middleware.call(nil, job, "default") { yielded = true }

          assert yielded
        end

        def test_negative_lock_for_yields_without_releasing_existing_lock
          jid = "winner-negative"
          digest = seed_lock(jid)
          job = {
            "jid" => jid,
            Locking::LOCK_FOR_KEY => -1,
            Locking::TOKEN_KEY => digest
          }
          yielded = false

          @middleware.call(nil, job, "default") { yielded = true }

          assert yielded
          assert_equal jid, Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }
        end

        def test_default_policy_releases_lock_after_successful_perform
          jid = "winner-1"
          digest = seed_lock(jid)
          job = {
            "jid" => jid,
            Locking::LOCK_FOR_KEY => 600,
            Locking::TOKEN_KEY => digest
          }

          @middleware.call(nil, job, "default") { :ok }

          assert_nil Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }
        end

        def test_default_policy_retains_lock_when_perform_raises
          jid = "winner-2"
          digest = seed_lock(jid)
          job = {
            "jid" => jid,
            Locking::LOCK_FOR_KEY => 600,
            Locking::TOKEN_KEY => digest
          }

          assert_raises(RuntimeError) do
            @middleware.call(nil, job, "default") { raise "boom" }
          end

          assert_equal jid, Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }
        end

        def test_before_perform_policy_releases_lock_before_perform
          jid = "winner-3"
          digest = seed_lock(jid)
          job = {
            "jid" => jid,
            Locking::LOCK_FOR_KEY => 600,
            Locking::RELEASE_LOCK_KEY => :before_perform,
            Locking::TOKEN_KEY => digest
          }

          observed_during_perform = nil
          @middleware.call(nil, job, "default") do
            observed_during_perform = Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }
          end

          assert_nil observed_during_perform, "lock should be gone before perform begins"
        end

        def test_before_perform_policy_does_not_re_lock_after_perform
          jid = "winner-4"
          digest = seed_lock(jid)
          job = {
            "jid" => jid,
            Locking::LOCK_FOR_KEY => 600,
            Locking::RELEASE_LOCK_KEY => "before_perform",
            Locking::TOKEN_KEY => digest
          }

          @middleware.call(nil, job, "default") { :ok }

          assert_nil Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }
        end

        def test_before_perform_policy_does_not_recreate_lock_when_perform_raises
          jid = "winner-5"
          digest = seed_lock(jid)
          job = {
            "jid" => jid,
            Locking::LOCK_FOR_KEY => 600,
            Locking::RELEASE_LOCK_KEY => "before_perform",
            Locking::TOKEN_KEY => digest
          }

          assert_raises(RuntimeError) do
            @middleware.call(nil, job, "default") { raise "boom" }
          end

          assert_nil Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }
        end
      end
    end
  end
end
