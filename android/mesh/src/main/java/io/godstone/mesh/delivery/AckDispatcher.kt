package io.godstone.mesh.delivery

import io.godstone.mesh.store.ClockContinuityStamp
import io.godstone.mesh.store.ExpiryReason
import io.godstone.mesh.store.MessageKind
import io.godstone.mesh.store.MonotonicClockAdapter
import io.godstone.mesh.store.RetentionCheckpoint
import io.godstone.mesh.store.RetentionClock
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.TypeV2

// ---------------------------------------------------------------------------
// T84 -- "Forward durable ACKs through intermediate relays" (section 14, the
// durable ACK return path). The card's defect: MeshNode sendeth every ACK to
// the local DeliveryTracker, so an intermediate relay -- which by definition
// holdeth NO delivery row for a message somebody else authored -- answereth
// UnknownMessage, and the multihop recipient receipt never cometh home.
//
// Two authorities are born here, and they are deliberately separate.
//
//   AckDispatcher -- the INBOUND decision for one ACK frame, taken BEFORE any
//     generic message TTL / dedup / store handling. The classification is
//     OriginVerification versus OpaqueRelay:
//       * a durable delivery row standeth for the msgId -> the ORIGIN. The
//         existing expected-recipient / trust / CAS verification runneth
//         first, and it is the ONLY road to DELIVERED. A rejected candidate
//         leaveth delivery unchanged and cannot suppress a later valid
//         signature;
//       * no delivery row standeth -> RELAY TRAFFIC, never an automatic
//         discard. The candidate entereth the SEPARATE ack_frames namespace
//         (never held_frames, never the message dedup), bounded per pair and
//         in total, labelled opaque-candidate unless a real recipient key
//         verified it;
//       * a delivery lookup that FAILED (corrupt or storage failure) is a
//         refusal BY NAME. Storage failure is never read as "no row", which
//         would silently reclassify a correctness-critical fault as traffic.
//
//   DurableAckPump -- the OUTBOUND bounded epidemic pump, and the one owner of
//     a candidate's lifecycle. It is scheduled on LinkReady, batch 32, at most
//     one retry per candidate/peer per 30 s, one ACK/s with burst 16 per peer;
//     it never echoeth to receivedFrom; it never inserteth a candidate into
//     the message bloom/inventory namespace, and a LOCAL ATT ACCEPTANCE NEVER
//     RETIRETH CUSTODY -- only the retention sweep and quota do. A forwarded
//     copy decrementeth TTL and incrementeth hop EXACTLY ONCE (the prepared
//     copy is stored and re-emitted byte-identically on every retry), and an
//     ACK whose received TTL lieth outside the production band is refused by
//     name rather than re-signed with a budget it never had.
//
// Retention is the section 14 non-replenishing clock policy, delegated to the
// T32 [RetentionClock] seam so that there is ONE owner of the arithmetic: a
// candidate admitted by THIS process is anchored at its admission instant and
// debited by the true monotonic delta, while a candidate restored from the
// store after a restart taketh the conservative branch exactly once (a
// discontinuity counted, a bounded nonnegative wall estimate floored at one
// hour), and the STORE refuseth any debit that would not strictly shorten the
// life. Eight days from first local receipt is the window; it is never
// replenished.
//
// Nonshipping: this is the lab mesh path. The shipping LIGHT Archive-only
// graph carrieth no :mesh dependency at all, the readiness flags stay false,
// and nothing here closeth a device gate.
// ---------------------------------------------------------------------------

/** The lowercase hex of a byte array, for keys and refusal detail only. */
private fun ByteArray.hex(): String = joinToString("") { "%02x".format(it) }

/** Bounded batch of forward copies offered to one peer (section 14: 32). */
const val ACK_RELAY_BATCH_LIMIT: Int = 32

/** At most one retry per candidate/peer in this window (section 14: 30 s). */
const val ACK_RELAY_RETRY_INTERVAL_MS: Long = 30_000L

/** Per-peer token bucket: one ACK/s, burst 16 (section 14). */
const val ACK_RELAY_BURST_PER_PEER: Int = 16
const val ACK_RELAY_RATE_MS: Long = 1_000L

/**
 * The EXPLICIT production initial ACK TTL, mirrored from the canonical ACK
 * generator ([ACK_INITIAL_TTL]). A received candidate ABOVE this carrieth a
 * hop budget the production generator never issueth and is refused by name; a
 * candidate below 2 cannot be forwarded at all (a forward copy decrementeth
 * the TTL, and a TTL-0 frame is local to the link and never travels).
 */
const val ACK_RELAY_INITIAL_TTL: Int = ACK_INITIAL_TTL

/** The bound on one enumeration walk of the candidate namespace. */
const val ACK_RELAY_ENUMERATION_LIMIT: Int = ACK_CANDIDATES_TOTAL_LIMIT

/** The classification of one inbound ACK (the card's named types). */
enum class AckDispatchClass { ORIGIN_VERIFICATION, OPAQUE_RELAY }

/** Why a frame was refused before any write. Named, never a silent drop. */
enum class AckRefusalReason {
    NOT_AN_ACK,
    MALFORMED_PAYLOAD,
    NON_CANONICAL_FLAGS,
    DELIVERY_STATE_UNREADABLE,
    CANDIDATE_CAPACITY,
    KNOWN_INVALID_SIGNATURE,
    CUSTODY_STORAGE_FAILURE,
}

/** What one admission did, and what it was labelled. */
class AckAdmission(
    val result: AckAdmissionResult,
    val ackKey: ByteArray?,
    val verificationClass: AckVerificationClass?,
) {
    val accepted: Boolean
        get() = result is AckAdmissionResult.Stored || result == AckAdmissionResult.Duplicate
}

/** The dispatcher's verdict for one inbound ACK frame. */
sealed class AckDispatch {
    abstract val dispatchClass: AckDispatchClass

    /** Whether this verdict meaneth "accepted" to the caller (an origin accept, or
     *  relay custody taken). A refusal is never an acceptance. */
    abstract val accepted: Boolean

    /** A durable delivery row standeth: only this road may reach DELIVERED. */
    class OriginVerification(val result: AckResult) : AckDispatch() {
        override val dispatchClass: AckDispatchClass get() = AckDispatchClass.ORIGIN_VERIFICATION

        /** Idempotent accept: a newly verified recipient is accepted, an
         *  already-terminal row is accepted, everything else is a rejection. */
        override val accepted: Boolean
            get() = result == AckResult.Applied ||
                result == AckResult.AlreadyAcknowledged ||
                result == AckResult.DuplicateAuthenticatedAck
    }

    /** No delivery row: relay traffic, carried in the separate namespace. */
    class OpaqueRelay(val admission: AckAdmission) : AckDispatch() {
        override val dispatchClass: AckDispatchClass get() = AckDispatchClass.OPAQUE_RELAY
        override val accepted: Boolean get() = admission.accepted
        val ackKey: ByteArray? get() = admission.ackKey
        val verificationClass: AckVerificationClass? get() = admission.verificationClass
    }

    /** Refused by name; nothing was written anywhere. */
    class Refused(val reason: AckRefusalReason, val detail: String = "") : AckDispatch() {
        override val dispatchClass: AckDispatchClass get() = AckDispatchClass.ORIGIN_VERIFICATION
        override val accepted: Boolean get() = false
    }
}

/**
 * The inbound ACK authority. Every dependency is injected at a real boundary:
 * the delivery-row lookup (the origin test), the tracker's verification, and
 * the admission (owned by [DurableAckPump]). Pure Kotlin -- no clock, no I/O
 * of its own -- so the whole dispatch statute is executable on the host.
 */
class AckDispatcher(
    private val lookupDeliveryRow: (ByteArray) -> DeliveryLookup,
    private val verifyOrigin: (FrameV2) -> AckResult,
    private val admitCandidate: (ByteArray, ByteArray?) -> AckAdmission,
) {
    /** One inbound ACK: origin first, then bounded relay custody. */
    fun dispatch(frame: FrameV2, receivedFrom: ByteArray?): AckDispatch {
        if (frame.type != TypeV2.ACK) {
            return AckDispatch.Refused(AckRefusalReason.NOT_AN_ACK)
        }
        if (frame.payload.size != ACK_PAYLOAD_LEN) {
            return AckDispatch.Refused(
                AckRefusalReason.MALFORMED_PAYLOAD,
                "an ACK payload is signature64||recipientNodeId16; this one carrieth " +
                    "${frame.payload.size} bytes",
            )
        }
        if (frame.msgId.size != ACK_MSG_LEN) {
            return AckDispatch.Refused(AckRefusalReason.MALFORMED_PAYLOAD, "msgId is not 16 bytes")
        }
        if (frame.flags != 0) {
            // section 14: "flags remain canonical0". A non-zero flag would make
            // this a different frame than the recipient signed.
            return AckDispatch.Refused(
                AckRefusalReason.NON_CANONICAL_FLAGS,
                "canonical ACK flags must be 0, found ${frame.flags}",
            )
        }
        val lookup = try {
            lookupDeliveryRow(frame.msgId)
        } catch (_e: Throwable) {
            DeliveryLookup.StorageFailure
        }
        when (lookup) {
            is DeliveryLookup.Found -> {
                // THE ORIGIN. The existing expected-recipient / trust / CAS
                // verification runs first and stands untouched: a rejected
                // candidate leaves delivery unchanged and cannot suppress a
                // later valid signature.
                val result = try {
                    verifyOrigin(frame)
                } catch (_e: Throwable) {
                    AckResult.StorageFailure
                }
                return AckDispatch.OriginVerification(result)
            }
            is DeliveryLookup.NotFound -> Unit  // relay traffic: fall through
            is DeliveryLookup.Corrupt -> return AckDispatch.Refused(
                AckRefusalReason.DELIVERY_STATE_UNREADABLE,
                "the delivery row for " + frame.msgId.hex() + " is corrupt",
            )
            is DeliveryLookup.StorageFailure -> return AckDispatch.Refused(
                AckRefusalReason.DELIVERY_STATE_UNREADABLE,
                "the delivery row for " + frame.msgId.hex() + " could not be read",
            )
            else -> return AckDispatch.Refused(
                AckRefusalReason.DELIVERY_STATE_UNREADABLE,
                "the delivery row for " + frame.msgId.hex() + " was refused: " + lookup,
            )
        }
        val admission = try {
            admitCandidate(frame.encode(), receivedFrom)
        } catch (_e: Throwable) {
            // An admission seam that THREW is a custody storage failure, never
            // a silent "nothing to carry".
            return AckDispatch.Refused(
                AckRefusalReason.CUSTODY_STORAGE_FAILURE, "the candidate store threw")
        }
        return when (admission.result) {
            is AckAdmissionResult.Stored, AckAdmissionResult.Duplicate ->
                AckDispatch.OpaqueRelay(admission)
            AckAdmissionResult.RefusedQuotaPair, AckAdmissionResult.RefusedQuotaGlobal ->
                AckDispatch.Refused(
                    AckRefusalReason.CANDIDATE_CAPACITY,
                    "the relay ACK window is full; new custody is refused explicitly " +
                        "(the original message and the origin verification state are untouched)",
                )
            AckAdmissionResult.RefusedKnownInvalid -> AckDispatch.Refused(
                AckRefusalReason.KNOWN_INVALID_SIGNATURE,
                "the candidate is invalid under an AVAILABLE authenticated recipient key",
            )
            AckAdmissionResult.RefusedBadFrame -> AckDispatch.Refused(
                AckRefusalReason.MALFORMED_PAYLOAD, "the candidate frame did not decode",
            )
            AckAdmissionResult.StorageFailure -> AckDispatch.Refused(
                AckRefusalReason.CUSTODY_STORAGE_FAILURE, "the candidate store refused the write",
            )
        }
    }
}

/** Why a candidate produced no forward copy in this batch. */
enum class AckForwardRefusal {
    /** LinkReady never arrived for this peer: the pump is not scheduled. */
    NOT_SCHEDULED,
    /** The candidate came FROM this peer: an ACK is never echoed back. */
    RECEIVED_FROM_THIS_PEER,
    /** One retry per candidate/peer per 30 s: this one is still in its window. */
    RETRY_WINDOW,
    /** The per-peer token bucket is empty (1 ACK/s, burst 16). */
    PEER_RATE_LIMIT,
    /** The received TTL is below 2: the copy would be a TTL-0 local frame. */
    TTL_EXHAUSTED,
    /** The received TTL exceedeth the explicit production initial 12. */
    TTL_ABOVE_PRODUCTION_INITIAL,
    /** The hop count cannot be incremented. */
    HOP_LIMIT,
    /** The stored frame no longer decodes. */
    MALFORMED,
}

/**
 * One prepared forward copy. It is built ONCE per candidate and stored, so a
 * retry re-emiteth the IDENTICAL bytes: TTL is decremented and hop incremented
 * exactly once for the copy, never again (section 14).
 */
class AckForwardCopy internal constructor(
    val ackKey: ByteArray,
    val msgId: ByteArray,
    val encodedFrame: ByteArray,
    val ttl: Int,
    val hopCount: Int,
    val verificationClass: AckVerificationClass,
)

/** The bounded result of one pump turn for one peer. */
class AckPumpBatch(
    val peer: ByteArray,
    val copies: List<AckForwardCopy>,
    val refusals: Map<AckForwardRefusal, Int>,
    val scanned: Int,
) {
    val refusedTotal: Int get() = refusals.values.sum()
}

/** What one retention sweep did. Every count is an executed observation. */
class AckSweepReport(
    val scanned: Int,
    val debited: Int,
    val expired: Int,
    val refusedReplenish: Int,
    val expiryReasons: Map<String, Int>,
    val storageFailure: Boolean,
)

/**
 * The bounded, durable epidemic ACK pump, and the one owner of a candidate's
 * lifecycle. It owneth no durable state of its own: the candidate rows ARE the
 * ack_frames namespace, and its in-memory tables (retry gates, token buckets,
 * prepared copies, retention anchors) are scheduling hints that a restart
 * rebuildeth from the store.
 */
class DurableAckPump(
    private val store: AckObligationStore,
    private val admitForeign: (ByteArray, ByteArray?) -> AckAdmissionResult,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000L },
) {
    /** Peers whose link became ready (the scheduling truth), and when. */
    private val readyAt = HashMap<String, Long>()

    /** Last offer of one candidate to one peer: the 30 s retry gate. */
    private val lastOffer = HashMap<String, Long>()

    private class Bucket(var tokens: Int, var refilledAtMs: Long)
    private val buckets = HashMap<String, Bucket>()

    /** The prepared copies: built once, re-emitted byte-identically forever. */
    private val copies = HashMap<String, AckForwardCopy>()

    /** Retention anchors: present IFF this process admitted or already knew the
     *  candidate. An absent anchor meaneth "restored from the store". */
    private val checkpoints = HashMap<String, RetentionCheckpoint>()

    private var lastSweepMs: Long? = null

    private val lock = Any()

    // ---------------------------------------------------------------- scheduling

    /** Schedule on LinkReady: the peer becometh eligible, with a full bucket. */
    fun onLinkReady(peer: ByteArray, now: Long = clock()) {
        synchronized(lock) {
            readyAt[peer.hex()] = now
            buckets[peer.hex()] = Bucket(ACK_RELAY_BURST_PER_PEER, now)
        }
    }

    /** A link went away: the peer stoppeth being eligible. Nothing is retired:
     *  the candidate waiteth, durably, for the next LinkReady. */
    fun onLinkGone(peer: ByteArray) {
        synchronized(lock) {
            readyAt.remove(peer.hex())
            buckets.remove(peer.hex())
        }
    }

    fun isScheduled(peer: ByteArray): Boolean = synchronized(lock) { readyAt.containsKey(peer.hex()) }

    // ---------------------------------------------------------------- custody

    /**
     * Admit one candidate into the SEPARATE namespace, and anchor it. This is
     * the dispatcher's injected boundary: the classification is the
     * dispatcher's, the lifecycle is the pump's.
     */
    fun admit(encoded: ByteArray, receivedFrom: ByteArray? = null,
              now: Long = clock()): AckAdmission {
        val result = try {
            admitForeign(encoded, receivedFrom)
        } catch (_e: Throwable) {
            AckAdmissionResult.StorageFailure
        }
        val frame = decodeOrNull(encoded)
        val claimed = frame?.payload?.takeIf { it.size == ACK_PAYLOAD_LEN }
            ?.copyOfRange(ACK_SIG_LEN, ACK_PAYLOAD_LEN)
        val key = if (frame != null && claimed != null) {
            try {
                AckCacheKey.compute(frame.msgId, claimed,
                    frame.payload.copyOfRange(0, ACK_SIG_LEN))
            } catch (_e: Throwable) {
                null
            }
        } else {
            null
        }
        var klass: AckVerificationClass? = null
        if (key != null && (result is AckAdmissionResult.Stored || result == AckAdmissionResult.Duplicate)) {
            klass = when (val row = store.lookupByAckKey(key)) {
                is FrameLookup.Found -> row.record.verificationClass
                else -> null
            }
            if (klass != null) {
                synchronized(lock) {
                    val hex = key.hex()
                    if (checkpoints[hex] == null) {
                        // A NEW receipt is granted the full local lifetime ONCE,
                        // anchored at this instant (section 14).
                        checkpoints[hex] = RetentionCheckpoint(
                            msgId = frame!!.msgId.hex(),
                            kind = MessageKind.DIRECT,
                            remainingMs = rowRemaining(key),
                            checkpointMonotonicMs = now,
                            lastWallCheckpointMs = now,
                            discontinuityCount = 0,
                            priority = 0,
                            firstReceiptId = "relay",
                        )
                    }
                }
            }
        }
        return AckAdmission(result, key, klass)
    }

    /** Custody is the store's: how many candidates stand right now. */
    fun custodyCount(): Int = when (val rows = store.listCandidates(ACK_RELAY_ENUMERATION_LIMIT)) {
        is CandidateList.Records -> rows.records.size
        else -> -1
    }

    fun custodyHolds(ackKey: ByteArray): Boolean = when (store.lookupByAckKey(ackKey)) {
        is FrameLookup.Found -> true
        else -> false
    }

    // ---------------------------------------------------------------- forwarding

    /**
     * One bounded pump turn for [peer]: at most 32 copies, honouring the retry
     * window, the per-peer rate, the never-echo law and the TTL/hop statute.
     */
    fun nextBatch(peer: ByteArray, now: Long = clock()): AckPumpBatch {
        val peerKey = peer.hex()
        synchronized(lock) {
            if (!readyAt.containsKey(peerKey)) {
                // No LinkReady, no offer. A candidate is never sent to a peer
                // the runtime has not declared ready.
                return AckPumpBatch(peer, emptyList(),
                    mapOf(AckForwardRefusal.NOT_SCHEDULED to 1), 0)
            }
            val rows = when (val listed = store.listCandidates(ACK_RELAY_ENUMERATION_LIMIT)) {
                is CandidateList.Records -> listed.records
                else -> return AckPumpBatch(peer, emptyList(), emptyMap(), 0)
            }
            val refusals = LinkedHashMap<AckForwardRefusal, Int>()
            fun refuse(reason: AckForwardRefusal) {
                refusals[reason] = (refusals[reason] ?: 0) + 1
            }
            val out = ArrayList<AckForwardCopy>()
            var scanned = 0
            for (record in rows) {
                if (out.size >= ACK_RELAY_BATCH_LIMIT) break
                val from = record.receivedFrom
                if (from != null && from.contentEquals(peer)) {
                    refuse(AckForwardRefusal.RECEIVED_FROM_THIS_PEER)
                    continue
                }
                scanned += 1
                val ackKeyHex = record.ackKey.hex()
                val last = lastOffer["$ackKeyHex|$peerKey"]
                if (last != null && now - last < ACK_RELAY_RETRY_INTERVAL_MS) {
                    refuse(AckForwardRefusal.RETRY_WINDOW)
                    continue
                }
                val frame = decodeOrNull(record.encodedFrame)
                if (frame == null) {
                    refuse(AckForwardRefusal.MALFORMED)
                    continue
                }
                // The TTL/hop statute is judged on the RECEIVED frame, BEFORE a
                // copy is prepared: a refusal never buildeth a frame it then
                // discards.
                when {
                    frame.ttl < 2 -> {
                        refuse(AckForwardRefusal.TTL_EXHAUSTED); continue
                    }
                    frame.ttl > ACK_RELAY_INITIAL_TTL -> {
                        refuse(AckForwardRefusal.TTL_ABOVE_PRODUCTION_INITIAL); continue
                    }
                    frame.hopCount + 1 > FrameV2.MAX_TTL -> {
                        refuse(AckForwardRefusal.HOP_LIMIT); continue
                    }
                }
                val bucket = buckets.getOrPut(peerKey) { Bucket(ACK_RELAY_BURST_PER_PEER, now) }
                if (refill(bucket, now) <= 0) {
                    refuse(AckForwardRefusal.PEER_RATE_LIMIT)
                    continue
                }
                val prepared = copies.getOrPut(ackKeyHex) { prepare(record, frame) }
                bucket.tokens -= 1
                // The retry window openeth at the OFFER, not at the writer's
                // convenience: a candidate offered now cannot be offered again
                // for 30 s even if the caller never reporteth an outcome. The
                // writer's report only re-stampeth the same window.
                lastOffer["$ackKeyHex|$peerKey"] = now
                out.add(prepared)
            }
            return AckPumpBatch(peer, out, refusals, scanned)
        }
    }

    /**
     * The link's writer answereth. A LOCAL ATT ACCEPTANCE NEVER RETIRETH
     * CUSTODY: it only starteth the retry window. A candidate leaveth the
     * namespace when the retention sweep expireth it, or when quota refuseth
     * new custody -- never because a radio accepted some bytes.
     */
    fun onForwardOutcome(copy: AckForwardCopy, peer: ByteArray, accepted: Boolean,
                         now: Long = clock()) {
        synchronized(lock) {
            lastOffer["${copy.ackKey.hex()}|${peer.hex()}"] = now
        }
    }

    // ---------------------------------------------------------------- retention

    /**
     * The retention sweep: ONE non-replenishing debit per candidate, expiring
     * those whose remaining life reacheth nought. The arithmetic is the T32
     * [RetentionClock]; the store refuseth any debit that would not strictly
     * shorten the life.
     */
    fun sweep(
        now: Long = clock(),
        wallEstimateMs: Long = 0L,
        continuity: ClockContinuityStamp = ClockContinuityStamp.Unknown,
    ): AckSweepReport {
        val adapter = object : MonotonicClockAdapter {
            override fun proveContinuity(
                previous: RetentionCheckpoint,
                nowMono: Long,
            ): ClockContinuityStamp = continuity
        }
        synchronized(lock) {
            val rows = when (val listed = store.listCandidates(ACK_RELAY_ENUMERATION_LIMIT)) {
                is CandidateList.Records -> listed.records
                else -> return AckSweepReport(0, 0, 0, 0, emptyMap(), true)
            }
            var debited = 0
            var expired = 0
            var refusedReplenish = 0
            val reasons = LinkedHashMap<String, Int>()
            for (record in rows) {
                val hex = record.ackKey.hex()
                val prior = checkpoints[hex]
                if (prior == null) {
                    // RESTORED from the store: this process knoweth not what
                    // elapsed while it was not running, so it taketh the
                    // conservative branch exactly once, and anchors there.
                    checkpoints[hex] = RetentionCheckpoint(
                        msgId = record.msgId.hex(),
                        kind = MessageKind.DIRECT,
                        remainingMs = record.remainingLifetimeMs,
                        checkpointMonotonicMs = now,
                        lastWallCheckpointMs = now,
                        discontinuityCount = 0,
                        priority = 0,
                        firstReceiptId = "relay",
                    )
                    val restored = checkpoints.getValue(hex)
                    val (next, reason) = RetentionClock.checkpoint(
                        restored, now, wallEstimateMs,
                        object : MonotonicClockAdapter {
                            override fun proveContinuity(
                                previous: RetentionCheckpoint,
                                nowMono: Long,
                            ): ClockContinuityStamp = continuity
                        },
                    )
                    if (applySweep(record, next, reason, now)) {
                        if (next.remainingMs <= 0L || reason != ExpiryReason.NotExpired) {
                            expired += 1
                            copies.remove(hex)
                            checkpoints.remove(hex)
                        } else {
                            debited += 1
                        }
                    } else {
                        refusedReplenish += 1
                    }
                    reasons[reason.name] = (reasons[reason.name] ?: 0) + 1
                    continue
                }
                val (next, reason) = RetentionClock.checkpoint(prior, now, wallEstimateMs, adapter)
                if (next.remainingMs <= 0L || reason != ExpiryReason.NotExpired) {
                    if (store.expireCandidate(record.ackKey)) {
                        expired += 1
                        copies.remove(hex)
                        checkpoints.remove(hex)
                    }
                } else if (store.debitCandidateLifetime(record.ackKey, next.remainingMs)) {
                    debited += 1
                    checkpoints[hex] = next
                } else {
                    refusedReplenish += 1
                }
                reasons[reason.name] = (reasons[reason.name] ?: 0) + 1
            }
            lastSweepMs = now
            return AckSweepReport(rows.size, debited, expired, refusedReplenish, reasons, false)
        }
    }

    /** Apply one restored-candidate debit. False when the store refused it. */
    private fun applySweep(record: AckFrameRecord, next: RetentionCheckpoint,
                           reason: ExpiryReason, now: Long): Boolean {
        val hex = record.ackKey.hex()
        if (next.remainingMs <= 0L || reason != ExpiryReason.NotExpired) {
            return store.expireCandidate(record.ackKey)
        }
        if (store.debitCandidateLifetime(record.ackKey, next.remainingMs)) {
            checkpoints[hex] = next
            return true
        }
        return false
    }

    // ---------------------------------------------------------------- internals

    private fun prepare(record: AckFrameRecord, frame: FrameV2): AckForwardCopy {
        val forwarded = FrameV2(
            type = TypeV2.ACK,
            msgId = frame.msgId,
            routingTag = frame.routingTag,  // the canonical recipient hint, NOT a route to the origin
            ttl = frame.ttl - 1,
            hopCount = frame.hopCount + 1,
            flags = 0,
            payload = frame.payload,
        )
        return AckForwardCopy(
            ackKey = record.ackKey,
            msgId = frame.msgId,
            encodedFrame = forwarded.encode(),
            ttl = forwarded.ttl,
            hopCount = forwarded.hopCount,
            verificationClass = record.verificationClass,
        )
    }

    private fun refill(bucket: Bucket, now: Long): Int {
        val elapsed = now - bucket.refilledAtMs
        if (elapsed <= 0L) return bucket.tokens
        val gained = (elapsed / ACK_RELAY_RATE_MS).toInt()
        if (gained > 0) {
            bucket.tokens = minOf(ACK_RELAY_BURST_PER_PEER, bucket.tokens + gained)
            bucket.refilledAtMs = now
        }
        return bucket.tokens
    }

    private fun rowRemaining(ackKey: ByteArray): Long =
        when (val row = store.lookupByAckKey(ackKey)) {
            is FrameLookup.Found -> row.record.remainingLifetimeMs
            else -> ACK_CANDIDATE_LIFETIME_MS_LOCAL
        }

    private fun decodeOrNull(raw: ByteArray): FrameV2? = try {
        FrameV2.decode(raw)
    } catch (_e: Throwable) {
        null
    }

    companion object {
        /** The section 14 window: eight days from first local receipt. */
        const val ACK_CANDIDATE_LIFETIME_MS_LOCAL: Long = 8L * 24L * 60L * 60L * 1000L
    }
}
