#!/bin/sh
# Run the iOS foundation lane and record the SOURCE DIGEST it compiled.
#
#     tools/readiness/run_ios_lane.sh [output-log]
#
# WHY A WRAPPER: `ci/check_lane_results.py` bindeth the lane's log to the bytes it tested, and
# **THE RUNNER IS THE ONLY PARTY THAT KNOWETH WHICH TREE IT COMPILED** -- the control can only CHECK.
# *A log with no provenance cannot be dated, and an undatable log is not evidence about the current tree.*
#
# AND THE DIGEST IS OVER CONTENT, NOT MTIMES: a `git checkout`, a mirror sync or a `touch` moveth an mtime
# WITHOUT changing a byte, so an mtime-bound control would refuse genuinely-current lanes -- *and a control
# that reddens spuriously getteth switched off.*
#
# THE MIRROR IS RE-SYNCED FIRST, because `ios/Packages/GodstoneFoundation/` is GENERATED and the lane
# compiles THE MIRROR: digesting canonical while testing the mirror would bind the log to bytes it never saw.
set -eu
cd "$(dirname "$0")/../.."
LOG="${1:-ios-lane.log}"

# *** THE PRE-RUN SOURCE DIGEST, SO A MID-RUN EDIT CANNOT DESCRIBE A TREE THE TESTS NEVER RAN. ***
#
# *THE SAME HOLE THE UI LANE CLOSED, AND IT WAS OPEN HERE: the lane wrote ONE digest AFTER `swift test`, so an edit to a
# Swift source BETWEEN the compile and the sidecar produced a log that DESCRIBED a tree the tests never built -- and
# `ci/check_lane_results.py` would then compare that late digest to the current tree and find them EQUAL, because both
# are post-edit.* **THE DIGEST IS THEREFORE TAKEN TWICE -- BEFORE the compile and AFTER -- AND THE TWO MUST AGREE.**
python3 tools/readiness/ios_source_digest.py >"$LOG.pre.sha256"

python3 scripts/sync_ios_foundation_package.py

# *** STAGE THE PINNED SQLCIPHER MACOS IMAGE, BECAUSE THE HOST LANE IS WHERE THE NATIVE ROAD CAN RUN. ***
#
# *THE OBLIGATION THIS ANSWERETH: the pinned SQLCipher library was recorded EXTERNAL, so the Foundation host lane's
# `ReadinessT30Tests`/`NativeConnectionRepairTests` native arms SKIPped -- **a skip reports as a pass while measuring
# NOTHING.** The source is repository-owned and buildable here, so the lane BUILDS the pinned MACOS image
# (`tools/supplychain/build_sqlcipher_simulator.sh --mode macos`, exact commit `810db22f…`/v4.17.0) and STAGEth it.*
#
# *** AND IT REFUSES IF THE STAGE CANNOT BE DONE. *** *The macOS process cannot `dlopen` an IOSSIMULATOR image and
# vice versa, so this is the MACOS image -- and a lane that could not stage it is a FAILED STAGE, not an external
# exemption.*
#
# `SqlCipherDylibEngine.init` resolveth the artifact from `GODSTONE_SQLCIPHER_ARTIFACT_DIR` FIRST, verifying the
# sidecar's sha256/platform/arch/cipher-major/source-commit BEFORE `dlopen`; `DYLD_LIBRARY_PATH` is exported as well
# so the host dynamic loader can satisfy the image's own dependencies from the same stage.
SQLCIPHER_STAGE="${GS_SQLCIPHER_STAGE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/board1-sqlcipher-macos}"
tools/supplychain/build_sqlcipher_simulator.sh --mode macos --out "$SQLCIPHER_STAGE" >"$LOG.sqlcipher" 2>&1 || {
    echo "::error::*** THE PINNED SQLCIPHER MACOS IMAGE COULD NOT BE BUILT/STAGED. ***" >&2
    echo "::error::the pinned library is repository-buildable from an exact commit; its absence is a FAILED STAGE," >&2
    echo "::error::not an external exemption -- a skipped native arm measured nothing" >&2
    exit 3
}
if [ ! -f "$SQLCIPHER_STAGE/libsqlcipher.0.dylib" ] || [ ! -f "$SQLCIPHER_STAGE/libsqlcipher.0.dylib.artifact.json" ]; then
    echo "::error::*** THE SQLCIPHER STAGE CARRIETH NO libsqlcipher.0.dylib + .artifact.json PAIR AT $SQLCIPHER_STAGE ***" >&2
    exit 3
fi
GODSTONE_SQLCIPHER_ARTIFACT_DIR="$SQLCIPHER_STAGE"
DYLD_LIBRARY_PATH="$SQLCIPHER_STAGE${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export GODSTONE_SQLCIPHER_ARTIFACT_DIR DYLD_LIBRARY_PATH
SQLCIPHER_SHA="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sha256'])" \
    "$SQLCIPHER_STAGE/libsqlcipher.0.dylib.artifact.json")"
# *** THE VERIFIER RUNS OVER THE ACTUAL BUILT IMAGE, AND ITS PASSING IS WHAT AUTHORISES THE SWIFT EXPECTATION. ***
# *The engine compareth the loaded bytes against the COMPILED-IN `SQLCipherTrustedExpectation`, which must therefore
# describe THIS mode's image; the generator RUNS the register verifier over the built bytes and REFUSES an unlisted
# toolchain -- so a mismatch is a FAILED BUILD, never a skip.*
# *The expectation is emitted into a temp file ($SQLCIPHER_STAGE/SQLCipherTrustedExpectation.swift) by the
# verifier -- AND THEN PLACED WHERE THE BUILD ACTUALLY READS IT: the engine compares the loaded bytes against the
# COMPILED-IN `SQLCipherTrustedExpectation`, which the compiler takes from the SOURCES tree, so a stale last-run
# copy (of ANY mode) would mis-bind every native-mandatory arm. THE LANE'S OWN VERIFIED EMISSION IS THE SOURCE OF
# TRUTH FOR ITS RUN; the temp file checks the build contract, the sources copy serves the build.*
python3 tools/supplychain/verify_sqlcipher_artifact.py --mode macos --dir "$SQLCIPHER_STAGE" \
    --emit-swift "$SQLCIPHER_STAGE/SQLCipherTrustedExpectation.swift" \
    >>"$LOG.sqlcipher" 2>&1 || {
    echo "::error::*** THE BUILT SQLCIPHER IMAGE DID NOT VERIFY AGAINST THE TRUSTED REGISTER (macos). ***" >&2
    exit 3
}
cp "$SQLCIPHER_STAGE/SQLCipherTrustedExpectation.swift" \
    ios/Godstone/Sources/GodstoneMesh/SQLCipherTrustedExpectation.swift || {
    echo "::error::the verified macos trust expectation could not be placed at the compile path" >&2
    exit 3
}
python3 scripts/sync_ios_foundation_package.py >>"$LOG.sqlcipher" 2>&1 || {
    echo "::error::the foundation mirror could not re-sync the verified trust expectation" >&2
    exit 3
}
echo "sqlcipher_stage=$SQLCIPHER_STAGE sqlcipher_sha256=$(printf '%s' "$SQLCIPHER_SHA" | cut -c1-16)…"
# *** THE VERDICT COMES FROM THE CHECKER, NOT THE RAW `swift test` STATUS -- AND THE DIGEST IS WRITTEN EITHER WAY. ***
#
# *THE DEFECT THIS CLOSES, MEASURED: the runner exited the script the moment `swift test` returned non-zero, so THE
# SOURCE DIGEST WAS NEVER WRITTEN -- `set -e` aborted before the sidecar line. THE LOG WAS THEREFORE ALWAYS STALE
# (`ci/check_lane_results.py`: "the log never saw these sources") **AND THE NEXT STEP, THE UI LANE, WAS SKIPPED
# ENTIRELY (`if: success()`), SO A RED FOUNDATION ARM HID THE ENTIRE UI LANE -- INCLUDING A FULLY INSTRUMENTED ARM
# THAT HAD NEVER ONCE RUN ON THE HOST.***
#
# **THE UI RUNNER ALREADY STATETH THE CORRECT PRINCIPLE IN ITS OWN WORDS** (`run_ios_ui_lane.sh`): *"a raw
# `xcodebuild` exit status CANNOT TELL A RECORDED KNOWN-RED OBLIGATION FROM A NOVEL BREAK ... so aborting on it
# would either suppress the obligation or force it to be hidden."* **THE SAME HOLDS FOR THE FOUNDATION LANE: it
# PRODUCETH evidence, and `ci/check_lane_results.py` DECIDETH.** *`rc` is therefore RECORDED AND REPORTED, the
# digest is always written, and the script exiteth 0 when it produced a log for the checker to judge -- exactly as
# its UI twin doth. A run that could not produce a log at all still fail-eth loudly, because the log would be empty
# and the checker refuseth it.*
rc=0
swift test --package-path ios/Packages/GodstoneFoundation >"$LOG" 2>&1 || rc=$?

python3 tools/readiness/ios_source_digest.py >"$LOG.sources.sha256"
post_digest="$(cat "$LOG.sources.sha256")"
pre_digest="$(cat "$LOG.pre.sha256")"
if [ "$pre_digest" != "$post_digest" ]; then
    echo "::error::a lane input changed WHILE the foundation lane ran:" >&2
    echo "::error::  pre=$pre_digest" >&2
    echo "::error::  post=$post_digest" >&2
    echo "::error::the log is therefore not evidence about any single revision" >&2
    exit 3
fi
echo "iOS lane: rc=$rc, log=$LOG, digest=$(cut -c1-16 "$LOG.sources.sha256")…"
echo "  (*the raw swift-test status is EVIDENCE; the verdict comes from \`ci/check_lane_results.py\`*)"
