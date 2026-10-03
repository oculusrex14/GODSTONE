"""*** THE CLOSURE LAW MUST STILL REFUSE, AND EVERY DISCHARGE MUST CITE SOMETHING REAL. ***

*WHY THIS FILE EXISTS: the obligation records and their statuses live inside
`scripts/build_structured_closure.py` -- **the thing that counts closures also holds the hand-authored constants it
counts.** So a builder can edit the gate's own inputs to make it report differently, with no independent check behind
the new value. These tests are that independent check, and they are written to FAIL against a laundering gate rather
than against an honest one.*

*They cover the two failure modes, both of which were briefly REAL in this very file:*

  1. **A discharge with no citation, or a citation that points at nothing.** *My first backstop accepted ANY
     existing path-like token (so mentioning `REMEDIATION_STATE.json` in prose resolved the claim), matched the bare
     word `tests` as a symbol (so any sentence containing "tests" self-certified, because `grep -rl tests` always
     hits), and took any 7-hex word as a commit (`deadbeef` included). **A backstop that launders a bogus discharge is
     WORSE than none: the file then carries an attestation nobody checked.***
  2. **The law going quiet after a batch of discharges.** *A batch after which the law stops refusing while cards are
     still unmet is the batch that was wrong -- so the refusal is re-proved against a forced READY status.*
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
GATE = REPO / "scripts" / "build_structured_closure.py"
CLOSURE = REPO / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"


def _load():
    spec = importlib.util.spec_from_file_location("closure_gate_under_test", GATE)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def _load_binding_authority():
    """*** THE CANONICAL FREEZE AUTHORITY -- A DIFFERENT MODULE FROM THE CLOSURE GATE. ***

    *MEASURED DEFECT THIS CLOSES: the fixture read `_load().FREEZE_ATTESTATION_SUCCESSOR_PATH`, but `_load()` returneth
    the CLOSURE GATE (`scripts/build_structured_closure.py`), which carrieth no such name -- AttributeError before any
    arm ran.* **The prospective and historical freeze paths live in `ci/check_candidate_binding.py` alone, so they are
    imported from there and never restated.**
    """
    spec = importlib.util.spec_from_file_location("candidate_binding_under_test",
                                                  REPO / "ci" / "check_candidate_binding.py")
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class CitationTokens(unittest.TestCase):
    """*** A TYPED TOKEN IS THE ONLY THING THAT COUNTS AS EVIDENCE. ***"""

    def setUp(self) -> None:
        self.mod = _load()

    def test_negative_cases_do_not_resolve(self) -> None:
        for citation, why in (
            ("the tests all pass", "prose is not a citation, and a bare `tests` word must not self-certify"),
            ("path:no/such/file.swift", "a plausible-looking path that does not exist"),
            ("path:../../etc/passwd", "traversal must be refused, not resolved"),
            ("path:docs/remediation/REMEDIATION_STATE.json:999999", "a line beyond the file's own length"),
            ("test:testThisSymbolDoesNotExistAnywhere", "a symbol that is not DEFINED in the tree"),
            ("commit:deadbeef", "a 7-hex word that is not a commit in this repository"),
        ):
            with self.subTest(citation=citation):
                tokens = self.mod._evidence_tokens(citation)
                ok = bool(tokens) and all(
                    self.mod._citation_token_resolves(k, v) for k, v in tokens)
                self.assertFalse(ok, f"{citation!r} must NOT resolve ({why})")

    def test_positive_cases_resolve(self) -> None:
        for citation in (
            "path:docs/remediation/REMEDIATION_STATE.json",
            "path:scripts/build_structured_closure.py:1",
            "test:testW14TheCampaignIsANamedResourceModel",
        ):
            with self.subTest(citation=citation):
                tokens = self.mod._evidence_tokens(citation)
                self.assertTrue(tokens, f"{citation!r} must carry a typed token")
                self.assertTrue(
                    all(self.mod._citation_token_resolves(k, v) for k, v in tokens),
                    f"{citation!r} must resolve",
                )

    def test_every_discharged_obligation_carries_a_typed_token(self) -> None:
        """*** A DISCHARGED OBLIGATION WITH PROSE-ONLY EVIDENCE IS A STATUS THIS BUILDER MAY NOT CARRY. ***

        *THE LIVE MAP CARRIETH ZERO DISCHARGED OBLIGATIONS (the 2026-10-02 reopen), so iterating it alone would be a
        vacuous pass -- a rule that cannot redden is not a tested rule.* **So the arm AUTHORISETH both sides: a
        prose-only discharge must produce an offender, and a typed-token discharge must produce none.**
        """
        def offenders(obligations):
            out = []
            for o in obligations:
                if o.get("status") != "DISCHARGED":
                    continue
                cites = [c for c in (o.get("evidence") or []) if isinstance(c, str) and c.strip()]
                tokens = [t for c in cites for t in self.mod._evidence_tokens(c)]
                if not tokens:
                    out.append(o["id"])
            return out

        prose_only = [{"id": "synthetic.prose-only", "status": "DISCHARGED",
                       "evidence": ["the tests all pass, obviously"]}]
        typed = [{"id": "synthetic.typed", "status": "DISCHARGED",
                  "evidence": ["`path:scripts/build_structured_closure.py`"]}]
        self.assertEqual(offenders(prose_only), ["synthetic.prose-only"],
                         "prose alone must be an offender")
        self.assertEqual(offenders(typed), [], "a typed, resolving citation must satisfy the rule")


class TheLawStillRefuses(unittest.TestCase):
    """*** RE-PROVED AFTER EVERY BATCH OF DISCHARGES, BECAUSE BULK-DISCHARGING CAN NEUTER THE GUARD. ***

    *** THIS TEST NEVER TOUCHES THE LIVE CONTROL-PLANE DOCUMENT, AND THAT IS A CORRECTNESS REQUIREMENT, NOT TIDINESS. ***
    *MY FIRST VERSION re-serialized `docs/production-readiness/BOARD1_CLOSURE.json` in place and restored it in
    `tearDown`. **IF IT HAD CRASHED, BEEN INTERRUPTED, OR DIED MID-SUITE, THE REPOSITORY WOULD HAVE BEEN LEFT WITH
    `status = READY_FOR_EXTERNAL_REAUDIT` WHILE 25 OBLIGATIONS ARE OPEN** -- the AUDIT-B1-CTRL-001 violation the law
    exists to catch, self-inflicted by the test meant to guard it. It would also churn a supply-chain-digested file.*

    **SO THE GATE IS RUN AGAINST A TEMPORARY REPO**: the real `CLOSURE`/`LEDGER` are copied into a scratch tree, the
    gate script is copied beside them, and the mutation happens THERE. The live document is only ever READ, and if
    this process dies the scratch tree dies with it.
    """

    def _run_gate_against_scratch(self, mutate, *, inject_open_obligation_into_gate: bool = False) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            scratch = Path(tmp) / "repo"
            (scratch / "scripts").mkdir(parents=True)
            (scratch / "docs" / "production-readiness").mkdir(parents=True)
            (scratch / "docs" / "remediation").mkdir(parents=True)
            shutil.copy2(GATE, scratch / "scripts" / GATE.name)
            if inject_open_obligation_into_gate:
                # *** THE OBLIGATION IS AUTHORED IN THE GATE'S OWN SOURCE, WHERE OBLIGATIONS LIVE. ***
                gt = scratch / "scripts" / GATE.name
                text = gt.read_text(encoding="utf-8")
                anchor = '"GS-FINAL-003": ['
                assert anchor in text, "the gate source carries no GS-FINAL-003 list to insert into"
                text = text.replace(
                    anchor, anchor + '\n        {"id": "law-refuses.inserted-open", "text": "an inserted open '
                    'obligation", "status": "OPEN", "evidence": []},', 1)
                gt.write_text(text, encoding="utf-8")
            shutil.copy2(CLOSURE, scratch / "docs" / "production-readiness" / CLOSURE.name)
            shutil.copy2(self.mod.LEDGER, scratch / "docs" / "remediation" / Path(self.mod.LEDGER).name)
            # THE MUTATION HAPPENS ON THE COPY. The live document is untouched even if this raises.
            target = scratch / "docs" / "production-readiness" / CLOSURE.name
            doc = json.loads(target.read_text(encoding="utf-8"))
            mutate(doc)
            target.write_text(json.dumps(doc, indent=2), encoding="utf-8")
            return subprocess.run(
                ["python3", str(scratch / "scripts" / GATE.name), "--check"],
                capture_output=True, text=True, cwd=str(scratch), timeout=600,
            )

    def setUp(self) -> None:
        self.mod = _load()
        self.live_before = CLOSURE.read_bytes()

    def test_the_live_document_is_never_written(self) -> None:
        """A guard that mutates the thing it guards is the defect, not the check."""
        self._run_gate_against_scratch(lambda d: d.update(status="READY_FOR_EXTERNAL_REAUDIT"))
        self.assertEqual(
            CLOSURE.read_bytes(), self.live_before,
            "*** THE LIVE CONTROL-PLANE DOCUMENT MUST BE BYTE-IDENTICAL AFTER THIS TEST. If it is not, an "
            "interrupted run could hand forward a READY status while obligations are open. ***",
        )
        # *** THE ASSERTION IS `UNCHANGED`, NOT A LITERAL STATE. ***
        #
        # *MEASURED, AND IT COST A RED: my first version pinned the string `REMEDIATION_IN_PROGRESS`, so the moment
        # the mission LEGITIMATELY reached READY_FOR_EXTERNAL_REAUDIT every other closure control passed and THIS one
        # reddened -- because it was asserting the status the doc happened to carry when it was written.* **THE
        # PROPERTY THIS ARM EXISTETH FOR IS THAT THE TEST DID NOT WRITE THE LIVE DOCUMENT**, so the check is
        # `bytes unchanged` (above) plus `the status is one the contract permits` -- *a literal would refuse the very
        # transition the mission is for.*
        status = json.loads(self.live_before)["status"]
        self.assertIn(
            status, ("REMEDIATION_IN_PROGRESS", "READY_FOR_EXTERNAL_REAUDIT", "COMPLETE"),
            "and the live document must carry a status the closure contract names",
        )

    def test_a_forced_ready_status_is_refused_while_gaps_remain(self) -> None:
        """*** THE LAW IS EXERCISED ON WORK THE ARM AUTHORS, SO IT KEEPETH BITING AFTER EVERY REAL DISCHARGE. ***

        *MY FIRST VERSION SKIPPED when the live ledger carried no open obligations -- and the hosted invariants job
        RIGHTLY REFUSED THE LANE for exceeding its 30-skip ceiling ("a control that should execute did not").* **A
        guard that stops testing the moment the work is done is a guard that disappears exactly when it is next
        needed.**

        *** AND THE OBLIGATION MUST BE AUTHORED IN THE GATE'S OWN SOURCE, NOT THE LEDGER: the gate DERIVES the
        obligation set from `PARTIAL_OBLIGATIONS`, so injecting one into the persisted ledger maketh it an ORPHAN and
        the refusal cometh on the DRIFT ground rather than on the readiness law.*** *So the scratch GATE carries one
        extra OPEN obligation (the same shape `test_closure_state_mutations.py` useth), and the refusal is required
        to be the readiness law's own words.*
        """
        proc = self._run_gate_against_scratch(
            lambda d: d.update(status="READY_FOR_EXTERNAL_REAUDIT"),
            inject_open_obligation_into_gate=True)
        self.assertEqual(
            proc.returncode, 1,
            "*** THE LAW MUST STILL REFUSE. If forcing READY now exits 0 over an AUTHORED open obligation, the gate "
            f"has been neutered by the very discharges it was supposed to audit. stdout: {proc.stdout[-500:]} ***",
        )
        self.assertIn("MAY NOT", proc.stdout, "and the refusal must SAY WHY, naming the open work")

    def test_verified_fixed_may_not_be_written_by_this_builder(self) -> None:
        proc = self._run_gate_against_scratch(lambda d: d.update(verified_fixed=1))
        self.assertEqual(
            proc.returncode, 1,
            "only an INDEPENDENT audit may write `verified_fixed`, and this builder must refuse to carry it",
        )


if __name__ == "__main__":
    unittest.main()


class ObligationStateMachine(unittest.TestCase):
    """*** THE STATE MODEL: TERMINALITY COMES FROM AN EXPLICIT SET, NOT FROM `== "OPEN"`. ***

    *THE DEFECT THESE CLOSE, PROVEN BY SIMULATION BEFORE THE FIX: the map held **18 OPEN, 2 PARTIAL, 10
    DISCHARGED**, and `counts()` summed only `status == "OPEN"` -- so the two `PARTIAL` obligations vanished from the
    unresolved total. **AND THE FALSE-CLOSURE PATH WAS REAL: with all 18 OPEN discharged and the 2 PARTIALs
    remaining, the derived count fell to zero and the law PERMITTED `READY_FOR_EXTERNAL_REAUDIT` (rc=0).*** That is
    AUDIT-B1-CTRL-001's defect class reproducing inside the instrument built to prevent it.*

    *These mutate the REAL structured model -- the actual `PARTIAL_OBLIGATIONS` map and the actual `counts()` -- not
    a toy predicate, so they cannot pass while production drifts away from them.*
    """

    def setUp(self) -> None:
        self.mod = _load()
        self.closure = self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8")))

    def test_the_legal_state_set_is_explicit(self) -> None:
        self.assertEqual(set(self.mod.OBLIGATION_STATES), {"OPEN", "PARTIAL", "DISCHARGED"})
        self.assertEqual(set(self.mod.UNRESOLVED_OBLIGATION_STATES), {"OPEN", "PARTIAL"})
        self.assertEqual(set(self.mod.TERMINAL_OBLIGATION_STATES), {"DISCHARGED"})
        self.assertFalse(set(self.mod.UNRESOLVED_OBLIGATION_STATES) & set(self.mod.TERMINAL_OBLIGATION_STATES),
                         "no state may be both unresolved and terminal")

    @staticmethod
    def _first_with_obligations(closure: dict):
        """The first finding that actually CARRIES obligations -- many findings carry none."""
        for f in closure.values():
            if f.get("internal_obligations"):
                return f
        raise AssertionError("the closure carries no obligations at all")

    def _count_with(self, mutate) -> dict:
        """Counts over the REAL closure with one obligation's status mutated."""
        closure = json.loads(json.dumps(self.closure))
        mutate(closure)
        return self.mod.counts(closure)

    def test_one_open_obligation_prevents_zero(self) -> None:
        def m(c):
            for f in c.values():
                for o in f["internal_obligations"]:
                    o["status"] = "DISCHARGED"
            self._first_with_obligations(c)["internal_obligations"][0]["status"] = "OPEN"
        self.assertEqual(self._count_with(m)["internal_obligations_unresolved"], 1,
                         "ONE OPEN obligation must keep the unresolved count at ONE")

    def test_one_partial_obligation_prevents_zero(self) -> None:
        """*** THE CASE THE OLD `== \"OPEN\"` FILTER GOT WRONG. ***"""
        def m(c):
            for f in c.values():
                for o in f["internal_obligations"]:
                    o["status"] = "DISCHARGED"
            self._first_with_obligations(c)["internal_obligations"][0]["status"] = "PARTIAL"
        self.assertEqual(self._count_with(m)["internal_obligations_unresolved"], 1,
                         "*** ONE PARTIAL obligation MUST keep the unresolved count at ONE -- a filter that honours "
                         "only the OPEN spelling of 'not finished' under-counts silently. ***")

    def test_only_all_discharged_reaches_zero(self) -> None:
        def m(c):
            for f in c.values():
                for o in f["internal_obligations"]:
                    o["status"] = "DISCHARGED"
        got = self._count_with(m)
        self.assertEqual(got["internal_obligations_unresolved"], 0)
        self.assertEqual(got["obligations_by_state"]["DISCHARGED"], sum(got["obligations_by_state"].values()))

    def test_an_unknown_status_is_refused(self) -> None:
        """*A state this instrument does not recognise is neither terminal nor unresolved -- guessing is a false
        reading, so it is NAMED.*"""
        for bogus in ("DONE", "FIXED", "PASS", "COMPLETE", "openn", "partial"):
            with self.subTest(status=bogus):
                closure = json.loads(json.dumps(self.closure))
                self._first_with_obligations(closure)["internal_obligations"][0]["status"] = bogus
                problems = self.mod.obligation_state_problems(closure)
                self.assertTrue(problems, f"{bogus!r} must be REFUSED by name, not guessed at")

    def test_the_real_map_carries_only_legal_states(self) -> None:
        self.assertEqual(self.mod.obligation_state_problems(self.closure), [],
                         "every obligation in the real map must carry a legal state")


class FindingStatusFollowsItsObligations(unittest.TestCase):
    """*** A FINDING MAY NOT BE INTERNALLY OPEN WHILE CARRYING ZERO UNRESOLVED OBLIGATIONS. ***

    *MEASURED ON THE LIVE TREE BEFORE THE FIX: **`AUDIT-B1-CTRL-001` AND `GS-FINAL-004` EACH STOOD
    `internal_status = OPEN` WITH EVERY ONE OF THEIR OBLIGATIONS `DISCHARGED`** -- internally open with nothing a
    builder could execute, so **no batch of work could ever have closed them.*** *Their inconsistency was invisible in
    `findings_internal_open`, which counteth OBLIGATIONS, so a reader comparing "8 findings internally open" against a
    status list showing ten OPEN findings had no field explaining the gap.*

    *** AND MY FIRST REPAIR WAS ITSELF WRONG, WHICH THESE TESTS PIN SO IT CANNOT COME BACK: it fired whenever a
    finding's obligations were ALL terminal -- which would have REFUSED EVERY CORRECTLY-CLOSED FINDING. A guard that
    refuseth the state it is meant to permit is the mirror defect of one that permitteth the state it is meant to
    refuse.*** *So the rule is the `OPEN` BESIDE AN ALL-TERMINAL SET, and the positive case is asserted too.*
    """

    def setUp(self) -> None:
        self.mod = _load()
        self.closure = self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8")))

    def test_the_live_closure_carries_no_such_inconsistency(self) -> None:
        self.assertEqual(
            self.mod.finding_state_problems(self.closure), [],
            "no finding may stand internally OPEN while all its obligations are terminal",
        )

    def test_an_open_finding_with_all_obligations_discharged_is_refused(self) -> None:
        closure = json.loads(json.dumps(self.closure))
        fid = next(f for f, e in closure.items() if e.get("internal_obligations"))
        for o in closure[fid]["internal_obligations"]:
            o["status"] = "DISCHARGED"
        closure[fid]["internal_status"] = "OPEN"
        problems = self.mod.finding_state_problems(closure)
        self.assertTrue(problems, f"{fid}: OPEN beside an all-terminal obligation set must be REFUSED")

    def test_a_complete_finding_with_all_obligations_discharged_is_PERMITTED(self) -> None:
        """*The mirror defect: a guard that refuses the state it exists to permit is not a guard.*"""
        closure = json.loads(json.dumps(self.closure))
        fid = next(f for f, e in closure.items() if e.get("internal_obligations"))
        for o in closure[fid]["internal_obligations"]:
            o["status"] = "DISCHARGED"
        closure[fid]["internal_status"] = "COMPLETE"
        self.assertEqual(
            self.mod.finding_state_problems(closure), [],
            "a COMPLETE finding whose obligations are all DISCHARGED is the CORRECT state, not a defect",
        )

    def test_a_finding_with_no_obligations_is_not_covered_by_the_rule(self) -> None:
        """*Terminality cannot be derived from a set that does not exist, so such a finding keeps its status.*"""
        closure = json.loads(json.dumps(self.closure))
        fid = next(f for f, e in closure.items() if not e.get("internal_obligations"))
        closure[fid]["internal_status"] = "OPEN"
        self.assertEqual(
            self.mod.finding_state_problems(closure), [],
            "a finding with no authored obligations is governed by its recorded status, not by an empty set",
        )

    def test_the_ledger_population_refuses_an_inconsistent_finding(self) -> None:
        """*** THE RULE IS ENFORCED WHERE THE FINDING IS BUILT, AND WITH THE LIVE WORK, NOT A SYNTHETIC DISCHARGE. ***

        *The earlier draft authored an all-DISCHARGED obligation set -- which the 2026-10-02 reopen now DEMOTES to
        OPEN, so the refusal it expected could not fire (the arm passed only while the live register happened to carry
        discharges).* **The reachable production shape is the OTHER direction: a finding RECORDED as fixed over
        obligations that are live.**

        *** AND THE ASSERTION MUST NAME THE FUNCTION THAT ACTUALLY CARRIES THE RULE. *** *MEASURED, BY DIRECT CALL:
        `build()` DERIVES `recorded_status` beside `internal_status` and does NOT refuse this direction (the finding is
        returned with `recorded_status='FIX_SUBMITTED'`, `internal_status='OPEN'`); the refusal liveth in
        `finding_state_problems()`, which `--check` runs -- so the old `assertRaises(SystemExit)` around `build()` was
        asserting a behaviour the gate never had.* **This arm now drives the ledger in ITS OWN TRACK and judges the
        real refusal by name.**
        """
        ledger = json.loads(self.mod.LEDGER.read_text(encoding="utf-8"))
        tracks = (ledger["findings"], ledger["independent_audit_new_findings"]["findings"])
        fids = [fid for fid, obligations in self.mod.PARTIAL_OBLIGATIONS.items()
                if any(o.get("status") in self.mod.UNRESOLVED_OBLIGATION_STATES for o in obligations)]
        target = next(((track, fid) for track in tracks for fid in fids if fid in track), None)
        self.assertIsNotNone(target, "no PARTIAL_OBLIGATIONS finding with live work is present in either ledger track "
                                     f"-- the arm would mutate nothing (candidates: {fids})")
        track, fid = target
        self.assertIn(track[fid].get("my_status"), ("OPEN", "PARTIAL"),
                      f"{fid} must be recorded as live work before the arm claims it fixed")
        track[fid]["my_status"] = "FIX_SUBMITTED"
        closure = self.mod.build(ledger)
        problems = self.mod.finding_state_problems(closure)
        self.assertTrue(any(fid in p and "UNRESOLVED" in p for p in problems),
                        f"{fid}: a RECORDED FIX_SUBMITTED over live obligations must be refused by the closure law, "
                        f"got {problems[:3]}")

    def test_both_findings_that_were_inconsistent_now_derive_coherently(self) -> None:
        """*The two MEASURED offenders -- pinned by name so a return to the old state is loud.*

        *** THE DURABLE INVARIANT, WHICH OUTLIVES THE MOMENTARY STATUS: a finding's `internal_status` must EQUAL what
        its obligation set derives. *** *When this file was written both offenders were all-terminal, so "not OPEN"
        was the test. Since 2026-10-02 their obligations were REOPENED and both now legitimately derive OPEN -- so a
        pinned status literal would now be FALSE. The invariant is the derivation, not the value.*
        """
        for fid in ("AUDIT-B1-CTRL-001", "GS-FINAL-004"):
            with self.subTest(finding=fid):
                e = self.closure[fid]
                obls = e.get("internal_obligations") or []
                self.assertTrue(obls, f"{fid} must carry authored obligations")
                expected = "COMPLETE" if self.mod.obligations_are_terminal(e) else "OPEN"
                self.assertEqual(
                    e.get("internal_status"), expected,
                    f"{fid}: internal_status must EQUAL the value its obligation set derives",
                )
                self.assertEqual(e.get("internal_status_source"), "derived_from_obligations")


class ReadinessRequiresBothPopulations(unittest.TestCase):
    """*** A READY STATUS MUST BE EMPTY IN BOTH POPULATIONS, NOT ONE. ***

    *MEASURED: with `AUDIT-B1-CTRL-001` and `GS-FINAL-004` internally OPEN while carrying ZERO obligations, a gate
    reading only `internal_obligations_unresolved` would have PERMITTED `READY_FOR_EXTERNAL_REAUDIT` while TEN findings
    still reported themselves internally open. Section 23 nameth `findings with internal_status OPEN = 0` as a
    readiness condition in its own right.*
    """

    def setUp(self) -> None:
        self.mod = _load()

    def test_the_status_population_is_reported_separately(self) -> None:
        c = self.mod.counts(self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8"))))
        self.assertIn("findings_with_internal_status_open", c,
                      "the obligation count cannot see a finding with no obligations, so the STATUS must be counted")

    def test_a_finding_status_open_alone_blocks_readiness(self) -> None:
        """*The mutation: every OBLIGATION discharged, but a finding still OPEN. The law must still refuse.*"""
        closure = self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8")))
        for f in closure.values():
            for o in f["internal_obligations"]:
                o["status"] = "DISCHARGED"
        fid = next(f for f, e in closure.items() if e.get("internal_obligations"))
        closure[fid]["internal_status"] = "OPEN"
        c = self.mod.counts(closure)
        self.assertEqual(c["internal_obligations_unresolved"], 0, "the obligation population is empty ...")
        self.assertGreater(c["findings_with_internal_status_open"], 0,
                           "... while the STATUS population is not -- which is exactly the gap the law must see")


class PersistedStateAgreesWithDerivation(unittest.TestCase):
    """*** THE PERSISTED STRUCTURED STATE MUST EQUAL WHAT THE LOGIC DERIVES. ***

    *MEASURED BEFORE THE FIX: the ledger carried `structured_counts.internal_obligations_open = 30` while the
    derivation produced **18** -- two disagreeing structured representations of the same state, which is exactly the
    narrative/state drift this control plane exists to eliminate. And `--check` never read them.*

    *These mutate the PERSISTED ledger in a scratch tree and require `--check` to refuse, so the field cannot go
    stale while the checker stays green.*
    """

    def _run_check_with_ledger(self, mutate) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as td:
            scratch = Path(td) / "repo"
            (scratch / "scripts").mkdir(parents=True)
            shutil.copy2(GATE, scratch / "scripts" / GATE.name)
            (scratch / "docs" / "production-readiness").mkdir(parents=True)
            (scratch / "docs" / "remediation").mkdir(parents=True)
            shutil.copy2(CLOSURE, scratch / "docs" / "production-readiness" / CLOSURE.name)
            led = json.loads((REPO / "docs" / "remediation" / "REMEDIATION_STATE.json").read_text(encoding="utf-8"))
            mutate(led)
            (scratch / "docs" / "remediation" / "REMEDIATION_STATE.json").write_text(
                json.dumps(led, indent=1, ensure_ascii=False), encoding="utf-8")
            return subprocess.run(["python3", str(scratch / "scripts" / GATE.name), "--check"],
                                  capture_output=True, text=True, cwd=str(scratch), timeout=600)

    def test_a_stale_count_is_refused(self) -> None:
        def m(led):
            led["current_assessment"]["structured_counts"]["internal_obligations_open"] += 1
        proc = self._run_check_with_ledger(m)
        self.assertEqual(proc.returncode, 1, "an altered persisted COUNT must be refused")
        self.assertIn("DISAGREES", proc.stdout, "and the refusal must SAY which field disagreed")

    def test_a_stale_obligation_status_is_refused(self) -> None:
        def m(led):
            for fid, f in (led["current_assessment"]["finding_closure"] or {}).items():
                for o in (f.get("internal_obligations") or []):
                    if o.get("status") == "OPEN":
                        o["status"] = "PARTIAL"
                        return
                    if o.get("status") == "DISCHARGED":
                        o["status"] = "OPEN"
                        return
            raise AssertionError("the persisted closure carries no obligation status to alter")
        proc = self._run_check_with_ledger(m)
        self.assertEqual(proc.returncode, 1, "an altered persisted STATUS must be refused")

    def test_a_deleted_obligation_is_refused(self) -> None:
        def m(led):
            for fid, f in (led["current_assessment"]["finding_closure"] or {}).items():
                if f.get("internal_obligations"):
                    f["internal_obligations"].pop()
                    return
        proc = self._run_check_with_ledger(m)
        self.assertEqual(proc.returncode, 1, "a DELETED persisted obligation must be refused")

    def test_an_orphan_obligation_is_refused(self) -> None:
        def m(led):
            for fid, f in (led["current_assessment"]["finding_closure"] or {}).items():
                f.setdefault("internal_obligations", []).append(
                    {"id": "orphan.not-in-derivation", "status": "OPEN"})
                return
        proc = self._run_check_with_ledger(m)
        self.assertEqual(proc.returncode, 1, "an ORPHAN persisted obligation must be refused")

    def test_the_real_tree_agrees(self) -> None:
        proc = subprocess.run(["python3", str(GATE), "--check"], capture_output=True, text=True,
                              cwd=str(REPO), timeout=600)
        self.assertEqual(proc.returncode, 0,
                         "the committed tree's persisted state must equal its derivation:\n" + proc.stdout)


class StructuredDischargeContradiction(unittest.TestCase):
    """*** A TERMINAL DISCHARGED ITS OWN STRUCTURED FIELDS CONTRADICT MUST BE REFUSED. ***

    *A discharge that says its evidence is `court-only` while its status says `DISCHARGED` is the contradiction a prose
    review cannot see. The structured block is what makes it visible; this test is what proves the instrument looks.*

    *** AND THE SUBJECT IS A FULLY VALID SYNTHETIC DISCHARGE THE ARM AUTHORIS, NOT A LIVE ONE. *** *The 2026-10-02
    reopen demoted the live register to 35 OPEN / 0 DISCHARGED, so an arm that waited for a live discharge would die on
    `next(iter(...))` -- StopIteration -- the moment the frontier is honestly open.* **Each arm therefore starts from
    the SAME all-valid synthetic obligation (every required field, production reachability, an external binding, a
    typed citation) and mutates exactly ONE falsifier**, so a kill reddens the property it names and nothing else.
    """

    #: The all-valid baseline: every required field present, real reach, PROSPECTIVE external identity binding.
    #: *** THE ATTESTATION NAMETH THE PROSPECTIVE PATH THE FREEZE WILL WRITE, FROM THE CANONICAL AUTHORITY. ***
    #: *`ci/check_candidate_binding.py` owneth `FREEZE_ATTESTATION_SUCCESSOR_PATH` / `HISTORICAL_ATTESTATION_PATH`;
    #: the CLOSURE GATE carrieth neither, so this is read from the binding authority (never a restated literal), and a
    #: drift in the ONE constant reddens the fixture rather than hiding behind a stale copy.*
    BINDING_AUTHORITY = _load_binding_authority()
    FUTURE_ATTESTATION_PATH = BINDING_AUTHORITY.FREEZE_ATTESTATION_SUCCESSOR_PATH
    VALID_DISCHARGE = {
        "behavior": "the synthetic control exercised the exact behaviour its clause names",
        "implementation": "`path:scripts/build_structured_closure.py` -- the authored block",
        "reachability": "production",
        "test": "the synthetic witness arm",
        "positive": "the honest fixture is green",
        "mutation": "removing any single field reddens exactly one refusal",
        "exact_result": "MEASURED: the synthetic arm's own fixture",
        "candidate_binding": {
            "candidate_ref": "production-readiness-board1-rc15",
            "external_manifest": "docs/remediation/evidence/board1-evidence-bundle.json",
            "attestation": FUTURE_ATTESTATION_PATH,
        },
    }

    def setUp(self) -> None:
        self.mod = _load()

    def _closure(self, mutate=None):
        """A closure fixture whose FIRST obligation is a fully valid synthetic discharge, then mutated."""
        obligation = {"id": "synthetic.discharged", "text": "t", "status": "DISCHARGED",
                      "evidence": ["`path:scripts/build_structured_closure.py`"],
                      "structured_discharge": json.loads(json.dumps(self.VALID_DISCHARGE))}
        if mutate is not None:
            mutate(obligation)
        return {"SYNTHETIC-001": {"group": "synthetic", "recorded_status": "FIX_SUBMITTED",
                                  "internal_status": "COMPLETE",
                                  "internal_obligations": [obligation]}}

    def test_the_valid_baseline_carries_no_contradiction(self) -> None:
        """*Without this, every kill below could be the fixture's own defect rather than the falsifier's.*"""
        self.assertEqual(self.mod.structured_discharge_problems(self._closure()), [],
                         "the all-valid synthetic discharge must pass, or no kill below is attributable")

    def test_a_court_only_reachability_contradicts_a_discharge(self) -> None:
        closure = self._closure(lambda o: o["structured_discharge"].update(reachability="court-only"))
        problems = self.mod.structured_discharge_problems(closure)
        self.assertTrue(any("CONTRADICTS" in p for p in problems),
                        "court-only reachability beside DISCHARGED must be refused")

    def test_a_missing_required_field_is_refused(self) -> None:
        closure = self._closure(lambda o: o["structured_discharge"].update(mutation=""))
        problems = self.mod.structured_discharge_problems(closure)
        self.assertTrue(any("MISSING" in p for p in problems), "an empty required field must be refused")

    def test_a_self_referential_candidate_sha_is_refused(self) -> None:
        closure = self._closure(lambda o: o["structured_discharge"]["candidate_binding"].update(
            candidate_sha="deadbeef"))
        problems = self.mod.structured_discharge_problems(closure)
        self.assertTrue(any("candidate_sha" in p for p in problems),
                        "an embedded candidate_sha is self-referential and must be refused")

    def test_a_non_terminal_obligation_may_not_carry_a_discharge_block(self) -> None:
        closure = self._closure(lambda o: o.update(status="OPEN"))
        problems = self.mod.structured_discharge_problems(closure)
        self.assertTrue(any("non-terminal" in p or "may not carry" in p for p in problems),
                        "a block that DESCRIBES a discharge may not sit on a non-terminal obligation")

    def test_the_live_tree_carries_no_discharge_contradiction(self) -> None:
        self.assertEqual(
            self.mod.structured_discharge_problems(
                self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8")))), [],
            "the live 35-OPEN closure must carry no discharge contradiction")

    def test_a_terminal_obligation_with_no_semantics_is_refused(self) -> None:
        """*** THE BYPASS THE OLD CHECK PERMITTED: `if sd is None: continue` skipped every legacy discharge. ***

        *A DISCHARGED obligation with NO `structured_discharge` block needed NOTHING to be terminal -- no behaviour,
        implementation, reachability, test, positive control, mutation, exact result or external binding. **That is a
        terminal claim without a subject, and it is now REFUSED BY NAME rather than skipped.***
        """
        closure = self._closure(lambda o: o.pop("structured_discharge"))
        problems = self.mod.structured_discharge_problems(closure)
        self.assertTrue(any("NO `structured_discharge`" in p for p in problems),
                        f"a terminal obligation with no authored semantics must be REFUSED, got {problems[:3]}")

    def test_a_binding_without_the_external_identity_is_refused(self) -> None:
        """*`candidate_binding` was OPTIONAL and its external identity unconstrained; both are now mandatory.*"""
        closure = self._closure(lambda o: o["structured_discharge"].update(
            candidate_binding={"external_manifest": "m"}))
        problems = self.mod.structured_discharge_problems(closure)
        self.assertTrue(any("attestation" in p for p in problems),
                        f"a binding without the frozen attestation must be refused, got {problems[:3]}")

    # *** THE PROSPECTIVE-BINDING LAW: A CURRENT DISCHARGE NAMES THE FUTURE ATTESTATION, NEVER HISTORY. ***
    #
    # *THE DEFECT THESE CLOSE, MEASURED: the schema checked only PRESENCE, so a current discharge could bind the
    # HISTORICAL rc14 attestation, an arbitrary stale path, or embed a tag object / candidate commit -- each of which
    # describes a candidate other than the one being cut.* **The prospective and historical paths come from the
    # canonical authority, so neither is restated here; the positive arm proves the baseline (which nameth the
    # prospective path) is admitted, and each negative arm mutates exactly one falsifier.**

    def test_the_prospective_binding_is_admitted(self) -> None:
        canonical = self.mod._canonical_freeze()
        binding = self._closure()["SYNTHETIC-001"]["internal_obligations"][0]["structured_discharge"]["candidate_binding"]
        self.assertEqual(binding["attestation"], canonical.FREEZE_ATTESTATION_SUCCESSOR_PATH,
                         "the all-valid baseline must name the canonical prospective attestation path")
        self.assertEqual(self.mod.structured_discharge_problems(self._closure()), [],
                         "a prospective binding must be admitted, or every kill below is the fixture's own defect")

    def test_the_historical_attestation_cannot_discharge_the_current_candidate(self) -> None:
        canonical = self.mod._canonical_freeze()
        closure = self._closure(lambda o: o["structured_discharge"]["candidate_binding"].update(
            attestation=canonical.HISTORICAL_ATTESTATION_PATH))
        problems = self.mod.structured_discharge_problems(closure)
        self.assertTrue(any("HISTORICAL attestation" in p for p in problems),
                        f"binding the historical rc14 attestation must be refused, got {problems[:3]}")

    def test_a_non_prospective_attestation_path_is_refused(self) -> None:
        closure = self._closure(lambda o: o["structured_discharge"]["candidate_binding"].update(
            attestation="docs/remediation/evidence/FREEZE_ATTESTATION_rc11.json"))
        problems = self.mod.structured_discharge_problems(closure)
        self.assertTrue(any("canonical prospective path" in p for p in problems),
                        f"a stale/prefix/directory path must be refused, got {problems[:3]}")

    def test_the_historical_candidate_ref_is_refused(self) -> None:
        closure = self._closure(lambda o: o["structured_discharge"]["candidate_binding"].update(
            candidate_ref="production-readiness-board1-rc14"))
        problems = self.mod.structured_discharge_problems(closure)
        self.assertTrue(any("HISTORICAL rc14 candidate" in p for p in problems),
                        f"a current discharge naming the archived candidate must be refused, got {problems[:3]}")

    def test_an_embedded_candidate_identity_is_refused(self) -> None:
        for key in ("tag_object", "candidate_commit"):
            with self.subTest(key=key):
                closure = self._closure(lambda o, k=key: o["structured_discharge"]["candidate_binding"].update(
                    {k: "f" * 40}))
                problems = self.mod.structured_discharge_problems(closure)
                self.assertTrue(any("immutable candidate identity" in p for p in problems),
                                f"an embedded {key} must be refused, got {problems[:3]}")

    def test_the_authored_semantics_must_match_the_closure(self) -> None:
        """*** A DISCHARGE AUTHORED FOR NON-TERMINAL WORK IS A CLAIM ABOUT WORK THAT DOES NOT EXIST. ***

        *`STRUCTURED_DISCHARGES` is EMPTY BY DESIGN while the frontier is open, so taking `next(iter(...))` from it
        raised StopIteration -- a dead arm on the honest tree.* **The arm now authors its own block and its own
        non-terminal subject, so it exercises the rule rather than the map's momentary contents.**
        """
        closure = self._closure(lambda o: o.update(status="OPEN"))  # non-terminal subject
        original = dict(self.mod.STRUCTURED_DISCHARGES)
        try:
            self.mod.STRUCTURED_DISCHARGES.clear()
            self.mod.STRUCTURED_DISCHARGES["synthetic.discharged"] = json.loads(
                json.dumps(StructuredDischargeContradiction.VALID_DISCHARGE))
            problems = self.mod.authoring_coverage_problems(closure)
            self.assertTrue(any("synthetic.discharged" in p for p in problems),
                            f"an authored discharge over non-terminal work must be refused, got {problems[:3]}")
        finally:
            self.mod.STRUCTURED_DISCHARGES.clear()
            self.mod.STRUCTURED_DISCHARGES.update(original)

    def test_a_measured_gap_must_sit_on_a_live_obligation(self) -> None:
        """*A gap recorded against terminal work is stale by construction.*"""
        closure = self._closure()  # a terminal DISCHARGED subject
        original = {k: json.loads(json.dumps(v)) for k, v in self.mod.KNOWN_INTERNAL_GAPS.items()}
        try:
            self.mod.KNOWN_INTERNAL_GAPS.clear()
            self.mod.KNOWN_INTERNAL_GAPS["synthetic.discharged"] = [{"defect": "stale"}]
            problems = self.mod.authoring_coverage_problems(closure)
            self.assertTrue(any("live gap against" in p for p in problems),
                            f"a gap against terminal work must be refused as stale, got {problems[:3]}")
        finally:
            self.mod.KNOWN_INTERNAL_GAPS.clear()
            self.mod.KNOWN_INTERNAL_GAPS.update(original)


class StructuredSemanticsAreMeasured(unittest.TestCase):
    """*** THE THREE SEMANTIC FIELDS MUST MEASURE, NOT ASSENT. ***

    *THE THREE DEFECTS THESE PIN, ALL OF WHICH WERE LIVE:*

      1. **A "present control" was every obligation whose status was not unresolved** -- *so a DISCHARGED obligation
         became a required control with NO semantic proof, and the field measured the status it was supposed to
         justify.* **Now a control is present only when its own authored `structured_discharge` names what was
         exercised; a terminal obligation without one lands in `refused_controls` and is NEVER reported present.**
      2. **`unresolved_internal_dependencies` was populated from `external_obligations`** -- *folding an EXTERNAL
         blocker (a pinned artifact, a device, an independent audit) into the INTERNAL dependency list is the
         confusion that lets external work read as internal.* **They are now separate fields.**
      3. **The gap scan carried "review-only" authority and no dispositions** -- *every hit now carrieth an explicit
         disposition DERIVED from the measured semantics.*

    *** AND THE SUBJECTS ARE AUTHORED HERE, NOT BORROWED FROM A LIVE DISCHARGE. *** *With 35 OPEN / 0 DISCHARGED the
    live register carrieth no terminal obligation at all, so every arm below builds its own synthetic discharged
    fixture (`StructuredDischargeContradiction.VALID_DISCHARGE`'s shape) and mutates it; the LIVE tree is exercised
    only where the assertion is genuinely about the live state, under its own name.*
    """

    def setUp(self) -> None:
        self.mod = _load()
        self.closure = self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8")))
        self.sem = self.mod.structured_semantics(self.closure)

    def _synthetic_closure(self, *, with_discharge: bool = True):
        """*** ONE SYNTHETIC DISCHARGED OBLIGATION, AUTHORED BY THE ARM, WITH THE FULL SCHEMA. ***

        *The live register carrieth 35 OPEN / 0 DISCHARGED, so the arms that need a terminal subject author
        `StructuredDischargeContradiction.VALID_DISCHARGE`'s shape here -- no live discharge, no global authority
        passthrough, no dependence on a state that exists only while the frontier happens to be open.*
        """
        obligation = {"id": "synthetic.discharged", "text": "synthetic clause",
                      "status": "DISCHARGED" if with_discharge else "OPEN",
                      "evidence": ["`path:scripts/build_structured_closure.py`"]}
        if with_discharge:
            obligation["structured_discharge"] = json.loads(
                json.dumps(StructuredDischargeContradiction.VALID_DISCHARGE))
        return {"SYNTHETIC-001": {"group": "synthetic", "recorded_status": "FIX_SUBMITTED",
                                  "internal_status": "COMPLETE" if with_discharge else "OPEN",
                                  "internal_obligations": [obligation]}}

    def test_present_controls_carry_authored_semantics(self) -> None:
        sem = self.mod.structured_semantics(self._synthetic_closure())
        self.assertTrue(sem["required_controls_present"], "a discharge with semantics must be a present control")
        for fid, items in sem["required_controls_present"].items():
            for item in items:
                with self.subTest(finding=fid, obligation=item["obligation"]):
                    self.assertTrue(item.get("reachability"),
                                    "a present control must carry the reach its discharge claimed")
                    self.assertTrue(item.get("behavior"), "and the behaviour it exercised")

    def test_a_terminal_obligation_without_semantics_is_never_present(self) -> None:
        """*The mutation: a DISCHARGED obligation stripped of its block must move to `refused_controls`, not stay
        present.*"""
        closure = self._synthetic_closure()
        oid = closure["SYNTHETIC-001"]["internal_obligations"][0]["id"]
        closure["SYNTHETIC-001"]["internal_obligations"][0].pop("structured_discharge")
        sem = self.mod.structured_semantics(closure)
        present_ids = {i["obligation"] for items in sem["required_controls_present"].values() for i in items}
        self.assertNotIn(oid, present_ids, "an unmeasurable control must NOT be reported present")
        self.assertIn(oid, {e["obligation"] for e in sem["refused_controls"]})

    def test_internal_and_external_dependencies_are_different_populations(self) -> None:
        """*An EXTERNAL obligation must never appear in the INTERNAL dependency list, and vice versa.*"""
        external_ids = {o.get("id") for f in self.closure.values() for o in (f.get("external_obligations") or [])}
        internal_ids = {oid for ids in self.sem["unresolved_internal_dependencies"].values() for oid in ids}
        self.assertFalse(external_ids & internal_ids,
                         "an external obligation must not read as an internal dependency")
        # And the internal list must name only UNRESOLVED internal obligations -- proven on a SYNTHETIC pair where
        # one side is an external obligation and the other an unresolved internal one.
        mixed = {
            "SYNTHETIC-001": {
                "internal_status": "OPEN",
                "internal_obligations": [{"id": "synthetic.internal-open", "text": "t", "status": "OPEN",
                                          "evidence": ["`path:scripts/build_structured_closure.py`"]}],
                "external_obligations": [{"id": "synthetic.external", "text": "e"}],
            },
            "SYNTHETIC-002": {
                "internal_status": "COMPLETE",
                "internal_obligations": [{"id": "synthetic.internal-done", "text": "t", "status": "DISCHARGED",
                                          "structured_discharge": json.loads(json.dumps(
                                              StructuredDischargeContradiction.VALID_DISCHARGE)),
                                          "evidence": ["`path:scripts/build_structured_closure.py`"]}],
            },
        }
        sem = self.mod.structured_semantics(mixed)
        in_deps = {oid for ids in sem["unresolved_internal_dependencies"].values() for oid in ids}
        self.assertEqual(in_deps, {"synthetic.internal-open"})
        self.assertNotIn("synthetic.external", in_deps,
                         "an EXTERNAL blocker folded into the INTERNAL list is the confusion this arm refuses")
        self.assertEqual(list(sem["external_obligations"]), ["SYNTHETIC-001"],
                         "the external population is reported separately")
        # And the live tree still honours the same split.
        for oid in internal_ids:
            self.assertIn(oid, {o.get("id") for f in self.closure.values()
                                for o in (f.get("internal_obligations") or [])},
                          f"{oid}: an internal dependency must name an INTERNAL obligation")

    def test_every_discharged_prose_hit_carries_a_disposition(self) -> None:
        """*** A TERMINAL OBLIGATION WHOSE OWN PROSE MENTIONS A GAP CONCEPT MUST CARRY A DISPOSITION. ***

        *The live register carrieth no terminal obligation, so asserting the live roster is non-empty would be an
        incidental-state assertion (and false today).* **The arm authors a synthetic discharge whose text carrieth a gap
        concept and asserts the disposition machinery for it** -- the property, not the current population.
        """
        closure = self._synthetic_closure()
        closure["SYNTHETIC-001"]["internal_obligations"][0]["text"] = (
            "the control is deferred and still owed, absent pending work")
        scan = self.mod.discharged_prose_scan(closure)
        self.assertTrue(scan["roster"], "a terminal obligation mentioning a gap concept must produce a hit")
        for hit in scan["roster"]:
            with self.subTest(obligation=hit["obligation"], concept=hit["concept"]):
                self.assertIn(hit["disposition"],
                              ("COVERED_BY_STRUCTURED_DISCHARGE", "REFUSED_CONTROL"))
                self.assertTrue(hit["reasoning"])

    def test_the_scan_and_the_semantics_never_feed_a_count(self) -> None:
        """*Neither the gap-word scan nor the semantics block may move a closure count.*"""
        before = self.mod.counts(self.closure)
        sem = self.mod.structured_semantics(self.closure)
        scan = self.mod.discharged_prose_scan(self.closure)
        self.assertEqual(self.mod.counts(self.closure), before)
        self.assertTrue(sem and scan, "the two artifacts exist while the count is unchanged")


class ReopenDerivesFindingStatus(unittest.TestCase):
    """*** A REOPENED OBLIGATION MUST MAKE ITS FINDING INTERNALLY OPEN. ***

    *THE OVERCLAIM THIS PREVENTS: flipping an obligation to OPEN while a finding stays `COMPLETE` would leave live work
    inside a completed finding -- the exact defect AUDIT-B1-CTRL-001 exists to refuse, re-created by the reopen itself.*
    """

    def setUp(self) -> None:
        self.mod = _load()

    def test_the_live_reopened_findings_derive_open(self) -> None:
        """*** A FINDING LIVES IN ONE OF TWO POPULATIONS; THE ARM MUST ASK THE RIGHT ONE. ***

        *THE DEFECT THIS CLOSES, MEASURED: this arm indexed `ledger["findings"]` directly, but `GS-FINAL-003` and
        `GS-UX-001` are INDEPENDENT-audit findings -- they live under
        `independent_audit_new_findings.findings` -- so the arm raised KeyError rather than judging the rule.* **It now
        reads the DERIVED closure (which merges both populations) and asserts the invariant: a finding whose
        obligations include unresolved work derives OPEN from those obligations.**
        """
        closure = self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8")))
        for fid in ("GS-FINAL-003", "GS-UX-001", "AUDIT-B1-CTRL-001"):
            with self.subTest(finding=fid):
                entry = closure[fid]
                obls = entry.get("internal_obligations") or []
                self.assertTrue(obls, f"{fid} must carry authored obligations")
                self.assertFalse(self.mod.obligations_are_terminal(entry),
                                 f"{fid} carries unresolved obligations, so it may not derive terminal")
                self.assertEqual(entry["internal_status"], "OPEN")
                self.assertEqual(entry["internal_status_source"], "derived_from_obligations")

    def test_an_unknown_finding_state_is_refused(self) -> None:
        closure = json.loads(json.dumps(self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8")))))
        fid = next(iter(closure))
        closure[fid]["internal_status"] = "PARTIAL"
        problems = self.mod.internal_status_state_problems(closure)
        self.assertTrue(any(fid in p for p in problems),
                        "an unknown finding state is neither open nor terminal and must be NAMED")

    def test_known_internal_gaps_only_while_open(self) -> None:
        """*An OPEN finding's live gaps must be named; a discharged finding's gap prose is HISTORY.*

        *Proven on an AUTHORED pair -- one OPEN finding and one terminal -- so the rule is exercised whatever the live
        frontier happens to carry.*
        """
        open_only = {
            "SYNTHETIC-OPEN": {
                "internal_status": "OPEN",
                "internal_obligations": [{"id": "synthetic.open", "text": "t", "status": "OPEN",
                                          "evidence": ["`path:scripts/build_structured_closure.py`"]}],
            }
        }
        sem_open = self.mod.structured_semantics(open_only)
        self.assertIn("SYNTHETIC-OPEN", sem_open["known_internal_gaps"],
                      "an internally OPEN finding's live gaps must be named")
        terminal = {
            "SYNTHETIC-DONE": {
                "internal_status": "COMPLETE",
                "internal_obligations": [{"id": "synthetic.done", "text": "t", "status": "DISCHARGED",
                                          "structured_discharge": json.loads(json.dumps(
                                              StructuredDischargeContradiction.VALID_DISCHARGE)),
                                          "evidence": ["`path:scripts/build_structured_closure.py`"]}],
            }
        }
        sem_done = self.mod.structured_semantics(terminal)
        self.assertNotIn("SYNTHETIC-DONE", sem_done["known_internal_gaps"],
                         "a discharged finding's gap prose is HISTORY, not outstanding work")
        # AND THE LIVE TREE HONOURS THE SAME RULE, READ FROM ITS OWN STATE.
        live = self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8")))
        live_sem = self.mod.structured_semantics(live)
        for fid, f in live.items():
            with self.subTest(finding=fid):
                if f.get("internal_status") == "OPEN" and f.get("internal_obligations"):
                    self.assertIn(fid, live_sem["known_internal_gaps"],
                                  "an internally OPEN finding's live gaps must be named")
                else:
                    self.assertNotIn(fid, live_sem["known_internal_gaps"],
                                     "a discharged finding's gap prose is HISTORY, not outstanding work")

    def test_every_open_obligation_carries_a_measured_gap_record(self) -> None:
        """*** THE REVIEW-SOURCE MAPPING MUST TRAVEL WITH THE OBLIGATION, BY CANONICAL IDENTITY. ***

        *The mission requires the canonical reviews' findings mapped to the SAME canonical obligations -- never a new
        finding and never a duplicate -- and kept OPEN pending proof. The obligation's own `known_internal_gaps` is
        where that mapping lives, so every OPEN obligation must carry at least one RECORD (a dict with a `defect`),
        not merely prose.*
        """
        closure = self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8")))
        missing = []
        for fid, f in closure.items():
            for o in f["internal_obligations"]:
                if o.get("status") not in self.mod.UNRESOLVED_OBLIGATION_STATES:
                    continue
                records = [g for g in (o.get("known_internal_gaps") or []) if isinstance(g, dict) and g.get("defect")]
                if not records:
                    missing.append(o["id"])
        self.assertEqual(missing, [],
                         "every OPEN obligation must carry at least one structured gap record mapping its "
                         "canonical review finding")

    def test_the_gap_records_name_their_review_source(self) -> None:
        """*An authored gap records where it came from; the inline prose gaps are normalised to `defect` and need not.*"""
        closure = self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8")))
        authored = [g for f in closure.values() for o in f["internal_obligations"]
                    for g in (o.get("known_internal_gaps") or [])
                    if isinstance(g, dict) and g.get("what_must_land")]
        self.assertTrue(authored, "the live tree must carry authored gap records")
        for g in authored:
            with self.subTest(defect=g.get("defect")):
                self.assertTrue(g.get("source"), "an authored gap must name the review it came from")
                self.assertTrue(g.get("canonical_defect"), "and the canonical defect it corresponds to")
        # AND NO REVIEW FINDING MAY BE COUNTED AS A NEW FINDING: the closure's finding count is unchanged.
        self.assertEqual(len(closure), 68, "mapping gap records must NOT add findings")

    def test_the_scan_carries_no_closure_authority(self) -> None:
        """*The scan may point at a discharge; it may never move a count. A word list is not a measurement.*"""
        closure = self.mod.build(json.loads(self.mod.LEDGER.read_text(encoding="utf-8")))
        before = self.mod.counts(closure)
        fid = next(f for f, e in closure.items() if e.get("internal_obligations"))
        o = closure[fid]["internal_obligations"][0]
        o["text"] = (o.get("text", "") + " gap absent missing not satisfied not implemented still owed "
                     "uncovered cannot not executed placeholder deferred TODO")
        self.assertEqual(self.mod.counts(closure), before,
                         "the gap-word scan must never feed a count")
