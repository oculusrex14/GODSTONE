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
