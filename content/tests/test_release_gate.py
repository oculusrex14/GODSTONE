from __future__ import annotations

import hashlib
import tempfile
import unittest
from datetime import date
from pathlib import Path

import yaml

from content.release_gate import ReleaseGateError, validate_document_manifest


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ReleaseGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "source.md"
        self.rights = self.root / "rights.txt"
        self.review = self.root / "review.txt"
        self.chunks = self.root / "chunks.txt"
        self.source.write_text("reviewed source\n", encoding="utf-8")
        self.rights.write_text("redistribution and derivatives permitted\n", encoding="utf-8")
        self.review.write_text("qualified reviewer approval\n", encoding="utf-8")
        self.chunks.write_text("all chunks reviewed with warnings attached\n", encoding="utf-8")
        self.manifest = self.root / "source.yaml"
        self.record = {
            "schema": 1,
            "id": "source-2026",
            "status": "approved",
            "example": False,
            "source": {
                "title": "Reviewed source", "publisher": "Publisher", "edition": "1",
                "version": "2026.1", "source_date": "2026-01-10",
                "acquisition_date": "2026-02-01", "canonical_url": "https://publisher.invalid/source",
                "source_sha256": digest(self.source),
            },
            "rights": {
                "licence": "CC-BY-4.0", "attribution": "Publisher, 2026",
                "redistribution_permitted": True, "derivative_work_permitted": True,
                "evidence_file": "rights.txt", "evidence_sha256": digest(self.rights),
            },
            "review": {
                "reviewer_id": "reviewer-123", "reviewer_role": "licensed clinician",
                "reviewer_qualifications": "qualification evidence ID 77",
                "reviewer_identity_evidence": "external-gate-record-77",
                "reviewed_on": "2026-03-01",
                "review_scope": "source transformation and every independently retrievable chunk",
                "expires_on": "2027-03-01", "approval_evidence_file": "review.txt",
                "approval_evidence_sha256": digest(self.review),
                "approval_signature": "external-signature-record-77",
            },
            "safety": {
                "warnings_required": True, "warning_sections": ["warning-1"],
                "contraindications_required": True, "contraindication_sections": ["contra-1"],
                "chunk_boundary_approved": True,
                "chunk_approval_evidence_file": "chunks.txt",
                "chunk_approval_evidence_sha256": digest(self.chunks),
                "jurisdiction": "global general guidance",
                "replacement_policy": "replace on source revision or review expiry",
            },
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write(self) -> None:
        self.manifest.write_text(yaml.safe_dump(self.record, sort_keys=True), encoding="utf-8")

    def validate(self):
        self.write()
        return validate_document_manifest(
            self.manifest, self.source, evidence_root=self.root, today=date(2026, 8, 6)
        )

    def test_approved_manifest_passes(self) -> None:
        result = self.validate()
        self.assertEqual("source-2026", result.document_id)

    def test_source_mutation_is_detected(self) -> None:
        self.write()
        self.source.write_text("mutated\n", encoding="utf-8")
        with self.assertRaisesRegex(ReleaseGateError, "source_sha256 mismatch"):
            validate_document_manifest(self.manifest, self.source, evidence_root=self.root, today=date(2026, 8, 6))

    def test_expired_review_is_rejected(self) -> None:
        self.record["review"]["expires_on"] = "2026-08-05"
        with self.assertRaisesRegex(ReleaseGateError, "expired"):
            self.validate()

    def test_wrong_rights_boolean_is_rejected(self) -> None:
        self.record["rights"]["derivative_work_permitted"] = False
        with self.assertRaisesRegex(ReleaseGateError, "derivative_work_permitted"):
            self.validate()

    def test_example_or_placeholder_is_rejected(self) -> None:
        self.record["example"] = True
        self.record["review"]["reviewer_id"] = "UNREVIEWED-EXAMPLE"
        with self.assertRaises(ReleaseGateError):
            self.validate()

    def test_missing_warning_mapping_is_rejected(self) -> None:
        self.record["safety"]["warning_sections"] = []
        with self.assertRaisesRegex(ReleaseGateError, "warning_sections"):
            self.validate()


if __name__ == "__main__":
    unittest.main()
