package io.godstone.app.trust

// ---------------------------------------------------------------------------
// T55 -- the QR / binding payload policy.
//
// A QR payload arriveth from a camera, so it is UNTRUSTED INPUT, and the card
// requireth that "QR decoding is size/type bounded". Bounds here:
//
//   * a versioned PREFIX (`godstone-binding:v1:`), refused by name when absent,
//     so a random QR is a typed refusal and never a parse attempt;
//   * a strict CHARACTER SET (base64url) and a MAXIMUM length, so an oversized
//     payload is refused BEFORE it is decoded (no allocation on hostile input);
//   * an exact DECODED length (node id 16 + static DH key 32 + signature 64),
//     so a truncated or padded payload is refused rather than partially applied;
//   * NO private material is ever accepted: the payload carrieth a node id, a
//     static DH PUBLIC key and a self-signature, and nothing else.
//
// The parser returneth a typed result; it never throweth and never logs.
// ---------------------------------------------------------------------------

/** A parsed, bounded recipient binding. Public material only. */
data class ParsedBindingPayload(
    val nodeId: ByteArray,
    val staticDhPublicKey: ByteArray,
    val signature: ByteArray,
    val version: Int,
) {
    init {
        require(nodeId.size == 16)
        require(staticDhPublicKey.size == 32)
        require(signature.size == 64)
    }
}

sealed class QrParseResult {
    data class Parsed(val binding: ParsedBindingPayload) : QrParseResult()
    data class Refused(val reason: String) : QrParseResult()
}

object QrPayloadPolicy {
    /** The versioned prefix a binding payload must carry. */
    const val PREFIX: String = "godstone-binding:v1:"

    /** The largest payload the policy will LOOK AT, prefix included. */
    const val MAX_PAYLOAD_CHARS: Int = 512

    /** The exact decoded width: 16 (node) + 32 (static DH pub) + 64 (signature). */
    const val EXPECTED_BYTES: Int = 112

    private val BASE64URL = Regex("^[A-Za-z0-9_-]+$")

    /** True iff [payload] is even worth parsing (size and prefix only). */
    fun isWellFormed(payload: String): Boolean =
        payload.length <= MAX_PAYLOAD_CHARS && payload.startsWith(PREFIX)

    /** Parse a scanned payload into bounded public material, or refuse by name. */
    fun parse(payload: String): QrParseResult {
        if (payload.isEmpty()) {
            return QrParseResult.Refused("the payload is empty")
        }
        if (payload.length > MAX_PAYLOAD_CHARS) {
            return QrParseResult.Refused(
                "the payload is ${payload.length} characters, over the $MAX_PAYLOAD_CHARS bound",
            )
        }
        if (!payload.startsWith(PREFIX)) {
            return QrParseResult.Refused("the payload carrieth no $PREFIX prefix")
        }
        val body = payload.removePrefix(PREFIX)
        if (body.isEmpty()) {
            return QrParseResult.Refused("the payload carrieth no body after the prefix")
        }
        if (!BASE64URL.matches(body)) {
            return QrParseResult.Refused("the payload body is not base64url: wrong type or charset")
        }
        val decoded = try {
            base64UrlDecode(body)
        } catch (_e: IllegalArgumentException) {
            return QrParseResult.Refused("the payload body is not decodable base64url")
        }
        if (decoded.size != EXPECTED_BYTES) {
            return QrParseResult.Refused(
                "the payload decodeth to ${decoded.size} octets, not the required $EXPECTED_BYTES",
            )
        }
        val nodeId = decoded.copyOfRange(0, 16)
        val staticDh = decoded.copyOfRange(16, 48)
        val signature = decoded.copyOfRange(48, 112)
        // a node id of all zeros is not an identity any authority could have
        // minted: refuse rather than import a placeholder
        if (nodeId.all { it == 0.toByte() }) {
            return QrParseResult.Refused("the payload carrieth an all-zero node id")
        }
        if (staticDh.all { it == 0.toByte() }) {
            return QrParseResult.Refused("the payload carrieth an all-zero static key")
        }
        return QrParseResult.Parsed(
            ParsedBindingPayload(nodeId, staticDh, signature, version = 1),
        )
    }

    /** The canonical payload for [nodeId], [staticDhPublicKey] and [signature]. */
    fun render(nodeId: ByteArray, staticDhPublicKey: ByteArray, signature: ByteArray): String {
        require(nodeId.size == 16) { "a binding carrieth a 16-octet node id" }
        require(staticDhPublicKey.size == 32) { "a binding carrieth a 32-octet static key" }
        require(signature.size == 64) { "a binding carrieth a 64-octet signature" }
        return PREFIX + base64UrlEncode(nodeId + staticDhPublicKey + signature)
    }

    // ---- base64url, unpadded, stdlib only -------------------------------------

    private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    private fun base64UrlEncode(bytes: ByteArray): String {
        val sb = StringBuilder()
        var i = 0
        while (i < bytes.size) {
            val b0 = bytes[i].toInt() and 0xFF
            val b1 = if (i + 1 < bytes.size) bytes[i + 1].toInt() and 0xFF else -1
            val b2 = if (i + 2 < bytes.size) bytes[i + 2].toInt() and 0xFF else -1
            sb.append(ALPHABET[b0 ushr 2])
            sb.append(ALPHABET[((b0 and 0x03) shl 4) or (if (b1 >= 0) b1 ushr 4 else 0)])
            if (b1 >= 0) {
                sb.append(ALPHABET[((b1 and 0x0F) shl 2) or (if (b2 >= 0) b2 ushr 6 else 0)])
            }
            if (b2 >= 0) sb.append(ALPHABET[b2 and 0x3F])
            i += 3
        }
        return sb.toString()
    }

    private fun base64UrlDecode(text: String): ByteArray {
        val out = ArrayList<Byte>(text.length * 3 / 4 + 3)
        var buffer = 0
        var bits = 0
        for (c in text) {
            val v = ALPHABET.indexOf(c)
            if (v < 0) throw IllegalArgumentException("not base64url")
            buffer = (buffer shl 6) or v
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out.add(((buffer ushr bits) and 0xFF).toByte())
            }
        }
        return out.toByteArray()
    }
}
