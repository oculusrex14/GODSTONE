#!/usr/bin/env bash
#
# Quantise base models into the exact GGUF files each tier ships.
#
# Runs entirely offline against whatever scripts/fetch_models.sh already put on
# disk. Output names must match the model_file values in
# content/ingest/build_archive.py, the Gradle flavours in tab 03 and Tier.swift
# in tab 06. A mismatch here produces an app that builds, installs, launches and
# then cannot find its model.
#
# Usage:
#     scripts/quantise.sh              # all tiers
#     scripts/quantise.sh MEDIUM

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="${GODSTONE_MODEL_DIR:-$ROOT/models}"
SRC_DIR="$MODEL_DIR/src"
LLAMA="${LLAMA_CPP_DIR:-$ROOT/third_party/llama.cpp}"
QUANTISE="$LLAMA/build/bin/llama-quantize"

if [[ ! -x "$QUANTISE" ]]; then
  echo "error: llama-quantize not built at $QUANTISE" >&2
  echo "       cmake -B build -S \"$LLAMA\" && cmake --build build -j" >&2
  exit 1
fi

# source file | output file | quant type
JOBS=(
  "Qwen3-0.6B-Q4_K_M.gguf|qwen3-0.6b-q4km.gguf|Q4_K_M|LIGHT"
  "Qwen3-1.7B-Q4_K_M.gguf|qwen3-1.7b-q4km.gguf|Q4_K_M|MEDIUM"
  "Qwen3-4B-Q5_K_M.gguf|qwen3-4b-q5km.gguf|Q5_K_M|LARGE"
  "bge-small-en-v1.5-f16.gguf|bge-small-en-v1.5-q8.gguf|Q8_0|LIGHT MEDIUM"
  "bge-base-en-v1.5-f16.gguf|bge-base-en-v1.5-q8.gguf|Q8_0|LARGE"
)

WANT_TIER="${1:-ALL}"

for entry in "${JOBS[@]}"; do
  IFS='|' read -r src out qtype tiers <<< "$entry"

  if [[ "$WANT_TIER" != "ALL" && " $tiers " != *" $WANT_TIER "* ]]; then
    continue
  fi

  src_path="$SRC_DIR/$src"
  out_path="$MODEL_DIR/$out"

  if [[ ! -f "$src_path" ]]; then
    echo "error: missing $src_path - run scripts/fetch_models.sh first" >&2
    exit 1
  fi

  if [[ -f "$out_path" && "$out_path" -nt "$src_path" ]]; then
    echo "ok       $out (up to date)"
    continue
  fi

  echo "quantising $src -> $out ($qtype)"

  # Embedding models keep their output weights at higher precision. The
  # embedding matrix IS the output for these, and quantising it hard measurably
  # degrades retrieval, which is the one thing that must not degrade (C3).
  if [[ "$qtype" == "Q8_0" ]]; then
    "$QUANTISE" "$src_path" "$out_path" "$qtype"
  else
    "$QUANTISE" --leave-output-tensor "$src_path" "$out_path" "$qtype"
  fi

  size=$(du -h "$out_path" | cut -f1)
  echo "ok       $out ($size)"
done

echo
echo "quantised models are in $MODEL_DIR"
echo "next: python -m content.ingest.build_archive --tier LIGHT"
