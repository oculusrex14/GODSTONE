"""GS-SOS-001 (second defect) -- the issuance bypass in the signed-SOS author.

The audit's local-identity control (`ci/check_local_identity_controls.py`, section 29 /
"outbound issuance bypass") refuseth a production file that constructs an
`IdentityBindingV1` outside the AUTHORITY files. On the audited tree it reporteth two
errors -- `SignedSosV1.kt` and `SignedSosV1.swift` -- because both `author(...)`
functions STRIKE THE BINDING THEMSELVES from the raw key material they are handed.

WHY THIS SUITE CARRIETH THE ASSERTION AND NOT ONLY THE CONTROL. The repair is an
OWNER-CONTRACT change (round 134: no authority is in scope at either `author(...)`, so
the CALLER must be given the issued binding to pass down). A behavioural arm of the new
law CANNOT COMPILE against the audited tree -- the API it must exercise does not exist
yet -- so the independent failing assertion for this defect is necessarily the
SOURCE-LEVEL one, run BEFORE the edit and kept afterwards as the regression control.
The behavioural half (a bound-less authority refuseth, and the authored frame carrieth
the binding the authority issued) ships WITH the repair in the SOS court
(`ReadinessT38Test` / `ReadinessT38Tests`) and is not claimed here.

This file liveth in the CANONICAL readiness suite because the arms are GREEN once the
repair landeth -- a red-by-design probe would belong in `tools/readiness/audit_probes/`.

It is NOT a device, radio or runtime result: it readeth production source text.
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
ANDROID_MESH = REPO / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh"
IOS_MESH = REPO / "ios" / "Godstone" / "Sources" / "GodstoneMesh"

# The SAME exclusion lists the repository control useth: the AUTHORITY files are the
# legitimate owners of an issuance, and only they may strike a binding.
ANDROID_AUTHORITY_FILES = {
    "Identity.kt",
    "IdentityBindingV1.kt",
    "LocalIdentityStateV1.kt",
    "Ed25519Keys.kt",
    "X25519Keys.kt",
}
IOS_AUTHORITY_FILES = {"MeshIdentity.swift", "IdentityBindingV1.swift", "LocalIdentityStateV1.swift"}

ANDROID_AUTHOR = ANDROID_MESH / "wire" / "v2" / "SignedSosV1.kt"
IOS_AUTHOR = IOS_MESH / "SignedSosV1.swift"


def _files(root: Path, suffix: str):
    if not root.exists():  # pragma: no cover -- a missing isle is a visible skip, never a pass
        return []
    return sorted(p for p in root.rglob("*" + suffix) if p.is_file())


def android_issuance_offenders() -> list[str]:
    out = []
    for f in _files(ANDROID_MESH, ".kt"):
        if f.name in ANDROID_AUTHORITY_FILES:
            continue
        text = f.read_text(encoding="utf-8")
        if "IdentityBindingV1.create(" in text or "IdentityBindingV1(" in text:
            out.append(f.name)
    return out


def ios_issuance_offenders() -> list[str]:
    out = []
    for f in _files(IOS_MESH, ".swift"):
        if f.name in IOS_AUTHORITY_FILES:
            continue
        text = f.read_text(encoding="utf-8")
        if re.search(r"\bIdentityBindingV1\s*\(", text):
            out.append(f.name)
    return out


def _declares_binding_parameter(path: Path, signature_pattern: str) -> bool:
    """True when the author function TAKETH an issued binding.

    The parameter's TYPE spelling is checked in both languages (`binding:
    IdentityBindingV1` -- Kotlin's trailing comma and Swift's label agree on this
    spelling) so that a later edit cannot quietly swap it for a re-derivation.
    """
    if not path.exists():  # pragma: no cover
        return False
    text = path.read_text(encoding="utf-8")
    m = re.search(signature_pattern, text)
    if not m:
        return False
    params = m.group(1)
    return re.search(r"binding\s*:\s*(io\.godstone\.mesh\.identity\.)?IdentityBindingV1", params) is not None


class LocalIdentityIssuanceTest(unittest.TestCase):
    """W00 -- the scan really readeth the tree, and the law hath a legitimate owner."""

    def test_w00_the_authority_files_still_issue_the_binding(self):
        """POSITIVE CONTROL: the exclusion list is not a way to hide the law. The
        authority files DO strike bindings, so a scan that found NOTHING anywhere
        would prove only that the scanner is broken."""
        android_owner = (ANDROID_MESH / "identity" / "Identity.kt").read_text(encoding="utf-8")
        ios_owner = IOS_MESH / "MeshIdentity.swift"
        self.assertIn("IdentityBindingV1.create(", android_owner,
                      "the Android authority must still be the issuing owner")
        self.assertIn("issueIdentityBinding", ios_owner.read_text(encoding="utf-8"),
                      "the iOS authority must still carry its issuing API")
        self.assertTrue(_files(ANDROID_MESH, ".kt"), "the scan must have found Android sources")
        self.assertTrue(_files(IOS_MESH, ".swift"), "the scan must have found iOS sources")

    def test_the_android_signed_sos_author_takes_the_issued_binding_and_issues_none(self):
        """The Android author must OBTAIN the binding, never strike one: its `binding`
        parameter is the only road, and no construction may survive in that file."""
        self.assertEqual(
            [], [n for n in android_issuance_offenders() if n == "SignedSosV1.kt"],
            "SignedSosV1.kt still constructs an IdentityBindingV1: an authority that "
            "holdeth the binding is bypassed by the sender's own re-derivation")
        self.assertTrue(
            _declares_binding_parameter(ANDROID_AUTHOR, r"fun author\(([^)]*)\)"),
            "SignedSosV1.author() must take the ISSUED binding as a parameter")




    def test_the_ios_signed_sos_author_takes_the_issued_binding_and_issues_none(self):
        """GS-SOS-001's second defect on the iOS isle, landed in round 164. Kept as its own arm
        so that each isle's repair can carry its own red and its own green."""
        self.assertEqual(
            [], [n for n in ios_issuance_offenders() if n == "SignedSosV1.swift"],
            "SignedSosV1.swift still constructs an IdentityBindingV1: an authority that "
            "holdeth the binding is bypassed by the sender's own re-derivation")
        self.assertTrue(
            _declares_binding_parameter(
                IOS_AUTHOR, r"static func author\(([\s\S]*?)\)\s*(?:throws)?\s*->"),
            "SignedSosV1.author() must take the ISSUED binding as a parameter")

if __name__ == "__main__":  # pragma: no cover
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
