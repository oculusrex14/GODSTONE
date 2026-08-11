import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

/// Durable recipient-authenticated delivery state machine (ADR-005; A-03; Stage
/// 4C / C6.1). Drives the REAL `DeliveryTracker` + `Ed25519AckAuthenticator`
/// with a REAL Ed25519 keypair and an in-memory `DeliveryJournal` fake for the
/// truth-table / negative-ACK matrix, plus a SQLite-backed reboot test in
/// `SqliteDeliveryJournalTests` (the file-backed journal was removed in C6.1 --
/// it could not store the recipient binding). Mirrors `DeliveryTrackerTest` on
/// Android one-for-one.
///
/// C6.1 invariants asserted here:
///  - `AckMode.none` messages can NEVER be acknowledged -- a valid trusted ACK
///    from any recipient yields `.notAckEligible` and the authenticator is NOT
///    invoked (a recipient identity may never become trusted merely because the
///    ACK packet names it).
///  - the expected recipient is bound at ENQUEUE time from durable outbound state
///    and is IMMUTABLE; an ACK from a valid-but-unintended recipient is
///    `.rejectedAuthentication`; a re-enqueue with a different binding is
///    `.conflictRecipient` (the historical send intent is not overwritten).
///  - only `.applied` means "verified"; `.alreadyAcknowledged` is a short-circuit
///    that does NOT authenticate and is NOT a verification.
///  - no delivery is claimed without cryptographic evidence (A-03 / ADR-005 OPEN).
final class DeliveryTrackerTests: XCTestCase {

    private func msgId(_ seed: UInt8) -> Data {
        Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &+ seed) })
    }
    private let routingTag = Data([0, 1, 2, 3])

    /// In-memory `DeliveryJournal` for the truth-table / negative matrix. Stores
    /// the full `DeliveryRecord` (state + ackMode + recipient) so the binding is
    /// preserved across `updateState`. `corruptIds` forces a `.corrupt` read for
    /// the listed msg ids (the C6.5 fail-closed path at the tracker level).
    /// `insertReturnsFalse` forces `insert` to report "no new row" so the re-read
    /// classification branch is exercised.
    private final class FakeJournal: DeliveryJournal {
        var map: [Data: DeliveryRecord] = [:]
        var corruptIds: Set<Data> = []
        let insertReturnsFalse: Bool

        init(insertReturnsFalse: Bool = false) {
            self.insertReturnsFalse = insertReturnsFalse
        }

        /// Test seam: plant a record (bypassing the queuedDurably insert).
        func plant(_ rec: DeliveryRecord) { map[rec.msgId] = rec }

        func read(_ msgId: Data) -> DeliveryLookup {
            if corruptIds.contains(msgId) { return .corrupt }
            guard let rec = map[msgId] else { return .notFound }
            return .found(rec)
        }

        func insert(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> Bool {
            if insertReturnsFalse { return false }
            if map[msgId] != nil { return false } // ON CONFLICT DO NOTHING
            map[msgId] = DeliveryRecord(msgId: msgId, state: .queuedDurably,
                                         ackMode: ackMode, expectedRecipientNodeId: expectedRecipient)
            return true
        }

        func updateState(_ msgId: Data, _ state: DeliveryState) -> Int {
            guard let rec = map[msgId] else { return 0 }
            map[msgId] = DeliveryRecord(msgId: msgId, state: state,
                                         ackMode: rec.ackMode,
                                         expectedRecipientNodeId: rec.expectedRecipientNodeId)
            return 1
        }

        func clear(_ msgId: Data) { map.removeValue(forKey: msgId) }
    }

    /// Authenticator returning a fixed verdict, recording whether it was invoked.
    private final class FakeAuthenticator: AckAuthenticator {
        let ok: Bool
        var invoked = false
        init(_ ok: Bool) { self.ok = ok }
        func verify(originalMsgId: Data, expectedRecipientNodeId: Data, ackFrame: FrameV2) -> Bool {
            invoked = true
            return ok
        }
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

    /// A real Ed25519 keypair (32-byte raw pub/priv).
    private func realKeypair() -> (pub: Data, priv: Data) {
        let priv = Curve25519.Signing.PrivateKey()
        return (priv.publicKey.rawRepresentation, priv.rawRepresentation)
    }

    private func rawAckFrame(_ mid: Data) -> FrameV2 {
        FrameV2(type: .ack, msgId: mid, routingTag: routingTag,
                ttl: 4, hopCount: 0, flags: 0, payload: Data(count: 80))
    }

    /// Extract the record from a `.found` lookup (fail the test otherwise).
    private func foundRecord(_ journal: DeliveryJournal, _ mid: Data) -> DeliveryRecord {
        if case .found(let rec) = journal.read(mid) { return rec }
        XCTFail("expected .found(\(mid))"); return DeliveryRecord(
            msgId: mid, state: .unavailable, ackMode: .none, expectedRecipientNodeId: nil)
    }

    // --- happy path: SINGLE_RECIPIENT enqueue -> handed -> acknowledged ---

    func testHappyPathReachesAcknowledgedOnlyWithAuthenticatedAck() throws {
        let (pub, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x42, count: 16)
        let resolver = SingleRecipientResolver(recipientNodeId, pub)
        let tracker = DeliveryTracker(journal: FakeJournal(),
                                      authenticator: Ed25519AckAuthenticator(resolver: resolver))
        let mid = msgId(1)
        XCTAssertEqual(.unavailable, tracker.state(mid))
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipientNodeId))
        XCTAssertEqual(.queuedDurably, tracker.state(mid))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))
        XCTAssertEqual(.handedToRelay, tracker.state(mid))
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipientNodeId, routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker.acknowledge(mid, ack))
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(mid))
    }

    // --- C6.1 mandatory negative: AckMode.none can NEVER be acknowledged ---

    func testNoneModeMessageRejectsEveryAckAsNotAckEligibleWithoutInvokingTheAuthenticator() throws {
        // A broadcast / SOS is AckMode.none: no recipient is bound, so NO ACK may
        // advance it -- not even a cryptographically valid ACK from a recipient we
        // fully trust. The authenticator is NOT invoked (a recipient identity may
        // never become trusted merely because the ACK packet names it).
        let (pubA, privA) = realKeypair()
        let (pubB, privB) = realKeypair()
        let nodeA = Data(repeating: 0x01, count: 16)
        let nodeB = Data(repeating: 0x02, count: 16)
        _ = TwoRecipientResolver(nodeA, pubA, nodeB, pubB) // two valid keys exist
        let auth = FakeAuthenticator(true) // would say "yes" -- must never be asked
        let tracker = DeliveryTracker(journal: FakeJournal(), authenticator: auth)
        let mid = msgId(50)
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .none, expectedRecipient: nil))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))
        XCTAssertEqual(.handedToRelay, tracker.state(mid))

        // A valid, trusted ACK from Alice -> .notAckEligible, state unchanged, auth NOT invoked.
        let ackA = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                      recipientNodeId: nodeA, routingTag: routingTag)
        XCTAssertEqual(AckResult.notAckEligible, tracker.acknowledge(mid, ackA))
        XCTAssertEqual(.handedToRelay, tracker.state(mid), "NONE-mode state unchanged on ACK")
        XCTAssertFalse(auth.invoked, "authenticator must NOT be invoked for a NONE-mode message")

        // Repeat with Bob -> still .notAckEligible, still no authenticator call.
        let ackB = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privB,
                                      recipientNodeId: nodeB, routingTag: routingTag)
        XCTAssertEqual(AckResult.notAckEligible, tracker.acknowledge(mid, ackB))
        XCTAssertEqual(.handedToRelay, tracker.state(mid))
        XCTAssertFalse(auth.invoked)
    }

    // --- no delivery claimed without cryptographic evidence (ADR-005) ---

    func testRejectedAckDoesNotAdvanceState() {
        let tracker = DeliveryTracker(journal: FakeJournal(), authenticator: FakeAuthenticator(false))
        let mid = msgId(2)
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: Data(repeating: 0x02, count: 16))
        tracker.markHandedToRelay(mid)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid, rawAckFrame(mid)))
        XCTAssertEqual(.handedToRelay, tracker.state(mid), "state unchanged on rejected ACK")
    }

    func testAckForWrongMessageIdIsRejected() throws {
        let (pub, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x43, count: 16)
        let tracker = DeliveryTracker(
            journal: FakeJournal(),
            authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(recipientNodeId, pub)))
        let midX = msgId(10), midY = msgId(11)
        _ = tracker.enqueue(midX, ackMode: .singleRecipient, expectedRecipient: recipientNodeId); tracker.markHandedToRelay(midX)
        _ = tracker.enqueue(midY, ackMode: .singleRecipient, expectedRecipient: recipientNodeId); tracker.markHandedToRelay(midY)
        // A valid ACK for X replayed against Y must not ack Y.
        let ackForX = try AckFrame.build(msgId: midX, recipientSigningPrivKey: priv,
                                         recipientNodeId: recipientNodeId, routingTag: routingTag)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(midY, ackForX),
                       "replayed ACK for X must not ack Y")
        XCTAssertEqual(.handedToRelay, tracker.state(midY))
        // The same ACK does ack X (the message it was made for).
        XCTAssertEqual(AckResult.applied, tracker.acknowledge(midX, ackForX))
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(midX))
    }

    func testTamperedSignatureIsRejected() throws {
        let (pub, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x44, count: 16)
        let tracker = DeliveryTracker(
            journal: FakeJournal(),
            authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(recipientNodeId, pub)))
        let mid = msgId(3)
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipientNodeId); tracker.markHandedToRelay(mid)
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipientNodeId, routingTag: routingTag)
        var tampered = ack.payload
        tampered[0] ^= 0x55
        let bad = FrameV2(type: .ack, msgId: mid, routingTag: routingTag,
                          ttl: 4, hopCount: 0, flags: 0, payload: tampered)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid, bad))
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
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipientNodeId); tracker.markHandedToRelay(mid)
        let forged = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privB,
                                        recipientNodeId: recipientNodeId, routingTag: routingTag)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid, forged),
                       "wrong-recipient signature must not verify")
        XCTAssertEqual(.handedToRelay, tracker.state(mid))
    }

    func testNonAckFrameIsRejectedAsAcknowledgment() throws {
        let (pub, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x46, count: 16)
        let tracker = DeliveryTracker(
            journal: FakeJournal(),
            authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(recipientNodeId, pub)))
        let mid = msgId(5)
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipientNodeId); tracker.markHandedToRelay(mid)
        // Same payload layout but the wrong type -- must be rejected on type.
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipientNodeId, routingTag: routingTag)
        let notAck = FrameV2(type: .message, msgId: mid, routingTag: routingTag,
                             ttl: 4, hopCount: 0, flags: 0, payload: ack.payload)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid, notAck))
        XCTAssertEqual(.handedToRelay, tracker.state(mid))
    }

    // --- truth-table: enqueue ---

    func testTruthTableEnqueueFromUnavailableCreatesSameBindingIdempotentTerminalRejects() {
        let tracker = DeliveryTracker(journal: FakeJournal(), authenticator: FakeAuthenticator(true))
        let mid = msgId(20)
        let recipient = Data(repeating: 0x20, count: 16)
        // from UNAVAILABLE -> .created
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipient))
        // from QUEUED, same binding -> .alreadyQueuedSameBinding
        XCTAssertEqual(EnqueueResult.alreadyQueuedSameBinding, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipient))
        XCTAssertEqual(.queuedDurably, tracker.state(mid))
        // from HANDED, same binding -> .alreadyQueuedSameBinding
        tracker.markHandedToRelay(mid)
        XCTAssertEqual(EnqueueResult.alreadyQueuedSameBinding, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipient))
        // from ACKNOWLEDGED -> .rejectedTerminalState
        _ = tracker.acknowledge(mid, rawAckFrame(mid))
        XCTAssertEqual(EnqueueResult.rejectedTerminalState, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipient))
    }

    func testReEnqueueWithDifferentBindingIsConflictRecipientAndPreservesOriginalBinding() {
        let journal = FakeJournal()
        let tracker = DeliveryTracker(journal: journal, authenticator: FakeAuthenticator(true))
        let mid = msgId(24)
        let nodeA = Data(repeating: 0xA1, count: 16)
        let nodeB = Data(repeating: 0xB1, count: 16)
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA))
        // Different intended recipient for the SAME msg_id -> .conflictRecipient.
        XCTAssertEqual(EnqueueResult.conflictRecipient, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeB))
        // The historical send intent (nodeA) is preserved -- not overwritten.
        let rec = foundRecord(journal, mid)
        XCTAssertEqual(rec.expectedRecipientNodeId, nodeA)
        XCTAssertEqual(.queuedDurably, rec.state)
        // NONE vs SINGLE for the same msg_id is also a conflict.
        XCTAssertEqual(EnqueueResult.conflictRecipient, tracker.enqueue(mid, ackMode: .none, expectedRecipient: nil))
    }

    func testNoneModeEnqueueIsIdempotentOnSameNullBinding() {
        let tracker = DeliveryTracker(journal: FakeJournal(), authenticator: FakeAuthenticator(true))
        let mid = msgId(25)
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .none, expectedRecipient: nil))
        XCTAssertEqual(EnqueueResult.alreadyQueuedSameBinding, tracker.enqueue(mid, ackMode: .none, expectedRecipient: nil))
    }

    func testInconsistentBindingIsRejectedAsCorruptBeforeJournalIsTouched() {
        let tracker = DeliveryTracker(journal: FakeJournal(), authenticator: FakeAuthenticator(true))
        let mid = msgId(26)
        // SINGLE_RECIPIENT with no recipient violates the C6.1 invariant.
        XCTAssertEqual(EnqueueResult.corrupt, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nil))
        // NONE with a recipient violates it too.
        XCTAssertEqual(EnqueueResult.corrupt, tracker.enqueue(mid, ackMode: .none, expectedRecipient: Data(count: 16)))
        // Neither touched the journal.
        XCTAssertEqual(.unavailable, tracker.state(mid))
    }

    // --- truth-table: markHandedToRelay / expire / cancel (TransitionResult) ---

    func testTruthTableMarkHandedOnlyFromQueuedOrHanded() {
        let tracker = DeliveryTracker(journal: FakeJournal(), authenticator: FakeAuthenticator(true))
        let mid = msgId(21)
        XCTAssertEqual(TransitionResult.unknownMessage, tracker.markHandedToRelay(mid), "cannot hand over before enqueue")
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: Data(repeating: 0x21, count: 16))
        XCTAssertEqual(TransitionResult.applied, tracker.markHandedToRelay(mid))
        XCTAssertEqual(TransitionResult.alreadyInTarget, tracker.markHandedToRelay(mid), "idempotent from HANDED")
        _ = tracker.acknowledge(mid, rawAckFrame(mid))
        XCTAssertEqual(TransitionResult.rejectedState, tracker.markHandedToRelay(mid), "cannot hand over after acknowledged")
    }

    func testTruthTableExpireCancelAndTerminalRejection() {
        let tracker = DeliveryTracker(journal: FakeJournal(), authenticator: FakeAuthenticator(true))
        let mid = msgId(22)
        XCTAssertEqual(TransitionResult.unknownMessage, tracker.expire(mid))
        XCTAssertEqual(TransitionResult.unknownMessage, tracker.cancel(mid))
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: Data(repeating: 0x22, count: 16))
        XCTAssertEqual(TransitionResult.applied, tracker.cancel(mid))
        XCTAssertEqual(.cancelledLocally, tracker.state(mid))
        // terminal: a DIFFERENT transition is rejected; re-calling the SAME one
        // is idempotent (a crash-then-resume that re-issues cancel still succeeds).
        XCTAssertEqual(EnqueueResult.rejectedTerminalState, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: Data(repeating: 0x22, count: 16)))
        XCTAssertEqual(TransitionResult.rejectedState, tracker.markHandedToRelay(mid))
        XCTAssertEqual(AckResult.rejectedState, tracker.acknowledge(mid, rawAckFrame(mid)))
        XCTAssertEqual(TransitionResult.rejectedState, tracker.expire(mid), "cannot expire a CANCELLED message")
        XCTAssertEqual(TransitionResult.alreadyInTarget, tracker.cancel(mid), "re-cancel is idempotent from CANCELLED")

        let mid2 = msgId(23)
        _ = tracker.enqueue(mid2, ackMode: .singleRecipient, expectedRecipient: Data(repeating: 0x23, count: 16)); tracker.markHandedToRelay(mid2)
        XCTAssertEqual(TransitionResult.applied, tracker.expire(mid2))
        XCTAssertEqual(.expired, tracker.state(mid2))
        XCTAssertEqual(AckResult.rejectedState, tracker.acknowledge(mid2, rawAckFrame(mid2)),
                       "cannot ack an EXPIRED message")
        XCTAssertEqual(TransitionResult.rejectedState, tracker.cancel(mid2), "cannot cancel an EXPIRED message")
        XCTAssertEqual(TransitionResult.alreadyInTarget, tracker.expire(mid2), "re-expire is idempotent from EXPIRED")
    }

    // --- acknowledge idempotency: alreadyAcknowledged is NOT a verification ---

    func testAcknowledgeIsIdempotentSecondAckIsAlreadyAcknowledgedNotApplied() throws {
        let (pub, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x47, count: 16)
        let tracker = DeliveryTracker(
            journal: FakeJournal(),
            authenticator: Ed25519AckAuthenticator(resolver: SingleRecipientResolver(recipientNodeId, pub)))
        let mid = msgId(6)
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipientNodeId); tracker.markHandedToRelay(mid)
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipientNodeId, routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker.acknowledge(mid, ack))
        // A second (even unsigned) ACK short-circuits to .alreadyAcknowledged --
        // option B: the authenticator is NOT consulted for a terminal record, and
        // this is NOT a new verification.
        XCTAssertEqual(AckResult.alreadyAcknowledged, tracker.acknowledge(mid, rawAckFrame(mid)))
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(mid))
    }

    // --- corrupt / unknown message lookup fail closed ---

    func testUnknownMessageAckIsUnknownMessageAndCorruptRecordIsCorrupt() {
        let journal = FakeJournal()
        let tracker = DeliveryTracker(journal: journal, authenticator: FakeAuthenticator(true))
        let mid = msgId(60)
        XCTAssertEqual(AckResult.unknownMessage, tracker.acknowledge(mid, rawAckFrame(mid)))
        // A corrupt row -> .corrupt (NOT UNAVAILABLE / NOT authenticated).
        journal.corruptIds.insert(mid)
        XCTAssertEqual(EnqueueResult.corrupt, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: Data(repeating: 0x60, count: 16)))
        XCTAssertEqual(AckResult.corrupt, tracker.acknowledge(mid, rawAckFrame(mid)))
        XCTAssertEqual(.unavailable, tracker.state(mid), "corrupt reads as UNAVAILABLE at the state seam")
    }

    func testForgetClearsTheDeliveryRecord() {
        let journal = FakeJournal()
        let tracker = DeliveryTracker(journal: journal, authenticator: FakeAuthenticator(true))
        let mid = msgId(61)
        _ = tracker.enqueue(mid, ackMode: .none, expectedRecipient: nil)
        tracker.forget(mid)
        XCTAssertEqual(.unavailable, tracker.state(mid))
        XCTAssertEqual(DeliveryLookup.notFound, journal.read(mid))
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

    func testTwoValidIdentitiesAckVerifiesOnlyForExpectedRecipientBoundAtEnqueue() throws {
        // C2 (ADR-005): the expected recipient is bound at ENQUEUE time from
        // durable outbound state, INDEPENDENT of the ACK. Two equally valid
        // recipients A and B each have their own key. An ACK from the bound
        // recipient verifies (.applied); an ACK from the other valid recipient
        // does NOT (.rejectedAuthentication), because the ACK's recipientNodeId
        // must equal the expected recipient recorded at send time.
        let (pubA, privA) = realKeypair()
        let (pubB, privB) = realKeypair()
        let nodeA = Data(repeating: 0x01, count: 16)
        let nodeB = Data(repeating: 0x02, count: 16)
        let resolver = TwoRecipientResolver(nodeA, pubA, nodeB, pubB)
        let tracker = DeliveryTracker(journal: FakeJournal(),
                                      authenticator: Ed25519AckAuthenticator(resolver: resolver))

        // Message intended for A: enqueue binds expectedRecipient = nodeA.
        let mid = msgId(30)
        XCTAssertEqual(EnqueueResult.created, tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA))
        tracker.markHandedToRelay(mid)
        // ACK from A (signed by A, claiming A) verifies.
        let ackA = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                      recipientNodeId: nodeA, routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker.acknowledge(mid, ackA), "ACK from the bound recipient A must verify")
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(mid))

        // A second message intended for A: ACK from B (signed by B, claiming B)
        // must NOT verify -- B is valid but NOT the expected recipient.
        let mid2 = msgId(31)
        _ = tracker.enqueue(mid2, ackMode: .singleRecipient, expectedRecipient: nodeA); tracker.markHandedToRelay(mid2)
        let ackB = try AckFrame.build(msgId: mid2, recipientSigningPrivKey: privB,
                                      recipientNodeId: nodeB, routingTag: routingTag)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid2, ackB),
                       "ACK from a valid but unintended recipient must not verify")
        XCTAssertEqual(.handedToRelay, tracker.state(mid2))

        // Symmetric: a message intended for B is acked by A -> rejected, then by B -> accepted.
        let mid3 = msgId(32)
        _ = tracker.enqueue(mid3, ackMode: .singleRecipient, expectedRecipient: nodeB); tracker.markHandedToRelay(mid3)
        let ackAforB = try AckFrame.build(msgId: mid3, recipientSigningPrivKey: privA,
                                          recipientNodeId: nodeA, routingTag: routingTag)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid3, ackAforB),
                       "ACK from A for a message intended for B must not verify")
        let ackBforB = try AckFrame.build(msgId: mid3, recipientSigningPrivKey: privB,
                                          recipientNodeId: nodeB, routingTag: routingTag)
        XCTAssertEqual(AckResult.applied, tracker.acknowledge(mid3, ackBforB), "ACK from the bound recipient B must verify")
        XCTAssertEqual(.acknowledgedByRecipient, tracker.state(mid3))
    }

    func testAckClaimingRecipientOtherThanExpectedIsRejected() throws {
        // C2 edge: the ACK names a recipient that the resolver CAN resolve (a
        // real, valid recipient) but which differs from the expected recipient
        // bound at enqueue. This must be rejected -- the binding is to the
        // durable expected recipient, not to whoever the ACK claims to be.
        let (pubA, privA) = realKeypair()
        let (pubB, _) = realKeypair()
        let nodeA = Data(repeating: 0x0A, count: 16)
        let nodeB = Data(repeating: 0x0B, count: 16)
        let resolver = TwoRecipientResolver(nodeA, pubA, nodeB, pubB)
        let tracker = DeliveryTracker(journal: FakeJournal(),
                                      authenticator: Ed25519AckAuthenticator(resolver: resolver))
        let mid = msgId(33)
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: nodeA); tracker.markHandedToRelay(mid)
        // ACK signed by A but claiming nodeB in its payload (recipientNodeId field).
        // claimed recipient (B) != expected recipient (A) -> rejected.
        let mismatched = try AckFrame.build(msgId: mid, recipientSigningPrivKey: privA,
                                            recipientNodeId: nodeB, routingTag: routingTag)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid, mismatched),
                       "ACK claiming a recipient other than the expected one must be rejected")
        XCTAssertEqual(.handedToRelay, tracker.state(mid))
    }

    // --- Stage 4C / C3: production resolver is UNRESOLVED -> fail-closed ---

    func testUnresolvedProductionResolverFailCloses() throws {
        // C3: the production RecipientKeyResolver is UNRESOLVED (M2-link identity
        // binding not wired). It returns nil for every node id, so the
        // Ed25519AckAuthenticator can resolve no key and rejects every ACK. This
        // is the fail-closed production state: no delivery is claimed until real
        // keys are bound -- A-03 / ADR-005 stay OPEN.
        let (_, priv) = realKeypair()
        let recipientNodeId = Data(repeating: 0x50, count: 16)
        let tracker = DeliveryTracker(journal: FakeJournal(),
                                      authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver()))
        let mid = msgId(40)
        _ = tracker.enqueue(mid, ackMode: .singleRecipient, expectedRecipient: recipientNodeId); tracker.markHandedToRelay(mid)
        let ack = try AckFrame.build(msgId: mid, recipientSigningPrivKey: priv,
                                     recipientNodeId: recipientNodeId, routingTag: routingTag)
        XCTAssertEqual(AckResult.rejectedAuthentication, tracker.acknowledge(mid, ack),
                       "unresolved resolver must reject every ACK")
        XCTAssertEqual(.handedToRelay, tracker.state(mid), "no delivery claimed without a bound key")
    }
}