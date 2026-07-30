// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh.router

import io.godstone.mesh.wire.Frame
import org.bouncycastle.crypto.digests.Blake2sDigest
import java.nio.ByteBuffer

/**
 * 20-bit BLAKE2s proof of work attached to GROUP and BROADCAST frames.
 *
 * PoW is the cheapest way to make flooding expensive without a central rate
 * limiter: a peer must burn CPU to inject wide-distribution traffic, so a
 * sybil node cannot drown the mesh for free. SOS and DIRECT are exempt because
 * latency there is safety.
 *
 * Verification is cheap (one BLAKE2s); mining is not, which is the point.
 */
object ProofOfWork {

    /**
     * True iff [frame] carries a valid 20-bit PoW stamp.
     *
     * Input = payload || msg_id || timestamp || type_code; the hash must have its
     * top 20 bits zero. The type is bound so a stamp cannot be replayed against a
     * different frame type.
     */
    fun verify(frame: Frame): Boolean {
        val input = frame.payload +
            longBytes(frame.msgId) +
            longBytes(frame.timestamp) +
            byteArrayOf(frame.type.code)

        val h = ByteArray(32)
        val d = Blake2sDigest(256 / 8)
        d.update(input, 0, input.size)
        d.doFinal(h, 0)

        return h[0].toInt() == 0 &&
            h[1].toInt() == 0 &&
            (h[2].toInt() and 0xF0) == 0
    }

    // TODO: fun mine(frame, difficulty) -- sender-side mining is not yet wired.

    private fun longBytes(v: Long): ByteArray =
        ByteBuffer.allocate(8).putLong(v).array()
}