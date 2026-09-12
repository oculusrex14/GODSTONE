// Hand-written runtime helper -- NOT a codegen artifact.
// ci/check_parity.py Invariant A regenerates the wire codecs only from wire_v2.yaml;
// this file is the runtime realisation of the section-15 SignedMessageV1 PROPOSED
// application-payload amendment and is outside the codegen contract, exactly like
// MessageId.kt and Priority.kt. The outer frame, the 29-byte sealed prefix, the
// MessageId formula, the PoW/priority policy and every frozen vector are read-only
// authorities: nothing here rewrites them. Section 15: "this baseline has no accepted
// shipping mesh protocol; reject legacy/untrusted formats rather than adding
// auto-detection"; unknown versions are fail-closed, there is no legacy plaintext fallback.
package io.godstone.mesh.wire.v2

import io.godstone.core.crypto.Ed25519Keys
import org.bouncycastle.crypto.digests.Blake2sDigest
import kotlin.text.Charsets

/**
 * Creation-time quality per section 15: 0 unknown, 1 user-confirmed, 2 authenticated
 * source. Unknown time uses createdAt 0 / timeQuality 0 -- NEVER a new plaintext
 * timestamp or header flag (the codec has no such field to add one into).
 */
enum class TimeQuality(val code: Int) {
    UNKNOWN(0),
    USER_CONFIRMED(1),
    AUTHENTICATED_SOURCE(2);

    companion object {
        fun fromCode(code: Int): TimeQuality? = entries.firstOrNull { it.code == code }
    }
}

/** The authenticated application message. Only ever produced by a Verified result. */
class VerifiedApplicationMessage internal constructor(
    val senderNodeId: ByteArray,        // 16 -- == BLAKE2s128(senderIdentityPub)
    val senderIdentityPub: ByteArray,   // 32 -- Ed25519 public key
    val recipientNodeId: ByteArray,     // 16 -- == the intended local recipient (checked by the verifier)
    val messageNonce: ByteArray,        // 16 -- sealed_inner prefix field, bound into the signature
    val createdAtEpochSeconds: Long,    // uint32 le in the preimage; 0 iff timeQuality UNKNOWN
    val timeQuality: TimeQuality,
    val priority: Priority,             // canonical frozen code byte, bound into the signature
    val bodyUtf8: ByteArray,            // <= 400 bytes, well-formed UTF-8 (verified)
    val signedPlaintext: ByteArray,     // unsigned || signature64 -- msgID is derived OVER these bytes
) {
    /** msgID = the FROZEN MessageId.derive over the signed plaintext; no circular inclusion. */
    val msgId: ByteArray = MessageId.derive(senderNodeId, createdAtEpochSeconds, messageNonce, signedPlaintext)
}

/** Typed verification failure -- the receiver loop never sees an exception from this path. */
sealed class SenderVerificationResult {
    class Verified(val message: VerifiedApplicationMessage) : SenderVerificationResult()
    class Invalid(val reason: String) : SenderVerificationResult()
    val isValid: Boolean get() = this is Verified
}

/**
 * SignedMessageV1 (section 15), the application payload inside the EXISTING 29-byte
 * sealed prefix and sealed-sender layer:
 *
 *     unsigned         = version1(0x01) || senderIdentityPub32 || recipientNodeId16
 *                     || timeQuality1 || bodyLength_u16_be || bodyUtf8[bodyLength]
 *     signature        = Ed25519.sign(senderIdentityPriv,
 *                        ASCII("GMP2-SIGNED-MESSAGE-V1")
 *                     || senderNodeId16 || recipientNodeId16
 *                     || messageNonce16 || createdAt_u32_le || priorityCode1 || unsigned)
 *     signedPlaintext  = unsigned || signature64
 *     sealed_inner     = messageNonce16 || powNonce8 || createdAt_u32_le
 *                     || priorityCode1 || signedPlaintext
 *     msgID            = MessageId.derive(senderNodeId, createdAt, messageNonce, signedPlaintext)
 *
 * The signature EXCLUDES the PoW nonce (no circular search dependence); the outer
 * MessageId formula is unchanged; cryptographic possession identifies a key, not a
 * person's name or emergency-service authority; no automatic human-verification claim.
 */
object SignedMessageV1 {

    const val VERSION: Int = 0x01
    const val PUB_LEN: Int = 32
    const val SIG_LEN: Int = 64
    const val NODE_LEN: Int = 16
    const val NONCE_LEN: Int = 16
    const val BODY_MAX: Int = 400            // section15 row 41: 400 UTF8 bytes fit the minimum record budget
    const val DOMAIN_SEPARATOR_TEXT: String = "GMP2-SIGNED-MESSAGE-V1"
    private val DOMAIN_BYTES: ByteArray = DOMAIN_SEPARATOR_TEXT.toByteArray(Charsets.US_ASCII)

    // ---- authoring ----------------------------------------------------------------------

    /** unsigned = version1 || pub32 || recipient16 || timeQuality1 || bodyLength_u16_be || body */
    fun buildUnsigned(senderIdentityPub: ByteArray, recipientNodeId: ByteArray, timeQuality: TimeQuality, bodyUtf8: ByteArray): ByteArray {
        require(senderIdentityPub.size == PUB_LEN) { "senderIdentityPub must be 32 bytes" }
        require(recipientNodeId.size == NODE_LEN) { "recipientNodeId must be 16 bytes" }
        require(bodyUtf8.size <= BODY_MAX) { "body exceeds the 400-byte documented budget" }
        require(isWellFormedUtf8(bodyUtf8)) { "body must be well-formed UTF-8" }
        val out = ByteArray(1 + PUB_LEN + NODE_LEN + 1 + 2 + bodyUtf8.size)
        var i = 0
        out[i++] = VERSION.toByte()
        senderIdentityPub.copyInto(out, i); i += PUB_LEN
        recipientNodeId.copyInto(out, i); i += NODE_LEN
        out[i++] = timeQuality.code.toByte()
        out[i++] = (bodyUtf8.size ushr 8).toByte()
        out[i++] = (bodyUtf8.size and 0xFF).toByte()
        bodyUtf8.copyInto(out, i)
        return out
    }

    /**
     * The signature preimage: DOMAIN || senderNodeId16 || recipientNodeId16 || messageNonce16
     * || createdAt_u32_le || priorityCode1 || unsigned. The PoW nonce is deliberately absent
     * (signature excludes it to avoid circular search dependence).
     */
    fun signaturePreimage(senderNodeId: ByteArray, recipientNodeId: ByteArray, messageNonce: ByteArray,
                          createdAtEpochSeconds: Long, priorityCode: Int, unsigned: ByteArray): ByteArray {
        require(senderNodeId.size == NODE_LEN) { "senderNodeId must be 16 bytes" }
        require(recipientNodeId.size == NODE_LEN) { "recipientNodeId must be 16 bytes" }
        require(messageNonce.size == NONCE_LEN) { "messageNonce must be 16 bytes" }
        require(priorityCode in 0..4) { "priorityCode must be a canonical frozen Priority code" }
        val le = MessageId.uint32Le(createdAtEpochSeconds)
        return ByteArray(DOMAIN_BYTES.size + NODE_LEN + NODE_LEN + NONCE_LEN + 4 + 1 + unsigned.size).also { out ->
            var i = 0
            DOMAIN_BYTES.copyInto(out, i); i += DOMAIN_BYTES.size
            senderNodeId.copyInto(out, i); i += NODE_LEN
            recipientNodeId.copyInto(out, i); i += NODE_LEN
            messageNonce.copyInto(out, i); i += NONCE_LEN
            le.copyInto(out, i); i += 4
            out[i++] = priorityCode.toByte()
            unsigned.copyInto(out, i)
        }
    }

    /**
     * Author a signed plaintext (the bytes placed after the 29-byte sealed prefix).
     * The lab profile enables DIRECT authoring only; SOS keeps its separate signed format
     * and GROUP/BROADCAST need a separately accepted design. Unknown time binds
     * createdAt 0 with TimeQuality.UNKNOWN -- the two fields stand and fall together.
     */
    fun author(senderIdentityPriv: ByteArray, senderIdentityPub: ByteArray, senderNodeId: ByteArray,
               recipientNodeId: ByteArray, messageNonce: ByteArray, createdAtEpochSeconds: Long,
               priority: Priority, timeQuality: TimeQuality, bodyUtf8: ByteArray): ByteArray {
        require(priority == Priority.DIRECT) { "the lab profile enables DIRECT authoring only" }
        require((createdAtEpochSeconds == 0L) == (timeQuality == TimeQuality.UNKNOWN)) {
            "unknown time binds createdAt 0 with timeQuality UNKNOWN; the two fields stand and fall together"
        }
        val unsigned = buildUnsigned(senderIdentityPub, recipientNodeId, timeQuality, bodyUtf8)
        val preimage = signaturePreimage(senderNodeId, recipientNodeId, messageNonce, createdAtEpochSeconds, priority.code, unsigned)
        val signature = Ed25519Keys.sign(preimage, senderIdentityPriv)
        require(signature.size == SIG_LEN) { "Ed25519 must produce a 64-byte signature" }
        return unsigned + signature
    }

    // ---- receiving ------------------------------------------------------------------------

    /**
     * Verify a signed plaintext against the FROZEN binding laws. Returns a typed result;
     * never throws out of the receiver loop. Rejects BEFORE any inbox/ACK admission:
     * exact length, version, well-formed UTF-8, the time-quality binding, the canonical
     * priority, the sender-id/key binding (senderNodeId == BLAKE2s128(pub)), the intended
     * local recipient equality, and finally the Ed25519 signature over the domain preimage.
     */
    fun verify(signedPlaintext: ByteArray, senderNodeId: ByteArray, recipientLocalNodeId: ByteArray,
               messageNonce: ByteArray, createdAtEpochSeconds: Long, priorityCode: Int): SenderVerificationResult {
        if (senderNodeId.size != NODE_LEN) return SenderVerificationResult.Invalid("senderNodeId must be 16 bytes")
        if (recipientLocalNodeId.size != NODE_LEN) return SenderVerificationResult.Invalid("recipient local id must be 16 bytes")
        if (messageNonce.size != NONCE_LEN) return SenderVerificationResult.Invalid("messageNonce must be 16 bytes")
        if (priorityCode !in 0..4) return SenderVerificationResult.Invalid("priorityCode is not a canonical frozen Priority code")
        val priority = Priority.fromCode(priorityCode) ?: return SenderVerificationResult.Invalid("priorityCode is not a canonical frozen Priority code")
        // exact length: 1 + 32 + 16 + 1 + 2 + body + 64
        if (signedPlaintext.size < 1 + PUB_LEN + NODE_LEN + 1 + 2 + SIG_LEN) return SenderVerificationResult.Invalid("signed plaintext shorter than the fixed layout")
        var i = 0
        if (signedPlaintext[i].toInt() and 0xFF != VERSION) return SenderVerificationResult.Invalid("unknown version; there is no legacy plaintext fallback")
        i += 1
        val senderIdentityPub = signedPlaintext.copyOfRange(i, i + PUB_LEN); i += PUB_LEN
        val embeddedRecipient = signedPlaintext.copyOfRange(i, i + NODE_LEN); i += NODE_LEN
        val tqCode = signedPlaintext[i].toInt() and 0xFF; i += 1
        val timeQuality = TimeQuality.fromCode(tqCode) ?: return SenderVerificationResult.Invalid("timeQuality is not a closed enum code")
        val bodyLength = ((signedPlaintext[i].toInt() and 0xFF) shl 8) or (signedPlaintext[i + 1].toInt() and 0xFF); i += 2
        if (bodyLength > BODY_MAX) return SenderVerificationResult.Invalid("bodyLength exceeds the documented 400-byte budget")
        val expectedTotal = 1 + PUB_LEN + NODE_LEN + 1 + 2 + bodyLength + SIG_LEN
        if (signedPlaintext.size != expectedTotal) return SenderVerificationResult.Invalid("bodyLength does not match the actual tail; the frame is not exact")
        val body = signedPlaintext.copyOfRange(i, i + bodyLength)
        val signature = signedPlaintext.copyOfRange(i + bodyLength, i + bodyLength + SIG_LEN)
        if (!isWellFormedUtf8(body)) return SenderVerificationResult.Invalid("body is not well-formed UTF-8")
        // the unknown-time binding law: zero time stands with UNKNOWN quality and vice versa
        if ((createdAtEpochSeconds == 0L) != (timeQuality == TimeQuality.UNKNOWN)) {
            return SenderVerificationResult.Invalid("createdAt and timeQuality are not bound (unknown time uses 0/UNKNOWN together)")
        }
        // sender-id / key binding: the id must be the BLAKE2s128 image of the key (possession is not proclamation)
        if (!nodeIdMatches(senderNodeId, senderIdentityPub)) return SenderVerificationResult.Invalid("senderNodeId is not BLAKE2s128(senderIdentityPub)")
        // intended local recipient: a valid signature over the WRONG recipient is still the wrong recipient
        if (!recipientLocalNodeId.contentEquals(embeddedRecipient)) {
            return SenderVerificationResult.Invalid("embedded recipientNodeId differs from the intended local recipient")
        }
        val unsigned = signedPlaintext.copyOfRange(0, 1 + PUB_LEN + NODE_LEN + 1 + 2 + bodyLength)
        val preimage = signaturePreimage(senderNodeId, embeddedRecipient, messageNonce, createdAtEpochSeconds, priorityCode, unsigned)
        val ok = try { Ed25519Keys.verify(preimage, signature, senderIdentityPub) } catch (_e: Throwable) { false }
        if (!ok) return SenderVerificationResult.Invalid("signature does not verify over the domain preimage")
        val message = VerifiedApplicationMessage(
            senderNodeId = senderNodeId.copyOf(),
            senderIdentityPub = senderIdentityPub.copyOf(),
            recipientNodeId = embeddedRecipient.copyOf(),
            messageNonce = messageNonce.copyOf(),
            createdAtEpochSeconds = createdAtEpochSeconds,
            timeQuality = timeQuality,
            priority = priority,
            bodyUtf8 = body.copyOf(),
            signedPlaintext = signedPlaintext.copyOf(),
        )
        return SenderVerificationResult.Verified(message)
    }

    /** The frozen binding from Identity.kt, copied VERBATIM in formula: node_id = BLAKE2s-128(identityPub). */
    fun nodeIdOf(identityPub: ByteArray): ByteArray {
        require(identityPub.size == PUB_LEN) { "identityPub must be 32 bytes" }
        val d = Blake2sDigest(null, 16, null, null)
        d.update(identityPub, 0, identityPub.size)
        val out = ByteArray(16)
        d.doFinal(out, 0)
        return out
    }

    private fun nodeIdMatches(senderNodeId: ByteArray, identityPub: ByteArray): Boolean =
        try { nodeIdOf(identityPub).contentEquals(senderNodeId) } catch (_e: Throwable) { false }

    // ---- sealed DH input guard -------------------------------------------------------------

    /**
     * Reject policy for X25519 public inputs before any agreement runs (section15 row 5:
     * malformed DH/public keys cannot throw out of the receiver loop). The all-zero encoding
     * is the identity (low-order) element; u >= p (2^255 - 19) is a non-canonical field
     * encoding; a set high bit on an otherwise-zero tail is the classic small-order probe
     * encoding. None of these seals a real shared secret; accepting one is a hostile downgrade
     * of the sealed layer, so they are refused fail-closed rather than passed downward.
     */
    fun acceptableSealedDhPublicKey(pub: ByteArray): Boolean {
        if (pub.size != PUB_LEN) return false
        var allZero = true
        for (b in pub) if (b.toInt() and 0xFF != 0) { allZero = false; break }
        if (allZero) return false                                                   // identity element: low order, refuse
        if (pub[31].toInt() and 0x80 != 0) return false                            // sign/masking bit must be clear in a canonical encoding
        // non-canonical field encodings: the little-endian value must be BELOW p = 2^255 - 19,
        // whose masked top byte is 0x7F and whose bytes 1..30 are all 0xFF with byte 0 = 0xED.
        if ((pub[31].toInt() and 0xFF) == 0x7F) {
            for (j in 30 downTo 1) if ((pub[j].toInt() and 0xFF) != 0xFF) return true    // a lower byte at a more significant position drops u below p
            if ((pub[0].toInt() and 0xFF) >= 0xED) return false                            // u >= p: non-canonical, refuse
        }
        return true
    }

    // ---- UTF-8 validation --------------------------------------------------------------------

    /** Strict well-formedness: no surrogates, no overlongs, no truncated sequences, cap at U+10FFFF. */
    fun isWellFormedUtf8(bytes: ByteArray): Boolean {
        var i = 0
        while (i < bytes.size) {
            val b0 = bytes[i].toInt() and 0xFF
            val len = when {
                b0 < 0x80 -> 1
                b0 in 0xC2..0xDF -> 2       // overlong 2-byte (C0/C1) excluded by range
                b0 in 0xE0..0xEF -> 3
                b0 in 0xF0..0xF4 -> 4       // above U+10FFFF excluded (F5..F7 rejected)
                else -> return false        // includes ASCII continuation bytes, C0/C1, F5+ and 0xF8+
            }
            if (i + len > bytes.size) return false
            for (k in 1 until len) {
                val bk = bytes[i + k].toInt() and 0xFF
                if (bk !in 0x80..0xBF) return false
            }
            if (len == 3) {
                val b1 = bytes[i + 1].toInt() and 0xFF
                if (b0 == 0xE0 && b1 < 0xA0) return false      // overlong 3-byte
                if (b0 == 0xED && b1 in 0xA0..0xBF) return false // surrogates D800..DFFF excluded
            }
            if (len == 4) {
                val b1 = bytes[i + 1].toInt() and 0xFF
                if (b0 == 0xF0 && b1 < 0x90) return false       // overlong 4-byte
                if (b0 == 0xF4 && b1 > 0x8F) return false        // above U+10FFFF
            }
            i += len
        }
        return true
    }

    /** Convenience: a 32-byte Ed25519 public key plus its derived 16-byte node id. */
    fun identityKeyMaterial(publicKey: ByteArray): Pair<ByteArray, ByteArray> {
        val pub = publicKey.copyOf()
        return Pair(pub, nodeIdOf(pub))
    }
}
