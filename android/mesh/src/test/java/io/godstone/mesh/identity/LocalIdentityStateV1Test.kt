package io.godstone.mesh.identity

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import org.junit.Assert.*
import org.junit.Test
import java.security.SecureRandom

class LocalIdentityStateV1Test {

    private fun hexToBytes(hex: String): ByteArray {
        val clean = hex.replace(" ", "").replace("\n", "")
        val result = ByteArray(clean.length / 2)
        for (i in result.indices) {
            result[i] = clean.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
        return result
    }

    private fun bytesToHex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it) }

    // Locked C8.1A Vectors
    private val VEC1_ED_PRIV = hexToBytes("11".repeat(32))
    private val VEC1_X_PRIV = hexToBytes("22".repeat(32))
    private val VEC1_ED_PUB = hexToBytes("d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c9778737")
    private val VEC1_X_PUB = hexToBytes("0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20")
    private val VEC1_NODE_ID = hexToBytes("8d17e35ae833d7c0ce931166dacf1311")
    private val VEC1_SERIALIZED = hexToBytes(
        "0100000000d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c97787370faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f204c546a07b0e80598eb6a290e3e3c8f364c059edf3804bd42a6924a7b0186e68217af7316c5f93cc40e35bb2731e752e758e7206fa6061b6ab349280752ec1908"
    )

    private val VEC2_ED_PRIV = hexToBytes("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    private val VEC2_X_PRIV = hexToBytes("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
    private val VEC2_ED_PUB = hexToBytes("03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8")
    private val VEC2_X_PUB = hexToBytes("358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254")
    private val VEC2_NODE_ID = hexToBytes("43a49857a024ee41b7f247d7d234fbc6")
    private val VEC2_SERIALIZED = hexToBytes(
        "010102030403a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254595d507f2602b2f52fe4ed8c72a4720e6e37206c81aecaf725654fdd41a4a08c942b23022c352dee7583d11380e5d288fa5ebc6d7fb894c8e65e7052c1778d02"
    )

    private val VEC3_ED_PRIV = hexToBytes("a5".repeat(32))
    private val VEC3_X_PRIV = hexToBytes("5a".repeat(32))
    private val VEC3_ED_PUB = hexToBytes("29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55")
    private val VEC3_X_PUB = hexToBytes("b0d08f35b4683381489afb32825e59152d47d19bc9e050d6d5a954984c9d1e2c")
    private val VEC3_NODE_ID = hexToBytes("fa6673ab45e5bdf47d2969afa59d71cb")
    private val VEC3_SERIALIZED = hexToBytes(
        "01ffffffff29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55b0d08f35b4683381489afb32825e59152d47d19bc9e050d6d5a954984c9d1e2c1079c3b37526daba3ebc207f7d7802f750a21ad38442542f6ea504ef3f11453430aa06a673d483738a0ffc071ee6418ecc4c875072db6ec82bb20eedf44b9d02"
    )

    /** In-memory test implementation of IdentityStorage. */
    private class InMemoryIdentityStorage : IdentityStorage {
        var v1State: ByteArray? = null
        var legacyMaterial: LegacyIdentityMaterial? = null
        var failWrites = false
        var lastUsedCommit = false

        override fun readV1State(): ByteArray? = v1State?.copyOf()

        override fun readLegacyMaterial(): LegacyIdentityMaterial? {
            val leg = legacyMaterial ?: return null
            return LegacyIdentityMaterial(
                idPub = leg.idPub.copyOf(),
                idPriv = leg.idPriv.copyOf(),
                dhPub = leg.dhPub.copyOf(),
                dhPriv = leg.dhPriv.copyOf(),
            )
        }

        override fun hasPartialLegacy(): Boolean = false

        override fun writeV1State(state: ByteArray): Boolean {
            lastUsedCommit = true
            if (failWrites) return false
            v1State = state.copyOf()
            return true
        }

        override fun migrateLegacyToV1(state: ByteArray): Boolean {
            lastUsedCommit = true
            if (failWrites) return false
            v1State = state.copyOf()
            legacyMaterial = null
            return true
        }

        override fun clear(): Boolean {
            v1State = null
            legacyMaterial = null
            return true
        }
    }

    // 1. V1 state exact length 69
    @Test
    fun `test 1 V1 state exact length 69`() {
        val state = LocalIdentityStateV1.create(0L, VEC1_ED_PRIV, VEC1_X_PRIV)
        val encoded = state.encode()
        assertEquals(69, encoded.size)
        assertEquals(LOCAL_IDENTITY_STATE_LENGTH, encoded.size)
    }

    // 2. V1 generation is big-endian
    @Test
    fun `test 2 V1 generation is big-endian`() {
        val state = LocalIdentityStateV1.create(0x01020304L, VEC2_ED_PRIV, VEC2_X_PRIV)
        val enc = state.encode()
        assertEquals(0x01.toByte(), enc[1])
        assertEquals(0x02.toByte(), enc[2])
        assertEquals(0x03.toByte(), enc[3])
        assertEquals(0x04.toByte(), enc[4])
    }

    // 3. V1 generation 0 parses
    @Test
    fun `test 3 V1 generation 0 parses`() {
        val state = LocalIdentityStateV1.create(0L, VEC1_ED_PRIV, VEC1_X_PRIV)
        val parsed = LocalIdentityStateV1.parse(state.encode())
        assertEquals(0L, parsed.generation)
        assertArrayEquals(VEC1_ED_PRIV, parsed.ed25519Seed)
        assertArrayEquals(VEC1_X_PRIV, parsed.x25519PrivateKey)
    }

    // 4. V1 generation 0x01020304 parses 16909060
    @Test
    fun `test 4 V1 generation 0x01020304 parses 16909060`() {
        val state = LocalIdentityStateV1.create(0x01020304L, VEC2_ED_PRIV, VEC2_X_PRIV)
        val parsed = LocalIdentityStateV1.parse(state.encode())
        assertEquals(16909060L, parsed.generation)
        assertEquals(0x01020304L, parsed.generation)
    }

    // 5. V1 generation 0xffffffff parses 4294967295
    @Test
    fun `test 5 V1 generation 0xffffffff parses 4294967295`() {
        val state = LocalIdentityStateV1.create(0xFFFFFFFFL, VEC3_ED_PRIV, VEC3_X_PRIV)
        val parsed = LocalIdentityStateV1.parse(state.encode())
        assertEquals(4294967295L, parsed.generation)
        assertEquals(0xFFFFFFFFL, parsed.generation)
    }

    // 6. malformed 68-byte state rejected
    @Test(expected = LocalIdentityException.IdentityStateCorrupt::class)
    fun `test 6 malformed 68-byte state rejected`() {
        val truncated = ByteArray(68) { 0x01 }
        LocalIdentityStateV1.parse(truncated)
    }

    // 7. malformed 70-byte state rejected
    @Test(expected = LocalIdentityException.IdentityStateCorrupt::class)
    fun `test 7 malformed 70-byte state rejected`() {
        val oversized = ByteArray(70) { 0x01 }
        LocalIdentityStateV1.parse(oversized)
    }

    // 8. unknown V1 version rejected
    @Test(expected = LocalIdentityException.UnsupportedIdentityStateVersion::class)
    fun `test 8 unknown V1 version rejected`() {
        val badVersion = LocalIdentityStateV1.create(0L, VEC1_ED_PRIV, VEC1_X_PRIV).encode()
        badVersion[0] = 0x02
        LocalIdentityStateV1.parse(badVersion)
    }

    // 9. empty persistence creates generation-0 V1 state
    @Test
    fun `test 9 empty persistence creates generation-0 V1 state`() {
        val storage = InMemoryIdentityStorage()
        val identity = Identity.loadOrCreate(storage)
        assertEquals(0L, identity.bindingGeneration)
        assertNotNull(storage.v1State)
        val parsedState = LocalIdentityStateV1.parse(storage.v1State!!)
        assertEquals(0L, parsedState.generation)
    }

    // 10. fresh state uses commit, not asynchronous apply
    @Test
    fun `test 10 fresh state uses commit not apply`() {
        val storage = InMemoryIdentityStorage()
        Identity.loadOrCreate(storage)
        assertTrue(storage.lastUsedCommit)
    }

    // 11. failed commit returns or throws persistence failure and no successful Identity
    @Test(expected = LocalIdentityException.IdentityPersistenceFailure::class)
    fun `test 11 failed commit throws persistence failure`() {
        val storage = InMemoryIdentityStorage().apply { failWrites = true }
        Identity.loadOrCreate(storage)
    }

    // 12. complete legacy state migrates to V1 generation 0
    @Test
    fun `test 12 complete legacy state migrates to V1 generation 0`() {
        val storage = InMemoryIdentityStorage().apply {
            legacyMaterial = LegacyIdentityMaterial(
                idPub = VEC1_ED_PUB,
                idPriv = VEC1_ED_PRIV,
                dhPub = VEC1_X_PUB,
                dhPriv = VEC1_X_PRIV,
            )
        }
        val identity = Identity.loadOrCreate(storage)
        assertEquals(0L, identity.bindingGeneration)
        assertArrayEquals(VEC1_ED_PUB, identity.identityPub)
        assertArrayEquals(VEC1_X_PUB, identity.staticDhPub)
        assertArrayEquals(VEC1_NODE_ID, identity.nodeId)
    }

    // 13. migration removes all four legacy values
    @Test
    fun `test 13 migration removes all four legacy values`() {
        val storage = InMemoryIdentityStorage().apply {
            legacyMaterial = LegacyIdentityMaterial(
                idPub = VEC1_ED_PUB,
                idPriv = VEC1_ED_PRIV,
                dhPub = VEC1_X_PUB,
                dhPriv = VEC1_X_PRIV,
            )
        }
        Identity.loadOrCreate(storage)
        assertNull(storage.legacyMaterial)
        assertNotNull(storage.v1State)
    }

    // 14. legacy Ed public/private mismatch rejects as corruption
    @Test(expected = LocalIdentityException.IdentityStateCorrupt::class)
    fun `test 14 legacy Ed public private mismatch rejects as corruption`() {
        val storage = InMemoryIdentityStorage().apply {
            legacyMaterial = LegacyIdentityMaterial(
                idPub = VEC2_ED_PUB, // Mismatched Ed pub!
                idPriv = VEC1_ED_PRIV,
                dhPub = VEC1_X_PUB,
                dhPriv = VEC1_X_PRIV,
            )
        }
        Identity.loadOrCreate(storage)
    }

    // 15. legacy X public/private mismatch rejects as corruption
    @Test(expected = LocalIdentityException.IdentityStateCorrupt::class)
    fun `test 15 legacy X public private mismatch rejects as corruption`() {
        val storage = InMemoryIdentityStorage().apply {
            legacyMaterial = LegacyIdentityMaterial(
                idPub = VEC1_ED_PUB,
                idPriv = VEC1_ED_PRIV,
                dhPub = VEC2_X_PUB, // Mismatched X pub!
                dhPriv = VEC1_X_PRIV,
            )
        }
        Identity.loadOrCreate(storage)
    }

    // 16. partial legacy state rejects as corruption
    @Test(expected = LocalIdentityException.IdentityStateCorrupt::class)
    fun `test 16 partial legacy state rejects as corruption`() {
        val storage = object : IdentityStorage {
            override fun readV1State(): ByteArray? = null
            override fun readLegacyMaterial(): LegacyIdentityMaterial? = null
            override fun hasPartialLegacy(): Boolean = true
            override fun writeV1State(state: ByteArray): Boolean = true
            override fun migrateLegacyToV1(state: ByteArray): Boolean = true
            override fun clear(): Boolean = true
        }
        Identity.loadOrCreate(storage)
    }

    // 17. V1 + legacy mixed state rejects as corruption
    @Test(expected = LocalIdentityException.IdentityStateCorrupt::class)
    fun `test 17 V1 and legacy mixed state rejects as corruption`() {
        val storage = InMemoryIdentityStorage().apply {
            v1State = LocalIdentityStateV1.create(0L, VEC1_ED_PRIV, VEC1_X_PRIV).encode()
            legacyMaterial = LegacyIdentityMaterial(VEC1_ED_PUB, VEC1_ED_PRIV, VEC1_X_PUB, VEC1_X_PRIV)
        }
        Identity.loadOrCreate(storage)
    }

    // 18. malformed Base64 rejects as corruption
    @Test(expected = LocalIdentityException.IdentityStateCorrupt::class)
    fun `test 18 malformed Base64 rejects as corruption`() {
        val storage = object : IdentityStorage {
            override fun readV1State(): ByteArray? = throw LocalIdentityException.IdentityStateCorrupt("Bad Base64")
            override fun readLegacyMaterial(): LegacyIdentityMaterial? = null
            override fun hasPartialLegacy(): Boolean = false
            override fun writeV1State(state: ByteArray): Boolean = true
            override fun migrateLegacyToV1(state: ByteArray): Boolean = true
            override fun clear(): Boolean = true
        }
        Identity.loadOrCreate(storage)
    }

    // 19. vector-1 V1 state issues exact locked fresh_generation_zero binding
    @Test
    fun `test 19 vector 1 issues exact locked fresh_generation_zero binding`() {
        val storage = InMemoryIdentityStorage().apply {
            v1State = LocalIdentityStateV1.create(0L, VEC1_ED_PRIV, VEC1_X_PRIV).encode()
        }
        val identity = Identity.loadOrCreate(storage)
        val binding = identity.issueIdentityBinding()
        assertArrayEquals(VEC1_SERIALIZED, binding.encode())
    }

    // 20. vector-2 V1 state issues exact locked endian_lock binding
    @Test
    fun `test 20 vector 2 issues exact locked endian_lock binding`() {
        val storage = InMemoryIdentityStorage().apply {
            v1State = LocalIdentityStateV1.create(0x01020304L, VEC2_ED_PRIV, VEC2_X_PRIV).encode()
        }
        val identity = Identity.loadOrCreate(storage)
        val binding = identity.issueIdentityBinding()
        assertArrayEquals(VEC2_SERIALIZED, binding.encode())
    }

    // 21. vector-3 V1 state issues exact locked max_generation binding
    @Test
    fun `test 21 vector 3 issues exact locked max_generation binding`() {
        val storage = InMemoryIdentityStorage().apply {
            v1State = LocalIdentityStateV1.create(0xFFFFFFFFL, VEC3_ED_PRIV, VEC3_X_PRIV).encode()
        }
        val identity = Identity.loadOrCreate(storage)
        val binding = identity.issueIdentityBinding()
        assertArrayEquals(VEC3_SERIALIZED, binding.encode())
    }

    // 22. issueIdentityBinding has no generation parameter
    @Test
    fun `test 22 issueIdentityBinding has no generation parameter`() {
        val methods = Identity::class.java.declaredMethods
        val issuerMethod = methods.find { it.name.startsWith("issueIdentityBinding") }
        assertNotNull("issueIdentityBinding method must exist", issuerMethod)
        assertEquals(0, issuerMethod!!.parameterCount)
    }

    // 23. issuer output validates through C8 1A IdentityBindingValidator
    @Test
    fun `test 23 issuer output validates through C8 1A IdentityBindingValidator`() {
        val storage = InMemoryIdentityStorage().apply {
            v1State = LocalIdentityStateV1.create(0L, VEC1_ED_PRIV, VEC1_X_PRIV).encode()
        }
        val identity = Identity.loadOrCreate(storage)
        val binding = identity.issueIdentityBinding()
        val result = IdentityBindingValidator.validate(binding.encode(), identity.staticDhPub, identity.nodeHint)
        assertTrue(result is IdentityBindingValidationResult.Valid)
        val validated = (result as IdentityBindingValidationResult.Valid).binding
        assertEquals(0L, validated.generation)
        assertArrayEquals(identity.nodeId, validated.nodeId)
        assertArrayEquals(identity.identityPub, validated.signingPublicKey)
        assertArrayEquals(identity.staticDhPub, validated.staticDhPublicKey)
    }

    // 24. identity public arrays are defensive copies
    @Test
    fun `test 24 identity public arrays are defensive copies`() {
        val storage = InMemoryIdentityStorage().apply {
            v1State = LocalIdentityStateV1.create(0L, VEC1_ED_PRIV, VEC1_X_PRIV).encode()
        }
        val identity = Identity.loadOrCreate(storage)
        val pub1 = identity.identityPub
        val dhPub1 = identity.staticDhPub
        pub1[0] = (pub1[0].toInt() xor 0xFF).toByte()
        dhPub1[0] = (dhPub1[0].toInt() xor 0xFF).toByte()

        assertNotEquals(pub1[0], identity.identityPub[0])
        assertNotEquals(dhPub1[0], identity.staticDhPub[0])
    }

    // 25. nodeId and nodeHint are defensive copies
    @Test
    fun `test 25 nodeId and nodeHint are defensive copies`() {
        val storage = InMemoryIdentityStorage().apply {
            v1State = LocalIdentityStateV1.create(0L, VEC1_ED_PRIV, VEC1_X_PRIV).encode()
        }
        val identity = Identity.loadOrCreate(storage)
        val nid = identity.nodeId
        val hint = identity.nodeHint
        nid[0] = (nid[0].toInt() xor 0xFF).toByte()
        hint[0] = (hint[0].toInt() xor 0xFF).toByte()

        assertNotEquals(nid[0], identity.nodeId[0])
        assertNotEquals(hint[0], identity.nodeHint[0])
    }

    // 26. Noise static private-key accessor does not expose mutable backing state
    @Test
    fun `test 26 Noise static private key accessor does not expose mutable backing state`() {
        val storage = InMemoryIdentityStorage().apply {
            v1State = LocalIdentityStateV1.create(0L, VEC1_ED_PRIV, VEC1_X_PRIV).encode()
        }
        val identity = Identity.loadOrCreate(storage)
        val xPriv = identity.staticDhPriv
        xPriv[0] = (xPriv[0].toInt() xor 0xFF).toByte()
        assertNotEquals(xPriv[0], identity.staticDhPriv[0])
    }

    // 27. fromKeyMaterial cannot select arbitrary generation
    @Test
    fun `test 27 fromKeyMaterial fixed to generation 0`() {
        val id = Identity.fromKeyMaterial(VEC1_ED_PUB, VEC1_ED_PRIV, VEC1_X_PUB, VEC1_X_PRIV)
        assertEquals(0L, id.bindingGeneration)
    }

    // 28. staticDhPriv is not public API
    @Test
    fun `test 28 staticDhPriv is not public API`() {
        val methods = Identity::class.java.declaredMethods
        val unmangledGetter = methods.find { it.name == "getStaticDhPriv" }
        assertNull("Unmangled public getter getStaticDhPriv() must not exist", unmangledGetter)
        val internalMangledGetter = methods.find { it.name.startsWith("getStaticDhPriv$") }
        assertNotNull("Kotlin internal getter getStaticDhPriv$... must exist", internalMangledGetter)
    }

    // 29. AndroidWipeArtifacts erase failure leaves journal at REQUESTED
    @Test
    fun `test 29 AndroidWipeArtifacts erase failure leaves journal at REQUESTED`() {
        class MockJournal : WipeJournal {
            var state = PanicWipe.WipeState.IDLE
            override fun read() = state
            override fun write(s: PanicWipe.WipeState) { state = s }
            override fun clear() { state = PanicWipe.WipeState.IDLE }
        }
        val journal = MockJournal()
        val artifacts = AndroidWipeArtifacts(
            eraseAction = { throw RuntimeException("Keystore erase failed") },
            deleteArtifactsAction = {},
            regenerateAction = {}
        )
        val wipe = PanicWipe(journal, artifacts)
        try {
            wipe.begin()
            fail("Expected exception")
        } catch (_: RuntimeException) {}
        assertEquals(PanicWipe.WipeState.REQUESTED, journal.state)
    }

    // 30. AndroidWipeArtifacts regenerate failure leaves journal at ARTIFACTS_DELETED
    @Test
    fun `test 30 AndroidWipeArtifacts regenerate failure leaves journal at ARTIFACTS_DELETED`() {
        class MockJournal : WipeJournal {
            var state = PanicWipe.WipeState.IDLE
            override fun read() = state
            override fun write(s: PanicWipe.WipeState) { state = s }
            override fun clear() { state = PanicWipe.WipeState.IDLE }
        }
        val journal = MockJournal()
        val artifacts = AndroidWipeArtifacts(
            eraseAction = {},
            deleteArtifactsAction = {},
            regenerateAction = { throw RuntimeException("Regeneration persistence failed") }
        )
        val wipe = PanicWipe(journal, artifacts)
        try {
            wipe.begin()
            fail("Expected exception")
        } catch (_: RuntimeException) {}
        assertEquals(PanicWipe.WipeState.ARTIFACTS_DELETED, journal.state)
    }

    // 31. AndroidWipeArtifacts successful wipe generates generation 0
    @Test
    fun `test 31 AndroidWipeArtifacts successful wipe generates generation 0`() {
        class MockJournal : WipeJournal {
            var state = PanicWipe.WipeState.IDLE
            override fun read() = state
            override fun write(s: PanicWipe.WipeState) { state = s }
            override fun clear() { state = PanicWipe.WipeState.IDLE }
        }
        val storage = InMemoryIdentityStorage()
        val journal = MockJournal()
        var generatedId: Identity? = null
        val artifacts = AndroidWipeArtifacts(
            eraseAction = {},
            deleteArtifactsAction = {},
            regenerateAction = {
                generatedId = Identity.loadOrCreate(storage)
            }
        )
        val wipe = PanicWipe(journal, artifacts)
        wipe.begin()
        assertEquals(PanicWipe.WipeState.IDLE, journal.state)
        assertNotNull(generatedId)
        assertEquals(0L, generatedId!!.bindingGeneration)
    }

    // 32. AndroidWipeArtifacts has no default zero-arg constructor
    @Test
    fun `test 32 AndroidWipeArtifacts has no default zero-arg constructor`() {
        val constructors = AndroidWipeArtifacts::class.java.constructors
        val zeroArg = constructors.find { it.parameterCount == 0 }
        assertNull("AndroidWipeArtifacts must not have a zero-arg constructor", zeroArg)
    }
}
