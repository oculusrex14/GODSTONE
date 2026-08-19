package io.godstone.mesh.identity

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.sql.DriverManager

class PeerIdentityStoreTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    @Test
    fun testFreshDatabaseInitialization() {
        val dbFile = tempFolder.newFile("fresh_peer.db")
        dbFile.delete() // Start fresh

        val store = JdbcPeerIdentityStore(dbFile)
        store.use {
            // Verify empty read
            val row = it.readRaw(ByteArray(16) { 0x01 })
            assertNull(row)
        }

        // Verify user_version was stamped
        val conn = DriverManager.getConnection("jdbc:sqlite:" + dbFile.absolutePath)
        conn.use { c ->
            val v = c.prepareStatement("PRAGMA user_version").use { ps ->
                ps.executeQuery().use { rs -> if (rs.next()) rs.getInt(1) else 0 }
            }
            assertEquals(1, v)
        }
    }

    @Test
    fun testReopenExistingValidDatabase() {
        val dbFile = tempFolder.newFile("reopen_peer.db")
        dbFile.delete()

        val nodeId = ByteArray(16) { 0x11 }
        val signPub = ByteArray(32) { 0x22 }
        val staticPub = ByteArray(32) { 0x33 }

        JdbcPeerIdentityStore(dbFile).use { store ->
            val affected = store.insertFirstSeen(nodeId, signPub, staticPub, 0L, PeerTrustLevel.TOFU_PINNED.persistedCode)
            assertEquals(1, affected)
        }

        // Reopen and read back
        JdbcPeerIdentityStore(dbFile).use { store ->
            val row = store.readRaw(nodeId)
            assertNotNull(row)
            assertArrayEquals(nodeId, row!!.nodeIdRaw)
            assertArrayEquals(signPub, row.signingPublicKeyRaw)
            assertArrayEquals(staticPub, row.acceptedStaticDhPublicKeyRaw)
            assertEquals(0L, row.acceptedGenerationRaw)
            assertEquals(PeerTrustLevel.TOFU_PINNED.persistedCode, row.trustCodeRaw)
            assertNull(row.pendingStaticDhPublicKeyRaw)
            assertNull(row.pendingGenerationRaw)
        }
    }

    @Test
    fun testMalformedCurrentSchemaFailsClosed() {
        val dbFile = tempFolder.newFile("malformed_peer.db")
        val conn = DriverManager.getConnection("jdbc:sqlite:" + dbFile.absolutePath)
        conn.use { c ->
            // Create table with missing CHECK constraints
            c.createStatement().use {
                it.execute("CREATE TABLE peer_identities (node_id BLOB PRIMARY KEY, signing_public_key BLOB)")
                it.execute("PRAGMA user_version = 1")
            }
        }

        try {
            JdbcPeerIdentityStore(dbFile)
            fail("Expected schema validation exception on malformed DDL")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("mismatch"))
        }
    }

    @Test
    fun testFutureVersionFailsClosed() {
        val dbFile = tempFolder.newFile("future_peer.db")
        val conn = DriverManager.getConnection("jdbc:sqlite:" + dbFile.absolutePath)
        conn.use { c ->
            c.createStatement().use {
                it.execute("PRAGMA user_version = 2")
            }
        }

        try {
            JdbcPeerIdentityStore(dbFile)
            fail("Expected failure on future user_version 2")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("future peer store schema"))
        }
    }

    @Test
    fun testUnversionedExistingTableFailsClosed() {
        val dbFile = tempFolder.newFile("unversioned_peer.db")
        val conn = DriverManager.getConnection("jdbc:sqlite:" + dbFile.absolutePath)
        conn.use { c ->
            c.createStatement().use {
                it.execute(PeerIdentitySchema.CREATE_TABLE_SQL)
                it.execute("PRAGMA user_version = 0")
            }
        }

        try {
            JdbcPeerIdentityStore(dbFile)
            fail("Expected fail-closed on unversioned existing table")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("Unversioned existing peer_identities table found"))
        }
    }

    @Test
    fun testRowImmutabilityAndDefensiveCopying() {
        val nodeId = ByteArray(16) { 0x01 }
        val signPub = ByteArray(32) { 0x02 }
        val staticPub = ByteArray(32) { 0x03 }
        val pendStatic = ByteArray(32) { 0x04 }

        val row = PeerIdentityRow(
            nodeIdRaw = nodeId,
            signingPublicKeyRaw = signPub,
            acceptedStaticDhPublicKeyRaw = staticPub,
            acceptedGenerationRaw = 5L,
            trustCodeRaw = 1,
            pendingStaticDhPublicKeyRaw = pendStatic,
            pendingGenerationRaw = 10L
        )

        // Mutate inputs
        nodeId[0] = 0xFF.toByte()
        signPub[0] = 0xFF.toByte()
        staticPub[0] = 0xFF.toByte()
        pendStatic[0] = 0xFF.toByte()

        assertEquals(0x01.toByte(), row.nodeIdRaw[0])
        assertEquals(0x02.toByte(), row.signingPublicKeyRaw[0])
        assertEquals(0x03.toByte(), row.acceptedStaticDhPublicKeyRaw[0])
        assertEquals(0x04.toByte(), row.pendingStaticDhPublicKeyRaw!![0])

        // Mutate getter output
        val gottenNodeId = row.nodeIdRaw
        gottenNodeId[0] = 0xAA.toByte()
        assertEquals(0x01.toByte(), row.nodeIdRaw[0])
    }

    // MARK: - Key-State Resolution Matrix (K1 - K9)

    @Test
    fun testK1_KeyAbsentAndDbAbsent_GeneratesAndPersists() {
        var generateCalled = 0
        var persistedValue: String? = null
        val generatedKey = ByteArray(32) { 0x42 }

        val result = PeerStoreKeyState.resolve(
            dbExists = false,
            storedEncodedKey = null,
            generate = {
                generateCalled++
                generatedKey
            },
            persist = { encoded ->
                persistedValue = encoded
                true
            }
        )

        assertEquals(1, generateCalled)
        assertArrayEquals(generatedKey, result)
        assertNotNull(persistedValue)
        val decoded = java.util.Base64.getDecoder().decode(persistedValue)
        assertArrayEquals(generatedKey, decoded)
    }

    @Test
    fun testK2_KeyPresentAndDbAbsent_DecodesAndDoesNotGenerate() {
        var generateCalled = 0
        var persistCalled = 0
        val existingKey = ByteArray(32) { 0x55 }
        val encoded = java.util.Base64.getEncoder().encodeToString(existingKey)

        val result = PeerStoreKeyState.resolve(
            dbExists = false,
            storedEncodedKey = encoded,
            generate = {
                generateCalled++
                ByteArray(32)
            },
            persist = {
                persistCalled++
                true
            }
        )

        assertEquals(0, generateCalled)
        assertEquals(0, persistCalled)
        assertArrayEquals(existingKey, result)
    }

    @Test
    fun testK3_KeyPresentAndDbPresent_DecodesAndDoesNotGenerate() {
        var generateCalled = 0
        var persistCalled = 0
        val existingKey = ByteArray(32) { 0x77 }
        val encoded = java.util.Base64.getEncoder().encodeToString(existingKey)

        val result = PeerStoreKeyState.resolve(
            dbExists = true,
            storedEncodedKey = encoded,
            generate = {
                generateCalled++
                ByteArray(32)
            },
            persist = {
                persistCalled++
                true
            }
        )

        assertEquals(0, generateCalled)
        assertEquals(0, persistCalled)
        assertArrayEquals(existingKey, result)
    }

    @Test
    fun testK4_KeyAbsentAndDbPresent_FailsClosed() {
        var generateCalled = 0
        var persistCalled = 0

        try {
            PeerStoreKeyState.resolve(
                dbExists = true,
                storedEncodedKey = null,
                generate = {
                    generateCalled++
                    ByteArray(32)
                },
                persist = {
                    persistCalled++
                    true
                }
            )
            fail("Expected fail-closed when key is absent and DB exists")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("refusing to recreate key"))
            assertEquals(0, generateCalled)
            assertEquals(0, persistCalled)
        }
    }

    @Test
    fun testK5_MalformedBase64_FailsClosed() {
        var generateCalled = 0
        var persistCalled = 0

        try {
            PeerStoreKeyState.resolve(
                dbExists = false,
                storedEncodedKey = "%%%not-valid-base64%%%",
                generate = {
                    generateCalled++
                    ByteArray(32)
                },
                persist = {
                    persistCalled++
                    true
                }
            )
            fail("Expected failure on malformed Base64")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("Malformed Base64"))
            assertEquals(0, generateCalled)
            assertEquals(0, persistCalled)
        }
    }

    @Test
    fun testK6_KeyTooShort_FailsClosed() {
        val shortKey = ByteArray(31) { 0x11 }
        val encoded = java.util.Base64.getEncoder().encodeToString(shortKey)

        try {
            PeerStoreKeyState.resolve(
                dbExists = false,
                storedEncodedKey = encoded,
                generate = { ByteArray(32) },
                persist = { true }
            )
            fail("Expected failure for 31-byte key")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("must be 32 bytes, got 31"))
        }
    }

    @Test
    fun testK7_KeyTooLong_FailsClosed() {
        val longKey = ByteArray(33) { 0x11 }
        val encoded = java.util.Base64.getEncoder().encodeToString(longKey)

        try {
            PeerStoreKeyState.resolve(
                dbExists = false,
                storedEncodedKey = encoded,
                generate = { ByteArray(32) },
                persist = { true }
            )
            fail("Expected failure for 33-byte key")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("must be 32 bytes, got 33"))
        }
    }

    @Test
    fun testK8_PersistenceFailure_FailsClosed() {
        var generateCalled = 0

        try {
            PeerStoreKeyState.resolve(
                dbExists = false,
                storedEncodedKey = null,
                generate = {
                    generateCalled++
                    ByteArray(32) { 0x01 }
                },
                persist = { false } // Commit failed!
            )
            fail("Expected failure when persistence fails")
        } catch (e: IllegalStateException) {
            assertTrue(e.message!!.contains("Failed to synchronously commit"))
            assertEquals(1, generateCalled)
        }
    }

    @Test
    fun testK9_KeyPreferenceNamespaceIsolation() {
        assertEquals("godstone_peer_identity_store_key", PeerIdentitySchema.KEY_PREFS)
        assertFalse(PeerIdentitySchema.KEY_PREFS == "godstone_store_key")
    }
}
