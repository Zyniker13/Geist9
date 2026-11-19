# 0025 — As-you-type: vocabulary completions with a match-set gate

**Date:** 2026-11-19
**Status:** Accepted (contingent on the maintainer's budget re-frame from 0024)

## Context

Decision 0024 and its addendum established that a full ranked search cannot meet the 50 ms first-keystroke budget on a 1M-message archive: spike 002 measured a 1-char prefix walk at 130–165 ms and 2-char prefixes at 670–875 ms, 20–30× over budget. The addendum proposed that as-you-type return vocabulary term completions (no postings walked) and that full ranked results appear once the prefix narrows the match set. This decision records the concrete design and the measured data that sets the gate.

Measured on the 1M-message probe corpus (11,980 distinct terms; `probe_vocab` = `fts5vocab('probe_fts','row')`), the prefix-length → match-set curve. Match set = sum of document frequencies over the prefix's terms; this is an upper bound on the true match set, since a document containing two terms under the same prefix is counted once:

| Prefix length | #prefixes | p10 | p50 | p90 | p99 | max |
|---|---|---|---|---|---|---|
| 1 | 29 | 27,750 | 12.5M | 15.0M | 16.4M | 16.6M |
| 2 | 181 | 2,750 | 1.0M | 3.1M | 4.1M | 6.1M |
| 3 | 2,380 | 250 | 64,224 | 254,152 | 601,501 | 4.1M |
| 4 | 6,209 | 250 | 29,354 | 99,633 | 300,521 | 4.0M |
| 5 | 2,706 | 30,417 | 42,142 | 101,667 | 306,085 | 4.0M |
| 6 | 2,735 | 30,409 | 41,892 | 98,820 | 305,229 | 4.0M |

(Values cross-checked against direct SQL `SUM(doc)`. The probe corpus is synthetic with short words, so the prefix count drops at L=5–6 and the p10 rises there — the surviving prefixes are the long common words.)

Two cost points from spike 002 bound the per-document cost of a full ranked walk+score:

- A single common term (df≈1M): walk 29 ms + scoring ~700 ms ≈ **730 ns/doc** (conservative upper bound).
- A 227-term, 16.5M-document prefix (`c*`): full ~1.7 s ≈ **103 ns/doc** (representative of a real multi-term prefix query).

The 7× spread means the exact gate threshold must be pinned by a dedicated as-you-type benchmark; the design below uses the conservative bound so the budget is never blown.

## Decision

1. **As-you-type returns term completions, not ranked messages.** Completions are ordered by document frequency (descending).
   - **1 char:** served from a precomputed first-letter table (letter → top-N terms by df), built at ingest. Point lookup, sub-millisecond. (A live 1-char `fts5vocab` range scan is 130–165 ms, over budget — measured.)
   - **2+ chars:** served from a live `fts5vocab` range scan. 22–31 ms, within budget — measured.
2. **Match-set gate for ranked prefix results.** Before running a ranked prefix search on the as-you-type path, compute the match-set size as the sum of document frequencies over the prefix's terms via `fts5vocab` (cheap — no postings walked). If the sum is at or below the gate threshold, run the full ranked search and show ranked results; otherwise show completions only.
   - **Starting threshold: 60,000 documents** (conservative: 50 ms ÷ 730 ns/doc ≈ 68k, rounded down). If the as-you-type benchmark confirms the per-doc cost is closer to 103 ns/doc, the threshold may be raised to ~400,000.
   - The threshold is a tunable constant derived from the cost model, not a magic number; it must be re-verified on real corpora (the probe corpus is synthetic).
3. **Committed query path: always full ranked search** (200 ms budget; M1 benchmark p95 107.6 ms PASS). The gate applies only to the as-you-type path.
4. **The gate check is the completion query.** The `fts5vocab` range scan that produces the completions also yields the df sum used for the gate, so the gate adds no extra query.

## Consequences

- Ingest produces a first-letter table artifact (tiny: 29 entries for the probe corpus; each entry = letter + top-N terms by df).
- The search core's query compiler: a prefix query compiles to the completion path while typing and to the ranked path on commit (or when the gate passes).
- The bench harness gains an as-you-type phase: 1-char and 2-char completion queries (budget <50 ms) and gated ranked prefix queries.
- The maintainer's budget re-frame proposal (0024 addendum) is the primary framing; the match-set gate is the fallback that lets ranked results appear for selective prefixes even under a strict 50 ms reading.
- The 60k threshold is conservative: it may show completions when ranked results would have fit (if the real per-doc cost is closer to 103 ns/doc), but it never blows the 50 ms budget. Re-verify with the as-you-type bench phase before trusting it on real corpora.
