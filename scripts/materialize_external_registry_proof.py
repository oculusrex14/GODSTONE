#!/usr/bin/env python3
"""Materialize the out-of-repository registry proof so a clean clone can re-derive it.

The evidence population bundle binds by digest the ledger's registered external evidence, which lives at the builder
root the record declares (evidence_root) -- a workstation directory a clean clone cannot carry. A naive re-derivation
there reported every external reference unresolved and refused the committed document for the runner's own missing
user files.

The fix is not to stop re-deriving: it is to give the clone the original bytes each registered reference's
disposition was measured from, so scripts/evidence_registry.classify re-derives the same examined/verified/unresolved
rows wherever it runs. This tool copies each required external reference's bytes, gzip compressed, into a tracked,
content-addressed archive named by the reference's registered SHA-256:

    evidence/external-registry-proof/<registered-sha256>.gz

The file name is the digest the bytes must hash to, so a tampered or missing proof is a named refusal rather than a
declared pass. Content addressing is over bytes: two references with identical content share one entry, while the
ledger keeps every original path, identity and disposition.

The required population is the external references enumerated by the registry's own ownership authority. Every
required reference whose builder-root file is absent, unreadable, or whose live SHA-256 disagrees with the ledger's
registered digest is a named problem, and the write is refused whole -- the tool never publishes a partial archive and
never pretends an old entry covers a live source it could not read.

The builder root is read only here. The archive directory is pinned inside the repository, every component is refused
if it is a symlink, and each entry is written to a fresh non-following temporary file then renamed into place, so an
existing symlink at the destination can never be followed to truncate the user's own log.

Usage:
    python3 scripts/materialize_external_registry_proof.py --write      # create the archive from the builder root
    python3 scripts/materialize_external_registry_proof.py --check      # prove the archive re-derives from the clone
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"
ARCHIVE = ROOT / "evidence" / "external-registry-proof"

sys.path.insert(0, str(ROOT / "scripts"))
from evidence_registry import (  # noqa: E402
    ARCHIVE_SUFFIX,
    CLONE_PROOF_DIRNAME,
    DIGEST,
    RegistryError,
    _clone_carried_bytes,
    _declared_evidence_root,
    _external_bytes,
    classify,
    declared_root_declaration,
    ownership_namespace,
    references,
    valid_anchored_loss,
)


def _tracked() -> set[str]:
    out = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"],
                         capture_output=True, text=True, check=True, timeout=120).stdout
    return set(out.split("\0")) - {""}


def _anchor() -> tuple[str, set[tuple[str, str]]]:
    """The immutable anchor commit and its (path, sha256) historical pairs, read from Git."""
    import importlib.util

    spec = importlib.util.spec_from_file_location("_beb_anchor", ROOT / "scripts" / "build_evidence_bundle.py")
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    commit = mod.HISTORICAL_ANCHOR["commit_sha"]
    text = subprocess.run(["git", "-C", str(ROOT), "show",
                           f"{commit}:docs/remediation/REMEDIATION_STATE.json"],
                          capture_output=True, text=True, check=True, timeout=120).stdout
    pairs = {(r["path"], r["sha256"]) for r in references(json.loads(text))
             if isinstance(r["path"], str) and isinstance(r["sha256"], str)}
    return commit, pairs


def _required_external(rows: list[dict], tracked: set[str],
                       historical_pairs: set[tuple[str, str]]) -> list[dict]:
    """Every external reference the archive must carry: not protected/repo-owned and not a valid anchored loss."""
    required: list[dict] = []
    for row in rows:
        namespace, _rel = ownership_namespace(row.get("path"), row.get("sha256"), ROOT, tracked, historical_pairs)
        if namespace != "external-historical":
            continue
        if valid_anchored_loss(row, historical_pairs):
            continue
        required.append(row)
    return required


def _archive_path(sha: str) -> Path:
    return ARCHIVE / f"{sha}{ARCHIVE_SUFFIX}"


def _assert_writable_destination() -> None:
    """Refuse if the archive directory or any ancestor inside the repo is a symlink or resolves outside the repo."""
    root_resolved = ROOT.resolve()
    for parent in (ARCHIVE, *ARCHIVE.parents):
        if parent == ROOT.parent:
            break
        if parent.is_symlink():
            raise RegistryError(f"an archive component {parent} is a symlink -- refusing to write through it")
    probe = ARCHIVE
    while not probe.exists() and probe != ROOT:
        probe = probe.parent
    if root_resolved not in probe.resolve().parents and probe.resolve() != root_resolved:
        raise RegistryError(f"the archive directory resolves outside the repository: {probe.resolve()}")


def _safe_write_entry(sha: str, data: bytes) -> None:
    """Write one entry atomically: a fresh temp file in the archive dir, then os.replace onto the destination.

    os.replace swaps the destination inode itself and never follows a symlink at the destination, so an existing
    symlink at <sha>.gz can never be followed to truncate the user's own evidence log.
    """
    ARCHIVE.mkdir(parents=True, exist_ok=True)
    dest = _archive_path(sha)
    if dest.is_symlink():
        raise RegistryError(f"{dest} is a symlink -- refusing to replace through it")
    fd, tmp = tempfile.mkstemp(prefix=f".{sha}.", suffix=".tmp", dir=ARCHIVE)
    try:
        # Exclude filename and timestamp from the gzip header; compressed-byte reproducibility still depends on zlib.
        with os.fdopen(fd, "wb") as fh:
            with gzip.GzipFile(filename="", mode="wb", fileobj=fh, mtime=0, compresslevel=9) as gz:
                gz.write(data)
        os.chmod(tmp, 0o644)
        os.replace(tmp, dest)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def materialize() -> tuple[int, list[str]]:
    """Verify every required external reference and write the whole archive, or refuse with nothing written."""
    document = json.loads(LEDGER.read_text(encoding="utf-8"))
    declared_root, declared_note = _declared_evidence_root(document, ROOT)
    if declared_root is None:
        # An invalid or absent root declaration refuses; the archive may not hide a bad identity.
        return 0, [f"the declared evidence_root is not a lawful source ({declared_note}) -- refusing to materialize"]
    tracked = _tracked()
    _commit, historical_pairs = _anchor()
    required = _required_external(references(document), tracked, historical_pairs)
    problems: list[str] = []
    entries: dict[str, bytes] = {}
    for row in required:
        expected, path = row.get("sha256"), row.get("path")
        if not isinstance(expected, str) or not DIGEST.fullmatch(expected):
            problems.append(f"{row['id']}: required external reference has no valid digest ({path})")
            continue
        data, why = _external_bytes(declared_root, declared_note, path)
        if data is None:
            problems.append(f"{row['id']}: required external proof is unreadable ({path}): {why}")
            continue
        actual = hashlib.sha256(data).hexdigest()
        if actual != expected:
            problems.append(f"{row['id']}: live SHA-256 {actual} disagrees with the registered {expected} "
                            f"({path}) -- proof may not be materialized from bytes that disagree with the register")
            continue
        entries[expected] = data
    if problems:
        # No partial publication: a single missing required input refuses the whole write.
        return 0, problems
    _assert_writable_destination()
    for sha, data in entries.items():
        _safe_write_entry(sha, data)
    return len(entries), problems


def check() -> tuple[int, list[str]]:
    """Prove the tracked archive supplies every required external proof and that the consumer re-derives from it.

    This checks only the clone-carried archive and the declared identity; it never reads the live builder root (the
    consumer does not either), so the check does not depend on workstation presence. classify()'s own problems are
    surfaced, so a malformed declaration cannot hide behind a valid archive.
    """
    document = json.loads(LEDGER.read_text(encoding="utf-8"))
    tracked = _tracked()
    commit, historical_pairs = _anchor()
    required = _required_external(references(document), tracked, historical_pairs)
    problems: list[str] = []
    n = 0
    for row in required:
        expected = row.get("sha256")
        got = _clone_carried_bytes(ROOT, expected, tracked) if isinstance(expected, str) else None
        if got is None:
            problems.append(f"{row['id']}: no lawful clone-carried proof entry "
                            f"{CLONE_PROOF_DIRNAME}/{expected}{ARCHIVE_SUFFIX}")
            continue
        if hashlib.sha256(got).hexdigest() != expected:
            problems.append(f"{row['id']}: archive entry does not hash to its own name")
            continue
        n += 1
    # The declared identity must be lawful (identity only -- not the live root's presence), and the consumer's own
    # verdict is the authority.
    _declared_root, declared_note = declared_root_declaration(document, ROOT)
    if _declared_root is None:
        problems.append(f"the declared evidence_root is not a lawful identity: {declared_note}")
    result = classify(document, root=ROOT, anchor_commit=commit)
    problems.extend(f"classify: {p}" for p in result["problems"])
    for rec in result["records"]:
        if rec.get("namespace") != "external-historical" or rec.get("disposition") == "declared_lost":
            continue
        if rec.get("read_via") != "clone-carried-proof-archive":
            problems.append(f"{rec['id']}: classify did not read the archive ({rec.get('reason')})")
    return n, problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="materialize the clone-carried registry proof archive")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args(argv)
    try:
        if args.write:
            n, problems = materialize()
            for p in problems:
                print(f"  ::error:: {p}")
            print(f"  archive entries written  : {n}")
            return 1 if problems else 0
        if args.check:
            n, problems = check()
            for p in problems:
                print(f"  ::error:: {p}")
            print(f"  archive records verified : {n}")
            return 1 if problems else 0
    except (OSError, ValueError, RegistryError) as exc:
        print(f"  ::error:: {exc}")
        return 1
    print("  nothing to do: pass --write or --check")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
