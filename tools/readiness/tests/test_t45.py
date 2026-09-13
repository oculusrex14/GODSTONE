#! /usr/bin/env python3
"""T45 readiness court: Make archive construction atomic and deterministic.

Required scenarios (task card), one named witness each:
 - Repeat deterministic build ................ W1
 - invalid source/schema ..................... W2
 - empty corpus .............................. W3
 - interrupted build ......................... W4 (all six seams + a
   KeyboardInterrupt proxy; destination preservation; residue census)
 - FTS query ................................= W5
 - absent embedding model with --no-embed .... W5 (same road, both legs)
 - validation coverage ....................... W6 (contract, plus the
   tampered-copy negative arm)
 - over-large artifact ....................... W7
 - unsafe destination ........................ W8
 - logical digest + final byte hash truth .... W9
 - whole path to staged verification ........... W10 (licensed source ->
   final chunks -> approval verification -> immutable DB -> signed
   manifest -> staging, and the absence of a side effect when a staged
   byte is forged)
 - serialized promotion ...................... W11

Mutation (task card): "Replace destination before validation: failed-build
preservation test fails" -- the roster row T45-SM1 strikes the validation
gate and this court's W4 is the witness that must redden.

Fixtures obey the blueprint s16 law on development data: harmless
app-navigation text, obvious FIXTURE markers, isolated debug paths under a
temporary directory. The release-path witness exercises the GATE with
self-fabricated records clearly labelled T45-FIXTURE; it is not and
shall not be read as an approved corpus, and readiness stays false.
"""

from __future__ import annotations

import hashlib
import itertools
import json
import shutil
import sqlite3
import sys
import tempfile
import threading
import unittest
from dataclasses import replace as dc_replace
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import yaml  # noqa: E402

from content.ingest import build_archive as ba  # noqa: E402
from content.archive_manifest import (  # noqa: E402
    create_manifest, generate_test_keypair, load_private_key,
    load_trust_store, verify_manifest)
from content.release_gate import validate_release_corpus  # noqa: E402
from scripts import prepare_release_assets  # noqa: E402

DB_DIR = REPO / "content" / "db"

BODY = """# FIXTURE power
Press and hold the power button beside the volume rocker for two seconds
until the banner appears; release. This passage is harmless app-navigation
text marked FIXTURE, never a medical instruction (blueprint s16).

# FIXTURE scroll
Swipe down with one finger; the list scrolls. Swipe up to return. The
status bar shows the battery icon and the clock.

# FIXTURE connect
Open settings and choose the network entry; the toggle turns blue when
connected and grey when disconnected.
"""

PROBE_TERM = "power"


def _seed(root: Path, *, tiers, reviewed: bool = False,
          media: bool = True) -> Path:
    seed = root / "seed"
    docs = seed / "docs"
    docs.mkdir(parents=True, exist_ok=True)
    (seed / "taxonomy.yaml").write_text(
        "domains:\n- id: navigation\n  label: Navigation\n",
        encoding="utf-8")
    for name, tier in tiers:
        stem = name.split(".")[0]
        review_lines = ("reviewed_by: Dr. T45-FIXTURE Reviewer\n"
                        "reviewed_on: '2026-07-30'\n" if reviewed else "")
        (docs / name).write_text(
            "---\n"
            f"title: FIXTURE {stem}\n"
            "domain: navigation\n"
            f"source: T45-FIXTURE-{stem}\n"
            "licence: CC0-1.0\n"
            "revision: '1'\n"
            f"tier_min: {tier}\n"
            f"{review_lines}"
            "---\n"
            f"{BODY}\n", encoding="utf-8")
    if media:
        (seed / "media_manifest.yaml").write_text(
            "media:\n"
            "- kind: diagram\n"
            "  source: T45-FIXTURE-a\n"
            "  path: images/panel.png\n"
            "  caption: The panel\n"
            "  bytes: 12\n"
            "  sha256: " + "a" * 64 + "\n"
            "- kind: video_1080\n"
            "  source: T45-FIXTURE-a\n"
            "  path: images/deep.mp4\n"
            "  caption: Deep view\n"
            "  bytes: 34\n"
            "  sha256: " + "b" * 64 + "\n", encoding="utf-8")
    return seed


def _stage(cfg, docs):
    staged = []
    serial = 0
    for position, doc in enumerate(docs, start=1):
        for _ordinal, chunk in enumerate(chunk_document_for(cfg, doc)):
            serial += 1
            chunk.chunk_id = serial
            chunk.document_id = position
            staged.append(chunk)
    return staged


def chunk_document_for(cfg, doc):
    from content.ingest.chunker import chunk_document
    return chunk_document(doc.body, max_tokens=cfg["chunk_tokens"],
                          overlap_tokens=cfg["chunk_overlap"])


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _open_readonly(archive: Path) -> sqlite3.Connection:
    uri = f"file:{archive.resolve()}?mode=ro&immutable=1"
    return sqlite3.connect(uri, uri=True)


class T45Case(unittest.TestCase):
    BASE_TIERS = (("a.md", "LIGHT"), ("b.md", "LIGHT"), ("c.md", "MEDIUM"))

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.out = self.root / "dist" / "archive_light.db"
        self._seed_n = itertools.count()

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def build(self, **kw):
        # beware the eagerness of setdefault: its value argument is evaluated
        # whether or not the key stands, and _seed WRITES. A default seed
        # therefore goes to a directory of its own, never under a seed_root
        # the witness brought itself.
        if "seed_root" not in kw:
            kw["seed_root"] = _seed(
                self.root / f"seed-{next(self._seed_n)}",
                tiers=self.BASE_TIERS)
        kw.setdefault("db_dir", DB_DIR)
        return ba.build("LIGHT", self.out, **kw)

    def no_residue(self) -> None:
        strays = sorted(p.name for p in self.out.parent.iterdir()
                        if ".tmp-" in p.name) if self.out.parent.exists() else []
        self.assertEqual(strays, [], "the staged life left a residue behind")


class DeterminismWitness(T45Case):
    def testRepeatedBuildPublishesByteIdenticalArchives(self) -> None:
        """W1: twice on one corpus, one and the same artifact."""
        first = self.build(embed=False)
        bytes1 = self.out.read_bytes()
        second = self.build(embed=False)
        bytes2 = self.out.read_bytes()
        self.assertEqual(bytes1, bytes2,
                         "the same corpus produced different bytes")
        self.assertEqual(first.archive_sha256, second.archive_sha256)
        self.assertEqual(first.corpus_sha256, second.corpus_sha256)
        self.assertGreater(first.chunk_count, 1)
        self.assertEqual(first.document_count, 2)
        self.no_residue()


class RefusalWitness(T45Case):
    def testInvalidSourceAndBrokenSchemaAreRefusedBeforePublication(self) -> None:
        """W2: neither a forged front matter nor a fractured schema may
        reach the destination."""
        sentinel = b"PREVIOUS-GOOD-BUILD"
        self.out.parent.mkdir(parents=True, exist_ok=True)
        self.out.write_bytes(sentinel)

        seed = _seed(self.root / "bad", tiers=[("a.md", "LIGHT")])
        (seed / "docs" / "a.md").write_text(
            "---\ntitle: x\ndomain: navigation\nsource: s\nrevision: '1'\n"
            "---\nbody\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            ba.build("LIGHT", self.out, embed=False, seed_root=seed,
                     db_dir=DB_DIR)
        self.assertEqual(self.out.read_bytes(), sentinel,
                         "an invalid source moved the destination")

        broken = self.root / "db"
        broken.mkdir()
        shutil.copyfile(DB_DIR / "schema.sql", broken / "schema.sql")
        shutil.copyfile(DB_DIR / "indexes.sql", broken / "indexes.sql")
        with (broken / "schema.sql").open("a", encoding="utf-8") as seam:
            seam.write("\nCREATE TABLE broken ( x CONSTRAINT );\n")
        good = _seed(self.root / "good", tiers=self.BASE_TIERS)
        with self.assertRaises(sqlite3.DatabaseError):
            ba.build("LIGHT", self.out, embed=False, seed_root=good,
                     db_dir=broken)
        self.assertEqual(self.out.read_bytes(), sentinel,
                         "a broken schema moved the destination")
        self.no_residue()

    def testEmptyCorpusIsRefusedAsEmptyNotAsSilentSuccess(self) -> None:
        """W3: an empty selection is a named refusal, never a success that
        silently built nothing."""
        sentinel = b"PREVIOUS-GOOD-BUILD"
        self.out.parent.mkdir(parents=True, exist_ok=True)
        self.out.write_bytes(sentinel)
        seed = _seed(self.root / "empty", tiers=[("z.md", "LARGE")])
        with self.assertRaises(ba.ArchiveEmptyError):
            self.build(seed_root=seed, embed=False)
        # the named emptiness is not merely some error wearing an
        # ArchiveBuildError mask: the validation error must not answer to it
        self.assertFalse(
            issubclass(ba.ArchiveEmptyError, ba.ArchiveValidationError))
        self.assertFalse(
            issubclass(ba.ArchiveValidationError, ba.ArchiveEmptyError))
        self.assertEqual(self.out.read_bytes(), sentinel)
        self.assertFalse((Path(str(self.out) + ba.SIDECAR_SUFFIX)).exists())
        self.no_residue()

    def testOverLargeArtifactIsRefusedWithANamedError(self) -> None:
        """W7: the section 18 ceiling speaks with its own name."""
        sentinel = b"PREVIOUS-GOOD-BUILD"
        self.out.parent.mkdir(parents=True, exist_ok=True)
        self.out.write_bytes(sentinel)
        with self.assertRaises(ba.ArchiveTooLargeError):
            self.build(embed=False, max_staged_bytes=64)
        self.assertEqual(self.out.read_bytes(), sentinel)
        self.assertFalse(
            isinstance(ba.ArchiveTooLargeError(b"x"),
                       ba.ArchiveEmptyError))
        self.no_residue()
        # the ceiling is an input, not an ornament: a nonsense bound is
        # refused before any resource is touched
        with self.assertRaises(TypeError):
            self.build(embed=False, max_staged_bytes=0)
        with self.assertRaises(TypeError):
            self.build(embed=False, max_staged_bytes=True)
        with self.assertRaises(TypeError):
            self.build(embed=False, max_staged_bytes="1024")
        self.assertEqual(self.out.read_bytes(), sentinel)

    def testUnsafeDestinationsAreRefusedBeforeAnyWrite(self) -> None:
        """W8: the guard stands at the gate before the hand can write."""
        protected = self.root / "dbcopy"
        protected.mkdir()
        shutil.copyfile(DB_DIR / "schema.sql", protected / "schema.sql")
        seed = _seed(self.root, tiers=self.BASE_TIERS)
        before = (protected / "schema.sql").read_bytes()

        attempts = [
            protected / "schema.sql",                      # name, anywhere
            protected / "nested" / "indexes.sql",          # name, in depth
            self.root / "seed",                            # a bare directory
            Path(str(self.root / "dist" / "x.db")
                 + ba.SIDECAR_SUFFIX),                   # reserved tail
            Path("nul\0inside"),                            # torn string
        ]
        for attempt in attempts:
            with self.subTest(target=str(attempt)):
                with self.assertRaises(ba.ArchiveUnsafeDestinationError):
                    ba.build("LIGHT", attempt, embed=False, seed_root=seed,
                             db_dir=protected)
        self.assertEqual((protected / "schema.sql").read_bytes(), before,
                         "a refused build had still touched the contract")
        # and the writes-inside-the-frozen-dir road: db_dir itself is guarded
        with self.assertRaises(ba.ArchiveUnsafeDestinationError):
            ba.build("LIGHT", protected / "sneak.db", embed=False,
                     seed_root=seed, db_dir=protected)
        self.assertFalse((protected / "sneak.db").exists())
        self.assertFalse((protected / "sneak.db.sha256.json").exists())


class InterruptionWitness(T45Case):
    def testInterruptedBuildPreservesThePreviousBytesAtEverySeam(self) -> None:
        """W4: at every named seam an injected fault leaves the previous
        bytes standing and no residue behind."""
        base = self.build(embed=False)
        good = self.out.read_bytes()
        sidecar_before = Path(str(self.out)
                             + ba.SIDECAR_SUFFIX).read_bytes()
        seams = ("after_temp_created", "rows_inserted", "vectors_done",
                 "indexed", "before_validate", "after_validate",
                 "before_publish")
        for seam in seams:
            with self.subTest(seam=seam):
                def fault(stage: str, _seam=seam) -> None:
                    if stage == _seam:
                        raise RuntimeError(f"injected at {_seam}")
                with self.assertRaises(RuntimeError):
                    self.build(embed=False, fault_hook=fault)
                self.assertEqual(self.out.read_bytes(), good,
                                 f"the fault at {seam} moved the destination")
                self.assertEqual(
                    Path(str(self.out)
                        + ba.SIDECAR_SUFFIX).read_bytes(), sidecar_before,
                    f"the fault at {seam} rewrote the sidecar")
                self.no_residue()
        # the process-interruption proxy: a raised interrupt is a fault too
        def storm(stage: str) -> None:
            if stage == "before_publish":
                raise KeyboardInterrupt
        with self.assertRaises(KeyboardInterrupt):
            self.build(embed=False, fault_hook=storm)
        self.assertEqual(self.out.read_bytes(), good)
        self.no_residue()
        self.assertEqual(base.archive_sha256,
                         hashlib.sha256(good).hexdigest())


class QueryWitness(T45Case):
    def testFtsQueryAnswersAfterANoEmbeddingBuild(self) -> None:
        """W5: the lexical road answers without the native embedding leg;
        the vectors table stays lawfully empty."""
        result = self.build(embed=False)
        conn = _open_readonly(self.out)
        try:
            hits = conn.execute(
                "SELECT COUNT(*) FROM chunks_fts WHERE chunks_fts MATCH ?",
                (f'"{PROBE_TERM}"',)).fetchone()[0]
            self.assertGreaterEqual(hits, 1,
                                   "the FTS index does not answer")
            joined = conn.execute(
                "SELECT c.text, d.title FROM chunk_citations c "
                "JOIN documents d ON d.document_id = c.document_id "
                "WHERE c.section LIKE '%power%'").fetchall()
            self.assertGreater(len(joined), 0,
                              "the citation view does not join")
            empty = conn.execute(
                "SELECT COUNT(*) FROM vectors").fetchone()[0]
            self.assertEqual(empty, 0,
                             "--no-embed wrote vectors after all")
            meta = {str(k): str(v) for k, v in conn.execute(
                "SELECT key, value FROM archive_meta")}
            self.assertEqual(meta["corpus_sha256"], result.corpus_sha256)
            self.assertEqual(meta["chunk_count"], str(result.chunk_count))
        finally:
            conn.close()
        # the native leg was never so much as greeted
        self.assertNotIn("llama_cpp", sys.modules)
        # and a missing model cannot speak: asking for embed with the model
        # absent is a dependency refusal, and the build stands
        good = self.out.read_bytes()
        def absent(cfg):
            raise SystemExit("embedding model not found: "
                             + cfg["embed_model"])
        with self.assertRaises(ba.ArchiveDependencyError):
            self.build(embed=True, embedder_factory=absent)
        self.assertEqual(self.out.read_bytes(), good)
        self.no_residue()


class ValidationWitness(T45Case):
    def testValidationReportCoversTheWholeContract(self) -> None:
        """W6: the report names every check the contract demands; the
        tampered copy is caught by the very same eyes."""
        class FakeVec:
            def __init__(self, dim: int) -> None:
                self.dim = dim
                self.closed = False
            def encode_int8(self, text: str):
                digest = hashlib.sha256(text.encode("utf-8")).digest()
                return (bytes(((digest[i % len(digest)] - 128) & 0xFF)
                             for i in range(self.dim))), 1.7
            def close(self) -> None:
                self.closed = True

        holders: list[FakeVec] = []
        def factory(cfg):
            vec = FakeVec(cfg["embed_dim"])
            holders.append(vec)
            return vec

        result = self.build(embed=True, embedder_factory=factory)
        report = result.validation
        self.assertTrue(report.ok, str(report.failures))
        self.assertEqual(report.tier, "LIGHT")
        self.assertEqual(report.schema_version, str(ba.SCHEMA_VERSION))
        self.assertEqual(report.integrity_check, "ok")
        self.assertEqual(report.foreign_key_violations, 0)
        self.assertTrue(report.ordering_verified)
        self.assertTrue(report.metadata_roundtrip_verified)
        self.assertGreaterEqual(report.fts_probe_hits, 1)
        self.assertEqual(dict(report.counts), {
            "documents": result.document_count,
            "chunks": result.chunk_count,
            "vectors": result.chunk_count})
        for name in ("tables", "views", "integrity_check",
                     "foreign_key_check", "schema_version",
                     "ordering_documents", "ordering_chunks",
                     "count_documents", "count_chunks", "count_vectors",
                     "vectors_shape", "fts_probe", "all"):
            self.assertIn(name, report.checks,
                          f"the report omits {name}")
        self.assertEqual(len(holders), 1)
        self.assertTrue(holders[0].closed, "the embedder was left open")

        # the negative arm: forge the copy, the report must redden
        tampered = self.root / "tampered.db"
        shutil.copyfile(self.out, tampered)
        conn = sqlite3.connect(tampered)
        try:
            conn.execute("DELETE FROM chunks WHERE chunk_id = 1")
            conn.commit()
        finally:
            conn.close()
        docs = ba.load_corpus("LIGHT", seed_root=self.seed_used)
        chunks = _stage(ba.TIERS["LIGHT"], docs)
        meta = {"schema_version": str(ba.SCHEMA_VERSION), "tier": "LIGHT",
                "embed_dim": "384", "corpus_sha256": "x" * 64}
        caught = ba._validate(tampered, "LIGHT", docs, chunks, meta,
                              expect_vectors=False, embed_dim=384)
        self.assertFalse(caught.ok)
        self.assertTrue(any(f.startswith("count_chunks") or
                            f.startswith("ordering_chunks")
                            for f in caught.failures),
                        str(caught.failures))

        # and the arm that walks before the gate: an embedder that ships
        # vectors of the wrong measure must never see its artifact published
        class WrongMeasure:
            def __init__(self, dim: int) -> None:
                self.dim = dim
            def encode_int8(self, text: str):
                return b"\x01" * (self.dim - 3), 1.0
            def close(self) -> None:
                pass
        wrong = self.root / "wrong" / "archive_light.db"
        def bad_factory(cfg):
            return WrongMeasure(cfg["embed_dim"])
        with self.assertRaises(ba.ArchiveValidationError):
            ba.build("LIGHT", wrong, embed=True, seed_root=_seed(
                self.root / "wrong-seed", tiers=self.BASE_TIERS),
                db_dir=DB_DIR, embedder_factory=bad_factory)
        self.assertFalse(wrong.exists(),
                         "a misshapen vector was published all the same")
        self.assertFalse(Path(str(wrong) + ba.SIDECAR_SUFFIX).exists())
        if wrong.parent.exists():
            strays = sorted(p.name for p in wrong.parent.iterdir()
                           if ".tmp-" in p.name)
            self.assertEqual(strays, [],
                             "the refused build left a residue behind")

    def setUp(self) -> None:
        super().setUp()
        self.seed_used = _seed(self.root, tiers=self.BASE_TIERS)


class HashWitness(T45Case):
    def testResultRecordsLogicalDigestAndFinalByteHashTruthfully(self) -> None:
        """W9: the receipt tells the truth about both hashes, and the
        sidecar repeats it; a forged version number is refused."""
        result = self.build(embed=False)
        seed = _seed(self.root / "independent", tiers=self.BASE_TIERS)
        docs = ba.load_corpus("LIGHT", seed_root=seed)
        cfg = ba.TIERS["LIGHT"]
        chunks = _stage(cfg, docs)
        self.assertEqual(ba.corpus_digest(docs, chunks),
                         result.corpus_sha256,
                         "the logical digest does not match a recompute")
        self.assertEqual(hashlib.sha256(self.out.read_bytes()).hexdigest(),
                         result.archive_sha256,
                         "the final byte hash is a lie")
        sidecar = Path(str(self.out) + ba.SIDECAR_SUFFIX)
        record = ba.read_sidecar(sidecar)
        self.assertEqual(record["archive_sha256"], result.archive_sha256)
        self.assertEqual(record["corpus_sha256"], result.corpus_sha256)
        self.assertEqual(record["archive_bytes"], self.out.stat().st_size)
        self.assertEqual(record["archive_file"], self.out.name)
        self.assertEqual(record["chunk_count"], result.chunk_count)
        conn = _open_readonly(self.out)
        try:
            stored = str(conn.execute(
                "SELECT value FROM archive_meta WHERE key = 'corpus_sha256'"
            ).fetchone()[0])
        finally:
            conn.close()
        self.assertEqual(stored, result.corpus_sha256)
        # the version gate: a sidecar from tomorrow is not obeyed today
        forged = json.loads(sidecar.read_text(encoding="utf-8"))
        forged["schema"] = 99
        sidecar.write_text(json.dumps(forged), encoding="utf-8")
        with self.assertRaises(ba.ArchiveBuildError):
            ba.read_sidecar(sidecar)


class WholePathWitness(T45Case):
    """W10: licensed source -> final chunks -> approval verification ->
    immutable DB -> signed manifest -> staging, end to end, plus the
    absence of a side effect when a staged byte is forged."""

    def setUp(self) -> None:
        super().setUp()
        self.seed_used = _seed(self.root, tiers=(("a.md", "LIGHT"),
                                                 ("b.md", "LIGHT")),
                               reviewed=True)
        self.manifests = self.root / "manifests" / "documents"
        self.evidence = self.root / "manifests"
        self.manifests.mkdir(parents=True)
        for path in sorted((self.seed_used / "docs").rglob("*.md")):
            stem = path.name.split(".")[0]
            source_id = f"T45-FIXTURE-{stem}"
            (self.evidence / f"{stem}.rights.txt").write_text(
                "redistribution and derivatives permitted\n",
                encoding="utf-8")
            (self.evidence / f"{stem}.review.txt").write_text(
                "qualified reviewer approval\n", encoding="utf-8")
            (self.evidence / f"{stem}.chunks.txt").write_text(
                "all chunks reviewed with warnings attached\n",
                encoding="utf-8")
            record = {
                "schema": 1,
                "id": source_id,
                "status": "approved",
                "example": False,
                "source": {
                    "title": f"FIXTURE {stem}", "publisher": "T45 Fixture Press",
                    "edition": "1", "version": "2026.1",
                    "source_date": "2026-01-10",
                    "acquisition_date": "2026-02-01",
                    "canonical_url": "https://fixture.invalid/" + stem,
                    "source_sha256": _sha256(path),
                },
                "rights": {
                    "licence": "CC0-1.0", "attribution": "T45 fixture",
                    "redistribution_permitted": True,
                    "derivative_work_permitted": True,
                    "evidence_file": f"{stem}.rights.txt",
                    "evidence_sha256": _sha256(
                        self.evidence / f"{stem}.rights.txt"),
                },
                "review": {
                    "reviewer_id": "t45-reviewer",
                    "reviewer_role": "licensed clinician (fixture)",
                    "reviewer_qualifications": "fixture qualification 0",
                    "reviewer_identity_evidence": "fixture-identity-0",
                    "reviewed_on": "2026-07-30",
                    "review_scope":
                        "source transformation and every retrievable chunk",
                    "expires_on": "2027-03-01",
                    "approval_evidence_file": f"{stem}.review.txt",
                    "approval_evidence_sha256": _sha256(
                        self.evidence / f"{stem}.review.txt"),
                    "approval_signature": "fixture-signature-0",
                },
                "safety": {
                    "warnings_required": True,
                    "warning_sections": ["warning-1"],
                    "contraindications_required": True,
                    "contraindication_sections": ["contra-1"],
                    "chunk_boundary_approved": True,
                    "chunk_approval_evidence_file": f"{stem}.chunks.txt",
                    "chunk_approval_evidence_sha256": _sha256(
                        self.evidence / f"{stem}.chunks.txt"),
                    "jurisdiction": "global general guidance (fixture)",
                    "replacement_policy":
                        "replace on source revision or review expiry",
                },
            }
            (self.manifests / f"{source_id}.yaml").write_text(
                yaml.safe_dump(record, sort_keys=True), encoding="utf-8")

    def testReleaseBuildTraversesTheWholePathToStagedVerification(self) -> None:
        today = date(2026, 8, 6)
        result = self.build(seed_root=self.seed_used, embed=False,
                            release=True, today=today,
                            manifests_root=self.manifests,
                            evidence_root=self.evidence)

        # the approval leg, verified independently of the build
        docs = ba.load_corpus("LIGHT", seed_root=self.seed_used)
        oracle = validate_release_corpus(
            docs, self.manifests, evidence_root=self.evidence, today=today)
        conn = _open_readonly(self.out)
        try:
            meta = {str(k): str(v) for k, v in conn.execute(
                "SELECT key, value FROM archive_meta")}
        finally:
            conn.close()
        self.assertEqual(meta["source_manifest_sha256"],
                         oracle.source_set_sha256)
        self.assertEqual(meta["review_manifest_sha256"],
                         oracle.review_set_sha256)
        self.assertEqual(meta["release_manifest_set_sha256"],
                         oracle.manifest_set_sha256)
        self.assertEqual(result.release_manifest_set_sha256,
                         oracle.manifest_set_sha256)

        # the signed manifest leg
        keys = self.root / "keys"
        keys.mkdir()
        private, trust = keys / "signing.key", keys / "trust.json"
        generate_test_keypair(private, trust, key_id="T45-FIXTURE-KEY")
        signed = self.root / "signed"
        signed.mkdir()
        manifest_path = signed / "archive_light.json"
        created = create_manifest(
            self.out, manifest_path, tier="LIGHT", archive_schema=3,
            source_manifest_sha256=oracle.source_set_sha256,
            review_manifest_sha256=oracle.review_set_sha256,
            corpus_manifest_sha256=oracle.manifest_set_sha256,
            build_tool_commit="t45-fixture-commit",
            private_key=load_private_key(private), key_id="T45-FIXTURE-KEY")
        self.assertEqual(created["archive_sha256"], result.archive_sha256)
        self.assertEqual(created["archive_bytes"], result.archive_bytes)
        self.assertEqual(created["counts"]["chunks"], result.chunk_count)
        verdict = verify_manifest(
            manifest_path, self.out, load_trust_store(trust),
            expected_tier="LIGHT", expected_archive_schema=3)
        self.assertTrue(verdict.ok, str(verdict.errors))

        # the staging leg: verified bytes are staged, forged bytes are not
        payload = self.root / "payload"
        payload.mkdir()
        staged_archive = payload / "archive_light.db"
        shutil.copyfile(self.out, staged_archive)
        generation = payload / "generation.gguf"
        generation.write_bytes(b"GGUF-FIXTURE-GENERATION-BLOB\n" * 7)
        embedding = payload / "embedding.gguf"
        embedding.write_bytes(b"GGUF-FIXTURE-EMBEDDING-BLOB\n" * 5)
        release = {
            "schema": 1, "tier": "LIGHT",
            "application_id": "io.godstone.app",
            "status": "approved", "production_ready": True,
            "assets": [
                {"role": "archive", "name": "archive_light.db",
                 "source": "payload/archive_light.db",
                 "bytes": staged_archive.stat().st_size,
                 "sha256": _sha256(staged_archive)},
                {"role": "generation_model", "name": "generation.gguf",
                 "source": "payload/generation.gguf",
                 "bytes": generation.stat().st_size,
                 "sha256": _sha256(generation)},
                {"role": "embedding_model", "name": "embedding.gguf",
                 "source": "payload/embedding.gguf",
                 "bytes": embedding.stat().st_size,
                 "sha256": _sha256(embedding)},
            ],
            "archive_manifest": str(manifest_path.relative_to(self.root)),
            "archive_trust_store": str(trust.relative_to(self.root)),
        }
        release_path = self.root / "release.json"
        release_path.write_text(json.dumps(release, sort_keys=True),
                                encoding="utf-8")
        data, staged = prepare_release_assets.validate(release_path)
        self.assertEqual({name for _, name in staged},
                         {"archive_light.db", "generation.gguf",
                          "embedding.gguf"})

        # main --check-only is a walk that writes nothing
        out_dir = self.root / "staged"
        argv = sys.argv
        try:
            sys.argv = ["prepare_release_assets", "--manifest",
                       str(release_path), "--out", str(out_dir),
                       "--check-only"]
            self.assertEqual(prepare_release_assets.main(), 0)
        finally:
            sys.argv = argv
        self.assertFalse(out_dir.exists(),
                         "check-only staging wrote to the world")

        # and the absence leg: one forged byte must stop the staging
        embedding.write_bytes(b"GGUF-FIXTURE-EMBEDDING-BLOB\n" * 5 + b"x")
        with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
            prepare_release_assets.validate(release_path)
        self.assertFalse(out_dir.exists(),
                         "a forged blob was staged nonetheless")


class PromotionWitness(T45Case):
    def testConcurrentPromotionsPublishOneWholeArtifact(self) -> None:
        """W11: through the one promotion gate, whatever wins the race, the
        world sees only whole artifacts -- never a torn page, never a
        residue."""
        first = self.build(embed=False)
        reference = self.out.read_bytes()
        self.assertEqual(first.archive_sha256,
                         hashlib.sha256(reference).hexdigest())
        Path(str(self.out) + ba.SIDECAR_SUFFIX).unlink()
        self.out.unlink()

        gate = threading.Barrier(3)
        outcomes: list = [None, None]
        errors: list = []

        def worker(index: int) -> None:
            try:
                gate.wait(timeout=120)
                outcomes[index] = self.build(
                    embed=False,
                    seed_root=_seed(self.root / f"worker-{index}",
                                   tiers=self.BASE_TIERS))
            except BaseException as exc:
                errors.append(exc)

        threads = [
            threading.Thread(target=worker, args=(i,), name=f"t45-{i}",
                             daemon=True)
            for i in range(2)
        ]
        for thread in threads:
            thread.start()
        gate.wait(timeout=120)  # the referee: all three arrive, none proceeds
        for thread in threads:
            thread.join(timeout=180)
            self.assertFalse(thread.is_alive(), "a builder thread stuck fast")
        self.assertEqual(errors, [], repr(errors))
        self.assertIsNotNone(outcomes[0])
        self.assertIsNotNone(outcomes[1])
        self.assertEqual(outcomes[0].archive_sha256,
                         outcomes[1].archive_sha256,
                         "the two promotions disagreed on the bytes")
        self.assertEqual(self.out.read_bytes(), reference,
                         "the published artifact is not the whole file")
        self.no_residue()
        sidecar = Path(str(self.out) + ba.SIDECAR_SUFFIX)
        self.assertTrue(sidecar.is_file())
        self.assertEqual(ba.read_sidecar(sidecar)["archive_sha256"],
                         hashlib.sha256(reference).hexdigest())


if __name__ == "__main__":
    unittest.main(verbosity=2)
