# 0063 — One scheduler pass at a time, per-account serially

## Context

M4's sync scheduler runs passes without a person driving them. DESIGN 5
("Politeness and Limits", "Background Sync") asks for per-provider politeness
and a default cadence of 30 minutes, and the engine (decision 0060) already
resumes exactly where a killed pass stopped. Two things were still open: how
many passes may run at once, and what happens when a second pass is requested
while one is in flight. Both matter for the politeness contract — two passes
against the same provider at once is exactly the behavior a mail server's
connection limit punishes.

## Decision

The scheduler keeps **one pass across all accounts at a time**, and inside a
pass it walks accounts **serially, in row order**. A `runPass` requested while
a pass is already running is a **no-op returning empty progress** — not a
queued second pass, not a concurrent one. A queued variant was rejected: it
would let "Sync now" presses pile up passes that each re-walk the same
accounts, and the politeness budget would then be spent on redundant
connection churn.

`start` runs the immediate first pass synchronously (the call returns after
it), then a detached loop repeats every `pollInterval` (default 30 minutes,
DESIGN 5) until `stop`. `stop` cancels the loop and awaits the in-flight pass,
so a stop is never mid-write; the engine's own cancellation contract
(decision 0060) governs the in-flight part. A second `start` first stops the
running cadence.

Missing credentials skip an account's pass with a "Unlock the app to continue
archiving" event; the engine is never constructed for that account, so an
unreachable secret store can never surface as an authentication failure
(DESIGN 4). Engine failures are reported as the same folded sentences the
onboarding screen shows.

## Consequences

- Politeness is enforced by construction: never more than one pass, never two
  accounts of the same provider connecting at once. Per-account connection
  limits inside a pass remain the engine's `PolitenessProfile` duty.
- Two accounts syncing concurrently (a speed feature) can be added later by
  widening the gate; nothing else changes.
- A test that calls `runPass` twice sees the second return empty progress —
  tests that want a real second pass must `stop` (or use a fresh scheduler).
- The cadence loop is detached, so a `start` whose loop task is deallocated
  would leave ticking passes; `stop` is the only sanctioned shutdown and the
  app's lifecycle must call it (the app target wires this in a later
  milestone).
