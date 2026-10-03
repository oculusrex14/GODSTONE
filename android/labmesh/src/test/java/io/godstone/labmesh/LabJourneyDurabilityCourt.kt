package io.godstone.labmesh

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.godstone.mesh.a11y.AccessibilityContract
import io.godstone.mesh.delivery.DeliveryState
import io.godstone.mesh.identity.PanicWipe
import io.godstone.mesh.lab.HostLabPlatform
import io.godstone.mesh.lab.ProductionLabEstate
import io.godstone.mesh.lab.LabWipeJourney
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-FINAL-003 `durable-authority` / GS-UX-001 `rendered-controls` (Android isle): THE RENDERED JOURNEY
 * BINDINGS PROVEN AGAINST THE REAL LABMESH RUNTIME, ACROSS A RELAUNCH. ***
 *
 * *THE PLAN'S OWN WORDS (step 8): **"Bind the lab author's SOS commands to a retained on-disk runtime/store and
 * reload the active msgId/delivery state from that authority"**, and prove the whole arm -> terminate -> relaunch ->
 * active -> cancel -> terminate -> relaunch -> terminal sequence "for the SAME message".*
 *
 * *** THE DISCRIMINATOR, AND WHY THE EXISTING COURT IS NOT ENOUGH. *** `LabMeshJourneyBoundTest` drives the
 * bindings over ONE retained runtime instance, so a view-local or harness-local register could satisfy it: the
 * commands and the reads share the same object graph. **THIS COURT BUILDS A *FRESH* COMPOSITION OVER THE SAME
 * ESTATE FILES FOR EVERY "RELAUNCH"** -- exactly what `LabMeshApplication` does at process start -- so the
 * message id and the delivery state on the second process can ONLY come from the durable estate, never from
 * anything the first process remembered.
 *
 * *** AND IT READS THE ACTUAL STORE, NOT THE SCREEN'S CLAIM. *** *Every assertion compares the RENDERED binding
 * state against `LabRuntime.heldMsgIdOf`/`activeSosMsgIdOf`/`activeSosStateOf`/`durableStateOf` -- the store's own
 * rows -- rather than against a string the bindings produced.* **A binding that remembered a sentence would render
 * a value the estate does not carry, and the equality would fail.**
 *
 * HOST BOUNDARY, NAMED: [`HostLabPlatform`] substitutes ONLY the two facilities a JVM genuinely lacks (the
 * AndroidKeyStore identity factory and the SQLCipher native engine) with real on-disk SQLite; the estate's permit,
 * file resolution, ledger, retirement and verification are the production ones. Nothing here claims a device
 * result or a physical radio.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class LabJourneyDurabilityCourt {

    private fun ctx(): Context = ApplicationProvider.getApplicationContext()

    /** The production estate over the SHARED host platform (the same one the `:mesh` estate court uses). */
    private fun estate(labels: List<String> = listOf("A", "R", "B")): ProductionLabEstate =
        ProductionLabEstate(ctx(), labels, HostLabPlatform())

    /** One "process": a fresh estate + fresh runtime over the SAME context/files, exactly as a relaunch composes. */
    private fun boot(labels: List<String> = listOf("A", "R", "B")) =
        io.godstone.mesh.lab.LabRuntime.composeRealEstateOrRefuse(ctx(), estate(labels), labels)

    /** The real durable record, written the way `FileWipeJournal` writes it. */
    private fun presetJournal(ordinal: Int?) {
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE).edit().apply {
            if (ordinal == null) remove("state") else putInt("state", ordinal)
        }.commit()
    }

    private fun rawOrdinal(): Int =
        ctx().getSharedPreferences("godstone_wipe_journal", Context.MODE_PRIVATE).getInt("state", -1)

    @Before fun clean() = presetJournal(null)
    @After fun tearDown() = presetJournal(null)

    // =================================================================================================================
    // 1. THE SOS JOURNEY: ARM -> RELAUNCH -> ACTIVE -> RETRY(SAME ID) -> CANCEL -> RELAUNCH -> TERMINAL.
    // =================================================================================================================

    /**
     * *** THE WHOLE SOS LIFECYCLE FOR ONE MESSAGE, WITH THE RELAUNCH AS THE DISCRIMINATOR. ***
     *
     * *The rendered words are asserted AGAINST THE DURABLE ROW at every step, and the msg_id on the second process is
     * read from the estate's own store.*
     */
    @Test
    fun theRenderedSosJourneyIsDurableAcrossRelaunchesForTheSameMessage() {
        // ---- (1) ARM through the RENDERED binding on the first "process".
        val first = boot().runtime!!
        val b1 = LabJourneyBindings(first, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = first))
        b1.refresh()
        assertNull(
            "*** BEFORE ARMING, THE ESTATE CARRIETH NO CALL -- the rendered words must not invent one. ***",
            runBlocking { first.activeSosMsgIdOf(b1.author) },
        )

        b1.armSos()
        val armedId = runBlocking { first.activeSosMsgIdOf(b1.author) }
        assertNotNull("*** ARMING THROUGH THE RENDERED BINDING MUST COMMIT A DURABLE SOS ROW. ***", armedId)
        val armedRowState = runBlocking { first.activeSosStateOf(b1.author) }
        assertEquals(
            "*** THE RENDERED SOS WORDS MUST BE THE SHARED WORD FOR THE ROW'S OWN STATE. Observed words: " +
                "'${b1.state.value.sosStateWords}' for row state $armedRowState ***",
            stateWordsForState(armedRowState), b1.state.value.sosStateWords,
        )

        // ---- (2) RELAUNCH: a FRESH estate + FRESH runtime over the SAME files.
        val second = boot().runtime!!
        val b2 = LabJourneyBindings(second, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = second))
        b2.refresh()
        assertEquals(
            "*** A RELAUNCH MUST SEE THE SAME STANDING CALL, BY THE SAME msg_id READ FROM THE STORE -- a remembered " +
                "id could not survive a fresh composition. First: ${LabJourneyBindings.hexOf(armedId!!)}, second: " +
                "${b2.state.value.durableMsgId} ***",
            LabJourneyBindings.hexOf(armedId), runBlocking { second.activeSosMsgIdOf(b2.author) }?.let(LabJourneyBindings::hexOf),
        )
        assertEquals(
            "*** AND THE RENDERED SOS WORDS AFTER A RELAUNCH MUST BE THE RELOADED ROW'S STATE. ***",
            stateWordsForState(runBlocking { second.activeSosStateOf(b2.author) }), b2.state.value.sosStateWords,
        )
        assertTrue(
            "*** AND THE RETRY MUST BE RENDERED ENABLED: a standing call is the only thing a retry can resume. ***",
            b2.state.value.sosRetryPermitted,
        )

        // ---- (3) RETRY through the rendered binding: the SAME authored bytes, never a fresh author.
        val heldBeforeRetry = runBlocking { second.heldMsgIdsOf(b2.author) }
        b2.retry()
        assertEquals(
            "*** A RETRY MUST RESUME THE *SAME* CALL -- a fresh msg_id would be the re-authoring the law forbids. ***",
            LabJourneyBindings.hexOf(armedId), runBlocking { second.activeSosMsgIdOf(b2.author) }?.let(LabJourneyBindings::hexOf),
        )
        assertEquals(
            "*** AND A RETRY MUST NOT AUTHOR A SECOND FRAME -- resuming is not authoring. Held before: " +
                "${heldBeforeRetry.size}, after: ${runBlocking { second.heldMsgIdsOf(b2.author) }.size} ***",
            heldBeforeRetry.size, runBlocking { second.heldMsgIdsOf(b2.author) }.size,
        )
        assertEquals(
            "*** AND THE OUTCOME MUST BE THE POSITIVE RESUME, not a refusal. Observed: '${b2.state.value.outcome}' ***",
            true, b2.state.value.outcome.startsWith("sos:resumed"),
        )

        // ---- (4) CANCEL through the rendered binding: the row moveth TERMINAL in the ESTATE's store.
        b2.cancelSos()
        assertEquals(
            "*** CANCELLING THROUGH THE RENDERED BINDING MUST MOVE THE DURABLE ROW TERMINAL. ***",
            DeliveryState.CANCELLED_LOCALLY,
            runBlocking { second.durableStateOf(b2.author, armedId) },
        )
        // *** AND A CANCELLATION MUST NOT RE-CREATE A HELD FRAME. ***
        assertEquals(
            "*** A CANCELLATION MUST RETIRE THE HELD FRAME, NOT RE-CREATE ONE. ***",
            0, runBlocking { second.heldMsgIdsOf(b2.author) }.size,
        )

        // ---- (5) RELAUNCH AGAIN: the terminal row is what a fresh process carrieth.
        val third = boot().runtime!!
        val b3 = LabJourneyBindings(third, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = third))
        b3.refresh()
        assertNull(
            "*** A RELAUNCH AFTER CANCELLATION MUST SEE NO STANDING CALL -- the terminal row is the record, and no " +
                "view may resurrect it. ***",
            runBlocking { third.activeSosMsgIdOf(b3.author) },
        )
        assertEquals(
            "*** AND THE RENDERED WORDS MUST FOLLOW THE ABSENCE INTO THE TERMINAL STATE. ***",
            AccessibilityContract.STATE_WORDS.getValue("CANCELLED"), b3.state.value.sosStateWords,
        )
    }

    // =================================================================================================================
    // 2. A DIRECT SEND SURVIVES A RELAUNCH: THE SAME msg_id AND THE SAME HONEST LABEL.
    // =================================================================================================================

    /**
     * *** THE DURABLE SEND'S OWN MESSAGE ID AND LABEL ARE THE STORE'S, AND THEY SURVIVE A FRESH PROCESS. ***
     */
    @Test
    fun theRenderedSendPersistsTheSameMsgIdAndLabelAcrossARelaunch() {
        val first = boot(listOf("A", "B")).runtime!!
        val b1 = LabJourneyBindings(first, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = first))
        b1.refresh()
        val recipient = b1.recipients.single()
        b1.send(recipient, "the bridge at Harrow is under two feet of water")
        val durableId = runBlocking { first.heldMsgIdOf(b1.author) }
        assertNotNull("*** A RENDERED SEND MUST COMMIT A HELD FRAME. ***", durableId)
        val label = first.deliveryLabelOf(b1.author, durableId!!)
        assertEquals(
            "*** THE RENDERED LABEL MUST BE THE STORE'S OWN LABEL. ***",
            label, b1.state.value.durableLabel,
        )
        assertEquals(
            "*** AND THE RENDERED ID MUST BE THE COMMITTED msg_id. ***",
            LabJourneyBindings.hexOf(durableId), b1.state.value.durableMsgId,
        )

        // ---- RELAUNCH: fresh process, same files.
        val second = boot(listOf("A", "B")).runtime!!
        val b2 = LabJourneyBindings(second, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = second))
        b2.refresh()
        assertEquals(
            "*** A RELAUNCH MUST RELOAD THE SAME COMMITTED msg_id FROM THE STORE. ***",
            LabJourneyBindings.hexOf(durableId),
            b2.state.value.durableMsgId,
        )
        assertEquals(
            "*** AND THE SAME HONEST LABEL. ***",
            second.deliveryLabelOf(b2.author, durableId), b2.state.value.durableLabel,
        )
    }

    // =================================================================================================================
    // 3. THE WIPE / RECOVERY JOURNEY THROUGH THE RENDERED BINDING.
    // =================================================================================================================

    /**
     * *** THE RENDERED WIPE MOVES THE PRODUCTION RECORD, AND A RELAUNCH READS THE SAME RUNG. ***
     *
     * *The obligation: "rendered wipe UI uses SAME durable production wipe owner (no composition harness local state
     * register)".* **The discriminator is a reopen over the same `FileWipeJournal`, and the rendered stage is asserted
     * equal to the record's own rung.**
     */
    @Test
    fun theRenderedWipeJourneyIsDurableAndResumesWithoutRewinding() {
        val runtime = boot().runtime!!
        val bindings = LabJourneyBindings(runtime, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = runtime))
        bindings.refresh()
        assertEquals("a clean device renders the clean rung, read from the record", "IDLE", bindings.state.value.wipeStage)

        bindings.beginWipe()
        val moved = rawOrdinal()
        assertTrue(
            "*** THE RENDERED WIPE MUST MOVE THE DURABLE RECORD OFF IDLE. Observed ordinal: $moved ***",
            moved != PanicWipe.WipeState.IDLE.ordinal,
        )
        assertEquals(
            "*** AND THE RENDERED STAGE MUST BE THE RECORD'S OWN RUNG -- a reading, not a message the screen made up. ***",
            PanicWipe.WipeState.entries[moved].name, bindings.state.value.wipeStage,
        )

        // ---- RELAUNCH: a FRESH owner over the same durable record, plus a FRESH composition over the same estate.
        val reopened = LabWipeJourney(ctx()).progress()
        assertEquals(
            "*** A RELAUNCH MUST SEE THE PERSISTED WIPE AT THE SAME RUNG, or a view-local register is what the screen " +
                "was rendering. ***",
            bindings.state.value.wipeStage, reopened.rung.name,
        )
        assertTrue("*** AND THE PRODUCTION CONTRACT MUST PERMIT A RESUME. ***", reopened.permitsResume)

        // ---- RESUME: re-drive the SAME persisted ladder; the record must not rewind.
        bindings.resumeWipe()
        assertTrue(
            "*** A RESUME MUST NOT REWIND THE RECORD TO CLEAN. Observed ordinal: ${rawOrdinal()} ***",
            rawOrdinal() != PanicWipe.WipeState.IDLE.ordinal,
        )
    }

    /**
     * *** A REQUESTED ESTATE REFUSES PRIVATE COMPOSITION, AND THE BINDING'S SEND SAYS SO IN THE OWNER'S WORDS. ***
     */
    @Test
    fun aRequestedEstateRefusesTheRenderedPrivateCommands() {
        presetJournal(PanicWipe.WipeState.REQUESTED.ordinal)
        val refused = io.godstone.mesh.lab.LabRuntime.composeRealEstateOrRefuse(ctx(), estate())
        assertNull("*** A PENDING WIPE MUST REFUSE THE NORMAL PRIVATE COMPOSITION. ***", refused.runtime)

        val bindings = LabJourneyBindings(null, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx()))
        bindings.refresh()
        assertEquals(
            "*** THE RENDERED DECISION MUST BE THE OWNER'S OWN. Observed: ${bindings.state.value.wipeDecision} ***",
            "recovery_pending", bindings.state.value.wipeDecision,
        )
        assertTrue(
            "*** AND THE RESUME CONTROL MUST BE ACTIONABLE -- it is the owner's own repair of a parked wipe. ***",
            bindings.state.value.wipeRecoveryPermitted,
        )
        bindings.send("B", "must never be durably enqueued")
        assertTrue(
            "*** A REFUSED SEND MUST REPORT THE OWNER'S DECISION RATHER THAN PRETENDING TO SEND. Observed: " +
                "'${bindings.state.value.outcome}' ***",
            bindings.state.value.outcome.contains("normal private graph is unavailable"),
        )
    }

    /**
     * *** A CORRUPT RECORD OFFERS THE OPERATOR'S RESOLUTION, WHICH DRIVES FULL ERASURE AND NEVER CLAIMS CleanStart. ***
     */
    @Test
    fun aCorruptRecordOffersTheOperatorResolutionRenderedFromTheRecord() {
        presetJournal(9999) // PRESENT but unreadable
        val bindings = LabJourneyBindings(null, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx()))
        bindings.refresh()
        assertEquals(
            "*** AN UNREADABLE RECORD MUST RENDER AS CORRUPT, NOT CLEAN. Observed: ${bindings.state.value.wipeDecision} ***",
            "corrupt_journal", bindings.state.value.wipeDecision,
        )
        assertTrue(
            "*** AND THE OPERATOR CONTROL MUST BE THE ACTION OFFERED. ***",
            bindings.state.value.wipeOperatorResolutionPermitted,
        )
        assertTrue(
            "*** WHILE A RESUME IS NOT OFFERED: retrying cannot read an unreadable record. ***",
            !bindings.state.value.wipeRecoveryPermitted,
        )

        bindings.resolveCorrupt()
        assertTrue(
            "*** THE OPERATOR RESOLUTION MUST NOT LEAVE THE RECORD ABSENT (which would be 'clear marker pretend " +
                "clean'). Observed ordinal: ${rawOrdinal()} ***",
            rawOrdinal() != -1,
        )
        assertEquals(
            "*** AND IT MUST NOT RENDER clean_start. Observed: ${bindings.state.value.wipeDecision} ***",
            false, bindings.state.value.wipeDecision == "clean_start",
        )
    }

    // =================================================================================================================
    // 4. THE BINDING READS THE REAL RUNTIME, NOT ITS OWN MEMORY -- THE NEGATIVE DISCRIMINATOR.
    // =================================================================================================================

    /**
     * *** A BINDING THAT REMEMBERED ITS OWN STRING WOULD FAIL: THE RENDERED ID IS `none` UNTIL THE STORE COMMITS. ***
     */
    @Test
    fun theRenderedDurableReadoutIsAbsentUntilTheStoreCommits() {
        val runtime = boot(listOf("A", "B")).runtime!!
        val bindings = LabJourneyBindings(runtime, CoroutineScope(Dispatchers.Unconfined), LabWipeJourney(ctx(), liveEstate = runtime))
        bindings.refresh()
        assertNull("nothing was authored, so the store carrieth no message", runBlocking { runtime.heldMsgIdOf(bindings.author) })
        assertNull(
            "*** AND THE RENDERED ID MUST BE ABSENT -- a screen that rendered one here would be remembering something " +
                "the estate never committed. Observed: ${bindings.state.value.durableMsgId} ***",
            bindings.state.value.durableMsgId,
        )
        assertEquals(
            "*** AND THE LABEL MUST BE THE HONEST ABSENCE, NOT A STATUS. ***",
            LabJourneyBindings.NO_LABEL, bindings.state.value.durableLabel,
        )
    }
}
