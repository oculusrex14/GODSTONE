// T42 readiness court (iOS isle) -- durable anti-entropy and forwarding.
//
// The card's defect on this isle: iOS carried an OPTIONAL store, so
// `Router.accept` could report a frame accepted on MEMORY ALONE, and it carried
// a forwarding closure the production receive path never drove. T41 wired the
// Android twin; this court replays the SAME traces on the iOS isle and asserts
// the same canonical outcomes.
//
// One reviewed scenario per witness; every assertion is positive and expected (a
// present side effect is captured, an absent one is CAPTURED as absence through
// a typed refusal or a zero census). The real MeshNode path is used throughout:
// real Router (with its required store), real SyncControlOwner, real store, real
// SyncPump on its own executor.
//
// Host tests prove no CoreBluetooth and no Data Protection behaviour; readiness
// stays false and no gate is closed.
import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

// The canonical trace the Android isle asserted (ReadinessT41Test.kt) -- the
// SAME ids, payload seeds, TTLs and priority order, so the two isles are
// replaying ONE trace and not two lookalikes. `testW15` verifieth the agreement
// by reading the Android court's own source.
private let traceMsgIdSeedA = 2
private let traceMsgIdSeedB = 6
private let tracePayloadSeed = 0x41

final class ReadinessT42Tests: XCTestCase {
    private let rng = SystemRandomNumberGenerator()

    // ------------------------------------------------------------ the world

    private func nodeId(_ seed: Int, _ salt: Int) -> Data {
        Data((0..<16).map { i -> UInt8 in
            if i < 4 { return UInt8((seed >> (8 * (3 - i))) & 0xFF) }
            return UInt8((i * 17 + salt * 3 + 1) & 0xFF)
        })
    }

    private func msgId(_ seed: Int) -> Data { Data((0..<16).map { UInt8(($0 + seed) & 0xFF) }) }

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

    private struct Local { let id: MeshIdentity; let seed: Data }

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage[tag] = nil }
    }

    /// A delegating store whose persist can be REFUSED, so "send before persist"
    /// is witnessable at the real seam.
    private final class RefusingStore: MessageStore, @unchecked Sendable {
        @discardableResult
        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) -> ObservationLease.LeaseToken? { nil }
        func removeHeldSetObserver(_ lease: ObservationLease.LeaseToken) {}
        let raw: InMemoryMessageStore
        var refusePersist = false
        init(_ raw: InMemoryMessageStore) { self.raw = raw }
        func refuseAll() { refusePersist = true }

        func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult {
            refusePersist ? .failedStorage : raw.persist(frame, receivedFrom: receivedFrom)
        }
        func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data,
                                   localOriginNodeId: Data) -> OutboundEnqueueResult {
            raw.enqueueDirectOutbound(frame, expectedRecipient: expectedRecipient,
                                      localOriginNodeId: localOriginNodeId)
        }
        func allHeldOrderedByPriority() -> [FrameV2] { raw.allHeldOrderedByPriority() }
        func allHeldMsgIds() -> [Data] { raw.allHeldMsgIds() }
        func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {
            raw.forEachHeldOrderedByPriority(visit)
        }
        func forEachHeldMsgId(_ visit: (Data) -> Bool) { raw.forEachHeldMsgId(visit) }
        var heldBytes: Int64 { raw.heldBytes }
        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) {}
    }

    private final class DeliveryRepo: DeliveryRepository, @unchecked Sendable {
        private var rows: [Data: DeliveryRecord] = [:]
        func get(_ msgId: Data) -> DeliveryLookup {
            if msgId.count != 16 { return .invalidArgument }
            guard let rec = rows[msgId] else { return .notFound }
            return .found(rec)
        }
        func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
            if msgId.count != 16 { return .invalidArgument }
            if case .notFound = get(msgId) {
                rows[msgId] = DeliveryRecord(msgId: msgId, state: .queuedDurably, ackMode: ackMode,
                                             expectedRecipientNodeId: expectedRecipient)
                return .created
            }
            return .alreadyQueuedSameBinding
        }
        func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult { .applied }
        func clear(_ msgId: Data) -> ClearResult { .alreadyAbsent }
        func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {
            .unknownMessage
        }
    }

    private final class Peer {
        let label: String
        let id: Data
        /// The 4-byte optimization hint -- NEVER a route to a recipient.
        let hint: Data
        let node: MeshNode
        let raw: InMemoryMessageStore
        let store: RefusingStore
        init(label: String, id: Data, hint: Data, node: MeshNode, raw: InMemoryMessageStore,
             store: RefusingStore) {
            self.label = label; self.id = id; self.hint = hint
            self.node = node; self.raw = raw; self.store = store
        }
        var pump: SyncPump { node.pumpFor() }
    }

    private func peer(_ label: String, _ id: Data, seedByte: UInt8, xByte: UInt8) throws -> Peer {
        let local = try newLocal(seedByte, xByte)
        let raw = InMemoryMessageStore()
        let store = RefusingStore(raw)
        let tracker = DeliveryTracker(repo: DeliveryRepo(),
                                      authenticator: Ed25519AckAuthenticator(resolver: FailClosedKeys()))
        let node = MeshNode(identity: local.id, store: store, deliveryTracker: tracker,
                            sessions: SessionManager(identity: local.id,
                                                     trustAuthority: FailClosedTrust()))
        return Peer(label: label, id: id, hint: Data(local.id.nodeHint), node: node,
                    raw: raw, store: store)
    }

    private final class FailClosedKeys: RecipientKeyResolver, @unchecked Sendable {
        func publicSigningKey(forNodeId nodeId: Data) -> Data? { nil }
    }
    private final class FailClosedTrust: PeerBindingTrustAuthority, @unchecked Sendable {
        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            .storageFailure
        }
    }

    private struct World {
        let a: Peer
        let r: Peer
        let b: Peer

        /// A TRUSTED relation comes up (a node id, never a transport UUID).
        func linkUp(_ x: Peer, _ y: Peer) {
            x.node.trustedPeerDidConnect(nodeId: y.id)
            y.node.trustedPeerDidConnect(nodeId: x.id)
        }
        func linkDown(_ x: Peer, _ y: Peer) {
            x.node.trustedPeerDidDisconnect(nodeId: y.id)
            y.node.trustedPeerDidDisconnect(nodeId: x.id)
        }
        /// One epidemic turn: everything `from` has for `to` is delivered to it.
        @discardableResult
        func round(_ from: Peer, _ to: Peer) -> [FrameV2] {
            let frames = from.node.drainSyncFrames(for: to.id)
            for f in frames { _ = to.node.ingestInbound(f, receivedFrom: from.id) }
            return frames
        }
        func rounds(_ from: Peer, _ to: Peer, _ times: Int = 4) -> [FrameV2] {
            var seen: [FrameV2] = []
            for _ in 0..<times { seen.append(contentsOf: round(from, to)) }
            return seen
        }
    }

    private func world() throws -> World {
        World(a: try peer("A", nodeId(0xA1, 0x11), seedByte: 0x31, xByte: 0x41),
              r: try peer("R", nodeId(0xA2, 0x22), seedByte: 0x32, xByte: 0x42),
              b: try peer("B", nodeId(0xA3, 0x33), seedByte: 0x33, xByte: 0x43))
    }

    /// A production MESSAGE: SEALED, DIRECT priority, the production initial TTL.
    private func messageFrame(_ seed: Int, ttl: UInt8 = FrameV2.defaultTtl,
                              hop: UInt8 = 0, priority: Priority = .direct) -> FrameV2 {
        FrameV2(type: .message, msgId: msgId(seed), routingTag: Data(repeating: 3, count: 4),
                ttl: ttl, hopCount: hop,
                flags: FrameV2.Flags.sealed | UInt16(priority.rawValue << 8),
                payload: Data((0..<24).map { UInt8(($0 + seed) & 0xFF) }))
    }

    private func frameWithPriority(_ id: Data, _ priority: Priority) -> FrameV2 {
        FrameV2(type: .message, msgId: id, routingTag: Data(repeating: 5, count: 4),
                ttl: FrameV2.defaultTtl, hopCount: 0,
                flags: FrameV2.Flags.sealed | UInt16(priority.rawValue << 8),
                payload: Data(repeating: UInt8(tracePayloadSeed), count: 16))
    }

    private func heldIds(_ p: Peer) -> Set<Data> { Set(p.raw.allHeldMsgIds()) }

    private func isOriginAck(_ v: DispatchVerdict) -> Bool {
        if case .ack(.originVerification) = v { return true }
        return false
    }

    // ------------------------------------------------------------ W01

    /// W01 -- the named falsification, second limb: a trusted relation that comes
    /// up is REGISTERED and scheduled, and one that goes away is cancelled.
    func testW01ATrustedPeerGetsARegisteredScheduler() throws {
        let w = try world()
        XCTAssertEqual(w.a.pump.registeredCount(), 0)
        let before = w.a.pump.turn(peer: w.b.id)
        XCTAssertEqual(before.total, 0, "an unregistered peer yields NOTHING")
        XCTAssertEqual(before.refusals.keys.first, .notRegistered)

        w.linkUp(w.a, w.b)
        XCTAssertEqual(w.a.pump.registeredCount(), 1)
        XCTAssertTrue(w.a.pump.isRegistered(w.b.id))
        let after = w.a.node.drainSyncFrames(for: w.b.id)
        XCTAssertGreaterThanOrEqual(after.count, 1, "a DIGEST is due at the initial encounter")
        XCTAssertEqual(after.first?.type, .digest)
        XCTAssertEqual(w.a.pump.relationFor(w.b.id)?.digestsSent, 1)

        w.linkDown(w.a, w.b)
        XCTAssertFalse(w.a.pump.isRegistered(w.b.id))
        XCTAssertEqual(w.a.pump.registeredCount(), 0)
        XCTAssertEqual(w.a.pump.turn(peer: w.b.id).total, 0)
    }

    // ------------------------------------------------------------ W02

    /// W02 -- the required three-node trace: A -> R -> B through the REAL
    /// dispatch, with the forward copy carrying TTL-1 / hop+1 exactly once.
    func testW02TheThreeNodeTraceForwardsAfterDurableAcceptance() throws {
        let w = try world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        let authored = messageFrame(traceMsgIdSeedA)

        XCTAssertTrue(w.r.node.ingestInbound(authored, receivedFrom: w.a.id),
                      "R durably accepted it")
        XCTAssertTrue(heldIds(w.r).contains(authored.msgId))
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.b.id), 1, "one copy queued for B")
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.a.id), 0, "never echoed back to A")

        let sent = w.rounds(w.r, w.b, 2).filter { $0.type == .message }
        XCTAssertEqual(sent.count, 1, "exactly one forward copy")
        let copy = try XCTUnwrap(sent.first)
        XCTAssertEqual(copy.ttl, FrameV2.defaultTtl - 1)
        XCTAssertEqual(copy.hopCount, 1)
        XCTAssertEqual(copy.msgId, authored.msgId)
        XCTAssertEqual(copy.payload, authored.payload, "the authored payload is preserved byte for byte")
        XCTAssertEqual(copy.flags, authored.flags, "the flags travel unaltered")
        XCTAssertTrue(heldIds(w.b).contains(authored.msgId), "B now holds it")
    }

    // ------------------------------------------------------------ W03

    /// W03 -- the card's named semantic negative: "Persist optional/try? then
    /// report accepted: store-failure integration test fails." A store that
    /// REFUSES the persist forwards nothing, holds nothing and reports nothing.
    func testW03ARefusedPersistForwardsNothingAndReportsNothing() throws {
        let w = try world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        w.r.store.refuseAll()
        let authored = messageFrame(traceMsgIdSeedB)
        XCTAssertFalse(w.r.node.ingestInbound(authored, receivedFrom: w.a.id),
                       "the store refused it: the frame is NOT accepted")
        XCTAssertFalse(heldIds(w.r).contains(authored.msgId), "nothing was held")
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.b.id), 0, "NOTHING was queued")
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.a.id), 0)
        XCTAssertEqual(w.rounds(w.r, w.b).filter { $0.type == .message }.count, 0,
                       "and nothing was sent")
    }

    // ------------------------------------------------------------ W04

    /// W04 -- memory-only acceptance is REJECTED by construction: an absent store
    /// refuses the router's construction, and a held duplicate is never
    /// re-accepted just because the seen window forgot the id.
    func testW04MemoryOnlyAcceptanceIsRejected() throws {
        // (a) absent store refuses construction
        XCTAssertNil(Router.make(selfNodeId: nodeId(0xC1, 0x51), store: nil),
                     "an absent store must refuse construction")
        let withStore = Router.make(selfNodeId: nodeId(0xC1, 0x51), store: InMemoryMessageStore())
        XCTAssertNotNil(withStore, "a store-bearing router constructs")

        // (b) a persist that FAILS is not an acceptance (the memory-only arm)
        let router = Router(selfNodeId: nodeId(0xC2, 0x52), store: FailingStore())
        XCTAssertFalse(router.ingest(messageFrame(70), isAddressedToMe: false, receivedFrom: Data()),
                       "a failed persist is a refusal, never a memory-only success")
        XCTAssertTrue(router.drain(limit: 8).isEmpty, "and it is not forwarded")

        // (c) the durable store, not the seen window, decideth a duplicate
        let store = InMemoryMessageStore()
        let capRouter = Router(selfNodeId: nodeId(0xC3, 0x53), store: store, seenCacheCapacity: 2)
        let f1 = messageFrame(71), f2 = messageFrame(72), f3 = messageFrame(73)
        XCTAssertTrue(capRouter.ingest(f1, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertTrue(capRouter.ingest(f2, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertTrue(capRouter.ingest(f3, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertFalse(capRouter.ingest(f1, isAddressedToMe: false, receivedFrom: Data()),
                       "the window's eviction cannot resurrect a held frame")
        XCTAssertEqual(Set(store.allHeldMsgIds()), Set([f1.msgId, f2.msgId, f3.msgId]))
    }

    private final class FailingStore: MessageStore, @unchecked Sendable {
        @discardableResult
        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) -> ObservationLease.LeaseToken? { nil }
        func removeHeldSetObserver(_ lease: ObservationLease.LeaseToken) {}
        func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult { .failedStorage }
        func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data,
                                   localOriginNodeId: Data) -> OutboundEnqueueResult { .storageFailure }
        func allHeldOrderedByPriority() -> [FrameV2] { [] }
        func allHeldMsgIds() -> [Data] { [] }
        func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {}
        func forEachHeldMsgId(_ visit: (Data) -> Bool) {}
        var heldBytes: Int64 { 0 }
        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) {}
    }

    // ------------------------------------------------------------ W05

    /// W05 -- disjoint held sets CONVERGE on this isle too, through the real
    /// DIGEST / inventory / WANT protocol driven by the pump's turns.
    func testW05DisjointHeldSetsConverge() throws {
        let w = try world()
        w.linkUp(w.r, w.b)
        let mine = (1...3).map { msgId(700 + $0) }
        let theirs = (1...3).map { msgId(720 + $0) }
        for (i, id) in mine.enumerated() {
            XCTAssertEqual(w.r.store.persist(frameWithPriority(id, .direct),
                                             receivedFrom: Data(repeating: 0, count: 16)),
                           .heldNew, "seed \(i)")
        }
        for (i, id) in theirs.enumerated() {
            XCTAssertEqual(w.b.store.persist(frameWithPriority(id, .direct),
                                             receivedFrom: Data(repeating: 0, count: 16)),
                           .heldNew, "seed \(i)")
        }
        XCTAssertTrue(heldIds(w.r).isDisjoint(with: heldIds(w.b)), "the sets are disjoint")

        for _ in 0..<6 {
            w.round(w.r, w.b)
            w.round(w.b, w.r)
        }
        XCTAssertTrue(theirs.allSatisfy { heldIds(w.r).contains($0) }, "R received what it lacked")
        XCTAssertTrue(mine.allSatisfy { heldIds(w.b).contains($0) }, "B received what it lacked")
        XCTAssertTrue(heldIds(w.r).isSuperset(of: heldIds(w.b)) &&
                      heldIds(w.b).isSuperset(of: heldIds(w.r)), "both hold the union")
    }

    // ------------------------------------------------------------ W06

    /// W06 -- the same trace replayed in the REVERSE direction (B authors, the
    /// relay carries it back to A): the road is symmetric.
    func testW06TheSameTraceReplaysInReverse() throws {
        let w = try world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        let authored = messageFrame(traceMsgIdSeedA)
        XCTAssertTrue(w.r.node.ingestInbound(authored, receivedFrom: w.b.id),
                      "the relay accepted it from B")
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.a.id), 1, "one copy queued for A")
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.b.id), 0, "never echoed back to B")
        let sent = w.rounds(w.r, w.a, 2).filter { $0.type == .message }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.ttl, FrameV2.defaultTtl - 1)
        XCTAssertEqual(sent.first?.hopCount, 1)
        XCTAssertTrue(heldIds(w.a).contains(authored.msgId))
    }

    // ------------------------------------------------------------ W07

    /// W07 -- a forced bloom false positive cannot suppress a fetch on this isle
    /// either: the bloom is a hint, the exact page driveth the WANT.
    func testW07AForcedBloomFalsePositiveDoesNotSuppressAFetch() throws {
        let w = try world()
        w.linkUp(w.r, w.b)
        let missing = msgId(800)
        XCTAssertEqual(w.r.store.persist(frameWithPriority(missing, .direct),
                                         receivedFrom: Data(repeating: 0, count: 16)), .heldNew)

        // (a) a SATURATED bloom claims everything: a bloom-based offer would skip it
        let saturated = BloomDigest([UInt8](repeating: 0xFF, count: BloomDigest.sizeBytes))
        XCTAssertTrue(saturated.mightContain(missing))
        let bloomBased = w.r.node.router.framesPeerLacks(saturated, limit: 32)
        XCTAssertTrue(bloomBased.allSatisfy { $0.msgId != missing },
                      "a bloom-based offer would suppress it")

        // (b) the exact road delivers it anyway
        for _ in 0..<6 {
            w.round(w.r, w.b)
            w.round(w.b, w.r)
        }
        XCTAssertTrue(heldIds(w.b).contains(missing),
                      "the exact road delivered what the bloom suppressed")
        let stored = try XCTUnwrap(w.r.raw.allHeldOrderedByPriority().first { $0.msgId == missing })
        let arrived = try XCTUnwrap(w.b.raw.allHeldOrderedByPriority().first { $0.msgId == missing })
        XCTAssertEqual(arrived.payload, stored.payload, "byte-identical to the stored original")
        XCTAssertEqual(arrived.flags, stored.flags)
    }

    // ------------------------------------------------------------ W08

    /// W08 -- TTL 0/1 and the hop ceiling refuse BY NAME, and no copy is queued.
    func testW08TtlExhaustionAndTheHopCeilingRefuseByName() throws {
        let w = try world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        XCTAssertEqual(w.r.pump.enqueueForward(messageFrame(50, ttl: 1), fromPeer: w.a.id),
                       .refused(.ttlExhausted))
        XCTAssertEqual(w.r.pump.enqueueForward(messageFrame(51, ttl: 0), fromPeer: w.a.id),
                       .refused(.ttlExhausted))
        XCTAssertEqual(w.r.pump.enqueueForward(messageFrame(52, ttl: 12, hop: FrameV2.maxTtl),
                                               fromPeer: w.a.id),
                       .refused(.hopLimit))
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.b.id), 0, "no refusal queued anything")

        // a control frame and an ACK never travel the message road
        let ping = FrameV2(type: .ping, msgId: msgId(53), routingTag: Data(repeating: 0, count: 4),
                           ttl: 0, hopCount: 0, flags: 0, payload: Data(repeating: 0, count: 8))
        XCTAssertEqual(w.r.pump.enqueueForward(ping, fromPeer: w.a.id), .notForwardable)

        // and a frame whose ONLY registered peer is the one it came from
        let solo = try peer("S", nodeId(0xA9, 0x99), seedByte: 0x91, xByte: 0x92)
        solo.node.trustedPeerDidConnect(nodeId: w.b.id)
        XCTAssertEqual(solo.pump.enqueueForward(messageFrame(54), fromPeer: w.b.id),
                       .refused(.noOtherPeer))
    }

    // ------------------------------------------------------------ W09

    /// W09 -- relation loss cancels the schedule and drains the peer's queue, and
    /// the DURABLE estate survives so a reconnect resumes.
    func testW09RelationLossCancelsTheScheduleAndTheEstateSurvives() throws {
        let w = try world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        let authored = messageFrame(60)
        XCTAssertTrue(w.r.node.ingestInbound(authored, receivedFrom: w.a.id))
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.b.id), 1)
        w.linkDown(w.r, w.b)
        XCTAssertFalse(w.r.pump.isRegistered(w.b.id))
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.b.id), 0,
                       "the queue released with the relation")
        XCTAssertTrue(heldIds(w.r).contains(authored.msgId), "the DURABLE frame survives")
        XCTAssertTrue(w.r.node.drainSyncFrames(for: w.b.id).isEmpty,
                      "a cancelled relation emits no sync frame")

        w.linkUp(w.r, w.b)
        XCTAssertTrue(w.r.pump.isRegistered(w.b.id))
        let later = messageFrame(61)
        XCTAssertTrue(w.r.node.ingestInbound(later, receivedFrom: w.a.id))
        let sent = w.rounds(w.r, w.b, 2).filter { $0.type == .message }
        XCTAssertEqual(sent.count, 1, "the new frame travels after the reconnect")
        XCTAssertEqual(sent.first?.msgId, later.msgId)
    }

    // ------------------------------------------------------------ W10

    /// W10 -- the forward leg is strict priority BY THE CANONICAL FLAG BITS, in
    /// whatever arrival order.
    func testW10TheForwardLegIsStrictlyPriorityOrdered() throws {
        let w = try world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        let bulk = frameWithPriority(msgId(1200), .bulk)
        let broadcast = frameWithPriority(msgId(1201), .broadcast)
        let group = frameWithPriority(msgId(1202), .group)
        let direct = frameWithPriority(msgId(1203), .direct)
        let sos = frameWithPriority(msgId(1204), .sos)
        for f in [bulk, broadcast, group, direct, sos] {
            XCTAssertEqual(w.r.pump.enqueueForward(f, fromPeer: w.a.id), .queued(peers: 1))
        }
        let batch = w.r.pump.turn(peer: w.b.id)
        XCTAssertEqual(batch.copies.map { $0.priority },
                       [.sos, .direct, .group, .broadcast, .bulk],
                       "SOS, DIRECT, GROUP, BROADCAST, BULK -- whatever the arrival order")

        // ... and the ROUTER's own relay queue useth the same canonical bits: a
        // type table would sort a DIRECT and a GROUP message alike.
        let store = InMemoryMessageStore()
        let router = Router(selfNodeId: nodeId(0xD1, 0x61), store: store)
        let dir = frameWithPriority(msgId(1210), .direct)
        let grp = frameWithPriority(msgId(1211), .group)
        let blk = frameWithPriority(msgId(1212), .bulk)
        for f in [blk, grp, dir] {
            XCTAssertTrue(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
        }
        XCTAssertEqual(router.drain(limit: 8).map { Priority.fromFlags($0.flags) },
                       [.direct, .group, .bulk],
                       "the relay queue is ordered by the CANONICAL priority bits")
    }

    // ------------------------------------------------------------ W11

    /// W11 -- the queue is BOUNDED with counted supersessions, and one turn is
    /// bounded: a flood can never grow the pump without limit.
    func testW11TheForwardQueueAndTheTurnAreBounded() throws {
        let w = try world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        for i in 1...(syncMaxForwardQueue + 25) {
            XCTAssertEqual(w.r.pump.enqueueForward(messageFrame(2000 + i), fromPeer: w.a.id),
                           .queued(peers: 1))
        }
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.b.id), syncMaxForwardQueue)
        XCTAssertGreaterThanOrEqual(w.r.pump.overflowCount(w.b.id), 25)
        let turn = w.r.pump.turn(peer: w.b.id)
        XCTAssertLessThanOrEqual(turn.forwarded, syncMaxForwardPerTurn)
    }

    // ------------------------------------------------------------ W12

    /// W12 -- the typed dispatch statute on this isle: control before ACK before
    /// the generic road, and an unsupported type REFUSED BY NAME.
    func testW12TheTypedDispatcherRoutethInTheStatuteOrder() throws {
        let w = try world()
        let dispatcher = FrameDispatcher(owner: w.a.node.syncControlOwner,
                                         ackAuthority: { nil },
                                         acknowledgeHistorically: { _ in .unknownMessage })
        // control first
        let ping = FrameV2(type: .ping, msgId: msgId(11), routingTag: Data(repeating: 0, count: 4),
                           ttl: 0, hopCount: 0, flags: 0, payload: Data())
        XCTAssertEqual(dispatcher.dispatch(ping, from: w.b.id).dispatchClass, .control)
        // ACK second
        let ack = FrameV2(type: .ack, msgId: msgId(13), routingTag: Data(repeating: 0, count: 4),
                          ttl: 12, hopCount: 0, flags: 0, payload: Data(repeating: 0, count: 80))
        XCTAssertEqual(dispatcher.dispatch(ack, from: w.b.id).dispatchClass, .ack)
        XCTAssertTrue(isOriginAck(dispatcher.dispatch(ack, from: w.b.id)),
                      "with no ack_frames namespace the historical point-to-point face standeth")
        // then the generic road
        XCTAssertEqual(dispatcher.dispatch(messageFrame(14), from: w.b.id).dispatchClass, .message)
        let sos = FrameV2(type: .sos, msgId: msgId(15), routingTag: Data(repeating: 0, count: 4),
                          ttl: 12, hopCount: 0, flags: 0, payload: Data(repeating: 0, count: 8))
        XCTAssertEqual(dispatcher.dispatch(sos, from: w.b.id).dispatchClass, .sos)
        // and everything else refused by name
        let goodbye = FrameV2(type: .goodbye, msgId: msgId(16), routingTag: Data(repeating: 0, count: 4),
                              ttl: 12, hopCount: 0, flags: 0, payload: Data())
        XCTAssertEqual(dispatcher.dispatch(goodbye, from: w.b.id).dispatchClass, .refused)
        if case .refused(let reason, _) = dispatcher.dispatch(goodbye, from: w.b.id) {
            XCTAssertEqual(reason, .unsupportedType)
        } else {
            XCTFail("a GOODBYE must be refused by name")
        }
        // the real MeshNode honours the same statute and persists nothing
        XCTAssertFalse(w.a.node.ingestInbound(goodbye, receivedFrom: w.b.id))
        XCTAssertTrue(heldIds(w.a).isEmpty, "the refused frame was NOT persisted")
    }

    // ------------------------------------------------------------ W13

    /// W13 -- the recipient road is the INBOX, never the 4-byte hint: a directed
    /// message whose tag does NOT match the local hint is still carried durably
    /// and still offered to the verified inbox.
    func testW13TheHintNeverRoutethARecipient() throws {
        let w = try world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)   // the relay's other trusted peer
        // a directed message whose routing tag is deliberately NOT our hint
        let foreignTag = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let directed = FrameV2(type: .message, msgId: msgId(900), routingTag: foreignTag,
                               ttl: FrameV2.defaultTtl, hopCount: 0,
                               flags: FrameV2.Flags.sealed | UInt16(Priority.direct.rawValue << 8),
                               payload: Data(repeating: 0x11, count: 40))
        XCTAssertNotEqual(foreignTag, w.r.hint, "the fixture's tag really is foreign")
        XCTAssertTrue(w.r.node.ingestInbound(directed, receivedFrom: w.a.id),
                      "the mismatched tag did not bar the durable road")
        XCTAssertTrue(heldIds(w.r).contains(directed.msgId),
                      "and it is durably held: the tag is a HINT, not a route")
        // the tag's only honest power is suppressing a needless relay
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.b.id), 1,
                       "and the relay leg still carried it onward")
    }

    // ------------------------------------------------------------ W14

    /// W14 -- the pump's turn runneth on its OWN executor and is serialized:
    /// concurrent turns never interleave, so no caller's thread holds the
    /// monitor across the store read.
    func testW14TheTurnRunnethOnThePumpsOwnExecutor() throws {
        let w = try world()
        w.linkUp(w.a, w.r)
        w.linkUp(w.r, w.b)
        for i in 1...8 {
            _ = w.r.pump.enqueueForward(messageFrame(3000 + i), fromPeer: w.a.id)
        }
        let group = DispatchGroup()
        let counter = NSLock()
        var handedTotal = 0
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                let batch = w.r.pump.turn(peer: w.b.id)
                counter.lock(); handedTotal += batch.forwarded; counter.unlock()
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(handedTotal, 8, "each copy was handed out EXACTLY once across all turns")
        XCTAssertEqual(w.r.pump.pendingForwardCount(w.b.id), 0, "and the queue drained exactly")
    }

    // ------------------------------------------------------------ W15

    /// W15 -- the CROSS-ISLE agreement: this court replays ONE trace, not a
    /// lookalike. The Android twin's own source is read and its canonical
    /// constants are asserted to be the ones this trace uses, so a drift on
    /// either isle fails here.
    func testW15TheSameTraceIsReplayedOnBothIsles() throws {
        // the mirror lives at ios/Packages/GodstoneFoundation/Tests/... and the
        // canonical file at ios/Godstone/Tests/..., so the root is found by
        // CONTENT (a directory holding both android/ and docs/) rather than by
        // counting path components -- the T42 lesson from the first run
        var repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var hops = 0
        while repo.path != "/" && hops < 16 {
            let fm = FileManager.default
            if fm.fileExists(atPath: repo.appendingPathComponent("android").path),
               fm.fileExists(atPath: repo.appendingPathComponent("docs").path) {
                break
            }
            repo.deleteLastPathComponent()
            hops += 1
        }
        let androidCourt = repo.appendingPathComponent(
            "android/mesh/src/test/java/io/godstone/mesh/readiness/ReadinessT41Test.kt")
        guard let text = try? String(contentsOf: androidCourt, encoding: .utf8) else {
            return XCTFail("the Android twin's court must be readable: \(androidCourt.path)")
        }
        // the canonical facts both isles must assert identically
        XCTAssertTrue(text.contains("FrameV2.DEFAULT_TTL - 1"),
                      "the Android twin requireth TTL-1 on the forward copy")
        XCTAssertTrue(text.contains("Assert.assertEquals(1, sent[0].hopCount)"),
                      "the Android twin requireth hop 1")
        XCTAssertTrue(text.contains("Priority.SOS, Priority.DIRECT, Priority.GROUP, Priority.BROADCAST, Priority.BULK"),
                      "the Android twin requireth the canonical priority order")
        XCTAssertTrue(text.contains("messageFrame(2)"),
                      "the Android twin's three-node trace useth msgId seed 2, as this court doth")
        XCTAssertTrue(text.contains("test_w03_a_refused_persist_forwards_nothing"),
                      "the Android twin carrieth the same store-failure trace")
        // ... and this court's own constants are the ones named above
        XCTAssertEqual(traceMsgIdSeedA, 2)
        XCTAssertEqual(messageFrame(traceMsgIdSeedA).ttl, FrameV2.defaultTtl)
    }

    // ------------------------------------------------------------ W16

    /// W16 -- an ACK is routed to the DELIVERY authority, never the message road,
    /// and never by the hint; and a refused ACK claimeth no receipt.
    func testW16AuthenticatedAcksGoToDeliveryNeverTheMessageRoad() throws {
        let w = try world()
        let ack = FrameV2(type: .ack, msgId: msgId(950), routingTag: Data(repeating: 9, count: 4),
                          ttl: 12, hopCount: 0, flags: 0,
                          payload: Data(repeating: 0x5A, count: 64) + w.b.id)
        // the dispatcher's ACK arm never enters the generic road
        let verdict = w.a.node.dispatcherForTest().dispatch(ack, from: w.r.id)
        XCTAssertEqual(verdict.dispatchClass, .ack)
        XCTAssertFalse(verdict.accepted,
                       "the fail-closed resolver verifies no ACK: no receipt is claimed")
        XCTAssertTrue(heldIds(w.a).isEmpty, "an ACK never reaches the held set")
        // and the real MeshNode path agrees
        XCTAssertFalse(w.a.node.ingestInbound(ack, receivedFrom: w.r.id))
        XCTAssertTrue(heldIds(w.a).isEmpty)
    }
}


// MARK: - GS-SYNC-002 (iOS twin): a control reply belongeth to its own peer alone
//
// Declared in a SAME-FILE EXTENSION on purpose: the arm is inside the court (Swift's `private` is
// file-scoped for extensions of the same type) without hunting for the class's closing brace -- an
// anchor that has already misplaced an arm twice in this work.

extension ReadinessT42Tests {

    /// The audit's charge on this isle: "A control reply for one peer is drained by another peer."
    ///
    /// ISOLATING BY CONSTRUCTION: the same experiment run twice -- once with only R linked, once with B
    /// linked too and B's turn taken FIRST. The drain also carries the pump's own frames, so the arm
    /// asserts the DIFFERENCE between the two runs, which is exactly the answer raised for R.
    func testW23AControlReplyBelongethToItsOwnPeerAlone() throws {
        func pingFromR(_ w: World) throws {
            let ping = try ControlPayloadV1.ping(reply: 0, nonce: 42)
            let frame = try ControlPayloadV1.frameFor(arm: .ping,
                msgId: Data((0..<16).map { UInt8(($0 + 5) % 256) }),
                routingTag: Data(repeating: 0, count: 4), payload: ping.encode())
            XCTAssertTrue(w.a.node.handleControlFrame(frame, fromPeer: w.r.id),
                          "R's ping must be answered by A")
        }

        // CONTROL RUN: only R is linked, so R takes its own answer.
        let control = try world()
        control.linkUp(control.a, control.r)
        try pingFromR(control)
        let direct = control.a.node.drainSyncFrames(for: control.r.id)

        // THE EXPERIMENT: B is linked too and draineth FIRST.
        let raced = try world()
        raced.linkUp(raced.a, raced.r)
        raced.linkUp(raced.a, raced.b)
        try pingFromR(raced)
        _ = raced.a.node.drainSyncFrames(for: raced.b.id)
        let afterB = raced.a.node.drainSyncFrames(for: raced.r.id)

        XCTAssertEqual(
            direct.count, afterB.count,
            "B's turn must NOT consume the answer raised for R: R must receive the same frames either way "
            + "(control=\(direct.count), after B's turn=\(afterB.count))")
    }
}

// MARK: - GS-SYNC-002 step 3 (iOS): a retired relation's control reply must not ride its replacement

extension ReadinessT42Tests {

    /// The Android limb's law, on this isle: an answer raised for a relation that was RETIRED must not
    /// survive into the relation that REPLACED it.
    ///
    /// THE OBSERVABLE IS THE ISOLATING ONE, learned the hard way on the other isle (see
    /// GS-SYNC-002/red/gs-sync-002-withdrawn-observables.txt): `drainSyncFrames` also carries the PUMP's own
    /// frames, so asserting on it measures the pump; and the answer is a frame with its OWN msg id, so
    /// filtering by the ping's id matches nothing (that arm passed on the pre-repair revision and proved
    /// nothing). The no-argument `drainControlOutbox()` carries ONLY control-outbox entries, so a leftover
    /// from the retired relation is visible there and nothing else can be.
    func testW29ARetiredRelationsControlReplyIsNotHandedToTheReplacement() throws {
        let w = try world()
        w.linkUp(w.a, w.r)
        let ping = try ControlPayloadV1.ping(reply: 0, nonce: 42)
        let frame = try ControlPayloadV1.frameFor(arm: .ping,
            msgId: Data((0..<16).map { UInt8(($0 + 5) % 256) }),
            routingTag: Data(repeating: 0, count: 4), payload: ping.encode())
        XCTAssertTrue(w.a.node.handleControlFrame(frame, fromPeer: w.r.id),
                      "R's ping must be answered by A")

        // the relation is RETIRED, and the SAME peer returns as a NEW relation
        w.linkDown(w.a, w.r)
        w.linkUp(w.a, w.r)

        let stale = w.a.node.drainControlOutbox()
        XCTAssertEqual(stale.count, 0,
                       "the answer raised BEFORE the relation was retired must not survive into the "
                       + "relation that replaced it (outbox frames=\(stale.count))")
    }
}

// MARK: - GS-SYNC-002 step 4 (iOS): the per-destination control-outbox bound

extension ReadinessT42Tests {

    /// The Android limb's law on this isle: one destination may not hold more than the per-destination
    /// bound, beside the aggregate cap of 64.
    ///
    /// THE LITERAL 16 IS DELIBERATE, and the reason is a rule of this repository: a COMPILE FAILURE IS NOT A
    /// RED. The production constant (MeshNode.maxControlRepliesPerDestination, also 16) does not exist on the
    /// PRE-REPAIR revision, so an arm naming it could not compile there and could not fail on its assertion.
    /// The committed Android arm reads the production value; this one states the bound and names its source in
    /// the failure message, so a drift between the two would be visible in a failing message rather than
    /// silently agreed with.
    func testW30ASingleDestinationCannotMonopoliseTheControlOutbox() throws {
        let w = try world()
        w.linkUp(w.a, w.r)
        for i in 0..<40 {
            // `nonce` is UInt64: the FIRST capture of this red failed to COMPILE on an Int, which is why
            // it was labelled INVALID rather than counted -- a compile failure is not a red.
            let ping = try ControlPayloadV1.ping(reply: 0, nonce: UInt64(100 + i))
            let frame = try ControlPayloadV1.frameFor(arm: .ping,
                msgId: Data((0..<16).map { UInt8(($0 + 5) % 256) }),
                routingTag: Data(repeating: 0, count: 4), payload: ping.encode())
            XCTAssertTrue(w.a.node.handleControlFrame(frame, fromPeer: w.r.id),
                          "ping \(i) must be answered by A")
        }
        let boxed = w.a.node.drainControlOutbox()
        XCTAssertTrue(boxed.count <= 16,
                      "one destination must not hold more than the per-destination bound "
                      + "(held=\(boxed.count), bound=16 = MeshNode.maxControlRepliesPerDestination)")
        XCTAssertFalse(boxed.isEmpty, "and the destination's answer must still be there at all")
    }
}
