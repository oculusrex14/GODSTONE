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
}
