import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

/// Stage 4B.1 / B4: the iOS SOS dispatch must persist BEFORE any transport
/// operation and report a truthful [SosDispatchResult] (Android parity):
///   - persist fails -> `.notPersisted`, ZERO sends (exit before transport)
///   - persist succeeds + 0 peers -> `.queuedDurably` (durably held, no send)
///   - persist succeeds + N successful sends -> `.handedToRelays(N)`
///
/// These tests exercise the ungated `MeshNode.dispatchSos(payload:send:)` with an
/// injected send closure, so they never touch the lazy `ble` (which would need
/// CoreBluetooth) and never depend on `linkLayerReady` (which is false in
/// production and gates `broadcastSos`). The production `broadcastSos` body is
/// unreachable while `linkLayerReady=false`; these tests pin the logic so that
/// enabling M2-link later cannot expose the old bug (it ignored `router.ingest`'s
/// return and could BLE-send after a persistence failure). The capacity-rejection
/// (`rejectedCapacity`) path shares the same "do not send what you do not durably
/// hold" gate as the failure path and is covered at the store level by the B2
/// tests in `SqliteMessageStoreTests`.
final class MeshNodeSosDispatchTests: XCTestCase {
    /// IOS-02 step 5: A RELAY MUST BE TRUSTED TO BE ROUTE-ELIGIBLE. This witness bringeth a rig peer up the
    /// REAL way -- the radio's handle first, then the trust the matching confirmation establisheth -- so an
    /// arm that useth it modelleth the production sequence, not the audited shortcut (presence = routable).
    private func bringPeerUp(_ node: MeshNode, _ handle: UUID) {
        node.transportDidConnect(peerId: handle)
        node.trustedPeerDidConnect(nodeId: Self.trustedNodeId(for: handle), peerId: handle)
    }

    static func trustedNodeId(for handle: UUID) -> Data {
        withUnsafeBytes(of: handle.uuid) { Data($0) }
    }



    /// In-memory `DeliveryRepository` for tests that construct a `MeshNode` but
    /// do not exercise the ACK path (the SOS dispatch tests). The tracker is
    /// fail-closed regardless -- the authenticator is the production
    /// `UnresolvedRecipientKeyResolver` -- so no delivery is claimed. C6.1 /
    /// C6.3 / C6.4: `dispatchSos` enqueues with `AckMode.none` (SOS broadcast) then
    /// `markHandedToRelay` (a `transition(.markHanded)`), so this fake implements
    /// the full typed `DeliveryRepository` (get / enqueue / transition /
    /// acknowledgeBound / clear); the recipient is IMMUTABLE post-creation
    /// (state-only advance), mirroring `SqliteDeliveryRepository`.
    private final class InMemoryDeliveryRepository: DeliveryRepository {
        var map: [Data: DeliveryRecord] = [:]

        func get(_ msgId: Data) -> DeliveryLookup {
            if let rec = map[msgId] { return .found(rec) }
            return .notFound
        }
        func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
            guard bindingConsistent(ackMode: ackMode, expectedRecipient: expectedRecipient) else { return .corrupt }
            switch get(msgId) {
            case .notFound:
                map[msgId] = DeliveryRecord(msgId: msgId, state: .queuedDurably,
                                             ackMode: ackMode, expectedRecipientNodeId: expectedRecipient)
                return .created
            case .found(let rec):
                return classifyExisting(rec: rec, ackMode: ackMode, expectedRecipient: expectedRecipient)
            case .corrupt:
                return .corrupt
            case .storageFailure:
                return .storageFailure
            case .invalidArgument:
                return .invalidArgument
            }
        }
        func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult {
            let target: DeliveryState, validFroms: Set<DeliveryState>
            switch transition {
            case .markHanded: target = .handedToRelay; validFroms = [.queuedDurably]
            case .expire:     target = .expired;        validFroms = [.queuedDurably, .handedToRelay]
            case .cancel:     target = .cancelledLocally; validFroms = [.queuedDurably, .handedToRelay]
            }
            switch get(msgId) {
            case .notFound: return .unknownMessage
            case .corrupt: return .corrupt
            case .storageFailure: return .storageFailure
            case .invalidArgument: return .invalidArgument
            case .found(let rec):
                let s = rec.state
                if s == target { return .alreadyInTarget }
                if validFroms.contains(s) {
                    map[msgId] = DeliveryRecord(msgId: msgId, state: target,
                                                 ackMode: rec.ackMode,
                                                 expectedRecipientNodeId: rec.expectedRecipientNodeId)
                    return .applied
                }
                return .rejectedState
            }
        }
        func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {
            switch get(msgId) {
            case .notFound: return .unknownMessage
            case .corrupt: return .corrupt
            case .storageFailure: return .storageFailure
            case .invalidArgument: return .invalidArgument
            case .found(let rec):
                if rec.ackMode != .singleRecipient || rec.expectedRecipientNodeId != .some(expectedRecipient) {
                    return .unknownMessage
                }
                switch rec.state {
                case .acknowledgedByRecipient: return .duplicateAuthenticatedAck
                case .expired, .cancelledLocally: return .rejectedState
                case .queuedDurably, .handedToRelay:
                    map[msgId] = DeliveryRecord(msgId: msgId, state: .acknowledgedByRecipient,
                                                 ackMode: rec.ackMode,
                                                 expectedRecipientNodeId: rec.expectedRecipientNodeId)
                    return .applied
                default: return .rejectedState
                }
            }
        }
        func clear(_ msgId: Data) -> ClearResult {
            if map.removeValue(forKey: msgId) != nil { return .cleared }
            return .alreadyAbsent
        }

        private func classifyExisting(rec: DeliveryRecord, ackMode: AckMode,
                                      expectedRecipient: Data?) -> EnqueueResult {
            if rec.state.isTerminal { return .rejectedTerminalState }
            if rec.ackMode == ackMode && rec.expectedRecipientNodeId == expectedRecipient {
                return .alreadyQueuedSameBinding
            }
            return .conflictRecipient
        }

        private func bindingConsistent(ackMode: AckMode, expectedRecipient: Data?) -> Bool {
            switch ackMode {
            case .none: return expectedRecipient == nil
            case .singleRecipient:
                guard let r = expectedRecipient else { return false }
                return r.count == 16
            }
        }
    }

    /// Build a node with a fresh in-memory identity (CryptoKit default inits
    /// generate fresh keys on the macOS host -- no Keychain needed) and [store].
    /// A fail-closed `DeliveryTracker` (production `UnresolvedRecipientKeyResolver`
    /// over an in-memory repository) is injected so the node owns its tracker
    /// without touching SQLite -- the SOS dispatch path does not drive the ACK
    /// path (C6/C7 do); it only enqueues with `AckMode.none` +
    /// `markHandedToRelay`.
    private func makeNode(store: MessageStore) -> MeshNode {
        let identity = try! MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let journal = InMemoryDeliveryRepository()
        let tracker = DeliveryTracker(
            repo: journal,
            authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver()))
        // GS-SOS-001: the SOS road refuseth to offer an unauthenticated frame, so a
        // rig that SENDS distress carrieth a signing authority. SIMULATED, PUBLIC
        // material -- harness support, never a device result.
        let node = MeshNode(identity: identity, store: store, deliveryTracker: tracker)
        node.sosAuthority = SosTestAuthority()
        return node
    }

    /// The gate as this isle's composition builds it: a real class conforming to the protocol, never a lambda.
    private final class FixedWipeGate: WipeSensitiveUseGate, @unchecked Sendable {
        private let permits: Bool
        init(permits: Bool) { self.permits = permits }
        func allowsSensitiveUse() -> Bool { permits }
    }

    /// The SAME rig with a real gate over the SAME store and tracker -- *so the arm differeth from its control by the
    /// gate alone*, exactly as the round-696 read-road arms on this isle do.
    private func gatedNode(permits: Bool, store: MessageStore, tracker: DeliveryTracker) -> MeshNode {
        let node = MeshNode(
            identity: try! MeshIdentity.generateAndStore(keychain: InMemoryKeychain()),
            store: store,
            deliveryTracker: tracker,
            wipeGate: FixedWipeGate(permits: permits)
        )
        node.sosAuthority = SosTestAuthority()
        return node
    }

    /// *** GS-FINAL-003 (round 699) -- THE `Author` ARM IS GATED. ***
    ///
    /// **THE DEFECT, FOUND BY ENUMERATING THE DOOR RATHER THAN BY READING A ROAD: the command surface is ONE door with
    /// THREE arms, and TWO were gated.** *`retrySos` asketh the gate first (round 633) and `cancelSos` consulteth it;
    /// `dispatchSos` -- THE ARM THAT WRITETH -- did not.* **A PENDING WIPE MUST NOT BE HANDED NEW DURABLE WORK.** *The
    /// identical gap existed on Android, where `handleSosCommand` makes the asymmetry visible inside a single `when`.*
    ///
    /// **A BEHAVIOURAL RED, NOT A COMPILE ERROR:** against the pre-fix revision the refusing node AUTHORETH ANYWAY.
    ///
    /// AND THE POSITIVE CONTROL IS INSIDE THE ARM: the SAME rig with a PERMITTING gate must really author, so the arm
    /// cannot pass by refusing everything.
    func testGF003APendingWipeRefusethTheAuthorArm() throws {
        // THE POSITIVE CONTROL FIRST: with the gate OPEN the SAME rig really authors and really persists.
        let openStore = InMemoryMessageStore()
        let openTracker = DeliveryTracker(
            repo: InMemoryDeliveryRepository(),
            authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver()))
        let permitting = gatedNode(permits: true, store: openStore, tracker: openTracker)
        // *** A RELAY MUST BE REALLY UP, or the permitting rig reporteth `.queuedDurably` instead of
        // `.handedToRelays` -- and my FIRST DRAFT ASSERTED `handedToRelays` WITHOUT BRINGING A PEER UP, SO THE
        // POSITIVE CONTROL ITSELF FAILED. *That was the control doing its job: it refused to let the arm proceed on a
        // rig that could not demonstrate the allowed behaviour.* ***
        bringPeerUp(permitting, UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
        let allowed = permitting.dispatchSos(payload: Data("an open gate authors".utf8)) { _, _ in true }
        guard case .handedToRelays(let n) = allowed else {
            return XCTFail("*** THE PERMITTING RIG MUST REALLY AUTHOR, or the refusal below measures nothing. " +
                "Observed: \(allowed) ***")
        }
        XCTAssertGreaterThan(n, 0, "and it must really hand the call to a relay")

        // NOW A FRESH STORE, GATED CLOSED: nothing may be persisted and nothing offered.
        let closedStore = InMemoryMessageStore()
        let closedTracker = DeliveryTracker(
            repo: InMemoryDeliveryRepository(),
            authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver()))
        let refusing = gatedNode(permits: false, store: closedStore, tracker: closedTracker)
        bringPeerUp(refusing, UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!)
        var sends = 0
        let out = refusing.dispatchSos(payload: Data("a wipe must refuse this".utf8)) { _, _ in
            sends += 1; return true
        }
        guard case .failed(let reason) = out else {
            return XCTFail("*** A PENDING WIPE MUST REFUSE THE AUTHOR ARM. Observed: \(out) ***")
        }
        XCTAssertTrue(reason.contains("wipe"),
                      "*** AND THE REFUSAL MUST NAME THE WIPE, so a caller can tell it from an ordinary policy " +
                      "drop. Observed: \(reason) ***")
        XCTAssertTrue(closedStore.allHeldMsgIds().isEmpty,
                      "*** NOTHING MAY BE DURABLY HELD: a wipe that still accepts new frames is not a wipe. ***")
        XCTAssertEqual(sends, 0, "nor may any bytes be offered")
    }

    /// *** GS-FINAL-003 (round 699) -- THE CANCEL ROAD IS GATED, BECAUSE IT IS *ALSO A READ*. ***
    ///
    /// *It tombstones the row (a write) AND returneth a result DERIVED FROM THAT ROW* -- `.cancelled(wasRelayed:)`,
    /// `.alreadyCancelled(wasRelayed:)`, `.rejectedTerminal(state)`. **WHILE A WIPE IS PENDING THAT DISCLOSES DURABLE
    /// STATE FROM A STORE BEING ERASED** -- *the same class as `deliveryProjection`, hiding on a road whose NAME
    /// suggesteth a mutation.*
    ///
    /// **AND THE DIRECTION IS THE SAFE ONE TO GATE, MEASURED RATHER THAN ASSUMED:** the gate protecteth USE, not
    /// DESTRUCTION (*`deleteAllFrames()` is deliberately open, because the eraser must be able to erase*). I checked
    /// that the wipe's own path does not need this road (`cancelSos` appears in neither `CrashResumableWipe.swift` nor
    /// `MeshRuntime.swift`), so refusing here cannot deadlock the wipe.
    ///
    /// **A BEHAVIOURAL RED:** pre-fix the refusing node cancelled anyway and reported the row's real relayed state.
    func testGF003APendingWipeRefusethTheCancelRoad() throws {
        // SEED through a PERMITTING rig over a store and tracker we keep handles on.
        let store = InMemoryMessageStore()
        let tracker = DeliveryTracker(
            repo: InMemoryDeliveryRepository(),
            authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver()))
        let permitting = gatedNode(permits: true, store: store, tracker: tracker)
        bringPeerUp(permitting, UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!)
        let authored = permitting.dispatchSos(payload: Data("a call a wipe must hide".utf8)) { _, _ in true }
        guard case .handedToRelays = authored else {
            return XCTFail("the rig must really hold a call: \(authored)")
        }
        let mid = try XCTUnwrap(store.allHeldMsgIds().first, "the rig must really hold a frame")

        // THE POSITIVE CONTROL FIRST: the permitting rig cancels and reports the truth.
        let live = permitting.cancelSos(mid)
        guard case .cancelled = live else {
            return XCTFail("*** THE PERMITTING RIG MUST REALLY CANCEL, or the refusal below measures nothing. " +
                "Observed: \(live) ***")
        }

        // A SECOND CALL, THEN THE SAME STORE GATED CLOSED.
        let authored2 = permitting.dispatchSos(payload: Data("a second call".utf8)) { _, _ in true }
        guard case .handedToRelays = authored2 else {
            return XCTFail("the rig must hold a second call: \(authored2)")
        }
        let mid2 = try XCTUnwrap(store.allHeldMsgIds().last)

        let refusing = gatedNode(permits: false, store: store, tracker: tracker)
        let dark = refusing.cancelSos(mid2)
        guard case .storageFailure = dark else {
            return XCTFail("*** WHILE A WIPE IS PENDING THE CANCEL ROAD MUST NOT REPORT THE ROW's STATE -- not even " +
                "as a refusal taxonomy, because `.unknownMessage`/`.rejectedTerminal`/`.cancelled(wasRelayed:)` ALL " +
                "DISCLOSE WHAT THE ROW HELD. Observed: \(dark) ***")
        }
    }

    /// B4: persist fails -> `.notPersisted`, ZERO sends. The previous iOS
    /// `broadcastSos` ignored `router.ingest`'s return and could attempt BLE
    /// sends after a persistence failure; this gate exits before any transport op.
    func testDispatchSosPersistFailureReportsNotPersistedAndZeroSends() {
        let node = makeNode(store: AlwaysFailingStore())
        var sendCalls = 0
        let result = node.dispatchSos(payload: Data("SOS".utf8)) { _, _ in
            sendCalls += 1
            return true
        }
        XCTAssertEqual(result, .notPersisted)
        XCTAssertEqual(sendCalls, 0, "persistence failure must exit before any transport operation")
        XCTAssertEqual(node.store.allHeldMsgIds().count, 0, "nothing durably held")
    }

    /// B4: persist succeeds + zero peers -> `.queuedDurably`. The SOS is durably
    /// held (it reaches a peer on the next encounter via anti-entropy) and no
    /// send is attempted because there is no peer to send to.
    func testDispatchSosPersistSucceedsZeroPeersReportsQueuedDurably() {
        let node = makeNode(store: InMemoryMessageStore())
        var sendCalls = 0
        let result = node.dispatchSos(payload: Data("SOS".utf8)) { _, _ in
            sendCalls += 1
            return true
        }
        XCTAssertEqual(result, .queuedDurably)
        XCTAssertEqual(sendCalls, 0, "no peers -> no sends, but durably held")
        XCTAssertEqual(node.store.allHeldMsgIds().count, 1, "SOS durably held")
    }

    /// B4: persist succeeds + N successful sends -> `.handedToRelays(N)`. The SOS
    /// is also durably held (persist runs before the sends).
    func testDispatchSosPersistSucceedsWithNPeersReportsHandedToRelays() {
        let node = makeNode(store: InMemoryMessageStore())
        let peers = (0..<3).map { _ in UUID() }
        for p in peers { bringPeerUp(node, p) }
        var sentTo: [UUID] = []
        let result = node.dispatchSos(payload: Data("SOS".utf8)) { _, peer in
            sentTo.append(peer); return true
        }
        XCTAssertEqual(result, .handedToRelays(3))
        XCTAssertEqual(Set(sentTo), Set(peers))
        XCTAssertEqual(node.store.allHeldMsgIds().count, 1, "also durably held before sends")
    }

    /// B4: partial sends report the actual count (not the peer count, and not
    /// `.queuedDurably`). One peer of two accepts the record -> `.handedToRelays(1)`.
    func testDispatchSosPartialSendsReportActualCount() {
        let node = makeNode(store: InMemoryMessageStore())
        let p1 = UUID(), p2 = UUID()
        bringPeerUp(node, p1)
        node.transportDidConnect(peerId: p2)
        let result = node.dispatchSos(payload: Data("SOS".utf8)) { _, peer in
            peer == p1   // only p1 accepts the record
        }
        XCTAssertEqual(result, .handedToRelays(1))
    }
}

/// A `MessageStore` whose `persist` always fails (`.failedStorage`) -- exercises
/// the B4 "persist fails -> notPersisted, zero sends" gate without sqlite3.
private final class AlwaysFailingStore: MessageStore {
        /// GS-STORE-005 (round 281): DECLARED, NOT INHERITED (this double relied on the extension default too).
        @discardableResult
        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) -> ObservationLease.LeaseToken? { nil }
        func removeHeldSetObserver(_ lease: ObservationLease.LeaseToken) {}
    func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult { .failedStorage }
    func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data, localOriginNodeId: Data) -> OutboundEnqueueResult { .storageFailure }
    func allHeldOrderedByPriority() -> [FrameV2] { [] }
    func allHeldMsgIds() -> [Data] { [] }
    func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {}
    func forEachHeldMsgId(_ visit: (Data) -> Bool) {}
    var heldBytes: Int64 { 0 }
}