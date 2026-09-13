#! /usr/bin/env python3
"""T52 readiness court: the presence inspector must not masquerade as exclusion.

The card's law: an exclusion-only binary check can succeed on an app that
containeth no usable archive. The court therefore trieth the three lanes
apart and requireth each gate by name:

  W01 the exclusion lane passeth a clean light package and publisheth
  W02 absence is REPORTED, never claimed as content (the card's heart)
  W03 the sealed prohibitions still stand in the exclusion lane (four shapes)
  W04 the presence lane requireth the archive to be there
  W05 changed bytes are refused as stale
  W06 the empty husk is refused
  W07 duplicate ZIP entries are refused
  W08 symlink entries are refused
  W09 traversal names are refused
  W10 world-writable entries are refused
  W11 the usable archive is sworn into the report (integrity/tier/counts/fts)
  W12 fixture marks are recorded in debug presence (not yet forbidden)
  W13 the release lane prohibiteth the fixture's prose
  W14 lying counts metadata are refused
  W15 the unrestorable FTS5 index is refused
  W16 the husk that is no database at all is refused (byte-match and all)
  W17 the road requireth the bundled engine (libsqliteJ*)
  W18 the road requireth the dex
  W19 the cross-tier masquerade is refused in both lanes
  W20 the AAB and the APK differ by their canonical paths (four shapes)
  W21 the IPA carrieth executable, plist and archive (four shapes)
  W22a the artifact inventory is deterministic in its record structure
  W22b the presence report is deterministic and fully shaped
  W23 the stale publication is refused at the gate (manifest vs staged file)
  W24 future schemas and false witnesses are refused by the loader (four)
  W25 the merged manifest's grants are scanned (granteth; removal tolerated)
  W26 no artifacts, no verdict, no publication
  W27 the release lane requireth an expected truth
  W28 the inspector's own selftest speaketh for itself
  W29 the deputy face of the staging gate readeth the document's pointers
      with its own named guard (and the operator face doth not share the phrase)
  W30 the operator face still refuseth self-nomination by name (the T51 law)
  W31 the CLI deputy face runneth without the flag; staging still demandeth it
  W32 the gates checker refuseth all twelve controls by name
  W33 the integration checker counteth its faces truthfully

All worlds are built in temporary regions upon harmless, visibly labelled
development bytes (app-navigation prose only). No clinical or survival
content is proven; readiness stays false; no external gate is closed.
"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

from scripts import inspect_android_artifacts as ins  # noqa: E402
from scripts import prepare_release_assets as prep  # noqa: E402

ENGINE = f"lib/arm64-v8a/{ins.BUNDLED_ENGINE_PREFIX}ni.so"


def _make_noindex_archive() -> bytes:
    """A valid-looking archive whose FTS5 index was never restored."""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "archive_light.db"
        with contextlib.closing(sqlite3.connect(path)) as db, db:
            db.executescript((REPO / "content/db/schema.sql").read_text(encoding="utf-8"))
            db.execute(
                "INSERT INTO documents (document_id, title, domain, source_id, licence, "
                "revision, tier_min, reading_level, is_critical) "
                "VALUES (1, 'Reading the river', 'water', 'src-t', 'CC0', 'r1', 'LIGHT', 8, 1)")
            db.execute(
                "INSERT INTO chunks (chunk_id, document_id, ordinal, section, text, token_count) "
                "VALUES (1, 1, 0, 'Bank', 'The quick brown fox jaunts by the riverbank.', 8)")
            db.executemany("INSERT INTO archive_meta (key, value) VALUES (?, ?)",
                          sorted({"schema_version": "3", "tier": "LIGHT",
                                 "document_count": "1", "chunk_count": "1"}.items()))
            # the virtual table stands, its shadow was never restored by indexes.sql:
            # the index existeth in name only and must be refused as unrestorable
            db.execute("DROP TABLE chunks_fts")
        return path.read_bytes()


class T52PresenceCourt(unittest.TestCase):
    maxDiff = None  # the whole log is ours; summaries print by name

    # -- world helpers -------------------------------------------------------
    def _apk_entries(self, archive: bytes | None) -> dict[str, bytes]:
        entries = {"classes.dex": b"dex\n", "lib/arm64-v8a/libcore.so": b"\x7fELF stub",
                   ENGINE: b"\x7fELF engine"}
        if archive is not None:
            entries[ins.CANONICAL_ARCHIVE[".apk"]] = archive
        return entries

    def _run(self, build: Path, out: Path, expected: Path | None = None,
             manifest: Path | None = None, release: bool = False):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc, inv = ins.inspect(build, out, expected, manifest, release)
        return rc, buf.getvalue(), inv

    def _report_of(self, out: Path, index: int = 0) -> dict:
        presence = json.loads((out / "approved-archive-presence.json").read_text(encoding="utf-8"))
        return presence["artifacts"][index]

    def _swear(self, root: Path, good: bytes, **over) -> Path:
        asset = {"role": "archive", "name": "archive_light.db",
                 "sha256": hashlib.sha256(good).hexdigest(), "bytes": len(good),
                 "build_phase": "resources"}
        if "sha" in over:
            asset["sha256"] = over["sha"]
        if "size" in over:
            asset["bytes"] = over["size"]
        for key, value in over.items():
            if key in asset and key not in ("sha", "size"):
                asset[key] = value
        document = {"schema": over.get("schema", 1), "tier": over.get("tier", "LIGHT"),
                    "application_id": over.get("application_id", "io.godstone.app"),
                    "generated_by": "scripts/prepare_release_assets.py",
                    "assets": over["assets"] if "assets" in over else [asset]}
        path = root / "APPROVED_ASSETS.json"
        path.write_text(json.dumps(document, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        return path

    def _world(self, td: str, entries: dict[str, bytes], *, name: str = "app.apk",
               **pkg_kwargs) -> tuple[Path, Path, Path]:
        root = Path(td)
        build = root / "build"
        build.mkdir(parents=True, exist_ok=True)
        ins._make_package(build / name, entries, **pkg_kwargs)
        return root, build, root / "out"

    # -- W01/W02 the exclusion lane ------------------------------------------
    def testTheExclusionLanePassethACleanLightPackage(self):
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(None))
            rc, _text, inv = self._run(build, out)
            self.assertEqual(rc, 0)
            self.assertEqual(len(inv), 1)
            self.assertTrue((out / "artifact-inventory.json").is_file())
            presence = json.loads((out / "approved-archive-presence.json")
                                  .read_text(encoding="utf-8"))
            self.assertEqual(presence["verdict"], "pass")
            self.assertEqual(presence["evidence"], "source-only-exclusion")
            self.assertEqual(presence["expected_sha256"], None)   # nothing was sworn

    def testAbsenceIsReportedNotClaimed(self):
        with tempfile.TemporaryDirectory() as td:
            _root, build, out = self._world(td, self._apk_entries(None))
            rc, _text, _inv = self._run(build, out)
            self.assertEqual(rc, 0)
            report = self._report_of(out)
            self.assertEqual(report["status"], "absent")
            self.assertEqual(report["entries_found"], 0)
            self.assertIsNone(report["sha256"])
            self.assertIsNone(report["integrity"])   # no probe ran upon an absence
            self.assertEqual(report["evidence"], "source-only-exclusion")

    def testTheExclusionLaneStillDeferencethTheSealedProhibitions(self):
        for label, extra in (
                ("model weight", {"assets/qwen3-0.6b-q4km.gguf": b"x"}),
                ("llm bridge", {"lib/arm64-v8a/libgodstone_llm.so": b"x"}),
                ("llama native", {"lib/arm64-v8a/libllama.so": b"x"}),
                ("cross tier archive", {"assets/archive_medium.db": b"x"})):
            with self.subTest(marker=label):
                with tempfile.TemporaryDirectory() as td:
                    _root, build, out = self._world(td, {**self._apk_entries(None), **extra})
                    rc, text, _inv = self._run(build, out)
                    self.assertEqual(rc, 1)
                    self.assertIn("inspection FAILED", text)

    # -- W04..W10 the gates, one blow each ------------------------------------
    def testPresenceLaneRequirethTheArchive(self):
        good = ins._make_archive_bytes()
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(None))
            exp = root / "archive_light.db"
            exp.write_bytes(good)
            rc, text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 1)
            self.assertIn("the expected Archive is absent from the package", text)

    def testChangedBytesAreRefusedAsStale(self):
        good = ins._make_archive_bytes()
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(b"tampered database bytes"))
            exp = root / "archive_light.db"
            exp.write_bytes(good)
            rc, text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 1)
            self.assertIn("SHA-256 differeth", text)

    def testEmptyHuskIsRefused(self):
        good = ins._make_archive_bytes()
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(b""))
            exp = root / "archive_light.db"
            exp.write_bytes(good)
            rc, text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 1)
            self.assertIn("the packaged Archive is empty", text)

    def testDuplicateZipEntriesAreRefused(self):
        good = ins._make_archive_bytes()
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(good),
                                          dupe=ins.CANONICAL_ARCHIVE[".apk"])
            exp = root / "archive_light.db"
            exp.write_bytes(good)
            rc, text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 1)
            self.assertIn("duplicate ZIP entries", text)

    def testSymlinkEntriesAreRefused(self):
        good = ins._make_archive_bytes()
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(good),
                                           symlink="assets/evil.db")
            exp = root / "archive_light.db"
            exp.write_bytes(good)
            rc, text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 1)
            self.assertIn("symlink entries are prohibited", text)

    def testTraversalNamesAreRefused(self):
        good = ins._make_archive_bytes()
        for label, rogue in (("dot-dot", "../escapeMe"), ("absolute", "/etc/passwd")):
            with self.subTest(marker=label):
                with tempfile.TemporaryDirectory() as td:
                    root, build, out = self._world(td, {**self._apk_entries(good), rogue: b"x"})
                    exp = root / "archive_light.db"
                    exp.write_bytes(good)
                    rc, text, _inv = self._run(build, out, exp)
                    self.assertEqual(rc, 1)
                    self.assertIn("traversal entry names are prohibited", text)

    def testWorldWritableEntriesAreRefused(self):
        good = ins._make_archive_bytes()
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(good), writable_mode=True)
            exp = root / "archive_light.db"
            exp.write_bytes(good)
            rc, text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 1)
            self.assertIn("dangerous entry modes", text)

    # -- W11/W12 the sworn report ---------------------------------------------
    def testTheUsableArchiveIsSwornIntoTheReport(self):
        good = ins._make_archive_bytes()
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(good))
            exp = root / "archive_light.db"
            exp.write_bytes(good)
            rc, _text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 0)
            report = self._report_of(out)
            self.assertEqual(report["status"], "byte-matched")
            self.assertEqual(report["entry"], "assets/archive_light.db")
            self.assertEqual(report["entries_found"], 1)
            self.assertEqual(report["integrity"], "ok")
            self.assertEqual(report["tier"], "LIGHT")
            self.assertEqual(report["schema_version"], "3")
            self.assertEqual(report["counts"], {"documents": 1, "chunks": 1})
            self.assertEqual(report["declared_counts"], {"documents": "1", "chunks": "1"})
            self.assertEqual(report["fts"], "ok")
            self.assertEqual(report["sha256"], hashlib.sha256(good).hexdigest())
            self.assertEqual(report["expected_sha256"], hashlib.sha256(good).hexdigest())
            self.assertEqual(report["errors"], [])

    def testFixtureMarksAreRecordedInDebugPresence(self):
        fixture = ins._make_archive_bytes(fixture=True)
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(fixture))
            exp = root / "archive_light.db"
            exp.write_bytes(fixture)
            rc, _text, _inv = self._run(build, out, exp)      # debug lane: release=False
            self.assertEqual(rc, 0)
            report = self._report_of(out)
            self.assertEqual(report["status"], "byte-matched")
            self.assertTrue(report["fixture_marker_found"])
            self.assertTrue(report["development_fixture_key"])

    def testTheReleaseLaneProhibitethTheFixturesProse(self):
        fixture = ins._make_archive_bytes(fixture=True)
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(fixture))
            exp = root / "archive_light.db"
            exp.write_bytes(fixture)
            rc, text, _inv = self._run(build, out, exp, None, True)
            self.assertEqual(rc, 1)
            self.assertIn("packaged as production (prose marker in the bytes)", text)

    # -- W14..W16 the deeper probes -------------------------------------------
    def testLyingCountsAreRefused(self):
        liar = ins._make_archive_bytes(lying_counts=True)
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(liar))
            exp = root / "archive_light.db"
            exp.write_bytes(liar)
            rc, text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 1)
            self.assertIn("the counts metadata lieth", text)

    def testTheUnrestorableIndexIsRefused(self):
        husk = _make_noindex_archive()
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(husk))
            exp = root / "archive_light.db"
            exp.write_bytes(husk)
            rc, text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 1)
            self.assertIn("the FTS5 index is unrestorable", text)

    def testTheHuskThatIsNoDatabaseAtAllIsRefused(self):
        corrupt = b"pretendeth to be a database, yet is but noise"
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(corrupt))
            exp = root / "archive_light.db"
            exp.write_bytes(corrupt)                  # byte-true... and still no database
            rc, text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 1)
            self.assertIn("no database", text)

    # -- W17/W18 the road's own furniture -------------------------------------
    def testTheRoadRequirethTheBundledEngine(self):
        good = ins._make_archive_bytes()
        entries = {"classes.dex": b"dex\n", "lib/arm64-v8a/libcore.so": b"\x7fELF stub",
                   ins.CANONICAL_ARCHIVE[".apk"]: good}
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, entries)
            exp = root / "archive_light.db"
            exp.write_bytes(good)
            rc, text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 1)
            self.assertIn("the resolved bundled engine is absent", text)

    def testTheRoadRequirethTheDex(self):
        good = ins._make_archive_bytes()
        entries = {"lib/arm64-v8a/libcore.so": b"\x7fELF stub", ENGINE: b"\x7fELF engine",
                   ins.CANONICAL_ARCHIVE[".apk"]: good}
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, entries)
            exp = root / "archive_light.db"
            exp.write_bytes(good)
            rc, text, _inv = self._run(build, out, exp)
            self.assertEqual(rc, 1)
            self.assertIn("the package carrieth no dex", text)

    # -- W19/W20/W21 the shapes ------------------------------------------------
    def testTheCrossTierMasqueradeIsRefused(self):
        medium = ins._make_archive_bytes(tier="MEDIUM")
        for label, kwargs in (("presence lane", dict(expected_set=True)),
                             ("exclusion lane", dict(expected_set=False))):
            with self.subTest(marker=label):
                with tempfile.TemporaryDirectory() as td:
                    root, build, out = self._world(td, self._apk_entries(medium))
                    exp = None
                    if kwargs["expected_set"]:
                        exp = root / "archive_light.db"
                        exp.write_bytes(medium)
                    rc, text, _inv = self._run(build, out, exp)
                    self.assertEqual(rc, 1)
                    self.assertIn("cross-tier archive", text)

    def testTheAabAndApkDifferByTheirCanonicalPaths(self):
        good = ins._make_archive_bytes()
        aab_ok = {"base/classes.dex": b"dex\n", "base/lib/arm64-v8a/libcore.so": b"E",
                  f"base/lib/arm64-v8a/{ins.BUNDLED_ENGINE_PREFIX}ni.so": b"E",
                  ins.CANONICAL_ARCHIVE[".aab"]: good}
        cases = (
            ("aab at its base path", aab_ok, "app.aab", True),
            ("aab with the apk-shaped path",
             {**{k: v for k, v in aab_ok.items() if k != ins.CANONICAL_ARCHIVE[".aab"]},
              "assets/archive_light.db": good},
             "app.aab", False),
            ("apk at its assets path", self._apk_entries(good), "app.apk", True),
            ("apk with the aab-shaped path",
             {**{k: v for k, v in self._apk_entries(None).items()},
              "base/assets/archive_light.db": good}, "app.apk", False))
        for label, entries, name, should_pass in cases:
            with self.subTest(marker=label):
                with tempfile.TemporaryDirectory() as td:
                    root, build, out = self._world(td, entries, name=name)
                    exp = root / "archive_light.db"
                    exp.write_bytes(good)
                    rc, _text, _inv = self._run(build, out, exp)
                    self.assertEqual(rc == 0, should_pass)

    def testTheIpaCarriethExecutablePlistAndArchive(self):
        good = ins._make_archive_bytes()
        plist_ok = b"<plist><key>CFBundleExecutable</key><string>Godstone</string></plist>"
        full = {ins.IPA_EXECUTABLE: b"Mach-O image bytes", ins.IPA_INFO_PLIST: plist_ok,
                ins.CANONICAL_ARCHIVE[".ipa"]: good}
        cases = (
            ("whole bundle", full, True, ""),
            ("wanting the plist", {ins.IPA_EXECUTABLE: b"image",
                                  ins.CANONICAL_ARCHIVE[".ipa"]: good},
             False, "wanteth its embedded Info.plist"),
            ("plist denying the executable key",
             {**full, ins.IPA_INFO_PLIST: b"<plist><key>CFBundleName</key></plist>"},
             False, "denieth CFBundleExecutable"),
            ("empty executable", {**full, ins.IPA_EXECUTABLE: b""},
             False, "executable is empty"))
        for label, entries, should_pass, needle in cases:
            with self.subTest(marker=label):
                with tempfile.TemporaryDirectory() as td:
                    root, build, out = self._world(td, entries, name="Godstone.ipa")
                    exp = root / "archive_light.db"
                    exp.write_bytes(good)
                    rc, text, _inv = self._run(build, out, exp)
                    self.assertEqual(rc == 0, should_pass)
                    if needle:
                        self.assertIn(needle, text)

    # -- W22a/W22b publication is honest ---------------------------------------
    def testTheArtifactInventoryIsDeterministicInItsRecordStructure(self):
        good = ins._make_archive_bytes()
        readings = []
        first_records = None
        for _ in range(2):
            with tempfile.TemporaryDirectory() as td:
                root, build, out = self._world(td, self._apk_entries(good))
                exp = root / "archive_light.db"
                exp.write_bytes(good)
                rc, _text, _inv = self._run(build, out, exp)
                self.assertEqual(rc, 0)
                records = json.loads((out / "artifact-inventory.json").read_text(encoding="utf-8"))
                for record in records:
                    record.pop("path")            # the temporary world's name is not the record
                    record.pop("sha256")           # the container digest carries the zip's clock
                if first_records is None:
                    first_records = records
                readings.append(json.dumps(records, sort_keys=True))
        self.assertEqual(readings[0], readings[1])
        # the order oath: a parse-and-re-dump equality is blind to key ORDER --
        # an unordered publication readeth the same tale twice and no disorder
        # would be seen; the oath requireth the sorted publication at every
        # depth, which the parse preservedeth as the file's own sequence
        for rec in first_records:
            self.assertEqual(list(rec), sorted(rec),
                             "the inventory must be published in sorted key order")
            arch = rec["archive"]
            self.assertEqual(list(arch), sorted(arch),
                             "the presence report must be published in sorted key order")
            self.assertEqual(list(arch["counts"]), sorted(arch["counts"]),
                             "the counts must be published in sorted key order")
            self.assertEqual(list(arch["declared_counts"]), sorted(arch["declared_counts"]),
                             "the declared counts must be published in sorted key order")

    def testThePresenceReportIsDeterministicAndFullyShaped(self):
        good = ins._make_archive_bytes()
        digests = []
        first_shape = None
        for _ in range(2):
            with tempfile.TemporaryDirectory() as td:
                root, build, out = self._world(td, self._apk_entries(good))
                exp = root / "archive_light.db"
                exp.write_bytes(good)
                rc, _text, _inv = self._run(build, out, exp)
                self.assertEqual(rc, 0)
                presence = json.loads((out / "approved-archive-presence.json").read_text(encoding="utf-8"))
                for artifact in presence["artifacts"]:
                    artifact.pop("path")
                digests.append(json.dumps(presence, sort_keys=True))
                first_shape = presence
        self.assertEqual(digests[0], digests[1])
        self.assertEqual(sorted(first_shape),
                         ["artifacts", "evidence", "expected_sha256", "schema", "verdict"])
        self.assertEqual(first_shape["schema"], 1)
        self.assertEqual(first_shape["verdict"], "pass")
        self.assertEqual(list(first_shape), sorted(first_shape),
                         "the presence report must be published in sorted key order")
        art = first_shape["artifacts"][0]
        self.assertEqual(list(art), sorted(art),
                         "the artifact record must be published in sorted key order")
        self.assertEqual(list(art["counts"]), sorted(art["counts"]),
                         "the counts must be published in sorted key order")
        self.assertEqual(list(art["declared_counts"]), sorted(art["declared_counts"]),
                         "the declared counts must be published in sorted key order")
        promised = {"bytes", "counts", "declared_counts", "dangerous_modes",
                    "development_fixture_key", "dex_entries", "duplicate_entries",
                    "entries_found", "entry", "errors", "evidence", "expected_sha256",
                    "fixture_marker_found", "fts", "integrity", "native_libraries", "radio_grants",
                    "schema_version", "sha256", "status", "symlink_entries", "tier",
                    "traversal_entries"}
        # the record's own fields, plus the kind stamp; 'path' was struck above
        self.assertEqual(sorted(first_shape["artifacts"][0]),
                         sorted(promised | {"kind"}))
        for key in promised:
            self.assertIn(key, first_shape["artifacts"][0])

    # -- W23/W24 the gate before the gate -------------------------------------
    def testTheStalePublicationIsRefusedAtTheGate(self):
        good = ins._make_archive_bytes()
        with tempfile.TemporaryDirectory() as td:
            root, build, out = self._world(td, self._apk_entries(good))
            exp = root / "archive_light.db"
            exp.write_bytes(good)
            manifest = self._swear(root, b"the bytes the manifest sweareth are other bytes")
            rc, text, _inv = self._run(build, out, exp, manifest, True)
            self.assertEqual(rc, 1)
            self.assertIn("stale publication", text)

    def testTheFutureSchemaAndFalseWitnessesAreRefused(self):
        good = ins._make_archive_bytes()
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            cases = (
                ("future schema", lambda: self._swear(root, good, schema=2),
                 "current schema"),
                ("foreign application", lambda: self._swear(root, good,
                                                            application_id="com.evil.corp"),
                 "application identity mismatch"),
                ("twin assets", lambda: self._swear(root, good, assets=[
                    {"role": "archive", "name": "archive_light.db",
                     "sha256": hashlib.sha256(good).hexdigest(), "bytes": len(good),
                     "build_phase": "resources"},
                    {"role": "model", "name": "qwen.gguf",
                     "sha256": hashlib.sha256(good).hexdigest(), "bytes": 1,
                     "build_phase": "resources"}]),
                 "exactly one archive asset"),
                ("uppercase oath", lambda: self._swear(root, good, sha="A" * 64),
                 "lower-case SHA-256"))
            for label, maker, needle in cases:
                with self.subTest(marker=label):
                    path = maker()
                    with self.assertRaises(ValueError) as caught:
                        ins.load_approved_manifest(path)
                    self.assertIn(needle, str(caught.exception))

    # -- W25 the merged manifest's real grants --------------------------------
    def testTheMergedManifestGrantScanIsKept(self):
        good = ins._make_archive_bytes()
        cases = (
            ("granteth INTERNET",
             '<manifest><uses-permission android:name="android.permission.INTERNET"/></manifest>',
             True),
            ("removal tolerated",
             '<manifest><uses-permission android:name="android.permission.INTERNET" '
             'tools:node="remove"/></manifest>', False))
        for label, xml, should_fail in cases:
            with self.subTest(marker=label):
                with tempfile.TemporaryDirectory() as td:
                    root = Path(td)
                    build = root / "build"
                    merged = build / "intermediates/merged_manifests/lightRelease"
                    merged.mkdir(parents=True)
                    (merged / "AndroidManifest.xml").write_text(xml, encoding="utf-8")
                    ins._make_package(build / "app.apk", self._apk_entries(good))
                    exp = root / "archive_light.db"
                    exp.write_bytes(good)
                    rc, text, _inv = self._run(build, root / "out", exp)
                    self.assertEqual(rc != 0, should_fail)
                    if should_fail:
                        self.assertIn("granteth radio/network permission", text)

    # -- W26/W27/W28 ------------------------------------------------------------
    def testNoArtifactsNoVerdictNoPublication(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            build = root / "build"
            build.mkdir()
            out = root / "out"
            rc, _text, inv = self._run(build, out)
            self.assertEqual(rc, 1)
            self.assertEqual(inv, [])
            self.assertFalse((out / "artifact-inventory.json").exists())
            self.assertFalse((out / "approved-archive-presence.json").exists())

    def testTheReleaseLaneRequirethAnExpectedTruth(self):
        good = ins._make_archive_bytes()
        with tempfile.TemporaryDirectory() as td:
            _root, build, out = self._world(td, self._apk_entries(good))
            rc, text, _inv = self._run(build, out, None, None, True)
            self.assertEqual(rc, 1)
            self.assertIn("release-candidate lane requireth an expected Archive", text)

    def testTheSelftestSpeaksForItself(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = ins.selftest()
        self.assertEqual(rc, 0, msg=buf.getvalue()[-800:])

    # -- W29..W31 the two lawful faces of the staging gate (T52 restoration) --
    def _deputy_doc(self, root: Path, *, pointers: bool) -> Path:
        good = ins._make_archive_bytes()
        payload = root / "payload"
        payload.mkdir(parents=True, exist_ok=True)
        source = payload / "archive_light.db"
        source.write_bytes(good)
        document = {"schema": 1, "tier": "LIGHT", "application_id": "io.godstone.app",
                    "status": "approved", "production_ready": True,
                    "assets": [{"role": "archive", "name": "archive_light.db",
                               "source": "payload/archive_light.db",
                               "bytes": len(good), "sha256": hashlib.sha256(good).hexdigest()}]}
        if pointers:
            document["archive_manifest"] = "archive-manifest.json"
            document["archive_trust_store"] = "reviewer-trust.json"
        doc = root / "release.json"
        doc.write_text(json.dumps(document, sort_keys=True), encoding="utf-8")
        return doc

    def testTheDeputyFaceReadethTheDocumentPointersLawfully(self):
        # no pointer fields: the deputy's own named guard must fire, with the
        # deputy's own words (the operator arm's shorter phrase is not this)
        with tempfile.TemporaryDirectory() as td:
            doc = self._deputy_doc(Path(td), pointers=False)
            with self.assertRaises(ValueError) as caught:
                prep.validate(doc)                       # the legacy face
            self.assertIn("signed archive manifest and trust store are required",
                          str(caught.exception))
            with self.assertRaises(ValueError) as caught:
                prep.validate(doc, trust_store_path=Path(td) / "whatever.json")   # operator face
            self.assertNotIn("and trust store are required", str(caught.exception))

    def testTheOperatorFaceStillRefusethSelfNomination(self):
        # the T51 law, byte-identical upon the explicit face: a document that
        # nominateth its own trust root is refused by name, before aught else
        with tempfile.TemporaryDirectory() as td:
            doc = self._deputy_doc(Path(td), pointers=True)
            with self.assertRaises(ValueError) as caught:
                prep.validate(doc, trust_store_path=Path(td) / "reviewer-trust.json")
            self.assertIn("the trust store is selected by the operator, never by the manifest",
                          str(caught.exception))

    def testTheCliDeputyFaceRunnethWithoutTheFlag(self):
        # restoration proved: --trust-store is optional on --check-only (the
        # deputy walketh), and still mandatory for staging (the lock holdeth)
        script = str(REPO / "scripts" / "prepare_release_assets.py")
        with tempfile.TemporaryDirectory() as td:
            doc = self._deputy_doc(Path(td), pointers=False)
            proc = subprocess.run([sys.executable, "-B", script, "--manifest", str(doc),
                                  "--out", str(Path(td) / "out"), "--check-only"],
                                 capture_output=True, text=True, cwd=str(REPO))
            self.assertEqual(proc.returncode, 1, msg=proc.stdout + proc.stderr)
            self.assertNotIn("required: --trust-store", proc.stdout + proc.stderr)
            self.assertIn("release assets rejected", proc.stdout)
            proc = subprocess.run([sys.executable, "-B", script, "--manifest", str(doc),
                                  "--out", str(Path(td) / "out")],
                                 capture_output=True, text=True, cwd=str(REPO))
            self.assertEqual(proc.returncode, 2, msg=proc.stdout + proc.stderr)
            self.assertIn("staging requireth the operator-selected --trust-store",
                          proc.stdout + proc.stderr)

    # -- W32/W33 the checker observers ------------------------------------------
    def testTheGatesCheckerRefusethAllTwelveByName(self):
        proc = subprocess.run([sys.executable, "-B", "ci/check_release_gates_status.py",
                              "--selftest"], capture_output=True, text=True, cwd=str(REPO))
        self.assertEqual(proc.returncode, 0, msg=proc.stdout + proc.stderr)
        self.assertIn("refuseth 12 of 12 malformed/false-closure controls", proc.stdout)

    def testTheEvidenceShapeIsSwornFullLowercaseHex(self):
        # the in-process eye upon the gates checker: a CLOSED gate must carry
        # a full, non-zero, lower-case hexadecimal commit. The sworn shape
        # must stand clean; the forgeries -- non-hex, all-zeroes, upper-case
        # forty-char shapes -- must each be refused, and refused BY NAME.
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "dsh_t52_gates", str(REPO / "ci" / "check_release_gates_status.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        fixture = {"gates": [
            {"gate": name, "status": "CLOSED", "evidence_commit": "a" * 40,
             "ci_job": ("not-runnable-in-ci" if kind == "not-runnable-in-ci"
                        else f"release-gates.yml / {name}")}
            for name, kind in mod.REQUIRED.items()]}
        for gate in fixture["gates"]:
            if gate["ci_job"] == "not-runnable-in-ci":
                gate["closure_requirement"] = "on-device evidence recorded in the field"
        self.assertEqual(mod.validate_status(fixture), [],
                         "the sworn evidence shape must stand clean")
        for name in sorted(mod.REQUIRED):
            for forgery, label in (("z" * 40, "non-hexadecimal"), ("0" * 40, "all-zeroes"),
                                   ("A" * 40, "upper-case")):
                forged = json.loads(json.dumps(fixture))
                for gate in forged["gates"]:
                    if gate["gate"] == name:
                        gate["evidence_commit"] = forgery
                errors = mod.validate_status(forged)
                self.assertTrue(any("full nonzero lowercase" in e for e in errors),
                                f"{name}: the {label} forty-char shape must be refused by"
                                f" name; got {errors}")

    def testTheIntegrationCheckerCountethItsFacesTruthfully(self):
        proc = subprocess.run([sys.executable, "-B", "ci/check_content_release_integration.py"],
                              capture_output=True, text=True, cwd=str(REPO))
        self.assertEqual(proc.returncode, 0, msg=proc.stdout + proc.stderr)
        self.assertIn("3 of 3 faces", proc.stdout)
        self.assertIn("19 of 19 presence faces", proc.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
