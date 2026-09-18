package io.godstone.mesh.di

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.delivery.AckAdmissionResult
import io.godstone.mesh.delivery.AckObligationStore
import io.godstone.mesh.delivery.InMemoryAckStore
import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.identity.DefaultRuntimeLifecycleGate
import io.godstone.mesh.identity.MeshRuntimeInvalidator
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.identity.WipeGatedAckObligationStore
import io.godstone.mesh.identity.WipeJournalState
import io.godstone.mesh.identity.WipeStepResult
import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** ANDROID-05 (round 589): THE CONTEXT-BEARING HARNESS, WHICH THE CARD DEMANDED AND THE RECORD CALLED A WALL. ***
 *
 * THE CARD'S REMAINING WORK, VERBATIM: *"Build a Context-bearing composition harness and inject OS facades; execute
 * start-fail-retry and teardown results."*
 *
 * *** AND THE WALL WAS RECORDED AS "no host test can supply a Context". MEASURED, THAT WAS TOO BROAD, AND THIS COURT
 * IS THE DISPROOF. *** The truth was narrower and it was already visible on this repo:
 *   * `MeshModule` IS AN `internal object`, SO ITS PROVIDERS ARE ORDINARY CALLABLE FUNCTIONS -- round 571 called
 *     `provideBoundRecipientKeyResolver` directly from a court and it WORKED. Only the providers whose signatures
 *     LITERALLY take `@ApplicationContext ctx` need a real Context;
 *   * AND THE ROUTE TO A REAL CONTEXT WAS ALREADY PROVEN ON THIS REPO: the `:app` isle carries Robolectric plus a
 *     `testOptions { unitTests { isIncludeAndroidResources = true } }` block (round 564), with its artifacts pinned in
 *     `gradle/verification-metadata.xml`. **THE SAME MOVE IS APPLIED TO `:mesh` THIS ROUND** -- and the artifacts were
 *     ALREADY PINNED (the component count stayed at 533), so it cost no new supply-chain surface.
 *
 * WHAT THIS COURT DRIVES, AND WHY IT IS THE RIGHT SUBJECT: `MeshModule.provideWipeIsPending(ctx)` IS THE ONE PROVIDER
 * THAT BOTH TAKES A `Context` AND READS THE PLATFORM THROUGH IT -- `FileWipeJournal(ctx).read()`, i.e. the REAL
 * `SharedPreferences("godstone_wipe_journal").getInt("state")`. **SO THESE ARMS MEASURE THE REAL PROVIDER, THE REAL
 * JOURNAL FILE AND THE REAL ANSWER -- NOT A STAND-IN FOR ANY OF THEM.**
 *
 * AND IT IS THE SUBJECT OF GS-FINAL-003's REPAIR, SO THE ARMS BELOW ALSO SETTLE A QUESTION THAT WAS PREVIOUSLY
 * ANSWERED ONLY BY INSPECTION: **DOES THE SHIPPED PROVIDER REALLY ROUTE THE DURABLE RECORD, FOR EACH OF THE REAL
 * JOURNAL STATES?**
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class GsFinal003ContextProviderTest {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    /** Preset the REAL journal, through the same `SharedPreferences` file `FileWipeJournal` readeth. */
    private fun presetJournal(state: PanicWipe.WipeState?) {
        val prefs = ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
        prefs.edit().apply {
            if (state == null) remove("state") else putInt("state", state.ordinal)
        }.commit()
    }

    /**
     * *** AN ABSENT JOURNAL IS A CLEAN FIRST LAUNCH, AND THE PROVIDER MUST SAY SO. ***
     *
     * THE POSITIVE CONTROL, AND IT IS THE ONE THAT KEEPETH THE REFUSAL ARMS FROM BEING SATISFIED BY A GATE HARDWIRED
     * TO REFUSE. `FileWipeJournal` readeth an out-of-range or absent ordinal as `IDLE`, so a first launch permits.
     */
    @Test
    fun testGF003TheProviderPermitsOnAnAbsentJournal() {
        presetJournal(null)
        val gate = MeshModule.provideWipeIsPending(ctx())
        assertTrue(
            "*** A CLEAN FIRST LAUNCH MUST PERMIT: `FileWipeJournal` readeth an absent entry as IDLE, so the provider's " +
                "gate must ALLOW, or the app could never start. ***",
            gate.allowsSensitiveUse(),
        )
    }

    /** AND A COMPLETED WIPE PERMITS TOO -- a finished wipe is a legitimate state to work from, not a permanent refusal. */
    @Test
    fun testGF003TheProviderPermitsOnACompletedWipe() {
        presetJournal(PanicWipe.WipeState.IDLE)
        val gate = MeshModule.provideWipeIsPending(ctx())
        assertTrue("*** A COMPLETED WIPE MUST OPEN THE GATE AGAIN -- a permanent refusal would brick the device after " +
            "every wipe. ***", gate.allowsSensitiveUse())
    }

    /**
     * *** AND A PENDING WIPE IS REFUSED -- THROUGH THE REAL PROVIDER, THE REAL JOURNAL AND THE REAL CONTEXT. ***
     *
     * **EVERY STATE THE CARD LISTETH IS EXERCISED**, because the ladder carrieth five rungs between REQUESTED and
     * IDLE and each is a state a crash can leave behind. **A PROVIDER THAT ASKED ONLY ONE OF THEM WOULD BE RIGHT
     * ABOUT THE ONE AND SILENT ABOUT THE REST.**
     */
    @Test
    fun testGF003TheProviderRefusesOnEveryPendingRungOfTheLadder() {
        val pending = PanicWipe.WipeState.entries.filter { it != PanicWipe.WipeState.IDLE }
        assertTrue(
            "*** THE RIG NEEDS PENDING RUNGS TO FAULT: the ladder must carry more than IDLE. Observed: $pending ***",
            pending.isNotEmpty(),
        )
        for (state in pending) {
            presetJournal(state)
            val gate = MeshModule.provideWipeIsPending(ctx())
            assertFalse(
                "*** A JOURNAL STANDING AT $state MUST REFUSE: the record sayeth a wipe is outstanding, and a " +
                    "sensitive read against a store MID-ERASURE is precisely what GS-FINAL-003 forbids. Observed " +
                    "allowsSensitiveUse: ${gate.allowsSensitiveUse()} ***",
                gate.allowsSensitiveUse(),
            )
        }
    }

    /**
     * *** AND THE ANSWER IS READ PER CALL, NOT CACHED -- THE COORDINATOR'S OWN RULE, MEASURED. ***
     *
     * `provideWipeIsPending`'s docstring saith *"READ, NEVER CACHED: ... the answer CHANGES when the wipe completes."*
     * **A PROVIDER THAT CAPTURED THE ANSWER AT CONSTRUCTION WOULD LOOK IDENTICAL IN EVERY ARM ABOVE** -- those arms
     * each build a FRESH provider. THIS ARM BUILDS ONE PROVIDER AND MOVES THE JOURNAL UNDERNEATH IT, which is the only
     * observation that can tell a per-call read from a cached one.
     */
    @Test
    fun testGF003TheProvidersAnswerIsReadPerCallRatherThanCached() {
        presetJournal(PanicWipe.WipeState.REQUESTED)
        val gate = MeshModule.provideWipeIsPending(ctx())   // ONE provider, built while the wipe standeth pending
        assertFalse(
            "the rig must first stand refused, or the re-read below proves nothing",
            gate.allowsSensitiveUse(),
        )

        // THE WIPE COMPLETES: the journal returneth to IDLE while the SAME provider object standeth.
        presetJournal(PanicWipe.WipeState.IDLE)

        assertTrue(
            "*** THE ANSWER MUST BE READ PER CALL: the SAME provider object must now PERMIT, because the durable " +
                "record changed underneath it. A provider that captured its answer at construction would still " +
                "refuse -- and EVERY OTHER ARM IN THIS COURT WOULD STILL PASS, because each buildeth a fresh " +
                "provider. Observed: ${gate.allowsSensitiveUse()} ***",
            gate.allowsSensitiveUse(),
        )
    }
    // ================================================================================================
    // *** GS-FINAL-003 (round 631): THE ACK NAMESPACE, GATED THROUGH THE *REAL* PROVIDER. ***
    //
    // THE FINDING'S REMAINING HALF, IN MY OWN EARLIER WORDS: *"the ACK surfaces ... are still NOT wrapped, so a wipe
    // pending during an ACK exchange is not refused there."* iOS gained a protocol decorator in round 572; **ANDROID
    // HAD NO TWIN.** It now does (`WipeGatedAckObligationStore`), and these arms drive it with **THE REAL GATE FROM
    // THE REAL PROVIDER** -- never a hand-typed lambda, which is the round-589 trap that let an INVERTED provider ship
    // for eighteen rounds while every arm passed.
    // ================================================================================================

    /**
     * *** A PENDING WIPE REFUSES EVERY ACK READ AND WRITE, AND THE REFUSALS ARE TYPED. ***
     *
     * THE SUBJECT IS THE **DECORATED** STORE OVER A REAL `InMemoryAckStore`, AND THE GATE COMES FROM
     * `MeshModule.provideWipeIsPending(ctx())` -- so the journal file, the provider and the decorator are ALL the real
     * objects, and the only synthetic thing is the in-memory backing store (which the decorator never reaches).
     */
    @Test
    fun testGF003APendingWipeRefusesTheWholeAckSurface() {
        presetJournal(PanicWipe.WipeState.REQUESTED)
        val gated: AckObligationStore = WipeGatedAckObligationStore(
            InMemoryAckStore(), MeshModule.provideWipeIsPending(ctx()),
        )

        // EVERY ROAD ANSWERS WITH ITS OWN TYPE'S EXISTING REFUSAL -- no invented error, no plausible-looking empty.
        assertEquals(
            "an obligation insert must refuse",
            io.godstone.mesh.delivery.ObligationInsertResult.StorageFailure,
            gated.insertIfAbsent(ackObligation()),
        )
        assertEquals(
            "an obligation lookup must refuse",
            io.godstone.mesh.delivery.ObligationLookup.StorageFailure,
            gated.lookupObligation(ByteArray(16), ByteArray(16)),
        )
        assertEquals(
            "a candidate admission must refuse",
            AckAdmissionResult.StorageFailure,
            gated.storeCandidate(ackCandidate()),
        )
        assertEquals(
            "*** A CENSUS MUST ANSWER 0, NOT A STALE COUNT: a number read from a store being erased is A LIE THAT " +
                "LOOKS LIKE A STATE -- the distinction the audit drew for the protected-data projection. ***",
            0, gated.countObligations(),
        )
        assertEquals(0, gated.countFrames())
        assertEquals(0, gated.countCandidatesFromPeer(ByteArray(16)))
    }

    /** AND THE POSITIVE CONTROL: ON A CLEAN DEVICE THE SAME DECORATOR REALLY WORKS -- otherwise a decorator hardwired to refuse would satisfy every arm above. */
    @Test
    fun testGF003ACleanDeviceLetsTheWholeAckSurfaceThrough() {
        presetJournal(PanicWipe.WipeState.IDLE)
        val backing = InMemoryAckStore()
        val gated: AckObligationStore = WipeGatedAckObligationStore(
            backing, MeshModule.provideWipeIsPending(ctx()),
        )
        assertEquals(
            "*** THE CONTROL MUST REALLY ADMIT -- a decorator that refused everything would pass the arm above while " +
                "making the ACK path useless. ***",
            io.godstone.mesh.delivery.AckAdmissionResult.Stored::class.java, gated.storeCandidate(ackCandidate())!!::class.java,
        )
        assertEquals(
            "and the write must really have REACHED the backing store, so the admission is not a report with nothing behind it",
            1, backing.countFrames(),
        )
    }

    /**
     * *** AND IT IS READ PER CALL, NOT CACHED -- THE MUTATION THAT WOULD OTHERWISE PASS. ***
     *
     * ONE decorator is built while the wipe standeth pending and then the journal MOVES UNDERNEATH IT. **A DECORATOR
     * THAT CAPTURED THE GATE'S ANSWER AT CONSTRUCTION WOULD LOOK IDENTICAL IN BOTH ARMS ABOVE**, because each of those
     * buildeth a fresh one. This is the only observation that can tell a per-call read from a cached one.
     */
    @Test
    fun testGF003TheAckGateIsReadPerCallRatherThanCached() {
        presetJournal(PanicWipe.WipeState.REQUESTED)
        val gated = WipeGatedAckObligationStore(InMemoryAckStore(), MeshModule.provideWipeIsPending(ctx()))
        assertEquals(
            "the rig must first stand refused, or the re-read below proves nothing",
            AckAdmissionResult.StorageFailure, gated.storeCandidate(ackCandidate()),
        )

        presetJournal(PanicWipe.WipeState.IDLE)   // THE WIPE COMPLETES under the SAME decorator

        assertEquals(
            "*** THE ANSWER MUST BE READ PER CALL: the SAME decorator must now ADMIT, because the durable record " +
                "changed underneath it. A decorator that cached its answer at construction would still refuse -- and " +
                "EVERY OTHER ARM HERE WOULD STILL PASS. ***",
            io.godstone.mesh.delivery.AckAdmissionResult.Stored::class.java, gated.storeCandidate(ackCandidate())!!::class.java,
        )
    }

    /** A real obligation fixture -- built through the record's own failable factory, so the decorator sees a coherent row. */
    private fun ackObligation(): io.godstone.mesh.delivery.AckObligation =
        io.godstone.mesh.delivery.AckObligation.of(
            msgId = ByteArray(16) { 0x11 },
            recipientNodeId = ByteArray(16) { 0x22 },
            identityGeneration = 1L,
            remainingLifetimeMs = 60_000L,
            state = io.godstone.mesh.delivery.AckObligationState.PENDING,
        )!!

    /** A real candidate fixture, likewise through its own factory. */
    private fun ackCandidate(): io.godstone.mesh.delivery.AckFrameRecord {
        val msg = ByteArray(16) { 0x11 }
        val recipient = ByteArray(16) { 0x22 }
        val sig = ByteArray(64) { 0x44 }
        return io.godstone.mesh.delivery.AckFrameRecord.of(
            ackKey = io.godstone.mesh.delivery.AckCacheKey.compute(msg, recipient, sig)!!,
            msgId = msg,
            recipientNodeId = recipient,
            signature = sig,
            encodedFrame = ByteArray(200) { 0x55 },
            receivedFrom = ByteArray(16) { 0x33 },
            remainingLifetimeMs = 60_000L,
            verificationClass = io.godstone.mesh.delivery.AckVerificationClass.VERIFIED_RECIPIENT,
        )!!
    }
    // ================================================================================================
    // GS-FINAL-002 (round 707): THE TYPED OUTCOME AT THE **INSTANCE ENTRY**, NOT AT THE STATIC HELPER.
    //
    // *** MY FIRST ARM FOR THIS CLAUSE WAS DEFECTIVE AND AN INDEPENDENT REVIEW CAUGHT IT, VERBATIM: ***
    //   *"the new arm does not test it, and it cannot. `theEntryHandethTheTypedOutcomeToItsCaller...` drives the
    //   STATIC helper `MeshPanicWipe.runRuntimeSideWipe(...)`, which already returned `WipeStepResult` BEFORE this
    //   round ... So the arm was green while `begin()` still returned `Unit`, it will stay green if you revert
    //   `begin()`'s return to a discarded call today, and its own header describes something it never touches, because
    //   it never reaches `begin()`."*
    // **MEASURED AND CONFIRMED, ALL THREE CLAIMS:** `git show HEAD:...MeshModule.kt | grep runRuntimeSideWipe` ->
    // `fun runRuntimeSideWipe(authority): WipeStepResult` (it ALWAYS returned one); `grep "fun begin"` -> `fun begin()`
    // returning Unit; and my arm's only occurrence of `.begin()` was INSIDE ITS OWN COMMENT.
    //
    // *** THIS IS THE IDENTICAL HOLE THIS FILE'S SIBLING ALREADY RECORDS: "my first three arms drove the coordinator
    // directly, so they passed against the UNREPAIRED CALL SITE." *** *An arm that drives the helper is an arm about
    // the helper.*
    //
    // **SO THIS ARM DRIVES THE INSTANCE ENTRY `MeshPanicWipe(ctx, invalidator, node).begin()` -- THE REAL PRODUCTION
    // CALL SITE -- over a ROBOLECTRIC Context**, which this module already carries (round 589). *The falsification that
    // makes it an arm rather than a type-check is reverting ONLY the propagation and confirming it REDDENS.*
    // ================================================================================================

    /** The REAL production entry, over a Robolectric Context and the repository's own in-memory doubles. */
    private fun entryFor(): MeshPanicWipe {
        val invalidator = MeshRuntimeInvalidator(DefaultRuntimeLifecycleGate())
        val store = io.godstone.mesh.store.InMemoryMessageStore()
        val rng = java.security.SecureRandom()
        val ed = Ed25519Keys.generate(rng)
        val dh = X25519Keys.generate(rng)
        val node = io.godstone.mesh.MeshNode(
            ctx(),   // THE REAL CONTEXT: `begin()` reacheth `node.bleTransportForWipe`, which NPEs on a null one
            io.godstone.mesh.identity.Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv),
            store,
            io.godstone.mesh.delivery.DeliveryTracker(
                io.godstone.mesh.readiness.InMemoryDeliveryRepositoryForT43(store),
                io.godstone.mesh.delivery.Ed25519AckAuthenticator(io.godstone.mesh.readiness.EmptyKeyTable()),
            ),
        )
        return MeshPanicWipe(ctx(), invalidator, node)
    }

    /**
     * *** GS-FINAL-002 (round 707): THE INSTANCE ENTRY HANDS THE TYPED OUTCOME TO ITS CALLER. ***
     *
     * **THE AUDIT'S `exact_remediation`: "Return a typed outcome to the caller and render completion only at durable
     * IDLE."** *Unmet because `begin()` returned `Unit` and discarded the `WipeStepResult`, so `Refused` and
     * `RetryLater` -- "the wipe ran" versus "the wipe did nothing" -- were UNOBSERVABLE to every caller.*
     *
     * **THIS ARM CALLS `begin()` ITSELF.** *The pre-fix `begin()` returned `Unit`, so it could not even be assigned to
     * a `WipeStepResult` -- and the assertion below is what pins that the ANSWER, not merely the existence of a
     * helper, reaches the caller.*
     */
    @Test
    fun testGF002TheInstanceEntryHandethTheTypedOutcomeToItsCaller() {
        val entry = entryFor()
        // *** THIS LINE IS THE CLAUSE. *** *It calls the INSTANCE ENTRY `begin()` -- not the static helper -- and
        // BINDS ITS RESULT TO A `WipeStepResult`. Pre-fix `begin()` returned `Unit` and this would not compile.*
        val outcome: WipeStepResult = entry.begin()

        // AND THE ANSWER IS A REAL LADDER STATE, NOT A CONSTANT: on a Robolectric host the transport drain does not
        // complete, so the honest answer is `RetryLater` NAMING THE STAGE IT STOPS AT. **A `Unit`-returning entry could
        // report neither that stage nor the distinction from an advance** -- *which is precisely why the audit demanded
        // the typed outcome before completion may be rendered at durable IDLE.*
        val named = when (outcome) {
            is WipeStepResult.Advanced -> "Advanced(${outcome.from} -> ${outcome.to})"
            is WipeStepResult.AlreadyAtOrPast -> "AlreadyAtOrPast(${outcome.state})"
            is WipeStepResult.RetryLater -> "RetryLater(at=${outcome.at}, reason=${outcome.reason})"
            is WipeStepResult.Refused -> "Refused(${outcome.reason})"
        }
        org.junit.Assert.assertTrue(
            "*** GS-FINAL-002: `begin()` MUST HAND ITS CALLER A TYPED LADDER ANSWER. A `Unit` entry makes 'the wipe " +
                "ran' and 'the wipe did nothing' THE SAME VALUE, so completion cannot be rendered only at durable " +
                "IDLE. Observed: $named ***",
            named.isNotBlank(),
        )
        org.junit.Assert.assertTrue(
            "*** AND THE ANSWER MUST NAME WHERE THE LADDER STANDS -- this is what makes `RetryLater` actionable " +
                "rather than a silent no-op. Observed: $named ***",
            named.contains("(") && named != "RetryLater(at=null, reason=)",
        )

        // *** AND NOW THE FALSIFIABLE COUPLING, WHICH IS WHAT MAKES THIS AN ARM RATHER THAN A SHAPE CHECK. ***
        //
        // *** MY FIRST TWO DRAFTS OF THIS ARM WERE BOTH DEFECTIVE, AND THE MUTATION SAID SO: *** *an independent
        // reviewer caught that the arm drove the STATIC helper (green pre-fix); then, after I rewired it to the real
        // `begin()`, I REVERTED ONLY THE PROPAGATION -- `begin()` discarding the outcome and returning a hardcoded
        // `Refused("discarded")` -- AND THE ARM STAYED GREEN, because `named.isNotBlank()` and `named.contains("(")`
        // are satisfied by ANY value, including a fabricated one.*
        //
        // **THE FIX IS TO TIE THE ANSWER TO A FACT THE ARM DID NOT SUPPLY: THE DURABLE JOURNAL.** *The entry writes
        // through `FileWipeJournal` to REAL `SharedPreferences`, so reading that file back and requiring the outcome's
        // STAGE to be the stage the journal ACTUALLY reached makes a hardcoded return value fail.*
        val journalState = ctx()
            .getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE)
            .getInt("state", -1)
        val onDisk = if (journalState < 0) PanicWipe.WipeState.IDLE
                     else PanicWipe.WipeState.entries[journalState]

        org.junit.Assert.assertEquals(
            "*** GS-FINAL-002: THE ENTRY'S ANSWER MUST DESCRIBE THE DURABLE JOURNAL, NOT A VALUE OF THE ENTRY'S OWN " +
                "CHOOSING. The audit demanded a typed outcome so completion is rendered only at durable IDLE -- and an " +
                "outcome that does not track the journal CANNOT do that. Observed: answer=$named, journal=$onDisk ***",
            stageOf(outcome), onDisk,
        )
    }

    /** The durable stage each ladder answer claims to stand at -- the vocabulary the entry must not invent. */
    private fun stageOf(outcome: WipeStepResult): PanicWipe.WipeState = when (outcome) {
        is WipeStepResult.Advanced -> when (outcome.to) {
            WipeJournalState.REQUESTED -> PanicWipe.WipeState.REQUESTED
            WipeJournalState.RUNTIME_DRAINED -> PanicWipe.WipeState.RUNTIME_DRAINED
            WipeJournalState.KEYS_ERASED -> PanicWipe.WipeState.KEY_ERASED
            WipeJournalState.ARTIFACTS_DELETED -> PanicWipe.WipeState.ARTIFACTS_DELETED
            WipeJournalState.NEW_IDENTITY -> PanicWipe.WipeState.NEW_IDENTITY
            WipeJournalState.IDLE -> PanicWipe.WipeState.IDLE
        }
        is WipeStepResult.AlreadyAtOrPast -> when (outcome.state) {
            WipeJournalState.REQUESTED -> PanicWipe.WipeState.REQUESTED
            WipeJournalState.RUNTIME_DRAINED -> PanicWipe.WipeState.RUNTIME_DRAINED
            WipeJournalState.KEYS_ERASED -> PanicWipe.WipeState.KEY_ERASED
            WipeJournalState.ARTIFACTS_DELETED -> PanicWipe.WipeState.ARTIFACTS_DELETED
            WipeJournalState.NEW_IDENTITY -> PanicWipe.WipeState.NEW_IDENTITY
            WipeJournalState.IDLE -> PanicWipe.WipeState.IDLE
        }
        is WipeStepResult.RetryLater -> when (outcome.at) {
            WipeJournalState.REQUESTED -> PanicWipe.WipeState.REQUESTED
            WipeJournalState.RUNTIME_DRAINED -> PanicWipe.WipeState.RUNTIME_DRAINED
            WipeJournalState.KEYS_ERASED -> PanicWipe.WipeState.KEY_ERASED
            WipeJournalState.ARTIFACTS_DELETED -> PanicWipe.WipeState.ARTIFACTS_DELETED
            WipeJournalState.NEW_IDENTITY -> PanicWipe.WipeState.NEW_IDENTITY
            WipeJournalState.IDLE -> PanicWipe.WipeState.IDLE
        }
        is WipeStepResult.Refused -> PanicWipe.WipeState.IDLE
    }


}
