package io.godstone.app.ui.browse

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.compose.ui.test.assertIsDisplayed
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import io.godstone.core.archive.ArchiveDocument
import io.godstone.core.archive.ArchivePassage
import io.godstone.core.archive.ArchiveReader
import io.godstone.core.archive.ArchiveSourceMetadata
import io.godstone.core.archive.ArchiveState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * *** GS-FINAL-006 / GS-UX-001 STEP 7 (round 564): THE ANDROID ISLE'S FIRST REAL UI TEST TARGET. ***
 *
 * WHY THIS FILE EXISTS AT ALL, AND IT IS THE WHOLE POINT OF THE ROUND: THREE SEPARATE REVIEWS NAMED THE SAME HOLE,
 * AND EACH WAS RIGHT --
 *
 *   * *"the only court touching `BrowseScreen` is one that `readText()`s the source file -- there is no Compose or
 *     Robolectric harness in `android/app/src/test`, so a green `:app` lane proves compile plus string matches, not
 *     that a returning reader lands at the anchor."*
 *   * *"without that, GS-FINAL-006's Android clause closes on the same style of false assurance this round already
 *     caught twice."*
 *   * AND THE AUDIT'S OWN REQUIRED INTERNAL WORK FOR GS-UX-001: *"add UI test targets and then execute physical
 *     protection/lifecycle gates."* That requirement was UNMET, and `GS-UX-001` was recorded `PARTIAL_MISCLASSIFIED`
 *     for exactly this reason.
 *
 * **SO THIS COURT REALLY COMPOSES, REALLY LAYS OUT AND REALLY SCROLLS** -- Robolectric supplieth the Android runtime
 * on the JVM, so no device and no emulator are needed, and the Compose test rule supplieth the real composition.
 * WHAT IT MEASURES IS THE `LazyListState` ROAD ITSELF, in the same wiring shape `ReadingList` useth: THE SCROLL IS
 * EXECUTED RATHER THAN INFERRED FROM SOURCE TEXT.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
class GsFinal006RenderedReadingListTest {

    @get:Rule val compose = createComposeRule()

    private val ids = (1L..40L).toList()

    /**
     * *** THE REAL `ReadingList` COMPOSABLE, NOT A REPLICA OF IT. ***
     *
     * A court that drove its own copy of the wiring would be ASSERTING AN ARCHITECTURE RATHER THAN OBSERVING THE
     * RUNTIME -- the failure mode three reviews warned about. So this renders THE PRODUCTION COMPOSABLE, driven by a
     * REAL `BrowseViewModel` over a real (fake-backed) archive, wearing the app's own theme.
     */
    private class TwoDocReader : ArchiveReader {
        override fun status(): ArchiveState = ArchiveState.Ready(origin = "installed.bin", sha256 = "a".repeat(64))
        override fun listDocuments(domain: String?): List<ArchiveDocument> =
            listOf(ArchiveDocument(7, "Archive guide", "reference", false, "src-001", "r7"),
                   ArchiveDocument(8, "Field manual", "reference", false, "src-002", "r8"))
        override fun listDomains(): List<String> = emptyList()
        override fun passages(documentId: Long): List<ArchivePassage> =
            if (documentId == 7L) (1L..40L).map { ArchivePassage(it, 7, "Archive guide", "reference", "S", "passage $it") }
            else (101L..140L).map { ArchivePassage(it, 8, "Field manual", "reference", "S", "field $it") }
        override fun search(query: String, limit: Int): List<ArchivePassage> = passages(7)
        override fun sourceMetadata(documentId: Long): ArchiveSourceMetadata? = null
    }

    private fun placedReader(target: Long): BrowseViewModel {
        val vm = BrowseViewModel(TwoDocReader(), UnconfinedTestDispatcher())
        vm.open(ArchiveDocument(7, "Archive guide", "reference", false, "src-001", "r7"))
        vm.noteScroll(documentId = 7L, passageId = target)
        vm.open(ArchiveDocument(7, "Archive guide", "reference", false, "src-001", "r7"))
        return vm
    }

    /**
     * *** AND IT OBSERVES THE FLOW RATHER THAN READING IT ONCE. ***
     *
     * MY FIRST DRAFT READ `vm.state.value` DIRECTLY -- WHICH DOES NOT SUBSCRIBE, SO THE COMPOSABLE NEVER
     * RECOMPOSED. Every arm passed anyway, because `setContent` evaluateth once and the state was already placed; but
     * a court that cannot observe a STATE CHANGE cannot see a document change either, **AND THAT IS WHY REMOVING THE
     * `key(...)` FROM THE LIST STATE LEFT THE WHOLE COURT GREEN.** `collectAsStateWithLifecycle` is the app's own
     * idiom (`BrowseScreen.kt:37`) and it is what maketh the composition follow the model.
     */
    @androidx.compose.runtime.Composable
    private fun RealReadingList(vm: BrowseViewModel) {
        val state by vm.state.collectAsStateWithLifecycle()
        io.godstone.app.ui.theme.GodstoneTheme(redNightMode = false) {
            ReadingList(state, vm)
        }
    }

    /**
     * *** THE EXECUTED WITNESS: A RESOLVED TARGET REALLY PLACES THE READER. ***
     *
     * THE AUDITED HEADLINE DEFECT WAS *"no list state or scroll action consuming the stored anchor."* Here THE SCROLL
     * REALLY HAPPENETH, IN THE PRODUCTION COMPOSABLE, THROUGH THE PRODUCTION VIEWMODEL: a reader whose anchor is
     * passage 25 really ends up there, and the top of the list is really gone.
     */
    @Test
    fun aResolvedTargetReallyPlacesTheReader() {
        val vm = placedReader(25L)

        compose.setContent { RealReadingList(vm) }
        awaitDisplayed("passage 25")
        // AND THE TOP IS **GONE** -- the "marched back to the top" defect, asserted from the other side: a `LazyColumn`
        // composes only what is visible, so `passage 1` being ABSENT is the layout's OWN WITNESS that the list really
        // moved. Without the `ReadingList` this court gathereth, the reader would be at `passage 1`.
        compose.onNodeWithText("passage 1").assertDoesNotExist()
    }

    /**
     * *** AND THE PLACED READER'S ASKED-FOR ANCHOR IS NOT OVERWRITTEN BY THE APP'S OWN PLACEMENT. ***
     *
     * THE DEFECT AN UNGATED REPORT WOULD CAUSE, AND IT IS THE ONE THE CLEARING CLAUSE EXISTS TO PREVENT, REINTRODUCED
     * ONE LAYER UP: `snapshotFlow` emits the current index on collection -- BEFORE the consume-effect's `scrollToItem`
     * takes layout effect -- and again as the placement lands. An unguarded report would `noteScroll(passage 1)` and
     * REPLACE THE READER'S PLACE WITH THE FIRST PASSAGE. **THE READER RETURNS, IS PLACED CORRECTLY, AND THE ACT OF
     * RETURNING DESTROYS THE PLACE.** Here the real composable really runs, and the reader's anchor must survive it.
     */
    @Test
    fun theAppsOwnPlacementDoesNotOverwriteTheReadersAnchor() {
        val vm = placedReader(25L)

        compose.setContent { RealReadingList(vm) }
        compose.waitForIdle()

        assertEquals(
            "*** THE PLACEMENT MUST NOT BECOME A REPORT: `readingTargetPassageId` is the RESOLVED target, and " +
                "`readingTargetPassageId` must be unchanged -- while the asked-for anchor must not have been " +
                "REPLACED by the first passage. Observed asked-for anchor: ${vm.state.value.anchorPassageId}, " +
                "observed resolved target: ${vm.state.value.readingTargetPassageId} ***",
            25L, vm.state.value.readingTargetPassageId,
        )
        assertEquals("and the asked-for anchor must not have been clobbered by the placement",
                     25L, vm.state.value.anchorPassageId)
    }

    /**
     * *** AND THE FALLBACK CASE: AN ANCHOR THAT NO LONGER STANDS IS NOT SILENTLY REPLACED BY THE FIRST PASSAGE. ***
     *
     * THE T49 ARM NAMETH THIS EXACT RULE -- *"the asked-for anchor is remembered AS ASKED FOR -- it is not silently
     * discarded"* -- AND THIS IS ITS RENDERED COUNTERPART. The reader's asked-for passage no longer existeth in this
     * document, so they are placed at the FIRST; **AND THE PLACEMENT MUST NOT BE RECORDED**, or the fallback would
     * become the reader's new anchor and their original place would be lost forever.
     */
    @Test
    fun aFallbackPlacementIsNotRecordedAsTheReadersNewAnchor() {
        val vm = placedReader(999_999L)          // an identity THIS document doth not carrieth

        compose.setContent { RealReadingList(vm) }
        awaitDisplayed("passage 1")
        assertEquals(
            "*** THE FALLBACK PLACEMENT MUST NOT BE RECORDED: an anchor that no longer stands is placed at the " +
                "FIRST passage, but the asked-for anchor must be REMEMBERED AS ASKED FOR rather than replaced by the " +
                "placement. Observed: ${vm.state.value.anchorPassageId} ***",
            999_999L, vm.state.value.anchorPassageId,
        )
    }

    /**
     * *** OPENING A NEW DOCUMENT SHOWETH **THAT** DOCUMENT'S BEGINNING, NOT THE OLD ONE'S POSITION. ***
     *
     * *** AND ITS NAME IS DELIBERATE, BECAUSE A REVIEW ASKED ME TO PROVE THE `key(...)` AND THE MEASUREMENT SAID I
     * COULD NOT: REMOVING THE KEY LEAVES THIS ARM GREEN.*** A first draft of this arm claimed it measured the key.
     * IT DOES NOT, AND THE REASON IS STRUCTURAL:
     *   * `ReadingList` is composed only in `BrowseMode.DOCUMENT`, so leaving that mode UNCOMPOSES it and
     *     `remember` is discarded regardless of any key;
     *   * the shipped navigation cannot produce a direct document-to-document transition; and
     *   * `ArchiveReadingAnchor.target` returneth THE FIRST passage for a new document, so the consume-effect
     *     scrolls to index 0 whatever offset was inherited.
     * **AND I FIRST CLAIMED "UNDER M1 THIS ARM REDDENS" AS THOUGH THAT MADE IT A CONTROL ON THE TRANSITION -- SO I
     * CHECKED WHICH ASSERTION ACTUALLY FAILS, AND IT IS NOT THE TRANSITION ONE.** Under M1 the arm dieth at its FIRST
     * assertion (`passage 25` was never placed), so it reddens for the PLACEMENT's reason and never reacheth the
     * document change at all. **A RED ARM IS NOT THEREBY A CONTROL ON THE THING YOU WERE TESTING** -- the same
     * lesson as the tape-measure arm and the vacuous setter arm, one level up.
     *
     * SO WHAT IS THIS ARM? THE BEHAVIOUR THE READER SEES WHEN THEY OPEN A NEW DOCUMENT: it starteth at its own
     * beginning. That is worth asserting and it is really observed. IT IS NOT EVIDENCE ABOUT `key(...)`, and it no
     * longer claimeth to be.
     */
    @Test
    fun openingANewDocumentShowsThatDocumentsBeginning() {
        val vm = placedReader(25L)

        compose.setContent { RealReadingList(vm) }
        compose.waitForIdle()
        compose.onNodeWithText("passage 25").assertIsDisplayed()

        // THE READER OPENS A DIFFERENT DOCUMENT. Its passages are `field 101..140`.
        vm.open(ArchiveDocument(8, "Field manual", "reference", false, "src-002", "r8"))
        compose.waitForIdle()

        compose.onNodeWithText("field 101").assertIsDisplayed()
        compose.onNodeWithText("field 126").assertDoesNotExist()
    }

    /**
     * *** THE SECOND SCROLL: A SELF-INFLICTED RESTART, MEASURED. ***
     *
     * THE HYPOTHESIS, FROM REVIEW, AND IT IS A FEEDBACK LOOP RATHER THAN AN "UNRELATED RECOMPOSITION":
     * `val ids = state.passages.map { it.chunkId }` BUILDETH A NEW `List` ON EVERY RECOMPOSITION, and
     * `LaunchedEffect` KEYS COMPARE LISTS BY REFERENCE -- SO EQUAL CONTENTS STILL RE-FIRE. And the report effect
     * CALLETH `vm.noteScroll(...)`, WHICH WRITETH `_state` -> RECOMPOSES -> REBUILDS `ids` -> **THE EFFECT RESTARTS
     * ITSELF**: `previous = null` and `placementLanded = false` are reset, THE GATE RE-LOCKS, and the consume-effect
     * ALSO RE-FIRES `scrollToItem(target)` -- WHICH CAN JUMP THE READER BACK TO THE RESTORED TARGET AFTER THEY
     * SCROLLED AWAY.
     *
     * **SO THE VERY ACT OF RECORDING A SCROLL TEARS DOWN THE GATE THAT AUTHORISED IT.** A single-scroll arm cannot
     * see it: the first report lands before the restart interferes. THIS ARM DRIVES TWO SCROLLS, WHICH CAN.
     */
    @Test
    fun aSecondScrollIsAlsoRecorded() {
        val vm = placedReader(25L)

        compose.setContent { RealReadingList(vm) }
        compose.waitForIdle()

        compose.onNodeWithTag(READING_LIST_TAG).performScrollToIndex(20)
        awaitDisplayed("passage 21")
        val afterFirst = vm.state.value.anchorPassageId

        compose.onNodeWithTag(READING_LIST_TAG).performScrollToIndex(32)
        awaitDisplayed("passage 33")
        val afterSecond = vm.state.value.anchorPassageId

        assertEquals(
            "*** A SECOND SCROLL MUST ALSO BE RECORDED. IF IT IS NOT, THE REPORT EFFECT RESTARTED ITSELF: its own " +
                "`vm.noteScroll` write recomposed the composable, rebuilt `ids` as a NEW List, re-fired the effect " +
                "(keys compare Lists by reference), and RESET `placementLanded` -- RE-LOCKING THE GATE. The reader " +
                "would keep scrolling and the place would never be persisted again. " +
                "after first scroll: $afterFirst, after second: $afterSecond ***",
            33L, afterSecond,
        )
    }

    /**
     * *** AND THE READER IS NOT YANKED BACK TO THE RESTORED TARGET BY THEIR OWN REPORT. ***
     *
     * THE OTHER HALF OF THE SAME LOOP: if the consume-effect re-fires, it re-runneth `scrollToItem(target)` AND
     * `target` IS STILL THE RESTORED PLACEMENT -- so the reader is thrown BACK to where they were restored, undoing
     * the scroll they just made. THIS IS THE VISIBLE SYMPTOM: "init works but the post-interaction state breaks."
     */
    /**
     * *** THE DECISIVE ARM: TWO SCROLLS WITH AN UNRELATED STATE CHANGE BETWEEN THEM. ***
     *
     * THE HYPOTHESIS UNDER TEST, FROM REVIEW, AND IT IS A PREDICTION I CAN FALSIFY RATHER THAN ARGUE WITH:
     * *"drive an UNRELATED state change (a `loading`/`phase` copy) BETWEEN the two scrolls -- if the second scroll's
     * report then vanishes, the self-restart is confirmed."*
     *
     * `onQueryChanged` IS THE UNRELATED CHANGE: it writeth `query`, WHICH `ReadingList` NEVER READETH, so the list's
     * content, offsets and target are all untouched. THE ONLY THING IT CAN DISTURB IS AN EFFECT'S KEY.
     *
     * AND WHY THIS ARM IS STRONGER THAN THE PLAIN TWO-SCROLL ONE: the first report may land before any restart
     * interleaves, so the plain arm can pass while the post-re-render state is broken -- **it would be a FALSE
     * POSITIVE FOR THE VERY BUG IT LOOKS LIKE IT COVERS.** Forcing the recomposition in the MIDDLE removeth the timing
     * from the question: either the gate surviveth it, or it does not.
     *
     * AND THE PREDICTION IS FALSE, WHICH IS WHY THE ASSERTION IS WHAT IT IS: `LaunchedEffect` KEYS COMPARE WITH
     * STRUCTURAL EQUALITY (measured in isolation, round 568), so a content-equal rebuilt `ids` list does NOT restart
     * the effect and `placementLanded` surviveth. **IF THIS ARM EVER FAILS, THE PREMISE HAS BECOME TRUE AND THE
     * MEMOIZATION FIX BECOMES NECESSARY.**
     */
    @Test
    fun aScrollAfterAnUnrelatedStateChangeIsStillRecorded() {
        val vm = placedReader(25L)

        compose.setContent { RealReadingList(vm) }
        awaitDisplayed("passage 25")

        compose.onNodeWithTag(READING_LIST_TAG).performScrollToIndex(20)
        awaitDisplayed("passage 21")
        val afterFirst = vm.state.value.anchorPassageId

        // *** THE UNRELATED CHANGE: IT TOUCHES `query`, WHICH THE READING LIST NEVER READETH. ***
        vm.onQueryChanged("an unrelated edit")
        compose.waitForIdle()

        compose.onNodeWithTag(READING_LIST_TAG).performScrollToIndex(32)
        awaitDisplayed("passage 33")
        val afterSecond = vm.state.value.anchorPassageId

        assertEquals(
            "*** A SCROLL AFTER AN UNRELATED STATE CHANGE MUST STILL BE RECORDED. IF IT IS NOT, THE REPORT EFFECT " +
                "RESTARTED ON A RECOMPOSITION THAT CHANGED NOTHING IT CARES ABOUT: `previous` AND `placementLanded` " +
                "WERE RESET, THE GATE RE-LOCKED, AND THE READER'S PLACE STOPPED BEING PERSISTED FOR THE REST OF THE " +
                "SESSION. after first scroll: $afterFirst, after the unrelated change and second scroll: " +
                "$afterSecond ***",
            33L, afterSecond,
        )
    }

    @Test
    fun theReaderIsNotYankedBackToTheRestoredTargetByTheirOwnScroll() {
        val vm = placedReader(25L)

        compose.setContent { RealReadingList(vm) }
        compose.waitForIdle()

        compose.onNodeWithTag(READING_LIST_TAG).performScrollToIndex(32)   // the reader moves far away
        compose.waitForIdle()

        // THE READER MUST STILL BE WHERE THEY SCROLLED, not back at the restored placement.
        compose.onNodeWithText("passage 33").assertIsDisplayed()
        assertEquals(
            "*** AND THE RECORDED PLACE MUST BE THE READER'S, NOT THE RESTORED ONE -- the consume-effect re-firing " +
                "would have dragged them back to the target. Observed anchor: ${vm.state.value.anchorPassageId} ***",
            33L, vm.state.value.anchorPassageId,
        )
    }

    /**
     * *** THE `key(...)`: UNEXERCISED -- AND THE "FLAKINESS" THAT HID IT WAS A HARNESS DEFECT, NOW FIXED. ***
     *
     * FOUR ANSWERS I GAVE ABOUT ONE LINE, EACH EARLIER ONE WRONG IN A DIFFERENT WAY:
     *   1. "THE KEY GUARDS AN INHERITED OFFSET." Measured: green -- but the court read `state.value` ONCE and NEVER
     *      RECOMPOSED, **SO `key(...)` WAS NEVER EVALUATED AT ALL.** I measured a rig that could not answer.
     *   2. "THE TRANSITION IS UNREACHABLE." FALSE: `openPassage` swaps A for B with `mode` still DOCUMENT.
     *   3. "THE COURT IS FLAKY; THE KEY IS UNPROVEN EITHER WAY." The flakiness was REAL but it was **MINE, NOT THE
     *      CODE'S**: `waitForIdle` waiteth for the composition and the frame clock, while the placement arriveth from a
     *      `LaunchedEffect` COROUTINE -- so an assertion could run before or after `scrollToItem`. THE SAME MUTATION
     *      ON THE SAME CODE WENT RED, THEN GREEN, THEN GREEN. **A COURT THAT CANNOT BE TRUSTED UNDER MUTATION CANNOT
     *      CERTIFY ANYTHING -- INCLUDING ITS OWN PASSES.**
     *   4. THE ANSWER, WITH THE WAITS FIXED (`waitUntil` ON A UI CONDITION): **REMOVING THE KEY LEAVES ALL SEVEN ARMS
     *      GREEN, DETERMINISTICALLY -- 3/3 FULL-SUITE RUNS AND 3/3 WITH THE ARM ISOLATED.** The key is genuinely
     *      unexercised, and the reason is DOMINANCE rather than unreachability: a fresh open resolves the target to
     *      the new document's FIRST passage, so the consume-effect's `scrollToItem(0)` forceth the top regardless.
     *
     * AND AN ARM I WROTE TO SETTLE IT WAS DELETED: feeding `readingTargetPassageId = null` so the consume-effect could
     * not mask the inheritance -- IT PASSED WITH AND WITHOUT THE KEY, SO IT MEASURED ITS OWN RIG.
     *
     * **THE KEY IS KEPT** (correct, cheap, and it becomes load-bearing the moment target resolution can yield a
     * non-zero index), **RECORDED AS UNEXERCISED, AND NOT COUNTED AS COVERED.**
     */
    /**
     * *** AND AFTER THE PLACEMENT LANDS, THE READER'S OWN SCROLL **IS** RECORDED. ***
     *
     * *** THIS ARM WAS VACUOUS AND IS NOW A CONTROL. *** AS FIRST WRITTEN IT CALLED `vm.noteScroll(documentId = 7L,
     * passageId = 30L)` DIRECTLY AND THEN ASSERTED `anchorPassageId == 30` -- A TAUTOLOGY ON THE SETTER, which
     * EXERCISED NONE OF THE REPORT PATH (`snapshotFlow` -> `reportedAnchorPassageId` -> `vm.noteScroll`) INSIDE
     * `ReadingList`. **IF THE REPORT PATH WERE BROKEN SO IT NEVER FIRED -- the very "mechanism that never fires"
     * defect this file's own docstring nameth -- THAT ARM STILL PASSED, BECAUSE IT WROTE THE STATE ITSELF.**
     *
     * AND THE GAP IT HID IS THE MAIN JOURNEY: after a placement lands, `targetIndex` stayeth pinned (it deriveth
     * from `readingTargetPassageId`, which `noteScroll` never changeth), so a rule keyed on "targetIndex != null" alone
     * WOULD SUPPRESS EVERY LATER SCROLL AND FREEZE THE READING PLACE FOR THE WHOLE SESSION. `placementLanded` is what
     * openeth the gate permanently -- AND THIS ARM IS WHAT MEASURETH THAT IT REALLY OPENETH.
     *
     * THE GESTURE IS REAL: `performScrollToIndex` moves the production `LazyListState`, the production effect sees
     * it, and the production `vm.noteScroll` is what records it.
     */
    @Test
    fun aReadersOwnScrollAfterThePlacementIsReallyRecorded() {
        val vm = placedReader(25L)

        compose.setContent { RealReadingList(vm) }
        awaitDisplayed("passage 25")
        assertEquals("the rig must really have placed the reader first", 25L, vm.state.value.readingTargetPassageId)

        // THE READER MOVES -- A REAL GESTURE AGAINST THE PRODUCTION LIST.
        compose.onNodeWithTag(READING_LIST_TAG).performScrollToIndex(32)
        awaitDisplayed("passage 33")

        assertEquals(
            "*** THE READER'S OWN SCROLL AFTER A PLACEMENT MUST BE RECORDED. `targetIndex` stayeth pinned for the " +
                "whole session, so a gate that never reopeneth WOULD FREEZE THE READING PLACE AT THE RESTORED " +
                "POSITION -- the main journey, silently broken. Observed anchor: ${vm.state.value.anchorPassageId}, " +
                "observed visible index: ${compose.onNodeWithTag(READING_LIST_TAG).fetchSemanticsNode()} ***",
            33L, vm.state.value.anchorPassageId,
        )
    }
    /**
     * *** A DETERMINISTIC WAIT FOR A UI CONDITION -- BECAUSE `waitForIdle()` MEASURES THE WRONG THING HERE. ***
     *
     * THE COURT WAS NONDETERMINISTIC IN FULL-SUITE RUNS AND DETERMINISTIC ALONE, WHICH IS THE SIGNATURE OF TIMING
     * LUCK RATHER THAN A REAL DEPENDENCY: `waitForIdle` waiteth for the composition and the frame clock, but the
     * PLACEMENT arriveth from a `LaunchedEffect` that calleth `scrollToItem` and from a `snapshotFlow` collector --
     * COROUTINES WHOSE LANDING IS NOT "IDLE". So an assertion could run before or after the scroll depending on
     * scheduling.
     *
     * `waitUntil { ... }` POLLS A CONDITION INSTEAD, which is the idiom for asynchronous UI state and removeth the
     * timing from the assertion.
     */
    private fun awaitDisplayed(text: String) {
        compose.waitUntil(timeoutMillis = 5_000) {
            compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty()
        }
    }

}
