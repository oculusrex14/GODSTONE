package io.godstone.core.archive

/**
 * GS-ARCHIVE-005 step 3: **A VALID READING ANCHOR** -- the Kotlin twin of the iOS `ArchiveReadingAnchor`, carrying
 * **THE SAME LAW**, because the contract is shared between the isles.
 *
 * THE CARD'S OWN WORDS: "Persist only small navigation identities on Android through `SavedStateHandle` ... submitted
 * query, current field text, mode, document id and **a valid reading anchor**."
 *
 * AND THE CARD SAYETH **VALID** FOR A REASON, WHICH IS THE WHOLE OF THIS TYPE: a persisted passage identity is a
 * promise about a document that may have been REPLACED, RE-RELEASED OR REVISED while the process was away. An
 * anchor honoured blindly would place a returning reader at a passage that no longer existeth -- or, worse, at
 * whatever passage now happeneth to carrieth that id in a DIFFERENT document. SO:
 *
 *   * a saved passage that **still standeth** in the currently selected document IS honoured, because the reader's
 *     place is theirs and a returning reader should not be marched back to the top;
 *   * a saved passage that **doth not stand** -- a stale identity, a changed revision, a different document --
 *     **FALLETH BACK TO THE FIRST PASSAGE**, which is the honest equivalent of "your place is gone";
 *   * an EMPTY document anchorerth nothing at all: there is no passage to stand upon, and inventing one would be a
 *     lie with a scroll behind it.
 *
 * `anchorHolds` existeth so that a caller can REPORT the fallback rather than pretend the anchor held -- the same
 * distinction the iOS isle draweth, and the reason this is a law and not a lookup.
 */
object ArchiveReadingAnchor {

    /**
     * The passage identity a reader should be placed at, or `null` when there is none.
     *
     * @param passageIds the passages of the CURRENTLY selected document, in reading order.
     * @param saved the anchor restored from the scene (the persisted navigation identity).
     */
    fun target(passageIds: List<Long>, saved: Long?): Long? {
        val first = passageIds.firstOrNull() ?: return null
        if (saved == null) return first
        return if (passageIds.contains(saved)) saved else first
    }

    /**
     * True when the saved anchor still standeth in this document -- so a caller can report that it fell back
     * rather than pretending the anchor held.
     */
    fun anchorHolds(passageIds: List<Long>, saved: Long?): Boolean =
        saved != null && passageIds.contains(saved)
}
