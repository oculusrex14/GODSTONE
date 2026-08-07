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
from dataclasses import dataclass
from datetime import date
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence

import yaml

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
        record = yaml.safe_load(manifest_path.read_text(encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as exc:
        raise ReleaseGateError(f"{manifest_path}: unreadable manifest: {exc}") from exc
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
