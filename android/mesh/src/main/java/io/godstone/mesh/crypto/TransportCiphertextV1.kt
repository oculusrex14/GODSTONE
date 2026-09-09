package io.godstone.mesh.crypto

import java.nio.ByteBuffer

/**
 * T06: the unified DATA transport wire format, shared with Swift:
 * `ciphertext = uint64_be(nonce) || ChaChaPoly ciphertext || tag`.
 *
 * The internal ChaCha nonce stays `zero32 || uint64_le(n)`; the wire carries
 * the explicit big-endian prefix. Legacy implicit-counter frames are never
 * auto-detected: the first 8 bytes are always the nonce.
 */
object TransportCiphertextV1 {

    fun encode(nonce: Long, ciphertextAndTag: ByteArray): ByteArray =
        ByteBuffer.allocate(8 + ciphertextAndTag.size)
            .putLong(nonce)
            .put(ciphertextAndTag)
            .array()

    /** Returns (nonce, ciphertextAndTag) or null when the frame is too short. */
    fun decode(raw: ByteArray): Pair<Long, ByteArray>? {
        if (raw.size < 8) return null
        val buffer = ByteBuffer.wrap(raw)
        val nonce = buffer.long
        val rest = ByteArray(raw.size - 8)
        buffer.get(rest)
        return nonce to rest
    }
}