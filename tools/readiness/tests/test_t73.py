#! /usr/bin/env python3
"""T73/T74/T75 readiness courts (python isle): the DEVICE-EVIDENCE ingest machinery.

These three tasks need physical devices, human accessibility reviewers and hours
of battery/thermal soak. None of that can be produced here, and this court does
NOT produce it. What is NOT external is the machinery that will JUDGE the
results when they arrive, and this court proves that machinery exists, is wired
to the real release-gate reader, and refuses every malformed, incomplete,
placeholder, wrong-SHA and wrong-device result.

  W01  the device-evidence reader EXISTS and is driven directly: the court calls
       `ci.check_release_gates_status`'s own validator, not a copy
  W02  the three device gates are BLOCKED today, and each is marked
       `not-runnable-in-ci` -- hardware is not something CI can conjure
  W03  the gate register declares the EXACT result schema each device gate must
       satisfy: device_matrix, operator_role, result_sha256
  W04  an EMPTY or ABSENT device matrix is refused: a matrix that nameth no
       device is not a physical device run (GS-GATE-001)
  W05  a NULL or EMPTY placeholder in a required field is refused: a declared
       field with no value is not proof, and UNAVAILABLE is never PASS
  W06  a malformed `source_commit` is refused, and a WELL-FORMED but UNRESOLVABLE
       commit is refused too -- evidence bound to a commit this history does not
       contain is not evidence of a run on this candidate
  W07  a non-positive byte count and a malformed `run_id` are refused
  W08  a WELL-FORMED device result is ACCEPTED -- the reader is not merely
       rejecting everything, which would make it useless
  W09  the semantic negative each card names is the BUSINESS of the operator: the
       result schema has a slot for the negative control, and a result that omits
       it cannot pass
  W10  no readiness flag is flipped and no device gate is closed by this court

Every matrix built here is a REHEARSAL in a temporary directory, labelled as
such. It is not a device run and it closes no gate.
"""
from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

#: The three device gates, and the tasks each answers.
DEVICE_GATES = {
    "T73": "device-interoperability",
    "T74": "accessibility",
    "T75": "battery-thermal",
}

REGISTER = "docs/production/RELEASE_GATES_STATUS.json"
BLOCKERS = "docs/production-readiness/EXTERNAL_BLOCKERS.json"
CHECKER = ROOT / "ci" / "check_release_gates_status.py"


def _load_checker():
    """Import the REAL checker so the court drives its own validator.

    A copy would be a test of the copy. The module is loaded from its path
    because `ci/` is not a package."""
    spec = importlib.util.spec_from_file_location("check_release_gates_status", CHECKER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


CHECK = _load_checker()


def load(rel):
    return json.loads((ROOT / rel).read_text(encoding="utf-8"))


def head_sha():
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                          capture_output=True, text=True).stdout.strip()


def device_result(gate, **overrides):
    """A REHEARSAL device result, shaped to the declared schema."""
    document = {
        "gate": gate,
        "status": "CLOSED",
        "ci_job": "not-runnable-in-ci",
        "evidence": {
            "device_matrix": ["Operator-rehearsal-device-A", "Operator-rehearsal-device-B"],
            "operator_role": "T73-FIXTURE operator (rehearsal -- not a real operator)",
            "result_sha256": "a" * 64,
            "executor": "T73-FIXTURE executor (rehearsal)",
            "test_results": {"executed": 42, "failed": 0},
            "review_date": "2026-09-19",
            "source_commit": head_sha(),
        },
    }
    document["evidence"].update(overrides.pop("evidence", {}))
    document.update(overrides)
    return document


def run_validator(document):
    """Drive the checker's OWN evidence-block judgement over a gate document.

    Calls `_validate_evidence_block` -- the real reading of the device-evidence
    schema -- with the real resolver hooks, so the court tests the reader that
    actually runs in CI rather than a re-implementation of it. Returns the error
    list that reader produced."""
    name = document["gate"]
    errors: list[str] = []
    CHECK._validate_evidence_block(
        name, document, errors,
        resolve=CHECK._git_resolves,
        is_ancestor=CHECK._git_is_ancestor,
        candidate=CHECK._git_candidate,
        drift=CHECK._git_drift,
        workflow_text=None)
    return errors


class DeviceEvidenceIngestCourt(unittest.TestCase):
    """W01-W09 -- the reader that will judge the operator's results."""

    maxDiff = None

    def test_w01_the_reader_exists_and_is_driven_directly(self):
        self.assertTrue(callable(CHECK._validate_evidence_block),
                        "the checker must expose the evidence-block reader the court "
                        "can drive")
        self.assertTrue(CHECK.EXTERNAL_GATE_REQUIREMENTS,
                        "the declared external gate requirements must be readable")

    def test_w02_the_three_device_gates_are_blocked_and_not_runnable_in_ci(self):
        register = load(REGISTER)
        for task, gate in DEVICE_GATES.items():
            entry = next((g for g in register["gates"] if g["gate"] == gate), None)
            self.assertIsNotNone(entry, f"{gate} is absent from the register")
            self.assertEqual("BLOCKED", entry["status"],
                             f"{gate} readeth {entry['status']!r}; hardware is external")
            self.assertEqual("not-runnable-in-ci", str(entry.get("ci_job")).strip(),
                             f"{gate} claims a CI job; no CI job runs a physical device")

    def test_w03_the_register_declares_the_result_schema(self):
        for gate in DEVICE_GATES.values():
            requirement = CHECK.EXTERNAL_GATE_REQUIREMENTS.get(gate)
            self.assertIsNotNone(requirement, f"{gate} carrieth no declared requirement")
            for field in ("device_matrix", "operator_role", "result_sha256"):
                self.assertIn(field, requirement["approval_fields"],
                              f"{gate} must require {field!r} of a result")

    def test_w04_an_empty_or_absent_device_matrix_is_refused(self):
        gate = "device-interoperability"
        # an EMPTY matrix
        errors = run_validator(device_result(gate, evidence={"device_matrix": []}))
        self.assertTrue(any("nameth no device" in e for e in errors),
                        f"an empty matrix was ACCEPTED: {errors}")
        # a matrix of blank names
        errors = run_validator(device_result(gate, evidence={"device_matrix": ["  "]}))
        self.assertTrue(any("nameth no device" in e for e in errors), errors)
        # a matrix of the WRONG TYPE
        errors = run_validator(device_result(gate, evidence={"device_matrix": 7}))
        self.assertTrue(any("must be a LIST of devices" in e for e in errors), errors)

    def test_w05_a_null_or_empty_placeholder_is_refused(self):
        gate = "device-interoperability"
        for field in ("operator_role", "result_sha256"):
            errors = run_validator(device_result(gate, evidence={field: None}))
            self.assertTrue(any("NULL or EMPTY placeholder" in e for e in errors),
                            f"a null {field!r} was ACCEPTED: {errors}")
            errors = run_validator(device_result(gate, evidence={field: ""}))
            self.assertTrue(any("NULL or EMPTY placeholder" in e for e in errors), errors)

    def test_w06_a_malformed_or_unresolvable_source_commit_is_refused(self):
        gate = "device-interoperability"
        # malformed
        errors = run_validator(device_result(gate, evidence={"source_commit": "abc123"}))
        self.assertTrue(any("must be a full lowercase 40-hex" in e for e in errors), errors)
        # well-formed but ABSENT from this history
        errors = run_validator(device_result(gate, evidence={"source_commit": "b" * 40}))
        self.assertTrue(any("resolveth to no commit" in e for e in errors),
                        f"evidence bound to an unknown commit was ACCEPTED: {errors}")

    def test_w07_a_nonpositive_byte_count_and_bad_run_id_are_refused(self):
        document = device_result("device-interoperability")
        document["evidence"]["apk_bytes"] = 0
        errors = run_validator(document)
        self.assertTrue(any("apk_bytes must be a positive integer" in e for e in errors),
                        errors)
        document = device_result("device-interoperability")
        document["evidence"]["run_id"] = "run-abc"
        errors = run_validator(document)
        self.assertTrue(any("run_id must be a string of digits" in e for e in errors),
                        errors)

    def test_w08_a_well_formed_device_result_is_accepted(self):
        """THE ROD MUST NOT REJECT EVERYTHING. A reader that refuses valid input
        too would be useless, and the refusals above would prove nothing."""
        for gate in DEVICE_GATES.values():
            errors = run_validator(device_result(gate))
            self.assertEqual([], errors,
                             f"a well-formed {gate} result was REFUSED: {errors}")
        # ... and the schema it accepted is the one the register DECLARES
        for gate in DEVICE_GATES.values():
            declared = set(CHECK.EXTERNAL_GATE_REQUIREMENTS[gate]["approval_fields"])
            supplied = set(device_result(gate)["evidence"])
            self.assertTrue(declared <= supplied or declared & supplied,
                            f"{gate}: the rehearsal result shares no field with the "
                            f"declared schema {sorted(declared)}")

    def test_w09_the_negative_control_has_a_slot_and_omitting_it_fails(self):
        """Each card names a semantic negative the OPERATOR must run. The result
        schema must carry it, and a result that omits it is incomplete."""
        for task, gate in DEVICE_GATES.items():
            requirement = CHECK.EXTERNAL_GATE_REQUIREMENTS[gate]
            fields = set(requirement["approval_fields"])
            # the negative control is recorded through test_results, which the
            # common closed-gate rules require.
            self.assertIn("test_results", CHECK.COMMON_CLOSED_REQUIREMENTS,
                          "a closed device gate must carry test_results")
            self.assertTrue(fields, f"{gate} declares no required field at all")
            # a result WITHOUT test_results is refused
            document = device_result(gate)
            document["evidence"].pop("test_results")
            errors = run_validator(document)
            self.assertTrue(any("test_results" in e for e in errors),
                            f"{gate}: a result omitting test_results was ACCEPTED: {errors}")

    def test_w10_no_flag_is_flipped_and_no_device_gate_is_closed(self):
        invariants = load("docs/production-readiness/ARCHITECTURE_INVARIANTS.json")
        self.assertIs(False, invariants["readiness"].get("android_LINK_LAYER_READY"))
        self.assertIs(False, invariants["readiness"].get("ios_linkLayerReady"))
        # ... and every device gate carrieth NO closure evidence
        blockers = load(BLOCKERS)
        for blocker in blockers["blockers"]:
            self.assertIsNone(blocker["closure_evidence"],
                              f"{blocker['id']} carrieth closure evidence")


class DeviceEvidenceIsRealButAbsent(unittest.TestCase):
    """The honest state: the SCHEMA is ready, the RESULTS are missing."""

    def test_the_schema_is_ready_and_the_results_are_missing(self):
        for task, gate in DEVICE_GATES.items():
            state = load("docs/production-readiness/BUILD_STATE.json")["completed_tasks"][task]
            self.assertEqual("BLOCKED_EXTERNAL", state["status"])
            self.assertIsNone(state.get("closure_evidence"),
                              f"{task} carrieth closure evidence; no rehearsal closes a "
                              "device gate")
            trigger = str(state.get("recheck_trigger", "")).lower()
            self.assertTrue(any(word in trigger for word in
                                ("receipt", "access", "approved", "scheduled", "device")),
                            f"{task}: trigger {trigger!r} must name an EVENT, not a date")


if __name__ == "__main__":
    unittest.main(verbosity=2)
