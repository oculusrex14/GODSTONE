"""IOS-04 (T24) slice (a) -- the authenticated IDENTITY PUBLIC KEY must be retained and answerable.

The card's own step 1: "At authenticated binding, capture `TrustedPeer(relation, nodeId16, identityPub32,
trustVersion)` from the trusted controller/repository result ...".

READ FROM THE CODE (round 236): the iOS controller retaineth `binding.nodeId` at BOTH trust sites and answereth
`authenticatedNodeId`, which is the shape THIS SESSION built on the android isle at round 197 and mirrored here at
round 198. BUT A `TrustedPeer` NEEDETH THE IDENTITY PUBLIC KEY (32 octets), NOT ONLY THE NODE ID: `nodeId16` is
DERIVED from that key, and the type's own law is that a captured peer 'can never disagree with its own identity public
key'. WITHOUT A PUBKEY ACCESSOR THE TRUSTED PEER CANNOT BE CONSTRUCTED AT THE AUTHENTICATED BINDING AT ALL -- which is
the whole of IOS-04's step 1, and the twin of the android slice landed at round 225.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth a field and an accessor, and a behavioural arm of an accessor that
doth not exist cannot compile. The behavioural half ships WITH the repair.
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
CONTROLLER = REPO / "ios/Godstone/Sources/GodstoneMesh/TrustedHandshakeController.swift"


class IosAuthenticatedPubkeyTest(unittest.TestCase):
    """W00 -- the positive control: the node-id retention and its accessor still exist at both trust sites."""

    def test_w00_the_node_id_retention_still_stands(self):
        c = CONTROLLER.read_text(encoding="utf-8")
        self.assertEqual(2, c.count("retainedNodeId = binding.nodeId"),
                         "both trust sites must still retain the node id")
        self.assertIn("var authenticatedNodeId: Data?", c)

    def test_the_identity_public_key_is_retained_at_both_trust_sites(self):
        c = CONTROLLER.read_text(encoding="utf-8")
        self.assertEqual(2, c.count("retainedIdentityPub = binding.signingPublicKey"),
                         "IOS-04 step 1: the AUTHENTICATED IDENTITY PUBLIC KEY must be retained at BOTH trust sites, "
                         "beside the node id, or no `TrustedPeer` can be captured at the authenticated binding")

    def test_it_is_answerable_as_a_copy(self):
        c = CONTROLLER.read_text(encoding="utf-8")
        self.assertRegex(c, r"var authenticatedIdentityPub: Data\?",
                         "the accessor must exist, the twin of `authenticatedNodeId`")
        i = c.index("var authenticatedIdentityPub: Data?")
        window = c[i:i + 160]
        self.assertRegex(window, r"copyOf\(\)|Data\(|\.map \{",
                         "it must hand out a COPY, as the node-id accessor doth -- a caller may not mutate the slot")

    def test_it_is_cleared_with_the_node_id(self):
        c = CONTROLLER.read_text(encoding="utf-8")
        i = c.index("private func destroy()") if "private func destroy()" in c else c.index("retainedNodeId = nil") - 200
        window = c[i:i + 900]
        self.assertIn("retainedIdentityPub = nil", window,
                      "the retained key must be cleared wherever the node id is cleared")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
