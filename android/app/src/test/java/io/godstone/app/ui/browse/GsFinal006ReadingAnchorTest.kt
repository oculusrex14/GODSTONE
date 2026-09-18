package io.godstone.app.ui.browse

import io.godstone.core.archive.ArchiveDocument
import io.godstone.core.archive.ArchivePassage
import io.godstone.core.archive.ArchiveReader
import io.godstone.core.archive.ArchiveSourceMetadata
import io.godstone.core.archive.ArchiveState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * GS-FINAL-006 (the independent audit, 2026-09-18), **the Android half**: *"BrowseScreen has no list state or scroll
 * action consuming the stored anchor."*
 *
 * THE CARD'S REMEDY FOR THIS ISLE, VERBATIM: *"On Android remember a `LazyListState`, consume the resolved anchor only
 * after matching document data/layout exists, and observe visible item identity into saved state. **Clear obsolete
 * anchors on document changes.**"*
 *
 * THE `LazyListState` AND THE SCROLL ITSELF ARE COMPOSE'S, and this isle carrieth **NO `androidTest` TARGET** -- so the
 * rendering half cannot be executed here and is NOT claimed. WHAT *IS* EXECUTABLE IS THE STATE HALF, WHICH IS WHERE THE
 * DEFECT LIVED: the resolved target the screen consumes, and the clearing clause that was measured ABSENT (a grep for
 * `anchorPassageId = null` in the ViewModel returned nothing before this round).
 */
@OptIn(ExperimentalCoroutinesApi::class)
class GsFinal006ReadingAnchorTest {

    private val dispatcher = StandardTestDispatcher()

    private val docA = ArchiveDocument(7, "Archive guide", "reference", false, "src-001", "r7")
    private val docB = ArchiveDocument(8, "Field manual", "reference", false, "src-002", "r8")
    private val a1 = ArchivePassage(11, 7, "Archive guide", "reference", "Search", "First.")
    private val a2 = ArchivePassage(12, 7, "Archive guide", "reference", "Search", "Second.")
    private val b1 = ArchivePassage(21, 8, "Field manual", "reference", "Search", "Only one.")

    private inner class TwoDocReader : ArchiveReader {
        override fun status(): ArchiveState = ArchiveState.Ready(origin = "installed.bin", sha256 = "a".repeat(64))
        override fun listDocuments(domain: String?): List<ArchiveDocument> = listOf(docA, docB)
        override fun listDomains(): List<String> = emptyList()
        override fun passages(documentId: Long): List<ArchivePassage> =
            if (documentId == 7L) listOf(a1, a2) else listOf(b1)
        override fun search(query: String, limit: Int): List<ArchivePassage> = listOf(a1, a2)
        override fun sourceMetadata(documentId: Long): ArchiveSourceMetadata? = null
    }

    @Before fun setUp() { Dispatchers.setMain(dispatcher) }
    @After fun tearDown() { Dispatchers.resetMain() }

    private fun viewModel() = BrowseViewModel(TwoDocReader(), dispatcher, null)

    /**
     * *** THE CLAUSE THAT WAS MEASURED ABSENT: AN OBSOLETE ANCHOR IS CLEARED ON A DOCUMENT CHANGE. ***
     *
     * A place recorded while reading document A must not survive into document B -- because `snapshotTo` would write
     * it into the saved handle, and a LATER return to B would honour an anchor the reader never set while reading B.
     * **A PLACE THAT BELONGS TO A DOCUMENT YOU ARE NOT IN IS NOT A PLACE.**
     */
    @Test
    fun anAnchorFromAnotherDocumentIsClearedWhenTheDocumentChanges() = runTest(dispatcher) {
        val vm = viewModel()

        vm.open(docA)
        advanceUntilIdle()
        vm.noteScroll(documentId = 7L, passageId = 12L)
        assertEquals("the rig must record a place in A first", 12L, vm.state.value.anchorPassageId)

        vm.open(docB)
        advanceUntilIdle()

        assertNull(
            "*** GS-FINAL-006: 'Clear obsolete anchors on document changes.' A passage id belonging to document A must " +
                "not be carried while B is open -- it would be PERSISTED and honoured on a later return to A. " +
                "Observed anchor: ${vm.state.value.anchorPassageId} ***",
            vm.state.value.anchorPassageId,
        )
    }

    /**
     * *** AND THE SAME DOCUMENT KEEPETH ITS PLACE -- THE CLEARING MUST NOT PUNISH A ROTATION. ***
     *
     * The clause says "on document CHANGES", so re-opening the document already open must NOT clear the anchor: a
     * recreation that re-opens the same document would otherwise lose the reader's place, which is the very thing the
     * anchor existeth for.
     */
    @Test
    fun reopeningTheSameDocumentKeepsItsAnchor() = runTest(dispatcher) {
        val vm = viewModel()

        vm.open(docA)
        advanceUntilIdle()
        vm.noteScroll(documentId = 7L, passageId = 12L)

        vm.open(docA)                       // THE SAME document -- not a change
        advanceUntilIdle()

        assertEquals(
            "re-opening the SAME document must keep the place -- otherwise a rotation would lose it",
            12L, vm.state.value.anchorPassageId,
        )
    }

    /**
     * *** AND THE TARGET THE SCREEN CONSUMES IS RESOLVED WHERE THE PASSAGES ARE KNOWN. ***
     *
     * This is the ViewModel half the screen now uses: `readingTargetPassageId` must be the anchor while it STANDS in
     * this document, and must FALL BACK otherwise -- so the screen can never be asked to scroll to a passage that is
     * not on screen.
     */
    @Test
    fun theResolvedTargetHonoursTheAnchorWhileItStandsAndFallsBackOtherwise() = runTest(dispatcher) {
        val vm = viewModel()

        vm.open(docA)
        advanceUntilIdle()
        vm.noteScroll(documentId = 7L, passageId = 12L)
        vm.open(docA)
        advanceUntilIdle()
        assertEquals(
            "an anchor that STANDS in the open document must be the target the screen scrolls to",
            12L, vm.state.value.readingTargetPassageId,
        )

        // AND A PASSAGE THAT DOES NOT STAND IN THIS DOCUMENT RESOLVES TO THE FIRST, so `scrollToItem` is asked for an
        // index that is really there.
        vm.noteScroll(documentId = 7L, passageId = 21L)   // B's passage, while A is open
        vm.open(docA)
        advanceUntilIdle()
        assertEquals(
            "a passage that is NOT in the open document must fall back to the first, never to a missing index",
            11L, vm.state.value.readingTargetPassageId,
        )
    }

    /**
     * *** THE OWNERSHIP HOLE, FOUND BY REVIEW: THE ANCHOR KNOWS ITS DOCUMENT AND NOTHING CARRIES THAT FACT. ***
     *
     * `noteScroll(documentId:passageId:)` RECEIVETH the owning document id AND DISCARDS IT. So the guard I wrote --
     * "clear when a DIFFERENT document is already open" -- is a test of ADJACENCY, NOT OF OWNERSHIP, and the list
     * detour walketh straight through it:
     *
     *     open(A) -> noteScroll(A, anchor) -> backToDocuments() -> open(B)
     *
     * `backToDocuments()` nulls `openedDocumentId` WITHOUT clearing `anchorPassageId`, so the guard reacheth B with
     * `alreadyOpen == null` and KEEPS A's anchor. And `ArchiveReadingAnchor.target` only testeth MEMBERSHIP in B's
     * current passage list -- so a COLLIDING chunkId places the reader in B at a passage they never set, AND
     * `snapshotTo` then persists it as B's.
     */
    @Test
    fun anAnchorFromADocumentReachedViaTheListViewIsNotCarriedIntoAnother() = runTest(dispatcher) {
        val vm = viewModel()

        vm.open(docA)
        advanceUntilIdle()
        vm.noteScroll(documentId = 7L, passageId = 12L)     // the reader's place in A

        vm.backToDocuments()                                // THE LIST DETOUR -- openedDocumentId becometh null
        advanceUntilIdle()
        vm.open(docB)                                       // and now B is opened
        advanceUntilIdle()

        assertNull(
            "*** GS-FINAL-006: AN ANCHOR BELONGING TO A MUST NOT SURVIVE THE LIST DETOUR INTO B. The guard " +
                "('a different document is already open') tests ADJACENCY, NOT OWNERSHIP, and `backToDocuments()` " +
                "leaves the anchor standing with NO document open -- so it reacheth B and, if B happeneth to carry a " +
                "colliding chunkId, PLACES THE READER AT A PASSAGE THEY NEVER SET and PERSISTS IT AS B'S. " +
                "Observed anchor: ${vm.state.value.anchorPassageId} ***",
            vm.state.value.anchorPassageId,
        )
    }

    /**
     * *** AND A RESTORED ANCHOR SURVIVES A ROUND TRIP -- BECAUSE A RESTORED ANCHOR IS NOT AN OBSOLETE ONE. ***
     *
     * THE CARD WRITETH `handle["anchorDocument"]`, and `restoreFrom` NEVER READ IT. So a handle restored for document
     * A carried an anchor whose owner was unrecorded, and any guard expressed in terms of the OPEN document could not
     * see that the anchor and the document agreed. **THE ANCHOR ALREADY KNOWS ITS DOCUMENT; THE STATE MUST CARRY IT.**
     */
    @Test
    fun aRestoredAnchorForItsOwnDocumentIsHonoured() = runTest(dispatcher) {
        val vm = viewModel()

        vm.open(docA)
        advanceUntilIdle()
        vm.noteScroll(documentId = 7L, passageId = 12L)

        var handle = mutableMapOf<String, Any?>()
        vm.snapshotTo(handle)
        assertEquals("the handle must carry the anchor's OWNER, not merely the open document",
                     7L, handle["anchorDocument"])

        val restored = viewModel()
        restored.restoreFrom(handle)
        advanceUntilIdle()

        assertEquals(
            "*** GS-FINAL-006: A RESTORED ANCHOR WHOSE OWNER MATCHES THE DOCUMENT MUST SURVIVE. Clearing it here " +
                "would mean PROCESS RECREATION PERMANENTLY LOSES THE READER'S PLACE -- the very thing the anchor " +
                "existeth for. Observed: ${restored.state.value.anchorPassageId} ***",
            12L, restored.state.value.anchorPassageId,
        )
        assertEquals("and it must be the target the screen scrolls to",
                     12L, restored.state.value.readingTargetPassageId)
    }

    /**
     * *** THE REPORT GATE: A REPORT IS ONLY THE READER'S OWN MOVEMENT. ***
     *
     * THE COMPOSE HALF IS NOT EXECUTABLE HERE (no `androidTest` target), SO THE DECISION WAS HOISTED INTO A PURE
     * FUNCTION AND IS COURTED HERE INSTEAD. THE DEFECT IT PREVENTETH: `snapshotFlow { firstVisibleItemIndex }`
     * EMITS THE CURRENT INDEX (0 on a fresh composition) BEFORE THE SIBLING `scrollToItem` LANDS, SO AN UNGATED
     * REPORT WOULD OVERWRITE THE JUST-RESTORED ANCHOR WITH THE FIRST PASSAGE -- the reader returns, is placed
     * correctly, and the act of returning destroys the place.
     */
    @Test
    fun aReportDuringTheAppsOwnScrollIsNotTheReadersMovement() {
        val ids = listOf(11L, 12L, 13L)

        assertNull(
            "*** WHILE A PLACEMENT IS OUTSTANDING, THE VISIBLE INDEX IS THE APP'S DOING, NOT THE READER'S: " +
                "reporting it would CLOBBER THE JUST-RESTORED ANCHOR with ids[0]. ***",
            reportedAnchorPassageId(previousVisibleIndex = 0, visibleIndex = 0, targetIndex = 2, placementLanded = false, ids = ids),
        )
        assertEquals(
            "and once the placement HAS landed, the visible passage is the reader's place",
            13L, reportedAnchorPassageId(previousVisibleIndex = 0, visibleIndex = 2, targetIndex = 2, placementLanded = true, ids = ids),
        )
    }

    @Test
    fun aReportWithNoPlacementOutstandingIsTheReadersOwnMovement() {
        val ids = listOf(11L, 12L, 13L)
        assertEquals("an ordinary scroll is reported", 12L,
                     reportedAnchorPassageId(previousVisibleIndex = 0, visibleIndex = 1, targetIndex = null, placementLanded = false, ids = ids))
        assertNull("an index past the list reports nothing rather than crashing or inventing an id",
                   reportedAnchorPassageId(previousVisibleIndex = 0, visibleIndex = 9, targetIndex = null, placementLanded = false, ids = ids))
        assertNull(
            "*** AND THE INITIAL EMISSION IS NEVER THE READER'S MOVEMENT: `snapshotFlow` emits the CURRENT value on " +
                "collection, so recording it would persist AN ANCHOR THE READER NEVER SET. Caught by the real UI court. ***",
            reportedAnchorPassageId(previousVisibleIndex = null, visibleIndex = 0, targetIndex = null, placementLanded = false, ids = ids),
        )
    }

    /** AND THE DOCUMENT LIST IS NOT GIVEN A READING TARGET: the anchor belongeth to a document, not to the list. */
    @Test
    fun theDocumentListCarriesNoReadingTarget() = runTest(dispatcher) {
        val vm = viewModel()
        vm.backToDocuments()                // the documents road, through the public action
        advanceUntilIdle()

        assertNull(
            "a documents-mode state must carry no reading target -- there is no document to place the reader in",
            vm.state.value.readingTargetPassageId,
        )
        assertNotNull("and the rig must really be in documents mode", vm.state.value.documents)
    }
}
