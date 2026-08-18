import XCTest
import CryptoKit
import SQLite3
@testable import GodstoneMesh
import GodstoneCore

/// Stage 4C.1 / C6.1; C6.3; **C6.4** -- the production `SqliteDeliveryRepository`
/// over a REAL on-disk SQLite (`SqliteMessageStore`, the same engine the store
/// tests use). The delivery state, ack mode and intended recipient live in ONE row
/// keyed by msg_id; the expected recipient is IMMUTABLE post-creation (there is
/// no recipient-only write). C6.3 folded the C6.1 `DeliveryJournal` plus the
/// enqueue / transition / retire classification into ONE atomic aggregate over
/// that row. C6.4 hardens that aggregate (mirrors `SqliteDeliveryRepositoryTest`
/// on Android one-for-one):
///
///  * StorageFailure is REAL (C6.4-A): the iOS store primitives THROW on a SQL /
///    IO / missing-handle failure; the repository catches and maps to the typed
///    `.storageFailure` variant, distinct from absence / conflict / no-match. The
///    `FaultingDeliveryStore` (a controlled failing handle -- NOT a corrupt random
///    temp file) injects selective faults: read failure -> `.storageFailure`;
///    insert failure -> `.storageFailure`; transition/ACK/clear exec failure ->
///    `.storageFailure`.
///  * No corrupt -> unavailable collapse (C6.4-B): a corrupt record reads
///    `.corrupt` at the `lookup` seam, NOT `.unavailable`; the lossy `state` seam
///    is gone.
///  * No durable state=UNAVAILABLE (C6.4-C): the schema `CHECK (state IN (1..5))`
///    rejects code 0 at write time and `fromPersistedCode` rejects it at read time
///    (defense in depth); a persisted state=0 reads `.corrupt` and cannot revive.
///  * 16-byte msg_id (C6.4-D): the schema `CHECK (length(msg_id) = 16)` on BOTH
///    tables + a repository input guard; every method rejects a non-16-byte msg_id
///    with `.invalidArgument` before any SQL.
///  * PRAGMA user_version versioning (C6.4-E): a stale `user_version` is
///    recreated (drop+recreate) and stamped; the logical revision matches Android
///    `DB_VERSION`.
///  * Real SQL CAS (C6.4-F/G): `transition` is a guarded `UPDATE ... WHERE msg_id
///    AND state IN (...)` decided by the affected row count; the repository owns
///    the truth-table (`DeliveryTransition`).
///  * ACK CAS (C6.4-H): `acknowledgeBound` binds state + mode + the exact durable
///    recipient in ONE WHERE clause; a 0-row CAS is re-read and classified
///    (`.duplicateAuthenticatedAck` / `.rejectedState` / `.unknownMessage` /
///    `.storageFailure`).
///  * `acknowledgeBound` retires delivery state ONLY (C6.4-I); held-frame
///    retirement is C7.4 (ADR-004 delete-on-ACK NOT closed).
///  * Typed `clear` (C6.4-J): `.cleared` / `.alreadyAbsent` / `.storageFailure` /
///    `.corrupt` / `.invalidArgument`.
///  * Deterministic concurrency (C6.4-L): a `BlockingAckAuthenticator` opens a
///    window between the tracker's `get` and `acknowledgeBound`; a racing
///    cancel/expire/second-ACK runs through the SAME locked store; the result is
///    decided by the CAS predicate, not a probabilistic thread race.
///  * Mutation controls (C6.4-M): each guard (stateGuard/modeGuard/recipientGuard)
///    dropped independently proves the predicate is load-bearing (the WRONG
///    outcome results).
///  * C1/C2 integration + fail-closed production composition over the real store.
final class SqliteDeliveryRepositoryTests: XCTestCase {

    private func msgId(_ seed: UInt8) -> Data {
        Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ seed) })
    }
    private let routingTag = Data([0, 1, 2, 3])
    private func nodeA() -> Data { Data(repeating: 0x01, count: 16) }
    private func nodeB() -> Data { Data(repeating: 0x02, count: 16) }

    /// Resolver binding a single node id to a key.
    private final class SingleRecipientResolver: RecipientKeyResolver {
        let expectedNodeId: Data, pubKey: Data
        init(_ expectedNodeId: Data, _ pubKey: Data) {
            self.expectedNodeId = expectedNodeId
            self.pubKey = pubKey
        }
        func publicSigningKey(forNodeId nodeId: Data) -> Data? {
            nodeId == expectedNodeId ? pubKey : nil
        }
    }

    /// Resolver binding two distinct node ids to two distinct keys (C2 test).
    private final class TwoRecipientResolver: RecipientKeyResolver {
        let a: Data, pubA: Data, b: Data, pubB: Data
        init(_ a: Data, _ pubA: Data, _ b: Data, _ pubB: Data) {
            self.a = a; self.pubA = pubA; self.b = b; self.pubB = pubB
        }
        func publicSigningKey(forNodeId nodeId: Data) -> Data? {
            if nodeId == a { return pubA }
            if nodeId == b { return pubB }
            return nil
        }
    }

    /// A real Ed25519 keypair (32-byte raw pub/priv).
    private func realKeypair() -> (pub: Data, priv: Data) {
        let priv = Curve25519.Signing.PrivateKey()
        return (priv.publicKey.rawRepresentation, priv.rawRepresentation)
    }

    /// A fresh on-disk store + repository at a unique temp URL.
    private func openRepo() -> (repo: SqliteDeliveryRepository, store: SqliteMessageStore, url: URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-delivery-\(UUID().uuidString).db")
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        return (SqliteDeliveryRepository(store), store, url)
    }

    /// Weakened (mutation-control) repository over the SAME store (C6.4-M /
    /// C6.4.1-A). Production `SqliteDeliveryRepository` builds its CAS WHERE
    /// clause UNCONDITIONALLY; the test-only `MutatedDeliveryRepository` rebuilds
    /// the WEAKENED SQL (a guard dropped) to prove a predicate is load-bearing.
    private func newRepo(_ store: SqliteMessageStore,
                          stateGuard: Bool = true, modeGuard: Bool = true,
                          recipientGuard: Bool = true,
                          skipHeldRetirement: Bool = false) -> MutatedDeliveryRepository {
        MutatedDeliveryRepository(store, stateGuard: stateGuard, modeGuard: modeGuard,
                                   recipientGuard: recipientGuard,
                                   skipHeldRetirement: skipHeldRetirement)
    }

    /// Extract the record from a `.found` lookup (fail the test otherwise).
    private func found(_ j: SqliteDeliveryRepository, _ mid: Data) -> DeliveryRecord {
        if case .found(let rec) = j.get(mid) { return rec }
        XCTFail("expected .found(\(mid))"); return DeliveryRecord(
            msgId: mid, state: .unavailable, ackMode: .none, expectedRecipientNodeId: nil)
    }

    /// C6.4-B helper: the state inside a `.found` lookup, or nil otherwise.
    private func stateOf(_ tracker: DeliveryTracker, _ mid: Data) -> DeliveryState? {
        if case .found(let rec) = tracker.lookup(mid) { return rec.state }
        return nil
    }

    private func localNode(_ seed: UInt8 = 0x10) -> Data {
        Data((0..<16).map { UInt8(($0 + Int(seed)) & 0xFF) })
    }

    private func directFrame(
        _ seed: UInt8,
        payloadSize: Int = 80,
        type: TypeV2 = .message,
        priority: Priority = .direct,
        sealed: Bool = true,
        hasPow: Bool = false,
        msgIdOverride: Data? = nil
    ) -> FrameV2 {
        var flags = UInt16(priority.rawValue << 8)
        if sealed { flags |= UInt16(FrameV2.Flags.sealed) }
        if hasPow { flags |= UInt16(FrameV2.Flags.has_pow) }
        return FrameV2(
            type: type,
            msgId: msgIdOverride ?? msgId(seed),
            routingTag: routingTag,
            ttl: 12,
            hopCount: 0,
            flags: flags,
            payload: Data(repeating: seed, count: payloadSize)
        )
    }

    private func plantHeld(_ store: SqliteMessageStore, _ mid: Data) {
        let f = FrameV2(type: .message, msgId: mid, routingTag: Data(count: 4), ttl: 10, hopCount: 0, flags: 0, payload: Data(count: 32))
        _ = store.persist(f, receivedFrom: Data())
    }

    /// C6.4-C/D: plant a bad `state` code past the new schema CHECKs via
    /// `PRAGMA ignore_check_constraints` (documented since SQLite 3.7.0; the iOS
    /// sqlite3 engine honors it). Production never does this.
    private func plantBadState(_ store: SqliteMessageStore, _ mid: Data, _ code: Int32) throws {
        try store.execRawSql("PRAGMA ignore_check_constraints = ON")
        _ = store.execRawUpdate("UPDATE delivery_state SET state = \(code) WHERE msg_id = ?", [mid])
        try store.execRawSql("PRAGMA ignore_check_constraints = OFF")
    }

    /// C6.4-M: plant a binding-inconsistent row (ack_mode=0 / NONE with a
    /// recipient) past the binding CHECK, so the modeGuard mutation test can prove
    /// the `ack_mode = SINGLE_RECIPIENT` predicate is load-bearing (without it an
    /// ACK lands on a NONE-mode row).
    private func plantCorruptBinding(_ store: SqliteMessageStore, _ mid: Data,
                                     _ recipient: Data) throws {
        try store.execRawSql("PRAGMA ignore_check_constraints = ON")
        _ = store.execRawUpdate(
            "UPDATE delivery_state SET ack_mode = 0, expected_recipient = ? WHERE msg_id = ?",
            [recipient, mid])
        try store.execRawSql("PRAGMA ignore_check_constraints = OFF")
    }

    // MARK: - C6.4-A: FaultingDeliveryStore (controlled failing handle)

    /// A `DeliveryStore` wrapper that injects selective faults (C6.4-A). NOT a
    /// corrupt random temp file -- a real `SqliteMessageStore` with per-method
    /// A `DeliveryStore` wrapper that injects selective faults (C6.4-A). NOT a
    /// corrupt random temp file -- a real `SqliteMessageStore` with per-method
    /// fault flags, synchronized on a lock so two threads share the one
    /// connection safely (the concurrency tests). Mirrors Android `FaultingStoreDb`.
    /// (Swift has no `@Volatile` attribute; the `NSLock` / `DispatchSemaphore`
    /// barriers provide the cross-thread memory ordering Kotlin's `@Volatile`
    /// gives, so plain `var` under the lock is correct here.)
    private final class FaultingDeliveryStore: DeliveryStore {
        private let underlying: SqliteMessageStore
        private let lock = NSLock()
        var faultReadDelivery = false
        var faultInsertDelivery = false
        var faultExecDeliveryUpdate = false

        init(_ underlying: SqliteMessageStore) { self.underlying = underlying }

        func readDelivery(_ msgId: Data) throws -> DeliveryRow? {
            lock.lock(); defer { lock.unlock() }
            if faultReadDelivery { throw FaultError.injected }
            return try underlying.readDelivery(msgId)
        }
        func insertDelivery(_ msgId: Data, stateOrdinal: Int32, ackModeOrdinal: Int32,
                            expectedRecipient: Data?) throws -> Bool {
            lock.lock(); defer { lock.unlock() }
            if faultInsertDelivery { throw FaultError.injected }
            return try underlying.insertDelivery(msgId, stateOrdinal: stateOrdinal,
                                                  ackModeOrdinal: ackModeOrdinal,
                                                  expectedRecipient: expectedRecipient)
        }
        func execDeliveryUpdate(_ sql: String, bytesArgs: [Data?]) throws -> Int {
            lock.lock(); defer { lock.unlock() }
            if faultExecDeliveryUpdate { throw FaultError.injected }
            return try underlying.execDeliveryUpdate(sql, bytesArgs: bytesArgs)
        }
        func atomicAcknowledgeAndRetire(
            guardedAckSql: String,
            msgId: Data,
            expectedRecipient: Data
        ) throws -> AckRetireMutationResult {
            lock.lock(); defer { lock.unlock() }
            if faultAtomicAcknowledgeAndRetire { throw FaultError.injected }
            return try underlying.atomicAcknowledgeAndRetire(
                guardedAckSql: guardedAckSql,
                msgId: msgId,
                expectedRecipient: expectedRecipient
            )
        }
        var faultAtomicAcknowledgeAndRetire = false

        func atomicTransitionAndRetire(
            guardedTransitionSql: String,
            msgId: Data
        ) throws -> TerminalRetireMutationResult {
            lock.lock(); defer { lock.unlock() }
            if faultAtomicTransitionAndRetire { throw FaultError.injected }
            return try underlying.atomicTransitionAndRetire(
                guardedTransitionSql: guardedTransitionSql,
                msgId: msgId
            )
        }
        var faultAtomicTransitionAndRetire = false
    }
    private enum FaultError: Error { case injected }

    // MARK: - C6.4-L: authenticators for deterministic interleaving

    /// Authenticator that opens a window between the tracker's `get` and
    /// `acknowledgeBound`: `verify` signals `reached` (the test knows the ACK got
    /// past the get + binding check), then blocks on `release` (the test runs the
    /// racing operation in that window), then returns `result`. Mirrors Android
    /// `BlockingAuthenticator`. The racing op runs through the SAME locked store,
    /// so the result is decided by the CAS predicate, not a probabilistic race.
    private final class BlockingAckAuthenticator: AckAuthenticator {
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var result: Bool
        init(result: Bool) { self.result = result }
        func verify(originalMsgId: Data, expectedRecipientNodeId: Data, ackFrame: FrameV2) -> Bool {
            reached.signal()
            release.wait()
            return result
        }
    }

    /// 2-party barrier authenticator: both ACKs reach `verify` before either
    /// proceeds, so two concurrent authenticated ACKs both pass `get` and reach
    /// the CAS -- exercising the dual-ACK race. Each verify signals `arrived` then
    /// waits on `release`; the coordinator waits for two arrivals, then releases
    /// both.
    private final class DualAckAuthenticator: AckAuthenticator {
        let arrived = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var result = true
        func verify(originalMsgId: Data, expectedRecipientNodeId: Data, ackFrame: FrameV2) -> Bool {
            arrived.signal()
            release.wait()
            return result
        }
    }

    /// Authenticator that fails the test if ever invoked (for the NONE-mode path,
    /// which must short-circuit BEFORE authentication).
    private final class NeverInvokeAuthenticator: AckAuthenticator {
        func verify(originalMsgId: Data, expectedRecipientNodeId: Data, ackFrame: FrameV2) -> Bool {
            XCTFail("authenticator must NOT be invoked for a NONE-mode / corrupt / terminal record")
            return false
        }
    }

    /// Mutable result holder shared with a background ACK thread. Visibility is
    /// provided by the `XCTestExpectation` fulfill/wait + semaphore barriers (Swift
    /// has no `@Volatile`; the barriers are the ordering primitive).
    private final class ResultBox { var value: AckResult = .unknownMessage }

    /// Mutable TransitionResult holder shared with a background transition thread
    /// (C6.4-L transition-vs-transition races). Same barrier-visibility rationale.
    private final class TransitionResultBox { var value: TransitionResult = .unknownMessage }

    // MARK: - enqueue / get

    func testEnqueueCreatesQueuedDurablyRowWithAckModeAndRecipient() throws {
        let (j, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(1)
        XCTAssertEqual(DeliveryLookup.notFound, j.get(mid))
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        let rec = found(j, mid)
        XCTAssertEqual(.queuedDurably, rec.state)
        XCTAssertEqual(.singleRecipient, rec.ackMode)
        XCTAssertEqual(rec.expectedRecipientNodeId ?? Data(), nodeA())
    }

    func testNoneModeEnqueueBindsNoRecipient() throws {
        let (j, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(2)
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .none, expectedRecipient: nil))
        let rec = found(j, mid)
        XCTAssertEqual(.none, rec.ackMode)
        XCTAssertNil(rec.expectedRecipientNodeId)
    }

    func testSecondEnqueueForSameMsgIdIsIdempotentOnSameBindingAndDoesNotMutateRecipient() throws {
        let (j, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(3)
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(EnqueueResult.alreadyQueuedSameBinding,
                       j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(EnqueueResult.conflictRecipient,
                       j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeB()))
        let rec = found(j, mid)
        XCTAssertEqual(rec.expectedRecipientNodeId ?? Data(), nodeA(),
                       "duplicate enqueue must not mutate the bound recipient")
        XCTAssertEqual(.queuedDurably, rec.state)
    }

    // MARK: - the load-bearing preservation invariant (C6.4-F/G/H)

    func testTransitionAndAcknowledgeBoundAdvanceOnlyStateColumnPreservingAckModeAndRecipient() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(4)
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(TransitionResult.applied, j.transition(mid, .markHanded))
        XCTAssertEqual(.handedToRelay, found(j, mid).state)
        XCTAssertEqual(found(j, mid).expectedRecipientNodeId ?? Data(), nodeA(),
                       "state-only write must preserve the bound expected recipient")
        XCTAssertEqual(.singleRecipient, found(j, mid).ackMode,
                       "state-only write must preserve the ack mode")
        plantHeld(store, mid)
        XCTAssertEqual(AckResult.applied, j.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA()))
        XCTAssertEqual(.acknowledgedByRecipient, found(j, mid).state)
        XCTAssertEqual(found(j, mid).expectedRecipientNodeId ?? Data(), nodeA(),
                       "ACKNOWLEDGED write must preserve the bound expected recipient")
        // transition for an unknown msg_id is UnknownMessage.
        XCTAssertEqual(TransitionResult.unknownMessage, j.transition(msgId(99), .markHanded))
    }

    func testTransitionAlreadyInTargetIsIdempotent() throws {
        let (j, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(45)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        XCTAssertEqual(.applied, j.transition(mid, .markHanded))
        XCTAssertEqual(.alreadyInTarget, j.transition(mid, .markHanded), "idempotent from HANDED")
    }

    func testTerminalRejectsNonAckTransitions() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(46)
        plantHeld(store, mid)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        XCTAssertEqual(.applied, j.transition(mid, .cancel))
        // CANCELLED is terminal: markHanded / expire are rejected; cancel is idempotent.
        XCTAssertEqual(.rejectedState, j.transition(mid, .markHanded))
        XCTAssertEqual(.rejectedState, j.transition(mid, .expire))
        XCTAssertEqual(.alreadyInTarget, j.transition(mid, .cancel))
    }

    // MARK: - clear (C6.4-J) + reboot recovery

    func testClearDropsTheRowTyped() throws {
        let (j, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(5)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        XCTAssertEqual(ClearResult.cleared, j.clear(mid))
        XCTAssertEqual(DeliveryLookup.notFound, j.get(mid))
        XCTAssertEqual(ClearResult.alreadyAbsent, j.clear(mid), "re-clear is alreadyAbsent")
    }

    func testRebootRecoveryFreshRepositoryOverSameFileRecoversStateAckModeAndRecipient() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-delivery-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var boot1: SqliteDeliveryRepository? = {
            let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
            return SqliteDeliveryRepository(store)
        }()
        let mid = msgId(6)
        XCTAssertEqual(EnqueueResult.created, boot1!.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(TransitionResult.applied, boot1!.transition(mid, .markHanded))
        XCTAssertEqual(.handedToRelay, found(boot1!, mid).state)
        boot1 = nil
        let store2 = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let boot2 = SqliteDeliveryRepository(store2)
        let rec = found(boot2, mid)
        XCTAssertEqual(.handedToRelay, rec.state, "state recovered after reboot")
        XCTAssertEqual(.singleRecipient, rec.ackMode, "ack mode recovered after reboot")
        XCTAssertEqual(rec.expectedRecipientNodeId ?? Data(), nodeA(),
                       "expected recipient recovered after reboot")
    }

    // MARK: - C6.4-D: 16-byte msg_id at every boundary

    func testNon16ByteMsgIdRejectedAsInvalidArgumentAtEveryBoundary() {
        let (j, _, _) = openRepo()
        for bad in [Data(), Data(count: 8), Data(count: 15), Data(count: 17), Data(count: 64)] {
            XCTAssertEqual(DeliveryLookup.invalidArgument, j.get(bad), "get rejects non-16-byte msg_id")
            XCTAssertEqual(EnqueueResult.invalidArgument, j.enqueue(bad, ackMode: .none, expectedRecipient: nil))
            XCTAssertEqual(TransitionResult.invalidArgument, j.transition(bad, .markHanded))
            XCTAssertEqual(AckResult.invalidArgument, j.acknowledgeBoundAndRetire(bad, expectedRecipient: nodeA()))
            XCTAssertEqual(ClearResult.invalidArgument, j.clear(bad))
        }
        // exactly 16 bytes is accepted (smoke).
        let mid = msgId(7)
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .none, expectedRecipient: nil))
        XCTAssertEqual(.queuedDurably, found(j, mid).state)
    }

    // MARK: - schema CHECK enforces C6.1 binding + C6.4-C/D invariants at DB level

    func testSchemaCheckEnforcesBindingAndStateAndMsgIdInvariantsAtDbLevel() throws {
        // The repository guards the invariants BEFORE it touches the DB, so to
        // exercise the DB-level CHECK directly we insert below the repository via
        // `SqliteMessageStore.insertDelivery` (now `throws` -- a CHECK violation
        // throws, the C6.4-A strict-primitive behavior; Android's JDBC raises
        // SQLException, same invariant).
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(7)
        // SINGLE_RECIPIENT + null recipient violates the binding CHECK -> throws.
        XCTAssertThrowsError(
            try store.insertDelivery(mid, stateOrdinal: DeliveryState.queuedDurably.code,
                                      ackModeOrdinal: AckMode.singleRecipient.rawValue,
                                      expectedRecipient: nil),
            "SINGLE_RECIPIENT + null recipient must violate the CHECK")
        XCTAssertEqual(DeliveryLookup.notFound, j.get(mid), "no row written on CHECK violation")
        // NONE + recipient violates the binding CHECK.
        XCTAssertThrowsError(
            try store.insertDelivery(mid, stateOrdinal: DeliveryState.queuedDurably.code,
                                      ackModeOrdinal: AckMode.none.rawValue,
                                      expectedRecipient: Data(count: 16)))
        // A short (non-16-byte) recipient violates the binding CHECK.
        XCTAssertThrowsError(
            try store.insertDelivery(mid, stateOrdinal: DeliveryState.queuedDurably.code,
                                      ackModeOrdinal: AckMode.singleRecipient.rawValue,
                                      expectedRecipient: Data(count: 8)))
        // A non-16-byte msg_id violates the msg_id CHECK on delivery_state.
        XCTAssertThrowsError(
            try store.insertDelivery(Data(count: 8), stateOrdinal: DeliveryState.queuedDurably.code,
                                      ackModeOrdinal: AckMode.none.rawValue,
                                      expectedRecipient: nil))
        // A state=0 (UNAVAILABLE) row violates the state CHECK (C6.4-C).
        XCTAssertThrowsError(
            try store.insertDelivery(mid, stateOrdinal: 0,
                                      ackModeOrdinal: AckMode.none.rawValue,
                                      expectedRecipient: nil),
            "state=0 (UNAVAILABLE) must violate the state CHECK")
        XCTAssertEqual(DeliveryLookup.notFound, j.get(mid))
    }

    // MARK: - C6.5 / C6.4-B/C: unknown + persisted-0 states fail closed to Corrupt

    func testUnknownPersistedStateCodeReadsAsCorruptNotUnavailable() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(8)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        try plantBadState(store, mid, 999) // past the state CHECK via ignore_check_constraints
        XCTAssertEqual(DeliveryLookup.corrupt, j.get(mid),
                       "an unknown state code must fail closed to Corrupt, NOT UNAVAILABLE")
    }

    func testPersistedStateZeroReadsAsCorruptAndCannotRevive() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(9)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        try plantBadState(store, mid, 0) // persisted UNAVAILABLE -- not a legal durable row (C6.4-C)
        XCTAssertEqual(DeliveryLookup.corrupt, j.get(mid),
                       "a persisted state=0 (UNAVAILABLE) reads Corrupt, NOT a revive to UNAVAILABLE")
        // A corrupt row rejects every mutation -- it cannot be "revived" to a
        // tracked state.
        XCTAssertEqual(EnqueueResult.corrupt, j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(TransitionResult.corrupt, j.transition(mid, .markHanded))
        XCTAssertEqual(AckResult.corrupt, j.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA()))
    }

    func testUnknownAckModeCodeDecodesToNilFailClosed() {
        XCTAssertNil(AckMode.fromCode(999))
        XCTAssertNil(AckMode.fromCode(-1))
        XCTAssertEqual(AckMode.fromCode(0), .some(AckMode.none)) // pin the Swift .none pitfall
        XCTAssertEqual(AckMode.fromCode(1), .some(.singleRecipient))
    }

    func testTrackerOverCorruptRecordReadsCorruptNotUnavailable() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(10)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        try plantBadState(store, mid, 0)
        let tracker = DeliveryTracker(repo: j, authenticator: NeverInvokeAuthenticator())
        XCTAssertEqual(DeliveryLookup.corrupt, tracker.lookup(mid))
    }

    func testAcknowledgeOnCorruptRowFailsClosedToCorrupt() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(11)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        try plantBadState(store, mid, 0)
        let tracker = DeliveryTracker(repo: j, authenticator: NeverInvokeAuthenticator())
        XCTAssertEqual(AckResult.corrupt, tracker.acknowledge(mid, rawAck(mid)),
                       "an ACK over a corrupt row fails closed to Corrupt, NOT RejectedState / UnknownMessage")
    }

    func testEnqueueOverCorruptRowFailsClosedToCorrupt() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(12)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        try plantBadState(store, mid, 0)
        XCTAssertEqual(EnqueueResult.corrupt,
                       j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
    }

    // MARK: - C6.4-A: StorageFailure typed propagation across all repository operations

    private func faultingRepo() -> (repo: SqliteDeliveryRepository, faulting: FaultingDeliveryStore, url: URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let faulting = FaultingDeliveryStore(store)
        return (SqliteDeliveryRepository(faulting), faulting, url)
    }

    func testGetFailureMapsToStorageFailure() throws {
        let (repo, faulting, url) = faultingRepo(); defer { try? FileManager.default.removeItem(at: url) }
        _ = repo.enqueue(msgId(13), ackMode: .singleRecipient, expectedRecipient: nodeA())
        faulting.faultReadDelivery = true
        XCTAssertEqual(DeliveryLookup.storageFailure, repo.get(msgId(13)),
                       "read failure -> StorageFailure, NOT NotFound")
    }

    func testEnqueueFailureMapsToStorageFailure() throws {
        let (repo, faulting, url) = faultingRepo(); defer { try? FileManager.default.removeItem(at: url) }
        faulting.faultInsertDelivery = true
        XCTAssertEqual(EnqueueResult.storageFailure,
                       repo.enqueue(msgId(13), ackMode: .none, expectedRecipient: nil),
                       "insert failure -> StorageFailure")
    }

    func testTransitionFailureMapsToStorageFailure() throws {
        let (repo, faulting, url) = faultingRepo(); defer { try? FileManager.default.removeItem(at: url) }
        _ = repo.enqueue(msgId(13), ackMode: .singleRecipient, expectedRecipient: nodeA())
        faulting.faultExecDeliveryUpdate = true
        XCTAssertEqual(TransitionResult.storageFailure, repo.transition(msgId(13), .markHanded),
                       "transition exec failure -> StorageFailure")
    }

    func testAckFailureMapsToStorageFailure() throws {
        let (repo, faulting, url) = faultingRepo(); defer { try? FileManager.default.removeItem(at: url) }
        _ = repo.enqueue(msgId(14), ackMode: .singleRecipient, expectedRecipient: nodeA())
        faulting.faultAtomicAcknowledgeAndRetire = true
        XCTAssertEqual(AckResult.storageFailure,
                       repo.acknowledgeBoundAndRetire(msgId(14), expectedRecipient: nodeA()),
                       "ACK exec failure -> StorageFailure")
    }

    func testClearFailureMapsToStorageFailure() throws {
        let (repo, faulting, url) = faultingRepo(); defer { try? FileManager.default.removeItem(at: url) }
        _ = repo.enqueue(msgId(15), ackMode: .none, expectedRecipient: nil)
        faulting.faultExecDeliveryUpdate = true
        XCTAssertEqual(ClearResult.storageFailure, repo.clear(msgId(15)),
                       "clear exec failure -> StorageFailure")
    }

    // MARK: - C6.4-H: zero-row ACK CAS classification

    func testAckAfterCancelIsRejectedState() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(16)
        plantHeld(store, mid)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        XCTAssertEqual(.applied, j.transition(mid, .cancel))
        // The ACK lost the CAS to a cancel -> 0-row -> re-read CANCELLED -> RejectedState.
        XCTAssertEqual(AckResult.rejectedState,
                       j.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA()))
    }

    func testCancelAfterAckIsRejectedState() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(17)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        plantHeld(store, mid)
        XCTAssertEqual(AckResult.applied, j.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA()))
        // cancel on an ACKNOWLEDGED row -> 0-row -> cancel's validFroms are
        // {queued,handed}, so RejectedState.
        XCTAssertEqual(TransitionResult.rejectedState, j.transition(mid, .cancel))
    }

    func testWrongRecipientAckIsUnknownMessage() throws {
        let (j, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(18)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        // ACK with a recipient that does not match the bound row -> 0-row -> re-read
        // -> binding changed -> UnknownMessage (an old ACK must never bind to a row).
        XCTAssertEqual(AckResult.unknownMessage,
                       j.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeB()))
    }

    func testDuplicateAuthenticatedAckIsReachableViaZeroRowCas() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(19)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        plantHeld(store, mid)
        XCTAssertEqual(AckResult.applied, j.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA()))
        // A second ACK with the SAME binding -> 0-row (state is ACKNOWLEDGED, not in
        // {queued,handed}) -> re-read ACKNOWLEDGED same binding -> DuplicateAuthenticatedAck.
        XCTAssertEqual(AckResult.duplicateAuthenticatedAck,
                       j.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA()),
                       "same-binding ACK that lost the CAS to a prior ACK -> DuplicateAuthenticatedAck")
    }

    // MARK: - C6.4-L: deterministic concurrency (BlockingAckAuthenticator)

    /// Shared setup for the ACK-vs-cancel / ACK-vs-expire races: enqueues +
    /// markHanded a SINGLE_RECIPIENT row, then starts a background ACK that blocks
    /// in `verify` (between the tracker's `get` and `acknowledgeBound`). Returns
    /// the tracker, the blocking authenticator, the expectation, and a result box
    /// the background thread writes the AckResult into. The caller runs the racing
    /// op while the ACK is blocked, then `auth.release.signal()` and waits.
    private func beginAckRace(seed: UInt8, url: URL)
        -> (tracker: DeliveryTracker, auth: BlockingAckAuthenticator,
            exp: XCTestExpectation, box: ResultBox) {
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let faulting = FaultingDeliveryStore(store)
        let repo = SqliteDeliveryRepository(faulting)
        let (_, priv) = realKeypair()
        let recipient = nodeA()
        let auth = BlockingAckAuthenticator(result: true)
        let tracker = DeliveryTracker(repo: repo, authenticator: auth)
        let mid = msgId(seed)
        plantHeld(store, mid)
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipient))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))
        let ack = try! AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipient, routingTag: routingTag)
        let exp = expectation(description: "ack \(seed)")
        let box = ResultBox()
        DispatchQueue.global().async {
            box.value = tracker.acknowledge(mid, ack)
            exp.fulfill()
        }
        auth.reached.wait()
        return (tracker, auth, exp, box)
    }

    func testAckVsCancelLosesCasToRejectedState() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let (tracker, auth, exp, box) = beginAckRace(seed: 100, url: url)
        // cancel wins the CAS while the ACK is blocked in verify.
        XCTAssertEqual(TransitionResult.applied, tracker.cancel(msgId(100)))
        auth.release.signal()
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(AckResult.rejectedState, box.value, "ACK that loses the CAS to cancel -> RejectedState")
        XCTAssertEqual(.cancelledLocally, stateOf(tracker, msgId(100)))
    }

    func testAckVsExpireLosesCasToRejectedState() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let (tracker, auth, exp, box) = beginAckRace(seed: 101, url: url)
        XCTAssertEqual(TransitionResult.applied, tracker.expire(msgId(101)))
        auth.release.signal()
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(AckResult.rejectedState, box.value, "ACK that loses the CAS to expire -> RejectedState")
        XCTAssertEqual(.expired, stateOf(tracker, msgId(101)))
    }

    func testTwoAuthenticatedAcksRaceFirstWinsSecondIsDuplicate() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let faulting = FaultingDeliveryStore(store)
        let repo = SqliteDeliveryRepository(faulting)
        let (_, priv) = realKeypair()
        let recipient = nodeA()
        let auth = DualAckAuthenticator()
        let tracker = DeliveryTracker(repo: repo, authenticator: auth)
        let mid = msgId(102)
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipient)
        XCTAssertEqual(.applied, tracker.markHandedToRelay(mid))
        plantHeld(store, mid)
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipient, routingTag: routingTag)
        let exp1 = expectation(description: "ack1")
        let exp2 = expectation(description: "ack2")
        let box1 = ResultBox(), box2 = ResultBox()
        DispatchQueue.global().async { box1.value = tracker.acknowledge(mid, ack); exp1.fulfill() }
        DispatchQueue.global().async { box2.value = tracker.acknowledge(mid, ack); exp2.fulfill() }
        // Wait for BOTH to reach verify (the 2-party barrier), then release both --
        // one wins the CAS (.applied), the other gets a 0-row same-binding
        // ACKNOWLEDGED (.duplicateAuthenticatedAck).
        auth.arrived.wait(); auth.arrived.wait()
        auth.release.signal(); auth.release.signal()
        wait(for: [exp1, exp2], timeout: 5)
        let applied = (box1.value == .applied ? 1 : 0) + (box2.value == .applied ? 1 : 0)
        let duplicate = (box1.value == .duplicateAuthenticatedAck ? 1 : 0)
                      + (box2.value == .duplicateAuthenticatedAck ? 1 : 0)
        XCTAssertEqual(applied, 1, "exactly one ACK wins the CAS")
        XCTAssertEqual(duplicate, 1, "the other is a DuplicateAuthenticatedAck")
        XCTAssertEqual(.acknowledgedByRecipient, stateOf(tracker, mid))
    }

    func testOldAliceAckVersusBobRebindIsUnknownMessage() throws {
        // Alice's old ACK (bound to Alice) races a clear + re-enqueue to Bob. The
        // re-bound row has expected_recipient=Bob; Alice's ACK matches 0 rows and
        // re-reads a DIFFERENT binding -> UnknownMessage (an old ACK must never
        // bind to a re-bound row).
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let faulting = FaultingDeliveryStore(store)
        let repo = SqliteDeliveryRepository(faulting)
        let (_, privA) = realKeypair()
        let alice = nodeA(), bob = nodeB()
        let auth = BlockingAckAuthenticator(result: true)
        let tracker = DeliveryTracker(repo: repo, authenticator: auth)
        let mid = msgId(103)
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: alice)
        XCTAssertEqual(.applied, tracker.markHandedToRelay(mid))
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                     recipientNodeId: alice, routingTag: routingTag)
        let exp = expectation(description: "alice ack")
        let box = ResultBox()
        DispatchQueue.global().async { box.value = tracker.acknowledge(mid, ack); exp.fulfill() }
        auth.reached.wait()
        // While Alice's ACK is blocked, the row is cleared + re-bound to Bob.
        XCTAssertEqual(ClearResult.cleared, tracker.forget(mid))
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: bob))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))
        auth.release.signal()
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(AckResult.unknownMessage, box.value,
                       "Alice's old ACK must not bind the re-bound-to-Bob row")
        XCTAssertEqual(.handedToRelay, stateOf(tracker, mid))
    }

    func testAckVersusStorageFailure() throws {
        // The ACK is blocked in verify; while blocked, the store is faulted so the
        // acknowledgeBoundAndRetire CAS throws -> StorageFailure.
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let faulting = FaultingDeliveryStore(store)
        let repo = SqliteDeliveryRepository(faulting)
        let (_, priv) = realKeypair()
        let recipient = nodeA()
        let auth = BlockingAckAuthenticator(result: true)
        let tracker = DeliveryTracker(repo: repo, authenticator: auth)
        let mid = msgId(104)
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipient)
        XCTAssertEqual(.applied, tracker.markHandedToRelay(mid))
        plantHeld(store, mid)
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipient, routingTag: routingTag)
        let exp = expectation(description: "ack")
        let box = ResultBox()
        DispatchQueue.global().async { box.value = tracker.acknowledge(mid, ack); exp.fulfill() }
        auth.reached.wait()
        faulting.faultAtomicAcknowledgeAndRetire = true // the CAS will throw
        auth.release.signal()
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(AckResult.storageFailure, box.value, "CAS exec failure during ACK -> StorageFailure")
    }

    func testCancelVersusExpireOneWinsOtherRejectedOrIdempotent() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(105)
        plantHeld(store, mid)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        XCTAssertEqual(.applied, j.transition(mid, .expire))
        // expire won; cancel on an EXPIRED row -> RejectedState.
        XCTAssertEqual(.rejectedState, j.transition(mid, .cancel))
        XCTAssertEqual(.alreadyInTarget, j.transition(mid, .expire), "re-expire idempotent")
    }

    func testMarkHandedVersusCancelBothOrders() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        // HANDED -> cancel is in validFroms {queued,handed} -> .applied (cancel can
        // recall a handed-but-unacked message).
        let mid = msgId(106)
        plantHeld(store, mid)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        XCTAssertEqual(.applied, j.transition(mid, .markHanded))
        XCTAssertEqual(.applied, j.transition(mid, .cancel), "cancel from HANDED is valid -> Applied")
        XCTAssertEqual(.cancelledLocally, found(j, mid).state)
        // CANCELLED -> markHanded is rejected (validFroms {queued} only).
        let mid2 = msgId(107)
        plantHeld(store, mid2)
        _ = j.enqueue(mid2, ackMode: .singleRecipient, expectedRecipient: nodeA())
        XCTAssertEqual(.applied, j.transition(mid2, .cancel))
        XCTAssertEqual(.rejectedState, j.transition(mid2, .markHanded), "markHanded on CANCELLED is rejected")
        XCTAssertEqual(.cancelledLocally, found(j, mid2).state)
    }

    // C6.4-L: the two tests above pin the post-race TRUTH-TABLE sequentially. The
    // spec also requires genuine transition-vs-transition CONCURRENCY (controlled
    // synchronization, not a probabilistic race). transition has no authenticator
    // seam to open a window (unlike the ACK races), so the coordination is a start
    // barrier: both background threads wait on `start`, the test releases both, and
    // each calls `transition` on the SAME queued row. SQLite (SQLITE_OPEN_FULLMUTEX)
    // serializes the two guarded UPDATEs, and the CAS predicate -- NOT thread timing
    // -- decides the outcome. The assertions hold for EVERY legal interleaving, so a
    // regression that made a transition non-atomic would break them. This is the
    // deterministic C6.4-L transition race.

    /// C6.4-L concurrent: cancel vs expire from QUEUED. Both validFroms are
    /// {queued, handed} but the row starts QUEUED, so the FIRST UPDATE advances
    /// the state to a terminal (expired OR cancelled) that is NOT in the other's
    /// validFroms -> exactly one `.applied` + one `.rejectedState`, always. The CAS
    /// predicate decides the race; the winner is order-dependent but the OUTCOME
    /// SET is deterministic.
    func testCancelVersusExpireConcurrentCasDecidesOneWinsOtherRejected() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(108)
        plantHeld(store, mid)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        let start = DispatchSemaphore(value: 0)
        let expA = expectation(description: "expire"), expB = expectation(description: "cancel")
        let boxA = TransitionResultBox(), boxB = TransitionResultBox()
        DispatchQueue.global().async { start.wait(); boxA.value = j.transition(mid, .expire); expA.fulfill() }
        DispatchQueue.global().async { start.wait(); boxB.value = j.transition(mid, .cancel); expB.fulfill() }
        start.signal(); start.signal() // release both ~simultaneously
        wait(for: [expA, expB], timeout: 5)
        let applied = (boxA.value == .applied ? 1 : 0) + (boxB.value == .applied ? 1 : 0)
        let rejected = (boxA.value == .rejectedState ? 1 : 0) + (boxB.value == .rejectedState ? 1 : 0)
        XCTAssertEqual(applied, 1, "exactly one transition wins the CAS -> Applied")
        XCTAssertEqual(rejected, 1, "the loser's predicate no longer matches -> RejectedState")
        let final = found(j, mid).state
        XCTAssertTrue(final == .expired || final == .cancelledLocally,
                      "final is a legal terminal state decided by the CAS, not a torn state")
    }

    /// C6.4-L concurrent: markHanded vs cancel from QUEUED. These are NOT mutually
    /// exclusive (cancel's validFroms {queued, handed} includes markHanded's target
    /// `handed`), so cancel ALWAYS prevails: if markHanded wins it advances to handed
    /// (cancel then applies handed->cancelled); if cancel wins, markHanded is
    /// rejected (cancelled not in {queued}). Final state is ALWAYS cancelledLocally.
    /// The invariant -- final == cancelledLocally, at least one Applied, at most one
    /// RejectedState -- holds for every interleaving, so a non-atomic regression
    /// (torn state or both losing) is caught.
    func testMarkHandedVersusCancelConcurrentAlwaysEndsCancelled() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(109)
        plantHeld(store, mid)
        _ = j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        let start = DispatchSemaphore(value: 0)
        let expA = expectation(description: "markHanded"), expB = expectation(description: "cancel")
        let boxA = TransitionResultBox(), boxB = TransitionResultBox()
        DispatchQueue.global().async { start.wait(); boxA.value = j.transition(mid, .markHanded); expA.fulfill() }
        DispatchQueue.global().async { start.wait(); boxB.value = j.transition(mid, .cancel); expB.fulfill() }
        start.signal(); start.signal()
        wait(for: [expA, expB], timeout: 5)
        let applied = (boxA.value == .applied ? 1 : 0) + (boxB.value == .applied ? 1 : 0)
        let rejected = (boxA.value == .rejectedState ? 1 : 0) + (boxB.value == .rejectedState ? 1 : 0)
        XCTAssertGreaterThanOrEqual(applied, 1, "at least one transition applies")
        XCTAssertLessThanOrEqual(rejected, 1, "at most one rejected -- the CAS never tears (both never lose)")
        XCTAssertEqual(found(j, mid).state, .cancelledLocally,
                      "cancel always prevails (validFroms ⊇ markHanded target); final is consistent")
    }

    // MARK: - C6.4-M: mutation controls (prove each CAS WHERE predicate is load-bearing)

    func testStateGuardOffLetsAckOverwriteCancelledRow() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let strong = SqliteDeliveryRepository(store) // all guards on
        let mid = msgId(200)
        _ = strong.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        plantHeld(store, mid)
        XCTAssertEqual(.applied, strong.transition(mid, .cancel)) // CANCELLED
        plantHeld(store, mid)
        // Weaken only the state guard: the ACK CAS drops `state IN (queued,handed)`,
        // so it matches the CANCELLED row -> .applied (WRONG -- an ACK overwrote a
        // CANCELLED row; the guard is load-bearing).
        let weak = newRepo(store, stateGuard: false)
        XCTAssertEqual(AckResult.applied, weak.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA()),
                       "without the state guard, an ACK overwrites a CANCELLED row (guard is load-bearing)")
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame deleted on ACK retirement")
        // A SEPARATE cancelled row: the all-guards-on repo correctly rejects.
        let mid2 = msgId(201)
        _ = strong.enqueue(mid2, ackMode: .singleRecipient, expectedRecipient: nodeA())
        plantHeld(store, mid2)
        XCTAssertEqual(.applied, strong.transition(mid2, .cancel))
        plantHeld(store, mid2)
        XCTAssertEqual(AckResult.rejectedState, strong.acknowledgeBoundAndRetire(mid2, expectedRecipient: nodeA()),
                       "with all guards on, an ACK on a CANCELLED row is RejectedState")
        XCTAssertTrue(store.allHeldMsgIds().contains(mid2), "held frame retained on rejection")
    }

    func testRecipientGuardOffLetsAliceAckBindBobRow() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let strong = SqliteDeliveryRepository(store)
        let mid = msgId(202)
        _ = strong.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()) // Alice
        plantHeld(store, mid)
        _ = strong.transition(mid, .markHanded)
        // Weaken the recipient guard: the ACK CAS matches on msg_id + mode + state
        // only, ignoring expected_recipient -> Bob's ACK matches Alice's row -> .applied
        // (WRONG -- Bob forged an ACK for Alice's message; the guard is load-bearing).
        let weak = newRepo(store, recipientGuard: false)
        XCTAssertEqual(AckResult.applied, weak.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeB()),
                       "without the recipient guard, Bob's ACK binds Alice's row (guard is load-bearing)")
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame deleted on ACK retirement")
        // A SEPARATE row: the all-guards-on repo correctly rejects Bob's ACK with
        // UnknownMessage (recipient mismatch via 0-row CAS re-read).
        let mid2 = msgId(203)
        _ = strong.enqueue(mid2, ackMode: .singleRecipient, expectedRecipient: nodeA())
        plantHeld(store, mid2)
        _ = strong.transition(mid2, .markHanded)
        XCTAssertEqual(AckResult.unknownMessage,
                       strong.acknowledgeBoundAndRetire(mid2, expectedRecipient: nodeB()),
                       "with all guards on, Bob's ACK on Alice's row is UnknownMessage")
        XCTAssertTrue(store.allHeldMsgIds().contains(mid2), "held frame retained on rejection")
    }

    func testModeGuardOffLetsAckLandOnNoneModeRow() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let strong = SqliteDeliveryRepository(store)
        let mid = msgId(204)
        _ = strong.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        plantHeld(store, mid)
        XCTAssertEqual(.applied, strong.transition(mid, .markHanded))
        // Corrupt the row to ack_mode=0 (NONE) + recipient (violates the binding
        // CHECK; planted via ignore_check_constraints). With the mode guard ON, the
        // `ack_mode = SINGLE_RECIPIENT` predicate misses it -> 0-row -> re-read ->
        // corrupt (binding inconsistent: NONE + recipient) -> .corrupt.
        try plantCorruptBinding(store, mid, nodeA())
        XCTAssertEqual(AckResult.corrupt, strong.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA()),
                       "with mode guard on, the NONE-mode row is rejected (corrupt)")
        // Weaken only the mode guard: the ACK CAS drops `ack_mode = SINGLE_RECIPIENT`,
        // so it matches the NONE-mode row (state is still HANDED -- the strong ACK
        // above did not mutate it; recipient matches) -> .applied (WRONG -- an ACK
        // landed on a NONE-mode row; the guard is load-bearing).
        let weak = newRepo(store, modeGuard: false)
        XCTAssertEqual(AckResult.applied, weak.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA()),
                       "without the mode guard, an ACK lands on a NONE-mode row (guard is load-bearing)")
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame deleted on ACK retirement")
        // C6.4-M symmetry: a SEPARATE clean SINGLE_RECIPIENT HANDED row -> the
        // all-guards-on repo ACKs it normally (.applied), the happy path the mode
        // guard protects.
        let midClean = msgId(207)
        _ = strong.enqueue(midClean, ackMode: .singleRecipient, expectedRecipient: nodeA())
        plantHeld(store, midClean)
        XCTAssertEqual(.applied, strong.transition(midClean, .markHanded))
        XCTAssertEqual(AckResult.applied, strong.acknowledgeBoundAndRetire(midClean, expectedRecipient: nodeA()),
                       "with all guards on, a clean SINGLE_RECIPIENT HANDED row ACKs (happy path)")
    }

    func testTransitionStateGuardOffLetsCancelOverwriteAcknowledged() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let strong = SqliteDeliveryRepository(store)
        let mid = msgId(205)
        _ = strong.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        plantHeld(store, mid)
        XCTAssertEqual(AckResult.applied, strong.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA())) // ACKNOWLEDGED
        plantHeld(store, mid)
        // Weaken the transition state guard: cancel's `state IN (queued,handed)`
        // predicate drops, so cancel matches the ACKNOWLEDGED row -> .applied (WRONG
        // -- cancel overwrote an ACKNOWLEDGED row; the guard is load-bearing).
        let weak = newRepo(store, stateGuard: false)
        XCTAssertEqual(TransitionResult.applied, weak.transition(mid, .cancel),
                       "without the transition state guard, cancel overwrites ACKNOWLEDGED (guard is load-bearing)")
        // A SEPARATE acknowledged row: the all-guards-on repo correctly rejects.
        let mid2 = msgId(206)
        _ = strong.enqueue(mid2, ackMode: .singleRecipient, expectedRecipient: nodeA())
        plantHeld(store, mid2)
        XCTAssertEqual(AckResult.applied, strong.acknowledgeBoundAndRetire(mid2, expectedRecipient: nodeA()))
        plantHeld(store, mid2)
        XCTAssertEqual(TransitionResult.rejectedState, strong.transition(mid2, .cancel),
                       "with all guards on, cancel on an ACKNOWLEDGED row is RejectedState")
    }

    func testSkipHeldRetirementLeavesSplitStateProvingAtomicRetirementIsLoadBearing() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let strong = SqliteDeliveryRepository(store)
        let weak = newRepo(store, skipHeldRetirement: true)

        let mid = msgId(208)
        _ = strong.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        plantHeld(store, mid)
        _ = strong.transition(mid, .markHanded)

        // Mutant ACK succeeds at updating delivery_state but SKIPS held deletion
        XCTAssertEqual(AckResult.applied, weak.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA()))
        XCTAssertEqual(.acknowledgedByRecipient, found(strong, mid).state)
        XCTAssertTrue(store.allHeldMsgIds().contains(mid), "MUTANT leaves split state: delivery ACKNOWLEDGED but held frame STILL EXISTS")

        // In contrast, production repository atomically retires held frame
        let mid2 = msgId(209)
        _ = strong.enqueue(mid2, ackMode: .singleRecipient, expectedRecipient: nodeA())
        plantHeld(store, mid2)
        _ = strong.transition(mid2, .markHanded)

        XCTAssertEqual(AckResult.applied, strong.acknowledgeBoundAndRetire(mid2, expectedRecipient: nodeA()))
        XCTAssertEqual(.acknowledgedByRecipient, found(strong, mid2).state)
        XCTAssertFalse(store.allHeldMsgIds().contains(mid2), "production atomically deletes held frame")
    }

    // MARK: - C6.4-E: PRAGMA user_version schema versioning

    func testPragmaUserVersionMigrationDropsAndRecreatesOnStaleVersion() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        // boot 1: current schema, stamp user_version=6, insert a row.
        var s1: SqliteMessageStore? = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        var r1: SqliteDeliveryRepository? = SqliteDeliveryRepository(s1!)
        let mid = msgId(70)
        XCTAssertEqual(EnqueueResult.created, r1!.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(.queuedDurably, found(r1!, mid).state)
        // Force the file's user_version down to 4 (simulate a stale dev file from a
        // prior schema revision -- pre-C6.4 CHECKs).
        try s1!.execRawSql("PRAGMA user_version = 4")
        r1 = nil; s1 = nil // close + flush
        // boot 2: current code sees user_version 4 < 6 -> drop+recreate -> stamp 6.
        let s2 = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let r2 = SqliteDeliveryRepository(s2)
        // The row was dropped by the destructive migration.
        XCTAssertEqual(DeliveryLookup.notFound, r2.get(mid), "stale-version migration drops the table")
        // The new state CHECK is present: a state=0 plant WITHOUT
        // ignore_check_constraints is rejected (0 rows changed), proving the
        // recreated table has the C6.4-C CHECK.
        _ = r2.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        let changed = s2.execRawUpdate("UPDATE delivery_state SET state = 0 WHERE msg_id = ?", [mid])
        XCTAssertEqual(0, changed, "new state CHECK rejects state=0 without ignore_check_constraints")
        XCTAssertEqual(.queuedDurably, found(r2, mid).state, "row unchanged after rejected plant")
    }

    // MARK: - C6.4.1-B/C/D/E: fail-closed schema version + migration + fingerprint

    /// C6.4.1-C: a FUTURE user_version (> current) is rejected fail-closed and
    /// left UNTOUCHED. The store must not silently downgrade a schema this build
    /// cannot read; on reopen the handle is closed (no half-migrated handle) and
    /// every primitive throws handleMissing.
    func testFutureUserVersionIsRejectedFailClosedAndUntouched() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        // boot 1: current schema, stamp user_version=6, insert a row.
        var s1: SqliteMessageStore? = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let mid = msgId(71)
        _ = SqliteDeliveryRepository(s1!).enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        // Simulate a file written by a FUTURE build (user_version 999).
        try s1!.execRawSql("PRAGMA user_version = 999")
        s1 = nil
        // boot 2: current code sees 999 > 6 -> fail-closed. The store is unusable
        // (handle nil); a delivery primitive throws rather than touching the file.
        let s2 = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        XCTAssertThrowsError(try s2.insertDelivery(mid, stateOrdinal: DeliveryState.queuedDurably.code,
                                                    ackModeOrdinal: AckMode.none.rawValue,
                                                    expectedRecipient: nil),
                             "future-version file must fail-closed, not open")
        // The file is untouched: a raw reopen at the current version would recreate,
        // but we prove fail-closed by confirming the future stamp survived (the
        // store did NOT rewrite user_version down to 6).
        var db: OpaquePointer?
        sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil)
        sqlite3_step(stmt)
        XCTAssertEqual(999, sqlite3_column_int(stmt, 0),
                       "future-version file is left untouched (no silent downgrade)")
        sqlite3_finalize(stmt); sqlite3_close_v2(db)
    }

    /// C6.4.1-E: a file that CLAIMS the current user_version but whose DDL does
    /// NOT match the fingerprint (hand-edited / partially-migrated / downgraded)
    /// is rejected fail-closed on open.
    func testMalformedCurrentVersionSchemaIsRejectedFailClosed() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        // boot 1: current schema (stamps user_version=6).
        var s1: SqliteMessageStore? = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let mid = msgId(72)
        _ = SqliteDeliveryRepository(s1!).enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA())
        // Tamper: drop held_frames and recreate it WITHOUT the msg_id CHECK (a
        // malformed current-version file). user_version stays 6.
        try s1!.execRawSql("DROP TABLE IF EXISTS \(StoreSchema.table)")
        try s1!.execRawSql("CREATE TABLE \(StoreSchema.table) (\(StoreSchema.colMsgId) BLOB PRIMARY KEY, \(StoreSchema.colType) INTEGER)")
        s1 = nil
        // boot 2: user_version == 6 but the held_frames DDL fingerprint does NOT
        // match StoreSchema.createSql -> validateSchema throws -> fail-closed.
        let s2 = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        XCTAssertThrowsError(try s2.insertDelivery(mid, stateOrdinal: DeliveryState.queuedDurably.code,
                                                    ackModeOrdinal: AckMode.none.rawValue,
                                                    expectedRecipient: nil),
                             "malformed current-version schema must fail-closed, not open")
    }

    /// C6.4.1-G: a NULL msg_id is rejected by BOTH tables (explicit NOT NULL +
    /// CHECK(length=16)) at the raw-SQL level, and the 16-byte boundary holds
    /// (0/8/15/17/64 rejected, 16 accepted). Defense-in-depth below the wire guard.
    func testMsgIdNullAndLengthBoundaryRejectedByBothTablesRawSql() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        // NULL msg_id rejected on held_frames (NOT NULL + CHECK). A NULL cannot be
        // bound as a BLOB, so use the literal-NULL execRawSql path and assert it
        // throws (sqlite3_exec returns non-OK on the constraint).
        XCTAssertThrowsError(try store.execRawSql(
            "INSERT INTO \(StoreSchema.table) (\(StoreSchema.colMsgId), \(StoreSchema.colType)) VALUES (NULL, 1)"),
            "NULL msg_id must be rejected by held_frames")
        XCTAssertThrowsError(try store.execRawSql(
            "INSERT INTO \(StoreSchema.deliveryTable) (\(StoreSchema.colDMsgId), \(StoreSchema.colDState), \(StoreSchema.colDAckMode)) VALUES (NULL, 1, 0)"),
            "NULL msg_id must be rejected by delivery_state")
        // Non-16-byte msg_id rejected on BOTH tables for every boundary size.
        // execRawUpdate binds a BLOB and returns sqlite3_changes -- 0 when the
        // CHECK(length=16) rejects the write (sqlite3_step -> SQLITE_CONSTRAINT).
        for n in [0, 8, 15, 17, 64] {
            let bad = Data(repeating: 0xAA, count: n)
            XCTAssertEqual(0, store.execRawUpdate(
                "INSERT INTO \(StoreSchema.table) (\(StoreSchema.colMsgId), \(StoreSchema.colType)) VALUES (?, 1)", [bad]),
                "held_frames must reject \(n)-byte msg_id")
            XCTAssertEqual(0, store.execRawUpdate(
                "INSERT INTO \(StoreSchema.deliveryTable) (\(StoreSchema.colDMsgId), \(StoreSchema.colDState), \(StoreSchema.colDAckMode)) VALUES (?, 1, 0)", [bad]),
                "delivery_state must reject \(n)-byte msg_id")
        }
        // A 16-byte msg_id is accepted on BOTH tables (sanity).
        XCTAssertEqual(1, store.execRawUpdate(
            "INSERT INTO \(StoreSchema.table) (\(StoreSchema.colMsgId), \(StoreSchema.colType)) VALUES (?, 1)", [msgId(73)]),
            "held_frames accepts a 16-byte msg_id")
        let ok = msgId(74)
        XCTAssertEqual(EnqueueResult.created, j.enqueue(ok, ackMode: .singleRecipient, expectedRecipient: nodeA()),
                       "delivery_state accepts a 16-byte msg_id")
        XCTAssertEqual(.queuedDurably, found(j, ok).state)
    }

    // MARK: - C1/C2 integration + fail-closed production composition

    func testDeliveryTrackerOverSqliteDeliveryRepositoryBindsAckToDurableExpectedRecipient() throws {
        let (j, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let (pubA, privA) = realKeypair()
        let (pubB, privB) = realKeypair()
        let resolver = TwoRecipientResolver(nodeA(), pubA, nodeB(), pubB)
        let tracker = DeliveryTracker(repo: j, authenticator: Ed25519AckAuthenticator(resolver: resolver))
        let mid = msgId(30)
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))
        plantHeld(store, mid)
        let ackA = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                      recipientNodeId: nodeA(), routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker.acknowledge(mid, ackA),
                       "ACK from the bound recipient A must verify over the durable repository")
        XCTAssertEqual(.acknowledgedByRecipient, stateOf(tracker, mid))
        let mid2 = msgId(31)
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid2, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        tracker.markHandedToRelay(mid2)
        let ackB = try AckFrame.build(msgId: mid2, recipientSigningPrivKey: privB,
                                      recipientNodeId: nodeB(), routingTag: routingTag)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid2, ackB),
                       "ACK from a valid but unintended recipient must not verify over the durable repository")
        XCTAssertEqual(.handedToRelay, stateOf(tracker, mid2))
    }

    func testNoneModeMessageOverSqliteIsNotAckEligible() throws {
        let (j, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let tracker = DeliveryTracker(repo: j, authenticator: NeverInvokeAuthenticator())
        let mid = msgId(32)
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .none, expectedRecipient: nil))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))
        XCTAssertEqual(AckResult.notAckEligible, tracker.acknowledge(mid, rawAck(mid)),
                       "a NONE-mode message is not ACK-eligible; the authenticator is not invoked")
        XCTAssertEqual(.handedToRelay, stateOf(tracker, mid))
    }

    func testProductionCompositionIsFailClosedUnderUnresolvedResolver() throws {
        let (repo, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let tracker = DeliveryTracker(repo: repo,
                                      authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver()))
        let (_, priv) = realKeypair()
        let recipient = Data(repeating: 0x07, count: 16)
        let mid = msgId(40)
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipient))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipient, routingTag: routingTag)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid, ack),
                       "unresolved production resolver must reject every ACK -- no delivery claimed without a bound key")
        XCTAssertEqual(.handedToRelay, stateOf(tracker, mid))
        XCTAssertEqual(found(repo, mid).expectedRecipientNodeId ?? Data(), recipient,
                       "the durable expected recipient is preserved for when M2-link wires a real resolver")
    }

    // ==================================================================
    // C6.7.1 Logical Message Identity & Delivery State Collision Tests
    // ==================================================================

    func testCase1AliceAndBobConcurrentSendsCoexistAsDistinctRows() throws {
        let (repo, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }

        let sender = Data(repeating: 0x01, count: 16)
        let timestamp: Int64 = 1700000000
        let plaintext = Data("medical supply update".utf8)

        let nonceA = Data(repeating: 0x11, count: 16)
        let nonceB = Data(repeating: 0x22, count: 16)
        let aliceNode = Data(repeating: 0xAA, count: 16)
        let bobNode = Data(repeating: 0xBB, count: 16)

        let msgIdA = MessageId.derive(senderNodeId: sender, createdAtEpochSeconds: timestamp, messageNonce: nonceA, plaintext: plaintext)
        let msgIdB = MessageId.derive(senderNodeId: sender, createdAtEpochSeconds: timestamp, messageNonce: nonceB, plaintext: plaintext)

        XCTAssertNotEqual(msgIdA, msgIdB)

        XCTAssertEqual(EnqueueResult.created, repo.enqueue(msgIdA, ackMode: .singleRecipient, expectedRecipient: aliceNode))
        XCTAssertEqual(EnqueueResult.created, repo.enqueue(msgIdB, ackMode: .singleRecipient, expectedRecipient: bobNode))

        let recA = found(repo, msgIdA)
        let recB = found(repo, msgIdB)

        XCTAssertEqual(recA.expectedRecipientNodeId, aliceNode)
        XCTAssertEqual(recB.expectedRecipientNodeId, bobNode)
        XCTAssertEqual(recA.state, .queuedDurably)
        XCTAssertEqual(recB.state, .queuedDurably)
    }

    func testCase2TwoDistinctLogicalSendsToSameRecipientCoexist() throws {
        let (repo, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }

        let sender = Data(repeating: 0x01, count: 16)
        let timestamp: Int64 = 1700000000
        let plaintext = Data("repeated status report".utf8)
        let recipientAlice = Data(repeating: 0xAA, count: 16)

        let nonce1 = Data(repeating: 0x33, count: 16)
        let nonce2 = Data(repeating: 0x44, count: 16)

        let msgId1 = MessageId.derive(senderNodeId: sender, createdAtEpochSeconds: timestamp, messageNonce: nonce1, plaintext: plaintext)
        let msgId2 = MessageId.derive(senderNodeId: sender, createdAtEpochSeconds: timestamp, messageNonce: nonce2, plaintext: plaintext)

        XCTAssertNotEqual(msgId1, msgId2)

        XCTAssertEqual(EnqueueResult.created, repo.enqueue(msgId1, ackMode: .singleRecipient, expectedRecipient: recipientAlice))
        XCTAssertEqual(EnqueueResult.created, repo.enqueue(msgId2, ackMode: .singleRecipient, expectedRecipient: recipientAlice))

        let rec1 = found(repo, msgId1)
        let rec2 = found(repo, msgId2)

        XCTAssertEqual(rec1.expectedRecipientNodeId, recipientAlice)
        XCTAssertEqual(rec2.expectedRecipientNodeId, recipientAlice)
    }

    func testCase3RetryWithSameLogicalIdentityIsIdempotent() throws {
        let (repo, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }

        let sender = Data(repeating: 0x01, count: 16)
        let timestamp: Int64 = 1700000000
        let plaintext = Data("idempotent retry message".utf8)
        let nonce = Data(repeating: 0x55, count: 16)
        let recipient = Data(repeating: 0xCC, count: 16)

        let msgIdOriginal = MessageId.derive(senderNodeId: sender, createdAtEpochSeconds: timestamp, messageNonce: nonce, plaintext: plaintext)
        let msgIdRetry = MessageId.derive(senderNodeId: sender, createdAtEpochSeconds: timestamp, messageNonce: nonce, plaintext: plaintext)

        XCTAssertEqual(msgIdOriginal, msgIdRetry)

        XCTAssertEqual(EnqueueResult.created, repo.enqueue(msgIdOriginal, ackMode: .singleRecipient, expectedRecipient: recipient))
        XCTAssertEqual(EnqueueResult.alreadyQueuedSameBinding, repo.enqueue(msgIdRetry, ackMode: .singleRecipient, expectedRecipient: recipient))

        let rec = found(repo, msgIdOriginal)
        XCTAssertEqual(rec.state, .queuedDurably)
        XCTAssertEqual(rec.expectedRecipientNodeId, recipient)
    }

    func testCase4AckIsolationBetweenMessages() throws {
        let (repo, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }

        let (pubA, privA) = realKeypair()
        let (pubB, privB) = realKeypair()
        let resolver = TwoRecipientResolver(nodeA(), pubA, nodeB(), pubB)
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: resolver))

        let sender = Data(repeating: 0x01, count: 16)
        let timestamp: Int64 = 1700000000
        let plaintext = Data("coordinated delivery message".utf8)

        let msgIdA = MessageId.derive(senderNodeId: sender, createdAtEpochSeconds: timestamp, messageNonce: Data(repeating: 0x66, count: 16), plaintext: plaintext)
        let msgIdB = MessageId.derive(senderNodeId: sender, createdAtEpochSeconds: timestamp, messageNonce: Data(repeating: 0x77, count: 16), plaintext: plaintext)

        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(msgIdA, ackMode: AckMode.singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(msgIdB, ackMode: AckMode.singleRecipient, expectedRecipient: nodeB()))

        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(msgIdA))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(msgIdB))

        plantHeld(store, msgIdA)
        let ackA = try AckFrame.build(msgId: msgIdA, recipientSigningPrivKey: privA, recipientNodeId: nodeA(), routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker.acknowledge(msgIdA, ackA))

        XCTAssertEqual(DeliveryState.acknowledgedByRecipient, stateOf(tracker, msgIdA))
        XCTAssertEqual(DeliveryState.handedToRelay, stateOf(tracker, msgIdB))
    }

    // MARK: - C7.4.1: Atomic Authenticated ACK Commit + Held-Frame Retirement Matrix

    func testC741ProductionShapedQueuedC66ToC74Success() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var store: SqliteMessageStore? = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        var repo: SqliteDeliveryRepository? = SqliteDeliveryRepository(store!)
        let (pub, priv) = realKeypair()
        var tracker: DeliveryTracker? = DeliveryTracker(repo: repo!, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pub)))
        let mid = msgId(150)
        let canonicalFrame = directFrame(1, payloadSize: 80, msgIdOverride: mid)

        let enqueueRes = store!.enqueueDirectOutbound(canonicalFrame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1))
        XCTAssertEqual(.created(canonicalFrame), enqueueRes)

        // Before ACK: held row exists, delivery row is QUEUED_DURABLY
        XCTAssertTrue(store!.allHeldMsgIds().contains(mid))
        let dBefore = try store!.readDelivery(mid)
        XCTAssertNotNil(dBefore)
        XCTAssertEqual(DeliveryState.queuedDurably.code, dBefore?.state)
        XCTAssertEqual(AckMode.singleRecipient.rawValue, dBefore?.ackMode)
        XCTAssertEqual(nodeA(), dBefore?.expectedRecipient)
        XCTAssertEqual([canonicalFrame], store!.allHeldOrderedByPriority().filter { $0.msgId == mid })

        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv, recipientNodeId: nodeA(), routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker!.acknowledge(mid, ack))

        // Close & reopen from disk file
        repo = nil; tracker = nil; store = nil
        let store2 = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo2 = SqliteDeliveryRepository(store2)
        let tracker2 = DeliveryTracker(repo: repo2, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pub)))

        // After reopen: delivery state is ACKNOWLEDGED, recipient preserved, held row absent
        let dAfter = try store2.readDelivery(mid)
        XCTAssertNotNil(dAfter)
        XCTAssertEqual(DeliveryState.acknowledgedByRecipient.code, dAfter?.state)
        XCTAssertEqual(AckMode.singleRecipient.rawValue, dAfter?.ackMode)
        XCTAssertEqual(nodeA(), dAfter?.expectedRecipient)
        XCTAssertEqual(DeliveryState.acknowledgedByRecipient, stateOf(tracker2, mid))
        XCTAssertFalse(store2.allHeldMsgIds().contains(mid), "held frame must be absent after ACK retirement")
        XCTAssertEqual([], store2.allHeldOrderedByPriority().filter { $0.msgId == mid })
    }

    func testC741ProductionShapedHandedC66ToC74Success() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var store: SqliteMessageStore? = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        var repo: SqliteDeliveryRepository? = SqliteDeliveryRepository(store!)
        let (pub, priv) = realKeypair()
        var tracker: DeliveryTracker? = DeliveryTracker(repo: repo!, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pub)))
        let mid = msgId(151)
        let canonicalFrame = directFrame(2, payloadSize: 80, msgIdOverride: mid)

        let enqueueRes = store!.enqueueDirectOutbound(canonicalFrame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1))
        XCTAssertEqual(.created(canonicalFrame), enqueueRes)
        XCTAssertEqual(TransitionResult.applied, tracker!.markHandedToRelay(mid))

        // Before ACK: held row exists, delivery row is HANDED_TO_RELAY
        XCTAssertTrue(store!.allHeldMsgIds().contains(mid))
        XCTAssertEqual(DeliveryState.handedToRelay, stateOf(tracker!, mid))

        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv, recipientNodeId: nodeA(), routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker!.acknowledge(mid, ack))

        // Close & reopen from disk file
        repo = nil; tracker = nil; store = nil
        let store2 = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo2 = SqliteDeliveryRepository(store2)
        let tracker2 = DeliveryTracker(repo: repo2, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pub)))

        // After reopen: delivery state is ACKNOWLEDGED, recipient preserved, held row absent
        let dAfter = try store2.readDelivery(mid)
        XCTAssertNotNil(dAfter)
        XCTAssertEqual(DeliveryState.acknowledgedByRecipient.code, dAfter?.state)
        XCTAssertEqual(nodeA(), dAfter?.expectedRecipient)
        XCTAssertEqual(DeliveryState.acknowledgedByRecipient, stateOf(tracker2, mid))
        XCTAssertFalse(store2.allHeldMsgIds().contains(mid), "held frame must be absent after ACK retirement")
    }

    func testC741RejectedAuthenticationHeldRetained() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, _) = realKeypair()
        let (_, privB) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))
        let mid = msgId(152)
        let canonicalFrame = directFrame(3, payloadSize: 80, msgIdOverride: mid)

        XCTAssertEqual(.created(canonicalFrame),
                       store.enqueueDirectOutbound(canonicalFrame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))

        let badAck = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privB, recipientNodeId: nodeA(), routingTag: routingTag)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid, badAck))

        XCTAssertEqual(DeliveryState.handedToRelay, stateOf(tracker, mid))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid), "held frame must be retained on auth rejection")
    }

    func testC741NotAckEligibleNoneModeHeldRetained() throws {
        let (repo, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let tracker = DeliveryTracker(repo: repo, authenticator: NeverInvokeAuthenticator())
        let mid = msgId(153)

        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .none, expectedRecipient: nil))
        plantHeld(store, mid)
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))

        let dummyAck = rawAck(mid)
        XCTAssertEqual(AckResult.notAckEligible, tracker.acknowledge(mid, dummyAck))

        XCTAssertEqual(DeliveryState.handedToRelay, stateOf(tracker, mid))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid), "held frame must be retained for NONE mode")
    }

    func testC741MissingHeldActiveRowRollbackAndCorrupt() throws {
        let (repo, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let (pub, priv) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pub)))
        let mid = msgId(154)

        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))
        // Note: NO plantHeld -- held frame is missing!

        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv, recipientNodeId: nodeA(), routingTag: routingTag)
        XCTAssertEqual(AckResult.corrupt, tracker.acknowledge(mid, ack))

        // Transaction rolled back -> state remains HANDED_TO_RELAY
        XCTAssertEqual(DeliveryState.handedToRelay, stateOf(tracker, mid))
    }

    func testC741FaultAfterAckCasBothRestored() throws {
        let (repo, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(155)

        XCTAssertEqual(EnqueueResult.created, repo.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        plantHeld(store, mid)
        XCTAssertEqual(TransitionResult.applied, repo.transition(mid, .markHanded))

        let res = repo.acknowledgeBoundAndRetireWithFault(
            mid,
            expectedRecipient: nodeA(),
            fault: { hook, _ in if hook == "after_ack_cas" { throw FaultError.injected } }
        )
        XCTAssertEqual(AckResult.storageFailure, res)

        // Both restored
        XCTAssertEqual(DeliveryState.handedToRelay, found(repo, mid).state)
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))
    }

    func testC741FaultAfterHeldDeleteBothRestored() throws {
        let (repo, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(156)

        XCTAssertEqual(EnqueueResult.created, repo.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        plantHeld(store, mid)
        XCTAssertEqual(TransitionResult.applied, repo.transition(mid, .markHanded))

        let res = repo.acknowledgeBoundAndRetireWithFault(
            mid,
            expectedRecipient: nodeA(),
            fault: { hook, _ in if hook == "after_held_delete" { throw FaultError.injected } }
        )
        XCTAssertEqual(AckResult.storageFailure, res)

        // Both restored
        XCTAssertEqual(DeliveryState.handedToRelay, found(repo, mid).state)
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))
    }

    func testC741HeldDeleteSqlFailureYieldsStorageFailureAndRollsBack() throws {
        let (repo, faulting, url) = faultingRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(157)

        XCTAssertEqual(EnqueueResult.created, repo.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        faulting.faultAtomicAcknowledgeAndRetire = true

        let res = repo.acknowledgeBoundAndRetire(mid, expectedRecipient: nodeA())
        XCTAssertEqual(AckResult.storageFailure, res)
    }

    func testC741SequentialDuplicateAckShortCircuitsWithoutReAuth() throws {
        let (repo, store, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let (pub, priv) = realKeypair()
        final class CountingAuth: AckAuthenticator {
            let delegate: AckAuthenticator
            var count = 0
            init(delegate: AckAuthenticator) { self.delegate = delegate }
            func verify(originalMsgId: Data, expectedRecipientNodeId: Data, ackFrame: FrameV2) -> Bool {
                count += 1
                return delegate.verify(originalMsgId: originalMsgId, expectedRecipientNodeId: expectedRecipientNodeId, ackFrame: ackFrame)
            }
        }
        let auth = CountingAuth(delegate: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pub)))
        let tracker = DeliveryTracker(repo: repo, authenticator: auth)
        let mid = msgId(158)

        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        plantHeld(store, mid)
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))

        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv, recipientNodeId: nodeA(), routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker.acknowledge(mid, ack))
        XCTAssertEqual(1, auth.count)
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))

        // Second ACK short-circuits without re-invoking authenticator
        let bogusAck = rawAck(mid)
        XCTAssertEqual(AckResult.alreadyAcknowledged, tracker.acknowledge(mid, bogusAck))
        XCTAssertEqual(1, auth.count, "authenticator must not be invoked for already acknowledged record")
        XCTAssertEqual(DeliveryState.acknowledgedByRecipient, stateOf(tracker, mid))
    }

    func testC741DuplicateAuthenticatedRaceOneAppliedOneDuplicate() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let faulting = FaultingDeliveryStore(store)
        let repo = SqliteDeliveryRepository(faulting)
        let (pub, priv) = realKeypair()
        let recipient = nodeA()
        let auth = DualAckAuthenticator()
        let tracker = DeliveryTracker(repo: repo, authenticator: auth)
        let mid = msgId(159)

        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipient))
        plantHeld(store, mid)
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))

        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv, recipientNodeId: recipient, routingTag: routingTag)
        let exp1 = expectation(description: "ack1")
        let exp2 = expectation(description: "ack2")
        let box1 = ResultBox(), box2 = ResultBox()
        DispatchQueue.global().async { box1.value = tracker.acknowledge(mid, ack); exp1.fulfill() }
        DispatchQueue.global().async { box2.value = tracker.acknowledge(mid, ack); exp2.fulfill() }

        auth.arrived.wait(); auth.arrived.wait()
        auth.release.signal(); auth.release.signal()
        wait(for: [exp1, exp2], timeout: 5)

        let applied = (box1.value == .applied ? 1 : 0) + (box2.value == .applied ? 1 : 0)
        let duplicate = (box1.value == .duplicateAuthenticatedAck ? 1 : 0) + (box2.value == .duplicateAuthenticatedAck ? 1 : 0)

        XCTAssertEqual(1, applied, "exactly one ACK wins CAS and applies")
        XCTAssertEqual(1, duplicate, "the racing duplicate gets DuplicateAuthenticatedAck")
        XCTAssertEqual(DeliveryState.acknowledgedByRecipient, stateOf(tracker, mid))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame must be deleted by winner")
    }

    func testC741ProductionEnqueueDirectOutboundAfterAckReturnsRejectedTerminalState() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pub, priv) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pub)))
        let mid = msgId(160)
        let canonicalFrame = directFrame(4, payloadSize: 80, msgIdOverride: mid)

        XCTAssertEqual(.created(canonicalFrame),
                       store.enqueueDirectOutbound(canonicalFrame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))

        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv, recipientNodeId: nodeA(), routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker.acknowledge(mid, ack))
        XCTAssertEqual(DeliveryState.acknowledgedByRecipient, stateOf(tracker, mid))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))

        // Re-enqueue for an ACKNOWLEDGED record fails closed via production enqueueDirectOutbound
        let reEnqueue = store.enqueueDirectOutbound(canonicalFrame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1))
        XCTAssertEqual(OutboundEnqueueResult.rejectedTerminalState, reEnqueue)
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame must remain absent")
        let d = try store.readDelivery(mid)
        XCTAssertNotNil(d)
        XCTAssertEqual(DeliveryState.acknowledgedByRecipient.code, d?.state)
        XCTAssertEqual(nodeA(), d?.expectedRecipient)
    }

    func testC741CapacityReleasedOnAuthenticatedAckIsReusableByNewFrame() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        // maxBytes = 200:
        // Frame A: payload 50 + row overhead 64 = 114 bytes <= 200.
        // Frame B: payload 100 + row overhead 64 = 164 bytes.
        // Together: 114 + 164 = 278 > 200.
        let store = SqliteMessageStore(url: url, maxBytes: 200, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, privA) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))

        let midA = msgId(161)
        let frameA = directFrame(5, payloadSize: 50, msgIdOverride: midA)
        let midB = msgId(162)
        let frameB = directFrame(6, payloadSize: 100, msgIdOverride: midB)

        // 1. Enqueue A succeeds
        XCTAssertEqual(.created(frameA),
                       store.enqueueDirectOutbound(frameA, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(114, store.heldBytes)

        // 2. While A is active (QUEUED_DURABLY), B cannot fit and cannot evict A
        XCTAssertEqual(.rejectedCapacity,
                       store.enqueueDirectOutbound(frameB, expectedRecipient: nodeB(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(114, store.heldBytes)

        // 3. Acknowledge and retire A
        let ackA = try AckFrame.build(msgId: midA, recipientSigningPrivKey: privA, recipientNodeId: nodeA(), routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker.acknowledge(midA, ackA))
        XCTAssertEqual(0, store.heldBytes, "heldBytes must drop to 0 after A is retired")
        XCTAssertFalse(store.allHeldMsgIds().contains(midA))

        // 4. Retry B: now succeeds because A's capacity was released!
        XCTAssertEqual(.created(frameB),
                       store.enqueueDirectOutbound(frameB, expectedRecipient: nodeB(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(164, store.heldBytes)
        XCTAssertTrue(store.allHeldMsgIds().contains(midB))
    }

    // ==================================================================
    // C7.5: Atomic EXPIRE/CANCEL held-frame retirement + relay suppression
    // ==================================================================

    func testC75ProductionQueuedToExpireSuccess() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, _) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))
        let mid = msgId(170)
        let frame = directFrame(1, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.queuedDurably, stateOf(tracker, mid))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        XCTAssertEqual(.applied, tracker.expire(mid))
        XCTAssertEqual(.expired, stateOf(tracker, mid))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame must be deleted on EXPIRE")

        let d = try store.readDelivery(mid)
        XCTAssertNotNil(d)
        XCTAssertEqual(DeliveryState.expired.code, d?.state)
        XCTAssertEqual(nodeA(), d?.expectedRecipient)

        // Reopen verification
        let store2 = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        XCTAssertFalse(store2.allHeldMsgIds().contains(mid), "held frame remains absent across restart")
        let reloaded = try store2.readDelivery(mid)
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(DeliveryState.expired.code, reloaded?.state)
    }

    func testC75ProductionHandedToExpireSuccess() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, _) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))
        let mid = msgId(171)
        let frame = directFrame(1, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, tracker.markHandedToRelay(mid))
        XCTAssertEqual(.handedToRelay, stateOf(tracker, mid))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        XCTAssertEqual(.applied, tracker.expire(mid))
        XCTAssertEqual(.expired, stateOf(tracker, mid))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame must be deleted on EXPIRE from HANDED state")
    }

    func testC75ProductionQueuedToCancelSuccess() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, _) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))
        let mid = msgId(172)
        let frame = directFrame(2, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.queuedDurably, stateOf(tracker, mid))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        XCTAssertEqual(.applied, tracker.cancel(mid))
        XCTAssertEqual(.cancelledLocally, stateOf(tracker, mid))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame must be deleted on CANCEL")

        let d = try store.readDelivery(mid)
        XCTAssertNotNil(d)
        XCTAssertEqual(DeliveryState.cancelledLocally.code, d?.state)
        XCTAssertEqual(nodeA(), d?.expectedRecipient)

        // Reopen verification
        let store2 = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        XCTAssertFalse(store2.allHeldMsgIds().contains(mid), "held frame remains absent across restart")
        let reloaded = try store2.readDelivery(mid)
        XCTAssertNotNil(reloaded)
        XCTAssertEqual(DeliveryState.cancelledLocally.code, reloaded?.state)
    }

    func testC75ProductionHandedToCancelSuccess() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, _) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))
        let mid = msgId(173)
        let frame = directFrame(2, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, tracker.markHandedToRelay(mid))
        XCTAssertEqual(.handedToRelay, stateOf(tracker, mid))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        XCTAssertEqual(.applied, tracker.cancel(mid))
        XCTAssertEqual(.cancelledLocally, stateOf(tracker, mid))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame must be deleted on CANCEL from HANDED state")
    }

    func testC75MarkHandedRetainsHeldFrame() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, _) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))
        let mid = msgId(174)
        let frame = directFrame(3, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, tracker.markHandedToRelay(mid))
        XCTAssertEqual(.handedToRelay, stateOf(tracker, mid))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid), "MARK_HANDED is state-only and must retain held frame for relay carry")
    }

    func testC75MissingHeldActiveRowRollbackAndCorruptOnExpire() throws {
        let (j, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(175)
        let (pubA, _) = realKeypair()
        let tracker = DeliveryTracker(repo: j, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))

        XCTAssertEqual(.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(.queuedDurably, stateOf(tracker, mid))

        XCTAssertEqual(.corrupt, tracker.expire(mid))
        XCTAssertEqual(.queuedDurably, stateOf(tracker, mid), "active delivery state must remain QUEUED_DURABLY after rollback")
    }

    func testC75MissingHeldActiveRowRollbackAndCorruptOnCancel() throws {
        let (j, _, url) = openRepo(); defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(176)
        let (pubA, _) = realKeypair()
        let tracker = DeliveryTracker(repo: j, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))

        XCTAssertEqual(.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(.queuedDurably, stateOf(tracker, mid))

        XCTAssertEqual(.corrupt, tracker.cancel(mid))
        XCTAssertEqual(.queuedDurably, stateOf(tracker, mid), "active delivery state must remain QUEUED_DURABLY after rollback")
    }

    func testC75FaultAfterTerminalCasBothRestoredOnExpire() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let mid = msgId(177)
        let frame = directFrame(4, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        let faultRes = repo.transitionWithFault(mid, .expire) { label, _ in
            if label == "after_terminal_cas" { throw FaultError.injected }
        }
        XCTAssertEqual(TransitionResult.storageFailure, faultRes)

        let d = try store.readDelivery(mid)
        XCTAssertNotNil(d)
        XCTAssertEqual(DeliveryState.queuedDurably.code, d?.state)
        XCTAssertTrue(store.allHeldMsgIds().contains(mid), "held frame must remain intact after rollback")
    }

    func testC75FaultAfterTerminalCasBothRestoredOnCancel() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let mid = msgId(178)
        let frame = directFrame(4, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        let faultRes = repo.transitionWithFault(mid, .cancel) { label, _ in
            if label == "after_terminal_cas" { throw FaultError.injected }
        }
        XCTAssertEqual(TransitionResult.storageFailure, faultRes)

        let d = try store.readDelivery(mid)
        XCTAssertNotNil(d)
        XCTAssertEqual(DeliveryState.queuedDurably.code, d?.state)
        XCTAssertTrue(store.allHeldMsgIds().contains(mid), "held frame must remain intact after rollback")
    }

    func testC75FaultAfterHeldDeleteBothRestoredOnExpire() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let mid = msgId(179)
        let frame = directFrame(5, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        let faultRes = repo.transitionWithFault(mid, .expire) { label, _ in
            if label == "after_terminal_delete" { throw FaultError.injected }
        }
        XCTAssertEqual(TransitionResult.storageFailure, faultRes)

        let d = try store.readDelivery(mid)
        XCTAssertNotNil(d)
        XCTAssertEqual(DeliveryState.queuedDurably.code, d?.state)
        XCTAssertTrue(store.allHeldMsgIds().contains(mid), "held frame must remain intact after rollback")
    }

    func testC75FaultAfterHeldDeleteBothRestoredOnCancel() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let mid = msgId(180)
        let frame = directFrame(5, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        let faultRes = repo.transitionWithFault(mid, .cancel) { label, _ in
            if label == "after_terminal_delete" { throw FaultError.injected }
        }
        XCTAssertEqual(TransitionResult.storageFailure, faultRes)

        let d = try store.readDelivery(mid)
        XCTAssertNotNil(d)
        XCTAssertEqual(DeliveryState.queuedDurably.code, d?.state)
        XCTAssertTrue(store.allHeldMsgIds().contains(mid), "held frame must remain intact after rollback")
    }

    func testC75HeldDeleteSqlFailureYieldsStorageFailureAndRollsBack() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let faulting = FaultingDeliveryStore(store)
        let repo = SqliteDeliveryRepository(faulting)
        let mid = msgId(181)
        let frame = directFrame(6, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        faulting.faultAtomicTransitionAndRetire = true
        XCTAssertEqual(.storageFailure, repo.transition(mid, .expire))

        let d = try store.readDelivery(mid)
        XCTAssertNotNil(d)
        XCTAssertEqual(DeliveryState.queuedDurably.code, d?.state)
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))
    }

    func testC75IdempotentSecondExpireReturnsAlreadyInTargetAndHeldRemainsAbsent() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let mid = msgId(182)
        let frame = directFrame(7, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, repo.transition(mid, .expire))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))

        XCTAssertEqual(.alreadyInTarget, repo.transition(mid, .expire))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame remains absent")
        let d = try store.readDelivery(mid)
        XCTAssertEqual(DeliveryState.expired.code, d?.state)
    }

    func testC75IdempotentSecondCancelReturnsAlreadyInTargetAndHeldRemainsAbsent() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let mid = msgId(183)
        let frame = directFrame(7, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, repo.transition(mid, .cancel))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))

        XCTAssertEqual(.alreadyInTarget, repo.transition(mid, .cancel))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame remains absent")
        let d = try store.readDelivery(mid)
        XCTAssertEqual(DeliveryState.cancelledLocally.code, d?.state)
    }

    func testC75CrossTerminalRejectionExpiredThenCancelReturnsRejectedState() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let mid = msgId(184)
        let frame = directFrame(8, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, repo.transition(mid, .expire))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))

        XCTAssertEqual(.rejectedState, repo.transition(mid, .cancel))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))
        let d = try store.readDelivery(mid)
        XCTAssertEqual(DeliveryState.expired.code, d?.state)
    }

    func testC75CrossTerminalRejectionCancelledThenExpireReturnsRejectedState() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let mid = msgId(185)
        let frame = directFrame(8, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, repo.transition(mid, .cancel))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))

        XCTAssertEqual(.rejectedState, repo.transition(mid, .expire))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))
        let d = try store.readDelivery(mid)
        XCTAssertEqual(DeliveryState.cancelledLocally.code, d?.state)
    }

    func testC75ProductionEnqueueDirectOutboundAfterExpireReturnsRejectedTerminalState() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let mid = msgId(186)
        let frame = directFrame(9, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, repo.transition(mid, .expire))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))

        let reEnqueue = store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1))
        XCTAssertEqual(OutboundEnqueueResult.rejectedTerminalState, reEnqueue)
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame must remain absent after terminal rejection")
    }

    func testC75ProductionEnqueueDirectOutboundAfterCancelReturnsRejectedTerminalState() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let mid = msgId(187)
        let frame = directFrame(9, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, repo.transition(mid, .cancel))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))

        let reEnqueue = store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1))
        XCTAssertEqual(OutboundEnqueueResult.rejectedTerminalState, reEnqueue)
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame must remain absent after terminal rejection")
    }

    func testC75AckVsCancelRaceDeterministicRealSql() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, privA) = realKeypair()
        let auth = BlockingAckAuthenticator(result: true)
        let tracker = DeliveryTracker(repo: repo, authenticator: auth)
        let mid = msgId(188)
        let frame = directFrame(10, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, tracker.markHandedToRelay(mid))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                     recipientNodeId: nodeA(), routingTag: routingTag)
        let exp = expectation(description: "ack")
        let box = ResultBox()
        DispatchQueue.global().async {
            box.value = tracker.acknowledge(mid, ack)
            exp.fulfill()
        }
        auth.reached.wait()
        // Cancel applies while ACK is blocked in verify
        XCTAssertEqual(.applied, tracker.cancel(mid))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame deleted by cancel")

        auth.release.signal()
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(.rejectedState, box.value)
        XCTAssertEqual(.cancelledLocally, stateOf(tracker, mid))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))
    }

    func testC75AckVsExpireRaceDeterministicRealSql() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, privA) = realKeypair()
        let auth = BlockingAckAuthenticator(result: true)
        let tracker = DeliveryTracker(repo: repo, authenticator: auth)
        let mid = msgId(189)
        let frame = directFrame(11, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, tracker.markHandedToRelay(mid))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                     recipientNodeId: nodeA(), routingTag: routingTag)
        let exp = expectation(description: "ack")
        let box = ResultBox()
        DispatchQueue.global().async {
            box.value = tracker.acknowledge(mid, ack)
            exp.fulfill()
        }
        auth.reached.wait()
        // Expire applies while ACK is blocked in verify
        XCTAssertEqual(.applied, tracker.expire(mid))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame deleted by expire")

        auth.release.signal()
        wait(for: [exp], timeout: 5)

        XCTAssertEqual(.rejectedState, box.value)
        XCTAssertEqual(.expired, stateOf(tracker, mid))
        XCTAssertFalse(store.allHeldMsgIds().contains(mid))
    }

    func testC75CancelVsExpireRaceDeterministicRealSql() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let mid = msgId(190)
        let frame = directFrame(12, payloadSize: 64, msgIdOverride: mid)

        XCTAssertEqual(.created(frame),
                       store.enqueueDirectOutbound(frame, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.applied, repo.transition(mid, .markHanded))
        XCTAssertTrue(store.allHeldMsgIds().contains(mid))

        let start = DispatchSemaphore(value: 0)
        let expA = expectation(description: "expire"), expB = expectation(description: "cancel")
        let boxA = TransitionResultBox(), boxB = TransitionResultBox()
        DispatchQueue.global().async { start.wait(); boxA.value = repo.transition(mid, .expire); expA.fulfill() }
        DispatchQueue.global().async { start.wait(); boxB.value = repo.transition(mid, .cancel); expB.fulfill() }
        start.signal(); start.signal()
        wait(for: [expA, expB], timeout: 5)

        let applied = (boxA.value == .applied ? 1 : 0) + (boxB.value == .applied ? 1 : 0)
        let rejected = (boxA.value == .rejectedState ? 1 : 0) + (boxB.value == .rejectedState ? 1 : 0)
        XCTAssertEqual(applied, 1, "exactly one terminal transition applies")
        XCTAssertEqual(rejected, 1, "the loser is rejected with prior state")
        XCTAssertFalse(store.allHeldMsgIds().contains(mid), "held frame must be absent after race")

        let d = try store.readDelivery(mid)
        XCTAssertTrue(d?.state == DeliveryState.expired.code || d?.state == DeliveryState.cancelledLocally.code)
    }

    func testC75AntiEntropyExcludesRetiredTerminalFrameAfterExpireAndCancel() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, _) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))
        let router = Router(selfNodeId: localNode(1))
        router.store = store

        let midExpire = msgId(191)
        let frameExpire = directFrame(13, payloadSize: 64, msgIdOverride: midExpire)
        let midCancel = msgId(192)
        let frameCancel = directFrame(14, payloadSize: 64, msgIdOverride: midCancel)

        // Enqueue both frames
        XCTAssertEqual(.created(frameExpire),
                       store.enqueueDirectOutbound(frameExpire, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(.created(frameCancel),
                       store.enqueueDirectOutbound(frameCancel, expectedRecipient: nodeB(), localOriginNodeId: localNode(1)))

        // Both present in bloom digest before retirement
        let initialBloom = BloomDigest.fromBytes(router.bloomDigest())
        XCTAssertTrue(initialBloom.mightContain(midExpire))
        XCTAssertTrue(initialBloom.mightContain(midCancel))

        // 1. Expire midExpire
        XCTAssertEqual(.applied, tracker.expire(midExpire))
        let bloomAfterExpire = BloomDigest.fromBytes(router.bloomDigest())
        XCTAssertFalse(bloomAfterExpire.mightContain(midExpire), "expired frame must not appear in bloom digest")
        XCTAssertTrue(bloomAfterExpire.mightContain(midCancel))
        XCTAssertFalse(store.allHeldMsgIds().contains(midExpire))

        // 2. Cancel midCancel
        XCTAssertEqual(.applied, tracker.cancel(midCancel))
        let bloomAfterCancel = BloomDigest.fromBytes(router.bloomDigest())
        XCTAssertFalse(bloomAfterCancel.mightContain(midCancel), "cancelled frame must not appear in bloom digest")
        XCTAssertFalse(store.allHeldMsgIds().contains(midCancel))
    }

    func testC75CapacityReleasedOnExpireIsReusableByNewFrame() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 200, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, _) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))

        let midA = msgId(193)
        let frameA = directFrame(15, payloadSize: 50, msgIdOverride: midA)
        let midB = msgId(194)
        let frameB = directFrame(16, payloadSize: 100, msgIdOverride: midB)

        XCTAssertEqual(.created(frameA),
                       store.enqueueDirectOutbound(frameA, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(114, store.heldBytes)

        // Frame B rejected due to capacity
        XCTAssertEqual(.rejectedCapacity,
                       store.enqueueDirectOutbound(frameB, expectedRecipient: nodeB(), localOriginNodeId: localNode(1)))

        // Expire A -> releases capacity
        XCTAssertEqual(.applied, tracker.expire(midA))
        XCTAssertEqual(0, store.heldBytes)
        XCTAssertFalse(store.allHeldMsgIds().contains(midA))

        // B can now enqueue!
        XCTAssertEqual(.created(frameB),
                       store.enqueueDirectOutbound(frameB, expectedRecipient: nodeB(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(164, store.heldBytes)
        XCTAssertTrue(store.allHeldMsgIds().contains(midB))
    }

    func testC75CapacityReleasedOnCancelIsReusableByNewFrame() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 200, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, _) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))

        let midA = msgId(195)
        let frameA = directFrame(17, payloadSize: 50, msgIdOverride: midA)
        let midB = msgId(196)
        let frameB = directFrame(18, payloadSize: 100, msgIdOverride: midB)

        XCTAssertEqual(.created(frameA),
                       store.enqueueDirectOutbound(frameA, expectedRecipient: nodeA(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(114, store.heldBytes)

        // Frame B rejected due to capacity
        XCTAssertEqual(.rejectedCapacity,
                       store.enqueueDirectOutbound(frameB, expectedRecipient: nodeB(), localOriginNodeId: localNode(1)))

        // Cancel A -> releases capacity
        XCTAssertEqual(.applied, tracker.cancel(midA))
        XCTAssertEqual(0, store.heldBytes)
        XCTAssertFalse(store.allHeldMsgIds().contains(midA))

        // B can now enqueue!
        XCTAssertEqual(.created(frameB),
                       store.enqueueDirectOutbound(frameB, expectedRecipient: nodeB(), localOriginNodeId: localNode(1)))
        XCTAssertEqual(164, store.heldBytes)
        XCTAssertTrue(store.allHeldMsgIds().contains(midB))
    }

    func testC75AckModeNoneTerminalRetirementOnExpireAndCancel() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("godstone-d-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SqliteMessageStore(url: url, maxBytes: 4096, fileProtection: .complete)
        let repo = SqliteDeliveryRepository(store)
        let (pubA, _) = realKeypair()
        let tracker = DeliveryTracker(repo: repo, authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(nodeA(), pubA)))

        // Test NONE mode EXPIRE
        let midNoneExp = msgId(197)
        plantHeld(store, midNoneExp)
        XCTAssertEqual(.created, tracker.enqueue(midNoneExp, ackMode: .none, expectedRecipient: nil))
        XCTAssertTrue(store.allHeldMsgIds().contains(midNoneExp))

        XCTAssertEqual(.applied, tracker.expire(midNoneExp))
        XCTAssertEqual(.expired, stateOf(tracker, midNoneExp))
        XCTAssertFalse(store.allHeldMsgIds().contains(midNoneExp), "NONE mode frame must be deleted on EXPIRE")

        // Test NONE mode CANCEL
        let midNoneCancel = msgId(198)
        plantHeld(store, midNoneCancel)
        XCTAssertEqual(.created, tracker.enqueue(midNoneCancel, ackMode: .none, expectedRecipient: nil))
        XCTAssertTrue(store.allHeldMsgIds().contains(midNoneCancel))

        XCTAssertEqual(.applied, tracker.cancel(midNoneCancel))
        XCTAssertEqual(.cancelledLocally, stateOf(tracker, midNoneCancel))
        XCTAssertFalse(store.allHeldMsgIds().contains(midNoneCancel), "NONE mode frame must be deleted on CANCEL")
    }

    // MARK: - helpers

    private func rawAck(_ mid: Data) -> FrameV2 {
        FrameV2(type: .ack, msgId: mid, routingTag: routingTag,
                ttl: 4, hopCount: 0, flags: 0, payload: Data(count: 80))
    }
}