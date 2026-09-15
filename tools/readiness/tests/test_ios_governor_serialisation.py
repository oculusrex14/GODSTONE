"""IOS-05 / T27 step 5 -- the iOS governor's Trust mutations must be SERIALISED.

The audit's card, step 5, in its own words: "Serialize the Trust record mutations too: `reward`/`penalise`
currently mutate shared reference fields after releasing `registryLock` (150-174); wiring concurrent
callers ...".

READ FROM THE CODE, not from the card: `mutableTrust(_:)` taketh `registryLock`, readeth the `Trust`
reference, and RELEASETH the lock (:89-95); `reward` (:151-155) and `penalise` (:162-174) then mutate that
SHARED REFERENCE's fields (`score`, `strikes`, `refuseUntilMillis`) with NO lock held. Two concurrent
callers therefore race on the same record -- and a lost `strikes` increment or a lost `refuseUntilMillis`
extension is exactly the kind of update a backoff law may not lose.

WHY THIS ARM IS SOURCE-LEVEL: the mutation is inside a method whose lock is not part of its public surface,
so a deterministic behavioural proof would need a seam the repair addeth (the serialised form makes the
lock observable by BLOCKING). The independent failing assertion is therefore the source-level one, run
BEFORE the edit and kept afterwards as the regression control; the BEHAVIOURAL half ships WITH the repair
in the T27 court, where the serialised order giveth a DETERMINISTIC final score.

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
GOV = REPO / "ios/Godstone/Sources/GodstoneMesh/PeerGovernor.swift"
ANDROID_GOV = REPO / "android/mesh/src/main/java/io/godstone/mesh/abuse/PeerGovernor.kt"


class IosGovernorSerialisationTest(unittest.TestCase):
    """W00 -- the positive control: the governor and its two mutators still exist to be judged."""

    def test_w00_the_mutators_and_the_registry_lock_still_exist(self):
        g = GOV.read_text(encoding="utf-8")
        self.assertIn("func reward(", g)
        self.assertIn("func penalise(", g)
        self.assertIn("registryLock", g)
        self.assertTrue(ANDROID_GOV.exists(),
                        "the android twin must exist: T27 is T26's isle-mate")

    def test_the_trust_mutations_happen_under_the_registry_lock(self):
        g = GOV.read_text(encoding="utf-8")
        for name in ("reward", "penalise"):
            m = re.search(r"public\s+func\s+" + name + r"\((?P<sig>[^)]*)\)\s*\{(?P<body>.*?)\n    \}",
                          g, re.DOTALL)
            self.assertIsNotNone(m, "the mutator " + name + " must still exist")
            body = m.group("body")
            self.assertRegex(
                body, r"registryLock\s*\.\s*lock\(\)",
                "IOS-05 / T27 step 5: `" + name + "` mutateth the SHARED Trust reference's fields WITHOUT "
                "holding `registryLock` -- `mutableTrust` releaseth it before returning -- so two concurrent "
                "callers race on one record and a lost `strikes` increment or a lost `refuseUntilMillis` "
                "extension is unnameable afterwards")

    def test_the_locked_lookup_does_not_re_enter_the_non_recursive_lock(self):
        """The repair must add a lock-HELD lookup: NSLock is not recursive, so calling the locking
        `mutableTrust` while already holding the lock would DEADLOCK rather than fix anything."""
        g = GOV.read_text(encoding="utf-8")
        self.assertTrue(
            re.search(r"func\s+mutableTrustLocked\s*\(", g) is not None,
            "the repair must provide a lock-HELD variant (`mutableTrustLocked`) so that the mutators can "
            "hold `registryLock` without re-entering it -- the lock is an NSLock, not a recursive one")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
