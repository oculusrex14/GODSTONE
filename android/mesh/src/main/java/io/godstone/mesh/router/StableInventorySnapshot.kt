package io.godstone.mesh.router

import io.godstone.mesh.store.MessageStore

/**
 * T40 (ADR-009 section 4) -- the snapshot authority and its captured,
 * stable, bounded, sorted immutable id vectors.
 *
 * The authority is the store executor: [capture] reads the durable held
 * ids through ONE consistent streaming walk ([MessageStore.forEachHeldMsgId]),
 * never the in-memory seen cache -- the semantic negative of the card
 * names the wrong source ("Build digest from seen-but-unheld IDs ... and
 * the eviction test fails"). The vector it captures is lexicographically
 * sorted, frozen, and pinned: pages are computed against the CAPTURED
 * vector, never against a changing SQL offset ("Pin pages to the captured
 * vector, not a changing SQL offset").
 *
 * The law of the context (all bounds from ADR-009):
 *  - at most [SNAPSHOT_MAX_ROWS] rows and [SNAPSHOT_MAX_ID_BYTES] bytes of ids;
 *  - snapshotId is a nonzero monotonic u64 allocated by this context;
 *    exhaustion retires the context (allocation then REFUSES);
 *  - at most [MAX_LEASED] snapshots are shared at once (current plus one
 *    referenced predecessor); when both are leased, a new build is DEFERRED
 *    -- memory must not grow;
 *  - maximum age [SNAPSHOT_MAX_AGE_MS]; an expired snapshot is not served:
 *    the consumer is reset instead (see SyncControlOwner);
 *  - at most one build per [SNAPSHOT_MIN_BUILD_GAP_MS], under a read
 *    transaction budget of [SNAPSHOT_READ_BUDGET_MS]; breaching the budget
 *    aborts safely (the previous snapshot, if any, stands; the attempt is
 *    counted and the caller defers to the next turn);
 *  - ordinary new holds do NOT restart an active immutable snapshot;
 *  - control state and producer leases release on relation terminal.
 */
class StableInventorySnapshot internal constructor(
    val snapshotId: Long,
    /** Sorted lexicographically (unsigned octet order); immutable; each id 16 bytes. */
    val ids: List<ByteArray>,
    /** Node-clock reading of the instant of capture (monotonic milliseconds). */
    val capturedAtMono: Long,
) {
    val size: Int get() = ids.size

    fun isEmpty(): Boolean = ids.isEmpty()

    fun idAt(index: Int): ByteArray = ids[index]

    /**
     * The page following the EXCLUSIVE lexicographic [cursor] (null = the
     * start, the consumer's cursorPresent 0 form): the first at-most
     * [maxPerPage] captured ids strictly greater than the cursor, plus the
     * truth whether the walk passed the end ([ControlPayloadV1.InventoryPage.done]).
     */
    fun pageAfter(cursor: ByteArray?, maxPerPage: Int): ControlPayloadV1.InventoryPage {
        if (maxPerPage < 1 || maxPerPage > ControlPayloadV1.MAX_IDS_PER_ARM) {
            throw ControlPayloadV1.ControlException(ControlPayloadV1.ControlDecodeFailure("count_out_of_range"))
        }
        if (cursor != null && cursor.size != ControlPayloadV1.ID_BYTES) {
            throw ControlPayloadV1.ControlException(ControlPayloadV1.ControlDecodeFailure("bad_cursor"))
        }
        var start = 0
        if (cursor != null) {
            while (start < ids.size &&
                ControlPayloadV1.lexicographicCompare(ids[start], cursor) <= 0) start++
        }
        val end = minOf(start + maxPerPage, ids.size)
        val window = ArrayList<ByteArray>(end - start)
        for (k in start until end) window.add(ids[k])
        val done = if (end >= ids.size) 1 else 0
        return ControlPayloadV1.InventoryPage(snapshotId, done, window)
    }

    /** Whether [id] stands in the captured vector (the pinned truth the walk answers). */
    fun contains(id: ByteArray): Boolean {
        var lo = 0
        var hi = ids.size - 1
        while (lo <= hi) {
            val mid = (lo + hi) ushr 1
            val c = ControlPayloadV1.lexicographicCompare(ids[mid], id)
            if (c == 0) return true
            if (c < 0) lo = mid + 1 else hi = mid - 1
        }
        return false
    }

    override fun toString(): String = "snapshot(sid=$snapshotId,n=${ids.size})"

    companion object {
        const val SNAPSHOT_MAX_ROWS: Int = 100_000
        const val SNAPSHOT_MAX_ID_BYTES: Int = 1_600_000
        const val SNAPSHOT_MAX_AGE_MS: Long = 300_000L
        const val SNAPSHOT_MIN_BUILD_GAP_MS: Long = 30_000L
        const val SNAPSHOT_READ_BUDGET_MS: Long = 2_000L
        const val MAX_LEASED: Int = 2

        /** Validate and freeze a captured vector: width, distinctness, bounds, order. */
        fun of(snapshotId: Long, rawIds: List<ByteArray>, capturedAtMono: Long): StableInventorySnapshot {
            if (snapshotId == 0L) throw ControlPayloadV1.ControlException(ControlPayloadV1.ControlDecodeFailure("zero_snapshot_id"))
            if (rawIds.size > SNAPSHOT_MAX_ROWS) {
                throw ControlPayloadV1.ControlException(ControlPayloadV1.ControlDecodeFailure("count_out_of_range"))
            }
            if (rawIds.size.toLong() * ControlPayloadV1.ID_BYTES > SNAPSHOT_MAX_ID_BYTES) {
                throw ControlPayloadV1.ControlException(ControlPayloadV1.ControlDecodeFailure("count_out_of_range"))
            }
            val sorted = ArrayList<ByteArray>(rawIds.size)
            for (id in rawIds) {
                if (id.size != ControlPayloadV1.ID_BYTES) {
                    throw ControlPayloadV1.ControlException(ControlPayloadV1.ControlDecodeFailure("wrong_size"))
                }
                sorted.add(id.copyOf())
            }
            sorted.sortWith { a, b -> ControlPayloadV1.lexicographicCompare(a, b) }
            for (k in 1 until sorted.size) {
                if (sorted[k - 1].contentEquals(sorted[k])) {
                    throw ControlPayloadV1.ControlException(ControlPayloadV1.ControlDecodeFailure("duplicate_ids"))
                }
            }
            return StableInventorySnapshot(snapshotId, sorted, capturedAtMono)
        }
    }
}

/**
 * The authority context: allocator, rate limiter, lease keeper and budget
 * enforcer over the one durable [store]. [monotonicNowMillis] is injected
 * so the courts can advance the clock deterministically (the production
 * pump supplies the node's monotonic reading).
 */
class InventorySnapshotAuthority(
    private val store: MessageStore,
    private val monotonicNowMillis: () -> Long,
    firstId: Long = 0L,
) {
    private val lock = Any()
    private var counter = firstId
    private var retired = false
    private var current: StableInventorySnapshot? = null
    private var predecessor: StableInventorySnapshot? = null
    private var lastBuildAttemptMono = Long.MIN_VALUE
    private val leases = HashMap<Long, Int>()

    // counters exposed for the courts
    private var buildsDeferredByRate = 0
    private var buildsDeferredByLeases = 0
    private var buildAbortsByBudget = 0
    private var buildsRefusedByBounds = 0
    private var allocationsRefusedByExhaustion = 0

    /** The context's allocator: nonzero, strictly monotonic; exhaustion retires the context. */
    fun nextSnapshotId(): Long? = synchronized(lock) {
        if (retired) return null
        if (counter == Long.MAX_VALUE) {
            retired = true
            allocationsRefusedByExhaustion++
            return null
        }
        counter += 1L
        counter
    }

    /** The freshest admissible snapshot; null means "defer this turn". */
    suspend fun currentSnapshot(): StableInventorySnapshot? {
        val now = monotonicNowMillis()
        synchronized(lock) {
            if (retired) return null
            val cur = current
            if (cur != null && now - cur.capturedAtMono <= StableInventorySnapshot.SNAPSHOT_MAX_AGE_MS) {
                return cur   // the active immutable snapshot stands
            }
            // expired (or never born): expiry triggers a rebuild; an expired
            // snapshot is NEVER served -- the consumer gets a reset instead
            if (lastBuildAttemptMono != Long.MIN_VALUE &&
                now - lastBuildAttemptMono < StableInventorySnapshot.SNAPSHOT_MIN_BUILD_GAP_MS) {
                buildsDeferredByRate++
                return null
            }
            if (leasedCountLocked() >= StableInventorySnapshot.MAX_LEASED) {
                buildsDeferredByLeases++
                return null
            }
            lastBuildAttemptMono = now
        }
        return captureLockedOut(now)
    }

    /** Force a recapture regardless of freshness, honouring rate, leases and budget. */
    suspend fun forceSnapshot(): StableInventorySnapshot? {
        val now = monotonicNowMillis()
        synchronized(lock) {
            if (retired) return null
            if (lastBuildAttemptMono != Long.MIN_VALUE &&
                now - lastBuildAttemptMono < StableInventorySnapshot.SNAPSHOT_MIN_BUILD_GAP_MS) {
                buildsDeferredByRate++
                return null
            }
            if (leasedCountLocked() >= StableInventorySnapshot.MAX_LEASED) {
                buildsDeferredByLeases++
                return null
            }
            lastBuildAttemptMono = now
        }
        return captureLockedOut(now)
    }

    private suspend fun captureLockedOut(now: Long): StableInventorySnapshot? {
        // one consistent streaming walk over the DURABLE store -- the seen
        // cache is not consulted anywhere on this path (semantic negative)
        val started = monotonicNowMillis()
        val raw = ArrayList<ByteArray>()
        var breachBudget = false
        var breachBounds = false
        store.forEachHeldMsgId { id ->
            if (monotonicNowMillis() - started > StableInventorySnapshot.SNAPSHOT_READ_BUDGET_MS) {
                breachBudget = true
                false
            } else if (raw.size >= StableInventorySnapshot.SNAPSHOT_MAX_ROWS) {
                breachBounds = true
                false
            } else {
                raw.add(id.copyOf())
                true
            }
        }
        if (breachBounds) {
            buildsRefusedByBounds++
            return null
        }
        if (breachBudget || raw.size.toLong() * ControlPayloadV1.ID_BYTES > StableInventorySnapshot.SNAPSHOT_MAX_ID_BYTES) {
            buildAbortsByBudget++
            return null
        }
        val sid = nextSnapshotId() ?: return null
        val capturedAt = monotonicNowMillis()
        val snap = try {
            StableInventorySnapshot.of(sid, raw, capturedAt)
        } catch (_e: ControlPayloadV1.ControlException) {
            // the durable store promised distinctness; if the walk ever
            // showed otherwise the capture is refused, never falsified
            return null
        }
        return synchronized(lock) {
            val old = current
            val pre = if (old != null && (leases[old.snapshotId] ?: 0) > 0) old else null
            predecessor = pre
            current = snap
            leases[snap.snapshotId] = 0
            if (pre == null && old != null) leases.remove(old.snapshotId)
            snap
        }
    }

    fun acquire(snapshotId: Long): Boolean = synchronized(lock) {
        val cur = current
        val pre = predecessor
        val known = (cur != null && cur.snapshotId == snapshotId) || (pre != null && pre.snapshotId == snapshotId)
        if (!known) return false
        leases[snapshotId] = (leases[snapshotId] ?: 0) + 1
        true
    }

    fun release(snapshotId: Long): Boolean = synchronized(lock) {
        val held = leases[snapshotId] ?: return false
        if (held <= 0) return false
        leases[snapshotId] = held - 1
        true
    }

    fun leasedOf(snapshotId: Long): Int = synchronized(lock) { leases[snapshotId] ?: 0 }

    /** Retire a relation's claims: control state and producer leases release on terminal. */
    fun forgetLeases(owned: List<Long>) = synchronized(lock) {
        for (sid in owned) leases.remove(sid)
    }

    private fun leasedCountLocked(): Int {
        var n = 0
        val cur = current
        if (cur != null && (leases[cur.snapshotId] ?: 0) > 0) n++
        val pre = predecessor
        if (pre != null && (leases[pre.snapshotId] ?: 0) > 0) n++
        return n
    }

    // --- the observation face for the courts -----------------------------------
    fun isRetired(): Boolean = synchronized(lock) { retired }
    fun deferredByRate(): Int = synchronized(lock) { buildsDeferredByRate }
    fun deferredByLeases(): Int = synchronized(lock) { buildsDeferredByLeases }
    fun abortedByBudget(): Int = synchronized(lock) { buildAbortsByBudget }
    fun refusedByBounds(): Int = synchronized(lock) { buildsRefusedByBounds }
    fun refusedByExhaustion(): Int = synchronized(lock) { allocationsRefusedByExhaustion }
    fun currentSnapshotOrNull(): StableInventorySnapshot? = synchronized(lock) { current }
}
