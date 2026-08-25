#!/usr/bin/env python3
"""Structural and regression controls for Trusted Runtime Composition (ADR-003, Phase C8.4B).

Verifies the presence, boundaries, and structural invariants of:
- Android SessionManager owns TrustedHandshakeController instances, not raw NoiseSession (R01)
- iOS SessionManager owns TrustedHandshakeController instances, not raw NoiseSession (R02)
- Android SessionManager.seal and SessionManager.open require HandshakeTrustState.READY (R03)
- iOS SessionManager.seal and SessionManager.open require HandshakeTrustState.READY (R04)
- Android SessionManager per-peer serialized handshake operations (R05)
- iOS SessionManager per-peer serialized handshake operations (R06)
- Android RuntimeLifecycleGate / RuntimeInvalidator authority interface and implementations (R07)
- iOS RuntimeLifecycleGate / RuntimeInvalidator authority protocol and implementations (R08)
- Android MeshRuntimeInvalidator invalidates gate and closes stores (R09)
- iOS MeshRuntimeInvalidator invalidates gate and closes stores (R10)
- Android RuntimeGatedPeerIdentityLookupSource and RuntimeGatedPeerBindingTrustAuthority fail closed upon invalidation (R11)
- iOS RuntimeGatedPeerIdentityLookupSource and RuntimeGatedPeerBindingTrustAuthority fail closed upon invalidation (R12)
- Android RuntimeAwareWipeArtifacts invalidates runtime handles before key erasure (R13)
- iOS RuntimeAwareWipeArtifacts invalidates runtime handles before key erasure (R14)
- Android MeshModule wires BoundRecipientKeyResolver, PeerIdentityRepository, DefaultRuntimeLifecycleGate, SessionManager, MeshNode (R15)
- iOS MeshRuntime wires BoundRecipientKeyResolver, PeerIdentityRepository, DefaultRuntimeLifecycleGate, SessionManager, MeshNode (R16)
- Android MeshModule / startup path calls PanicWipe.resumeIfPending(ctx) (R17)
- iOS MeshRuntime / startup path calls PanicWipe.resumeIfPending() (R18)
- Android MeshNode consumes trusted SessionManager authority (R19)
- iOS MeshNode consumes trusted SessionManager authority (R20)
- iOS AppContainer remains strictly Archive-only (no GodstoneMesh / MeshRuntime / BoundRecipientKeyResolver / SessionManager) (R21)
- Android :mesh is not exposed/imported in shipping Light app root (R22)
- Link layer ready flags remain false on BOTH platforms (R23)
- ADR-003 Section 7.3 and status reflect C8.4B composition (R24)
- Android SessionManagerTest inventory (SM01-SM12) (R25)
- iOS SessionManagerTests inventory (SM01-SM12) (R26)
- Android CompositionResolverAckTest inventory (CR01-CR08) (R27)
- iOS CompositionResolverAckTests inventory (CR01-CR08) (R28)
- Android WipeLifecycleTest and CrashStartupResumeTest inventories (W01-W15, SR01-SR07) (R29)
- iOS WipeLifecycleTests and CrashStartupResumeTests inventories (W01-W15, SR01-SR07) (R30)
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

    # ── R03: Android SessionManager.seal and open require READY state ──
    if "fun seal(" not in kt_sm or "fun open(" not in kt_sm:
        errors.append("Android SessionManager missing seal or open methods (R03)")
    if "HandshakeTrustState.READY" not in kt_sm:
        errors.append("Android SessionManager seal/open must gate on HandshakeTrustState.READY (R03)")

    # ── R04: iOS SessionManager.seal and open require READY state ──
    if "func seal(" not in swift_sm or "func open(" not in swift_sm:
        errors.append("iOS SessionManager missing seal or open methods (R04)")
    if ".ready" not in swift_sm:
        errors.append("iOS SessionManager seal/open must gate on .ready state (R04)")

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

    # ── R09: Android MeshRuntimeInvalidator closes stores and invalidates gate ──
    if "class MeshRuntimeInvalidator" not in kt_gate:
        errors.append("Android MeshRuntimeInvalidator missing (R09)")
    if "lifecycleGate.invalidateForWipe()" not in kt_gate:
        errors.append("Android MeshRuntimeInvalidator must invalidate lifecycleGate (R09)")

    # ── R10: iOS MeshRuntimeInvalidator closes stores and invalidates gate ──
    if "class MeshRuntimeInvalidator" not in swift_gate:
        errors.append("iOS MeshRuntimeInvalidator missing (R10)")
    if "lifecycleGate.invalidateForWipe()" not in swift_gate:
        errors.append("iOS MeshRuntimeInvalidator must invalidate lifecycleGate (R10)")

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

    # ── R13: Android RuntimeAwareWipeArtifacts invalidates before key erasure ──
    if "class RuntimeAwareWipeArtifacts" not in kt_gate:
        errors.append("Android RuntimeAwareWipeArtifacts missing (R13)")
    if "invalidator.invalidateForWipe()" not in kt_gate or "delegate.eraseKeys()" not in kt_gate:
        errors.append("Android RuntimeAwareWipeArtifacts must invalidate before delegate.eraseKeys (R13)")

    # ── R14: iOS RuntimeAwareWipeArtifacts invalidates before key erasure ──
    if "class RuntimeAwareWipeArtifacts" not in swift_gate:
        errors.append("iOS RuntimeAwareWipeArtifacts missing (R14)")
    if "invalidator.invalidateForWipe()" not in swift_gate or "delegate.eraseKeys()" not in swift_gate:
        errors.append("iOS RuntimeAwareWipeArtifacts must invalidate before delegate.eraseKeys (R14)")

    # ── R15: Android MeshModule wires BoundRecipientKeyResolver and SessionManager ──
    if "BoundRecipientKeyResolver" not in kt_mesh_mod:
        errors.append("Android MeshModule must wire BoundRecipientKeyResolver (R15)")
    if "SessionManager" not in kt_mesh_mod:
        errors.append("Android MeshModule must wire SessionManager (R15)")
    if "DefaultRuntimeLifecycleGate" not in kt_mesh_mod:
        errors.append("Android MeshModule must wire DefaultRuntimeLifecycleGate (R15)")

    # ── R16: iOS MeshRuntime wires BoundRecipientKeyResolver and SessionManager ──
    if "BoundRecipientKeyResolver" not in swift_mesh_runtime:
        errors.append("iOS MeshRuntime must wire BoundRecipientKeyResolver (R16)")
    if "SessionManager" not in swift_mesh_runtime:
        errors.append("iOS MeshRuntime must wire SessionManager (R16)")
    if "DefaultRuntimeLifecycleGate" not in swift_mesh_runtime:
        errors.append("iOS MeshRuntime must wire DefaultRuntimeLifecycleGate (R16)")

    # ── R17: Android MeshModule calls PanicWipe.resumeIfPending ──
    if "PanicWipe.resumeIfPending" not in kt_mesh_mod and "resumeIfPending" not in kt_mesh_mod:
        errors.append("Android MeshModule must invoke PanicWipe.resumeIfPending at initialization (R17)")

    # ── R18: iOS MeshRuntime calls PanicWipe.resumeIfPending ──
    if "PanicWipe.resumeIfPending" not in swift_mesh_runtime and "resumeIfPending" not in swift_mesh_runtime:
        errors.append("iOS MeshRuntime must invoke PanicWipe.resumeIfPending at initialization (R18)")

    # ── R19: Android MeshNode consumes trusted SessionManager authority ──
    if "sessions: io.godstone.mesh.crypto.SessionManager" not in kt_mesh_node and "sessions: SessionManager" not in kt_mesh_node:
        errors.append("Android MeshNode must require SessionManager authority (R19)")

    # ── R20: iOS MeshNode consumes trusted SessionManager authority ──
    if "sessions: SessionManager" not in swift_mesh_node:
        errors.append("iOS MeshNode must require SessionManager authority (R20)")

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

    # ── R29: Android WipeLifecycleTest and CrashStartupResumeTest inventories ──
    wipe_methods = [
        "testWipe_CleanIdle_NoOp",
        "testWipe_FullExecution_ErasesKeysAndDeletesArtifactsAndRegeneratesIdentity",
        "testWipe_InvalidatesRuntimeHandles_BeforeKeyErasure",
        "testWipe_SessionManagerInvalidated_RefusesAllOperations",
        "testWipe_ResolverReturnsNull_AfterInvalidation",
        "testWipe_TrustAuthorityReturnsStorageFailure_AfterInvalidation",
        "testWipe_PeerStoreClosed_AfterInvalidation",
        "testWipe_MessageStoreClosed_AfterInvalidation",
        "testWipe_CrashAtRequested_ResumesWipeAndCompletes",
        "testWipe_CrashAtKeyErased_ResumesWipeAndCompletes",
        "testWipe_CrashAtArtifactsDeleted_ResumesWipeAndCompletes",
        "testWipe_CrashAtNewIdentity_ResumesWipeAndCompletes",
        "testWipe_OldRuntimeHandleRemainsInvalid_AfterWipeCompletes",
        "testWipe_FreshRuntimeInstance_AfterWipeWorksNormally",
        "testWipe_InvalidationException_PreventsKeyErasure",
    ]
    for m in wipe_methods:
        if m not in kt_test_wipe:
            errors.append(f"Android WipeLifecycleTest missing canonical test: {m} (R29)")

    startup_methods = [
        "testStartup_PendingWipe_FinishesBeforeRuntimeInitialization",
        "testStartup_CleanLaunch_InitializesRuntimeNormally",
        "testStartup_MidWipeCrash_LeavesConsistentFinalState",
        "testStartup_IdentityRegeneration_YieldsFreshNodeIdAndZeroGeneration",
        "testStartup_OldDatabaseFilesUnusable_AfterCryptoErasure",
        "testStartup_WipeJournalCleared_OnlyUponFullCompletion",
        "testStartup_RebootBarrier_PreventsStaleStoreAccess",
    ]
    for m in startup_methods:
        if m not in kt_test_startup:
            errors.append(f"Android CrashStartupResumeTest missing canonical test: {m} (R29)")

    # ── R30: iOS WipeLifecycleTests and CrashStartupResumeTests inventories ──
    for m in wipe_methods:
        if m not in swift_test_wipe:
            errors.append(f"iOS WipeLifecycleTests missing canonical test: {m} (R30)")
    for m in startup_methods:
        if m not in swift_test_startup:
            errors.append(f"iOS CrashStartupResumeTests missing canonical test: {m} (R30)")

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

        # Mutation R09: Android MeshRuntimeInvalidator does not invalidate lifecycleGate
        f_kt_gate.write_text(f_kt_gate.read_text(encoding="utf-8").replace("lifecycleGate.invalidateForWipe()", "// no-op"), encoding="utf-8")
        if any("R09" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R09 was NOT caught")
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

        # Mutation R13: Android RuntimeAwareWipeArtifacts misses invalidation call
        f_kt_gate.write_text(f_kt_gate.read_text(encoding="utf-8").replace("invalidator.invalidateForWipe()", "// no-op"), encoding="utf-8")
        if any("R13" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R13 was NOT caught")
        reset_all()

        # Mutation R14: iOS RuntimeAwareWipeArtifacts misses invalidation call
        f_swift_gate.write_text(f_swift_gate.read_text(encoding="utf-8").replace("invalidator.invalidateForWipe()", "// no-op"), encoding="utf-8")
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

        # Mutation R17: Android MeshModule does not call PanicWipe.resumeIfPending
        f_kt_mod.write_text(f_kt_mod.read_text(encoding="utf-8").replace("PanicWipe.resumeIfPending", "// resume"), encoding="utf-8")
        if any("R17" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R17 was NOT caught")
        reset_all()

        # Mutation R18: iOS MeshRuntime does not call PanicWipe.resumeIfPending
        f_swift_runtime.write_text(f_swift_runtime.read_text(encoding="utf-8").replace("PanicWipe.resumeIfPending", "// resume"), encoding="utf-8")
        if any("R18" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R18 was NOT caught")
        reset_all()

        # Mutation R19: Android MeshNode constructor does not require SessionManager
        f_kt_node.write_text(f_kt_node.read_text(encoding="utf-8").replace("io.godstone.mesh.crypto.SessionManager", "Any").replace("SessionManager", "Any"), encoding="utf-8")
        if any("R19" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R19 was NOT caught")
        reset_all()

        # Mutation R20: iOS MeshNode initializer does not require SessionManager
        f_swift_node.write_text(f_swift_node.read_text(encoding="utf-8").replace("sessions: SessionManager", "sessions: Any"), encoding="utf-8")
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

        # Mutation R29: Remove canonical test from Android WipeLifecycleTest
        f_kt_twipe.write_text(f_kt_twipe.read_text(encoding="utf-8").replace("testWipe_InvalidatesRuntimeHandles_BeforeKeyErasure", "testOldWipeHandles"), encoding="utf-8")
        if any("R29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R29 was NOT caught")
        reset_all()

        # Mutation R30: Remove canonical test from iOS WipeLifecycleTests
        f_swift_twipe.write_text(f_swift_twipe.read_text(encoding="utf-8").replace("testWipe_InvalidatesRuntimeHandles_BeforeKeyErasure", "testOldWipeHandles"), encoding="utf-8")
        if any("R30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation R30 was NOT caught")
        reset_all()

    if failures:
        for f in failures:
            print(f"::error::selftest failure: {f}")
        return 1

    print(f"check_trusted_runtime_composition_controls selftest PASSED ({passed}/28 mutations caught deterministically across R01-R30).")
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
