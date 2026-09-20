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
    """*** RE-PROVED AFTER EVERY BATCH OF DISCHARGES, BECAUSE BULK-DISCHARGING CAN NEUTER THE GUARD. ***"""

    def setUp(self) -> None:
        self.mod = _load()
        self.backup = CLOSURE.read_bytes()

    def tearDown(self) -> None:
        CLOSURE.write_bytes(self.backup)

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

        doc = json.loads(CLOSURE.read_text(encoding="utf-8"))
        doc["status"] = "READY_FOR_EXTERNAL_REAUDIT"
        CLOSURE.write_text(json.dumps(doc, indent=2), encoding="utf-8")

        proc = subprocess.run(
            ["python3", str(GATE), "--check"], capture_output=True, text=True, cwd=str(REPO), timeout=600,
        )
        self.assertEqual(
            proc.returncode, 1,
            "*** THE LAW MUST STILL REFUSE. If forcing READY now exits 0 while "
            f"{open_obligations} internal obligation(s) are still OPEN, the gate has been neutered by the very "
            "discharges it was supposed to audit -- and that is the batch that was wrong. ***",
        )
        self.assertIn(
            "MAY NOT", proc.stdout,
            "and the refusal must SAY WHY, naming the open work",
        )

    def test_verified_fixed_may_not_be_written_by_this_builder(self) -> None:
        doc = json.loads(CLOSURE.read_text(encoding="utf-8"))
        doc["verified_fixed"] = 1
        CLOSURE.write_text(json.dumps(doc, indent=2), encoding="utf-8")
        proc = subprocess.run(
            ["python3", str(GATE), "--check"], capture_output=True, text=True, cwd=str(REPO), timeout=600,
        )
        self.assertEqual(
            proc.returncode, 1,
            "only an INDEPENDENT audit may write `verified_fixed`, and this builder must refuse to carry it",
        )


if __name__ == "__main__":
    unittest.main()
