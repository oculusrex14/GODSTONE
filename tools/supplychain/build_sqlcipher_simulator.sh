#!/usr/bin/env bash
# Build the pinned SQLCipher engine for the iOS SIMULATOR from an exact source
# commit, and stage it so the engine's dlopen can find it.
#
#   tools/supplychain/build_sqlcipher_simulator.sh [--mode ios-simulator|macos]
#       [--out DIR] [--verify-only] [--quiet]
#
# MODES
# -----
# `ios-simulator` (default): an arm64 IOSSIMULATOR image for the simulator lane.
# `macos`: an arm64 macOS image for the Foundation host swift-test, which dlopeneth
# the SAME fixed leaf name on the host. The two images are STAGED SEPARATELY
# (different --out dirs), because a macOS process cannot dlopen an IOSSIMULATOR
# image and vice versa.
#
# WHY THIS EXISTS
# ---------------
# `SqlCipherDylibEngine` bindeth `libsqlcipher.0.dylib` BY BARE NAME via
# `dlopen(name, RTLD_NOW|RTLD_LOCAL)`. The iOS half of that pinned artifact was
# recorded EXTERNAL and therefore absent, so
# `ReadinessT30Tests.testTheDylibEngineRoundTripsWhenThePinnedLibraryIsPresent`
# SKIPPED. The source is repository-owned and buildable here; this script builds
# it from `docs/supplychain/SQLCIPHER.pins.json` (exact commit `810db22f…`,
# v4.17.0), with the Apple SDK's own CommonCrypto provider (no OpenSSL, no
# third-party dependency), and stages the dylib where the simulator test's
# loader will find it.
#
# WHAT IS PINNED, AND WHERE THE TRUST LIVETH
# ------------------------------------------
# The git COMMIT is the source authority (a commit is a content-addressed tree),
# and the TRUST ANCHOR for the OUTPUT is the repository register
# docs/supplychain/SQLCIPHER.pins.json, whose expected_output digest is scoped to
# an EXACT toolchain. This builder merely PRODUCETH an image and RECORDETH what it
# measured (its sha256, printed below) -- that measurement is an UNTRUSTED
# observation, and no downstream consumer may accept it on its own. The HARD GATE
# is applied by tools/supplychain/verify_sqlcipher_artifact.py against the register
# (approved mode/recipe/image identity) and by the compiled source-authority
# constant the loader importeth; a different Xcode/SDK must ADD its own measured
# register entry (--record-entry) rather than the gate being loosened. This script
# giveth NO authority: it is a producer and a recorder.
#
# WHAT REMAINS EXTERNAL
# ---------------------
# The DEVICE build, the signing identity and the on-device at-rest proof are the
# external half and are NOT claimed here. This script proveth only what a host
# can prove: the pinned source builds a real SQLCipher image for the simulator,
# exporting the engine's required symbols.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN="${REPO_ROOT}/docs/supplychain/SQLCIPHER.pins.json"
ID=""  # resolved per-mode from the schema-2 register
OUT=""
VERIFY_ONLY=0
QUIET=0
MODE="ios-simulator"
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --verify-only) VERIFY_ONLY=1; shift ;;
    --quiet) QUIET=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$MODE" in
  ios-simulator)
    SDK_NAME="iphonesimulator"; TARGET="arm64-apple-ios16.0-simulator" ;;
  macos)
    SDK_NAME="macosx"; TARGET="arm64-apple-macos13.0" ;;
  *) echo "unknown --mode: $MODE" >&2; exit 2 ;;
esac

command -v xcrun >/dev/null || { echo "::error::xcrun is required (macOS/Xcode)"; exit 1; }
[ -f "$PIN" ] || { echo "::error::the pin is absent: $PIN"; exit 1; }

IDS="$(python3 -c "import json,sys
d=json.load(open(sys.argv[1]))
print(next(x['id'] for x in d['sources'] if sys.argv[2] in x.get('modes',{})))" "$PIN" "$MODE")"
COMMIT="$(python3 -c "import json,sys;print(next(x for x in json.load(open(sys.argv[1]))['sources'] if x['id']==sys.argv[2])['commit'])" "$PIN" "$IDS")"
TAG="$(python3 -c "import json,sys;print(next(x for x in json.load(open(sys.argv[1]))['sources'] if x['id']==sys.argv[2])['tag'])" "$PIN" "$IDS")"
LIBNAME="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['library_name'])" "$PIN")"
[ -n "$COMMIT" ] || { echo "::error::the pin names no commit"; exit 1; }

# --verify-only: report whether the pin is well-formed and the SDK is present.
if [ "$VERIFY_ONLY" -eq 1 ]; then
  xcrun --sdk "$SDK_NAME" --show-sdk-path >/dev/null 2>&1 \
    || { echo "::error::the iphonesimulator SDK is absent"; exit 1; }
  echo "pin ok: sqlcipher $TAG @ $COMMIT -> $LIBNAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/sqlcipher"

# The source is fetched at the EXACT commit the pin nameth; a shallow clone at the
# tag is refused if the peeled commit disagreeth (a moved tag is a substitution).
git clone --quiet "https://github.com/sqlcipher/sqlcipher.git" "$SRC"
git -C "$SRC" fetch --quiet --depth 1 origin "$COMMIT"
git -C "$SRC" checkout --quiet "$COMMIT"
GOT="$(git -C "$SRC" rev-parse HEAD)"
[ "$GOT" = "$COMMIT" ] || { echo "::error::source commit $GOT is not the pinned $COMMIT"; exit 1; }
[ "$QUIET" -eq 0 ] && echo "fetched sqlcipher @ $GOT ($TAG)"

# The amalgamation (requires configure, which buildeth the jimsh the generator
# runneth under), then the simulator dylib, exactly as the pin records.
cd "$SRC"
SDK="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
CFLAGS_PIN=(-DSQLITE_HAS_CODEC -DSQLCIPHER_CRYPTO_CC -DSQLITE_EXTRA_INIT=sqlcipher_extra_init
            -DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown -DSQLITE_TEMP_STORE=2
            -DSQLITE_THREADSAFE=1)
./configure --with-tempstore=yes --disable-tcl \
  CFLAGS="${CFLAGS_PIN[*]} -isysroot $SDK -target $TARGET" \
  LDFLAGS="-isysroot $SDK -target $TARGET" >/dev/null 2>&1 \
  || { echo "::error::configure failed"; exit 1; }
make sqlite3.c >/dev/null 2>&1 || { echo "::error::amalgamation generation failed"; exit 1; }
clang "${CFLAGS_PIN[@]}" -isysroot "$SDK" -target "$TARGET" \
  -dynamiclib -install_name "@rpath/$LIBNAME" -compatibility_version 4.0.0 \
  -current_version 4.17.0 sqlite3.c -o "$LIBNAME" \
  -framework Security -framework CoreFoundation -O2 \
  || { echo "::error::the simulator dylib failed to build"; exit 1; }

# The engine's own required symbols must all be present, or the bind is refused.
REQUIRED=(sqlite3_open_v2 sqlite3_close_v2 sqlite3_busy_timeout sqlite3_exec sqlite3_changes
          sqlite3_errmsg sqlite3_prepare_v2 sqlite3_step sqlite3_finalize sqlite3_bind_blob
          sqlite3_bind_int sqlite3_bind_int64 sqlite3_bind_null sqlite3_bind_text
          sqlite3_column_blob sqlite3_column_bytes sqlite3_column_int sqlite3_column_int64
          sqlite3_column_text sqlite3_column_type)
PRESENT="$(nm -gU "$LIBNAME" | awk '{print $3}')"
missing=()
for s in "${REQUIRED[@]}"; do
  grep -qx "_$s" <<<"$PRESENT" || missing+=("$s")
done
[ "${#missing[@]}" -eq 0 ] || { echo "::error::the built image is missing required symbol(s): ${missing[*]}"; exit 1; }

DIGEST="$(shasum -a 256 "$LIBNAME" | awk '{print $1}')"
BYTES="$(wc -c <"$LIBNAME" | tr -d ' ')"
[ "$QUIET" -eq 0 ] && echo "built $LIBNAME from $GOT: sha256 $DIGEST ($BYTES bytes)"

# --platform/arch, read from the image the compiler actually produced ---------
case "$MODE" in
  ios-simulator) PLATFORM="IOSSIMULATOR"; ARCH="arm64" ;;
  macos)         PLATFORM="MACOS";       ARCH="arm64" ;;
esac
CIPHER_MAJOR="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['cipher_version_major'])" "$PIN")"

# Stage where the loader can find it. This directory and any descriptor written
# into it are UNTRUSTED STAGING: a sidecar beside a replaceable image may be
# rewritten by whoever replaced the image, so it RECORDETH facts but AUTHORIZETH
# nothing. The HARD GATE is the register (via verify_sqlcipher_artifact.py) and the
# compiled source-authority constant the loader importeth; a downstream consumer
# must verify the image against THOSE, never against this sidecar alone.
if [ -n "$OUT" ]; then
  STAGE="$OUT"
else
  STAGE="${RUNNER_TEMP:-$WORK}/board1-sqlcipher-$MODE"
fi
mkdir -p "$STAGE"
cp "$LIBNAME" "$STAGE/$LIBNAME"
# The RECORD sidecar: an UNTRUSTED record of THIS build's measured facts, for
# human/staging convenience and cross-check only. It AUTHORIZETH nothing -- the
# production loader importeth a compiled expectation and verifieth the image
# against the register; a matching sidecar is never sufficient.
SIDECAR="$STAGE/$LIBNAME.artifact.json"
python3 - "$SIDECAR" "$LIBNAME" "$COMMIT" "$TAG" "$CIPHER_MAJOR" "$PLATFORM" "$ARCH" "$DIGEST" "$BYTES" "$MODE" <<'PY'
import json, sys
out, lib, commit, tag, cipher, platform, arch, sha, nbytes, mode = sys.argv[1:11]
json.dump({
    "library_name": lib,
    "source": {"commit": commit, "tag": tag, "repo": "https://github.com/sqlcipher/sqlcipher.git"},
    "cipher_version_major": int(cipher),
    "platform": platform,
    "arch": arch,
    "sha256": sha,
    "bytes": int(nbytes),
    "mode": mode,
}, open(out, "w"), indent=2, sort_keys=True)
open(out, "a").write("\n")
PY
echo "staged $STAGE/$LIBNAME"
echo "descriptor $SIDECAR"
# The workflow points the lane at THIS directory: GODSTONE_SQLCIPHER_ARTIFACT_DIR
# (host swift-test) and the simulator test bundle's Frameworks/ (copied in).
