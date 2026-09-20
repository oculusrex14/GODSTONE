package io.godstone.mesh.identity

/**
 * GS-STORE-006: **THE PRODUCTION `WipeDurabilityStore` FOR THIS ISLE** -- A MAPPING BETWEEN TWO STATE MACHINES rather than a
 * second state machine of its own.
 *
 * THE CARD'S STEP-1 FORK, SETTLED BY MEASUREMENT: this isle's coordinator carries the ladder
 * `REQUESTED -> RUNTIME_DRAINED -> KEYS_ERASED -> ARTIFACTS_DELETED -> NEW_IDENTITY -> IDLE` as a list of stage NAMES,
 * while its journal carries ONE TYPED `PanicWipe.WipeState` -- and that enum had a value per ladder stage EXCEPT THE DRAIN
 * until the same change that added this file. **THE MISSING STAGE WAS THE MISSING GUARANTEE, AND BOTH HALVES ARE RESTORED
 * TOGETHER.**
 *
 * **IT LIVES BEHIND THE EXISTING ENTRY POINT**, which is the card's own instruction ("do not leave two competing public
 * wipe coordinators"): the durable record stays `WipeJournal` -- the field-proven implementation the isle already has --
 * and nothing here invents a second store.
 *
 * AND IT USES **THE ISLE'S OWN SPELLING**: this isle writes `KEY_ERASED` (singular) where iOS writes `KEYS_ERASED`, so the
 * mapping accepts the isle's spelling AND tolerates the other (a wire name from the other isle must not be silently
 * dropped). An UNKNOWN stage name is REFUSED rather than dropped -- `appendJournal` returns without writing -- because a
 * dropped checkpoint is a wipe that restarts LATER than it should: the failure is closed, and the caller's step stays
 * pending.
 */
class WipeJournalDurabilityAdapter(
    private val journal: WipeJournal,
) : WipeDurabilityStore, WipeReadabilityReporting {

    /**
     * *** GS-FINAL-003: THE ADAPTER MUST NOT INVENT A READABILITY IT CANNOT SEE. ***
     *
     * A `WipeJournal` that cannot answer the question (no `WipeReadabilityReporting`) has NOT answered it, so this
     * returns `false` -- FAIL CLOSED, matching iOS. *An earlier version of this class had no such property at all, so
     * a store mid-erasure was indistinguishable from an empty one.*
     */
    override val isReadable: Boolean
        get() = (journal as? WipeReadabilityReporting)?.isReadable ?: false


    private val lock = Any()

    /**
     * The journal holds ONE state, so the "list" is the single checkpoint it stands at -- reporting a longer history than
     * the store carries would be INVENTING A PAST.
     */
    override fun readJournal(): List<String> = synchronized(lock) {
        val state = journal.read()
        if (state == PanicWipe.WipeState.IDLE) emptyList() else listOf(stageFor(state))
    }

    /** Appending a stage WRITES IT THROUGH; an unmappable name is REFUSED (nothing is written, and no exception pretends). */
    override fun appendJournal(stateName: String) {
        val state = stateFor(stateName) ?: return
        synchronized(lock) { journal.write(state) }
    }

    companion object {
        /** The coordinator's own stage vocabulary, in ITS order -- the ladder, named by the strings it persists. */
        val LADDER: List<String> = listOf(
            "REQUESTED", "RUNTIME_DRAINED", "KEYS_ERASED", "ARTIFACTS_DELETED", "NEW_IDENTITY", "IDLE",
        )

        /** Map ONE ladder stage name onto the journal's own typed state; `null` when the name is not a ladder stage. */
        fun stateFor(stage: String): PanicWipe.WipeState? = when (stage) {
            "REQUESTED" -> PanicWipe.WipeState.REQUESTED
            "RUNTIME_DRAINED" -> PanicWipe.WipeState.RUNTIME_DRAINED
            // THE ISLE'S OWN SPELLING FIRST, AND THE OTHER ISLE'S TOLERATED: a wire name that came from the other side
            // must not be silently dropped, but this isle WRITES `KEY_ERASED`.
            "KEY_ERASED", "KEYS_ERASED" -> PanicWipe.WipeState.KEY_ERASED
            "ARTIFACTS_DELETED" -> PanicWipe.WipeState.ARTIFACTS_DELETED
            "NEW_IDENTITY" -> PanicWipe.WipeState.NEW_IDENTITY
            "IDLE" -> PanicWipe.WipeState.IDLE
            else -> null
        }

        /** And the reverse, in the isle's own spelling. */
        fun stageFor(state: PanicWipe.WipeState): String = when (state) {
            PanicWipe.WipeState.IDLE -> "IDLE"
            PanicWipe.WipeState.REQUESTED -> "REQUESTED"
            PanicWipe.WipeState.RUNTIME_DRAINED -> "RUNTIME_DRAINED"
            PanicWipe.WipeState.KEY_ERASED -> "KEY_ERASED"
            PanicWipe.WipeState.ARTIFACTS_DELETED -> "ARTIFACTS_DELETED"
            PanicWipe.WipeState.NEW_IDENTITY -> "NEW_IDENTITY"
        }
    }
}
