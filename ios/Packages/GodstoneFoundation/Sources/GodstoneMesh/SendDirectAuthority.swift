// T36 contract (iOS isle) -- twin of SendDirectAuthority.kt, composed read-only over the sealed
// iOS authorities (SignedMessageV1 / MessageId / Router.buildSealedMessage /
// enqueueDirectOutbound / the peer trust law).
//
// Card law: SendDirect(recipientTrustRef, utf8Body) returns an immutable logical message ID
// ONLY AFTER durable enqueue. Resolve the CURRENT approved recipient key/version, generate ONE
// CSPRNG nonce, sign/seal ONCE, commit held frame + SINGLE_RECIPIENT delivery row atomically.
// Retry loads identical persisted bytes; changed recipient/body/priority creates a NEW logical
// send. The 400-byte UTF-8 DIRECT body profile is enforced BEFORE signing.
import Foundation
import GodstoneCore

// --------------------------------------------------------------------------- hex (redacted)

enum CourtHex {
    private static let hexChars: [Character] = [
        "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f",
    ]
    static func redacted(_ data: Data) -> String {
        let b = [UInt8](data)
        if b.isEmpty { return "-" }
        if b.count <= 8 { return hex(b) }
        return hex(Array(b[0..<4])) + ".." + hex(Array(b[(b.count - 4)..<b.count]))
    }
    private static func hex(_ b: [UInt8]) -> String {
        var s = ""
        for byte in b {
            s.append(hexChars[Int(byte >> 4)])
            s.append(hexChars[Int(byte & 0xF)])
        }
        return s
    }
}

// --------------------------------------------------------------------------- command

/// Explicit send intent: caller-minted dedup token, recipient trust ref, raw UTF-8 body bytes.
public final class SendDirectCommand: Sendable, Equatable {
    public static let intentIdBytesMax: Int = 64
    public let intentId: Data
    public let recipientTrustRef: Data
    public let bodyUtf8: [UInt8]

    private init(intentId: Data, recipientTrustRef: Data, bodyUtf8: [UInt8]) {
        self.intentId = intentId
        self.recipientTrustRef = recipientTrustRef
        self.bodyUtf8 = bodyUtf8
    }

    /// Validates the COMMAND shape only (the body profile gate lives in the authority).
    public static func of(intentId: Data, recipientTrustRef: Data, bodyUtf8: [UInt8]) -> SendDirectCommand? {
        guard intentId.count >= 1, intentId.count <= intentIdBytesMax else { return nil }
        guard recipientTrustRef.count == MessageId.nodeIdBytes else { return nil }
        return SendDirectCommand(intentId: intentId, recipientTrustRef: recipientTrustRef, bodyUtf8: bodyUtf8)
    }

    public static func == (l: SendDirectCommand, r: SendDirectCommand) -> Bool {
        l.intentId == r.intentId && l.recipientTrustRef == r.recipientTrustRef && l.bodyUtf8 == r.bodyUtf8
    }

    public var description: String {
        "SendDirectCommand(intent=" + CourtHex.redacted(intentId) + ",ref=" + CourtHex.redacted(recipientTrustRef)
            + ",bodyBytes=" + String(bodyUtf8.count) + ")"
    }
}

// --------------------------------------------------------------------------- journal

/// Monotone intent ladder; a completion step moves EXACTLY one rung.
public enum IntentStateRank: Int, Sendable, Comparable {
    case authored = 0
    case committed = 1

    public static func < (l: IntentStateRank, r: IntentStateRank) -> Bool { l.rawValue < r.rawValue }
}

/// Pinned facts of one accepted logical send. verifyLogicalIdentity re-derives the msgId from
/// the pinned bytes: proof the handed id IS the durably committed id.
public final class JournalEntry: Sendable, Equatable {
    public let intentId: Data
    public let logicalMessageId: Data
    public let signedPlaintextBytes: Data
    public let canonicalFrameBytes: Data
    public let recipientNodeId: Data
    public let recipientStaticDhPub: Data
    public let acceptedGeneration: UInt32
    public let bindingDigest: Data
    public let createdAtEpochSeconds: Int64
    public let messageNonce: Data
    public let priorityCode: Int
    public let stateRank: IntentStateRank

    public init?(
        intentId: Data,
        logicalMessageId: Data,
        signedPlaintextBytes: Data,
        canonicalFrameBytes: Data,
        recipientNodeId: Data,
        recipientStaticDhPub: Data,
        acceptedGeneration: UInt32,
        bindingDigest: Data,
        createdAtEpochSeconds: Int64,
        messageNonce: Data,
        priorityCode: Int,
        stateRank: IntentStateRank
    ) {
        guard intentId.count >= 1, intentId.count <= SendDirectCommand.intentIdBytesMax else { return nil }
        guard logicalMessageId.count == MessageId.nodeIdBytes, messageNonce.count == MessageId.messageNonceBytes else { return nil }
        guard recipientNodeId.count == MessageId.nodeIdBytes, recipientStaticDhPub.count == 32 else { return nil }
        guard bindingDigest.count == 32 else { return nil }
        guard !signedPlaintextBytes.isEmpty, !canonicalFrameBytes.isEmpty else { return nil }
        self.intentId = intentId
        self.logicalMessageId = logicalMessageId
        self.signedPlaintextBytes = signedPlaintextBytes
        self.canonicalFrameBytes = canonicalFrameBytes
        self.recipientNodeId = recipientNodeId
        self.recipientStaticDhPub = recipientStaticDhPub
        self.acceptedGeneration = acceptedGeneration
        self.bindingDigest = bindingDigest
        self.createdAtEpochSeconds = createdAtEpochSeconds
        self.messageNonce = messageNonce
        self.priorityCode = priorityCode
        self.stateRank = stateRank
    }

    public func verifyLogicalIdentity(senderNodeId: Data) -> Bool {
        MessageId.derive(senderNodeId: senderNodeId, createdAtEpochSeconds: createdAtEpochSeconds,
                         messageNonce: messageNonce, plaintext: signedPlaintextBytes)
            == logicalMessageId
    }

    public static func == (l: JournalEntry, r: JournalEntry) -> Bool {
        l.intentId == r.intentId && l.logicalMessageId == r.logicalMessageId
            && l.signedPlaintextBytes == r.signedPlaintextBytes && l.canonicalFrameBytes == r.canonicalFrameBytes
            && l.recipientNodeId == r.recipientNodeId && l.recipientStaticDhPub == r.recipientStaticDhPub
            && l.acceptedGeneration == r.acceptedGeneration && l.bindingDigest == r.bindingDigest
            && l.createdAtEpochSeconds == r.createdAtEpochSeconds && l.messageNonce == r.messageNonce
            && l.priorityCode == r.priorityCode && l.stateRank == r.stateRank
    }

    public var description: String {
        "JournalEntry(intent=" + CourtHex.redacted(intentId) + ",id=" + CourtHex.redacted(logicalMessageId)
            + ",recip=" + CourtHex.redacted(recipientNodeId) + ",gen=" + String(acceptedGeneration)
            + ",created=" + String(createdAtEpochSeconds) + ",prio=" + String(priorityCode)
            + ",rank=" + String(stateRank.rawValue) + ")"
    }

    /// Defensive copy through the value-typed boundary (Data is value semantic; the pin is frozen).
    func copied() -> JournalEntry {
        JournalEntry(intentId: intentId, logicalMessageId: logicalMessageId,
                     signedPlaintextBytes: signedPlaintextBytes, canonicalFrameBytes: canonicalFrameBytes,
                     recipientNodeId: recipientNodeId, recipientStaticDhPub: recipientStaticDhPub,
                     acceptedGeneration: acceptedGeneration, bindingDigest: bindingDigest,
                     createdAtEpochSeconds: createdAtEpochSeconds, messageNonce: messageNonce,
                     priorityCode: priorityCode, stateRank: stateRank)!
    }
}

public enum JournalInsertResult: Sendable, Equatable {
    case stored
    case duplicate
    case storageFailure
}

public enum JournalAdvanceResult: Sendable, Equatable {
    case advanced
    case stale
    case noSuchEntry
    case storageFailure
}

public protocol OutboundIntentJournal: AnyObject, Sendable {
    func load(_ intentId: Data) -> JournalEntry?
    func insertIfAbsent(_ entry: JournalEntry) -> JournalInsertResult
    func advance(intentId: Data, from: IntentStateRank, to: IntentStateRank) -> JournalAdvanceResult
}

/// Load distinguishes absent from storage fault; insert-if-absent is atomic; advance is the
/// single explicit transition with token revalidation.
public final class InMemoryOutboundIntentJournal: OutboundIntentJournal, @unchecked Sendable {
    private struct Key: Hashable, Equatable { let bytes: [UInt8] }
    private let lock = NSLock()
    private var rows: [Key: JournalEntry] = [:]

    public init() {}

    public func load(_ intentId: Data) -> JournalEntry? {
        lock.lock(); defer { lock.unlock() }
        return rows[Key(bytes: [UInt8](intentId))]?.copied()
    }

    public func insertIfAbsent(_ entry: JournalEntry) -> JournalInsertResult {
        lock.lock(); defer { lock.unlock() }
        let k = Key(bytes: [UInt8](entry.intentId))
        if rows[k] != nil { return .duplicate }
        rows[k] = entry
        return .stored
    }

    /// `to` must sit exactly one rung above `from` and the row must stand at `from` -- else stale.
    public func advance(intentId: Data, from: IntentStateRank, to: IntentStateRank) -> JournalAdvanceResult {
        lock.lock(); defer { lock.unlock() }
        let k = Key(bytes: [UInt8](intentId))
        guard let cur = rows[k] else { return .noSuchEntry }
        guard to.rawValue == from.rawValue + 1 else { return .stale }
        guard cur.stateRank == from else { return .stale }
        guard let moved = JournalEntry(intentId: cur.intentId, logicalMessageId: cur.logicalMessageId,
                                       signedPlaintextBytes: cur.signedPlaintextBytes,
                                       canonicalFrameBytes: cur.canonicalFrameBytes,
                                       recipientNodeId: cur.recipientNodeId,
                                       recipientStaticDhPub: cur.recipientStaticDhPub,
                                       acceptedGeneration: cur.acceptedGeneration, bindingDigest: cur.bindingDigest,
                                       createdAtEpochSeconds: cur.createdAtEpochSeconds,
                                       messageNonce: cur.messageNonce, priorityCode: cur.priorityCode,
                                       stateRank: to) else { return .stale }
        rows[k] = moved
        return .advanced
    }

    public func size() -> Int {
        lock.lock(); defer { lock.unlock() }
        return rows.count
    }
}

// --------------------------------------------------------------------------- trust

/// Approved recipient material, resolved ONCE per fresh accept.
public enum ResolvedRecipient: Sendable, Equatable {
    case approved(recipientNodeId: Data, recipientSigningPub: Data, recipientStaticDhPub: Data,
                  acceptedGeneration: UInt32)
    case absent
    case notApproved(reason: String)
    case revoked
    case corrupt(reason: String)
    case storageFailure
    case invalidArgument
}

public protocol RecipientTrustResolver: Sendable {
    func resolve(recipientTrustRef: Data) -> ResolvedRecipient
}

/// The default resolver mirrors the sealed BoundRecipientKeyResolver policy EXACTLY: only
/// TOFU_PINNED / USER_VERIFIED verified records resolve approved; every other lookup case gets
/// its OWN typed rejection (failure distinguished from empty success).
final class TrustedPeerIdentityResolver: RecipientTrustResolver, @unchecked Sendable {
    private let source: PeerIdentityLookupSource

    init(source: PeerIdentityLookupSource) { self.source = source }

    func resolve(recipientTrustRef: Data) -> ResolvedRecipient {
        guard recipientTrustRef.count == MessageId.nodeIdBytes else { return .invalidArgument }
        let lookup = source.lookup(recipientTrustRef)
        switch lookup {
        case .notFound:
            return .absent
        case .verified(let v):
            guard v.trustLevel == .tofuPinned || v.trustLevel == .userVerified else {
                return .notApproved(reason: "trust-level " + String(describing: v.trustLevel))
            }
            guard v.nodeId.count == MessageId.nodeIdBytes, v.signingPublicKey.count == SignedMessageV1.pubLen,
                  v.acceptedStaticDhPublicKey.count == SignedMessageV1.pubLen else {
                return .corrupt(reason: "approved record field widths")
            }
            return .approved(recipientNodeId: v.nodeId, recipientSigningPub: v.signingPublicKey,
                             recipientStaticDhPub: v.acceptedStaticDhPublicKey,
                             acceptedGeneration: v.acceptedGeneration)
        case .quarantined:
            return .notApproved(reason: "quarantined")
        case .revoked:
            return .revoked
        case .corrupt(let reason):
            return .corrupt(reason: String(describing: reason))
        case .storageFailure:
            return .storageFailure
        case .invalidArgument:
            return .invalidArgument
        }
    }
}

// --------------------------------------------------------------------------- seams

/// The keystore seam: the frozen MeshIdentity keeps its private material private; the
/// composition root / court injects the 32-byte halves here. Coherence is proven at the
/// authority's init.
public protocol SenderSigningKeys: Sendable {
    var identityPrivSeed: Data { get }
    var identityPub32: Data { get }
}

public final class SigningKeysAdapter: SenderSigningKeys, @unchecked Sendable {
    private let seed: Data
    private let pub: Data
    public init(seed: Data, pub: Data) {
        precondition(seed.count == 32 && pub.count == 32, "Ed25519 key material must be 32 bytes per half")
        self.seed = seed
        self.pub = pub
    }
    public var identityPrivSeed: Data { seed }
    public var identityPub32: Data { pub }
    public var description: String { "SigningKeysAdapter(pub=" + CourtHex.redacted(pub) + ")" }
}

public protocol LogicalIdentityFactory: Sendable {
    func create(nowEpochSeconds: Int64) -> LogicalMessageIdentity
}

public struct DefaultLogicalIdentityFactory: LogicalIdentityFactory {
    public init() {}
    public func create(nowEpochSeconds: Int64) -> LogicalMessageIdentity {
        LogicalMessageIdentity.createNew(nowEpochSeconds: nowEpochSeconds)
    }
}

public struct SenderTime: Sendable, Equatable {
    public let createdAtEpochSeconds: Int64
    public let timeQuality: TimeQuality
    public init(createdAtEpochSeconds: Int64, timeQuality: TimeQuality) {
        self.createdAtEpochSeconds = createdAtEpochSeconds
        self.timeQuality = timeQuality
    }
}

public protocol SenderClock: Sendable {
    func now() -> SenderTime
}

public struct SystemSenderClock: SenderClock {
    public init() {}
    public func now() -> SenderTime {
        let wall = Int64(Date().timeIntervalSince1970)
        return wall > 0 ? SenderTime(createdAtEpochSeconds: wall, timeQuality: .userConfirmed)
                        : SenderTime(createdAtEpochSeconds: 0, timeQuality: .unknown)
    }
}

// --------------------------------------------------------------------------- result

/// Every refusal names its cause (failure distinguished from empty success).
public enum SendDirectRejection: Int, Sendable, Equatable {
    case bodyEmpty, bodyTooLarge, bodyNotUtf8, intentIdMalformed, trustRefMalformed
    case recipientAbsent, recipientNotApproved, recipientRevoked, recipientCorrupt, recipientStorageFailure
    case clockUnbound, identityCreationFailed, senderIdentityUnbound, journalStorageFailure
    case enqueueCanonicMismatch, enqueueCapacity, enqueueConflictRecipient, enqueueTerminalState
    case enqueueInconsistent, enqueueStorageFailure, enqueueInvalidArgument
}

/// durablyEnqueued is the ONLY carrier of the immutable logical id, and only after the durable
/// commit proved itself; rejected carries no id at all.
public enum SendDirectResult: Sendable, Equatable {
    case durablyEnqueued(logicalMessageId: Data, fromRetry: Bool)
    case rejected(reason: SendDirectRejection)
}

// --------------------------------------------------------------------------- authority

/// The atomic authored send command. Composes the sealed authorities; owns only the journal.
public final class SendDirectAuthority: @unchecked Sendable {
    public static let bindingDomainText = "GMP2-SEND-DIRECT-BIND-V1"

    private let identity: MeshIdentity
    private let signingKeys: SenderSigningKeys
    private let router: Router
    private let store: MessageStore
    private let trustResolver: RecipientTrustResolver
    private let journal: OutboundIntentJournal
    private let identityFactory: LogicalIdentityFactory
    private let clock: SenderClock

    public init(
        identity: MeshIdentity,
        signingKeys: SenderSigningKeys,
        router: Router,
        store: MessageStore,
        trustResolver: RecipientTrustResolver,
        journal: OutboundIntentJournal,
        identityFactory: LogicalIdentityFactory = DefaultLogicalIdentityFactory(),
        clock: SenderClock = SystemSenderClock()
    ) {
        precondition(identity.nodeId == SignedMessageV1.nodeIdOf(identity.signingPublicKey),
                     "the send authority must own its key: node_id is not BLAKE2s-128(identity_pub)")
        precondition(signingKeys.identityPub32 == identity.signingPublicKey,
                     "the keystore public half must cohere with the identity's")
        precondition(signingKeys.identityPrivSeed.count == 32, "the Ed25519 seed must be 32 bytes")
        self.identity = identity
        self.signingKeys = signingKeys
        self.router = router
        self.store = store
        self.trustResolver = trustResolver
        self.journal = journal
        self.identityFactory = identityFactory
        self.clock = clock
    }

    /// The command entry: the lab profile ships DIRECT only.
    public func sendDirect(_ command: SendDirectCommand) async -> SendDirectResult {
        await sendDirect(command, priority: .direct)
    }

    /// The internal door the profile-refutation and binding-coverage probes drive.
    public func sendDirect(_ command: SendDirectCommand, priority: Priority) async -> SendDirectResult {
        // ---- the body profile stands BEFORE every authoring primitive (card law) ----
        guard !command.bodyUtf8.isEmpty else { return .rejected(reason: .bodyEmpty) }
        guard command.bodyUtf8.count <= SignedMessageV1.bodyMax else { return .rejected(reason: .bodyTooLarge) }
        guard SignedMessageV1.isWellFormedUtf8(command.bodyUtf8) else { return .rejected(reason: .bodyNotUtf8) }
        guard priority == .direct else { return .rejected(reason: .enqueueInvalidArgument) }

        let digest = SendDirectAuthority.bindingDigest(trustRef: command.recipientTrustRef,
                                                      body: command.bodyUtf8,
                                                      priorityCode: Int(priority.rawValue))

        // ---- the pinned facts answer first: a retry LOADS, it does not re-create ----
        if let row = journal.load(command.intentId), row.bindingDigest == digest {
            guard row.verifyLogicalIdentity(senderNodeId: identity.nodeId) else {
                return .rejected(reason: .enqueueCanonicMismatch)
            }
            guard let frame = FrameV2.decode(row.canonicalFrameBytes), frame.type == .message,
                  (frame.flags & UInt16(FrameV2.Flags.sealed)) != 0,
                  frame.msgId == row.logicalMessageId else {
                return .rejected(reason: .enqueueCanonicMismatch)
            }
            let replay = store.enqueueDirectOutbound(frame, expectedRecipient: row.recipientNodeId,
                                                    localOriginNodeId: identity.nodeId)
            switch replay {
            case .created, .alreadyQueuedSameBinding:
                advanceQuietly(intentId: command.intentId, from: row.stateRank, to: .committed)
                return .durablyEnqueued(logicalMessageId: row.logicalMessageId, fromRetry: true)
            case .canonicalFrameMismatch: return .rejected(reason: .enqueueCanonicMismatch)
            case .rejectedCapacity:       return .rejected(reason: .enqueueCapacity)
            case .conflictRecipient:      return .rejected(reason: .enqueueConflictRecipient)
            case .rejectedTerminalState:  return .rejected(reason: .enqueueTerminalState)
            case .inconsistentState:      return .rejected(reason: .enqueueInconsistent)
            case .storageFailure:         return .rejected(reason: .enqueueStorageFailure)
            case .invalidArgument:        return .rejected(reason: .enqueueInvalidArgument)
            }
        }

        // ---- fresh accept: resolve the CURRENT approved material ONCE ----
        var recipientNodeId = Data()
        var recipientStaticDhPub = Data()
        var acceptedGeneration: UInt32 = 0
        switch trustResolver.resolve(recipientTrustRef: command.recipientTrustRef) {
        case .approved(let nodeId, let signingPub, let staticDhPub, let generation):
            guard nodeId.count == MessageId.nodeIdBytes, signingPub.count == SignedMessageV1.pubLen,
                  staticDhPub.count == SignedMessageV1.pubLen else {
                return .rejected(reason: .recipientCorrupt)
            }
            recipientNodeId = nodeId
            recipientStaticDhPub = staticDhPub
            acceptedGeneration = generation
        case .absent:          return .rejected(reason: .recipientAbsent)
        case .notApproved:     return .rejected(reason: .recipientNotApproved)
        case .revoked:         return .rejected(reason: .recipientRevoked)
        case .corrupt:         return .rejected(reason: .recipientCorrupt)
        case .storageFailure:  return .rejected(reason: .recipientStorageFailure)
        case .invalidArgument: return .rejected(reason: .trustRefMalformed)
        }

        let t = clock.now()
        guard (t.createdAtEpochSeconds == 0) == (t.timeQuality == .unknown) else {
            return .rejected(reason: .clockUnbound)
        }
        let msgIdentity = identityFactory.create(nowEpochSeconds: t.createdAtEpochSeconds)
        guard msgIdentity.messageNonce.count == MessageId.messageNonceBytes else {
            return .rejected(reason: .identityCreationFailed)
        }

        // ---- sign ONCE through the sealed T35 authoring law ----
        let signedPlaintext: Data
        do {
            signedPlaintext = try SignedMessageV1.author(
                senderIdentityPriv: signingKeys.identityPrivSeed,
                senderIdentityPub: identity.signingPublicKey,
                senderNodeId: identity.nodeId,
                recipientNodeId: recipientNodeId,
                messageNonce: msgIdentity.messageNonce,
                createdAtEpochSeconds: msgIdentity.createdAtEpochSeconds,
                priority: .direct,
                timeQuality: t.timeQuality,
                bodyUtf8: Data(command.bodyUtf8))
        } catch { return .rejected(reason: .enqueueInvalidArgument) }

        // ---- seal ONCE through the canonical authority (hot path composed-via) ----
        let frame: FrameV2
        do {
            frame = try await router.buildSealedMessage(
                plaintext: signedPlaintext,
                recipientNodeId: recipientNodeId,
                recipientStaticPub: recipientStaticDhPub,
                identity: msgIdentity,
                priority: priority)
        } catch { return .rejected(reason: .enqueueInvalidArgument) }

        // the two derivations must agree before ANYTHING is written (positive cross-check)
        let expectId = MessageId.derive(senderNodeId: identity.nodeId,
                                         createdAtEpochSeconds: msgIdentity.createdAtEpochSeconds,
                                         messageNonce: msgIdentity.messageNonce,
                                         plaintext: signedPlaintext)
        guard frame.msgId == expectId,
              expectId == MessageId.derive(senderNodeId: identity.nodeId, identity: msgIdentity,
                                           plaintext: signedPlaintext) else {
            return .rejected(reason: .enqueueCanonicMismatch)
        }

        // ---- WRITE-AHEAD the ledger BEFORE the store transaction ----
        guard let entry = JournalEntry(
            intentId: command.intentId, logicalMessageId: expectId,
            signedPlaintextBytes: signedPlaintext, canonicalFrameBytes: frame.encode(),
            recipientNodeId: recipientNodeId, recipientStaticDhPub: recipientStaticDhPub,
            acceptedGeneration: acceptedGeneration, bindingDigest: digest,
            createdAtEpochSeconds: msgIdentity.createdAtEpochSeconds, messageNonce: msgIdentity.messageNonce,
            priorityCode: Int(priority.rawValue), stateRank: .authored) else {
            return .rejected(reason: .intentIdMalformed)
        }
        switch journal.insertIfAbsent(entry) {
        case .stored, .duplicate: break   // raced or replayed: the store transaction governs
        case .storageFailure: return .rejected(reason: .journalStorageFailure)
        }

        // ---- the ONE durable commit: held frame + SINGLE_RECIPIENT delivery row, atomic ----
        let enq = store.enqueueDirectOutbound(frame, expectedRecipient: recipientNodeId,
                                             localOriginNodeId: identity.nodeId)
        switch enq {
        case .created:
            advanceQuietly(intentId: command.intentId, from: .authored, to: .committed)
            return .durablyEnqueued(logicalMessageId: expectId, fromRetry: false)
        case .alreadyQueuedSameBinding:
            advanceQuietly(intentId: command.intentId, from: .authored, to: .committed)
            return .durablyEnqueued(logicalMessageId: expectId, fromRetry: true)
        case .canonicalFrameMismatch: return .rejected(reason: .enqueueCanonicMismatch)
        case .rejectedCapacity:       return .rejected(reason: .enqueueCapacity)
        case .conflictRecipient:      return .rejected(reason: .enqueueConflictRecipient)
        case .rejectedTerminalState:  return .rejected(reason: .enqueueTerminalState)
        case .inconsistentState:      return .rejected(reason: .enqueueInconsistent)
        case .storageFailure:         return .rejected(reason: .enqueueStorageFailure)
        case .invalidArgument:        return .rejected(reason: .enqueueInvalidArgument)
        }
    }

    /// An advance failure never revokes a proven durable commit; the replay repairs the rank.
    private func advanceQuietly(intentId: Data, from: IntentStateRank, to: IntentStateRank) {
        _ = journal.advance(intentId: intentId, from: from, to: to)
    }

    /// BLAKE2s-256 over domain || trustRef || [priority code] || body. Covers COMMAND facts only
    /// (never live key material): rotation behind a pinned intent cannot move the replay;
    /// changed content under one token never replays.
    public static func bindingDigest(trustRef: Data, body: [UInt8], priorityCode: Int) -> Data {
        var input = [UInt8](bindingDomainText.utf8)
        input.append(contentsOf: [UInt8](trustRef))
        input.append(UInt8(priorityCode & 0xFF))
        input.append(contentsOf: body)
        return Blake2s.hash(Data(input), digestLength: 32)
    }
}
