package io.godstone.mesh.delivery

import io.godstone.mesh.store.StoreDb

// Stage 4C.1 / C6.3 -- production [DeliveryRepository] backed by the SAME SQLite
// DB as the held-frames store. Folds the C6.1 `DeliveryJournal` plus the
// enqueue / transition / retire classification into ONE atomic aggregate over
// the `delivery_state` row keyed by msg_id, so the ACK authenticity decision
// (C2) binds to the recipient recorded in durable outbound state INDEPENDENT of
// the ACK frame (ADR-005: do not claim an ACK is from the intended recipient
// unless the expected recipient comes from durable outbound state).
//
// Each mutation is a single atomic SQL statement (see StoreSchema): [enqueue]
// creates the row (INSERT ... ON CONFLICT DO NOTHING -- a conflict is classified
// by re-reading), [compareAndSet] / [acknowledgeAndRetire] advance only the
// state column (UPDATE SET state WHERE msg_id, preserving ack_mode +
// expected_recipient), [clear] drops the row. The expected recipient is IMMUTABLE
// post-creation -- there is no recipient-only write. A crash between the
// repository's read and write leaves the LAST persisted state on disk (the
// write did not commit), which is the crash-safe semantics ADR-005 requires.
// (CAS-hardened WHERE-clause transitions arrive in C6.4.)
//
// The int state / ack_mode codes are the cross-platform persistence contract
// (NOT the Kotlin enum ordinals), so Android and iOS agree even if their enum
// orders ever diverge. An unknown state or ack_mode code, or a row that
// violates the C6.1 binding invariant, decodes to [DeliveryLookup.Corrupt] --
// fail closed (C6.5), never silently to UNAVAILABLE. Mirrors
// `SqliteDeliveryRepository` on iOS (byte-identical schema + SQL + codes).
internal class SqliteDeliveryRepository(private val db: StoreDb) : DeliveryRepository {

    override fun get(msgId: ByteArray): DeliveryLookup {
        val row = db.readDelivery(msgId) ?: return DeliveryLookup.NotFound
        val state = DeliveryState.fromCode(row.state) ?: return DeliveryLookup.Corrupt
        val ackMode = AckMode.fromCode(row.ackMode) ?: return DeliveryLookup.Corrupt
        // C6.1 binding invariant (mirrors the schema CHECK): NONE -> null
        // recipient; SINGLE_RECIPIENT -> 16-byte recipient. A row that violates
        // it (e.g. manually mutated) is corrupt -- fail closed.
        if (!bindingConsistent(ackMode, row.expectedRecipient)) return DeliveryLookup.Corrupt
        return DeliveryLookup.Found(
            DeliveryRecord(msgId, state, ackMode, row.expectedRecipient),
        )
    }

    override fun enqueue(
        msgId: ByteArray,
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): EnqueueResult {
        // C6.1 invariant: NONE -> no recipient; SINGLE_RECIPIENT -> 16-byte recipient.
        if (!bindingConsistent(ackMode, expectedRecipient)) return EnqueueResult.Corrupt
        return when (val l = get(msgId)) {
            DeliveryLookup.NotFound -> {
                if (db.insertDelivery(msgId, DeliveryState.QUEUED_DURABLY.code, ackMode.code, expectedRecipient)) {
                    EnqueueResult.Created
                } else {
                    classifyExisting(msgId, ackMode, expectedRecipient) // row appeared mid-call
                }
            }
            is DeliveryLookup.Found -> classifyExisting(l.record, ackMode, expectedRecipient)
            DeliveryLookup.Corrupt -> EnqueueResult.Corrupt
            DeliveryLookup.StorageFailure -> EnqueueResult.StorageFailure
        }
    }

    override fun compareAndSet(
        msgId: ByteArray,
        validFroms: Set<DeliveryState>,
        target: DeliveryState,
    ): TransitionResult = when (val l = get(msgId)) {
        DeliveryLookup.NotFound -> TransitionResult.UnknownMessage
        DeliveryLookup.Corrupt -> TransitionResult.Corrupt
        DeliveryLookup.StorageFailure -> TransitionResult.StorageFailure
        is DeliveryLookup.Found -> {
            val s = l.record.state
            when {
                s == target -> TransitionResult.AlreadyInTarget
                s in validFroms ->
                    if (db.updateDeliveryState(msgId, target.code) == 1) TransitionResult.Applied
                    else TransitionResult.UnknownMessage // row vanished mid-call
                else -> TransitionResult.RejectedState
            }
        }
    }

    override fun acknowledgeAndRetire(
        msgId: ByteArray,
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): AckResult = when (val l = get(msgId)) {
        DeliveryLookup.NotFound -> AckResult.UnknownMessage
        DeliveryLookup.Corrupt -> AckResult.Corrupt
        DeliveryLookup.StorageFailure -> AckResult.StorageFailure
        is DeliveryLookup.Found -> {
            val rec = l.record
            // The durable binding (ack mode + expected recipient) MUST still match
            // the values the tracker authenticated against -- the recipient identity
            // comes from durable outbound state, INDEPENDENT of the ACK frame. A
            // mismatch means the row is not the message the tracker verified.
            if (rec.ackMode != ackMode ||
                !rec.expectedRecipientNodeId.contentEquals(expectedRecipient)
            ) return AckResult.UnknownMessage
            if (db.updateDeliveryState(msgId, DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code) == 1) {
                AckResult.Applied
            } else {
                AckResult.UnknownMessage // row vanished mid-call (raced expire/cancel/forget)
            }
        }
    }

    override fun clear(msgId: ByteArray) {
        db.clearDelivery(msgId)
    }

    private fun classifyExisting(
        msgId: ByteArray,
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): EnqueueResult = when (val l = get(msgId)) {
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

    /** C6.1 invariant: NONE -> null recipient; SINGLE_RECIPIENT -> 16-byte recipient. */
    private fun bindingConsistent(ackMode: AckMode, expectedRecipient: ByteArray?): Boolean =
        when (ackMode) {
            AckMode.NONE -> expectedRecipient == null
            AckMode.SINGLE_RECIPIENT -> expectedRecipient != null && expectedRecipient.size == 16
        }
}