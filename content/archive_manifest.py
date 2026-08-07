#!/usr/bin/env python3
"""Create and verify signed GODSTONE Archive release manifests."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat, PublicFormat

MANIFEST_SCHEMA = 1
ALLOWED_TIERS = {"LIGHT", "MEDIUM", "LARGE"}


class ArchiveManifestError(RuntimeError):
    pass


@dataclass(frozen=True)
class VerificationResult:
    ok: bool
    errors: tuple[str, ...]


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def _canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _signable(manifest: Mapping[str, Any]) -> bytes:
    unsigned = dict(manifest)
    unsigned.pop("signature", None)
    return _canonical(unsigned)


def load_private_key(path: Path) -> Ed25519PrivateKey:
    raw = path.read_bytes()
    if len(raw) != 32:
        raise ArchiveManifestError("Ed25519 private key file must contain exactly 32 raw bytes")
    return Ed25519PrivateKey.from_private_bytes(raw)


def load_trust_store(path: Path) -> dict[str, Ed25519PublicKey]:
    data = json.loads(path.read_text(encoding="utf-8"))
    keys = data.get("keys") if isinstance(data, Mapping) else None
    if not isinstance(keys, Mapping):
        raise ArchiveManifestError("trust store must contain a keys mapping")
    output: dict[str, Ed25519PublicKey] = {}
    for key_id, value in keys.items():
        raw = base64.b64decode(str(value), validate=True)
        if len(raw) != 32:
            raise ArchiveManifestError(f"trust key {key_id} is not a raw Ed25519 public key")
        output[str(key_id)] = Ed25519PublicKey.from_public_bytes(raw)
    return output


def _db_metadata(archive: Path) -> tuple[dict[str, str], dict[str, int], str]:
    uri = f"file:{archive.resolve()}?mode=ro&immutable=1"
    conn = sqlite3.connect(uri, uri=True)
    try:
        integrity = str(conn.execute("PRAGMA integrity_check").fetchone()[0])
        meta: dict[str, str] = {}
        table_names = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view')")}
        if "archive_meta" in table_names:
            meta = {str(k): str(v) for k, v in conn.execute("SELECT key, value FROM archive_meta")}
        counts = {}
        for table in ("documents", "chunks", "vectors"):
            counts[table] = int(conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]) if table in table_names else 0
        fts = "fts5" if "chunks_fts" in table_names else "none"
        return meta, counts, integrity + ":" + fts
    finally:
        conn.close()


def create_manifest(
    archive: Path,
    output: Path,
    *,
    tier: str,
    archive_schema: int,
    source_manifest_sha256: str,
    review_manifest_sha256: str,
    corpus_manifest_sha256: str,
    build_tool_commit: str,
    private_key: Ed25519PrivateKey,
    key_id: str,
    embedding_model: str | None = None,
    embedding_sha256: str | None = None,
    embedding_dimension: int | None = None,
) -> dict[str, Any]:
    if tier not in ALLOWED_TIERS:
        raise ArchiveManifestError(f"unsupported tier: {tier}")
    if not archive.is_file():
        raise ArchiveManifestError(f"archive not found: {archive}")
    meta, counts, integrity = _db_metadata(archive)
    if not integrity.startswith("ok:"):
        raise ArchiveManifestError(f"archive integrity check failed: {integrity}")
    manifest: dict[str, Any] = {
        "schema": MANIFEST_SCHEMA,
        "archive_schema": archive_schema,
        "tier": tier,
        "archive_file": archive.name,
        "archive_bytes": archive.stat().st_size,
        "archive_sha256": _sha256(archive),
        "source_manifest_sha256": source_manifest_sha256,
        "review_manifest_sha256": review_manifest_sha256,
        "corpus_manifest_sha256": corpus_manifest_sha256,
        "build_tool_commit": build_tool_commit,
        "sqlite": {"integrity": "ok", "fts": integrity.split(":", 1)[1], "query_only": True},
        "counts": {
            "documents": counts["documents"],
            "chunks": counts["chunks"],
            "vectors": counts["vectors"],
        },
        "archive_meta": meta,
        "embedding": None if embedding_model is None else {
            "model": embedding_model,
            "sha256": embedding_sha256,
            "dimension": embedding_dimension,
        },
    }
    signature = private_key.sign(_signable(manifest))
    manifest["signature"] = {
        "algorithm": "Ed25519",
        "key_id": key_id,
        "value": base64.b64encode(signature).decode("ascii"),
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(_canonical(manifest) + b"\n")
    return manifest


def verify_manifest(
    manifest_path: Path,
    archive: Path,
    trust_store: Mapping[str, Ed25519PublicKey],
    *,
    expected_tier: str | None = None,
    expected_archive_schema: int | None = None,
    expected_embedding_sha256: str | None = None,
) -> VerificationResult:
    errors: list[str] = []
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return VerificationResult(False, (f"manifest unreadable: {exc}",))
    if not isinstance(manifest, Mapping):
        return VerificationResult(False, ("manifest root is not an object",))
    if manifest.get("schema") != MANIFEST_SCHEMA:
        errors.append(f"manifest schema must be {MANIFEST_SCHEMA}")
    if manifest.get("tier") not in ALLOWED_TIERS:
        errors.append("manifest tier is invalid")
    if expected_tier and manifest.get("tier") != expected_tier:
        errors.append("archive tier does not match the application variant")
    if expected_archive_schema is not None and manifest.get("archive_schema") != expected_archive_schema:
        errors.append("archive schema is incompatible")
    if manifest.get("archive_file") != archive.name:
        errors.append("archive filename does not match the manifest")
    if not archive.is_file():
        errors.append("archive file is missing")
    else:
        if manifest.get("archive_bytes") != archive.stat().st_size:
            errors.append("archive size mismatch")
        if manifest.get("archive_sha256") != _sha256(archive):
            errors.append("archive SHA-256 mismatch")
    signature = manifest.get("signature")
    if not isinstance(signature, Mapping) or signature.get("algorithm") != "Ed25519":
        errors.append("manifest has no supported signature")
    else:
        key_id = str(signature.get("key_id", ""))
        public_key = trust_store.get(key_id)
        if public_key is None:
            errors.append("manifest signing key is not trusted")
        else:
            try:
                public_key.verify(base64.b64decode(str(signature.get("value", "")), validate=True), _signable(manifest))
            except (ValueError, InvalidSignature):
                errors.append("manifest signature verification failed")
    if archive.is_file():
        try:
            meta, counts, integrity = _db_metadata(archive)
        except sqlite3.DatabaseError as exc:
            errors.append(f"archive cannot be opened read-only: {exc}")
        else:
            if not integrity.startswith("ok:"):
                errors.append("SQLite integrity check failed")
            if str(meta.get("schema_version", manifest.get("archive_schema"))) != str(manifest.get("archive_schema")):
                errors.append("archive metadata schema mismatch")
            if meta.get("tier") and meta.get("tier") != manifest.get("tier"):
                errors.append("archive metadata tier mismatch")
            expected_counts = manifest.get("counts", {})
            if isinstance(expected_counts, Mapping):
                for table, key in (("documents", "documents"), ("chunks", "chunks"), ("vectors", "vectors")):
                    if expected_counts.get(key) != counts[table]:
                        errors.append(f"archive {table} count mismatch")
    if expected_embedding_sha256:
        embedding = manifest.get("embedding")
        if not isinstance(embedding, Mapping) or embedding.get("sha256") != expected_embedding_sha256:
            errors.append("embedding model is incompatible with the archive")
    return VerificationResult(not errors, tuple(errors))


def generate_test_keypair(private_path: Path, trust_path: Path, key_id: str = "TEST-ONLY") -> None:
    key = Ed25519PrivateKey.generate()
    private_path.write_bytes(key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption()))
    public = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    trust_path.write_text(json.dumps({"keys": {key_id: base64.b64encode(public).decode("ascii")}}, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Create or verify signed GODSTONE archive manifests")
    sub = parser.add_subparsers(dest="command", required=True)
    create = sub.add_parser("create")
    create.add_argument("--archive", type=Path, required=True)
    create.add_argument("--out", type=Path, required=True)
    create.add_argument("--tier", choices=sorted(ALLOWED_TIERS), required=True)
    create.add_argument("--archive-schema", type=int, required=True)
    create.add_argument("--source-manifest-sha256", required=True)
    create.add_argument("--review-manifest-sha256", required=True)
    create.add_argument("--corpus-manifest-sha256", required=True)
    create.add_argument("--build-tool-commit", required=True)
    create.add_argument("--private-key", type=Path, required=True)
    create.add_argument("--key-id", required=True)
    verify = sub.add_parser("verify")
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--archive", type=Path, required=True)
    verify.add_argument("--trust-store", type=Path, required=True)
    verify.add_argument("--tier", choices=sorted(ALLOWED_TIERS))
    verify.add_argument("--archive-schema", type=int)
    args = parser.parse_args()
    try:
        if args.command == "create":
            create_manifest(
                args.archive, args.out, tier=args.tier, archive_schema=args.archive_schema,
                source_manifest_sha256=args.source_manifest_sha256,
                review_manifest_sha256=args.review_manifest_sha256,
                corpus_manifest_sha256=args.corpus_manifest_sha256,
                build_tool_commit=args.build_tool_commit,
                private_key=load_private_key(args.private_key), key_id=args.key_id,
            )
            print(args.out)
        else:
            result = verify_manifest(
                args.manifest, args.archive, load_trust_store(args.trust_store),
                expected_tier=args.tier, expected_archive_schema=args.archive_schema,
            )
            if not result.ok:
                print("\n".join(result.errors))
                return 1
            print("archive manifest verified")
    except (ArchiveManifestError, OSError, json.JSONDecodeError) as exc:
        print(str(exc))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
