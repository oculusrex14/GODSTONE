package io.godstone.mesh.render

import io.godstone.mesh.identity.CapabilityStatus
import io.godstone.mesh.identity.DrainResult
import io.godstone.mesh.identity.UnifiedRuntimeLifecycle
import io.godstone.mesh.transport.DisconnectingTransport
import io.godstone.mesh.transport.InFlightAwareTransport
import io.godstone.mesh.transport.LifecycleTransportAdapter
import io.godstone.mesh.transport.PeerEvent
import io.godstone.mesh.transport.Transport
import io.godstone.mesh.transport.TransportResult
import kotlinx.coroutines.flow.Flow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * *** RENDER/LIFECYCLE-PROBE: WHAT THE WIPE PROBE REPORTS MUST BE THE REAL TRANSPORT'S OWN NUMBERS. ***
 *
 * *The named defect class this file probes: a drain that REPORTED A CONSTANT (`resourcesReleased = 1`,
 * `outboundDrained = 1`) while the real transport severed nothing. The fix binds the report to a MEASURED count -- so
 * this court drives the PRODUCTION adapter ([LifecycleTransportAdapter]) over a transport that can answer, and
 * requires the authority's own [DrainResult] to carrieth the transport's real numbers.*
 *
 * *** AND IT PINS OBJECT IDENTITY, NOT JUST VALUES: the authority must drain exactly the lease object it acquired,
 * the adapter must govern exactly the transport it was handed, and a fresh authority must inherit neither.*
 */
class LifecycleProbeVerificationTest {

    private val clock: Long = 1_700_000_000_000L

    /**
     * A radio that reports its OWN teardown: how many links a disconnect severed, and how many in-flight tasks were
     * still running at the bound. Both are the transport's real answers -- never a constant held beside it.
     */
    private class AnsweringTransport(
        private val inFlightOutstanding: Int,
    ) : DisconnectingTransport, InFlightAwareTransport {
        var starts = 0
        var stops = 0
        var severedLinks = 3
        override val name: String get() = "answering"
        override val isBulkCapable: Boolean get() = false
        override fun start() { starts += 1 }
        override fun stop() { stops += 1 }
        override fun disconnectAll(): Int { severedLinks += 1; return severedLinks }
        override fun awaitInFlight(boundMillis: Long): Int = inFlightOutstanding
        override fun peers(): Flow<PeerEvent> =
            throw UnsupportedOperationException("not exercised by the lifecycle probes")
        override suspend fun send(peerId: ByteArray, bytes: ByteArray): TransportResult =
            throw UnsupportedOperationException("not exercised by the lifecycle probes")
        override fun received(): Flow<Pair<ByteArray, ByteArray>> =
            throw UnsupportedOperationException("not exercised by the lifecycle probes")
    }

    /** A coarse transport that can answer NOTHING -- it must be allowed to claim nothing (never a fabricated count). */
    private class CoarseTransport : Transport {
        var starts = 0
        var stops = 0
        override val name: String get() = "coarse"
        override val isBulkCapable: Boolean get() = false
        override fun start() { starts += 1 }
        override fun stop() { stops += 1 }
        override fun peers(): Flow<PeerEvent> =
            throw UnsupportedOperationException("not exercised by the lifecycle probes")
        override suspend fun send(peerId: ByteArray, bytes: ByteArray): TransportResult =
            throw UnsupportedOperationException("not exercised by the lifecycle probes")
        override fun received(): Flow<Pair<ByteArray, ByteArray>> =
            throw UnsupportedOperationException("not exercised by the lifecycle probes")
    }

    /**
     * *** (1) THE DRAIN REPORTS THE TRANSPORT'S REAL SEVERED-COUNT AND THE REAL RELEASE ARITHMETIC. ***
     *
     * *The audit's class was a HARDCODED number. This arm drives the production adapter over a transport that severs
     * a known count, and requires `outboundDrained` to be exactly that count and `resourcesReleased` to be the REAL
     * sum the authority computes (the one released lease + the retired contexts + the transport's own sweep).*
     */
    @Test
    fun theDrainReportsTheRealTransportNumbersNotAConstant() {
        val t = AnsweringTransport(inFlightOutstanding = 0)
        val auth = UnifiedRuntimeLifecycle(LifecycleTransportAdapter(t), { clock })
        auth.start()

        val drained: DrainResult = auth.drainForWipe()
        assertEquals("the answering transport's own counter IS its real answer", 4, t.severedLinks)
        assertEquals(
            "*** `outboundDrained` MUST BE THE TRANSPORT'S REAL TEARDOWN COUNT. *A constant `1` is exactly the "
                + "defect this arm exists to catch.* ***",
            t.severedLinks, drained.outboundDrained,
        )
        assertEquals(
            "*** AND `resourcesReleased` MUST BE THE REAL SUM: one released lease + the retired contexts + the "
                + "transport's own severed count -- not a literal. ***",
            1 + drained.contextsRetired + drained.outboundDrained, drained.resourcesReleased,
        )
        assertTrue("a drain with nothing outstanding is clean", drained.isClean)
        assertTrue(
            "*** AND THE REAL TRANSPORT MUST HAVE BEEN STOPPED EXACTLY ONCE -- the adapter governs the object it "
                + "was handed, not a copy. ***",
            t.stops == 1,
        )
        assertNull("the released lease is gone from the authority", auth.activeLease())
        assertFalse("and the authority is no longer started", auth.isStarted())
    }

    /**
     * *** (2) IN-FLIGHT WORK THE TRANSPORT REPORTS MAKES THE DRAIN UNCLEAN -- AND REACHES THE ADAPTER. ***
     *
     * *The card's law: a drain is not clean merely because admission closed. This arm hands the adapter a transport
     * that reports OUTSTANDING in-flight work at the bound, and requires the authority's own [DrainResult] to carry
     * that MEASURED figure (2) and to refuse to call itself clean -- then proves the boundary really was reached by
     * giving a second authority a transport that reports zero, whose drain IS clean.*
     */
    @Test
    fun inFlightWorkReportedByTheTransportReachesTheAuthorityAndMakesTheDrainUnclean() {
        val busy = AnsweringTransport(inFlightOutstanding = 2)
        val auth = UnifiedRuntimeLifecycle(LifecycleTransportAdapter(busy), { clock })
        auth.start()
        val drained = auth.drainForWipe()
        assertEquals(
            "*** THE AUTHORITY MUST CARRY THE TRANSPORT'S OWN IN-FLIGHT FIGURE. *The old adapter never overrode "
                + "`awaitInFlight`, so this was always the seam's default 0.* ***",
            2, drained.inFlightOutstanding,
        )
        assertFalse(
            "*** A DRAIN WITH OUTSTANDING WORK IS NOT CLEAN -- a constant `true` here is the audited defect. ***",
            drained.isClean,
        )

        val idle = AnsweringTransport(inFlightOutstanding = 0)
        val clean = UnifiedRuntimeLifecycle(LifecycleTransportAdapter(idle), { clock })
        clean.start()
        val cleanDrain = clean.drainForWipe()
        assertEquals("the idle transport reports zero outstanding", 0, cleanDrain.inFlightOutstanding)
        assertTrue("*** AND ITS DRAIN IS CLEAN -- the two readings must differ. ***", cleanDrain.isClean)
    }

    /**
     * *** (3) A COARSE TRANSPORT IS ALLOWED TO CLAIM NOTHING -- AND IS NOT PRETENDED TO HAVE DRAINED. ***
     *
     * *The twin law: a transport that cannot answer must not have a count invented for it. This arm drains a coarse
     * transport and requires zero severed and zero resources BEYOND the lease/contexts the authority itself owns.*
     */
    @Test
    fun aCoarseTransportClaimsNothingRatherThanAFabricatedCount() {
        val t = CoarseTransport()
        val auth = UnifiedRuntimeLifecycle(LifecycleTransportAdapter(t), { clock })
        auth.start()
        val drained = auth.drainForWipe()
        assertEquals(
            "*** A COARSE TRANSPORT MUST NOT HAVE A SEVERED COUNT INVENTED FOR IT. ***",
            0, drained.outboundDrained,
        )
        assertEquals(
            "and `resourcesReleased` is then only the lease plus the retired contexts the authority really owns",
            1 + drained.contextsRetired, drained.resourcesReleased,
        )
        assertTrue("the coarse transport was still stopped once", t.stops == 1)
    }

    /**
     * *** (4) THE LIFECYCLE PROBE'S OBJECT IDENTITY: ONE LEASE PER ACTIVATION, AND NO INHERITANCE. ***
     *
     * *The authority acquires exactly one lease object and releases THAT object; a fresh authority over the same real
     * transport inherits neither the lease nor a context. This is the object-identity contract the probe rests on.*
     */
    @Test
    fun theAuthorityOwnsOneLeaseObjectAndAFreshAuthorityInheritsNone() {
        val t = AnsweringTransport(inFlightOutstanding = 0)
        val adapter = LifecycleTransportAdapter(t)
        val a = UnifiedRuntimeLifecycle(adapter, { clock })
        a.start()
        val lease = a.activeLease()
        assertTrue("a running authority holds a live lease", lease != null)
        assertEquals("exactly one context per activation", 1, a.liveContextCount())
        assertSame("the lease is a single object", lease, a.activeLease())

        a.stop()
        assertTrue("*** THE AUTHORITY RELEASES THE VERY LEASE IT ACQUIRED. ***", lease!!.isReleased)

        val b = UnifiedRuntimeLifecycle(adapter, { clock })
        assertNull("a fresh authority inherits NO lease", b.activeLease())
        assertEquals("and NO context", 0, b.liveContextCount())
        b.start()
        assertFalse(
            "*** THE FRESH AUTHORITY ACQUIRES ITS OWN LEASE -- never the inherited one. ***",
            lease === b.activeLease(),
        )
        assertTrue("and its lease id is a distinct token", lease.leaseId != b.activeLease()!!.leaseId)
        assertTrue("the adapter still governs the one real transport", t.starts == 2 && t.stops == 1)
    }

    /**
     * *** (5) A CALLBACK ARRIVING DURING THE WIPE IS DROPPED BY THE RETIRED CONTEXT -- NO EFFECT, NO OS CALL. ***
     *
     * *The probe's semantic-negative core: a late callback must not mutate state or reach the radio. The effect is
     * observed on a real counter, and the transport's own start count is required to stay fixed.*
     */
    @Test
    fun aCallbackDuringTheWipeIsDroppedByTheRetiredContext() {
        val t = AnsweringTransport(inFlightOutstanding = 0)
        val auth = UnifiedRuntimeLifecycle(LifecycleTransportAdapter(t), { clock })
        auth.start()
        val live = auth.snapshotContexts().first()
        val startsBefore = t.starts
        var effectRan = 0
        auth.drainForWipe()
        auth.deliverToContext(live) { effectRan += 1 }
        assertEquals("*** a retired context forbids all future effects ***", 0, effectRan)
        assertEquals("and the dropped callback made no real OS call", startsBefore, t.starts)
        assertEquals("no live context survives the drain", 0, auth.liveContextCount())
        assertFalse("the drained runtime is never READY", auth.isReady())
    }

    /**
     * *** (6) A BACKGROUND EVENT CANNOT RESURRECT A STOPPED RUNTIME AT THE REAL TRANSPORT. ***
     *
     * *The stopped runtime issues no OS call, so the transport's own `starts` cannot move after a background churn.*
     */
    @Test
    fun backgroundChurnCannotRestartTheRealTransportAfterStop() {
        val t = AnsweringTransport(inFlightOutstanding = 0)
        val auth = UnifiedRuntimeLifecycle(LifecycleTransportAdapter(t), { clock })
        auth.start()
        auth.stop()
        val startsAfterStop = t.starts
        auth.onBackgrounded()
        auth.onBackgrounded()
        assertEquals(
            "*** A BACKGROUND EVENT ON A STOPPED RUNTIME MUST ISSUE NO OS CALL. ***",
            startsAfterStop, t.starts,
        )
        assertFalse("and the runtime is not READY", auth.isReady())
    }

    /**
     * *** (7) POWER LOSS AT THE REAL BOUNDARY IS TERMINAL, AND THE TRANSPORT IS STOPPED EXACTLY ONCE. ***
     */
    @Test
    fun powerLossAtTheRealBoundaryStopsTheTransportOnceAndIsTerminal() {
        val t = AnsweringTransport(inFlightOutstanding = 0)
        val auth = UnifiedRuntimeLifecycle(LifecycleTransportAdapter(t), { clock })
        auth.start()
        auth.onPowerLoss()
        assertEquals(CapabilityStatus.TERMINAL_UNAVAILABLE, auth.capabilityState())
        assertFalse(auth.isReady())
        assertEquals("the real transport was stopped exactly once", 1, t.stops)
        val startsAfter = t.starts
        auth.start()               // a terminal runtime must not be revived
        auth.onBackgrounded()
        assertEquals("a terminal runtime cannot restart the real transport", startsAfter, t.starts)
        assertFalse("still terminal, never READY", auth.isReady())
    }
}
