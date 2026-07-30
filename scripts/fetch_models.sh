#!/usr/bin/env bash
#
# Fetch the base models Godstone quantises and ships.
#
# This is the ONLY script in the repository that is allowed to touch the
# network, and it is a developer tool. It is never invoked by the build, never
# invoked by CI on a release branch, and no part of either app can reach it.
# Constraint C1 is about the shipped product; somebody has to download the
# weights once.
#
# Usage:
#     scripts/fetch_models.sh              # all tiers
#     scripts/fetch_models.sh LIGHT        # one tier
#     GODSTONE_MODEL_DIR=/mnt/big scripts/fetch_models.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL_DIR="${GODSTONE_MODEL_DIR:-$ROOT/models}"
SRC_DIR="$MODEL_DIR/src"

mkdir -p "$SRC_DIR"

# repo | file | sha256 | tiers
#
# Pinned by hash, not by tag. A tag can be moved; a hash cannot. If an upstream
# repository silently republishes different weights the checksum fails and the
# build stops, which is the correct outcome.
MODELS=(
  "Qwen/Qwen3-0.6B-GGUF|Qwen3-0.6B-Q4_K_M.gguf|9f2a4c81d7e0b53628a1fc94d0e7b3a562189cf40b7e2d85a3c016f9b48e7d20|LIGHT"
  "Qwen/Qwen3-1.7B-GGUF|Qwen3-1.7B-Q4_K_M.gguf|c3e70b18a95d24f6810be3c7d92a05f14e8b6072c5d9a381f0b46e2c7a9d5310|MEDIUM"
  "Qwen/Qwen3-4B-GGUF|Qwen3-4B-Q5_K_M.gguf|5b1d92e0c874a3f6209d1e7b48c50a3f6e2b91d70c845fa3e17b0d629c4a8f31|LARGE"
  "BAAI/bge-small-en-v1.5|bge-small-en-v1.5-f16.gguf|a70c5e3182d94b6f051ae8c37b2d940f81e6c5a29d3b074f8e12a6c5093bd748|LIGHT MEDIUM"
  "BAAI/bge-base-en-v1.5|bge-base-en-v1.5-f16.gguf|18d4b6a09e5c7f231840ba9d6e0c58f37a29b1d40e6c839f5a71b02d4c9e6318|LARGE"
)

WANT_TIER="${1:-ALL}"

have() { command -v "$1" >/dev/null 2>&1; }

if have sha256sum; then
  checksum() { sha256sum "$1" | cut -d' ' -f1; }
elif have shasum; then
  checksum() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  echo "error: need sha256sum or shasum" >&2
  exit 1
fi

download() {
  local url="$1" dest="$2"
  if have curl; then
    # --fail so an HTML error page is never written to a .gguf file, and
    # --continue-at so a dropped connection does not restart 3 GB.
    curl --fail --location --continue-at - --output "$dest" "$url"
  elif have wget; then
    wget --continue --output-document="$dest" "$url"
  else
    echo "error: need curl or wget" >&2
    exit 1
  fi
}

for entry in "${MODELS[@]}"; do
  IFS='|' read -r repo file want_sha tiers <<< "$entry"

  if [[ "$WANT_TIER" != "ALL" && " $tiers " != *" $WANT_TIER "* ]]; then
    continue
  fi

  dest="$SRC_DIR/$file"

  if [[ -f "$dest" ]]; then
    got="$(checksum "$dest")"
    if [[ "$got" == "$want_sha" ]]; then
      echo "ok       $file (already present)"
      continue
    fi
    echo "warning  $file checksum mismatch, re-downloading" >&2
    rm -f "$dest"
  fi

  echo "fetching $file from $repo"
  download "https://huggingface.co/$repo/resolve/main/$file" "$dest"

  got="$(checksum "$dest")"
  if [[ "$got" != "$want_sha" ]]; then
    echo "error    $file checksum FAILED" >&2
    echo "         expected $want_sha" >&2
    echo "         got      $got" >&2
    rm -f "$dest"
    exit 1
  fi
  echo "ok       $file"
done

echo
echo "base models are in $SRC_DIR"
echo "next: scripts/quantise.sh"
