import Foundation

// T37 (section 14): the recipient inbox transaction -- from the authenticated
// link's bounded frame to the canonical recipient ACK, in the order the plan
// prescribes and never out of it. Twin of RecipientInboxRepository.kt.
//
// ```text
// authenticated link -> bounded decode -> local destination attempt
//   -> unseal -> canonical inner policy -> verify signed author/recipient/msgID
//   -> transaction: unique inbox + dedup + receipt-relative retention
//   -> after commit: sign canonical recipient ACK and schedule it
// duplicate valid message: no duplicate inbox; regenerate the ACK
// storage/verification failure: no ACK and no claimed local acceptance
// ```
//
// Identity doctrine (the task's objective): the immediate-hop TrustedPeer is
// NOT necessarily the end-to-end sender; neither the transport id
// (receivedFrom) nor the 4-byte routing tag may stand in for either identity.
// The sender is proven ONLY cryptographically -- the sealed layer authenticates
// the senderNodeId claim under our DH key (Router.openSealedMessage, the frozen
// policy core) and the container's Ed25519 signature plus the Blake2s-128
// id/key binding (SignedMessageV1.verify, the frozen binding laws) authenticate
// the author and bind the intended local recipient. The tag is an optimization
// hint: a mismatch never rejects (clock skew must not be mistaken for an
// authentication failure of an identity) and a match never admits (it is not
// proof); both directions are only counted into the observable census.
//
// The inbox transaction itself is the caller-bound commitInbound pair of the
// T83 store method commitInboundWithObligationAtWithFault: held insert,
// capacity enforcement and the pending ACK obligation INSERT in ONE engine
// transaction, both-or-neither. The canonical ACK is produced ONLY after that
// commit returned, by the frozen builder AckFrame.build with the section-14
// production TTL, verified through the pinned-key authenticator BEFORE filing,
// and filed together with the obligation retirement in the paired store's
// atomic step. A duplicate delivery answers from the STORED verified row --
// the very bytes first filed, never a re-signature (this host's Ed25519 layer
// signs randomized; the durable row is the truth -- the T83 finding).
//
// The repository keeps NO authoritative state: the durable store is the sole
// authority; census() is runtime telemetry only.

/// Section 14 verbatim: the production generator's initial ACK TTL is
/// explicitly 12 -- passed at THIS call site; the frozen builder's default
/// parameter (4) stands untouched.
let ackInitialTtl: UInt8 = 12
/// Section 14: unexpired ACKs and dedup tombstones stand 8 days from first
/// local receipt, on the same non-replenishing clock policy as T83.
let ackRetentionMs: Int64 = 8 * 24 * 60 * 60 * 1000
/// The public rotating tag may legitimately lag or lead this node's calendar
/// by a bounded window when peers' clocks differ; the hint census scans that
/// window only -- it is never an identity decision.
let hintWindowDays: Int64 = 1
/// A recipient ACK census for one pair never exceeds the T83 pair bound.
let pairCensusBound: Int = ackCandidatesPerPairLimit

/// Typed rejection taxonomy of the recipient inbox process. Input refusals
/// keep every table byte-for-byte; none of these arms writes anything.
enum RejectionReason: Equatable {
    case widths
    case envelope
    case notDirect
    case notForUs
    case malformed
    case policyMismatch
    case messageIdMismatch
    case proofUnbound
    case verificationFailed
    case senderRevoked
    case capacity
    case storageFailure
    case keyUnavailable
    case selfVerificationFailed
    case storedFrameCorrupt
    case cacheKeyUnsound
    case admissionQuota
}

/// The card's taxonomy of one accept-and-require-ACK transaction. New and
/// Duplicate carry the canonical recipient ACK; Rejected carries none -- a
/// rejected delivery emits no ACK and claims no local acceptance.
enum InboxCommitResult: Equatable {
    /// The frame was newly held; the canonical ACK stands filed beside it.
    case new(ack: FrameV2)
    /// The frame was already held durably; the STORED row's very bytes were
    /// returned -- never a re-signature, and no duplicate inbox content was
    /// written.
    case duplicate(ack: FrameV2)
    /// Nothing was written and no ACK was issued: the prior state stands.
    case rejected(reason: RejectionReason, detail: String?)
}

/// Sender admission policy, made BESIDE and never in place of the
/// cryptographic proof (section 14: trust is policy; proof is proof). The lab
/// composition (T54) wires the durable peer-identity authority behind it.
public protocol RecipientSenderTrustPolicy: AnyObject {
    /// False only when the sender's durable identity stands revoked.
    func admits(senderNodeId: Data) -> Bool
}

/// The fail-open default: an absent policy must not masquerade as a revoked
/// one; proof of the signature IS the identity. Width sanity still applies.
public final class AdmitAllSenders: RecipientSenderTrustPolicy, @unchecked Sendable {
    public init() {}
    public func admits(senderNodeId: Data) -> Bool { senderNodeId.count == 16 }
}

/// Runtime telemetry of one repository instance -- observable, admissible
/// never as proof; the durable store remains the sole authority.
struct InboxCensus: Equatable {
    var hintHits: Int = 0
    var hintMissesUnsealed: Int = 0
    var unsealedAccepted: Int = 0
    var verificationRejections: Int = 0
    var policyRejections: Int = 0
    var committedNew: Int = 0
    var committedDuplicate: Int = 0
    var acksIssued: Int = 0
    var acksRefusedQuota: Int = 0
    var acksRefusedKey: Int = 0
    var acksRefusedSelfVerify: Int = 0
    var storageFailures: Int = 0
}

private let t37HexDigits = Array("0123456789abcdef")

private func t37RedactedHex(_ bytes: Data?) -> String {
    guard let bytes = bytes, !bytes.isEmpty else { return bytes == nil ? "null" : "-" }
    let b = [UInt8](bytes)
    var sb = ""
    if b.count <= 8 {
        for v in b {
            sb.append(t37HexDigits[Int(v >> 4) & 0xF]); sb.append(t37HexDigits[Int(v) & 0xF])
        }
        return sb
    }
    for v in b[0..<4] {
        sb.append(t37HexDigits[Int(v >> 4) & 0xF]); sb.append(t37HexDigits[Int(v) & 0xF])
    }
    sb.append("..")
    for v in b[(b.count - 4)..<b.count] {
        sb.append(t37HexDigits[Int(v >> 4) & 0xF]); sb.append(t37HexDigits[Int(v) & 0xF])
    }
    return sb
}

private func t37RedactedAckFrame(_ frame: FrameV2) -> String {
    return "FrameV2[type=\(frame.type),msg=\(t37RedactedHex(frame.msgId)),"
        + "tag=\(t37RedactedHex(frame.routingTag)),ttl=\(frame.ttl),"
        + "hop=\(frame.hopCount),payload=\(frame.payload.count)B]"
}

final class RecipientInboxRepository: @unchecked Sendable {
    private let router: Router
    private let ourNodeId: Data
    /// The current local DH private key (32 bytes) or nil while none stands ready.
    private let localDhPrivate: () -> Data?
    /// The T83 signer seam: nodeId binding, generation pin and Ed25519 seed.
    private let signer: AckSignerSeam
    /// Pins the authentic public signing keys; consulted for OUR own key.
    private let resolver: RecipientKeyResolver
    /// The frozen authenticator: every self-produced ACK passes it pre-filing.
    private let authenticator: Ed25519AckAuthenticator
    /// The two T83 namespaces under the both-or-neither pair law.
    private let pairedStore: AckObligationStore
    /// The bound inbox commit: the T83 store method of the composing store.
    private let commitInbound: (FrameV2, Data, Data, Int64, Int64, Int64,
                                ((String) throws -> Void)?) throws -> InboundCommitResult
    /// Sender admission policy beside, never in place of, the proof.
    private let trustPolicy: RecipientSenderTrustPolicy
    /// Wall clock in whole seconds; the composition root injects the platform truth.
    private let clockSeconds: () -> Int64
    /// The rotating-tag epoch day; defaults to the sealed layer's own calendar.
    private let epochDay: () -> Int64
    /// The generation an accepted delivery pins into the obligation row.
    private let identityGeneration: () -> Int64

    init(
        router: Router,
        ourNodeId: Data,
        localDhPrivate: @escaping () -> Data?,
        signer: AckSignerSeam,
        resolver: RecipientKeyResolver,
        authenticator: Ed25519AckAuthenticator,
        pairedStore: AckObligationStore,
        commitInbound: @escaping (FrameV2, Data, Data, Int64, Int64, Int64,
                                  ((String) throws -> Void)?) throws -> InboundCommitResult,
        trustPolicy: RecipientSenderTrustPolicy = AdmitAllSenders(),
        clockSeconds: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        epochDay: @escaping () -> Int64 = { SealedSender.currentEpochDay() },
        identityGeneration: @escaping () -> Int64 = { 0 }
    ) {
        self.router = router
        self.ourNodeId = Data(ourNodeId)
        self.localDhPrivate = localDhPrivate
        self.signer = signer
        self.resolver = resolver
        self.authenticator = authenticator
        self.pairedStore = pairedStore
        self.commitInbound = commitInbound
        self.trustPolicy = trustPolicy
        self.clockSeconds = clockSeconds
        self.epochDay = epochDay
        self.identityGeneration = identityGeneration
    }

    // ------------------------------------------------------------------ telemetry

    private let countersLock = NSLock()
    private var counters = InboxCensus()

    /// The current census of this receiving process (telemetry, not authority).
    func census() -> InboxCensus {
        countersLock.lock()
        let snap = counters
        countersLock.unlock()
        return snap
    }

    private func bump(_ keyPath: WritableKeyPath) {
        countersLock.lock()
        switch keyPath {
        case .hintHit: counters.hintHits += 1
        case .hintMiss: counters.hintMissesUnsealed += 1
        case .unsealed: counters.unsealedAccepted += 1
        case .verification: counters.verificationRejections += 1
        case .policy: counters.policyRejections += 1
        case .newAdmit: counters.committedNew += 1
        case .duplicateAdmit: counters.committedDuplicate += 1
        case .issued: counters.acksIssued += 1
        case .quota: counters.acksRefusedQuota += 1
        case .key: counters.acksRefusedKey += 1
        case .selfVerify: counters.acksRefusedSelfVerify += 1
        case .storage: counters.storageFailures += 1
        }
        countersLock.unlock()
    }

    private enum WritableKeyPath {
        case hintHit, hintMiss, unsealed, verification, policy
        case newAdmit, duplicateAdmit, issued, quota, key, selfVerify, storage
    }

    // ------------------------------------------------------------------ the entry

    /// The whole inbound-recipient transaction of section 14 for one already
    /// decoded frame off the authenticated link. receivedFrom is the
    /// immediate-hop token (the trusted peer's 16-byte node id): it is filed
    /// as receipt metadata and NEVER consulted for the end-to-end sender
    /// identity. fault is the court-only fail-point seam, strings "signing"
    /// and "frame_insert", mirroring the T83 discipline; production passes
    /// nil. A crash thrown at an armed seam propagates observably -- the
    /// caller (the node's collector) wraps the call and the durable truth of
    /// the already-returned commit stands.
    func acceptVerifiedAndRequireAck(
        _ frame: FrameV2,
        receivedFrom: Data,
        fault: ((String) throws -> Void)? = nil
    ) throws -> InboxCommitResult {
        // -- gate 0: widths and the envelope, fail-closed before any work ----
        guard ourNodeId.count == ackRecipLen, receivedFrom.count == ackRecipLen,
              frame.msgId.count == ackMsgLen, frame.routingTag.count == 4,
              !frame.payload.isEmpty, frame.payload.count <= FrameV2.maxPayload
        else { return .rejected(reason: .widths, detail: nil) }
        guard frame.type == .message else { return .rejected(reason: .envelope, detail: nil) }
        guard (frame.flags & FrameV2.Flags.sealed) != 0 else { return .rejected(reason: .envelope, detail: nil) }
        guard (frame.flags & FrameV2.Flags.has_pow) == 0 else {
            // the frozen DIRECT profile carries no stamp (the core binds this too)
            return .rejected(reason: .envelope, detail: nil)
        }
        guard Priority.fromFlagsStrict(frame.flags) == .direct else {
            // only a directed message has the one recipient who could sign an ACK
            return .rejected(reason: .notDirect, detail: nil)
        }

        // -- gate 1: the rotating-tag census -- a hint, never a decision ------
        let today = epochDay()
        var hintHit = false
        for day in (today - hintWindowDays)...(today + hintWindowDays) {
            if SealedSender.routingTag(recipientNodeId: ourNodeId, epochDay: day) == frame.routingTag {
                hintHit = true
            }
        }
        bump(hintHit ? .hintHit : .hintMiss)
        // the tag NEVER gates: a miss is charged to the bounded decryption
        // budget (this very attempt) and the frame is still opened, because
        // "incorrect clocks must not be mistaken for authentication failure of
        // an identity".

        // -- gate 2: unseal under the local key through the frozen core -------
        guard let ourDh = localDhPrivate() else {
            return refuseKey("no local dh key material")
        }
        let opened: PolicyCheckedOpenedMessage
        switch router.openSealedMessage(frame, ourStaticDhPriv: ourDh) {
        case .accepted(let m):
            opened = m
            bump(.unsealed)
        case .notForUs: return .rejected(reason: .notForUs, detail: nil)
        case .malformed: return .rejected(reason: .malformed, detail: nil)
        case .wrongFrameType: return .rejected(reason: .envelope, detail: nil)
        case .missingSealedFlag: return .rejected(reason: .envelope, detail: nil)
        case .policyMismatch: return .rejected(reason: .policyMismatch, detail: nil)
        case .messageIdMismatch: return .rejected(reason: .messageIdMismatch, detail: nil)
        case .invalidProofOfWork: return .rejected(reason: .proofUnbound, detail: nil)
        }

        // -- gate 3: verify the signed author/recipient/msgID before admission -
        let sv = SignedMessageV1.verify(
            signedPlaintext: opened.plaintext,
            senderNodeId: opened.senderNodeId,
            recipientLocalNodeId: ourNodeId,
            messageNonce: opened.messageNonce,
            createdAtEpochSeconds: opened.createdAtEpochSeconds,
            priorityCode: opened.priority.rawValue
        )
        let vm: VerifiedApplicationMessage
        switch sv {
        case .verified(let message):
            vm = message
        case .invalid(reason: let reason):
            bump(.verification)
            return .rejected(reason: .verificationFailed, detail: reason)
        }
        // defense in depth: the frozen derivation must agree with the envelope
        if vm.msgId != frame.msgId {
            bump(.verification)
            return .rejected(reason: .messageIdMismatch, detail: "derived vs framed")
        }
        if vm.recipientNodeId != ourNodeId {
            // the verifier already bound this; a divergence here is unsound input
            bump(.verification)
            return .rejected(reason: .verificationFailed, detail: "recipient binding")
        }

        // -- gate 4: sender admission policy, beside (never instead of) proof --
        if !trustPolicy.admits(senderNodeId: vm.senderNodeId) {
            bump(.policy)
            return .rejected(reason: .senderRevoked, detail: nil)
        }

        // -- gate 5: the durable inbox transaction: unique + dedup + retention --
        let outcome = try commitInbound(
            frame, receivedFrom, ourNodeId, identityGeneration(),
            ackRetentionMs, clockSeconds(), fault
        )
        let heldNew: Bool
        let obligationStored: Bool
        switch outcome {
        case .committed(heldNew: let newHeld, obligationStored: let stored, duplicate: _):
            heldNew = newHeld
            obligationStored = stored
        case .rejectedCapacity:
            return .rejected(reason: .capacity, detail: nil)
        case .storageFailure:
            return refuseStorage("inbox commit")
        case .invalidArgument:
            return .rejected(reason: .widths, detail: "commit args")
        }

        // -- step 6: AFTER the commit, the canonical recipient ACK, once ------
        return try issueOrRestoreAck(frame, receivedFrom: receivedFrom,
                                     heldNew: heldNew, obligationStored: obligationStored,
                                     fault: fault)
    }

    // ------------------------------------------------------------------ internals

    /// Read the stored row for this (msg, us) pair; else sign, verify, file.
    private func issueOrRestoreAck(
        _ frame: FrameV2,
        receivedFrom: Data,
        heldNew: Bool,
        obligationStored: Bool,
        fault: ((String) throws -> Void)?
    ) throws -> InboxCommitResult {
        // (a) the stored verified row answers a duplicate with the VERY bytes
        //     first filed -- regenerating by re-signing is forbidden: this
        //     host's Ed25519 layer signs randomized, the durable row is the truth.
        switch try pairedStore.candidatesForPair(frame.msgId, recipientNodeId: ourNodeId,
                                                 bound: Int32(pairCensusBound)) {
        case .records(let rows):
            for rec in rows {
                if rec.recipientNodeId != ourNodeId { continue }
                if rec.verificationClass != .verifiedRecipiant { continue }
                guard let stored = FrameV2.decode(rec.encodedFrame) else {
                    return refuseCorrupt("stored ack row does not decode")
                }
                if obligationStored {
                    // The sealed T83 commit inserts its obligation beside EVERY
                    // inbox entry, duplicates included; this accept answered from
                    // the already-filed row and skipped the pair step, so the
                    // fresh PENDING row is a resurrection of a settled pair.
                    // Retire it here -- the census stays honest and the bounded
                    // worker is never re-armed for an answered pair.
                    switch pairedStore.retireObligation(frame.msgId, recipientNodeId: ourNodeId) {
                    case .storageFailure: bump(.storage)
                    default: ()
                    }
                }
                return admitArm(heldNew, stored)
            }
        case .corrupt(let reason): return refuseCorrupt(reason)
        case .storageFailure: return refuseStorage("pair census")
        }
        // (b) no filed row yet: the obligation stands (or an external wipe
        //     removed the pair's frames and this is the reissuance under the
        //     frozen formula). Sign now -- this is still AFTER the durable
        //     commit, which returned above.
        if let f = fault { try f("signing") }
        guard let theirNode = signer.nodeId, theirNode == ourNodeId else {
            return refuseKey("signer does not name the obligated recipient")
        }
        guard let seed = try signer.signingSeed(msgId: frame.msgId, recipientNodeId: ourNodeId) else {
            return refuseKey("signing seed unavailable")
        }
        switch pairedStore.lookupObligation(frame.msgId, recipientNodeId: ourNodeId) {
        case .found(let ob):
            if signer.generation() < ob.identityGeneration {
                // the key stands behind the obligation's pinned generation
                return refuseKey("signer generation behind obligation pin")
            }
        case .absent:
            () // reissuance; the pair step tolerates an absent obligation
        case .corrupt(let reason):
            return refuseCorrupt("obligation row: " + reason)
        case .storageFailure:
            return refuseStorage("obligation lookup")
        }
        let built = try AckFrame.build(
            msgId: frame.msgId,
            recipientSigningPrivKey: seed,
            recipientNodeId: ourNodeId,
            routingTag: Data(ourNodeId.prefix(4)),
            ttl: ackInitialTtl
        )
        // verification-first, even for our own freshly built answer: an ACK that
        // fails its own pinned-key check is never filed and never handed out --
        // the obligation stays pending for the bounded worker.
        guard let ourPublic = resolver.publicSigningKey(forNodeId: ourNodeId), ourPublic.count == 32 else {
            return refuseKey("own signing key not resolvable")
        }
        guard authenticator.verify(originalMsgId: frame.msgId, expectedRecipientNodeId: ourNodeId,
                                   ackFrame: built) else {
            bump(.selfVerify)
            return .rejected(reason: .selfVerificationFailed, detail: nil)
        }
        guard built.payload.count == ackPayloadLen,
              Data(built.payload.dropFirst(ackSigLen)) == ourNodeId else {
            bump(.selfVerify)
            return .rejected(reason: .selfVerificationFailed, detail: "canonical shape")
        }
        let signature = Data(built.payload.prefix(ackSigLen))
        guard let ackKey = AckCacheKey.compute(msgId: frame.msgId, recipientNodeId: ourNodeId,
                                               signature: signature) else {
            return .rejected(reason: .cacheKeyUnsound, detail: nil)
        }
        guard let record = AckFrameRecord.of(
            ackKey: ackKey,
            msgId: frame.msgId,
            recipientNodeId: ourNodeId,
            signature: signature,
            encodedFrame: built.encode(),
            receivedFrom: Data(receivedFrom),
            remainingLifetimeMs: ackRetentionMs,
            verificationClass: .verifiedRecipiant
        ) else {
            return .rejected(reason: .cacheKeyUnsound, detail: "record")
        }
        if let f = fault { try f("frame_insert") }
        switch pairedStore.commitFrameAndRetireObligation(record, msgId: frame.msgId,
                                                         recipientNodeId: ourNodeId) {
        case .committed, .idempotent:
            bump(.issued)
            return admitArm(heldNew, built)
        case .refusedQuotaPair, .refusedQuotaGlobal:
            bump(.quota)
            // saturation posture: nothing is claimed; the obligation stays
            // pending for the bounded T83 worker to retire later
            return .rejected(reason: .admissionQuota, detail: nil)
        case .storageFailure:
            return refuseStorage("pair commit")
        }
    }

    private func admitArm(_ heldNew: Bool, _ ack: FrameV2) -> InboxCommitResult {
        if heldNew {
            bump(.newAdmit)
            return .new(ack: ack)
        }
        bump(.duplicateAdmit)
        return .duplicate(ack: ack)
    }

    private func refuseKey(_ detail: String) -> InboxCommitResult {
        bump(.key)
        return .rejected(reason: .keyUnavailable, detail: detail)
    }

    private func refuseStorage(_ site: String) -> InboxCommitResult {
        bump(.storage)
        return .rejected(reason: .storageFailure, detail: site)
    }

    private func refuseCorrupt(_ detail: String) -> InboxCommitResult {
        return .rejected(reason: .storedFrameCorrupt, detail: detail)
    }
}
