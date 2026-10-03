#!/usr/bin/env python3
"""*** FOCUSED SELFTESTS: THE FREEZE CANDIDATE PATH VERIFIER MUST NOT LIE ABOUT READINESS. ***

*THE CONTRACT, ONE WITNESS EACH:*

  * **W01 a VALID candidate PASSES** -- every recorded path resolves, survives and leaks nothing.
  * **W02 a build-directory LEAK fails** -- a stable, repo-relative record whose path carrieth `build/` is refused
    BY NAME, while the lane RESULTS' own `.../build/test-results/...` nesting stays exempt.
  * **W03 a MISSING file fails** -- the verifier must never report success while the real file access is broken.
  * **W04 an UNRESOLVED substitution token fails** -- a manifest row that never named a real directory.
  * **W05 an ABSOLUTE repo-relative record fails** -- and an ABSOLUTE gate log with no rebind root fails CLOSED
    (rather than assuming a runner's scratch path is present).
  * **W06 a `..`-escaping relative path fails** -- it would resolve against whatever root the reader happens to be in.
  * **W07 an attestation payload carrieth no build/temp leak** -- a leaked `build/` or `/tmp` path is refused.
  * **W08 the ONE lawful future-attestation path is adjudicated by the BINDING AUTHORITY** (never re-implemented).
  * **W09 the INTEGRATION with the existing freeze flow** -- the REAL `check_manifest` consumer runs inside the verifier
    against the same resolved fixture, and a manifest whose path the freeze would refuse reddens here too.

The fixture is a REAL throwaway git repository with a REAL annotated tag and REAL artifact bytes, built by the manifest
contract's OWN fixture (so the positive case is the exact shape the freeze binds). No external gate is closed.
"""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for _p in (ROOT / "ci", ROOT / "scripts", ROOT / "tools" / "readiness"):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))

import check_board1_manifest as cbm  # noqa: E402
import check_candidate_binding as ccb  # noqa: E402
import verify_freeze_candidate_paths as vfc  # noqa: E402


class _Fixture(unittest.TestCase):
    """Base: a real fixture candidate repo and its positive manifest, written to disk."""

    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls.root = Path(cls._tmp.name)
        cls.base = cbm._fixture_repo(cls.root)
        cls.gates = cls.root / "gates"
        cls.doc = cbm._selftest_doc(cls.base, cls.gates)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def _write(self, doc) -> Path:
        path = self.root / "manifest.json"
        path.write_text(json.dumps(doc), encoding="utf-8")
        return path

    def _verify(self, doc, **kw) -> list[str]:
        kw.setdefault("base", self.base)
        return vfc.verify_freeze_candidate_paths(manifest=self._write(doc), **kw)

    def _records(self, doc) -> list[dict]:
        return vfc.manifest_path_records(doc)

    def _closure_record(self, doc) -> dict:
        return next(r for r in self._records(doc) if r["label"] == "closure")


class ValidCandidatePasses(_Fixture):
    """W01 -- the positive construction, resolved with the real utilities, is VERIFIED."""

    def test_w01_a_valid_candidate_passes(self):
        # The traversal is MANIFEST-DRIVEN: it must find the gate, campaign, lane, closure/ledger and external paths.
        records = self._records(self.doc)
        labels = {r["label"] for r in records}
        self.assertIn("closure", labels)
        self.assertIn("ledger", labels)
        self.assertIn("campaign.manifest_path", labels)
        self.assertTrue(any(l.startswith("lanes.") for l in labels))
        self.assertTrue(any(l.startswith("gates.") for l in labels))
        self.assertGreater(len(records), 10)
        # No path problem at all, with existence required.
        self.assertEqual(self._verify(self.doc, consumer_checks=False), [])

    def test_w01b_the_real_manifest_consumer_is_the_integration_point(self):
        # consumer_checks=True runs the SAME `check_manifest` the freeze runs; the positive fixture stays valid.
        self.assertEqual(self._verify(self.doc, consumer_checks=True), [])

    def test_w01c_the_lane_result_build_nesting_is_exempt(self):
        # An evidence-class lane result lives under the workflow's real `.../build/test-results/...` and is NOT a leak.
        lane_arts = [r for r in self._records(self.doc)
                     if r["class"] == vfc.CLASS_EVIDENCE and "/build/" in str(r["path"])]
        self.assertTrue(lane_arts, "the fixture must carry a build-nested lane result to exercise the exemption")
        for rec in lane_arts:
            self.assertEqual(vfc.forbidden_path_problems(rec["path"], label=rec["label"],
                                                         check_build=False, check_temp=False), [])


class BuildDirLeakFails(_Fixture):
    """W02 -- a stable repo-relative path carrying `build/` is a leak and is refused BY NAME."""

    def test_w02_a_build_dir_leak_fails(self):
        bad = json.loads(json.dumps(self.doc))
        self._closure_record(bad)  # locate by shape, then mutate the real record object
        rec_path = "build/BOARD1_CLOSURE.json"
        for row in (bad.get("external_evidence") or {}).get("historical") or []:
            row["path"] = rec_path
        problems = self._verify(bad, consumer_checks=False)
        self.assertTrue(any("build-directory component" in p for p in problems), problems)

    def test_w02b_a_repo_record_under_build_is_refused_even_when_it_resolves(self):
        # A `build/` path that HAPPENS to exist is still a leak: the rule is the shape, not the presence.
        target = self.base / "build" / "BOARD1_CLOSURE.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("{}", encoding="utf-8")
        bad = json.loads(json.dumps(self.doc))
        bad["closure"]["record"]["path"] = "build/BOARD1_CLOSURE.json"
        problems = self._verify(bad, consumer_checks=False)
        self.assertTrue(any("build-directory component" in p for p in problems), problems)


class MissingFileFails(_Fixture):
    """W03 -- a recorded path that resolves to nothing that exists is refused (never a green on a string)."""

    def test_w03_a_missing_file_fails(self):
        bad = json.loads(json.dumps(self.doc))
        bad["closure"]["record"]["path"] = "docs/production-readiness/DOES_NOT_EXIST.json"
        problems = self._verify(bad, consumer_checks=False)
        self.assertTrue(any("does NOT EXIST" in p for p in problems), problems)

    def test_w03b_a_missing_lane_artifact_fails(self):
        bad = json.loads(json.dumps(self.doc))
        lane = bad["lanes"][0]
        lane["artifacts"][0]["path"] = lane["artifacts"][0]["path"] + ".gone"
        problems = self._verify(bad, consumer_checks=False)
        self.assertTrue(any("does NOT EXIST" in p for p in problems), problems)


class UnresolvedTokenFails(_Fixture):
    """W04 -- a gate row that never had its substitution token resolved cannot be verified."""

    def test_w04_an_unresolved_token_fails(self):
        bad = json.loads(json.dumps(self.doc))
        bad["gates"]["rows"][0]["argv"] = list(bad["gates"]["rows"][0]["argv"]) + ["{ios_app}"]
        problems = self._verify(bad, consumer_checks=False)
        self.assertTrue(any("UNRESOLVED substitution token" in p for p in problems), problems)


class AbsoluteForbiddenFails(_Fixture):
    """W05 -- absolute shapes: a repo-relative record may not be absolute, and an absolute gate log fails CLOSED."""

    def test_w05_an_absolute_repo_record_fails(self):
        bad = json.loads(json.dumps(self.doc))
        bad["closure"]["record"]["path"] = "/tmp/BOARD1_CLOSURE.json"
        problems = self._verify(bad, consumer_checks=False)
        self.assertTrue(any("is ABSOLUTE" in p for p in problems), problems)

    def test_w05b_an_absolute_gate_log_without_a_root_fails_closed(self):
        # THE MAIN DEFECT: a recorded absolute scratch path this host cannot read must NEVER read green.
        bad = json.loads(json.dumps(self.doc))
        bad["gates"]["rows"][0]["log"] = {"path": "/nonexistent-runner-temp/gate.log",
                                          "sha256": "0" * 64, "bytes": 1}
        problems = self._verify(bad, consumer_checks=False)
        self.assertTrue(any("does NOT EXIST" in p for p in problems), problems)

    def test_w05c_an_absolute_gate_log_with_a_rebind_root_resolves_by_identity(self):
        # With the reader-side artifact root supplied, the recorded basename resolves under it (the real freeze flow).
        gid = self.doc["gates"]["rows"][0]["id"]
        log = self.gates / f"{gid}.log"
        self.assertTrue(log.is_file())
        bad = json.loads(json.dumps(self.doc))
        bad["gates"]["rows"][0]["log"] = {"path": f"/nonexistent-runner-temp/gates/{gid}.log",
                                          "sha256": cbm.sha256_file(log), "bytes": log.stat().st_size}
        problems = vfc.verify_freeze_candidate_paths(manifest=self._write(bad), base=self.base,
                                                     artifacts=self.gates, consumer_checks=False)
        self.assertFalse(any("does NOT EXIST" in p for p in problems), problems)


class EscapingPathFails(_Fixture):
    """W06 -- a relative path that escapes an unspecified ancestor is refused."""

    def test_w06_an_escaping_relative_path_fails(self):
        bad = json.loads(json.dumps(self.doc))
        bad["closure"]["record"]["path"] = "../escape.json"
        problems = self._verify(bad, consumer_checks=False)
        self.assertTrue(any("'..'" in p for p in problems), problems)

    def test_w06b_an_empty_path_fails(self):
        bad = json.loads(json.dumps(self.doc))
        bad["closure"]["record"]["path"] = ""
        problems = self._verify(bad, consumer_checks=False)
        self.assertTrue(any("is EMPTY" in p for p in problems), problems)


class AttestationPayloadLeakFails(_Fixture):
    """W07 -- no build/temp path may leak into an attestation payload."""

    def test_w07_a_build_path_in_the_payload_fails(self):
        att = {"schema": 1, "candidate_ref": "rc", "artifacts": {"apk": "android/app/build/outputs/app.apk"},
               "run": {"workflow_path": ".github/workflows/repository-verification.yml"}}
        problems = vfc.attestation_path_problems(att)
        self.assertTrue(any("build-directory component" in p for p in problems), problems)

    def test_w07b_a_tmp_path_in_the_payload_fails(self):
        att = {"schema": 1, "run": {"scratch": "/tmp/board1-gates-abc/candidate-binding-selftest.log"}}
        problems = vfc.attestation_path_problems(att)
        self.assertTrue(any("temporary root" in p for p in problems), problems)

    def test_w07c_a_clean_attestation_payload_passes(self):
        att = {"schema": 1, "candidate_ref": "production-readiness-board1-rc14",
               "post_tag_attestation": ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH,
               "run": {"workflow_path": ".github/workflows/repository-verification.yml",
                       "repository": "oculusrex14/GODSTONE"}}
        self.assertEqual(vfc.attestation_path_problems(att), [])


class FutureAttestationPolicy(_Fixture):
    """W08 -- the One lawful future-attestation path is the BINDING AUTHORITY's, never a private literal."""

    def test_w08_the_authority_literal_is_admitted(self):
        self.assertEqual(vfc.future_attestation_path_problems(ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH), [])

    def test_w08b_a_build_path_is_refused(self):
        problems = vfc.future_attestation_path_problems("build/FREEZE_ATTESTATION_rc15.json")
        self.assertTrue(problems)
        self.assertTrue(any("build-directory component" in p for p in problems), problems)

    def test_w08c_a_glob_prefix_directory_or_rc14_is_refused(self):
        for bad in ("docs/remediation/evidence/*.json",
                    "docs/remediation/evidence/",
                    ccb.HISTORICAL_ATTESTATION_PATH,
                    "/tmp/FREEZE_ATTESTATION_rc15.json"):
            self.assertTrue(vfc.future_attestation_path_problems(bad), bad)


class IntegrationWithTheFreezeFlow(_Fixture):
    """W09 -- the real consumer runs inside the verifier, and a path the freeze refuses reddens here too."""

    def test_w09_the_real_consumer_reddens_on_a_broken_path(self):
        bad = json.loads(json.dumps(self.doc))
        bad["closure"]["record"]["path"] = "docs/production-readiness/DOES_NOT_EXIST.json"
        problems = self._verify(bad, consumer_checks=True)
        # The consumer's own refusal must appear (not merely the path traversal's).
        self.assertTrue(any("closure" in p or "NOT PRESENT" in p or "does not match" in p for p in problems), problems)
        # And the real consumer itself refuses the mutated document.
        self.assertTrue(cbm.check_manifest(bad, base=self.base))

    def test_w09b_an_absent_manifest_fails_closed(self):
        problems = vfc.verify_freeze_candidate_paths(manifest=self.root / "no-such-manifest.json", base=self.base,
                                                     consumer_checks=False)
        self.assertTrue(any("no document at" in p for p in problems), problems)

    def test_w09c_no_manifest_named_is_a_named_refusal(self):
        problems = vfc.verify_freeze_candidate_paths(manifest=None, base=self.base)
        self.assertTrue(any("no manifest named" in p for p in problems), problems)


class CampaignPathsResolve(_Fixture):
    """W10 -- the campaign envelope and its phase logs resolve the way the freez's OWN consumer resolves them."""

    def _campaign_dir(self) -> Path:
        return self.base.parent / (self.base.name + "-campaign")

    def test_w10_the_campaign_tree_is_traversed_and_survives(self):
        labels = {r["label"] for r in self._records(self.doc)}
        self.assertIn("campaign.manifest_path", labels)
        self.assertTrue(any(l.startswith("campaign.files[") for l in labels))
        self.assertEqual(self._verify(self.doc, consumer_checks=False), [])

    def test_w10b_the_envelope_is_base_relative_without_a_rebind_root(self):
        # EXACTLY check_manifest: with no campaign root, a relative envelope path is BASE-relative -- never
        # double-joined under a campaign directory.
        rec = next(r for r in self._records(self.doc) if r["label"] == "campaign.manifest_path")
        disk, problems = vfc.resolve_record(rec, base=self.base, rebind={})
        self.assertEqual(problems, [])
        self.assertEqual(disk, self.base / rec["path"])

    def test_w10c_the_envelope_maps_by_basename_under_a_rebind_root(self):
        rec = next(r for r in self._records(self.doc) if r["label"] == "campaign.manifest_path")
        disk, _ = vfc.resolve_record(rec, base=self.base, rebind={"campaign": self._campaign_dir()})
        self.assertEqual(disk, self._campaign_dir() / Path(rec["path"]).name)

    def test_w10d_a_phase_log_resolves_under_the_campaign_root(self):
        rec = next(r for r in self._records(self.doc) if r["class"] == vfc.CLASS_CAMPAIGN_FILE)
        disk, _ = vfc.resolve_record(rec, base=self.base, rebind={"campaign": self._campaign_dir()})
        self.assertEqual(disk, self._campaign_dir() / str(rec["path"]))
        self.assertTrue(disk.is_file())

    def test_w10e_a_missing_campaign_phase_log_fails(self):
        bad = json.loads(json.dumps(self.doc))
        bad["campaign"]["files"][0]["path"] = "logs/DOES_NOT_EXIST.log"
        problems = self._verify(bad, consumer_checks=False)
        self.assertTrue(any("does NOT EXIST" in p for p in problems), problems)

    def test_w10f_a_missing_campaign_envelope_fails(self):
        bad = json.loads(json.dumps(self.doc))
        bad["campaign"]["manifest_path"] = "docs/remediation/evidence/NO_SUCH_ENVELOPE.json"
        problems = self._verify(bad, consumer_checks=False)
        self.assertTrue(any("does NOT EXIST" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
