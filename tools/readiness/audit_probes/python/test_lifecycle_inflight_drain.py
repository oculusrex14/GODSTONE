"""ANDROID-05 (step 3) -- the REAL lifecycle seam must implement the bounded in-flight drain.

The audit's card, step 3: "Await bounded in-flight writer/session tasks to terminate before
completing the drain; use typed timeout/failure instead of reporting a constant successful sweep."

`TransportSeam.awaitInFlight(boundMillis): Int` existeth with a DEFAULT of 0, and its own KDoc sayeth
plainly: "The default answereth 0 -- a seam that owneth no such work -- so every existing implementer
stayeth source-compatible, **and the REAL adapter must override it**."

The REAL adapter (`LifecycleTransportAdapter`, the seam the runtime composition binds to the concrete
transports) DOES NOT OVERRIDE IT. So at the actual transport boundary the authority's drain always
observeth `inFlightOutstanding == 0`: in-flight writer and session work is INVISIBLE, a drain that
leaveth it running is indistinguishable from one that leaveth nothing behind, and the courts that
assert the drain's law are asserting it against FAKES that do override the method
(`ReadinessAndroid05Test.FakeSeam`, `ReadinessAndroid05bTest.FakeSeam`, `ReadinessT28Test.FakeSeam`)
-- never against the production seam.

WHY THIS ARM IS SOURCE-LEVEL: the repair addeth a capability the transport may offer
(`InFlightAwareTransport`), and an assertion about an interface that does not exist yet cannot compile.
The independent failing assertion is therefore the source-level one, run BEFORE the edit and kept
afterwards as the regression control, exactly as GS-SOS-001's issuance repair did. The BEHAVIOURAL
half (the adapter delegating to an in-flight-aware transport, and answering 0 for one that is not)
ships WITH the repair in `ReadinessAndroid05Test`.

It is NOT a device, emulator or radio result: it readeth production source text.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

def _repo_root() -> Path:
    """The repo root, found by SENTINEL rather than by a fixed depth: this file is RUN in the
    canonical suite and PARKED here between rounds, so a depth-relative root would silently
    resolve to the wrong tree after the move -- which it did, and the failure was caught by
    the W00 positive control the moment the probe was first run from its parked home."""
    here = Path(__file__).resolve()
    for candidate in [here.parent, *here.parents]:
        if (candidate / "ci" / "check_repository.py").exists():
            return candidate
    raise SystemExit("the repository root could not be located from " + str(here))


REPO = _repo_root()
ADAPTER = REPO / "android/mesh/src/main/java/io/godstone/mesh/transport/LifecycleTransportAdapter.kt"
SEAM = REPO / "android/mesh/src/main/java/io/godstone/mesh/identity/RuntimeLifecycle.kt"
BLE_TRANSPORT = REPO / "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt"


def _text(p: Path) -> str:
    return p.read_text(encoding="utf-8") if p.exists() else ""


class LifecycleInFlightDrainTest(unittest.TestCase):
    """W00 -- the seam still declares the method and the default is still 0 (positive control)."""

    def test_w00_the_seam_still_declares_the_bounded_await(self):
        seam = _text(SEAM)
        self.assertIn("fun awaitInFlight(boundMillis: Long): Int = 0", seam,
                      "the seam must still declare the bounded await with its compatible default")
        self.assertTrue(ADAPTER.exists(), "the real adapter must exist to be judged")

    def test_the_real_adapter_overrides_await_in_flight(self):
        """The production seam must OWN the bounded drain, not inherit the do-nothing default."""
        adapter = _text(ADAPTER)
        self.assertRegex(
            adapter, r"override\s+fun\s+awaitInFlight\s*\(",
            "LifecycleTransportAdapter does NOT override `awaitInFlight`: at the REAL transport "
            "boundary the drain always observeth 0 in-flight, so writers and sessions left running "
            "are invisible and a dirty drain looketh exactly as clean as a clean one")

    def test_the_real_adapter_delegates_to_an_in_flight_aware_transport(self):
        """A transport that CAN report its in-flight work must be asked; one that cannot answers 0."""
        adapter = _text(ADAPTER)
        self.assertIn("InFlightAwareTransport", adapter,
                      "the adapter must ask the transport through the capability, not guess")
        self.assertIn("as? InFlightAwareTransport", adapter,
                      "the capability is optional: a coarse transport answers 0 as before")

    def test_the_concrete_transport_can_report_its_in_flight_work(self):
        """The real radio must be able to answer, and must MEASURE rather than fabricate."""
        t = _text(BLE_TRANSPORT)
        self.assertIn("InFlightAwareTransport", t,
                      "BleTransport must implement the capability, or the adapter has nothing to ask")
        self.assertRegex(t, r"override\s+fun\s+awaitInFlight\s*\(",
                         "BleTransport must implement the bounded drain it alone can measure")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
