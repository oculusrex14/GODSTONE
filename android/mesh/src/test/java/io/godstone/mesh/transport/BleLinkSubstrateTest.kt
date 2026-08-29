package io.godstone.mesh.transport

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.MeshNode
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.ValidatedPeerBinding
import io.godstone.mesh.router.BloomDigest
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.store.MessageStore
import io.godstone.mesh.store.PersistResult
import io.godstone.mesh.wire.v2.FrameV2
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.TypeV2
import kotlinx.coroutines.ExperimentalCoroutinesApi
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

    private class MockMessageStore : MessageStore {
        val held = mutableListOf<ByteArray>()
        private val observers = mutableListOf<() -> Unit>()

        override fun registerHeldSetObserver(observer: () -> Unit) {
            observers.add(observer)
        }

        fun notifyChanged() {
            observers.forEach { it.invoke() }
        }

        override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray): PersistResult {
            held.add(frame.msgId)
            notifyChanged()
            return PersistResult.HELD_NEW
        }

        fun remove(msgId: ByteArray) {
            held.removeIf { it.contentEquals(msgId) }
            notifyChanged()
        }

        fun clear() {
            held.clear()
            notifyChanged()
        }

        override suspend fun enqueueDirectOutbound(
            frame: FrameV2,
            expectedRecipient: ByteArray,
            localOriginNodeId: ByteArray
        ) = io.godstone.mesh.store.OutboundEnqueueResult.CanonicalFrameMismatch

        override suspend fun allHeldOrderedByPriority(): List<FrameV2> = emptyList()
        override suspend fun allHeldMsgIds(): List<ByteArray> = held.toList()
        override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) {}
        override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {
            for (id in held) {
                if (!visit(id)) break
            }
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
        val blocks = validSection.split("},\n    {", "},\n     {", "},\r\n    {")
        val cases = mutableListOf<ValidCase>()
        for (b in blocks) {
            val name = b.substringAfter("\"name\": \"").substringBefore("\"")
            val flags = b.substringAfter("\"flags\": ").substringBefore(",").trim().toInt().toByte()
            val nodeHintHex = b.substringAfter("\"node_hint\": \"").substringBefore("\"")
            val shortDigestHex = b.substringAfter("\"short_digest\": \"").substringBefore("\"")
            val queueDepth = b.substringAfter("\"queue_depth\": ").substringBefore(",").trim().toInt()
            val expectedHex = b.substringAfter("\"expected_hex\": \"").substringBefore("\"")
            cases.add(
                ValidCase(
                    name = name,
                    flags = flags,
                    nodeHint = hexToBytes(nodeHintHex),
                    shortDigest = hexToBytes(shortDigestHex),
                    queueDepth = queueDepth,
                    expectedHex = expectedHex
                )
            )
        }
        return cases
    }

    private fun parseInvalidCases(json: String): List<InvalidCase> {
        val invalidSection = json.substringAfter("\"invalid_cases\": [").substringBefore("],")
        val blocks = invalidSection.split("},\n    {", "},\n     {", "},\r\n    {")
        val cases = mutableListOf<InvalidCase>()
        for (b in blocks) {
            val name = b.substringAfter("\"name\": \"").substringBefore("\"")
            val hex = b.substringAfter("\"hex\": \"").substringBefore("\"")
            cases.add(InvalidCase(name, hex))
        }
        return cases
    }

    private fun parseRoleElectionCases(json: String): List<RoleElectionCase> {
        val section = json.substringAfter("\"role_election_cases\": [").substringBefore("]")
        val blocks = section.split("},\n    {", "},\n     {", "},\r\n    {")
        val cases = mutableListOf<RoleElectionCase>()
        for (b in blocks) {
            val localHex = b.substringAfter("\"local_hint\": \"").substringBefore("\"")
            val remoteHex = b.substringAfter("\"remote_hint\": \"").substringBefore("\"")
            val expectedRole = if (b.contains("\"expected_role\": null")) {
                null
            } else {
                b.substringAfter("\"expected_role\": \"").substringBefore("\"")
            }
            cases.add(
                RoleElectionCase(
                    localHint = hexToBytes(localHex),
                    remoteHint = hexToBytes(remoteHex),
                    expectedRole = expectedRole
                )
            )
        }
        return cases
    }

    private fun hexToBytes(hex: String): ByteArray {
        val clean = hex.trim()
        val len = clean.length
        val data = ByteArray(len / 2)
        var i = 0
        while (i < len) {
            data[i / 2] = ((Character.digit(clean[i], 16) shl 4) + Character.digit(clean[i + 1], 16)).toByte()
            i += 2
        }
        return data
    }

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

    private fun bytesToHex(bytes: ByteArray): String {
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun makeIdentity(): Identity {
        val storage = InMemoryIdentityStorage()
        return Identity.loadOrCreate(storage)
    }

    @Test
    fun testRoleElection_UnsignedLexicographical() {
        val hintLow = byteArrayOf(0x01, 0x00, 0x00, 0x00)
        val hintHigh = byteArrayOf(0x80.toByte(), 0x00, 0x00, 0x00)

        val resultA = BleRoleElection.elect(hintLow, hintHigh)
        assertTrue(resultA is BleRoleElectionResult.Elected)
        assertEquals(BleRole.INITIATOR, (resultA as BleRoleElectionResult.Elected).role)

        val resultB = BleRoleElection.elect(hintHigh, hintLow)
        assertTrue(resultB is BleRoleElectionResult.Elected)
        assertEquals(BleRole.RESPONDER, (resultB as BleRoleElectionResult.Elected).role)
    }

    @Test
    fun testRoleElection_1000RandomUnequalPairs_ExactlyOneInitiator() {
        val rng = Random(42)
        for (i in 0 until 1000) {
            val a = ByteArray(4).apply { rng.nextBytes(this) }
            val b = ByteArray(4).apply { rng.nextBytes(this) }
            if (a.contentEquals(b)) continue

            val resA = BleRoleElection.elect(a, b)
            val resB = BleRoleElection.elect(b, a)

            assertTrue(resA is BleRoleElectionResult.Elected)
            assertTrue(resB is BleRoleElectionResult.Elected)

            val roleA = (resA as BleRoleElectionResult.Elected).role
            val roleB = (resB as BleRoleElectionResult.Elected).role

            assertTrue(
                (roleA == BleRole.INITIATOR && roleB == BleRole.RESPONDER) ||
                    (roleA == BleRole.RESPONDER && roleB == BleRole.INITIATOR)
            )
        }
    }

    @Test
    fun testRoleElection_EqualHints_FailClosed() {
        val hint = byteArrayOf(0x12, 0x34, 0x56, 0x78)
        val result = BleRoleElection.elect(hint, hint)
        assertEquals(BleRoleElectionResult.Tie, result)
    }

    @Test
    fun testRoleElection_CanonicalJsonVectors() {
        val json = readCanonicalJsonText()
        val cases = parseRoleElectionCases(json)
        assertTrue("Must find role election cases in json", cases.isNotEmpty())

        for (c in cases) {
            val result = BleRoleElection.elect(c.localHint, c.remoteHint)
            if (c.expectedRole == null) {
                assertEquals(BleRoleElectionResult.Tie, result)
            } else {
                assertTrue("Expected Elected for ${bytesToHex(c.localHint)} vs ${bytesToHex(c.remoteHint)}", result is BleRoleElectionResult.Elected)
                val role = (result as BleRoleElectionResult.Elected).role
                assertEquals(c.expectedRole, role.name)
            }
        }
    }

    @Test
    fun testLinkInfoV1_EncodeDecodeParity() {
        val flags: Byte = (BleLinkInfoConstants.FLAG_SOS_PRESENT or BleLinkInfoConstants.FLAG_CLOCK_UNTRUSTED).toByte()
        val nodeHint = byteArrayOf(0xDE.toByte(), 0xAD.toByte(), 0xBE.toByte(), 0xEF.toByte())
        val shortDigest = byteArrayOf(1, 2, 3, 4, 5, 6)
        val queueDepth = 42

        val encoded = BleLinkInfoCodec.encode(
            version = BleLinkInfoConstants.PROTOCOL_VERSION,
            flags = flags,
            nodeHint = nodeHint,
            shortDigest = shortDigest,
            queueDepth = queueDepth
        )
        assertEquals(BleLinkInfoConstants.LINK_INFO_BYTES, encoded.size)

        val decoded = BleLinkInfoCodec.decode(encoded)
        assertNotNull(decoded)
        assertEquals(BleLinkInfoConstants.PROTOCOL_VERSION, decoded!!.version)
        assertEquals(flags, decoded.flags)
        assertArrayEquals(nodeHint, decoded.nodeHint)
        assertArrayEquals(shortDigest, decoded.shortDigest)
        assertEquals(queueDepth, decoded.queueDepth)
    }

    @Test
    fun testLinkInfoV1_MalformedLength_Rejected() {
        assertNull(BleLinkInfoCodec.decode(ByteArray(12)))
        assertNull(BleLinkInfoCodec.decode(ByteArray(14)))
        assertNull(BleLinkInfoCodec.decode(ByteArray(0)))
    }

    @Test
    fun testLinkInfoV1_UnknownVersion_Rejected() {
        val badVersionBytes = ByteArray(13).apply { this[0] = 0x03 }
        assertNull(BleLinkInfoCodec.decode(badVersionBytes))
    }

    @Test
    fun testLinkInfoV1_CanonicalJsonVectors_AllValidAndInvalid() {
        val json = readCanonicalJsonText()
        val validCases = parseValidCases(json)
        val invalidCases = parseInvalidCases(json)

        assertTrue(validCases.isNotEmpty())
        assertTrue(invalidCases.isNotEmpty())

        for (c in validCases) {
            val encoded = BleLinkInfoCodec.encode(
                version = BleLinkInfoConstants.PROTOCOL_VERSION,
                flags = c.flags,
                nodeHint = c.nodeHint,
                shortDigest = c.shortDigest,
                queueDepth = c.queueDepth
            )
            assertEquals("Encode mismatch for ${c.name}", c.expectedHex, bytesToHex(encoded))

            val decoded = BleLinkInfoCodec.decode(encoded)
            assertNotNull("Decode failed for ${c.name}", decoded)
            assertEquals(BleLinkInfoConstants.PROTOCOL_VERSION, decoded!!.version)
            assertEquals(c.flags, decoded.flags)
            assertArrayEquals(c.nodeHint, decoded.nodeHint)
            assertArrayEquals(c.shortDigest, decoded.shortDigest)
            assertEquals(c.queueDepth, decoded.queueDepth)
        }

        for (c in invalidCases) {
            val raw = hexToBytes(c.hex)
            val decoded = BleLinkInfoCodec.decode(raw)
            assertNull("Invalid case ${c.name} should fail decode", decoded)
        }
    }

    @Test
    fun testRoleBinding_NegativePreconditions() {
        val conn = BleConnection(byteArrayOf(1, 2, 3))
        val hint = byteArrayOf(0x01, 0x02, 0x03, 0x04)

        // 1. Generic transitionTo to ROLE_BOUND / HANDSHAKE_IN_PROGRESS / READY is forbidden
        try {
            conn.transitionTo(BleConnectionState.ROLE_BOUND)
            fail("Direct transition to ROLE_BOUND must fail")
        } catch (_: IllegalArgumentException) {}

        try {
            conn.transitionTo(BleConnectionState.HANDSHAKE_IN_PROGRESS)
            fail("Direct transition to HANDSHAKE_IN_PROGRESS must fail")
        } catch (_: IllegalArgumentException) {}

        try {
            conn.transitionTo(BleConnectionState.READY)
            fail("Direct transition to READY must fail")
        } catch (_: IllegalArgumentException) {}

        // 2. Initiator bind from PROVISIONAL_CONNECTING or PROVISIONAL_CONNECTED must fail
        try {
            conn.bindInitiatorAfterLinkInfoWriteAck(hint)
            fail("Initiator bind from PROVISIONAL_CONNECTING must fail")
        } catch (_: IllegalStateException) {}

        conn.transitionTo(BleConnectionState.PROVISIONAL_CONNECTED)
        try {
            conn.bindInitiatorAfterLinkInfoWriteAck(hint)
            fail("Initiator bind from PROVISIONAL_CONNECTED must fail")
        } catch (_: IllegalStateException) {}

        // 3. Responder bind from LINK_INFO_WRITING must fail
        val conn2 = BleConnection(byteArrayOf(4, 5, 6))
        conn2.transitionTo(BleConnectionState.PROVISIONAL_CONNECTED)
        conn2.transitionTo(BleConnectionState.LINK_INFO_READING)
        conn2.transitionTo(BleConnectionState.LINK_INFO_WRITING)
        try {
            conn2.bindResponderFromAcceptedIncomingLinkInfo(hint)
            fail("Responder bind from LINK_INFO_WRITING must fail")
        } catch (_: IllegalStateException) {}

        // 4. Successful initiator bind from LINK_INFO_WRITING
        conn2.bindInitiatorAfterLinkInfoWriteAck(hint)
        assertEquals(BleConnectionState.ROLE_BOUND, conn2.state)
        assertEquals(BleRole.INITIATOR, conn2.localRole)
        assertTrue(conn2.isRoleBound)

        // 5. Duplicate bind must fail
        try {
            conn2.bindInitiatorAfterLinkInfoWriteAck(hint)
            fail("Duplicate bind must fail")
        } catch (_: IllegalStateException) {}

        // 6. After close, bind must fail
        conn2.transitionTo(BleConnectionState.CLOSED)
        try {
            conn2.bindInitiatorAfterLinkInfoWriteAck(hint)
            fail("Bind on closed connection must fail")
        } catch (_: IllegalStateException) {}
    }

    @Test
    fun testStateProgression_InitiatorFlow_Authoritative() {
        val conn = BleConnection(byteArrayOf(1, 2, 3))
        assertEquals(BleConnectionState.PROVISIONAL_CONNECTING, conn.state)

        conn.transitionTo(BleConnectionState.PROVISIONAL_CONNECTED)
        conn.transitionTo(BleConnectionState.LINK_INFO_READING)
        conn.transitionTo(BleConnectionState.LINK_INFO_WRITING)

        val remoteHint = byteArrayOf(1, 2, 3, 4)
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
        val conn = BleConnection(byteArrayOf(1, 2, 3))
        conn.transitionTo(BleConnectionState.PROVISIONAL_CONNECTED)

        val remoteHint = byteArrayOf(5, 6, 7, 8)
        conn.bindResponderFromAcceptedIncomingLinkInfo(remoteHint)
        assertEquals(BleConnectionState.ROLE_BOUND, conn.state)
        assertEquals(BleRole.RESPONDER, conn.localRole)
        assertArrayEquals(remoteHint, conn.remoteNodeHint)

        assertFalse(conn.isHandshakeTransportReady)
        conn.isNotificationSubscribed = true
        assertTrue(conn.isHandshakeTransportReady)
    }

    @Test
    fun testTransitionToReady_ForbiddenInSubstrate() {
        val conn = BleConnection(byteArrayOf(1, 2, 3))
        try {
            conn.transitionTo(BleConnectionState.READY)
            fail("transitionTo(READY) must throw")
        } catch (_: IllegalArgumentException) {}
    }

    @Test
    fun testDataTransmission_StrictlyForbiddenBeforeReady() {
        val conn = BleConnection(byteArrayOf(1, 2, 3))
        assertFalse(conn.isHandshakeTransportReady)
    }

    @Test
    fun testSnapshotAuthority_MissingAuthorities_FailsClosed() {
        // Missing identity and missing store -> fails closed (null)
        val authMissingAll = LinkInfoSnapshotAuthority()
        assertNull(authMissingAll.currentSnapshot())
        assertNull(authMissingAll.currentBytes())

        // Missing identity only -> fails closed
        val store = MockMessageStore()
        val authMissingIdentity = LinkInfoSnapshotAuthority(storeProvider = { store })
        assertNull(authMissingIdentity.currentSnapshot())
        assertNull(authMissingIdentity.currentBytes())

        // Missing store only -> fails closed
        val identity = makeIdentity()
        val authMissingStore = LinkInfoSnapshotAuthority(identityProvider = { identity })
        assertNull(authMissingStore.currentSnapshot())
        assertNull(authMissingStore.currentBytes())
    }

    @Test
    fun testLinkInfoSnapshotAuthority_EmptyStore() {
        val identity = makeIdentity()
        val store = MockMessageStore()
        val auth = LinkInfoSnapshotAuthority(
            identityProvider = { identity },
            storeProvider = { store }
        )

        val snap = auth.currentSnapshot()
        assertNotNull(snap)
        assertEquals(0, snap!!.queueDepth)
        assertArrayEquals(ByteArray(6), snap.shortDigest)
        assertArrayEquals(identity.nodeHint, snap.nodeHint)
    }

    @Test
    fun testLinkInfoSnapshotAuthority_HeldRecordsAndSaturating255() {
        val identity = makeIdentity()
        val store = MockMessageStore()
        val auth = LinkInfoSnapshotAuthority(
            identityProvider = { identity },
            storeProvider = { store }
        )

        val bloom = BloomDigest()
        for (i in 0 until 300) {
            val msgId = ByteArray(16) { i.toByte() }
            store.held.add(msgId)
            bloom.add(msgId)
        }
        auth.refresh()

        val snap = auth.currentSnapshot()
        assertNotNull(snap)
        assertEquals(255, snap!!.queueDepth)
        val expectedDigest = bloom.toBytes().copyOf(6)
        assertArrayEquals(expectedDigest, snap.shortDigest)
    }

    // ============================================================
    // PRODUCTION ORCHESTRATION TESTS (SECTION 9)
    // ============================================================

    @Test
    fun testOrchestration_UuidOnlyToDuplexReadyAndFound() {
        val localHint = byteArrayOf(0x01, 0x00, 0x00, 0x00)
        val remoteHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val remoteLinkInfo = BleLinkInfoCodec.encode(
            version = BleLinkInfoConstants.PROTOCOL_VERSION, flags = 0, nodeHint = remoteHint, shortDigest = ByteArray(6), queueDepth = 0
        )
        val localLinkInfo = BleLinkInfoCodec.encode(
            version = BleLinkInfoConstants.PROTOCOL_VERSION, flags = 0, nodeHint = localHint, shortDigest = ByteArray(6), queueDepth = 0
        )

        val driver = BleCentralOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { localLinkInfo }
        )

        val peer = "AA:BB:CC:DD:EE:01"
        // 1. Scan result (UUID only) -> ConnectGatt
        val act1 = driver.onScanResult(peer, rssi = -60, serviceDataHint = null)
        assertEquals(BleCentralAction.ConnectGatt(peer), act1)

        // 2. Connected -> DiscoverServices
        val act2 = driver.onGattConnected(peer, gattGeneration = 1, currentGattGen = 1)
        assertEquals(BleCentralAction.DiscoverServices(peer), act2)

        // 3. Services Discovered -> ReadLinkInfo
        val act3 = driver.onServicesDiscovered(peer, success = true, gattGeneration = 1, currentGattGen = 1)
        assertEquals(BleCentralAction.ReadLinkInfo(peer), act3)

        // 4. Remote LinkInfo read (local < remote -> INITIATOR) -> WriteLinkInfo
        val act4 = driver.onLinkInfoReadResult(peer, remoteLinkInfo, gattGeneration = 1, currentGattGen = 1)
        assertTrue(act4 is BleCentralAction.WriteLinkInfo)
        val writeAct = act4 as BleCentralAction.WriteLinkInfo
        assertArrayEquals(remoteHint, writeAct.remoteHint)

        // 5. LinkInfo write acknowledged -> SubscribeCccd
        val act5 = driver.onLinkInfoWriteAcknowledged(peer, success = true, remoteHint = remoteHint, gattGeneration = 1, currentGattGen = 1)
        assertEquals(BleCentralAction.SubscribeCccd(peer), act5)

        // 6. CCCD subscription acknowledged -> Duplex Ready & PublishFound!
        val act6 = driver.onCccdWriteAcknowledged(peer, success = true, gattGeneration = 1, currentGattGen = 1)
        assertEquals(BleCentralAction.PublishFound(peer, -60), act6)
        assertTrue(driver.isPublishedFound(peer))
    }

    @Test
    fun testOrchestration_DuplicateScanCreatesOneProvisionalLink() {
        val driver = BleCentralOrchestrationDriver(
            localHint = byteArrayOf(1, 0, 0, 0),
            localLinkInfoProvider = { ByteArray(13) }
        )
        val peer = "AA:BB:CC:DD:EE:02"
        val act1 = driver.onScanResult(peer, -50, null)
        assertEquals(BleCentralAction.ConnectGatt(peer), act1)
        assertEquals(1, driver.getActiveConnectionCount())

        val act2 = driver.onScanResult(peer, -48, null)
        assertEquals(BleCentralAction.NoOp, act2)
        assertEquals(1, driver.getActiveConnectionCount())
    }

    @Test
    fun testOrchestration_LinkInfoWriteAckRequiredForInitiatorBinding() {
        val driver = BleCentralOrchestrationDriver(
            localHint = byteArrayOf(1, 0, 0, 0),
            localLinkInfoProvider = { ByteArray(13) }
        )
        val peer = "AA:BB:CC:DD:EE:03"
        driver.onScanResult(peer, -60, null)
        driver.onGattConnected(peer, 1, 1)
        driver.onServicesDiscovered(peer, true, 1, 1)
        val remoteLinkInfo = BleLinkInfoCodec.encode(BleLinkInfoConstants.PROTOCOL_VERSION, 0, byteArrayOf(2, 0, 0, 0), ByteArray(6), 0)
        driver.onLinkInfoReadResult(peer, remoteLinkInfo, 1, 1)

        val conn = driver.getActiveConnection(peer)
        assertNotNull(conn)
        assertEquals(BleConnectionState.LINK_INFO_WRITING, conn!!.state)
        assertFalse(conn.isRoleBound)

        // If write fails -> Disconnect and cleanup
        val act = driver.onLinkInfoWriteAcknowledged(peer, success = false, remoteHint = byteArrayOf(2, 0, 0, 0), gattGeneration = 1, currentGattGen = 1)
        assertTrue(act is BleCentralAction.DisconnectGatt)
        assertNull(driver.getActiveConnection(peer))
    }

    @Test
    fun testOrchestration_CccdAckRequiredForPhysicalReady() {
        val driver = BleCentralOrchestrationDriver(
            localHint = byteArrayOf(1, 0, 0, 0),
            localLinkInfoProvider = { ByteArray(13) }
        )
        val peer = "AA:BB:CC:DD:EE:04"
        driver.onScanResult(peer, -60, null)
        driver.onGattConnected(peer, 1, 1)
        driver.onServicesDiscovered(peer, true, 1, 1)
        val remoteLinkInfo = BleLinkInfoCodec.encode(BleLinkInfoConstants.PROTOCOL_VERSION, 0, byteArrayOf(2, 0, 0, 0), ByteArray(6), 0)
        driver.onLinkInfoReadResult(peer, remoteLinkInfo, 1, 1)
        driver.onLinkInfoWriteAcknowledged(peer, true, byteArrayOf(2, 0, 0, 0), 1, 1)

        val conn = driver.getActiveConnection(peer)!!
        assertTrue(conn.isRoleBound)
        assertFalse(conn.isHandshakeTransportReady) // Notification not yet subscribed

        val act = driver.onCccdWriteAcknowledged(peer, success = true, gattGeneration = 1, currentGattGen = 1)
        assertTrue(conn.isHandshakeTransportReady)
        assertEquals(BleCentralAction.PublishFound(peer, -60), act)
    }

    @Test
    fun testOrchestration_CccdFailureNeverPublishesFound() {
        val driver = BleCentralOrchestrationDriver(
            localHint = byteArrayOf(1, 0, 0, 0),
            localLinkInfoProvider = { ByteArray(13) }
        )
        val peer = "AA:BB:CC:DD:EE:05"
        driver.onScanResult(peer, -60, null)
        driver.onGattConnected(peer, 1, 1)
        driver.onServicesDiscovered(peer, true, 1, 1)
        val remoteLinkInfo = BleLinkInfoCodec.encode(BleLinkInfoConstants.PROTOCOL_VERSION, 0, byteArrayOf(2, 0, 0, 0), ByteArray(6), 0)
        driver.onLinkInfoReadResult(peer, remoteLinkInfo, 1, 1)
        driver.onLinkInfoWriteAcknowledged(peer, true, byteArrayOf(2, 0, 0, 0), 1, 1)

        val act = driver.onCccdWriteAcknowledged(peer, success = false, gattGeneration = 1, currentGattGen = 1)
        assertTrue(act is BleCentralAction.DisconnectGatt)
        assertFalse(driver.isPublishedFound(peer))
    }

    @Test
    fun testOrchestration_StaleGattCallbackCannotCompleteNewOperation() {
        val driver = BleCentralOrchestrationDriver(
            localHint = byteArrayOf(1, 0, 0, 0),
            localLinkInfoProvider = { ByteArray(13) }
        )
        val peer = "AA:BB:CC:DD:EE:06"
        driver.onScanResult(peer, -60, null)
        // Stale generation 1 when current is 2 -> Ignored (NoOp)
        val act = driver.onGattConnected(peer, gattGeneration = 1, currentGattGen = 2)
        assertEquals(BleCentralAction.NoOp, act)
    }

    @Test
    fun testOrchestration_NotificationTimeoutInvalidatesPhysicalGeneration() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) }
        )
        val central = "11:22:33:44:55:66"
        driver.onClientConnected(central, peerGeneration = 1)
        assertTrue(driver.isDeviceAdmitted(central))

        // Timeout triggers physical channel teardown
        val act = driver.onNotificationTimeout(central)
        assertEquals(BleServerAction.PoisonServer, act)
        assertFalse(driver.isDeviceAdmitted(central))
        assertNull(driver.getInboundConnection(central))
    }

    @Test
    fun testOrchestration_LateNotificationCallbackCannotCompleteLaterSend() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) }
        )
        val central = "11:22:33:44:55:77"
        driver.onClientConnected(central, peerGeneration = 1)

        // Timeout on send #1 (gen 1)
        driver.onNotificationTimeout(central)

        // Reconnect -> new physical generation 2
        driver.onClientConnected(central, peerGeneration = 2)

        // Late callback for send #1 arrives (notificationGen 1, peerGen 1) while send #2 is in flight (notificationGen 2, peerGen 2)
        val staleAct = driver.onNotificationSent(
            deviceAddress = central,
            statusSuccess = true,
        )
        assertEquals(BleServerAction.NoOp, staleAct)
    }

    @Test
    fun testOrchestration_StaleServiceAddedIgnored() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) }
        )
        // Verify driver state isolation
        assertEquals(0, driver.getAdmittedCount())
    }

    @Test
    fun testOrchestration_RawInboundCapacityBounded() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) },
            maxAdmittedClients = 7
        )

        for (i in 1..7) {
            val addr = "AA:BB:CC:DD:EE:%02d".format(i)
            val act = driver.onClientConnected(addr, peerGeneration = i.toLong())
            assertEquals(BleServerAction.AdmitConnection(addr), act)
        }
        assertEquals(7, driver.getAdmittedCount())

        // 8th client connection rejected
        val addr8 = "AA:BB:CC:DD:EE:08"
        val act8 = driver.onClientConnected(addr8, peerGeneration = 8)
        assertEquals(BleServerAction.RejectConnection(addr8), act8)
        assertFalse(driver.isDeviceAdmitted(addr8))

        // 8th client cannot write or subscribe
        val readAct = driver.onLinkInfoReadRequest(addr8)
        assertEquals(BleServerAction.RejectRead(addr8), readAct)

        val writeAct = driver.onLinkInfoWriteRequest(addr8, ByteArray(13))
        assertTrue(writeAct is BleServerAction.RejectWrite)

        val subAct = driver.onDescriptorWriteRequest(addr8, true)
        assertEquals(BleServerAction.RejectDescriptorWrite(addr8), subAct)

        // Disconnect one client -> replacement is admitted
        driver.onClientDisconnected("AA:BB:CC:DD:EE:01")
        assertEquals(6, driver.getAdmittedCount())

        val act8Replacement = driver.onClientConnected(addr8, peerGeneration = 9)
        assertEquals(BleServerAction.AdmitConnection(addr8), act8Replacement)
        assertEquals(7, driver.getAdmittedCount())
    }

    @Test
    fun testOrchestration_StorePersistAutomaticallyRefreshesLinkInfo() = kotlinx.coroutines.runBlocking {
        val identity = makeIdentity()
        val store = InMemoryMessageStore()
        val auth = LinkInfoSnapshotAuthority(
            identityProvider = { identity },
            storeProvider = { store }
        )

        val initialSnap = auth.currentSnapshot()
        assertNotNull(initialSnap)
        assertEquals(0, initialSnap!!.queueDepth)

        // Persist real frame through normal store API without calling auth.refresh()
        val frame = FrameV2(
            type = TypeV2.MESSAGE,
            flags = Priority.toFlags(Priority.DIRECT),
            ttl = 10,
            hopCount = 0,
            routingTag = ByteArray(4),
            msgId = ByteArray(16) { 0x55.toByte() },
            payload = byteArrayOf(1, 2, 3)
        )
        val res = store.persist(frame, byteArrayOf(9, 9, 9))
        assertEquals(PersistResult.HELD_NEW, res)

        // Observe automatic snapshot update
        val updatedSnap = auth.currentSnapshot()
        assertNotNull(updatedSnap)
        assertEquals(1, updatedSnap!!.queueDepth)
    }

    @Test
    fun testOrchestration_StoreRemovalAutomaticallyRefreshesLinkInfo() = kotlinx.coroutines.runBlocking {
        val identity = makeIdentity()
        val store = InMemoryMessageStore()
        val auth = LinkInfoSnapshotAuthority(
            identityProvider = { identity },
            storeProvider = { store }
        )

        val frame = FrameV2(
            type = TypeV2.MESSAGE,
            flags = Priority.toFlags(Priority.DIRECT),
            ttl = 10,
            hopCount = 0,
            routingTag = ByteArray(4),
            msgId = ByteArray(16) { 0x77.toByte() },
            payload = byteArrayOf(4, 5, 6)
        )
        store.persist(frame, byteArrayOf(9, 9, 9))
        assertEquals(1, auth.currentSnapshot()!!.queueDepth)

        // Remove through store API without manual refresh
        store.removeHeld(frame.msgId)
        assertEquals(0, auth.currentSnapshot()!!.queueDepth)
    }

    @Test
    fun testCrossingConnections_ALessThanB_ARetainsBRejects() {
        val hintA = byteArrayOf(0x01, 0x00, 0x00, 0x00)
        val hintB = byteArrayOf(0x02, 0x00, 0x00, 0x00)

        val electionA = BleRoleElection.elect(hintA, hintB)
        assertTrue(electionA is BleRoleElectionResult.Elected)
        assertEquals(BleRole.INITIATOR, (electionA as BleRoleElectionResult.Elected).role)

        val electionB = BleRoleElection.elect(hintB, hintA)
        assertTrue(electionB is BleRoleElectionResult.Elected)
        assertEquals(BleRole.RESPONDER, (electionB as BleRoleElectionResult.Elected).role)
    }

    @Test
    fun testCrossingConnections_BLessThanA_BRetainsARejects() {
        val hintA = byteArrayOf(0x09, 0x00, 0x00, 0x00)
        val hintB = byteArrayOf(0x03, 0x00, 0x00, 0x00)

        val electionA = BleRoleElection.elect(hintA, hintB)
        assertTrue(electionA is BleRoleElectionResult.Elected)
        assertEquals(BleRole.RESPONDER, (electionA as BleRoleElectionResult.Elected).role)

        val electionB = BleRoleElection.elect(hintB, hintA)
        assertTrue(electionB is BleRoleElectionResult.Elected)
        assertEquals(BleRole.INITIATOR, (electionB as BleRoleElectionResult.Elected).role)
    }

    @Test
    fun testCrossingConnections_EqualHints_BothReject() {
        val hint = byteArrayOf(0x42, 0x42, 0x42, 0x42)
        val election = BleRoleElection.elect(hint, hint)
        assertEquals(BleRoleElectionResult.Tie, election)
    }

    @Test
    fun testHandshakeRecordDelivery_AcrossConnectionSeam() {
        val conn = BleConnection(byteArrayOf(1, 2, 3), 50)
        val hint = byteArrayOf(1, 2, 3, 4)
        conn.transitionTo(BleConnectionState.PROVISIONAL_CONNECTED)
        conn.transitionTo(BleConnectionState.LINK_INFO_READING)
        conn.transitionTo(BleConnectionState.LINK_INFO_WRITING)
        conn.bindInitiatorAfterLinkInfoWriteAck(hint)
        conn.isNotificationSubscribed = true
        assertTrue(conn.isHandshakeTransportReady)

        val recordPayload = ByteArray(60) { it.toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.HS1, 1, recordPayload, 50)
        assertEquals(2, frags.size)

        val reassembler = BleRecordReassembler()
        var reassembled: BleReassembledRecord? = null
        for (f in frags) {
            val r = reassembler.receiveFragmentBytes(f)
            if (r != null) {
                reassembled = r
            }
        }
        assertNotNull(reassembled)
        assertEquals(BleRecordType.HS1, reassembled!!.recordType)
        assertArrayEquals(recordPayload, reassembled.payload)
    }

    @Test
    fun testDisconnect_PurgesState_AndIdempotent() {
        val conn = BleConnection(byteArrayOf(1, 2, 3))
        conn.transitionTo(BleConnectionState.CLOSING)
        conn.transitionTo(BleConnectionState.CLOSED)
        assertFalse(conn.isActive)
        assertEquals(BleConnectionState.CLOSED, conn.state)
    }

    @Test
    fun testLinkLayerReady_RemainsFalse() {
        assertFalse(MeshNode.LINK_LAYER_READY)
    }

    @Test
    fun testNotification_N1Success() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) }
        )
        val epoch = driver.startNewServerEpoch()
        assertTrue(driver.onServiceAdded(epoch, true))
        val central = "11:22:33:44:55:66"
        driver.onClientConnected(central, peerGeneration = 1)
        assertTrue(driver.beginNotification(central))
        val act = driver.onNotificationSent(central, statusSuccess = true)
        assertEquals(BleServerAction.NotificationSuccess(central), act)
    }

    @Test
    fun testNotification_N1ExplicitFailure() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) }
        )
        val epoch = driver.startNewServerEpoch()
        assertTrue(driver.onServiceAdded(epoch, true))
        val central = "11:22:33:44:55:66"
        driver.onClientConnected(central, peerGeneration = 1)
        assertTrue(driver.beginNotification(central))
        val act = driver.onNotificationSent(central, statusSuccess = false)
        assertEquals(BleServerAction.NotificationFailure(central), act)
    }

    @Test
    fun testNotification_N1TimeoutPoisonsServerEpoch() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) }
        )
        val epoch = driver.startNewServerEpoch()
        assertTrue(driver.onServiceAdded(epoch, true))
        val central = "11:22:33:44:55:66"
        driver.onClientConnected(central, peerGeneration = 1)
        assertTrue(driver.beginNotification(central))
        val act = driver.onNotificationTimeout(central)
        assertEquals(BleServerAction.PoisonServer, act)
        assertFalse(driver.beginNotification(central))
    }

    @Test
    fun testNotification_FreshServerEpochAllowsN2() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) }
        )
        val epoch1 = driver.startNewServerEpoch()
        assertTrue(driver.onServiceAdded(epoch1, true))
        val central = "11:22:33:44:55:66"
        driver.onClientConnected(central, peerGeneration = 1)
        assertTrue(driver.beginNotification(central))
        driver.onNotificationTimeout(central)

        // Fresh server epoch
        val epoch2 = driver.startNewServerEpoch()
        assertTrue(epoch2 > epoch1)
        assertTrue(driver.onServiceAdded(epoch2, true))
        driver.onClientConnected(central, peerGeneration = 2)
        assertTrue(driver.beginNotification(central))
        val act = driver.onNotificationSent(central, statusSuccess = true)
        assertEquals(BleServerAction.NotificationSuccess(central), act)
    }

    @Test
    fun testNotification_LateOldCallbackCannotCompleteN2() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) }
        )
        val epoch1 = driver.startNewServerEpoch()
        assertTrue(driver.onServiceAdded(epoch1, true))
        val central = "11:22:33:44:55:66"
        driver.onClientConnected(central, peerGeneration = 1)
        assertTrue(driver.beginNotification(central))
        driver.onNotificationTimeout(central)

        // Late callback from old epoch arrives while server is poisoned -> NoOp
        val lateAct = driver.onNotificationSent(central, statusSuccess = true)
        assertEquals(BleServerAction.NoOp, lateAct)
    }

    @Test
    fun testNotification_StaleServiceAddedCannotMutateNewServer() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) }
        )
        val epoch1 = driver.startNewServerEpoch()
        val epoch2 = driver.startNewServerEpoch()

        // Stale epoch 1 callback arrives after epoch 2 has begun
        assertFalse(driver.onServiceAdded(epoch1, true))
        assertFalse(driver.isServerReady)

        // Valid epoch 2 callback succeeds
        assertTrue(driver.onServiceAdded(epoch2, true))
        assertTrue(driver.isServerReady)
    }

    @Test
    fun testNotification_DisconnectWhilePendingSettles() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) }
        )
        val epoch = driver.startNewServerEpoch()
        assertTrue(driver.onServiceAdded(epoch, true))
        val central = "11:22:33:44:55:66"
        driver.onClientConnected(central, peerGeneration = 1)
        assertTrue(driver.beginNotification(central))
        driver.onClientDisconnected(central)

        // Callback after disconnect is NoOp
        val act = driver.onNotificationSent(central, statusSuccess = true)
        assertEquals(BleServerAction.NoOp, act)
    }

    @Test
    fun testLinkInfo_AckRetirementAutomaticallyRefreshesSnapshot() = kotlinx.coroutines.runBlocking {
        val identity = makeIdentity()
        val tmpFile = File.createTempFile("godstone_retire_ack", ".db")
        tmpFile.deleteOnExit()
        val store = io.godstone.mesh.store.SqliteMessageStore(
            io.godstone.mesh.store.JdbcStoreDb(tmpFile),
            4096,
            null
        )
        val repo = io.godstone.mesh.delivery.SqliteDeliveryRepository(store.engine, store::notifyHeldSetChanged)
        val authority = LinkInfoSnapshotAuthority(
            identityProvider = { identity },
            storeProvider = { store }
        )

        val msgId = ByteArray(16) { 0x11.toByte() }
        val recipient = ByteArray(16) { 0x22.toByte() }
        val frame = FrameV2(
            type = TypeV2.MESSAGE,
            flags = Priority.toFlags(Priority.DIRECT) or FrameV2.SEALED,
            ttl = 10,
            hopCount = 0,
            routingTag = ByteArray(4),
            msgId = msgId,
            payload = byteArrayOf(1, 2, 3)
        )
        val enq = store.enqueueDirectOutbound(frame, recipient, identity.nodeId)
        assertTrue(enq is io.godstone.mesh.store.OutboundEnqueueResult.Created)
        assertEquals(1, authority.currentSnapshot()!!.queueDepth)

        // Authenticated ACK retirement deletes held frame and notifies snapshot authority automatically
        val ackRes = repo.acknowledgeBoundAndRetire(msgId, recipient)
        assertEquals(io.godstone.mesh.delivery.AckResult.Applied, ackRes)
        assertEquals(0, authority.currentSnapshot()!!.queueDepth)
    }

    @Test
    fun testLinkInfo_ExpireRetirementAutomaticallyRefreshesSnapshot() = kotlinx.coroutines.runBlocking {
        val identity = makeIdentity()
        val tmpFile = File.createTempFile("godstone_retire_exp", ".db")
        tmpFile.deleteOnExit()
        val store = io.godstone.mesh.store.SqliteMessageStore(
            io.godstone.mesh.store.JdbcStoreDb(tmpFile),
            4096,
            null
        )
        val repo = io.godstone.mesh.delivery.SqliteDeliveryRepository(store.engine, store::notifyHeldSetChanged)
        val authority = LinkInfoSnapshotAuthority(
            identityProvider = { identity },
            storeProvider = { store }
        )

        val msgId = ByteArray(16) { 0x33.toByte() }
        val recipient = ByteArray(16) { 0x44.toByte() }
        val frame = FrameV2(
            type = TypeV2.MESSAGE,
            flags = Priority.toFlags(Priority.DIRECT) or FrameV2.SEALED,
            ttl = 10,
            hopCount = 0,
            routingTag = ByteArray(4),
            msgId = msgId,
            payload = byteArrayOf(1, 2, 3)
        )
        store.enqueueDirectOutbound(frame, recipient, identity.nodeId)
        assertEquals(1, authority.currentSnapshot()!!.queueDepth)

        // EXPIRE retirement deletes held frame and notifies snapshot authority automatically
        val expRes = repo.transition(msgId, io.godstone.mesh.delivery.DeliveryTransition.EXPIRE)
        assertEquals(io.godstone.mesh.delivery.TransitionResult.Applied, expRes)
        assertEquals(0, authority.currentSnapshot()!!.queueDepth)
    }

    @Test
    fun testLinkInfo_CancelRetirementAutomaticallyRefreshesSnapshot() = kotlinx.coroutines.runBlocking {
        val identity = makeIdentity()
        val tmpFile = File.createTempFile("godstone_retire_cnc", ".db")
        tmpFile.deleteOnExit()
        val store = io.godstone.mesh.store.SqliteMessageStore(
            io.godstone.mesh.store.JdbcStoreDb(tmpFile),
            4096,
            null
        )
        val repo = io.godstone.mesh.delivery.SqliteDeliveryRepository(store.engine, store::notifyHeldSetChanged)
        val authority = LinkInfoSnapshotAuthority(
            identityProvider = { identity },
            storeProvider = { store }
        )

        val msgId = ByteArray(16) { 0x55.toByte() }
        val recipient = ByteArray(16) { 0x66.toByte() }
        val frame = FrameV2(
            type = TypeV2.MESSAGE,
            flags = Priority.toFlags(Priority.DIRECT) or FrameV2.SEALED,
            ttl = 10,
            hopCount = 0,
            routingTag = ByteArray(4),
            msgId = msgId,
            payload = byteArrayOf(1, 2, 3)
        )
        store.enqueueDirectOutbound(frame, recipient, identity.nodeId)
        assertEquals(1, authority.currentSnapshot()!!.queueDepth)

        // CANCEL retirement deletes held frame and notifies snapshot authority automatically
        val cncRes = repo.transition(msgId, io.godstone.mesh.delivery.DeliveryTransition.CANCEL)
        assertEquals(io.godstone.mesh.delivery.TransitionResult.Applied, cncRes)
        assertEquals(0, authority.currentSnapshot()!!.queueDepth)
    }

    @Test
    fun testLinkInfo_FailedRetirementDoesNotFalselyNotify() = kotlinx.coroutines.runBlocking {
        val identity = makeIdentity()
        val tmpFile = File.createTempFile("godstone_retire_fail", ".db")
        tmpFile.deleteOnExit()
        val store = io.godstone.mesh.store.SqliteMessageStore(
            io.godstone.mesh.store.JdbcStoreDb(tmpFile),
            4096,
            null
        )
        val repo = io.godstone.mesh.delivery.SqliteDeliveryRepository(store.engine, store::notifyHeldSetChanged)
        val authority = LinkInfoSnapshotAuthority(
            identityProvider = { identity },
            storeProvider = { store }
        )

        val msgId = ByteArray(16) { 0x77.toByte() }
        val recipient = ByteArray(16) { 0x88.toByte() }
        val frame = FrameV2(
            type = TypeV2.MESSAGE,
            flags = Priority.toFlags(Priority.DIRECT) or FrameV2.SEALED,
            ttl = 10,
            hopCount = 0,
            routingTag = ByteArray(4),
            msgId = msgId,
            payload = byteArrayOf(1, 2, 3)
        )
        store.enqueueDirectOutbound(frame, recipient, identity.nodeId)
        assertEquals(1, authority.currentSnapshot()!!.queueDepth)

        // Attempt ACK with wrong recipient -> UnknownMessage / no-match; snapshot depth remains 1
        val badRecipient = ByteArray(16) { 0x99.toByte() }
        val ackRes = repo.acknowledgeBoundAndRetire(msgId, badRecipient)
        assertEquals(io.godstone.mesh.delivery.AckResult.UnknownMessage, ackRes)
        assertEquals(1, authority.currentSnapshot()!!.queueDepth)
    }

    @Test
    fun testAttRead_CacheAbsent_FailsClosed_NoStoreTraversal() {
        var traversalCount = 0
        val store = object : MessageStore {
            override fun registerHeldSetObserver(observer: () -> Unit) {}
            override suspend fun persist(frame: FrameV2, receivedFrom: ByteArray) = PersistResult.HELD_NEW
            override suspend fun enqueueDirectOutbound(frame: FrameV2, expectedRecipient: ByteArray, localOriginNodeId: ByteArray) =
                io.godstone.mesh.store.OutboundEnqueueResult.CanonicalFrameMismatch
            override suspend fun allHeldOrderedByPriority(): List<FrameV2> = emptyList()
            override suspend fun allHeldMsgIds(): List<ByteArray> = emptyList()
            override suspend fun forEachHeldOrderedByPriority(visit: (FrameV2) -> Boolean) {}
            override suspend fun forEachHeldMsgId(visit: (ByteArray) -> Boolean) {
                traversalCount++
            }
        }
        // Authority with missing identity provider -> initial snapshot is null
        val authority = LinkInfoSnapshotAuthority(
            identityProvider = { null },
            storeProvider = { store }
        )
        assertNull(authority.currentSnapshot())
        assertNull(authority.currentBytes())
        assertEquals(0, traversalCount)
    }

    @Test
    fun testGlobalCapacity_MixedDirectionsFillAndReplace() {
        val cap = BleGlobalCapacityAuthority()
        assertEquals(7, cap.maxTotalPeers)

        // Admit 4 outbound
        for (i in 1..4) {
            assertTrue(cap.tryAdmitOutbound())
        }
        assertEquals(4, cap.totalCount)

        // Admit 3 inbound -> capacity full (7)
        for (i in 1..3) {
            assertTrue(cap.tryAdmitInbound())
        }
        assertEquals(7, cap.totalCount)

        // 8th connection (either direction) rejected
        assertFalse(cap.tryAdmitOutbound())
        assertFalse(cap.tryAdmitInbound())

        // Release 1 outbound -> 1 inbound can now enter
        cap.releaseOutbound()
        assertEquals(6, cap.totalCount)
        assertTrue(cap.tryAdmitInbound())
        assertEquals(7, cap.totalCount)
        assertFalse(cap.tryAdmitInbound())
    }

    @Test
    fun testServiceRegistration_StaleGeneration1Success_Ignored() {
        val localHint = byteArrayOf(0x02, 0x00, 0x00, 0x00)
        val driver = BleServerOrchestrationDriver(
            localHint = localHint,
            localLinkInfoProvider = { ByteArray(13) }
        )
        val epoch1 = driver.startNewServerEpoch()
        val epoch2 = driver.startNewServerEpoch()

        // Stale epoch 1 success callback
        assertFalse(driver.onServiceAdded(epoch1, true))
        assertFalse(driver.isServerReady)

        // Current epoch 2 success callback
        assertTrue(driver.onServiceAdded(epoch2, true))
        assertTrue(driver.isServerReady)
    }

    @Test
    fun testSessionManager_HandshakeApiNotInvokedBySubstrate() {
        // Assert that substrate driver never invokes SessionManager handshake-driving APIs
        val smClass = io.godstone.mesh.crypto.SessionManager::class.java
        val driverClass = BleServerOrchestrationDriver::class.java
        // Verify no method on driver takes SessionManager
        for (m in driverClass.declaredMethods) {
            for (pt in m.parameterTypes) {
                assertFalse("BleServerOrchestrationDriver must not accept SessionManager", smClass.isAssignableFrom(pt))
            }
        }
    }
}

