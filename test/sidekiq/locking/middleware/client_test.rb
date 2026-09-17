# frozen_string_literal: true

require "test_helper"

module Sidekiq
  module Locking
    module Middleware
      class ClientTest < Minitest::Test
        class ClientJob
          include Sidekiq::Job
        end

        class ArgsJob
          include Sidekiq::Job

          def self.lock_args(job)
            [job["args"].first]
          end
        end

        def setup
          @original_prefix = Locking.redis_key_prefix
          Locking.redis_key_prefix = Locking::DEFAULT_REDIS_KEY_PREFIX
          flush_lock_keys
          @middleware = Client.new
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

        def call(job, queue = "default", worker_class: ClientJob, redis_pool: nil)
          yielded = false
          result = @middleware.call(worker_class, job, queue, redis_pool) { yielded = true }
          [result, yielded]
        end

        def base_job(overrides = {})
          {
            "class" => ClientJob.name,
            "queue" => "default",
            "args" => [1, 2, 3],
            "jid" => SecureRandom.hex(12)
          }.merge(overrides)
        end

        def test_job_without_lock_for_yields_unchanged
          job = base_job

          _result, yielded = call(job)

          assert yielded
          assert_nil job[Locking::TOKEN_KEY]
        end

        def test_false_lock_for_skips_locking
          job = base_job(Locking::LOCK_FOR_KEY => false)

          _result, yielded = call(job)

          assert yielded
          assert_nil job[Locking::TOKEN_KEY]
        end

        def test_negative_lock_for_skips_locking
          job = base_job(Locking::LOCK_FOR_KEY => -1)

          _result, yielded = call(job)

          assert yielded
          assert_nil job[Locking::TOKEN_KEY]
        end

        def test_first_push_acquires_lock_and_stamps_token
          job = base_job(Locking::LOCK_FOR_KEY => 600)

          _result, yielded = call(job)

          assert yielded
          refute_nil job[Locking::TOKEN_KEY]
          assert_equal job["jid"], Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{job[Locking::TOKEN_KEY]}") }
        end

        def test_duplicate_push_returns_false_and_does_not_yield
          first = base_job(Locking::LOCK_FOR_KEY => 600)
          call(first)

          second = base_job(Locking::LOCK_FOR_KEY => 600)
          result, yielded = call(second)

          assert_equal false, result
          refute yielded
          assert_nil second[Locking::TOKEN_KEY]
        end

        def test_custom_lock_args_controls_duplicate_scope
          first = base_job(
            "class" => ArgsJob.name,
            "args" => [1, "first"],
            Locking::LOCK_FOR_KEY => 600
          )
          call(first, worker_class: ArgsJob)

          second = base_job(
            "class" => ArgsJob.name,
            "args" => [1, "second"],
            Locking::LOCK_FOR_KEY => 600
          )
          result, yielded = call(second, worker_class: ArgsJob)

          assert_equal false, result
          refute yielded
        end

        def test_different_args_get_independent_locks
          first = base_job(Locking::LOCK_FOR_KEY => 600, "args" => [1])
          call(first)

          second = base_job(Locking::LOCK_FOR_KEY => 600, "args" => [2])
          _result, yielded = call(second)

          assert yielded
        end

        def test_already_locked_payload_is_passed_through
          # A retry re-enters the chain with TOKEN_KEY already set; we must not
          # try to re-acquire and we must yield.
          job = base_job(Locking::LOCK_FOR_KEY => 600, Locking::TOKEN_KEY => "existing-digest")

          _result, yielded = call(job)

          assert yielded
        end

        def test_scheduled_jobs_include_delay_in_ttl
          at = Time.now.to_f + 3600
          job = base_job(Locking::LOCK_FOR_KEY => 600, "at" => at)

          _result, yielded = call(job)

          assert yielded
          ttl_ms = Sidekiq.redis { |conn| conn.pttl("#{Locking.redis_key_prefix}#{job[Locking::TOKEN_KEY]}") }
          # at + 600 ~= now + 4200 → > 1h (3.6e6 ms) but < 1.5h (5.4e6 ms)
          assert_operator ttl_ms, :>, 3_600_000
          assert_operator ttl_ms, :<, 5_400_000
        end

        def test_already_expired_at_yields_without_locking
          job = base_job(Locking::LOCK_FOR_KEY => 10, "at" => Time.now.to_f - 600)

          _result, yielded = call(job)

          assert yielded
          assert_nil job[Locking::TOKEN_KEY]
        end

        def test_releases_lock_when_downstream_middleware_aborts_the_push
          # If a later middleware (e.g. Sidekiq::Routing's blackhole) returns
          # false, the job never reaches Redis. Our lock must be released so the
          # next identical enqueue is not blocked until the TTL.
          job = base_job(Locking::LOCK_FOR_KEY => 600)

          result = @middleware.call(ClientJob, job, "default", nil) { false }

          assert_equal false, result
          digest = job[Locking::TOKEN_KEY]
          refute_nil digest
          assert_nil Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }
        end

        def test_does_not_release_lock_when_yield_returns_truthy
          job = base_job(Locking::LOCK_FOR_KEY => 600)

          @middleware.call(ClientJob, job, "default", nil) { "some-jid" }

          digest = job[Locking::TOKEN_KEY]
          assert_equal job["jid"], Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }
        end

        def test_does_not_release_lock_when_yield_returns_nil
          # nil is not an abort signal — only an explicit `false` is.
          job = base_job(Locking::LOCK_FOR_KEY => 600)

          @middleware.call(ClientJob, job, "default", nil) { nil }

          digest = job[Locking::TOKEN_KEY]
          assert_equal job["jid"], Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }
        end

        def test_uses_provided_redis_pool_to_acquire_lock
          pool_used = false
          redis_pool = Object.new
          redis_pool.define_singleton_method(:with) do |&block|
            pool_used = true
            Sidekiq.redis(&block)
          end
          job = base_job(Locking::LOCK_FOR_KEY => 600)

          _result, yielded = call(job, redis_pool: redis_pool)

          assert yielded
          assert pool_used
          assert_equal job["jid"], Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{job[Locking::TOKEN_KEY]}") }
        end
      end
    end
  end
end
