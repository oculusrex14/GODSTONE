package io.godstone.mesh.di

import io.godstone.mesh.identity.CrashResumableWipe
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.PrivateOwnerToken
import io.godstone.mesh.identity.WipeJournal
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.identity.WipeReadabilityReporting
import io.godstone.mesh.identity.WipeRefusalCause
import io.godstone.mesh.identity.WipeStepResult

/**
 * *** GS-FINAL-003 `same-estate` (A2): THE DURABLE RECORD'S REVISION AS A TYPE -- LADDER **AND** GENERATION. ***
 *
 * *THE REVIEW'S A2, VERBATIM: **"RevisionOf reads coordinator snapshot not live journal; permit enum only not bound/
 * validated at consumption; stale/wrongestate/ABA accepted once denyall fixed."*** **THE PERMIT WAS A PURE FUNCTION OF A
 * PUBLIC ENUM AND A STRING A CALLER SUPPLIED, so a stale or wrong-estate permit could be presented after the estate moved
 * (ABA), and nothing RE-READ the journal at consumption.**
 *
 * *** THIS TYPE IS THE ONE RESOLUTION OF "WHAT ESTATE IS THIS", AND IT IS DERIVED FROM THE DURABLE BYTES. *** *The
 * revision is built from the journal on every call -- never the coordinator's in-memory ladder -- so a write performed by
 * ANOTHER instance invalides every permit minted before it.*
 *
 * *** AND IT CARRIETH THE DURABLE GENERATION ([epoch]), WHICH IS THE HALF THE LADDER ALONE CANNOT PROVE. *** *`IDLE →
 * REQUESTED → … → IDLE` RETURNETH THE RECORD TO THE RUNG IT STARTED AT, so permits minted at the two `IDLE` readings would
 * carry the SAME ladder wire while the estate between them was ANNIHILATED and RE-IDENTIFIED.* **THE EPOCH MAKETH THOSE
 * TWO REVISIONS DIFFERENT, so a fresh reopen that presenteth the older permit is REFUSED -- the `noABA` law stated as
 * bytes rather than as a convention.**
 */
sealed class EstateRevision {
    /** The canonical wire form the permit carrieth: the ladder bytes AND the durable generation. */
    abstract val wire: String

    /** The durable generation this revision was read at. *`0` meaneth the store could not name one: never a match.* */
    abstract val epoch: Long

    /** NO WIPE WAS EVER REQUESTED (this journal collapses the terminal rung to no history). */
    class Absent(override val epoch: Long) : EstateRevision() {
        override val wire: String = "|true|$epoch"
    }

    /** THE RECORD STANDS AT A RUNG. */
    class Present(val state: PanicWipe.WipeState, override val epoch: Long) : EstateRevision() {
        override val wire: String = "${state.name}|true|$epoch"
    }

    /** THE RECORD CANNOT BE PARSED. *Never a clean start, and never a valid permit.* */
    class Unreadable(override val epoch: Long) : EstateRevision() {
        override val wire: String = "$UNAVAILABLE|$epoch"
    }

    companion object {
        /** *The coordinator's word for "I cannot read this record".* */
        const val UNAVAILABLE: String = "<unreadable>"

        /**
         * *** THE ONE RESOLUTION: PARSE THE RECORD'S OWN WIRE, SO THE TYPED ESTATE AND THE PERMIT'S STRING CANNOT
         * DISAGREE -- THEY ARE THE SAME BYTES READ TWICE. ***
         *
         * *The ladder AND the generation are taken from `liveRevision()` (which re-reads the STORE), never from a second
         * read that could race it.* **A store that could not name a generation contributed `<...>|0`, and a zero epoch
         * matchteth no minted revision -- fail closed rather than guess.**
         */
        fun of(coordinator: CrashResumableWipe): EstateRevision {
            val wire = coordinator.liveRevision()
            if (wire == UNAVAILABLE) return Unreadable(0L)
            val parts = wire.split('|')
            val epoch = parts.getOrNull(2)?.toLongOrNull() ?: 0L
            val rung = parts.getOrNull(0).orEmpty()
            if (rung.isEmpty()) return Absent(epoch)
            val state = PanicWipe.WipeState.entries.firstOrNull { it.name == rung } ?: return Unreadable(epoch)
            return Present(state, epoch)
        }
    }
}

/**
 * *** GS-FINAL-003 `one-owner` (A2/A3/A8): THE ONE ESTATE AUTHORITY -- THE SINGLE OWNER THAT SERIALIZES EVERY REAL DRIVE. ***
 *
 * *THE REVIEW'S A8, VERBATIM: **"no shared estate drive/admission lock/reentrancy guard; duplicate effects/checkpoint
 * regression; cold constant Drained despite live owner possible."*** **THE TWO PRODUCTION ROADS (the startup barrier and the
 * runtime-side wipe) EACH BUILT THEIR OWN COORDINATOR, so two owners could drive one durable record concurrently -- and a
 * second owner could REGRESS or OVERWRITE a checkpoint with a stale write.**
 *
 * *** SO THE DRIVE, THE ADMISSION, THE CHECKPOINT WRITES AND THE PERMIT ARE ONE OBJECT. *** *[guarded] is the ONE
 * serialization point: every real drive holds it, and a reentrant drive (an injected hook or seam that re-enters) is
 * REFUSED rather than run twice.* **And [revision] is read from the durable record, so admission and permit validation ask
 * the SAME question of the SAME bytes.**
 *
 * *** IT EXPOSES THE NARROW REAL API THE UI AND THE BOOTSTRAP NEED, AND NOTHING ELSE: *** *the typed decision at rest, the
 * conditional recovery verbs, the operator's corrupt resolution ([resolveCorruptForOperator]), and the current-estate permit
 * ([issueCurrentPermit]).* **There is no second boolean to invert and no enum a caller can hand to a constructor.**
 */
class EstateAuthority internal constructor(
    private val journal: WipeJournal,
    private val seams: WipeRecoverySeams,
) {
    /** The ONE lock: every drive and every resolution travelleth here, so two owners cannot step one record at once. */
    private val driveLock = Any()

    /** *Set while a drive holds the lock; a reentrant drive finds a refusal rather than a second effect.* */
    private var inDrive = false

    /**
     * *** THE ONE COORDINATOR (A8): built ONCE, here, so the barrier and the runtime drive the SAME instance. ***
     *
     * *Its in-memory ladder is therefore the ONE owner's memory; [revision] and [decisionAtRest] re-read the STORE, so a
     * write by any other means still moveth the revision and invalidateth a stale permit.*
     */
    internal val coordinator: CrashResumableWipe = StartupRecoveryGraph.coordinator(journal, seams)

    /** *The estate as the DURABLE RECORD tells it, typed -- parsed from the record's own wire so permit and surface agree.* */
    fun revision(): EstateRevision = EstateRevision.of(coordinator)

    /**
     * *** GS-FINAL-003 `same-estate` (A2/A8): THE DURABLE GENERATION THIS ESTATE STANDS AT, READ FRESH. ***
     *
     * *Exposed so the composition's permit minting and the coordination's consumption check can state the generation they
     * judged, rather than re-deriving it from a stale reading of their own.* **It is a READ of the record, never a cached
     * field: a store that cannot name one answers `0`, which matchteth no revision.**
     */
    fun epoch(): Long = (journal as? io.godstone.mesh.identity.WipeEpochReporting)?.epoch ?: 0L

    /** *The typed decision at rest, through the ONE production mapping -- the SAME mapping the barrier uses.* */
    fun decisionAtRest(): StartupWipeDecision = StartupRecoveryGraph.decisionAtRest(journal)

    /** GS-FINAL-003: derived from [decisionAtRest], so the two cannot drift. TRUE means the estate is settled and clean. */
    val permitsStartup: Boolean get() = decisionAtRest().allowsPrivateConstruction

    /** *The name LabEstate's bootstrap consults: MAY normal private composition be composed NOW?* */
    fun permitsNormalComposition(): Boolean = decisionAtRest().allowsPrivateConstruction

    /** *** THE ONE SERIALIZATION GATE (A8): every real drive travelleth here, reentrant drives are refused. *** */
    private fun guarded(body: () -> RecoveryDrive): RecoveryDrive = serialized(body)

    /**
     * *** GS-FINAL-003 `one-owner` (A8): the serialization primitive, exposed `internal` for the RUNTIME-SIDE road. ***
     *
     * *The runtime-side wipe driveth a coordinator over the LIVE seams (a different seam set from the barrier's) -- but it
     * must serialize on the SAME estate owner, or two roads could step one durable record at once.* **This is that one
     * lock; a REENTRANT drive on the same thread is refused rather than run twice.**
     */
    internal fun <T> serialized(body: () -> T): T = synchronized(driveLock) {
        require(!inDrive) { "GS-FINAL-003: a drive of this estate is already in progress on this thread" }
        inDrive = true
        try {
            body()
        } finally {
            inDrive = false
        }
    }

    private fun runDrive(body: (CrashResumableWipe) -> WipeStepResult): RecoveryDrive {
        val outcome = body(coordinator)
        return RecoveryDrive(outcome, StartupRecoveryGraph.decisionOf(coordinator, outcome), revision())
    }

    /** *** THE REQUEST VERB: a NEW wipe, over the real seams, durably recorded before any effect. *** */
    fun requestWipe(): RecoveryDrive = guarded { runDrive { it.requestWipe() } }

    /** *** THE RESUME VERB: what a relaunch owns. *** */
    fun resumeWipe(): RecoveryDrive = guarded { runDrive { it.resume() } }

    /**
     * *** GS-FINAL-003 (A7): THE OPERATOR'S REAL RESOLUTION FOR A CORRUPT RECORD -- ERASURE, NOT A JOURNAL CLEAR. ***
     *
     * *THE REVIEW'S A7, VERBATIM: **"operator corrupt resolution clears journal -> CLEAN_START without erasure and has no
     * actual UI caller; corruption-only precondition absent."*** **DROPPING THE UNREADABLE MARKER LEFT WHATEVER MATERIAL
     * MADE IT UNREADABLE IN PLACE**, and then claimed a first launch over it -- the unsound direction `decide()` names.*
     *
     * *** SO THE OPERATOR'S ACT IS: DURABLY RECORD `REQUESTED`, THEN PERFORM THE FULL VERIFIED ERASURE THROUGH THE SAME
     * LADDER (drain -> keys -> artifacts -> fresh identity), AND ANSWER `WIPE_COMPLETED` -- NEVER `CLEAN_START`. *** *The
     * resolution is RESTRICTED to a genuinely corrupt record ([decisionAtRest] is CORRUPT_JOURNAL); a call on a readable
     * estate is a misuse and REFUSED. If the ladder cannot finish (a failed checkpoint, a refusing seam) the record keeps
     * its truth and the drive answereth the typed refusal -- never a fabricated clean start.*
     */
    fun resolveCorruptForOperator(): RecoveryDrive = guarded {
        if (decisionAtRest() != StartupWipeDecision.CORRUPT_JOURNAL) {
            return@guarded RecoveryDrive(
                WipeStepResult.Refused(
                    WipeRefusalCause.WIPE_ALREADY_PENDING,
                    "the operator's corrupt resolution is offered only for an unreadable record",
                ),
                decisionAtRest(),
                revision(),
            )
        }
        // (1) DURABLY RECORD THE REQUEST before any effect -- a resolution that erased without recording is not resumable.
        if (!coordinator.recordRequestDurably()) {
            return@guarded RecoveryDrive(
                WipeStepResult.Refused(
                    WipeRefusalCause.CHECKPOINT_NOT_DURABLE,
                    "the corrupt-resolution request did not reach disk",
                ),
                StartupWipeDecision.CORRUPT_JOURNAL,
                revision(),
            )
        }
        // (2) AND THE SAME LADDER PERFORMS THE FULL ERASURE.
        val outcome = coordinator.resume()
        RecoveryDrive(outcome, StartupRecoveryGraph.decisionOf(coordinator, outcome), revision())
    }

    /**
     * *** GS-FINAL-003 (A2): THE CURRENT-ESTATE PERMIT -- RE-VALIDATED AT ISSUE, REFUSED WHEN THE ESTATE IS NOT SETTLED. ***
     *
     * *A composition that must obtain the authority for a NORMAL construction asks HERE; the returned permit carrieth the
     * revision it was validated at ([revision]), and every raw owner constructor re-checks that revision at consumption
     * ([PrivateStorePermit.requireLiveFor]).* **There is no road to a permit that skips this -- the enum alone mints
     * nothing.**
     */
    fun issueCurrentPermit(): PrivateStorePermit? {
        val decision = decisionAtRest()
        if (!decision.allowsPrivateConstruction) return null
        return PrivateStorePermit.mint(decision, revision().wire)
    }

    companion object {
        /** *The one way to build the authority over a real journal and its seams.* */
        internal fun over(journal: WipeJournal, seams: WipeRecoverySeams): EstateAuthority = EstateAuthority(journal, seams)
    }
}

/**
 * *** GS-FINAL-003 `unforgeable-permit` (A3): THE PRIVATE-STORE AUTHORITY -- NON-FORGEABLE, EVIDENCE-BOUND, ESTATE-BOUND. ***
 *
 * *THE REVIEW'S A3, VERBATIM: **"internal RecoveryEvidence.issued(enum,revisionString) permits same-module constructor
 * selfmint; arbitrary coordinator+terminaloutcome accepted."*** **A `private constructor` PLUS a producer that took the
 * DECISION AS AN ARGUMENT is a door any `:mesh` caller can open -- which is exactly the "normal runtime constructor mints
 * its own permit" mutation the obligation names.**
 *
 * *** THE DOOR NOW TAKES EVIDENCE WHOSE DECISION IS COMPUTED FROM THE COORDINATOR AND WHOSE REVISION IS THE RECORD'S OWN
 * LIVE BYTES, AND THE PERMIT IS RE-CHECKED AT CONSUMPTION. ***
 *   * [issue] refuseth unless the evidence's decision permits;
 *   * [requireLiveFor] refuseth unless the ESTATE HAS NOT MOVED since -- the A2 ABA law; and
 *   * the normal-owner token ([PrivateOwnerToken]) cannot exist without this permit, so every raw construction is gated.
 */
class PrivateStorePermit private constructor(
    /** The typed decision the evidence COMPUTED. */
    val issuedFrom: StartupWipeDecision,
    /** The durable revision this permit was validated at; re-checked at consumption. */
    internal val estateRevision: String,
) {
    /**
     * *** GS-FINAL-003 `same-estate` (A2): RE-VALIDATE THIS PERMIT AGAINST THE ESTATE *NOW*, AT CONSUMPTION. ***
     *
     * *A permit is a judgement about an estate, not a permanent badge.* **The caller supplieth the executing revision (read
     * from the record at the instant of construction) and the token it intends to consume; the permit refuseth if the
     * estate has moved (ABA) or the token belongs to another estate.**
     */
    internal fun requireLiveFor(executingRevision: String, token: PrivateOwnerToken): PrivateOwnerToken {
        require(estateRevision == executingRevision) {
            "GS-FINAL-003: the estate moved since this permit was judged (permit revision '$estateRevision', executing " +
                "revision '$executingRevision'); a permit minted before a wipe cannot admit construction after it"
        }
        require(token.estateRevision == estateRevision) {
            "GS-FINAL-003: the normal-owner token belongs to a different estate than this permit"
        }
        return token
    }

    companion object {
        /**
         * *The ONLY PUBLIC door, and it takes EVIDENCE -- never a bare decision.* **A caller that holds `CLEAN_START` but
         * no evidence cannot mint, and a caller inside a normal runtime constructor has neither.**
         */
        fun issue(evidence: RecoveryEvidence): PrivateStorePermit? =
            if (evidence.decision.allowsPrivateConstruction) {
                PrivateStorePermit(evidence.decision, evidence.estateRevision)
            } else null

        /** *The composition's own mint, from a decision IT computed at the current estate -- `internal`, so no raw caller reaches it.* */
        internal fun mint(decision: StartupWipeDecision, estateRevision: String): PrivateStorePermit =
            PrivateStorePermit(decision, estateRevision)
    }
}

/**
 * *** GS-FINAL-003 `unforgeable-permit`: THE PRE-PRIVATE GRAPH'S OWN EVIDENCE, PRODUCED ONLY BY THE AUTHORITY. ***
 *
 * *Its constructor is `private`, and the only producer computes the decision from a coordinator and the revision from the
 * record's own bytes -- so a caller can neither manufacture the evidence nor choose what it sayeth.*
 */
class RecoveryEvidence private constructor(
    /** The decision the recovery graph COMPUTED -- not one a caller supplied. */
    val decision: StartupWipeDecision,
    /** The durable record's revision at the instant it was read. */
    internal val estateRevision: String,
) {
    /** *Retained for existing callers; it is exactly [estateRevision].* */
    val journalRevision: String get() = estateRevision

    internal companion object {
        /** *The one producer over a coordinator and its outcome -- the decision is DERIVED, never supplied.* */
        internal fun issued(coordinator: CrashResumableWipe, outcome: WipeStepResult): RecoveryEvidence =
            RecoveryEvidence(
                decision = StartupRecoveryGraph.decisionOf(coordinator, outcome),
                estateRevision = coordinator.liveRevision(),
            )
    }
}

/**
 * *** WHAT A RECOVERY DRIVE HANDS BACK: THE LADDER'S TYPED ANSWER, THE DECISION IT PRODUCED, AND THE ESTATE REVISION. ***
 *
 * *A caller that renders needeth [outcome]/[decision]; a caller that reasons about staleness needeth [revision].* **Keeping
 * them together meaneth a caller cannot hold a decision that its own drive did not compute.**
 */
class RecoveryDrive internal constructor(
    val outcome: WipeStepResult,
    val decision: StartupWipeDecision,
    val revision: EstateRevision,
)
