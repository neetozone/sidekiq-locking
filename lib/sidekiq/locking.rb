# frozen_string_literal: true

require "sidekiq"

# Sidekiq::Locking — best-effort, TTL-bounded deduplication of Sidekiq enqueues.
#
# While a lock is held for a job, a second enqueue of the same job is dropped.
# Treat it as a pruning convenience, never a guarantee — the lock expires on a
# TTL and the check is inherently racy, so keep jobs idempotent and enforce real
# uniqueness in your datastore.
#
# The Redis building blocks used here — a token-valued `SET ... NX PX` to claim
# the lock and a compare-and-delete to release it — are the standard recipes from
# the Redis SET documentation (https://redis.io/commands/set/).
#
# Opt a job in with a lock window, and optionally narrow the dedup scope:
#
#   # config/initializers/sidekiq.rb
#   Sidekiq::Locking.install! unless Rails.env.test?
#
#   class MyJob
#     include Sidekiq::Job
#     sidekiq_options lock_for: 5.minutes
#
#     def self.lock_args(job)
#       [job["args"].first]
#     end
#   end
module Sidekiq
  module Locking
    LOCK_FOR_KEY = "lock_for"
    RELEASE_LOCK_KEY = "release_lock"
    TOKEN_KEY = "lock_token"

    RELEASE_AFTER_PERFORM = "after_perform"
    RELEASE_BEFORE_PERFORM = "before_perform"

    DEFAULT_REDIS_KEY_PREFIX = "sidekiq:locking:"

    class << self
      attr_writer :redis_key_prefix

      def redis_key_prefix
        @redis_key_prefix || DEFAULT_REDIS_KEY_PREFIX
      end

      # Registers the client + server middleware on both client and server
      # configurations, plus a death handler so dead jobs release their lock.
      def install!
        Sidekiq.configure_client do |config|
          config.client_middleware do |chain|
            chain.add Middleware::Client
          end
          # ensure `perform_inline` releases locks too
          config.server_middleware do |chain|
            chain.add Middleware::Server
          end
        end

        Sidekiq.configure_server do |config|
          config.client_middleware do |chain|
            chain.add Middleware::Client
          end
          config.server_middleware do |chain|
            chain.add Middleware::Server
          end
          config.death_handlers << ->(job, _ex) do
            Releaser.release(job[TOKEN_KEY], job["jid"]) if job[TOKEN_KEY]
          end
        end
      end
    end
  end
end

require "sidekiq/locking/key"
require "sidekiq/locking/acquirer"
require "sidekiq/locking/releaser"
require "sidekiq/locking/middleware/client"
require "sidekiq/locking/middleware/server"
