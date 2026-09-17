# frozen_string_literal: true

require "sidekiq/locking/version"

# Sidekiq::Locking: TTL-bounded, best-effort enqueue deduplication for Sidekiq jobs.
#
# Defines Sidekiq::Locking and its public API (install!, redis_key_prefix). The
# module file requires its own collaborators (Key, Acquirer, Releaser, and the
# client/server middleware), so requiring it here loads the whole subsystem.
#
# The per-job DSL (`lock_for`, `release_lock`, `lock_args`) is unchanged. "Lock"
# somewhat overclaims: this is best-effort dedup, not a runtime mutex (see README).
require "sidekiq/locking"
