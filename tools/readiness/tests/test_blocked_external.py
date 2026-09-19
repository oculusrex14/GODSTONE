#! /usr/bin/env python3
"""The blocked-external court: the FINAL frontier, made checkable.

Seventy-two tasks are COMPLETE and twelve are BLOCKED_EXTERNAL. This court existeth
so that "cannot run" is never mistaken for "was not done", and -- above all -- so that
NOBODY can make a gate green by writing a fixture:

  W01 the frontier: every catalogue task carrieth a COMPLETE or a BLOCKED_EXTERNAL
      record, and the four frontier tasks have COMPLETE internal prerequisites
  W02 a pending task with NO record is CAUGHT (the checker is fed the omission)
  W03 a blocked task may NOT claim COMPLETE, and a blocker may NOT carry closure
      evidence: a fixture can never close an external gate
  W04 TRANSITIVE HONESTY: a blocked task whose dependency is pending may not claim
      its internal prerequisites are complete -- and one whose dependencies ARE
      complete must say so
  W05 the readiness flags stay FALSE
  W06 the five externally-blocked release entries stay OPEN or BLOCKED; the ONE
      pre-existing CLOSED gate is registered WITH an ancestor-verified evidence
      commit, and a CLOSED entry with no register record is caught
  W07 every catalogue external_requirement mapeth to a blocker in the register
  W08 the register's dependent_tasks cover every blocked task BY NAME
  W09 every blocker nameth its artifact, its approving human role, its verification
      commands and its recheck trigger
  W10 the real repository PASSES, and the register's own frontier note carrieth the
      counts this court asserteth

No external gate is closed; readiness stays false; no device is claimed.
"""
from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

import blockers as blockers_module  # noqa: E402
from blockers import (  # noqa: E402
    CATALOGUE_TO_REGISTER, blocked_records, findings, load, pending_tasks,
    readiness_flags, report,
)

FILES = (
    "docs/production-readiness/BUILD_STATE.json",
    "docs/production-readiness/TASKS.json",
    "docs/production-readiness/EXTERNAL_BLOCKERS.json",
    "docs/production-readiness/ARCHITECTURE_INVARIANTS.json",
    "docs/production/RELEASE_GATES_STATUS.json",
)


class _Fixture:
    """A copy of the five declarations, so a witness can FEED the checker a
    violation (the T82 lesson: a checker witness must feed the checker)."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self._mirror_court_existence()
        for rel in FILES:
            destination = self.root / rel
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / rel, destination)

    def edit(self, rel, mutate):
        path = self.root / rel
        document = json.loads(path.read_text(encoding="utf-8"))
        mutate(document)
        path.write_text(json.dumps(document, indent=2), encoding="utf-8")

    def _mirror_court_existence(self):
        """Create empty placeholders mirroring which court files EXIST.

        The rods resolve a witness path against the sandbox root, so a sandbox
        that carried no test files would make every witness look missing -- and
        the negative arms would pass for the wrong reason. The mirror is about
        EXISTENCE, which is exactly what the rod checks: content is not read."""
        # EVERY path any real blocked-task classification names, whatever the
        # language: python courts under tools/readiness/tests, Kotlin courts under
        # android/, Swift courts under ios/, and metadata like ios/project.yml.
        # Mirroring only *.py would have made every native witness look absent, and
        # the positive control would then have failed for a reason that has nothing
        # to do with the rod.
        state, catalogue, _register, _m = load(ROOT)
        wanted: set[str] = set()
        for tid in blocked_records(state):
            entry = next(t for t in catalogue["tasks"] if t["id"] == tid)
            for rel in (entry.get("required_regression_paths") or []):
                wanted.add(str(rel))
            for case in (state["completed_tasks"][tid].get("case_classification") or []):
                if isinstance(case, dict) and case.get("implemented_by"):
                    wanted.add(str(case["implemented_by"]))
        for rel in wanted:
            if "/" not in rel or rel.endswith("/"):
                continue
            dest = self.root / rel
            if dest.exists():
                continue
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text("", encoding="utf-8")

    def close(self):
        self.tmp.cleanup()


class BlockedFrontierTest(unittest.TestCase):
    """W01-W04 -- the frontier and the honesty of the records."""

    def test_w01_every_task_carrieth_a_record_and_the_frontier_holdeth(self):
        state, catalogue, register, _m = load(ROOT)
        done = state["completed_tasks"]
        for task in catalogue["tasks"]:
            entry = done.get(task["id"])
            self.assertIsNotNone(entry, "no record for %s" % task["id"])
            self.assertIn(entry["status"], ("COMPLETE", "BLOCKED_EXTERNAL"),
                          "%s: %s" % (task["id"], entry["status"]))
        complete = sum(1 for e in done.values() if e["status"] == "COMPLETE")
        blocked = blocked_records(state)
        self.assertEqual(72, complete, "the completed count is a recorded fact")
        self.assertEqual(12, len(blocked), "the blocked count is a recorded fact")
        self.assertEqual(len(catalogue["tasks"]), complete + len(blocked))
        # the four FRONTIER tasks await ONLY their artifact
        for tid in ("T74", "T79", "T80", "T81"):
            self.assertTrue(blocked[tid]["internal_prerequisites_completed"], tid)
            self.assertTrue(blocked[tid]["own_external_requirement"], tid)
        # and no internally-runnable task remaineth
        self.assertEqual([], [t for t in pending_tasks(catalogue, state)
                              if not blocked[t]["blocker"]])

    def test_w02_an_unrecorded_pending_task_is_caught(self):
        fixture = _Fixture()
        try:
            fixture.edit("docs/production-readiness/BUILD_STATE.json",
                         lambda d: d["completed_tasks"].pop("T81"))
            problems = findings(fixture.root)
            self.assertTrue(any(p.startswith("unrecorded") for p in problems), problems)
        finally:
            fixture.close()
        self.assertEqual([], [p for p in findings(ROOT) if p.startswith("unrecorded")])

    def test_w03_a_blocked_task_may_not_claim_complete_nor_close_a_gate(self):
        fixture = _Fixture()
        try:
            fixture.edit("docs/production-readiness/BUILD_STATE.json",
                         lambda d: d["completed_tasks"]["T81"].update({"status": "COMPLETE"}))
            problems = findings(fixture.root)
            # a record may not be COMPLETE and name a blocker: the contradiction rule
            # catcheth it (the first form of this arm expected `unrecorded`, which
            # fireth only when the record is ABSENT)
            self.assertTrue(any(p.startswith("contradiction") for p in problems), problems)
        finally:
            fixture.close()
        # THE FIXTURE RULE: closure evidence on a blocker is CAUGHT
        fixture = _Fixture()
        try:
            fixture.edit("docs/production-readiness/EXTERNAL_BLOCKERS.json",
                         lambda d: d["blockers"][0].update({"closure_evidence": "a fixture"}))
            problems = findings(fixture.root)
            self.assertTrue(any(p.startswith("gate-closed-by-fixture") for p in problems),
                            problems)
        finally:
            fixture.close()
        # ... and a CLOSED status is caught too
        fixture = _Fixture()
        try:
            fixture.edit("docs/production-readiness/EXTERNAL_BLOCKERS.json",
                         lambda d: d["blockers"][0].update({"status": "CLOSED"}))
            problems = findings(fixture.root)
            self.assertTrue(any(p.startswith("gate-status-drift") for p in problems), problems)
        finally:
            fixture.close()
        # the real register carrieth no closure evidence at all
        for entry in blocked_records(load(ROOT)[0]).values():
            self.assertIsNone(entry["closure_evidence"], entry["blocker"])

    def test_w04_transitive_honesty(self):
        fixture = _Fixture()
        try:
            fixture.edit("docs/production-readiness/BUILD_STATE.json",
                         lambda d: d["completed_tasks"]["T62"].update(
                             {"internal_prerequisites_completed": True}))
            problems = findings(fixture.root)
            self.assertTrue(any(p.startswith("transitive-dishonesty") for p in problems),
                            problems)
        finally:
            fixture.close()
        # ... and an understatement is caught too
        fixture = _Fixture()
        try:
            fixture.edit("docs/production-readiness/BUILD_STATE.json",
                         lambda d: d["completed_tasks"]["T81"].update(
                             {"internal_prerequisites_completed": False}))
            problems = findings(fixture.root)
            self.assertTrue(any(p.startswith("transitive-understatement") for p in problems),
                            problems)
        finally:
            fixture.close()
        self.assertEqual([], findings(ROOT))


class UnauthoredCourtTest(unittest.TestCase):
    """W11-W12 -- the invariant the FIRST closure lacked.

    `BLOCKED_EXTERNAL` answereth "the final acceptance needs an input nobody here
    can produce". It doth NOT answer "and therefore nothing internally executable
    was owed". T78's narrow stage measured `tests=0/0` while the register called
    the task honestly blocked, and no rod caught it. These two witnesses prove the
    new rod striketh -- one for an UNJUSTIFIED absence, one for an empty gesture
    at a justification."""

    def test_w11_an_unjustified_absent_court_is_caught(self):
        fixture = _Fixture()
        try:
            def excuse_nothing(d):
                d["completed_tasks"]["T81"].pop("court_not_authored", None)
            fixture.edit("docs/production-readiness/BUILD_STATE.json", excuse_nothing)

            def declare_an_absent_court(d):
                # the rod reads DECLARED PATHS from the CATALOGUE, so the mutation
                # must land there; the mirror did not create this name.
                for task in d["tasks"]:
                    if task["id"] == "T81":
                        task["required_regression_paths"] = [
                            "tools/readiness/tests/test_w11_absent_court_fixture.py"]
            fixture.edit("docs/production-readiness/TASKS.json", declare_an_absent_court)
            problems = findings(fixture.root)
            self.assertTrue(any(p.startswith("unauthored-court") for p in problems),
                            problems)
        finally:
            fixture.close()
        # ... and the real repository carrieth no such finding
        self.assertEqual([], [p for p in findings(ROOT)
                              if p.startswith("unauthored-court")])

    def test_w12_a_gesture_at_a_justification_is_caught(self):
        fixture = _Fixture()
        try:
            def gesture(d):
                d["completed_tasks"]["T73"].update({"court_not_authored": "todo"})
            fixture.edit("docs/production-readiness/BUILD_STATE.json", gesture)

            def absent_court(d):
                for task in d["tasks"]:
                    if task["id"] == "T73":
                        task["required_regression_paths"] = [
                            "tools/readiness/tests/test_w12_absent_court_fixture.py"]
            fixture.edit("docs/production-readiness/TASKS.json", absent_court)
            problems = findings(fixture.root)
            self.assertTrue(any(p.startswith("unjustified-court") for p in problems),
                            problems)
        finally:
            fixture.close()
        # ... and every real justification is substantive
        state, catalogue, _register, _m = load(ROOT)
        for tid in blocked_records(state):
            entry = state["completed_tasks"][tid]
            excuse = str(entry.get("court_not_authored") or "")
            if excuse:
                self.assertGreaterEqual(len(excuse), 80,
                                        f"{tid}: a justification must NAME the reason")


class CaseClassificationTest(unittest.TestCase):
    """W17-W23 -- the case-level rods, and the rc3 escape hatch they close.

    A PROSE JUSTIFICATION MAY NOT EXCUSE A HOST-TESTABLE CASE. rc3 accepted any
    `court_not_authored` of sufficient LENGTH, and length is not proof: T64 and
    T65 sat behind one while their cards named cases needing no model at all.
    These witnesses drive the rods that closed it.

    EACH MUTATION IS ALSO CHECKED IN BOTH DIRECTIONS: the mutated sandbox must
    produce the finding, and the unmutated repository must stay clean. A rod that
    merely fires proves nothing about what it distinguishes."""

    #: a witness path that really exists, for the positive and fabricated arms
    REAL_WITNESS = "tools/readiness/tests/test_t78.py"

    def _mutate(self, fn):
        """Run `fn` against a sandboxed copy and return the findings."""
        fixture = _Fixture()
        try:
            fixture.edit("docs/production-readiness/BUILD_STATE.json", fn)
            return findings(fixture.root)
        finally:
            fixture.close()

    def test_w17_a_host_case_with_no_witness_is_caught(self):
        """Mutation A -- the card's own example: T64 names a host-testable case
        with nothing implementing it."""
        def strip_witness(d):
            d["completed_tasks"]["T64"]["case_classification"] = [
                {"case": "same dimension, different model", "classification":
                 "HOST_TESTABLE_PURE_LOGIC", "implemented_by": None}]
        problems = self._mutate(strip_witness)
        self.assertTrue(any(p.startswith("unimplemented-case") for p in problems),
                        problems)
        # ... and the real repository carrieth no such finding
        self.assertEqual([], [p for p in findings(ROOT)
                              if p.startswith("unimplemented-case")])

    def test_w18_prose_length_cannot_buy_an_exemption(self):
        """Mutation B -- THE rc3 ESCAPE HATCH SPECIFICALLY. A long justification
        beside a host-testable case with no witness must still be refused."""
        def excuse_with_prose(d):
            entry = d["completed_tasks"]["T65"]
            entry["court_not_authored"] = (
                "This justification is deliberately WELL OVER the eighty-character "
                "substance floor, and it is nonetheless insufficient: length is not "
                "proof, and a host-testable case without a witness is unimplemented "
                "however eloquently the absence is described.")
            entry["case_classification"] = [
                {"case": "deterministic test-double edge cases",
                 "classification": "HOST_TESTABLE_WITH_TEST_DOUBLE",
                 "implemented_by": None}]
        problems = self._mutate(excuse_with_prose)
        self.assertTrue(any(p.startswith("unimplemented-case") for p in problems),
                        "a long justification bought the exemption: %s" % problems)
        self.assertFalse(any(p.startswith("unjustified-court") for p in problems),
                         "the prose was long enough, so `unjustified-court` should not "
                         "be the rod that fired: %s" % problems)

    def test_w19_a_witness_that_does_not_exist_is_caught(self):
        """Mutation C -- the `implemented_by` NAMES a file, so a non-existent path
        must be refused; this reaches the branch Mutation A cannot."""
        def name_a_ghost(d):
            d["completed_tasks"]["T64"]["case_classification"] = [
                {"case": "same dimension, different model",
                 "classification": "HOST_TESTABLE_PURE_LOGIC",
                 "implemented_by": "tools/readiness/tests/test_does_not_exist.py"}]
        problems = self._mutate(name_a_ghost)
        self.assertTrue(any(p.startswith("unimplemented-case") for p in problems),
                        problems)

    def test_w20_an_external_case_may_not_claim_a_witness(self):
        """Mutation D -- a REQUIRES_*/DEVICE_ONLY case pointing at a real file is
        fabricated internal coverage."""
        def claim_internal(d):
            d["completed_tasks"]["T81"]["case_classification"] = [
                {"case": "real approved native/model binaries",
                 "classification": "REQUIRES_APPROVED_NATIVE_ARTIFACT",
                 "implemented_by": self.REAL_WITNESS}]
        problems = self._mutate(claim_internal)
        self.assertTrue(any(p.startswith("fabricated-case") for p in problems),
                        problems)

    def test_w21_an_unknown_classification_is_caught(self):
        def invent_a_class(d):
            d["completed_tasks"]["T64"]["case_classification"] = [
                {"case": "something", "classification": "PROBABLY_FINE",
                 "implemented_by": None}]
        problems = self._mutate(invent_a_class)
        self.assertTrue(any(p.startswith("malformed-cases") for p in problems),
                        problems)

    def test_w22_a_blocked_task_with_an_absent_court_and_no_cases_is_caught(self):
        """The omission itself is visible: without a classification a reader
        cannot tell host-testable from external, so the absence is unjudgeable."""
        def drop_cases(d):
            d["completed_tasks"]["T64"].pop("case_classification", None)
        problems = self._mutate(drop_cases)
        fixture = _Fixture()
        try:
            def absent_court(d):
                for task in d["tasks"]:
                    if task["id"] == "T64":
                        task["required_regression_paths"] = [
                            "tools/readiness/tests/test_w22_absent_court_fixture.py"]
            fixture.edit("docs/production-readiness/TASKS.json", absent_court)
            fixture.edit("docs/production-readiness/BUILD_STATE.json", drop_cases)
            problems = findings(fixture.root)
        finally:
            fixture.close()
        self.assertTrue(any(p.startswith("unclassified-cases") for p in problems),
                        problems)

    def test_w23_a_well_formed_host_case_keeps_the_tree_clean(self):
        """THE POSITIVE CONTROL: the rods must DISCRIMINATE, not merely fire."""
        def well_formed(d):
            d["completed_tasks"]["T64"]["case_classification"] = [
                {"case": "a host-testable case with a real witness",
                 "classification": "HOST_TESTABLE_PURE_LOGIC",
                 "implemented_by": self.REAL_WITNESS}]
        problems = self._mutate(well_formed)
        self.assertEqual([], [p for p in problems
                              if p.startswith(("unimplemented-case", "fabricated-case",
                                               "malformed-cases"))],
                         "a well-formed classification was refused: %s" % problems)


class BlockedDeclarationsTest(unittest.TestCase):
    """W05-W09 -- the gates, the mapping, the register's own fields."""

    def test_w05_the_readiness_flags_stay_false(self):
        flags = readiness_flags(ROOT)
        self.assertIs(False, flags.get("android_LINK_LAYER_READY"))
        self.assertIs(False, flags.get("ios_linkLayerReady"))
        fixture = _Fixture()
        try:
            fixture.edit("docs/production-readiness/ARCHITECTURE_INVARIANTS.json",
                         lambda d: d["readiness"].update({"android_LINK_LAYER_READY": True}))
            problems = findings(fixture.root)
            self.assertTrue(any(p.startswith("readiness-drift") for p in problems), problems)
        finally:
            fixture.close()

    def test_w06_the_five_external_entries_stay_open_or_blocked(self):
        state, catalogue, register, manifest = load(ROOT)
        externally_blocked = {"A-06-independent-noise-vectors", "production-corpus",
                              "model-native-stack", "device-interoperability",
                              "accessibility", "battery-thermal", "signing-store-approval"}
        for gate in manifest["gates"]:
            if gate["gate"] in externally_blocked:
                self.assertIn(gate["status"], ("OPEN", "BLOCKED"), gate["gate"])
        # the ONE pre-existing CLOSED gate is registered with an ancestor commit
        closed = {entry["gate"]: entry for entry in register["pre_existing_closed_gates"]}
        self.assertTrue(closed, "the register must record the pre-existing closure")
        for entry in closed.values():
            self.assertTrue(entry["ancestor_of_head"], entry["gate"])
        # ... and a CLOSED entry with NO register record is caught
        fixture = _Fixture()
        try:
            fixture.edit("docs/production-readiness/EXTERNAL_BLOCKERS.json",
                         lambda d: d.update({"pre_existing_closed_gates": []}))
            problems = findings(fixture.root)
            self.assertTrue(any(p.startswith("release-entry-drift") for p in problems),
                            problems)
        finally:
            fixture.close()
        # ... and so is a closed EXTERNALLY-BLOCKED entry
        fixture = _Fixture()
        try:
            def close_the_model_gate(d):
                for gate in d["gates"]:
                    if gate["gate"] == "model-native-stack":
                        gate["status"] = "CLOSED"
            fixture.edit("docs/production/RELEASE_GATES_STATUS.json", close_the_model_gate)
            problems = findings(fixture.root)
            self.assertTrue(any(p.startswith("release-entry-drift") for p in problems),
                            problems)
        finally:
            fixture.close()

    def test_w07_every_external_requirement_mapeth_to_a_register_id(self):
        _state, catalogue, register, _m = load(ROOT)
        ids = {b["id"] for b in register["blockers"]}
        self.assertEqual({"A06", "APPROVED_CONTENT", "NATIVE_MODELS", "HARDWARE", "SIGNING"}, ids)
        for task in catalogue["tasks"]:
            requirement = task.get("external_requirement")
            if not requirement:
                continue
            self.assertIn(requirement, CATALOGUE_TO_REGISTER, task["id"])
            self.assertIn(CATALOGUE_TO_REGISTER[requirement], ids, task["id"])

    def test_w08_the_register_dependent_tasks_cover_every_blocked_task(self):
        state, catalogue, register, _m = load(ROOT)
        blocked = blocked_records(state)
        listed = {tid for b in register["blockers"] for tid in b["dependent_tasks"]}
        self.assertEqual(set(blocked), listed,
                         "every blocked task must be named by its own blocker")
        # a register that forgetteth one is caught
        fixture = _Fixture()
        try:
            def drop_t81(d):
                for blocker in d["blockers"]:
                    blocker["dependent_tasks"] = [t for t in blocker["dependent_tasks"]
                                                  if t != "T81"]
            fixture.edit("docs/production-readiness/EXTERNAL_BLOCKERS.json", drop_t81)
            problems = findings(fixture.root)
            self.assertTrue(any(p.startswith("register-incomplete") for p in problems),
                            problems)
        finally:
            fixture.close()

    def test_w09_every_blocker_nameth_its_artifact_role_commands_and_trigger(self):
        _state, _catalogue, register, _m = load(ROOT)
        for blocker in register["blockers"]:
            self.assertTrue(blocker["required_artifact_schema"], blocker["id"])
            self.assertTrue(blocker["approved_source_or_human_role"], blocker["id"])
            self.assertTrue(blocker["verification_commands"], blocker["id"])
            self.assertTrue(blocker["recheck_trigger"], blocker["id"])
            self.assertTrue(blocker["reason"], blocker["id"])
            # time passing is NOT artifact availability: the trigger must name an
            # EVENT (a receipt, an approval, an access, a drop) and never a date
            trigger = blocker["recheck_trigger"].lower()
            self.assertTrue(any(word in trigger for word in
                                ("receipt", "access", "approved", "provisioned", "received",
                                 "staged", "arrive")), "%s: %r" % (blocker["id"], trigger))
            for forbidden in ("day", "week", "month", "quarter", "soon", "later", "20"):
                self.assertNotIn(forbidden, trigger,
                                 "%s: a trigger may not be a date (%r)" % (blocker["id"], trigger))


class BlockedRepositoryTest(unittest.TestCase):
    """W10 -- the real repository, and the register's own counts."""

    def test_w10_the_real_repository_passes(self):
        problems = findings(ROOT)
        self.assertEqual([], problems, problems)
        text = report(ROOT)
        self.assertIn("VERDICT: PASS", text)
        self.assertIn("72 COMPLETE", text)
        self.assertIn("12 BLOCKED_EXTERNAL", text)
        # the register's own counts agree with the state
        state, catalogue, register, _m = load(ROOT)
        done = state["completed_tasks"]
        self.assertEqual(register["completed_task_count"],
                         sum(1 for e in done.values() if e["status"] == "COMPLETE"))
        self.assertEqual(register["blocked_external_count"],
                         sum(1 for e in done.values() if e["status"] == "BLOCKED_EXTERNAL"))
        self.assertEqual(len(catalogue["tasks"]),
                         register["completed_task_count"] + register["blocked_external_count"])
        # and the frontier note carrieth the same numbers in words
        note = register["frontier_note"]
        self.assertIn("SEVENTY-TWO", note)
        self.assertIn("TWELVE", note)


if __name__ == "__main__":
    unittest.main(verbosity=2)
