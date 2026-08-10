package io.godstone.mesh.delivery

import io.godstone.mesh.store.StoreDb

// Stage 4C / C4 -- production [DeliveryJournal] + [ExpectedRecipientStore] backed
// by the SAME SQLite DB as the held-frames store (not a separate Properties file
// like [FileDeliveryJournal]). The delivery lifecycle state AND the intended
// recipient live in ONE row keyed by msg_id, so the ACK authenticity decision
// (C2) binds to the recipient recorded in durable outbound state INDEPENDENT of
// the ACK frame (ADR-005: do not claim an ACK is from the intended recipient
// unless the expected recipient comes from durable outbound state).
//
// Each operation is a single atomic SQL statement (see StoreSchema): a
// state-only write preserves any bound expected recipient via a subquery, and a
// recipient-only write preserves the current state via COALESCE -- so the
// non-recursive connection lock is acquired once per call and no transaction
// seam is needed. A crash between DeliveryTracker's read and write leaves the
// LAST persisted state on disk (the write did not commit), which is the
// crash-safe semantics ADR-005 requires.
//
// The int state code is the cross-platform persistence contract (NOT the Kotlin
// enum ordinal), so Android and iOS agree even if their enum orders ever differ.
// Mirrors `SqliteDeliveryJournal` on iOS (byte-identical schema + SQL + codes).
internal class SqliteDeliveryJournal(private val db: StoreDb) : DeliveryJournal, ExpectedRecipientStore {

    override fun read(msgId: ByteArray): DeliveryState {
        val row = db.readDelivery(msgId) ?: return DeliveryState.UNAVAILABLE
        return fromCode(row.first)
    }

    override fun write(msgId: ByteArray, state: DeliveryState) {
        db.upsertDeliveryState(msgId, code(state))
    }

    override fun clear(msgId: ByteArray) {
        db.clearDelivery(msgId)
    }

    override fun expectedRecipient(msgId: ByteArray): ByteArray? =
        db.readDelivery(msgId)?.second

    override fun recordExpectedRecipient(msgId: ByteArray, recipient: ByteArray?) {
        db.upsertDeliveryRecipient(msgId, recipient)
    }

    /**
     * Stable int persistence code -- the cross-platform contract (mirrors iOS).
     * UNAVAILABLE=0, QUEUED_DURABLY=1, HANDED_TO_RELAY=2,
     * ACKNOWLEDGED_BY_RECIPIENT=3, EXPIRED=4, CANCELLED_LOCALLY=5.
     */
    private fun code(s: DeliveryState): Int = when (s) {
        DeliveryState.UNAVAILABLE -> 0
        DeliveryState.QUEUED_DURABLY -> 1
        DeliveryState.HANDED_TO_RELAY -> 2
        DeliveryState.ACKNOWLEDGED_BY_RECIPIENT -> 3
        DeliveryState.EXPIRED -> 4
        DeliveryState.CANCELLED_LOCALLY -> 5
    }

    private fun fromCode(c: Int): DeliveryState = when (c) {
        0 -> DeliveryState.UNAVAILABLE
        1 -> DeliveryState.QUEUED_DURABLY
        2 -> DeliveryState.HANDED_TO_RELAY
        3 -> DeliveryState.ACKNOWLEDGED_BY_RECIPIENT
        4 -> DeliveryState.EXPIRED
        5 -> DeliveryState.CANCELLED_LOCALLY
        else -> DeliveryState.UNAVAILABLE   // forward-compat: unknown code -> unavailable
    }
}