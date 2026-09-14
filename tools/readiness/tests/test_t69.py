#!/usr/bin/env python3
"""T69 readiness court (python isle): the real iOS release artifact.

The card's law, one witness each where the rule speaketh:

  W01  a source-only build is classified as such and never as a release
  W02  an approved manifest plus a byte-matched Archive is the one
       classification that carrieth the release-candidate name
  W03  an Archive inside the bundle with nothing approving it is
       present-unverified, never a candidate
  W04  an expected Archive that is absent is refused by name
  W05  a bundled Archive whose bytes differ from the approval is refused
  W06  the approved manifest must name the same application identity
  W07  a bundle carrieth the census it claimeth: every file hashed, an
       aggregate digest over the census, and a symlink refused as bytes
  W08  the excluded tiers (medium/large) are refused as resources
  W09  models, ML packages, dylibs and test bundles are refused as resources
  W10  GodstoneMesh linked into LIGHT is refused (the card's named semantic
       negative, first limb)
  W11  the LLM and BLE surfaces are refused where they are named
  W12  the architectures must be arm64, and a simulator slice is a lab
       artifact rather than a release candidate
  W13  the deployment minimum must be 16.0 or above
  W14  the Info.plist's disabled capabilities are refused
  W15  the declared release entitlements must be empty, and a forbidden
       entitlement is refused by name
  W16  a signed bundle's entitlements are read from the signature
  W17  the privacy manifest must be present
  W18  NSPrivacyTracking must be false for an Archive-only release
  W19  every declared accessed API must carry a reason code
  W20  a release that declareth collected data types is refused
  W21  test-only frameworks and bundles are refused
  W22  a Mach-O is parsed here: fat headers yield one slice per architecture
  W23  a truncated or foreign binary is refused by name, never guessed at
  W24  an IPA must carrieth exactly one app, with no traversal, symlink or
       world-writable entry
  W25  a release-candidate claim against a source build is refused
  W26  the report carrieth the device claim as UNVERIFIED, and the command
       door reporteth 0 for a clean source bundle and 1 for a refusal

All judgments run in-process over synthetic but structurally real bundles
(built by the inspector's own fixture writer, Mach-O load commands included),
over the repository's own reviewed plists read-only, and -- for the executed
evidence -- over the bundle that xcodebuild actually produced. Device
installation, launch and signing are EXTERNAL and no witness claimeth them.
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
import plistlib
import shutil
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
for _lane in (str(ROOT), str(ROOT / "scripts")):
    if _lane not in sys.path:
        sys.path.insert(0, _lane)

import inspect_ios_artifacts as I  # the authority under audit, in-process


class IosArtifactCourt(unittest.TestCase):
    """T69: the artifact, its exclusions, and the claims it does not make."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    # -- fixtures ---------------------------------------------------------
    def bundle(self, name: str = "Godstone.app", **kwargs) -> Path:
        bundle = self.root / name
        bundle.mkdir()
        I._write_synthetic_bundle(bundle, **kwargs)
        return bundle

    def approved(self, archive: Path, *, digest: str | None = None,
                 application: str = "io.godstone.app", tier: str = "LIGHT") -> Path:
        document = {
            "schema": 1, "tier": tier, "application_id": application,
            "generated_by": "scripts/prepare_release_assets.py",
            "assets": [{"role": "archive", "name": "archive_light.db",
                        "sha256": digest or I.sha256_file(archive),
                        "bytes": archive.stat().st_size, "build_phase": "resources"}],
        }
        path = self.root / f"APPROVED-{abs(hash(tier)) % 1000}-{application}.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def archive(self, *, tier: str = "LIGHT") -> Path:
        import sqlite3
        path = self.root / f"archive-{tier.lower()}-{abs(hash(tier)) % 1000}.db"
        con = sqlite3.connect(path)
        con.executescript((ROOT / "content/db/schema.sql").read_text())
        con.execute("INSERT INTO documents VALUES(1,'Fixture','reference','src','CC0',"
                    "'1','LIGHT',8,0)")
        con.execute("INSERT INTO chunks VALUES(1,1,0,'S','Synthetic fixture content',6)")
        con.executemany("INSERT INTO archive_meta VALUES(?,?)",
                        {"schema_version": "3", "tier": tier}.items())
        con.commit()
        con.close()
        return path

    # -- W01-W06 the classification ---------------------------------------
    def test_w01_a_source_build_is_classified_as_source_only(self):
        report = I.inspect(self.bundle())
        self.assertEqual("source-only-exclusion", report["classification"])
        self.assertEqual("PASS", report["verdict"])
        self.assertEqual("absent-expected-none", report["archive"]["status"])
        self.assertEqual("ios", report["architectures"]["platform"])
        self.assertEqual(["arm64"], report["architectures"]["architectures"])

    def test_w02_a_byte_matched_approval_is_the_only_candidate(self):
        bundle = self.bundle()
        archive = self.archive()
        shutil.copyfile(archive, bundle / "archive_light.db")
        report = I.inspect(bundle, approved_manifest=self.approved(archive))
        self.assertEqual("release-candidate-content", report["classification"])
        self.assertEqual("byte-matched", report["archive"]["status"])
        self.assertEqual("LIGHT", report["archive"]["tier"])
        self.assertEqual(I.sha256_file(archive), report["archive"]["bundled_sha256"])
        self.assertEqual("PASS", report["verdict"])

    def test_w03_an_unapproved_archive_is_present_unverified(self):
        bundle = self.bundle()
        archive = self.archive()
        shutil.copyfile(archive, bundle / "archive_light.db")
        report = I.inspect(bundle, expected_archive=archive)
        self.assertEqual("present-unverified", report["classification"])
        self.assertEqual("byte-matched", report["archive"]["status"])
        self.assertTrue(any("presence claim is met" in item
                            for item in report["warnings"]), report["warnings"])
        bare = self.bundle("Bare.app")
        shutil.copyfile(archive, bare / "archive_light.db")
        unapproved = I.inspect(bare)
        self.assertEqual("present-unverified", unapproved["classification"])

    def test_w04_an_absent_expected_archive_is_refused(self):
        archive = self.archive()
        report = I.inspect(self.bundle(), expected_archive=archive)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("expected Archive is absent from the package" in item
                            for item in report["failures"]), report["failures"])
        self.assertEqual("refused", report["classification"])

    def test_w05_a_mismatched_archive_is_refused(self):
        bundle = self.bundle()
        archive = self.archive()
        shutil.copyfile(archive, bundle / "archive_light.db")
        report = I.inspect(bundle, approved_manifest=self.approved(archive,
                                                                  digest="0" * 64))
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("is not the approved Archive" in item
                            for item in report["failures"]), report["failures"])

    def test_w06_the_approval_must_name_this_application(self):
        bundle = self.bundle()
        archive = self.archive()
        shutil.copyfile(archive, bundle / "archive_light.db")
        with self.assertRaisesRegex(I.ArtifactError, "identity mismatch"):
            I.inspect(bundle, approved_manifest=self.approved(
                archive, application="io.someone.else"))

    # -- W07-W11 the resources and the link map ---------------------------
    def test_w07_the_census_is_hashed_and_a_symlink_is_refused(self):
        bundle = self.bundle()
        report = I.inspect(bundle)
        census = report["hashes"]["files"]
        self.assertEqual(report["resources"]["count"], len(census))
        self.assertEqual(report["resources"]["total_bytes"],
                         sum(entry["bytes"] for entry in census))
        for entry in census:
            self.assertEqual(64, len(entry["sha256"]))
        self.assertEqual(I.aggregate_digest(census), report["hashes"]["aggregate_sha256"])
        (bundle / "link.db").symlink_to(self.archive())
        with self.assertRaisesRegex(I.ArtifactError, "carrieth a symlink"):
            I.inspect(bundle)

    def test_w08_an_excluded_tier_archive_is_refused(self):
        for name in I.FORBIDDEN_ARCHIVES:
            with self.subTest(name=name):
                bundle = self.bundle(f"Tier-{name}.app")
                (bundle / name).write_bytes(b"another tier")
                report = I.inspect(bundle)
                self.assertEqual("FAIL", report["verdict"])
                self.assertTrue(any(name in item for item in report["failures"]),
                                report["failures"])

    def test_w09_models_dylibs_and_test_bundles_are_refused_resources(self):
        for name, cry in (("model.gguf", "excludes"), ("Net.mlmodelc", "excludes"),
                          ("Extra.dylib", "excludes"), ("GodstoneTests.xctest",
                                                        "excludes")):
            with self.subTest(name=name):
                bundle = self.bundle(f"Res-{name}.app")
                (bundle / name).write_bytes(b"x")
                report = I.inspect(bundle)
                self.assertEqual("FAIL", report["verdict"])
                self.assertTrue(any(cry in item and name in item
                                    for item in report["failures"]), report["failures"])

    def test_w10_the_mesh_linked_into_light_is_refused(self):
        bundle = self.bundle(library="/System/Library/Frameworks/GodstoneMesh.framework/"
                                      "GodstoneMesh")
        report = I.inspect(bundle)
        self.assertEqual("FAIL", report["verdict"])
        self.assertEqual(["arm64"], report["architectures"]["architectures"])
        self.assertTrue(any("GodstoneMesh" in item for item in report["failures"]),
                        report["failures"])
        self.assertEqual("refused", report["classification"])

    def test_w11_the_llm_and_ble_surfaces_are_refused_where_named(self):
        for token in ("GodstoneLLM", "CoreBluetooth", "XCTest", "llama"):
            with self.subTest(token=token):
                bundle = self.bundle(f"Link-{token}.app",
                                     library=f"/usr/lib/{token}.dylib")
                report = I.inspect(bundle)
                self.assertEqual("FAIL", report["verdict"])
                self.assertTrue(any(token in item for item in report["failures"]),
                                report["failures"])

    # -- W12-W16 the binary, the plist and the entitlements ---------------
    def test_w12_a_simulator_slice_is_not_a_release_candidate(self):
        bundle = self.bundle()
        # a fat binary carrying both the device and the simulator slice
        device = (bundle / "Fixture").read_bytes()
        simulator = bytearray(device)
        struct.pack_into("<I", simulator, 4, 0x01000007)
        struct.pack_into("<I", simulator, 64, 7)          # LC_BUILD_VERSION platform
        fat = (struct.pack(">II", 0xcafebabe, 2)
               + struct.pack(">IIIII", 0x0100000c, 0, 8 + 2 * 20, len(device), 0)
               + struct.pack(">IIIII", 0x01000007, 0, 8 + 2 * 20 + len(device),
                             len(simulator), 0)
               + device + bytes(simulator))
        (bundle / "Fixture").write_bytes(fat)
        report = I.inspect(bundle)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("simulator slice" in item for item in report["failures"]),
                        report["failures"])
        self.assertIn("x86_64", report["architectures"]["architectures"])

    def test_w13_the_deployment_minimum_is_enforced(self):
        report = I.inspect(self.bundle(minos="15.0"))
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("below 16.0" in item for item in report["failures"]),
                        report["failures"])
        self.assertEqual("PASS", I.inspect(self.bundle("Ok.app", minos="17.0"))["verdict"])

    def test_w14_the_disabled_info_plist_capabilities_are_refused(self):
        bundle = self.bundle()
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        info["NSBluetoothAlwaysUsageDescription"] = "why"
        info["UIBackgroundModes"] = ["bluetooth-central"]
        (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
        report = I.inspect(bundle)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("NSBluetoothAlwaysUsageDescription" in item
                            for item in report["failures"]), report["failures"])
        self.assertTrue(any("UIBackgroundModes" in item for item in report["failures"]),
                        report["failures"])

    def test_w15_the_declared_release_entitlements_must_be_empty(self):
        bundle = self.bundle()
        empty = self.root / "empty.entitlements"
        empty.write_bytes(plistlib.dumps({}))
        report = I.inspect(bundle, entitlements_path=empty)
        self.assertEqual("PASS", report["verdict"])
        self.assertEqual([], report["entitlements"]["declared_keys"])
        carrying = self.root / "carrying.entitlements"
        carrying.write_bytes(plistlib.dumps(
            {"aps-environment": "production",
             "com.apple.developer.networking.multicast": True}))
        report = I.inspect(bundle, entitlements_path=carrying)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("must be empty" in item for item in report["failures"]),
                        report["failures"])
        self.assertTrue(any("multicast" in item and "disabled capability" in item
                            for item in report["failures"]), report["failures"])
        self.assertEqual(["aps-environment",
                          "com.apple.developer.networking.multicast"],
                         report["entitlements"]["declared_keys"])

    def test_w16_a_signed_bundle_entitlements_are_read_from_the_signature(self):
        bundle = self.bundle()
        signature = plistlib.dumps({"application-identifier": "TEAM.io.godstone.app"})
        with patch.object(I.shutil, "which", return_value="/usr/bin/codesign"):
            with patch.object(I.subprocess, "run",
                              return_value=type("R", (), {"returncode": 0,
                                                          "stdout": signature,
                                                          "stderr": b""})()):
                report = I.inspect(bundle)
        self.assertTrue(report["entitlements"]["signed"])
        self.assertIn("application-identifier", report["entitlements"]["keys"])
        # and a signature carrying a forbidden entitlement is caught
        forbidden = plistlib.dumps({"aps-environment": "production"})
        with patch.object(I.shutil, "which", return_value="/usr/bin/codesign"):
            with patch.object(I.subprocess, "run",
                              return_value=type("R", (), {"returncode": 0,
                                                          "stdout": forbidden,
                                                          "stderr": b""})()):
                caught = I.inspect(bundle)
        self.assertEqual(["aps-environment"], caught["entitlements"]["forbidden"])

    # -- W17-W21 the privacy manifest -------------------------------------
    def test_w17_the_privacy_manifest_must_be_present(self):
        bundle = self.bundle()
        (bundle / "PrivacyInfo.xcprivacy").unlink()
        report = I.inspect(bundle)
        self.assertEqual("FAIL", report["verdict"])
        self.assertFalse(report["privacy"]["present"])
        self.assertTrue(any("no PrivacyInfo.xcprivacy" in item
                            for item in report["failures"]), report["failures"])

    def test_w18_tracking_must_be_false(self):
        report = I.inspect(self.bundle(tracking=True))
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("NSPrivacyTracking must be false" in item
                            for item in report["failures"]), report["failures"])

    def test_w19_every_accessed_api_carrieth_a_reason(self):
        bundle = self.bundle()
        privacy = plistlib.loads((bundle / "PrivacyInfo.xcprivacy").read_bytes())
        privacy["NSPrivacyAccessedAPITypes"] = [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryDiskSpace"},
            {"NSPrivacyAccessedAPITypeReasons": ["C617.1"]}]
        (bundle / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(privacy))
        report = I.inspect(bundle)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("carrieth no reason code" in item
                            for item in report["failures"]), report["failures"])
        self.assertTrue(any("carrieth no category" in item
                            for item in report["failures"]), report["failures"])

    def test_w20_collected_data_types_are_refused(self):
        bundle = self.bundle()
        privacy = plistlib.loads((bundle / "PrivacyInfo.xcprivacy").read_bytes())
        privacy["NSPrivacyCollectedDataTypes"] = [
            {"NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypePreciseLocation",
             "NSPrivacyCollectedDataTypeLinked": False,
             "NSPrivacyCollectedDataTypeTracking": False,
             "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]}]
        (bundle / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(privacy))
        report = I.inspect(bundle)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("collecteth nothing" in item for item in report["failures"]),
                        report["failures"])

    def test_w21_test_only_surfaces_are_refused(self):
        bundle = self.bundle()
        tests = bundle / "PlugIns" / "GodstoneTests.xctest"
        tests.mkdir(parents=True)
        (tests / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "t"}))
        report = I.inspect(bundle)
        self.assertIn("PlugIns/GodstoneTests.xctest/Info.plist",
                      report["test_only"]["bundles"])
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("test-only surfaces" in item for item in report["failures"]),
                        report["failures"])

    # -- W22-W24 the readers' own laws ------------------------------------
    def test_w22_a_fat_binary_yieldeth_one_slice_per_architecture(self):
        device = (self.bundle() / "Fixture").read_bytes()
        fat = (struct.pack(">II", 0xcafebabf, 2)
               + struct.pack(">IIQQII", 0x0100000c, 0, 8 + 2 * 32, len(device), 0, 0)
               + struct.pack(">IIQQII", 0x01000007, 0, 8 + 2 * 32 + len(device),
                             len(device), 0, 0)
               + device + device)
        slices = I.parse_macho(fat)
        self.assertEqual(2, len(slices))
        self.assertEqual({"arm64", "x86_64"}, {entry["arch"] for entry in slices})
        self.assertEqual("ios", slices[0]["platform"])
        self.assertEqual("16.0.0", slices[0]["minos"])
        self.assertEqual(32, len(slices[0]["uuid"]))  # 16 bytes, hexed
        with self.assertRaisesRegex(I.ArtifactError, "implausible architecture count"):
            I.parse_macho(struct.pack(">II", 0xcafebabe, 9999))

    def test_w23_a_truncated_or_foreign_binary_is_refused(self):
        bundle = self.bundle()
        (bundle / "Fixture").write_bytes(b"not a mach-o at all")
        with self.assertRaisesRegex(I.ArtifactError, "not a Mach-O"):
            I.inspect(bundle)
        device = (self.bundle("Truncated.app") / "Fixture").read_bytes()
        # 20 bytes: the magic is intact and the header is not, so the refusal
        # must be the header's own, named exactly (a looser regex would let a
        # mutant that skippeth the header check escape on a later complaint)
        (self.root / "Truncated.app" / "Fixture").write_bytes(device[:20])
        with self.assertRaisesRegex(I.ArtifactError, "the Mach-O header is truncated"):
            I.inspect(self.root / "Truncated.app")
        # 40 bytes: header intact, first load command truncated, refused by its own law
        (self.root / "Truncated.app" / "Fixture").write_bytes(device[:40])
        with self.assertRaisesRegex(I.ArtifactError, "leaveth the file|is truncated"):
            I.inspect(self.root / "Truncated.app")
        fat = struct.pack(">II", 0xcafebabe, 1) + struct.pack(">IIIII", 0x0100000c, 0,
                                                             1024, 4096, 0)
        (self.root / "Truncated.app" / "Fixture").write_bytes(fat)
        with self.assertRaisesRegex(I.ArtifactError, "reacheth past the end"):
            I.inspect(self.root / "Truncated.app")

    def test_w24_an_ipa_must_carrieth_one_clean_app(self):
        bundle = self.bundle()
        good = self.root / "good.ipa"
        with zipfile.ZipFile(good, "w") as archive:
            for path in sorted(bundle.rglob("*")):
                if path.is_file():
                    archive.write(path, f"Payload/Godstone.app/"
                                        f"{path.relative_to(bundle)}")
        with tempfile.TemporaryDirectory() as work:
            extracted = I.extract_ipa(good, Path(work))
            report = I.inspect(extracted)
        self.assertEqual("source-only-exclusion", report["classification"])
        for name, cry, entry in (
                ("two.ipa", "exactly one app", [("Payload/A.app/x", b"x"),
                                                ("Payload/B.app/y", b"y")]),
                ("traversal.ipa", "traversal entry", [("Payload/../../etc/passwd",
                                                       b"x")]),
                ("absolute.ipa", "traversal entry", [("/Payload/Godstone.app/x",
                                                      b"x")]),
                ("nopayload.ipa", "exactly one app", [("Godstone.app/x", b"x")]),
                ("nested.ipa", "exactly one app", [("Payload/Godstone.app/x", b"x"),
                                                   ("Payload/Other.app/y", b"y")])):
            with self.subTest(name=name):
                path = self.root / name
                with zipfile.ZipFile(path, "w") as archive:
                    for entry_name, blob in entry:
                        # a ZipInfo keepeth the name verbatim, which is how a
                        # hostile package carrieth its traversal
                        archive.writestr(zipfile.ZipInfo(entry_name), blob)
                with tempfile.TemporaryDirectory() as work:
                    with self.assertRaisesRegex(I.ArtifactError, cry):
                        I.extract_ipa(path, Path(work))
        symlink = self.root / "symlink.ipa"
        with zipfile.ZipFile(symlink, "w") as archive:
            info = zipfile.ZipInfo("Payload/Godstone.app/x")
            info.external_attr = (0o120777 << 16)
            archive.writestr(info, "target")
        with tempfile.TemporaryDirectory() as work:
            with self.assertRaisesRegex(I.ArtifactError, "symlink entry"):
                I.extract_ipa(symlink, Path(work))

    # -- W25-W26 the claims the report refuseth to make -------------------
    def test_w25_a_release_candidate_claim_against_a_source_build_is_refused(self):
        report = I.inspect(self.bundle(), release_candidate=True)
        self.assertEqual("FAIL", report["verdict"])
        self.assertEqual("refused", report["classification"])
        self.assertTrue(any("claimeth to be a release candidate" in item
                            for item in report["failures"]), report["failures"])

    def test_w26_the_device_claim_is_unverified_and_the_door_reporteth(self):
        bundle = self.bundle()
        report = I.inspect(bundle)
        self.assertIn("UNVERIFIED", report["device"]["installed"])
        self.assertIn("UNVERIFIED", report["device"]["launched"])
        self.assertIn("external evidence", report["device"]["note"])
        # The door's own words are captured rather than printed: a bare
        # "FAIL:" line on stdout is indistinguishable from a unittest verdict
        # line, and the mutation harness readeth exactly those.
        def door(argv):
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                code = I.main(argv)
            return code, captured.getvalue()

        code, said = door([str(bundle)])
        self.assertEqual(0, code)
        self.assertIn("PASS: source-only-exclusion", said)
        (bundle / "archive_medium.db").write_bytes(b"x")
        code, said = door([str(bundle)])
        self.assertEqual(1, code)
        self.assertIn("FAIL: refused", said)
        self.assertIn("::error::", said)
        code, said = door(["--selftest"])
        self.assertEqual(0, code)
        self.assertIn("selftest OK", said)
        out = self.root / "report"
        out.mkdir()
        code, said = door([str(self.bundle("Reported.app")), "--out", str(out)])
        self.assertEqual(0, code)
        document = json.loads((out / "ios-artifact-report.json").read_text())
        self.assertEqual("source-only-exclusion", document["classification"])
        for key in ("hashes", "resources", "linkMap", "architectures", "entitlements",
                    "privacy", "bundleMetadata"):
            self.assertIn(key, document)
        self.assertEqual(1, door([str(self.root / "absent.app")])[0])
        self.assertEqual(1, door([str(self.asset_that_is_not_a_bundle())])[0])

    def asset_that_is_not_a_bundle(self) -> Path:
        path = self.root / "not-a-bundle.txt"
        path.write_text("plain text")
        return path


if __name__ == "__main__":
    unittest.main()
