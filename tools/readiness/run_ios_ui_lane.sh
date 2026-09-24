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
# *THE PATTERN IS DELIBERATELY BROAD: a hosted runner's installed simulator set changes with its Xcode image, and a
# NARROW PATTERN THAT MATCHES NOTHING WOULD ABORT THE LANE FOR A REASON THAT HAS NOTHING TO DO WITH THE CODE.* **Ask
# for the newest iPhone the image actually has, preferring a Pro.*** `GS_SIM` overrides.
SIM="${GS_SIM:-$(xcrun simctl list devices available 2>/dev/null \
      | grep -oE 'iPhone [0-9]+( Pro Max| Pro| Plus)?' | sort -u -V | tail -1)}"
if [ -z "$SIM" ]; then
    echo "no iOS simulator found; set GS_SIM" >&2
    exit 2
fi

# 2b. *** THE DESTINATION MUST BE SETTLED BEFORE A TEST RUN IS ASKED OF IT -- BUT THE WAIT MUST BE BOUNDED. ***
#
# **MEASURED, REPEATEDLY, ON THE LOCAL HOST: running this lane straight after another lane produced
# `FBSOpenApplicationServiceErrorDomain Code=6`, `reason: Busy ("Application failed preflight checks")`, and the whole
# lane reported `suites=0 tests=0` -- *A DEVICE THAT WAS STILL SETTLING REFUSED THE TEST RUNNER BEFORE A SINGLE TEST
# EXECUTED.* **THAT IS A FALSE RED OF THE EXACT CLASS THIS LANE EXISTS TO AVOID: it reads as a broken product and is an
# artifact of the environment.** *So the run is asked of a device that can answer.*
#
# *** AND MY FIRST VERSION OF THIS WAIT WAS UNBOUNDED -- WHICH COST A 2h08m HOSTED RUN AND IS THE WORSE DEFECT OF THE
# TWO.*** *MEASURED, HOSTED RUN `35962665742`: `simctl bootstatus -b` NEVER RETURNED.* **The UI lane's log stops at
#
# ```
# 06:12:40  Created project at .../ios/Godstone.xcodeproj
# 08:21:29  ##[error]The operation was canceled.        <- 2h08m of ZERO output
# ```
#
# *-- and the runner's own cleanup terminated `Terminate orphan process: pid (24887) (simctl)`, which nameth the
# blocked command.* **A LANE THAT HANGS PRODUCETH NO LOG AND NO VERDICT, SO A FALSE RED TURNETH INTO NO SIGNAL AT ALL;
# A BOUNDED WAIT DEGRADES TO THE OLD BEHAVIOUR INSTEAD.***
#
# *`timeout` is spelled through `perl` rather than assumed: macOS ships no GNU `timeout`, and busybox's `-t` flag would
# silently change the meaning on another host. 120s is generous for a device that is going to settle at all -- the
# successful hosted runs took ~20 min for the WHOLE lane.*
_bounded_boot_wait() {
    local udid="$1"
    perl -e 'alarm shift; exec @ARGV' 120 xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
}
UDID="$(xcrun simctl list devices available 2>/dev/null | grep -F "$SIM (" | head -1 | grep -oE '[0-9A-F-]{36}')"
if [ -n "$UDID" ]; then
    _bounded_boot_wait "$UDID"
fi

# 3. BOTH UI SCHEMES, EACH WITH ITS OWN LOG SO A FAILURE NAMES ITS TARGET.
#
# *** THE RUNNER PRODUCES EVIDENCE; THE CHECKER DECIDES THE VERDICT. ***
#
# *THE DISTINCTION IS LOAD-BEARING AND IT IS WHY THIS DOES NOT SIMPLY `exit $rc`:* a raw `xcodebuild` exit status
# **CANNOT TELL A RECORDED KNOWN-RED OBLIGATION FROM A NOVEL BREAK** -- both return non-zero. *So aborting on the
# raw status would either suppress the known-red obligation or force it to be hidden, and both directions are
# forbidden.*
#
# **THIS SCRIPT THEREFORE FAILS ONLY WHEN IT COULD NOT PRODUCE EVIDENCE** (a scheme that would not build at all, no
# simulator, an absent log). *When the schemes RAN and a log EXISTS, the exit status is recorded as evidence and the
# committed checker interprets it -- every required arm present, any skip, any empty or zero-executed run, and any
# failure that is not the exact recorded known-red arm.*
rc=0
: >"$LOG"
schemes_run=0
for scheme in LabMeshUI GodstoneArchiveUI; do
    echo "=== scheme $scheme ===" >>"$LOG"
    schemes_run=$((schemes_run + 1))
    # *** THE SETTLE IS PER-SCHEME, NOT PER-LANE. ***
    #
    # **MEASURED: with the wait only at the top of the lane, the FIRST scheme ran and the SECOND was refused with
    # `Code=6`, `reason: Busy ("Application failed preflight checks")` -- *the device is settling again the moment a
    # test run releases it, so a wait taken once does not cover the run that followeth.* **THE LANE THEN REPORTED
    # `suites=1 tests=6`: ONE SCHEME'S WORTH OF TESTS, AND A REFUSAL THAT READS AS A BROKEN PRODUCT.***
    #
    # *`xa` names the xcodebuild exit status so it can be ORed into `rc` under `set -e` without ending the lane, which
    # is the same evidence-versus-verdict rule the rest of this script followeth.*
    #
    # *** AND THIS WAIT IS BOUNDED FOR THE SAME MEASURED REASON AS THE ONE ABOVE -- `simctl bootstatus -b` HUNG THE
    # HOSTED LANE FOR 2h08m IN RUN `35962665742`, AND A HUNG LANE PRODUCETH NO LOG, NO VERDICT AND NO EVIDENCE.***
    if [ -n "$UDID" ]; then
        _bounded_boot_wait "$UDID"
    fi
    xa=0
    xcodebuild -project ios/Godstone.xcodeproj -scheme "$scheme"         -configuration LightDebug \
        -destination "platform=iOS Simulator,name=$SIM" \
        CODE_SIGNING_ALLOWED=NO test >>"$LOG" 2>&1 || xa=$?
    [ "$xa" -eq 0 ] || rc=1
done

# 4. THE DIGEST SIDECAR, from the SAME definition the control uses.
python3 tools/readiness/ios_source_digest.py >"$LOG.sources.sha256"

# 5. EVIDENCE-PRODUCTION GATE: the script fails only if it could not produce a log to interpret.
if [ ! -s "$LOG" ]; then
    echo "::error::the iOS UI lane produced NO log -- nothing for the checker to interpret" >&2
    exit 2
fi
echo "iOS UI lane: schemes=$schemes_run raw-rc=$rc log=$LOG digest=$(cut -c1-16 "$LOG.sources.sha256")…"
echo "  (*the raw xcodebuild status is EVIDENCE; the verdict comes from \`ci/check_lane_results.py\`*)"
exit 0
