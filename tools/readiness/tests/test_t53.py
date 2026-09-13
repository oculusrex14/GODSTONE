#! /usr/bin/env python3
"""T53 readiness court: the gate status must be exact-SHA, complete, profile-aware.

The card's law, one witness each where the rule speaketh:

  W01 the register is versioned; future and malformed versions refused; the
      legacy (v1) path kept byte-identical for the sealed courts' fixtures
  W02 every required gate, none may be forgotten
  W03 duplicate gates stricken
  W04 an unknown gate refused by name (the v2 register)
  W05 malformed JSON refused at the door; a missing file likewise
  W06 stale evidence: an unresolvable commit and a remote non-ancestor both
      refused (the resolver injected at the real boundary, faked here)
  W07 the profiles keep the LIGHT no-embed gate and the embedded MEDIUM corpus
      apart: wrong-flavoured evidence refused field by field
  W08 the profiled wiring (--release, the binary-inspection step) never cut away
  W09 a skipped job (if: false) or a missing job may not close a gate
  W10 UNAVAILABLE never mapped to PASS: zero-run results, failed results, and a
      candidate closure without test results all refused
  W11 the real register, judged by the real resolvers, standeth clean
  W12 the evidence field formats are strict (run id, executor, checksums, bytes)
  W13 the two selftests ring true (12 and 15 controls refused by name)
  W14 the consistency keeper sleepeth not (the whole-house harmony witness)
  W15 the workflow's real wiring sworn twice (--release present, the inspection
      step present, every named job existeth)
  W16 an OPEN or BLOCKED gate shall not carry an evidence block
  W17 the legacy path is byte-identical where the sealed courts dwell
  W18 the classification is recomputed, never trusted from the document
  W19 the byte counts are sworn to the reason's prose (the transcription proved)

All judgments run in-process upon injected fakes save where a witness named
sayeth the real history (W11, W15, W19); the fakes are deterministic. No
external gate is closed by any witness; readiness stays false; the eight
gates keep their recorded statuses.
"""
from __future__ import annotations

import copy
import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))


def _gates_module():
    spec = importlib.util.spec_from_file_location(
        "dsh_t53_gates", str(REPO / "ci" / "check_release_gates_status.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


MOD = _gates_module()
STATUS_PATH = REPO / "docs" / "production" / "RELEASE_GATES_STATUS.json"
WORKFLOW_PATH = REPO / ".github" / "workflows" / "release-gates.yml"

WF_CORRECT = """
jobs:
  android-archive-only-release:
    runs-on: ubuntu-latest
    if: inputs.gate == 'open'
    steps:
      - run: python scripts/inspect_android_artifacts.py android/app/build artifacts/android
  production-corpus:
    runs-on: ubuntu-latest
    steps:
      - run: python -m content.ingest.build_archive --tier MEDIUM --out dist/archive_medium.db --release
"""


def base2():
    return {"schema_version": 2, "gates": [
        {"gate": name, "status": "OPEN", "evidence_commit": None,
         "ci_job": "not-runnable-in-ci" if kind == "not-runnable-in-ci"
                   else f"release-gates.yml / {name}"}
        for name, kind in MOD.REQUIRED.items()]}


def gate_of(data, name):
    return next(g for g in data["gates"] if g["gate"] == name)


def close_android(data, commit="f" * 40, **evil):
    evi = {"run_id": "31384944062", "executor": "release-gates.yml / android-archive-only-release",
           "apk_sha256": "a" * 64, "aab_sha256": "b" * 64, "apk_bytes": 10, "aab_bytes": 20}
    evi.update(evil.pop("evidence", {}))
    gate_of(data, "android-archive-only-release").update(
        {"status": "CLOSED", "evidence_commit": commit, "evidence": evi, **evil})
    return data


def close_corpus(data, commit="f" * 40, **evil):
    evi = {"run_id": "42", "executor": "release-gates.yml / production-corpus",
           "corpus_sha256": "c" * 64, "test_results": {"executed": 5, "failed": 0}}
    evi.update(evil.pop("evidence", {}))
    gate_of(data, "production-corpus").update(
        {"status": "CLOSED", "evidence_commit": commit, "evidence": evi, **evil})
    return data


def check(data, workflow=None):
    """Judge v2 with the deterministic fakes injected at every resolver boundary."""
    return MOD.validate_status(data, resolve_evidence=MOD._fake_resolve,
                              is_ancestor=MOD._fake_ancestor, candidate=MOD._fake_candidate,
                              drift=MOD._fake_drift, workflow_text=workflow)


class T53GateStatusCourt(unittest.TestCase):
    maxDiff = None

    # -- W01 ------------------------------------------------------------------
    def testTheFileVersionsAreAcceptedOrRefused(self):
        clean = base2()
        self.assertEqual(check(clean), [])
        future = base2(); future["schema_version"] = 3
        self.assertTrue(any("refused" in e for e in check(future)), check(future))
        malformed = base2(); malformed["schema_version"] = "2"
        self.assertTrue(any("refused" in e for e in check(malformed)))
        boolean = base2(); boolean["schema_version"] = True
        self.assertTrue(any("refused" in e for e in check(boolean)))
        legacy = base2(); legacy.pop("schema_version")
        legacy["gates"].append({"gate": "rogue-gate", "status": "OPEN",
                                "ci_job": "not-runnable-in-ci"})
        self.assertEqual(check(legacy), [], "the v1 path knoweth not the unknown-gate law")

    # -- W02 ------------------------------------------------------------------
    def testEveryRequiredGateIsNeverForgotten(self):
        for name in sorted(MOD.REQUIRED):
            with self.subTest(gate=name):
                data = base2()
                data["gates"] = [g for g in data["gates"] if g["gate"] != name]
                errors = check(data)
                self.assertTrue(any("missing required gate" in e and name in e for e in errors),
                                f"{name}: {errors}")

    # -- W03 ------------------------------------------------------------------
    def testDuplicateGatesAreStricken(self):
        data = base2()
        data["gates"].append(copy.deepcopy(gate_of(data, "production-corpus")))
        errors = check(data)
        self.assertTrue(any("duplicate gate: production-corpus" in e for e in errors), errors)

    # -- W04 ------------------------------------------------------------------
    def testAnUnknownGateIsRefusedByName(self):
        data = base2()
        data["gates"].append({"gate": "rogue-gate", "status": "OPEN",
                              "ci_job": "not-runnable-in-ci"})
        errors = check(data)
        self.assertTrue(any("unknown gate" in e and "rogue-gate" in e for e in errors), errors)

    # -- W05 ------------------------------------------------------------------
    def testMalformedJSONIsRefusedAtTheDoor(self):
        self.assertEqual(MOD.validate_status({"gates": {}}),
                         ["status must be an object containing a gates array"])
        with tempfile.TemporaryDirectory() as td:
            junk = Path(td) / "gates.json"
            junk.write_text("{not even json,,,", encoding="utf-8")
            proc = subprocess.run([sys.executable, "-B", "ci/check_release_gates_status.py",
                                  "--status", str(junk)], capture_output=True, text=True,
                                 cwd=str(REPO))
            self.assertEqual(proc.returncode, 1, msg=proc.stdout + proc.stderr)
            self.assertIn("cannot read status", proc.stdout)
            proc = subprocess.run([sys.executable, "-B", "ci/check_release_gates_status.py",
                                  "--status", str(Path(td) / "nothere.json")],
                                 capture_output=True, text=True, cwd=str(REPO))
            self.assertEqual(proc.returncode, 1)
            self.assertIn("cannot read status", proc.stdout)

    # -- W06 ------------------------------------------------------------------
    def testStaleEvidenceDothNotResolve(self):
        data = close_android(base2(), commit="9" * 40)
        errors = check(data)
        self.assertTrue(any("stale evidence" in e and "doth not resolve" in e for e in errors),
                        errors)
        data = close_android(base2(), commit="e" * 40)   # the fake resolve knoweth a tree
        errors = check(data)
        self.assertTrue(any("nor as an ancestor" in e for e in errors), errors)

    # -- W07 ------------------------------------------------------------------
    def testTheProfilesKeepLightAndCorpusApart(self):
        data = close_android(base2(), evidence={"corpus_sha256": "d" * 64})
        # the android gate now sweareth corpus evidence: the four LIGHT fields are
        # wanted and the foreign corpus field is not in the register of required
        del gate_of(data, "android-archive-only-release")["evidence"]["apk_sha256"]
        del gate_of(data, "android-archive-only-release")["evidence"]["aab_sha256"]
        del gate_of(data, "android-archive-only-release")["evidence"]["apk_bytes"]
        del gate_of(data, "android-archive-only-release")["evidence"]["aab_bytes"]
        errors = check(data)
        for field in ("apk_sha256", "aab_sha256", "apk_bytes", "aab_bytes"):
            self.assertTrue(any(f"evidence wanteth {field}" in e for e in errors),
                            f"{field}: {errors}")
        data = close_corpus(base2())
        del gate_of(data, "production-corpus")["evidence"]["corpus_sha256"]
        gate_of(data, "production-corpus")["evidence"].update(
            {"apk_sha256": "a" * 64, "aab_sha256": "b" * 64,
             "apk_bytes": 10, "aab_bytes": 20})
        errors = check(data)
        self.assertTrue(any("evidence wanteth corpus_sha256" in e for e in errors), errors)
        # the table itself, sworn
        light = MOD.PROFILE_REQUIREMENTS["android-archive-only-release"]
        corpus = MOD.PROFILE_REQUIREMENTS["production-corpus"]
        self.assertIn("inspect_android_artifacts.py", light["workflow_must_hold"])
        self.assertIn("--release", corpus["workflow_must_hold"])
        self.assertTrue(any(p.startswith("content/ingest") for p in corpus["scope_paths"]))
        self.assertTrue(any(p.startswith("android/app") for p in light["scope_paths"]))
        self.assertNotIn("android/app", tuple(corpus["scope_paths"]))

    # -- W08 ------------------------------------------------------------------
    def testTheProfiledWiringIsNeverCutAway(self):
        data = close_corpus(base2())
        errors = check(data, workflow=WF_CORRECT.replace(" --release", ""))
        self.assertTrue(any("wanteth" in e and "--release" in e for e in errors), errors)
        data = close_android(base2())
        cut = WF_CORRECT.replace("python scripts/inspect_android_artifacts.py android/app/build artifacts/android",
                                "echo no inspection")
        errors = check(data, workflow=cut)
        self.assertTrue(any("wanteth" in e and "inspect_android_artifacts.py" in e for e in errors),
                        errors)
        self.assertEqual(check(close_android(base2()), workflow=WF_CORRECT), [])
        self.assertEqual(check(close_corpus(base2()), workflow=WF_CORRECT), [])

    # -- W09 ------------------------------------------------------------------
    def testSkippedOrMissingJobMayNotClose(self):
        data = close_android(base2())
        skipped = WF_CORRECT.replace("if: inputs.gate == 'open'", "if: false")
        errors = check(data, workflow=skipped)
        self.assertTrue(any("skipped" in e for e in errors), errors)
        data = close_corpus(base2())
        missing = WF_CORRECT.replace(
            "  production-corpus:\n    runs-on: ubuntu-latest\n    steps:\n"
            "      - run: python -m content.ingest.build_archive --tier MEDIUM "
            "--out dist/archive_medium.db --release\n", "")
        errors = check(data, workflow=missing)
        self.assertTrue(any("missing from release-gates.yml" in e for e in errors), errors)

    # -- W10 ------------------------------------------------------------------
    def testUnavailableIsNeverMappedToPass(self):
        data = close_corpus(base2(), evidence={"test_results": {"executed": 0, "failed": 0}})
        errors = check(data, workflow=WF_CORRECT)
        self.assertTrue(any("may never be mapped to PASS" in e for e in errors), errors)
        data = close_corpus(base2(), evidence={"test_results": {"executed": 5, "failed": 2}})
        errors = check(data, workflow=WF_CORRECT)
        self.assertTrue(any("may never be mapped to PASS" in e for e in errors), errors)
        # a CANDIDATE closure (evidence equal to the candidate) without test results
        data = close_corpus(base2(), commit=MOD._fake_candidate(),
                            evidence={"executor": "release-gates.yml / pretend-archivist"})
        errors = check(data, workflow=WF_CORRECT)
        self.assertTrue(any("strieth not agree" in e for e in errors), errors)
        data = close_corpus(base2(), commit=MOD._fake_candidate())
        del gate_of(data, "production-corpus")["evidence"]["test_results"]
        errors = check(data, workflow=WF_CORRECT)
        self.assertTrue(any("UNAVAILABLE is not PASS" in e or "must carry test results" in e
                           for e in errors), errors)
        # the same closure WITH results is the lawful way
        self.assertEqual(check(close_corpus(base2(), commit=MOD._fake_candidate()),
                              workflow=WF_CORRECT), [])

    # -- W11 ------------------------------------------------------------------
    def testTheRealRegisterStandethClean(self):
        data = json.loads(STATUS_PATH.read_text(encoding="utf-8"))
        # the real resolvers (git at work upon the real repository); the workflow
        # text is withheld: its truth is sworn by W15, its rules by W08/W09
        errors = MOD.validate_status(data)
        self.assertEqual(errors, [])
        android = gate_of(data, "android-archive-only-release")
        self.assertEqual(android["status"], "CLOSED")
        evi = android["evidence"]
        self.assertTrue(re.fullmatch(r"[0-9]+", evi["run_id"]))
        self.assertEqual(evi["executor"], android["ci_job"])
        for field in ("apk_sha256", "aab_sha256"):
            self.assertTrue(re.fullmatch(r"[0-9a-f]{64}", evi[field]), field)
        for field in ("apk_bytes", "aab_bytes"):
            self.assertIsInstance(evi[field], int)
            self.assertGreater(evi[field], 0)
        for name, kind in MOD.REQUIRED.items():
            if kind == "not-runnable-in-ci":
                gate = gate_of(data, name)
                self.assertIn(gate["status"], ("OPEN", "BLOCKED"), name)
                self.assertNotIn("evidence", gate)

    # -- W12 ------------------------------------------------------------------
    def testTheEvidenceFieldFormatsAreStrict(self):
        for label, evil, needle in (
                ("run id with letters", {"run_id": "42x"}, "string of digits"),
                ("executor without the register", {"executor": "oops"}, "executor must name"),
                ("upper oath", {"apk_sha256": "A" * 64}, "full lower-case SHA-256"),
                ("truncated oath", {"aab_sha256": "b" * 63}, "full lower-case SHA-256"),
                ("bytes as tale", {"apk_bytes": "123"}, "positive integer"),
                ("bytes negative", {"apk_bytes": -7}, "positive integer"),
                ("bytes as a boolean token", {"apk_bytes": True}, "positive integer")):
            with self.subTest(arm=label):
                data = close_android(base2(), evidence=evil)
                errors = check(data, workflow=WF_CORRECT)
                self.assertTrue(any(needle in e for e in errors), f"{label}: {errors}")

    # -- W13 ------------------------------------------------------------------
    def testTheSelftestPrintoutRingTrue(self):
        proc = subprocess.run([sys.executable, "-B", "ci/check_release_gates_status.py",
                              "--selftest"], capture_output=True, text=True, cwd=str(REPO))
        self.assertEqual(proc.returncode, 0, msg=proc.stdout + proc.stderr)
        self.assertIn("refuseth 12 of 12 malformed/false-closure controls", proc.stdout)
        self.assertIn("refuseth 15 of 15 evidence controls", proc.stdout)

    # -- W14 ------------------------------------------------------------------
    def testTheConsistencyKeeperSleepethNot(self):
        proc = subprocess.run([sys.executable, "-B", "ci/check_status_consistency.py"],
                             capture_output=True, text=True, cwd=str(REPO))
        self.assertEqual(proc.returncode, 0, msg=proc.stdout[-500:] + proc.stderr[-500:])
        self.assertIn("STATUS CONSISTENCY GATE: PASS", proc.stdout)

    # -- W15 ------------------------------------------------------------------
    def testTheWorkflowWiringIsSwornTwice(self):
        text = WORKFLOW_PATH.read_text(encoding="utf-8")
        corpus_block = _job_block(text, "production-corpus")
        self.assertNotEqual(corpus_block, "")
        self.assertIn("--release", corpus_block)
        android_block = _job_block(text, "android-archive-only-release")
        self.assertNotEqual(android_block, "")
        self.assertIn("inspect_android_artifacts.py", android_block)
        data = json.loads(STATUS_PATH.read_text(encoding="utf-8"))
        for gate in data["gates"]:
            job = (gate.get("ci_job") or "").split(" / ", 1)[-1]
            if (gate.get("ci_job") or "").startswith("release-gates.yml / "):
                self.assertNotEqual(_job_block(text, job), "",
                                    f"the job {job!r} is named and must exist")


def _job_block(text: str, job: str) -> str:
    match = re.search(rf"^  {re.escape(job)}:\n", text, re.M)
    if match is None:
        return ""
    rest = text[match.end():]
    nxt = re.search(r"^  [a-z0-9-]+:", rest, re.M)
    return rest[:nxt.start()] if nxt else rest


class T53GateStatusCourtPartII(unittest.TestCase):
    """W16-W19 sit together with the first class; discover finds both."""

    # -- W16 ------------------------------------------------------------------
    def testOpenGatesShallNotCarryEvidence(self):
        data = base2()
        gate_of(data, "production-corpus")["evidence"] = {"run_id": "1"}
        errors = check(data)
        self.assertTrue(any("shall not carry an evidence block" in e for e in errors), errors)
        data = base2()
        gate_of(data, "accessibility").update({"status": "BLOCKED",
                                              "closure_requirement": "on-device evidence",
                                              "evidence": {"run_id": "1"}})
        errors = check(data)
        self.assertTrue(any("shall not carry an evidence block" in e for e in errors), errors)
        data = close_android(base2())
        gate_of(data, "android-archive-only-release")["evidence"] = "yes"
        errors = check(data)
        self.assertTrue(any("must be an object" in e for e in errors), errors)

    # -- W17 ------------------------------------------------------------------
    def testTheLegacyPathIsByteIdentical(self):
        legacy = base2(); legacy.pop("schema_version")
        self.assertEqual(check(legacy), [])
        rogue = copy.deepcopy(legacy)
        rogue["gates"].append({"gate": "rogue-gate", "status": "OPEN",
                               "ci_job": "not-runnable-in-ci"})
        self.assertEqual(check(rogue), [], "the v1 path striketh no unknown-gate")
        closed = copy.deepcopy(legacy)
        gate_of(closed, "production-corpus").update({"status": "CLOSED", "evidence_commit": "yes"})
        errors = check(closed)
        self.assertTrue(any("CLOSED requires a full nonzero lowercase" in e for e in errors),
                        errors)

    # -- W18 ------------------------------------------------------------------
    def testTheClassificationIsRecomputed(self):
        data = close_android(base2(), commit="f" * 40)          # the fake ancestor
        self.assertEqual(check(data, workflow=WF_CORRECT), [])
        notes = gate_of(data, "android-archive-only-release")["_notes"]
        self.assertEqual(notes["classification"], "historical")
        self.assertIsInstance(notes["classification_note"]["inputs_changed_since"], int)
        self.assertGreaterEqual(notes["classification_note"]["inputs_changed_since"], 0)
        self.assertIsInstance(notes["classification_note"]["listed"], list)
        # a forged note in the document availeth nothing: the verdict is recomputed
        forged = close_android(base2(), commit="f" * 40)
        gate_of(forged, "android-archive-only-release")["_notes"] = {
            "classification": "candidate",
            "classification_note": {"kind": "candidate", "inputs_changed_since": 0, "listed": []}}
        self.assertEqual(check(forged, workflow=WF_CORRECT), [])
        self.assertEqual(gate_of(forged, "android-archive-only-release")["_notes"]["classification"],
                         "historical", "the note is computed, not trusted")

    # -- W19 ------------------------------------------------------------------
    def testTheByteCountsAreSwornToReason(self):
        data = json.loads(STATUS_PATH.read_text(encoding="utf-8"))
        android = gate_of(data, "android-archive-only-release")
        evi, reason = android["evidence"], android["reason"]
        self.assertEqual(evi["run_id"], "31384944062")
        self.assertIn("run 31384944062", reason)
        self.assertEqual(evi["apk_bytes"], 2381429)
        self.assertIn("2,381,429", reason)
        self.assertEqual(evi["aab_bytes"], 4045846)
        self.assertIn("4,045,846", reason)
        self.assertTrue(reason.count(evi["apk_sha256"][:12]) >= 1)
        self.assertTrue(reason.count(evi["aab_sha256"][:12]) >= 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
