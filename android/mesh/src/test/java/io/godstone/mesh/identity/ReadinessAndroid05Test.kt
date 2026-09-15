package io.godstone.mesh.identity

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ANDROID-05 — the drain may not report a CONSTANT successful sweep.
 *
 * The audit's card, step 3: "Await bounded in-flight writer/session tasks to terminate before
 * completing the drain; use typed timeout/failure instead of reporting a constant successful
 * sweep." The authority's drain returned `resourcesReleased = 1` as a hardcoded constant and its
 * `isClean` could not see in-flight work at all, so a drain that left writers and sessions RUNNING
 * was indistinguishable from one that left nothing behind.
 *
 * W01 THE POSITIVE CONTROL: a drain with nothing in flight is clean.
 * W02 in-flight work that did NOT terminate within the bound must not be reported as success.
 *
 * The seam below is a FAKE that recordeth calls; no device, emulator or radio is involved.
 */
class ReadinessAndroid05Test {

    private class FakeSeam(private val outstanding: Int) : TransportSeam {
        var disconnects: Int = 0
        var awaited: Long = -1L
        override fun startScan() {}
        override fun stopScan() {}
        override fun startAdvertising() {}
        override fun stopAdvertising() {}
        override fun disconnectAll(): Int { disconnects += 1; return outstanding }
        override fun resetResources() {}
        override fun awaitInFlight(boundMillis: Long): Int { awaited = boundMillis; return outstanding }
    }

    /** ANDROID-05 step 3: a transport that CAN report its in-flight work, and recordeth the ask. */
    private class InFlightAwareFakeTransport(private val outstanding: Int) :
        io.godstone.mesh.transport.Transport, io.godstone.mesh.transport.InFlightAwareTransport {
        var askedWith: Long = -1L
        var starts: Int = 0
        var stops: Int = 0
        override val name: String get() = "fake-in-flight-aware"
        override val isBulkCapable: Boolean get() = false
        override fun start() { starts += 1 }
        override fun stop() { stops += 1 }
        override fun peers(): kotlinx.coroutines.flow.Flow<io.godstone.mesh.transport.PeerEvent> =
            kotlinx.coroutines.flow.emptyFlow()
        override suspend fun send(peerId: ByteArray, bytes: ByteArray):
            io.godstone.mesh.transport.TransportResult = io.godstone.mesh.transport.TransportResult.Admitted
        override fun received(): kotlinx.coroutines.flow.Flow<Pair<ByteArray, ByteArray>> =
            kotlinx.coroutines.flow.emptyFlow()
        override fun awaitInFlight(boundMillis: Long): Int { askedWith = boundMillis; return outstanding }
    }

    /** ANDROID-05 step 3: a COARSE transport, which owneth no such work to report. */
    private class CoarseFakeTransport : io.godstone.mesh.transport.Transport {
        override val name: String get() = "fake-coarse"
        override val isBulkCapable: Boolean get() = false
        override fun start() {}
        override fun stop() {}
        override fun peers(): kotlinx.coroutines.flow.Flow<io.godstone.mesh.transport.PeerEvent> =
            kotlinx.coroutines.flow.emptyFlow()
        override suspend fun send(peerId: ByteArray, bytes: ByteArray):
            io.godstone.mesh.transport.TransportResult = io.godstone.mesh.transport.TransportResult.Admitted
        override fun received(): kotlinx.coroutines.flow.Flow<Pair<ByteArray, ByteArray>> =
            kotlinx.coroutines.flow.emptyFlow()
    }

    @Test
    fun testW07TheDrainReportethTheResourcesItACTUALLYReleased() {
        // A CONSTANT figure cannot tell a drain that released nothing from one that swept three
        // relations: `resourcesReleased` must MEASURE what actually left. Here: the runtime's own
        // lease (1) plus the seam's own reported sweep (3).
        val seam = FakeSeam(3)
        val authority = UnifiedRuntimeLifecycle(seam, { 1_000L })
        authority.start()
        val result = authority.drainForWipe()
        // THE ARITHMETIC IS THE MEASUREMENT, and the first draft of this arm got it WRONG: the
        // expectation was 4 (lease + sweep), but `start()` HAD OPENED A CONTEXT, so the drain really
        // retired one too -- lease 1 + context 1 + sweep 3 = 5. The lane caught the mis-expectation,
        // and the correction is written here rather than erased: a measured figure is only as good as
        // the reading of what was actually released.
        assertEquals("lease (1) + the context start() opened (1) + the seam's own sweep (3)", 5,
            result.resourcesReleased)
        assertEquals("and the drain nameth the context it retired", 1, result.contextsRetired)
        assertEquals("the seam's sweep count travelleth on unchanged", 3, result.outboundDrained)
    }

    @Test
    fun testW08ADrainThatReleasedNothingMayNotClaimARelease() {
        // THE NEGATIVE CONTROL: never started, so there is NO lease to release and NO sweep to report.
        // The old constant `1` claimed a release that never happened, which is precisely the audited
        // shape ("reporting a constant successful sweep").
        val seam = FakeSeam(0)
        val authority = UnifiedRuntimeLifecycle(seam, { 1_000L })
        val result = authority.drainForWipe()
        assertEquals("nothing was released, so nothing may be claimed", 0, result.resourcesReleased)
        assertFalse("and such a drain is NOT clean", result.isClean)
    }

    @Test
    fun testW05TheRealAdapterAsksAnInFlightAwareTransportAndReportethItsMeasuredCount() {
        // The seam's default answereth 0 -- its own KDoc sayeth the REAL adapter must override it.
        // The override ASKETH a transport that can answer, and its MEASURED count travelleth on, so a
        // drain that leaveth writers running can no longer be reported as clean.
        val transport = InFlightAwareFakeTransport(outstanding = 3)
        val seam = io.godstone.mesh.transport.LifecycleTransportAdapter(transport)
        // THE FIRST ASSERTION IS THE MEASURED COUNT, NOT THE BOUND: the seam returneth how many tasks
        // remain, and the BOUND is proven by what the transport RECORDED being asked with. (The first
        // draft of this arm confused the two and the lane caught it -- recorded rather than erased.)
        assertEquals("the MEASURED count of the transport is what the drain heareth",
            3, seam.awaitInFlight(250L))
        assertEquals("...and must have ASKED, not guessed: the bound travelleth through",
            250L, transport.askedWith)
    }

    @Test
    fun testW06ACoarseTransportIsNotPretendedToHaveBeenDrained() {
        // The NEGATIVE control: a transport that cannot answer must not be reported as drained.
        val seam = io.godstone.mesh.transport.LifecycleTransportAdapter(CoarseFakeTransport())
        assertEquals("a coarse transport answereth 0 -- the seam's default, unchanged",
            0, seam.awaitInFlight(250L))
    }

    @Test
    fun testW01ThePositiveControlADrainWithNothingInFlightIsClean() {
        val authority = UnifiedRuntimeLifecycle(FakeSeam(0), { 1_000L })
        authority.start()
        val result = authority.drainForWipe()
        assertTrue("a drain with nothing in flight must be clean", result.isClean)
        assertEquals("nothing was in flight, so nothing may be reported as in flight",
            0, result.inFlightOutstanding)
    }

    @Test
    fun testW02InFlightWorkThatDidNotTerminateMayNotBeReportedAsSuccess() {
        val authority = UnifiedRuntimeLifecycle(FakeSeam(2), { 1_000L })
        authority.start()
        val result = authority.drainForWipe()
        assertEquals("the drain must REPORT how much work was still running",
            2, result.inFlightOutstanding)
        assertFalse(
            "a drain whose in-flight writer/session tasks had NOT terminated reported SUCCESS: " +
                "a constant successful sweep",
            result.isClean)
    }
}
