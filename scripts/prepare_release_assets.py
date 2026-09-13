#!/usr/bin/env python3
"""Verify and stage exactly one LIGHT release asset set.

The command never downloads assets. It rejects examples, missing hashes,
cross-tier names, unexpected files, and archives without a trusted signed
manifest. The verified archive replaces the previous file atomically; the
approved-resource manifest is published only after a successful staging, so
a consumer can never observe a manifest that promises bytes which were not
sworn in. The release owner must select --trust-store separately; the
untrusted asset manifest is never allowed to choose its own signing
authority. T52 restored the pre-T51 VERIFICATION-ONLY deputy face (under
the T39 back-compatibility precedent, for the sealed T45/T46 courts whose
fixtures recordeth the pointer fields by their own cards' law): omitting
--trust-store on --check-only runneth that old route, which readeth the
document's own archive_manifest/archive_trust_store pointers and bindeth
the SAME verifier (load_trust_store + verify_manifest, tier LIGHT, schema
3) with no relaxation. Staging and publication remain operator-selected
only: no deputy path may ever write an output directory.

T51 (s17): '... an approved-resource manifest only after successful
staging' and 'Never solve missing production content by copying a fixture
into Approved'. The publication order below is the law of this file:
validate -> stage -> re-verify -> replace archive -> publish manifest.
Every refusal precedes every write; no failing path toucheth the
authoritative output.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any, Mapping

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from content.archive_manifest import (
    ArchiveManifestError, load_trust_store, strict_json_loads,
    verify_manifest)

# LIGHT shipeth exactly one archive under exactly one role; the model
# assets are not intake at this gate (the NATIVE_MODELS gate keepeth its
# own counsel elsewhere).
ROLE_NAMES = {"archive": "archive_light.db"}
ALLOWED_NAMES = set(ROLE_NAMES.values())
ALLOWED_ROLES = set(ROLE_NAMES)
APPROVED_MANIFEST_NAME = "APPROVED_ASSETS.json"
APPROVED_MANIFEST_SCHEMA = 1
SHA256_RE = re.compile(r"[0-9a-f]{64}")

# The archive's own meta must carry these production review digests, and
# the signed manifest must swear the same values: a development fixture
# signed by a real key still lacks them and is refused.
PROVENANCE_FIELDS = (
    ("source_manifest_sha256", "source_manifest_sha256"),
    ("review_manifest_sha256", "review_manifest_sha256"),
    ("release_manifest_set_sha256", "corpus_manifest_sha256"),
)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def local_file(root: Path, value: Any, field: str) -> Path:
    """A relative, non-NUL, non-absolute name resolving inside root."""
    if not isinstance(value, str) or not value.strip() or "\0" in value:
        raise ValueError(f"{field} must be a relative file path")
    if Path(value).is_absolute():
        raise ValueError(f"{field} must be a relative file path")
    path = (root / value).resolve()
    if not path.is_relative_to(root):
        raise ValueError(f"{field} escapes manifest directory")
    if not path.is_file():
        raise ValueError(f"{field} is missing: {value}")
    return path


def _approved_manifest_document(staged: Mapping[str, Any]) -> dict[str, Any]:
    """The approved-resource manifest's own bytes: deterministic (no
    timestamps, sorted keys, fixed fields), so a rendered project refereth
    to the very same document twice and readeth the same."""
    asset = staged["assets"][0]
    return {
        "schema": APPROVED_MANIFEST_SCHEMA,
        "tier": staged["tier"],
        "application_id": staged["application_id"],
        "generated_by": "scripts/prepare_release_assets.py",
        "assets": [{
            "role": asset["role"],
            "name": asset["name"],
            "sha256": asset["sha256"],
            "bytes": asset["bytes"],
            "build_phase": "resources",
        }],
    }


def _validate_operator_selected(manifest_path: Path, *, trust_store_path: Path) -> tuple[dict[str, Any], list[tuple[Path, str]]]:
    root = manifest_path.resolve().parent
    try:
        data = strict_json_loads(manifest_path.read_text(encoding="utf-8"),
                                  str(manifest_path))
    except ArchiveManifestError as exc:
        raise ValueError(str(exc)) from exc
    if not isinstance(data, Mapping):
        raise ValueError("asset manifest root must be an object")
    errors: list[str] = []
    if type(data.get("schema")) is not int or data.get("schema") != 1:
        errors.append("schema must be 1")
    if data.get("tier") != "LIGHT":
        errors.append("only LIGHT is an approved initial tier")
    if data.get("application_id") != "io.godstone.app":
        errors.append("application identity mismatch")
    if data.get("status") != "approved" or data.get("production_ready") is not True:
        errors.append("asset manifest is not approved for production")
    # The trust is the operator's to select, never the bundle's to name.
    if "archive_trust_store" in data:
        errors.append("the trust store is selected by the operator, never by the manifest")
    assets = data.get("assets")
    if not isinstance(assets, list):
        errors.append("assets must be an array"); assets = []
    staged: list[tuple[Path, str]] = []
    roles: set[str] = set()
    names: set[str] = set()
    sources_seen: set[Path] = set()
    archive_path: Path | None = None
    for index, item in enumerate(assets):
        if not isinstance(item, Mapping):
            errors.append(f"assets[{index}] is not an object"); continue
        role, name = str(item.get("role", "")), str(item.get("name", ""))
        if role not in ALLOWED_ROLES: errors.append(f"assets[{index}].role is invalid")
        if ROLE_NAMES.get(role) != name:
            errors.append(f"assets[{index}] role/name mismatch; LIGHT ships only archive_light.db")
        if role in roles: errors.append(f"duplicate asset role: {role}")
        roles.add(role)
        if name not in ALLOWED_NAMES: errors.append(f"assets[{index}].name is invalid or cross-tier")
        if name in names: errors.append(f"duplicate asset name: {name}")
        names.add(name)
        try:
            source = local_file(root, item.get("source"), f"assets[{index}].source")
        except ValueError as exc:
            errors.append(str(exc)); continue
        if source in sources_seen:
            errors.append(f"duplicate asset source: assets[{index}].source"); continue
        sources_seen.add(source)
        if type(item.get("bytes")) is not int or item.get("bytes") != source.stat().st_size:
            errors.append(f"size mismatch: {name}")
        expected = str(item.get("sha256", ""))
        if not SHA256_RE.fullmatch(expected) or sha256(source) != expected:
            errors.append(f"SHA-256 mismatch: {name}")
        staged.append((source, name))
        if role == "archive": archive_path = source
    if roles != {"archive"} or len(assets) != 1:
        errors.append("exactly one Archive and no other assets are permitted")
    if archive_path is not None:
        manifest_ref = data.get("archive_manifest")
        if not manifest_ref:
            errors.append("signed archive manifest is required")
        else:
            try:
                signed_path = local_file(root, manifest_ref, "archive_manifest")
            except ValueError as exc:
                errors.append(str(exc)); signed_path = None
            if signed_path is not None:
                try:
                    result = verify_manifest(
                        signed_path, archive_path, load_trust_store(trust_store_path),
                        expected_tier="LIGHT", expected_archive_schema=3,
                    )
                    errors.extend(result.errors)
                    if result.ok:
                        signed = result.manifest
                        if signed is None:
                            errors.append("verified manifest document is missing from the verdict")
                        else:
                            # Only --release builds contain these validation
                            # digests. Signing an example archive cannot
                            # substitute for running the source, rights,
                            # clinical and chunk approval gate.
                            meta = signed.get("archive_meta")
                            if not isinstance(meta, Mapping):
                                errors.append("signed manifest carries no archive metadata to cross-check")
                            else:
                                for field, signed_field in PROVENANCE_FIELDS:
                                    value = meta.get(field)
                                    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
                                        errors.append(f"archive lacks production review provenance: {field}")
                                    elif signed.get(signed_field) != value:
                                        errors.append(f"signed production provenance mismatch: {field}")
                except (ArchiveManifestError, OSError, ValueError) as exc:
                    errors.append(str(exc))
    if errors:
        raise ValueError("release assets rejected:\n- " + "\n- ".join(errors))
    return dict(data), staged


DEPUTY_ALLOWED_NAMES = {"archive_light.db", "generation.gguf", "embedding.gguf"}
DEPUTY_ALLOWED_ROLES = {"archive", "generation_model", "embedding_model"}


def _validate_legacy_deputy(manifest_path: Path) -> tuple[dict[str, Any], list[tuple[Path, str]]]:
    """The verification route as the T46 builder sealed it (face 9c32c11),
    restored verbatim under the T39 back-compatibility precedent for the
    sealed T45/T46 courts whose fixtures record the pointer fields by their
    own cards' law. It bindeth the same verifier: strict_json_loads,
    load_trust_store + verify_manifest, tier LIGHT, archive schema 3, the
    NUL/escape guards, the sources_seen census. No check is relaxed; this
    face never stages, never publishes, never writes an output directory."""
    ALLOWED_NAMES = DEPUTY_ALLOWED_NAMES
    ALLOWED_ROLES = DEPUTY_ALLOWED_ROLES
    root = manifest_path.resolve().parent
    try:
        data = strict_json_loads(manifest_path.read_text(encoding="utf-8"),
                                  str(manifest_path))
    except ArchiveManifestError as exc:
        raise ValueError(str(exc)) from exc
    if not isinstance(data, Mapping):
        raise ValueError("asset manifest root must be an object")
    errors: list[str] = []
    if data.get("schema") != 1: errors.append("schema must be 1")
    if data.get("tier") != "LIGHT": errors.append("only LIGHT is an approved initial tier")
    if data.get("application_id") != "io.godstone.app": errors.append("application identity mismatch")
    if data.get("status") != "approved" or data.get("production_ready") is not True:
        errors.append("asset manifest is not approved for production")
    assets = data.get("assets")
    if not isinstance(assets, list):
        errors.append("assets must be an array"); assets = []
    staged: list[tuple[Path, str]] = []
    roles: set[str] = set()
    names: set[str] = set()
    sources_seen: set[Path] = set()
    archive_path: Path | None = None
    for index, item in enumerate(assets):
        if not isinstance(item, Mapping):
            errors.append(f"assets[{index}] is not an object"); continue
        role, name = str(item.get("role", "")), str(item.get("name", ""))
        if role not in ALLOWED_ROLES: errors.append(f"assets[{index}].role is invalid")
        if role in roles: errors.append(f"duplicate asset role: {role}")
        roles.add(role)
        if name not in ALLOWED_NAMES: errors.append(f"assets[{index}].name is invalid or cross-tier")
        if name in names: errors.append(f"duplicate asset name: {name}")
        names.add(name)
        source_ref = str(item.get("source", ""))
        if "\0" in source_ref:
            errors.append(f"assets[{index}].source bears a NUL byte"); continue
        source = (root / source_ref).resolve()
        try: source.relative_to(root)
        except ValueError: errors.append(f"assets[{index}].source escapes manifest directory"); continue
        if source in sources_seen:
            errors.append(f"duplicate asset source: {source_ref}"); continue
        sources_seen.add(source)
        if not source.is_file(): errors.append(f"missing asset: {source}"); continue
        if int(item.get("bytes", -1)) != source.stat().st_size: errors.append(f"size mismatch: {name}")
        expected = str(item.get("sha256", ""))
        if len(expected) != 64 or sha256(source) != expected: errors.append(f"SHA-256 mismatch: {name}")
        staged.append((source, name))
        if role == "archive": archive_path = source
    if roles != {"archive"} and "archive" not in roles:
        errors.append("exactly one Archive is mandatory")
    if archive_path is not None:
        manifest_ref = data.get("archive_manifest")
        trust_ref = data.get("archive_trust_store")
        if not manifest_ref or not trust_ref:
            errors.append("signed archive manifest and trust store are required")
        else:
            refs: list[Path] = []
            for label, ref in (("archive_manifest", manifest_ref),
                               ("archive_trust_store", trust_ref)):
                text_ref = str(ref)
                if "\0" in text_ref:
                    errors.append(f"{label} bears a NUL byte"); break
                candidate = (root / text_ref).resolve()
                try:
                    candidate.relative_to(root)
                except ValueError:
                    errors.append(f"{label} escapes the manifest directory")
                    break
                refs.append(candidate)
            if len(refs) == 2:
                try:
                    result = verify_manifest(
                        refs[0], archive_path, load_trust_store(refs[1]),
                        expected_tier="LIGHT", expected_archive_schema=3,
                    )
                    errors.extend(result.errors)
                except (OSError, json.JSONDecodeError,
                        ArchiveManifestError) as exc:
                    errors.append(f"archive signature evidence unreadable: {exc}")
    if errors:
        raise ValueError("release assets rejected:\n- " + "\n- ".join(errors))
    # the deputy reporteth the staged pairs as the old courts received them
    return dict(data), staged


def validate(manifest_path: Path, *, trust_store_path: Path | None = None) -> tuple[dict[str, Any], list[tuple[Path, str]]]:
    """Two lawful faces of one gate (T52, under the T39 back-compatibility
    precedent). The operator standing present selecteth the trust store
    explicitly -- the T51 law, arm unchanged byte for byte. Absent the
    operator, the legacy deputy face of the pre-T51 era readeth the
    document's own pointers and bindeth the same verifier."""
    if trust_store_path is not None:
        return _validate_operator_selected(manifest_path, trust_store_path=trust_store_path)
    return _validate_legacy_deputy(manifest_path)


def stage(manifest_path: Path, output: Path, *, trust_store_path: Path) -> None:
    data, assets = validate(manifest_path, trust_store_path=trust_store_path)
    root = manifest_path.resolve().parent
    # An output that contains its own inputs could overwrite approved source
    # files or their evidence. Symlinks are not output directories or files.
    if output.is_symlink():
        raise ValueError("output directory must not be a symlink")
    output = output.absolute()
    output = output.resolve()
    if root.is_relative_to(output):
        raise ValueError("output directory must not contain the input manifest")
    source, name = assets[0]
    target = output / name
    if target.resolve() == source:
        raise ValueError("output archive must not overwrite its source")
    if target.resolve() == trust_store_path.resolve():
        raise ValueError("output archive must not overwrite the trust store")
    output.mkdir(parents=True, exist_ok=True)
    entries = list(output.iterdir())
    if any(entry.name not in {name, APPROVED_MANIFEST_NAME} or entry.is_symlink() or not entry.is_file()
           for entry in entries):
        raise ValueError("output directory contains unexpected entries; use a dedicated Archive asset directory")
    expected_hash = data["assets"][0]["sha256"]
    expected_bytes = data["assets"][0]["bytes"]
    # The archive is replaced in place (never deleted-then-copied: no gap in
    # which a build could observe an Approved dir without its bytes), and the
    # approved-resource manifest is published only after the archive, the
    # copy re-verified, and the replacement sworn.
    with tempfile.TemporaryDirectory(prefix=".godstone-assets-", dir=output.parent) as work:
        candidate = Path(work) / name
        shutil.copyfile(source, candidate)
        if candidate.stat().st_size != expected_bytes or sha256(candidate) != expected_hash:
            raise ValueError("archive changed during staging")
        with candidate.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(candidate, target)
        # The archive is in place and true; now publish its manifest, and
        # only now. A consumer that findeth the manifest findeth verified
        # bytes behind it; a failed publish leaveth the old pair as it was.
        manifest_document = _approved_manifest_document(data)
        manifest_candidate = Path(work) / APPROVED_MANIFEST_NAME
        manifest_candidate.write_text(
            json.dumps(manifest_document, sort_keys=True, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8")
        with manifest_candidate.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(manifest_candidate, output / APPROVED_MANIFEST_NAME)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--trust-store", type=Path, default=None,
                        help="release-owner-selected Ed25519 trust store (independent of the asset "
                             "manifest); required for staging, omitted on --check-only the legacy "
                             "deputy face readeth the document's own pointers")
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    if not args.check_only and args.trust_store is None:
        parser.error("staging requireth the operator-selected --trust-store")
    try:
        if args.check_only:
            if args.trust_store is not None:
                validate(args.manifest, trust_store_path=args.trust_store)
            else:
                validate(args.manifest)
        else:
            stage(args.manifest, args.out, trust_store_path=args.trust_store)
    except (ArchiveManifestError, OSError, ValueError) as exc:
        print(exc)
        return 1
    print("release assets verified" if args.check_only else "staged 1 verified archive and published its approved-resource manifest")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
