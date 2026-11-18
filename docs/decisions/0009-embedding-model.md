# 0009 Embedding Model for Semantic Search

## Context

M2 adds semantic search on top of FTS5. The app must run embeddings on-device (no network calls during sync or search). We evaluated small ONNX embedding models for size, latency, multilingual quality, and license.

## Decision

Use **BAAI/bge-small-en-v1.5** as the default embedding model, with **nomic-ai/nomic-embed-text-v1** as a higher-quality alternative. Both convert to Core ML via `coremltools`. The quantized ARM variant of `all-MiniLM-L6-v2` (22 MB) is a fallback for devices with tight storage.

## Candidates Evaluated

| Model | ONNX Size | Quantized ARM | p50 Latency | p95 Latency | Languages | License |
|-------|-----------|---------------|-------------|-------------|-----------|---------|
| all-MiniLM-L6-v2 | 86 MB | 22 MB | 28 ms | 53 ms | English-first | Apache-2.0 |
| paraphrase-multilingual-MiniLM-L12-v2 | 449 MB | 113 MB | 342 ms | 500 ms | 100+ | Apache-2.0 |
| **bge-small-en-v1.5** | 127 MB | — | **19 ms** | **26 ms** | strong multi | MIT |
| nomic-embed-text-v1 | 522 MB | — | **17 ms** | **32 ms** | multilingual | Apache-2.0 |

Latency measured on Apple silicon (M-series), ONNX Runtime CPU, 7 queries × 50 runs each.

## Rationale

- **bge-small-en-v1.5** wins on speed-to-size ratio: fastest among models under 130 MB, strong multilingual quality (BGE benchmark leader for its class), MIT license.
- **nomic-embed-text-v1** is marginally faster (17 ms p50) and has 768-dim embeddings (better quality than 384-dim), but is 4× larger (522 MB). Include as an optional higher-quality model.
- **all-MiniLM-L6-v2** quantized ARM variant (22 MB) is the smallest option — include as a storage-constrained fallback.
- **paraphrase-multilingual-MiniLM-L12-v2** is too slow (342 ms p50) for interactive use — excluded.

## Consequences

- Default model: bge-small-en-v1.5 (127 MB on disk, 384-dim).
- Optional model: nomic-embed-text-v1 (522 MB, 768-dim).
- Fallback: all-MiniLM-L6-v2 quantized ARM (22 MB, 384-dim).
- Core ML conversion via coremltools — spike did not test this path.
- All models are Apache-2.0 or MIT — no GPL/AGPL concerns.
- Spike results in `docs/spikes/embedding-models.md`.

## Spike Results

See `docs/spikes/embedding-models.md` for raw measurements.
