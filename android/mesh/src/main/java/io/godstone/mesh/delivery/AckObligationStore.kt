// T83 (android isle) -- the recipient ACK return path, section 14 of the plan.
//
// Add ack_obligations and ack_frames namespaces as section14 specifies: ACKs reuse the
// MESSAGE msgID, so the existing held_frames primary key collides; a crash between the
// inbox commit and the ACK signing would lose a reply without a durable obligation.
//
//   * ack_obligations(msg_id, recipient_node_id, identity_generation,
//     remaining_lifetime_ms, state) keyed by the FIRST TWO fields; inserted in the
//     SAME recipient inbox transaction (the store's commitInboundWithObligation);
//   * after commit the bounded worker signs via the corresponding still-valid local
//     identity (injected AckSignerSeam; the sealed AckFrame builder produces the
//     canonical frame -- the generated wire formula is NOT reimplemented here),
//     stores the exact frame row, then retires the obligation IN ONE TRANSACTION;
//   * process death at any boundary resumes it: the driver is stateless between runs
//     and re-reads the tables afresh; a key/storage failure leaves a retryable
//     obligation and produces NO claimed delivery;
//   * ack_frames(ack_key, msg_id, recipient_node_id, signature, encoded_frame,
//     received_from, remaining_lifetime_ms, verification_class) where
//     ack_key = SHA256(ASCII("GMP2-ACK-CACHE") || msg_id || recipient || signature) is
//     a LOCAL CACHE KEY ONLY -- it introduces no wire field;
//   * a MESSAGE and its ACK coexist (separate namespaces, no collision); different
//     signature candidates for one (msg_id, recipient) pair do not dedup each other;
//     bounded 4 per pair, 4096 total; known-invalid signatures under an available
//     authenticated recipient key are REJECTED (never stored); unknown-key relays
//     carry only bounded OPAQUE candidates, never labelled recipient-verified;
//     exhaustion REFUSES new custody explicitly, does not poison origin verification
//     state and does not erase original messages.
//
// Every read distinguishes ABSENT from STORAGE FAILURE from CORRUPT (section 14: no
// correctness-critical query may fabricate an empty set); every refusal names its
// cause; byte fields are defensively copied at every boundary; descriptions are
// redacted (section 5 privacy: no key material, no full payloads in logs).
package io.godstone.mesh.delivery

import io.godstone.mesh.store.AckFrameRowView
import io.godstone.mesh.store.FrameCommitOutcome
import io.godstone.mesh.store.ObligationEntryRow
import io.godstone.mesh.store.StoreDb
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2
import java.security.MessageDigest
import kotlin.text.Charsets

const val ACK_MSG_LEN: Int = 16
const val ACK_RECIPIENT_LEN: Int = 16
const val ACK_SIG_LEN: Int = 64
const val ACK_KEY_LEN: Int = 32
const val ACK_PAYLOAD_LEN: Int = 80
const val ACK_HINT_LEN: Int = 4
const val ACK_CANDIDATES_PER_PAIR_LIMIT: Int = 4
const val ACK_CANDIDATES_TOTAL_LIMIT: Int = 4096

// ------------------------------------------------------------------ persisted records

enum class AckObligationState(val code: Int) {
    PENDING(0),
    SIGNED(1);

    companion object {
        fun fromPersistedCode(code: Int): AckObligationState? = when (code) {
            0 -> PENDING
            1 -> SIGNED
            else -> null
        }
    }
}

enum class AckVerificationClass(val code: Int) {
    VERIFIED_RECIPIENT(1),
    OPAQUE_CANDIDATE(2);

    companion object {
        fun fromPersistedCode(code: Int): AckVerificationClass? = when (code) {
            1 -> VERIFIED_RECIPIENT
            2 -> OPAQUE_CANDIDATE
            else -> null
        }
    }
}

private fun bytesEqual(left: ByteArray?, right: ByteArray?): Boolean {
    if (left == null && right == null) return true
    if (left == null || right == null) return false
    return left.contentEquals(right)
}

private val HEX_DIGITS = "0123456789abcdef"

private fun redactedHex(bytes: ByteArray?): String {
    if (bytes == null) return "null"
    if (bytes.isEmpty()) return "-"
    val head = if (bytes.size <= 4) bytes.size else 4
    val tail = if (bytes.size <= 4) 0 else 4
    val sb = StringBuilder()
    for (i in 0 until head) {
        val v = bytes[i].toInt() and 0xFF
        sb.append(HEX_DIGITS[(v shr 4) and 0xF]); sb.append(HEX_DIGITS[v and 0xF])
    }
    if (tail > 0) {
        sb.append("..")
        for (i in (bytes.size - tail) until bytes.size) {
            val v = bytes[i].toInt() and 0xFF
            sb.append(HEX_DIGITS[(v shr 4) and 0xF]); sb.append(HEX_DIGITS[v and 0xF])
        }
    }
    return sb.toString()
}

/** One row of ack_obligations. Immutable; content equality; redacted description. */
class AckObligation private constructor(
    msgId: ByteArray,
    recipientNodeId: ByteArray,
    identityGeneration: Long,
    remainingLifetimeMs: Long,
    state: AckObligationState,
) {
    private val _msgId = msgId.copyOf()
    private val _recipientNodeId = recipientNodeId.copyOf()
    private val _identityGeneration: Long = identityGeneration
    private val _remainingLifetimeMs: Long = remainingLifetimeMs
    private val _state: AckObligationState = state

    val msgId: ByteArray get() = _msgId.copyOf()
    val recipientNodeId: ByteArray get() = _recipientNodeId.copyOf()
    val identityGeneration: Long get() = _identityGeneration
    val remainingLifetimeMs: Long get() = _remainingLifetimeMs
    val state: AckObligationState get() = _state

    companion object {
        fun of(
            msgId: ByteArray,
            recipientNodeId: ByteArray,
            identityGeneration: Long,
            remainingLifetimeMs: Long,
            state: AckObligationState,
        ): AckObligation? {
            if (msgId.size != ACK_MSG_LEN) return null
            if (recipientNodeId.size != ACK_RECIPIENT_LEN) return null
            if (identityGeneration < 0L) return null
            if (remainingLifetimeMs < 0L) return null
            return AckObligation(msgId, recipientNodeId, identityGeneration, remainingLifetimeMs, state)
        }
    }

    override fun equals(other: Any?): Boolean {
        if (other === this) return true
        if (other !is AckObligation) return false
        return _msgId.contentEquals(other._msgId) && _recipientNodeId.contentEquals(other._recipientNodeId) &&
            _identityGeneration == other._identityGeneration &&
            _remainingLifetimeMs == other._remainingLifetimeMs && _state == other._state
    }

    override fun hashCode(): Int {
        var h = _msgId.contentHashCode()
        h = 31 * h + _recipientNodeId.contentHashCode()
        h = 31 * h + _identityGeneration.hashCode()
        h = 31 * h + _remainingLifetimeMs.hashCode()
        h = 31 * h + _state.hashCode()
        return h
    }

    override fun toString(): String =
        "AckObligation(msg=" + redactedHex(_msgId) + ",recip=" + redactedHex(_recipientNodeId) +
            ",gen=" + _identityGeneration + ",remainingMs=" + _remainingLifetimeMs +
            ",state=" + _state.name + ")"
}

/** One row of ack_frames. Immutable; content equality; redacted description. */
class AckFrameRecord private constructor(
    ackKey: ByteArray,
    msgId: ByteArray,
    recipientNodeId: ByteArray,
    signature: ByteArray,
    encodedFrame: ByteArray,
    receivedFrom: ByteArray?,
    remainingLifetimeMs: Long,
    verificationClass: AckVerificationClass,
) {
    private val _ackKey = ackKey.copyOf()
    private val _msgId = msgId.copyOf()
    private val _recipientNodeId = recipientNodeId.copyOf()
    private val _signature = signature.copyOf()
    private val _encodedFrame = encodedFrame.copyOf()
    private val _receivedFrom: ByteArray? = receivedFrom?.copyOf()
    private val _remainingLifetimeMs: Long = remainingLifetimeMs
    private val _verificationClass: AckVerificationClass = verificationClass

    val ackKey: ByteArray get() = _ackKey.copyOf()
    val msgId: ByteArray get() = _msgId.copyOf()
    val recipientNodeId: ByteArray get() = _recipientNodeId.copyOf()
    val signature: ByteArray get() = _signature.copyOf()
    val encodedFrame: ByteArray get() = _encodedFrame.copyOf()
    val receivedFrom: ByteArray? get() = _receivedFrom?.copyOf()
    val remainingLifetimeMs: Long get() = _remainingLifetimeMs
    val verificationClass: AckVerificationClass get() = _verificationClass

    companion object {
        fun of(
            ackKey: ByteArray,
            msgId: ByteArray,
            recipientNodeId: ByteArray,
            signature: ByteArray,
            encodedFrame: ByteArray,
            receivedFrom: ByteArray?,
            remainingLifetimeMs: Long,
            verificationClass: AckVerificationClass,
        ): AckFrameRecord? {
            if (ackKey.size != ACK_KEY_LEN) return null
            if (msgId.size != ACK_MSG_LEN) return null
            if (recipientNodeId.size != ACK_RECIPIENT_LEN) return null
            if (signature.size != ACK_SIG_LEN) return null
            if (encodedFrame.isEmpty()) return null
            if (receivedFrom != null && receivedFrom.size != ACK_RECIPIENT_LEN) return null
            if (remainingLifetimeMs < 0L) return null
            return AckFrameRecord(ackKey, msgId, recipientNodeId, signature, encodedFrame,
                receivedFrom, remainingLifetimeMs, verificationClass)
        }
    }

    internal fun toView(): AckFrameRowView = AckFrameRowView(
        ackKey = _ackKey.copyOf(), msgId = _msgId.copyOf(),
        recipientNodeId = _recipientNodeId.copyOf(), signature = _signature.copyOf(),
        encodedFrame = _encodedFrame.copyOf(), receivedFrom = _receivedFrom?.copyOf(),
        remainingLifetimeMs = _remainingLifetimeMs, verificationClassCode = _verificationClass.code,
    )

    override fun equals(other: Any?): Boolean {
        if (other === this) return true
        if (other !is AckFrameRecord) return false
        return _ackKey.contentEquals(other._ackKey) && _msgId.contentEquals(other._msgId) &&
            _recipientNodeId.contentEquals(other._recipientNodeId) &&
            _signature.contentEquals(other._signature) && _encodedFrame.contentEquals(other._encodedFrame) &&
            bytesEqual(_receivedFrom, other._receivedFrom) &&
            _remainingLifetimeMs == other._remainingLifetimeMs &&
            _verificationClass == other._verificationClass
    }

    override fun hashCode(): Int {
        var h = _ackKey.contentHashCode()
        h = 31 * h + _signature.contentHashCode()
        h = 31 * h + _verificationClass.hashCode()
        h = 31 * h + _remainingLifetimeMs.hashCode()
        return h
    }

    override fun toString(): String =
        "AckFrameRecord(key=" + redactedHex(_ackKey) + ",msg=" + redactedHex(_msgId) +
            ",recip=" + redactedHex(_recipientNodeId) + ",sig=" + redactedHex(_signature) +
            ",frame=" + redactedHex(_encodedFrame) + ",from=" + redactedHex(_receivedFrom) +
            ",remainingMs=" + _remainingLifetimeMs + ",class=" + _verificationClass.name + ")"
}

// ------------------------------------------------------------------ local cache key

/** ack_key = SHA256(ASCII("GMP2-ACK-CACHE") || msg_id || recipient || signature).
 *  A LOCAL cache key only -- it never enters the wire. */
object AckCacheKey {
    const val ACK_DOMAIN_TEXT: String = "GMP2-ACK-CACHE"

    fun compute(msgId: ByteArray, recipientNodeId: ByteArray, signature: ByteArray): ByteArray? {
        if (msgId.size != ACK_MSG_LEN) return null
        if (recipientNodeId.size != ACK_RECIPIENT_LEN) return null
        if (signature.size != ACK_SIG_LEN) return null
        val md = MessageDigest.getInstance("SHA-256")
        md.update(ACK_DOMAIN_TEXT.toByteArray(Charsets.US_ASCII))
        md.update(msgId)
        md.update(recipientNodeId)
        md.update(signature)
        return md.digest()
    }
}

// ------------------------------------------------------------------ typed outcomes

sealed class InboundCommitResult {
    data class Committed(val heldNew: Boolean, val obligationStored: Boolean, val duplicate: Boolean)
        : InboundCommitResult()
    object RejectedCapacity : InboundCommitResult()
    object StorageFailure : InboundCommitResult()
    object InvalidArgument : InboundCommitResult()
}

sealed class ObligationInsertResult {
    object Stored : ObligationInsertResult()
    object Duplicate : ObligationInsertResult()
    object StorageFailure : ObligationInsertResult()
}

sealed class ObligationLookup {
    data class Found(val obligation: AckObligation) : ObligationLookup()
    object Absent : ObligationLookup()
    data class Corrupt(val reason: String) : ObligationLookup()
    object StorageFailure : ObligationLookup()
}

sealed class ObligationAdvanceResult {
    object Advanced : ObligationAdvanceResult()
    object Absent : ObligationAdvanceResult()
    data class StateDrift(val foundState: AckObligationState) : ObligationAdvanceResult()
    object StorageFailure : ObligationAdvanceResult()
}

sealed class AckAdmissionResult {
    data class Stored(val ackKey: ByteArray) : AckAdmissionResult()
    object Duplicate : AckAdmissionResult()
    object RefusedQuotaPair : AckAdmissionResult()
    object RefusedQuotaGlobal : AckAdmissionResult()
    object RefusedBadFrame : AckAdmissionResult()
    object RefusedKnownInvalid : AckAdmissionResult()
    object StorageFailure : AckAdmissionResult()
}

sealed class FrameCommitResult {
    object Committed : FrameCommitResult()
    object Idempotent : FrameCommitResult()
    object RefusedQuotaPair : FrameCommitResult()
    object RefusedQuotaGlobal : FrameCommitResult()
    object StorageFailure : FrameCommitResult()
}

sealed class PendingList {
    data class Rows(val rows: List<AckObligation>) : PendingList()
    data class Corrupt(val reason: String) : PendingList()
    object StorageFailure : PendingList()
}

sealed class PairList {
    data class Records(val records: List<AckFrameRecord>) : PairList()
    data class Corrupt(val reason: String) : PairList()
    object StorageFailure : PairList()
}

sealed class FrameLookup {
    data class Found(val record: AckFrameRecord) : FrameLookup()
    object Absent : FrameLookup()
    data class Corrupt(val reason: String) : FrameLookup()
    object StorageFailure : FrameLookup()
}

// ------------------------------------------------------------------ the paired store

interface AckSignerSeam {
    /** The node id this signer binds; null when no local identity stands ready. */
    val nodeId: ByteArray?

    /** The current binding generation of the local identity (audit pin). */
    fun generation(): Long

    /** The 32-byte Ed25519 seed of the still-valid local identity, or null when the
     *  key is unavailable (the obligation then REMAINS pending; nothing is claimed). */
    fun signingSeed(msgId: ByteArray, recipientNodeId: ByteArray): ByteArray?
}

/** The two namespaces as ONE paired store: the frame insert and the obligation
 *  retirement commit together or not at all (section 14: "in a transaction"). */
interface AckObligationStore {
    fun insertIfAbsent(obligation: AckObligation): ObligationInsertResult
    fun lookupObligation(msgId: ByteArray, recipientNodeId: ByteArray): ObligationLookup
    fun listPending(bound: Int): PendingList
    fun markSigned(msgId: ByteArray, recipientNodeId: ByteArray): ObligationAdvanceResult
    fun retireObligation(msgId: ByteArray, recipientNodeId: ByteArray): ObligationAdvanceResult
    fun countObligations(): Int

    fun storeCandidate(record: AckFrameRecord): AckAdmissionResult
    fun lookupByAckKey(ackKey: ByteArray): FrameLookup
    fun candidatesForPair(msgId: ByteArray, recipientNodeId: ByteArray, bound: Int): PairList
    fun countForPair(msgId: ByteArray, recipientNodeId: ByteArray): Int
    fun countFrames(): Int
    fun deleteAllFrames(): Int

    /** The atomic pair step: insert the frame row AND retire the obligation. */
    fun commitFrameAndRetireObligation(
        record: AckFrameRecord,
        msgId: ByteArray,
        recipientNodeId: ByteArray,
    ): FrameCommitResult
}

// ------------------------------------------------------------------ in-memory engine

internal class InMemoryAckStore : AckObligationStore {
    private val lock = Any()
    private class ObKey(val a: ByteArray, val b: ByteArray) {
        override fun equals(other: Any?): Boolean =
            other is ObKey && a.contentEquals(other.a) && b.contentEquals(other.b)
        override fun hashCode(): Int = 31 * a.contentHashCode() + b.contentHashCode()
    }
    private class Key(val bytes: ByteArray) {
        override fun equals(other: Any?): Boolean = other is Key && bytes.contentEquals(other.bytes)
        override fun hashCode(): Int = bytes.contentHashCode()
    }
    private val obligations = LinkedHashMap<ObKey, AckObligation>()
    private val frames = LinkedHashMap<Key, AckFrameRecord>()

    fun clearAll() = synchronized(lock) {
        obligations.clear()
        frames.clear()
    }

    override fun insertIfAbsent(obligation: AckObligation): ObligationInsertResult =
        synchronized(lock) {
            val k = ObKey(obligation.msgId, obligation.recipientNodeId)
            if (obligations.containsKey(k)) ObligationInsertResult.Duplicate
            else {
                obligations[k] = obligation
                ObligationInsertResult.Stored
            }
        }

    override fun lookupObligation(msgId: ByteArray, recipientNodeId: ByteArray): ObligationLookup =
        synchronized(lock) {
            val row = obligations[ObKey(msgId, recipientNodeId)]
            if (row == null) ObligationLookup.Absent else ObligationLookup.Found(row)
        }

    override fun listPending(bound: Int): PendingList = synchronized(lock) {
        if (bound <= 0) PendingList.Rows(emptyList())
        else {
            val taken = ArrayList<AckObligation>()
            for (row in obligations.values) {
                if (taken.size >= bound) break
                if (row.state == AckObligationState.PENDING || row.state == AckObligationState.SIGNED) {
                    taken.add(row)
                }
            }
            PendingList.Rows(taken.toList())
        }
    }

    override fun markSigned(msgId: ByteArray, recipientNodeId: ByteArray): ObligationAdvanceResult =
        synchronized(lock) {
            val k = ObKey(msgId, recipientNodeId)
            val cur = obligations[k]
            if (cur == null) ObligationAdvanceResult.Absent
            else if (cur.state != AckObligationState.PENDING) ObligationAdvanceResult.StateDrift(cur.state)
            else {
                obligations[k] = AckObligation.of(
                    cur.msgId, cur.recipientNodeId, cur.identityGeneration,
                    cur.remainingLifetimeMs, AckObligationState.SIGNED,
                ) ?: return@synchronized ObligationAdvanceResult.StorageFailure
                ObligationAdvanceResult.Advanced
            }
        }

    override fun retireObligation(msgId: ByteArray, recipientNodeId: ByteArray): ObligationAdvanceResult =
        synchronized(lock) {
            val k = ObKey(msgId, recipientNodeId)
            val cur = obligations[k]
            if (cur == null) ObligationAdvanceResult.Absent
            else {
                obligations.remove(k)
                ObligationAdvanceResult.Advanced
            }
        }

    override fun countObligations(): Int = synchronized(lock) { obligations.size }

    override fun storeCandidate(record: AckFrameRecord): AckAdmissionResult = synchronized(lock) {
        val k = Key(record.ackKey)
        if (frames.containsKey(k)) AckAdmissionResult.Duplicate
        else if (countForPairLocked(record.msgId, record.recipientNodeId) >= ACK_CANDIDATES_PER_PAIR_LIMIT) {
            AckAdmissionResult.RefusedQuotaPair
        } else if (frames.size >= ACK_CANDIDATES_TOTAL_LIMIT) {
            AckAdmissionResult.RefusedQuotaGlobal
        } else {
            frames[k] = record
            AckAdmissionResult.Stored(record.ackKey.copyOf())
        }
    }

    override fun lookupByAckKey(ackKey: ByteArray): FrameLookup = synchronized(lock) {
        val row = frames[Key(ackKey)]
        if (row == null) FrameLookup.Absent else FrameLookup.Found(row)
    }

    override fun candidatesForPair(
        msgId: ByteArray,
        recipientNodeId: ByteArray,
        bound: Int,
    ): PairList = synchronized(lock) {
        if (bound <= 0) PairList.Records(emptyList())
        else {
            val out = ArrayList<AckFrameRecord>()
            for (row in frames.values) {
                if (row.msgId.contentEquals(msgId) && row.recipientNodeId.contentEquals(recipientNodeId)) {
                    out.add(row)
                    if (out.size >= bound) break
                }
            }
            PairList.Records(out.toList())
        }
    }

    override fun countForPair(msgId: ByteArray, recipientNodeId: ByteArray): Int =
        synchronized(lock) { countForPairLocked(msgId, recipientNodeId) }

    private fun countForPairLocked(msgId: ByteArray, recipientNodeId: ByteArray): Int {
        var n = 0
        for (row in frames.values) {
            if (row.msgId.contentEquals(msgId) && row.recipientNodeId.contentEquals(recipientNodeId)) n++
        }
        return n
    }

    override fun countFrames(): Int = synchronized(lock) { frames.size }

    override fun deleteAllFrames(): Int = synchronized(lock) {
        val n = frames.size
        frames.clear()
        n
    }

    override fun commitFrameAndRetireObligation(
        record: AckFrameRecord,
        msgId: ByteArray,
        recipientNodeId: ByteArray,
    ): FrameCommitResult = synchronized(lock) {
        val k = Key(record.ackKey)
        val obK = ObKey(msgId, recipientNodeId)
        val framePresent = frames.containsKey(k)
        val obPresent = obligations.containsKey(obK)
        if (!framePresent) {
            if (countForPairLocked(record.msgId, record.recipientNodeId) >= ACK_CANDIDATES_PER_PAIR_LIMIT) {
                FrameCommitResult.RefusedQuotaPair
            } else if (frames.size >= ACK_CANDIDATES_TOTAL_LIMIT) {
                FrameCommitResult.RefusedQuotaGlobal
            } else {
                frames[k] = record
                if (obPresent) obligations.remove(obK)
                FrameCommitResult.Committed
            }
        } else {
            if (obPresent) obligations.remove(obK)
            FrameCommitResult.Idempotent
        }
    }
}

// ------------------------------------------------------------------ sqlite engine

/** The paired store over the durable SQLite transaction engine: the frame insert and
 *  the obligation retirement commit inside ONE engine.inTransaction (both-or-neither;
 *  the non-recursive connection lock is held once per call). */
internal class SqliteAckStore(private val engine: StoreDb) : AckObligationStore {
    override fun insertIfAbsent(obligation: AckObligation): ObligationInsertResult = try {
        if (engine.insertObligation(
                obligation.msgId, obligation.recipientNodeId,
                obligation.identityGeneration, obligation.remainingLifetimeMs,
                obligation.state.code,
            )
        ) ObligationInsertResult.Stored else ObligationInsertResult.Duplicate
    } catch (_e: Exception) {
        ObligationInsertResult.StorageFailure
    }

    override fun lookupObligation(msgId: ByteArray, recipientNodeId: ByteArray): ObligationLookup {
        val row = try {
            engine.readObligation(msgId, recipientNodeId)
        } catch (_e: Exception) {
            return ObligationLookup.StorageFailure
        }
        if (row == null) return ObligationLookup.Absent
        val state = AckObligationState.fromPersistedCode(row.stateCode)
            ?: return ObligationLookup.Corrupt("persisted state code ${row.stateCode}")
        val ob = AckObligation.of(
            row.msgId, row.recipientNodeId, row.identityGeneration,
            row.remainingLifetimeMs, state,
        ) ?: return ObligationLookup.Corrupt("persisted widths violate the relation")
        return ObligationLookup.Found(ob)
    }

    override fun listPending(bound: Int): PendingList {
        if (bound <= 0) return PendingList.Rows(emptyList())
        val rows = try {
            engine.listPendingObligations(bound)
        } catch (_e: Exception) {
            return PendingList.StorageFailure
        }
        val out = ArrayList<AckObligation>(rows.size)
        for (row in rows) {
            val state = AckObligationState.fromPersistedCode(row.stateCode)
                ?: return PendingList.Corrupt("pending scan: state code ${row.stateCode}")
            val ob = AckObligation.of(
                row.msgId, row.recipientNodeId, row.identityGeneration,
                row.remainingLifetimeMs, state,
            ) ?: return PendingList.Corrupt("pending scan: widths violate the relation")
            out.add(ob)
        }
        return PendingList.Rows(out.toList())
    }

    override fun markSigned(msgId: ByteArray, recipientNodeId: ByteArray): ObligationAdvanceResult {
        val advanced = try {
            engine.casMarkObligationSigned(msgId, recipientNodeId)
        } catch (_e: Exception) {
            return ObligationAdvanceResult.StorageFailure
        }
        if (advanced == 1) return ObligationAdvanceResult.Advanced
        return classifyZeroCas(msgId, recipientNodeId, AckObligationState.PENDING)
    }

    override fun retireObligation(msgId: ByteArray, recipientNodeId: ByteArray): ObligationAdvanceResult {
        val retired = try {
            engine.deleteObligation(msgId, recipientNodeId)
        } catch (_e: Exception) {
            return ObligationAdvanceResult.StorageFailure
        }
        if (retired > 0) return ObligationAdvanceResult.Advanced
        return classifyZeroCas(msgId, recipientNodeId, null)
    }

    /** A 0-row guarded statement is re-read ONCE and classified -- absent vs state
     *  drift are distinct observations; never folded into the storage failure. */
    private fun classifyZeroCas(
        msgId: ByteArray,
        recipientNodeId: ByteArray,
        expect: AckObligationState?,
    ): ObligationAdvanceResult {
        val row = engine.readObligation(msgId, recipientNodeId)
            ?: return ObligationAdvanceResult.Absent
        val state = AckObligationState.fromPersistedCode(row.stateCode)
            ?: return ObligationAdvanceResult.StorageFailure
        if (expect != null && state == expect) return ObligationAdvanceResult.StorageFailure
        return ObligationAdvanceResult.StateDrift(state)
    }

    override fun countObligations(): Int = try {
        engine.countObligationRows()
    } catch (_e: Exception) {
        -1
    }

    override fun storeCandidate(record: AckFrameRecord): AckAdmissionResult {
        val view = record.toView()
        val inserted = try {
            engine.insertAckFrameRow(view)
        } catch (_e: Exception) {
            return AckAdmissionResult.StorageFailure
        }
        if (inserted) return AckAdmissionResult.Stored(record.ackKey.copyOf())
        // a duplicate key: re-read ONCE to distinguish the true duplicate from a
        // raced removal; never report a refusal that did not happen
        val again = try {
            engine.readAckFrameRowByAckKey(record.ackKey)
        } catch (_e: Exception) {
            return AckAdmissionResult.StorageFailure
        }
        return if (again == null) AckAdmissionResult.StorageFailure else AckAdmissionResult.Duplicate
    }

    /** The quota gates run BEFORE any write: the pair census and the total
     *  census, each refused explicitly, none of them poisoning any other
     *  namespace (section 14: exhaustion refuses, it does not corrupt). */
    fun admitUnderQuota(record: AckFrameRecord): AckAdmissionResult {
        val pairCount = try {
            engine.countAckFrameRowsForPair(record.msgId, record.recipientNodeId)
        } catch (_e: Exception) {
            return AckAdmissionResult.StorageFailure
        }
        if (pairCount >= ACK_CANDIDATES_PER_PAIR_LIMIT) return AckAdmissionResult.RefusedQuotaPair
        val total = try {
            engine.countAckFrameRowsTotal()
        } catch (_e: Exception) {
            return AckAdmissionResult.StorageFailure
        }
        if (total >= ACK_CANDIDATES_TOTAL_LIMIT) return AckAdmissionResult.RefusedQuotaGlobal
        return storeCandidate(record)
    }

    override fun lookupByAckKey(ackKey: ByteArray): FrameLookup {
        val row = try {
            engine.readAckFrameRowByAckKey(ackKey)
        } catch (_e: Exception) {
            return FrameLookup.StorageFailure
        }
        if (row == null) return FrameLookup.Absent
        val rec = fromView(row) ?: return FrameLookup.Corrupt("stored frame violates the relation")
        return FrameLookup.Found(rec)
    }

    override fun candidatesForPair(
        msgId: ByteArray,
        recipientNodeId: ByteArray,
        bound: Int,
    ): PairList {
        if (bound <= 0) return PairList.Records(emptyList())
        val rows = try {
            engine.listAckFrameRowsForPair(msgId, recipientNodeId, bound)
        } catch (_e: Exception) {
            return PairList.StorageFailure
        }
        val out = ArrayList<AckFrameRecord>(rows.size)
        for (row in rows) {
            out.add(fromView(row) ?: return PairList.Corrupt("pair scan: row violates the relation"))
        }
        return PairList.Records(out.toList())
    }

    override fun countForPair(msgId: ByteArray, recipientNodeId: ByteArray): Int = try {
        engine.countAckFrameRowsForPair(msgId, recipientNodeId)
    } catch (_e: Exception) {
        -1
    }

    override fun countFrames(): Int = try {
        engine.countAckFrameRowsTotal()
    } catch (_e: Exception) {
        -1
    }

    override fun deleteAllFrames(): Int = try {
        engine.deleteAllAckFrameRows()
    } catch (_e: Exception) {
        -1
    }

    override fun commitFrameAndRetireObligation(
        record: AckFrameRecord,
        msgId: ByteArray,
        recipientNodeId: ByteArray,
    ): FrameCommitResult {
        val outcome = try {
            engine.commitAckPair(record.toView(), msgId, recipientNodeId)
        } catch (_e: Exception) {
            return FrameCommitResult.StorageFailure
        }
        return when (outcome) {
            FrameCommitOutcome.COMMITTED -> FrameCommitResult.Committed
            FrameCommitOutcome.IDEMPOTENT -> FrameCommitResult.Idempotent
            FrameCommitOutcome.REFUSED_QUOTA_PAIR -> FrameCommitResult.RefusedQuotaPair
            FrameCommitOutcome.REFUSED_QUOTA_GLOBAL -> FrameCommitResult.RefusedQuotaGlobal
        }
    }

    private fun fromView(row: AckFrameRowView): AckFrameRecord? {
        val klass = AckVerificationClass.fromPersistedCode(row.verificationClassCode) ?: return null
        return AckFrameRecord.of(
            row.ackKey, row.msgId, row.recipientNodeId, row.signature,
            row.encodedFrame, row.receivedFrom, row.remainingLifetimeMs, klass,
        )
    }
}

// ------------------------------------------------------------------ the bounded worker

/** The bounded worker of section 14: signs via the still-valid local identity AFTER
 *  the inbox commit, stores the exact frame row, retires the obligation -- one
 *  transaction per pair. Stateless between runs; a restart resumes by re-reading. */
internal class AckObligationDriver(
    private val store: AckObligationStore,
    private val signer: AckSignerSeam,
    private val authenticator: AckAuthenticator,
    private val resolver: RecipientKeyResolver,
) {
    class DriverReport(
        val scanned: Int,
        val signed: Int,
        val retired: Int,
        val keyUnavailable: Int,
        val idempotent: Int,
        val refusedQuota: Int,
        val storageFailures: Int,
    )

    fun runPendingOnce(bound: Int, fault: ((String) -> Unit)? = null): DriverReport {
        var scanned = 0; var signed = 0; var retired = 0; var keyUnavailable = 0
        var idempotent = 0; var refusedQuota = 0; var failures = 0
        val pending = when (val pl = store.listPending(bound)) {
            is PendingList.Rows -> pl.rows
            is PendingList.Corrupt -> { failures++; emptyList() }
            PendingList.StorageFailure -> { failures++; emptyList() }
        }
        for (ob in pending) {
            scanned++
            // refuse to sign with a key that does not name the obligated recipient
            val signerNode = signer.nodeId
            if (signerNode == null || !signerNode.contentEquals(ob.recipientNodeId)) {
                keyUnavailable++
                continue
            }
            if (signer.generation() < ob.identityGeneration) {
                // the presented identity is older than the pin: NOT the still-valid
                // local identity; the obligation remains pending and nothing is claimed
                keyUnavailable++
                continue
            }
            val seed = try {
                signer.signingSeed(ob.msgId, ob.recipientNodeId)
            } catch (_e: Throwable) {
                null
            }
            if (seed == null) {
                keyUnavailable++
                continue
            }
            fault?.invoke("signing")
            val frame = try {
                AckFrame.build(ob.msgId, seed, ob.recipientNodeId,
                    ob.recipientNodeId.copyOfRange(0, ACK_HINT_LEN))
            } catch (_e: Throwable) {
                failures++
                continue
            }
            if (frame.payload.size != ACK_PAYLOAD_LEN) {
                failures++
                continue
            }
            val encoded = try { frame.encode() } catch (_e: Throwable) { null }
            if (encoded == null || encoded.isEmpty()) {
                failures++
                continue
            }
            val signature = frame.payload.copyOfRange(0, ACK_SIG_LEN)
            val claimed = frame.payload.copyOfRange(ACK_SIG_LEN, ACK_PAYLOAD_LEN)
            // verification-first even for self-produced frames: a mis-signed reply
            // must never be stored and the obligation must survive it
            val ownKey = try {
                resolver.publicSigningKey(claimed)
            } catch (_e: Throwable) {
                null
            }
            if (ownKey != null) {
                val ok = try {
                    authenticator.verify(ob.msgId, claimed, frame)
                } catch (_e: Throwable) {
                    false
                }
                if (!ok) {
                    failures++
                    continue
                }
            }
            val ackKey = AckCacheKey.compute(ob.msgId, ob.recipientNodeId, signature)
            if (ackKey == null) {
                failures++
                continue
            }
            val record = AckFrameRecord.of(ackKey, ob.msgId, ob.recipientNodeId, signature,
                encoded, null, ob.remainingLifetimeMs, AckVerificationClass.VERIFIED_RECIPIENT)
            if (record == null) {
                failures++
                continue
            }
            fault?.invoke("frame_insert")
            val res = try {
                store.commitFrameAndRetireObligation(record, ob.msgId, ob.recipientNodeId)
            } catch (_e: Throwable) {
                FrameCommitResult.StorageFailure
            }
            when (res) {
                FrameCommitResult.Committed -> { signed++; retired++ }
                FrameCommitResult.Idempotent -> { idempotent++ }
                FrameCommitResult.RefusedQuotaPair -> refusedQuota++
                FrameCommitResult.RefusedQuotaGlobal -> refusedQuota++
                FrameCommitResult.StorageFailure -> failures++
            }
        }
        return DriverReport(scanned, signed, retired, keyUnavailable, idempotent, refusedQuota, failures)
    }

    /** Admission of a foreign candidate (a received ACK frame): the classifier runs
     *  BEFORE any write. Known-invalid under an available authenticated key is
     *  REJECTED; without an available key the candidate is admitted only as a bounded
     *  OPAQUE row, never labelled recipient-verified. Quota gates live in the store. */
    fun admitForeignCandidate(encoded: ByteArray, receivedFrom: ByteArray?): AckAdmissionResult {
        val frame = try {
            FrameV2.decode(encoded)
        } catch (_e: Throwable) {
            null
        } ?: return AckAdmissionResult.RefusedBadFrame
        if (frame.type != TypeV2.ACK) return AckAdmissionResult.RefusedBadFrame
        if (frame.payload.size != ACK_PAYLOAD_LEN) return AckAdmissionResult.RefusedBadFrame
        if (frame.msgId.size != ACK_MSG_LEN) return AckAdmissionResult.RefusedBadFrame
        if (receivedFrom != null && receivedFrom.size != ACK_RECIPIENT_LEN) {
            return AckAdmissionResult.RefusedBadFrame
        }
        val signature = frame.payload.copyOfRange(0, ACK_SIG_LEN)
        val claimed = frame.payload.copyOfRange(ACK_SIG_LEN, ACK_PAYLOAD_LEN)
        val key = try {
            resolver.publicSigningKey(claimed)
        } catch (_e: Throwable) {
            null
        }
        val klass = if (key != null) {
            val ok = try {
                authenticator.verify(frame.msgId, claimed, frame)
            } catch (_e: Throwable) {
                false
            }
            if (!ok) return AckAdmissionResult.RefusedKnownInvalid
            AckVerificationClass.VERIFIED_RECIPIENT
        } else {
            AckVerificationClass.OPAQUE_CANDIDATE
        }
        val ackKey = AckCacheKey.compute(frame.msgId, claimed, signature)
            ?: return AckAdmissionResult.RefusedBadFrame
        val record = AckFrameRecord.of(ackKey, frame.msgId, claimed, signature, encoded,
            receivedFrom, ACK_CANDIDATE_LIFETIME_MS, klass)
            ?: return AckAdmissionResult.RefusedBadFrame
        return if (store is SqliteAckStore) store.admitUnderQuota(record) else store.storeCandidate(record)
    }

    companion object {
        /** Candidates admitted without a verified origin enter the bounded relay
         *  window under the 8-day ACK-retention policy of section 14 (the clock
         *  policy proper belongs to the retention sweep, T84). */
        const val ACK_CANDIDATE_LIFETIME_MS: Long = 8L * 24L * 60L * 60L * 1000L
    }
}
