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
} >"$LOG"

rc=0
xcodebuild -project ios/Godstone.xcodeproj -scheme Godstone-Light \
    -configuration LightDebug \
    -destination "platform=iOS Simulator,id=${UDID}" \
    -resultBundlePath "$RESULT_BUNDLE" \
    CODE_SIGNING_ALLOWED=NO test >>"$LOG" 2>&1 || rc=$?
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
exit 0
