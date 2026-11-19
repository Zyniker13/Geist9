# 0021 — Trigram fallback index for substring and CJK search

Date: 2026-11-18

## Context

DESIGN 6A (M2.1) requires substring search: partial words (`2214` inside
INV221488), phrases spanning token boundaries (`"rder prj"`), and CJK
queries that must survive segmentation differences between the query and
the indexed text. The M1 exact-token FTS5 index matches whole tokens only,
so all three fail today. The 1M benchmark closed M1 with the ranked budget
met (p95 167 ms < 200 ms) while the as-you-type first-ten budget is still
open (167 ms vs 50 ms) — the fallback must not stand in the way of closing
that budget in M2.

The FTS5 spike (decision 0008 era, docs/spikes/fts5-search.md) measured a
trigram index over full bodies at ~225 MB per 100k messages, versus 36 MB
subject+sender-only, and recommended starting narrow.

## Decision

Add a second FTS5 table with the `trigram` tokenizer alongside the exact
index, never replacing it:

- Schema `core-v5` adds `message_trigram` (FTS5, `tokenize = 'trigram'`,
  the same seven columns as `message_text`, but holding raw folded text
  instead of token streams) and `message.textVersion` (pipeline version
  per row, nullable on migrate).
- Ingest writes trigram content for new rows in the same ingest
  transaction, delete-before-insert so re-ingest stays idempotent.
- `message.textVersion` records which text pipeline version indexed each
  row. `TextIndexVersion.current` is 2. Rows older than the current
  version are re-indexed from their stored bytes by `reindexOutdated`
  (called on open and from the backfill queue); stored files are never
  rewritten, keeping the data-safety invariant. The `core-v5` migration
  itself does not backfill; the service does, so opening a large older
  archive is incremental rather than one blocking write.
- Compilation: each text leaf compiles to an `FTSLeaf` — the exact-token
  MATCH expression plus an optional trigram MATCH expression built from
  the folded raw text. Phrases shorter than three characters produce no
  fallback (a trigram cannot exist). Phrases are split into maximal
  same-script runs; CJK runs stay whole (below-trigram-length CJK is
  handled by the raw-text inclusion), non-CJK pieces shorter than three
  characters are dropped from the fallback only.
- Execution, ranked path: when the exact-token ranked query returns zero
  hits and any leaf has a fallback, the leaf's fallback expression is
  re-run ranked (BM25 has no meaning over trigrams, so fallback results
  keep the executor's recency ordering and the exact results take
  precedence when both match).
- Execution, predicate path: CJK leaves union their trigram match
  eagerly — the query's segmentation can differ from the indexed text's,
  and a predicate tree has no "found nothing yet" point where a retry
  could attach. Every other fallback-able leaf unions only through a
  whole-tree zero-hit retry: if the exact predicate tree matched nothing,
  the tree is rebuilt with `useFallbacks` and re-run. The common path
  (exact hits) pays for nothing extra.

## Consequences

- Substring, cross-token-phrase, and CJK-by-segmentation queries now
  return results on all three executor paths; 11 dedicated tests cover
  ingest, ranked fallback, predicate fallback (including AND/NOT trees),
  CJK, migration backfill, and idempotent re-ingest.
- Storage grows by trigram content for full bodies (~225 MB/100k
  messages with bodies per the spike). The narrow-start option stays
  open: the write path is one function, so a later decision can drop
  body trigrams for older messages without touching search semantics.
- The ranked path's fallback keeps BM25 out of trigram scoring; ranking
  quality for fallback-only hits rests on recency ordering until the
  relevance-set work (M2.9) measures it.
- The zero-hit retry runs the predicate tree at most twice; filters are
  unchanged. The eager CJK union can add a second MATCH per CJK leaf in
  the common path — acceptable because CJK queries are the case where
  the exact path is unreliable by construction.
- `textVersion` makes every future text-pipeline change (stemming,
  extraction, OCR, M2.2–M2.4) an incremental backfill instead of a
  destructive rebuild.
