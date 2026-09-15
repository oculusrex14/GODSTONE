#!/usr/bin/env python3
"""Build a Godstone Archive database for one tier.

    python -m content.ingest.build_archive --tier LIGHT --out dist/archive_light.db

The build is deterministic and atomic. The same corpus and the same tier
produce byte-identical chunk text, chunk ordering, chunk ids and, on one
machine with one SQLite, byte-identical files. The build writes ONLY into a
sibling temporary database; the schema, counts, foreign keys, FTS
answerability, canonical row ordering, metadata round-trip and size ceiling
are validated THERE; only then is the destination replaced, in one promoted,
serialized publication. A failed or interrupted build leaves the previous
bytes exactly as they were -- the destination is never opened for writing,
so there is nothing to restore.

That is what makes corpus_sha256 meaningful, and it is what lets a user
verify that the database on their phone is the one that was published
(constraint C2 - no accounts, so a hash is the only trust anchor we have).

Nothing here touches the network (C1). Sources are vendored under content/seed
and models are already on disk; if a path is missing the build fails loudly
rather than fetching anything. The embedding model is an OPTIONAL native
dependency: a --no-embed build runs on the lightweight tooling requirements
alone (content/requirements-dev.txt) and must never import llama-cpp.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import itertools
import json
import os
import re
import shutil
import sqlite3
import sys
import threading
import unicodedata
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any, Callable, Mapping

import yaml

from .chunker import Chunk, chunk_document
from .embedder import Embedder
from content.release_gate import validate_release_corpus
from content.release_gate import (
    ReleaseGateError, TrustPolicyError, TrustedReviewerKeySet,
    assert_independent_store, set_digest,
    verify_chunk_approvals, yaml_load_strict)

SCHEMA_VERSION = 3

ROOT = Path(__file__).resolve().parents[2]
SEED = ROOT / "content" / "seed"
DB_DIR = ROOT / "content" / "db"

# Section 18: "Archive import/build ... 1GiB parser/staging ceiling ...
# explicit error for larger artifact". The ceiling is checked on the staged
# file, before anything may be promoted.
MAX_STAGED_BYTES = 1 << 30

# The sidecar that records the final byte hash beside the logical digest.
SIDECAR_SUFFIX = ".sha256.json"
SIDECAR_SCHEMA = 1

# Mirrors the tier table in 00_README section 3 and docs/packaging/TIERS.md.
# These three dicts are the single source of truth for what ships in a build;
# if they disagree with the Gradle flavours (tab 03) or Tier.swift (tab 06) the
# app will look for a model file that is not there.
TIERS = {
    "LIGHT": {
        "model_file": "qwen3-0.6b-q4km.gguf",
        "embed_model": "bge-small-en-v1.5-q8.gguf",
        "embed_dim": 384,
        "context_tokens": 2048,
        "chunk_tokens": 320,
        "chunk_overlap": 48,
        "target_chunks": 40_000,
        "db_name": "archive_light.db",
    },
    "MEDIUM": {
        "model_file": "qwen3-1.7b-q4km.gguf",
        "embed_model": "bge-small-en-v1.5-q8.gguf",
        "embed_dim": 384,
        "context_tokens": 4096,
        "chunk_tokens": 384,
        "chunk_overlap": 64,
        "target_chunks": 150_000,
        "db_name": "archive_medium.db",
    },
    "LARGE": {
        "model_file": "qwen3-4b-q5km.gguf",
        "embed_model": "bge-base-en-v1.5-q8.gguf",
        "embed_dim": 768,
        "context_tokens": 8192,
        "chunk_tokens": 448,
        "chunk_overlap": 64,
        "target_chunks": 400_000,
        "db_name": "archive_large.db",
    },
}

# A LIGHT database contains only LIGHT documents; MEDIUM contains LIGHT and
# MEDIUM, and so on. Tier is cumulative, never exclusive.
TIER_RANK = {"LIGHT": 0, "MEDIUM": 1, "LARGE": 2}

REQUIRED_FRONT_MATTER = ("title", "domain", "source", "licence", "revision")

# Audit A-09. A release archive may not contain clinically unreviewed material.
# The check lives in the BUILD, not in a checklist, because a checklist is a
# claim and a build step is a control -- the distinction this whole repository
# is about. `--release` refuses; the default build warns and continues, so
# development against worked examples stays possible.
REVIEW_FIELDS = ("reviewed_by", "reviewed_on")
UNREVIEWED_SENTINEL = "UNREVIEWED-EXAMPLE"

# Tables the frozen schema contract (content/db/schema.sql) must yield.
REQUIRED_TABLES = frozenset((
    "documents", "chunks", "chunks_fts", "vectors", "media", "archive_meta",
))
REQUIRED_VIEWS = frozenset(("chunk_citations",))

_WORD_RE = re.compile(r"[A-Za-z]{3,}")


class ArchiveBuildError(RuntimeError):
    """Any failure of the archive build. The destination never moved."""


class ArchiveEmptyError(ArchiveBuildError):
    """The corpus selects no documents for this tier. An empty production
    archive is a refusal, not a success that built nothing."""


class ArchiveDependencyError(ArchiveBuildError):
    """An optional native dependency (the embedding engine or its model file)
    is absent. Distinct from every validation failure so a caller can tell a
    missing toolchain from a broken artifact."""


class ArchiveUnsafeDestinationError(ArchiveBuildError):
    """The destination would overwrite a frozen contract, live inside the
    corpus or the schema directory, or is otherwise not a plain file path."""


class ArchiveUnsafeContentError(ArchiveBuildError):
    """A media row that would travel outside the seed, or a path that is
    not in its canonical clean form, is refused before any row is made."""


class ArchiveApprovalError(ArchiveBuildError):
    """The shipped chunks are not covered by fresh, properly signed
    approvals from independently configured reviewer keys."""


class ArchiveTooLargeError(ArchiveBuildError):
    """The staged artifact overruns the section 18 staging ceiling."""


class ArchiveValidationError(ArchiveBuildError):
    """The staged database failed one or more of the pre-publication checks.
    The report names each; the previous bytes at the destination stand."""

    def __init__(self, report: "ArchiveValidationReport") -> None:
        self.report = report
        super().__init__(
            "archive validation failed: " + ", ".join(report.failures)
            + " (checks run: " + ", ".join(report.checks) + ")")


@dataclass(frozen=True)
class ArchiveValidationReport:
    """Everything the validator observed on the staged database, before the
    world was allowed to see it."""
    ok: bool
    schema_version: str
    tier: str
    counts: Mapping[str, int]
    integrity_check: str
    fts_probe_query: str
    fts_probe_hits: int
    foreign_key_violations: int
    ordering_verified: bool
    metadata_roundtrip_verified: bool
    checks: tuple[str, ...]
    failures: tuple[str, ...]


@dataclass(frozen=True)
class ArchiveBuildResult:
    """The receipt of one successful atomic build."""
    tier: str
    destination: Path
    archive_bytes: int
    archive_sha256: str
    corpus_sha256: str
    document_count: int
    chunk_count: int
    vector_count: int
    validation: ArchiveValidationReport
    release_manifest_set_sha256: str | None
    sidecar: Path


class AtomicArchiveOutput:
    """A destination plus the sibling temporary file it is built in.

    The destination is opened NEVER. Only publish() touches it, once, under
    the promotion lock; discard() releases exactly the temporary this object
    created and nothing else (cancel/release only resources owned by the
    exact operation). Both are idempotent.
    """

    def __init__(self, destination: Path, token: str) -> None:
        self.destination = Path(destination)
        self.temp = self.destination.with_name(
            f".{self.destination.name}.tmp-{token}")
        self._published = False
        self._discarded = False

    @property
    def committed(self) -> bool:
        return self._published

    def ensure_parent(self) -> None:
        self.destination.parent.mkdir(parents=True, exist_ok=True)

    def publish(self) -> None:
        if self._published:
            return
        if self._discarded or not self.temp.exists():
            raise ArchiveBuildError(
                f"nothing is staged to publish for {self.destination}")
        with _PROMOTION_LOCK:
            os.replace(self.temp, self.destination)
        self._published = True

    def discard(self) -> None:
        if self._published or self._discarded:
            return
        self._discarded = True
        if self.temp.exists():
            self.temp.unlink()


# Artifact promotion and state-file writes are serialized (section 16: pure
# build tasks serialize artifact promotion). One process-wide lock suffices:
# the build is a batch job and the critical sections are single syscalls.
_PROMOTION_LOCK = threading.Lock()
_TOKEN_LOCK = threading.Lock()
_TOKEN_COUNTER = itertools.count(1)


def _next_token() -> str:
    with _TOKEN_LOCK:
        return f"{os.getpid()}-{next(_TOKEN_COUNTER)}"


@dataclass
class Document:
    path: Path
    title: str
    domain: str
    source_id: str
    licence: str
    revision: str
    tier_min: str
    reading_level: int
    is_critical: bool
    reviewed_by: str
    reviewed_on: str
    body: str


def parse_front_matter(path: Path) -> Document:
    """Read a seed markdown file with YAML front matter.

    Fails hard on a missing key. An unattributed document is a licence
    violation and an uncitable answer, and both are unacceptable (C3).
    """
    raw = path.read_text(encoding="utf-8")
    if not raw.startswith("---"):
        raise ValueError(f"{path}: missing YAML front matter")

    _, fm_text, body = raw.split("---", 2)
    fm = yaml_load_strict(fm_text, str(path)) or {}

    missing = [k for k in REQUIRED_FRONT_MATTER if k not in fm]
    if missing:
        raise ValueError(f"{path}: front matter missing {missing}")

    reading_level = int(fm.get("reading_level", 8))
    if reading_level > 9:
        print(f"warning: {path} reads at grade {reading_level}; "
              f"aim for 9 or below (C7)", file=sys.stderr)

    tier_min = str(fm.get("tier_min", "LIGHT")).strip().upper()
    if tier_min not in TIER_RANK:
        raise ValueError(f"{path}: unknown tier_min {tier_min!r}")

    return Document(
        path=path,
        title=str(fm["title"]).strip(),
        domain=str(fm["domain"]).strip(),
        source_id=str(fm["source"]).strip(),
        licence=str(fm["licence"]).strip(),
        revision=str(fm["revision"]).strip(),
        tier_min=tier_min,
        reading_level=reading_level,
        is_critical=bool(fm.get("critical", False)),
        reviewed_by=str(fm.get("reviewed_by", UNREVIEWED_SENTINEL)).strip(),
        reviewed_on=str(fm.get("reviewed_on", "")).strip(),
        body=body.strip(),
    )


def load_corpus(tier: str, *, seed_root: Path | None = None) -> list[Document]:
    """Collect every seed document that belongs in this tier.

    Sorted by path so document_id and chunk_id are stable across machines and
    across runs. Filesystem iteration order is not, and a nondeterministic id
    would make corpus_sha256 worthless.
    """
    if tier not in TIER_RANK:
        raise ArchiveBuildError(f"unknown tier {tier!r}")
    seed = Path(seed_root) if seed_root is not None else SEED

    taxonomy_path = seed / "taxonomy.yaml"
    if not taxonomy_path.is_file():
        raise ArchiveEmptyError(f"no taxonomy at {taxonomy_path}")
    taxonomy = yaml_load_strict(
        taxonomy_path.read_text(encoding="utf-8"), str(taxonomy_path)) or {}
    known_domains = {d["id"] for d in taxonomy.get("domains", [])}

    limit = TIER_RANK[tier]
    docs: list[Document] = []

    for path in sorted((seed / "docs").rglob("*.md"), key=lambda p: str(p)):
        doc = parse_front_matter(path)
        if doc.domain not in known_domains:
            raise ValueError(f"{path}: unknown domain {doc.domain!r}")
        if TIER_RANK[doc.tier_min] <= limit:
            docs.append(doc)

    if not docs:
        raise ArchiveEmptyError(f"no documents qualify for tier {tier}")
    return docs


def _digest_field(h: "hashlib._Hash", value: str) -> None:
    """Length-prefix every field. Without the length the pairs ('ab','c') and
    ('a','bc') would chain to one and the same hash, and a digest that
    collides on construction is not a trust anchor."""
    encoded = value.encode("utf-8")
    h.update(str(len(encoded)).encode("ascii"))
    h.update(b"\x1f")
    h.update(encoded)
    h.update(b"\x1e")


def corpus_digest(docs: list[Document], chunks: list[Chunk]) -> str:
    """Hash of everything that ends up in the database.

    Covers document metadata and chunk rows but deliberately not the embedding
    bytes: a different embedding model produces the same knowledge and should
    not look like a different corpus. The document fields covered are exactly
    the columns persisted into `documents`; the chunk fields are exactly the
    columns persisted into `chunks`. Field boundaries are domain-separated by
    the length prefixes of _digest_field.
    """
    h = hashlib.sha256()
    h.update(b"GS-ARCHIVE-LOGICAL-V2\x1c")
    _digest_field(h, str(len(docs)))
    _digest_field(h, str(len(chunks)))
    for doc in docs:
        for value in (doc.title, doc.domain, doc.source_id, doc.licence,
                      doc.revision, doc.tier_min, str(doc.reading_level),
                      str(int(doc.is_critical))):
            _digest_field(h, value)
    for ch in chunks:
        # The ordinal the row carries is the insert position the caller chose;
        # the validator compares that against the stored rows. The digest
        # speaks of what the chunk object itself holds, keyed by its global
        # chunk_id -- which encodes the very sequence.
        for value in (str(ch.chunk_id), str(ch.document_id),
                      ch.section, ch.text, str(ch.token_count)):
            _digest_field(h, value)
    return h.hexdigest()


def _guard_destination(destination: Path, db_dir: Path, seed: Path) -> None:
    """Refuse, before touching anything, every destination that could do harm.

    The frozen schema sources and the corpus are the crown jewels of the
    build; a destination that resolves inside them -- or masquerades as one of
    them -- is refused with a name, and so is anything that is not a plain
    file path."""
    if not isinstance(destination, Path):
        raise TypeError("out_path must be a pathlib.Path")
    text = str(destination)
    if not text or "\0" in text:
        raise ArchiveUnsafeDestinationError("destination path is empty or NUL-torn")
    name = destination.name
    if not name or name in {".", ".."}:
        raise ArchiveUnsafeDestinationError(
            f"destination has no file name: {destination}")
    if name.endswith(SIDECAR_SUFFIX):
        raise ArchiveUnsafeDestinationError(
            f"a sidecar name is reserved for the hash record: {destination}")
    try:
        exists = destination.exists()
    except OSError as exc:
        raise ArchiveUnsafeDestinationError(f"destination is unreachable: {exc}")
    if exists and not destination.is_file():
        raise ArchiveUnsafeDestinationError(
            f"destination exists and is not a regular file: {destination}")
    resolved = destination.resolve()
    for guarded, label in ((Path(db_dir).resolve(), "schema directory"),
                           (Path(seed).resolve(), "corpus directory")):
        try:
            resolved.relative_to(guarded)
        except ValueError:
            continue
        raise ArchiveUnsafeDestinationError(
            f"destination resolves inside the {label} ({guarded}); the build "
            f"may not write there")
    if name in {"schema.sql", "indexes.sql"}:
        raise ArchiveUnsafeDestinationError(
            f"{name!r} is a frozen schema source name; a database file may "
            f"not be published under it")


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def _canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


@contextlib.contextmanager
def _canonical_output_lock(reference: Path):
    """GS-CONTENT-002: publication is serialized by CANONICAL OUTPUT IDENTITY, across
    PROCESSES. The process-wide threading.Lock below cannot protect a database-plus-receipt
    composition from a second CLI invocation, which is exactly how the audit interleaved two
    builds and produced a receipt combining one build's corpus identity with another's
    bytes."""
    lock_path = reference.parent / f".{reference.name}.publish.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    handle = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield
    finally:
        try:
            fcntl.flock(handle, fcntl.LOCK_UN)
        finally:
            os.close(handle)


def _fsync_file(path: Path) -> None:
    """A FILE's bytes are durable only when the FILE is fsynced.

    AUDIT-004 step 5: the publication retained the previous pair and wrote the journal, but
    NEITHER was fsynced, so a crash after the destructive promotion could leave a pair whose
    ROLLBACK TARGET had never reached the disk -- a rollback to a file that was never there.
    """
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _fsync_directory(directory: Path) -> None:
    """A rename is durable only when the DIRECTORY is fsynced (card step 6).

    AUDIT-004 step 5: a REQUIRED durability failure PROPAGATETH. The earlier form swallowed BOTH
    the open failure and the fsync failure, so a publication whose rename never reached the disk
    was indistinguishable from one that did -- SUCCESS REPORTED OVER AN UNPROVEN BOUNDARY.
    """
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _journal_path(destination: Path) -> Path:
    return destination.parent / f".{destination.name}.publish-journal.json"


def _write_journal(destination: Path, state: str, previous: Mapping[str, str]) -> None:
    """Write ONE COMMIT STATE durably: the record's bytes reach the disk before it is renamed
    into place, and the directory entry is fsynced before the caller proceedeth -- a journal
    that liveth only in the page cache recovereth nothing."""
    payload = {"schema": 1, "kind": "archive-publication", "state": state,
               "destination": destination.name, "previous": dict(previous)}
    path = _journal_path(destination)
    tmp = path.with_name(f".{path.name}.tmp-{_next_token()}")
    tmp.write_bytes(_canonical_json(payload) + b"\n")
    _fsync_file(tmp)
    os.replace(tmp, path)
    _fsync_directory(path.parent)


def _pair_is_consistent(destination: Path, sidecar: Path) -> bool:
    """True when the receipt beside the archive describeth THOSE bytes exactly."""
    if not (destination.is_file() and sidecar.is_file()):
        return False
    try:
        record = json.loads(sidecar.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    if not isinstance(record, dict):
        return False
    return (record.get("archive_bytes") == destination.stat().st_size
            and record.get("archive_sha256") == _sha256_file(destination))


def recover_publication(destination: Path) -> str:
    """Resolve an INTERRUPTED publication, so no reader ever meets a mixed pair.

    GS-CONTENT-002 / AUDIT-004 step 2: `publish_archive_pair` recordeth EXPLICIT commit states
    and retaineth the previous pair -- but NOTHING CONSUMED THAT JOURNAL, so a process that died
    between the database's promotion and its receipt's write (a real `os._exit`, which no handler
    of ours can catch) left the NEW database beside the OLD receipt FOREVER. This is the consumer
    the audit requireth, and it runneth BEFORE ANY READER OR NEW WRITER PROCEEDETH.

    The direction is ROLLBACK to the retained COMPLETE previous generation: a journal that did not
    reach its terminal state provecth that both files of the new generation were never published,
    so the previous pair is the last generation that is whole. Every step is safe to REPEAT after
    a crash between an effect and its checkpoint, because it is derived from the files on disk
    rather than from a progress counter.

    Returns 'clean' (no journal, or a whole pair already standing), 'rolled_back' (the previous
    generation restored), or 'unavailable' (a journal that cannot be resolved -- reported, never
    silently ignored).
    """
    destination = Path(destination)
    sidecar = Path(str(destination) + SIDECAR_SUFFIX)
    journal = _journal_path(destination)
    if not journal.is_file():
        return "clean"
    try:
        record = json.loads(journal.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ArchiveBuildError(
            f"publication journal {journal} is unreadable ({exc}); the pair cannot be "
            f"resolved and must not be guessed at") from exc
    if not isinstance(record, dict):
        raise ArchiveBuildError(f"publication journal {journal} is not an object")
    state = record.get("state")
    previous = record.get("previous") or {}
    # THE STATE DECIDETH, AND THE DIRECTION IS NOT SYMMETRIC. Only an INTERRUPTED publication --
    # one that never reached its terminal state -- proveth that the new generation was never
    # published, and only then may the retained previous generation be restored. A journal in
    # `published` (or already `recovered`) means BOTH files were written: if the pair then looks
    # inconsistent, that is TAMPERING or external damage, and the recovery path must not "repair"
    # it by DELETING anything -- the reader's own pair check refuseth it by name instead.
    if state in ("published", "recovered", "rolled_back"):
        return "clean"
    with _canonical_output_lock(destination):
        if _pair_is_consistent(destination, sidecar):
            # the new generation IS whole (the crash happened after both writes but before the
            # terminal record): keep it rather than destroying a complete generation
            _write_journal(destination, "recovered", previous)
            _fsync_directory(destination.parent)
            return "clean"
        if not previous:
            return "unavailable"
        for path in (destination, sidecar):
            kept = previous.get(path.name)
            if not (kept and os.path.isfile(kept)):
                # the retained previous generation is INCOMPLETE: nothing is deleted and nothing
                # is guessed -- the pair is reported as unresolvable
                return "unavailable"
        for path in (destination, sidecar):
            shutil.copy2(previous[path.name], path)
        _fsync_directory(destination.parent)
        if _pair_is_consistent(destination, sidecar):
            _write_journal(destination, "recovered", previous)
            _fsync_directory(destination.parent)
            return "rolled_back"
    return "unavailable"


def publish_archive_pair(candidate, receipt: Mapping[str, Any]) -> Path:
    """Publish the DATABASE and its RECEIPT as ONE generation (GS-CONTENT-002).

    The card's step 3: prepare and validate the complete generation -- database plus sidecar
    -- and publish it under one lock, so no reader ever meets a mismatched pair. Because the
    public fixed paths cannot migrate to a generation pointer in one step, the card's step 4
    is followed instead: a JOURNALED protocol with BACKUPS and explicit recovery states, in
    which a failure RESTORES the previous pair rather than leaving half of it.
    """
    destination = candidate.destination
    sidecar = Path(str(destination) + SIDECAR_SUFFIX)
    # AUDIT-004 step 2: a NEW WRITER must not proceed over an interrupted one either. The
    # journal is consumed FIRST, so the writer's own "previous pair" is a WHOLE generation.
    recover_publication(destination)
    with _canonical_output_lock(destination):
        backups = destination.parent / f".{destination.name}.previous"
        previous: dict[str, str] = {}
        for path in (destination, sidecar):
            if path.exists():
                backups.mkdir(parents=True, exist_ok=True)
                kept = backups / path.name
                shutil.copy2(path, kept)
                # AUDIT-004 step 5: THE ROLLBACK TARGET MUST BE DURABLE BEFORE THE DESTRUCTIVE
                # PROMOTION. A copy that liveth only in the page cache is not a rollback target.
                _fsync_file(kept)
                previous[path.name] = str(kept)
        _write_journal(destination, "prepared", previous)
        try:
            candidate.publish()
            write_sidecar(destination, receipt)
            _fsync_directory(destination.parent)
        except BaseException:
            # RESTORE the previous PAIR: a failure never leaves a new database beside an old
            # receipt (the audit's reproduced mismatch).
            for path in (destination, sidecar):
                kept = previous.get(path.name)
                if kept and os.path.isfile(kept):
                    shutil.copy2(kept, path)
                elif path.exists() and not kept:
                    path.unlink()
            _fsync_directory(destination.parent)
            _write_journal(destination, "rolled_back", previous)
            raise
        # AUDIT-004 step 5: "Handle a failed journal-finalization write without leaving
        # success/failure ambiguity." The generation IS published at this point, so a bare
        # failure here would be a LIE in the other direction. The error NAMETH the true state,
        # and the recovery consumer will accept the consistent pair from the `prepared` record.
        try:
            _write_journal(destination, "published", previous)
        except OSError as exc:
            raise ArchiveBuildError(
                f"the generation is published beside {destination}, but its TERMINAL journal "
                f"record could not be written durably ({exc}); the journal still carrieth the "
                f"`prepared` state, which recovery resolveth to the CONSISTENT pair now on "
                f"disk -- do not retry the build blindly") from exc
        shutil.rmtree(backups, ignore_errors=True)
        _fsync_directory(destination.parent)
    return sidecar


def write_sidecar(destination: Path, record: Mapping[str, Any]) -> Path:
    """Record the logical-content digest and the final byte hash beside the
    archive, versioned and atomic. Unknown future schema is refused."""
    sidecar = Path(str(destination) + SIDECAR_SUFFIX)
    payload = dict(record)
    payload["schema"] = SIDECAR_SCHEMA
    staging = sidecar.with_name(
        f".{sidecar.name}.tmp-{_next_token()}")
    staging.write_bytes(_canonical_json(payload) + b"\n")
    with _PROMOTION_LOCK:
        os.replace(staging, sidecar)
    return sidecar


def read_sidecar(sidecar: Path, archive: Path | None = None) -> dict[str, Any]:
    """Read a sidecar; a tool of yesterday may understand it, an unknown
    future schema may not be silently obeyed.

    GS-CONTENT-002: when the ARCHIVE is at hand, the pair is checked: a receipt whose byte
    hash or byte count doth not describe the bytes beside it is REFUSED by name, so no
    reader ever acts upon a mismatched pair.

    AUDIT-004 steps 2-3: `archive=None` IS NO LONGER A WAY TO READ A STALE RECEIPT
    UNCHALLENGED. The archive is DERIVED from the receipt's own name when the caller furnisheth
    none -- the two files live at fixed, canonical paths -- and an INTERRUPTED PUBLICATION is
    RESOLVED before the receipt is handed back, so a reader meeteth a complete generation or an
    explicit refusal, never a mixture.
    """
    sidecar = Path(sidecar)
    if archive is None and str(sidecar).endswith(SIDECAR_SUFFIX):
        derived = Path(str(sidecar)[:-len(SIDECAR_SUFFIX)])
        if derived.is_file():
            archive = derived
    if archive is not None:
        # the recovery consumer, BEFORE this reader proceedeth (it may itself be a no-op)
        recover_publication(archive)
    record = json.loads(sidecar.read_text(encoding="utf-8"))
    if not isinstance(record, dict):
        raise ArchiveBuildError(f"sidecar {sidecar} is not an object")
    # THE VERSION IS JUDGED FIRST, and the order is the law rather than a convenience: a receipt
    # in a format this tool doth not understand may not be OBEYED, and its fields may not be
    # interpreted as though the format were known -- comparing the bytes of an unknown schema
    # would answer the wrong question with the wrong message. (A pre-existing court,
    # SidecarTests.test_an_unknown_future_version_is_refused, pinreth exactly this.)
    version = record.get("schema")
    if version != SIDECAR_SCHEMA:
        raise ArchiveBuildError(
            f"sidecar {sidecar} schema {version!r} is not the supported "
            f"{SIDECAR_SCHEMA}; refusing an unknown version rather than "
            f"guessing")
    if archive is not None:
        if not archive.is_file():
            raise ArchiveBuildError(f"receipt {sidecar} has no archive beside it")
        actual_bytes = archive.stat().st_size
        actual_sha = _sha256_file(archive)
        if record.get("archive_bytes") != actual_bytes:
            raise ArchiveBuildError(
                f"receipt {sidecar} claimeth {record.get('archive_bytes')!r} bytes while "
                f"{archive.name} carrieth {actual_bytes}: the pair is MISMATCHED")
        if record.get("archive_sha256") != actual_sha:
            raise ArchiveBuildError(
                f"receipt {sidecar} carrieth {record.get('archive_sha256')!r} while "
                f"{archive.name} hasheth to {actual_sha}: the pair is MISMATCHED")
    return record


def _default_embedder_factory(cfg: Mapping[str, Any]) -> Any:
    return Embedder(model_file=cfg["embed_model"], dim=cfg["embed_dim"])


def _validate(staged: Path, tier: str, docs: list[Document],
              chunks: list[Chunk], meta: Mapping[str, str], *,
              expect_vectors: bool, embed_dim: int) -> ArchiveValidationReport:
    """Observe the staged database as a user would: read-only, immutable.

    Every check is named; a failure names itself in the report. None of this
    can harm the destination -- the staged file is the only thing opened and
    it is opened mode=ro immutable=1. When the contract tables themselves are
    absent the deep probes are skipped and reported, not crashed into.
    """
    failures: list[str] = []
    checks: list[str] = []
    integrity = "skipped"
    fk_rows: list[Any] = []
    counts: dict[str, int] = {}
    probe = ""
    hits = 0
    roundtrip = False
    uri = f"file:{staged.resolve()}?mode=ro&immutable=1"
    conn = sqlite3.connect(uri, uri=True)
    try:
        names = {row[0] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type IN ('table','view')")}
        missing_tables = sorted(REQUIRED_TABLES - names)
        if missing_tables:
            failures.append(
                "tables:missing:" + ", ".join(missing_tables))
        else:
            checks.append("tables")
        missing_views = sorted(REQUIRED_VIEWS - names)
        if missing_views:
            failures.append("views:missing:" + ", ".join(missing_views))
        else:
            checks.append("views")

        if not missing_tables and not missing_views:
            integrity = str(
                conn.execute("PRAGMA integrity_check").fetchone()[0])
            if integrity != "ok":
                failures.append(f"integrity:{integrity}")
            else:
                checks.append("integrity_check")

            fk_rows = conn.execute("PRAGMA foreign_key_check").fetchall()
            if fk_rows:
                failures.append(f"foreign_keys:{len(fk_rows)} violations")
            checks.append("foreign_key_check")

            stored_meta = {str(k): str(v) for k, v in conn.execute(
                "SELECT key, value FROM archive_meta")}
            if stored_meta != dict(meta):
                seen = set(stored_meta) | set(meta)
                differ = sorted(k for k in seen
                               if stored_meta.get(k) != meta.get(k))
                failures.append(
                    "metadata_roundtrip:" + (", ".join(differ[:12])
                                             or "mismatch"))
                roundtrip = False
            else:
                roundtrip = True
            if "schema_version" not in stored_meta:
                failures.append("schema_version:absent")
            elif stored_meta["schema_version"] != str(SCHEMA_VERSION):
                failures.append(
                    f"schema_version:{stored_meta['schema_version']!r}")
            else:
                checks.append("schema_version")

            document_rows = conn.execute(
                "SELECT document_id, title, domain, source_id, licence, "
                "revision, tier_min, reading_level, is_critical FROM documents "
                "ORDER BY document_id").fetchall()
            expected_document_rows = [
                (i, d.title, d.domain, d.source_id, d.licence, d.revision,
                 d.tier_min, d.reading_level, int(d.is_critical))
                for i, d in enumerate(docs, start=1)]
            if document_rows != expected_document_rows:
                failures.append("ordering:documents")
            else:
                checks.append("ordering_documents")

            chunk_rows = conn.execute(
                "SELECT chunk_id, document_id, ordinal, section, text, "
                "token_count FROM chunks ORDER BY chunk_id").fetchall()
            # The ordinal is positional truth: the number of earlier chunks
            # that share this document, in the very sequence that was staged.
            in_document = {}
            expected_chunk_rows = []
            for c in chunks:
                seen_so_far = in_document.get(c.document_id, 0)
                in_document[c.document_id] = seen_so_far + 1
                expected_chunk_rows.append(
                    (c.chunk_id, c.document_id, seen_so_far, c.section,
                     c.text, c.token_count))
            if (chunk_rows != expected_chunk_rows
                    or [r[0] for r in chunk_rows]
                    != list(range(1, len(chunks) + 1))):
                failures.append("ordering:chunks")
            else:
                checks.append("ordering_chunks")

            counts = {
                "documents": int(conn.execute(
                    "SELECT COUNT(*) FROM documents").fetchone()[0]),
                "chunks": int(conn.execute(
                    "SELECT COUNT(*) FROM chunks").fetchone()[0]),
                "vectors": int(conn.execute(
                    "SELECT COUNT(*) FROM vectors").fetchone()[0]),
            }
            if counts["documents"] != len(docs):
                failures.append(f"count_documents:{counts['documents']}")
            else:
                checks.append("count_documents")
            if counts["chunks"] != len(chunks):
                failures.append(f"count_chunks:{counts['chunks']}")
            else:
                checks.append("count_chunks")
            want_vectors = len(chunks) if expect_vectors else 0
            if counts["vectors"] != want_vectors:
                failures.append(f"count_vectors:{counts['vectors']}")
            else:
                checks.append("count_vectors")
            if expect_vectors:
                bad = conn.execute(
                    "SELECT COUNT(*) FROM vectors WHERE dim != ? OR "
                    "LENGTH(vec) != ?", (embed_dim, embed_dim)).fetchone()[0]
                if bad:
                    failures.append(f"vectors_shape:{bad}")
                else:
                    checks.append("vectors_shape")

            if not chunks or not docs:
                failures.append("empty_archive:no rows to speak")
            else:
                word = next(
                    (w for w in _WORD_RE.findall(chunks[0].text)
                     if unicodedata.normalize("NFKD", w).isalnum()), None)
                if word is None:
                    failures.append("fts_probe:no probe word in the first chunk")
                else:
                    probe = '"' + word.replace('"', '""') + '"'
                    hits = int(conn.execute(
                        "SELECT COUNT(*) FROM chunks_fts "
                        "WHERE chunks_fts MATCH ?", (probe,)).fetchone()[0])
                    if hits < 1:
                        failures.append(f"fts_probe:{probe!r} answered nothing")
                    else:
                        checks.append("fts_probe")
    finally:
        conn.close()

    if not failures:
        checks.append("all")
    return ArchiveValidationReport(
        ok=not failures,
        schema_version=str(meta.get("schema_version", "")),
        tier=tier,
        counts=counts,
        integrity_check=integrity,
        fts_probe_query=probe,
        fts_probe_hits=hits,
        foreign_key_violations=len(fk_rows),
        ordering_verified=not any(f.startswith("ordering") for f in failures),
        metadata_roundtrip_verified=roundtrip,
        checks=tuple(checks),
        failures=tuple(failures),
    )


def build(tier: str, out_path: Path, embed: bool = True,
          release: bool = False, *,
          seed_root: Path | None = None,
          db_dir: Path | None = None,
          manifests_root: Path | None = None,
          evidence_root: Path | None = None,
          today: date | None = None,
          max_staged_bytes: int = MAX_STAGED_BYTES,
          fault_hook: Callable[[str], None] | None = None,
          embedder_factory: Callable[[Mapping[str, Any]], Any] | None = None,
          approvals_dir: Path | None = None,
          reviewer_keyset: Path | None = None,
          ) -> ArchiveBuildResult:
    """Build one tier atomically and deterministically.

    Inputs are validated first; the build writes ONLY a sibling temporary;
    the staged database is validated; only a validated artifact is promoted
    over the destination, under the promotion lock. Any failure -- a bad
    corpus, an absent model, an injected fault, an over-large artifact --
    leaves the previous destination bytes untouched. The five hooks of the
    process are named for the fault-injection seams: after_temp_created,
    rows_inserted, vectors_done, indexed, before_validate, after_validate,
    before_publish, after_publish.
    """
    # ---- THE FINAL CHUNK APPROVALS ARE MANDATORY IN A RELEASE (GS-CONTENT-001) ----
    # The audit reproduced that `release=True` without approvals_dir/reviewer_keyset
    # PASSED and produced a database carrying no approvals_sha256, which then reached
    # operator staging. The configuration is therefore checked at ENTRY, before a single
    # byte of output existeth, and half a pair is refused exactly as before.
    if release:
        if approvals_dir is None or reviewer_keyset is None:
            missing = [name for name, value in
                       (("approvals_dir", approvals_dir),
                        ("reviewer_keyset", reviewer_keyset)) if value is None]
            raise SystemExit(
                f"::error::REFUSING to build a release archive: the final chunk "
                f"approvals are mandatory in a release, and {', '.join(missing)} "
                f"{'is' if len(missing) == 1 else 'are'} absent. Supply BOTH "
                f"--approvals-dir and --reviewer-keyset; a release archive may not be "
                f"built without its approved chunks (GS-CONTENT-001).")
    if not isinstance(max_staged_bytes, int) or isinstance(
            max_staged_bytes, bool) or max_staged_bytes <= 0:
        raise TypeError("max_staged_bytes must be a positive integer")

    def fire(stage: str) -> None:
        if fault_hook is not None:
            fault_hook(stage)

    if tier not in TIERS:
        raise ArchiveBuildError(f"unknown tier {tier!r}")
    cfg = TIERS[tier]
    seed = Path(seed_root) if seed_root is not None else SEED
    schema_dir = Path(db_dir) if db_dir is not None else DB_DIR
    destination = out_path
    _guard_destination(destination, schema_dir, seed)

    schema_sql = (schema_dir / "schema.sql").read_text(encoding="utf-8")
    indexes_sql = (schema_dir / "indexes.sql").read_text(encoding="utf-8")

    docs = load_corpus(tier, seed_root=seed)
    print(f"tier {tier}: {len(docs)} documents")

    # The final chunks are computed once, up front: the approvals leg must
    # read the very forms that will be inserted, and the insert loop shall
    # not derive them afresh by another road.
    chunked: list[tuple[Document, list[Chunk]]] = [
        (doc, list(chunk_document(
            doc.body, max_tokens=cfg["chunk_tokens"],
            overlap_tokens=cfg["chunk_overlap"])))
        for doc in docs
    ]

    mroot = (Path(manifests_root) if manifests_root is not None
             else ROOT / "content" / "manifests" / "documents")
    eroot = (Path(evidence_root) if evidence_root is not None
             else ROOT / "content" / "manifests")

    # ---- editorial gate (A-09) -------------------------------------------
    unreviewed = [d for d in docs if d.reviewed_by == UNREVIEWED_SENTINEL]
    if unreviewed:
        names = ", ".join(d.path.name for d in unreviewed)
        if release:
            raise SystemExit(
                f"::error::REFUSING to build a release archive: {len(unreviewed)} "
                f"document(s) have no clinical review ({names}). See "
                f"docs/editorial/REVIEW.md. A release archive may not carry "
                f"unreviewed medical instructions.")
        print(f"warning: {len(unreviewed)} document(s) are UNREVIEWED worked "
              f"examples ({names}). --release would refuse this build.",
              file=sys.stderr)

    release_validation = None
    if release:
        try:
            release_validation = validate_release_corpus(
                docs, mroot, evidence_root=eroot, today=today)
        except ReleaseGateError as exc:
            raise ArchiveApprovalError(
                f"release content gate refused the build: {exc}") from exc
        print(f"validated {len(release_validation.documents)} production "
              f"document manifest(s)")

    approvals_digest: str | None = None
    approvals_covered = 0
    if approvals_dir is not None or reviewer_keyset is not None:
        if approvals_dir is None or reviewer_keyset is None:
            raise TypeError(
                "approvals_dir and reviewer_keyset go together; half a "
                "policy is no policy")
        if not release or release_validation is None:
            raise ArchiveApprovalError(
                "chunk approvals are a release-path instrument; naming them "
                "for a non-release build is a configuration fault")
        if today is None:
            raise ArchiveApprovalError(
                "approvals are observed against an injected clock; the "
                "build was given none")
        home = Path(approvals_dir)
        bundle_digests: list[str] = []
        try:
            store = assert_independent_store(
                Path(reviewer_keyset),
                forbidden_roots=(seed, mroot, eroot, home,
                                destination.parent),
                what="reviewer trust store")
            keyset = TrustedReviewerKeySet.load(store)
            for (doc, chunks), validated in zip(
                    chunked, release_validation.documents):
                if validated.document_id != doc.source_id:
                    raise ArchiveApprovalError(
                        f"validated document {validated.document_id!r} doth "
                        f"not answer to source {doc.source_id!r}")
                coverage = verify_chunk_approvals(
                    source_id=doc.source_id,
                    document_sha256=validated.source_sha256,
                    rights_sha256=validated.rights_evidence_sha256,
                    manifest_path=validated.manifest_path,
                    evidence_root=eroot,
                    chunks=chunks,
                    approvals_dir=home,
                    keyset=keyset,
                    today=today)
                if coverage.chunk_approved != coverage.chunk_total:
                    raise ArchiveApprovalError(
                        f"{doc.source_id}: coverage proved incomplete")
                bundle_digests.append(coverage.bundle_sha256)
                approvals_covered += coverage.chunk_approved
        except TrustPolicyError as exc:
            raise ArchiveApprovalError(
                f"trust policy refused the build: {exc}") from exc
        except ReleaseGateError as exc:
            raise ArchiveApprovalError(
                f"approvals refused the build: {exc}") from exc
        approvals_digest = set_digest(bundle_digests)
        print(f"approvals proved: {approvals_covered} chunk(s) covered by "
              f"{len(bundle_digests)} bundle(s); digest "
              f"{approvals_digest[:12]}")

    out = AtomicArchiveOutput(destination, _next_token())
    out.ensure_parent()
    all_chunks: list[Chunk] = []
    chunk_id = 0
    try:
      conn = sqlite3.connect(out.temp)
      try:
        conn.executescript(schema_sql)
        fire("after_temp_created")

        for document_id, (doc, chunks) in enumerate(chunked, start=1):
            conn.execute(
                "INSERT INTO documents (document_id, title, domain, source_id, "
                "licence, revision, tier_min, reading_level, is_critical) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (document_id, doc.title, doc.domain, doc.source_id,
                 doc.licence, doc.revision, doc.tier_min, doc.reading_level,
                 int(doc.is_critical)),
            )
            for ordinal, ch in enumerate(chunks):
                chunk_id += 1
                ch.chunk_id = chunk_id
                ch.document_id = document_id
                conn.execute(
                    "INSERT INTO chunks (chunk_id, document_id, ordinal, "
                    "section, text, token_count) VALUES (?, ?, ?, ?, ?, ?)",
                    (chunk_id, document_id, ordinal, ch.section, ch.text,
                     ch.token_count),
                )
                all_chunks.append(ch)
        fire("rows_inserted")
        print(f"tier {tier}: {len(all_chunks)} chunks "
              f"(target ~{cfg['target_chunks']:,})")

        if embed:
            factory = embedder_factory or _default_embedder_factory
            try:
                embedder = factory(cfg)
            except (SystemExit, ImportError, OSError) as exc:
                raise ArchiveDependencyError(
                    f"embedding dependency unavailable: {exc}") from exc
            try:
                for ch in all_chunks:
                    # The heading path is prepended before embedding. 'Apply
                    # above the wound' is nearly meaningless on its own; with
                    # its section title it retrieves correctly.
                    vec, scale = embedder.encode_int8(
                        f"{ch.section}\n{ch.text}")
                    conn.execute(
                        "INSERT INTO vectors (chunk_id, dim, scale, vec) "
                        "VALUES (?, ?, ?, ?)",
                        (ch.chunk_id, cfg["embed_dim"], scale, vec),
                    )
            finally:
                embedder.close()
        fire("vectors_done")

        media_path = seed / "media_manifest.yaml"
        if media_path.exists():
            insert_media(conn, media_path, tier,
                         {d.source_id: i + 1
                          for i, d in enumerate(docs)})

        digest = corpus_digest(docs, all_chunks)
        meta = {
            "schema_version": str(SCHEMA_VERSION),
            "tier": tier,
            "embed_dim": str(cfg["embed_dim"]),
            "embed_model": cfg["embed_model"],
            "model_file": cfg["model_file"],
            "context_tokens": str(cfg["context_tokens"]),
            "document_count": str(len(docs)),
            "chunk_count": str(len(all_chunks)),
            "corpus_sha256": digest,
        }
        if release_validation is not None:
            meta.update({
                "source_manifest_sha256":
                    release_validation.source_set_sha256,
                "review_manifest_sha256":
                    release_validation.review_set_sha256,
                "release_manifest_set_sha256":
                    release_validation.manifest_set_sha256,
            })
        if approvals_digest is not None:
            meta["approvals_sha256"] = approvals_digest
            meta["approvals_covered"] = str(approvals_covered)

        conn.executemany(
            "INSERT INTO archive_meta (key, value) VALUES (?, ?)",
            sorted(meta.items()))

        conn.executescript(indexes_sql)
        conn.commit()
      finally:
        conn.close()
      fire("indexed")

      fire("before_validate")
      report = _validate(out.temp, tier, docs, all_chunks, meta,
                         expect_vectors=embed, embed_dim=cfg["embed_dim"])
      fire("after_validate")
      if not report.ok:
          raise ArchiveValidationError(report)

      size = out.temp.stat().st_size
      if size > max_staged_bytes:
          raise ArchiveTooLargeError(
              f"staged artifact is {size} bytes, over the ceiling of "
              f"{max_staged_bytes}")

      # ---- prepare the WHOLE generation BEFORE any authoritative replacement ----------
      # GS-CONTENT-002: the digest, the byte count and every receipt field are computed from
      # the OPERATION'S OWN staged database, never by re-reading the shared destination --
      # a re-read after the replacement is exactly how one build's corpus identity ended up
      # in a receipt beside another build's bytes.
      staged_bytes = out.temp.read_bytes()
      archive_sha = hashlib.sha256(staged_bytes).hexdigest()
      receipt = {
          "schema": SIDECAR_SCHEMA,
          "tier": tier,
          "archive_file": destination.name,
          "archive_bytes": len(staged_bytes),
          "archive_sha256": archive_sha,
          "corpus_sha256": digest,
          "document_count": len(docs),
          "chunk_count": len(all_chunks),
          "vector_count": len(all_chunks) if embed else 0,
      }
      fire("before_publish")
      sidecar = publish_archive_pair(out, receipt)
      fire("after_publish")
      final_bytes = staged_bytes
    except BaseException:
      # Nothing below the promotion may leave a residue: the temp is ours to
      # discard (idempotent, and a no-op once published); the destination was
      # never opened and stands exactly as it was. The cause travels on.
      out.discard()
      raise

    print(f"wrote {destination} ({len(final_bytes) / (1024 * 1024):.1f} MB)")
    print(f"corpus_sha256 {digest}")
    print(f"archive_sha256 {archive_sha}")

    return ArchiveBuildResult(
        tier=tier,
        destination=destination,
        archive_bytes=len(final_bytes),
        archive_sha256=archive_sha,
        corpus_sha256=digest,
        document_count=len(docs),
        chunk_count=len(all_chunks),
        vector_count=len(all_chunks) if embed else 0,
        validation=report,
        release_manifest_set_sha256=(
            None if release_validation is None
            else release_validation.manifest_set_sha256),
        sidecar=sidecar,
    )


def _media_path_fault(rel: Any) -> str | None:
    """Why a media path is refused, or None when it is fit to ship.

    The path must already be clean: absolute ways, drive letters, NUL
    bytes, backslashes, tilde expansion, empty or doubled separators,
    and any '.' or '..' segment -- even ones that would normpath home --
    are refused. A traversed path is not made honest by normpath; the
    canonical form is required at the gate.
    """
    text = str(rel)
    if not text:
        return "the path is empty"
    if "\0" in text:
        return "the path bears a NUL byte"
    if "\\" in text:
        return "the path bears a backslash"
    if text.startswith("~"):
        return "the path begins a tilde"
    if text.startswith("/"):
        return "the path is absolute"
    if len(text) > 1 and text[1] == ":":
        return "the path bears a drive letter"
    parts = text.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return ("the path is not in canonical clean form ('.', '..', "
                "empty or doubled segments)")
    return None


def insert_media(conn: sqlite3.Connection, manifest: Path, tier: str,
                 doc_ids: dict[str, int]) -> None:
    """Register media that this tier is allowed to carry.

    LIGHT ships diagrams only, MEDIUM adds voice and 480p, LARGE adds 1080p.
    Media files themselves are copied by scripts in tab 11; this only indexes.
    """
    allowed = {
        "LIGHT": {"diagram"},
        "MEDIUM": {"diagram", "audio", "video_480"},
        "LARGE": {"diagram", "audio", "video_480", "video_1080"},
    }[tier]

    entries = yaml_load_strict(
        manifest.read_text(encoding="utf-8"), str(manifest)) or {}
    media_id = 0
    seen_paths: set[str] = set()
    for item in entries.get("media", []):
        if item["kind"] not in allowed:
            continue
        document_id = doc_ids.get(item["source"])
        if document_id is None:
            continue
        rel = str(item["path"])
        fault = _media_path_fault(rel)
        if fault is not None:
            raise ArchiveUnsafeContentError(
                f"{manifest}: media path refused: {rel!r} ({fault})")
        if rel in seen_paths:
            raise ArchiveUnsafeContentError(
                f"{manifest}: duplicate media path: {rel!r}")
        seen_paths.add(rel)
        media_id += 1
        conn.execute(
            "INSERT INTO media (media_id, document_id, kind, relpath, caption, "
            "bytes, sha256) VALUES (?, ?, ?, ?, ?, ?, ?)",
            (media_id, document_id, item["kind"], item["path"],
             item["caption"], int(item.get("bytes", 0)),
             item.get("sha256", "")),
        )


def main() -> None:
    ap = argparse.ArgumentParser(description="Build a Godstone Archive database")
    ap.add_argument("--tier", required=True, choices=sorted(TIERS))
    ap.add_argument("--out", type=Path, default=None)
    ap.add_argument("--no-embed", action="store_true",
                    help="skip embeddings; lexical search only. Fast smoke test.")
    ap.add_argument("--print-config", action="store_true")
    ap.add_argument("--release", action="store_true",
                    help="refuse to build if any document lacks clinical review")
    ap.add_argument("--approvals-dir", type=Path, default=None,
                    help="home of the {source_id}.approvals.json bundles; with "
                         "--release, every shipped chunk must be covered by a "
                         "fresh approval signed by an independently configured "
                         "reviewer key")
    ap.add_argument("--reviewer-keyset", type=Path, default=None,
                    help="operator-configured reviewer trust store; it may "
                         "not live inside the corpus, the manifests, the "
                         "approvals home or the destination tree")
    args = ap.parse_args()

    if args.print_config:
        print(json.dumps(TIERS[args.tier], indent=2))
        return

    out = args.out or (ROOT / "dist" / TIERS[args.tier]["db_name"])
    try:
        build(args.tier, out, embed=not args.no_embed, release=args.release,
              approvals_dir=args.approvals_dir,
              reviewer_keyset=args.reviewer_keyset)
    except ArchiveBuildError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        raise SystemExit(2) from exc


if __name__ == "__main__":
    main()
