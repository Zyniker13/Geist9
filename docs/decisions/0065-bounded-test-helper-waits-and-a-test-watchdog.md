# 0065 — Every test helper wait is bounded; test servers never block the cooperative pool

## Context

CI hung twice in the macOS `swift-test` phase after the
authorize-flow timeout fix (`8af579a`, green on 2026-11-23) — on `601f90c`
the phase printed nothing for 39 minutes until the job cap cancelled the
run. A local MailSyncTests helper hung the same way but reproduced only
intermittently (7 clean local runs before one hang), pointing at a
threading wedge rather than a deterministic bug.

An audit of every wait in the test helpers and production code found the
pattern whose sibling had already deadlocked `OAuthTestServer.stop()` once
(fixed in 71d0e48): blocking waits that can hold a Swift-concurrency
cooperative-pool thread while NIO work needs the pool to spawn its
event-loop threads. Found and fixed:

- `FakeIMAPServer.start()` bound with an unbounded `.bind(...).wait()` and
  `stop()` called `close().wait()` plus `syncShutdownGracefully()` — the
  exact pair that deadlocked the OAuth suite's server. This helper serves
  seven suites that run concurrently under `swift test --parallel`.
- `OAuthTestServer.start()` still bound with an unbounded `.wait()` (only
  its `stop()` had been fixed).
- `IngestPoolStarvationTests` documented a 10-second deadline but
  implemented an unbounded semaphore wait on a plain thread.

Production waits were checked and left alone: `OAuthAuthorizeFlow.start()`'s
bind completes on its own event-loop thread, and `awaitRedirect`'s
deadline race is covered by its own regression test.

## Decision

1. **Every test-helper wait is bounded.** `NonBlockingTestBootstrap.bind`
   runs the NIO bind on a plain worker thread and the caller waits on a
   semaphore with a deadline (10 s default): a bind that never completes
   throws `BindTimedOut` instead of parking the task forever. The helper's
   own suite pins the three outcomes: bound, the bind's own error, and
   timeout on a never-completing future.
2. **Test servers tear down without blocking.** `FakeIMAPServer.stop()`
   now fires the async close and `shutdownGracefully` instead of
   `close().wait()` + `syncShutdownGracefully()`, matching the
   `OAuthTestServer.stop()` shape proven in 71d0e48. `start()`/`stop()`
   stay synchronous so call sites (including `setUpWithError` and
   `defer`) do not change.
3. **`IngestPoolStarvationTests` actually enforces its deadline:** each
   hop's semaphore wait carries a 10-second timeout and the first expired
   wait throws `IngestHopTimedOut`, failing the test at the deadline.
4. **`scripts/check.sh` runs the Swift test phase with a watchdog:** if
   `swift test --parallel` outlasts 20 minutes (3× the normal ~7-minute
   full run), the script prints which phase hung, sends SIGTERM to the
   test process tree, records a `swift-test watchdog` step-summary
   annotation, and fails the phase. The CI job caps stay as the outer
   bound; this turns a silent 30/45-minute cap into a named, logged
   failure in minutes.

## Consequences

- A hanging helper now fails a test in seconds (timeout) or names the
  phase in minutes (watchdog) instead of eating the job cap with no
  output.
- The watchdog bound is generous by design: it catches hangs, not slow
  runs. If a legitimate suite outgrows it, raise it in the same commit
  that shows the new timing.
- Binding on a helper thread means one extra thread per server start for
  its duration (milliseconds); irrelevant to suite time.
- `swift test --parallel` remains the executor; per-test timeouts in the
  runner are not available for XCTest cases, so the deadline lives in the
  helpers and the watchdog.
