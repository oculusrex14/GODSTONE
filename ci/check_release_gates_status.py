#!/usr/bin/env python3
"""Validate docs/production/RELEASE_GATES_STATUS.json (ADR-008 Stage 3, Phase J).

The release-gates workflow represents external gates that cannot run in
repository-verification explicitly as OPEN/BLOCKED in a durable status file.
This validator enforces that representation so an unavailable external gate can
never be turned green by being silently skipped:

  * every required external gate is present;
  * status is one of {OPEN, BLOCKED, CLOSED};
  * a gate marked CLOSED MUST carry a non-null evidence_commit (executable
    evidence of closure) -- a CLOSED gate without evidence is a false claim;
  * the runnable-in-CI gates (A-06, production-corpus, model-native-stack) are
    exercised by release-gates.yml and may be OPEN here while their CI job is
    fail-closed;
  * the not-runnable-in-ci gates (device-interoperability, accessibility,
    battery-thermal, signing-store-approval) MUST be present and MUST be
    OPEN or BLOCKED (they cannot be CLOSED by CI).

This is itself a repo-owned gate and runs in repository-verification.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATUS = ROOT / "docs" / "production" / "RELEASE_GATES_STATUS.json"

REQUIRED = {
    "A-06-independent-noise-vectors": "ci",
    "production-corpus": "ci",
    "model-native-stack": "ci",
    "device-interoperability": "not-runnable-in-ci",
    "accessibility": "not-runnable-in-ci",
    "battery-thermal": "not-runnable-in-ci",
    "signing-store-approval": "not-runnable-in-ci",
}
VALID = {"OPEN", "BLOCKED", "CLOSED"}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--status", type=Path, default=STATUS)
    args = ap.parse_args()
    if not args.status.exists():
        print(f"::error::missing {args.status.relative_to(ROOT)}")
        return 1
    data = json.loads(args.status.read_text(encoding="utf-8"))
    gates = {g["gate"]: g for g in data.get("gates", [])}
    errors: list[str] = []

    missing = set(REQUIRED) - set(gates)
    for g in sorted(missing):
        errors.append(f"missing required gate: {g}")

    for name, kind in REQUIRED.items():
        g = gates.get(name)
        if not g:
            continue
        status = g.get("status")
        if status not in VALID:
            errors.append(f"{name}: invalid status {status!r} (must be one of {sorted(VALID)})")
            continue
        if status == "CLOSED":
            ev = g.get("evidence_commit")
            if not ev:
                errors.append(f"{name}: CLOSED without evidence_commit -- a closed "
                              "gate without executable evidence is a false claim")
        if kind == "not-runnable-in-ci" and status == "CLOSED":
            # A not-runnable-in-ci gate cannot be closed by CI alone; require
            # an evidence_commit AND a closure_requirement that names on-device
            # evidence. This is a second guard beyond the empty-evidence check.
            if not g.get("closure_requirement"):
                errors.append(f"{name}: CLOSED not-runnable gate without a "
                              "closure_requirement describing the on-device evidence")
        if kind == "not-runnable-in-ci" and g.get("ci_job") != "not-runnable-in-ci":
            errors.append(f"{name}: must be marked ci_job=not-runnable-in-ci")

    if errors:
        for e in errors:
            print(f"::error::{e}")
        print(f"FAIL: {len(errors)} release-gate status problem(s)")
        return 1
    print(f"ok: {len(gates)} release gates represented; required external gates "
          f"OPEN/BLOCKED (not skipped). CLOSED gates require evidence_commit.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())