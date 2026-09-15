"""IOS-07 (T15/T20/T23) -- the silent-peer deadlines must have a SCHEDULED PRODUCTION OWNER.

The card's own words: "Cancel owned timers on success/disconnect/stop and ensure cancellation of an old lease
cannot cancel a replacement. Keep existing ingress checks as defense in depth, not ..." -- and, before that,
the whole point of a DEADLINE: it must fire on its own.

READ FROM THE CODE: `BleTransport.sweepInboundLeases()` (:2827) carrieth the sweep -- it walketh the outbound
lifetimes and the inbound lifetimes, asketh each connection whether a lease lapsed, and retires the OWNING
relation through its exact key -- AND IT IS CALLED BY NOTHING IN PRODUCTION: the only caller anywhere is a
court (`ReadinessT20Tests:1000` calls `bob.sweepInboundLeases()`). A SILENT peer's lapsed deadline therefore
waiteth for unrelated traffic for ever, which is the same defect the android isle carried and closed at round
210 (its own `sweepInboundLeases` had no production caller either).

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth a scheduled job and its observation seams, and a behavioural arm
of a seam that doth not exist cannot compile. It is run BEFORE the edit and kept afterwards as the regression
control; the BEHAVIOURAL half is built VERBATIM on the court's own working expiry arm and differeth in exactly
one way -- it never calleth the sweep -- which is the controlled-experiment discipline round 210 paid five
rounds to learn.

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
TRANSPORT = REPO / "ios/Godstone/Sources/GodstoneMesh/BleTransport.swift"


class IosDeadlineSweepOwnerTest(unittest.TestCase):
    """W00 -- the positive control: the sweep and the lifecycle still exist, and the sweep still retires
    only the owning relation through its exact key."""

    def test_w00_the_sweep_and_its_exact_key_retirement_still_exist(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("public func sweepInboundLeases()", t)
        self.assertIn("public func start()", t)
        self.assertIn("public func stop()", t)
        self.assertIn("activeOutboundLifetimes", t)
        self.assertIn("activeInboundLifetimes", t)

    def test_the_sweep_has_a_scheduled_production_owner(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn(
            "leaseSweepJob", t,
            "IOS-07: `sweepInboundLeases()` is called ONLY by a court, so a SILENT peer's lapsed deadline waits "
            "for unrelated traffic for ever -- the same defect the android isle closed at round 210, and the "
            "deadline must be OWNED by a scheduled job")

    def test_the_owner_armeth_at_start_and_cancelleth_at_stop(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        # THE ARMING LIVETH IN THE INSTALL STEP, NOT IN start()'s OWN TEXT: `start()` quiesces the previous
        # epoch and then calleth `startInstalling()`, which is the one place where a start is CERTAIN. A first
        # draft of this arm looked only inside `start()` and failed on that -- its own assertion, not the code.
        self.assertIsNotNone(
            re.search(r"private func startInstalling\(\)[\s\S]{0,900}?armLeaseSweepIfNeeded\(\)", t),
            "the install step must ARM the sweep, or a silent peer is never swept")
        self.assertIsNotNone(
            re.search(r"public func stop\(\)[\s\S]{0,6000}?leaseSweepJob\?\.cancel", t),
            "stop() must CANCEL the owned sweep -- an orphan job outliveth the transport")

    def test_the_interval_is_named_and_injectable(self):
        """A named constant for production AND an injectable value for the court that proveth it by time."""
        t = TRANSPORT.read_text(encoding="utf-8")
        # THE ISLE'S OWN NAMING: a first draft wrote the ANDROID convention (SCREAMING_CASE) and failed against
        # the Swift constant -- the arm's error, not the code's, and the second such self-inflicted slip of this
        # finding. The convention of the isle under judgment is the one that counteth.
        self.assertRegex(t, r"static let leaseSweepIntervalSeconds\s*:\s*TimeInterval",
                         "the production interval must be a NAMED constant")
        self.assertRegex(t, r"leaseSweepInterval\w*\s*:\s*(TimeInterval|Double|Int)",
                         "the interval must be INJECTABLE, so a court can witness expiry BY TIME rather than "
                         "by traffic (the seam the android isle's round 206 added for exactly this reason)")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
