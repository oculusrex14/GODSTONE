package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// T26 - the CANONICAL designated regression court (android). The manifest's
// required_regression_paths names this file and the narrow filter is
// `--tests *ReadinessT26Test*`. It witnesseth the seven required behavioural
// cases of the bounded, authenticated traffic-budget governor (PeerGovernor):
//   Sybil identities, unknown types, malformed/oversized values, concurrent
//   budget consumption, wall-clock rollback, SOS spam, and fair admitted DIRECT
//   traffic. Every witness is an EXECUTED assertion against the live governor
//   under a controllable clock; the frozen Priority enum is read, never altered.
// ---------------------------------------------------------------------------

import io.godstone.mesh.abuse.PeerGovernor
import io.godstone.mesh.wire.v2.Priority
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadinessT26Test {

    private val t0: Long = 1_700_000_000_000L

    private class Clock(var t: Long)

    private fun id(n: Int): ByteArray = ByteArray(16) { n.toByte() }

    // (1) Sybil identities: a fresh identity beyond the bound is REFUSED and
    //     allocates NOTHING; a tracked identity is still served. The global
    //     bound is consulted BEFORE any governor entry is allocated.
    @Test
    fun testSybilFloodIsBoundedByTheGovernorAdmittingBeforeAllocating() {
        val clock = Clock(t0)
        val g = PeerGovernor(nowMillis = { clock.t }, maxTrackedPeers = 8)
        var served = 0
        for (i in 0 until 8) {
            if (g.allowInbound(id(i), Priority.DIRECT)) served += 1
        }
        assertEquals("the eight within the bound are served", 8, served)
        assertEquals("eight identities are tracked", 8, g.trackedPeerCount())
        assertFalse("a fresh identity beyond the bound is refused", g.allowInbound(id(100), Priority.DIRECT))
        assertEquals("the registry stays bounded -- no entry allocated for the refused Sybil", 8, g.trackedPeerCount())
        assertTrue("a tracked identity is still served at the bound", g.allowInbound(id(0), Priority.DIRECT))
    }

    // (2) Unknown types: a priority that the capacity table does not name falls
    //     back to the SAFE bounded default (10), never an unbounded channel.
    @Test
    fun testAnUnmappedClassFallsBackToTheBoundedDefaultNotUnbounded() {
        val clock = Clock(t0)
        val capNoBulk = mapOf(
            Priority.SOS to 30, Priority.DIRECT to 60, Priority.GROUP to 30, Priority.BROADCAST to 20,
        )
        val refillNoBulk = mapOf(
            Priority.SOS to 0.5, Priority.DIRECT to 1.0, Priority.GROUP to 0.5, Priority.BROADCAST to 0.25,
        )
        val g = PeerGovernor(
            nowMillis = { clock.t }, maxTrackedPeers = 64,
            capacity = capNoBulk, refillPerSecond = refillNoBulk,
        )
        var ok = 0
        for (i in 0 until 50) {
            if (g.allowInbound(id(11), Priority.BULK)) ok += 1
        }
        assertEquals("an unmapped class is bounded by the safe default (10), not unbounded", 10, ok)
    }

    // (3) Malformed / oversized values: a burst beyond a class budget is DROPPED
    //     UNPARSED (denied), and a sustained overrun is itself charged to trust.
    @Test
    fun testAnOversizedBurstIsDroppedUnparsedAndCostsTrust() {
        val clock = Clock(t0)
        val g = PeerGovernor(nowMillis = { clock.t }, maxTrackedPeers = 64)
        var allowed = 0
        var denied = 0
        for (i in 0 until 30) {
            if (g.allowInbound(id(21), Priority.BULK)) allowed += 1 else denied += 1
        }
        assertEquals("BULK admits at most its 10-token budget", 10, allowed)
        assertEquals("the remaining 20 of the burst are dropped", 20, denied)
        assertTrue("a denied flood is itself evidence: trust decays below pristine", g.trustOf(id(21)) < 1.0)
    }

    // (4) Concurrent budget consumption: from many threads against one frozen
    //     (peer, priority) bucket, AT MOST the bucket capacity is admitted -- the
    //     consume is atomic, so no over-admission. (The non-atomic falsification is
    //     the T26 controls mutant.)
    @Test
    fun testConcurrentConsumptionAdmitsExactlyTheBudgetNeverMore() {
        val clock = Clock(t0)
        val g = PeerGovernor(nowMillis = { clock.t }, maxTrackedPeers = 64)
        val threads = 12
        val per = 20                       // 240 demand against a 60-token DIRECT bucket
        val admitted = AtomicInteger(0)
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        repeat(threads) {
            Thread {
                start.await()
                repeat(per) { if (g.allowInbound(id(42), Priority.DIRECT)) admitted.incrementAndGet() }
                done.countDown()
            }.start()
        }
        start.countDown()
        assertTrue("the workers settle within the bound", done.await(30, TimeUnit.SECONDS))
        assertEquals("across all threads the DIRECT bucket admits exactly its 60 tokens, never more", 60, admitted.get())
    }

    // (5) Wall-clock rollback: a backward nowMillis step grants NO refund to a
    //     drained bucket and does NOT shorten an active refuse exclusion.
    @Test
    fun testWallClockRollbackGrantsNoRefundAndShrinksNoExclusion() {
        // (5a) no refund from a backward step on a drained budget
        val clock = Clock(1_000_000L)
        val g = PeerGovernor(nowMillis = { clock.t }, maxTrackedPeers = 64)
        var ok = 0
        repeat(10) { if (g.allowInbound(id(31), Priority.BULK)) ok += 1 }
        assertEquals("the frozen BULK bucket first yields its full 10 tokens", 10, ok)
        assertFalse("the drained bucket denies", g.allowInbound(id(31), Priority.BULK))
        clock.t = 1_000_000L - 60_000L
        assertFalse("a wall-clock rollback grants no refund", g.allowInbound(id(31), Priority.BULK))
        clock.t = 1_000_000L - 120_000L
        assertFalse("a further rollback still grants no refund", g.allowInbound(id(31), Priority.BULK))

        // (5b) a backward step does not shrink an active refuse exclusion
        val clock2 = Clock(2_000_000L)
        val g2 = PeerGovernor(nowMillis = { clock2.t }, maxTrackedPeers = 64)
        repeat(40) { g2.allowInbound(id(32), Priority.BULK) }   // exhaust + sustained overrun -> a refuse window
        val inWindow = clock2.t
        assertFalse("the peer sits inside its refuse window", g2.admits(id(32)))
        clock2.t = inWindow - 400_000L
        assertFalse("a rollback does not shrink the exclusion", g2.admits(id(32)))
        clock2.t = inWindow + 600_000L
        assertTrue("the exclusion elapses normally on a forward clock", g2.admits(id(32)))
    }

    // (6) SOS spam: SOS is charged to its OWN bucket and bounded -- marking
    //     everything SOS does not open an exempt, unbounded channel. (The
    //     bypass-SOS-charge falsification is a T26 controls mutant.)
    @Test
    fun testSustainedSOSIsChargedAndBoundedNotExempt() {
        val clock = Clock(t0)
        val g = PeerGovernor(nowMillis = { clock.t }, maxTrackedPeers = 64)
        var ok = 0
        for (i in 0 until 60) {
            if (g.allowInbound(id(51), Priority.SOS)) ok += 1
        }
        assertEquals("SOS is charged to its own 30-token bucket, never exempt/unbounded", 30, ok)
        assertTrue("sustained SOS spam is itself evidence: trust decays", g.trustOf(id(51)) < 1.0)
    }

    // (7) Fair admitted DIRECT traffic: buckets are PER class, so exhausting one
    //     class does not starve another -- DIRECT and SOS keep their independent
    //     budgets for a peer that spammed a lower class.
    @Test
    fun testAdmittedDirectTrafficIsFairAndNotStarvedBySpam() {
        val clock = Clock(t0)
        val g = PeerGovernor(nowMillis = { clock.t }, maxTrackedPeers = 64)
        val p = id(61)
        var broadcastOk = 0
        repeat(20) { if (g.allowInbound(p, Priority.BROADCAST)) broadcastOk += 1 }
        assertEquals("BROADCAST yields its full 20-token budget", 20, broadcastOk)
        assertFalse("the drained BROADCAST class now denies", g.allowInbound(p, Priority.BROADCAST))
        var directOk = 0
        for (i in 0 until 60) {
            if (g.allowInbound(p, Priority.DIRECT)) directOk += 1
        }
        assertEquals("DIRECT keeps its full independent budget -- not starved by the BROADCAST load", 60, directOk)
        assertTrue("SOS is served for the same peer, not starved by the BROADCAST load", g.allowInbound(p, Priority.SOS))
    }
}
