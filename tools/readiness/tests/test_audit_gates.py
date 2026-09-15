#! /usr/bin/env python3
"""GS-GATE-001 — the release-gate checker must not accept unproved CLOSED claims.

The audit's independent gate-negative probes are moved into the canonical suite here,
with their assertions INTACT and only their imports rebound to this repository:

  W01 a SCHEMA-DOWNGRADE (schema_version=1) with an unknown CLOSED gate and a
      nonexistent all-1 SHA, plus Android CLOSED without evidence, must be REFUSED
  W02 an EXTERNAL candidate (schema 2) set CLOSED at the candidate SHA with no evidence
      block and a NONEXISTENT workflow job must be REFUSED
  W03 THE POSITIVE CONTROL: a valid all-OPEN registry is still ACCEPTED
  W04 every REQUIRED gate must be represented, and an unknown gate name is refused
  W05 a CLOSED gate's evidence commit must RESOLVE (a resolver that rejecteth every SHA
      must make every CLOSED claim fail)
  W06 a CI gate must name a workflow job that EXISTS in the workflow text
  W07 an external human/device gate must carry its signed/approved evidence, not merely a
      status
  W08 the REAL status document validates, with the five external gates left OPEN/BLOCKED

AUDIT-004 (the independent review of the first GS-GATE-001 submission) reproduced TWO further
bypasses, adopted below with their assertions INTACT:

  W09 THE TYPED POSITIVE CONTROL: a locally VALID device closure -- every required value carrying
      a real value in the shape its field requireth -- must still be ACCEPTED, or the checker is
      merely refusing everything
  W10 the audit's own probe: a CLOSED device gate whose required KEYS are all present but whose
      VALUES are null (`device_matrix=None`, `result_sha256=None`, `test_results=None`) is ACCEPTED
  W11 one required value NULLED ALONE at a time (and once REMOVED) must each be refused, so a
      refusal can never come from a different defect than the one the arm nameth
  W12 the audit's own probe: a job disabled by `if: ${{ false }}` is ACCEPTED, because the parser
      recognised only the literal `if: false`
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "ci"))


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "ci" / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


gates = _load("audit_gates_module", "check_release_gates_status.py")

EXTERNALLY_BLOCKED = {
    "A-06-independent-noise-vectors", "production-corpus", "model-native-stack",
    "device-interoperability", "accessibility", "battery-thermal",
    "signing-store-approval",
}


def fixture():
    """The audit's own fixture: the real status document, every gate OPEN and stripped."""
    document = json.loads(gates.STATUS.read_text())
    for gate in document["gates"]:
        gate["status"] = "OPEN"
        gate["evidence_commit"] = None
        gate.pop("evidence", None)
    return document


class GateNegativeProbeTest(unittest.TestCase):
    """W01-W03 -- the audit's three probes, assertions intact."""

    def test_w01_a_schema_downgrade_cannot_accept_an_unproved_closed_gate(self):
        document = fixture()
        document["schema_version"] = 1
        document["gates"].append({"gate": "not-a-real-gate", "status": "CLOSED",
                                  "evidence_commit": "1" * 40})
        android = next(g for g in document["gates"]
                       if g["gate"] == "android-archive-only-release")
        android["status"] = "CLOSED"
        android["evidence_commit"] = "1" * 40
        problems = gates.validate_status(document, resolve_evidence=lambda sha: False,
                                         workflow_text=gates.WORKFLOW.read_text())
        self.assertTrue(problems,
                        "Schema downgrade accepted unknown gate and nonexistent CLOSED SHA "
                        "without evidence")

    def test_w02_an_external_candidate_without_results_or_a_real_job_cannot_close(self):
        document = fixture()
        noise = next(g for g in document["gates"]
                     if g["gate"] == "A-06-independent-noise-vectors")
        noise.update(status="CLOSED", evidence_commit="b" * 40,
                     ci_job="release-gates.yml / nonexistent-job")
        problems = gates.validate_status(document, resolve_evidence=lambda sha: True,
                                         candidate=lambda: "b" * 40,
                                         workflow_text=gates.WORKFLOW.read_text())
        self.assertTrue(problems,
                        "Candidate external closure accepted no evidence/results and "
                        "nonexistent job")

    def test_w03_a_valid_open_registry_remains_accepted(self):
        self.assertEqual([], gates.validate_status(fixture(),
                                                   workflow_text=gates.WORKFLOW.read_text()))


class GateClosureEvidenceTest(unittest.TestCase):
    """W04-W07 -- what a CLOSED claim must prove."""

    def test_w04_an_unknown_gate_name_is_refused(self):
        document = fixture()
        document["gates"].append({"gate": "invented-by-the-builder", "status": "OPEN"})
        problems = gates.validate_status(document, workflow_text=gates.WORKFLOW.read_text())
        self.assertTrue([p for p in problems if "invented-by-the-builder" in p], problems)

    def test_w05_every_closed_claim_must_resolve_its_evidence(self):
        """A resolver that rejecteth EVERY sha must make every CLOSED claim fail -- and the
        real document's own CLOSED gate (android-archive-only-release) is included, so the
        rule is not one that only fixtures meet."""
        document = json.loads(gates.STATUS.read_text())
        for gate in document["gates"]:
            if gate["gate"] in EXTERNALLY_BLOCKED:
                gate["status"] = "OPEN"
                gate["evidence_commit"] = None
                gate.pop("evidence", None)
        problems = gates.validate_status(document, resolve_evidence=lambda sha: False,
                                         workflow_text=gates.WORKFLOW.read_text())
        self.assertTrue([p for p in problems if "android-archive-only-release" in p], problems)

    def test_w06_a_closed_ci_gate_must_name_a_real_job(self):
        document = fixture()
        android = next(g for g in document["gates"]
                       if g["gate"] == "android-archive-only-release")
        android.update(status="CLOSED", evidence_commit="c" * 40,
                       ci_job="repository-verification.yml / no-such-job")
        problems = gates.validate_status(document, resolve_evidence=lambda sha: True,
                                         candidate=lambda: "c" * 40,
                                         workflow_text=gates.WORKFLOW.read_text())
        self.assertTrue([p for p in problems if "no-such-job" in p or "job" in p.lower()],
                        problems)

    def test_w07_an_external_gate_needs_its_own_approval_evidence(self):
        document = fixture()
        signing = next(g for g in document["gates"]
                       if g["gate"] == "signing-store-approval")
        signing.update(status="CLOSED", evidence_commit="d" * 40)
        problems = gates.validate_status(document, resolve_evidence=lambda sha: True,
                                         candidate=lambda: "d" * 40,
                                         workflow_text=gates.WORKFLOW.read_text())
        self.assertTrue(problems, "an external approval closed without its evidence")


class GateRepositoryTest(unittest.TestCase):
    """W08 -- the real document, and the external gates' own state."""

    def test_w08_the_real_status_document_is_valid_and_the_gates_stay_open(self):
        document = json.loads(gates.STATUS.read_text())
        problems = gates.validate_status(document, workflow_text=gates.WORKFLOW.read_text())
        self.assertEqual([], problems, problems)
        document = json.loads(gates.STATUS.read_text())
        for gate in document["gates"]:
            if gate["gate"] in EXTERNALLY_BLOCKED:
                self.assertIn(gate["status"], ("OPEN", "BLOCKED"), gate["gate"])
                self.assertIsNone(gate.get("closure_evidence"),
                                  "%s must not claim closure evidence" % gate["gate"])


class AdoptedAudit004GateProbeTest(unittest.TestCase):
    """W09-W12 -- AUDIT-004's two executed gate failures, adopted assertion-intact.

    W09 is the TYPED POSITIVE CONTROL: a synthetic, clearly labelled device closure in which
    every required field carrieth a real value of the right SHAPE. It closeth no real gate --
    the operator and the matrix are synthetic -- and it existeth so that W10/W11 can prove a
    refusal of the NAMED defect rather than of everything.
    """

    def _head(self):
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=str(ROOT),
                                       text=True).strip()

    def check(self, document, workflow=None):
        head = self._head()
        return gates.validate_status(
            document, resolve_evidence=lambda sha: "commit" if sha == head else "",
            candidate=lambda: head,
            workflow_text=workflow if workflow is not None else gates.WORKFLOW.read_text())

    def valid_device_closure(self):
        document = fixture()
        gate = next(g for g in document["gates"] if g["gate"] == "device-interoperability")
        gate.update(status="CLOSED", evidence_commit=self._head(),
                    ci_job="not-runnable-in-ci",
                    closure_requirement="physical evidence required (SYNTHETIC fixture)",
                    evidence={"executor": "synthetic audit operator",
                              "operator_role": "synthetic audit operator",
                              "device_matrix": ["synthetic-device-a", "synthetic-device-b"],
                              "result_sha256": "3" * 64,
                              "review_date": "2026-09-15",
                              "test_results": {"executed": 4, "failed": 0}})
        return document, gate

    def test_w09_the_typed_positive_control_is_accepted(self):
        document, _ = self.valid_device_closure()
        self.assertEqual([], self.check(document))

    def test_w10_a_null_device_proof_is_rejected(self):
        # THE AUDIT'S OWN PROBE, assertion and fixture intact: every required key is present,
        # and every VALUE that proveth anything is None.
        document = fixture()
        gate = next(g for g in document["gates"] if g["gate"] == "device-interoperability")
        gate.update(status="CLOSED", evidence_commit=self._head(), ci_job="not-runnable-in-ci",
                    closure_requirement="physical evidence required",
                    evidence={"executor": "synthetic audit role", "test_results": None,
                              "device_matrix": None, "operator_role": "synthetic audit role",
                              "result_sha256": None})
        self.assertTrue(self.check(document), "null device matrix/result accepted as CLOSED")

    def test_w11_each_required_value_nulled_alone_is_rejected(self):
        for field in ("device_matrix", "operator_role", "result_sha256", "test_results", "executor"):
            document, gate = self.valid_device_closure()
            gate["evidence"][field] = None
            self.assertTrue(self.check(document),
                            "a CLOSED device gate accepted a NULL %r" % field)
        for field in ("device_matrix", "result_sha256"):
            document, gate = self.valid_device_closure()
            gate["evidence"].pop(field)
            self.assertTrue(self.check(document),
                            "a CLOSED device gate accepted a MISSING %r" % field)
        # ... and an EMPTY matrix is not a device run
        document, gate = self.valid_device_closure()
        gate["evidence"]["device_matrix"] = []
        self.assertTrue(self.check(document), "an empty device matrix accepted as a device run")

    def test_w12_an_expression_disabled_ci_job_is_rejected(self):
        document = fixture()
        gate = next(g for g in document["gates"]
                    if g["gate"] == "A-06-independent-noise-vectors")
        head = self._head()
        gate.update(status="CLOSED", evidence_commit=head,
                    ci_job="release-gates.yml / noise-conformance",
                    evidence={"executor": "release-gates.yml / noise-conformance",
                              "test_results": {"executed": 1, "failed": 0},
                              "source_commit": head, "source_sha256": "1" * 64,
                              "fixture_sha256": "2" * 64,
                              "reviewer_role": "synthetic audit role",
                              "review_date": "2026-09-15"})
        document_noise = document
        workflow = ("jobs:\n  noise-conformance:\n    if: ${{ false }}\n"
                    "    runs-on: ubuntu-latest\n    steps:\n      - run: echo no-tests\n")
        self.assertTrue(self.check(document_noise, workflow),
                        "expression-disabled job accepted as CLOSED")
        # the same closure against an ENABLED job is the positive control for this arm
        enabled = workflow.replace("    if: ${{ false }}\n", "")
        self.assertEqual([], self.check(document_noise, enabled))

    def test_w13_the_job_disabling_forms_are_all_recognised(self):
        """`${{ false }}` is not the only spelling of a disabled job, and an ENABLED condition
        (`inputs.gate == 'open'`, which the real workflow carrieth) must stay enabled."""
        head = self._head()
        for condition in ("if: false", "if: ${{ false }}", "if: 'false'", "if: ${{ !true }}",
                          "if: ${{false}}", "if: FALSE"):
            document = fixture()
            gate = next(g for g in document["gates"]
                        if g["gate"] == "A-06-independent-noise-vectors")
            gate.update(status="CLOSED", evidence_commit=head,
                        ci_job="release-gates.yml / noise-conformance",
                        evidence={"executor": "release-gates.yml / noise-conformance",
                                  "test_results": {"executed": 1, "failed": 0},
                                  "source_commit": head, "source_sha256": "1" * 64,
                                  "fixture_sha256": "2" * 64,
                                  "reviewer_role": "synthetic audit role",
                                  "review_date": "2026-09-15"})
            workflow = ("jobs:\n  noise-conformance:\n    %s\n    runs-on: ubuntu-latest\n"
                        "    steps:\n      - run: echo no-tests\n" % condition)
            self.assertTrue(self.check(document, workflow),
                            "a job disabled by %r was accepted as CLOSED" % condition)
        # ... and the conditional form the REAL workflow useth remaineth enabled
        document = fixture()
        gate = next(g for g in document["gates"]
                    if g["gate"] == "A-06-independent-noise-vectors")
        gate.update(status="CLOSED", evidence_commit=head,
                    ci_job="release-gates.yml / noise-conformance",
                    evidence={"executor": "release-gates.yml / noise-conformance",
                              "test_results": {"executed": 1, "failed": 0},
                              "source_commit": head, "source_sha256": "1" * 64,
                              "fixture_sha256": "2" * 64,
                              "reviewer_role": "synthetic audit role",
                              "review_date": "2026-09-15"})
        enabled_wf = ("jobs:\n  noise-conformance:\n    if: inputs.gate == 'open'\n"
                      "    runs-on: ubuntu-latest\n    steps:\n      - run: echo tests\n")
        self.assertEqual([], self.check(document, enabled_wf),
                         "a CONDITIONAL job (not statically disabled) must not be refused")


if __name__ == "__main__":
    unittest.main(verbosity=2)
