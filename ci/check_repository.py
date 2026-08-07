#!/usr/bin/env python3
from __future__ import annotations
import subprocess
import sys

CHECKS = [
    [sys.executable, "ci/no_release_bypasses.py"],
    [sys.executable, "ci/check_oracle_private_draft.py"],
    [sys.executable, "ci/check_release_surface.py"],
    [sys.executable, "ci/check_content_release_integration.py"],
]


def main() -> int:
    failed = 0
    for command in CHECKS:
        print("+", " ".join(command), flush=True)
        result = subprocess.run(command, check=False)
        failed += result.returncode != 0
    return 1 if failed else 0

if __name__ == "__main__":
    raise SystemExit(main())
