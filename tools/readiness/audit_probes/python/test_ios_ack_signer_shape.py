"""GS-RUNTIME-001 / step 2 -- THE ACK SIGNER'S SEAM MUST BE SIGNATURE-SHAPED, NOT SEED-SHAPED.

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

    def test_the_seam_is_signature_shaped_and_the_identity_keepeth_its_seed_private(self):
        """The law: a PINNED identity must be able to sign an ACK obligation WITHOUT exporting its seed."""
        store = STORE.read_text(encoding="utf-8")
        identity = IDENTITY.read_text(encoding="utf-8")
        # the identity must keep its material private -- and it doth, which is the POINT:
        self.assertRegex(identity, r"private let signingKey",
                         "the identity's signing key must stay private (a seed accessor would be the breach)")
        self.assertRegex(identity, r"public var signingPublicKey",
                         "and its public half must stay answerable")
        # …so the seam must ask for a SIGNATURE, not a SEED:
        self.assertNotRegex(
            store, r"signingSeed\(msgId: Data, recipientNodeId: Data\)[^\n]*Data\?",
            "GS-RUNTIME-001 step 2: the seam still asketh for a SIGNING SEED, WHICH PRODUCTION'S PRIVATE KEY "
            "MUST NEVER HAND OUT -- so no production signer can exist, and the driver cannot be constructed "
            "over the pinned identity. THE REPAIR IS A SHAPE CHANGE, NOT A NEW FILE.")
        self.assertRegex(
            store, r"func sign\(preimage: Data\)",
            "GS-RUNTIME-001 step 2: the seam must offer a SIGNATURE-SHAPED road (`sign(preimage:)`) so that a "
            "signer bound to the PINNED identity can satisfy it without exporting anything.")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
