# frozen_string_literal: true

require "securerandom"

require "sidekiq"

# The suite talks to a real Redis. Point it at a disposable logical DB so a run
# never touches a development or production keyspace. Override with REDIS_URL.
redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/15")
Sidekiq.configure_client do |config|
  config.redis = { url: redis_url }
end
Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }
end

require "sidekiq-locking"

require "minitest/autorun"
require "mocha/minitest"
