# frozen_string_literal: true

module Sidekiq
  module Locking
    # Claims a lock with `SET key <jid> NX PX <ttl>` plus the GET option — the
    # check-and-set lock recipe from the Redis SET docs
    # (https://redis.io/commands/set/). The acquiring job's JID is stored as the
    # value so the release can later be guarded by ownership.
    module Acquirer
      Held = Struct.new(:jid) do
        def held?
          true
        end
      end

      class << self
        def try_acquire(key, jid, ttl_ms, redis_pool = nil)
          setter = ->(conn) { conn.set(key.redis_key, jid, "get", "nx", "px", ttl_ms) }
          holder = redis_pool ? redis_pool.with(&setter) : Sidekiq.redis(&setter)

          holder ? Held.new(holder) : :acquired
        end
      end
    end
  end
end
