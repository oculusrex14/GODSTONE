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

*** AND THE FIXTURE IS NOW A REAL REPO, BECAUSE THE OLD ONE MADE EVERY KILL VACUOUS. ***

*MEASURED, BEFORE THE FIX: this campaign built a scratch tree carrying ONLY `scripts/` and two `docs/` files, so the
gate's citation backstop could not resolve a SINGLE `path:` token -- **its own committed DISCHARGED obligations all
pointed at files the scratch tree did not have.*** *So the gate's `--check` returned `rc=1` for EVERY case AND for the
UNMUTATED baseline: **the campaign was green because the fixture was broken, not because any refusal was the one the
case was written to provoke.*** *A case "killed" by an unrelated citation error is not a kill, and the old test could
not tell the two apart because it compared a bare exit code.*

*** AND THE SAME MEASUREMENT FOUND A SECOND, SHARPER DEFECT: THE OLD CASES MUTATED THE WRONG FILE. *** *Five of them
edited the PERSISTED `finding_closure` -- which `build()` NEVER READS: the obligation states are authored in
`PARTIAL_OBLIGATIONS` in `scripts/build_structured_closure.py`, and the derivation is from THAT.* **So "reopen an
obligation" never reached the state the law judges, and the case was green only because the broken fixture reddened
everything.*** *The cases now mutate the GATE'S OWN SOURCE for obligation-state changes, and the persisted ledger only
for the drift cases that are genuinely about the persisted copy.*

**SO FOUR THINGS CHANGED, AND EACH CLOSES ONE HALF OF THE HOLE:**
  1. the fixture is a `git worktree add --detach` OF HEAD, so `path:`/`commit:`/`test:` citations resolve exactly as
     they do in the live tree;
  2. **CASE 0 IS THE UNMUTATED BASELINE**, and it MUST return `rc=0` with no `::error::` line -- *every later kill is
     judged against that, so a fixture that refuses everything fails the suite instead of passing it;*
  3. each case carries the REFUSAL CATEGORY it is supposed to provoke, parsed from the gate's own output, and a case
     that reddens for a DIFFERENT reason FAILS the suite -- *the campaign judges a refusal, it does not merely count a
     non-zero exit;*
  4. cases 12 and 13 AUTHOR an unresolved obligation in the gate's source after discharging every real one, so they
     keep testing the readiness law after the repository's own ten obligations close.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
GATE = REPO / "scripts" / "build_structured_closure.py"
CLOSURE = REPO / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"
LEDGER = REPO / "docs" / "remediation" / "REMEDIATION_STATE.json"

#: *** THE TREES THE GATE'S CITATION BACKSTOP RESOLVES AGAINST. *** *`path:` tokens are read from the fixture root, and
#: `test:` symbols are DEFINED under `ios/` or `android/`, so a fixture without them cannot judge a discharge at all.*
#: *`ios/` and `android/` are SYMLINKED because they are large and read-only here -- the gate only ever reads them.*
SYMLINKED_TREES = ("ios", "android", "content", "tools", "ci")
#: Trees COPIED rather than linked: the campaign mutates the gate's source and the ledger, so both must be private.
COPIED = ("scripts", "docs")


class _Fixture:
    """A disposable `git worktree` of HEAD, provisioned so the gate's own citations resolve."""

    def __init__(self) -> None:
        self._td = tempfile.TemporaryDirectory(prefix="godstone-closure-fixture-")
        self.root = Path(self._td.name) / "repo"

    def __enter__(self) -> "_Fixture":
        subprocess.run(["git", "worktree", "add", "--force", "--detach", str(self.root), "HEAD"],
                       cwd=str(REPO), check=True, capture_output=True, timeout=600)
        for tree in SYMLINKED_TREES:
            src, dst = REPO / tree, self.root / tree
            if src.exists() and not dst.exists():
                dst.symlink_to(src, target_is_directory=True)
        for tree in COPIED:
            src, dst = REPO / tree, self.root / tree
            if not src.is_dir():
                continue
            if dst.is_dir():
                shutil.rmtree(dst)
            shutil.copytree(src, dst, symlinks=True)
        return self

    def __exit__(self, *exc) -> bool:
        subprocess.run(["git", "worktree", "remove", "--force", str(self.root)],
                       cwd=str(REPO), capture_output=True, timeout=600)
        subprocess.run(["git", "worktree", "prune"], cwd=str(REPO), capture_output=True, timeout=600)
        self._td.cleanup()
        return False

    @property
    def gate(self) -> Path:
        return self.root / "scripts" / GATE.name

    def restore_gate(self) -> None:
        """*** RESET THE GATE SOURCE TO THE COMMITTED BYTES BEFORE EVERY CASE. ***
        *A source mutation left over from the previous case would change the next one's starting state, and the
        campaign would be measuring its own history rather than its mutations.*
        """
        self.gate.write_bytes(GATE.read_bytes())

    def ledger(self) -> dict:
        return json.loads((self.root / "docs/remediation" / LEDGER.name).read_text(encoding="utf-8"))

    def write_ledger(self, doc: dict) -> None:
        (self.root / "docs/remediation" / LEDGER.name).write_text(
            json.dumps(doc, indent=1, ensure_ascii=False), encoding="utf-8")

    def write_closure(self, doc: dict) -> None:
        (self.root / "docs/production-readiness" / CLOSURE.name).write_text(
            json.dumps(doc, indent=1), encoding="utf-8")

    def check(self) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(self.gate), "--check"],
                              capture_output=True, text=True, cwd=str(self.root), timeout=600)


_FIXTURE: "_Fixture | None" = None
_PRISTINE_LEDGER: str = ""


def setUpModule() -> None:
    global _FIXTURE, _PRISTINE_LEDGER
    _FIXTURE = _Fixture().__enter__()
    _PRISTINE_LEDGER = (_FIXTURE.root / "docs/remediation" / LEDGER.name).read_text(encoding="utf-8")


def tearDownModule() -> None:
    if _FIXTURE is not None:
        _FIXTURE.__exit__(None, None, None)


def _run(mutate, expect: str | tuple[str, ...]) -> tuple[bool, str]:
    """*** MUTATE THE PRISTINE FIXTURE, RUN `--check`, AND REQUIRE THE EXPECTED REFUSAL BY CATEGORY. ***

    *A case whose refusal is a DIFFERENT category than the one it was written to provoke is NOT killed: that is the
    whole repair, because the broken fixture used to redden every case with an unrelated citation error and the bare
    exit code could not tell.* **`expect` may name several acceptable categories where the gate legitimately refuses a
    mutation on more than one ground, but it always NAMES them.**
    """
    assert _FIXTURE is not None, "the module fixture must be up"
    _FIXTURE.restore_gate()
    _FIXTURE.write_ledger(json.loads(_PRISTINE_LEDGER))
    closure_doc = {"status": "REMEDIATION_IN_PROGRESS", "verified_fixed": 0}
    ledger = _FIXTURE.ledger()
    mutate(ledger, closure_doc)
    _FIXTURE.write_ledger(ledger)
    _FIXTURE.write_closure(closure_doc)
    proc = _FIXTURE.check()
    out = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode == 0:
        return False, "ESCAPED -- the gate returned rc=0 for this mutation"
    expected = (expect,) if isinstance(expect, str) else expect
    if any(needle in out for needle in expected):
        return True, ""
    return False, ("reddened for a DIFFERENT reason than the one it provokes -- expected one of "
                   f"{list(expected)}, got:\n" + out[:1500])


# ----------------------------------------------------------------------------------------------------------------
# The fixtures' own readers: the PERSISTED closure (for the drift cases), and the GATE SOURCE (for obligation states).
# ----------------------------------------------------------------------------------------------------------------

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


def _set_finding_status(ledger: dict, fid: str, status: str) -> None:
    """*** SET A FINDING'S RECORDED STATUS IN EVERY POPULATION THAT ALREADY CARRIETH IT. ***

    *`setdefault` was the old helper's defect: it INSERTED the finding into the population it was absent from, so
    `build()` refused with "appears in BOTH populations" -- **a refusal about the mutation's own bug rather than the
    defect the case was written to expose.*** *A status is only ever updated where the finding is already recorded.*
    """
    for group in (ledger["findings"], ledger["independent_audit_new_findings"]["findings"]):
        if fid in group:
            group[fid]["my_status"] = status


def _first_discharged_obligation_id(ledger: dict) -> str:
    """The id of a DISCHARGED obligation, read from the PERSISTED closure the gate derived."""
    for f in _finding_closure(ledger).values():
        for o in (f.get("internal_obligations") or []):
            if o.get("status") == "DISCHARGED":
                return o["id"]
    raise AssertionError("no DISCHARGED obligation to reopen")


def _finding_of_obligation(ledger: dict, oid: str) -> str:
    for fid, f in _finding_closure(ledger).items():
        for o in (f.get("internal_obligations") or []):
            if o.get("id") == oid:
                return fid
    raise AssertionError(f"no finding carries obligation {oid}")


def _obligation_list_block(text: str, fid: str) -> tuple[int, int]:
    """The `[start, end)` span of `fid`'s obligation list in the gate's source, by bracket depth."""
    anchor = f'"{fid}": ['
    start = text.find(anchor)
    if start < 0:
        raise AssertionError(f"the gate source carries no obligation list for {fid}")
    i = text.index("[", start)
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "[":
            depth += 1
        elif text[j] == "]":
            depth -= 1
            if depth == 0:
                return start, j + 1
    raise AssertionError(f"the obligation list for {fid} is unterminated")


def _gate_set_obligation_status(oid: str, status: str) -> None:
    """*** THE OBLIGATION STATES LIVE IN THE GATE'S OWN SOURCE, SO THAT SOURCE IS THE INPUT TO MUTATE. ***

    *THE OLD CAMPAIGN MUTATED ONLY THE PERSISTED `finding_closure`, WHICH `build()` NEVER READS -- the derivation comes
    from `PARTIAL_OBLIGATIONS` in `scripts/build_structured_closure.py`.* **So "reopen an obligation" had to mean
    editing the gate's constant, or the mutation never reached the state the law judges.*** *Anchored on the
    obligation's own id, so it can only touch the intended entry.*
    """
    assert _FIXTURE is not None
    text = _FIXTURE.gate.read_text(encoding="utf-8")
    pattern = re.compile(r'("id":\s*"' + re.escape(oid) + r'",.*?"status":\s*")([A-Z]+)(")', re.S)
    m = pattern.search(text)
    if not m:
        raise AssertionError(f"the gate source carries no `status` for obligation {oid}")
    new_text = text[:m.start(2)] + status + text[m.end(2):]
    if new_text == text:
        raise AssertionError(f"the gate mutation for {oid} was a no-op")
    _FIXTURE.gate.write_text(new_text, encoding="utf-8")


def _gate_discharge_obligation_list(fid: str) -> None:
    """Discharge EVERY obligation the gate's source carries for `fid`."""
    assert _FIXTURE is not None
    text = _FIXTURE.gate.read_text(encoding="utf-8")
    start, end = _obligation_list_block(text, fid)
    block = text[start:end]
    new_block = re.sub(r'("status":\s*")(OPEN|PARTIAL)(")',
                       lambda m: m.group(1) + "DISCHARGED" + m.group(3), block)
    _FIXTURE.gate.write_text(text[:start] + new_block + text[end:], encoding="utf-8")


def _gate_insert_obligation(fid: str, oid: str, status: str) -> None:
    """Insert one obligation into `fid`'s list in the gate's source."""
    assert _FIXTURE is not None
    text = _FIXTURE.gate.read_text(encoding="utf-8")
    start, end = _obligation_list_block(text, fid)
    block = text[start:end]
    insert_at = block.rindex("]")
    entry = (f'\n        {{"id": "{oid}", "text": "an inserted obligation", '
             f'"status": "{status}", "evidence": []}},')
    _FIXTURE.gate.write_text(text[:start] + block[:insert_at] + entry + "\n    " + block[insert_at:] + text[end:],
                             encoding="utf-8")


# ----------------------------------------------------------------------------------------------------------------
# The mutations. Each is `mutate(ledger, closure_doc)`, and it may also edit the gate's own source.
# ----------------------------------------------------------------------------------------------------------------

def _mut_one_open(ledger, closure_doc):
    """1. ONE OPEN OBLIGATION. *Reopen a discharged one, let its finding follow, and CLAIM READY -- the only defect is live work.*"""
    oid = _first_discharged_obligation_id(ledger)
    fid = _finding_of_obligation(ledger, oid)
    _set_finding_status(ledger, fid, "PARTIAL")
    _gate_set_obligation_status(oid, "OPEN")
    closure_doc["status"] = "READY_FOR_EXTERNAL_REAUDIT"


def _mut_one_partial(ledger, closure_doc):
    """2. ONE PARTIAL OBLIGATION. ***THE SPELLING THE OLD `== "OPEN"` FILTER LOST. ***"""
    oid = _first_discharged_obligation_id(ledger)
    fid = _finding_of_obligation(ledger, oid)
    _set_finding_status(ledger, fid, "PARTIAL")
    _gate_set_obligation_status(oid, "PARTIAL")
    closure_doc["status"] = "READY_FOR_EXTERNAL_REAUDIT"


def _mut_open_finding_zero_obligations(ledger, closure_doc):
    """3. A PARTIAL/OPEN FINDING WITH ZERO UNRESOLVED OBLIGATIONS. *Open with nothing a builder could execute.*"""
    fid, _f = _first_with_obligations(ledger)
    _set_finding_status(ledger, fid, "OPEN")
    _gate_discharge_obligation_list(fid)


def _mut_complete_finding_over_open_obligation(ledger, closure_doc):
    """4. ***A COMPLETE FINDING WITH AN OPEN OBLIGATION -- THE DIRECTION THAT CLAIMETH WORK IS FINISHED.***

    *This is the case my FIRST version of the consistency rule PERMITTED: it refused "open with nothing to do" and
    allowed "done with work outstanding".* **A rule that guardeth the state nobody reaches while missing the state a
    builder is tempted to write is worse than none, because it readeth as coverage.**
    """
    oid = _first_discharged_obligation_id(ledger)
    fid = _finding_of_obligation(ledger, oid)
    _set_finding_status(ledger, fid, "FIX_SUBMITTED")
    _gate_set_obligation_status(oid, "OPEN")


def _mut_unknown_obligation_status(ledger, closure_doc):
    """5. AN UNKNOWN OBLIGATION STATUS. *Neither terminal nor unresolved -- guessing is a false reading, so it is NAMED.*"""
    _gate_set_obligation_status(_first_discharged_obligation_id(ledger), "DONE")


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
    raise AssertionError("no DISCHARGED obligation to change")


def _mut_verified_fixed(ledger, closure_doc):
    """11. `verified_fixed = 1`. ***ONLY THE INDEPENDENT AUDITOR MAY WRITE IT, SO THE BUILDER MUST REFUSE TO CARRY IT.***"""
    closure_doc["verified_fixed"] = 1


def _close_the_real_population(ledger) -> str:
    """*** DISCHARGE EVERY REAL OBLIGATION IN THE GATE'S SOURCE, AND AUTHOR ONE UNRESOLVED ONE INSTEAD. ***

    *Cases 12 and 13 must keep testing the readiness law AFTER the ten real obligations close, so they cannot rely on
    live open work existing.* **So they close the real population, flip every affected finding to `FIX_SUBMITTED`, and
    INSERT one explicit unresolved obligation -- which puts the law in front of work the case authored rather than work
    that happened to still be open the day it was written.***
    """
    assert _FIXTURE is not None
    text = _FIXTURE.gate.read_text(encoding="utf-8")
    fid = None
    for candidate in re.findall(r'"(GS-[A-Z0-9\-]+)": \[', text):
        fid = candidate
        break
    if fid is None:
        raise AssertionError("the gate source carries no GS-* obligation lists")
    # Every GS-* list is discharged...
    for name in set(re.findall(r'"(GS-[A-Z0-9\-]+)": \[', text)):
        _gate_discharge_obligation_list(name)
    # ... and ONE unresolved obligation is authored, so the law has work before it.
    _gate_insert_obligation(fid, "case12.inserted-unresolved", "OPEN")
    # Every finding whose obligations are now all terminal must record FIX_SUBMITTED, or its OWN
    # recorded status would disagree with its set -- and the case would redden on the wrong rule.
    for group in (ledger["findings"], ledger["independent_audit_new_findings"]["findings"]):
        for f in group.values():
            if f.get("my_status") in ("OPEN", "PARTIAL"):
                f["my_status"] = "FIX_SUBMITTED"
    # The authored finding must stay PARTIAL, so its open obligation is consistent with its status.
    _set_finding_status(ledger, fid, "PARTIAL")
    return fid


def _mut_ready_over_work(ledger, closure_doc):
    """12. FORCE READY while an AUTHORED unresolved obligation standeth."""
    _close_the_real_population(ledger)
    closure_doc["status"] = "READY_FOR_EXTERNAL_REAUDIT"


def _mut_complete_over_work(ledger, closure_doc):
    """13. FORCE COMPLETE while an AUTHORED unresolved obligation standeth."""
    _close_the_real_population(ledger)
    closure_doc["status"] = "COMPLETE"


#: (name, mutation, expected refusal category -- read from the gate's own output).
CASES = (
    ("1. one OPEN obligation", _mut_one_open, "structured internal obligation(s) are OPEN"),
    ("2. one PARTIAL obligation", _mut_one_partial, "structured internal obligation(s) are OPEN"),
    ("3. OPEN finding with zero unresolved obligations", _mut_open_finding_zero_obligations,
     "recorded internal status is 'OPEN' while ALL"),
    ("4. COMPLETE finding with an OPEN obligation", _mut_complete_finding_over_open_obligation,
     "obligations are UNRESOLVED"),
    ("5. unknown obligation status", _mut_unknown_obligation_status, "carrieth obligation status"),
    ("6. unknown finding status", _mut_unknown_finding_status, "has no structured mapping"),
    ("7. stale persisted count", _mut_stale_count, "structured_counts."),
    ("8. missing persisted obligation", _mut_missing_obligation, "MISSING from the persisted closure"),
    ("9. orphan persisted obligation", _mut_orphan_obligation, "ORPHANED from the derived closure"),
    ("10. changed persisted obligation status", _mut_changed_obligation_status, "status persisted"),
    ("11. verified_fixed = 1", _mut_verified_fixed, "verified_fixed"),
    ("12. force READY with unresolved internal work", _mut_ready_over_work,
     "BOARD1_CLOSURE.status is 'READY_FOR_EXTERNAL_REAUDIT' while"),
    ("13. force COMPLETE with unresolved internal work", _mut_complete_over_work,
     "BOARD1_CLOSURE.status is 'COMPLETE' while"),
)


class ClosureStateMutations(unittest.TestCase):
    """*** EVERY SHAPE OF FALSE CLOSURE MUST BE REFUSED, PROVEN AGAINST THE REAL GATE. ***"""

    def test_the_campaign_is_the_required_size(self) -> None:
        """*** AT LEAST THIRTEEN MUTATIONS, EVERY ONE CARRYING AN EXPECTED CATEGORY. ***

        *The size is the mission's floor; the CATEGORY is what makes a kill attributable -- **so both are asserted here
        rather than assumed from the tuple's shape.***
        """
        self.assertGreaterEqual(len(CASES), 13, "the mission's required campaign is at least 13 mutations")
        for name, _mutate, expect in CASES:
            self.assertTrue(expect, f"{name}: every case must carry an expected refusal category")

    def test_case_0_the_unmutated_fixture_is_green(self) -> None:
        """*** THE BASELINE, WITHOUT WHICH EVERY OTHER KILL IS UNATTRIBUTABLE. ***

        *MEASURED, BEFORE THE FIX: the scratch fixture could not resolve a single citation, so `--check` returned
        `rc=1` for the UNMUTATED ledger too -- **which meant the campaign's thirteen "kills" were all the same fixture
        defect, and the test read green.*** *This case is the negative control for that: a fixture that refuses
        everything FAILS here rather than passing in `test_every_required_mutation_is_killed_for_its_own_reason`.*
        """
        assert _FIXTURE is not None
        _FIXTURE.restore_gate()
        _FIXTURE.write_ledger(json.loads(_PRISTINE_LEDGER))
        _FIXTURE.write_closure({"status": "REMEDIATION_IN_PROGRESS", "verified_fixed": 0})
        proc = _FIXTURE.check()
        out = (proc.stdout or "") + (proc.stderr or "")
        self.assertEqual(0, proc.returncode,
                         "the UNMUTATED fixture must satisfy the closure law, or no kill below is attributable:\n"
                         + out[:4000])
        self.assertNotIn("::error::", out, "the unmutated fixture must produce no refusal")

    def test_every_required_mutation_is_killed_for_its_own_reason(self) -> None:
        """*** EVERY MUTATION MUST BE REFUSED, AND REFUSED FOR THE REASON IT PROVOKES. ***"""
        escaped: list[str] = []
        for name, mutate, expect in CASES:
            killed, detail = _run(mutate, expect)
            if not killed:
                escaped.append(f"{name}: {detail}")
        self.assertEqual(escaped, [],
                         "these mutations ESCAPED or reddened for the wrong reason:\n" + "\n".join(escaped))

    def test_the_live_gate_accepts_the_committed_tree(self) -> None:
        """*A campaign that reddened the real tree would prove the campaign, not the tree.*"""
        proc = subprocess.run([sys.executable, str(GATE), "--check"],
                              capture_output=True, text=True, cwd=str(REPO), timeout=600)
        self.assertEqual(proc.returncode, 0,
                         "the committed tree must satisfy its own closure law:\n" + proc.stdout)


if __name__ == "__main__":
    unittest.main()
