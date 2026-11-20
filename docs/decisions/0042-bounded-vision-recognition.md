# 0042 — Bounded Vision recognition

Date: 2026-11-20

## Context

Vision's `VNImageRequestHandler.perform` runs synchronously and has no
built-in deadline. On the CI macOS runner the OCR suite (decision 0040)
turned a 7.5-minute `scripts/check.sh` into a run that was killed at the
45-minute job wall, with the recognition assets presumably unable to
load on that virtualized runner. Whatever the root cause, the same stall
class could wedge an import on a user's Mac.

## Decision

Every Vision recognition call in `OCRText` runs on a worker thread and
is waited on for at most `recognitionTimeout` (90 s). On deadline the
call yields nil for that pass, exactly like an unreadable image: the
message's bytes stay archived untouched, and a later `TextIndexVersion`
bump can extract again. The Vision handler and request stay confined to
the worker thread; only the outcome crosses back through a locked box
(`performBounded`).

Additionally, `scripts/check.sh` emits phase markers (`swift-build`,
`swift-test`, `docs`, `app`, each with begin/done and elapsed seconds)
as job notices and step-summary lines, so a stuck or timed-out CI run
names the phase it died in through the public checks API, which needs
no credentials on a public repository.

## Consequences

- Import can no longer wedge indefinitely on a hung recognition call;
  the worst case per call is 90 s of waiting, then extraction gives up.
- CI turns a silent 45-minute hang into either a bounded pass or a red
  failure naming the phase, which is diagnostic rather than masking.
- No extraction result changes on healthy systems: the deadline only
  fires where the old code would have hung.
- If CI proves Vision unusable on runners (deadline reached every run),
  that becomes a Maintainer decision (self-hosted runner or asset
  prewarm); tests are not skipped or loosened to hide it.
