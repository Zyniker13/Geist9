# 0027 — Persistent vocabulary table for as-you-type completions

## Context

Decision 0025 served every completion query from a temporary fts5vocab scan
over the live FTS5 index. On the 1M benchmark that scan cost 60.3 ms p95 for
two-character prefixes and 66.1 ms p95 gated four-character prefixes
(35 FTS segments), against a 50 ms first-keystroke budget — and the 1-char
path already used a precomputed first-letter table (point lookup, 1.0 ms).

## Decision

Add a persistent `vocabulary(term TEXT PRIMARY KEY, doc INTEGER NOT NULL)
WITHOUT ROWID` table (core-v9) that mirrors the FTS5 index's term set
exactly:

- **Migration core-v9** creates the table and rebuilds it once from the live
  fts5vocab of the existing index (`Vocabulary.rebuildAll`), then rebuilds
  the first-letter tables from it. Stored message rows and bytes are never
  touched.
- **Ingest keeps it exact** by applying per-message term-frequency deltas
  (`termDelta: [term: docChange]`) inside the same transaction that writes
  the FTS index: new messages add their term set; a reindexed message
  subtracts the old row's term set (read before the rewrite) and adds the
  new one, so overlapping terms are counted once. The stored message row
  and bytes are untouched.
- **Queries** keep decision 0025's shape: 1-character prefixes use the
  first-letter tables (unchanged); 2+-character prefixes do a single
  b-tree range scan over `vocabulary` with the match-set gate computed in
  the same query (`SUM(doc) OVER ()`), replacing the fts5vocab scan.
- Terms whose count reaches zero are deleted; the table has no rows the
  FTS index lacks.
- `refreshAsYouTypeVocabulary()` (import ends, backfill, full reindex)
  now rebuilds the vocabulary table plus the first-letter tables.

## Tests

`Tests/ArchiveCoreTests/VocabularyTableTests.swift` pins the table against
the live fts5vocab after plain ingest (no rebuild call), duplicate ingest,
a simulated old-pipeline reindex (delta must drop removed terms and count
overlapping terms once), a versionless reingest (empty delta), transaction
rollback, the completion gate reading the new table, and the core-v9
migration of a hand-built core-v8 archive (table equals the live vocabulary;
stored message and text rows byte-identical).

## Consequences

- Two-character prefix completions read one small b-tree instead of
  scanning all FTS segments; the 50 ms budget should now hold at 1M
  messages (to be re-measured with the benchmark).
- The first-letter tables remain an import-end snapshot (decision 0025),
  but the gate for 2+-character prefixes is now exact at all times.
- The ingest transaction grows by one upsert per distinct term; the delta
  map is transaction-local and rolls back with the index writes.
- A schema-version bump means first open of an existing archive runs the
  core-v9 rebuild (one full vocabulary scan, then incremental upkeep).
