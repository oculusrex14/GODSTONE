package io.godstone.mesh.store

// ---------------------------------------------------------------------------
// T33 SHARED QUOTA / EVICTION / OBSERVER-LEASE CONTRACT (android) -- the exact
// section14 (rows 51/57/74) store-growth & observer-lifetime algorithm. ADDITIVE,
// PURE-KOTLIN seam: it performs NO SQLite access and NO wall/heap read -- the
// measurements (held/total bytes, row counts, WAL bytes, in-transaction flag) are
// INJECTED via QuotaSnapshot, so the capacity/authority/consistency/lease laws are
// EXECUTABLE on the host via deterministic fakes (no device/SDK/network result is
// fabricated). The runtime binds this seam; the sealed wall-clock MessageStore
// held-cap/eviction/observer path (the current incomplete implementation the card
// names) is NOT rewritten -- blast-radius discipline, as the T31/T32 seams.
//
// The iOS twin (ios/Godstone/Sources/GodstoneMesh/StoreQuota.swift) mirrors this
// contract ONE-FOR-ONE and its court asserts the SAME laws (dual-court parity).
// ---------------------------------------------------------------------------

/** The bounded categories the store accounts for, each with a hard ceiling. */
enum class QuotaKind { HELD_FRAME, TOTAL_PRIVATE_STORE, DELIVERY_ROWS, INBOX_ROWS, TOMBSTONE_ROWS, TRUST_IDENTITIES }

/** A read of one measured quantity: a real value, OR a query failure. A failure is NEVER a fabricated 0. */
sealed class Measured {
    data class Values(val value: Long) : Measured()
    data class QueryFailure(val reason: String) : Measured()
    val isOk: Boolean get() = this is Values
}

/** The resources the store must NEVER silently evict under pressure -- new admission is refused instead. */
enum class Pressure { UNEXPIRED_TOMBSTONES, VERIFIED_TRUST_PINS, REVOKED_TRUST_PINS, DELIVERY_ROWS }

/** The immutable classification of a frame for admission/eviction: priority (0 = SOS, retained last), receipt order, size. */
data class Frame(val id: String, val priority: Int, val receivedAt: Long, val size: Long)

/** The transaction-owned delivery state a held row maps to; eviction must move it in the SAME transaction. */
enum class DeliveryState { QUEUED, HANDED, DELIVERED, CANCELLED, EVICTED }

/** A candidate held row carrying its delivery binding; identity is the immutable [id]. */
data class HeldRow(
    val id: String,
    val priority: Int,
    val receivedAt: Long,
    val size: Long,
    val deliveryState: DeliveryState = DeliveryState.QUEUED,
    val isUnexpiredTombstone: Boolean = false,
    val isVerifiedTrustPin: Boolean = false,
    val isRevokedTrustPin: Boolean = false,
)

/** The injected, deterministic measurements of the store at a decision instant. A null read is a QueryFailure, never 0. */
data class QuotaSnapshot(
    val heldBytes: Measured,
    val totalBytes: Measured,
    val deliveryRows: Measured,
    val inboxRows: Measured,
    val tombstoneRows: Measured,
    val trustPins: Measured,
    val inActiveTransaction: Boolean,
    val walBytes: Long,
)

/** The outcome of one admission decision. QueryError is DISTINCT from a real rejection and from acceptance. */
sealed class AdmissionResult {
    object Accepted : AdmissionResult()
    object RejectedHeldCap : AdmissionResult()
    object RejectedTotalQuota : AdmissionResult()
    data class RefusedUnderPressure(val reason: Pressure) : AdmissionResult()
    object DuplicateRejected : AdmissionResult()
    object TerminalRejected : AdmissionResult()
    data class QueryError(val reason: String) : AdmissionResult()
    fun isAccepted(): Boolean = this is Accepted
}

/** The plan of one transaction-owned eviction: which rows leave, and their delivery transitions, in stable order. */
data class EvictionPlan(val evictedIds: List<String>, val deliveryTransitions: List<Pair<String, DeliveryState>>, val cumulativeBytes: Long)

/**
 * The exact section14 policy. Stateless over the injected snapshot: every decision
 * is a pure function of the measurements, so the ordering/authority/consistency/lease
 * laws are reproducible and host-testable. All ceilings are the canonical constants.
 */
object StoreQuota {
    const val MIB: Long = 1024L * 1024L
    const val HELD_FRAME_HARD_CAP: Long = 64L * MIB       // 64 MiB held hard cap, INCLUDING SOS
    const val TOTAL_PRIVATE_STORE_QUOTA: Long = 128L * MIB
    const val DELIVERY_ROW_CAP: Int = 100000
    const val INBOX_ROW_CAP: Int = 100000
    const val TOMBSTONE_ROW_CAP: Int = 100000
    const val TRUST_IDENTITY_CAP: Int = 4096
    const val WAL_ALLOWANCE: Long = 16L * MIB            // measured bounded overshoot allowance before a checkpoint
    const val MIGRATION_PREFLIGHT_SPACE: Long = 256L * MIB

    /** Stable policy order: NON-SOS FIRST (priority > 0 ascending), then oldest-received, then id -- so SOS (priority 0) is retained-LAST, i.e. evicted only after every non-SOS. */
    val policyComparator: Comparator<HeldRow> = Comparator { a, b ->
        if (a.priority != b.priority) return@Comparator b.priority - a.priority
        if (a.receivedAt != b.receivedAt) return@Comparator if (a.receivedAt < b.receivedAt) -1 else 1
        a.id.compareTo(b.id)
    }

    private fun Measured.valueOrFailed(): Long? = (this as? Measured.Values)?.value

    /**
     * Pure admission of one candidate frame. NEVER returns Accepted on a fabricated
     * measurement: a query failure on the held or total accounting yields QueryError
     * (distinct from a rejection), so an unbounded growth caused by a mis-read 0 is
     * impossible. Under pressure it REFUSES rather than deleting protected resources.
     */
    fun admit(snapshot: QuotaSnapshot, candidateSize: Long, isDuplicate: Boolean, isTerminal: Boolean): AdmissionResult {
        val held = snapshot.heldBytes.valueOrFailed() ?: return AdmissionResult.QueryError("held bytes read failed")
        val total = snapshot.totalBytes.valueOrFailed() ?: return AdmissionResult.QueryError("total bytes read failed")
        val del = snapshot.deliveryRows.valueOrFailed() ?: return AdmissionResult.QueryError("delivery rows read failed")
        val inbox = snapshot.inboxRows.valueOrFailed() ?: return AdmissionResult.QueryError("inbox rows read failed")
        val tomb = snapshot.tombstoneRows.valueOrFailed() ?: return AdmissionResult.QueryError("tombstone rows read failed")
        val trust = snapshot.trustPins.valueOrFailed() ?: return AdmissionResult.QueryError("trust pins read failed")
        if (isDuplicate) return AdmissionResult.DuplicateRejected
        if (isTerminal) return AdmissionResult.TerminalRejected
        // (a) 64 MiB held hard cap INCLUDING SOS -- enforced, never bypassed by SOS priority.
        if (held + candidateSize > HELD_FRAME_HARD_CAP) return AdmissionResult.RejectedHeldCap
        // (b) 128 MiB total private-store quota (held + terminal + tombstone + trust + journal).
        if (total + candidateSize > TOTAL_PRIVATE_STORE_QUOTA) return AdmissionResult.RejectedTotalQuota
        // (c) row caps; at a cap REFUSE new admission rather than delete protected rows.
        if (del >= DELIVERY_ROW_CAP) return AdmissionResult.RefusedUnderPressure(Pressure.DELIVERY_ROWS)
        if (inbox >= INBOX_ROW_CAP) return AdmissionResult.RefusedUnderPressure(Pressure.DELIVERY_ROWS)
        if (tomb >= TOMBSTONE_ROW_CAP) return AdmissionResult.RefusedUnderPressure(Pressure.UNEXPIRED_TOMBSTONES)
        if (trust >= TRUST_IDENTITY_CAP) return AdmissionResult.RefusedUnderPressure(Pressure.VERIFIED_TRUST_PINS)
        return AdmissionResult.Accepted
    }

    /**
     * The transaction-owned eviction that keeps the 64 MiB held hard cap. Candidates
     * are taken in the STABLE policy order (non-SOS first, SOS retained last); a row
     * that is an unexpired tombstone or a trust pin is PROTECTED (never silently
     * evicted). The returned plan pairs every evicted held id with its delivery
     * transition (EVICTED) so held and delivery move CONSISTENTLY, in one transaction.
     */
    fun evictionPlan(rows: List<HeldRow>, measuredHeldBytes: Long): EvictionPlan {
        if (measuredHeldBytes <= HELD_FRAME_HARD_CAP) return EvictionPlan(emptyList(), emptyList(), measuredHeldBytes)
        var overshoot = measuredHeldBytes - HELD_FRAME_HARD_CAP
        val eligible = rows.sortedWith(policyComparator).filter { !it.isUnexpiredTombstone && !it.isVerifiedTrustPin && !it.isRevokedTrustPin && it.deliveryState != DeliveryState.EVICTED }
        val evicted = ArrayList<String>()
        val transitions = ArrayList<Pair<String, DeliveryState>>()
        var cum = 0L
        for (r in eligible) {
            if (overshoot <= 0L) break
            evicted.add(r.id)
            transitions.add(Pair(r.id, DeliveryState.EVICTED))   // SAME-transaction delivery update
            cum += r.size
            overshoot -= r.size
        }
        return EvictionPlan(evicted, transitions, cum)
    }

    /** The hard-cap invariant must hold AFTER the plan: no over-cap residue is left unhandled. */
    fun hardCapHoldsAfter(rows: List<HeldRow>, measuredHeldBytes: Long): Boolean {
        if (measuredHeldBytes <= HELD_FRAME_HARD_CAP) return true
        val plan = evictionPlan(rows, measuredHeldBytes)
        return plan.cumulativeBytes >= (measuredHeldBytes - HELD_FRAME_HARD_CAP)
    }

    /**
     * WAL checkpoint scheduling: a checkpoint is DUE only from the measured WAL
     * overshoot AND only when NOT inside an active transaction -- checkpointing must
     * not run inside an open tx. While an overshoot is pending and a tx is active the
     * store suspends (cannot safely checkpoint), which the caller must honour.
     */
    fun checkpointState(inActiveTransaction: Boolean, walBytes: Long): Pair<Boolean, Boolean> {
        val over = walBytes > WAL_ALLOWANCE
        val suspend = over && inActiveTransaction
        val due = over && !inActiveTransaction
        return Pair(due, suspend)
    }

    /** Bounded cursor read: a page never exceeds its limit; a null/abandoned read yields none, never a fabricated full page. */
    fun <T> fetchPage(source: List<T>, start: Int, limit: Int): List<T> {
        if (limit <= 0 || start < 0 || start >= source.size) return emptyList()
        return source.subList(start, minOf(start + limit, source.size))
    }

    private fun minOf(a: Int, b: Int): Int = if (a < b) a else b
}

/**
 * The observer lease. Handles register and fire ONLY after a commit, in registration
 * order, exactly once, and NOT reentrantly during an open transaction or an in-flight
 * dispatch: an observer registered during dispatch is deferred to the next commit.
 * An aborted transaction fires nothing. Each handle owns exactly one registration and
 * is removed by its own token only.
 */
class ObservationLease {
    class LeaseToken internal constructor(val id: Int)

    private val registrations = ArrayList<Pair<LeaseToken, () -> Unit>>()
    private val deferred = ArrayList<Pair<LeaseToken, () -> Unit>>()   // registered in an open tx (abandoned on abort) or during dispatch (fire NEXT round)
    private var nextId = 0
    private var inTx = false
    private var dispatching = false

    val active: Boolean get() = inTx

    fun beginTransaction() { inTx = true }
    // a commit ends the transaction; notifications registered within it stay pending and are promoted by the next afterCommit
    fun commit() { inTx = false }
    // an abort DISCARDS the notifications registered within the transaction -- they must never be promoted/fired
    fun abort() { inTx = false; deferred.clear() }

    fun register(observer: () -> Unit): LeaseToken {
        val t = LeaseToken(nextId++)
        val bucket = if (dispatching || inTx) deferred else registrations
        bucket.add(Pair(t, observer))
        return t
    }

    fun unregisterBy(token: LeaseToken) {
        for (b in listOf(registrations, deferred)) { val it = b.iterator(); while (it.hasNext()) if (it.next().first === token) it.remove() }
    }

    /**
     * Promote the notifications that committed since the last round (or were registered
     * reentrantly during the last dispatch) into the standing set, then fire the standing
     * set once each, in order, NOT reentrantly. An open transaction promotes/fires nothing;
     * an aborted transaction has already discarded its pending notifications so they never fire.
     */
    fun afterCommit() {
        if (inTx) return
        registrations.addAll(deferred); deferred.clear()
        dispatching = true
        try {
            val pending = ArrayList(registrations)
            val fired = HashSet<Int>()
            var i = 0
            while (i < pending.size) { val e = pending[i]; if (fired.add(e.first.id)) e.second(); i++ }
        } finally { dispatching = false }
    }
}
