"""GS-STORE-005 (T33) slice 1 -- a store observer registration must be a DISPOSABLE LEASE.

The card's own words: "Extend the actual MessageStore observer API to return a disposable lease/token. Store registrations
by token under the existing owner; disposing twice [must be harmless]."

READ FROM THE CODE: `MessageStore.registerHeldSetObserver(observer: () -> Unit)` RETURNETH NOTHING, and the real store
merely ADDETH the closure to a `CopyOnWriteArrayList` -- `heldSetObservers.add(observer)` -- WITH NO REMOVAL PATH AT ALL.
So a registration cannot be withdrawn, EVER: a consumer that stops keepeth hearing, and a REPLACED one heareth tales meant
for its predecessor. THE ONE PRODUCTION REGISTRANT IS `LinkInfoSnapshotAuthority`, which registereth a closure and
retaineth no handle, so its own teardown cannot free it.

WHY THIS ARM IS SOURCE-LEVEL: the repair changeth the API's shape, and a behavioural arm of a lease that doth not exist
cannot compile. The behavioural half ships WITH the repair.
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
STORE = REPO / "android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt"
AUTH = REPO / "android/mesh/src/main/java/io/godstone/mesh/transport/LinkInfoSnapshotAuthority.kt"


class StoreObserverLeaseTest(unittest.TestCase):
    """W00 -- the positive control: the observer API and its one production registrant still exist."""

    def test_w00_the_api_and_its_registrant_still_exist(self):
        s = STORE.read_text(encoding="utf-8")
        self.assertIn("registerHeldSetObserver", s)
        self.assertIn("notifyHeldSetChanged", s)
        self.assertIn("registerHeldSetObserver", AUTH.read_text(encoding="utf-8"),
                      "the one production registrant must still stand")

    def test_registration_handeth_back_a_lease(self):
        s = STORE.read_text(encoding="utf-8")
        self.assertRegex(s, r"fun registerHeldSetObserver\(observer: \(\) -> Unit\): Int\b",
                         "GS-STORE-005: the registration must HAND BACK A LEASE -- today it returneth nothing and the "
                         "store keepeth the closure in a list with NO removal path")

    def test_the_store_can_dispose_by_lease(self):
        s = STORE.read_text(encoding="utf-8")
        self.assertRegex(s, r"fun disposeHeldSetObserver\(",
                         "a lease that cannot be disposed is not a lease")

    def test_the_registrant_retaineth_and_disposeth(self):
        a = AUTH.read_text(encoding="utf-8")
        self.assertRegex(a, r"val \w*[Ll]ease\w* = store\.registerHeldSetObserver",
                         "the production registrant must RETAIN the lease, or its own teardown cannot free the ear")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
