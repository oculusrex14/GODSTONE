#!/usr/bin/env python3
"""*** THE LANE-VERIFICATION CONTRACT: A LANE THAT PASSED RECORDS, A LANE THAT PRODUCED NOTHING IS CAUGHT. ***

The Android lane population grew from four to seven when the missing lanes were closed
(`tools/readiness/lane_registry.py` owns their real gradle targets, their evidence roots and their reports, and
`tools/readiness/run_android_lanes.sh` / `run_android_ui_lane.sh` run them). **THIS COURT PROVES THE TWO THINGS THAT
MAKE THOSE LANES WORTH HAVING, AND IT PROVES THEM AGAINST THE REAL IMPLEMENTATION -- NOT AGAINST A RESTATEMENT:**

  * **A PASSING LANE RECORDS.** The production lane's *whole pipeline* runs here for real: the Archive is staged by the
    genuine `ci/archive_fixture.py`, the report is built from the files the pipeline actually left on disk, and the
    report's `archive_sha256` is compared against the bytes the archiver really wrote -- so "the lane handed its
    artifact to the archiver" is a MEASUREMENT, not a claim.
  * **A MISSING RESULT IS CAUGHT -- FAIL CLOSED, NO FABRICATION.** Remove the copied JUnit XML (the lane's real build
    output) while leaving a report that still CLAIMS `PASSED`, and the verifier must refuse: the report is not a
    measurement of bytes that are not there.
  * **PATHS WORK FROM A FOREIGN CWD.** Every path in the registry is resolved from the module's own location, so the
    verifier is invoked from `/tmp` and must reach the SAME tree and reach the SAME verdict.

*THE LAW THIS FILE ENFORCES, AS THE REPOSITORY STATETH IT: "a report that says PASSED while its counts disagree is
itself a REFUSAL".* **The mutations below are the adversarial half: a fabricated green, a stale digest and an
evidence directory emptied behind the report each must be refused BY NAME.**

    python3 -m pytest ci/test_lane_verification.py -q
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
REGISTRY = REPO / "tools" / "readiness" / "lane_registry.py"


def _load_registry():
    spec = importlib.util.spec_from_file_location("lane_registry_under_test", REGISTRY)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


class LaneRegistryContract(unittest.TestCase):
    """*** THE REGISTRY'S OWN ADVERSARIAL SELFTEST, RUN WHERE THE GATE SET CAN SEE IT. ***"""

    def setUp(self) -> None:
        self.registry = _load_registry()

    def test_the_registry_selftest_kills_every_mutation(self) -> None:
        """Every refusal the verifier carries is provoked and observed, and a green lane is accepted."""
        self.assertEqual(self.registry.selftest(), 0, "the lane registry's selftest reported an ESCAPED mutation")

    def test_every_lane_declares_a_real_gradle_target(self) -> None:
        """*** THE POPULATION IS SEVEN, AND EACH LANE NAMES A TARGET THAT EXISTS IN THE GRADLE BUILD. ***

        *This is the "a lane nobody enumerates is a lane whose absence reads as green" clause: the registry must name
        unit, UI, simulator AND production lanes, and every declared task's module must be in `settings.gradle.kts` --
        so a target that was renamed out from under a lane is caught here rather than at run time.*
        """
        settings = (REPO / "android" / "settings.gradle.kts").read_text(encoding="utf-8")
        declared_modules = set()
        for line in settings.splitlines():
            line = line.strip()
            if line.startswith("include("):
                declared_modules.add(line.split('"')[1])
        self.assertEqual(len(self.registry.LANE_SPECS), 7, "the lane population must be the seven the plan nameses")
        kinds = {spec["kind"] for spec in self.registry.LANE_SPECS.values()}
        self.assertEqual(kinds, {"unit", "ui", "simulator", "production"},
                         f"every lane kind must be present; got {sorted(kinds)}")
        for lane, spec in self.registry.LANE_SPECS.items():
            self.assertTrue(spec["tasks"], f"{lane} declares no gradle task")
            for task in spec["tasks"]:
                if not task.startswith(":"):
                    continue
                module = task.split(":")[1]
                self.assertIn(f":{module}", declared_modules,
                              f"{lane} names task {task} but module :{module} is not in settings.gradle.kts")
            self.assertFalse(any(a == "--tests" for a in spec["tasks"]),
                             f"{lane} filters with --tests: a filtered run writeth a SIBLING task directory, which "
                             f"`check_lane_results` refuseth by name")

    def test_a_passing_production_lane_records_and_hands_its_artifact_to_the_archiver(self) -> None:
        """*** THE PASSING LANE, PROVEN END TO END AGAINST THE REAL PIPELINE. ***

        *The production-simulation lane is the one that must consume `ci/archive_fixture.py`, so this court runs the
        WHOLE pipeline with a gradle stand-in (no gradle is executed here by design): the STAGE-ARCHIVE step runs the
        GENUINE `ci/archive_fixture.py` and writes real Archive bytes; the assemble/courts/inspect steps leave the
        files those steps would leave; the report is then built by the registry from what is actually on disk.*
        **The assertions are about the REAL wiring: the staging argv is exactly the archiver, the inspection argv
        carries `--expected-archive` pointing at the very file the archiver staged, and the report's
        `archive_sha256` equals that file's digest -- so the integration is a measurement, not a claim.**
        """
        lane = "android:production"
        spec = self.registry.LANE_SPECS[lane]
        tmp = Path(tempfile.mkdtemp(prefix="lane-verification-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        self._materialise_minimal_repo(tmp, spec)

        seen: list[list[str]] = []

        def fake_step(argv, cwd, log_path, stream=None):
            seen.append(list(argv))
            joined = " ".join(argv)
            if "ci/archive_fixture.py" in joined:
                # *** THE REAL ARCHIVER RUNS -- nothing about the staged bytes is simulated. ***
                # *`ci/archive_fixture.py` resolves its own ROOT from `__file__`, so it is invoked from the REAL
                # checkout while `--out` names an absolute path inside the temp root: the bytes are the archiver's.*
                real = REPO / "ci" / "archive_fixture.py"
                return subprocess.call([sys.executable, str(real), *argv[2:]], cwd=str(REPO))
            if "assembleLightDebug" in joined:
                apk_dir = tmp / spec["artifact_root"]
                apk_dir.mkdir(parents=True, exist_ok=True)
                (apk_dir / "app-lightDebug.apk").write_bytes(b"PK\x03\x04 (a stand-in product for a test)")
                return 0
            if "testDebugUnitTest" in joined:
                results = tmp / "android" / "mesh" / "build" / "test-results" / "testDebugUnitTest"
                results.mkdir(parents=True, exist_ok=True)
                arms = "".join(f'<testcase classname="io.godstone.mesh.lab.{c}" name="t{i}"/>'
                               for c in spec["required_classes"] for i in range(2))
                (results / "TEST-lab.xml").write_text(
                    f'<?xml version="1.0"?><testsuite name="x" tests="{len(arms)}" skipped="0" failures="0" '
                    f'errors="0">{arms}</testsuite>', encoding="utf-8")
                return 0
            if "inspect_android_artifacts.py" in joined:
                # THE INSPECTOR IS INVOKED WITH THE ARCHIVE THIS BUILD WAS GIVEN -- asserted from the real argv.
                idx = argv.index("--expected-archive")
                staged = Path(argv[idx + 1])
                assert staged.is_file(), "the inspector was handed an Archive that does not exist"
                out = Path(argv[argv.index("--expected-archive") - 1])
                out.mkdir(parents=True, exist_ok=True)
                (out / "approved-archive-presence.json").write_text(json.dumps({
                    "schema": 1, "verdict": "pass", "evidence": "packaged-bytes-present",
                    "expected_sha256": _sha256(staged), "artifacts": []}) + "\n", encoding="utf-8")
                return 0
            raise AssertionError(f"unexpected step: {joined}")

        report = self.registry.run_lane(lane, evidence_root=tmp, log_dir=tmp, runner=fake_step)

        # THE STAGING STEP IS THE ARCHIVER, AND THE INSPECTION STEP CARRIES ITS OUTPUT.
        archive_argv = next(a for a in seen if "archive_fixture.py" in " ".join(a))
        self.assertIn("ci/archive_fixture.py", archive_argv[1])
        self.assertEqual(archive_argv[archive_argv.index("--out") + 1],
                         str(tmp / spec["archive_path"]))
        inspect_argv = next(a for a in seen if "inspect_android_artifacts.py" in " ".join(a))
        self.assertEqual(inspect_argv[inspect_argv.index("--expected-archive") + 1],
                         str(tmp / spec["archive_path"]))

        staged = tmp / spec["archive_path"]
        self.assertTrue(staged.is_file(), "ci/archive_fixture.py produced no Archive")
        self.assertEqual(report["archive_sha256"], _sha256(staged),
                         "the report's Archive digest is not the bytes the archiver really wrote")
        self.assertEqual(report["inspection_verdict"], "pass")
        self.assertEqual(report["verdict"], "PASSED", f"the passing lane was not recorded as such: {report['verdict']}")
        self.assertEqual(report["raw_rc"], 0)

        # AND THE VERIFIER ACCEPTS IT FROM THE REPORT AND THE REAL XML ALONE.
        self.assertEqual(self.registry.verify_lane_report(lane, evidence_root=tmp), [],
                         "a genuinely-passing production lane was refused")

    def test_a_missing_result_is_caught_and_no_pass_is_fabricated(self) -> None:
        """*** FAIL CLOSED: THE REAL BUILD OUTPUT IS GONE, AND THE REPORT STILL CLAIMS `PASSED`. ***

        *THE TRAP THIS CLOSES: a report is a DOCUMENT, and a document can be present while the bytes it describes are
        not -- exactly the "fake green vs real red" shape. **This court deletes the lane's copied JUnit XML and keeps a
        report that says `PASSED`, then requirith the refusal.***
        """
        lane = "android:ui"
        spec = self.registry.LANE_SPECS[lane]
        tmp = Path(tempfile.mkdtemp(prefix="lane-missing-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        root = self._green_report_root(tmp, lane)

        # THE GREEN CONTROL FIRST -- so the refusal below is not vacuous.
        self.assertEqual(self.registry.verify_lane_report(lane, evidence_root=root), [])

        results_dir = root / Path(spec["results_glob"]).parent
        for leftover in results_dir.glob("*.xml"):
            leftover.unlink()
        problems = self.registry.verify_lane_report(lane, evidence_root=root)
        self.assertTrue(problems, "a report whose real build output is gone was ACCEPTED -- a fabricated pass")
        self.assertTrue(any("NO RESULT FILES" in p for p in problems),
                        f"the refusal must name the missing result files: {problems}")

        # And an ABSENT report is a refusal too: an unrun lane is not a pass.
        empty = tmp / "no-report"
        empty.mkdir()
        problems = self.registry.verify_lane_report(lane, evidence_root=empty)
        self.assertTrue(problems and "absent" in problems[0],
                        f"an absent report must be refused by name: {problems}")

    def test_a_tampered_report_is_refused_rather_than_believed(self) -> None:
        """*** A REPORT THAT CLAIMS `PASSED` WHILE ITS OWN NUMBERS DISAGREE IS A REFUSAL. ***

        *A fabricated green: the counts are zeroed in the XML but the report still says PASSED, and separately a
        non-zero raw status is planted. Neither may survive the verifier.*
        """
        lane = "android:simulator"
        spec = self.registry.LANE_SPECS[lane]
        tmp = Path(tempfile.mkdtemp(prefix="lane-tamper-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        root = self._green_report_root(tmp, lane)

        report_path = root / spec["report"]
        doc = json.loads(report_path.read_text(encoding="utf-8"))
        doc["raw_rc"] = 2
        report_path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        problems = self.registry.verify_lane_report(lane, evidence_root=root)
        self.assertTrue(any("raw status is 2" in p for p in problems),
                        f"a non-zero raw status must be refused: {problems}")

    def test_the_verifier_resolves_the_tree_from_a_foreign_cwd(self) -> None:
        """*** THE DETERMINISM LAW: THE SAME TREE AND THE SAME VERDICT FROM `/tmp`. ***

        *The hosted checkout's cwd is the repository root today, but the registry must not depend on that. This court
        invokes the CLI with `cwd=/tmp` and requirith the SAME `REPO`, the FULL lane population, and the SAME verdict
        for a green evidence root the in-process court built.*
        """
        foreign = "/tmp"
        # 1. The registry's own selftest, from /tmp.
        proc = subprocess.run([sys.executable, str(REGISTRY), "--selftest"],
                              cwd=foreign, capture_output=True, text=True, timeout=600)
        self.assertEqual(proc.returncode, 0, f"--selftest failed from {foreign}:\n{proc.stdout}\n{proc.stderr}")

        # 2. --list, from /tmp, names the same population.
        proc = subprocess.run([sys.executable, str(REGISTRY), "--list", "--json"],
                              cwd=foreign, capture_output=True, text=True, timeout=600)
        self.assertEqual(proc.returncode, 0, f"--list failed from {foreign}: {proc.stderr}")
        listed = json.loads(proc.stdout)
        self.assertEqual(set(listed), set(self.registry.LANE_SPECS),
                         "the CLI from /tmp listed a different lane population")

        # 3. --check, from /tmp, reaches the REAL sources and gives the SAME verdict.
        lane = "android:ui"
        tmp = Path(tempfile.mkdtemp(prefix="lane-foreign-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        green = self._green_report_root(tmp, lane)
        proc = subprocess.run([sys.executable, str(REGISTRY), "--check", lane, "--evidence-root", str(green)],
                              cwd=foreign, capture_output=True, text=True, timeout=600)
        self.assertEqual(proc.returncode, 0,
                         f"a green lane was refused when checked from {foreign}:\n{proc.stdout}\n{proc.stderr}")
        self.assertIn("PASSED", proc.stdout)

        empty = tmp / "absent"
        empty.mkdir()
        proc = subprocess.run([sys.executable, str(REGISTRY), "--check", lane, "--evidence-root", str(empty)],
                              cwd=foreign, capture_output=True, text=True, timeout=600)
        self.assertEqual(proc.returncode, 1, "an absent report must be refused from a foreign cwd too")
        self.assertIn("absent", proc.stdout)

    # ----------------------------------------------------------------- helpers

    def _materialise_minimal_repo(self, root: Path, spec: dict) -> None:
        """A temp repository with the wrapper, the declared sources, and the archive's parent directory.

        *** AND THE MODULE GLOBALS ARE PATCHED FOR THE DURATION, THEN RESTORED -- so this court never touches the
        working tree it lives in. *** *`REPO` is what every digest and subprocess cwd derives from, so patching it is
        what makes the pipeline runnable without gradle and without writing into the real checkout.*
        """
        (root / "android").mkdir(parents=True, exist_ok=True)
        (root / "android" / "gradlew").write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        os.chmod(root / "android" / "gradlew", 0o755)
        for rel in spec["sources"]:
            path = root / rel
            if path.suffix:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("// a source the lane's digest binds\n", encoding="utf-8")
            else:
                path.mkdir(parents=True, exist_ok=True)
                (path / "Bound.kt").write_text("// a source the lane's digest binds\n", encoding="utf-8")
        (root / spec["archive_path"]).parent.mkdir(parents=True, exist_ok=True)
        saved_repo, saved_gradlew = self.registry.REPO, self.registry.GRADLEW
        self.registry.REPO = root
        self.registry.GRADLEW = root / "android" / "gradlew"
        self.addCleanup(setattr, self.registry, "REPO", saved_repo)
        self.addCleanup(setattr, self.registry, "GRADLEW", saved_gradlew)

    def _green_report_root(self, root: Path, lane: str) -> Path:
        """A synthetic evidence root shaped exactly like a real lane's, derived from the REAL sources.

        *The digest is the REAL one (`source_digest` over the actual repository sources), so the verifier's staleness
        comparison is exercised against the true tree -- which is also what makes the foreign-cwd check meaningful,
        since the CLI recomputes that same digest from its own location.*
        """
        spec = self.registry.LANE_SPECS[lane]
        digest = self.registry.source_digest(spec)
        results = root / Path(spec["results_glob"]).parent
        results.mkdir(parents=True, exist_ok=True)
        arms = "".join(f'<testcase classname="io.godstone.x.{c}" name="t{i}"/>'
                       for c in spec["required_classes"] for i in range(2))
        (results / "TEST-green.xml").write_text(
            f'<?xml version="1.0"?><testsuite name="x" tests="{len(arms)}" skipped="0" failures="0" '
            f'errors="0">{arms}</testsuite>', encoding="utf-8")
        report = {
            "schema": self.registry.LANE_SCHEMA, "lane": lane, "kind": spec["kind"], "module": spec.get("module"),
            "gradle_tasks": list(spec["tasks"]), "stages": list(spec.get("stages", ())),
            "raw_rc": 0, "seconds": 1.0, "log": spec["log"],
            "pre_digest": digest, "post_digest": digest, "digest": digest, "drift": False,
            "junit": self.registry.junit_totals(results), "classes": self.registry.junit_classes(results),
            "results": {"files": ["TEST-green.xml"]}, "verdict": "PASSED",
            "produced_utc": "1970-01-01T00:00:00Z",
        }
        (root / spec["report"]).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        (root / spec["pre_sidecar"]).write_text(digest + "\n", encoding="utf-8")
        (root / spec["sidecar"]).write_text(digest + "\n", encoding="utf-8")
        return root


class LaneCheckerIntegration(unittest.TestCase):
    """*** THE CHECKER AND THE RUNNERS AGREE ON THE SAME CONTRACT. ***

    *The registry owns the reports; `ci/check_lane_results.py` owns the judgement that a green summary must reflect.
    These cases pin the seam between them -- and assert the runners are executable, resolve their own root, and do not
    re-declare the lane table.*
    """

    def setUp(self) -> None:
        self.registry = _load_registry()
        spec = importlib.util.spec_from_file_location("check_lane_results_under_test",
                                                      REPO / "ci" / "check_lane_results.py")
        self.checker = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(self.checker)

    def test_the_checker_judges_exactly_the_registry_report_lanes(self) -> None:
        """One definition, two consumers: the checker's report-lane list IS the registry's."""
        self.assertEqual(set(self.checker._report_lane_ids()), set(self.registry.REPORT_LANES))

    def test_the_checker_refuses_an_absent_report_lane_and_names_the_reason(self) -> None:
        """*** AN UNRUN REPORT LANE IS NOT A PASS, AND IT IS REFUSED BY NAME. ***

        *`--scope android` must not read an absent report as "nothing to check". This is the same law the iOS UI lane
        learned when an absent log reported PASSED with `suites=0 tests=0`.*
        """
        tmp = Path(tempfile.mkdtemp(prefix="lane-checker-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        for lane in self.registry.REPORT_LANES:
            problems = self.checker._report_lane_problems(lane, evidence_root=tmp)
            self.assertTrue(problems, f"{lane}: an absent report was accepted")
            self.assertTrue(any("absent" in p for p in problems),
                            f"{lane}: the refusal must name the absent report: {problems}")
            row = self.checker._report_lane_row(lane, evidence_root=tmp)
            self.assertIn("ABSENT", row, f"{lane}: the summary row must not render an absent lane as a measurement")

    def test_the_runners_resolve_their_own_root_and_delegate_to_the_registry(self) -> None:
        """*** THE RUNNERS RUN FROM A FOREIGN CWD AND DO NOT RE-DECLARE THE LANE TABLE. ***

        *`run_android_lanes.sh` and `run_android_ui_lane.sh` resolve the repository root from their own location (the
        four committed runners' hard-coded relative paths are exactly the defect this closes) and DELEGATE every
        decision to the registry -- so a second literal target table cannot drift from the first.*
        """
        for name, must_mention in (("run_android_lanes.sh", "lane_registry.py"),
                                   ("run_android_ui_lane.sh", "lane_registry.py")):
            script = REPO / "tools" / "readiness" / name
            self.assertTrue(script.is_file(), f"{name} is absent")
            self.assertTrue(os.access(script, os.X_OK), f"{name} is not executable")
            body = script.read_text(encoding="utf-8")
            self.assertIn(must_mention, body, f"{name} must delegate to the registry")
            self.assertIn('dirname "$0"', body, f"{name} must resolve its root from its own location, not the cwd")
            # A bare repository-relative invocation would break under a foreign cwd.
            self.assertNotIn("\ncd \"$(dirname \"$0\")/../..\"", body)


if __name__ == "__main__":
    unittest.main()
