#!/usr/bin/env bash
#
# V4 deliberately downloads the exact shipping GGUF quantisations named in the
# verified model lock. Re-quantising an already-quantised GGUF is neither
# reproducible nor useful and was a defect in V3's packaging path.
#
# This command remains as a compatibility entrypoint for existing build notes.
# It verifies that the locked outputs are present and answer to their sworn
# SHA-256 digests, exact lengths and parseable GGUF headers; it does not
# transform model weights. T61: the verification lives in the tested Python
# authority scripts/model_provenance.py (its ever-living selftest refuseth
# its own corruptions before any verdict is given), so this shell speaketh
# only the delegation and keepeth the old exit-code faces (nonzero = refuse).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/docs/packaging/MODELS.lock.json"
MODEL_DIR="${GODSTONE_MODEL_DIR:-$ROOT/models}"
WANT_TIER="${1:-ALL}"

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required to validate the model lock" >&2
  exit 1
}

exec python3 "$ROOT/scripts/model_provenance.py" verify \
    --lock "$LOCK" --dest "$MODEL_DIR" --tier "$WANT_TIER"
