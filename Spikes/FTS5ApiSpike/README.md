# Spike 001: fts5_api from a SwiftPM C target

Part of decision 0024's spike sequence for the first-keystroke
(as-you-type) budget: DESIGN 6A requires first-keystroke results under
50 ms at 1M messages, and the SQL shapes cannot get there (the bare
posting walk alone is 1.54 s for a 1-char prefix; ~50 ns/doc even for a
single common term). Before any C posting-walk can be written, the
feasibility gate is: can our C code reach `fts5_api` at all, on macOS and
Linux, inside a SwiftPM build?

## Question

Given a SwiftPM C target linked against the same libsqlite3 the app uses,
can it (1) obtain the connection's `fts5_api` pointer, (2) register a
custom FTS5 auxiliary function through `xCreateFunction`, (3) have the
auxiliary function invoked by real MATCH queries, and (4) walk a phrase's
whole posting list via `xQueryPhrase` — on macOS and Linux?

## Approach

- Standalone SwiftPM package (`Package.swift` + `FTS5ApiSpikeC/ext.c` +
  `Sources/FTS5ApiSpike/main.swift`), not part of the main build.
- No vendored amalgamation, no vendored fts5.h: the macOS SDK's
  `sqlite3.h` and Ubuntu's `libsqlite3-dev` header both already carry the
  full FTS5 extension API (`Fts5ExtensionApi`, `fts5_api`,
  `Fts5PhraseIter`). The C target links plain `-lsqlite3`.
- `fts5_api` retrieval by the documented mechanism: prepare
  `SELECT fts5(?1)`, bind the output pointer with
  `sqlite3_bind_pointer(..., "fts5_api_ptr", NULL)`, step once.
- An auxiliary function `bc_aux` registered via `api->xCreateFunction`,
  invoked from the SELECT list (`SELECT bc_aux(t_fts) FROM t_fts WHERE
  t_fts MATCH ...`), which walks phrase 0's postings via `xQueryPhrase`
  (row callback + per-row `xPhraseFirst/xPhraseNext`) and returns the
  document count.
- Nine PASS/FAIL checks: table creation, retrieval+registration, per-row
  invocation counts, phrase count, row count, walk doc/instance counts,
  OR-query behavior.

## Results

- macOS (Apple libsqlite3 3.54.0): `SPIKE-001 RESULT: PASS (9 checks)`.
- Linux (swift:6.2 container, libsqlite3-dev 3.45.1):
  `SPIKE-001 RESULT: PASS (9 checks)`.

## Verdict: VALIDATED

### What worked
- `fts5_api` retrieval via `SELECT fts5(?1)` +
  `sqlite3_bind_pointer(..., "fts5_api_ptr")` — on both platforms.
- `xCreateFunction` aux-function registration; invocation from the
  SELECT list of MATCH queries; `xQueryPhrase` whole-table posting walk
  with per-row callbacks and per-row instance iteration.

### What didn't
- The first attempt used `sqlite3_bind_blob` to pass the output address;
  FTS5 requires the typed-pointer form (`sqlite3_bind_pointer` with
  `"fts5_api_ptr"`). With bind_blob the registration fails without a
  sqlite error message.
- Aux functions cannot be used inside the MATCH expression itself
  (`MATCH 'a AND bc_aux()'` is a syntax error shape); they are called
  from the SELECT list / rank context.

### Surprises
- The FTS5 extension API ships inside `sqlite3.h` on both platforms —
  nothing to vendor, which also removes version-skew risk: the header we
  compile against is the header of the library we run against.
- Each per-row aux invocation can re-walk the full phrase postings (3
  docs × 3 invocations = 9 walked docs before accounting was fixed) — a
  per-row walk is wasted work; a real top-k implementation must walk once
  per query (auxdata or a capture-on-first-call pattern).

### Recommendation for the real build
- GRDB 7 uses the system libsqlite3 (`systemLibrary` target) and exposes
  no extension loading, so the walk should run on the search core's own
  read-only connection opened by the C target (WAL allows concurrent
  readers) rather than trying to register into GRDB's connection.
- Spike 002 builds on this: a C top-k walk (WAND-style early cutoff via
  the `SQLITE_DONE` return from the `xQueryPhrase` callback) over the
  1- and 2-char prefix shapes of the 1M probe corpus, target <50 ms.

Run: `cd Spikes/FTS5ApiSpike && swift run FTS5ApiSpike`.
Linux: `docker run --rm -v "$PWD":/spike -w /spike swift:6.2 bash -c
"apt-get install -y libsqlite3-dev >/dev/null && swift run FTS5ApiSpike"`.
