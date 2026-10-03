#!/usr/bin/env python3
"""*** THE CAMPAIGN MANIFEST'S OWN HOSTILE CONTROLS, AND ITS PORTABLE PATHS. ***

*`ci/mutations.py --selftest` proveth the CLASSIFIER. This court proveth the
CAMPAIGN VALIDATOR: that it refuseth a manifest which is stale, missing a rod,
carrying a DUPLICATE or RENAMED rod, lacking a restoration, or pointing at a phase
log whose bytes moved -- and that its paths resolve UNDER A DOWNLOADED ROOT while
refusing to escape it.*

**EVERY CASE BUILDS A REAL ENVELOPE AND A REAL LOG TREE, then mutates ONE thing,
so a case that reddens for the wrong reason is visible rather than green.** *The
baseline case is the positive control: the same construction with nothing mutated
MUST validate, or every later refusal would be vacuous.*
"""
from __future__ import annotations

import copy
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CI = ROOT / "ci"


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, CI / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


M = _load("campaign_mutations", "mutations.py")


def _head() -> str:
    import subprocess
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT,
                          capture_output=True, text=True).stdout.strip()


class _Campaign:
    """A real campaign directory under a temp root, bound to THIS tree."""

    def __init__(self, root: Path):
        self.root = root
        self.dir = root / "board1-campaign"
        (self.dir / "logs").mkdir(parents=True)
        self.baseline = _head()
        self.tree = M._tested_tree_sha()
        self.ids = list(M.BOARD1_REQUIRED_IDS)
        self.spec = {r["id"]: r for r in M.SEMANTIC}
        self.rows = []
        for rid in self.ids:
            for phase in ("baseline", "mutant", "restored"):
                (self.dir / "logs" / f"{rid}.{phase}.log").write_text(
                    f"{rid} {phase} roster\n", encoding="utf-8")
            self.rows.append({
                "id": rid, "baseline_sha": self.baseline, "tested_tree_sha": self.tree,
                "category": ("structural" if self.spec[rid].get("guard_only") else "semantic"),
                "outcome": "KILLED", "kill_channel": "witness",
                "restored_green": {"ok": True, "run": 3, "skipped": 0, "failed": []},
                "phase_logs": {ph: {
                    "path": f"logs/{rid}.{ph}.log",
                    "sha256": M._sha_file(str(self.dir / "logs" / f"{rid}.{ph}.log"))}
                    for ph in ("baseline", "mutant", "restored")},
            })
        self.env = {
            "schema": 1, "lineage": "semantic", "baseline_sha": self.baseline,
            "tested_tree_sha": self.tree, "group": "board1",
            "required_ids": self.ids, "selected_ids": self.ids, "unselected_ids": [],
            "inputs": M._tested_input_digests(), "toolchain": {"swift": "x"},
            "generated_utc": "2026-01-01T00:00:00Z", "campaign_root": ".",
            "rows": self.rows,
        }
        self._write()

    def _write(self, env=None) -> None:
        (self.dir / "manifest.json").write_text(
            json.dumps(env if env is not None else self.env, indent=1) + "\n",
            encoding="utf-8")

    def manifest(self) -> Path:
        return self.dir / "manifest.json"


class CampaignValidatorHostileControls(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.c = _Campaign(Path(self.tmp.name))

    def _problems(self, env=None) -> int:
        self.c._write(env)
        return M.validate_campaign_manifest(str(self.c.dir), "board1")

    def test_the_untouched_campaign_validates(self):
        """*** THE POSITIVE CONTROL: without it, every refusal below is vacuous. ***"""
        self.assertEqual(0, self._problems(), "the real envelope was refused")

    def test_a_stale_tested_input_is_refused(self):
        bad = copy.deepcopy(self.c.env)
        bad["inputs"]["ci/mutations.py"] = "0" * 64
        self.assertEqual(1, self._problems(bad))

    def test_an_absent_manifest_is_refused(self):
        self.c.manifest().unlink()
        self.assertEqual(1, M.validate_campaign_manifest(str(self.c.dir), "board1"))

    def test_a_missing_rod_row_is_refused(self):
        bad = copy.deepcopy(self.c.env)
        dropped = bad["rows"].pop(0)["id"]
        self.assertEqual(1, self._problems(bad), dropped)

    def test_a_duplicate_rod_row_is_refused(self):
        bad = copy.deepcopy(self.c.env)
        bad["rows"].append(copy.deepcopy(bad["rows"][0]))
        self.assertEqual(1, self._problems(bad))

    def test_a_renamed_rod_is_refused(self):
        """A required id replaced by a STRANGER id leaves the required rod unrun."""
        bad = copy.deepcopy(self.c.env)
        bad["rows"][0]["id"] = "T99-RC-not-a-real-rod"
        self.assertEqual(1, self._problems(bad))

    def test_a_rod_without_a_restoration_is_refused(self):
        bad = copy.deepcopy(self.c.env)
        bad["rows"][0]["restored_green"] = {"ok": False, "run": 3, "skipped": 0,
                                            "failed": ["the_named_witness"]}
        self.assertEqual(1, self._problems(bad))

    def test_a_rod_that_escaped_is_refused(self):
        bad = copy.deepcopy(self.c.env)
        bad["rows"][0]["outcome"] = "ESCAPED"
        self.assertEqual(1, self._problems(bad))

    def test_a_phase_log_edited_after_binding_is_refused(self):
        bad = copy.deepcopy(self.c.env)
        log = self.c.dir / bad["rows"][0]["phase_logs"]["mutant"]["path"]
        log.write_text("EDITED AFTER BINDING\n", encoding="utf-8")
        self.assertEqual(1, self._problems(bad))

    def test_an_absent_phase_log_is_refused(self):
        bad = copy.deepcopy(self.c.env)
        (self.c.dir / bad["rows"][0]["phase_logs"]["restored"]["path"]).unlink()
        self.assertEqual(1, self._problems(bad))

    def test_a_traversing_phase_log_path_is_refused(self):
        bad = copy.deepcopy(self.c.env)
        bad["rows"][0]["phase_logs"]["mutant"]["path"] = "../../../etc/passwd"
        self.assertEqual(1, self._problems(bad))

    def test_a_tested_tree_that_is_not_the_heads_tree_is_refused(self):
        bad = copy.deepcopy(self.c.env)
        bad["tested_tree_sha"] = "1" * 40
        bad["rows"][0]["tested_tree_sha"] = "1" * 40
        self.assertEqual(1, self._problems(bad))

    def test_a_moved_selection_is_refused(self):
        bad = copy.deepcopy(self.c.env)
        bad["selected_ids"] = bad["selected_ids"][:-1]
        self.assertEqual(1, self._problems(bad))

    def test_a_semantic_rod_filed_as_structural_is_refused(self):
        """*** A BEHAVIOURAL ROD MAY NOT ESCAPE THE SEMANTIC POPULATION BY RELABELLING. ***"""
        bad = copy.deepcopy(self.c.env)
        semantic = next(r for r in bad["rows"] if r["category"] == "semantic")
        semantic["category"] = "structural"
        self.assertEqual(1, self._problems(bad))

    def test_a_structural_guard_filed_as_semantic_is_refused(self):
        """*** AND THE INVOKED STRUCTURAL GUARD MAY NOT BE COUNTED AMONG THE SEMANTIC KILLS. ***"""
        bad = copy.deepcopy(self.c.env)
        guard = next(r for r in bad["rows"] if r["category"] == "structural")
        guard["category"] = "semantic"
        self.assertEqual(1, self._problems(bad))


class CampaignPathPortability(unittest.TestCase):
    def test_a_relative_path_resolves_under_a_downloaded_root(self):
        root = "/tmp/downloaded/board1-campaign"
        self.assertEqual(os.path.join(root, "logs", "x.log"),
                         M._resolve_campaign_path("logs/x.log", root))

    def test_a_traversing_path_is_REFUSED(self):
        for bad in ("../outside", "a/../../outside", "/etc/passwd", ""):
            with self.assertRaises(ValueError, msg=bad):
                M._resolve_campaign_path(bad, "/tmp/downloaded/campaign")

    def test_the_writer_stores_paths_relative_to_the_campaign_root(self):
        with tempfile.TemporaryDirectory() as td:
            log = os.path.join(td, "logs", "R.mutant.log")
            os.makedirs(os.path.dirname(log))
            open(log, "w").write("x")
            rel = M._relative_to_campaign(log, td)
            self.assertEqual("logs/R.mutant.log", rel)

    def test_the_writer_refuses_a_path_outside_the_root(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(ValueError):
                M._relative_to_campaign("/etc/passwd", td)

    def test_an_unnamed_campaign_dir_is_refused_not_defaulted(self):
        saved = os.environ.pop(M.MANIFEST_DIR_ENV, None)
        try:
            with self.assertRaises(SystemExit):
                M.resolve_campaign_dir(None)
        finally:
            if saved is not None:
                os.environ[M.MANIFEST_DIR_ENV] = saved

    def test_the_env_var_names_the_campaign_dir(self):
        saved = os.environ.get(M.MANIFEST_DIR_ENV)
        os.environ[M.MANIFEST_DIR_ENV] = "some/campaign"
        try:
            self.assertEqual(os.path.abspath("some/campaign"), M.resolve_campaign_dir(None))
        finally:
            if saved is None:
                os.environ.pop(M.MANIFEST_DIR_ENV, None)
            else:
                os.environ[M.MANIFEST_DIR_ENV] = saved


class TypeEnforcementClassification(unittest.TestCase):
    """*** A COMPILE FAILURE IS A KILL ONLY WHEN THE PROPERTY IS TYPE ENFORCEMENT. ***"""

    def _entry(self, **kw):
        e = {"id": "x", "witness": "the_named_witness", "file": "f", "find": "a", "replace": "b"}
        e.update(kw)
        return e

    def test_a_type_enforced_rod_is_killed_by_the_compiler(self):
        verdict, note = M._classify(self._entry(type_enforced=True), 1, None, set(), True, 1)
        self.assertEqual("KILLED", verdict)
        self.assertIn("TYPE ENFORCEMENT", note)

    def test_any_other_compile_failure_is_build_invalid(self):
        verdict, _ = M._classify(self._entry(), 1, None, set(), True, 1)
        self.assertEqual("BUILD_INVALID", verdict)


class SelftestRodVacuityGuard(unittest.TestCase):
    """*** A SELFTEST ROD WHOSE MUTANT DOES NOT PARSE MUST NOT BE A KILL. ***

    *MEASURED, FROM A REAL DEFECT: a rod whose `find` was truncated to one line of a
    two-line statement produced an `IndentationError` -- the control exited non-zero
    because the FILE was broken, not because a mutation ESCAPED its guard, and the
    rod was booked KILLED. The mutated control is compiled first; a parse failure is
    BUILD_INVALID, never a catch.*
    """

    def _entry(self, control):
        return {"id": "x", "platform": "selftest", "control": control, "selftest_flag": "--selftest",
                "witness": "w", "file": "f", "find": "a", "replace": "b"}

    def test_a_parsing_mutant_that_escapes_is_a_clean_nonzero_rc(self):
        with tempfile.TemporaryDirectory() as td:
            # the per-case table shape: `<label>. <name> expect=… got=… ESCAPED`
            open(os.path.join(td, "ok.py"), "w").write(
                "import sys\nprint('7a. a skip wearing the exemption  expect=red got=green ESCAPED')\nsys.exit(1)\n")
            entry = dict(self._entry("ok.py"), expect_escaped=["7a"])
            r = M._run_harness(entry, td)
            self.assertEqual(0, r["build_exit"])
            self.assertEqual({"w"}, r["failed"])

    def test_an_unattributed_nonzero_rc_is_not_a_kill(self):
        """*** A CONTROL THAT REDDENED WITHOUT NAMING THE INTENDED FIXTURE IS NOT A KILL. ***"""
        with tempfile.TemporaryDirectory() as td:
            open(os.path.join(td, "drift.py"), "w").write(
                "import sys\nprint('8. the real log  expect=green got=red ESCAPED')\nsys.exit(1)\n")
            entry = dict(self._entry("drift.py"), expect_escaped=["7a"])
            r = M._run_harness(entry, td)
            self.assertEqual(set(), r["failed"], "an unattributed failure was booked as a kill")

    def test_a_mutant_that_does_not_parse_is_build_invalid(self):
        with tempfile.TemporaryDirectory() as td:
            open(os.path.join(td, "bad.py"), "w").write("if True:\n    pass\n     pass\n")
            r = M._run_harness(self._entry("bad.py"), td)
            self.assertEqual(1, r["build_exit"])
            verdict, _ = M._classify(self._entry("bad.py"), r["build_exit"], r["run"],
                                     r["failed"], True, 1, r["skipped"], {"ok": True})
            self.assertEqual("BUILD_INVALID", verdict)


class StructuralVsSemanticSeparation(unittest.TestCase):
    """*** A GUARD-ONLY ROD IS STRUCTURAL AND MUST NOT COUNT AS A SEMANTIC KILL. ***

    *User sections 8/37: a source-shape/wiring assertion is NOT a behavioural kill.
    A `guard_only` rod's row carrieth category="structural", and the validator keeps
    the two populations strictly apart.*
    """

    def test_a_guard_only_row_is_recorded_structural(self):
        entry = {"id": "g", "witness": "w", "file": "f", "find": "a", "replace": "b",
                 "patch_sha": "0" * 64, "guard_only": True}
        row = M._row(entry, "sha", "semantic", 1, 0, ["w"], 1, "KILLED", None, None,
                     structural=True)
        self.assertEqual("structural", row["category"])

    def test_a_normal_row_stays_semantic(self):
        entry = {"id": "s", "witness": "w", "file": "f", "find": "a", "replace": "b",
                 "patch_sha": "0" * 64}
        row = M._row(entry, "sha", "semantic", 1, 0, ["w"], 1, "KILLED", None, None)
        self.assertEqual("semantic", row["category"])

    def test_the_runner_guard_rod_is_a_required_structural_guard(self):
        rod = [r for r in M.SEMANTIC if r["id"].startswith("LANE-ROD-6")][0]
        self.assertTrue(rod.get("guard_only"))
        self.assertIn(rod["id"], M.BOARD1_REQUIRED_IDS,
                      "the invoked runner guard is a REQUIRED control")
        self.assertEqual(["structural"], rod.get("category_expect"))
        self.assertTrue(rod.get("guard_command"), "and it must be an INVOKED guard, not a grep")


class ShellRodGuardWitness(unittest.TestCase):
    """*** THE SHELL WITNESS INVOKES A GUARD ASSERION, NEVER A BARE SOURCE GREP-AS-PASS. ***

    *The rod's `guard_command` must exit non-zero on the MUTANT (the guard is gone)
    and zero on the BASELINE. A rod with no `guard_command` makes no semantic claim.*
    """

    def test_a_guard_only_rod_has_an_invoked_guard_command(self):
        rod = [r for r in M.SEMANTIC if r["id"].startswith("LANE-ROD-6")][0]
        self.assertTrue(rod.get("guard_command"), "the runner rod must name an invoked guard")

    def test_the_guard_reddens_on_the_mutant_and_passes_on_the_baseline(self):
        import shutil
        import tempfile
        rod = [r for r in M.SEMANTIC if r["id"].startswith("LANE-ROD-6")][0]
        base = ROOT / rod["script"]
        with tempfile.TemporaryDirectory() as td:
            # the whole tests dir is shimmed so the INVOKED fixture resolves
            shutil.copytree(ROOT / "tools" / "readiness" / "tests", Path(td) / "tools" / "readiness" / "tests")
            shim = Path(td) / rod["script"]
            shim.parent.mkdir(parents=True, exist_ok=True)
            shim.write_text(base.read_text(encoding="utf-8"), encoding="utf-8")
            self.assertEqual(set(), M._run_harness(rod, td)["failed"])
            shim.write_text(base.read_text(encoding="utf-8").replace(
                rod["find"], rod["replace"], 1), encoding="utf-8")
            self.assertEqual({rod["witness"]}, M._run_harness(rod, td)["failed"])


class LaneLabelScoping(unittest.TestCase):
    """*** EACH LANE ROD RUNS EXACTLY ONE FAMILY, SO ITS LABEL IS READ AGAINST THAT
    FAMILY ALONE (foundation/simulator/ui each carry their own `7a`/`10`/`7d`). ***"""

    def test_each_lane_rod_names_one_selftest_flag_and_its_own_label(self):
        lane = [r for r in M.SEMANTIC if r["id"].startswith("LANE-ROD")
                and r.get("expect_escaped")]
        self.assertEqual(5, len(lane), "the five behavioural lane rods")
        for rod in lane:
            flags = [str(rod.get("selftest_flag") or "")]
            self.assertEqual(1, len(flags), rod["id"])
            self.assertTrue(rod["selftest_flag"].startswith("--selftest"), rod["id"])
            self.assertTrue(rod["expect_escaped"], rod["id"])
            # the label belongs to the family the flag selects
            fam = rod["selftest_flag"].replace("--selftest", "").strip("-") or "android"
            self.assertTrue(fam in ("foundation", "simulator", "ui", "android"), rod["id"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
