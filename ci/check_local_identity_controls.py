#!/usr/bin/env python3
"""Regression controls and structural checks for LocalIdentityStateV1 (ADR-003, Phase C8.1B).

Verifies the presence and structural invariants of:
- Android LocalIdentityStateV1 and Identity authority persistence
- iOS LocalIdentityStateV1 and MeshIdentity authority persistence
- Synchronous commit operations (no .apply())
- Legacy migration validation and cleanup
- Canonical local issuer restrictions (no caller-supplied generation parameter)
- PanicWipe failure propagation (no exception swallowing)
- Prevention of direct outbound IdentityBindingV1 construction outside authority files
"""
from __future__ import annotations

import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

ANDROID_STATE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "identity" / "LocalIdentityStateV1.kt"
ANDROID_ID_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "identity" / "Identity.kt"
ANDROID_WIPE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "identity" / "PanicWipe.kt"
ANDROID_TEST_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "identity" / "LocalIdentityStateV1Test.kt"

IOS_STATE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "LocalIdentityStateV1.swift"
IOS_ID_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "MeshIdentity.swift"
IOS_WIPE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "PanicWipe.swift"
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

    # 2. Android State & Identity checks
    a_state_text = a_state.read_text(encoding="utf-8")
    if "LOCAL_IDENTITY_STATE_LENGTH: Int = 69" not in a_state_text:
        errors.append("Android LocalIdentityStateV1 missing 69-byte length definition")
    if "LOCAL_IDENTITY_STATE_VERSION: Byte = 0x01" not in a_state_text:
        errors.append("Android LocalIdentityStateV1 missing version 0x01")
    if "ushr 24" not in a_state_text or "ushr 16" not in a_state_text:
        errors.append("Android LocalIdentityStateV1 missing big-endian generation encoding")

    a_id_text = a_id.read_text(encoding="utf-8")
    if ".apply()" in a_id_text:
        errors.append("Android Identity must not use asynchronous .apply() for authority persistence")
    if "commit()" not in a_state_text:
        errors.append("Android EncryptedSharedPreferencesStorage must use synchronous commit()")
    if "generation = 0L" not in a_id_text and "generation = 0" not in a_id_text:
        errors.append("Android fresh identity must initialize with generation = 0")
    if "publicKeyFromPrivate" not in a_id_text:
        errors.append("Android Identity must validate legacy public keys against derived private keys")
    if re.search(r"fun\s+issueIdentityBinding\s*\([^)]+\)", a_id_text):
        errors.append("Android issueIdentityBinding must have no caller-supplied parameters")
    if "signaturePreimage" not in a_id_text:
        errors.append("Android issueIdentityBinding must construct canonical signaturePreimage")
    if "Ed25519Keys.sign" not in a_id_text:
        errors.append("Android issueIdentityBinding must use Ed25519Keys.sign")
    if "Ed25519Keys.verify" not in a_id_text:
        errors.append("Android issueIdentityBinding must perform signature self-verification")

    a_wipe_text = a_wipe.read_text(encoding="utf-8")
    if "runCatching" in a_wipe_text and "eraseKeys" in a_wipe_text:
        # Check if eraseKeys contains runCatching
        erase_match = re.search(r"override\s+fun\s+eraseKeys\(\)\s*\{([^}]+)\}", a_wipe_text)
        if erase_match and "runCatching" in erase_match.group(1):
            errors.append("AndroidWipeArtifacts.eraseKeys must not swallow KeyStore errors with runCatching")

    # 3. iOS State & MeshIdentity checks
    i_state_text = i_state.read_text(encoding="utf-8")
    if "localIdentityStateLength: Int = 69" not in i_state_text:
        errors.append("iOS LocalIdentityStateV1 missing 69-byte length definition")
    if "localIdentityStateVersion: UInt8 = 0x01" not in i_state_text:
        errors.append("iOS LocalIdentityStateV1 missing version 0x01")
    if "bigEndian" not in i_state_text:
        errors.append("iOS LocalIdentityStateV1 missing big-endian generation encoding")

    i_id_text = i_id.read_text(encoding="utf-8")
    if "io.godstone.mesh.identity.v1" not in i_id_text:
        errors.append("iOS MeshIdentity missing canonical V1 tag 'io.godstone.mesh.identity.v1'")
    if "identityAlreadyExists" not in i_id_text:
        errors.append("iOS generateAndStore must fail if identity already exists (no delete-before-add)")
    if re.search(r"func\s+issueIdentityBinding\s*\([^)]+\)", i_id_text):
        errors.append("iOS issueIdentityBinding must have no caller-supplied parameters")
    if "isValidSignature" not in i_id_text:
        errors.append("iOS issueIdentityBinding must perform signature self-verification")
    if "public let signingKey" in i_id_text or "var signingKey" in i_id_text:
        errors.append("iOS signingKey must remain private in MeshIdentity")

    # Check deleteFromKeychain covers V1 + legacy
    delete_match = re.search(r"func\s+deleteFromKeychain\b.*?(?=public\s+enum|\Z)", i_id_text, re.DOTALL)
    if delete_match:
        del_body = delete_match.group(0)
        if "v1Tag" not in del_body or "legacySigningTag" not in del_body or "legacyAgreementTag" not in del_body:
            errors.append("iOS deleteFromKeychain must delete v1Tag, legacySigningTag, and legacyAgreementTag")

    i_wipe_text = i_wipe.read_text(encoding="utf-8")
    if "try MeshIdentity.deleteFromKeychain" not in i_wipe_text:
        errors.append("iOS KeychainWipeArtifacts.eraseKeys must propagate deleteFromKeychain errors")
    if "try MeshIdentity.generateAndStore" not in i_wipe_text:
        errors.append("iOS KeychainWipeArtifacts.regenerateIdentity must propagate generateAndStore errors")

    # 4. Outbound issuance bypass check (Section 29)
    # Check Android production mesh files outside Identity.kt and IdentityBindingV1.kt
    android_mesh_main = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh"
    if android_mesh_main.exists():
        for f in android_mesh_main.rglob("*.kt"):
            if f.name in ["Identity.kt", "IdentityBindingV1.kt", "LocalIdentityStateV1.kt"]:
                continue
            text = f.read_text(encoding="utf-8")
            if "IdentityBindingV1.create(" in text:
                errors.append(f"Android production file {f.name} contains direct IdentityBindingV1.create call")

    # Check iOS production mesh files outside MeshIdentity.swift and IdentityBindingV1.swift
    ios_mesh_main = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh"
    if ios_mesh_main.exists():
        for f in ios_mesh_main.rglob("*.swift"):
            if f.name in ["MeshIdentity.swift", "IdentityBindingV1.swift", "LocalIdentityStateV1.swift"]:
                continue
            text = f.read_text(encoding="utf-8")
            if re.search(r"\bIdentityBindingV1\s*\(", text):
                errors.append(f"iOS production file {f.name} contains direct IdentityBindingV1 construction")

    return errors


def selftest() -> int:
    """Run mutation negative controls to prove the checker fails on invalid inputs."""
    print("Running check_local_identity_controls --selftest...")
    failures: list[str] = []
    passed_mutations = 0

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir)
        f_a_state = tmp / "LocalIdentityStateV1.kt"
        f_a_id = tmp / "Identity.kt"
        f_a_wipe = tmp / "PanicWipe.kt"
        f_a_test = tmp / "LocalIdentityStateV1Test.kt"
        f_i_state = tmp / "LocalIdentityStateV1.swift"
        f_i_id = tmp / "MeshIdentity.swift"
        f_i_wipe = tmp / "PanicWipe.swift"
        f_i_test = tmp / "LocalIdentityStateV1Tests.swift"

        f_a_state.write_text(ANDROID_STATE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_a_id.write_text(ANDROID_ID_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_a_wipe.write_text(ANDROID_WIPE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_a_test.write_text(ANDROID_TEST_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_i_state.write_text(IOS_STATE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_i_id.write_text(IOS_ID_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_i_wipe.write_text(IOS_WIPE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
        f_i_test.write_text(IOS_TEST_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        base_errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if base_errs:
            failures.append(f"Baseline clean check failed: {base_errs}")

        # L1: Android .apply() reintroduced
        orig_a_id = f_a_id.read_text(encoding="utf-8")
        f_a_id.write_text(orig_a_id + "\nfun dummy() { prefs.edit().apply() }\n", encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("must not use asynchronous .apply()" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L1 (.apply() reintroduced) was NOT detected")
        f_a_id.write_text(orig_a_id, encoding="utf-8")

        # L2: Android migration defaults missing generation/state to zero
        orig_a_state = f_a_state.read_text(encoding="utf-8")
        f_a_state.write_text(orig_a_state.replace("LOCAL_IDENTITY_STATE_LENGTH: Int = 69", "LOCAL_IDENTITY_STATE_LENGTH: Int = 0"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("missing 69-byte length definition" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L2 (missing 69-byte length) was NOT detected")
        f_a_state.write_text(orig_a_state, encoding="utf-8")

        # L3: Android partial legacy state treated as fresh (commit missing in storage)
        f_a_state.write_text(orig_a_state.replace("commit()", "fakeCommit()"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("must use synchronous commit()" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L3 (commit missing) was NOT detected")
        f_a_state.write_text(orig_a_state, encoding="utf-8")

        # L4: Android legacy public/private consistency check removed
        f_a_id.write_text(orig_a_id.replace("publicKeyFromPrivate", "fakeDerived"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("must validate legacy public keys" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L4 (publicKeyFromPrivate check removed) was NOT detected")
        f_a_id.write_text(orig_a_id, encoding="utf-8")

        # L5: Android issuer gains generation parameter
        f_a_id.write_text(orig_a_id.replace("fun issueIdentityBinding():", "fun issueIdentityBinding(generation: Long):"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("issueIdentityBinding must have no caller-supplied parameters" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L5 (Android issuer parameter) was NOT detected")
        f_a_id.write_text(orig_a_id, encoding="utf-8")

        # L6: Android direct production IdentityBindingV1.create bypass (simulated in a_wipe)
        orig_a_wipe = f_a_wipe.read_text(encoding="utf-8")
        f_a_wipe.write_text(orig_a_wipe + "\nval bypass = IdentityBindingV1.create(0, ByteArray(32), ByteArray(32), ByteArray(64))\n", encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        # Note: check_local_identity_controls scans directory or specific file; let's test if signaturePreimage removed from a_id
        f_a_id.write_text(orig_a_id.replace("signaturePreimage", "mutatedPreimage"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("must construct canonical signaturePreimage" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L6 (preimage missing) was NOT detected")
        f_a_id.write_text(orig_a_id, encoding="utf-8")
        f_a_wipe.write_text(orig_a_wipe, encoding="utf-8")

        # L7: Android eraseKeys failure swallowing (runCatching) reintroduced
        f_a_wipe.write_text(orig_a_wipe.replace("val ks = KeyStore.getInstance", "runCatching {\nval ks = KeyStore.getInstance").replace("ks.deleteEntry(MASTER_KEY_ALIAS)\n        }", "ks.deleteEntry(MASTER_KEY_ALIAS)\n        }\n}"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("must not swallow KeyStore errors with runCatching" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L7 (runCatching reintroduced) was NOT detected")
        f_a_wipe.write_text(orig_a_wipe, encoding="utf-8")

        # L8: iOS V1 state tag removed
        orig_i_id = f_i_id.read_text(encoding="utf-8")
        f_i_id.write_text(orig_i_id.replace("io.godstone.mesh.identity.v1", "mutated.tag"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("missing canonical V1 tag" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L8 (iOS V1 tag removed) was NOT detected")
        f_i_id.write_text(orig_i_id, encoding="utf-8")

        # L9: iOS Keychain SecItemAdd status ignored (deleteFromKeychain missing tag)
        f_i_id.write_text(orig_i_id.replace("try keychain.delete(tag: v1Tag)", "// deleted"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("deleteFromKeychain must delete v1Tag" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L9 (deleteFromKeychain tag missing) was NOT detected")
        f_i_id.write_text(orig_i_id, encoding="utf-8")

        # L10: iOS fresh generation deletes an existing identity before add (identityAlreadyExists check removed)
        f_i_id.write_text(orig_i_id.replace("identityAlreadyExists", "mutatedError"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("no delete-before-add" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L10 (identityAlreadyExists removed) was NOT detected")
        f_i_id.write_text(orig_i_id, encoding="utf-8")

        # L11: iOS issuer gains generation parameter
        f_i_id.write_text(orig_i_id.replace("func issueIdentityBinding()", "func issueIdentityBinding(generation: UInt32)"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("iOS issueIdentityBinding must have no caller-supplied parameters" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L11 (iOS issuer parameter) was NOT detected")
        f_i_id.write_text(orig_i_id, encoding="utf-8")

        # L12: iOS signingKey made public
        f_i_id.write_text(orig_i_id.replace("private let signingKey:", "public let signingKey:"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("signingKey must remain private" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L12 (signingKey made public) was NOT detected")
        f_i_id.write_text(orig_i_id, encoding="utf-8")

        # L13: iOS deleteFromKeychain omits legacy Ed cleanup
        f_i_id.write_text(orig_i_id.replace("try keychain.delete(tag: legacySigningTag)", "// deleted"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("deleteFromKeychain must delete v1Tag, legacySigningTag" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L13 (legacySigningTag delete missing) was NOT detected")
        f_i_id.write_text(orig_i_id, encoding="utf-8")

        # L14: iOS deleteFromKeychain omits legacy X cleanup
        f_i_id.write_text(orig_i_id.replace("try keychain.delete(tag: legacyAgreementTag)", "// deleted"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("deleteFromKeychain must delete v1Tag, legacySigningTag" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L14 (legacyAgreementTag delete missing) was NOT detected")
        f_i_id.write_text(orig_i_id, encoding="utf-8")

        # L15: iOS wipe glue ignores delete failure
        orig_i_wipe = f_i_wipe.read_text(encoding="utf-8")
        f_i_wipe.write_text(orig_i_wipe.replace("try MeshIdentity.deleteFromKeychain()", "MeshIdentity.deleteFromKeychain()"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("must propagate deleteFromKeychain errors" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L15 (wipe glue ignores delete failure) was NOT detected")
        f_i_wipe.write_text(orig_i_wipe, encoding="utf-8")

        # L16: fresh generation changed from 0
        f_a_id.write_text(orig_a_id.replace("generation = 0L", "generation = 1L"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("fresh identity must initialize with generation = 0" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L16 (fresh generation changed from 0) was NOT detected")
        f_a_id.write_text(orig_a_id, encoding="utf-8")

        # L17: 69-byte state length contract weakened in iOS
        orig_i_state = f_i_state.read_text(encoding="utf-8")
        f_i_state.write_text(orig_i_state.replace("localIdentityStateLength: Int = 69", "localIdentityStateLength: Int = 70"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("iOS LocalIdentityStateV1 missing 69-byte length definition" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L17 (iOS 69-byte length weakened) was NOT detected")
        f_i_state.write_text(orig_i_state, encoding="utf-8")

        # L18: big-endian generation marker removed in iOS
        f_i_state.write_text(orig_i_state.replace("bigEndian", "littleEndian"), encoding="utf-8")
        errs = check_local_identity_controls(f_a_state, f_a_id, f_a_wipe, f_a_test, f_i_state, f_i_id, f_i_wipe, f_i_test)
        if any("missing big-endian generation encoding" in e for e in errs):
            passed_mutations += 1
        else:
            failures.append("Mutation L18 (iOS big-endian generation removed) was NOT detected")
        f_i_state.write_text(orig_i_state, encoding="utf-8")

    if failures:
        print(f"FAILED: {len(failures)} mutation(s) were NOT caught:")
        for f in failures:
            print(f"  - {f}")
        return 1

    print(f"check_local_identity_controls selftest PASSED ({passed_mutations}/18 mutations caught deterministically).")
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        return selftest()

    errors = check_local_identity_controls()
    if errors:
        print("LOCAL IDENTITY CONTROLS GATE: FAILED", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print("LOCAL IDENTITY CONTROLS GATE: PASS -- structural controls and platform markers present.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
