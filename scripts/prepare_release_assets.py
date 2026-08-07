#!/usr/bin/env python3
"""Verify and stage exactly one LIGHT release asset set.

The command never downloads assets. It rejects examples, missing hashes,
cross-tier names, unexpected files, and archives without a trusted signed
manifest. The destination is cleaned before copying to prevent contamination.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import shutil
import sys
from pathlib import Path
from typing import Any, Mapping

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from content.archive_manifest import load_trust_store, verify_manifest

ALLOWED_NAMES = {"archive_light.db", "generation.gguf", "embedding.gguf"}
ALLOWED_ROLES = {"archive", "generation_model", "embedding_model"}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def validate(manifest_path: Path) -> tuple[dict[str, Any], list[tuple[Path, str]]]:
    root = manifest_path.resolve().parent
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
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
        source = (root / str(item.get("source", ""))).resolve()
        try: source.relative_to(root)
        except ValueError: errors.append(f"assets[{index}].source escapes manifest directory"); continue
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
            result = verify_manifest(
                (root / str(manifest_ref)).resolve(), archive_path,
                load_trust_store((root / str(trust_ref)).resolve()),
                expected_tier="LIGHT", expected_archive_schema=3,
            )
            errors.extend(result.errors)
    if errors:
        raise ValueError("release assets rejected:\n- " + "\n- ".join(errors))
    return dict(data), staged


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    try:
        _, staged = validate(args.manifest)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(exc)
        return 1
    if not args.check_only:
        if args.out.exists(): shutil.rmtree(args.out)
        args.out.mkdir(parents=True)
        for source, name in staged:
            shutil.copyfile(source, args.out / name)
        actual = {path.name for path in args.out.iterdir() if path.is_file()}
        expected = {name for _, name in staged}
        if actual != expected:
            print("staged asset set differs from manifest")
            return 1
    print("release assets verified" if args.check_only else f"staged {len(staged)} verified asset(s)")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
