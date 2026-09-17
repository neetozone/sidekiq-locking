# frozen_string_literal: true

require "test_helper"
require "sidekiq/api"

# End-to-end verification of the public Sidekiq::Locking DSL through the REAL enqueue
# path. `install!` registers the client middleware on the live Sidekiq config and
# then `perform_async` / `perform_in` / `set` exercise every documented option
# against a real Redis. The middleware unit tests drive the middleware object
# directly; this file proves the public wiring (install! + sidekiq_options) really
# deduplicates real enqueues.
module Sidekiq
  module Locking
    # Register the client middleware once, on the real Sidekiq client config.
    Locking.install!

    class IntegrationTest < Minitest::Test
      QUEUE = "lock_integration"

      class DefaultJob
        include Sidekiq::Job
        sidekiq_options queue: QUEUE, lock_for: 600
        def perform(*); end
      end

      class CustomArgsJob
        include Sidekiq::Job
        sidekiq_options queue: QUEUE, lock_for: 600

        def self.lock_args(job)
          [job["args"].first]
        end

        def perform(*); end
      end

      class NoLockJob
        include Sidekiq::Job
        sidekiq_options queue: QUEUE
        def perform(*); end
      end

      def setup
        @original_prefix = Locking.redis_key_prefix
        Locking.redis_key_prefix = "test:int:#{SecureRandom.hex(6)}:"
        clear!
      end

      def teardown
        clear!
        Locking.redis_key_prefix = @original_prefix
      end

      def clear!
        Sidekiq.redis do |conn|
          keys = conn.call("KEYS", "#{Locking.redis_key_prefix}*")
          conn.del(*keys) if keys.any?
        end
        Sidekiq::Queue.new(QUEUE).clear
        Sidekiq::ScheduledSet.new.each { |entry| entry.delete if entry.item["queue"] == QUEUE }
      end

      def queue_size
        Sidekiq::Queue.new(QUEUE).size
      end

      # ---- install! wired the client middleware onto the real chain ----

      def test_install_registered_the_client_middleware
        klasses = Sidekiq.default_configuration.client_middleware.entries.map(&:klass)
        assert_includes klasses, Middleware::Client
      end

      # ---- enqueue-time dedup via the public perform_async ----

      def test_perform_async_pushes_first_and_drops_duplicate
        jid1 = DefaultJob.perform_async("alpha")
        refute_nil jid1, "first enqueue should return a jid"
        assert_equal 1, queue_size

        jid2 = DefaultJob.perform_async("alpha")
        assert_nil jid2, "duplicate enqueue should be dropped (perform_async returns nil)"
        assert_equal 1, queue_size, "queue should still hold a single job"
      end

      def test_distinct_args_enqueue_independently
        refute_nil DefaultJob.perform_async("a")
        refute_nil DefaultJob.perform_async("b")
        assert_equal 2, queue_size
      end

      # ---- lock_args narrows the dedup scope ----

      def test_custom_lock_args_narrows_the_dedup_scope
        refute_nil CustomArgsJob.perform_async(1, "reason-x")
        assert_nil CustomArgsJob.perform_async(1, "reason-y"), "same first arg → deduped"
        refute_nil CustomArgsJob.perform_async(2, "reason-z"), "different first arg → independent"
        assert_equal 2, queue_size
      end

      # ---- opting out: lock_for: false and no lock_for at all ----

      def test_per_enqueue_set_can_disable_the_lock
        refute_nil DefaultJob.set(lock_for: false).perform_async("dup")
        refute_nil DefaultJob.set(lock_for: false).perform_async("dup")
        assert_equal 2, queue_size
      end

      def test_job_without_lock_for_is_never_deduped
        refute_nil NoLockJob.perform_async("x")
        refute_nil NoLockJob.perform_async("x")
        assert_equal 2, queue_size
      end

      # ---- scheduled enqueue folds the delay into the TTL ----

      def test_perform_in_folds_the_delay_into_the_lock_ttl
        DefaultJob.perform_in(3600, "scheduled")
        ttl_ms = Sidekiq.redis do |conn|
          key = conn.call("KEYS", "#{Locking.redis_key_prefix}*").first
          conn.pttl(key)
        end
        # 3600s delay + 600s lock window ≈ 4200s, comfortably above the 1h delay.
        assert_operator ttl_ms, :>, 3_600_000, "scheduled delay should extend the lock TTL"
        assert_operator ttl_ms, :<, 4_300_000
      end

      # ---- full lifecycle: release after a successful perform frees the lock ----

      def test_lock_released_after_successful_perform_allows_reenqueue
        jid = DefaultJob.perform_async("cycle")
        item = Sidekiq::Queue.new(QUEUE).find_job(jid).item
        assert_nil DefaultJob.perform_async("cycle"), "still locked → duplicate dropped"

        # Default release policy (:after_perform): release on successful perform.
        Middleware::Server.new.call(DefaultJob, item, QUEUE) { :ok }

        refute_nil DefaultJob.perform_async("cycle"),
          "after the lock is released, an identical enqueue acquires again"
      end
    end
  end
end
