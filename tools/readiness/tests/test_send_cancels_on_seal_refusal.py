"""ANDROID-06 step 2 at the CALLER -- a refused seal must RETURN its slot.

The card's own words: "provide cancellation that returns a slot."

READ FROM THE CODE (round 218): `BleTransport.sendThrough` reserveth, then sealeth. Its
`SealAnswer.Refused ->` branch recordeth the refusal in the transport's census and RETURNETH a
`TransportResult` -- **AND NEVER CANCELS THE RESERVATION**. With the reserved-slot table landed at round 216 (which
is what maketh the four-record bound count RESERVED records, as the card's step 4 demandeth), EVERY REFUSED SEAL
THEREFORE LEAKS A SLOT: four refusals exhaust the relation's bound and it can send NOTHING further. That is a
consequence of the repair itself, found by reading the caller after changing the callee -- and it is exactly the
cancel-at-the-caller half of step 2 that round 217 named as owed.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth a call inside one branch, and a behavioural arm of it needs a full
session whose sealer refuses (no court has one -- nothing in the suite mentioneth a refused seal). The behavioural
half is therefore OWED AND NAMED rather than implied.
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


class SendCancelsOnSealRefusalTest(unittest.TestCase):
    """W00 -- the positive control: the reserving sender and its refusal branch still exist."""

    def test_w00_the_sender_and_its_refusal_branch_still_exist(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("private suspend fun sendThrough(", t)
        self.assertIn("is SealAnswer.Refused ->", t)
        self.assertIn("writer.reserve(", t)
        self.assertIn("sealAndQueue(", t)

    def test_the_refused_seal_cancelleth_the_reservation(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        i = t.index("is SealAnswer.Refused ->")
        # the branch runs to the next branch of the same when, generously bounded
        branch = t[i:i + 2600]
        self.assertRegex(
            branch, r"\.cancel\(",
            "ANDROID-06 step 2 at the CALLER: `sendThrough`'s `SealAnswer.Refused` branch recordeth the refusal and "
            "RETURNETH WITHOUT CANCELLING THE RESERVATION -- so with the reserved-slot table landed at round 216, "
            "EVERY REFUSED SEAL LEAKS A SLOT and four refusals exhaust the relation's four-record bound")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
