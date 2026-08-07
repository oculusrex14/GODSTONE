#!/usr/bin/env python3
from __future__ import annotations
import subprocess
import sys

CHECKS = [
    [sys.executable, "ci/no_release_bypasses.py"],
    [sys.executable, "ci/check_oracle_private_draft.py"],
    [sys.executable, "ci/check_release_surface.py"],
    [sys.executable, "ci/check_content_release_integration.py"],
    # Shipping-path gate: fails iff legacy Mesh/GMP-1 wire is reachable from a
    # LIGHT shipping build (build-config evidence). The companion
    # ci/inventory_dormant_wire.py is intentionally NOT here -- it is a
    # non-passing technical-debt inventory, not a gate. It does not close A-01.
    [sys.executable, "ci/check_shipping_path.py"],
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
