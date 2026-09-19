#! /usr/bin/env python3
"""T80 readiness court (python isle): the approved-content INGEST machinery.

T80's final acceptance needs a human-reviewed licensed corpus that nobody here
may author or approve. That is external and stays blocked. What is NOT external
is the machinery that INGESTS and validates a corpus, and this court proves it
exists, is wired to the real release gate, and refuses missing, stale,
tampered, duplicate and unapproved content.

  W01  the release gate's corpus validator EXISTS and is driven directly -- the
       court calls `content.release_gate.validate_release_corpus`, not a copy
  W02  a MISSING approved manifest is refused by name
  W03  a final-chunk approvals bundle that is ABSENT is refused by name: missing
       approval BLOCKS, it does not read as approved
  W04  a FUTURE approvals schema is refused by name; a MALFORMED bundle is
       refused by name
  W05  a DUPLICATE source_id is refused, and an UNSAFE source_id is refused
  W06  THE CARD'S SEMANTIC NEGATIVE: replacing one approved source paragraph
       after review makes the final-chunk signature gate fail
  W07  the fixture is NOT the production corpus, and the repository SAYS so:
       no gate is closed, and readiness stays false
  W08  absent human review keeps the gate BLOCKED, with a receipt-event trigger

Every corpus built here is HARMLESS development text in a temporary directory,
labelled as a rehearsal. It is NOT an approved corpus and it closes no gate.
"""
from __future__ import annotations

import hashlib
import json
import shutil
import sys
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

import yaml  # noqa: E402
from content import release_gate as gate  # noqa: E402

BLOCKERS = "docs/production-readiness/EXTERNAL_BLOCKERS.json"
BUILD_STATE = "docs/production-readiness/BUILD_STATE.json"


def load(rel):
    return json.loads((ROOT / rel).read_text(encoding="utf-8"))


class _Corpus:
    """A rehearsal corpus in a temporary directory, shaped to the REAL schema.

    HARMLESS text only, and every bundle it writes is stamped as a fixture. The
    manifest shape is taken from `validate_document_manifest` -- the court drives
    the real gate, so the fixture must satisfy the real contract or it would be
    testing a schema that does not exist."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.manifests = self.root / "manifests"
        self.manifests.mkdir()
        self.approvals = self.root / "approvals"
        self.approvals.mkdir()
        # *_resolve_evidence* resolves against the evidence root, which the
        # corpus validator defaults to `manifests_dir.parent` -- this temp root.
        self.evidence = self.root
        self.doc = self.root / "T80-FIXTURE-SOURCE.txt"
        self.doc.write_text(
            "T80 fixture prose. A rehearsal is not an approval.\n", encoding="utf-8")

    def _evidence(self, name, body=b"T80-FIXTURE EVIDENCE -- NOT AN APPROVAL"):
        path = self.evidence / name
        path.write_bytes(body)
        return name, hashlib.sha256(path.read_bytes()).hexdigest()

    def manifest(self, source_id="T80-FIXTURE-SOURCE", *, status="approved",
                 example=False, source_sha256=None, expires_on=None):
        rights_file, rights_sha = self._evidence(f"{source_id}.rights.txt")
        review_file, review_sha = self._evidence(f"{source_id}.review.txt")
        chunk_file, chunk_sha = self._evidence(f"{source_id}.chunk.txt")
        today = date.today()
        document = {
            "schema": gate.SCHEMA_VERSION,
            "id": source_id,
            "status": status,
            "example": example,
            "source": {
                "title": "T80 fixture document",
                "publisher": "T80-FIXTURE (not a real publisher)",
                "edition": "rehearsal",
                "version": "1",
                "source_date": today.isoformat(),
                "acquisition_date": today.isoformat(),
                "canonical_url": "https://example.invalid/t80-fixture",
                "source_sha256": source_sha256
                if source_sha256 is not None
                else hashlib.sha256(self.doc.read_bytes()).hexdigest(),
            },
            "rights": {
                "licence": "T80-FIXTURE-LICENCE (not a real licence)",
                "attribution": "T80 fixture rehearsal",
                "redistribution_permitted": True,
                "derivative_work_permitted": True,
                "evidence_file": rights_file,
                "evidence_sha256": rights_sha,
            },
            "review": {
                "reviewer_id": "T80-FIXTURE-REVIEWER",
                "reviewer_role": "rehearsal",
                "reviewer_qualifications": "T80-FIXTURE -- NOT A REAL PROFESSIONAL QUALIFICATION",
                "reviewer_identity_evidence": f"{source_id}.review.txt",
                "reviewed_on": today.isoformat(),
                "review_scope": "rehearsal",
                "expires_on": expires_on or (today + timedelta(days=365)).isoformat(),
                "approval_signature": "T80-FIXTURE-SIGNATURE -- NOT AN APPROVAL",
                "approval_evidence_file": review_file,
                "approval_evidence_sha256": review_sha,
            },
            "safety": {
                "chunk_boundary_approved": True,
                "jurisdiction": "T80-FIXTURE",
                "replacement_policy": "T80 fixture rehearsal",
                "warnings_required": False,
                "contraindications_required": False,
                "chunk_approval_evidence_file": chunk_file,
                "chunk_approval_evidence_sha256": chunk_sha,
            },
        }
        return document

    def write_manifest(self, document, source_id="T80-FIXTURE-SOURCE"):
        path = self.manifests / f"{source_id}.yaml"
        path.write_text(yaml.safe_dump(document, sort_keys=False), encoding="utf-8")
        return path

    def approve(self, source_id="T80-FIXTURE-SOURCE", **kwargs):
        document = self.manifest(source_id, **kwargs)
        self.write_manifest(document, source_id)
        return document

    def approvals_bundle(self, source_id="T80-FIXTURE-SOURCE", **overrides):
        bundle = {"schema": gate.APPROVAL_SCHEMA, "approvals": [], "fixture": True}
        bundle.update(overrides)
        path = self.approvals / f"{source_id}.approvals.json"
        path.write_text(json.dumps(bundle), encoding="utf-8")
        return path

    def close(self):
        self.tmp.cleanup()


class ApprovedContentIngestCourt(unittest.TestCase):
    """W01-W07 -- the ingest machinery as it actually behaves."""

    maxDiff = None

    def test_w01_the_corpus_validator_is_driven_directly(self):
        """The court must call the REAL validator, and it must exist."""
        self.assertTrue(callable(gate.validate_release_corpus))
        self.assertTrue(callable(gate.load_final_chunk_approvals))
        self.assertIsInstance(gate.APPROVAL_SCHEMA, int)

    def test_w02_a_missing_approved_manifest_is_refused_by_name(self):
        corpus = _Corpus()
        try:
            document = {"source_id": "T80-FIXTURE-SOURCE", "path": str(corpus.doc)}
            with self.assertRaises(gate.ReleaseGateError) as caught:
                gate.validate_release_corpus([document], corpus.manifests,
                                             evidence_root=corpus.root)
            # a document with NO approved manifest beside it is not approved
            self.assertIn("unreadable manifest", str(caught.exception))
        finally:
            corpus.close()

    def test_w03_an_absent_approvals_bundle_is_refused_by_name(self):
        corpus = _Corpus()
        try:
            with self.assertRaises(gate.ReleaseGateError) as caught:
                gate.load_final_chunk_approvals(corpus.approvals, "T80-FIXTURE-SOURCE")
            self.assertIn("no approvals bundle", str(caught.exception))
        finally:
            corpus.close()

    def test_w04_a_future_or_malformed_bundle_is_refused_by_name(self):
        corpus = _Corpus()
        try:
            # a FUTURE schema version
            corpus.approvals_bundle(schema=gate.APPROVAL_SCHEMA + 1)
            with self.assertRaises(gate.ReleaseGateError) as caught:
                gate.load_final_chunk_approvals(corpus.approvals, "T80-FIXTURE-SOURCE")
            self.assertIn("unsupported future approvals schema", str(caught.exception))

            # a MALFORMED bundle
            (corpus.approvals / "T80-FIXTURE-SOURCE.approvals.json").write_text(
                "{not json", encoding="utf-8")
            with self.assertRaises(gate.ReleaseGateError) as caught:
                gate.load_final_chunk_approvals(corpus.approvals, "T80-FIXTURE-SOURCE")
            self.assertIn("unreadable approvals bundle", str(caught.exception))

            # a bundle whose root is not an object
            (corpus.approvals / "T80-FIXTURE-SOURCE.approvals.json").write_text(
                "[]", encoding="utf-8")
            with self.assertRaises(gate.ReleaseGateError) as caught:
                gate.load_final_chunk_approvals(corpus.approvals, "T80-FIXTURE-SOURCE")
            self.assertIn("root must be an object", str(caught.exception))
        finally:
            corpus.close()

    def test_w05_a_duplicate_or_unsafe_source_id_is_refused(self):
        corpus = _Corpus()
        try:
            corpus.approve()
            document = {"source_id": "T80-FIXTURE-SOURCE", "path": str(corpus.doc)}
            with self.assertRaises(gate.ReleaseGateError) as caught:
                gate.validate_release_corpus([document, dict(document)],
                                             corpus.manifests,
                                             evidence_root=corpus.root)
            self.assertIn("duplicate source_id", str(caught.exception),
                          "a duplicated source_id was ACCEPTED")

            # ... and an UNSAFE id (a traversal attempt) is refused
            unsafe = {"source_id": "../escape", "path": str(corpus.doc)}
            with self.assertRaises(gate.ReleaseGateError) as caught:
                gate.validate_release_corpus([unsafe], corpus.manifests,
                                             evidence_root=corpus.root)
            self.assertIn("unsafe source_id", str(caught.exception))
        finally:
            corpus.close()

    def test_w06_replacing_an_approved_paragraph_after_review_is_detected(self):
        """The card's semantic negative.

        The manifest pins the document's bytes; changing the prose after review
        must make the gate fail, because the approved digest no longer describes
        what stands in the corpus."""
        corpus = _Corpus()
        try:
            corpus.approve()
            document = {"source_id": "T80-FIXTURE-SOURCE", "path": str(corpus.doc)}
            # BASELINE FIRST: the rehearsal corpus must be ingestible, or the
            # tamper proves nothing about the gate.
            result = gate.validate_release_corpus([document], corpus.manifests,
                                                  evidence_root=corpus.root)
            self.assertEqual(1, len(result.documents),
                             "the rehearsal corpus did not validate at baseline")

            # NOW replace the reviewed prose, exactly as the card's negative says
            corpus.doc.write_text(
                "T80 fixture prose. THIS PARAGRAPH WAS REPLACED AFTER REVIEW.\n",
                encoding="utf-8")
            with self.assertRaises(gate.ReleaseGateError) as caught:
                gate.validate_release_corpus([document], corpus.manifests,
                                             evidence_root=corpus.root)
            self.assertIn("source_sha256 mismatch", str(caught.exception),
                          "replacing the reviewed paragraph was ACCEPTED: the bytes "
                          "are not pinned by the approval")
        finally:
            corpus.close()

    def test_w07_the_fixture_is_not_the_production_corpus(self):
        """The repository must SAY the fixture is not an approval -- both in the
        fixture it writes and in the gate record."""
        corpus = _Corpus()
        try:
            manifest = corpus.approve()
            self.assertIn("NOT AN APPROVAL", manifest["review"]["approval_signature"],
                          "a fixture manifest must carry its own disclaimer: a "
                          "rehearsal may never be mistaken for a review")
            self.assertIn("NOT A REAL PROFESSIONAL QUALIFICATION",
                          manifest["review"]["reviewer_qualifications"],
                          "the reviewer fields must read as rehearsal values")
            register = load(BLOCKERS)
            content = [b for b in register["blockers"] if b["id"] == "APPROVED_CONTENT"]
            self.assertTrue(content)
            self.assertIsNone(content[0]["closure_evidence"],
                              "APPROVED_CONTENT carrieth closure evidence: no fixture "
                              "may close a content-approval gate")
        finally:
            corpus.close()


class TheContentGateStaysBlocked(unittest.TestCase):
    """W08 -- absent human review keeps T80 blocked."""

    def test_w08_absent_human_review_keeps_the_gate_blocked(self):
        state = load(BUILD_STATE)["completed_tasks"]["T80"]
        self.assertEqual("BLOCKED_EXTERNAL", state["status"])
        self.assertIsNone(state.get("closure_evidence"))
        self.assertIn("receipt", str(state.get("recheck_trigger", "")).lower(),
                      "the trigger must name a receipt EVENT, not a date")
        invariants = load("docs/production-readiness/ARCHITECTURE_INVARIANTS.json")
        self.assertIs(False, invariants["readiness"].get("android_LINK_LAYER_READY"))
        self.assertIs(False, invariants["readiness"].get("ios_linkLayerReady"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
