#! /usr/bin/env python3
"""GS-STORE-001 -- the T29 court must prove what it CLAIMETH, or say what it cannot prove.

The audit's charge, verbatim: "ReadinessT29 uses FakeOpener/TestHandle booleans and FakeBinding, and
runAtomic mutates a MutableList. It neither creates encrypted database files nor performs the real store
transaction. The test comment moves actual native proof to T73-T75, contrary to T29 required design and
completion requirements."

TWO ARMS, and BOTH are RED on today's tree -- the finding's behavioural red. It liveth OUTSIDE the
module's test source set (a red arm inside `:mesh` would redden the lane), and the repair MOVETH it into
the canonical lane.

The FIRST version of this probe stripped comments from both arms and PASSED -- blind to the very limb the
audit quoted ("The test COMMENT moves actual native proof to T73-T75"). Arm B therefore readeth the
COMMENTS ON PURPOSE, and neither arm may be "fixed" by stripping what it examineth.
"""
from __future__ import annotations

import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))
COURT = os.path.join(ROOT, "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT29Test.kt")


def court_text() -> str:
    with open(COURT, encoding="utf-8") as stream:
        return stream.read()


def code_only(text: str) -> str:
    without_block = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return "\n".join(line.split("//")[0] for line in without_block.splitlines())


class StoreEvidenceTest(unittest.TestCase):

    def test_a_the_native_seam_is_not_a_stub_in_this_court(self):
        """The court must not PROVE the classifier by stubbing the native seam itself."""
        code = code_only(court_text())
        stubbed = re.search(r"override\s+fun\s+openEncrypted\([^)]*\)\s*(?::[^=]*)?=\s*\w+\(\)", code)
        self.assertIsNone(
            stubbed,
            "T29 stubbeth the NATIVE opener (`openEncrypted(...) = facts()`): the court proveth its "
            "classifier against bytes it invented rather than against the store (GS-STORE-001)")

    def test_b_the_native_proof_is_not_deferred_in_a_comment(self):
        """A court may NAME an external lane -- it may not present the deferral as its own proof."""
        deferral = re.search(r"T7[3-5]", court_text())          # the COMMENTS are read on purpose
        self.assertIsNone(
            deferral,
            "T29 deferreth its native proof to T73-T75 in its own words: the audit calleth that "
            "contrary to T29's required design (GS-STORE-001)")


if __name__ == "__main__":
    unittest.main(verbosity=2)
