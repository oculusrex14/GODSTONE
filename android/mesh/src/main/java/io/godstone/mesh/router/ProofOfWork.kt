// SYNTHESIZED gap-closure file -- realised for GMP/2.1 per ADR-001 §3 + ADR-008 §2.1.
package io.godstone.mesh.router

import org.bouncycastle.crypto.digests.Blake2sDigest
import kotlinx.coroutines.ensureActive
import kotlin.coroutines.coroutineContext

/**
 * 20-bit BLAKE2s proof of work, carried inside the sealed, authenticated
 * payload (ADR-001 §3). Under GMP/1 the search variable was msg_id itself
 * (there was no nonce field); under GMP/2.1 msg_id is a content hash and CANNOT
 * be mutated, so the nonce moves into the sealed payload where it is
 * authenticated rather than merely present.
 *
 * WHAT THIS MEANS FOR ROUTING. PoW is now a **recipient-side** check, not a
 * relay gate. A relay cannot unseal the payload, so it cannot verify the stamp;
 * relay-side anti-flood is the PeerGovernor token buckets (threat A5). The
 * recipient, after SealedSender.open, verifies the nonce against the unsealed
 * content. The FrameV2 HAS_POW flag (0x0008) marks a frame whose sealed payload
 * carries a mined nonce; GROUP and BROADCAST set it, SOS and DIRECT do not.
 *
 * Verification is cheap (one BLAKE2s); mining is not, which is the point.
 */
object ProofOfWork {

    const val NONCE_BYTES = 8
    /** ADR-001 §3: the production target is a 20-bit-zero BLAKE2s-256 prefix. */
    const val TARGET_BITS = 20

    /**
     * True iff (powNonce ‖ senderNodeId ‖ createdAtBe ‖ typeCode ‖ plaintext)
     * hashes to a BLAKE2s-256 digest whose top [targetBits] bits are zero.
     *
     * The type code is bound so a stamp cannot be replayed against a different
     * frame type (the GMP/1 rationale survives the cutover). The plaintext is
     * the application payload the sender sealed — NOT the sealed blob, which a
     * relay could see but a recipient verifies after opening.
     *
     * [targetBits] defaults to [TARGET_BITS] (20, ADR-pinned). A lower value is
     * exposed solely so unit tests can exercise the mine/verify path without
     * paying for a ~1M-hash search; production always calls the default.
     */
    fun verify(
        powNonce: ByteArray,
        senderNodeId: ByteArray,
        createdAtBe: ByteArray,
        typeCode: Byte,
        plaintext: ByteArray,
        targetBits: Int = TARGET_BITS
    ): Boolean {
        require(powNonce.size == NONCE_BYTES) { "pow_nonce must be $NONCE_BYTES bytes" }
        require(targetBits in 1..32) { "targetBits out of range" }
        val h = blake2s256(preimage(powNonce, senderNodeId, createdAtBe, typeCode, plaintext))
        return topBitsZero(h, targetBits)
    }

    /**
     * Find a [NONCE_BYTES] nonce satisfying the [targetBits] target for the
     * given unsealed content. At the production 20-bit target this is ~1M
     * BLAKE2s, so this suspend function must be called OFF the main thread.
     *
     * It does NOT impose its own dispatcher: the caller controls threading
     * (MeshNode calls it from Dispatchers.IO). Imposing Dispatchers.Default
     * here deadlocks under runBlocking in the test worker; a suspend function
     * should not override its caller's context. It remains cooperatively
     * cancellable via ensureActive() so a user leaving the screen does not
     * strand a CPU.
     */
    suspend fun mine(
        senderNodeId: ByteArray,
        createdAtBe: ByteArray,
        typeCode: Byte,
        plaintext: ByteArray,
        rng: java.security.SecureRandom = java.security.SecureRandom(),
        targetBits: Int = TARGET_BITS
    ): ByteArray {
        require(targetBits in 1..32) { "targetBits out of range" }
        val powNonce = ByteArray(NONCE_BYTES).also { rng.nextBytes(it) }
        while (true) {
            coroutineContext.ensureActive()
            val h = blake2s256(preimage(powNonce, senderNodeId, createdAtBe, typeCode, plaintext))
            if (topBitsZero(h, targetBits)) {
                return powNonce.copyOf()
            }
            increment(powNonce)
        }
    }

    /** True iff the top [targetBits] bits of [h] are all zero. */
    private fun topBitsZero(h: ByteArray, targetBits: Int): Boolean {
        var remaining = targetBits
        var i = 0
        while (remaining >= 8) {
            if (h[i].toInt() != 0) return false
            remaining -= 8; i++
        }
        if (remaining > 0) {
            val mask = (0xFF shl (8 - remaining)) and 0xFF
            if (h[i].toInt() and mask != 0) return false
        }
        return true
    }

    private fun preimage(
        powNonce: ByteArray, senderNodeId: ByteArray, createdAtBe: ByteArray,
        typeCode: Byte, plaintext: ByteArray
    ) = powNonce + senderNodeId + createdAtBe + byteArrayOf(typeCode) + plaintext

    private fun blake2s256(data: ByteArray): ByteArray {
        val d = Blake2sDigest(256 / 8)
        d.update(data, 0, data.size)
        val out = ByteArray(32)
        d.doFinal(out, 0)
        return out
    }

    /** Big-endian increment of an 8-byte nonce; wraps at 2^64 (astronomically never). */
    private fun increment(b: ByteArray) {
        // Compare the byte UNSIGNED: toInt() sign-extends, so 0xFF becomes -1 and
        // a naive `== 0xFF` is never true -- the carry would never fire and the
        // nonce would cycle through only 256 last-byte values, hanging the mine.
        var i = b.size - 1
        while (i >= 0) {
            if ((b[i].toInt() and 0xFF) == 0xFF) { b[i] = 0; i-- } else {
                b[i] = ((b[i].toInt() and 0xFF) + 1).toByte(); return
            }
        }
    }
}