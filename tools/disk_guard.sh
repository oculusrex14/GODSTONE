#! /bin/sh
# Guard: fail loudly when the internal disk falls below a working margin.
#
# WHY THIS EXISTS: the machine reached 1.3 GiB free on a 228 GiB volume -- 100% on Data -- while
# builds, simulator runtimes and agent session logs kept writing. Nothing warned, so the first
# symptom was the disk being full. A margin that is only checked after a failure is not a margin.
#
# Usage:
#   tools/disk_guard.sh            # warn below 15 GiB, fail below 5 GiB
#   tools/disk_guard.sh 20 10      # custom warn/fail thresholds in GiB
#
# Exit codes: 0 ok, 1 below warn, 2 below fail.
set -eu

WARN_GIB="${1:-15}"
FAIL_GIB="${2:-5}"

avail_gib=$(df -g /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$avail_gib" ] || { echo "disk_guard: could not read free space" >&2; exit 2; }

echo "internal disk: ${avail_gib} GiB free (warn<${WARN_GIB}, fail<${FAIL_GIB})"

if [ "$avail_gib" -lt "$FAIL_GIB" ]; then
    echo "::error:: internal disk critically low: ${avail_gib} GiB free. Offload regenerable" >&2
    echo "::error:: caches to /Volumes/T9/offload/ before continuing." >&2
    exit 2
fi

if [ "$avail_gib" -lt "$WARN_GIB" ]; then
    echo "warning: internal disk below ${WARN_GIB} GiB; consider offloading caches to T9" >&2
    exit 1
fi

exit 0
