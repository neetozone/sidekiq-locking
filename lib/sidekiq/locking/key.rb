# frozen_string_literal: true

require "digest/sha2"
require "json"

module Sidekiq
  module Locking
    # Value object for a lock key. Builds the uniqueness tuple (job class, queue,
    # args) from the Sidekiq payload and hashes it into the Redis key shared by
    # the acquirer and releaser. The hash encoding (SHA-256 hex over a JSON dump
    # of the tuple) is an internal implementation detail — it only has to be
    # stable and collision-resistant for a given tuple.
    class Key
      ACTIVE_JOB_WRAPPERS = [
        "Sidekiq::ActiveJob::Wrapper",
        "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper"
      ].freeze

      attr_reader :job, :klass, :queue, :args, :context, :digest

      def initialize(job)
        @job = job
        @klass = job["wrapped"] || job["class"]
        @queue = job["queue"]
        @args = resolved_args
        @context = [klass, queue, args]
        @digest = Digest::SHA256.hexdigest(JSON.generate(context))
      end

      def redis_key
        "#{Locking.redis_key_prefix}#{digest}"
      end

      private

        def resolved_args
          job_class = constantized_job_class
          return default_args unless job_class&.respond_to?(:lock_args)

          scratch = job.merge("class" => klass, "args" => copy_args(default_args))
          result = job_class.lock_args(scratch)
          unless result.is_a?(Array)
            raise TypeError, "#{job_class.name}.lock_args must return an Array (got #{result.class})"
          end

          result
        end

        def default_args
          if ACTIVE_JOB_WRAPPERS.include?(job["class"])
            job.dig("args", 0, "arguments") || []
          else
            job["args"] || []
          end
        end

        def constantized_job_class
          Object.const_get(klass)
        rescue NameError
          nil
        end

        def copy_args(value)
          value.respond_to?(:dup) ? value.dup : value
        end
    end
  end
end
