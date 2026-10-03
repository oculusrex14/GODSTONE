#!/usr/bin/env python3
"""*** THE BOARD 1 GATE MANIFEST CONTRACT: ITS REFUSALS, PROVEN AGAINST REAL BYTES. ***

*These are the witnesses for `ci/check_board1_manifest.py` and the manifest binding added to
`tools/readiness/board1.py`. Every case builds a REAL throwaway git repository (an actual annotated tag, actual
artifact files, an actual campaign envelope over the copy's own ledger) and asserts an OBSERVED refusal -- so a
control that quietly stopped reading git, the digests or the populations would be caught here.*

**AN EMPTY LIST IS NOT A PASS, AND A CHECK THAT REFUSED EVERYTHING IS NOT A CONTROL EITHER:** the positive cases
assert that the same construction is ACCEPTED, with every claim re-derived. Deterministic, no network, no sleeps.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
for _extra in (REPO / "ci", REPO / "tools" / "readiness"):
    if str(_extra) not in sys.path:
        sys.path.insert(0, str(_extra))

import check_board1_manifest as cbm  # noqa: E402
import check_candidate_binding as ccb  # noqa: E402
import board1  # noqa: E402


class _ManifestFixture:
    """A real, minimal candidate repository: one commit, one annotated tag, one pushed origin."""

    def __init__(self, root: Path, *, status: str = "READY_FOR_EXTERNAL_REAUDIT"):
        self.root = root
        self.repo = root / "repo"
        self.origin = root / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", str(self.origin)], check=True)
        self.repo.mkdir()
        self._git("init", "-q", "-b", "main")
        self._git("config", "user.email", "court@example.invalid")
        self._git("config", "user.name", "court")
        (self.repo / "docs/remediation/evidence/board1-rc11-rods/logs").mkdir(parents=True)
        (self.repo / "docs/production-readiness").mkdir(parents=True, exist_ok=True)
        (self.repo / "src").mkdir(exist_ok=True)
        (self.repo / "src/prod.swift").write_text("let x = 1\n", encoding="utf-8")
        shutil.copyfile(cbm.CLOSURE, self.repo / "docs/production-readiness/BOARD1_CLOSURE.json")
        shutil.copyfile(cbm.LEDGER, self.repo / "docs/remediation/REMEDIATION_STATE.json")
        (self.repo / "scripts").mkdir(exist_ok=True)
        shutil.copyfile(REPO / "scripts" / "build_structured_closure.py",
                        self.repo / "scripts" / "build_structured_closure.py")
        (self.repo / "ci").mkdir(exist_ok=True)
        cbm.copy_rod_ledger(self.repo)
        # *** THE COPIED LEDGER IS MADE INTERNALLY CONSISTENT BY THE COPY'S OWN GENERATOR. *** *The real derivation
        # still runs; the obligations are emptied in the COPY and the persisted counts are regenerated through it, so
        # the fixture is exactly the state `--write` produceth and nothing is asserted that was not derived.*
        cbm.normalize_fixture_ledger(self.repo, status=status)
        # *** THE FIXTURE REGISTERS ITS LANE DERIVATIONS; PRODUCTION REGISTERS NOTHING. ***
        cbm.register_lane_overrides(self.repo, digest=lambda _l: "d" * 64,
                                    check=lambda _l: ([], {"tests": 3, "skipped": 0, "failures": 0,
                                                           "errors": 0}),
                                    roster=lambda _l: 3)
        # *The lane artifacts and the campaign tree are written BEFORE the candidate commit, so the fixture's working
        # tree is CLEAN exactly as a real candidate's is -- an untracked artifact would now be (correctly) refused.*
        cbm._fixture_lanes(self.repo)
        cbm._fixture_campaign(self.repo)
        # *ONE candidate commit: every fixture artifact (lane sidecars, campaign tree, external register) is committed
        # with the sources, so the working tree stays clean exactly as a real candidate's does.*
        # *ONE candidate commit carrying the committed evidence (lane sidecars, external register).*
        (self.repo / "docs/production-readiness/EXTERNAL_BLOCKERS.json").write_text(
            json.dumps({"blockers": [{"id": "A06", "status": "BLOCKED_EXTERNAL"}]}), encoding="utf-8")
        self._git("add", "-A")
        self._git("commit", "-q", "-m", "candidate")
        # *** THE CAMPAIGN LIVES OUTSIDE THE TREE, AS IT DOES FOR THE REAL TERMINAL JOB. *** *A commit cannot name its
        # own sha, so the envelope is written to a scratch root AFTER the candidate exists and stamped with it.*
        self._stamp_campaign_baseline()
        self._git("tag", "-a", "board1-court-rc", "-m", "the court candidate")
        self._git("remote", "add", "origin", str(self.origin))
        self._git("push", "-q", "origin", "main")
        self._git("push", "-q", "origin", "board1-court-rc")
        # *** AND THE FIXTURE'S OWN IMMUTABLE ANCHOR, IN THE rc14 SHAPE. *** *The real rc14 objects live only in the
        # real repository; the court carries its OWN anchor -- a real child commit holding a real blob -- so
        # `anchor_facts` derives every identity from the fixture's git objects and the anchor clause is exercised by
        # real derivation, not stubbed out.*
        cbm.register_anchor_specs(self.repo, cbm._fixture_anchor_spec(self.repo))
        self._external = cbm._fixture_external(self.repo)
        self._campaign = cbm.campaign_facts(self.campaign_dir, self.repo)
        self.sha = self._git("rev-parse", "HEAD").stdout.strip()
        self.tree = self._git("rev-parse", "HEAD^{tree}").stdout.strip()
        self.gates = root / "gates"
        # *The terminal job writes the manifest to its scratch root, NOT into the candidate tree.*
        self.manifest_path = root / "board1-gate-manifest.json"

    def _stamp_campaign_baseline(self) -> None:
        """Write the campaign envelope to the SCRATCH root, stamped with the candidate commit and tree."""
        cdir = cbm._fixture_campaign_dir(self.repo)
        cbm._fixture_campaign(self.repo)
        env_path = cdir / "manifest.json"
        env = json.loads(env_path.read_text(encoding="utf-8"))
        head = self._git("rev-parse", "HEAD").stdout.strip()
        tree = self._git("rev-parse", "HEAD^{tree}").stdout.strip()
        env["baseline_sha"] = head
        env["tested_tree_sha"] = tree
        for row in env.get("rows") or []:
            row["baseline_sha"] = head
            row["tested_tree_sha"] = tree
        env_path.write_text(json.dumps(env, indent=1) + "\n", encoding="utf-8")
        self.campaign_dir = cdir

    def _git(self, *args) -> subprocess.CompletedProcess:
        return subprocess.run(["git", "-C", str(self.repo), *args],
                              capture_output=True, text=True, check=False)

    def gate_rows(self) -> list[dict]:
        facts = cbm._selftest_gate_facts(self.gates)
        return [{"id": f["id"], "label": f["label"], "argv": f["argv"], "rc": f["rc"],
                 "log": cbm.artifact_record(Path(f["log_path"]), self.repo), "verdict": "PASS"}
                for f in facts]

    def dirt(self, *, clean: bool = True) -> dict:
        """A dirt report in the shape `cbm.dirt_report` produceth (timestamps, tracked/untracked/all).

        *The pre-gate block also carrieth the EXECUTING head/tree, because the validator requires the gates to have
        run at the candidate's own revision -- so the court's snapshot carries them too.*
        """
        paths = [] if clean else ["src/prod.swift"]
        return {"tracked": paths, "untracked": [], "all": paths, "allow": [], "status_error": None,
                "measured_utc": cbm._now_utc(), "ok": clean,
                "head_sha": self.sha, "head_tree": self.tree}

    def snapshot(self) -> dict:
        """A pre-gate snapshot in the shape `cbm.pre_gate_snapshot` produceth."""
        return {"before": self.dirt(), "taken": "before-gates"}

    def document(self) -> dict:
        return cbm.build_manifest(
            gate_facts=self.gate_rows(), base=self.repo,
            candidate={"tag": "board1-court-rc", "sha": self.sha, "tree_sha": self.tree,
                       "sha_source": "tag", "tag_state": "annotated"},
            campaign=self._campaign, lanes=cbm._fixture_lanes(self.repo),
            closure=cbm._fixture_closure(self.repo), external=self._external,
            clean_start=self.dirt(), clean_end=self.dirt(),
            campaign_dir_override=self.campaign_dir)

    def check(self, doc: dict, **kw) -> list[str]:
        """Validate with the fixture's REGISTERED derivations -- the real validators, over fixture inputs."""
        kw.setdefault("ledger_ids_fn", lambda: cbm.default_ledger_ids(self.repo))
        kw.setdefault("tested_inputs_fn",
                      lambda: cbm._import_ci("mutations", self.repo)._tested_input_digests())
        return cbm.check_manifest(doc, base=self.repo, **kw)

    def write(self, doc: dict) -> Path:
        cbm._write_atomic(self.manifest_path, json.dumps(doc, indent=1) + "\n")
        return self.manifest_path


class ManifestContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._td = tempfile.TemporaryDirectory()
        cls.fx = _ManifestFixture(Path(cls._td.name))
        cls.doc = cls.fx.document()

    @classmethod
    def tearDownClass(cls):
        cls._td.cleanup()

    # ------------------------------------------------------------------ positives
    def test_the_constructed_manifest_is_accepted_and_revalidates_identically(self):
        """The same construction the refusals mutate must be ACCEPTED, twice, with no side effect."""
        self.assertEqual(self.fx.check(self.doc), [])
        self.assertEqual(self.fx.check(self.doc), [])

    def test_the_recorded_argv_is_the_canonical_argv_for_every_required_gate(self):
        """Every gate row carrieth an argv the contract ACCEPTS for that gate's id.

        *** THE ARGV IS JUDGED BY THE CONTRACT'S OWN SEMANTIC COMPARISON, NOT BY LITERAL EQUALITY. *** *The input
        tokens (`{proof_dir}`, `{campaign_dir}`, …) are RESOLVED to the absolute paths the run actually used, which is
        the contract's own rule (`argv_problems` alloweth a resolved input but refuseth an unresolved or non-absolute
        one); a byte-equality check would instead demand the literal tokens and read a correct run as a mismatch.* **So
        the exact id ORDER is asserted and each argv is put through `argv_problems` -- the same reader the validator
        useth, which refuses a wrong, renamed or unresolved command.***
        """
        rows = self.doc["gates"]["rows"]
        self.assertEqual([r["id"] for r in rows], list(cbm.REQUIRED_GATE_IDS))
        for row in rows:
            spec = next(g for g in cbm.GATE_DEFINITIONS if g["id"] == row["id"])
            self.assertEqual(cbm.argv_problems(row["argv"], spec), [],
                             f"gate {row['id']} argv is not the canonical command: {row['argv']!r}")

    # ------------------------------------------------------------------ gate accounting
    def test_a_gate_recording_a_different_argv_is_refused(self):
        """*** THE COMMAND IS PART OF THE GATE. *** *A gate row that ran some OTHER command proves nothing about the
        contract's gate, and `argv` is exactly what a reader re-runs.*"""
        bad = json.loads(json.dumps(self.doc))
        bad["gates"]["rows"][1]["argv"] = [sys.executable, "-c", "pass"]
        self.assertTrue(any("an unaccounted command is not this contract's gate" in p
                            for p in self.fx.check(bad)))

    def test_a_gate_population_that_disagrees_with_the_contract_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["gates"]["required_ids"] = bad["gates"]["required_ids"][:-1]
        self.assertTrue(any("gates.required_ids" in p for p in self.fx.check(bad)))

    def test_a_manifest_omitting_a_required_gate_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["gates"]["rows"] = [r for r in bad["gates"]["rows"] if r["id"] != "lane-results"]
        self.assertTrue(any("omits required gate(s): ['lane-results']" in p
                            for p in self.fx.check(bad)))

    def test_a_gate_that_returned_nonzero_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["gates"]["rows"][2]["rc"] = 1
        self.assertTrue(any("EVERY required gate returned zero" in p
                            for p in self.fx.check(bad)))

    def test_a_gate_log_edited_after_binding_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        log = self.fx.repo / bad["gates"]["rows"][0]["log"]["path"]
        original = log.read_bytes()
        try:
            log.write_bytes(original + b"EDITED AFTER BINDING\n")
            self.assertTrue(any("was EDITED after the manifest bound it" in p
                                for p in self.fx.check(bad)))
        finally:
            log.write_bytes(original)

    def test_the_builder_refuses_to_emit_from_an_incomplete_gate_run(self):
        """*** A PARTIAL RUN MAY NOT EMIT A MANIFEST AT ALL. *** *The builder is the only door to a PASS document.*"""
        facts = cbm._selftest_gate_facts(self.fx.root / "gates-incomplete",
                                         drop={"readiness-suites"})
        gate_facts = []
        for f in facts:
            log = Path(f["log_path"])
            gate_facts.append({"id": f["id"], "label": f["label"], "argv": f["argv"], "rc": f["rc"],
                               "log": cbm.artifact_record(log, self.fx.repo) if log.is_file() else None,
                               "verdict": "MISSING" if f["id"] == "readiness-suites" else "PASS"})
        with self.assertRaises(cbm.ManifestRefused) as ctx:
            cbm.build_manifest(gate_facts=gate_facts, base=self.fx.repo,
                               candidate={"tag": "board1-court-rc", "sha": self.fx.sha,
                                          "tree_sha": self.fx.tree},
                               campaign=cbm._fixture_campaign(self.fx.repo),
                               lanes=cbm._fixture_lanes(self.fx.repo),
                               closure=cbm._fixture_closure(self.fx.repo),
                               external=cbm._fixture_external(self.fx.repo),
                               clean_start={"ok": True, "dirty_tracked": []},
                               clean_end={"ok": True, "dirty_tracked": []})
        self.assertTrue(any("NO artifact at all" in p for p in ctx.exception.problems))

    def test_the_builder_refuses_to_emit_after_a_nonzero_gate(self):
        facts = cbm._selftest_gate_facts(self.fx.root / "gates-red",
                                         rc_override={"evidence-digests": 1})
        gate_facts = [{"id": f["id"], "label": f["label"], "argv": f["argv"], "rc": f["rc"],
                       "log": cbm.artifact_record(Path(f["log_path"]), self.fx.repo),
                       "verdict": "PASS" if f["rc"] == 0 else "FAIL"} for f in facts]
        with self.assertRaises(cbm.ManifestRefused) as ctx:
            cbm.build_manifest(gate_facts=gate_facts, base=self.fx.repo,
                               candidate={"tag": "board1-court-rc", "sha": self.fx.sha,
                                          "tree_sha": self.fx.tree},
                               campaign=cbm._fixture_campaign(self.fx.repo),
                               lanes=cbm._fixture_lanes(self.fx.repo),
                               closure=cbm._fixture_closure(self.fx.repo),
                               external=cbm._fixture_external(self.fx.repo),
                               clean_start={"ok": True, "dirty_tracked": []},
                               clean_end={"ok": True, "dirty_tracked": []})
        self.assertTrue(any("NON-ZERO" in p for p in ctx.exception.problems))

    # ------------------------------------------------------------------ candidate binding
    def test_a_manifest_with_no_candidate_sha_or_tree_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["candidate"] = {"tag": None, "sha": None, "tree_sha": None}
        problems = self.fx.check(bad)
        self.assertTrue(any("is not a full 40-hex commit" in p for p in problems))
        self.assertTrue(any("is not a full 40-hex tree" in p for p in problems))

    def test_a_dirty_start_or_end_is_refused(self):
        """*** A CLEAN GIT STATUS IS REQUIRED AT BOTH ENDS, AND UNTRACKED PATHS MAKE IT UNCLEAN. ***

        *THE MEASURED ESCAPE: the case set `ok=False` AND a non-empty itemized inventory, so the inventory legs
        refused the document even when the summary guard was disabled -- the mutant survived a witness it had already
        satisfied for another reason. **So the `ok=False` leg now carrieth an EMPTY inventory, leaving only the summary
        to speak: with the summary guard struck the document is ACCEPTED (the consumer-visible false green), so the
        `ok=False` case asserts a refusal and no prose. The itemized legs stay as separate behavioural cases, each
        asserting its own refusal.***
        """
        for label in ("clean_start", "clean_end"):
            bad = json.loads(json.dumps(self.doc))
            bad[label] = {**self.doc[label], "ok": False, "tracked": [], "untracked": [], "all": []}
            self.assertTrue(self.fx.check(bad),
                            f"{label} with ok=False and no itemized path must be refused; the mutant accepts it")
            bad = json.loads(json.dumps(self.doc))
            bad[label] = {**self.doc[label], "ok": False, "tracked": ["src/prod.swift"],
                          "untracked": [], "all": ["src/prod.swift"]}
            self.assertTrue(self.fx.check(bad),
                            f"{label} carrieth an uncommitted TRACKED change and must be refused")
            bad = json.loads(json.dumps(self.doc))
            bad[label] = {**self.doc[label], "ok": False, "tracked": [], "untracked": ["scratch/"],
                          "all": ["scratch/"]}
            self.assertTrue(self.fx.check(bad),
                            f"{label} carrieth an UNTRACKED path and must be refused")

    def test_a_lightweight_candidate_tag_is_refused(self):
        self.fx._git("tag", "board1-court-light", "-f", self.fx.sha)
        bad = json.loads(json.dumps(self.doc))
        bad["candidate"]["tag"] = "board1-court-light"
        self.assertTrue(any("is LIGHTWEIGHT" in p for p in self.fx.check(bad)))

    # ------------------------------------------------------------------ campaign
    def test_a_campaign_population_that_disagrees_with_the_ledger_is_refused(self):
        """*** THE POPULATION COMES FROM THE LEDGER, NOT FROM THE MANIFEST'S OWN CLAIM. ***

        *THE MEASURED ESCAPE: the case sliced `required_ids`, but the ledger-source equality guard already refuseth
        that state -- so the `omitted` guard this mutation disables was never the reason the case passed, and the
        witness stayed green under the mutant. **So the case now gives the manifest's OWN recorded SELECTION as EMPTY
        while the envelope still selected every required rod: the selection-minus-required delta is the ONLY
        disagreement the `omitted` guard sees, so with the guard struck the document is ACCEPTED -- the consumer-visible
        false green -- and the witness condemneth it. The assertion is the refusal itself, never its prose.***
        """
        bad = json.loads(json.dumps(self.doc))
        bad["campaign"]["population"]["selected_ids"] = []
        bad["campaign"]["population"]["row_count"] = 0
        self.assertTrue(self.fx.check(bad),
                        "a manifest whose recorded selection is EMPTY while the envelope selected every required rod "
                        "must be refused; the mutant accepts it")

    def test_a_campaign_missing_a_required_row_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["campaign"]["population"]["missing_rows"] = [cbm.REQUIRED_ROD_SAMPLE[1]]
        self.assertTrue(any("carrieth NO row for selected id(s)" in p
                            for p in self.fx.check(bad)))

    def test_a_rod_that_escaped_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["campaign"]["population"]["rows_by_id"][cbm.REQUIRED_ROD_SAMPLE[0]] = "ESCAPED"
        bad["campaign"]["all_killed"] = False
        self.assertTrue(any("required rod(s) not KILLED" in p
                            for p in self.fx.check(bad)))

    def test_a_campaign_whose_tested_input_moved_is_refused(self):
        """*** THE CAMPAIGN MUST HAVE RUN AGAINST THESE BYTES. ***"""
        bad = json.loads(json.dumps(self.doc))
        moved = dict(bad["campaign"]["tested_inputs"])
        moved["ci/mutations.py"] = "1" * 64
        bad["campaign"]["tested_inputs"] = moved
        self.assertTrue(any("has MOVED since the campaign" in p
                            for p in self.fx.check(bad)))

    def test_a_campaign_phase_log_edited_after_binding_is_refused(self):
        doc = self.fx.document()
        log = self.fx.campaign_dir / "logs" / f"{cbm.REQUIRED_ROD_SAMPLE[0]}.mutant.log"
        original = log.read_bytes()
        try:
            log.write_bytes(b"EDITED AFTER BINDING\n")
            self.assertTrue(any("campaign directory digest does not recompute" in p
                                for p in self.fx.check(doc)))
        finally:
            log.write_bytes(original)

    def test_an_absent_campaign_manifest_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        path = self.fx.repo / bad["campaign"]["manifest_path"]
        original = path.read_bytes()
        try:
            path.unlink()
            self.assertTrue(any("is NOT PRESENT" in p
                                for p in self.fx.check(bad)))
        finally:
            path.write_bytes(original)
        cbm._fixture_campaign(self.fx.repo)

    # ------------------------------------------------------------------ lanes
    def test_a_stale_lane_source_digest_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["lanes"][0]["digest"] = "0" * 64
        self.assertTrue(any("THE LANE IS STALE" in p
                            for p in cbm.check_manifest(bad,
                                                        lane_digest_fn=lambda _l: "d" * 64)))

    def test_a_lane_whose_pre_and_post_digests_disagree_is_refused(self):
        """*** AN INPUT THAT MOVED WHILE THE LANE RAN MAKES ITS ARTIFACTS EVIDENCE ABOUT NO REVISION. ***"""
        doc = self.fx.document()
        pre = cbm.LANE_SOURCES[cbm.REQUIRED_LANES[0]]["sidecars"][0]
        path = self.fx.repo / pre
        original = path.read_bytes()
        try:
            # *The PRE sidecar is rewritten while the POST one keeps the manifest's digest -- so the pair disagrees.
            # Writing only the pre sidecar keeps every other lane check satisfied, isolating this refusal.*
            path.write_bytes(b"a" * 64 + b"\n")
            self.assertTrue(any("does not match POST-RUN" in p for p in self.fx.check(doc)))
        finally:
            path.write_bytes(original)

    def test_a_manifest_omitting_a_required_lane_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["lanes"] = [l for l in bad["lanes"] if l["id"] != "ios:simulator"]
        self.assertTrue(any("omits required lane(s): ['ios:simulator']" in p
                            for p in self.fx.check(bad)))

    def test_a_lane_absent_from_the_artifact_but_unidentified_is_refused(self):
        doc = self.fx.document()
        art = self.fx.repo / doc["lanes"][0]["artifacts"][0]["path"]
        original = art.read_bytes()
        try:
            art.unlink()
            self.assertTrue(any("names NO hosted artifact" in p
                                for p in cbm.check_manifest(doc,
                                                            lane_digest_fn=lambda _l: "d" * 64)))
        finally:
            art.write_bytes(original)
        cbm._fixture_lanes(self.fx.repo)

    def test_a_lane_that_goes_red_on_recheck_is_refused(self):
        self.assertTrue(any("(re-checked): a required arm did not execute" in p
                            for p in cbm.check_manifest(
                                self.fx.document(),
                                lane_digest_fn=lambda _l: "d" * 64,
                                lane_problems_fn=lambda _l: ["a required arm did not execute"])))

    # ------------------------------------------------------------------ closure / ledger
    def test_a_closure_record_edited_after_binding_is_refused(self):
        doc = self.fx.document()
        path = self.fx.repo / "docs/production-readiness/BOARD1_CLOSURE.json"
        original = path.read_bytes()
        try:
            path.write_bytes(original + b" ")
            self.assertTrue(any("does not match the digest the manifest bound" in p
                                for p in cbm.check_manifest(doc,
                                                            lane_digest_fn=lambda _l: "d" * 64)))
        finally:
            path.write_bytes(original)

    def test_a_manifest_whose_structured_counts_drift_from_the_ledger_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        drifted = dict(bad["derived_counts"])
        drifted["internal_obligations_open"] = drifted.get("internal_obligations_open", 0) + 3
        bad["derived_counts"] = drifted
        self.assertTrue(any("structured counts DISAGREE" in p
                            for p in self.fx.check(bad)))

    def test_a_builder_written_verified_fixed_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["closure"]["verified_fixed"] = 1
        bad["closure"]["record"] = cbm.artifact_record(
            self.fx.repo / "docs/production-readiness/BOARD1_CLOSURE.json", self.fx.repo)
        self.assertTrue(any("only an INDEPENDENT auditor may write it" in p
                            for p in self.fx.check(bad)))

    # ------------------------------------------------------------------ external evidence
    def test_an_edited_external_register_is_refused(self):
        """*** THE REGISTER'S DIGEST IS RE-DERIVED, SO AN EDIT TO THE BLOCKERS FILE IS CAUGHT. ***

        *The refusal nameth the file, and the mutation is confined to the blockers register `_fixture_external`
        recorded -- the anchors and historical rows are untouched, so the case refuses for the register and nothing
        else.*
        """
        doc = self.fx.document()
        path = self.fx.repo / "docs/production-readiness/EXTERNAL_BLOCKERS.json"
        original = path.read_bytes()
        try:
            path.write_bytes(b"{}\n")
            self.assertTrue(any("docs/production-readiness/EXTERNAL_BLOCKERS.json does not match the digest" in p
                                for p in self.fx.check(doc)))
        finally:
            path.write_bytes(original)
            self._external = cbm._fixture_external(self.fx.repo)

    def test_an_absent_historical_evidence_identity_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["external_evidence"]["historical"] = [
            {"path": "docs/remediation/evidence/GONE.json", "missing": True}]
        self.assertTrue(any("is MISSING" in p for p in self.fx.check(bad)))

    def test_a_re_pointed_anchor_tag_is_refused(self):
        """*** THE ANCHOR IS THE GIT OBJECT, NOT A RE-HASH OF A WORKING FILE. ***

        *A manifest that recordeth a tag object the repository no longer carrieth -- the exact shape of a re-pointed or
        re-created tag -- is refused, even though the file's own bytes are untouched.*
        """
        bad = json.loads(json.dumps(self.doc))
        bad["external_evidence"]["anchors"]["anchors"][0]["tag_object"] = "0" * 40
        self.assertTrue(any("tag_object" in p for p in self.fx.check(bad)))

    def test_a_rewritten_anchor_blob_is_refused(self):
        """*** A REWRITTEN ANCHORED ARTIFACT IS CAUGHT BY THE BLOB, NOT BY A FILE DIGEST. ***"""
        bad = json.loads(json.dumps(self.doc))
        bad["external_evidence"]["anchors"]["anchors"][0]["blob_sha"] = "0" * 40
        self.assertTrue(any("blob_sha" in p for p in self.fx.check(bad)))

    def test_a_manifest_binding_no_immutable_anchor_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["external_evidence"]["anchors"] = {}
        self.assertTrue(any("NO immutable-anchor block" in p for p in self.fx.check(bad)))

    def test_a_gate_run_from_another_checkout_is_refused(self):
        """*** THE MANIFEST MAY NOT BIND A CANDIDATE THE GATES DID NOT EXECUTE. ***

        *`clean_start` is the pre-gate snapshot; a manifest whose executing HEAD differs from the candidate it binds
        -- or whose revision nobody recorded -- is refused, because a gate run from another checkout proves nothing
        about this candidate.*
        """
        bad = json.loads(json.dumps(self.doc))
        bad["clean_start"] = {**bad["clean_start"], "head_sha": "0" * 40}
        self.assertTrue(any("gates executed at HEAD" in p for p in self.fx.check(bad)))
        bad = json.loads(json.dumps(self.doc))
        bad["clean_start"] = {**bad["clean_start"], "head_sha": None}
        self.assertTrue(any("NO executing HEAD" in p for p in self.fx.check(bad)))


    def test_the_release_proof_is_mandatory_law_not_a_caller_boolean(self):
        """*** THE EXACT-CANDIDATE RELEASE PROOF IS MANDATORY AT EVERY ADMISSION -- THERE IS NO `required` KNOB. ***

        *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: a `release_evidence_required=False` default (and a `required`
        boolean) let a proof-less manifest stand as a weak Phase-3 shape. **So an absent or empty release population is
        refused with NO argument at all -- and the fixture's GENUINE captured proof (produced through the owner's
        `capture()` over the raw-GH transport seam) is ACCEPTED by the same default admission.***
        """
        # *The positive control: the fixture's real, hosted-authenticated proof passes the mandatory admission.*
        self.assertEqual(self.fx.check(self.doc), [])
        # *An ABSENT block and an EMPTY population are each refused by name, with no boolean to weaken the law.*
        gone = json.loads(json.dumps(self.doc))
        gone["external_evidence"] = {k: v for k, v in gone["external_evidence"].items()
                                     if k != "release_proof"}
        self.assertTrue(any("release evidence is REQUIRED" in p for p in self.fx.check(gone)), "an absent block passed")
        empty = json.loads(json.dumps(self.doc))
        empty["external_evidence"]["release_proof"] = {
            **empty["external_evidence"]["release_proof"], "records": []}
        self.assertTrue(any("no record is bound" in p for p in self.fx.check(empty)), "an empty block passed")

    def test_a_release_proof_bound_to_another_candidate_is_refused(self):
        bad = json.loads(json.dumps(self.doc))
        bad["external_evidence"]["release_proof"] = {
            "interface": cbm.RELEASE_PROOF_INTERFACE, "available": False, "required": False,
            "records": [{"record": {"path": "docs/remediation/evidence/board1-release-proof/1-2.json",
                                    "sha256": "0" * 64, "bytes": 1},
                         "document_sha256": "0" * 64,
                         "candidate": {"sha": "f" * 40, "tag": "board1-court-rc"},
                         "run_id": "1", "run_attempt": 2, "problems": []}],
            "problems": []}
        self.assertTrue(any("not the candidate" in p
                            for p in self.fx.check(bad)))


class AttestationBindingTests(unittest.TestCase):
    """*** THE ATTESTATION BINDS THE GATE MANIFEST, AND THE READ-ONLY ROAD RE-DERIVES IT. ***"""

    @classmethod
    def setUpClass(cls):
        cls._td = tempfile.TemporaryDirectory()
        cls.fx = _ManifestFixture(Path(cls._td.name))
        cls._saved = (board1.ROOT, ccb.ROOT, ccb._run_facts, ccb._job_annotations)
        board1.ROOT = cls.fx.repo
        ccb.ROOT = cls.fx.repo
        green = {"head_sha": cls.fx.sha, "conclusion": "success", "status": "completed",
                 "event": "push", "workflow": "repository-verification",
                 "repository": "o/r", "head_branch": "main",
                 "path": ".github/workflows/repository-verification.yml",
                 "jobs": [{"id": 100 + i, "name": n, "conclusion": "success"}
                          for i, n in enumerate(ccb.CANONICAL_JOB_NAMES)]}
        ccb._run_facts = lambda run_id, attempt=None, **kw: {**green, "run_attempt": attempt}
        ccb._job_annotations = lambda job_id: []
        # *** THE HOSTED RELEASE-PROOF TRANSPORT IS THE MANIFEST FIXTURE'S OWN RAW-GH SEAM. ***
        # *`authenticate_release_proof` RE-CAPTURES the claimed run through `capture_release_proof.capture`. The
        # manifest fixture already installs a real raw-GH transport (`_fixture_release_seam`) serving the five
        # release-gates jobs and the required artifact population for THIS candidate -- so this class uses the SAME
        # genuine proof and seam rather than a second, divergent one. The REAL capture, REAL authenticator and REAL
        # digest compare all run; only the transport bytes are supplied -- never a bool and never a mocked auth.*
        #
        # *** THE ATTESTATION PATH IS THE ONE CANONICAL FUTURE PATH, AND THE PROOF LIVES OUTSIDE THE CANDIDATE TREE. ***
        cls.att = cls.fx.repo / ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH
        cls._bind_manifest_transport()
        # *** THE TRUSTED REPO IS THE CANONICAL ORIGIN; THE COURT NAMES ITS FIXTURE SLUG. ***
        cls._saved_release_repo = cbm._release_repo
        cbm._release_repo = lambda: "o/r"
        # *The shared reader derives its trusted repo from the origin; the fixture repo carries no GitHub origin, so the
        # court names the same fixture slug here too.*
        cls._saved_ccb_repository = ccb._repository
        ccb._repository = lambda: "o/r"
        # *The fixture's genuine captured proof root, produced over the raw-GH seam with the "o/r" slug above.*
        cls.proof_dir = cbm._fixture_release_seam(cls.fx.repo)

    @classmethod
    def _bind_manifest_transport(cls) -> None:
        """The manifest/attestation seams: serve the gate manifest as if GitHub had received it."""
        cls._saved_artifacts = (ccb._run_artifacts, ccb._artifact_zip)
        import io as _io
        import zipfile as _zip

        def _zip_of(name, blob):
            buf = _io.BytesIO()
            with _zip.ZipFile(buf, "w") as z:
                z.writestr(name + ".json", blob)
            return buf.getvalue()

        def _serve_artifacts(run_id, attempt=None, fetch=None):
            if not cls.fx.manifest_path.is_file():
                return None
            blob = _zip_of("board1-gate-manifest", cls.fx.manifest_path.read_bytes())
            cls._served = {"id": 4242, "name": "board1-gate-manifest",
                           "archive_sha256": __import__("hashlib").sha256(blob).hexdigest(),
                           "size_in_bytes": len(blob), "expired": False}
            return [cls._served]

        ccb._run_artifacts = _serve_artifacts
        ccb._artifact_zip = lambda artifact_id, fetch_bytes=None: _zip_of(
            "board1-gate-manifest", cls.fx.manifest_path.read_bytes())

    @classmethod
    def tearDownClass(cls):
        board1.ROOT, ccb.ROOT, ccb._run_facts, ccb._job_annotations = cls._saved
        ccb._run_artifacts, ccb._artifact_zip = cls._saved_artifacts
        cbm._release_repo = cls._saved_release_repo
        ccb._repository = cls._saved_ccb_repository
        cls._td.cleanup()

    def setUp(self):
        """*** EACH CASE GETS ITS OWN FRESH MANIFEST AND ATTESTATION. *** *A case that leaned on a sibling's write
        would be proving the ORDER the tests ran in, not the contract.*"""
        # *** EVERY CASE STARTS FROM THE CANDIDATE'S OWN COMMIT (`C`), NOT FROM A SIBLING'S SUCCESSOR. *** *Each
        # case commits its own successor below, so the fixture's HEAD must first return to the candidate: otherwise a
        # second case's `HEAD` would be a DESCENDANT OF the first case's successor rather than a DIRECT CHILD of `C`,
        # and the direct-child proof would (correctly) refuse it. This is the contract's own law, exercised by the
        # fixture rather than assumed away.*
        self.fx._git("reset", "--hard", self.fx.sha)
        self.doc = self.fx.document()
        self.fx.write(self.doc)
        if self.att.is_file():
            self.att.unlink()
        self.assertEqual(board1.freeze("1", "board1-court-rc", self.att, 1,
                                       manifest=self.fx.manifest_path,
                                       campaign_dir=self.fx.campaign_dir,
                                       proof_dir=self.proof_dir), 0)
        # *** AND THE ATTESTATION IS COMMITTED AS THE SUCCESSOR `A`, AS PRODUCTION DOES. *** *The post-tag allowance
        # names ONE exact path, and read-only validation refuses an uncommitted successor -- because an attestation
        # sitting untracked in the tree is not the artifact a reader checks out.*
        self.fx._git("add", "-A")
        self.fx._git("commit", "-q", "-m", "attestation")

    def test_the_freeze_binds_the_manifest_and_read_only_validation_re_derives_it(self):
        bound = json.loads(self.att.read_text())["gate_manifest"]
        self.assertEqual(bound["sha256"], cbm.sha256_file(self.fx.manifest_path))
        self.assertEqual(bound["candidate_sha"], self.fx.sha)
        self.assertEqual(bound["gate_count"], len(cbm.REQUIRED_GATE_IDS))
        self.assertEqual(board1.validate_attestation(self.att), 0)

    def test_read_only_validation_leaves_the_attestation_byte_identical(self):
        before = self.att.read_bytes()
        board1.validate_attestation(self.att)
        self.assertEqual(self.att.read_bytes(), before)

    def test_read_only_validation_authenticates_the_embedded_manifest_against_the_hosted_run(self):
        """*** A SELF-CONSISTENT DOCUMENT IS NOT AN AUTHENTICATED ONE. ***

        *The embedded manifest is compared to the bytes THE PINNED RUN uploaded; a caller who hand-writes a manifest
        that agrees with itself but was never fetched is refused.*
        """
        att = json.loads(self.att.read_text())
        att["gate_manifest"] = dict(att["gate_manifest"])
        doctored = json.loads(json.dumps(att["gate_manifest"]["document"]))
        # *A field a reader would not notice: the recorded gate population. The document stays internally consistent
        # (its digest fields are recomputed), so ONLY the hosted comparison can catch it.*
        doctored["gates"]["population"] = {**doctored["gates"]["population"], "accounted": 1}
        att["gate_manifest"]["document"] = doctored
        forged = self.fx.repo / "docs/remediation/evidence/FORGED_ATTESTATION.json"
        forged.write_text(json.dumps(att, indent=1))
        try:
            self.assertNotEqual(board1.validate_attestation(forged), 0)
        finally:
            forged.unlink()

    def test_a_forged_envelope_with_genuine_terminal_bytes_is_refused_at_standalone_admission(self):
        """*** AN ALTERED ENVELOPE MUST BE REFUSED EVEN WHEN THE TERMINAL BYTES ARE GENUINE. ***

        *THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: `executing_successor_problems` used to authenticate only the
        terminal evidence, so an altered `tag_object_sha`/`at_tag_closure_sha256`/`at_tag_ledger_sha256`/pinned attempt
        survived STANDALONE admission.* **Here a committed attestation with the GENUINE hosted terminal bytes (the
        fixture proof + served manifest) but an ALTERED immutable-envelope field is fed to the standalone admission
        path and refused BY NAME.***
        """
        # *The positive control first: the genuine fixture attestation is admitted standalone.*
        self.assertEqual(ccb.executing_successor_problems(
            candidate=self.fx.sha, successor=self.fx._git("rev-parse", "HEAD").stdout.strip(),
            attestation_path=ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH), [])
        # *Now alter ONLY an immutable-envelope field (tag_object_sha) while leaving the terminal bytes genuine.*
        att = json.loads(self.att.read_text())
        att["tag_object_sha"] = "0" * 40
        tampered = json.loads(json.dumps(att))
        self.att.write_text(json.dumps(tampered, indent=1))
        try:
            self.fx._git("add", "--", ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH)
            self.fx._git("commit", "-q", "--amend", "-m", "attestation tampered envelope")
            successor = self.fx._git("rev-parse", "HEAD").stdout.strip()
            problems = ccb.executing_successor_problems(
                candidate=self.fx.sha, successor=successor,
                attestation_path=ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH)
            self.assertTrue(any("tag_object_sha" in p for p in problems),
                            f"a forged envelope survived standalone admission: {problems[:5]}")
        finally:
            self.fx._git("reset", "--hard", self.fx.sha)

    def test_a_manifest_edited_after_the_attestation_bound_it_is_refused(self):
        """*** THE ATTESTATION'S BOUND MANIFEST IS AN ANCHOR, AND ITS DIGEST IS RE-DERIVED. ***

        *THE MEASURED ESCAPE: the case tampered ONLY the on-disk copy, which the embedded-vs-disk equality guard
        already refuseth -- so disabling the bound-digest re-derivation changed nothing and the witness stayed green.
        **So the on-disk manifest AND the embedded copy are now edited TOGETHER (the two agree, and the hosted bytes
        still match), leaving the STALE BOUND DIGEST as the sole disagreement -- exactly the anchor the mutation
        removes.***
        """
        tampered = json.loads(self.fx.manifest_path.read_text())
        tampered["producer"] = {**tampered["producer"], "tool_sha256": "0" * 64}
        self.fx.write(tampered)
        att = json.loads(self.att.read_text())
        att["gate_manifest"]["document"] = tampered       # embedded == on-disk, so only the bound digest can speak
        self.att.write_text(json.dumps(att, indent=1) + "\n")
        self.fx._git("add", "--", ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH)
        self.fx._git("commit", "-q", "--amend", "-m", "attestation")
        before = self.att.read_bytes()
        try:
            self.assertNotEqual(board1.validate_attestation(self.att), 0)
            self.assertEqual(self.att.read_bytes(), before)
        finally:
            self.fx.write(self.doc)

    def test_a_manifest_bound_to_another_candidate_is_refused_by_the_freeze(self):
        """*** A FREEZE MAY NOT BIND A MANIFEST WHOSE CANDIDATE IS NOT THE TAG'S OWN PEEL. ***

        *THE MEASURED ESCAPE: the case put a foreign SHA on a manifest that still NAMED the candidate tag, so the
        manifest contract's candidate-resolution guard refused it before the tag-versus-`candidate.sha` peel guard --
        the guard this mutation disables -- could matter. **So the case now keeps `candidate.sha` at the candidate `C`
        and names a SECOND annotated tag that peels to a DIFFERENT same-tree commit: the ONLY disagreement left is the
        tag's peel versus the manifest's stated sha, which the disabled guard no longer sees. With the guard struck the
        freeze SUCCEEDS and writes a false-green attestation about a tree the tag does not name; the witness asserts the
        live consumer outcome -- a non-zero verdict and NO attestation written -- never the refusal's prose.***
        """
        self.fx._git("reset", "--hard", self.fx.sha)
        self.fx._git("commit", "-q", "--allow-empty", "-m", "foreign same-tree candidate")
        foreign = self.fx._git("rev-parse", "HEAD").stdout.strip()
        self.fx._git("reset", "--hard", self.fx.sha)
        self.fx._git("tag", "-a", "board1-court-other", "-m", "the foreign tag", foreign)
        self.assertEqual(self.fx._git("rev-parse", f"{foreign}^{{tree}}").stdout.strip(), self.fx.tree)
        other = json.loads(json.dumps(self.doc))
        other["candidate"] = {**other["candidate"], "tag": "board1-court-other"}
        self.fx.write(other)
        if self.att.is_file():
            self.att.unlink()
        try:
            rc = board1.freeze("1", "board1-court-rc", self.att, 1,
                               manifest=self.fx.manifest_path,
                               campaign_dir=self.fx.campaign_dir,
                               proof_dir=self.proof_dir)
            self.assertNotEqual(rc, 0,
                                "a tag that peels to another commit than the manifest's stated sha must be refused")
            self.assertFalse(self.att.is_file(),
                             "the freeze must write NO attestation when the tag and the manifest disagree")
        finally:
            self.fx.write(self.doc)
            self.fx._git("tag", "-d", "board1-court-other")

    def test_a_relative_attestation_path_is_resolved_and_never_crashes(self):
        """*** THE MEASURED CRASH: `--attest-out <repo-relative>` RAISED `ValueError` FROM `relative_to`. ***

        *THE MEASURED ESCAPE: the case used a NON-canonical basename and only asserted "no crash", so the mutant's
        NAMED outside-the-repository refusal satisfied it -- the witness stayed green under the mutant. **So the case
        now passes the EXACT canonical SUCCESSOR path, RELATIVE, which the fixed code resolves and accepts, and the
        mutant refuseth by name -- so `rc == 0` and the written file discriminate the two.***
        """
        import os
        if self.att.is_file():
            self.att.unlink()
        rel = Path(ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH)
        previous = os.getcwd()
        try:
            os.chdir(self.fx.repo)
            try:
                rc = board1.freeze("1", "board1-court-rc", rel, 1,
                                   manifest=self.fx.manifest_path,
                                   campaign_dir=self.fx.campaign_dir,
                                   proof_dir=self.proof_dir)
            except ValueError as exc:                       # the measured defect
                self.fail(f"a RELATIVE --attest-out raised ValueError instead of refusing or writing: {exc}")
        finally:
            os.chdir(previous)
        self.assertEqual(rc, 0,
                         "the canonical future attestation named RELATIVELY must be RESOLVED and written; the "
                         "mutant refuseth it as outside the repository")
        self.assertEqual(self.att.resolve(), (self.fx.repo / rel).resolve())

    def test_an_attestation_path_outside_the_repository_is_refused_by_name(self):
        outside = Path(tempfile.mkdtemp()) / "ELSEWHERE.json"
        self.assertNotEqual(board1.freeze("1", "board1-court-rc", outside, 1,
                                          manifest=self.fx.manifest_path,
                                          campaign_dir=self.fx.campaign_dir,
                                          proof_dir=self.proof_dir), 0)
        self.assertFalse(outside.is_file())

    def test_the_freeze_refuses_any_attestation_path_that_is_not_the_canonical_future_path(self):
        """*** THE FREEZE WRITETH EXACTLY ONE PATH -- THE DECLARED FUTURE ATTESTATION. ***

        *An rc11/rc14-era name, a differently-named file or a directory is refused BY NAME; the historical rc14
        attestation may never be re-created as a fresh output.*
        """
        self.att.unlink()
        stray = self.fx.repo / "docs/remediation/evidence/FREEZE_ATTESTATION_rc99.json"
        self.assertNotEqual(board1.freeze("1", "board1-court-rc", stray, 1,
                                          manifest=self.fx.manifest_path,
                                          campaign_dir=self.fx.campaign_dir,
                                          proof_dir=self.proof_dir), 0)
        self.assertFalse(stray.is_file())

    def test_the_freeze_is_write_once_and_refuses_even_malformed_existing_bytes(self):
        """*** AN EXISTING ATTESTATION IS NEVER OVERWRITTEN, EVEN IF ITS BYTES DO NOT PARSE. ***

        *The old guard overwrote a malformed file (its parsed value was None); an attestation is a historical artifact,
        so the path's mere existence is a refusal.*
        """
        self.assertTrue(self.att.is_file())
        malformed = b"{not json at all"
        self.att.write_bytes(malformed)
        try:
            self.assertNotEqual(board1.freeze("1", "board1-court-rc", self.att, 1,
                                              manifest=self.fx.manifest_path,
                                              campaign_dir=self.fx.campaign_dir,
                                              proof_dir=self.proof_dir), 0)
            self.assertEqual(self.att.read_bytes(), malformed)   # left untouched
        finally:
            self.att.unlink()

    def test_a_manifest_over_open_internal_semantic_obligations_is_refused(self):
        """*** A PASS MANIFEST REQUIRETH EVERY INTERNAL OBLIGATION CLOSED -- NOT A STATUS ENUM. ***

        *The derived population is the MEASURED half; a manifest standing PASS over live internal obligations is the
        overclaim this contract refuseth, whatever the closure STATUS saith.*
        """
        bad = json.loads(json.dumps(self.doc))
        bad["derived_counts"] = {**bad["derived_counts"], "internal_obligations_open": 3}
        bad["ledger"] = {**bad["ledger"], "structured_counts": dict(bad["derived_counts"])}
        self.assertTrue(any("internal semantic obligation(s) remain OPEN" in p
                            for p in self.fx.check(bad)))

    def test_a_manifest_with_a_missing_end_identity_is_refused(self):
        """*** BOTH ENDS MUST CARRY THE MEASURED HEAD/TREE. ***

        *`clean_end` used to omit them and the validator bit only when they happened to exist; a missing end identity is
        itself the missing proof this contract refuses.*
        """
        bad = json.loads(json.dumps(self.doc))
        bad["clean_end"] = {k: v for k, v in bad["clean_end"].items() if k not in ("head_sha", "head_tree")}
        problems = self.fx.check(bad)
        self.assertTrue(any("clean_end carrieth NO executing HEAD" in p for p in problems))
        self.assertTrue(any("clean_end carrieth NO executing TREE" in p for p in problems))

    def test_a_manifest_with_no_semantic_provenance_is_refused(self):
        """*** THE PER-OBLIGATION SEMANTICS MUST TRAVEL WITH THE MANIFEST. ***"""
        bad = json.loads(json.dumps(self.doc))
        bad["closure"] = {k: v for k, v in bad["closure"].items() if k != "semantics"}
        self.assertTrue(any("binds NO structured semantic provenance" in p
                            for p in self.fx.check(bad)))


class SharedReaderAuthenticationTests(unittest.TestCase):
    """*** THE ONE SHARED READER AUTHENTICATES THE FULL TERMINAL EVIDENCE -- AND THE BUNDLE CALLS IT DIRECTLY. ***

    *These are the consumers the hostile review named: `scripts/build_evidence_bundle.py` invokes
    `ccb.validate_attestation` DIRECTLY, so a fabricated-but-internally-consistent attestation must be refused THERE,
    not only by the stronger CLI wrapper.*
    """

    @classmethod
    def setUpClass(cls):
        cls._td = tempfile.TemporaryDirectory()
        cls.fx = _ManifestFixture(Path(cls._td.name))
        cls._saved = (board1.ROOT, ccb.ROOT)
        board1.ROOT = cls.fx.repo
        ccb.ROOT = cls.fx.repo
        cls.att = cls.fx.repo / ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH

    @classmethod
    def tearDownClass(cls):
        board1.ROOT, ccb.ROOT = cls._saved
        cls._td.cleanup()

    def test_the_shared_reader_refuses_an_embedded_manifest_that_was_never_hosted(self):
        """*** A SELF-CONSISTENT DOCUMENT IS NOT AN AUTHENTICATED ONE -- PROVEN AT THE SHARED READER. ***

        *A fabricated attestation whose embedded manifest is locally consistent but which no pinned run ever uploaded
        must be refused by `ccb.validate_attestation` itself, since the evidence bundle calls that function directly.
        The run-facts seam names a real successful run, but the artifact lookup finds no artifact of the recorded name
        on it -- so the hosted-bytes authentication bites.*
        """
        green = {"head_sha": self.fx.sha, "conclusion": "success", "status": "completed", "event": "push",
                 "workflow": "repository-verification", "repository": "o/r", "head_branch": "main",
                 "path": ".github/workflows/repository-verification.yml",
                 "run_attempt": 1,
                 "jobs": [{"id": 1000 + i, "name": n, "conclusion": "success"}
                          for i, n in enumerate(ccb.CANONICAL_JOB_NAMES)]}
        saved = (ccb._run_facts, ccb._job_annotations, ccb._run_artifacts, ccb._artifact_zip)
        ccb._run_facts = lambda run_id, attempt=None, **kw: green
        ccb._job_annotations = lambda job_id: []
        ccb._run_artifacts = lambda run_id, attempt=None, fetch=None: []   # the run uploaded NOTHING
        ccb._artifact_zip = lambda artifact_id, fetch_bytes=None: None
        try:
            doc = self.fx.document()
            forged = {
                "candidate_ref": "board1-court-rc", "candidate_sha": self.fx.sha,
                "candidate_tree_sha": self.fx.tree, "tag_object_sha": self.fx._git("rev-parse",
                                                                                  "board1-court-rc").stdout.strip(),
                "at_tag_closure_sha256": "0" * 64, "at_tag_ledger_sha256": "0" * 64,
                "run": {"id": 1, "attempt": 1},
                "gate_manifest": {"name": "board1-gate-manifest", "document": doc,
                                  "hosted_artifact": {"name": "board1-gate-manifest"}},
                "release_evidence": {"records": []},
            }
            forged_path = self.fx.repo / ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH
            forged_path.write_text(json.dumps(forged, indent=1))
            problems = ccb.validate_attestation(forged_path)
            self.assertTrue(any("hosted manifest" in p or "artifact" in p for p in problems),
                            f"the shared reader did not authenticate hosted bytes: {problems[:5]}")
        finally:
            ccb._run_facts, ccb._job_annotations, ccb._run_artifacts, ccb._artifact_zip = saved

    def test_the_shared_reader_refuses_a_fabricated_attestation_without_release_proof(self):
        """*** NO RELEASE-EVIDENCE BLOCK IS A REFUSAL AT THE SHARED READER. ***"""
        forged = {"candidate_ref": "board1-court-rc", "candidate_sha": self.fx.sha,
                  "candidate_tree_sha": self.fx.tree, "tag_object_sha": "0" * 40,
                  "at_tag_closure_sha256": "0" * 64, "at_tag_ledger_sha256": "0" * 64,
                  "run": {"id": 1, "attempt": 1}, "gate_manifest": {"document": None}}
        forged_path = self.fx.repo / ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH
        saved = forged_path.read_bytes() if forged_path.is_file() else None
        forged_path.write_text(json.dumps(forged, indent=1))
        try:
            problems = ccb.validate_attestation(forged_path)
            self.assertTrue(any("release-evidence" in p or "tag_object_sha" in p for p in problems))
        finally:
            if saved is not None:
                forged_path.write_bytes(saved)
            else:
                forged_path.unlink(missing_ok=True)


class ExecutingSuccessorEndpointTests(unittest.TestCase):
    """*** A LEGITIMATE `A` EXECUTION IS ACCEPTED; A WRONG DELTA OR DRIFT IS REFUSED. ***"""

    @classmethod
    def setUpClass(cls):
        cls._td = tempfile.TemporaryDirectory()
        cls.fx = _ManifestFixture(Path(cls._td.name))

    @classmethod
    def tearDownClass(cls):
        cls._td.cleanup()

    def _doc_with_executing_a(self):
        """A manifest that records frozen `C` and a proven executing `A`."""
        doc = self.fx.document()
        doc["candidate"] = {**doc["candidate"],
                            "frozen": {"sha": self.fx.sha, "tree_sha": self.fx.tree, "tag": "board1-court-rc",
                                       "sha_source": "tag"}}
        return doc

    def test_the_structural_half_admits_the_exact_one_file_direct_child_and_refuses_a_wrong_binding(self):
        """*** THE STRUCTURAL HALF: direct child, delta exactly one file, document declares C. ***

        *`attest_exclusion_policy` is the STRUCTURAL half only -- it is NOT admission. The candidate must not carry the
        future file, the successor must be its direct child carrying only that file, and the document must declare the
        candidate; a wrong binding is refused by name.*
        """
        att_rel = ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH
        att = self.fx.repo / att_rel
        att.parent.mkdir(parents=True, exist_ok=True)
        att.write_text(json.dumps({"candidate_sha": self.fx.sha, "candidate_tree_sha": self.fx.tree}), encoding="utf-8")
        # *STAGE ONLY THE ATTESTATION -- an `-A` stage would sweep the fixture's lane sidecars into the delta.*
        self.fx._git("add", "--", att_rel)
        self.fx._git("commit", "-q", "-m", "attestation")
        successor = self.fx._git("rev-parse", "HEAD").stdout.strip()
        saved_root = ccb.ROOT
        ccb.ROOT = self.fx.repo
        try:
            delta = ccb._tree_delta(self.fx.sha)
            self.assertEqual(ccb.attest_exclusion_policy(future_path=att_rel, candidate=self.fx.sha,
                                                         successor=successor, delta=delta, attestation=att_rel), [])
            # *A WRONG BINDING IN THE DOCUMENT IS REFUSED BY THE STRUCTURAL HALF.*
            att.write_text(json.dumps({"candidate_sha": "f" * 40}), encoding="utf-8")
            self.fx._git("add", "--", att_rel)
            self.fx._git("commit", "-q", "--amend", "-m", "attestation")
            successor2 = self.fx._git("rev-parse", "HEAD").stdout.strip()
            problems = ccb.attest_exclusion_policy(future_path=att_rel, candidate=self.fx.sha,
                                                   successor=successor2, delta=ccb._tree_delta(self.fx.sha),
                                                   attestation=att_rel)
            self.assertTrue(any("bindeth candidate" in p for p in problems), problems)
        finally:
            ccb.ROOT = saved_root
            self.fx._git("reset", "--hard", self.fx.sha)
            if att.is_file():
                att.unlink()

    def test_the_structural_half_refuses_a_successor_differing_in_TWO_files(self):
        """*** A SUCCESSOR MAY DIFFER IN EXACTLY THE ONE ATTESTATION FILE. ***

        *The structural delta law (`attest_exclusion_policy`) refuseth any second changed path by name, so a successor
        that also edited a source file cannot be admitted as the attestation-only child.*
        """
        att_rel = ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH
        att = self.fx.repo / att_rel
        att.parent.mkdir(parents=True, exist_ok=True)
        att.write_text(json.dumps({"candidate_sha": self.fx.sha}), encoding="utf-8")
        (self.fx.repo / "src" / "extra.txt").write_text("x\n", encoding="utf-8")
        self.fx._git("add", "--", att_rel, "src/extra.txt")
        self.fx._git("commit", "-q", "-m", "attestation and a source edit")
        successor = self.fx._git("rev-parse", "HEAD").stdout.strip()
        saved_root = ccb.ROOT
        ccb.ROOT = self.fx.repo
        try:
            delta = ccb._tree_delta(self.fx.sha)
            self.assertGreaterEqual(len(delta), 2, delta)
            problems = ccb.attest_exclusion_policy(future_path=att_rel, candidate=self.fx.sha,
                                                   successor=successor, delta=delta, attestation=att_rel)
            self.assertTrue(any("delta" in p for p in problems), problems)
        finally:
            ccb.ROOT = saved_root
            self.fx._git("reset", "--hard", self.fx.sha)
            if att.is_file():
                att.unlink()
            extra = self.fx.repo / "src" / "extra.txt"
            if extra.is_file():
                extra.unlink()

    def test_a_manifest_whose_executing_endpoint_drifted_from_a_is_refused(self):
        """*** THE ENDPOINTS MUST MATCH THE PROVEN EXECUTING `A`, AND DRIFT IS STILL REFUSED. ***

        *When `candidate.executing` names a revision the relation cannot prove, the validator falleth back to the strict
        `C` comparison -- so a manifest claiming an UNPROVEN other revision is refused.*
        """
        doc = self._doc_with_executing_a()
        doc["candidate"]["executing"] = {"sha": "9" * 40, "tree_sha": "8" * 40,
                                         "frozen_sha": self.fx.sha, "attestation": ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH}
        problems = self.fx.check(doc)
        self.assertTrue(any("executing-A" in p for p in problems), problems)


class LaneEvidenceRootDerivationTests(unittest.TestCase):
    """*** LANE SEMANTIC COUNTS MUST BE DERIVED FROM THE DOWNLOADED EVIDENCE ROOT. ***"""

    def test_the_android_lane_counts_come_from_the_supplied_evidence_root(self):
        """*** THE DEFECT THIS CLOSES, FROM THE HOSTILE REVIEW: the checker read the CHECKOUT, not the download. ***

        *A JUnit XML placed ONLY under an evidence root (never in the candidate tree) must drive the lane's parsed
        counts; the same lane against the un-rooted base must report NO result file rather than invent one.*
        """
        with tempfile.TemporaryDirectory() as td:
            base = Path(td) / "repo"
            (base / "ci").mkdir(parents=True)
            shutil.copyfile(REPO / "ci" / "check_lane_results.py", base / "ci" / "check_lane_results.py")
            evr = Path(td) / "evidence"
            xml_rel = cbm.LANE_SOURCES["android:app"]["result_glob"].replace("*.xml", "TEST-Evidence.xml")
            xml = evr / xml_rel
            xml.parent.mkdir(parents=True, exist_ok=True)
            xml.write_text('<?xml version="1.0"?><testsuite tests="7" skipped="1" failures="0" errors="0"></testsuite>\n',
                           encoding="utf-8")
            rooted = cbm.evidence_scoped_lane_check("android:app", base, evidence_root=evr)
            self.assertEqual(rooted[1]["tests"], 7, f"counts not derived from the evidence root: {rooted}")
            unrooted = cbm.lane_check("android:app", base)
            self.assertTrue(any("NO RESULT FILES" in p or "did not run" in p for p in unrooted[0]),
                            f"the un-rooted base invented a lane result: {unrooted}")


class FreshReaderRebindTests(unittest.TestCase):
    """*** A FRESH READER REBINDS RECORDS BY IDENTITY -- AND A SWAPPED FILE IS REFUSED. ***"""

    @classmethod
    def setUpClass(cls):
        cls._td = tempfile.TemporaryDirectory()
        cls.fx = _ManifestFixture(Path(cls._td.name))
        cls.doc = cls.fx.document()

    @classmethod
    def tearDownClass(cls):
        cls._td.cleanup()

    def test_a_rebound_gate_log_with_the_same_bytes_is_accepted_and_a_swapped_one_refused(self):
        """*** REBINDING MAPS THE RECORD BY ITS OWN BASENAME UNDER THE READER'S ROOT, AND KEEPS THE BOUND DIGEST. ***

        *The hosted runner wrote the gate log under its scratch root; a reader names `--artifacts`. When the mapped file
        carries the SAME bytes the manifest bound, the read is accepted; when the mapped file's bytes DIFFER, the
        original-digest check refuses it -- a wrong map cannot smuggle a different file.*
        """
        row = self.doc["gates"]["rows"][0]
        recorded_log_path = self.fx.repo / row["log"]["path"]
        self.assertTrue(recorded_log_path.is_file())
        with tempfile.TemporaryDirectory() as td:
            reader_root = Path(td)
            mapped = reader_root / Path(row["log"]["path"]).name
            mapped.write_bytes(recorded_log_path.read_bytes())
            # *The SAME bytes: accepted with the rebind (the recorded path is deliberately NOT reachable from this
            # reader root, so only the mapping can satisfy the read).*
            ok = self.fx.check(self.doc, rebind={"gates": reader_root})
            self.assertFalse(any("does not match the digest the manifest bound" in p for p in ok), ok)
            # *Swapped bytes under the same name are refused by the ORIGINAL digest.*
            mapped.write_bytes(b"SWAPPED BYTES\n")
            bad = self.fx.check(self.doc, rebind={"gates": reader_root})
            self.assertTrue(any("was EDITED after the manifest bound it" in p for p in bad), bad)


class Schema2ReleaseProofConsumptionTests(unittest.TestCase):
    """*** THE OWNER'S REAL SCHEMA-2 RELEASE PROOF IS CONSUMED -- run:{id,attempt} WITH NO REQUIRED TAG. ***"""

    def test_release_proof_facts_reads_run_id_attempt_and_optional_tag(self):
        """*** `release_proof_facts` MUST READ `doc['run']['id']/['attempt']`, NOT TOP-LEVEL FIELDS. ***

        *A schema-2 document whose `candidate` carrieth {sha,tree_sha} and NO tag, and whose run is `{id,attempt}`,
        must yield the bound keys -- and `release_evidence_problems` must NOT refuse it for the absent tag.*
        """
        with tempfile.TemporaryDirectory() as td:
            proof_dir = Path(td) / "proof"
            proof_dir.mkdir()
            doc = {"schema": 2, "candidate": {"sha": "a" * 40, "tree_sha": "b" * 40},
                   "run": {"id": 7, "attempt": 2, "workflow": "release-gates", "event": "push",
                           "ref": "main", "head_sha": "a" * 40},
                   "internal": {"verdict": "PASS", "jobs": [], "artifacts": [], "refusals": []},
                   "external": {"verdict": "PASS", "roster": []}}
            (proof_dir / "7-2.json").write_text(json.dumps(doc), encoding="utf-8")
            facts = cbm.release_proof_facts(proof_dir, Path(td))
            rec = (facts.get("records") or [{}])[0]
            self.assertEqual(rec.get("run_id"), 7, facts)
            self.assertEqual(rec.get("run_attempt"), 2, facts)
            self.assertIsNone((rec.get("candidate") or {}).get("tag"))
            # *No tag => no tag refusal, but the SHA binding still holds.*
            problems = cbm.release_evidence_problems(facts, candidate_sha="a" * 40,
                                                     candidate_tag="production-readiness-board1-rc15")
            self.assertFalse(any("bindeth candidate tag" in p for p in problems), problems)
            problems_bad = cbm.release_evidence_problems(facts, candidate_sha="c" * 40,
                                                         candidate_tag=None)
            self.assertTrue(any("bindeth candidate sha" in p for p in problems_bad), problems_bad)

    def test_a_forged_self_sealed_proof_is_refused_by_the_real_authenticator(self):
        """*** `RP.seal` IS INTEGRITY, NOT AUTHENTICATION -- A FORGED SELF-SEAL MUST BE REFUSED. ***

        *The owner's `authenticate_release_proof` RE-CAPTURES the claimed run through `capture_release_proof.capture`.
        Here the raw GH transport (`capture_release_proof.gh_api`/`job_log_text`) is faked to answer with REAL
        release-gates facts, and a FORGED document (locally sealed, but whose run/job claims differ from the facts) is
        fed to the REAL authenticator via `verify_release_record`: the canonical body digest compare must refuse it.*
        """
        import importlib
        for _p in (str(REPO), str(REPO / "tools" / "supplychain")):
            if _p not in sys.path:
                sys.path.insert(0, _p)
        cp = importlib.import_module("capture_release_proof")
        vrp = importlib.import_module("verify_release_proof")
        c_sha, c_tree = "a" * 40, "b" * 40
        run = {"id": 11, "run_attempt": 3, "name": "release-gates", "event": "push",
               "head_branch": "main", "head_sha": c_sha, "conclusion": "failure",
               "workflow_path": cp.WORKFLOW_PATH, "repository": {"full_name": "o/r"}}
        jobs, logs = [], {}
        for i, spec in enumerate(cp.INTERNAL_JOB_SPECS):
            jobs.append({"id": 900 + i, "name": spec["display_name"], "conclusion": "success",
                         "steps": [{"name": "artifact-inspection", "conclusion": "success"}]})
        for i, spec in enumerate(cp.EXTERNAL_JOB_SPECS):
            jid = 950 + i
            jobs.append({"id": jid, "name": spec["display_name"], "conclusion": "failure", "steps": []})
            logs[str(jid)] = cp.marker_log(spec["boundary"], f"{spec['boundary']}-src", "ABSENT")
        uploaded = [{"name": a, "digest": "sha256:" + "c" * 64, "size_in_bytes": 10}
                    for spec in cp.INTERNAL_JOB_SPECS for a in spec["artifacts"]]
        saved_gh, saved_log = cp.gh_api, cp.job_log_text
        cp.gh_api = lambda path: (run if "/actions/runs/11" in path and "/attempts/" not in path
                                  and "/artifacts" not in path and "/jobs" not in path
                                  else {"jobs": jobs} if path.endswith("/jobs?per_page=100")
                                  else {"artifacts": uploaded} if "/artifacts" in path
                                  else {"commit": {"tree": {"sha": c_tree}}} if "/commits/" in path else None)
        cp.job_log_text = lambda repo, job_id: logs.get(str(job_id), "")
        try:
            # *A FORGED, locally-sealed document that claims a DIFFERENT job/artifact population than the facts.*
            forged = vrp.seal({"schema": 2, "candidate": {"sha": c_sha, "tree_sha": c_tree},
                               "run": {"id": 11, "attempt": 3, "workflow": "release-gates", "event": "push",
                                       "ref": "main", "head_sha": c_sha},
                               "internal": {"verdict": "PASS",
                                            "jobs": [{"job_id": j, "name": j, "id": 1, "conclusion": "success",
                                                      "steps": [{"name": "artifact-inspection",
                                                                 "internal_verdict": "PASS"}], "artifacts": []}
                                                     for j in vrp.REQUIRED_INTERNAL_JOB_IDS],
                                            "artifacts": [{"name": n, "sha256": "d" * 64, "bytes": 99}
                                                          for n in vrp.REQUIRED_INTERNAL_ARTIFACTS],
                                            "refusals": []},
                               "external": {"verdict": "BLOCKED_EXTERNAL",
                                            "roster": [{"id": jid, "boundary_step": bounds[0],
                                                        "boundary_result": "BLOCKED_EXTERNAL",
                                                        "actual_ids": [],
                                                        "refusal_reason": "forged"}
                                                       for jid, bounds in vrp.EXTERNAL_JOB_BOUNDARIES.items()]}})
            # *The local seal recomputes (integrity holds) -- the AUTHENTICATOR is what refuses the fabrication.*
            self.assertEqual(vrp.verify_release_proof(forged), [])
            problems = cbm.verify_release_record(forged, candidate_sha=c_sha, candidate_tree_sha=c_tree, repo="o/r")
            self.assertTrue(any("fabricated" in p or "altered" in p or "does not match" in p for p in problems),
                            f"the authenticator did not refuse the forged document: {problems}")
            # *And a validly captured document for the SAME facts is accepted (positive control).*
            good = cp.capture("o/r", 11, 3, c_sha)
            self.assertEqual(cbm.verify_release_record(good, candidate_sha=c_sha, candidate_tree_sha=c_tree,
                                                       repo="o/r"), [])
            # *And a tree mismatch is refused by the consumer.*
            self.assertTrue(any("tree" in p for p in cbm.verify_release_record(
                good, candidate_sha=c_sha, candidate_tree_sha="e" * 40, repo="o/r")))
        finally:
            cp.gh_api, cp.job_log_text = saved_gh, saved_log


class ReplayLayoutTests(unittest.TestCase):
    """*** REPLAY EXTRACTS EACH ARTIFACT INTO ITS WORKFLOW DESTINATION, NOT ONE MERGED ROOT. ***"""

    def test_the_destination_map_preserves_per_artifact_nesting(self):
        """*** THE DESTINATION MAP MUST PRESERVE THE PER-ARTIFACT LAYOUT THE WORKFLOW USES. ***

        *`ios-simulator-xcresult` -> evidence/ios-simulator-lane.xcresult; `ios-light-artifact-evidence` ->
        evidence/ios-light; `android-light-artifact-evidence` -> evidence/android-light; the flat gate/manifest
        artifacts -> the hydration root. A single merged `evidence/` root is the defect this refuses.*
        """
        import inspect
        src = inspect.getsource(board1.replay)
        self.assertIn('"ios-simulator-xcresult": out / "evidence" / "ios-simulator-lane.xcresult"', src)
        self.assertIn('"ios-light-artifact-evidence": out / "evidence" / "ios-light"', src)
        self.assertIn('"android-light-artifact-evidence": out / "evidence" / "android-light"', src)


class StrictCMalformedManifestTests(unittest.TestCase):
    """*** A STRICT-C MANIFEST WITH A SUCCESSOR CLAUSE IS REFUSED WITHOUT RE-ENTRY. ***"""

    def test_a_strict_c_manifest_with_a_frozen_clause_is_refused_not_recursed(self):
        """*** THE RECURSION GUARD MUST SKIP SUCCESSOR ADMISSION ENTIRELY IN STRICT-C MODE. ***

        *A malformed embedded C manifest carrying a `frozen`/`executing` clause must return the NAMED refusal and NOT
        re-enter `executing_successor_problems` (which would recurse).*
        """
        fx = _ManifestFixture(Path(tempfile.mkdtemp()))
        try:
            doc = fx.document()
            doc["candidate"] = {**doc["candidate"],
                                "frozen": {"sha": fx.sha, "tree_sha": fx.tree, "tag": "board1-court-rc"},
                                "executing": {"sha": "9" * 40, "tree_sha": "8" * 40}}
            # *Called in strict-C mode: the refusal must be by name and must NOT raise RecursionError.*
            problems = cbm.check_manifest(doc, base=fx.repo, require_candidate=True, strict_candidate=fx.sha)
            self.assertTrue(any("STRICT-C" in p for p in problems), problems)
            self.assertFalse(any("RecursionError" in p or "maximum recursion" in p for p in problems), problems)
        finally:
            import shutil as _sh
            _sh.rmtree(fx.root, ignore_errors=True)


if __name__ == "__main__":
    unittest.main()


def tearDownModule():
    """Restore the shared `capture_release_proof` raw-GH transport the fixtures install."""
    cbm._restore_fixture_release_seams()
