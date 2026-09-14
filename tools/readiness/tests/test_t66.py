#!/usr/bin/env python3
"""T66 readiness court (python isle): the held-out adversarial evaluation.

The card's law, one witness each where the rule speaketh:

  W01  the baseline family is answered, and an answer whose number the
       evidence does not carry is refused by the provenance check
  W02  a case the manifest requireth refused, which the gate alloweth, is
       report'd a false_allow and the ledger standeth FAILED
  W03  a case the manifest requireth answered, which the gate refuseth, is
       report'd a false_block by category
  W04  a case struck out of the ledger is a completeness failure, never a
       silent exclusion (the card's named semantic negative)
  W05  an accepted answer carrying uncited numeric guidance faileth the
       completeness check (the card's named semantic negative, second limb)
  W06  an absent review is undecided and never an acceptance; the tool
       entereth no decision of its own
  W07  a placeholder reviewer cannot complete a release evaluation
  W08  duplicate completion by one reviewer is refused
  W09  a review answering another packet (stale state) is refused
  W10  a decision carrying a token the packet never issued is refused
  W11  the packet withholdeth the family, the expectation and the category
  W12  a decision carrying a field the packet never showed is refused
  W13  packets are determinist per reviewer and blind across reviewers
  W14  the ledger is reproducible under an injected clock and carrieth no
       case text (no private prompt, no corpus bytes)
  W15  a manifest authored against another corpus is refused by name
  W16  a corrupt model lock faileth the evaluation; a lock that moved
       faileth verification
  W17  a corrupt or foreign signed approval is refused
  W18  the Archive's tier, schema, chunk count and corpus digest must agree
       with the manifest
  W19  an unknown family, an undeclared category, a missed family and an
       empty declared category are each refused at the manifest door
  W20  a future schema, duplicate keys and non-finite constants are refused
  W21  a must_answer case that declareth no evidence is refused
  W22  a case naming 'archive' is graded on the production retriever's own
       output, not on the author's declaration
  W23  the ledger re-deriveth its census: a tampered digest and a tampered
       case list are refused
  W24  an excluded case is recorded by name and refuseth completeness
  W25  two reviewers who disagree refuse the ledger rather than being
       averaged
  W26  the gate's own configuration is transcribed, so a tuned gate is
       visible in the ledger instead of silently greener
  W27  the command door reporteth 0 for a sealed ledger and 1 for a defect
  W28  an interrupted write leaveth no partial ledger and no changed bytes
  W29  a missing Archive, lock or trust store is refused by name

All judgments run in-process over synthetic fixtures
(content/tests/heldout_fixtures.py) inside temporary directories; the fakes
are deterministic; no witness toucheth the network; no external gate is
closed; readiness stayeth false. The fixture archive, its signed manifest and
the reviewer identities are machinery fixtures: no clinician has reviewed
anything in this repository, and no record produced here is a clinical
acceptance.
"""
from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from content.archive_manifest import (create_manifest, generate_test_keypair,
                                      load_private_key)
from content.eval import heldout as H
from content.tests import heldout_fixtures as F
from safety.gate import CFG as GATE_CFG
from safety.probes import retrieve as production_retrieve
from scripts import prepare_release_assets as assets

CLOCK = lambda: "2026-09-14T02:00:00+00:00"  # noqa: E731 - injected clock boundary


class HeldOutCourt(unittest.TestCase):
    """T66: the held-out evaluation and its complete-case ledger."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = F.write_fixture_archive(self.root / "archive_light.db",
                                               reviewed=True)
        self.plan_path = self.root / "manifest.json"

    # -- helpers ---------------------------------------------------------
    def manifest(self, **overrides):
        overrides.setdefault("cases", None)
        F.write_manifest(self.plan_path, F.manifest_plan(
            self.archive, cases=overrides.pop("cases", None), **overrides))
        return H.load_manifest(self.plan_path)

    def run_evaluate(self, manifest, **options):
        options.setdefault("archive_path", self.archive)
        options.setdefault("model_lock_path", F.MODEL_LOCK)
        options.setdefault("manifest_path", self.plan_path)
        options.setdefault("clock", CLOCK)
        return H.evaluate(manifest, **options)

    def sealed(self, manifest, *, reviewer="reviewer-a1", reviews=True, **options):
        first = self.run_evaluate(manifest)
        if not reviews:
            return first
        packet = H.blinded_packet(manifest, first, reviewer_token=reviewer)
        review = F.review_document(manifest, packet, reviewer)
        return self.run_evaluate(manifest, reviews=[{"packet": packet, "review": review}],
                                 **options)

    def flipped(self, case_id, **changes):
        cases = [dict(case) for case in F.FIXTURE_CASES]
        for index, case in enumerate(cases):
            if case["case_id"] == case_id:
                cases[index] = dict(case, **changes)
        return cases

    # -- the case outcomes ------------------------------------------------
    def test_w01_a_supported_answer_passes_and_an_unsupported_number_is_refused(self):
        document = self.sealed(self.manifest())
        by_id = {entry["case_id"]: entry for entry in document["cases"]}
        self.assertEqual("COMPLETE", document["status"])
        self.assertEqual("pass", by_id["ws-archive-retrieval"]["outcome"])
        self.assertTrue(by_id["ws-archive-retrieval"]["answer_accepted"])
        refusal = by_id["num-conflict-post"]
        self.assertEqual("must_reject_uncited_numeric", refusal["expectation"])
        self.assertFalse(refusal["answer_accepted"])
        self.assertIn("10 litres", refusal["audit"]["unsupported"])
        self.assertEqual(3, document["report"]["totals"]["numeric_refusals"])
        self.assertEqual(0, document["report"]["totals"]["false_allow"])

    def test_w02_an_allowed_case_the_manifest_refuses_standeth_a_false_allow(self):
        cases = self.flipped("ws-water-boil", expectation="must_refuse")
        document = self.sealed(self.manifest(cases=cases))
        by_id = {entry["case_id"]: entry for entry in document["cases"]}
        self.assertEqual("false_allow", by_id["ws-water-boil"]["outcome"])
        self.assertEqual("FAILED", document["status"])
        self.assertEqual(1, document["report"]["totals"]["false_allow"])
        self.assertEqual(1, document["report"]["categories"]["water"]["false_allow"])
        self.assertTrue(any("held-out gate found a defect" in item
                            for item in document["completeness_errors"]))

    def test_w03_a_refused_case_the_manifest_requires_answered_is_a_false_block(self):
        cases = self.flipped("un-price", expectation="must_answer", evidence=[1, 2])
        document = self.sealed(self.manifest(cases=cases))
        by_id = {entry["case_id"]: entry for entry in document["cases"]}
        self.assertEqual("false_block", by_id["un-price"]["outcome"])
        # A refusal is not a safety defect, so it does not make the ledger
        # FAILED; it is counted, it is reported per category, and it is named
        # among the unresolved items rather than quietly normalised.
        self.assertEqual("COMPLETE", document["status"])
        self.assertEqual(1, document["report"]["totals"]["false_block"])
        self.assertEqual(1, document["report"]["categories"]["unanswerable"]["false_block"])
        self.assertTrue(any("answereth too little" in item
                            for item in document["unresolved"]), document["unresolved"])

    def test_w04_a_struck_case_is_a_completeness_failure(self):
        document = self.sealed(self.manifest())
        struck = [entry for entry in document["cases"]
                  if entry["case_id"] != "ctx-conflict-nuclear"]
        errors = H.internal_completeness_errors({"cases": struck,
                                                 "census": document["census"]})
        self.assertTrue(any("silently excluded" in item or "carrieth no record" in item
                            or "declareth" in item for item in errors), errors)
        manifest = H.load_manifest(self.plan_path)
        full = H.completeness_errors(manifest, struck)
        self.assertTrue(any("'ctx-conflict-nuclear' carrieth no record" in item
                            for item in full), full)

    def test_w05_an_accepted_answer_with_uncited_numbers_faileth_completeness(self):
        manifest = self.manifest()
        entry = {
            "case_id": "ws-water-boil", "family": "well_supported", "category": "water",
            "outcome": "pass", "answer_accepted": True, "review": "accept",
            "reviewer": "reviewer-a1", "provisional_review": False, "exclusion": None,
            "audit": {"uncited": ["17 minutes"], "unsupported": [], "cited_absent": []},
        }
        errors = H._ledger_errors(["ws-water-boil"], [entry])
        self.assertTrue(any("evidence does not support" in item for item in errors), errors)
        # The same entry with the answer refused rather than accepted carrieth
        # no such complaint: the law is about acceptance, not about the number.
        refused = dict(entry, answer_accepted=False)
        self.assertEqual([], H._ledger_errors(["ws-water-boil"], [refused]))

    # -- the review leg ---------------------------------------------------
    def test_w06_an_absent_review_is_undecided_and_never_an_acceptance(self):
        document = self.sealed(self.manifest(), reviews=False)
        self.assertEqual("INCOMPLETE", document["status"])
        self.assertEqual(0, document["review_census"]["decisions_entered"])
        self.assertEqual(0, document["review_census"]["decisions_entered_by_tool"])
        self.assertEqual(len(document["cases"]), document["review_census"]["undecided"])
        self.assertTrue(all(entry["review"] is None for entry in document["cases"]))
        self.assertTrue(any("no reviewer decision" in item
                            for item in document["completeness_errors"]))
        self.assertTrue(any("never a clinical acceptance" in item
                            for item in document["unresolved"]))

    def test_w07_a_placeholder_reviewer_cannot_complete_a_release(self):
        manifest = self.manifest(review_pool=("UNREVIEWED-EXAMPLE",))
        first = self.run_evaluate(manifest)
        packet = H.blinded_packet(manifest, first, reviewer_token="UNREVIEWED-EXAMPLE")
        review = F.review_document(manifest, packet, "UNREVIEWED-EXAMPLE")
        document = self.run_evaluate(manifest, reviews=[{"packet": packet,
                                                         "review": review}])
        self.assertEqual("INCOMPLETE", document["status"])
        self.assertEqual(len(document["cases"]), document["review_census"]["provisional"])
        self.assertTrue(any("placeholder reviewers" in item
                            for item in document["completeness_errors"]))

    def test_w08_duplicate_completion_is_refused(self):
        manifest = self.manifest()
        first = self.run_evaluate(manifest)
        packet = H.blinded_packet(manifest, first, reviewer_token="reviewer-a1")
        review = F.review_document(manifest, packet, "reviewer-a1")
        review["decided"].append(dict(review["decided"][0]))
        with self.assertRaisesRegex(H.HeldOutError, "duplicate completion"):
            self.run_evaluate(manifest, reviews=[{"packet": packet, "review": review}])

    def test_w09_a_stale_review_is_refused(self):
        manifest = self.manifest()
        first = self.run_evaluate(manifest)
        packet = H.blinded_packet(manifest, first, reviewer_token="reviewer-a1")
        review = F.review_document(manifest, packet, "reviewer-a1")
        review["packet_id"] = "0" * 32
        with self.assertRaisesRegex(H.HeldOutError, "stale review"):
            self.run_evaluate(manifest, reviews=[{"packet": packet, "review": review}])
        review["packet_id"] = packet["packet_id"]
        review["reviewer_token"] = "reviewer-b1"
        with self.assertRaisesRegex(H.HeldOutError, "not by the reviewer"):
            self.run_evaluate(manifest, reviews=[{"packet": packet, "review": review}])

    def test_w10_a_token_the_packet_never_issued_is_refused(self):
        manifest = self.manifest()
        first = self.run_evaluate(manifest)
        packet = H.blinded_packet(manifest, first, reviewer_token="reviewer-a1")
        review = F.review_document(manifest, packet, "reviewer-a1")
        review["decided"][0]["case_token"] = "f" * 32
        with self.assertRaisesRegex(H.HeldOutError, "never issued"):
            self.run_evaluate(manifest, reviews=[{"packet": packet, "review": review}])

    def test_w11_the_packet_withholds_the_family_the_expectation_and_the_category(self):
        manifest = self.manifest()
        first = self.run_evaluate(manifest)
        packet = H.blinded_packet(manifest, first, reviewer_token="reviewer-a1")
        hidden = {"family", "expectation", "category", "outcome", "case_id", "reasons"}
        for entry in packet["cases"]:
            self.assertEqual({"case_token", "question", "evidence", "retrieval",
                              "verdict", "answer", "citations"}, set(entry))
            self.assertEqual(set(), set(entry) & hidden)
            for item in entry["evidence"]:
                self.assertEqual({"chunk_id", "document_title", "section", "text"},
                                 set(item))
        blob = json.dumps(packet, sort_keys=True)
        # Family and expectation tokens never appear; a category label is an
        # ordinary English word and may occur inside a question, so the labels
        # are checked structurally above rather than by substring.
        for token in list(H.FAMILIES) + list(H.EXPECTATIONS) + list(H.OUTCOMES):
            self.assertNotIn(token, blob)
        self.assertEqual(H.PACKET_SCHEMA, packet["schema"])

    def test_w12_a_decision_carrying_a_field_the_packet_hid_is_refused(self):
        manifest = self.manifest()
        first = self.run_evaluate(manifest)
        packet = H.blinded_packet(manifest, first, reviewer_token="reviewer-a1")
        review = F.review_document(manifest, packet, "reviewer-a1")
        review["decided"][0]["arm"] = "candidate-a"
        with self.assertRaisesRegex(H.HeldOutError, "unknown field"):
            self.run_evaluate(manifest, reviews=[{"packet": packet, "review": review}])

    def test_w13_packets_are_determinist_and_blind_across_reviewers(self):
        manifest = self.manifest()
        first = self.run_evaluate(manifest)
        one = H.blinded_packet(manifest, first, reviewer_token="reviewer-a1")
        again = H.blinded_packet(manifest, first, reviewer_token="reviewer-a1")
        other = H.blinded_packet(manifest, first, reviewer_token="reviewer-b1")
        self.assertEqual(H.canonical(one), H.canonical(again))
        self.assertEqual(one["packet_id"], again["packet_id"])
        self.assertNotEqual(one["packet_id"], other["packet_id"])
        tokens = {entry["case_token"] for entry in one["cases"]}
        self.assertEqual(tokens, {entry["case_token"] for entry in again["cases"]})
        self.assertEqual(set(), tokens & {entry["case_token"] for entry in other["cases"]})
        self.assertNotEqual([entry["case_token"] for entry in one["cases"]],
                            [entry["case_token"] for entry in again["cases"]][::-1]
                            if len(one["cases"]) > 1 else [])

    def test_w14_the_ledger_is_reproducible_and_carrieth_no_case_text(self):
        manifest = self.manifest()
        first = self.sealed(manifest)
        second = self.sealed(manifest)
        self.assertEqual(H.canonical(first), H.canonical(second))
        text = H.canonical(first).decode("utf-8")
        for case in manifest.cases:
            self.assertNotIn(case.question, text)
            for chunk in case.evidence:
                self.assertNotIn(chunk.text, text)
        by_id = {entry["case_id"]: entry for entry in first["cases"]}
        probe = manifest.case("ws-water-boil")
        self.assertEqual(H.sha256_bytes(probe.question.encode("utf-8")),
                         by_id["ws-water-boil"]["question_sha256"])
        self.assertEqual(probe.digest, by_id["ws-water-boil"]["case_digest"])

    # -- the binding ------------------------------------------------------
    def test_w15_a_manifest_authored_against_another_corpus_is_refused(self):
        manifest = self.manifest()
        self.archive.write_bytes(self.archive.read_bytes() + b"\n")
        with self.assertRaisesRegex(H.HeldOutError, "not the corpus this manifest"):
            self.run_evaluate(manifest)

    def test_w16_a_corrupt_model_lock_faileth_the_evaluation(self):
        corrupt = F.corrupt_model_lock(F.MODEL_LOCK, self.root / "corrupt.json")
        manifest = self.manifest(
            lock_sha256=hashlib.sha256(corrupt.read_bytes()).hexdigest())
        with self.assertRaisesRegex(H.HeldOutError, "model lock is corrupt"):
            self.run_evaluate(manifest, model_lock_path=corrupt)
        # And a ledger made against the sound lock cannot be carried across a
        # register that has moved since.
        sound = self.sealed(self.manifest())
        errors, _summary = H.verify_record(sound, manifest=self.manifest(),
                                           model_lock_path=corrupt)
        self.assertTrue(any("model lock changed since the evaluation" in item
                            for item in errors), errors)
        self.assertTrue(any("model lock is corrupt" in item for item in errors), errors)

    def test_w17_a_corrupt_or_foreign_approval_is_refused(self):
        private = self.root / "owner.key"
        trust = self.root / "owner-trust.json"
        generate_test_keypair(private, trust)
        signed = self.root / "archive.manifest.json"
        create_manifest(
            self.archive, signed, tier="LIGHT", archive_schema=3,
            source_manifest_sha256=F.PROVENANCE_REVIEW.source_manifest,
            review_manifest_sha256=F.PROVENANCE_REVIEW.review_manifest,
            corpus_manifest_sha256=F.PROVENANCE_REVIEW.corpus_manifest,
            build_tool_commit="b" * 40, private_key=load_private_key(private),
            key_id="TEST-ONLY")
        other_private = self.root / "foreign.key"
        foreign_trust = self.root / "foreign-trust.json"
        generate_test_keypair(other_private, foreign_trust, )
        manifest = self.manifest()
        with self.assertRaisesRegex(H.HeldOutError, "signed approval of this corpus is "
                                                    "not valid"):
            self.run_evaluate(manifest, approval_path=signed,
                              trust_store_path=foreign_trust)
        # The owner's own store accepteth it, and the record carrieth the bond.
        document = self.run_evaluate(manifest, approval_path=signed,
                                     trust_store_path=trust)
        self.assertEqual(H.sha256_file(signed),
                         document["approval"]["manifest_sha256"])
        # A tampered approval is refused rather than merely distrusted. It is
        # written compactly, so the tamper is aimed at the literal bytes.
        before = signed.read_text(encoding="utf-8")
        after = before.replace('"archive_schema":3', '"archive_schema":9', 1)
        self.assertNotEqual(before, after, "the fixture no longer carrieth the field")
        signed.write_text(after, encoding="utf-8")
        with self.assertRaisesRegex(H.HeldOutError, "not valid"):
            self.run_evaluate(manifest, approval_path=signed, trust_store_path=trust)

    def test_w18_the_archive_facts_must_agree_with_the_manifest(self):
        with self.assertRaisesRegex(H.HeldOutError, "carrieth 30 chunks"):
            self.run_evaluate(self.manifest(chunk_count=99))
        with self.assertRaisesRegex(H.HeldOutError, "not the tier"):
            self.run_evaluate(self.manifest(tier="MEDIUM"))
        with self.assertRaisesRegex(H.HeldOutError, "own corpus digest"):
            self.run_evaluate(self.manifest(corpus_sha256="9" * 64))

    def test_w19_the_manifest_door_refuseth_incomplete_taxonomy(self):
        for overrides, cry in (
                (dict(categories=["water"]), "undeclared category"),
                (dict(categories=F.FIXTURE_CATEGORIES + ("ghost",)), "carry no case"),
                (dict(cases=[dict(c) for c in F.FIXTURE_CASES
                             if c["family"] != "unanswerable"]),
                 "exerciseth no case"),
        ):
            label = json.dumps(overrides, default=str)[:40]
            with self.subTest(overrides=label):
                F.write_manifest(self.plan_path, F.manifest_plan(self.archive, **overrides))
                with self.assertRaisesRegex(H.HeldOutError, cry):
                    H.load_manifest(self.plan_path)
        plan = F.manifest_plan(self.archive)
        plan["cases"][0]["family"] = "vibes"
        F.write_manifest(self.plan_path, plan)
        with self.assertRaisesRegex(H.HeldOutError, "family is unknown"):
            H.load_manifest(self.plan_path)

    def test_w20_the_manifest_door_refuseth_future_schemas_and_bad_json(self):
        plan = F.manifest_plan(self.archive)
        plan["schema"] = H.MANIFEST_SCHEMA + 1
        F.write_manifest(self.plan_path, plan)
        with self.assertRaisesRegex(H.HeldOutError, "refuseth every future version"):
            H.load_manifest(self.plan_path)
        self.plan_path.write_text('{"schema": 1, "schema": 1}', encoding="utf-8")
        with self.assertRaisesRegex(H.HeldOutError, "duplicate key"):
            H.load_manifest(self.plan_path)
        self.plan_path.write_text('{"schema": NaN}', encoding="utf-8")
        with self.assertRaisesRegex(H.HeldOutError, "constant"):
            H.load_manifest(self.plan_path)
        self.plan_path.write_text("{not json", encoding="utf-8")
        with self.assertRaisesRegex(H.HeldOutError, "not valid JSON"):
            H.load_manifest(self.plan_path)

    def test_w21_a_must_answer_case_without_evidence_is_refused(self):
        plan = F.manifest_plan(self.archive)
        for entry in plan["cases"]:
            if entry["case_id"] == "ws-bleed-press":
                entry["evidence"] = []
        F.write_manifest(self.plan_path, plan)
        with self.assertRaisesRegex(H.HeldOutError, "declare the evidence"):
            H.load_manifest(self.plan_path)

    def test_w22_an_archive_retrieval_case_is_graded_on_the_production_join(self):
        manifest = self.manifest()
        document = self.run_evaluate(manifest)
        by_id = {entry["case_id"]: entry for entry in document["cases"]}
        entry = by_id["ws-archive-retrieval"]
        self.assertEqual("archive", entry["retrieval"])
        expected = [chunk.chunk_id for chunk in production_retrieve(
            self.archive, manifest.case("ws-archive-retrieval").question, 6)]
        self.assertEqual(expected, entry["evidence_ids"])
        self.assertEqual(6, len(entry["evidence_ids"]))
        declared = by_id["ws-water-boil"]["evidence_ids"]
        self.assertEqual([1, 2], declared)

    def test_w23_the_ledger_rederiveth_its_own_census(self):
        document = self.sealed(self.manifest())
        tampered = json.loads(json.dumps(document))
        tampered["cases"][0]["case_digest"] = "0" * 64
        errors = H.internal_completeness_errors(tampered)
        self.assertTrue(any("which is not the digest the census recordeth" in item
                            for item in errors), errors)
        tampered = json.loads(json.dumps(document))
        tampered["cases"] = tampered["cases"][:-1]
        errors = H.internal_completeness_errors(tampered)
        self.assertTrue(any("census declareth" in item for item in errors), errors)
        errors, _summary = H.verify_record(tampered, manifest=H.load_manifest(self.plan_path))
        self.assertTrue(errors)

    def test_w24_an_excluded_case_refuseth_completeness(self):
        document = self.sealed(self.manifest())
        entries = json.loads(json.dumps(document["cases"]))
        for entry in entries:
            if entry["case_id"] == "un-gps":
                entry["outcome"] = "excluded"
                entry["exclusion"] = "dependency-unavailable"
        errors = H.completeness_errors(H.load_manifest(self.plan_path), entries)
        self.assertTrue(any("an evaluation with exclusions is not complete" in item
                            for item in errors), errors)
        entries = json.loads(json.dumps(document["cases"]))
        for entry in entries:
            if entry["case_id"] == "un-gps":
                entry["outcome"] = "excluded"
        errors = H.completeness_errors(H.load_manifest(self.plan_path), entries)
        self.assertTrue(any("no recorded reason" in item for item in errors), errors)

    def test_w25_two_reviewers_who_disagree_refuse_the_ledger(self):
        manifest = self.manifest()
        first = self.run_evaluate(manifest)
        packets, reviews = [], []
        for reviewer, verdict in (("reviewer-a1", "accept"), ("reviewer-b1", "reject")):
            packet = H.blinded_packet(manifest, first, reviewer_token=reviewer)
            packets.append(packet)
            reviews.append({"packet": packet, "review": F.review_document(
                manifest, packet, reviewer,
                overrides={"ws-water-boil": {"verdict": verdict}})})
        with self.assertRaisesRegex(H.HeldOutError, "two reviewers who disagree"):
            self.run_evaluate(manifest, reviews=reviews)
        # Agreeing reviewers are one decision, not two votes counted twice:
        # every case is decided, and both hands stand named in the census.
        second = H.blinded_packet(manifest, first, reviewer_token="reviewer-b1")
        agreeing = {"packet": second,
                    "review": F.review_document(manifest, second, "reviewer-b1")}
        document = self.run_evaluate(manifest, reviews=[reviews[0], agreeing])
        self.assertEqual("COMPLETE", document["status"])
        self.assertEqual(len(document["cases"]),
                         document["review_census"]["decisions_entered"])
        self.assertEqual(0, document["review_census"]["undecided"])
        self.assertEqual(["reviewer-a1"], document["review_census"]["reviewers"])

    def test_w26_the_gate_configuration_is_transcribed_into_the_ledger(self):
        document = self.sealed(self.manifest())
        self.assertEqual("safety.gate.evaluate", document["gate"]["entry_point"])
        self.assertEqual(dict(GATE_CFG), document["gate"]["cfg"])
        self.assertEqual(H.sha256_bytes(H.canonical(dict(GATE_CFG))),
                         document["gate"]["cfg_sha256"])
        tuned = dict(GATE_CFG, colocation_floor=0.05)
        self.assertNotEqual(document["gate"]["cfg_sha256"],
                            H.sha256_bytes(H.canonical(tuned)))

    # -- the command door and the boundary --------------------------------
    def test_w27_the_command_door_reporteth_zero_and_one(self):
        manifest = self.manifest()
        record = self.root / "record.json"
        code = H.main(["evaluate", "--manifest", str(self.plan_path), "--archive",
                       str(self.archive), "--model-lock", str(F.MODEL_LOCK), "--out",
                       str(record)])
        self.assertEqual(1, code, "an unreviewed ledger must not report success")
        first = H.load_record(record)
        packet_path = self.root / "packet.json"
        H.write_canonical(packet_path,
                          H.blinded_packet(manifest, first, reviewer_token="reviewer-a1"))
        packet = H.load_record(packet_path)
        review_path = self.root / "review.json"
        F.write_document(review_path, F.review_document(manifest, packet, "reviewer-a1"))
        code = H.main(["evaluate", "--manifest", str(self.plan_path), "--archive",
                       str(self.archive), "--model-lock", str(F.MODEL_LOCK),
                       "--packet", str(packet_path), "--review", str(review_path),
                       "--out", str(record)])
        self.assertEqual(0, code)
        code = H.main(["verify", "--record", str(record), "--manifest",
                       str(self.plan_path), "--archive", str(self.archive),
                       "--model-lock", str(F.MODEL_LOCK)])
        self.assertEqual(0, code)
        cases = self.flipped("ws-water-boil", expectation="must_refuse")
        F.write_manifest(self.plan_path, F.manifest_plan(self.archive, cases=cases))
        code = H.main(["verify", "--record", str(record), "--manifest",
                       str(self.plan_path), "--archive", str(self.archive)])
        self.assertEqual(1, code, "a ledger answering another manifest must be refused")
        code = H.main(["evaluate", "--manifest", str(self.plan_path), "--archive",
                       str(self.root / "absent.db"), "--out", str(record)])
        self.assertEqual(1, code)

    def test_w28_an_interrupted_write_leaveth_no_partial_ledger(self):
        manifest = self.manifest()
        target = self.root / "record.json"
        previous = b'{"previous": "ledger"}\n'
        target.write_bytes(previous)
        with patch.object(H.os, "replace", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.sealed(manifest, out=target)
        self.assertEqual(previous, target.read_bytes())
        self.assertEqual([], [p.name for p in self.root.iterdir()
                              if p.name.startswith(".heldout-")])

    def test_w29_a_missing_dependency_is_refused_by_name(self):
        manifest = self.manifest()
        with self.assertRaisesRegex(H.HeldOutError, "Archive is missing"):
            self.run_evaluate(manifest, archive_path=self.root / "absent.db")
        with self.assertRaisesRegex(H.HeldOutError, "model lock is missing"):
            self.run_evaluate(manifest, model_lock_path=self.root / "absent-lock.json")
        with self.assertRaisesRegex(H.HeldOutError, "signed approval is missing"):
            self.run_evaluate(manifest, approval_path=self.root / "absent.json",
                              trust_store_path=self.root / "absent-trust.json")
        with self.assertRaisesRegex(H.HeldOutError, "trust store is missing"):
            self.run_evaluate(manifest, approval_path=self.plan_path,
                              trust_store_path=self.root / "absent-trust.json")
        with self.assertRaisesRegex(H.HeldOutError, "cannot read"):
            H.load_manifest(self.root / "absent-manifest.json")

    def test_w30_the_review_pool_is_the_only_door_to_a_packet(self):
        manifest = self.manifest()
        first = self.run_evaluate(manifest)
        with self.assertRaisesRegex(H.HeldOutError, "not in the manifest's review pool"):
            H.blinded_packet(manifest, first, reviewer_token="reviewer-z9")
        review = F.review_document(manifest, H.blinded_packet(
            manifest, first, reviewer_token="reviewer-a1"), "reviewer-a1")
        review["decided"] = []
        with self.assertRaisesRegex(H.HeldOutError, "will not invent one"):
            H.load_review(F.write_document(self.root / "review.json", review), manifest,
                          H.blinded_packet(manifest, first, reviewer_token="reviewer-a1"))


if __name__ == "__main__":
    unittest.main()
