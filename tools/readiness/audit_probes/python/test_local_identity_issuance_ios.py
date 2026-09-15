"""GS-SOS-001 (second defect) -- the iOS HALF of the issuance bypass: THE PARKED RED.

RED BY DESIGN, and parked OUTSIDE the canonical suite for the reason this directory
existeth: `tools/readiness/tests/` is a GREEN lane, and the iOS repair landeth on its
own commit (each isle's repair must leave its own lane green). The Android twin already
MOVED INTO `tools/readiness/tests/test_local_identity_issuance.py`, and its arm passeth
there.

WHEN THE iOS REPAIR LANDETH, THIS ARM MOVES IN BESIDE ITS TWIN (the same rule every other
probe here followeth) and this file is deleted.

Run it with:

    python3 -m unittest tools.readiness.audit_probes.python.test_local_identity_issuance_ios

The scan and the signature check are IMPORTED from the canonical module, so there is one
implementation of the law and no second copy to drift.
"""
from __future__ import annotations

import unittest

from tools.readiness.tests.test_local_identity_issuance import (
    IOS_AUTHOR,
    _declares_binding_parameter,
    ios_issuance_offenders,
)


class IosIssuanceProbe(unittest.TestCase):
    """The iOS author must OBTAIN the issued binding, never strike one of its own."""

    def test_the_ios_signed_sos_author_takes_the_issued_binding_and_issues_none(self):
        self.assertEqual(
            [], [n for n in ios_issuance_offenders() if n == "SignedSosV1.swift"],
            "SignedSosV1.swift still constructs an IdentityBindingV1: an authority that "
            "holdeth the binding is bypassed by the sender's own re-derivation")
        self.assertTrue(
            _declares_binding_parameter(
                IOS_AUTHOR, r"static func author\(([\s\S]*?)\)\s*(?:throws)?\s*->"),
            "SignedSosV1.author() must take the ISSUED binding as a parameter")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
