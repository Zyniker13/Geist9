# Spike 002: C posting-walk top-k over FTS5 prefix shapes

Part of decision 0024's spike sequence for the first-keystroke
(as-you-type) budget: DESIGN 6A requires first-keystroke results under
50 ms at 1M messages, and the SQL shapes cannot get there (the bare
posting walk alone is 1.54 s for a 1-char prefix). Spike 001 validated
that `fts5_api` is reachable from a SwiftPM C target on macOS and Linux.
This spike measures the next gate: can a C walk over the public API
meet the budget at all?

## Question

Given `fts5_api` access (spike 001), can a C top-k walk — `xQueryPhrase`
over the prefix-expanded term union plus exact BM25 scoring in C —
return the first-keystroke shapes (1-char and 2-char prefixes) under
50 ms on the 1M-message probe corpus?

## Approach

- Standalone SwiftPM package (`Package.swift` + `PrefixWalkSpikeC/ext.c`
  + `Sources/PrefixWalkSpike/main.swift`), not part of the main build.
  C target links plain `-lsqlite3`; the FTS5 extension API ships inside
  `sqlite3.h` on both platforms (spike 001).
- The C side registers an auxiliary function that walks the query's
  phrase postings via `xQueryPhrase`. Per document it accumulates the
  exact BM25 score from `xInstCount`/`xInst` (same formula as the SQL
  `bm25()` mirror) and keeps a top-k heap. A walk-only mode skips
  scoring entirely, measuring the pure walk floor.
- Seventeen shapes on the 1M probe corpus: seven 1-char prefixes
  (`c* j* m* s* b* t* w*`), six 2-char prefixes (`jo* mu* re* wo* ca*
  sa*`), the full-word prefix `jojasu*`, two two-word prefix shapes
  (`mu* jojasu`, `mu* jo*`), and a committed two-word control
  (`caju nusi`).
- p50 over 5 repeats, release build, `mmap_size=2 GiB`, 64 MB page
  cache (same setup as the M1 benchmark).
- Verification: top-10 ids and scores from the C walk against SQL
  `bm25()` on a mid-size shape, tie-aware comparison.

## Results (p50, ms, release build, 1M synthetic corpus)

Run A (complete table; the walk numbers are unaffected by the vocab
probe bug fixed for the final run):

| shape        | docs      | full   | walk-only | instances  | ns/inst |
|--------------|-----------|--------|-----------|------------|---------|
| `c*`         | 1,000,000 | 2268.3 | 1748.0    | 20,858,108 | 145     |
| `j*`         |   999,999 | 2156.1 |  978.7    | 19,978,926 | 107     |
| `m*`         |   999,929 | 1696.5 |  809.2    | 14,148,706 | 124     |
| `s*`         |   999,938 | 1535.7 |  849.1    | 14,068,190 | 123     |
| `b*`         |   999,889 | 1483.9 |  765.8    | 13,193,526 | 112     |
| `t*`         |   999,953 | 1512.2 |  845.3    | 15,105,269 | 100     |
| `w*`         |   999,980 | 1532.6 |  895.8    | 16,864,399 |  90     |
| `jo*`        |   998,090 |  835.3 |  183.1    |  8,196,432 | 102     |
| `mu*`        |   912,575 |  694.8 |  137.4    |  2,700,122 | 256     |
| `re*`        |   867,584 |  668.5 |  110.5    |  2,192,961 | 304     |
| `wo*`        |   957,478 |  796.9 |  176.9    |  3,605,431 | 221     |
| `ca*`        |   986,123 |  874.9 |  238.4    |  5,142,067 | 169     |
| `sa*`        |   929,022 |  766.1 |  150.4    |  2,958,725 | 258     |
| `jojasu*`    |   992,271 |  696.6 |   29.2    |  5,994,461 | 127     |
| `mu* jojasu` | 1,904,846 |  805.2 |  169.6    |  2,700,122 | 271     |
| `mu* jo*`    | 1,910,665 | 1357.1 |  335.2    |  2,700,122 | 502     |
| `caju nusi`  |   692,086 |  456.5 |   11.5    |    907,915 | 498     |

Final run (fixed vocab probe; 2-char+ shapes re-measured at the same
order of magnitude): `jo*` full 1049.7 / walk-only 185.9; `mu*` 871.2 /
181.5; `re*` 905.1 / 126.5; `wo*` 955.0 / 213.2; `ca*` 1043.2 / 269.4;
`sa*` 905.1 / 172.0; `jojasu*` 811.3 / 33.8; `mu* jojasu` 896.2 / 171.2;
`mu* jo*` 994.8 / 370.0; `caju nusi` 403.5 / 8.2.

Vocabulary range scans (`fts5vocab`, no postings walked), p50 ms:
`c*` 165.3, `j*` 138.8, `m*` 130.4, `jo*` 29.7, `mu*` 22.1, `wo*` 31.0.

Verification: top-10 ids and scores from the C walk match SQL `bm25()`
exactly on the mid-size shape (tie-aware). PASS.

## Verdict: INVALIDATED for the public-API route

- **1-char prefixes: the walk-only floor is 766–1748 ms** — 15–35× over
  the 50 ms budget. Walk-only skips all scoring (no `xInstCount`/`xInst`
  calls, no accumulation), so it is the lower bound of any public-API
  approach. No C code over this API can meet the budget for the
  first-keystroke shape.
- **2-char prefixes: walk-only floor 110–269 ms** (2–5× over budget);
  full scoring 668–1049 ms.
- **Per-instance cost is not the problem**: 90–500 ns/instance, and a
  single-term walk runs at ~30 ns/doc (`jojasu*`: 29.2 ms over 992k
  docs). The cost is prefix expansion: `c*` expands to 227 of the
  corpus's 11,980 terms, and the union walk over their posting lists
  costs ~1.7 µs/doc — ~60× the single-term per-doc cost. A cheaper
  per-instance scoring variant (e.g. `xInstCount`-only) is moot: the
  walk floor alone is 3–35× over budget.
- **The vocabulary table is fast for 2-char but slow for 1-char**:
  22–31 ms for 2-char (under budget) but 130–165 ms for 1-char, because
  the range covers ~227 terms and `ORDER BY doc DESC` sorts them.

## What worked

- Prefix-expansion union walk via `xQueryPhrase` over the public API,
  with exact BM25 scoring in C matching the SQL mirror exactly.
- Walk-only floor measurement, which is what makes the verdict airtight:
  the budget is missed before any scoring happens.

## What didn't

- The budget itself. See verdict.

## Surprises

- The per-doc cost of the union walk scales with the number of expanded
  terms, not with the result size: `c*` matches ~1M docs at 1.7 µs/doc
  while `jojasu*` matches ~1M docs at 0.03 µs/doc.
- `fts5vocab` range scans are a viable 2-char completion source
  (22–31 ms) but not a 1-char one (130–165 ms).
- Degenerate idf on this corpus: the head words occur in ~99% of
  documents, so their idf is ~0 and prefix-shape scores are dominated by
  the rarer terms. A corpus property, not a bug — the mirror matches
  SQL exactly.

## Recommendation for the real build

- The public-API C walk is not a viable first-keystroke path at 1M
  messages. Do not build a C posting-walk for as-you-type.
- Take the fallback named in decision 0024: **vocabulary-gated
  as-you-type**. The first-keystroke response is term completions (no
  postings walked): 1-char from a precomputed first-letter table
  (point lookup, sub-ms), 2-char+ from a live `fts5vocab` range scan
  (measured 22–31 ms, under budget). Ranked messages remain the
  committed-query path (200 ms budget; M1 benchmark p95 107.6 ms PASS).
- The budget re-frame (first-keystroke "results" = the completion list;
  ranked prefix results excluded from the as-you-type budget because a
  1-char prefix matches ~1M messages and even the bare walk takes 1.5 s)
  is proposed to the maintainer under "Needs the Maintainer" in
  STATUS.md.

Run: `cd Spikes/PrefixWalkSpike && swift build -c release &&
.build/release/PrefixWalkSpike <probe1m.db> 5`. The 1M probe corpus
(`probe1m.db`) is built from the M1 benchmark corpus in the scratch
area; the synthetic corpus generator is not committed.
