#!/usr/bin/env bash
#
# V4 deliberately downloads the exact shipping GGUF quantisations named in the
# verified model lock. Re-quantising an already-quantised GGUF is neither
# reproducible nor useful and was a defect in V3's packaging path.
#
# This command remains as a compatibility entrypoint for existing build notes.
# It verifies that the locked outputs are present and match their SHA-256 values;
# it does not transform model weights.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/docs/packaging/MODELS.lock.json"
MODEL_DIR="${GODSTONE_MODEL_DIR:-$ROOT/models}"
WANT_TIER="${1:-ALL}"

python3 - "$LOCK" "$MODEL_DIR" "$WANT_TIER" <<'PY'
import hashlib, json, pathlib, re, sys

lock_path, model_dir, tier = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
if tier not in {"ALL", "LIGHT", "MEDIUM", "LARGE"}:
    raise SystemExit("error: tier must be ALL, LIGHT, MEDIUM or LARGE")
lock = json.loads(lock_path.read_text())
if lock.get("status") != "PINNED":
    raise SystemExit("error: model lock is UNPINNED; run no release packaging")

checked = 0
for item in lock.get("artifacts", []):
    if tier != "ALL" and tier not in item.get("tiers", []):
        continue
    sha = item.get("sha256")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise SystemExit(f"error: invalid sha256 for {item.get('id')}")
    path = model_dir / item["output_file"]
    if not path.is_file():
        raise SystemExit(f"error: missing {path}; run scripts/fetch_models.sh first")
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    got = h.hexdigest()
    if got != sha:
        raise SystemExit(f"error: checksum mismatch for {path.name}: {got}")
    print(f"ok       {path.name}")
    checked += 1
if not checked:
    raise SystemExit(f"error: no locked artifacts selected for tier {tier}")
print("model set is verified; no re-quantisation is required")
PY
