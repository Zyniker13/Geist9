# 0028: Judged Relevance Set for Search Quality

Date: 2026-11-19
Status: Accepted
Supersedes: none

## Context

DESIGN 6A requires a judged relevance set gating every change that touches
search: about 300 curated queries with graded judgments, scored as nDCG@10 and
recall@50 (targets set in M0: nDCG@10 >= 0.45, recall@50 >= 0.75, a drop
beyond 0.02 from the recorded baseline fails the build). The intended corpus is
Enron plus our own multilingual and attachment fixtures. M2 must show both
metrics meeting the targets, in CI.

Two constraints shape the design:

- The repository is public and must not contain real people's names, real
  messages, or Enron corpus bytes (AGENTS.md, "Public Repository"). Enron
  messages are real mail by real people.
- Not every search mechanism DESIGN 6A names exists yet. The M2 milestone
  builds them in order (trigram, natural-language dates, typo tolerance,
  semantic). Queries that need a mechanism the engine does not have would
  hold the metrics below targets that were set for the finished engine.

## Decision

The judged set lives in three layers.

1. **Committed gate set** (this decision's core): a deterministic, fully
   synthetic topical corpus generated in Swift (fake people, example.com
   addresses only) of ~400 messages — topical threads with targets,
   near-misses, and terminology traps, plus seeded generic noise — and ~200
   curated queries with hand-authored graded judgments (0-3) stored as JSON in
   the test target. Categories follow DESIGN 6A: names and address tokens,
   phrases, fields and operators, dates, folding and diacritics, stemming,
   trigram substrings, attachment text, CJK, Cyrillic, and German compounds.
   The gate runs in `swift test` (so in CI on Linux and macOS) as
   `Tests/SearchEvalTests/RelevanceGateTests.swift`.
2. **Capability-gated slices**: every query lists the mechanisms it needs
   (`requires`). The runner computes the engine's capability set for the
   platform it runs on (for example stemming is macOS-only until language
   detection runs on Linux; typo tolerance, natural-language dates, semantic
   search, PDF text, and OCR are not built yet). A query joins the gate
   aggregate only when every mechanism it needs exists; the other slices are
   computed and logged in the failure message but do not gate yet. When a
   mechanism lands, its queries move into the gate — recorded here, never by
   editing targets or tolerances. The aggregate is a macro-average over gate
   queries; nDCG@10 uses exponential gain 2^rel - 1; recall@50 counts any
   judged message with grade >= 1 found in the top 50.
3. **Baseline**: the first recorded per-platform metrics are committed as
   `Tests/SearchEvalTests/baseline.json`. The gate fails if a metric drops
   more than 0.02 below its baseline or below the M0 target. Legitimate
   improvements update the baseline upward in the same commit as the change.

The Enron layer is maintainer-local: the same runner accepts an external
corpus and judgments file from outside the repository (gitignored), so the
Enron queries can be authored and scored on a real corpus without committing
its bytes or names. Until that layer exists, the committed gate set is what
CI enforces, and the M2 milestone's "done" refers to it.

## Consequences

- CI now measures search quality on every run, on both platforms, with
  deterministic fixtures; a search change that loses relevance fails.
- Judgment authoring is coupled to the generator: topical message IDs are
  stable, so query files stay valid across generator refactors that do not
  change message content; the corpus version is recorded in the JSON.
- The gate set grows as mechanisms land; targets and tolerance never change
  to accommodate a red build. A mechanism's slice failing at merge-in time is
  a bug to fix before the mechanism is called done.
- Enron-derived work stays out of the repository; when the maintainer layer
  runs, it can only make the picture more honest, not the gate weaker.
