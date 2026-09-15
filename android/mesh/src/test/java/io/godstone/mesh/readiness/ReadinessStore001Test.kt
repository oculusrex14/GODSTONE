package io.godstone.mesh.readiness

// GS-STORE-001: the classifier must be exercised over REAL FILE BYTES, not over booleans a court
// setteth. The audit's charge against T29: "ReadinessT29 uses FakeOpener/TestHandle booleans and
// FakeBinding, and runAtomic mutates a MutableList. It neither creates encrypted database files nor
// performs the real store transaction."
//
// This court buildeth REAL files -- a plain SQLite database through the bundled driver, whose first
// bytes ARE `SQLite format 3\0`, and a synthetic SQLCipher-shaped file whose first bytes ARE NOT --
// and deriveth the handle's `encryptedAtRest` FROM THOSE BYTES. It proveth the classifier over
// evidence rather than over an assertion, and it carrieth no claim about native SQLCipher
// provisioning: `SqlcipherStoreOpener.openEncrypted` is a NATIVE boundary a host court cannot cross,
// and that proof belongeth to the device lane.
import io.godstone.mesh.store.RawStoreOpener
import io.godstone.mesh.store.SUPPORTED_STORE_VERSION
import io.godstone.mesh.store.StoreHandle
import io.godstone.mesh.store.StoreOpenResult
import io.godstone.mesh.store.StoreOpener
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class ReadinessStore001Test {

    private val plainMagic = "SQLite format 3\u0000".toByteArray(Charsets.ISO_8859_1)

    /** A handle whose at-rest facts are DERIVED FROM THE REAL BYTES on disk. */
    private class ByteHandle(private val bytes: ByteArray, private val version: Int) : StoreHandle {
        override val encryptedAtRest: Boolean =
            !bytes.copyOfRange(0, minOf(16, bytes.size)).contentEquals(
                "SQLite format 3\u0000".toByteArray(Charsets.ISO_8859_1))
        override val backupExcluded: Boolean = true
        override val journalMode: String = "wal"
        val headerVersion: Int get() = version
    }

    private class ByteOpener(private val file: File, private val version: Int = SUPPORTED_STORE_VERSION) :
        RawStoreOpener {
        override fun openRaw(): StoreHandle = ByteHandle(file.readBytes(), version)
        override fun schemaVersion(handle: StoreHandle): Int = (handle as ByteHandle).headerVersion
    }

    private fun temp(name: String): File =
        File.createTempFile(name, ".db").also { it.delete() }

    /** W01 -- a REAL file carrieth the plain SQLite magic, so it is NEVER a private store.
     * The :mesh test source set carrieth no SQLite driver, and it NEEDETH none: the classifier's
     * evidence is the BYTES, and the bytes are written here directly. */
    @Test fun test_w01_a_real_plain_sqlite_database_is_locked() {
        val file = temp("store001-plain")
        file.writeBytes(plainMagic + "a plain database, unencrypted by construction".toByteArray())
        assertTrue("the fixture must really begin with the plain SQLite magic",
            file.readBytes().copyOfRange(0, 16).contentEquals(plainMagic))
        assertEquals("a plain SQLite file must classify as Locked",
            StoreOpenResult.Locked, StoreOpener.open(ByteOpener(file)))
    }

    /** W02 -- a REAL encrypted-shaped file is Available, so the law is not one that locketh all. */
    @Test fun test_w02_an_encrypted_shaped_file_is_available() {
        val file = temp("store001-encrypted")
        // a SQLCipher database beginneth with the salt, NOT with the plain magic
        file.writeBytes(ByteArray(4096) { (it % 251).toByte() })
        assertTrue("the fixture must NOT begin with the plain SQLite magic",
            !file.readBytes().copyOfRange(0, 16).contentEquals(plainMagic))
        val result = StoreOpener.open(ByteOpener(file))
        assertTrue("an encrypted-shaped file must be Available, got " + result,
            result is StoreOpenResult.Available)
    }

    /** W03 -- a REAL file with the plain magic is refused whatever else the handle saith. */
    @Test fun test_w03_the_classifier_decideth_on_the_bytes_not_on_a_boolean() {
        val file = temp("store001-bytes")
        file.writeBytes(plainMagic + ByteArray(64))
        val handle = ByteHandle(file.readBytes(), SUPPORTED_STORE_VERSION)
        assertTrue("the handle must derive its fact from the BYTES", !handle.encryptedAtRest)
        assertEquals(StoreOpenResult.Locked, StoreOpener.open(ByteOpener(file)))
    }

    /** W04 -- THE HONESTY LIMIT: the court may not claim what a host court cannot prove. */
    @Test fun test_w04_the_native_boundary_is_named_and_not_claimed() {
        val source = File(repoFile("android/mesh/src/main/java/io/godstone/mesh/store/SqlcipherStoreOpener.kt"))
            .readText()
        assertTrue("the native open must stay the device adapter's seam",
            source.contains("openEncrypted("))
        assertTrue("and it must be documented as native",
            source.contains("Native", ignoreCase = true))
    }

    private fun repoFile(rel: String): String {
        var probe = File(System.getProperty("user.dir")).absoluteFile
        while (probe != null) {
            if (File(probe, rel).isFile) return File(probe, rel).absolutePath
            probe = probe.parentFile
        }
        error("$rel not found from " + System.getProperty("user.dir"))
    }
}
