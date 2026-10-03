#!/bin/sh
# Run the iOS SIMULATOR lane -- the workflow's step 13 (`xcodebuild test` on `Godstone-Light`) -- and record the
# SOURCE DIGEST it compiled, the raw process status, and a fresh result bundle.
#
#     tools/readiness/run_ios_simulator_lane.sh [output-log] [result-bundle-path]
#
# *** WHY THIS EXISTS, AND WHAT ITS ABSENCE COST. ***
#
# *THE WORKFLOW'S `xcodebuild test (GodstoneMeshTests on iOS Simulator)` STEP WAS INLINE IN
# `.github/workflows/repository-verification.yml`, SO IT HAD:*
#
#   1. **NO PRE-RUN SOURCE DIGEST.** The UI runner (`run_ios_ui_lane.sh`) taketh a digest BEFORE the schemes and AFTER,
#      and requireth them to agree, *so a mid-run edit cannot leave a current-looking log.* **THE SIMULATOR STEP HAD
#      NEITHER**, so nothing bound its log to the bytes it compiled.
#   2. **NO RAW STATUS.** It ended in a `| tee` pipeline, so the step's exit code was `tee`'s -- *the same defect the
#      readiness-courts step in the same job already documents and repairs with `pipefail`.*
#   3. **NO RESULT BUNDLE.** A `.xcresult` carrieth the per-CASE roster, the suite lifecycle and the skip annotations;
#      a log carrieth only what XCTest chose to print.
#   4. **A `>=50` / last-summary / `TEST SUCCEEDED` GREP.** *MEASURED, AND IT IS THE DEFECT THIS RUNNER EXISTS TO
#      REMOVE: `grep -oE "Executed [0-9]+ tests, with 0 failures" | tail -1` readeth the LAST such line in the log.
#      XCTest printeth one per NESTED suite, so the last line is a CHILD'S total, and `>= 50` accepted a run whose
#      outer suite never finished.* **A count nobody can reconcile with the sources is the same defect class the
#      foundation lane's own control was strengthened to refuse.**
#
# **THE ROSTER IS DERIVED FROM THE SOURCES, NOT PINNED.** `ci/check_lane_results.py --scope ios-simulator` reapeth this
# log against a source-derived roster (every `func test...` under the target's configured source directories) and
# requirith zero missing, zero duplicate, zero skipped, zero unfinished suites and raw rc=0 -- *so an arm that never
# ran cannot be absent from a green count.*
#
# THE SIMULATOR IS RESOLVED ONCE AND RECORDED. *The workflow picked the newest iPhone by a `sort -u | tail -1` over
# the image's installed set; that stays, but WHICH UDID and WHICH RUNTIME ran is now written into the log so a reader
# can re-execute on the same device rather than guessing which "iPhone" it meant.* `GS_SIM` overrides.
#
# THE PROJECT IS REGENERATED, NOT TRUSTED: `ios/Godstone.xcodeproj` is GENERATED and GITIGNORED, so `project.yml` is
# the authority for which targets and schemes exist.
set -eu
cd "$(dirname "$0")/../.."
LOG="${1:-ios-simulator-lane.log}"
RESULT_BUNDLE="${2:-$(pwd)/ios-simulator-lane.xcresult}"

# 1. THE PRE-RUN SOURCE DIGEST, SO A MID-RUN EDIT CANNOT DESCRIBE A TREE THE TESTS NEVER RAN.
python3 tools/readiness/ios_source_digest.py >"$LOG.pre.sha256"
pre_digest="$(cat "$LOG.pre.sha256")"

# 2. THE SPEC IS THE AUTHORITY.
xcodegen generate --spec ios/project.yml

# 3. *** THE DEVICE IS RESOLVED AND RECORDED, NOT ASSUMED. ***
SIM="${GS_SIM:-$(xcrun simctl list devices available 2>/dev/null \
      | grep -oE 'iPhone [0-9]+( Pro Max| Pro| Plus)?' | sort -u -V | tail -1)}"
if [ -z "$SIM" ]; then
    echo "::error::no available iPhone simulator on this host -- the simulator lane cannot run, and a lane that never"
    echo "::error::ran is not a pass" >&2
    exit 3
fi
# *** THE RUNTIME COMES FROM THE GROUP HEADER, NOT THE DEVICE LINE -- AND THAT IS A MEASURED DEFECT, NOT A STYLE. ***
#
# *`xcrun simctl list devices available` printeth the runtime ONCE as a GROUP HEADER and the device line carrieth only
# the name, UDID and state:*
#     -- iOS 26.3 --
#         iPhone 17 Pro Max (B44EC7AF-...) (Booted)
# **THE PREVIOUS `grep -oE 'iOS [0-9.]+'` OVER THE DEVICE LINE THEREFORE MATCHED NOTHING**, so `device_runtime=` was
# written EMPTY and the lane refused its own digest contract for a device it had in fact resolved and run on. *The
# header immediately ABOVE the matched device line is the device's runtime, so that is what is read -- recorded
# verbatim (`iOS 26.3`), and asserted non-empty below rather than silently exported empty.*
SIMCTL_DEVICES="$(xcrun simctl list devices available 2>/dev/null)"
DEVICE_LINE="$(printf '%s\n' "$SIMCTL_DEVICES" | grep -F "$SIM (" | head -1)"
UDID="$(printf '%s\n' "$DEVICE_LINE" | grep -oE '[0-9A-F-]{36}')"
RUNTIME="$(printf '%s\n' "$SIMCTL_DEVICES" | awk -v needle="$SIM (" '
    /^-- .* --[[:space:]]*$/ { rt = $0; sub(/^-- /, "", rt); sub(/ --[[:space:]]*$/, "", rt); next }
    index($0, needle) { print rt; exit }
')"
if [ -z "$RUNTIME" ]; then
    echo "::error::could not derive the RUNTIME for '$SIM' from 'xcrun simctl list devices available' -- *the runtime"
    echo "::error::is the group header above the device line; an empty device_runtime is a lane that cannot be" >&2
    echo "::error::re-executed on the same device, so it is refused rather than recorded empty*" >&2
    exit 3
fi
TOOLCHAIN="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"

# 4. A FRESH RESULT BUNDLE EVERY RUN: *a pre-existing bundle would let a reader attribute an older run's roster to
# this log.*
rm -rf "$RESULT_BUNDLE"

# 4b. *** STAGE THE PINNED SQLCIPHER IOSSIMULATOR IMAGE INTO THE TEST BUNDLE'S FRAMEWORKS. ***
#
# *THE OBLIGATION THIS ANSWERETH: the pinned SQLCipher library was recorded EXTERNAL, so
# `ReadinessT30Tests.testTheDylibEngineRoundTripsWhenThePinnedLibraryIsPresent` SKIPped -- **and a skip reports as a
# pass while measuring NOTHING.** The source is repository-owned and buildable here, so the lane BUILDS the pinned
# image (`tools/supplychain/build_sqlcipher_simulator.sh --mode ios-simulator`, exact commit
# `810db22f…`/v4.17.0 from `docs/supplychain/SQLCIPHER.pins.json`) with the Apple SDK's own CommonCrypto provider,
# and STAGEth it where the engine's production constructor resolveth it.*
#
# *** AND IT REFUSES IF THE STAGE CANNOT BE DONE. *** *The pinned library is BUILDABLE HERE, so its absence is not an
# acceptable external exemption for this lane; a build-for-testing product whose `.xctest` bundle carrieth no
# `Frameworks/libsqlcipher.0.dylib` + `.artifact.json` pair is a FAILED STAGE, named, rather than a silent skip.*
#
# The engine's constructor (`SqlCipherDylibEngine.init`) resolveth the artifact from `GODSTONE_SQLCIPHER_ARTIFACT_DIR`,
# then from the bundle's `Frameworks/`, then from `Bundle.main`'s -- verifying sha256/platform/arch/cipher-major/source
# commit from the sidecar BEFORE `dlopen`. The simulator test bundle is what runs on the device, so `Frameworks/` is
# where the image must land; `GODSTONE_SQLCIPHER_ARTIFACT_DIR` is also exported so the HOST-side resolver (if any is
# driven in the same run) reacheth the same verified image.
SQLCIPHER_STAGE="${GS_SQLCIPHER_STAGE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/board1-sqlcipher-ios-simulator}"
echo "sqlcipher_stage=$SQLCIPHER_STAGE" >>"$LOG"
tools/supplychain/build_sqlcipher_simulator.sh --mode ios-simulator --out "$SQLCIPHER_STAGE" >>"$LOG" 2>&1 || {
    echo "::error::*** THE PINNED SQLCIPHER IOSSIMULATOR IMAGE COULD NOT BE BUILT/STAGED. ***" >&2
    echo "::error::the pinned library is repository-buildable from an exact commit; its absence is a FAILED STAGE," >&2
    echo "::error::not an external exemption -- a lane that skipped the native road measured nothing" >&2
    exit 3
}
DESCRIPTOR="$SQLCIPHER_STAGE/libsqlcipher.0.dylib.artifact.json"
if [ ! -f "$SQLCIPHER_STAGE/libsqlcipher.0.dylib" ] || [ ! -f "$DESCRIPTOR" ]; then
    echo "::error::*** THE SQLCIPHER STAGE CARRIETH NO libsqlcipher.0.dylib + .artifact.json PAIR AT $SQLCIPHER_STAGE ***" >&2
    exit 3
fi
# *** THE VERIFIER RUNS OVER THE ACTUAL BUILT IMAGE, AND ITS PASSING IS WHAT AUTHORISES THE SWIFT EXPECTATION. ***
# *`SqlCipherTrustedExpectation` is the COMPILED-IN authority the engine compareth the image against (the sidecar is
# only a record), so it MUST describe THIS mode's image. The generator RUNS the register verifier over the built bytes
# and refuses an unlisted toolchain, so a failure here is a FAILED BUILD, not a skip.*
# *The expectation is emitted into a temp file ($SQLCIPHER_STAGE/SQLCipherTrustedExpectation.swift) by the
# verifier -- AND THEN PLACED WHERE THE BUILD ACTUALLY READS IT: the engine compares the loaded bytes against the
# COMPILED-IN `SQLCipherTrustedExpectation`, which xcodebuild takes from the SOURCES tree, so a stale last-run copy
# (of ANY mode -- a macos emission left by the foundation lane minutes earlier is the MEASURED case) mis-bound every
# native-mandatory arm and the fail-closed platform guard reddened them all. THE LANE'S OWN VERIFIED EMISSION IS THE
# SOURCE OF TRUTH FOR ITS RUN; the temp file checks the build contract, the sources copy serves the build.*
python3 tools/supplychain/verify_sqlcipher_artifact.py --mode ios-simulator --dir "$SQLCIPHER_STAGE" \
    --emit-swift "$SQLCIPHER_STAGE/SQLCipherTrustedExpectation.swift" \
    >>"$LOG" 2>&1 || {
    echo "::error::*** THE BUILT SQLCIPHER IMAGE DID NOT VERIFY AGAINST THE TRUSTED REGISTER (ios-simulator). ***" >&2
    exit 3
}
cp "$SQLCIPHER_STAGE/SQLCipherTrustedExpectation.swift" \
    ios/Godstone/Sources/GodstoneMesh/SQLCipherTrustedExpectation.swift || {
    echo "::error::the verified ios-simulator trust expectation could not be placed at the compile path" >&2
    exit 3
}
echo "sqlcipher_descriptor=$DESCRIPTOR" >>"$LOG"
export GODSTONE_SQLCIPHER_ARTIFACT_DIR="$SQLCIPHER_STAGE"

# 5. *** THE RAW PROCESS STATUS IS CAPTURED FROM THE CHILD DIRECTLY, NEVER FROM A PIPELINE'S LAST ELEMENT. ***
#
# *The workflow's `| tee` shape returned `tee`'s status no matter what `xcodebuild` reported. This redirects BOTH
# streams to the log and reads `$?` of the `xcodebuild` process itself -- which is the only status that means
# anything.*
{
    echo "== ios-simulator-lane =="
    echo "device_name=$SIM"
    echo "device_udid=$UDID"
    echo "device_runtime=$RUNTIME"
    echo "toolchain=$TOOLCHAIN"
    echo "pre_source_digest=$pre_digest"
    echo "result_bundle=$RESULT_BUNDLE"
    echo "sqlcipher_stage=$SQLCIPHER_STAGE"
} >"$LOG"
SQLCIPHER_TARGET="$SQLCIPHER_STAGE"

# 5b. *** BUILD-FOR-TESTING -> STAGE THE VERIFIED IMAGE -> TEST-WITHOUT-BUILDING. ***
#
# *`xcodebuild test` builds and runs in one shot, and there is no hook between the build and the run to place the
# image into the product's `Frameworks/`.* **So the lane is split exactly as the assignment nameth: `build-for-testing`
# produceth the `.xctest` bundle, the built+verified IOSSIMULATOR image and its descriptor are COPIED INTO that
# bundle's `Frameworks/`, and `test-without-building` runneth the already-built product.** *The engine then resolveth
# the artifact from ITS OWN BUNDLE and verifyeth the descriptor before `dlopen` -- so no path is guessed and no
# bare-name library is claimed pinned.*
DERIVED="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/board1-ios-sim-derived"
rm -rf "$DERIVED"
rc=0
xcodebuild -project ios/Godstone.xcodeproj -scheme Godstone-Light \
    -configuration LightDebug \
    -destination "platform=iOS Simulator,id=${UDID}" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO build-for-testing >>"$LOG" 2>&1 || rc=$?
echo "raw_build_for_testing_rc=$rc" >>"$LOG"
if [ "$rc" -ne 0 ]; then
    echo "raw_xcodebuild_rc=$rc" >>"$LOG"
    echo "::error::the simulator lane could not build-for-testing (rc=$rc); the test-without-building step is skipped" >&2
else
    XCTEST_BUNDLE="$(find "$DERIVED/Build/Products" -name 'GodstoneMeshTests.xctest' -maxdepth 3 2>/dev/null | head -1)"
    if [ -z "$XCTEST_BUNDLE" ] || [ ! -d "$XCTEST_BUNDLE" ]; then
        echo "::error::*** NO BUILT GodstoneMeshTests.xctest WAS FOUND under $DERIVED/Build/Products. ***" >&2
        rc=3
    else
        echo "xctest_bundle=$XCTEST_BUNDLE" >>"$LOG"
        mkdir -p "$XCTEST_BUNDLE/Frameworks"
        cp "$SQLCIPHER_TARGET/libsqlcipher.0.dylib" "$XCTEST_BUNDLE/Frameworks/"
        cp "$DESCRIPTOR" "$XCTEST_BUNDLE/Frameworks/"
        # *** AND THE STAGE IS VERIFIED IN PLACE, BY DIGEST, BEFORE THE RUN. *** *An image that did not survive the
        # copy must REFUSE here rather than produce a lane whose native arm skipped for an unexplained reason.*
        staged_digest="$(shasum -a 256 "$XCTEST_BUNDLE/Frameworks/libsqlcipher.0.dylib" | awk '{print $1}')"
        sidecar_digest="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sha256'])" "$DESCRIPTOR")"
        if [ "$staged_digest" != "$sidecar_digest" ]; then
            echo "::error::*** THE STAGED SQLCIPHER IMAGE DOES NOT MATCH ITS DESCRIPTOR ($staged_digest vs $sidecar_digest). ***" >&2
            rc=3
        else
            echo "staged_sqlcipher_sha256=$staged_digest" >>"$LOG"
            xcodebuild -project ios/Godstone.xcodeproj -scheme Godstone-Light \
                -configuration LightDebug \
                -destination "platform=iOS Simulator,id=${UDID}" \
                -derivedDataPath "$DERIVED" \
                -resultBundlePath "$RESULT_BUNDLE" \
                CODE_SIGNING_ALLOWED=NO test-without-building >>"$LOG" 2>&1 || rc=$?
        fi
    fi
fi
echo "raw_xcodebuild_rc=$rc" >>"$LOG"

# 6. THE DIGEST SIDECAR, AND THE PRE/POST AGREEMENT -- the same contract the UI lane carrieth.
python3 tools/readiness/ios_source_digest.py >"$LOG.sources.sha256"
post_digest="$(cat "$LOG.sources.sha256")"
echo "post_source_digest=$post_digest" >>"$LOG"

if [ "$pre_digest" != "$post_digest" ]; then
    echo "::error::a lane input changed WHILE the simulator lane ran:" >&2
    echo "::error::  pre=$pre_digest" >&2
    echo "::error::  post=$post_digest" >&2
    echo "::error::the log is therefore not evidence about any single revision" >&2
    exit 3
fi

# 7. *** THE RUNNER PRODUCES EVIDENCE; THE CHECKER DECIDES. ***
#
# *This mirrors the other two iOS runners exactly: a raw non-zero is RECORDED, not fatal here, because the raw status
# cannot tell a build failure from an assertion failure from a test-runner launch refusal -- and
# `ci/check_lane_results.py --scope ios-simulator` is the party that interpreteth the roster, the skips, the suite
# lifecycle and the per-case verdicts.* **A run that could not produce a log at all still faileth loudly, because the
# log is what the checker reaps.**
if [ ! -s "$LOG" ]; then
    echo "::error::the simulator lane produced no log" >&2
    exit 3
fi
printf 'iOS simulator lane: device=%s (%s) raw-rc=%s log=%s bundle=%s digest=%s…\n' \
    "$SIM" "$UDID" "$rc" "$LOG" "$RESULT_BUNDLE" "$(cut -c1-16 "$LOG.sources.sha256")"
echo "  (*the raw xcodebuild status is EVIDENCE; the verdict comes from \`ci/check_lane_results.py --scope ios-simulator\`)"
# *** THE RUNNER PRODUCES EVIDENCE; THE CHECKER DECIDES -- AND THE STEP MUST NOT ABORT BEFORE THAT CHECKER RUNS. ***
# *A non-zero `exit` here would make the WORKFLOW STEP red and SKIP the later `--scope ios` aggregate control
# entirely (`if: success()`), which is the measured defect the foundation lane's own docstring records: "a red
# foundation arm hid the entire UI lane". The raw rc is written into the log above and the control refuses it; that is
# where a red lane is DISCHARGED, not here.*
exit 0
