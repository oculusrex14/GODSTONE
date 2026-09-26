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

python3 scripts/sync_ios_foundation_package.py
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
echo "iOS lane: rc=$rc, log=$LOG, digest=$(cut -c1-16 "$LOG.sources.sha256")…"
echo "  (*the raw swift-test status is EVIDENCE; the verdict comes from \`ci/check_lane_results.py\`*)"
