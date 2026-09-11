package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// T28 - the CANONICAL designated regression court (android side). The manifest
// required_regression_paths names this file; the narrow filter is
// `--tests *ReadinessT28Test*`. It drives the unified lifecycle authority
// (identity/UnifiedRuntimeLifecycle) through an injected FAKE transport seam that
// records EVERY OS-boundary call, so the required behavioural laws are executed:
// repeated start/stop, background cannot start a stopped runtime (no OS calls),
// power loss mid-run uniformly invalidates and is terminal (never READY),
// permission removal is terminal, a lifecycle callback during wipe is dropped by
// the retired context, and process recreation inherits no session and no lease.
// The iOS twin court ReadinessT28Tests.swift mirrors these witnesses; the T28-SM
// roster strikes the two named falsifications.
// ---------------------------------------------------------------------------

import io.godstone.mesh.identity.CapabilityStatus
import io.godstone.mesh.identity.RuntimeTransportLease
import io.godstone.mesh.identity.TransportSeam
import io.godstone.mesh.identity.UnifiedRuntimeLifecycle
import io.godstone.mesh.transport.LifecycleTransportAdapter
import io.godstone.mesh.transport.PeerEvent
import io.godstone.mesh.transport.Transport
import io.godstone.mesh.transport.TransportResult
import kotlinx.coroutines.flow.Flow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadinessT28Test {

    private val clock: Long = 1_700_000_000_000L

    private class FakeSeam: TransportSeam {
        var scanStarts = 0
        var scanStops = 0
        var advStarts = 0
        var advStops = 0
        var disconnects = 0
        var resets = 0
        val ops = mutableListOf<String>()
        override fun startScan() { scanStarts += 1; ops.add("startScan") }
        override fun stopScan() { scanStops += 1; ops.add("stopScan") }
        override fun startAdvertising() { advStarts += 1; ops.add("startAdvertising") }
        override fun stopAdvertising() { advStops += 1; ops.add("stopAdvertising") }
        override fun disconnectAll(): Int { disconnects += 1; ops.add("disconnectAll"); return disconnects }
        override fun resetResources() { resets += 1; ops.add("resetResources") }
        fun startsOsCalls(): Int = scanStarts + advStarts
    }

    private fun newAuthority(fake: FakeSeam, adapterPresent: Boolean = true, permissionGranted: Boolean = true) =
        UnifiedRuntimeLifecycle(seam = fake, nowMillis = { clock }, adapterPresent = adapterPresent, permissionGranted = permissionGranted)

    // (1) repeated start is idempotent and creates exactly one context + one lease + one scan
    @Test
    fun testStartIsIdempotentAndBeginsExactlyOneContext() {
        val fake = FakeSeam()
        val a = newAuthority(fake)
        a.start()
        a.start()
        a.start()
        assertEquals("a repeated start begins the scanner once", 1, fake.scanStarts)
        assertEquals("a repeated start begins advertising once", 1, fake.advStarts)
        assertEquals("exactly one live context per activation", 1, a.liveContextCount())
        assertTrue("the authority is READY once started with adapter + permission", a.isReady())
    }

    // (2) BACKGROUND cannot start a STOPPED runtime -- the semantic-negative core (T28-SM1 witness)
    @Test
    fun testBackgroundCanNotStartAStoppedRuntimeMakesNoOsCalls() {
        val fake = FakeSeam()
        val a = newAuthority(fake)
        a.start()
        val before = fake.startsOsCalls()
        a.stop()
        assertFalse("the runtime is not READY once stopped", a.isReady())
        a.onBackgrounded()
        a.onBackgrounded()
        assertEquals("a background event on a stopped runtime issues NO OS call", before, fake.startsOsCalls())
        assertFalse("still not READY after background churn", a.isReady())
    }

    // (3) power loss mid-run UNIFORMLY invalidates and is terminal, never READY (T28-SM2 witness)
    @Test
    fun testPowerLossUniformlyInvalidatesAndIsTerminalNeverReady() {
        val fake = FakeSeam()
        val a = newAuthority(fake)
        a.start()
        a.onPowerLoss()
        assertTrue("power-off disconnected the transport", fake.disconnects >= 1)
        assertTrue("power-off stopped the scanner", fake.scanStops >= 1)
        assertTrue("power-off stopped advertising", fake.advStops >= 1)
        assertEquals("power-off is a typed terminal capability", CapabilityStatus.TERMINAL_UNAVAILABLE, a.capabilityState())
        assertFalse("a powered-off runtime is never READY", a.isReady())
        val after = fake.startsOsCalls()
        a.start()                 // a terminal runtime must NOT be revived
        a.onBackgrounded()
        assertEquals("a terminal runtime cannot be restarted into new OS calls", after, fake.startsOsCalls())
        assertFalse("still terminal, never READY", a.isReady())
    }

    // (4) permission removal is a typed terminal state, never READY
    @Test
    fun testPermissionRemovalIsTerminalNeverReady() {
        val fake = FakeSeam()
        val a = newAuthority(fake)
        a.start()
        a.onPermissionRemoved()
        assertEquals("revoked permission is a typed terminal capability", CapabilityStatus.TERMINAL_PERMISSION_REVOKED, a.capabilityState())
        assertFalse("a permission-revoked runtime is never READY", a.isReady())
        val after = fake.startsOsCalls()
        a.start()
        a.onBackgrounded()
        assertEquals("a revoked runtime cannot be restarted into new OS calls", after, fake.startsOsCalls())
        assertFalse("still terminal, never READY", a.isReady())
    }

    // (5) the lifecycle callback that arrives during/after a wipe is dropped by the retired context
    @Test
    fun testLifecycleCallbackDuringWipeIsDroppedByRetiredContext() {
        val fake = FakeSeam()
        val a = newAuthority(fake)
        a.start()
        val live = a.snapshotContexts().first()
        val before = fake.startsOsCalls()
        var effectRan = 0
        a.drainForWipe()                 // retire every context as part of the wipe drain
        a.deliverToContext(live) { effectRan += 1; fake.startScan() }
        assertEquals("a retired context forbids all future effects", 0, effectRan)
        assertEquals("the dropped callback made no OS call", before, fake.startsOsCalls())
        assertEquals("no live context survives the wipe drain", 0, a.liveContextCount())
    }

    // (6) the wipe path drains (retire + disconnect + stop + reset) BEFORE key erasure
    @Test
    fun testWipeDrainsBeforeKeyErasure() {
        val fake = FakeSeam()
        val a = newAuthority(fake)
        a.start()
        fake.ops.clear()
        val drained = a.drainForWipe()
        fake.ops.add("eraseKeys")        // the platform key erasure the caller performs AFTER the drain returns
        val eraseIdx = fake.ops.indexOfFirst { it == "eraseKeys" }
        for (op in listOf("disconnectAll", "stopAdvertising", "stopScan", "resetResources")) {
            val i = fake.ops.indexOfFirst { it == op }
            assertTrue("the wipe drained '$op' before key erasure", i >= 0 && i < eraseIdx)
        }
        assertTrue("the drain reported a clean release", drained.isClean)
        assertFalse("the runtime is no longer started after a wipe drain", a.isStarted())
    }

    // (7) process recreation creates NO inherited session and NO inherited lease
    @Test
    fun testProcessRecreationInheritsNoSessionAndNoLease() {
        val fakeA = FakeSeam()
        val a = newAuthority(fakeA)
        a.start()
        val leaseA: RuntimeTransportLease = a.activeLease()!!
        assertTrue("a running authority holds a live lease", a.liveContextCount() >= 1)
        a.stop()
        assertTrue("the old lease is released exactly once on stop", leaseA.isReleased)

        val fakeB = FakeSeam()
        val b = newAuthority(fakeB)
        assertTrue("a fresh authority inherits NO lease", b.activeLease() == null)
        assertEquals("a fresh authority inherits NO session context", 0, b.liveContextCount())
        b.start()
        val leaseB: RuntimeTransportLease = b.activeLease()!!
        assertFalse("the fresh authority acquires its OWN lease, never the inherited one", leaseA === leaseB)
        assertTrue("the fresh lease is a distinct token", leaseA.leaseId != leaseB.leaseId)
        assertEquals("the fresh authority begins exactly one context", 1, b.liveContextCount())
    }

    // ---- integration: the authority composed over the REAL Transport contract via the production adapter ----
    private class RecordingTransport: Transport {
        var starts = 0
        var stops = 0
        override val name: String get() = "recording"
        override val isBulkCapable: Boolean get() = false
        override fun start() { starts += 1 }
        override fun stop() { stops += 1 }
        override fun peers(): Flow<PeerEvent> = throw UnsupportedOperationException("not exercised by the lifecycle witnesses")
        override suspend fun send(peerId: ByteArray, bytes: ByteArray): TransportResult = throw UnsupportedOperationException("not exercised by the lifecycle witnesses")
        override fun received(): Flow<Pair<ByteArray, ByteArray>> = throw UnsupportedOperationException("not exercised by the lifecycle witnesses")
    }

    @Test
    fun testAdapterGovernsTheRealTransportAndBackgroundCannotStartAStoppedRuntime() {
        val t = RecordingTransport()
        val a = UnifiedRuntimeLifecycle(LifecycleTransportAdapter(t), { clock })
        a.start()
        assertEquals("a single activation starts the real transport exactly once", 1, t.starts)
        a.stop()
        assertEquals("a drain stops the real transport exactly once", 1, t.stops)
        val before = t.starts
        a.onBackgrounded()
        a.onBackgrounded()
        assertEquals("a background event on a stopped runtime must not re-start the real transport", before, t.starts)
    }

    @Test
    fun testAdapterPowerOffUniformlyStopsTheRealTransportAndIsTerminal() {
        val t = RecordingTransport()
        val a = UnifiedRuntimeLifecycle(LifecycleTransportAdapter(t), { clock })
        a.start()
        a.onPowerLoss()
        assertTrue("power-off drove the real transport to stop once (uniform invalidation)", t.stops >= 1)
        assertFalse("a powered-off runtime is never READY", a.isReady())
        val before = t.starts
        a.start()
        a.onBackgrounded()
        assertEquals("a terminal runtime cannot re-start the real transport", before, t.starts)
        assertFalse("still terminal, never READY", a.isReady())
    }

    @Test
    fun testAdapterRepeatedAuthorityStartStartsTheRealTransportOnce() {
        val t = RecordingTransport()
        val a = UnifiedRuntimeLifecycle(LifecycleTransportAdapter(t), { clock })
        a.start()
        a.start()
        a.start()
        assertEquals("repeated authority start issues exactly one real Transport.start", 1, t.starts)
    }
}
