#!/usr/bin/env python3
"""Regression controls and structural checks for BoundRecipientKeyResolver (ADR-003, Phase C8.3 / C8.3.1).

Verifies the presence, boundaries, and structural invariants of:
- Android & iOS BoundRecipientKeyResolver implementations
- Guarded 16-byte boundary checks before lookup
- Read-only PeerIdentityLookupSource adapter authority
- Verified-only non-null key resolution with TOFU_PINNED / USER_VERIFIED trust
- Fail-closed behavior on NotFound, Quarantined, Revoked, Corrupt, StorageFailure, InvalidArgument
- No store mutation, raw SQL, or store constructor calls in resolver sources
- Stateless contract (no key caching or memoization)
- Continued fail-closed UnresolvedRecipientKeyResolver in production MeshModule composition
- Comprehensive semantic test inventories on Android and iOS (including split ACK integration tests)
"""
from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

ANDROID_RESOLVER_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "delivery" / "BoundRecipientKeyResolver.kt"
IOS_RESOLVER_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BoundRecipientKeyResolver.swift"
ANDROID_TEST_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "delivery" / "BoundRecipientKeyResolverTest.kt"
IOS_TEST_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "BoundRecipientKeyResolverTests.swift"
ANDROID_MESH_MODULE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "di" / "MeshModule.kt"
IOS_APP_CONTAINER_PATH = ROOT / "ios" / "Godstone" / "Sources" / "App" / "AppContainer.swift"
ADR003_PATH = ROOT / "docs" / "adr" / "ADR-003-identity-and-sealed-sender.md"
FINDINGS_PATH = ROOT / "docs" / "production" / "FINDINGS_STATUS.json"


def strip_comments(text: str) -> str:
    # remove single line comments
    text = re.sub(r'//.*', '', text)
    # remove multi-line comments
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    return text


def check_controls(
    android_resolver_path: Path = ANDROID_RESOLVER_PATH,
    ios_resolver_path: Path = IOS_RESOLVER_PATH,
    android_test_path: Path = ANDROID_TEST_PATH,
    ios_test_path: Path = IOS_TEST_PATH,
    mesh_module_path: Path = ANDROID_MESH_MODULE_PATH,
    app_container_path: Path = IOS_APP_CONTAINER_PATH,
    adr003_path: Path = ADR003_PATH,
    findings_path: Path = FINDINGS_PATH,
) -> list[str]:
    errors: list[str] = []

    # File presence checks
    for p, desc in [
        (android_resolver_path, "Android BoundRecipientKeyResolver"),
        (ios_resolver_path, "iOS BoundRecipientKeyResolver"),
        (android_test_path, "Android BoundRecipientKeyResolverTest"),
        (ios_test_path, "iOS BoundRecipientKeyResolverTests"),
        (mesh_module_path, "Android MeshModule"),
        (app_container_path, "iOS AppContainer"),
        (adr003_path, "ADR-003"),
        (findings_path, "FINDINGS_STATUS.json"),
    ]:
        if not p.exists():
            errors.append(f"Missing required file: {desc} ({p})")

    if errors:
        return errors

    kt_res = android_resolver_path.read_text(encoding="utf-8")
    swift_res = ios_resolver_path.read_text(encoding="utf-8")
    kt_test = android_test_path.read_text(encoding="utf-8")
    swift_test = ios_test_path.read_text(encoding="utf-8")
    mesh_mod = mesh_module_path.read_text(encoding="utf-8")
    app_cont = app_container_path.read_text(encoding="utf-8")
    adr_txt = adr003_path.read_text(encoding="utf-8")
    find_txt = findings_path.read_text(encoding="utf-8")

    kt_code = strip_comments(kt_res)
    swift_code = strip_comments(swift_res)

    # 1. B01: Android BoundRecipientKeyResolver exists and implements RecipientKeyResolver
    if "class BoundRecipientKeyResolver" not in kt_code or "RecipientKeyResolver" not in kt_code:
        errors.append("Android BoundRecipientKeyResolver must implement RecipientKeyResolver (B01)")

    # 2. B02: iOS BoundRecipientKeyResolver exists and conforms to RecipientKeyResolver
    if "class BoundRecipientKeyResolver" not in swift_code or "RecipientKeyResolver" not in swift_code:
        errors.append("iOS BoundRecipientKeyResolver must conform to RecipientKeyResolver (B02)")

    # 3. B03: Both platforms guard node id == 16 before lookup
    if not re.search(r'nodeId\.size\s*!=\s*16', kt_code) and not re.search(r'nodeId\.size\s*==\s*16', kt_code):
        errors.append("Android BoundRecipientKeyResolver missing 16-byte nodeId boundary guard (B03)")
    if not re.search(r'nodeId\.count\s*==\s*16', swift_code) and not re.search(r'nodeId\.count\s*!=\s*16', swift_code):
        errors.append("iOS BoundRecipientKeyResolver missing 16-byte nodeId boundary guard (B03)")

    # 4. B04: Both platforms obtain authority through PeerIdentityLookupSource / lookup
    if "source.lookup(nodeId)" not in kt_code or "PeerIdentityLookupSource" not in kt_code:
        errors.append("Android BoundRecipientKeyResolver must query PeerIdentityLookupSource.lookup (B04)")
    if "source.lookup(nodeId)" not in swift_code or "PeerIdentityLookupSource" not in swift_code:
        errors.append("iOS BoundRecipientKeyResolver must query PeerIdentityLookupSource.lookup (B04)")

    # 5. B05: ONLY Verified lookup can produce a non-null key
    if "is PeerIdentityLookup.Verified ->" not in kt_code or "case .verified" not in swift_code:
        errors.append("Both platforms must restrict non-null key returns to Verified lookup (B05)")
    if "is PeerIdentityLookup.Quarantined ->" in kt_code:
        errors.append("Android BoundRecipientKeyResolver Quarantined branch must not return a key (B05)")

    # 6. B06: Returned authority is signingPublicKey, never accepted/pending static DH key
    if "signingPublicKey" not in kt_code or "signingPublicKey" not in swift_code:
        errors.append("Both platforms must return signingPublicKey (B06)")
    if "acceptedStaticDhPublicKey" in kt_code or "pendingStaticDhPublicKey" in kt_code:
        errors.append("Android BoundRecipientKeyResolver must not reference static DH keys (B06)")
    if "acceptedStaticDhPublicKey" in swift_code or "pendingStaticDhPublicKey" in swift_code:
        errors.append("iOS BoundRecipientKeyResolver must not reference static DH keys (B06)")

    # 7. B07: TOFU_PINNED and USER_VERIFIED are the only accepted trust levels
    if "TOFU_PINNED" not in kt_code or "USER_VERIFIED" not in kt_code or "REVOKED -> null" not in kt_code:
        errors.append("Android BoundRecipientKeyResolver must accept only TOFU_PINNED/USER_VERIFIED and reject REVOKED (B07)")
    if "tofuPinned" not in swift_code or "userVerified" not in swift_code or "revoked:" not in swift_code:
        errors.append("iOS BoundRecipientKeyResolver must accept only tofuPinned/userVerified and reject revoked (B07)")

    # 8. B08: NotFound / Quarantined / Revoked / Corrupt / StorageFailure / InvalidArgument fail closed
    kt_required_fail_closed = ["NotFound", "Quarantined", "Revoked", "Corrupt", "StorageFailure", "InvalidArgument"]
    for branch in kt_required_fail_closed:
        if branch not in kt_code:
            errors.append(f"Android BoundRecipientKeyResolver missing fail-closed branch: {branch} (B08)")

    swift_required_fail_closed = ["notFound", "quarantined", "revoked", "corrupt", "storageFailure", "invalidArgument"]
    for branch in swift_required_fail_closed:
        if branch not in swift_code:
            errors.append(f"iOS BoundRecipientKeyResolver missing fail-closed branch: {branch} (B08)")

    # 9. B09: Resolver source contains no mutation authority calls
    for forbidden in ["applyValidatedBinding", "approvePendingRotation", "revokePeer"]:
        if forbidden in kt_code:
            errors.append(f"Android BoundRecipientKeyResolver contains forbidden mutation call: {forbidden} (B09)")
        if forbidden in swift_code:
            errors.append(f"iOS BoundRecipientKeyResolver contains forbidden mutation call: {forbidden} (B09)")

    # 10. B10: Resolver source contains no raw SQL or store write token
    for forbidden_sql in ["execRawSql", "INSERT INTO", "UPDATE ", "DELETE FROM", "CREATE TABLE", "writeRaw"]:
        if forbidden_sql in kt_code or forbidden_sql in swift_code:
            errors.append(f"Resolver source contains forbidden SQL / store write token: {forbidden_sql} (B10)")

    # 11. B11: Resolver contains no cache / map / dictionary / memoized key state
    for cache_kw in ["Map<", "HashMap", "ConcurrentHashMap", "Dictionary<", "NSCache", "cachedKey", "lastKey", "var cache"]:
        if cache_kw in kt_code or cache_kw in swift_code:
            errors.append(f"Resolver source contains forbidden caching/memoization token: {cache_kw} (B11)")

    # 12. B12: Resolver does not construct SqlcipherPeerIdentityStore or SqlitePeerIdentityStore
    for store_ctor in ["SqlcipherPeerIdentityStore(", "SqlitePeerIdentityStore("]:
        if store_ctor in kt_code or store_ctor in swift_code:
            errors.append(f"Resolver source contains forbidden store construction: {store_ctor} (B12)")

    # 13. B13: Android MeshModule still wires UnresolvedRecipientKeyResolver in C8.3
    if "UnresolvedRecipientKeyResolver" not in mesh_mod:
        errors.append("Android MeshModule must continue to wire UnresolvedRecipientKeyResolver in C8.3 (B13)")
    if "BoundRecipientKeyResolver" in mesh_mod:
        errors.append("Android MeshModule must NOT wire BoundRecipientKeyResolver in C8.3 (B13)")

    # 14. B14: Link flags remain false and iOS AppContainer remains Archive-only
    if "LINK_LAYER_READY = false" not in adr_txt or "linkLayerReady = false" not in adr_txt:
        errors.append("ADR-003 link layer ready flags must remain false (B14)")
    if "MeshNode" in app_cont or "DeliveryTracker" in app_cont or "BoundRecipientKeyResolver" in app_cont:
        errors.append("iOS AppContainer must remain Archive-only (B14)")

    # 15. B15: Canonical Android resolver test inventory (including distinct ACK integration methods)
    canonical_tests = [
        "testBoundResolver_ActiveTofu_ReturnsSigningKey",
        "testBoundResolver_UserVerified_ReturnsSigningKey",
        "testBoundResolver_Unseen_ReturnsNull",
        "testBoundResolver_Quarantined_ReturnsNull",
        "testBoundResolver_OldAcceptedReplayWhilePending_ReturnsNull",
        "testBoundResolver_ApprovalRestoresResolution",
        "testBoundResolver_Revoked_ReturnsNull",
        "testBoundResolver_InvalidNodeLength_NoLookup",
        "testBoundResolver_Corrupt_ReturnsNull",
        "testBoundResolver_StorageFailure_ReturnsNull",
        "testBoundResolver_NoCacheAcrossLifecycle",
        "testBoundResolver_DefensiveCopy",
        "testBoundResolver_ConcurrentRevoke_NoStalePostCommitKey",
        "testBoundResolver_ReadOnlyAdapter_SingleLookupCall",
        "testBoundResolver_AckIntegration_ActiveValidAckSucceeds",
        "testBoundResolver_AckIntegration_TamperedSignatureFailsWithActivePeer",
        "testBoundResolver_AckIntegration_UnseenRecipientFailsAtResolver",
        "testBoundResolver_AckIntegration_CorruptLookupFailsClosed",
        "testBoundResolver_AckIntegration_StorageFailureFailsClosed",
        "testBoundResolver_AckIntegration_LifecycleQuarantineApprovalRevocation",
    ]
    for t in canonical_tests:
        if t not in kt_test:
            errors.append(f"Android test suite missing canonical test: {t} (B15)")

    # 16. B16: Canonical iOS resolver test inventory (including distinct ACK integration methods)
    for t in canonical_tests:
        if t not in swift_test:
            errors.append(f"iOS test suite missing canonical test: {t} (B16)")

    return errors


def selftest() -> int:
    print("Running check_bound_recipient_key_resolver_controls --selftest...")
    failures: list[str] = []
    passed = 0

    with tempfile.TemporaryDirectory() as tmpdir:
        td = Path(tmpdir)
        f_kt_res = td / "BoundRecipientKeyResolver.kt"
        f_swift_res = td / "BoundRecipientKeyResolver.swift"
        f_kt_test = td / "BoundRecipientKeyResolverTest.kt"
        f_swift_test = td / "BoundRecipientKeyResolverTests.swift"
        f_mesh_mod = td / "MeshModule.kt"
        f_app_cont = td / "AppContainer.swift"
        f_adr = td / "ADR-003.md"
        f_find = td / "FINDINGS_STATUS.json"

        def reset_all():
            f_kt_res.write_text(ANDROID_RESOLVER_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_res.write_text(IOS_RESOLVER_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_test.write_text(ANDROID_TEST_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_test.write_text(IOS_TEST_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_mesh_mod.write_text(ANDROID_MESH_MODULE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_app_cont.write_text(IOS_APP_CONTAINER_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_adr.write_text(ADR003_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_find.write_text(FINDINGS_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        def run_check() -> list[str]:
            return check_controls(
                android_resolver_path=f_kt_res,
                ios_resolver_path=f_swift_res,
                android_test_path=f_kt_test,
                ios_test_path=f_swift_test,
                mesh_module_path=f_mesh_mod,
                app_container_path=f_app_cont,
                adr003_path=f_adr,
                findings_path=f_find,
            )

        # Baseline check
        reset_all()
        baseline_errs = run_check()
        if baseline_errs:
            print(f"::error::check_bound_recipient_key_resolver_controls baseline failed: {baseline_errs}")
            return 1

        # Mutation B01: Android class renamed / interface removed
        f_kt_res.write_text(f_kt_res.read_text(encoding="utf-8").replace("class BoundRecipientKeyResolver", "class FakeResolver"), encoding="utf-8")
        if any("B01" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B01 was NOT caught")
        reset_all()

        # Mutation B02: iOS protocol conformance removed
        f_swift_res.write_text(f_swift_res.read_text(encoding="utf-8").replace("RecipientKeyResolver", "AnyObject"), encoding="utf-8")
        if any("B02" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B02 was NOT caught")
        reset_all()

        # Mutation B03: Android 16-byte guard removed
        f_kt_res.write_text(f_kt_res.read_text(encoding="utf-8").replace("if (nodeId.size != 16) {\n            return null\n        }", ""), encoding="utf-8")
        if any("B03" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B03 was NOT caught")
        reset_all()

        # Mutation B04: Lookup source query bypassed
        f_kt_res.write_text(f_kt_res.read_text(encoding="utf-8").replace("source.lookup(nodeId)", "PeerIdentityLookup.NotFound"), encoding="utf-8")
        if any("B04" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B04 was NOT caught")
        reset_all()

        # Mutation B05: Quarantined returns non-null key
        f_kt_res.write_text(f_kt_res.read_text(encoding="utf-8").replace("is PeerIdentityLookup.Quarantined,", "is PeerIdentityLookup.Quarantined -> ByteArray(32)\n"), encoding="utf-8")
        if any("B05" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B05 was NOT caught")
        reset_all()

        # Mutation B06: Return static DH key instead of signing key
        f_kt_res.write_text(f_kt_res.read_text(encoding="utf-8").replace("lookup.identity.signingPublicKey.clone()", "lookup.identity.acceptedStaticDhPublicKey.clone()"), encoding="utf-8")
        if any("B06" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B06 was NOT caught")
        reset_all()

        # Mutation B07: Accept REVOKED trust level
        f_kt_res.write_text(f_kt_res.read_text(encoding="utf-8").replace("PeerTrustLevel.REVOKED -> null", "PeerTrustLevel.REVOKED -> lookup.identity.signingPublicKey.clone()"), encoding="utf-8")
        if any("B07" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B07 was NOT caught")
        reset_all()

        # Mutation B08: StorageFailure branch removed
        f_kt_res.write_text(f_kt_res.read_text(encoding="utf-8").replace("is PeerIdentityLookup.StorageFailure,", ""), encoding="utf-8")
        if any("B08" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B08 was NOT caught")
        reset_all()

        # Mutation B09: Forbidden approvePendingRotation call injected
        f_kt_res.write_text(f_kt_res.read_text(encoding="utf-8") + "\nfun mutate(repo: PeerIdentityRepository) { repo.approvePendingRotation(ByteArray(16), 1L, ByteArray(32)) }\n", encoding="utf-8")
        if any("B09" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B09 was NOT caught")
        reset_all()

        # Mutation B10: Forbidden raw SQL token injected
        f_kt_res.write_text(f_kt_res.read_text(encoding="utf-8") + "\nfun rawSql() { val sql = \"UPDATE peer_identities SET trust_level = 2\" }\n", encoding="utf-8")
        if any("B10" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B10 was NOT caught")
        reset_all()

        # Mutation B11: Cache dictionary injected
        f_swift_res.write_text(f_swift_res.read_text(encoding="utf-8") + "\nprivate var cachedKey: Data?\n", encoding="utf-8")
        if any("B11" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B11 was NOT caught")
        reset_all()

        # Mutation B12: Forbidden store construction injected
        f_kt_res.write_text(f_kt_res.read_text(encoding="utf-8") + "\nfun createStore(ctx: android.content.Context) { SqlcipherPeerIdentityStore(ctx) }\n", encoding="utf-8")
        if any("B12" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B12 was NOT caught")
        reset_all()

        # Mutation B13: MeshModule wires BoundRecipientKeyResolver prematurely
        f_mesh_mod.write_text(f_mesh_mod.read_text(encoding="utf-8").replace("UnresolvedRecipientKeyResolver", "BoundRecipientKeyResolver"), encoding="utf-8")
        if any("B13" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B13 was NOT caught")
        reset_all()

        # Mutation B14: Link layer ready flipped to true in ADR-003
        f_adr.write_text(f_adr.read_text(encoding="utf-8").replace("LINK_LAYER_READY = false", "LINK_LAYER_READY = true"), encoding="utf-8")
        if any("B14" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B14 was NOT caught")
        reset_all()

        # Mutation B15: Android canonical test removed (UnseenRecipientFailsAtResolver)
        f_kt_test.write_text(f_kt_test.read_text(encoding="utf-8").replace("testBoundResolver_AckIntegration_UnseenRecipientFailsAtResolver", "testOldUnseenAckIntegration"), encoding="utf-8")
        if any("B15" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B15 was NOT caught")
        reset_all()

        # Mutation B16: iOS canonical test removed (TamperedSignatureFailsWithActivePeer)
        f_swift_test.write_text(f_swift_test.read_text(encoding="utf-8").replace("testBoundResolver_AckIntegration_TamperedSignatureFailsWithActivePeer", "testOldTamperedAckIntegration"), encoding="utf-8")
        if any("B16" in e for e in run_check()): passed += 1
        else: failures.append("Mutation B16 was NOT caught")
        reset_all()

    if failures:
        for f in failures:
            print(f"::error::selftest failure: {f}")
        return 1

    print(f"check_bound_recipient_key_resolver_controls selftest PASSED ({passed}/16 mutations caught deterministically).")
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
            print(f"::error::Bound recipient key resolver control error: {e}", file=sys.stderr)
        print(f"\nFAIL: {len(errors)} bound recipient key resolver control issue(s) found.", file=sys.stderr)
        return 1

    print("BOUND RECIPIENT KEY RESOLVER CONTROLS GATE: PASS -- read-only authority, fail-closed matrix, and boundaries satisfied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
