# frozen_string_literal: true

module Sidekiq
  module Locking
    module Middleware
      # Acquires the lock before push. Skips the push (returns false) if a lock
      # is already held for the same (class, queue, lock_args) tuple.
      #
      # Scheduled jobs (`perform_in`) include their delay in the TTL: a job
      # scheduled an hour out with `lock_for: 10.minutes` holds the lock for 70
      # minutes total.
      class Client
        def call(_worker_class, job, _queue, redis_pool = nil)
          return yield unless lockable?(job)

          expiry_ms = expiry_for(job)
          if expiry_ms <= 0
            Sidekiq.logger.info("Skipping lock for #{job["class"]}/#{job["jid"]}: lock window ends in the past")
            return yield
          end

          key = Key.new(job)
          result = Acquirer.try_acquire(key, job["jid"], expiry_ms, redis_pool)

          if result == :acquired
            job[TOKEN_KEY] = key.digest
            pushed = yield
            # If a downstream middleware aborted the push (e.g. Sidekiq::Routing's
            # blackhole returns false) the job never reaches Redis but our lock
            # is held. Release it so the next identical enqueue isn't blocked
            # until the TTL expires.
            Releaser.release(key.digest, job["jid"]) if pushed == false
            pushed
          else
            klass = job["wrapped"] || job["class"]
            Sidekiq.logger.info { "Skipping enqueue for #{klass}, lock held by JID #{result.jid}" }
            false
          end
        end

        private

          def lockable?(job)
            job[LOCK_FOR_KEY] && !job.key?(TOKEN_KEY) && job[LOCK_FOR_KEY].to_i >= 0
          end

          # How long the lock should live, in milliseconds. The base window is
          # `lock_for` seconds; a scheduled job ("at" in the future) stays locked
          # until it actually runs, so the remaining delay is added on top.
          # Immediate jobs carry no delay.
          def expiry_for(job)
            window_seconds = job[LOCK_FOR_KEY].to_i
            run_at = job["at"]
            delay_seconds = run_at ? run_at - Time.now.to_f : 0.0

            ((window_seconds + delay_seconds) * 1000).to_i
          end
      end
    end
  end
end
