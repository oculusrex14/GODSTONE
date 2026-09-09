package io.godstone.mesh.readiness

import io.godstone.mesh.identity.Identity
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.transport.BleDirection
import io.godstone.mesh.transport.BleLinkInfoCodec
import io.godstone.mesh.transport.BleLinkInfoConstants
import io.godstone.mesh.transport.BleLinkInfoV1
import io.godstone.mesh.transport.BleTransport
import io.godstone.mesh.transport.RelationKey
import io.godstone.mesh.transport.ScanContext
import io.godstone.mesh.transport.ScanEvent
import io.godstone.mesh.transport.ScanFailureEvent
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.ArrayList

/**
 * T11: Android scan callbacks are bound to bounded scan epochs.
 *
 * A scan registration is created complete (epoch, callback identity, lease)
 * before the scanner is told to call anybody back. The callback boundary
 * only captures an immutable ScanEvent naming its source context; the
 * reducer mutates transport state exclusively, and only while the exact
 * same context is the active registration of a started transport in the
 * currently open epoch. Late deliveries of retired or replaced
 * registrations - delayed results after stop/start, failures of superseded
 * contexts - change nothing at all. The discovery surface holds at most
 * MAX_DISCOVERED_PEERS entries: the least recently observed unpinned
 * entries are evicted first and deterministically, while active relations
 * are pinned. A scan failure terminates only its own context; recovery is
 * a fresh registration.
 */
class ReadinessT11Test {

    private class InMemoryIdentityStorage : io.godstone.mesh.identity.IdentityStorage {
        var v1State: ByteArray? = null
        var legacyMaterial: io.godstone.mesh.identity.LegacyIdentityMaterial? = null
        var failWrites = false

        override fun readV1State(): ByteArray? = v1State?.copyOf()
        override fun readLegacyMaterial(): io.godstone.mesh.identity.LegacyIdentityMaterial? = legacyMaterial
        override fun hasPartialLegacy(): Boolean = false
        override fun writeV1State(state: ByteArray): Boolean {
            if (failWrites) return false
            v1State = state.copyOf()
            return true
        }
        override fun migrateLegacyToV1(v1State: ByteArray): Boolean {
            if (failWrites) return false
            this.v1State = v1State.copyOf()
            this.legacyMaterial = null
            return true
        }
        override fun clear(): Boolean {
            v1State = null
            legacyMaterial = null
            return true
        }
    }

    private fun makeTransport(): BleTransport {
        val identity = Identity.loadOrCreate(InMemoryIdentityStorage())
        return BleTransport(identity = identity, store = InMemoryMessageStore())
    }

    private fun startedTransport(): BleTransport {
        val transport = makeTransport()
        transport.start()
        assertTrue("the transport run must be started for scan reduction", transport.isTransportStartedForTest())
        return transport
    }

    private fun metadataFor(seed: Int): BleLinkInfoV1 {
        val hint = byteArrayOf(seed.toByte(), (seed shr 8).toByte(), 3.toByte(), 7.toByte())
        val digest = ByteArray(BleLinkInfoConstants.SHORT_DIGEST_BYTES) { idx -> ((seed + idx) % 251).toByte() }
        return BleLinkInfoV1(nodeHint = hint, shortDigest = digest)
    }

    private fun bytesFor(seed: Int): ByteArray {
        val hint = byteArrayOf(seed.toByte(), (seed shr 8).toByte(), 3.toByte(), 7.toByte())
        val digest = ByteArray(BleLinkInfoConstants.SHORT_DIGEST_BYTES) { idx -> ((seed + idx) % 251).toByte() }
        return BleLinkInfoCodec.encode(flags = 0.toByte(), nodeHint = hint, shortDigest = digest, queueDepth = 3)
    }

    private fun addrAt(index: Int): String {
        return "5E:%012X".format(index.toLong())
    }

    @Test
    fun testLiveContextReducesAndEverySurfaceFollows() {
        val transport = startedTransport()
        try {
            val ctx = transport.openScanContextForTest()
            assertSame("the registration is the active context", ctx, transport.activeScanContextForTest())
            val address = addrAt(1)
            val accepted = transport.handleScanEvent(ScanEvent(ctx, 1, address, -55, null))
            assertTrue("the live context must reduce", accepted)
            assertTrue("the peer enters the bounded surface", transport.isPeerDiscoveredForTest(address))
            assertEquals("the signal is recorded", -55, transport.rssiForTest(address))
            val record = transport.centralDriver.driverScanRecordForTest(address)
            if (record == null) {
                fail("the driver shares the observation")
            } else {
                assertEquals("the driver records the same signal", -55, record.rssi)
            }
            assertEquals("one surface, one entry", 1, transport.discoveredCountForTest())
            assertEquals("the driver surface matches", 1, transport.centralDriver.driverScanCountForTest())
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testCaptureSnapshotsTheSourceNeverThePlatformObject() {
        val transport = startedTransport()
        try {
            val ctx = transport.openScanContextForTest()
            val seed = 41
            val event = transport.captureScanEvent(ctx, 2, addrAt(7), -61, bytesFor(seed))
            assertSame("the event names its source context", ctx, event.context)
            assertEquals("the address is snapshotted", addrAt(7), event.address)
            assertEquals("the signal is snapshotted", -61, event.rssi)
            val meta = event.metadata
            if (meta == null) {
                fail("a well-formed payload must decode into metadata")
            } else {
                assertArrayEquals("the hint travels", metadataFor(seed).nodeHint, meta.nodeHint)
            }
            // Malformed input is rejected, never inferred: a wrong-size
            // payload yields a signal-only observation, not a guess.
            val truncated = transport.captureScanEvent(ctx, 2, addrAt(8), -50, ByteArray(BleLinkInfoConstants.LINK_INFO_BYTES - 1))
            assertNull("a wrong-size payload decodes to nothing", truncated.metadata)
            // The event carries no platform object at all: a late callback
            // can deliver only the snapshot, never a live ScanResult.
            for (field in ScanEvent::class.java.declaredFields) {
                val typeName = field.getType().getName()
                assertFalse("no field may smuggle a platform type: " + typeName, typeName.contains("android."))
            }
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testFullPositivePathSchedulesThePlatformAction() {
        val transport = startedTransport()
        try {
            val ctx = transport.openScanContextForTest()
            val seed = 77
            val address = addrAt(11)
            val event = transport.captureScanEvent(ctx, 1, address, -42, bytesFor(seed))
            assertTrue("the accepted event reduces through capture", transport.handleScanEvent(event))
            assertTrue("the peer is discovered", transport.isPeerDiscoveredForTest(address))
            assertTrue("the scheduling half ran: a client stands ready", transport.activeClientCountForTest() >= 1)
            assertTrue("the scheduling half ran: the provisional timeout is pending", transport.hasProvisionalJobForTest(address))
            val record = transport.centralDriver.driverScanRecordForTest(address)
            if (record == null) {
                fail("the driver must carry the hint")
            } else {
                assertArrayEquals("the hint reached the driver", metadataFor(seed).nodeHint, record.hint)
            }
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testDelayedScanResultAfterStopStartIsDropped() {
        val transport = startedTransport()
        try {
            val ctx = transport.openScanContextForTest()
            val address = addrAt(21)
            assertTrue(transport.handleScanEvent(ScanEvent(ctx, 1, address, -50, null)))
            // The run ends; a newer run opens in its place.
            transport.stop()
            transport.start()
            // The delayed delivery of the old registration arrives now.
            val replayed = transport.handleScanEvent(ScanEvent(ctx, 1, address, -999, null))
            assertFalse("a stale registration cannot deliver into the new run", replayed)
            assertNull("the new run keeps no trace of the stale signal", transport.rssiForTest(address))
            assertEquals("the new surface stays empty", 0, transport.discoveredCountForTest())
            assertEquals("no scheduling happened for the stale event", 0, transport.activeClientCountForTest())
            // The new run itself still works: the drop is a context verdict,
            // not a broken pipeline.
            val fresh = transport.openScanContextForTest()
            assertTrue("a fresh registration reduces", transport.handleScanEvent(ScanEvent(fresh, 1, address, -61, null)))
            assertEquals("and the signal is the fresh one", -61, transport.rssiForTest(address))
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testOldScanFailureAfterReplacementMutatesNothing() {
        val transport = startedTransport()
        try {
            val first = transport.openScanContextForTest()
            val second = transport.openScanContextForTest()
            assertFalse("replacements are ordered by epoch", second.epoch == first.epoch)
            val address = addrAt(31)
            assertTrue("the newer registration reduces", transport.handleScanEvent(ScanEvent(second, 1, address, -60, null)))
            // The failure of the superseded context arrives late.
            val handled = transport.handleScanFailure(ScanFailureEvent(first, 4))
            assertFalse("a failure of a replaced registration is not its own", handled)
            assertTrue("the active context is untouched", second.isActive())
            assertSame("the active registration stays the newer one", second, transport.activeScanContextForTest())
            assertEquals("the authoritative state survives", -60, transport.rssiForTest(address))
            // And events of the superseded context stay dropped, even though
            // its lease never was released: the capture is identity, not age.
            assertFalse(transport.handleScanEvent(ScanEvent(first, 1, addrAt(32), -70, null)))
            assertNull(transport.rssiForTest(addrAt(32)))
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testScanFailureTerminatesOnlyItsOwnContext() {
        val transport = startedTransport()
        try {
            val ctx = transport.openScanContextForTest()
            val address = addrAt(41)
            assertTrue(transport.handleScanEvent(ScanEvent(ctx, 1, address, -33, null)))
            assertTrue("the failure of the active context is its own", transport.handleScanFailure(ScanFailureEvent(ctx, 2)))
            assertFalse("the lease is ended", ctx.isActive())
            assertFalse("a second failure of a terminated context reports nothing", transport.handleScanFailure(ScanFailureEvent(ctx, 2)))
            assertFalse("no further event of it is reduced", transport.handleScanEvent(ScanEvent(ctx, 1, addrAt(42), -80, null)))
            assertEquals("the run surface survives: the failure terminates only its context", -33, transport.rssiForTest(address))
            assertTrue("the transport itself is untouched", transport.isTransportStartedForTest())
            assertNull("nothing of the terminated context leaked in", transport.rssiForTest(addrAt(42)))
            val next = transport.openScanContextForTest()
            assertTrue("a new registration reduces again", transport.handleScanEvent(ScanEvent(next, 1, addrAt(42), -80, null)))
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testStopReleasesTheRunSurfaceAndContext() {
        val transport = startedTransport()
        try {
            val ctx = transport.openScanContextForTest()
            assertTrue(transport.handleScanEvent(ScanEvent(ctx, 1, addrAt(51), -40, null)))
            transport.stop()
            assertEquals("the run releases its bounded surface", 0, transport.discoveredCountForTest())
            assertNull("the run releases its registration", transport.activeScanContextForTest())
            assertFalse("the lease of the run is ended", ctx.isActive())
            // A second stop is a no-op on the scan gate, not a double release.
            transport.stop()
            assertFalse(transport.handleScanEvent(ScanEvent(ctx, 1, addrAt(51), -41, null)))
        } finally {
            transport.stop()
        }
    }
    @Test
    fun testTenThousandDistinctAdvertisersStayBounded() {
        val transport = startedTransport()
        try {
            val ctx = transport.openScanContextForTest()
            for (i in 0..9999) {
                val signal = -(30 + i % 60)
                transport.handleScanEvent(ScanEvent(ctx, 1, addrAt(i), signal, null))
            }
            assertEquals("the discovered-peer bound is applied", 64, transport.discoveredCountForTest())
            assertEquals("the driver surface is bounded by the same rule", 64, transport.centralDriver.driverScanCountForTest())
            // Deterministic survivors: the seven connect-admitted pioneers
            // (active, hence pinned) plus the 57 most recently observed
            // others, in observation order.
            val expected = ArrayList<String>()
            for (i in 0..6) {
                expected.add(addrAt(i))
            }
            for (i in 9943..9999) {
                expected.add(addrAt(i))
            }
            assertEquals("the survivor set is exactly determined", expected, transport.discoveredAddressesForTest())
            assertFalse("the very first non-survivor was evicted", transport.isPeerDiscoveredForTest(addrAt(500)))
            assertTrue("the newest observation is present", transport.isPeerDiscoveredForTest(addrAt(9999)))
            // Each pinned pioneer keeps its own first signal: eviction never
            // disturbed their records, and re-observation never happened.
            assertEquals("the first pioneer keeps its signal", -30, transport.rssiForTest(addrAt(0)))
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testPublishedRelationsArePinnedAcrossTheFlood() {
        val transport = startedTransport()
        try {
            val pinnedAddress = addrAt(0)
            val published = transport.publishRelation(RelationKey(BleDirection.OUTBOUND, pinnedAddress, 1L))
            assertTrue("the relation is published", published)
            val ctx = transport.openScanContextForTest()
            for (i in 0..9999) {
                transport.handleScanEvent(ScanEvent(ctx, 1, addrAt(i), -(20 + i % 55), null))
            }
            assertEquals("the bound holds with the pin in place", 64, transport.discoveredCountForTest())
            assertTrue("the active relation survives the flood", transport.isPeerDiscoveredForTest(pinnedAddress))
            val expected = ArrayList<String>()
            for (i in 0..6) {
                expected.add(addrAt(i))
            }
            for (i in 9943..9999) {
                expected.add(addrAt(i))
            }
            assertEquals("the survivor set is exactly determined, pin included", expected, transport.discoveredAddressesForTest())
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testDuplicateAdvertisementsRefreshWithoutDuplicating() {
        val transport = startedTransport()
        try {
            val ctx = transport.openScanContextForTest()
            val seed = 91
            val address = addrAt(61)
            assertTrue(transport.handleScanEvent(transport.captureScanEvent(ctx, 1, address, -70, bytesFor(seed))))
            assertTrue(transport.handleScanEvent(ScanEvent(ctx, 1, address, -40, null)))
            assertTrue(transport.handleScanEvent(ScanEvent(ctx, 1, address, -41, null)))
            assertEquals("one address, one entry, always", 1, transport.discoveredCountForTest())
            assertEquals("the signal is the latest", -41, transport.rssiForTest(address))
            // Absent fields stay as they were: the hint of the first well-
            // formed advertisement survives the signal-only repeats.
            val meta = transport.discoveredMetadataForTest(address)
            if (meta == null) {
                fail("the metadata of the first advertisement must persist through field-absent updates")
            } else {
                assertArrayEquals("the hint stayed", metadataFor(seed).nodeHint, meta.nodeHint)
            }
            // And a better advertisement replaces the present field.
            val newer = 92
            assertTrue(transport.handleScanEvent(transport.captureScanEvent(ctx, 1, address, -42, bytesFor(newer))))
            val refreshed = transport.discoveredMetadataForTest(address)
            if (refreshed == null) {
                fail("the newer payload must replace the metadata")
            } else {
                assertArrayEquals("the hint is the newest", metadataFor(newer).nodeHint, refreshed.nodeHint)
            }
            assertEquals("still exactly one entry", 1, transport.discoveredCountForTest())
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testPermissionRestorationOpensAFreshRegistration() {
        val transport = startedTransport()
        try {
            val denied = transport.openScanContextForTest()
            // The radio reports its registration failed (out of hardware
            // resources, too frequently started, or denied): only this
            // context is terminated.
            assertTrue(transport.handleScanFailure(ScanFailureEvent(denied, 3)))
            assertFalse(denied.isActive())
            assertFalse("the dead registration stays dead", transport.handleScanEvent(ScanEvent(denied, 1, addrAt(71), -50, null)))
            // Permission restored: the supervisor re-registers, exactly as
            // peers() does after a flow close. A fresh epoch, identity and
            // lease carry the new run.
            val restored = transport.openScanContextForTest()
            assertTrue("the fresh registration is live", restored.isActive())
            assertTrue("its events reduce", transport.handleScanEvent(ScanEvent(restored, 1, addrAt(71), -50, null)))
            assertEquals("and the effect lands", -50, transport.rssiForTest(addrAt(71)))
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testMissingAddressIsDroppedNotInferred() {
        val transport = startedTransport()
        try {
            val ctx = transport.openScanContextForTest()
            val before = transport.discoveredCountForTest()
            assertFalse("an event without the source identity is dropped", transport.handleScanEvent(ScanEvent(ctx, 1, null, -50, null)))
            assertEquals("nothing was mutated for it", before, transport.discoveredCountForTest())
            assertEquals("no current-state lookup stood in for the missing identity", 0, transport.activeClientCountForTest())
            assertTrue("the live registration still works", transport.handleScanEvent(ScanEvent(ctx, 1, addrAt(81), -50, null)))
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testEpochIsReadAtArrivalNotInferred() {
        val transport = startedTransport()
        try {
            val ctx = transport.openScanContextForTest()
            // A replacement registration has advanced the epoch while this
            // context object is still the stored one and its lease is live:
            // only the epoch read at arrival can tell the truth.
            transport.bumpScanEpochForTest()
            assertSame("the stored context is still this object", ctx, transport.activeScanContextForTest())
            assertTrue("its lease is still live", ctx.isActive())
            assertFalse("yet its epoch no longer matches the opened one", transport.handleScanEvent(ScanEvent(ctx, 1, addrAt(91), -50, null)))
            assertNull("and nothing was mutated", transport.rssiForTest(addrAt(91)))
            assertEquals(0, transport.discoveredCountForTest())
        } finally {
            transport.stop()
        }
    }
}
