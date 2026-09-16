"""IOS-04 (T24) step 4 -- readiness must be KEYED BY THE FULL RELATION TOKEN, not a bare handle.

The card's own words: "Key readiness by the full relation token, not UUID. Remove that relation on disconnect and all
owned relations on stop."

READ FROM THE CODE: readiness lived in a bare `linkReadyPublished: [UUID]`, so a UUID returning with a NEW generation
could ALIAS a previous relation's readiness -- the last piece of the finding's own phrase, "stale UUID readiness".
The store now carrieth the relation BESIDE the handle, and the duplicate guard asketh the RELATION rather than merely
the handle.

HONESTY ABOUT THIS ARM'S PLACE IN THE ORDER, STATED RATHER THAN GLOSSED: the production edit was made BEFORE this arm
was written, so it is a REGRESSION CONTROL and NOT a red-proven repair. The reason is stated plainly: the change is
BEHAVIOUR-PRESERVING for every path a court can drive today (the new behaviour showeth itself only when a handle is
REUSED with a new generation, which needs a fresh handshake), so no failing assertion could have been written against
the old code without inventing a fixture the isle cannot produce. The finding's OTHER half -- the entry dying with the
relation -- WAS red-proven at round 245 and is witnessed in the T23 court.
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


class IosReadinessTokenKeyedTest(unittest.TestCase):
    """W00 -- the positive control: the readiness seam and its uses still exist."""

    def test_w00_the_readiness_seam_still_exists(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertIn("internal func linkReadyPeersForTest() -> [UUID]", t)
        self.assertIn("func publishApplicationLinkReadyOnce(", t)

    def test_the_store_carrieth_the_relation_beside_the_handle(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertRegex(
            t, r"private var linkReadyRelations: \[\(peerId: UUID, relation: RelationKey\?\)\]",
            "IOS-04 step 4: readiness must be KEYED BY THE FULL RELATION TOKEN, or a UUID returning with a new "
            "generation aliaseth a previous relation's readiness")

    def test_no_bare_handle_store_remaineth(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        self.assertNotIn("linkReadyPublished", t,
                         "the bare `[UUID]` store must be gone, not shadowed")

    def test_the_duplicate_guard_asketh_the_relation(self):
        t = TRANSPORT.read_text(encoding="utf-8")
        i = t.index("linkReadyRelations.contains(where:")
        window = t[i:i + 220]
        self.assertIn("entry.relation", window,
                      "the duplicate guard must compare the RELATION, not merely the handle")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
