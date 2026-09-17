# frozen_string_literal: true

module Sidekiq
  module Locking
    # Claims a lock with `SET key <jid> NX PX <ttl>`, falling back to a `GET` of
    # the current holder when the claim loses — the check-and-set lock recipe
    # from the Redis SET docs (https://redis.io/commands/set/). The acquiring
    # job's JID is stored as the value so the release can later be guarded by
    # ownership.
    #
    # Claim and read-back run inside one script so the pair stays atomic. They
    # are deliberately not folded into a single `SET ... NX GET`: Redis only
    # accepts the GET option alongside NX from 7.0 onward, and older servers
    # answer "ERR syntax error".
    module Acquirer
      ACQUIRE_SCRIPT = <<~LUA
        if redis.call('set', KEYS[1], ARGV[1], 'nx', 'px', ARGV[2]) then
          return false
        end
        return redis.call('get', KEYS[1])
      LUA

      Held = Struct.new(:jid) do
        def held?
          true
        end
      end

      class << self
        def try_acquire(key, jid, ttl_ms, redis_pool = nil)
          setter = ->(conn) { conn.call("EVAL", ACQUIRE_SCRIPT, 1, key.redis_key, jid, ttl_ms) }
          holder = redis_pool ? redis_pool.with(&setter) : Sidekiq.redis(&setter)

          holder ? Held.new(holder) : :acquired
        end
      end
    end
  end
end
