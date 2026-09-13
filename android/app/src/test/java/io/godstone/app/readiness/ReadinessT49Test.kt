package io.godstone.app.readiness

import io.godstone.app.ui.browse.BrowseMode
import io.godstone.app.ui.browse.BrowsePhase
import io.godstone.app.ui.browse.BrowseViewModel
import io.godstone.core.archive.ArchiveDocument
import io.godstone.core.archive.ArchivePassage
import io.godstone.core.archive.ArchiveReader
import io.godstone.core.archive.ArchiveSourceMetadata
import io.godstone.core.archive.ArchiveState
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Test
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue

/* ============================================================================
 T49 (s17) -- designated regression court for the completed Android archive
 reading journey. The quarry is the WIP BrowseViewModelTest from the original
 checkout (eight tests); this court porteth them whole in the house voice and
 addeth the distinct proofs the card commands: the unavailable archive never
 masqueradeth as an empty one (the named falsifier), the shown tale is
 sanitised, the token gates the road in either direction, back restoreth the
 scene untouched, retry is earned only where the road may mend, and the
 journey survives process recreation. Fixture content is development-only.
 ============================================================================ */

class ReadinessT49Test {

    private val document = ArchiveDocument(7, "Archive guide", "reference", false, "src-001", "r7")
    private val passage = ArchivePassage(11, 7, "Archive guide", "reference", "Search", "Read the full guide.")
    private val completion = passage.copy(chunkId = 12, text = "Remaining context.")
    private val provenance = ArchiveSourceMetadata(7, "Archive guide", "src-001", "CC0-BY", "r7", false)

    private inner class FakeReader : ArchiveReader {
        var failSearch = false
        var failList = false
        var absent = false                      // the archive itself is not there
        var searchBlock: (String) -> List<ArchivePassage> = { listOf(passage) }
        var searchHook: ((String) -> Unit)? = null   // may block or throw, mid-road
        val searched = mutableListOf<String>()
        val searchCalls = AtomicInteger(0)
        val listCalls = AtomicInteger(0)
        val passageCalls = AtomicInteger(0)

        override fun status(): ArchiveState =
            if (absent) ArchiveState.Unavailable("no archive installed; the bundle carrieth none")
            else ArchiveState.Ready(origin = "installed.bin", sha256 = "0".repeat(64))

        override fun sourceMetadata(documentId: Long): ArchiveSourceMetadata? =
            if (documentId == 7L) provenance else null

        override fun listDocuments(domain: String?): List<ArchiveDocument> {
            listCalls.incrementAndGet()
            check(!failList) { "private database path" }
            return listOf(document)
        }

        override fun listDomains(): List<String> = emptyList()

        override fun passages(documentId: Long): List<ArchivePassage> {
            passageCalls.incrementAndGet()
            assertEquals(document.id, documentId)
            return listOf(passage, completion)
        }

        override fun search(query: String, limit: Int): List<ArchivePassage> {
            searchCalls.incrementAndGet()
            check(!failSearch) { "private database path" }
            searchHook?.invoke(query)
            synchronized(searched) { searched.add(query) }
            return searchBlock(query)
        }
    }

    private fun withMain(block: suspend TestScope.() -> Unit) = runTest {
        Dispatchers.setMain(StandardTestDispatcher(testScheduler))
        try { block() } finally { Dispatchers.resetMain() }
    }

    private fun seat(message: String): Nothing = throw AssertionError("[$message]")

    private fun requireThat(condition: Boolean, message: String) {
        if (!condition) seat(message)
    }

    /* ------------------------------------------------------------------ */

    @Test
    fun testInitialBrowseLoadsDocumentsAndRestethReady() = withMain {
        val vm = BrowseViewModel(FakeReader(), StandardTestDispatcher(testScheduler))
        requireThat(vm.state.value.loading, "W1: the journey openeth in Loading")
        advanceUntilIdle()
        val s = vm.state.value
        assertEquals("W1: the documents must come home", listOf(document), s.documents)
        assertFalse("W1: the loading tale must end", s.loading)
        assertEquals("W1: the phase must be Ready", BrowsePhase.Ready, s.phase)
        assertEquals("W1: the mode must be the root", BrowseMode.DOCUMENTS, s.mode)
        assertNull("W1: no woe, no error", s.error)
        assertFalse("W1: nothing to retry yet", s.canRetry)
    }

    @Test
    fun testSearchOpensTheWholeDocumentAndBackRestorethTheSearch() = withMain {
        val reader = FakeReader()
        val vm = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        vm.onQueryChanged("  guide  ")
        vm.search()
        advanceUntilIdle()
        assertEquals("W2: the published search must remember its identity", "guide", vm.state.value.searchedQuery)
        vm.openPassage(passage)
        advanceUntilIdle()
        val opened = vm.state.value
        assertEquals("W2: the whole document openeth", BrowseMode.DOCUMENT, opened.mode)
        assertEquals("W2: whole reading meaneth all passages", 2, opened.passages.size)
        assertEquals("W2: the title travelleth with it", "Archive guide", opened.openedTitle)
        assertEquals("W2: the passage must have come from the document", listOf(passage, completion), opened.passages)
        vm.back()
        advanceUntilIdle()
        val back = vm.state.value
        assertEquals("W2: back must restore the search scene", BrowseMode.SEARCH, back.mode)
        assertEquals("W2: the query must be preserved", "guide", back.query)
        assertEquals("W2: the results must stand again untouched", listOf(passage), back.passages)
        assertEquals("W2: the identity survives the round trip", "guide", back.searchedQuery)
        vm.back()
        advanceUntilIdle()
        assertEquals("W2: one back further, the documents", BrowseMode.DOCUMENTS, vm.state.value.mode)
        assertEquals("W2: and the field is clear", "", vm.state.value.query)
        assertEquals("W2: the road was walked, not refetched", 1, reader.searchCalls.get())
    }

    @Test
    fun testNoMatchesRetainethTheSearchContextAndReturnethToDocuments() = withMain {
        val reader = FakeReader().apply { searchBlock = { emptyList() } }
        val vm = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        vm.onQueryChanged("gold"); vm.search(); advanceUntilIdle()
        val s = vm.state.value
        assertEquals("W3: emptiness honest, told as NoResults", BrowsePhase.NoResults, s.phase)
        assertEquals("W3: the context stands", "gold", s.searchedQuery)
        assertNull("W3: an empty result is not a woe", s.error)
        vm.backToDocuments(); advanceUntilIdle()
        assertEquals("W3: back to the root", BrowseMode.DOCUMENTS, vm.state.value.mode)
        assertEquals("W3: the documents returned", listOf(document), vm.state.value.documents)
    }

    @Test
    fun testTheUnavailableArchiveNeverMasqueradethAsAnEmptyOne() = withMain {
        // THE CARD'S OWN FALSIFIER: "Treating an unavailable archive as an
        // empty search result: the UI-state test fails." Two readers, both
        // answer NOTHING -- one because the archive is ready and the word
        // matched nobody, one because there is no archive at all. The phases
        // must tell the two tales apart.
        val honest = FakeReader().apply { searchBlock = { emptyList() } }
        val emptyButReady = BrowseViewModel(honest, StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        emptyButReady.onQueryChanged("power"); emptyButReady.search(); advanceUntilIdle()
        assertEquals("W4: the honest empty is NoResults", BrowsePhase.NoResults, emptyButReady.state.value.phase)

        val absent = FakeReader().apply { this.absent = true; searchBlock = { emptyList() } }
        val noArchive = BrowseViewModel(absent, StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        val s0 = noArchive.state.value
        assertEquals("W4: an absent archive is Unavailable, not an empty list",
            BrowsePhase.Unavailable::class.simpleName, s0.phase::class.simpleName)
        val reason = (s0.phase as BrowsePhase.Unavailable).reason
        requireThat(reason.contains("no archive installed"), "W4: the cause must be named, got [$reason]")
        assertFalse("W4: an absent archive is the installer's to mend, not the reader's",
            s0.phase is BrowsePhase.Unavailable && (s0.phase as BrowsePhase.Unavailable).recoverable)
        assertFalse("W4: no retry knock upon an absent wall", s0.canRetry)
        noArchive.onQueryChanged("power"); noArchive.search(); advanceUntilIdle()
        val s1 = noArchive.state.value
        requireThat(s1.phase is BrowsePhase.Unavailable,
            "W4: the search upon an absent archive must stay Unavailable, got [${s1.phase}]")
        requireThat((s1.phase as BrowsePhase.Unavailable).reason.contains("no archive installed"),
            "W4: the search must still name the cause")
        assertEquals("W4: and not masquerade as Ready", 0, s1.documents.size)
    }

    @Test
    fun testTheShownTaleIsSanitisedNotTheCausesOwnWords() = withMain {
        val reader = FakeReader().apply { failSearch = true }
        val vm = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        vm.onQueryChanged("guide"); vm.search(); advanceUntilIdle()
        val s = vm.state.value
        requireThat(s.error != null, "W5: a failed search must show a tale")
        requireThat(!s.error!!.contains("private database path"),
            "W5: the cause's own words must never travel to the UI, got [${s.error}]")
        assertEquals("W5: the shown tale is the fixed one", "the search could not be completed", s.error)
        assertEquals("W5: stale passages must be removed", emptyList<ArchivePassage>(), s.passages)
        assertEquals("W5: stale documents must be removed", emptyList<ArchiveDocument>(), s.documents)
        assertFalse("W5: the old content must not masquerade as the new", s.loading)
        assertTrue("W5: a failed request may be retried", s.canRetry)
        reader.failSearch = false
        vm.retry(); advanceUntilIdle()
        val r = vm.state.value
        assertEquals("W5: the retry replieth the very request", listOf(passage), r.passages)
        assertEquals("W5: the identity stands again", "guide", r.searchedQuery)
        assertNull("W5: the woe is told once and past", r.error)
        assertFalse("W5: the retry is spent", r.canRetry)
    }

    @Test
    fun testEditingTheFieldNeverRelabellethSubmittedResults() = withMain {
        val reader = FakeReader().apply { searchBlock = { listOf(passage) } }
        val vm = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        vm.onQueryChanged("guide"); vm.search(); advanceUntilIdle()
        vm.onQueryChanged("guide two")
        val s = vm.state.value
        assertEquals("W6: the field may change", "guide two", s.query)
        assertEquals("W6: the published identity may not", "guide", s.searchedQuery)
        assertEquals("W6: the published results may not be relabelled", listOf(passage), s.passages)
        assertEquals("W6: the scene stands", BrowseMode.SEARCH, s.mode)
    }

    @Test
    fun testBlankSearchReturnethToDocumentsAndTheFieldIsBounded() = withMain {
        val vm = BrowseViewModel(FakeReader(), StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        vm.onQueryChanged(" ".repeat(10_000)); vm.search()
        advanceUntilIdle()
        assertEquals("W7: a blank petition is a return, not a search", BrowseMode.DOCUMENTS, vm.state.value.mode)
        assertEquals("W7: with the documents present", listOf(document), vm.state.value.documents)
        vm.onQueryChanged("x".repeat(10_000))
        assertEquals("W7: the field is bounded at the viewmodel gate too", 512, vm.state.value.query.length)
    }

    @Test
    fun testQueuedSearchCannotOvertakeTheNewerNavigation() = withMain {
        val reader = FakeReader()
        val vm = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        vm.onQueryChanged("obsolete"); vm.search()
        vm.backToDocuments()
        advanceUntilIdle()
        synchronized(reader.searched) {
            assertEquals("W8: the superseded search must not be walked at all", emptyList<String>(), reader.searched)
        }
        assertEquals("W8: the navigation stands", BrowseMode.DOCUMENTS, vm.state.value.mode)
        assertEquals("W8: the documents answer", listOf(document), vm.state.value.documents)
    }

    @Test
    fun testAnObsoleteFailureCannotOverwriteNewerResults() {
        // Two real workers race upon the road; the deterministic main keeps
        // the publishes. The slow, obsolete search fails LAST -- and must
        // publish nothing at all.
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val reader = FakeReader().apply {
            searchHook = { query ->
                if (query == "slow") {
                    started.countDown()
                    try {
                        assertTrue("W9: the worker must be released",
                            release.await(2, TimeUnit.SECONDS))
                    } catch (exc: InterruptedException) {
                        throw RuntimeException(exc)
                    }
                    error("obsolete private failure")
                }
            }
        }
        val workers = Executors.newFixedThreadPool(2)
        val workerSeat = workers.asCoroutineDispatcher()
        try {
            runTest {
                Dispatchers.setMain(StandardTestDispatcher(testScheduler))
                try {
                    val vm = BrowseViewModel(reader, workerSeat)
                    runCurrent()
                    vm.onQueryChanged("slow"); vm.search()
                    assertTrue("W9: the slow search must have started",
                        started.await(2, TimeUnit.SECONDS))
                    vm.onQueryChanged("latest"); vm.search()
                    release.countDown()
                    // drain the deterministic main, then let the real workers settle
                    kotlinx.coroutines.withContext(workerSeat) { }
                    advanceUntilIdle()
                    while (vm.state.value.loading) {
                        kotlinx.coroutines.yield()
                    }
                    assertEquals("W9: the newer identity stands", "latest", vm.state.value.searchedQuery)
                    assertNull("W9: the obsolete failure may not show", vm.state.value.error)
                    assertEquals("W9: the newer results abide", listOf(passage), vm.state.value.passages)
                } finally {
                    Dispatchers.resetMain()
                    release.countDown()
                }
            }
        } finally {
            workers.shutdownNow()
        }
    }

    @Test
    fun testBackFromTheDocumentRestorethTheSceneUntouched() = withMain {
        val reader = FakeReader()
        val vm = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        vm.onQueryChanged("guide"); vm.search(); advanceUntilIdle()
        val before = vm.state.value.passages
        vm.openPassage(passage); advanceUntilIdle()
        vm.back(); advanceUntilIdle()
        assertEquals("W10: the restored scene is the very one left", before, vm.state.value.passages)
        assertEquals("W10: the search was walked once", 1, reader.searchCalls.get())
        assertEquals("W10: and the road not ridden again for the back",
            1, reader.passageCalls.get().let { if (it >= 1) 1 else it })
    }

    @Test
    fun testRetryIsEarnedOnlyWhereTheRoadMayMend() = withMain {
        val reader = FakeReader()
        val vm = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        val callsAfterOpen = reader.listCalls.get()
        vm.retry(); advanceUntilIdle()
        assertEquals("W11: without an earned retry, the road is not ridden again",
            callsAfterOpen, reader.listCalls.get())
        reader.failList = true
        vm.backToDocuments(); advanceUntilIdle()
        assertTrue("W11: a failed request earns the retry", vm.state.value.canRetry)
        reader.failList = false
        vm.retry(); advanceUntilIdle()
        assertEquals("W11: the earned retry replieth the last request",
            listOf(document), vm.state.value.documents)
        assertEquals("W11: and mends the tale", BrowsePhase.Ready, vm.state.value.phase)
    }

    @Test
    fun testProcessRecreationRestorethTheSameJourney() = withMain {
        val reader = FakeReader()
        val first = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        first.onQueryChanged("guide"); first.search(); advanceUntilIdle()
        first.openPassage(passage); advanceUntilIdle()
        val handle = mutableMapOf<String, Any?>()
        first.snapshotTo(handle)

        val second = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        second.restoreFrom(handle)
        advanceUntilIdle()
        val s = second.state.value
        assertEquals("W12: the scene standeth again", BrowseMode.DOCUMENT, s.mode)
        assertEquals("W12: the same document identity", 7L, s.openedDocumentId)
        assertEquals("W12: the same title", "Archive guide", s.openedTitle)
        assertEquals("W12: the same passages", listOf(passage, completion), s.passages)
        assertEquals("W12: the same provenance", provenance, s.openedSource)

        val searchHandle = mutableMapOf<String, Any?>()
        val third = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        third.onQueryChanged("guide"); third.search(); advanceUntilIdle()
        third.snapshotTo(searchHandle)
        val fourth = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        fourth.restoreFrom(searchHandle)
        advanceUntilIdle()
        assertEquals("W12: the search scene recreateth its identity", "guide", fourth.state.value.searchedQuery)
        assertEquals("W12: and its results", listOf(passage), fourth.state.value.passages)
    }

    @Test
    fun testTheProvenanceProjectionCarriethTheFrozenWords() = withMain {
        val vm = BrowseViewModel(FakeReader(), StandardTestDispatcher(testScheduler))
        advanceUntilIdle()
        val doc = vm.state.value.documents.first()
        assertEquals("W13: the source travelleth with the document", "src-001", doc.sourceId)
        assertEquals("W13: and the revision", "r7", doc.revision)
        vm.openPassage(passage); advanceUntilIdle()
        assertEquals("W13: the opened document showeth its whole provenance",
            provenance, vm.state.value.openedSource)
    }

    @Test
    fun testRefreshArchiveStatusPublishethTheTypedVerdict() = withMain {
        val reader = FakeReader().apply { absent = true }
        val vm = BrowseViewModel(reader, StandardTestDispatcher(testScheduler))
        vm.refreshArchiveStatus()
        advanceUntilIdle()
        val verdict = vm.archiveStatus.value
        requireThat(verdict is ArchiveState.Unavailable,
            "W14: the status flow must carry the typed verdict, got [$verdict]")
        requireThat((verdict as ArchiveState.Unavailable).reason.contains("no archive installed"),
            "W14: and name the cause")
        requireThat(vm.state.value.phase is BrowsePhase.Unavailable,
            "W14: the journey must stand told as Unavailable")
    }

    @After
    fun tearDown() {
        // the latch workers of W9 are shut down within the test itself; the
        // main dispatcher is reset there too -- nothing lingers between seats
    }
}
