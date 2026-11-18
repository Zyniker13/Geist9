# Embedding Model Spike Results

M0 evaluation of on-device embedding models for semantic search.

## Candidates Tested

### all-MiniLM-L6-v2

- **Description:** 22 MB · 384-dim · English-first · Apache-2.0
- **License:** Apache-2.0
- **ONNX model size:** 86.2 MB
- **Quantized ARM size:** 22.0 MB
- **Latency (per query, CPU):** p50=28.24ms p95=53.21ms p99=70.86ms avg=30.82ms
- **Status:** measured

### paraphrase-multilingual-MiniLM-L12-v2

- **Description:** 220 MB · 384-dim · 100+ languages · Apache-2.0
- **License:** Apache-2.0
- **ONNX model size:** 448.5 MB
- **Quantized ARM size:** 112.9 MB
- **Latency (per query, CPU):** p50=342.03ms p95=499.78ms p99=525.53ms avg=348.99ms
- **Status:** measured

### bge-small-en-v1.5

- **Description:** 130 MB · 384-dim · strong multilingual · MIT
- **License:** MIT
- **ONNX model size:** 126.9 MB
- **Latency (per query, CPU):** p50=19.47ms p95=26.07ms p99=30.11ms avg=20.49ms
- **Status:** measured

### nomic-embed-text-v1

- **Description:** 274 MB · 768-dim · open license, multilingual · Apache-2.0
- **License:** Apache-2.0
- **ONNX model size:** 522.2 MB
- **Latency (per query, CPU):** p50=16.84ms p95=31.81ms p99=36.77ms avg=18.7ms
- **Status:** measured

## Notes

- Models downloaded from HuggingFace.
- Latency measured on this machine (Apple silicon).
- Core ML conversion not tested (requires coremltools).
- For Swift on-device inference, Core ML conversion is the production path.
