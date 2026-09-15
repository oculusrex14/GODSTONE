"""IOS-04 (T24) slice (b) -- the REAL application LinkReady must CAPTURE the trusted peer.

The card's own step 1: "At authenticated binding, capture `TrustedPeer(relation, nodeId16, identityPub32,
trustVersion)` from the trusted controller/repository result ...".

READ FROM THE CODE (round 237): the instrument standeth -- `TrustedPeer` (TrustedPeerChannel.swift) carrieth the
relation, `nodeId16`, `identityPub32` and a `trustVersion`, and its FAILABLE initialiser VALIDATETH the lengths -- and
`PeerEventPublisher` already offereth `publishLinkReady(_:)`/`publishLinkLost(_:)`/`publishAuth(_:)` on this isle. BUT
THE TRANSPORT OWNETH NO PUBLISHER AND CAPTURETH NO PEER: `publishApplicationLinkReadyOnce(_ peerId: UUID)` -- the ONE
place the application LinkReady is made, after the sealed key-confirmation round -- telleth its watchers a BARE UUID
and nothing more. THE REAL CONSUMER THEREFORE RECEIVETH A HANDLE, NEVER A TRUSTED PEER -- which is the finding's own
title, and the twin of the android slice (b) landed at round 226.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth an accessor, a capture and a seam, and a behavioural arm of a capture
that doth not exist cannot compile. The behavioural half ships WITH the repair.
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
SESSION = REPO / "ios/Godstone/Sources/GodstoneMesh/SessionManager.swift"


class IosLinkReadyCapturesPeerTest(unittest.TestCase):
    """W00 -- the positive control: the instrument and the publication site still exist."""

    def test_w00_the_instrument_and_the_publication_site_still_exist(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("private func publishApplicationLinkReadyOnce(", t)
        self.assertIn("func publishLinkReady(_ captured: TrustedPeer)", 
                      (REPO / "ios/Godstone/Sources/GodstoneMesh/PeerEventPublisher.swift").read_text(encoding="utf-8"))
        tp = (REPO / "ios/Godstone/Sources/GodstoneMesh/TrustedPeerChannel.swift").read_text(encoding="utf-8")
        self.assertIn("init?(relation: RelationKey", tp, "the failable, validating initialiser must stand")

    def test_the_session_manager_answereth_the_authenticated_pubkey(self):
        s = SESSION.read_text(encoding="utf-8")
        self.assertRegex(
            s, r"func authenticatedIdentityPubOf\(",
            "IOS-04 step 1: `TrustedPeer` needeth the identity PUBLIC KEY, and the manager answereth only the NODE ID "
            "today -- the twin of the android accessor added at round 225")

    def test_the_real_link_ready_captures_the_peer(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertRegex(
            t, r"TrustedPeer\(relation:",
            "IOS-04 step 1: the publication moment must CONSTRUCT the trusted peer from the authenticated identity, "
            "not tell its watchers a bare UUID")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
