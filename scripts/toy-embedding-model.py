"""Generate the toy Core ML embedding model used by ArchiveEmbedAppleTests.

Writes toy-embedding.mlmodel next to the test fixtures. The model honors
the adapter contract from Sources/ArchiveEmbedApple/CoreMLEmbedding.swift
(three Int32 inputs shaped [1, S]; a `last_hidden_state` output shaped
[1, S, D]) while being a few kilobytes: the pooled `[CLS]` vector is a
deterministic function of the token IDs and the attention mask, enough
to exercise pooling, normalization, padding, and truncation without any
real model weights.

Regenerate with the Python 3.12 venv from decision 0045:
    python3 scripts/toy-embedding-model.py
"""

import numpy as np
import coremltools as ct
import torch

LENGTH = 16
DIM = 8


class ToyEmbed(torch.nn.Module):
    def __init__(self) -> None:
        super().__init__()
        self.length = LENGTH
        self.dim = DIM
        base = torch.linspace(0.05, 0.75, DIM)
        weight = torch.arange(1.0, DIM + 1.0) * 0.01
        self.register_buffer("base", base)
        self.register_buffer("weight", weight)

    def forward(
        self,
        input_ids: torch.Tensor,
        attention_mask: torch.Tensor,
        token_type_ids: torch.Tensor,
    ) -> torch.Tensor:
        contrib = (
            input_ids.float() * attention_mask.float() + token_type_ids.float()
        ).sum(dim=1, keepdim=True)
        hidden = self.base.view(1, 1, self.dim) + contrib.view(1, 1, 1) * self.weight.view(
            1, 1, self.dim
        )
        return hidden.expand(1, self.length, self.dim)


def main() -> None:
    torch.manual_seed(45)
    model = ToyEmbed()
    traced = torch.jit.trace(
        model.eval(),
        (
            torch.zeros((1, LENGTH), dtype=torch.int32),
            torch.ones((1, LENGTH), dtype=torch.int32),
            torch.zeros((1, LENGTH), dtype=torch.int32),
        ),
    )
    converted = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, LENGTH), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, LENGTH), dtype=np.int32),
            ct.TensorType(name="token_type_ids", shape=(1, LENGTH), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="last_hidden_state")],
        convert_to="neuralnetwork",
    )
    # Sanity check before writing: prediction must run and return [1, LENGTH, DIM].
    result = converted.predict(
        {
            "input_ids": np.zeros((1, LENGTH), dtype=np.int32),
            "attention_mask": np.ones((1, LENGTH), dtype=np.int32),
            "token_type_ids": np.zeros((1, LENGTH), dtype=np.int32),
        }
    )
    array = result["last_hidden_state"]
    assert array.shape == (1, LENGTH, DIM), array.shape
    out_path = "Tests/ArchiveEmbedAppleTests/toy_embedding.mlmodel"
    converted.save(out_path)
    print(f"wrote {out_path} ({array.shape[2]} dims, length {LENGTH})")


if __name__ == "__main__":
    main()
