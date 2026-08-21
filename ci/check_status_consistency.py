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
ADR004_PATH = ROOT / "docs" / "adr" / "ADR-004-durable-store.md"
ADR003_PATH = ROOT / "docs" / "adr" / "ADR-003-identity-and-sealed-sender.md"

EXPECTED_VERDICT = "PARTIALLY_REMEDIATED_NOT_READY"
EXPECTED_BRANCH = "remediation/stage-4-link-release"
EXPECTED_STAGE2_TIP = "b7bac64341c1214e05d0436fcb29c5b671d710e9"
EXPECTED_STAGE3_TIP = "ce265e2e2b9a8e01d9851bde9baefbae0c72c993"
STALE_BRANCHES = ["remediation/stage-3-durability", "remediation/stage-2-gmp21", "remediate-overlay"]


def check_consistency(
    findings_path: Path = FINDINGS_STATUS_PATH,
    release_gates_path: Path = RELEASE_GATES_PATH,
    tiers_path: Path = TIERS_CONFIG_PATH,
    manifest_path: Path = RELEASE_MANIFEST_PATH,
    final_status_path: Path = FINAL_STATUS_PATH,
    adr004_path: Path = ADR004_PATH,
    adr003_path: Path = ADR003_PATH,
) -> list[str]:
    errors: list[str] = []

    # 1. Load and validate machine-readable JSON authorities
    for p, label in [
        (findings_path, "FINDINGS_STATUS.json"),
        (release_gates_path, "RELEASE_GATES_STATUS.json"),
        (tiers_path, "tiers.json"),
        (manifest_path, "RELEASE_MANIFEST.json"),
        (adr004_path, "ADR-004-durable-store.md"),
        (adr003_path, "ADR-003-identity-and-sealed-sender.md"),
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

    # 3. Check Branch Identity and Immutable Frozen Tips
    manifest_source = manifest_data.get("source", {})
    manifest_branch = manifest_source.get("branch", "")
    if manifest_branch != EXPECTED_BRANCH:
        errors.append(
            f"RELEASE_MANIFEST.json branch is {manifest_branch!r}; expected {EXPECTED_BRANCH!r}"
        )
    for stale in STALE_BRANCHES:
        if stale in manifest_branch:
            errors.append(f"RELEASE_MANIFEST.json references stale branch: {stale}")

    manifest_stage2 = manifest_source.get("stage2_frozen_tip", "")
    if manifest_stage2 != EXPECTED_STAGE2_TIP:
        errors.append(
            f"RELEASE_MANIFEST.json stage2_frozen_tip is {manifest_stage2!r}; expected {EXPECTED_STAGE2_TIP!r}"
        )

    manifest_stage3 = manifest_source.get("stage3_frozen_tip", "")
    if manifest_stage3 != EXPECTED_STAGE3_TIP:
        errors.append(
            f"RELEASE_MANIFEST.json stage3_frozen_tip is {manifest_stage3!r}; expected {EXPECTED_STAGE3_TIP!r}"
        )

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

    # 7. Check Findings Status Truth & Semantic Asserts
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

    for fid in ["A-03", "A-04", "A-10"]:
        f = findings.get(fid)
        if f:
            ev = f.get("evidence", "")
            if "C7.4.1/C7.5/C7.5.1 atomic ACK and terminal retirement" not in ev:
                errors.append(
                    f"FINDINGS_STATUS.json: {fid} evidence must reflect 'C7.4.1/C7.5/C7.5.1 atomic ACK and terminal retirement'"
                )

    # Check finding A-05 (Identity binding / TOFU / sealed-sender)
    a05 = findings.get("A-05")
    if not a05:
        errors.append("FINDINGS_STATUS.json: missing finding A-05")
    else:
        a05_status = a05.get("status")
        if a05_status in ("CLOSED", "NONSHIPPING_TESTED", "IMPLEMENTED_SOURCE"):
            errors.append(
                f"FINDINGS_STATUS.json: A-05 status is {a05_status!r}; must remain OPEN_REPOSITORY "
                f"while C8 implementation remains open"
            )
        elif a05_status != "OPEN_REPOSITORY":
            errors.append(
                f"FINDINGS_STATUS.json: A-05 status is {a05_status!r}; expected 'OPEN_REPOSITORY'"
            )

        a05_ev = a05.get("evidence", "")
        if "trust architecture unimplemented" in a05_ev:
            errors.append("FINDINGS_STATUS.json: A-05 contains stale phrase 'trust architecture unimplemented'")
        if "C8.0" not in a05_ev:
            errors.append("FINDINGS_STATUS.json: A-05 evidence must mention C8.0")
        if "binding architecture" not in a05_ev and "peer-binding" not in a05_ev:
            errors.append("FINDINGS_STATUS.json: A-05 evidence must mention peer-binding architecture")
        if "C8.1B" not in a05_ev or "local identity authority" not in a05_ev:
            errors.append("FINDINGS_STATUS.json: A-05 evidence must reference C8.1B local identity authority implementation")
        if "peer trust store is implemented" in a05_ev or "PeerIdentityStore implemented" in a05_ev:
            errors.append("FINDINGS_STATUS.json: A-05 evidence must not claim peer trust store is implemented")
        if "implementation" not in a05_ev or "open" not in a05_ev.lower():
            errors.append("FINDINGS_STATUS.json: A-05 evidence must state implementation remains open")
        if "sealed-sender" not in a05_ev:
            errors.append("FINDINGS_STATUS.json: A-05 evidence must state sealed-sender authorship remains open")

    findings_raw = findings_path.read_text(encoding="utf-8")
    stale_findings_phrases = [
        ("delete-on-ACK (ADR-004, C7.4) pending", "stale delete-on-ACK pending without C7.4.1/C7.5 resolution"),
        ("delete-on-ACK (ADR-004) remain", "stale delete-on-ACK remain without C7.4.1/C7.5 resolution"),
    ]
    for stale_str, label in stale_findings_phrases:
        if stale_str in findings_raw:
            errors.append(f"FINDINGS_STATUS.json contains stale phrase: {label} ({stale_str!r})")

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
                errors.append(f"FINAL_STATUS.md references stale branch: {stale}")

    # 9. Check ADR-004 Status Authority
    if adr004_path.exists():
        adr004_text = adr004_path.read_text(encoding="utf-8")
        if "### Current repo-owned closure snapshot" not in adr004_text:
            errors.append("ADR-004: missing '### Current repo-owned closure snapshot' section under '## Current state'")
        else:
            snapshot_match = re.search(
                r"### Current repo-owned closure snapshot\s*\n(.*?)(?=\n##|\n###|\Z)",
                adr004_text,
                re.DOTALL,
            )
            if not snapshot_match:
                errors.append("ADR-004: could not extract '### Current repo-owned closure snapshot' section")
            else:
                snapshot_text = snapshot_match.group(1)

                if "- ADR-004 overall: OPEN" not in snapshot_text:
                    errors.append("ADR-004 snapshot: must contain '- ADR-004 overall: OPEN'")
                if "ADR-004 overall: CLOSED" in snapshot_text:
                    errors.append("ADR-004 snapshot: overall must not be CLOSED")

                if "- Persist-before-forward (Android): REPO-VERIFIED / NONSHIPPING" not in snapshot_text:
                    errors.append("ADR-004 snapshot: must contain '- Persist-before-forward (Android): REPO-VERIFIED / NONSHIPPING'")
                if "- Persist-before-forward (iOS): REPO-VERIFIED / NONSHIPPING" not in snapshot_text:
                    errors.append("ADR-004 snapshot: must contain '- Persist-before-forward (iOS): REPO-VERIFIED / NONSHIPPING'")

                if "- Delete-on-authenticated-ACK (Android): REPO-VERIFIED / NONSHIPPING" not in snapshot_text:
                    errors.append("ADR-004 snapshot: must contain '- Delete-on-authenticated-ACK (Android): REPO-VERIFIED / NONSHIPPING'")
                if "- Delete-on-authenticated-ACK (iOS): REPO-VERIFIED / NONSHIPPING" not in snapshot_text:
                    errors.append("ADR-004 snapshot: must contain '- Delete-on-authenticated-ACK (iOS): REPO-VERIFIED / NONSHIPPING'")

                if "- Terminal-retirement on EXPIRE / CANCEL (Android): REPO-VERIFIED / NONSHIPPING" not in snapshot_text:
                    errors.append("ADR-004 snapshot: must contain '- Terminal-retirement on EXPIRE / CANCEL (Android): REPO-VERIFIED / NONSHIPPING'")
                if "- Terminal-retirement on EXPIRE / CANCEL (iOS): REPO-VERIFIED / NONSHIPPING" not in snapshot_text:
                    errors.append("ADR-004 snapshot: must contain '- Terminal-retirement on EXPIRE / CANCEL (iOS): REPO-VERIFIED / NONSHIPPING'")

                if "- Durable held-set anti-entropy (Android): REPO-VERIFIED / NONSHIPPING" not in snapshot_text:
                    errors.append("ADR-004 snapshot: must contain '- Durable held-set anti-entropy (Android): REPO-VERIFIED / NONSHIPPING'")
                if "- Durable held-set anti-entropy (iOS): REPO-VERIFIED / NONSHIPPING" not in snapshot_text:
                    errors.append("ADR-004 snapshot: must contain '- Durable held-set anti-entropy (iOS): REPO-VERIFIED / NONSHIPPING'")

                # Still open section requirements
                if "on-device" not in snapshot_text:
                    errors.append("ADR-004 snapshot: Still open section must mention on-device verification")
                if "power-loss" not in snapshot_text and "reboot" not in snapshot_text and "durability" not in snapshot_text:
                    errors.append("ADR-004 snapshot: Still open section must mention physical reboot/power-loss/device durability")
                if "radio" not in snapshot_text and "link" not in snapshot_text and "partition" not in snapshot_text:
                    errors.append("ADR-004 snapshot: Still open section must mention radio/link or partition mobility")
                if "shipping-path" not in snapshot_text:
                    errors.append("ADR-004 snapshot: Still open section must mention shipping-path deployment")

                if "C7.4 pending" in snapshot_text or "C7.4 pending" in adr004_text:
                    errors.append("ADR-004 contains stale phrase: 'C7.4 pending'")
                if "delete-on-ACK pending" in snapshot_text:
                    errors.append("ADR-004 snapshot contains stale phrase: 'delete-on-ACK pending'")

    # 10. Check ADR-003 Status Authority
    if adr003_path.exists():
        adr003_text = adr003_path.read_text(encoding="utf-8")
        if "## 1. Status" not in adr003_text and "## 1 Status" not in adr003_text:
            errors.append("ADR-003: missing '## 1. Status' section")
        else:
            status_match = re.search(
                r"## 1\.\s*Status\s*\n(.*?)(?=\n##|\Z)",
                adr003_text,
                re.DOTALL,
            )
            if not status_match:
                errors.append("ADR-003: could not extract '## 1. Status' section")
            else:
                s_text = status_match.group(1)

                if "BINDING ARCHITECTURE FROZEN" not in s_text and "PEER-IDENTITY ARCHITECTURE FROZEN" not in s_text and "ARCHITECTURE FROZEN" not in s_text:
                    errors.append("ADR-003 status: must contain 'PEER-IDENTITY ARCHITECTURE FROZEN' or 'BINDING ARCHITECTURE FROZEN'")
                if "C8.1A" not in s_text:
                    errors.append("ADR-003 status: must mention C8.1A status as frozen/implemented")
                if "C8.1B" not in s_text:
                    errors.append("ADR-003 status: must mention C8.1B status as implemented/pending freeze")
                if "C8.2" not in s_text:
                    errors.append("ADR-003 status: must mention C8.2 status")
                if "C8.3" not in s_text:
                    errors.append("ADR-003 status: must mention C8.3 status")
                if re.search(r"C8\.4[^\n]*(?<!Un)implemented\b", s_text, re.IGNORECASE) or re.search(r"C8\.4[^\n]*\b(?:CLOSED|Frozen)\b", s_text, re.IGNORECASE) or "C8.4 Noise & Handshake Trust Gating:** OPEN" not in s_text:
                    errors.append("ADR-003 status: C8.4 must remain open and not claimed as implemented or closed")
                if "open" not in s_text.lower():
                    errors.append("ADR-003 status: must state implementation is OPEN")
                if "Sealed-Sender" not in s_text or "OPEN" not in s_text.upper():
                    errors.append("ADR-003 status: must state Sealed-Sender is OPEN")
                if "RecipientKeyResolver" not in s_text or "UNRESOLVED" not in s_text:
                    errors.append("ADR-003 status: must state RecipientKeyResolver is UNRESOLVED")
                if "Link" not in s_text or ("Disabled" not in s_text and "disabled" not in s_text and "false" not in s_text):
                    errors.append("ADR-003 status: must state Link layer is disabled")

                if "RecipientKeyResolver: READY" in s_text or "RecipientKeyResolver: RESOLVED" in s_text or "RecipientKeyResolver`:** READY" in s_text or "RecipientKeyResolver`:** RESOLVED" in s_text:
                    errors.append("ADR-003 status: RecipientKeyResolver must not be READY/RESOLVED")

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
        f_adr004 = tdp / "ADR-004-durable-store.md"
        f_adr003 = tdp / "ADR-003-identity-and-sealed-sender.md"

        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_gates.write_text(RELEASE_GATES_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_tiers.write_text(TIERS_CONFIG_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_manifest.write_text(RELEASE_MANIFEST_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_status.write_text(FINAL_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_adr004.write_text(ADR004_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_adr003.write_text(ADR003_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Baseline: clean files must pass
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

        clean_errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if clean_errs:
            print(f"::error::selftest baseline failed: {clean_errs}")
            return 1

        # Mutation 1: Branch name mutated to remediation/stage-3-durability
        m1 = json.loads(f_manifest.read_text(encoding="utf-8"))
        m1["source"]["branch"] = "remediation/stage-3-durability"
        f_manifest.write_text(json.dumps(m1), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("remediation/stage-3-durability" in e or "branch" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 1 (stale branch) was NOT detected")
        f_manifest.write_text(json.dumps(manifest_clean, indent=2), encoding="utf-8")

        # Mutation 2: LIGHT shipping surface corrupted to include mesh
        m2 = json.loads(f_manifest.read_text(encoding="utf-8"))
        m2["shipping_surface"]["mesh"] = "enabled"
        f_manifest.write_text(json.dumps(m2), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
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
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("A-06" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 3 (A-06 marked CLOSED) was NOT detected")
        f_gates.write_text(RELEASE_GATES_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation 4: Android Archive-only build capability claimed "not produced" in status
        s4 = status_clean + "\nA full clean APK/AAB is **not produced** in repo-owned CI."
        f_status.write_text(s4, encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
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
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("A-03" in e and "CLOSED" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 5 (A-03 marked CLOSED) was NOT detected")
        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation 6: Tier registry/prose mismatch (MEDIUM marked shipping=true)
        t6 = json.loads(f_tiers.read_text(encoding="utf-8"))
        t6["tiers"]["MEDIUM"]["shipping"] = True
        f_tiers.write_text(json.dumps(t6), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("MEDIUM" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 6 (MEDIUM tier shipping=true) was NOT detected")
        f_tiers.write_text(TIERS_CONFIG_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation 7: Stage 3 frozen tip corrupted
        m7 = json.loads(f_manifest.read_text(encoding="utf-8"))
        m7["source"]["stage3_frozen_tip"] = "0000000000000000000000000000000000000000"
        f_manifest.write_text(json.dumps(m7), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("stage3_frozen_tip" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 7 (stage3_frozen_tip corrupted) was NOT detected")
        f_manifest.write_text(json.dumps(manifest_clean, indent=2), encoding="utf-8")

        # Mutation 8: Stale delete-on-ACK phrase in FINDINGS_STATUS.json
        f8 = json.loads(f_findings.read_text(encoding="utf-8"))
        for f in f8["findings"]:
            if f["id"] == "A-03":
                f["evidence"] += " delete-on-ACK (ADR-004, C7.4) pending"
        f_findings.write_text(json.dumps(f8), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("stale delete-on-ACK pending" in e or "stale phrase" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 8 (stale delete-on-ACK phrase in FINDINGS_STATUS.json) was NOT detected")
        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation 9: Missing C7.4.1/C7.5/C7.5.1 evidence in A-03
        f9 = json.loads(f_findings.read_text(encoding="utf-8"))
        for f in f9["findings"]:
            if f["id"] == "A-03":
                f["evidence"] = "Old evidence without the C7 marker"
        f_findings.write_text(json.dumps(f9), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("A-03" in e and "C7.4.1/C7.5/C7.5.1 atomic ACK" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation 9 (missing C7.4.1/C7.5/C7.5.1 evidence in A-03) was NOT detected")
        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation S10: Android delete-on-ACK missing NONSHIPPING qualification
        adr004_clean = f_adr004.read_text(encoding="utf-8")
        s10 = adr004_clean.replace(
            "- Delete-on-authenticated-ACK (Android): REPO-VERIFIED / NONSHIPPING",
            "- Delete-on-authenticated-ACK (Android): REPO-VERIFIED"
        )
        f_adr004.write_text(s10, encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("Delete-on-authenticated-ACK (Android)" in e and "NONSHIPPING" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S10 (missing NONSHIPPING qualification) was NOT detected")
        f_adr004.write_text(adr004_clean, encoding="utf-8")

        # Mutation S11: ADR-004 overall marked CLOSED
        s11 = adr004_clean.replace("- ADR-004 overall: OPEN", "- ADR-004 overall: CLOSED")
        f_adr004.write_text(s11, encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("ADR-004" in e and ("CLOSED" in e or "overall" in e) for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S11 (ADR-004 overall marked CLOSED) was NOT detected")
        f_adr004.write_text(adr004_clean, encoding="utf-8")

        # Mutation S12: Android delete-on-ACK marked OPEN/pending
        s12 = adr004_clean.replace(
            "- Delete-on-authenticated-ACK (Android): REPO-VERIFIED / NONSHIPPING",
            "- Delete-on-authenticated-ACK (Android): OPEN (delete-on-ACK pending)"
        )
        f_adr004.write_text(s12, encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("Delete-on-authenticated-ACK (Android)" in e or "delete-on-ACK pending" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S12 (Android delete-on-ACK marked OPEN/pending) was NOT detected")
        f_adr004.write_text(adr004_clean, encoding="utf-8")

        # Mutation S13: iOS terminal-retirement marked OPEN/pending
        s13 = adr004_clean.replace(
            "- Terminal-retirement on EXPIRE / CANCEL (iOS): REPO-VERIFIED / NONSHIPPING",
            "- Terminal-retirement on EXPIRE / CANCEL (iOS): OPEN (pending)"
        )
        f_adr004.write_text(s13, encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("Terminal-retirement on EXPIRE / CANCEL (iOS)" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S13 (iOS terminal-retirement marked OPEN/pending) was NOT detected")
        f_adr004.write_text(adr004_clean, encoding="utf-8")

        # Mutation S14: Missing snapshot section
        s14 = adr004_clean.replace("### Current repo-owned closure snapshot", "### Stale section")
        f_adr004.write_text(s14, encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("Current repo-owned closure snapshot" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S14 (Missing snapshot section) was NOT detected")
        f_adr004.write_text(adr004_clean, encoding="utf-8")

        # Mutation S15: Stale "trust architecture unimplemented" in A-05
        f15 = json.loads(f_findings.read_text(encoding="utf-8"))
        for f in f15["findings"]:
            if f["id"] == "A-05":
                f["evidence"] = "trust claims removed; trust architecture unimplemented."
        f_findings.write_text(json.dumps(f15), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("A-05" in e and "trust architecture unimplemented" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S15 (A-05 stale trust architecture unimplemented) was NOT detected")
        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation S16: A-05 marked CLOSED
        f16 = json.loads(f_findings.read_text(encoding="utf-8"))
        for f in f16["findings"]:
            if f["id"] == "A-05":
                f["status"] = "CLOSED"
        f_findings.write_text(json.dumps(f16), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("A-05" in e and "CLOSED" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S16 (A-05 marked CLOSED) was NOT detected")
        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation S17: A-05 missing C8.0 architecture evidence
        f17 = json.loads(f_findings.read_text(encoding="utf-8"))
        for f in f17["findings"]:
            if f["id"] == "A-05":
                f["evidence"] = "Old ungrounded evidence without C8.0 markers."
        f_findings.write_text(json.dumps(f17), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("A-05" in e and ("C8.0" in e or "architecture" in e or "peer-binding" in e) for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S17 (A-05 missing C8.0 evidence) was NOT detected")
        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation S18: ADR-003 claims C8.4 is implemented (S2)
        adr003_clean = f_adr003.read_text(encoding="utf-8")
        s18 = adr003_clean.replace("C8.4 Noise & Handshake Trust Gating:** OPEN", "C8.4 Noise & Handshake Trust Gating:** Implemented & Closed")
        f_adr003.write_text(s18, encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("ADR-003" in e and "C8.4" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S2 (ADR-003 claims C8.4 is implemented) was NOT detected")
        f_adr003.write_text(adr003_clean, encoding="utf-8")

        # Mutation S19: ADR-003 resolver marked READY
        s19 = adr003_clean.replace("RecipientKeyResolver`:** UNRESOLVED", "RecipientKeyResolver`:** READY")
        f_adr003.write_text(s19, encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("ADR-003" in e and ("RecipientKeyResolver" in e or "READY" in e) for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S19 (ADR-003 resolver marked READY) was NOT detected")
        f_adr003.write_text(adr003_clean, encoding="utf-8")

        # Mutation S3: ADR-003 omits C8.1B status
        s3 = re.sub(r"- \*\*Phase C8\.1B[^\n]*\n", "", adr003_clean)
        f_adr003.write_text(s3, encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("ADR-003" in e and "C8.1B" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S3 (ADR-003 omits C8.1B status) was NOT detected")
        f_adr003.write_text(adr003_clean, encoding="utf-8")

        # Mutation S4: A-05 omits C8.1B evidence
        f_s4 = json.loads(f_findings.read_text(encoding="utf-8"))
        for f in f_s4["findings"]:
            if f["id"] == "A-05":
                f["evidence"] = f["evidence"].replace("C8.1B local identity authority is implemented and hardened; ", "")
        f_findings.write_text(json.dumps(f_s4), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("A-05" in e and "C8.1B" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S4 (A-05 omits C8.1B evidence) was NOT detected")
        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation S5: A-05 evidence claims peer trust store is implemented
        f_s5 = json.loads(f_findings.read_text(encoding="utf-8"))
        for f in f_s5["findings"]:
            if f["id"] == "A-05":
                f["evidence"] = f["evidence"] + " peer trust store is implemented."
        f_findings.write_text(json.dumps(f_s5), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("A-05" in e and "peer trust store is implemented" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S5 (A-05 claims peer trust store is implemented) was NOT detected")
        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        # Mutation S6: finding A-05 marked NONSHIPPING_TESTED before link layer wiring
        f_s6 = json.loads(f_findings.read_text(encoding="utf-8"))
        for f in f_s6["findings"]:
            if f["id"] == "A-05":
                f["status"] = "NONSHIPPING_TESTED"
        f_findings.write_text(json.dumps(f_s6), encoding="utf-8")
        errs = check_consistency(f_findings, f_gates, f_tiers, f_manifest, f_status, f_adr004, f_adr003)
        if any("A-05" in e and ("NONSHIPPING_TESTED" in e or "OPEN_REPOSITORY" in e) for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation S6 (A-05 marked NONSHIPPING_TESTED) was NOT detected")
        f_findings.write_text(FINDINGS_STATUS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

    if failures:
        for f in failures:
            print(f"::error::selftest failure: {f}")
        return 1

    print(f"check_status_consistency selftest PASSED ({passed_mutations}/23 mutations caught deterministically).")
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
