package io.godstone.mesh.identity

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ANDROID-05 — the R1 supplement's T09: A FAILED START MAY NOT SUPPRESS RETRY.
 *
 * The authority froze availability when it was built (`adapterPresent` / `permissionGranted` are
 * constructor values, and `start()` consulteth them once), so a startup that failed because the
 * radio had not yet come up could NEVER be retried: no platform event could return the authority
 * to READY, and the only recovery was to build a fresh authority. That is exactly the "failed
 * startup suppresses retry" the supplement nameth.
 *
 * W01 THE POSITIVE CONTROL: an authority built with the adapter present starteth and reacheth READY.
 * W02 a start that found no adapter is not READY, and a RETRY AFTER THE ADAPTER APPEARETH must
 *     succeed rather than be suppressed for ever.
 * W03 the same law for permission: granted LATER, a retry must succeed.
 *
 * The seam is a FAKE that recordeth calls; no device, emulator or radio is involved.
 */
class ReadinessAndroid05bTest {

    private class FakeSeam : TransportSeam {
        var scans: Int = 0
        override fun startScan() { scans += 1 }
        override fun stopScan() {}
        override fun startAdvertising() {}
        override fun stopAdvertising() {}
        override fun disconnectAll(): Int = 0
        override fun resetResources() {}
    }

    @Test
    fun testW01ThePositiveControlAnAvailableAdapterStarteth() {
        val authority = UnifiedRuntimeLifecycle(FakeSeam(), { 1_000L })
        authority.start()
        assertTrue("an authority with an adapter present must reach READY", authority.isReady())
    }

    @Test
    fun testW02ARetryAfterTheAdapterAppearedMustNotBeSuppressed() {
        var present = false
        val authority = UnifiedRuntimeLifecycle(
            FakeSeam(), { 1_000L }, adapterPresent = false, adapterAvailable = { present })
        authority.start()
        assertFalse("a start with no adapter must not be READY", authority.isReady())
        present = true                              // the radio arriveth: the platform's own event
        authority.start()                           // ... and the retry
        assertTrue(
            "a failed startup SUPPRESSED retry: with the adapter now present the authority " +
                "refused to start, so only a fresh authority could ever recover",
            authority.isReady())
    }

    @Test
    fun testW03ARetryAfterPermissionWasGrantedMustNotBeSuppressed() {
        var granted = false
        val authority = UnifiedRuntimeLifecycle(
            FakeSeam(), { 1_000L }, permissionGranted = false, permissionAvailable = { granted })
        authority.start()
        assertFalse("a start without permission must not be READY", authority.isReady())
        granted = true
        authority.start()
        assertTrue(
            "a start refused for want of permission was never retryable once permission arrived",
            authority.isReady())
    }
}
