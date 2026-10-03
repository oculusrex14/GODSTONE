#!/bin/sh
# Run EVERY Android lane and record the SOURCE DIGEST each compiled.
#
#     tools/readiness/run_android_lanes.sh [--report-lanes-only]
#
# WHY: `ci/check_lane_results.py` bindeth each lane's result files to the bytes they tested, and
# **THE RUNNER IS THE ONLY PARTY THAT KNOWETH WHICH TREE IT COMPILED** -- the control can only CHECK.
# *`--rerun-tasks` replaces the XML on a real run, but nothing asserted that the replacement happened; measured,
# 155 Kotlin sources under `android/mesh/src` were newer than that lane's result XML.*
#
# THE DIGEST IS OVER CONTENT, NOT MTIMES: a `git checkout` or a `touch` moveth an mtime WITHOUT changing a byte,
# so an mtime-bound control would refuse genuinely-current lanes.
#
# *** AND THE POPULATION IS NOW SEVEN, NOT FOUR (the missing lanes closed). ***
#
# *The four HISTORICAL UNIT LANES (`android:app`, `:core`, `:mesh`, `:labmesh`) keep their contract BYTE-IDENTICAL:
# their XML stays under `build/test-results/<task>/` and their digests stay in `android-<lane>.{pre,sources}.sha256`,
# because the workflow and `ci/check_board1_manifest.py` already read exactly those paths.*
#
# **THE THREE MISSING LANES ARE RUN FROM THE ONE REGISTRY (`tools/readiness/lane_registry.py`), WHICH OWNS THEIR REAL
# GRADLE TARGETS, THEIR EVIDENCE ROOTS AND THEIR REPORTS:**
#   * `android:ui`         -- the rendered-controls (Compose semantics) courts, required BY NAME;
#   * `android:simulator`  -- the lab's LAUNCHABLE composition over the shared host platform;
#   * `android:production` -- THE PRODUCTION-SIMULATION LANE: the Archive is staged by `ci/archive_fixture.py`, the
#     SHIPPING `:app:assembleLightDebug` is built, the production-estate courts run, and
#     `scripts/inspect_android_artifacts.py --expected-archive` reads the PACKAGED BYTES -- *the bytes are the
#     authority, and the expected Archive is the very file staged for this build.*
#
# **NOTHING IS FABRICATED: each lane captures its own child's exit status (never a pipeline's last element), copies
# the JUnit XML the target really wrote into its own evidence root, and writeth a report whose every field is a
# measurement. The CHECKER (`ci/check_lane_results.py --scope android`) re-derives the verdict from those bytes.**
#
# EVERY PATH IS RESOLVED FROM THIS SCRIPT, NOT FROM THE CWD -- the hosted checkout is the repo root today, but a runner
# invoked from `/tmp` must resolve the SAME tree.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

REPORT_ONLY=0
if [ "${1:-}" = "--report-lanes-only" ]; then
    REPORT_ONLY=1
fi

export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

worst=0

if [ "$REPORT_ONLY" -eq 0 ]; then
    # *** THE RESULTS ROOT IS CLEARED FIRST, SO THE LANE'S EVIDENCE IS ITS OWN. ***
    #
    # *THE DEFECT THIS CLOSES, MEASURED: `ci/check_lane_results.py` refuseth an UNEXPECTED SIBLING under a lane's
    # `build/test-results/` -- a filtered run (`--tests ...`) writeth BESIDE the lane's own task directory, and a
    # sibling is how this lane's count was once inflated. **The cross-platform coordinator legitimateth such a sibling
    # (`:mesh:board1IntegrationWorker` writeth `board1IntegrationWorker/`), so a machine that ran the coordinator before
    # the lane carried that directory into the lane's evidence and the control refused it -- correctly, since a stale
    # sibling is exactly the pollution it existeth to catch.** *`--rerun-tasks` regenerateth the lane's own XML, so
    # clearing the root first leaveth the lane's run as the only writer and the count bound to the sources.*
    for _mod in app core mesh labmesh; do
        rm -rf "android/$_mod/build/test-results"
    done

    # *** THE PRE-RUN DIGESTS, SO A MID-RUN EDIT CANNOT DESCRIBE A TREE THE TESTS NEVER COMPILED. ***
    # *The same contract the two iOS runners carry: the digest is taken BEFORE the lanes start and AFTER they finish,
    # and the two must agree -- otherwise the result files describe no single revision.*
    python3 tools/readiness/android_source_digest.py >android-app.pre.sha256
    python3 tools/readiness/android_source_digest.py --lane android:core >android-core.pre.sha256
    python3 tools/readiness/android_source_digest.py --lane android:mesh >android-mesh.pre.sha256
    python3 tools/readiness/android_source_digest.py --lane android:labmesh >android-labmesh.pre.sha256

    # *** THE VERDICT COMES FROM THE CHECKER, NOT THE RAW GRADLE STATUS -- AND THE DIGESTS ARE WRITTEN EITHER WAY. ***
    #
    # *THE DEFECT THIS CLOSES, AND IT IS THE EXACT ONE `run_ios_lane.sh` ALREADY DOCUMENTS FOR ITSELF: this script
    # runneth under `set -e`, so the moment `gradlew` returned non-zero the script ABORTED BEFORE WRITING ANY POST-RUN
    # DIGEST -- **`rc=$?` on the next line was never reached, `android-*.sources.sha256` was left STALE (or absent), and
    # the pre/post drift check below never ran at all.*** **A RED ANDROID RUN THEREFORE LEFT EVIDENCE THE LANE CONTROL
    # REFUSETH AS STALE, RATHER THAN A RED THE CONTROL COULD NAME** -- *the runner's own evidence-production rule ("it
    # PRODUCETH evidence, the checker DECIDETH") was honoured for the two iOS lanes and NOT here.* **`|| rc=$?` records
    # the gradle status and keeps the lane alive exactly as its iOS twins do.**
    #
    # *** THIS `rc=0` LINE AND THE GUARDED GRADLE LINE BELOW ARE THE KEEP-ALIVE CONTRACT, EXERCISED BY A REAL
    # REGRESSION CONTROL (`tools/readiness/tests/mutation_runner_keepalive_probe.sh`, wired as the shell rod
    # LANE-ROD-6). *** *That fixture EXTRACTS this section VERBATIM -- from the column-zero `rc=0` through the gradle
    # line -- runs it under `set -eu` with a `gradlew` that exits 7, and requirith the section to REACH its post-run
    # step. **So `rc=0` MUST sit at column zero and the invocation MUST carry the trailing `|| rc=$?` on THIS
    # line**; an indented or reformatted guard would make the fixture extract nothing and the rod would (correctly)
    # redden, since a guard no probe can reach is a guard nobody has proven.*
rc=0
./android/gradlew -p android \
    :app:testLightDebugUnitTest :core:testDebugUnitTest :mesh:testDebugUnitTest \
    :labmesh:testDebugUnitTest \
    --rerun-tasks --no-daemon --console=plain || rc=$?
    [ "$rc" -ne 0 ] && worst=1

    python3 tools/readiness/android_source_digest.py >android-app.sources.sha256
    python3 tools/readiness/android_source_digest.py --lane android:core >android-core.sources.sha256
    python3 tools/readiness/android_source_digest.py --lane android:mesh >android-mesh.sources.sha256
    python3 tools/readiness/android_source_digest.py --lane android:labmesh >android-labmesh.sources.sha256

    # *** AND THE PRE-RUN DIGESTS MUST EQUAL THE POST-RUN ONES. ***
    drift=0
    for lane in app core mesh labmesh; do
        if ! cmp -s "android-$lane.pre.sha256" "android-$lane.sources.sha256"; then
            echo "::error::a lane input changed WHILE the android lane ran (android:$lane):" >&2
            echo "::error::  pre=$(cut -c1-16 "android-$lane.pre.sha256")" >&2
            echo "::error::  post=$(cut -c1-16 "android-$lane.sources.sha256")" >&2
            drift=1
        fi
    done
    if [ "$drift" -ne 0 ]; then
        echo "::error::the result files are therefore not evidence about any single revision" >&2
        exit 3
    fi
fi

# *** THE THREE REPORT LANES, EACH FROM THE REGISTRY -- WHICH IS THE ONE DEFINITION OF THEIR TARGETS. ***
#
# *The registry writeth the report, the pre/post digests and the copied XML for each. **Its own exit status is a
# VERDICT, not a build status: it is non-zero when the derived verdict is not PASSED -- which is exactly the signal a
# caller wants -- but this script does NOT abort on it, because the CHECKER must still be able to read the evidence and
# name the reason.*** *So the status is recorded and the script carries on, exactly as the unit block above does.*
for lane in android:ui android:simulator android:production; do
    if ! python3 tools/readiness/lane_registry.py --run "$lane"; then
        echo "::warning::$lane: the registry reported a non-PASSED verdict; the checker will name the reason" >&2
        worst=1
    fi
done

echo "Android lanes: worst-rc=$worst, evidence written for $(python3 tools/readiness/lane_registry.py --list | wc -l | tr -d ' ') lanes"
echo "  (*the raw gradle statuses are EVIDENCE; the verdict comes from \`ci/check_lane_results.py --scope android\`*)"
exit "$worst"
