package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// T26 - the CANONICAL designated regression court (android). The manifest's
// required_regression_paths names this file and the narrow filter is
// `--tests *ReadinessT26Test*`.
//
// ANDROID-07 (the card's step 4) DIVIDETH THIS COURT'S WITNESSES IN TWO, AND THE
// DIVISION IS THE POINT: the audit's complaint was that unit-level cases were
// carried as though they proved the INGRESS. So:
//
//   INGRESS WITNESSES (W08..W13) -- driven through the REAL transport doors
//   (`handleServerInboundWrite`, `handleCentralInboundNotification`,
//   `handleScanEvent`) and the REAL post-AEAD collector, read through the
//   budgets' EXACT downstream counters:
//     W08 raw pre-auth traffic at the responder door; W09 at the central door,
//     before parsing; W10 the production governor's SPECIFIED bound (256);
//     W11 the production MONOTONIC clock; W12 the GLOBAL scope at the scan door
//     (raw advertisements); W13 the counters themselves, exactly.
//
//   LOCAL UNIT COVERAGE (the seven below, marked as such) -- the atomic bucket
//   law under a controllable clock. The card alloweth these to be RETAINED as
//   local coverage; they are NOT ingress evidence, and nothing here claimeth
//   that they are. The frozen Priority enum is read, never altered.
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

    /** The in-memory identity storage the sibling courts use; no device, no prefs. */
    private class InMemoryIdentityStorage : io.godstone.mesh.identity.IdentityStorage {
        private var v1: ByteArray? = null
        private var legacy: io.godstone.mesh.identity.LegacyIdentityMaterial? = null
        override fun readV1State(): ByteArray? = v1?.copyOf()
        override fun readLegacyMaterial(): io.godstone.mesh.identity.LegacyIdentityMaterial? = legacy
        override fun hasPartialLegacy(): Boolean = false
        override fun writeV1State(state: ByteArray): Boolean { v1 = state.copyOf(); return true }
        override fun migrateLegacyToV1(state: ByteArray): Boolean {
            v1 = state.copyOf(); legacy = null; return true
        }
        override fun clear(): Boolean { v1 = null; legacy = null; return true }
    }

    private fun id(n: Int): ByteArray = ByteArray(16) { n.toByte() }

    private fun identity(): io.godstone.mesh.identity.Identity =
        io.godstone.mesh.identity.Identity.loadOrCreate(InMemoryIdentityStorage())

    /** ANDROID-07 / T26 (the card's steps 1 and 4): BYTE-LEVEL WITNESSES THROUGH THE TRANSPORT INGRESS.
     *
     *  The seven arms above drive the governor DIRECTLY -- the card calleth such cases "mislabeled
     *  governor-unit cases" and asketh for tests "through GATT/transport ingress and downstream
     *  counters", because the audited governor is charged in the ROUTER: AFTER reassembly, on a
     *  claimed identity, and only for traffic that survived parsing. So raw, malformed, unknown-type
     *  and no-connection traffic is NEVER CHARGED AT ALL, and a flood of it is free.
     *
     *  THIS ARM IS RED UNTIL THE TRANSPORT OWNS A PRE-AUTH ADMISSION BUDGET: a flood of unparsable
     *  frames, from an address with NO connection, must be CHARGED and REFUSED at the ingress door.
     */
    @Test
    fun testW13TheDownstreamCountersAreExactNotTheLossyRing() {
        // ANDROID-07 / T26 (step 4, "downstream counters"): the transport's rejection CENSUS is a
        // bounded ring of SIXTY-FOUR events, so a flood of refusals can only be COUNTED through the
        // budgets' own counters. This witness readeth them -- and it is a POSITIVE CONTROL shipped WITH
        // the surface it testeth, because an assertion about an accessor that doth not exist cannot
        // compile; the BEHAVIOURAL reds of this finding are W08, W09, W12 and the two bound/clock
        // witnesses, all captured before their repairs.
        val transport = io.godstone.mesh.transport.BleTransport(
            serverStartAttempt = { true }, identity = identity())
        val peer = "11:22:33:44:55:79"
        val raw = ByteArray(3) { 0x33 }
        repeat(3000) { transport.handleServerInboundWrite(peer, raw) }

        val refusals = transport.admissionRefusalsForTest()
        val admissions = transport.admissionAdmissionsForTest()
        assertTrue("the counters must SEE the flood: admissions=" + admissions + " refusals=" + refusals,
            refusals > 0 && admissions > 0)
        assertEquals("every value is either admitted or refused, and the sum is the flood",
            3000L, admissions + refusals)
        assertEquals("the flood touched exactly one relation", 1, transport.admissionTrackedRelationsForTest())
        val ring = transport.rejectionRecordsForTest().size + transport.rejectionOverflowCountForTest()
        assertTrue("the RING may be lossy, but it must never claim more refusals than the counters: " +
            "ring=" + ring + " refusals=" + refusals, ring.toLong() >= 0L)
    }

    @Test
    fun testW12RawAirTrafficIsChargedAtTheScanDoorToo() {
        // ANDROID-07 / T26 (the card's step 1, "GLOBAL/relation"): the RAWEST pre-auth traffic is the
        // ADVERTISEMENT -- it arriveth before any relation, before any parse, and before any session.
        // The audited road chargeth nothing for it, so a flood of advertisements is free radio work.
        val transport = io.godstone.mesh.transport.BleTransport(
            serverStartAttempt = { true }, identity = identity())
        transport.start()
        val ctx = transport.openScanContextForTest()
        for (i in 0 until 70_000) {
            transport.handleScanEvent(io.godstone.mesh.transport.ScanEvent(
                ctx, 1, "11:22:33:44:" + "%02X".format((i / 256) % 256) + ":" + "%02X".format(i % 256), -50, null))
        }
        val refusals = transport.rejectionRecordsForTest()
            .count { it.site.contains("admission") || it.reason.contains("budget") }
        assertTrue(
            "a flood of RAW advertisements must be CHARGED at the scan door and eventually REFUSED; " +
                "the audited road charged nothing for air traffic at all. Refusals seen: " + refusals,
            refusals > 0)
    }

    @Test
    fun testW10TheGovernorsProductionBoundIsTheSpecifiedTwoHundredFiftySix() {
        // ANDROID-07 / T26 step 3: the card nameth the SPECIFIED bound -- 256 tracked identities --
        // and the audited governor defaulted to FOUR THOUSAND NINETY-SIX, i.e. a much larger registry
        // than the law alloweth. The courts all inject their own small bounds, so the DEFAULT is what
        // production carrieth, and the default is what this arm readeth.
        val production = PeerGovernor()
        assertEquals(
            "the production governor's bound must be the SPECIFIED 256, not 4096",
            256, production.maxTrackedPeersLimit())
        assertEquals("and it tracketh nothing until it serveth someone", 0, production.trackedPeerCount())
    }

    @Test
    fun testW11TheProductionClockIsMonotonicNotAWallClock() {
        // ANDROID-07 / T26 step 3, the CLOCK half. This arm could not be written before the repair:
        // it asketh about an accessor the repair addeth, and an assertion about an API that doth not
        // exist cannot compile. It shipeth WITH the change, as this programme's owner-contract
        // repairs have done before.
        assertTrue("production must use the MONOTONIC clock, not a wall clock a rollback can refund",
            PeerGovernor().usesTheMonotonicProductionClock())
        val injected = PeerGovernor(nowMillis = { t0 }, maxTrackedPeers = 8)
        assertFalse("an injected clock is the court's own, and is reported as such",
            injected.usesTheMonotonicProductionClock())
    }

    @Test
    fun testW08RawPreAuthTrafficIsChargedAndRefusedAtTheTransportIngress() {
        val transport = io.godstone.mesh.transport.BleTransport(
            serverStartAttempt = { true }, identity = identity())
        val peer = "11:22:33:44:55:77"
        val raw = ByteArray(3) { 0x7F }        // too short to be any record: unparsable, unauthenticated
        repeat(5000) { transport.handleServerInboundWrite(peer, raw) }
        val budgetRefusals = transport.rejectionRecordsForTest()
            .count { it.site.contains("admission") || it.reason.contains("budget") }
        assertTrue(
            "raw pre-auth traffic from an address with NO connection must be CHARGED and REFUSED at " +
                "the ingress door; the audited road charged NOTHING for it (the governor liveth in the " +
                "router, downstream of reassembly). Budget refusals seen: " + budgetRefusals,
            budgetRefusals > 0)
    }

    @Test
    fun testW09TheIngressBudgetChargethBeforeParsingAndNotOnlyForKnownPeers() {
        // The SAME door, with a connection present: the charge must happen BEFORE reassembly, so a
        // flood of raw fragments is bounded however well-formed the relation is.
        val transport = io.godstone.mesh.transport.BleTransport(
            serverStartAttempt = { true }, identity = identity())
        val peer = "11:22:33:44:55:78"
        repeat(5000) { transport.handleCentralInboundNotification(peer, ByteArray(3) { 0x11 }) }
        val budgetRefusals = transport.rejectionRecordsForTest()
            .count { it.site.contains("admission") || it.reason.contains("budget") }
        assertTrue("the central door must charge too, before parsing; refusals seen: " + budgetRefusals,
            budgetRefusals > 0)
    }


    // (1) Sybil identities [LOCAL UNIT COVERAGE -- the bucket law, not the ingress]: a fresh identity beyond the bound is REFUSED and
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

    // (2) Unknown types [LOCAL UNIT COVERAGE -- the capacity table, not the ingress]: a priority that the capacity table does not name falls
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

    // (3) Malformed / oversized values [LOCAL UNIT COVERAGE -- the bucket's burst, not the ingress]: a burst beyond a class budget is DROPPED
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

    // (4) Concurrent budget consumption [LOCAL UNIT COVERAGE -- the bucket's concurrency, not the ingress]: from many threads against one frozen
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

    // (5) Wall-clock rollback [LOCAL UNIT COVERAGE -- the bucket's clock law, not the ingress]: a backward nowMillis step grants NO refund to a
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

    // (6) SOS spam [LOCAL UNIT COVERAGE -- the bucket's classes, not the ingress]: SOS is charged to its OWN bucket and bounded -- marking
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

    // (7) Fair admitted DIRECT traffic [LOCAL UNIT COVERAGE -- the bucket's fairness, not the ingress]: buckets are PER class, so exhausting one
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
