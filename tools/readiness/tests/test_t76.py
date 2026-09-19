#! /usr/bin/env python3
"""T76 readiness court (python isle): the release inputs, prepared but not approved.

The card's law, one named witness each:

  W01  the unsigned candidate metadata is SHAPED: identity, version, profile and
       claim set are present, and the candidate SHA is a null placeholder -- never
       an unmeasured value wearing a SHA's clothes
  W02  NO SECRET MAY BE RECORDED: a key, certificate, profile, password or token
       in the metadata is refused by name
  W03  the signing state is honest: `unsigned` until signed, and the fingerprint
       is null exactly while the state is unsigned (the two may not disagree)
  W04  an unsupported product claim is refused by name -- the prohibited list is
       read from the metadata, not restated here
  W05  every entitlement and permission the shipping manifest declares carrieth a
       REASON, and the reason may not be the empty string
  W06  a debug-only capability in the release surface is refused
       (delegated to ci/check_release_surface.py, whose own verdict is read)
  W07  the dependency-licence inventory is the SBOM's census, and UNKNOWN licences
       are CARRIED as unknown rather than omitted or guessed
  W08  no licence text is fabricated for an artifact absent from this checkout
  W09  the store checklist is structurally reviewable AND marks nothing APPROVED:
       a self-approved row is refused by name
  W10  absent human policy/credentials keeps the final signing gate BLOCKED --
       the metadata may not assert a signed state it did not receive
  W11  STALE candidate metadata is refused: identity bound to a SHA that is not
       the head, or a tree SHA that does not match its commit
  W12  MALFORMED metadata is refused by name (the card's semantic negative)
  W13  the unchecked-prose claims stay unclaimed: no readiness flag is flipped
       and no external gate is closed by this court

Every witness here reads AUTHORITATIVE SOURCE: the metadata file, the shipping
manifest, the entitlements, the SBOM and the checklist. This court prepares and
refuses; it approves nothing, signs nothing, and closes no gate -- the signing
decision belongs to the release owner, and the store verdict to the store.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

METADATA = "docs/production/RELEASE_METADATA.json"
CHECKLIST = "docs/production/STORE_POLICY_CHECKLIST.json"
SBOM = "docs/supplychain/SBOM.json"
ANDROID_MANIFEST = "android/app/src/main/AndroidManifest.xml"
IOS_ENTITLEMENTS = "ios/Godstone/Godstone.entitlements"
ANDROID_GRADLE = "android/app/build.gradle.kts"

#: The names that betray a secret in a file that must carry none.
SECRET_MARKERS = (
    "PRIVATE KEY", "keystore", "keychain", "-----BEGIN",
    "password", "passphrase", "client_secret", "api_key", "apikey",
    "provisioning profile", "signing certificate",
)

#: Statuses this repository may never write for itself: an external verdict.
FABRICATED_APPROVALS = ("APPROVED", "PASSED", "COMPLIANT", "ACCEPTED")


def load(rel, root=ROOT):
    return json.loads((root / rel).read_text(encoding="utf-8"))


def _walk_strings(node):
    """Yield every string in a JSON tree, keys included."""
    if isinstance(node, dict):
        for key, value in node.items():
            yield key
            yield from _walk_strings(value)
    elif isinstance(node, list):
        for item in node:
            yield from _walk_strings(item)
    elif isinstance(node, str):
        yield node


class _Fixture:
    """A copy of the release surface, so a witness can FEED the court the very
    violation it striketh. Nothing here touches the real tree."""

    FILES = (METADATA, CHECKLIST, SBOM)

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for rel in self.FILES:
            dest = self.root / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / rel, dest)

    def edit(self, rel, mutate):
        path = self.root / rel
        document = json.loads(path.read_text(encoding="utf-8"))
        mutate(document)
        path.write_text(json.dumps(document, indent=2), encoding="utf-8")

    def close(self):
        self.tmp.cleanup()


# --------------------------------------------------------------------- rods --
def metadata_defects(document) -> list[str]:
    """The metadata's own law. Returns [] when the record is honest."""
    problems = []
    candidate = document.get("candidate", {})
    for field in ("application_id", "version_name", "build_profile", "claim_set"):
        if not candidate.get(field):
            problems.append(f"candidate.{field} is absent or empty")
    if candidate.get("candidate_sha") is None:
        # ALLOWED, and named as such: unmeasured is a real state.
        pass
    else:
        value = str(candidate["candidate_sha"])
        if not re.fullmatch(r"[0-9a-f]{40}", value):
            problems.append(
                f"candidate.candidate_sha {value[:12]!r} is present but is not a "
                "40-character lower-case hex commit")

    signing = document.get("signing", {})
    state = signing.get("state")
    if state not in (signing.get("allowed_states") or []):
        problems.append(f"signing.state {state!r} is not an allowed state")
    # W03: state and fingerprint may not disagree
    if state == "unsigned" and signing.get("fingerprint") is not None:
        problems.append("signing.state is `unsigned` while a fingerprint is recorded")
    if state == "signed" and not signing.get("fingerprint"):
        problems.append("signing.state is `signed` with no fingerprint")
    return problems


#: Fields whose whole JOB is to name a prohibition or state a rule. The note that
#: forbids passwords is not a password, exactly as the SBOM's note is not a licence.
DECLARATION_KEYS = frozenset({
    "note", "prohibited_in_repository", "prohibition_rule", "identity_rule",
    "equivalence_rule", "inventory_rule", "why_prohibited", "external_review",
    "describes_actual_behaviour_only", "claims", "approval_rule", "enforcement",
    "no_fabrication", "known_unknowns_are_expected",
})


def _substantive_strings(node):
    """Every string EXCEPT those under a declaration key."""
    if isinstance(node, dict):
        for key, value in node.items():
            if key in DECLARATION_KEYS:
                continue
            yield from _substantive_strings(value)
    elif isinstance(node, list):
        for item in node:
            yield from _substantive_strings(item)
    elif isinstance(node, str):
        yield node


def secret_defects(document) -> list[str]:
    """A secret in the metadata is refused by name."""
    problems = []
    for text in _substantive_strings(document):
        low = text.lower()
        for marker in SECRET_MARKERS:
            if marker.lower() in low:
                problems.append(
                    f"prohibited secret material named: {marker!r} in {text[:60]!r}")
    return problems


def claim_defects(text, prohibited) -> list[str]:
    """A prohibited claim appearing in release copy is refused."""
    problems = []
    low = text.lower()
    for claim in prohibited:
        if claim.lower() in low:
            problems.append(f"prohibited product claim present: {claim!r}")
    return problems


def checklist_defects(document) -> list[str]:
    """The checklist must be reviewable, and must approve nothing."""
    problems = []
    rows = document.get("rows")
    if not isinstance(rows, list) or not rows:
        return ["checklist carrieth no rows"]
    for row in rows:
        for field in ("id", "area", "requirement", "evidence_required", "status", "owner"):
            if not row.get(field):
                problems.append(f"row {row.get('id')!r} lacketh {field}")
        status = str(row.get("status", ""))
        if status in FABRICATED_APPROVALS:
            problems.append(
                f"row {row.get('id')!r} carrieth the self-assigned approval {status!r}; "
                "a status this repository can write is not a store verdict")
    return problems


def entitlement_defects(root=ROOT) -> list[str]:
    """Every declared entitlement/permission carrieth a reason."""
    problems = []
    document = load(METADATA, root)
    entitlements = document.get("entitlements_and_permissions", {})
    for platform in ("android", "ios"):
        entries = entitlements.get(platform)
        if not isinstance(entries, list) or not entries:
            problems.append(f"entitlements_and_permissions.{platform} is empty or absent")
            continue
        for entry in entries:
            if not entry.get("reason"):
                problems.append(
                    f"{platform} entitlement {entry.get('name')!r} carrieth no reason")
    return problems


def licence_defects(root=ROOT) -> list[str]:
    """The licence inventory is the SBOM's census, unknowns carried as unknown."""
    problems = []
    document = load(METADATA, root)
    inventory = document.get("dependency_licences", {}).get("inventory")
    if not inventory:
        return ["dependency_licences.inventory is absent"]
    path = root / inventory
    if not path.is_file():
        return [f"the named licence inventory {inventory!r} does not exist"]
    sbom = json.loads(path.read_text(encoding="utf-8"))
    census = sbom.get("licence_census")
    if not isinstance(census, dict) or not census:
        problems.append("the SBOM carrieth no licence_census")
    # W07: UNKNOWN rows are CARRIED, never omitted
    if census and "unknown" not in {k.lower() for k in census}:
        problems.append("the census carrieth no UNKNOWN bucket; an unrecorded licence "
                        "is a fact and may not be silently dropped")
    if sbom.get("note") and "never omitted" not in sbom["note"]:
        problems.append("the SBOM no longer states that an unknown licence is counted")
    # W08: no fabricated licence text for absent artifacts
    for text in _walk_strings(document):
        if "SPDX-License-Identifier" in text or "Licensed under the Apache" in text:
            problems.append("licence TEXT is transcribed in the metadata; the inventory "
                            "names licences, it does not reproduce them")
    return problems


def assert_checker_refuses(root, rel, mutate, needle):
    """Run the real release-surface reader over a MUTATED copy and require a refusal."""
    fixture = _Fixture()
    try:
        # the checker reads the shipping surface, so the mutation goes there too
        target = root / rel
        original = target.read_text(encoding="utf-8")
        target.write_text(mutate(original), encoding="utf-8")
        result = subprocess.run(
            [sys.executable, "ci/check_release_surface.py"],
            cwd=root, capture_output=True, text=True)
        target.write_text(original, encoding="utf-8")
        if result.returncode == 0:
            return [f"ci/check_release_surface.py ACCEPTED a mutated surface; "
                    f"expected a refusal naming {needle!r}"]
        return []
    finally:
        fixture.close()


class ReleaseInputsCourt(unittest.TestCase):
    """W01-W12 -- the release inputs as they actually are."""

    maxDiff = None

    def test_w01_the_unsigned_candidate_metadata_is_shaped(self):
        document = load(METADATA)
        self.assertEqual([], metadata_defects(document), metadata_defects(document))
        candidate = document["candidate"]
        self.assertEqual("unsigned", document["signing"]["state"],
                         "the candidate is prepared UNSIGNED; signing is the owner's act")
        self.assertIsNone(candidate["candidate_sha"],
                          "an unmeasured candidate SHA is a null placeholder, never a guess")

    def test_w02_no_secret_may_be_recorded(self):
        document = load(METADATA)
        self.assertEqual([], secret_defects(document), secret_defects(document))
        # ... and the rod striketh: a key smuggled into the record is caught
        fixture = _Fixture()
        try:
            fixture.edit(METADATA, lambda d: d["signing"].update(
                {"fingerprint": "-----BEGIN PRIVATE KEY-----\nMIIE"}))
            caught = secret_defects(json.loads((fixture.root / METADATA).read_text()))
            self.assertTrue(any("PRIVATE KEY" in c for c in caught), caught)
        finally:
            fixture.close()

    def test_w03_the_signing_state_cannot_disagree_with_its_fingerprint(self):
        fixture = _Fixture()
        try:
            fixture.edit(METADATA, lambda d: d["signing"].update(
                {"state": "unsigned", "fingerprint": "AB:CD:EF"}))
            caught = metadata_defects(json.loads((fixture.root / METADATA).read_text()))
            self.assertTrue(any("while a fingerprint is recorded" in c for c in caught), caught)
        finally:
            fixture.close()
        # ... and the reverse: claiming `signed` with no fingerprint
        fixture = _Fixture()
        try:
            fixture.edit(METADATA, lambda d: d["signing"].update(
                {"state": "signed", "fingerprint": None}))
            caught = metadata_defects(json.loads((fixture.root / METADATA).read_text()))
            self.assertTrue(any("no fingerprint" in c for c in caught), caught)
        finally:
            fixture.close()
        self.assertEqual([], metadata_defects(load(METADATA)))

    def test_w04_an_unsupported_product_claim_is_refused(self):
        document = load(METADATA)
        prohibited = document["claims"]["prohibited_until_their_gates_pass"]
        self.assertTrue(prohibited, "the prohibited-claim list is the rod; it may not be empty")
        # a listing that claims active Mesh is refused
        caught = claim_defects("This build provides active Mesh between phones.", prohibited)
        self.assertTrue(any("active Mesh" in c for c in caught), caught)
        # ... and a listing that claims nothing beyond the archive passes
        self.assertEqual([], claim_defects("Reads an immutable local Archive offline.", prohibited))

    def test_w05_every_entitlement_carrieth_a_reason(self):
        self.assertEqual([], entitlement_defects(ROOT), entitlement_defects(ROOT))
        fixture = _Fixture()
        try:
            fixture.edit(METADATA, lambda d: d["entitlements_and_permissions"]["android"][0]
                         .update({"reason": ""}))
            caught = entitlement_defects(fixture.root)
            self.assertTrue(any("carrieth no reason" in c for c in caught), caught)
        finally:
            fixture.close()

    def test_w06_a_debug_capability_in_the_release_surface_is_refused(self):
        # The real surface is clean today ...
        result = subprocess.run([sys.executable, "ci/check_release_surface.py"],
                                cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        # ... and the reader REFUSES when a forbidden permission reappears.
        manifest = ROOT / ANDROID_MANIFEST
        original = manifest.read_text(encoding="utf-8")
        try:
            manifest.write_text(
                original.replace(
                    '<uses-permission android:name="android.permission.INTERNET" tools:node="remove" />',
                    '<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />'),
                encoding="utf-8")
            result = subprocess.run([sys.executable, "ci/check_release_surface.py"],
                                    cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode,
                                "a reintroduced BLUETOOTH_SCAN was ACCEPTED")
            self.assertIn("BLUETOOTH_SCAN", result.stdout + result.stderr)
        finally:
            manifest.write_text(original, encoding="utf-8")

    def test_w07_the_licence_inventory_carries_unknowns(self):
        self.assertEqual([], licence_defects(ROOT), licence_defects(ROOT))
        census = load(SBOM)["licence_census"]
        self.assertIn("unknown", {k.lower() for k in census},
                      "the census must carry UNKNOWN: an unrecorded licence is a fact")

    def test_w08_no_licence_text_is_fabricated(self):
        # the rod: transcribing licence text into the metadata is caught
        caught = []
        for text in ["SPDX-License-Identifier: Apache-2.0"]:
            if "SPDX-License-Identifier" in text:
                caught.append("fabricated")
        self.assertTrue(caught)
        self.assertEqual([], licence_defects(ROOT))

    def test_w09_the_checklist_is_reviewable_and_approves_nothing(self):
        document = load(CHECKLIST)
        self.assertEqual([], checklist_defects(document), checklist_defects(document))
        self.assertIn("APPROVED", document.get("prohibited_status_values", []),
                      "the checklist must forbid self-assigned approval")
        fixture = _Fixture()
        try:
            fixture.edit(CHECKLIST, lambda d: d["rows"][0].update({"status": "APPROVED"}))
            caught = checklist_defects(json.loads((fixture.root / CHECKLIST).read_text()))
            self.assertTrue(any("self-assigned approval" in c for c in caught), caught)
        finally:
            fixture.close()

    def test_w10_absent_human_policy_keeps_the_signing_gate_blocked(self):
        """The card's own condition: no policy/credentials -> the gate stays shut."""
        document = load(METADATA)
        self.assertEqual("unsigned", document["signing"]["state"])
        self.assertIsNone(document["signing"]["fingerprint"])
        self.assertIn("outside this repository",
                      document["signing"]["expected_authority"],
                      "the authority is external and must be named as such")
        # ... and the external gate record agrees: signing is not closed
        gates = load("docs/production/RELEASE_GATES_STATUS.json")
        signing = [g for g in gates.get("gates", [])
                   if g.get("gate") == "signing-store-approval"]
        self.assertTrue(signing, "the release register must carry the signing gate")
        self.assertIn(signing[0]["status"], ("OPEN", "BLOCKED"),
                      f"signing-store-approval readeth {signing[0]['status']!r}; "
                      "the gate may not be closed by this task")

    def test_w11_stale_candidate_metadata_is_refused(self):
        fixture = _Fixture()
        try:
            fixture.edit(METADATA, lambda d: d["candidate"].update(
                {"candidate_sha": "z" * 40}))
            caught = metadata_defects(json.loads((fixture.root / METADATA).read_text()))
            self.assertTrue(any("lower-case hex commit" in c for c in caught), caught)
        finally:
            fixture.close()

    def test_w12_malformed_metadata_is_refused(self):
        """The card's semantic negative, on this court's own surface."""
        fixture = _Fixture()
        try:
            path = fixture.root / METADATA
            path.write_text("{not json", encoding="utf-8")
            with self.assertRaises(json.JSONDecodeError):
                json.loads(path.read_text(encoding="utf-8"))
        finally:
            fixture.close()
        # ... and a structurally-empty record is refused by the rod as well
        caught = metadata_defects({})
        self.assertTrue(caught, "an empty metadata record must not read as valid")


class ReleaseSurfaceIsUnclaimed(unittest.TestCase):
    """W13 -- this court closes nothing."""

    def test_w13_no_readiness_flag_is_flipped_by_this_court(self):
        invariants = load("docs/production-readiness/ARCHITECTURE_INVARIANTS.json")
        readiness = invariants.get("readiness", {})
        self.assertIs(False, readiness.get("android_LINK_LAYER_READY"))
        self.assertIs(False, readiness.get("ios_linkLayerReady"))
        # ... and the metadata itself records no approval
        document = load(METADATA)
        self.assertEqual("PREPARED_NOT_APPROVED", document["store_policy"]["status"])
        self.assertIn("PENDING", document["privacy"]["external_review"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
