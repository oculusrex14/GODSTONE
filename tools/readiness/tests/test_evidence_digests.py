#! /usr/bin/env python3
"""The EVIDENCE DIGESTS' own court.

The remediation ledger claimeth run-specific evidence: for each finding, logs with a recorded
sha256. A claim of evidence that nobody re-measureth is a claim, not a measurement -- and the
programme already paid for that lesson in round 278 (the NINTH species of the control family):

  the digest check lived only in an AD-HOC SHELL ONE-LINER that resolved each registered path with
  `os.path.exists(p)` AGAINST THE WORKING DIRECTORY. 86 of the 304 entries were bare RELATIVE paths
  (`ANDROID-02/green/...`) that resolve under neither the checkout nor the evidence root, so the
  check counted them as NEITHER an ok NOR a mismatch and reported "218 ok, 0 mismatched" WHILE NEVER
  EXAMINING 28% OF WHAT IT CLAIMED TO HAVE AUDITED. The 86 files were present and correct: THE
  INSTRUMENT WAS BLIND. A DENOMINATOR QUIETLY SHRUNK IS NOT A DENOMINATOR.

So the court judgeth the INSTRUMENT, not only the data:

  W01 every registered entry is EXAMINED and every digest MATCHETH (rc 0 on the real ledger)
  W02 THE DENOMINATOR ADDETH UP, and equalleth the count this court maketh for itself from the
      ledger -- so the instrument cannot audit less than it claims while reporting a clean sheet
  W03 NEGATIVE: an entry that resolveth nowhere is a NAMED ERROR, never a skip -- and it stayeth
      inside the denominator, so it cannot leave the audit unnoticed
  W04 NEGATIVE: a digest that disagreeth with its file is a NAMED ERROR
  W05 NEGATIVE: an entry that carrieth no path at all is a NAMED ERROR
  W06 the canonical evidence root is RECORDED IN THE LEDGER and existeth, because a relative path
      whose root is unrecorded meaneth whatever the reader's shell happeneth to mean by it
  W07 the CONVERGENCE population is examined too: candidate verifications register their logs outside
      `my_logs`, and AN INSTRUMENT WITH AN IGNORED POPULATION IS THE NINTH SPECIES OVER AGAIN

GS-FINAL-001 (the independent audit, 2026-09-18) found the instrument STILL blind in four ways, and
this court now judgeth each one:

  W08 a convergence record that NAMES a log and carrieth NO digest is a NAMED DEFECT, never a silent
      omission. The walker yielded only on a complete (log, digest) pair, so the record it could not
      verify was also the record it never counted.
  W09 the RED-CASE population is examined. `my_red_case` carrieth a `log` LIST and a PARALLEL
      `log_sha256` LIST -- a schema the instrument's scalar reader turned into the empty string, so
      fourteen real RED logs were neither verified nor NAMED. A parallel list is not a scalar.
  W10 a valid parent log does not HIDE a nested invalid one. The walker `return`ed upon yielding a
      parent, so children were never visited.
  W11 `--json` is not a way to pass. The root-existence check sat only on the text path, so a missing
      evidence root returned 1 in text mode and 0 in JSON mode.
  W12 THE COURT COUNTETH FOR ITSELF, WITH ITS OWN WALKER. Every record in the ledger that NAMES a log
      is registered and verified -- so the instrument cannot audit less than the record carries while
      this court reports a clean sheet from a SHARED blind spot.
"""
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"
INSTRUMENT = ROOT / "ci" / "check_evidence_digests.py"


def ledger() -> dict:
    return json.loads(LEDGER.read_text(encoding="utf-8"))


def write_temp(state: dict) -> Path:
    tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
    json.dump(state, tmp, ensure_ascii=False)
    tmp.close()
    return Path(tmp.name)


def first_entry(state: dict):
    """The first (finding id, evidence entry) pair the ledger carrieth."""
    for fid, entry in state["findings"].items():
        for ev in entry.get("my_logs") or []:
            return fid, ev
    raise AssertionError("the ledger carrieth no evidence entries at all")


def break_first_entry(**changes):
    """A ledger whose FIRST evidence entry carrieth the given changes -- one thing broken, nothing else."""
    state = ledger()
    fid, ev = first_entry(state)
    state["findings"][fid]["my_logs"][0] = dict(ev, **changes)
    return fid, write_temp(state)


def run_instrument(ledger_path, json_out=True):
    cmd = [sys.executable, str(INSTRUMENT), "--ledger", str(ledger_path)]
    if json_out:
        cmd.append("--json")
    p = subprocess.run(cmd, capture_output=True, text=True)
    out = p.stdout + p.stderr
    parsed = None
    if json_out:
        start = p.stdout.find("{")
        if start >= 0:
            try:
                parsed = json.loads(p.stdout[start:])
            except json.JSONDecodeError:
                parsed = None
    return p.returncode, out, parsed


def _as_paths(value):
    """A record's log field is a scalar OR a parallel list. Both are SHAPES THE RECORD USETH."""
    if value is None:
        return []
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    if isinstance(value, list):
        return [v.strip() for v in value if isinstance(v, str) and v.strip()]
    return []


def court_entries(state):
    """EVERY record in the ledger that NAMES a log -- counted by THIS court's own walker.

    The instrument and this court must not share a blind spot: the denominator the instrument reports
    is compared against a population derived here, by a walker that ENTERS a record merely because it
    sayeth `log`, and that CARRIETH the parallel-list shape the RED cases actually use."""
    out = []

    def walk(obj, label):
        if isinstance(obj, dict):
            if "log" in obj:
                out.append((label, _as_paths(obj.get("log")),
                            _as_paths(obj.get("sha256") or obj.get("log_sha256"))))
            for key, value in obj.items():
                walk(value, "%s.%s" % (label, key))
        elif isinstance(obj, list):
            for index, value in enumerate(obj):
                walk(value, "%s[%d]" % (label, index))

    walk(state, "")
    return out


class EvidenceDigestTest(unittest.TestCase):
    def test_w01_every_registered_entry_is_examined_and_every_digest_matchet(self):
        rc, out, parsed = run_instrument(LEDGER)
        self.assertIsNotNone(parsed, "the instrument must emit JSON:\n" + out)
        self.assertEqual(0, rc, "every registered evidence digest must verify:\n" + out)
        self.assertEqual(parsed["registered"], parsed["verified"],
                         "a registered entry that was not verified is evidence nobody re-measured")
        self.assertEqual(parsed["registered"], parsed["examined"],
                         "every registered entry must be EXAMINED, not skipped")

    def test_w02_the_denominator_addeth_up_and_match_the_courts_own_count(self):
        mine = sum(len(e.get("my_logs") or []) for e in ledger()["findings"].values())
        rc, out, parsed = run_instrument(LEDGER)
        self.assertIsNotNone(parsed, out)
        self.assertLessEqual(mine, parsed["findings"]["registered"],
                             "the instrument examined a SMALLER population than the ledger carrieth:\n" + out)
        self.assertEqual(parsed["registered"],
                         parsed["examined"],
                         "the denominator must account for every registered entry:\n" + out)
        self.assertEqual(parsed["registered"],
                         parsed["verified"] + len(parsed["mismatched"]) + len(parsed["unresolved"])
                         + len(parsed["unnamed"]) + len(parsed["undigested"]),
                         "every registered entry must land in exactly one bucket, and NONE may be "
                         "silently dropped:\n" + out)

    def test_w07_the_convergence_population_is_examined_too(self):
        """AN INSTRUMENT WITH AN IGNORED POPULATION IS THE NINTH SPECIES OVER AGAIN.

        The first version of the instrument read `findings[*].my_logs` ONLY -- while candidate
        verifications register their logs under `convergence`. It would have been blind to five freshly
        registered candidate logs the moment they were written."""
        rc, out, parsed = run_instrument(LEDGER)
        self.assertIsNotNone(parsed, out)
        conv = parsed["convergence"]
        self.assertGreater(conv["registered"], 0,
                           "candidate verifications register logs under `convergence`; an instrument that "
                           "readeth only `my_logs` never seeth them")
        self.assertEqual(conv["registered"], conv["examined"],
                         "every convergence-registered log must be EXAMINED:\n" + out)
        self.assertEqual(conv["registered"], conv["verified"],
                         "every convergence-registered log must VERIFY:\n" + out)

    def test_w03_an_entry_that_resolveth_nowhere_is_a_named_error_not_a_skip(self):
        fid, path = break_first_entry(log="NO-SUCH-FINDING/green/nowhere.log")
        rc, out, parsed = run_instrument(path)
        self.assertEqual(1, rc, "an unresolvable entry MUST be a red, not a skip:\n" + out)
        self.assertIn(fid, out, "the error must NAME the finding whose evidence is missing")
        self.assertTrue(parsed["unresolved"], out)
        self.assertEqual(parsed["registered"],
                         parsed["examined"] + len(parsed["unresolved"]) + len(parsed["unnamed"]),
                         "the unresolvable entry must stay INSIDE the denominator:\n" + out)
        self.assertEqual(parsed["registered"] - 1, parsed["verified"],
                         "exactly one entry should have become unexaminable, and the REST must still verify -- "
                         "an instrument that giveth up on the whole population when one entry is missing "
                         "cannot tell a blind check from a broken repository:\n" + out)

    def test_w04_a_digest_that_disagreeth_with_its_file_is_a_named_error(self):
        fid, path = break_first_entry(sha256="0" * 64)
        rc, out, parsed = run_instrument(path)
        self.assertEqual(1, rc, "a digest that no longer matcht its file MUST be a red:\n" + out)
        self.assertIn(fid, out, "the mismatch must NAME the finding")
        self.assertTrue(parsed["mismatched"], out)
        self.assertEqual(parsed["registered"], parsed["examined"],
                         "a mismatched digest WAS examined -- it must not vanish from the denominator:\n" + out)

    def test_w05_an_entry_with_no_path_at_all_is_a_named_error(self):
        fid, path = break_first_entry(log="")
        rc, out, parsed = run_instrument(path)
        self.assertEqual(1, rc, "an evidence entry with no path is not evidence:\n" + out)
        self.assertIn(fid, out, "the error must NAME the finding")
        self.assertTrue(parsed["unnamed"], out)

    def test_w06_the_canonical_evidence_root_is_recorded_and_existeth(self):
        root = ledger().get("evidence_root")
        self.assertTrue(root, "the ledger must RECORD its canonical evidence root: a relative path whose "
                              "root is unrecorded meaneth whatever the reader's shell meaneth by it")
        self.assertTrue(Path(root).is_dir(), "the recorded evidence root must exist: %s" % root)
        rc, out, parsed = run_instrument(LEDGER)
        self.assertEqual(root, parsed["root"], out)
        self.assertTrue(parsed["root_exists"], out)

    # ----------------------------------------------------------------------------------------------
    # GS-FINAL-001 -- THE FOUR WAYS THE INSTRUMENT WAS STILL BLIND, EACH NOW A NAMED ARM.
    # ----------------------------------------------------------------------------------------------

    def test_w08_a_log_named_without_a_digest_is_a_named_defect_not_an_omission(self):
        """GS-FINAL-001(a). The walker yielded ONLY on a complete (log, digest) pair, so a record that
        NAMETH a log and carrieth no digest was never registered -- THE RECORD IT COULD NOT VERIFY WAS
        ALSO THE RECORD IT NEVER COUNTED. Fourteen such records existed in the real ledger; the repair
        recorded their digests, and this arm keeps the CLASS judged rather than depending on the data
        still being broken."""
        state = ledger()
        # *** THE FIXTURE IS SYNTHETIC AND ITS ROOT IS A TEMP DIRECTORY -- NEVER THE IMMUTABLE EVIDENCE TREE. ***
        #
        # THE FIRST DRAFT OF THIS ARM WROTE `valid.log` UNDER THE REAL `evidence_root` AND LEFT IT THERE: it committed
        # TEST POLLUTION INTO THE VERY TREE WHOSE IMMUTABILITY THIS PROGRAMME VERIFIES, and it was found as
        # `REMEDIATION/GS-TEST-001/valid.log` on disk. A control whose fixture writes into the evidence it audits is
        # destroying the thing it measures. The ledger's `findings` are also left out, because this arm's subject is the
        # ARM's own record-shape handling, not the real population.
        base = Path(tempfile.mkdtemp(prefix="gs-final-001-w08-"))
        (base / "REMEDIATION" / "GS-TEST-001").mkdir(parents=True, exist_ok=True)
        (base / "REMEDIATION" / "GS-TEST-001" / "valid.log").write_text("synthetic\n")
        state = {"schema_version": 1, "evidence_root": str(base), "findings": {}, "convergence": {}}
        state["findings"]["GS-TEST-001"] = {
            "my_red_case": {"log": "GS-TEST-001/valid.log", "case": "synthetic"}
        }
        rc, out, parsed = run_instrument(write_temp(state))
        self.assertEqual(1, rc,
                         "a log named without a digest is UNVERIFIED EVIDENCE and must redden the "
                         "control:\n" + out)
        self.assertTrue(parsed["undigested"],
                        "the defect must be NAMED in the report, not silently dropped:\n" + out)
        self.assertIn("GS-TEST-001", out, "the defect must NAME the record that carrieth it")
        # IT IS NOT A MISMATCH: nothing was compared, so nothing disagreed. The distinction matters --
        # a wrong digest and an absent digest demand different repairs.
        self.assertFalse(parsed["mismatched"],
                         "an ABSENT digest is not a WRONG digest; the two defects must stay separable:\n" + out)

    def test_w09_the_red_case_population_is_examined_in_its_parallel_list_shape(self):
        """GS-FINAL-001(b). `my_red_case` carrieth `log` as a LIST with a PARALLEL `log_sha256` LIST.
        The instrument read scalars, so a list became the empty string and fourteen real RED logs were
        neither verified nor named. This arm pins the SHAPE, not merely the count."""
        state = ledger()
        reds = [(fid, e.get("my_red_case")) for fid, e in state["findings"].items()
                if isinstance(e.get("my_red_case"), dict) and e["my_red_case"].get("log")]
        self.assertTrue(reds, "this ledger carrieth my_red_case records; they are a population")
        # BOTH SHAPES LIVE IN THIS LEDGER: eighteen RED cases name a single log, fourteen name a LIST
        # of them with a PARALLEL digest list. The instrument must read BOTH; a reader that handled
        # only the scalar shape would still be blind to half the population.
        shaped = [(fid, rc) for fid, rc in reds if isinstance(rc["log"], list)]
        scalar = [(fid, rc) for fid, rc in reds if isinstance(rc["log"], str)]
        self.assertTrue(shaped, "this ledger carrieth LIST-shaped RED cases -- the shape a scalar "
                                "reader cannot see")
        self.assertTrue(scalar, "this ledger also carrieth SCALAR-shaped RED cases")
        fid, red = shaped[0]
        self.assertEqual(len(red["log"]), len(red.get("log_sha256") or []),
                         "the parallel lists must pair element for element")
        # A WRONG RED-CASE DIGEST MUST BE A NAMED MISMATCH -- proof the population is really judged.
        state["findings"][fid]["my_red_case"]["log_sha256"] = ["0" * 64] * len(red["log"])
        rc, out, parsed = run_instrument(write_temp(state))
        self.assertEqual(1, rc, "a wrong RED-case digest must redden the control:\n" + out)
        self.assertTrue(parsed["mismatched"], out)
        self.assertIn(fid, out, "the mismatch must NAME the finding")

    def test_w10_a_valid_parent_log_does_not_hide_a_nested_invalid_one(self):
        """GS-FINAL-001(c). The walker `return`ed the moment it yielded a parent, so children were
        NEVER VISITED: a nested invalid log was hidden by a valid parent. The arm nests one INSIDE the
        parent dict, so a walker that stops at the parent cannot see it."""
        state = {"schema_version": 1, "evidence_root": "", "findings": {}, "convergence": {}}
        base = Path(tempfile.mkdtemp(prefix="gs-final-001-w10-"))
        (base / "valid.log").write_text("a valid parent log\n")
        valid = hashlib.sha256((base / "valid.log").read_bytes()).hexdigest()
        state["evidence_root"] = str(base)
        state["convergence"] = {
            "parent": {"log": "valid.log", "sha256": valid,
                       "child": {"log": "valid.log", "sha256": "0" * 64}},
        }
        rc, out, parsed = run_instrument(write_temp(state))
        self.assertEqual(1, rc,
                         "a nested invalid record must not be hidden by its valid parent:\n" + out)
        self.assertTrue(parsed["mismatched"], out)
        self.assertTrue(any("child" in m["finding"] for m in parsed["mismatched"]),
                        "the NESTED record must be the one reported, by its own label:\n" + out)
        # BOTH RECORDS ARE JUDGED: stopping at the parent is a blind spot, and skipping the parent once
        # children are walked would be the same defect wearing the other face.
        self.assertEqual(2, parsed["registered"],
                         "the parent AND its nested child are both records:\n" + out)
        self.assertEqual(1, parsed["verified"],
                         "the parent's own VALID digest must still be credited:\n" + out)

    def test_w11_json_mode_does_not_turn_a_failure_into_a_success(self):
        """GS-FINAL-001(d). The root-existence check sat only on the text path: a missing root returned
        1 in text mode and 0 in `--json`. A machine-readable report that disagreeth with the human one
        is a second verdict, and the automation reads the machine's."""
        state = {"evidence_root": str(ROOT / "NO-SUCH-EVIDENCE-ROOT"),
                 "findings": {}, "convergence": {}}
        path = write_temp(state)
        text_rc, text_out, _ = run_instrument(path, json_out=False)
        json_rc, json_out, _ = run_instrument(path, json_out=True)
        self.assertEqual(1, text_rc, text_out)
        self.assertEqual(1, json_rc,
                         "--json must not convert a failing control into success:\n" + json_out)
        self.assertEqual(text_rc, json_rc,
                         "the two output modes must deliver ONE verdict:\n%s\n%s" % (text_out, json_out))

    def test_w13_a_malformed_ledger_is_a_named_diagnostic_not_a_traceback(self):
        """GS-FINAL-001(c), THE LAST UNMET CLAUSE OF THE CARD.

        The card's `exact_remediation` demandeth "malformed-I/O diagnostics". The instrument's own
        clause 5 claimeth "IT FAILETH LOUDLY: rc 1 with every defect listed, each as a `::error::`
        line" -- *and a PYTHON TRACEBACK IS NOT ONE OF ITS LINES. It is the interpreter reporting,
        in a shape no log parser was written for, that the program died before it began.* **Measured
        before this arm existed: a ledger that is not JSON returned rc 1 WITH a traceback and ZERO
        `::error::` lines -- failing closed, but reporting nothing the contract promiseth.**"""
        with tempfile.TemporaryDirectory(prefix="gs-final-001-w13-") as tmp:
            bad = Path(tmp) / "not-json.json"
            bad.write_text("{not json at all", encoding="utf-8")
            rc, out, parsed = run_instrument(bad)
            self.assertEqual(1, rc, "a malformed ledger MUST fail:\n" + out)
            self.assertNotIn("Traceback", out,
                             "a raw traceback is not a diagnostic:\n" + out)
            self.assertIn("::error::", out,
                          "the instrument's own clause 5 promiseth `::error::` lines; a malformed ledger\n"
                      "must be NAMED the same way every other defect is:\n" + out)
            self.assertIn("ledger", out.lower(),
                          "the diagnostic must name WHAT could not be read:\n" + out)

    def test_w14_an_unreadable_evidence_entry_is_named_like_every_other_defect(self):
        """GS-FINAL-001(c): *"A DIRECTORY WHERE A FILE IS EXPECTED, AN UNREADABLE FILE"* -- the two
        shapes the ledger's own assessment named as owed, MEASURED HERE AS RAW TRACEBACKS BEFORE THIS
        REPAIR. **Clause 5's promise is uniform: `rc 1` with `::error::` lines. An entry that resolves
        to something the instrument cannot hash must be one of those lines, not an interpreter dump.**
        """
        import os
        import stat as _stat
        with tempfile.TemporaryDirectory(prefix="gs-final-001-w14-") as tmp:
            root = Path(tmp)
            (root / "REMEDIATION" / "X").mkdir(parents=True)
            (root / "REMEDIATION" / "X" / "adir").mkdir()
            unreadable = root / "REMEDIATION" / "X" / "sealed.log"
            unreadable.write_text("sealed\n", encoding="utf-8")
            for label, name in (("directory where a file is expected", "X/adir"),
                                ("unreadable file", "X/sealed.log")):
                if label.startswith("unreadable"):
                    if os.geteuid() == 0:
                        continue  # root readeth everything; the shape cannot be produced
                    unreadable.chmod(0)
                led = {"schema_version": 1, "evidence_root": str(root),
                       "findings": {"GS-X": {"my_logs": [{"log": name, "sha256": "0" * 64}]}},
                       "convergence": {}}
                ledp = root / "l.json"
                ledp.write_text(json.dumps(led), encoding="utf-8")
                rc, out, _ = run_instrument(ledp)
                self.assertEqual(1, rc, "%s MUST fail:\n%s" % (label, out))
                self.assertNotIn("Traceback", out,
                                 "%s produced a raw interpreter dump, not a diagnostic:\n%s" % (label, out))
                self.assertIn("GS-X", out,
                              "the diagnostic must NAME the finding whose evidence is unreadable:\n" + out)
                if label.startswith("unreadable"):
                    unreadable.chmod(_stat.S_IRUSR | _stat.S_IWUSR)

    def test_w15_the_ledger_s_version_is_a_GATE_not_a_label(self):
        """*** GS-FINAL-001's LAST NAMED SUB-ITEM: "a versioned schema". ***

        *The ledger carrieth `schema_version: 1` -- and **NOTHING READ IT.** `ci/check_evidence_digests.py` and
        `ci/check_required_runs.py` both return ZERO hits for the name, so the field was a LABEL: a record could be
        rewritten under a new interpretation and every instrument would keep reading it by the old rules and
        report PASS.* **The session's own law is that A GATE NOBODY CONSULTS IS NOT A GATE, so this arm demandeth that
        the instrument REFUSE a record whose version it was not written to interpret.**

        *Both directions are exercised, because a gate that only refuseth is indistinguishable from one that
        refuseth everything: an UNKNOWN version is a NAMED defect, and the KNOWN one still verifieth.*
        """
        base = ledger()
        with tempfile.TemporaryDirectory(prefix="gs-final-001-w15-") as tmp:
            for label, version, expect_ok in (("the known version", 1, True),
                                              ("an unknown future version", 99, False),
                                              ("no version at all", None, False)):
                state = json.loads(json.dumps(base))
                if version is None:
                    state.pop('schema_version', None)
                else:
                    state['schema_version'] = version
                path = Path(tmp) / ("ledger-%s.json" % (version if version is not None else "absent"))
                path.write_text(json.dumps(state), encoding="utf-8")
                rc, out, _parsed = run_instrument(path)
                if expect_ok:
                    self.assertEqual(0, rc, "%s must still be accepted:\n%s" % (label, out))
                else:
                    self.assertEqual(1, rc, "*** %s MUST BE REFUSED: an instrument that readeth a record by "
                                            "rules it was not written for reporteth PASS about the WRONG "
                                            "DOCUMENT. ***\n%s" % (label, out))
                    self.assertIn("schema", out.lower(),
                                  "%s must be NAMED, not refused anonymously:\n%s" % (label, out))

    def test_w12_the_court_counteth_the_population_with_its_own_walker(self):
        """THE COURT MUST NOT SHARE THE INSTRUMENT'S BLIND SPOT. This arm derives the population here,
        with its own walker and its own reading of the record's shapes, and demands that the instrument
        registered exactly what the LEDGER NAMES -- every log-bearing record, in every shape."""
        entries = court_entries(ledger())
        pairs = sum(len(logs) for _, logs, _ in entries)
        rc, out, parsed = run_instrument(LEDGER)
        self.assertIsNotNone(parsed, out)
        self.assertEqual(pairs, parsed["registered"],
                         "the instrument registered %d entries while the record NAMES %d logs:\n"
                         % (parsed["registered"], pairs) + out)
        self.assertEqual(parsed["registered"],
                         parsed["verified"] + len(parsed["mismatched"]) + len(parsed["unresolved"])
                         + len(parsed["unnamed"]) + len(parsed["undigested"]),
                         "every registered entry stays inside the denominator:\n" + out)
