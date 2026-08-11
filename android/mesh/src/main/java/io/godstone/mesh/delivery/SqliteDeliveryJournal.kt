package io.godstone.mesh.delivery

import io.godstone.mesh.store.StoreDb

// Stage 4C.1 / C6.1 -- production [DeliveryJournal] backed by the SAME SQLite DB
// as the held-frames store. The delivery lifecycle state, the ACK mode, and the
// intended recipient live in ONE row keyed by msg_id, so the ACK authenticity
// decision (C2) binds to the recipient recorded in durable outbound state
// INDEPENDENT of the ACK frame (ADR-005: do not claim an ACK is from the
// intended recipient unless the expected recipient comes from durable outbound
// state).
//
// Each mutation is a single atomic SQL statement (see StoreSchema): [insert]
// creates the row (INSERT ... ON CONFLICT DO NOTHING), [updateState] advances
// only the state column (UPDATE SET state WHERE msg_id, preserving ack_mode +
// expected_recipient), [clear] drops the row. The expected recipient is IMMUTABLE
// post-creation -- there is no recipient-only write. A crash between
// DeliveryTracker's read and write leaves the LAST persisted state on disk (the
// write did not commit), which is the crash-safe semantics ADR-005 requires.
// (CAS-hardened transitions arrive in C6.4.)
//
// The int state / ack_mode codes are the cross-platform persistence contract
// (NOT the Kotlin enum ordinals), so Android and iOS agree even if their enum
// orders ever diverge. An unknown state or ack_mode code, or a row that
// violates the C6.1 binding invariant, decodes to [DeliveryLookup.Corrupt] --
// fail closed (C6.5), never silently to UNAVAILABLE. Mirrors
// `SqliteDeliveryJournal` on iOS (byte-identical schema + SQL + codes).
internal class SqliteDeliveryJournal(private val db: StoreDb) : DeliveryJournal {

    override fun read(msgId: ByteArray): DeliveryLookup {
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

    override fun insert(msgId: ByteArray, ackMode: AckMode, expectedRecipient: ByteArray?): Boolean =
        db.insertDelivery(msgId, DeliveryState.QUEUED_DURABLY.code, ackMode.code, expectedRecipient)

    override fun updateState(msgId: ByteArray, state: DeliveryState): Int =
        db.updateDeliveryState(msgId, state.code)

    override fun clear(msgId: ByteArray) {
        db.clearDelivery(msgId)
    }

    private fun bindingConsistent(ackMode: AckMode, expectedRecipient: ByteArray?): Boolean =
        when (ackMode) {
            AckMode.NONE -> expectedRecipient == null
            AckMode.SINGLE_RECIPIENT -> expectedRecipient != null && expectedRecipient.size == 16
        }
}