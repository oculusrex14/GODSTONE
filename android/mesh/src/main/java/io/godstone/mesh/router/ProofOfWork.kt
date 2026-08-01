// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
package io.godstone.mesh.router

import io.godstone.mesh.wire.Frame
import org.bouncycastle.crypto.digests.Blake2sDigest
import java.nio.ByteBuffer
import kotlinx.coroutines.Dispatchers
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

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

    /**
     * Return a copy of [frame] whose msg_id satisfies the 20-bit PoW target.
     *
     * Audit A-11: verify() existed but nothing produced stamps, so every
     * locally-originated GROUP/BROADCAST frame would have been dropped by the
     * first honest relay.
     *
     * There is no dedicated nonce field in the GMP/1 header (see wire/Frame.kt),
     * so the search variable is msg_id itself, which the sender already chooses
     * freely and which verify() already binds. The hash input below is therefore
     * byte-identical to verify() by construction -- do not let the two drift.
     *
     * msg_id stays uniformly distributed, so bloom-digest and dedup behaviour
     * are unaffected.
     *
     * ~1M BLAKE2s at 20 bits: suspending, off the main thread, and cooperatively
     * cancellable so a user leaving the screen does not strand a CPU.
     */
    suspend fun mine(frame: Frame): Frame = withContext(Dispatchers.Default) {
        val tail = longBytes(frame.timestamp) + byteArrayOf(frame.type.code)
        val h = ByteArray(32)
        var candidate = frame.msgId

        while (true) {
            coroutineContext.ensureActive()

            val d = Blake2sDigest(256 / 8)
            d.update(frame.payload, 0, frame.payload.size)
            val mid = longBytes(candidate)
            d.update(mid, 0, mid.size)
            d.update(tail, 0, tail.size)
            d.doFinal(h, 0)

            if (h[0].toInt() == 0 && h[1].toInt() == 0 && (h[2].toInt() and 0xF0) == 0) {
                return@withContext frame.copy(msgId = candidate)
            }
            candidate++
        }
        error("unreachable")
    }

    private fun longBytes(v: Long): ByteArray =
        ByteBuffer.allocate(8).putLong(v).array()
}
