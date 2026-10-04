#!/bin/sh
# *** AN INVOKED NEGATIVE FIXTURE FOR `run_android_lanes.sh`'s KEEP-ALIVE GUARD. ***
#
#     tools/readiness/tests/mutation_runner_keepalive_probe.sh <path-to-run_android_lanes.sh>
#
# *THE DEFECT THIS PROVES CLOSED, AND WHY A GREP WOULD NOT: the runner runneth under
# `set -e`, so a non-zero gradle must be CAUGHT (`|| rc=$?`) rather than allowed to
# abort the script before it writes its post-run digests and runs the pre/post drift
# check. A source grep ("does `|| rc=$?` appear?") is a WIRING assertion, not a
# behavioural one: it says nothing about whether the script actually keeps going.*
#
# **SO THIS FIXTURE EXTRACTS THE RUNNER'S REAL CRITICAL SECTION AND EXECUTES IT.** *It
# builds a sandbox where `./android/gradlew` fails with a sentinel status and the digest
# writers are stubs that record they ran, then runs the extracted section. If the guard
# is present the section proceeds to the writers and `post-run-ran` exists; if the guard
# is absent (`set -e` aborts on the failing gradle) it does not, and this exits non-zero.
# The mutated line is the very thing exercised.*
#
# EXIT 0: the guard held (post-run step reached despite the failing command).
# EXIT 1: the guard is absent -- the runner aborted (this is the mutant's red).
set -eu
RUNNER="${1:?usage: mutation_runner_keepalive_probe.sh <run_android_lanes.sh>}"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# 1. the fixture's gradle that FAILS, exactly as a red lane would
mkdir -p "$SANDBOX/android" "$SANDBOX/tools/readiness"
printf '#!/bin/sh\nexit 7\n' >"$SANDBOX/android/gradlew"
chmod +x "$SANDBOX/android/gradlew"

# 2. extract the runner's critical section VERBATIM: from the `rc=0` line through the
#    gradle invocation (the guarded, mutated line) -- nothing else is reproduced.
awk '
    /^rc=0$/ { grab=1 }
    grab { print }
    grab && /--rerun-tasks --no-daemon --console=plain/ { exit }
' "$RUNNER" >"$SANDBOX/section.sh"

if ! grep -q 'gradlew' "$SANDBOX/section.sh"; then
    echo "the fixture could not find the gradle invocation in $RUNNER" >&2
    exit 1
fi

# 3. a driver that runs THAT section under the runner's own `set -eu`, then records that
#    control returned to the post-run step (the digest writers / sentinel).
# Pass the sandbox through the environment: printf %q is not portable /bin/sh.
{
    echo 'set -eu'
    printf 'cd "$SANDBOX"\n'
    cat "$SANDBOX/section.sh"
    printf 'echo post-run-reached >"$SANDBOX/post-run-ran"\n'
} >"$SANDBOX/driver.sh"

( SANDBOX="$SANDBOX" sh "$SANDBOX/driver.sh" ) >/dev/null 2>&1 || true

if [ -f "$SANDBOX/post-run-ran" ]; then
    echo "KEEP-ALIVE HELD: the failing command was caught and the post-run step was reached"
    exit 0
fi
echo "KEEP-ALIVE ABSENT: the runner aborted before its post-run step (the mutant's red)" >&2
exit 1
