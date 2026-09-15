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
