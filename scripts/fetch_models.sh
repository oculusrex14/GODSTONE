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

ROWS_TEXT="$(python3 - "$LOCK" "$WANT_TIER" <<'PY'
import json, pathlib, re, sys

path = pathlib.Path(sys.argv[1])
tier = sys.argv[2]
try:
    lock = json.loads(path.read_text())
except Exception as exc:
    raise SystemExit(f"error: cannot read model lock: {exc}")

if lock.get("schema") != 1:
    raise SystemExit("error: unsupported model-lock schema")
if lock.get("status") != "PINNED":
    raise SystemExit(
        "error: model lock is UNPINNED; independently verify every upstream "
        "artifact and SHA-256 before fetching"
    )
if not lock.get("verified_on") or not lock.get("verified_by"):
    raise SystemExit("error: PINNED lock requires verified_on and verified_by")

rows = []
for item in lock.get("artifacts", []):
    tiers = item.get("tiers", [])
    if tier != "ALL" and tier not in tiers:
        continue
    sha = item.get("sha256")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise SystemExit(f"error: invalid or missing sha256 for {item.get('id')}")
    fields = [item.get("repo"), item.get("source_file"), item.get("output_file")]
    if any(not isinstance(v, str) or not v for v in fields):
        raise SystemExit(f"error: incomplete coordinates for {item.get('id')}")
    if "/" in item["output_file"] or item["output_file"] in {".", ".."}:
        raise SystemExit(f"error: unsafe output_file for {item.get('id')}")
    rows.append("|".join([item["repo"], item["source_file"], item["output_file"], sha]))

if not rows:
    raise SystemExit(f"error: no locked artifacts selected for tier {tier}")
print("\n".join(rows))
PY
)"
# `var=$(cmd)` does NOT trigger `set -e` when cmd fails (a bash gotcha), so the
# Python SystemExit above (UNPINNED / missing checksum / bad coordinates) would
# otherwise be swallowed into an empty ROWS list and the script would exit 0 --
# a FALSE GREEN on the fail-closed production-corpus gate. Guard it explicitly.
rc=$?
if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi
mapfile -t ROWS <<< "$ROWS_TEXT"
if [ "${#ROWS[@]}" -eq 0 ]; then
  echo "error: model lock produced no fetchable artifacts for tier $WANT_TIER" >&2
  exit 1
fi

mkdir -p "$MODEL_DIR"

checksum() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    echo "error: need sha256sum or shasum" >&2
    return 1
  fi
}

download() {
  local url="$1" dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --retry 3 --continue-at - --output "$dest" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget --continue --output-document="$dest" "$url"
  else
    echo "error: need curl or wget" >&2
    return 1
  fi
}

for row in "${ROWS[@]}"; do
  IFS='|' read -r repo source_file output_file want_sha <<< "$row"
  dest="$MODEL_DIR/$output_file"
  part="$dest.part"

  if [[ -f "$dest" && "$(checksum "$dest")" == "$want_sha" ]]; then
    echo "ok       $output_file (already verified)"
    continue
  fi

  rm -f "$part"
  echo "fetching $source_file from $repo"
  download "https://huggingface.co/$repo/resolve/main/$source_file" "$part"

  got="$(checksum "$part")"
  if [[ "$got" != "$want_sha" ]]; then
    echo "error: checksum failed for $output_file" >&2
    echo "       expected $want_sha" >&2
    echo "       got      $got" >&2
    rm -f "$part"
    exit 1
  fi
  mv "$part" "$dest"
  echo "ok       $output_file"
done

echo "locked model artifacts are in $MODEL_DIR"
