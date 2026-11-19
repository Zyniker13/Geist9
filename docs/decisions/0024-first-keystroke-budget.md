# 0024: The 50 ms budget is the first-keystroke (as-you-type) path, not first-ten

**Date:** 2026-11-19
**Status:** Accepted

## Context

Decision 0023's budget framing was wrong, and the error traces back to the
M1 closure. DESIGN 6A budgets, verbatim: "first keystroke results under
50 ms, a full ranked page under 200 ms" — enforced **from M2** on a
synthetic archive (docs/TESTING.md says the same). ROADMAP M1's only
benchmark budget is the two-word ranked page (<200 ms). "First keystroke
results" means: what the search field shows after the first character is
typed — a prefix/substring query — not "the first ten results of a
two-word query". The bench harness had been gating the limit-10 pass of
the two-word ranked shape against the 50 ms budget (`first-ten < 50`), a
mis-scope that also crept into STATUS.md's budget table and the framing
of decisions 0021 and 0023.

Evidence that these are different shapes, measured on the 1M probe corpus
(`probe1m.db`, synthetic, seed 42):

- The two-word ranked shape (executor v2) measures p95 **107.6 ms** — its
  budget (<200 ms) passes with margin. Its limit-10 variant costs the same
  (109.7 ms), as it must: `LIMIT` cannot trim per-match work, and after
  executor v2 there is almost none left to trim.
- The actual first-keystroke shape has **no implementation yet**: the
  search core has no prefix query form; the trigram fallback fires only on
  zero exact hits and is a full substring scan.
- Probe of prefix posting sizes (`probe3b`): the synthetic vocabulary's
  head words appear in ~99% of messages (`jojasu` in 992,271 of 1,000,000).
  A 1-char prefix matches ≈1M messages; the **bare FTS5 posting walk**
  (a `count(*)`, no bm25, no sort) takes **1.54 s** for `c*` because a
  prefix expands to every matching vocabulary term. Even a single common
  term's contiguous posting list walks at ≈**50 ns/doc** through SQL
  (0.05 s at M=1M) — the entire budget spent before any ranking.
- Ranking prefix shapes through SQL is non-viable: the bm25-prefix probe
  run timed out at 420 s without finishing its 25-query suite.

## Decision

1. The harness's first-ten gate was a wrong test and is removed (wrong-test
   fix in its own commit, per AGENTS.md): the limit-10 series stays as an
   informational regression signal; the enforced budget on this bench is
   the ranked page <200 ms. STATUS.md's budget table records the two-word
   ranked row and an explicit "not yet implemented" row for as-you-type.
2. The 50 ms budget is re-attached to its real shape and stays: when the
   as-you-type path exists (M2), first-keystroke results on the 1M
   synthetic archive must come back under 50 ms.
3. Spike sequence for the as-you-type mechanism (kill-risk order):
   - **001**: register `fts5_api` from a SwiftPM C target on macOS and
     Linux — the feasibility gate for any C posting-walk.
   - **002**: a C top-k posting walk (WAND-style pruning over the prefix's
     expanded terms) on the 1- and 2-char prefix shapes, target <50 ms at
     M≈1M. The arithmetic is plausible: the SQL walk pays ~50 ns/doc; a
     tight C walk over the same postings needs ~10–50 ms at 10–50 ns/doc.
   - If 002 misses, the fallback is a vocabulary-gated design (rank the
     completions first, evaluate only the top completions' postings) or a
     budget re-anchor proposed to the maintainer.

This record supersedes decision 0023's budget framing (the executor v2
adoption itself stands, and its measurements remain valid for the ranked
shape). Decision 0021's "as-you-type first-ten" phrasing reads as this
record does.

## Consequences

- The M1 exit stays closed with its real budget met (ranked p95 107.6 ms).
- The M2 search work gains a concrete first target: prefix queries in the
  query language/compiler plus a first-keystroke execution path that can
  meet 50 ms at M≈1M; the bench harness gains an as-you-type phase when
  the path exists.
- The 1.54 s / 50 ns-per-doc SQL numbers are the baseline the C walk must
  beat; the spike compares against the bare walk, not against SQL shapes
  that were never going to be fast enough.
- Ingest is unaffected; the trigram table stays for substring and CJK
  retrieval, distinct from the as-you-type path.
