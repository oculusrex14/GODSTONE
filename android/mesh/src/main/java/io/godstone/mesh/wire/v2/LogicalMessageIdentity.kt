package io.godstone.mesh.wire.v2

import java.security.SecureRandom

/**
 * Immutable logical message identity (ADR-001 §3.3, C6.7.1).
 *
 * Encapsulates the immutable tuple:
 *     (created_at_epoch_seconds, message_nonce)
 *
 * Rules:
 * - A new logical message authors an identity ONCE via [createNew].
 * - Retries re-transmit the exact persisted FrameV2 rather than re-authoring.
 * - [messageNonce] is an immutable 16-byte random token (defensive copy on read).
 * - [createdAtEpochSeconds] is constrained to uint32 epoch-second range.
 */
class LogicalMessageIdentity private constructor(
    val createdAtEpochSeconds: Long,
    private val rawNonce: ByteArray
) {
    init {
        require(createdAtEpochSeconds in 0..0xFFFFFFFFL) {
            "createdAtEpochSeconds ($createdAtEpochSeconds) out of uint32 range"
        }
        require(rawNonce.size == MessageId.NONCE_BYTES) {
            "messageNonce must be ${MessageId.NONCE_BYTES} bytes, got ${rawNonce.size}"
        }
    }

    /** Copy-on-read defensive copy to prevent external mutation. */
    val messageNonce: ByteArray
        get() = rawNonce.copyOf()

    /** 4-byte little-endian uint32 serialization (ADR-001 §3.3 created_at_le). */
    fun createdAtLe(): ByteArray = MessageId.uint32Le(createdAtEpochSeconds)

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is LogicalMessageIdentity) return false
        return createdAtEpochSeconds == other.createdAtEpochSeconds &&
            rawNonce.contentEquals(other.rawNonce)
    }

    override fun hashCode(): Int {
        var result = createdAtEpochSeconds.hashCode()
        result = 31 * result + rawNonce.contentHashCode()
        return result
    }

    override fun toString(): String {
        val nonceHex = rawNonce.joinToString("") { "%02x".format(it) }
        return "LogicalMessageIdentity(createdAt=$createdAtEpochSeconds, nonce=$nonceHex)"
    }

    companion object {
        /** Author a new logical message identity with wall-clock time and CSPRNG nonce. */
        fun createNew(
            nowEpochSeconds: Long = System.currentTimeMillis() / 1000,
            rng: SecureRandom = SecureRandom()
        ): LogicalMessageIdentity {
            val nonce = ByteArray(MessageId.NONCE_BYTES).also { rng.nextBytes(it) }
            return LogicalMessageIdentity(nowEpochSeconds, nonce)
        }

        /** Construct a deterministic logical identity (for tests, unsealing, and rederivation). */
        fun of(
            createdAtEpochSeconds: Long,
            messageNonce: ByteArray
        ): LogicalMessageIdentity {
            return LogicalMessageIdentity(createdAtEpochSeconds, messageNonce.copyOf())
        }
    }
}
