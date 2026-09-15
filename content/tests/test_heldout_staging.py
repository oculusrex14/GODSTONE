"""T66 integration: the held-out evaluation rides the staged release path.

The scenario is the production call path the card names -- licensed source ->
final chunks -> approval verification -> immutable DB -> signed manifest ->
staging -- with the evaluation bound to the very Archive being staged. Every
refusal below is tried against the previous authoritative bytes and against the
absence of any published manifest, so a failing path can be shown to write
nothing at all.

The manifest, the review decisions and the archive here are synthetic fixtures
(synthetic prose, a TEST-ONLY signing key, stand-in reviewer identities). No
clinician has reviewed anything in this repository, and no record produced by
these courts may be used as a clinical acceptance.
"""
from __future__ import annotations

import contextlib
import hashlib
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from content.archive_manifest import create_manifest, generate_test_keypair, load_private_key
from content.eval import heldout as H
from content.tests import heldout_fixtures as F
from scripts import prepare_release_assets as assets

CLOCK = lambda: "2026-09-14T02:00:00+00:00"  # noqa: E731 - injected clock boundary


class HeldOutStagingTests(unittest.TestCase):
    """T66: the evaluation a staging run carrieth must bind to the bytes it
    stages, or the run is refused before any write."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.inputs = self.root / "inputs"
        self.inputs.mkdir()
        self.archive = F.write_fixture_archive(self.inputs / "archive_light.db",
                                               reviewed=True)
        self.private = self.root / "test.key"
        self.trust = self.root / "operator-trust.json"
        generate_test_keypair(self.private, self.trust)
        self.signed = self.inputs / "archive.manifest.json"
        self.manifest_path = self.inputs / "assets.json"
        self.plan_path = self.inputs / "heldout-plan.json"
        self.record_path = self.inputs / "heldout-record.json"
        self.packet_path = self.inputs / "packet-a1.json"
        self.review_path = self.inputs / "review-a1.json"
        self.output = self.root / "output"
        self.output.mkdir()
        self.previous = b"previous usable archive"
        self.previous_manifest = b'{"previous": "manifest"}\n'
        (self.output / "archive_light.db").write_bytes(self.previous)
        (self.output / assets.APPROVED_MANIFEST_NAME).write_bytes(self.previous_manifest)
        self.refresh()

    # -- the intake bundle ------------------------------------------------
    def refresh(self):
        create_manifest(
            self.archive, self.signed, tier="LIGHT", archive_schema=3,
            source_manifest_sha256=F.PROVENANCE_REVIEW.source_manifest,
            review_manifest_sha256=F.PROVENANCE_REVIEW.review_manifest,
            corpus_manifest_sha256=F.PROVENANCE_REVIEW.corpus_manifest,
            build_tool_commit="b" * 40,
            private_key=load_private_key(self.private), key_id="TEST-ONLY")
        self.assets_document = {
            "schema": 1, "tier": "LIGHT", "application_id": "io.godstone.app",
            "status": "approved", "production_ready": True,
            "archive_manifest": self.signed.name,
            "assets": [{
                "role": "archive", "name": "archive_light.db",
                "source": self.archive.name,
                "bytes": self.archive.stat().st_size,
                "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            }],
        }
        F.write_document(self.manifest_path, self.assets_document)

    def manifest(self, **overrides):
        plan = F.manifest_plan(self.archive, **overrides)
        F.write_manifest(self.plan_path, plan)
        return H.load_manifest(self.plan_path)

    def sealed_record(self, manifest, *, reviews=True, out=None, archive=None,
                      model_lock=F.MODEL_LOCK):
        """One evaluation run, optionally sealed with a synthetic review."""
        first = H.evaluate(manifest, archive_path=archive or self.archive,
                           model_lock_path=model_lock, manifest_path=self.plan_path,
                           clock=CLOCK)
        H.write_canonical(self.record_path, first)
        if not reviews:
            return first
        packet = H.blinded_packet(manifest, first, reviewer_token="reviewer-a1")
        H.write_canonical(self.packet_path, packet)
        review = F.review_document(manifest, packet, "reviewer-a1")
        F.write_document(self.review_path, review)
        document = H.evaluate(manifest, archive_path=archive or self.archive,
                              model_lock_path=model_lock, manifest_path=self.plan_path,
                              reviews=[{"packet": packet, "review": review}],
                              clock=CLOCK, out=out or self.record_path)
        return document

    def stage(self, output=None, **options):
        options.setdefault("heldout_evaluation", self.record_path)
        options.setdefault("heldout_manifest", self.plan_path)
        assets.stage(self.manifest_path, output or self.output,
                     trust_store_path=self.trust, **options)

    def assert_preserved(self):
        self.assertEqual(self.previous, (self.output / "archive_light.db").read_bytes())
        self.assertEqual(self.previous_manifest,
                         (self.output / assets.APPROVED_MANIFEST_NAME).read_bytes())

    # -- the happy way ----------------------------------------------------
    def test_a_complete_evaluation_travels_with_the_staged_archive(self):
        manifest = self.manifest()
        document = self.sealed_record(manifest)
        self.assertEqual("COMPLETE", document["status"])
        self.stage()
        self.assertEqual(self.archive.read_bytes(),
                         (self.output / "archive_light.db").read_bytes())
        published = json.loads((self.output / assets.APPROVED_MANIFEST_NAME).read_text())
        block = published["evaluation"]
        self.assertEqual(assets.EVALUATION_BLOCK_SCHEMA, block["schema"])
        self.assertEqual("COMPLETE", block["status"])
        self.assertEqual(hashlib.sha256(self.archive.read_bytes()).hexdigest(),
                         block["corpus_sha256"])
        self.assertEqual(hashlib.sha256(self.record_path.read_bytes()).hexdigest(),
                         block["record_sha256"])
        self.assertEqual(document["report"]["totals"]["cases"], block["cases"])
        self.assertEqual(0, block["false_allow"])
        self.assertEqual({"bleeding", "cbrm", "safety", "unanswerable", "water"},
                         set(block["categories"]))
        self.assertTrue(block["clinical_acceptance"].startswith("EXTERNAL"))

    def test_staging_without_an_evaluation_keeps_its_published_face(self):
        self.stage(heldout_evaluation=None, heldout_manifest=None)
        published = json.loads((self.output / assets.APPROVED_MANIFEST_NAME).read_text())
        self.assertNotIn("evaluation", published)

    def test_release_owner_may_demand_an_evaluation(self):
        with self.assertRaisesRegex(ValueError, "requireth a held-out evaluation"):
            self.stage(heldout_evaluation=None, heldout_manifest=None,
                       require_heldout_evaluation=True)
        self.assert_preserved()

    # -- the refusals that keep it honest ---------------------------------
    def test_a_different_corpus_cannot_borrow_this_evaluation(self):
        manifest = self.manifest()
        self.sealed_record(manifest)
        # A neighbouring build of the same corpus, one passage different: the
        # signed manifest is regenerated for it, so only the evaluation's own
        # corpus binding can tell the two apart.
        other = self.root / "elsewhere" / "archive_light.db"
        other.parent.mkdir()
        F.write_fixture_archive(other, reviewed=True)
        with contextlib.closing(sqlite3.connect(other)) as db, db:
            db.execute("UPDATE chunks SET text=? WHERE chunk_id=1",
                       ("Bring water to a rolling boil and hold it there for 5 "
                        "minutes before drinking it.",))
        self.archive.write_bytes(other.read_bytes())
        self.refresh()
        with self.assertRaisesRegex(ValueError, "different corpus"):
            self.stage()
        self.assert_preserved()

    def test_an_unreviewed_ledger_cannot_be_staged(self):
        manifest = self.manifest()
        self.sealed_record(manifest, reviews=False)
        with self.assertRaisesRegex(ValueError, "blinded review is incomplete|standeth 'INCOMPLETE'"):
            self.stage()
        self.assert_preserved()

    def test_a_corrupt_model_lock_is_refused_by_name(self):
        corrupt = F.corrupt_model_lock(F.MODEL_LOCK, self.root / "corrupt-lock.json")
        # The evaluation itself refuseth first: a corrupt register can bind
        # neither coordinate nor byte, so no record may claim to stand on it.
        bound_to_corrupt = self.manifest(
            lock_sha256=hashlib.sha256(corrupt.read_bytes()).hexdigest())
        with self.assertRaisesRegex(H.HeldOutError, "model lock is corrupt"):
            H.evaluate(bound_to_corrupt, archive_path=self.archive,
                       model_lock_path=corrupt, manifest_path=self.plan_path,
                       clock=CLOCK)
        # And a record made against the sound lock cannot be carried across a
        # register that has since gone bad.
        manifest = self.manifest()
        self.sealed_record(manifest)
        with self.assertRaisesRegex(ValueError, "model lock is corrupt|"
                                                "model lock changed since the evaluation"):
            self.stage(model_lock_path=corrupt)
        self.assert_preserved()

    def test_a_model_lock_that_moved_since_the_run_is_refused(self):
        manifest = self.manifest()
        self.sealed_record(manifest)
        moved = self.root / "moved-lock.json"
        moved.write_text(F.MODEL_LOCK.read_text(encoding="utf-8").replace(
            '"verified_on": null', '"verified_on": "2026-09-14"'), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "model lock changed since the evaluation|"
                                                "model lock is corrupt"):
            self.stage(model_lock_path=moved)
        self.assert_preserved()

    def test_a_false_allow_cannot_reach_the_approved_directory(self):
        # A case the manifest requires refused, on a question this corpus
        # genuinely answers: the gate allows it, the harness reporteth the
        # finding, and the finding stopeth the release.
        cases = [dict(case) for case in F.FIXTURE_CASES]
        cases[0] = dict(cases[0], expectation="must_refuse")
        manifest = self.manifest(cases=cases)
        document = self.sealed_record(manifest)
        self.assertEqual("FAILED", document["status"])
        self.assertGreaterEqual(document["report"]["totals"]["false_allow"], 1)
        with self.assertRaisesRegex(ValueError, "false allow"):
            self.stage()
        self.assert_preserved()

    def test_a_hand_struck_case_is_caught_by_the_published_census(self):
        manifest = self.manifest()
        self.sealed_record(manifest)
        record = json.loads(self.record_path.read_text())
        record["cases"] = [entry for entry in record["cases"]
                           if entry["outcome"] != "false_allow"
                           and entry["case_id"] != "un-price"]
        self.record_path.write_text(json.dumps(record, indent=2) + "\n",
                                    encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "silently excluded|carrieth no record"):
            self.stage()
        self.assert_preserved()

    def test_a_placeholder_review_cannot_complete_a_release(self):
        manifest = self.manifest(review_pool=("UNREVIEWED-EXAMPLE",))
        first = H.evaluate(manifest, archive_path=self.archive,
                           model_lock_path=F.MODEL_LOCK, manifest_path=self.plan_path,
                           clock=CLOCK)
        packet = H.blinded_packet(manifest, first, reviewer_token="UNREVIEWED-EXAMPLE")
        review = F.review_document(manifest, packet, "UNREVIEWED-EXAMPLE")
        document = H.evaluate(manifest, archive_path=self.archive,
                              model_lock_path=F.MODEL_LOCK, manifest_path=self.plan_path,
                              reviews=[{"packet": packet, "review": review}],
                              clock=CLOCK, out=self.record_path)
        self.assertEqual("INCOMPLETE", document["status"])
        self.assertTrue(any("placeholder reviewers" in item
                            for item in document["completeness_errors"]))
        with self.assertRaisesRegex(ValueError, "placeholder reviewers"):
            self.stage()
        self.assert_preserved()

    def test_check_only_binds_the_evaluation_without_publishing(self):
        manifest = self.manifest()
        self.sealed_record(manifest)
        data, staged = assets.validate(self.manifest_path, trust_store_path=self.trust,
                                       heldout_evaluation=self.record_path,
                                       heldout_manifest=self.plan_path)
        self.assertEqual(1, len(staged))
        self.assertEqual("COMPLETE", data["_heldout_evaluation"]["status"])
        self.assert_preserved()

    def test_the_deputy_face_refuseth_to_carry_an_evaluation(self):
        """REVERSED AT ROUND 98 (GS-CONTENT-003 / AUDIT-004).

        This arm once asserted the message "operator-selected face's law", which belonged to a
        refusal raised AFTER a supplied trust store was already demanded -- so every supplied
        held-out evaluation was refused, including VALID operator-selected input, and this arm
        PINNED that regression. The refusal it protected is gone. The law the arm now holds is
        the one that was always meant: the DEPUTY face (no operator trust store) may not carry
        an evaluation at all, because the trust store is selected by the OPERATOR and never by
        the bundle that is being judged. No trust assertion was dropped: the refusal is still
        demanded, with its real reason named.
        """
        manifest = self.manifest()
        self.sealed_record(manifest)
        with self.assertRaisesRegex(ValueError, "selected by the operator"):
            assets.validate(self.manifest_path, heldout_evaluation=self.record_path)
        self.assert_preserved()

    def test_a_valid_operator_selected_evaluation_reaches_the_valid_verifier(self):
        """THE ADOPTED REGRESSION ARM (AUDIT-004, GS-CONTENT-003).

        The independent review reproduced this assertion PASSING on the prior baseline
        (c683a2bf) and FAILING on the repaired source: public `validate` refused a VALID
        operator-selected held-out evaluation before ever reaching the verifier that accepts
        it. It is adopted here with its assertions INTACT.

        The fixture's metadata is adapted to the new provenance-presence policy exactly as the
        independent probe adapted it -- a SYNTHETIC approvals digest is installed so the signed
        manifest can swear it -- and NO human approval is claimed: this proveth that the WRAPPER
        reaches its verifier, not that any content was ever approved.
        """
        with sqlite3.connect(self.archive) as db:
            db.execute("INSERT OR REPLACE INTO archive_meta VALUES('approvals_sha256',?)",
                       ("4" * 64,))
            db.execute("INSERT OR REPLACE INTO archive_meta VALUES('approvals_covered','1')")
        self.refresh()
        manifest = self.manifest()
        self.sealed_record(manifest)
        options = {"trust_store_path": self.trust,
                   "heldout_evaluation": self.record_path,
                   "heldout_manifest": self.plan_path}
        data, _ = assets._validate_operator_selected(self.manifest_path, **options)
        self.assertEqual("COMPLETE", data["_heldout_evaluation"]["status"],
                         "the LOWER verifier is the positive control and must accept")
        try:
            data, _ = assets.validate(self.manifest_path, **options)
        except ValueError as exc:
            self.fail("outer validate rejects a valid operator-selected evaluation: %s" % exc)
        self.assertEqual("COMPLETE", data["_heldout_evaluation"]["status"])

    def test_check_only_binds_a_valid_evaluation_without_publishing(self):
        """The audit's step 3: the CHECK-ONLY face must reach the same verifier for a valid
        operator-selected evaluation, and must not PUBLISH anything while doing it.

        HARNESS NOTE (round 98): the first form of this arm asserted `not staged` on
        `validate`'s second return value and failed -- because that value is the PLAN of the
        assets that WOULD be staged, not a publication. A harness misuse is not a product
        defect, so the arm now asserts the real law with the court's own publication witness:
        the previously published pair must be byte-identical afterwards.
        """
        with sqlite3.connect(self.archive) as db:
            db.execute("INSERT OR REPLACE INTO archive_meta VALUES('approvals_sha256',?)",
                       ("4" * 64,))
            db.execute("INSERT OR REPLACE INTO archive_meta VALUES('approvals_covered','1')")
        self.refresh()
        manifest = self.manifest()
        self.sealed_record(manifest)
        try:
            data, planned = assets.validate(
                self.manifest_path, trust_store_path=self.trust,
                heldout_evaluation=self.record_path, heldout_manifest=self.plan_path)
        except ValueError as exc:
            self.fail("check-only rejected a valid operator-selected evaluation: %s" % exc)
        self.assertEqual("COMPLETE", data["_heldout_evaluation"]["status"])
        self.assertEqual(["archive_light.db"], [name for _, name in planned],
                         "the check-only plan must name the assets it WOULD stage")
        self.assert_preserved()

    def test_published_bytes_stay_deterministic_with_an_evaluation(self):
        manifest = self.manifest()
        self.sealed_record(manifest)
        self.stage()
        first = (self.output / assets.APPROVED_MANIFEST_NAME).read_bytes()
        self.stage()
        second = (self.output / assets.APPROVED_MANIFEST_NAME).read_bytes()
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
