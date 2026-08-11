import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

/// Stage 4C.1 / C6.1; C6.3 -- the production `SqliteDeliveryRepository` over a
/// REAL on-disk SQLite (`SqliteMessageStore`, the same engine the store tests
/// use). The delivery state, ack mode and intended recipient live in ONE row
/// keyed by msg_id; the expected recipient is IMMUTABLE post-creation (there is
/// no recipient-only write). C6.3 folded the C6.1 `DeliveryJournal` plus the
/// enqueue / transition / retire classification into ONE atomic aggregate over
/// that row. Asserts the durability + preservation invariants that make the C2
/// ACK binding trustworthy when the expected recipient comes from durable
/// outbound state:
///   - `enqueue` creates the row (QUEUED_DURABLY + ack mode + recipient); a
///     second enqueue for the same msg_id with the SAME binding is idempotent
///     (`EnqueueResult.alreadyQueuedSameBinding`, no mutation); a second enqueue
///     with a DIFFERENT binding is `EnqueueResult.conflictRecipient` and does
///     NOT mutate the recipient (C6.1: the historical send intent is never
///     overwritten);
///   - `compareAndSet` / `acknowledgeAndRetire` advance ONLY the state column,
///     preserving ack_mode + expected_recipient (the C4 invariant the C2 binding
///     relies on);
///   - the row survives a "reboot" (a fresh store + repository over the same
///     file);
///   - a real `DeliveryTracker` over the real repository binds the ACK to the
///     durable expected recipient (C1/C2 integration over SQLite, not a fake);
///   - the schema CHECK enforces the C6.1 binding invariant at the DB level
///     (pinned via `SqliteMessageStore.insertDelivery`, below the repository's
///     own binding guard, so the DB-level constraint is exercised directly);
///   - C6.5: an unknown persisted state / ack_mode fails closed to
///     `DeliveryLookup.corrupt` (NOT UNAVAILABLE), and a tracker over it rejects
///     every mutation.
///
/// Mirrors `SqliteDeliveryRepositoryTest` on Android one-for-one. One platform
/// difference is documented inline: Android's JDBC engine RAISES
/// `java.sql.SQLException` on a CHECK violation, whereas the iOS sqlite3 C API
/// returns `SQLITE_CONSTRAINT` from `sqlite3_step`, which `insertDelivery` folds
/// to a `false` (0-row) result. Both reject the row -- the test asserts the
/// iOS-honest "no row written" form.
final class SqliteDeliveryRepositoryTests: XCTestCase {

    private func msgId(_ seed: UInt8) -> Data {
        Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ seed) })
    }
    private let routingTag = Data([0, 1, 2, 3])
    private func nodeA() -> Data { Data(repeating: 0x01, count: 16) }
    private func nodeB() -> Data { Data(repeating: 0x02, count: 16) }

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

    /// A fresh on-disk store + repository at a unique temp URL. Returns the
    /// store too so the C6.5 corrupt tests can `execRawUpdate` on the SAME
    /// connection.
    private func openRepo() -> (repo: SqliteDeliveryRepository, store: SqliteMessageStore, url: URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-delivery-\(UUID().uuidString).db")
        let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        return (SqliteDeliveryRepository(store), store, url)
    }

    /// Extract the record from a `.found` lookup (fail the test otherwise).
    private func found(_ j: SqliteDeliveryRepository, _ mid: Data) -> DeliveryRecord {
        if case .found(let rec) = j.get(mid) { return rec }
        XCTFail("expected .found(\(mid))"); return DeliveryRecord(
            msgId: mid, state: .unavailable, ackMode: .none, expectedRecipientNodeId: nil)
    }

    // MARK: - enqueue / get

    func testEnqueueCreatesQueuedDurablyRowWithAckModeAndRecipient() throws {
        let (j, _, url) = openRepo()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(1)
        XCTAssertEqual(DeliveryLookup.notFound, j.get(mid))
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        let rec = found(j, mid)
        XCTAssertEqual(.queuedDurably, rec.state)
        XCTAssertEqual(.singleRecipient, rec.ackMode)
        XCTAssertEqual(rec.expectedRecipientNodeId ?? Data(), nodeA())
    }

    func testNoneModeEnqueueBindsNoRecipient() throws {
        let (j, _, url) = openRepo()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(2)
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .none, expectedRecipient: nil))
        let rec = found(j, mid)
        XCTAssertEqual(.none, rec.ackMode)
        XCTAssertNil(rec.expectedRecipientNodeId)
    }

    func testSecondEnqueueForSameMsgIdIsIdempotentOnSameBindingAndDoesNotMutateRecipient() throws {
        let (j, _, url) = openRepo()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(3)
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        // A second enqueue with the SAME binding is idempotent -- no new row,
        // no mutation.
        XCTAssertEqual(EnqueueResult.alreadyQueuedSameBinding,
                       j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        // A second enqueue with a DIFFERENT recipient (e.g. an attempt to rebind)
        // is ConflictRecipient and MUST NOT overwrite the bound recipient.
        XCTAssertEqual(EnqueueResult.conflictRecipient,
                       j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeB()))
        let rec = found(j, mid)
        XCTAssertEqual(rec.expectedRecipientNodeId ?? Data(), nodeA(),
                       "duplicate enqueue must not mutate the bound recipient")
        XCTAssertEqual(.queuedDurably, rec.state)
    }

    // MARK: - the load-bearing preservation invariant

    func testCompareAndSetAndAcknowledgeAndRetireAdvanceOnlyStateColumnPreservingAckModeAndRecipient() throws {
        // The load-bearing C4 invariant for C2: enqueue binds the expected
        // recipient; later state transitions (HANDED_TO_RELAY, ACKNOWLEDGED)
        // advance only the state column with NO recipient write. If that
        // clobbered the bound recipient, the ACK binding the C2 test relies on
        // would be gone before the ACK arrives.
        let (j, _, url) = openRepo()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(4)
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(TransitionResult.applied,
                       j.compareAndSet(mid, validFroms: [.queuedDurably], target: .handedToRelay))
        XCTAssertEqual(.handedToRelay, found(j, mid).state)
        XCTAssertEqual(found(j, mid).expectedRecipientNodeId ?? Data(), nodeA(),
                       "state-only write must preserve the bound expected recipient")
        XCTAssertEqual(.singleRecipient, found(j, mid).ackMode,
                       "state-only write must preserve the ack mode")
        XCTAssertEqual(AckResult.applied, j.acknowledgeAndRetire(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(.acknowledgedByRecipient, found(j, mid).state)
        XCTAssertEqual(found(j, mid).expectedRecipientNodeId ?? Data(), nodeA(),
                       "ACKNOWLEDGED write must preserve the bound expected recipient")
        // compareAndSet for an unknown msg_id is UnknownMessage.
        XCTAssertEqual(TransitionResult.unknownMessage,
                       j.compareAndSet(msgId(99), validFroms: [.queuedDurably], target: .handedToRelay))
    }

    // MARK: - clear + reboot recovery

    func testClearDropsTheRow() throws {
        let (j, _, url) = openRepo()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(5)
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        j.clear(mid)
        XCTAssertEqual(DeliveryLookup.notFound, j.get(mid))
    }

    func testRebootRecoveryFreshRepositoryOverSameFileRecoversStateAckModeAndRecipient() throws {
        // A "crash" is simulated by dropping the first store (its deinit calls
        // sqlite3_close_v2, which flushes), then reopening the same file with a
        // fresh store + repository and recovering the persisted record.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-delivery-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        // First "boot": enqueue + bind recipient + hand to relay, then "crash".
        var boot1: SqliteDeliveryRepository? = {
            let store = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
            return SqliteDeliveryRepository(store)
        }()
        let mid = msgId(6)
        XCTAssertEqual(EnqueueResult.created, boot1!.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(TransitionResult.applied,
                       boot1!.compareAndSet(mid, validFroms: [.queuedDurably], target: .handedToRelay))
        XCTAssertEqual(.handedToRelay, found(boot1!, mid).state)
        boot1 = nil   // "crash": deinit closes + flushes the SQLite file.

        // Second "boot": a fresh store + repository over the same file recovers
        // the full record -- state, ack mode and the bound expected recipient.
        let store2 = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let boot2 = SqliteDeliveryRepository(store2)
        let rec = found(boot2, mid)
        XCTAssertEqual(.handedToRelay, rec.state, "state recovered after reboot")
        XCTAssertEqual(.singleRecipient, rec.ackMode, "ack mode recovered after reboot")
        XCTAssertEqual(rec.expectedRecipientNodeId ?? Data(), nodeA(),
                       "expected recipient recovered after reboot")
    }

    // MARK: - schema CHECK enforces the C6.1 binding invariant at the DB level

    func testSchemaCheckEnforcesC6_1BindingInvariantAtDbLevel() throws {
        // The repository's `enqueue` guards the C6.1 binding invariant BEFORE
        // it touches the DB (returning `EnqueueResult.corrupt`), so to exercise
        // the DB-level CHECK constraint directly we insert below the repository
        // via `SqliteMessageStore.insertDelivery` -- the SAME primitive
        // `SqliteDeliveryRepository` uses. Platform note: Android's JDBC engine
        // RAISES java.sql.SQLException on a CHECK violation; the iOS sqlite3 C
        // API returns SQLITE_CONSTRAINT from sqlite3_step, which
        // `insertDelivery` folds to a false (0-row) result. Both reject the row
        // -- assert the iOS-honest "no row written" form (insertDelivery ==
        // false AND get == .notFound).
        let (j, store, url) = openRepo()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(7)
        // SINGLE_RECIPIENT with a NULL recipient violates the CHECK -> rejected.
        XCTAssertFalse(store.insertDelivery(mid, stateOrdinal: DeliveryState.queuedDurably.code,
                                            ackModeOrdinal: AckMode.singleRecipient.rawValue,
                                            expectedRecipient: nil),
                       "SINGLE_RECIPIENT + null recipient must violate the CHECK")
        XCTAssertEqual(DeliveryLookup.notFound, j.get(mid), "no row written on CHECK violation")
        // NONE with a recipient also violates the CHECK.
        XCTAssertFalse(store.insertDelivery(mid, stateOrdinal: DeliveryState.queuedDurably.code,
                                            ackModeOrdinal: AckMode.none.rawValue,
                                            expectedRecipient: Data(count: 16)),
                       "NONE + recipient must violate the CHECK")
        // A short (non-16-byte) recipient violates the CHECK for SINGLE_RECIPIENT.
        XCTAssertFalse(store.insertDelivery(mid, stateOrdinal: DeliveryState.queuedDurably.code,
                                            ackModeOrdinal: AckMode.singleRecipient.rawValue,
                                            expectedRecipient: Data(count: 8)),
                       "a short recipient must violate the CHECK")
        XCTAssertEqual(DeliveryLookup.notFound, j.get(mid))
    }

    // MARK: - C6.5: unknown persisted states fail closed (NOT UNAVAILABLE)

    func testUnknownPersistedStateCodeReadsAsCorruptNotUnavailable() throws {
        let (j, store, url) = openRepo()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(8)
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        // Corrupt the state column to an unknown code (999) on the same connection.
        _ = store.execRawUpdate("UPDATE delivery_state SET state = 999 WHERE msg_id = ?", [mid])
        XCTAssertEqual(DeliveryLookup.corrupt, j.get(mid),
                       "an unknown state code must fail closed to Corrupt, NOT UNAVAILABLE")
    }

    func testUnknownAckModeCodeDecodesToNilFailClosed() {
        // C6.5: an unknown persisted ack_mode code must fail closed. The schema
        // CHECK makes an invalid ack_mode UNREACHABLE in the DB -- it rejects any
        // ack_mode outside {0,1} paired with a compatible recipient binding, so
        // `UPDATE ... SET ack_mode = 999` is itself rejected (the row stays
        // valid). The fail-closed guard is therefore the `AckMode.fromCode`
        // decoder, which `SqliteDeliveryRepository.get` consults. This test pins
        // the decoder directly (and guards the Swift pitfall where a bare
        // `.none` return would map AckMode.none to Optional.none / nil).
        XCTAssertNil(AckMode.fromCode(999))
        XCTAssertNil(AckMode.fromCode(-1))
        XCTAssertEqual(AckMode.fromCode(0), .some(AckMode.none))
        XCTAssertEqual(AckMode.fromCode(1), .some(.singleRecipient))
    }

    func testTrackerOverCorruptRecordRejectsEveryMutation() throws {
        let (j, store, url) = openRepo()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(10)
        XCTAssertEqual(EnqueueResult.created, j.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        _ = store.execRawUpdate("UPDATE delivery_state SET state = 999 WHERE msg_id = ?", [mid])
        let tracker = DeliveryTracker(
            repo: j,
            authenticator: Ed25519AckAuthenticator(
                resolver: TwoRecipientResolver(nodeA(), Data(count: 32), nodeB(), Data(count: 32))))
        // A corrupt row does NOT silently become UNAVAILABLE; every seam fails closed.
        XCTAssertEqual(.unavailable, tracker.state(mid), "corrupt reads as UNAVAILABLE at the state seam")
        XCTAssertEqual(EnqueueResult.corrupt, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(AckResult.corrupt, tracker.acknowledge(mid, rawAck(mid)))
        XCTAssertEqual(TransitionResult.corrupt, tracker.markHandedToRelay(mid))
    }

    // MARK: - C1/C2 integration + fail-closed production composition

    func testDeliveryTrackerOverSqliteDeliveryRepositoryBindsAckToDurableExpectedRecipient() throws {
        // C1/C2 integration over the REAL durable store (not a fake). Two valid
        // recipients A and B. A message intended for A is acked by A (.applied)
        // and by B (.rejectedAuthentication) -- because the expected recipient
        // is read from the SQLite repository at acknowledge time, independent of
        // the ACK frame.
        let (j, _, url) = openRepo()
        defer { try? FileManager.default.removeItem(at: url) }
        let (pubA, privA) = realKeypair()
        let (pubB, privB) = realKeypair()
        let resolver = TwoRecipientResolver(nodeA(), pubA, nodeB(), pubB)
        let tracker = DeliveryTracker(repo: j, authenticator: Ed25519AckAuthenticator(resolver: resolver))

        let mid = msgId(30)
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))
        // ACK from A verifies -- the durable expected recipient == nodeA.
        let ackA = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                      recipientNodeId: nodeA(), routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker.acknowledge(mid, ackA),
                       "ACK from the bound recipient A must verify over the durable repository")
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(mid))

        // A second message intended for A: ACK from B must NOT verify.
        let mid2 = msgId(31)
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid2, ackMode: .singleRecipient, expectedRecipient: nodeA()))
        tracker.markHandedToRelay(mid2)
        let ackB = try AckFrame.build(msgId: mid2, recipientSigningPrivKey: privB,
                                      recipientNodeId: nodeB(), routingTag: routingTag)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid2, ackB),
                       "ACK from a valid but unintended recipient must not verify over the durable repository")
        XCTAssertEqual(.handedToRelay, tracker.state(mid2))
    }

    func testProductionCompositionIsFailClosedUnderUnresolvedResolver() throws {
        // C5 production composition recipe (mirrors the iOS composition root):
        // a SqliteDeliveryRepository over a REAL on-disk SqliteMessageStore is
        // the durable record, and an Ed25519AckAuthenticator over the production
        // UnresolvedRecipientKeyResolver rejects every ACK. No delivery is
        // claimed until M2-link binds real keys.
        let (repo, _, url) = openRepo()
        defer { try? FileManager.default.removeItem(at: url) }
        let tracker = DeliveryTracker(repo: repo,
                                      authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver()))
        let (_, priv) = realKeypair()
        let recipient = Data(repeating: 0x07, count: 16)
        let mid = msgId(40)
        // Outbound: enqueue binds the expected recipient + advances to handed.
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipient))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))
        // A real, well-formed ACK signed by the recipient is STILL rejected,
        // because the production resolver resolves no key. State unchanged.
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipient, routingTag: routingTag)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid, ack),
                       "unresolved production resolver must reject every ACK -- no delivery claimed without a bound key")
        XCTAssertEqual(.handedToRelay, tracker.state(mid))
        // The durable expected recipient is preserved (state-only writes do not
        // clobber it), so the binding substrate is intact for when M2-link wires
        // a real resolver -- but until then the tracker is fail-closed.
        XCTAssertEqual(found(repo, mid).expectedRecipientNodeId ?? Data(), recipient)
    }

    // MARK: - helpers

    private func rawAck(_ mid: Data) -> FrameV2 {
        FrameV2(type: .ack, msgId: mid, routingTag: routingTag,
                ttl: 4, hopCount: 0, flags: 0, payload: Data(count: 80))
    }
}