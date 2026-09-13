import Foundation
import GodstoneCore

// T40 (ADR-009 section 5) -- the per-relation sync/control owner, the twin
// of the Android router/SyncControlOwner.kt.
//
// The node's ingress demultiplexes decoded PING/HELLO/DIGEST/WANT here,
// BEFORE the generic Router runs policy, the seen-dedup window, the TTL gate
// and persistence; ACK keeps its sealed dispatcher and only MESSAGE and SOS
// enter durable message routing. Everything else (the bulk pair, any
// unknown) is refused in this profile. The owner mutates relation state
// only; control frames never enter held message storage.
//
// The section 14 event algorithm, per arriving control:
//   1. capture the source token before delivery -- the relation identity
//      and its generation are taken before any work begins;
//   2. validate token and input under the named owner -- the codec already
//      refused an uncanonical payload; the owner revalidates that the
//      relation still stands linked and the payload belongs to its run;
//   3. perform exactly one explicit transition -- each handler moves one
//      field of the run state, never two;
//   4. schedule a bounded effect -- replies, pages and answers are RETURNED
//      to the caller, counted against the run budgets (64 pages, 256
//      requested frames);
//   5. revalidate the token on completion -- afterwards the relation must
//      still be the same instance of the same generation, else the effect is
//      refused and nothing stands mutated.
//
// The inventory run is a stream: pages arrive in lexicographic order after
// an exclusive cursor; the run is OPENED by the first request, CONTINUES
// through the pages, and is CLOSED by the first page whose done is set. A
// page that names the run's snapshot after the close is an internal
// contradiction: refused "sequence_break". The end-of-run certification
// checkSequence re-inspects the accumulated stream.

public final class SyncControlOwner: @unchecked Sendable {

    public enum OwnerDecision: Sendable, Equatable {
        case accepted
        case ignored(reason: String)
        case refused(reason: String)
        case answered(frame: FrameV2)
        case delivered(frames: [FrameV2])
    }

    /// The per-relation run state (the section 14 sync run's peer member).
    public final class Relation: @unchecked Sendable {
        public let peerNodeId: Data
        public var generation: Int = 0                      // the captured source token
        public var lastHeardMono: Int64 = 0

        // consumer view: the digest tracked for this peer
        public var trackedSid: UInt64 = 0
        public var trackedBloom: Data?
        public var pendingSid: UInt64 = 0                   // named by a RESET; the next DIGEST must prove it

        // the active inventory run
        public var runSid: UInt64 = 0
        public var runCursor: Data?
        public var runDone: Bool = true
        public var pagesRequested: Int = 0
        public var pagesReceived: Int = 0
        public var requestsSent: Int = 0
        public var lastInventoryRunMono: Int64 = 0

        /// The owner stores all received page descriptors for reinspection.
        public var delivered = [ControlInventoryPage]()
        /// Received ids absent locally wait for the next want.
        public var wantQueue = [Data]()

        // producer view: answers to this peer's requests
        public var servedSid: UInt64 = 0
        public var producerPagesSent: Int = 0
        public var producerRunMono: Int64 = 0
        public var leasedSids = [UInt64]()

        // ping / RTT (ADR-009 section 3: PING is its own answer)
        public var lastPingSentNonce: UInt64 = 0
        public var lastPingSentMono: Int64 = 0
        public var lastAnsweredNonce: UInt64 = 0
        public var answeredOnce = false
        public var rttMillis: Int64 = -1

        init(peerNodeId: Data) {
            precondition(peerNodeId.count == ControlPayloadV1.idBytes, "relation peers must name 16-octet ids")
            self.peerNodeId = Data([UInt8](peerNodeId))
        }

        public var description: String {
            "relation(sid=\(trackedSid),run=\(runSid),done=\(runDone),pagesReq=\(pagesRequested)," +
            "pagesRecv=\(pagesReceived),wants=\(wantQueue.count),recv=\(delivered.count))"
        }
    }

    public static let maxPagesPerRun: Int = 64
    public static let maxWantsPerRun: Int = 256
    public static let maxWantsQueued: Int = 8_192           // 256 frames x 32 ids: the queue may not outgrow the run
    public static let periodicInventoryMs: Int64 = 300_000

    private let store: MessageStore
    private let authority: InventorySnapshotAuthority
    private let monotonicNowMillis: () -> Int64
    private let frameStamper: (ControlArm, Data) -> FrameV2
    private let lock = NSLock()
    private var relations: [String: Relation] = [:]        // keyed by the hex of the node id

    public init(store: MessageStore,
                authority: InventorySnapshotAuthority,
                monotonicNowMillis: @escaping () -> Int64,
                localNodeId: Data,
                frameStamper: ((ControlArm, Data) -> FrameV2)? = nil) {
        self.store = store
        self.authority = authority
        self.monotonicNowMillis = monotonicNowMillis
        self.frameStamper = frameStamper
            ?? SyncControlOwner.defaultStamper(localNodeId: localNodeId, monotonicNowMillis: monotonicNowMillis)
    }

    private static func hexKey(_ d: Data) -> String { ControlPayloadV1.hexOf(d) }

    /// Get or create the relation for a peer (the node's peer directory of relations).
    public func relation(for peer: Data) -> Relation {
        lock.lock(); defer { lock.unlock() }
        let key = SyncControlOwner.hexKey(peer)
        if let known = relations[key] { return known }
        let fresh = Relation(peerNodeId: peer)
        relations[key] = fresh
        return fresh
    }

    /// The number of linked relations -- the observation face.
    public func linkedRelationCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return relations.count
    }

    /// Relation terminal: control state and producer leases release here.
    public func forgetPeer(_ peer: Data) -> Bool {
        lock.lock()
        let removed = relations.removeValue(forKey: SyncControlOwner.hexKey(peer))
        lock.unlock()
        guard let removed = removed else { return false }
        authority.forgetLeases(removed.leasedSids)
        removed.generation += 1                              // any in-flight revalidation now breaks
        return true
    }

    // ------------------------------------------------------------------
    // the demultiplex: decode by the frozen outer code, dispatch by arm
    // ------------------------------------------------------------------
    public func handleControlFrame(_ frame: FrameV2, from peer: Data) -> OwnerDecision {
        let result = ControlPayloadV1.decodeFor(type: frame.type, frame.payload)
        guard case .ok(let payload) = result else {
            if case .err(let failure, _) = result {
                return .refused(reason: "decode:\(failure.rawValue)")
            }
            return .refused(reason: "decode")
        }
        let rel = relation(for: peer)
        let token = rel.generation
        let decision: OwnerDecision
        switch payload {
        case .ping(let p): decision = onPing(rel, p)
        case .digest(let p): decision = onDigest(rel, p)
        case .want(let p): decision = onWant(rel, p)
        case .inventoryRequest(let p): decision = onInventoryRequest(rel, p)
        case .inventoryPage(let p): decision = onInventoryPage(rel, p)
        case .reset(let p): decision = onReset(rel, p)
        }
        // revalidate the captured token after the work
        lock.lock()
        let still = (relations[SyncControlOwner.hexKey(peer)] === rel) && rel.generation == token
        lock.unlock()
        return still ? decision : .refused(reason: "relation gone")
    }

    // ------------------------------------------------------------------
    // one explicit transition per arm
    // ------------------------------------------------------------------
    private func onPing(_ rel: Relation, _ p: ControlPing) -> OwnerDecision {
        let now = monotonicNowMillis()
        rel.lastHeardMono = now
        if p.reply == 0 {
            // a request is answered; a replay of the same request is re-answered
            // idempotently -- the reply carries the very same nonce
            rel.lastAnsweredNonce = p.nonce
            rel.answeredOnce = true
            let reply = try! ControlPing(reply: 1, nonce: p.nonce)
            return .answered(frame: frameStamper(.ping, reply.encode()))
        }
        if p.nonce != rel.lastPingSentNonce || rel.lastPingSentMono == 0 {
            return .ignored(reason: "unsolicited reply")     // a reply is never answered; an unknown nonce is not ours
        }
        rel.rttMillis = now - rel.lastPingSentMono
        rel.lastPingSentMono = 0
        return .accepted
    }

    /// The node asks a peer whether it is alive; the RTT pair rides back.
    public func queuePing(_ rel: Relation) -> ControlPing {
        let now = monotonicNowMillis()
        let peerByte = UInt64([UInt8](rel.peerNodeId).first ?? 0)
        let nonce = (UInt64(max(0, now)) << 8) ^ peerByte ^ 0x9E37
        rel.lastPingSentNonce = nonce
        rel.lastPingSentMono = now
        return try! ControlPing(reply: 0, nonce: nonce)
    }

    private func onDigest(_ rel: Relation, _ d: ControlDigest) -> OwnerDecision {
        rel.lastHeardMono = monotonicNowMillis()
        if rel.pendingSid != 0 && d.snapshotId != rel.pendingSid {
            return .ignored(reason: "digest names a foreign snapshot")   // the run restarts deterministically
        }
        if rel.trackedSid != 0 && d.snapshotId < rel.trackedSid {
            return .ignored(reason: "stale digest")                        // the elder stands; mutate nothing
        }
        if d.snapshotId == rel.trackedSid {
            rel.trackedBloom = d.bloom                                     // reaffirmed under the very same sid
            rel.pendingSid = 0
            return .accepted
        }
        // a newer snapshot: adopt it; a run over the elder is discarded
        rel.trackedSid = d.snapshotId
        rel.trackedBloom = d.bloom
        rel.pendingSid = 0
        if rel.runSid != 0 && rel.runSid != d.snapshotId { discardRun(rel) }
        return .accepted
    }

    /// The peer asks for ids: the answer is the held frame, read back verbatim.
    private func onWant(_ rel: Relation, _ w: ControlWant) -> OwnerDecision {
        rel.lastHeardMono = monotonicNowMillis()
        guard let serving = authority.currentSnapshotOrNull(), serving.snapshotId == w.snapshotId else {
            return .delivered(frames: [])                                  // bounded absent response: answer nothing
        }
        _ = serving                                                        // the response stands on the captured vector
        var wanted = Set<String>()
        for id in w.ids { _ = wanted.insert(ControlPayloadV1.hexOf(id)) }
        var answers: [FrameV2] = []
        store.forEachHeldOrderedByPriority { frame in
            if wanted.contains(ControlPayloadV1.hexOf(frame.msgId)) { answers.append(frame) }
            return true                                                    // keep the walk: at most 32 hit anyway
        }
        return .delivered(frames: answers)                                 // exact ids, bytes as stored
    }

    /// The peer requests a page of our captured inventory (producer side).
    private func onInventoryRequest(_ rel: Relation, _ r: ControlInventoryRequest) -> OwnerDecision {
        rel.lastHeardMono = monotonicNowMillis()
        guard let snap = authority.currentSnapshot() else {                // honouring the rate limit and the leases
            return .refused(reason: "snapshot build deferred")
        }
        if snap.snapshotId != r.snapshotId {
            // the peer walks a stale or foreign course: answer with a reset
            // naming the new snapshot plus the current digest; the consumer
            // restarts with cursorPresent 0 (section 14, verbatim)
            rel.servedSid = snap.snapshotId
            rel.producerPagesSent = 0
            rel.producerRunMono = monotonicNowMillis()
            let reset = try! ControlReset(newSnapshotId: snap.snapshotId)
            let digest = digestPayload(for: snap)
            return .delivered(frames: [
                frameStamper(.reset, reset.encode()),
                frameStamper(.digest, digest.encode()),
            ])
        }
        if rel.servedSid != snap.snapshotId {
            rel.servedSid = snap.snapshotId                                // a new snapshot starts a new producer run
            rel.producerPagesSent = 0
            rel.producerRunMono = monotonicNowMillis()
        }
        if rel.producerPagesSent >= SyncControlOwner.maxPagesPerRun {
            return .refused(reason: "producer run budget spent")           // resume next turn
        }
        let cursor = r.cursorPresent == 0 ? nil : r.cursor
        guard let page = try? snap.pageAfter(cursor: cursor, maxPerPage: ControlPayloadV1.maxIdsPerArm) else {
            return .refused(reason: "decode:bad_cursor")
        }
        rel.producerPagesSent += 1
        return .delivered(frames: [frameStamper(.inventoryPage, page.encode())])
    }

    /// The response to OUR inventory request: verify, store, advance -- once.
    private func onInventoryPage(_ rel: Relation, _ p: ControlInventoryPage) -> OwnerDecision {
        rel.lastHeardMono = monotonicNowMillis()
        if rel.runSid == 0 { return .ignored(reason: "unsolicited page") }
        if p.snapshotId != rel.runSid { return .refused(reason: "sequence_break") }
        if rel.runDone { return .refused(reason: "sequence_break") }       // the stream continues after the close
        if !p.ids.isEmpty {
            if !ControlPayloadV1.idsDistinct(p.ids) { return .refused(reason: "duplicate_ids") }
            for k in 1..<p.ids.count {
                if ControlPayloadV1.lexicographicCompare(p.ids[k - 1], p.ids[k]) >= 0 {
                    return .refused(reason: "sequence_break")
                }
            }
            if let cursor = rel.runCursor,
               ControlPayloadV1.lexicographicCompare(p.ids.first!, cursor) <= 0 {
                return .refused(reason: "sequence_break")
            }
        }
        if p.done != 0 && p.done != 1 { return .refused(reason: "bad_done") }
        // one explicit transition: the verified page joins the run
        rel.delivered.append(p)
        if let last = p.ids.last { rel.runCursor = last }
        rel.pagesReceived += 1
        // request each id absent from the durable store (the probe reads the
        // truth, not the cache); duplicates already queued are passed over
        if !p.ids.isEmpty {
            var held = Set<String>()
            store.forEachHeldMsgId { id in _ = held.insert(ControlPayloadV1.hexOf(id)); return true }
            for id in p.ids {
                if held.contains(ControlPayloadV1.hexOf(id)) { continue }
                if !rel.wantQueue.contains(where: { $0 == id }) && rel.wantQueue.count < SyncControlOwner.maxWantsQueued {
                    rel.wantQueue.append(id)
                }
            }
        }
        if p.done == 1 { rel.runDone = true }
        return .accepted
    }

    /// HELLO subtype 3: the producer names a new snapshot; the consumer restarts.
    private func onReset(_ rel: Relation, _ rs: ControlReset) -> OwnerDecision {
        rel.lastHeardMono = monotonicNowMillis()
        discardRun(rel)
        rel.trackedSid = 0                                                 // await the digest that proves the new sid
        rel.pendingSid = rs.newSnapshotId
        return .accepted
    }

    /// Re-inspect the accumulated stream of one run; nil when it is coherent.
    public func checkSequence(_ rel: Relation) -> String? {
        if rel.delivered.isEmpty { return "sequence_break" }
        if !rel.runDone { return "sequence_break" }
        var previous: Data? = nil
        for (k, page) in rel.delivered.enumerated() {
            if page.snapshotId != rel.runSid { return "sequence_break" }
            if page.ids.count > ControlPayloadV1.maxIdsPerArm { return "count_out_of_range" }
            if page.ids.isEmpty && page.done != 1 { return "bad_done" }
            if !page.ids.isEmpty {
                if let previous = previous,
                   ControlPayloadV1.lexicographicCompare(page.ids.first!, previous) <= 0 { return "sequence_break" }
                previous = page.ids.last
            }
            if page.done == 1 && k != rel.delivered.count - 1 { return "sequence_break" }
        }
        return nil
    }

    // ------------------------------------------------------------------
    // the consumer's pump: bounded inventory runs (plan / pump / complete)
    // ------------------------------------------------------------------
    /// Open a run over the peer's tracked snapshot (initial encounter or the period).
    public func startInventoryRun(_ peer: Data) -> Bool {
        let rel = relation(for: peer)
        if rel.trackedSid == 0 { return false }
        if !rel.runDone { return false }                                   // a run is already open
        rel.runSid = rel.trackedSid
        rel.runCursor = nil
        rel.runDone = false
        rel.pagesRequested = 0
        rel.pagesReceived = 0
        rel.requestsSent = 0
        rel.delivered.removeAll()
        rel.wantQueue.removeAll()
        rel.lastInventoryRunMono = monotonicNowMillis()
        return true
    }

    /// Whether the period has arrived for a fresh exact-inventory run.
    public func shouldScheduleInventory(_ peer: Data, now: Int64) -> Bool {
        let rel = relation(for: peer)
        return rel.runDone && rel.trackedSid != 0 &&
            (rel.lastInventoryRunMono == 0 || now - rel.lastInventoryRunMono >= SyncControlOwner.periodicInventoryMs)
    }

    /// The next frames of the consumer's run; empty when the turn has yielded.
    /// The page leg runs only while the walk is open; the want leg drains even
    /// after the close -- received-but-unheld ids must not be stranded.
    public func pumpNextInventoryFrames(_ peer: Data) -> [FrameV2] {
        let rel = relation(for: peer)
        if rel.runSid == 0 { return [] }
        var out: [FrameV2] = []
        if !rel.runDone && rel.pagesRequested < SyncControlOwner.maxPagesPerRun {
            let cp: UInt8 = rel.runCursor == nil ? 0 : 1
            let cursor = rel.runCursor ?? Data(repeating: 0, count: ControlPayloadV1.idBytes)
            let req = try! ControlInventoryRequest(snapshotId: rel.runSid, cursorPresent: cp, cursor: cursor)
            out.append(frameStamper(.inventoryRequest, req.encode()))
            rel.pagesRequested += 1
        }
        while rel.requestsSent < SyncControlOwner.maxWantsPerRun && !rel.wantQueue.isEmpty {
            let take = min(rel.wantQueue.count, ControlPayloadV1.maxIdsPerArm)
            let batch = Array(rel.wantQueue[0..<take])
            rel.wantQueue.removeFirst(take)
            let w = try! ControlWant(snapshotId: rel.runSid, ids: batch)
            out.append(frameStamper(.want, w.encode()))
            rel.requestsSent += 1                                          // one requested frame per want payload
        }
        if rel.pagesRequested >= SyncControlOwner.maxPagesPerRun && rel.wantQueue.isEmpty && !out.isEmpty {
            rel.runDone = true                                             // the budget spent: yield the turn
        }
        return out
    }

    /// The consumer's pending wants (the observation face for the pump's owner).
    public func pendingWants(_ peer: Data) -> [Data] {
        return relation(for: peer).wantQueue
    }

    // ------------------------------------------------------------------
    // the producer's pump: serve the current snapshot as a DIGEST frame
    // ------------------------------------------------------------------
    /// Build (do not send) the digest frame for our current snapshot.
    public func buildDigestFrame() -> (frame: FrameV2, payload: ControlDigest)? {
        guard let snap = authority.currentSnapshot() else { return nil }
        let payload = digestPayload(for: snap)
        return (frameStamper(.digest, payload.encode()), payload)
    }

    /// The canonical four rounds over the CAPTURED vector -- never the seen cache.
    public func digestPayload(for snap: StableInventorySnapshot) -> ControlDigest {
        let bloom = BloomDigest()
        for id in snap.ids { bloom.add(id) }
        return try! ControlDigest(snapshotId: snap.snapshotId, bloom: bloom.toBytes())
    }

    /// Lease a snapshot for a relation (the run pins its pages to it).
    public func acquireLease(_ rel: Relation, _ snapshotId: UInt64) -> Bool {
        let ok = authority.acquire(snapshotId)
        if ok, !rel.leasedSids.contains(snapshotId) { rel.leasedSids.append(snapshotId) }
        return ok
    }

    public func releaseLease(_ rel: Relation, _ snapshotId: UInt64) -> Bool {
        let ok = authority.release(snapshotId)
        if let at = rel.leasedSids.firstIndex(of: snapshotId) { rel.leasedSids.remove(at: at) }
        return ok
    }

    /// Discard an open or closed run: the next start begins from the top.
    private func discardRun(_ rel: Relation) {
        rel.runSid = 0
        rel.runCursor = nil
        rel.runDone = true
        rel.pagesRequested = 0
        rel.pagesReceived = 0
        rel.requestsSent = 0
        rel.delivered.removeAll()
        rel.wantQueue.removeAll()
    }

    /// The honest stamper: ids derived by the frozen formula, tag from the id.
    public static func defaultStamper(
        localNodeId: Data,
        monotonicNowMillis: @escaping () -> Int64
    ) -> (ControlArm, Data) -> FrameV2 {
        let box = SeqBox()
        return { arm, payload in
            let seq = box.next()
            let now = monotonicNowMillis()
            var nonce = Data(repeating: 0, count: 16)
            putU64(&nonce, 0, UInt64(max(0, now)) >> 10)
            putU64(&nonce, 8, UInt64(seq))
            let msgId = MessageId.derive(
                senderNodeId: localNodeId,
                createdAtEpochSeconds: now / 1000,
                messageNonce: nonce,
                plaintext: payload
            )
            let base = msgId.startIndex
            return FrameV2(
                type: arm.outerCode,
                msgId: msgId,
                routingTag: msgId[base..<(base + 4)],
                ttl: 0,
                hopCount: 0,
                flags: 0,
                payload: payload
            )
        }
    }

    private static func putU64(_ out: inout Data, _ at: Int, _ value: UInt64) {
        let base = out.startIndex
        out[base + at + 0] = UInt8((value >> 56) & 0xFF)
        out[base + at + 1] = UInt8((value >> 48) & 0xFF)
        out[base + at + 2] = UInt8((value >> 40) & 0xFF)
        out[base + at + 3] = UInt8((value >> 32) & 0xFF)
        out[base + at + 4] = UInt8((value >> 24) & 0xFF)
        out[base + at + 5] = UInt8((value >> 16) & 0xFF)
        out[base + at + 6] = UInt8((value >> 8) & 0xFF)
        out[base + at + 7] = UInt8(value & 0xFF)
    }

    private final class SeqBox: @unchecked Sendable {
        private let lock = NSLock()
        private var seq: Int64 = 0
        func next() -> Int64 { lock.lock(); defer { lock.unlock() }; seq += 1; return seq }
    }
}
