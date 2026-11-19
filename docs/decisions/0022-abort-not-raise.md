# 0022 — Crash simulation kills with abort(), not raise(SIGABRT)

Date: 2026-11-18

## Context

The CI Linux job went red while the trigram work landed: the benchmark
changes introduced Linux-only build errors (the `stdout` global, the
`rusage` argument), fixed in commits 6822c83 and 10fc3fc. Once the build
compiled again, commit 1b6ae48's run surfaced 20 failures across all 8
`KillTests` — every simulated-crash durability test on Linux.

Diagnosis, established with a small signal probe and a run of the real
tests in a `swift:6.2-noble` container:

- On Linux, the Swift runtime installs a one-shot handler for SIGABRT (the
  crash backtracer that prints "Program crashed"). The handler returns, so
  `raise(SIGABRT)` returns and the process keeps running; only a second
  SIGABRT kills (the handler has reset itself to the default disposition).
- On macOS, no such handler is installed and every `raise(SIGABRT)` kills
  the process with status 6, which is why the tests passed there.
- The kill tests therefore saw, on Linux only, a child that survived the
  simulated crash, finished the whole import, and exited 0 — and the
  durability assertions compared a fully-imported archive against the
  expected mid-crash snapshot.

## Decision

All simulated-crash kill points in the benchmark fixture
(`Sources/Benchmarks/main.swift`) call `abort()` instead of
`raise(SIGABRT)`. POSIX requires `abort()` to terminate even when SIGABRT is
caught, blocked, or ignored: glibc resets the disposition, unblocks the
signal, and re-raises. The default action of SIGABRT is unchanged — core
dump signal, indistinguishable from a power loss for fsync'd files — so the
tests' durability invariants are untouched.

## Consequences

- `KillTests` pass 8/8 on Linux (verified serially and with the CI's
  `--parallel` in a `swift:6.2-noble` container), and keep passing on macOS
  where `abort()` behaves the same as the old raise.
- The fixture's stdout line now says SIGABRT everywhere (one stale
  "sending SIGKILL" label fixed in passing).
- The `crashStage`/`killAfter` flags in `bench-search` remain the supported
  way to simulate crashes for durability tests; nothing in ArchiveCore
  changes, and the hook contract ("the hook may kill the process") is
  unchanged.
- The one-shot-backtracer behavior is a property of the Linux Swift
  runtime, not of this codebase; if a future runtime stops installing it,
  `abort()` remains correct on both platforms.
