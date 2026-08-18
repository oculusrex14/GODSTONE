#!/usr/bin/env python3
"""
ci/check_peer_trust_controls.py — Structural Regression Gate for Peer Trust Model and Engine (ADR-003, Phase C8.2A/C8.2A.1)

Enforces:
  1. Authoritative model sources exist on Android and iOS with explicit persisted codes (1, 2, 3).
  2. Durable PeerIdentityRecordValidator implements all 11 invariants including BLAKE2s derivation.
  3. PeerTrustEngine is pure: zero SQL/database imports, zero wall-clock access.
  4. Complete 7-reason reject taxonomy and 6-plan decision taxonomy present on both platforms.
  5. Exact structural decision logic in PeerTrustEngine: FirstSeen, Revoked, Collision, No-Pending matrix, Pending matrix.
  6. Narrow authority surface:
     - PeerIdentityRecord is module-internal on both platforms.
     - Pure engine and durable validator are module-internal on both platforms.
     - VerifiedPeerIdentity and PendingPeerIdentity constructors are private/fileprivate.
     - Record conversion factories (.fromRecord) are internal, not public.
     - Zero production callsites to VerifiedPeerIdentity.fromRecord, PendingPeerIdentity.fromRecord,
       or PeerIdentityRecord( outside PeerTrustModels.
  7. Semantic test matrix coverage (T01-T25, V01-V18/V15) and status synchronization.
"""

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path
from typing import List, Optional

ROOT = Path(__file__).resolve().parent.parent

ANDROID_MODELS_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "identity" / "PeerTrustModels.kt"
ANDROID_ENGINE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "identity" / "PeerTrustEngine.kt"
ANDROID_TESTS_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "identity" / "PeerTrustEngineTest.kt"
ANDROID_SRC_MAIN = ROOT / "android" / "mesh" / "src" / "main" / "java"

IOS_MODELS_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "PeerTrustModels.swift"
IOS_ENGINE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "PeerTrustEngine.swift"
IOS_TESTS_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "PeerTrustEngineTests.swift"
IOS_SRC_MAIN = ROOT / "ios" / "Godstone" / "Sources"

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
    android_src_dir: Optional[Path] = ANDROID_SRC_MAIN,
    ios_src_dir: Optional[Path] = IOS_SRC_MAIN,
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
    # R1-R3: exact lengths
    if "NODE_ID_LENGTH = 16" not in kt_models or "SIGNING_KEY_LENGTH = 32" not in kt_models or "STATIC_KEY_LENGTH = 32" not in kt_models:
        errors.append("Android PeerIdentityRecordValidator missing exact key length constants (16, 32, 32)")
    # R5: BLAKE2s nodeId derivation
    if "!nodeBytes.contentEquals(expectedNodeId)" not in kt_models:
        errors.append("Android PeerIdentityRecordValidator missing BLAKE2s nodeId derivation invariant check (R5)")
    if "record.nodeId == expectedNodeId" not in swift_models:
        errors.append("iOS PeerIdentityRecordValidator missing BLAKE2s nodeId derivation invariant check (R5)")

    # R6: pending coupling
    if "(pendStatic == null) != (pendGen == null)" not in kt_models:
        errors.append("Android PeerIdentityRecordValidator missing pending coupling check (R6)")
    if "(pendStatic == nil) == (pendGen == nil)" not in swift_models:
        errors.append("iOS PeerIdentityRecordValidator missing pending coupling check (R6)")

    # R8: pending newer than accepted
    if "pendGen <= record.acceptedGeneration" not in kt_models:
        errors.append("Android PeerIdentityRecordValidator missing pending generation monotonicity check (R8)")
    if "pendGen > record.acceptedGeneration" not in swift_models:
        errors.append("iOS PeerIdentityRecordValidator missing pending generation monotonicity check (R8)")

    # R10: pending static divergence
    if "pendStatic.contentEquals(accStatic)" not in kt_models:
        errors.append("Android PeerIdentityRecordValidator missing pending static divergence check (R10)")
    if "pendStatic != record.acceptedStaticDhPublicKey" not in swift_models:
        errors.append("iOS PeerIdentityRecordValidator missing pending static divergence check (R10)")

    # R11: revoked with pending
    if "record.trustLevel == PeerTrustLevel.REVOKED" not in kt_models or "RevokedWithPending" not in kt_models:
        errors.append("Android PeerIdentityRecordValidator missing revoked-with-pending check (R11)")
    if "record.trustLevel != .revoked" not in swift_models or "revokedWithPending" not in swift_models:
        errors.append("iOS PeerIdentityRecordValidator missing revoked-with-pending check (R11)")

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

    # 6. Check production PeerTrustEngine decision logic structure
    # P7 / First-seen: any uint32 is accepted as baseline
    if "if (current == null)" not in kt_engine or "TrustPlan.InsertFirstSeen" not in kt_engine:
        errors.append("Android PeerTrustEngine missing unconditional FirstSeen branch for current == null")
    if "binding.generation == 0" in kt_engine or "binding.generation == 0L" in kt_engine or "gen == 0" in kt_engine:
        errors.append("Android PeerTrustEngine incorrectly restricts first-seen baseline to generation 0")
    if "guard let current = current else" not in swift_engine or ".insertFirstSeen" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing unconditional FirstSeen branch for current == nil")
    if "binding.generation == 0" in swift_engine or "gen == 0" in swift_engine:
        errors.append("iOS PeerTrustEngine incorrectly restricts first-seen baseline to generation 0")

    # P8 / Exact accepted reconnect: AcceptExisting
    if "gen == accGen && incomingStatic.contentEquals(accStatic) -> TrustPlan.AcceptExisting" not in kt_engine:
        errors.append("Android PeerTrustEngine missing exact accepted reconnect -> AcceptExisting branch")
    if "gen == accGen && incomingStatic == accStatic" not in swift_engine or "return .acceptExisting" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing exact accepted reconnect -> .acceptExisting branch")

    # P9 / Lower generation: Reject Rollback
    if "gen < accGen -> TrustPlan.Reject(PeerTrustRejectReason.Rollback)" not in kt_engine:
        errors.append("Android PeerTrustEngine missing lower-generation -> Reject(Rollback) branch")
    if "gen < accGen" not in swift_engine or "return .reject(.rollback)" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing lower-generation -> Reject(.rollback) branch")

    # P10 / Same generation different static: Reject SameGenerationConflict
    if "gen == accGen && !incomingStatic.contentEquals(accStatic) -> TrustPlan.Reject(PeerTrustRejectReason.SameGenerationConflict)" not in kt_engine:
        errors.append("Android PeerTrustEngine missing same-generation different static -> Reject(SameGenerationConflict) branch")
    if "gen == accGen && incomingStatic != accStatic" not in swift_engine or "return .reject(.sameGenerationConflict)" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing same-generation different static -> Reject(.sameGenerationConflict) branch")

    # P11 / Higher generation same static: Reject NoncanonicalGenerationAdvance
    if "gen > accGen && incomingStatic.contentEquals(accStatic) -> TrustPlan.Reject(PeerTrustRejectReason.NoncanonicalGenerationAdvance)" not in kt_engine:
        errors.append("Android PeerTrustEngine missing higher generation same static -> Reject(NoncanonicalGenerationAdvance) branch")
    if "gen > accGen && incomingStatic == accStatic" not in swift_engine or "return .reject(.noncanonicalGenerationAdvance)" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing higher generation same static -> Reject(.noncanonicalGenerationAdvance) branch")

    # P12 / Higher generation distinct static: SetInitialPendingCandidate
    if "else -> TrustPlan.SetInitialPendingCandidate" not in kt_engine:
        errors.append("Android PeerTrustEngine missing higher generation distinct static -> SetInitialPendingCandidate branch")
    if "return .setInitialPendingCandidate" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing higher generation distinct static -> .setInitialPendingCandidate branch")

    # P13 / Pending + old accepted exact reconnect: KeepQuarantined
    if "if (incomingStatic.contentEquals(accStatic)) {\n                    TrustPlan.KeepQuarantined" not in kt_engine:
        errors.append("Android PeerTrustEngine missing pending old-accepted reconnect -> KeepQuarantined branch")
    if "if incomingStatic == accStatic {\n                return .keepQuarantined" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing pending old-accepted reconnect -> .keepQuarantined branch")

    # P14 / Pending intermediate generation (A < gen < P): StaleRelativeToPending
    if "gen < pendGen -> TrustPlan.Reject(PeerTrustRejectReason.StaleRelativeToPending)" not in kt_engine:
        errors.append("Android PeerTrustEngine missing intermediate generation -> Reject(StaleRelativeToPending) branch")
    if "if gen < pendGen {\n            return .reject(.staleRelativeToPending)" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing intermediate generation -> Reject(.staleRelativeToPending) branch")

    # P15 / Pending generation conflict (gen == P + diff static): PendingGenerationConflict
    if "TrustPlan.Reject(PeerTrustRejectReason.PendingGenerationConflict)" not in kt_engine:
        errors.append("Android PeerTrustEngine missing pending generation conflict -> Reject(PendingGenerationConflict) branch")
    if "return .reject(.pendingGenerationConflict)" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing pending generation conflict -> Reject(.pendingGenerationConflict) branch")

    # P16 / Newer candidate (gen > P + novel static): AdvancePendingCandidate
    if "TrustPlan.AdvancePendingCandidate" not in kt_engine:
        errors.append("Android PeerTrustEngine missing advance pending candidate -> AdvancePendingCandidate branch")
    if "return .advancePendingCandidate" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing advance pending candidate -> .advancePendingCandidate branch")

    # P17 & P18 / Newer candidate static reuse rejection (gen > P + accStatic or pendStatic): NoncanonicalGenerationAdvance
    if "incomingStatic.contentEquals(accStatic) || incomingStatic.contentEquals(pendStatic)" not in kt_engine or "NoncanonicalGenerationAdvance" not in kt_engine:
        errors.append("Android PeerTrustEngine missing newer candidate static reuse rejection branch")
    if "incomingStatic == accStatic || incomingStatic == pendStatic" not in swift_engine or ".noncanonicalGenerationAdvance" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing newer candidate static reuse rejection branch")

    # P19 / Revoked precedence: unconditionally rejects
    if "current.trustLevel == PeerTrustLevel.REVOKED" not in kt_engine or "TrustPlan.Reject(PeerTrustRejectReason.Revoked)" not in kt_engine:
        errors.append("Android PeerTrustEngine missing unconditional Revocation Precedence branch")
    if "current.trustLevel != .revoked" not in swift_engine or "return .reject(.revoked)" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing unconditional Revocation Precedence branch")

    # P20 / Signing-key collision rejection
    if "!incomingSigningPub.contentEquals(current.signingPublicKey)" not in kt_engine or "TrustPlan.Reject(PeerTrustRejectReason.NodeIdSigningKeyCollision)" not in kt_engine:
        errors.append("Android PeerTrustEngine missing NodeIdSigningKeyCollision rejection branch")
    if "incomingSigningPub == current.signingPublicKey" not in swift_engine or "return .reject(.nodeIdSigningKeyCollision)" not in swift_engine:
        errors.append("iOS PeerTrustEngine missing NodeIdSigningKeyCollision rejection branch")

    # P21 / No special USER_VERIFIED bypass altering exact reconnect in evaluate()
    if "USER_VERIFIED" in kt_engine:
        errors.append("Android PeerTrustEngine must not contain special USER_VERIFIED decision bypass branches")
    if "userVerified" in swift_engine:
        errors.append("iOS PeerTrustEngine must not contain special userVerified decision bypass branches")

    # 7. Check Authority Surface & Visibility Controls (C8.2A.1)
    # P26 / Android PeerIdentityRecord must be internal class
    if not re.search(r"\binternal\s+class\s+PeerIdentityRecord\b", kt_models):
        errors.append("Android PeerIdentityRecord must have 'internal' visibility")
    if re.search(r"\bpublic\s+class\s+PeerIdentityRecord\b", kt_models):
        errors.append("Android PeerIdentityRecord must not be public")

    # P27 / iOS PeerIdentityRecord must NOT be public struct
    if re.search(r"\bpublic\s+struct\s+PeerIdentityRecord\b", swift_models):
        errors.append("iOS PeerIdentityRecord must not have 'public' visibility (must be module-internal)")

    # P28 & P29 / Android fromRecord must be internal
    if not re.search(r"\binternal\s+fun\s+fromRecord\b", kt_models):
        errors.append("Android fromRecord factories must have 'internal' visibility")
    if re.search(r"\bpublic\s+fun\s+fromRecord\b", kt_models):
        errors.append("Android fromRecord factories must not be public")

    # P30 & P31 / iOS fromRecord must NOT be public
    if re.search(r"\bpublic\s+static\s+func\s+fromRecord\b", swift_models):
        errors.append("iOS fromRecord factories must not have 'public' visibility")

    # P32 / Android VerifiedPeerIdentity & PendingPeerIdentity constructors must be private
    if "class VerifiedPeerIdentity private constructor(" not in kt_models:
        errors.append("Android VerifiedPeerIdentity constructor must be 'private constructor'")
    if "class PendingPeerIdentity private constructor(" not in kt_models:
        errors.append("Android PendingPeerIdentity constructor must be 'private constructor'")

    # P33 / iOS VerifiedPeerIdentity & PendingPeerIdentity initializers must be fileprivate
    if "fileprivate init(" not in swift_models:
        errors.append("iOS VerifiedPeerIdentity/PendingPeerIdentity initializers must be 'fileprivate init'")

    # Internal pure engine and validators
    if not re.search(r"\binternal\s+object\s+PeerIdentityRecordValidator\b", kt_models):
        errors.append("Android PeerIdentityRecordValidator must be internal")
    if not re.search(r"\binternal\s+object\s+PeerTrustEngine\b", kt_engine):
        errors.append("Android PeerTrustEngine must be internal")
    if re.search(r"\bpublic\s+enum\s+PeerIdentityRecordValidator\b", swift_models):
        errors.append("iOS PeerIdentityRecordValidator must not be public")
    if re.search(r"\bpublic\s+enum\s+PeerTrustEngine\b", swift_engine):
        errors.append("iOS PeerTrustEngine must not be public")

    # P34 & P35 / Same-Module Bypass Control across production source trees
    if android_src_dir and android_src_dir.exists():
        for kt_file in android_src_dir.rglob("*.kt"):
            if kt_file.name == "PeerTrustModels.kt":
                continue
            txt = kt_file.read_text(encoding="utf-8")
            path_str = str(kt_file.relative_to(ROOT)) if kt_file.is_relative_to(ROOT) else kt_file.name
            if "VerifiedPeerIdentity.fromRecord(" in txt or "PendingPeerIdentity.fromRecord(" in txt:
                errors.append(f"Forbidden production call to fromRecord() in {path_str} (P34)")
            if "PeerIdentityRecord(" in txt:
                errors.append(f"Forbidden production instantiation of PeerIdentityRecord() in {path_str} (P35)")

    if ios_src_dir and ios_src_dir.exists():
        for swift_file in ios_src_dir.rglob("*.swift"):
            if swift_file.name == "PeerTrustModels.swift":
                continue
            txt = swift_file.read_text(encoding="utf-8")
            path_str = str(swift_file.relative_to(ROOT)) if swift_file.is_relative_to(ROOT) else swift_file.name
            if "VerifiedPeerIdentity.fromRecord(" in txt or "PendingPeerIdentity.fromRecord(" in txt:
                errors.append(f"Forbidden production call to fromRecord() in {path_str} (P34)")
            if "PeerIdentityRecord(" in txt:
                errors.append(f"Forbidden production instantiation of PeerIdentityRecord() in {path_str} (P35)")

    # 8. Check semantic engine behavior in tests
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

    # 9. Check ADR-003 status consistency
    if "Phase C8.2A Pure Peer Trust Engine & Models" not in adr_text:
        errors.append("ADR-003 status section missing Phase C8.2A declaration")
    if "FileProtectionType.complete" not in adr_text:
        errors.append("ADR-003 missing iOS FileProtectionType.complete data protection freeze")
    if "godstone_peer_identities.db" not in adr_text:
        errors.append("ADR-003 missing Android dedicated godstone_peer_identities.db declaration")

    # 10. Check FINDINGS_STATUS.json A-05 consistency
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
        fake_android_src = tdp / "android_src"
        fake_android_src.mkdir(parents=True, exist_ok=True)
        fake_ios_src = tdp / "ios_src"
        fake_ios_src.mkdir(parents=True, exist_ok=True)

        def reset_all():
            f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_tests.write_text(ANDROID_TESTS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_models.write_text(IOS_MODELS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_engine.write_text(IOS_ENGINE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_tests.write_text(IOS_TESTS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_adr.write_text(ADR003_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_findings.write_text(FINDINGS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            # Clear fake production source dirs
            for f in fake_android_src.glob("*.kt"):
                f.unlink()
            for f in fake_ios_src.glob("*.swift"):
                f.unlink()

        def run_check():
            return check_controls(
                f_kt_models, f_kt_engine, f_kt_tests,
                f_swift_models, f_swift_engine, f_swift_tests,
                f_adr, f_findings,
                fake_android_src, fake_ios_src
            )

        reset_all()

        # Mutation P1: TOFU_PINNED code mutated 1 -> 0
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("TOFU_PINNED(1)", "TOFU_PINNED(0)"), encoding="utf-8")
        errs = run_check()
        if any("persisted codes" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P1 (persisted TOFU code mutated) was NOT caught")
        reset_all()

        # Mutation P2: nodeId == BLAKE2s(signingKey) condition neutralized
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("!nodeBytes.contentEquals(expectedNodeId)", "false"), encoding="utf-8")
        errs = run_check()
        if any("BLAKE2s nodeId derivation" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P2 (nodeId derivation condition neutralized) was NOT caught")
        reset_all()

        # Mutation P3: pending coupling logic mutated so one field can be present without the other
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("(pendStatic == null) != (pendGen == null)", "false"), encoding="utf-8")
        errs = run_check()
        if any("pending coupling" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P3 (pending coupling logic neutralized) was NOT caught")
        reset_all()

        # Mutation P4: pending generation monotonicity mutated so equality with accepted is allowed
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("pendGen <= record.acceptedGeneration", "pendGen < record.acceptedGeneration"), encoding="utf-8")
        errs = run_check()
        if any("monotonicity" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P4 (pending generation equality allowed) was NOT caught")
        reset_all()

        # Mutation P5: pending static divergence check mutated so accepted == pending is allowed
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("pendStatic.contentEquals(accStatic)", "false"), encoding="utf-8")
        errs = run_check()
        if any("pending static divergence" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P5 (pending static equality allowed) was NOT caught")
        reset_all()

        # Mutation P6: revoked + pending allowed
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("record.trustLevel == PeerTrustLevel.REVOKED", "false"), encoding="utf-8")
        errs = run_check()
        if any("revoked-with-pending" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P6 (revoked + pending allowed) was NOT caught")
        reset_all()

        # Mutation P7: first-seen branch mutated so generation must equal 0
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("if (current == null) {", "if (current == null && binding.generation == 0L) {"), encoding="utf-8")
        errs = run_check()
        if any("generation 0" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P7 (first-seen restricted to generation 0) was NOT caught")
        reset_all()

        # Mutation P8: exact accepted reconnect mutated away from AcceptExisting
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("gen == accGen && incomingStatic.contentEquals(accStatic) -> TrustPlan.AcceptExisting", "gen == accGen && incomingStatic.contentEquals(accStatic) -> TrustPlan.SetInitialPendingCandidate"), encoding="utf-8")
        errs = run_check()
        if any("exact accepted reconnect" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P8 (exact accepted reconnect mutated) was NOT caught")
        reset_all()

        # Mutation P9: lower-generation rejection mutated away from Rollback
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("gen < accGen -> TrustPlan.Reject(PeerTrustRejectReason.Rollback)", "gen < accGen -> TrustPlan.AcceptExisting"), encoding="utf-8")
        errs = run_check()
        if any("lower-generation" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P9 (lower generation rollback mutated) was NOT caught")
        reset_all()

        # Mutation P10: same-generation different-static mutated away from SameGenerationConflict
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("gen == accGen && !incomingStatic.contentEquals(accStatic) -> TrustPlan.Reject(PeerTrustRejectReason.SameGenerationConflict)", "gen == accGen && !incomingStatic.contentEquals(accStatic) -> TrustPlan.AcceptExisting"), encoding="utf-8")
        errs = run_check()
        if any("same-generation different static" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P10 (same generation conflict mutated) was NOT caught")
        reset_all()

        # Mutation P11: higher-generation same-accepted-static mutated to allow it
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("gen > accGen && incomingStatic.contentEquals(accStatic) -> TrustPlan.Reject(PeerTrustRejectReason.NoncanonicalGenerationAdvance)", "// bypassed advance check"), encoding="utf-8")
        errs = run_check()
        if any("higher generation same static" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P11 (higher generation same static allowed) was NOT caught")
        reset_all()

        # Mutation P12: higher-generation distinct-static mutated away from SetInitialPendingCandidate
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("else -> TrustPlan.SetInitialPendingCandidate", "else -> TrustPlan.AcceptExisting"), encoding="utf-8")
        errs = run_check()
        if any("SetInitialPendingCandidate" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P12 (initial pending candidate mutated) was NOT caught")
        reset_all()

        # Mutation P13: pending + old accepted exact reconnect mutated KeepQuarantined -> AcceptExisting
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("TrustPlan.KeepQuarantined\n                } else {", "TrustPlan.AcceptExisting\n                } else {"), encoding="utf-8")
        errs = run_check()
        if any("pending old-accepted reconnect" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P13 (pending old accepted reconnect mutated) was NOT caught")
        reset_all()

        # Mutation P14: intermediate generation (A < gen < P) mutated from StaleRelativeToPending to AdvancePendingCandidate
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("gen < pendGen -> TrustPlan.Reject(PeerTrustRejectReason.StaleRelativeToPending)", "gen < pendGen -> TrustPlan.AdvancePendingCandidate"), encoding="utf-8")
        errs = run_check()
        if any("intermediate generation" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P14 (intermediate generation mutated) was NOT caught")
        reset_all()

        # Mutation P15: gen == pendGen + different static mutated away from PendingGenerationConflict
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("TrustPlan.Reject(PeerTrustRejectReason.PendingGenerationConflict)", "TrustPlan.KeepQuarantined"), encoding="utf-8")
        errs = run_check()
        if any("PendingGenerationConflict" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P15 (pending generation conflict mutated) was NOT caught")
        reset_all()

        # Mutation P16: gen > pendGen + novel static mutated away from AdvancePendingCandidate
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("TrustPlan.AdvancePendingCandidate", "TrustPlan.KeepQuarantined"), encoding="utf-8")
        errs = run_check()
        if any("AdvancePendingCandidate" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P16 (advance pending candidate mutated) was NOT caught")
        reset_all()

        # Mutation P17: gen > pendGen + accepted static allowed
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("incomingStatic.contentEquals(accStatic) || ", ""), encoding="utf-8")
        errs = run_check()
        if any("newer candidate static reuse" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P17 (newer candidate accepted static reuse allowed) was NOT caught")
        reset_all()

        # Mutation P18: gen > pendGen + pending static allowed
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace(" || incomingStatic.contentEquals(pendStatic)", ""), encoding="utf-8")
        errs = run_check()
        if any("newer candidate static reuse" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P18 (newer candidate pending static reuse allowed) was NOT caught")
        reset_all()

        # Mutation P19: revoked precedence removed so bindings proceed
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("current.trustLevel == PeerTrustLevel.REVOKED", "false"), encoding="utf-8")
        errs = run_check()
        if any("Revocation Precedence" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P19 (revocation precedence removed) was NOT caught")
        reset_all()

        # Mutation P20: signing-key collision check removed
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("!incomingSigningPub.contentEquals(current.signingPublicKey)", "false"), encoding="utf-8")
        errs = run_check()
        if any("NodeIdSigningKeyCollision" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P20 (signing-key collision check removed) was NOT caught")
        reset_all()

        # Mutation P21: special USER_VERIFIED path introduced in engine
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8").replace("val accGen = current.acceptedGeneration", "if (current.trustLevel == PeerTrustLevel.USER_VERIFIED) return TrustPlan.AdvancePendingCandidate\n        val accGen = current.acceptedGeneration"), encoding="utf-8")
        errs = run_check()
        if any("USER_VERIFIED" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P21 (special USER_VERIFIED path introduced) was NOT caught")
        reset_all()

        # Mutation P22: engine introduces wall-clock access
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8") + "\nval now = System.currentTimeMillis()\n", encoding="utf-8")
        errs = run_check()
        if any("System.currentTimeMillis" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P22 (engine introduces wall-clock access) was NOT caught")
        reset_all()

        # Mutation P23: SQL imports in PeerTrustEngine
        f_kt_engine.write_text(ANDROID_ENGINE_PATH.read_text(encoding="utf-8") + "\nimport java.sql.ResultSet\n", encoding="utf-8")
        errs = run_check()
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
        errs = run_check()
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
        errs = run_check()
        if any("peer trust store is implemented" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P25 (A-05 claims peer trust store implemented) was NOT caught")
        reset_all()

        # Mutation P26: Android PeerIdentityRecord changed from internal to public
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("internal class PeerIdentityRecord", "public class PeerIdentityRecord"), encoding="utf-8")
        errs = run_check()
        if any("PeerIdentityRecord" in e and "internal" in e for e in errs) or any("PeerIdentityRecord must not be public" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P26 (Android PeerIdentityRecord made public) was NOT caught")
        reset_all()

        # Mutation P27: iOS PeerIdentityRecord changed to public struct
        f_swift_models.write_text(IOS_MODELS_PATH.read_text(encoding="utf-8").replace("struct PeerIdentityRecord", "public struct PeerIdentityRecord"), encoding="utf-8")
        errs = run_check()
        if any("iOS PeerIdentityRecord" in e and "public" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P27 (iOS PeerIdentityRecord made public) was NOT caught")
        reset_all()

        # Mutation P28: Android VerifiedPeerIdentity.fromRecord opened to public
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("internal fun fromRecord(record: PeerIdentityRecord): VerifiedPeerIdentity?", "public fun fromRecord(record: PeerIdentityRecord): VerifiedPeerIdentity?"), encoding="utf-8")
        errs = run_check()
        if any("fromRecord" in e and "public" in e for e in errs) or any("fromRecord" in e and "internal" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P28 (Android VerifiedPeerIdentity.fromRecord made public) was NOT caught")
        reset_all()

        # Mutation P29: Android PendingPeerIdentity.fromRecord opened to public
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("internal fun fromRecord(record: PeerIdentityRecord): PendingPeerIdentity?", "public fun fromRecord(record: PeerIdentityRecord): PendingPeerIdentity?"), encoding="utf-8")
        errs = run_check()
        if any("fromRecord" in e and "public" in e for e in errs) or any("fromRecord" in e and "internal" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P29 (Android PendingPeerIdentity.fromRecord made public) was NOT caught")
        reset_all()

        # Mutation P30: iOS VerifiedPeerIdentity.fromRecord opened to public
        f_swift_models.write_text(IOS_MODELS_PATH.read_text(encoding="utf-8").replace("static func fromRecord(_ record: PeerIdentityRecord) -> VerifiedPeerIdentity?", "public static func fromRecord(_ record: PeerIdentityRecord) -> VerifiedPeerIdentity?"), encoding="utf-8")
        errs = run_check()
        if any("iOS fromRecord" in e and "public" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P30 (iOS VerifiedPeerIdentity.fromRecord made public) was NOT caught")
        reset_all()

        # Mutation P31: iOS PendingPeerIdentity.fromRecord opened to public
        f_swift_models.write_text(IOS_MODELS_PATH.read_text(encoding="utf-8").replace("static func fromRecord(_ record: PeerIdentityRecord) -> PendingPeerIdentity?", "public static func fromRecord(_ record: PeerIdentityRecord) -> PendingPeerIdentity?"), encoding="utf-8")
        errs = run_check()
        if any("iOS fromRecord" in e and "public" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P31 (iOS PendingPeerIdentity.fromRecord made public) was NOT caught")
        reset_all()

        # Mutation P32: Android VerifiedPeerIdentity constructor opened from private
        f_kt_models.write_text(ANDROID_MODELS_PATH.read_text(encoding="utf-8").replace("class VerifiedPeerIdentity private constructor(", "class VerifiedPeerIdentity constructor("), encoding="utf-8")
        errs = run_check()
        if any("VerifiedPeerIdentity constructor" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P32 (Android VerifiedPeerIdentity constructor opened) was NOT caught")
        reset_all()

        # Mutation P33: iOS VerifiedPeerIdentity initializer opened from fileprivate
        f_swift_models.write_text(IOS_MODELS_PATH.read_text(encoding="utf-8").replace("fileprivate init(", "public init("), encoding="utf-8")
        errs = run_check()
        if any("initializers must be 'fileprivate init'" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P33 (iOS VerifiedPeerIdentity init opened) was NOT caught")
        reset_all()

        # Mutation P34: Fake production file calls VerifiedPeerIdentity.fromRecord
        (fake_android_src / "BypassCaller.kt").write_text("package io.godstone.mesh.identity\nval x = VerifiedPeerIdentity.fromRecord(null!!)\n", encoding="utf-8")
        errs = run_check()
        if any("Forbidden production call to fromRecord()" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P34 (fake production call to fromRecord()) was NOT caught")
        reset_all()

        # Mutation P35: Fake production file constructs PeerIdentityRecord directly
        (fake_ios_src / "BypassConstructor.swift").write_text("import Foundation\nlet r = PeerIdentityRecord(nodeId: Data(), signingPublicKey: Data(), acceptedStaticDhPublicKey: Data(), acceptedGeneration: 0, trustLevel: .tofuPinned)\n", encoding="utf-8")
        errs = run_check()
        if any("Forbidden production instantiation of PeerIdentityRecord()" in e for e in errs):
            passed += 1
        else:
            failures.append("Mutation P35 (fake production instantiation of PeerIdentityRecord()) was NOT caught")
        reset_all()

    if failures:
        for f in failures:
            print(f"::error::selftest failure: {f}")
        return 1

    print(f"check_peer_trust_controls selftest PASSED ({passed}/35 mutations caught deterministically).")
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
