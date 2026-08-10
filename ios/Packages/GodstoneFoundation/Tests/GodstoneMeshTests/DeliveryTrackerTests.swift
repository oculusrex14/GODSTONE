import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

/// Durable recipient-authenticated delivery state machine (ADR-005; A-03;
/// Stage 3 Phase H). Drives the REAL `DeliveryTracker` + `Ed25519AckAuthenticator`
/// with a REAL Ed25519 keypair and a REAL on-disk `FileDeliveryJournal` for the
/// reboot path, plus fakes for the truth-table / negative-ACK matrix. Mirrors
/// `DeliveryTrackerTest` on Android one-for-one.
///
/// Asserts the ADR-005 exit criteria provable without a device/radio: truth-table
/// for every state; no unsigned/tampered/wrong-recipient ACK accepted (no
/// delivery claimed without cryptographic evidence); replay across message ids
/// rejected; reboot recovery from the durable journal.
final class DeliveryTrackerTests: XCTestCase {

    private func msgId(_ seed: UInt8) -> Data {
        Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ seed) })
    }
    private let routingTag = Data([0, 1, 2, 3])

    /// In-memory journal for the truth-table / negative matrix.
    private final class FakeJournal: DeliveryJournal {
        var map: [Data: DeliveryState] = [:]
        func read(_ msgId: Data) -> DeliveryState { map[msgId] ?? .unavailable }
        func write(_ msgId: Data, _ state: DeliveryState) { map[msgId] = state }
        func clear(_ msgId: Data) { map.removeValue(forKey: msgId) }
    }

    /// Authenticator that returns a fixed verdict (for the truth-table).
    private final class FakeAuthenticator: AckAuthenticator {
        let ok: Bool
        init(_ ok: Bool) { self.ok = ok }
        func verify(originalMsgId: Data, expectedRecipientNodeId: Data?, ackFrame: FrameV2) -> Bool { ok }
    }

    /// Resolver backed by a single recipient keypair.
    private final class SingleRecipientResolver: RecipientKeyResolver {
        let nodeId: Data
        let pub: Data
        init(_ nodeId: Data, _ pub: Data) { self.nodeId = nodeId; self.pub = pub }
        func publicSigningKey(forNodeId nodeId: Data) -> Data? {
            nodeId == self.nodeId ? pub : nil
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

    /// In-memory `ExpectedRecipientStore` for the C2 binding tests.
    private final class FakeExpectedRecipientStore: ExpectedRecipientStore {
        var map: [Data: Data] = [:]
        func expectedRecipient(_ msgId: Data) -> Data? { map[msgId] }
        func recordExpectedRecipient(_ msgId: Data, _ recipient: Data?) {
            if let r = recipient { map[msgId] = r } else { map.removeValue(forKey: msgId) }
        }
    }

    /// A real Ed25519 keypair (32-byte raw pub/priv).
    private func realKeypair() -> (pub: Data, priv: Data) {
        let priv = Curve25519.Signing.PrivateKey()
        return (priv.publicKey.rawRepresentation, priv.rawRepresentation)
    }

    private func bogusAck(_ mid: Data) -> FrameV2 {
        FrameV2(type: .ack, msgId: mid, routingTag: routingTag,
                ttl: 4, hopCount: 0, flags: 0, payload: Data(count: 80))
    }

    // --- happy path: enqueue -> handed -> acknowledged (authenticated) ---

    func testHappyPathReachesAcknowledgedOnlyWithAuthenticatedAck() throws {
        let (pub, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x42, count: 16)
        let resolver = SingleRecipientResolver(recipientNodeId, pub)
        let tracker = DeliveryTracker(journal: FakeJournal(),
                                      authenticator: Ed25519AckAuthenticator(resolver: resolver))
        let mid = msgId(1)
        XCTAssertEqual(.unavailable, tracker.state(mid))
        XCTAssertTrue(tracker.enqueue(mid))
        XCTAssertEqual(.queuedDurably, tracker.state(mid))
        XCTAssertTrue(tracker.markHandedToRelay(mid))
        XCTAssertEqual(.handedToRelay, tracker.state(mid))
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipientNodeId, routingTag: routingTag)
        XCTAssertTrue(tracker.acknowledge(mid, ack))
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(mid))
    }

    // --- no delivery claimed without cryptographic evidence (ADR-005) ---

    func testRejectedAckDoesNotAdvanceState() {
        let tracker = DeliveryTracker(journal: FakeJournal(), authenticator: FakeAuthenticator(false))
        let mid = msgId(2)
        tracker.enqueue(mid)
        tracker.markHandedToRelay(mid)
        XCTAssertFalse(tracker.acknowledge(mid, bogusAck(mid)))
        XCTAssertEqual(.handedToRelay, tracker.state(mid), "state unchanged on rejected ACK")
    }

    func testAckForWrongMessageIdIsRejected() throws {
        let (pub, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x43, count: 16)
        let tracker = DeliveryTracker(
            journal: FakeJournal(),
            authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(recipientNodeId, pub)))
        let midX = msgId(10), midY = msgId(11)
        tracker.enqueue(midX); tracker.markHandedToRelay(midX)
        tracker.enqueue(midY); tracker.markHandedToRelay(midY)
        // A valid ACK for X replayed against Y must not ack Y.
        let ackForX = try AckFrame.build(msgId: midX, recipientSigningPrivKey: priv,
                                         recipientNodeId: recipientNodeId, routingTag: routingTag)
        XCTAssertFalse(tracker.acknowledge(midY, ackForX), "replayed ACK for X must not ack Y")
        XCTAssertEqual(.handedToRelay, tracker.state(midY))
        // The same ACK does ack X (the message it was made for).
        XCTAssertTrue(tracker.acknowledge(midX, ackForX))
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(midX))
    }

    func testTamperedSignatureIsRejected() throws {
        let (pub, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x44, count: 16)
        let tracker = DeliveryTracker(
            journal: FakeJournal(),
            authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(recipientNodeId, pub)))
        let mid = msgId(3)
        tracker.enqueue(mid); tracker.markHandedToRelay(mid)
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipientNodeId, routingTag: routingTag)
        var tampered = ack.payload
        tampered[0] ^= 0x55
        let bad = FrameV2(type: .ack, msgId: mid, routingTag: routingTag,
                          ttl: 4, hopCount: 0, flags: 0, payload: tampered)
        XCTAssertFalse(tracker.acknowledge(mid, bad))
        XCTAssertEqual(.handedToRelay, tracker.state(mid))
    }

    func testAckSignedByWrongRecipientIsRejected() throws {
        let (pubA, _) = realKeypair()        // the bound recipient A
        let (_, privB) = realKeypair()       // an attacker B
        let recipientNodeId = Data(repeating: 0x45, count: 16)
        // Resolver binds recipientNodeId -> A's pub, but the ACK is signed by B.
        let tracker = DeliveryTracker(
            journal: FakeJournal(),
            authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(recipientNodeId, pubA)))
        let mid = msgId(4)
        tracker.enqueue(mid); tracker.markHandedToRelay(mid)
        let forged = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privB,
                                        recipientNodeId: recipientNodeId, routingTag: routingTag)
        XCTAssertFalse(tracker.acknowledge(mid, forged), "wrong-recipient signature must not verify")
        XCTAssertEqual(.handedToRelay, tracker.state(mid))
    }

    func testNonAckFrameIsRejectedAsAcknowledgment() throws {
        let (pub, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x46, count: 16)
        let tracker = DeliveryTracker(
            journal: FakeJournal(),
            authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(recipientNodeId, pub)))
        let mid = msgId(5)
        tracker.enqueue(mid); tracker.markHandedToRelay(mid)
        // Same payload layout but the wrong type -- must be rejected on type.
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipientNodeId, routingTag: routingTag)
        let notAck = FrameV2(type: .message, msgId: mid, routingTag: routingTag,
                             ttl: 4, hopCount: 0, flags: 0, payload: ack.payload)
        XCTAssertFalse(tracker.acknowledge(mid, notAck))
        XCTAssertEqual(.handedToRelay, tracker.state(mid))
    }

    // --- truth-table: legal transitions advance, illegal are rejected ---

    func testTruthTableEnqueueOnlyFromUnavailableOrQueued() {
        let tracker = DeliveryTracker(journal: FakeJournal(), authenticator: FakeAuthenticator(true))
        let mid = msgId(20)
        XCTAssertTrue(tracker.enqueue(mid))                 // unavailable -> queued
        XCTAssertTrue(tracker.enqueue(mid))                 // queued -> idempotent
        XCTAssertEqual(.queuedDurably, tracker.state(mid))
        tracker.markHandedToRelay(mid)
        XCTAssertFalse(tracker.enqueue(mid))                // handed -> false
        tracker.acknowledge(mid, bogusAck(mid))
        XCTAssertFalse(tracker.enqueue(mid))                // acknowledged -> false
    }

    func testTruthTableMarkHandedOnlyFromQueuedOrHanded() {
        let tracker = DeliveryTracker(journal: FakeJournal(), authenticator: FakeAuthenticator(true))
        let mid = msgId(21)
        XCTAssertFalse(tracker.markHandedToRelay(mid), "cannot hand over before enqueue")
        tracker.enqueue(mid)
        XCTAssertTrue(tracker.markHandedToRelay(mid))
        XCTAssertTrue(tracker.markHandedToRelay(mid), "idempotent from handed")
        tracker.acknowledge(mid, bogusAck(mid))
        XCTAssertFalse(tracker.markHandedToRelay(mid), "cannot hand over after acknowledged")
    }

    func testTruthTableExpireCancelAndTerminalRejection() {
        let tracker = DeliveryTracker(journal: FakeJournal(), authenticator: FakeAuthenticator(true))
        let mid = msgId(22)
        XCTAssertFalse(tracker.expire(mid))
        XCTAssertFalse(tracker.cancel(mid))
        tracker.enqueue(mid)
        XCTAssertTrue(tracker.cancel(mid))
        XCTAssertEqual(.cancelledLocally, tracker.state(mid))
        // terminal: a DIFFERENT transition is rejected; re-calling the SAME one
        // is idempotent (a crash-then-resume that re-issues cancel still succeeds).
        XCTAssertFalse(tracker.enqueue(mid))
        XCTAssertFalse(tracker.markHandedToRelay(mid))
        XCTAssertFalse(tracker.acknowledge(mid, bogusAck(mid)))
        XCTAssertFalse(tracker.expire(mid), "cannot expire a CANCELLED message")
        XCTAssertTrue(tracker.cancel(mid), "re-cancel is idempotent from CANCELLED")

        let mid2 = msgId(23)
        tracker.enqueue(mid2); tracker.markHandedToRelay(mid2)
        XCTAssertTrue(tracker.expire(mid2))
        XCTAssertEqual(.expired, tracker.state(mid2))
        XCTAssertFalse(tracker.acknowledge(mid2, bogusAck(mid2)), "cannot ack an EXPIRED message")
        XCTAssertFalse(tracker.cancel(mid2), "cannot cancel an EXPIRED message")
        XCTAssertTrue(tracker.expire(mid2), "re-expire is idempotent from EXPIRED")
    }

    func testAcknowledgeIdempotentOnceAcknowledged() throws {
        let (pub, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x47, count: 16)
        let tracker = DeliveryTracker(
            journal: FakeJournal(),
            authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(recipientNodeId, pub)))
        let mid = msgId(6)
        tracker.enqueue(mid); tracker.markHandedToRelay(mid)
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipientNodeId, routingTag: routingTag)
        XCTAssertTrue(tracker.acknowledge(mid, ack))
        // A second (even unsigned) ack is idempotent -- already acknowledged.
        XCTAssertTrue(tracker.acknowledge(mid, bogusAck(mid)))
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(mid))
    }

    // --- reboot recovery: a fresh tracker over the same durable journal ---

    func testRebootRecoveryStateSurvivesFreshTrackerOverSameFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-delivery-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let (pub, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x48, count: 16)
        let resolver = SingleRecipientResolver(recipientNodeId, pub)
        let mid = msgId(7)

        // First "boot": enqueue + hand to relay, then "crash".
        let boot1 = DeliveryTracker(journal: FileDeliveryJournal(url: url),
                                    authenticator: Ed25519AckAuthenticator(resolver: resolver))
        XCTAssertTrue(boot1.enqueue(mid))
        XCTAssertTrue(boot1.markHandedToRelay(mid))
        XCTAssertEqual(.handedToRelay, boot1.state(mid))

        // Second "boot": a fresh tracker over the same journal file recovers.
        let boot2 = DeliveryTracker(journal: FileDeliveryJournal(url: url),
                                    authenticator: Ed25519AckAuthenticator(resolver: resolver))
        XCTAssertEqual(.handedToRelay, boot2.state(mid), "state recovered after reboot")
        // And it can still be acknowledged after the reboot.
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipientNodeId, routingTag: routingTag)
        XCTAssertTrue(boot2.acknowledge(mid, ack))
        XCTAssertEqual(.acknowledgedByRecipient, boot2.state(mid))

        // Third "boot": sees the persisted acknowledgment.
        let boot3 = DeliveryTracker(journal: FileDeliveryJournal(url: url),
                                    authenticator: Ed25519AckAuthenticator(resolver: resolver))
        XCTAssertEqual(.acknowledgedByRecipient, boot3.state(mid))
    }

    // --- cross-platform parity: a signature made here verifies here ---

    func testEd25519SignAndVerifyRoundTrip() throws {
        let (pub, priv) = realKeypair()
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: priv)
        let msg = Data(ackMagic.utf8) + msgId(8) + Data(repeating: 0x49, count: 16)
        let sig = try key.signature(for: msg)
        XCTAssertEqual(64, sig.count)
        let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: pub)
        XCTAssertTrue(pubKey.isValidSignature(sig, for: msg))
        // wrong message -> false
        XCTAssertFalse(pubKey.isValidSignature(sig, for: Data(count: 39)))
        // wrong key -> false
        let (otherPub, _) = realKeypair()
        let otherKey = try Curve25519.Signing.PublicKey(rawRepresentation: otherPub)
        XCTAssertFalse(otherKey.isValidSignature(sig, for: msg))
    }

    // --- Stage 4C / C2: two valid identities, ACK bound to the expected recipient ---

    func testTwoValidIdentitiesAckVerifiesOnlyForExpectedRecipient() throws {
        // C2 (ADR-005): the expected recipient is bound at ENQUEUE time from durable
        // outbound state, INDEPENDENT of the ACK. Two equally valid recipients A and
        // B each have their own key. An ACK from the bound recipient verifies; an ACK
        // from the other valid recipient does NOT, because the ACK's recipientNodeId
        // must equal the expected recipient recorded at send time. This is the
        // adversarial test the directive mandates: two valid identities,
        // wrong-recipient ACK rejected. Mirrors the Android C2 test one-for-one.
        let (pubA, privA) = realKeypair()
        let (pubB, privB) = realKeypair()
        let nodeA = Data(repeating: 0x01, count: 16)
        let nodeB = Data(repeating: 0x02, count: 16)
        let resolver = TwoRecipientResolver(nodeA, pubA, nodeB, pubB)
        let store = FakeExpectedRecipientStore()
        let tracker = DeliveryTracker(journal: FakeJournal(),
                                      authenticator: Ed25519AckAuthenticator(resolver: resolver),
                                      expectedRecipientStore: store)

        // Message intended for A: enqueue binds expectedRecipient = nodeA.
        let mid = msgId(30)
        XCTAssertTrue(tracker.enqueue(mid, expectedRecipient: nodeA))
        tracker.markHandedToRelay(mid)
        // ACK from A (signed by A, claiming A) verifies.
        let ackA = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                      recipientNodeId: nodeA, routingTag: routingTag)
        XCTAssertTrue(tracker.acknowledge(mid, ackA), "ACK from the bound recipient A must verify")
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(mid))

        // A second message intended for A: ACK from B (signed by B, claiming B) must
        // NOT verify -- B is valid but NOT the expected recipient.
        let mid2 = msgId(31)
        XCTAssertTrue(tracker.enqueue(mid2, expectedRecipient: nodeA))
        tracker.markHandedToRelay(mid2)
        let ackB = try AckFrame.build(msgId: mid2, recipientSigningPrivKey: privB,
                                      recipientNodeId: nodeB, routingTag: routingTag)
        XCTAssertFalse(tracker.acknowledge(mid2, ackB), "ACK from a valid but unintended recipient must not verify")
        XCTAssertEqual(.handedToRelay, tracker.state(mid2))

        // Symmetric: a message intended for B is acked by A -> rejected, then by B -> accepted.
        let mid3 = msgId(32)
        XCTAssertTrue(tracker.enqueue(mid3, expectedRecipient: nodeB))
        tracker.markHandedToRelay(mid3)
        let ackAforB = try AckFrame.build(msgId: mid3, recipientSigningPrivKey: privA,
                                         recipientNodeId: nodeA, routingTag: routingTag)
        XCTAssertFalse(tracker.acknowledge(mid3, ackAforB), "ACK from A for a message intended for B must not verify")
        let ackBforB = try AckFrame.build(msgId: mid3, recipientSigningPrivKey: privB,
                                         recipientNodeId: nodeB, routingTag: routingTag)
        XCTAssertTrue(tracker.acknowledge(mid3, ackBforB), "ACK from the bound recipient B must verify")
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(mid3))
    }

    func testAckClaimingRecipientOtherThanExpectedIsRejected() throws {
        // C2 edge: the ACK names a recipient that the resolver CAN resolve (a real,
        // valid recipient) but which differs from the expected recipient bound at
        // enqueue. This must be rejected -- the binding is to the durable expected
        // recipient, not to whoever the ACK claims to be.
        let (pubA, privA) = realKeypair()
        let (pubB, _) = realKeypair()
        let nodeA = Data(repeating: 0x0A, count: 16)
        let nodeB = Data(repeating: 0x0B, count: 16)
        let resolver = TwoRecipientResolver(nodeA, pubA, nodeB, pubB)
        let store = FakeExpectedRecipientStore()
        let tracker = DeliveryTracker(journal: FakeJournal(),
                                      authenticator: Ed25519AckAuthenticator(resolver: resolver),
                                      expectedRecipientStore: store)
        let mid = msgId(33)
        XCTAssertTrue(tracker.enqueue(mid, expectedRecipient: nodeA))
        tracker.markHandedToRelay(mid)
        // ACK signed by A but claiming nodeB in its payload (recipientNodeId field).
        // The signature is over preimage(mid, nodeB) -- valid under A's key only if A
        // signed it, which A did not sign for nodeB's preimage. Either way it must be
        // rejected: claimed recipient (B) != expected recipient (A).
        let mismatched = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                           recipientNodeId: nodeB, routingTag: routingTag)
        XCTAssertFalse(tracker.acknowledge(mid, mismatched),
                       "ACK claiming a recipient other than the expected one must be rejected")
        XCTAssertEqual(.handedToRelay, tracker.state(mid))
    }

    // --- Stage 4C / C3: production resolver is UNRESOLVED -> fail-closed ---

    func testUnresolvedProductionResolverFailCloses() throws {
        // C3: the production RecipientKeyResolver is UNRESOLVED (M2-link identity
        // binding not wired). It returns nil for every node id, so the
        // Ed25519AckAuthenticator can resolve no key and rejects every ACK. This is
        // the fail-closed production state: no delivery is claimed until real keys
        // are bound -- A-03 / ADR-005 stay OPEN.
        let (_, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x50, count: 16)
        let store = FakeExpectedRecipientStore()
        let tracker = DeliveryTracker(journal: FakeJournal(),
                                      authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver()),
                                      expectedRecipientStore: store)
        let mid = msgId(40)
        XCTAssertTrue(tracker.enqueue(mid, expectedRecipient: recipientNodeId))
        tracker.markHandedToRelay(mid)
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipientNodeId, routingTag: routingTag)
        XCTAssertFalse(tracker.acknowledge(mid, ack), "unresolved resolver must reject every ACK")
        XCTAssertEqual(.handedToRelay, tracker.state(mid), "no delivery claimed without a bound key")
    }
}