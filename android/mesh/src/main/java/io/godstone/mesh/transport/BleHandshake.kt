package io.godstone.mesh.transport

import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import java.security.SecureRandom

/**
 * T23 (section 13): the typed vocabulary of the handshake failure, duplicate
 * and key-confirmation policy. The instruments that stand here are each of
 * them a servant of the relation that owns them: the stage projection the
 * connection weareth, the transcript that remembereth what hath already been
 * told as a whole frame, the hour-glass that telleth the moment a half-spoken
 * exchange must fall, and the sealed key-confirmation of a trusted hour.
 *
 * Nothing here mutateth the authoritative state: the doors consult them, and
 * the owners hands alone close a relation. A refusal never corrupteth a
 * standing truth - the previous authoritative state is preserved, or the
 * relation reacheth its specified terminal state.
 */

/**
 * The projection of section thirteens progression, worn beside the lifecycle
 * state so the drivers effect may be traced without a second mutable ready
 * flag. The lifecycle state is the authority; this is its shadow, and it
 * stoppeth short of KEY_CONFIRMED and APPLICATION_LINK_READY until the sealed
 * key-confirmation round is proved by its echo.
 */
enum class HandshakeStage {
    /** No relation of record. */
    IDLE,

    /** The LinkInfo exchange hath bound the seat; the hour-glass is armed. */
    ROLE_BOUND,

    /** The half hath spoken its opening counsel (the first, or the second). */
    HS_OUT,

    /** The half hath heard its counsel and answered; it awaiteth the last. */
    HS_IN,

    /** The controller reporteth the slot cryptographically ready. */
    TRUSTED_CRYPTO_READY,

    /** The sealed key-confirmation echo matched the standing challenge. */
    KEY_CONFIRMED,

    /** The application LinkReady hath been published, exactly once. */
    APPLICATION_LINK_READY,
}

/**
 * T23: the typed connection dispatch violations that D2 must OBSERVE and
 * CLOSE, raised before the silent stage filter of the reassembler would
 * swallow an out-of-place handshake record. Each is a distinct fall of the
 * law; each is recorded, bounded, and answereth by the exact relation
 * falling through its owners hand.
 */
enum class HandshakeDispatchViolation {
    /** A handshake record of any kind seen once the relation is trusted. */
    UNSOLICITED_HS_AFTER_READY,

    /** The respondent spake its own second aloud at the responders gate. */
    OWN_VOICE_AT_THE_GATE,

    /** The whole of the counsel is out of order at the door. */
    OUT_OF_ORDER_COUNSEL,

    /** A challenge came back that was the very one this side standeth upon. */
    REFLECTED_CHALLENGE,

    /** An echo that matched none standing, of this relation or of an elder. */
    FORGED_OR_STALE_ECHO,

    /** The hour-glass of the handshake ran out before the trust was whole. */
    HANDSHAKE_DEADLINE_LAPSED,

    /** The confirming hour ran out unanswered: the challenge went abroad and no
     *  echo ever came home to settle it. A distinct lapse from the handshake
     *  hour above, that an audit may tell the two twain apart. */
    KEY_CONFIRMATION_DEADLINE_LAPSED,
}

/** A heard dispatch violation, recorded for the courts sight. */
data class HandshakeDispatchRecord(val peerId: ByteArray, val site: String, val kind: HandshakeDispatchViolation) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is HandshakeDispatchRecord) return false
        return peerId.contentEquals(other.peerId) && site == other.site && kind == other.kind
    }

    override fun hashCode(): Int {
        var h = peerId.contentHashCode()
        h = 31 * h + site.hashCode()
        h = 31 * h + kind.hashCode()
        return h
    }
}

/**
 * The bounded transcript of whole frames this relation hath already SPOKEN
 * AND HEARD complete - keyed not by the kind alone but by the FULL frame
 * identity (kind, sequence, bytes). This is the very letter of section
 * thirteen: "exact duplicate bytes ... are ignored; conflicting duplicates
 * or out-of-order stages close." An exact re-delivery of the selfsame frame
 * is an idle re-telling and is hearkened not, and the controller is never run
 * for it a second time; a re-telling under an other sequence, or with other
 * bytes, is a CONFLICT and the relation falleth.
 *
 * It supplieth a need the reassembler cannot: the reassembler collapseth
 * repeated FRAGMENTS within one sequence; the transcript here is the whole
 * record as it is presented at the door, so that a re-presented whole record
 * - though it be a fresh assembly - never runneth the Noise controller the
 * second time. It is bounded: the eldest memory giveth way, that no
 * adversary may swell it.
 */
class TranscriptCache(private val capacity: Int = FRAME_CAPACITY) {
    private val lock = Any()
    private val heard: HashMap<Int, ArrayDeque<Int>> = HashMap()
    private var overflow: Int = 0

    init {
        require(capacity > 0) { "the transcript must keep at least one counsel of a kind" }
    }

    /** The mark of a whole frame, of its kind, its sequence and its bytes
     *  alone - never of any address, clock or station. The sequence is part
     *  of the identity so that a re-telling of the selfsame tale under an
     *  OTHER sequence is NO exact duplicate and falleth to the doors stage
     *  law as ever; onely the byte-for-byte, sequence-for-sequence frame is
     *  the idle re-presenting this transcript hearkeneth not. */
    private fun fingerprint(kind: Int, sequence: Int, payload: ByteArray): Int {
        var h: Int = 0x811C9DC4.toInt()
        h = (h xor kind) * 0x01000193
        h = (h xor sequence) * 0x01000193
        for (b in payload) h = (h xor (b.toInt() and 0xFF)) * 0x01000193
        return h
    }

    /** Whether this very frame was already spoken and heard whole: the doors
     *  aske it at the mouth of each arm, and a known frame is hearkened not
     *  (the controller is never run again for it), it standeth. */
    fun knows(kind: Int, sequence: Int, payload: ByteArray): Boolean = synchronized(lock) {
        heard[kind]?.contains(fingerprint(kind, sequence, payload)) == true
    }

    /** The doors, at the health of a counsel through the controller, record
     *  it here that a selfsame frame re-presented be known. Idempotent: a
     *  frame twice remembred is kept but once. */
    fun remember(kind: Int, sequence: Int, payload: ByteArray) = synchronized(lock) {
        val mark = fingerprint(kind, sequence, payload)
        val kept = heard[kind]
        if (kept == null) {
            heard.put(kind, ArrayDeque<Int>().apply { addLast(mark) })
            return@synchronized
        }
        if (kept.contains(mark)) return@synchronized
        if (kept.size >= capacity) { kept.removeFirst(); overflow += 1 }
        kept.addLast(mark)
    }

    /** The number of tales remembered of one kind, that a court may count. */
    internal fun heardCountForTest(kind: Int): Int = synchronized(lock) { heard[kind]?.size ?: 0 }

    /** The number of eldest tales that gave way to make room. */
    internal fun overflowCountForTest(): Int = synchronized(lock) { overflow }

    /** Whether the transcript keepeth nothing at all. */
    internal fun isEmptyForTest(): Boolean = synchronized(lock) {
        heard.values.all { it.isEmpty() }
    }

    /** The relations hand, at its fall or fresh course, forgetteth all. */
    internal fun forgetAll() = synchronized(lock) {
        heard.clear()
        overflow = 0
    }

    companion object {
        const val FRAME_CAPACITY = 16
    }
}

/**
 * The ten-second monotonic hour-glass of the handshake, turn'd upon the role
 * binding and stopt at the trusted hour. It answereth by predicate, never by
 * wall; a stale lookup of the present hour can not lengthen it, and a
 * re-delivered event can not shorten it.
 */
class HandshakeDeadline(
    private val now: () -> Long,
    private val seconds: Long = HANDSECONDS
) {
    private val lock = Any()
    private var armedMono: Long = UNARMED
    private var fired: Boolean = false

    /** The seat is bound; the glass is turn'd. It is armed but once; a
     *  redundant binding findeth it already turn'd and spareth the first hour. */
    fun arm() = synchronized(lock) {
        if (armedMono == UNARMED) {
            armedMono = now() + seconds
        }
    }

    /** The trusted hour is come; the glass is stopt and may never fell a
     *  relation that is already trusted. */
    fun stop() = synchronized(lock) {
        armedMono = STOPPED
    }

    /** The relation is torn down; the glass is wound again to unturn'd, that
     *  a fresh binding of the selfsame station may turn it afresh. */
    fun reset() = synchronized(lock) {
        armedMono = UNARMED
        fired = false
    }

    /** Is the glass spent, with the hour yet to come? A stopt or unturn'd
     *  glass answereth false. */
    fun expired(): Boolean = synchronized(lock) {
        armedMono != UNARMED && armedMono != STOPPED && now() >= armedMono
    }

    /** The hour the glass was set to, for the courts inspection: -1 unturn'd,
     *  -2 stopt. */
    internal fun armedMonoForTest(): Long = synchronized(lock) { armedMono }

    /** Whether the glass was ever spent. */
    internal fun hasFiredForTest(): Boolean = synchronized(lock) { fired }

    /** The owners hand, at the fall, marketh the glass spent, that the trace
     *  may name it once. */
    internal fun markFired() = synchronized(lock) { fired = true }

    companion object {
        const val HANDSECONDS: Long = 10L
        const val UNARMED: Long = -1L
        const val STOPPED: Long = -2L
    }
}

/**
 * The standing key-confirmation of one half: the challenge it sent and hath
 * not yet seen echoed, and the hour past which a missing echo is a failure.
 * Each half keepeth one; the echo must match THIS relations challenge, so an
 * echo of an elder relation, or a forged echo, findeth no mate.
 */
class KeyConfirmation(
    private val now: () -> Long,
    private val seconds: Long = ECHOSECONDS
) {
    private val lock = Any()
    private var ourChallenge: ByteArray? = null
    private var issuedMono: Long = UNISSUED
    private var confirmed: Boolean = false

    /** Whether the sealed round of this half is whole: an echo matched the
     *  standing challenge. The truth of KEY_CONFIRMED dwelleth here, in the
     *  projection, and nowher as a parallel ready flag upon the station. */
    val isConfirmed: Boolean get() = synchronized(lock) { confirmed }

    /** The owners hand, at the proving of an authenticated echo that matched
     *  the standing challenge, recordeth the sealed round as whole. It is the
     *  authors sole path to confirmation; the challenge is spent at the
     *  selfsame breath, that no echo may win a selfsame publication twice. */
    internal fun confirmExternally() = synchronized(lock) {
        ourChallenge = null
        confirmed = true
    }

    companion object {
        /** The length of a key-confirmation challenge, of section thirteen. */
        const val CHALLENGE_BYTES = 16

        /** The echo must come within half a minute of the challenge. */
        const val ECHOSECONDS: Long = 30L

        /** The version octet of the key-confirmation payload. */
        const val KEY_CONFIRMATION_VERSION: Byte = 0x01

        /** The mode of a challenge, and of its echo. */
        const val MODE_CHALLENGE: Byte = 0x00
        const val MODE_RESPONSE: Byte = 0x01

        const val UNISSUED: Long = -1L
    }

    /** A new challenge is taken upon the old; the elder is forgotten whole. */
    fun issue(challenge: ByteArray) = synchronized(lock) {
        require(challenge.size == CHALLENGE_BYTES) { "the key-confirmation challenge must be sixteen octets" }
        ourChallenge = challenge.copyOf()
        issuedMono = now()
    }

    /** The challenge the half standeth upon, or null when none is abroad. */
    fun outstanding(): ByteArray? = synchronized(lock) { ourChallenge?.copyOf() }

    /** Whether the echo matcheth the standing challenge, and is not yet
     *  spent. A match consumeth the standing, that no second echo may win a
     *  selfsame publication. */
    fun matchesAndConsume(echo: ByteArray): Boolean = synchronized(lock) {
        val standing = ourChallenge ?: return@synchronized false
        if (echo.size != CHALLENGE_BYTES || standing.size != CHALLENGE_BYTES) return@synchronized false
        var diff = 0
        for (i in 0 until CHALLENGE_BYTES) {
            diff = diff or (echo[i].toInt() xor standing[i].toInt())
        }
        if (diff != 0) return@synchronized false
        ourChallenge = null
        confirmed = true
        return@synchronized true
    }

    /** The echo is past its hour. */
    fun echoLapsed(): Boolean = synchronized(lock) {
        ourChallenge != null && issuedMono != UNISSUED && now() >= issuedMono + seconds
    }

    /** A challenge goeth abroad and no echo hath yet matched it: the half doth
     *  AWAIT the peers echo. It is the witness that the round is a-comming, and
     *  the trigger of the key-confirmation timeout of section thirteen. */
    fun isAwaitingEcho(): Boolean = synchronized(lock) {
        ourChallenge != null && !confirmed
    }

    /** The half hath spoken no challenge; the trace may rest. */
    fun clear() = synchronized(lock) {
        ourChallenge = null
        issuedMono = UNISSUED
        confirmed = false
    }

    fun isIdle(): Boolean = synchronized(lock) { ourChallenge == null }
}

/**
 * T23 (section 13): the sealed key-confirmation round, carried INSIDE the
 * existing PING frame of the wire - never a fourth Noise message, never
 * persisted, never forwarded by the router. A control frame is the very
 * plaintext of an ordinary trusted DATA record: it is sealed by the selfsame
 * session the third counsel established, fragmented and pump'd by the
 * selfsame whole-record writer, and opened again by the selfsame collector.
 * D2 onely RECOGNISETH it by its shape and answereth it.
 *
 * The shape, of section thirteens own words: a PING frame whose payload is
 * [version = 1, mode, challenge(16)], where mode 0 is a challenge and 1 its
 * echo; TTL 0, hop 0, no priority, no ACK-REQUEST, no SEALED flag - a control
 * frame claimeth none of the application planes.
 */
object KeyConfirmationControl {
    const val PROTOCOL_VERSION: Int = 0x01
    const val MODE_CHALLENGE: Int = 0x00
    const val MODE_RESPONSE: Int = 0x01
    const val CHALLENGE_BYTES: Int = 16
    private const val PAYLOAD_BYTES: Int = 2 + CHALLENGE_BYTES
    private const val MSG_ID_BYTES: Int = 16

    /** One fresh CSPRNG challenge: sixteen unpredictable octets. */
    fun newChallenge(): ByteArray = randomOctets(CHALLENGE_BYTES)

    /** One fresh control message identifier: sixteen octets, distinct ever. */
    private fun newMessageId(): ByteArray = randomOctets(MSG_ID_BYTES)

    private fun randomOctets(count: Int): ByteArray {
        val out = ByteArray(count)
        SecureRandom().nextBytes(out)
        return out
    }

    fun encodeChallenge(challenge: ByteArray): ByteArray =
        encode(MODE_CHALLENGE, challenge)

    fun encodeResponse(challenge: ByteArray): ByteArray =
        encode(MODE_RESPONSE, challenge)

    private fun encode(mode: Int, challenge: ByteArray): ByteArray {
        require(challenge.size == CHALLENGE_BYTES) { "the key-confirmation challenge must be sixteen octets" }
        require(mode == MODE_CHALLENGE || mode == MODE_RESPONSE) { "the key-confirmation mode is none of challenge or response" }
        val payload = ByteArray(PAYLOAD_BYTES)
        payload[0] = PROTOCOL_VERSION.toByte()
        payload[1] = mode.toByte()
        for (i in 0 until CHALLENGE_BYTES) {
            payload[2 + i] = challenge[i]
        }
        return FrameV2(
            type = TypeV2.PING,
            msgId = newMessageId(),
            routingTag = ByteArray(4),
            ttl = 0,
            hopCount = 0,
            flags = 0,
            payload = payload
        ).encode()
    }

    /**
     * The strict shape of section thirteen. It returneth the parsed challenge
     * and its mode, or null when the opened plaintext is not a key-confirmation
     * control - every ordinary application frame, and every corrupted one,
     * answereth null and travelleth on to the application undisturb'd.
     */
    fun parse(opened: ByteArray): KeyConfirmationFrame? {
        val frame = FrameV2.decode(opened) ?: return null
        if (frame.type != TypeV2.PING) return null
        if (frame.ttl != 0 || frame.hopCount != 0) return null
        if (frame.flags != 0) return null
        val payload = frame.payload
        if (payload.size != PAYLOAD_BYTES) return null
        if (payload[0].toInt() and 0xFF != PROTOCOL_VERSION) return null
        val mode = payload[1].toInt() and 0xFF
        if (mode != MODE_CHALLENGE && mode != MODE_RESPONSE) return null
        val challenge = payload.copyOfRange(2, PAYLOAD_BYTES)
        return KeyConfirmationFrame(mode = mode, challenge = challenge)
    }
}

/** A parsed key-confirmation control frame: its mode and its sixteen-octet challenge. */
data class KeyConfirmationFrame(val mode: Int, val challenge: ByteArray) {
    val isChallenge: Boolean get() = mode == KeyConfirmationControl.MODE_CHALLENGE
    val isResponse: Boolean get() = mode == KeyConfirmationControl.MODE_RESPONSE

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is KeyConfirmationFrame) return false
        return mode == other.mode && challenge.contentEquals(other.challenge)
    }

    override fun hashCode(): Int = 31 * mode + challenge.contentHashCode()
}
