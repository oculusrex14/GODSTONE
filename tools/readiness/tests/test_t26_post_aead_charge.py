"""ANDROID-07 / T26 step 2 -- the POST-AEAD charge on the AUTHENTICATED identity.

The audit's card, step 2: "After AEAD, charge authenticated traffic against immutable full NodeID,
before full application payload decoding. Do not use MAC, hint, or claimed SOS to evade the global cap."

The transport's post-AEAD road is `BleTransport.received()`'s collector: `openWithResult` decideth, and
on `Authenticated` the plaintext travelleth to the application (`trySend`) or to the key-confirmation
door. NOTHING there is charged: the router's governor is the only authenticated-side budget, and it sits
DOWNSTREAM of the frame decode, on the CLAIMED sender and the CLAIMED priority -- so a peer can spend the
transport's own memory and CPU on authenticated ciphertext before any budget seeth it, and a claimed SOS
priority is what the router's bucket is chosen by.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth the charge and its counters, and a behavioural arm of a
counter that doth not exist cannot compile. It is written and RUN here (red by design), then MOVED into
`tools/readiness/tests/` when the charge landeth -- the same discipline as ANDROID-05's in-flight drain.

It is NOT a device, emulator or radio result: it readeth production source text.

**ROUND 278 -- THIS COURT WAS RED FROM ROUND 193 TO ROUND 278 (EIGHTY-FIVE ROUNDS) BECAUSE IT ASSERTED
ON A *NAME* RATHER THAN ON THE LAW.** It required the literal token `peerId` among the charge's
arguments; round 193's repair (`cf1bd15`) bound the identity first --
`val chargedIdentity = sessions?.authenticatedNodeIdOf(peerId) ?: peerId` -- WHICH SATISFIETH THE CARD
MORE STRONGLY, BY NAMING THE AUTHENTICATED LOOKUP ITSELF, and the court reddened ON THE RENAME. The
production law was never broken; the court was blind to it. A court that testeth a SPELLING reddeneth
when the code IMPROVETH and stayeth green when the spelling is kept and the law is broken.

So the judgment is now a PURE FUNCTION over source text (`charge_binding_problems`), and the court
carrieth FOUR NEGATIVE CASES that each land on their own clause of it -- because A NEGATIVE CASE IS THE
ONLY PROOF THAT A CHECK JUDGETH, and a witness that must be reconstructed by hand each time is not an
instrument.
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
BUDGET = REPO / "android/mesh/src/main/java/io/godstone/mesh/transport/AdmissionBudget.kt"


def charge_binding_problems(source: str) -> list[str]:
    """The card's law, as a judgment over source text: THE CHARGE ON THE AUTHENTICATED SCOPE MUST BE
    KEYED ON THE RELATION'S AUTHENTICATED IDENTITY, AND ON NOTHING THE PEER CAN CLAIM.

    Three clauses, each returning its own named problem so a witness can show WHICH one fired:
      1. the charged identity -- or the binding it carrieth its name from -- must come from an
         AUTHENTICATED-identity lookup;
      2. no claimed MAC, hint or SOS priority may choose the key, and the only admissible fallback is
         the CONNECTION'S OWN `peerId`;
      3. the charge must be the AUTHENTICATED scope, named as such.
    """
    problems: list[str] = []
    m = re.search(r"\w*[Aa]dmission\w*Budget\s*\.\s*chargeAuthenticated\((?P<args>[^)]*)\)", source)
    if m is None:
        return ["the post-AEAD charge must use the AUTHENTICATED scope, named as such, so that a claimed "
                "MAC, hint or SOS priority cannot choose its key or its bucket"]
    charged = m.group("args").split(",")[0].strip()

    # CLAUSE 1 -- where the charged identity cometh from.
    if re.search(r"authenticatedNodeId\w*\s*\(", charged):
        rhs = charged
    else:
        if charged == "peerId":
            problems.append("the charge is keyed directly on the CLAIMED handle: the card forbiddeth MAC, "
                            "hint and claimed-SOS keys, and the authenticated scope must be keyed on the "
                            "RELATION'S AUTHENTICATED identity")
            return problems
        binding = re.search(r"\bval\s+" + re.escape(charged) + r"\s*=\s*(?P<rhs>[^\n]*(?:\n\s*[.?:][^\n]*)*)",
                            source)
        if binding is None:
            problems.append("the charged identity %r must be BOUND in the source, so that this court can "
                            "judge WHERE it cometh from rather than merely that it hath a name" % charged)
            return problems
        rhs = binding.group("rhs")
    if not re.search(r"authenticatedNodeId\w*\s*\(", rhs):
        problems.append("the charged identity must be derived from the relation's AUTHENTICATED node id -- "
                        "%r is not, so the bucket is chosen by something the peer claimeth" % rhs.strip())
        return problems

    # CLAUSE 2 -- not a claim, and the only fallback is the connection's own peerId.
    if re.search(r"hint|claim|sos|priorit|\bmac\b", rhs.lower()):
        problems.append("a claimed MAC, hint or SOS priority may not choose the key: %r" % rhs.strip())
    for fallback in re.findall(r"\?:\s*([A-Za-z_][A-Za-z0-9_]*)", rhs):
        if fallback != "peerId":
            problems.append("the ONLY admissible fallback is the connection's own `peerId`; %r is a source "
                            "the peer can claim, which is what the authenticated identity was meant to "
                            "replace" % fallback)
    return problems


class T26PostAeadChargeTest(unittest.TestCase):
    """W00 -- the positive control: the POST-AEAD road still exists to be charged."""

    def test_w00_the_post_aead_road_still_exists(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("CryptoOpenResult.Authenticated", t,
                      "the collector must still have an Authenticated arm to judge")
        self.assertRegex(t, r"openWithResult\(\s*[A-Za-z_][\w.?]*\(?[^,)]*\)?,?\s*record\.payload\)",
                         "the collector must still decrypt through the registry")
        self.assertTrue(BUDGET.exists(), "the admission budget must exist to be extended")

    def test_the_authenticated_traffic_is_charged_before_the_plaintext_leaves(self):
        """The charge must sit BETWEEN authentication and the application hand-off."""
        t = TRANSPORT.read_text(encoding="utf-8")
        # the authenticated arm of the collector, from `Authenticated` to the trySend
        m = re.search(r"Authenticated\s*->\s*\{(?P<body>.*?)trySend\(peerId to outcome\.plaintext\)",
                      t, re.DOTALL)
        self.assertIsNotNone(m, "the collector's Authenticated arm must still hand the plaintext on")
        body = m.group("body")
        self.assertRegex(
            body, r"\w*[Aa]dmission\w*Budget\s*\.\s*charge",
            "authenticated traffic is charged NOTHING between authentication and the application: the "
            "router's governor is downstream of the frame decode and keyed on the CLAIMED sender and "
            "priority, so authenticated ciphertext spendeth the transport's memory and CPU before any "
            "budget seeth it")

    def test_the_charge_is_keyed_on_the_authenticated_identity_not_a_claimed_handle(self):
        """The card forbiddeth MAC, hint and claimed-SOS keys for this scope (see the module docstring
        for the eighty-five-round red this court carried)."""
        problems = charge_binding_problems(TRANSPORT.read_text(encoding="utf-8"))
        self.assertEqual([], problems, "the production charge violateth the card: " + " | ".join(problems))


class T26BindingNegativeCasesTest(unittest.TestCase):
    """THE WITNESSES THAT THE JUDGMENT JUDGETH: one valid positive control and four negatives, each of
    which must land on its OWN clause. A check whose negatives were reconstructed by hand once, in a
    script that nobody kept, doth not carrieth its own proof."""

    def _source(self) -> str:
        return TRANSPORT.read_text(encoding="utf-8")

    BINDING = ("val chargedIdentity = element.admission\n"
               "                                ?.let { sessions?.authenticatedNodeIdOf(it) } ?: peerId")
    CALL = "chargedIdentity, outcome.plaintext.size"

    def _patched(self, old: str, new: str) -> str:
        t = self._source()
        self.assertIn(old, t, "the anchor this witness patcheth is not in the file: " + old)
        patched = t.replace(old, new)
        # THE EIGHTH SPECIES, GUARDED: a replacement that changed nothing would make a negative case
        # "pass" while proving nothing at all.
        self.assertNotEqual(t, patched, "THE REPLACEMENT CHANGED NOTHING (round 278's eighth species)")
        return patched

    def test_w00_the_real_source_is_a_valid_positive_control(self):
        self.assertEqual([], charge_binding_problems(self._source()),
                         "the positive control must be clean, or every negative below prove nothing")

    def test_the_round_188_spelling_is_no_longer_accepted(self):
        """THE PROOF THAT THIS COURT NOW JUDGETH THE LAW RATHER THAN THE NAME: the shape the round-188
        court demanded -- a bare `peerId` argument -- is itself a VIOLATION."""
        problems = charge_binding_problems(self._patched(self.CALL, "peerId, outcome.plaintext.size"))
        self.assertTrue(problems, "keying the charge directly on the claimed handle MUST be refused")
        self.assertIn("CLAIMED handle", " | ".join(problems))

    def test_a_binding_from_a_claimed_hint_is_refused(self):
        problems = charge_binding_problems(self._patched(self.BINDING, "val chargedIdentity = hintFromPayload ?: peerId"))
        self.assertTrue(problems, "a charge bound from a claimed hint MUST be refused")

    def test_a_fallback_that_is_not_the_connections_own_peer_id_is_refused(self):
        problems = charge_binding_problems(self._patched(
            self.BINDING, "val chargedIdentity = sessions?.authenticatedNodeIdOf(admissionKey) ?: otherPeer"))
        self.assertTrue(problems, "a fallback to anything but the connection's own peerId MUST be refused")
        self.assertIn("admissible fallback", " | ".join(problems))

    def test_a_fallback_to_a_claimed_sos_handle_is_refused(self):
        problems = charge_binding_problems(self._patched(
            self.BINDING, "val chargedIdentity = sessions?.authenticatedNodeIdOf(admissionKey) ?: claimedSosHandle"))
        self.assertTrue(problems, "a claimed SOS handle may not choose the key")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
