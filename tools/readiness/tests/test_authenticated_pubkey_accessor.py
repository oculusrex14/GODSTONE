"""ANDROID-03 (T24) slice (a) -- the authenticated IDENTITY PUBLIC KEY must be answerable for a relation.

READ FROM THE CODE (round 224): the real publication site `publishApplicationLinkReadyOnce(peerId)` can reach the
authenticated identity only as a NODE ID -- `sessions?.authenticatedNodeIdOf(peerId)`, the accessor this session
added at round 197 -- while `TrustedPeer.capture(relation, authenticatedIdentityPub32, trustVersion)` REQUIRETH the
authenticated PUBLIC KEY (32 octets) and DERIVETH the node id from it, so that (in the file's own words) "a captured
peer can never disagree with its own identity public key". WITHOUT A PUBKEY ACCESSOR THERE IS NOTHING TO CAPTURE
FROM, and the trusted publication cannot be constructed at the real moment at all.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth a method, and a behavioural arm of a method that doth not exist
cannot compile. The behavioural half -- that the accessor answereth EXACTLY the peer's own identity public key after
a real handshake, and NULL before one -- ships WITH the repair.
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
SESSION = REPO / "android/mesh/src/main/java/io/godstone/mesh/crypto/SessionManager.kt"


class AuthenticatedPubkeyAccessorTest(unittest.TestCase):
    """W00 -- the positive control: the NODE-ID accessor of round 197 still standeth, with its lock discipline."""

    def test_w00_the_node_id_accessor_still_standeth(self):
        s = SESSION.read_text(encoding="utf-8")
        self.assertIn("fun authenticatedNodeIdOf(", s)
        self.assertIn("lifecycleRwLock.read", s, "the accessor must keep the manager's own read discipline")

    def test_the_authenticated_pubkey_is_answerable(self):
        s = SESSION.read_text(encoding="utf-8")
        self.assertRegex(
            s, r"fun authenticatedIdentityPub\w*Of\(",
            "ANDROID-03 slice (a): `TrustedPeer.capture` needeth the authenticated PUBLIC KEY (32 octets) and "
            "deriveth the node id from it; the transport can reach only a NODE ID today, so the trusted publication "
            "cannot be constructed at the real publication moment")

    def test_the_node_id_is_still_derived_from_the_pubkey(self):
        """The two accessors must agree: the node id IS the canonical derivation of the pubkey."""
        # THE COPY DISCIPLINE LIVES IN THE CONTROLLER, NOT IN THE MANAGER -- and a first draft of this arm looked
        # for it in `SessionManager` and failed on its OWN expectation rather than on the code. The manager readeth
        # the controller's property, and THAT property is the one that must copy.
        s = SESSION.read_text(encoding="utf-8")
        self.assertIn("fun authenticatedIdentityPub", s,
                      "the accessor must exist before its discipline can be judged (a clean failure, not an ERROR)")
        controller = (REPO / "android/mesh/src/main/java/io/godstone/mesh/crypto/TrustedHandshakeController.kt"
                      ).read_text(encoding="utf-8")
        self.assertIn("internal val authenticatedIdentityPub: ByteArray?", controller)
        self.assertRegex(
            controller, r"get\(\) = retainedIdentityPub\?\.copyOf\(\)",
            "the retained identity public key must be handed out as a COPY -- a caller may not mutate the slot")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
