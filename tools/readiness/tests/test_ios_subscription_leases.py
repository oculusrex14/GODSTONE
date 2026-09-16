"""IOS-04 (T24) step 5 -- event subscriptions must be REMOVABLE LEASES.

The card's own words: "Give event subscriptions removable leases. Handle a full channel with an explicit bounded
retry/drain or terminal action; do not silently drop."

READ FROM THE CODE: the publisher ALREADY handeth back a token (`addSink(_:) -> Int`, `removeSink(_ token: Int)`), so
the instrument existed -- BUT THE TRANSPORT'S OWN SEAM DISCARDED IT (`addTrustedPeerSink` returned Void), and the ELDER
path kept bare closures in `applicationLinkReadyFlow: [(UUID) -> Void]` with NO way to withdraw one at all. A
subscription that cannot be withdrawn outliveth its owner: a stopped consumer keepeth hearing tales, and a REPLACED
one heareth tales meant for its predecessor.

HONESTY ABOUT THIS ARM'S PLACE IN THE ORDER: like the token-keyed store of round 246, the production change was made
BEFORE this arm, so it is a REGRESSION CONTROL and not red-proven -- the lease is a NEW capability rather than a
corrected behaviour, and no assertion against the old code could fail without inventing a caller that the isle's own
courts do not have. The BEHAVIOURAL witness (subscribe, withdraw, prove silence across a second publication) is OWED
and named.
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
PUBLISHER = REPO / "ios/Godstone/Sources/GodstoneMesh/PeerEventPublisher.swift"


class IosSubscriptionLeasesTest(unittest.TestCase):
    """W00 -- the positive control: the publisher's own lease instrument still exists."""

    def test_w00_the_publishers_lease_instrument_still_exists(self):
        p = PUBLISHER.read_text(encoding="utf-8")
        self.assertRegex(p, r"func addSink\(_ call: @escaping \(LinkEvent\) -> Void\) -> Int")
        self.assertRegex(p, r"func removeSink\(_ token: Int\)")

    def test_the_trusted_seam_handeth_back_its_lease(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertRegex(t, r"func addTrustedPeerSink\(_ sink: @escaping \(LinkEvent\) -> Void\) -> Int",
                         "IOS-04 step 5: the transport's seam must not DISCARD the lease the publisher handeth back")
        self.assertRegex(t, r"func removeTrustedPeerSink\(_ lease: Int\)")

    def test_the_elder_path_carrieth_leases_too(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("applicationLinkReadyFlow: [(lease: Int, ear: (UUID) -> Void)]", t)
        self.assertRegex(t, r"func removeApplicationLinkReady\(_ lease: Int\)",
                         "a subscription the application can stop is one that cannot outlive its owner")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
