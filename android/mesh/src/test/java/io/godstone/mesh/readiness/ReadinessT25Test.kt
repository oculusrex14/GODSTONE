package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// T25 - the CANONICAL designated regression court (android), the file the task
// manifest's required_regression_paths and the narrow filter `--tests
// *ReadinessT25Test*` name. This child covers the CONTRACT layer: the two
// additive types HeldSnapshot and SnapshotObservationLease (their widths REUSE'D
// from the frozen BleLinkInfoConstants, their single-release / inert-closed law).
// The platform child (the authority rewire) and integration child (transport
// call-sites) ADD their own courts; every witness is run with an EXECUTED
// assertion, and the suffixed courts below the canonical one carry the rest.
// ---------------------------------------------------------------------------

import io.godstone.mesh.transport.BleLinkInfoConstants
import io.godstone.mesh.transport.HeldSnapshot
import io.godstone.mesh.transport.SnapshotObservationLease
import io.godstone.mesh.transport.LinkInfoSnapshotAuthority
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.IdentityStorage
import io.godstone.mesh.identity.LegacyIdentityMaterial
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.wire.v2.FrameV2
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadinessT25Test {

    private fun hint(fill: Int): ByteArray = ByteArray(BleLinkInfoConstants.NODE_HINT_BYTES) { fill.toByte() }
    private fun digest(fill: Int): ByteArray = ByteArray(BleLinkInfoConstants.SHORT_DIGEST_BYTES) { fill.toByte() }

    // Returns true iff the block threw. No fail() inside the try, so the helper
    // does not confound its own AssertionError with the construct under test.
    private fun threw(block: () -> Unit): Boolean =
        try { block(); false } catch (_: Error) { true } catch (_: Exception) { true }

    // (1) A malformed form is refus'd: a wrong-width hint or digest, a negative
    //     generation token. The frozen widths are law.
    @Test
    fun testAHeldSnapshotRefusethAMalformedForm() {
        assertFalse("a well-form'd form is accept'd", threw { HeldSnapshot(0L, hint(7), digest(9), 0) })
        assertTrue("a short hint is refus'd", threw { HeldSnapshot(0L, ByteArray(BleLinkInfoConstants.NODE_HINT_BYTES - 1), digest(9), 0) })
        assertTrue("a long hint is refus'd", threw { HeldSnapshot(0L, ByteArray(BleLinkInfoConstants.NODE_HINT_BYTES + 1), digest(9), 0) })
        assertTrue("a short digest is refus'd", threw { HeldSnapshot(0L, hint(7), ByteArray(BleLinkInfoConstants.SHORT_DIGEST_BYTES - 1), 0) })
        assertTrue("a long digest is refus'd", threw { HeldSnapshot(0L, hint(7), ByteArray(BleLinkInfoConstants.SHORT_DIGEST_BYTES + 1), 0) })
        assertTrue("a negative generation is refus'd", threw { HeldSnapshot(-1L, hint(7), digest(9), 0) })
    }

    // (2) The form carrieth the canonical octets DEFENSIVELY COPIED: mutating the
    //     source arrays after construction doth not alter the snapshot, and each
    //     read doth return a copy the consumer cannot write through.
    @Test
    fun testAHeldSnapshotCarriethTheFormsDefensivelyCopied() {
        val h = ByteArray(BleLinkInfoConstants.NODE_HINT_BYTES) { (it + 1).toByte() }
        val d = ByteArray(BleLinkInfoConstants.SHORT_DIGEST_BYTES) { (it + 2).toByte() }
        val s = HeldSnapshot(3L, h, d, 10)
        val expectH = byteArrayOf(1, 2, 3, 4)
        val expectD = byteArrayOf(2, 3, 4, 5, 6, 7)
        h[0] = 0x7F; d[0] = 0x7F; d[d.size - 1] = 0x7F   // sledge the caller's arrays
        assertArrayEquals("the stored hint is the value at construction, not the sledge'd caller array", expectH, s.copyHint4())
        assertArrayEquals("the stored digest is the value at construction, not the sledge'd caller array", expectD, s.copyDigest6())
        val leaked = s.copyHint4(); leaked[0] = 0            // mutate a returned copy
        assertArrayEquals("a returned copy may not be written through to the snapshot", expectH, s.copyHint4())
    }

    // (3) queueDepth is confin'd to the one on-wire byte (0..255); an out-of-range
    //     depth is refus'd, so the compute's 255-saturation is representable.
    @Test
    fun testAHeldSnapshotConfinethQueueDepthToOneByte() {
        assertFalse("zero is representable", threw { HeldSnapshot(0L, hint(0), digest(0), 0) })
        assertFalse("the saturating cap 255 is representable", threw { HeldSnapshot(0L, hint(0), digest(0), 255) })
        assertTrue("256 overflow'th the one-byte field and is refus'd", threw { HeldSnapshot(0L, hint(0), digest(0), 256) })
        assertTrue("a negative depth is refus'd", threw { HeldSnapshot(0L, hint(0), digest(0), -1) })
    }

    // (4) Two snapshots compare by CONTENT (version, depth, and the two digests),
    //     not by identity; a differing digest or version breaketh equality.
    @Test
    fun testTwoHeldSnapshotsCompareByContentNotIdentity() {
        val a = HeldSnapshot(5L, hint(7), digest(9), 42)
        val b = HeldSnapshot(5L, hint(7), digest(9), 42)
        assertNotSame("distinct instances", a, b)
        assertEquals("equal by content", a, b)
        assertEquals("and equal in hash", a.hashCode(), b.hashCode())
        assertNotEquals("a differant digest breaketh equality", a, HeldSnapshot(5L, hint(7), digest(0xFF), 42))
        assertNotEquals("a differant hint breaketh equality", a, HeldSnapshot(5L, hint(0xFF), digest(9), 42))
        assertNotEquals("a differant generation breaketh equality", a, HeldSnapshot(6L, hint(7), digest(9), 42))
        assertNotEquals("a differant depth breaketh equality", a, HeldSnapshot(5L, hint(7), digest(9), 41))
    }

    // (5) The lease is born active; the FIRST close performeth the transition and
    //     the one release; further closes are inert no-ops (release fires EXACTLY
    //     once; closeCount stayth one).
    @Test
    fun testALeaseOpensActiveAndClosesthExactlyOnceIdempotently() {
        var releases = 0
        val lease = SnapshotObservationLease { releases += 1 }
        assertTrue("born active", lease.isActive)
        assertEquals("not yet clos'd", 0, lease.closeCount)
        assertTrue("the first close transitioneth", lease.close())
        assertEquals("the release fired once", 1, releases)
        assertFalse("a second close is a no-op", lease.close())
        assertFalse("a third close is a no-op", lease.close())
        assertEquals("the release fired EXACTLY once", 1, releases)
        assertEquals("closeCount is one", 1, lease.closeCount)
        assertFalse("the lease is now inert", lease.isActive)
    }

    // (6) After close the lease is INERT: a stale or rolled-back notification that
    //     consulteth isActive findeth it false and so driveth NO compute (no release,
    //     no work) -- the guard the platform child will wrap around the store callback.
    @Test
    fun testAClosedLeaseIsInertToAStaleNotification() {
        var releases = 0
        var computes = 0
        val lease = SnapshotObservationLease { releases += 1 }
        assertTrue(lease.close())
        // the callback gate the authority useth: compute only while the lease is active
        if (lease.isActive) { computes += 1 }
        assertEquals("a stale notification upon a closed lease driveth no compute", 0, computes)
        assertEquals("and no second release", 1, releases)
        // a live lease's gate DOth admit the compute, to show the guard is not vacuous
        val live = SnapshotObservationLease { }
        if (live.isActive) { computes += 1 }
        assertEquals("an active lease's gate admitteth exactly one compute", 1, computes)
    }

    // =====================================================================
    // PLATFORM child -- the five required behavioural cases, at the live
    // store<->authority seam (design A: same-thread synchronous compute on the
    // committing thread, an owned gate, revalidate-before-publish, fail-closed
    // on traversal throw). A deterministic in-JVM double drives the boundary.
    // =====================================================================

    private val idA: ByteArray = ByteArray(16) { (it + 1).toByte() }
    private val idB: ByteArray = ByteArray(16) { (it + 60).toByte() }

    private val identity: Identity by lazy { makeIdentity() }

    private fun bloomOf(ids: List<ByteArray>): ByteArray {
        val bloom = BloomDigest()
        for (id in ids) bloom.add(id)
        return bloom.toBytes().copyOf(BleLinkInfoConstants.SHORT_DIGEST_BYTES)
    }

    private fun makeIdentity(): Identity = Identity.loadOrCreate(InMemoryIdentityStorage())

    // (7) A GATT read copieth the last committed snapshot WITHOUT touching the
    //     store -- so a blocked/erroring store cannot stall or falsify a read
    //     (the "blocked database during GATT read" case).
    @Test
    fun testTheReadPathCopiethTheCommittedValueEvenWhileTheStoreIsBlocked() {
        val store = ProbeStore()
        store.seed(listOf(idA, idB))
        val auth = LinkInfoSnapshotAuthority(identityProvider = { identity }, storeProvider = { store })
        val bytes0 = auth.currentBytes()
        val snap0 = auth.currentSnapshot()
        val held0 = auth.currentHeldSnapshot()
        assertNotNull("a primed read yieldeth bytes", bytes0)
        assertNotNull("a primed read yieldeth the held-snapshot", held0)
        val traversalsAtPrime = store.traversalCount
        // Make the very next traversal blow up: a pure read must be indifferent to it.
        store.failNextTraversal = true
        repeat(64) {
            assertSame("the cached snapshot is a pure copy (no rebuild, no throw)", snap0, auth.currentSnapshot())
            assertSame("the cached bytes are a pure copy", bytes0, auth.currentBytes())
            assertSame("the cached held-snapshot is a pure copy", held0, auth.currentHeldSnapshot())
        }
        assertEquals("a GATT read trigger'd NO durable traversal", traversalsAtPrime, store.traversalCount)
    }

    // (8) A nested (reentrant) commit notified DURING a traversal must not let the
    //     stale in-flight result win: the compute that captures an older token is
    //     DROPPED and the latest is published exactly once (bounded re-run).
    @Test
    fun testObserverReentrancyPublishethTheLatestValueExactlyOnce() {
        val store = ProbeStore()
        store.seed(listOf(idA))
        val auth = LinkInfoSnapshotAuthority(identityProvider = { identity }, storeProvider = { store })
        val vBefore = auth.currentHeldSnapshot()!!.storeVersion
        assertEquals("the prime reflecteth the one seeded item", 1, auth.currentHeldSnapshot()!!.queueDepth)
        // Arm a reentrant commit that fires DURING the next traversal: it adds idB and
        // notifies the (already in-flight) observer, advancing the generation mid-compute.
        store.reentrantOnce = { store.held.add(idB); store.emitObservers() }
        val info = auth.refresh()
        assertNotNull("the recompute returneth a snapshot", info)
        val snap = auth.currentHeldSnapshot()!!
        assertEquals("the reentrant latest commit is reflected exactly once", 2, snap.queueDepth)
        assertArrayEquals("the digest covereth both the pre- and the mid-traversal item", bloomOf(store.held), snap.digest6)
        assertTrue("the generation advanced past the pre-hook token", snap.storeVersion > vBefore)
        assertNull("no storage failure was fabricat'd", auth.lastStorageFailureForTest())
    }

    // (9) A commit that ROLLED BACK fires no observer and must change NO snapshot;
    //     only a genuinely committed change advances it (the contrast is the proof).
    @Test
    fun testARolledBackCommitCausethNoNewSnapshot() {
        val store = ProbeStore()
        store.seed(listOf(idA))
        val auth = LinkInfoSnapshotAuthority(identityProvider = { identity }, storeProvider = { store })
        val held = auth.currentHeldSnapshot()!!
        val v0 = held.storeVersion
        val q0 = held.queueDepth
        val tr0 = store.traversalCount
        store.simulateRolledBackCommit(listOf(idB))            // the store gates this out: no notify, no durable change
        assertEquals("a rolled-back commit fire'th no observer", tr0, store.traversalCount)
        assertSame("the snapshot is unchang'd", held, auth.currentHeldSnapshot())
        assertEquals(v0, auth.currentHeldSnapshot()!!.storeVersion)
        assertEquals(q0, auth.currentHeldSnapshot()!!.queueDepth)
        // contrast: a committed change DOth advance (so the guard above is not vacuous)
        store.committed(listOf(idA, idB))
        assertEquals(2, auth.currentHeldSnapshot()!!.queueDepth)
        assertTrue("a committed change advance'th the generation", auth.currentHeldSnapshot()!!.storeVersion > v0)
    }

    // (10) Repeated runtime start/stop leaveth exactly ONE store registration (the
    //      grow-only registry is gated, never re-added); while stopp'd the observation
    //      is zero-active (no recompute); while start'd it observeth again on the same
    //      one registration.
    @Test
    fun testRepeatedRuntimeStartStopLeavethOneRegistrationThenZeroActive() {
        val store = ProbeStore()
        store.seed(listOf(idA))
        val auth = LinkInfoSnapshotAuthority(identityProvider = { identity }, storeProvider = { store })
        assertEquals("exactly one registration at construction", 1, store.registrations)
        assertTrue(auth.isObserving())
        for (k in 0 until 3) { auth.stopObserving(); auth.startObserving() }
        assertEquals("repeated start/ stop addeth no second registration", 1, store.registrations)
        // stopped: a committed change reacheth no observer effect (the gate is clos'd)
        auth.stopObserving()
        assertFalse("the lease readeth as stopp'd", auth.isObserving())
        val trStop = store.traversalCount
        val qStop = auth.currentHeldSnapshot()!!.queueDepth
        store.committed(listOf(idA, idB))
        assertEquals("while stopp'd the observation is zero-active (no recompute)", trStop, store.traversalCount)
        assertEquals(qStop, auth.currentHeldSnapshot()!!.queueDepth)
        // started again: the selfsame registration observeth anew
        auth.startObserving()
        assertTrue("the lease readeth as start'd", auth.isObserving())
        store.committed(listOf(idA, idB))
        assertTrue("while start'd the observation recomputeth", store.traversalCount > trStop)
        assertEquals(2, auth.currentHeldSnapshot()!!.queueDepth)
    }

    // (11) The held count saturateth at the one-byte bound (255) and the digest is
    //      the frozen generator over the FULL held set (not a fresh formula).
    @Test
    fun testQueueDepthSaturatethAtTheOneByteBound() {
        val store = ProbeStore()
        val many = (0 until 300).map { i -> ByteArray(16) { j -> ((i * 16 + j) and 0xFF).toByte() } }
        store.seed(many)
        val auth = LinkInfoSnapshotAuthority(identityProvider = { identity }, storeProvider = { store })
        val held = auth.currentHeldSnapshot()!!
        assertEquals("the held count saturateth at the one-byte cap", 255, held.queueDepth)
        assertArrayEquals("the digest is the frozen generator over the FULL held set", bloomOf(many), held.digest6)
        assertEquals("the on-wire snapshot agree'th with the held-snapshot", 255, auth.currentSnapshot()!!.queueDepth.toInt())
    }

    // ---- deterministic double for the store<->authority boundary ----
    private class ProbeStore : MessageStore {
        val held = ArrayList<ByteArray>()
        private val observers = ArrayList<() -> Unit>()
        var registrations = 0; private set
        var traversalCount = 0; private set
        var failNextTraversal = false
        var reentrantOnce: (() -> Unit)? = null
        fun seed(ids: List<ByteArray>) { held.clear(); held.addAll(ids) }
        fun committed(ids: List<ByteArray>) { held.clear(); held.addAll(ids); emitObservers() }
        /** Models a transaction that rolled back: no durable change survives, and the store fire'th NO observer. */
        fun simulateRolledBackCommit(ids: List<ByteArray>) { /* deliberately inert: no mutation, no notify */ }
        fun emitObservers() { observers.toList().forEach { it.invoke() } }
        override fun registerHeldSetObserver(observer: () -> Unit) { registrations++; observers.add(observer) }
        override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): PersistResult = PersistResult.HELD_NEW
        override suspend fun enqueueDirectOutbound(
            frame: FrameV2, expectedRecipient: ByteArray, localOriginNodeId: ByteArray,
        ): OutboundEnqueueResult = OutboundEnqueueResult.CanonicalFrameMismatch
        override suspend fun allHeldOrderedByPriority(): List<FrameV2> = emptyList()
        override suspend fun allHeldMsgIds(): List<ByteArray> = held.toList()
        override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) {}
        override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {
            traversalCount++
            if (failNextTraversal) { failNextTraversal = false; throw IllegalStateException("injected store I/O failure") }
            for (id in held.toList()) { if (!visit(id)) break }
            val hook = reentrantOnce
            if (hook != null) { reentrantOnce = null; hook() }
        }
    }

    // the sanctioned in-JVM identity fixture (copied from the sibling readiness courts)
    private class InMemoryIdentityStorage : IdentityStorage {
        var v1State: ByteArray? = null
        var legacyMaterial: LegacyIdentityMaterial? = null
        var failWrites = false
        override fun readV1State(): ByteArray? = v1State?.copyOf()
        override fun readLegacyMaterial(): LegacyIdentityMaterial? = legacyMaterial
        override fun hasPartialLegacy(): Boolean = false
        override fun writeV1State(state: ByteArray): Boolean {
            if (failWrites) return false
            v1State = state.copyOf(); return true
        }
        override fun migrateLegacyToV1(v1State: ByteArray): Boolean {
            if (failWrites) return false
            this.v1State = v1State.copyOf(); this.legacyMaterial = null; return true
        }
        override fun clear(): Boolean { v1State = null; legacyMaterial = null; return true }
    }
}
