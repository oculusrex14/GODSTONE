"""IOS-05 / T27 step 3 -- the POST-AEAD charge on the AUTHENTICATED identity.

The card's own words: "After AEAD succeeds and a trusted peer is available, charge its authenticated
identity/priority budget before application decode/store/router delivery. Bind budget outcomes ...".

READ FROM THE ISLE, not from the card: the iOS transport's two post-AEAD collectors
(`registry?.openWithResult(peerId, record.payload)` / `openWithResult(centralId, rec.payload)`) hand the
plaintext on UNCHARGED; `PeerGovernor` is referenced nowhere in production; and the iOS
`TrustedHandshakeController` CONSUMETH the validated binding through `applyValidatedBinding(...)` WITHOUT
RETAINING IT -- so the authenticated identity the charge must ride on is not even answerable, exactly as on
the android isle before round 193.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth a retention and an accessor, and an assertion about an API
that doth not exist cannot compile. It is run BEFORE the edit and kept afterwards as the regression control;
the BEHAVIOURAL half (a real trusted handshake answering the peer's OWN sixteen-octet NodeID) ships WITH the
repair, as it did on the android isle.

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
MESH = REPO / "ios/Godstone/Sources/GodstoneMesh"
CONTROLLER = MESH / "TrustedHandshakeController.swift"
SESSIONS = MESH / "SessionManager.swift"
TRANSPORT = MESH / "BleTransport.swift"


class IosPostAeadChargeTest(unittest.TestCase):
    """W00 -- the positive control: the post-AEAD road and its two collectors still exist."""

    def test_w00_the_post_aead_road_still_exists(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertGreaterEqual(t.count("openWithResult("), 2,
                                "the isle must still decrypt through the registry on both sides")
        self.assertIn("Authenticated", t)
        self.assertTrue(CONTROLLER.exists() and SESSIONS.exists())

    def test_the_controller_retains_the_identity_the_handshake_validated(self):
        c = CONTROLLER.read_text(encoding="utf-8")
        self.assertEqual(
            2, len(re.findall(r"applyValidatedBinding\(binding\)", c)),
            "the two trust sites must still exist to be judged")
        self.assertRegex(
            c, r"retainedNodeId\s*=|retainedIdentity\s*=",
            "IOS-05 / T27 step 3: the controller consumes the VALIDATED binding WITHOUT RETAINING it, so the "
            "authenticated identity the post-AEAD charge must ride on is not answerable -- and the Noise "
            "remote static key is the DH key, NOT the identity (the android isle learned this at round 192)")

    def test_the_authenticated_identity_is_answerable_and_read_only_by_trust(self):
        s = SESSIONS.read_text(encoding="utf-8")
        self.assertRegex(
            s, r"func\s+authenticatedNodeIdOf\s*\(",
            "the SessionManager must expose the RETAINED authenticated identity under the relation's peer "
            "id, answering nil while trust was never marked")

    def test_the_collectors_charge_before_the_payload_leaves(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        for m in re.finditer(r"openWithResult\((?P<key>\w+), ?(?P<payload>[\w.]+)\)(?P<tail>.*?)(?:trySend|yield)",
                             t, re.DOTALL):
            tail = m.group("tail")
            self.assertRegex(
                tail, r"authenticatedAdmissionBudget\s*\.\s*charge|admissionBudget\s*\.\s*chargeAuthenticated",
                "IOS-05 / T27 step 3: the collector for `" + m.group("key") + "` handeth the plaintext on "
                "WITHOUT charging the authenticated identity -- the router's governor is downstream of the "
                "application decode, and the isle's own governor is referenced nowhere in production")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
