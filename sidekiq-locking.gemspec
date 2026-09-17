# frozen_string_literal: true

require_relative "lib/sidekiq/locking/version"

Gem::Specification.new do |spec|
  spec.name = "sidekiq-locking"
  spec.version = Sidekiq::Locking::VERSION
  spec.authors = ["Vishnu M"]
  spec.email = ["vishnu.m@bigbinary.com"]

  spec.summary = "Best-effort, TTL-bounded enqueue deduplication for Sidekiq jobs: " \
                 "drop duplicate enqueues of the same job while a lock is held."
  spec.description = <<~DESC
    sidekiq-locking keeps only the first copy of a job in Redis while a
    short-lived lock is active. A duplicate enqueue for the same lock context
    (class, queue, args by default) is skipped until the original job succeeds
    or the lock_for TTL expires — whichever comes first. It is deliberately
    best-effort enqueue coalescing, not a correctness primitive or a runtime
    mutex: jobs must still be idempotent and protect true uniqueness with
    database constraints/locks where required. Opt a job in with
    `sidekiq_options lock_for: 5.minutes`; customize the dedup scope with a
    `lock_args` class method. No Rails or ActiveSupport required.
  DESC
  spec.homepage = "https://github.com/neetozone/sidekiq-locking"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.1"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "sidekiq", ">= 7.0"
end
