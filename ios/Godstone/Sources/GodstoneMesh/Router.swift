import Foundation
import GodstoneCore

/// Delay-tolerant epidemic router, GMP/2 (ADR-001, ADR-008, C6.7.2).
///
/// V4: `ingest` now takes `FrameV2`.
public final class Router {

    public static let defaultTtl: UInt8 = FrameV2.defaultTtl
    public static let maxTtl: UInt8 = FrameV2.maxTtl
    public static let seenCacheCapacity = 16_384

    public let selfNodeId: Data
    private var seen: LruSet<Data>
    /// The wipe admission seam, or nil for a caller that has not been wired to one (nil == no gate, the road unchanged).
    private let wipeGate: (any WipeSensitiveUseGate)?
    private var queue: [FrameV2] = []
    private let lock = NSLock()

    public var onDeliverLocally: ((FrameV2) -> Void)?
    public var onForward: ((FrameV2) -> Void)?

    /// THE durable hold, REQUIRED (T42). It was optional, and an absent store
    /// made `accept` report a frame accepted on MEMORY ALONE -- a success the
    /// node could not honour after a restart, and a relay it never held. A
    /// router is now constructed WITH its store or not at all; the anti-entropy
    /// digest is built from the store's held msg_ids (the set of frames this node
    /// CARRIES), matching Android.
    public let store: MessageStore

    /// The fail-closed door: a nil store REFUSES construction, so the
    /// memory-only face is not merely discouraged but unreachable.
    public static func make(selfNodeId: Data, store: MessageStore?,
                            seenCacheCapacity: Int = Router.seenCacheCapacity) -> Router? {
        guard let store else { return nil }
        return Router(selfNodeId: selfNodeId, store: store, seenCacheCapacity: seenCacheCapacity)
    }

    /// *** GS-FINAL-003 (round 636): THE iOS TWIN OF ANDROID'S ROUND-574 ADMISSION POINT. ***
    ///
    /// **MEASURED THIS ROUND: ANDROID'S `Router` CARRIED A REQUIRED `wipeGate` AND ASKED IT BEFORE `store.persist`;
    /// iOS'S CARRIED NONE AT ALL, SO `accept` COULD WRITE THE HELD ROW DURING A PENDING WIPE.** *The same defect class
    /// the two isles keep trading: a control one isle has and the other merely appears to.*
    ///
    /// IT IS **OPTIONAL AND DEFAULTS TO NIL**, DELIBERATELY: the iOS `Router` is constructed at many call sites, and
    /// making the gate required would be a large cutover for a seam whose consumers can adopt it as they are proven.
    /// **AND NIL MEANS "NO GATE", WHICH IS THE HONEST READING OF AN UNWIRED CALLER RATHER THAN A SILENT ALWAYS-ALLOW**
    /// -- the behaviour of a nil gate is exactly the road as it was, so no existing composition changes, which is the
    /// same property the round-574 note required on the other isle. **A CALLER THAT WANTS THE GATE PASSES ONE, AND
    /// THE COMPOSITION IS THE PLACE THAT DOES.**
    public init(selfNodeId: Data, store: MessageStore,
                seenCacheCapacity: Int = Router.seenCacheCapacity,
                wipeGate: (any WipeSensitiveUseGate)? = nil) {
        precondition(selfNodeId.count == MessageId.nodeIdBytes, "selfNodeId must be \(MessageId.nodeIdBytes) bytes")
        self.selfNodeId = selfNodeId
        self.store = store
        self.seen = LruSet<Data>(capacity: seenCacheCapacity)
        self.wipeGate = wipeGate
    }

    /// True when the frame was new and has been accepted.
    @discardableResult
    public func ingest(_ frame: FrameV2, isAddressedToMe: Bool, receivedFrom: Data) -> Bool {
        // T40 (ADR-009 section 5): only MESSAGE and SOS enter durable message
        // routing. Control frames are demultiplexed to the per-relation owner
        // at the ingress ahead of this door; the bulk pair and GOODBYE are
        // refused in this profile. Gate in depth: the seal of the seen window
        // and the TTL law below stand exactly as sealed.
        guard frame.type == .message || frame.type == .sos else { return false }
        guard frame.ttl <= Router.maxTtl,
              frame.hopCount <= Router.maxTtl else { return false }

        let d = accept(frame, isAddressedToMe: isAddressedToMe, receivedFrom: receivedFrom)
        guard d.accepted else { return false }
        if d.deliver { onDeliverLocally?(frame) }
        if let fwd = d.forwardCopy { enqueue(fwd) }
        return true
    }

    private struct IngestDecision {
        let accepted: Bool
        let deliver: Bool
        let forwardCopy: FrameV2?
    }

    private func accept(_ frame: FrameV2, isAddressedToMe: Bool, receivedFrom: Data) -> IngestDecision {
        let none = IngestDecision(accepted: false, deliver: false, forwardCopy: nil)
        lock.lock()
        defer { lock.unlock() }

        if seen.contains(frame.msgId) { return none }

        // *** GS-FINAL-003 (round 636): THE ADMISSION POINT, ASKED BEFORE THE STORE -- AND THE ORDERING IS THE
        // POINT. *** Asked AFTER `store.persist` it would be A REPORT RATHER THAN A GATE: the held row would already be
        // written and a refusal would leave it standing. *That is not hypothetical: the Android round placed its first
        // gate after the tracker read and its own arm named the mistake.*
        if let gate = wipeGate, !gate.allowsSensitiveUse() { return none }

        // T42: the durable acceptance is the ONLY acceptance. A persist that did
        // not happen is a refusal -- never a memory-only success.
        switch store.persist(frame, receivedFrom: receivedFrom) {
        case .heldNew:
            seen.insert(frame.msgId)
        case .heldDuplicate:
            seen.insert(frame.msgId)
            return none
        case .rejectedCapacity, .failedStorage:
            return none
        case .rejectedTombstone:
            // GS-STORE-004 (round 337): A RETIRED MESSAGE IS NOT RE-ACCEPTED, and the router treateth it exactly as
            // a refusal -- because it IS one: the store deliberately let this id go, and re-accepting it would
            // RE-OPEN THE DOOR THE RETIREMENT CLOSED. It is NOT inserted into `seen` either, because the store's own
            // tombstone is the durable authority on that decision, and a memory-only echo of it would be a second
            // authority that could drift.
            return none
        }

        // The hint's ONLY power is to suppress a needless relay (section 14:
        // "public rotating routing tags are optimization hints"). It never
        // decideth a RECIPIENT: the recipient decision is the verified sealed
        // inner policy, taken at the inbox (T37) -- and a directed message whose
        // tag does not match is still attempted there, bounded.
        let deliver = isAddressedToMe
        let shouldRelay = !(isAddressedToMe && frame.type != .sos)
        let forwardCopy = shouldRelay ? Router.forwardCopyOf(frame) : nil
        return IngestDecision(accepted: true, deliver: deliver, forwardCopy: forwardCopy)
    }

    /// Returns the copy of `frame` ready to be relayed: TTL decremented and hop
    /// count incremented EXACTLY ONCE. The one owner of that arithmetic -- the
    /// accept path and the T42 pump both call it, and neither rewrites TTL again.
    public func forwardCopy(_ frame: FrameV2) -> FrameV2? { Router.forwardCopyOf(frame) }

    /// The pure form, usable without an instance (the pump holdeth one too).
    public static func forwardCopyOf(_ frame: FrameV2) -> FrameV2? {
        guard frame.ttl > 1, Int(frame.hopCount) + 1 <= FrameV2.maxTtl else { return nil }
        return FrameV2(type: frame.type,
                       msgId: frame.msgId,
                       routingTag: frame.routingTag,
                       ttl: frame.ttl - 1,
                       hopCount: frame.hopCount + 1,
                       flags: frame.flags,
                       payload: frame.payload)
    }

    private func enqueue(_ frame: FrameV2) {
        lock.lock(); defer { lock.unlock() }
        queue.append(frame)
        queue.sort { priority($0) < priority($1) }
        if queue.count > 512 {
            queue.removeLast(queue.count - 512)
        }
    }

    /// T42: the order is the CANONICAL priority bits (3-bit priority_mask:
    /// SOS 0 / DIRECT 1 / GROUP 2 / BROADCAST 3 / BULK 4), not a table over the
    /// frame TYPE. A DIRECT message and a GROUP message are both `.message`, and
    /// the old table sorted them alike; the wire carrieth the truth.
    private func priority(_ f: FrameV2) -> Int {
        Priority.fromFlags(f.flags).rawValue
    }

    public func drain(limit: Int) -> [FrameV2] {
        lock.lock(); defer { lock.unlock() }
        let out = Array(queue.prefix(limit))
        queue.removeFirst(out.count)
        return out
    }

    /// Compute what a peer appears to lack, in strict canonical priority order.
    /// The Swift twin of Android `Router.framesPeerLacks`: the bloom is a HINT,
    /// so a saturated one suppresses an offer here -- which is exactly why the
    /// EXACT inventory/WANT road must exist beside it (T42's W07 witness).
    public func framesPeerLacks(_ peerDigest: BloomDigest, limit: Int = 32) -> [FrameV2] {
        if limit <= 0 { return [] }
        var out: [FrameV2] = []
        store.forEachHeldOrderedByPriority { frame in
            if !peerDigest.mightContain(frame.msgId) {
                out.append(frame)
                if out.count >= limit { return false }
            }
            return true
        }
        return out
    }

    public func bloomDigest() -> Data {
        lock.lock(); defer { lock.unlock() }
        return BloomDigest.build(from: store.allHeldMsgIds())
    }

    /// Deterministically build a sealed MESSAGE frame around an explicit [identity] (C6.7.2).
    /// Canonical 29-byte sealed payload prefix: message_nonce[16] || pow_nonce[8] || created_at_le[4] || priority_code[1] || plaintext
    public func buildSealedMessage(
        plaintext: Data,
        recipientNodeId: Data,
        recipientStaticPub: Data,
        identity: LogicalMessageIdentity,
        priority: Priority = .direct
    ) async throws -> FrameV2 {
        precondition(recipientNodeId.count == MessageId.nodeIdBytes, "recipientNodeId must be 16 bytes")
        precondition(recipientStaticPub.count == 32, "recipientStaticPub must be 32 bytes")
        precondition(priority == .direct || priority == .group || priority == .broadcast,
                     "Invalid priority for sealed MESSAGE frame")

        let createdAtLe = identity.createdAtLe()
        let powNonce: Data
        if priority.requiresProofOfWork {
            powNonce = try await ProofOfWork.mine(
                senderNodeId: selfNodeId,
                createdAtLe: createdAtLe,
                messageNonce: identity.messageNonce,
                priorityCode: UInt8(priority.rawValue),
                typeCode: TypeV2.message.rawValue,
                plaintext: plaintext
            )
        } else {
            powNonce = Data(count: ProofOfWork.nonceBytes)
        }

        var sealedInner = Data(capacity: MessageId.messageNonceBytes + ProofOfWork.nonceBytes + 4 + 1 + plaintext.count)
        sealedInner.append(identity.messageNonce)
        sealedInner.append(powNonce)
        sealedInner.append(createdAtLe)
        sealedInner.append(UInt8(priority.rawValue))
        sealedInner.append(plaintext)

        let sealed = try SealedSender.seal(
            plaintext: sealedInner,
            senderNodeId: selfNodeId,
            recipientStaticPub: recipientStaticPub
        )
        let msgId = MessageId.derive(senderNodeId: selfNodeId, identity: identity, plaintext: plaintext)
        let routingTag = SealedSender.routingTag(
            recipientNodeId: recipientNodeId,
            epochDay: SealedSender.currentEpochDay()
        )
        var flags: UInt16 = UInt16(FrameV2.Flags.sealed) | Priority.toFlags(priority)
        if priority.requiresProofOfWork {
            flags |= UInt16(FrameV2.Flags.has_pow)
        }

        return FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: routingTag,
            ttl: Router.defaultTtl,
            hopCount: 0,
            flags: flags,
            payload: sealed
        )
    }

    /// Author a NEW sealed message by creating an explicit [LogicalMessageIdentity] once.
    public func authorSealedMessage(
        plaintext: Data,
        recipientNodeId: Data,
        recipientStaticPub: Data,
        priority: Priority = .direct
    ) async throws -> FrameV2 {
        let identity = LogicalMessageIdentity.createNew()
        return try await buildSealedMessage(
            plaintext: plaintext,
            recipientNodeId: recipientNodeId,
            recipientStaticPub: recipientStaticPub,
            identity: identity,
            priority: priority
        )
    }

    /// Open a sealed MESSAGE addressed to us and verify authenticated message policy
    /// and identity against frame headers (ADR-001 §3.3, C6.7.2).
    public func openSealedMessage(
        _ frame: FrameV2,
        ourStaticDhPriv: Data
    ) -> OpenMessageResult {
        guard frame.type == .message else {
            return .wrongFrameType
        }
        guard (frame.flags & UInt16(FrameV2.Flags.sealed)) != 0 else {
            return .missingSealedFlag
        }

        guard let opened = SealedSender.open(sealedPayload: frame.payload, recipientStaticPriv: ourStaticDhPriv) else {
            return .notForUs
        }
        let inner = Data(opened.plaintext)
        let prefixLen = MessageId.messageNonceBytes + ProofOfWork.nonceBytes + 4 + 1 // 29 bytes
        guard inner.count >= prefixLen, opened.senderNodeId.count == MessageId.nodeIdBytes else {
            return .malformed
        }
        let messageNonce = Data(inner.prefix(MessageId.messageNonceBytes))
        let powNonce = Data(inner.subdata(in: MessageId.messageNonceBytes..<(MessageId.messageNonceBytes + ProofOfWork.nonceBytes)))
        let createdAtLe = Data(inner.subdata(in: (MessageId.messageNonceBytes + ProofOfWork.nonceBytes)..<(MessageId.messageNonceBytes + ProofOfWork.nonceBytes + 4)))
        let priorityCode = inner[MessageId.messageNonceBytes + ProofOfWork.nonceBytes + 4]
        let plaintext = Data(inner.suffix(from: prefixLen))

        guard let sealedPriority = Priority.fromCode(Int(priorityCode)) else {
            return .policyMismatch
        }
        guard sealedPriority == .direct || sealedPriority == .group || sealedPriority == .broadcast else {
            return .policyMismatch
        }

        guard let headerPriority = Priority.fromFlagsStrict(frame.flags) else {
            return .policyMismatch
        }

        guard headerPriority == sealedPriority else {
            return .policyMismatch
        }

        if sealedPriority == .direct {
            guard (frame.flags & UInt16(FrameV2.Flags.has_pow)) == 0 else {
                return .policyMismatch
            }
            guard powNonce.allSatisfy({ $0 == 0 }) else {
                return .policyMismatch
            }
        } else {
            guard (frame.flags & UInt16(FrameV2.Flags.has_pow)) != 0 else {
                return .policyMismatch
            }
        }

        let createdAt = Int64(createdAtLe[0]) |
                        (Int64(createdAtLe[1]) << 8) |
                        (Int64(createdAtLe[2]) << 16) |
                        (Int64(createdAtLe[3]) << 24)
        let identity = LogicalMessageIdentity.of(createdAtEpochSeconds: createdAt, messageNonce: messageNonce)

        let expectedMsgId = MessageId.derive(senderNodeId: opened.senderNodeId, identity: identity, plaintext: plaintext)
        guard expectedMsgId == frame.msgId else {
            return .messageIdMismatch
        }

        if sealedPriority.requiresProofOfWork {
            let powValid = ProofOfWork.verify(
                powNonce: powNonce,
                senderNodeId: opened.senderNodeId,
                createdAtLe: createdAtLe,
                messageNonce: messageNonce,
                priorityCode: UInt8(sealedPriority.rawValue),
                typeCode: frame.type.rawValue,
                plaintext: plaintext
            )
            guard powValid else {
                return .invalidProofOfWork
            }
        }

        return .accepted(PolicyCheckedOpenedMessage(
            senderNodeId: opened.senderNodeId,
            identity: identity,
            powNonce: powNonce,
            priority: sealedPriority,
            plaintext: plaintext,
            frame: frame
        ))
    }
}

/// Typed outcome of `Router.openSealedMessage`.
public enum OpenMessageResult: Equatable {
    case accepted(PolicyCheckedOpenedMessage)
    case notForUs
    case malformed
    case wrongFrameType
    case missingSealedFlag
    case policyMismatch
    case messageIdMismatch
    case invalidProofOfWork
}

/// Result of opening a verified sealed MESSAGE.
public struct PolicyCheckedOpenedMessage: Equatable {
    public let senderNodeId: Data
    public let identity: LogicalMessageIdentity
    public let powNonce: Data
    public let priority: Priority
    public let plaintext: Data
    public let frame: FrameV2

    public var createdAtEpochSeconds: Int64 { identity.createdAtEpochSeconds }
    public var messageNonce: Data { identity.messageNonce }

    public init(
        senderNodeId: Data,
        identity: LogicalMessageIdentity,
        powNonce: Data,
        priority: Priority,
        plaintext: Data,
        frame: FrameV2
    ) {
        self.senderNodeId = senderNodeId
        self.identity = identity
        self.powNonce = powNonce
        self.priority = priority
        self.plaintext = plaintext
        self.frame = frame
    }
}
