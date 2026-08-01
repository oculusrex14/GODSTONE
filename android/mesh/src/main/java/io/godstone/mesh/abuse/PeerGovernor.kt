package io.godstone.mesh.abuse

import io.godstone.mesh.wire.Priority
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.min
import kotlin.math.pow

/**
 * Anti-abuse: token-bucket rate limits and local trust scoring.
 * PROTOCOL.md section 8, documented in full and never implemented.
 *
 * WHAT THIS CLOSES. The threat model promises adversary **A5 (flooder / battery
 * attacker)** four mitigations: proof of work, per-peer token buckets, trust
 * scoring with exponential backoff, and duty-cycle floors. Only proof of work
 * existed, and it exempts SOS and DIRECT -- so an attacker could hold a link
 * open and stream unlimited exempt frames, and every phone in range would
 * process each one until the battery died.
 *
 * On a mesh whose entire premise is "battery is life" (C4), an unbounded
 * inbound rate is not a spam problem. It is a remote power-off switch.
 *
 * DESIGN. Limits are enforced at the SESSION layer, before any application
 * payload is parsed, so a malformed flood costs a bucket check rather than a
 * decode. Trust is per-node_id and purely local: there is no shared reputation
 * and no authority, because a serverless mesh has neither.
 */
class PeerGovernor(private val nowMillis: () -> Long = System::currentTimeMillis) {

    /** Per priority class, because SOS must not be starved by BROADCAST spam. */
    private val capacity = mapOf(
        Priority.SOS to 30,          // generous: latency here is a safety property
        Priority.DIRECT to 60,
        Priority.GROUP to 30,
        Priority.BROADCAST to 20,
        Priority.BULK to 10
    )
    private val refillPerSecond = mapOf(
        Priority.SOS to 0.5,
        Priority.DIRECT to 1.0,
        Priority.GROUP to 0.5,
        Priority.BROADCAST to 0.25,
        Priority.BULK to 0.1
    )

    private data class Bucket(var tokens: Double, var lastMillis: Long)
    private data class Trust(
        var score: Double = 1.0,
        var strikes: Int = 0,
        var refuseUntilMillis: Long = 0
    )

    private val buckets = ConcurrentHashMap<String, MutableMap<Priority, Bucket>>()
    private val trust = ConcurrentHashMap<String, Trust>()

    private fun key(nodeId: ByteArray) = nodeId.joinToString("") { "%02x".format(it) }

    /**
     * Should we even talk to this peer? Low trust earns an exponentially
     * growing refusal window, so a persistent attacker costs us one rejected
     * connection per window instead of continuous radio time.
     */
    fun admits(nodeId: ByteArray): Boolean {
        val t = trust[key(nodeId)] ?: return true
        return nowMillis() >= t.refuseUntilMillis
    }

    /**
     * Consume one token for an inbound frame. False means DROP IT UNPARSED.
     *
     * SOS is rate limited too, deliberately. An exempt class is an unbounded
     * channel, and an attacker will simply mark everything SOS. The bucket is
     * sized so that genuine distress traffic -- which is bursty and rare --
     * always fits, while a sustained stream does not.
     */
    fun allowInbound(nodeId: ByteArray, priority: Priority): Boolean {
        val k = key(nodeId)
        if (!admits(nodeId)) return false

        val perPeer = buckets.computeIfAbsent(k) { ConcurrentHashMap() }
        val b = perPeer.computeIfAbsent(priority) {
            Bucket((capacity[priority] ?: 10).toDouble(), nowMillis())
        }
        val now = nowMillis()
        val elapsedSec = (now - b.lastMillis) / 1000.0
        b.lastMillis = now
        b.tokens = min((capacity[priority] ?: 10).toDouble(),
                       b.tokens + elapsedSec * (refillPerSecond[priority] ?: 0.25))
        if (b.tokens < 1.0) {
            penalise(nodeId, 0.05)   // sustained overrun is itself evidence
            return false
        }
        b.tokens -= 1.0
        return true
    }

    /** Well-formed, useful traffic slowly restores trust. */
    fun reward(nodeId: ByteArray) {
        val t = trust.computeIfAbsent(key(nodeId)) { Trust() }
        t.score = min(1.0, t.score + 0.01)
        if (t.score > 0.5) t.strikes = 0
    }

    /**
     * Malformed frames, failed MACs and duplicate floods cost trust. Below the
     * floor the peer is refused for a window that doubles each time, capped so
     * a transient fault cannot permanently partition an honest neighbour.
     */
    fun penalise(nodeId: ByteArray, amount: Double = 0.2) {
        val k = key(nodeId)
        val t = trust.computeIfAbsent(k) { Trust() }
        t.score -= amount
        if (t.score <= 0.25) {
            t.strikes = min(t.strikes + 1, MAX_STRIKES)
            val backoffMs = (BASE_BACKOFF_MS * 2.0.pow(t.strikes - 1)).toLong()
            t.refuseUntilMillis = nowMillis() + backoffMs
            t.score = 0.3   // leave a path back: permanent bans partition the mesh
        }
    }

    fun trustOf(nodeId: ByteArray): Double = trust[key(nodeId)]?.score ?: 1.0

    fun forget(nodeId: ByteArray) {
        val k = key(nodeId)
        buckets.remove(k); trust.remove(k)
    }

    companion object {
        private const val BASE_BACKOFF_MS = 30_000L
        /** 30s, 1m, 2m, ... capped at ~8m. A neighbour with a flaky radio must
         *  be able to come back; only a persistent attacker stays excluded. */
        private const val MAX_STRIKES = 5
    }
}
