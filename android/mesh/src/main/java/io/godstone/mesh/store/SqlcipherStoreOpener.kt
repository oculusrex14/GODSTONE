package io.godstone.mesh.store

// ---------------------------------------------------------------------------
// T29 platform-integration adapter (android). Binds a concrete SQLCipher native
// binding to the RawStoreOpener seam and DELEGATES every decision to the pure
// StoreOpener classifier, so the real device store-open path and the JVM court
// share ONE classification law. The concrete device binding (the SQLCipher
// SQLiteOpenHelper in MessageStore) is supplied by the runtime composition; the
// physical wrong-key / corruption bytes on the real native are device evidence
// (deferred to T73-T75). This adapter carries no crypto of its own: it maps the
// native facts onto a StoreHandle and hands them to StoreOpener, which decides
// Available vs a fail-closed typed fault -- so a plain (cipherEnabled=false)
// binding can NEVER silently compose to a healthy Available store.
// ---------------------------------------------------------------------------

/** Facts the native reports about an opened database (the header version drives the version gate). */
class NativeOpenFacts internal constructor(
    val journalMode: String,
    val headerVersion: Int,
)

/** The low-level cipher binding the device SQLCipher adapter implements. */
interface CipherNativeBinding {
    /** PRAGMA cipher_enabled as the native reports it; false for a plain (un-encrypted) SQLite build. */
    val cipherEnabled: Boolean
    /** Whether the private DB/WAL/SHM are excluded from platform backup by policy. */
    val backupRulesExcludeDatabase: Boolean
    /** Open the (already key-supplied) database, THROWING an SQLCipher-shaped fault on any failure. */
    fun openEncrypted(path: String, key: ByteArray): NativeOpenFacts
}

/** A [RawStoreOpener] over a [CipherNativeBinding], delegating classification to [StoreOpener]. */
class SqlcipherStoreOpener(
    private val binding: CipherNativeBinding,
    private val path: String,
    private val key: ByteArray,
) : RawStoreOpener {

    private class MappedHandle(
        override val encryptedAtRest: Boolean,
        override val backupExcluded: Boolean,
        override val journalMode: String,
        val facts: NativeOpenFacts,
    ) : StoreHandle

    override fun openRaw(): StoreHandle {
        val facts = binding.openEncrypted(path, key)                 // throws SQLCipher-shaped faults the classifier maps
        return MappedHandle(
            encryptedAtRest = binding.cipherEnabled,                  // a plain binding reports false -> StoreOpener rejects
            backupExcluded = binding.backupRulesExcludeDatabase,     // backup-included -> StoreOpener rejects
            journalMode = facts.journalMode,
            facts = facts,
        )
    }

    override fun schemaVersion(handle: StoreHandle): Int = (handle as MappedHandle).facts.headerVersion
}
