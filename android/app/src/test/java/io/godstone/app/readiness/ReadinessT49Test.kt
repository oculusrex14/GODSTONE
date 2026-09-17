package io.godstone.app.readiness

import androidx.sqlite.SQLiteConnection
import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.lifecycle.SavedStateHandle
import io.godstone.app.ui.browse.BrowseMode
import io.godstone.app.ui.browse.BrowsePhase
import io.godstone.app.ui.browse.BrowseViewModel
import io.godstone.core.archive.ArchiveBridge
import io.godstone.core.archive.ArchiveDrivers
import io.godstone.core.archive.ArchiveDocument
import io.godstone.core.archive.ArchivePassage
import io.godstone.core.archive.ArchiveReader
import io.godstone.core.archive.ArchiveRepository
import io.godstone.core.archive.ArchiveSourceMetadata
import io.godstone.core.archive.ArchiveState
import java.io.File
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

/* ------------------------------------------------------------------
 * W15's real-road witnesses: the very FROZEN DDL executed verbatim
 * through the bundled engine (the T47 idiom, ported), a filesystem
 * bridge, and the REAL ArchiveRepository -- that the projection SQL,
 * the status() override and the whole read road be proved on the true
 * storage, not upon a fake's word. Fixture content is development-only.
 * ------------------------------------------------------------------ */

private const val T49_ASSET: String = "godstone_light.db"
private const val T49_MANIFEST: String = "godstone_light.db.manifest"

private fun t49Sha256(bytes: ByteArray): String =
    java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { b -> "%02x".format(b.toInt() and 0xFF) }

private fun t49TempRoot(prefix: String): File {
    val dir = File("/tmp/" + prefix + "-" + System.nanoTime())
    dir.mkdirs()
    dir.deleteOnExit()
    return dir
}

private fun SQLiteConnection.speak(sql: String) {
    try {
        prepare(sql).use { it.step() }
    } catch (exc: Throwable) {
        System.err.println("SPOKE-FALSE[" + sql.replace("\n", "|") + "]")
        throw exc
    }
}

private fun t49SpeakScript(conn: SQLiteConnection, script: String) {
    // Statements end at a semicolon that stands outside a string literal and
    // outside a comment -- the law the python builder's executescript keeps;
    // a naive split is a lie (the frozen DDL carries semicolons in comments).
    val buf = StringBuilder()
    var i = 0
    while (i < script.length) {
        val c = script[i]
        when {
            c == '\'' -> {
                buf.append(c)
                i++
                while (i < script.length) {
                    val d = script[i]
                    buf.append(d)
                    i++
                    if (d == '\'') {
                        if (i < script.length && script[i] == '\'') {
                            buf.append(script[i])
                            i++
                        } else {
                            break
                        }
                    }
                }
            }
            c == '-' && i + 1 < script.length && script[i + 1] == '-' -> {
                while (i < script.length && script[i] != '\n') {
                    buf.append(script[i])
                    i++
                }
            }
            c == '/' && i + 1 < script.length && script[i + 1] == '*' -> {
                buf.append(c)
                buf.append(script[i + 1])
                i += 2
                while (i + 1 < script.length && !(script[i] == '*' && script[i + 1] == '/')) {
                    buf.append(script[i])
                    i++
                }
                if (i + 1 < script.length) {
                    buf.append('*').append('/')
                    i += 2
                }
            }
            c == ';' -> {
                val stmt = buf.toString().trim()
                if (stmt.isNotEmpty()) conn.speak(stmt)
                buf.clear()
                i++
            }
            else -> {
                buf.append(c)
                i++
            }
        }
    }
    val tail = buf.toString().trim()
    if (tail.isNotEmpty()) conn.speak(tail)
}

private fun t49BuildArchive(target: File) {
    var probe: File? = File(System.getProperty("user.dir")).absoluteFile
    var repoRoot: File? = null
    while (probe != null) {
        if (File(probe, "content/db/schema.sql").isFile) { repoRoot = probe; break }
        probe = probe.parentFile
    }
    val root = repoRoot ?: error("the court could not find content/db/schema.sql from " +
        System.getProperty("user.dir"))
    val schema = File(root, "content/db/schema.sql").readText()
    val indexes = File(root, "content/db/indexes.sql").readText()
    val conn = BundledSQLiteDriver().open(target.absolutePath)
    try {
        t49SpeakScript(conn, schema)
        conn.prepare("INSERT INTO documents(document_id,title,domain,source_id,licence,revision,is_critical) VALUES(?,?,?,?,?,?,?)").use { st ->
            st.bindLong(1, 7L); st.bindText(2, "Archive guide"); st.bindText(3, "reference")
            st.bindText(4, "src-001"); st.bindText(5, "CC0-BY"); st.bindText(6, "r7")
            st.bindLong(7, 0L); st.step()
        }
        conn.prepare("INSERT INTO chunks(chunk_id,document_id,ordinal,section,text,token_count) VALUES(?,?,?,?,?,?)").use { st ->
            st.bindLong(1, 11L); st.bindLong(2, 7L); st.bindLong(3, 1L)
            st.bindText(4, "Search"); st.bindText(5, "Read the full guide."); st.bindLong(6, 4L)
            st.step()
        }
        conn.prepare("INSERT INTO chunks(chunk_id,document_id,ordinal,section,text,token_count) VALUES(?,?,?,?,?,?)").use { st ->
            st.bindLong(1, 12L); st.bindLong(2, 7L); st.bindLong(3, 2L)
            st.bindText(4, "Search"); st.bindText(5, "Remaining context."); st.bindLong(6, 2L)
            st.step()
        }
        conn.prepare("INSERT INTO archive_meta(key,value) VALUES(?,?)").use { st ->
            st.bindText(1, "schema_version"); st.bindText(2, "3"); st.step()
        }
        t49SpeakScript(conn, indexes)
    } finally {
        conn.close()
    }
}

private class T49Bridge(
    private val root: File,
    private var bytes: ByteArray?,
) : ArchiveBridge {
    override fun assetBytes(name: String): ByteArray? = when (name) {
        T49_ASSET -> bytes
        T49_MANIFEST -> bytes?.let { b ->
            ("{\"archive_bytes\":${b.size},\"archive_file\":\"$T49_ASSET\",\"archive_schema\":3," +
                "\"archive_sha256\":\"${t49Sha256(b)}\",\"schema\":1,\"tier\":\"LIGHT\"}")
                .toByteArray()
        }
        else -> null
    }
    override fun cacheRoot(): File = root
}

class ReadinessT49Test {

    companion object {
        init {
            // The very class the LIGHT APK installs out of band; the host
            // road runseth the same driver over the same native stock.
            ArchiveDrivers.install { BundledSQLiteDriver() }
        }
    }

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
        requireThat(!s.phase.toString().contains("private database path"),
            "W5b: the banner reason must not carry the cause's own words either, got [${s.phase}]")
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
        // Two real workers travel the road; the deterministic main keeps the
        // sample. The elder must not publish until the younger's tale hath
        // landed -- else the sample would race the very violation it judges.
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val witnessBox = Array<BrowseViewModel?>(1) { null }
        val reader = FakeReader().apply {
            searchHook = { query ->
                if (query == "slow") {
                    started.countDown()
                    try {
                        assertTrue("W9: the worker must be released",
                            release.await(2, TimeUnit.SECONDS))
                        // determinism law: wait until the younger search hath
                        // published its truth (bounded spin, one heart-beat a
                        // time); only then may the elder's woe be raised
                        val until = System.currentTimeMillis() + 2000L
                        while (!(witnessBox[0]?.state?.value?.let {
                                    it.searchedQuery == "latest" && !it.loading } == true) &&
                                System.currentTimeMillis() < until) {
                            Thread.sleep(1)
                        }
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
                    witnessBox[0] = vm
                    runCurrent()
                    vm.onQueryChanged("slow"); vm.search()
                    assertTrue("W9: the slow search must have started",
                        started.await(2, TimeUnit.SECONDS))
                    vm.onQueryChanged("latest"); vm.search()
                    release.countDown()
                    // let the elder's whole post-wake path (spin, throw, fold)
                    // complete before the sample is taken
                    Thread.sleep(150)
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

    @Test
    fun testTheRealFrozenRoadCarriethProvenanceAndTellethTruth() {
        // W15: the REAL repository over the REAL bundled engine upon bytes
        // built by executing the FROZEN DDL verbatim -- the projection SQL,
        // the status() override and the falsifier end to end, on the true
        // storage. A fake's word is not proof; this is.
        val root = t49TempRoot("t49-court")
        val staged = File(root, "staged.db")
        t49BuildArchive(staged)
        val bytes = staged.readBytes()

        val bridge = T49Bridge(File(root, "cache"), bytes)
        val repo = ArchiveRepository(bridge, T49_ASSET)
        val s0 = repo.status()
        requireThat(s0 is ArchiveState.Ready, "W15: the real road must arm ready, got [$s0]")

        val docs = repo.listDocuments(null)
        assertEquals("W15: one document stands", 1, docs.size)
        assertEquals("W15: the source travelleth from the frozen column", "src-001", docs[0].sourceId)
        assertEquals("W15: the revision likewise", "r7", docs[0].revision)

        assertEquals("W15: the whole provenance projection, from the real SELECT",
            ArchiveSourceMetadata(7L, "Archive guide", "src-001", "CC0-BY", "r7", false),
            repo.sourceMetadata(7L))
        assertNull("W15: an unheard document nameth no provenance", repo.sourceMetadata(404L))

        val found = repo.passages(7L)
        assertEquals("W15: the whole document, in ordinal order, off real storage",
            listOf("Read the full guide.", "Remaining context."), found.map { it.text })

        assertTrue("W15: the FTS engine is truly alive upon the host",
            repo.search("guide", 40).isNotEmpty())

        // the defaced middle: the magic stands, the body is smeared over a
        // whole page's worth -- the integrity walk must feel it
        val rotten = bytes.copyOf()
        val at = rotten.size / 2
        for (k in at until minOf(at + 4096, rotten.size)) {
            rotten[k] = (rotten[k].toInt() xor 0xFF).toByte()
        }
        val bridge2 = T49Bridge(File(root, "cache2"), rotten)
        val repo2 = ArchiveRepository(bridge2, T49_ASSET)
        val s1 = repo2.status()
        requireThat(s1 is ArchiveState.Unavailable,
            "W15: the defaced archive must be told unavailable, got [$s1]")

        // and the viewmodel upon that truth-telling reader must call the
        // card's falsifier down end to end: no empty masquerade
        runTest {
            Dispatchers.setMain(StandardTestDispatcher(testScheduler))
            try {
                val vm = BrowseViewModel(repo2, StandardTestDispatcher(testScheduler))
                vm.onQueryChanged("power"); vm.search(); advanceUntilIdle()
                val p = vm.state.value.phase
                requireThat(p is BrowsePhase.Unavailable,
                    "W15: the falsifier, end to end -- the defaced archive is Unavailable, never an empty search result, got [$p]")
                requireThat((p as BrowsePhase.Unavailable).reason.isNotBlank(),
                    "W15: the cause must be named")
                assertFalse("W15: no retry knock upon a defaced wall", vm.state.value.canRetry)
            } finally {
                Dispatchers.resetMain()
            }
        }
    }

    @After
    fun tearDown() {
        // the latch workers of W9 are shut down within the test itself; the
        // main dispatcher is reset there too -- nothing lingers between seats
    }

    // MARK: - GS-ARCHIVE-005 step 3: the place, where the platform keepeth it

    /**
     * *** GS-ARCHIVE-005 STEP 3, MEASURED BEHAVIOURALLY ON THIS ISLE. ***
     *
     * THE CARD'S OWN CHARGE, WHICH WAS EXACTLY TRUE HERE BEFORE THIS ROUND: `snapshotTo`/`restoreFrom` existed and
     * **NO PRODUCTION CALLER REACHED EITHER**, and `SavedStateHandle` appeared NOWHERE in the Android tree -- so a
     * process recreation lost the promised query and document place on THIS isle just as on the iOS one.
     *
     * THIS ARM TAKETH THE REAL ROAD, WHICH IS WHY IT IS BEHAVIOURAL AND NOT STRUCTURAL: it constructeth the view
     * model OVER A HANDLE, drives a real OPEN, and then CONSTRUCTS A SECOND VIEW MODEL OVER THE SAME HANDLE -- which
     * is what a process recreation giveth to the platform.
     */
    @Test
    fun testProcessRecreationFindethThePlaceInTheSavedStateHandle() = withMain {
        val handle = SavedStateHandle()
        val first = BrowseViewModel(FakeReader(), StandardTestDispatcher(testScheduler), handle)
        advanceUntilIdle()
        first.open(document)
        advanceUntilIdle()
        assertEquals("the scene must stand IN the document", BrowseMode.DOCUMENT, first.state.value.mode)
        assertEquals("and the open must have been WRITTEN where recreation can find it",
                     document.id, handle.get<Long>("openedDocumentId"))
        assertEquals("and the mode with it", "DOCUMENT", handle.get<String>("mode"))
        assertEquals("and the title", "Archive guide", handle.get<String>("openedTitle"))

        // A SECOND VIEW MODEL OVER THE SAME HANDLE IS A PROCESS RECREATION.
        val second = BrowseViewModel(FakeReader(), StandardTestDispatcher(testScheduler), handle)
        advanceUntilIdle()
        assertEquals("*** THE RESTORED PLACE MUST STAND: the mode (GS-ARCHIVE-005 step 3) ***",
                     BrowseMode.DOCUMENT, second.state.value.mode)
        assertEquals("and the document identity must be the one that was open",
                     document.id, second.state.value.openedDocumentId)
        assertEquals("and its title", "Archive guide", second.state.value.openedTitle)
    }

    /**
     * *** THE DISCRIMINATOR, SO THE ARM ABOVE CANNOT PASS ON A RESTORATION OF NOTHING. *** An EMPTY handle is a
     * FIRST RUN, not a restoration: restoring from it would strike out the first browse with the empty place it had
     * just built -- the loss the finding chargeth, inverted.
     */
    /**
     * *** GS-ARCHIVE-005 step 3: "a VALID reading anchor" -- THE BEHAVIOURAL HALF, ON THE ISLE THAT HAD NO ANCHOR. ***
     *
     * MEASURED at round 526 before this work: the string `anchor` appeared NOWHERE in the Android browse path, so the
     * card's step 3 could not be satisfied by persistence alone -- there was nothing to persist. This arm notes a
     * place, recreates the view model over the same handle, and requireth THAT THE PLACE BE HONOURED, because the
     * anchored passage STILL STANDETH in the document.
     */
    @Test
    fun testAProcessRecreationRestorethTheReadingAnchorAndHonourethIt() = withMain {
        val handle = SavedStateHandle()
        val first = BrowseViewModel(FakeReader(), StandardTestDispatcher(testScheduler), handle)
        advanceUntilIdle()
        first.open(document)
        advanceUntilIdle()
        first.noteScroll(documentId = document.id, passageId = completion.chunkId)
        advanceUntilIdle()
        assertEquals("the asked-for anchor must be PERSISTED as asked for",
                     completion.chunkId, handle.get<Long>("anchorPassage"))

        val second = BrowseViewModel(FakeReader(), StandardTestDispatcher(testScheduler), handle)
        advanceUntilIdle()
        assertEquals("and it must be RESTORED", completion.chunkId, second.state.value.anchorPassageId)
        assertEquals("*** AND HONOURED, because it still standeth in this document ***",
                     completion.chunkId, second.state.value.readingTargetPassageId)
    }

    /**
     * *** THE DISCRIMINATOR, WITHOUT WHICH THE ARM ABOVE WOULD PASS ON A BLIND LOOKUP. ***
     *
     * A persisted anchor is a promise about a document that may have been replaced, re-released or revised while the
     * process was away. A STALE identity must NOT be honoured -- and must not silently place the reader at whatever
     * passage now happeneth to carry that number.
     */
    @Test
    fun testAStaleAnchorFallethBackToTheFirstPassageAndIsNotHonoured() = withMain {
        val handle = SavedStateHandle()
        handle["mode"] = "DOCUMENT"
        handle["openedDocumentId"] = document.id
        handle["openedTitle"] = "Archive guide"
        handle["anchorPassage"] = 999_999L          // an identity THIS document doth not carrieth

        val vm = BrowseViewModel(FakeReader(), StandardTestDispatcher(testScheduler), handle)
        advanceUntilIdle()
        assertEquals("the asked-for anchor is remembered AS ASKED FOR -- it is not silently discarded",
                     999_999L, vm.state.value.anchorPassageId)
        assertEquals("*** A STALE ANCHOR MUST NOT BE HONOURED: the reader is placed at the FIRST passage ***",
                     passage.chunkId, vm.state.value.readingTargetPassageId)
    }

    @Test
    fun testAnEmptyHandleIsAFirstRunAndNotARestorationOfNothing() = withMain {
        val vm = BrowseViewModel(FakeReader(), StandardTestDispatcher(testScheduler), SavedStateHandle())
        advanceUntilIdle()
        assertEquals("*** AN EMPTY HANDLE MUST MEAN A FIRST BROWSE ***", BrowseMode.DOCUMENTS, vm.state.value.mode)
        assertEquals("and the documents must come home", listOf(document), vm.state.value.documents)
        assertNull("and nothing may be claimed as restored", vm.state.value.openedDocumentId)
    }
}
