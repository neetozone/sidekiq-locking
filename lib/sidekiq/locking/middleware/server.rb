# frozen_string_literal: true

module Sidekiq
  module Locking
    module Middleware
      # Releases the lock around perform.
      #
      #   release_lock: :after_perform (default) — release after successful
      #     perform. Errored jobs keep the lock through retries until success or
      #     death.
      #   release_lock: :before_perform — release just before perform begins.
      class Server
        def call(_worker_class, job, _queue)
          return yield unless locked?(job)

          if release_before_perform?(job)
            release(job)
            yield
          else
            yield
            release(job)
          end
        end

        private

          def locked?(job)
            job[LOCK_FOR_KEY] && job[LOCK_FOR_KEY].to_i >= 0 && job[TOKEN_KEY]
          end

          def release_before_perform?(job)
            job.fetch(RELEASE_LOCK_KEY, RELEASE_AFTER_PERFORM).to_s == RELEASE_BEFORE_PERFORM
          end

          def release(job)
            Releaser.release(job[TOKEN_KEY], job["jid"])
          end
      end
    end
  end
end
