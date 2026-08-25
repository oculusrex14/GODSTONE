#!/usr/bin/env python3
"""Structural and regression controls for Trusted Runtime Composition (ADR-003, Phase C8.4B / C8.4B.1).

Verifies the presence, boundaries, and structural invariants of:
- Android SessionManager owns TrustedHandshakeController instances, not raw NoiseSession (R01)
- iOS SessionManager owns TrustedHandshakeController instances, not raw NoiseSession (R02)
- Android SessionManager.seal and SessionManager.open require HandshakeTrustState.READY under lifecycle lock (R03)
- iOS SessionManager.seal and SessionManager.open require .ready under lifecycle lock (R04)
- Android SessionManager per-peer serialized handshake operations (R05)
- iOS SessionManager per-peer serialized handshake operations (R06)
- Android RuntimeLifecycleGate / RuntimeInvalidator authority interface and implementations (R07)
- iOS RuntimeLifecycleGate / RuntimeInvalidator authority protocol and implementations (R08)
- Android MeshRuntimeInvalidator closes stores without swallowed exceptions and invalidates gate (R09)
- iOS MeshRuntimeInvalidator closes stores without swallowed exceptions and invalidates gate (R10)
- Android RuntimeGatedPeerIdentityLookupSource and RuntimeGatedPeerBindingTrustAuthority fail closed upon invalidation (R11)
- iOS RuntimeGatedPeerIdentityLookupSource and RuntimeGatedPeerBindingTrustAuthority fail closed upon invalidation (R12)
- Android RuntimeAwareWipeArtifacts used in active MeshPanicWipe composition (R13)
- iOS RuntimeAwareWipeArtifacts used in active MeshRuntime.beginPanicWipe (R14)
- Android MeshModule wires same gate, sessions, peerStore, messageStore into MeshRuntimeInvalidator and MeshPanicWipe (R15)
- iOS MeshRuntime owns/uses MeshRuntimeInvalidator and exact store URLs for active wipe (R16)
- Android MeshStartupWipeBarrier precedes all sensitive opens (R17)
- iOS MeshRuntime.create binds default startup artifacts to exact store URLs (R18)
- Android MeshNode.canStart checks sessions.isActive and forbids independent Identity.loadOrCreate (R19)
- iOS MeshNode.canStart checks sessions.isActive (R20)
- iOS AppContainer remains strictly Archive-only (no GodstoneMesh / MeshRuntime / BoundRecipientKeyResolver / SessionManager) (R21)
- Android :mesh is not exposed/imported in shipping Light app root (R22)
- Link layer ready flags remain false on BOTH platforms (R23)
- ADR-003 Section 7.3 and status reflect C8.4B composition (R24)
- Android SessionManagerTest inventory (SM01-SM12) (R25)
- iOS SessionManagerTests inventory (SM01-SM12) (R26)
- Android CompositionResolverAckTest inventory (CR01-CR08) (R27)
- iOS CompositionResolverAckTests inventory (CR01-CR08) (R28)
- Android WipeLifecycleTest and CrashStartupResumeTest inventories (W01-W15, SR01-SR07, RC01-RC03) (R29)
- iOS WipeLifecycleTests and CrashStartupResumeTests inventories (W01-W15, SR01-SR07, RC01-RC03) (R30)
"""
from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Paths
ANDROID_SM_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "crypto" / "SessionManager.kt"
ANDROID_GATE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "identity" / "RuntimeLifecycleGate.kt"
ANDROID_MESH_MODULE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "di" / "MeshModule.kt"
ANDROID_MESH_NODE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "MeshNode.kt"
ANDROID_WIPE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "identity" / "PanicWipe.kt"

ANDROID_TEST_SM_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "crypto" / "SessionManagerTest.kt"
ANDROID_TEST_CR_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "delivery" / "CompositionResolverAckTest.kt"
ANDROID_TEST_WIPE_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "identity" / "WipeLifecycleTest.kt"
ANDROID_TEST_STARTUP_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "identity" / "CrashStartupResumeTest.kt"
ANDROID_TEST_CONCURRENCY_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "crypto" / "SessionManagerConcurrencyTest.kt"

IOS_SM_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "SessionManager.swift"
IOS_GATE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "RuntimeLifecycleGate.swift"
IOS_MESH_RUNTIME_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "MeshRuntime.swift"
IOS_MESH_NODE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "MeshNode.swift"
IOS_APP_CONTAINER_PATH = ROOT / "ios" / "Godstone" / "Sources" / "App" / "AppContainer.swift"
IOS_WIPE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "PanicWipe.swift"

IOS_TEST_SM_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "SessionManagerTests.swift"
IOS_TEST_CR_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "CompositionResolverAckTests.swift"
IOS_TEST_WIPE_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "WipeLifecycleTests.swift"
IOS_TEST_STARTUP_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "CrashStartupResumeTests.swift"
IOS_TEST_CONCURRENCY_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "SessionManagerConcurrencyTests.swift"

ADR003_PATH = ROOT / "docs" / "adr" / "ADR-003-identity-and-sealed-sender.md"


def strip_comments(text: str) -> str:
    """Remove single-line and multi-line comments."""
    text = re.sub(r'//.*', '', text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    return text


def check_controls(
    android_sm_path: Path = ANDROID_SM_PATH,
    android_gate_path: Path = ANDROID_GATE_PATH,
    android_mesh_mod_path: Path = ANDROID_MESH_MODULE_PATH,
    android_mesh_node_path: Path = ANDROID_MESH_NODE_PATH,
    android_wipe_path: Path = ANDROID_WIPE_PATH,
    android_test_sm_path: Path = ANDROID_TEST_SM_PATH,
    android_test_cr_path: Path = ANDROID_TEST_CR_PATH,
    android_test_wipe_path: Path = ANDROID_TEST_WIPE_PATH,
    android_test_startup_path: Path = ANDROID_TEST_STARTUP_PATH,
    android_test_concurrency_path: Path = ANDROID_TEST_CONCURRENCY_PATH,
    ios_sm_path: Path = IOS_SM_PATH,
    ios_gate_path: Path = IOS_GATE_PATH,
    ios_mesh_runtime_path: Path = IOS_MESH_RUNTIME_PATH,
    ios_mesh_node_path: Path = IOS_MESH_NODE_PATH,
    ios_app_container_path: Path = IOS_APP_CONTAINER_PATH,
    ios_wipe_path: Path = IOS_WIPE_PATH,
    ios_test_sm_path: Path = IOS_TEST_SM_PATH,
    ios_test_cr_path: Path = IOS_TEST_CR_PATH,
    ios_test_wipe_path: Path = IOS_TEST_WIPE_PATH,
    ios_test_startup_path: Path = IOS_TEST_STARTUP_PATH,
    ios_test_concurrency_path: Path = IOS_TEST_CONCURRENCY_PATH,
    adr003_path: Path = ADR003_PATH,
) -> list[str]:
    errors: list[str] = []

    # File presence checks
    files_to_check = [
        (android_sm_path, "Android SessionManager"),
        (android_gate_path, "Android RuntimeLifecycleGate"),
        (android_mesh_mod_path, "Android MeshModule"),
        (android_mesh_node_path, "Android MeshNode"),
        (android_wipe_path, "Android PanicWipe"),
        (android_test_sm_path, "Android SessionManagerTest"),
        (android_test_cr_path, "Android CompositionResolverAckTest"),
        (android_test_wipe_path, "Android WipeLifecycleTest"),
        (android_test_startup_path, "Android CrashStartupResumeTest"),
        (android_test_concurrency_path, "Android SessionManagerConcurrencyTest"),
        (ios_sm_path, "iOS SessionManager"),
        (ios_gate_path, "iOS RuntimeLifecycleGate"),
        (ios_mesh_runtime_path, "iOS MeshRuntime"),
        (ios_mesh_node_path, "iOS MeshNode"),
        (ios_app_container_path, "iOS AppContainer"),
        (ios_wipe_path, "iOS PanicWipe"),
        (ios_test_sm_path, "iOS SessionManagerTests"),
        (ios_test_cr_path, "iOS CompositionResolverAckTests"),
        (ios_test_wipe_path, "iOS WipeLifecycleTests"),
        (ios_test_startup_path, "iOS CrashStartupResumeTests"),
        (ios_test_concurrency_path, "iOS SessionManagerConcurrencyTests"),
        (adr003_path, "ADR-003"),
    ]

    for p, desc in files_to_check:
        if not p.exists():
            errors.append(f"Missing required file: {desc} ({p})")

    if errors:
        return errors

    kt_sm = strip_comments(android_sm_path.read_text(encoding="utf-8"))
    kt_gate = strip_comments(android_gate_path.read_text(encoding="utf-8"))
    kt_mesh_mod = strip_comments(android_mesh_mod_path.read_text(encoding="utf-8"))
    kt_mesh_node = strip_comments(android_mesh_node_path.read_text(encoding="utf-8"))
    kt_wipe = strip_comments(android_wipe_path.read_text(encoding="utf-8"))
    kt_test_sm = strip_comments(android_test_sm_path.read_text(encoding="utf-8"))
    kt_test_cr = strip_comments(android_test_cr_path.read_text(encoding="utf-8"))
    kt_test_wipe = strip_comments(android_test_wipe_path.read_text(encoding="utf-8"))
    kt_test_startup = strip_comments(android_test_startup_path.read_text(encoding="utf-8"))
    kt_test_concurrency = strip_comments(android_test_concurrency_path.read_text(encoding="utf-8"))

    swift_sm = strip_comments(ios_sm_path.read_text(encoding="utf-8"))
    swift_gate = strip_comments(ios_gate_path.read_text(encoding="utf-8"))
    swift_mesh_runtime = strip_comments(ios_mesh_runtime_path.read_text(encoding="utf-8"))
    swift_mesh_node = strip_comments(ios_mesh_node_path.read_text(encoding="utf-8"))
    swift_app_container = strip_comments(ios_app_container_path.read_text(encoding="utf-8"))
    swift_wipe = strip_comments(ios_wipe_path.read_text(encoding="utf-8"))
    swift_test_sm = strip_comments(ios_test_sm_path.read_text(encoding="utf-8"))
    swift_test_cr = strip_comments(ios_test_cr_path.read_text(encoding="utf-8"))
    swift_test_wipe = strip_comments(ios_test_wipe_path.read_text(encoding="utf-8"))
    swift_test_startup = strip_comments(ios_test_startup_path.read_text(encoding="utf-8"))
    swift_test_concurrency = strip_comments(ios_test_concurrency_path.read_text(encoding="utf-8"))

    adr_txt = adr003_path.read_text(encoding="utf-8")

    # ── R01: Android SessionManager owns TrustedHandshakeController instances ──
    if "TrustedHandshakeController" not in kt_sm:
        errors.append("Android SessionManager must reference TrustedHandshakeController (R01)")
    if "controllers" not in kt_sm or "TrustedHandshakeController" not in kt_sm:
        errors.append("Android SessionManager must own TrustedHandshakeController registry (R01)")
    if "TrustedHandshakeController.initiator" not in kt_sm or "TrustedHandshakeController.responder" not in kt_sm:
        errors.append("Android SessionManager must construct TrustedHandshakeController instances (R01)")
    if re.search(r'controllers\s*[:=]\s*(?:HashMap|MutableMap|ConcurrentHashMap)<[^,>]+,\s*NoiseSession>', kt_sm):
        errors.append("Android SessionManager must NOT store raw NoiseSession instances in controllers (R01)")

    # ── R02: iOS SessionManager owns TrustedHandshakeController instances ──
    if "TrustedHandshakeController" not in swift_sm:
        errors.append("iOS SessionManager must reference TrustedHandshakeController (R02)")
    if "controllers" not in swift_sm:
        errors.append("iOS SessionManager must own TrustedHandshakeController registry (R02)")
    if "TrustedHandshakeController.initiator" not in swift_sm or "TrustedHandshakeController.responder" not in swift_sm:
        errors.append("iOS SessionManager must construct TrustedHandshakeController instances (R02)")
    if re.search(r'controllers\s*:\s*\[\s*UUID\s*:\s*NoiseSession\s*\]', swift_sm):
        errors.append("iOS SessionManager must NOT store raw NoiseSession instances in controllers (R02)")

    # ── R03: Android SessionManager.seal and open require READY state under lifecycle lock ──
    if "fun seal(" not in kt_sm or "fun open(" not in kt_sm:
        errors.append("Android SessionManager missing seal or open methods (R03)")
    if "HandshakeTrustState.READY" not in kt_sm:
        errors.append("Android SessionManager seal/open must gate on HandshakeTrustState.READY (R03)")
    if "lifecycleRwLock" not in kt_sm:
        errors.append("Android SessionManager must use lifecycle read/write lock for operation linearizability (R03)")

    # ── R04: iOS SessionManager.seal and open require READY state under lifecycle lock ──
    if "func seal(" not in swift_sm or "func open(" not in swift_sm:
        errors.append("iOS SessionManager missing seal or open methods (R04)")
    if ".ready" not in swift_sm:
        errors.append("iOS SessionManager seal/open must gate on .ready state (R04)")
    if "lifecycleRwLock" not in swift_sm:
        errors.append("iOS SessionManager must use lifecycle read/write lock for operation linearizability (R04)")

    # ── R05: Android SessionManager per-peer serialization ──
    if "peerLocks" not in kt_sm and "getPeerLock" not in kt_sm:
        errors.append("Android SessionManager missing per-peer serialization locks (R05)")

    # ── R06: iOS SessionManager per-peer serialization ──
    if "peerLocks" not in swift_sm and "getPeerLock" not in swift_sm:
        errors.append("iOS SessionManager missing per-peer serialization locks (R06)")

    # ── R07: Android RuntimeLifecycleGate / RuntimeInvalidator authority ──
    if "interface RuntimeLifecycleGate" not in kt_gate or "interface RuntimeInvalidator" not in kt_gate:
        errors.append("Android RuntimeLifecycleGate / RuntimeInvalidator interfaces missing (R07)")
    if "class DefaultRuntimeLifecycleGate" not in kt_gate:
        errors.append("Android DefaultRuntimeLifecycleGate missing (R07)")

    # ── R08: iOS RuntimeLifecycleGate / RuntimeInvalidator authority ──
    if "protocol RuntimeLifecycleGate" not in swift_gate or "protocol RuntimeInvalidator" not in swift_gate:
        errors.append("iOS RuntimeLifecycleGate / RuntimeInvalidator protocols missing (R08)")
    if "class DefaultRuntimeLifecycleGate" not in swift_gate:
        errors.append("iOS DefaultRuntimeLifecycleGate missing (R08)")

    # ── R09: Android MeshRuntimeInvalidator closes stores and invalidates gate without swallowed exceptions ──
    if "class MeshRuntimeInvalidator" not in kt_gate:
        errors.append("Android MeshRuntimeInvalidator missing (R09)")
    if "lifecycleGate.invalidateForWipe()" not in kt_gate:
        errors.append("Android MeshRuntimeInvalidator must invalidate lifecycleGate (R09)")
    if "peerStore?.close()" not in kt_gate:
        errors.append("Android MeshRuntimeInvalidator must close peerStore (R09)")
    if "messageStore?.close()" not in kt_gate:
        errors.append("Android MeshRuntimeInvalidator must close messageStore (R09)")
    if "catch (_: Exception)" in kt_gate or "catch (e: Exception)" in kt_gate or "catch (t: Throwable)" in kt_gate:
        errors.append("Android MeshRuntimeInvalidator must NOT swallow closure exceptions (R09)")

    # ── R10: iOS MeshRuntimeInvalidator closes stores and invalidates gate ──
    if "class MeshRuntimeInvalidator" not in swift_gate:
        errors.append("iOS MeshRuntimeInvalidator missing (R10)")
    if "lifecycleGate.invalidateForWipe()" not in swift_gate:
        errors.append("iOS MeshRuntimeInvalidator must invalidate lifecycleGate (R10)")
    if "peerStore?.close()" not in swift_gate:
        errors.append("iOS MeshRuntimeInvalidator must close peerStore (R10)")
    if "messageStore?.close()" not in swift_gate:
        errors.append("iOS MeshRuntimeInvalidator must close messageStore (R10)")

    # ── R11: Android RuntimeGatedPeerIdentityLookupSource and RuntimeGatedPeerBindingTrustAuthority ──
    if "class RuntimeGatedPeerIdentityLookupSource" not in kt_gate:
        errors.append("Android RuntimeGatedPeerIdentityLookupSource missing (R11)")
    if "class RuntimeGatedPeerBindingTrustAuthority" not in kt_gate:
        errors.append("Android RuntimeGatedPeerBindingTrustAuthority missing (R11)")

    # ── R12: iOS RuntimeGatedPeerIdentityLookupSource and RuntimeGatedPeerBindingTrustAuthority ──
    if "class RuntimeGatedPeerIdentityLookupSource" not in swift_gate:
        errors.append("iOS RuntimeGatedPeerIdentityLookupSource missing (R12)")
    if "class RuntimeGatedPeerBindingTrustAuthority" not in swift_gate:
        errors.append("iOS RuntimeGatedPeerBindingTrustAuthority missing (R12)")

    # ── R13: Android RuntimeAwareWipeArtifacts used in active MeshPanicWipe composition ──
    if "class RuntimeAwareWipeArtifacts" not in kt_gate:
        errors.append("Android RuntimeAwareWipeArtifacts missing (R13)")
    if "invalidator.invalidateForWipe()" not in kt_gate or "delegate.eraseKeys()" not in kt_gate:
        errors.append("Android RuntimeAwareWipeArtifacts must invalidate before delegate.eraseKeys (R13)")
    if "class MeshPanicWipe" not in kt_mesh_mod or "RuntimeAwareWipeArtifacts" not in kt_mesh_mod:
        errors.append("Android MeshModule must define MeshPanicWipe using RuntimeAwareWipeArtifacts (R13)")

    # ── R14: iOS RuntimeAwareWipeArtifacts used in active MeshRuntime wipe ──
    if "class RuntimeAwareWipeArtifacts" not in swift_gate:
        errors.append("iOS RuntimeAwareWipeArtifacts missing (R14)")
    if "invalidator.invalidateForWipe()" not in swift_gate or "delegate.eraseKeys()" not in swift_gate:
        errors.append("iOS RuntimeAwareWipeArtifacts must invalidate before delegate.eraseKeys (R14)")
    if "func beginPanicWipe()" not in swift_mesh_runtime or "RuntimeAwareWipeArtifacts" not in swift_mesh_runtime:
        errors.append("iOS MeshRuntime must provide beginPanicWipe using RuntimeAwareWipeArtifacts (R14)")

    # ── R15: Android MeshModule wires BoundRecipientKeyResolver and SessionManager ──
    if "BoundRecipientKeyResolver" not in kt_mesh_mod:
        errors.append("Android MeshModule must wire BoundRecipientKeyResolver (R15)")
    if "SessionManager" not in kt_mesh_mod:
        errors.append("Android MeshModule must wire SessionManager (R15)")
    if "DefaultRuntimeLifecycleGate" not in kt_mesh_mod:
        errors.append("Android MeshModule must wire DefaultRuntimeLifecycleGate (R15)")
    if "provideMeshRuntimeInvalidator" not in kt_mesh_mod or "provideMeshPanicWipe" not in kt_mesh_mod:
        errors.append("Android MeshModule must provide MeshRuntimeInvalidator and MeshPanicWipe (R15)")

    # ── R16: iOS MeshRuntime wires BoundRecipientKeyResolver and SessionManager ──
    if "BoundRecipientKeyResolver" not in swift_mesh_runtime:
        errors.append("iOS MeshRuntime must wire BoundRecipientKeyResolver (R16)")
    if "SessionManager" not in swift_mesh_runtime:
        errors.append("iOS MeshRuntime must wire SessionManager (R16)")
    if "DefaultRuntimeLifecycleGate" not in swift_mesh_runtime:
        errors.append("iOS MeshRuntime must wire DefaultRuntimeLifecycleGate (R16)")
    if "invalidator" not in swift_mesh_runtime or "MeshRuntimeInvalidator" not in swift_mesh_runtime:
        errors.append("iOS MeshRuntime must own MeshRuntimeInvalidator (R16)")

    # ── R17: Android MeshModule startup wipe barrier precedes sensitive opens ──
    if "MeshStartupWipeBarrier" not in kt_mesh_mod:
        errors.append("Android MeshModule must define MeshStartupWipeBarrier (R17)")
    if "_barrier: MeshStartupWipeBarrier" not in kt_mesh_mod:
        errors.append("Android MeshModule sensitive providers must depend on MeshStartupWipeBarrier (R17)")

    # ── R18: iOS MeshRuntime binds default startup artifacts to exact store URLs ──
    if "storeUrl: messageStoreUrl" not in swift_mesh_runtime or "peerStoreUrl: peerStoreUrl" not in swift_mesh_runtime:
        errors.append("iOS MeshRuntime.create must bind default startup artifacts to messageStoreUrl and peerStoreUrl (R18)")

    # ── R19: Android MeshNode consumes trusted SessionManager and forbids independent identity load ──
    if "sessions: io.godstone.mesh.crypto.SessionManager" not in kt_mesh_node and "sessions: SessionManager" not in kt_mesh_node:
        errors.append("Android MeshNode must require SessionManager authority (R19)")
    if "canStart(" not in kt_mesh_node or "sessions.isActive" not in kt_mesh_node:
        errors.append("Android MeshNode.start must check canStart(linkReady) with sessions.isActive (R19)")
    if "Identity.loadOrCreate" in kt_mesh_node:
        errors.append("Android MeshNode must not independently invoke Identity.loadOrCreate (R19)")

    # ── R20: iOS MeshNode consumes trusted SessionManager and checks canStart ──
    if "sessions: SessionManager" not in swift_mesh_node:
        errors.append("iOS MeshNode must require SessionManager authority (R20)")
    if "canStart(" not in swift_mesh_node or "sessions.isActive" not in swift_mesh_node:
        errors.append("iOS MeshNode.start must check canStart(linkReady) with sessions.isActive (R20)")

    # ── R21: iOS AppContainer remains strictly Archive-only ──
    for forbidden in ["GodstoneMesh", "MeshRuntime", "BoundRecipientKeyResolver", "SessionManager", "MeshNode"]:
        if forbidden in swift_app_container:
            errors.append(f"iOS AppContainer must NOT reference {forbidden} (R21)")

    # ── R22: Android shipping LIGHT root boundary ──
    android_app_dir = ROOT / "godstone-android" / "app"
    if android_app_dir.exists():
        for kt_file in android_app_dir.rglob("*.kt"):
            content = strip_comments(kt_file.read_text(encoding="utf-8"))
            if "io.godstone.mesh" in content or "MeshRuntime" in content:
                errors.append(f"Shipping Android app file {kt_file.name} must NOT import mesh runtime (R22)")

    # ── R23: Link layer ready flags remain false ──
    if "LINK_LAYER_READY = false" not in kt_mesh_node:
        errors.append("Android MeshNode LINK_LAYER_READY must remain false (R23)")
    if "linkLayerReady = false" not in swift_mesh_node:
        errors.append("iOS MeshNode linkLayerReady must remain false (R23)")

    # ── R24: ADR-003 Section 7.3 status ──
    if "LINK_LAYER_READY = false" not in adr_txt and "linkLayerReady = false" not in adr_txt:
        errors.append("ADR-003 must confirm link layer flags remain false (R24)")

    # ── R25: Android SessionManagerTest inventory (SM01-SM12) ──
    sm_methods = [
        "testSessionManager_InitiatorStart_Returns32ByteHs1",
        "testSessionManager_ResponderProcessHs1_Returns229ByteHs2",
        "testSessionManager_InitiatorProcessHs2_Emits197ByteHs3_AndReachesReady",
        "testSessionManager_ResponderProcessHs3_ReachesReady",
        "testSessionManager_SealAndOpen_RoundTripSucceedsOnlyWhenReady",
        "testSessionManager_SealBeforeReady_ReturnsNull",
        "testSessionManager_OpenBeforeReady_ReturnsNull",
        "testSessionManager_QuarantinedHandshake_NeverReachesReady_SealFails",
        "testSessionManager_RejectedHandshake_NeverReachesReady_SealFails",
        "testSessionManager_DropPeer_CleansUpController_SealFails",
        "testSessionManager_DestroyAll_DestroysAllControllers",
        "testSessionManager_InvalidateForWipe_PermanentlyRefusesNewAndExistingSessions",
    ]
    for m in sm_methods:
        if m not in kt_test_sm:
            errors.append(f"Android SessionManagerTest missing canonical test: {m} (R25)")

    # ── R26: iOS SessionManagerTests inventory (SM01-SM12) ──
    for m in sm_methods:
        if m not in swift_test_sm:
            errors.append(f"iOS SessionManagerTests missing canonical test: {m} (R26)")

    # ── R27: Android CompositionResolverAckTest inventory (CR01-CR08) ──
    cr_methods = [
        "testComposition_ActiveTofuPeer_ResolvesSigningKey_AndValidAckSucceeds",
        "testComposition_UserVerifiedPeer_ResolvesSigningKey_AndValidAckSucceeds",
        "testComposition_QuarantinedPeer_ResolverReturnsNull_AndAckFails",
        "testComposition_RevokedPeer_ResolverReturnsNull_AndAckFails",
        "testComposition_UnseenPeer_ResolverReturnsNull_AndAckFails",
        "testComposition_ApprovedPendingRotation_RestoresAckResolution",
        "testComposition_TamperedAckSignature_FailsVerification",
        "testComposition_SameRepositoryBacksResolverAndTrustAuthority",
    ]
    for m in cr_methods:
        if m not in kt_test_cr:
            errors.append(f"Android CompositionResolverAckTest missing canonical test: {m} (R27)")

    # ── R28: iOS CompositionResolverAckTests inventory (CR01-CR08) ──
    for m in cr_methods:
        if m not in swift_test_cr:
            errors.append(f"iOS CompositionResolverAckTests missing canonical test: {m} (R28)")

    # ── R29: Android WipeLifecycleTest, SessionManagerConcurrencyTest, CrashStartupResumeTest ──
    wipe_methods = [
        "testWipe_CleanIdle_NoOp",
        "testWipe_FullExecution_ErasesKeysAndDeletesArtifactsAndRegeneratesIdentity",
        "testWipe_DeterministicOrdering_GateSessionsPeerMessageKeys",
        "testWipe_SessionManagerInvalidated_RefusesAllOperations",
        "testWipe_ResolverReturnsNull_AfterInvalidation",
        "testWipe_TrustAuthorityReturnsStorageFailure_AfterInvalidation",
        "testWipe_W04_PeerStoreClosed_AfterInvalidation",
        "testWipe_W05_MessageStoreClosed_AfterInvalidation",
        "testWipe_W06_InvalidatorFailure_PreventsKeyErasure_PreservesRequestedState",
        "testWipe_CrashAtRequested_ResumesWipeAndCompletes",
        "testWipe_CrashAtKeyErased_ResumesWipeAndCompletes",
        "testWipe_CrashAtArtifactsDeleted_ResumesWipeAndCompletes",
        "testWipe_CrashAtNewIdentity_ResumesWipeAndCompletes",
        "testWipe_OldRuntimeHandleRemainsInvalid_AfterWipeCompletes",
        "testWipe_FreshRuntimeInstance_AfterWipeWorksNormally",
        "testWipe_W15_RealDatabaseArtifactsAndSidecars_DeletedAfterClosure",
    ]
    # ── R29: Android WipeLifecycleTest, SessionManagerConcurrencyTest, CrashStartupResumeTest ──
    for m in wipe_methods:
        if m not in kt_test_wipe:
            errors.append(f"Android WipeLifecycleTest missing canonical test: {m} (R29)")

    # Android SessionManager invalidation-attempt hook
    if "testInvalidationAttemptHook" not in kt_sm or not re.search(r"fun\s+invalidateForWipe\(\)\s*\{\s*testInvalidationAttemptHook\?\.invoke\(\)\s*lifecycleRwLock\.write", kt_sm):
        errors.append("Android SessionManager invalidateForWipe missing testInvalidationAttemptHook invocation immediately before write authority (R29)")

    # Android Concurrency semantics (RC01-RC03)
    if "testRC01_ResolverLookupVsInvalidation" not in kt_test_concurrency:
        errors.append("Android SessionManagerConcurrencyTest missing testRC01_ResolverLookupVsInvalidation (R29)")
    if "testRC02_ReadySealVsInvalidation" not in kt_test_concurrency:
        errors.append("Android SessionManagerConcurrencyTest missing testRC02_ReadySealVsInvalidation (R29)")
    else:
        if not re.search(r"testRC02_ReadySealVsInvalidation.*?enteredReadAuthority.*?testInvalidationAttemptHook\s*=\s*\{\s*invalidationStarted\.countDown\(\)\s*\}.*?invalidationStarted\.await.*?assertEquals\(1L,\s*invalidationFinished\.count\).*?releaseThreadA\.countDown\(\).*?invalidationFinished\.await", kt_test_concurrency, re.DOTALL):
            errors.append("Android SessionManagerConcurrencyTest RC02 missing deterministic invalidationStarted boundary / pre-release invalidationFinished check (R29)")
    if "testRC03_HandshakeProcessingVsInvalidation" not in kt_test_concurrency:
        errors.append("Android SessionManagerConcurrencyTest missing testRC03_HandshakeProcessingVsInvalidation (R29)")
    else:
        if not re.search(r"testRC03_HandshakeProcessingVsInvalidation.*?responderProcessHs1.*?enteredHsReadAuthority.*?testInvalidationAttemptHook\s*=\s*\{\s*invalidationStarted\.countDown\(\)\s*\}.*?invalidationStarted\.await.*?assertEquals\(1L,\s*invalidationFinished\.count\).*?releaseHsThread\.countDown\(\).*?invalidationFinished\.await", kt_test_concurrency, re.DOTALL):
            errors.append("Android SessionManagerConcurrencyTest RC03 missing real responderProcessHs1 HS2 / deterministic invalidationStarted boundary (R29)")

    if "Thread.yield()" in kt_test_concurrency or "Thread.sleep" in kt_test_concurrency:
        errors.append("Android SessionManagerConcurrencyTest contains timing assumptions (Thread.yield/Thread.sleep) (R29)")

    # Android Startup semantics (SR01-SR07)
    startup_methods = [
        "testSR01_CleanLaunch_InitializesRuntimeNormally",
        "testSR02_PendingWipe_Requested_FinishesBeforeRuntimeInitialization",
        "testSR03_KeyErased_DeletesExactStoreArtifactsBeforeOpen",
        "testSR04_ArtifactsDeleted_RegeneratesIdentityBeforeRuntimeConstruction",
        "testSR05_FreshRuntime_AfterWipe_HasDifferentNodeId",
        "testSR06_FreshPeerStore_ContainsNoPriorPeerRecords",
        "testSR07_OldRuntimeHandle_RemainsPermanentlyUnusable",
    ]
    for m in startup_methods:
        if m not in kt_test_startup:
            errors.append(f"Android CrashStartupResumeTest missing canonical test: {m} (R29)")

    if not re.search(r"eraseKeys.*deleteArtifacts.*regenerateIdentity.*identityOpen.*failedIdentityOpens", kt_test_startup, re.DOTALL):
        errors.append("Android CrashStartupResumeTest SR02 missing recovery-before-open ordering or fail-closed assertions (R29)")

    if not re.search(r"sr03_msg\.db.*sr03_peer\.db.*allArtifacts.*KEY_ERASED.*deletedBeforeOpen.*JdbcPeerIdentityStore\(peerFile\)", kt_test_startup, re.DOTALL):
        errors.append("Android CrashStartupResumeTest SR03 missing exact artifact deletion / same path store open (R29)")

    if not re.search(r"RuntimeAwareWipeArtifacts.*PanicWipe\(.*\.begin\(\).*oldNodeId.*newIdentity\.nodeId.*bindingGeneration", kt_test_startup, re.DOTALL):
        errors.append("Android CrashStartupResumeTest SR05 missing actual wipe invocation or causal node change assertion (R29)")

    if not re.search(r"applyValidatedBinding.*lookup1.*MeshRuntimeInvalidator.*deleteArtifacts.*JdbcPeerIdentityStore\(peerFile\).*lookup2.*NotFound", kt_test_startup, re.DOTALL):
        errors.append("Android CrashStartupResumeTest SR06 missing prior peer insertion / same-path fresh store / post-wipe absence proof (R29)")

    if not re.search(r"BoundRecipientKeyResolver.*SessionManager.*MeshRuntimeInvalidator.*PanicWipe.*sm\.seal.*resolver\.publicSigningKey", kt_test_startup, re.DOTALL):
        errors.append("Android CrashStartupResumeTest SR07 missing full runtime authority / runtime invalidation / post-wipe denial assertions (R29)")

    # ── R30: iOS WipeLifecycleTests, SessionManagerConcurrencyTests, CrashStartupResumeTests ──
    for m in wipe_methods:
        if m not in swift_test_wipe:
            errors.append(f"iOS WipeLifecycleTests missing canonical test: {m} (R30)")
    for m in startup_methods:
        if m not in swift_test_startup:
            errors.append(f"iOS CrashStartupResumeTests missing canonical test: {m} (R30)")

    # iOS SessionManager invalidation-attempt hook
    if "testInvalidationAttemptHook" not in swift_sm or not re.search(r"func\s+invalidateForWipe\(\)\s*\{\s*testInvalidationAttemptHook\?\(\)\s*lifecycleRwLock\.withWriteLock", swift_sm):
        errors.append("iOS SessionManager invalidateForWipe missing testInvalidationAttemptHook invocation immediately before write authority (R30)")

    # iOS Concurrency semantics (RC01-RC03)
    if "testRC01_ResolverLookupVsInvalidation" not in swift_test_concurrency:
        errors.append("iOS SessionManagerConcurrencyTests missing testRC01_ResolverLookupVsInvalidation (R30)")
    if "testRC02_ReadySealVsInvalidation" not in swift_test_concurrency:
        errors.append("iOS SessionManagerConcurrencyTests missing testRC02_ReadySealVsInvalidation (R30)")
    else:
        if not re.search(r"testRC02_ReadySealVsInvalidation.*?enteredReadAuthority.*?testInvalidationAttemptHook\s*=\s*\{\s*invalidationStarted\.signal\(\)\s*\}.*?invalidationStarted\.wait.*?XCTAssertFalse\(invalidationReturned.*?releaseThreadA\.signal\(\).*?wait\(for:\s*\[threadAFinished,\s*invalidationFinished\]", swift_test_concurrency, re.DOTALL):
            errors.append("iOS SessionManagerConcurrencyTests RC02 missing deterministic invalidationStarted boundary / pre-release invalidationReturned check (R30)")
    if "testRC03_HandshakeProcessingVsInvalidation" not in swift_test_concurrency:
        errors.append("iOS SessionManagerConcurrencyTests missing testRC03_HandshakeProcessingVsInvalidation (R30)")
    else:
        if not re.search(r"testRC03_HandshakeProcessingVsInvalidation.*?responderProcessHs1.*?enteredHsReadAuthority.*?testInvalidationAttemptHook\s*=\s*\{\s*invalidationStarted\.signal\(\)\s*\}.*?invalidationStarted\.wait.*?XCTAssertFalse\(invalidationReturned.*?releaseHsThread\.signal\(\).*?wait\(for:\s*\[hsThreadFinished,\s*invalidationFinished\]", swift_test_concurrency, re.DOTALL):
            errors.append("iOS SessionManagerConcurrencyTests RC03 missing real responderProcessHs1 HS2 / deterministic invalidationStarted boundary (R30)")

    if "Thread.sleep" in swift_test_concurrency or "Thread.yield" in swift_test_concurrency:
        errors.append("iOS SessionManagerConcurrencyTests contains timing assumptions (Thread.sleep/Thread.yield) (R30)")

    # iOS SR05: runtime1 beginPanicWipe, runtime2 SAME store URLs, node id change
    if not re.search(r"runtime1\.beginPanicWipe.*MeshRuntime\.create\(.*messageStoreUrl:\s*msgUrl,\s*peerStoreUrl:\s*peerUrl.*XCTAssertNotEqual\(oldNodeId,\s*runtime2\.identity\.nodeId\)", swift_test_startup, re.DOTALL):
        errors.append("iOS CrashStartupResumeTests SR05 missing runtime1 beginPanicWipe / runtime2 same store URLs / node ID change assertion (R30)")

    # iOS SR06: peer inserted in runtime1, beginPanicWipe, runtime2 SAME peer URL, post-wipe absence
    if not re.search(r"applyValidatedBinding.*lookup1.*runtime1\.beginPanicWipe.*MeshRuntime\.create\(.*peerStoreUrl:\s*peerUrl.*peerIdentityStore\.readRaw.*lookup2.*notFound.*recipientKeyResolver.*XCTAssertNil", swift_test_startup, re.DOTALL):
        errors.append("iOS CrashStartupResumeTests SR06 missing prior peer insertion / same-path fresh store / post-wipe absence proof (R30)")

    # iOS SR07: beginPanicWipe, invalidated gate, inactive sessions, nil resolver
    if not re.search(r"beginPanicWipe.*lifecycleGate\.isInvalidated.*sessionManager\.isActive.*recipientKeyResolver", swift_test_startup, re.DOTALL):
        errors.append("iOS CrashStartupResumeTests SR07 missing post-wipe denial assertions (R30)")

    return errors


def selftest() -> int:
    """Run comprehensive mutation tests verifying each control R01-R30 detects violations."""
    print("Running check_trusted_runtime_composition_controls --selftest...")

    clean_errors = check_controls()
    if clean_errors:
        print(f"::error::Baseline check failed with {len(clean_errors)} errors:", file=sys.stderr)
        for e in clean_errors:
            print(f"  {e}", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory() as td:
        tdp = Path(td)

        f_kt_sm = tdp / "SessionManager.kt"
        f_kt_gate = tdp / "RuntimeLifecycleGate.kt"
        f_kt_mod = tdp / "MeshModule.kt"
        f_kt_node = tdp / "MeshNode.kt"
        f_kt_wipe = tdp / "PanicWipe.kt"
        f_kt_tsm = tdp / "SessionManagerTest.kt"
        f_kt_tcr = tdp / "CompositionResolverAckTest.kt"
        f_kt_twipe = tdp / "WipeLifecycleTest.kt"
        f_kt_tstartup = tdp / "CrashStartupResumeTest.kt"
        f_kt_tconcurrency = tdp / "SessionManagerConcurrencyTest.kt"

        f_swift_sm = tdp / "SessionManager.swift"
        f_swift_gate = tdp / "RuntimeLifecycleGate.swift"
        f_swift_runtime = tdp / "MeshRuntime.swift"
        f_swift_node = tdp / "MeshNode.swift"
        f_swift_app = tdp / "AppContainer.swift"
        f_swift_wipe = tdp / "PanicWipe.swift"
        f_swift_tsm = tdp / "SessionManagerTests.swift"
        f_swift_tcr = tdp / "CompositionResolverAckTests.swift"
        f_swift_twipe = tdp / "WipeLifecycleTests.swift"
        f_swift_tstartup = tdp / "CrashStartupResumeTests.swift"
        f_swift_tconcurrency = tdp / "SessionManagerConcurrencyTests.swift"

        f_adr = tdp / "ADR-003.md"

        def reset_all():
            f_kt_sm.write_text(ANDROID_SM_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_gate.write_text(ANDROID_GATE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_mod.write_text(ANDROID_MESH_MODULE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_node.write_text(ANDROID_MESH_NODE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_wipe.write_text(ANDROID_WIPE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_tsm.write_text(ANDROID_TEST_SM_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_tcr.write_text(ANDROID_TEST_CR_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_twipe.write_text(ANDROID_TEST_WIPE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_tstartup.write_text(ANDROID_TEST_STARTUP_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_tconcurrency.write_text(ANDROID_TEST_CONCURRENCY_PATH.read_text(encoding="utf-8"), encoding="utf-8")

            f_swift_sm.write_text(IOS_SM_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_gate.write_text(IOS_GATE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_runtime.write_text(IOS_MESH_RUNTIME_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_node.write_text(IOS_MESH_NODE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_app.write_text(IOS_APP_CONTAINER_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_wipe.write_text(IOS_WIPE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_tsm.write_text(IOS_TEST_SM_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_tcr.write_text(IOS_TEST_CR_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_twipe.write_text(IOS_TEST_WIPE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_tstartup.write_text(IOS_TEST_STARTUP_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_tconcurrency.write_text(IOS_TEST_CONCURRENCY_PATH.read_text(encoding="utf-8"), encoding="utf-8")

            f_adr.write_text(ADR003_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        def run_check():
            return check_controls(
                android_sm_path=f_kt_sm,
                android_gate_path=f_kt_gate,
                android_mesh_mod_path=f_kt_mod,
                android_mesh_node_path=f_kt_node,
                android_wipe_path=f_kt_wipe,
                android_test_sm_path=f_kt_tsm,
                android_test_cr_path=f_kt_tcr,
                android_test_wipe_path=f_kt_twipe,
                android_test_startup_path=f_kt_tstartup,
                android_test_concurrency_path=f_kt_tconcurrency,
                ios_sm_path=f_swift_sm,
                ios_gate_path=f_swift_gate,
                ios_mesh_runtime_path=f_swift_runtime,
                ios_mesh_node_path=f_swift_node,
                ios_app_container_path=f_swift_app,
                ios_wipe_path=f_swift_wipe,
                ios_test_sm_path=f_swift_tsm,
                ios_test_cr_path=f_swift_tcr,
                ios_test_wipe_path=f_swift_twipe,
                ios_test_startup_path=f_swift_tstartup,
                ios_test_concurrency_path=f_swift_tconcurrency,
                adr003_path=f_adr,
            )

        passed = 0
        failures: list[str] = []

        reset_all()

        # Mutation R01: Store raw NoiseSession in Android SessionManager
        f_kt_sm.write_text(f_kt_sm.read_text(encoding="utf-8").replace("TrustedHandshakeController", "NoiseSession"), encoding="utf-8")
        if any("R01" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R01 was NOT caught")
        reset_all()

        # Mutation R02: Store raw NoiseSession in iOS SessionManager
        f_swift_sm.write_text(f_swift_sm.read_text(encoding="utf-8").replace("TrustedHandshakeController", "NoiseSession"), encoding="utf-8")
        if any("R02" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R02 was NOT caught")
        reset_all()

        # Mutation R03: Remove READY check from Android SessionManager
        f_kt_sm.write_text(f_kt_sm.read_text(encoding="utf-8").replace("HandshakeTrustState.READY", "HandshakeTrustState.INITIAL"), encoding="utf-8")
        if any("R03" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R03 was NOT caught")
        reset_all()

        # Mutation R04: Remove .ready check from iOS SessionManager
        f_swift_sm.write_text(f_swift_sm.read_text(encoding="utf-8").replace(".ready", ".initial"), encoding="utf-8")
        if any("R04" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R04 was NOT caught")
        reset_all()

        # Mutation R05: Remove per-peer locks in Android SessionManager
        f_kt_sm.write_text(f_kt_sm.read_text(encoding="utf-8").replace("peerLocks", "noPeerLocks").replace("getPeerLock", "noGetPeerLock"), encoding="utf-8")
        if any("R05" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R05 was NOT caught")
        reset_all()

        # Mutation R06: Remove per-peer locks in iOS SessionManager
        f_swift_sm.write_text(f_swift_sm.read_text(encoding="utf-8").replace("peerLocks", "noPeerLocks").replace("getPeerLock", "noGetPeerLock"), encoding="utf-8")
        if any("R06" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R06 was NOT caught")
        reset_all()

        # Mutation R07: Remove RuntimeLifecycleGate interface from Android
        f_kt_gate.write_text(f_kt_gate.read_text(encoding="utf-8").replace("interface RuntimeLifecycleGate", "interface DummyGate"), encoding="utf-8")
        if any("R07" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R07 was NOT caught")
        reset_all()

        # Mutation R08: Remove RuntimeLifecycleGate protocol from iOS
        f_swift_gate.write_text(f_swift_gate.read_text(encoding="utf-8").replace("protocol RuntimeLifecycleGate", "protocol DummyGate"), encoding="utf-8")
        if any("R08" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R08 was NOT caught")
        reset_all()

        # Mutation R09a: Android MeshRuntimeInvalidator does not invalidate lifecycleGate
        f_kt_gate.write_text(f_kt_gate.read_text(encoding="utf-8").replace("lifecycleGate.invalidateForWipe()", "// no-op"), encoding="utf-8")
        if any("R09" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R09a was NOT caught")
        reset_all()

        # Mutation R09b: Android MeshRuntimeInvalidator removes peer-store close
        f_kt_gate.write_text(f_kt_gate.read_text(encoding="utf-8").replace("peerStore?.close()", "// peerStore"), encoding="utf-8")
        if any("R09" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R09b was NOT caught")
        reset_all()

        # Mutation R09c: Android MeshRuntimeInvalidator wraps close in swallowed catch
        f_kt_gate.write_text(f_kt_gate.read_text(encoding="utf-8").replace("peerStore?.close()", "try { peerStore?.close() } catch (_: Exception) {}"), encoding="utf-8")
        if any("R09" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R09c was NOT caught")
        reset_all()

        # Mutation R09d: Android MeshRuntimeInvalidator removes message-store close
        f_kt_gate.write_text(f_kt_gate.read_text(encoding="utf-8").replace("messageStore?.close()", "// msgStore"), encoding="utf-8")
        if any("R09" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R09d was NOT caught")
        reset_all()

        # Mutation R10: iOS MeshRuntimeInvalidator does not invalidate lifecycleGate
        f_swift_gate.write_text(f_swift_gate.read_text(encoding="utf-8").replace("lifecycleGate.invalidateForWipe()", "// no-op"), encoding="utf-8")
        if any("R10" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R10 was NOT caught")
        reset_all()

        # Mutation R11: Remove RuntimeGatedPeerIdentityLookupSource from Android
        f_kt_gate.write_text(f_kt_gate.read_text(encoding="utf-8").replace("class RuntimeGatedPeerIdentityLookupSource", "class DummyLookupSource"), encoding="utf-8")
        if any("R11" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R11 was NOT caught")
        reset_all()

        # Mutation R12: Remove RuntimeGatedPeerIdentityLookupSource from iOS
        f_swift_gate.write_text(f_swift_gate.read_text(encoding="utf-8").replace("class RuntimeGatedPeerIdentityLookupSource", "class DummyLookupSource"), encoding="utf-8")
        if any("R12" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R12 was NOT caught")
        reset_all()

        # Mutation R13: Android MeshModule uses plain AndroidWipeArtifacts instead of RuntimeAwareWipeArtifacts
        f_kt_mod.write_text(f_kt_mod.read_text(encoding="utf-8").replace("RuntimeAwareWipeArtifacts", "PlainWipeArtifacts"), encoding="utf-8")
        if any("R13" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R13 was NOT caught")
        reset_all()

        # Mutation R14: iOS MeshRuntime active wipe bypasses RuntimeAwareWipeArtifacts
        f_swift_runtime.write_text(f_swift_runtime.read_text(encoding="utf-8").replace("RuntimeAwareWipeArtifacts", "PlainWipeArtifacts"), encoding="utf-8")
        if any("R14" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R14 was NOT caught")
        reset_all()

        # Mutation R15: Android MeshModule does not wire BoundRecipientKeyResolver
        f_kt_mod.write_text(f_kt_mod.read_text(encoding="utf-8").replace("BoundRecipientKeyResolver", "UnresolvedRecipientKeyResolver"), encoding="utf-8")
        if any("R15" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R15 was NOT caught")
        reset_all()

        # Mutation R16: iOS MeshRuntime does not wire BoundRecipientKeyResolver
        f_swift_runtime.write_text(f_swift_runtime.read_text(encoding="utf-8").replace("BoundRecipientKeyResolver", "UnresolvedKeyResolver"), encoding="utf-8")
        if any("R16" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R16 was NOT caught")
        reset_all()

        # Mutation R17: Android MeshModule sensitive providers omit MeshStartupWipeBarrier
        f_kt_mod.write_text(f_kt_mod.read_text(encoding="utf-8").replace("_barrier: MeshStartupWipeBarrier", "// no barrier"), encoding="utf-8")
        if any("R17" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R17 was NOT caught")
        reset_all()

        # Mutation R18: iOS MeshRuntime.create does not bind exact URLs
        f_swift_runtime.write_text(f_swift_runtime.read_text(encoding="utf-8").replace("storeUrl: messageStoreUrl", "storeUrl: nil"), encoding="utf-8")
        if any("R18" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R18 was NOT caught")
        reset_all()

        # Mutation R19a: Android MeshNode removes canStart / sessions.isActive check
        f_kt_node.write_text(f_kt_node.read_text(encoding="utf-8").replace("sessions.isActive", "true"), encoding="utf-8")
        if any("R19" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R19a was NOT caught")
        reset_all()

        # Mutation R19b: Android MeshNode reintroduces Identity.loadOrCreate
        f_kt_node.write_text(f_kt_node.read_text(encoding="utf-8") + "\nfun dummy() = Identity.loadOrCreate(ctx)\n", encoding="utf-8")
        if any("R19" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R19b was NOT caught")
        reset_all()

        # Mutation R20: iOS MeshNode removes canStart / sessions.isActive check
        f_swift_node.write_text(f_swift_node.read_text(encoding="utf-8").replace("sessions.isActive", "true"), encoding="utf-8")
        if any("R20" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R20 was NOT caught")
        reset_all()

        # Mutation R21: Wire MeshRuntime into iOS AppContainer
        f_swift_app.write_text(f_swift_app.read_text(encoding="utf-8") + "\nprivate var runtime: MeshRuntime?\n", encoding="utf-8")
        if any("R21" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R21 was NOT caught")
        reset_all()

        # Mutation R23: Android MeshNode flip LINK_LAYER_READY to true
        f_kt_node.write_text(f_kt_node.read_text(encoding="utf-8").replace("LINK_LAYER_READY = false", "LINK_LAYER_READY = true"), encoding="utf-8")
        if any("R23" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R23 was NOT caught")
        reset_all()

        # Mutation R25: Remove canonical test from Android SessionManagerTest
        f_kt_tsm.write_text(f_kt_tsm.read_text(encoding="utf-8").replace("testSessionManager_InitiatorStart_Returns32ByteHs1", "testOldInitiator"), encoding="utf-8")
        if any("R25" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R25 was NOT caught")
        reset_all()

        # Mutation R26: Remove canonical test from iOS SessionManagerTests
        f_swift_tsm.write_text(f_swift_tsm.read_text(encoding="utf-8").replace("testSessionManager_InitiatorStart_Returns32ByteHs1", "testOldInitiator"), encoding="utf-8")
        if any("R26" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R26 was NOT caught")
        reset_all()

        # Mutation R27: Remove canonical test from Android CompositionResolverAckTest
        f_kt_tcr.write_text(f_kt_tcr.read_text(encoding="utf-8").replace("testComposition_ActiveTofuPeer_ResolvesSigningKey_AndValidAckSucceeds", "testOldTofuAck"), encoding="utf-8")
        if any("R27" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R27 was NOT caught")
        reset_all()

        # Mutation R28: Remove canonical test from iOS CompositionResolverAckTests
        f_swift_tcr.write_text(f_swift_tcr.read_text(encoding="utf-8").replace("testComposition_ActiveTofuPeer_ResolvesSigningKey_AndValidAckSucceeds", "testOldTofuAck"), encoding="utf-8")
        if any("R28" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R28 was NOT caught")
        reset_all()

        # Mutation R29a: Remove canonical test from Android WipeLifecycleTest
        f_kt_twipe.write_text(f_kt_twipe.read_text(encoding="utf-8").replace("testWipe_W04_PeerStoreClosed_AfterInvalidation", "testOldWipeHandles"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R29a was NOT caught")
        reset_all()

        # Mutation R29_SR02: Move sensitive open marker before recovery in Android CrashStartupResumeTest
        f_kt_tstartup.write_text(f_kt_tstartup.read_text(encoding="utf-8").replace("eraseKeys", "identityOpen"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R29_SR02 was NOT caught")
        reset_all()

        # Mutation R29_SR03: Switch recovered peer/message artifact to unrelated path in Android CrashStartupResumeTest
        f_kt_tstartup.write_text(f_kt_tstartup.read_text(encoding="utf-8").replace("sr03_peer.db", "unrelated_other.db"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R29_SR03 was NOT caught")
        reset_all()

        # Mutation R29_SR05: Replace actual wipe path with two independent MeshIdentity.generate() calls
        f_kt_tstartup.write_text(f_kt_tstartup.read_text(encoding="utf-8").replace("RuntimeAwareWipeArtifacts", "PlainFakeArtifacts"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R29_SR05 was NOT caught")
        reset_all()

        # Mutation R29_SR06a: Remove prior peer insertion in Android CrashStartupResumeTest
        f_kt_tstartup.write_text(f_kt_tstartup.read_text(encoding="utf-8").replace("applyValidatedBinding", "// no-insert"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R29_SR06a was NOT caught")
        reset_all()

        # Mutation R29_SR06b: Fresh store uses a different DB path in Android CrashStartupResumeTest
        f_kt_tstartup.write_text(f_kt_tstartup.read_text(encoding="utf-8").replace("JdbcPeerIdentityStore(peerFile)", "JdbcPeerIdentityStore(differentFile)"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R29_SR06b was NOT caught")
        reset_all()

        # Mutation R29_SR07: Replace runtime invalidation with bare gate invalidation in Android CrashStartupResumeTest
        f_kt_tstartup.write_text(f_kt_tstartup.read_text(encoding="utf-8").replace("MeshRuntimeInvalidator", "BareGateOnly"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R29_SR07 was NOT caught")
        reset_all()

        # Mutation R29_RC02: Remove the in-operation barrier in Android SessionManagerConcurrencyTest
        f_kt_tconcurrency.write_text(f_kt_tconcurrency.read_text(encoding="utf-8").replace("enteredReadAuthority", "noBarrier"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R29_RC02 was NOT caught")
        reset_all()

        # Mutation R29_RC03: Replace real handshake stage with bogus zero HS2 race in Android SessionManagerConcurrencyTest
        f_kt_tconcurrency.write_text(f_kt_tconcurrency.read_text(encoding="utf-8").replace("responderProcessHs1", "bogusZeroHs1"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R29_RC03 was NOT caught")
        reset_all()

        # Mutation R30a: Remove canonical test from iOS WipeLifecycleTests
        f_swift_twipe.write_text(f_swift_twipe.read_text(encoding="utf-8").replace("testWipe_W04_PeerStoreClosed_AfterInvalidation", "testOldWipeHandles"), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R30a was NOT caught")
        reset_all()

        # Mutation R30_SR05: runtime2 uses unrelated URLs in iOS CrashStartupResumeTests
        f_swift_tstartup.write_text(f_swift_tstartup.read_text(encoding="utf-8").replace("messageStoreUrl: msgUrl,\n            peerStoreUrl: peerUrl", "messageStoreUrl: unrelatedMsgUrl,\n            peerStoreUrl: unrelatedPeerUrl"), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R30_SR05 was NOT caught")
        reset_all()

        # Mutation R30_SR06a: Remove prior peer insertion in iOS CrashStartupResumeTests
        f_swift_tstartup.write_text(f_swift_tstartup.read_text(encoding="utf-8").replace("applyValidatedBinding", "// no-apply"), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R30_SR06a was NOT caught")
        reset_all()

        # Mutation R30_SR06b: runtime2 uses unrelated peer URL in iOS CrashStartupResumeTests
        f_swift_tstartup.write_text(f_swift_tstartup.read_text(encoding="utf-8").replace("peerStoreUrl: peerUrl", "peerStoreUrl: otherPeerUrl"), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R30_SR06b was NOT caught")
        reset_all()

        # Mutation R30_RC02: Remove the in-operation barrier in iOS SessionManagerConcurrencyTests
        f_swift_tconcurrency.write_text(f_swift_tconcurrency.read_text(encoding="utf-8").replace("enteredReadAuthority", "noBarrier"), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R30_RC02 was NOT caught")
        reset_all()

        # Mutation R30_RC03: Replace deterministic handshake interleaving with opportunistic race in iOS SessionManagerConcurrencyTests
        f_swift_tconcurrency.write_text(f_swift_tconcurrency.read_text(encoding="utf-8").replace("responderProcessHs1", "bogusZeroHs1"), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R30_RC03 was NOT caught")
        reset_all()

        # Mutation M46 (R29_HOOK): Remove testInvalidationAttemptHook invocation from Android SessionManager
        f_kt_sm.write_text(f_kt_sm.read_text(encoding="utf-8").replace("testInvalidationAttemptHook?.invoke()", "// no-hook"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation M46 (R29_HOOK) was NOT caught")
        reset_all()

        # Mutation M47 (R29_RC02_START): Remove invalidationStarted synchronization from Android RC02
        f_kt_tconcurrency.write_text(f_kt_tconcurrency.read_text(encoding="utf-8").replace("invalidationStarted.countDown()", "// no-start-signal"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation M47 (R29_RC02_START) was NOT caught")
        reset_all()

        # Mutation M48 (R29_RC02_ORDER): Move pre-release invalidation check after releaseThreadA in Android RC02
        old_block_kt_rc02 = "assertEquals(1L, invalidationFinished.count)\n\n        // Release Thread A\n        releaseThreadA.countDown()"
        new_block_kt_rc02 = "releaseThreadA.countDown()\n\n        assertEquals(1L, invalidationFinished.count)"
        f_kt_tconcurrency.write_text(f_kt_tconcurrency.read_text(encoding="utf-8").replace(old_block_kt_rc02, new_block_kt_rc02), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation M48 (R29_RC02_ORDER) was NOT caught")
        reset_all()

        # Mutation M49 (R29_YIELD): Reintroduce Thread.yield() in Android SessionManagerConcurrencyTest
        f_kt_tconcurrency.write_text(f_kt_tconcurrency.read_text(encoding="utf-8").replace("package io.godstone.mesh.crypto", "package io.godstone.mesh.crypto\nfun yieldHelper() { Thread.yield() }"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation M49 (R29_YIELD) was NOT caught")
        reset_all()

        # Mutation M50 (R29_RC03_START): Remove invalidationStarted boundary from Android RC03
        f_kt_tconcurrency.write_text(f_kt_tconcurrency.read_text(encoding="utf-8").replace("smA.testInvalidationAttemptHook = {\n            invalidationStarted.countDown()\n        }", "smA.testInvalidationAttemptHook = null"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation M50 (R29_RC03_START) was NOT caught")
        reset_all()

        # Mutation M51 (R30_HOOK): Remove testInvalidationAttemptHook invocation from iOS SessionManager
        f_swift_sm.write_text(f_swift_sm.read_text(encoding="utf-8").replace("testInvalidationAttemptHook?()", "// no-hook"), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation M51 (R30_HOOK) was NOT caught")
        reset_all()

        # Mutation M52 (R30_RC02_SLEEP): Replace deterministic boundary with Thread.sleep in iOS RC02
        f_swift_tconcurrency.write_text(f_swift_tconcurrency.read_text(encoding="utf-8").replace("XCTAssertFalse(invalidationReturned", "Thread.sleep(forTimeInterval: 0.01)\n        XCTAssertFalse(invalidationReturned"), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation M52 (R30_RC02_SLEEP) was NOT caught")
        reset_all()

        # Mutation M53 (R30_RC02_ASSERT): Remove pre-release invalidation-not-returned assertion in iOS RC02
        f_swift_tconcurrency.write_text(f_swift_tconcurrency.read_text(encoding="utf-8").replace('XCTAssertFalse(invalidationReturned, "invalidation must NOT return while Thread A holds read lock")', '// no assert'), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation M53 (R30_RC02_ASSERT) was NOT caught")
        reset_all()

        # Mutation M54 (R30_RC03_SLEEP): Replace deterministic boundary with Thread.sleep in iOS RC03
        f_swift_tconcurrency.write_text(f_swift_tconcurrency.read_text(encoding="utf-8").replace("releaseHsThread.signal()", "Thread.sleep(forTimeInterval: 0.01)\n        releaseHsThread.signal()"), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation M54 (R30_RC03_SLEEP) was NOT caught")
        reset_all()

        # Mutation M55 (R30_RC03_START): Remove invalidationStarted synchronization from iOS RC03
        f_swift_tconcurrency.write_text(f_swift_tconcurrency.read_text(encoding="utf-8").replace("smA.testInvalidationAttemptHook = {\n            invalidationStarted.signal()\n        }", "smA.testInvalidationAttemptHook = nil"), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation M55 (R30_RC03_START) was NOT caught")
        reset_all()

    if failures:
        for f in failures:
            print(f"::error::selftest failure: {f}")
        return 1

    print(f"check_trusted_runtime_composition_controls selftest PASSED ({passed}/55 mutations caught deterministically across R01-R30).")
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
            print(f"::error::Trusted runtime composition control error: {e}", file=sys.stderr)
        print(f"\nFAIL: {len(errors)} trusted runtime composition control issue(s) found.", file=sys.stderr)
        return 1

    print("TRUSTED RUNTIME COMPOSITION CONTROLS GATE: PASS -- non-shipping graph, wipe lifecycle, and boundaries satisfied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
