#!/usr/bin/env bash
# Stage the STOCK (plain, non-SQLCipher) SQLite oracle the GF-004 courts bind at runtime.
#
#   tools/supplychain/stage_stock_sqlite.sh --runtime-root DIR [--out DIR] [--bundle DIR]
#   tools/supplychain/stage_stock_sqlite.sh --udid UDID        [--out DIR] [--bundle DIR]
#
# WHY THIS EXISTS
# ---------------
# `GsFinal004OwnedConnectionTests` (the empty-DEK and stock-cipher refusals) needs a REALLY BOUND image
# carrying the full `sqlite3_*` surface but NO cipher, so the probe that deciding at-rest can be exercised.
# It hardcoded `/usr/lib/libsqlite3.dylib` -- which is ABSENT as a plain file on the iOS SIMULATOR: the
# simulator resolve that path THROUGH the runtime root (`$SIMULATOR_ROOT/usr/lib/libsqlite3.dylib`), where
# it IS a real Mach-O image carrying all twenty required symbols. `SQLiteFunctionTable.bind` validates each
# `dlsym` against `dladdr`'s REALPATH, so a literal that only resolveth via the runtime root fails the bind
# and the arm reddens as a supply failure.
#
# WHAT THIS STAGES
# ----------------
# The image is TAKEN FROM THE RUNTIME the lane resolved FOR ITS DEVICE (its `runtimeRoot`), never from one
# arbitrary "last available" runtime -- a mismatched runtime would be a silently different oracle. The
# twenty required symbols are validated with BOTH `dyld_info -exports` and `nm -gU` (two independent
# readers, so a reader that silently truncated cannot admit a partial image), and the SQLCipher init
# symbols must be ABSENT (an image that carrieth them is not "stock"). The staged copy's digest is
# re-measured after the copy.
#
# WHAT IS PINNED, AND WHERE THE TRUST LIVETH
# ------------------------------------------
# `docs/supplychain/STOCK_SQLITE.pins.json` is an EXPORT CONTRACT, not a fixed-digest pin: this image is
# Apple's own SQLite INSIDE each simulator runtime, so its bytes belong to the runtime, and a fixed sha256
# would freeze one runtime's bytes into every other runtime's lane. The register pins the SYMBOL SURFACE
# (and the must-not-carry init symbols); this script RECORDS the per-run sha256/bytes/arch/platform in the
# staging sidecar. The sidecar AUTHORIZETH nothing -- it is an untrusted record beside a replaceable image;
# the oracle's hard gate is the symbol surface, and the GF-004 court still refuseth a non-stock image at
# the cipher probe.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIN="${REPO_ROOT}/docs/supplychain/STOCK_SQLITE.pins.json"
OUT=""
BUNDLE=""
RUNTIME_ROOT=""
UDID=""

while [ $# -gt 0 ]; do
    case "$1" in
        --runtime-root) RUNTIME_ROOT="$2"; shift 2 ;;
        --udid)         UDID="$2"; shift 2 ;;
        --out)          OUT="$2"; shift 2 ;;
        --bundle)       BUNDLE="$2"; shift 2 ;;
        -h|--help)      sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "::error::unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -f "$PIN" ] || { echo "::error::the stock register is absent: $PIN" >&2; exit 1; }
case "$PIN" in *.md) echo "::error::the register must be JSON, not prose" >&2; exit 1 ;; esac

if [ -z "$OUT" ]; then
    OUT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/board1-stock-sqlite-oracle"
fi

# ---- (1) RESOLVE THE RUNTIME ROOT FOR **THIS** DEVICE, SO THE ORACLE IS THE RIGHT RUNTIME'S. ------------------
if [ -z "$RUNTIME_ROOT" ]; then
    [ -n "$UDID" ] || { echo "::error::need --runtime-root DIR or --udid UDID (the device the lane resolved)" >&2; exit 2; }
    command -v xcrun >/dev/null || { echo "::error::xcrun is required to resolve a UDID's runtime" >&2; exit 1; }
    # *** A FRESHLY RESOLVED UDID IS OFTEN SHUTDOWN ON A COLD HOST, AND `simctl getenv` REQUIRETH A BOOTED DEVICE. ***
    # *So the device is settled through a BOUNDED wait -- the UI lane's own `perl alarm` pattern -- before the root is
    # asked for. An unbounded `bootstatus -b` once hung a hosted lane for 2h08m and produced no log at all, so the wait
    # is bounded (900s) and NEVER forever.*
    perl -e 'alarm shift; exec @ARGV' 900 xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
    # *** `simctl getenv <udid> SIMULATOR_ROOT` IS THE AUTHORITY: the DEVICE knoweth its own runtime root by
    #     construction. *A `list runtimes | tail -1` would pick whichever runtime was NEWEST rather than the one
    #     THIS device booteth from -- a silently different oracle.* ***
    RUNTIME_ROOT="$(xcrun simctl getenv "$UDID" SIMULATOR_ROOT 2>/dev/null || true)"
    if [ -z "$RUNTIME_ROOT" ]; then
        # *THE TWO FAILURES ARE NAMED APART: an EMPTY answer meaneth the device did not boot or simctl could not
        #  answer -- NOT that a wrong runtime was chosen. Conflating them would send a reader hunting for a runtime
        #  mismatch that never happened.*
        echo "::error::*** DEVICE $UDID REPORTED NO SIMULATOR_ROOT: the device is not booted or simctl getenv could" >&2
        echo "::error::not answer (a device-boot failure, distinct from a wrong-runtime refusal). ***" >&2
        exit 3
    fi
fi

SOURCE="${RUNTIME_ROOT}/usr/lib/libsqlite3.dylib"
if [ ! -f "$SOURCE" ]; then
    echo "::error::*** HOST-SUPPLY FAILURE: the runtime carrieth no ${SOURCE#"$RUNTIME_ROOT"/} -- the stock oracle" >&2
    echo "::error::cannot be staged from runtime '$RUNTIME_ROOT'. A missing system SQLite is a FAILED STAGE, not a skip. ***" >&2
    exit 3
fi

# ---- (2) THE REGISTER'S SYMBOL SURFACE, READ ONCE AND SHARED BY BOTH READERS. --------------------------------
REQUIRED="$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))['required_symbols']))" "$PIN")"
FORBIDDEN="$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1]))['must_not_carry']))" "$PIN")"
[ -n "$REQUIRED" ] || { echo "::error::the register carrieth no required symbols" >&2; exit 1; }

# ---- (3) COPY INTO THE STAGE AND RE-MEASURE THE COPY (a copy that did not survive is a FAILED STAGE). --------
mkdir -p "$OUT"
STAGED="$OUT/$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['library_name'])" "$PIN")"
cp "$SOURCE" "$STAGED"
src_digest="$(shasum -a 256 "$SOURCE" | awk '{print $1}')"
staged_digest="$(shasum -a 256 "$STAGED" | awk '{print $1}')"
if [ "$src_digest" != "$staged_digest" ]; then
    echo "::error::*** THE STAGED STOCK IMAGE DOES NOT MATCH ITS SOURCE ($staged_digest vs $src_digest) ***" >&2
    exit 3
fi

# ---- (4) VALIDATE THE STAGED BYTES WITH **TWO** EXPORT READERS, THEN THE NEGATIVE. --------------------------
dyld_exports="$(dyld_info -exports "$STAGED" 2>/dev/null | awk 'NF==2 && $1 ~ /^0x/ {print $2}' | sed 's/^_//')"
nm_exports="$(nm -gU "$STAGED" 2>/dev/null | awk '{print $3}' | sed 's/^_//')"
missing_dyld=(); missing_nm=()
for s in $REQUIRED; do
    grep -qx "$s" <<<"$dyld_exports" || missing_dyld+=("$s")
    grep -qx "$s" <<<"$nm_exports"   || missing_nm+=("$s")
done
if [ "${#missing_dyld[@]}" -ne 0 ] || [ "${#missing_nm[@]}" -ne 0 ]; then
    echo "::error::*** THE STAGED STOCK IMAGE LACKS REQUIRED SYMBOLS: dyld_info=${missing_dyld[*]:-none} nm=${missing_nm[*]:-none}. ***" >&2
    echo "::error::a partially bound image would call a garbage pointer, so it is refused before staging. ***" >&2
    exit 3
fi
for s in $FORBIDDEN; do
    if grep -qx "$s" <<<"$nm_exports"; then
        echo "::error::*** THE IMAGE CARRIETH '$s': it is NOT a stock oracle (a cipher init symbol means this is" >&2
        echo "::error::SQLCipher, and the GF-004 'stock' refusal would be measuring the wrong thing). ***" >&2
        exit 3
    fi
done

# ---- (5) RECORD THE MEASURED FACTS IN AN UNTRUSTED SIDECAR (an export contract, not a digest pin). ----------
BYTES="$(wc -c <"$STAGED" | tr -d ' ')"
ARCH="$(lipo -archs "$STAGED" 2>/dev/null | awk '{print $1}')"
PLATFORM="$(vtool -show-build "$STAGED" 2>/dev/null | awk '/platform/ {print $2; exit}')"
SIDECAR="$STAGED.artifact.json"
python3 - "$SIDECAR" "$STAGED" "$SOURCE" "$RUNTIME_ROOT" "$staged_digest" "$BYTES" "$ARCH" "$PLATFORM" "$REQUIRED" <<'PY'
import json, sys
out, staged, source, root, digest, size, arch, platform, required = sys.argv[1:10]
doc = {
    "schema": 1,
    "library_name": "libsqlite3-stock.dylib",
    "role": "stock oracle (plain SQLite, no cipher) for the GF-004 empty-DEK and stock-cipher refusals",
    "digest_policy": "runtime-measured, NOT a fixed pin: the bytes belong to the resolved simulator runtime",
    "source": {"library": source, "runtime_root": root},
    "sha256": digest,
    "bytes": int(size),
    "arch": arch,
    "platform": platform,
    "required_symbols": required.split(),
    "note": "UNTRUSTED RECORD beside a replaceable image: it AUTHORIZETH nothing. The hard gate is the export contract in docs/supplychain/STOCK_SQLITE.pins.json, and the court still refuseth a non-stock image at the cipher probe.",
}
with open(out, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY

# ---- (6) IF A TEST BUNDLE IS NAMED, PLACE THE ORACLE WHERE THE TEST PROCESS CAN REACH IT. -------------------
# *The simulator `.xctest` bundle is a real file the TEST PROCESS can read; the CoreSimulator volume is
#  visible too, but the bundle is the convention the SQLCipher image already uses, and it surviveth a
#  `test-without-building` invocation whose environment does not carry a custom variable.*
if [ -n "$BUNDLE" ]; then
    [ -d "$BUNDLE" ] || { echo "::error::the named test bundle is absent: $BUNDLE" >&2; exit 3; }
    mkdir -p "$BUNDLE/Frameworks"
    cp "$STAGED" "$BUNDLE/Frameworks/"
    cp "$SIDECAR" "$BUNDLE/Frameworks/"
    bundled_digest="$(shasum -a 256 "$BUNDLE/Frameworks/libsqlite3-stock.dylib" | awk '{print $1}')"
    sidecar_digest="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sha256'])" "$SIDECAR")"
    if [ "$bundled_digest" != "$sidecar_digest" ]; then
        echo "::error::*** THE BUNDLE-STAGED STOCK IMAGE DOES NOT MATCH ITS SIDECAR ($bundled_digest vs $sidecar_digest) ***" >&2
        exit 3
    fi
    echo "stock_bundle_dir=$BUNDLE/Frameworks"
fi

echo "stock_sqlite_stage=$OUT"
echo "stock_sqlite_source=$SOURCE"
echo "stock_sqlite_sha256=$staged_digest"
echo "stock_sqlite_bytes=$BYTES"
echo "stock_sqlite_arch=$ARCH"
echo "stock_sqlite_platform=$PLATFORM"
echo "stock_sqlite_descriptor=$SIDECAR"
