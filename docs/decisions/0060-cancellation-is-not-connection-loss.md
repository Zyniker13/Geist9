# 0060 — A cancelled sync surfaces as cancellation, never as connection loss

Date: 2026-11-22

## Context

The M4 kill-mid-pass resume test (kill a sync pass by cancelling its task,
then verify the next pass resumes from the last checkpoint) needs to know
whether the pass was actually killed. When the task is cancelled, the
IMAP connection's channel closes with it, and the connection library
reports that as its own connection error. The engine mapped every
`IMAPConnection.Error` to `SyncEngineError.connectionLost`.

That mapping made a kill indistinguishable from a network drop: a caller
that cancels a pass to stop it saw "the connection was lost", and a test
could not assert the kill happened. The same laundering hid a second
failure mode on Linux, where a cancelled pass returned as if it had
completed normally.

## Decision

When a sync pass or connection test ends with a connection error and the
task is (or was) cancelled, the engine throws `CancellationError()`, not
`SyncEngineError.connectionLost`. Only an uncancelled task's connection
failure is connection loss. The rule applies to both `sync` and
`testConnection`.

To make the kill-mid-pass case reproducible at all — small folders finish
their batches faster than any observer can see a checkpoint — the engine
has a `betweenBatches` hook, awaited once after each batch's checkpoint
commit. It is nil in production; production pacing stays per folder
(politeness profile). Tests set it to a short sleep to open a kill window.

## Consequences

- Kill/resume callers read an honest signal: cancellation means "killed",
  connectionLost means "the network/server went away" — which is what the
  resume contract and the onboarding error surface both need.
- A cancelled pass still commits every checkpoint for batches that were
  already durable before the cancel landed; the next pass resumes from the
  last committed checkpoint (per-batch durability, DESIGN 5 step 5).
- The `betweenBatches` seam is public API on the engine; it must stay nil
  in production paths (only tests pace batches).
- Regression coverage: `GreenMailSyncTests.testKillMidPassResumesFromThe-
  LastCheckpoint` (real server, both macOS and Linux).
