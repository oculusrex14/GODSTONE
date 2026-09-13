from __future__ import annotations

import contextlib
import hashlib
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from content.archive_manifest import create_manifest, generate_test_keypair, load_private_key
from content.tests.archive_fixtures import write_archive
from scripts import prepare_release_assets as assets


class ReleaseAssetTests(unittest.TestCase):
    """T51 (s17): the intake gate. Every refusal must precede every write;
    the approved-resource manifest is published only after a successful
    staging; the trust is the operator's to select, never the bundle's to
    name. The sentinels below are the previous authoritative bytes: each
    failing path is tried against them and they must not move."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        self.archive = self.inputs / "archive_light.db"
        write_archive(self.archive, reviewed=True)
        # The operator's trust root is intentionally outside the input bundle.
        self.private = self.root / "test.key"
        self.trust = self.root / "operator-trust.json"
        generate_test_keypair(self.private, self.trust)
        self.signed = self.inputs / "archive.manifest.json"
        self.manifest = self.inputs / "assets.json"
        self.output = self.root / "output"
        self.output.mkdir()
        self.previous = b"previous usable archive"
        self.previous_manifest = b'{"previous": "manifest"}\n'
        (self.output / "archive_light.db").write_bytes(self.previous)
        (self.output / assets.APPROVED_MANIFEST_NAME).write_bytes(self.previous_manifest)
        self.refresh()

    def refresh(self):
        create_manifest(
            self.archive, self.signed, tier="LIGHT", archive_schema=3,
            source_manifest_sha256="1" * 64, review_manifest_sha256="2" * 64,
            corpus_manifest_sha256="3" * 64, build_tool_commit="b" * 40,
            private_key=load_private_key(self.private), key_id="TEST-ONLY",
        )
        self.data = {
            "schema": 1, "tier": "LIGHT", "application_id": "io.godstone.app",
            "status": "approved", "production_ready": True,
            "archive_manifest": self.signed.name,
            "assets": [{
                "role": "archive", "name": "archive_light.db", "source": self.archive.name,
                "bytes": self.archive.stat().st_size,
                "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            }],
        }
        self.save()

    def save(self):
        self.manifest.write_text(json.dumps(self.data))

    def stage(self, output=None):
        assets.stage(self.manifest, output or self.output, trust_store_path=self.trust)

    def assert_preserved(self):
        self.assertEqual(self.previous, (self.output / "archive_light.db").read_bytes())
        self.assertEqual(self.previous_manifest,
                         (self.output / assets.APPROVED_MANIFEST_NAME).read_bytes())
        self.assertEqual({"inputs", "test.key", "operator-trust.json", "output"},
                         {p.name for p in self.root.iterdir()})

    # -- the happy way, and the refusals that keep it happy ---------------

    def test_valid_signed_archive_atomically_replaces_previous_file(self):
        self.stage()
        self.assertEqual(self.archive.read_bytes(), (self.output / "archive_light.db").read_bytes())
        self.assertEqual({"archive_light.db", assets.APPROVED_MANIFEST_NAME},
                         {p.name for p in self.output.iterdir()})

    def test_signed_development_archive_cannot_be_staged(self):
        self.archive.unlink()
        write_archive(self.archive, reviewed=False)
        self.refresh()
        with self.assertRaisesRegex(ValueError, "production review provenance"):
            self.stage()
        self.assert_preserved()

    def test_production_digests_must_match_signed_manifest(self):
        with contextlib.closing(sqlite3.connect(self.archive)) as db, db:
            db.execute("UPDATE archive_meta SET value=? WHERE key='review_manifest_sha256'", ("a" * 64,))
        self.refresh()
        with self.assertRaisesRegex(ValueError, "signed production provenance mismatch"):
            self.stage()
        self.assert_preserved()

    def test_manifest_cannot_select_its_own_trust_root(self):
        self.data["archive_trust_store"] = "attacker-trust.json"
        generate_test_keypair(self.inputs / "attacker.key", self.inputs / "attacker-trust.json")
        create_manifest(
            self.archive, self.signed, tier="LIGHT", archive_schema=3,
            source_manifest_sha256="1" * 64, review_manifest_sha256="2" * 64,
            corpus_manifest_sha256="3" * 64, build_tool_commit="b" * 40,
            private_key=load_private_key(self.inputs / "attacker.key"), key_id="TEST-ONLY",
        )
        self.save()
        # The bundle now carries both its own signature and a matching trust
        # file. Only the independently selected operator key is authoritative;
        # the manifest naming its own trust is itself an error.
        with self.assertRaisesRegex(ValueError, "signature verification failed"):
            self.stage()
        with self.assertRaisesRegex(ValueError, "never by the manifest"):
            self.stage()
        self.assertEqual(self.previous, (self.output / "archive_light.db").read_bytes())

    def test_role_and_name_mapping_rejects_models_and_cross_tier_assets(self):
        for role, name in (("archive", "generation.gguf"), ("generation_model", "archive_light.db"),
                           ("archive", "archive_medium.db")):
            with self.subTest(role=role, name=name):
                self.data["assets"][0].update(role=role, name=name)
                self.save()
                with self.assertRaisesRegex(ValueError, "role/name mismatch"):
                    self.stage()
                self.assert_preserved()

    def test_additional_model_asset_is_rejected(self):
        self.data["assets"].append(dict(self.data["assets"][0], role="generation_model", name="generation.gguf"))
        self.save()
        with self.assertRaisesRegex(ValueError, "no other assets"):
            self.stage()
        self.assert_preserved()

    def test_path_escape_and_absolute_input_paths_are_rejected(self):
        for field, value in (("source", "../operator-trust.json"),
                             ("source", str(self.archive)),
                             ("archive_manifest", "../operator-trust.json")):
            with self.subTest(field=field, value=value):
                self.refresh()
                if field == "source":
                    self.data["assets"][0][field] = value
                else:
                    self.data[field] = value
                self.save()
                with self.assertRaisesRegex(ValueError, "escapes manifest directory|relative file path"):
                    self.stage()
                self.assert_preserved()

    def test_symlink_input_cannot_escape_manifest_directory(self):
        link = self.inputs / "outside.db"
        link.symlink_to(self.trust)
        self.data["assets"][0]["source"] = link.name
        self.save()
        with self.assertRaisesRegex(ValueError, "escapes manifest directory"):
            self.stage()
        self.assert_preserved()

    def test_corrupt_source_preserves_existing_output(self):
        self.archive.write_bytes(b"corrupt")
        with self.assertRaisesRegex(ValueError, "size mismatch|SHA-256 mismatch"):
            self.stage()
        self.assert_preserved()

    def test_copy_failure_preserves_existing_output(self):
        with patch.object(assets.shutil, "copyfile", side_effect=OSError("disk full")):
            with self.assertRaisesRegex(OSError, "disk full"):
                self.stage()
        self.assert_preserved()

    def test_source_mutation_during_copy_preserves_existing_output(self):
        def changed_copy(source, destination):
            Path(destination).write_bytes(b"changed during staging")
        with patch.object(assets.shutil, "copyfile", side_effect=changed_copy):
            with self.assertRaisesRegex(ValueError, "changed during staging"):
                self.stage()
        self.assert_preserved()

    def test_publish_failure_preserves_existing_output(self):
        with patch.object(assets.os, "replace", side_effect=OSError("publish failed")):
            with self.assertRaisesRegex(OSError, "publish failed"):
                self.stage()
        self.assert_preserved()

    def test_output_directory_symlink_is_rejected(self):
        link = self.root / "output-link"
        link.symlink_to(self.output, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "must not be a symlink"):
            self.stage(link)
        self.assertEqual(self.previous, (self.output / "archive_light.db").read_bytes())

    def test_output_file_symlink_is_rejected(self):
        target = self.output / "archive_light.db"
        target.unlink()
        (self.output / assets.APPROVED_MANIFEST_NAME).unlink()
        target.symlink_to(self.trust)
        previous_trust = self.trust.read_bytes()
        with self.assertRaisesRegex(ValueError, "overwrite the trust store|unexpected entries"):
            self.stage()
        self.assertEqual(previous_trust, self.trust.read_bytes())

    def test_unexpected_destination_content_is_never_deleted(self):
        extra = self.output / "important.txt"
        extra.write_text("keep me")
        with self.assertRaisesRegex(ValueError, "unexpected entries"):
            self.stage()
        self.assertEqual("keep me", extra.read_text())
        self.assert_preserved()

    def test_output_cannot_overwrite_input_bundle(self):
        before = self.archive.read_bytes()
        with self.assertRaisesRegex(ValueError, "must not contain the input manifest"):
            self.stage(self.inputs)
        self.assertEqual(before, self.archive.read_bytes())
        self.assert_preserved()

    # -- the new law: the approved-resource manifest itself -----------------

    def test_approved_manifest_is_published_only_after_the_archive(self):
        # A clean destination: neither file is there before; both appear, and
        # the manifest's bytes describeth exactly the staged archive.
        (self.output / "archive_light.db").unlink()
        (self.output / assets.APPROVED_MANIFEST_NAME).unlink()
        self.stage()
        published = json.loads((self.output / assets.APPROVED_MANIFEST_NAME).read_text())
        self.assertEqual(published["schema"], assets.APPROVED_MANIFEST_SCHEMA)
        self.assertEqual(published["tier"], "LIGHT")
        self.assertEqual(published["application_id"], "io.godstone.app")
        self.assertEqual(len(published["assets"]), 1)
        entry = published["assets"][0]
        self.assertEqual(entry["role"], "archive")
        self.assertEqual(entry["name"], "archive_light.db")
        self.assertEqual(entry["sha256"], hashlib.sha256(self.archive.read_bytes()).hexdigest())
        self.assertEqual(entry["bytes"], self.archive.stat().st_size)
        self.assertEqual(entry["build_phase"], "resources")
        # the bytes behind the manifest are the bytes it names
        self.assertEqual((self.output / "archive_light.db").read_bytes(), self.archive.read_bytes())

    def test_approved_manifest_bytes_are_deterministic(self):
        self.stage()
        first = (self.output / assets.APPROVED_MANIFEST_NAME).read_bytes()
        self.stage()
        second = (self.output / assets.APPROVED_MANIFEST_NAME).read_bytes()
        self.assertEqual(first, second)
        self.assertEqual(first,
                         (json.dumps(assets._approved_manifest_document(self.data),
                                      sort_keys=True, indent=2, ensure_ascii=False) + "\n").encode())

    def test_failure_never_publishes_a_manifest_to_a_clean_destination(self):
        (self.output / "archive_light.db").unlink()
        (self.output / assets.APPROVED_MANIFEST_NAME).unlink()
        self.data["status"] = "draft"
        self.save()
        with self.assertRaisesRegex(ValueError, "not approved for production"):
            self.stage()
        self.assertEqual([], list(self.output.iterdir()))

    def test_check_only_validates_without_publishing(self):
        data, staged = assets.validate(self.manifest, trust_store_path=self.trust)
        self.assertEqual(len(staged), 1)
        self.assertEqual(data["tier"], "LIGHT")
        self.assert_preserved()   # the sentinels: check-only toucheth nothing


if __name__ == "__main__":
    unittest.main()
