#!/usr/bin/env python3
"""T77 -- the Archive upgrade, failed-update and rollback recovery authority.

The shipped Archive is an installed estate: bytes, the published
approved-resource manifest that nameth those bytes, and the signed archive
manifest that the operator's trust store accepteth. The release path may
replace that estate. What the release path could NOT answer before this file
existed:

  * which candidate schema may replace which installed schema, and what
    happeneth to an unsupported DOWNGRADE or to an UNKNOWN FUTURE schema;
  * whether the previous authoritative bytes survive a failed, refused or
    interrupted update -- i.e. whether there is a rollback target at all;
  * what an interrupted staging, an interrupted placement or a wipe in
    progress LEAVES BEHIND, and how it is resumed rather than guessed at.

The laws of this file, in the order they bind:

  1. AN ESTATE IS BOUND TO ITS SWORN RECORDS. Opening one requireth the
     archive, the published approved-resource manifest and the signed
     archive manifest, verified against the OPERATOR-selected trust store
     (never a pointer the document nameth for itself -- the T51/T52 law).
     An estate that cannot produce them is refused BY NAME.
  2. A PARTIAL ESTATE IS NEVER AN EMPTY ESTATE. One file of the trio present
     without the others is a wipe in progress or a broken estate; it is
     refused as such. Storage failure is never confused with missing data.
  3. A FUTURE SCHEMA IS REFUSED, NEVER RECREATED. An unknown schema is
     refused by name and the estate is preserved byte for byte. The
     authority never answers an unreadable estate by recreating it empty --
     that is the card's named semantic negative, and the witness that
     killeth the mutant liveth in tools/readiness/tests/test_t77.py.
  4. AN UNSUPPORTED DOWNGRADE REFUSETH BEFORE ANY WRITE. The compatibility
     matrix decideth; a refusal precedeth the retention snapshot and every
     placement.
  5. THE LAST-APPROVED BYTES REMAIN AVAILABLE ONLY UNDER THE EXPLICIT
     COMPATIBLE TRUST POLICY. The retention record (written by
     scripts/prepare_release_assets.py before either file of the pair is
     replaced) is the ONLY rollback target, and a rollback is refused when
     the retained archive's schema is not one this build may run.
  6. THE UPDATE IS TRANSACTIONAL. Every transition is journaled, fsynced,
     OUTSIDE the estate, before the action it describeth. An interruption in
     any transition leaveth the published manifest naming bytes that are
     present: either the previous estate whole, or the candidate estate
     whole -- a half-applied pair is never observable, and resume() reacheth
     a terminal state from the record alone.
  7. A WIPE IS JOURNALED AND TERMINAL. Its terminal states are exactly WIPED
     or the previous authoritative estate intact; a wipe in progress never
     masqueradeth as a healthy-estate-less install.
  8. NOTHING HERE FETCHETH. The recovery is offline by construction
     (invariant C1), and the operator instructions name every artifact it
     requireth.

This authority decideth NOTHING about publication: the publication order
(validate -> stage -> re-verify -> replace archive -> publish manifest)
remaineth scripts/prepare_release_assets.py's law, and its retention seam and
publication boundaries are what this file driveth. It decideth nothing about
the device either: an installed estate on a phone is established only by the
explicit platform/device gate, and every report carrieth that claim as
UNVERIFIED.
"""
from __future__ import annotations

import argparse
import errno
import hashlib
import json
import os
import shutil
import sqlite3
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from content.archive_manifest import (  # noqa: E402
    ArchiveManifestError, create_manifest, generate_test_keypair, load_private_key,
    load_trust_store, strict_json_loads, verify_manifest)
from content.ingest.build_archive import SCHEMA_VERSION as ARCHIVE_SCHEMA_VERSION  # noqa: E402
from scripts import prepare_release_assets as staging  # noqa: E402

JOURNAL_SCHEMA = 1
RETENTION_SCHEMA = staging.RETENTION_SCHEMA

ESTATE_ARCHIVE_NAME = "archive_light.db"
ESTATE_APPROVED_NAME = staging.APPROVED_MANIFEST_NAME
ESTATE_SIGNED_NAME = "archive_manifest.json"
ESTATE_TIER = "LIGHT"
# The estate is the PAIR the publication gate owneth, and the transaction's
# owner refuseth any other entry in that directory (T51/T52 law). The signed
# archive record that answereth the pair therefore liveth BESIDE it, in the
# estate's own record directory -- still mandatory, still verified against the
# operator's store, just not inside the directory the staging gate manageth.
ESTATE_PAIR = (ESTATE_ARCHIVE_NAME, ESTATE_APPROVED_NAME)
ESTATE_TRIO = ESTATE_PAIR + (ESTATE_SIGNED_NAME,)
ESTATE_RECORD_SUFFIX = ".record"


def estate_record_dir(estate: Path) -> Path:
    """Where an estate's signed record liveth, derived from the estate itself
    so that an estate and its record can never drift apart by a caller's
    forgetfulness."""
    estate = Path(estate)
    return estate.parent / (estate.name + ESTATE_RECORD_SUFFIX)


def estate_record_path(estate: Path, record_dir: Path | None = None) -> Path:
    return Path(record_dir or estate_record_dir(estate)) / ESTATE_SIGNED_NAME
JOURNAL_NAME = "recovery-journal.json"
RETAINED_DIR_NAME = "retained"

# The one archive schema the shipping LIGHT release publish eth, bound to the
# archive builder's own authority: a schema bump cannot leave this file (or
# the compatibility matrix below) behind.
ACCEPTED_ARCHIVE_SCHEMA = ARCHIVE_SCHEMA_VERSION

DEVICE_CLAIM = "UNVERIFIED (external: no device in this lane)"

# directions
INSTALL, REPLACE, UPGRADE = "INSTALL", "REPLACE", "UPGRADE"
# outcomes
APPLIED, REFUSED, INTERRUPTED, RECOVERED, WIPED = (
    "APPLIED", "REFUSED", "INTERRUPTED", "RECOVERED", "WIPED")
# journal states, in the order the update reacheth them
REQUESTED = "REQUESTED"
VALIDATED = "VALIDATED"
RETAINED = "RETAINED"
ARCHIVE_REPLACE_INTENT = "ARCHIVE_REPLACE_INTENT"
ARCHIVE_REPLACED = "ARCHIVE_REPLACED"
MANIFEST_PUBLISH_INTENT = "MANIFEST_PUBLISH_INTENT"
MANIFEST_PUBLISHED = "MANIFEST_PUBLISHED"
COMPLETED = "COMPLETED"
ROLLBACK_INTENT = "ROLLBACK_INTENT"
ROLLED_BACK = "ROLLED_BACK"
WIPE_REQUESTED = "WIPE_REQUESTED"
WIPE_ARCHIVE_UNLINKED = "WIPE_ARCHIVE_UNLINKED"
WIPE_MANIFEST_UNLINKED = "WIPE_MANIFEST_UNLINKED"
WIPE_SIGNED_UNLINKED = "WIPE_SIGNED_UNLINKED"
WIPED = "WIPED"

TERMINAL_STATES = (COMPLETED, REFUSED, WIPED)
WIPE_CHAIN = (WIPE_REQUESTED, WIPE_ARCHIVE_UNLINKED, WIPE_MANIFEST_UNLINKED,
              WIPE_SIGNED_UNLINKED, WIPED)
# the boundary NAME of the staging seam -> the journal state it recordeth
BOUNDARY_STATES = {
    "validated": VALIDATED,
    "retained": RETAINED,
    "before_archive_replace": ARCHIVE_REPLACE_INTENT,
    "after_archive_replace": ARCHIVE_REPLACED,
    "before_manifest_publish": MANIFEST_PUBLISH_INTENT,
    "published": MANIFEST_PUBLISHED,
}
# the boundaries a caller may name as an interruption or a disk fault
INTERRUPTIBLE = tuple(BOUNDARY_STATES)


class RecoveryError(RuntimeError):
    """A named, lawful refusal. The estate is untouched when this is raised."""


class RecoveryInterrupted(RecoveryError):
    """A deterministic interruption fired at a real dependency boundary."""

    def __init__(self, boundary: str) -> None:
        self.boundary = boundary
        super().__init__(f"interrupted at {boundary}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _write_json_atomic(path: Path, document: Any) -> None:
    """fsync + rename: a crashed model cannot reconstruct success from memory."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, name = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    os.close(handle)
    temporary = Path(name)
    try:
        with temporary.open("w", encoding="utf-8") as stream:
            stream.write(json.dumps(document, sort_keys=True, indent=2,
                                    ensure_ascii=False) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _read_json_strict(path: Path, origin: str) -> Any:
    try:
        return strict_json_loads(path.read_text(encoding="utf-8"), origin)
    except (OSError, json.JSONDecodeError, ArchiveManifestError) as exc:
        raise RecoveryError(f"{origin} is unreadable: {exc}") from exc


def _default_clock() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _archive_meta(path: Path) -> dict[str, str]:
    uri = f"file:{path.resolve()}?mode=ro&immutable=1"
    connection = sqlite3.connect(uri, uri=True)
    try:
        tables = {row[0] for row in connection.execute(
            "SELECT name FROM sqlite_master WHERE type IN ('table','view')")}
        if "archive_meta" not in tables:
            raise RecoveryError("the archive carrieth no archive_meta")
        return {str(k): str(v) for k, v in
                connection.execute("SELECT key, value FROM archive_meta")}
    finally:
        connection.close()


# ---------------------------------------------------------------------------
# the compatibility matrix
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class RollbackCompatibilityMatrix:
    """Which candidate schema may replace which installed schema, and which
    installed schema a rollback may return to.

    ``accepted_schema`` is what the release PUBLISHETH; ``supported_installed``
    is what the shipping build may RUN from an installed estate (so a rollback
    target is lawful exactly when it lieth in that set); ``migrations`` is the
    declared set of (installed -> accepted) steps, each of which requireth a
    golden fixture before it may be declared. A migration that was never
    declared is refused by name rather than attempted.
    """

    accepted_schema: int
    supported_installed: tuple[int, ...]
    migrations: tuple[tuple[int, int], ...] = ()

    def __post_init__(self) -> None:
        if type(self.accepted_schema) is not int or self.accepted_schema <= 0:
            raise RecoveryError("the accepted archive schema must be a positive integer")
        if not self.supported_installed:
            raise RecoveryError("the matrix must declare at least one supported installed schema")
        for schema in self.supported_installed:
            if type(schema) is not int or schema <= 0:
                raise RecoveryError(f"supported installed schema {schema!r} is not a positive integer")
        if self.accepted_schema not in self.supported_installed:
            raise RecoveryError(
                "the matrix accepteth schema " + str(self.accepted_schema) +
                " as a candidate and yet doth not list it as runnable: the release "
                "would publish an archive the shipping build may not open")
        for step in self.migrations:
            if (not isinstance(step, tuple) or len(step) != 2 or
                    step[1] != self.accepted_schema):
                raise RecoveryError(f"declared migration {step!r} must end at the accepted schema")
            if step[0] not in self.supported_installed:
                raise RecoveryError(
                    f"declared migration {step!r} starteth from a schema the build may not run")

    def classify(self, installed: int | None, candidate: int) -> tuple[str | None, str | None]:
        """Return (direction, refusal). A refusal is never None with a direction."""
        if type(candidate) is not int or candidate <= 0:
            return None, f"the candidate carrieth no usable archive schema: {candidate!r}"
        if candidate > self.accepted_schema:
            return None, (
                f"unknown future schema {candidate} refused: this build accepteth schema "
                f"{self.accepted_schema}. The estate is preserved; it is never recreated empty.")
        if candidate < self.accepted_schema:
            return None, (
                f"unsupported archive schema {candidate} refused: this build publish eth schema "
                f"{self.accepted_schema} alone")
        if installed is None:
            return INSTALL, None
        if type(installed) is not int or installed <= 0:
            return None, f"the installed estate carrieth no usable archive schema: {installed!r}"
        if installed > self.accepted_schema:
            return None, (
                f"unknown future installed schema {installed} refused: this build accepteth schema "
                f"{self.accepted_schema}; the estate is preserved and no candidate is placed over it")
        if installed == self.accepted_schema:
            return REPLACE, None
        if (installed, self.accepted_schema) not in self.migrations:
            return None, (
                f"no declared migration from installed schema {installed} to "
                f"{self.accepted_schema}: an undeclared migration is refused by name")
        return UPGRADE, None

    def rollback_permitted(self, retained: int | None) -> tuple[bool, str | None]:
        if retained is None:
            return False, "no retained estate standeth: there is no rollback target"
        if retained not in self.supported_installed:
            return False, (
                f"rollback refused: the retained estate's schema {retained} is not one this "
                f"build may run (supported: {', '.join(str(s) for s in self.supported_installed)})")
        return True, None

    def to_json(self) -> dict[str, Any]:
        return {
            "accepted_schema": self.accepted_schema,
            "supported_installed": list(self.supported_installed),
            "migrations": [list(step) for step in self.migrations],
        }


# The shipped matrix. There is no earlier SUPPORTED archive version in this
# repository: docs/production/MIGRATION.md requireth a fixture-based migration
# from every supported version, and this baseline carrieth none, so the honest
# declaration is that a schema-2 estate is refused by name until such a fixture
# and step are declared. The migration CODE PATH is not dead: it is exercised
# with a rehearsal matrix (see the T77 court), which is where a future
# supported version's step would be proven before it was declared here.
SHIPPED_MATRIX = RollbackCompatibilityMatrix(
    accepted_schema=ACCEPTED_ARCHIVE_SCHEMA,
    supported_installed=(ACCEPTED_ARCHIVE_SCHEMA,),
    migrations=(),
)


# ---------------------------------------------------------------------------
# the journal
# ---------------------------------------------------------------------------
@dataclass
class Journal:
    """The durable record of one recovery operation.

    It liveth OUTSIDE the estate on purpose: the estate's bytes must be
    provably untouched by a refusal, and a journal written into the estate
    would make every refusal a mutation.
    """

    path: Path
    clock: Callable[[], str] = _default_clock
    entries: list[dict[str, Any]] = field(default_factory=list)

    def load(self) -> "Journal":
        if not self.path.is_file():
            return self
        document = _read_json_strict(self.path, str(self.path))
        if not isinstance(document, Mapping):
            raise RecoveryError(f"the journal {self.path} is not an object")
        version = document.get("schema")
        if version != JOURNAL_SCHEMA:
            raise RecoveryError(
                f"the journal schema {version!r} is refused: only schema {JOURNAL_SCHEMA} is "
                "known and a future journal is never auto-detected")
        entries = document.get("entries")
        if not isinstance(entries, list) or not all(isinstance(e, Mapping) for e in entries):
            raise RecoveryError(f"the journal {self.path} carrieth no usable entry list")
        self.entries = [dict(entry) for entry in entries]
        return self

    def record(self, state: str, **fields: Any) -> None:
        self.entries.append({"state": state, "at_utc": self.clock(), **fields})
        _write_json_atomic(self.path, {"schema": JOURNAL_SCHEMA, "entries": self.entries})

    @property
    def state(self) -> str | None:
        return self.entries[-1]["state"] if self.entries else None

    def states(self) -> tuple[str, ...]:
        return tuple(str(entry["state"]) for entry in self.entries)


# ---------------------------------------------------------------------------
# the estates
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class InstalledEstate:
    present: bool
    archive_sha256: str | None = None
    archive_bytes: int | None = None
    schema: int | None = None
    approved_manifest_sha256: str | None = None
    signed_manifest_sha256: str | None = None
    key_id: str | None = None
    tier: str | None = None

    def to_json(self) -> dict[str, Any]:
        return {
            "present": self.present,
            "archive_sha256": self.archive_sha256,
            "archive_bytes": self.archive_bytes,
            "schema": self.schema,
            "approved_manifest_sha256": self.approved_manifest_sha256,
            "signed_manifest_sha256": self.signed_manifest_sha256,
            "key_id": self.key_id,
            "tier": self.tier,
        }

    def same_bytes_as(self, other: "InstalledEstate") -> bool:
        return (self.archive_sha256 == other.archive_sha256 and
                self.archive_bytes == other.archive_bytes and
                self.approved_manifest_sha256 == other.approved_manifest_sha256 and
                self.signed_manifest_sha256 == other.signed_manifest_sha256)


@dataclass(frozen=True)
class CandidateSource:
    """What the operator furnisheth as the next estate.

    ``asset_manifest`` is the full production bundle manifest; when it is
    present the candidate is opened through the REAL staging gate
    (scripts/prepare_release_assets.validate), and the archive and signed
    manifest it nameth are the authoritative ones -- a caller's own paths are
    never believed over the document's.
    """

    archive: Path | None = None
    signed_manifest: Path | None = None
    asset_manifest: Path | None = None


@dataclass(frozen=True)
class CandidateEstate:
    archive_path: Path
    archive_sha256: str
    archive_bytes: int
    schema: int
    signed_manifest_sha256: str
    signed_manifest_path: Path
    tier: str
    key_id: str | None
    candidate_class: str

    def to_json(self) -> dict[str, Any]:
        return {
            "archive_sha256": self.archive_sha256,
            "archive_bytes": self.archive_bytes,
            "schema": self.schema,
            "signed_manifest_sha256": self.signed_manifest_sha256,
            "tier": self.tier,
            "key_id": self.key_id,
            "candidate_class": self.candidate_class,
        }


@dataclass(frozen=True)
class RecoveryResult:
    case_id: str
    outcome: str
    direction: str | None
    installed_schema: int | None
    candidate_schema: int | None
    old_archive_sha256: str | None
    new_archive_sha256: str | None
    preserved: bool
    refusals: tuple[str, ...] = ()
    retained_path: str | None = None
    retained_schema: int | None = None
    rollback_permitted: bool = False
    rollback_refusal: str | None = None
    boundaries: tuple[str, ...] = ()
    journal: tuple[str, ...] = ()
    candidate_class: str | None = None
    device_claim: str = DEVICE_CLAIM
    production_claim: str = (
        "NONE: this result proveth the RECOVERY PROTOCOL. It closeth no external gate "
        "and establisheth no installation on any device.")

    def to_json(self) -> dict[str, Any]:
        return {
            "case_id": self.case_id,
            "outcome": self.outcome,
            "direction": self.direction,
            "installed_schema": self.installed_schema,
            "candidate_schema": self.candidate_schema,
            "old_archive_sha256": self.old_archive_sha256,
            "new_archive_sha256": self.new_archive_sha256,
            "preserved": self.preserved,
            "refusals": list(self.refusals),
            "retained_path": self.retained_path,
            "retained_schema": self.retained_schema,
            "rollback_permitted": self.rollback_permitted,
            "rollback_refusal": self.rollback_refusal,
            "boundaries": list(self.boundaries),
            "journal": list(self.journal),
            "candidate_class": self.candidate_class,
            "device_claim": self.device_claim,
            "production_claim": self.production_claim,
        }


# ---------------------------------------------------------------------------
# opening an estate
# ---------------------------------------------------------------------------
def open_estate(estate: Path, trust_store: Path,
                record_dir: Path | None = None) -> InstalledEstate:
    """The installed estate, or a refusal BY NAME. Never a write.

    Law 2 (a partial estate is never an empty one) and law 3 (a future schema
    is refused, never recreated) both bind here.
    """
    estate = Path(estate)
    trust_store = Path(trust_store)
    signed_path = estate_record_path(estate, record_dir)
    if not trust_store.is_file():
        raise RecoveryError(
            "the operator-selected trust store is required and is absent: " + str(trust_store) +
            ". Recovery is offline and the trust store is never read from the estate's own record.")
    present = [name for name in ESTATE_PAIR if (estate / name).is_file()]
    extra = sorted(entry.name for entry in estate.iterdir()) if estate.is_dir() else []
    extra = [name for name in extra if name not in ESTATE_PAIR]
    if not present:
        if signed_path.is_file():
            raise RecoveryError(
                "the signed archive record standeth without an estate: " + str(signed_path) +
                ". A record naming bytes that are nowhere is a broken state, never an empty install.")
        return InstalledEstate(present=False)
    if len(present) != len(ESTATE_PAIR):
        missing = [name for name in ESTATE_PAIR if name not in present]
        raise RecoveryError(
            "the estate is incomplete: " + ", ".join(missing) + " is missing. A partial estate is "
            "a wipe in progress or a broken estate -- it is never read as an empty one, and it is "
            "never recreated empty.")
    if extra:
        raise RecoveryError(
            "the estate carrieth unexpected entries: " + ", ".join(extra) + ". The estate is the "
            "pair the publication gate owneth; its signed record liveth beside it.")
    if not signed_path.is_file():
        raise RecoveryError(
            "the estate carrieth no signed archive record: " + str(signed_path) + " is absent, and "
            "an estate that cannot be verified offline is never opened.")
    approved_path = estate / ESTATE_APPROVED_NAME
    archive_path = estate / ESTATE_ARCHIVE_NAME
    approved = _read_json_strict(approved_path, str(approved_path))
    if not isinstance(approved, Mapping):
        raise RecoveryError("the published approved-resource manifest is not an object")
    if approved.get("schema") != staging.APPROVED_MANIFEST_SCHEMA:
        raise RecoveryError(
            f"the published approved-resource manifest schema {approved.get('schema')!r} is refused")
    tier = approved.get("tier")
    if tier != ESTATE_TIER:
        raise RecoveryError(f"the published approved-resource manifest tier {tier!r} is not {ESTATE_TIER}")
    assets = approved.get("assets")
    if not isinstance(assets, list) or len(assets) != 1 or not isinstance(assets[0], Mapping):
        raise RecoveryError("the published approved-resource manifest must name exactly one archive")
    asset = assets[0]
    if asset.get("role") != "archive" or asset.get("name") != ESTATE_ARCHIVE_NAME:
        raise RecoveryError("the published approved-resource manifest nameth an unexpected asset")
    digest = asset.get("sha256")
    size = asset.get("bytes")
    if (not isinstance(digest, str) or not staging.SHA256_RE.fullmatch(digest) or
            type(size) is not int or isinstance(size, bool) or size <= 0):
        raise RecoveryError("the published approved-resource manifest carrieth no usable digest and size")
    if sha256_file(archive_path) != digest or archive_path.stat().st_size != size:
        raise RecoveryError(
            "the published manifest nameth bytes that are not present: the estate is mid-update, "
            "mid-wipe or broken -- never empty")
    try:
        verdict = verify_manifest(signed_path, archive_path, load_trust_store(trust_store),
                                 expected_tier=ESTATE_TIER)
    except (ArchiveManifestError, OSError, ValueError) as exc:
        raise RecoveryError(f"the signed archive manifest is unreadable: {exc}") from exc
    if not verdict.ok:
        raise RecoveryError("the estate is refused by the signed archive manifest: " +
                            "; ".join(verdict.errors))
    document = verdict.manifest or {}
    schema = document.get("archive_schema")
    if type(schema) is not int:
        raise RecoveryError("the signed archive manifest carrieth no integer archive_schema")
    meta = _archive_meta(archive_path)
    if str(meta.get("schema_version", "")) != str(schema):
        raise RecoveryError(
            f"the archive's own schema_version {meta.get('schema_version')!r} disagreeth with the "
            f"signed manifest's {schema!r}")
    signature = document.get("signature") or {}
    return InstalledEstate(
        present=True,
        archive_sha256=digest,
        archive_bytes=size,
        schema=schema,
        approved_manifest_sha256=sha256_file(approved_path),
        signed_manifest_sha256=sha256_file(signed_path),
        key_id=str(signature.get("key_id")) if signature.get("key_id") else None,
        tier=str(tier),
    )


def open_candidate(source: CandidateSource, trust_store: Path, *,
                   require_production_approval: bool = False) -> CandidateEstate:
    """The candidate, verified BEFORE anything in the estate is touched.

    With ``require_production_approval`` the candidate must pass the real
    staging gate, which refuseth a development fixture (it carrieth no
    production review provenance). Without it -- the REHEARSAL face -- the
    same verifier primitives are bound and the result is labelled
    development-fixture, so a rehearsal can never be quoted as an approval.
    """
    trust_store = Path(trust_store)
    if not trust_store.is_file():
        raise RecoveryError("the operator-selected trust store is required and is absent: " +
                            str(trust_store))
    archive = source.archive
    signed = source.signed_manifest
    candidate_class = "development-fixture"
    if require_production_approval:
        if source.asset_manifest is None:
            raise RecoveryError(
                "a production candidate requireth the approved asset manifest "
                "(--asset-manifest); a bare archive path is never an approval")
        try:
            staging.validate(Path(source.asset_manifest), trust_store_path=trust_store)
        except (ArchiveManifestError, OSError, ValueError) as exc:
            raise RecoveryError(f"the candidate is refused by the release asset gate: {exc}") from exc
        root = Path(source.asset_manifest).resolve().parent
        document = _read_json_strict(Path(source.asset_manifest), str(source.asset_manifest))
        try:
            archive = staging.local_file(root, document["assets"][0].get("source"),
                                        "assets[0].source")
            signed = staging.local_file(root, document.get("archive_manifest"), "archive_manifest")
        except (ValueError, KeyError, IndexError, TypeError) as exc:
            raise RecoveryError(f"the approved asset manifest carrieth no usable candidate: {exc}") from exc
        candidate_class = "release-candidate"
    if archive is None or signed is None:
        raise RecoveryError(
            "a candidate requireth both the archive and the signed archive manifest it answers")
    archive, signed = Path(archive), Path(signed)
    if not archive.is_file():
        raise RecoveryError(f"the candidate archive is absent: {archive}")
    try:
        verdict = verify_manifest(signed, archive, load_trust_store(trust_store),
                                 expected_tier=ESTATE_TIER)
    except (ArchiveManifestError, OSError, ValueError) as exc:
        raise RecoveryError(f"the candidate's signed archive manifest is unreadable: {exc}") from exc
    if not verdict.ok:
        raise RecoveryError("the candidate is refused by its signed archive manifest: " +
                            "; ".join(verdict.errors))
    document = verdict.manifest or {}
    schema = document.get("archive_schema")
    if type(schema) is not int:
        raise RecoveryError("the candidate's signed archive manifest carrieth no integer archive_schema")
    meta = _archive_meta(archive)
    if str(meta.get("schema_version", "")) != str(schema):
        raise RecoveryError(
            f"the candidate archive's own schema_version {meta.get('schema_version')!r} disagreeth "
            f"with its signed manifest's {schema!r}")
    signature = document.get("signature") or {}
    return CandidateEstate(
        archive_path=archive,
        archive_sha256=sha256_file(archive),
        archive_bytes=archive.stat().st_size,
        schema=schema,
        signed_manifest_sha256=sha256_file(signed),
        signed_manifest_path=signed,
        tier=str(document.get("tier")),
        key_id=str(signature.get("key_id")) if signature.get("key_id") else None,
        candidate_class=candidate_class,
    )


# ---------------------------------------------------------------------------
# the transaction
# ---------------------------------------------------------------------------
class _Hooks(staging.PublishHooks):
    """The staging seam, bound to the journal and to a case's fault schedule."""

    def __init__(self, journal: Journal, *, estate: Path, retained: Path,
                 interruption: str | None, disk_fault: str | None,
                 boundaries: list[str], installed: InstalledEstate,
                 signed_manifest: Path, record_dir: Path | None = None) -> None:
        self.journal = journal
        self.estate = Path(estate)
        self.record_dir = Path(record_dir) if record_dir is not None else estate_record_dir(estate)
        self.retained = Path(retained)
        self.interruption = interruption
        self.disk_fault = disk_fault
        self.boundaries: list[str] = boundaries
        self.installed = installed
        self.signed_manifest = Path(signed_manifest)

    def at(self, boundary: str) -> None:
        self.boundaries.append(boundary)
        # the estate's OWN sworn record travels into the retention directory
        # beside the pair the staging gate retaineth, so a rollback can
        # re-verify offline. It is copied before the pair is replaced.
        if boundary == "validated" and self.installed.present:
            self._retain_signed_record()
        self.journal.record(BOUNDARY_STATES[boundary])
        # the signed archive manifest that ANSWERS the new bytes travelleth
        # with them: the estate is bound to its sworn records, so a pair
        # whose record still nameth the previous archive is not an estate.
        if boundary == "published":
            self._place_signed_record()
        if self.disk_fault == boundary:
            raise OSError(errno.ENOSPC, f"no space left on device (injected at {boundary})")
        if self.interruption == boundary:
            raise RecoveryInterrupted(boundary)

    def _retain_signed_record(self) -> None:
        self.retained.mkdir(parents=True, exist_ok=True)
        source = estate_record_path(self.estate, self.record_dir)
        if not source.is_file():
            raise RecoveryError("the estate carrieth no signed archive manifest to retain")
        target = self.retained / ESTATE_SIGNED_NAME
        shutil.copyfile(source, target)
        with target.open("rb") as stream:
            os.fsync(stream.fileno())

    def _place_signed_record(self) -> None:
        self.record_dir.mkdir(parents=True, exist_ok=True)
        source = self.signed_manifest
        if not source.is_file():
            raise RecoveryError(f"the candidate carrieth no signed archive manifest: {source}")
        temporary = self.record_dir / ("." + ESTATE_SIGNED_NAME + ".candidate")
        try:
            shutil.copyfile(source, temporary)
            with temporary.open("rb") as stream:
                os.fsync(stream.fileno())
            os.replace(temporary, self.record_dir / ESTATE_SIGNED_NAME)
        finally:
            temporary.unlink(missing_ok=True)


def _retained_schema(retained: Path, trust_store: Path, archive_name: str) -> int | None:
    """The schema of the retained estate, read from its own retained signed
    record -- recomputed here, never carried from the journal on trust."""
    signed = Path(retained) / ESTATE_SIGNED_NAME
    archive = Path(retained) / archive_name
    if not (signed.is_file() and archive.is_file()):
        return None
    verdict = verify_manifest(signed, archive, load_trust_store(trust_store),
                             expected_tier=ESTATE_TIER)
    if not verdict.ok:
        return None
    schema = (verdict.manifest or {}).get("archive_schema")
    return schema if type(schema) is int else None


def _retained_record(retained: Path) -> Mapping[str, Any]:
    record_path = Path(retained) / staging.RETENTION_RECORD_NAME
    record = _read_json_strict(record_path, str(record_path))
    if not isinstance(record, Mapping) or record.get("schema") != RETENTION_SCHEMA:
        raise RecoveryError(
            f"the retention record schema {record.get('schema') if isinstance(record, Mapping) else None!r} "
            f"is refused: only schema {RETENTION_SCHEMA} is known")
    for field_name in ("archive", "approved_manifest"):
        entry = record.get(field_name)
        if not isinstance(entry, Mapping):
            raise RecoveryError(f"the retention record carrieth no {field_name} entry")
        path = Path(retained) / str(entry.get("name", ""))
        if not path.is_file():
            raise RecoveryError(
                f"the retention record nameth a {field_name} that is not present: {path.name}")
        if sha256_file(path) != entry.get("sha256") or path.stat().st_size != entry.get("bytes"):
            raise RecoveryError(
                f"the retained {field_name} doth not match the record: the rollback target is not whole")
    return record


def _restore_from_retention(estate: Path, retained: Path, trust_store: Path,
                            journal: Journal, record_dir: Path | None = None) -> None:
    """Put the previous authoritative estate back, whole, and prove it.

    The archive is placed first, then the published manifest that nameth it.
    Between the two the pair is INCONSISTENT and open_estate refuseth it by
    name -- so the window is visible rather than silent. An interruption
    inside the restore is resumable, because ROLLBACK_INTENT standeth in the
    journal before the first placement and the retained copy is still whole.
    """
    estate = Path(estate)
    _retained_record(retained)
    destinations = {
        ESTATE_ARCHIVE_NAME: estate / ESTATE_ARCHIVE_NAME,
        ESTATE_APPROVED_NAME: estate / ESTATE_APPROVED_NAME,
        ESTATE_SIGNED_NAME: estate_record_path(estate, record_dir),
    }
    for name in ESTATE_TRIO:
        source = Path(retained) / name
        if not source.is_file():
            raise RecoveryError(f"the retained estate wanteth {name}: there is no rollback target")
    journal.record(ROLLBACK_INTENT)
    for name in ESTATE_TRIO:
        source = Path(retained) / name
        destination = destinations[name]
        destination.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary_name = tempfile.mkstemp(prefix="." + name + ".", dir=destination.parent)
        os.close(handle)
        temporary = Path(temporary_name)
        try:
            shutil.copyfile(source, temporary)
            with temporary.open("rb") as stream:
                os.fsync(stream.fileno())
            os.replace(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)
    journal.record(ROLLED_BACK)


def _result(case: "UpgradeCase", outcome: str, *, direction: str | None = None,
            installed: InstalledEstate | None = None, candidate: CandidateEstate | None = None,
            preserved: bool, refusals: Sequence[str] = (), retained: Path | None = None,
            retained_schema: int | None = None, matrix: RollbackCompatibilityMatrix = SHIPPED_MATRIX,
            boundaries: Sequence[str] = (), journal: Journal | None = None) -> RecoveryResult:
    permitted, refusal = matrix.rollback_permitted(retained_schema) if retained is not None else (False, None)
    return RecoveryResult(
        case_id=case.case_id,
        outcome=outcome,
        direction=direction,
        installed_schema=installed.schema if installed is not None else case.installed_schema,
        candidate_schema=candidate.schema if candidate is not None else case.candidate_schema,
        old_archive_sha256=installed.archive_sha256 if installed is not None else None,
        new_archive_sha256=candidate.archive_sha256 if candidate is not None else None,
        preserved=preserved,
        refusals=tuple(refusals),
        retained_path=str(retained) if retained is not None else None,
        retained_schema=retained_schema,
        rollback_permitted=permitted,
        rollback_refusal=refusal,
        boundaries=tuple(boundaries),
        journal=journal.states() if journal is not None else (),
        candidate_class=candidate.candidate_class if candidate is not None else None,
    )


@dataclass(frozen=True)
class UpgradeCase:
    """One declared rehearsal. The expectation is the card's law; the
    RecoveryResult is the evidence, and the court asserteth the two against
    each other."""

    case_id: str
    expectation: str
    installed_schema: int | None = None
    candidate_schema: int | None = None
    installed_variant: str = "installed"
    candidate_variant: str = "candidate"
    interruption: str | None = None
    disk_fault: str | None = None
    refusal_fragment: str | None = None
    description: str = ""

    def to_json(self) -> dict[str, Any]:
        return {
            "case_id": self.case_id,
            "expectation": self.expectation,
            "installed_schema": self.installed_schema,
            "candidate_schema": self.candidate_schema,
            "installed_variant": self.installed_variant,
            "candidate_variant": self.candidate_variant,
            "interruption": self.interruption,
            "disk_fault": self.disk_fault,
            "refusal_fragment": self.refusal_fragment,
            "description": self.description,
        }


def _rehearsal_approved_document(candidate: CandidateEstate) -> dict[str, Any]:
    """The published manifest for a REHEARSAL candidate.

    It is labelled as what it is: a development rehearsal, not an approval.
    A production candidate never travels this road -- it goeth through
    staging.stage, which refuseth a document that is not approved and
    production_ready with production review provenance.
    """
    return {
        "schema": staging.APPROVED_MANIFEST_SCHEMA,
        "tier": ESTATE_TIER,
        "application_id": "io.godstone.app",
        "generated_by": "scripts/upgrade_recovery.py (DEVELOPMENT REHEARSAL -- NOT AN APPROVAL)",
        "assets": [{
            "role": "archive",
            "name": ESTATE_ARCHIVE_NAME,
            "sha256": candidate.archive_sha256,
            "bytes": candidate.archive_bytes,
            "build_phase": "resources",
        }],
    }


def _publish(source: CandidateSource, candidate: CandidateEstate, estate: Path, trust_store: Path,
             retained: Path, hooks: "_Hooks", *, require_production_approval: bool) -> None:
    """Drive the ONE publication owner, on whichever face the caller selected."""
    if require_production_approval:
        staging.stage(Path(source.asset_manifest), Path(estate), trust_store_path=Path(trust_store),
                      retention=retained, hooks=hooks)
        return
    staging.publish_verified(ESTATE_ARCHIVE_NAME, candidate.archive_path, output=Path(estate),
                             expected_hash=candidate.archive_sha256,
                             expected_bytes=candidate.archive_bytes,
                             approved_document=_rehearsal_approved_document(candidate),
                             retention=retained, hooks=hooks)


def rehearse(case: UpgradeCase, *, estate: Path, candidate: CandidateSource,
             trust_store: Path, work_root: Path, matrix: RollbackCompatibilityMatrix = SHIPPED_MATRIX,
             require_production_approval: bool = False,
             settle_on_fault: bool = True, record_dir: Path | None = None,
             clock: Callable[[], str] = _default_clock) -> RecoveryResult:
    """Execute one upgrade case against a real estate, transactionally.

    Every refusal precedeth every write to the estate; the journal standeth
    outside it. On any interruption or fault the previous authoritative
    estate is restored from the retention record and re-verified, and the
    result telleth whether it is byte-identical to what stood before.
    """
    estate = Path(estate)
    work_root = Path(work_root)
    work_root.mkdir(parents=True, exist_ok=True)
    retained = work_root / RETAINED_DIR_NAME / case.case_id
    journal = Journal(work_root / f"{case.case_id}.{JOURNAL_NAME}", clock=clock)
    boundaries: list[str] = []
    if matrix.accepted_schema != ACCEPTED_ARCHIVE_SCHEMA:
        raise RecoveryError(
            f"the matrix accepteth schema {matrix.accepted_schema} and this build publish eth "
            f"{ACCEPTED_ARCHIVE_SCHEMA}: a matrix that disagreeth with the shipped schema is refused")
    record_dir = Path(record_dir) if record_dir is not None else estate_record_dir(estate)
    installed = open_estate(estate, trust_store, record_dir)   # law 1/2/3: no write
    try:
        next_estate = open_candidate(candidate, trust_store,
                                    require_production_approval=require_production_approval)
    except RecoveryError as exc:
        # a candidate that cannot be verified is a REFUSAL, not a crash: a
        # failed signature (or a missing approval) leaveth the previous
        # authoritative estate exactly as it stood.
        journal.record(REFUSED, case=case.case_id, reason=str(exc))
        return _result(case, REFUSED, installed=installed, preserved=True,
                       refusals=(str(exc),), matrix=matrix, boundaries=boundaries, journal=journal)
    direction, refusal = matrix.classify(installed.schema, next_estate.schema)   # law 4
    if refusal is not None:
        journal.record(REFUSED, case=case.case_id, reason=refusal)
        return _result(case, REFUSED, installed=installed, candidate=next_estate, preserved=True,
                       refusals=(refusal,), matrix=matrix, boundaries=boundaries, journal=journal)
    journal.record(REQUESTED, direction=direction,
                   installed_schema=installed.schema, candidate_schema=next_estate.schema)
    hooks = _Hooks(journal, estate=estate, retained=retained,
                   interruption=case.interruption, disk_fault=case.disk_fault,
                   boundaries=boundaries, installed=installed, record_dir=record_dir,
                   signed_manifest=next_estate.signed_manifest_path)
    try:
        _publish(candidate, next_estate, estate, trust_store, retained, hooks,
                 require_production_approval=require_production_approval)
    except RecoveryInterrupted as exc:
        if not settle_on_fault:
            # the process DIED at the boundary: nothing mended the estate, and
            # the recovery is the resumer's to prove from the record alone.
            raise
        return _settle(case, estate, retained, trust_store, journal, installed, next_estate,
                       matrix, boundaries, direction, record_dir=record_dir,
                       refusal=f"interrupted at {exc.boundary}",
                       interrupted_boundary=exc.boundary)
    except OSError as exc:
        if not settle_on_fault:
            raise
        cause = ("the disk was full" if exc.errno == errno.ENOSPC else
                 f"the filesystem refused the update ({exc.strerror or exc})")
        return _settle(case, estate, retained, trust_store, journal, installed, next_estate,
                       matrix, boundaries, direction, record_dir=record_dir,
                       refusal=f"{cause}: the previous authoritative estate is preserved",
                       interrupted_boundary=case.disk_fault)
    except (ArchiveManifestError, ValueError) as exc:
        if not settle_on_fault:
            raise
        return _settle(case, estate, retained, trust_store, journal, installed, next_estate,
                       matrix, boundaries, direction, record_dir=record_dir,
                       refusal=f"the publication refused the candidate: {exc}",
                       interrupted_boundary=None)
    journal.record(COMPLETED, archive_sha256=next_estate.archive_sha256)
    retained_schema = _retained_schema(retained, trust_store, ESTATE_ARCHIVE_NAME)
    return _result(case, APPLIED, direction=direction, installed=installed, candidate=next_estate,
                   preserved=False, retained=retained, retained_schema=retained_schema,
                   matrix=matrix, boundaries=boundaries, journal=journal)


def _settle(case: UpgradeCase, estate: Path, retained: Path, trust_store: Path, journal: Journal,
            installed: InstalledEstate, candidate: CandidateEstate,
            matrix: RollbackCompatibilityMatrix, boundaries: list[str], direction: str | None,
            *, refusal: str, interrupted_boundary: str | None,
            record_dir: Path | None = None) -> RecoveryResult:
    """Reach a terminal, self-consistent state after an interruption or fault.

    The published manifest must always name bytes that are present, so when
    the pair is not whole the previous estate is restored from the retention
    record. When nothing had been placed yet, the previous estate already
    standeth and is left alone.
    """
    state = journal.state
    if state in (ARCHIVE_REPLACE_INTENT, ARCHIVE_REPLACED, MANIFEST_PUBLISH_INTENT,
                 MANIFEST_PUBLISHED):
        # the transaction is complete only when its OWN record sayeth so: a
        # boundary that fired before COMPLETED is journaled leaveth the
        # previous authoritative estate standing, whole.
        _restore_from_retention(estate, retained, trust_store, journal, record_dir)
    restored = (open_estate(estate, trust_store, record_dir)
                if state != ARCHIVE_REPLACE_INTENT else installed)
    preserved = True
    if installed.present:
        preserved = restored.same_bytes_as(installed)
    else:
        preserved = not restored.present
    if not preserved:
        raise RecoveryError(
            "the previous authoritative estate was NOT preserved after " + str(interrupted_boundary) +
            ": the update mutated the estate and then refused (this is a defect, not a refusal)")
    journal.record(REFUSED, reason=refusal, preserved=True)
    outcome = INTERRUPTED if interrupted_boundary is not None else REFUSED
    return _result(case, outcome, direction=direction, installed=installed, candidate=candidate,
                   preserved=True, refusals=(refusal,), retained=retained,
                   retained_schema=_retained_schema(retained, trust_store, ESTATE_ARCHIVE_NAME),
                   matrix=matrix, boundaries=boundaries, journal=journal)


def rollback(*, estate: Path, retained: Path, trust_store: Path, work_root: Path,
             case_id: str = "rollback", matrix: RollbackCompatibilityMatrix = SHIPPED_MATRIX,
             record_dir: Path | None = None,
             clock: Callable[[], str] = _default_clock) -> RecoveryResult:
    """Return to the retained estate -- under the explicit compatible trust policy."""
    estate, retained, work_root = Path(estate), Path(retained), Path(work_root)
    work_root.mkdir(parents=True, exist_ok=True)
    journal = Journal(work_root / f"{case_id}.{JOURNAL_NAME}", clock=clock)
    case = UpgradeCase(case_id=case_id, expectation=RECOVERED)
    record_dir = Path(record_dir) if record_dir is not None else estate_record_dir(estate)
    try:
        installed: InstalledEstate | None = open_estate(estate, trust_store, record_dir)
    except RecoveryError:
        # the estate is mid-update or mid-wipe: that is exactly what a
        # rollback mendeth, and the refusal above is recorded as the reason
        # the rollback was needed, not as a bar to it.
        installed = None
    retained_schema = _retained_schema(retained, trust_store, ESTATE_ARCHIVE_NAME)
    permitted, refusal = matrix.rollback_permitted(retained_schema)
    if not permitted:
        journal.record(REFUSED, reason=refusal)
        return _result(case, REFUSED, installed=installed, preserved=True, refusals=(refusal,),
                       retained=retained, retained_schema=retained_schema, matrix=matrix,
                       journal=journal)
    record = _retained_record(retained)
    _restore_from_retention(estate, retained, trust_store, journal, record_dir)
    restored = open_estate(estate, trust_store, record_dir)
    preserved = (restored.archive_sha256 == (record.get("archive") or {}).get("sha256") and
                 restored.schema == retained_schema)
    if not preserved:
        raise RecoveryError(
            "the rollback did not restore the retained estate: the bytes that stand do not match "
            "the retention record")
    journal.record(COMPLETED, rolled_back=True)
    return _result(case, RECOVERED, direction=RECOVERED, installed=installed,
                   preserved=True, retained=retained, retained_schema=retained_schema,
                   matrix=matrix, journal=journal)


def resume(*, estate: Path, trust_store: Path, work_root: Path, case_id: str,
           matrix: RollbackCompatibilityMatrix = SHIPPED_MATRIX, record_dir: Path | None = None,
           clock: Callable[[], str] = _default_clock) -> RecoveryResult:
    """Reach a terminal state from the record alone.

    A journal in the WIPE chain is carried to completion (a wipe is terminal);
    an update that had not published its manifest is rolled back from the
    retention record; an update that had published is already whole and is
    reported as such. Nothing is guessed and no byte is inferred from memory.
    """
    work_root, estate = Path(work_root), Path(estate)
    record_dir = Path(record_dir) if record_dir is not None else estate_record_dir(estate)
    journal = Journal(work_root / f"{case_id}.{JOURNAL_NAME}", clock=clock).load()
    case = UpgradeCase(case_id=case_id, expectation=RECOVERED)
    state = journal.state
    retained = work_root / RETAINED_DIR_NAME / case_id
    if state is None:
        raise RecoveryError(
            "no journal standeth for " + case_id + ": an interruption before the record was "
            "written cannot be resumed by guessing; the estate is verified as it standeth")
    if state in WIPE_CHAIN:
        return wipe(estate=estate, work_root=work_root, case_id=case_id, trust_store=trust_store,
                    matrix=matrix, record_dir=record_dir, clock=clock)
    if state == REFUSED:
        return _result(case, REFUSED, preserved=True, refusals=("the recorded refusal standeth",),
                       matrix=matrix, journal=journal)
    if state == COMPLETED:
        installed = open_estate(estate, trust_store, record_dir)
        return _result(case, APPLIED, installed=installed, preserved=False, matrix=matrix,
                       journal=journal)
    if state in (ARCHIVE_REPLACE_INTENT, ARCHIVE_REPLACED, MANIFEST_PUBLISH_INTENT,
                 MANIFEST_PUBLISHED):
        before = None
        for entry in reversed(journal.entries):
            if "installed_schema" in entry:
                before = entry["installed_schema"]
                break
        # the estate is KNOWINGLY mid-update here -- that is what the journal
        # just said -- so its refusal to open is the reason for the rollback,
        # not a bar to it.
        try:
            installed: InstalledEstate | None = open_estate(estate, trust_store, record_dir)
        except RecoveryError:
            installed = None
        _restore_from_retention(estate, retained, trust_store, journal, record_dir)
        restored = open_estate(estate, trust_store, record_dir)
        if before is not None and restored.schema != before:
            raise RecoveryError(
                f"the resumed estate carrieth schema {restored.schema} and the journal recorded "
                f"{before}: the rollback did not restore the previous estate")
        journal.record(COMPLETED, recovered=True)
        return _result(case, RECOVERED, installed=installed, preserved=True, retained=retained,
                       retained_schema=_retained_schema(retained, trust_store, ESTATE_ARCHIVE_NAME),
                       matrix=matrix, journal=journal)
    # REQUESTED / VALIDATED / RETAINED / ROLLBACK_INTENT: nothing was placed,
    # or a rollback was already under way -- carry the rollback to its end.
    if state == ROLLBACK_INTENT:
        _restore_from_retention(estate, retained, trust_store, journal, record_dir)
    installed = open_estate(estate, trust_store, record_dir)
    journal.record(COMPLETED, recovered=True)
    return _result(case, RECOVERED, installed=installed, preserved=True, retained=retained,
                   retained_schema=_retained_schema(retained, trust_store, ESTATE_ARCHIVE_NAME),
                   matrix=matrix, journal=journal)


def wipe(*, estate: Path, work_root: Path, case_id: str = "wipe", trust_store: Path | None = None,
         matrix: RollbackCompatibilityMatrix = SHIPPED_MATRIX, interruption: str | None = None,
         record_dir: Path | None = None,
         clock: Callable[[], str] = _default_clock) -> RecoveryResult:
    """Erase the estate, journaled and resumable. Terminal states are exactly
    WIPED or the previous authoritative estate intact.

    The unlink order is archive, then published manifest, then signed record.
    A crash at any step leaveth an estate that open_estate refuseth BY NAME
    (partially wiped), never one that readeth as a healthy empty install.
    """
    estate, work_root = Path(estate), Path(work_root)
    record_dir = Path(record_dir) if record_dir is not None else estate_record_dir(estate)
    work_root.mkdir(parents=True, exist_ok=True)
    journal = Journal(work_root / f"{case_id}.{JOURNAL_NAME}", clock=clock).load()
    case = UpgradeCase(case_id=case_id, expectation=WIPED)
    present = [name for name in ESTATE_PAIR if (estate / name).is_file()]
    if not present and not journal.entries:
        journal.record(WIPE_REQUESTED)
        journal.record(WIPED)
        return _result(case, WIPED, preserved=True, matrix=matrix, journal=journal)
    if journal.state != WIPE_REQUESTED:
        journal.record(WIPE_REQUESTED, present=present)
    steps = ((ESTATE_ARCHIVE_NAME, WIPE_ARCHIVE_UNLINKED, estate / ESTATE_ARCHIVE_NAME),
             (ESTATE_APPROVED_NAME, WIPE_MANIFEST_UNLINKED, estate / ESTATE_APPROVED_NAME),
             (ESTATE_SIGNED_NAME, WIPE_SIGNED_UNLINKED,
              estate_record_path(estate, record_dir)))
    for name, state, target in steps:
        if target.is_file():
            target.unlink()
            try:
                directory = os.open(target.parent, os.O_RDONLY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            except OSError:
                pass
        journal.record(state)
        # the interruption landeth AFTER the step it nameth, so a wipe in
        # progress is a real partial estate and never a whole one that was
        # merely about to be touched.
        if interruption == state:
            raise RecoveryInterrupted(state)
    journal.record(WIPED)
    return _result(case, WIPED, preserved=False, matrix=matrix, journal=journal)


# ---------------------------------------------------------------------------
# the operator's instructions -- offline, and naming every artifact
# ---------------------------------------------------------------------------
def recovery_instructions() -> tuple[str, ...]:
    return (
        "Recovery is OFFLINE. No step below fetcheth anything; a device that cannot "
        "reach a network can still be recovered (invariant C1).",
        "Furnish three artifacts: the installed archive (" + ESTATE_ARCHIVE_NAME + "), the "
        "published approved-resource manifest (" + ESTATE_APPROVED_NAME + ") that nameth its "
        "bytes, and the signed archive manifest (" + ESTATE_SIGNED_NAME + "). The trust store is "
        "selected by the operator and is never read from the estate's own document.",
        "Verify the estate before trusting it: python3 scripts/upgrade_recovery.py verify "
        "--estate <estate> --trust-store <store>.",
        "The only rollback target is the RETENTION.json record written by "
        "scripts/prepare_release_assets.py BEFORE either file of the previous pair was replaced. "
        "Roll back with: python3 scripts/upgrade_recovery.py rollback --estate <estate> "
        "--retained <retention-dir> --work <work> --trust-store <store>. A rollback is refused "
        "when the retained archive's schema is not one this build may run.",
        "Resume an interrupted update instead of guessing: python3 scripts/upgrade_recovery.py "
        "resume --estate <estate> --work <work> --case <case-id> --trust-store <store>. An "
        "interruption in any transition leaveth the published manifest naming bytes that are "
        "present -- the previous estate whole, or the candidate estate whole.",
        "A wipe is journaled and terminal. Resume it with: python3 scripts/upgrade_recovery.py "
        "wipe --estate <estate> --work <work> --case <case-id>.",
        "A partial estate (one file present without its pair) is REFUSED by name. It is a wipe in "
        "progress or a broken estate; it is never read as empty, and it is never recreated empty.",
        "An unknown FUTURE schema is refused by name and the estate is preserved byte for byte. "
        "An unsupported DOWNGRADE is refused before any write. Neither is ever auto-detected.",
        "Installation on a device is NOT established by any of the above. The device claim is " +
        DEVICE_CLAIM + ".",
    )


def _development_world(work: Path) -> dict[str, Any]:
    """A harmless, visibly labelled rehearsal world. NOT an approval.

    Each archive is a development fixture carrying only app-navigation prose
    (the same documents ci/archive_fixture.py buildeth, under a variant label
    that maketh the variants DISTINCT bytes), the key is TEST-ONLY and
    generated here, and the candidate carrieth no production review
    provenance -- so the RELEASE asset gate would refuse it, which is exactly
    why the rehearsal face is labelled development-fixture.

    The "prior" archive declareth a schema version BELOW the shipped one over
    the current DDL: it is a SYNTHETIC prior-version label whose only purpose
    is to exercise the UPGRADE/undeclared-migration branches of the matrix.
    It is not a claim that such an archive ever shipped, and no production
    migration is declared (see SHIPPED_MATRIX).
    """
    from ci import archive_fixture

    work = Path(work)
    work.mkdir(parents=True, exist_ok=True)
    documents = work / "documents"
    trust_store = work / "trust-store.json"
    private_key = work / "test-only-private.key"
    if not (trust_store.is_file() and private_key.is_file()):
        generate_test_keypair(private_key, trust_store, key_id="TEST-ONLY-T77")
    archives: dict[str, Path] = {}
    manifests: dict[str, Path] = {}
    # Each variant liveth in its OWN directory under the canonical archive
    # name: a signed manifest nameth its archive's filename, and an estate
    # holdeth the one canonical name, so a variant that were built elsewhere
    # could never be verified where it will be installed.
    for variant, schema in (("prior", 2), ("installed", 3), ("candidate", 3), ("future", 4)):
        directory = documents / variant
        directory.mkdir(parents=True, exist_ok=True)
        archive = directory / ESTATE_ARCHIVE_NAME
        archive_fixture.build(archive, variant=variant, schema_version=schema)
        manifest = directory / "signed-archive-manifest.json"
        create_manifest(archive, manifest, tier=ESTATE_TIER, archive_schema=schema,
                        source_manifest_sha256="0" * 64, review_manifest_sha256="0" * 64,
                        corpus_manifest_sha256="0" * 64, build_tool_commit="development-fixture",
                        private_key=load_private_key(private_key), key_id="TEST-ONLY-T77")
        archives[variant] = archive
        manifests[variant] = manifest
    estate = work / "estate"
    _write_development_estate(estate, archives["installed"], manifests["installed"])
    return {"work": work, "trust_store": trust_store, "archives": archives,
            "manifests": manifests, "estate": estate}


def _write_development_estate(estate: Path, archive: Path, manifest: Path,
                              record_dir: Path | None = None) -> None:
    """(Re)build the installed estate from one fixture variant, whole.

    It is rebuilt rather than patched, so no case can ever be credited with a
    world another case left behind -- and the published manifest is written
    LAST, so an estate that carrieth a manifest carrieth its bytes.
    """
    estate = Path(estate)
    estate.mkdir(parents=True, exist_ok=True)
    record_dir = Path(record_dir) if record_dir is not None else estate_record_dir(estate)
    record_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(archive, estate / ESTATE_ARCHIVE_NAME)
    shutil.copyfile(manifest, record_dir / ESTATE_SIGNED_NAME)
    _write_json_atomic(estate / ESTATE_APPROVED_NAME, {
        "schema": staging.APPROVED_MANIFEST_SCHEMA,
        "tier": ESTATE_TIER,
        "application_id": "io.godstone.app",
        "generated_by": "scripts/upgrade_recovery.py (DEVELOPMENT REHEARSAL -- NOT AN APPROVAL)",
        "assets": [{
            "role": "archive",
            "name": ESTATE_ARCHIVE_NAME,
            "sha256": staging.sha256(Path(archive)),
            "bytes": Path(archive).stat().st_size,
            "build_phase": "resources",
        }],
    })


# The rehearsal matrix: what a build WOULD declare once a fixture-based
# migration from a supported earlier version existed (docs/production/
# MIGRATION.md requireth exactly that). It is the court's declaration, not the
# shipped one, and the shipped matrix above declareth no migration at all.
REHEARSAL_MATRIX = RollbackCompatibilityMatrix(
    accepted_schema=ACCEPTED_ARCHIVE_SCHEMA,
    supported_installed=(2, ACCEPTED_ARCHIVE_SCHEMA),
    migrations=((2, ACCEPTED_ARCHIVE_SCHEMA),),
)

REHEARSAL_CASES = (
    UpgradeCase("content-replacement", APPLIED, installed_schema=3, candidate_schema=3,
                description="schema 3 -> schema 3: the content is replaced and the previous estate is retained"),
    UpgradeCase("schema-migration", APPLIED, installed_schema=2, candidate_schema=3,
                installed_variant="prior", candidate_variant="installed",
                description="a DECLARED migration from a supported earlier schema is applied (rehearsal matrix)"),
    UpgradeCase("undeclared-migration-refused", REFUSED, installed_schema=2, candidate_schema=3,
                installed_variant="prior", candidate_variant="installed",
                refusal_fragment="no declared migration from installed schema 2",
                description="the same migration without its declaration is refused by name"),
    UpgradeCase("downgrade-refused", REFUSED, installed_schema=3, candidate_schema=2,
                candidate_variant="prior", refusal_fragment="unsupported archive schema 2 refused",
                description="an older candidate schema is an unsupported downgrade: refused by name"),
    UpgradeCase("future-schema-refused", REFUSED, installed_schema=3, candidate_schema=4,
                candidate_variant="future", refusal_fragment="unknown future schema 4 refused",
                description="an unknown future schema is refused by name; the estate is never recreated empty"),
    UpgradeCase("interrupted-update", INTERRUPTED, installed_schema=3, candidate_schema=3,
                interruption="after_archive_replace",
                description="an interruption after the archive was placed: the previous estate is restored whole"),
    UpgradeCase("interrupted-staging", INTERRUPTED, installed_schema=3, candidate_schema=3,
                interruption="retained",
                description="an interruption mid-staging leaveth the previous estate standing"),
    UpgradeCase("disk-full", INTERRUPTED, installed_schema=3, candidate_schema=3,
                disk_fault="after_archive_replace", refusal_fragment="the disk was full",
                description="a full disk during the placement: the transaction does not complete, "
                            "the failure is named, and the previous estate is restored whole"),
    UpgradeCase("disk-full-before-placement", INTERRUPTED, installed_schema=3, candidate_schema=3,
                disk_fault="before_archive_replace", refusal_fragment="the disk was full",
                description="a full disk before anything was placed: the previous estate never moved"),
)


def _rehearse_declared(work: Path, *, report: Path | None = None) -> tuple[int, list[dict[str, Any]]]:
    """Run the declared ladder against development fixtures, plus the three
    proofs a single case cannot carry: the rollback, the wipe, and the
    offline refusal. Every row sayeth whether the observation AGREED with the
    declaration; the door falleth when any row disagreeth."""
    world = _development_world(work)
    trust_store = world["trust_store"]
    estate = world["estate"]
    operations = world["work"] / "work"
    frozen = lambda: "1970-01-01T00:00:00+00:00"  # noqa: E731
    rows: list[dict[str, Any]] = []

    def observe(case: UpgradeCase, matrix: RollbackCompatibilityMatrix, call) -> None:
        _write_development_estate(estate, world["archives"][case.installed_variant],
                                  world["manifests"][case.installed_variant])
        row: dict[str, Any] = {"case": case.to_json(), "matrix": matrix.to_json()}
        try:
            result = call()
        except RecoveryError as exc:
            row.update({"verdict": "RAISED", "reason": str(exc), "agreed": False})
            rows.append(row)
            print(f"  RAISED   {case.case_id}: {exc}")
            return
        agreed = result.outcome == case.expectation
        if case.refusal_fragment is not None:
            agreed = agreed and any(case.refusal_fragment in item for item in result.refusals)
        if case.expectation != APPLIED:
            agreed = agreed and result.preserved
        row.update({"result": result.to_json(), "agreed": bool(agreed)})
        rows.append(row)
        print(f"  {'AGREED ' if agreed else 'DISAGREED'} {case.case_id}: {result.outcome} "
              f"(preserved={result.preserved})")

    def rehearse_case(case: UpgradeCase, matrix: RollbackCompatibilityMatrix):
        return rehearse(case, estate=estate,
                        candidate=CandidateSource(archive=world["archives"][case.candidate_variant],
                                                  signed_manifest=world["manifests"][case.candidate_variant]),
                        trust_store=trust_store, work_root=operations / case.case_id,
                        matrix=matrix, clock=frozen)

    for case in REHEARSAL_CASES:
        matrix = REHEARSAL_MATRIX if case.case_id == "schema-migration" else SHIPPED_MATRIX
        observe(case, matrix, lambda case=case, matrix=matrix: rehearse_case(case, matrix))

    # the previous content retained correctly: after a real replacement, the
    # rollback returneth the previous authoritative bytes exactly.
    case = UpgradeCase("rollback-after-upgrade", RECOVERED)
    _write_development_estate(estate, world["archives"]["installed"],
                              world["manifests"]["installed"])
    before = open_estate(estate, trust_store)
    row = {"case": case.to_json(), "matrix": SHIPPED_MATRIX.to_json()}
    try:
        applied = rehearse(UpgradeCase("rollback-after-upgrade", APPLIED), estate=estate,
                           candidate=CandidateSource(archive=world["archives"]["candidate"],
                                                     signed_manifest=world["manifests"]["candidate"]),
                           trust_store=trust_store, work_root=operations / "rollback-after-upgrade",
                           clock=frozen)
        rolled = rollback(estate=estate, retained=Path(applied.retained_path or estate),
                          trust_store=trust_store, work_root=operations / "rollback-after-upgrade",
                          case_id="rollback-after-upgrade", clock=frozen)
        restored = open_estate(estate, trust_store)
        agreed = (applied.outcome == APPLIED and rolled.outcome == RECOVERED and
                  restored.archive_sha256 == before.archive_sha256 and
                  restored.same_bytes_as(before))
        row.update({"applied": applied.to_json(), "result": rolled.to_json(),
                    "restored_archive_sha256": restored.archive_sha256,
                    "agreed": bool(agreed)})
    except RecoveryError as exc:
        row.update({"verdict": "RAISED", "reason": str(exc), "agreed": False})
    rows.append(row)
    print(f"  {'AGREED ' if row['agreed'] else 'DISAGREED'} rollback-after-upgrade: "
          f"{row.get('result', {}).get('outcome', row.get('verdict'))}")

    # a wipe in progress, and its resumption to the terminal state
    case = UpgradeCase("wipe-in-progress", WIPED)
    row = {"case": case.to_json(), "matrix": SHIPPED_MATRIX.to_json()}
    try:
        interrupted = False
        try:
            wipe(estate=estate, work_root=operations / "wipe-in-progress",
                 case_id="wipe-in-progress", interruption=WIPE_ARCHIVE_UNLINKED, clock=frozen)
        except RecoveryInterrupted:
            interrupted = True
        mid_wipe_refused = False
        try:
            open_estate(estate, trust_store)
        except RecoveryError as exc:
            mid_wipe_refused = "incomplete" in str(exc)
        done = resume(estate=estate, trust_store=trust_store,
                      work_root=operations / "wipe-in-progress",
                      case_id="wipe-in-progress", clock=frozen)
        fresh = open_estate(estate, trust_store).present is False
        agreed = interrupted and mid_wipe_refused and done.outcome == WIPED and fresh
        row.update({"interrupted": interrupted, "mid_wipe_refused_as_partial": mid_wipe_refused,
                    "result": done.to_json(), "agreed": bool(agreed)})
    except RecoveryError as exc:
        row.update({"verdict": "RAISED", "reason": str(exc), "agreed": False})
    rows.append(row)
    print(f"  {'AGREED ' if row['agreed'] else 'DISAGREED'} wipe-in-progress: "
          f"{row.get('result', {}).get('outcome', row.get('verdict'))}")

    # offline: a missing trust store is refused BY NAME before any write
    case = UpgradeCase("offline-trust-store-required", REFUSED)
    _write_development_estate(estate, world["archives"]["installed"],
                              world["manifests"]["installed"])
    before = open_estate(estate, trust_store)
    row = {"case": case.to_json(), "matrix": SHIPPED_MATRIX.to_json()}
    absent = world["work"] / "no-such-trust-store.json"
    try:
        rehearse(case, estate=estate,
                 candidate=CandidateSource(archive=world["archives"]["candidate"],
                                           signed_manifest=world["manifests"]["candidate"]),
                 trust_store=absent, work_root=operations / "offline", clock=frozen)
        row.update({"agreed": False, "reason": "a missing trust store was not refused"})
    except RecoveryError as exc:
        agreed = ("trust store is required" in str(exc) and
                  open_estate(estate, trust_store).same_bytes_as(before))
        row.update({"refusal": str(exc), "agreed": bool(agreed)})
    rows.append(row)
    print(f"  {'AGREED ' if row['agreed'] else 'DISAGREED'} offline-trust-store-required")

    failures = sum(1 for row in rows if not row.get("agreed"))
    document = {"schema": 1, "kind": "recovery-rehearsal",
                "rehearsal": "development fixtures only -- NOT an approval, NOT a device result",
                "device_claim": DEVICE_CLAIM,
                "cases_agreed": len(rows) - failures, "cases_declared": len(rows),
                "cases": rows}
    if report is not None:
        _write_json_atomic(Path(report), document)
    return (1 if failures else 0), rows


def selftest() -> int:
    """The door's own proof: a control that never fired is not a control."""
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="godstone-t77-selftest-") as temporary:
        work = Path(temporary)
        world = _development_world(work)
        trust_store = world["trust_store"]
        estate = world["estate"]
        clock = lambda: "1970-01-01T00:00:00+00:00"  # noqa: E731

        def check(label: str, condition: bool, detail: str = "") -> None:
            if not condition:
                failures.append(label + (": " + detail if detail else ""))

        # 1. the matrix refuseth the future and the downgrade BY NAME
        _, future = SHIPPED_MATRIX.classify(3, 4)
        check("the future schema is refused by name", bool(future) and "future schema 4" in future)
        _, older = SHIPPED_MATRIX.classify(3, 2)
        check("the unsupported downgrade is refused by name", bool(older) and "unsupported archive schema 2" in older)
        _, undeclared = SHIPPED_MATRIX.classify(2, 3)
        check("an undeclared migration is refused by name", bool(undeclared) and "no declared migration" in undeclared)
        check("a replacement is lawful", SHIPPED_MATRIX.classify(3, 3) == (REPLACE, None))
        check("a fresh install is lawful", SHIPPED_MATRIX.classify(None, 3) == (INSTALL, None))

        before = open_estate(estate, trust_store)
        check("the development estate openeth", before.present and before.schema == 3)

        # 2. a refusal leaveth the estate byte-identical
        case = UpgradeCase("selftest-downgrade", REFUSED)
        result = rehearse(case, estate=estate,
                          candidate=CandidateSource(archive=world["archives"]["prior"],
                                                    signed_manifest=world["manifests"]["prior"]),
                          trust_store=trust_store, work_root=work / "w1", clock=clock)
        check("the downgrade is refused", result.outcome == REFUSED, str(result.refusals))
        check("the estate is preserved by the refusal",
              open_estate(estate, trust_store).same_bytes_as(before))

        # 3. an unknown future schema is refused and NEVER recreated empty
        case = UpgradeCase("selftest-future", REFUSED)
        result = rehearse(case, estate=estate,
                          candidate=CandidateSource(archive=world["archives"]["future"],
                                                    signed_manifest=world["manifests"]["future"]),
                          trust_store=trust_store, work_root=work / "w2", clock=clock)
        check("the future schema is refused in the transaction", result.outcome == REFUSED,
              str(result.refusals))
        after = open_estate(estate, trust_store)
        check("the future schema did not empty the estate", after.present)
        check("the estate is byte-identical after the future-schema refusal", after.same_bytes_as(before))

        # 4. a partial estate is refused BY NAME and never read as empty
        # a PARTIAL estate: one file of the pair present without the other.
        broken = work / "broken-estate"
        broken.mkdir()
        shutil.copyfile(estate / ESTATE_APPROVED_NAME, broken / ESTATE_APPROVED_NAME)
        try:
            open_estate(broken, trust_store)
            check("a partial estate is refused", False, "it was opened")
        except RecoveryError as exc:
            check("a partial estate is refused by name", "incomplete" in str(exc), str(exc))

        # 5. the transaction replaceth AND retaineth
        case = UpgradeCase("selftest-replace", APPLIED)
        result = rehearse(case, estate=estate,
                          candidate=CandidateSource(archive=world["archives"]["candidate"],
                                                    signed_manifest=world["manifests"]["candidate"]),
                          trust_store=trust_store, work_root=work / "w3", clock=clock)
        check("the replacement is applied", result.outcome == APPLIED, str(result.refusals))
        check("the replacement actually changed the installed bytes",
              result.old_archive_sha256 != result.new_archive_sha256)
        check("the retention record standeth", result.retained_path is not None and
              (Path(result.retained_path) / staging.RETENTION_RECORD_NAME).is_file())
        check("a rollback is permitted", result.rollback_permitted, str(result.rollback_refusal))
        check("the published manifest nameth the bytes that are present",
              open_estate(estate, trust_store).archive_sha256 == result.new_archive_sha256)

        # 6. a rollback returneth to the retained estate exactly
        rolled = rollback(estate=estate, retained=Path(result.retained_path), trust_store=trust_store,
                          work_root=work / "w3b", case_id="selftest-rollback", clock=clock)
        check("the rollback is recovered", rolled.outcome == RECOVERED, str(rolled.refusals))
        check("the rollback restored the previous authoritative bytes",
              open_estate(estate, trust_store).archive_sha256 == before.archive_sha256)

        # 7a. a REHEARSED interruption: the harness mends it inline, and the
        #     estate that standeth afterwards is the previous one, whole.
        case = UpgradeCase("selftest-interrupt", INTERRUPTED, interruption="after_archive_replace")
        result = rehearse(case, estate=estate,
                          candidate=CandidateSource(archive=world["archives"]["candidate"],
                                                    signed_manifest=world["manifests"]["candidate"]),
                          trust_store=trust_store, work_root=work / "w4", clock=clock)
        check("the interruption is reported", result.outcome == INTERRUPTED, result.outcome)
        check("the interrupted estate is the previous one, whole",
              open_estate(estate, trust_store).archive_sha256 == before.archive_sha256)
        resumed = resume(estate=estate, trust_store=trust_store, work_root=work / "w4",
                        case_id="selftest-interrupt", clock=clock)
        check("the resumed run reporteth its recorded terminal state",
              resumed.outcome == REFUSED, resumed.outcome)

        # 7b. a real CRASH: the process dieth at the boundary, nothing mends
        #     the estate, and the resumer must reach a terminal state from the
        #     record alone.
        case = UpgradeCase("selftest-crash", RECOVERED, interruption="after_archive_replace")
        try:
            rehearse(case, estate=estate,
                     candidate=CandidateSource(archive=world["archives"]["candidate"],
                                               signed_manifest=world["manifests"]["candidate"]),
                     trust_store=trust_store, work_root=work / "w6", clock=clock,
                     settle_on_fault=False)
            check("the crash fired", False, "it did not fire")
        except RecoveryInterrupted:
            pass
        try:
            open_estate(estate, trust_store)
            check("a mid-update estate is refused by name", False, "it was opened")
        except RecoveryError as exc:
            check("a mid-update estate is refused as inconsistent, never as empty",
                  "nameth bytes that are not present" in str(exc), str(exc))
        crashed = resume(estate=estate, trust_store=trust_store, work_root=work / "w6",
                        case_id="selftest-crash", clock=clock)
        check("the crash resumeth to a terminal state", crashed.outcome == RECOVERED, crashed.outcome)
        check("the resumed estate is the previous one, whole",
              open_estate(estate, trust_store).same_bytes_as(before))

        # 8. a wipe in progress is refused as such, and resumeth to WIPED
        wiped_estate = work / "wipe-estate"
        shutil.copytree(estate, wiped_estate)
        shutil.copytree(estate_record_dir(estate), estate_record_dir(wiped_estate))
        try:
            wipe(estate=wiped_estate, work_root=work / "w5", case_id="selftest-wipe",
                 interruption=WIPE_ARCHIVE_UNLINKED, clock=clock)
            check("the wipe interruption fired", False, "it did not fire")
        except RecoveryInterrupted:
            pass
        try:
            open_estate(wiped_estate, trust_store)
            check("a mid-wipe estate is refused", False, "it was opened")
        except RecoveryError as exc:
            check("a mid-wipe estate is refused as partial, not as empty",
                  "incomplete" in str(exc), str(exc))
        done = resume(estate=wiped_estate, trust_store=trust_store, work_root=work / "w5",
                     case_id="selftest-wipe", clock=clock)
        check("the wipe resumeth to WIPED", done.outcome == WIPED, done.outcome)
        check("the wiped estate openeth as a fresh install",
              open_estate(wiped_estate, trust_store).present is False)

        # 9. the instructions name the artifacts and are offline
        text = " ".join(recovery_instructions())
        for needle in (ESTATE_ARCHIVE_NAME, ESTATE_APPROVED_NAME, ESTATE_SIGNED_NAME,
                       "OFFLINE", "RETENTION.json"):
            check("the instructions name " + needle, needle in text)

    if failures:
        print("T77 RECOVERY SELFTEST: FAILED")
        for item in failures:
            print("  - " + item)
        return 1
    print("T77 RECOVERY SELFTEST: PASS (the matrix, the partial estate, the future schema, "
          "the transaction, the retention, the interruption, the wipe and the instructions)")
    return 0


def _repository_root() -> Path:
    """The source tree this script liveth in (its own checkout, not the caller's cwd)."""
    return Path(__file__).resolve().parents[1]


def _refuse_report_inside_the_tree(report: Path, *, override: bool = False) -> str:
    """The output contract: a run artifact belongeth OUTSIDE the source tree.

    Returneth '' when the path is acceptable, else the refusal reason. A path that
    resolveth INSIDE the repository (including a bare relative name, which the audited
    workflow used) is refused BY NAME: it would leave untracked residue, dirty the tree
    and fail the provenance check that followeth. The caller may place its outputs in
    RUNNER_TEMP or any other directory outside the checkout.
    """
    if override:
        return ''
    root = _repository_root()
    resolved = (Path.cwd() / report).resolve() if not report.is_absolute() else report.resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        return ''
    return (f"the report path {str(report)!r} resolveth INSIDE the source tree "
            f"({resolved}); a run artifact must be written OUTSIDE the checkout -- use "
            f"RUNNER_TEMP (or any external directory) so the tree stayeth clean for the "
            f"provenance check that followeth. Pass --allow-in-tree-report only for a "
            f"local debugging run, never in CI.")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    # --selftest is the form every other repository door speaketh; the
    # `selftest` subcommand is its twin, and neither is a substitute for the
    # other's evidence.
    parser.add_argument("--selftest", action="store_true",
                        help="prove the door itself (twin of the selftest subcommand)")
    sub = parser.add_subparsers(dest="command", required=False)
    p_self = sub.add_parser("selftest", help="prove the door itself")
    p_verify = sub.add_parser("verify", help="open an installed estate, or refuse it by name")
    p_verify.add_argument("--estate", type=Path, required=True)
    p_verify.add_argument("--trust-store", type=Path, required=True)
    p_rehearse = sub.add_parser("rehearse", help="run the declared rehearsal against development fixtures")
    p_rehearse.add_argument("--work", type=Path, required=True)
    p_rehearse.add_argument("--report", type=Path, default=None)
    p_rehearse.add_argument("--allow-in-tree-report", action="store_true",
                            help="LOCAL DEBUGGING ONLY: permit a report inside the tree")
    p_resume = sub.add_parser("resume", help="resume an interrupted operation from its journal")
    p_resume.add_argument("--estate", type=Path, required=True)
    p_resume.add_argument("--work", type=Path, required=True)
    p_resume.add_argument("--case", dest="case_id", required=True)
    p_resume.add_argument("--trust-store", type=Path, required=True)
    p_wipe = sub.add_parser("wipe", help="wipe an estate, journaled and resumable")
    p_wipe.add_argument("--estate", type=Path, required=True)
    p_wipe.add_argument("--work", type=Path, required=True)
    p_wipe.add_argument("--case", dest="case_id", default="wipe")
    p_roll = sub.add_parser("rollback", help="return to the retained estate")
    p_roll.add_argument("--estate", type=Path, required=True)
    p_roll.add_argument("--retained", type=Path, required=True)
    p_roll.add_argument("--work", type=Path, required=True)
    p_roll.add_argument("--trust-store", type=Path, required=True)
    p_roll.add_argument("--case", dest="case_id", default="rollback")
    args = parser.parse_args(argv)
    try:
        if args.command is None:
            if args.selftest:
                return selftest()
            parser.error("a command is required (or --selftest)")
        if args.command == "selftest":
            return selftest()
        if args.command == "verify":
            estate = open_estate(args.estate, args.trust_store)
            print(json.dumps({"estate": estate.to_json(), "device_claim": DEVICE_CLAIM},
                             sort_keys=True, indent=2))
            return 0
        if args.command == "rehearse":
            if args.report is not None:
                refusal = _refuse_report_inside_the_tree(
                    args.report, override=args.allow_in_tree_report)
                if refusal:
                    print(f"REFUSED: {refusal}", file=sys.stderr)
                    return 2
            code, rows = _rehearse_declared(args.work, report=args.report)
            agreed = sum(1 for row in rows if row.get("agreed"))
            print(f"T77 RECOVERY REHEARSAL: {agreed} of {len(rows)} declared cases agreed "
                  f"(development fixtures; no gate is closed; {DEVICE_CLAIM})")
            return code
        if args.command == "resume":
            result = resume(estate=args.estate, trust_store=args.trust_store, work_root=args.work,
                            case_id=args.case_id)
            print(json.dumps(result.to_json(), sort_keys=True, indent=2))
            return 0 if result.outcome != REFUSED else 1
        if args.command == "wipe":
            result = wipe(estate=args.estate, work_root=args.work, case_id=args.case_id)
            print(json.dumps(result.to_json(), sort_keys=True, indent=2))
            return 0
        if args.command == "rollback":
            result = rollback(estate=args.estate, retained=args.retained, work_root=args.work,
                              trust_store=args.trust_store, case_id=args.case_id)
            print(json.dumps(result.to_json(), sort_keys=True, indent=2))
            return 0 if result.outcome == RECOVERED else 1
    except RecoveryError as exc:
        print(str(exc))
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
