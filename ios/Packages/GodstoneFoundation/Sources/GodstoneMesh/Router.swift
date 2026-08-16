import Foundation
import GodstoneCore

/// Delay-tolerant epidemic router, GMP/2 (ADR-001, ADR-008, C6.7.1).
///
/// V4: `ingest` now takes `FrameV2`.
public final class Router {

    public static let defaultTtl: UInt8 = FrameV2.defaultTtl
    public static let maxTtl: UInt8 = FrameV2.maxTtl
    private static let seenCacheCapacity = 16_384

    public var selfNodeId: Data
    private var seen: LruSet<Data>
    private var queue: [FrameV2] = []
    private let lock = NSLock()

    public var onDeliverLocally: ((FrameV2) -> Void)?
    public var onForward: ((FrameV2) -> Void)?

    /// Optional durable hold. When attached, the anti-entropy digest is built
    /// from the store's held msg_ids (the set of frames this node CARRIES),
    /// matching Android.
    public var store: MessageStore?

    public convenience init() {
        self.init(selfNodeId: Data(repeating: 0, count: 16), seenCacheCapacity: Router.seenCacheCapacity)
    }

    public convenience init(selfNodeId: Data) {
        self.init(selfNodeId: selfNodeId, seenCacheCapacity: Router.seenCacheCapacity)
    }

    /// Test-only init with a smaller dedup window.
    internal init(selfNodeId: Data = Data(repeating: 0, count: 16), seenCacheCapacity: Int) {
        self.selfNodeId = selfNodeId
        self.seen = LruSet<Data>(capacity: seenCacheCapacity)
    }

    /// True when the frame was new and has been accepted.
    @discardableResult
    public func ingest(_ frame: FrameV2, isAddressedToMe: Bool, receivedFrom: Data) -> Bool {
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

        if let store {
            switch store.persist(frame, receivedFrom: receivedFrom) {
            case .heldNew:
                seen.insert(frame.msgId)
            case .heldDuplicate:
                seen.insert(frame.msgId)
                return none
            case .rejectedCapacity, .failedStorage:
                return none
            }
        } else {
            seen.insert(frame.msgId)
        }

        let deliver = isAddressedToMe
        let shouldRelay = !(isAddressedToMe && frame.type != .sos)
        var forwardCopy: FrameV2? = nil
        if shouldRelay && frame.ttl > 1 && frame.hopCount < Router.maxTtl {
            forwardCopy = FrameV2(type: frame.type,
                                  msgId: frame.msgId,
                                  routingTag: frame.routingTag,
                                  ttl: frame.ttl - 1,
                                  hopCount: frame.hopCount + 1,
                                  flags: frame.flags,
                                  payload: frame.payload)
        }
        return IngestDecision(accepted: true, deliver: deliver, forwardCopy: forwardCopy)
    }

    private func enqueue(_ frame: FrameV2) {
        lock.lock(); defer { lock.unlock() }
        queue.append(frame)
        queue.sort { priority($0) < priority($1) }
        if queue.count > 512 {
            queue.removeLast(queue.count - 512)
        }
    }

    private func priority(_ f: FrameV2) -> Int {
        switch f.type {
        case .sos:        return 0
        case .ack:        return 1
        case .hello:      return 2
        case .message:    return 3
        case .digest, .want: return 4
        case .ping, .goodbye: return 5
        case .bulk_offer, .bulk_chunk: return 6
        }
    }

    public func drain(limit: Int) -> [FrameV2] {
        lock.lock(); defer { lock.unlock() }
        let out = Array(queue.prefix(limit))
        queue.removeFirst(out.count)
        return out
    }

    public func bloomDigest() -> Data {
        lock.lock(); defer { lock.unlock() }
        guard let store else { return BloomDigest.build(from: []) }
        return BloomDigest.build(from: store.allHeldMsgIds())
    }

    /// Deterministically build a sealed MESSAGE frame around an explicit [identity] (C6.7.1).
    public func buildSealedMessage(
        plaintext: Data,
        recipientNodeId: Data,
        recipientStaticPub: Data,
        senderNodeId: Data? = nil,
        identity: LogicalMessageIdentity,
        priority: Priority = .direct
    ) async throws -> FrameV2 {
        let sender = senderNodeId ?? selfNodeId
        precondition(recipientNodeId.count == MessageId.nodeIdBytes, "recipientNodeId must be 16 bytes")
        precondition(recipientStaticPub.count == 32, "recipientStaticPub must be 32 bytes")
        precondition(sender.count == MessageId.nodeIdBytes, "senderNodeId must be 16 bytes")

        let createdAtLe = identity.createdAtLe()
        let powNonce: Data
        if priority.requiresProofOfWork {
            powNonce = try await ProofOfWork.mine(
                senderNodeId: sender,
                createdAtLe: createdAtLe,
                messageNonce: identity.messageNonce,
                typeCode: TypeV2.message.rawValue,
                plaintext: plaintext
            )
        } else {
            powNonce = Data(count: ProofOfWork.nonceBytes)
        }

        var sealedInner = Data(capacity: MessageId.messageNonceBytes + ProofOfWork.nonceBytes + 4 + plaintext.count)
        sealedInner.append(identity.messageNonce)
        sealedInner.append(powNonce)
        sealedInner.append(createdAtLe)
        sealedInner.append(plaintext)

        let sealed = try SealedSender.seal(
            plaintext: sealedInner,
            senderNodeId: sender,
            recipientStaticPub: recipientStaticPub
        )
        let msgId = MessageId.derive(senderNodeId: sender, identity: identity, plaintext: plaintext)
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
        senderNodeId: Data? = nil,
        priority: Priority = .direct
    ) async throws -> FrameV2 {
        let identity = LogicalMessageIdentity.createNew()
        return try await buildSealedMessage(
            plaintext: plaintext,
            recipientNodeId: recipientNodeId,
            recipientStaticPub: recipientStaticPub,
            senderNodeId: senderNodeId,
            identity: identity,
            priority: priority
        )
    }

    /// Open a sealed MESSAGE addressed to us and split the authenticated inner
    /// content into verified components.
    public func openSealedMessage(
        _ frame: FrameV2,
        ourStaticDhPriv: Data
    ) -> OpenMessageResult {
        guard let opened = SealedSender.open(sealedPayload: frame.payload, recipientStaticPriv: ourStaticDhPriv) else {
            return .notForUs
        }
        let inner = Data(opened.plaintext)
        let prefixLen = MessageId.messageNonceBytes + ProofOfWork.nonceBytes + 4 // 28 bytes
        guard inner.count >= prefixLen, opened.senderNodeId.count == MessageId.nodeIdBytes else {
            return .malformed
        }
        let messageNonce = Data(inner.prefix(MessageId.messageNonceBytes))
        let powNonce = Data(inner.subdata(in: MessageId.messageNonceBytes..<(MessageId.messageNonceBytes + ProofOfWork.nonceBytes)))
        let createdAtLe = Data(inner.subdata(in: (MessageId.messageNonceBytes + ProofOfWork.nonceBytes)..<prefixLen))
        let plaintext = Data(inner.suffix(from: prefixLen))

        let createdAt = Int64(createdAtLe[0]) |
                        (Int64(createdAtLe[1]) << 8) |
                        (Int64(createdAtLe[2]) << 16) |
                        (Int64(createdAtLe[3]) << 24)
        let identity = LogicalMessageIdentity.of(createdAtEpochSeconds: createdAt, messageNonce: messageNonce)

        let expectedMsgId = MessageId.derive(senderNodeId: opened.senderNodeId, identity: identity, plaintext: plaintext)
        guard expectedMsgId == frame.msgId else {
            return .messageIdMismatch
        }

        if (frame.flags & UInt16(FrameV2.Flags.has_pow)) != 0 {
            let powValid = ProofOfWork.verify(
                powNonce: powNonce,
                senderNodeId: opened.senderNodeId,
                createdAtLe: createdAtLe,
                messageNonce: messageNonce,
                typeCode: frame.type.rawValue,
                plaintext: plaintext
            )
            guard powValid else {
                return .invalidProofOfWork
            }
        }

        return .accepted(VerifiedOpenedMessage(
            senderNodeId: opened.senderNodeId,
            identity: identity,
            powNonce: powNonce,
            plaintext: plaintext,
            frame: frame
        ))
    }
}

/// Typed outcome of `Router.openSealedMessage`.
public enum OpenMessageResult: Equatable {
    case accepted(VerifiedOpenedMessage)
    case notForUs
    case malformed
    case messageIdMismatch
    case invalidProofOfWork
}

/// Result of opening a verified sealed MESSAGE.
public struct VerifiedOpenedMessage: Equatable {
    public let senderNodeId: Data
    public let identity: LogicalMessageIdentity
    public let powNonce: Data
    public let plaintext: Data
    public let frame: FrameV2

    public var createdAtEpochSeconds: Int64 { identity.createdAtEpochSeconds }
    public var messageNonce: Data { identity.messageNonce }

    public init(
        senderNodeId: Data,
        identity: LogicalMessageIdentity,
        powNonce: Data,
        plaintext: Data,
        frame: FrameV2
    ) {
        self.senderNodeId = senderNodeId
        self.identity = identity
        self.powNonce = powNonce
        self.plaintext = plaintext
        self.frame = frame
    }
}
