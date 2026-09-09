package io.godstone.mesh.readiness

import android.bluetooth.BluetoothProfile
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.transport.BleCentralAction
import io.godstone.mesh.transport.BleCentralOrchestrationDriver
import io.godstone.mesh.transport.BleDirection
import io.godstone.mesh.transport.BleGlobalCapacityAuthority
import io.godstone.mesh.transport.BleLinkInfoCodec
import io.godstone.mesh.transport.BleServerAction
import io.godstone.mesh.transport.BleServerOrchestrationDriver
import io.godstone.mesh.transport.BleTransport
import io.godstone.mesh.transport.GattClientConnection
import io.godstone.mesh.transport.OutboundPeerSlotState
import io.godstone.mesh.transport.RelationKey
import io.godstone.mesh.transport.ScanEvent
import io.godstone.mesh.transport.ServerPeerSlotState
import io.godstone.mesh.transport.TerminalEvent
import io.godstone.mesh.transport.TerminalReason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * T12: Android locally cancelled attempts terminate explicitly.
 *
 * Reject, provisional timeout and local cancel are terminal events in
 * themselves: the exact RelationKey (direction, address, generation) of the
 * attempt transitions to terminal, its lease leaves the authority once, its
 * publication comes down once, and only then the captured GATT handle of
 * that very attempt is closed. No slot rests in an intermediate state
 * awaiting a didDisconnect that a locally closed handle can no longer
 * deliver, and a late platform terminal for an ended generation is an
 * idempotent no-op. Events that do not name their exact registration - an
 * absent token, a foreign generation, a stale client - are dropped where
 * they stand: no current-state lookup ever stands in for the missing
 * identity, and the successor's slot, lease and publication stay intact.
 */
class ReadinessT12Test {

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

    private val localHintBytes = byteArrayOf(0x01, 0x00, 0x00, 0x00)
    private val remoteHintBytes = byteArrayOf(0x09, 0x00, 0x00, 0x00)

    private fun makeTransport(): BleTransport {
        val identity = Identity.loadOrCreate(InMemoryIdentityStorage())
        return BleTransport(identity = identity, store = InMemoryMessageStore())
    }

    private fun startedTransport(): BleTransport {
        val transport = makeTransport()
        transport.start()
        return transport
    }

    private fun linkInfoBytes(): ByteArray {
        return BleLinkInfoCodec.encode(
            flags = 0.toByte(),
            nodeHint = remoteHintBytes,
            shortDigest = ByteArray(6) { (it % 251).toByte() },
            queueDepth = 0
        )
    }

    private fun centralDriverWith(authority: BleGlobalCapacityAuthority?): BleCentralOrchestrationDriver {
        return BleCentralOrchestrationDriver(
            localHint = localHintBytes,
            localLinkInfoProvider = { linkInfoBytes() },
            globalCapacity = authority
        )
    }

    private fun serverDriverWith(authority: BleGlobalCapacityAuthority?): BleServerOrchestrationDriver {
        return BleServerOrchestrationDriver(
            localHint = localHintBytes,
            localLinkInfoProvider = { linkInfoBytes() },
            globalCapacity = authority
        )
    }

    /// Drive one central relation through the happy path until the
    /// physical duplex readiness is published. Returns the PublishFound
    /// action for inspection.
    private fun advanceToPublishFound(driver: BleCentralOrchestrationDriver, peer: String): BleCentralAction {
        driver.onScanResult(peer, -55, null)
        driver.onGattConnected(peer, 1L, 1L)
        driver.onServicesDiscovered(peer, true, 1L, 1L)
        driver.onLinkInfoReadResult(peer, linkInfoBytes(), 1L, 1L)
        driver.onLinkInfoWriteAcknowledged(peer, true, remoteHintBytes, 1L, 1L)
        val act = driver.onCccdWriteAcknowledged(peer, true, 1L, 1L)
        assertTrue("the happy path ends in a published relation", act is BleCentralAction.PublishFound)
        return act
    }

    /// Schedule one scan admission through the real transport wiring and
    /// return the client the scheduling installed for it.
    private fun admitViaTransport(transport: BleTransport, peer: String): Boolean {
        val ctx = transport.openScanContextForTest()
        return transport.handleScanEvent(ScanEvent(ctx, 1, peer, -55, null))
    }

    @Test
    fun testTimeoutTerminatesWithoutAnyCallback() {
        val transport = startedTransport()
        try {
            val peer = "3E:00:00:00:00:21"
            assertTrue(admitViaTransport(transport, peer))
            assertEquals("the attempt holds one outbound lease", 1, transport.globalCapacity.outboundCount)
            assertTrue("the provisional window is armed", transport.hasProvisionalJobForTest(peer))
            assertEquals("one client is scheduled", 1, transport.activeClientCountForTest())
            val liveSlot = transport.centralDriver.outboundSlotForTest(peer)
            assertNotNull("the slot carries the attempt", liveSlot)
            if (liveSlot != null) {
                assertEquals("registered at generation one", 1L, liveSlot.generation)
                assertTrue("the slot is ACTIVE while the attempt lives", liveSlot.state == OutboundPeerSlotState.ACTIVE)
            }
            // The provisional window closes. The timeout is a local
            // termination: it never needs, and never waits for, a
            // didDisconnect.
            val timeoutAct = transport.centralDriver.onProvisionalTimeout(peer, 1L)
            assertTrue("the timeout schedules the close of the captured handle", timeoutAct is BleCentralAction.DisconnectGatt)
            if (timeoutAct is BleCentralAction.DisconnectGatt) {
                assertEquals("the close intent names the exact generation", 1L, timeoutAct.generation)
                transport.dispatchCentralActionForTest(peer, timeoutAct)
            }
            val rested = transport.centralDriver.outboundSlotForTest(peer)
            assertNotNull(rested)
            if (rested != null) {
                assertTrue("the slot rests terminal at IDLE, it awaits no callback", rested.state == OutboundPeerSlotState.IDLE)
                assertEquals("the terminal remembers its generation", 1L, rested.generation)
            }
            assertNull("the connection object is gone", transport.centralDriver.getActiveConnection(peer))
            assertEquals("the lease left the authority exactly once", 0, transport.globalCapacity.outboundCount)
            assertEquals("the scheduled client was withdrawn", 0, transport.activeClientCountForTest())
            assertFalse("no publication of the dead attempt survives", transport.isRelationPublished(BleDirection.OUTBOUND, peer, 1L))
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testLatePlatformTerminalAfterTimeoutIsIdempotent() {
        val transport = startedTransport()
        try {
            val peer = "3E:00:00:00:00:22"
            assertTrue(admitViaTransport(transport, peer))
            val client = transport.activeClientForTest(peer)
            if (client == null) {
                fail("the scheduling must have installed a client")
            } else {
                val token = client.clientToken
                val gen = client.gattGeneration
                val timeoutAct = transport.centralDriver.onProvisionalTimeout(peer, 1L)
                if (timeoutAct is BleCentralAction.DisconnectGatt) {
                    transport.dispatchCentralActionForTest(peer, timeoutAct)
                }
                // The platform now delivers, late, the disconnect its
                // closed handle will never really send for this generation.
                client.onDisconnected(token, gen)
                assertEquals("nothing stirred: the lease count stays at zero", 0, transport.globalCapacity.outboundCount)
                assertEquals("nothing stirred: no client was resurrected", 0, transport.activeClientCountForTest())
                val rested = transport.centralDriver.outboundSlotForTest(peer)
                if (rested != null) {
                    assertTrue("the slot keeps resting terminal", rested.state == OutboundPeerSlotState.IDLE)
                }
            }
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testTimeoutThenLateConnectIsRefused() {
        val transport = startedTransport()
        try {
            val peer = "3E:00:00:00:00:23"
            assertTrue(admitViaTransport(transport, peer))
            val timeoutAct = transport.centralDriver.onProvisionalTimeout(peer, 1L)
            if (timeoutAct is BleCentralAction.DisconnectGatt) {
                transport.dispatchCentralActionForTest(peer, timeoutAct)
            }
            // A callback of the dead attempt stumbles in late: the
            // connection-complete of generation one arrives after the end.
            val late = transport.centralDriver.onGattConnected(peer, 1L, 1L)
            assertTrue("the late connect finds no attempt to advance", late is BleCentralAction.NoOp)
            assertNull("no connection was rebuilt", transport.centralDriver.getActiveConnection(peer))
            assertEquals("no lease was taken anew", 0, transport.globalCapacity.outboundCount)
            val rested = transport.centralDriver.outboundSlotForTest(peer)
            if (rested != null) {
                assertTrue("the slot is untouched by the ghost", rested.state == OutboundPeerSlotState.IDLE)
            }
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testDuplicateFailureDisconnectChangesNothingTwice() {
        val authority = BleGlobalCapacityAuthority(maxTotalPeers = 7)
        val driver = centralDriverWith(authority)
        advanceToPublishFound(driver, "3E:00:00:00:00:24")
        val peer = "3E:00:00:00:00:24"
        assertEquals("one lease is held", 1, authority.outboundCount)
        val first = driver.onDisconnected(peer, 1L)
        assertTrue("the first terminal brings the publication down", first is BleCentralAction.PublishLost)
        if (first is BleCentralAction.PublishLost) {
            assertEquals("and names its exact relation", 1L, first.generation)
        }
        assertEquals("the lease left the authority once", 0, authority.outboundCount)
        val second = driver.onDisconnected(peer, 1L)
        assertTrue("the repeat of the very same event is an idempotent no-op", second is BleCentralAction.NoOp)
        val repeat = driver.terminate(TerminalEvent(RelationKey(BleDirection.OUTBOUND, peer, 1L), TerminalReason.LOCAL_CANCEL))
        assertFalse("the repeat does not transition again", repeat.transitioned)
        assertFalse("the repeat is not mistaken for a foreign relation", repeat.refusedForeignGeneration)
        assertTrue("the repeat is recognised as already terminal", repeat.alreadyTerminal)
        assertFalse("the repeat schedules no close", repeat.closeCapturedGattRequired)
        assertFalse("the repeat takes no publication down", repeat.unpublishEffectPending)
        assertEquals("the count did not fall below zero", 0, authority.outboundCount)
        val rested = driver.outboundSlotForTest(peer)
        if (rested != null) {
            assertTrue("the slot still rests terminal at IDLE", rested.state == OutboundPeerSlotState.IDLE)
        }
    }

    @Test
    fun testReplacementRelationSurvivesOldCallback() {
        val transport = startedTransport()
        try {
            val peer = "3E:00:00:00:00:25"
            assertTrue(admitViaTransport(transport, peer))
            val firstClient = transport.activeClientForTest(peer)
            if (firstClient == null) {
                fail("the first attempt must have installed a client")
            } else {
                val firstToken = firstClient.clientToken
                val firstGattGen = firstClient.gattGeneration
                // Attempt one dies by timeout, terminally.
                val timeoutAct = transport.centralDriver.onProvisionalTimeout(peer, 1L)
                if (timeoutAct is BleCentralAction.DisconnectGatt) {
                    transport.dispatchCentralActionForTest(peer, timeoutAct)
                }
                // The successor is admitted: same address, generation two.
                assertTrue(admitViaTransport(transport, peer))
                val successor = transport.activeClientForTest(peer)
                assertNotNull("the successor stands in place", successor)
                if (successor != null) {
                    assertEquals("the successor is stamped with generation two", 2L, successor.relationGeneration)
                    assertTrue("the successor is a fresh registration", successor.clientToken != firstToken)
                    // The dead attempt's client now reports a disconnect
                    // with its own, stale tokens.
                    firstClient.onDisconnected(firstToken, firstGattGen)
                    val slot = transport.centralDriver.outboundSlotForTest(peer)
                    if (slot != null) {
                        assertTrue("the successor still lives", slot.state == OutboundPeerSlotState.ACTIVE)
                        assertEquals("the successor keeps its generation", 2L, slot.generation)
                    }
                    assertNotNull("the successor's connection stands", transport.centralDriver.getActiveConnection(peer))
                    assertEquals("the successor's lease is untouched", 1, transport.globalCapacity.outboundCount)
                    assertEquals("the successor's client is in place", 1, transport.activeClientCountForTest())
                    assertTrue("the successor is still the stored client", transport.activeClientForTest(peer) === successor)
                }
            }
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testExactLeaseCountReturnsToZeroBothDirections() {
        val transport = startedTransport()
        try {
            val centralPeer = "3E:00:00:00:00:26"
            val serverPeer = "3E:00:00:00:01:26"
            assertTrue(admitViaTransport(transport, centralPeer))
            transport.gattServer.processConnectionStateChange(serverPeer, 0, BluetoothProfile.STATE_CONNECTED, null)
            assertEquals("both directions hold their leases", 2, transport.globalCapacity.totalCount)
            // The central attempt is terminated by the platform's own word.
            val centralAct = transport.centralDriver.onDisconnected(centralPeer, 1L)
            transport.dispatchCentralActionForTest(centralPeer, centralAct)
            // The server learns the disconnection through the real facade.
            transport.gattServer.processConnectionStateChange(serverPeer, 0, BluetoothProfile.STATE_DISCONNECTED, null)
            assertEquals("both leases are back", 0, transport.globalCapacity.totalCount)
            assertNull(transport.centralDriver.getActiveConnection(centralPeer))
            assertNull(transport.serverDriver.getInboundConnection(serverPeer))
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testAbsentTokenIsNeverCorrelatedToCurrentSlot() {
        val driver = serverDriverWith(null)
        driver.startNewServerEpoch()
        driver.onServiceAdded(1L, true)
        val peer = "3E:00:00:00:02:27"
        val withoutToken = driver.onClientConnected(peer, 0L)
        assertTrue("an arrival without a token is refused", withoutToken is BleServerAction.RejectConnection)
        val admitted = driver.onClientConnected(peer, 1L)
        assertTrue("the stamped arrival is admitted", admitted is BleServerAction.AdmitConnection)
        assertEquals("the driver stores the token it was given", 1L, driver.getClientGeneration(peer))
        val foreign = driver.onClientDisconnected(peer, 7L)
        assertTrue("a terminal naming a foreign generation is refused", foreign is BleServerAction.NoOp)
        val slot = driver.getPeerSlotState(peer)
        assertTrue("the registered slot is untouched by the forgery", slot == ServerPeerSlotState.ACTIVE)
        val exact = driver.onClientDisconnected(peer, 1L)
        assertTrue("the exact token terminates", exact is BleServerAction.TearDownPhysicalChannel)
        assertTrue("and the slot rests QUARANTINED", driver.getPeerSlotState(peer) == ServerPeerSlotState.QUARANTINED)
    }

    @Test
    fun testForeignGenerationTerminalIsRefusedEntirely() {
        val authority = BleGlobalCapacityAuthority(maxTotalPeers = 7)
        val driver = centralDriverWith(authority)
        driver.onScanResult("3E:00:00:00:03:28", -55, null)
        assertEquals("one lease", 1, authority.outboundCount)
        val forged = driver.terminate(TerminalEvent(RelationKey(BleDirection.OUTBOUND, "3E:00:00:00:03:28", 9L), TerminalReason.LOCAL_CANCEL))
        assertFalse("the forged termination does not transition", forged.transitioned)
        assertTrue("and is recognised as foreign", forged.refusedForeignGeneration)
        assertEquals("the lease is untouched", 1, authority.outboundCount)
        val live = driver.outboundSlotForTest("3E:00:00:00:03:28")
        if (live != null) {
            assertTrue("the live slot stands", live.state == OutboundPeerSlotState.ACTIVE)
        }
        val exact = driver.terminate(TerminalEvent(RelationKey(BleDirection.OUTBOUND, "3E:00:00:00:03:28", 1L), TerminalReason.LOCAL_CANCEL))
        assertTrue("the exact event transitions", exact.transitioned)
        assertTrue("and reports the close of the captured handle", exact.closeCapturedGattRequired)
        assertEquals("the lease left once", 0, authority.outboundCount)
        val again = driver.terminate(TerminalEvent(RelationKey(BleDirection.OUTBOUND, "3E:00:00:00:03:28", 1L), TerminalReason.LOCAL_CANCEL))
        assertFalse("the very same event never transitions twice", again.transitioned)
        assertTrue("it is recognised as already terminal", again.alreadyTerminal)
    }

    @Test
    fun testMalformedWriteTeardownIsTerminalItself() {
        val authority = BleGlobalCapacityAuthority(maxTotalPeers = 7)
        val driver = serverDriverWith(authority)
        driver.startNewServerEpoch()
        driver.onServiceAdded(1L, true)
        val peer = "3E:00:00:00:04:29"
        driver.onClientConnected(peer, 1L)
        assertEquals("the admitted client holds a lease", 1, authority.inboundCount)
        val rejected = driver.onLinkInfoWriteRequest(peer, ByteArray(7))
        assertTrue("the malformed payload is refused", rejected is BleServerAction.RejectWrite)
        assertTrue("the local teardown is terminal in itself", driver.getPeerSlotState(peer) == ServerPeerSlotState.QUARANTINED)
        assertEquals("the admitted set withdrew", 0, driver.getAdmittedCount())
        assertEquals("the lease left exactly once", 0, authority.inboundCount)
        // The platform's disconnect for the dead generation arrives late.
        val late = driver.onClientDisconnected(peer, 1L)
        assertTrue("it finds an idempotent end", late is BleServerAction.NoOp)
        assertTrue("the slot keeps its terminal rest", driver.getPeerSlotState(peer) == ServerPeerSlotState.QUARANTINED)
    }

    @Test
    fun testStaleGenerationCloseIntentClosesNothing() {
        val transport = startedTransport()
        try {
            val peer = "3E:00:00:00:05:30"
            assertTrue(admitViaTransport(transport, peer))
            // A close intent for a generation that was never registered
            // must not touch the live attempt of generation one.
            transport.dispatchCentralActionForTest(peer, BleCentralAction.DisconnectGatt(peer, "stale intent", 7L))
            assertEquals("the client of the live attempt stands", 1, transport.activeClientCountForTest())
            assertNotNull("its handle was not closed by a stranger's intent", transport.activeClientForTest(peer))
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testCapturedHandleClosesOnceAndNeverAgain() {
        val client = GattClientConnection(peerAddress = "3E:00:00:00:06:31", relationGeneration = 1L)
        // Nothing was ever captured for this instance: a close changes
        // nothing and reports so - the once-flag guards the platform call.
        val first = client.closeCapturedHandle()
        assertFalse("no handle, no close, no change", first)
        val second = client.closeCapturedHandle()
        assertFalse("the repeat changes nothing", second)
        assertFalse("and the client stays disconnected", client.isConnected)
    }

    @Test
    fun testServerHandlerRequiresExactRegistration() {
        val transport = startedTransport()
        try {
            val peer = "3E:00:00:00:07:32"
            transport.gattServer.processConnectionStateChange(peer, 0, BluetoothProfile.STATE_CONNECTED, null)
            assertEquals("the facade admitted the arrival", 1, transport.serverDriver.getAdmittedCount())
            val gen = transport.serverDriver.getClientGeneration(peer)
            assertTrue("registered with a positive token", gen > 0L)
            // A late terminal naming a foreign generation must leave the
            // live registration complete and untouched.
            transport.handleServerDisconnected(peer, gen + 100L)
            assertEquals("still admitted", 1, transport.serverDriver.getAdmittedCount())
            assertTrue("still active", transport.serverDriver.getPeerSlotState(peer) == ServerPeerSlotState.ACTIVE)
            assertEquals("still leased", 1, transport.globalCapacity.inboundCount)
            // The exact registration terminates through the transport.
            transport.handleServerDisconnected(peer, gen)
            assertEquals("withdrawn", 0, transport.serverDriver.getAdmittedCount())
            assertEquals("the lease is back", 0, transport.globalCapacity.inboundCount)
        } finally {
            transport.stop()
        }
    }

    @Test
    fun testStopReleasesEveryLeaseOfTheRun() {
        val transport = startedTransport()
        val centralPeer = "3E:00:00:00:08:33"
        val serverPeer = "3E:00:00:00:09:33"
        assertTrue(admitViaTransport(transport, centralPeer))
        transport.gattServer.processConnectionStateChange(serverPeer, 0, BluetoothProfile.STATE_CONNECTED, null)
        transport.publishRelation(RelationKey(BleDirection.OUTBOUND, centralPeer, 1L))
        assertEquals("the run holds its state", 2, transport.globalCapacity.totalCount)
        assertTrue("published", transport.isRelationPublished(BleDirection.OUTBOUND, centralPeer, 1L))
        transport.stop()
        assertEquals("the stop released every lease", 0, transport.globalCapacity.totalCount)
        assertFalse("every publication came down", transport.isAnyRelationPublishedForAddress(BleDirection.OUTBOUND, centralPeer))
        assertFalse("no inbound job outlives the run", transport.hasInboundJob(serverPeer))
        assertEquals("no client outlives the run", 0, transport.activeClientCountForTest())
    }
}
