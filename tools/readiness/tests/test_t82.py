#! /usr/bin/env python3
"""T82 readiness court: the unsupported tier and bulk-plane promises, closed explicitly.

The card's law, one witness each where the rule speaketh:

  W01 the ledger carrieth every capability with its ENABLING CODE and its STATUS
  W02 THE LAW: a capability advertised as available must have its enabling code
      ENABLED, and every refusal nameth the capability and the code
  W03 THE NAMED NEGATIVE, first limb: advertising BULK TRANSFER while its flag is
      false is REFUSED by name
  W04 THE NAMED NEGATIVE, second limb: an INTERNET permission in the Archive-only
      manifest is REFUSED by name
  W05 the LIGHT profile declareth every unsupported capability FALSE
  W06 the tier table carrieth EXACTLY one shipping tier (LIGHT), and MEDIUM/LARGE are
      research-only
  W07 the tier documentation SAYETH SO: a closed tier must be closed IN WORDS
  W08 the bulk plane is closed in words: ADR-006 is OPEN and the iOS transport
      reporteth unavailable rather than pretending to send
  W09 the iOS shipping surface advertises no bulk/multipeer capability
  W10 EVERY externally-open capability NAMETH a decision recorded in the release
      manifest or the external-blocker register
  W11 no ADVERTISED capability is an UNSUPPORTED STUB
  W12 the real repository PASSES the check, and each defect the court injecteth into
      a copy is CAUGHT
  W13 the ledger never claimeth a capability the code doth not enable, and the
      Archive-only product stayeth offline

No external gate is closed; readiness stays false; no device is claimed.
"""
from __future__ import annotations

import dataclasses
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

import promises as promises_module  # noqa: E402
from promises import (  # noqa: E402
    CAPABILITIES, Capability, Finding, Status, advertised, check, refused_promises,
    report,
)


class _PatchedLedger:
    """A context manager that swappeth the module's ledger for a patched one, so a
    witness can FEED the checker the very violation its rod striketh."""

    def __init__(self, changes):
        self.changes = changes

    def __enter__(self):
        patched = []
        for capability in promises_module.CAPABILITIES:
            change = self.changes.get(capability.id)
            patched.append(dataclasses.replace(capability, **change) if change else capability)
        self.original = promises_module.CAPABILITIES
        promises_module.CAPABILITIES = tuple(patched)
        return promises_module.CAPABILITIES

    def __exit__(self, *exc):
        promises_module.CAPABILITIES = self.original
        return False

#: The files the checker readeth: a corrupted fixture is a COPY of these.
FIXTURE_FILES = (
    "android/app/build.gradle.kts",
    "android/app/src/main/AndroidManifest.xml",
    "android/labmesh/src/main/AndroidManifest.xml",
    "config/tiers.json",
    "docs/packaging/TIERS.md",
    "docs/adr/ADR-006-bulk-plane.md",
    "ios/Godstone/Info.plist",
    "ios/Godstone/Godstone.entitlements",
    "ios/Godstone/Sources/GodstoneMesh/BulkTransport.swift",
    "docs/production/RELEASE_GATES_STATUS.json",
    "docs/production-readiness/EXTERNAL_BLOCKERS.json",
)


def _copy(root: Path, target: Path) -> None:
    for rel in FIXTURE_FILES:
        destination = target / rel
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text((root / rel).read_text(encoding="utf-8"), encoding="utf-8")


class T82LedgerTest(unittest.TestCase):
    """W01-W03 -- the ledger, the law, and the bulk-plane negative."""

    def test_w01_every_capability_carrieth_its_enabling_code_and_status(self):
        self.assertGreaterEqual(len(CAPABILITIES), 10)
        ids = [c.id for c in CAPABILITIES]
        self.assertEqual(len(ids), len(set(ids)), "capability ids must be unique")
        for capability in CAPABILITIES:
            self.assertTrue(capability.label, capability.id)
            self.assertTrue(capability.enabling_code, capability.id)
            self.assertIn(capability.status,
                          (Status.ENABLED, Status.DISABLED_EXPLICITLY,
                           Status.UNSUPPORTED_STUB, Status.EXTERNAL_DECISION_OPEN))
            # a STUB or an OPEN decision must say WHY
            if capability.status in (Status.UNSUPPORTED_STUB, Status.EXTERNAL_DECISION_OPEN):
                self.assertTrue(capability.note, capability.id)
        # the four families the card nameth are all present
        for required in ("bulk_transfer", "group_broadcast_authoring", "medium_tier",
                         "large_tier"):
            self.assertIn(required, ids, required)

    def test_w02_the_law_advertised_implies_enabled(self):
        for capability in advertised():
            self.assertTrue(capability.may_be_advertised,
                            "%s is advertised while %s" % (capability.id, capability.status))
        # and the refusal NAMETH the capability and the code
        for capability in refused_promises():
            self.assertFalse(capability.may_be_advertised, capability.id)
            self.assertTrue(capability.enabling_code)
        # the real repository carrieth no refused promise
        self.assertEqual((), refused_promises(),
                         "nothing advertised may be disabled, a stub or an open decision")
        # ... and the witness FEEDETH the checker the very violation its rod striketh
        with _PatchedLedger({"bulk_transfer": {"advertised_in": ("docs/packaging/TIERS.md",)}}):
            findings = check(ROOT)
            self.assertTrue(any(f.rule == "advertised-but-not-enabled" for f in findings),
                            [str(f) for f in findings])

    def test_w03_advertising_bulk_transfer_is_refused_by_name(self):
        bulk = next(c for c in CAPABILITIES if c.id == "bulk_transfer")
        self.assertEqual(Status.DISABLED_EXPLICITLY, bulk.status)
        self.assertFalse(bulk.may_be_advertised)
        self.assertIn("BULK_TRANSFER_ENABLED", bulk.enabling_code)
        # a ledger in which bulk IS advertised while disabled must be REFUSED
        armed = Capability(id=bulk.id, label=bulk.label, enabling_code=bulk.enabling_code,
                           status=bulk.status,
                           advertised_in=("docs/packaging/TIERS.md",), note=bulk.note)
        self.assertTrue(armed.is_advertised and not armed.may_be_advertised,
                        "advertising a disabled capability must be refusable")
        # ... and the check reporteth it when the fixture carrieth the words as a promise
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            _copy(ROOT, target)
            (target / "docs/packaging/TIERS.md").write_text(
                "Bulk transfer is available in every tier.\n", encoding="utf-8")
            findings = check(target)
            self.assertTrue(any("closure-unstated" in f.rule for f in findings),
                            [str(f) for f in findings])


class T82ProfileTest(unittest.TestCase):
    """W04-W06 -- the profile flags, INTERNET, the tier table."""

    def test_w04_internet_in_the_archive_only_manifest_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            _copy(ROOT, target)
            manifest = target / "android/app/src/main/AndroidManifest.xml"
            text = manifest.read_text(encoding="utf-8")
            manifest.write_text(text.replace('tools:node="remove"', ''), encoding="utf-8")
            findings = check(target)
            self.assertTrue(any(f.rule == "internet-reachable" for f in findings),
                            [str(f) for f in findings])
        # and the real manifest removeth it
        self.assertEqual([], [f for f in check(ROOT) if f.rule == "internet-reachable"])

    def test_w05_the_light_profile_declares_every_capability_false(self):
        gradle = (ROOT / "android/app/build.gradle.kts").read_text(encoding="utf-8")
        for flag in ("BULK_TRANSFER_ENABLED", "MESH_ENABLED", "ORACLE_ENABLED",
                     "SOS_ENABLED"):
            self.assertIn('buildConfigField("boolean", "%s", "false")' % flag, gradle, flag)
        # a mutant that flips ONE flag true is caught
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            _copy(ROOT, target)
            path = target / "android/app/build.gradle.kts"
            text = path.read_text(encoding="utf-8")
            path.write_text(text.replace('buildConfigField("boolean", "BULK_TRANSFER_ENABLED", "false")',
                                         'buildConfigField("boolean", "BULK_TRANSFER_ENABLED", "true")'),
                            encoding="utf-8")
            findings = check(target)
            self.assertTrue(any(f.rule == "profile-flag-not-disabled" for f in findings),
                            [str(f) for f in findings])

    def test_w06_exactly_one_shipping_tier_and_it_is_light(self):
        tiers = json.loads((ROOT / "config/tiers.json").read_text(encoding="utf-8"))["tiers"]
        shipping = [name for name, row in tiers.items() if row.get("shipping")]
        self.assertEqual(["LIGHT"], shipping, "exactly one shipping tier, and it is LIGHT")
        for research in ("MEDIUM", "LARGE"):
            self.assertFalse(tiers[research]["shipping"], research)
        # a mutant that shipeth MEDIUM is caught
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            _copy(ROOT, target)
            path = target / "config/tiers.json"
            document = json.loads(path.read_text(encoding="utf-8"))
            document["tiers"]["MEDIUM"]["shipping"] = True
            path.write_text(json.dumps(document, indent=2), encoding="utf-8")
            findings = check(target)
            # EACH clause separately: a witness that accepteth either rule would let
            # one of them fall asleep behind the other (its rod escaped until this
            # arm was split)
            self.assertTrue(any(f.rule == "tier-table-drift" for f in findings),
                            [str(f) for f in findings])
            self.assertTrue(any(f.rule == "tier-promise" for f in findings),
                            [str(f) for f in findings])


class T82ClosureTest(unittest.TestCase):
    """W07-W11 -- the closures in words, and the open decisions."""

    def test_w07_a_closed_tier_must_be_closed_in_words(self):
        doc = (ROOT / "docs/packaging/TIERS.md").read_text(encoding="utf-8").lower()
        self.assertIn("research", doc)
        self.assertIn("shipping", doc)
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            _copy(ROOT, target)
            (target / "docs/packaging/TIERS.md").write_text(
                "LIGHT, MEDIUM and LARGE are all products you may install.\n", encoding="utf-8")
            findings = check(target)
            self.assertTrue(any(f.rule == "closure-unstated" for f in findings),
                            [str(f) for f in findings])

    def test_w08_the_bulk_plane_is_closed_in_words(self):
        adr = (ROOT / "docs/adr/ADR-006-bulk-plane.md").read_text(encoding="utf-8")
        self.assertIn("OPEN", adr)
        transport = (ROOT / "ios/Godstone/Sources/GodstoneMesh/BulkTransport.swift").read_text(
            encoding="utf-8").lower()
        self.assertIn("unavailable", transport)
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            _copy(ROOT, target)
            path = target / "ios/Godstone/Sources/GodstoneMesh/BulkTransport.swift"
            path.write_text("import Foundation\n// bulk transfer works\n", encoding="utf-8")
            findings = check(target)
            self.assertTrue(any(f.rule == "bulk-stub-silent" for f in findings),
                            [str(f) for f in findings])

    def test_w09_the_ios_shipping_surface_advertises_no_bulk_capability(self):
        plist = (ROOT / "ios/Godstone/Info.plist").read_text(encoding="utf-8")
        for forbidden in ("NSLocalNetworkUsageDescription", "NSBonjourServices",
                          "UIBackgroundModes"):
            self.assertNotIn(forbidden, plist, forbidden)
        entitlements = (ROOT / "ios/Godstone/Godstone.entitlements").read_text(encoding="utf-8")
        for forbidden in ("multipeer", "Multipeer"):
            self.assertNotIn(forbidden, entitlements, forbidden)
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp)
            _copy(ROOT, target)
            path = target / "ios/Godstone/Info.plist"
            text = path.read_text(encoding="utf-8")
            path.write_text(text.replace("<dict>", "<dict>\n\t<key>NSLocalNetworkUsageDescription</key>\n\t<string>to send big files</string>", 1),
                            encoding="utf-8")
            findings = check(target)
            self.assertTrue(any(f.rule == "ios-capability-advertised" for f in findings),
                            [str(f) for f in findings])

    def test_w10_every_open_decision_is_recorded(self):
        open_capabilities = [c for c in CAPABILITIES
                             if c.status == Status.EXTERNAL_DECISION_OPEN]
        self.assertTrue(open_capabilities, "the ledger must carry the open decisions")
        blockers = (ROOT / "docs/production-readiness/EXTERNAL_BLOCKERS.json").read_text(
            encoding="utf-8")
        gates = (ROOT / "docs/production/RELEASE_GATES_STATUS.json").read_text(encoding="utf-8")
        for capability in open_capabilities:
            self.assertTrue(capability.external_decision, capability.id)
            token = capability.external_decision.upper()
            self.assertTrue(token in blockers.upper() or token in gates.upper(),
                            "%s nameth %s, which no register carrieth" % (capability.id, token))
        # and NONE of them is CLOSED by this task
        for capability in open_capabilities:
            self.assertNotEqual(Status.ENABLED, capability.status, capability.id)
        self.assertEqual([], [f for f in check(ROOT) if f.rule == "open-decision-unrecorded"])
        # EVERY capability that NAMETH a decision must name one a register carrieth --
        # not only the OPEN ones (a disabled tier nameth its own undecided design too)
        for capability in CAPABILITIES:
            if not capability.external_decision:
                continue
            token = capability.external_decision.upper()
            self.assertTrue(token in blockers.upper() or token in gates.upper(),
                            "%s nameth %s, which no register carrieth" % (capability.id, token))
        # ... and a BOGUS decision is refused by name, on ANY capability that nameth one
        with _PatchedLedger({"medium_tier": {"external_decision": "NOBODY_DECIDED_THIS"}}):
            findings = check(ROOT)
            self.assertTrue(any(f.rule == "open-decision-unrecorded" for f in findings),
                            [str(f) for f in findings])
        # ... and a CLOSED capability that nameth NO decision is refused too: a
        # research-only tier that pointeth at nothing would look deliberately closed
        with _PatchedLedger({"medium_tier": {"external_decision": ""}}):
            findings = check(ROOT)
            self.assertTrue(any(f.rule == "closure-without-decision" for f in findings),
                            [str(f) for f in findings])

    def test_w11_no_advertised_capability_is_a_stub(self):
        for capability in CAPABILITIES:
            if capability.status == Status.UNSUPPORTED_STUB:
                self.assertFalse(capability.is_advertised,
                                 "%s is a stub and must not be advertised" % capability.id)
        # the two incompatible stubs the card nameth are in the ledger
        stubs = {c.id for c in CAPABILITIES if c.status == Status.UNSUPPORTED_STUB}
        self.assertEqual({"wifi_aware_transport", "multipeer_transport"}, stubs)
        # ... and an ADVERTISED stub is refused by name
        with _PatchedLedger({"multipeer_transport": {"advertised_in": ("docs/packaging/TIERS.md",)}}):
            findings = check(ROOT)
            self.assertTrue(any(f.rule in ("stub-advertised", "advertised-but-not-enabled")
                                for f in findings), [str(f) for f in findings])


class T82RepositoryTest(unittest.TestCase):
    """W12-W13 -- the real repository, and the offline claim."""

    def test_w12_the_real_repository_passes(self):
        findings = check(ROOT)
        self.assertEqual([], [str(f) for f in findings], "the repository must pass the check")
        text = report(ROOT)
        self.assertIn("VERDICT: PASS", text)
        self.assertIn("advertised", text)

    def test_w13_the_ledger_claims_nothing_the_code_does_not_enable(self):
        for capability in CAPABILITIES:
            if capability.status == Status.ENABLED:
                self.assertFalse(capability.external_decision,
                                 "%s is enabled and carrieth no open decision" % capability.id)
        # the Archive-only product stayeth OFFLINE: no capability promiseth a network
        # it doth not have
        internet = next(c for c in CAPABILITIES if c.id == "internet_access")
        self.assertEqual(Status.DISABLED_EXPLICITLY, internet.status)
        self.assertIn("INTERNET", internet.enabling_code)
        # and the ledger carrieth no capability whose label promiseth an open decision
        for capability in CAPABILITIES:
            if capability.status == Status.EXTERNAL_DECISION_OPEN:
                self.assertFalse(capability.is_advertised,
                                 "%s is an OPEN decision and must not be advertised"
                                 % capability.id)


if __name__ == "__main__":
    unittest.main(verbosity=2)
