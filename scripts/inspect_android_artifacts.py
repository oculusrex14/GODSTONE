#!/usr/bin/env python3
from __future__ import annotations
import argparse
import hashlib
import json
import zipfile
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("build_root", type=Path)
    parser.add_argument("out", type=Path)
    args = parser.parse_args()
    artifacts = sorted(list(args.build_root.rglob("*.apk")) + list(args.build_root.rglob("*.aab")))
    if not artifacts:
        print("no APK/AAB artifacts found")
        return 1
    args.out.mkdir(parents=True, exist_ok=True)
    inventory = []
    for artifact in artifacts:
        with zipfile.ZipFile(artifact) as zf:
            names = sorted(zf.namelist())
        forbidden = [n for n in names if any(t in n.lower() for t in ("archive_medium", "archive_large", "qwen3-1.7", "qwen3-4b"))]
        if forbidden:
            print(f"cross-tier asset contamination in {artifact}: {forbidden}")
            return 1
        inventory.append({"path": str(artifact), "bytes": artifact.stat().st_size, "sha256": digest(artifact), "entries": names})
    (args.out / "artifact-inventory.json").write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
