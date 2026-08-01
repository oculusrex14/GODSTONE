// GENERATED FROM wire/wire_v2.yaml -- DO NOT EDIT BY HAND.
// Regenerate with `python -m wire.codegen`.
// ci/check_parity.py Invariant A fails the build on any hand edit.
package io.godstone.mesh.wire.v2

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** GMP/2 frame. Header is 32 bytes, big-endian. */
data class FrameV2(
    val type: TypeV2,
    val msgId: ByteArray,        // 16 bytes
    val routingTag: ByteArray,   // 4 bytes
    val ttl: Int,
    val hopCount: Int,
    val flags: Int,
    val payload: ByteArray
) {
    fun encode(): ByteArray {
        require(msgId.size == 16) { "msg_id must be 16 bytes" }
        require(routingTag.size == 4) { "routing_tag must be 4 bytes" }
        require(ttl in 0..MAX_TTL) { "ttl out of range" }
        require(hopCount in 0..MAX_TTL) { "hop_count out of range" }
        require(payload.size <= MAX_PAYLOAD) { "payload too large" }
        val buf = ByteBuffer.allocate(HEADER_SIZE + payload.size).order(ByteOrder.BIG_ENDIAN)
        buf.putShort(MAGIC.toShort())
        buf.put(VERSION)
        buf.put(type.code)
        buf.put(msgId)
        buf.put(routingTag)
        buf.put(ttl.toByte())
        buf.put(hopCount.toByte())
        buf.putShort(flags.toShort())
        buf.putShort(payload.size.toShort())
        val header = buf.array()
        buf.putShort(crc16(header, 0, HEADER_SIZE - 2).toShort())
        buf.put(payload)
        return buf.array()
    }

    companion object {
        const val MAGIC = 0x4753
        const val VERSION: Byte = 0x02
        const val HEADER_SIZE = 32
        const val MAX_PAYLOAD = 60000
        const val MAX_TTL = 16
        const val DEFAULT_TTL = 12

        /** Shared BLE identifiers. Both platforms MUST use these exact values. */
        val SERVICE_UUID: java.util.UUID = java.util.UUID.fromString("6764A001-9A5E-4C7B-B0A1-3E5D8C2F7A10")
        val INBOX_UUID: java.util.UUID = java.util.UUID.fromString("6764A002-9A5E-4C7B-B0A1-3E5D8C2F7A10")
        val DIGEST_UUID: java.util.UUID = java.util.UUID.fromString("6764A003-9A5E-4C7B-B0A1-3E5D8C2F7A10")

        const val SEALED = 0x0001
        const val COMPRESSED = 0x0002
        const val FRAGMENTED = 0x0004
        const val HAS_POW = 0x0008
        const val ACK_REQ = 0x0010
        const val RELAY_OK = 0x0020
        const val PRIORITY_MASK = 0x0700

        /**
         * Bounded, fail-closed parsing. Magic, version, CRC and the declared
         * length are all validated BEFORE any allocation, so a desynced or
         * corrupted frame is rejected outright rather than half-parsed into a
         * different message.
         */
        fun decode(raw: ByteArray): FrameV2? {
            if (raw.size < HEADER_SIZE) return null
            val buf = ByteBuffer.wrap(raw).order(ByteOrder.BIG_ENDIAN)
            if ((buf.short.toInt() and 0xFFFF) != MAGIC) return null
            if (buf.get() != VERSION) return null
            val type = TypeV2.from(buf.get()) ?: return null
            val msgId = ByteArray(16).also { buf.get(it) }
            val tag = ByteArray(4).also { buf.get(it) }
            val ttl = buf.get().toInt() and 0xFF
            if (ttl > MAX_TTL) return null
            val hop = buf.get().toInt() and 0xFF
            if (hop > MAX_TTL) return null
            val flags = buf.short.toInt() and 0xFFFF
            val len = buf.short.toInt() and 0xFFFF
            val crc = buf.short.toInt() and 0xFFFF
            if (crc != crc16(raw, 0, HEADER_SIZE - 2)) return null
            if (len > MAX_PAYLOAD) return null
            if (raw.size != HEADER_SIZE + len) return null
            val payload = ByteArray(len).also { buf.get(it) }
            return FrameV2(type, msgId, tag, ttl, hop, flags, payload)
        }

        fun crc16(data: ByteArray, from: Int, len: Int): Int {
            var crc = 0xFFFF
            for (i in from until from + len) {
                crc = crc xor ((data[i].toInt() and 0xFF) shl 8)
                repeat(8) {
                    crc = if (crc and 0x8000 != 0) ((crc shl 1) xor 0x1021) and 0xFFFF
                          else (crc shl 1) and 0xFFFF
                }
            }
            return crc
        }
    }
}

enum class TypeV2(val code: Byte) {
    HELLO(0x11.toByte()),
    DIGEST(0x12.toByte()),
    WANT(0x14.toByte()),
    MESSAGE(0x18.toByte()),
    ACK(0x21.toByte()),
    BULK_OFFER(0x22.toByte()),
    BULK_CHUNK(0x24.toByte()),
    PING(0x28.toByte()),
    GOODBYE(0x41.toByte()),
    SOS(0xF0.toByte()),
    ;
    companion object {
        private val map = entries.associateBy { it.code }
        fun from(b: Byte): TypeV2? = map[b]
    }
}
