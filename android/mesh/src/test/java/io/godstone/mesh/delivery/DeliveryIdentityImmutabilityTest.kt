package io.godstone.mesh.delivery

import io.godstone.mesh.store.DeliveryRow
import org.junit.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/**
 * C6.4.1-J: Kotlin `ByteArray` is reference-mutable, so a delivery ID exposed as
 * a plain `val ByteArray` is mutable by any caller that retains the reference --
 * `assertEquals(array, array)` is REFERENCE equality, masking the aliasing. These
 * tests prove the production delivery records are ACTUALLY immutable on BOTH
 * sides: (1) mutating the array passed to the constructor AFTER construction does
 * not change the record, and (2) mutating an EXPORTED id does not change the
 * record's internal storage. iOS `Data` is a value type, so no iOS twin is needed.
 *
 * The mechanism is a private backing field (defensive copy on construction) plus a
 * computed getter that returns a fresh copy on every read -- see [DeliveryRecord]
 * / [DeliveryRow].
 */
class DeliveryIdentityImmutabilityTest {

    private fun msgId(seed: Byte) = ByteArray(16) { (it + seed).toByte() }
    private fun recipient(seed: Byte) = ByteArray(16) { (it + seed).toByte() }

    @Test
    fun `DeliveryRecord msgId is isolated from constructor-input mutation`() {
        val input = msgId(1)
        val rec = DeliveryRecord(input, DeliveryState.QUEUED_DURABLY, AckMode.SINGLE_RECIPIENT, null)
        // mutate the array handed to the constructor AFTER construction
        input[0] = 0x7F
        assertNotEquals(0x7F.toByte(), rec.msgId[0],
            "mutating the constructor-input msg_id must not reach the record")
        assertEquals(msgId(1)[0], rec.msgId[0])
    }

    @Test
    fun `DeliveryRecord expectedRecipientNodeId is isolated from constructor-input mutation`() {
        val input = recipient(2)
        val rec = DeliveryRecord(msgId(3), DeliveryState.QUEUED_DURABLY, AckMode.SINGLE_RECIPIENT, input)
        input[0] = 0x7F
        assertNotEquals(0x7F.toByte(), rec.expectedRecipientNodeId!![0],
            "mutating the constructor-input recipient must not reach the record")
        assertEquals(recipient(2)[0], rec.expectedRecipientNodeId!![0])
    }

    @Test
    fun `DeliveryRecord exported msgId is a fresh copy that cannot reach internal storage`() {
        val rec = DeliveryRecord(msgId(4), DeliveryState.QUEUED_DURABLY, AckMode.SINGLE_RECIPIENT, null)
        val exported = rec.msgId
        exported[0] = 0x7F
        assertNotEquals(0x7F.toByte(), rec.msgId[0],
            "mutating an exported msg_id must not reach the record")
        // every read returns a NEW instance (copy-on-read), so aliasing is impossible
        assertTrue(rec.msgId !== rec.msgId, "exported msg_id must be a fresh copy on every read")
    }

    @Test
    fun `DeliveryRecord exported expectedRecipientNodeId is a fresh copy that cannot reach internal storage`() {
        val rec = DeliveryRecord(msgId(5), DeliveryState.QUEUED_DURABLY, AckMode.SINGLE_RECIPIENT, recipient(6))
        val exported = rec.expectedRecipientNodeId!!
        exported[0] = 0x7F
        assertNotEquals(0x7F.toByte(), rec.expectedRecipientNodeId!![0],
            "mutating an exported recipient must not reach the record")
        assertTrue(rec.expectedRecipientNodeId !== rec.expectedRecipientNodeId,
            "exported recipient must be a fresh copy on every read")
    }

    @Test
    fun `DeliveryRecord copy preserves the immutability contract`() {
        val rec = DeliveryRecord(msgId(7), DeliveryState.QUEUED_DURABLY, AckMode.SINGLE_RECIPIENT, recipient(8))
        val copied = rec.copy(state = DeliveryState.HANDED_TO_RELAY)
        // mutate the source record's exported ids -- the copy must be unaffected
        rec.msgId[0] = 0x7F
        rec.expectedRecipientNodeId!![0] = 0x7F
        assertEquals(msgId(7)[0], copied.msgId[0], "copy must hold an independent msg_id")
        assertEquals(recipient(8)[0], copied.expectedRecipientNodeId!![0], "copy must hold an independent recipient")
        // and mutating the copy's exported ids must not reach the copy itself
        copied.msgId[0] = 0x7F
        assertNotEquals(0x7F.toByte(), copied.msgId[0], "copy's exported msg_id must be a fresh copy")
    }

    @Test
    fun `DeliveryRow expectedRecipient is isolated from constructor-input mutation`() {
        val input = recipient(9)
        val row = DeliveryRow(DeliveryState.QUEUED_DURABLY.code, AckMode.SINGLE_RECIPIENT.code, input)
        input[0] = 0x7F
        assertNotEquals(0x7F.toByte(), row.expectedRecipient!![0],
            "mutating the constructor-input recipient must not reach the row")
        assertEquals(recipient(9)[0], row.expectedRecipient!![0])
    }

    @Test
    fun `DeliveryRow exported expectedRecipient is a fresh copy that cannot reach internal storage`() {
        val row = DeliveryRow(DeliveryState.QUEUED_DURABLY.code, AckMode.SINGLE_RECIPIENT.code, recipient(10))
        val exported = row.expectedRecipient!!
        exported[0] = 0x7F
        assertNotEquals(0x7F.toByte(), row.expectedRecipient!![0],
            "mutating an exported recipient must not reach the row")
        assertTrue(row.expectedRecipient !== row.expectedRecipient,
            "exported recipient must be a fresh copy on every read")
    }

    @Test
    fun `DeliveryRow with a null expectedRecipient stays null and is stable`() {
        val row = DeliveryRow(DeliveryState.QUEUED_DURABLY.code, AckMode.NONE.code, null)
        assertEquals(null, row.expectedRecipient, "a null recipient stays null across reads")
    }
}