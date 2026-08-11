package io.godstone.mesh.delivery

import io.godstone.mesh.wire.v2.FrameV2

// Stage 4C.1 / C6.1 -- durable, recipient-authenticated delivery state machine
// (ADR-005; A-03). The lifecycle from ADR-005:
//
//   UNAVAILABLE | QUEUED_DURABLY -> HANDED_TO_RELAY -> ACKNOWLEDGED_BY_RECIPIENT
//                                       \-> EXPIRED | CANCELLED_LOCALLY
//
// A successful GATT write is only HANDED_TO_RELAY. ACKNOWLEDGED_BY_RECIPIENT is
// forbidden unless an AUTHENTICATED intended recipient ACKs the EXACT message
// id (see AckAuthenticator), AND the message was enqueued with AckMode
// SINGLE_RECIPIENT -- a broadcast (AckMode.NONE) can NEVER be acknowledged via
// this path (no recipient is bound, so no recipient identity may become trusted
// merely because an ACK packet names it). Cancellation cannot recall already
// relayed copies and the state says so. The machine is pure (no Context / no
// disk) with the journal + authenticator injected, so it is host-testable
// without a device or radio. The radio/link layer remains disabled (M2-link),
// so this is repo-owned evidence for the state machine + authenticated-ACK
// verification, not an on-device delivery proof.

/**
 * Delivery lifecycle (ADR-005). Terminal states are ACKNOWLEDGED_BY_RECIPIENT,
 * EXPIRED and CANCELLED_LOCALLY.
 *
 * [code] / [fromCode] are the cross-platform persistence contract (NOT the
 * Kotlin enum ordinal), so Android and iOS agree even if their enum orders ever
 * diverge. [fromCode] returns null for an unknown code -- an unknown persisted
 * state fails closed (C6.5) rather than silently mapping to UNAVAILABLE.
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
 */
data class DeliveryRecord(
    val msgId: ByteArray,
    val state: DeliveryState,
    val ackMode: AckMode,
    val expectedRecipientNodeId: ByteArray?,
) {
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
 * treated as a valid UNAVAILABLE state (C6.5).
 */
sealed interface DeliveryLookup {
    /** A row was found and decoded into a consistent [DeliveryRecord]. */
    data class Found(val record: DeliveryRecord) : DeliveryLookup
    /** No row exists for the msg_id (never tracked, or forgotten). */
    data object NotFound : DeliveryLookup
    /** A row exists but its state / ack_mode / recipient binding is unknown or
     *  inconsistent (fails the schema CHECK or the code tables). Fail closed. */
    data object Corrupt : DeliveryLookup
    /** The underlying store failed to read (IO / SQL error). */
    data object StorageFailure : DeliveryLookup
}

/**
 * Outcome of [DeliveryTracker.enqueue]. Sealed (C6.2): a delivery-security
 * outcome is never a Bool the caller can misread as "ok".
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
    /** The underlying store failed to write. */
    data object StorageFailure : EnqueueResult
    /** The store returned a corrupt / inconsistent record. */
    data object Corrupt : EnqueueResult
}

/**
 * Outcome of [DeliveryTracker.acknowledge]. Sealed (C6.2): the caller must
 * branch on the outcome and can NEVER translate [AlreadyAcknowledged] or
 * [DuplicateAuthenticatedAck] into "this ACK was newly verified" -- they mean
 * the message was already in a terminal acknowledged state, NOT that this
 * packet authenticated (option B: a terminal record short-circuits BEFORE the
 * authenticator is invoked, bounding CPU under a flood of replayed ACKs).
 */
sealed interface AckResult {
    /** The ACK authenticated for the bound recipient and the state advanced to
     *  ACKNOWLEDGED_BY_RECIPIENT. This is the ONLY outcome that means "verified". */
    data object Applied : AckResult
    /** The ACK authenticated, but the message was already acknowledged by a
     *  prior authenticated ACK. Not a new verification. */
    data object DuplicateAuthenticatedAck : AckResult
    /** The record is already ACKNOWLEDGED; this ACK was NOT authenticated
     *  (short-circuit, option B). Not "verified". */
    data object AlreadyAcknowledged : AckResult
    /** The message is AckMode.NONE -- broadcasts are not ACK-eligible. The
     *  authenticator was NOT invoked; the state is unchanged. (C6.1 invariant.) */
    data object NotAckEligible : AckResult
    /** No delivery record exists for the msg_id. */
    data object UnknownMessage : AckResult
    /** The ACK was reached but failed authentication (wrong recipient / wrong
     *  msg id / tampered / unsigned / unresolved key). State unchanged. */
    data object RejectedAuthentication : AckResult
    /** The record is in a non-ackable state (EXPIRED / CANCELLED). State unchanged. */
    data object RejectedState : AckResult
    /** The underlying store failed to write. */
    data object StorageFailure : AckResult
    /** The store returned a corrupt / inconsistent record. */
    data object Corrupt : AckResult
}

/**
 * Crash-safe persisted delivery state per message id. Implementations must
 * persist across a reboot/jetsam so a fresh [DeliveryTracker] over the same
 * journal recovers the record (reboot recovery, ADR-005 exit criteria). The
 * state, ack mode and expected recipient live in ONE logical row keyed by
 * msg_id; the expected recipient is IMMUTABLE post-creation (C6.1/C6.3).
 *
 * Each mutation is a single atomic SQL statement (see StoreSchema): [insert]
 * creates the row (ON CONFLICT DO NOTHING -- the caller detects a conflict by
 * re-reading), [updateState] advances only the state column (preserving ack_mode
 * + expected_recipient), [clear] drops the row. No read-modify-write seam, so a
 * crash between operations leaves the LAST persisted state on disk -- the
 * crash-safe semantics ADR-005 requires. (CAS-hardened transitions arrive in
 * C6.4; this commit establishes the typed, fail-closed semantics.)
 */
interface DeliveryJournal {
    /** Read the delivery record for `msgId`, or [DeliveryLookup.NotFound]. */
    fun read(msgId: ByteArray): DeliveryLookup

    /**
     * Atomically create a delivery record in QUEUED_DURABLY with [ackMode] and
     * [expectedRecipient] (null for AckMode.NONE, 16 bytes for SINGLE_RECIPIENT).
     * Returns true iff a NEW row was inserted; false if a row already exists for
     * `msgId` (the caller re-reads to classify the conflict). The expected
     * recipient is NEVER updated on an existing row (historical send intent).
     */
    fun insert(msgId: ByteArray, ackMode: AckMode, expectedRecipient: ByteArray?): Boolean

    /**
     * Advance only the state column for `msgId`, preserving ack_mode and
     * expected_recipient. Returns the row count (1 if a row existed and was
     * updated, 0 otherwise).
     */
    fun updateState(msgId: ByteArray, state: DeliveryState): Int

    /** Drop the delivery row for `msgId`. */
    fun clear(msgId: ByteArray)
}

/**
 * Verifies that an inbound ACK frame is an authentic acknowledgment of
 * [originalMsgId] by the intended recipient [expectedRecipientNodeId]. The
 * expected recipient is NON-NULL: it always comes from durable outbound state
 * (the delivery record bound at enqueue), INDEPENDENT of the ACK frame. A return
 * of false means the ACK is rejected and the delivery state MUST NOT advance --
 * no UI phrase stronger than the cryptographic evidence is permitted (ADR-005).
 *
 * C6.1: the nullable / unbound verify path is removed. A recipient identity may
 * NEVER become trusted merely because the ACK packet names it; the authenticator
 * is only ever invoked for an AckMode.SINGLE_RECIPIENT record, with the expected
 * recipient read from durable state.
 */
interface AckAuthenticator {
    fun verify(
        originalMsgId: ByteArray,
        expectedRecipientNodeId: ByteArray,
        ackFrame: FrameV2,
    ): Boolean
}

/**
 * Durable delivery state machine. Every successful transition is persisted to
 * [journal] AFTER it is applied, so a crash-then-resume re-reads the last
 * persisted state. Transitions that are illegal for the current state (or an
 * ACK that fails authentication) do not mutate state -- the truth-table is
 * enforced, not advisory.
 */
class DeliveryTracker(
    private val journal: DeliveryJournal,
    private val authenticator: AckAuthenticator,
) {
    /** Current persisted state for `msgId` (UNAVAILABLE if never tracked / corrupt). */
    fun state(msgId: ByteArray): DeliveryState = when (val l = journal.read(msgId)) {
        is DeliveryLookup.Found -> l.record.state
        DeliveryLookup.NotFound, DeliveryLookup.Corrupt, DeliveryLookup.StorageFailure ->
            DeliveryState.UNAVAILABLE
    }

    /**
     * Begin tracking a message: UNAVAILABLE -> QUEUED_DURABLY with [ackMode] and
     * (for SINGLE_RECIPIENT) the durably-bound intended recipient. The binding
     * (ack mode + recipient) is IMMUTABLE post-creation: a re-enqueue of the
     * SAME logical message (same msg_id, same binding) is idempotent
     * ([EnqueueResult.AlreadyQueuedSameBinding]); a re-enqueue with a DIFFERENT
     * binding fails closed ([EnqueueResult.ConflictRecipient]) -- the historical
     * send intent is never overwritten. A terminal record rejects re-enqueue.
     *
     * C6.1: AckMode.NONE binds no recipient (broadcast SOS / group). The ack
     * mode + recipient are validated against the C6.1 invariant (NONE -> null;
     * SINGLE_RECIPIENT -> 16-byte recipient) before the journal is touched.
     */
    fun enqueue(
        msgId: ByteArray,
        ackMode: AckMode,
        expectedRecipient: ByteArray? = null,
    ): EnqueueResult {
        // C6.1 invariant: NONE -> no recipient; SINGLE_RECIPIENT -> 16-byte recipient.
        if (!bindingConsistent(ackMode, expectedRecipient)) return EnqueueResult.Corrupt
        return when (val l = journal.read(msgId)) {
            DeliveryLookup.NotFound -> {
                if (journal.insert(msgId, ackMode, expectedRecipient)) EnqueueResult.Created
                else classifyExisting(msgId, ackMode, expectedRecipient) // row appeared mid-call
            }
            is DeliveryLookup.Found -> classifyExisting(l.record, ackMode, expectedRecipient)
            DeliveryLookup.Corrupt -> EnqueueResult.Corrupt
            DeliveryLookup.StorageFailure -> EnqueueResult.StorageFailure
        }
    }

    private fun classifyExisting(
        msgId: ByteArray,
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): EnqueueResult = when (val l = journal.read(msgId)) {
        is DeliveryLookup.Found -> classifyExisting(l.record, ackMode, expectedRecipient)
        DeliveryLookup.NotFound -> EnqueueResult.StorageFailure // row vanished -- storage anomaly
        DeliveryLookup.Corrupt -> EnqueueResult.Corrupt
        DeliveryLookup.StorageFailure -> EnqueueResult.StorageFailure
    }

    private fun classifyExisting(
        rec: DeliveryRecord,
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): EnqueueResult {
        if (rec.state.isTerminal) return EnqueueResult.RejectedTerminalState
        // Non-terminal (QUEUED / HANDED): same binding -> idempotent; else conflict.
        return if (rec.ackMode == ackMode &&
            rec.expectedRecipientNodeId.contentEquals(expectedRecipient)
        ) EnqueueResult.AlreadyQueuedSameBinding
        else EnqueueResult.ConflictRecipient
    }

    /**
     * Record that the frame was handed to a relay (a successful GATT write).
     * QUEUED_DURABLY -> HANDED_TO_RELAY. Idempotent from HANDED_TO_RELAY.
     * Returns false from any other state (this is NOT "sent" -- only
     * [acknowledge] can reach ACKNOWLEDGED_BY_RECIPIENT).
     */
    fun markHandedToRelay(msgId: ByteArray): Boolean {
        return when (val l = journal.read(msgId)) {
            is DeliveryLookup.Found -> when (l.record.state) {
                DeliveryState.HANDED_TO_RELAY -> true
                DeliveryState.QUEUED_DURABLY -> journal.updateState(msgId, DeliveryState.HANDED_TO_RELAY) == 1
                else -> false
            }
            else -> false
        }
    }

    /**
     * Apply an authenticated recipient ACK (C6.1). The outcome is typed
     * ([AckResult]); only [AckResult.Applied] means "this ACK verified and the
     * state advanced". A NONE-mode message is [NotAckEligible] and the
     * authenticator is NOT invoked. A terminal acknowledged record short-
     * circuits to [AlreadyAcknowledged] WITHOUT authenticating (option B: bound
     * CPU under replayed ACK floods; NOT a verification). EXPIRED / CANCELLED
     * records are [RejectedState]. A SINGLE_RECIPIENT record authenticates the
     * ACK against the durable expected recipient; failure is
     * [RejectedAuthentication] and the state is unchanged.
     */
    fun acknowledge(msgId: ByteArray, ackFrame: FrameV2): AckResult {
        return when (val l = journal.read(msgId)) {
            DeliveryLookup.NotFound -> AckResult.UnknownMessage
            DeliveryLookup.Corrupt -> AckResult.Corrupt
            DeliveryLookup.StorageFailure -> AckResult.StorageFailure
            is DeliveryLookup.Found -> {
                val rec = l.record
                if (rec.state == DeliveryState.ACKNOWLEDGED_BY_RECIPIENT) {
                    return AckResult.AlreadyAcknowledged // option B: short-circuit, no auth
                }
                if (rec.state.isTerminal) return AckResult.RejectedState // EXPIRED / CANCELLED
                if (rec.state != DeliveryState.QUEUED_DURABLY &&
                    rec.state != DeliveryState.HANDED_TO_RELAY
                ) return AckResult.RejectedState // UNAVAILABLE / anomalous non-terminal
                if (rec.ackMode == AckMode.NONE) return AckResult.NotAckEligible // authenticator NOT invoked
                // SINGLE_RECIPIENT: expected recipient is non-null by the schema CHECK.
                val expected = rec.expectedRecipientNodeId
                    ?: return AckResult.Corrupt // invariant violation (CHECK should prevent)
                if (!authenticator.verify(msgId, expected, ackFrame)) {
                    return AckResult.RejectedAuthentication
                }
                if (journal.updateState(msgId, DeliveryState.ACKNOWLEDGED_BY_RECIPIENT) == 1) {
                    AckResult.Applied
                } else {
                    AckResult.UnknownMessage // row vanished mid-call (raced expire/cancel/forget)
                }
            }
        }
    }

    /** TTL expiry: QUEUED_DURABLY or HANDED_TO_RELAY -> EXPIRED. Terminal/idempotent. */
    fun expire(msgId: ByteArray): Boolean {
        return when (val l = journal.read(msgId)) {
            is DeliveryLookup.Found -> when (l.record.state) {
                DeliveryState.EXPIRED -> true
                DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY ->
                    journal.updateState(msgId, DeliveryState.EXPIRED) == 1
                else -> false
            }
            else -> false
        }
    }

    /**
     * Local cancellation: QUEUED_DURABLY or HANDED_TO_RELAY -> CANCELLED_LOCALLY.
     * Terminal/idempotent. Cancellation cannot recall already relayed copies --
     * the caller gives the truthful UI; the state machine records the intent.
     */
    fun cancel(msgId: ByteArray): Boolean {
        return when (val l = journal.read(msgId)) {
            is DeliveryLookup.Found -> when (l.record.state) {
                DeliveryState.CANCELLED_LOCALLY -> true
                DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY ->
                    journal.updateState(msgId, DeliveryState.CANCELLED_LOCALLY) == 1
                else -> false
            }
            else -> false
        }
    }

    /** Drop tracking for `msgId` (e.g. after it ages out of the store). */
    fun forget(msgId: ByteArray) = journal.clear(msgId)

    /** C6.1 invariant: NONE -> null recipient; SINGLE_RECIPIENT -> 16-byte recipient. */
    private fun bindingConsistent(ackMode: AckMode, expectedRecipient: ByteArray?): Boolean =
        when (ackMode) {
            AckMode.NONE -> expectedRecipient == null
            AckMode.SINGLE_RECIPIENT -> expectedRecipient != null && expectedRecipient.size == 16
        }
}