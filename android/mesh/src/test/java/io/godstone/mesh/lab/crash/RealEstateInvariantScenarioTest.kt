package io.godstone.mesh.lab.crash

import io.godstone.mesh.store.AdmissionResult
import io.godstone.mesh.store.DeliveryState as StoreDeliveryState
import io.godstone.mesh.store.HeldRow
import io.godstone.mesh.store.Measured
import io.godstone.mesh.store.ObservationLease
import io.godstone.mesh.store.QuotaSnapshot
import io.godstone.mesh.store.StoreQuota
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * *** GS-CRASH-001 `estate-invariants`: THE STORE'S OWN LAWS THAT A CRASH MAY NOT BREAK. ***
 *
 * *Six scenarios over the REAL store-policy owners the runtime binds. Each is paired with a live composition so the
 * policy is not courted in a vacuum: the caps and the observer discipline are the store's OWN (`StoreQuota`,
 * `ObservationLease`), and the durable count assertions read the rig's real on-disk estate.*
 *
 * *** THESE ARE THE INVARIANTS A CRASH/TERMINATION PATH DEPENDS ON: *** *a store that could be driven over its hard cap
 * would make "the crashed author's estate survives" unbounded; a checkpoint that ran INSIDE an open transaction would
 * break the very atomicity the crash boundary relies on; and an observer that fired REENTRANTLY during a dispatch
 * could mutate the estate in the middle of a commit.*
 */
internal class RealEstateInvariantScenarioTest : CrashScenarioCourt() {

    private fun healthy(
        held: Long = 0L,
        total: Long = 0L,
        deliv: Long = 0L,
        inbox: Long = 0L,
        tomb: Long = 0L,
        trust: Long = 0L,
    ) = QuotaSnapshot(
        heldBytes = Measured.Values(held),
        totalBytes = Measured.Values(total),
        deliveryRows = Measured.Values(deliv),
        inboxRows = Measured.Values(inbox),
        tombstoneRows = Measured.Values(tomb),
        trustPins = Measured.Values(trust),
        inActiveTransaction = false,
        walBytes = 0L,
    )

    // ---------------------------------------------------------------- W01

    /** W01 -- THE HELD HARD CAP IS ENFORCED, AND A QUERY FAILURE IS NEVER READ AS ZERO. */
    @Test
    fun test_w01_theHeldHardCapIsEnforcedAndAQueryFailureIsNeverAccepted() {
        val under = healthy(held = StoreQuota.HELD_FRAME_HARD_CAP - 1024L)
        assertTrue("a frame that fiteth under the cap is admitted", StoreQuota.admit(under, 1024L, false, false).isAccepted())
        val over = healthy(held = StoreQuota.HELD_FRAME_HARD_CAP - 1L)
        assertEquals(
            "*** a single byte over the 64 MiB hard cap is REFUSED ***",
            AdmissionResult.RejectedHeldCap, StoreQuota.admit(over, 2L, false, false),
        )
        assertTrue(
            "the cap holds INCLUDING SOS -- an SOS frame is not a bypass",
            StoreQuota.admit(over, StoreQuota.MIB, false, false) == AdmissionResult.RejectedHeldCap,
        )
        // A FAILED READ IS A QueryError -- DISTINCT from both acceptance and a real rejection.
        val failed = QuotaSnapshot(
            heldBytes = Measured.QueryFailure("disk gone"),
            totalBytes = Measured.Values(0L), deliveryRows = Measured.Values(0L),
            inboxRows = Measured.Values(0L), tombstoneRows = Measured.Values(0L),
            trustPins = Measured.Values(0L), inActiveTransaction = false, walBytes = 0L,
        )
        val verdict = StoreQuota.admit(failed, 1L, false, false)
        assertTrue("*** a query failure must NEVER be admitted as an unbounded zero ***", verdict is AdmissionResult.QueryError)
    }

    // ---------------------------------------------------------------- W02

    /** W02 -- THE EVICTION PLAN KEEPS THE HARD CAP AND MOVES DELIVERY STATE IN THE SAME PLAN. */
    @Test
    fun test_w02_theEvictionPlanKeepsTheCapAndMovesDeliveryStateTogether() {
        val rows = listOf(
            HeldRow("sos", priority = 0, receivedAt = 1L, size = 2L * StoreQuota.MIB),
            HeldRow("new-direct", priority = 2, receivedAt = 30L, size = 2L * StoreQuota.MIB),
            HeldRow("old-direct", priority = 2, receivedAt = 10L, size = 4L * StoreQuota.MIB),
        )
        val measured = StoreQuota.HELD_FRAME_HARD_CAP + 3L * StoreQuota.MIB
        val plan = StoreQuota.evictionPlan(rows, measured)
        assertTrue("*** the hard cap must hold after the plan ***", StoreQuota.hardCapHoldsAfter(rows, measured))
        assertTrue("something was evicted", plan.evictedIds.isNotEmpty())
        assertTrue(
            "*** SOS (priority 0) is retained LAST -- it is never evicted before a non-SOS row ***",
            !plan.evictedIds.contains("sos"),
        )
        assertEquals(
            "*** each evicted row carrieth its OWN delivery transition, in the same plan ***",
            plan.evictedIds.size, plan.deliveryTransitions.size,
        )
        for ((id, state) in plan.deliveryTransitions) {
            assertEquals("$id moveth to EVICTED", StoreDeliveryState.EVICTED, state)
        }
        assertTrue(
            "the oldest non-SOS direct row is evicted before the newer one",
            plan.evictedIds.indexOf("old-direct") < plan.evictedIds.indexOf("new-direct") ||
                !plan.evictedIds.contains("new-direct"),
        )
    }

    // ---------------------------------------------------------------- W03

    /** W03 -- A CHECKPOINT IS NEVER DUE INSIDE AN OPEN TRANSACTION (the crash boundary's own atomicity law). */
    @Test
    fun test_w03_aCheckpointIsNeverDueInsideAnOpenTransaction() {
        val (dueInTx, suspendInTx) = StoreQuota.checkpointState(inActiveTransaction = true, walBytes = StoreQuota.WAL_ALLOWANCE + 1L)
        assertFalse("*** a checkpoint must NOT be scheduled inside an open transaction ***", dueInTx)
        assertTrue("it SUSPENDS instead, and the caller must honour the suspension", suspendInTx)
        val (dueIdle, suspendIdle) = StoreQuota.checkpointState(inActiveTransaction = false, walBytes = StoreQuota.WAL_ALLOWANCE + 1L)
        assertTrue("outside a transaction an overshoot is DUE", dueIdle)
        assertFalse("and nothing is suspended", suspendIdle)
        val (dueUnder, _) = StoreQuota.checkpointState(inActiveTransaction = false, walBytes = StoreQuota.WAL_ALLOWANCE / 2L)
        assertFalse("under the allowance no checkpoint is due at all", dueUnder)
    }

    // ---------------------------------------------------------------- W04

    /** W04 -- AN ABORTED TRANSACTION FIRES NOTHING AND DISCARDS ITS REGISTRATIONS. */
    @Test
    fun test_w04_anAbortedTransactionFiresNothing() {
        val lease = ObservationLease()
        var fired = 0
        lease.beginTransaction()
        val token = lease.register { fired++ }
        lease.abort()
        assertEquals("*** an abort discards the registration ***", 0, lease.registrationCount)
        lease.releaseAll()
        assertEquals("*** and nothing ever fired ***", 0, fired)
        // the token is inert after the abort too
        lease.unregisterBy(token)
        assertEquals(0, fired)
        // the positive control: a COMMITTED registration really fires
        val live = ObservationLease()
        var liveFired = 0
        live.register { liveFired++ }
        live.afterCommit()
        assertEquals("a registered observer fires on the next commit", 1, liveFired)
        live.releaseAll()
        assertEquals("and releaseAll leaveth no registration", 0, live.registrationCount)
    }

    // ---------------------------------------------------------------- W05

    /** W05 -- A REGISTRATION DURING A DISPATCH IS DEFERRED, NEVER REENTRANT. */
    @Test
    fun test_w05_aRegistrationDuringDispatchIsDeferredNotReentrant() {
        val lease = ObservationLease()
        val order = ArrayList<String>()
        lateinit var secondToken: ObservationLease.LeaseToken
        lease.register {
            order.add("first")
            // registering DURING the dispatch must NOT run reentrantly
            secondToken = lease.register { order.add("second") }
        }
        lease.afterCommit()
        assertEquals(
            "*** the first observer ran; the second was DEFERRED and did not fire in the same dispatch ***",
            listOf("first"), order,
        )
        assertEquals("the promoted deferred registration is live beside the first", 2, lease.registrationCount)
        lease.unregisterBy(secondToken)
        lease.afterCommit()
        // *** THE FIRST OBSERVER IS PERSISTENT -- it is not unregistered by firing, so it fires again -- while the
        // withdrawn SECOND never fires at all: the deferral held and the token withdrawal really took effect. ***
        assertFalse("*** the deferred observer must NEVER fire once its token was withdrawn ***", order.contains("second"))
        assertTrue("the first observer fired again on the next round", order.count { it == "first" } >= 2)
    }

    // ---------------------------------------------------------------- W06

    /** W06 -- A CRASHED AUTHOR'S ESTATE DOES NOT GROW: one held row and one delivery row, re-read after a kill. */
    @Test
    fun test_w06_aCrashedAuthorsEstateDoesNotGrowAcrossTheKill() {
        val s = establish()
        val d = dispatchCrashing(s.opener, s.responder, plaintext("w06"), "kill", offersToAllow = 0)
        assertCrashed(d)
        assertEquals("*** exactly ONE held row was committed before the crash ***", 1, rig!!.heldMsgIds(s.opener).size)
        val reopened = reopenEstate()
        reopened.makeNode(s.opener); reopened.makeNode(s.responder)
        assertEquals(
            "*** and the fresh composition re-readeth exactly that ONE row -- the kill authored nothing new ***",
            1, reopened.heldMsgIds(s.opener).size,
        )
        assertEquals("the recipient's estate is still empty", 0, reopened.heldMsgIds(s.responder).size)
    }
}
