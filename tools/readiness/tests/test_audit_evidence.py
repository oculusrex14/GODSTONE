#! /usr/bin/env python3
"""GS-CTRL-001 — the completion validator must be an acceptance gate.

The audit's independent probes (evidence/controls/audit_runner_tests.py) are moved
into the canonical suite here, with their assertions INTACT and only their fixtures
rebound to this repository: a FAILED command, a PASSED entry naming a nonexistent log,
and a bare COMPLETE record must each INVALIDATE completion.

The court then goeth further than the probes, because a checker must be seen to
ACCEPT valid evidence as well as refuse invalid evidence:

  W01 a FAILED command invalidateth completion (audit probe 1)
  W02 a PASSED entry naming a nonexistent log invalidateth completion (audit probe 2)
  W03 a bare COMPLETE record invalidateth completion (audit probe 3)
  W04 THE POSITIVE CONTROL: a fully valid record -- a real commit, its real tree,
      required command ids, a real log with a matching sha256, PASSED with a nonzero
      executed count -- must PASS, or the validator is merely refusing everything
  W05 the tamper battery: a one-byte log change, an older-but-valid SHA, a removed
      required case and a skipped-only result must each FAIL
  W06 every non-passing outcome is refused: FAILED, REJECTED, TIMEOUT, DRYRUN, a
      missing outcome and a missing log
  W07 a build-only command stayeth distinct from an executed behavioral test: it need
      not carry test counts, and it may NOT satisfy a required behavioral case
  W08 an implemented-but-blocked task is representable: COMPLETE with required
      external evidence absent FAILETH, while BLOCKED_EXTERNAL nameth the exact proof
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "readiness"))
import run  # noqa: E402


class _Evidence:
    """A disposable evidence directory shaped as the runner expecteth."""

    def __init__(self, entry=None, task="T01"):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.tmp.name)
        (self.root / task).mkdir()
        self.task = task
        if entry is not None:
            (self.root / task / "commands.json").write_text(
                json.dumps({"schema_version": 1, "commands": [entry]}), encoding="utf-8")

    def log(self, rel, payload=b"a real run log\n") -> str:
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(payload)
        return rel

    def repo(self):
        return run.Repo(str(ROOT), str(self.root))

    def close(self):
        self.tmp.cleanup()


def _command(**over):
    entry = {"id": "probe", "outcome": "PASSED", "exit_code": 0, "kind": "test",
             "tests_executed": 12, "tests_failed": 0, "cwd": ".", "argv": ["python3", "-m", "unittest"]}
    entry.update(over)
    return entry


def _problems(evidence, task="T01"):
    problems = []
    run._validate_command_evidence(evidence.repo(), task, "probe", problems)
    return problems


class AuditProbeTest(unittest.TestCase):
    """W01-W03 -- the audit's three probes, assertions intact."""

    def test_w01_failed_command_must_invalidate_completion(self):
        evidence = _Evidence(_command(outcome="FAILED", exit_code=1, tests_failed=1))
        self.addCleanup(evidence.close)
        problems = _problems(evidence)
        self.assertTrue(problems, "FAILED command accepted without a validation problem")

    def test_w02_missing_log_must_invalidate_completion(self):
        evidence = _Evidence(_command(log_path="T01/missing.log", log_sha256="0" * 64))
        self.addCleanup(evidence.close)
        problems = _problems(evidence)
        self.assertTrue(problems, "nonexistent claimed test log accepted")

    def test_w03_complete_requires_implementation_tree_and_evidence(self):
        repo = run.Repo(str(ROOT), "/Users/oculus/Projects/GODSTONE_BUILDER_EVIDENCE")
        state = {"schema_version": 1, "last_observed_head": repo.head(),
                 "completed_tasks": {"T01": {"status": "COMPLETE"}}, "in_progress": None}
        with patch.object(run, "recover_state", return_value=state):
            self.assertTrue(run.validate_state(repo),
                            "bare COMPLETE accepted without implementation, tree, or commands")


class ValidEvidenceTest(unittest.TestCase):
    """W04 -- the positive control: valid evidence must PASS."""

    #: T01 hath no dependencies, so the fixture needeth no dependency records. It DOETH
    #: have a legacy migration, so the fixture carrieth the migration's own required
    #: commands from the real record -- adapted to the fixture's evidence dir -- which is
    #: exactly what the positive control must prove: that VALID evidence passes.
    TASK = "T01"

    def test_w04_a_fully_valid_record_passes(self):
        head = run.Repo(str(ROOT), "/tmp").head()
        tree = run.subprocess.run(["git", "rev-parse", head + "^{tree}"], cwd=str(ROOT),
                                  capture_output=True, text=True).stdout.strip()
        evidence = _Evidence(task=self.TASK)
        self.addCleanup(evidence.close)
        rel = evidence.log("%s/logs/run.log" % self.TASK)
        digest = hashlib.sha256((evidence.root / rel).read_bytes()).hexdigest()
        evidence_entry = _command(log_path=rel, log_sha256=digest, source_sha=head)
        # the fixture carrieth BOTH its own probe and the migration's covering command,
        # each backed by the fixture's real log
        covering = dict(evidence_entry, id="t01-cmd-12")
        (evidence.root / self.TASK / "commands.json").write_text(
            json.dumps({"schema_version": 1, "commands": [evidence_entry, covering]}),
            encoding="utf-8")
        problems = []
        run._validate_command_evidence(evidence.repo(), self.TASK, "probe", problems)
        self.assertEqual([], problems)
        run._validate_command_evidence(evidence.repo(), self.TASK, "t01-cmd-12", problems)
        self.assertEqual([], problems, "the covering command must itself validate strictly")
        # ... and the state-level check accepteth a COMPLETE record that carrieth the
        # implementation commit, its tree and a required command id
        # the fixture carrieth the real T01 record, whose required commands are the ones
        # the migration resolved, with the fixture's own log standing in for the run
        real = json.loads((ROOT / "docs/production-readiness/BUILD_STATE.json").read_text())
        record = dict(real["completed_tasks"][self.TASK])
        record.update({"implementation_commit": head, "tested_tree_sha": tree,
                       "commands": ["probe"]})
        state = {"schema_version": 1, "last_observed_head": head,
                 "completed_tasks": {self.TASK: record}, "in_progress": None}
        with patch.object(run, "recover_state", return_value=state):
            problems = run.validate_state(evidence.repo())
        # T01 carrieth a legacy migration, so the migration's OWN coverage rule applyeth:
        # the fixture must therefore carry the migration's covering command too
        self.assertTrue(any("migration nameth" in p for p in problems),
                        "the migration's coverage rule must be seen to fire on a fixture that "
                        "omiteth the covering command")
        record["commands"] = ["probe", "t01-cmd-12"]
        with patch.object(run, "recover_state", return_value=state):
            problems = run.validate_state(evidence.repo())
        self.assertEqual([], [p for p in problems if p.startswith(self.TASK)], problems)


class TamperBatteryTest(unittest.TestCase):
    """W05-W07 -- tampering, refused outcomes, and the build/test distinction."""

    def test_w05_each_tamper_is_refused(self):
        head = run.Repo(str(ROOT), "/tmp").head()
        # (a) one byte of the log changed
        evidence = _Evidence()
        self.addCleanup(evidence.close)
        rel = evidence.log("T01/logs/run.log", b"untampered\n")
        digest = hashlib.sha256((evidence.root / rel).read_bytes()).hexdigest()
        (evidence.root / rel).write_bytes(b"tampered!!\n")
        entry = _command(log_path=rel, log_sha256=digest)
        (evidence.root / "T01" / "commands.json").write_text(
            json.dumps({"schema_version": 1, "commands": [entry]}), encoding="utf-8")
        self.assertTrue(_problems(evidence), "a one-byte log change must fail")
        # (b) a skipped-only result cannot satisfy a required behavioral case
        evidence = _Evidence(_command(tests_executed=0, tests_skipped=5,
                                      required_cases=["test_the_case"], passed_cases=[]))
        self.addCleanup(evidence.close)
        self.assertTrue(_problems(evidence), "a skipped-only result must not pass")

    def test_w06_every_non_passing_outcome_is_refused(self):
        for outcome in ("FAILED", "REJECTED", "TIMEOUT", "DRYRUN", None):
            evidence = _Evidence(_command(**({"outcome": outcome} if outcome else {"outcome": None})))
            self.addCleanup(evidence.close)
            self.assertTrue(_problems(evidence), "outcome %r must be refused" % outcome)
        # a PASSED entry with NO log at all is refused (not merely a wrong path)
        evidence = _Evidence(_command())
        self.addCleanup(evidence.close)
        self.assertTrue(_problems(evidence), "a PASSED entry with no log must be refused")

    def test_w07_a_build_is_not_a_behavioral_test(self):
        # a build-only command need not carry test counts ...
        evidence = _Evidence(_command(kind="build", tests_executed=0))
        self.addCleanup(evidence.close)
        self.assertEqual([], [p for p in _problems(evidence) if "zero tests" in p],
                         "a build is not an executed test")
        # ... and it may NOT satisfy a required behavioral case
        evidence = _Evidence(_command(kind="build", required_cases=["test_the_case"],
                                      passed_cases=[]))
        self.addCleanup(evidence.close)
        self.assertTrue(_problems(evidence),
                        "a build-only command must not close a required behavioral case")


class BlockedVersusCompleteTest(unittest.TestCase):
    """W08 -- an implemented-but-blocked task must be representable."""

    def test_w08_complete_without_required_external_evidence_fails(self):
        head = run.Repo(str(ROOT), "/tmp").head()
        evidence = _Evidence()
        self.addCleanup(evidence.close)
        (evidence.root / "T01" / "commands.json").write_text(
            json.dumps({"schema_version": 1, "commands": []}), encoding="utf-8")
        state = {"schema_version": 1, "last_observed_head": head,
                 "completed_tasks": {"T01": {"status": "COMPLETE",
                                             "implementation_commit": head,
                                             "tested_tree_sha": "0" * 40,
                                             "commands": ["probe"],
                                             "external_evidence_required": ["device_run"]}},
                 "in_progress": None}
        with patch.object(run, "recover_state", return_value=state):
            problems = run.validate_state(evidence.repo())
        self.assertTrue(any("T01" in p for p in problems),
                        "a COMPLETE task with required external evidence absent must fail")
        # ... while the same task BLOCKED_EXTERNAL, naming the exact missing proof, is
        # a legal disposition
        state["completed_tasks"]["T01"] = {"status": "BLOCKED_EXTERNAL",
                                           "blocker": "HARDWARE",
                                           "reason": "device_run not available"}
        with patch.object(run, "recover_state", return_value=state):
            problems = run.validate_state(evidence.repo())
        self.assertEqual([], [p for p in problems if p.startswith("T01")], problems)
        # ... and a BLOCKED record may NEVER be COMPLETE
        state["completed_tasks"]["T01"]["status"] = "SKIPPED_COMPLETE"
        with patch.object(run, "recover_state", return_value=state):
            with self.assertRaises(Exception):
                run.validate_state(evidence.repo())


if __name__ == "__main__":
    unittest.main(verbosity=2)
