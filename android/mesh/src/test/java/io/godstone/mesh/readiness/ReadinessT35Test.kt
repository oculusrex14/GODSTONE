package io.godstone.mesh.readiness

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.KeyPair
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.wire.v2.MessageId
import io.godstone.mesh.wire.v2.Priority
import io.godstone.mesh.wire.v2.SenderVerificationResult
import io.godstone.mesh.wire.v2.SignedMessageV1
import io.godstone.mesh.wire.v2.TimeQuality
import io.godstone.mesh.wire.v2.VerifiedApplicationMessage
import java.security.SecureRandom
import org.junit.Assert
import org.junit.Test

/**
 * T35 readiness court (android isle): SignedMessageV1 authorship binding inside the
 * sealed envelope, exactly as section 15. The outer frame, the 29-byte sealed prefix,
 * the frozen MessageId formula, the PoW/priority policy and every golden vector are
 * read-only authorities exercised here, never rewritten. The cross-platform vector was
 * produced and verified by the foreign raw signer (openssl pkeyutl -rawin), and the
 * JVM signer must reproduce it byte for byte -- the sealed core documents the two
 * signers as byte-identical RFC 8032 operations over the raw message bytes.
 */
public class ReadinessT35Test {

    private companion object {
        // ---- pinned cross-platform vector constants (hex, foreign-signer produced) ----
        val PRV: ByteArray = hex("d09deef5f114172233445566778899aabbccddeeff00112233445566778899aa")
        val PUB: ByteArray = hex("a720fa37a67ee233c29f4c7473852e73e4bd2e90dcf4abbc288b0d7a6b3935dc")
        val NOD: ByteArray = hex("d285a925802330c7d66708b19856a38d")
        val RCP: ByteArray = hex("72656369702d6e6f6465212100000000")   // "recip-node!!"
        val NON: ByteArray = hex("6d6573736167652d6e6f6e6365210000")   // "message-nonce!"
        const val CREAT: Long = 1700000000L
        val BOD: ByteArray = "SignedMessageV1 cross-platform pinned vector!!".toByteArray(Charsets.UTF_8)
        val SPD: ByteArray = hex(
            "01" +
            "a720fa37a67ee233c29f4c7473852e73e4bd2e90dcf4abbc288b0d7a6b3935dc" +
            "72656369702d6e6f6465212100000000" + "01" + "002e" +
            "5369676e65644d65737361676556312063726f73732d706c6174666f726d2070696e6e656420766563746f722121" +
            "172ba189d6c1bd8f7b50e0ce045212ad32afc65e243ed1acd95a8e7328a0b1bf5003a2e65b711464338309ac3fc74df845901ba6680564d9904f2336097d420e")
        val MID: ByteArray = hex("3ec672aca155b2678c7533b46d944156")

        fun hex(s: String): ByteArray = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        fun newPair(rng: SecureRandom): KeyPair = Ed25519Keys.generate(rng)
        fun nodeIdOf(pub: ByteArray): ByteArray = SignedMessageV1.nodeIdOf(pub)
        fun le32(b: ByteArray): Long =
            (b[0].toLong() and 0xFF) or ((b[1].toLong() and 0xFF) shl 8) or ((b[2].toLong() and 0xFF) shl 16) or ((b[3].toLong() and 0xFF) shl 24)
        /** sealed_inner = messageNonce16 || powNonce8 || createdAt_le4 || priorityCode1 || signedPlaintext */
        fun sealInner(nonce: ByteArray, pow: ByteArray, created: Long, prio: Int, sp: ByteArray): ByteArray =
            nonce + pow + MessageId.uint32Le(created) + byteArrayOf(prio.toByte()) + sp
        fun unseal(inner: ByteArray): Triple<ByteArray, Long, Int> =
            Triple(inner.copyOfRange(0, 16), le32(inner.copyOfRange(24, 28)), inner[28].toInt() and 0xFF)
        fun tamper(b: ByteArray, i: Int): ByteArray = b.copyOf().also { it[i] = (it[i].toInt() xor 0x01).toByte() }
        fun honestSign(priv: ByteArray, pub: ByteArray, node: ByteArray, recip: ByteArray,
                       nonce: ByteArray, created: Long, body: ByteArray): ByteArray =
            SignedMessageV1.author(priv, pub, node, recip, nonce, created, Priority.DIRECT, TimeQuality.USER_CONFIRMED, body)
    }

    // (1) known-recipient-key impersonation: possession identifies a key, not a person
    @Test
    fun testKnownRecipientKeyImpersonationIsRejected() {
        val rng = SecureRandom()
        val victim = newPair(rng); val victimNode = nodeIdOf(victim.pub)
        val carol = newPair(rng)
        // Carol knows the victim's public key and node id (both public); she authors with HER OWN
        // key yet claims the victim's node id -- the id/key binding must catch the impersonation.
        val forged = SignedMessageV1.author(carol.priv, carol.pub, victimNode, RCP, NON, CREAT,
            Priority.DIRECT, TimeQuality.USER_CONFIRMED, BOD)
        val r = SignedMessageV1.verify(forged, victimNode, RCP, NON, CREAT, Priority.DIRECT.code)
        Assert.assertTrue("a stranger cannot sign as the victim: the id/key binding rejects it",
            r is SenderVerificationResult.Invalid && (r as SenderVerificationResult.Invalid).reason.contains("BLAKE2s128"))
        // an honest message under the victim's own key verifies -- the rejection is not blanket
        val honest = honestSign(victim.priv, victim.pub, victimNode, RCP, NON, CREAT, BOD)
        val ok = SignedMessageV1.verify(honest, victimNode, RCP, NON, CREAT, Priority.DIRECT.code)
        Assert.assertTrue("the genuine author still verifies", ok is SenderVerificationResult.Verified)
        // tampering the embedded public key inside a genuine frame breaks the binding (checked before signature)
        val r2 = SignedMessageV1.verify(tamper(honest, 1), victimNode, RCP, NON, CREAT, Priority.DIRECT.code)
        Assert.assertTrue("a modified embedded key is Invalid", r2 is SenderVerificationResult.Invalid)
    }

    // (2) valid signature, wrong recipient: rejected BEFORE inbox/ACK admission (side effect absent)
    @Test
    fun testValidSignatureWrongRecipientRejectedBeforeInbox() {
        val rng = SecureRandom()
        val alice = newPair(rng); val aliceNode = nodeIdOf(alice.pub)
        val bobNode = nodeIdOf(newPair(rng).pub)        // the intended local recipient
        val malloryNode = nodeIdOf(newPair(rng).pub)    // some other node
        val sp = honestSign(alice.priv, alice.pub, aliceNode, bobNode, NON, CREAT, BOD)
        val inbox = mutableListOf<VerifiedApplicationMessage>()
        val acks = mutableListOf<ByteArray>()
        fun admit(r: SenderVerificationResult) { if (r is SenderVerificationResult.Verified) { inbox.add(r.message); acks.add(r.message.msgId) } }
        // a delivery attempt at the WRONG local endpoint: the signature is valid over the claimed
        // fields, yet the embedded recipient differs from the intended local recipient -> refuse
        admit(SignedMessageV1.verify(sp, aliceNode, malloryNode, NON, CREAT, Priority.DIRECT.code))
        Assert.assertSame("the wrong-recipient frame reached no inbox", 0, inbox.size)
        Assert.assertSame("and it reached no ACK log", 0, acks.size)
        admit(SignedMessageV1.verify(sp, aliceNode, bobNode, NON, CREAT, Priority.DIRECT.code))
        Assert.assertSame("the right-recipient frame is admitted exactly once", 1, inbox.size)
        Assert.assertSame("with exactly one ACK", 1, acks.size)
    }

    // (3) modified priority / time / body each break the signature; untouched authenticates
    @Test
    fun testModifiedPriorityTimeOrBodyBreaksTheSignature() {
        val rng = SecureRandom()
        val alice = newPair(rng); val aliceNode = nodeIdOf(alice.pub)
        val sp = honestSign(alice.priv, alice.pub, aliceNode, RCP, NON, CREAT, BOD)
        val pow = ByteArray(8) { (it * 7 + 3).toByte() }
        val (n1, c1, q1) = unseal(sealInner(NON, pow, CREAT, Priority.DIRECT.code, sp))
        Assert.assertTrue("the untouched sealed frame authenticates",
            SignedMessageV1.verify(sp, aliceNode, RCP, n1, c1, q1) is SenderVerificationResult.Verified)
        val rp = SignedMessageV1.verify(sp, aliceNode, RCP, NON, CREAT, Priority.BULK.code)
        Assert.assertTrue("a relay cannot rewrite the sealed priority byte: the signature covers it",
            rp is SenderVerificationResult.Invalid && (rp as SenderVerificationResult.Invalid).reason.contains("signature"))
        val rt = SignedMessageV1.verify(sp, aliceNode, RCP, NON, CREAT + 1L, Priority.DIRECT.code)
        Assert.assertTrue("a shifted creation time breaks the signature", rt is SenderVerificationResult.Invalid)
        val rb = SignedMessageV1.verify(tamper(sp, 55), aliceNode, RCP, NON, CREAT, Priority.DIRECT.code)
        Assert.assertTrue("one modified body byte breaks the signature", rb is SenderVerificationResult.Invalid)
        val rs = SignedMessageV1.verify(tamper(sp, sp.size - 1), aliceNode, RCP, NON, CREAT, Priority.DIRECT.code)
        Assert.assertTrue("one modified signature byte breaks the signature", rs is SenderVerificationResult.Invalid)
    }

    // (4) malformed length / UTF-8 / version: fail closed, never throw out of the receiver loop
    @Test
    fun testMalformedLengthAndUtf8RejectedFailClosed() {
        val rng = SecureRandom()
        val alice = newPair(rng); val aliceNode = nodeIdOf(alice.pub)
        val sp = honestSign(alice.priv, alice.pub, aliceNode, RCP, NON, CREAT, BOD)
        val trunc = sp.copyOfRange(0, sp.size - 1)
        val shortFrame = sp.copyOfRange(0, 40)
        // the bodyLength field (bytes 50..51) claims one MORE byte than the tail actually holds
        val lied = sp.copyOf().also { it[51] = (it[51].toInt() + 1).toByte() }
        val badVersion = sp.copyOf().also { it[0] = 0x02 }
        val loneCont = sp.copyOf().also { it[52] = 0x80.toByte() }                          // continuation lead
        val overlong = sp.copyOf().also { it[52] = 0xC0.toByte(); it[53] = 0x80.toByte() }  // overlong two-byte
        val surrog = sp.copyOf().also { it[52] = 0xED.toByte(); it[53] = 0xA0.toByte(); it[54] = 0x80.toByte() }
        val abovePlane = sp.copyOf().also { it[52] = 0xF5.toByte() }                        // beyond U+10FFFF
        val cases = listOf(
            Pair("truncated tail", trunc),
            Pair("shorter than the fixed layout", shortFrame),
            Pair("lied bodyLength", lied),
            Pair("unknown version", badVersion),
            Pair("lone continuation byte", loneCont),
            Pair("overlong form", overlong),
            Pair("surrogate", surrog),
            Pair("beyond the plane", abovePlane),
        )
        for (c in cases) {
            var r: SenderVerificationResult? = null
            var thrown: Throwable? = null
            try { r = SignedMessageV1.verify(c.second, aliceNode, RCP, NON, CREAT, Priority.DIRECT.code) }
            catch (e: Throwable) { thrown = e }
            Assert.assertNull("${c.first}: the verifier must not throw, it fails closed", thrown)
            Assert.assertTrue("${c.first} is Invalid", r is SenderVerificationResult.Invalid)
            Assert.assertTrue("${c.first} carries a non-empty reason", (r as SenderVerificationResult.Invalid).reason.isNotEmpty())
        }
    }

    // (5) low-order / non-canonical sealed DH inputs are refused by the input filter
    @Test
    fun testLowOrderDhInputsAreRejected() {
        // the filter guards the X25519 u-coordinate inputs of the sealed agreement (the 29-byte
        // prefix layer), NOT the Ed25519 identity keys (whose top bit is a legitimate sign bit)
        val zero = ByteArray(32)                                       // the identity element (all-zero encoding)
        Assert.assertFalse("the all-zero (identity) public value is low order: refuse", SignedMessageV1.acceptableSealedDhPublicKey(zero))
        val p = ByteArray(32).also { it[0] = 0xED.toByte(); for (j in 1..30) it[j] = 0xFF.toByte(); it[31] = 0x7F.toByte() }
        Assert.assertFalse("u == p is a non-canonical encoding: refuse", SignedMessageV1.acceptableSealedDhPublicKey(p))
        val above = ByteArray(32).also { it[0] = 0xEE.toByte(); for (j in 1..30) it[j] = 0xFF.toByte(); it[31] = 0x7F.toByte() }
        Assert.assertFalse("u > p is a non-canonical encoding: refuse", SignedMessageV1.acceptableSealedDhPublicKey(above))
        val real = X25519Keys.generate(SecureRandom()).pub            // a genuine canonical u-coordinate
        Assert.assertTrue("a canonical generated public value is accepted", SignedMessageV1.acceptableSealedDhPublicKey(real))
        val masked = real.copyOf().also { it[31] = (it[31].toInt() or 0x80).toByte() }
        Assert.assertFalse("the sign/masking bit must be clear in a canonical u encoding: refuse", SignedMessageV1.acceptableSealedDhPublicKey(masked))
        Assert.assertFalse("a 31-byte short value is refused", SignedMessageV1.acceptableSealedDhPublicKey(real.copyOfRange(0, 31)))
    }

    // (6) cross-platform pinned bytes and signature vectors (foreign-signer produced, JVM reproduced)
    @Test
    fun testCrossPlatformBytesAndSignatureVectors() {
        Assert.assertArrayEquals("BLAKE2s-128 identity binding is byte-for-byte across isles", NOD, nodeIdOf(PUB))
        val sp = SignedMessageV1.author(PRV, PUB, NOD, RCP, NON, CREAT, Priority.DIRECT, TimeQuality.USER_CONFIRMED, BOD)
        Assert.assertArrayEquals("the JVM signer reproduces the foreign pinned signed plaintext byte for byte (signature included)", SPD, sp)
        val r = SignedMessageV1.verify(SPD, NOD, RCP, NON, CREAT, Priority.DIRECT.code)
        Assert.assertTrue("the foreign-signed vector authenticates on this isle", r is SenderVerificationResult.Verified)
        val m = (r as SenderVerificationResult.Verified).message
        Assert.assertArrayEquals("msgID matches the independently computed pinned vector", MID, m.msgId)
        Assert.assertArrayEquals("msgID equals the frozen MessageId.derive over the signed plaintext",
            MessageId.derive(NOD, CREAT, NON, SPD), m.msgId)
        Assert.assertEquals("the signed plaintext has the exact pinned length", 162, SPD.size)
        Assert.assertSame("and its version byte is 0x01", 1, SPD[0].toInt())
    }

    // (7) msgID binds the signed plaintext; the PoW nonce stays outside (no circular inclusion)
    @Test
    fun testMsgIdBoundWithoutCircularInclusion() {
        val rng = SecureRandom()
        val alice = newPair(rng); val aliceNode = nodeIdOf(alice.pub)
        val sp = honestSign(alice.priv, alice.pub, aliceNode, RCP, NON, CREAT, BOD)
        val pow = ByteArray(8) { (it * 3 + 1).toByte() }
        val (n1, c1, q1) = unseal(sealInner(NON, pow, CREAT, Priority.DIRECT.code, sp))
        val r = SignedMessageV1.verify(sp, aliceNode, RCP, n1, c1, q1)
        Assert.assertTrue("the sealed frame authenticates", r is SenderVerificationResult.Verified)
        val m = (r as SenderVerificationResult.Verified).message
        Assert.assertArrayEquals("msgID is the frozen derivation over the signed plaintext",
            MessageId.derive(aliceNode, CREAT, NON, sp), m.msgId)
        // the PoW nonce is NOT in the signature preimage: rewriting it leaves authorship valid
        val pow2 = ByteArray(8) { (it * 3 + 2).toByte() }
        val (n2, c2, q2) = unseal(sealInner(NON, pow2, CREAT, Priority.DIRECT.code, sp))
        val r2 = SignedMessageV1.verify(sp, aliceNode, RCP, n2, c2, q2)
        Assert.assertTrue("a different PoW nonce still authenticates (signature excludes it: no circular search dependence)",
            r2 is SenderVerificationResult.Verified)
        Assert.assertArrayEquals("and the authorship binding is unchanged", m.msgId, (r2 as SenderVerificationResult.Verified).message.msgId)
        // while msgID is bound to every signed byte: flipping one body bit changes the derived msgID
        val flipped = tamper(sp, 55)
        Assert.assertFalse("a flipped signed byte changes the derived msgID",
            MessageId.derive(aliceNode, CREAT, NON, flipped).contentEquals(m.msgId))
    }

    // (8) unknown-time rule and the time-quality binding; no new header flag exists
    @Test
    fun testUnknownTimeRuleAndTimeQualityBinding() {
        val rng = SecureRandom()
        val alice = newPair(rng); val aliceNode = nodeIdOf(alice.pub)
        // unknown time: createdAt 0 with timeQuality 0 stand together
        val sp0 = SignedMessageV1.author(alice.priv, alice.pub, aliceNode, RCP, NON, 0L,
            Priority.DIRECT, TimeQuality.UNKNOWN, BOD)
        val r0 = SignedMessageV1.verify(sp0, aliceNode, RCP, NON, 0L, Priority.DIRECT.code)
        Assert.assertTrue("zero time with UNKNOWN quality authenticates", r0 is SenderVerificationResult.Verified)
        Assert.assertSame("and carries TimeQuality.UNKNOWN", TimeQuality.UNKNOWN, (r0 as SenderVerificationResult.Verified).message.timeQuality)
        // tampering the timeQuality byte (0 -> 1) while claiming nonzero time breaks both the
        // enum-binding story and the signature that covered the ORIGINAL byte
        val tamperedTq = sp0.copyOf().also { it[49] = TimeQuality.USER_CONFIRMED.code.toByte() }
        val r2 = SignedMessageV1.verify(tamperedTq, aliceNode, RCP, NON, CREAT, Priority.DIRECT.code)
        Assert.assertTrue("a re-stamped quality byte cannot survive: the signature covered the binding", r2 is SenderVerificationResult.Invalid)
        val r3 = SignedMessageV1.verify(tamperedTq, aliceNode, RCP, NON, 0L, Priority.DIRECT.code)
        Assert.assertTrue("even at zero time the re-stamped frame fails (byte 49 no longer 0)", r3 is SenderVerificationResult.Invalid)
        // an out-of-range timeQuality code cannot be forged past the verifier
        val outOfRange = sp0.copyOf().also { it[49] = 3 }
        val r4 = SignedMessageV1.verify(outOfRange, aliceNode, RCP, NON, 0L, Priority.DIRECT.code)
        Assert.assertTrue("timeQuality 3 is Invalid", r4 is SenderVerificationResult.Invalid)
        // authoring refuses a mismatched binding up front
        var threw = false
        try { SignedMessageV1.author(alice.priv, alice.pub, aliceNode, RCP, NON, 0L, Priority.DIRECT, TimeQuality.USER_CONFIRMED, BOD) }
        catch (e: IllegalArgumentException) { threw = true }
        Assert.assertTrue("author() binds createdAt 0 with UNKNOWN only", threw)
        // the layout has no field where a new timestamp/header flag could stand
        Assert.assertEquals("the signed plaintext is exactly 1+32+16+1+2+46+64 bytes -- no room for an extra flag", 162, sp0.size)
    }

    // (9) structural zero-signature fixtures stay structural; runtime authentication rejects them
    @Test
    fun testStructuralZeroSignatureSosFixtureRejectedAtRuntime() {
        // the existing structural golden SOS fixtures deliberately carry ZERO signatures: they are
        // STRUCTURAL. A frame with a 64-byte zero signature must NOT pass runtime authentication
        // (a structural codec test is not a signature-validity test), while the signed-DIRECT
        // family keeps its separate authenticated path.
        val unsigned = SignedMessageV1.buildUnsigned(PUB, RCP, TimeQuality.AUTHENTICATED_SOURCE, BOD)
        Assert.assertEquals("the unsigned part is exactly 1+32+16+1+2+46 bytes", 98, unsigned.size)
        val zeroSig = unsigned + ByteArray(64)
        val r = SignedMessageV1.verify(zeroSig, NOD, RCP, NON, CREAT, Priority.DIRECT.code)
        Assert.assertTrue("a zero signature is rejected by the verifier", r is SenderVerificationResult.Invalid)
        val genuine = SignedMessageV1.verify(SPD, NOD, RCP, NON, CREAT, Priority.DIRECT.code)
        Assert.assertTrue("the signed-DIRECT family still authenticates", genuine is SenderVerificationResult.Verified)
        Assert.assertFalse("and its msgID differs from any structural (zero-signature) msgId",
            MessageId.derive(NOD, CREAT, NON, zeroSig).contentEquals((genuine as SenderVerificationResult.Verified).message.msgId))
    }
}
