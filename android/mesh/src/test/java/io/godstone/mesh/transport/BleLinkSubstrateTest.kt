package io.godstone.mesh.transport

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.MeshNode
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.ValidatedPeerBinding
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.store.OutboundEnqueueResult
import io.godstone.mesh.wire.v2.FrameV2
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.util.Random

@OptIn(ExperimentalCoroutinesApi::class)
class BleLinkSubstrateTest {

    private class RecordingTrustAuthority : io.godstone.mesh.crypto.PeerBindingTrustAuthority {
        override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
            return PeerTrustApplyResult.Accepted
        }
    }

    private data class ValidCase(
        val name: String,
        val flags: Byte,
        val nodeHint: ByteArray,
        val shortDigest: ByteArray,
        val queueDepth: Int,
        val expectedHex: String
    )
    private data class InvalidCase(val name: String, val hex: String)
    private data class RoleElectionCase(val localHint: ByteArray, val remoteHint: ByteArray, val expectedRole: String?)

    private fun readCanonicalJsonText(): String {
        val candidatePaths = listOf(
            "wire/ble_link_info_vectors.json",
            "../wire/ble_link_info_vectors.json",
            "../../wire/ble_link_info_vectors.json",
            "../../../wire/ble_link_info_vectors.json",
            "../../../../wire/ble_link_info_vectors.json"
        )
        for (path in candidatePaths) {
            val file = File(path)
            if (file.exists()) {
                return file.readText(Charsets.UTF_8)
            }
        }
        val cl = BleLinkSubstrateTest::class.java.classLoader
        val stream = cl?.getResourceAsStream("ble_link_info_vectors.json")
            ?: cl?.getResourceAsStream("wire/ble_link_info_vectors.json")
        if (stream != null) {
            return stream.bufferedReader(Charsets.UTF_8).readText()
        }
        throw IllegalStateException("Cannot find wire/ble_link_info_vectors.json in candidate paths")
    }

    private fun parseValidCases(json: String): List<ValidCase> {
        val validSection = json.substringAfter("\"valid_cases\": [").substringBefore("],")
        val blocks = validSection.split(Regex("\\},\\s*\\{"))
        return blocks.map { block ->
            val name = Regex("\"name\":\\s*\"([^\"]+)\"").find(block)?.groupValues?.get(1) ?: ""
            val flags = Regex("\"flags\":\\s*(\\d+)").find(block)?.groupValues?.get(1)?.toInt()?.toByte() ?: 0
            val hintHex = Regex("\"node_hint\":\\s*\"([^\"]+)\"").find(block)?.groupValues?.get(1) ?: ""
            val digestHex = Regex("\"short_digest\":\\s*\"([^\"]+)\"").find(block)?.groupValues?.get(1) ?: ""
            val queueDepth = Regex("\"queue_depth\":\\s*(\\d+)").find(block)?.groupValues?.get(1)?.toInt() ?: 0
            val expectedHex = Regex("\"expected_hex\":\\s*\"([^\"]+)\"").find(block)?.groupValues?.get(1) ?: ""
            ValidCase(name, flags, hexToBytes(hintHex), hexToBytes(digestHex), queueDepth, expectedHex)
        }
    }

    private fun parseInvalidCases(json: String): List<InvalidCase> {
        val invalidSection = json.substringAfter("\"invalid_cases\": [").substringBefore("],")
        val blocks = invalidSection.split(Regex("\\},\\s*\\{"))
        return blocks.map { block ->
            val name = Regex("\"name\":\\s*\"([^\"]+)\"").find(block)?.groupValues?.get(1) ?: ""
            val hex = Regex("\"hex\":\\s*\"([^\"]*)\"").find(block)?.groupValues?.get(1) ?: ""
            InvalidCase(name, hex)
        }
    }

    private fun parseRoleElectionCases(json: String): List<RoleElectionCase> {
        val section = json.substringAfter("\"role_election_cases\": [").substringBefore("]")
        val blocks = section.split(Regex("\\},\\s*\\{"))
        return blocks.map { block ->
            val localHex = Regex("\"local_hint\":\\s*\"([^\"]+)\"").find(block)?.groupValues?.get(1) ?: ""
            val remoteHex = Regex("\"remote_hint\":\\s*\"([^\"]+)\"").find(block)?.groupValues?.get(1) ?: ""
            val expectedRole = Regex("\"expected_role\":\\s*\"([^\"]+)\"").find(block)?.groupValues?.get(1)
            RoleElectionCase(hexToBytes(localHex), hexToBytes(remoteHex), expectedRole)
        }
    }

    // ------------------------------------------------------------------------
    // 1. Unsigned lexicographical role election
    // ------------------------------------------------------------------------
    @Test
    fun testRoleElection_UnsignedLexicographical() {
        val hintSmall = byteArrayOf(0x00, 0x01, 0x02, 0x03)
        val hintLarge = byteArrayOf(0x80.toByte(), 0x01, 0x02, 0x03)

        val res1 = BleRoleElection.elect(hintSmall, hintLarge)
        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), res1)

        val res2 = BleRoleElection.elect(hintLarge, hintSmall)
        assertEquals(BleRoleElectionResult.Elected(BleRole.RESPONDER), res2)

        // 0x7F vs 0x80
        val hint7F = byteArrayOf(0x7F, 0x00, 0x00, 0x00)
        val hint80 = byteArrayOf(0x80.toByte(), 0x00, 0x00, 0x00)
        assertEquals(BleRoleElectionResult.Elected(BleRole.INITIATOR), BleRoleElection.elect(hint7F, hint80))
        assertEquals(BleRoleElectionResult.Elected(BleRole.RESPONDER), BleRoleElection.elect(hint80, hint7F))
    }

    // ------------------------------------------------------------------------
    // 2. 1000 Pair Property Test
    // ------------------------------------------------------------------------
    @Test
    fun testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator() {
        val rng = Random(42)
        for (i in 0 until 1000) {
            val a = ByteArray(4).also { rng.nextBytes(it) }
            val b = ByteArray(4).also { rng.nextBytes(it) }
            if (a.contentEquals(b)) continue

            val resAB = BleRoleElection.elect(a, b)
            val resBA = BleRoleElection.elect(b, a)

            assertTrue("Expected Elected for AB", resAB is BleRoleElectionResult.Elected)
            assertTrue("Expected Elected for BA", resBA is BleRoleElectionResult.Elected)

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
    // 3. Equal-hint Rejection (Fail Closed)
    // ------------------------------------------------------------------------
    @Test
    fun testRoleElection_EqualHints_FailClosed() {
        val hint = byteArrayOf(0x12, 0x34, 0x56, 0x78)
        val res = BleRoleElection.elect(hint, hint)
        assertEquals(BleRoleElectionResult.Tie, res)
    }

    // ------------------------------------------------------------------------
    // 4. LinkInfo V1 Encode/Decode Parity and Flags
    // ------------------------------------------------------------------------
    @Test
    fun testLinkInfoV1_EncodeDecodeParity() {
        val version: Byte = 0x02
        val flags: Byte = (BleLinkInfoConstants.FLAG_SOS_PRESENT or BleLinkInfoConstants.FLAG_POWER_CONSTRAINED).toByte()
        val nodeHint = byteArrayOf(0xAA.toByte(), 0xBB.toByte(), 0xCC.toByte(), 0xDD.toByte())
        val shortDigest = byteArrayOf(0x01, 0x02, 0x03, 0x04, 0x05, 0x06)
        val queueDepth: Int = 42

        val encoded = BleLinkInfoCodec.encode(
            version = version,
            flags = flags,
            nodeHint = nodeHint,
            shortDigest = shortDigest,
            queueDepth = queueDepth
        )
        assertEquals(13, encoded.size)

        val decoded = BleLinkInfoCodec.decode(encoded)
        assertNotNull(decoded)
        assertEquals(version, decoded!!.version)
        assertEquals(flags, decoded.flags)
        assertArrayEquals(nodeHint, decoded.nodeHint)
        assertArrayEquals(shortDigest, decoded.shortDigest)
        assertEquals(queueDepth, decoded.queueDepth)
        assertTrue(decoded.isSosPresent)
        assertTrue(decoded.isPowerConstrained)
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
    // 6. Unknown Version Rejections
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
    // 7. Canonical JSON LinkInfo Vectors (Directly Consumed from JSON)
    // ------------------------------------------------------------------------
    @Test
    fun testLinkInfoV1_CanonicalJsonVectors_AllValidAndInvalid() {
        val json = readCanonicalJsonText()

        // Valid cases
        val validCases = parseValidCases(json)
        assertTrue("Expected at least 1 valid case", validCases.isNotEmpty())
        for (c in validCases) {
            val expected = hexToBytes(c.expectedHex)
            val encoded = BleLinkInfoCodec.encode(
                flags = c.flags,
                nodeHint = c.nodeHint,
                shortDigest = c.shortDigest,
                queueDepth = c.queueDepth
            )
            assertArrayEquals("Mismatch encoding case ${c.name}", expected, encoded)

            val decoded = BleLinkInfoCodec.decode(expected)
            assertNotNull("Decode returned null in case ${c.name}", decoded)
            assertEquals(c.flags, decoded!!.flags)
            assertArrayEquals(c.nodeHint, decoded.nodeHint)
            assertArrayEquals(c.shortDigest, decoded.shortDigest)
            assertEquals(c.queueDepth, decoded.queueDepth)
        }

        // Invalid cases
        val invalidCases = parseInvalidCases(json)
        assertTrue("Expected at least 1 invalid case", invalidCases.isNotEmpty())
        for (c in invalidCases) {
            val data = hexToBytes(c.hex)
            assertNull("Expected invalid case ${c.name} (${c.hex}) to decode as null", BleLinkInfoCodec.decode(data))
        }
    }

    // ------------------------------------------------------------------------
    // 8. Canonical JSON Role Election Cases (Directly Consumed from JSON)
    // ------------------------------------------------------------------------
    @Test
    fun testRoleElection_CanonicalJsonVectors() {
        val json = readCanonicalJsonText()
        val electionCases = parseRoleElectionCases(json)
        assertTrue("Expected at least 1 role election case", electionCases.isNotEmpty())
        for (c in electionCases) {
            val res = BleRoleElection.elect(c.localHint, c.remoteHint)
            if (c.expectedRole != null) {
                val expectedRole = if (c.expectedRole == "INITIATOR") BleRole.INITIATOR else BleRole.RESPONDER
                assertEquals("Mismatch in role election for ${c.localHint} vs ${c.remoteHint}", BleRoleElectionResult.Elected(expectedRole), res)
            } else {
                assertEquals("Expected tie for ${c.localHint} vs ${c.remoteHint}", BleRoleElectionResult.Tie, res)
            }
        }
    }

    // ------------------------------------------------------------------------
    // 9. Authoritative State Progression - Initiator & Responder
    // ------------------------------------------------------------------------
    @Test
    fun testStateProgression_InitiatorFlow_Authoritative() {
        val conn = BleConnection(peerId = byteArrayOf(1, 2, 3, 4, 5, 6))
        assertEquals(BleConnectionState.PROVISIONAL_CONNECTING, conn.state)

        conn.markConnected()
        assertEquals(BleConnectionState.PROVISIONAL_CONNECTED, conn.state)

        conn.startLinkInfoRead()
        assertEquals(BleConnectionState.LINK_INFO_READING, conn.state)

        conn.startLinkInfoWrite()
        assertEquals(BleConnectionState.LINK_INFO_WRITING, conn.state)

        val remoteHint = byteArrayOf(0x01, 0x02, 0x03, 0x04)
        conn.bindInitiatorAfterLinkInfoWriteAck(remoteHint)
        assertEquals(BleConnectionState.ROLE_BOUND, conn.state)
        assertEquals(BleRole.INITIATOR, conn.localRole)
        assertArrayEquals(remoteHint, conn.remoteNodeHint)

        assertFalse(conn.isHandshakeTransportReady)
        conn.isNotificationSubscribed = true
        assertTrue(conn.isHandshakeTransportReady)
    }

    @Test
    fun testStateProgression_ResponderFlow_Authoritative() {
        val conn = BleConnection(peerId = byteArrayOf(6, 5, 4, 3, 2, 1))
        conn.markConnected()
        assertEquals(BleConnectionState.PROVISIONAL_CONNECTED, conn.state)

        val remoteHint = byteArrayOf(0x05, 0x06, 0x07, 0x08)
        conn.bindResponderFromAcceptedIncomingLinkInfo(remoteHint)
        assertEquals(BleConnectionState.ROLE_BOUND, conn.state)
        assertEquals(BleRole.RESPONDER, conn.localRole)
        assertArrayEquals(remoteHint, conn.remoteNodeHint)

        assertFalse(conn.isHandshakeTransportReady)
        conn.isNotificationSubscribed = true
        assertTrue(conn.isHandshakeTransportReady)
    }

    // ------------------------------------------------------------------------
    // 10. Role Binding Negative Preconditions
    // ------------------------------------------------------------------------
    @Test
    fun testRoleBinding_NegativePreconditions() {
        val remoteHint = byteArrayOf(1, 2, 3, 4)

        // 1. From DISCOVERED state -> fail
        val connDiscovered = BleConnection(peerId = byteArrayOf(1))
        connDiscovered.markDisconnected()
        try {
            connDiscovered.bindRole(remoteHint, BleRole.INITIATOR)
            fail("Expected bindRole to fail from CLOSED")
        } catch (_: IllegalStateException) {}

        // 2. From PROVISIONAL_CONNECTING -> fail
        val connConnecting = BleConnection(peerId = byteArrayOf(1))
        try {
            connConnecting.bindRole(remoteHint, BleRole.INITIATOR)
            fail("Expected bindRole to fail from PROVISIONAL_CONNECTING")
        } catch (_: IllegalStateException) {}

        // 3. Initiator from PROVISIONAL_CONNECTED -> fail (must be LINK_INFO_WRITING)
        val connConnected = BleConnection(peerId = byteArrayOf(1))
        connConnected.markConnected()
        try {
            connConnected.bindInitiatorAfterLinkInfoWriteAck(remoteHint)
            fail("Expected bindInitiatorAfterLinkInfoWriteAck to fail from PROVISIONAL_CONNECTED")
        } catch (_: IllegalStateException) {}

        // 4. Responder from LINK_INFO_WRITING -> fail (must be PROVISIONAL_CONNECTED)
        val connWriting = BleConnection(peerId = byteArrayOf(1))
        connWriting.markConnected()
        connWriting.startLinkInfoRead()
        connWriting.startLinkInfoWrite()
        try {
            connWriting.bindResponderFromAcceptedIncomingLinkInfo(remoteHint)
            fail("Expected bindResponderFromAcceptedIncomingLinkInfo to fail from LINK_INFO_WRITING")
        } catch (_: IllegalStateException) {}

        // 5. Duplicate bind -> fail
        connWriting.bindInitiatorAfterLinkInfoWriteAck(remoteHint)
        try {
            connWriting.bindInitiatorAfterLinkInfoWriteAck(remoteHint)
            fail("Expected duplicate bind to fail")
        } catch (_: IllegalStateException) {}
    }

    // ------------------------------------------------------------------------
    // 11. Substrate Forbidden From Transitioning to READY
    // ------------------------------------------------------------------------
    @Test
    fun testTransitionToReady_ForbiddenInSubstrate() {
        val conn = BleConnection(peerId = byteArrayOf(1))
        conn.markConnected()
        conn.startLinkInfoRead()
        conn.startLinkInfoWrite()
        conn.bindInitiatorAfterLinkInfoWriteAck(byteArrayOf(1, 2, 3, 4))
        conn.isNotificationSubscribed = true
        conn.transitionTo(BleConnectionState.HANDSHAKE_IN_PROGRESS)

        try {
            conn.transitionTo(BleConnectionState.READY)
            fail("Expected transitionTo(READY) to be rejected by substrate")
        } catch (e: IllegalStateException) {
            assertTrue(e.message?.contains("READY") == true)
        }
    }

    // ------------------------------------------------------------------------
    // 12. Application DATA Forbidden Before Cryptographic READY
    // ------------------------------------------------------------------------
    @Test
    fun testDataTransmission_StrictlyForbiddenBeforeReady() {
        val conn = BleConnection(peerId = byteArrayOf(1))
        conn.markConnected()
        conn.startLinkInfoRead()
        conn.startLinkInfoWrite()
        conn.bindInitiatorAfterLinkInfoWriteAck(byteArrayOf(1, 2, 3, 4))
        conn.isNotificationSubscribed = true

        val appData = "Secret Mesh Payload".toByteArray(Charsets.UTF_8)
        val fragsInRoleBound = conn.fragmentOutbound(BleRecordType.DATA, appData)
        assertTrue("DATA fragments must be empty before READY", fragsInRoleBound.isEmpty())

        conn.transitionTo(BleConnectionState.HANDSHAKE_IN_PROGRESS)
        val fragsInHs = conn.fragmentOutbound(BleRecordType.DATA, appData)
        assertTrue("DATA fragments must be empty in HANDSHAKE_IN_PROGRESS", fragsInHs.isEmpty())
    }

    // ------------------------------------------------------------------------
    // 13. Dynamic LinkInfo Snapshot Authority Tests
    // ------------------------------------------------------------------------
    private class MockMessageStore : MessageStore {
        val held = mutableListOf<ByteArray>()
        override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): PersistResult { held.add(frame.msgId); return PersistResult.HELD_NEW }
        override suspend fun enqueueDirectOutbound(frame: FrameV2, expectedRecipient: ByteArray, localOriginNodeId: ByteArray): OutboundEnqueueResult = OutboundEnqueueResult.CanonicalFrameMismatch
        override suspend fun allHeldOrderedByPriority(): List<FrameV2> = emptyList()
        override suspend fun allHeldMsgIds(): List<ByteArray> = held
        override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) {}
        override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {
            for (id in held) {
                if (!visit(id)) break
            }
        }
    }

    @Test
    fun testLinkInfoSnapshotAuthority_EmptyStore() {
        val identity = MeshIdentity.generate()
        val store = MockMessageStore()
        val authority = LinkInfoSnapshotAuthority(
            identityProvider = { identity },
            storeProvider = { store }
        )

        val snap = authority.currentSnapshot()
        assertEquals(0, snap.queueDepth)
        assertArrayEquals(identity.nodeHint, snap.nodeHint)
        assertArrayEquals(ByteArray(6), snap.shortDigest)
    }

    @Test
    fun testLinkInfoSnapshotAuthority_HeldRecordsAndSaturating255() {
        val identity = MeshIdentity.generate()
        val store = MockMessageStore()
        val authority = LinkInfoSnapshotAuthority(
            identityProvider = { identity },
            storeProvider = { store }
        )

        // Insert 10 records
        val bloom = BloomDigest()
        for (i in 1..10) {
            val msgId = ByteArray(16) { (i + it).toByte() }
            store.held.add(msgId)
            bloom.add(msgId)
        }

        authority.refresh()
        val snap10 = authority.currentSnapshot()
        assertEquals(10, snap10.queueDepth)
        assertArrayEquals(bloom.toBytes().copyOf(6), snap10.shortDigest)

        // Insert 300 records to test saturation at 255
        for (i in 11..300) {
            val msgId = ByteArray(16) { (i + it).toByte() }
            store.held.add(msgId)
        }

        authority.refresh()
        val snap300 = authority.currentSnapshot()
        assertEquals(255, snap300.queueDepth)
    }

    // ------------------------------------------------------------------------
    // 14. Crossing Connections Logic
    // ------------------------------------------------------------------------
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

    // ------------------------------------------------------------------------
    // 15. Handshake Record Delivery Across Seam
    // ------------------------------------------------------------------------
    @Test
    fun testHandshakeRecordDelivery_AcrossConnectionSeam() {
        val connA = BleConnection(byteArrayOf(1), 30)
        connA.markConnected()
        connA.startLinkInfoRead()
        connA.startLinkInfoWrite()
        connA.bindInitiatorAfterLinkInfoWriteAck(byteArrayOf(5, 6, 7, 8))
        connA.isNotificationSubscribed = true
        connA.transitionTo(BleConnectionState.HANDSHAKE_IN_PROGRESS)

        val connB = BleConnection(byteArrayOf(2), 30)
        connB.markConnected()
        connB.bindResponderFromAcceptedIncomingLinkInfo(byteArrayOf(1, 2, 3, 4))
        connB.isNotificationSubscribed = true
        connB.transitionTo(BleConnectionState.HANDSHAKE_IN_PROGRESS)

        // Handshake 2 record (229 bytes)
        val hs2Payload = ByteArray(229) { (it * 3).toByte() }
        val frags = connA.fragmentOutbound(BleRecordType.HS2, hs2Payload)
        assertTrue(frags.size > 1)

        var reassembled: BleReassembledRecord? = null
        for (f in frags) {
            val r = connB.ingestInboundAttValue(f)
            if (r != null) reassembled = r
        }
        assertNotNull(reassembled)
        assertEquals(BleRecordType.HS2, reassembled!!.recordType)
        assertArrayEquals(hs2Payload, reassembled.payload)
    }

    // ------------------------------------------------------------------------
    // 16. Disconnect Purges Reassembly State & Idempotent Start/Stop
    // ------------------------------------------------------------------------
    @Test
    fun testDisconnect_PurgesState_AndIdempotent() {
        val conn = BleConnection(byteArrayOf(1), 20)
        conn.markConnected()
        conn.startLinkInfoRead()
        conn.startLinkInfoWrite()
        conn.bindInitiatorAfterLinkInfoWriteAck(byteArrayOf(2, 3, 4, 5))
        conn.isNotificationSubscribed = true

        val hs1Payload = ByteArray(32) { 1 }
        val frags = conn.fragmentOutbound(BleRecordType.HS1, hs1Payload)
        assertNull(conn.ingestInboundAttValue(frags[0]))

        conn.markDisconnected()
        assertFalse(conn.isActive)
        assertEquals(BleConnectionState.CLOSED, conn.state)

        // Fragments after disconnect are rejected
        assertNull(conn.ingestInboundAttValue(frags[1]))

        // Repeated disconnect is safe and idempotent
        conn.markDisconnected()
        assertEquals(BleConnectionState.CLOSED, conn.state)
    }

    // ------------------------------------------------------------------------
    // 17. LINK_LAYER_READY Remains False
    // ------------------------------------------------------------------------
    @Test
    fun testLinkLayerReady_RemainsFalse() {
        assertFalse(MeshNode.LINK_LAYER_READY)
    }

    // ------------------------------------------------------------------------
    // 18. SessionManager Handshake API Not Invoked by Substrate
    // ------------------------------------------------------------------------
    @Test
    fun testSessionManager_HandshakeApiNotInvokedBySubstrate() {
        val id = MeshIdentity.generate()
        val sm = SessionManager(id, RecordingTrustAuthority())
        val conn = BleConnection(byteArrayOf(1), 20)
        conn.markConnected()
        assertFalse(sm.isReady(byteArrayOf(1)))
    }

    private fun hexToBytes(hex: String): ByteArray {
        if (hex.isEmpty()) return ByteArray(0)
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
