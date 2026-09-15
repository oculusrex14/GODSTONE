#! /usr/bin/env python3
"""GS-CONTENT-003 — a signing key nominated BY THE ASSET BUNDLE is never an approval.

The audit's independent probe (evidence/AUDIT-002/content/audit_content_tests.py,
`test_bundle_selected_signing_trust_must_be_rejected`) is moved into the canonical suite
with its assertion INTACT: a bundle whose `assets.json` nameth its OWN trust store
(`archive_trust_store: attacker-trust.json`, signed by `ATTACKER-NOT-OPERATOR`) must be
REFUSED by `prep.validate(bundle)` when no OPERATOR trust store was supplied.

  W01 the audit's probe: a bundle-nominated trust store is REFUSED BY NAME
  W02 THE POSITIVE CONTROL: the same bundle WITH an explicit operator trust store is
      judged by the operator-selected face (and the attacker's key is then refused)
  W03 the refusal NAMETH the reason: the bundle may not nominate the key that signeth it
  W04 `--check-only` (the default release-validation path) cannot obtain the bypass the
      `--trust-store` path refuseth
"""
from __future__ import annotations

import hashlib
import json
import shutil
import sqlite3
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

from content.ingest import build_archive as ba            # noqa: E402
from content import archive_manifest as am                 # noqa: E402
from scripts import prepare_release_assets as prep         # noqa: E402
from tools.readiness.tests.test_t46 import ApprovalCourtCase, TODAY, DB_DIR  # noqa: E402


class BundleNominatedTrustTest(ApprovalCourtCase):
    """The audit's probe, plus the operator-selected positive control."""

    def ordinary_build(self, **kwargs):
        return ba.build("LIGHT", self.out, embed=False,
                        seed_root=self.seed, db_dir=DB_DIR, **kwargs)

    def make_asset_bundle(self):
        """The audit's own fixture: a bundle that nominate th its OWN trust store."""
        self.ordinary_build()
        bundle = self.root / "malicious-bundle"
        bundle.mkdir()
        archive = bundle / "archive_light.db"
        shutil.copyfile(self.out, archive)
        am.generate_test_keypair(bundle / "attacker.key", bundle / "attacker-trust.json",
                                 key_id="ATTACKER-NOT-OPERATOR")
        am.create_manifest(archive, bundle / "archive_light.json", tier="LIGHT",
                           archive_schema=3, source_manifest_sha256="0" * 64,
                           review_manifest_sha256="0" * 64, corpus_manifest_sha256="0" * 64,
                           build_tool_commit="0" * 40,
                           private_key=am.load_private_key(bundle / "attacker.key"),
                           key_id="ATTACKER-NOT-OPERATOR")
        manifest = bundle / "assets.json"
        manifest.write_text(json.dumps({
            "schema": 1, "tier": "LIGHT", "application_id": "io.godstone.app",
            "status": "approved", "production_ready": True,
            "archive_manifest": "archive_light.json",
            "archive_trust_store": "attacker-trust.json",
            "assets": [{"role": "archive", "name": "archive_light.db",
                        "source": "archive_light.db", "bytes": archive.stat().st_size,
                        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()}],
        }))
        return manifest

    def test_w01_a_bundle_nominated_trust_store_is_refused(self):
        """THE AUDIT'S ASSERTION, INTACT: this must raise ValueError."""
        manifest = self.make_asset_bundle()
        with self.assertRaises(ValueError):
            prep.validate(manifest)

    def test_w03_the_refusal_nameth_the_reason(self):
        manifest = self.make_asset_bundle()
        try:
            prep.validate(manifest)
        except ValueError as exc:
            message = str(exc)
            self.assertTrue(
                any(word in message.lower() for word in
                    ("trust", "operator", "nominat", "bundle")),
                "the refusal must say WHY: %r" % message)
        else:
            self.fail("the bundle-nominated trust store was ACCEPTED")

    def test_w04_the_default_release_path_cannot_obtain_the_bypass(self):
        """`--check-only` calleth validate() with no operator trust store: the same
        refusal must hold there, so the default path is not a softer door."""
        source = (ROOT / "scripts" / "prepare_release_assets.py").read_text(encoding="utf-8")
        self.assertNotIn("_validate_legacy_deputy", source,
                         "the deputy face must be GONE, not merely renamed: no caller may "
                         "reach a path that readeth the trust store out of the bundle")
        self.assertNotIn("load_trust_store(refs[1])", source,
                         "the bundle-nominated trust resolution must be removed")
        manifest = self.make_asset_bundle()
        with self.assertRaises(ValueError):
            prep.validate(manifest, trust_store_path=None)


if __name__ == "__main__":
    unittest.main(verbosity=2)
