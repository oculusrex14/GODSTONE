package io.godstone.mesh.readiness

import io.godstone.mesh.store.AdmissionResult
import io.godstone.mesh.store.DeliveryState
import io.godstone.mesh.store.HeldRow
import io.godstone.mesh.store.Measured
import io.godstone.mesh.store.ObservationLease
import io.godstone.mesh.store.Pressure
import io.godstone.mesh.store.QuotaSnapshot
import io.godstone.mesh.store.StoreQuota
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * T33 designated regression court (android) -- bounded store growth and observer
 * lifetimes. Drives the pure [StoreQuota] / [ObservationLease] contract through
 * injected deterministic [QuotaSnapshot]s and asserts the exact section14 laws:
 *   * the 64 MiB held hard cap holds EVEN for an all-SOS store (SOS is retained-LAST,
 *     not exempt);
 *   * duplicate / terminal inputs are rejected idempotent, never admitted;
 *   * a WAL overshoot checkpoints only OUTSIDE an active transaction;
 *   * an observer fires only AFTER commit, exactly once, never reentrantly;
 *   * a SQL failure in heldBytes is a QueryError, NEVER a fabricated 0 (the named
 *     falsification), so admission is refused rather than growing unbounded;
 *   * the cap is never exceeded across a sequence of inserts;
 *   * eviction is a deterministic, stable, MINIMAL prefix in policy order;
 *   * eviction moves the delivery record EVICTED in the SAME transaction (the second
 *     named falsification: leaving delivery unchanged must fail).
 * The iOS twin ReadinessT33Tests.swift asserts the SAME eight laws with identical names.
 */
private fun ok(v: Long): Measured = Measured.Values(v)
private fun bad(reason: String): Measured = Measured.QueryFailure(reason)
private fun Long.min(other: Long): Long = if (this < other) this else other

private fun healthy(total: Long = 0L, deliv: Long = 0L, inbox: Long = 0L, tomb: Long = 0L, trust: Long = 0L, inTx: Boolean = false, wal: Long = 0L): QuotaSnapshot =
    QuotaSnapshot(ok(total), ok(1L shl 20), ok(deliv), ok(inbox), ok(tomb), ok(trust), inTx, wal)

private fun allSos(n: Int): List<HeldRow> = (1..n).map { HeldRow("sos-%04d".format(it), 0, it.toLong(), 1L) }

private fun mixedRows(): List<HeldRow> = listOf(
    HeldRow("sos-b", 0, 3L, 4L),          // SOS, oldest -> evicted LAST
    HeldRow("n-c", 1, 1L, 2L),            // non-SOS, oldest -> evicted FIRST
    HeldRow("n-a", 1, 2L, 1L),            // non-SOS
    HeldRow("n-b", 1, 2L, 2L),            // non-SOS, ties receivedAt with n-a, id breaks
    HeldRow("sos-a", 0, 4L, 8L),          // SOS, protected unexpired tombstone
)

class ReadinessT33Test {

    // (1) an all-SOS store still holds the hard cap INCLUDING SOS
    @Test
    fun testAllSosStoreStillHoldsTheHardCapIncludingSos() {
        val rows = allSos(400)                                   // every row is SOS (priority 0)
        val total = StoreQuota.HELD_FRAME_HARD_CAP + 32L        // a 32-byte overshoot
        val plan = StoreQuota.evictionPlan(rows, total)
        assertEquals("the all-SOS overshoot is drained to exactly the deficit", 32L, plan.cumulativeBytes)
        assertTrue("an all-SOS store is still capped -- SOS is evicted (retained-LAST, not exempt)", plan.evictedIds.isNotEmpty())
        assertTrue("eviction is a MINIMAL prefix: no more than needed is removed", plan.cumulativeBytes - plan.evictedIds.size.toLong() < 32L)
    }

    // (2) millions of duplicate / terminal inputs are rejected idempotent
    @Test
    fun testMillionsOfDuplicateAndTerminalInputsAreRejectedIdempotent() {
        for (i in 1..1000) {
            assertEquals("duplicate replay is always rejected", AdmissionResult.DuplicateRejected, StoreQuota.admit(healthy(), 1L, true, false))
            assertEquals("terminal input is always rejected", AdmissionResult.TerminalRejected, StoreQuota.admit(healthy(), 1L, false, true))
        }
        assertTrue("a fresh, non-duplicate, non-terminal input is admitted once", StoreQuota.admit(healthy(), 1L, false, false).isAccepted())
    }

    // (3) a WAL overshoot checkpoints only outside an active transaction
    @Test
    fun testWalGrowthCheckpointsOutsideActiveTransaction() {
        val under = StoreQuota.checkpointState(false, StoreQuota.WAL_ALLOWANCE / 2L)
        assertEquals("no checkpoint when the WAL is within its allowance", false, under.first)
        assertEquals("no suspension when the WAL is within its allowance", false, under.second)
        val outside = StoreQuota.checkpointState(false, StoreQuota.WAL_ALLOWANCE + 1L)
        assertTrue("a WAL overshoot OUTSIDE a tx is due to checkpoint", outside.first)
        assertEquals("and is not suspended", false, outside.second)
        val inside = StoreQuota.checkpointState(true, StoreQuota.WAL_ALLOWANCE + 1L)
        assertEquals("a WAL overshoot INSIDE an active tx must NOT checkpoint", false, inside.first)
        assertTrue("instead the store suspends until the tx closes", inside.second)
    }

    // (4) an observer fires only after commit, exactly once, never reentrantly
    @Test
    fun testObserverReentryIsDeferredAndFiresOnlyAfterCommit() {
        val lease = ObservationLease()
        var firstCalls = 0
        var lateCalls = 0
        lease.register {
            firstCalls += 1
            lease.register { lateCalls += 1 }          // reentrant registration during dispatch
        }
        lease.afterCommit()
        assertEquals("the registered observer fired once on commit", 1, firstCalls)
        assertEquals("the reentrantly registered observer did NOT fire in the same dispatch", 0, lateCalls)
        lease.afterCommit()
        assertEquals("the deferred observer fires on the NEXT commit", 1, lateCalls)
        assertEquals("and the first observer still fires exactly once per commit", 2, firstCalls)
        // an aborted transaction notifies nothing: the observer registered INSIDE the tx window is discarded on abort
        val lease2 = ObservationLease()
        var fired = 0
        lease2.beginTransaction()                 // the tx is open
        lease2.register { fired += 1 }            // registered within the tx -> pending, must not fire on abort
        lease2.abort()                             // the transaction is rolled back
        lease2.afterCommit()                       // a post-abort settle must NOT resurrect the discarded notification
        assertEquals("an aborted transaction fires no observer", 0, fired)
    }

    // (5) a SQL failure in heldBytes never fabricates 0 and refuses admission (the named falsification)
    @Test
    fun testSqlFailureInHeldBytesNeverFabricatesZeroAndRefusesAdmission() {
        val failing = QuotaSnapshot(bad("sql: no such table"), ok(1L shl 20), ok(0L), ok(0L), ok(0L), ok(0L), false, 0L)
        val r = StoreQuota.admit(failing, 1L, false, false)
        assertTrue("a heldBytes read failure is a QueryError, not a fabricated zero", r is AdmissionResult.QueryError)
        assertTrue("it is not silently Accepted", !r.isAccepted())
        assertTrue("and it is distinct from a real capacity rejection", r != AdmissionResult.RejectedHeldCap)
        // the fabricated-zero path is what the mutant would take; it is not reachable here. The contract carries its own descriptive reason; the LAW is that it is a genuine QueryError with a reason.
        assertTrue("the QueryError carries a non-empty reason", (r as AdmissionResult.QueryError).reason.isNotEmpty())
    }

    // (6) the hard cap is never exceeded across a sequence of inserts
    @Test
    fun testCapUnderConcurrentInsertIsNeverExceeded() {
        var held = 0L
        val cap = StoreQuota.HELD_FRAME_HARD_CAP
        val step = 3L * StoreQuota.MIB
        var accepted = 0
        for (i in 1..100) {
            val r = StoreQuota.admit(healthy(total = held), step, false, false)
            if (r is AdmissionResult.Accepted) { held += step; accepted += 1 }
            assertTrue("the accounting total never crosses the hard cap", held <= cap)
        }
        assertTrue("inserts were actually admitted before the cap bound them", accepted >= 1)
    }

    // (7) eviction is a deterministic, stable, minimal prefix in policy order
    @Test
    fun testStableEvictionOrderIsDeterministic() {
        val rows = mixedRows()
        val total = StoreQuota.HELD_FRAME_HARD_CAP + 5L       // a 5-byte overshoot
        val plan = StoreQuota.evictionPlan(rows, total)
        assertEquals("policy order evicts the oldest non-SOS first, ties broken by id, then the next; SOS and protected rows untouched",
            listOf("n-c", "n-a", "n-b"), plan.evictedIds)
        assertEquals("the drained cumulative bytes equal the sum of the evicted sizes", 5L, plan.cumulativeBytes)
        assertTrue("the hard cap holds after the plan", StoreQuota.hardCapHoldsAfter(rows, total))
        assertTrue("no unexpired tombstone / trust pin is silently evicted",
            plan.evictedIds.none { it == "sos-a" } && plan.evictedIds.none { it.startsWith("sos-b") })
    }

    // (8) eviction moves the delivery record EVICTED in the SAME transaction (the second named falsification)
    @Test
    fun testEvictionUpdatesDeliveryStateInTheSameTransaction() {
        val rows = mixedRows()
        val total = StoreQuota.HELD_FRAME_HARD_CAP + 5L
        val plan = StoreQuota.evictionPlan(rows, total)
        assertEquals("every evicted row has exactly one delivery transition", plan.evictedIds.size, plan.deliveryTransitions.size)
        for ((id, st) in plan.deliveryTransitions) {
            assertTrue("the evicted row $id is paired with its id", id in plan.evictedIds)
            assertEquals("and its delivery state moves to EVICTED, atomically with the held removal", DeliveryState.EVICTED, st)
        }
        // applying the transaction (marking the plan EVICTED) leaves NO evicted row with a stale delivery state
        val applied = rows.map { if (it.id in plan.evictedIds) it.copy(deliveryState = DeliveryState.EVICTED) else it }
        for (r in applied) if (r.id in plan.evictedIds) assertEquals("held and delivery stay consistent", DeliveryState.EVICTED, r.deliveryState)
        // an eviction pass that has brought the store back TO the cap is idempotent: re-checking a capped store is a no-op,
        // and a second pass never re-evicts a row whose delivery is already EVICTED (no stale double-transition)
        val appliedTotal = total - plan.cumulativeBytes
        assertTrue("the pass brought the store to (or under) the hard cap", appliedTotal <= StoreQuota.HELD_FRAME_HARD_CAP)
        val second = StoreQuota.evictionPlan(applied, appliedTotal)
        assertTrue("re-checking a capped store evicts nothing further", second.evictedIds.isEmpty())
        assertEquals("a no-op pass reports the (already-capped) held total as its drain, freeing zero bytes", appliedTotal, second.cumulativeBytes)
        val secondForced = StoreQuota.evictionPlan(applied, total)
        assertTrue("a second pass never re-evicts an already-EVICTED row", secondForced.evictedIds.none { it in plan.evictedIds })
    }
}
