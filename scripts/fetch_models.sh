#!/usr/bin/env bash
#
# Fetch the exact, pre-quantised GGUF artifacts declared in
# docs/packaging/MODELS.lock.json.
#
# This developer-only script is the repository's sole model-network path. It
# fails closed while the lock is UNPINNED or any checksum is absent. Never
# replace a missing checksum with a guessed value: verify the upstream artifact,
# record who verified it and when, then change status to PINNED.
#
# T61 reformation: the download/verify/promote machinery lived here in bash
# once and carried a bash-4-only array-slurping builtin unknown to macOS's
# bash 3.2, a mutable
# 'resolve/main/' coordinate and an unverified mv -- each a defect the card
# nameth. It now liveth in the tested Python authority
# scripts/model_provenance.py: bounded temporary files (.part with a hard
# ceiling at the declared size), verification of digest, length AND the
# parseable GGUF header before any promotion, atomic os.replace promotion, a
# corrupt standing destination refused rather than silently overwritten, and
# immutable commit coordinates (source_commit, never a branch head such as
# 'main'). This shell keepeth only its fail-closed preflight -- so the CI's
# textual gate (ci/integration.py, letter K) still seeth the refusal at its
# source -- and than delegateth. Nothing here is ever wired into the shipping
# runtime; the apps carry packaged bytes and verify them through the
# provenance gates on each isle (io.godstone.llm.provenance / GodstoneLLMProvenance).
#
# Usage:
#     scripts/fetch_models.sh
#     scripts/fetch_models.sh LIGHT
#     GODSTONE_MODEL_DIR=/mnt/big scripts/fetch_models.sh MEDIUM

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/docs/packaging/MODELS.lock.json"
MODEL_DIR="${GODSTONE_MODEL_DIR:-$ROOT/models}"
WANT_TIER="${1:-ALL}"

case "$WANT_TIER" in
  ALL|LIGHT|MEDIUM|LARGE) ;;
  *) echo "error: tier must be ALL, LIGHT, MEDIUM or LARGE" >&2; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 is required to validate the model lock" >&2
  exit 1
}

# Fail-closed preflight. A simple command under `set -e` propagateth its
# exit code directly (unlike the old captured `ROWS_TEXT="$(python3 ...)"`,
# whose SystemExit could perish silently into an empty list and a FALSE
# GREEN on the production-corpus gate). The authority re-checketh every
# claim below independently and in its own voice.
python3 - "$LOCK" "$WANT_TIER" <<'PY'
import json, pathlib, re, sys

path = pathlib.Path(sys.argv[1])
tier = sys.argv[2]
try:
    lock = json.loads(path.read_text())
except Exception as exc:
    raise SystemExit(f"error: cannot read model lock: {exc}")

if lock.get("schema") not in {1, 2}:
    raise SystemExit("error: unsupported model-lock schema")
if lock.get("status") != "PINNED":
    raise SystemExit(
        "error: model lock is UNPINNED; independently verify every upstream "
        "artifact and SHA-256 before fetching"
    )
if not lock.get("verified_on") or not lock.get("verified_by"):
    raise SystemExit("error: PINNED lock requires verified_on and verified_by")

selected = 0
for item in lock.get("artifacts", []):
    if tier != "ALL" and tier not in item.get("tiers", []):
        continue
    selected += 1
    sha = item.get("sha256")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise SystemExit(f"error: invalid or missing sha256 for {item.get('id')}")
if not selected:
    raise SystemExit(f"error: no locked artifacts selected for tier {tier}")
PY

# The delegation: bounded temporary files, digest/length/header verification,
# atomic promotion and immutable coordinates all live in the tested Python
# authority, whose ever-living selftest refuseth its own corruptions before
# any verdict is given.
exec python3 "$ROOT/scripts/model_provenance.py" fetch \
    --lock "$LOCK" --dest "$MODEL_DIR" --tier "$WANT_TIER"
