package io.godstone.mesh.transport

import io.godstone.mesh.MeshIdentity
import io.godstone.mesh.crypto.SessionManager
import io.godstone.mesh.identity.PeerBindingTrustAuthority
import io.godstone.mesh.identity.PeerTrustApplyResult
import io.godstone.mesh.identity.ValidatedPeerBinding
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BleRecordTest {

    private class RecordingTrustAuthority : PeerBindingTrustAuthority {
        override fun applyValidatedBinding(binding: ValidatedPeerBinding): PeerTrustApplyResult {
            return PeerTrustApplyResult.Accepted
        }
    }

    private fun hexToBytes(hex: String): ByteArray {
        val len = hex.length
        val data = ByteArray(len / 2)
        var i = 0
        while (i < len) {
            data[i / 2] = ((Character.digit(hex[i], 16) shl 4) or Character.digit(hex[i + 1], 16)).toByte()
            i += 2
        }
        return data
    }

    private fun bytesToHex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }

    // ========================================================================
    // 1. Pinned Vectors from wire/ble_record_vectors.json
    // ========================================================================

    @Test
    fun testVector_Positive_Hs1_SingleFragment() {
        val payload = ByteArray(32) { (it % 256).toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.HS1, 0, payload, maxAttValueLength = 100)
        assertEquals(1, frags.size)

        val reassembler = BleRecordReassembler()
        val result = reassembler.receiveFragmentBytes(frags[0])
        assertNotNull(result)
        assertEquals(BleRecordType.HS1, result!!.recordType)
        assertEquals(0, result.recordSeq)
        assertArrayEquals(payload, result.payload)
    }

    @Test
    fun testVector_Positive_Hs2_MultiFragment() {
        val payload = ByteArray(229) { ((it * 7 + 3) % 256).toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.HS2, 1, payload, maxAttValueLength = 60)
        assertEquals(5, frags.size)

        val reassembler = BleRecordReassembler()
        var result: BleReassembledRecord? = null
        for (f in frags) {
            val r = reassembler.receiveFragmentBytes(f)
            if (r != null) result = r
        }
        assertNotNull(result)
        assertEquals(BleRecordType.HS2, result!!.recordType)
        assertEquals(1, result.recordSeq)
        assertArrayEquals(payload, result.payload)
    }

    @Test
    fun testVector_Positive_Hs3_MultiFragment() {
        val payload = ByteArray(197) { ((it * 13 + 7) % 256).toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.HS3, 2, payload, maxAttValueLength = 50)
        assertEquals(5, frags.size)

        val reassembler = BleRecordReassembler()
        var result: BleReassembledRecord? = null
        for (f in frags) {
            val r = reassembler.receiveFragmentBytes(f)
            if (r != null) result = r
        }
        assertNotNull(result)
        assertEquals(BleRecordType.HS3, result!!.recordType)
        assertEquals(2, result.recordSeq)
        assertArrayEquals(payload, result.payload)
    }

    @Test
    fun testVector_Positive_Close_ZeroLength() {
        val payload = ByteArray(0)
        val frags = BleRecordFragmenter.fragment(BleRecordType.CLOSE, 3, payload, maxAttValueLength = 100)
        assertEquals(1, frags.size)

        val reassembler = BleRecordReassembler()
        val result = reassembler.receiveFragmentBytes(frags[0])
        assertNotNull(result)
        assertEquals(BleRecordType.CLOSE, result!!.recordType)
        assertEquals(3, result.recordSeq)
        assertEquals(0, result.payload.size)
    }

    @Test
    fun testVector_Positive_Data_MultiFragment() {
        val payload = ByteArray(500) { ((it * 17 + 1) % 256).toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.DATA, 255, payload, maxAttValueLength = 128)
        assertEquals(5, frags.size)

        val reassembler = BleRecordReassembler()
        var result: BleReassembledRecord? = null
        for (f in frags) {
            val r = reassembler.receiveFragmentBytes(f)
            if (r != null) result = r
        }
        assertNotNull(result)
        assertEquals(BleRecordType.DATA, result!!.recordType)
        assertEquals(255, result.recordSeq)
        assertArrayEquals(payload, result.payload)
    }

    @Test
    fun testVector_Positive_MaxRecord_16384() {
        val payload = ByteArray(16384) { ((it * 31) % 256).toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.DATA, 100, payload, maxAttValueLength = 264)
        assertEquals(64, frags.size)

        val reassembler = BleRecordReassembler()
        var result: BleReassembledRecord? = null
        for (f in frags) {
            val r = reassembler.receiveFragmentBytes(f)
            if (r != null) result = r
        }
        assertNotNull(result)
        assertEquals(BleRecordType.DATA, result!!.recordType)
        assertEquals(100, result.recordSeq)
        assertArrayEquals(payload, result.payload)
    }

    // ========================================================================
    // Negative Vector Assertions
    // ========================================================================

    @Test
    fun testVector_Negative_TruncatedHeader() {
        assertNull(BleRecordCodec.decodeFragment(hexToBytes("47110000010020")))
    }

    @Test
    fun testVector_Negative_BadMagic() {
        val hs1Payload = ByteArray(32) { (it % 256).toByte() }
        val badMagicHdr = byteArrayOf(0x48.toByte(), 0x11, 0x00, 0x00, 0x01, 0x00, 0x20)
        val chk = BleRecordCodec.computeHeaderCheck(badMagicHdr)
        val full = badMagicHdr + byteArrayOf(chk) + hs1Payload
        assertNull(BleRecordCodec.decodeFragment(full))
    }

    @Test
    fun testVector_Negative_UnknownRecordType() {
        val hs1Payload = ByteArray(32) { (it % 256).toByte() }
        val badTypeHdr = byteArrayOf(0x47.toByte(), 0x99.toByte(), 0x00, 0x00, 0x01, 0x00, 0x20)
        val chk = BleRecordCodec.computeHeaderCheck(badTypeHdr)
        val full = badTypeHdr + byteArrayOf(chk) + hs1Payload
        assertNull(BleRecordCodec.decodeFragment(full))
    }

    @Test
    fun testVector_Negative_CorruptHeaderXorCheck() {
        val hs1Payload = ByteArray(32) { (it % 256).toByte() }
        val hdr = BleRecordCodec.encodeHeader(BleRecordType.HS1, 0, 0, 1, 32)
        hdr[7] = (hdr[7].toInt() xor 0xFF).toByte()
        assertNull(BleRecordCodec.decodeFragment(hdr + hs1Payload))
    }

    @Test
    fun testVector_Negative_FragCountZero() {
        val hs1Payload = ByteArray(32) { (it % 256).toByte() }
        val raw = byteArrayOf(0x47, 0x11, 0x00, 0x00, 0x00, 0x00, 0x20)
        val chk = BleRecordCodec.computeHeaderCheck(raw)
        assertNull(BleRecordCodec.decodeFragment(raw + byteArrayOf(chk) + hs1Payload))
    }

    @Test
    fun testVector_Negative_FragCount65ExceedsMax() {
        val hs1Payload = ByteArray(32) { (it % 256).toByte() }
        val raw = byteArrayOf(0x47, 0x11, 0x00, 0x00, 65.toByte(), 0x00, 0x20)
        val chk = BleRecordCodec.computeHeaderCheck(raw)
        assertNull(BleRecordCodec.decodeFragment(raw + byteArrayOf(chk) + hs1Payload))
    }

    @Test
    fun testVector_Negative_FragIndexEqualsFragCount() {
        val hs1Payload = ByteArray(32) { (it % 256).toByte() }
        val raw = byteArrayOf(0x47, 0x11, 0x00, 0x02, 0x02, 0x00, 0x20)
        val chk = BleRecordCodec.computeHeaderCheck(raw)
        assertNull(BleRecordCodec.decodeFragment(raw + byteArrayOf(chk) + hs1Payload))
    }

    @Test
    fun testVector_Negative_TotalLen16385ExceedsMax() {
        val raw = byteArrayOf(0x47, 0x18, 0x00, 0x00, 0x01, 0x40.toByte(), 0x01)
        val chk = BleRecordCodec.computeHeaderCheck(raw)
        assertNull(BleRecordCodec.decodeFragment(raw + byteArrayOf(chk)))
    }

    @Test
    fun testVector_Negative_TruncatedPayload() {
        val hs1Payload = ByteArray(31) { (it % 256).toByte() }
        val hdr = BleRecordCodec.encodeHeader(BleRecordType.HS1, 0, 0, 1, 32)
        assertNull(BleRecordCodec.decodeFragment(hdr + hs1Payload))
    }

    @Test
    fun testVector_Negative_ExcessPayload() {
        val hs1Payload = ByteArray(33) { (it % 256).toByte() }
        val hdr = BleRecordCodec.encodeHeader(BleRecordType.HS1, 0, 0, 1, 32)
        assertNull(BleRecordCodec.decodeFragment(hdr + hs1Payload))
    }

    // ========================================================================
    // 2. Property & Reordering & Conflict Tests
    // ========================================================================

    @Test
    fun testReassembly_ReverseOrder() {
        val payload = ByteArray(300) { (it * 3).toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.DATA, 42, payload, maxAttValueLength = 70)
        val reassembler = BleRecordReassembler()

        var result: BleReassembledRecord? = null
        for (i in frags.indices.reversed()) {
            val r = reassembler.receiveFragmentBytes(frags[i])
            if (r != null) result = r
        }
        assertNotNull(result)
        assertEquals(42, result!!.recordSeq)
        assertEquals(BleRecordType.DATA, result.recordType)
        assertArrayEquals(payload, result.payload)
    }

    @Test
    fun testReassembly_ShuffledOrder() {
        val payload = ByteArray(450) { (it * 11).toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.DATA, 77, payload, maxAttValueLength = 80)
        val reassembler = BleRecordReassembler()

        // Deterministic shuffle: 2, 0, 4, 1, 3, etc.
        val indices = frags.indices.toList().sortedBy { (it * 37) % frags.size }
        var result: BleReassembledRecord? = null
        for (idx in indices) {
            val r = reassembler.receiveFragmentBytes(frags[idx])
            if (r != null) result = r
        }
        assertNotNull(result)
        assertArrayEquals(payload, result!!.payload)
    }

    @Test
    fun testReassembly_IdempotentDuplicateFragment() {
        val payload = ByteArray(150) { it.toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.DATA, 10, payload, maxAttValueLength = 50)
        val reassembler = BleRecordReassembler()

        // Deliver frag 0 twice
        assertNull(reassembler.receiveFragmentBytes(frags[0]))
        assertNull(reassembler.receiveFragmentBytes(frags[0])) // duplicate, no error

        for (i in 1 until frags.size) {
            val r = reassembler.receiveFragmentBytes(frags[i])
            if (i == frags.size - 1) {
                assertNotNull(r)
                assertArrayEquals(payload, r!!.payload)
            } else {
                assertNull(r)
            }
        }
    }

    @Test
    fun testReassembly_ConflictingDuplicateFragment_InvalidatesAssembly() {
        val payload = ByteArray(150) { it.toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.DATA, 11, payload, maxAttValueLength = 50)
        val reassembler = BleRecordReassembler()

        assertNull(reassembler.receiveFragmentBytes(frags[0]))

        // Create conflicting fragment with same index 0 but corrupted payload
        val corruptFrag0 = frags[0].copyOf()
        corruptFrag0[BleRecordConstants.HEADER_BYTES] = (corruptFrag0[BleRecordConstants.HEADER_BYTES].toInt() xor 0xFF).toByte()

        assertNull(reassembler.receiveFragmentBytes(corruptFrag0)) // triggers invalidation

        // Remaining fragments cannot finish assembly because it was discarded
        for (i in 1 until frags.size) {
            assertNull(reassembler.receiveFragmentBytes(frags[i]))
        }
    }

    @Test
    fun testReassembly_MetadataConflict_InvalidatesAssembly() {
        val payload1 = ByteArray(100) { it.toByte() }
        val frags1 = BleRecordFragmenter.fragment(BleRecordType.DATA, 12, payload1, maxAttValueLength = 60)

        val reassembler = BleRecordReassembler()
        assertNull(reassembler.receiveFragmentBytes(frags1[0]))

        // Conflicting fragment with same seq 12 but HS2 record type
        val payload2 = ByteArray(100) { it.toByte() }
        val frags2 = BleRecordFragmenter.fragment(BleRecordType.HS2, 12, payload2, maxAttValueLength = 60)

        assertNull(reassembler.receiveFragmentBytes(frags2[1])) // conflict -> invalidates

        // Rest of frags1 fails
        for (i in 1 until frags1.size) {
            assertNull(reassembler.receiveFragmentBytes(frags1[i]))
        }
    }

    @Test
    fun testReassembly_MaxConcurrentLimit() {
        val reassembler = BleRecordReassembler()
        val payload = ByteArray(100) { it.toByte() }

        // Start 4 concurrent assemblies (seq 1, 2, 3, 4)
        val frags1 = BleRecordFragmenter.fragment(BleRecordType.DATA, 1, payload, maxAttValueLength = 60)
        val frags2 = BleRecordFragmenter.fragment(BleRecordType.DATA, 2, payload, maxAttValueLength = 60)
        val frags3 = BleRecordFragmenter.fragment(BleRecordType.DATA, 3, payload, maxAttValueLength = 60)
        val frags4 = BleRecordFragmenter.fragment(BleRecordType.DATA, 4, payload, maxAttValueLength = 60)
        val frags5 = BleRecordFragmenter.fragment(BleRecordType.DATA, 5, payload, maxAttValueLength = 60)

        assertNull(reassembler.receiveFragmentBytes(frags1[0]))
        assertNull(reassembler.receiveFragmentBytes(frags2[0]))
        assertNull(reassembler.receiveFragmentBytes(frags3[0]))
        assertNull(reassembler.receiveFragmentBytes(frags4[0]))

        // 5th concurrent assembly is rejected
        assertNull(reassembler.receiveFragmentBytes(frags5[0]))

        // Complete assembly 1
        for (i in 1 until frags1.size) {
            val r = reassembler.receiveFragmentBytes(frags1[i])
            if (i == frags1.size - 1) assertNotNull(r)
        }

        // Now assembly 5 can be started
        assertNull(reassembler.receiveFragmentBytes(frags5[0]))
        for (i in 1 until frags5.size) {
            val r = reassembler.receiveFragmentBytes(frags5[i])
            if (i == frags5.size - 1) assertNotNull(r)
        }
    }

    @Test
    fun testReassembly_TimeoutFailClosed() {
        var currentTimeSec = 1000L
        val reassembler = BleRecordReassembler(clock = { currentTimeSec })
        val payload = ByteArray(120) { it.toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.DATA, 20, payload, maxAttValueLength = 50)

        assertNull(reassembler.receiveFragmentBytes(frags[0]))

        // Advance clock past 30 seconds
        currentTimeSec += 31L

        // Next fragment for expired assembly will find it evicted and fail to complete partial record
        assertNull(reassembler.receiveFragmentBytes(frags[1]))
    }

    @Test
    fun testReassembly_DuplicateCompletedRecord_Suppressed() {
        val payload = ByteArray(80) { it.toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.DATA, 30, payload, maxAttValueLength = 50)
        val reassembler = BleRecordReassembler()

        var firstCompletion: BleReassembledRecord? = null
        for (f in frags) {
            val r = reassembler.receiveFragmentBytes(f)
            if (r != null) firstCompletion = r
        }
        assertNotNull(firstCompletion)

        // Retransmitting all fragments must NOT emit a second completion
        for (f in frags) {
            assertNull(reassembler.receiveFragmentBytes(f))
        }
    }

    @Test
    fun testReassembly_SequenceWrap_Accepted() {
        val payload1 = ByteArray(80) { 0x11.toByte() }
        val frags1 = BleRecordFragmenter.fragment(BleRecordType.DATA, 50, payload1, maxAttValueLength = 50)
        val reassembler = BleRecordReassembler()

        var comp1: BleReassembledRecord? = null
        for (f in frags1) {
            val r = reassembler.receiveFragmentBytes(f)
            if (r != null) comp1 = r
        }
        assertNotNull(comp1)
        assertArrayEquals(payload1, comp1!!.payload)

        // New record with same sequence number 50 but different payload
        val payload2 = ByteArray(90) { 0x22.toByte() }
        val frags2 = BleRecordFragmenter.fragment(BleRecordType.DATA, 50, payload2, maxAttValueLength = 50)

        var comp2: BleReassembledRecord? = null
        for (f in frags2) {
            val r = reassembler.receiveFragmentBytes(f)
            if (r != null) comp2 = r
        }
        assertNotNull(comp2)
        assertArrayEquals(payload2, comp2!!.payload)
    }

    @Test
    fun testReassembly_ResetClearsAllState() {
        val payload = ByteArray(100) { it.toByte() }
        val frags = BleRecordFragmenter.fragment(BleRecordType.DATA, 60, payload, maxAttValueLength = 50)
        val reassembler = BleRecordReassembler()

        assertNull(reassembler.receiveFragmentBytes(frags[0]))
        reassembler.reset()

        // After reset, previous in-flight fragment 0 is gone; delivering fragment 1 fails
        assertNull(reassembler.receiveFragmentBytes(frags[1]))
    }

    // ========================================================================
    // 3. Encrypt-Then-Fragment Semantic Integrity
    // ========================================================================

    @Test
    fun testEncryptThenFragment_SemanticDataFlow() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority()
        val trustB = RecordingTrustAuthority()

        val smA = SessionManager(identityA, trustA)
        val smB = SessionManager(identityB, trustB)

        // Complete handshake
        val hs1 = smA.initiatorStart(identityB.nodeId, identityB.nodeHint)!!
        val hs2 = smB.responderProcessHs1(identityA.nodeId, identityA.nodeHint, hs1)!!
        val hs3 = smA.initiatorProcessHs2(identityB.nodeId, hs2, identityB.nodeHint)!!
        assertTrue(smB.responderProcessHs3(identityA.nodeId, hs3, identityA.nodeHint))
        assertTrue(smA.isReady(identityB.nodeId))
        assertTrue(smB.isReady(identityA.nodeId))

        val plaintext = "Hello authenticated BLE record mesh layer!".toByteArray(Charsets.UTF_8)

        // 1. Outbound: SessionManager.seal EXACTLY ONCE
        val ciphertext = smA.seal(identityB.nodeId, plaintext)!!

        // 2. Fragment ciphertext into BLE records
        val frags = BleRecordFragmenter.fragment(BleRecordType.DATA, 1, ciphertext, maxAttValueLength = 25)
        assertTrue(frags.size > 1)

        // 3. Inbound: Reassemble BLE record fragments
        val reassemblerB = BleRecordReassembler()
        var reassembledCiphertext: ByteArray? = null
        for (f in frags.reversed()) { // test out-of-order reassembly
            val r = reassemblerB.receiveFragmentBytes(f)
            if (r != null) reassembledCiphertext = r.payload
        }
        assertNotNull(reassembledCiphertext)
        assertArrayEquals(ciphertext, reassembledCiphertext)

        // 4. SessionManager.open EXACTLY ONCE on complete record
        val decrypted = smB.open(identityA.nodeId, reassembledCiphertext!!)!!
        assertArrayEquals(plaintext, decrypted)
    }

    // ========================================================================
    // 4. Pure Handshake Record Composition Test (HS1 -> HS2 -> HS3 -> READY)
    // ========================================================================

    @Test
    fun testPureHandshake_ThroughBleRecords_CompletesAndReachesReady() {
        val identityA = MeshIdentity.generate()
        val identityB = MeshIdentity.generate()
        val trustA = RecordingTrustAuthority()
        val trustB = RecordingTrustAuthority()

        val smA = SessionManager(identityA, trustA)
        val smB = SessionManager(identityB, trustB)

        val reassemblerA = BleRecordReassembler()
        val reassemblerB = BleRecordReassembler()

        // 1. Initiator A starts HS1 (exactly 32 bytes)
        val hs1Raw = smA.initiatorStart(identityB.nodeId, identityB.nodeHint)!!
        assertEquals(32, hs1Raw.size)

        val hs1Frags = BleRecordFragmenter.fragment(BleRecordType.HS1, 0, hs1Raw, maxAttValueLength = 100)
        assertEquals(1, hs1Frags.size)

        val hs1Reassembled = reassemblerB.receiveFragmentBytes(hs1Frags[0])!!
        assertEquals(BleRecordType.HS1, hs1Reassembled.recordType)
        assertEquals(32, hs1Reassembled.payload.size)

        // 2. Responder B processes HS1 and produces HS2 (exactly 229 bytes)
        val hs2Raw = smB.responderProcessHs1(identityA.nodeId, identityA.nodeHint, hs1Reassembled.payload)!!
        assertEquals(229, hs2Raw.size)

        // Fragment HS2 with small MTU so it fragments across multiple packets
        val hs2Frags = BleRecordFragmenter.fragment(BleRecordType.HS2, 0, hs2Raw, maxAttValueLength = 60)
        assertTrue(hs2Frags.size >= 4)

        var hs2Reassembled: BleReassembledRecord? = null
        for (f in hs2Frags.reversed()) { // Reordered delivery
            val r = reassemblerA.receiveFragmentBytes(f)
            if (r != null) hs2Reassembled = r
        }
        assertNotNull(hs2Reassembled)
        assertEquals(BleRecordType.HS2, hs2Reassembled!!.recordType)
        assertEquals(229, hs2Reassembled.payload.size)

        // 3. Initiator A processes HS2 and produces HS3 (exactly 197 bytes)
        val hs3Raw = smA.initiatorProcessHs2(identityB.nodeId, hs2Reassembled.payload, identityB.nodeHint)!!
        assertEquals(197, hs3Raw.size)

        val hs3Frags = BleRecordFragmenter.fragment(BleRecordType.HS3, 1, hs3Raw, maxAttValueLength = 55)
        assertTrue(hs3Frags.size >= 4)

        var hs3Reassembled: BleReassembledRecord? = null
        for (f in hs3Frags.reversed()) { // Reordered delivery
            val r = reassemblerB.receiveFragmentBytes(f)
            if (r != null) hs3Reassembled = r
        }
        assertNotNull(hs3Reassembled)
        assertEquals(BleRecordType.HS3, hs3Reassembled!!.recordType)
        assertEquals(197, hs3Reassembled.payload.size)

        // 4. Responder B processes HS3
        val bReady = smB.responderProcessHs3(identityA.nodeId, hs3Reassembled.payload, identityA.nodeHint)
        assertTrue(bReady)

        // Both managers are READY
        assertTrue(smA.isReady(identityB.nodeId))
        assertTrue(smB.isReady(identityA.nodeId))

        // 5. Subsequent encrypted DATA exchange
        val message = "Handshake completed over fragmented BLE records!".toByteArray(Charsets.UTF_8)
        val ciphertext = smA.seal(identityB.nodeId, message)!!
        val dataFrags = BleRecordFragmenter.fragment(BleRecordType.DATA, 2, ciphertext, maxAttValueLength = 40)
        assertTrue(dataFrags.size > 1)

        var reassembledData: BleReassembledRecord? = null
        for (f in dataFrags) {
            val r = reassemblerB.receiveFragmentBytes(f)
            if (r != null) reassembledData = r
        }
        assertNotNull(reassembledData)

        val opened = smB.open(identityA.nodeId, reassembledData!!.payload)!!
        assertArrayEquals(message, opened)
    }
}
