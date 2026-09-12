package io.godstone.mesh.delivery

import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2

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
// -- a broadcast (AckMode.NONE) can NEVER be acknowledged via this path (no
// recipient is bound, so no recipient identity may become trusted merely
// because an ACK packet names it). Cancellation cannot recall already relayed
// copies and the state says so. The machine is pure (no Context / no disk) with
// the repository + authenticator injected, so it is host-testable without a
// device or radio. The radio/link layer remains disabled (M2-link), so this is
// repo-owned evidence for the state machine + authenticated-ACK verification,
// not an on-device delivery proof.
//
// C6.4 hardens the durable contract the tracker rests on:
//  * StorageFailure is REAL (C6.4-A): the repository maps SQL exceptions /
//    prepare/step failures / a missing handle to typed StorageFailure, distinct
//    from absence / conflict / no-match (never the same sentinel).
//  * No corrupt/storage -> UNAVAILABLE collapse (C6.4-B): the tracker exposes
//    `lookup` (the raw DeliveryLookup); a corrupt or failed read is NOT silently
//    reported as UNAVAILABLE. The lossy `state` seam was removed.
//  * No durable state=UNAVAILABLE (C6.4-C): a persisted state code 0 is corrupt,
//    rejected by the schema CHECK(state IN (1..5)) and the decode guard.
//  * 16-byte msg_id at the boundary (C6.4-D): every repository method rejects a
//    non-16-byte msg_id with InvalidArgument BEFORE any SQL.
//  * Real SQL CAS (C6.4-F): transitions are guarded `UPDATE ... WHERE msg_id AND
//    state IN (...)`; the write is decided by the affected row count, not a stale
//    pre-read.
//  * The repository owns the lifecycle truth-table (C6.4-G): the public API is
//    `transition(msgId, DeliveryTransition)`, not an arbitrary
//    `compareAndSet(validFroms, target)` a caller could misuse.
//  * ACK CAS binds STATE + MODE + RECIPIENT in one WHERE (C6.4-H): a guarded
//    `UPDATE ... SET acknowledged WHERE msg_id AND state IN (queued,handed) AND
//    ack_mode = SINGLE_RECIPIENT AND expected_recipient = ?` -- the authenticated
//    ACK's binding is part of the CAS predicate, not a separate re-read.

/**
 * Delivery lifecycle (ADR-005). Terminal states are ACKNOWLEDGED_BY_RECIPIENT,
 * EXPIRED and CANCELLED_LOCALLY.
 *
 * [code] / [fromCode] are the cross-platform persistence contract (NOT the
 * Kotlin enum ordinal), so Android and iOS agree even if their enum orders ever
 * diverge. [fromCode] returns null for an unknown code -- an unknown persisted
 * state fails closed (C6.5) rather than silently mapping to UNAVAILABLE.
 *
 * C6.4-C: UNAVAILABLE (code 0) is an in-memory / lifecycle concept ONLY -- it is
 * NOT a legal durable row. [fromPersistedCode] is the decoder used on the
 * durable read path: it rejects code 0 (and any unknown code) so a persisted
 * UNAVAILABLE fails closed to [DeliveryLookup.Corrupt]. No normal creation path
 * writes code 0; the schema `CHECK (state IN (1,2,3,4,5))` rejects it at write
 * time, and [fromPersistedCode] rejects it at read time (defense in depth for a
 * legacy / bypassed-CHECK / corrupt-file row).
 */
enum class DeliveryState {
    UNAVAILABLE,
    QUEUED_DURABLY,
    HANDED_TO_RELAY,
    ACKNOWLEDGED_BY_RECIPIENT,
    EXPIRED,
    CANCELLED_LOCALLY;

    val isTerminal: Boolean get() =
        this == ACKNOWLEDGED_BY_RECIPIENT || this == EXPIRED || this == CANCELLED_LOCALLY

    /** Stable int persistence code (cross-platform contract, mirrors iOS). */
    val code: Int get() = when (this) {
        UNAVAILABLE -> 0
        QUEUED_DURABLY -> 1
        HANDED_TO_RELAY -> 2
        ACKNOWLEDGED_BY_RECIPIENT -> 3
        EXPIRED -> 4
        CANCELLED_LOCALLY -> 5
    }

    companion object {
        /** Decode a persisted code, or null if the code is unknown (fail closed). */
        fun fromCode(c: Int): DeliveryState? = when (c) {
            0 -> UNAVAILABLE
            1 -> QUEUED_DURABLY
            2 -> HANDED_TO_RELAY
            3 -> ACKNOWLEDGED_BY_RECIPIENT
            4 -> EXPIRED
            5 -> CANCELLED_LOCALLY
            else -> null
        }

        /**
         * Decode a persisted durable-row state (C6.4-C). Rejects code 0
         * (UNAVAILABLE) -- UNAVAILABLE is NOT a legal durable row, only an
         * in-memory concept, so a persisted 0 fails closed to Corrupt. Used on
         * the durable read path ([DeliveryRepository.get]); [fromCode] is used
         * for in-memory state round-trips.
         */
        fun fromPersistedCode(c: Int): DeliveryState? = when (c) {
            1 -> QUEUED_DURABLY
            2 -> HANDED_TO_RELAY
            3 -> ACKNOWLEDGED_BY_RECIPIENT
            4 -> EXPIRED
            5 -> CANCELLED_LOCALLY
            else -> null // 0 (UNAVAILABLE) and any unknown code -> fail closed
        }
    }
}

/**
 * Whether a tracked message is eligible for an authenticated recipient ACK.
 *
 *  * NONE -- a broadcast / group / SOS frame. No single intended recipient is
 *    bound, so no ACK can ever advance it to ACKNOWLEDGED_BY_RECIPIENT. An
 *    inbound ACK for a NONE-mode message yields [AckResult.NotAckEligible] and
 *    the authenticator is NOT invoked (a recipient identity may NEVER become
 *    trusted merely because the ACK packet names it -- C6.1).
 *  * SINGLE_RECIPIENT -- a DIRECT message addressed to exactly one node id
 *    (16 bytes), bound durably at enqueue time. An ACK advances the state only
 *    if it is from THAT recipient (see [AckAuthenticator]).
 *
 * Do NOT invent a multi-recipient ACK policy here (C6.1). The int code is the
 * cross-platform persistence contract (mirrors iOS AckMode).
 */
enum class AckMode(val code: Int) {
    NONE(0),
    SINGLE_RECIPIENT(1);

    companion object {
        /** Decode a persisted code, or null if unknown (fail closed). */
        fun fromCode(c: Int): AckMode? = when (c) {
            0 -> NONE
            1 -> SINGLE_RECIPIENT
            else -> null
        }
    }
}

/**
 * One durable delivery record: the lifecycle state, the ACK mode, and (for
 * SINGLE_RECIPIENT) the intended recipient node id bound at enqueue time. The
 * expected recipient is IMMUTABLE post-creation (it records historical send
 * intent); re-enqueuing with a different binding is a [EnqueueResult.ConflictRecipient],
 * not a mutation. For AckMode.NONE, [expectedRecipientNodeId] is null.
 *
 * C6.4-K: the [ByteArray] fields are defensively copied at construction (Kotlin
 * `ByteArray` is reference-mutable, unlike Swift `Data`'s value semantics). A
 * caller that mutates the source array after handing it to a record / repository
 * cannot mutate the durable binding the record holds. The record is the
 * immutable historical send intent; it is never aliased to caller-owned storage
 * in the production repository or the test fakes.
 */
class DeliveryRecord(
    msgId: ByteArray,
    val state: DeliveryState,
    val ackMode: AckMode,
    expectedRecipientNodeId: ByteArray?,
) {
    /** C6.4-K + C6.4.1-J: defensive copy on construction AND a fresh copy on
     *  every read -- a caller cannot mutate the record's internal storage via
     *  the constructor input nor via the exported id. */
    private val _msgId: ByteArray = msgId.copyOf()
    val msgId: ByteArray
        get() = _msgId.copyOf()
    /** C6.4-K + C6.4.1-J: defensive copy on construction AND a fresh copy on
     *  every read -- the immutable historical send intent. */
    private val _expectedRecipientNodeId: ByteArray? = expectedRecipientNodeId?.copyOf()
    val expectedRecipientNodeId: ByteArray?
        get() = _expectedRecipientNodeId?.copyOf()

    /** Copy with overridden fields (re-copies the byte arrays). */
    fun copy(
        msgId: ByteArray = this.msgId,
        state: DeliveryState = this.state,
        ackMode: AckMode = this.ackMode,
        expectedRecipientNodeId: ByteArray? = this.expectedRecipientNodeId,
    ): DeliveryRecord = DeliveryRecord(msgId, state, ackMode, expectedRecipientNodeId)

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is DeliveryRecord) return false
        return state == other.state && ackMode == other.ackMode &&
            msgId.contentEquals(other.msgId) &&
            expectedRecipientNodeId.contentEquals(other.expectedRecipientNodeId)
    }

    override fun hashCode(): Int {
        var h = state.hashCode()
        h = 31 * h + ackMode.hashCode()
        h = 31 * h + msgId.contentHashCode()
        h = 31 * h + (expectedRecipientNodeId?.contentHashCode() ?: 0)
        return h
    }
}

/**
 * Result of reading a delivery record by msg_id. Sealed so the caller MUST
 * handle every outcome -- a corrupt or unknown row can never be silently
 * treated as a valid state (C6.5). C6.4-A: [StorageFailure] is a REAL,
 * distinguishable outcome (SQL / IO failure), never folded into [NotFound].
 * C6.4-D: [InvalidArgument] is a non-16-byte msg_id rejected before any SQL --
 * NOT [Corrupt] (a caller precondition violation is distinct from a corrupt row).
 */
sealed interface DeliveryLookup {
    /** A row was found and decoded into a consistent [DeliveryRecord]. */
    data class Found(val record: DeliveryRecord) : DeliveryLookup
    /** No row exists for the msg_id (never tracked, or forgotten). */
    data object NotFound : DeliveryLookup
    /** A row exists but its state / ack_mode / recipient binding is unknown or
     *  inconsistent (fails the schema CHECK or the code tables, including a
     *  persisted state code 0 / UNAVAILABLE). Fail closed. */
    data object Corrupt : DeliveryLookup
    /** The underlying store failed to read (IO / SQL error / missing handle). */
    data object StorageFailure : DeliveryLookup
    /** The msg_id is not exactly 16 bytes -- rejected before any SQL (C6.4-D). */
    data object InvalidArgument : DeliveryLookup
}

/**
 * Outcome of [DeliveryRepository.enqueue]. Sealed (C6.2): a delivery-security
 * outcome is never a Bool the caller can misread as "ok". C6.4-A/D add
 * [StorageFailure] (real SQL failure) and [InvalidArgument] (non-16-byte msg_id).
 */
sealed interface EnqueueResult {
    /** A new delivery record was durably created in QUEUED_DURABLY. */
    data object Created : EnqueueResult
    /** A non-terminal record with the SAME binding already exists -- idempotent
     *  re-enqueue of the same logical message (retry). No new row, no mutation. */
    data object AlreadyQueuedSameBinding : EnqueueResult
    /** A record exists with a DIFFERENT binding (different ack mode or intended
     *  recipient). Fail closed -- the historical send intent is not overwritten. */
    data object ConflictRecipient : EnqueueResult
    /** The record is already in a terminal state (acked / expired / cancelled). */
    data object RejectedTerminalState : EnqueueResult
    /** The underlying store failed to read / write (C6.4-A). */
    data object StorageFailure : EnqueueResult
    /** The store returned a corrupt / inconsistent record. */
    data object Corrupt : EnqueueResult
    /** The msg_id is not exactly 16 bytes -- rejected before any SQL (C6.4-D). */
    data object InvalidArgument : EnqueueResult
}

/**
 * Outcome of [DeliveryTracker.acknowledge]. Sealed (C6.2): the caller must
 * branch on the outcome and can NEVER translate [AlreadyAcknowledged] or
 * [DuplicateAuthenticatedAck] into "this ACK was newly verified" -- they mean
 * the message was already in a terminal acknowledged state, NOT that this
 * packet authenticated (option B: a terminal record short-circuits BEFORE the
 * authenticator is invoked, bounding CPU under a flood of replayed ACKs).
 *
 * C6.4-H: [DuplicateAuthenticatedAck] is now REACHABLE via the SQL CAS. When two
 * authenticated ACKs race -- both read HANDED, both authenticate, ACK #1's CAS
 * succeeds (`Applied`), ACK #2's guarded UPDATE matches 0 rows and re-reads
 * ACKNOWLEDGED with the SAME binding -- ACK #2 yields [DuplicateAuthenticatedAck]
 * (authenticated, but not a new verification). An authenticated ACK that loses the
 * CAS to a cancel / expire re-reads a terminal non-acknowledged state and yields
 * [RejectedState]; one that loses to a recipient rebinding yields
 * [UnknownMessage] (an old ACK must never bind to a new row).
 */
sealed interface AckResult {
    /** The ACK authenticated for the bound recipient and the state advanced to
     *  ACKNOWLEDGED_BY_RECIPIENT. This is the ONLY outcome that means "verified". */
    data object Applied : AckResult
    /** The ACK authenticated, but the message was already acknowledged by a prior
     *  authenticated ACK that won the CAS race. Not a new verification. (C6.4-H.) */
    data object DuplicateAuthenticatedAck : AckResult
    /** The record is already ACKNOWLEDGED; this ACK was NOT authenticated
     *  (short-circuit, option B). Not "verified". */
    data object AlreadyAcknowledged : AckResult
    /** The message is AckMode.NONE -- broadcasts are not ACK-eligible. The
     *  authenticator was NOT invoked; the state is unchanged. (C6.1 invariant.) */
    data object NotAckEligible : AckResult
    /** No delivery record exists for the msg_id, OR the row vanished / was re-bound
     *  to a different recipient before the ACK's CAS could match. */
    data object UnknownMessage : AckResult
    /** The ACK was reached but failed authentication (wrong recipient / wrong
     *  msg id / tampered / unsigned / unresolved key). State unchanged. */
    data object RejectedAuthentication : AckResult
    /** The record is in a non-ackable state (EXPIRED / CANCELLED) -- the ACK lost
     *  the CAS to a cancel / expire. State unchanged. */
    data object RejectedState : AckResult
    /** The underlying store failed to read / write (C6.4-A). */
    data object StorageFailure : AckResult
    /** The store returned a corrupt / inconsistent record. */
    data object Corrupt : AckResult
    /** The msg_id is not exactly 16 bytes -- rejected before any SQL (C6.4-D). */
    data object InvalidArgument : AckResult
}

/**
 * Outcome of a non-ACK lifecycle transition ([DeliveryTransition.MARK_HANDED] /
 * [EXPIRE] / [CANCEL]). Sealed (C6.2): like [AckResult], a delivery-security
 * outcome is never a Bool the caller can misread as "ok". The caller MUST branch
 * and can NEVER translate [AlreadyInTarget] into "this transition just happened"
 * -- it means the record was already in the target state (idempotent re-issue,
 * e.g. a crash-then-resume that re-marks handed), NOT a fresh transition. Only
 * [Applied] means the state advanced on this call.
 *
 * C6.4-F: the transition is a guarded SQL CAS (`UPDATE ... WHERE msg_id AND
 * state IN (...)`); [Applied] is decided by an affected row count of 1, not a
 * stale pre-read. A 0-row CAS is re-read once and classified.
 */
sealed interface TransitionResult {
    /** The state advanced to the target on this call (fresh CAS transition persisted). */
    data object Applied : TransitionResult
    /** The record was already in the target state -- idempotent, NO mutation. Not
     *  a fresh transition. */
    data object AlreadyInTarget : TransitionResult
    /** A record exists but its current state disallows this transition (e.g.
     *  marking handed an ACKNOWLEDGED / EXPIRED / CANCELLED record). No mutation. */
    data object RejectedState : TransitionResult
    /** No durable record exists for the msg_id (never tracked, or it vanished
     *  mid-call via a raced clear). */
    data object UnknownMessage : TransitionResult
    /** The store returned a corrupt / inconsistent record. Fail closed. */
    data object Corrupt : TransitionResult
    /** The underlying store failed to read / write (C6.4-A). */
    data object StorageFailure : TransitionResult
    /** The msg_id is not exactly 16 bytes -- rejected before any SQL (C6.4-D). */
    data object InvalidArgument : TransitionResult
}

/**
 * Outcome of [DeliveryRepository.clear] (C6.4-J). A destructive operation is
 * never `Unit` / void -- a failed clear looks different from success and from
 * "nothing to delete", so expiry cleanup, panic-wipe coordination and crash
 * recovery can tell them apart.
 */
sealed interface ClearResult {
    /** A row existed and was dropped. */
    data object Cleared : ClearResult
    /** No row existed for the msg_id (already absent / never tracked). */
    data object AlreadyAbsent : ClearResult
    /** The underlying store failed (C6.4-A). */
    data object StorageFailure : ClearResult
    /** The msg_id is not exactly 16 bytes -- rejected before any SQL (C6.4-D). */
    data object InvalidArgument : ClearResult
}

/**
 * A legal non-ACK lifecycle transition the repository owns (C6.4-G). The
 * repository, not the caller, maps a transition to its fixed (valid-from-states,
 * target) pair, so a caller cannot ask for an illegal truth-table like
 * `ACKNOWLEDGED -> QUEUED` or `CANCELLED -> HANDED` by passing the wrong
 * arguments. The fixed mapping:
 *  * [MARK_HANDED] -- QUEUED_DURABLY -> HANDED_TO_RELAY.
 *  * [EXPIRE]      -- QUEUED_DURABLY | HANDED_TO_RELAY -> EXPIRED.
 *  * [CANCEL]      -- QUEUED_DURABLY | HANDED_TO_RELAY -> CANCELLED_LOCALLY.
 */
enum class DeliveryTransition {
    MARK_HANDED,
    EXPIRE,
    CANCEL,
}

/**
 * Atomic durable delivery aggregate per message id (C6.3; hardened C6.4). Folds
 * the C6.1 `DeliveryJournal` plus the enqueue / transition / retire
 * classification into ONE repository whose every mutation is a single atomic
 * guarded SQL statement over the SAME `delivery_state` row keyed by msg_id. The
 * state, ack mode and expected recipient live in that one row; the expected
 * recipient is IMMUTABLE post-creation (C6.1/C6.3) -- no method here updates it,
 * so a re-enqueue with a different binding is [EnqueueResult.ConflictRecipient],
 * not a mutation.
 *
 * The repository is the single place that maps a durable row to the typed
 * delivery outcomes ([DeliveryLookup] / [EnqueueResult] / [TransitionResult] /
 * [AckResult] / [ClearResult]). C6.4 hardening:
 *  * Storage failure is REAL (C6.4-A): SQL exceptions / prepare-step failures /
 *    a missing DB handle are caught and mapped to the typed `StorageFailure`
 *    variant -- NEVER folded into `NotFound` / `false` / `0`. Absence / conflict
 *    / no-match use their own sentinels. `Exception` (not `Throwable`) is caught
 *    at this boundary.
 *  * 16-byte msg_id (C6.4-D): every method rejects a non-16-byte msg_id with
 *    `InvalidArgument` BEFORE any SQL.
 *  * SQL CAS (C6.4-F): [transition] runs `UPDATE ... SET state WHERE msg_id AND
 *    state IN (...)` and decides [Applied] by the affected row count; a 0-row
 *    result is re-read ONCE to classify ([AlreadyInTarget] / [RejectedState] /
 *    [UnknownMessage] / [Corrupt] / [StorageFailure]).
 *  * Lifecycle truth-table owned here (C6.4-G): [transition] takes a
 *    [DeliveryTransition], not an arbitrary (validFroms, target) pair.
 *  * ACK CAS (C6.4-H): [acknowledgeBound] runs
 *    `UPDATE ... SET acknowledged WHERE msg_id AND state IN (queued,handed) AND
 *    ack_mode = SINGLE_RECIPIENT AND expected_recipient = ?` -- state + mode +
 *    exact durable recipient in ONE WHERE clause. A 0-row CAS is re-read and
 *    classified ([DuplicateAuthenticatedAck] for same-binding ACKNOWLEDGED,
 *    [RejectedState] for EXPIRED/CANCELLED, [UnknownMessage] for a vanished /
 *    re-bound row, [StorageFailure] for a same-binding QUEUED/HANDED row that the
 *    SQL should have matched).
 *  * `acknowledgeBound` performs delivery-state retirement ONLY. It does NOT yet
 *    delete the corresponding held frame -- that cross-table atomic transaction
 *    is C7.4 (ADR-004 delete-on-authenticated-ACK is NOT closed by this method).
 *    The name says `acknowledgeBound` (the durable binding CAS), not
 *    `acknowledgeAndRetire`, so it does not imply the held-frame retirement is
 *    implemented (C6.4-I).
 *
 * Each mutation is one atomic SQL statement (see StoreSchema): [enqueue]
 * creates the row (INSERT ... ON CONFLICT DO NOTHING -- a conflict is classified
 * by re-reading), [transition] / [acknowledgeBound] advance the state column via
 * a guarded CAS UPDATE (preserving ack_mode + expected_recipient), [clear] drops
 * the row. No read-modify-write seam, so a crash between operations leaves the
 * LAST persisted state on disk -- the crash-safe semantics ADR-005 requires.
 *
 * NOTE (C6.4-N): row-atomicity here is the `delivery_state` row only. It does NOT
 * yet make `persist held frame` + `enqueue delivery record` atomic -- that
 * cross-table outbound transaction is C6.6. A DIRECT send is transport-eligible
 * only after BOTH are committed (C6.6); until then the outbound path composes
 * them as separate operations.
 *
 * Implementations must persist across a reboot/jetsam so a fresh
 * [DeliveryTracker] over the same repository recovers the record (reboot
 * recovery, ADR-005 exit criteria).
 */
interface DeliveryRepository {
    /** Read the delivery record for `msgId`, or [DeliveryLookup.NotFound].
     *  C6.4-A/D: a storage failure is [StorageFailure]; a non-16-byte msg_id is
     *  [InvalidArgument] (before any SQL). */
    fun get(msgId: ByteArray): DeliveryLookup

    /**
     * Atomically create / classify a delivery record for `msgId` with [ackMode]
     * and [expectedRecipient] (null for AckMode.NONE, 16 bytes for
     * SINGLE_RECIPIENT). A NEW row in QUEUED_DURABLY -> [EnqueueResult.Created];
     * a non-terminal row with the SAME binding -> [AlreadyQueuedSameBinding]
     * (idempotent, no mutation); a row with a DIFFERENT binding ->
     * [ConflictRecipient] (the historical send intent is NEVER overwritten); a
     * terminal row -> [RejectedTerminalState]. The expected recipient is NEVER
     * updated on an existing row. A binding that violates the C6.1 invariant ->
     * [EnqueueResult.Corrupt]. C6.4-A/D: a storage failure is [StorageFailure];
     * a non-16-byte msg_id is [InvalidArgument] (before any SQL).
     */
    fun enqueue(msgId: ByteArray, ackMode: AckMode, expectedRecipient: ByteArray?): EnqueueResult

    /**
     * Guarded SQL CAS lifecycle transition with explicit HeldDisposition policy (C7.5.1).
     * Dispatches based on transitionSpec(transition).heldDisposition:
     *  * RETAIN (MARK_HANDED): state-only guarded CAS update; held frame is retained.
     *  * RETIRE_ATOMICALLY (EXPIRE, CANCEL): atomic guarded CAS update + held_frames
     *    deletion in one transaction. If held frame is missing while delivery row is
     *    active, rolls back and yields Corrupt.
     * A 0-row CAS is re-read ONCE and classified: row absent -> [UnknownMessage];
     * corrupt -> [Corrupt]; storage failure -> [StorageFailure];
     * state == target -> [AlreadyInTarget]; any other legal durable state ->
     * [RejectedState]; a same-validFrom state that the SQL should have matched
     * (invariant violation under concurrency) -> [StorageFailure]. The
     * (validFroms, target) pair is fixed by [transition] (C6.4-G), not supplied
     * by the caller. C6.4-D: a non-16-byte msg_id is [InvalidArgument].
     */
    fun transition(msgId: ByteArray, transition: DeliveryTransition): TransitionResult

    /**
     * Atomic authenticated ACK state commit + held-frame retirement (C7.4; ADR-004).
     * Runs the guarded CAS `UPDATE delivery_state SET state = ACKNOWLEDGED WHERE
     * msg_id = ? AND state IN (QUEUED, HANDED) AND ack_mode = SINGLE_RECIPIENT AND
     * expected_recipient = ?` AND deletes the exact held frame `DELETE FROM held_frames
     * WHERE msg_id = ?` in ONE atomic transaction. [AckResult.Applied] iff both operations
     * succeed and commit. If the held frame is missing while the delivery row is active,
     * the transaction rolls back and returns [AckResult.Corrupt]. A 0-row CAS is re-read
     * ONCE and classified without deleting held frames.
     * C6.4-D: a non-16-byte msg_id or recipient is [InvalidArgument].
     */
    fun acknowledgeBoundAndRetire(msgId: ByteArray, expectedRecipient: ByteArray): AckResult

    /**
     * Drop the delivery row for `msgId` (C6.4-J). Typed -- a failed destructive
     * operation is never indistinguishable from success: [Cleared] (a row was
     * dropped), [AlreadyAbsent] (no row), [StorageFailure] (C6.4-A),
     * [InvalidArgument] (C6.4-D). C6.4.1-K: [Corrupt] is removed -- `clear` is a
     * single DELETE; a corrupt read is impossible (no row is decoded).
     */
    fun clear(msgId: ByteArray): ClearResult

    /**
     * T39 (section 14): commit the broadcast author's PAIR -- the held frame AND
     * its NONE-mode delivery row -- as ONE durable operation. This is the card's
     * "one durable authority" for the SOS path; validation runs first and
     * nothing is written when any gate refuses (fail closed).
     *
     * The DEFAULT body is the compatible two-step route the sealed journals of
     * T24/T38 already speak with, byte for byte: run the caller's [persist]
     * closure over the frame table, then record the row through [enqueue] with
     * (AckMode.NONE, no recipient). Journals that keep the two tables apart see
     * the very sequence of operations of the pre-T39 dispatch -- no observer is
     * broken by this addition.
     *
     * A repository that owns BOTH tables in one authority -- the shared SQL
     * engine (one transaction), the store-backed in-memory repository (one
     * monitor) -- OVERRIDES this member with the atomic pair-commit: either both
     * rows appear or neither does, and a second-write failure rolls the whole
     * pair back ([OutboundEnqueueResult.StorageFailure], never a silent half).
     * A fresh pair reports [OutboundEnqueueResult.Created] carrying the
     * read-back canonical frame; a re-delivery of the identical pair is the
     * idempotent [OutboundEnqueueResult.AlreadyQueuedSameBinding]; conflicts and
     * terminal rows are classified apart, never conflated.
     */
    suspend fun enqueueSosOutbound(
        frame: FrameV2,
        localOriginNodeId: ByteArray,
        persist: suspend () -> PersistResult,
    ): OutboundEnqueueResult {
        // -- policy gates, before any write ---------------------------------------
        if (frame.msgId.size != 16) return OutboundEnqueueResult.InvalidArgument
        if (frame.routingTag.size != 4) return OutboundEnqueueResult.InvalidArgument
        if (frame.ttl !in 0..FrameV2.MAX_TTL) return OutboundEnqueueResult.InvalidArgument
        if (frame.hopCount !in 0..FrameV2.MAX_TTL) return OutboundEnqueueResult.InvalidArgument
        if (frame.flags !in 0..0xFFFF) return OutboundEnqueueResult.InvalidArgument
        if (frame.payload.size > FrameV2.MAX_PAYLOAD) return OutboundEnqueueResult.InvalidArgument
        if (localOriginNodeId.size != 16) return OutboundEnqueueResult.InvalidArgument
        if (frame.type != TypeV2.SOS) return OutboundEnqueueResult.InvalidArgument
        // the outer code and the required flags stand forever as the tables
        // record them (T38/section 15): a distress frame must carry BOTH bits.
        if ((frame.flags and FrameV2.ACK_REQ) == 0 ||
            (frame.flags and FrameV2.RELAY_OK) == 0
        ) return OutboundEnqueueResult.InvalidArgument
        // -- the compatible two-step route (persist, then record) ------------------
        return when (val p = persist()) {
            PersistResult.HELD_NEW, PersistResult.HELD_DUPLICATE ->
                when (val e = enqueue(frame.msgId, AckMode.NONE, null)) {
                    EnqueueResult.Created -> OutboundEnqueueResult.Created(frame)
                    EnqueueResult.AlreadyQueuedSameBinding ->
                        OutboundEnqueueResult.AlreadyQueuedSameBinding(frame)
                    EnqueueResult.ConflictRecipient -> OutboundEnqueueResult.ConflictRecipient
                    EnqueueResult.RejectedTerminalState -> OutboundEnqueueResult.RejectedTerminalState
                    EnqueueResult.Corrupt -> OutboundEnqueueResult.InconsistentState
                    EnqueueResult.StorageFailure -> OutboundEnqueueResult.StorageFailure
                    EnqueueResult.InvalidArgument -> OutboundEnqueueResult.InvalidArgument
                }
            PersistResult.REJECTED_CAPACITY -> OutboundEnqueueResult.RejectedCapacity
            PersistResult.FAILED_STORAGE -> OutboundEnqueueResult.StorageFailure
        }
    }
}

/**
 * High-level delivery state machine (ADR-004; ADR-005). Coordinates
 * authenticated ACK verification against the durable [DeliveryRepository].
 *
 * Sits ABOVE the atomic repository primitives (get / enqueue / transition /
 * acknowledgeBoundAndRetire / clear); the tracker owns the ACK policy: the terminal
 * short-circuit (option B), the NONE-mode rejection, and the cryptographic
 * authentication against the durable expected recipient. The repository owns
 * the atomic SQL CAS (guarded transitions) and the 0-row CAS reclassification.
 *
 * Inbound ACK flow:
 *   [acknowledge]
 *     ↓
 *   durable record read ([DeliveryRepository.get])
 *     ↓
 *   terminal / NONE checks (option B: ACKNOWLEDGED -> AlreadyAcknowledged, no auth)
 *     ↓
 *   cryptographic verification ([AckAuthenticator.verify] against durable recipient)
 *     ↓
 *   atomic commit + held retirement ([DeliveryRepository.acknowledgeBoundAndRetire])
 *     ↓
 *   durable ACK state + held deletion committed
 */
class DeliveryTracker(
    private val repo: DeliveryRepository,
    private val authenticator: AckAuthenticator,
) {
    /**
     * Read the delivery state for [msgId] (reboot recovery / outbound state
     * inspection). Typed outcome: [DeliveryLookup.Found] / [DeliveryLookup.NotFound] /
     * [DeliveryLookup.Corrupt] / [DeliveryLookup.StorageFailure].
     */
    fun get(msgId: ByteArray): DeliveryLookup = repo.get(msgId)

    fun lookup(msgId: ByteArray): DeliveryLookup = get(msgId)

    /**
     * Enqueue a new delivery record. Called during the atomic outbound enqueue
     * path ([io.godstone.mesh.store.MessageStore.enqueueDirectOutbound]).
     */
    fun enqueue(
        msgId: ByteArray,
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): EnqueueResult = repo.enqueue(msgId, ackMode, expectedRecipient)

    /**
     * Advance a delivery record from QUEUED_DURABLY -> HANDED_TO_RELAY via a
     * guarded SQL CAS (C6.4-F/G).
     */
    fun markHanded(msgId: ByteArray): TransitionResult =
        repo.transition(msgId, DeliveryTransition.MARK_HANDED)

    fun markHandedToRelay(msgId: ByteArray): TransitionResult = markHanded(msgId)

    /**
     * Apply an authenticated recipient ACK (C6.1; C6.4-H; C7.4). The outcome is typed
     * ([AckResult]); only [AckResult.Applied] means "this ACK verified, state advanced,
     * and held frame was retired". A NONE-mode message is [NotAckEligible] and the
     * authenticator is NOT invoked. A terminal acknowledged record short-
     * circuits to [AlreadyAcknowledged] WITHOUT authenticating (option B: bound
     * CPU under replayed ACK floods; NOT a verification). EXPIRED / CANCELLED
     * records are [RejectedState]. A SINGLE_RECIPIENT record authenticates the
     * ACK against the durable expected recipient; failure is
     * [RejectedAuthentication] and the state is unchanged. On a verified ACK the
     * state commit and held-frame retirement are persisted atomically by
     * [DeliveryRepository.acknowledgeBoundAndRetire], whose guarded CAS binds state + mode
     * + the exact durable recipient in one WHERE clause and deletes the held frame -- so a
     * verified ACK that loses the race to another verified ACK yields [DuplicateAuthenticatedAck],
     * to a cancel/expire yields [RejectedState], and to a recipient rebinding
     * yields [UnknownMessage].
     */
    fun acknowledge(msgId: ByteArray, ackFrame: FrameV2): AckResult {
        return when (val l = repo.get(msgId)) {
            DeliveryLookup.NotFound -> AckResult.UnknownMessage
            DeliveryLookup.Corrupt -> AckResult.Corrupt
            DeliveryLookup.StorageFailure -> AckResult.StorageFailure
            DeliveryLookup.InvalidArgument -> AckResult.InvalidArgument
            is DeliveryLookup.Found -> {
                val rec = l.record
                if (rec.state == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT) {
                    return AckResult.AlreadyAcknowledged // option B: short-circuit, no auth
                }
                if (rec.state.isTerminal) return AckResult.RejectedState // EXPIRED / CANCELLED
                if (rec.state != DeliveryState.QUEUED_DURABLY &&
                    rec.state != DeliveryState.HANDED_TO_RELAY
                ) return AckResult.RejectedState // anomalous non-terminal (UNAVAILABLE)
                if (rec.ackMode == AckMode.NONE) return AckResult.NotAckEligible // authenticator NOT invoked
                // SINGLE_RECIPIENT: expected recipient is non-null by the schema CHECK.
                val expected = rec.expectedRecipientNodeId
                    ?: return AckResult.Corrupt // invariant violation (CHECK should prevent)
                if (!authenticator.verify(msgId, expected, ackFrame)) {
                    return AckResult.RejectedAuthentication
                }
                // Atomic state commit + held retirement: a guarded CAS binds state + mode + the
                // exact durable recipient in one WHERE clause and deletes held_frames in ONE transaction.
                // The tracker authenticated before this call; a lost CAS is classified by the
                // repository (DuplicateAuthenticatedAck / RejectedState / UnknownMessage).
                return repo.acknowledgeBoundAndRetire(msgId, expected)
            }
        }
    }

    /** TTL expiry: QUEUED_DURABLY or HANDED_TO_RELAY -> EXPIRED via a guarded
     *  SQL CAS (C6.4-F/G). Idempotent from EXPIRED ([TransitionResult.AlreadyInTarget]);
     *  [TransitionResult.RejectedState] from a terminal non-target state
     *  (ACKNOWLEDGED / CANCELLED). */
    fun expire(msgId: ByteArray): TransitionResult =
        repo.transition(msgId, DeliveryTransition.EXPIRE)

    /**
     * Local cancellation: QUEUED_DURABLY or HANDED_TO_RELAY -> CANCELLED_LOCALLY
     * via a guarded SQL CAS (C6.4-F/G). Idempotent from CANCELLED_LOCALLY
     * ([TransitionResult.AlreadyInTarget]); [TransitionResult.RejectedState] from
     * a terminal non-target state (ACKNOWLEDGED / EXPIRED). Cancellation cannot
     * recall already relayed copies -- the caller gives the truthful UI; the
     * state machine records the intent.
     */
    fun cancel(msgId: ByteArray): TransitionResult =
        repo.transition(msgId, DeliveryTransition.CANCEL)

    /**
     * Drop tracking for `msgId` (e.g. after it ages out of the store). Typed
     * (C6.4-J): a failed destructive operation is never indistinguishable from
     * success.
     */
    fun forget(msgId: ByteArray): ClearResult = repo.clear(msgId)

    /**
     * T39: forward the broadcast PAIR-COMMIT (held frame + NONE-mode row) to
     * the repository authority. A repository that owns both tables commits them
     * in one transaction; a plain journal inherits the compatible two-step route
     * (persist, then record) defined on [DeliveryRepository.enqueueSosOutbound].
     * The tracker adds no policy of its own -- the validation ladder lives in
     * one place, and no silent half-commits are reachable from either route.
     */
    suspend fun enqueueSosOutbound(
        frame: io.godstone.mesh.wire.v2.FrameV2,
        localOriginNodeId: ByteArray,
        persist: suspend () -> io.godstone.mesh.store.PersistResult,
    ): io.godstone.mesh.store.OutboundEnqueueResult =
        repo.enqueueSosOutbound(frame, localOriginNodeId, persist)

    /**
     * T39 (section 14): the ONE durable cancellation for a broadcast obligation.
     * The row moves QUEUED_DURABLY/HANDED_TO_RELAY -> CANCELLED_LOCALLY through
     * the repository's guarded CAS, and the held frame is retired with it -- in
     * one transaction under the authority that owns both tables (the shared SQL
     * engine's C7.5 machinery; the store-backed repository under the store's one
     * monitor). Cancellation cannot recall copies already relayed: the truth of
     * what had gone out is reported in [SosCancelResult.Cancelled.wasRelayed]
     * and the UI must tell it. Duplicate cancellation is the idempotent
     * [SosCancelResult.AlreadyCancelled], never an error; a directed
     * (SINGLE_RECIPIENT) obligation is [SosCancelResult.NotBroadcast] and is
     * touched by no hand here. Nothing moves on any refused path.
     */
    fun cancelSosBroadcast(msgId: ByteArray): io.godstone.mesh.SosCancelResult {
        if (msgId.size != 16) return io.godstone.mesh.SosCancelResult.InvalidArgument
        return when (val peek = repo.get(msgId)) {
            DeliveryLookup.NotFound -> io.godstone.mesh.SosCancelResult.UnknownMessage
            DeliveryLookup.Corrupt -> io.godstone.mesh.SosCancelResult.Corrupt
            DeliveryLookup.StorageFailure -> io.godstone.mesh.SosCancelResult.StorageFailure
            DeliveryLookup.InvalidArgument -> io.godstone.mesh.SosCancelResult.InvalidArgument
            is DeliveryLookup.Found -> {
                val rec = peek.record
                if (rec.ackMode != AckMode.NONE)
                    return io.godstone.mesh.SosCancelResult.NotBroadcast
                val derived = when (rec.state) {
                    DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY ->
                        rec.state == DeliveryState.HANDED_TO_RELAY
                    DeliveryState.CANCELLED_LOCALLY ->
                        return io.godstone.mesh.SosCancelResult.AlreadyCancelled(null)
                    DeliveryState.EXPIRED, DeliveryState.ACKNOWLEDGED_BY_RECIPIENT ->
                        return io.godstone.mesh.SosCancelResult.RejectedTerminal(rec.state)
                    DeliveryState.UNAVAILABLE ->
                        return io.godstone.mesh.SosCancelResult.Corrupt
                }
                when (val t = repo.transition(msgId, DeliveryTransition.CANCEL)) {
                    TransitionResult.Applied ->
                        io.godstone.mesh.SosCancelResult.Cancelled(derived)
                    TransitionResult.AlreadyInTarget ->
                        io.godstone.mesh.SosCancelResult.AlreadyCancelled(derived)
                    TransitionResult.RejectedState, TransitionResult.UnknownMessage ->
                        // raced to another terminal state (or forgotten) meanwhile:
                        // re-read ONCE and classify honestly, touch nothing
                        when (val again = repo.get(msgId)) {
                            DeliveryLookup.NotFound ->
                                io.godstone.mesh.SosCancelResult.UnknownMessage
                            DeliveryLookup.Corrupt -> io.godstone.mesh.SosCancelResult.Corrupt
                            DeliveryLookup.StorageFailure ->
                                io.godstone.mesh.SosCancelResult.StorageFailure
                            DeliveryLookup.InvalidArgument ->
                                io.godstone.mesh.SosCancelResult.InvalidArgument
                            is DeliveryLookup.Found -> when (again.record.state) {
                                DeliveryState.CANCELLED_LOCALLY ->
                                    io.godstone.mesh.SosCancelResult.AlreadyCancelled(derived)
                                DeliveryState.EXPIRED, DeliveryState.ACKNOWLEDGED_BY_RECIPIENT ->
                                    io.godstone.mesh.SosCancelResult.RejectedTerminal(again.record.state)
                                DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY ->
                                    // the CAS refused yet the row still stands live: the
                                    // transition machinery itself failed -- report it,
                                    // do not pretend the cancel moved
                                    io.godstone.mesh.SosCancelResult.StorageFailure
                                DeliveryState.UNAVAILABLE -> io.godstone.mesh.SosCancelResult.Corrupt
                            }
                        }
                    TransitionResult.Corrupt -> io.godstone.mesh.SosCancelResult.Corrupt
                    TransitionResult.StorageFailure -> io.godstone.mesh.SosCancelResult.StorageFailure
                    TransitionResult.InvalidArgument -> io.godstone.mesh.SosCancelResult.InvalidArgument
                }
            }
        }
    }
}

/**
 * T39 (section 14): the in-memory authority over BOTH tables -- the held frames
 * and the delivery rows -- under the store's one monitor. This is the durable
 * repository for the broadcast path where the shared SQL engine is the durable
 * repository in production: same classifications, same guarded transitions, same
 * both-or-neither law for the pair-commit ([enqueueSosOutbound]) and for the
 * retiring CANCEL/EXPIRE (C7.5: guarded terminal CAS + exact held-frame removal
 * in one transaction). Validation precedes every write; a refused operation
 * leaves the previous authoritative state whole; every typed result names its
 * cause (failure is distinguished from idempotent no-op, C6.4-A/J).
 */
internal class InMemoryStoreDeliveryRepository(
    private val store: io.godstone.mesh.store.InMemoryMessageStore,
) : DeliveryRepository {

    private class Spec(
        val target: DeliveryState,
        val validFroms: Set<DeliveryState>,
        val retiresHeld: Boolean,
    )

    private fun specOf(transition: DeliveryTransition): Spec = when (transition) {
        DeliveryTransition.MARK_HANDED -> Spec(
            DeliveryState.HANDED_TO_RELAY, setOf(DeliveryState.QUEUED_DURABLY), false)
        DeliveryTransition.EXPIRE -> Spec(
            DeliveryState.EXPIRED,
            setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), true)
        DeliveryTransition.CANCEL -> Spec(
            DeliveryState.CANCELLED_LOCALLY,
            setOf(DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY), true)
    }

    private fun bindingConsistent(
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): Boolean = when (ackMode) {
        AckMode.NONE -> expectedRecipient == null
        AckMode.SINGLE_RECIPIENT -> expectedRecipient?.size == 16
    }

    override fun get(msgId: ByteArray): DeliveryLookup {
        if (msgId.size != 16) return DeliveryLookup.InvalidArgument
        val row = store.readDeliveryRow(msgId) ?: return DeliveryLookup.NotFound
        val state = DeliveryState.fromPersistedCode(row.state) ?: return DeliveryLookup.Corrupt
        val ackMode = AckMode.fromCode(row.ackMode) ?: return DeliveryLookup.Corrupt
        if (!bindingConsistent(ackMode, row.expectedRecipient)) return DeliveryLookup.Corrupt
        return DeliveryLookup.Found(DeliveryRecord(msgId, state, ackMode, row.expectedRecipient))
    }

    override fun enqueue(
        msgId: ByteArray,
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): EnqueueResult {
        if (msgId.size != 16) return EnqueueResult.InvalidArgument
        if (!bindingConsistent(ackMode, expectedRecipient)) return EnqueueResult.Corrupt
        if (store.insertDeliveryRowIfAbsent(
                msgId, DeliveryState.QUEUED_DURABLY.code, ackMode.code, expectedRecipient)
        ) return EnqueueResult.Created
        // ON CONFLICT DO NOTHING -- re-read the row and classify it once (C6.4-T)
        return when (val l = get(msgId)) {
            DeliveryLookup.NotFound -> EnqueueResult.StorageFailure // vanished mid-classification: report, do not invent
            DeliveryLookup.Corrupt -> EnqueueResult.Corrupt
            DeliveryLookup.StorageFailure -> EnqueueResult.StorageFailure
            DeliveryLookup.InvalidArgument -> EnqueueResult.InvalidArgument
            is DeliveryLookup.Found -> {
                val rec = l.record
                if (rec.state.isTerminal) return EnqueueResult.RejectedTerminalState
                if (rec.ackMode != ackMode ||
                    !(rec.expectedRecipientNodeId?.contentEquals(expectedRecipient) ?: (expectedRecipient == null))
                ) return EnqueueResult.ConflictRecipient
                EnqueueResult.AlreadyQueuedSameBinding
            }
        }
    }

    override fun transition(msgId: ByteArray, transition: DeliveryTransition): TransitionResult {
        if (msgId.size != 16) return TransitionResult.InvalidArgument
        val spec = specOf(transition)
        return when (val l = get(msgId)) {
            DeliveryLookup.NotFound -> TransitionResult.UnknownMessage
            DeliveryLookup.Corrupt -> TransitionResult.Corrupt
            DeliveryLookup.StorageFailure -> TransitionResult.StorageFailure
            DeliveryLookup.InvalidArgument -> TransitionResult.InvalidArgument
            is DeliveryLookup.Found -> {
                val st = l.record.state
                if (st == spec.target) return TransitionResult.AlreadyInTarget
                if (st !in spec.validFroms) return TransitionResult.RejectedState
                if (spec.retiresHeld && store.heldSnapshot(msgId) == null) {
                    // C7.5: an active obligation without its held frame is cross-table
                    // corruption -- the transaction would roll back; nothing moves here
                    return TransitionResult.Corrupt
                }
                store.updateDeliveryState(msgId, spec.target.code)
                if (spec.retiresHeld) store.removeHeld(msgId)
                TransitionResult.Applied
            }
        }
    }

    override fun acknowledgeBoundAndRetire(
        msgId: ByteArray,
        expectedRecipient: ByteArray,
    ): AckResult {
        if (msgId.size != 16 || expectedRecipient.size != 16) return AckResult.InvalidArgument
        return when (val l = get(msgId)) {
            DeliveryLookup.NotFound -> AckResult.UnknownMessage
            DeliveryLookup.Corrupt -> AckResult.Corrupt
            DeliveryLookup.StorageFailure -> AckResult.StorageFailure
            DeliveryLookup.InvalidArgument -> AckResult.InvalidArgument
            is DeliveryLookup.Found -> {
                val rec = l.record
                if (rec.state == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT)
                    return AckResult.DuplicateAuthenticatedAck // option B short-circuit, no writes
                if (rec.state.isTerminal) return AckResult.RejectedState
                if (rec.ackMode != AckMode.SINGLE_RECIPIENT ||
                    !expectedRecipient.contentEquals(rec.expectedRecipientNodeId)
                ) return AckResult.UnknownMessage // the guarded WHERE binds the exact recipient
                // atomic commit (C7.4): state -> ACKED and the held frame retires together
                if (store.heldSnapshot(msgId) == null) return AckResult.Corrupt
                store.updateDeliveryState(msgId, DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code)
                store.removeHeld(msgId)
                AckResult.Applied
            }
        }
    }

    override fun clear(msgId: ByteArray): ClearResult {
        if (msgId.size != 16) return ClearResult.InvalidArgument
        return if (store.deleteDeliveryRow(msgId)) ClearResult.Cleared else ClearResult.AlreadyAbsent
    }

    /**
     * T39 THE OVERRIDE: the pair-commit over the one authority. Delegates to
     * [io.godstone.mesh.store.InMemoryMessageStore.enqueueSosOutboundAtWithFault],
     * which writes BOTH tables under the store's monitor with the both-or-neither
     * law and named fault seams -- the atomic in-memory twin of the shared
     * engine's inTransaction pair-commit.
     */
    override suspend fun enqueueSosOutbound(
        frame: io.godstone.mesh.wire.v2.FrameV2,
        localOriginNodeId: ByteArray,
        persist: suspend () -> io.godstone.mesh.store.PersistResult,
    ): io.godstone.mesh.store.OutboundEnqueueResult =
        store.enqueueSosOutboundAtWithFault(frame, localOriginNodeId, System.currentTimeMillis(), null)
}