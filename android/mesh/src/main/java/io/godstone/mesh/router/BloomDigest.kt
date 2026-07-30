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
 */
class BloomDigest(private val bits: ByteArray = ByteArray(SIZE_BYTES)) {

    fun add(msgId: Long) {
        for (i in 0 until HASHES) {
            val idx = index(msgId, i)
            bits[idx ushr 3] = (bits[idx ushr 3].toInt() or (1 shl (idx and 7))).toByte()
        }
    }

    fun mightContain(msgId: Long): Boolean {
        for (i in 0 until HASHES) {
            val idx = index(msgId, i)
            if (bits[idx ushr 3].toInt() and (1 shl (idx and 7)) == 0) return false
        }
        return true
    }

    fun toBytes(): ByteArray = bits.copyOf()

    /** 16-byte truncation carried in the BLE advertisement. */
    fun shortDigest(): ByteArray = bits.copyOf(16)

    private fun index(msgId: Long, round: Int): Int {
        val d = Blake2sDigest(null, 8, null, null)
        val input = ByteBuffer.allocate(12).putLong(msgId).putInt(round).array()
        d.update(input, 0, input.size)
        val out = ByteArray(8)
        d.doFinal(out, 0)
        val v = ByteBuffer.wrap(out).getLong()
        return ((v ushr 1).toInt() and Int.MAX_VALUE) % SIZE_BITS
    }

    companion object {
        const val SIZE_BITS = 4096
        const val SIZE_BYTES = SIZE_BITS / 8
        const val HASHES = 4

        fun fromBytes(b: ByteArray): BloomDigest {
            require(b.size == SIZE_BYTES) { "bad digest size ${b.size}" }
            return BloomDigest(b.copyOf())
        }
    }
}
