#!/usr/bin/env python3
"""Materialize the host-testable iOS Core+Mesh package deterministically.

Authoritative sources: ios/Godstone/Sources/{GodstoneCore,GodstoneMesh} and
ios/Godstone/Tests/{GodstoneCoreTests,GodstoneMeshTests}. This script COPIES
them (destructively: rmtree + copyfile) into ios/Packages/GodstoneFoundation
so the Core+Mesh closure can be `swift test`-ed on a host/CI without building
the iOS-only GodstoneLLMBridge (llama.cpp) target.

The Foundation package is a GENERATED artifact. Do NOT edit its Sources/ or
Tests/ trees by hand — edits are silently overwritten on the next sync. Make
all changes in ios/Godstone (canonical) and re-run this script, then commit
the regenerated tree. CI runs `--check` to fail on drift between the committed
generated tree and canonical, so a hand-edit or a forgotten re-sync is caught.
The Foundation Package.swift is a hand-maintained subset (it intentionally
omits the GodstoneLLMBridge/GodstoneLLM targets) and is NOT reconciled by the
copy logic; its hash is recorded in SOURCE_MANIFEST.json for drift detection.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "ios" / "Packages" / "GodstoneFoundation"
MAPPINGS = {
    ROOT / "ios" / "Godstone" / "Sources" / "GodstoneCore": PACKAGE / "Sources" / "GodstoneCore",
    ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh": PACKAGE / "Sources" / "GodstoneMesh",
    ROOT / "ios" / "Godstone" / "Tests" / "GodstoneCoreTests": PACKAGE / "Tests" / "GodstoneCoreTests",
    ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests": PACKAGE / "Tests" / "GodstoneMeshTests",
}


def digest(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.relative_to(PACKAGE).as_posix().encode())
    h.update(b"\0")
    h.update(path.read_bytes())
    return h.hexdigest()


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
            shutil.rmtree(destination, ignore_errors=True)
            destination.mkdir(parents=True, exist_ok=True)
            for path in sorted(source.rglob("*.swift")):
                target = destination / path.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)

    manifest = {
        "schema": 1,
        "files": {
            p.relative_to(PACKAGE).as_posix(): digest(p)
            for p in sorted(PACKAGE.rglob("*.swift"))
        },
    }
    manifest_path = PACKAGE / "SOURCE_MANIFEST.json"
    if args.check:
        if json.loads(manifest_path.read_text()) != manifest:
            raise SystemExit("GodstoneFoundation SOURCE_MANIFEST.json drift")
    else:
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
