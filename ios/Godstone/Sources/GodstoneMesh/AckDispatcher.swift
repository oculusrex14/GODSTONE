// T84 -- "Forward durable ACKs through intermediate relays" (section 14, the
// durable ACK return path). The Swift twin of
// android/mesh/src/main/java/io/godstone/mesh/delivery/AckDispatcher.kt
//
// The card's defect: MeshNode sendeth every ACK to the local DeliveryTracker, so
// an intermediate relay -- which by definition holdeth NO delivery row for a
// message somebody else authored -- answereth UnknownMessage, and the multihop
// recipient receipt never cometh home.
//
// Two authorities are born here, and they are deliberately separate.
//
//   AckDispatcher -- the INBOUND decision for one ACK frame, taken BEFORE any
//     generic message TTL / dedup / store handling. The classification is
//     OriginVerification versus OpaqueRelay:
//       * a durable delivery row standeth for the msgId -> the ORIGIN. The
//         existing expected-recipient / trust / CAS verification runneth first,
//         and it is the ONLY road to DELIVERED. A rejected candidate leaveth
//         delivery unchanged and cannot suppress a later valid signature;
//       * no delivery row standeth -> RELAY TRAFFIC, never an automatic
//         discard. The candidate entereth the SEPARATE ack_frames namespace
//         (never held_frames, never the message dedup), bounded per pair and in
//         total, labelled opaque-candidate unless a real recipient key
//         verified it;
//       * a delivery lookup that FAILED (corrupt or storage failure) is a
//         refusal BY NAME. Storage failure is never read as "no row", which
//         would silently reclassify a correctness-critical fault as traffic.
//
//   DurableAckPump -- the OUTBOUND bounded epidemic pump, and the one owner of a
//     candidate's lifecycle. It is scheduled on LinkReady, batch 32, at most one
//     retry per candidate/peer per 30 s, one ACK/s with burst 16 per peer; it
//     never echoeth to receivedFrom; it never inserteth a candidate into the
//     message bloom/inventory namespace, and a LOCAL ATT ACCEPTANCE NEVER
//     RETIRETH CUSTODY -- only the retention sweep and quota do. A forwarded copy
//     decrementeth TTL and incrementeth hop EXACTLY ONCE (the prepared copy is
//     stored and re-emitted byte-identically on every retry), and an ACK whose
//     received TTL lieth outside the production band is refused by name rather
//     than re-signed with a budget it never had.
//
// Retention is the section 14 non-replenishing clock policy, delegated to the
// T32 RetentionClock seam so that there is ONE owner of the arithmetic: a
// candidate admitted by THIS process is anchored at its admission instant and
// debited by the true monotonic delta, while a candidate restored from the store
// after a restart taketh the conservative branch exactly once (a discontinuity
// counted, a bounded nonnegative wall estimate floored at one hour), and the
// STORE refuseth any debit that would not strictly shorten the life. Eight days
// from first local receipt is the window; it is never replenished.
//
// Nonshipping: this is the lab mesh path. The shipping LIGHT Archive-only graph
// carrieth no mesh dependency at all, the readiness flags stay false, and
// nothing here closeth a device gate. Host tests do not prove CoreBluetooth or
// Data Protection behaviour.

import Foundation

/// Bounded batch of forward copies offered to one peer (section 14: 32).
let ackRelayBatchLimit: Int = 32

/// At most one retry per candidate/peer in this window (section 14: 30 s).
let ackRelayRetryIntervalMs: Int = 30_000

/// Per-peer token bucket: one ACK/s, burst 16 (section 14).
let ackRelayBurstPerPeer: Int = 16
let ackRelayRateMs: Int = 1_000

/// The EXPLICIT production initial ACK TTL, mirrored from the canonical ACK
/// generator (`ackInitialTtl`). A received candidate ABOVE this carrieth a hop
/// budget the production generator never issueth and is refused by name; a
/// candidate below 2 cannot be forwarded at all (a forward copy decrementeth the
/// TTL, and a TTL-0 frame is local to the link and never travels).
let ackRelayInitialTtl: Int = Int(ackInitialTtl)

/// The bound on one enumeration walk of the candidate namespace.
let ackRelayEnumerationLimit: Int = ackCandidatesTotalLimit

private func ackHex(_ bytes: Data) -> String {
    return bytes.map { String(format: "%02x", $0) }.joined()
}

/// The classification of one inbound ACK (the card's named types).
enum AckDispatchClass: String, Equatable {
    case originVerification = "ORIGIN_VERIFICATION"
    case opaqueRelay = "OPAQUE_RELAY"
}

/// Why a frame was refused before any write. Named, never a silent drop.
enum AckRefusalReason: String, Equatable {
    case notAnAck = "NOT_AN_ACK"
    case malformedPayload = "MALFORMED_PAYLOAD"
    case nonCanonicalFlags = "NON_CANONICAL_FLAGS"
    case deliveryStateUnreadable = "DELIVERY_STATE_UNREADABLE"
    case candidateCapacity = "CANDIDATE_CAPACITY"
    case knownInvalidSignature = "KNOWN_INVALID_SIGNATURE"
    case custodyStorageFailure = "CUSTODY_STORAGE_FAILURE"
}

/// What one admission did, and what it was labelled.
struct AckAdmission: Equatable {
    let result: AckAdmissionResult
    let ackKey: Data?
    let verificationClass: AckVerificationClass?

    var accepted: Bool {
        switch result {
        case .stored, .duplicate: return true
        default: return false
        }
    }
}

/// The dispatcher's verdict for one inbound ACK frame.
enum AckDispatch {
    /// A durable delivery row standeth: only this road may reach DELIVERED.
    case originVerification(AckResult)
    /// No delivery row: relay traffic, carried in the separate namespace.
    case opaqueRelay(AckAdmission)
    /// Refused by name; nothing was written anywhere.
    case refused(AckRefusalReason, String)

    var dispatchClass: AckDispatchClass {
        switch self {
        case .originVerification: return .originVerification
        case .opaqueRelay: return .opaqueRelay
        case .refused: return .originVerification
        }
    }

    /// Idempotent accept: a newly verified recipient is accepted, an
    /// already-terminal row is accepted, everything else is a rejection.
    var accepted: Bool {
        switch self {
        case .originVerification(let result):
            switch result {
            case .applied, .alreadyAcknowledged, .duplicateAuthenticatedAck: return true
            default: return false
            }
        case .opaqueRelay(let admission): return admission.accepted
        case .refused: return false
        }
    }
}

/// The inbound ACK authority. Every dependency is injected at a real boundary:
/// the delivery-row lookup (the origin test), the tracker's verification, and the
/// admission (owned by DurableAckPump). Pure Swift -- no clock, no I/O of its
/// own -- so the whole dispatch statute is executable on the host.
final class AckDispatcher: @unchecked Sendable {
    private let lookupDeliveryRow: (Data) -> DeliveryLookup
    private let verifyOrigin: (FrameV2) -> AckResult
    private let admitCandidate: (Data, Data?) -> AckAdmission

    init(lookupDeliveryRow: @escaping (Data) -> DeliveryLookup,
         verifyOrigin: @escaping (FrameV2) -> AckResult,
         admitCandidate: @escaping (Data, Data?) -> AckAdmission) {
        self.lookupDeliveryRow = lookupDeliveryRow
        self.verifyOrigin = verifyOrigin
        self.admitCandidate = admitCandidate
    }

    /// One inbound ACK: origin first, then bounded relay custody.
    func dispatch(_ frame: FrameV2, receivedFrom: Data?) -> AckDispatch {
        if frame.type != .ack { return .refused(.notAnAck, "") }
        if frame.payload.count != ackPayloadLen {
            return .refused(.malformedPayload,
                            "an ACK payload is signature64||recipientNodeId16; this one carrieth "
                            + "\(frame.payload.count) bytes")
        }
        if frame.msgId.count != ackMsgLen {
            return .refused(.malformedPayload, "msgId is not 16 bytes")
        }
        if frame.flags != 0 {
            // section 14: "flags remain canonical0". A non-zero flag would make
            // this a different frame than the recipient signed.
            return .refused(.nonCanonicalFlags,
                            "canonical ACK flags must be 0, found \(frame.flags)")
        }
        switch lookupDeliveryRow(frame.msgId) {
        case .found:
            // THE ORIGIN. The existing expected-recipient / trust / CAS
            // verification runs first and stands untouched: a rejected candidate
            // leaves delivery unchanged and cannot suppress a later valid one.
            return .originVerification(verifyOrigin(frame))
        case .notFound:
            break  // relay traffic: fall through
        case .corrupt:
            return .refused(.deliveryStateUnreadable,
                            "the delivery row for " + ackHex(frame.msgId) + " is corrupt")
        case .storageFailure:
            return .refused(.deliveryStateUnreadable,
                            "the delivery row for " + ackHex(frame.msgId) + " could not be read")
        case .invalidArgument:
            return .refused(.deliveryStateUnreadable,
                            "the delivery row for " + ackHex(frame.msgId) + " was refused")
        }
        let admission = admitCandidate(frame.encode(), receivedFrom)
        switch admission.result {
        case .stored, .duplicate:
            return .opaqueRelay(admission)
        case .refusedQuotaPair, .refusedQuotaGlobal:
            return .refused(.candidateCapacity,
                            "the relay ACK window is full; new custody is refused explicitly "
                            + "(the original message and the origin verification state are untouched)")
        case .refusedKnownInvalid:
            return .refused(.knownInvalidSignature,
                            "the candidate is invalid under an AVAILABLE authenticated recipient key")
        case .refusedBadFrame:
            return .refused(.malformedPayload, "the candidate frame did not decode")
        case .storageFailure:
            return .refused(.custodyStorageFailure, "the candidate store refused the write")
        }
    }
}

/// Why a candidate produced no forward copy in this batch.
enum AckForwardRefusal: String, Equatable {
    case notScheduled = "NOT_SCHEDULED"
    case receivedFromThisPeer = "RECEIVED_FROM_THIS_PEER"
    case retryWindow = "RETRY_WINDOW"
    case peerRateLimit = "PEER_RATE_LIMIT"
    case ttlExhausted = "TTL_EXHAUSTED"
    case ttlAboveProductionInitial = "TTL_ABOVE_PRODUCTION_INITIAL"
    case hopLimit = "HOP_LIMIT"
    case malformed = "MALFORMED"
}

/// One prepared forward copy. It is built ONCE per candidate and stored, so a
/// retry re-emiteth the IDENTICAL bytes: TTL is decremented and hop incremented
/// exactly once for the copy, never again (section 14).
struct AckForwardCopy: Equatable {
    let ackKey: Data
    let msgId: Data
    let encodedFrame: Data
    let ttl: Int
    let hopCount: Int
    let verificationClass: AckVerificationClass
}

/// The bounded result of one pump turn for one peer.
struct AckPumpBatch {
    let peer: Data
    let copies: [AckForwardCopy]
    let refusals: [AckForwardRefusal: Int]
    let scanned: Int

    var refusedTotal: Int { refusals.values.reduce(0, +) }
}

/// What one retention sweep did. Every count is an executed observation.
struct AckSweepReport {
    let scanned: Int
    let debited: Int
    let expired: Int
    let refusedReplenish: Int
    let expiryReasons: [String: Int]
    let storageFailure: Bool
}

/// The bounded, durable epidemic ACK pump, and the one owner of a candidate's
/// lifecycle. It owneth no durable state of its own: the candidate rows ARE the
/// ack_frames namespace, and its in-memory tables (retry gates, token buckets,
/// prepared copies, retention anchors) are scheduling hints that a restart
/// rebuildeth from the store.
final class DurableAckPump: @unchecked Sendable {
    /// The section 14 window: eight days from first local receipt.
    static let candidateLifetimeMs: Int = 8 * 24 * 60 * 60 * 1000

    private let store: AckObligationStore
    private let admitForeign: (Data, Data?) -> AckAdmissionResult
    private let clock: () -> Int
    private let lock = NSLock()

    private var readyAt: [String: Int] = [:]
    private var lastOffer: [String: Int] = [:]
    private final class Bucket { var tokens: Int; var refilledAtMs: Int
        init(tokens: Int, refilledAtMs: Int) { self.tokens = tokens; self.refilledAtMs = refilledAtMs } }
    private var buckets: [String: Bucket] = [:]
    private var copies: [String: AckForwardCopy] = [:]
    /// Retention anchors: present IFF this process admitted or already knew the
    /// candidate. An absent anchor meaneth "restored from the store".
    private var checkpoints: [String: RetentionCheckpoint] = [:]
    private var lastSweepMs: Int?

    init(store: AckObligationStore,
         admitForeign: @escaping (Data, Data?) -> AckAdmissionResult,
         clock: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.store = store
        self.admitForeign = admitForeign
        self.clock = clock
    }

    // ---------------------------------------------------------------- scheduling

    /// Schedule on LinkReady: the peer becometh eligible, with a full bucket.
    func onLinkReady(_ peer: Data, now: Int? = nil) {
        let instant = now ?? clock()
        lock.lock(); defer { lock.unlock() }
        readyAt[ackHex(peer)] = instant
        buckets[ackHex(peer)] = Bucket(tokens: ackRelayBurstPerPeer, refilledAtMs: instant)
    }

    /// A link went away: the peer stoppeth being eligible. Nothing is retired:
    /// the candidate waiteth, durably, for the next LinkReady.
    func onLinkGone(_ peer: Data) {
        lock.lock(); defer { lock.unlock() }
        readyAt.removeValue(forKey: ackHex(peer))
        buckets.removeValue(forKey: ackHex(peer))
    }

    func isScheduled(_ peer: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return readyAt[ackHex(peer)] != nil
    }

    // ---------------------------------------------------------------- custody

    /// Admit one candidate into the SEPARATE namespace, and anchor it. This is
    /// the dispatcher's injected boundary: the classification is the
    /// dispatcher's, the lifecycle is the pump's.
    func admit(_ encoded: Data, receivedFrom: Data? = nil, now: Int? = nil) -> AckAdmission {
        let instant = now ?? clock()
        let result: AckAdmissionResult
        do {
            result = admitForeign(encoded, receivedFrom)
        } catch {
            return AckAdmission(result: .storageFailure, ackKey: nil, verificationClass: nil)
        }
        guard let frame = try? FrameV2.decode(encoded), frame.payload.count == ackPayloadLen else {
            return AckAdmission(result: result, ackKey: nil, verificationClass: nil)
        }
        let signature = frame.payload.prefix(ackSigLen)
        let claimed = frame.payload.suffix(ackRecipLen)
        guard let key = AckCacheKey.compute(msgId: frame.msgId, recipientNodeId: Data(claimed),
                                           signature: Data(signature)) else {
            return AckAdmission(result: result, ackKey: nil, verificationClass: nil)
        }
        var klass: AckVerificationClass?
        if case .stored = result {
            if case .found(let row) = store.lookupByAckKey(key) { klass = row.verificationClass }
        } else if result == .duplicate {
            if case .found(let row) = store.lookupByAckKey(key) { klass = row.verificationClass }
        }
        guard let verifiedClass = klass else {
            return AckAdmission(result: result, ackKey: key, verificationClass: nil)
        }
        lock.lock()
        let hex = ackHex(key)
        if checkpoints[hex] == nil {
            // A NEW receipt is granted the full local lifetime ONCE, anchored at
            // this instant (section 14).
            checkpoints[hex] = RetentionCheckpoint(
                msgId: ackHex(frame.msgId), kind: .direct,
                remainingMs: rowRemaining(key),
                checkpointMonotonicMs: instant, lastWallCheckpointMs: instant,
                discontinuityCount: 0, priority: 0, firstReceiptId: "relay")
        }
        lock.unlock()
        return AckAdmission(result: result, ackKey: key, verificationClass: verifiedClass)
    }

    /// Custody is the store's: how many candidates stand right now.
    func custodyCount() -> Int {
        switch store.listCandidates(Int32(ackRelayEnumerationLimit)) {
        case .records(let rows): return rows.count
        default: return -1
        }
    }

    func custodyHolds(_ ackKey: Data) -> Bool {
        if case .found = store.lookupByAckKey(ackKey) { return true }
        return false
    }

    // ---------------------------------------------------------------- forwarding

    /// One bounded pump turn for `peer`: at most 32 copies, honouring the retry
    /// window, the per-peer rate, the never-echo law and the TTL/hop statute.
    func nextBatch(_ peer: Data, now: Int? = nil) -> AckPumpBatch {
        let instant = now ?? clock()
        let peerKey = ackHex(peer)
        lock.lock(); defer { lock.unlock() }
        if readyAt[peerKey] == nil {
            // No LinkReady, no offer: a candidate is never sent to a peer the
            // runtime has not declared ready.
            return AckPumpBatch(peer: peer, copies: [],
                                refusals: [.notScheduled: 1], scanned: 0)
        }
        let rows: [AckFrameRecord]
        switch store.listCandidates(Int32(ackRelayEnumerationLimit)) {
        case .records(let listed): rows = listed
        default: return AckPumpBatch(peer: peer, copies: [], refusals: [:], scanned: 0)
        }
        var refusals: [AckForwardRefusal: Int] = [:]
        func refuse(_ reason: AckForwardRefusal) { refusals[reason, default: 0] += 1 }
        var out: [AckForwardCopy] = []
        var scanned = 0
        for record in rows {
            if out.count >= ackRelayBatchLimit { break }
            if let from = record.receivedFrom, from == peer {
                refuse(.receivedFromThisPeer)
                continue
            }
            scanned += 1
            let ackKeyHex = ackHex(record.ackKey)
            if let last = lastOffer["\(ackKeyHex)|\(peerKey)"], instant - last < ackRelayRetryIntervalMs {
                refuse(.retryWindow)
                continue
            }
            guard let frame = try? FrameV2.decode(record.encodedFrame) else {
                refuse(.malformed)
                continue
            }
            // The TTL/hop statute is judged on the RECEIVED frame, BEFORE a copy
            // is prepared: a refusal never buildeth a frame it then discards.
            if frame.ttl < 2 { refuse(.ttlExhausted); continue }
            if Int(frame.ttl) > ackRelayInitialTtl { refuse(.ttlAboveProductionInitial); continue }
            if Int(frame.hopCount) + 1 > FrameV2.maxTtl { refuse(.hopLimit); continue }
            let bucket = buckets[peerKey] ?? Bucket(tokens: ackRelayBurstPerPeer, refilledAtMs: instant)
            buckets[peerKey] = bucket
            if refill(bucket, now: instant) <= 0 { refuse(.peerRateLimit); continue }
            let prepared: AckForwardCopy
            if let cached = copies[ackKeyHex] {
                prepared = cached
            } else {
                prepared = prepare(record, frame)
                copies[ackKeyHex] = prepared
            }
            bucket.tokens -= 1
            // The retry window openeth at the OFFER, not at the writer's
            // convenience: a candidate offered now cannot be offered again for
            // 30 s even if the caller never reporteth an outcome.
            lastOffer["\(ackKeyHex)|\(peerKey)"] = instant
            out.append(prepared)
        }
        return AckPumpBatch(peer: peer, copies: out, refusals: refusals, scanned: scanned)
    }

    /// The link's writer answereth. A LOCAL ATT ACCEPTANCE NEVER RETIRETH
    /// CUSTODY: it only re-stampeth the retry window. A candidate leaveth the
    /// namespace when the retention sweep expireth it, or when quota refuseth new
    /// custody -- never because a radio accepted some bytes.
    func onForwardOutcome(_ copy: AckForwardCopy, peer: Data, accepted: Bool, now: Int? = nil) {
        let instant = now ?? clock()
        lock.lock(); defer { lock.unlock() }
        lastOffer["\(ackHex(copy.ackKey))|\(ackHex(peer))"] = instant
    }

    // ---------------------------------------------------------------- retention

    /// The retention sweep: ONE non-replenishing debit per candidate, expiring
    /// those whose remaining life reacheth nought. The arithmetic is the T32
    /// RetentionClock; the store refuseth any debit that would not strictly
    /// shorten the life.
    func sweep(now: Int? = nil, wallEstimateMs: Int = 0,
               continuity: ClockContinuityStamp = .unknown) -> AckSweepReport {
        let instant = now ?? clock()
        let adapter = FixedContinuity(stamp: continuity)
        lock.lock(); defer { lock.unlock() }
        let rows: [AckFrameRecord]
        switch store.listCandidates(Int32(ackRelayEnumerationLimit)) {
        case .records(let listed): rows = listed
        default:
            return AckSweepReport(scanned: 0, debited: 0, expired: 0, refusedReplenish: 0,
                                  expiryReasons: [:], storageFailure: true)
        }
        var debited = 0
        var expired = 0
        var refusedReplenish = 0
        var reasons: [String: Int] = [:]
        for record in rows {
            let hex = ackHex(record.ackKey)
            if checkpoints[hex] == nil {
                // RESTORED from the store: this process knoweth not what elapsed
                // while it was not running, so it taketh the conservative branch
                // exactly once, and anchors there.
                let restored = RetentionCheckpoint(
                    msgId: ackHex(record.msgId), kind: .direct,
                    remainingMs: Int(record.remainingLifetimeMs),
                    checkpointMonotonicMs: instant, lastWallCheckpointMs: instant,
                    discontinuityCount: 0, priority: 0, firstReceiptId: "relay")
                let (next, reason) = RetentionPolicy.checkpoint(
                    restored, nowMono: instant, wallEstimateMs: wallEstimateMs, adapter: adapter)
                reasons[reason.rawValue, default: 0] += 1
                if next.remainingMs <= 0 || reason != .notExpired {
                    if store.expireCandidate(record.ackKey) {
                        expired += 1
                        copies.removeValue(forKey: hex)
                        checkpoints.removeValue(forKey: hex)
                    }
                } else if store.debitCandidateLifetime(record.ackKey, remainingLifetimeMs: Int64(next.remainingMs)) {
                    debited += 1
                    checkpoints[hex] = next
                } else {
                    refusedReplenish += 1
                }
                continue
            }
            let prior = checkpoints[hex]!
            let (next, reason) = RetentionPolicy.checkpoint(
                prior, nowMono: instant, wallEstimateMs: wallEstimateMs, adapter: adapter)
            reasons[reason.rawValue, default: 0] += 1
            if next.remainingMs <= 0 || reason != .notExpired {
                if store.expireCandidate(record.ackKey) {
                    expired += 1
                    copies.removeValue(forKey: hex)
                    checkpoints.removeValue(forKey: hex)
                }
            } else if store.debitCandidateLifetime(record.ackKey, remainingLifetimeMs: Int64(next.remainingMs)) {
                debited += 1
                checkpoints[hex] = next
            } else {
                refusedReplenish += 1
            }
        }
        lastSweepMs = instant
        return AckSweepReport(scanned: rows.count, debited: debited, expired: expired,
                              refusedReplenish: refusedReplenish, expiryReasons: reasons,
                              storageFailure: false)
    }

    // ---------------------------------------------------------------- internals

    private func prepare(_ record: AckFrameRecord, _ frame: FrameV2) -> AckForwardCopy {
        let forwarded = FrameV2(
            type: .ack, msgId: frame.msgId,
            routingTag: frame.routingTag,  // the canonical recipient hint, NOT a route to the origin
            ttl: frame.ttl - 1, hopCount: frame.hopCount + 1, flags: 0, payload: frame.payload)
        return AckForwardCopy(ackKey: record.ackKey, msgId: frame.msgId,
                              encodedFrame: forwarded.encode(), ttl: Int(forwarded.ttl),
                              hopCount: Int(forwarded.hopCount),
                              verificationClass: record.verificationClass)
    }

    private func refill(_ bucket: Bucket, now: Int) -> Int {
        let elapsed = now - bucket.refilledAtMs
        if elapsed <= 0 { return bucket.tokens }
        let gained = elapsed / ackRelayRateMs
        if gained > 0 {
            bucket.tokens = min(ackRelayBurstPerPeer, bucket.tokens + gained)
            bucket.refilledAtMs = now
        }
        return bucket.tokens
    }

    private func rowRemaining(_ ackKey: Data) -> Int {
        if case .found(let row) = store.lookupByAckKey(ackKey) { return Int(row.remainingLifetimeMs) }
        return DurableAckPump.candidateLifetimeMs
    }
}

/// The injected continuity verdict, held constant for one sweep (the court
/// injecteth a deterministic stamp; the platform adapter is a separate seam).
private final class FixedContinuity: MonotonicClockAdapter {
    private let stamp: ClockContinuityStamp
    init(stamp: ClockContinuityStamp) { self.stamp = stamp }
    func proveContinuity(previous: RetentionCheckpoint, nowMono: Int) -> ClockContinuityStamp {
        return stamp
    }
}
