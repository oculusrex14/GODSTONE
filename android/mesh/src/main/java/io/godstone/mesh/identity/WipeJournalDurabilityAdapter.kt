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
) : WipeDurabilityStore, WipeReadabilityReporting, WipeEpochReporting {

    /**
     * *** GS-FINAL-003 `same-estate` (A2/A8): THE ADAPTER RELAYS THE RECORD'S DURABLE GENERATION. ***
     *
     * *This is what lets [CrashResumableWipe.liveRevision] -- and therefore every permit, evidence and owner-token -- carry
     * the GENERATION beside the ladder, so `IDLE → wipe → IDLE` produceth a DIFFERENT revision rather than the same one.*
     * **A journal that cannot name a generation answereth `0`, which matchteth no revision: fail closed, never guess.**
     */
    override val epoch: Long
        get() = (journal as? WipeEpochReporting)?.epoch ?: 0L

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

    /**
     * *** GS-FINAL-003 `durable-checkpoints` (A2/A9): THE CHECKPOINT THAT CAN REFUSE. ***
     *
     * *TWO DEFECTS ARE CLOSED AT THIS ONE SEAM, AND BOTH WERE MEASURED:*
     *
     *   1. **A9 -- THE COMMIT'S VERDICT IS CONSULTED.** *The old [appendJournal] called the best-effort write and
     *      DISCARDED `SharedPreferences.commit()`'s boolean, so a checkpoint that never reached disk was treated as
     *      durable and the ladder advanced over it.* **Here the durable verdict IS the return value.**
     *   2. **A2 -- A SECOND OWNER CANNOT REGRESS THE CHECKPOINT.** *The store carrieth ONE value, so "append-only" means
     *      the incoming stage must be the LEGAL NEXT STEP ([WipeJournalState.rank] exactly one above the current rung) or
     *      the terminal `IDLE` closing a full ladder.* **A stale writer that would move the record BACKWARD -- or SKIP a
     *      rung -- is REFUSED rather than obeyed**, *because the coordinator and the record would otherwise disagree
     *      about how far the erasure has advanced, which is exactly the ABA this finding names.*
     *
     * *A name with no owner is REFUSED, exactly as [appendJournal] refuseth it: a dropped checkpoint keeps the step
     * pending rather than fabricating progress.*
     */
    override fun appendJournalDurably(stateName: String): Boolean {
        val state = stateFor(stateName) ?: return false
        synchronized(lock) {
            val current = journal.read()
            if (!isLegalNext(current, state)) return false
            return journal.writeDurably(state)
        }
    }

    /**
     * *** THE LADDER'S OWN LEGALITY, ASKED OF THE TYPED RUNGS RATHER THAN OF A LIST. ***
     *
     * *`current == IDLE` is the clean/terminal estate, so the ONLY legal write is the ladder's first rung, `REQUESTED`.*
     * *Otherwise the incoming rung must be exactly one rank above the current one -- the strict-monotone law the
     * coordinator declares -- or the terminal `IDLE` that closeth a completed ladder.*
     *
     * *** AND THE RANK IS READ FROM THIS ADAPTER'S OWN ORDERED RUNGS ([`RUNGS`]), NOT INVENTED FROM THE JOURNAL
     * ENUM. *** *`PanicWipe
     * .WipeState` is the PERSISTED RECORD'S vocabulary and its declaration order is `IDLE, REQUESTED, RUNTIME_DRAINED,
     * KEY_ERASED, ARTIFACTS_DELETED, NEW_IDENTITY` -- **`IDLE` is ordinal 0 there, so ordinal arithmetic over that enum
     * would read a completed wipe as the FIRST rung.*** *The ladder ORDER is the coordinator's (`WipeJournalState.rank`),
     * and this adapter is the ONE place the two vocabularies are mapped, so the rank is taken from the mapping it owns.*
     */
    private fun isLegalNext(current: PanicWipe.WipeState, next: PanicWipe.WipeState): Boolean = when {
        current == PanicWipe.WipeState.IDLE -> next == PanicWipe.WipeState.REQUESTED
        next == PanicWipe.WipeState.IDLE -> current == PanicWipe.WipeState.NEW_IDENTITY
        else -> rankOf(next) == rankOf(current) + 1
    }

    /**
     * *The coordinator's rank for a journal state, resolved through the ONE mapping above rather than by ordinal.*
     *
     * *** AND IT IS READ FROM THE ORDERED RUNGS, NOT FROM A NAME ROUND-TRIP: *** *the earlier `LADDER.indexOf(stageFor
     * (state))` crossed the two vocabularies by NAME -- so when the ladder spelled the third rung `KEYS_ERASED` while
     * [`stageFor`] emitted the isle's own `KEY_ERASED`, this answered `-1` and [`isLegalNext`] REFUSED the ladder's own
     * successor. The order is [`RUNGS`] and nothing else.*
     */
    private fun rankOf(state: PanicWipe.WipeState): Int = RUNGS.indexOf(state)

    companion object {
        /**
         * *** THE COORDINATOR'S RUNGS, IN ITS ORDER -- THE ONE LIST THE LADDER IS DERIVED FROM. ***
         *
         * *`WipeJournalState.rank` declares this order (`REQUESTED` 1 .. `IDLE` 6); it is restated here in the typed
         * vocabulary of the PERSISTED record because this adapter is the ONE place the two vocabularies meet.* **The
         * ORDER is the law; spelling is not order -- the isle persists `KEY_ERASED` where the coordinator's wire name
         * is `KEYS_ERASED`, and [`stateFor`] bridges them.*** *`stageFor` is an exhaustive `when` over the enum, so a
         * rung added here without a name (or vice versa) cannot compile.*
         */
        private val RUNGS: List<PanicWipe.WipeState> = listOf(
            PanicWipe.WipeState.REQUESTED,
            PanicWipe.WipeState.RUNTIME_DRAINED,
            PanicWipe.WipeState.KEY_ERASED,
            PanicWipe.WipeState.ARTIFACTS_DELETED,
            PanicWipe.WipeState.NEW_IDENTITY,
            PanicWipe.WipeState.IDLE,
        )

        /**
         * The ladder, named by the strings THIS adapter persists, in the coordinator's order.
         *
         * *** IT IS DERIVED FROM [`RUNGS`] RATHER THAN HAND-TYPED A SECOND TIME, AND THAT IS THE FIX: *** *the two
         * tables previously DISAGREED -- the ladder said `KEYS_ERASED` while [`stageFor`] emitted `KEY_ERASED` -- so
         * [`rankOf`] answered `-1` for the third rung and `appendJournalDurably` REFUSED the ladder's own successor
         * (`RUNTIME_DRAINED -> KEY_ERASED`), leaving every runtime-side wipe stuck before `KEYS_ERASED`. **DERIVATION
         * MAKETH THAT IMPOSSIBLE: EVERY RUNG NAME MAPPETH 1:1 ONTO ITS LADDER ENTRY BY CONSTRUCTION.***
         */
        val LADDER: List<String> = RUNGS.map { stageFor(it) }

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
