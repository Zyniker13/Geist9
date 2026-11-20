# Decision 0045: Semantic hybrid — vector index and rank fusion

Date: 2026-11-20
Status: Accepted (implemented in slices; this record fixes storage, similarity, and merge)

## Context

The second M2 remaining item is the semantic hybrid (ROADMAP M2): keyword
(BM25) results merged with nearest-neighbour results from embedding vectors.
Decision 0009 already chose the embedding model: bge-small-en-v1.5, 384
dimensions, running through Core ML on Apple silicon, "on by default once
its model is downloaded, off-switchable". DESIGN 6C left the vector-index
choice open: an SQLite extension (sqlite-vec, MIT) or a flat index of our
own "if that is simpler to sandbox".

## Decision

1. **Own flat index, no SQLite extension.** Loading a C extension into
   SQLite from SwiftPM — on macOS *and* Linux CI, and later from inside a
   sandboxed app bundle — is a chain of packaging risks for a query path a
   plain scan can serve. The semantic-query budget (DESIGN 11: 300 ms on a
   one-million-message index) fits a float16 full scan with vectorized dot
   products; the five-million stretch is measured before we trust it.

2. **Storage.** New `message_embedding` table (introduced core-v12), one
   row per message *per model* — the primary key is (message id, model),
   added as the core-v13 rebuild after slice 2's tests caught that the
   id-alone key of core-v12 let a second model's backfill overwrite the
   first model's vectors:

   ```sql
   CREATE TABLE message_embedding(
       id     INTEGER NOT NULL REFERENCES message(id) ON DELETE CASCADE,
       model  TEXT NOT NULL,
       dim    INTEGER NOT NULL,
       vector BLOB NOT NULL,
       PRIMARY KEY (id, model))
   ```

   Vectors are stored as **float16 little-endian** BLOBs (2 bytes per
   dimension: 768 MB at 1M × 384, versus 1.5 GB at float32) and decoded to
   float32 for arithmetic. The f16 rounding (~1e-3 relative) does not move
   ranking order meaningfully. Deleting a message cascades its embedding;
   no stored message bytes are touched.

3. **Similarity and search** (`VectorIndex` in ArchiveCore, builds and
   tests on Linux): `encode`/`decode` (exact IEEE binary16 conversion,
   round-to-nearest-even; decode exact for normal, subnormal, Inf, NaN),
   `cosine` (nil for dimension mismatch or an all-zero vector), `upsert`
   (replaces the row for the (message, model) pair; rejects empty vectors
   and any
   dimension change for a model already present — one dimension per model,
   so a query dimension is always known), `remove`, and `search` (full
   scan, cosine descending, ties by ascending message id, `limit`
   truncation; corrupt or all-zero rows are skipped silently; a
   mismatched query dimension throws). The scan is scalar for this slice —
   one deterministic code path on every platform; the Accelerate/vDSP path
   lands with the scale measurement slice.

4. **Rank fusion** (`RankFusion.rrf` in ArchiveCore): reciprocal rank
   fusion over the keyword list and the semantic list, score =
   Σ 1/(k + rank) with k = 60 (the standard constant), contributions
   summed for an identifier appearing in both lists, descending score with
   ascending-id tie-break for determinism, `limit` truncation. RRF needs
   only ranks — no score-scale calibration between BM25 and cosine — which
   is why it was chosen over weighted linear combination.

5. **What is embedded** (per DESIGN 6C and decision 0009): each message's
   subject plus its opening text, not the whole body — embedding cost
   scales with ingest, and the opening carries the semantic signal the
   hybrid adds over BM25. The Core ML embedding adapter, the background
   computation/backfill, and the executor wiring with the off-switch are
   later slices of this same decision (see Implementation status).

6. **No new dependencies.** sqlite-vec is not added; Core ML is an Apple
   system framework reached through the macOS-only target that decision
   0039 established for Vision/PDFKit (the embedding adapter mirrors that
   arrangement).

## Consequences

- Linux CI tests the index and fusion with hand-written vectors; it never
  needs the model or Core ML.
- A model swap means a new `model` value with its own dimension; rows of
  the old model stay but are never returned to a new-model query. A
  backfill that recomputes embeddings under the new model reuses this
  table.
- The scan is O(rows × dim) per query. The scale slice must measure the
  300 ms budget at 1M × 384 and report; if a flat scan misses it there,
  the follow-up decision picks a real ANN structure (the schema above does
  not change — only the search path does).
- `IndexSchema.version` moves 11 → 12, and 12 → 13 when slice 2's tests
  caught the id-alone key letting a second model overwrite the first
  model's vectors; old archives migrate on open with no change to stored
  bytes.

## Implementation status

- **Slice 1 (storage, similarity, fusion):** `VectorIndex` (binary16
  codec, cosine scan, dimension-per-model upsert) and `RankFusion.rrf` in
  ArchiveCore; `message_embedding` introduced in core-v12. Committed
  `dc07056`.
- **Slice 2 (runtime + backfill):** the `EmbeddingModel` protocol (with a
  deterministic test double as the default), `EmbeddingBackfill`
  (resumable, oldest-first, bounded, never rewrites an existing vector,
  embeds subject + opening of the folded token stream), hybrid `search()`
  merging the keyword and semantic lists via RRF with `viaSemantic` on
  hits, and the core-v13 rebuild above. Committed `ddc9dcb`.
- **Slice 3 (Core ML adapter + wiring):** the macOS-only `ArchiveEmbedApple`
  target, the decision-0039 arrangement: `WordPieceTokenizer` (BERT
  WordPiece, per-model vocabulary, truncation to the model's sequence
  length) and `CoreMLEmbedding` (compiles source-format models before
  load, probes the real output shape when a conversion leaves it
  undeclared, normalizes the [CLS] hidden state, also accepts pooled
  outputs). `CoreMLEmbedding.load(named:in:)` locates
  `<name>.mlmodel`/`.mlpackage` plus `<name>-vocab.txt` in the app bundle
  or the models folder and returns nil otherwise. The app loads the model
  per archive, passes it and the persisted off-switch
  (`semanticSearchEnabled`, default on) into every search, and schedules
  bounded background backfill passes after open and import. No model
  weights are committed; tests run against a generated toy model. Until
  the real bge-small-en-v1.5 files are present (the model-download slice),
  the archive searches keyword-only.
