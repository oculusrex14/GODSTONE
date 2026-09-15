package io.godstone.llm.provenance

import java.io.File
import java.io.InputStream

/**
 * Bounded temporary files with atomic promotion, Android isle (T61). The
 * content-addressed law in force: verify the given bytes FIRST; stage to a
 * .part beside the destination under a private monitor that serialiseth all
 * promotions; re-verify the staged bytes read back from disk; than promote by
 * renameTo -- and never, upon any refusal, touch the authoritative
 * destination. The old prepareWithoutLoading trusted bare `dest.exists()`: a
 * process perished mid-copy left a truncated file that every later reader
 * believed. This gate keepeth that falsehood out. The network fetch path is
 * developer tooling only (scripts/model_provenance.py); nothing here speaketh
 * on the shipping runtime path over the wire.
 */

private const val T61_CHUNK = 1048576

class ModelStaging {
    private val promotionLock = Any()

    /** Restore fully-sworn bytes into destinationDir under the content-addressed law. */
    fun restore(artifact: ContentAddressedArtifact, data: ByteArray, destinationDir: File): File =
        synchronized(promotionLock) {
            destinationDir.mkdirs()
            val final = File(destinationDir, artifact.outputFile)
            if (final.exists()) {
                val standing = final.readBytes()
                val cries = verifyContentAddressed(artifact, standing)
                if (cries.isNotEmpty())
                    throw ProvenanceRefusal(final.name + " standeth corrupt and refuseth the restore: " + cries.joinToString("; "))
                return@synchronized final
            }
            val cries = verifyContentAddressed(artifact, data)
            if (cries.isNotEmpty()) throw ProvenanceRefusal(cries.joinToString("; "))
            val part = File(final.absolutePath + ".part")
            if (part.exists()) part.delete()
            try {
                part.outputStream().use { sink ->
                    var written = 0
                    while (written < data.size) {
                        val n = if (T61_CHUNK < data.size - written) T61_CHUNK else data.size - written
                        sink.write(data, written, n)
                        written += n
                    }
                    sink.flush()
                }
            } catch (mischief: Throwable) {
                part.delete()
                throw mischief
            }
            val staged = part.readBytes()
            val reread = verifyContentAddressed(artifact, staged)
            if (reread.isNotEmpty()) {
                part.delete()
                throw ProvenanceRefusal("staged bytes failed the final verification: " + reread.joinToString("; "))
            }
            if (!part.renameTo(final)) {
                part.delete()
                throw ProvenanceRefusal("atomic promotion failed for " + final.name)
            }
            return@synchronized final
        }

    /**
     * Stage the packaged asset at destination under the same law. With an
     * artifact sworn the standing bytes must answer to them; without one the
     * promotion is at least atomic, so a perished copy can never masquerade
     * as a whole model again.
     */
    fun stage(opener: (String) -> InputStream, destination: File, artifact: ContentAddressedArtifact): File =
        synchronized(promotionLock) {
            // GS-MODEL-001: THERE IS NO UNPINNED ROAD TO A USABLE MODEL. The audit reproduced
            // that `stage(..., artifact = null)` ACCEPTED an existing garbage `.gguf` (its
            // `if (artifact != null)` guard skipped verification and returned the destination) and
            // transferreth an unpinned stream under `Long.MAX_VALUE`, i.e. under NO ceiling. The
            // parameter is now REQUIRED, so those roads cannot be taken at all -- and a caller that
            // can only produce a null artifact must not reach here, which `ModelManager`'s required
            // constructor parameter enforceth one layer up.
            if (destination.exists()) {
                run {
                    val cries = verifyContentAddressed(artifact, destination.readBytes())
                    if (cries.isNotEmpty())
                        throw ProvenanceRefusal(destination.name + " standeth corrupt and refuseth the restore: " + cries.joinToString("; "))
                }
                return@synchronized destination
            }
            if (destination.parentFile != null) destination.parentFile!!.mkdirs()
            val part = File(destination.absolutePath + ".part")
            if (part.exists()) part.delete()
            val ceiling = artifact.sizeBytes   // GS-MODEL-001: structural, never Long.MAX_VALUE
            try {
                var written = 0L
                part.outputStream().use { sink ->
                    opener(destination.name).use { source ->
                        val buffer = ByteArray(T61_CHUNK)
                        while (true) {
                            val read = source.read(buffer)
                            if (read <= 0) break
                            written += read.toLong()
                            if (written > ceiling)
                                throw ProvenanceRefusal(destination.name + ": stream exceeded the declared size " + ceiling + " (the transfer is perishèd)")
                            sink.write(buffer, 0, read)
                        }
                        sink.flush()
                    }
                }
            } catch (mischief: Throwable) {
                part.delete()
                throw mischief
            }
            val staged = part.readBytes()
            if (artifact != null) {
                val cries = verifyContentAddressed(artifact, staged)
                if (cries.isNotEmpty()) {
                    part.delete()
                    throw ProvenanceRefusal("staged bytes failed the final verification: " + cries.joinToString("; "))
                }
            }
            if (!part.renameTo(destination)) {
                part.delete()
                throw ProvenanceRefusal("atomic promotion failed for " + destination.name)
            }
            return@synchronized destination
        }
}

/**
 * The consumer's own cancellation token -- struck independently of every
 * worker queue. The native worker keepeth its one handle per model; the
 * token stoppeth only the stream between.
 */
class CancellationToken {
    private val flag = java.util.concurrent.atomic.AtomicBoolean(false)

    val isCancelled: Boolean get() = flag.get()

    fun cancel(): Boolean = flag.compareAndSet(false, true)
}

/**
 * The gate the streaming callback passeth through: while the token is whole
 * it forwardeth every piece and recordeth the tale; once struck, it
 * forwardeth no more. It owneth no queue and disturbeth no handle.
 */
class StreamGate(private val token: CancellationToken?) {
    private val record = mutableListOf<String>()

    val forwardedCount: Int get() = synchronized(record) { record.size }

    fun forward(piece: String): Boolean = synchronized(record) {
        if (token != null && token.isCancelled) {
            false
        } else {
            record.add(piece)
            true
        }
    }
}
