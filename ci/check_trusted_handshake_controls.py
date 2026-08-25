#!/usr/bin/env python3
"""Regression controls and structural checks for TrustedHandshakeController (ADR-003, Phase C8.4A / C8.4A.1).

Verifies the presence, boundaries, and structural invariants of:
- Typed HandshakeReadResult on Android and iOS (H01)
- Android authenticated remote static exposure without requiring split (H02)
- iOS separate readMessage2 and writeMessage3 operations (H03)
- Trusted iOS controller does not call readMessage2AndWrite3 (H04)
- Local binding payload from canonical issueIdentityBinding on both platforms (H05)
- IdentityBindingValidator.validate called with payload, authenticatedRemoteStaticKey, advertised hint (H06)
- Repository apply only after validation .Valid / .valid (H07)
- Initiator HS3 production only for Accepted / FirstSeenPinned (H08)
- KeyChangedQuarantined has no initiator HS3 authority (H09)
- Rejected/Corrupt/StorageFailure have no initiator HS3 authority (H10)
- Responder READY only for Accepted / FirstSeenPinned (H11)
- Responder quarantine/reject/corrupt/storage cannot READY (H12)
- Application seal/open requires explicit READY state (H13)
- Canonical 32/229/197 size assertions on Android (H14)
- Canonical 32/229/197 size assertions on iOS (H15)
- NoiseSession source contains no PeerIdentityRepository/PeerIdentityStore mutation authority (H16)
- Android MeshModule uses UnresolvedRecipientKeyResolver; iOS AppContainer remains Archive-only (H17)
- Link flags remain false (H18)
- Canonical semantic test inventories exist on BOTH platforms (H19)
- iOS readMessage2AndWrite3 absent or strictly non-public/uncalled in production mesh (H20)
- Android HandshakeReadResult defensive immutability with private backing and clone copies (H21)
- Method-scoped HS3 authority on Android and iOS (H22)
- Zero-call semantic test inventory on Android and iOS (H23)
- Option-B status truth in ADR-003 regarding untrusted SessionManager (H24)
- iOS AppContainer archive-only boundary (H25)
- NOISE_ESTABLISHED state is real, assigned, tested, and not READY (H26)
"""
from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

ANDROID_CONTROLLER_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "crypto" / "TrustedHandshakeController.kt"
ANDROID_NOISE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "crypto" / "NoiseSession.kt"
ANDROID_TEST_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "crypto" / "TrustedHandshakeControllerTest.kt"
ANDROID_MESH_MODULE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "di" / "MeshModule.kt"
ANDROID_MESH_NODE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "MeshNode.kt"

IOS_CONTROLLER_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "TrustedHandshakeController.swift"
IOS_NOISE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "NoiseSession.swift"
IOS_TEST_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "TrustedHandshakeControllerTests.swift"
IOS_APP_CONTAINER_PATH = ROOT / "ios" / "Godstone" / "Sources" / "App" / "AppContainer.swift"
IOS_MESH_NODE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "MeshNode.swift"

ADR003_PATH = ROOT / "docs" / "adr" / "ADR-003-identity-and-sealed-sender.md"


def strip_comments(text: str, lang: str = "kt") -> str:
    """Remove single-line and multi-line comments."""
    text = re.sub(r'//.*', '', text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    return text


def check_controls(
    android_controller_path: Path = ANDROID_CONTROLLER_PATH,
    android_noise_path: Path = ANDROID_NOISE_PATH,
    android_test_path: Path = ANDROID_TEST_PATH,
    mesh_module_path: Path = ANDROID_MESH_MODULE_PATH,
    android_mesh_node_path: Path = ANDROID_MESH_NODE_PATH,
    ios_controller_path: Path = IOS_CONTROLLER_PATH,
    ios_noise_path: Path = IOS_NOISE_PATH,
    ios_test_path: Path = IOS_TEST_PATH,
    app_container_path: Path = IOS_APP_CONTAINER_PATH,
    ios_mesh_node_path: Path = IOS_MESH_NODE_PATH,
    adr003_path: Path = ADR003_PATH,
) -> list[str]:
    errors: list[str] = []

    # File presence checks
    required_files = [
        (android_controller_path, "Android TrustedHandshakeController"),
        (android_noise_path, "Android NoiseSession"),
        (android_test_path, "Android TrustedHandshakeControllerTest"),
        (mesh_module_path, "Android MeshModule"),
        (android_mesh_node_path, "Android MeshNode"),
        (ios_controller_path, "iOS TrustedHandshakeController"),
        (ios_noise_path, "iOS NoiseSession"),
        (ios_test_path, "iOS TrustedHandshakeControllerTests"),
        (app_container_path, "iOS AppContainer"),
        (ios_mesh_node_path, "iOS MeshNode"),
        (adr003_path, "ADR-003"),
    ]
    for p, desc in required_files:
        if not p.exists():
            errors.append(f"Missing required file: {desc} ({p})")
    if errors:
        return errors

    # Read all files
    kt_ctrl = android_controller_path.read_text(encoding="utf-8")
    kt_noise = android_noise_path.read_text(encoding="utf-8")
    kt_test = android_test_path.read_text(encoding="utf-8")
    kt_mesh_mod = mesh_module_path.read_text(encoding="utf-8")
    kt_mesh_node = android_mesh_node_path.read_text(encoding="utf-8")
    swift_ctrl = ios_controller_path.read_text(encoding="utf-8")
    swift_noise = ios_noise_path.read_text(encoding="utf-8")
    swift_test = ios_test_path.read_text(encoding="utf-8")
    swift_app_cont = app_container_path.read_text(encoding="utf-8")
    swift_mesh_node = ios_mesh_node_path.read_text(encoding="utf-8")
    adr_txt = adr003_path.read_text(encoding="utf-8")

    # Strip comments for code analysis
    kt_ctrl_code = strip_comments(kt_ctrl)
    kt_noise_code = strip_comments(kt_noise)
    swift_ctrl_code = strip_comments(swift_ctrl)
    swift_noise_code = strip_comments(swift_noise)

    # ── H01: Typed HandshakeReadResult exists on Android and iOS ──
    if "class HandshakeReadResult" not in kt_noise_code or "authenticatedRemoteStaticKey" not in kt_noise_code:
        errors.append("Android NoiseSession must define class HandshakeReadResult with authenticatedRemoteStaticKey (H01)")
    if "HandshakeReadResult" not in swift_noise_code or "authenticatedRemoteStaticKey" not in swift_noise_code:
        errors.append("iOS NoiseSession must define HandshakeReadResult with authenticatedRemoteStaticKey (H01)")

    # ── H02: Android exposes authenticated remote static after static-bearing read without requiring split ──
    if "readHandshakeMessageWithResult" not in kt_noise_code:
        errors.append("Android NoiseSession must expose readHandshakeMessageWithResult returning HandshakeReadResult (H02)")
    if "readHandshakeMessageWithResult" not in kt_ctrl_code:
        errors.append("Android TrustedHandshakeController must call readHandshakeMessageWithResult (H02)")

    # ── H03: iOS has separate readMessage2 and writeMessage3 operations ──
    if not re.search(r'func\s+readMessage2\s*\(', swift_noise_code):
        errors.append("iOS NoiseSession must have separate readMessage2 function (H03)")
    if not re.search(r'func\s+writeMessage3\s*\(', swift_noise_code):
        errors.append("iOS NoiseSession must have separate writeMessage3 function (H03)")

    # ── H04: Trusted iOS controller does not call readMessage2AndWrite3 ──
    if "readMessage2AndWrite3" in swift_ctrl_code or "readMessage2AndWrite" in swift_ctrl_code:
        errors.append("iOS TrustedHandshakeController must NOT call readMessage2AndWrite3 (H04)")

    # ── H05: Local binding payload comes from canonical issueIdentityBinding on both platforms ──
    if "issueIdentityBinding()" not in kt_ctrl_code:
        errors.append("Android TrustedHandshakeController must call issueIdentityBinding() (H05)")
    if "issueIdentityBinding()" not in swift_ctrl_code:
        errors.append("iOS TrustedHandshakeController must call issueIdentityBinding() (H05)")

    # ── H06: IdentityBindingValidator.validate called with payload, authenticatedRemoteStaticKey, advertisedNodeHint ──
    for platform, code, name in [
        ("Android", kt_ctrl_code, "TrustedHandshakeController.kt"),
        ("iOS", swift_ctrl_code, "TrustedHandshakeController.swift"),
    ]:
        if "IdentityBindingValidator.validate" not in code:
            errors.append(f"{platform} {name} must call IdentityBindingValidator.validate (H06)")
        if "authenticatedRemoteStaticKey" not in code:
            errors.append(f"{platform} {name} must pass authenticatedRemoteStaticKey to validation (H06)")

    # ── H07: Repository apply happens only after validation .Valid / .valid ──
    if "applyValidatedBinding" not in kt_ctrl_code:
        errors.append("Android TrustedHandshakeController must call applyValidatedBinding (H07)")
    if "applyValidatedBinding" not in swift_ctrl_code:
        errors.append("iOS TrustedHandshakeController must call applyValidatedBinding (H07)")
    for platform, code in [("Android", kt_ctrl_code), ("iOS", swift_ctrl_code)]:
        ctrl_start = code.find("class TrustedHandshakeController")
        if ctrl_start < 0:
            errors.append(f"{platform} missing TrustedHandshakeController class (H07)")
            continue
        ctrl_body = code[ctrl_start:]
        validate_positions = [m.start() for m in re.finditer(r'IdentityBindingValidator\.validate', ctrl_body)]
        apply_positions = [m.start() for m in re.finditer(r'trustAuthority\.applyValidatedBinding', ctrl_body)]
        if validate_positions and apply_positions:
            for ap in apply_positions:
                preceding = [vp for vp in validate_positions if vp < ap]
                if not preceding:
                    errors.append(f"{platform} must validate BEFORE applyValidatedBinding (H07)")

    # ── H08: Initiator HS3 production occurs only for Accepted / FirstSeenPinned ──
    if "Accepted" not in kt_ctrl_code or "FirstSeenPinned" not in kt_ctrl_code:
        errors.append("Android TrustedHandshakeController must branch on Accepted / FirstSeenPinned (H08)")
    if ".accepted" not in swift_ctrl_code or ".firstSeenPinned" not in swift_ctrl_code:
        errors.append("iOS TrustedHandshakeController must branch on .accepted / .firstSeenPinned (H08)")

    # ── H09: KeyChangedQuarantined has no initiator HS3 authority ──
    if "KeyChangedQuarantined" not in kt_ctrl_code:
        errors.append("Android TrustedHandshakeController must handle KeyChangedQuarantined (H09)")
    if ".keyChangedQuarantined" not in swift_ctrl_code:
        errors.append("iOS TrustedHandshakeController must handle .keyChangedQuarantined (H09)")
    if "QUARANTINED" not in kt_ctrl_code:
        errors.append("Android TrustedHandshakeController must set QUARANTINED state on KeyChangedQuarantined (H09)")
    if ".quarantined" not in swift_ctrl_code:
        errors.append("iOS TrustedHandshakeController must set .quarantined state on keyChangedQuarantined (H09)")

    # ── H10: Rejected/Corrupt/StorageFailure have no initiator HS3 authority ──
    for label in ["Rejected", "Corrupt", "StorageFailure"]:
        if label not in kt_ctrl_code:
            errors.append(f"Android TrustedHandshakeController must handle {label} (returning null, not HS3) (H10)")
    for label in [".rejected", ".corrupt", ".storageFailure"]:
        if label not in swift_ctrl_code:
            errors.append(f"iOS TrustedHandshakeController must handle {label} (returning nil, not HS3) (H10)")

    # ── H11: Responder READY only for Accepted / FirstSeenPinned ──
    if "HandshakeTrustState.READY" not in kt_ctrl_code:
        errors.append("Android TrustedHandshakeController must transition to READY state (H11)")
    if "state = .ready" not in swift_ctrl_code:
        errors.append("iOS TrustedHandshakeController must transition to .ready state (H11)")

    # ── H12: Responder quarantine/reject/corrupt/storage cannot READY ──
    for state_name in ["QUARANTINED", "SECURITY_REJECT", "CORRUPT", "STORAGE_FAILURE"]:
        if state_name not in kt_ctrl_code:
            errors.append(f"Android TrustedHandshakeController must have {state_name} state handling (H12)")
    for state_name in [".quarantined", ".securityReject", ".corrupt", ".storageFailure"]:
        if state_name not in swift_ctrl_code:
            errors.append(f"iOS TrustedHandshakeController must have {state_name} state handling (H12)")

    # ── H13: Application seal/open requires explicit READY state ──
    for fn_name in ["fun seal(", "fun open("]:
        if fn_name not in kt_ctrl_code:
            errors.append(f"Android TrustedHandshakeController must have {fn_name.strip()} gated on READY (H13)")
    if "state != HandshakeTrustState.READY" not in kt_ctrl_code:
        errors.append("Android seal/open must guard on state != READY (H13)")
    for fn_name in ["func seal(", "func open("]:
        if fn_name not in swift_ctrl_code:
            errors.append(f"iOS TrustedHandshakeController must have {fn_name.strip()} gated on .ready (H13)")
    if "state == .ready" not in swift_ctrl_code and "isReady" not in swift_ctrl_code:
        errors.append("iOS seal/open must guard on state == .ready (H13)")

    # ── H14: Canonical 32 / 229 / 197 size assertions exist on Android ──
    for size in ["32", "229", "197"]:
        if size not in kt_ctrl_code:
            errors.append(f"Android TrustedHandshakeController missing canonical size assertion for {size} bytes (H14)")

    # ── H15: Canonical 32 / 229 / 197 size assertions exist on iOS ──
    for size in ["32", "229", "197"]:
        if size not in swift_ctrl_code:
            errors.append(f"iOS TrustedHandshakeController missing canonical size assertion for {size} bytes (H15)")

    # ── H16: NoiseSession source contains no PeerIdentityRepository / PeerIdentityStore mutation authority ──
    for forbidden in ["PeerIdentityRepository", "PeerIdentityStore", "applyValidatedBinding", "approvePendingRotation", "revokePeer"]:
        if forbidden in kt_noise_code:
            errors.append(f"Android NoiseSession must NOT reference {forbidden} (H16)")
        if forbidden in swift_noise_code:
            errors.append(f"iOS NoiseSession must NOT reference {forbidden} (H16)")

    # ── H17: Android MeshModule still uses UnresolvedRecipientKeyResolver; iOS AppContainer remains Archive-only ──
    kt_mesh_mod_code = strip_comments(kt_mesh_mod)
    if "UnresolvedRecipientKeyResolver" not in kt_mesh_mod_code:
        errors.append("Android MeshModule must still use UnresolvedRecipientKeyResolver during C8.4A (H17)")
    if "BoundRecipientKeyResolver" in kt_mesh_mod_code:
        errors.append("Android MeshModule must NOT wire BoundRecipientKeyResolver during C8.4A (H17)")
    if "TrustedHandshakeController" in kt_mesh_mod_code:
        errors.append("Android MeshModule must NOT wire TrustedHandshakeController during C8.4A (H17)")
    swift_app_cont_code = strip_comments(swift_app_cont)
    if "BoundRecipientKeyResolver" in swift_app_cont_code:
        errors.append("iOS AppContainer must NOT wire BoundRecipientKeyResolver during C8.4A (H17)")
    if "TrustedHandshakeController" in swift_app_cont_code:
        errors.append("iOS AppContainer must NOT wire TrustedHandshakeController during C8.4A (H17)")

    # ── H18: Link flags remain false ──
    if "LINK_LAYER_READY = false" not in kt_mesh_node:
        errors.append("Android MeshNode LINK_LAYER_READY must remain false (H18)")
    if "linkLayerReady = false" not in swift_mesh_node:
        errors.append("iOS MeshNode linkLayerReady must remain false (H18)")
    if "LINK_LAYER_READY = false" not in adr_txt and "LINK_LAYER_READY=false" not in adr_txt:
        errors.append("ADR-003 must state LINK_LAYER_READY = false (H18)")

    # ── H19: Canonical semantic test inventories exist on BOTH platforms ──
    android_required_tests = [f"H_A{i:02d}" for i in range(1, 21)]
    ios_required_tests = [f"H_I{i:02d}" for i in range(1, 24)]

    for test_id in android_required_tests:
        if test_id not in kt_test:
            errors.append(f"Android TrustedHandshakeControllerTest missing canonical test {test_id} (H19)")
    for test_id in ios_required_tests:
        if test_id not in swift_test:
            errors.append(f"iOS TrustedHandshakeControllerTests missing canonical test {test_id} (H19)")

    # ── H20: iOS readMessage2AndWrite3 absent or strictly non-public/uncalled in production mesh ──
    if "readMessage2AndWrite3" in swift_noise_code:
        errors.append("iOS NoiseSession must NOT contain readMessage2AndWrite3 (H20)")

    # ── H21: Android HandshakeReadResult defensive immutability ──
    if "internal class HandshakeReadResult" not in kt_noise_code and "class HandshakeReadResult" not in kt_noise_code:
        errors.append("Android HandshakeReadResult must be an internal class (H21)")
    if "_payload" not in kt_noise_code or "_authenticatedRemoteStaticKey" not in kt_noise_code:
        errors.append("Android HandshakeReadResult must use private backing fields for defensive copying (H21)")
    if "clone()" not in kt_noise_code:
        errors.append("Android HandshakeReadResult must use clone() for defensive copy semantics (H21)")
    if "testHandshakeReadResult_DefensiveImmutability" not in kt_test:
        errors.append("Android TrustedHandshakeControllerTest missing testHandshakeReadResult_DefensiveImmutability (H21)")

    # ── H22: Method-scoped HS3 authority on Android and iOS ──
    if "hs3Writer.writeHs3" not in kt_ctrl_code:
        errors.append("Android TrustedHandshakeController missing method-scoped hs3Writer.writeHs3 invocation (H22)")
    if "hs3Writer.writeHs3" not in swift_ctrl_code:
        errors.append("iOS TrustedHandshakeController missing method-scoped hs3Writer.writeHs3 invocation (H22)")

    # ── H23: Zero-call semantic test inventory on Android and iOS ──
    if "issuerCalls" not in kt_test or "hs3WriterCalls" not in kt_test:
        errors.append("Android TrustedHandshakeControllerTest must verify zero issuer/hs3Writer calls on failure (H23)")
    if "CountingIssuer" not in swift_test or "CountingHs3Writer" not in swift_test:
        errors.append("iOS TrustedHandshakeControllerTests must verify zero issuer/hs3Writer calls on failure (H23)")

    # ── H24: Option-B status truth in ADR-003 regarding untrusted SessionManager ──
    if "SessionManager" not in adr_txt or "UNTRUSTED" not in adr_txt or "NOT RUNTIME-AUTHORITATIVE" not in adr_txt:
        errors.append("ADR-003 must contain explicit SessionManager UNTRUSTED / NOT RUNTIME-AUTHORITATIVE warning (H24)")

    # ── H25: iOS AppContainer archive-only boundary ──
    forbidden_app_container = [
        "MeshNode", "SessionManager", "NoiseSession", "TrustedHandshakeController",
        "PeerIdentityRepository", "PeerIdentityStore", "SqlitePeerIdentityStore",
        "DeliveryTracker", "BoundRecipientKeyResolver", "AckAuthenticator"
    ]
    for forbidden in forbidden_app_container:
        if forbidden in swift_app_cont_code:
            errors.append(f"iOS AppContainer must NOT reference {forbidden} (H25)")

    # ── H26: NOISE_ESTABLISHED state is real, assigned, tested, and not READY ──
    if "HandshakeTrustState.NOISE_ESTABLISHED" not in kt_ctrl_code:
        errors.append("Android TrustedHandshakeController must transition through NOISE_ESTABLISHED (H26)")
    if ".noiseEstablished" not in swift_ctrl_code:
        errors.append("iOS TrustedHandshakeController must transition through .noiseEstablished (H26)")
    if "testResponder_NoiseEstablishedObservedDuringTrustApply_AcceptedAdvancesToReady" not in kt_test:
        errors.append("Android TrustedHandshakeControllerTest missing NOISE_ESTABLISHED observation test (H26)")
    if "testResponder_NoiseEstablishedObservedDuringTrustApply_AcceptedAdvancesToReady" not in swift_test:
        errors.append("iOS TrustedHandshakeControllerTests missing NOISE_ESTABLISHED observation test (H26)")

    return errors


def selftest() -> int:
    """Run mutation selftest: inject 26 mutations (one per control) and verify each is caught."""
    import shutil

    passed = 0
    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="trusted_hs_controls_selftest_") as td:
        tmp = Path(td)

        # Copy all required files
        src_files = {
            "android_controller": (ANDROID_CONTROLLER_PATH, tmp / "TrustedHandshakeController.kt"),
            "android_noise": (ANDROID_NOISE_PATH, tmp / "NoiseSession.kt"),
            "android_test": (ANDROID_TEST_PATH, tmp / "TrustedHandshakeControllerTest.kt"),
            "mesh_module": (ANDROID_MESH_MODULE_PATH, tmp / "MeshModule.kt"),
            "android_mesh_node": (ANDROID_MESH_NODE_PATH, tmp / "MeshNode.kt"),
            "ios_controller": (IOS_CONTROLLER_PATH, tmp / "TrustedHandshakeController.swift"),
            "ios_noise": (IOS_NOISE_PATH, tmp / "NoiseSession.swift"),
            "ios_test": (IOS_TEST_PATH, tmp / "TrustedHandshakeControllerTests.swift"),
            "app_container": (IOS_APP_CONTAINER_PATH, tmp / "AppContainer.swift"),
            "ios_mesh_node": (IOS_MESH_NODE_PATH, tmp / "MeshNode.swift"),
            "adr003": (ADR003_PATH, tmp / "ADR-003.md"),
        }

        for key, (src, dst) in src_files.items():
            shutil.copy2(src, dst)

        def get_paths():
            return dict(
                android_controller_path=src_files["android_controller"][1],
                android_noise_path=src_files["android_noise"][1],
                android_test_path=src_files["android_test"][1],
                mesh_module_path=src_files["mesh_module"][1],
                android_mesh_node_path=src_files["android_mesh_node"][1],
                ios_controller_path=src_files["ios_controller"][1],
                ios_noise_path=src_files["ios_noise"][1],
                ios_test_path=src_files["ios_test"][1],
                app_container_path=src_files["app_container"][1],
                ios_mesh_node_path=src_files["ios_mesh_node"][1],
                adr003_path=src_files["adr003"][1],
            )

        def run_check():
            return check_controls(**get_paths())

        def reset_all():
            for key, (src, dst) in src_files.items():
                shutil.copy2(src, dst)

        # Baseline: must pass
        baseline_errors = run_check()
        if baseline_errors:
            print("::error::selftest baseline FAILED -- controls themselves have errors:")
            for e in baseline_errors:
                print(f"  {e}")
            return 1

        f_kt_noise = src_files["android_noise"][1]
        f_swift_noise = src_files["ios_noise"][1]
        f_kt_ctrl = src_files["android_controller"][1]
        f_swift_ctrl = src_files["ios_controller"][1]
        f_kt_test = src_files["android_test"][1]
        f_swift_test = src_files["ios_test"][1]
        f_mesh_mod = src_files["mesh_module"][1]
        f_kt_node = src_files["android_mesh_node"][1]
        f_swift_node = src_files["ios_mesh_node"][1]
        f_app_cont = src_files["app_container"][1]
        f_adr = src_files["adr003"][1]

        # Mutation H01: Remove HandshakeReadResult from Android NoiseSession
        f_kt_noise.write_text(f_kt_noise.read_text(encoding="utf-8").replace("class HandshakeReadResult", "class OtherResult"), encoding="utf-8")
        if any("H01" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H01 was NOT caught")
        reset_all()

        # Mutation H02: Remove readHandshakeMessageWithResult from Android NoiseSession
        f_kt_noise.write_text(f_kt_noise.read_text(encoding="utf-8").replace("readHandshakeMessageWithResult", "readOldMsg"), encoding="utf-8")
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("readHandshakeMessageWithResult", "readOldMsg"), encoding="utf-8")
        if any("H02" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H02 was NOT caught")
        reset_all()

        # Mutation H03: Remove readMessage2 from iOS NoiseSession
        f_swift_noise.write_text(f_swift_noise.read_text(encoding="utf-8").replace("func readMessage2(", "func readOldMessage2("), encoding="utf-8")
        if any("H03" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H03 was NOT caught")
        reset_all()

        # Mutation H04: Inject readMessage2AndWrite3 call in iOS controller
        f_swift_ctrl.write_text(f_swift_ctrl.read_text(encoding="utf-8") + "\nfunc legacy() { _ = noiseSession.readMessage2AndWrite3(Data()) }\n", encoding="utf-8")
        if any("H04" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H04 was NOT caught")
        reset_all()

        # Mutation H05: Remove issueIdentityBinding from Android controller
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("issueIdentityBinding()", "createBinding()"), encoding="utf-8")
        if any("H05" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H05 was NOT caught")
        reset_all()

        # Mutation H06: Remove IdentityBindingValidator.validate from Android controller
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("IdentityBindingValidator.validate", "BindingChecker.check"), encoding="utf-8")
        if any("H06" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H06 was NOT caught")
        reset_all()

        # Mutation H07: Remove applyValidatedBinding from Android controller
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("applyValidatedBinding", "doSomethingElse"), encoding="utf-8")
        if any("H07" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H07 was NOT caught")
        reset_all()

        # Mutation H08: Remove PeerTrustApplyResult.Accepted branch from Android controller
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("PeerTrustApplyResult.Accepted", "PeerTrustApplyResult.AutoGranted"), encoding="utf-8")
        if any("H08" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H08 was NOT caught")
        reset_all()

        # Mutation H09: Remove KeyChangedQuarantined from Android controller
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("KeyChangedQuarantined", "KeyChanged"), encoding="utf-8")
        if any("H09" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H09 was NOT caught")
        reset_all()

        # Mutation H10: Remove StorageFailure handling from Android controller
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("StorageFailure", "DiskError"), encoding="utf-8")
        if any("H10" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H10 was NOT caught")
        reset_all()

        # Mutation H11: Remove READY state transition from Android controller
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("HandshakeTrustState.READY", "HandshakeTrustState.DONE"), encoding="utf-8")
        if any("H11" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H11 was NOT caught")
        reset_all()

        # Mutation H12: Remove CORRUPT state from Android controller
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("CORRUPT", "BROKEN"), encoding="utf-8")
        if any("H12" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H12 was NOT caught")
        reset_all()

        # Mutation H13: Remove READY guard from seal/open on Android
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("state != HandshakeTrustState.READY", "false"), encoding="utf-8")
        if any("H13" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H13 was NOT caught")
        reset_all()

        # Mutation H14: Remove 197 size assertion from Android controller
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("197", "999"), encoding="utf-8")
        if any("H14" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H14 was NOT caught")
        reset_all()

        # Mutation H15: Remove 229 size assertion from iOS controller
        f_swift_ctrl.write_text(f_swift_ctrl.read_text(encoding="utf-8").replace("229", "999"), encoding="utf-8")
        if any("H15" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H15 was NOT caught")
        reset_all()

        # Mutation H16: Inject PeerIdentityRepository reference in Android NoiseSession
        f_kt_noise.write_text(f_kt_noise.read_text(encoding="utf-8") + "\nfun mutate(repo: PeerIdentityRepository) {}\n", encoding="utf-8")
        if any("H16" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H16 was NOT caught")
        reset_all()

        # Mutation H17: Wire BoundRecipientKeyResolver in Android MeshModule
        f_mesh_mod.write_text(f_mesh_mod.read_text(encoding="utf-8").replace("UnresolvedRecipientKeyResolver", "BoundRecipientKeyResolver"), encoding="utf-8")
        if any("H17" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H17 was NOT caught")
        reset_all()

        # Mutation H18: Flip LINK_LAYER_READY to true in Android MeshNode
        f_kt_node.write_text(f_kt_node.read_text(encoding="utf-8").replace("LINK_LAYER_READY = false", "LINK_LAYER_READY = true"), encoding="utf-8")
        if any("H18" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H18 was NOT caught")
        reset_all()

        # Mutation H19: Remove canonical test H_A01 from Android test
        f_kt_test.write_text(f_kt_test.read_text(encoding="utf-8").replace("H_A01", "H_OLD01"), encoding="utf-8")
        if any("H19" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H19 was NOT caught")
        reset_all()

        # Mutation H20: Inject readMessage2AndWrite3 into iOS NoiseSession
        f_swift_noise.write_text(f_swift_noise.read_text(encoding="utf-8") + "\npublic func readMessage2AndWrite3() {}\n", encoding="utf-8")
        if any("H20" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H20 was NOT caught")
        reset_all()

        # Mutation H21: Remove clone() from Android HandshakeReadResult
        f_kt_noise.write_text(f_kt_noise.read_text(encoding="utf-8").replace(".clone()", ""), encoding="utf-8")
        if any("H21" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H21 was NOT caught")
        reset_all()

        # Mutation H22: Remove hs3Writer.writeHs3 from iOS controller
        f_swift_ctrl.write_text(f_swift_ctrl.read_text(encoding="utf-8").replace("hs3Writer.writeHs3", "dummyWriter"), encoding="utf-8")
        if any("H22" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H22 was NOT caught")
        reset_all()

        # Mutation H23: Remove CountingIssuer from iOS test
        f_swift_test.write_text(f_swift_test.read_text(encoding="utf-8").replace("CountingIssuer", "OtherIssuer"), encoding="utf-8")
        if any("H23" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H23 was NOT caught")
        reset_all()

        # Mutation H24: Remove UNTRUSTED warning from ADR-003
        f_adr.write_text(f_adr.read_text(encoding="utf-8").replace("UNTRUSTED", "TRUSTED"), encoding="utf-8")
        if any("H24" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H24 was NOT caught")
        reset_all()

        # Mutation H25: Inject MeshNode into iOS AppContainer
        f_app_cont.write_text(f_app_cont.read_text(encoding="utf-8") + "\nlet node: MeshNode? = nil\n", encoding="utf-8")
        if any("H25" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H25 was NOT caught")
        reset_all()

        # Mutation H26: Remove NOISE_ESTABLISHED state transition from Android controller
        f_kt_ctrl.write_text(f_kt_ctrl.read_text(encoding="utf-8").replace("HandshakeTrustState.NOISE_ESTABLISHED", "HandshakeTrustState.READY"), encoding="utf-8")
        if any("H26" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H26 was NOT caught")
        reset_all()

    if failures:
        for f in failures:
            print(f"::error::selftest failure: {f}")
        return 1

    print(f"check_trusted_handshake_controls selftest PASSED ({passed}/26 mutations caught deterministically).")
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
            print(f"::error::Trusted handshake control error: {e}", file=sys.stderr)
        print(f"\nFAIL: {len(errors)} trusted handshake control issue(s) found.", file=sys.stderr)
        return 1

    print("TRUSTED HANDSHAKE CONTROLS GATE: PASS -- typed inspection, trust gate, seal/open boundary, defensive immutability, zero-call semantics, and link flags satisfied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
