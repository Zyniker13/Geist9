# 0023: Executor v2 — single bm25, narrow rank join, deferred snippets

**Date:** 2026-11-19
**Status:** Accepted

## Context

The M1 benchmark measured ranked search at p95 167 ms on the 1M-row corpus
(budget 200 ms) and first-ten at 167 ms against a 50 ms as-you-type budget.
Profiling the SQL shapes on a 1M-row probe database (`probe1m.db`,
synthetic corpus, seed 42) isolated the per-match work that `LIMIT` cannot
trim: every match paid a wide `JOIN message` row read, a second `bm25()`
evaluation, and a per-row `julianday('now')` re-parse before the sorter, so
first-ten cost the same as ranked.

Three candidate directions were measured on the probe:

1. **FTS-local rewrite** (`core-v6` as originally drafted): keep a narrow
   id/threadID/day tuple inside the `message_text` FTS table via
   `UNINDEXED` columns, so the ranked query touches only the FTS index.
   Measured p95 **130.2 ms vs 101.5 ms** for the current shape — the wide
   external `content` reads (every column of a ~1.5 KB row) dominate; the
   FTS-local shape was **slower**. Hypothesis refuted by measurement.
2. **Executor v2**: project `bm25()` once with field weights, join a narrow
   side table (`message_rank(id, threadID, day)`, `day` a REAL julian day),
   bind the recency anchor as a `:now` parameter, and compute snippets in a
   second MATCH pass restricted to page survivors. Measured p95:
   **65.4 ms** (v1b) vs 99.8 ms for the current shape (−35%); the survivor
   snippet pass adds ~8–13 ms on the heaviest queries. Grouped-by-thread
   measured 131.9 ms vs 141.9 ms (window-function dedup dominates).
3. **The floor**: single `bm25()` with no join at all (v4) measures
   **60.2 ms p95** on the heaviest query (M≈89k matches). The SQL layer
   cannot go below this: it is FTS5 posting-list iteration plus the sort.

A Python `sqlite3` commit pitfall was also found while rebuilding the probe
database: the 1M-row INSERT ran inside an implicit transaction and
`close()` rolled it back silently, producing an empty 36 KB husk. The
profiling scripts now commit explicitly.

## Decision

Land Executor v2 in `ArchiveCore`:

- `SearchIndex` ranked queries project `bm25()` once (field weights kept),
  join the narrow `message_rank` side table, and order by the inline
  expression (SQLite resolves select-list aliases only in ORDER BY
  contexts; the inline form measured faster and avoids the alias trap).
- The recency factor uses a bound `:now` REAL parameter instead of
  per-row `julianday('now')`.
- Snippets are computed only for page survivors in a second MATCH pass
  (`MATCH + rowid IN json_each`), byte-equal to the inline form (pinned by
  tests).
- Grouped-by-thread keeps the window-function dedup keyed on rank order;
  the middle level multiplies plain `score`/`day` columns.
- Schema `core-v6` adds `message_rank`; migration v5→v6 backfills it from
  existing rows; ingest writes the rank row in the same transaction as the
  message row.

The FTS-local (UNINDEXED-in-FTS) rewrite is **rejected**: measured slower
because wide `content` reads dominate over the narrow join.

## Consequences

- Ranked p95 on the probe drops ~35% (99.8 → 65.4 ms before the survivor
  pass); the 200 ms ranked budget keeps its margin on the 1M corpus.
- The first-ten 50 ms budget is **below the measured SQL floor** (60.2 ms
  for a single-bm25 no-join query at M≈90k). No further SQL reshaping can
  close the gap; the remaining options are a C posting-walk (WAND-style
  top-k over FTS5 via the fts5_api extension point) or re-anchoring the
  budget with the maintainer. Decision 0024 will record which path.
- Every schema-bearing table now carries its narrow rank columns in one
  place; future executors should add columns to `message_rank` rather than
  re-widening query joins.
- Ingest gains one small upsert per message (measured within noise of the
  M1.9 ingest budget).
