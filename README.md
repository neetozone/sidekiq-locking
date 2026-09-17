# sidekiq-locking

Best-effort, **TTL-bounded enqueue deduplication** for Sidekiq jobs — drop
duplicate enqueues of the same job while a short-lived lock is held, **without a
database or a runtime mutex**.

If application code enqueues the same work repeatedly — a webhook storm, a
fan-out that re-triggers the same sync, a retry loop upstream — only the first
copy is kept in Redis while the lock is active. A duplicate is skipped when it
matches the same lock context: `(class, queue, args)` by default.

This is intentionally **best-effort deduplication, not a correctness primitive.**
It is not a distributed lock and not a runtime mutex: two copies can still run
concurrently if the TTL expires before the first finishes. Jobs must stay
idempotent, and business-critical uniqueness should be protected with database
constraints, row locks, or advisory locks.

> **Naming.** The gem is `sidekiq-locking` and the namespace is `Sidekiq::Locking`,
> with a `lock_for` DSL. The word "lock" somewhat overclaims — this is
> best-effort, TTL-bounded enqueue *deduplication*, not a true mutex. The name
> and DSL are kept stable for now and may be revisited.

## Installation

```ruby
gem "sidekiq-locking"
```

```sh
bundle install
```

Requires Ruby >= 3.1 and Sidekiq >= 7.0. The gem depends only on `sidekiq` — no
Rails or ActiveSupport required.

## Quick start

Install the middleware once, in the host application's Sidekiq initializer:

```ruby
# config/initializers/sidekiq.rb
require "sidekiq-locking"

Sidekiq::Locking.install! unless Rails.env.test?
```

`install!` registers the client middleware (acquires the lock and skips
duplicate pushes), the server middleware (releases the lock around `perform`),
and a death handler (releases the lock when a job is discarded). Disabling it in
test keeps tests deterministic and avoids locks leaking between examples.

Then opt a job in with a lock window:

```ruby
class SyncAddressJob
  include Sidekiq::Job

  sidekiq_options lock_for: 5.minutes

  def perform(user_id)
    # sync user address
  end
end
```

A second `SyncAddressJob` with the same queue and args cannot be enqueued while
the first lock is active. The lock is released when the job succeeds, or when
`lock_for` expires — whichever happens first. Keep `lock_for` short; a window
longer than a few minutes usually means the job wants stronger application-level
concurrency control.

## Lock context

By default jobs are deduplicated by `[class, queue, args]`, so the same job
class with the same args can still be enqueued on different queues:

```ruby
SyncAddressJob.set(queue: "default").perform_async(1)
SyncAddressJob.set(queue: "low").perform_async(1) # different lock — queue differs
```

### Custom lock args

Use a `lock_args(job)` class method when only part of the args should
participate in the lock key. It must return an `Array`; if it is absent, the
full args array is used.

```ruby
class RefreshAccountCacheJob
  include Sidekiq::Job

  sidekiq_options lock_for: 5.minutes

  # Only account_id participates in the lock; the reason arg is ignored.
  def self.lock_args(job)
    [job["args"].first]
  end

  def perform(account_id, reason = nil)
    # refresh account cache
  end
end

# These two share one lock:
RefreshAccountCacheJob.perform_async(42, "user_updated")
RefreshAccountCacheJob.perform_async(42, "manual_refresh")
```

### ActiveJob

`Sidekiq::Locking` unwraps Sidekiq's ActiveJob wrapper and keys on the wrapped job
class plus the real ActiveJob arguments. A wrapped job that defines
`lock_args(job)` receives the unwrapped args.

## Scheduled jobs

Scheduled jobs include the delay in the lock TTL. With `lock_for: 10.minutes`:

```ruby
SyncAddressJob.set(wait: 1.hour).perform_async(1)
```

the lock lasts ~70 minutes total (the one-hour delay plus the ten-minute
window), so a duplicate cannot be enqueued for that full period unless the
original runs and releases the lock earlier.

## Retries and the unlock policy

`release_lock` controls when the lock is released.

- **`:after_perform` (default)** — release only after `perform` returns
  successfully. A failed job keeps its lock while it waits to retry, so a
  transient failure does not let a duplicate slip in. The lock clears on
  success, on death (via the death handler), or on TTL expiry.

  ```ruby
  sidekiq_options lock_for: 5.minutes, release_lock: :after_perform
  ```

- **`:before_perform`** — release immediately before the job starts running.
  Use this only when it is acceptable for another copy to be enqueued while the
  current job is still executing.

  ```ruby
  sidekiq_options lock_for: 5.minutes, release_lock: :before_perform
  ```

If the TTL expires while a job is still retrying, a duplicate can be enqueued.
Design jobs with that best-effort behavior in mind.

## Per-enqueue overrides

Use Sidekiq's `set` API to disable or override the lock for one enqueue:

```ruby
SyncAddressJob.set(lock_for: false).perform_async(1)      # no lock this time
SyncAddressJob.set(lock_for: 30.seconds).perform_async(1) # shorter window
SyncAddressJob.set(lock_for: 10.minutes).perform_async(1) # longer window
```

## Return value on a duplicate enqueue

A duplicate enqueue does not return a JID because the job was never pushed.
Through Sidekiq's public `perform_async` API this is observed as `nil`:

```ruby
SyncAddressJob.perform_async(1) # => "abc123..."
SyncAddressJob.perform_async(1) # => nil   (duplicate, lock held)
```

Do not rely on `perform_async` always returning a JID for lockable jobs. Each
skipped duplicate is logged at info level —
`Skipping enqueue for <Class>, lock held by JID <jid>`.

## Redis key prefix

Each active lock is one Redis string at `sidekiq:locking:<digest>`, whose value is
the owning job's JID (releases are JID-guarded so a late finisher cannot delete
a newer lock). The prefix is configurable:

```ruby
Sidekiq::Locking.redis_key_prefix = "my-app:sidekiq:locking:"
```

## How it works

```text
perform_async
  → client middleware builds a lock key from (class, queue, args)
  → Redis: SET sidekiq:locking:<digest> <jid> NX PX <ttl_ms>
              (plus a GET of the holder when the claim loses, in one script)

  Acquired (key was new):
    → stamp job["lock_token"] = digest, push the job
    → server middleware releases the lock on success (per release_lock)
    → death handler releases the lock if the job is discarded

  Already held:
    → do not push; perform_async returns nil; log the skip
```

If a *downstream* client middleware aborts the push by returning `false` (for
example a blackhole route from
[sidekiq-routing](https://github.com/neetozone/sidekiq-routing)), the lock
middleware releases the lock it just acquired so the next identical enqueue is
not blocked until the TTL. When composing with other client middleware, the
lock middleware should run **before** any middleware that may abort the push.

## Caveats

- Locks are best-effort and TTL-bounded; jobs must remain idempotent.
- This is enqueue deduplication, not execution-time mutual exclusion — if the
  TTL expires while a job is still running or retrying, another copy can be
  enqueued.
- Duplicate jobs are dropped, not rescheduled or replaced.
- There is no Web UI, lock browser, or stale-lock reaper — the TTL is the safety
  mechanism.
- `release_lock: :before_perform` allows duplicates while the job is running.
- Manually deleting jobs from Sidekiq queues may leave the lock in Redis until
  the TTL expires.
- The lock adds one Redis round-trip before each push; if Redis is unavailable,
  enqueue can fail with a Redis/network error.

## License

Released under the [MIT License](LICENSE).
