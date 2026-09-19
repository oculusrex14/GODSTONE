#! /usr/bin/env python3
"""T78 readiness court (python isle): the candidate evaluator, and the three
levels it must never conflate.

The card's law, one named witness each:

  W01  the manifest is verified against EXACT BYTES: a missing evidence file is
       refused by name, and a file whose bytes changed is refused as a mismatch
  W02  a manifest for ANOTHER PROFILE is refused by name
  W03  the evidence is bound to an EXACT SHA: a substituted old SHA, a SHA that
       is not a commit, a non-hex SHA, a tree SHA that belongs to another commit,
       and evidence from a commit that is not the head are EACH refused
  W04  a REQUIRED COURT THAT EXECUTED NOTHING is refused: `executed: 0` is not
       evidence, and this is the card's own `0/0 must not qualify` rule
  W05  a required court that RECORDED A FAILURE is refused
  W06  a PHASE GATE that is not PASS is refused
  W07  a DIRTY TRACKED TREE is refused (untracked evidence directories are not
       dirt -- they are this repository's design)
  W08  the outer manifest law still holds: an unknown schema version, a duplicate
       key and malformed JSON are each refused by name
  W09  THE THREE LEVELS STAY APART: a candidate whose evidence is sound but whose
       external gates are open readeth INTERNAL_VERIFICATION = PASS,
       EXTERNAL_GATES = OPEN, PRODUCTION_RELEASE = BLOCKED -- and this is NOT
       reported as a production success
  W10  the semantic negative the card names -- "substitute an old SHA: candidate
       evaluator must fail" -- is exercised THROUGH THE REAL EVALUATOR
  W11  the evaluator closes nothing: no readiness flag is flipped, and an open
       external gate is recorded as OPEN rather than raised as a fault

Every witness drives `tools/readiness/run.py`'s own `evaluate_candidate`. The
fixtures are LABELLED rehearsals: a manifest built here is a fixture-shaped
manifest, it is not an approval, and it closes no gate.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

import run as run_module  # noqa: E402

HEAD = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                      capture_output=True, text=True).stdout.strip()
TREE = subprocess.run(["git", "rev-parse", "HEAD^{tree}"], cwd=ROOT,
                      capture_output=True, text=True).stdout.strip()


def sha256_file(path):
    import hashlib
    digest = hashlib.sha256()
    digest.update(Path(path).read_bytes())
    return digest.hexdigest()


class _World:
    """A fixture evidence root plus a manifest written into it.

    The evaluator resolves evidence paths against `repo.evidence`, so the world
    carries its own evidence directory and the fixture manifest is built to
    match it."""

    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        self.repo = run_module.Repo(str(ROOT), str(self.evidence))

    def put(self, name, data=b"T78-FIXTURE EVIDENCE"):
        path = self.evidence / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return {"path": name, "sha256": sha256_file(path)}

    def manifest(self, **overrides):
        document = {
            "schema_version": run_module.SCHEMA_VERSION,
            "profile": "archive",
            "candidate_sha": HEAD,
            "candidate_tree_sha": TREE,
        }
        document.update(overrides)
        return document

    def evaluate(self, document, profile="archive"):
        path = self.root / "manifest.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return run_module.evaluate_candidate(self.repo, profile, str(path),
                                             head=HEAD, dirty=False)

    def close(self):
        self.tmp.cleanup()


class CandidateEvaluatorCourt(unittest.TestCase):
    """W01-W08 -- the evaluator's own refusals."""

    maxDiff = None

    def test_w01_evidence_is_verified_against_exact_bytes(self):
        world = _World()
        try:
            record = world.put("payload.bin")
            good = world.manifest(files=[record])
            self.assertEqual([], world.evaluate(good)["problems"])

            # a MISSING file is refused by name
            missing = world.manifest(files=[{"path": "absent.bin", "sha256": "0" * 64}])
            caught = world.evaluate(missing)["problems"]
            self.assertTrue(any("missing evidence file" in c for c in caught), caught)

            # a file whose BYTES CHANGED is refused as a mismatch
            stale = world.manifest(files=[{**record, "sha256": "0" * 64}])
            caught = world.evaluate(stale)["problems"]
            self.assertTrue(any("hash mismatch" in c for c in caught), caught)
        finally:
            world.close()

    def test_w02_a_manifest_for_another_profile_is_refused(self):
        world = _World()
        try:
            caught = world.evaluate(world.manifest(profile="lab-mesh"))["problems"]
            self.assertTrue(any("not 'archive'" in c for c in caught), caught)
        finally:
            world.close()

    def test_w03_evidence_must_be_bound_to_an_exact_sha(self):
        world = _World()
        try:
            # a substituted OLD sha (a real commit that is not the head)
            old = subprocess.run(["git", "rev-parse", "HEAD~1"], cwd=ROOT,
                                 capture_output=True, text=True).stdout.strip()
            caught = world.evaluate(world.manifest(candidate_sha=old))["problems"]
            self.assertTrue(any("tree of" in c or "not the head" in c for c in caught),
                            caught)

            # a sha that is not a commit at all
            caught = world.evaluate(world.manifest(candidate_sha="a" * 40))["problems"]
            self.assertTrue(any("not a commit object" in c for c in caught), caught)

            # a non-hex sha
            caught = world.evaluate(world.manifest(candidate_sha="z" * 40))["problems"]
            self.assertTrue(any("lower-case hex" in c for c in caught), caught)

            # a tree sha belonging to another commit
            oldtree = subprocess.run(["git", "rev-parse", "HEAD~1^{tree}"], cwd=ROOT,
                                     capture_output=True, text=True).stdout.strip()
            caught = world.evaluate(world.manifest(candidate_tree_sha=oldtree))["problems"]
            self.assertTrue(any("is not the tree of" in c for c in caught), caught)
        finally:
            world.close()

    def test_w04_a_required_court_that_executed_nothing_is_refused(self):
        """The card's own rule: `0/0` must not silently qualify."""
        world = _World()
        try:
            zero = world.manifest(required_courts=[
                {"name": "T78-narrow", "executed": 0, "failed": 0}])
            caught = world.evaluate(zero)["problems"]
            self.assertTrue(any("executed 0 tests" in c for c in caught), caught)

            # ... and a court with NO count at all is refused too
            absent = world.manifest(required_courts=[{"name": "T78-narrow"}])
            caught = world.evaluate(absent)["problems"]
            self.assertTrue(any("no executed count" in c for c in caught), caught)

            # ... and a positive count passes
            positive = world.manifest(required_courts=[
                {"name": "T78-narrow", "executed": 13, "failed": 0}])
            self.assertEqual([], world.evaluate(positive)["problems"])
        finally:
            world.close()

    def test_w05_a_required_court_that_failed_is_refused(self):
        world = _World()
        try:
            caught = world.evaluate(world.manifest(required_courts=[
                {"name": "T78-narrow", "executed": 13, "failed": 2}]))["problems"]
            self.assertTrue(any("recorded 2 failure" in c for c in caught), caught)
        finally:
            world.close()

    def test_w06_a_phase_gate_that_is_not_pass_is_refused(self):
        world = _World()
        try:
            caught = world.evaluate(world.manifest(phase_gates=[
                {"id": "P9", "status": "OPEN"}]))["problems"]
            self.assertTrue(any("phase gate 'P9' statuseth 'OPEN'" in c for c in caught),
                            caught)
            ok = world.manifest(phase_gates=[{"id": "P9", "status": "PASS"}])
            self.assertEqual([], world.evaluate(ok)["problems"])
        finally:
            world.close()

    def test_w07_a_dirty_tracked_tree_is_refused(self):
        world = _World()
        try:
            result = run_module.evaluate_candidate(
                world.repo, "archive", str(self._write(world, world.manifest())), head=HEAD,
                dirty=True)
            self.assertTrue(any("dirty" in p for p in result["problems"]),
                            result["problems"])
        finally:
            world.close()
        # ... and untracked files are NOT dirt: this repository carries evidence
        # directories that are untracked BY DESIGN, and `is_dirty` must read the
        # TRACKED tree only. Proven directly, so the witness does not depend on
        # whether the tree happens to be clean at the moment it runs.
        probe = run_module.Repo(str(ROOT), str(ROOT))
        tracked = subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=no"],
            cwd=ROOT, capture_output=True, text=True).stdout.strip()
        # THE RULE, asserted against git itself rather than against a hoped-for
        # state: is_dirty() must report exactly what the TRACKED view reports. A
        # tree mid-edit is dirty and that is correct; what must never happen is
        # is_dirty() reading an UNTRACKED evidence directory as dirt.
        self.assertEqual(probe.is_dirty(), bool(tracked),
                         "is_dirty() must agree with the tracked-only porcelain view")
        all_files = subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=all"],
            cwd=ROOT, capture_output=True, text=True).stdout
        self.assertTrue(all_files.count("\n") >= tracked.count("\n"),
                        "the untracked view must include at least everything the "
                        "tracked view does")
        # ... and the evidence directories really are untracked by design
        self.assertIn("?? ", all_files,
                      "this repository is expected to carry untracked evidence roots")

    @staticmethod
    def _write(world, document):
        path = world.root / "manifest.json"
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def test_w08_the_outer_manifest_law_still_holds(self):
        world = _World()
        try:
            # an unknown FUTURE schema version
            future = world.manifest(schema_version=run_module.SCHEMA_VERSION + 1)
            path = self._write(world, future)
            with self.assertRaises(run_module.StateInvalid):
                run_module.load_json_strict(path)
            # a missing schema version
            path.write_text(json.dumps({"profile": "archive"}), encoding="utf-8")
            with self.assertRaises(run_module.StateInvalid):
                run_module.load_json_strict(path)
            # a DUPLICATE key
            path.write_text('{"schema_version": 1, "schema_version": 1}', encoding="utf-8")
            with self.assertRaises(run_module.RunnerError):
                run_module.load_json_strict(path)
            # malformed JSON
            path.write_text("{not json", encoding="utf-8")
            with self.assertRaises(run_module.StateInvalid):
                run_module.load_json_strict(path)
        finally:
            world.close()


class TheThreeLevelsStayApart(unittest.TestCase):
    """W09-W11 -- the distinction the evaluator exists to draw."""

    def test_w09_internal_pass_does_not_imply_production_release(self):
        world = _World()
        try:
            result = world.evaluate(world.manifest(required_courts=[
                {"name": "T78-narrow", "executed": 13, "failed": 0}]))
            self.assertEqual("PASS", result["internal_verification"], result["problems"])
            self.assertEqual("BLOCKED", result["production_release"],
                             "open external gates must read BLOCKED, never 'ready'")
            self.assertTrue(result["external_gates_open"],
                            "the external gates are open today and must be reported so")
            self.assertIn("EXTERNAL_GATES = OPEN", result["verdict_line"])
            self.assertIn("PRODUCTION_RELEASE = BLOCKED", result["verdict_line"])
        finally:
            world.close()

    def test_w10_a_substituted_old_sha_makes_the_evaluator_fail(self):
        """The card's semantic negative, measured through the real evaluator."""
        world = _World()
        try:
            old = subprocess.run(["git", "rev-parse", "HEAD~1"], cwd=ROOT,
                                 capture_output=True, text=True).stdout.strip()
            result = world.evaluate(world.manifest(candidate_sha=old))
            self.assertNotEqual([], result["problems"],
                                "a substituted old SHA was ACCEPTED")
            self.assertEqual("FAIL", result["internal_verification"])
        finally:
            world.close()

    def test_w11_the_evaluator_closes_nothing(self):
        invariants = json.loads(
            (ROOT / "docs/production-readiness/ARCHITECTURE_INVARIANTS.json")
            .read_text(encoding="utf-8"))
        readiness = invariants.get("readiness", {})
        self.assertIs(False, readiness.get("android_LINK_LAYER_READY"))
        self.assertIs(False, readiness.get("ios_linkLayerReady"))
        # ... and the real repository's gates read OPEN, reported not raised
        world = _World()
        try:
            result = world.evaluate(world.manifest())
            states = result["external_gates"]
            self.assertTrue(states, "the gate register must be readable")
            for gate in ("A06", "APPROVED_CONTENT", "NATIVE_MODELS", "HARDWARE", "SIGNING"):
                self.assertIn(gate, states)
                self.assertNotEqual("CLOSED", states[gate],
                                    f"{gate} may not be closed by the evaluator")
        finally:
            world.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
