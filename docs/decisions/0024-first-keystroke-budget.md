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

## Addendum (2026-11-19): spike 002 result

Spike 002 (`Spikes/PrefixWalkSpike`) measured the C top-k walk over the
public API on the 1M probe corpus (release build, p50 over 5 repeats):

- **1-char prefixes: walk-only floor 766–1748 ms** (15–35× over budget);
  full scoring 1484–2268 ms. Walk-only skips all scoring, so it is the
  lower bound of any public-API approach.
- **2-char prefixes: walk-only floor 110–269 ms** (2–5× over); full
  scoring 668–1049 ms.
- Per-instance cost is not the problem (90–500 ns/instance; a
  single-term walk runs at ~30 ns/doc). The cost is prefix expansion:
  `c*` expands to 227 of the corpus's 11,980 terms, and the union walk
  over their posting lists costs ~1.7 µs/doc — ~60× the single-term
  per-doc cost.
- The C walk's BM25 mirror matches SQL `bm25()` exactly (tie-aware
  PASS), so the measurements are on correct results.
- `fts5vocab` range scans (no postings walked): 22–31 ms for 2-char
  (under budget), 130–165 ms for 1-char (over budget; the range covers
  ~227 terms plus an `ORDER BY doc DESC` sort).

**Verdict: the public-API C walk is INVALIDATED as the first-keystroke
path.** The cheaper per-instance scoring variant named in the spike
plan (`xInstCount`-only) is moot: the walk-only floor alone is 3–35×
over budget.

The fallback named in this record is now the design direction:
**vocabulary-gated as-you-type**. The first-keystroke response is term
completions (no postings walked): 1-char from a precomputed
first-letter table (point lookup, sub-ms), 2-char+ from a live
`fts5vocab` range scan (measured 22–31 ms, under budget). Ranked
messages remain the committed-query path (200 ms budget; M1 benchmark
p95 107.6 ms PASS).

**Budget re-frame proposed to the maintainer** (STATUS.md, "Needs the
Maintainer"): first-keystroke "results" are the completion list; ranked
prefix results are excluded from the as-you-type budget, because a
1-char prefix matches ~1M messages and even the bare walk takes 1.5 s —
no ranked result set for a 1-char prefix can exist under 50 ms on this
corpus. If the maintainer rejects the re-frame, the as-you-type budget
is unmeetable as written and the DESIGN 6A line needs a correction.
