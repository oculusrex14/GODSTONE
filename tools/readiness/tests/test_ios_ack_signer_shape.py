"""GS-RUNTIME-001 / step 2 -- THE ACK ROAD MUST BE CONSTRUCTIBLE OVER THE PINNED IDENTITY.

**ROUND 216: THIS PROBE'S FIRST FORM ASSERTED A DESIGN GUESS OF MINE, AND THE GUESS WAS WRONG. It demanded
`sign(preimage:)` AND THE REMOVAL OF `signingSeed` ALTOGETHER. The implemented design is BETTER and satisfieth the
same law: the seam carrieth BOTH roads, `signAck(msgId:recipientNodeId:)` WITH A DEFAULT IMPLEMENTATION that signeth
through `signingSeed`, so every harness signer and every court kept working with NO reconciliation -- while the
PRODUCTION signer (`IdentityAckSigner`) refuseth the seed road outright. THE PROBE IS NOW THE LAW, NOT MY GUESS:
(1) a production signer over the pinned identity EXISTS; (2) it RELEASES NO SEED; (3) it SIGNETH the canonical
preimage; and (4) THE DRIVER TAKES THE SIGNING ROAD, not the seed road.**

THE LAW, IN THE CARD'S OWN TERMS: step 2 requireth the durable ACK store/driver/pump to be constructed over
THE SAME OPENED PRIVATE DATABASE AND PINNED IDENTITY in the runtime composition. MEASURED (round 212): that
construction is blocked, and not for want of code -- **the seam's SHAPE assumeth the harness**:

    protocol AckSignerSeam: AnyObject {
        var nodeId: Data? { get }
        func generation() -> Int64
        func signingSeed(msgId: Data, recipientNodeId: Data) throws -> Data?     <-- A SEED, NOT A SIGNATURE
    }

and the driver's own loop TAKETH that seed and buildeth the signed frame itself (AckObligationStore.swift:
`seed = try signer.signingSeed(...)`, then `guard let seed else { keyUnavailable += 1; continue }`).

PRODUCTION CANNOT SATISFY IT, AND MUST NOT: `MeshIdentity` keepeth its signing key PRIVATE and offereth a
SIGNATURE (`internal func sign(message:) throws -> Data`) but NO SEED ACCESSOR -- because HANDING OUT THE
PINNED SEED IS EXACTLY WHAT A PRODUCTION IDENTITY SHOULD NOT DO. The harness satisfieth it only because the
harness GENERATETH ITS OWN material; hence `TestAckSigner` and its own confession, "IT IS HARNESS SUPPORT AND
NOT A DEVICE RESULT".

SO THE REPAIR'S PRECONDITION IS A DESIGN CHANGE -- the seam becometh SIGNATURE-SHAPED (`sign(preimage:)`, with
the store no longer deriving the signature from exported material), or the driver accepteth a signer that signeth
internally -- AND WRITING A SEED-EXPORTING "PRODUCTION SIGNER" WOULD BE A KEY-MATERIAL BREACH DRESSED AS
COMPLIANCE. This probe is RED BY DESIGN and PARKED; its arms MOVE into the canonical suite when the seam changes.
It readeth production source text: it is NOT a device or runtime result, and no gate is closed by it.
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
STORE = REPO / "ios/Godstone/Sources/GodstoneMesh/AckObligationStore.swift"
IDENTITY = REPO / "ios/Godstone/Sources/GodstoneMesh/MeshIdentity.swift"


class AckSignerShapeTest(unittest.TestCase):
    """W00 -- the positive control: the driver and its frame-building loop still exist to be judged."""

    def test_w00_the_driver_still_existeth(self):
        t = STORE.read_text(encoding="utf-8")
        self.assertIn("protocol AckSignerSeam", t)
        self.assertIn("signingSeed(msgId: Data, recipientNodeId: Data)", t,
                      "the seam this probe judgeth must still stand where it standeth")

    def test_a_production_signer_existeth_and_the_driver_taketh_the_signing_road(self):
        """The law: the ACK road must be constructible over the PINNED identity WITHOUT exporting private material."""
        store = STORE.read_text(encoding="utf-8")
        identity = IDENTITY.read_text(encoding="utf-8")
        signer_file = REPO / "ios/Godstone/Sources/GodstoneMesh/IdentityAckSigner.swift"

        # (1) A PRODUCTION SIGNER OVER THE PINNED IDENTITY EXISTS
        self.assertTrue(signer_file.exists(),
                        "GS-RUNTIME-001 step 2: there must be a PRODUCTION signer bound to the pinned identity -- "
                        "the harness's own confession ('HARNESS SUPPORT AND NOT A DEVICE RESULT') is not one")
        signer = signer_file.read_text(encoding="utf-8")
        self.assertIn("final class IdentityAckSigner: AckSignerSeam", signer)

        # (2) IT RELEASES NO SEED -- and the identity it signeth for keepeth its material private
        self.assertRegex(identity, r"private let signingKey",
                         "the identity's signing key must stay private")
        self.assertRegex(signer, r"func signingSeed\(msgId: Data, recipientNodeId: Data\) throws -> Data\? \{ nil \}",
                         "GS-RUNTIME-001 step 2: the production signer must REFUSE the seed road BY CONSTRUCTION, so "
                         "that a caller learns the truth rather than a stand-in")

        # (3) IT SIGNETH THE CANONICAL PREIMAGE
        self.assertIn("AckFrame.preimage(msgId: msgId, recipientNodeId: recipientNodeId)", signer,
                      "the production road must sign the EXISTING canonical preimage, not a new one beside it")

        # (4) THE DRIVER TAKES THE SIGNING ROAD -- and the seed road surviveth ONLY as the default that keepeth
        #     the harness working, never as the road the driver walketh.
        self.assertIn("signer.signAck(msgId: ob.msgId, recipientNodeId: ob.recipientNodeId)", store,
                      "GS-RUNTIME-001 step 2: the driver must ASK FOR A SIGNATURE rather than a seed")
        self.assertIn("msgId: ob.msgId, signature: signatureForFrame", store,
                      "and it must build the frame FROM THAT SIGNATURE through the signature-taking builder")
        self.assertIn("func signAck(msgId: Data, recipientNodeId: Data) throws -> Data? {\n        guard let seed = try signingSeed(",
                      store,
                      "the SEED road surviveth ONLY as `signAck`'s DEFAULT -- which is what made this change additive")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
