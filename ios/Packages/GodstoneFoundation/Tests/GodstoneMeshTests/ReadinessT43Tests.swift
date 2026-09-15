// T43 readiness court (iOS isle) -- honest delivery labels. The twin of
// ReadinessT43Test.kt (android), with the SAME witness name set.
//
// The card's defect: "A Boolean send currently advances HANDED_TO_RELAY even
// though it only proves local ATT admission." A message whose bytes a radio
// accepted was recorded as durably handed to a relay -- a custody claim the node
// could not honour, and one a restart would keep repeating.
//
// Host tests prove no CoreBluetooth and no Data Protection behaviour; readiness
// stays false and no gate is closed.
import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

final class ReadinessT43Tests: XCTestCase {
    private let rng = SystemRandomNumberGenerator()

    // ------------------------------------------------------------ fixtures

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage[tag] = nil }
    }

    private struct Local { let id: MeshIdentity; let seed: Data }

    private func newLocal(_ seedByte: UInt8, _ xByte: UInt8) throws -> Local {
        let edSeed = Data(repeating: seedByte, count: 32)
        let xPriv = Data(repeating: xByte, count: 32)
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: edSeed,
                                             x25519PrivateKey: xPriv)
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        let id = try MeshIdentity.loadFromKeychain(keychain: kc)
        return Local(id: id, seed: edSeed)
    }

    private final class KeyTable: RecipientKeyResolver, @unchecked Sendable {
        private var table: [Data: Data] = [:]
        func put(_ nodeId: Data, _ key: Data) { table[nodeId] = Data(key) }
        func publicSigningKey(forNodeId nodeId: Data) -> Data? { table[nodeId].map { Data($0) } }
    }

    private final class CountingAuthenticator: AckAuthenticator, @unchecked Sendable {
        private let inner: Ed25519AckAuthenticator
        var calls = 0
        init(_ inner: Ed25519AckAuthenticator) { self.inner = inner }
        func verify(originalMsgId: Data, expectedRecipientNodeId: Data, ackFrame: FrameV2) -> Bool {
            calls += 1
            return inner.verify(originalMsgId: originalMsgId,
                                expectedRecipientNodeId: expectedRecipientNodeId, ackFrame: ackFrame)
        }
    }

    private final class FailClosedTrust: PeerBindingTrustAuthority, @unchecked Sendable {
        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            .storageFailure
        }
    }

    private final class Rig {
        let store: InMemoryMessageStore
        let keys: KeyTable
        let tracker: DeliveryTracker
        let node: MeshNode
        let auth: CountingAuthenticator
        private var seedCounter = 0
        init(store: InMemoryMessageStore, keys: KeyTable, tracker: DeliveryTracker,
             node: MeshNode, auth: CountingAuthenticator) {
            self.store = store; self.keys = keys; self.tracker = tracker
            self.node = node; self.auth = auth
        }
        func nextSeed() -> Int { seedCounter += 1; return seedCounter * 13 + 5 }
    }

    private func rig(_ tag: UInt8 = 0x11) throws -> Rig {
        let store = InMemoryMessageStore()
        let keys = KeyTable()
        let auth = CountingAuthenticator(Ed25519AckAuthenticator(resolver: keys))
        let tracker = DeliveryTracker(repo: InMemoryDeliveryRepositoryForT43(store),
                                      authenticator: auth)
        let identity = try newLocal(tag, tag &+ 1)
        let node = MeshNode(identity: identity.id, store: store, deliveryTracker: tracker,
                            sessions: SessionManager(identity: identity.id,
                                                     trustAuthority: FailClosedTrust()))
        // GS-SOS-001: the SOS road refuseth to offer an unauthenticated frame, so a
        // rig that SENDS distress carrieth a signing authority. SIMULATED, PUBLIC
        // material -- harness support, never a device result.
        node.sosAuthority = SosTestAuthority()
        return Rig(store: store, keys: keys, tracker: tracker, node: node, auth: auth)
    }

    private func msgId(_ seed: Int) -> Data { Data((0..<16).map { UInt8(($0 + seed) & 0xFF) }) }

    private func directedFrame(_ seed: Int) -> FrameV2 {
        FrameV2(type: .message, msgId: msgId(seed), routingTag: Data(repeating: 3, count: 4),
                ttl: FrameV2.defaultTtl, hopCount: 0,
                flags: FrameV2.Flags.sealed | UInt16(Priority.direct.rawValue << 8),
                payload: Data((0..<24).map { UInt8(($0 + seed) & 0xFF) }))
    }

    private func ackOf(_ mid: Data, _ signer: Local) -> FrameV2 {
        let preimage = Data("GMP2-ACK".utf8) + mid + signer.id.nodeId
        let signature = try! signer.id.sign(message: preimage)
        return FrameV2(type: .ack, msgId: mid, routingTag: Data(repeating: 7, count: 4),
                       ttl: 12, hopCount: 0, flags: 0,
                       payload: signature + signer.id.nodeId)
    }

    private func stateOf(_ tracker: DeliveryTracker, _ mid: Data) -> DeliveryState? {
        if case .found(let rec) = tracker.lookup(mid) { return rec.state }
        return nil
    }

    /// Author one DIRECT message and hand it to `peers` links.
    private func authorAndOffer(_ r: Rig, _ recipient: Local, peers: Int = 1,
                                admitted: Bool = true) throws -> Data {
        for i in 0..<peers { r.node.transportDidConnect(peerId: UUID()) }
        let frame = directedFrame(r.nextSeed())
        _ = r.node.dispatchDirect(frame, expectedRecipient: recipient.id.nodeId) { _, _ in admitted }
        return frame.msgId
    }

    // ------------------------------------------------------------ W01

    /// W01 -- the card's named mutation: an ATT success advances NOTHING durable.
    func testW01AttSuccessWithoutRemoteStorageLeavethItQueued() throws {
        let r = try rig()
        let recipient = try newLocal(0x31, 0x41)
        r.keys.put(recipient.id.nodeId, recipient.id.signingPublicKey)
        let mid = try authorAndOffer(r, recipient, peers: 2)

        XCTAssertEqual(stateOf(r.tracker, mid), .queuedDurably,
                       "the DURABLE state did not advance")
        let projection = r.node.deliveryProjection(mid)
        XCTAssertEqual(projection.label, .offered,
                       "the label saith OFFERED, never handed and never delivered")
        XCTAssertTrue(projection.retryable, "an offer NEVER clear retryability")
        XCTAssertFalse(projection.claimsDelivery)
        XCTAssertFalse(projection.claimsRelayCustody)
        XCTAssertEqual(projection.linkOffers, 2, "both admissions are ephemeral telemetry")
        XCTAssertFalse(projection.legacyHandedToRelay)
    }

    // ------------------------------------------------------------ W02

    /// W02 -- a refused send is NOT an offer: the label stayeth QUEUED.
    func testW02ARefusedSendLeavethTheLabelQueued() throws {
        let r = try rig()
        let recipient = try newLocal(0x32, 0x42)
        r.keys.put(recipient.id.nodeId, recipient.id.signingPublicKey)
        let mid = try authorAndOffer(r, recipient, peers: 2, admitted: false)

        XCTAssertEqual(stateOf(r.tracker, mid), .queuedDurably)
        let projection = r.node.deliveryProjection(mid)
        XCTAssertEqual(projection.label, .queued, "a refused offer is not an offer")
        XCTAssertEqual(projection.linkOffers, 0, "no ADMITTED offer standeth")
        XCTAssertEqual(projection.refusedOffers, 2, "the refusals are still visible as telemetry")
        XCTAssertFalse(r.node.linkOffers.anyAdmitted(mid))
        XCTAssertTrue(projection.retryable)
        XCTAssertFalse(projection.claimsDelivery)
    }

    // ------------------------------------------------------------ W03

    /// W03 -- the ONLY road to DELIVERED: an authenticated ACK from the intended
    /// recipient.
    func testW03TheIntendedRecipientsAckProducethDelivered() throws {
        let r = try rig()
        let recipient = try newLocal(0x33, 0x43)
        r.keys.put(recipient.id.nodeId, recipient.id.signingPublicKey)
        let mid = try authorAndOffer(r, recipient)
        XCTAssertEqual(r.node.deliveryProjection(mid).label, .offered)

        XCTAssertEqual(r.tracker.acknowledge(mid, ackOf(mid, recipient)), .applied)
        let projection = r.node.deliveryProjection(mid)
        XCTAssertEqual(projection.state, .acknowledgedByRecipient)
        XCTAssertEqual(projection.label, .delivered, "delivered, and only now")
        XCTAssertTrue(projection.claimsDelivery)
        XCTAssertFalse(projection.retryable)
    }

    // ------------------------------------------------------------ W04

    /// W04 -- a WRONG recipient's ACK is rejected; the label never claimeth delivery.
    func testW04AWrongRecipientsAckIsRejected() throws {
        let r = try rig()
        let recipient = try newLocal(0x34, 0x44)
        let stranger = try newLocal(0x35, 0x45)
        r.keys.put(recipient.id.nodeId, recipient.id.signingPublicKey)
        r.keys.put(stranger.id.nodeId, stranger.id.signingPublicKey)
        let mid = try authorAndOffer(r, recipient)

        let result = r.tracker.acknowledge(mid, ackOf(mid, stranger))
        XCTAssertNotEqual(result, .applied, "a stranger's ACK may not advance delivery")
        let projection = r.node.deliveryProjection(mid)
        XCTAssertEqual(projection.state, .queuedDurably)
        XCTAssertEqual(projection.label, .offered)
        XCTAssertFalse(projection.claimsDelivery)
    }

    // ------------------------------------------------------------ W05

    /// W05 -- a duplicate ACK is idempotent AND is not a second verification.
    func testW05ADuplicateAckIsIdempotent() throws {
        let r = try rig()
        let recipient = try newLocal(0x36, 0x46)
        r.keys.put(recipient.id.nodeId, recipient.id.signingPublicKey)
        let mid = try authorAndOffer(r, recipient)

        XCTAssertEqual(r.tracker.acknowledge(mid, ackOf(mid, recipient)), .applied)
        let callsAfterFirst = r.auth.calls
        let again = r.tracker.acknowledge(mid, ackOf(mid, recipient))
        XCTAssertEqual(again, .alreadyAcknowledged)
        XCTAssertEqual(r.auth.calls, callsAfterFirst,
                       "the authenticator is NOT consulted for a terminal row")
        XCTAssertEqual(r.node.deliveryProjection(mid).label, .delivered)
    }

    // ------------------------------------------------------------ W06

    /// W06 -- ACK versus cancel and expiry: a terminal committed state WINS.
    func testW06CancellationAndExpiryWinOverALateAck() throws {
        let r = try rig()
        let recipient = try newLocal(0x37, 0x47)
        r.keys.put(recipient.id.nodeId, recipient.id.signingPublicKey)

        let cancelled = try authorAndOffer(r, recipient)
        XCTAssertEqual(r.tracker.cancel(cancelled), .applied)
        XCTAssertNotEqual(r.tracker.acknowledge(cancelled, ackOf(cancelled, recipient)), .applied)
        let cancelledProjection = r.node.deliveryProjection(cancelled)
        XCTAssertEqual(cancelledProjection.label, .cancelled)
        XCTAssertFalse(cancelledProjection.claimsDelivery)
        XCTAssertFalse(cancelledProjection.retryable)

        let expired = try authorAndOffer(r, recipient)
        XCTAssertEqual(r.tracker.expire(expired), .applied)
        XCTAssertNotEqual(r.tracker.acknowledge(expired, ackOf(expired, recipient)), .applied)
        XCTAssertEqual(r.node.deliveryProjection(expired).label, .expired)
    }

    // ------------------------------------------------------------ W07

    /// W07 -- RESTART preserves honest status: the durable label surviveth, the
    /// EPHEMERAL offers do not.
    func testW07ARestartPreservethTheHonestStatus() throws {
        let r = try rig()
        let recipient = try newLocal(0x38, 0x48)
        r.keys.put(recipient.id.nodeId, recipient.id.signingPublicKey)
        let mid = try authorAndOffer(r, recipient, peers: 2)
        XCTAssertEqual(r.node.deliveryProjection(mid).label, .offered)

        let coldKeys = KeyTable()
        coldKeys.put(recipient.id.nodeId, recipient.id.signingPublicKey)
        let coldIdentity = try newLocal(0x39, 0x49)
        let cold = MeshNode(identity: coldIdentity.id, store: r.store,
                            deliveryTracker: DeliveryTracker(
                                repo: InMemoryDeliveryRepositoryForT43(r.store),
                                authenticator: Ed25519AckAuthenticator(resolver: coldKeys)),
                            sessions: SessionManager(identity: coldIdentity.id,
                                                     trustAuthority: FailClosedTrust()))
        let projection = cold.deliveryProjection(mid)
        XCTAssertEqual(projection.state, .queuedDurably, "the durable state surviveth")
        XCTAssertEqual(projection.label, .queued, "the offer is GONE: the label falleth back")
        XCTAssertEqual(projection.linkOffers, 0, "no offer surviveth the process")
        XCTAssertTrue(projection.retryable)
    }

    // ------------------------------------------------------------ W08

    /// W08 -- a LEGACY handed row is READ as queued, before any migration runneth.
    func testW08ALegacyHandedRowIsReadAsQueued() {
        let mid = msgId(80)
        XCTAssertTrue(LegacyHandedLabels.isLegacy(LegacyHandedLabels.legacyCode))
        let projection = LegacyHandedLabels.projectionForLegacyRow(mid, code: LegacyHandedLabels.legacyCode)
        XCTAssertEqual(projection.label, .queued,
                       "the legacy label is read as the queued estate it always was")
        XCTAssertEqual(projection.state, .queuedDurably)
        XCTAssertTrue(projection.retryable)
        XCTAssertFalse(projection.claimsRelayCustody)
        XCTAssertFalse(projection.claimsDelivery)
        XCTAssertTrue(projection.legacyHandedToRelay, "and the fact of the legacy label is PRESERVED")
        XCTAssertEqual(LegacyHandedLabels.projectionForLegacyRow(mid, code: 3).label, .delivered)
    }

    // ------------------------------------------------------------ W09

    /// W09 -- the MIGRATION rewriteth every legacy row through the T31 engine's
    /// own transaction, deleting nothing.
    func testW09TheLegacyMigrationRewritethThroughTheEngine() throws {
        let tables = [TableFingerprint(
            name: "delivery_state",
            columns: ["msg_id", "state", "ack_mode", "expected_recipient"],
            immutableColumns: ["msg_id", "expected_recipient"])]
        let history = NSMutableArray()
        let executor = InMemoryMigrationExecutor(
            startRevision: 1, initialTables: tables,
            initialImmutable: ["delivery_state": ["msg-1", "recipient-1"]])
        executor.withImmutableDomains(["delivery_state": ["msg_id", "expected_recipient"]])
        let engine = SchemaMigrationEngine(
            steps: [LegacyHandedLabels.step(history: history)],
            supportedMax: LegacyHandedLabels.toRevision,
            fingerprint: executor.observeFingerprint())
        let immutableBefore = executor.immutableDigest()
        let result = engine.migrate(currentVersion: 1, observed: executor.observeFingerprint(),
                                    executor: executor)
        guard case .upgraded(let from, let to) = result else {
            return XCTFail("the engine must advance the revision, got \(result)")
        }
        XCTAssertEqual(from, 1)
        XCTAssertEqual(to, LegacyHandedLabels.toRevision)
        XCTAssertTrue(executor.executed.contains {
            $0.contains("UPDATE delivery_state SET state = 1 WHERE state = 2")
        }, "the rewrite ran through the engine's own executor")
        XCTAssertEqual(history.count, 1, "the history list recordeth the legacy code once")
        XCTAssertEqual(executor.immutableDigest(), immutableBefore, "NOTHING immutable moved")
        XCTAssertTrue(executor.violations.isEmpty)

        let sql = LegacyHandedLabels.statements()
        XCTAssertEqual(sql.count, 1)
        XCTAssertTrue(sql[0].contains("= 1 WHERE state = 2"))
        XCTAssertFalse(sql[0].uppercased().contains("DELETE"))
        XCTAssertFalse(sql[0].uppercased().contains("DROP"))
    }

    // ------------------------------------------------------------ W10

    /// W10 -- NO RELAY RECEIPTS: nothing a relay observeth can raise a label above
    /// OFFERED, and custody is never claimed.
    func testW10NoRelayReceiptIsEverClaimed() throws {
        let r = try rig()
        let recipient = try newLocal(0x3A, 0x4A)
        r.keys.put(recipient.id.nodeId, recipient.id.signingPublicKey)
        let mid = try authorAndOffer(r, recipient, peers: 2)
        let projection = r.node.deliveryProjection(mid)
        XCTAssertFalse(projection.claimsRelayCustody, "a local admission is not custody")
        XCTAssertFalse(projection.claimsDelivery)
        XCTAssertEqual(projection.label, .offered)
        XCTAssertEqual(r.tracker.acknowledge(mid, ackOf(mid, recipient)), .applied)
        XCTAssertEqual(r.node.deliveryProjection(mid).label, .delivered)
    }

    // ------------------------------------------------------------ W11

    /// W11 -- the ledger is BOUNDED, drop-oldest, and refuseth a malformed key.
    func testW11TheOfferLedgerIsBoundedAndFailClosed() {
        let ledger = LinkOfferLedger(bound: 4)
        for i in 1...6 {
            ledger.record(msgId(i), linkId: Data(repeating: 9, count: 16),
                          admitted: true, atMonoMillis: Int64(i))
        }
        XCTAssertEqual(ledger.total(), 4, "the ledger stoppeth at its bound")
        XCTAssertEqual(ledger.droppedCount(), 2, "and the supersessions are counted")
        XCTAssertEqual(ledger.countFor(msgId(1)), 0, "the eldest two are gone")
        XCTAssertEqual(ledger.countFor(msgId(6)), 1, "the freshest four stand")
        XCTAssertEqual(ledger.admittedCountFor(msgId(6)), 1)
        XCTAssertEqual(ledger.refusedCountFor(msgId(6)), 0)
        ledger.clear()
        XCTAssertEqual(ledger.total(), 0)
    }

    // ------------------------------------------------------------ W12

    /// W12 -- an UNREADABLE row is never labelled queued: the projection falleth
    /// closed to UNAVAILABLE.
    func testW12AnUnreadableRowIsNeverLabelledQueued() throws {
        let r = try rig()
        let stranger = msgId(99)
        let projection = r.node.deliveryProjection(stranger)
        XCTAssertEqual(projection.label, .unavailable, "an absent row is UNAVAILABLE, never QUEUED")
        XCTAssertFalse(projection.retryable)
        XCTAssertFalse(projection.claimsDelivery)
        XCTAssertFalse(projection.claimsRelayCustody)
        XCTAssertEqual(projection.linkOffers, 0)
        // the SOS cancel surface reporteth the ephemeral truth, and a refusal is
        // typed rather than an empty success
        let recipient = try newLocal(0x3B, 0x4B)
        r.keys.put(recipient.id.nodeId, recipient.id.signingPublicKey)
        let mid = try authorAndOffer(r, recipient)
        XCTAssertTrue(r.node.linkOffers.anyAdmitted(mid),
                      "the offer ledger is the only source of 'copies may be out'")
        XCTAssertEqual(r.node.cancelSos(stranger), .unknownMessage,
                       "an unknown msg_id is a typed refusal, not a silent success")
    }
    // ------------------------------------------------------------ W13

    /// W13 -- the SOS arm carrieth the same law on this isle: a broadcast whose
    /// bytes a radio admitted standeth QUEUED_DURABLY (mode none, no recipient),
    /// and the send is an EPHEMERAL offer. The first campaign proved this witness
    /// necessary on the android twin; it is mirrored here so the SOS send site
    /// cannot re-acquire the custody advance unobserved on either isle.
    func testW13ABroadcastSendLeavethTheSosLabelQueued() throws {
        let r = try rig(0x51)
        r.node.transportDidConnect(peerId: UUID())
        r.node.transportDidConnect(peerId: UUID())

        let result = r.node.dispatchSos(payload: Data("medic".utf8)) { _, _ in true }
        XCTAssertEqual(result, .handedToRelays(2), "two links took the bytes")
        guard let mid = r.store.allHeldMsgIds().first else {
            return XCTFail("the broadcast must be durably held")
        }
        XCTAssertEqual(stateOf(r.tracker, mid), .queuedDurably,
                       "the DURABLE state did not advance")
        let projection = r.node.deliveryProjection(mid)
        XCTAssertEqual(projection.label, .offered)
        XCTAssertEqual(projection.linkOffers, 2, "both admissions are ephemeral telemetry")
        XCTAssertTrue(projection.retryable)
        XCTAssertFalse(projection.claimsDelivery)
        XCTAssertFalse(projection.claimsRelayCustody)
        if case .found(let rec) = r.tracker.lookup(mid) {
            XCTAssertEqual(rec.ackMode, .none, "and the row standeth none-mode")
        } else {
            XCTFail("the row must stand")
        }
    }
}

/// The minimal in-memory delivery repository this court requireth (the durable
/// CAS itself is T37's, exercised by its own courts).
internal final class InMemoryDeliveryRepositoryForT43: DeliveryRepository, @unchecked Sendable {
    private let store: InMemoryMessageStore
    private var records: [Data: DeliveryRecord] = [:]

    init(_ store: InMemoryMessageStore) { self.store = store }

    func get(_ msgId: Data) -> DeliveryLookup {
        if msgId.count != 16 { return .invalidArgument }
        if let rec = records[msgId] { return .found(rec) }
        guard let row = store.readDeliveryRow(msgId) else { return .notFound }
        guard let state = DeliveryState.fromPersistedCode(row.state) else { return .corrupt }
        guard let mode = AckMode.fromCode(row.ackMode) else { return .corrupt }
        let rec = DeliveryRecord(msgId: msgId, state: state, ackMode: mode,
                                 expectedRecipientNodeId: row.expectedRecipient)
        records[msgId] = rec
        return .found(rec)
    }

    func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
        if msgId.count != 16 { return .invalidArgument }
        switch get(msgId) {
        case .notFound:
            records[msgId] = DeliveryRecord(msgId: msgId, state: .queuedDurably, ackMode: ackMode,
                                            expectedRecipientNodeId: expectedRecipient)
            return .created
        case .found: return .alreadyQueuedSameBinding
        default: return .storageFailure
        }
    }

    func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult {
        // the durable row may have been written by the STORE (the outbound enqueue
        // pair), so the read path is consulted, never the local map alone
        guard case .found(let rec) = get(msgId) else { return .unknownMessage }
        let target: DeliveryState
        switch transition {
        case .expire: target = .expired
        case .cancel: target = .cancelledLocally
        case .markHanded: target = .handedToRelay
        }
        if rec.state == target { return .alreadyInTarget }
        if rec.state.isTerminal { return .rejectedState }
        records[msgId] = DeliveryRecord(msgId: rec.msgId, state: target, ackMode: rec.ackMode,
                                        expectedRecipientNodeId: rec.expectedRecipientNodeId)
        return .applied
    }

    func clear(_ msgId: Data) -> ClearResult { .alreadyAbsent }

    func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {
        if msgId.count != 16 || expectedRecipient.count != 16 { return .invalidArgument }
        guard case .found(let rec) = get(msgId) else { return .unknownMessage }
        if rec.state == .acknowledgedByRecipient { return .duplicateAuthenticatedAck }
        if rec.state.isTerminal { return .rejectedState }
        if rec.ackMode != .singleRecipient { return .notAckEligible }
        guard let bound = rec.expectedRecipientNodeId else { return .corrupt }
        if bound != expectedRecipient { return .rejectedState }
        records[msgId] = DeliveryRecord(msgId: rec.msgId, state: .acknowledgedByRecipient,
                                        ackMode: rec.ackMode,
                                        expectedRecipientNodeId: rec.expectedRecipientNodeId)
        return .applied
    }
}
