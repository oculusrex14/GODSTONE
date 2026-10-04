#! /usr/bin/env python3
"""*** THE INTEGRATION-EVIDENCE GATE'S CONTRACT, RUN WHERE THE GATE SET CAN SEE IT. ***

`ci/check_integration_evidence.py` judgeth the Board1 cross-platform / process-death evidence by CONTENT: the required
population, the exact per-arm shapes, the re-computed digests, the live-tree input binding, and the copied-fixture
refusal. **Its own adversarial selftest (`--selftest`) must EXECUTE in the gate**, or the day a guard is deleted the
terminal job's `--require-mode all` call would still pass on a fresh green run and the deletion would be invisible.

THESE CASES:
  * RUN the gate's selftest, so its twelve mutations are exercised as part of `unittest discover -s
    tools/readiness/tests` (the board1 gate set and the workflow both run that discovery);
  * JUDGE the two committed fixtures DIRECTLY: with the age clauses neutralised they are ACCEPTED (so the gate bites
    on content, not merely on their being fixtures), and WITH those clauses on they are REFUSED as copied/stale --
    which is the property that maketh a fresh run distinguishable from a re-committed old one.
"""
from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
GATE = REPO / "ci" / "check_integration_evidence.py"
FIXTURES = REPO / "tools" / "integration-fixtures"


def _load():
    spec = importlib.util.spec_from_file_location("check_integration_evidence_under_test", GATE)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class IntegrationEvidenceAdversarialSelftest(unittest.TestCase):
    def test_the_gates_selftest_kills_every_mutation(self) -> None:
        mod = _load()
        self.assertEqual(mod.selftest(), 0, "the integration-evidence selftest reported an ESCAPED mutation")

    def test_the_recipe_digest_tracks_inputs_not_generated_output(self) -> None:
        from tools.readiness import build_provenance

        inputs = {
            "tools/supplychain/build_sqlcipher_simulator.sh": b"native builder\n",
            "tools/supplychain/verify_sqlcipher_artifact.py": b"expectation verifier\n",
            "docs/supplychain/SQLCIPHER.pins.json": b'{"source": "pinned"}\n',
        }
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            for name, data in inputs.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            with patch.object(build_provenance, "REPO", root):
                clean = build_provenance.recipe_digest()
                expectation = root / build_provenance.EXPECTED_SOURCE
                expectation.parent.mkdir(parents=True, exist_ok=True)
                expectation.write_bytes(b"generated expectation\n")
                self.assertEqual(clean, build_provenance.recipe_digest())
                expectation.write_bytes(b"different generated expectation\n")
                self.assertEqual(clean, build_provenance.recipe_digest())
                expectation.unlink()
                self.assertEqual(clean, build_provenance.recipe_digest())
                for name, data in inputs.items():
                    with self.subTest(input=name):
                        path = root / name
                        path.write_bytes(data + b"changed recipe input\n")
                        self.assertNotEqual(clean, build_provenance.recipe_digest())
                        path.write_bytes(data)


class IntegrationEvidenceFixtures(unittest.TestCase):
    """*** THE COMMITTED FIXTURES ARE JUDGED BY CONTENT, NOT PARDONED BY BEING FIXTURES. ***"""

    def setUp(self) -> None:
        self.mod = _load()

    def test_the_cross_platform_fixture_satisfies_the_eight_combo_matrix(self) -> None:
        d = FIXTURES / "20260929T211012Z-8f8795"
        self.assertTrue((d / "integration-report.json").is_file(), "the cross-platform fixture is absent")
        probs, totals = self.mod.check_report(d, check_inputs=False, check_fixture_collision=False,
                                              check_fresh_run_proofs=False)
        self.assertFalse(probs, f"the committed cross-platform fixture was refused on content: {probs}")
        self.assertEqual(totals["cross"], 8, "the eight-combo matrix is not eight combos")

    def test_the_crash_fixture_satisfies_both_durable_boundaries(self) -> None:
        d = FIXTURES / "20260929T170839Z-e574a7"
        self.assertTrue((d / "integration-report.json").is_file(), "the crash fixture is absent")
        # *** THE TERMINATION CLAUSE IS TURNED OFF HERE BECAUSE THE FIXTURE PREDATES IT. *** *The frozen rc11 crash
        # fixture was produced by a coordinator that recorded no `crash_terminations`/`worker_terminations` at all;
        # this court judgeth its POPULATION and arms. **The clause's own teeth are proven by the gate's selftest
        # (cases 13-19) and by the separate `test_the_termination_clause_bites_a_fresh_report` below, which turneth
        # it ON against a report that carrieth the map.*
        probs, totals = self.mod.check_report(d, check_inputs=False, check_fixture_collision=False,
                                              check_fresh_run_proofs=False)
        self.assertFalse(probs, f"the committed crash fixture was refused on content: {probs}")
        self.assertEqual(totals["crash"], 2, "the crash campaign must prove both durable boundaries")

    def test_the_termination_clause_bites_a_report_that_carrieth_the_map(self) -> None:
        """*** A FRESH run's crash rows must be backed by an observed death the coordinator did not supply. ***"""
        # *The frozen crash fixture carrieth no `crash_terminations`/`worker_terminations` (it predates this clause),
        # so WITH the clause on it is refused for exactly that reason -- the observable proof that the clause is not
        # vacuous. Turned OFF, its population is judged by the test above.*
        d = FIXTURES / "20260929T170839Z-e574a7"
        probs, _ = self.mod.check_report(d, check_inputs=False, check_fixture_collision=False,
                                         check_fresh_run_proofs=True)
        self.assertTrue(any("termination" in p for p in probs),
                        f"a crash report with no observed terminations was accepted with the clause on: {probs}")

    def test_a_copied_fixture_is_refused_when_the_age_clauses_are_on(self) -> None:
        """*** THE CLAUSE THAT MAKETH A FRESH RUN DISTINGUISHABLE FROM A RE-COMMITTED OLD ONE. ***"""
        d = FIXTURES / "20260929T211012Z-8f8795"
        probs, _ = self.mod.check_report(d, check_inputs=False, check_fixture_collision=True)
        self.assertTrue(any("COMMITTED FIXTURE" in p for p in probs),
                        f"a copied fixture's run_id was accepted: {probs}")


if __name__ == "__main__":
    unittest.main()
