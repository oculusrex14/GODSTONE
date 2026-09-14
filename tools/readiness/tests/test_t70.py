#!/usr/bin/env python3
"""T70 readiness court (python isle): the Android release artifact.

  W01  every required ABI carrieth every native library, and a package
       missing one is refused (the card's named semantic negative)
  W02  a library absent from one ABI is refused by name, though the others
       carry it
  W03  the AAB's ABI coverage is judged on its own base/lib tree
  W04  a PT_LOAD alignment below 16 KiB is refused: that library cannot load
       on a 16 KiB-page device
  W05  a 16 KiB-aligned library passeth, and the alignments are reported
  W06  a non-ELF and a truncated ELF are refused by name
  W07  the merged manifest's forbidden permissions are refused
  W08  a debuggable release manifest is refused
  W09  the backup surface must be excluded (android:allowBackup=false)
  W10  an absent merged manifest is refused: the permissions cannot be judged
  W11  minification must be declared, keep rules must exist, and a minified
       build must produce its mapping
  W12  a keep rule naming one of the APPLICATION's own classes that the dex
       carrieth not is refused
  W13  a keep rule naming an EXCLUDED module is recorded, never refused (the
       LIGHT release carrieth no :llm and no :mesh dependency by design)
  W14  wildcard keep rules are judged by prefix, and a rule that kept nothing
       is named rather than silently believed
  W15  the release runtime classpath may not carry an excluded module
  W16  the packaged Archive: byte-matched with an approval is the only
       candidate; absent while expected, or mismatched, is refused;
       unapproved is present-unverified
  W17  a traversal, symlink or world-writable entry in the container is
       refused; an unsigned release is recorded, not refused
  W18  the device claims are UNVERIFIED, the report is determinist, and the
       command door reporteth 0 for a clean release and 1 for a refusal

All judgments run in-process over synthetic containers (real zip files and
real ELF program headers, built by the reader's own fixture writers) and over
the repository's own reviewed inputs read-only. Installation on a minAPI26
device and on a current supported target, the FTS5 query in the shrunk app,
and the store's target requirements at submission are EXTERNAL: no witness
claimeth them, and a rod that would assert them must die.
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import shutil
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
for _lane in (str(ROOT), str(ROOT / "scripts")):
    if _lane not in sys.path:
        sys.path.insert(0, _lane)

import inspect_android_release as A  # the authority under audit, in-process


class AndroidReleaseCourt(unittest.TestCase):
    """T70: the release package as built, not as hoped."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    # -- fixtures ---------------------------------------------------------
    def apk(self, name: str = "release.apk", *, abis=("arm64-v8a",),
            page_size: int = A.PAGE_SIZE_16K) -> Path:
        return A._write_synthetic_apk(self.root / name, abis=abis,
                                      page_size=page_size)

    def judge(self, apk: Path, **overrides):
        options = {
            "merged_manifest": A._write_manifest(self.root, allow_backup="false"),
            "rules": A._write_rules(self.root),
            "mapping": A._write_mapping(self.root),
            "dependencies_text": "+--- io.godstone:core:1.0\n",
        }
        options.update(overrides)
        return A.inspect(apk, **options)

    # -- W01-W06 the ABI and the page size --------------------------------
    def test_w01_a_missing_abi_is_refused(self):
        report = self.judge(self.apk(abis=()))
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("required ABI arm64-v8a" in item
                            for item in report["failures"]), report["failures"])
        self.assertIn("arm64-v8a", report["ABI"]["required"])
        self.assertEqual([], report["ABI"]["libraries"])

    def test_w02_a_library_missing_from_one_abi_is_named(self):
        apk = self.root / "partial.apk"
        A._write_synthetic_apk(apk, abis=("arm64-v8a",), page_size=A.PAGE_SIZE_16K)
        with zipfile.ZipFile(apk, "a") as container:
            container.writestr("lib/armeabi-v7a/libgodstone_core.so",
                               A._synthetic_elf(A.PAGE_SIZE_16K))
        report = self.judge(apk)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("libgodstone_sqlite.so is absent from ABI armeabi-v7a"
                            in item for item in report["failures"]), report["failures"])

    def test_w03_the_aab_coverage_is_judged_separately(self):
        aab = self.root / "release.aab"
        with zipfile.ZipFile(aab, "w") as container:
            container.writestr("base/dex/classes.dex", b"Lio/godstone/app/MainActivity;")
            container.writestr("base/lib/arm64-v8a/libgodstone_sqlite.so",
                               A._synthetic_elf(A.PAGE_SIZE_16K))
        report = self.judge(self.apk(), aab=aab)
        self.assertEqual("PASS", report["verdict"])
        self.assertEqual({"arm64-v8a": ["libgodstone_sqlite.so"]},
                         report["AAB"]["abi"])
        empty = self.root / "empty.aab"
        with zipfile.ZipFile(empty, "w") as container:
            container.writestr("base/dex/classes.dex", b"x")
        missing = self.judge(self.apk(), aab=empty)
        self.assertEqual("FAIL", missing["verdict"])
        self.assertTrue(any("AAB carrieth no native library for the required ABI"
                            in item for item in missing["failures"]),
                        missing["failures"])

    def test_w04_a_four_kib_alignment_is_refused(self):
        report = self.judge(self.apk(page_size=4096))
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("not 16 KiB page compatible" in item
                            for item in report["failures"]), report["failures"])
        face = report["pageSize"]["arm64-v8a"]["libgodstone_sqlite.so"]
        self.assertEqual([4096], face["alignments"])
        self.assertEqual("4KiB-only (p_align=4096)", face["face"])

    def test_w05_a_sixteen_kib_alignment_passeth_and_is_reported(self):
        report = self.judge(self.apk(page_size=16384))
        self.assertEqual("PASS", report["verdict"])
        face = report["pageSize"]["arm64-v8a"]["libgodstone_sqlite.so"]
        self.assertEqual("16KiB-compatible", face["face"])
        self.assertEqual(16384, face["minimum"])

    def test_w06_a_foreign_or_truncated_elf_is_refused(self):
        with self.assertRaisesRegex(A.ReleaseArtifactError, "not an ELF image"):
            A.elf_load_alignments(b"MZ\x90\x00" + b"\x00" * 60)
        with self.assertRaisesRegex(A.ReleaseArtifactError, "too short"):
            A.elf_load_alignments(b"\x7fELF" + b"\x00" * 8)
        blob = A._synthetic_elf(A.PAGE_SIZE_16K)
        with self.assertRaisesRegex(A.ReleaseArtifactError, "reach past the end"):
            A.elf_load_alignments(blob[:64] + blob[64:70])

    # -- W07-W10 the merged manifest --------------------------------------
    def test_w07_a_forbidden_permission_is_refused(self):
        manifest = A._write_manifest(
            self.root / "permissions.xml", permissions=(
                "android.permission.INTERNET",
                "android.permission.BLUETOOTH_SCAN"))
        report = self.judge(self.apk(), merged_manifest=manifest)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("disabled permission android.permission.INTERNET" in item
                            for item in report["failures"]), report["failures"])
        self.assertTrue(any("BLUETOOTH_SCAN" in item for item in report["failures"]),
                        report["failures"])

    def test_w08_a_debuggable_release_is_refused(self):
        path = self.root / "debuggable.xml"
        path.write_text('<?xml version="1.0" encoding="utf-8"?>'
                        '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
                        '<application android:debuggable="true" '
                        'android:allowBackup="false"/></manifest>', encoding="utf-8")
        report = self.judge(self.apk(), merged_manifest=path)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("debuggable=true" in item for item in report["failures"]),
                        report["failures"])

    def test_w09_the_backup_surface_must_be_excluded(self):
        report = self.judge(self.apk(), merged_manifest=A._write_manifest(
            self.root / "backup-on.xml", allow_backup="true"))
        self.assertEqual("FAIL", report["verdict"])
        self.assertEqual("true", report["manifest"]["allow_backup"])
        self.assertTrue(any("allowBackup" in item for item in report["failures"]),
                        report["failures"])
        default = self.root / "default.xml"
        default.write_text('<?xml version="1.0" encoding="utf-8"?>'
                           '<manifest xmlns:android="http://schemas.android.com/apk/res/android">'
                           '<application/></manifest>', encoding="utf-8")
        self.assertEqual("FAIL", self.judge(self.apk(), merged_manifest=default)["verdict"])

    def test_w10_an_absent_manifest_is_refused(self):
        report = self.judge(self.apk(), merged_manifest=self.root / "absent.xml")
        self.assertEqual("FAIL", report["verdict"])
        self.assertFalse(report["manifest"]["present"])
        self.assertTrue(any("merged release manifest is absent" in item
                            for item in report["failures"]), report["failures"])

    # -- W11-W14 R8 -------------------------------------------------------
    def test_w11_minification_and_its_mapping_are_both_required(self):
        no_rules = self.root / "empty.pro"
        no_rules.write_text("# nothing kept\n", encoding="utf-8")
        report = self.judge(self.apk(), rules=no_rules)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("no -keep rule existeth" in item
                            for item in report["failures"]), report["failures"])
        no_mapping = self.judge(self.apk(), mapping=self.root / "absent-mapping.txt")
        self.assertEqual("FAIL", no_mapping["verdict"])
        self.assertTrue(any("no mapping.txt was produced" in item
                            for item in no_mapping["failures"]), no_mapping["failures"])
        with_rule = self.root / "rule.pro"
        with_rule.write_text("-keep class io.godstone.app.MainActivity { *; }\n",
                             encoding="utf-8")
        report = self.judge(self.apk(), rules=with_rule)
        self.assertTrue(report["R8"]["minify_declared"])
        self.assertTrue(report["R8"]["mapping_present"])

    def test_w12_a_keep_rule_that_kept_nothing_of_ours_is_refused(self):
        rules = self.root / "own.pro"
        rules.write_text("-keep class io.godstone.app.OracleViewModel { *; }\n",
                         encoding="utf-8")
        report = self.judge(self.apk(), rules=rules)
        self.assertEqual("FAIL", report["verdict"])
        self.assertEqual(["io.godstone.app.OracleViewModel"],
                         report["R8"]["application_targets_missing_from_dex"])
        self.assertTrue(any("classes of THIS application" in item
                            for item in report["failures"]), report["failures"])

    def test_w13_a_rule_for_an_excluded_module_is_recorded_not_refused(self):
        rules = self.root / "excluded.pro"
        rules.write_text("-keep class io.godstone.llm.LlamaBridge { *; }\n"
                         "-keep class io.godstone.mesh.** { *; }\n"
                         "-keep class io.godstone.app.MainActivity { *; }\n",
                         encoding="utf-8")
        report = self.judge(self.apk(), rules=rules)
        self.assertEqual("PASS", report["verdict"])
        self.assertEqual(2, len(report["R8"]["excluded_module_rules"]))
        self.assertEqual([], report["R8"]["application_targets_missing_from_dex"])
        self.assertTrue(any("excluded module" in report["R8"]["note"]
                            for _ in [0]) or "excluded module" in report["R8"]["note"])

    def test_w14_wildcards_are_judged_by_prefix(self):
        rules = self.root / "wild.pro"
        rules.write_text("-keep class io.godstone.app.** { *; }\n"
                         "-keep class com.example.missing.** { *; }\n",
                         encoding="utf-8")
        report = self.judge(self.apk(), rules=rules)
        self.assertEqual("PASS", report["verdict"])
        self.assertIn("com.example.missing.**",
                      report["R8"]["absent_library_targets"])
        self.assertEqual([], report["R8"]["application_targets_missing_from_dex"])

    # -- W15-W18 the classpath, the Archive and the doors ------------------
    def test_w15_the_classpath_may_not_carry_an_excluded_module(self):
        text = ("+--- project :core\n"
                "+--- project :llm\n"
                "|    \\--- io.godstone:llm:1.0\n"
                "\\--- io.godstone:mesh:1.0\n")
        report = self.judge(self.apk(), dependencies_text=text)
        self.assertEqual("FAIL", report["verdict"])
        self.assertEqual(["io.godstone:llm:1.0", "io.godstone:mesh:1.0"],
                         [item for item in report["classpaths"]["forbidden"]
                          if item.startswith("io.godstone")])
        self.assertEqual(2, report["classpaths"]["count"])
        absent = self.judge(self.apk(), dependencies_text=None)
        self.assertTrue(any("classpath was not captured" in item
                            for item in absent["failures"]), absent["failures"])

    def test_w16_the_packaged_archive_is_judged_against_its_approval(self):
        approved_archive = self.root / "archive_light.db"
        approved_archive.write_bytes(b"the approved bytes")
        apk = self.apk()
        with zipfile.ZipFile(apk, "a") as container:
            container.writestr(A.ARCHIVE_ASSET, b"the approved bytes")
        digest = A.sha256_file(approved_archive)
        manifest = self.root / "APPROVED_ASSETS.json"
        manifest.write_text(json.dumps({
            "schema": 1, "tier": "LIGHT", "application_id": "io.godstone.app",
            "assets": [{"role": "archive", "name": "archive_light.db",
                        "sha256": digest, "bytes": len(b"the approved bytes")}]}),
            encoding="utf-8")
        report = self.judge(apk, approved_manifest=manifest)
        self.assertEqual("release-candidate-content", report["classification"])
        self.assertEqual("byte-matched", report["approvedArchive"]["status"])
        self.assertEqual("PASS", report["verdict"])
        unapproved = self.judge(apk, expected_archive=approved_archive)
        self.assertEqual("present-unverified", unapproved["classification"])
        mismatched = self.root / "other-approval.json"
        mismatched.write_text(json.dumps({
            "schema": 1, "tier": "LIGHT", "application_id": "io.godstone.app",
            "assets": [{"role": "archive", "name": "archive_light.db",
                        "sha256": "0" * 64, "bytes": 19}]}), encoding="utf-8")
        report = self.judge(apk, approved_manifest=mismatched)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("not the approved Archive" in item
                            for item in report["failures"]), report["failures"])
        absent = self.judge(self.apk(), expected_archive=approved_archive)
        self.assertEqual("source-only-absent" if False else "refused",
                         absent["classification"])
        self.assertTrue(any("expected Archive is absent" in item
                            for item in absent["failures"]), absent["failures"])

    def test_w17_container_hygiene_and_the_signature_face(self):
        for label, name, mode in (("traversal", "assets/../../etc/passwd", None),
                                  ("absolute", "/assets/x", None),
                                  ("symlink", "assets/link", 0o120777),
                                  ("world", "assets/open", 0o100666)):
            with self.subTest(label=label):
                apk = self.root / f"{label}.apk"
                with zipfile.ZipFile(apk, "w") as container:
                    info = zipfile.ZipInfo(name)
                    if mode:
                        info.external_attr = mode << 16
                    container.writestr(info, b"x")
                    container.writestr("classes.dex", b"x")
                with self.assertRaisesRegex(A.ReleaseArtifactError,
                                            "traversal entry|symlink entry|"
                                            "world-writable entry"):
                    self.judge(apk)
        signed = self.root / "signed.apk"
        A._write_synthetic_apk(signed, abis=("arm64-v8a",), page_size=A.PAGE_SIZE_16K)
        with zipfile.ZipFile(signed, "a") as container:
            container.writestr("META-INF/CERT.RSA", b"signature")
        report = self.judge(signed)
        self.assertTrue(report["signature"]["signed"])
        self.assertEqual("PASS", report["verdict"])
        self.assertFalse(self.judge(self.apk())["signature"]["signed"])

    def test_w18_the_device_claims_are_unverified_and_the_doors_report(self):
        apk = self.apk()
        report = self.judge(apk)
        for key in ("installed_min_api26", "installed_current_target", "fts5_query",
                    "offline_start"):
            self.assertIn("UNVERIFIED", report["device"][key])
        self.assertIn("external evidence", report["device"]["note"])
        again = self.judge(apk)
        self.assertEqual(A.canonical(report), A.canonical(again))

        def door(argv):
            captured = io.StringIO()
            with contextlib.redirect_stdout(captured):
                code = A.main(argv)
            return code, captured.getvalue()

        manifest = A._write_manifest(self.root, allow_backup="false")
        rules = A._write_rules(self.root)
        mapping = A._write_mapping(self.root)
        classpath = self.root / "classpath.txt"
        classpath.write_text("+--- io.godstone:core:1.0\n", encoding="utf-8")
        code, said = door([str(apk), "--merged-manifest", str(manifest), "--rules",
                           str(rules), "--mapping", str(mapping), "--dependencies",
                           str(classpath)])
        self.assertEqual(0, code)
        self.assertIn("PASS: source-only-exclusion", said)
        poisoned = self.apk("poisoned.apk", abis=())
        code, said = door([str(poisoned), "--merged-manifest", str(manifest), "--rules",
                           str(rules), "--mapping", str(mapping), "--dependencies",
                           str(classpath)])
        self.assertEqual(1, code)
        self.assertIn("FAIL: refused", said)
        self.assertIn("::error::", said)
        self.assertEqual(0, door(["--selftest"])[0])
        self.assertEqual(1, door([str(self.root / "absent.apk")])[0])
        out = self.root / "reports"
        out.mkdir()
        code, _said = door([str(apk), "--merged-manifest", str(manifest), "--rules",
                            str(rules), "--mapping", str(mapping), "--dependencies",
                            str(classpath), "--out", str(out)])
        self.assertEqual(0, code)
        document = json.loads((out / "android-release-report.json").read_text())
        for key in ("apk", "AAB", "classpaths", "manifest", "ABI", "pageSize", "R8",
                    "approvedArchive"):
            self.assertIn(key, document)


if __name__ == "__main__":
    unittest.main()
