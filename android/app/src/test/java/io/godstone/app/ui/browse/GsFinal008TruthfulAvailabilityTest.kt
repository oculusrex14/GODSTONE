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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * GS-FINAL-008 (the independent audit, 2026-09-18): **AN AVAILABILITY EXCEPTION MUST NOT BECOME "READY".**
 *
 * THE AUDIT'S MEASUREMENT, VERBATIM: *"search and openDocumentInternal use
 * `getOrDefault(ArchiveState.Ready(origin=\"assumed\", sha256=\"\"))` when reader.status throws. refreshArchiveStatus
 * treats the same exception as Unavailable."* AND ITS ROOT CAUSE: *"An optimistic fallback collapses unknown/error into
 * success and disagrees with another path using the same status API."*
 *
 * THE TWO FACTS THIS ARM PINS, AND THEY ARE BOTH ABOUT HONESTY RATHER THAN BEHAVIOUR:
 *
 *   1. **A THROW FROM `status()` IS NOT "READY".** The same exception is `Unavailable` in one road and `Ready` in
 *      three others -- one API, two verdicts, and the lenient one is the one the user sees.
 *   2. **`origin = "assumed"` AND `sha256 = ""` ARE FABRICATED METADATA.** The audit's remediation: *"Do not
 *      manufacture a digest or origin."* A state that says "assumed" with an empty digest is not a claim anyone
 *      measured; it is the absence of a claim wearing the costume of one.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class GsFinal008TruthfulAvailabilityTest {

    private val dispatcher = StandardTestDispatcher()

    private val document = ArchiveDocument(7, "Archive guide", "reference", false, "src-001", "r7")
    private val passage = ArchivePassage(11, 7, "Archive guide", "reference", "Search", "Read the full guide.")

    /** A reader whose CONTENT reads succeed and whose STATUS probe THROWS. */
    private inner class ThrowingStatusReader : ArchiveReader {
        var statusCalls = 0
        override fun status(): ArchiveState {
            statusCalls += 1
            throw IllegalStateException("the status probe is unreadable")
        }
        override fun listDocuments(domain: String?): List<ArchiveDocument> = listOf(document)
        override fun listDomains(): List<String> = emptyList()
        override fun passages(documentId: Long): List<ArchivePassage> = listOf(passage)
        override fun search(query: String, limit: Int): List<ArchivePassage> = listOf(passage)
        override fun sourceMetadata(documentId: Long): ArchiveSourceMetadata? = null
    }

    @Before fun setUp() { Dispatchers.setMain(dispatcher) }
    @After fun tearDown() { Dispatchers.resetMain() }

    private fun viewModel(reader: ArchiveReader) = BrowseViewModel(reader, dispatcher, null)

    /**
     * *** THE HEADLINE: A STATUS THROW MUST NOT BECOME `Ready`. ***
     *
     * The content read SUCCEEDS, so a composition that only checked "did the read work" would call this healthy. The
     * status probe is the archive's own statement about its availability, and it could not be made -- which is
     * `Unavailable`, the same verdict `refreshArchiveStatus` already reacheth for the identical exception.
     */
    @Test
    fun aStatusThrowDuringSearchDoesNotBecomeReady() = runTest(dispatcher) {
        val reader = ThrowingStatusReader()
        val vm = viewModel(reader)

        vm.onQueryChanged("guide")
        vm.search()
        advanceUntilIdle()

        val phase = vm.state.value.phase
        assertFalse(
            "*** GS-FINAL-008: A STATUS THROW MUST NOT PRODUCE `Ready`. The same exception is `Unavailable` in " +
                "refreshArchiveStatus and `Ready` here -- ONE API, TWO VERDICTS, and the lenient one is what the " +
                "user sees. Observed phase: $phase ***",
            phase is BrowsePhase.Ready,
        )
        assertTrue(
            "and it must be the typed UNAVAILABLE phase, which carrieth its reason: $phase",
            phase is BrowsePhase.Unavailable,
        )
        assertTrue("the status probe really was consulted: ${reader.statusCalls}", reader.statusCalls > 0)
    }

    /**
     * *** AND NO FABRICATED METADATA MAY APPEAR ANYWHERE THE UI CAN READ IT. ***
     *
     * `origin = "assumed"` with `sha256 = ""` is the fallback's own signature. If any state published after a throwing
     * probe carrieth it, the composition has manufactured a digest -- the thing the audit forbade by name.
     */
    @Test
    fun noAssumedOriginOrEmptyDigestIsEverPublished() = runTest(dispatcher) {
        val reader = ThrowingStatusReader()
        val vm = viewModel(reader)

        vm.refreshArchiveStatus()
        vm.onQueryChanged("guide")
        vm.search()
        advanceUntilIdle()
        vm.open(document)
        advanceUntilIdle()

        val status = vm.archiveStatus.value
        if (status is ArchiveState.Ready) {
            assertFalse(
                "*** GS-FINAL-008: `origin = \"assumed\"` IS A MANUFACTURED ORIGIN. Observed: ${status.origin} ***",
                status.origin == "assumed",
            )
            assertFalse(
                "*** GS-FINAL-008: AN EMPTY sha256 IS A MANUFACTURED DIGEST. Observed: '${status.sha256}' ***",
                status.sha256.isEmpty(),
            )
        }
        // AND THE STATE NEVER CLAIMS READY AT ALL FOR THIS READER, whichever road published it.
        assertEquals(
            "a reader whose status probe throws must never leave a Ready verdict in the published status",
            false,
            status is ArchiveState.Ready,
        )
    }

    /**
     * *** AND THE POSITIVE CONTROL: A HEALTHY READER STILL REACHES `Ready` WITH REAL METADATA. ***
     *
     * The repair must refuse a *throwing* probe WITHOUT refusing an ordinary archive -- otherwise it is a denial of
     * service rather than a gate, and the UI would never show results again.
     */
    @Test
    fun aHealthyReaderStillReachesReadyWithItsOwnMetadata() = runTest(dispatcher) {
        val reader = object : ArchiveReader {
            override fun status(): ArchiveState = ArchiveState.Ready(origin = "installed.bin", sha256 = "a".repeat(64))
            override fun listDocuments(domain: String?): List<ArchiveDocument> = listOf(document)
            override fun listDomains(): List<String> = emptyList()
            override fun passages(documentId: Long): List<ArchivePassage> = listOf(passage)
            override fun search(query: String, limit: Int): List<ArchivePassage> = listOf(passage)
            override fun sourceMetadata(documentId: Long): ArchiveSourceMetadata? = null
        }
        val vm = viewModel(reader)

        vm.refreshArchiveStatus()          // the status road: it is null until this runs
        vm.onQueryChanged("guide")
        vm.search()
        advanceUntilIdle()

        assertEquals(
            "a healthy archive must still reach Ready -- the gate must not refuse an ordinary read",
            BrowsePhase.Ready,
            vm.state.value.phase,
        )
        val published = vm.archiveStatus.value
        assertTrue(
            "the status road must have published a READY verdict for a healthy reader; observed $published",
            published is ArchiveState.Ready,
        )
        assertEquals("installed.bin", (published as ArchiveState.Ready).origin)
        assertNull("and no error is fabricated for a healthy read", vm.state.value.error)
    }
    /**
     * *** GS-FINAL-008 (round 719): THE AUDIT'S OTHER TWO CLAUSES, WHICH HAD NO ARMS. ***
     *
     * An independent sweep reported: *"the audit's explicit 'cancellation and a later successful retry' regression clause
     * has no arms, and `canRetry=false` closes the retry door on the status-throw path."* **MEASURED AND CONFIRMED --
     * the court had exactly three arms and neither of these.** *The audit's `Regression test` clause readeth verbatim:
     * "Fake the reader so content read succeeds but status throws; assert a typed error/unavailable phase and no
     * fabricated Ready. **INCLUDE CANCELLATION AND A LATER SUCCESSFUL RETRY.**"*
     */

    /** A reader whose status probe THROWS only while [broken] is true -- so the arm can HEAL it and retry. */
    private inner class HealableStatusReader : ArchiveReader {
        var broken = true
        var statusCalls = 0
        override fun status(): ArchiveState {
            statusCalls += 1
            if (broken) throw IllegalStateException("the status probe is unreadable")
            return ArchiveState.Ready(origin = "installed.bin", sha256 = "b".repeat(64))
        }
        override fun listDocuments(domain: String?): List<ArchiveDocument> = listOf(document)
        override fun listDomains(): List<String> = emptyList()
        override fun passages(documentId: Long): List<ArchivePassage> = listOf(passage)
        override fun search(query: String, limit: Int): List<ArchivePassage> = listOf(passage)
        override fun sourceMetadata(documentId: Long): ArchiveSourceMetadata? = null
    }

    /**
     * *** "A LATER SUCCESSFUL RETRY": THE SAME VIEW-MODEL, ONCE THE STATUS PROBE RECOVERS, MUST REACH A TRUTHY STATE. ***
     *
     * **WHY THIS IS NOT A RESTATEMENT OF THE FIRST ARM:** *that arm proveth a status throw does not become `Ready`; THIS
     * one proveth the refusal is **NOT PERMANENT** -- that the view-model can be asked again and, when the archive
     * answereth, publishes the archive's OWN metadata rather than a fabricated one.* **The two together are what maketh
     * the refusal honest rather than merely cautious:** a view-model that answered `Unavailable` for ever would satisfy
     * the first arm and be useless.
     */
    @Test
    fun aLaterSuccessfulRetryReachethTheRealMetadata() = runTest(dispatcher) {
        val reader = HealableStatusReader()
        val vm = viewModel(reader)

        vm.onQueryChanged("guide")
        vm.search()
        advanceUntilIdle()
        assertEquals(
            "*** the broken probe must first publish UNAVAILABLE -- the arm's own premise ***",
            BrowsePhase.Unavailable::class, vm.state.value.phase::class,
        )
        assertFalse("and it must NOT be a fabricated readiness", vm.state.value.phase is BrowsePhase.Ready)

        // *** THE ARCHIVE RECOVERS, AND THE SAME VIEW-MODEL IS ASKED AGAIN. ***
        reader.broken = false
        vm.search()
        advanceUntilIdle()

        val after = vm.state.value
        assertTrue(
            "*** GS-FINAL-008: A LATER SUCCESSFUL RETRY MUST REACH A TRUTHY STATE. The audit asked for exactly this " +
                "arm, and it is what separateth an honest refusal from a permanent one. Observed: " + after.phase +
                " ***",
            after.phase is BrowsePhase.Ready,
        )
        // *** THE METADATA LIVETH ON ITS OWN FLOW, PUBLISHED BY `refreshArchiveStatus` -- NOT BY `search()` *** (*the
        // phase carrieth none*). *My first draft read `archiveStatus` after a `search()` and the arm failed with "the
        // recovered archive must have published a verdict" -- the arm naming its OWN wrong road rather than a defect.*
        // **So the retry is driven through the road that publishes the metadata, which is also the road the audit's own
        // sentence paireth with `search`: "Map status exceptions through ONE typed mapper used by refresh, search and
        // open."**
        vm.refreshArchiveStatus()
        advanceUntilIdle()
        val status = vm.archiveStatus.value
        assertTrue("the recovered archive must have published a verdict", status is ArchiveState.Ready)
        val ready = status as ArchiveState.Ready
        assertEquals(
            "*** AND THE METADATA MUST BE THE ARCHIVE'S OWN -- never an assumed origin or an empty digest, which is the " +
                "fabrication this finding was about. ***",
            "installed.bin", ready.origin,
        )
        assertEquals("b".repeat(64), ready.sha256)
    }

    /**
     * *** "CANCELLATION": AN OBSOLETE OPERATION MUST NOT PUBLISH OVER A NEWER ONE. ***
     *
     * *The audit paireth cancellation with the retry clause, and the reason is the same one the repository already
     * recordeth for this view-model: a superseded search that publishes late WOULD OVERWRITE THE NEWER ANSWER.* **This
     * arm raiseth a slow status-throwing search, supersedes it with a query whose probe recovereth, and demands the
     * OBSOLETE failure never land on top of the newer truth.**
     */
    @Test
    fun aSupersededStatusThrowCannotOverwriteANewerResult() = runTest(dispatcher) {
        val reader = HealableStatusReader()
        val vm = viewModel(reader)

        // the ELDER operation runs against a broken probe...
        vm.onQueryChanged("elder")
        vm.search()
        // ...and is superseded BEFORE it can publish, by a query whose probe now works.
        reader.broken = false
        vm.onQueryChanged("newer")
        vm.search()
        advanceUntilIdle()

        val after = vm.state.value
        assertTrue(
            "*** THE NEWER RESULT MUST STAND: an obsolete status throw must not overwrite it. Observed: " + after.phase +
                " ***",
            after.phase is BrowsePhase.Ready,
        )
        assertEquals(
            "*** and the published identity must be the NEWER query's, not the elder's ***",
            "newer", after.searchedQuery,
        )
    }

}
