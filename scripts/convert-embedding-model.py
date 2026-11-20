#!/usr/bin/env python3.12
"""Convert BAAI/bge-small-en-v1.5 to a Core ML package for the archiver.

Downloads the model and its WordPiece vocabulary from Hugging Face, traces
the encoder's [CLS] hidden state, and converts it to an .mlpackage plus the
vocab.txt the Swift WordPieceTokenizer loads next to the model.

The weights are never committed to this repository: run this script locally
and place the two outputs in Application Support/Bristlecone/Models (or the
app bundle) as described in docs/DESIGN.md. Default output directory is
next to the script, ignored by git.

Usage:
    python3.12 scripts/convert-embedding-model.py --setup
    python3.12 scripts/convert-embedding-model.py [--out DIR] [--venv VENV]

`--setup` creates/repairs the virtualenv at <out-dir>/embedding-venv with
the pinned, mutually tested dependency set (torch 2.7.0 is the newest torch
coremltools 9.0 documents support; transformers 4.51.3). Subsequent runs
use that venv's interpreter automatically.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import venv
from pathlib import Path

import numpy as np

MODEL_ID = "BAAI/bge-small-en-v1.5"
MAX_LEN = 512  # bge-small-en-v1.5 max_position_embeddings
PINNED = ["torch==2.7.0", "transformers==4.51.3", "coremltools==9.0", "numpy==2.5.5"]
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_OUT = SCRIPT_DIR.parent / "tmp-embedding-model"


def setup_venv(venv_dir: Path) -> None:
    print(f"Creating virtualenv at {venv_dir}")
    builder = venv.EnvBuilder(with_pip=True, upgrade_deps=True)
    builder.create(venv_dir)
    pip = venv_dir / "bin" / "pip"
    subprocess.run([str(pip), "install", "--quiet", *PINNED], check=True)
    print("Virtualenv ready:", venv_dir)


def venv_python(venv_dir: Path) -> Path:
    return venv_dir / "bin" / "python"


def in_venv(python: Path) -> bool:
    return python.is_file()


def convert(out_dir: Path) -> None:
    import coremltools as ct
    import torch
    from transformers import AutoModel, AutoTokenizer

    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading {MODEL_ID} from the Hugging Face cache")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    model = AutoModel.from_pretrained(MODEL_ID)
    model.eval()

    vocab_path = out_dir / "bge-small-en-v1.5-vocab.txt"
    # The vocab file is the Swift tokenizer's id table: line N must BE id
    # N, because WordPieceTokenizer assigns ids by file position. HF's
    # get_vocab() returns a token->id dict whose key order is NOT the id
    # order (a scrambled file makes every Swift token id wrong — the model
    # then embeds near-random vectors that still look deterministic and
    # unit-normalized, so only a known-id check catches it). Write the
    # tokens sorted by id, then verify the round trip.
    token_to_id = tokenizer.get_vocab()
    ordered = sorted(token_to_id.items(), key=lambda kv: kv[1])
    vocab_lines = [token for token, _ in ordered]
    expected = sorted(token_to_id.values())
    if [token_to_id[token] for token in vocab_lines] != expected:
        raise SystemExit("vocab ids are not a contiguous 0..N-1 range; refusing to write")
    vocab_path.write_text("\n".join(vocab_lines) + "\n", encoding="utf-8")
    roundtrip = tokenizer.convert_ids_to_tokens(list(range(min(8, len(vocab_lines)))))
    file_sample = vocab_lines[: len(roundtrip)]
    if roundtrip != file_sample:
        raise SystemExit(
            "vocab round trip failed: first lines %r do not match ids %r"
            % (file_sample, roundtrip)
        )
    print(f"Wrote {vocab_path} ({len(vocab_lines)} tokens, id order verified)")

    class CLS(torch.nn.Module):
        def __init__(self, encoder):
            super().__init__()
            self.encoder = encoder

        def forward(
            self, input_ids: torch.Tensor,
            attention_mask: torch.Tensor,
            token_type_ids: torch.Tensor,
        ):
            hidden = self.encoder(
                input_ids=input_ids,
                attention_mask=attention_mask,
                token_type_ids=token_type_ids,
            )
            return hidden.last_hidden_state[:, 0, :]

    # torch.export (decomposed) rather than jit.trace: coremltools 9's trace
    # frontend fails on the embeddings' int cast with a multi-element
    # constant ("only 0-dimensional arrays can be converted to Python
    # scalars"); the torch.export frontend handles it. The exported graph
    # signature carries the input names the Swift adapter looks up, so no
    # inputs= list is passed here.
    exported = torch.export.export(CLS(model).eval(), args=(
        torch.zeros((1, MAX_LEN), dtype=torch.int32),
        torch.ones((1, MAX_LEN), dtype=torch.int32),
        torch.zeros((1, MAX_LEN), dtype=torch.int32),
    )).run_decompositions()

    print(f"Converting to Core ML (fp16, fixed sequence length {MAX_LEN})")
    mlmodel = ct.convert(
        exported,
        outputs=[ct.TensorType(name="cls_hidden_state")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    package = out_dir / "bge-small-en-v1.5.mlpackage"
    mlmodel.save(str(package))

    # Self-check: the Core ML prediction must track torch closely.
    sample = tokenizer(
        ["Example document text for the archive index."],
        truncation=True, max_length=MAX_LEN, padding="max_length", return_tensors="pt",
    )
    zeros = torch.zeros_like(sample["input_ids"]).to(torch.int32)
    with torch.no_grad():
        ref = CLS(model)(
            sample["input_ids"].to(torch.int32),
            sample["attention_mask"].to(torch.int32),
            zeros,
        )
    pred = mlmodel.predict({
        "input_ids": sample["input_ids"].to(torch.int32).numpy(),
        "attention_mask": sample["attention_mask"].to(torch.int32).numpy(),
        "token_type_ids": zeros.numpy(),
    })["cls_hidden_state"]
    delta = float(np.abs(np.asarray(ref) - np.asarray(pred)).max())
    print(f"Self-check max |torch - coreml| = {delta:.5f} (fp16 tolerance ~1e-2)")
    if delta > 0.05:
        raise SystemExit("Core ML output deviates from torch beyond fp16 tolerance")

    meta = {"model_id": MODEL_ID, "sequence_length": MAX_LEN, "hidden": 384,
            "max_abs_error": delta}
    (out_dir / "bge-small-en-v1.5.json").write_text(json.dumps(meta, indent=2) + "\n")
    print("Done:", package)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--venv", type=Path, default=None,
                        help="virtualenv to use/create (default <out>/embedding-venv)")
    parser.add_argument("--setup", action="store_true",
                        help="create the virtualenv and exit")
    args = parser.parse_args()
    venv_dir = args.venv or (args.out / "embedding-venv")

    if args.setup:
        setup_venv(venv_dir)
        return

    python = venv_python(venv_dir)
    if not in_venv(python):
        print("No virtualenv found; run with --setup first, or pass --venv.", file=sys.stderr)
        raise SystemExit(2)
    if python.resolve() != Path(sys.executable).resolve():
        # Re-exec under the venv interpreter. Skipped when we already are that
        # interpreter: execv from a job-controlled background shell can wedge
        # the replacement process before it prints anything.
        os.execv(str(python), [str(python), __file__, *sys.argv[1:]])
        return  # pragma: no cover - execv only returns on failure
    convert(args.out)


if __name__ == "__main__":
    main()
