"""IOS-02 -- the iOS ADAPTER must START the trusted handshake (D2) itself, on the real trust transition.

THE AUDIT'S OWN WORDS: "The adapter never starts D2 or key confirmation" -- `beginTrustedHandshake(`
appeareth ONCE in the canonical Sources (its declaration at `GodstoneMesh/BleTransport.swift:2294`) and
`beginKeyConfirmation(` ONCE (`:2575`). Measured in round 281: **NOTHING IN PRODUCTION CALLETH EITHER**,
so a relation reacheth trust only if application or test code invoketh the entry point by hand -- which
is the same defect ANDROID-01 carrieth on the other isle, and the fourth finding in this programme whose
whole shape is "the instrument existeth and no production path reacheth it".

WHY THIS ARM IS SOURCE-LEVEL: it is the WITNESS THAT CAN BE RUN TODAY, without a device and without
reddening the iOS lane. Its behavioural half -- three arms witnessing that the adapter putteth HS1 on the
wire by itself, that a duplicate notification reduction beginneth no second handshake, and that a second
begin is REFUSED -- is PARKED, RUN AND MEASURED in
`tools/readiness/audit_probes/swift/ReadinessIOS02Tests.swift`, together with the repair that maketh them
green (T22: 16 tests, 0 failures) and the measured blast radius of that repair (61 arms across five
suites whose rigs still begin by hand; ReadinessT23 30, ReadinessT21 26, ReadinessT17 3, ReadinessT19 1,
ReadinessT14 1). THE REPAIR IS PRESERVED AS A RE-APPLIABLE PATCH:
`.../REMEDIATION/IOS-02/round281-the-repair-and-the-arms.patch`.

IT IS PARKED HERE, AND NOT IN `tools/readiness/tests/`, for the reason the directory's README giveth: the
test lane must never be red, and this arm is RED BY DESIGN until the repair landeth. **When it landeth,
this file MOVES into the canonical suite** -- the card's "move the independent failing assertion into the
canonical subsystem suite" is part of the repair, not a preliminary.

It readeth production source text. It is NOT a device, radio or runtime result, and no gate is closed by
it.
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
SOURCES = REPO / "ios" / "Godstone" / "Sources"
TRANSPORT = SOURCES / "GodstoneMesh" / "BleTransport.swift"
REDUCTION = "reductionProcessPeripheralNotificationStateUpdated"


def _production_swift() -> str:
    """Every canonical Swift source, so a call site is found WHEREVER the repair putteth it."""
    return "\n".join(p.read_text(encoding="utf-8") for p in sorted(SOURCES.rglob("*.swift")))


class IosTransportStartsD2Test(unittest.TestCase):
    """W00 -- the positive control: the entry points and the sending side still exist to be reached."""

    def test_w00_the_entry_points_still_exist(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("public func beginTrustedHandshake(", t,
                      "the initiator's door must still exist for a production path to reach")
        self.assertIn("internal func beginKeyConfirmation(", t,
                      "the key-confirmation door must still exist for the trusted transition to reach")
        self.assertIn("writeHandshakeRecord(.hs1, payload: hs1, toPeripheral: peerId)", t,
                      "the sending side of the first counsel must still exist")

    def test_the_adapter_starteth_the_trusted_handshake_itself(self):
        t = _production_swift()
        calls = [m.start() for m in re.finditer(r"beginTrustedHandshake\(", t)]
        self.assertGreater(
            len(calls), 1,
            "IOS-02: `beginTrustedHandshake(` is called from NOWHERE in production -- every occurrence is "
            "its declaration -- so the application never starts D2 or key confirmation, and a relation "
            "reacheth trust only if application or test code invoketh the door by hand.")

    def test_the_begin_sitteth_on_the_physical_duplex_reduction(self):
        """The card's first step: "enter it from the ACTUAL physical-duplex reducer, after ROLE_BOUND,
        localHint < remoteHint, and complete duplex validation"."""
        t = TRANSPORT.read_text(encoding="utf-8")
        # THE DECLARATION, NOT THE FIRST MENTION -- and this was a defect of this probe's own first
        # draft, caught by RUNNING it: `t.find(REDUCTION)` matched the CALL inside the public wrapper
        # (`processPeripheralNotificationStateUpdated` delegateth to
        # `reductionProcessPeripheralNotificationStateUpdated`), so the window judged the WRAPPER and
        # this arm could NEVER pass, however good the repair. A WINDOW THAT BEGINS AT THE WRONG PLACE
        # IS AS BLIND AS ONE THAT ENDS AT THE WRONG PLACE (the fifth species of round 277).
        marker = "public func " + REDUCTION + "("
        start = t.find(marker)
        self.assertGreater(start, 0, "the physical-duplex reduction's DECLARATION must exist: " + marker)
        # the reduction, from its declaration to the next top-level `public func`: a bounded window
        # whose edge IS the next declaration, so it cannot run past the thing it judgeth
        following = t.find("\n    public func ", start + len(marker))
        body = t[start:following if following > 0 else start + 4000]
        self.assertIn(".physicalDuplexReady", body,
                      "the window must actually cover the physical-duplex-ready branch (if this fails, "
                      "the window is wrong and every assertion below it is worthless)")
        self.assertIn("beginTrustedHandshake(", body,
                      "the begin must be made FROM the physical-duplex reduction, not from some other "
                      "path: the reduction is the one place where ROLE_BOUND, the witnessed duplex and "
                      "the relation's own captured hint are all true together")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
