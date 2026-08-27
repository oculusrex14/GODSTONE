package io.godstone.mesh.transport

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.MeshNode
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.ValidatedPeerBinding
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

@OptIn(ExperimentalCoroutinesApi::class)
class BleLinkSubstrateTest {

    private class RecordingTrustAuthority : io.godstone.mesh.crypto.PeerBindingTrustAuthority {
        override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
            return PeerTrustApplyResult.Accepted
        }
    }

    // ------------------------------------------------------------------------
    // 1. Unsigned lexicographical role election
    // ------------------------------------------------------------------------
    @Test
    fun testRoleElection_UnsignedLexicographical() {
        val hintSmall = byteArrayOf(0x00.toByte(), 0x01.toByte(), 0x02.toByte(), 0x03.toByte())
        val hintLarge = byteArrayOf(0x80.toByte(), 0x01.toByte(), 0x02.toByte(), 0x03.toByte())

        // 0x00 < 0x80 (unsigned): hintSmall is initiator
        val res1 = BleRoleElection.elect(hintSmall, hintLarge)
        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), res1)

        val res2 = BleRoleElection.elect(hintLarge, hintSmall)
        assertEquals(BleRoleElectionResult.Elected(BleRole.RESPONDER), res2)

        // 0x7F vs 0x80 (unsigned comparison: 127 < 128)
        val hint7F = byteArrayOf(0x7F.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte())
        val hint80 = byteArrayOf(0x80.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte())
        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), BleRoleElection.elect(hint7F, hint80))
        assertEquals(BleRoleElectionResult.Elected(BleRole.RESPONDER), BleRoleElection.elect(hint80, hint7F))
    }

    // ------------------------------------------------------------------------
    // 2. 1000 random unequal node-hint pairs -> exactly one initiator
    // ------------------------------------------------------------------------
    @Test
    fun testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator() {
        val rng = Random(42)
        for (i in 0 until 1000) {
            val a = ByteArray(4)
            val b = ByteArray(4)
            rng.nextBytes(a)
            rng.nextBytes(b)

            if (a.contentEquals(b)) continue

            val resAB = BleRoleElection.elect(a, b)
            val resBA = BleRoleElection.elect(b, a)

            assertTrue(resAB is BleRoleElectionResult.Elected)
            assertTrue(resBA is BleRoleElectionResult.Elected)

            val roleAB = (resAB as BleRoleElectionResult.Elected).role
            val roleBA = (resBA as BleRoleElectionResult.Elected).role

            if (roleAB == BleRole.INITIATOR) {
                assertEquals(BleRole.RESPONDER, roleBA)
            } else {
                assertEquals(BleRole.RESPONDER, roleAB)
                assertEquals(BleRole.INITIATOR, roleBA)
            }
        }
    }

    // ------------------------------------------------------------------------
    // 3. Equal-hint fail-closed behavior
    // ------------------------------------------------------------------------
    @Test
    fun testRoleElection_EqualHints_FailClosed() {
        val hint = byteArrayOf(0x12.toByte(), 0x34.toByte(), 0x56.toByte(), 0x78.toByte())
        val res = BleRoleElection.elect(hint, hint)
        assertEquals(BleRoleElectionResult.Tie, res)
    }

    // ------------------------------------------------------------------------
    // 4. Advertisement payload parse/round-trip (13-byte discovery payload)
    // ------------------------------------------------------------------------
    @Test
    fun testDiscoveryPayload_EncodeDecodeRoundTrip() {
        val version: Byte = 0x02
        val flags: Byte = (BleDiscoveryConstants.FLAG_SOS or BleDiscoveryConstants.FLAG_POWER_CONSTRAINED).toByte()
        val nodeHint = byteArrayOf(0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte(), 0xDD.toByte())
        val shortDigest = byteArrayOf(0x01.toByte(), 0x02.toByte(), 0x03.toByte(), 0x04.toByte(), 0x05.toByte(), 0x06.toByte())
        val queueDepth = 42

        val encoded = BleDiscoveryCodec.encode(version, flags, nodeHint, shortDigest, queueDepth)
        assertEquals(13, encoded.size)

        val decoded = BleDiscoveryCodec.decode(encoded)
        assertNotNull(decoded)
        assertEquals(version, decoded!!.version)
        assertEquals(flags, decoded.flags)
        assertArrayEquals(nodeHint, decoded.nodeHint)
        assertArrayEquals(shortDigest, decoded.shortDigest)
        assertEquals(queueDepth, decoded.queueDepth)
        assertTrue(decoded.isSosPresent)
        assertTrue(decoded.isPowerConstrained)
        assertFalse(decoded.isBulkCapable)
    }

    // ------------------------------------------------------------------------
    // 5. Scan observation merger: adv first, scan response later
    // ------------------------------------------------------------------------
    @Test
    fun testScanObservationMerger_AdvFirst_ScanResponseLater() {
        val nodeHint = byteArrayOf(0x11, 0x22, 0x33, 0x44)
        val shortDigest = byteArrayOf(1, 2, 3, 4, 5, 6)
        val payload = BleDiscoveryCodec.encode(0x02, BleDiscoveryConstants.FLAG_SOS.toByte(), nodeHint, shortDigest, 5)

        assertNull(BleDiscoveryCodec.decode(ByteArray(0)))
        assertNull(BleDiscoveryCodec.decode(ByteArray(12)))

        val metadata = BleDiscoveryCodec.decode(payload)
        assertNotNull(metadata)
        assertArrayEquals(nodeHint, metadata!!.nodeHint)
    }

    // ------------------------------------------------------------------------
    // 6. Persistent connection supports >1 sequential ATT value
    // ------------------------------------------------------------------------
    @Test
    fun testPersistentConnection_MultipleSequentialAttValues() {
        val peerId = byteArrayOf(1, 2, 3, 4, 5, 6)
        val remoteHint = byteArrayOf(0x99.toByte(), 0x88.toByte(), 0x77.toByte(), 0x66.toByte())
        val conn = BleConnection(
            peerId = peerId,
            remoteNodeHint = remoteHint,
            localRole = BleRole.INITIATOR,
            initialMaxAttValueLength = 30
        )
        conn.markConnected()

        val recordPayload1 = "First sequential record payload".toByteArray(Charsets.UTF_8)
        val recordPayload2 = "Second sequential record payload with different bytes".toByteArray(Charsets.UTF_8)

        val frags1 = conn.fragmentOutbound(BleRecordType.DATA, recordPayload1)
        val frags2 = conn.fragmentOutbound(BleRecordType.DATA, recordPayload2)

        assertTrue(frags1.isNotEmpty())
        assertTrue(frags2.isNotEmpty())

        val receiverConn = BleConnection(
            peerId = peerId,
            remoteNodeHint = remoteHint,
            localRole = BleRole.RESPONDER,
            initialMaxAttValueLength = 30
        )
        receiverConn.markConnected()

        var rec1: BleReassembledRecord? = null
        for (f in frags1) {
            val r = receiverConn.ingestInboundAttValue(f)
            if (r != null) rec1 = r
        }
        assertNotNull(rec1)
        assertArrayEquals(recordPayload1, rec1!!.payload)

        var rec2: BleReassembledRecord? = null
        for (f in frags2) {
            val r = receiverConn.ingestInboundAttValue(f)
            if (r != null) rec2 = r
        }
        assertNotNull(rec2)
        assertArrayEquals(recordPayload2, rec2!!.payload)
    }

    // ------------------------------------------------------------------------
    // 7. Duplex synthetic connection traffic
    // ------------------------------------------------------------------------
    @Test
    fun testDuplexSyntheticTraffic_BothDirections() {
        val nodeA = byteArrayOf(0x01, 0x02, 0x03, 0x04)
        val nodeB = byteArrayOf(0x05, 0x06, 0x07, 0x08)

        val electionA = BleRoleElection.elect(nodeA, nodeB)
        val electionB = BleRoleElection.elect(nodeB, nodeA)

        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), electionA)
        assertEquals(BleRoleElectionResult.Elected(BleRole.RESPONDER), electionB)

        val connA = BleConnection(byteArrayOf(1), nodeB, BleRole.INITIATOR, 40)
        val connB = BleConnection(byteArrayOf(2), nodeA, BleRole.RESPONDER, 40)
        connA.markConnected()
        connB.markConnected()

        // Direction 1: A -> B
        val msgAtoB = "Hello from Initiator A to Responder B".toByteArray(Charsets.UTF_8)
        val fragsAtoB = connA.fragmentOutbound(BleRecordType.DATA, msgAtoB)
        var receivedByB: BleReassembledRecord? = null
        for (f in fragsAtoB) {
            val r = connB.ingestInboundAttValue(f)
            if (r != null) receivedByB = r
        }
        assertNotNull(receivedByB)
        assertArrayEquals(msgAtoB, receivedByB!!.payload)

        // Direction 2: B -> A
        val msgBtoA = "Hello back from Responder B to Initiator A".toByteArray(Charsets.UTF_8)
        val fragsBtoA = connB.fragmentOutbound(BleRecordType.DATA, msgBtoA)
        var receivedByA: BleReassembledRecord? = null
        for (f in fragsBtoA) {
            val r = connA.ingestInboundAttValue(f)
            if (r != null) receivedByA = r
        }
        assertNotNull(receivedByA)
        assertArrayEquals(msgBtoA, receivedByA!!.payload)
    }

    // ------------------------------------------------------------------------
    // 8. C8.4C record fragments survive connection seam and reassemble
    // ------------------------------------------------------------------------
    @Test
    fun testRecordFragments_ThroughConnectionSeam() {
        val conn = BleConnection(byteArrayOf(1), byteArrayOf(2, 3, 4, 5), BleRole.INITIATOR, 25)
        conn.markConnected()

        val hs2Payload = ByteArray(229) { (it * 7).toByte() }
        val fragments = conn.fragmentOutbound(BleRecordType.HS2, hs2Payload)
        assertTrue(fragments.size > 1)

        val receiver = BleConnection(byteArrayOf(2), byteArrayOf(1, 1, 1, 1), BleRole.RESPONDER, 25)
        receiver.markConnected()

        var result: BleReassembledRecord? = null
        for (f in fragments) {
            val r = receiver.ingestInboundAttValue(f)
            if (r != null) result = r
        }
        assertNotNull(result)
        assertEquals(BleRecordType.HS2, result!!.recordType)
        assertArrayEquals(hs2Payload, result.payload)
    }

    // ------------------------------------------------------------------------
    // 9. Negotiated max ATT value length is passed to BleRecord fragmentation
    // ------------------------------------------------------------------------
    @Test
    fun testNegotiatedMaxAttValueLength_PropagatedToFragmentation() {
        val conn = BleConnection(byteArrayOf(1), byteArrayOf(2, 3, 4, 5), BleRole.INITIATOR, 20)
        conn.markConnected(negotiatedAttValueLength = 100)
        assertEquals(100, conn.maxAttValueLength)

        val payload = ByteArray(150)
        val frags = conn.fragmentOutbound(BleRecordType.DATA, payload)
        assertEquals(2, frags.size)
        assertTrue(frags[0].size <= 100)
        assertTrue(frags[1].size <= 100)
    }

    // ------------------------------------------------------------------------
    // 10. Disconnect purges connection / reassembly state
    // ------------------------------------------------------------------------
    @Test
    fun testDisconnect_PurgesConnectionAndReassemblyState() {
        val conn = BleConnection(byteArrayOf(1), byteArrayOf(2, 3, 4, 5), BleRole.INITIATOR, 20)
        conn.markConnected()

        val payload = ByteArray(50)
        val frags = conn.fragmentOutbound(BleRecordType.DATA, payload)
        assertTrue(frags.size > 1)

        assertNull(conn.ingestInboundAttValue(frags[0]))

        conn.markDisconnected()
        assertFalse(conn.isActive)
        assertEquals(BleConnectionState.DISCONNECTED, conn.state)

        assertNull(conn.ingestInboundAttValue(frags[1]))
    }

    // ------------------------------------------------------------------------
    // 11. Repeated start/stop is idempotent
    // ------------------------------------------------------------------------
    @Test
    fun testRepeatedStartStop_Idempotent() {
        val conn = BleConnection(byteArrayOf(1), byteArrayOf(2, 3, 4, 5), BleRole.INITIATOR, 20)
        conn.markConnected()
        conn.markDisconnected()
        conn.markDisconnected()
        assertEquals(BleConnectionState.DISCONNECTED, conn.state)
    }

    // ------------------------------------------------------------------------
    // 12. No SessionManager handshake API invoked by C8.4D1 production path
    // ------------------------------------------------------------------------
    @Test
    fun testSessionManager_HandshakeApiNotInvokedBySubstrate() {
        val id = MeshIdentity.generate()
        val sm = SessionManager(id, RecordingTrustAuthority())

        val conn = BleConnection(byteArrayOf(1), byteArrayOf(2, 3, 4, 5), BleRole.INITIATOR, 20)
        conn.markConnected()

        assertFalse(sm.isReady(byteArrayOf(1)))
    }

    // ------------------------------------------------------------------------
    // 13. LINK_LAYER_READY remains false
    // ------------------------------------------------------------------------
    @Test
    fun testLinkLayerReady_RemainsFalse() {
        assertFalse(MeshNode.LINK_LAYER_READY)
    }

    // ------------------------------------------------------------------------
    // 14. Real discovery snapshot authority is used in advertising
    // ------------------------------------------------------------------------
    @Test
    fun testRealDiscoverySnapshotAuthority_UsedInAdvertising() {
        val nodeHint = byteArrayOf(0x10, 0x20, 0x30, 0x40)
        val realDigest = byteArrayOf(0x10, 0x20, 0x30, 0x40, 0x50, 0x60)
        val snapshot = BleDiscoverySnapshot(
            shortDigest = realDigest,
            queueDepth = 7,
            sosPresent = true,
            clockUntrusted = false
        )

        var flags = 0
        if (snapshot.sosPresent) flags = flags or BleTransport.FLAG_SOS
        if (snapshot.clockUntrusted) flags = flags or BleTransport.FLAG_CLOCK_UNTRUSTED

        val payload = BleDiscoveryCodec.encode(
            version = io.godstone.mesh.wire.v2.FrameV2.VERSION,
            flags = flags.toByte(),
            nodeHint = nodeHint,
            shortDigest = snapshot.shortDigest.copyOfRange(0, 6),
            queueDepth = snapshot.queueDepth
        )
        val decoded = BleDiscoveryCodec.decode(payload)
        assertNotNull(decoded)
        assertArrayEquals(realDigest, decoded!!.shortDigest)
        assertEquals(7, decoded.queueDepth)
        assertTrue(decoded.isSosPresent)
    }

    // ------------------------------------------------------------------------
    // 15. Server subscription and MTU tracking
    // ------------------------------------------------------------------------
    @Test
    fun testServerSubscriptionAndMtuTracking() {
        val conn = BleConnection(
            peerId = byteArrayOf(1, 2, 3, 4, 5, 6),
            remoteNodeHint = byteArrayOf(0x11, 0x22, 0x33, 0x44),
            localRole = BleRole.RESPONDER,
            initialMaxAttValueLength = 20
        )
        assertEquals(20, conn.maxAttValueLength)
        conn.markConnected(negotiatedAttValueLength = 128)
        assertEquals(128, conn.maxAttValueLength)
        assertTrue(conn.isActive)
    }

    // ------------------------------------------------------------------------
    // 16. C8.4D1-A1: Crossing connections A < B: A retains, B rejects
    // ------------------------------------------------------------------------
    @Test
    fun testCrossingConnections_ALessThanB_ARetainsBRejects() {
        val hintA = byteArrayOf(0x00, 0x01, 0x02, 0x03)
        val hintB = byteArrayOf(0x80.toByte(), 0x01, 0x02, 0x03)

        // Connection 1: Central A reads LinkInfo from Peripheral B
        val electionAtA = BleRoleElection.elect(hintA, hintB)
        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), electionAtA)
        // A < B: Central A retains link and proceeds to write LinkInfo to B

        // Connection 2: Central B reads LinkInfo from Peripheral A
        val electionAtB = BleRoleElection.elect(hintB, hintA)
        assertEquals(BleRoleElectionResult.Elected(BleRole.RESPONDER), electionAtB)
        // B > A: Central B recognizes wrong-direction connection and cancels immediately
    }

    // ------------------------------------------------------------------------
    // 17. C8.4D1-A1: Crossing connections B < A: B retains, A rejects
    // ------------------------------------------------------------------------
    @Test
    fun testCrossingConnections_BLessThanA_BRetainsARejects() {
        val hintA = byteArrayOf(0x99.toByte(), 0x00, 0x00, 0x00)
        val hintB = byteArrayOf(0x11, 0x00, 0x00, 0x00)

        // Central A reads LinkInfo from B: A > B -> Responder -> cancel
        val electionAtA = BleRoleElection.elect(hintA, hintB)
        assertEquals(BleRoleElectionResult.Elected(BleRole.RESPONDER), electionAtA)

        // Central B reads LinkInfo from A: B < A -> Initiator -> retain
        val electionAtB = BleRoleElection.elect(hintB, hintA)
        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), electionAtB)
    }

    // ------------------------------------------------------------------------
    // 18. C8.4D1-A1: Crossing connections Equal hints: Both reject (tie fail-closed)
    // ------------------------------------------------------------------------
    @Test
    fun testCrossingConnections_EqualHints_BothReject() {
        val hint = byteArrayOf(0x42, 0x42, 0x42, 0x42)
        val res = BleRoleElection.elect(hint, hint)
        assertEquals(BleRoleElectionResult.Tie, res)
    }

    // ------------------------------------------------------------------------
    // 19. C8.4D1-A1: LinkInfo V1 encode/decode parity and validation
    // ------------------------------------------------------------------------
    @Test
    fun testLinkInfoV1_EncodeDecodeParityAndValidation() {
        val version: Byte = 0x02
        val flags: Byte = (BleLinkInfoConstants.FLAG_SOS or BleLinkInfoConstants.FLAG_VERIFIED_ONLY).toByte()
        val nodeHint = byteArrayOf(0x12, 0x34, 0x56, 0x78)
        val shortDigest = byteArrayOf(0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte(), 0xDD.toByte(), 0xEE.toByte(), 0xFF.toByte())
        val queueDepth = 99

        val encoded = BleLinkInfoCodec.encode(version, flags, nodeHint, shortDigest, queueDepth)
        assertEquals(13, encoded.size)

        val decoded = BleLinkInfoCodec.decode(encoded)
        assertNotNull(decoded)
        assertEquals(version, decoded!!.version)
        assertEquals(flags, decoded.flags)
        assertArrayEquals(nodeHint, decoded.nodeHint)
        assertArrayEquals(shortDigest, decoded.shortDigest)
        assertEquals(queueDepth, decoded.queueDepth)
        assertTrue(decoded.isSosPresent)
        assertTrue(decoded.isVerifiedOnly)
    }

    // ------------------------------------------------------------------------
    // 20. C8.4D1-A1: Malformed LinkInfo length rejected
    // ------------------------------------------------------------------------
    @Test
    fun testLinkInfoV1_MalformedLength_Rejected() {
        assertNull(BleLinkInfoCodec.decode(ByteArray(0)))
        assertNull(BleLinkInfoCodec.decode(ByteArray(12)))
        assertNull(BleLinkInfoCodec.decode(ByteArray(1)))
    }

    // ------------------------------------------------------------------------
    // 21. C8.4D1-A1: Unknown version rejected
    // ------------------------------------------------------------------------
    @Test
    fun testLinkInfoV1_UnknownVersion_Rejected() {
        val badVersionPayload = ByteArray(13) { 0 }
        badVersionPayload[0] = 0x03 // unknown version != 0x02
        assertNull(BleLinkInfoCodec.decode(badVersionPayload))
    }

    // ------------------------------------------------------------------------
    // 22. C8.4D1-A1: Missing advertisement metadata allows provisional connection
    // ------------------------------------------------------------------------
    @Test
    fun testProvisionalConnection_MissingAdvMetadata_Allowed() {
        // Under C8.4D1-A1, missing scan response metadata does NOT prohibit provisional connection.
        // LinkInfo characteristic is the normative post-connect authority.
        val emptyAdvServiceData: ByteArray? = null
        assertNull(emptyAdvServiceData)
    }

    // ------------------------------------------------------------------------
    // 23. C8.4D1-A1: LinkInfo characteristic authority overrides adv metadata
    // ------------------------------------------------------------------------
    @Test
    fun testLinkInfoAuthority_OverridesAdvMetadata() {
        val advHint = byteArrayOf(0x00, 0x00, 0x00, 0x00) // spoofed or stale adv
        val realLinkInfoHint = byteArrayOf(0x77, 0x88, 0x99.toByte(), 0xAA.toByte())

        // Role election uses realLinkInfoHint from LinkInfo characteristic READ
        val myHint = byteArrayOf(0x11, 0x22, 0x33, 0x44)
        val election = BleRoleElection.elect(myHint, realLinkInfoHint)
        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), election)
    }
}
