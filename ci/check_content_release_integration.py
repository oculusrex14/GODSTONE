#!/usr/bin/env python3
from pathlib import Path


def main() -> int:
    path = Path("content/ingest/build_archive.py")
    if not path.is_file():
        print("content/ingest/build_archive.py missing")
        return 1
    text = path.read_text(encoding="utf-8")
    required = (
        "from content.release_gate import validate_release_corpus",
        "validate_release_corpus(",
        'ROOT / "content" / "manifests" / "documents"',
    )
    missing = [item for item in required if item not in text]
    if missing:
        print("release builder is not wired to the complete content gate: " + ", ".join(missing))
        return 1
    print("release archive builder invokes the complete content gate")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
