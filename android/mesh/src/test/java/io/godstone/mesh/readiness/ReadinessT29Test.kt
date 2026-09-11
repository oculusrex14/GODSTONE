package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// T29 - the CANONICAL designated regression court (android). The manifest's
// required_regression_paths names this file; the narrow filter is
// `--tests *ReadinessT29Test*`. It drives the T29 typed store-open contract
// (store/StoreOpener) through an injected RawStoreOpener that raises the
// SQLCipher-shaped faults deterministically, so the laws are EXECUTED: happy
// open is Available (encrypted-at-rest, backup-excluded); wrong key is Locked
// and NEVER an empty healthy store; malformed header is Corrupt; key-acquisition
// failure is Unavailable; an unknown version is UnsupportedVersion; an
// unclassified fault fails CLOSED; a plain (unencrypted) store is REJECTED by the
// encrypted-at-rest predicate (the T29-SM1 target); write faults are typed and
// an interrupted atomic enqueue rolls back with no partial row. The physical
// wrong-key/corruption bytes on the real native are device evidence (T73-T75).
// ---------------------------------------------------------------------------

import io.godstone.mesh.store.RawStoreOpener
import io.godstone.mesh.store.SUPPORTED_STORE_VERSION
import io.godstone.mesh.store.StoreHandle
import io.godstone.mesh.store.StoreOpenResult
import io.godstone.mesh.store.StoreOpener
import io.godstone.mesh.store.StoreTransactionResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadinessT29Test {

    private class TestHandle(
        override val encryptedAtRest: Boolean,
        override val backupExcluded: Boolean,
        override val journalMode: String = "wal",
    ) : StoreHandle

    private class FakeOpener(private val body: () -> StoreHandle, private val version: Int = SUPPORTED_STORE_VERSION) : RawStoreOpener {
        override fun openRaw(): StoreHandle = body()
        override fun schemaVersion(handle: StoreHandle): Int = version
    }

    private fun goodOpener(version: Int = SUPPORTED_STORE_VERSION) =
        FakeOpener({ TestHandle(encryptedAtRest = true, backupExcluded = true) }, version)

    private fun throwing(message: String) = FakeOpener({ throw IllegalStateException(message) })

    // (1) happy path: an encrypted, backup-excluded store at the supported version opens Available
    @Test
    fun testOpenHappyPathYieldsAvailableEncryptedBackupExcludedStore() {
        val r = StoreOpener.open(goodOpener())
        assertTrue("a real encrypted store opens Available", r is StoreOpenResult.Available)
        val h = (r as StoreOpenResult.Available).handle
        assertTrue("the handle reports encryption at rest", h.encryptedAtRest)
        assertTrue("the handle reports backup exclusion", h.backupExcluded)
    }

    // (2) wrong key is Locked, and NEVER surfaces as an empty healthy store
    @Test
    fun testWrongKeyFaultIsLockedAndNeverAnEmptyHealthyStore() {
        val r = StoreOpener.open(throwing("file is not a database or is not encrypted"))
        assertTrue("a wrong-key open is Locked", r is StoreOpenResult.Locked)
        assertFalse("a wrong-key open must never yield a healthy Available store", r is StoreOpenResult.Available)
    }

    // (3) a malformed header is Corrupt
    @Test
    fun testMalformedHeaderFaultIsCorrupt() {
        val r = StoreOpener.open(throwing("database file header is malformed / not well formed"))
        assertTrue("a malformed header is Corrupt", r is StoreOpenResult.Corrupt)
        assertFalse(r is StoreOpenResult.Available)
    }

    // (4) key-acquisition failure is Unavailable (distinct from a corrupt/locked store)
    @Test
    fun testKeyAcquisitionFaultIsUnavailable() {
        val r = StoreOpener.open(throwing("keystore key acquisition failed: no key available"))
        assertTrue("a key-acquisition failure is Unavailable", r is StoreOpenResult.Unavailable)
        assertFalse(r is StoreOpenResult.Available)
    }

    // (5) an unknown schema version is UnsupportedVersion, carrying the found/supported versions
    @Test
    fun testUnknownSchemaVersionIsUnsupportedVersion() {
        val r = StoreOpener.open(goodOpener(version = 7))
        assertTrue("an unknown version is UnsupportedVersion", r is StoreOpenResult.UnsupportedVersion)
        val uv = r as StoreOpenResult.UnsupportedVersion
        assertEquals("the found version is reported", 7, uv.found)
        assertEquals("the supported version is reported", SUPPORTED_STORE_VERSION, uv.supported)
    }

    // (6) an unclassified fault fails CLOSED (never Available, never an empty healthy store)
    @Test
    fun testUnclassifiedFaultFailsClosedNeverAvailable() {
        val r = StoreOpener.open(throwing("a mystery io failure with no recognised signature"))
        assertFalse("an unclassified fault must not be reported as a healthy Available store", r is StoreOpenResult.Available)
        assertTrue("an unclassified fault fails closed to a terminal result", r is StoreOpenResult.Corrupt)
    }

    // (7) the encrypted-at-rest predicate is REQUIRED -- a plain (or backup-included) store is rejected
    @Test
    fun testEncryptedAtRestIsRequiredAndPlainStoreRejected() {
        val plain = StoreOpener.open(FakeOpener({ TestHandle(encryptedAtRest = false, backupExcluded = true) }))
        assertFalse("a plain SQLite store must NOT be accepted as a healthy Available", plain is StoreOpenResult.Available)
        assertTrue("a plain store is rejected (Locked) by the encrypted-at-rest predicate", plain is StoreOpenResult.Locked)
        val inBackup = StoreOpener.open(FakeOpener({ TestHandle(encryptedAtRest = true, backupExcluded = false) }))
        assertFalse("a backup-included store must NOT be accepted as a healthy Available", inBackup is StoreOpenResult.Available)
        assertTrue("a backup-included store is rejected", inBackup is StoreOpenResult.Locked)
    }

    // (8) write faults are typed, and an interrupted atomic enqueue rolls back leaving no partial row
    @Test
    fun testWriteFaultsAreClassifiedAndAtomicEnqueueRollsBackFailClosed() {
        assertTrue(StoreOpener.classifyTransaction(RuntimeException("no space left on device (errno 28)")) is StoreTransactionResult.FailedDiskFull)
        assertTrue(StoreOpener.classifyTransaction(RuntimeException("attempt to write a read-only transaction")) is StoreTransactionResult.FailedReadOnly)
        assertTrue(StoreOpener.classifyTransaction(RuntimeException("database file is corrupt")) is StoreTransactionResult.FailedCorrupt)
        assertTrue(StoreOpener.classifyTransaction(RuntimeException("a transient glitch")) is StoreTransactionResult.RolledBack)

        val staged = mutableListOf("alpha", "bravo")
        val res = StoreOpener.runAtomic(staged) { list ->
            list.add("charlie")                                  // staged, then interrupted
            throw IllegalStateException("disk full during commit")
        }
        assertTrue("a disk-full commit is FailedDiskFull, not a silent success", res is StoreTransactionResult.FailedDiskFull)
        assertEquals("the interrupted enqueue left NO partial row (rolled back)", listOf("alpha", "bravo"), staged.toList())

        val staged2 = mutableListOf<Int>()
        val res2 = StoreOpener.runAtomic(staged2) { list -> list.add(1); list.add(2) }
        assertTrue("an unbroken commit reports Committed", res2 is StoreTransactionResult.Committed)
        assertEquals("a committed enqueue keeps both rows", 2, staged2.size)
    }
}
