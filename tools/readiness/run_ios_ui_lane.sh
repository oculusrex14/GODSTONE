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

# 1b. *** THE PRE-RUN SOURCE DIGEST, SO A MID-RUN EDIT CANNOT DESCRIBE A TREE THE TESTS NEVER RAN. ***
#
# *THE DEFECT THIS CLOSES, AND IT IS THE SAME VACUOUS-EVIDENCE CLASS THE OTHER GUARDS REMOVE: the lane writeth ONE
# digest AFTER the run, so an edit to a UI source BETWEEN the schemes and the sidecar produceth a log that DESCRIBETH
# a tree the tests never compiled* -- **and `ci/check_lane_results.py` would then compare that late digest to the
# current tree and find them EQUAL, because both are post-edit.** *The post-run digest is written from the same tree
# the sidecar is read against, so the staleness guard could never see a mid-run edit.*
#
# **SO THE DIGEST IS TAKEN TWICE -- BEFORE the schemes run and AFTER -- and the two must AGREE.** *A mismatch meaneth
# an input changed while the lane was running, so the log is not evidence about ANY single revision; the lane sayeth
# so and exiteth 3 rather than leaving a log that looketh current.*
python3 tools/readiness/ios_source_digest.py >"$LOG.pre.sha256"
pre_digest="$(cat "$LOG.pre.sha256")"

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
# silently change the meaning on another host.*
#
# *** AND THE BOUND MUST BE LONGER THAN THE SETTLE IT WAITETH FOR -- MY FIRST NUMBER WAS 120s AND IT WAS WRONG FOR THE
# VERY CASE THE WAIT EXISTETH TO CURE. *** *MEASURED: with 120s, the local UI lane finished in 150s carrying
# `ios:ui suites=1 tests=6` -- **ONE SCHEME, WITH THE SIX ARCHIVE ARMS ENTIRELY ABSENT** -- because `bootstatus -b`
# TAKES A LONG TIME PRECISELY WHEN THE DEVICE IS STILL SETTLING:* ***so a bound shorter than the settle KILLETH THE
# WAIT EXACTLY WHEN IT IS NEEDED, AND THE SCHEME THEN LAUNCHETH INTO A WEDGED DEVICE.*** **THAT TRADETH A HANG FOR THE
# FALSE RED -- THE OUTCOME THIS LANE EXISTS TO PREVENT -- AND A `Busy` REFUSAL IN 150s YIELDETH ZERO ARM VERDICTS,
# WHICH IS THE SAME NON-ANSWER AS A HANG, REACHED FASTER.***
#
# *900s (15 min) is past the realistic per-scheme settle -- ~8-10 min is normal, and the whole lane took ~20 min when it
# worked -- and it remaineth a bound: THE POINT IS "NOT FOREVER", NOT "SHORT".*
_bounded_boot_wait() {
    local udid="$1"
    perl -e 'alarm shift; exec @ARGV' 900 xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
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
post_digest="$(cat "$LOG.sources.sha256")"

# 4b. *** AND THE PRE-RUN DIGEST MUST EQUAL THE POST-RUN ONE, OR THIS LOG IS NOT EVIDENCE ABOUT ANY REVISION. ***
#
# *The named input is printed so the reader knoweth WHICH edit invalidated the lane, rather than being told only that
# a digest moved. `ios_source_digest.py` carrieth one digest over the whole set of source trees, so the exact file is
# found by comparing the trees themselves -- which is bounded, and is the honest way to name it.*
if [ "$pre_digest" != "$post_digest" ]; then
    echo "::error::A SOURCE CHANGED WHILE THE UI LANE WAS RUNNING." >&2
    echo "  pre-run  digest: $(printf '%s' "$pre_digest" | cut -c1-16)..." >&2
    echo "  post-run digest: $(printf '%s' "$post_digest" | cut -c1-16)..." >&2
    echo "  THE LOG IS NOT EVIDENCE ABOUT ANY SINGLE REVISION: the tests compiled one tree and the sidecar describeth" >&2
    echo "  another. Revert the concurrent edit and re-run the lane." >&2
    exit 3
fi

# 5. EVIDENCE-PRODUCTION GATE: the script fails only if it could not produce a log to interpret.
#
# *** AND "A LOG EXISTS" WAS TOO WEAK A TEST FOR THAT, WHICH I MEASURED RATHER THAN REASONED ABOUT. ***
#
# *A SCHEME WHOSE RUNNER IS REFUSED AT LAUNCH -- `Code=6`, `reason: Busy ("Application failed preflight checks")` --
# STILL WRITETH THAT ERROR INTO THE LOG, so `-s "$LOG"` was satisfied and this runner reported success on a lane that
# produced HALF ITS EVIDENCE.* **MEASURED: the lane echoed `schemes=2` while its own log carried `ios:ui suites=1
# tests=6` -- ONE SCHEME, AND THE SIX ARCHIVE ARMS ENTIRELY ABSENT.** *The committed checker DID catch it (it requireth
# every named arm), which is why the verdict was still refused -- **but a runner that reporteth success on a
# half-empty lane inviteth the next reader to trust the wrong line.***
#
# **SO A SCHEME THAT DID NOT LAUNCH IS NOT EVIDENCE, AND THIS SAYETH SO AT THE POINT THE FAILURE HAPPENETH** --
# *counting the arms each scheme actually produced, from the log, rather than counting loop iterations.*
#
# *The arms are keyed exactly as the checker keys them: `suite.Class method` for the UI targets. This is a
# LAUNCH-EVIDENCE gate, not a verdict -- a scheme that launched and failed an arm still passeth here, because that is
# the checker's call and a recorded known-red obligation lives among those arms.*
launched=0
missing=""
for s in LabMeshUITests GodstoneArchiveUITests; do
    if grep -qE "Test Case '-\[[A-Za-z0-9_.]*${s}\." "$LOG"; then
        launched=$((launched + 1))
    else
        missing="$missing $s"
    fi
done
if [ "$launched" -ne "$schemes_run" ]; then
    echo "::error::only $launched of $schemes_run UI schemes LAUNCHED -- no arm verdict for:$missing" >&2
    echo "  a scheme refused at launch (typically 'Busy (Application failed preflight checks)') still writeth an error" >&2
    echo "  into the log, so a non-empty log is NOT evidence that the scheme ran. The wait before each scheme is bounded" >&2
    echo "  at 900s precisely so a settle is not cut short; if this keeps happening the DEVICE is wedged, which is an" >&2
    echo "  environment fault and NOT a verdict about the product." >&2
    exit 3
fi
echo "iOS UI lane: attempted=$schemes_run launched=$launched raw-rc=$rc log=$LOG digest=$(cut -c1-16 "$LOG.sources.sha256")…"
echo "  (*the raw xcodebuild status is EVIDENCE; the verdict comes from \`ci/check_lane_results.py\`*)"
exit 0
