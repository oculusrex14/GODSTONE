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
swift test --package-path ios/Packages/GodstoneFoundation >"$LOG" 2>&1
rc=$?

python3 tools/readiness/ios_source_digest.py >"$LOG.sources.sha256"
echo "iOS lane: rc=$rc, log=$LOG, digest=$(cut -c1-16 "$LOG.sources.sha256")…"
exit $rc
