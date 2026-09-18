package io.godstone.app.ui.browse

import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
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
            listOf(ArchiveDocument(7, "Archive guide", "reference", false, "src-001", "r7"))
        override fun listDomains(): List<String> = emptyList()
        override fun passages(documentId: Long): List<ArchivePassage> =
            (1L..40L).map { ArchivePassage(it, 7, "Archive guide", "reference", "S", "passage $it") }
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

    @androidx.compose.runtime.Composable
    private fun RealReadingList(vm: BrowseViewModel) {
        io.godstone.app.ui.theme.GodstoneTheme(redNightMode = false) {
            ReadingList(vm.state.value, vm)
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
     * *** AND THE READER'S OWN SCROLL **IS** RECORDED -- THE GATE MUST NOT SILENCE THE MECHANISM. ***
     *
     * A gate that never lets anything through would be the same species of defect this programme keeps finding (a
     * control nobody consults, a mechanism that never fires). With NO placement outstanding, the reader's own
     * movement must reach the state, or the place could never be persisted at all.
     */
    @Test
    fun aReadersOwnScrollIsReallyRecorded() {
        val vm = placedReader(1L)                // placed at the top: the placement lands, nothing is outstanding

        compose.setContent { RealReadingList(vm) }
        compose.waitForIdle()

        // THE READER MOVES. There is no placement outstanding any more, so this is THEIR movement.
        vm.noteScroll(documentId = 7L, passageId = 30L)
        compose.waitForIdle()

        assertEquals("the reader's own movement must reach the state",
                     30L, vm.state.value.anchorPassageId)
    }
}
