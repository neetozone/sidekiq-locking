# frozen_string_literal: true

module Sidekiq
  module Locking
    # Deletes a lock only when the Redis value still equals the releasing job's
    # JID, so a late finisher cannot delete a newer lock acquired after the
    # original TTL expired. This compare-and-delete is the standard safe-release
    # pattern from the Redis SET docs (https://redis.io/commands/set/).
    module Releaser
      UNLOCK_SCRIPT = <<~LUA
        if redis.call('get', KEYS[1]) == ARGV[1] then
          redis.call('del', KEYS[1])
        end
      LUA

      class << self
        def release(digest, jid)
          return unless digest && jid

          Sidekiq.redis do |conn|
            conn.call("EVAL", UNLOCK_SCRIPT, 1, "#{Locking.redis_key_prefix}#{digest}", jid)
          end
        end
      end
    end
  end
end
