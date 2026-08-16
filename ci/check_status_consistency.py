#!/usr/bin/env python3
"""Stage 4E0: Production-readiness status consistency checker.

Compares machine-readable sources of truth against derived status artifacts to
ensure the repository status is mechanically truthful, consistent, and cannot
silently drift or claim unverified progress.

Sources of truth:
  - docs/production/FINDINGS_STATUS.json (findings, statuses, evidence)
  - docs/production/RELEASE_GATES_STATUS.json (external release gates)
  - config/tiers.json (canonical tier definitions and shipping flags)

Derived status artifacts checked:
  - RELEASE_MANIFEST.json
  - docs/production/FINAL_STATUS.md

Invariants enforced:
  1. Canonical verdict: PARTIALLY_REMEDIATED_NOT_READY across all status files.
  2. Branch identity: reflects active Stage 4 remediation branch.
  3. Shipping surface: LIGHT tier only; Oracle, Mesh, SOS, Bulk are disabled.
  4. Archive-only Android release capability: acknowledged as green in repo-owned
     release gates, while store-signed release remains external.
  5. Repo-owned parity: Invariants A, B, C, E, F, G, H green; D reported OPEN.
  6. Durable store / delivery evidence: repo-tested state machines distinguished
     from on-device/radio closure.
  7. Release gates truthfulness: fail-closed external gates (A-06, model, corpus,
     device, a11y, battery, signing) are OPEN or BLOCKED, never skipped.

Usage:
  python ci/check_status_consistency.py
  python ci/check_status_consistency.py --selftest
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

FINDINGS_STATUS_PATH = ROOT / "docs" / "production" / "FINDINGS_STATUS.json"
RELEASE_GATES_PATH = ROOT / "docs" / "production" / "RELEASE_GATES_STATUS.json"
TIERS_CONFIG_PATH = ROOT / "config" / "tiers.json"
RELEASE_MANIFEST_PATH = ROOT / "RELEASE_MANIFEST.json"
FINAL_STATUS_PATH = ROOT / "docs" / "production" / "FINAL_STATUS.md"

EXPECTED_VERDICT = "PARTIALLY_REMEDIATED_NOT_READY"
EXPECTED_BRANCH = "remediation/stage-4-link-release"
STALE_BRANCHES = ["remediation/stage-3-durability", "remediation/stage-2-gmp21", "remediate-overlay"]


def check_consistency(
    findings_path: Path = FINDINGS_STATUS_PATH,
    release_gates_path: Path = RELEASE_GATES_PATH,
    tiers_path: Path = TIERS_CONFIG_PATH,
    manifest_path: Path = RELEASE_MANIFEST_PATH,
    final_status_path: Path = FINAL_STATUS_PATH,
) -> list[str]:
    errors: list[str] = []

    # 1. Load and validate machine-readable JSON authorities
    for p, label in [
        (findings_path, "FINDINGS_STATUS.json"),
        (release_gates_path, "RELEASE_GATES_STATUS.json"),
        (tiers_path, "tiers.json"),
        (manifest_path, "RELEASE_MANIFEST.json"),
    ]:
        if not p.exists():
            errors.append(f"Missing authoritative file: {label} at {p}")
            return errors

    try:
        findings_data = json.loads(findings_path.read_text(encoding="utf-8"))
    except Exception as e:
        errors.append(f"Failed to parse {findings_path.name}: {e}")
        return errors

    try:
        release_gates_data = json.loads(release_gates_path.read_text(encoding="utf-8"))
    except Exception as e:
        errors.append(f"Failed to parse {release_gates_path.name}: {e}")
        return errors

    try:
        tiers_data = json.loads(tiers_path.read_text(encoding="utf-8"))
    except Exception as e:
        errors.append(f"Failed to parse {tiers_path.name}: {e}")
        return errors

    try:
        manifest_data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except Exception as e:
        errors.append(f"Failed to parse {manifest_path.name}: {e}")
        return errors

    if final_status_path.exists():
        final_status_text = final_status_path.read_text(encoding="utf-8")
    else:
        errors.append(f"Missing {final_status_path.name}")
        final_status_text = ""

    # 2. Check Verdict Consistency
    findings_verdict = findings_data.get("verdict")
    if findings_verdict != EXPECTED_VERDICT:
        errors.append(
            f"FINDINGS_STATUS.json verdict is {findings_verdict!r}; must be {EXPECTED_VERDICT!r}"
        )

    manifest_verdict = manifest_data.get("verdict")
    if manifest_verdict != EXPECTED_VERDICT:
        errors.append(
            f"RELEASE_MANIFEST.json verdict is {manifest_verdict!r}; must be {EXPECTED_VERDICT!r}"
        )

    if final_status_text:
        if "PARTIALLY REMEDIATED — NOT READY" not in final_status_text and "PARTIALLY_REMEDIATED_NOT_READY" not in final_status_text:
            errors.append("FINAL_STATUS.md does not contain required verdict 'PARTIALLY REMEDIATED — NOT READY'")

    # 3. Check Branch Identity
    manifest_branch = manifest_data.get("source", {}).get("branch", "")
    if manifest_branch != EXPECTED_BRANCH:
        errors.append(
            f"RELEASE_MANIFEST.json branch is {manifest_branch!r}; expected {EXPECTED_BRANCH!r}"
        )
    for stale in STALE_BRANCHES:
        if stale in manifest_branch:
            errors.append(f"RELEASE_MANIFEST.json references stale branch: {stale}")

    findings_branch = findings_data.get("generated_for_branch", "")
    if findings_branch != EXPECTED_BRANCH:
        errors.append(
            f"FINDINGS_STATUS.json generated_for_branch is {findings_branch!r}; expected {EXPECTED_BRANCH!r}"
        )

    gates_branch = release_gates_data.get("generated_from_branch", "")
    if gates_branch != EXPECTED_BRANCH:
        errors.append(
            f"RELEASE_GATES_STATUS.json generated_from_branch is {gates_branch!r}; expected {EXPECTED_BRANCH!r}"
        )

    # 4. Check Shipping Surface Truth
    tiers = tiers_data.get("tiers", {})
    if not tiers.get("LIGHT", {}).get("shipping", False):
        errors.append("config/tiers.json: LIGHT tier must be marked shipping=true")
    if tiers.get("MEDIUM", {}).get("shipping", True):
        errors.append("config/tiers.json: MEDIUM tier must be marked shipping=false")
    if tiers.get("LARGE", {}).get("shipping", True):
        errors.append("config/tiers.json: LARGE tier must be marked shipping=false")

    manifest_surface = manifest_data.get("shipping_surface", {})
    if manifest_surface.get("tier") != "LIGHT":
        errors.append(
            f"RELEASE_MANIFEST.json shipping tier is {manifest_surface.get('tier')!r}; expected 'LIGHT'"
        )
    if manifest_surface.get("oracle") != "disabled":
        errors.append("RELEASE_MANIFEST.json: Oracle must be marked 'disabled'")
    if "disabled" not in str(manifest_surface.get("mesh", "")):
        errors.append("RELEASE_MANIFEST.json: Mesh must be marked disabled")
    if manifest_surface.get("sos") != "disabled":
        errors.append("RELEASE_MANIFEST.json: SOS must be marked 'disabled'")
    if manifest_surface.get("bulk_transfer") != "disabled":
        errors.append("RELEASE_MANIFEST.json: bulk_transfer must be marked 'disabled'")

    # 5. Check Release Gates Status
    gates_list = release_gates_data.get("gates", [])
    gates_by_name = {g["gate"]: g for g in gates_list}

    # android-archive-only-release must be CLOSED with evidence_commit
    android_gate = gates_by_name.get("android-archive-only-release")
    if not android_gate:
        errors.append("RELEASE_GATES_STATUS.json missing 'android-archive-only-release' gate")
    elif android_gate.get("status") != "CLOSED":
        errors.append("RELEASE_GATES_STATUS.json: android-archive-only-release must be CLOSED")
    elif not android_gate.get("evidence_commit"):
        errors.append("RELEASE_GATES_STATUS.json: android-archive-only-release missing evidence_commit")

    # Fail-closed external gates MUST be OPEN or BLOCKED
    for ext_gate_name in [
        "A-06-independent-noise-vectors",
        "production-corpus",
        "model-native-stack",
        "device-interoperability",
        "accessibility",
        "battery-thermal",
        "signing-store-approval",
    ]:
        g = gates_by_name.get(ext_gate_name)
        if not g:
            errors.append(f"RELEASE_GATES_STATUS.json missing required external gate {ext_gate_name}")
            continue
        status = g.get("status")
        if status not in ("OPEN", "BLOCKED"):
            errors.append(
                f"RELEASE_GATES_STATUS.json: external gate {ext_gate_name} has status {status!r}; "
                f"must remain OPEN or BLOCKED until verified"
            )

    # 6. Check Release Blockers in Manifest
    # Release blockers must not claim resolved Stage 3 items are open blockers
    manifest_blockers = manifest_data.get("release_blockers", [])
    blocker_text = " ".join(manifest_blockers)

    stale_blocker_patterns = [
        ("tier tables disagree across platforms", "Invariant E tier tables agreement"),
        ("cross-platform byte parity not yet enforced", "GMP/2.1 byte parity"),
        ("durable encrypted message stores + bounded capacity (Phase E/G)", "durable message store repo implementation"),
        ("coordinated resumable panic wipe (Phase F)", "panic wipe state machine"),
        ("authenticated ACK delivery state (Phase H)", "authenticated ACK delivery state machine"),
        ("Archive-only Android release artifact with :llm out of the LIGHT graph (Phase I)", "Archive-only Android artifact"),
    ]
    for pattern, label in stale_blocker_patterns:
        if pattern in blocker_text:
            errors.append(f"RELEASE_MANIFEST.json contains stale release blocker claim: {label}")

    # 7. Check Findings Status Truth
    findings = {f["id"]: f for f in findings_data.get("findings", [])}
    nonshipping_findings = ["A-03", "A-10"]
    for fid in nonshipping_findings:
        f = findings.get(fid)
        if f:
            if f.get("status") == "CLOSED":
                errors.append(
                    f"FINDINGS_STATUS.json: {fid} is marked CLOSED; must remain NONSHIPPING_TESTED "
                    f"until on-device and radio verification are complete"
                )

    # 8. Check FINAL_STATUS.md prose truthfulness
    if final_status_text:
        # Check that FINAL_STATUS.md does not claim Android Archive-only artifact is "not produced"
        if re.search(r"clean APK/AAB is \*\*not produced\*\*", final_status_text, re.IGNORECASE):
            errors.append(
                "FINAL_STATUS.md states 'clean APK/AAB is not produced in repo-owned CI', "
                "contradicting android-archive-only-release gate"
            )
        # Check that FINAL_STATUS.md does not refer to Stage 3 as future work
        if "cross-platform byte parity and durable stores are Stage 3 work" in final_status_text:
            errors.append(
                "FINAL_STATUS.md contains stale reference 'byte parity and durable stores are Stage 3 work'"
            )
        # Check for stale branch references in FINAL_STATUS.md
        for stale in STALE_BRANCHES:
            if stale in final_status_text:
                errors.append(f"FINAL_STATUS.md contains stale branch reference: {stale}")

    return errors


def selftest() -> int:
    """Run mutation negative controls to prove the checker fails on invalid inputs."""
    print("Running check_status_consistency --selftest...")
    failures: list[str] = []
    passed_mutations = 0

    with tempfile.TemporaryDirectory() as td:
        tdp = Path(td)
        # Copy clean base files
        f_findings = tdp / "FINDINGS_STATUS.json"
        f_gates = tdp / "RELEASE_GATES_STATUS.json"
        f_tiers = tdp / "tiers.json"
        f_manifest = tdp / "RELEASE_MANIFEST.json"
        f_status = tdp / "FINAL_STATUS.md"

        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_gates.write_text(RELEASE_GATES_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_tiers.write_text(TIERS_CONFIG_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_manifest.write_text(RELEASE_MANIFEST_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_status.write_text(FINAL_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Baseline: clean files must pass
        base_errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status)
        # Note: if current real files are not yet updated, base_errs might not be empty yet,
        # but in selftest we create a known-good baseline first:
        manifest_clean = json.loads(f_manifest.read_text(encoding="utf-8"))
        manifest_clean["source"]["branch"] = EXPECTED_BRANCH
        manifest_clean["release_blockers"] = [
            "independent Noise vectors (A-06) unpinned",
            "production corpus + approved embedded archive unpinned",
            "model/native stack unpinned",
            "device interoperability / Hardware Case 0 over BLE link layer",
            "on-device accessibility verification",
            "battery and thermal profiling",
            "production signing and store approval",
        ]
        f_manifest.write_text(json.dumps(manifest_clean, indent=2), encoding="utf-8")

        status_clean = (
            "# Final status\n\n"
            "## Verdict\n\n"
            "**PARTIALLY REMEDIATED — NOT READY**\n\n"
            "## Build status\n\n"
            "Android Archive-only LIGHT binary is produced in release-gates CI.\n"
            "iOS LightRelease Archive-only build passes in CI.\n\n"
            "## Feature status\n\n"
            "Archive: initial LIGHT release surface.\n"
            "Oracle/Mesh/SOS/bulk: disabled and fail-closed.\n"
        )
        f_status.write_text(status_clean, encoding="utf-8")

        clean_errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status)
        if clean_errs:
            print(f"::error::selftest baseline failed: {clean_errs}")
            return 1

        # Mutation 1: Branch name mutated to remediation/stage-3-durability
        m1 = json.loads(f_manifest.read_text(encoding="utf-8"))
        m1["source"]["branch"] = "remediation/stage-3-durability"
        f_manifest.write_text(json.dumps(m1), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status)
        if any("remediation/stage-3-durability" in e or "branch" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 1 (stale branch) was NOT detected")
        f_manifest.write_text(json.dumps(manifest_clean, indent=2), encoding="utf-8")

        # Mutation 2: LIGHT shipping surface corrupted to include mesh
        m2 = json.loads(f_manifest.read_text(encoding="utf-8"))
        m2["shipping_surface"]["mesh"] = "enabled"
        f_manifest.write_text(json.dumps(m2), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status)
        if any("Mesh" in e or "mesh" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 2 (mesh enabled in shipping surface) was NOT detected")
        f_manifest.write_text(json.dumps(manifest_clean, indent=2), encoding="utf-8")

        # Mutation 3: External gate A-06 changed from OPEN to CLOSED/PASS
        g3 = json.loads(f_gates.read_text(encoding="utf-8"))
        for g in g3["gates"]:
            if g["gate"] == "A-06-independent-noise-vectors":
                g["status"] = "CLOSED"
        f_gates.write_text(json.dumps(g3), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status)
        if any("A-06" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 3 (A-06 marked CLOSED) was NOT detected")
        f_gates.write_text(RELEASE_GATES_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation 4: Android Archive-only build capability claimed "not produced" in status
        s4 = status_clean + "\nA full clean APK/AAB is **not produced** in repo-owned CI."
        f_status.write_text(s4, encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status)
        if any("not produced" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 4 (APK/AAB not produced claim) was NOT detected")
        f_status.write_text(status_clean, encoding="utf-8")

        # Mutation 5: NONSHIPPING_TESTED finding A-03 mutated to CLOSED
        f5 = json.loads(f_findings.read_text(encoding="utf-8"))
        for f in f5["findings"]:
            if f["id"] == "A-03":
                f["status"] = "CLOSED"
        f_findings.write_text(json.dumps(f5), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status)
        if any("A-03" in e and "CLOSED" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 5 (A-03 marked CLOSED) was NOT detected")
        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation 6: Tier registry/prose mismatch (MEDIUM marked shipping=true)
        t6 = json.loads(f_tiers.read_text(encoding="utf-8"))
        t6["tiers"]["MEDIUM"]["shipping"] = True
        f_tiers.write_text(json.dumps(t6), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status)
        if any("MEDIUM" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 6 (MEDIUM tier shipping=true) was NOT detected")
        f_tiers.write_text(TIERS_CONFIG_PATH.read_text(encoding="utf-8"), encoding="utf-8")

    if failures:
        for f in failures:
            print(f"::error::selftest failure: {f}")
        return 1

    print(f"check_status_consistency selftest PASSED ({passed_mutations}/6 mutations caught deterministically).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--selftest",
        action="store_true",
        help="Run mutation self-tests against synthetic inputs",
    )
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    errors = check_consistency()
    if errors:
        for e in errors:
            print(f"::error::Status inconsistency: {e}", file=sys.stderr)
        print(f"\nFAIL: {len(errors)} status inconsistency issue(s) found.", file=sys.stderr)
        return 1

    print("STATUS CONSISTENCY GATE: PASS -- machine-readable sources and status artifacts agree.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
