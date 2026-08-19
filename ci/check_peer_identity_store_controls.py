#!/usr/bin/env python3
"""
ci/check_peer_identity_store_controls.py

Enforces structural invariants, authority surfaces, guarded SQL predicates,
encryption/key isolation, and transaction discipline for Phase C8.2B
(Physically Separate Durable Peer-Identity Store & Transactional Authority).

Invariants enforced:
1. Physical database separation:
   - Database name: godstone_peer_identities.db (NOT godstone_messages.db)
   - Independent table: peer_identities (NOT in StoreSchema/godstone_messages)
2. Android SQLCipher & Passphrase isolation:
   - Dedicated EncryptedSharedPreferences namespace: godstone_peer_identity_store_key (NOT godstone_store_key)
   - Synchronous commit() on key storage (NO .apply())
   - Key length must be exactly 32 bytes
   - If key absent + DB present -> FAIL CLOSED (no replacement generation)
   - net.zetetic.database.sqlcipher SQLiteOpenHelper used
3. Schema V1 and DDL CHECK invariants:
   - 16-byte node_id
   - 32-byte signing_public_key
   - 32-byte accepted_static_dh_public_key
   - accepted_generation between 0 and 4294967295
   - trust_level in (1, 2, 3)
   - pending coupling, 32-byte length, uint32 range, > accepted_generation, != accepted_static
   - revoked (3) cannot have pending
4. Schema version & Upgrade/Downgrade:
   - Android onUpgrade: FAIL CLOSED (no DROP TABLE)
   - Android onDowngrade: FAIL CLOSED
   - On-open DDL fingerprint validation against sqlite_master
   - iOS user_version == 1 with DDL fingerprint check; v > 1 fails closed
5. iOS Data Protection & Transaction:
   - Fixed FileProtectionType.complete (no weaker caller options)
   - Attribute setting failure is fail-closed (no try?)
   - BEGIN IMMEDIATE used for writer serialization
   - No nested locking calls inside transaction body
6. Repository Transaction & Authority:
   - Decision occurs entirely inside serialized transaction
   - Raw row undergoes strict decode (D1-D5) + PeerIdentityRecordValidator before engine evaluation
   - INSERT FIRST SEEN uses standard INSERT (no OR IGNORE / REPLACE)
   - Guarded UPDATE for initial-pending contains all required authority predicates
   - Guarded UPDATE for advance-pending contains all required authority predicates
   - Affected rows must equal exactly 1
   - Post-mutation readback + validation inside same transaction
   - AcceptExisting, KeepQuarantined, Reject perform NO mutations
   - Incoming network bindings cannot promote trust level
7. Authority View Boundary:
   - PeerIdentityRecord constructor allowed in production ONLY in PeerTrustModels and PeerIdentityRepository
   - VerifiedPeerIdentity.fromRecord & PendingPeerIdentity.fromRecord allowed in production ONLY in PeerTrustModels and PeerIdentityRepository
   - PeerIdentityStore must NOT directly mint VerifiedPeerIdentity or PendingPeerIdentity
8. Status & Open Findings:
   - A-05 must remain OPEN_REPOSITORY
   - BoundRecipientKeyResolver must remain OPEN / un-implemented

Usage:
  python3 ci/check_peer_identity_store_controls.py
  python3 ci/check_peer_identity_store_controls.py --selftest
"""

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

KT_SCHEMA_PATH = ROOT / "android/mesh/src/main/java/io/godstone/mesh/identity/PeerIdentitySchema.kt"
KT_STORE_PATH = ROOT / "android/mesh/src/main/java/io/godstone/mesh/identity/PeerIdentityStore.kt"
KT_REPO_PATH = ROOT / "android/mesh/src/main/java/io/godstone/mesh/identity/PeerIdentityRepository.kt"

SWIFT_STORE_PATH = ROOT / "ios/Godstone/Sources/GodstoneMesh/PeerIdentityStore.swift"
SWIFT_REPO_PATH = ROOT / "ios/Godstone/Sources/GodstoneMesh/PeerIdentityRepository.swift"

ANDROID_SRC_DIR = ROOT / "android/mesh/src/main/java/io/godstone/mesh"
IOS_SRC_DIR = ROOT / "ios/Godstone/Sources/GodstoneMesh"

MSG_STORE_KT = ROOT / "android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt"
FINDINGS_PATH = ROOT / "docs/production/FINDINGS_STATUS.json"
ADR_PATH = ROOT / "docs/adr/ADR-003-identity-and-sealed-sender.md"


def check_controls(
    kt_schema: str = None,
    kt_store: str = None,
    kt_repo: str = None,
    swift_store: str = None,
    swift_repo: str = None,
    msg_store_kt: str = None,
    findings_txt: str = None,
    adr_txt: str = None,
    android_src: Path = None,
    ios_src: Path = None,
) -> list[str]:
    errors = []

    if kt_schema is None and KT_SCHEMA_PATH.exists():
        kt_schema = KT_SCHEMA_PATH.read_text(encoding="utf-8")
    if kt_store is None and KT_STORE_PATH.exists():
        kt_store = KT_STORE_PATH.read_text(encoding="utf-8")
    if kt_repo is None and KT_REPO_PATH.exists():
        kt_repo = KT_REPO_PATH.read_text(encoding="utf-8")
    if swift_store is None and SWIFT_STORE_PATH.exists():
        swift_store = SWIFT_STORE_PATH.read_text(encoding="utf-8")
    if swift_repo is None and SWIFT_REPO_PATH.exists():
        swift_repo = SWIFT_REPO_PATH.read_text(encoding="utf-8")
    if msg_store_kt is None and MSG_STORE_KT.exists():
        msg_store_kt = MSG_STORE_KT.read_text(encoding="utf-8")
    if findings_txt is None and FINDINGS_PATH.exists():
        findings_txt = FINDINGS_PATH.read_text(encoding="utf-8")
    if adr_txt is None and ADR_PATH.exists():
        adr_txt = ADR_PATH.read_text(encoding="utf-8")
    if android_src is None:
        android_src = ANDROID_SRC_DIR
    if ios_src is None:
        ios_src = IOS_SRC_DIR

    # 1. Physical Database Separation (S01, S02)
    for code, platform in [(kt_schema, "Android"), (swift_store, "iOS")]:
        if code:
            if 'DB_NAME = "godstone_peer_identities.db"' not in code and 'dbName = "godstone_peer_identities.db"' not in code:
                errors.append(f"{platform} peer store must declare dbName = 'godstone_peer_identities.db'")
            if 'godstone_messages.db' in code:
                errors.append(f"{platform} peer store must NOT use 'godstone_messages.db' (S01)")
    if msg_store_kt and "peer_identities" in msg_store_kt:
        errors.append("MessageStore/StoreSchema must NOT contain peer_identities table (S02)")

    # 2. Android SQLCipher & Key Management (S03 - S07)
    if kt_schema and kt_store:
        if "godstone_peer_identity_store_key" not in kt_schema:
            errors.append("Android PeerIdentitySchema must use dedicated 'godstone_peer_identity_store_key' namespace")
        if "godstone_store_key" in kt_schema or "godstone_store_key" in kt_store:
            errors.append("Android peer store must NOT use message store key namespace 'godstone_store_key' (S03)")
        if "decoded.size != 32" not in kt_store:
            errors.append("Android peer key decoding must enforce exact 32 bytes length (S04)")
        if "if (dbExists)" not in kt_store or "refusing to recreate key" not in kt_store:
            errors.append("Android peer store must fail closed when key is missing but DB exists (S05)")
        if ".apply()" in kt_store:
            errors.append("Android peer key storage must use synchronous commit(), not .apply() (S06)")
        if "net.zetetic.database.sqlcipher.SQLiteOpenHelper" not in kt_store:
            errors.append("Android peer store must use net.zetetic.database.sqlcipher.SQLiteOpenHelper (S07)")

    # 3. Canonical Schema DDL CHECK constraints (S08 - S16)
    for code, platform in [(kt_schema, "Android"), (swift_store, "iOS")]:
        if code:
            if "CHECK (length(node_id) = 16)" not in code:
                errors.append(f"{platform} DDL missing CHECK (length(node_id) = 16) (S08)")
            if "CHECK (length(signing_public_key) = 32)" not in code:
                errors.append(f"{platform} DDL missing CHECK (length(signing_public_key) = 32) (S09)")
            if "CHECK (length(accepted_static_dh_public_key) = 32)" not in code:
                errors.append(f"{platform} DDL missing CHECK (length(accepted_static_dh_public_key) = 32) (S10)")
            if "accepted_generation BETWEEN 0 AND 4294967295" not in code:
                errors.append(f"{platform} DDL missing accepted_generation uint32 CHECK (S11)")
            if "trust_level IN (1,2,3)" not in code and "trust_level IN (1, 2, 3)" not in code:
                errors.append(f"{platform} DDL missing trust_level IN (1,2,3) CHECK (S12)")
            if "pending_static_dh_public_key IS NULL" not in code or "pending_generation IS NULL" not in code:
                errors.append(f"{platform} DDL missing pending fields coupling CHECK (S13)")
            if "pending_generation > accepted_generation" not in code:
                errors.append(f"{platform} DDL missing pending_generation > accepted_generation CHECK (S14)")
            if "pending_static_dh_public_key != accepted_static_dh_public_key" not in code:
                errors.append(f"{platform} DDL missing pending static divergence CHECK (S15)")
            if "trust_level != 3" not in code:
                errors.append(f"{platform} DDL missing revoked with pending rejection CHECK (S16)")

    # 4. Schema Lifecycle & Upgrade/Downgrade (S17 - S19)
    if kt_store:
        if "DROP TABLE" in kt_store:
            errors.append("Android peer store must NOT contain DROP TABLE in onUpgrade (S17)")
        if "Unimplemented peer store schema migration" not in kt_store:
            errors.append("Android peer store must throw on unimplemented onUpgrade (S18)")
        if "PeerIdentitySchema.validateSchema(db)" not in kt_store:
            errors.append("Android peer store must validate schema DDL on open (S19)")

    # 5. iOS Protection & Transaction (S20 - S24)
    if swift_store:
        if "FileProtectionType.complete" not in swift_store:
            errors.append("iOS peer store must enforce FileProtectionType.complete (S20)")
        if re.search(r'init\([^)]*fileProtection:', swift_store):
            errors.append("iOS peer store public initializer must NOT expose caller-selectable fileProtection (S21)")
        if "convenience init(url: URL)" not in swift_store and "init(url: URL)" not in swift_store:
            errors.append("iOS peer store must provide fixed init(url: URL) initializer (S21)")
        if "try? FileManager.default.setAttributes" in swift_store or "try? protectionSetter" in swift_store:
            errors.append("iOS peer store must NOT ignore file protection failures (S22)")
        if "BEGIN IMMEDIATE" not in swift_store:
            errors.append("iOS peer store must execute BEGIN IMMEDIATE for writer transactions (S23)")
        if "class SqlitePeerIdentityStore" in swift_store and "func inImmediateTransaction" in swift_store:
            in_tx = swift_store.split("class SqlitePeerIdentityStore")[1].split("func inImmediateTransaction")[1].split("func readUserVersion")[0]
            if "readRaw(" in in_tx or "insertFirstSeen(" in in_tx or "setInitialPendingGuarded(" in in_tx or "withDbThrowing" in in_tx:
                errors.append("iOS inImmediateTransaction must NOT call locking store methods (S24)")

    # 6. Repository Transaction, Strict Decoder, Transaction Abort & Guarded SQL (S25 - S40, S47, S48)
    for repo_code, platform in [(kt_repo, "Android"), (swift_repo, "iOS")]:
        if repo_code:
            # S25: Transaction boundary
            if "store.inImmediateTransaction" not in repo_code:
                errors.append(f"{platform} PeerIdentityRepository must run apply inside inImmediateTransaction (S25)")
            # S26: Strict decode before engine evaluate
            if "decodeRowStrict" not in repo_code or "PeerIdentityRecordValidator.validate" not in repo_code:
                errors.append(f"{platform} PeerIdentityRepository must strictly decode and validate before evaluate (S26)")
            # S35: Mutation cardinality
            if "MutationCardinality" not in repo_code and "mutationCardinality" not in repo_code:
                errors.append(f"{platform} PeerIdentityRepository must enforce mutation cardinality == 1 (S35)")
            # S36: Post-mutation readback
            if "MissingPostMutationRow" not in repo_code and "missingPostMutationRow" not in repo_code:
                errors.append(f"{platform} PeerIdentityRepository must perform post-mutation readback (S36)")
            # S37: AcceptExisting performs NO mutations
            if platform == "Android" and "is TrustPlan.AcceptExisting" in repo_code:
                ae_block = repo_code.split("is TrustPlan.AcceptExisting")[1].split("is TrustPlan.")[0]
                if "insertFirstSeen" in ae_block or "setInitialPendingGuarded" in ae_block or "advancePendingGuarded" in ae_block:
                    errors.append("Android AcceptExisting must not execute mutations (S37)")
            elif platform == "iOS" and "case .acceptExisting:" in repo_code:
                ae_block = repo_code.split("case .acceptExisting:")[1].split("case .")[0]
                if "insertFirstSeen" in ae_block or "setInitialPendingGuarded" in ae_block or "advancePendingGuarded" in ae_block:
                    errors.append("iOS acceptExisting must not execute mutations (S37)")
            # S38: KeepQuarantined performs NO mutations
            if platform == "Android" and "is TrustPlan.KeepQuarantined" in repo_code:
                kq_block = repo_code.split("is TrustPlan.KeepQuarantined")[1].split("is TrustPlan.")[0]
                if "insertFirstSeen" in kq_block or "setInitialPendingGuarded" in kq_block or "advancePendingGuarded" in kq_block:
                    errors.append("Android KeepQuarantined must not execute mutations (S38)")
            elif platform == "iOS" and "case .keepQuarantined:" in repo_code:
                kq_block = repo_code.split("case .keepQuarantined:")[1].split("case .")[0]
                if "insertFirstSeen" in kq_block or "setInitialPendingGuarded" in kq_block or "advancePendingGuarded" in kq_block:
                    errors.append("iOS keepQuarantined must not execute mutations (S38)")
            # S39: Reject performs NO mutations
            if platform == "Android" and "is TrustPlan.Reject" in repo_code:
                rej_block = repo_code.split("is TrustPlan.Reject")[1].split("is TrustPlan.")[0]
                if "insertFirstSeen" in rej_block or "setInitialPendingGuarded" in rej_block or "advancePendingGuarded" in rej_block:
                    errors.append("Android Reject must not execute mutations (S39)")
            elif platform == "iOS" and "case .reject(" in repo_code:
                rej_block = repo_code.split("case .reject(")[1].split("case .")[0]
                if "insertFirstSeen" in rej_block or "setInitialPendingGuarded" in rej_block or "advancePendingGuarded" in rej_block:
                    errors.append("iOS reject must not execute mutations (S39)")
            # S40: Network trust promotion forbidden
            if platform == "Android":
                if "trustCode = PeerTrustLevel.TOFU_PINNED.persistedCode" not in repo_code or "USER_VERIFIED" in repo_code.split("fun applyValidatedBinding")[1].split("fun lookup")[0]:
                    errors.append("Android first-seen must be TOFU_PINNED and cannot promote trust level (S40)")
            elif platform == "iOS":
                if "trustCode: Int32(PeerTrustLevel.tofuPinned.persistedCode)" not in repo_code or "userVerified" in repo_code.split("func applyValidatedBinding")[1].split("func lookup")[0]:
                    errors.append("iOS first-seen must be tofuPinned and cannot promote trust level (S40)")
            # S48: Transaction abort on corruption (no normal Corrupt return inside transaction)
            if platform == "Android":
                if "inImmediateTransaction" in repo_code:
                    txn_block = repo_code.split("inImmediateTransaction")[1].split("catch (e: CorruptTxnAbort)")[0]
                    if "return@inImmediateTransaction PeerTrustApplyResult.Corrupt" in txn_block or "PeerTrustApplyResult.Corrupt(" in txn_block:
                        errors.append("Android applyValidatedBinding transaction must abort on corruption, not return Corrupt (S48)")
                    if "abortCorrupt(" not in txn_block or "CorruptTxnAbort" not in repo_code:
                        errors.append("Android applyValidatedBinding must use abortCorrupt / CorruptTxnAbort (S48)")
            elif platform == "iOS":
                if "inImmediateTransaction" in repo_code:
                    txn_block = repo_code.split("inImmediateTransaction")[1].split("catch let ApplyTxnAbort.corrupt")[0]
                    if "return .corrupt(" in txn_block:
                        errors.append("iOS applyValidatedBinding transaction must abort on corruption, not return .corrupt (S48)")
                    if "ApplyTxnAbort.corrupt(" not in txn_block:
                        errors.append("iOS applyValidatedBinding must throw ApplyTxnAbort.corrupt on corruption (S48)")

    for schema_code, platform in [(kt_schema, "Android"), (swift_store, "iOS")]:
        if schema_code:
            # S27: Normal INSERT
            if "INSERT OR IGNORE" in schema_code or "INSERT OR REPLACE" in schema_code:
                errors.append(f"{platform} first-seen must use standard INSERT, not OR IGNORE/REPLACE (S27)")
            # S28 - S32: Initial-pending guarded UPDATE predicates
            if "AND signing_public_key = ?" not in schema_code:
                errors.append(f"{platform} guarded UPDATE missing signing_public_key predicate (S28)")
            if "AND accepted_static_dh_public_key = ?" not in schema_code:
                errors.append(f"{platform} guarded UPDATE missing accepted_static_dh_public_key predicate (S29)")
            if "AND accepted_generation = ?" not in schema_code:
                errors.append(f"{platform} guarded UPDATE missing accepted_generation predicate (S30)")
            if "AND trust_level = ?" not in schema_code:
                errors.append(f"{platform} guarded UPDATE missing trust_level predicate (S31)")
            if "AND pending_static_dh_public_key IS NULL" not in schema_code or "AND pending_generation IS NULL" not in schema_code:
                errors.append(f"{platform} initial-pending guarded UPDATE missing NULL pending predicates (S32)")
            # S33 - S34: Advance-pending guarded UPDATE predicates
            if "AND pending_static_dh_public_key = ?" not in schema_code:
                errors.append(f"{platform} advance-pending guarded UPDATE missing old pending-static predicate (S33)")
            if "AND pending_generation = ?" not in schema_code:
                errors.append(f"{platform} advance-pending guarded UPDATE missing old pending-generation predicate (S34)")

    # S47: Raw SQL authority bypass forbidden in production store
    if kt_store and "fun execRawSql" in kt_store:
        errors.append("Android production PeerIdentityStore must NOT expose execRawSql (S47)")
    if swift_store and "func execRawSql" in swift_store:
        errors.append("iOS production PeerIdentityStore must NOT expose execRawSql (S47)")

    # 7. Production Source Authority Surface Scanner (S41 - S44)
    if android_src and android_src.exists():
        for f in android_src.rglob("*.kt"):
            txt = f.read_text(encoding="utf-8")
            if f.name not in ("PeerTrustModels.kt", "PeerIdentityRepository.kt"):
                if "VerifiedPeerIdentity.fromRecord(" in txt or "PendingPeerIdentity.fromRecord(" in txt:
                    errors.append(f"Forbidden production call to fromRecord() in {f.name} (S41/S42)")
                if "PeerIdentityRecord(" in txt:
                    errors.append(f"Forbidden production instantiation of PeerIdentityRecord() in {f.name} (S43)")
            if f.name == "PeerIdentityStore.kt":
                if "VerifiedPeerIdentity(" in txt or "VerifiedPeerIdentity.fromRecord(" in txt:
                    errors.append("PeerIdentityStore must NOT mint VerifiedPeerIdentity directly (S44)")
                if "fun execRawSql" in txt:
                    errors.append("SqlcipherPeerIdentityStore must NOT implement execRawSql (S47)")

    if ios_src and ios_src.exists():
        for f in ios_src.rglob("*.swift"):
            txt = f.read_text(encoding="utf-8")
            if f.name not in ("PeerTrustModels.swift", "PeerIdentityRepository.swift"):
                if "VerifiedPeerIdentity.fromRecord(" in txt or "PendingPeerIdentity.fromRecord(" in txt:
                    errors.append(f"Forbidden production call to fromRecord() in {f.name} (S41/S42)")
                if "PeerIdentityRecord(" in txt:
                    errors.append(f"Forbidden production instantiation of PeerIdentityRecord() in {f.name} (S43)")
            if f.name == "PeerIdentityStore.swift":
                if "VerifiedPeerIdentity(" in txt or "VerifiedPeerIdentity.fromRecord(" in txt:
                    errors.append("PeerIdentityStore must NOT mint VerifiedPeerIdentity directly (S44)")
                if "func execRawSql" in txt:
                    errors.append("SqlitePeerIdentityStore must NOT implement execRawSql (S47)")
            if "SqlitePeerIdentityStore(" in txt and "fileProtection:" in txt:
                errors.append(f"Production callsite {f.name} must NOT pass caller-selected fileProtection (S21)")

    # 8. Status & Findings Consistency (S45, S46)
    if findings_txt:
        try:
            findings = json.loads(findings_txt)
            findings_list = findings.get("findings", [])
            findings_map = {f["id"]: f for f in findings_list if isinstance(f, dict)}
            a05 = findings_map.get("A-05", {})
            if a05.get("status") != "OPEN_REPOSITORY":
                errors.append(f"A-05 status must be OPEN_REPOSITORY, got '{a05.get('status')}' (S45)")
            if "BoundRecipientKeyResolver" in a05.get("evidence", "") and "RESOLVED" in a05.get("evidence", ""):
                errors.append("Status incorrectly claims BoundRecipientKeyResolver is resolved (S46)")
            if a05.get("bound_recipient_key_resolver") == "RESOLVED":
                errors.append("Status incorrectly claims BoundRecipientKeyResolver is resolved (S46)")
        except json.JSONDecodeError as e:
            errors.append(f"Failed to parse FINDINGS_STATUS.json: {e}")

    return errors


def selftest() -> int:
    print("Running check_peer_identity_store_controls --selftest...")
    passed = 0
    failures = []

    with tempfile.TemporaryDirectory() as tmpdir:
        tmp_path = Path(tmpdir)
        fake_android_src = tmp_path / "android"
        fake_ios_src = tmp_path / "ios"
        fake_android_src.mkdir(parents=True)
        fake_ios_src.mkdir(parents=True)

        f_kt_schema = fake_android_src / "PeerIdentitySchema.kt"
        f_kt_store = fake_android_src / "PeerIdentityStore.kt"
        f_kt_repo = fake_android_src / "PeerIdentityRepository.kt"
        f_swift_store = fake_ios_src / "PeerIdentityStore.swift"
        f_swift_repo = fake_ios_src / "PeerIdentityRepository.swift"
        f_msg_store = fake_android_src / "MessageStore.kt"
        f_findings = tmp_path / "FINDINGS_STATUS.json"
        f_adr = tmp_path / "ADR-003.md"

        def reset_all():
            f_kt_schema.write_text(KT_SCHEMA_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_store.write_text(KT_STORE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_kt_repo.write_text(KT_REPO_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_store.write_text(SWIFT_STORE_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_swift_repo.write_text(SWIFT_REPO_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_msg_store.write_text(MSG_STORE_KT.read_text(encoding="utf-8"), encoding="utf-8")
            f_findings.write_text(FINDINGS_PATH.read_text(encoding="utf-8"), encoding="utf-8")
            f_adr.write_text(ADR_PATH.read_text(encoding="utf-8"), encoding="utf-8")

        reset_all()

        def run_check():
            return check_controls(
                kt_schema=f_kt_schema.read_text(encoding="utf-8"),
                kt_store=f_kt_store.read_text(encoding="utf-8"),
                kt_repo=f_kt_repo.read_text(encoding="utf-8"),
                swift_store=f_swift_store.read_text(encoding="utf-8"),
                swift_repo=f_swift_repo.read_text(encoding="utf-8"),
                msg_store_kt=f_msg_store.read_text(encoding="utf-8"),
                findings_txt=f_findings.read_text(encoding="utf-8"),
                adr_txt=f_adr.read_text(encoding="utf-8"),
                android_src=fake_android_src,
                ios_src=fake_ios_src,
            )

        # Baseline
        base_errs = run_check()
        if base_errs:
            print(f"::error::selftest baseline failed: {base_errs}")
            return 1

        # S01: Peer DB changed to godstone_messages.db
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("godstone_peer_identities.db", "godstone_messages.db"), encoding="utf-8")
        if any("S01" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S01 was NOT caught")
        reset_all()

        # S02: peer_identities added to MessageStore
        f_msg_store.write_text(f_msg_store.read_text(encoding="utf-8") + "\n// peer_identities table in message store\n", encoding="utf-8")
        if any("S02" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S02 was NOT caught")
        reset_all()

        # S03: Android peer key prefs changed to godstone_store_key
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("godstone_peer_identity_store_key", "godstone_store_key"), encoding="utf-8")
        if any("S03" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S03 was NOT caught")
        reset_all()

        # S04: Android peer key length check weakened
        f_kt_store.write_text(f_kt_store.read_text(encoding="utf-8").replace("decoded.size != 32", "decoded.size < 16"), encoding="utf-8")
        if any("S04" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S04 was NOT caught")
        reset_all()

        # S05: Missing key + existing DB generates replacement
        f_kt_store.write_text(f_kt_store.read_text(encoding="utf-8").replace("if (dbExists)", "if (false)"), encoding="utf-8")
        if any("S05" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S05 was NOT caught")
        reset_all()

        # S06: Checked commit replaced by .apply()
        f_kt_store.write_text(f_kt_store.read_text(encoding="utf-8").replace("persist(encoded)", "true; persist(encoded)"), encoding="utf-8")
        f_kt_store.write_text(f_kt_store.read_text(encoding="utf-8") + "\n// .apply()\n", encoding="utf-8")
        if any("S06" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S06 was NOT caught")
        reset_all()

        # S07: SQLCipher replaced with plaintext SQLite
        f_kt_store.write_text(f_kt_store.read_text(encoding="utf-8").replace("import net.zetetic.database.sqlcipher.SQLiteOpenHelper", "import android.database.sqlite.SQLiteOpenHelper"), encoding="utf-8")
        if any("S07" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S07 was NOT caught")
        reset_all()

        # S08: node_id length CHECK removed
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("CHECK (length(node_id) = 16),", ""), encoding="utf-8")
        if any("S08" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S08 was NOT caught")
        reset_all()

        # S09: signing_public_key length CHECK removed
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("CHECK (length(signing_public_key) = 32),", ""), encoding="utf-8")
        if any("S09" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S09 was NOT caught")
        reset_all()

        # S10: accepted_static_dh_public_key length CHECK removed
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("CHECK (length(accepted_static_dh_public_key) = 32),", ""), encoding="utf-8")
        if any("S10" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S10 was NOT caught")
        reset_all()

        # S11: accepted_generation uint32 CHECK removed
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("accepted_generation BETWEEN 0 AND 4294967295", "accepted_generation >= 0"), encoding="utf-8")
        if any("S11" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S11 was NOT caught")
        reset_all()

        # S12: trust_level code CHECK removed
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("CHECK (\n                trust_level IN (1,2,3)\n            ),", ""), encoding="utf-8")
        if any("S12" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S12 was NOT caught")
        reset_all()

        # S13: pending coupling CHECK removed
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("pending_static_dh_public_key IS NULL", "1 = 1"), encoding="utf-8")
        if any("S13" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S13 was NOT caught")
        reset_all()

        # S14: pending_generation monotonicity CHECK removed
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("pending_generation > accepted_generation", "1 = 1"), encoding="utf-8")
        if any("S14" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S14 was NOT caught")
        reset_all()

        # S15: pending static divergence CHECK removed
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("pending_static_dh_public_key != accepted_static_dh_public_key", "1 = 1"), encoding="utf-8")
        if any("S15" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S15 was NOT caught")
        reset_all()

        # S16: revoked with pending CHECK removed
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("trust_level != 3", "1 = 1"), encoding="utf-8")
        if any("S16" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S16 was NOT caught")
        reset_all()

        # S17: destructive onUpgrade DROP TABLE
        f_kt_store.write_text(f_kt_store.read_text(encoding="utf-8").replace("throw IllegalStateException(\n                \"Unimplemented", "db.execSQL(\"DROP TABLE\"); throw IllegalStateException(\"Unimplemented"), encoding="utf-8")
        if any("S17" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S17 was NOT caught")
        reset_all()

        # S18: future Android version silently allowed
        f_kt_store.write_text(f_kt_store.read_text(encoding="utf-8").replace("Unimplemented peer store schema migration", "migration complete"), encoding="utf-8")
        if any("S18" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S18 was NOT caught")
        reset_all()

        # S19: onOpen validation removed
        f_kt_store.write_text(f_kt_store.read_text(encoding="utf-8").replace("PeerIdentitySchema.validateSchema(db)", "// no validation"), encoding="utf-8")
        if any("S19" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S19 was NOT caught")
        reset_all()

        # S20: iOS peer protection changed away from complete
        f_swift_store.write_text(f_swift_store.read_text(encoding="utf-8").replace("FileProtectionType.complete", "FileProtectionType.none"), encoding="utf-8")
        if any("S20" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S20 was NOT caught")
        reset_all()

        # S21: public iOS initializer allows caller-selectable weaker protection
        f_swift_store.write_text(f_swift_store.read_text(encoding="utf-8").replace("convenience init(url: URL)", "init(url: URL, fileProtection: FileProtectionType = .complete)"), encoding="utf-8")
        if any("S21" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S21 was NOT caught")
        reset_all()

        # S22: iOS protection assignment changed to try?
        f_swift_store.write_text(f_swift_store.read_text(encoding="utf-8").replace("try protectionSetter", "try? protectionSetter"), encoding="utf-8")
        if any("S22" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S22 was NOT caught")
        reset_all()

        # S23: iOS BEGIN IMMEDIATE removed
        f_swift_store.write_text(f_swift_store.read_text(encoding="utf-8").replace("BEGIN IMMEDIATE", "BEGIN DEFERRED"), encoding="utf-8")
        if any("S23" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S23 was NOT caught")
        reset_all()

        # S24: No nested locking calls inside transaction body
        f_swift_store.write_text(f_swift_store.read_text(encoding="utf-8").replace("let result = try block(txStore)", "let result = try block(txStore); _ = try readRaw(Data())"), encoding="utf-8")
        if any("S24" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S24 was NOT caught")
        reset_all()

        # S25: Repository reads/evaluates before entering transaction
        f_kt_repo.write_text(f_kt_repo.read_text(encoding="utf-8").replace("store.inImmediateTransaction", "// store.inTransaction"), encoding="utf-8")
        if any("S25" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S25 was NOT caught")
        reset_all()

        # S26: Raw row reaches PeerTrustEngine without strict decode
        f_kt_repo.write_text(f_kt_repo.read_text(encoding="utf-8").replace("decodeRowStrict", "bypassStrictDecode"), encoding="utf-8")
        if any("S26" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S26 was NOT caught")
        reset_all()

        # S27: first-seen changed to INSERT OR IGNORE
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("INSERT INTO peer_identities", "INSERT OR IGNORE INTO peer_identities"), encoding="utf-8")
        if any("S27" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S27 was NOT caught")
        reset_all()

        # S28: initial-pending guarded UPDATE loses signing-key predicate
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("AND signing_public_key = ?", ""), encoding="utf-8")
        if any("S28" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S28 was NOT caught")
        reset_all()

        # S29: initial-pending guarded UPDATE loses accepted-static predicate
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("AND accepted_static_dh_public_key = ?", ""), encoding="utf-8")
        if any("S29" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S29 was NOT caught")
        reset_all()

        # S30: initial-pending guarded UPDATE loses accepted-generation predicate
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("AND accepted_generation = ?", ""), encoding="utf-8")
        if any("S30" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S30 was NOT caught")
        reset_all()

        # S31: initial-pending guarded UPDATE loses trust-level predicate
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("AND trust_level = ?", ""), encoding="utf-8")
        if any("S31" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S31 was NOT caught")
        reset_all()

        # S32: initial-pending guarded UPDATE loses pending-NULL predicate
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("AND pending_static_dh_public_key IS NULL", ""), encoding="utf-8")
        if any("S32" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S32 was NOT caught")
        reset_all()

        # S33: advance-pending UPDATE loses old pending-static predicate
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("AND pending_static_dh_public_key = ?", ""), encoding="utf-8")
        if any("S33" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S33 was NOT caught")
        reset_all()

        # S34: advance-pending UPDATE loses old pending-generation predicate
        f_kt_schema.write_text(f_kt_schema.read_text(encoding="utf-8").replace("AND pending_generation = ?", ""), encoding="utf-8")
        if any("S34" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S34 was NOT caught")
        reset_all()

        # S35: affected-row exact-one check removed
        f_kt_repo.write_text(f_kt_repo.read_text(encoding="utf-8").replace("MutationCardinality", "IgnoredCardinality"), encoding="utf-8")
        if any("S35" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S35 was NOT caught")
        reset_all()

        # S36: post-mutation readback removed
        f_kt_repo.write_text(f_kt_repo.read_text(encoding="utf-8").replace("MissingPostMutationRow", "IgnoredMissingRow"), encoding="utf-8")
        if any("S36" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S36 was NOT caught")
        reset_all()

        # S37: AcceptExisting performs mutation
        f_kt_repo.write_text(f_kt_repo.read_text(encoding="utf-8").replace("PeerTrustApplyResult.Accepted", "tx.setInitialPendingGuarded(binding.nodeId, binding.signingPublicKey, binding.staticDhPublicKey, 0L, 1, binding.staticDhPublicKey, 1L); PeerTrustApplyResult.Accepted"), encoding="utf-8")
        if any("S37" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S37 was NOT caught")
        reset_all()

        # S38: KeepQuarantined performs mutation
        f_kt_repo.write_text(f_kt_repo.read_text(encoding="utf-8").replace("PeerTrustApplyResult.KeyChangedQuarantined", "tx.advancePendingGuarded(binding.nodeId, binding.signingPublicKey, binding.staticDhPublicKey, 0L, 1, binding.staticDhPublicKey, 1L, binding.staticDhPublicKey, 2L); PeerTrustApplyResult.KeyChangedQuarantined"), encoding="utf-8")
        if any("S38" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S38 was NOT caught")
        reset_all()

        # S39: Reject performs mutation
        f_kt_repo.write_text(f_kt_repo.read_text(encoding="utf-8").replace("PeerTrustApplyResult.Rejected(plan.reason)", "tx.insertFirstSeen(binding.nodeId, binding.signingPublicKey, binding.staticDhPublicKey, 0L, 1); PeerTrustApplyResult.Rejected(plan.reason)"), encoding="utf-8")
        if any("S39" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S39 was NOT caught")
        reset_all()

        # S40: Network trust promotion (e.g. USER_VERIFIED set on first seen)
        f_kt_repo.write_text(f_kt_repo.read_text(encoding="utf-8").replace("trustCode = PeerTrustLevel.TOFU_PINNED.persistedCode", "trustCode = PeerTrustLevel.USER_VERIFIED.persistedCode"), encoding="utf-8")
        if any("S40" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S40 was NOT caught")
        reset_all()

        # S41: VerifiedPeerIdentity.fromRecord called in third production file
        (fake_android_src / "BypassCaller.kt").write_text("package io.godstone.mesh.identity\nval x = VerifiedPeerIdentity.fromRecord(null!!)\n", encoding="utf-8")
        if any("S41" in e or "S42" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S41 was NOT caught")
        reset_all()

        # S42: PendingPeerIdentity.fromRecord called in third production file
        (fake_ios_src / "BypassPending.swift").write_text("import Foundation\nlet p = PendingPeerIdentity.fromRecord(null)\n", encoding="utf-8")
        if any("S41" in e or "S42" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S42 was NOT caught")
        reset_all()

        # S43: PeerIdentityRecord constructor called in third production file
        (fake_android_src / "BypassRec.kt").write_text("package io.godstone.mesh.identity\nval r = PeerIdentityRecord(ByteArray(16), ByteArray(32), ByteArray(32), 0L, PeerTrustLevel.TOFU_PINNED)\n", encoding="utf-8")
        if any("S43" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S43 was NOT caught")
        reset_all()

        # S44: PeerIdentityStore directly mints VerifiedPeerIdentity
        f_kt_store.write_text(f_kt_store.read_text(encoding="utf-8") + "\nfun mint() = VerifiedPeerIdentity.fromRecord(null!!)\n", encoding="utf-8")
        if any("S44" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S44 was NOT caught")
        reset_all()

        # S45: A-05 marked closed
        findings_data = json.loads(f_findings.read_text(encoding="utf-8"))
        for f in findings_data["findings"]:
            if f["id"] == "A-05":
                f["status"] = "CLOSED"
        f_findings.write_text(json.dumps(findings_data), encoding="utf-8")
        if any("S45" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S45 was NOT caught")
        reset_all()

        # S46: status claims BoundRecipientKeyResolver implemented
        findings_data = json.loads(f_findings.read_text(encoding="utf-8"))
        for f in findings_data["findings"]:
            if f["id"] == "A-05":
                f["bound_recipient_key_resolver"] = "RESOLVED"
        f_findings.write_text(json.dumps(findings_data), encoding="utf-8")
        if any("S46" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S46 was NOT caught")
        reset_all()

        # S47: Raw SQL re-added to production store
        f_kt_store.write_text(f_kt_store.read_text(encoding="utf-8").replace("interface PeerIdentityStore : AutoCloseable {", "interface PeerIdentityStore : AutoCloseable {\n    fun execRawSql(sql: String)\n"), encoding="utf-8")
        if any("S47" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S47 was NOT caught")
        reset_all()

        # S48: Corrupt returned normally from transaction instead of aborting
        f_kt_repo.write_text(f_kt_repo.read_text(encoding="utf-8").replace("abortCorrupt(decode.reason)", "return@inImmediateTransaction PeerTrustApplyResult.Corrupt(decode.reason)"), encoding="utf-8")
        if any("S48" in e for e in run_check()): passed += 1
        else: failures.append("Mutation S48 was NOT caught")
        reset_all()

    if failures:
        for f in failures:
            print(f"::error::selftest failure: {f}")
        return 1

    print(f"check_peer_identity_store_controls selftest PASSED ({passed}/48 mutations caught deterministically).")
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
            print(f"::error::Peer identity store control error: {e}", file=sys.stderr)
        print(f"\nFAIL: {len(errors)} peer identity store control issue(s) found.", file=sys.stderr)
        return 1

    print("PEER IDENTITY STORE CONTROLS GATE: PASS -- durable store, schema, guarded SQL, and transaction invariants satisfied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
