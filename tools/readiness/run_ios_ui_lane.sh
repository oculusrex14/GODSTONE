#!/bin/sh
# Run the iOS UI lane (the `bundle.ui-testing` targets) and record the SOURCE DIGEST it compiled.
#
#     tools/readiness/run_ios_ui_lane.sh [output-log]
#
# *** WHY THIS EXISTS, AND WHAT ITS ABSENCE COST. ***
#
# *`run_ios_lane.sh` runs `swift test --package-path ios/Packages/GodstoneFoundation` and NOTHING ELSE. It never
# builds `Godstone.xcodeproj` and never executes a `bundle.ui-testing` target -- so **THE UI WITNESSES HAD NO LANE,
# NO RESULT-FILE PARSING, NO SKIPPED ACCOUNTING AND NO DIGEST-BOUND LOG OF THEIR OWN.** They ran only from ad-hoc
# scripts typed into `/tmp`, **which an auditor cannot re-execute.** That is why a crashed XCUITest run could print
# `Executed 4, 0 failures` with no gate objecting: the number was true and the arm that never completed was simply
# absent from it.*
#
# *A witness that a fresh clone cannot reproduce is not evidence. **THE FIXTURE IS COMMITTED AND HASH-VERIFIED
# PRECISELY SO THAT SOMETHING CAN ENFORCE THE ARMS RAN AGAINST IT -- and until now nothing did.***
#
# THE PROJECT IS REGENERATED, NOT TRUSTED: `ios/Godstone.xcodeproj` is GENERATED and GITIGNORED, so `project.yml` is
# the authority for which targets and schemes exist. *Regenerating first means a hand-edit of the generated project
# cannot change what is built without the spec changing too.*
#
# THE DIGEST IS THE SAME DEFINITION THE PACKAGE LANE USES, plus `ios/project.yml` and the committed fixture bytes --
# so an edit to the rig or to the fixture INVALIDATES this log rather than leaving it looking current.
set -eu
cd "$(dirname "$0")/../.."
LOG="${1:-ios-ui-lane.log}"

# 1. THE SPEC IS THE AUTHORITY: regenerate the project rather than consuming whatever is on disk.
xcodegen generate --spec ios/project.yml

# 2. THE DESTINATION MUST BE AN iOS SIMULATOR. *MEASURED: without this, xcodebuild resolved to "My Mac" and refused
#    with exit 70 because the app's supported platforms are iOS -- **a UI-testing bundle cannot run on the host.***
SIM="${GS_SIM:-$(xcrun simctl list devices available | grep -oE "iPhone 1[5-9] Pro" | head -1)}"
if [ -z "$SIM" ]; then
    echo "no iOS simulator found; set GS_SIM" >&2
    exit 2
fi

# 3. BOTH UI SCHEMES, EACH WITH ITS OWN LOG SO A FAILURE NAMES ITS TARGET.
rc=0
: >"$LOG"
for scheme in LabMeshUI GodstoneArchiveUI; do
    echo "=== scheme $scheme ===" >>"$LOG"
    if ! xcodebuild -project ios/Godstone.xcodeproj -scheme "$scheme" \
            -configuration LightDebug \
            -destination "platform=iOS Simulator,name=$SIM" \
            CODE_SIGNING_ALLOWED=NO test >>"$LOG" 2>&1; then
        rc=1
    fi
done

# 4. THE DIGEST SIDECAR, from the SAME definition the control uses.
python3 tools/readiness/ios_source_digest.py >"$LOG.sources.sha256"
echo "iOS UI lane: rc=$rc, log=$LOG, digest=$(cut -c1-16 "$LOG.sources.sha256")…"
exit $rc
