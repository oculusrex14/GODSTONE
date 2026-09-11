package io.godstone.mesh.store

// ---------------------------------------------------------------------------
// T29 CONTRACT - the typed, fail-closed result surface for opening the private
// store, plus the PURE fault classifier the device SQLCipher adapter reuses.
//
// Host JDBC tests do not demonstrate SQLCipher behaviour, and a key/disk fault
// must NEVER surface as an empty healthy store. So the open path returns a
// TYPED result, and classification is total + fail-closed: any fault maps to a
// non-Available outcome, and an opened-but-not-encrypted-at-rest or a
// backup-included store is rejected -- it is not a healthy Available store.
//
//   StoreOpenResult{Available, Locked, Corrupt, Unavailable, UnsupportedVersion}
//   StoreTransactionResult{Committed, RolledBack, FailedDiskFull, FailedReadOnly, FailedCorrupt}
//
// The concrete device adapter (SqlcipherStoreDb) supplies the real [RawStoreOpener];
// the JVM court injects a deterministic fake into the SAME classifier, so the
// classification law is executed, not narrated. Peer-trust and message stores stay
// separate, and the private DB/WAL/SHM are excluded from backup. No frozen
// store/wire/identity contract is altered here.
// ---------------------------------------------------------------------------

/** The at-rest invariants a successfully opened private store must report. */
interface StoreHandle {
    /** True only when the bytes are encrypted at rest (SQLCipher), never plain SQLite. */
    val encryptedAtRest: Boolean
    /** True only when DB/WAL/SHM are excluded from any platform backup. */
    val backupExcluded: Boolean
    /** The journal mode in force (e.g. "wal"). */
    val journalMode: String
}

sealed class StoreOpenResult {
    class Available(val handle: StoreHandle) : StoreOpenResult()
    /** Wrong key / cannot decrypt / read-only locked / "file is not a database". */
    object Locked : StoreOpenResult()
    /** Malformed header / not well formed / irreparably corrupt. */
    object Corrupt : StoreOpenResult()
    /** Key acquisition failed / no keystore / cannot obtain the passphrase. */
    object Unavailable : StoreOpenResult()
    /** The on-disk schema version is newer/older than the adapter supports. */
    class UnsupportedVersion(val found: Int, val supported: Int) : StoreOpenResult()
}

sealed class StoreTransactionResult {
    object Committed : StoreTransactionResult()
    object RolledBack : StoreTransactionResult()
    object FailedDiskFull : StoreTransactionResult()
    object FailedReadOnly : StoreTransactionResult()
    object FailedCorrupt : StoreTransactionResult()
}

/** Signals an unsupported schema version read from the opened header. */
class UnsupportedVersionSignal(val found: Int) : RuntimeException("unsupported store schema version " + found)

/** The low-level open seam the concrete device adapter implements; injected so the JVM court drives deterministic faults. */
interface RawStoreOpener {
    /** Perform the real open, returning a handle, or THROWING an SQLCipher-shaped fault. */
    fun openRaw(): StoreHandle
    /** Report the schema version the opened header carries. */
    fun schemaVersion(handle: StoreHandle): Int
}

/** The committed schema version the adapter supports. */
const val SUPPORTED_STORE_VERSION: Int = 2

/** Pure, total, fail-closed classification -- the contract the device adapter reuses verbatim. */
object StoreOpener {

    /** Open through [opener]; any fault maps to a non-Available outcome; an un-encrypted/backup-included store is rejected. */
    fun open(opener: RawStoreOpener, supportedVersion: Int = SUPPORTED_STORE_VERSION): StoreOpenResult {
        val handle = try {
            opener.openRaw()
        } catch (t: Throwable) {
            return classify(t, supportedVersion)               // fail-closed: a thrown open is never a healthy store
        }
        // the at-rest invariants are REQUIRED for a healthy Available; reject a plain or backup-included store
        if (!handle.encryptedAtRest || !handle.backupExcluded) return StoreOpenResult.Locked
        val v = try {
            opener.schemaVersion(handle)
        } catch (t: Throwable) {
            return classify(t, supportedVersion)
        }
        if (v != supportedVersion) return StoreOpenResult.UnsupportedVersion(v, supportedVersion)
        return StoreOpenResult.Available(handle)
    }

    /** Map a low-level open fault to its typed result. Total: the else arm fails CLOSED to the safest result. */
    fun classify(t: Throwable, supportedVersion: Int = SUPPORTED_STORE_VERSION): StoreOpenResult {
        if (t is UnsupportedVersionSignal) return StoreOpenResult.UnsupportedVersion(t.found, supportedVersion)
        val m = (t.message ?: "").lowercase()
        return when {
            containsAny(m, "keystore", "key acquisition", "no key", "cannot obtain key", "key not available", "keyservice") -> StoreOpenResult.Unavailable
            containsAny(m, "malformed", "corrupt", "not well formed", "bad header", "header too short") -> StoreOpenResult.Corrupt
            containsAny(m, "not a database", "wrong key", "read-only", "read only", "locked", "unable to open database file") -> StoreOpenResult.Locked
            else -> StoreOpenResult.Corrupt                     // an unclassified store fault fails CLOSED
        }
    }

    /** Map a write/transaction fault to its typed result. Total; the else arm is a clean rollback. */
    fun classifyTransaction(t: Throwable): StoreTransactionResult {
        val m = (t.message ?: "").lowercase()
        return when {
            containsAny(m, "disk full", "no space", "storage full", "enospc", "errno 28") -> StoreTransactionResult.FailedDiskFull
            containsAny(m, "read-only", "read only", "attempt to write a read-only") -> StoreTransactionResult.FailedReadOnly
            containsAny(m, "corrupt", "malformed", "not a database", "bad header") -> StoreTransactionResult.FailedCorrupt
            else -> StoreTransactionResult.RolledBack
        }
    }

    /**
     * Fail-closed atomic enqueue: apply [block] to [staged] and report [StoreTransactionResult.Committed] only on an
     * unbroken block; on ANY throw, restore [staged] to its pre-image (no partial effect) and report the classified fault.
     */
    fun <T> runAtomic(staged: MutableList<T>, block: (MutableList<T>) -> Unit): StoreTransactionResult {
        val preImage = staged.toMutableList()
        try {
            block(staged)
        } catch (t: Throwable) {
            staged.clear()
            staged.addAll(preImage)                              // no partial committed row survives
            return classifyTransaction(t)
        }
        return StoreTransactionResult.Committed
    }

    private fun containsAny(m: String, vararg needles: String): Boolean {
        for (n in needles) if (m.contains(n)) return true
        return false
    }
}
