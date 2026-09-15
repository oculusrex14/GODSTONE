"""IOS-01 (T13/T14/T16/T28) -- the OS cleanup must run on the CLOSING epoch's own managers.

The card's own step 1: "In `stopQuiesced`, capture the exact closing `ManagerContext` and an immutable array of its
connected peripherals BEFORE clearing ownership. Do not use [a live lookup]." And step 3: "Issue stopScan,
stopAdvertising, and cancelPeripheralConnection on `closing.central`/`closing.peripheral`, including only peripherals
owned by that context."

READ FROM THE CODE (round 235), AND THE DEFECT IS EXACT: `stopQuiesced()` clears ownership FIRST --
`activeManagerContext = nil` -- and the transport's `central`/`peripheral` are COMPUTED OPTIONAL PROPERTIES over the
CURRENT context (`private var central: CBCentralManager? { ... }`). SO `central?.stopScan()` (`:1413`),
`peripheral?.stopAdvertising()` (`:1414`) AND `central?.cancelPeripheralConnection(p)` (`:1419`) ARE ALL **NO-OPS**:
the references are gone before the OS is asked to do anything, which is the finding's own title -- 'stop loses manager
references before OS cleanup'. The CLOSING context still holdeth its own immutable `let central: CBCentralManager` and
`let peripheral: CBPeripheralManager`, so the cleanup CAN be done -- through `closing`, not through a live lookup.

WHY THIS ARM IS SOURCE-LEVEL: the repair redirects existing calls at a captured local, and a behavioural arm would
need a real CoreBluetooth manager (there is none in this environment -- never relabel a simulator or a fixture as a
device result). The behavioural half is OWED AND NAMED.
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


class IosStopUsesClosingContextTest(unittest.TestCase):
    """W00 -- the positive control: the computed properties and the context's own managers still exist."""

    def test_w00_the_live_properties_and_the_contexts_managers_exist(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertRegex(t, r"private var central: CBCentralManager\?")
        self.assertRegex(t, r"private var peripheral: CBPeripheralManager\?")
        self.assertIn("public let central: CBCentralManager", t)
        self.assertIn("public let peripheral: CBPeripheralManager", t)

    def test_the_cleanup_uses_the_closing_context(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        i = t.index("private func stopQuiesced()")
        body = t[i:i + 3200]
        self.assertRegex(
            body, r"closing\w*\.(central|peripheral)|closingContext",
            "IOS-01: `stopQuiesced` clearith ownership (`activeManagerContext = nil`) BEFORE the OS calls, and the "
            "transport's `central`/`peripheral` are computed properties over the CURRENT context -- so "
            "`central?.stopScan()`, `peripheral?.stopAdvertising()` and `central?.cancelPeripheralConnection(...)` "
            "are NO-OPS: the references are lost before the OS is asked to do anything")

    def test_the_connected_peripherals_are_captured_before_clearing(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        i = t.index("private func stopQuiesced()")
        body = t[i:i + 3200]
        self.assertRegex(
            body, r"let \w+ = .*connectedPeripherals|Array\(connectedPeripherals",
            "IOS-01 step 1: an IMMUTABLE ARRAY of the closing context's connected peripherals must be captured BEFORE "
            "ownership is cleared, so the cancellation cannot depend on a collection that is about to be emptied")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
