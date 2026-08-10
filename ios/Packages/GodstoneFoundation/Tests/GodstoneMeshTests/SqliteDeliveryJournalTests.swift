import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

/// Stage 4C / C4 -- the production `SqliteDeliveryJournal` over a REAL on-disk
/// SQLite (`SqliteMessageStore`, the same engine the store tests use). Asserts
/// the durability + preservation invariants that make the C2 ACK binding
/// trustworthy when the expected recipient comes from durable outbound state:
///   - a state-only write (handedToRelay / acknowledgedByRecipient) MUST preserve
///     a recipient bound at enqueue -- otherwise the binding the C2 adversarial
///     test relies on would be silently clobbered by every state transition;
///   - a recipient-only write MUST preserve the state;
///   - the row survives a "reboot" (a fresh store + journal over the same file);
///   - a real `DeliveryTracker` over the real journal binds the ACK to the
///     durable expected recipient (C1/C2 integration over SQLite, not a fake).
///
/// Mirrors `SqliteDeliveryJournalTest` on Android one-for-one.
final class SqliteDeliveryJournalTests: XCTestCase {

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

    /// A fresh on-disk store + journal at a unique temp URL.
    private func openJournal() -> (SqliteDeliveryJournal, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-delivery-\(UUID().uuidString).db")
        let store = SqliteMessageStore(url: url, maxBytes: .max,
                                       fileProtection: .complete)
        return (SqliteDeliveryJournal(store), url)
    }

    // MARK: - state read/write

    func testWriteAndReadRecoverTheState() throws {
        let (j, url) = openJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(1)
        XCTAssertEqual(.unavailable, j.read(mid))
        j.write(mid, .queuedDurably)
        XCTAssertEqual(.queuedDurably, j.read(mid))
        j.write(mid, .handedToRelay)
        XCTAssertEqual(.handedToRelay, j.read(mid))
        j.write(mid, .acknowledgedByRecipient)
        XCTAssertEqual(.acknowledgedByRecipient, j.read(mid))
    }

    func testRecordExpectedRecipientAndExpectedRecipientRecoverTheRecipient() throws {
        let (j, url) = openJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(2)
        XCTAssertNil(j.expectedRecipient(mid))
        j.recordExpectedRecipient(mid, nodeA())
        XCTAssertEqual(nodeA(), j.expectedRecipient(mid))
    }

    // MARK: - the load-bearing preservation invariants

    func testStateOnlyWritePreservesBoundExpectedRecipient() throws {
        // The load-bearing C4 invariant for C2: enqueue writes queuedDurably
        // then records the expected recipient. Later state transitions
        // (handedToRelay, acknowledgedByRecipient) call write() with the new
        // state but NO recipient. If that clobbered the bound recipient, the
        // ACK binding the C2 test relies on would be gone before the ACK arrives.
        let (j, url) = openJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(3)
        j.write(mid, .queuedDurably)
        j.recordExpectedRecipient(mid, nodeA())
        XCTAssertEqual(nodeA(), j.expectedRecipient(mid))
        // State advances; the recipient MUST survive.
        j.write(mid, .handedToRelay)
        XCTAssertEqual(.handedToRelay, j.read(mid))
        XCTAssertEqual(nodeA(), j.expectedRecipient(mid),
                       "state-only write must preserve the bound expected recipient")
        j.write(mid, .acknowledgedByRecipient)
        XCTAssertEqual(.acknowledgedByRecipient, j.read(mid))
        XCTAssertEqual(nodeA(), j.expectedRecipient(mid),
                       "acknowledged write must preserve the bound expected recipient")
    }

    func testRecipientOnlyWritePreservesTheState() throws {
        let (j, url) = openJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(4)
        j.write(mid, .queuedDurably)
        j.recordExpectedRecipient(mid, nodeA())
        // Re-bind the recipient (e.g. a re-enqueue); the state MUST survive.
        j.recordExpectedRecipient(mid, nodeB())
        XCTAssertEqual(nodeB(), j.expectedRecipient(mid))
        XCTAssertEqual(.queuedDurably, j.read(mid),
                       "recipient-only write must preserve the state")
        // Clearing the recipient (nil) MUST NOT reset the state.
        j.recordExpectedRecipient(mid, nil)
        XCTAssertNil(j.expectedRecipient(mid))
        XCTAssertEqual(.queuedDurably, j.read(mid),
                       "clearing the recipient must not reset the state")
    }

    // MARK: - clear + reboot recovery

    func testClearDropsTheRow() throws {
        let (j, url) = openJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let mid = msgId(5)
        j.write(mid, .queuedDurably)
        j.recordExpectedRecipient(mid, nodeA())
        j.clear(mid)
        XCTAssertEqual(.unavailable, j.read(mid))
        XCTAssertNil(j.expectedRecipient(mid))
    }

    func testRebootRecoveryFreshJournalOverSameFileRecoversStateAndRecipient() throws {
        // A "crash" is simulated by dropping the first store (its deinit calls
        // sqlite3_close_v2, which flushes), then reopening the same file with a
        // fresh store + journal and recovering the persisted state + recipient.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-delivery-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        // First "boot": queue + bind recipient + hand to relay, then "crash".
        var boot1: SqliteDeliveryJournal? = {
            let store = SqliteMessageStore(url: url, maxBytes: .max,
                                           fileProtection: .complete)
            return SqliteDeliveryJournal(store)
        }()
        let mid = msgId(6)
        boot1!.write(mid, .queuedDurably)
        boot1!.recordExpectedRecipient(mid, nodeA())
        boot1!.write(mid, .handedToRelay)
        XCTAssertEqual(.handedToRelay, boot1!.read(mid))
        XCTAssertEqual(nodeA(), boot1!.expectedRecipient(mid))
        boot1 = nil   // "crash": deinit closes + flushes the SQLite file.

        // Second "boot": a fresh store + journal over the same file recovers.
        let store2 = SqliteMessageStore(url: url, maxBytes: .max,
                                        fileProtection: .complete)
        let boot2 = SqliteDeliveryJournal(store2)
        XCTAssertEqual(.handedToRelay, boot2.read(mid), "state recovered after reboot")
        XCTAssertEqual(nodeA(), boot2.expectedRecipient(mid),
                       "expected recipient recovered after reboot")
    }

    // MARK: - C1/C2 integration over the REAL durable store

    func testDeliveryTrackerOverSqliteDeliveryJournalBindsAckToDurableExpectedRecipient() throws {
        // C1/C2 integration over the REAL durable store (not a fake). Two valid
        // recipients A and B. A message intended for A is acked by A (accepted)
        // and by B (rejected) -- because the expected recipient is read from the
        // SQLite journal at acknowledge time, independent of the ACK frame.
        let (j, url) = openJournal()
        defer { try? FileManager.default.removeItem(at: url) }
        let (pubA, privA) = realKeypair()
        let (pubB, privB) = realKeypair()
        let resolver = TwoRecipientResolver(nodeA(), pubA, nodeB(), pubB)
        // The SAME SqliteDeliveryJournal is BOTH the journal and the expected
        // recipient store (one row holds both), as it will be in production.
        let tracker = DeliveryTracker(journal: j,
                                      authenticator: Ed25519AckAuthenticator(resolver: resolver),
                                      expectedRecipientStore: j)

        let mid = msgId(30)
        XCTAssertTrue(tracker.enqueue(mid, expectedRecipient: nodeA()))
        XCTAssertTrue(tracker.markHandedToRelay(mid))
        // ACK from A verifies -- the durable expected recipient == nodeA.
        let ackA = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                      recipientNodeId: nodeA(), routingTag: routingTag)
        XCTAssertTrue(tracker.acknowledge(mid, ackA),
                       "ACK from the bound recipient A must verify over the durable journal")
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(mid))

        // A second message intended for A: ACK from B must NOT verify.
        let mid2 = msgId(31)
        XCTAssertTrue(tracker.enqueue(mid2, expectedRecipient: nodeA()))
        tracker.markHandedToRelay(mid2)
        let ackB = try AckFrame.build(msgId: mid2, recipientSigningPrivKey: privB,
                                      recipientNodeId: nodeB(), routingTag: routingTag)
        XCTAssertFalse(tracker.acknowledge(mid2, ackB),
                       "ACK from a valid but unintended recipient must not verify over the durable journal")
        XCTAssertEqual(.handedToRelay, tracker.state(mid2))
    }
}