package io.godstone.app.ui.browse

import androidx.compose.ui.test.junit4.createComposeRule
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
        compose.waitForIdle()

        compose.onNodeWithText("passage 25").assertIsDisplayed()
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
        compose.waitForIdle()

        compose.onNodeWithText("passage 1").assertIsDisplayed()
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
     * **WHAT THIS ARM REALLY MEASURES IS THE BEHAVIOUR THE READER SEES** -- the new document really starteth at its
     * own beginning -- and THAT is causally connected to the scroll: under MUTATION M1 (the consume-effect removed)
     * THIS ARM REDDENS. It is a real control on a real journey; it is simply NOT a control on the key, and it no
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
        compose.waitForIdle()
        assertEquals("the rig must really have placed the reader first", 25L, vm.state.value.readingTargetPassageId)

        // THE READER MOVES -- A REAL GESTURE AGAINST THE PRODUCTION LIST.
        compose.onNodeWithTag(READING_LIST_TAG).performScrollToIndex(32)
        compose.waitForIdle()

        assertEquals(
            "*** THE READER'S OWN SCROLL AFTER A PLACEMENT MUST BE RECORDED. `targetIndex` stayeth pinned for the " +
                "whole session, so a gate that never reopeneth WOULD FREEZE THE READING PLACE AT THE RESTORED " +
                "POSITION -- the main journey, silently broken. Observed anchor: ${vm.state.value.anchorPassageId}, " +
                "observed visible index: ${compose.onNodeWithTag(READING_LIST_TAG).fetchSemanticsNode()} ***",
            33L, vm.state.value.anchorPassageId,
        )
    }
}
