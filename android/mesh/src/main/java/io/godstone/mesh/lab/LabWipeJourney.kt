package io.godstone.mesh.lab

import android.content.Context
import io.godstone.mesh.di.StartupRecoveryGraph
import io.godstone.mesh.di.StartupWipeDecision
import io.godstone.mesh.di.WipeRecoverySeams
import io.godstone.mesh.identity.FileWipeJournal
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.WipeJournal
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.identity.WipeStepResult
import io.godstone.mesh.runtime.ComposedEstateOwnership

/**
 * *** GS-FINAL-003 `durable-authority` / `same-estate` / GS-UX-001 `rendered-controls` (Android isle): THE RENDERED
 * WIPE USES THE REAL PRODUCTION OWNER, OVER THE SAME ESTATE THE SEND ROAD USED. ***
 *
 * *THE OBLIGATION'S OWN WORDS: **"rendered wipe UI uses SAME durable production wipe owner (no composition harness local
 * state register) with live journey clean/wipe/persist/reopen/resume/terminal."***
 *
 * *** AND THE REVIEW'S A6 CHARGE, WHICH IS THE HALF THE FIRST REPAIR MISSED: *** **"LabWipeJourney wipes unrelated
 * Context disk estate; rendered Send/SOS LabRuntime uses in-memory identity/messages/acks and always-allow MeshNode gate;
 * wipe does not retire/erase same runtime."** *A journey that read the right journal while the send road used a DIFFERENT
 * estate would render every state a court asked for and still be A SCREEN NARRATING A WIPE SOMEBODY ELSE PERFORMED.*
 *
 * *** SO THIS CLASS OWNS BOTH HALVES, AND THEY ARE THE SAME HALF: ***
 *
 *   1. **[begin] RETIRES THE LIVE OWNERS FIRST.** *[ComposedEstateOwnership.retireLiveOwners] closes the composition's
 *      own admission and returns a COUNT, so every subsequent send/publish is REFUSED BY THE SAME HARNESS the message
 *      road used -- the obligation's "old work refused".* **Only then is the durable ladder driven, so the ladder's
 *      erasure cannot race a writer.**
 *   2. **[begin] ERASES THE SAME ESTATE THE SEND ROAD WROTE.** *The seams are [StartupRecoveryGraph.prePrivate], which
 *      ARE the isle's own owners reached without a private graph: the AndroidKeyStore master-key deleter
 *      (`AndroidWipeArtifacts.eraseKeys`), the stores' own physical-target destroyer (`FullEstateArtifactSeam`, which
 *      verifieth the REAL `godstone_messages.db` / `godstone_peer_identities.db` / identity preferences), the
 *      recovery-only identity material ops (`RecoveryIdentityMaterial`), and a transport seam that answers the drain's
 *      question truthfully because a process owning no transport can carry nothing in flight.*
 *
 * *** THE CORRUPT-RECORD RESOLUTION IS REAL AND OPERATOR-CONFIRMED (review A7). *** *A `CORRUPT_JOURNAL` decision
 * refuseth construction, and the ONLY road out is a deliberate, recorded act.* **`resolveCorruptForOperator()` is that
 * act: it durably writes `REQUESTED` and drives the FULL verified erasure through the same ladder -- it NEVER merely
 * clears the journal and it NEVER claimeth `CLEAN_START` for a record it could not read.** *The returned decision is the
 * ladder's own `WIPE_COMPLETED` when the erasure reached the terminal rung, or the honest pending/failed refusal when a
 * real capability could not complete.*
 *
 * *** AND IT NEVER TOUCHES THE PUBLIC ARCHIVE. *** *The shipping `:app` reacheth `:core`'s public Archive-only content
 * store (`filesDir/archives`, opened read-only). Nothing here nameth it: the private estate this class eraseth is the
 * Mesh identity/message/peer/ACK estate, and the Archive is not that.*
 *
 * *** WHAT A HOST GENUINELY LACKS IS THE PLATFORM, AND THAT BOUNDARY IS NAMED RATHER THAN FAKED: *** *the AndroidKeyStore
 * is an on-device facility, so a JVM host may refuse `eraseKeys`/`loadOrCreate`.* **When it doth, the wipe STOPS at the
 * rung whose owner refused and stays PENDING -- which is the honest, crash-resumable answer, not a silent success.** *The
 * journey is therefore `clean -> request -> PERSISTED at whatever rung the real capabilities reached -> reopen (the
 * SAME rung) -> resume -> not rewound`, and the TERMINAL rung is reachable whenever the capabilities succeed.*
 * `LabProfile.MANUFACTURES_READINESS` stays a compile-time `false`: nothing here claims a device result.
 */
class LabWipeJourney(
    private val ctx: Context,
    /**
     * *** THE LIVE ESTATE THIS WIPE MUST DRAIN AND RETIRE -- WHEN THE CALLER OWNS ONE. ***
     *
     * *A journey over a real composition is handed the harness that composed it, so "resume/relaunch uses the same
     * estate" is a property of the object graph rather than of a path string.* **A journey built over the durable record
     * ALONE (the reopen/relaunch probe) leaves this null: it owns no live writer, which is exactly what a fresh process
     * is.** *And `retireLiveOwners()` returns ZERO for the resource model, so "nothing was retired" is a measurement.*
     */
    private val liveEstate: ComposedEstateOwnership? = null,
    /**
     * *** GS-FINAL-003 `same-estate` (review A6): THE ESTATE'S OWN REAL FILES, SO THE LADDER ERASES WHAT SEND WROTE. ***
     *
     * *THE REVIEW'S CHARGE, VERBATIM: **"LabWipeJourney wipes unrelated Context disk estate ... wipe does not
     * retire/erase same runtime."*** **A ladder over the DEFAULT context seams deletes `godstone_messages.db` at the
     * application's own path, while a per-label lab estate wrote its databases and preferences under the label's own
     * directory -- so the wipe reported progress against files nobody wrote.** *When a real estate is supplied, the
     * filesystem and identity seams below resolve to THAT estate's actual files; the null case is the resource model /
     * reopen probe, which owns no files at all.*
     */
    private val estate: LabEstateWipeAuthority? = null,
    /**
     * *** THE DURABLE RECORD, ALWAYS THE ISLE'S OWN. ***
     *
     * *`FileWipeJournal(ctx)` is the SAME `SharedPreferences` file the startup barrier, the runtime-side wipe and the
     * admission gate read, so "the screen is at REQUESTED" meaneth THE RECORD IS AT `REQUESTED`.* **It is injectable so a
     * court can drive a faulted journal without a second implementation of the ladder.**
     */
    private val journal: io.godstone.mesh.identity.WipeJournal = FileWipeJournal(ctx),
    /**
     * *** GS-FINAL-003 `same-estate` (review A6): THE LIVE ESTATE RESOLVED AT *USE*, NEVER AT CONSTRUCTION. ***
     *
     * *THE BOOTSTRAP'S OWN ORDERING LAW: the application must consult the durable record BEFORE it composes anything
     * private.* **If this class captured the composition eagerly, merely BUILDING the journey would compose the normal
     * private graph -- which is exactly the A6 defect wearing a different hat.** *A bootstrap therefore handeth this
     * provider, and the graph is touched only when a wipe verb actually needs to retire it.*
     */
    private val liveEstateProvider: (() -> ComposedEstateOwnership?)? = null,
) {

    /** *The live owner, resolved at USE: the provider when given, else the eagerly supplied one.* */
    private fun live(): ComposedEstateOwnership? = liveEstateProvider?.invoke() ?: liveEstate

    /**
     * *** THE REAL PRE-PRIVATE CAPABILITIES, OVER THE ESTATE'S OWN BYTES WHEN THERE IS AN ESTATE. ***
     *
     * *THE OBLIGATION'S PROHIBITION IS EXACT: "don't classify missing implementable actions external".* **These seams
     * CAN erase, CAN delete and CAN re-identify without a private graph, and they are the SAME owners the runtime-side
     * wipe uses.** *The vault, the transport and the identity authority are the isle's PRODUCTION mapping
     * ([StartupRecoveryGraph.prePrivate]); the FILESYSTEM and the IDENTITY AUTHORITY are REPLACED by the estate's own
     * owners when an estate is present, because only the estate can name the files it really wrote (review A5/A10).*
     */
    private fun seams(): WipeRecoverySeams {
        val base = StartupRecoveryGraph.prePrivate(ctx, journal)
        val owner = estate ?: return base
        return WipeRecoverySeams(
            vault = base.vault,
            filesystem = LabEstateArtifactSeam(owner, base.filesystem),
            runtime = base.runtime,
            authority = LabEstateIdentitySeam(owner),
        )
    }

    /**
     * One rendered wipe row.
     *
     * *** EVERY FIELD IS DERIVED, NONE IS REMEMBERED: *** *[rung] is read back from the record, [decision] is the
     * production mapping over it, and [permitsResume]/[requiresOperator] are the production projections.* **A surface
     * therefore cannot hold a value the durable record does not carry.**
     */
    data class Step(
        val decision: StartupWipeDecision,
        /**
         * The rung the durable record stands at; `IDLE` when no wipe is outstanding.
         *
         * *`IDLE` is ALSO what an unreadable record coerces to, which is why [decision] -- which carrieth the
         * readability fact -- is the field a surface must branch on rather than the rung alone.*
         */
        val rung: WipeJournalState,
        /** Whether a wipe is outstanding, READ from the record rather than remembered. */
        val pending: Boolean,
        /** The coordinator's own typed answer, so the surface speaketh the ladder's vocabulary. */
        val outcome: WipeStepResult,
    ) {
        /** The words a surface may render: **THE STAGE COMES FROM THE RECORD**, never from a view's memory. */
        val stage: String get() = rung.name

        /**
         * *** THE DECISION IN THE ISLES' SHARED WIRE SPELLING (`"clean_start"`, `"wipe_completed"`, ...). ***
         *
         * *A rendered surface and a log record then speak ONE vocabulary across both isles, which is the same law the
         * accessibility words already follow.* **Kotlin's `camelCase` enum names would be a THIRD spelling** -- neither
         * the wire's nor the user's -- so the rendering uses this rather than `decision.name`.
         */
        val decisionName: String get() = decision.wireName

        /**
         * *** THE RESUME CONTRACT, AS A PROPERTY OF THE TYPED DECISION RATHER THAN A SWITCH. ***
         *
         * *True for EXACTLY the two decisions that mean "the ladder could not finish from here" -- `recovery_pending`
         * and `retryable_failure` -- and false for the clean estate (nothing to resume), the unreadable record
         * (retrying cannot help) and the non-retryable erasure failure (defined by retrying not helping).* **A wipe
         * resume IS semantically conditional, and the condition is this typed state.**
         */
        val permitsResume: Boolean
            get() = decision == StartupWipeDecision.RECOVERY_PENDING ||
                decision == StartupWipeDecision.RETRYABLE_FAILURE

        /**
         * *** WHETHER A HUMAN MUST LOOK -- AND THE ONE CASE A HUMAN CAN ACT ON. ***
         *
         * *`CORRUPT_JOURNAL` (an unreadable record) and `TERMINAL_FAILURE` (key material may survive) both demand a
         * person.* **But only the CORRUPT case has a real resolution this owner can drive: [resolveCorruptForOperator]
         * durably requests and performs the FULL verified erasure, whereas a terminal erasure failure is not resolvable
         * by any journal edit -- which is why [permitsOperatorCorruptResolution] is narrower than this flag.**
         */
        val requiresOperator: Boolean get() = decision.requiresOperator

        /**
         * *** `review A7/A11`: THE OPERATOR CONTROL'S OWN ENABLEMENT. ***
         *
         * *A button that SAYETH "operator required" while being unclickable -- or one that is clickable on an estate
         * where the act would be meaningless -- is a control that lies.* **This is true for exactly the CORRUPT record,
         * which is the one case [resolveCorruptForOperator] can really resolve.**
         */
        val permitsOperatorCorruptResolution: Boolean
            get() = decision == StartupWipeDecision.CORRUPT_JOURNAL

        /**
         * *** AND THE NORMAL-COMPOSITION ANSWER, DERIVED -- SO A BOOTSTRAP CAN ASK THE SURFACE'S OWN PROJECTION. ***
         *
         * *The launchable application asks exactly this before it composes private owners: `CLEAN_START` and
         * `WIPE_COMPLETED` permit; every pending/corrupt/terminal case refuseth.*
         */
        val permitsNormalComposition: Boolean get() = decision.allowsPrivateConstruction
    }

    /** *** `progress()`: read the durable record and derive the typed decision from it. *** */
    fun progress(): Step {
        val decision = StartupRecoveryGraph.decisionAtRest(journal)
        val rung = rungOf(journal.read())
        return Step(
            decision = decision,
            rung = rung,
            pending = rung != WipeJournalState.IDLE,
            // At rest nothing was driven; the coordinator's vocabulary for "a rung already passed" is the honest one.
            outcome = WipeStepResult.AlreadyAtOrPast(rung),
        )
    }

    /**
     * *** `beginWipe()`: RETIRE THE LIVE ESTATE, THEN DRIVE THE REAL LADDER. ***
     *
     * *THE ORDER IS THE WHOLE REPAIR: the obligation is **"begin wipe must drain/retire actual live owner ... old work
     * refused"**.* **Retiring FIRST meaneth the ladder's key erasure and artifact deletion cannot race a writer that
     * still holdeth a store handle** -- the "same estate" clause as a property of the sequence rather than of a comment.
     *
     * *And a requested wipe therefore REALLY erases, REALLY deletes and REALLY re-identifies; what it CANNOT do on a host
     * is reach past a capability the host genuinely lacks (the AndroidKeyStore), and that boundary is the platform's,
     * named rather than faked.*
     */
    fun begin(): Step {
        // *** (1) OLD WORK REFUSED, BEFORE THE LADDER MOVES. ***
        live()?.retireLiveOwners()
        // *** (2) AND THE LADDER, OVER THE REAL CAPABILITIES. ***
        return fromDrive(StartupRecoveryGraph.requestWipe(journal, seams()))
    }

    /**
     * *** `resumeWipe()`: hand a PERSISTED pending wipe back to the graph that owns the ladder. ***
     *
     * *A RESUME IS NOT A REQUEST: no new `REQUESTED` is written, and the ladder continueth from the rung the record
     * carrieth. The live estate is retired here too, because a resume after a crash may find a composition that was
     * built against the record before the wipe was requested.*
     */
    fun resume(): Step {
        live()?.retireLiveOwners()
        return fromDrive(StartupRecoveryGraph.resumeWipe(journal, seams()))
    }

    /**
     * *** `resolveCorruptForOperator()` (review A7): THE REAL, RECORDED RESOLUTION OF AN UNREADABLE RECORD. ***
     *
     * *THE OBLIGATION ASKETH FOR "corruption typed operator-required with real resume path", AND ITS PROHIBITION IS
     * EXACT: **"never clear marker pretend clean"**.* **The FIRST form of the graph's operator act DID exactly that --
     * `journal.clear()` and then a re-read, which returned `CLEAN_START` -- so an estate whose record could not be read
     * was declared a first launch, and private stores were opened over material that might be mid-erasure.**
     *
     * *** THIS ACT INSTEAD: durably writes `REQUESTED` (through the ONE production `requestWipe`, which persisteth the
     * marker BEFORE it drives anything) and performs the FULL VERIFIED ERASURE through the SAME ladder -- keys erased,
     * the owner-defined physical artifacts deleted and VERIFIED, and a fresh identity published by the recovery-only
     * material ops.** *The decision returned is therefore `WIPE_COMPLETED` when the erasure reached the terminal rung,
     * or the honest pending/failed refusal when a real capability could not complete -- and NEVER `CLEAN_START`.*
     *
     * *** AND IT IS REFUSED UNLESS THE RECORD REALLY IS CORRUPT. *** *A caller that could invoke this on a clean or
     * pending estate would have a general "erase everything" button dressed as a repair; the guard maketh the operation
     * mean what its name sayeth.*
     */
    fun resolveCorruptForOperator(): Step {
        val current = StartupRecoveryGraph.decisionAtRest(journal)
        require(current == StartupWipeDecision.CORRUPT_JOURNAL) {
            "GS-FINAL-003: the operator's corrupt resolution is offered ONLY for an unreadable record; this estate " +
                "decided $current. A resolution that ran on any other state would be an erasure button wearing a " +
                "repair's name."
        }
        // (1) OLD WORK REFUSED, exactly as `begin()` -- the erasure must not race a live writer.
        live()?.retireLiveOwners()
        // (2) *** THE REAL RESOLUTION IS THE FULL LADDER, NOT A JOURNAL EDIT. *** *`requestWipe` records `REQUESTED`
        // durably first (overwriting the unreadable marker with a readable one) and then drives every rung through the
        // real seams -- so the bytes this estate held are actually erased rather than merely forgotten.*
        return fromDrive(StartupRecoveryGraph.requestWipe(journal, seams()))
    }

    private fun fromDrive(drive: io.godstone.mesh.di.RecoveryDrive): Step {
        val outcome = drive.outcome
        val decision = drive.decision
        // THE RUNG IS READ BACK FROM THE RECORD **AFTER** THE VERB, so the rendered stage is what was PERSISTED rather
        // than what the verb intended -- the difference between a screen reporting an intention and a fact.
        val rung = rungOf(journal.read())
        return Step(
            decision = decision,
            rung = rung,
            pending = rung != WipeJournalState.IDLE,
            outcome = outcome,
        )
    }

    /**
     * *The journal's own typed rung, spelled in the coordinator's vocabulary so the two cannot drift.* **`IDLE` is what
     * the isle's journal means by "no wipe is outstanding" -- the same collapse both isles' adapters share and which
     * `WipeStartupHalfTest` records rather than hides.**
     */
    internal fun rungOf(state: PanicWipe.WipeState): WipeJournalState = when (state) {
        PanicWipe.WipeState.IDLE -> WipeJournalState.IDLE
        PanicWipe.WipeState.REQUESTED -> WipeJournalState.REQUESTED
        PanicWipe.WipeState.RUNTIME_DRAINED -> WipeJournalState.RUNTIME_DRAINED
        PanicWipe.WipeState.KEY_ERASED -> WipeJournalState.KEYS_ERASED
        PanicWipe.WipeState.ARTIFACTS_DELETED -> WipeJournalState.ARTIFACTS_DELETED
        PanicWipe.WipeState.NEW_IDENTITY -> WipeJournalState.NEW_IDENTITY
    }
}

/**
 * *** GS-FINAL-003 `same-estate` (review A5/A10): THE LADDER'S FILESYSTEM SEAM, OVER THE LAB ESTATE'S OWN FILES. ***
 *
 * *THE A5 CHARGE: the active composition used a CWD-relative seam that addressed `File("mesh.db")` -- on Android, a
 * path under `/`, where nobody wrote anything -- so `ARTIFACTS_DELETED` was a claim about files that never existed.* The
 * A10 follow-up: verification against LOGICAL aliases certified nothing either.
 *
 * *** THIS SEAM ASKS THE ESTATE THAT WROTE THE FILES, VERIFIES THE SURVIVORS IT REALLY OWNS, AND FALLS BACK TO THE
 * ISLE'S OWN OWNER-DEFINED SEAM ONLY FOR A NAME THE ESTATE DOES NOT CLAIM. *** *A throw from the owner becometh a
 * preserved, retryable `Failed` -- never a silent success.*
 */
private class LabEstateArtifactSeam(
    private val estate: LabEstateWipeAuthority,
    private val base: io.godstone.mesh.identity.ArtifactFileSystemSeam,
) : io.godstone.mesh.identity.ArtifactFileSystemSeam {

    override fun deleteArtifact(path: String): io.godstone.mesh.identity.FileDeletionResult {
        val result = estate.destroyFamily(path)
        // *A family the ESTATE owned is answered by the estate's own verdict; one it does not claim is the isle's own
        // owner-defined family, which the base seam still resolves.*
        return if (result is io.godstone.mesh.identity.FileDeletionResult.Absent) base.deleteArtifact(path) else result
    }

    override fun exists(path: String): Boolean =
        estate.familyExists(path) || base.exists(path)

    override fun isReadable(path: String): Boolean = base.isReadable(path)
}

/**
 * *** GS-FINAL-003 `recovery-identity` (review A4): THE LADDER'S IDENTITY SEAM, OVER THE LAB ESTATE'S OWN LABELS. ***
 *
 * *THE A4 CHARGE: an existing encrypted identity survived the master-KEK deletion and the replacement loadOrCreate could
 * not decrypt it, so the wipe parked at `ARTIFACTS_DELETED` for ever.* **This seam ERASES every label's identity
 * material and VERIFIES it is gone, then publishes a fresh identity through the RECOVERY-ONLY factory** -- never the
 * `PrivateOwnerToken`-gated normal owner. *`null` is the seam's typed "NOT PUBLISHED", so a host without a keystore
 * stays PENDING rather than claiming a new name.*
 */
private class LabEstateIdentitySeam(
    private val estate: LabEstateWipeAuthority,
) : io.godstone.mesh.identity.IdentityAuthoritySeam {

    override fun publishNewIdentity(): String? {
        if (!estate.eraseIdentityFamily()) return null
        return estate.publishFreshIdentity()
    }

    /** *The seam's read has no production caller (the coordinator asketh only [publishNewIdentity]); null, not a mint.*/
    override fun identity(): String? = null
}
