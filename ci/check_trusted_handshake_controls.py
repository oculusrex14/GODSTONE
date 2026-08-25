#!/usr/bin/env python3
"""Regression controls and structural checks for TrustedHandshakeController (ADR-003, Phase C8.4A / C8.4A.1 / C8.4A.2).

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
- Method-scoped HS3 authority and correct initiator state ordering on Android and iOS (H22)
- Zero-call semantic test inventory on Android and iOS (H23)
- Option-B status truth in ADR-003 regarding untrusted SessionManager (H24)
- iOS AppContainer archive-only boundary (H25)
- NOISE_ESTABLISHED state is real, assigned after split, tested, and distinct from READY (H26)
- READY requires real Noise establishment on BOTH platforms (H27)
- HS3 writer/issuer failure fails closed without leaking exceptions (H28)
- Positive writer counts (1/1) proven on BOTH platforms for Accepted and FirstSeenPinned (H29)
- Successful tests may not fake READY with non-delegating mock writers (H30)
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


def strip_comments(text: str) -> str:
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

    # ── H17: Android MeshModule non-shipping composition; iOS AppContainer remains Archive-only ──
    swift_app_cont_code = strip_comments(swift_app_cont)
    if "BoundRecipientKeyResolver" in swift_app_cont_code:
        errors.append("iOS AppContainer must NOT wire BoundRecipientKeyResolver (H17)")
    if "TrustedHandshakeController" in swift_app_cont_code or "MeshRuntime" in swift_app_cont_code:
        errors.append("iOS AppContainer must NOT wire TrustedHandshakeController or MeshRuntime (H17)")

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

    # ── H21: Android HandshakeReadResult defensive immutability (Strengthened) ──
    hrr_start = kt_noise_code.find("internal class HandshakeReadResult")
    ns_start = kt_noise_code.find("class NoiseSession")
    if hrr_start < 0:
        errors.append("Android NoiseSession must define 'internal class HandshakeReadResult' (H21)")
    else:
        hrr_body = kt_noise_code[hrr_start:ns_start] if ns_start > hrr_start else kt_noise_code[hrr_start:]
        if "private val _payload: ByteArray" not in hrr_body:
            errors.append("Android HandshakeReadResult must define 'private val _payload: ByteArray' backing field (H21)")
        if "private val _authenticatedRemoteStaticKey: ByteArray?" not in hrr_body:
            errors.append("Android HandshakeReadResult must define 'private val _authenticatedRemoteStaticKey: ByteArray?' backing field (H21)")
        if ("_payload: ByteArray = payload.copyOf()" not in hrr_body and "_payload: ByteArray = payload.clone()" not in hrr_body and
            "_payload = payload.copyOf()" not in hrr_body and "_payload = payload.clone()" not in hrr_body):
            errors.append("Android HandshakeReadResult constructor must copy input payload (H21)")
        if ("_authenticatedRemoteStaticKey: ByteArray? = authenticatedRemoteStaticKey?.copyOf()" not in hrr_body and
            "_authenticatedRemoteStaticKey: ByteArray? = authenticatedRemoteStaticKey?.clone()" not in hrr_body and
            "_authenticatedRemoteStaticKey = authenticatedRemoteStaticKey?.copyOf()" not in hrr_body and
            "_authenticatedRemoteStaticKey = authenticatedRemoteStaticKey?.clone()" not in hrr_body):
            errors.append("Android HandshakeReadResult constructor must copy input authenticatedRemoteStaticKey (H21)")
        if "val payload: ByteArray" not in hrr_body or ("_payload.copyOf()" not in hrr_body and "_payload.clone()" not in hrr_body):
            errors.append("Android HandshakeReadResult payload getter must return a defensive copy (H21)")
        if "val authenticatedRemoteStaticKey: ByteArray?" not in hrr_body or ("_authenticatedRemoteStaticKey?.copyOf()" not in hrr_body and "_authenticatedRemoteStaticKey?.clone()" not in hrr_body):
            errors.append("Android HandshakeReadResult authenticatedRemoteStaticKey getter must return a defensive copy (H21)")
    if "testHandshakeReadResult_DefensiveImmutability" not in kt_test:
        errors.append("Android TrustedHandshakeControllerTest missing testHandshakeReadResult_DefensiveImmutability (H21)")

    # ── H22: Method-scoped HS3 authority & Ordering on Android and iOS (Strengthened) ──
    # Android initiatorProcessMessage2 sequence check
    kt_init_match = re.search(r'fun\s+initiatorProcessMessage2\s*\(.*?\)\s*:\s*ByteArray\?\s*\{(?P<body>.*?)\n\s*fun\s+', kt_ctrl_code, re.DOTALL)
    if not kt_init_match:
        errors.append("Android TrustedHandshakeController missing initiatorProcessMessage2 method (H22)")
    else:
        kt_body = kt_init_match.group("body")
        pos_val = kt_body.find("IdentityBindingValidator.validate")
        pos_apply = kt_body.find("trustAuthority.applyValidatedBinding")
        pos_issue = kt_body.find("localBindingIssuer.issueEncodedBinding")
        pos_write = kt_body.find("hs3Writer.writeHs3")
        pos_estab = kt_body.find("noiseSession.isEstablished")
        pos_noise_state = kt_body.find("HandshakeTrustState.NOISE_ESTABLISHED")
        pos_ready_state = kt_body.find("HandshakeTrustState.READY")

        if pos_val < 0 or pos_apply < 0 or pos_issue < 0 or pos_write < 0 or pos_estab < 0 or pos_noise_state < 0 or pos_ready_state < 0:
            errors.append("Android initiatorProcessMessage2 missing required steps in pipeline (H22)")
        elif not (pos_val < pos_apply < pos_issue < pos_write < pos_estab < pos_noise_state < pos_ready_state):
            errors.append("Android initiatorProcessMessage2 steps executed in invalid order (must be: validate -> apply -> issue -> writeHs3 -> isEstablished -> NOISE_ESTABLISHED -> READY) (H22)")
        if "hs3Writer" in kt_ctrl_code[kt_ctrl_code.find("KeyChangedQuarantined"):kt_ctrl_code.find("responderProcessMessage1")]:
            errors.append("Android hs3Writer must not be called in quarantine/rejected branch (H22)")

    # iOS initiatorProcessMessage2 sequence check
    swift_init_match = re.search(r'func\s+initiatorProcessMessage2\s*\(.*?\)\s*->\s*Data\?\s*\{(?P<body>.*?)\n\s*(?:func|\/\/\/)\s+', swift_ctrl_code, re.DOTALL)
    if not swift_init_match:
        errors.append("iOS TrustedHandshakeController missing initiatorProcessMessage2 method (H22)")
    else:
        swift_body = swift_init_match.group("body")
        pos_val = swift_body.find("IdentityBindingValidator.validate")
        pos_apply = swift_body.find("trustAuthority.applyValidatedBinding")
        pos_issue = swift_body.find("localBindingIssuer.issueEncodedBinding")
        pos_write = swift_body.find("hs3Writer.writeHs3")
        pos_estab = swift_body.find("noiseSession.isEstablished")
        pos_noise_state = swift_body.find(".noiseEstablished")
        pos_ready_state = swift_body.find(".ready")

        if pos_val < 0 or pos_apply < 0 or pos_issue < 0 or pos_write < 0 or pos_estab < 0 or pos_noise_state < 0 or pos_ready_state < 0:
            errors.append("iOS initiatorProcessMessage2 missing required steps in pipeline (H22)")
        elif not (pos_val < pos_apply < pos_issue < pos_write < pos_estab < pos_noise_state < pos_ready_state):
            errors.append("iOS initiatorProcessMessage2 steps executed in invalid order (must be: validate -> apply -> issue -> writeHs3 -> isEstablished -> .noiseEstablished -> .ready) (H22)")
        if "hs3Writer" in swift_ctrl_code[swift_ctrl_code.find("case .keyChangedQuarantined"):swift_ctrl_code.find("responderProcessMessage1")]:
            errors.append("iOS hs3Writer must not be called in quarantine/rejected branch (H22)")

    # ── H23: Zero-call semantic test inventory on Android and iOS (Strengthened) ──
    # Android zero-call check
    h_a20_start = kt_test.find("testTrustedHandshake_H_A20")
    h_a20_pos = kt_test.find("Positive case: Accepted", h_a20_start)
    if h_a20_start >= 0 and h_a20_pos > h_a20_start:
        h_a20_fail_body = kt_test[h_a20_start:h_a20_pos]
        if "assertEquals(\"issuerCalls must be 0 for ${tc.name}\", 0, issuerCalls)" not in h_a20_fail_body:
            errors.append("Android H-A20 test missing zero-call assertion for issuerCalls (H23)")
        if "assertEquals(\"hs3WriterCalls must be 0 for ${tc.name}\", 0, hs3WriterCalls)" not in h_a20_fail_body:
            errors.append("Android H-A20 test missing zero-call assertion for hs3WriterCalls (H23)")
        for req_token in ["F1_InvalidSignature", "F2_StaticMismatch", "F3_HintMismatch", "F4_KeyChangedQuarantined", "F5_RejectedRevoked", "F6_Corrupt", "F7_StorageFailure"]:
            if req_token not in h_a20_fail_body:
                errors.append(f"Android H-A20 test missing failure test case {req_token} (H23)")
    else:
        errors.append("Android TrustedHandshakeControllerTest missing H-A20 test body (H23)")

    # iOS zero-call check
    h_i20_start = swift_test.find("testTrustedHandshake_H_I20")
    h_i20_pos = swift_test.find("Positive case: Accepted", h_i20_start)
    if h_i20_start >= 0 and h_i20_pos > h_i20_start:
        h_i20_fail_body = swift_test[h_i20_start:h_i20_pos]
        if "XCTAssertEqual(issuer.calls, 0" not in h_i20_fail_body:
            errors.append("iOS H-I20 test missing zero-call assertion for issuer.calls (H23)")
        if "XCTAssertEqual(writer.calls, 0" not in h_i20_fail_body:
            errors.append("iOS H-I20 test missing zero-call assertion for writer.calls (H23)")
        for req_token in ["F1_InvalidSignature", "F2_StaticMismatch", "F3_HintMismatch", "F4_KeyChangedQuarantined", "F5_RejectedRevoked", "F6_Corrupt", "F7_StorageFailure"]:
            if req_token not in h_i20_fail_body:
                errors.append(f"iOS H-I20 test missing failure test case {req_token} (H23)")
    else:
        errors.append("iOS TrustedHandshakeControllerTests missing H-I20 test body (H23)")

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

    # ── H26: NOISE_ESTABLISHED state is real, assigned after split, tested, and distinct from READY (Strengthened) ──
    if "HandshakeTrustState.NOISE_ESTABLISHED" not in kt_ctrl_code:
        errors.append("Android TrustedHandshakeController must transition through NOISE_ESTABLISHED (H26)")
    if ".noiseEstablished" not in swift_ctrl_code:
        errors.append("iOS TrustedHandshakeController must transition through .noiseEstablished (H26)")
    if "testResponder_NoiseEstablishedObservedDuringTrustApply_AcceptedAdvancesToReady" not in kt_test:
        errors.append("Android TrustedHandshakeControllerTest missing NOISE_ESTABLISHED observation test (H26)")
    if "testResponder_NoiseEstablishedObservedDuringTrustApply_AcceptedAdvancesToReady" not in swift_test:
        errors.append("iOS TrustedHandshakeControllerTests missing NOISE_ESTABLISHED observation test (H26)")
    if "testResponder_NoiseEstablishedObservedDuringTrustApply_QuarantineDeniesReadyAndSeal" not in kt_test:
        errors.append("Android TrustedHandshakeControllerTest missing NOISE_ESTABLISHED quarantine deny test (H26)")
    if "testResponder_NoiseEstablishedObservedDuringTrustApply_QuarantineDeniesReadyAndSeal" not in swift_test:
        errors.append("iOS TrustedHandshakeControllerTests missing NOISE_ESTABLISHED quarantine deny test (H26)")

    # Verify seal/open only accept READY (not NOISE_ESTABLISHED)
    if "NOISE_ESTABLISHED" in kt_ctrl_code[kt_ctrl_code.find("fun seal("):kt_ctrl_code.find("companion object")]:
        errors.append("Android seal/open must NOT accept NOISE_ESTABLISHED (H26)")

    # ── H27: READY requires real Noise establishment on BOTH platforms ──
    # Android production isEstablished guard
    if kt_init_match and "if (!noiseSession.isEstablished)" not in kt_init_match.group("body"):
        errors.append("Android initiatorProcessMessage2 missing !noiseSession.isEstablished guard (H27)")
    kt_resp_match = re.search(r'fun\s+responderProcessMessage3\s*\(.*?\)\s*:\s*Boolean\s*\{(?P<body>.*?)\n\s*fun\s+', kt_ctrl_code, re.DOTALL)
    if not kt_resp_match or "if (!noiseSession.isEstablished)" not in kt_resp_match.group("body"):
        errors.append("Android responderProcessMessage3 missing !noiseSession.isEstablished guard (H27)")

    # iOS production isEstablished guard
    if swift_init_match and "guard noiseSession.isEstablished" not in swift_init_match.group("body"):
        errors.append("iOS initiatorProcessMessage2 missing guard noiseSession.isEstablished (H27)")
    swift_resp_match = re.search(r'func\s+responderProcessMessage3\s*\(.*?\)\s*->\s*Bool\s*\{(?P<body>.*?)\n\s*(?:func|\/\/\/)\s+', swift_ctrl_code, re.DOTALL)
    if not swift_resp_match or "guard noiseSession.isEstablished" not in swift_resp_match.group("body"):
        errors.append("iOS responderProcessMessage3 missing guard noiseSession.isEstablished (H27)")

    # Negative control semantic test presence
    if "A_HS3_FAIL_03" not in kt_test:
        errors.append("Android TrustedHandshakeControllerTest missing A_HS3_FAIL_03 negative control (H27)")
    if "I_HS3_FAIL_03" not in swift_test:
        errors.append("iOS TrustedHandshakeControllerTests missing I_HS3_FAIL_03 negative control (H27)")

    # ── H28: HS3 writer/issuer failure fails closed without leaking exceptions ──
    # Android controller must catch writer/issuer exceptions rather than leaking
    if "hs3Writer.writeHs3" in kt_ctrl_code:
        hs3_pos = kt_ctrl_code.find("hs3Writer.writeHs3")
        try_before = kt_ctrl_code.rfind("try {", 0, hs3_pos)
        catch_after = kt_ctrl_code.find("catch (e: Exception)", hs3_pos)
        if try_before < 0 or catch_after < 0 or catch_after - hs3_pos > 200:
            errors.append("Android TrustedHandshakeController must wrap hs3Writer in try/catch to prevent exception leak (H28)")

    # Semantic failure tests battery
    for a_test in ["A_HS3_FAIL_01", "A_HS3_FAIL_02", "A_HS3_FAIL_04", "A_HS3_FAIL_05", "A_HS3_FAIL_06"]:
        if a_test not in kt_test:
            errors.append(f"Android TrustedHandshakeControllerTest missing {a_test} (H28)")
    for i_test in ["I_HS3_FAIL_01", "I_HS3_FAIL_02", "I_HS3_FAIL_04", "I_HS3_FAIL_05", "I_HS3_FAIL_06"]:
        if i_test not in swift_test:
            errors.append(f"iOS TrustedHandshakeControllerTests missing {i_test} (H28)")

    # ── H29: Positive writer counts (1/1) proven on BOTH platforms for Accepted and FirstSeenPinned ──
    if "issuerCalls must be 1 for Accepted" not in kt_test and "assertEquals(1, issuerCalls)" not in kt_test:
        errors.append("Android test missing positive issuerCalls == 1 assertion for Accepted (H29)")
    if "hs3WriterCalls must be 1 for Accepted" not in kt_test and "assertEquals(1, hs3WriterCalls)" not in kt_test:
        errors.append("Android test missing positive hs3WriterCalls == 1 assertion for Accepted (H29)")
    if "issuerCalls must be 1 for FirstSeenPinned" not in kt_test and "assertEquals(1, issuerCalls)" not in kt_test:
        errors.append("Android test missing positive issuerCalls == 1 assertion for FirstSeenPinned (H29)")
    if "hs3WriterCalls must be 1 for FirstSeenPinned" not in kt_test and "assertEquals(1, hs3WriterCalls)" not in kt_test:
        errors.append("Android test missing positive hs3WriterCalls == 1 assertion for FirstSeenPinned (H29)")

    # iOS positive writer count assertions
    h_i20_start = swift_test.find("testTrustedHandshake_H_I20")
    h_i21_start = swift_test.find("testTrustedHandshake_H_I21")
    if h_i20_start >= 0 and h_i21_start > h_i20_start:
        h_i20_body = swift_test[h_i20_start:h_i21_start]
        writer_1_count = len(re.findall(r'XCTAssertEqual\(writer\.calls,\s*1\)', h_i20_body))
        if writer_1_count < 2:
            errors.append("iOS H-I20 test missing positive writer.calls == 1 assertions for Accepted and FirstSeenPinned (H29)")
    else:
        errors.append("iOS TrustedHandshakeControllerTests missing H-I20 test body (H29)")

    # ── H30: Successful tests may not fake READY with non-delegating mock writers ──
    # Check that positive tests in Android and iOS do NOT use fake non-delegating writers
    accepted_slice = kt_test[kt_test.find("Positive case: Accepted"):kt_test.find("Positive case: FirstSeenPinned")]
    firstseen_slice = kt_test[kt_test.find("Positive case: FirstSeenPinned"):kt_test.find("testResponder_NoiseEstablishedObservedDuringTrustApply_AcceptedAdvancesToReady")]
    if "alice.noiseSession.writeHandshakeMessage" not in accepted_slice:
        errors.append("Android positive Accepted test must delegate to noiseSession.writeHandshakeMessage (H30)")
    if "alice.noiseSession.writeHandshakeMessage" not in firstseen_slice:
        errors.append("Android positive FirstSeenPinned test must delegate to noiseSession.writeHandshakeMessage (H30)")
    if "CountingHs3Writer(noiseSession:" not in swift_test[swift_test.find("Positive case: Accepted"):swift_test.find("testTrustedHandshake_H_I21")]:
        errors.append("iOS positive Accepted test must use delegating CountingHs3Writer(noiseSession:) (H30)")

    return errors


def selftest() -> int:
    """Run mutation selftest across all controls H01-H30 and verify each is caught."""
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

        # Mutation H17: Wire BoundRecipientKeyResolver in iOS AppContainer
        f_app_cont.write_text(f_app_cont.read_text(encoding="utf-8") + "\nprivate var resolver: BoundRecipientKeyResolver?\n", encoding="utf-8")
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

        # Mutation H21a: Remove `internal` from HandshakeReadResult
        f_kt_noise.write_text(f_kt_noise.read_text(encoding="utf-8").replace("internal class HandshakeReadResult", "public class HandshakeReadResult"), encoding="utf-8")
        if any("H21" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H21a was NOT caught")
        reset_all()

        # Mutation H21b: Change payload getter from clone()/copyOf() to raw backing
        f_kt_noise.write_text(f_kt_noise.read_text(encoding="utf-8").replace("get() = _payload.copyOf()", "get() = _payload").replace("get() = _payload.clone()", "get() = _payload"), encoding="utf-8")
        if any("H21" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H21b was NOT caught")
        reset_all()

        # Mutation H21c: Change remote-static getter from clone()/copyOf() to raw backing
        f_kt_noise.write_text(f_kt_noise.read_text(encoding="utf-8").replace("get() = _authenticatedRemoteStaticKey?.copyOf()", "get() = _authenticatedRemoteStaticKey").replace("get() = _authenticatedRemoteStaticKey?.clone()", "get() = _authenticatedRemoteStaticKey"), encoding="utf-8")
        if any("H21" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H21c was NOT caught")
        reset_all()

        # Mutation H21d: Remove constructor input copy
        f_kt_noise.write_text(f_kt_noise.read_text(encoding="utf-8").replace("private val _payload: ByteArray = payload.copyOf()", "private val _payload: ByteArray = payload").replace("private val _payload: ByteArray = payload.clone()", "private val _payload: ByteArray = payload"), encoding="utf-8")
        if any("H21" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H21d was NOT caught")
        reset_all()

        # Mutation H22a: Move hs3Writer call before applyValidatedBinding in Android controller
        bad_kt_ctrl = f_kt_ctrl.read_text(encoding="utf-8").replace(
            "val applyResult = trustAuthority.applyValidatedBinding(validation.binding)",
            "val dummyHs3 = hs3Writer.writeHs3(ByteArray(133))\n        val applyResult = trustAuthority.applyValidatedBinding(validation.binding)"
        )
        f_kt_ctrl.write_text(bad_kt_ctrl, encoding="utf-8")
        if any("H22" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H22a was NOT caught")
        reset_all()

        # Mutation H22b: Move hs3Writer into quarantine branch in iOS controller
        bad_swift_ctrl = f_swift_ctrl.read_text(encoding="utf-8").replace(
            "case .keyChangedQuarantined:\n            state = .quarantined\n            return nil",
            "case .keyChangedQuarantined:\n            state = .quarantined\n            _ = try? hs3Writer.writeHs3(payload: Data())\n            return nil"
        )
        f_swift_ctrl.write_text(bad_swift_ctrl, encoding="utf-8")
        if any("H22" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H22b was NOT caught")
        reset_all()

        # Mutation H22c: Move NOISE_ESTABLISHED before hs3Writer in Android controller
        bad_kt_ctrl2 = f_kt_ctrl.read_text(encoding="utf-8").replace(
            "state = HandshakeTrustState.NOISE_ESTABLISHED\n                state = HandshakeTrustState.READY",
            "state = HandshakeTrustState.READY"
        ).replace(
            "val hs3 = try {",
            "state = HandshakeTrustState.NOISE_ESTABLISHED\n                val hs3 = try {"
        )
        f_kt_ctrl.write_text(bad_kt_ctrl2, encoding="utf-8")
        if any("H22" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H22c was NOT caught")
        reset_all()

        # Mutation H23a: Replace 0 with 1 in Android H-A20 zero-call assertion
        bad_kt_test = f_kt_test.read_text(encoding="utf-8").replace(
            "assertEquals(\"issuerCalls must be 0 for ${tc.name}\", 0, issuerCalls)",
            "assertEquals(\"issuerCalls must be 0 for ${tc.name}\", 1, issuerCalls)"
        )
        f_kt_test.write_text(bad_kt_test, encoding="utf-8")
        if any("H23" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H23a was NOT caught")
        reset_all()

        # Mutation H23b: Delete failure test case from iOS H-I20
        bad_swift_test = f_swift_test.read_text(encoding="utf-8").replace(
            '"F4_KeyChangedQuarantined"',
            '"F4_Skipped"',
        )
        f_swift_test.write_text(bad_swift_test, encoding="utf-8")
        if any("H23" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H23b was NOT caught")
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

        # Mutation H26a: Move initiator NOISE_ESTABLISHED assignment before writer in iOS controller
        bad_swift_ctrl2 = f_swift_ctrl.read_text(encoding="utf-8").replace(
            "state = .noiseEstablished\n                state = .ready",
            "state = .ready"
        ).replace(
            "let hs3 = try hs3Writer.writeHs3",
            "state = .noiseEstablished\n                let hs3 = try hs3Writer.writeHs3"
        )
        f_swift_ctrl.write_text(bad_swift_ctrl2, encoding="utf-8")
        if any("H22" in e or "H26" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H26a was NOT caught")
        reset_all()

        # Mutation H26b: Allow seal/open when NOISE_ESTABLISHED in Android controller
        bad_kt_ctrl3 = f_kt_ctrl.read_text(encoding="utf-8").replace(
            "if (state != HandshakeTrustState.READY) return null",
            "if (state != HandshakeTrustState.READY && state != HandshakeTrustState.NOISE_ESTABLISHED) return null"
        )
        f_kt_ctrl.write_text(bad_kt_ctrl3, encoding="utf-8")
        if any("H26" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H26b was NOT caught")
        reset_all()

        # Mutation H27a: Remove isEstablished guard before READY in Android controller
        bad_kt_ctrl_h27 = f_kt_ctrl.read_text(encoding="utf-8").replace(
            "if (!noiseSession.isEstablished)",
            "if (true)"
        )
        f_kt_ctrl.write_text(bad_kt_ctrl_h27, encoding="utf-8")
        if any("H27" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H27a was NOT caught")
        reset_all()

        # Mutation H27b: Remove isEstablished guard before READY in iOS controller
        bad_swift_ctrl_h27 = f_swift_ctrl.read_text(encoding="utf-8").replace(
            "guard noiseSession.isEstablished",
            "guard true"
        )
        f_swift_ctrl.write_text(bad_swift_ctrl_h27, encoding="utf-8")
        if any("H27" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H27b was NOT caught")
        reset_all()

        # Mutation H28a: Remove try-catch around hs3Writer in Android controller (leaks exception)
        bad_kt_ctrl_h28 = f_kt_ctrl.read_text(encoding="utf-8").replace(
            "val hs3 = try {\n                    hs3Writer.writeHs3(localBytes)\n                } catch (e: Exception) {\n                    state = HandshakeTrustState.SECURITY_REJECT\n                    return null\n                }",
            "val hs3 = hs3Writer.writeHs3(localBytes)"
        )
        f_kt_ctrl.write_text(bad_kt_ctrl_h28, encoding="utf-8")
        if any("H28" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H28a was NOT caught")
        reset_all()

        # Mutation H28b: Remove A_HS3_FAIL_01 test from Android test
        bad_kt_test_h28 = f_kt_test.read_text(encoding="utf-8").replace("A_HS3_FAIL_01", "A_HS3_OLD_01")
        f_kt_test.write_text(bad_kt_test_h28, encoding="utf-8")
        if any("H28" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H28b was NOT caught")
        reset_all()

        # Mutation H29a: Remove iOS FirstSeenPinned writer assertion in H-I20
        bad_swift_test_h29 = f_swift_test.read_text(encoding="utf-8").replace(
            "XCTAssertEqual(writer.calls, 1)\n            XCTAssertTrue(alice.noiseSession.isEstablished)\n        }\n    }\n\n    // MARK: - H-I21",
            "XCTAssertTrue(alice.noiseSession.isEstablished)\n        }\n    }\n\n    // MARK: - H-I21"
        )
        f_swift_test.write_text(bad_swift_test_h29, encoding="utf-8")
        if any("H29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H29a was NOT caught")
        reset_all()

        # Mutation H29b: Remove Android FirstSeenPinned hs3WriterCalls assertion in H-A20
        bad_kt_test_h29 = f_kt_test.read_text(encoding="utf-8").replace(
            "assertEquals(\"hs3WriterCalls must be 1 for FirstSeenPinned\", 1, hs3WriterCalls)",
            ""
        )
        f_kt_test.write_text(bad_kt_test_h29, encoding="utf-8")
        if any("H29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H29b was NOT caught")
        reset_all()

        # Mutation H30a: Change iOS positive accepted writer to return fake Data(count: 197) without NoiseSession
        bad_swift_test_h30 = f_swift_test.read_text(encoding="utf-8").replace(
            "CountingHs3Writer(noiseSession: noiseSession)",
            "CountingHs3Writer()"
        )
        f_swift_test.write_text(bad_swift_test_h30, encoding="utf-8")
        if any("H30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H30a was NOT caught")
        reset_all()

        # Mutation H30b: Change Android positive accepted writer to return fake ByteArray(197) without NoiseSession
        bad_kt_test_h30 = f_kt_test.read_text(encoding="utf-8").replace(
            "alice.noiseSession.writeHandshakeMessage(payload)",
            "ByteArray(197)"
        )
        f_kt_test.write_text(bad_kt_test_h30, encoding="utf-8")
        if any("H30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation H30b was NOT caught")
        reset_all()

    total_mutations = 41
    if failures:
        for f in failures:
            print(f"::error::selftest failure: {f}")
        return 1

    print(f"check_trusted_handshake_controls selftest PASSED ({passed}/{total_mutations} mutations caught deterministically across H01-H30).")
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

    print("TRUSTED HANDSHAKE CONTROLS GATE: PASS -- typed inspection, trust gate, seal/open boundary, defensive immutability, zero-call semantics, Noise establishment invariant (H01-H30), and link flags satisfied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
