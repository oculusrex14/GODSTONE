import Foundation

// Stage 4C.1 / C6.1 -- durable, recipient-authenticated delivery state machine
// (ADR-005; A-03). The lifecycle from ADR-005:
//
//   UNAVAILABLE | QUEUED_DURABLY -> HANDED_TO_RELAY -> ACKNOWLEDGED_BY_RECIPIENT
//                                       \-> EXPIRED | CANCELLED_LOCALLY
//
// A successful GATT write is only HANDED_TO_RELAY. ACKNOWLEDGED_BY_RECIPIENT is
// forbidden unless an AUTHENTICATED intended recipient ACKs the EXACT message id
// (see AckAuthenticator), AND the message was enqueued with AckMode
// SINGLE_RECIPIENT -- a broadcast (AckMode.none) can NEVER be acknowledged via
// this path (no recipient is bound, so no recipient identity may become trusted
// merely because an ACK packet names it). Cancellation cannot recall already
// relayed copies and the state says so. The machine is pure (no Keychain / no
// disk) with the repository + authenticator injected, so it is host-testable
// without a device or radio. The radio/link layer remains disabled (M2-link), so
// this is repo-owned evidence for the state machine + authenticated-ACK
// verification, not an on-device delivery proof. The Swift twin of
// android/.../mesh/delivery/DeliveryTracker.kt -- same states, same ack modes,
// same truth-table, same idempotent terminal semantics, so the two platforms
// enforce the same delivery contract.

/// Delivery lifecycle (ADR-005). Terminal states are acknowledged, expired,
/// cancelled.
///
/// `code` / `fromCode` are the cross-platform persistence contract (NOT the
/// Swift enum's raw value / position), so Android and iOS agree even if their
/// enum orders ever diverge. `fromCode` returns nil for an unknown code -- an
/// unknown persisted state fails closed (C6.5) rather than silently mapping to
/// unavailable.
public enum DeliveryState: String, Sendable, Equatable {
    case unavailable
    case queuedDurably
    case handedToRelay
    case acknowledgedByRecipient
    case expired
    case cancelledLocally

    public var isTerminal: Bool {
        self == .acknowledgedByRecipient || self == .expired || self == .cancelledLocally
    }

    /// Stable int persistence code (cross-platform contract, mirrors Android).
    public var code: Int32 {
        switch self {
        case .unavailable: return 0
        case .queuedDurably: return 1
        case .handedToRelay: return 2
        case .acknowledgedByRecipient: return 3
        case .expired: return 4
        case .cancelledLocally: return 5
        }
    }

    /// Decode a persisted code, or nil if the code is unknown (fail closed).
    public static func fromCode(_ c: Int32) -> DeliveryState? {
        switch c {
        case 0: return .unavailable
        case 1: return .queuedDurably
        case 2: return .handedToRelay
        case 3: return .acknowledgedByRecipient
        case 4: return .expired
        case 5: return .cancelledLocally
        default: return nil
        }
    }
}

/// Whether a tracked message is eligible for an authenticated recipient ACK.
///
///  * none -- a broadcast / group / SOS frame. No single intended recipient is
///    bound, so no ACK can ever advance it to acknowledgedByRecipient. An inbound
///    ACK for a none-mode message yields `AckResult.notAckEligible` and the
///    authenticator is NOT invoked (a recipient identity may NEVER become trusted
///    merely because the ACK packet names it -- C6.1).
///  * singleRecipient -- a DIRECT message addressed to exactly one node id
///    (16 bytes), bound durably at enqueue time. An ACK advances the state only
///    if it is from THAT recipient (see `AckAuthenticator`).
///
/// Do NOT invent a multi-recipient ACK policy here (C6.1). The int code is the
/// cross-platform persistence contract (mirrors Android AckMode).
public enum AckMode: Int32, Sendable, Equatable {
    case none = 0
    case singleRecipient = 1

    /// Decode a persisted code, or nil if unknown (fail closed).
    ///
    /// Note: `case 0` MUST spell `AckMode.none` explicitly. The return type is
    /// `AckMode?`, so a bare `return .none` would resolve to `Optional.none`
    /// (nil) -- not `AckMode.none` -- silently mapping every legitimate NONE-mode
    /// row to corrupt. The qualified form is promoted to `.some(AckMode.none)`.
    public static func fromCode(_ c: Int32) -> AckMode? {
        switch c {
        case 0: return AckMode.none
        case 1: return .singleRecipient
        default: return nil
        }
    }
}

/// One durable delivery record: the lifecycle state, the ACK mode, and (for
/// singleRecipient) the intended recipient node id bound at enqueue time. The
/// expected recipient is IMMUTABLE post-creation (it records historical send
/// intent); re-enqueuing with a different binding is an
/// `EnqueueResult.conflictRecipient`, not a mutation. For AckMode.none,
/// `expectedRecipientNodeId` is nil.
public struct DeliveryRecord: Sendable, Equatable {
    public let msgId: Data
    public let state: DeliveryState
    public let ackMode: AckMode
    public let expectedRecipientNodeId: Data?

    public init(msgId: Data, state: DeliveryState, ackMode: AckMode,
                expectedRecipientNodeId: Data?) {
        self.msgId = msgId
        self.state = state
        self.ackMode = ackMode
        self.expectedRecipientNodeId = expectedRecipientNodeId
    }
}

/// Result of reading a delivery record by msg_id. Sealed so the caller MUST
/// handle every outcome -- a corrupt or unknown row can never be silently
/// treated as a valid unavailable state (C6.5).
public enum DeliveryLookup: Sendable, Equatable {
    /// A row was found and decoded into a consistent record.
    case found(DeliveryRecord)
    /// No row exists for the msg_id (never tracked, or forgotten).
    case notFound
    /// A row exists but its state / ack_mode / recipient binding is unknown or
    /// inconsistent (fails the schema CHECK or the code tables). Fail closed.
    case corrupt
    /// The underlying store failed to read (IO / SQL error).
    case storageFailure
}

/// Outcome of `DeliveryTracker.enqueue`. Sealed (C6.2): a delivery-security
/// outcome is never a Bool the caller can misread as "ok".
public enum EnqueueResult: Sendable, Equatable {
    /// A new delivery record was durably created in queuedDurably.
    case created
    /// A non-terminal record with the SAME binding already exists -- idempotent
    /// re-enqueue of the same logical message (retry). No new row, no mutation.
    case alreadyQueuedSameBinding
    /// A record exists with a DIFFERENT binding (different ack mode or intended
    /// recipient). Fail closed -- the historical send intent is not overwritten.
    case conflictRecipient
    /// The record is already in a terminal state (acked / expired / cancelled).
    case rejectedTerminalState
    /// The underlying store failed to write.
    case storageFailure
    /// The store returned a corrupt / inconsistent record.
    case corrupt
}

/// Outcome of `DeliveryTracker.acknowledge`. Sealed (C6.2): the caller must
/// branch on the outcome and can NEVER translate `alreadyAcknowledged` or
/// `duplicateAuthenticatedAck` into "this ACK was newly verified" -- they mean
/// the message was already in a terminal acknowledged state, NOT that this
/// packet authenticated (option B: a terminal record short-circuits BEFORE the
/// authenticator is invoked, bounding CPU under a flood of replayed ACKs).
public enum AckResult: Sendable, Equatable {
    /// The ACK authenticated for the bound recipient and the state advanced to
    /// acknowledgedByRecipient. This is the ONLY outcome that means "verified".
    case applied
    /// The ACK authenticated, but the message was already acknowledged by a prior
    /// authenticated ACK. Not a new verification.
    case duplicateAuthenticatedAck
    /// The record is already acknowledged; this ACK was NOT authenticated
    /// (short-circuit, option B). Not "verified".
    case alreadyAcknowledged
    /// The message is AckMode.none -- broadcasts are not ACK-eligible. The
    /// authenticator was NOT invoked; the state is unchanged. (C6.1 invariant.)
    case notAckEligible
    /// No delivery record exists for the msg_id.
    case unknownMessage
    /// The ACK was reached but failed authentication (wrong recipient / wrong msg
    /// id / tampered / unsigned / unresolved key). State unchanged.
    case rejectedAuthentication
    /// The record is in a non-ackable state (expired / cancelled). State unchanged.
    case rejectedState
    /// The underlying store failed to write.
    case storageFailure
    /// The store returned a corrupt / inconsistent record.
    case corrupt
}

/// Outcome of a non-ACK lifecycle transition (`markHandedToRelay` / `expire` /
/// `cancel`). Sealed (C6.2): like `AckResult`, a delivery-security outcome is
/// never a Bool the caller can misread as "ok". The caller MUST branch and can
/// NEVER translate `alreadyInTarget` into "this transition just happened" -- it
/// means the record was already in the target state (idempotent re-issue, e.g. a
/// crash-then-resume that re-marks handed), NOT a fresh transition. Only
/// `applied` means the state advanced on this call.
public enum TransitionResult: Sendable, Equatable {
    /// The state advanced to the target on this call (fresh transition persisted).
    case applied
    /// The record was already in the target state -- idempotent, NO mutation. Not
    /// a fresh transition.
    case alreadyInTarget
    /// A record exists but its current state disallows this transition (e.g.
    /// marking handed an acknowledged / expired / cancelled record). No mutation.
    case rejectedState
    /// No durable record exists for the msg_id (never tracked, or it vanished
    /// mid-call via a raced expire / cancel / forget).
    case unknownMessage
    /// The store returned a corrupt / inconsistent record. Fail closed.
    case corrupt
    /// The underlying store failed to read / write.
    case storageFailure
}

/// Atomic durable delivery aggregate per message id (C6.3). Folds the C6.1
/// `DeliveryJournal` plus the enqueue / transition / retire classification that
/// lived in `DeliveryTracker` into ONE repository whose every mutation is a
/// single atomic SQL statement over the SAME `delivery_state` row keyed by
/// msg_id. The state, ack mode and expected recipient live in that one row; the
/// expected recipient is IMMUTABLE post-creation (C6.1/C6.3) -- no method here
/// updates it, so a re-enqueue with a different binding is
/// `EnqueueResult.conflictRecipient`, not a mutation.
///
/// The repository is the single place that maps a durable row to the typed
/// delivery outcomes (`DeliveryLookup` / `EnqueueResult` / `TransitionResult` /
/// `AckResult`) -- the truth-tables C6.1/C6.2 established now live here, not in
/// the tracker, so the tracker is a thin policy layer over `get` / `enqueue` /
/// `compareAndSet` / `acknowledgeAndRetire` / `clear`. Each mutation is one
/// atomic SQL statement (see StoreSchema): `enqueue` creates the row (INSERT ...
/// ON CONFLICT DO NOTHING -- a conflict is classified by re-reading),
/// `compareAndSet` / `acknowledgeAndRetire` advance only the state column
/// (preserving ack_mode + expected_recipient), `clear` drops the row. No
/// read-modify-write seam, so a crash between operations leaves the LAST
/// persisted state on disk -- the crash-safe semantics ADR-005 requires.
/// (CAS-hardened WHERE-clause transitions arrive in C6.4; this commit
/// establishes the single typed aggregate and the fail-closed semantics.)
///
/// Implementations must persist across a reboot/jetsam so a fresh
/// `DeliveryTracker` over the same repository recovers the record (reboot
/// recovery, ADR-005 exit criteria).
public protocol DeliveryRepository: AnyObject {
    /// Read the delivery record for `msgId`, or `.notFound`.
    func get(_ msgId: Data) -> DeliveryLookup

    /// Atomically create / classify a delivery record for `msgId` with `ackMode`
    /// and `expectedRecipient` (nil for AckMode.none, 16 bytes for
    /// singleRecipient). A NEW row in queuedDurably -> `.created`; a non-terminal
    /// row with the SAME binding -> `.alreadyQueuedSameBinding` (idempotent, no
    /// mutation); a row with a DIFFERENT binding -> `.conflictRecipient` (the
    /// historical send intent is NEVER overwritten); a terminal row ->
    /// `.rejectedTerminalState`. The expected recipient is NEVER updated on an
    /// existing row. A binding that violates the C6.1 invariant -> `.corrupt`.
    func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult

    /// Compare-and-set the state column: advance to `target` only if the current
    /// state is one of `validFroms`; a record already in `target` is
    /// `.alreadyInTarget` (idempotent, NO mutation); any other existing state is
    /// `.rejectedState`; a missing / corrupt / failed read is `.unknownMessage` /
    /// `.corrupt` / `.storageFailure`. If the row vanishes between the read and
    /// the state-only write (a raced expire / cancel / forget), the update touches
    /// 0 rows -> `.unknownMessage`. (The WHERE-clause state guard that makes this
    /// a true SQL CAS arrives in C6.4.)
    func compareAndSet(_ msgId: Data, validFroms: Set<DeliveryState>, target: DeliveryState) -> TransitionResult

    /// Atomic authenticated ACK retirement (C6.3). Re-reads the row for `msgId`
    /// and advances it to acknowledgedByRecipient ONLY if the durable binding
    /// matches (`ackMode` + `expectedRecipient` equal the row's bound values) --
    /// the recipient identity comes from durable outbound state, INDEPENDENT of
    /// the ACK frame (ADR-005). A binding mismatch (the row is not the message
    /// the tracker verified) -> `.unknownMessage`; a vanished row ->
    /// `.unknownMessage`; a corrupt / failed read -> `.corrupt` / `.storageFailure`.
    /// The tracker invokes this ONLY after `AckAuthenticator.verify` has
    /// authenticated the ACK against the same expected recipient; this method
    /// persists the retirement atomically. (Only `.applied` means "verified and
    /// advanced".)
    func acknowledgeAndRetire(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> AckResult

    /// Drop the delivery row for `msgId`.
    func clear(_ msgId: Data)
}

/// Verifies that an inbound ACK frame is an authentic acknowledgment of
/// `originalMsgId` by the intended recipient `expectedRecipientNodeId`. The
/// expected recipient is NON-optional: it always comes from durable outbound
/// state (the delivery record bound at enqueue), INDEPENDENT of the ACK frame. A
/// return of false means the ACK is rejected and the delivery state MUST NOT
/// advance -- no UI phrase stronger than the cryptographic evidence is permitted
/// (ADR-005).
///
/// C6.1: the nullable / unbound verify path is removed. A recipient identity may
/// NEVER become trusted merely because the ACK packet names it; the
/// authenticator is only ever invoked for an AckMode.singleRecipient record,
/// with the expected recipient read from durable state.
public protocol AckAuthenticator: AnyObject {
    func verify(originalMsgId: Data, expectedRecipientNodeId: Data, ackFrame: FrameV2) -> Bool
}

/// Durable delivery state machine -- a thin policy layer over a
/// `DeliveryRepository` (C6.3) plus an `AckAuthenticator`. Every successful
/// transition is persisted by the repository AFTER it is applied, so a
/// crash-then-resume re-reads the last persisted state. Transitions that are
/// illegal for the current state (or an ACK that fails authentication) do not
/// mutate state -- the truth-table is enforced, not advisory. The repository
/// owns the typed durable-row mapping (get / enqueue / compareAndSet /
/// acknowledgeAndRetire / clear); the tracker owns the ACK policy: the terminal
/// short-circuit (option B), the AckMode.none gate, and the authenticator call.
public final class DeliveryTracker {
    private let repo: DeliveryRepository
    private let authenticator: AckAuthenticator

    public init(repo: DeliveryRepository, authenticator: AckAuthenticator) {
        self.repo = repo
        self.authenticator = authenticator
    }

    /// Current persisted state for `msgId` (unavailable if never tracked / corrupt).
    public func state(_ msgId: Data) -> DeliveryState {
        switch repo.get(msgId) {
        case .found(let rec): return rec.state
        case .notFound, .corrupt, .storageFailure: return .unavailable
        }
    }

    /// Begin tracking a message: unavailable -> queuedDurably with `ackMode` and
    /// (for singleRecipient) the durably-bound intended recipient. The binding
    /// (ack mode + recipient) is IMMUTABLE post-creation: a re-enqueue of the
    /// SAME logical message is idempotent (`.alreadyQueuedSameBinding`); a
    /// re-enqueue with a DIFFERENT binding fails closed (`.conflictRecipient`);
    /// a terminal record rejects re-enqueue (`.rejectedTerminalState`). Delegates
    /// to `DeliveryRepository.enqueue`, which validates the C6.1 binding invariant
    /// (none -> nil; singleRecipient -> 16-byte recipient) before touching the
    /// store.
    @discardableResult
    public func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data? = nil) -> EnqueueResult {
        repo.enqueue(msgId, ackMode: ackMode, expectedRecipient: expectedRecipient)
    }

    /// Record that the frame was handed to a relay (a successful GATT write).
    /// queuedDurably -> handedToRelay. Idempotent from handedToRelay
    /// (`.alreadyInTarget` -- NOT a fresh hand-off). Returns `.rejectedState` from
    /// any other state (this is NOT "sent" -- only `acknowledge` can reach
    /// acknowledgedByRecipient).
    @discardableResult
    public func markHandedToRelay(_ msgId: Data) -> TransitionResult {
        repo.compareAndSet(msgId, validFroms: [.queuedDurably], target: .handedToRelay)
    }

    /// Apply an authenticated recipient ACK (C6.1). The outcome is typed
    /// (`AckResult`); only `.applied` means "this ACK verified and the state
    /// advanced". A none-mode message is `.notAckEligible` and the authenticator
    /// is NOT invoked. A terminal acknowledged record short-circuits to
    /// `.alreadyAcknowledged` WITHOUT authenticating (option B: bound CPU under
    /// replayed ACK floods; NOT a verification). expired / cancelled records are
    /// `.rejectedState`. A singleRecipient record authenticates the ACK against
    /// the durable expected recipient; failure is `.rejectedAuthentication` and
    /// the state is unchanged. On a verified ACK the retirement is persisted
    /// atomically by `DeliveryRepository.acknowledgeAndRetire`, which re-reads
    /// the row and requires the durable binding to still match.
    @discardableResult
    public func acknowledge(_ msgId: Data, _ ackFrame: FrameV2) -> AckResult {
        switch repo.get(msgId) {
        case .notFound:
            return .unknownMessage
        case .corrupt:
            return .corrupt
        case .storageFailure:
            return .storageFailure
        case .found(let rec):
            if rec.state == .acknowledgedByRecipient {
                return .alreadyAcknowledged // option B: short-circuit, no auth
            }
            if rec.state.isTerminal { return .rejectedState } // expired / cancelled
            if rec.state != .queuedDurably && rec.state != .handedToRelay {
                return .rejectedState // unavailable / anomalous non-terminal
            }
            if rec.ackMode == .none { return .notAckEligible } // authenticator NOT invoked
            // singleRecipient: expected recipient is non-nil by the schema CHECK.
            guard let expected = rec.expectedRecipientNodeId else {
                return .corrupt // invariant violation (CHECK should prevent)
            }
            if !authenticator.verify(originalMsgId: msgId, expectedRecipientNodeId: expected, ackFrame: ackFrame) {
                return .rejectedAuthentication
            }
            // Atomic retirement: re-reads the row and requires the durable binding
            // (ack mode + expected recipient) to still match before advancing.
            return repo.acknowledgeAndRetire(msgId, ackMode: rec.ackMode, expectedRecipient: expected)
        }
    }

    /// TTL expiry: queuedDurably or handedToRelay -> expired. Idempotent from
    /// expired (`.alreadyInTarget`); `.rejectedState` from a terminal non-target
    /// state (acknowledged / cancelled).
    @discardableResult
    public func expire(_ msgId: Data) -> TransitionResult {
        repo.compareAndSet(msgId, validFroms: [.queuedDurably, .handedToRelay], target: .expired)
    }

    /// Local cancellation: queuedDurably or handedToRelay -> cancelledLocally.
    /// Idempotent from cancelledLocally (`.alreadyInTarget`); `.rejectedState`
    /// from a terminal non-target state (acknowledged / expired). Cancellation
    /// cannot recall already relayed copies -- the caller gives the truthful UI;
    /// the state machine records the intent.
    @discardableResult
    public func cancel(_ msgId: Data) -> TransitionResult {
        repo.compareAndSet(msgId, validFroms: [.queuedDurably, .handedToRelay], target: .cancelledLocally)
    }

    /// Drop tracking for `msgId` (e.g. after it ages out of the store).
    public func forget(_ msgId: Data) { repo.clear(msgId) }
}