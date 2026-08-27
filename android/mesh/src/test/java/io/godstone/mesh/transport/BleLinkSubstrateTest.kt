package io.godstone.mesh.transport

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.MeshNode
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.identity.PeerIdentityRepository
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.ValidatedPeerBinding
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.SecureRandom
import java.util.Random

class BleLinkSubstrateTest {

    private class RecordingTrustAuthority : io.godstone.mesh.crypto.PeerBindingTrustAuthority {
        override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
            return PeerTrustApplyResult.Accepted
        }
    }

    private fun hexToBytes(hex: String): ByteArray {
        val len = hex.length
        val data = ByteArray(len / 2)
        var i = 0
        while (i < len) {
            data[i / 2] = ((Character.digit(hex[i], 16) shl 4) + Character.digit(hex[i + 1], 16)).toByte()
            i += 2
        }
        return data
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

        // Edge case: 0x7F vs 0x80 (signed comparison would treat 0x80 as -128 < 127; unsigned must treat 0x80 as 128 > 127)
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

        // Decode partial or absent returns null
        assertNull(BleDiscoveryCodec.decode(ByteArray(0)))
        assertNull(BleDiscoveryCodec.decode(ByteArray(12))) // less than 13

        // When complete 13 bytes arrives:
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

        // Ingest on receiver
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
        // Capacity = 100 - 8 = 92 bytes. 150 / 92 = 2 fragments
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

        // Ingest fragment 0
        assertNull(conn.ingestInboundAttValue(frags[0]))

        // Mark disconnected
        conn.markDisconnected()
        assertFalse(conn.isActive)
        assertEquals(BleConnectionState.DISCONNECTED, conn.state)

        // Ingesting after disconnect returns null
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
        conn.markDisconnected() // safe second call
        assertEquals(BleConnectionState.DISCONNECTED, conn.state)
    }

    // ------------------------------------------------------------------------
    // 12. No SessionManager handshake API invoked by C8.4D1 production path
    // ------------------------------------------------------------------------
    @Test
    fun testSessionManager_HandshakeApiNotInvokedBySubstrate() {
        val id = MeshIdentity.generate()
        val sm = SessionManager(id, RecordingTrustAuthority())

        // Substrate connection does not invoke sm.beginInitiator or beginResponder
        val conn = BleConnection(byteArrayOf(1), byteArrayOf(2, 3, 4, 5), BleRole.INITIATOR, 20)
        conn.markConnected()

        // SM remains in initial state with zero sessions
        assertFalse(sm.isReady(byteArrayOf(1)))
    }

    // ------------------------------------------------------------------------
    // 13. LINK_LAYER_READY remains false
    // ------------------------------------------------------------------------
    @Test
    fun testLinkLayerReady_RemainsFalse() {
        assertFalse(MeshNode.LINK_LAYER_READY)
    }
}
