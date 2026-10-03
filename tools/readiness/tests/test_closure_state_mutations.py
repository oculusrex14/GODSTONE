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
SYMLINKED_TREES = ("ios", "android", "content", "tools")
#: Trees COPIED rather than linked: the campaign mutates the gate's source and the ledger, so both must be private.
COPIED = ("scripts", "docs")
#: *** `ci/` IS REFRESHED FROM THE LIVE AUTHORITY, NOT TRUSTED FROM THE WORKTREE'S HEAD. ***
#:
#: *MEASURED (bg741): the worktree is detached at HEAD, so it ALREADY carrieth a `ci/` directory -- and because that
#: directory existed, the old symlink loop skipped it, leaving a STALE `check_candidate_binding.py` (no
#: `FREEZE_ATTESTATION_SUCCESSOR_PATH`).* **The closure gate imports the freeze authority for the current-binding law,
#: so every seeded case then died on 'the canonical freeze authority could not be imported'.** *Copied from the live
#: tree, the scratch `ci/` is the same bytes the gate under test reads in production -- a real import, never a test
#: alias.*
REFRESHED_TREES = ("ci",)



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
        for tree in COPIED + REFRESHED_TREES:
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

    def rederive(self) -> None:
        """*** RE-DERIVE THE PERSISTED BLOCK FROM THE (SEEDED) SOURCE, SO A CASE STARTS COHERENT. ***

        *A case that seeds a synthetic DISCHARGED obligation into the gate's source MUST bring the persisted
        `finding_closure`/`structured_counts` with it, or the first refusal would be the drift rule rather than the
        law under test.* **`--write` is the gate's own deriver, so the fixture useth the gate rather than a
        hand-mirrored copy.**

        *** AND THE RECORDED STATUSES ARE ALIGNED FIRST, IN THE TRACK EACH FINDING ACTUALLY LIVES IN. ***
        *MEASURED: a seeded/mutated source can leave an UNRELATED finding whose obligations are all terminal while its
        recorded status still says OPEN/PARTIAL -- and the gate then refuses on THAT finding rather than on the case's
        own defect, so the case reddens for the wrong reason.* **The alignment useth the SCRATCH gate's OWN derivation
        (including its scoped demotion), so each finding's recorded status follows the set the scratch gate will read,
        and it touches ONLY the throwaway fixture's ledger.**
        """
        self.align_recorded_statuses()
        proc = subprocess.run([sys.executable, str(self.gate), "--write"],
                              capture_output=True, text=True, cwd=str(self.root), timeout=600)
        if proc.returncode != 0:
            raise AssertionError(f"the fixture could not re-derive its persisted block (rc={proc.returncode})\n"
                                 f"--- stdout ---\n{(proc.stdout or '')[-2000:]}\n"
                                 f"--- stderr ---\n{(proc.stderr or '')[-2000:]}")

    def align_recorded_statuses(self) -> None:
        """*** THE SCRATCH LEDGER'S RECORDED STATUSES FOLLOW THE SCRATCH GATE'S CANONICAL DERIVATION. ***

        *Reads the scratch gate module, runs its OWN `_with_authored_discharges` over each finding's authored
        obligations, and corrects a contradiction in the track the finding actually lives in:* **an all-terminal set
        over an OPEN/PARTIAL recording becomes FIX_SUBMITTED; an unresolved set over a FIX_SUBMITTED recording becomes
        PARTIAL.** *A finding with no authored obligations keeps its recorded status (terminality cannot be derived
        from a set that does not exist), and the live repository ledger is never touched.*
        """
        gate_mod = _load_scratch_gate(self.gate)
        ledger = self.ledger()
        for track in (ledger["findings"], ledger["independent_audit_new_findings"]["findings"]):
            for fid, entry in track.items():
                obligations = gate_mod._with_authored_discharges(gate_mod.PARTIAL_OBLIGATIONS.get(fid, []))
                if not obligations:
                    continue
                terminal = gate_mod.obligations_are_terminal({"internal_obligations": obligations})
                recorded = entry.get("my_status")
                if terminal and recorded in ("OPEN", "PARTIAL"):
                    entry["my_status"] = "FIX_SUBMITTED"
                elif not terminal and recorded == "FIX_SUBMITTED":
                    entry["my_status"] = "PARTIAL"
        self.write_ledger(ledger)


_FIXTURE: "_Fixture | None" = None
_PRISTINE_LEDGER: str = ""


def _load_scratch_gate(path: Path):
    """*** THE SCRATCH GATE'S OWN MODULE -- THE CANONICAL DERIVATION, READ FROM THE FIXTURE'S SOURCE. ***
    *Never the live gate: a seeded case mutates the scratch source, and the alignment must read exactly what the
    scratch `--write` will read.*"""
    import importlib.util
    spec = importlib.util.spec_from_file_location("scratch_closure_gate", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def setUpModule() -> None:
    global _FIXTURE, _PRISTINE_LEDGER
    _FIXTURE = _Fixture().__enter__()
    _PRISTINE_LEDGER = (_FIXTURE.root / "docs/remediation" / LEDGER.name).read_text(encoding="utf-8")


def tearDownModule() -> None:
    if _FIXTURE is not None:
        _FIXTURE.__exit__(None, None, None)


def _run(mutate, expect: str | tuple[str, ...], seed=None) -> tuple[bool, str]:
    """*** MUTATE THE PRISTINE (OR SEEDED) FIXTURE, RUN `--check`, AND REQUIRE THE EXPECTED REFUSAL. ***

    *A case whose refusal is a DIFFERENT category than the one it was written to provoke is NOT killed: that is the
    whole repair, because the broken fixture used to redden every case with an unrelated citation error and the bare
    exit code could not tell.* **`expect` may name several acceptable categories where the gate legitimately refuses a
    mutation on more than one ground, but it always NAMES them.**

    *** AND A CASE THAT NEEDS A DISCHARGED OBLIGATION SUPPLIETH ITS OWN. *** *The live tree carrieth 35 OPEN
    obligations and ZERO DISCHARGED (the 2026-10-02 reopen), so `seed` authoriseth the campaign's OWN synthetic
    baseline in the scratch source and re-deriveth the persisted block -- the case then mutates a state the CAMPAIGN
    authored, never one that happened to be open the day it was written.*
    """
    assert _FIXTURE is not None, "the module fixture must be up"
    _FIXTURE.restore_gate()
    # *** THE LEDGER IS RESET FROM PRISTINE BEFORE EVERY CASE, SEEDED OR NOT. ***
    # *A seeded case must not inherit the previous case's mutation -- the fixture would then be measuring its own
    # history, and independence between cases is what makes each kill attributable.*
    _FIXTURE.write_ledger(json.loads(_PRISTINE_LEDGER))
    if seed is not None:
        seed()
        _FIXTURE.rederive()
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
    # *** A REFUSAL MUST BE ATTRIBUTABLE, SO THE STREAM THAT ACTUALLY CARRIETH IT IS REPORTED. ***
    # *MEASURED: a fixture that failed in its own seeding phase (rc != 0) with an EMPTY stdout reported only
    # "reddened for a DIFFERENT reason ... got:" -- the cause lived on stderr and was thrown away.* **Both streams, the
    # exit code and the case's own seed state are carried, so a fixture defect and a law kill are distinguishable.**
    return False, ("reddened for a DIFFERENT reason than the one it provokes -- expected one of "
                   f"{list(expected)}; rc={proc.returncode} seeded={seed is not None}\n"
                   f"--- stdout ---\n{(proc.stdout or '')[:1500]}\n"
                   f"--- stderr ---\n{(proc.stderr or '')[:1500]}")


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


#: *** THE CAMPAIGN'S OWN TERMINAL SUBJECT, AND THE CASES THAT NEED IT. ***
#: *The 2026-10-02 reopen left production with 35 OPEN obligations and ZERO DISCHARGED, so the cases whose subject IS
#: a discharged obligation author their own (`_seed_synthetic_discharged_obligation`) and name it BY CONSTANT -- the
#: persisted copy carrieth it demoted to OPEN (that is the production law), so the SOURCE's literal is the authority
#: for these cases.*
SYNTHETIC_FINDING = "GS-ARCHIVE-005"
SYNTHETIC_OBLIGATION = "campaign.synthetic-discharged"


def _future_attestation_path() -> str:
    """*** THE PROSPECTIVE ATTESTATION PATH, READ FROM THE ONE CANONICAL AUTHORITY. ***

    *The closure law now REQUIRES a current discharge binding to name the path the freeze WILL write
    (`ci/check_candidate_binding.FREEZE_ATTESTATION_SUCCESSOR_PATH`) and refuses the historical rc14 document.* **So a
    scratch fixture that bound rc14 would make its own baseline refusable and every seeded case an unattributable
    red.** *The constant is IMPORTED here, never restated, so a drift in the authority reddens the fixture rather
    than hiding behind a stale literal in the campaign.*
    """
    sys.path.insert(0, str(REPO / "ci"))
    import check_candidate_binding as _ccb  # noqa: PLC0415 - the ONE authority for the freeze paths
    return _ccb.FREEZE_ATTESTATION_SUCCESSOR_PATH


SEEDED_CASES = frozenset({
    "1. one OPEN obligation",
    "2. one PARTIAL obligation",
    "3. OPEN finding with zero unresolved obligations",
    "4. COMPLETE finding with an OPEN obligation",
    "5. unknown obligation status",
    # *** CASE 10 MUTATES THE PERSISTED STATUS *OF THE CAMPAIGN'S OWN SEEDED OBLIGATION*. ***
    # *MEASURED (bg739): the case rewrites `campaign.synthetic-discharged`'s persisted state, but the production
    # register carrieth no such obligation -- so without the seed the case died on "no campaign.synthetic-discharged to
    # change" rather than exercising the canonical status-drift refusal.* **Seeded, the persisted copy carrieth the
    # obligation (demoted to OPEN by the production law), the case rewrites it to a DIFFERENT legal state, and the
    # drift rule refuseth it BY NAME -- the case's own intended kill.**
    "10. changed persisted obligation status",
})


def _author_semantics_into_source(text: str, oid: str) -> str:
    """*** AUTHOR THE FULL TERMINAL SCHEMA INTO THE SCRATCH SOURCE FOR ONE OBLIGATION. ***

    *An id that the scratch gate will derive as DISCHARGED must carry every field `_discharge_block_problems`
    requireth, or the scratch `--check` refuseth it with "DISCHARGED but carrieth NO `structured_discharge` block" --
    a fixture defect, not the case's kill.* **The schema is inserted immediately after the obligation's id; an entry
    that already carrieth one is left alone.** *The block binds the prospective attestation path read from the
    canonical authority, never the historical rc14 document.*
    """
    anchor = f'"id": "{oid}"'
    start = text.find(anchor)
    if start < 0:
        return text
    rest = text[start + len(anchor):]
    next_id = rest.find('"id": "')
    entry_text = rest[:next_id if next_id != -1 else 1500]
    if '"structured_discharge"' in entry_text:
        return text
    insert_at = text.find(",", start)
    if insert_at < 0:
        raise AssertionError(f"the authored entry for {oid} carries no field separator")
    block = (
        ', "structured_discharge": {"behavior": "x", "implementation": "x", "reachability": "production", '
        '"test": "x", "positive": "x", "mutation": "x", "exact_result": "x", '
        '"candidate_binding": {"external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", '
        '"attestation": "' + _future_attestation_path() + '"}}')
    return text[:insert_at] + block + text[insert_at:]


def _force_status_in_source(text: str, oid: str, status: str) -> str:
    """Set one obligation's authored `status` in the SCRATCH source (anchored on its own id)."""
    start = text.find(f'"id": "{oid}"')
    if start < 0:
        return text
    match = re.compile(r'"status":\s*"([A-Z]+)"').search(text, start)
    if not match:
        raise AssertionError(f"the authored entry for {oid} carries no status")
    return text[:match.start(1)] + status + text[match.end(1):]


def _seed_synthetic_discharged_obligation(fid: str = SYNTHETIC_FINDING, *, keep_finding_ids: bool = False) -> None:
    """*** THE CAMPAIGN AUTHORISETH ITS OWN TERMINAL OBLIGATION; PRODUCTION KEEPETH ITS 35 OPEN. ***

    *The 2026-10-02 reopen left the live register with ZERO DISCHARGED obligations, so every case that needeth one
    (reopen one, set one PARTIAL, change a persisted status, an unknown status, a non-terminal block) would die on
    "no DISCHARGED obligation to reopen" -- **a mutation that CANNOT BE APPLIED IS A BROKEN EXPERIMENT, not a kill.***
    **So the campaign authors ONE synthetic DISCHARGED obligation in the SCRATCH gate's own source, with the FULL
    schema the terminal boundary requires** *(behaviour/implementation/reachability=production/test/positive/mutation/
    exact result, an external `candidate_binding` with `external_manifest` and `attestation` and NO `candidate_sha`,
    and a typed, resolving citation so the citation backstop is exercised)*, **neutralizeth the historical DEMOTION
    for exactly the ids this case needeth** *(the production demotion is `_with_authored_discharges`, which would turn
    every source DISCHARGED into OPEN and make a terminal state unreachable in the scratch fixture)*, **and then
    re-deriveth the persisted block.** *A synthetic proof object inside a throwaway fixture is not a production
    discharge and cannot be mistaken for one: the live tree is never written.*

    `keep_finding_ids=True` also preserveth the finding's OWN obligation states through the derivation -- the shape
    case 3 needeth (a finding whose whole set is terminal).
    """
    assert _FIXTURE is not None
    text = _FIXTURE.gate.read_text(encoding="utf-8")
    start, end = _obligation_list_block(text, fid)  # bracket-DEPTH scan: evidence lists must not end the span
    insert_at = end - 1  # just before the list's own closing bracket
    entry = (
        '\n        {"id": "campaign.synthetic-discharged", '
        '"text": "A synthetic obligation the campaign discharges so the closure law carrieth a terminal subject.", '
        '"status": "DISCHARGED", "evidence": ["`path:scripts/build_structured_closure.py`"], '
        '"structured_discharge": {'
        '"behavior": "x", "implementation": "x", "reachability": "production", "test": "x", '
        '"positive": "x", "mutation": "x", "exact_result": "x", '
        '"candidate_binding": {"external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json", '
        '"attestation": "' + _future_attestation_path() + '"}}},')
    text = text[:insert_at] + entry + text[insert_at:]
    # *** THE DEMOTION IS NEUTRALIZED FOR EXACTLY THE IDS THIS CASE NEEDS, AND NOTHING ELSE. ***
    keep = {SYNTHETIC_OBLIGATION}
    if keep_finding_ids:
        keep.update(re.findall(r'"id":\s*"([^"]+)"', text[start:end]))
    demotion = 'if copy.get("status") == "DISCHARGED":'
    if text.count(demotion) != 1:
        raise AssertionError(f"the gate source must carry exactly one demotion line, found {text.count(demotion)}")
    literal = ", ".join(f'"{k}"' for k in sorted(keep))
    # *** THE DEMOTION IS APPLIED TO EVERYTHING *EXCEPT* THE KEPT IDS. ***
    # *MEASURED (bg740): the first version read `oid in (...)`, which demoted ONLY the kept ids and SKIPPED the
    # demotion for every unrelated obligation -- the exact opposite of the production law, so unrelated historical
    # DISCHARGED obligations kept their blocks and the seeded case 3/5/10 baselines were unreachable.* **The predicate
    # is therefore `oid not in (...)`: the production demotion applies normally to every id this case did not author.**
    text = text.replace(demotion, f'if copy.get("status") == "DISCHARGED" and oid not in ({literal},):', 1)
    # *** A KEPT ID MUST BE A COMPLETE, VALID TERMINAL OBLIGATION IN THE SCRATCH SOURCE. ***
    # *MEASURED (bg741): exempting an obligation from demotion PRESERVED its old prose-only text, so the scratch
    # `--check` refused it with "DISCHARGED but carrieth NO `structured_discharge` block".* **This is done ONLY for the
    # case that authors a whole terminal set (`keep_finding_ids`), and there each kept id is both FORCED to DISCHARGED
    # in the source and given the full schema -- an OPEN obligation may never carry a discharge block, so authoring one
    # onto a live obligation would be a different (and wrong) fixture.** *The live gate source is never written.*
    if keep_finding_ids:
        for k in sorted(keep):
            text = _force_status_in_source(text, k, "DISCHARGED")
            text = _author_semantics_into_source(text, k)
    _FIXTURE.gate.write_text(text, encoding="utf-8")
    if keep_finding_ids:
        # *** THE RECORDED STATUS MUST FOLLOW THE AUTHORED ALL-TERMINAL SET BEFORE RE-DERIVATION. ***
        # *With the demotion scoped away, the seeded finding's obligations are ALL terminal, so a recorded
        # `PARTIAL`/`OPEN` beside them would be refused by `build()` itself -- the seed-phase refusal, not the one
        # the case authors. The status is moved to FIX_SUBMITTED IN THE SCRATCH LEDGER, where the derivation reads it.*
        ledger = _FIXTURE.ledger()
        for group in (ledger["findings"], ledger["independent_audit_new_findings"]["findings"]):
            if fid in group:
                group[fid]["my_status"] = "FIX_SUBMITTED"
        _FIXTURE.write_ledger(ledger)



def _set_finding_status(ledger: dict, fid: str, status: str) -> None:
    """*** SET A FINDING'S RECORDED STATUS IN EVERY POPULATION THAT ALREADY CARRIETH IT. ***

    *`setdefault` was the old helper's defect: it INSERTED the finding into the population it was absent from, so
    `build()` refused with "appears in BOTH populations" -- **a refusal about the mutation's own bug rather than the
    defect the case was written to expose.*** *A status is only ever updated where the finding is already recorded.*
    """
    for group in (ledger["findings"], ledger["independent_audit_new_findings"]["findings"]):
        if fid in group:
            group[fid]["my_status"] = status


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
    """1. ONE OPEN OBLIGATION. *Reopen the campaign's OWN synthetic discharge, let its finding follow, CLAIM READY --
    the only defect is live work.*"""
    _set_finding_status(ledger, SYNTHETIC_FINDING, "PARTIAL")
    _gate_set_obligation_status(SYNTHETIC_OBLIGATION, "OPEN")
    closure_doc["status"] = "READY_FOR_EXTERNAL_REAUDIT"


def _mut_one_partial(ledger, closure_doc):
    """2. ONE PARTIAL OBLIGATION. ***THE SPELLING THE OLD `== "OPEN"` FILTER LOST. ***"""
    _set_finding_status(ledger, SYNTHETIC_FINDING, "PARTIAL")
    _gate_set_obligation_status(SYNTHETIC_OBLIGATION, "PARTIAL")
    closure_doc["status"] = "READY_FOR_EXTERNAL_REAUDIT"


def _mut_open_finding_zero_obligations(ledger, closure_doc):
    """3. A PARTIAL/OPEN FINDING WITH ZERO UNRESOLVED OBLIGATIONS. *Open with nothing a builder could execute.*

    *** THE SUBJECT IS THE CAMPAIGN'S OWN FINDING, SEEDED TERMINAL: the production register carrieth live work, so a
    finding that is OPEN with nothing left to do is authored HERE and discharged HERE.***
    """
    _set_finding_status(ledger, SYNTHETIC_FINDING, "OPEN")
    _gate_discharge_obligation_list(SYNTHETIC_FINDING)


def _mut_complete_finding_over_open_obligation(ledger, closure_doc):
    """4. ***A COMPLETE FINDING WITH AN OPEN OBLIGATION -- THE DIRECTION THAT CLAIMETH WORK IS FINISHED.***

    *This is the case my FIRST version of the consistency rule PERMITTED: it refused "open with nothing to do" and
    allowed "done with work outstanding".* **A rule that guardeth the state nobody reaches while missing the state a
    builder is tempted to write is worse than none, because it readeth as coverage.**
    """
    _set_finding_status(ledger, SYNTHETIC_FINDING, "FIX_SUBMITTED")
    _gate_set_obligation_status(SYNTHETIC_OBLIGATION, "OPEN")


def _mut_unknown_obligation_status(ledger, closure_doc):
    """5. AN UNKNOWN OBLIGATION STATUS. *Neither terminal nor unresolved -- guessing is a false reading, so it is NAMED.*"""
    _gate_set_obligation_status(SYNTHETIC_OBLIGATION, "DONE")


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
    """10. A CHANGED PERSISTED OBLIGATION STATUS. *The subject is the seeded synthetic discharge; its persisted copy
    is rewritten to a DIFFERENT legal state, a real persisted/derived disagreement.*"""
    for f in _finding_closure(ledger).values():
        for o in (f.get("internal_obligations") or []):
            if o.get("id") != SYNTHETIC_OBLIGATION:
                continue
            if o.get("status") == "DISCHARGED":
                o["status"] = "OPEN"
            elif o.get("status") in ("OPEN", "PARTIAL"):
                o["status"] = "PARTIAL"
            else:
                raise AssertionError(f"unexpected seeded status {o.get('status')!r}")
            return
    raise AssertionError(f"the persisted closure carries no {SYNTHETIC_OBLIGATION} to change")


def _mut_verified_fixed(ledger, closure_doc):
    """11. `verified_fixed = 1`. ***ONLY THE INDEPENDENT AUDITOR MAY WRITE IT, SO THE BUILDER MUST REFUSE TO CARRY IT.***"""
    closure_doc["verified_fixed"] = 1


def _close_the_real_population(ledger) -> str:
    """*** DISCHARGE EVERY REAL OBLIGATION IN THE GATE'S SOURCE, AND AUTHOR ONE UNRESOLVED ONE INSTEAD. ***

    *Cases 12 and 13 must keep testing the readiness law without relying on live work, so they close whatever the
    source carrieth, flip every affected finding to `FIX_SUBMITTED`, and INSERT one explicit unresolved obligation --
    which puts the law in front of work the case authored rather than work that happened to still be open the day it
    was written.* **The demotion is neutralized for exactly the ids this case authors, so the scratch derivation
    reacheth the terminal states the case created.**
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
        _keep_finding_discharges_through_demotion(name)
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


def _keep_finding_discharges_through_demotion(fid: str) -> None:
    """*** THE DEMOTION IS A PRODUCTION LAW; A CASE THAT AUTHORS ITS OWN TERMINAL SET MUST EXEMPT IT. ***

    *`_with_authored_discharges` demoteth every source `DISCHARGED` to OPEN (the 2026-10-02 reopen).* **A case whose
    subject IS a terminal obligation neutralizes the demotion for exactly that obligation's id -- never globally, and
    only inside the throwaway fixture.** *The exemption list is appended to by id, so the second call adds the new id
    without losing the first.*
    """
    assert _FIXTURE is not None
    text = _FIXTURE.gate.read_text(encoding="utf-8")
    start, end = _obligation_list_block(text, fid)
    ids = re.findall(r'"id":\s*"([^"]+)"', text[start:end])
    if not ids:
        raise AssertionError(f"the obligation list for {fid} carries no ids")
    pattern = re.compile(r'if copy\.get\("status"\) == "DISCHARGED"(?: and oid not in \(([^)]*)\))?:')
    m = pattern.search(text)
    if not m:
        raise AssertionError("the gate source carries no demotion line to scope")
    existing = {s.strip().strip('",\'') for s in (m.group(1) or "").split(",") if s.strip()}
    keep = sorted(existing | set(ids) | {SYNTHETIC_OBLIGATION})
    literal = ", ".join(f'"{k}"' for k in keep)
    # *THE KEPT IDS ARE THE EXCEPTION; EVERY UNRELATED OBLIGATION CARRieth THE PRODUCTION DEMOTION.*
    text = text[:m.start()] + f'if copy.get("status") == "DISCHARGED" and oid not in ({literal},):' + text[m.end():]
    _FIXTURE.gate.write_text(text, encoding="utf-8")


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


def _seeded_baseline_detail(seed) -> str | None:
    """*** A SEEDED CASE'S OWN BASELINE MUST BE GREEN BEFORE ITS KILL IS JUDGED. ***

    *Seeds the scratch gate/ledger, re-derives, and runs the gate UNMUTATED; returns the refusal detail when the
    baseline is not green, `None` when it is.* **So a fixture defect is reported as a FIXTURE defect rather than
    counted as the case's kill -- the same attribution rule the unmutated case 0 establishes for the whole campaign.**
    """
    assert _FIXTURE is not None
    _FIXTURE.restore_gate()
    _FIXTURE.write_ledger(json.loads(_PRISTINE_LEDGER))
    seed()
    try:
        _FIXTURE.rederive()
    except AssertionError as exc:
        return f"re-derivation raised: {exc}"
    _FIXTURE.write_closure({"status": "REMEDIATION_IN_PROGRESS", "verified_fixed": 0})
    proc = _FIXTURE.check()
    out = (proc.stdout or "") + (proc.stderr or "")
    if proc.returncode == 0 and "::error::" not in out:
        return None
    return f"rc={proc.returncode}\n--- stdout ---\n{(proc.stdout or '')[:1500]}\n--- stderr ---\n{(proc.stderr or '')[:1500]}"


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
        """*** EVERY MUTATION MUST BE REFUSED, AND REFUSED FOR THE REASON IT PROVOKES. ***

        *** AND A SEEDED CASE IS JUDGED ONLY AFTER ITS OWN UNMUTATED BASELINE IS GREEN. *** *MEASURED (bg740): seeded
        cases reddened on a fixture defect (a wrong-direction demotion scope) rather than on their own case, so the
        kill was unattributable.* **A seeded case's baseline -- seeded, re-derived, unmutated -- must satisfy the gate
        first; a red baseline is a FIXTURE failure reported as such, never counted as a kill.**
        """
        escaped: list[str] = []
        for name, mutate, expect in CASES:
            seed = None
            if name in SEEDED_CASES:
                keep = name.startswith("3.")
                seed = (lambda keep=keep: _seed_synthetic_discharged_obligation(keep_finding_ids=keep))
                baseline_detail = _seeded_baseline_detail(seed)
                if baseline_detail is not None:
                    escaped.append(f"{name}: SEEDED BASELINE IS NOT GREEN (fixture defect, not a kill): "
                                   f"{baseline_detail}")
                    continue
            killed, detail = _run(mutate, expect, seed=seed)
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
