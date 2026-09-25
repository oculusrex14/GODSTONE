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
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
GATE = REPO / "scripts" / "build_structured_closure.py"
CLOSURE = REPO / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"


def _load():
    spec = importlib.util.spec_from_file_location("closure_gate_under_test", GATE)
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

    def test_every_citation_in_the_map_carries_a_typed_token(self) -> None:
        """A DISCHARGED obligation with prose-only evidence is a status this builder may not carry."""
        offenders = []
        for fid, entry in self.mod.PARTIAL_OBLIGATIONS.items():
            for o in entry:
                if o.get("status") != "DISCHARGED":
                    continue
                cites = [c for c in (o.get("evidence") or []) if isinstance(c, str) and c.strip()]
                tokens = [t for c in cites for t in self.mod._evidence_tokens(c)]
                if not tokens:
                    offenders.append(o["id"])
        self.assertEqual(
            offenders, [],
            "every DISCHARGED obligation must cite at least one typed token (`path:`/`commit:`/`test:`) -- "
            "prose cannot carry the claim",
        )


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

    def _run_gate_against_scratch(self, mutate) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as tmp:
            scratch = Path(tmp) / "repo"
            (scratch / "scripts").mkdir(parents=True)
            (scratch / "docs" / "production-readiness").mkdir(parents=True)
            (scratch / "docs" / "remediation").mkdir(parents=True)
            shutil.copy2(GATE, scratch / "scripts" / GATE.name)
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
        self.assertEqual(
            json.loads(self.live_before)["status"], "REMEDIATION_IN_PROGRESS",
            "and it must say what it said before",
        )

    def test_a_forced_ready_status_is_refused_while_gaps_remain(self) -> None:
        ledger = json.loads(self.mod.LEDGER.read_text(encoding="utf-8"))
        closure = self.mod.build(ledger)
        open_obligations = sum(
            1 for f in closure.values()
            if isinstance(f, dict) and f.get("internal_status") == "OPEN"
            for o in (f.get("internal_obligations") or []) if o.get("status") == "OPEN"
        )
        if open_obligations == 0:
            self.skipTest("no open obligations remain, so there is nothing for the law to refuse over")

        proc = self._run_gate_against_scratch(
            lambda d: d.update(status="READY_FOR_EXTERNAL_REAUDIT"))
        self.assertEqual(
            proc.returncode, 1,
            "*** THE LAW MUST STILL REFUSE. If forcing READY now exits 0 while "
            f"{open_obligations} internal obligation(s) are still OPEN, the gate has been neutered by the very "
            "discharges it was supposed to audit -- and that is the batch that was wrong. ***",
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
        """The rule is enforced where the finding is BUILT, not only by the checker that reads it afterwards."""
        ledger = json.loads(self.mod.LEDGER.read_text(encoding="utf-8"))
        # A finding whose obligations are ALL discharged is made internally OPEN in the LEDGER.
        ledger["findings"]["GS-ARCHIVE-005"]["my_status"] = "PARTIAL"
        fid = "GS-ARCHIVE-005"
        with patch.object(self.mod, "PARTIAL_OBLIGATIONS", {
                **self.mod.PARTIAL_OBLIGATIONS,
                fid: [{"id": f"{fid}.synthetic", "text": "t", "status": "DISCHARGED",
                       "evidence": ["`path:scripts/build_structured_closure.py`"]}]}):
            with self.assertRaises(SystemExit):
                self.mod.build(ledger)

    def test_both_findings_that_were_inconsistent_now_derive_coherently(self) -> None:
        """*The two MEASURED offenders -- pinned by name so a return to the old state is loud.*"""
        for fid in ("AUDIT-B1-CTRL-001", "GS-FINAL-004"):
            with self.subTest(finding=fid):
                e = self.closure[fid]
                if e.get("internal_obligations"):
                    self.assertTrue(
                        self.mod.obligations_are_terminal(e),
                        f"{fid}'s obligations are all terminal, so it must not stand internally OPEN",
                    )
                    self.assertNotEqual(e.get("internal_status"), "OPEN")


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
                    if o.get("status") == "DISCHARGED":
                        o["status"] = "OPEN"
                        return
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
