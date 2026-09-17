# frozen_string_literal: true

require "test_helper"

module Sidekiq
  class LockingTest < Minitest::Test
    class PlainJob
      include Sidekiq::Job
    end

    class CustomArgsJob
      include Sidekiq::Job

      def self.lock_args(job)
        first_arg = job["args"].first
        job["args"] << "mutated-inside-callback"
        [first_arg]
      end
    end

    class BadArgsJob
      include Sidekiq::Job

      def self.lock_args(_job)
        "not an array"
      end
    end

    class WrappedJob
      def self.lock_args(job)
        [job["args"].first]
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

    def flush_lock_keys
      Sidekiq.redis do |conn|
        keys = conn.call("KEYS", "#{Locking.redis_key_prefix}*")
        conn.del(*keys) if keys.any?
      end
    end

    def test_key_keeps_plain_sidekiq_job_class_queue_and_args
      job = {
        "class" => PlainJob.name,
        "queue" => "mailers",
        "args" => ["tenant-1", 42]
      }

      key = Locking::Key.new(job)

      assert_equal [PlainJob.name, "mailers", ["tenant-1", 42]], key.context
    end

    def test_key_unwraps_active_job_adapter_wrapper
      job = {
        "class" => "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
        "wrapped" => "RealAJ",
        "queue" => "default",
        "args" => [{ "arguments" => [1, 2, 3] }]
      }

      key = Locking::Key.new(job)

      assert_equal ["RealAJ", "default", [1, 2, 3]], key.context
    end

    def test_key_unwraps_modern_sidekiq_active_job_wrapper
      job = {
        "class" => "Sidekiq::ActiveJob::Wrapper",
        "wrapped" => "RealAJ",
        "queue" => "default",
        "args" => [{ "arguments" => [42] }]
      }

      key = Locking::Key.new(job)

      assert_equal ["RealAJ", "default", [42]], key.context
    end

    def test_key_uses_lock_args_when_defined
      job = { "class" => CustomArgsJob.name, "queue" => "default", "args" => [1, "junk"] }

      key = Locking::Key.new(job)

      assert_equal [CustomArgsJob.name, "default", [1]], key.context
    end

    def test_key_does_not_mutate_real_args_even_if_lock_args_does
      job = { "class" => CustomArgsJob.name, "queue" => "default", "args" => [1, "junk"] }

      Locking::Key.new(job)

      assert_equal [1, "junk"], job["args"]
    end

    def test_key_passes_unwrapped_active_job_arguments_to_lock_args
      job = {
        "class" => "Sidekiq::ActiveJob::Wrapper",
        "wrapped" => WrappedJob.name,
        "queue" => "default",
        "args" => [{ "arguments" => ["dedupe-me", "ignore-me"] }]
      }

      key = Locking::Key.new(job)

      assert_equal [WrappedJob.name, "default", ["dedupe-me"]], key.context
    end

    def test_key_raises_when_lock_args_returns_non_array
      job = { "class" => BadArgsJob.name, "queue" => "default", "args" => [1] }

      assert_raises(TypeError) { Locking::Key.new(job) }
    end

    def test_key_uses_configurable_redis_prefix
      Locking.redis_key_prefix = "custom:prefix:"
      job = { "class" => PlainJob.name, "queue" => "default", "args" => [1] }

      key = Locking::Key.new(job)

      assert_match(/^custom:prefix:/, key.redis_key)
    end

    def test_release_is_no_op_without_token
      # Releaser.release returns nil and makes no Redis call when either the
      # digest or the jid is missing.
      assert_nil Locking::Releaser.release(nil, "abc")
      assert_nil Locking::Releaser.release("abc", nil)
    end

    def test_release_only_releases_when_jid_matches
      digest = "deadbeef"
      Sidekiq.redis { |conn| conn.set("#{Locking.redis_key_prefix}#{digest}", "winner-jid") }

      Locking::Releaser.release(digest, "imposter-jid")
      assert_equal "winner-jid", Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }

      Locking::Releaser.release(digest, "winner-jid")
      assert_nil Sidekiq.redis { |conn| conn.get("#{Locking.redis_key_prefix}#{digest}") }
    end
  end
end
