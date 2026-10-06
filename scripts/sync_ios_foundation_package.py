#!/usr/bin/env python3
"""Materialize the host-testable iOS Core+Mesh package deterministically.

Authoritative sources: ios/Godstone/Sources/{GodstoneCore,GodstoneMesh} and
ios/Godstone/Tests/{GodstoneCoreTests,GodstoneMeshTests,LabMeshTests}. This script
reconciles their canonical `*.swift` sources into ios/Packages/GodstoneFoundation
so the Core+Mesh closure can be `swift test`-ed on a host/CI without building
the iOS-only GodstoneLLMBridge (llama.cpp) target.

Reconciliation is incremental and byte-preserving, NOT a wipe-and-recopy. A
destination file whose bytes already equal its canonical source is left strictly
untouched — same bytes, same mtime/inode — so re-running this script cannot
invalidate Swift's incremental build state for the whole mirror. Only missing or
genuinely changed files are (re)written, and stale generated members under the
mapped directories — including a stale file/symlink/directory that collides with
a canonical path — are removed, so the resulting tree is exactly what the old
rmtree+copy-all regenerate produced. SOURCE_MANIFEST.json is rewritten only when
its serialized bytes actually change.

The Foundation package is a GENERATED artifact. Do NOT edit its Sources/ or
Tests/ trees by hand — a hand-edit that differs from canonical is overwritten on
the next sync. Make all changes in ios/Godstone (canonical) and re-run this
script, then commit the regenerated tree. CI runs `--check` to fail closed on
drift between the committed generated tree and canonical, so a hand-edit or a
forgotten re-sync is caught. The Foundation Package.swift is a hand-maintained
subset (it intentionally omits the GodstoneLLMBridge/GodstoneLLM targets) and is
NOT reconciled by the copy logic; its hash is recorded in SOURCE_MANIFEST.json
for drift detection.

Manifest membership comes from Git, not ignored lane output. Write mode includes
new nonignored sources awaiting staging; check mode requires tracked inputs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "ios" / "Packages" / "GodstoneFoundation"
MAPPINGS = {
    ROOT / "ios" / "Godstone" / "Sources" / "GodstoneCore": PACKAGE / "Sources" / "GodstoneCore",
    ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh": PACKAGE / "Sources" / "GodstoneMesh",
    ROOT / "ios" / "Godstone" / "Tests" / "GodstoneCoreTests": PACKAGE / "Tests" / "GodstoneCoreTests",
    ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests": PACKAGE / "Tests" / "GodstoneMeshTests",
    # T54: the nonshipping LabMesh target's own test capability. It is mirrored so
    # the lab's real-composition cases EXECUTE on the host beside the mesh courts,
    # rather than existing only as an Xcode target no host run reacheth.
    ROOT / "ios" / "Godstone" / "Tests" / "LabMeshTests": PACKAGE / "Tests" / "LabMeshTests",
}


# Directory names that are NOT authoritative source and must never be hashed
# into SOURCE_MANIFEST.json. `.build/` is written by `swift test`/`swift build`
# under the package root (synthesized runner.swift, derived modules, ...);
# `.swiftpm/`, `DerivedData/`, `.git/` are tooling state. Ingesting any of them
# makes the manifest environment-dependent and non-idempotent: a clean checkout
# has no `.build/`, so a manifest that listed `.build/.../runner.swift` would
# report drift forever and break the ios verification job's `--check`. Only the
# committed Package.swift + Sources/ + Tests/ trees are the generated package.
EXCLUDED_DIRS = {".build", ".swiftpm", "DerivedData", ".git"}


def is_manifest_source(path: Path) -> bool:
    """True if `path` is authoritative package source (not a build artifact)."""
    return not any(part in EXCLUDED_DIRS for part in path.relative_to(PACKAGE).parts)


def digest(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.relative_to(PACKAGE).as_posix().encode())
    h.update(b"\0")
    h.update(path.read_bytes())
    return h.hexdigest()


def reconcile(source: Path, destination: Path) -> None:
    """Make `destination` exactly the canonical `*.swift` tree of `source`.

    Byte-preserving and idempotent: a mirror file whose bytes already equal its
    canonical source is left strictly untouched (same inode and mtime), so a
    no-op re-run cannot invalidate Swift's incremental build state for the whole
    mirror. Missing or changed files are (re)written, and stale generated members
    under the owned directory — extra files, stale subtrees, or a file/symlink/
    directory shape that collides with a canonical path — are removed, yielding
    byte-for-byte the tree the previous rmtree+copy-all regenerate produced.
    """
    wanted = {path.relative_to(source) for path in source.rglob("*.swift")}
    wanted_dirs: set[Path] = set()
    for rel in wanted:
        parent = rel.parent
        while parent != Path("."):
            wanted_dirs.add(parent)
            parent = parent.parent

    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        destination.unlink()

    if destination.is_dir():
        # Deepest-first so a removed subtree is never revisited. Keep an entry
        # only when it already has the shape the canonical tree wants: a regular
        # file at a canonical file path, or a real directory a canonical file
        # lives under. Everything else — extra files, stale subtrees, symlinks,
        # and file/directory shape collisions — is removed before rewriting.
        for entry in sorted(destination.rglob("*"), key=lambda p: len(p.parts), reverse=True):
            rel = entry.relative_to(destination)
            if entry.is_symlink():
                keep = False
            elif rel in wanted:
                keep = entry.is_file()
            elif rel in wanted_dirs:
                keep = entry.is_dir()
            else:
                keep = False
            if not keep:
                if entry.is_dir() and not entry.is_symlink():
                    shutil.rmtree(entry)
                else:
                    entry.unlink()

    destination.mkdir(parents=True, exist_ok=True)
    for rel in sorted(wanted):
        origin = source / rel
        target = destination / rel
        if target.is_file() and target.read_bytes() == origin.read_bytes():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(origin, target)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail if generated package drifts")
    args = parser.parse_args()

    for source, destination in MAPPINGS.items():
        if not source.is_dir():
            raise SystemExit(f"missing source directory: {source}")
        if args.check:
            if not destination.is_dir():
                raise SystemExit(f"missing generated directory: {destination}")
            source_files = {p.relative_to(source) for p in source.rglob("*.swift")}
            dest_files = {p.relative_to(destination) for p in destination.rglob("*.swift")}
            if source_files != dest_files:
                raise SystemExit(f"generated file-set drift: {source} -> {destination}")
            for rel in sorted(source_files):
                if source.joinpath(rel).read_bytes() != destination.joinpath(rel).read_bytes():
                    raise SystemExit(f"generated source drift: {destination / rel}")
        else:
            reconcile(source, destination)

    membership = ["--cached"] if args.check else ["--cached", "--others", "--exclude-standard"]
    names = subprocess.check_output(
        ["git", "-C", str(ROOT), "ls-files", "-z", *membership, "--",
         PACKAGE.relative_to(ROOT).as_posix()]
    ).decode().split("\0")
    manifest_sources = sorted(ROOT / name for name in names
                              if name.endswith(".swift") and is_manifest_source(ROOT / name))
    missing = [p.relative_to(PACKAGE).as_posix() for p in manifest_sources if not p.is_file()]
    if missing:
        raise SystemExit("GodstoneFoundation tracked source absent: " + ", ".join(missing))

    manifest = {
        "schema": 1,
        "files": {p.relative_to(PACKAGE).as_posix(): digest(p) for p in manifest_sources},
    }
    manifest_path = PACKAGE / "SOURCE_MANIFEST.json"
    if args.check:
        if json.loads(manifest_path.read_text()) != manifest:
            raise SystemExit("GodstoneFoundation SOURCE_MANIFEST.json drift")
    else:
        serialized = json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        if not manifest_path.is_file() or manifest_path.read_text() != serialized:
            manifest_path.write_text(serialized)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
