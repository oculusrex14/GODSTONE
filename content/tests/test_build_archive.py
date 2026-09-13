from __future__ import annotations

"""Unit witnesses for the atomic, deterministic archive builder (T45).

The readiness court in tools/readiness/tests/test_t45.py walks the whole
call path; this suite tests the builder's own parts where they stand:
the canonical digest, the front-matter gate, the corpus sorter, the
destination guard, the atomic output handle, the sidecar version gate and
the media tier table. Fixtures are harmless app-navigation text with
obvious FIXTURE markers, per the blueprint s16 law on development data.
"""

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from content.ingest.build_archive import (
    AtomicArchiveOutput, ArchiveBuildError, ArchiveEmptyError,
    ArchiveTooLargeError, ArchiveUnsafeDestinationError, SIDECAR_SUFFIX,
    TIERS, corpus_digest, insert_media, load_corpus, parse_front_matter,
    read_sidecar, write_sidecar,
)
from content.ingest.chunker import chunk_document

REPO = Path(__file__).resolve().parents[2]
DB_DIR = REPO / "content" / "db"

BODY = """# FIXTURE power
Press and hold the power button beside the volume rocker for two seconds
until the banner appears; release. This passage is harmless app-navigation
text marked FIXTURE, never a medical instruction.

# FIXTURE scroll
Swipe down with one finger; the list scrolls. Swipe up to return. The
status bar shows the battery icon.

# FIXTURE connect
Open settings and choose the network entry; the toggle turns blue when
connected.
"""


def _fixture_seed(root: Path, *, tiers=None, body=BODY):
    seed = root / "seed"
    docs = seed / "docs"
    docs.mkdir(parents=True, exist_ok=True)
    (seed / "taxonomy.yaml").write_text(
        "domains:\n- id: navigation\n  label: Navigation\n", encoding="utf-8")
    tiers = tiers or [("a.md", "LIGHT"), ("b.md", "LIGHT"),
                      ("c.md", "MEDIUM"), ("d.md", "LARGE")]
    for name, tier in tiers:
        (docs / name).write_text(
            "---\n"
            "title: Fixture {name}\n"
            "domain: navigation\n"
            "source: FIXTURE-{stem}\n"
            "licence: CC0-1.0\n"
            "revision: '1'\n"
            "tier_min: {tier}\n"
            "---\n{body}\n".format(name=name, stem=name.split('.')[0],
                                   tier=tier, body=body),
            encoding="utf-8")
    return seed


def _stage_chunks(cfg, docs):
    staged = []
    serial = 0
    for position, doc in enumerate(docs, start=1):
        for ordinal, chunk in enumerate(chunk_document(
                doc.body, max_tokens=cfg["chunk_tokens"],
                overlap_tokens=cfg["chunk_overlap"])):
            serial += 1
            chunk.chunk_id = serial
            chunk.document_id = position
            staged.append(chunk)
    return staged


class TempDirCase(unittest.TestCase):
    """unittest hands us addCleanup; the sealed sibling suites here use a
    plain tearDown, and so do we."""

    def tearDown(self) -> None:
        temp = getattr(self, "temp", None)
        if temp is not None:
            temp.cleanup()


class CanonicalDigestTests(TempDirCase):
    """The digest must speak of every persisted field, tell field boundaries
    apart, and order the sequence -- or it is not a trust anchor."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.seed = _fixture_seed(self.root)
        self.docs = load_corpus("LIGHT", seed_root=self.seed)
        self.cfg = TIERS["LIGHT"]
        self.base = corpus_digest(self.docs, _stage_chunks(self.cfg, self.docs))

    def test_digest_separates_document_field_boundaries(self) -> None:
        """('ab','c') and ('a','bc') are different documents, not one corpus
        wearing two masks: the naive byte chain is identical, so only honest
        length prefixes keep the two digests apart."""
        left = _mkdoc(title="ab", domain="c")
        right = _mkdoc(title="a", domain="bc")
        self.assertEqual(left.title + left.domain, right.title + right.domain)
        self.assertNotEqual(
            corpus_digest([left], _stage_chunks(self.cfg, [left])),
            corpus_digest([right], _stage_chunks(self.cfg, [right])),
            "a digest that collides on field boundaries is not a trust anchor")

    def test_digest_separates_chunk_field_boundaries(self) -> None:
        """The same law on the chunk rows: (section, text) boundaries must be
        as loud as the document's."""
        doc = _mkdoc(title="one", domain="navigation")
        from content.ingest.chunker import Chunk
        left = Chunk(section="ab", text="c", token_count=7,
                     chunk_id=1, document_id=1)
        right = Chunk(section="a", text="bc", token_count=7,
                      chunk_id=1, document_id=1)
        self.assertEqual(left.section + left.text, right.section + right.text)
        self.assertNotEqual(
            corpus_digest([doc], [left]), corpus_digest([doc], [right]),
            "chunk boundaries must speak distinctly")

    def test_digest_tracks_every_persisted_field(self) -> None:
        """Each persisted column, altered alone, must alter the digest."""
        for field, mutate in (
                ("title", lambda v: str(v) + "X"),
                ("domain", lambda v: str(v) + "X"),
                ("source_id", lambda v: str(v) + "X"),
                ("licence", lambda v: str(v) + "X"),
                ("revision", lambda v: str(v) + "X"),
                ("tier_min", lambda v: "MEDIUM" if str(v) != "MEDIUM" else "LARGE"),
                ("reading_level", lambda v: int(v) + 1),
                ("is_critical", lambda v: (not v)),
        ):
            with self.subTest(field=field):
                moved = [self.docs[0]]
                current = getattr(self.docs[0], field)
                moved[0] = _retitle(moved[0], **{field: mutate(current)})
                self.assertNotEqual(
                    self.base,
                    corpus_digest(moved + self.docs[1:],
                                  _stage_chunks(self.cfg, moved + self.docs[1:])),
                    f"{field} is persisted yet the digest does not observe it")

    def test_digest_tracks_every_persisted_chunk_field(self) -> None:
        chunks = _stage_chunks(self.cfg, self.docs)
        for field, mutate in (
                ("section", lambda v: str(v) + "X"),
                ("text", lambda v: str(v) + " tail"),
                ("token_count", lambda v: int(v) + 1),
        ):
            with self.subTest(field=field):
                moved = list(chunks)
                current = getattr(chunks[0], field)
                moved[0] = _rechunk(moved[0], **{field: mutate(current)})
                self.assertNotEqual(
                    self.base, corpus_digest(self.docs, moved),
                    f"chunk {field} is persisted yet the digest does not "
                    f"observe it")

    def test_digest_is_order_sensitive(self) -> None:
        chunks = _stage_chunks(self.cfg, self.docs)
        self.assertGreater(len(chunks), 1)
        swapped = list(chunks)
        swapped[0], swapped[1] = swapped[1], swapped[0]
        self.assertNotEqual(self.base, corpus_digest(self.docs, swapped))

    def test_digest_is_a_fixed_point_over_the_same_corpus(self) -> None:
        """Twice built over the same corpus, one and the same digest."""
        again = corpus_digest(
            load_corpus("LIGHT", seed_root=self.seed),
            _stage_chunks(self.cfg, load_corpus("LIGHT", seed_root=self.seed)))
        self.assertEqual(self.base, again)

    def test_digest_ignores_the_vector_bytes(self) -> None:
        """A different embedding model produces the same knowledge: the
        digest covers documents and chunk rows, never vectors."""
        chunks = _stage_chunks(self.cfg, self.docs)
        with_vectors = corpus_digest(self.docs, chunks)
        # the same rows seen through a forged vector store still digest the
        # same -- corpus_digest takes no vectors in, by its signature
        import inspect
        from content.ingest import build_archive as module
        names = inspect.signature(module.corpus_digest).parameters
        self.assertEqual(sorted(names), ["chunks", "docs"])
        self.assertEqual(with_vectors, self.base)


class FrontMatterGateTests(TempDirCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.seed = _fixture_seed(self.root)

    def test_missing_key_is_refused(self) -> None:
        bad = self.seed / "docs" / "bad.md"
        bad.write_text("---\ntitle: x\ndomain: navigation\nsource: s\n"
                       "revision: '1'\n---\nbody\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "licence"):
            parse_front_matter(bad)

    def test_unknown_tier_is_refused(self) -> None:
        bad = self.seed / "docs" / "weird.md"
        bad.write_text("---\ntitle: x\ndomain: navigation\nsource: s\n"
                       "licence: CC0\nrevision: '1'\ntier_min: HUGE\n---\n"
                       "body\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "tier_min"):
            parse_front_matter(bad)

    def test_absent_opening_fence_is_refused(self) -> None:
        bad = self.seed / "docs" / "plain.md"
        bad.write_text("# no front matter at all\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "missing YAML front matter"):
            parse_front_matter(bad)


class CorpusSorterTests(TempDirCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.seed = _fixture_seed(self.root)

    def test_corpus_is_sorted_and_culled_by_tier(self) -> None:
        light = load_corpus("LIGHT", seed_root=self.seed)
        self.assertEqual([d.path.name for d in light], ["a.md", "b.md"])
        medium = load_corpus("MEDIUM", seed_root=self.seed)
        self.assertEqual([d.path.name for d in medium],
                         ["a.md", "b.md", "c.md"])
        large = load_corpus("LARGE", seed_root=self.seed)
        self.assertEqual([d.path.name for d in large],
                         ["a.md", "b.md", "c.md", "d.md"])

    def test_empty_selection_raises_the_named_error(self) -> None:
        seed = _fixture_seed(self.root / "e", tiers=[("z.md", "LARGE")])
        with self.assertRaises(ArchiveEmptyError):
            load_corpus("LIGHT", seed_root=seed)

    def test_unknown_domain_is_refused(self) -> None:
        (self.seed / "docs" / "stray.md").write_text(
            "---\ntitle: stray\ndomain: astronomy\nsource: s\n"
            "licence: CC0\nrevision: '1'\n---\nbody\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "unknown domain"):
            load_corpus("LIGHT", seed_root=self.seed)


class DestinationGuardTests(TempDirCase):
    """The guard that stands before any write: unsafe destinations are
    refused with a name, and nothing on disk has moved by the time they do."""

    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def _guard(self, destination: Path) -> None:
        from content.ingest.build_archive import _guard_destination
        _guard_destination(Path(destination), DB_DIR, self.root / "seed")

    def test_plain_file_path_is_let_through(self) -> None:
        self._guard(self.root / "dist" / "archive_light.db")

    def test_schema_names_are_refused_globally(self) -> None:
        for name in ("schema.sql", "indexes.sql"):
            with self.subTest(name=name):
                with self.assertRaises(ArchiveUnsafeDestinationError):
                    self._guard(self.root / name)

    def test_writes_inside_the_frozen_dirs_are_refused(self) -> None:
        with self.assertRaises(ArchiveUnsafeDestinationError):
            self._guard(DB_DIR / "sneak.db")
        seed = self.root / "seed"
        (seed / "docs").mkdir(parents=True)
        with self.assertRaises(ArchiveUnsafeDestinationError):
            self._guard(seed / "corrupt.md.db")

    def test_sidecar_name_and_nul_and_directory_are_refused(self) -> None:
        with self.assertRaises(ArchiveUnsafeDestinationError):
            self._guard(self.root / ("x.db" + SIDECAR_SUFFIX))
        with self.assertRaises(ArchiveUnsafeDestinationError):
            self._guard(Path("nul\0path"))
        a_dir = self.root / "adir"
        a_dir.mkdir()
        with self.assertRaises(ArchiveUnsafeDestinationError):
            self._guard(a_dir)
        with self.assertRaises(ArchiveUnsafeDestinationError):
            self._guard(Path("."))
        with self.assertRaises(ArchiveUnsafeDestinationError):
            self._guard(Path(""))


class AtomicOutputTests(TempDirCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.dest = self.root / "out.db"

    def test_publish_moves_the_staged_bytes_once_and_idempotently(self) -> None:
        out = AtomicArchiveOutput(self.dest, "alpha-1")
        out.ensure_parent()
        out.temp.write_bytes(b"STAGED")
        out.publish()
        out.publish()
        self.assertEqual(self.dest.read_bytes(), b"STAGED")
        self.assertFalse(out.temp.exists())
        out.discard()  # idempotent after publish: nothing to release

    def test_discard_releases_only_its_own_resource(self) -> None:
        neighbour = self.root / "keep.db"
        neighbour.write_bytes(b"KEEP")
        out = AtomicArchiveOutput(self.dest, "alpha-2")
        out.ensure_parent()
        out.temp.write_bytes(b"DUST")
        out.discard()
        out.discard()
        self.assertFalse(out.temp.exists())
        self.assertFalse(self.dest.exists())
        self.assertEqual(neighbour.read_bytes(), b"KEEP")

    def test_publishing_nothing_is_a_named_failure(self) -> None:
        out = AtomicArchiveOutput(self.dest, "alpha-3")
        with self.assertRaises(ArchiveBuildError):
            out.publish()

    def test_over_an_absent_destination_the_replace_still_holds(self) -> None:
        pre = self.root / "old.db"
        pre.write_bytes(b"PREVIOUS")
        out = AtomicArchiveOutput(pre, "alpha-4")
        out.temp.write_bytes(b"NEW")
        out.publish()
        self.assertEqual(pre.read_bytes(), b"NEW")


class SidecarTests(TempDirCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def test_round_trip_records_the_two_hashes(self) -> None:
        archive = self.root / "a.db"
        archive.write_bytes(b"BYTES")
        digest = hashlib.sha256(b"BYTES").hexdigest()
        sidecar = write_sidecar(archive, {
            "tier": "LIGHT", "archive_file": "a.db", "archive_bytes": 5,
            "archive_sha256": digest, "corpus_sha256": "c" * 64,
            "document_count": 1, "chunk_count": 2, "vector_count": 0})
        record = read_sidecar(sidecar)
        self.assertEqual(record["archive_sha256"], digest)
        self.assertEqual(record["schema"], 1)
        # canonical bytes: sorted keys, tight separators, trailing newline
        raw = sidecar.read_bytes()
        self.assertTrue(raw.endswith(b"\n"))
        self.assertEqual(raw, json.dumps(record, sort_keys=True,
                                         separators=(",", ":"),
                                         ensure_ascii=False).encode() + b"\n")

    def test_an_unknown_future_version_is_refused(self) -> None:
        archive = self.root / "b.db"
        archive.write_bytes(b"x")
        sidecar = write_sidecar(archive, {"tier": "LIGHT"})
        payload = json.loads(sidecar.read_text(encoding="utf-8"))
        payload["schema"] = 2
        sidecar.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaisesRegex(ArchiveBuildError, "schema"):
            read_sidecar(sidecar)

    def test_a_non_object_sidecar_is_refused(self) -> None:
        archive = self.root / "c.db"
        archive.write_bytes(b"x")
        sidecar = Path(str(archive) + SIDECAR_SUFFIX)
        sidecar.write_text("[1,2]", encoding="utf-8")
        with self.assertRaises(ArchiveBuildError):
            read_sidecar(sidecar)


class MediaTierTests(TempDirCase):
    def setUp(self) -> None:
        import sqlite3
        self.sqlite3 = sqlite3
        self.conn = sqlite3.connect(":memory:")
        self.conn.executescript(
            "CREATE TABLE media (media_id INTEGER PRIMARY KEY, document_id "
            "INTEGER NOT NULL, kind TEXT NOT NULL, relpath TEXT NOT NULL, "
            "caption TEXT NOT NULL, bytes INTEGER NOT NULL, sha256 TEXT NOT NULL);")
        self.temp = tempfile.TemporaryDirectory()
        self.manifest = Path(self.temp.name) / "media_manifest.yaml"
        self.manifest.write_text(
            "media:\n"
            "- kind: diagram\n  source: s1\n  path: p1\n  caption: c1\n"
            "  bytes: 1\n  sha256: h1\n"
            "- kind: audio\n  source: s1\n  path: p2\n  caption: c2\n"
            "  bytes: 2\n  sha256: h2\n"
            "- kind: video_480\n  source: s1\n  path: p3\n  caption: c3\n"
            "  bytes: 3\n  sha256: h3\n"
            "- kind: video_1080\n  source: s1\n  path: p4\n  caption: c4\n"
            "  bytes: 4\n  sha256: h4\n", encoding="utf-8")

    def _kinds(self, tier: str) -> list[str]:
        insert_media(self.conn, self.manifest, tier, {"s1": 1})
        return [row[0] for row in self.conn.execute(
            "SELECT kind FROM media ORDER BY media_id")]

    def test_tier_table_gates_what_may_ship(self) -> None:
        self.assertEqual(self._kinds("LIGHT"), ["diagram"])
        self.conn.execute("DELETE FROM media")
        self.assertEqual(self._kinds("MEDIUM"),
                        ["diagram", "audio", "video_480"])
        self.conn.execute("DELETE FROM media")
        self.assertEqual(self._kinds("LARGE"),
                         ["diagram", "audio", "video_480", "video_1080"])

    def test_media_without_a_home_in_the_corpus_is_skipped(self) -> None:
        insert_media(self.conn, self.manifest, "LARGE", {})
        self.assertEqual(self.conn.execute(
            "SELECT COUNT(*) FROM media").fetchone()[0], 0)


def _mkdoc(**changes):
    from content.ingest.build_archive import Document
    fields = dict(path=Path("fixture.md"), title="t", domain="navigation",
                  source_id="s", licence="CC0-1.0", revision="1",
                  tier_min="LIGHT", reading_level=8, is_critical=False,
                  reviewed_by="UNREVIEWED-EXAMPLE", reviewed_on="",
                  body=BODY)
    fields.update(changes)
    return Document(**fields)


def _retitle(doc, **changes):
    from dataclasses import replace
    return replace(doc, **changes)


def _rechunk(chunk, **changes):
    from dataclasses import replace
    return replace(chunk, **changes)


def _bump(value, field: str):
    if field == "reading_level":
        return int(value) + 1
    if field == "is_critical":
        return not value
    if isinstance(value, bool):
        return not value
    return str(value) + "X"


if __name__ == "__main__":
    unittest.main(verbosity=2)
