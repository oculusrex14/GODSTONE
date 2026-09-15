"""ANDROID-01 (T21/T22/T23/T24) -- the transport must START D2 itself, on the real trust transition.

The card's own words: "On the real HS3 ordered-write/trust transition, schedule one encrypted confirmation
challenge per relation through the record writer" (step 3) and "Remove the requirement that application/test code
directly invoke D2 to make a connection progress" (step 5).

READ FROM THE CODE (round 229): `BleTransport.beginKeyConfirmation(peerId, supplied)` (:1660) ISSUETH a challenge,
encodeth it (`KeyConfirmationControl.encodeChallenge`) and sendeth it as a sealed DATA record -- THE SENDING SIDE IS
COMPLETE. AND IT IS CALLED FROM **NOWHERE IN PRODUCTION**: every caller is a court (`ReadinessT23Test:909, 940,
972, 1003, 1075`). SO A CONNECTION PROGRESSES TO 'TRUSTED' ONLY IF APPLICATION OR TEST CODE INVOKES D2 ITSELF,
which is EXACTLY the card's step 5 -- and it is the FOURTH finding in this programme whose whole defect is 'the
instrument existeth and no production path reacheth it' (after ANDROID-04's sweep, IOS-07's deadline sweep, and
T24's trusted publication).

AND ITS CONSEQUENCE REACHES A NEIGHBOURING FINDING, MEASURED AT ROUND 228: the application LinkReady -- and with it
ANDROID-03's captured trusted peer -- is published ONLY upon the sealed key-confirmation round (the T23 law), so
while D2 is never started by the transport, NO REAL CONNECTION EVER BECOMES APPLICATION-READY.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth a scheduling call inside a handshake transition, and a behavioural
arm of a call that no production path maketh cannot compile. The behavioural half ships WITH the repair.
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


class TransportStartsD2Test(unittest.TestCase):
    """W00 -- the positive control: the D2 sending side and its court callers still exist."""

    def test_w00_the_d2_sending_side_still_exists(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("internal fun beginKeyConfirmation(", t)
        self.assertIn("KeyConfirmationControl.encodeChallenge(", t)

    def test_the_transport_schedulleth_the_challenge_itself(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        # the challenge must be scheduled from a PRODUCTION path: the call must appear OUTSIDE the function's own
        # declaration and OUTSIDE the test-facing seams (the courts live in another module entirely).
        calls = [m.start() for m in re.finditer(r"beginKeyConfirmation\(", t)]
        self.assertGreater(
            len(calls), 1,
            "ANDROID-01 step 5: `beginKeyConfirmation` is called from NOWHERE in production -- every caller is a "
            "court -- so a connection progresses to trusted only if application or test code invokes D2 itself")

    def test_the_scheduling_sitteth_on_a_handshake_transition(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        i = t.find("beginKeyConfirmation(")
        j = t.find("beginKeyConfirmation(", i + 1)
        self.assertNotEqual(-1, j, "a second call site must exist -- the scheduling one")
        window = t[max(0, j - 2000):j + 400]
        self.assertRegex(
            window, r"markHandshakeEngaged|ROLE_BOUND|handleHs3|hs3",
            "the scheduling must sit upon the HS3 ordered-write/trust transition the card names, not somewhere "
            "plausible")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
