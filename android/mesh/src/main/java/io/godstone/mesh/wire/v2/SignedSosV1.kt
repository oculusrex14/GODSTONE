package io.godstone.mesh.wire.v2

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.mesh.identity.IDENTITY_BINDING_NODE_ID_LENGTH
import io.godstone.mesh.identity.IDENTITY_BINDING_SERIALIZED_LENGTH
import io.godstone.mesh.identity.IDENTITY_BINDING_SIGNING_KEY_LENGTH
import io.godstone.mesh.identity.IDENTITY_BINDING_SIGNATURE_LENGTH
import io.godstone.mesh.identity.IDENTITY_BINDING_STATIC_DH_KEY_LENGTH
import io.godstone.mesh.identity.IDENTITY_BINDING_VERSION
import io.godstone.mesh.identity.IdentityBindingV1

/*
 * SignedSosV1 -- the one signed SOS envelope of section 15 (T38).
 *
 * Hand-written runtime helper -- NOT a codegen artifact (the ci/check_parity
 * Invariant A regenerations cover the wire tables only); this file follows the
 * same exception as MessageId.kt and SignedMessageV1.kt. It OBEYS the frozen
 * tables and REUSES the sealed authorities; it rewrites none of them:
 *
 *   - the outer SOS code and required flags stand forever as recorded in
 *     wire_v2.yaml (type 0xF0; ACK_REQ|RELAY_OK); this file only sets them,
 *     never reads them into new meaning;
 *   - msg_id is the FROZEN MessageId.derive formula, taken here over the
 *     UNSIGNED payload (the card's law); the signature covers
 *     msg_id || ASCII("SOS1") || unsigned payload -- the section-15 transcript,
 *     consistently with the structural validator's documented split;
 *   - the identity binding is the T13 IdentityBindingV1, reused verbatim:
 *     serialized 133 = version || generation_be || signing_pub || static_dh_pub
 *     || binding_signature; its 80-byte preimage carries the GMP2-IDBIND domain
 *     and node_id = BLAKE2s-128(signing_pub) is the ONLY honest node identity;
 *   - the structural gate is DELEGATED, not duplicated: SosFrameValidator
 *     keeps its patch-15 scope (magic, flags, lengths) and this file composes
 *     the cryptographic gate behind it. The split is section-15 law: the
 *     structural golden fixtures carry zero signatures on purpose and must
 *     pass the validator while runtime authentication refuses them.
 *
 * Canonical layout (wire_v2.yaml sos_requirements, amended by the T38 record
 * in docs/adr/ADR-005; vectors locked in crypto/sos_v1_vectors.json):
 *
 *   frame payload = "SOS1"(4) || signature(64) || unsigned payload
 *   unsigned payload = version(1)=0x01 || identityBinding(133)
 *                    || created_at_le(4) || time_quality(1) || nonce(16)
 *                    || body_len_be(2) || utf8 body (<= 400, strict)
 *
 * The receiver distinguishes the authenticated KEY from the verified PERSON:
 * verification alone announces the key material; the caller who holds a peer
 * directory may pass its claimed node id as expectedNodeId and the equation
 * node_id == BLAKE2s-128(embedded signing_pub) is checked against it -- an
 * absent directory (null) never fabricates a trust decision. No trust or
 * approval state moves here (the security gate of the delivery tracker is a
 * different layer entirely). Nothing on this path ever throws out of the
 * receiver loop: every refusal is a typed SosAuthResult.Unauthenticated with
 * a reason from the table below.
 */

/** The card's taxonomy of one received signed SOS frame. */
class VerifiedSos(
    senderNodeId: ByteArray,
    signingPublicKey: ByteArray,
    staticDhPublicKey: ByteArray,
    val generation: Long,
    val createdAtEpochSeconds: Long,
    val timeQuality: TimeQuality,
    messageNonce: ByteArray,
    bodyUtf8: ByteArray,
    unsignedPayload: ByteArray,
    val frame: FrameV2,
) {
    /* Defensive copies: the arrays handed out are never the stored ones. */
    private val _senderNodeId = senderNodeId.copyOf()
    private val _signingPublicKey = signingPublicKey.copyOf()
    private val _staticDhPublicKey = staticDhPublicKey.copyOf()
    private val _messageNonce = messageNonce.copyOf()
    private val _bodyUtf8 = bodyUtf8.copyOf()
    private val _unsignedPayload = unsignedPayload.copyOf()

    val senderNodeId: ByteArray get() = _senderNodeId.copyOf()
    val signingPublicKey: ByteArray get() = _signingPublicKey.copyOf()
    val staticDhPublicKey: ByteArray get() = _staticDhPublicKey.copyOf()
    val messageNonce: ByteArray get() = _messageNonce.copyOf()
    val bodyUtf8: ByteArray get() = _bodyUtf8.copyOf()
    val unsignedPayload: ByteArray get() = _unsignedPayload.copyOf()

    /** Redacted: key material is never rendered whole (section-5 privacy). */
    override fun toString(): String = "VerifiedSos(sender=" +
        SignedSosV1.hex4(_senderNodeId) + ",key=" + SignedSosV1.hex4(_signingPublicKey) +
        ",dh=" + SignedSosV1.hex4(_staticDhPublicKey) + ",gen=" + generation +
        ",t=" + createdAtEpochSeconds + ",tq=" + timeQuality.name +
        ",nonce=" + SignedSosV1.hex4(_messageNonce) + ",body=" + _bodyUtf8.size + "B)"
}

/** Verification result of the signed-SOS receiver: authenticated or refused. */
sealed class SosAuthResult {
    class Authenticated(val verified: VerifiedSos) : SosAuthResult()
    class Unauthenticated(val reason: String, val detail: String? = null) : SosAuthResult()
}

/**
 * The signing authority the composition root wires into MeshNode for the SOS
 * path (the T54 lab graph binds it to the durable identity; the unit courts
 * bind it to fixed KAT material). A null authority keeps the legacy
 * structural emission of Router.buildSos -- documented, not silently
 * authenticated, and unreachable while the link layer stays closed.
 */
interface SosObserver {
    /** The frame authenticated: the observer announces the distress indication
     * together with the resolved key material. Trust/approval state does NOT
     * move here -- that is the peer-directory layer's own decision. */
    fun onSosAuthenticated(verified: VerifiedSos)

    /** The frame was refused authentication: reason from the table; the
     * relay/forwarding duty of the router is unaffected either way. */
    fun onSosUnauthenticated(frame: FrameV2, reason: String)
}

interface SosSigningAuthority {
    /** A fresh 16-byte nonce for each authorship (payload-independent
     * freshness); the composition root draws from the CSPRNG, courts pin
     * fixed ones for the transcribed vectors. */
    fun currentNonce(): ByteArray

    /** The 32-byte Ed25519 seed, or null when the node holds no signing key. */
    fun currentSigningSeed(): ByteArray?

    /** The 32-byte static X25519 public key that pairs with the seed. */
    fun currentStaticDhPublicKey(): ByteArray?

    /** The durable generation counter the binding is struck under. */
    fun currentGeneration(): Long

    /** Wall clock in whole epoch seconds; 0 announces the unknown-time rule. */
    fun currentTimeEpochSeconds(): Long
}

object SignedSosV1 {
    /* ---- literal constants (names match the frozen tables) ---- */

    /** The four magic bytes; equal to SosFrameValidator.PAYLOAD_MAGIC by law. */
    val SOS_MAGIC: ByteArray = byteArrayOf(
        'S'.code.toByte(), 'O'.code.toByte(), 'S'.code.toByte(), '1'.code.toByte(),
    )
    const val PAYLOAD_VERSION: Int = 0x01
    const val SIGNATURE_BYTES: Int = 64
    const val NONCE_BYTES: Int = 16
    const val BODY_BUDGET_MAX: Int = 400

    /* offsets in the unsigned payload, counted in bytes */
    const val OFF_VERSION: Int = 0
    const val OFF_BINDING: Int = 1
    const val OFF_CREATED_LE: Int = OFF_BINDING + IDENTITY_BINDING_SERIALIZED_LENGTH   // 134
    const val OFF_TIME_QUALITY: Int = OFF_CREATED_LE + 4                                 // 138
    const val OFF_NONCE: Int = OFF_TIME_QUALITY + 1                                      // 139
    const val OFF_BODY_LEN: Int = OFF_NONCE + NONCE_BYTES                                // 155
    const val OFF_BODY: Int = OFF_BODY_LEN + 2                                           // 157
    const val UNSIGNED_MIN: Int = OFF_BODY

    /** The table of named reasons; the court and the roster match on these. */
    object Reason {
        const val WRONG_TYPE = "wrong_type"
        const val MISSING_REQUIRED_FLAGS = "missing_required_flags"
        const val MALFORMED = "malformed"
        const val BODY_LENGTH = "body_length"
        const val TIME_QUALITY = "time_quality"
        const val UNKNOWN_TIME_PAIRING = "unknown_time_pairing"
        const val MESSAGE_ID_MISMATCH = "message_id_mismatch"
        const val IDENTITY_BINDING = "identity_binding"
        const val SIGNATURE = "signature"
    }

    /* ---- small helpers ---- */

    internal fun hex4(bytes: ByteArray): String {
        if (bytes.size <= 8) return hexAll(bytes)
        return hexAll(bytes.copyOfRange(0, 4)) + ".." +
            hexAll(bytes.copyOfRange(bytes.size - 4, bytes.size))
    }

    internal fun hexAll(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            sb.append(HEX_DIGITS[(v ushr 4) and 0x0F])
            sb.append(HEX_DIGITS[v and 0x0F])
        }
        return sb.toString()
    }

    private val HEX_DIGITS = charArrayOf('0', '1', '2', '3', '4', '5', '6', '7',
        '8', '9', 'a', 'b', 'c', 'd', 'e', 'f')

    private fun writeU32Le(dest: ByteArray, at: Int, value: Long) {
        dest[at] = (value and 0xFF).toByte()
        dest[at + 1] = ((value ushr 8) and 0xFF).toByte()
        dest[at + 2] = ((value ushr 16) and 0xFF).toByte()
        dest[at + 3] = ((value ushr 24) and 0xFF).toByte()
    }

    private fun readU32Le(src: ByteArray, at: Int): Long =
        (src[at].toLong() and 0xFF) or
            ((src[at + 1].toLong() and 0xFF) shl 8) or
            ((src[at + 2].toLong() and 0xFF) shl 16) or
            ((src[at + 3].toLong() and 0xFF) shl 24)

    private fun readU16Be(src: ByteArray, at: Int): Int =
        ((src[at].toInt() and 0xFF) shl 8) or (src[at + 1].toInt() and 0xFF)

    private fun timeQualityFromCode(code: Int): TimeQuality? = when (code) {
        0 -> TimeQuality.UNKNOWN
        1 -> TimeQuality.USER_CONFIRMED
        2 -> TimeQuality.AUTHENTICATED_SOURCE
        else -> null
    }

    private fun unauth(reason: String, detail: String? = null): SosAuthResult =
        SosAuthResult.Unauthenticated(reason, detail)

    /* ---- the canonical builders (single source of truth, both directions) ---- */

    /** Assemble the unsigned payload; throws IllegalArgumentException on any
     * non-canonical input -- the author refuses to emit what it cannot verify. */
    fun unsignedPayload(binding: ByteArray, createdAtEpochSeconds: Long,
        timeQuality: TimeQuality, messageNonce: ByteArray, bodyUtf8: ByteArray): ByteArray {
        require(binding.size == IDENTITY_BINDING_SERIALIZED_LENGTH) {
            "binding must be the 133-byte serialization"
        }
        require(messageNonce.size == NONCE_BYTES) { "nonce must be 16 bytes" }
        require(bodyUtf8.size <= BODY_BUDGET_MAX) { "body exceeds the 400-byte budget" }
        require(createdAtEpochSeconds in 0L..0xFFFF_FFFFL) { "created_at outside u32" }
        require(SignedMessageV1.isWellFormedUtf8(bodyUtf8)) { "body must be well-formed UTF-8" }
        require((createdAtEpochSeconds == 0L) == (timeQuality == TimeQuality.UNKNOWN)) {
            "unknown time binds created_at 0 with timeQuality UNKNOWN; the two stand and fall together"
        }
        val out = ByteArray(UNSIGNED_MIN + bodyUtf8.size)
        out[OFF_VERSION] = PAYLOAD_VERSION.toByte()
        binding.copyInto(out, OFF_BINDING, 0, binding.size)
        writeU32Le(out, OFF_CREATED_LE, createdAtEpochSeconds)
        out[OFF_TIME_QUALITY] = timeQuality.code.toByte()
        messageNonce.copyInto(out, OFF_NONCE, 0, messageNonce.size)
        out[OFF_BODY_LEN] = ((bodyUtf8.size ushr 8) and 0xFF).toByte()
        out[OFF_BODY_LEN + 1] = (bodyUtf8.size and 0xFF).toByte()
        bodyUtf8.copyInto(out, OFF_BODY, 0, bodyUtf8.size)
        return out
    }

    /** The section-15 transcript: msg_id || ASCII("SOS1") || unsigned payload. */
    fun signatureTranscript(messageId: ByteArray, unsigned: ByteArray): ByteArray =
        messageId + SOS_MAGIC + unsigned

    /** The frozen MessageId formula, taken here over the UNSIGNED span. */
    fun deriveMessageId(senderNodeId: ByteArray, createdAtEpochSeconds: Long,
        messageNonce: ByteArray, unsigned: ByteArray): ByteArray =
        MessageId.derive(senderNodeId, createdAtEpochSeconds, messageNonce, unsigned)

    /* ---- author (sender side) ---- */

    /**
     * Sign one distress call end to end: strike the identity binding with the
     * local key (the T13 equation, reused not rewritten), assemble the
     * unsigned payload, derive msg_id over it, sign the transcript, and set
     * the outer fields exactly as the frozen tables record them: type SOS,
     * ACK_REQ|RELAY_OK required, ttl MAX_TTL, hop 0, broadcast routing tag.
     */
    fun author(signingSeed: ByteArray, staticDhPublicKey: ByteArray, generation: Long,
        createdAtEpochSeconds: Long, timeQuality: TimeQuality, messageNonce: ByteArray,
        bodyUtf8: ByteArray): FrameV2 {
        require(signingSeed.size == IDENTITY_BINDING_SIGNING_KEY_LENGTH) { "seed must be 32 bytes" }
        require(staticDhPublicKey.size == IDENTITY_BINDING_STATIC_DH_KEY_LENGTH) { "dh pub must be 32 bytes" }
        require(generation in 0L..0xFFFF_FFFFL) { "generation outside u32" }
        val signingPublicKey = Ed25519Keys.publicKeyFromPrivate(signingSeed)
        val bindingPreimage = IdentityBindingV1.signaturePreimage(
            generation, signingPublicKey, staticDhPublicKey,
        )
        val bindingSignature = Ed25519Keys.sign(bindingPreimage, signingSeed)
        val binding = IdentityBindingV1.create(
            generation = generation,
            signingPublicKey = signingPublicKey,
            staticDhPublicKey = staticDhPublicKey,
            signature = bindingSignature,
        ).encode()
        val unsigned = unsignedPayload(binding, createdAtEpochSeconds, timeQuality,
            messageNonce, bodyUtf8)
        val senderNodeId = IdentityBindingV1.deriveNodeId(signingPublicKey)
        val msgId = deriveMessageId(senderNodeId, createdAtEpochSeconds, messageNonce, unsigned)
        val signature = Ed25519Keys.sign(signatureTranscript(msgId, unsigned), signingSeed)
        val payload = SOS_MAGIC + signature + unsigned
        return FrameV2(
            type = TypeV2.SOS,
            msgId = msgId,
            routingTag = ByteArray(4),                 // broadcast: no destination hint
            ttl = FrameV2.MAX_TTL,
            hopCount = 0,
            flags = FrameV2.ACK_REQ or FrameV2.RELAY_OK,
            payload = payload,
        )
    }

    /* ---- receiver (authentication; the verifier never throws) ---- */

    /**
     * Authenticate one received SOS frame. Gate order is the validator order:
     * structural (delegated to SosFrameValidator), then shape, then time,
     * then the identity equation, then the hash binding, then the signature.
     * expectedNodeId -- when the composition root holds a peer directory --
     * checks the authenticated key against the claimed person; null asks no
     * such question and no trust state moves either way.
     */
    fun verify(frame: FrameV2, expectedNodeId: ByteArray? = null): SosAuthResult {
        when (SosFrameValidator.validate(frame)) {
            SosFrameValidator.Verdict.OK -> Unit
            SosFrameValidator.Verdict.WRONG_TYPE -> return unauth(Reason.WRONG_TYPE)
            SosFrameValidator.Verdict.MISSING_REQUIRED_FLAGS ->
                return unauth(Reason.MISSING_REQUIRED_FLAGS)
            else -> return unauth(Reason.MALFORMED, "envelope")
        }
        if (expectedNodeId != null && expectedNodeId.size != IDENTITY_BINDING_NODE_ID_LENGTH) {
            return unauth(Reason.MALFORMED, "expected node id")
        }
        val payload = frame.payload
        val totalMin = SOS_MAGIC.size + SIGNATURE_BYTES + UNSIGNED_MIN
        if (payload.size < totalMin || payload.size > totalMin + BODY_BUDGET_MAX) {
            return unauth(Reason.MALFORMED, "frame length")
        }
        val signature = payload.copyOfRange(SOS_MAGIC.size, SOS_MAGIC.size + SIGNATURE_BYTES)
        val unsigned = payload.copyOfRange(SOS_MAGIC.size + SIGNATURE_BYTES, payload.size)
        if (unsigned[OFF_VERSION].toInt() and 0xFF != PAYLOAD_VERSION) {
            return unauth(Reason.MALFORMED, "payload version")
        }
        val bodyLen = readU16Be(unsigned, OFF_BODY_LEN)
        if (bodyLen > BODY_BUDGET_MAX) return unauth(Reason.BODY_LENGTH, "budget")
        if (unsigned.size != UNSIGNED_MIN + bodyLen) return unauth(Reason.BODY_LENGTH)
        val createdAt = readU32Le(unsigned, OFF_CREATED_LE)
        val timeQuality = timeQualityFromCode(unsigned[OFF_TIME_QUALITY].toInt() and 0xFF)
            ?: return unauth(Reason.TIME_QUALITY)
        if ((createdAt == 0L) != (timeQuality == TimeQuality.UNKNOWN)) {
            return unauth(Reason.UNKNOWN_TIME_PAIRING)
        }
        val nonce = unsigned.copyOfRange(OFF_NONCE, OFF_NONCE + NONCE_BYTES)
        val bindingBytes = unsigned.copyOfRange(OFF_BINDING,
            OFF_BINDING + IDENTITY_BINDING_SERIALIZED_LENGTH)
        val binding = try {
            IdentityBindingV1.parse(bindingBytes)
        } catch (e: IllegalArgumentException) {
            return unauth(Reason.IDENTITY_BINDING, "parse")
        }
        if (binding.version != IDENTITY_BINDING_VERSION) {
            return unauth(Reason.IDENTITY_BINDING, "version")
        }
        if (binding.generation !in 0L..0xFFFF_FFFFL) {
            return unauth(Reason.IDENTITY_BINDING, "generation")
        }
        val bindingOk = try {
            Ed25519Keys.verify(
                IdentityBindingV1.signaturePreimage(
                    binding.generation, binding.signingPublicKey, binding.staticDhPublicKey,
                ),
                binding.signature,
                binding.signingPublicKey,
            )
        } catch (e: IllegalArgumentException) {
            false
        }
        if (!bindingOk) return unauth(Reason.IDENTITY_BINDING, "binding signature")
        val derivedNode = IdentityBindingV1.deriveNodeId(binding.signingPublicKey)
        if (expectedNodeId != null && !derivedNode.contentEquals(expectedNodeId)) {
            // the authenticated key is not the key of the claimed person
            return unauth(Reason.IDENTITY_BINDING, "person")
        }
        val msgRe = deriveMessageId(derivedNode, createdAt, nonce, unsigned)
        if (!msgRe.contentEquals(frame.msgId)) return unauth(Reason.MESSAGE_ID_MISMATCH)
        val signatureOk = try {
            Ed25519Keys.verify(signatureTranscript(msgRe, unsigned), signature,
                binding.signingPublicKey)
        } catch (e: IllegalArgumentException) {
            false
        }
        if (!signatureOk) return unauth(Reason.SIGNATURE)
        val body = unsigned.copyOfRange(OFF_BODY, unsigned.size)
        // The body's UTF-8 shape was bound into the hash before signing; a
        // byte that broke the shape would have broken the hash first. The
        // re-check is defense in depth for the consumer of VerifiedSos.
        if (!SignedMessageV1.isWellFormedUtf8(body)) {
            return unauth(Reason.MALFORMED, "utf-8")
        }
        return SosAuthResult.Authenticated(VerifiedSos(
            senderNodeId = derivedNode,
            signingPublicKey = binding.signingPublicKey,
            staticDhPublicKey = binding.staticDhPublicKey,
            generation = binding.generation,
            createdAtEpochSeconds = createdAt,
            timeQuality = timeQuality,
            messageNonce = nonce,
            bodyUtf8 = body,
            unsignedPayload = unsigned,
            frame = frame,
        ))
    }

    /** Convenience for the composition root: the key pair a node may sign with. */
    fun signingPublicKeyOf(seed: ByteArray): ByteArray =
        Ed25519Keys.publicKeyFromPrivate(seed)

    /** The node identity a signing public key binds to (the T13 equation). */
    fun nodeIdOfSigningKey(signingPublicKey: ByteArray): ByteArray =
        IdentityBindingV1.deriveNodeId(signingPublicKey)
}
