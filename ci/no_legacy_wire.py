#!/usr/bin/env python3
"""DEPRECATED shim -- use ci/check_shipping_path.py (gate) + ci/inventory_dormant_wire.py.

The old monolithic legacy-wire check has been split into two scripts with
correct build-config semantics:

  * ci/check_shipping_path.py     -- SHIPPING-PATH GATE. Fails iff legacy
                                      Mesh/GMP-1 wire is reachable from a LIGHT
                                      shipping build, decided by build-config
                                      evidence (Gradle java.exclude globs +
                                      project() deps; ios/project.yml sources
                                      allowlist + dependencies).
  * ci/inventory_dormant_wire.py  -- DORMANT-DEBT INVENTORY (non-passing).
                                      Reports compile-excluded legacy/future
                                      Mesh/SOS sources as technical debt. Does
                                      NOT close A-01; does NOT prove GMP/2.1.

This shim preserves the old entry point by delegating to the gate, so existing
callers keep getting a fail-on-shipping-contamination verdict. It does NOT
duplicate the inventory here -- run ci/inventory_dormant_wire.py for that.
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from check_shipping_path import main as gate_main  # noqa: E402


def main() -> int:
    print("note: ci/no_legacy_wire.py is deprecated; delegating to ci/check_shipping_path.py",
          file=sys.stderr)
    print("note: for the dormant-debt inventory run ci/inventory_dormant_wire.py",
          file=sys.stderr)
    return gate_main()


if __name__ == "__main__":
    raise SystemExit(main())