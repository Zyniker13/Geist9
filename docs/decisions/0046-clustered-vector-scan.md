# 0046 — Clustered vector scan (IVF-flat)

## Context

Decision 0045's scale slice measured the flat cosine scan on the 1M-vector
benchmark archive (1M × 384 float16). After the fetch-shape fixes (cursor
streaming, 1 GB mmap) the scan's floor is fetch ~170 ms + Accelerate math
~90 ms ≈ 260–290 ms: the 50-repeat round gives p50 288.9 ms, p95 340.5 ms
under moderate machine load. The 300 ms p95 budget therefore has no
headroom — the median alone sits at 97% of it — and no fetch-shape change
can fix that: the archive must not all be read per query. Decision 0045
pre-committed this follow-up: when the flat scan misses, pick an ANN
structure without giving up exact scores for the rows that are scored.

## Decision

Partition the `message_embedding` rows per model with IVF-flat (inverted
file, flat quantization): k-means centroids, each row assigned to its
nearest centroid, queries scored against centroids first and only the
`nprobe` nearest clusters fully scanned.

- **Schema (core-v14).** New table `embedding_cluster(model, cluster,
  centroid, count, PRIMARY KEY(model, cluster))` holding the float16
  centroids; new nullable column `message_embedding.cluster` (NULL = not
  assigned yet) with an index on (model, cluster, id). Existing archives
  migrate with all clusters NULL: search keeps the exact full scan until a
  clustering run assigns rows.
- **Trainer.** Deterministic k-means++ on a stride sample (≤ 65536 rows,
  seeded RNG), ≤ 16 Lloyd iterations, empty clusters reseeded to the
  farthest sample point. Assignment and training runs use Accelerate GEMM
  on Apple silicon with an identical scalar fallback (the agreement test
  pattern from the scan). Clustering is triggered from the embedding
  backfill when a model has ≥ 65536 rows and (no centroids yet or ≥ 10%
  of rows unassigned); new vectors are assigned to their nearest centroid
  by the next clustering run, not one at a time.
- **Search.** With centroids present: score the query against every
  centroid with the scalar cosine (≤ ~1k small dots, well under 1 ms),
  probe the top `nprobe` clusters (default 16) plus every NULL-cluster
  row, and run the existing id-ordered batched cosine scan per probed
  cluster into the same bounded keeper — scores for the rows actually
  scored stay exact, ordering and tie-breaking unchanged. Without
  centroids (or when a caller forces it), the behavior is the exact flat
  scan of decision 0045.
- **Correctness detail.** An upsert that rewrites a vector resets its
  cluster to NULL — a changed vector's assignment is stale by definition,
  and a stale assignment would hide the row from the cluster that now
  contains it.
- **Approximation is measured.** `bench-search vector-recall` reports
  recall@limit against the exact scan plus latency per `nprobe`; the
  operating point (nprobe and the recall bar it achieves on the benchmark
  corpus) is recorded in STATUS after measurement. The benchmark archive's
  random vectors cluster worse than real mail embeddings, so its recall is
  a conservative bound.

## Consequences

Search on a clustered archive reads only probed clusters (~1.5% of rows at
nprobe 16 over 1k clusters), well inside the budget with headroom for
machine load. Small archives (the default case) keep the exact flat scan
and its exactness guarantee; cluster building is a bounded, resumable backfill
step, never part of the search path. The cluster column and table are part
of the archive format: core-v14 carries the migration and DESIGN.md the
schema, per the AGENTS.md rule. Deleting a message cascades its embedding
row as before; a re-cluster rebuilds `embedding_cluster` from scratch for
that model, so stale centroids never outlive their rows.
