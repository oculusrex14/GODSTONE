package io.godstone.mesh.identity

import io.godstone.core.crypto.Ed25519Keys
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class IdentityBindingV1Test {

    // Authoritative Vector 1: fresh_generation_zero
    companion object {
        const val VEC1_NAME = "fresh_generation_zero"
        const val VEC1_GEN = 0L
        const val VEC1_ED_SEED_HEX = "1111111111111111111111111111111111111111111111111111111111111111"
        const val VEC1_SIGNING_PUB_HEX = "d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c9778737"
        const val VEC1_STATIC_DH_PUB_HEX = "0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20"
        const val VEC1_NODE_ID_HEX = "8d17e35ae833d7c0ce931166dacf1311"
        const val VEC1_PREIMAGE_HEX = "474d50322d494442494e440100000000d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c97787370faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20"
        const val VEC1_SIG_HEX = "4c546a07b0e80598eb6a290e3e3c8f364c059edf3804bd42a6924a7b0186e68217af7316c5f93cc40e35bb2731e752e758e7206fa6061b6ab349280752ec1908"
        const val VEC1_SERIALIZED_HEX = "0100000000d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c97787370faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f204c546a07b0e80598eb6a290e3e3c8f364c059edf3804bd42a6924a7b0186e68217af7316c5f93cc40e35bb2731e752e758e7206fa6061b6ab349280752ec1908"

        // Authoritative Vector 2: endian_lock
        const val VEC2_NAME = "endian_lock"
        const val VEC2_GEN = 16909060L // 0x01020304
        const val VEC2_ED_SEED_HEX = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        const val VEC2_SIGNING_PUB_HEX = "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
        const val VEC2_STATIC_DH_PUB_HEX = "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254"
        const val VEC2_NODE_ID_HEX = "43a49857a024ee41b7f247d7d234fbc6"
        const val VEC2_PREIMAGE_HEX = "474d50322d494442494e44010102030403a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254"
        const val VEC2_SIG_HEX = "595d507f2602b2f52fe4ed8c72a4720e6e37206c81aecaf725654fdd41a4a08c942b23022c352dee7583d11380e5d288fa5ebc6d7fb894c8e65e7052c1778d02"
        const val VEC2_SERIALIZED_HEX = "010102030403a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254595d507f2602b2f52fe4ed8c72a4720e6e37206c81aecaf725654fdd41a4a08c942b23022c352dee7583d11380e5d288fa5ebc6d7fb894c8e65e7052c1778d02"

        // Authoritative Vector 3: max_generation
        const val VEC3_NAME = "max_generation"
        const val VEC3_GEN = 4294967295L // 0xffffffff
        const val VEC3_ED_SEED_HEX = "a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5"
        const val VEC3_SIGNING_PUB_HEX = "29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55"
        const val VEC3_STATIC_DH_PUB_HEX = "b0d08f35b4683381489afb32825e59152d47d19bc9e050d6d5a954984c9d1e2c"
        const val VEC3_NODE_ID_HEX = "fa6673ab45e5bdf47d2969afa59d71cb"
        const val VEC3_PREIMAGE_HEX = "474d50322d494442494e4401ffffffff29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55b0d08f35b4683381489afb32825e59152d47d19bc9e050d6d5a954984c9d1e2c"
        const val VEC3_SIG_HEX = "1079c3b37526daba3ebc207f7d7802f750a21ad38442542f6ea504ef3f11453430aa06a673d483738a0ffc071ee6418ecc4c875072db6ec82bb20eedf44b9d02"
        const val VEC3_SERIALIZED_HEX = "01ffffffff29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55b0d08f35b4683381489afb32825e59152d47d19bc9e050d6d5a954984c9d1e2c1079c3b37526daba3ebc207f7d7802f750a21ad38442542f6ea504ef3f11453430aa06a673d483738a0ffc071ee6418ecc4c875072db6ec82bb20eedf44b9d02"

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

        private fun bytesToHex(bytes: ByteArray): String {
            val sb = StringBuilder(bytes.size * 2)
            for (b in bytes) {
                sb.append(String.format("%02x", b.toInt() and 0xFF))
            }
            return sb.toString()
        }
    }

    @Test
    fun `fresh_generation_zero KAT assertion`() {
        val serialized = hexToBytes(VEC1_SERIALIZED_HEX)
        val staticDh = hexToBytes(VEC1_STATIC_DH_PUB_HEX)
        val expectedNodeId = hexToBytes(VEC1_NODE_ID_HEX)
        val hint = expectedNodeId.copyOfRange(0, 4)

        val result = IdentityBindingValidator.validate(serialized, staticDh, hint)
        assertTrue("Expected Valid result for fresh_generation_zero", result is IdentityBindingValidationResult.Valid)
        val valid = (result as IdentityBindingValidationResult.Valid).binding

        assertEquals(0L, valid.generation)
        assertArrayEquals(expectedNodeId, valid.nodeId)
        assertArrayEquals(hexToBytes(VEC1_SIGNING_PUB_HEX), valid.signingPublicKey)
        assertArrayEquals(staticDh, valid.staticDhPublicKey)

        val parsed = IdentityBindingV1.parse(serialized)
        assertEquals(0L, parsed.generation)
        assertArrayEquals(serialized, parsed.encode())
    }

    @Test
    fun `endian_lock KAT assertion`() {
        val serialized = hexToBytes(VEC2_SERIALIZED_HEX)
        val staticDh = hexToBytes(VEC2_STATIC_DH_PUB_HEX)
        val expectedNodeId = hexToBytes(VEC2_NODE_ID_HEX)
        val hint = expectedNodeId.copyOfRange(0, 4)

        val result = IdentityBindingValidator.validate(serialized, staticDh, hint)
        assertTrue("Expected Valid result for endian_lock", result is IdentityBindingValidationResult.Valid)
        val valid = (result as IdentityBindingValidationResult.Valid).binding

        assertEquals(16909060L, valid.generation)
        assertArrayEquals(expectedNodeId, valid.nodeId)
        assertArrayEquals(hexToBytes(VEC2_SIGNING_PUB_HEX), valid.signingPublicKey)
        assertArrayEquals(staticDh, valid.staticDhPublicKey)

        val parsed = IdentityBindingV1.parse(serialized)
        assertEquals(0x01020304L, parsed.generation)
        assertArrayEquals(serialized, parsed.encode())
    }

    @Test
    fun `max_generation KAT assertion`() {
        val serialized = hexToBytes(VEC3_SERIALIZED_HEX)
        val staticDh = hexToBytes(VEC3_STATIC_DH_PUB_HEX)
        val expectedNodeId = hexToBytes(VEC3_NODE_ID_HEX)
        val hint = expectedNodeId.copyOfRange(0, 4)

        val result = IdentityBindingValidator.validate(serialized, staticDh, hint)
        assertTrue("Expected Valid result for max_generation", result is IdentityBindingValidationResult.Valid)
        val valid = (result as IdentityBindingValidationResult.Valid).binding

        assertEquals(4294967295L, valid.generation)
        assertArrayEquals(expectedNodeId, valid.nodeId)
        assertArrayEquals(hexToBytes(VEC3_SIGNING_PUB_HEX), valid.signingPublicKey)
        assertArrayEquals(staticDh, valid.staticDhPublicKey)

        val parsed = IdentityBindingV1.parse(serialized)
        assertEquals(0xFFFFFFFFL, parsed.generation)
        assertArrayEquals(serialized, parsed.encode())
    }

    @Test
    fun `exact 80-byte preimage reproduction`() {
        val p1 = IdentityBindingV1.signaturePreimage(
            VEC1_GEN,
            hexToBytes(VEC1_SIGNING_PUB_HEX),
            hexToBytes(VEC1_STATIC_DH_PUB_HEX)
        )
        assertEquals(80, p1.size)
        assertEquals(VEC1_PREIMAGE_HEX, bytesToHex(p1))

        val p2 = IdentityBindingV1.signaturePreimage(
            VEC2_GEN,
            hexToBytes(VEC2_SIGNING_PUB_HEX),
            hexToBytes(VEC2_STATIC_DH_PUB_HEX)
        )
        assertEquals(80, p2.size)
        assertEquals(VEC2_PREIMAGE_HEX, bytesToHex(p2))

        val p3 = IdentityBindingV1.signaturePreimage(
            VEC3_GEN,
            hexToBytes(VEC3_SIGNING_PUB_HEX),
            hexToBytes(VEC3_STATIC_DH_PUB_HEX)
        )
        assertEquals(80, p3.size)
        assertEquals(VEC3_PREIMAGE_HEX, bytesToHex(p3))
    }

    @Test
    fun `exact 133-byte serialization`() {
        val obj = IdentityBindingV1.create(
            VEC1_GEN,
            hexToBytes(VEC1_SIGNING_PUB_HEX),
            hexToBytes(VEC1_STATIC_DH_PUB_HEX),
            hexToBytes(VEC1_SIG_HEX)
        )
        val enc = obj.encode()
        assertEquals(133, enc.size)
        assertEquals(VEC1_SERIALIZED_HEX, bytesToHex(enc))
    }

    @Test
    fun `parse and encode round-trip byte-identical`() {
        for (hex in listOf(VEC1_SERIALIZED_HEX, VEC2_SERIALIZED_HEX, VEC3_SERIALIZED_HEX)) {
            val bytes = hexToBytes(hex)
            val parsed = IdentityBindingV1.parse(bytes)
            assertArrayEquals(bytes, parsed.encode())
        }
    }

    @Test
    fun `valid signature accepted`() {
        val signingPub = hexToBytes(VEC1_SIGNING_PUB_HEX)
        val staticDh = hexToBytes(VEC1_STATIC_DH_PUB_HEX)
        val sig = hexToBytes(VEC1_SIG_HEX)
        val preimage = IdentityBindingV1.signaturePreimage(VEC1_GEN, signingPub, staticDh)

        assertTrue(Ed25519Keys.verify(preimage, sig, signingPub))
    }

    @Test
    fun `bad signature one-bit corruption rejected`() {
        val serialized = hexToBytes(VEC1_SERIALIZED_HEX)
        val staticDh = hexToBytes(VEC1_STATIC_DH_PUB_HEX)
        val hint = hexToBytes(VEC1_NODE_ID_HEX).copyOfRange(0, 4)

        // Corrupt signature byte
        serialized[69] = (serialized[69].toInt() xor 0x01).toByte()
        val result = IdentityBindingValidator.validate(serialized, staticDh, hint)
        assertEquals(IdentityBindingValidationResult.InvalidSignature, result)
    }

    @Test
    fun `wrong signing public key rejected`() {
        val serialized = hexToBytes(VEC1_SERIALIZED_HEX)
        val staticDh = hexToBytes(VEC1_STATIC_DH_PUB_HEX)
        val hint = hexToBytes(VEC1_NODE_ID_HEX).copyOfRange(0, 4)

        // Overwrite signing key with Vector 2's signing key
        System.arraycopy(hexToBytes(VEC2_SIGNING_PUB_HEX), 0, serialized, 5, 32)
        val result = IdentityBindingValidator.validate(serialized, staticDh, hint)
        assertEquals(IdentityBindingValidationResult.InvalidSignature, result)
    }

    @Test
    fun `remote Noise static mismatch rejected`() {
        val serialized = hexToBytes(VEC1_SERIALIZED_HEX)
        val wrongStaticDh = hexToBytes(VEC2_STATIC_DH_PUB_HEX)
        val hint = hexToBytes(VEC1_NODE_ID_HEX).copyOfRange(0, 4)

        val result = IdentityBindingValidator.validate(serialized, wrongStaticDh, hint)
        assertEquals(IdentityBindingValidationResult.NoiseStaticMismatch, result)
    }

    @Test
    fun `advertised hint mismatch rejected`() {
        val serialized = hexToBytes(VEC1_SERIALIZED_HEX)
        val staticDh = hexToBytes(VEC1_STATIC_DH_PUB_HEX)
        val wrongHint = byteArrayOf(0x00, 0x00, 0x00, 0x00)

        val result = IdentityBindingValidator.validate(serialized, staticDh, wrongHint)
        assertEquals(IdentityBindingValidationResult.AdvertisementHintMismatch, result)
    }

    @Test
    fun `bad version rejected`() {
        val serialized = hexToBytes(VEC1_SERIALIZED_HEX)
        val staticDh = hexToBytes(VEC1_STATIC_DH_PUB_HEX)
        val hint = hexToBytes(VEC1_NODE_ID_HEX).copyOfRange(0, 4)

        serialized[0] = 0x02
        val result = IdentityBindingValidator.validate(serialized, staticDh, hint)
        assertEquals(IdentityBindingValidationResult.UnsupportedVersion, result)

        try {
            IdentityBindingV1.parse(serialized)
            fail("Expected parse to fail on unsupported version")
        } catch (_: IllegalArgumentException) {}
    }

    @Test
    fun `truncated 132-byte payload rejected`() {
        val serialized = hexToBytes(VEC1_SERIALIZED_HEX).copyOf(132)
        val staticDh = hexToBytes(VEC1_STATIC_DH_PUB_HEX)
        val hint = hexToBytes(VEC1_NODE_ID_HEX).copyOfRange(0, 4)

        val result = IdentityBindingValidator.validate(serialized, staticDh, hint)
        assertEquals(IdentityBindingValidationResult.MalformedLength, result)

        try {
            IdentityBindingV1.parse(serialized)
            fail("Expected parse to fail on truncated payload")
        } catch (_: IllegalArgumentException) {}
    }

    @Test
    fun `oversized 134-byte payload rejected`() {
        val serialized = hexToBytes(VEC1_SERIALIZED_HEX) + byteArrayOf(0x00)
        val staticDh = hexToBytes(VEC1_STATIC_DH_PUB_HEX)
        val hint = hexToBytes(VEC1_NODE_ID_HEX).copyOfRange(0, 4)

        val result = IdentityBindingValidator.validate(serialized, staticDh, hint)
        assertEquals(IdentityBindingValidationResult.MalformedLength, result)

        try {
            IdentityBindingV1.parse(serialized)
            fail("Expected parse to fail on oversized payload")
        } catch (_: IllegalArgumentException) {}
    }

    @Test
    fun `malformed authenticated static context rejected`() {
        val serialized = hexToBytes(VEC1_SERIALIZED_HEX)
        val badStatic = ByteArray(31)
        val hint = hexToBytes(VEC1_NODE_ID_HEX).copyOfRange(0, 4)

        val result = IdentityBindingValidator.validate(serialized, badStatic, hint)
        assertEquals(IdentityBindingValidationResult.InvalidContext, result)
    }

    @Test
    fun `malformed advertised hint context rejected`() {
        val serialized = hexToBytes(VEC1_SERIALIZED_HEX)
        val staticDh = hexToBytes(VEC1_STATIC_DH_PUB_HEX)
        val badHint = ByteArray(5)

        val result = IdentityBindingValidator.validate(serialized, staticDh, badHint)
        assertEquals(IdentityBindingValidationResult.InvalidContext, result)
    }

    @Test
    fun `Kotlin defensive-copy test`() {
        val serialized = hexToBytes(VEC1_SERIALIZED_HEX)
        val parsed = IdentityBindingV1.parse(serialized)

        // Mutate original buffer
        serialized[5] = (serialized[5].toInt() xor 0xFF).toByte()
        assertNotEquals(serialized[5], parsed.signingPublicKey[0])

        // Mutate array returned by getter
        val signing = parsed.signingPublicKey
        signing[0] = (signing[0].toInt() xor 0xFF).toByte()
        assertNotEquals(signing[0], parsed.signingPublicKey[0])

        // ValidatedPeerBinding defensive copy
        val staticDh = hexToBytes(VEC1_STATIC_DH_PUB_HEX)
        val hint = hexToBytes(VEC1_NODE_ID_HEX).copyOfRange(0, 4)
        val result = IdentityBindingValidator.validate(hexToBytes(VEC1_SERIALIZED_HEX), staticDh, hint)
        val validated = (result as IdentityBindingValidationResult.Valid).binding

        val nid = validated.nodeId
        nid[0] = (nid[0].toInt() xor 0xFF).toByte()
        assertNotEquals(nid[0], validated.nodeId[0])
    }

    @Test
    fun `generation big-endian parsing verification`() {
        val serialized = hexToBytes(VEC2_SERIALIZED_HEX)
        val parsed = IdentityBindingV1.parse(serialized)
        assertEquals(16909060L, parsed.generation)
        assertEquals(0x01020304L, parsed.generation)
    }

    @Test
    fun `generation unsigned max parsing verification`() {
        val serialized = hexToBytes(VEC3_SERIALIZED_HEX)
        val parsed = IdentityBindingV1.parse(serialized)
        assertEquals(4294967295L, parsed.generation)
        assertEquals(0xFFFFFFFFL, parsed.generation)
    }
}
