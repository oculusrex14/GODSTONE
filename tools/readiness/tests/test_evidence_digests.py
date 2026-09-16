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
"""
from __future__ import annotations

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
        self.assertEqual(mine, parsed["registered"],
                         "the instrument examined a different population than the ledger carrieth:\n" + out)
        self.assertEqual(parsed["registered"],
                         parsed["examined"] + len(parsed["unresolved"]) + len(parsed["unnamed"]),
                         "the denominator must account for every registered entry")

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
