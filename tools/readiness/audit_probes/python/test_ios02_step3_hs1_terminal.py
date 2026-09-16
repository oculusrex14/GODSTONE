"""IOS-02 STEP 3 -- "Treat actual reservation rejection as terminal for that relation": the SOURCE-LEVEL probe.

WHY A SOURCE-LEVEL ARM, AND WHY IT IS PARKED HERE. The card's third step asketh that a reservation refusal on
the FIRST counsel be TERMINAL for the relation, rather than leaving an engaged exchange with nothing on the
wire. THE BEHAVIOURAL WITNESS IS NOT REACHABLE ON THIS ISLE, AND THAT IS MEASURED, NOT ASSUMED: this
repository's own arm for the SAME law at the THIRD counsel saith so in its own words --

    "the reservation flood on the island is beyond the tests reach by any public handle: the pump draineth as
     it runneth, and the staging is private. That branch is proven on the other island by the flooder and here
     by inspection."
                                    -- ReadinessT21Tests.testTheHS3ReservationFailureClosedTheRelationExactly

-- and it substitutes a duplicate-counsel case instead. So the law is witnessed HERE, by inspection of the
production text, until a seam or the Android flooder can carry it behaviourally.

MEASURED BEFORE THE REPAIR: `beginTrustedHandshake` ENDETH with

    return writeHandshakeRecord(.hs1, payload: hs1, toPeripheral: peerId)

-- it RETURNETH the outcome without inspecting it, having already marked the connection engaged
(`conn.markHandshakeEngaged()` and `conn.advanceStage(to: .hsOut)`). A refused first counsel therefore leaveth
a relation IN HANDSHAKE WITH NOTHING ON THE WIRE: the exchange is engaged and cannot proceed, which is the
defect the card nameth.

IT READETH PRODUCTION SOURCE TEXT. It is NOT a device, radio or runtime result, and no gate is closed by it.
When the repair landeth AND a behavioural seam existeth, this arm MOVES into the canonical suite.
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


class Step3Hs1ReservationTerminalTest(unittest.TestCase):
    """W00 -- the positive control: the first counsel still travellerh by the whole-record writer."""

    def test_w00_the_first_counsel_still_travellerh_by_the_writer(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("func beginTrustedHandshake(", t)
        self.assertIn("writeHandshakeRecord(.hs1, payload: hs1, toPeripheral: peerId)", t,
                      "the first counsel must still go out by the whole-record writer")

    def test_the_hs1_write_outcome_is_inspected_and_a_refusal_is_terminal(self):
        """The card: "Treat actual reservation rejection as terminal for that relation"."""
        t = TRANSPORT.read_text(encoding="utf-8")
        start = t.index("func beginTrustedHandshake(")
        end = t.index("\n    }", start)
        body = t[start:end]
        self.assertIn("writeHandshakeRecord(.hs1", body, "the window must cover the first counsel's write")
        # A TERMINAL refusal must INSPECT the outcome: the write's result must be BOUND to a name and tested.
        self.assertRegex(
            body, r"let\s+\w+\s*=\s*writeHandshakeRecord\(\.hs1",
            "IOS-02 step 3: `beginTrustedHandshake` RETURNETH the first counsel's write outcome WITHOUT "
            "BINDING IT, so a reservation refusal cannot be treated as terminal -- the relation stayeth "
            "engaged with nothing on the wire (measured: the function endeth `return writeHandshakeRecord(...)` "
            "AFTER `conn.markHandshakeEngaged()` and `advanceStage(to: .hsOut)`)")
        self.assertTrue(
            re.search(r"closeInitiatorRelation\(|closeResponderRelation\(", body) is not None,
            "IOS-02 step 3: a refused first counsel must CLOSE the relation exactly, not leave it engaged")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
