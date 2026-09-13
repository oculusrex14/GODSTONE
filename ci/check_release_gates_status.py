#!/usr/bin/env python3
"""Validate docs/production/RELEASE_GATES_STATUS.json (ADR-008 Stage 3, Phase J).

The release-gates workflow represents external gates that cannot run in
repository-verification explicitly as OPEN/BLOCKED in a durable status file.
This validator enforces that representation so an unavailable external gate can
never be turned green by being silently skipped:

  * every required external gate is present;
  * status is one of {OPEN, BLOCKED, CLOSED};
  * every gate marked CLOSED MUST carry a full commit SHA for its evidence;
    this checks the pointer's shape, not whether the evidence proves closure;
  * the runnable-in-CI gates (A-06, production-corpus, model-native-stack) are
    exercised by release-gates.yml and may be OPEN here while their CI job is
    fail-closed;
  * the not-runnable-in-ci gates (device-interoperability, accessibility,
    battery-thermal, signing-store-approval) MUST retain their external CI
    designation. CLOSED additionally requires an explicit closure requirement;
    CI alone does not establish their on-device or approval evidence.

This is itself a repo-owned gate and runs in repository-verification. The
inner selftest (T52) runs with every plain invocation, before the live file
is judged: a checker that has forgotten how to refuse must not be trusted
to approve.
"""
from __future__ import annotations

import argparse
import copy
import json
import re
from pathlib import Path
from typing import Any, Mapping

ROOT = Path(__file__).resolve().parents[1]
STATUS = ROOT / "docs" / "production" / "RELEASE_GATES_STATUS.json"

REQUIRED = {
    "A-06-independent-noise-vectors": "ci",
    "production-corpus": "ci",
    "model-native-stack": "ci",
    "android-archive-only-release": "ci",
    "device-interoperability": "not-runnable-in-ci",
    "accessibility": "not-runnable-in-ci",
    "battery-thermal": "not-runnable-in-ci",
    "signing-store-approval": "not-runnable-in-ci",
}
VALID = {"OPEN", "BLOCKED", "CLOSED"}


def validate_status(data: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, Mapping) or not isinstance(data.get("gates"), list):
        return ["status must be an object containing a gates array"]
    gates: dict[str, Mapping[str, Any]] = {}
    for index, gate in enumerate(data["gates"]):
        if not isinstance(gate, Mapping) or not isinstance(gate.get("gate"), str) or not gate["gate"].strip():
            errors.append(f"gates[{index}] must be an object with a nonempty gate name")
            continue
        name = gate["gate"]
        if name in gates:
            errors.append(f"duplicate gate: {name}")
        gates[name] = gate

    missing = set(REQUIRED) - set(gates)
    for g in sorted(missing):
        errors.append(f"missing required gate: {g}")

    for name, g in gates.items():
        kind = REQUIRED.get(name)
        status = g.get("status")
        if not isinstance(status, str) or status not in VALID:
            errors.append(f"{name}: invalid status {status!r} (must be one of {sorted(VALID)})")
            continue
        if status == "CLOSED":
            ev = g.get("evidence_commit")
            if not isinstance(ev, str) or not re.fullmatch(r"[0-9a-f]{40}", ev) or ev == "0" * 40:
                errors.append(f"{name}: CLOSED requires a full nonzero lowercase evidence_commit SHA")
        if kind == "not-runnable-in-ci" and status == "CLOSED":
            # A not-runnable-in-ci gate cannot be closed by CI alone; require
            # an evidence_commit AND a closure_requirement that names on-device
            # evidence. This is a second guard beyond the empty-evidence check.
            if not isinstance(g.get("closure_requirement"), str) or not g["closure_requirement"].strip():
                errors.append(f"{name}: CLOSED not-runnable gate without a "
                              "closure_requirement describing the on-device evidence")
        if kind == "not-runnable-in-ci" and g.get("ci_job") != "not-runnable-in-ci":
            errors.append(f"{name}: must be marked ci_job=not-runnable-in-ci")
        if kind == "ci" and (not isinstance(g.get("ci_job"), str) or not g["ci_job"].startswith("release-gates.yml / ")):
            errors.append(f"{name}: must name its release-gates.yml CI job")
    return errors


def selftest() -> int:
    fixture = {"gates": [
        {"gate": name, "status": "OPEN", "evidence_commit": None,
         "ci_job": "not-runnable-in-ci" if kind == "not-runnable-in-ci" else f"release-gates.yml / {name}"}
        for name, kind in REQUIRED.items()
    ]}
    if validate_status(fixture):
        print("::error::selftest baseline failed")
        return 1
    cases: list[tuple[str, Any]] = [("invalid root", []), ("invalid gates", {"gates": {}})]
    def mutate(label, change):
        value = copy.deepcopy(fixture)
        change(value)
        cases.append((label, value))
    mutate("missing required gate", lambda value: value["gates"].pop())
    mutate("duplicate gate", lambda value: value["gates"].append(value["gates"][0]))
    mutate("non-object gate", lambda value: value["gates"].append(None))
    mutate("unhashable status", lambda value: value["gates"][0].update(status=[]))
    mutate("fake closure evidence", lambda value: value["gates"][0].update(status="CLOSED", evidence_commit="yes"))
    mutate("unvalidated additional gate", lambda value: value["gates"].append({"gate": "additional", "status": "CLOSED"}))
    mutate("archive-only closure lacks evidence", lambda value: next(g for g in value["gates"] if g["gate"] == "android-archive-only-release").update(status="CLOSED"))
    mutate("external gate relabeled CI", lambda value: value["gates"][-1].update(ci_job="release-gates.yml / pretend"))
    mutate("external closure lacks requirement", lambda value: value["gates"][-1].update(status="CLOSED", evidence_commit="a" * 40))
    mutate("CI job omitted", lambda value: value["gates"][0].update(ci_job=None))
    failed = [label for label, value in cases if not validate_status(value)]
    refused = len(cases) - len(failed)
    for label in failed:
        print(f"::error::selftest failed to reject {label}")
    print(f"ok: release-gate status selftest refuseth {refused} of {len(cases)} "
          "malformed/false-closure controls")
    if failed:
        return 1
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--status", type=Path, default=STATUS)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    # A checker that can not refuse the false can not approve the true: the
    # inner selftest is ever-living, and it judges before the live file does.
    rc = selftest()
    if rc != 0:
        return rc
    try:
        data = json.loads(args.status.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"::error::cannot read status {args.status}: {exc}")
        return 1
    errors = validate_status(data)

    if errors:
        for e in errors:
            print(f"::error::{e}")
        print(f"FAIL: {len(errors)} release-gate status problem(s)")
        return 1
    print(f"ok: {len(data['gates'])} release gates represented; CLOSED gates have "
          "well-formed evidence pointers (evidence content is not verified here).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
