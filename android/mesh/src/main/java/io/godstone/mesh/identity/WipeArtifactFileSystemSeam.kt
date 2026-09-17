package io.godstone.mesh.identity

import java.io.File

/**
 * GS-STORE-006: **THE PRODUCTION `ArtifactFileSystemSeam` FOR THIS ISLE** -- written from the seam's own three members and
 * the platform's own filesystem, WITH NO UNKNOWN DEPENDENCY: it is path-agnostic, so it needs no scope list and no handle.
 *
 * **EVERY RESULT IS CHECKED, WHICH IS THE CARD'S STEP 5**: deletion is performed through `File`, and the answer is derived
 * from WHAT THE FILESYSTEM REPORTS AFTERWARDS rather than from the absence of a thrown exception -- so a permission, a lock,
 * or a path that SURVIVED ITS OWN DELETION is returned as a FAILURE and the wipe stays pending, exactly as the card demands
 * ("check every result, and leave the wipe pending when cleanup fails").
 *
 * **AND `isReadable` CONSULTS THE JOURNAL, NOT THE VAULT -- MIRRORING iOS, WHERE THE FIRST DRAFT MADE A DESTRUCTIVE *READ*:**
 * the seam's only key verb is `eraseKey`, so answering "do the keys still live?" by ASKING THE VAULT would have ERASED THEM --
 * a question that destroys its own subject, on a path a caller reads to decide something. THE ORACLE IS THEREFORE THE WIPE'S
 * OWN DURABLE RECORD: once the journal stands at or past `KEY_ERASED`, the material that would decrypt an artifact is gone, so
 * an artifact still on disk is NOT readable. NO KEY IS TOUCHED HERE.
 */
class WipeArtifactFileSystemSeam(private val journal: WipeJournal) : ArtifactFileSystemSeam {

    override fun exists(path: String): Boolean = File(path).exists()

    override fun deleteArtifact(path: String): FileDeletionResult {
        val file = File(path)
        if (!file.exists()) {
            // ABSENCE AND DELETION BOTH SATISFY THE CLEANUP (the seam's own `satisfiesCleanup` doctrine), so an artifact
            // that never stood is reported as such rather than as a failure.
            return FileDeletionResult.Absent
        }
        try {
            if (!file.delete()) {
                // A `delete()` THAT RETURNED FALSE WHILE THE FILE SURVIVES IS STILL A FAILURE, and saying so is the whole
                // point of checking every result rather than trusting the call.
                return FileDeletionResult.Failed(path, "the artifact surviveth its own deletion")
            }
        } catch (e: SecurityException) {
            return FileDeletionResult.Failed(path, e.toString())
        }
        if (file.exists()) {
            return FileDeletionResult.Failed(path, "the artifact surviveth its own deletion")
        }
        return FileDeletionResult.Deleted
    }

    override fun isReadable(path: String): Boolean {
        if (!File(path).exists()) return false
        // THE JOURNAL IS THE ORACLE, AND IT IS READ-ONLY: the erasure belongs to the step that is supposed to erase.
        val state = journal.read()
        return !(state == PanicWipe.WipeState.KEY_ERASED ||
            state == PanicWipe.WipeState.ARTIFACTS_DELETED ||
            state == PanicWipe.WipeState.NEW_IDENTITY)
    }
}
