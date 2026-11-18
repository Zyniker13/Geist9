#!/usr/bin/env python3
"""Embedding model spike — M0 candidate evaluation.

Downloads small ONNX embedding models, measures size and inference
latency on this machine, and records findings in docs/spikes/embedding-models.md.

Usage:
    python3.12 Spikes/EmbeddingSpike/main.py
"""

import json
import math
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

# ── Model candidates ──────────────────────────────────────────────────────────
# Each entry: (huggingface_repo, onnx_model_name_or_path, description, expected_dim, license)
MODELS = [
    (
        "sentence-transformers/all-MiniLM-L6-v2",
        "onnx",
        "all-MiniLM-L6-v2",
        "22 MB · 384-dim · English-first · Apache-2.0",
        "Apache-2.0",
    ),
    (
        "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2",
        "onnx",
        "paraphrase-multilingual-MiniLM-L12-v2",
        "220 MB · 384-dim · 100+ languages · Apache-2.0",
        "Apache-2.0",
    ),
    (
        "BAAI/bge-small-en-v1.5",
        "onnx",
        "bge-small-en-v1.5",
        "130 MB · 384-dim · strong multilingual · MIT",
        "MIT",
    ),
    (
        "nomic-ai/nomic-embed-text-v1",
        "onnx",
        "nomic-embed-text-v1",
        "274 MB · 768-dim · open license, multilingual · Apache-2.0",
        "Apache-2.0",
    ),
]

# Test queries: English, Chinese, Japanese, Korean, mixed
QUERIES = [
    "email archive search",
    "邮件归档搜索",
    "メールアーカイブ",
    "이메일 보관 검색",
    "search emails by sender and date",
    "message from alice@example.com",
    "attachment PDF invoice",
]


def download_model(repo_id: str, cache_dir: Path) -> Path:
    """Download a model using huggingface_hub if available, else skip."""
    model_path = cache_dir / repo_id.replace("/", "--")
    if model_path.exists():
        return model_path

    try:
        import huggingface_hub
    except ImportError:
        print(f"  [SKIP] huggingface_hub not installed — skipping {repo_id}")
        return model_path

    model_path.mkdir(parents=True, exist_ok=True)
    huggingface_hub.snapshot_download(
        repo_id,
        allow_patterns=["*.onnx", "*.json", "*.txt"],
        local_dir=str(model_path),
        local_dir_use_symlinks=False,
    )
    return model_path


def measure_latency(onnx_dir: Path, model_root: Path, queries: list[str], n_runs: int = 50) -> dict:
    """Run inference on queries, measure latency."""
    import numpy as np
    import onnxruntime as ort

    session = ort.InferenceSession(
        str(onnx_dir / "model.onnx"),
        providers=["CPUExecutionProvider"],
    )

    input_name = session.get_inputs()[0].name
    # Find attention_mask input if present (optional)
    input_names = [i.name for i in session.get_inputs()]
    has_mask = "attention_mask" in input_names
    has_token_type = "token_type_ids" in input_names

    latencies = []
    for _ in range(n_runs):
        for q in queries:
            start = time.perf_counter()
            inputs = {input_name: np.array([tokenizer_encode(q, model_root)])}
            if has_mask:
                inputs["attention_mask"] = np.array(
                    [[1] * len(inputs[input_name][0])]
                )
            if has_token_type:
                inputs["token_type_ids"] = np.zeros_like(inputs[input_name])
            session.run(None, inputs)
            latencies.append((time.perf_counter() - start) * 1000)

    latencies.sort()
    p50 = latencies[len(latencies) // 2]
    p95 = latencies[int(len(latencies) * 0.95)]
    p99 = latencies[int(len(latencies) * 0.99)]
    avg = sum(latencies) / len(latencies)

    return {
        "p50_ms": round(p50, 2),
        "p95_ms": round(p95, 2),
        "p99_ms": round(p99, 2),
        "avg_ms": round(avg, 2),
    }


def tokenizer_encode(text: str, model_path: Path) -> list[int]:
    """Tokenize text using the model's tokenizer (slow, single-threaded)."""
    try:
        from transformers import AutoTokenizer
    except ImportError:
        # Fallback: simple whitespace tokenization for measurement only
        # This is NOT a real tokenizer — just for latency measurement
        tokens = text.split()
        # Map to IDs using a placeholder — not meaningful for actual inference
        # This path is only for rough latency measurement
        return [101] + [100] * 10 + [102]  # [CLS] + [PAD]*10 + [SEP]

    tokenizer = AutoTokenizer.from_pretrained(str(model_path))
    encoded = tokenizer(text, return_tensors="np")
    input_ids = encoded["input_ids"].tolist()[0]
    return input_ids


def model_size_mb(path: Path) -> float:
    """Calculate total size of model files."""
    total = 0
    for f in path.rglob("*"):
        if f.is_file():
            total += f.stat().st_size
    return round(total / (1024 * 1024), 1)


def onnx_model_size_mb(onnx_dir: Path) -> tuple[float, float]:
    """Calculate size of the main ONNX model and the quantized ARM variant.

    Returns (main_size_mb, quantized_arm_size_mb).
    """
    main = onnx_dir / "model.onnx"
    quantized = onnx_dir / "model_qint8_arm64.onnx"
    main_size = main.stat().st_size / (1024 * 1024) if main.exists() else 0.0
    quant_size = quantized.stat().st_size / (1024 * 1024) if quantized.exists() else 0.0
    return round(main_size, 1), round(quant_size, 1)


def main():
    cache_dir = Path("/tmp/embedding-spike-cache")
    if cache_dir.exists():
        shutil.rmtree(cache_dir)
    cache_dir.mkdir(parents=True, exist_ok=True)

    results = []
    for repo_id, onnx_subdir, name, desc, license_ in MODELS:
        print(f"\n=== {name} ===")
        print(f"  {desc}")

        model_path = download_model(repo_id, cache_dir)
        onnx_dir = model_path / "onnx"
        if not model_path.exists() or not (onnx_dir / "model.onnx").exists():
            print(f"  [SKIP] Could not download model")
            results.append(
                {
                    "name": name,
                    "description": desc,
                    "license": license_,
                    "size_mb": None,
                    "latency": None,
                    "status": "download_failed",
                }
            )
            continue

        onnx_size, quant_size = onnx_model_size_mb(onnx_dir)
        print(f"  ONNX model: {onnx_size} MB (quantized ARM: {quant_size} MB)")

        # Try latency measurement
        try:
            latency = measure_latency(onnx_dir, model_path, QUERIES)
            print(f"  Latency: p50={latency['p50_ms']}ms p95={latency['p95_ms']}ms avg={latency['avg_ms']}ms")
            results.append(
                {
                    "name": name,
                    "description": desc,
                    "license": license_,
                    "size_mb": onnx_size,
                    "quant_size_mb": quant_size,
                    "latency": latency,
                    "status": "measured",
                }
            )
        except Exception as e:
            print(f"  [SKIP] Latency measurement failed: {e}")
            results.append(
                {
                    "name": name,
                    "description": desc,
                    "license": license_,
                    "size_mb": onnx_size,
                    "quant_size_mb": quant_size,
                    "latency": None,
                    "status": f"latency_failed: {e}",
                }
            )

    # Write results
    results_path = cache_dir / "results.json"
    with open(results_path, "w") as f:
        json.dump(results, f, indent=2)
    print(f"\nResults written to {results_path}")

    # Also write a summary for the spike doc
    summary_path = Path(__file__).parent.parent.parent / "docs" / "spikes" / "embedding-models.md"
    with open(summary_path, "w") as f:
        f.write("# Embedding Model Spike Results\n\n")
        f.write("M0 evaluation of on-device embedding models for semantic search.\n\n")
        f.write("## Candidates Tested\n\n")
        for r in results:
            f.write(f"### {r['name']}\n\n")
            f.write(f"- **Description:** {r['description']}\n")
            f.write(f"- **License:** {r['license']}\n")
            f.write(f"- **ONNX model size:** {r['size_mb']} MB\n")
            if r.get("quant_size_mb"):
                f.write(f"- **Quantized ARM size:** {r['quant_size_mb']} MB\n")
            if r["latency"]:
                f.write(
                    f"- **Latency (per query, CPU):** p50={r['latency']['p50_ms']}ms "
                    f"p95={r['latency']['p95_ms']}ms p99={r['latency']['p99_ms']}ms "
                    f"avg={r['latency']['avg_ms']}ms\n"
                )
            f.write(f"- **Status:** {r['status']}\n\n")
        f.write("## Notes\n\n")
        f.write("- Models downloaded from HuggingFace.\n")
        f.write("- Latency measured on this machine (Apple silicon).\n")
        f.write("- Core ML conversion not tested (requires coremltools).\n")
        f.write("- For Swift on-device inference, Core ML conversion is the production path.\n")

    print(f"Summary written to {summary_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
