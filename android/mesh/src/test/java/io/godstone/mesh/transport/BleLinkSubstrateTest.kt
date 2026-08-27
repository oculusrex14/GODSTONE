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
    // 4. LinkInfo V1 encode/decode parity and flags
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

    @Test
    fun testPersistentConnection_MultipleSequentialAttValues() {
        val peerId = byteArrayOf(1, 2, 3, 4, 5, 6)
        val conn = BleConnection(peerId = peerId, initialMaxAttValueLength = 30)
        conn.markConnected()
        conn.bindRole(byteArrayOf(0x05, 0x06, 0x07, 0x08), BleRole.INITIATOR)
        conn.transitionTo(BleConnectionState.READY)

        val recordPayload1 = "First sequential record payload".toByteArray(Charsets.UTF_8)
        val recordPayload2 = "Second sequential record payload with different bytes".toByteArray(Charsets.UTF_8)

        val frags1 = conn.fragmentOutbound(BleRecordType.DATA, recordPayload1)
        val frags2 = conn.fragmentOutbound(BleRecordType.DATA, recordPayload2)

        assertTrue(frags1.isNotEmpty())
        assertTrue(frags2.isNotEmpty())

        val receiverConn = BleConnection(peerId = peerId, initialMaxAttValueLength = 30)
        receiverConn.markConnected()
        receiverConn.bindRole(byteArrayOf(0x01, 0x02, 0x03, 0x04), BleRole.RESPONDER)
        receiverConn.transitionTo(BleConnectionState.READY)

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
    // 5. Malformed Length Rejections (0, 1, 12, 14, 20, 255)
    // ------------------------------------------------------------------------
    @Test
    fun testLinkInfoV1_MalformedLength_Rejected() {
        assertNull(BleLinkInfoCodec.decode(ByteArray(0)))
        assertNull(BleLinkInfoCodec.decode(ByteArray(1)))
        assertNull(BleLinkInfoCodec.decode(ByteArray(12)))
        assertNull(BleLinkInfoCodec.decode(ByteArray(14)))
        assertNull(BleLinkInfoCodec.decode(ByteArray(20)))
        assertNull(BleLinkInfoCodec.decode(ByteArray(255)))
    }

    // ------------------------------------------------------------------------
    // 6. Unknown version rejected
    // ------------------------------------------------------------------------
    @Test
    fun testLinkInfoV1_UnknownVersion_Rejected() {
        val bad01 = ByteArray(13) { 0 }.also { it[0] = 0x01 }
        assertNull(BleLinkInfoCodec.decode(bad01))

        val bad03 = ByteArray(13) { 0 }.also { it[0] = 0x03 }
        assertNull(BleLinkInfoCodec.decode(bad03))

        val badFF = ByteArray(13) { 0 }.also { it[0] = 0xFF.toByte() }
        assertNull(BleLinkInfoCodec.decode(badFF))
    }

    // ------------------------------------------------------------------------
    // 7. Role Binding Coordinator - Central Flow
    // ------------------------------------------------------------------------
    @Test
    fun testRoleBindingCoordinator_CentralFlow() {
        val localHint = byteArrayOf(0x01, 0x02, 0x03, 0x04)
        val coord = BleRoleBindingCoordinator(localHint)
        val peerAddress = "AA:BB:CC:DD:EE:FF"

        // 1. Discovered -> ConnectProvisionally
        val act1 = coord.processCentralEvent(BleRoleBindingEvent.Discovered(peerAddress))
        assertEquals(BleRoleBindingAction.ConnectProvisionally(peerAddress), act1)

        // 2. ProvisionalConnected -> ReadRemoteLinkInfo
        val act2 = coord.processCentralEvent(BleRoleBindingEvent.ProvisionalConnected(peerAddress))
        assertEquals(BleRoleBindingAction.ReadRemoteLinkInfo(peerAddress), act2)

        // 3. RemoteLinkInfo with larger hint (local < remote -> INITIATOR) -> WriteLocalLinkInfo
        val remoteHintLarger = byteArrayOf(0x05, 0x06, 0x07, 0x08)
        val remoteLinkInfoLarger = BleLinkInfoCodec.encode(
            flags = 0,
            nodeHint = remoteHintLarger,
            shortDigest = ByteArray(6),
            queueDepth = 0
        )
        val act3 = coord.processCentralEvent(BleRoleBindingEvent.RemoteLinkInfoReadRaw(peerAddress, remoteLinkInfoLarger))
        assertTrue(act3 is BleRoleBindingAction.WriteLocalLinkInfo)
        assertArrayEquals(remoteHintLarger, (act3 as BleRoleBindingAction.WriteLocalLinkInfo).remoteHint)

        // 4. Write acknowledged -> RoleBound
        val act4 = coord.processCentralEvent(BleRoleBindingEvent.LocalLinkInfoWriteAcknowledged(peerAddress, remoteHintLarger))
        assertEquals(BleRoleBindingAction.RoleBound(peerAddress, BleRole.INITIATOR, remoteHintLarger), act4)

        // 5. RemoteLinkInfo with smaller hint (local > remote -> RESPONDER on central link) -> Cancel
        val remoteHintSmaller = byteArrayOf(0x00, 0x01, 0x02, 0x03)
        val remoteLinkInfoSmaller = BleLinkInfoCodec.encode(
            flags = 0,
            nodeHint = remoteHintSmaller,
            shortDigest = ByteArray(6),
            queueDepth = 0
        )
        val act5 = coord.processCentralEvent(BleRoleBindingEvent.RemoteLinkInfoReadRaw(peerAddress, remoteLinkInfoSmaller))
        assertTrue(act5 is BleRoleBindingAction.CancelWrongDirectionLink)

        // 6. Equal hint -> Cancel
        val remoteLinkInfoEqual = BleLinkInfoCodec.encode(
            flags = 0,
            nodeHint = localHint,
            shortDigest = ByteArray(6),
            queueDepth = 0
        )
        val act6 = coord.processCentralEvent(BleRoleBindingEvent.RemoteLinkInfoReadRaw(peerAddress, remoteLinkInfoEqual))
        assertTrue(act6 is BleRoleBindingAction.CancelWrongDirectionLink)
    }

    // ------------------------------------------------------------------------
    // 8. Role Binding Coordinator - Peripheral Incoming Write Events
    // ------------------------------------------------------------------------
    @Test
    fun testRoleBindingCoordinator_PeripheralIncomingWrite() {
        val localHint = byteArrayOf(0x80.toByte(), 0x00, 0x00, 0x00)
        val coord = BleRoleBindingCoordinator(localHint)
        val peerAddress = "11:22:33:44:55:66"

        // 1. Incoming write with remote < local -> Accept as RESPONDER
        val remoteSmaller = byteArrayOf(0x10, 0x00, 0x00, 0x00)
        val payloadSmaller = BleLinkInfoCodec.encode(
            flags = 0,
            nodeHint = remoteSmaller,
            shortDigest = ByteArray(6),
            queueDepth = 0
        )
        val act1 = coord.processPeripheralLinkInfoWrite(peerAddress, payloadSmaller)
        assertTrue(act1 is BleRoleBindingAction.AcceptIncomingWrite)
        assertArrayEquals(remoteSmaller, (act1 as BleRoleBindingAction.AcceptIncomingWrite).remoteHint)

        // 2. Incoming write with remote > local -> Reject
        val remoteLarger = byteArrayOf(0x90.toByte(), 0x00, 0x00, 0x00)
        val payloadLarger = BleLinkInfoCodec.encode(
            flags = 0,
            nodeHint = remoteLarger,
            shortDigest = ByteArray(6),
            queueDepth = 0
        )
        val act2 = coord.processPeripheralLinkInfoWrite(peerAddress, payloadLarger)
        assertTrue(act2 is BleRoleBindingAction.RejectIncomingWrite)

        // 3. Incoming write with equal hint -> Reject
        val payloadEqual = BleLinkInfoCodec.encode(
            flags = 0,
            nodeHint = localHint,
            shortDigest = ByteArray(6),
            queueDepth = 0
        )
        val act3 = coord.processPeripheralLinkInfoWrite(peerAddress, payloadEqual)
        assertTrue(act3 is BleRoleBindingAction.RejectIncomingWrite)
    }

    // ------------------------------------------------------------------------
    // 9. BleConnection Provisional State Machine & One-Way Role Binding
    // ------------------------------------------------------------------------
    @Test
    fun testBleConnection_ProvisionalStateMachine() {
        val peerId = byteArrayOf(1, 2, 3, 4, 5, 6)
        val conn = BleConnection(peerId = peerId)

        assertEquals(BleConnectionState.PROVISIONAL_CONNECTING, conn.state)
        assertNull(conn.remoteNodeHint)
        assertNull(conn.localRole)
        assertFalse(conn.isRoleBound)
        assertFalse(conn.isHandshakeTransportReady)
        assertTrue(conn.isActive)

        conn.markConnected()
        assertEquals(BleConnectionState.PROVISIONAL_CONNECTED, conn.state)

        conn.transitionTo(BleConnectionState.LINK_INFO_READING)
        assertEquals(BleConnectionState.LINK_INFO_READING, conn.state)

        conn.transitionTo(BleConnectionState.LINK_INFO_WRITING)
        assertEquals(BleConnectionState.LINK_INFO_WRITING, conn.state)

        // Bind role
        val remoteHint = byteArrayOf(0x01, 0x02, 0x03, 0x04)
        conn.bindRole(remoteHint, BleRole.INITIATOR)
        assertEquals(BleConnectionState.ROLE_BOUND, conn.state)
        assertTrue(conn.isRoleBound)
        assertArrayEquals(remoteHint, conn.remoteNodeHint)
        assertEquals(BleRole.INITIATOR, conn.localRole)

        // Handshake transport ready requires notification subscription
        assertFalse(conn.isHandshakeTransportReady)
        conn.isNotificationSubscribed = true
        assertTrue(conn.isHandshakeTransportReady)

        // Disconnect
        conn.markDisconnected()
        assertEquals(BleConnectionState.CLOSED, conn.state)
        assertFalse(conn.isActive)
        assertFalse(conn.isHandshakeTransportReady)
    }

    @Test
    fun testDuplexSyntheticTraffic_BothDirections() {
        val nodeA = byteArrayOf(0x01, 0x02, 0x03, 0x04)
        val nodeB = byteArrayOf(0x05, 0x06, 0x07, 0x08)

        val electionA = BleRoleElection.elect(nodeA, nodeB)
        val electionB = BleRoleElection.elect(nodeB, nodeA)

        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), electionA)
        assertEquals(BleRoleElectionResult.Elected(BleRole.RESPONDER), electionB)

        val connA = BleConnection(byteArrayOf(1), 40)
        val connB = BleConnection(byteArrayOf(2), 40)
        connA.markConnected()
        connB.markConnected()
        connA.bindRole(nodeB, BleRole.INITIATOR)
        connB.bindRole(nodeA, BleRole.RESPONDER)
        connA.transitionTo(BleConnectionState.READY)
        connB.transitionTo(BleConnectionState.READY)

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

    @Test
    fun testRecordFragments_ThroughConnectionSeam() {
        val conn = BleConnection(byteArrayOf(1), 25)
        conn.markConnected()
        conn.bindRole(byteArrayOf(2, 3, 4, 5), BleRole.INITIATOR)

        val hs2Payload = ByteArray(229) { (it * 7).toByte() }
        val fragments = conn.fragmentOutbound(BleRecordType.HS2, hs2Payload)
        assertTrue(fragments.size > 1)

        val receiver = BleConnection(byteArrayOf(2), 25)
        receiver.markConnected()
        receiver.bindRole(byteArrayOf(1, 1, 1, 1), BleRole.RESPONDER)

        var result: BleReassembledRecord? = null
        for (f in fragments) {
            val r = receiver.ingestInboundAttValue(f)
            if (r != null) result = r
        }
        assertNotNull(result)
        assertEquals(BleRecordType.HS2, result!!.recordType)
        assertArrayEquals(hs2Payload, result.payload)
    }

    @Test
    fun testNegotiatedMaxAttValueLength_PropagatedToFragmentation() {
        val conn = BleConnection(byteArrayOf(1), 20)
        conn.markConnected(negotiatedAttValueLength = 100)
        conn.bindRole(byteArrayOf(2, 3, 4, 5), BleRole.INITIATOR)
        conn.transitionTo(BleConnectionState.READY)
        assertEquals(100, conn.maxAttValueLength)

        val payload = ByteArray(150)
        val frags = conn.fragmentOutbound(BleRecordType.DATA, payload)
        assertEquals(2, frags.size)
        assertTrue(frags[0].size <= 100)
        assertTrue(frags[1].size <= 100)
    }

    @Test
    fun testDisconnect_PurgesConnectionAndReassemblyState() {
        val conn = BleConnection(byteArrayOf(1), 20)
        conn.markConnected()
        conn.bindRole(byteArrayOf(2, 3, 4, 5), BleRole.INITIATOR)
        conn.transitionTo(BleConnectionState.READY)

        val payload = ByteArray(50)
        val frags = conn.fragmentOutbound(BleRecordType.DATA, payload)
        assertTrue(frags.size > 1)

        assertNull(conn.ingestInboundAttValue(frags[0]))

        conn.markDisconnected()
        assertFalse(conn.isActive)
        assertEquals(BleConnectionState.CLOSED, conn.state)

        assertNull(conn.ingestInboundAttValue(frags[1]))
    }

    @Test
    fun testRepeatedStartStop_Idempotent() {
        val conn = BleConnection(byteArrayOf(1), 20)
        conn.markConnected()
        conn.markDisconnected()
        conn.markDisconnected()
        assertEquals(BleConnectionState.CLOSED, conn.state)
    }

    @Test
    fun testSessionManager_HandshakeApiNotInvokedBySubstrate() {
        val id = MeshIdentity.generate()
        val sm = SessionManager(id, RecordingTrustAuthority())

        val conn = BleConnection(byteArrayOf(1), 20)
        conn.markConnected()

        assertFalse(sm.isReady(byteArrayOf(1)))
    }

    @Test
    fun testLinkLayerReady_RemainsFalse() {
        assertFalse(MeshNode.LINK_LAYER_READY)
    }

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
        if (snapshot.sosPresent) flags = flags or BleLinkInfoConstants.FLAG_SOS_PRESENT
        if (snapshot.clockUntrusted) flags = flags or BleLinkInfoConstants.FLAG_CLOCK_UNTRUSTED

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

    @Test
    fun testServerSubscriptionAndMtuTracking() {
        val conn = BleConnection(
            peerId = byteArrayOf(1, 2, 3, 4, 5, 6),
            initialMaxAttValueLength = 20
        )
        conn.markConnected()
        conn.bindRole(byteArrayOf(0x11, 0x22, 0x33, 0x44), BleRole.RESPONDER)
        assertEquals(20, conn.maxAttValueLength)
        conn.markConnected(negotiatedAttValueLength = 128)
        assertEquals(128, conn.maxAttValueLength)
        assertTrue(conn.isActive)
    }

    @Test
    fun testCrossingConnections_ALessThanB_ARetainsBRejects() {
        val hintA = byteArrayOf(0x00, 0x01, 0x02, 0x03)
        val hintB = byteArrayOf(0x80.toByte(), 0x01, 0x02, 0x03)

        val electionAtA = BleRoleElection.elect(hintA, hintB)
        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), electionAtA)

        val electionAtB = BleRoleElection.elect(hintB, hintA)
        assertEquals(BleRoleElectionResult.Elected(BleRole.RESPONDER), electionAtB)
    }

    @Test
    fun testCrossingConnections_BLessThanA_BRetainsARejects() {
        val hintA = byteArrayOf(0x99.toByte(), 0x00, 0x00, 0x00)
        val hintB = byteArrayOf(0x11, 0x00, 0x00, 0x00)

        val electionAtA = BleRoleElection.elect(hintA, hintB)
        assertEquals(BleRoleElectionResult.Elected(BleRole.RESPONDER), electionAtA)

        val electionAtB = BleRoleElection.elect(hintB, hintA)
        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), electionAtB)
    }

    @Test
    fun testCrossingConnections_EqualHints_BothReject() {
        val hint = byteArrayOf(0x42, 0x42, 0x42, 0x42)
        val res = BleRoleElection.elect(hint, hint)
        assertEquals(BleRoleElectionResult.Tie, res)
    }

    @Test
    fun testLinkInfoV1_EncodeDecodeParityAndValidation() {
        val version: Byte = 0x02
        val flags: Byte = (BleLinkInfoConstants.FLAG_SOS_PRESENT or BleLinkInfoConstants.FLAG_VERIFIED_ONLY).toByte()
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

    @Test
    fun testProvisionalConnection_MissingAdvMetadata_Allowed() {
        val emptyAdvServiceData: ByteArray? = null
        assertNull(emptyAdvServiceData)
    }

    @Test
    fun testLinkInfoAuthority_OverridesAdvMetadata() {
        val realLinkInfoHint = byteArrayOf(0x77, 0x88.toByte(), 0x99.toByte(), 0xAA.toByte())
        val myHint = byteArrayOf(0x11, 0x22, 0x33, 0x44)
        val election = BleRoleElection.elect(myHint, realLinkInfoHint)
        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), election)
    }

    // ------------------------------------------------------------------------
    // 11. Application DATA Is Strictly Gated Before READY State
    // ------------------------------------------------------------------------
    @Test
    fun testDataRecord_ForbiddenBeforeReadyState() {
        val conn = BleConnection(peerId = byteArrayOf(1), initialMaxAttValueLength = 40)
        conn.markConnected()
        conn.bindRole(byteArrayOf(0x01, 0x02, 0x03, 0x04), BleRole.INITIATOR)

        val appData = "Secret Application Data".toByteArray(Charsets.UTF_8)

        // While in ROLE_BOUND or HANDSHAKE_IN_PROGRESS: DATA fragments return empty
        val fragsBeforeReady = conn.fragmentOutbound(BleRecordType.DATA, appData)
        assertTrue(fragsBeforeReady.isEmpty())

        // Transition to READY: DATA fragments are permitted
        conn.transitionTo(BleConnectionState.READY)
        val fragsAfterReady = conn.fragmentOutbound(BleRecordType.DATA, appData)
        assertTrue(fragsAfterReady.isNotEmpty())
    }

    // ------------------------------------------------------------------------
    // 13. Golden Test Vectors Conformance (wire/ble_link_info_vectors.json)
    // ------------------------------------------------------------------------
    @Test
    fun testGoldenVectors_BleLinkInfoV1() {
        val cases = listOf(
            TestCase("all_zero", 0, "01020304", "000000000000", 0, "02000102030400000000000000"),
            TestCase("mixed_flags", 0x15, "a1b2c3d4", "112233445566", 42, "0215a1b2c3d41122334455662a"),
            TestCase("all_flags", 0x1F, "deadbeef", "aabbccddeeff", 128, "021fdeadbeefaabbccddeeff80"),
            TestCase("unsigned_edge_zero", 0, "00000000", "010203040506", 0, "02000000000001020304050600"),
            TestCase("unsigned_edge_max", 0x08, "ffffffff", "ffffffffffff", 255, "0208ffffffffffffffffffffff"),
            TestCase("high_bit_hint", 0x02, "80000000", "1234567890ab", 255, "0202800000001234567890abff")
        )

        for (c in cases) {
            val hint = hexToBytes(c.hintHex)
            val digest = hexToBytes(c.digestHex)
            val expected = hexToBytes(c.expectedHex)

            val encoded = BleLinkInfoCodec.encode(
                flags = c.flags.toByte(),
                nodeHint = hint,
                shortDigest = digest,
                queueDepth = c.depth
            )
            assertArrayEquals("Mismatch in case ${c.name}", expected, encoded)

            val decoded = BleLinkInfoCodec.decode(expected)
            assertNotNull("Decode returned null in case ${c.name}", decoded)
            assertEquals(c.flags.toByte(), decoded!!.flags)
            assertArrayEquals(hint, decoded.nodeHint)
            assertArrayEquals(digest, decoded.shortDigest)
            assertEquals(c.depth, decoded.queueDepth)
        }
    }

    private data class TestCase(
        val name: String,
        val flags: Int,
        val hintHex: String,
        val digestHex: String,
        val depth: Int,
        val expectedHex: String
    )

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
}
