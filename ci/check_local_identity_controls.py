#!/usr/bin/env python3
"""Regression controls and structural checks for LocalIdentityStateV1 (ADR-003, Phase C8.1B.2).

Verifies the presence and structural invariants of:
- Android LocalIdentityStateV1 and Identity authority persistence
- iOS LocalIdentityStateV1 and MeshIdentity authority persistence
- Synchronous commit operations (no .apply())
- Legacy migration validation and cleanup
- Canonical local issuer restrictions (no caller-supplied generation parameter)
- PanicWipe failure propagation (no exception swallowing)
- Prevention of direct outbound IdentityBindingV1 construction outside authority files
- iOS production signing using Apple CryptoKit (no handwritten Ed25519 engine)
- iOS semantic cryptographic conformance tests (exact preimage, signature verification, prefix(69), validator)
- Android WipeArtifacts constructor hardening (no zero-argument defaults)
- Internal visibility barriers on keychain protocols, prefs constants, and private key accessors
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

ANDROID_MESH_ROOT = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh"
IOS_MESH_ROOT = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh"

ANDROID_STATE_PATH = ANDROID_MESH_ROOT / "identity" / "LocalIdentityStateV1.kt"
ANDROID_ID_PATH = ANDROID_MESH_ROOT / "identity" / "Identity.kt"
ANDROID_WIPE_PATH = ANDROID_MESH_ROOT / "identity" / "PanicWipe.kt"
ANDROID_TEST_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "identity" / "LocalIdentityStateV1Test.kt"

IOS_STATE_PATH = IOS_MESH_ROOT / "LocalIdentityStateV1.swift"
IOS_ID_PATH = IOS_MESH_ROOT / "MeshIdentity.swift"
IOS_WIPE_PATH = IOS_MESH_ROOT / "PanicWipe.swift"
IOS_TEST_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "LocalIdentityStateV1Tests.swift"


def check_local_identity_controls(
    a_state: Path = ANDROID_STATE_PATH,
    a_id: Path = ANDROID_ID_PATH,
    a_wipe: Path = ANDROID_WIPE_PATH,
    a_test: Path = ANDROID_TEST_PATH,
    i_state: Path = IOS_STATE_PATH,
    i_id: Path = IOS_ID_PATH,
    i_wipe: Path = IOS_WIPE_PATH,
    i_test: Path = IOS_TEST_PATH,
    android_mesh_root: Path = ANDROID_MESH_ROOT,
    ios_mesh_root: Path = IOS_MESH_ROOT,
) -> list[str]:
    errors: list[str] = []

    # 1. Existence
    for path, name in [
        (a_state, "Android LocalIdentityStateV1"),
        (a_id, "Android Identity"),
        (a_wipe, "Android PanicWipe"),
        (a_test, "Android LocalIdentityStateV1Test"),
        (i_state, "iOS LocalIdentityStateV1"),
        (i_id, "iOS MeshIdentity"),
        (i_wipe, "iOS PanicWipe"),
        (i_test, "iOS LocalIdentityStateV1Tests"),
    ]:
        if not path.exists():
            errors.append(f"Missing required file: {name} ({path})")

    if errors:
        return errors

    # 2. Production Cryptography Checks (Section 9)
    if (ios_mesh_root / "Ed25519Signer.swift").exists():
        errors.append("Forbidden file Ed25519Signer.swift found in iOS production source; must use platform CryptoKit")

    i_id_text = i_id.read_text(encoding="utf-8")
    if "Ed25519Signer" in i_id_text:
        errors.append("iOS MeshIdentity must not invoke Ed25519Signer; must use platform CryptoKit")
    if "signingKey.signature(for:" not in i_id_text:
        errors.append("iOS MeshIdentity must use signingKey.signature(for:) for production signing")

    # 3. Android State & Identity checks
    a_state_text = a_state.read_text(encoding="utf-8")
    if "LOCAL_IDENTITY_STATE_LENGTH: Int = 69" not in a_state_text:
        errors.append("Android LocalIdentityStateV1 missing 69-byte length definition (LOCAL_IDENTITY_STATE_LENGTH: Int = 69)")
    if "LOCAL_IDENTITY_STATE_VERSION: Byte = 0x01" not in a_state_text:
        errors.append("Android LocalIdentityStateV1 missing version 0x01 (LOCAL_IDENTITY_STATE_VERSION: Byte = 0x01)")
    if "ushr 24" not in a_state_text or "ushr 16" not in a_state_text:
        errors.append("Android LocalIdentityStateV1 missing big-endian generation encoding shifts")

    a_id_text = a_id.read_text(encoding="utf-8")
    if ".apply()" in a_id_text or ".apply()" in a_state_text:
        errors.append("Android Identity persistence must not use asynchronous .apply(); commit() required")
    if "commit()" not in a_state_text:
        errors.append("Android EncryptedSharedPreferencesStorage must use synchronous commit()")
    if "generation = 0L" not in a_id_text and "generation = 0" not in a_id_text:
        errors.append("Android fresh identity must initialize with generation = 0")
    if "storage.hasPartialLegacy()" not in a_id_text or "throw" not in a_id_text:
        errors.append("Android Identity must fail closed on partial legacy state (hasPartialLegacy check required)")
    if "!derivedEdPub.contentEquals(legacy.idPub)" not in a_id_text:
        errors.append("Android Identity must validate legacy Ed public key against derived private seed")
    if "!derivedDhPub.contentEquals(legacy.dhPub)" not in a_id_text:
        errors.append("Android Identity must validate legacy X public key against derived private key")
    if re.search(r"fun\s+issueIdentityBinding\s*\([^)]+\)", a_id_text):
        errors.append("Android issueIdentityBinding must have no caller-supplied parameters")
    if re.search(r"(?:public\s+val|val\s+)staticDhPriv\b", a_id_text) and not re.search(r"internal\s+val\s+staticDhPriv\b", a_id_text):
        errors.append("Android staticDhPriv accessor must be internal, not public")
    if not re.search(r"internal\s+const\s+val\s+PREFS\b", a_id_text):
        errors.append("Android Identity.PREFS constant must be internal, not public")
    if "signaturePreimage" not in a_id_text:
        errors.append("Android issueIdentityBinding must construct canonical signaturePreimage")
    if "Ed25519Keys.sign" not in a_id_text:
        errors.append("Android issueIdentityBinding must use Ed25519Keys.sign")
    if "Ed25519Keys.verify" not in a_id_text:
        errors.append("Android issueIdentityBinding must perform signature self-verification")

    a_wipe_text = a_wipe.read_text(encoding="utf-8")
    if "runCatching" in a_wipe_text:
        errors.append("AndroidWipeArtifacts.eraseKeys must not swallow KeyStore errors with runCatching")
    if re.search(r"class\s+AndroidWipeArtifacts\s*\(\s*(?:private\s+)?val\s+ctx:\s*Context\?\s*=\s*null", a_wipe_text):
        errors.append("AndroidWipeArtifacts must not have default null Context constructor")

    # 4. iOS State & MeshIdentity checks
    i_state_text = i_state.read_text(encoding="utf-8")
    if "localIdentityStateLength: Int = 69" not in i_state_text:
        errors.append("iOS LocalIdentityStateV1 missing 69-byte length definition (localIdentityStateLength: Int = 69)")
    if "localIdentityStateVersion: UInt8 = 0x01" not in i_state_text:
        errors.append("iOS LocalIdentityStateV1 missing version 0x01 (localIdentityStateVersion: UInt8 = 0x01)")
    if "bigEndian" not in i_state_text and "<< 24" not in i_state_text:
        errors.append("iOS LocalIdentityStateV1 missing big-endian generation encoding")
    if "load(as: UInt32.self)" in i_state_text:
        errors.append("iOS LocalIdentityStateV1 must not use raw memory load(as: UInt32.self); explicit byte shifts required")
    if "public protocol LocalIdentityKeychain" in i_state_text:
        errors.append("iOS LocalIdentityKeychain protocol must be internal, not public")
    if "public struct DefaultLocalIdentityKeychain" in i_state_text or "public final class DefaultLocalIdentityKeychain" in i_state_text:
        errors.append("iOS DefaultLocalIdentityKeychain must be internal, not public")
    if "guard status == errSecSuccess" not in i_state_text:
        errors.append("iOS DefaultLocalIdentityKeychain.add must check status == errSecSuccess")

    if "io.godstone.mesh.identity.v1" not in i_id_text:
        errors.append("iOS MeshIdentity missing canonical V1 tag 'io.godstone.mesh.identity.v1'")
    if "identityAlreadyExists" not in i_id_text:
        errors.append("iOS generateAndStore must fail if identity already exists")
    if re.search(r"func\s+generateAndStore\b[^{]*\{[^}]*SecItemDelete", i_id_text, re.DOTALL):
        errors.append("iOS generateAndStore must not perform delete-before-add")
    if re.search(r"(?:public|internal)\s+init\s*\([^)]*bindingGeneration", i_id_text, re.DOTALL):
        errors.append("iOS MeshIdentity must not expose an initializer accepting bindingGeneration")
    if "public let agreementKey" in i_id_text or "public var agreementKey" in i_id_text:
        errors.append("iOS agreementKey accessor must be internal, not public")
    if "public func sign(message:" in i_id_text:
        errors.append("iOS generic sign(message:) must be internal, not public")
    if re.search(r"public\s+static\s+func\s+loadFromKeychain\s*\([^)]*keychain\s*:", i_id_text):
        errors.append("iOS public loadFromKeychain must not expose a keychain parameter")
    if re.search(r"public\s+static\s+func\s+generateAndStore\s*\([^)]*keychain\s*:", i_id_text):
        errors.append("iOS public generateAndStore must not expose a keychain parameter")
    if re.search(r"public\s+static\s+func\s+deleteFromKeychain\s*\([^)]*keychain\s*:", i_id_text):
        errors.append("iOS public deleteFromKeychain must not expose a keychain parameter")
    if re.search(r"func\s+issueIdentityBinding\s*\([^)]+\)", i_id_text):
        errors.append("iOS issueIdentityBinding must have no caller-supplied parameters")
    if "isValidSignature" not in i_id_text:
        errors.append("iOS issueIdentityBinding must perform signature self-verification")
    if "public let signingKey" in i_id_text or "var signingKey" in i_id_text or "internal let signingKey" in i_id_text:
        errors.append("iOS signingKey must remain private in MeshIdentity")

    # Check deleteFromKeychain covers V1 + legacy tags
    delete_funcs = re.findall(r"func\s+deleteFromKeychain\b[^{]*\{.*?\n    \}", i_id_text, re.DOTALL)
    if not delete_funcs or not any("v1Tag" in df for df in delete_funcs):
        errors.append("iOS deleteFromKeychain must delete v1Tag")
    if not delete_funcs or not any("legacySigningTag" in df for df in delete_funcs):
        errors.append("iOS deleteFromKeychain must delete legacySigningTag")
    if not delete_funcs or not any("legacyAgreementTag" in df for df in delete_funcs):
        errors.append("iOS deleteFromKeychain must delete legacyAgreementTag")

    # Check iOS wipe error propagation
    i_wipe_text = i_wipe.read_text(encoding="utf-8")
    if "try MeshIdentity.deleteFromKeychain" not in i_wipe_text:
        errors.append("iOS KeychainWipeArtifacts.eraseKeys must propagate deleteFromKeychain errors")
    if re.search(r"func\s+eraseKeys\b.*?\bcatch\b", i_wipe_text, re.DOTALL):
        errors.append("iOS KeychainWipeArtifacts.eraseKeys must not swallow deletion errors in catch block")
    if "try MeshIdentity.generateAndStore" not in i_wipe_text:
        errors.append("iOS KeychainWipeArtifacts.regenerateIdentity must propagate generateAndStore errors")
    if re.search(r"func\s+regenerateIdentity\b.*?\bcatch\b", i_wipe_text, re.DOTALL):
        errors.append("iOS KeychainWipeArtifacts.regenerateIdentity must not swallow regeneration errors in catch block")

    # Check iOS test semantic KAT assertions (Section 9)
    i_test_text = i_test.read_text(encoding="utf-8")
    if "IdentityBindingV1.signaturePreimage" not in i_test_text:
        errors.append("iOS LocalIdentityStateV1Tests must assert exact signaturePreimage")
    if "test20Vector1IssuesValidSemanticBinding" not in i_test_text or "vec1Serialized.subdata(in: 5..<37)" not in i_test_text:
        errors.append("iOS LocalIdentityStateV1Tests must assert vector 1 exact public keys and preimage")
    if "test21Vector2IssuesValidEndianLockBinding" not in i_test_text or "vec2Serialized.subdata(in: 5..<37)" not in i_test_text:
        errors.append("iOS LocalIdentityStateV1Tests must assert vector 2 exact public keys and preimage")
    if "test22Vector3IssuesValidMaxGenerationBinding" not in i_test_text or "vec3Serialized.subdata(in: 5..<37)" not in i_test_text:
        errors.append("iOS LocalIdentityStateV1Tests must assert vector 3 exact public keys and preimage")
    if "isValidSignature(binding.signature" not in i_test_text:
        errors.append("iOS LocalIdentityStateV1Tests must perform cryptographic signature verification")
    if "encoded.count, 133" not in i_test_text and "binding.encode().count, 133" not in i_test_text:
        errors.append("iOS LocalIdentityStateV1Tests must assert 133-byte encoded length")
    if "prefix(69)" not in i_test_text:
        errors.append("iOS LocalIdentityStateV1Tests must assert exact prefix(69) canonical field encoding")
    if "IdentityBindingValidator.validate" not in i_test_text:
        errors.append("iOS LocalIdentityStateV1Tests must assert validator acceptance")

    # 5. Outbound issuance bypass check (Section 29)
    if android_mesh_root.exists():
        for f in android_mesh_root.rglob("*.kt"):
            if f.name in ["Identity.kt", "IdentityBindingV1.kt", "LocalIdentityStateV1.kt", "Ed25519Keys.kt", "X25519Keys.kt"]:
                continue
            text = f.read_text(encoding="utf-8")
            if "IdentityBindingV1.create(" in text or "IdentityBindingV1(" in text:
                errors.append(f"Android production file {f.name} contains direct IdentityBindingV1 construction outside Identity authority")

    if ios_mesh_root.exists():
        for f in ios_mesh_root.rglob("*.swift"):
            if f.name in ["MeshIdentity.swift", "IdentityBindingV1.swift", "LocalIdentityStateV1.swift"]:
                continue
            text = f.read_text(encoding="utf-8")
            if re.search(r"\bIdentityBindingV1\s*\(", text):
                errors.append(f"iOS production file {f.name} contains direct IdentityBindingV1 construction outside MeshIdentity authority")

    return errors


def selftest() -> int:
    """Run all named mutation negative controls against isolated temporary trees."""
    print("Running check_local_identity_controls --selftest...")
    failures: list[str] = []
    passed_mutations = 0

    mutations: list[tuple[str, str, callable]] = []

    def make_tree():
        tmpdir = tempfile.mkdtemp()
        t = Path(tmpdir)
        a_mesh = t / "android_mesh"
        a_mesh.mkdir(parents=True)
        (a_mesh / "identity").mkdir()
        i_mesh = t / "ios_mesh"
        i_mesh.mkdir(parents=True)

        a_state = a_mesh / "identity" / "LocalIdentityStateV1.kt"
        a_id = a_mesh / "identity" / "Identity.kt"
        a_wipe = a_mesh / "identity" / "PanicWipe.kt"
        a_test = t / "LocalIdentityStateV1Test.kt"

        i_state = i_mesh / "LocalIdentityStateV1.swift"
        i_id = i_mesh / "MeshIdentity.swift"
        i_wipe = i_mesh / "PanicWipe.swift"
        i_test = t / "LocalIdentityStateV1Tests.swift"

        a_state.write_text(ANDROID_STATE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        a_id.write_text(ANDROID_ID_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        a_wipe.write_text(ANDROID_WIPE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        a_test.write_text(ANDROID_TEST_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        i_state.write_text(IOS_STATE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        i_id.write_text(IOS_ID_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        i_wipe.write_text(IOS_WIPE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        i_test.write_text(IOS_TEST_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        return tmpdir, a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh

    # M1: Android identity persistence changes commit() to apply()
    def mutate_m1(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        a_state.write_text(a_state.read_text(encoding="utf-8").replace("commit()", "apply()"), encoding="utf-8")
    mutations.append(("M1", "apply()", mutate_m1))

    # M2: Android partial legacy state falls through to fresh generation
    def mutate_m2(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        a_id.write_text(a_id.read_text(encoding="utf-8").replace("if (storage.hasPartialLegacy())", "if (false)"), encoding="utf-8")
    mutations.append(("M2", "hasPartialLegacy check required", mutate_m2))

    # M3: Android legacy Ed public/private validation removed
    def mutate_m3(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        a_id.write_text(a_id.read_text(encoding="utf-8").replace("if (!derivedEdPub.contentEquals(legacy.idPub))", "if (false)"), encoding="utf-8")
    mutations.append(("M3", "validate legacy Ed public key", mutate_m3))

    # M4: Android legacy X public/private validation removed
    def mutate_m4(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        a_id.write_text(a_id.read_text(encoding="utf-8").replace("if (!derivedDhPub.contentEquals(legacy.dhPub))", "if (false)"), encoding="utf-8")
    mutations.append(("M4", "validate legacy X public key", mutate_m4))

    # M5: Android issueIdentityBinding gains generation argument
    def mutate_m5(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        a_id.write_text(a_id.read_text(encoding="utf-8").replace("fun issueIdentityBinding(): IdentityBindingV1", "fun issueIdentityBinding(generation: Long): IdentityBindingV1"), encoding="utf-8")
    mutations.append(("M5", "issueIdentityBinding must have no caller-supplied parameters", mutate_m5))

    # M6: Android staticDhPriv becomes public
    def mutate_m6(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        a_id.write_text(a_id.read_text(encoding="utf-8").replace("internal val staticDhPriv", "public val staticDhPriv"), encoding="utf-8")
    mutations.append(("M6", "staticDhPriv accessor must be internal", mutate_m6))

    # M7: Android production source outside Identity contains IdentityBindingV1.create(...) issuance bypass
    def mutate_m7(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        fake_file = a_mesh / "Bypass.kt"
        fake_file.write_text("package io.godstone.mesh\nclass Bypass { fun run() { IdentityBindingV1.create(0L, ByteArray(32), ByteArray(32), ByteArray(64)) } }", encoding="utf-8")
    mutations.append(("M7", "Android production file Bypass.kt contains direct IdentityBindingV1 construction", mutate_m7))

    # M8: Android eraseKeys wraps/ignores KeyStore failure
    def mutate_m8(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        a_wipe.write_text(a_wipe.read_text(encoding="utf-8").replace("ks.deleteEntry(MASTER_KEY_ALIAS)", "kotlin.runCatching { ks.deleteEntry(MASTER_KEY_ALIAS) }"), encoding="utf-8")
    mutations.append(("M8", "swallow KeyStore errors with runCatching", mutate_m8))

    # M9: 69-byte Android state length changed
    def mutate_m9(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        a_state.write_text(a_state.read_text(encoding="utf-8").replace("LOCAL_IDENTITY_STATE_LENGTH: Int = 69", "LOCAL_IDENTITY_STATE_LENGTH: Int = 70"), encoding="utf-8")
    mutations.append(("M9", "69-byte length", mutate_m9))

    # M10: Android fresh generation changed from 0
    def mutate_m10(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        a_id.write_text(a_id.read_text(encoding="utf-8").replace("generation = 0L", "generation = 1L"), encoding="utf-8")
    mutations.append(("M10", "generation = 0", mutate_m10))

    # M11: iOS LocalIdentityKeychain becomes public
    def mutate_m11(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_state.write_text(i_state.read_text(encoding="utf-8").replace("internal protocol LocalIdentityKeychain", "public protocol LocalIdentityKeychain"), encoding="utf-8")
    mutations.append(("M11", "LocalIdentityKeychain protocol must be internal", mutate_m11))

    # M12: iOS DefaultLocalIdentityKeychain becomes public
    def mutate_m12(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_state.write_text(i_state.read_text(encoding="utf-8").replace("internal final class DefaultLocalIdentityKeychain", "public final class DefaultLocalIdentityKeychain"), encoding="utf-8")
    mutations.append(("M12", "DefaultLocalIdentityKeychain must be internal", mutate_m12))

    # M13: iOS MeshIdentity initializer becomes internal/public and accepts bindingGeneration
    def mutate_m13(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_id.write_text(re.sub(r"private\s+init\s*\(", "public init(", i_id.read_text(encoding="utf-8")), encoding="utf-8")
    mutations.append(("M13", "initializer accepting bindingGeneration", mutate_m13))

    # M14: iOS agreementKey becomes public
    def mutate_m14(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_id.write_text(i_id.read_text(encoding="utf-8").replace("internal let agreementKey", "public let agreementKey"), encoding="utf-8")
    mutations.append(("M14", "agreementKey accessor must be internal", mutate_m14))

    # M15: iOS generic sign(message:) becomes public
    def mutate_m15(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_id.write_text(i_id.read_text(encoding="utf-8").replace("internal func sign(message:", "public func sign(message:"), encoding="utf-8")
    mutations.append(("M15", "generic sign(message:) must be internal", mutate_m15))

    # M16: iOS public loadFromKeychain exposes a keychain argument
    def mutate_m16(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_id.write_text(i_id.read_text(encoding="utf-8").replace("public static func loadFromKeychain()", "public static func loadFromKeychain(keychain: any LocalIdentityKeychain = DefaultLocalIdentityKeychain())"), encoding="utf-8")
    mutations.append(("M16", "public loadFromKeychain must not expose a keychain parameter", mutate_m16))

    # M17: iOS public generateAndStore exposes a keychain argument
    def mutate_m17(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_id.write_text(i_id.read_text(encoding="utf-8").replace("public static func generateAndStore()", "public static func generateAndStore(keychain: any LocalIdentityKeychain = DefaultLocalIdentityKeychain())"), encoding="utf-8")
    mutations.append(("M17", "public generateAndStore must not expose a keychain parameter", mutate_m17))

    # M18: iOS public deleteFromKeychain exposes a keychain argument
    def mutate_m18(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_id.write_text(i_id.read_text(encoding="utf-8").replace("public static func deleteFromKeychain()", "public static func deleteFromKeychain(keychain: any LocalIdentityKeychain = DefaultLocalIdentityKeychain())"), encoding="utf-8")
    mutations.append(("M18", "public deleteFromKeychain must not expose a keychain parameter", mutate_m18))

    # M19: iOS SecItemAdd OSStatus guard is removed
    def mutate_m19(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_state.write_text(i_state.read_text(encoding="utf-8").replace("guard status == errSecSuccess", "if status == 0"), encoding="utf-8")
    mutations.append(("M19", "check status == errSecSuccess", mutate_m19))

    # M20: iOS fresh generation performs delete-before-add
    def mutate_m20(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_id.write_text(i_id.read_text(encoding="utf-8").replace("let v1Data = try keychain.read(tag: v1Tag)", "_ = SecItemDelete([:] as CFDictionary)\n        let v1Data = try keychain.read(tag: v1Tag)"), encoding="utf-8")
    mutations.append(("M20", "must not perform delete-before-add", mutate_m20))

    # M21: iOS production source outside MeshIdentity constructs IdentityBindingV1(...) for outbound issuance
    def mutate_m21(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        fake_swift = i_mesh / "Bypass.swift"
        fake_swift.write_text("import Foundation\nfunc bypass() { _ = IdentityBindingV1(generation: 0, signingPublicKey: Data(), staticDhPublicKey: Data(), signature: Data()) }", encoding="utf-8")
    mutations.append(("M21", "iOS production file Bypass.swift contains direct IdentityBindingV1 construction", mutate_m21))

    # M22 (C1): Introduce Ed25519Signer.swift into iOS production tree
    def mutate_m22(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        (i_mesh / "Ed25519Signer.swift").write_text("// forbidden manual signer\n", encoding="utf-8")
    mutations.append(("M22_C1", "Forbidden file Ed25519Signer.swift found", mutate_m22))

    # M23 (C2): Replace CryptoKit signing with Ed25519Signer.sign call
    def mutate_m23(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_id.write_text(i_id.read_text(encoding="utf-8").replace("try signingKey.signature(for: preimage)", "Ed25519Signer.sign(message: preimage, seed: signingKey.rawRepresentation)"), encoding="utf-8")
    mutations.append(("M23_C2", "must not invoke Ed25519Signer", mutate_m23))

    # M24 (C3): Remove vector-1 exact preimage assertion
    def mutate_m24(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_test.write_text(i_test.read_text(encoding="utf-8").replace("vec1Serialized.subdata(in: 5..<37)", "// removed"), encoding="utf-8")
    mutations.append(("M24_C3", "vector 1 exact public keys", mutate_m24))

    # M25 (C4): Remove vector-2 exact preimage assertion
    def mutate_m25(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_test.write_text(i_test.read_text(encoding="utf-8").replace("vec2Serialized.subdata(in: 5..<37)", "// removed"), encoding="utf-8")
    mutations.append(("M25_C4", "vector 2 exact public keys", mutate_m25))

    # M26 (C5): Remove vector-3 exact preimage assertion
    def mutate_m26(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_test.write_text(i_test.read_text(encoding="utf-8").replace("vec3Serialized.subdata(in: 5..<37)", "// removed"), encoding="utf-8")
    mutations.append(("M26_C5", "vector 3 exact public keys", mutate_m26))

    # M27 (C6): Remove signature verification assertion
    def mutate_m27(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_test.write_text(i_test.read_text(encoding="utf-8").replace("isValidSignature(binding.signature", "true //"), encoding="utf-8")
    mutations.append(("M27_C6", "cryptographic signature verification", mutate_m27))

    # M28 (C7): Remove 133-byte length assertion
    def mutate_m28(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_test.write_text(i_test.read_text(encoding="utf-8").replace("encoded.count, 133", "encoded.count, 134"), encoding="utf-8")
    mutations.append(("M28_C7", "133-byte encoded length", mutate_m28))

    # M29 (C8): Remove prefix(69) canonical-field assertion
    def mutate_m29(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_test.write_text(i_test.read_text(encoding="utf-8").replace("prefix(69)", "prefix(68)"), encoding="utf-8")
    mutations.append(("M29_C8", "prefix(69)", mutate_m29))

    # M30 (C9): Remove validator acceptance assertion
    def mutate_m30(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_test.write_text(i_test.read_text(encoding="utf-8").replace("IdentityBindingValidator.validate", "// validator removed"), encoding="utf-8")
    mutations.append(("M30_C9", "validator acceptance", mutate_m30))

    # M31: iOS local generation parser reintroduces load(as: UInt32.self)
    def mutate_m31(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_state.write_text(i_state.read_text(encoding="utf-8") + "\n// load(as: UInt32.self)\n", encoding="utf-8")
    mutations.append(("M31", "load(as: UInt32.self)", mutate_m31))

    # M32: iOS deleteFromKeychain omits V1
    def mutate_m32(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_id.write_text(i_id.read_text(encoding="utf-8").replace("try keychain.delete(tag: v1Tag)", "// deleted"), encoding="utf-8")
    mutations.append(("M32", "delete v1Tag", mutate_m32))

    # M33: iOS deleteFromKeychain omits legacy Ed
    def mutate_m33(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_id.write_text(i_id.read_text(encoding="utf-8").replace("try keychain.delete(tag: legacySigningTag)", "// deleted"), encoding="utf-8")
    mutations.append(("M33", "delete legacySigningTag", mutate_m33))

    # M34: iOS deleteFromKeychain omits legacy X
    def mutate_m34(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_id.write_text(i_id.read_text(encoding="utf-8").replace("try keychain.delete(tag: legacyAgreementTag)", "// deleted"), encoding="utf-8")
    mutations.append(("M34", "delete legacyAgreementTag", mutate_m34))

    # M35: iOS wipe erase failure is swallowed
    def mutate_m35(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_wipe.write_text(i_wipe.read_text(encoding="utf-8").replace("try MeshIdentity.deleteFromKeychain(keychain: keychain)", "do { try MeshIdentity.deleteFromKeychain(keychain: keychain) } catch { }"), encoding="utf-8")
    mutations.append(("M35", "eraseKeys must not swallow deletion errors", mutate_m35))

    # M36: iOS wipe regenerate failure is swallowed
    def mutate_m36(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        i_wipe.write_text(i_wipe.read_text(encoding="utf-8").replace("try MeshIdentity.generateAndStore(keychain: keychain)", "do { try MeshIdentity.generateAndStore(keychain: keychain) } catch { }"), encoding="utf-8")
    mutations.append(("M36", "regenerateIdentity must not swallow regeneration errors", mutate_m36))

    # M37: Android PREFS constant is made public
    def mutate_m37(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        a_id.write_text(a_id.read_text(encoding="utf-8").replace("internal const val PREFS", "public const val PREFS"), encoding="utf-8")
    mutations.append(("M37", "Identity.PREFS constant must be internal", mutate_m37))

    # M38: Android WipeArtifacts gains zero-arg default null constructor
    def mutate_m38(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh):
        a_wipe.write_text(a_wipe.read_text(encoding="utf-8").replace("internal class AndroidWipeArtifacts private constructor", "internal class AndroidWipeArtifacts(private val ctx: Context? = null"), encoding="utf-8")
    mutations.append(("M38", "must not have default null Context constructor", mutate_m38))

    # Execute all 38 mutations
    for name, expected_fragment, fn in mutations:
        tmpdir, a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh = make_tree()
        try:
            fn(a_state, a_id, a_wipe, a_test, i_state, i_id, i_wipe, i_test, a_mesh, i_mesh)
            errs = check_local_identity_controls(
                a_state=a_state,
                a_id=a_id,
                a_wipe=a_wipe,
                a_test=a_test,
                i_state=i_state,
                i_id=i_id,
                i_wipe=i_wipe,
                i_test=i_test,
                android_mesh_root=a_mesh,
                ios_mesh_root=i_mesh,
            )
            if any(expected_fragment in e for e in errs):
                passed_mutations += 1
            else:
                failures.append(f"Mutation {name} ({expected_fragment!r}) was NOT detected. Caught errors: {errs}")
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    if failures:
        for f in failures:
            print(f"::error::selftest failure: {f}")
        return 1

    print(f"check_local_identity_controls selftest PASSED ({passed_mutations}/{len(mutations)} mutations caught deterministically).")
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

    errors = check_local_identity_controls()
    if errors:
        for e in errors:
            print(f"::error::Local identity control failure: {e}", file=sys.stderr)
        print(f"\nFAIL: {len(errors)} local identity control issue(s) found.", file=sys.stderr)
        return 1

    print("LOCAL IDENTITY CONTROLS GATE: PASS -- all local identity invariants and boundaries satisfied.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
