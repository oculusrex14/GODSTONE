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
"""
from __future__ import annotations

import importlib.util
import json
import pathlib
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
