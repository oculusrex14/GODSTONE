package io.godstone.mesh.wire

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * GMP/1 frame. See docs/mesh/PROTOCOL.md section 5.
 *
 * Layout (big-endian):
 *   0   1   version
 *   1   1   type
 *   2   2   length
 *   4   1   ttl
 *   5   1   priority
 *   6   8   msg_id
 *   14  6   timestamp
 *   20  N   payload
 */
data class Frame(
    val version: Byte = PROTOCOL_VERSION,
    val type: FrameType,
    val ttl: Int,
    val priority: Priority,
    val msgId: Long,
    val timestamp: Long,
    val payload: ByteArray
) {

    fun encode(): ByteArray {
        require(payload.size <= MAX_PAYLOAD) { "payload too large: ${payload.size}" }
        val buf = ByteBuffer.allocate(HEADER_SIZE + payload.size)
            .order(ByteOrder.BIG_ENDIAN)
        buf.put(version)
        buf.put(type.code)
        buf.putShort(payload.size.toShort())
        buf.put(ttl.coerceIn(0, MAX_TTL).toByte())
        buf.put(priority.code)
        buf.putLong(msgId)
        // 6-byte timestamp: build 8 bytes then keep the low 6.
        val ts = ByteBuffer.allocate(8).order(ByteOrder.BIG_ENDIAN)
            .putLong(timestamp).array()
        buf.put(ts, 2, 6)
        buf.put(payload)
        return buf.array()
    }

    companion object {
        const val PROTOCOL_VERSION: Byte = 0x01
        const val HEADER_SIZE = 20
        const val MAX_PAYLOAD = 65535
        const val MAX_TTL = 16
        const val DEFAULT_TTL = 12

        /**
         * Bounded parsing, protocol section 8. Every length field is validated
         * against the actual remaining buffer BEFORE any allocation, so an
         * attacker-supplied length can never drive memory allocation.
         */
        fun decode(raw: ByteArray): Frame? {
            if (raw.size < HEADER_SIZE) return null

            val buf = ByteBuffer.wrap(raw).order(ByteOrder.BIG_ENDIAN)

            val version = buf.get()
            if (version != PROTOCOL_VERSION) return null   // refuse, never guess

            val type = FrameType.from(buf.get()) ?: return null
            val length = buf.getShort().toInt() and 0xFFFF

            // Critical bound check.
            if (length != raw.size - HEADER_SIZE) return null
            if (length > MAX_PAYLOAD) return null

            val ttl = buf.get().toInt() and 0xFF
            if (ttl > MAX_TTL) return null

            val priority = Priority.from(buf.get()) ?: return null
            val msgId = buf.getLong()

            val tsBytes = ByteArray(8)
            buf.get(tsBytes, 2, 6)
            val timestamp = ByteBuffer.wrap(tsBytes).order(ByteOrder.BIG_ENDIAN).getLong()

            val payload = ByteArray(length)
            buf.get(payload)

            return Frame(version, type, ttl, priority, msgId, timestamp, payload)
        }
    }

    override fun equals(other: Any?): Boolean =
        other is Frame && other.msgId == msgId

    override fun hashCode(): Int = msgId.hashCode()
}

enum class FrameType(val code: Byte) {
    HELLO(0x01),
    DIGEST(0x02),
    WANT(0x03),
    MESSAGE(0x04),
    ACK(0x05),
    BULK_OFFER(0x06),
    BULK_CHUNK(0x07),
    SOS(0x08),
    PING(0x09),
    GOODBYE(0x0A);

    companion object {
        private val map = entries.associateBy { it.code }
        fun from(b: Byte): FrameType? = map[b]
    }
}

enum class Priority(val code: Byte) {
    SOS(0),
    DIRECT(1),
    GROUP(2),
    BROADCAST(3),
    BULK(4);

    /** SOS and DIRECT are exempt from proof of work: latency there is safety. */
    val requiresProofOfWork: Boolean get() = this == GROUP || this == BROADCAST

    companion object {
        private val map = entries.associateBy { it.code }
        fun from(b: Byte): Priority? = map[b]
    }
}
