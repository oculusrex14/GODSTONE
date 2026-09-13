#!/usr/bin/env python3
"""Fail-closed production content manifest validation for GODSTONE.

Development fixtures may exist without approval, but a release archive must call
``validate_release_corpus`` before any output database is created. The validator
is deliberately local-only: it verifies immutable files and hashes already in
the repository and never attempts to fetch evidence from the network.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from base64 import b64decode, b64encode
from dataclasses import dataclass, replace
from datetime import date
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

import yaml
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey, Ed25519PublicKey)
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from content.archive_manifest import (
    ArchiveManifestError, strict_json_loads)

SCHEMA_VERSION = 1
_PLACEHOLDER = re.compile(
    r"(?:^|[\s_\-])(example|placeholder|sample|tbd|todo|unknown|unreviewed|dummy|test-only|n/?a)(?:$|[\s_\-])",
    re.IGNORECASE,
)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_ALLOWED_STATUS = {"approved"}


class ReleaseGateError(RuntimeError):
    """Raised when any release content requirement is unproven."""


@dataclass(frozen=True)
class ValidatedDocument:
    document_id: str
    manifest_path: Path
    source_path: Path
    manifest_sha256: str
    source_sha256: str
    rights_evidence_sha256: str
    review_evidence_sha256: str
    chunk_approval_sha256: str


@dataclass(frozen=True)
class CorpusValidation:
    documents: tuple[ValidatedDocument, ...]
    manifest_set_sha256: str
    source_set_sha256: str
    review_set_sha256: str


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _require_mapping(value: Any, field: str, errors: list[str]) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        errors.append(f"{field} must be a mapping")
        return {}
    return value


def _require_text(mapping: Mapping[str, Any], key: str, field: str, errors: list[str]) -> str:
    value = mapping.get(key)
    text = str(value).strip() if value is not None else ""
    if not text:
        errors.append(f"{field}.{key} missing")
    elif _PLACEHOLDER.search(text) or text.lower() in {"none", "null", "-"}:
        errors.append(f"{field}.{key} is a placeholder")
    return text


def _require_bool(mapping: Mapping[str, Any], key: str, expected: bool, field: str, errors: list[str]) -> None:
    if mapping.get(key) is not expected:
        errors.append(f"{field}.{key} must be {str(expected).lower()}")


def _parse_date(value: str, field: str, errors: list[str]) -> date | None:
    if not value:
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        errors.append(f"{field} must use YYYY-MM-DD")
        return None


def _resolve_evidence(
    root: Path,
    mapping: Mapping[str, Any],
    file_key: str,
    hash_key: str,
    field: str,
    errors: list[str],
) -> tuple[Path | None, str]:
    rel = _require_text(mapping, file_key, field, errors)
    expected = _require_text(mapping, hash_key, field, errors).lower()
    if expected and not _SHA256.fullmatch(expected):
        errors.append(f"{field}.{hash_key} must be a lowercase SHA-256")
    if not rel:
        return None, ""
    candidate = (root / rel).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError:
        errors.append(f"{field}.{file_key} escapes the evidence root")
        return None, ""
    if not candidate.is_file():
        errors.append(f"{field}.{file_key} does not exist: {rel}")
        return candidate, ""
    actual = sha256_file(candidate)
    if expected and actual != expected:
        errors.append(f"{field}.{hash_key} mismatch")
    return candidate, actual


def validate_document_manifest(
    manifest_path: Path,
    source_path: Path,
    *,
    evidence_root: Path,
    today: date | None = None,
) -> ValidatedDocument:
    """Validate one source, rights packet, review packet, and chunk approval.

    The function checks the bytes referenced by the manifest. A non-empty name,
    URL, or reviewer role is not treated as evidence by itself.
    """
    today = today or date.today()
    errors: list[str] = []
    try:
        text = manifest_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ReleaseGateError(f"{manifest_path}: unreadable manifest: {exc}") from exc
    record = yaml_load_strict(text, str(manifest_path)) or {}
    if not isinstance(record, Mapping):
        raise ReleaseGateError(f"{manifest_path}: manifest root must be a mapping")

    if record.get("schema") != SCHEMA_VERSION:
        errors.append(f"schema must be {SCHEMA_VERSION}")
    document_id = _require_text(record, "id", "document", errors)
    if record.get("status") not in _ALLOWED_STATUS:
        errors.append("status must be approved")
    if record.get("example") is not False:
        errors.append("example must be false")

    source = _require_mapping(record.get("source"), "source", errors)
    for key in (
        "title", "publisher", "edition", "version", "source_date",
        "acquisition_date", "canonical_url", "source_sha256",
    ):
        _require_text(source, key, "source", errors)
    expected_source = str(source.get("source_sha256", "")).strip().lower()
    if expected_source and not _SHA256.fullmatch(expected_source):
        errors.append("source.source_sha256 must be a lowercase SHA-256")
    if not source_path.is_file():
        errors.append(f"source file missing: {source_path}")
        actual_source = ""
    else:
        actual_source = sha256_file(source_path)
        if expected_source and actual_source != expected_source:
            errors.append("source.source_sha256 mismatch")
    source_date = _parse_date(str(source.get("source_date", "")), "source.source_date", errors)
    acquired = _parse_date(str(source.get("acquisition_date", "")), "source.acquisition_date", errors)
    if source_date and source_date > today:
        errors.append("source.source_date is in the future")
    if acquired and acquired > today:
        errors.append("source.acquisition_date is in the future")

    rights = _require_mapping(record.get("rights"), "rights", errors)
    _require_text(rights, "licence", "rights", errors)
    _require_text(rights, "attribution", "rights", errors)
    _require_bool(rights, "redistribution_permitted", True, "rights", errors)
    _require_bool(rights, "derivative_work_permitted", True, "rights", errors)
    _, rights_hash = _resolve_evidence(
        evidence_root, rights, "evidence_file", "evidence_sha256", "rights", errors
    )

    review = _require_mapping(record.get("review"), "review", errors)
    for key in (
        "reviewer_id", "reviewer_role", "reviewer_qualifications",
        "reviewer_identity_evidence", "reviewed_on", "review_scope",
        "expires_on", "approval_signature",
    ):
        _require_text(review, key, "review", errors)
    reviewed_on = _parse_date(str(review.get("reviewed_on", "")), "review.reviewed_on", errors)
    expires_on = _parse_date(str(review.get("expires_on", "")), "review.expires_on", errors)
    if reviewed_on and reviewed_on > today:
        errors.append("review.reviewed_on is in the future")
    if expires_on and expires_on < today:
        errors.append("review has expired")
    if reviewed_on and expires_on and expires_on <= reviewed_on:
        errors.append("review.expires_on must be after review.reviewed_on")
    _, review_hash = _resolve_evidence(
        evidence_root, review, "approval_evidence_file", "approval_evidence_sha256", "review", errors
    )

    safety = _require_mapping(record.get("safety"), "safety", errors)
    _require_bool(safety, "chunk_boundary_approved", True, "safety", errors)
    _require_text(safety, "jurisdiction", "safety", errors)
    _require_text(safety, "replacement_policy", "safety", errors)
    warnings_required = safety.get("warnings_required") is True
    contraindications_required = safety.get("contraindications_required") is True
    if safety.get("warnings_required") not in {True, False}:
        errors.append("safety.warnings_required must be boolean")
    if safety.get("contraindications_required") not in {True, False}:
        errors.append("safety.contraindications_required must be boolean")
    warning_sections = safety.get("warning_sections")
    contraindication_sections = safety.get("contraindication_sections")
    if warnings_required and (not isinstance(warning_sections, Sequence) or isinstance(warning_sections, str) or not warning_sections):
        errors.append("safety.warning_sections required and non-empty")
    if contraindications_required and (
        not isinstance(contraindication_sections, Sequence)
        or isinstance(contraindication_sections, str)
        or not contraindication_sections
    ):
        errors.append("safety.contraindication_sections required and non-empty")
    _, chunk_hash = _resolve_evidence(
        evidence_root,
        safety,
        "chunk_approval_evidence_file",
        "chunk_approval_evidence_sha256",
        "safety",
        errors,
    )

    if errors:
        raise ReleaseGateError(f"{manifest_path}: " + "; ".join(errors))

    return ValidatedDocument(
        document_id=document_id,
        manifest_path=manifest_path,
        source_path=source_path,
        manifest_sha256=sha256_file(manifest_path),
        source_sha256=actual_source,
        rights_evidence_sha256=rights_hash,
        review_evidence_sha256=review_hash,
        chunk_approval_sha256=chunk_hash,
    )


def _set_digest(values: Iterable[str]) -> str:
    h = hashlib.sha256()
    for value in sorted(values):
        h.update(value.encode("ascii"))
        h.update(b"\n")
    return h.hexdigest()


def validate_release_corpus(
    documents: Iterable[Any],
    manifests_dir: Path,
    *,
    evidence_root: Path | None = None,
    today: date | None = None,
) -> CorpusValidation:
    """Validate every document selected for a release archive.

    ``documents`` may be the builder's Document objects or dictionaries. Each
    item must expose ``source_id`` and ``path``; release reading level is also
    checked when present. Missing or extra approved manifests are rejected.
    """
    manifests_dir = manifests_dir.resolve()
    evidence_root = (evidence_root or manifests_dir.parent).resolve()
    validated: list[ValidatedDocument] = []
    seen: set[str] = set()
    errors: list[str] = []

    docs = list(documents)
    for doc in docs:
        source_id = str(getattr(doc, "source_id", doc.get("source_id") if isinstance(doc, Mapping) else "")).strip()
        source_path_value = getattr(doc, "path", doc.get("path") if isinstance(doc, Mapping) else None)
        if not source_id or source_path_value is None:
            errors.append("document is missing source_id/path")
            continue
        if source_id in seen:
            errors.append(f"duplicate source_id: {source_id}")
            continue
        seen.add(source_id)
        if not re.fullmatch(r"[A-Za-z0-9._-]+", source_id):
            errors.append(f"unsafe source_id: {source_id}")
            continue
        reading_level = getattr(doc, "reading_level", doc.get("reading_level") if isinstance(doc, Mapping) else None)
        if reading_level is not None and int(reading_level) > 9:
            errors.append(f"{source_id}: reading level {reading_level} exceeds release maximum 9")
        manifest = manifests_dir / f"{source_id}.yaml"
        try:
            validated.append(
                validate_document_manifest(
                    manifest,
                    Path(source_path_value),
                    evidence_root=evidence_root,
                    today=today,
                )
            )
        except ReleaseGateError as exc:
            errors.append(str(exc))

    approved_files = set(manifests_dir.glob("*.yaml")) if manifests_dir.exists() else set()
    expected_files = {manifests_dir / f"{source_id}.yaml" for source_id in seen}
    extras = sorted(path.name for path in approved_files - expected_files)
    if extras:
        errors.append("approved manifest(s) not selected into the archive: " + ", ".join(extras))
    if not validated:
        errors.append("release corpus contains no validated documents")
    if errors:
        raise ReleaseGateError("release corpus rejected:\n- " + "\n- ".join(errors))

    return CorpusValidation(
        documents=tuple(validated),
        manifest_set_sha256=_set_digest(item.manifest_sha256 for item in validated),
        source_set_sha256=_set_digest(item.source_sha256 for item in validated),
        review_set_sha256=_set_digest(
            item.rights_evidence_sha256 + item.review_evidence_sha256 + item.chunk_approval_sha256
            for item in validated
        ),
    )


# ---------------------------------------------------------------------------
# Final chunk approvals (T46). An approval is worth nothing unless it is
# bound to the exact bytes that ship, signed by a key the operator -- not
# the bundle -- nominated, and fresh when it is read. A nonempty
# approval_signature proves the ink is dry, nothing more; the leg below
# verifies detached Ed25519 signatures against an independently configured
# trust store and refuseth every other way.
# ---------------------------------------------------------------------------

APPROVAL_SCHEMA = 1
_CHUNK_TAG = b"GS-CHUNK-FINAL-V1"
_APPROVAL_TAG = b"GS-APPROVAL-V1"
_SET_TAG = b"GS-SET-V1"


class TrustPolicyError(ReleaseGateError):
    """Raised when the reviewer trust configuration itself is unsound."""


def _canon(tag: bytes, fields: Iterable[str]) -> bytes:
    """Length-prefixed, domain-tagged concatenation: ('ab','c') and
    ('a','bc') shall never chain to one hash."""
    parts = [tag]
    for value in fields:
        raw = str(value).encode("utf-8")
        parts.append(str(len(raw)).encode("ascii") + b"\x1f" + raw + b"\x1e")
    return b"".join(parts)


def set_digest(values: Iterable[str]) -> str:
    """A canonical digest over a sorted set of texts; equal texts are
    equal texts, and the empty set hasheth of its own right name."""
    return hashlib.sha256(_canon(_SET_TAG, sorted(
        {str(value).strip() for value in values if str(value).strip()}
    ))).hexdigest()


def yaml_load_strict(text: str, origin: str) -> Any:
    """Parse YAML, refusing duplicate keys at any depth: a mapping that
    receiveth the same key twice is a smuggling gap, not a document."""
    try:
        nodes = list(yaml.compose_all(text, Loader=yaml.SafeLoader))
    except yaml.YAMLError as exc:
        raise ReleaseGateError(f"{origin}: malformed YAML: {exc}") from exc
    for node in nodes:
        _walk_strict_node(node, origin)
    try:
        return yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise ReleaseGateError(f"{origin}: malformed YAML: {exc}") from exc


def _walk_strict_node(node: Any, origin: str) -> None:
    if isinstance(node, yaml.MappingNode):
        seen: list = []
        for key_node, value_node in node.value:
            if isinstance(key_node, yaml.ScalarNode):
                mark = (key_node.tag, key_node.value)
                if mark in seen:
                    raise ReleaseGateError(
                        f"{origin}: duplicate YAML key {key_node.value!r}")
                seen.append(mark)
            _walk_strict_node(key_node, origin)
            _walk_strict_node(value_node, origin)
    elif isinstance(node, yaml.SequenceNode):
        for item in node.value:
            _walk_strict_node(item, origin)


@dataclass(frozen=True)
class TrustedReviewerKey:
    key_id: str
    reviewer_id: str
    valid_from: date
    valid_until: date
    public_key: Ed25519PublicKey


@dataclass(frozen=True)
class TrustedReviewerKeySet:
    """The independently configured set of reviewer keys. It is loaded
    from the operator's own path; a bundle that nominates its own keys is
    refused before any byte of it is read (assert_independent_store)."""

    keys: Mapping[str, TrustedReviewerKey]
    source: Path | None = None

    def get(self, key_id: str) -> TrustedReviewerKey | None:
        return self.keys.get(key_id)

    @classmethod
    def load(cls, path: Path) -> "TrustedReviewerKeySet":
        origin = str(path)
        if not Path(path).is_file():
            raise TrustPolicyError(f"{origin}: reviewer trust store is missing")
        try:
            data = strict_json_loads(
                Path(path).read_text(encoding="utf-8"), origin)
        except (OSError, json.JSONDecodeError, ArchiveManifestError) as exc:
            raise TrustPolicyError(
                f"{origin}: unreadable reviewer trust store: {exc}") from exc
        if not isinstance(data, Mapping):
            raise TrustPolicyError(
                f"{origin}: reviewer trust store root must be an object")
        if data.get("schema") != APPROVAL_SCHEMA:
            raise TrustPolicyError(
                f"{origin}: reviewer trust store schema must be {APPROVAL_SCHEMA}")
        rows = data.get("keys")
        if not isinstance(rows, list) or not rows:
            raise TrustPolicyError(f"{origin}: keys must be a non-empty array")
        keys: dict[str, TrustedReviewerKey] = {}
        for index, row in enumerate(rows):
            if not isinstance(row, Mapping):
                raise TrustPolicyError(f"{origin}: keys[{index}] is not an object")
            key_id = str(row.get("key_id", "")).strip()
            reviewer_id = str(row.get("reviewer_id", "")).strip()
            if not key_id or not reviewer_id:
                raise TrustPolicyError(
                    f"{origin}: keys[{index}] lacks key_id or reviewer_id")
            if _PLACEHOLDER.search(key_id) or _PLACEHOLDER.search(reviewer_id):
                raise TrustPolicyError(
                    f"{origin}: key {key_id} carries a placeholder identity")
            if key_id in keys:
                raise TrustPolicyError(f"{origin}: duplicate signing key_id {key_id}")
            try:
                raw = b64decode(str(row.get("public_key", "")).strip(),
                               validate=True)
            except ValueError as exc:
                raise TrustPolicyError(
                    f"{origin}: key {key_id} public_key is not base64") from exc
            if len(raw) != 32:
                raise TrustPolicyError(
                    f"{origin}: key {key_id} is not a raw 32-byte Ed25519 public key")
            try:
                public = Ed25519PublicKey.from_public_bytes(raw)
            except ValueError as exc:
                raise TrustPolicyError(
                    f"{origin}: key {key_id} cannot be read as an Ed25519 public key"
                ) from exc
            try:
                valid_from = date.fromisoformat(str(row.get("valid_from", "")).strip())
                valid_until = date.fromisoformat(str(row.get("valid_until", "")).strip())
            except ValueError as exc:
                raise TrustPolicyError(
                    f"{origin}: key {key_id} window must use YYYY-MM-DD") from exc
            if valid_until < valid_from:
                raise TrustPolicyError(
                    f"{origin}: key {key_id} expires before it is in force")
            keys[key_id] = TrustedReviewerKey(
                key_id, reviewer_id, valid_from, valid_until, public)
        return cls(keys=keys, source=Path(path))


def assert_independent_store(
    store: Path,
    *,
    forbidden_roots: Iterable[Path],
    what: str = "reviewer trust store",
) -> Path:
    """The bundle cannot nominate its own trusted keys: a trust store (or
    an approvals home) resolving inside the corpus, the manifests, the
    bundle or the destination is refused before it is read."""
    resolved = Path(store).resolve()
    for root in forbidden_roots:
        guarded = Path(root).resolve()
        try:
            resolved.relative_to(guarded)
        except ValueError:
            continue
        raise TrustPolicyError(
            f"{what} is nominated from inside the bundle: {resolved} resolves "
            f"within {guarded}; trust is configured independently or not at all")
    return resolved


def _signature_is_valid(
    public_key: Ed25519PublicKey, signature: bytes, message: bytes
) -> bool:
    """Verify a detached signature; false on any fault. A caller that
    counted nonempty signatures instead would prove the ink is dry."""
    try:
        public_key.verify(signature, message)
        return True
    except (InvalidSignature, ValueError):
        return False


def is_under(section_path: str, declared: Iterable[str]) -> bool:
    """True when the chunk path falls under a declared section name: the
    '>'-joined path, component by component casefolded, prefix-matches the
    declared name split the same way."""
    parts = [p.strip().casefold() for p in str(section_path).split(">")]
    for name in declared or ():
        wanted = [p.strip().casefold() for p in str(name).split(">")]
        if wanted and parts[: len(wanted)] == wanted:
            return True
    return False


def warning_sets_for(
    chunks: Sequence[Any],
    *,
    warning_sections: Iterable[str],
    contraindication_sections: Iterable[str],
) -> tuple[list[str], list[str]]:
    """Harvest the warning and contraindication texts that are in force:
    the texts of chunks whose path falls under a declared section."""
    warnings = sorted({str(c.text) for c in chunks
                        if is_under(c.section, warning_sections)})
    contraindications = sorted({str(c.text) for c in chunks
                                if is_under(c.section, contraindication_sections)})
    return warnings, contraindications


def chunk_final_hashes(
    *,
    source_id: str,
    document_sha256: str,
    chunks: Sequence[Any],
    warnings: Iterable[str],
    contraindications: Iterable[str],
) -> list[str]:
    """The canonical final form of every chunk that ships: identity,
    revision, ordinal, path, text, measure, and the warning sets in force.
    The approval bindeth to these hashes and to nothing else."""
    warnings_digest = set_digest(warnings)
    contra_digest = set_digest(contraindications)
    return [
        hashlib.sha256(_canon(_CHUNK_TAG, (
            source_id, document_sha256, str(ordinal), chunk.section,
            chunk.text, str(chunk.token_count),
            warnings_digest, contra_digest))).hexdigest()
        for ordinal, chunk in enumerate(chunks, start=1)
    ]


@dataclass(frozen=True)
class FinalChunkApprovalV1:
    schema: int
    source_id: str
    document_sha256: str
    rights_sha256: str
    reviewer_id: str
    reviewer_credential_evidence_file: str
    reviewer_credential_sha256: str
    reviewed_on: date
    valid_from: date
    valid_until: date
    warnings_sha256: str
    contraindications_sha256: str
    chunk_final_sha256: tuple[str, ...]
    chunk_count: int
    key_id: str
    signature: str

    def bound_fields(self) -> tuple[str, ...]:
        return (
            str(self.schema), self.source_id, self.document_sha256,
            self.rights_sha256, self.reviewer_id,
            self.reviewer_credential_evidence_file,
            self.reviewer_credential_sha256, self.reviewed_on.isoformat(),
            self.valid_from.isoformat(), self.valid_until.isoformat(),
            self.warnings_sha256, self.contraindications_sha256,
            set_digest(self.chunk_final_sha256), str(self.chunk_count),
            self.key_id,
        )

    def preimage(self) -> bytes:
        return _canon(_APPROVAL_TAG, self.bound_fields())


_APPROVAL_FIELDS = (
    "schema", "source_id", "document_sha256", "rights_sha256",
    "reviewer_id", "reviewer_credential_evidence_file",
    "reviewer_credential_sha256", "reviewed_on", "valid_from",
    "valid_until", "warnings_sha256", "contraindications_sha256",
    "chunk_final_sha256", "chunk_count", "key_id", "signature")


def _jsonable(value: Any) -> Any:
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, tuple):
        return [_jsonable(v) for v in value]
    if isinstance(value, list):
        return [_jsonable(v) for v in value]
    return value


def write_approvals_bundle(path: Path,
                           records: Sequence[FinalChunkApprovalV1]) -> None:
    body = {"schema": APPROVAL_SCHEMA,
            "approvals": [{field: _jsonable(getattr(record, field))
                          for field in _APPROVAL_FIELDS}
                         for record in records]}
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json(body) + b"\n")


def load_final_chunk_approvals(approvals_dir: Path,
                               source_id: str) -> tuple[FinalChunkApprovalV1, ...]:
    origin = str(Path(approvals_dir) / f"{source_id}.approvals.json")
    path = Path(origin)
    if not path.is_file():
        raise ReleaseGateError(f"{origin}: no approvals bundle for {source_id}")
    try:
        data = strict_json_loads(path.read_text(encoding="utf-8"), origin)
    except (OSError, json.JSONDecodeError, ArchiveManifestError) as exc:
        raise ReleaseGateError(
            f"{origin}: unreadable approvals bundle: {exc}") from exc
    if not isinstance(data, Mapping):
        raise ReleaseGateError(f"{origin}: bundle root must be an object")
    version = data.get("schema")
    if not isinstance(version, int) or isinstance(version, bool):
        raise ReleaseGateError(f"{origin}: schema must be an integer version")
    if version > APPROVAL_SCHEMA:
        raise ReleaseGateError(
            f"{origin}: unsupported future approvals schema {version}")
    if version != APPROVAL_SCHEMA:
        raise ReleaseGateError(f"{origin}: approvals schema must be {APPROVAL_SCHEMA}")
    rows = data.get("approvals")
    if not isinstance(rows, list) or not rows:
        raise ReleaseGateError(f"{origin}: approvals must be a non-empty array")
    records: list[FinalChunkApprovalV1] = []
    for index, row in enumerate(rows):
        if not isinstance(row, Mapping):
            raise ReleaseGateError(f"{origin}: approvals[{index}] is not an object")
        record_schema = row.get("schema")
        if (not isinstance(record_schema, int) or isinstance(record_schema, bool)
                or record_schema > APPROVAL_SCHEMA
                or record_schema != APPROVAL_SCHEMA):
            raise ReleaseGateError(
                f"{origin}: approvals[{index}].schema must be {APPROVAL_SCHEMA}")

        def _text(key: str, _row=row, _index=index) -> str:
            value = _row.get(key)
            value = "" if value is None else str(value).strip()
            if not value:
                raise ReleaseGateError(
                    f"{origin}: approvals[{_index}].{key} missing")
            return value

        def _hash(key: str) -> str:
            value = _text(key).lower()
            if not _SHA256.fullmatch(value):
                raise ReleaseGateError(
                    f"{origin}: approvals[{index}].{key} must be a lowercase SHA-256")
            return value

        def _day(key: str) -> date:
            raw = _text(key)
            try:
                return date.fromisoformat(raw)
            except ValueError as exc:
                raise ReleaseGateError(
                    f"{origin}: approvals[{index}].{key} must use YYYY-MM-DD") from exc

        chunks_raw = row.get("chunk_final_sha256")
        if not isinstance(chunks_raw, list) or not chunks_raw:
            raise ReleaseGateError(
                f"{origin}: approvals[{index}].chunk_final_sha256 must be a "
                f"non-empty array")
        chunk_hashes: list[str] = []
        for position, digest in enumerate(chunks_raw):
            digest = str(digest).strip().lower()
            if not _SHA256.fullmatch(digest):
                raise ReleaseGateError(
                    f"{origin}: approvals[{index}].chunk_final_sha256[{position}] "
                    f"is not a lowercase SHA-256")
            chunk_hashes.append(digest)
        count = row.get("chunk_count")
        if not isinstance(count, int) or isinstance(count, bool) \
                or count != len(chunk_hashes):
            raise ReleaseGateError(
                f"{origin}: approvals[{index}].chunk_count doth not number the "
                f"chunk hashes given")
        records.append(FinalChunkApprovalV1(
            schema=record_schema,
            source_id=_text("source_id"),
            document_sha256=_hash("document_sha256"),
            rights_sha256=_hash("rights_sha256"),
            reviewer_id=_text("reviewer_id"),
            reviewer_credential_evidence_file=_text(
                "reviewer_credential_evidence_file"),
            reviewer_credential_sha256=_hash("reviewer_credential_sha256"),
            reviewed_on=_day("reviewed_on"),
            valid_from=_day("valid_from"),
            valid_until=_day("valid_until"),
            warnings_sha256=_hash("warnings_sha256"),
            contraindications_sha256=_hash("contraindications_sha256"),
            chunk_final_sha256=tuple(sorted(chunk_hashes)),
            chunk_count=count,
            key_id=_text("key_id"),
            signature=_text("signature"),
        ))
    return tuple(records)


def _section_names(value: Any, field: str, errors: list[str]) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str) or not isinstance(value, Sequence):
        errors.append(f"{field} must be a list of section names")
        return []
    names = [str(item).strip() for item in value]
    if any(not name for name in names):
        errors.append(f"{field} must not hold empty names")
    return [name for name in names if name]


@dataclass(frozen=True)
class ApprovalCoverage:
    source_id: str
    chunk_total: int
    chunk_approved: int
    warnings_sha256: str
    contraindications_sha256: str
    bundle_sha256: str


def verify_chunk_approvals(
    *,
    source_id: str,
    document_sha256: str,
    rights_sha256: str,
    manifest_path: Path,
    evidence_root: Path,
    chunks: Sequence[Any],
    approvals_dir: Path,
    keyset: TrustedReviewerKeySet,
    today: date,
) -> ApprovalCoverage:
    """Prove that every final chunk of one source is covered by a fresh,
    properly signed approval from an operator-nominated key -- and that
    nothing outside the corpus claims one. Every fault is collected; the
    clock is injected, never wall-watched."""
    chunks = list(chunks)
    if not chunks:
        raise ReleaseGateError(f"{source_id}: no chunks to approve")
    errors: list[str] = []
    try:
        declared = yaml_load_strict(
            Path(manifest_path).read_text(encoding="utf-8"), str(manifest_path))
    except OSError as exc:
        raise ReleaseGateError(
            f"{source_id}: document manifest unreadable: {exc}") from exc
    if not isinstance(declared, Mapping):
        raise ReleaseGateError(
            f"{source_id}: document manifest root must be a mapping")
    safety = _require_mapping(declared.get("safety"),
                              f"{source_id}: safety", errors)
    warning_sections = _section_names(safety.get("warning_sections"),
                                       f"{source_id}: safety.warning_sections", errors)
    contraindication_sections = _section_names(
        safety.get("contraindication_sections"),
        f"{source_id}: safety.contraindication_sections", errors)
    if errors:
        raise ReleaseGateError("; ".join(errors))
    warnings, contraindications = warning_sets_for(
        chunks, warning_sections=warning_sections,
        contraindication_sections=contraindication_sections)
    warnings_digest = set_digest(warnings)
    contra_digest = set_digest(contraindications)
    expected = chunk_final_hashes(
        source_id=source_id, document_sha256=document_sha256, chunks=chunks,
        warnings=warnings, contraindications=contraindications)
    expected_set = set(expected)
    records = load_final_chunk_approvals(approvals_dir, source_id)
    claimed: list[str] = []
    for position, record in enumerate(records, start=1):
        label = f"{source_id}: approval {position}"
        key = keyset.get(record.key_id)
        if key is None:
            errors.append(
                f"{label}: signing key {record.key_id} is not in the "
                f"independently configured set")
            continue
        if key.reviewer_id != record.reviewer_id:
            errors.append(
                f"{label}: reviewer identity doth not match the key's bound "
                f"reviewer ({record.reviewer_id!r} against {key.reviewer_id!r})")
        if key.valid_from > today or key.valid_until < today:
            errors.append(
                f"{label}: signing key {record.key_id} is out of force on "
                f"{today.isoformat()}")
        if record.valid_until < today:
            errors.append(
                f"{label}: approval expired on {record.valid_until.isoformat()}")
        if record.valid_from > today:
            errors.append(
                f"{label}: approval is not in force till "
                f"{record.valid_from.isoformat()}")
        if record.reviewed_on > today:
            errors.append(
                f"{label}: review date {record.reviewed_on.isoformat()} is in "
                f"the future")
        if not (record.valid_from <= record.reviewed_on <= record.valid_until):
            errors.append(
                f"{label}: review date doth not fall within the approval window")
        if record.source_id != source_id:
            errors.append(f"{label}: bindeth another source {record.source_id}")
        if record.document_sha256 != document_sha256:
            errors.append(f"{label}: document digests do not match the bytes that ship")
        if record.rights_sha256 != rights_sha256:
            errors.append(f"{label}: rights digests do not match the approved rights packet")
        if record.warnings_sha256 != warnings_digest:
            errors.append(f"{label}: warning sets changed under the approval since it was signed")
        if record.contraindications_sha256 != contra_digest:
            errors.append(f"{label}: contraindication sets changed under the approval")
        _resolve_evidence(
            evidence_root,
            {
                "reviewer_credential_evidence_file":
                    record.reviewer_credential_evidence_file,
                "reviewer_credential_sha256": record.reviewer_credential_sha256,
            },
            "reviewer_credential_evidence_file",
            "reviewer_credential_sha256",
            label,
            errors,
        )
        foreign = sorted(set(record.chunk_final_sha256) - expected_set)
        for digest in foreign[:3]:
            errors.append(
                f"{label}: covereth chunk {digest[:12]}... that is not in this corpus")
        if len(foreign) > 3:
            errors.append(
                f"{label}: covereth {len(foreign)} foreign chunks in all")
        claimed.extend(record.chunk_final_sha256)
        try:
            signature = b64decode(record.signature, validate=True)
        except ValueError:
            errors.append(f"{label}: signature is not base64")
            continue
        if not _signature_is_valid(key.public_key, signature, record.preimage()):
            errors.append(
                f"{label}: signature is invalid: the bytes do not answer to the key")
    if len(claimed) != len(set(claimed)):
        seen: set[str] = set()
        doubled: set[str] = set()
        for digest in claimed:
            if digest in seen:
                doubled.add(digest)
            seen.add(digest)
        for digest in sorted(doubled)[:3]:
            errors.append(
                f"{source_id}: chunk {digest[:12]}... is claimed by more than "
                f"one approval")
    uncovered = sorted(expected_set - set(claimed))
    if uncovered:
        errors.append(f"{source_id}: {len(uncovered)} chunk(s) are unapproved")
    if errors:
        head = "; ".join(errors[:12])
        tail = "" if len(errors) <= 12 else f"; and {len(errors) - 12} more fault(s)"
        raise ReleaseGateError(f"approvals rejected: {head}{tail}")
    bundle_sha256 = hashlib.sha256(b"".join(
        sorted(record.preimage() for record in records))).hexdigest()
    return ApprovalCoverage(
        source_id=source_id,
        chunk_total=len(expected),
        chunk_approved=len(set(claimed) & expected_set),
        warnings_sha256=warnings_digest,
        contraindications_sha256=contra_digest,
        bundle_sha256=bundle_sha256)


# --- TEST-ONLY aids: they fabricate keys and sign records for the courts. ---
# They no more prove clinical review than a seal blanks prove a deed; the
# operator's own signing ceremony happens elsewhere, out of band.

def make_test_keyset_entry(private_key: Ed25519PrivateKey, *, key_id: str,
                           reviewer_id: str, valid_from: date,
                           valid_until: date) -> dict[str, str]:
    public = private_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return {
        "key_id": key_id, "reviewer_id": reviewer_id,
        "public_key": b64encode(public).decode("ascii"),
        "valid_from": valid_from.isoformat(),
        "valid_until": valid_until.isoformat(),
    }


def write_test_keyset(path: Path,
                      entries: Sequence[Mapping[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical_json(
        {"schema": APPROVAL_SCHEMA, "keys": [dict(e) for e in entries]}) + b"\n")


def sign_final_approval_fields(
    private_key: Ed25519PrivateKey,
    *,
    source_id: str,
    document_sha256: str,
    rights_sha256: str,
    reviewer_id: str,
    reviewer_credential_evidence_file: str,
    reviewer_credential_sha256: str,
    reviewed_on: date,
    valid_from: date,
    valid_until: date,
    warnings_sha256: str,
    contraindications_sha256: str,
    chunk_final_sha256: Sequence[str],
    key_id: str,
) -> FinalChunkApprovalV1:
    record = FinalChunkApprovalV1(
        schema=APPROVAL_SCHEMA, source_id=source_id,
        document_sha256=document_sha256, rights_sha256=rights_sha256,
        reviewer_id=reviewer_id,
        reviewer_credential_evidence_file=reviewer_credential_evidence_file,
        reviewer_credential_sha256=reviewer_credential_sha256,
        reviewed_on=reviewed_on, valid_from=valid_from, valid_until=valid_until,
        warnings_sha256=warnings_sha256,
        contraindications_sha256=contraindications_sha256,
        chunk_final_sha256=tuple(sorted(chunk_final_sha256)),
        chunk_count=len(chunk_final_sha256), key_id=key_id, signature="")
    return replace(
        record,
        signature=b64encode(private_key.sign(record.preimage())).decode("ascii"))


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate GODSTONE production content manifests")
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--date", type=date.fromisoformat, default=None)
    args = parser.parse_args()
    try:
        result = validate_document_manifest(
            args.manifest, args.source, evidence_root=args.evidence_root, today=args.date
        )
    except ReleaseGateError as exc:
        print(str(exc))
        return 1
    print(json.dumps({
        "document_id": result.document_id,
        "manifest_sha256": result.manifest_sha256,
        "source_sha256": result.source_sha256,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
