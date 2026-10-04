"""The evidence population bundle: repo-owned vs historical vs external, and the denominator.

The bundle is what VerifyFreeze's manifest binds by digest, so this court proves the three things a consumer relies
on: the document re-derives, every digested path exists with its digest, and the ledger's registered partition closes.

External dispositions must re-derive from a tracked, content-addressed proof archive, not from a user's builder root.
A clean clone cannot carry the out-of-repository builder root, so a re-derivation that read it reported every external
reference unresolved and refused the committed document for the runner's own missing user files. The repair is
clone-carried proof: each registered external reference's bytes live, gzip-compressed, in
evidence/external-registry-proof/<registered-sha256>.gz, and scripts/evidence_registry.classify re-derives the same
examined/verified/unresolved rows from it wherever it runs.

The external-proof arms run against an isolated clone (`git clone --shared` of the repository, so Git tracking and the
anchor history are real but the main repository's Git metadata is never touched). The materializer arms use a minimal
self-contained repository with a hand-authored ledger and actual payload bytes, so a mixed population -- one valid
reference and one absent -- exercises the whole-write refusal rather than a vacuous all-absent case.
"""
from __future__ import annotations

import gzip
import hashlib
import importlib.util
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
BUNDLE = REPO / "docs" / "remediation" / "evidence" / "board1-evidence-bundle.json"
GEN = REPO / "scripts" / "build_evidence_bundle.py"
MATERIALIZER = REPO / "scripts" / "materialize_external_registry_proof.py"
REGISTRY = REPO / "scripts" / "evidence_registry.py"
LEDGER = REPO / "docs" / "remediation" / "REMEDIATION_STATE.json"


def _load(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def _load_bundle():
    return _load(GEN, "evidence_bundle_under_test")


def _registry():
    import sys
    if str(REPO / "scripts") not in sys.path:
        sys.path.insert(0, str(REPO / "scripts"))
    import evidence_registry
    return evidence_registry


def _required_shas(ledger: dict, root: Path) -> list[str]:
    """The external references the archive must carry, enumerated by the registry's own ownership authority."""
    mat = _load(MATERIALIZER, "materializer_for_required")
    tracked = set(subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                                 capture_output=True, text=True, check=True).stdout.split("\0")) - {""}
    _commit, pairs = mat._anchor()
    rows = _registry().references(ledger)
    return sorted({r["sha256"] for r in mat._required_external(rows, tracked, pairs)})


class _CloneFixture:
    """An isolated shared clone of the repository: real tracking and history, own Git metadata.

    `git clone --shared` makes the clone's own `.git` (with the repository's object store as a read-only alternate),
    so tests mutate the clone's index/worktree freely and never touch the main repository's Git metadata.
    """

    def __init__(self) -> None:
        self._td = tempfile.TemporaryDirectory(prefix="godstone-evidence-clone-")

    def __enter__(self) -> "_CloneFixture":
        self.root = Path(self._td.name) / "clone"
        subprocess.run(["git", "clone", "--quiet", "--shared", "--no-checkout", str(REPO), str(self.root)],
                       check=True, capture_output=True, timeout=600)
        subprocess.run(["git", "-C", str(self.root), "checkout", "--quiet", "--detach", "HEAD"],
                       check=True, capture_output=True, timeout=600)
        return self

    def __exit__(self, *exc) -> bool:
        self._td.cleanup()
        return False

    @property
    def archive(self) -> Path:
        return self.root / "evidence" / "external-registry-proof"

    def entry(self, sha: str) -> Path:
        return self.archive / f"{sha}.gz"

    def classify(self):
        ledger = json.loads((self.root / "docs/remediation/REMEDIATION_STATE.json").read_text(encoding="utf-8"))
        commit = json.loads((self.root / "docs/remediation/evidence/board1-evidence-bundle.json")
                            .read_text(encoding="utf-8"))["historical_anchor"]["commit_sha"]
        return _registry().classify(ledger, root=self.root, anchor_commit=commit)

    def external_record(self, result, sha: str) -> dict:
        for rec in result["records"]:
            if rec["namespace"] == "external-historical" and rec["registered_sha256"] == sha:
                return rec
        raise AssertionError(f"no external record for {sha}")


class _MaterializerFixture:
    """A minimal self-contained repository: a hand-authored ledger of two external references, actual payload bytes.

    The builder root holds a real file for the valid reference and nothing for the absent one, so the required
    population is genuinely mixed. ROOT/LEDGER/ARCHIVE and the anchor are patched on the loaded materializer so it
    reads this fixture, while the ledger parser and raw-digest logic are the real ones.
    """

    def __init__(self) -> None:
        self._td = tempfile.TemporaryDirectory(prefix="godstone-materializer-")

    def __enter__(self) -> "_MaterializerFixture":
        base = Path(self._td.name)
        self.root = base / "repo"
        self.builder = base / "builder"
        self.outside = base / "outside"
        (self.root / "docs/remediation/evidence").mkdir(parents=True)
        (self.builder / "REMEDIATION").mkdir(parents=True)
        self.outside.mkdir(parents=True)
        valid = b"a valid external proof payload\n"
        self.valid_sha = hashlib.sha256(valid).hexdigest()
        self.absent_sha = hashlib.sha256(b"the absent payload\n").hexdigest()
        self.valid_path = self.builder / "REMEDIATION" / "valid.log"
        self.absent_path = self.builder / "REMEDIATION" / "absent.log"
        self.valid_path.write_bytes(valid)
        self.ledger = {
            "schema_version": 1,
            "evidence_root": str(self.builder),
            "findings": {
                "FIXTURE-1": {
                    "my_logs": [
                        {"log": str(self.valid_path), "sha256": self.valid_sha},
                        {"log": str(self.absent_path), "sha256": self.absent_sha},
                    ]
                }
            },
        }
        ledger_path = self.root / "docs/remediation/REMEDIATION_STATE.json"
        ledger_path.write_text(json.dumps(self.ledger), encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git", "-c", "user.email=c@t", "-c", "user.name=c", "add", "-A"],
                       cwd=self.root, check=True, capture_output=True)
        subprocess.run(["git", "-c", "user.email=c@t", "-c", "user.name=c", "commit", "-qm", "seed"],
                       cwd=self.root, check=True, capture_output=True)
        return self

    def __exit__(self, *exc) -> bool:
        self._td.cleanup()
        return False

    def module(self, name: str = "materializer_under_test"):
        mat = _load(MATERIALIZER, name)
        mat.ROOT = self.root
        mat.LEDGER = self.root / "docs/remediation/REMEDIATION_STATE.json"
        mat.ARCHIVE = self.root / "evidence" / "external-registry-proof"
        mat._anchor = lambda: ("0" * 40, set())
        return mat

    def make_all_valid(self) -> None:
        """Write the absent reference's payload so every required source is readable."""
        self.absent_path.write_bytes(b"the absent payload\n")


class TheBundleIsConsistent(unittest.TestCase):
    def setUp(self) -> None:
        self.mod = _load_bundle()
        self.doc = json.loads(BUNDLE.read_text(encoding="utf-8"))

    def test_the_document_digest_re_derives(self) -> None:
        body = {k: v for k, v in self.doc.items() if k != "document_sha256"}
        self.assertEqual(self.doc["document_sha256"], self.mod.document_digest(body))

    def test_every_digested_path_exists_with_its_digest(self) -> None:
        for rel, want in self.doc["digests"].items():
            with self.subTest(path=rel):
                p = REPO / rel
                self.assertTrue(p.is_file(), f"{rel} must be present in a clean clone")
                self.assertEqual(self.mod.sha256_file(p), want)

    def test_every_historical_path_exists_with_its_digest(self) -> None:
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
        accounted = r["examined"] + r["unresolved"] + r["unnamed"] + r["declared_lost"] + r["undigested"]
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
        declared = self.doc["historical_root_declared"]
        self.assertIn("NOT required", declared["availability"])


class TheBundleRefusesWhatItCannotProve(unittest.TestCase):
    """The defects the generator refuses, each measured against check() on the real document.

    These arms pin the refusals, so a future edit that quietly restores the directory walk, trusts the stored
    partition, or degrades a missing release authority into an empty external population reddens here:

      - a digested path that is untracked (the directory-walk defect) is refused by name;
      - a tracked evidence file the bundle does not digest is refused (membership in both directions);
      - an empty external population is refused -- "no external work remains" is the false all-clear;
      - a malformed or absent release authority fails closed rather than yielding an empty gate list;
      - a moved historical anchor is refused, so a rewritten frozen run cannot read as frozen.
    """

    def setUp(self) -> None:
        self.mod = _load_bundle()
        self.doc = json.loads(BUNDLE.read_text(encoding="utf-8"))

    def _problems(self, mutate) -> list[str]:
        doc = json.loads(json.dumps(self.doc))
        mutate(doc)
        return self.mod.check(doc)

    def test_an_untracked_digest_entry_is_refused(self) -> None:
        """The directory-walk defect: a file the clone cannot carry must never be presented as clean-clone bytes.

        The fixture owns its population. This arm seeds one tracked evidence file, commits, then adds one untracked
        evidence file with explicit bytes; a digest entry over the tracked file is accepted (positive control), and
        the same entry for the untracked file is refused.
        """
        with _MaterializerFixture() as fx:
            root = fx.root
            mod = _load_bundle()
            mod.ROOT = root
            mod.OUT = root / "docs/remediation/evidence/board1-evidence-bundle.json"
            mod.EVIDENCE_REL = "docs/remediation/evidence"
            tracked_rel = "docs/remediation/evidence/tracked-baseline.json"
            (root / tracked_rel).write_text('{"tracked": true}\n', encoding="utf-8")
            subprocess.run(["git", "-C", str(root), "add", "-A"], check=True, capture_output=True)
            subprocess.run(["git", "-C", str(root), "-c", "user.email=c@t", "-c", "user.name=c",
                            "commit", "-qm", "track"], check=True, capture_output=True)
            untracked_rel = "docs/remediation/evidence/untracked-fixture.log"
            payload = b"an untracked user file the clean clone cannot carry\n"
            (root / untracked_rel).write_bytes(payload)
            self.assertEqual([untracked_rel], mod.untracked_evidence_paths(),
                             "the fixture must carry exactly the untracked file it seeded")

            def document_with(rel_to_digest: str | None) -> dict:
                digests = {tracked_rel: mod.sha256_file(root / tracked_rel)}
                if rel_to_digest is not None:
                    digests[rel_to_digest] = hashlib.sha256(payload).hexdigest()
                doc = {
                    "digests": digests,
                    "untracked_present": [untracked_rel],
                    "external": [{"id": "X", "class": "external-gate", "status": "OPEN", "closure_evidence": None}],
                    "historical": [],
                    "historical_root_declared": {"path": "/nonexistent/builder",
                                                 "availability": "out-of-repo, NOT required"},
                    "historical_anchor": {"tag_object_sha": "0" * 40},
                }
                body = {k: v for k, v in doc.items() if k != "document_sha256"}
                doc["document_sha256"] = mod.document_digest(body)
                return doc

            clean = mod.check(document_with(None))
            self.assertFalse(any("UNTRACKED" in p or "clean clone" in p for p in clean),
                             f"the tracked-only control must not be refused as untracked, got {clean[:3]}")
            problems = mod.check(document_with(untracked_rel))
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
        original = self.mod.RELEASE_GATES
        try:
            with tempfile.TemporaryDirectory() as td:
                for payload in ("{ not json", json.dumps({"gates": []}),
                                json.dumps({"gates": [{"gate": "X", "status": "WEIRD"}]})):
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

    def _with_malformed_ledger(self, mod, body):
        ledger = json.loads(LEDGER.read_text(encoding="utf-8"))
        ledger["evidence_root"] = "relative/not/absolute"
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as tf:
            json.dump(ledger, tf)
            path = Path(tf.name)
        saved = mod.LEDGER
        mod.LEDGER = path
        return saved, path

    def test_the_producer_refuses_a_malformed_declaration(self) -> None:
        """A malformed declared identity refuses at build(), not merely in the stored partition."""
        saved, path = self._with_malformed_ledger(self.mod, None)
        try:
            _body, problems = self.mod.build()
        finally:
            self.mod.LEDGER = saved
            path.unlink(missing_ok=True)
        self.assertTrue(any("evidence_root" in p for p in problems),
                        f"build() must refuse a malformed declaration, got {problems[:4]}")

    def test_a_resealed_malformed_declaration_cannot_pass_the_consumer(self) -> None:
        """A rebuilt document matching a malformed registry must still be refused by check().

        The malformed ledger is installed while build() derives a body, so the body's partition, source digest and
        document digest are all computed FROM the malformed registry. That matching document is then offered to
        check() -- which must refuse the bad registry itself, not merely report a mismatch, so a reseal that made the
        stored and live lists equal cannot smuggle a malformed identity past the consumer.
        """
        saved, path = self._with_malformed_ledger(self.mod, None)
        try:
            body, _problems = self.mod.build()
            problems = self.mod.check(body)
        finally:
            self.mod.LEDGER = saved
            path.unlink(missing_ok=True)
        self.assertTrue(any("evidence_root" in p for p in problems),
                        f"check() must refuse a malformed registry even for a matching document, got {problems[:4]}")

    def test_an_absent_absolute_declaration_is_accepted(self) -> None:
        """A valid ABSENT absolute declaration is lawful: the root is declared but never required.

        Only the identity is judged here; the committed document still names its own root, so the comparison arms are
        exercised against classify() directly rather than a document declaring a different root.
        """
        er = _registry()
        ledger = json.loads(LEDGER.read_text(encoding="utf-8"))
        ledger["evidence_root"] = "/nonexistent/GODSTONE_BUILDER_EVIDENCE"
        result = er.classify(ledger, root=REPO,
                             anchor_commit=json.loads(BUNDLE.read_text(encoding="utf-8"))
                             ["historical_anchor"]["commit_sha"])
        self.assertEqual([], result["problems"],
                         f"an absent absolute declaration must be lawful, got {result['problems']}")


class TheExternalProofIsCloneCarried(unittest.TestCase):
    """Every external disposition re-derives from the tracked archive, and every absence refuses.

    Each arm mutates an actual archive file in an isolated clone and asserts the outcome for ONE KNOWN required
    reference (the smallest enumerated digest, chosen explicitly), never a vacuous non-empty count.
    """

    @classmethod
    def setUpClass(cls):
        cls.ledger = json.loads(LEDGER.read_text(encoding="utf-8"))
        cls.required = _required_shas(cls.ledger, REPO)
        cls.sha = cls.required[0]  # a known required identity, selected explicitly

    def test_the_committed_document_rederives_from_the_clone_carried_archive(self) -> None:
        mod = _load_bundle()
        doc = json.loads(BUNDLE.read_text(encoding="utf-8"))
        self.assertEqual([], mod.check(doc), "the committed bundle must re-derive clean")
        result = _registry().classify(self.ledger, root=REPO,
                                      anchor_commit=doc["historical_anchor"]["commit_sha"])
        examined = {r["registered_sha256"] for r in result["records"]
                    if r["namespace"] == "external-historical" and r["disposition"] == "examined"}
        # The examined identities are exactly the enumerated required population, each with a proof.
        self.assertEqual(set(self.required), examined)
        for sha in self.required:
            rec = next(r for r in result["records"]
                       if r["namespace"] == "external-historical" and r["registered_sha256"] == sha)
            self.assertTrue(rec["proof"], f"{sha} must re-derive examined+verified")

    def test_the_rederivation_does_not_depend_on_the_live_root(self) -> None:
        """The consumer must re-derive the same dispositions with the declared root absent."""
        er = _registry()
        ledger = dict(self.ledger)
        ledger["evidence_root"] = "/nonexistent/GODSTONE_BUILDER_EVIDENCE"
        result = er.classify(ledger, root=REPO,
                             anchor_commit=self._anchor())
        rec = next(r for r in result["records"]
                   if r["namespace"] == "external-historical" and r["registered_sha256"] == self.sha)
        self.assertEqual("examined", rec["disposition"], "the live root must not affect re-derivation")
        self.assertTrue(rec["proof"])
        self.assertEqual([], result["problems"])

    def _anchor(self) -> str:
        return json.loads((REPO / "docs/remediation/evidence/board1-evidence-bundle.json")
                          .read_text(encoding="utf-8"))["historical_anchor"]["commit_sha"]

    def test_a_malformed_declaration_cannot_hide_behind_a_valid_archive(self) -> None:
        er = _registry()
        bad = json.loads(json.dumps(self.ledger))
        bad["evidence_root"] = "relative/not/absolute"
        result = er.classify(bad, root=REPO, anchor_commit=self._anchor())
        self.assertTrue(any("evidence_root" in p for p in result["problems"]),
                        f"a malformed declaration must be a named problem, got {result['problems']}")
        mat = _load(MATERIALIZER, "materializer_declaration")
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8") as tf:
            json.dump(bad, tf)
            path = Path(tf.name)
        saved = mat.LEDGER
        try:
            mat.LEDGER = path
            _n, problems = mat.check()
        finally:
            mat.LEDGER = saved
            path.unlink(missing_ok=True)
        self.assertTrue(any("evidence_root" in p or p.startswith("classify:") for p in problems),
                        f"check() must surface the malformed declaration, got {problems[:3]}")

    def test_a_missing_archive_entry_refuses(self) -> None:
        with _CloneFixture() as fx:
            before = fx.external_record(fx.classify(), self.sha)
            self.assertEqual("examined", before["disposition"])
            fx.entry(self.sha).unlink()
            after = fx.classify()
            self.assertEqual("unresolved", fx.external_record(after, self.sha)["disposition"],
                             "a missing proof must re-derive unresolved")
            # Every other known-required identity is still examined from the archive.
            for sha in self.required[1:]:
                self.assertEqual("examined", fx.external_record(after, sha)["disposition"])

    def test_an_untracked_archive_entry_refuses(self) -> None:
        with _CloneFixture() as fx:
            subprocess.run(["git", "rm", "-q", "--cached", str(fx.entry(self.sha).relative_to(fx.root))],
                           cwd=fx.root, check=True, capture_output=True)
            self.assertTrue(fx.entry(self.sha).is_file(), "the file stays on disk but is no longer tracked")
            after = fx.classify()
            self.assertEqual("unresolved", fx.external_record(after, self.sha)["disposition"],
                             "an untracked proof is not clone-carried and must refuse")

    def test_a_corrupt_archive_entry_refuses(self) -> None:
        with _CloneFixture() as fx:
            fx.entry(self.sha).write_bytes(b"\x00 not a gzip stream \x00")
            after = fx.classify()
            self.assertEqual("unresolved", fx.external_record(after, self.sha)["disposition"],
                             "an unreadable proof must refuse")

    def test_a_tampered_archive_entry_refuses(self) -> None:
        with _CloneFixture() as fx:
            fx.entry(self.sha).write_bytes(gzip.compress(b"a different body entirely", mtime=0))
            after = fx.classify()
            self.assertEqual("unresolved", fx.external_record(after, self.sha)["disposition"],
                             "gzip bytes that do not hash to the file name must refuse")

    def test_a_symlinked_archive_directory_refuses(self) -> None:
        with _CloneFixture() as fx:
            elsewhere = Path(fx.root).parent / "elsewhere-proof"
            shutil.move(str(fx.archive), str(elsewhere))
            fx.archive.symlink_to(elsewhere, target_is_directory=True)
            after = fx.classify()
            self.assertEqual("unresolved", fx.external_record(after, self.sha)["disposition"],
                             "a symlinked archive directory must not carry proof bytes")

    def test_a_symlinked_archive_leaf_refuses(self) -> None:
        with _CloneFixture() as fx:
            real = Path(fx.root).parent / f"{self.sha}.gz"
            shutil.move(str(fx.entry(self.sha)), str(real))
            fx.entry(self.sha).symlink_to(real)
            after = fx.classify()
            self.assertEqual("unresolved", fx.external_record(after, self.sha)["disposition"],
                             "a symlinked proof leaf must not carry proof bytes")


class TheMaterializerGuardsItself(unittest.TestCase):
    """The materializer refuses a whole write on any missing required source, and never writes through a symlink.

    Each arm uses the minimal fixture with a mixed population (one valid reference, one absent) and actual payload
    bytes; materialize()/main() -- the consumer entry points -- are exercised, not a private helper.
    """

    def test_a_missing_required_source_refuses_the_whole_write(self) -> None:
        with _MaterializerFixture() as fx:
            mat = fx.module("materializer_mixed")
            # A pre-existing good entry for the VALID reference must not mask the ABSENT required reference.
            mat.ARCHIVE.mkdir(parents=True, exist_ok=True)
            good = mat.ARCHIVE / f"{fx.valid_sha}.gz"
            good.write_bytes(gzip.compress(fx.valid_path.read_bytes(), mtime=0))
            before = good.read_bytes()
            n, problems = mat.materialize()
            self.assertEqual(0, n, "a refused write must publish nothing")
            self.assertTrue(any(str(fx.absent_path) in p for p in problems),
                            f"the absent required source must be named, got {problems}")
            # No entry for the absent reference, and the pre-existing good entry is untouched.
            self.assertFalse((mat.ARCHIVE / f"{fx.absent_sha}.gz").exists(),
                             "no partial entry may be published for the absent source")
            self.assertEqual(before, good.read_bytes(), "a pre-existing entry must not be rewritten")

    def test_the_cli_refuses_a_missing_required_source(self) -> None:
        with _MaterializerFixture() as fx:
            mat = fx.module("materializer_cli")
            rc = mat.main(["--write"])
            self.assertEqual(1, rc, "the CLI must refuse a missing required source")
            self.assertFalse((mat.ARCHIVE / f"{fx.absent_sha}.gz").exists())

    def test_a_symlinked_archive_directory_refuses_and_preserves_outside_bytes(self) -> None:
        with _MaterializerFixture() as fx:
            fx.make_all_valid()
            mat = fx.module("materializer_symlink_dir")
            # The archive directory is a symlink to an outside directory holding the valid digest's destination.
            outside = fx.outside
            sentinel = outside / f"{fx.valid_sha}.gz"
            sentinel.write_bytes(b"outside sentinel bytes")
            before = sentinel.read_bytes()
            mat.ARCHIVE.parent.mkdir(parents=True, exist_ok=True)
            mat.ARCHIVE.symlink_to(outside, target_is_directory=True)
            rc = mat.main(["--write"])
            self.assertEqual(1, rc, "a write through a symlinked archive directory must refuse")
            self.assertEqual(before, sentinel.read_bytes(), "outside bytes must not be touched")

    def test_a_symlinked_destination_leaf_refuses_and_preserves_outside_bytes(self) -> None:
        with _MaterializerFixture() as fx:
            fx.make_all_valid()
            mat = fx.module("materializer_symlink_leaf")
            mat.ARCHIVE.mkdir(parents=True, exist_ok=True)
            outside = fx.outside / "real-entry.gz"
            outside.write_bytes(b"outside sentinel bytes")
            before = outside.read_bytes()
            mat.ARCHIVE.joinpath(f"{fx.valid_sha}.gz").symlink_to(outside)
            rc = mat.main(["--write"])
            self.assertEqual(1, rc, "a write through a symlinked destination must refuse")
            self.assertEqual(before, outside.read_bytes(), "the symlink target must not be truncated")


if __name__ == "__main__":
    unittest.main()
