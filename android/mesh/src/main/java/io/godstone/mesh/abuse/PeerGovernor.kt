package io.godstone.mesh.abuse

import io.godstone.mesh.wire.v2.Priority
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.min
import kotlin.math.pow

/**
 * Anti-abuse: token-bucket rate limits and local trust scoring.
 * PROTOCOL.md section 8, documented in full.
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
 *
 * T26 HARDENING (Bound Android admission and authenticated traffic budgets).
 * Three invariants the threat model requires, now enforced here:
 *  - BOUNDED IDENTITY GOVERNOR. The per-peer registry is capped at
 *    [maxTrackedPeers]. [admitIdentity] consults the GLOBAL bound BEFORE it
 *    allocates any governor entry: a fresh peer beyond the cap is refused with
 *    no entry created, so a Sybil flood of distinct ids cannot grow the maps
 *    without limit. A peer already tracked is always served.
 *  - ATOMIC BUDGET CONSUME. The refill-then-debit of a [Bucket] runs under the
 *    bucket's own monitor, so N concurrent inbound frames for one
 *    (peer, priority) admit at most the bucket's tokens -- never more.
 *  - WALL-CLOCK ROLLBACK SAFETY. A bucket's last-contact stamp never moves
 *    backwards and a negative interval never pays tokens; a trust refuse
 *    window only ever EXTENDS, so a backward clock step cannot refund a budget
 *    or shorten an exclusion.
 * SOS and DIRECT are charged to their own buckets, never exempted, so marking
 * everything SOS does not open an unbounded channel.
 */
class PeerGovernor(
    private val nowMillis: () -> Long = System::currentTimeMillis,
    private val maxTrackedPeers: Int = DEFAULT_MAX_TRACKED_PEERS,
    private val capacity: Map<Priority, Int> = DEFAULT_CAPACITY,
    private val refillPerSecond: Map<Priority, Double> = DEFAULT_REFILL,
) {

    private data class Bucket(var tokens: Double, var lastMillis: Long)
    private data class Trust(
        var score: Double = 1.0,
        var strikes: Int = 0,
        var refuseUntilMillis: Long = 0,
    )

    private val buckets = ConcurrentHashMap<String, MutableMap<Priority, Bucket>>()
    private val trust = ConcurrentHashMap<String, Trust>()
    // Distinct tracked identities; incremented/decremented only under the instance monitor.
    private val tracked = AtomicInteger(0)

    private fun key(nodeId: ByteArray) = nodeId.joinToString("") { "%02x".format(it) }

    /**
     * Global admission gate. A peer already known is admitted unconditionally. A
     * fresh identity is admitted ONLY while the bounded registry has room, and
     * the bound is tested BEFORE any entry is allocated -- the falsification the
     * task card names ("allocate a governor entry before global admission").
     */
    private fun admitIdentity(k: String): Boolean {
        if (trust.containsKey(k) || buckets.containsKey(k)) return true
        synchronized(this) {
            if (trust.containsKey(k) || buckets.containsKey(k)) return true
            if (tracked.get() >= maxTrackedPeers) return false
            var created = false
            trust.computeIfAbsent(k) { created = true; Trust() }
            if (created) tracked.incrementAndGet()
            return true
        }
    }

    /** The mutable trust record for [k], allocating it only if global admission permits. */
    private fun mutableTrust(k: String): Trust? {
        trust[k]?.let { return it }
        if (!admitIdentity(k)) return null
        return trust[k]
    }

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
        // Bounded identity governor: the global bound is checked BEFORE any entry is
        // allocated -- an over-cap fresh identity is refused with no allocation made.
        if (!admitIdentity(k)) return false

        val perPeer = buckets.computeIfAbsent(k) { ConcurrentHashMap() }
        val capD = (capacity[priority] ?: DEFAULT_UNKNOWN_CAPACITY).toDouble()
        val refill = refillPerSecond[priority] ?: DEFAULT_UNKNOWN_REFILL
        val b = perPeer.computeIfAbsent(priority) { Bucket(capD, nowMillis()) }

        synchronized(b) {
            val now = nowMillis()
            // Wall-clock rollback safety: never move the stamp backwards, never pay
            // tokens for a negative interval; a forward step refills as usual.
            if (now >= b.lastMillis) {
                val elapsedSec = (now - b.lastMillis) / 1000.0
                val refilled = b.tokens + elapsedSec * refill
                b.tokens = if (refilled < capD) refilled else capD
                b.lastMillis = now
            }
            if (b.tokens < 1.0) {
                penalise(nodeId, 0.05)   // sustained overrun is itself evidence
                return false
            }
            b.tokens -= 1.0
            return true
        }
    }

    /** Well-formed, useful traffic slowly restores trust. */
    fun reward(nodeId: ByteArray) {
        val t = mutableTrust(key(nodeId)) ?: return
        t.score = min(1.0, t.score + 0.01)
        if (t.score > 0.5) t.strikes = 0
    }

    /**
     * Malformed frames, failed MACs and duplicate floods cost trust. Below the
     * floor the peer is refused for a window that doubles each time, capped so
     * a transient fault cannot permanently partition an honest neighbour. The
     * window only ever EXTENDS, so a rolled-back clock cannot shrink an exclusion.
     */
    fun penalise(nodeId: ByteArray, amount: Double = 0.2) {
        val k = key(nodeId)
        val t = mutableTrust(k) ?: return
        t.score -= amount
        if (t.score <= 0.25) {
            t.strikes = min(t.strikes + 1, MAX_STRIKES)
            val until = nowMillis() + (BASE_BACKOFF_MS * 2.0.pow(t.strikes - 1)).toLong()
            if (until > t.refuseUntilMillis) t.refuseUntilMillis = until
            t.score = 0.3   // leave a path back: permanent bans partition the mesh
        }
    }

    fun trustOf(nodeId: ByteArray): Double = trust[key(nodeId)]?.score ?: 1.0

    fun forget(nodeId: ByteArray) {
        val k = key(nodeId)
        synchronized(this) {
            val removedIdentity = trust.remove(k) != null
            buckets.remove(k)
            if (removedIdentity && !trust.containsKey(k) && !buckets.containsKey(k) && tracked.get() > 0) {
                tracked.decrementAndGet()
            }
        }
    }

    // Gauges for the readiness court (visible to this module's test compilation).
    internal fun trackedPeerCount(): Int = tracked.get()
    internal fun maxTrackedPeersLimit(): Int = maxTrackedPeers

    companion object {
        private const val BASE_BACKOFF_MS = 30_000L
        /** 30s, 1m, 2m, ... capped at ~8m. A neighbour with a flaky radio must
         *  be able to come back; only a persistent attacker stays excluded. */
        private const val MAX_STRIKES = 5

        const val DEFAULT_MAX_TRACKED_PEERS = 4096
        private const val DEFAULT_UNKNOWN_CAPACITY = 10
        private const val DEFAULT_UNKNOWN_REFILL = 0.25

        val DEFAULT_CAPACITY = mapOf(
            Priority.SOS to 30,
            Priority.DIRECT to 60,
            Priority.GROUP to 30,
            Priority.BROADCAST to 20,
            Priority.BULK to 10,
        )
        val DEFAULT_REFILL = mapOf(
            Priority.SOS to 0.5,
            Priority.DIRECT to 1.0,
            Priority.GROUP to 0.5,
            Priority.BROADCAST to 0.25,
            Priority.BULK to 0.1,
        )
    }
}
