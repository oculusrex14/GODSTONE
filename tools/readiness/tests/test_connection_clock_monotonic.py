"""ANDROID-04 (T20/T23) step 1 -- THE CONNECTION'S LEASE CLOCK MUST BE MONOTONIC.

The card's own words: "Inject a monotonic clock into the actual transport/composition
(`SystemClock.elapsedRealtime` or a canonical monotonic abstraction with explicit units); keep wall time only
for app ...".

READ FROM THE CODE: `BleOrchestrationDriver` createth every connection with

    clock = connectionClockForTest ?: { System.currentTimeMillis() / 1000L }

AT **TWO** CREATION SITES -- a WALL CLOCK is the default for the lease clock of a real connection, and EVERY
lease deadline on this isle is computed against it. A wall clock can be stepped BACKWARDS (NTP, a user, a
hostile environment), and this session already replaced exactly this default in the GOVERNOR (rounds 187/195)
and the ADMISSION BUDGET (round 186) -- but not here.

WHY THIS ARM IS SOURCE-LEVEL: the repair changeth a default expression, and the behavioural consequences are
already covered by the parked time-based witness
(`tools/readiness/audit_probes/kotlin/t20-owned-sweep-time-witness.kt.txt`), which is re-run WITH the repair.

It is NOT a device, emulator or radio result: it readeth production source text.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path


def _repo_root() -> Path:
    here = Path(__file__).resolve()
    for candidate in [here.parent, *here.parents]:
        if (candidate / "ci" / "check_repository.py").exists():
            return candidate
    raise SystemExit("the repository root could not be located from " + str(here))


REPO = _repo_root()
DRIVER = REPO / "android/mesh/src/main/java/io/godstone/mesh/transport/BleOrchestrationDriver.kt"


def strip_comments(text: str) -> str:
    """Kotlin line comments removed, so that a comment quoting the audited spelling is not mistaken for it."""
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.splitlines())


class ConnectionClockMonotonicTest(unittest.TestCase):
    """W00 -- the positive control: the two creation sites and the injection seam still exist."""

    def test_w00_the_two_creation_sites_and_the_seam_still_exist(self):
        d = DRIVER.read_text(encoding="utf-8")
        # FOUR occurrences: the seam is DECLARED on both drivers and USED at both creation sites. (A first
        # draft asserted two and the control failed on its own miscount -- which is what a control is for.)
        self.assertEqual(4, d.count("connectionClockForTest"),
                         "the seam must be declared twice and used at both creation sites")
        self.assertGreaterEqual(len(re.findall(r"BleConnection\(", d)), 2,
                                "both creation sites must still be there to be judged")

    def test_no_connection_defaults_to_a_wall_clock(self):
        """COMMENTS ARE STRIPPED FIRST -- the same discipline the repository's own controls use, and for the
        same measured reason: a first draft banned the wall-clock spelling across the WHOLE file and tripped
        on the audit-trail COMMENT the repair itself had written above each site."""
        d = strip_comments(DRIVER.read_text(encoding="utf-8"))
        self.assertNotIn(
            "System.currentTimeMillis() / 1000L", d,
            "ANDROID-04 step 1: a real CONNECTION's lease clock defaulteth to a WALL clock, and every lease "
            "deadline is computed against it -- a wall clock can be stepped BACKWARDS. The card asketh for a "
            "monotonic clock in the actual transport/composition, with wall time kept only for the app.")

    def test_the_default_is_the_canonical_monotonic_source(self):
        d = DRIVER.read_text(encoding="utf-8")
        self.assertRegex(
            d, r"connectionClockForTest\s*\?:\s*\{?\s*System\.nanoTime\(\)",
            "the fallback must BE the monotonic source (System.nanoTime, whose units are stated), so that a "
            "connection created without an injected clock still carrieth a monotonic lease clock")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
