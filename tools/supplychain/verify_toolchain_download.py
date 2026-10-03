#!/usr/bin/env python3
"""Verify a downloaded build-tool archive against its EXACT pin, before it is used.

    python3 tools/supplychain/verify_toolchain_download.py \
        --config docs/supplychain/TOOLCHAIN.pins.json \
        --id android-commandlinetools-macos /path/to/commandlinetools-mac-...zip
    python3 tools/supplychain/verify_toolchain_download.py --selftest

WHY THIS EXISTS
---------------
The workflows download a toolchain archive and, until now, unzipped it on the
strength of the URL alone. A URL is a location, not an identity: a mirror, a CDN
poisoning, a truncated transfer or a swapped release can all deliver DIFFERENT
bytes from the same URL. `docs/supplychain/TOOLCHAIN.pins.json` recordeth the one
identity the archive is allowed to have -- its exact bytes and its digest, the
latter taken from the vendor's OWN manifest (never invented here) -- and this
tool refuseth every blob that is not those bytes, so a substitution is caught at
the door rather than compiled into the product.

THE LAWS
--------
* No digest is invented. The sha256 in the pin was MEASURED on a fresh download
  and cross-checked against the sha1 and the size the vendor's manifest
  publisheth; a pin whose entries carry no digest is refused as half-sworn.
* Verification precedeth use. The command refuseth by name, naming the archive
  and the mismatch, so the step that unzippeth it must run only on exit 0.
* The selftest proveth the discrimination on synthetic bytes: a correct blob is
  accepted and a WRONG DIGEST (and a truncated blob) is refused, with no network
  in the loop.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

SCHEMA = 1
SHA256_RE = re.compile(r"[0-9a-f]{64}")
SHA1_RE = re.compile(r"[0-9a-f]{40}")


class ToolchainDownloadError(RuntimeError):
    """A refusal. Every refusal precedeth the archive being unzipped or used."""


def _require(condition: Any, message: str) -> None:
    if not condition:
        raise ToolchainDownloadError(message)


def load_pins(path: Path) -> dict[str, Any]:
    path = Path(path)
    _require(path.is_file(), f"the toolchain pin file is absent: {path}")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ToolchainDownloadError(f"{path}: not readable JSON: {exc}") from exc
    _require(isinstance(document, dict), f"{path}: the pin file must be an object")
    _require(document.get("schema") == SCHEMA,
             f"{path}: the pin file schema must be {SCHEMA}")
    archives = document.get("archives")
    _require(isinstance(archives, list) and archives,
             f"{path}: the pin file carrieth no archive")
    return document


def _digest(path: Path, algorithm: str) -> str:
    hasher = hashlib.new(algorithm)
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(block)
    return hasher.hexdigest()


def sha256_file(path: Path) -> str:
    return _digest(Path(path), "sha256")


def sha1_file(path: Path) -> str:
    return _digest(Path(path), "sha1")


def tree_sha256(root: Path) -> tuple[int, str]:
    """The content digest of an extracted tree: sorted relpath\\0bytes\\0sha256(blob).

    Digested by CONTENT, not by name or mtime, so a preexisting tool directory
    that is not the pinned bytes cannot pass as the pinned archive. A symlink in
    the tree is refused -- a link is not bytes and cannot be hashed honestly."""
    root = Path(root)
    _require(root.is_dir(), f"the tree root is absent: {root}")
    files: list[Path] = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ToolchainDownloadError(
                f"the tree carrieth a symlink, {path}: a link is not bytes")
        if path.is_file():
            files.append(path)
    hasher = hashlib.sha256()
    for path in files:
        rel = str(path.relative_to(root))
        blob_sha = sha256_file(path)
        hasher.update(f"{rel}\0{path.stat().st_size}\0{blob_sha}\n".encode("utf-8"))
    return len(files), hasher.hexdigest()


def verify_tree(root: Path, entry: Mapping[str, Any]) -> list[str]:
    """Judge an extracted tool tree against the pin's recorded identity."""
    extracted = entry.get("extracted")
    _require(isinstance(extracted, Mapping),
             f"the pin for {entry.get('id')!r} carries no extracted-tree identity")
    _require(SHA256_RE.fullmatch(str(extracted.get("tree_sha256") or "")),
             f"the pin for {entry.get('id')!r} carries no valid extracted-tree SHA-256")
    _require(isinstance(extracted.get("files"), int) and extracted["files"] > 0,
             f"the pin for {entry.get('id')!r} carries no positive extracted-file count")
    problems: list[str] = []
    count, digest = tree_sha256(root)
    if extracted.get("files") is not None and count != extracted["files"]:
        problems.append(f"{root.name}: the tree carrieth {count} file(s) where the pin "
                        f"sweareth {extracted['files']}")
    if digest != extracted.get("tree_sha256"):
        problems.append(f"{root.name}: the extracted tree digest {digest} is not the "
                        f"pinned {extracted.get('tree_sha256')}: the tool directory is "
                        f"NOT the pinned archive's contents")
    source = Path(root) / "source.properties"
    if source.is_file():
        text = source.read_text(encoding="utf-8", errors="replace")
        expected = str(extracted.get("pkg_revision") or "")
        match = re.search(r"Pkg\.Revision\s*=\s*([^\s]+)", text)
        measured = match.group(1) if match else ""
        if expected and measured != expected:
            problems.append(f"{root.name}: source.properties nameth Pkg.Revision "
                            f"{measured!r} where the pin sweareth {expected!r}")
    else:
        problems.append(f"{root.name}: the tree carrieth no source.properties")
    return problems


def select_archive(config: Mapping[str, Any], identity: str) -> dict[str, Any]:
    """The pinned entry named by id, filename or url. Exactly one must match."""
    matches = [entry for entry in config["archives"]
               if identity in (entry.get("id"), entry.get("filename"),
                               entry.get("url"))]
    _require(len(matches) == 1,
             f"the pin file carrieth {len(matches)} archive(s) named {identity!r}; "
             f"exactly one is required")
    return dict(matches[0])


def verify_pin(entry: Mapping[str, Any]) -> list[str]:
    """The pin must be fully sworn before it can be used to judge a blob."""
    problems: list[str] = []
    _require(entry.get("sha256") and SHA256_RE.fullmatch(str(entry["sha256"])),
             f"the pin for {entry.get('id')!r} carrieth no lower-case SHA-256: a pin "
             f"without a digest is not a pin")
    if entry.get("sha1") is not None:
        _require(SHA1_RE.fullmatch(str(entry["sha1"])),
                 f"the pin for {entry.get('id')!r} carrieth a malformed SHA-1")
    _require(isinstance(entry.get("bytes"), int) and entry["bytes"] > 0,
             f"the pin for {entry.get('id')!r} carrieth no positive byte count")
    _require(isinstance(entry.get("url"), str) and entry["url"].startswith("https://"),
             f"the pin for {entry.get('id')!r} carrieth no https URL")
    return problems


def verify_archive(path: Path, entry: Mapping[str, Any]) -> list[str]:
    """Judge a downloaded blob against its pin. Returns what is wrong, never a guess."""
    path = Path(path)
    _require(path.is_file(), f"the downloaded archive is absent: {path}")
    verify_pin(entry)
    problems: list[str] = []
    actual_bytes = path.stat().st_size
    if actual_bytes != entry["bytes"]:
        problems.append(f"{path.name}: {actual_bytes} byte(s) where the pin sweareth "
                        f"{entry['bytes']}: a truncated or substituted transfer")
    actual_sha256 = sha256_file(path)
    if actual_sha256 != entry["sha256"]:
        problems.append(f"{path.name}: sha256 {actual_sha256} is not the pinned "
                        f"{entry['sha256']}: THE DOWNLOAD IS NOT THE PINNED ARCHIVE")
    if entry.get("sha1") is not None:
        actual_sha1 = sha1_file(path)
        if actual_sha1 != entry["sha1"]:
            problems.append(f"{path.name}: sha1 {actual_sha1} is not the pinned "
                            f"{entry['sha1']} the vendor's manifest declares")
    return problems


def _selftest() -> int:
    """Prove the discrimination on synthetic bytes, with no network in the loop."""
    import tempfile
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as work:
        blob = Path(work) / "archive.zip"
        blob.write_bytes(b"the true archive bytes" * 16)
        entry = {"id": "fixture", "url": "https://example.invalid/a.zip",
                 "filename": "a.zip", "bytes": blob.stat().st_size,
                 "sha256": sha256_file(blob), "sha1": sha1_file(blob)}
        if verify_archive(blob, entry):
            failures.append("a correct blob was refused")
        wrong = dict(entry, sha256="0" * 64)
        problems = verify_archive(blob, wrong)
        if not any("NOT THE PINNED ARCHIVE" in item for item in problems):
            failures.append(f"a wrong digest was tolerated: {problems}")
        truncated = dict(entry, bytes=entry["bytes"] + 1)
        problems = verify_archive(blob, truncated)
        if not any("truncated or substituted" in item for item in problems):
            failures.append(f"a size mismatch was tolerated: {problems}")
        try:
            verify_archive(blob, {"id": "bad", "url": "https://x/y",
                                  "bytes": 1, "sha256": None})
            failures.append("a half-sworn pin was tolerated")
        except ToolchainDownloadError:
            pass
        # The extracted-tree identity: a tree that is not the pinned contents is
        # refused, and a symlink in the tree is refused as bytes it is not.
        import os
        tree = Path(work) / "cmdline-tools"
        tree.mkdir()
        (tree / "source.properties").write_text("Pkg.Revision=12.0\n",
                                                 encoding="utf-8")
        (tree / "bin").mkdir()
        (tree / "bin" / "sdkmanager").write_bytes(b"#!/bin/sh\n")
        count, digest = tree_sha256(tree)
        entry_tree = {"id": "t", "url": "https://x/y", "bytes": 1, "sha256": "0" * 64,
                      "extracted": {"root": "cmdline-tools", "files": count,
                                    "tree_sha256": digest, "pkg_revision": "12.0"}}
        if verify_tree(tree, entry_tree):
            failures.append("an honest tree was refused")
        for extracted in (None, {"files": count},
                          {"tree_sha256": digest},
                          {"files": 0, "tree_sha256": digest}):
            try:
                verify_tree(tree, dict(entry_tree, extracted=extracted))
            except ToolchainDownloadError:
                pass
            else:
                failures.append(f"an incomplete extracted-tree pin was tolerated: {extracted!r}")
        wrong = dict(entry_tree, extracted=dict(entry_tree["extracted"],
                                                tree_sha256="1" * 64))
        if not any("NOT the pinned archive" in item for item in verify_tree(tree, wrong)):
            failures.append("a tree that is not the pinned contents was tolerated")
        (tree / "escape").symlink_to(tree / "bin" / "sdkmanager")
        try:
            verify_tree(tree, entry_tree)
            failures.append("a symlink in the tool tree was tolerated")
        except ToolchainDownloadError:
            pass
    for line in failures:
        print(f"::error::{line}")
    if failures:
        print(f"selftest FAILED ({len(failures)})")
        return 1
    print("selftest OK: correct archive/tree accepted; wrong digest, truncation, "
          "incomplete archive/tree pins, substituted tree and symlinked tree refused")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify a downloaded build-tool archive against its exact pin")
    parser.add_argument("--config", type=Path,
                        default=Path("docs/supplychain/TOOLCHAIN.pins.json"))
    parser.add_argument("--id", help="the pin's id, filename or url")
    parser.add_argument("artifact", nargs="?", type=Path)
    parser.add_argument("--verify-tree", type=Path, metavar="DIR",
                        help="judge an already-extracted tool tree against the pin's "
                             "recorded identity (refuses a preexisting arbitrary tree)")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    if args.selftest:
        return _selftest()
    if args.id is None:
        parser.error("--id is required unless --selftest")
    try:
        config = load_pins(args.config)
        entry = select_archive(config, args.id)
        if args.verify_tree is not None:
            problems = verify_tree(args.verify_tree, entry)
            label = f"the tree {args.verify_tree}"
        elif args.artifact is not None:
            problems = verify_archive(args.artifact, entry)
            label = args.artifact.name
        else:
            parser.error("an artifact path or --verify-tree is required")
    except ToolchainDownloadError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    for line in problems:
        print(f"::error::{line}")
    if problems:
        return 1
    print(f"verified {label} against {entry['id']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
