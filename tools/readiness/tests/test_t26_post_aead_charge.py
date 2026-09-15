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


class T26PostAeadChargeTest(unittest.TestCase):
    """W00 -- the positive control: the POST-AEAD road still exists to be charged."""

    def test_w00_the_post_aead_road_still_exists(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("CryptoOpenResult.Authenticated", t,
                      "the collector must still have an Authenticated arm to judge")
        self.assertIn("openWithResult(peerId, record.payload)", t,
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
        """The card forbiddeth MAC, hint and claimed-SOS keys for this scope."""
        t = TRANSPORT.read_text(encoding="utf-8")
        m = re.search(r"\w*[Aa]dmission\w*Budget\s*\.\s*chargeAuthenticated\((?P<args>[^)]*)\)", t)
        self.assertIsNotNone(
            m, "the post-AEAD charge must use the AUTHENTICATED scope, named as such, so that a claimed "
               "MAC, hint or SOS priority cannot choose its key or its bucket")
        self.assertIn("peerId", m.group("args"),
                      "the authenticated scope must be keyed on the RELATION'S AUTHENTICATED identity")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
