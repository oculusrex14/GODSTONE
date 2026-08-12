import Foundation

// Stage 4C.1 / C6.1 -- durable, recipient-authenticated delivery state machine
// (ADR-005; A-03). The lifecycle from ADR-005:
//
//   QUEUED_DURABLY -> HANDED_TO_RELAY -> ACKNOWLEDGED_BY_RECIPIENT
//                       \-> EXPIRED | CANCELLED_LOCALLY
//
// (UNAVAILABLE is an in-memory / lifecycle concept ONLY -- it is NOT a legal
// durable row; C6.4-C. A row = tracked; no row = untracked.) A successful GATT
// write is only HANDED_TO_RELAY. ACKNOWLEDGED_BY_RECIPIENT is forbidden unless an
// AUTHENTICATED intended recipient ACKs the EXACT message id (see
// AckAuthenticator), AND the message was enqueued with AckMode SINGLE_RECIPIENT
// -- a broadcast (AckMode.none) can NEVER be acknowledged via this path (no
// recipient is bound, so no recipient identity may become trusted merely
// because an ACK packet names it). Cancellation cannot recall already relayed
// copies and the state says so. The machine is pure (no Keychain / no disk) with
// the repository + authenticator injected, so it is host-testable without a
// device or radio. The radio/link layer remains disabled (M2-link), so this is
// repo-owned evidence for the state machine + authenticated-ACK verification,
// not an on-device delivery proof.
//
// C6.4 hardens the durable contract the tracker rests on (mirrors the Android
// `DeliveryTracker.kt`):
//  * StorageFailure is REAL (C6.4-A): the repository maps SQL exceptions /
//    prepare/step failures / a missing handle to typed `.storageFailure`,
//    distinct from absence / conflict / no-match (never the same sentinel).
//  * No corrupt/storage -> unavailable collapse (C6.4-B): the tracker exposes
//    `lookup` (the raw DeliveryLookup); a corrupt or failed read is NOT silently
//    reported as `.unavailable`. The lossy `state` seam was removed.
//  * No durable state=UNAVAILABLE (C6.4-C): a persisted state code 0 is corrupt,
//    rejected by the schema CHECK(state IN (1..5)) and the decode guard.
//  * 16-byte msg_id at the boundary (C6.4-D): every repository method rejects a
//    non-16-byte msg_id with `.invalidArgument` BEFORE any SQL.
//  * Real SQL CAS (C6.4-F): transitions are guarded `UPDATE ... WHERE msg_id AND
//    state IN (...)`; the write is decided by the affected row count, not a
//    stale pre-read.
//  * The repository owns the lifecycle truth-table (C6.4-G): the public API is
//    `transition(msgId, DeliveryTransition)`, not an arbitrary
//    `compareAndSet(validFroms, target)` a caller could misuse.
//  * ACK CAS binds STATE + MODE + RECIPIENT in one WHERE (C6.4-H): a guarded
//    `UPDATE ... SET acknowledged WHERE msg_id AND state IN (queued,handed) AND
//    ack_mode = SINGLE_RECIPIENT AND expected_recipient = ?` -- the authenticated
//    ACK's binding is part of the CAS predicate, not a separate re-read.

/// Delivery lifecycle (ADR-005). Terminal states are acknowledged, expired,
/// cancelled.
///
/// `code` / `fromCode` are the cross-platform persistence contract (NOT the
/// Swift enum's raw value / position), so Android and iOS agree even if their
/// enum orders ever diverge. `fromCode` returns nil for an unknown code -- an
/// unknown persisted state fails closed (C6.5) rather than silently mapping to
/// unavailable.
///
/// C6.4-C: UNAVAILABLE (code 0) is an in-memory / lifecycle concept ONLY -- it is
/// NOT a legal durable row. `fromPersistedCode` is the decoder used on the
/// durable read path: it rejects code 0 (and any unknown code) so a persisted
/// UNAVAILABLE fails closed to `DeliveryLookup.corrupt`. No normal creation path
/// writes code 0; the schema `CHECK (state IN (1,2,3,4,5))` rejects it at write
/// time, and `fromPersistedCode` rejects it at read time (defense in depth for a
/// legacy / bypassed-CHECK / corrupt-file row).
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
    /// Keeps `.unavailable` (code 0) for in-memory state round-trips.
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

    /// Decode a persisted durable-row state (C6.4-C). Rejects code 0
    /// (unavailable) -- unavailable is NOT a legal durable row, only an in-memory
    /// concept, so a persisted 0 fails closed to corrupt. Used on the durable
    /// read path (`DeliveryRepository.get`); `fromCode` is used for in-memory
    /// state round-trips.
    public static func fromPersistedCode(_ c: Int32) -> DeliveryState? {
        switch c {
        case 1: return .queuedDurably
        case 2: return .handedToRelay
        case 3: return .acknowledgedByRecipient
        case 4: return .expired
        case 5: return .cancelledLocally
        default: return nil // 0 (unavailable) and any unknown code -> fail closed
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
///
/// C6.4-K: Swift `Data` is a value type (copy-on-write), unlike Kotlin's
/// reference-mutable `ByteArray`. The record therefore does NOT need to
/// defensively copy its `Data` fields -- a caller that mutates the source `Data`
/// after handing it to a record / repository cannot mutate the durable binding
/// the record holds (a mutation on the caller's copy triggers COW, leaving the
/// record's copy intact). The Android twin copies via `copyOf()`; iOS relies on
/// `Data` value semantics. Both arrive at the same invariant: the record is the
/// immutable historical send intent, never aliased to caller-owned storage.
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
/// treated as a valid state (C6.5). C6.4-A: `.storageFailure` is a REAL,
/// distinguishable outcome (SQL / IO failure), never folded into `.notFound`.
/// C6.4-D: `.invalidArgument` is a non-16-byte msg_id rejected before any SQL --
/// NOT `.corrupt` (a caller precondition violation is distinct from a corrupt row).
public enum DeliveryLookup: Sendable, Equatable {
    /// A row was found and decoded into a consistent record.
    case found(DeliveryRecord)
    /// No row exists for the msg_id (never tracked, or forgotten).
    case notFound
    /// A row exists but its state / ack_mode / recipient binding is unknown or
    /// inconsistent (fails the schema CHECK or the code tables, including a
    /// persisted state code 0 / unavailable). Fail closed.
    case corrupt
    /// The underlying store failed to read (IO / SQL error / missing handle).
    case storageFailure
    /// The msg_id is not exactly 16 bytes -- rejected before any SQL (C6.4-D).
    case invalidArgument
}

/// Outcome of `DeliveryRepository.enqueue`. Sealed (C6.2): a delivery-security
/// outcome is never a Bool the caller can misread as "ok". C6.4-A/D add
/// `.storageFailure` (real SQL failure) and `.invalidArgument` (non-16-byte
/// msg_id).
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
    /// The underlying store failed to read / write (C6.4-A).
    case storageFailure
    /// The store returned a corrupt / inconsistent record.
    case corrupt
    /// The msg_id is not exactly 16 bytes -- rejected before any SQL (C6.4-D).
    case invalidArgument
}

/// Outcome of `DeliveryTracker.acknowledge`. Sealed (C6.2): the caller must
/// branch on the outcome and can NEVER translate `alreadyAcknowledged` or
/// `duplicateAuthenticatedAck` into "this ACK was newly verified" -- they mean
/// the message was already in a terminal acknowledged state, NOT that this
/// packet authenticated (option B: a terminal record short-circuits BEFORE the
/// authenticator is invoked, bounding CPU under a flood of replayed ACKs).
///
/// C6.4-H: `duplicateAuthenticatedAck` is now REACHABLE via the SQL CAS. When two
/// authenticated ACKs race -- both read HANDED, both authenticate, ACK #1's CAS
/// succeeds (`.applied`), ACK #2's guarded UPDATE matches 0 rows and re-reads
/// acknowledged with the SAME binding -- ACK #2 yields `.duplicateAuthenticatedAck`
/// (authenticated, but not a new verification). An authenticated ACK that loses
/// the CAS to a cancel / expire re-reads a terminal non-acknowledged state and
/// yields `.rejectedState`; one that loses to a recipient rebinding yields
/// `.unknownMessage` (an old ACK must never bind to a new row).
public enum AckResult: Sendable, Equatable {
    /// The ACK authenticated for the bound recipient and the state advanced to
    /// acknowledgedByRecipient. This is the ONLY outcome that means "verified".
    case applied
    /// The ACK authenticated, but the message was already acknowledged by a prior
    /// authenticated ACK that won the CAS race. Not a new verification. (C6.4-H.)
    case duplicateAuthenticatedAck
    /// The record is already acknowledged; this ACK was NOT authenticated
    /// (short-circuit, option B). Not "verified".
    case alreadyAcknowledged
    /// The message is AckMode.none -- broadcasts are not ACK-eligible. The
    /// authenticator was NOT invoked; the state is unchanged. (C6.1 invariant.)
    case notAckEligible
    /// No delivery record exists for the msg_id, OR the row vanished / was re-bound
    /// to a different recipient before the ACK's CAS could match.
    case unknownMessage
    /// The ACK was reached but failed authentication (wrong recipient / wrong msg
    /// id / tampered / unsigned / unresolved key). State unchanged.
    case rejectedAuthentication
    /// The record is in a non-ackable state (expired / cancelled) -- the ACK lost
    /// the CAS to a cancel / expire. State unchanged.
    case rejectedState
    /// The underlying store failed to read / write (C6.4-A).
    case storageFailure
    /// The store returned a corrupt / inconsistent record.
    case corrupt
    /// The msg_id is not exactly 16 bytes -- rejected before any SQL (C6.4-D).
    case invalidArgument
}

/// Outcome of a non-ACK lifecycle transition (`DeliveryTransition.markHanded` /
/// `.expire` / `.cancel`). Sealed (C6.2): like `AckResult`, a delivery-security
/// outcome is never a Bool the caller can misread as "ok". The caller MUST
/// branch and can NEVER translate `alreadyInTarget` into "this transition just
/// happened" -- it means the record was already in the target state (idempotent
/// re-issue, e.g. a crash-then-resume that re-marks handed), NOT a fresh
/// transition. Only `.applied` means the state advanced on this call.
///
/// C6.4-F: the transition is a guarded SQL CAS (`UPDATE ... WHERE msg_id AND
/// state IN (...)`); `.applied` is decided by an affected row count of 1, not a
/// stale pre-read. A 0-row CAS is re-read once and classified.
public enum TransitionResult: Sendable, Equatable {
    /// The state advanced to the target on this call (fresh CAS transition persisted).
    case applied
    /// The record was already in the target state -- idempotent, NO mutation. Not
    /// a fresh transition.
    case alreadyInTarget
    /// A record exists but its current state disallows this transition (e.g.
    /// marking handed an acknowledged / expired / cancelled record). No mutation.
    case rejectedState
    /// No durable record exists for the msg_id (never tracked, or it vanished
    /// mid-call via a raced clear).
    case unknownMessage
    /// The store returned a corrupt / inconsistent record. Fail closed.
    case corrupt
    /// The underlying store failed to read / write (C6.4-A).
    case storageFailure
    /// The msg_id is not exactly 16 bytes -- rejected before any SQL (C6.4-D).
    case invalidArgument
}

/// Outcome of `DeliveryRepository.clear` (C6.4-J). A destructive operation is
/// never `Void` -- a failed clear looks different from success and from "nothing
/// to delete", so expiry cleanup, panic-wipe coordination and crash recovery can
/// tell them apart.
public enum ClearResult: Sendable, Equatable {
    /// A row existed and was dropped.
    case cleared
    /// No row existed for the msg_id (already absent / never tracked).
    case alreadyAbsent
    /// The underlying store failed (C6.4-A).
    case storageFailure
    /// The msg_id is not exactly 16 bytes -- rejected before any SQL (C6.4-D).
    case invalidArgument
}

/// A legal non-ACK lifecycle transition the repository owns (C6.4-G). The
/// repository, not the caller, maps a transition to its fixed (valid-from-states,
/// target) pair, so a caller cannot ask for an illegal truth-table like
/// `acknowledged -> queued` or `cancelled -> handed` by passing the wrong
/// arguments. The fixed mapping:
///  * `.markHanded` -- queuedDurably -> handedToRelay.
///  * `.expire`    -- queuedDurably | handedToRelay -> expired.
///  * `.cancel`    -- queuedDurably | handedToRelay -> cancelledLocally.
public enum DeliveryTransition: Sendable, Equatable {
    case markHanded
    case expire
    case cancel
}

/// Atomic durable delivery aggregate per message id (C6.3; hardened C6.4). Folds
/// the C6.1 `DeliveryJournal` plus the enqueue / transition / retire
/// classification into ONE repository whose every mutation is a single atomic
/// guarded SQL statement over the SAME `delivery_state` row keyed by msg_id. The
/// state, ack mode and expected recipient live in that one row; the expected
/// recipient is IMMUTABLE post-creation (C6.1/C6.3) -- no method here updates it,
/// so a re-enqueue with a different binding is `EnqueueResult.conflictRecipient`,
/// not a mutation.
///
/// The repository is the single place that maps a durable row to the typed
/// delivery outcomes (`DeliveryLookup` / `EnqueueResult` / `TransitionResult` /
/// `AckResult` / `ClearResult`). C6.4 hardening (mirrors Android):
///  * Storage failure is REAL (C6.4-A): SQL exceptions / prepare-step failures /
///    a missing DB handle are caught and mapped to the typed `.storageFailure`
///    variant -- NEVER folded into `.notFound` / `false` / `0`. Absence /
///    conflict / no-match use their own sentinels.
///  * 16-byte msg_id (C6.4-D): every method rejects a non-16-byte msg_id with
///    `.invalidArgument` BEFORE any SQL.
///  * SQL CAS (C6.4-F): `transition` runs `UPDATE ... SET state WHERE msg_id AND
///    state IN (...)` and decides `.applied` by the affected row count; a 0-row
///    result is re-read ONCE and classified (`.alreadyInTarget` /
///    `.rejectedState` / `.unknownMessage` / `.corrupt` / `.storageFailure`).
///  * Lifecycle truth-table owned here (C6.4-G): `transition` takes a
///    `DeliveryTransition`, not an arbitrary (validFroms, target) pair.
///  * ACK CAS (C6.4-H): `acknowledgeBound` runs
///    `UPDATE ... SET acknowledged WHERE msg_id AND state IN (queued,handed) AND
///    ack_mode = SINGLE_RECIPIENT AND expected_recipient = ?` -- state + mode +
///    the exact durable recipient in ONE WHERE clause. A 0-row CAS is re-read
///    and classified (`.duplicateAuthenticatedAck` for same-binding acknowledged,
///    `.rejectedState` for expired/cancelled, `.unknownMessage` for a vanished /
///    re-bound row, `.storageFailure` for a same-binding queued/handed row that
///    the SQL should have matched).
///  * `acknowledgeBound` performs delivery-state retirement ONLY. It does NOT yet
///    delete the corresponding held frame -- that cross-table atomic transaction
///    is C7.4 (ADR-004 delete-on-authenticated-ACK is NOT closed by this method).
///    The name says `acknowledgeBound` (the durable binding CAS), not
///    `acknowledgeAndRetire`, so it does not imply the held-frame retirement is
///    implemented (C6.4-I).
///
/// Each mutation is one atomic SQL statement (see StoreSchema): `enqueue`
/// creates the row (INSERT ... ON CONFLICT DO NOTHING -- a conflict is classified
/// by re-reading), `transition` / `acknowledgeBound` advance the state column via
/// a guarded CAS UPDATE (preserving ack_mode + expected_recipient), `clear` drops
/// the row. No read-modify-write seam, so a crash between operations leaves the
/// LAST persisted state on disk -- the crash-safe semantics ADR-005 requires.
///
/// NOTE (C6.4-N): row-atomicity here is the `delivery_state` row only. It does NOT
/// yet make `persist held frame` + `enqueue delivery record` atomic -- that
/// cross-table outbound transaction is C6.6. A DIRECT send is transport-eligible
/// only after BOTH are committed (C6.6); until then the outbound path composes
/// them as separate operations.
///
/// Implementations must persist across a reboot/jetsam so a fresh
/// `DeliveryTracker` over the same repository recovers the record (reboot
/// recovery, ADR-005 exit criteria).
public protocol DeliveryRepository: AnyObject {
    /// Read the delivery record for `msgId`, or `.notFound`. C6.4-A/D: a storage
    /// failure is `.storageFailure`; a non-16-byte msg_id is `.invalidArgument`
    /// (before any SQL).
    func get(_ msgId: Data) -> DeliveryLookup

    /// Atomically create / classify a delivery record for `msgId` with `ackMode`
    /// and `expectedRecipient` (nil for AckMode.none, 16 bytes for
    /// singleRecipient). A NEW row in queuedDurably -> `.created`; a non-terminal
    /// row with the SAME binding -> `.alreadyQueuedSameBinding` (idempotent, no
    /// mutation); a row with a DIFFERENT binding -> `.conflictRecipient` (the
    /// historical send intent is NEVER overwritten); a terminal row ->
    /// `.rejectedTerminalState`. The expected recipient is NEVER updated on an
    /// existing row. A binding that violates the C6.1 invariant -> `.corrupt`.
    /// C6.4-A/D: a storage failure is `.storageFailure`; a non-16-byte msg_id is
    /// `.invalidArgument` (before any SQL).
    func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult

    /// Guarded SQL CAS lifecycle transition (C6.4-F/G). Runs
    /// `UPDATE delivery_state SET state = target WHERE msg_id = ? AND state IN
    /// (validFroms)`; `.applied` iff the affected row count is 1. A 0-row CAS is
    /// re-read ONCE and classified: row absent -> `.unknownMessage`; corrupt ->
    /// `.corrupt`; storage failure -> `.storageFailure`; state == target ->
    /// `.alreadyInTarget`; any other legal durable state -> `.rejectedState`; a
    /// same-validFrom state that the SQL should have matched (invariant violation
    /// under concurrency) -> `.storageFailure`. The (validFroms, target) pair is
    /// fixed by `transition` (C6.4-G), not supplied by the caller. C6.4-D: a
    /// non-16-byte msg_id is `.invalidArgument`.
    func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult

    /// Atomic authenticated ACK state commit (C6.4-H/I). Runs the guarded CAS
    /// `UPDATE delivery_state SET state = ACKNOWLEDGED WHERE msg_id = ? AND state
    /// IN (QUEUED, HANDED) AND ack_mode = SINGLE_RECIPIENT AND expected_recipient
    /// = ?` -- state + mode + the EXACT durable recipient in ONE WHERE clause.
    /// `.applied` iff the affected row count is 1 (this ACK won the CAS). A 0-row
    /// CAS is re-read ONCE and classified:
    ///  * row absent -> `.unknownMessage`;
    ///  * binding changed (ack_mode or recipient differ) -> `.unknownMessage`
    ///    (an old ACK must NEVER bind to a re-bound row);
    ///  * state == acknowledged with the SAME binding -> `.duplicateAuthenticatedAck`
    ///    (the tracker authenticated before losing the CAS -- a real race);
    ///  * state == expired / cancelled -> `.rejectedState`;
    ///  * same binding + queued/handed still present -> `.storageFailure`
    ///    (invariant violation -- the SQL should have matched);
    ///  * corrupt / storage failure -> `.corrupt` / `.storageFailure`.
    /// The tracker invokes this ONLY after `AckAuthenticator.verify` has
    /// authenticated the ACK against the same expected recipient. This method
    /// performs delivery-state retirement ONLY; held-frame retirement is C7.4
    /// (NOT yet implemented -- do not claim ADR-004 delete-on-ACK is closed).
    /// C6.4-D: a non-16-byte msg_id is `.invalidArgument`. C6.4.1-I: the binding
    /// is ALWAYS `AckMode.singleRecipient` with a non-nil 16-byte recipient (the
    /// tracker gates `none` / nil before this call), so `ackMode` + optionality are
    /// removed from the signature -- the SQL hard-codes `ack_mode = SINGLE_RECIPIENT`.
    func acknowledgeBound(_ msgId: Data, expectedRecipient: Data) -> AckResult

    /// Drop the delivery row for `msgId` (C6.4-J). Typed -- a failed destructive
    /// operation is never indistinguishable from success: `.cleared` (a row was
    /// dropped), `.alreadyAbsent` (no row), `.storageFailure` (C6.4-A),
    /// `.invalidArgument` (C6.4-D). C6.4.1-K: `.corrupt` is removed -- `clear` is a
    /// single DELETE; a corrupt read is impossible (no row is decoded).
    func clear(_ msgId: Data) -> ClearResult
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
/// `DeliveryRepository` (C6.3; hardened C6.4) plus an `AckAuthenticator`. Every
/// successful transition is persisted by the repository as a guarded SQL CAS, so
/// a crash-then-resume re-reads the last persisted state. Transitions that are
/// illegal for the current state (or an ACK that fails authentication) do not
/// mutate state -- the truth-table is enforced, not advisory. The repository
/// owns the typed durable-row mapping (get / enqueue / transition /
/// acknowledgeBound / clear); the tracker owns the ACK policy: the terminal
/// short-circuit (option B), the AckMode.none gate, and the authenticator call.
///
/// C6.4-B: the lossy `state(msgId)` seam is REMOVED -- it collapsed notFound /
/// corrupt / storageFailure all to `.unavailable`, hiding a corrupt or
/// inaccessible record behind "never tracked / eligible for fresh creation". Use
/// `lookup` for the raw typed outcome; a corrupt record fails closed, it is NOT
/// reported as `.unavailable`. (A lossy `displayState` convenience is intentionally
/// NOT provided for mutation / security decisions.)
public final class DeliveryTracker {
    private let repo: DeliveryRepository
    private let authenticator: AckAuthenticator

    public init(repo: DeliveryRepository, authenticator: AckAuthenticator) {
        self.repo = repo
        self.authenticator = authenticator
    }

    /// Typed lookup for `msgId` (C6.4-B). Replaces the lossy `state(msgId)` seam:
    /// the caller sees `.found` / `.notFound` / `.corrupt` / `.storageFailure` /
    /// `.invalidArgument` and MUST branch. A corrupt record is `.corrupt` -- NOT
    /// `.unavailable` -- and a caller MUST NOT treat it as "never tracked /
    /// eligible for fresh creation".
    public func lookup(_ msgId: Data) -> DeliveryLookup { repo.get(msgId) }

    /// Begin tracking a message: queuedDurably with `ackMode` and (for
    /// singleRecipient) the durably-bound intended recipient. The binding
    /// (ack mode + recipient) is IMMUTABLE post-creation: a re-enqueue of the
    /// SAME logical message is idempotent (`.alreadyQueuedSameBinding`); a
    /// re-enqueue with a DIFFERENT binding fails closed (`.conflictRecipient`);
    /// a terminal record rejects re-enqueue (`.rejectedTerminalState`). Delegates
    /// to `DeliveryRepository.enqueue`, which validates the C6.1 binding invariant
    /// (none -> nil; singleRecipient -> 16-byte recipient) before touching the
    /// store, and the C6.4-D 16-byte msg_id invariant before that.
    @discardableResult
    public func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data? = nil) -> EnqueueResult {
        repo.enqueue(msgId, ackMode: ackMode, expectedRecipient: expectedRecipient)
    }

    /// Record that the frame was handed to a relay (a successful GATT write).
    /// queuedDurably -> handedToRelay via a guarded SQL CAS (C6.4-F/G). Idempotent
    /// from handedToRelay (`.alreadyInTarget` -- NOT a fresh hand-off). Returns
    /// `.rejectedState` from any other state (this is NOT "sent" -- only
    /// `acknowledge` can reach acknowledgedByRecipient).
    @discardableResult
    public func markHandedToRelay(_ msgId: Data) -> TransitionResult {
        repo.transition(msgId, .markHanded)
    }

    /// Apply an authenticated recipient ACK (C6.1; C6.4-H). The outcome is typed
    /// (`AckResult`); only `.applied` means "this ACK verified and the state
    /// advanced". A none-mode message is `.notAckEligible` and the authenticator
    /// is NOT invoked. A terminal acknowledged record short-circuits to
    /// `.alreadyAcknowledged` WITHOUT authenticating (option B: bound CPU under
    /// replayed ACK floods; NOT a verification). expired / cancelled records are
    /// `.rejectedState`. A singleRecipient record authenticates the ACK against
    /// the durable expected recipient; failure is `.rejectedAuthentication` and
    /// the state is unchanged. On a verified ACK the state commit is persisted
    /// atomically by `DeliveryRepository.acknowledgeBound`, whose guarded CAS
    /// binds state + mode + the exact durable recipient in one WHERE clause -- so
    /// a verified ACK that loses the race to another verified ACK yields
    /// `.duplicateAuthenticatedAck`, to a cancel/expire yields `.rejectedState`,
    /// and to a recipient rebinding yields `.unknownMessage`.
    @discardableResult
    public func acknowledge(_ msgId: Data, _ ackFrame: FrameV2) -> AckResult {
        switch repo.get(msgId) {
        case .notFound:
            return .unknownMessage
        case .corrupt:
            return .corrupt
        case .storageFailure:
            return .storageFailure
        case .invalidArgument:
            return .invalidArgument
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
            // Atomic state commit: a guarded CAS binds state + mode + the exact
            // durable recipient in one WHERE clause. The tracker authenticated
            // before this call; a lost CAS is classified by the repository
            // (duplicateAuthenticatedAck / rejectedState / unknownMessage).
            return repo.acknowledgeBound(msgId, expectedRecipient: expected)
        }
    }

    /// TTL expiry: queuedDurably or handedToRelay -> expired via a guarded SQL CAS
    /// (C6.4-F/G). Idempotent from expired (`.alreadyInTarget`); `.rejectedState`
    /// from a terminal non-target state (acknowledged / cancelled).
    @discardableResult
    public func expire(_ msgId: Data) -> TransitionResult {
        repo.transition(msgId, .expire)
    }

    /// Local cancellation: queuedDurably or handedToRelay -> cancelledLocally via a
    /// guarded SQL CAS (C6.4-F/G). Idempotent from cancelledLocally
    /// (`.alreadyInTarget`); `.rejectedState` from a terminal non-target state
    /// (acknowledged / expired). Cancellation cannot recall already relayed
    /// copies -- the caller gives the truthful UI; the state machine records the
    /// intent.
    @discardableResult
    public func cancel(_ msgId: Data) -> TransitionResult {
        repo.transition(msgId, .cancel)
    }

    /// Drop tracking for `msgId` (e.g. after it ages out of the store). Typed
    /// (C6.4-J): a failed destructive operation is never indistinguishable from
    /// success.
    @discardableResult
    public func forget(_ msgId: Data) -> ClearResult { repo.clear(msgId) }
}