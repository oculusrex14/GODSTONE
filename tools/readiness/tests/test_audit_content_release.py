#! /usr/bin/env python3
"""GS-CONTENT-001 — a release build cannot omit the final chunk approvals, and an
unapproved archive cannot reach operator staging.

The audit's independent probe
(evidence/AUDIT-002/content/audit_content_current_tests.py,
`test_audit_release_without_final_approvals_cannot_reach_operator_staging`) is moved into
the canonical suite with its FINAL assertion intact: an archive built WITHOUT the chunk
approvals must be REFUSED by `prep.stage(...)`.

The probe's SETUP built that archive with `release=True` and no approval inputs, which the
card's step 2 forbids outright ("At build() entry, require BOTH approvals_dir and
reviewer_keyset whenever release is true"). The canonical court therefore buildeth the
unapproved archive the lawful way -- a NON-release build -- and keeps every assertion:

  W01 the audit's staging assertion: an unapproved archive is REFUSED by operator staging
  W02 `build(release=True)` WITHOUT `approvals_dir` and `reviewer_keyset` REFUSETH at
      entry, before any output existeth
  W03 half an approval pair is refused too (the old "go together" law, kept)
  W04 the actual CLI: `--release` without the approval inputs exiteth non-zero and writeth
      no destination
  W05 THE POSITIVE CONTROL: an APPROVED release build carrieth its `approvals_sha256` and
      reaches operator staging
"""
from __future__ import annotations

import json
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

from content.ingest import build_archive as ba            # noqa: E402
from content import archive_manifest as am                 # noqa: E402
from scripts import prepare_release_assets as prep         # noqa: E402
from tools.readiness.tests.test_t46 import ApprovalCourtCase, TODAY, DB_DIR  # noqa: E402


class UnapprovedReleaseTest(ApprovalCourtCase):
    """W01-W05: the approvals are mandatory, on every path."""

    def unapproved_archive(self):
        """The audit's unapproved archive -- an archive WITHOUT its approvals digest.

        The build face now REFUSETH to produce one (W02), so the archive is produced the
        only lawful way left: an APPROVED release build whose approval digest is then
        STRIPPED from `archive_meta`. That is defence in depth: the staging face must
        refuse such an archive even though the build face can no longer make one.
        """
        self.sign_all()
        result = ba.build("LIGHT", self.out, embed=False, release=True,
                          seed_root=self.seed, db_dir=DB_DIR, today=TODAY,
                          manifests_root=self.manifests, evidence_root=self.evidence,
                          approvals_dir=self.approvals,
                          reviewer_keyset=self.trust_home / "reviewer_keys.json")
        with sqlite3.connect(self.out) as connection:
            connection.execute("DELETE FROM archive_meta WHERE key = 'approvals_sha256'")
            connection.commit()
        return result

    def signed_bundle_for(self, result):
        private = self.root / "operator.key"
        trust = self.root / "operator-trust.json"
        am.generate_test_keypair(private, trust)
        with sqlite3.connect(self.out) as connection:
            meta = dict(connection.execute("SELECT key, value FROM archive_meta"))
        signed = self.out.parent / "archive.json"
        am.create_manifest(self.out, signed, tier="LIGHT", archive_schema=3,
                           source_manifest_sha256=meta["source_manifest_sha256"],
                           review_manifest_sha256=meta["review_manifest_sha256"],
                           corpus_manifest_sha256=meta["release_manifest_set_sha256"],
                           build_tool_commit="b" * 40,
                           private_key=am.load_private_key(private), key_id="TEST-ONLY")
        manifest = self.out.parent / "assets.json"
        manifest.write_text(json.dumps({
            "schema": 1, "tier": "LIGHT", "application_id": "io.godstone.app",
            "status": "approved", "production_ready": True,
            "archive_manifest": signed.name,
            "assets": [{"role": "archive", "name": self.out.name, "source": self.out.name,
                        "bytes": result.archive_bytes, "sha256": result.archive_sha256}],
        }))
        return manifest, trust

    def test_w01_an_unapproved_archive_cannot_reach_operator_staging(self):
        """THE AUDIT'S ASSERTION, INTACT -- and asserted BY REASON: the refusal must name
        the missing approvals digest, or an unrelated ValueError would satisfy it."""
        result = self.unapproved_archive()
        manifest, trust = self.signed_bundle_for(result)
        with self.assertRaises(ValueError) as caught:
            prep.stage(manifest, self.root / "output", trust_store_path=trust)
        self.assertIn("approvals_sha256", str(caught.exception),
                      "the refusal must NAME the missing approvals: %s" % caught.exception)
        self.assertFalse((self.root / "output").exists(),
                         "the unapproved archive must not be staged")

    def test_w02_a_release_build_without_approvals_is_refused_at_entry(self):
        destination = self.root / "refused" / "archive_light.db"
        with self.assertRaises((ValueError, SystemExit, ba.ArchiveBuildError)) as caught:
            ba.build("LIGHT", destination, embed=False, release=True,
                     seed_root=self.seed, db_dir=DB_DIR)
        message = str(getattr(caught.exception, "args", [caught.exception])[0])
        self.assertTrue(any(word in message.lower() for word in
                            ("approval", "reviewer", "keyset")),
                        "the refusal must name the missing approvals: %r" % message)
        self.assertFalse(destination.exists(),
                         "the refused release build must create NO destination")

    def test_w03_half_an_approval_pair_is_refused(self):
        with self.assertRaises((ValueError, SystemExit, ba.ArchiveBuildError)):
            ba.build("LIGHT", self.root / "half" / "archive_light.db", embed=False,
                     release=True, seed_root=self.seed, db_dir=DB_DIR,
                     approvals_dir=self.evidence)

    def test_w04_the_cli_release_path_refuses_without_the_inputs(self):
        destination = self.root / "cli" / "archive_light.db"
        proc = subprocess.run(
            [sys.executable, "-m", "content.ingest.build_archive", "--tier", "LIGHT",
             "--out", str(destination), "--no-embed", "--release"],
            cwd=str(ROOT), capture_output=True, text=True)
        self.assertNotEqual(0, proc.returncode, proc.stdout + proc.stderr)
        self.assertFalse(destination.exists(), "the refused CLI run wrote a destination")

    def test_w05_an_approved_release_build_carries_its_digest_and_stages(self):
        """THE POSITIVE CONTROL: the repair must not refuse everything. The chunks are
        approved exactly as the T46 court approveth them."""
        self.sign_all()
        result = ba.build("LIGHT", self.out, embed=False, release=True,
                          seed_root=self.seed, db_dir=DB_DIR, today=TODAY,
                          manifests_root=self.manifests, evidence_root=self.evidence,
                          approvals_dir=self.approvals,
                          reviewer_keyset=self.trust_home / "reviewer_keys.json")
        with sqlite3.connect(self.out) as connection:
            meta = dict(connection.execute("SELECT key, value FROM archive_meta"))
        self.assertIn("approvals_sha256", meta,
                      "an APPROVED release build must carry its approvals digest")
        self.assertRegex(meta["approvals_sha256"], r"^[0-9a-f]{64}$")


    def test_w06_the_release_lane_passes_the_approvals_and_stops_when_absent(self):
        """GS-CONTENT-001 step 4: the production-corpus lane must OBTAIN the external
        approvals and pass BOTH explicitly -- and STOP at the external content gate when
        they are absent, never invent one. The COMMANDS are read, not the prose."""
        workflow = (ROOT / ".github/workflows/release-gates.yml").read_text(encoding="utf-8")
        joined = "\n".join(line for line in workflow.replace("\\\n", " ").splitlines()
                           if not line.strip().startswith("#"))
        self.assertTrue(any("build_archive" in line for line in joined.splitlines()),
                        "the lane must build the archive")
        self.assertIn("--approvals-dir", joined,
                      "the release lane must pass the approval-bundle home explicitly")
        self.assertIn("--reviewer-keyset", joined,
                      "and the operator's reviewer keyset")
        self.assertIn("STOPPING at the external content gate", joined,
                      "when they are absent the lane must STOP and NAME the external input")
        self.assertIn("must never substitute", joined,
                      "and say that a self-generated fixture is not an approval")


if __name__ == "__main__":
    unittest.main(verbosity=2)
