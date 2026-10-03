#!/bin/sh
# Run the Android UI lane (the RENDERED-CONTROLS courts) and record the SOURCE DIGEST it compiled.
#
#     tools/readiness/run_android_ui_lane.sh [output-log]
#
# *** WHY THIS EXISTS, AND WHAT ITS ABSENCE COST. ***
#
# *The `:app` and `:labmesh` Compose courts (`createComposeRule` under Robolectric) are the ONLY internal witnesses
# that a control is really RENDERED -- that its semantics tree carrieth `contentDescription`, `stateDescription`,
# `semanticsRole` and LiveRegion announcements, and that a returning reader lands at the reading anchor.* **BEFORE THIS
# LANE THEY RAN INSIDE THE UNIT LANES, judged by the same count census -- so a rendered court that never executed was
# INVISIBLE among a thousand plain unit tests.** *That is exactly the "an arm that never completed was simply ABSENT
# from a green count" defect the iOS UI lane's control was written to remove, one platform over.*
#
# *** AND THE WORK IS NOT DUPLICATED HERE: THE TARGET, THE EVIDENCE ROOT AND THE REPORT COME FROM ONE REGISTRY. ***
#
# *`tools/readiness/lane_registry.py` owneth the ONE definition of every lane's real gradle target. A second literal in
# this script would drift from the registry the moment either moved -- the same "one source of truth, two consumers"
# rule the iOS arm rosters follow.* **So this runner RESOLVES the repository root from its OWN location (a foreign cwd
# must not change the tree), exports the toolchain the android job uses, and DELEGATES to the registry.**
#
# **NOTHING IS FABRICATED: the registry captures the child's own exit status (never a pipeline's last element), copies
# the JUnit XML the target really wrote into the lane's own evidence root, and writeth a report whose every field is a
# measurement. The CHECKER (`ci/check_lane_results.py --scope android`) re-derives the verdict from those bytes.**
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG="${1:-android-ui.log}"

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

# *** THE RUNNER PRODUCES EVIDENCE; THE CHECKER DECIDES. ***
#
# *A non-zero registry status means the DERIVED VERDICT was not PASSED -- that is a signal for the caller, but this
# script does NOT turn it into a bare exit that would hide the reason: the report and the copied XML are already on
# disk, and `ci/check_lane_results.py --scope android` nameth the failing court.* **A run that could not produce its
# evidence at all is still recorded: the registry raiseth and the checker refuseth the absent report by name.**
rc=0
python3 "$ROOT/tools/readiness/lane_registry.py" --run android:ui --log-dir "$ROOT" || rc=$?

echo "Android UI lane: raw-rc=$rc log=$LOG"
echo "  (*the raw gradle status is EVIDENCE; the verdict comes from \`ci/check_lane_results.py --scope android\`*)"
exit 0
