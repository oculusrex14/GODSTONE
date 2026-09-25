"""*** THE CLOSURE PLANE MUST REFUSE EVERY SHAPE OF FALSE CLOSURE. ***

*THE CLOSURE MISSION'S SECTION 19 LISTETH THE REQUIRED KILLS, AND THIS FILE CARRIETH THEM AS A PERMANENT, RE-RUNNABLE
CAMPAIGN AGAINST **A SCRATCH COPY OF THE REAL GATE** -- never the live tree.* ***THAT DISTINCTION IS A CORRECTNESS
REQUIREMENT, NOT TIDINESS: a guard that mutates the thing it guards is the defect, not the check, and an interrupted
run would leave `READY` sitting over live work.*** *The scratch tree is destroyed with the `TemporaryDirectory`, so even
a crash mid-case cannot touch the repository.*

*** AND BOTH CONSISTENCY DIRECTIONS ARE HERE BECAUSE MY FIRST RULE COVERED ONLY ONE OF THEM.*** *It refused an `OPEN`
finding whose obligations were all terminal, and PERMITTED a `COMPLETE` finding over an UNRESOLVED obligation --*
**the direction that matters most, because it is the one that CLAIMETH WORK IS FINISHED.** *A mutation found that gap,
which is why the mission's case 4 is listed beside its case 3 rather than trusting either alone.*
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
GATE = REPO / "scripts" / "build_structured_closure.py"
CLOSURE = REPO / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"
LEDGER = REPO / "docs" / "remediation" / "REMEDIATION_STATE.json"


def _run(name: str, mutate) -> bool:
    """Mutate a SCRATCH copy of the real gate's inputs and require `--check` to refuse. True iff killed."""
    with tempfile.TemporaryDirectory() as td:
        root = Path(td) / "repo"
        for sub in ("scripts", "docs/production-readiness", "docs/remediation"):
            (root / sub).mkdir(parents=True)
        (root / "scripts" / GATE.name).write_bytes(GATE.read_bytes())
        (root / "docs/production-readiness" / CLOSURE.name).write_bytes(CLOSURE.read_bytes())
        ledger = json.loads(LEDGER.read_text(encoding="utf-8"))
        closure_doc = {"status": "REMEDIATION_IN_PROGRESS", "verified_fixed": 0}
        mutate(ledger, closure_doc)
        (root / "docs/remediation" / LEDGER.name).write_text(
            json.dumps(ledger, indent=1, ensure_ascii=False), encoding="utf-8")
        (root / "docs/production-readiness" / CLOSURE.name).write_text(
            json.dumps(closure_doc, indent=1), encoding="utf-8")
        proc = subprocess.run(
            [sys.executable, str(root / "scripts" / GATE.name), "--check"],
            capture_output=True, text=True, cwd=str(root), timeout=600)
        return proc.returncode != 0


def _finding_closure(ledger: dict) -> dict:
    return ledger["current_assessment"]["finding_closure"]


def _first_with_obligations(ledger: dict):
    """Any finding that CARRIES obligations -- many findings carry none."""
    for fid, f in _finding_closure(ledger).items():
        if f.get("internal_obligations"):
            return fid, f
    raise AssertionError("the persisted closure carries no obligations at all")


def _first_with_a_discharged(ledger: dict):
    """*** A FINDING THAT ACTUALLY CARRIETH A DISCHARGED OBLIGATION. ***

    *MY FIRST VERSION USED `_first_with_obligations`, WHICH RETURNETH THE FIRST FINDING WITH ANY OBLIGATIONS -- and the
    first such finding is `GS-ARCHIVE-005`, whose single obligation is `OPEN`.* **So the case died on
    "no DISCHARGED obligation to reopen" rather than exercising the gate: a mutation that CANNOT BE APPLIED IS NOT A
    KILLED MUTATION, IT IS A BROKEN EXPERIMENT, and the difference is exactly the class this campaign existeth to
    remove.*** *The helper now finds a finding that can actually carry the mutation.*
    """
    for fid, f in _finding_closure(ledger).items():
        if any(o.get("status") == "DISCHARGED" for o in (f.get("internal_obligations") or [])):
            return fid, f
    raise AssertionError("no finding carries a DISCHARGED obligation")


def _mut_one_open(ledger, closure_doc):
    """1. ONE OPEN OBLIGATION. *Reopen a discharged one and let its finding follow, so the ONLY defect is the open work.*"""
    fid, f = _first_with_a_discharged(ledger)
    for o in f["internal_obligations"]:
        if o["status"] == "DISCHARGED":
            o["status"] = "OPEN"
            ledger["findings"].setdefault(fid, {})["my_status"] = "PARTIAL"
            ledger["independent_audit_new_findings"]["findings"].setdefault(fid, {})["my_status"] = "PARTIAL"
            return
    raise AssertionError("no DISCHARGED obligation to reopen")


def _mut_one_partial(ledger, closure_doc):
    """2. ONE PARTIAL OBLIGATION. ***THE SPELLING THE OLD `== "OPEN"` FILTER LOST. ***"""
    fid, f = _first_with_a_discharged(ledger)
    for o in f["internal_obligations"]:
        if o["status"] == "DISCHARGED":
            o["status"] = "PARTIAL"
            ledger["findings"].setdefault(fid, {})["my_status"] = "PARTIAL"
            ledger["independent_audit_new_findings"]["findings"].setdefault(fid, {})["my_status"] = "PARTIAL"
            return
    raise AssertionError("no DISCHARGED obligation to mark PARTIAL")


def _mut_ready_over_work(ledger, closure_doc):
    """12. FORCE READY while unresolved internal work standeth."""
    closure_doc["status"] = "READY_FOR_EXTERNAL_REAUDIT"


def _mut_complete_over_work(ledger, closure_doc):
    """13. FORCE COMPLETE while unresolved internal work standeth."""
    closure_doc["status"] = "COMPLETE"


def _mut_unknown_obligation_status(ledger, closure_doc):
    """5. AN UNKNOWN OBLIGATION STATUS. *Neither terminal nor unresolved -- guessing is a false reading, so it is NAMED.*"""
    _, f = _first_with_obligations(ledger)
    f["internal_obligations"][0]["status"] = "DONE"


def _mut_unknown_finding_status(ledger, closure_doc):
    """6. AN UNKNOWN FINDING STATUS."""
    ledger["findings"]["GS-ARCHIVE-005"]["my_status"] = "TOTALLY_DONE"


def _mut_stale_count(ledger, closure_doc):
    """7. A STALE PERSISTED COUNT."""
    ledger["current_assessment"]["structured_counts"]["internal_obligations_open"] += 1


def _mut_missing_obligation(ledger, closure_doc):
    """8. A MISSING PERSISTED OBLIGATION."""
    _, f = _first_with_obligations(ledger)
    f["internal_obligations"].pop()


def _mut_orphan_obligation(ledger, closure_doc):
    """9. AN ORPHAN PERSISTED OBLIGATION."""
    _, f = _first_with_obligations(ledger)
    f["internal_obligations"].append({"id": "orphan.not-in-derivation", "status": "OPEN"})


def _mut_changed_obligation_status(ledger, closure_doc):
    """10. A CHANGED PERSISTED OBLIGATION STATUS."""
    _, f = _first_with_a_discharged(ledger)
    for o in f["internal_obligations"]:
        if o["status"] == "DISCHARGED":
            o["status"] = "OPEN"
            return


def _mut_verified_fixed(ledger, closure_doc):
    """11. `verified_fixed = 1`. ***ONLY THE INDEPENDENT AUDITOR MAY WRITE IT, SO THE BUILDER MUST REFUSE TO CARRY IT.***"""
    closure_doc["verified_fixed"] = 1


def _mut_complete_finding_over_open_obligation(ledger, closure_doc):
    """4. ***A COMPLETE FINDING WITH AN OPEN OBLIGATION -- THE DIRECTION THAT CLAIMETH WORK IS FINISHED.***

    *This is the case my FIRST version of the consistency rule PERMITTED: it refused "open with nothing to do" and
    allowed "done with work outstanding".* **A rule that guardeth the state nobody reaches while missing the state a
    builder is tempted to write is worse than none, because it readeth as coverage.**
    """
    _, f = _first_with_obligations(ledger)
    for o in f["internal_obligations"]:
        o["status"] = "DISCHARGED"
    f["internal_obligations"][0]["status"] = "OPEN"
    f["internal_status"] = "COMPLETE"


def _mut_open_finding_zero_obligations(ledger, closure_doc):
    """3. A PARTIAL/OPEN FINDING WITH ZERO UNRESOLVED OBLIGATIONS. *Open with nothing a builder could execute.*"""
    _, f = _first_with_obligations(ledger)
    for o in f["internal_obligations"]:
        o["status"] = "DISCHARGED"
    f["internal_status"] = "OPEN"


CASES = (
    ("1. one OPEN obligation", _mut_one_open),
    ("2. one PARTIAL obligation", _mut_one_partial),
    ("3. OPEN finding with zero unresolved obligations", _mut_open_finding_zero_obligations),
    ("4. COMPLETE finding with an OPEN obligation", _mut_complete_finding_over_open_obligation),
    ("5. unknown obligation status", _mut_unknown_obligation_status),
    ("6. unknown finding status", _mut_unknown_finding_status),
    ("7. stale persisted count", _mut_stale_count),
    ("8. missing persisted obligation", _mut_missing_obligation),
    ("9. orphan persisted obligation", _mut_orphan_obligation),
    ("10. changed persisted obligation status", _mut_changed_obligation_status),
    ("11. verified_fixed = 1", _mut_verified_fixed),
    ("12. force READY with unresolved internal work", _mut_ready_over_work),
    ("13. force COMPLETE with unresolved internal work", _mut_complete_over_work),
)


class ClosureStateMutations(unittest.TestCase):
    """*** EVERY SHAPE OF FALSE CLOSURE MUST BE REFUSED, PROVEN AGAINST THE REAL GATE. ***"""

    def test_the_campaign_is_the_required_size(self) -> None:
        self.assertGreaterEqual(len(CASES), 13, "the mission's required campaign is at least 13 mutations")

    def test_every_required_mutation_is_killed(self) -> None:
        escaped = [name for name, mutate in CASES if not _run(name, mutate)]
        self.assertEqual(escaped, [], f"these mutations ESCAPED and must be refused: {escaped}")

    def test_the_live_gate_accepts_the_committed_tree(self) -> None:
        """*A campaign that reddened the real tree would prove the campaign, not the tree.*"""
        proc = subprocess.run([sys.executable, str(GATE), "--check"],
                              capture_output=True, text=True, cwd=str(REPO), timeout=600)
        self.assertEqual(proc.returncode, 0,
                         "the committed tree must satisfy its own closure law:\n" + proc.stdout)


if __name__ == "__main__":
    unittest.main()
