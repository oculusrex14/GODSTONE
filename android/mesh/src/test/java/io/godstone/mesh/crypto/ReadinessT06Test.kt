package io.godstone.mesh.crypto

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.identity.Identity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets

/**
 * T06: unify Swift DATA nonce framing with Android.
 *
 * Wire contract under test: DATA ciphertext = uint64_be(nonce) || ChaChaPoly
 * ciphertext || tag, with the internal ChaCha nonce staying
 * zero32 || uint64_le(n). This suite exports the REAL Android engine's
 * transport vectors (fixed keys, deterministic bytes) into
 * wire/transport_vectors_android.json and verifies the Swift engine's vectors
 * cross-engine through the live Android session.
 */
class ReadinessT06Test {

    private val edPrivI = ByteArray(32) { 0xA3.toByte() }
    private val dhPrivI = ByteArray(32) { 0xA1.toByte() }
    private val edPrivR = ByteArray(32) { 0xB3.toByte() }
    private val dhPrivR = ByteArray(32) { 0xB1.toByte() }
    private val hintI = byteArrayOf(0x11, 0x11, 0x11, 0x11)
    private val hintR = byteArrayOf(0x22, 0x22, 0x22, 0x22)
    private val plaintexts = listOf(
        ByteArray(0), "transport-one".toByteArray(),
        "transport-two".toByteArray(), ByteArray(0),
    )

    private fun fixedIdentity(dhPriv: ByteArray, edPriv: ByteArray): Identity =
        Identity.fromKeyMaterial(
            Ed25519Keys.publicKeyFromPrivate(edPriv), edPriv,
            X25519Keys.publicKeyFromPrivate(dhPriv), dhPriv)

    private fun establishPair(): Pair<NoiseSession, NoiseSession> {
        val initiator = NoiseSession.initiator(
            fixedIdentity(dhPrivI, edPrivI), hintI, hintR)
        val responder = NoiseSession.responder(
            fixedIdentity(dhPrivR, edPrivR), hintI, hintR)
        responder.readHandshakeMessage(initiator.writeHandshakeMessage())
        initiator.readHandshakeMessage(responder.writeHandshakeMessage())
        responder.readHandshakeMessage(initiator.writeHandshakeMessage())
        assertTrue(initiator.isEstablished)
        assertTrue(responder.isEstablished)
        return initiator to responder
    }

    private fun hex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }

    private fun unhex(text: String): ByteArray =
        ByteArray(text.length / 2) { i ->
            ((Character.digit(text[i * 2], 16) shl 4) +
                Character.digit(text[i * 2 + 1], 16)).toByte()
        }

    private fun wireFile(name: String): File {
        // The Gradle test JVM cwd may be android/ or android/mesh; walk
        // upward until the repository-root wire/ directory is found.
        var dir = File(System.getProperty("user.dir"))
        repeat(4) {
            val wire = File(dir, "wire")
            if (wire.isDirectory) return File(wire, name)
            dir = dir.parentFile ?: return@repeat
        }
        throw AssertionError("wire directory not found above " +
            System.getProperty("user.dir"))
    }

    private val fixtureKey = ByteArray(32) { 0x5A.toByte() }

    @Test
    fun testExportAndroidTransportVectors() {
        val sender = NoiseSession.senderForTest(fixtureKey,
            fixedIdentity(dhPrivI, edPrivI))
        assertTrue(sender.isEstablished)
        val steps = StringBuilder()
        for ((index, plaintext) in plaintexts.withIndex()) {
            val sealed = sender.encrypt(plaintext)
            val decoded = TransportCiphertextV1.decode(sealed)
            assertNotNull("frame $index must carry the nonce prefix",
                decoded)
            assertEquals("wire nonce must be the explicit BE prefix",
                index.toLong(), decoded!!.first)
            val receiver = NoiseSession.receiverForTest(fixtureKey,
                fixedIdentity(dhPrivR, edPrivR))
            val opened = receiver.decrypt(sealed)
            assertTrue(opened.contentEquals(plaintext))
            if (index > 0) steps.append(",\n")
            steps.append("    {\n")
            steps.append("      \"ciphertext_hex\": \"")
                .append(hex(sealed)).append("\",\n")
            steps.append("      \"nonce_u64\": ").append(index)
                .append(",\n")
            steps.append("      \"plaintext_hex\": \"")
                .append(hex(plaintext)).append("\"\n")
            steps.append("    }")
        }
        val json = StringBuilder()
        json.append("{\n")
        json.append("  \"origin_engine\": \"android\",\n")
        json.append("  \"schema_version\": 1,\n")
        json.append("  \"suite\": \"Noise_XX_25519_ChaChaPoly_BLAKE2s\",\n")
        json.append("  \"transport\": [\n")
        json.append(steps)
        json.append("\n  ],\n")
        json.append("  \"transport_key_hex\": \"")
            .append(hex(fixtureKey)).append("\"\n")
        json.append("}\n")
        val target = wireFile("transport_vectors_android.json")
        target.writeText(json.toString(), StandardCharsets.UTF_8)
        assertTrue(target.length() > 0)
    }

    @Test
    fun testAndroidEngineVerifiesSwiftTransportVectors() {
        val source = wireFile("transport_vectors_swift.json").readText()
        assertTrue("must verify the other engine's vectors",
            Regex("\"origin_engine\"\\s*:\\s*\"swift\"")
                .containsMatchIn(source))
        val keyLine = Regex("\"transport_key_hex\"\\s*:\\s*\"([0-9a-f]+)\"")
            .find(source)!!
        assertEquals("fixture transport key must match the shared constant",
            hex(fixtureKey), keyLine.groupValues[1])
        val receiver = NoiseSession.receiverForTest(
            unhex(keyLine.groupValues[1]),
            fixedIdentity(dhPrivR, edPrivR))
        val ciphertextPattern =
            Regex("\"ciphertext_hex\"\\s*:\\s*\"([0-9a-f]+)\"")
        val plaintextPattern =
            Regex("\"plaintext_hex\"\\s*:\\s*\"([0-9a-f]*)\"")
        val ciphertexts = ciphertextPattern.findAll(source)
            .map { it.groupValues[1] }.toList()
        val plaintextHexes = plaintextPattern.findAll(source)
            .map { it.groupValues[1] }.toList()
        assertTrue(ciphertexts.size >= 4)
        for ((index, ciphertextHex) in ciphertexts.withIndex()) {
            val opened = receiver.decrypt(unhex(ciphertextHex))
            assertEquals(plaintextHexes[index], hex(opened))
        }
        // A replay of the last committed vector must be expired.
        val outcome = receiver.openWithResult(unhex(ciphertexts.last()))
        assertTrue(outcome is NoiseSession.CryptoOpenResult.Expired)
    }

    @Test
    fun testLegacyImplicitCounterCiphertextIsNeverAutoDetected() {
        val (initiator, responder) = establishPair()
        responder.decrypt(initiator.encrypt("seed".toByteArray()))
        // Legacy shape: a REAL sealed box with the uint64_be prefix STRIPPED -
        // exactly the pre-T06 implicit-counter wire bytes.
        val sealed = initiator.encrypt("legacy-shape".toByteArray())
        val legacy = TransportCiphertextV1.decode(sealed)!!.second
        // Never auto-detect: the first 8 bytes are parsed as a nonce, so the
        // AEAD opens against the wrong material and must not authenticate.
        val outcome = responder.openWithResult(legacy)
        assertFalse(outcome is NoiseSession.CryptoOpenResult.Authenticated)
    }

    @Test
    fun testForgedInPolicyNonceCommitsNothing() {
        val (initiator, responder) = establishPair()
        for (n in plaintexts.indices) {
            assertTrue(responder.openWithResult(initiator.encrypt(plaintexts[n]))
                is NoiseSession.CryptoOpenResult.Authenticated)
        }
        // A forged in-policy nonce never legitimately sent: AEAD fails and
        // the window commits nothing.
        val forged = TransportCiphertextV1.encode(
            UnsignedNonce.POLICY_CEILING, ByteArray(16))
        assertTrue(responder.openWithResult(forged)
            is NoiseSession.CryptoOpenResult.Rejected)
        // The real next frame still authenticates.
        assertTrue(responder.openWithResult(initiator.encrypt("five".toByteArray()))
            is NoiseSession.CryptoOpenResult.Authenticated)
    }

    @Test
    fun testEmptyPlaintextAuthenticates() {
        val (initiator, responder) = establishPair()
        val outcome = responder.openWithResult(
            initiator.encrypt(ByteArray(0)))
        assertTrue(outcome is NoiseSession.CryptoOpenResult.Authenticated)
        assertEquals(0, (outcome as NoiseSession.CryptoOpenResult.Authenticated)
            .plaintext.size)
    }

    @Test
    fun testInvalidFrameV2RejectedSeparatelyFromSessionRejection() {
        val (initiator, responder) = establishPair()
        // Wire-layer rejection: an invalid FrameV2 fails at decode, not AEAD.
        assertNull(io.godstone.mesh.wire.v2.FrameV2.decode(ByteArray(8)))
        // Session-layer rejection: a too-short transport frame is Rejected.
        assertTrue(responder.openWithResult(ByteArray(4))
            is NoiseSession.CryptoOpenResult.Rejected)
        // And the collector keeps going: the next real frame authenticates.
        assertTrue(responder.openWithResult(initiator.encrypt("after".toByteArray()))
            is NoiseSession.CryptoOpenResult.Authenticated)
    }

    @Test
    fun testReservedNonceRejectedBeforeSubtraction() {
        val (initiator, responder) = establishPair()
        for (n in plaintexts) {
            responder.decrypt(initiator.encrypt(n))
        }
        // A reserved nonce (unsigned >= 2^63) is Expired before the window
        // math; the window mutates nothing.
        val forged = TransportCiphertextV1.encode(Long.MIN_VALUE, ByteArray(16))
        assertTrue(responder.openWithResult(forged)
            is NoiseSession.CryptoOpenResult.Expired)
        assertTrue(responder.openWithResult(initiator.encrypt("next".toByteArray()))
            is NoiseSession.CryptoOpenResult.Authenticated)
    }

    @Test
    fun testTransportCiphertextV1Roundtrip() {
        val nonce = 0x0102030405060708L
        val payload = ByteArray(20) { it.toByte() }
        val encoded = TransportCiphertextV1.encode(nonce, payload)
        assertEquals(8 + payload.size, encoded.size)
        assertEquals(nonce, ByteBuffer.wrap(encoded).getLong())
        val (decodedNonce, decodedPayload) = TransportCiphertextV1.decode(encoded)!!
        assertEquals(nonce, decodedNonce)
        assertTrue(decodedPayload.contentEquals(payload))
    }
}