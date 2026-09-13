package io.godstone.core.archive

import androidx.sqlite.SQLiteDriver
import java.io.File

/**
 * The staged, verified, bounded installer/verifier for the on-device
 * Archive (blueprint s17).
 *
 * The old path served a cached database merely because the file
 * existeth. That is no proof of anything: a truncated copy, a flipped
 * page and a stale build all exist too. This installer replaces that
 * law with a road every byte must walk:
 *
 *   1. the candidate bytes are read (from the shipped asset, or from a
 *      caller-supplied file) and bounded -- nothing larger than
 *      [MAX_BUNDLE_BYTES] ever entereth;
 *   2. when a trusted manifest is at hand, the candidate must match it
 *      exactly -- size and SHA-256 both -- or it is Rejected and the
 *      bytes already installed are left untouched;
 *   3. the candidate is staged under the install root (never beside the
 *      live file), flushed, and openedd read-only through the bundled
 *      driver for the FULL probe: required tables, the FTS5 canary and
 *      the integrity check all must answer (see [ArchiveDatabase
 *      .openReadOnly]);
 *   4. only a probe-surviving candidate is promoted, by one atomic
 *      rename within the same filesystem, into the current slot; the
 *      record file (what was believed) is written beside it;
 *   5. a failed promotion destroyeth only the installer's own staging
 *      copy -- the old bytes always survive a failed update;
 *   6. serving is never an existence check: [status] recomputeth the
 *      digest of the live bytes, compareth it against the record, and
 *      runneth the engine probe again. A cache that cannot validate
 *      reporteth Unavailable with its cause named, and the bytes are
 *      preserved for the next install to mend.
 *
 * Concurrency: promotion is serialised by the [promotion] monitor, so
 * parallel install threads cannot interleave their renames; readers
 * always observe one whole database -- either the old file or the new
 * one, never a half-written thing -- because rename within a filesystem
 * is atomic and staging names are unique per install.
 */
sealed class InstallOutcome {
    /** The current slot holds provably-good bytes; serve them. */
    data class Selected(val sha256: String, val bytes: Long) : InstallOutcome()

    /** The current slot held stale or unverifiable bytes; they were
     * replaced by these freshly proven ones. */
    data class Refreshed(val sha256: String, val bytes: Long) : InstallOutcome()

    /** This candidate was refused. Anything already installed was left
     * exactly as it was. */
    data class Rejected(val cause: String) : InstallOutcome()

    /** Nothing can currently be served from this root, for this reason. */
    data class Unavailable(val reason: String) : InstallOutcome()
}

class ArchiveInstaller(
    private val root: File,
    private val driverProvider: () -> SQLiteDriver = { ArchiveDrivers.required() },
    private val clock: () -> Long = { System.currentTimeMillis() },
) {
    private val promotion = Any()
    private var stagingCounter = 0L

    companion object {
        const val CURRENT_DIR_NAME: String = "current"
        const val STAGING_DIR_NAME: String = "staging"
        const val ARCHIVE_FILE_NAME: String = "archive.db"
        const val RECORD_FILE_NAME: String = "archive.record.json"

        /** The install bound: no candidate larger than this ever passeth
         * (the LARGE-tier archive is far below it; a runaway or hostile
         * candidate does not). */
        const val MAX_BUNDLE_BYTES: Long = 512L * 1024L * 1024L
    }

    fun currentFile(): File = File(File(root, CURRENT_DIR_NAME), ARCHIVE_FILE_NAME)

    fun recordFile(): File = File(File(root, CURRENT_DIR_NAME), RECORD_FILE_NAME)

    /**
     * Install [bundleSource]'s bytes into the current slot, believing
     * [manifest] when it is given. [bundleSource] may be called at most
     * once per install; returning null means the bundle is missing.
     */
    fun install(bundleSource: () -> ByteArray?, manifest: ArchiveManifestFacts?): InstallOutcome {
        if (!root.isDirectory && !root.mkdirs() && !root.isDirectory) {
            return InstallOutcome.Unavailable("install root does not exist and could not be made: $root")
        }
        val bundle = bundleSource()
            ?: return InstallOutcome.Rejected("bundle missing: the source could not be read")
        if (bundle.isEmpty()) {
            return InstallOutcome.Rejected("bundle empty: zero bytes carry no database")
        }
        if (bundle.size.toLong() > MAX_BUNDLE_BYTES) {
            return InstallOutcome.Rejected(
                "bundle exceeds the install bound: " + bundle.size + " bytes against " +
                    MAX_BUNDLE_BYTES)
        }
        if (manifest != null) {
            if (bundle.size.toLong() != manifest.bytes) {
                return InstallOutcome.Rejected(
                    "bundle size does not match the trusted manifest: " +
                        bundle.size + " against " + manifest.bytes)
            }
        }
        val digest = Sha256.hexOf(bundle)
        if (manifest != null && digest != manifest.sha256) {
            return InstallOutcome.Rejected(
                "bundle digest does not match the trusted manifest: computed " +
                    digest.take(16) + "..., manifest believes " +
                    manifest.sha256.take(16) + "...")
        }

        // Stage: a private file, a unique name, an honest fsync.
        val staging = File(root, STAGING_DIR_NAME)
        if (!staging.isDirectory && !staging.mkdirs() && !staging.isDirectory) {
            return InstallOutcome.Unavailable("staging directory could not be made: $staging")
        }
        val seq: Long
        synchronized(promotion) { seq = ++stagingCounter }
        val staged = File(
            staging,
            "candidate-" + clock() + "-" + System.identityHashCode(this) + "-" + seq + ".db",
        )
        var stagedOk = false
        try {
            staged.outputStream().use { out ->
                out.write(bundle)
                out.flush()
                out.fd.sync()
            }
            stagedOk = true
        } catch (exc: Throwable) {
            staged.delete()
            return InstallOutcome.Unavailable(
                "staging write failed: " + (exc.message ?: exc::class.simpleName))
        }
        if (!staged.isFile) {
            return InstallOutcome.Unavailable("staged candidate vanished before it could be probed")
        }
        // The engine probe -- the candidate must answer read-only, complete.
        val fault = runCatching {
            ArchiveDatabase.verify(staged, driverProvider())
        }.fold(
            onSuccess = { it },
            onFailure = { exc -> "the probe threw: " + (exc.message ?: exc::class.simpleName) },
        )
        if (fault != null) {
            staged.delete()
            return InstallOutcome.Rejected("staged probe failed: $fault")
        }

        // Promote -- or keep the old bytes if the promotion itself falls.
        val result = synchronized(promotion) {
            val current = currentFile()
            val previousExisted = current.isFile
            val parent = current.parentFile
            if (!parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) {
                staged.delete()
                InstallOutcome.Unavailable("current directory could not be made: $parent")
            } else if (
                current.isFile && recordFile().isFile &&
                runCatching { ArchiveRecord.fromJson(recordFile().readText()) }
                    .getOrNull()?.sha256 == digest &&
                current.length() == bundle.size.toLong() &&
                runCatching { Sha256.hexOf(current) }.getOrNull() == digest
            ) {
                // The very same bytes are already installed and recorded.
                staged.delete()
                InstallOutcome.Selected(digest, bundle.size.toLong())
            } else if (!staged.renameTo(current)) {
                staged.delete()
                InstallOutcome.Rejected(
                    "promotion failed: the staged candidate could not be renamed into place; " +
                        "the previously installed bytes, if any, stand untouched")
            } else {
                val record = ArchiveRecord(
                    schema = ArchiveRecord.RECORD_SCHEMA,
                    sha256 = digest,
                    bytes = bundle.size.toLong(),
                    origin = manifest?.fileName ?: "asset",
                    selectedAtMs = clock(),
                )
                runCatching { recordFile().writeText(record.toCanonJson()) }
                    .onFailure { exc ->
                        return@synchronized InstallOutcome.Unavailable(
                            "record write failed after promotion: " +
                                (exc.message ?: exc::class.simpleName))
                    }
                if (previousExisted) {
                    InstallOutcome.Refreshed(digest, bundle.size.toLong())
                } else {
                    InstallOutcome.Selected(digest, bundle.size.toLong())
                }
            }
        }
        return result
    }

    /**
     * What may be served right now from this root. This is not an
     * existence check: the digest of the live bytes is recomputed, the
     * record is consulted, and the full engine probe runneth again.
     * A cache that failseth any of these reporteth Unavailable, and no
     * byte is destroyed in the telling.
     */
    fun status(manifest: ArchiveManifestFacts? = null): InstallOutcome {
        val current = currentFile()
        if (!current.isFile) {
            return InstallOutcome.Unavailable("no archive is installed under $root")
        }
        val recordFileHandle = recordFile()
        if (!recordFileHandle.isFile) {
            return InstallOutcome.Unavailable(
                "the install record is missing beside the bytes: " + recordFileHandle)
        }
        val record = runCatching { ArchiveRecord.fromJson(recordFileHandle.readText()) }.getOrNull()
            ?: return InstallOutcome.Unavailable("the install record is unreadable or stale-shaped")
        val digest = runCatching { Sha256.hexOf(current) }.getOrNull()
            ?: return InstallOutcome.Unavailable("the installed bytes could not be digested")
        if (digest != record.sha256) {
            return InstallOutcome.Unavailable(
                "cache integrity: the installed bytes do not match their record")
        }
        if (current.length() != record.bytes) {
            return InstallOutcome.Unavailable(
                "cache integrity: the installed length does not match the record")
        }
        if (manifest != null && digest != manifest.sha256) {
            return InstallOutcome.Unavailable(
                "the installed archive is not the one the trusted manifest believes")
        }
        val fault = runCatching {
            ArchiveDatabase.verify(current, driverProvider())
        }.fold(
            onSuccess = { it },
            onFailure = { exc -> "the probe threw: " + (exc.message ?: exc::class.simpleName) },
        )
        if (fault != null) {
            return InstallOutcome.Unavailable("cache probe failed: $fault")
        }
        return InstallOutcome.Selected(digest, record.bytes)
    }
}
