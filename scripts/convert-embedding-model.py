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

MODEL_ID = "BAAI/bge-small-en-v1.5"
MAX_LEN = 512  # bge-small-en-v1.5 max_position_embeddings
PINNED = ["torch==2.7.0", "transformers==4.51.3", "coremltools==9.0"]
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
    vocab_path.write_text("\n".join(tokenizer.get_vocab().keys()) + "\n", encoding="utf-8")
    print(f"Wrote {vocab_path} ({len(tokenizer.get_vocab())} tokens)")

    class CLS(torch.nn.Module):
        def __init__(self, encoder):
            super().__init__()
            self.encoder = encoder

        def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor):
            hidden = self.encoder(input_ids=input_ids, attention_mask=attention_mask)
            return hidden.last_hidden_state[:, 0, :]

    traced = torch.jit.trace(CLS(model).eval(), example_inputs=(
        torch.zeros((1, MAX_LEN), dtype=torch.int32),
        torch.ones((1, MAX_LEN), dtype=torch.int32),
    ))

    print(f"Converting to Core ML (fp16, fixed sequence length {MAX_LEN})")
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, MAX_LEN), dtype="int32"),
            ct.TensorType(name="attention_mask", shape=(1, MAX_LEN), dtype="int32"),
        ],
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
    with torch.no_grad():
        ref = CLS(model)(
            sample["input_ids"].to(torch.int32), sample["attention_mask"].to(torch.int32),
        )
    import numpy as np
    pred = mlmodel.predict({
        "input_ids": sample["input_ids"].to(torch.int32).numpy(),
        "attention_mask": sample["attention_mask"].to(torch.int32).numpy(),
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
    if in_venv(python):
        os.execv(str(python), [str(python), __file__, *sys.argv[1:]])
        return  # pragma: no cover - execv only returns on failure
    print("No virtualenv found; run with --setup first, or pass --venv.", file=sys.stderr)
    raise SystemExit(2)


if __name__ == "__main__":
    main()
