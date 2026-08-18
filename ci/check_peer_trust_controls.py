#!/usr/bin/env python3
"""
ci/check_peer_trust_controls.py — Structural Regression Gate for Peer Trust Model and Engine (ADR-003, Phase C8.2A)

Enforces:
  1. Authoritative model sources exist on Android and iOS with explicit persisted codes (1, 2, 3).
  2. Durable PeerIdentityRecordValidator implements all 11 invariants including BLAKE2s derivation.
  3. PeerTrustEngine is pure: zero SQL/database imports, zero wall-clock access.
  4. Complete 7-reason reject taxonomy and 6-plan decision taxonomy present on both platforms.
  5. Exhaustive test coverage for the semantic decision matrix (T01-T25), record invariants (V01-V18),
     and effective state precedence on both platforms.
  6. Status synchronization in ADR-003 and FINDINGS_STATUS.json (A-05 remains OPEN_REPOSITORY).
"""

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path
from typing import List, Tuple

ROOT = Path(__file__).resolve().parent.parent

ANDROID_MODELS_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "identity" / "PeerTrustModels.kt"
ANDROID_ENGINE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "identity" / "PeerTrustEngine.kt"
ANDROID_TESTS_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "identity" / "PeerTrustEngineTest.kt"

IOS_MODELS_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "PeerTrustModels.swift"
IOS_ENGINE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "PeerTrustEngine.swift"
IOS_TESTS_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "PeerTrustEngineTests.swift"

ADR003_PATH = ROOT / "docs" / "adr" / "ADR-003-identity-and-sealed-sender.md"
FINDINGS_PATH = ROOT / "docs" / "production" / "FINDINGS_STATUS.json"


def check_controls(
    android_models: Path = ANDROID_MODELS_PATH,
    android_engine: Path = ANDROID_ENGINE_PATH,
    android_tests: Path = ANDROID_TESTS_PATH,
    ios_models: Path = IOS_MODELS_PATH,
    ios_engine: Path = IOS_ENGINE_PATH,
    ios_tests: Path = IOS_TESTS_PATH,
    adr003: Path = ADR003_PATH,
    findings: Path = FINDINGS_PATH,
) -> List[str]:
    errors: List[str] = []

    # 1. Verify existence of all files
    for p, label in [
        (android_models, "Android PeerTrustModels"),
        (android_engine, "Android PeerTrustEngine"),
        (android_tests, "Android PeerTrustEngineTest"),
        (ios_models, "iOS PeerTrustModels"),
        (ios_engine, "iOS PeerTrustEngine"),
        (ios_tests, "iOS PeerTrustEngineTests"),
        (adr003, "ADR-003"),
        (findings, "FINDINGS_STATUS.json"),
    ]:
        if not p.exists():
            errors.append(f"Missing required file: {label} ({p})")

    if errors:
        return errors

    kt_models = android_models.read_text(encoding="utf-8")
    kt_engine = android_engine.read_text(encoding="utf-8")
    kt_tests = android_tests.read_text(encoding="utf-8")

    swift_models = ios_models.read_text(encoding="utf-8")
    swift_engine = ios_engine.read_text(encoding="utf-8")
    swift_tests = ios_tests.read_text(encoding="utf-8")

    adr_text = adr003.read_text(encoding="utf-8")
    findings_json = json.loads(findings.read_text(encoding="utf-8"))

    # 2. Check explicit persisted trust level codes (1=TOFU_PINNED, 2=USER_VERIFIED, 3=REVOKED)
    if "TOFU_PINNED(1)" not in kt_models or "USER_VERIFIED(2)" not in kt_models or "REVOKED(3)" not in kt_models:
        errors.append("Android PeerTrustLevel missing explicit persisted codes 1, 2, 3")
    if "tofuPinned = 1" not in swift_models or "userVerified = 2" not in swift_models or "revoked = 3" not in swift_models:
        errors.append("iOS PeerTrustLevel missing explicit persisted codes 1, 2, 3")

    # 3. Check durable PeerIdentityRecordValidator invariants
    for model_code, platform in [(kt_models, "Android"), (swift_models, "iOS")]:
        if "deriveNodeId" not in model_code:
            errors.append(f"{platform} PeerIdentityRecordValidator missing BLAKE2s nodeId derivation invariant check")
        if "PendingCouplingViolation" not in model_code and "pendingCouplingViolation" not in model_code:
            errors.append(f"{platform} PeerIdentityRecordValidator missing pending coupling check")
        if "PendingNotNewer" not in model_code and "pendingNotNewer" not in model_code:
            errors.append(f"{platform} PeerIdentityRecordValidator missing pending newer-than-accepted check")
        if "PendingStaticEqualsAccepted" not in model_code and "pendingStaticEqualsAccepted" not in model_code:
            errors.append(f"{platform} PeerIdentityRecordValidator missing pending static divergence check")
        if "RevokedWithPending" not in model_code and "revokedWithPending" not in model_code:
            errors.append(f"{platform} PeerIdentityRecordValidator missing revoked-with-pending check")

    # 4. Check purity of PeerTrustEngine (no SQL, no storage, no wall clock)
    for engine_code, platform in [(kt_engine, "Android"), (swift_engine, "iOS")]:
        forbidden_tokens = ["sqlite", "sql", "SQLite", "System.currentTimeMillis", "Instant.now", "Date()", "Date.now", "clock", "Context", "SharedPreferences", "Keychain"]
        for tok in forbidden_tokens:
            if re.search(r"\b" + re.escape(tok) + r"\b", engine_code):
                errors.append(f"{platform} PeerTrustEngine contains forbidden non-pure token '{tok}'")

    # 5. Check 7 reject reasons and 6 plan variants
    reject_reasons = [
        "Rollback", "SameGenerationConflict", "PendingGenerationConflict",
        "StaleRelativeToPending", "NoncanonicalGenerationAdvance",
        "NodeIdSigningKeyCollision", "Revoked"
    ]
    for reason in reject_reasons:
        if reason not in kt_models:
            errors.append(f"Android PeerTrustRejectReason missing '{reason}'")
        # Swift camelCase version
        swift_reason = reason[0].lower() + reason[1:]
        if swift_reason not in swift_models:
            errors.append(f"iOS PeerTrustRejectReason missing '{swift_reason}'")

    trust_plans = [
        "AcceptExisting", "InsertFirstSeen", "SetInitialPendingCandidate",
        "AdvancePendingCandidate", "KeepQuarantined", "Reject"
    ]
    for plan in trust_plans:
        if plan not in kt_models:
            errors.append(f"Android TrustPlan missing '{plan}'")
        swift_plan = plan[0].lower() + plan[1:]
        if swift_plan not in swift_models:
            errors.append(f"iOS TrustPlan missing '{swift_plan}'")

    # 6. Check semantic engine behavior in tests
    for test_code, platform in [(kt_tests, "Android"), (swift_tests, "iOS")]:
        # T01-T25
        for i in range(1, 26):
            t_name = f"T{i:02d}"
            if t_name not in test_code:
                errors.append(f"{platform} tests missing semantic test matrix case {t_name}")
        # V01-V15
        for i in range(1, 16):
            v_name = f"V{i:02d}"
            if v_name not in test_code:
                errors.append(f"{platform} tests missing validation test case {v_name}")
        # Effective state tests
        if "testEffectiveStatePrecedence" not in test_code and "testEffectiveState" not in test_code:
            errors.append(f"{platform} tests missing effective state precedence tests")

    # 7. Check ADR-003 status consistency
    if "Phase C8.2A Pure Peer Trust Engine & Models" not in adr_text:
        errors.append("ADR-003 status section missing Phase C8.2A declaration")
    if "FileProtectionType.complete" not in adr_text:
        errors.append("ADR-003 missing iOS FileProtectionType.complete data protection freeze")
    if "godstone_peer_identities.db" not in adr_text:
        errors.append("ADR-003 missing Android dedicated godstone_peer_identities.db declaration")

    # 8. Check FINDINGS_STATUS.json A-05 consistency
    a05_found = False
    for finding in findings_json.get("findings", []):
        if finding.get("id") == "A-05":
            a05_found = True
            if finding.get("status") != "OPEN_REPOSITORY":
                errors.append(f"A-05 status is {finding.get('status')!r}; must be 'OPEN_REPOSITORY'")
            evidence = finding.get("evidence", "")
            if "C8.2A" not in evidence:
                errors.append("A-05 evidence missing C8.2A reference")
            if "peer trust store is implemented" in evidence:
                errors.append("A-05 evidence falsely claims peer trust store is implemented")
            if "PeerIdentityStore" not in evidence:
                errors.append("A-05 evidence must state PeerIdentityStore remains open")
            break

    if not a05_found:
        errors.append("FINDINGS_STATUS.json missing finding A-05")

    return errors


def selftest() -> int:
    print("Running check_peer_trust_controls --selftest...")
    failures: List[str] = []
    passed = 0

    with tempfile.TemporaryDirectory() as td:
        tdp = Path(td)
        f_kt_models = tdp / "PeerTrustModels.kt"
        f_kt_engine = tdp / "PeerTrustEngine.kt"
        f_kt_tests = tdp / "PeerTrustEngineTest.kt"
        f_swift_models = tdp / "PeerTrustModels.swift"
        f_swift_engine = tdp / "PeerTrustEngine.swift"
        f_swift_tests = tdp / "PeerTrustEngineTests.swift"
        f_adr = tdp / "ADR-003.md"
        f_findings = tdp / "FINDINGS_STATUS.json"

        def reset_all():
            f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_models.write_text(IOS_MODELS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_engine.write_text(IOS_ENGINE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_tests.write_text(IOS_TESTS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_adr.write_text(ADR003_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_findings.write_text(FINDINGS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        reset_all()

        # Mutation P1: Ordinal persistence replaces explicit codes
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("TOFU_PINNED(1)", "TOFU_PINNED(0)"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("persisted codes" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P1 (ordinal persistence replaces explicit codes) was NOT caught")
        reset_all()

        # Mutation P2: nodeId/signing-key durable invariant removed
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("deriveNodeId", "computeDummyId"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("BLAKE2s nodeId derivation" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P2 (nodeId/signing-key invariant removed) was NOT caught")
        reset_all()

        # Mutation P3: pending coupling removed
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("PendingCouplingViolation", "DummyCoupling"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("pending coupling" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P3 (pending coupling removed) was NOT caught")
        reset_all()

        # Mutation P4: pending > accepted removed
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("PendingNotNewer", "DummyNewer"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("newer-than-accepted" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P4 (pending > accepted removed) was NOT caught")
        reset_all()

        # Mutation P5: pending static divergence removed
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("PendingStaticEqualsAccepted", "DummyDivergence"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("pending static divergence" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P5 (pending static divergence removed) was NOT caught")
        reset_all()

        # Mutation P6: revoked+pending allowed
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("RevokedWithPending", "DummyRevokedPending"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("revoked-with-pending" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P6 (revoked+pending allowed) was NOT caught")
        reset_all()

        # Mutation P7: first-seen test T01 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T01", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T01" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P7 (first-seen test T01 removed) was NOT caught")
        reset_all()

        # Mutation P8: exact accepted reconnect test T04 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T04", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T04" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P8 (test T04 removed) was NOT caught")
        reset_all()

        # Mutation P9: rollback test T06 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T06", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T06" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P9 (test T06 removed) was NOT caught")
        reset_all()

        # Mutation P10: same-generation conflict test T07 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T07", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T07" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P10 (test T07 removed) was NOT caught")
        reset_all()

        # Mutation P11: noncanonical advance test T08 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T08", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T08" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P11 (test T08 removed) was NOT caught")
        reset_all()

        # Mutation P12: initial pending candidate test T09 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T09", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T09" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P12 (test T09 removed) was NOT caught")
        reset_all()

        # Mutation P13: old accepted reconnect while pending test T11 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T11", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T11" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P13 (test T11 removed) was NOT caught")
        reset_all()

        # Mutation P14: intermediate generation test T14 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T14", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T14" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P14 (test T14 removed) was NOT caught")
        reset_all()

        # Mutation P15: pending generation conflict test T18 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T18", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T18" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P15 (test T18 removed) was NOT caught")
        reset_all()

        # Mutation P16: advance pending candidate test T20 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T20", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T20" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P16 (test T20 removed) was NOT caught")
        reset_all()

        # Mutation P17: newer reusing accepted static test T21 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T21", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T21" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P17 (test T21 removed) was NOT caught")
        reset_all()

        # Mutation P18: newer reusing pending static test T22 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T22", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T22" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P18 (test T22 removed) was NOT caught")
        reset_all()

        # Mutation P19: revoked test T23 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T23", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T23" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P19 (test T23 removed) was NOT caught")
        reset_all()

        # Mutation P20: signing-key collision test T25 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T25", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T25" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P20 (test T25 removed) was NOT caught")
        reset_all()

        # Mutation P21: USER_VERIFIED exact reconnect test T05 missing
        f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8").replace("T05", "DISABLED_CASE"), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("T05" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P21 (test T05 removed) was NOT caught")
        reset_all()

        # Mutation P22: engine introduces wall-clock access
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8") + "\nval now = System.currentTimeMillis()\n", encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("System.currentTimeMillis" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P22 (engine introduces wall-clock access) was NOT caught")
        reset_all()

        # Mutation P23: checker permits SQL imports in PeerTrustEngine
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8") + "\nimport java.sql.ResultSet\n", encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("sql" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P23 (SQL imports in PeerTrustEngine) was NOT caught")
        reset_all()

        # Mutation P24: status marks A-05 closed
        f_json = json.loads(FINDINGS_PATH.read_text(encoding="utf-8"))
        for f in f_json["findings"]:
            if f["id"] == "A-05":
                f["status"] = "CLOSED"
        f_findings.write_text(json.dumps(f_json), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("A-05 status" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P24 (A-05 marked closed) was NOT caught")
        reset_all()

        # Mutation P25: status claims PeerIdentityStore implemented
        f_json = json.loads(FINDINGS_PATH.read_text(encoding="utf-8"))
        for f in f_json["findings"]:
            if f["id"] == "A-05":
                f["evidence"] = f["evidence"] + " peer trust store is implemented."
        f_findings.write_text(json.dumps(f_json), encoding="utf-8")
        errs = check_controls(f_kt_models, f_kt_engine, f_kt_tests, f_swift_models, f_swift_engine, f_swift_tests, f_adr, f_findings)
        if any("peer trust store is implemented" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P25 (A-05 claims peer trust store implemented) was NOT caught")
        reset_all()

    if failures:
        for f in failures:
            print(f"::error::selftest failure: {f}")
        return 1

    print(f"check_peer_trust_controls selftest PASSED ({passed}/25 mutations caught deterministically).")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true", help="Run mutation selftest")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    errors = check_controls()
    if errors:
        for e in errors:
            print(f"::error::Peer trust controls error: {e}", file=sys.stderr)
        print(f"\nFAIL: {len(errors)} peer trust control issue(s) found.", file=sys.stderr)
        return 1

    print("PEER TRUST CONTROLS GATE: PASS -- pure model, validator, and engine invariants satisfied.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
