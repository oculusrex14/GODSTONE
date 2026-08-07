package io.godstone.mesh.router

import org.bouncycastle.crypto.digests.Blake2sDigest
import java.nio.ByteBuffer

/**
 * Bloom filter of held msg_ids, exchanged so two peers can determine what the
 * other is missing without enumerating everything they hold.
 *
 * 4096 bits, 4 hashes, roughly 0.9% false positive rate at 2000 messages.
 * A false positive means we fail to offer a message the peer actually lacks;
 * the next encounter, or a different carrier, corrects it. That is acceptable
 * in an epidemic protocol and far cheaper than exchanging full id lists.
 *
 * GMP/2.1 (ADR-001 §3): the hash input is the full 16-byte msg_id concatenated
 * with the round index as a big-endian uint32, hashed with BLAKE2s-64 (8-byte
 * digest) and reduced mod 4096. Four rounds. The 20-byte shortDigest (the first
 * 20 bytes of the 512-byte filter) is carried in the BLE advertisement.
 *
 * The msg_id is now a 16-byte content-derived BLOB (MessageId.derive), not the
 * GMP/1 8-byte Long. add()/mightContain() take the 16-byte id directly.
 */
class BloomDigest(private val bits: ByteArray = ByteArray(SIZE_BYTES)) {

    fun add(msgId: ByteArray) {
        require(msgId.size == 16) { "msg_id must be 16 bytes" }
        for (i in 0 until HASHES) {
            val idx = index(msgId, i)
            bits[idx ushr 3] = (bits[idx ushr 3].toInt() or (1 shl (idx and 7))).toByte()
        }
    }

    fun mightContain(msgId: ByteArray): Boolean {
        require(msgId.size == 16) { "msg_id must be 16 bytes" }
        for (i in 0 until HASHES) {
            val idx = index(msgId, i)
            if (bits[idx ushr 3].toInt() and (1 shl (idx and 7)) == 0) return false
        }
        return true
    }

    fun toBytes(): ByteArray = bits.copyOf()

    /** 20-byte truncation carried in the BLE advertisement (ADR-001 §3). */
    fun shortDigest(): ByteArray = bits.copyOf(SHORT_BYTES)

    private fun index(msgId: ByteArray, round: Int): Int {
        val d = Blake2sDigest(null, 8, null, null)
        d.update(msgId, 0, msgId.size)
        // uint32_be(round): big-endian round index, matching the wire format's byte order.
        val rb = ByteBuffer.allocate(4).putInt(round).array()
        d.update(rb, 0, rb.size)
        val out = ByteArray(8)
        d.doFinal(out, 0)
        // Interpret the 8-byte BLAKE2s-64 digest big-endian, mask to unsigned, mod 4096.
        val v = ByteBuffer.wrap(out).getLong()
        return ((v ushr 1).toInt() and Int.MAX_VALUE) % SIZE_BITS
    }

    companion object {
        const val SIZE_BITS = 4096
        const val SIZE_BYTES = SIZE_BITS / 8   // 512
        const val SHORT_BYTES = 20
        const val HASHES = 4

        fun fromBytes(b: ByteArray): BloomDigest {
            require(b.size == SIZE_BYTES) { "bad digest size ${b.size}" }
            return BloomDigest(b.copyOf())
        }
    }
}