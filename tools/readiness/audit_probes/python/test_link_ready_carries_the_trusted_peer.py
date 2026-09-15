"""ANDROID-03 (T24) slices (b) and (c) -- the REAL LinkReady must CARRY the captured trusted peer.

READ FROM THE CODE (round 226): the instrument standeth complete -- `PeerEventPublisher` offereth
`publishLinkReady(captured: TrustedPeer)`, `publishLinkLost(captured: TrustedPeer)` and `publishAuth(captured:
TrustedPeer)` -- and FOUR courts witness the bounded channel's contract. WHAT IS STILL MISSING IS THE PRODUCTION
REACH: the transport's own publication moment (`publishApplicationLinkReadyOnce`, called once, from the trust
transition) emiteth a BARE sixteen-octet peer id and NEVER CONSTRUCTS A `TrustedPeer`, so no real consumer ever
receiveth one. The card's own sentence: 'Replace the mesh transport's authoritative events with
LinkReady(TrustedPeer), LinkLost(TrustedPeer), and AuthenticatedFrame(TrustedPeer, FrameV2/rawBytes)'.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth an owned publisher and a construction at one site, and a behavioural
arm of a publisher that no production path reacheth cannot compile. The behavioural half ships WITH the repair.
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


class LinkReadyCarriesTrustedPeerTest(unittest.TestCase):
    """W00 -- the positive control: the instrument and its four courts still exist."""

    def test_w00_the_publisher_and_the_channel_still_exist(self):
        pub = (REPO / "android/mesh/src/main/java/io/godstone/mesh/transport/PeerEventPublisher.kt").read_text(encoding="utf-8")
        self.assertIn("fun publishLinkReady(captured: TrustedPeer", pub)
        self.assertIn("fun publishLinkLost(captured: TrustedPeer", pub)
        chan = (REPO / "android/mesh/src/main/java/io/godstone/mesh/transport/TrustedPeerChannel.kt").read_text(encoding="utf-8")
        self.assertIn("fun offer(", chan, "the bounded channel's offer must still stand")

    def test_the_transport_owneth_the_publisher(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertRegex(t, r"PeerEventPublisher\(",
                         "ANDROID-03: the transport must OWN the event publisher -- today it is referenced in NO "
                         "production file, so no real consumer ever receiveth a LinkReady carrying a trusted peer")

    def test_the_real_link_ready_carrieth_a_captured_peer(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertRegex(t, r"TrustedPeer\.capture\(",
                         "ANDROID-03: the publication moment must CONSTRUCT the trusted peer from the AUTHENTICATED "
                         "identity public key (`TrustedPeer.capture`), not emit a bare peer id")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
