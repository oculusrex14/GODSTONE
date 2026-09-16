"""IOS-04 (T24) step 3 -- the application must be told WHO sent a frame: the AUTHENTICATED NODE ID, not a handle.

The card's own words: "Route inbound frames with `capturedPeer.nodeId16` as `receivedFrom`."

READ FROM THE CODE: both post-AEAD collectors tell the consumer `transportDidReceive(data: clear, peerId: <handle>)`
-- an OPAQUE UUID -- and NOTHING carrieth the authenticated node id the handshake validated, even though the transport
now CAPTURES it at the sealed round (`capturedPeers`). THE APPLICATION THEREFORE CANNOT TELL WHICH IDENTITY SENT A
FRAME, only which transport handle carried it -- and a handle is not an identity. (The android isle carrieth the same
shape and was measured at round 223-228.)

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth a delegate method and its calls, and a behavioural arm of a method
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


class IosReceivedFromNodeIdTest(unittest.TestCase):
    """W00 -- the positive control: both collectors and the existing delivery method still exist."""

    def test_w00_the_collectors_and_the_delivery_still_exist(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertEqual(2, t.count("transportDidReceive(data: clear, peerId:"),
                         "both post-AEAD collectors must still deliver to the consumer")
        self.assertIn("func transportDidReceive(data: Data, peerId: UUID)", t)

    def test_a_delivery_carrieth_the_authenticated_node_id(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertRegex(
            t, r"func transportDidReceive\(data: Data, peerId: UUID, receivedFrom",
            "IOS-04 step 3: the consumer must be told the AUTHENTICATED NODE ID of the sender -- a handle is not an "
            "identity, and the transport capturETH the identity at the sealed round but never passeth it on")

    def test_at_least_one_collector_useth_it(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertRegex(t, r"transportDidReceive\(data: clear, peerId: [A-Za-z]+, receivedFrom:",
                         "the collector must actually carry it, not merely the protocol")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
