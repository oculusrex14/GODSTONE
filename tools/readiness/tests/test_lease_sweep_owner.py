"""ANDROID-04 (T20/T23) -- the lease sweep must have a SCHEDULED PRODUCTION OWNER.

The card's step 3, in its own words: "Schedule assembly expiration independently of future peer traffic."

READ FROM THE CODE: `BleTransport.sweepInboundLeases()` (:979) is called **only** by a court
(`ReadinessT20Test:845` calls `rig.bob.sweepInboundLeases()`), so the absolute lease expiry runneth ONLY when
some other inbound packet arriveth and trips the ingress -- a SILENT peer therefore never trips it, and a
relation whose absolute term hath lapsed stayeth pinned until unrelated traffic happeneth by. That is the
finding's own sentence: the SCHEDULER, which is the card's first defect, is untouched.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth a scheduled job and its observation seam, and a behavioural arm
of a seam that doth not exist cannot compile. It is run BEFORE the edit and kept afterwards as the regression
control; the BEHAVIOURAL half (the sweep armed at start, cancelled at stop, and harmless after cancellation)
ships WITH the repair, where the transport's own `hasInboundJob` seam already showeth the shape.

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
TRANSPORT = REPO / "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt"


class LeaseSweepOwnerTest(unittest.TestCase):
    """W00 -- the positive control: the sweep and the transport's own job seams still exist."""

    def test_w00_the_sweep_and_the_lifecycle_still_exist(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("fun sweepInboundLeases()", t)
        self.assertIn("fun start()", t)
        self.assertIn("fun stop()", t)
        self.assertIn("hasInboundJob(", t,
                      "the inbound-job seam is the SHAPE a scheduled owner must follow")

    def test_the_sweep_is_armed_by_a_production_owner(self):
        """The card's step 3: expiration must not wait for future peer traffic."""
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn(
            "leaseSweepJob", t,
            "ANDROID-04: `sweepInboundLeases()` is called ONLY by a court, so a SILENT peer's lapsed absolute "
            "term is never swept until unrelated traffic happens by -- the scheduler the card nameth is "
            "untouched, and the expiry must be OWNED by a scheduled job")

    def test_the_owner_armeth_at_start_and_cancelleth_at_stop(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        armed = re.search(r"fun start\(\)[\s\S]{0,4000}?leaseSweepJob\s*=", t)
        self.assertIsNotNone(armed, "start() must ARM the sweep, or a silent peer is never swept")
        cancelled = re.search(r"fun stop\(\)[\s\S]{0,4000}?leaseSweepJob\?\.cancel", t)
        self.assertIsNotNone(cancelled, "stop() must CANCEL the owned sweep -- an orphan job outliveth the transport")

    def test_the_sweep_carrieth_a_harmless_interval(self):
        """A generous interval, so a frozen-clock court is never swept mid-witness."""
        t = TRANSPORT.read_text(encoding="utf-8")
        m = re.search(r"LEASE_SWEEP_INTERVAL_MS\s*[:=]\s*(\d[\d_]*)", t)
        self.assertIsNotNone(m, "the interval must be a NAMED constant, not a bare number")
        self.assertGreaterEqual(int(m.group(1).replace("_", "")), 250,
                                "a short interval would sweep frozen-clock courts mid-witness")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
