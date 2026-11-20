# 0047 — Capability-gated semantic evaluation

## Context
The relevance runner (`RelevanceRunner`) evaluates hybrid search against a
judged set (`qrels.json`).  Queries may require a capability (e.g. `"semantic"`)
that is only available when an embedding model is present.  When the capability
is missing the gate should not penalise the system for not having that feature.

## Decision
- `QrelsFile.Query` gains a `requires: [String]` field (decoded from the JSON).
- `RelevanceRunner` splits its output into `RelevanceSlice` structs, one per
  capability that was exercised (`"keyword"` and/or `"semantic"`).
- The gate aggregate (`RelevanceRun.gate`) only considers slices whose
  capabilities are available.  A semantic query with `requires: ["semantic"]`
  is excluded from the keyword gate when no model is provided.
- `RelevanceQueryScore` gains a `topRank: Int` (1-based rank of the best
  relevant message, 0 when none found).

## Consequences
- Gate tests (`RelevanceGateTests`) pass without a model (keyword-only).
- Semantic slice tests (`SemanticSliceTests`) run only when a model is present
  and can verify semantic retrieval quality.
- The judged set can express capability requirements per query.
