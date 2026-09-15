"""IOS-05 / T27 step 1 -- the GOVERNOR itself must be under the runtime owner.

The card's step 1, in its own words: "Put one governor configuration and the required bounded global/pre-auth
buckets under the runtime owner, using the canonical shared configuration and an injected monotonic clock."
And step 3: "After AEAD succeeds and a trusted peer is available, charge its authenticated identity/priority
budget before application decode/store/router delivery."

READ FROM THE ISLE: rounds 195-198 fixed the governor's DEFAULTS (the specified 256 bound, a structural
monotonic clock) and wired a purpose-built `AdmissionBudget` at the ingress and after AEAD -- BUT THE
`PeerGovernor` ITSELF IS STILL REFERENCED NOWHERE IN PRODUCTION except one comment, so the isle carrieth TWO
instruments where its card asketh for ONE governor configuration under the runtime owner, and the
identity/priority budget the card's step 3 nameth (which is exactly what the governor's buckets ARE) is not
charged at all.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth a field and two charge sites, and a behavioural arm of a
charge that doth not exist cannot compile. It is run BEFORE the edit and kept afterwards as the regression
control; the behavioural half is owed and named (a live-handshake flood through the authenticated gate).

It is NOT a device, emulator or radio result: it readeth production source text.
"""
from __future__ import annotations

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


class IosGovernorUnderRuntimeOwnerTest(unittest.TestCase):
    """W00 -- the positive control: the governor exists and its default configuration is the canonical one."""

    def test_w00_the_governor_exists_with_the_canonical_configuration(self):
        gov = (REPO / "ios/Godstone/Sources/GodstoneMesh/PeerGovernor.swift").read_text(encoding="utf-8")
        self.assertIn("public final class PeerGovernor", gov)
        self.assertIn("public static let defaultMaxTrackedPeers = 256", gov,
                      "the canonical bound must stay the specified 256")
        self.assertTrue(TRANSPORT.exists())

    def test_the_transport_owns_the_governor_under_the_runtime_owner(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("PeerGovernor(", t,
                      "IOS-05 / T27 step 1: the runtime owner must own the GOVERNOR -- the isle currently "
                      "carries a purpose-built AdmissionBudget for the ingress while `PeerGovernor` is "
                      "referenced nowhere in production but a comment, so there are TWO instruments where "
                      "the card asks for ONE governor configuration")

    def test_both_collectors_charge_the_authenticated_priority_budget(self):
        """The card's step 3: the identity/priority budget is charged AFTER AEAD and BEFORE delivery."""
        t = TRANSPORT.read_text(encoding="utf-8")
        for who in ("peerId", "centralId"):
            delivery = "delegate?.transportDidReceive(data: clear, peerId: " + who + ")"
            self.assertIn(delivery, t, "the delivery site for " + who + " must still exist")
            self.assertIn("governor.allowInbound(", t,
                          "the authenticated identity/priority budget -- the GOVERNOR's own buckets -- must be "
                          "charged in the collector for " + who + " before the payload leaves")
        first_charge = t.index("governor.allowInbound(")
        for who in ("peerId", "centralId"):
            delivery = t.index("delegate?.transportDidReceive(data: clear, peerId: " + who + ")")
            self.assertLess(
                first_charge, delivery,
                "the governor's charge must precede the delivery (charge at " + str(first_charge)
                + ", delivery for " + who + " at " + str(delivery) + ")")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
