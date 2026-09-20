"""*** THE iOS LANE DIGEST MUST COVER THE RIG AND THE FIXTURE BYTES, NOT ONLY `*.swift`. ***

*MEASURED GAP, found by reading `ci/check_lane_results.py` rather than trusting it: `_ios_source_digest` walked only
`*.swift` under the four source trees. **`ios/project.yml` WAS NOT DIGESTED AT ALL** -- and that file is precisely
what decides which target and scheme get compiled and executed. So registering OR REMOVING
`GodstoneArchiveUITests`/`GodstoneArchiveUI` there left an existing lane log reading "current" -- **a green log that
could not date itself against the configuration that produced it**, which is this control's own Phase-5 clause about
no required test being omitted by target configuration.*

*The committed fixture bytes were outside the digest for the same reason (they are not `.swift`). The executed app
witness verifies the fixture's sha256 at RUN time, so tampering fails the ARM -- but the LANE LOG'S green was not
bound to the bytes it claimed to have verified.*

**THESE TESTS FAIL ON THE OLD SCOPE AND PASS ON THE NEW ONE**, which is what makes them a control rather than a
comment. Each asserts the digest MOVES when one thing changes and HOLDS when nothing does.
"""

from __future__ import annotations

import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
CONTROL = REPO / "ci" / "check_lane_results.py"


def _load():
    spec = importlib.util.spec_from_file_location("check_lane_results_under_test", CONTROL)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class IOSLaneDigestScope(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = _load()
        self.baseline = self.mod._ios_source_digest()

    def test_the_digest_is_stable_when_nothing_changes(self) -> None:
        """A digest that moved on every call would invalidate every log and be useless."""
        self.assertEqual(self.baseline, self.mod._ios_source_digest())

    def test_the_rig_file_is_digested(self) -> None:
        """*** THE MEASURED GAP. *** *`ios/project.yml` decides which targets the lane compiles and runs.*"""
        self.assertIn(
            "ios/project.yml",
            self.mod.IOS_RIG_FILES,
            "the project spec MUST be in the digested rig set -- it selects the targets and schemes that run, so a "
            "log that ignores it cannot tell whether the configuration it was produced under still holds",
        )
        rig = REPO / "ios" / "project.yml"
        self.assertTrue(rig.is_file(), "the rig file the control names must exist")
        original = rig.read_bytes()
        try:
            # A change that touches NO `.swift` byte: this is exactly the blind spot.
            rig.write_bytes(original + b"\n# digest-scope probe\n")
            moved = self.mod._ios_source_digest()
        finally:
            rig.write_bytes(original)
        self.assertNotEqual(
            moved, self.baseline,
            "*** A RIG-ONLY CHANGE MUST MOVE THE DIGEST. If it does not, a target can be added to or removed from the "
            "lane and every existing log still reads current -- the configuration blind spot this control exists to "
            "close. ***",
        )
        self.assertEqual(self.baseline, self.mod._ios_source_digest(), "and restoring must restore the digest")

    def test_the_fixture_bytes_are_digested(self) -> None:
        """*** The bytes the executed app witness verifies at run time must also date the log. ***"""
        tree = REPO / "ios" / "Godstone" / "Tests" / "GodstoneArchiveUITests" / "Fixtures"
        self.assertTrue(
            tree.is_dir(),
            "the committed fixture tree must exist, or the executed app witness cannot run at all",
        )
        fixture = tree / "archive_light.db"
        self.assertTrue(fixture.is_file(), "the committed fixture must exist")
        original = fixture.read_bytes()
        try:
            flipped = bytearray(original)
            flipped[-1] ^= 0xFF
            fixture.write_bytes(bytes(flipped))
            moved = self.mod._ios_source_digest()
        finally:
            fixture.write_bytes(original)
        self.assertNotEqual(
            moved, self.baseline,
            "*** A FIXTURE-BYTE CHANGE MUST MOVE THE DIGEST. The witness verifies the fixture's sha at run time, so a "
            "tampered fixture fails the ARM -- but without this the lane LOG would still read green while describing "
            "bytes it no longer matches. ***",
        )
        self.assertEqual(self.baseline, self.mod._ios_source_digest())

    def test_a_swift_change_still_moves_the_digest(self) -> None:
        """The original coverage must survive the widening -- a regression here would be silent."""
        target = next(
            (REPO / "ios" / "Godstone" / "Tests").rglob("*.swift"), None,
        )
        self.assertIsNotNone(target, "expected at least one iOS test source")
        original = target.read_bytes()
        try:
            target.write_bytes(original + b"\n// digest-scope probe\n")
            moved = self.mod._ios_source_digest()
        finally:
            target.write_bytes(original)
        self.assertNotEqual(moved, self.baseline, "a `.swift` change must still be caught")
        self.assertEqual(self.baseline, self.mod._ios_source_digest())


if __name__ == "__main__":
    unittest.main()
