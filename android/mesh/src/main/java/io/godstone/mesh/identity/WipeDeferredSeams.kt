package io.godstone.mesh.identity

import java.io.File

/**
 * GS-STORE-006: **THE EFFECTFUL SEAMS FOR A RUNTIME THAT DOES NOT YET STAND.**
 *
 * The startup barrier runs BEFORE the runtime object exists -- so at that moment IT OWNS NO PLATFORM RESOURCE: not the
 * transport, not the keystore, not the database handles. THE STARTUP RESUME MUST THEREFORE DEFER **EVERY** EFFECTFUL SEAM,
 * and these are the ones that remain, mirroring the iOS side's four (which were measured there one failure at a time: a
 * deferred filesystem was discovered only after a court's real files were deleted by the live one).
 *
 * EACH ANSWERS **A NAMED, RETRYABLE PENDING** RESULT, WHICH STOPS THE LADDER BEFORE `KEY_ERASED` -- EXACTLY WHERE A PROCESS
 * THAT HAS NOT YET OPENED ITS STORES MUST STOP, AND EXACTLY WHAT THE CARD'S STEP 6 SAYS: "on restart, resume from the
 * durable compatible journal BEFORE opening keys, databases, discovery or a new identity." THE RUNTIME THAT LATER STANDS
 * RESUMES WITH THE LIVE SEAMS, AND BECAUSE THE JOURNAL NOW CARRIES `RUNTIME_DRAINED` AS ITS OWN CHECKPOINT, THE SECOND
 * ATTEMPT CANNOT MISTAKE WORK NOT DONE FOR WORK ALREADY DONE.
 *
 * THE JOURNAL SEAM IS DELIBERATELY **NOT** DEFERRED: writing a checkpoint is DURABILITY, not destruction, and it is the
 * whole point of the startup half -- `WipeJournalDurabilityAdapter` is the journal seam, and it writes.
 */
object WipeDeferredSeams {

    /** The transport of a runtime that does not yet stand: it DRAINS NOTHING and admits nothing. */
    class DeferredTransportRuntimeSeam : TransportRuntimeSeam {
        override fun drainTransport(): RuntimeDrainReceipt = RuntimeDrainReceipt.NotDrained(REASON)
        override fun isQuiesced(): Boolean = false
        override fun fireRadio(msg: String): Boolean = false
        override fun sendVia(msg: String): Boolean = false

        companion object {
            const val REASON = "the runtime does not yet stand: no drain may be performed at the startup barrier"
        }
    }

    /** The vault of a runtime that does not yet stand: EVERY key answereth a named, retryable pending failure. */
    class DeferredKeyVaultSeam : KeyVaultSeam {
        override fun eraseKey(name: String): KeyDeletionResult =
            // NEVER Deleted (a claim about an act nobody performed) and never Absent (a lie about a key nobody asked for).
            KeyDeletionResult.Failed(keyName = name, retryable = true, reason = REASON)

        companion object {
            const val REASON = "the runtime does not yet stand: no key may be erased at the startup barrier"
        }
    }

    /** The identity authority of a runtime that does not yet stand: it PUBLISHES NOTHING, and NAMES its own absence. */
    class DeferredIdentityAuthoritySeam : IdentityAuthoritySeam {
        override fun publishNewIdentity(): String = REASON
        override fun identity(): String? = null

        companion object {
            const val REASON = "the runtime does not yet stand: no identity may be published at the startup barrier"
        }
    }

    /** The artifact filesystem of a runtime that does not yet stand: it DELETES NOTHING -- but it still READS. */
    class DeferredArtifactFileSystemSeam : ArtifactFileSystemSeam {
        /** READING IS NOT AN EFFECT: a reader that could not see the truth would be worse than no reader at all. */
        override fun exists(path: String): Boolean = File(path).exists()

        override fun deleteArtifact(path: String): FileDeletionResult = FileDeletionResult.Failed(path, REASON)

        /** Nothing is readable while no runtime stands: answering `true` here would invite a reader to try. */
        override fun isReadable(path: String): Boolean = false

        companion object {
            const val REASON = "the runtime does not yet stand: no artifact may be deleted at the startup barrier"
        }
    }
}
