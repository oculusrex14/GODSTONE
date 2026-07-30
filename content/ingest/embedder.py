"""Embedding generation and int8 quantisation.

Runs llama.cpp locally through llama-cpp-python. The same GGUF embedding model
is later shipped inside the app, so a vector produced here and a vector produced
on the phone at query time land in the same space. If they did not, semantic
search would return noise and the whole hybrid retriever would silently degrade
to lexical-only.

Vectors are stored int8. At LARGE tier, 400k chunks at 768 dims is 1.2 GB in
float32 and 300 MB in int8. The recall difference is under one percent on the
eval set in tab 12; the storage difference decides whether the app installs.
"""

from __future__ import annotations

import math
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODEL_DIR = Path(os.environ.get("GODSTONE_MODEL_DIR", ROOT / "models"))


class Embedder:
    """Thin wrapper over a GGUF embedding model.

    Loaded once per build. Constructing a llama context costs seconds; doing it
    per chunk would make a LARGE build take days instead of hours.
    """

    def __init__(self, model_file: str, dim: int, threads: int | None = None):
        from llama_cpp import Llama

        path = MODEL_DIR / model_file
        if not path.exists():
            raise SystemExit(
                f"embedding model not found: {path}\n"
                f"run scripts/fetch_models.sh first (nothing is downloaded "
                f"during the build - constraint C1)"
            )

        self.dim = dim
        self._llm = Llama(
            model_path=str(path),
            embedding=True,
            n_ctx=512,
            n_threads=threads or (os.cpu_count() or 4),
            verbose=False,
        )

    def encode(self, text: str) -> list[float]:
        """L2-normalised float embedding.

        Normalising here means the retrievers can use a plain dot product as
        cosine similarity, which is what both of them actually do.
        """
        raw = self._llm.create_embedding(text)["data"][0]["embedding"]

        # llama.cpp returns a token matrix for some models and a single pooled
        # vector for others. Mean-pool when needed so both shapes behave the
        # same way; this mirrors the mean pooling in LlamaBridge.mm embed().
        if raw and isinstance(raw[0], list):
            cols = len(raw[0])
            pooled = [0.0] * cols
            for row in raw:
                for i, v in enumerate(row):
                    pooled[i] += v
            raw = [v / len(raw) for v in pooled]

        if len(raw) != self.dim:
            raise ValueError(
                f"embedding model returned {len(raw)} dims, tier expects {self.dim}"
            )

        norm = math.sqrt(sum(v * v for v in raw)) or 1.0
        return [v / norm for v in raw]

    def encode_int8(self, text: str) -> tuple[bytes, float]:
        """Embedding quantised to signed bytes, plus the scale used."""
        return quantise_int8(self.encode(text))

    def close(self) -> None:
        self._llm = None


def quantise_int8(vec: list[float]) -> tuple[bytes, float]:
    """Symmetric per-vector int8 quantisation.

    Symmetric (a single scale, no zero point) because the input is already
    L2-normalised and therefore centred near zero. Per-vector rather than a
    global scale because it costs one float per chunk and removes any dependence
    on corpus-wide statistics, which keeps the build deterministic even when
    documents are added.

    The dequantisation on the device is deliberately trivial:
        value = byte / 127.0
    which is exactly what Retriever.kt and RagPipeline.swift both do.
    """
    peak = max((abs(v) for v in vec), default=0.0)
    if peak == 0.0:
        return bytes(len(vec)), 1.0

    out = bytearray(len(vec))
    for i, v in enumerate(vec):
        q = int(round((v / peak) * 127.0))
        # Clamp to -127 rather than -128 so the range is symmetric and the
        # device-side divide by 127.0 can never exceed 1.0.
        q = max(-127, min(127, q))
        out[i] = q & 0xFF
    return bytes(out), peak


def dequantise_int8(blob: bytes) -> list[float]:
    """Inverse of quantise_int8, used by the eval harness in tab 12."""
    return [((b - 256) if b > 127 else b) / 127.0 for b in blob]
