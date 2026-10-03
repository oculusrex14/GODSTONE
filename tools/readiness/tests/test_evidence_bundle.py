"""*** THE EVIDENCE POPULATION BUNDLE: REPO-OWNED vs HISTORICAL vs EXTERNAL, AND THE DENOMINATOR. ***

*The bundle is what VerifyFreeze's manifest binds BY DIGEST, so this court proves the three things a consumer relies
on: the document re-derives, every digested path exists with its digest, and the ledger's registered partition CLOSES.*
"""
from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
BUNDLE = REPO / "docs" / "remediation" / "evidence" / "board1-evidence-bundle.json"
GEN = REPO / "scripts" / "build_evidence_bundle.py"


def _load():
    spec = importlib.util.spec_from_file_location("evidence_bundle_under_test", GEN)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class TheBundleIsConsistent(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = _load()
        self.doc = json.loads(BUNDLE.read_text(encoding="utf-8"))

    def test_the_document_digest_re_derives(self) -> None:
        claimed = self.doc["document_sha256"]
        body = {k: v for k, v in self.doc.items() if k != "document_sha256"}
        self.assertEqual(claimed, self.mod.document_digest(body))

    def test_every_digested_path_exists_with_its_digest(self) -> None:
        for rel, want in self.doc["digests"].items():
            with self.subTest(path=rel):
                p = REPO / rel
                self.assertTrue(p.is_file(), f"{rel} must be present in a clean clone")
                self.assertEqual(self.mod.sha256_file(p), want)

    def test_every_historical_path_exists_with_its_digest(self) -> None:
        """*An absent historical identity is a REFUSAL, never an omission.*"""
        for rec in self.doc["historical"]:
            with self.subTest(path=rec["path"]):
                p = REPO / rec["path"]
                self.assertTrue(p.is_file(), f"historical bytes {rec['path']} must be tracked and present")
                self.assertEqual(self.mod.sha256_file(p), rec["sha256"])

    def test_historical_records_are_marked_historical(self) -> None:
        for rec in self.doc["historical"]:
            self.assertIn("HISTORICAL", rec["scope"])

    def test_the_bundle_does_not_digest_itself(self) -> None:
        self.assertNotIn("board1-evidence-bundle.json", " ".join(self.doc["digests"]))

    def test_the_denominator_closes(self) -> None:
        r = self.doc["ledger_registered_partition"]
        accounted = (r["examined"] + r["unresolved"] + r["unnamed"] + r["declared_lost"] + r["undigested"])
        self.assertTrue(r["counts_accounted"])
        self.assertEqual(accounted, r["registered"], "the five-way partition must close against registered")

    def test_external_identities_are_named_and_not_fabricated_green(self) -> None:
        for gate in self.doc["external"]:
            self.assertTrue(gate["id"])
            self.assertIn(gate["status"], ("BLOCKED_EXTERNAL", "OPEN", "CLOSED"))
            if gate["status"] != "CLOSED":
                self.assertIsNone(gate["closure_evidence"],
                                  "a non-CLOSED gate may not carry closure evidence")

    def test_no_internal_green_depends_on_the_out_of_repo_root(self) -> None:
        """*The declared out-of-repo root must be marked non-required, so a clean clone is not failed by its absence.*"""
        declared = self.doc["historical_root_declared"]
        self.assertIn("NOT required", declared["availability"])


class TheBundleRefusesWhatItCannotProve(unittest.TestCase):
    """*** THE THREE DEFECTS THE GENERATOR NOW REFUSES, EACH MEASURED AGAINST `check()` ON THE REAL DOCUMENT. ***

    *The court above pins the COMMITTED document's shape; these arms pin the REFUSALS, so a future edit that quietly
    restores the directory walk, trusts the stored partition, or degrades a missing release authority into an empty
    external population reddens HERE rather than passing silently.*

      * a digested path that is UNTRACKED (the directory-walk defect) is refused by name;
      * a tracked evidence file the bundle does NOT digest is refused (membership in both directions);
      * an EMPTY external population is refused -- "no external work remains" is the false all-clear;
      * a MALFORMED or ABSENT release authority fails closed rather than yielding an empty gate list;
      * a MOVED historical anchor is refused, so a rewritten "frozen" run cannot read as frozen.
    """

    def setUp(self) -> None:
        self.mod = _load()
        self.doc = json.loads(BUNDLE.read_text(encoding="utf-8"))

    def _problems(self, mutate) -> list[str]:
        doc = json.loads(json.dumps(self.doc))
        mutate(doc)
        return self.mod.check(doc)

    def test_an_untracked_digest_entry_is_refused(self) -> None:
        """*The directory-walk defect: a file the clone cannot carry must never be presented as clean-clone bytes.*"""
        untracked = self.doc.get("untracked_present") or []
        self.assertTrue(untracked, "the fixture carries at least one untracked present file to digest illegally")
        rel = untracked[0]

        def m(doc):
            # A digest entry for a path that is PRESENT but UNTRACKED -- and an honest body digest over it.
            import hashlib
            p = REPO / rel
            doc["digests"][rel] = hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() else "0" * 64
            body = {k: v for k, v in doc.items() if k != "document_sha256"}
            doc["document_sha256"] = self.mod.document_digest(body)

        problems = self._problems(m)
        self.assertTrue(any("UNTRACKED" in p or "clean clone" in p for p in problems),
                        f"an untracked digested path must be refused, got {problems[:3]}")

    def test_a_missing_tracked_entry_is_refused(self) -> None:
        def m(doc):
            rel = next(iter(doc["digests"]))
            del doc["digests"][rel]
            body = {k: v for k, v in doc.items() if k != "document_sha256"}
            doc["document_sha256"] = self.mod.document_digest(body)

        problems = self._problems(m)
        self.assertTrue(any("does NOT digest" in p for p in problems),
                        f"a tracked file absent from the digest set must be refused, got {problems[:3]}")

    def test_an_empty_external_population_is_refused(self) -> None:
        def m(doc):
            doc["external"] = []
            body = {k: v for k, v in doc.items() if k != "document_sha256"}
            doc["document_sha256"] = self.mod.document_digest(body)

        problems = self._problems(m)
        self.assertTrue(any("NO external gates" in p or "empty external population" in p for p in problems),
                        f"an empty external population must be refused, got {problems[:3]}")

    def test_a_malformed_release_authority_fails_closed(self) -> None:
        """*A gate document that cannot be read is NOT an empty gate population.*"""
        import tempfile
        from pathlib import Path
        original = self.mod.RELEASE_GATES
        try:
            with tempfile.TemporaryDirectory() as td:
                for payload in ("{ not json", json.dumps({"gates": []}), json.dumps({"gates": [{"gate": "X", "status": "WEIRD"}]})):
                    p = Path(td) / "gates.json"
                    p.write_text(payload, encoding="utf-8")
                    self.mod.RELEASE_GATES = p
                    gates, problems = self.mod.external_identities()
                    self.assertEqual(gates, [])
                    self.assertTrue(problems, f"{payload[:20]!r} must fail closed with a named problem")
                self.mod.RELEASE_GATES = Path(td) / "absent.json"
                gates, problems = self.mod.external_identities()
                self.assertEqual(gates, [])
                self.assertTrue(problems, "an ABSENT release authority must fail closed, not read as empty")
        finally:
            self.mod.RELEASE_GATES = original

    def test_a_moved_historical_anchor_is_refused(self) -> None:
        def m(doc):
            doc["historical_anchor"]["tag_object_sha"] = "0" * 40
            body = {k: v for k, v in doc.items() if k != "document_sha256"}
            doc["document_sha256"] = self.mod.document_digest(body)

        problems = self._problems(m)
        self.assertTrue(any("anchor" in p.lower() for p in problems),
                        f"a moved anchor must be refused, got {problems[:3]}")

    def test_a_tampered_historical_digest_is_refused(self) -> None:
        def m(doc):
            doc["historical"][0]["sha256"] = "0" * 64
            body = {k: v for k, v in doc.items() if k != "document_sha256"}
            doc["document_sha256"] = self.mod.document_digest(body)

        problems = self._problems(m)
        self.assertTrue(any("historical" in p for p in problems),
                        f"a historical digest that disagrees with the anchor must be refused, got {problems[:3]}")

    def test_the_committed_document_carries_no_refusal(self) -> None:
        self.assertEqual(self.mod.check(self.doc), [],
                         "the committed bundle must satisfy every refusal it claims")


if __name__ == "__main__":
    unittest.main()
