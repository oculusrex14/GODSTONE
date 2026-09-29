#!/bin/sh
# Run the three Android lanes and record the SOURCE DIGEST each compiled.
#
#     tools/readiness/run_android_lanes.sh
#
# WHY: `ci/check_lane_results.py` bindeth each lane's result files to the bytes they tested, and
# **THE RUNNER IS THE ONLY PARTY THAT KNOWETH WHICH TREE IT COMPILED** -- the control can only CHECK.
# *`--rerun-tasks` replaces the XML on a real run, but nothing asserted that the replacement happened; measured,
# 155 Kotlin sources under `android/mesh/src` were newer than that lane's result XML.*
#
# THE DIGEST IS OVER CONTENT, NOT MTIMES: a `git checkout` or a `touch` moveth an mtime WITHOUT changing a byte,
# so an mtime-bound control would refuse genuinely-current lanes.
set -eu
cd "$(dirname "$0")/../.."

# *** THE PRE-RUN DIGESTS, SO A MID-RUN EDIT CANNOT DESCRIBE A TREE THE TESTS NEVER COMPILED. ***
# *The same contract the two iOS runners carry: the digest is taken BEFORE the lanes start and AFTER they finish, and
# the two must agree -- otherwise the result files describe no single revision.*
python3 tools/readiness/android_source_digest.py >android-app.pre.sha256
python3 tools/readiness/android_source_digest.py --lane android:core >android-core.pre.sha256
python3 tools/readiness/android_source_digest.py --lane android:mesh >android-mesh.pre.sha256

JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@17}" \
ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}" \
  ./android/gradlew -p android \
    :app:testDebugUnitTest :core:testDebugUnitTest :mesh:testDebugUnitTest \
    --rerun-tasks --no-daemon --console=plain
rc=$?

python3 tools/readiness/android_source_digest.py >android-app.sources.sha256
python3 tools/readiness/android_source_digest.py --lane android:core >android-core.sources.sha256
python3 tools/readiness/android_source_digest.py --lane android:mesh >android-mesh.sources.sha256

# *** AND THE PRE-RUN DIGESTS MUST EQUAL THE POST-RUN ONES. ***
drift=0
for lane in app core mesh; do
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

echo "Android lanes: rc=$rc, digests written"
exit $rc
