package io.godstone.app.ui.browse

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import io.godstone.core.archive.ArchiveDocument
import io.godstone.core.archive.ArchivePassage
import io.godstone.core.archive.ArchiveReadingAnchor
import io.godstone.core.archive.ArchiveReader
import io.godstone.core.archive.ArchiveRepository
import io.godstone.core.archive.ArchiveSourceMetadata
import io.godstone.core.archive.ArchiveState
import io.godstone.core.archive.SearchQuery
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The three places the browse journey standeth (T49, s17). */
enum class BrowseMode { DOCUMENTS, SEARCH, DOCUMENT }

/** The explicit phase of the road. An unavailable archive is told as
 *  [Unavailable] with its cause named -- it never masqueradeth as the
 *  honest empty [NoResults], which meaneth only: the archive is ready and
 *  this word matched nobody. */
sealed class BrowsePhase {
    object Loading : BrowsePhase()
    object Ready : BrowsePhase()
    object NoResults : BrowsePhase()
    data class Unavailable(val reason: String, val recoverable: Boolean) : BrowsePhase()
}

data class BrowseUiState(
    val query: String = "",
    // the identity of the search actually published -- editing [query] never
    // relabelleth already-submitted results (WIP law, kept verbatim in spirit)
    val searchedQuery: String? = null,
    val mode: BrowseMode = BrowseMode.DOCUMENTS,
    val phase: BrowsePhase = BrowsePhase.Loading,
    val loading: Boolean = true,
    val documents: List<ArchiveDocument> = emptyList(),
    val passages: List<ArchivePassage> = emptyList(),
    // the restored document identity, for process recreation and for back()
    val openedDocumentId: Long? = null,
    val openedTitle: String? = null,
    val openedSource: ArchiveSourceMetadata? = null,
    // *** GS-ARCHIVE-005 step 3: "a VALID reading anchor". *** TWO FIELDS, AND THE DISTINCTION IS THE WHOLE LAW:
    // `anchorPassageId` is the IDENTITY THE READER ASKED FOR (persisted, and restored on recreation), while
    // `readingTargetPassageId` is WHERE THE READER SHALL ACTUALLY BE PLACED -- resolved through
    // `ArchiveReadingAnchor.target`, which HONOURETH the asked-for passage only while it STILL STANDETH in the
    // currently selected document and otherwise FALLETH BACK TO THE FIRST. A reader whose place survived should not
    // be marched back to the top; a reader whose place did NOT survive must not be placed at whatever passage now
    // happeneth to carry that id.
    val anchorPassageId: Long? = null,
    val readingTargetPassageId: Long? = null,
    val error: String? = null,
    val canRetry: Boolean = false
)

/** The browsing journey's state owner.
 *
 *  T49 (s17) review/port of the Browse WIP: explicit Loading/Ready/NoResults/
 *  Unavailable phases derived from the repository's outcomes; full-document
 *  opening; back restoration of the query and of the document identity;
 *  source/revision projection; retry only where the road may mend; and the
 *  production missing archive never made to look ready -- the card's own
 *  falsifier. Every request captureth its generation token before delivery
 *  and revalidateth it after the road: a stale completion publisheth nothing.
 */
@HiltViewModel
class BrowseViewModel(
    private val reader: ArchiveReader,
    private val dispatcher: CoroutineDispatcher,
    // --------------------------------------------------------------------------------------
    // *** GS-ARCHIVE-005 STEP 3: THE SMALL NAVIGATION IDENTITIES, WHERE PROCESS RECREATION CAN FIND THEM. ***
    //
    // THE CARD NAMETH THIS VEHICLE BY NAME -- "Persist only small navigation identities on Android through
    // `SavedStateHandle` injected into the actual Hilt ViewModel constructor ... Restore them from the constructor;
    // remove unused MutableMap-only helpers or make them the serialization behind the real SavedStateHandle."
    //
    // MEASURED BEFORE THIS EDIT: `snapshotTo`/`restoreFrom` existed and **NO PRODUCTION CALLER REACHED EITHER**, and
    // `SavedStateHandle` appeared NOWHERE in the Android tree -- so the card's charge, "Both apps implement
    // snapshot/restore methods but no production caller persists/restores them", WAS EXACTLY TRUE ON THIS ISLE TOO.
    // THE HELPERS ARE THEREFORE NOT REMOVED BUT **MADE THE SERIALISATION BEHIND THE REAL HANDLE**, which is the
    // card's own second option: nothing is lost, and the map is no longer the DESTINATION -- it is the BRIDGE.
    // --------------------------------------------------------------------------------------
    private val savedState: SavedStateHandle? = null
) : ViewModel() {

    /** The shipping composition: the real repository, off the main thread. */
    @Inject
    constructor(archive: ArchiveRepository, savedState: SavedStateHandle)
        : this(archive, Dispatchers.Default, savedState)

    /**
     * *** GS-ARCHIVE-005 STEP 3: THE SMALL IDENTITIES, READ WHERE THE PLATFORM KEPT THEM. ***
     *
     * A handle carrying NOTHING is a FIRST RUN, not a restoration: restoring from an empty handle would strike out
     * the first browse with the empty place it just built -- the loss the finding chargeth, inverted. IT ANSWERETH
     * WHETHER IT RESTORED, because the caller MUST NOT browse when it did.
     */
    private fun restoreFromSavedStateIfAny(): Boolean {
        val handle = savedState ?: return false
        val keys = listOf("query", "searchedQuery", "mode", "openedDocumentId", "openedTitle",
                          "anchorDocument", "anchorPassage")
        val persisted = keys.mapNotNull { key -> handle.get<Any?>(key)?.let { key to it } }.toMap()
        if (persisted.isEmpty()) return false
        restoreFrom(persisted)
        return true
    }

    /**
     * *** GS-ARCHIVE-005 step 3: THE READER'S PLACE, NOTED. *** The Kotlin twin of the iOS scene's
     * `noteScroll(documentId:passageId:)`: the reading anchor is a SMALL NAVIGATION IDENTITY (two longs), which is
     * why it belongeth in a saved-state bundle at all.
     */
    fun noteScroll(documentId: Long? = null, passageId: Long? = null) {
        _state.value = _state.value.copy(anchorPassageId = passageId)
    }

    /**
     * *** GS-ARCHIVE-005 STEP 3: THE SMALL IDENTITIES, WRITTEN WHERE THE PLATFORM WILL KEEP THEM. ***
     *
     * ONELY THE SMALL ONES, which is the card's own bound ("Persist only small navigation identities"): a query, a
     * mode, a document identity and a title. NO RESULTS, NO PASSAGES AND NO ARCHIVE CONTENT enter a saved-state
     * bundle -- those are re-read from the archive, which is why restoring a PLACE is cheap.
     */
    private fun persistToSavedState() {
        val handle = savedState ?: return
        val s = _state.value
        handle["query"] = s.query
        handle["searchedQuery"] = s.searchedQuery
        handle["mode"] = s.mode.name
        handle["openedDocumentId"] = s.openedDocumentId
        handle["openedTitle"] = s.openedTitle
        // GS-ARCHIVE-005 step 3: "a valid reading anchor" -- the ASKED-FOR identity is what is persisted, NEVER the
        // resolved target, because validity must be judged against the document that standeth WHEN IT IS REOPENED.
        s.anchorPassageId?.let { handle["anchorPassage"] = it }
        s.openedDocumentId?.let { handle["anchorDocument"] = it }
    }

    private val _state = MutableStateFlow(BrowseUiState())
    val state: StateFlow<BrowseUiState> = _state.asStateFlow()

    // T47 (s17): the typed availability of the Archive path travels to the
    // UI -- "why nothing answers" is said, not implied by a bare boolean.
    private val _archiveStatus = MutableStateFlow<ArchiveState?>(null)
    val archiveStatus: StateFlow<ArchiveState?> = _archiveStatus.asStateFlow()

    fun refreshArchiveStatus() {
        viewModelScope.launch(dispatcher) {
            // GS-FINAL-008: THE SAME MAPPER EVERY OTHER ROAD USETH -- one status probe, one verdict.
            val verdict = archiveVerdict()
            _archiveStatus.value = verdict
            if (verdict !is ArchiveState.Ready) {
                val reason = when (verdict) {
                    is ArchiveState.Unavailable -> verdict.reason
                    else -> "the reader reporteth not"
                }
                _state.value = _state.value.copy(
                    loading = false,
                    phase = BrowsePhase.Unavailable(reason, recoverable = false),
                    documents = emptyList(),
                    passages = emptyList(),
                    error = null,
                    canRetry = false
                )
            }
        }
    }

    /** The token of the road. Every request captureth it before delivery and
     *  revalidateth it after the road; no current-state lookup standeth in
     *  for the missing immutable callback identity. */
    private val generation = AtomicLong(0L)

    private class Scene(
        val mode: BrowseMode,
        val query: String,
        val searchedQuery: String?,
        val documents: List<ArchiveDocument>,
        val passages: List<ArchivePassage>,
        val openedDocumentId: Long?,
        val openedTitle: String?,
        val openedSource: ArchiveSourceMetadata?
    )

    private var returnScene: Scene? = null
    private var lastRequest: (() -> Unit)? = null

    // *** GS-ARCHIVE-005 STEP 3: THE RESTORATION STANDETH **AFTER THE DECLARATIONS AND BEFORE THE FIRST BROWSE** --
    // AND BOTH HALVES OF THAT SENTENCE ARE LOAD-BEARING, EACH MEASURED RATHER THAN REASONED: ***
    //
    //   * BEFORE THE FIRST BROWSE, because `loadDocuments()` below would otherwise strike out the restored place with
    //     the browse's own empty query -- THE VERY LOSS THE FINDING CHARGETH, inverted;
    //   * AND **AFTER THE DECLARATIONS**, BECAUSE `init` BLOCKS RUN IN DECLARATION ORDER. The first draft of this
    //     restore sat near the TOP of the class (by the constructor), where `_state` (`:133`), `generation` (`:168`)
    //     and `returnScene` (`:181`) stand UNINITIALISED -- and THE BEHAVIOURAL ARM CAUGHT IT IN ONE RUN:
    //       `NullPointerException: Cannot invoke "AtomicLong.incrementAndGet()" because "this.generation" is null`
    //     **A STRUCTURAL CHECK COULD NEVER HAVE SEEN THAT**, and neither could reading: the code LOOKED right at both
    //     positions. It is the card's own demand ("Restore them from the constructor") that maketh the order matter.
    //
    // AND THE WRITE GOETH FROM ONE SEAM RATHER THAN FROM EVERY PUBLISHER: the state flow carrieth the whole place, so
    // a collector over it CANNOT MISS one -- whereas a call added to each of the nine `_state.value = ...` sites could
    // be forgotten by whoever addeth the tenth. **A RULE ENFORCED AT ONE SEAM BEATETH A RULE REMEMBERED AT N CALL
    // SITES.** With no handle wired the write is a NO-OP, so every existing court constructeth this class unchanged.
    init {
        if (!restoreFromSavedStateIfAny()) loadDocuments()
        viewModelScope.launch { _state.collect { persistToSavedState() } }
    }

    fun onQueryChanged(value: String) {
        // the gate keepeth the bounds the engine itself commandeth
        _state.value = _state.value.copy(query = value.take(SearchQuery.MAX_PHRASE_CHARS))
    }

    /**
     * *** GS-FINAL-008 (the independent audit, 2026-09-18): ONE STATUS PROBE, ONE VERDICT. ***
     *
     * THE AUDIT'S MEASUREMENT: *"search and openDocumentInternal use
     * `getOrDefault(ArchiveState.Ready(origin=\"assumed\", sha256=\"\"))` when reader.status throws.
     * refreshArchiveStatus treats the same exception as Unavailable."* AND ITS ROOT CAUSE: *"An optimistic fallback
     * collapses unknown/error into success and disagrees with another path using the same status API."*
     *
     * TWO DEFECTS IN ONE EXPRESSION, AND THE SECOND IS THE ONE THAT TRAVELS:
     *   1. A THROWING PROBE BECAME SUCCESS. The same exception was `Unavailable` in one road and `Ready` in three --
     *      so which verdict a user saw depended on WHICH SCREEN ROUTE they took, not on the archive's state.
     *   2. IT MANUFACTURED METADATA. `origin = "assumed"` with `sha256 = ""` is a digest nobody computed, published
     *      where a real one belongs. The audit's own words: *"Do not manufacture a digest or origin."*
     *
     * THE REMEDY IS THE ONE PLACE THIS DECISION MAY BE TAKEN. Every road that needs the archive's availability calls
     * THIS, so there is no second opinion to disagree with, and a throw can only ever become `Unavailable` carrying
     * its own cause.
     */
    private fun archiveVerdict(): ArchiveState =
        runCatching { reader.status() }
            .getOrElse { exc ->
                ArchiveState.Unavailable("status probe threw: " + (exc.message ?: exc::class.simpleName))
            }

    fun search() {
        val query = _state.value.query.trim()
        if (query.isEmpty()) {
            backToDocuments()
            return
        }
        val token = generation.incrementAndGet()
        _state.value = _state.value.copy(
            loading = true, phase = BrowsePhase.Loading, error = null, canRetry = false)
        lastRequest = { search() }
        viewModelScope.launch(dispatcher) {
            if (generation.get() != token) return@launch          // stale before the road
            val outcome = runCatching {
                withContext(dispatcher) { reader.search(query, SearchQuery.bound(40)) }
            }
            if (generation.get() != token) return@launch          // stale after the road
            outcome.fold(
                onSuccess = { hits ->
                    when (val verdict = archiveVerdict()) {
                        is ArchiveState.Ready ->
                            _state.value = _state.value.copy(
                                loading = false,
                                phase = if (hits.isEmpty()) BrowsePhase.NoResults else BrowsePhase.Ready,
                                // the field tellth what stands published: the trimmed
                                // identity, as the WIP law commandeth
                                query = query,
                                searchedQuery = query,
                                mode = BrowseMode.SEARCH,
                                documents = emptyList(),
                                passages = hits,
                                openedDocumentId = null,
                                openedTitle = null,
                                openedSource = null,
                                error = null,
                                canRetry = false)
                        is ArchiveState.Unavailable ->
                            _state.value = _state.value.copy(
                                loading = false,
                                phase = BrowsePhase.Unavailable(verdict.reason, recoverable = false),
                                query = query,
                                searchedQuery = query,
                                mode = BrowseMode.SEARCH,
                                documents = emptyList(),
                                passages = emptyList(),
                                openedDocumentId = null,
                                openedTitle = null,
                                openedSource = null,
                                error = null,
                                canRetry = false)
                    }
                },
                onFailure = { exc -> publishFailure("the search could not be completed", exc) }
            )
        }
    }

    /** The screen's sealed reference: open a document whole from the list. */
    fun open(document: ArchiveDocument) {
        stashScene()
        openDocumentInternal(document.id, document.title)
    }

    /** The journey's new door: a search hit openeth the WHOLE document, not
     *  only the matched passage (s17 'full document navigation'). */
    /** GS-ARCHIVE-003: a search HIT openeth the whole document. It useth the same road the
     * document list doth, so the two entrances cannot drift apart. */
    fun openHit(passage: ArchivePassage) = openPassage(passage)

    /** The honest NoResults action: clear the query and return to the document list. */
    fun clearQuery() {
        _state.value = _state.value.copy(query = "")
        search()          // the road the query field already useth
    }

    fun openPassage(passage: ArchivePassage) {
        stashScene()
        openDocumentInternal(passage.documentId, passage.documentTitle)
    }

    private fun openDocumentInternal(documentId: Long, title: String) {
        val token = generation.incrementAndGet()
        _state.value = _state.value.copy(
            loading = true, phase = BrowsePhase.Loading, error = null, canRetry = false)
        lastRequest = { openDocumentInternal(documentId, title) }
        viewModelScope.launch(dispatcher) {
            if (generation.get() != token) return@launch
            val outcome = runCatching {
                withContext(dispatcher) {
                    reader.passages(documentId) to
                        runCatching { reader.sourceMetadata(documentId) }.getOrNull()
                }
            }
            if (generation.get() != token) return@launch
            outcome.fold(
                onSuccess = { (found, source) ->
                    when (val verdict = archiveVerdict()) {
                        is ArchiveState.Ready ->
                            _state.value = _state.value.copy(
                                loading = false,
                                phase = BrowsePhase.Ready,
                                mode = BrowseMode.DOCUMENT,
                                documents = emptyList(),
                                passages = found,
                                openedDocumentId = documentId,
                                openedTitle = title,
                                openedSource = source,
                                // GS-ARCHIVE-005 step 3: THE ANCHOR IS RESOLVED **WHERE THE PASSAGES ARE KNOWN**,
                                // which is here and nowhere else -- validity is a judgement about THIS document's
                                // passages, so it cannot be made when the anchor is read from the handle.
                                readingTargetPassageId = ArchiveReadingAnchor.target(
                                    found.map { it.chunkId }, _state.value.anchorPassageId),
                                error = null,
                                canRetry = false)
                        is ArchiveState.Unavailable ->
                            _state.value = _state.value.copy(
                                loading = false,
                                phase = BrowsePhase.Unavailable(verdict.reason, recoverable = false),
                                documents = emptyList(),
                                passages = emptyList(),
                                openedDocumentId = null,
                                openedTitle = null,
                                openedSource = null,
                                error = null,
                                canRetry = false)
                    }
                },
                onFailure = { exc -> publishFailure("the document could not be opened", exc) }
            )
        }
    }

    /** Back restoration: from the document, the scene from which it was
     *  opened returneth untouched -- the query, its published identity and
     *  the results stand again. From a search, the documents return. */
    fun back() {
        val current = _state.value
        when (current.mode) {
            BrowseMode.DOCUMENT -> {
                val scene = returnScene
                generation.incrementAndGet()
                if (scene == null) {
                    backToDocuments()
                    return
                }
                returnScene = null
                _state.value = current.copy(
                    loading = false,
                    phase = phaseOf(scene.mode, scene.passages, scene.documents, scene.searchedQuery),
                    mode = scene.mode,
                    query = scene.query,
                    searchedQuery = scene.searchedQuery,
                    documents = scene.documents,
                    passages = scene.passages,
                    openedDocumentId = scene.openedDocumentId,
                    openedTitle = scene.openedTitle,
                    openedSource = scene.openedSource,
                    error = null,
                    canRetry = false)
                if (scene.mode == BrowseMode.DOCUMENTS && scene.documents.isEmpty()) {
                    loadDocuments()
                }
            }
            BrowseMode.SEARCH -> backToDocuments()
            BrowseMode.DOCUMENTS -> {
                // already at the root: the journey resteth
            }
        }
    }

    fun backToDocuments() {
        generation.incrementAndGet()
        returnScene = null
        _state.value = _state.value.copy(
            query = "", searchedQuery = null, mode = BrowseMode.DOCUMENTS,
            openedDocumentId = null, openedTitle = null, openedSource = null,
            error = null, canRetry = false)
        loadDocuments()
    }

    /** Retry only where the road may mend: a failed request is replayable;
     *  an absent archive is the installer's to mend, not the reader's. */
    fun retry() {
        if (_state.value.canRetry) lastRequest?.invoke()
    }

    /** Process recreation: the journey's place, the query and the opened
     *  identity travel through a bundle-like handle and stand again. */
    fun snapshotTo(handle: MutableMap<String, Any?>) {
        val s = _state.value
        handle["query"] = s.query
        handle["searchedQuery"] = s.searchedQuery
        handle["mode"] = s.mode.name
        handle["openedDocumentId"] = s.openedDocumentId
        handle["openedTitle"] = s.openedTitle
        // GS-ARCHIVE-005 step 3: THE TWO SERIALISATIONS MUST AGREE, because the card maketh THIS ONE "the
        // serialization behind the real SavedStateHandle" -- a helper that dropped the anchor would silently lose it
        // for every caller that used the helper rather than the seam.
        s.anchorPassageId?.let { handle["anchorPassage"] = it }
        s.openedDocumentId?.let { handle["anchorDocument"] = it }
    }

    fun restoreFrom(handle: Map<String, Any?>) {
        val modeName = handle["mode"] as? String
        val mode = runCatching { BrowseMode.valueOf(modeName ?: "DOCUMENTS") }
            .getOrDefault(BrowseMode.DOCUMENTS)
        val query = handle["query"] as? String ?: ""
        val searchedQuery = handle["searchedQuery"] as? String
        val openedId = handle["openedDocumentId"] as? Long
        val openedTitle = handle["openedTitle"] as? String
        val anchorPassage = handle["anchorPassage"] as? Long
        generation.incrementAndGet()
        returnScene = Scene(BrowseMode.DOCUMENTS, "", null, emptyList(), emptyList(), null, null, null)
        _state.value = BrowseUiState(
            query = query, searchedQuery = searchedQuery, mode = mode,
            // GS-ARCHIVE-005 step 3: the ASKED-FOR anchor standeth from the moment of restoration; the RESOLVED
            // target is computed when the document's passages are known (`openDocumentInternal`).
            anchorPassageId = anchorPassage,
            phase = BrowsePhase.Loading, loading = true)
        when (mode) {
            BrowseMode.DOCUMENT -> {
                if (openedId != null) {
                    openDocumentInternal(openedId, openedTitle ?: "")
                } else {
                    loadDocuments()
                }
            }
            BrowseMode.SEARCH -> {
                if (searchedQuery != null && searchedQuery.isNotEmpty()) {
                    onQueryChanged(searchedQuery)
                    search()
                } else {
                    loadDocuments()
                }
            }
            BrowseMode.DOCUMENTS -> loadDocuments()
        }
    }

    private fun loadDocuments() {
        val token = generation.incrementAndGet()
        _state.value = _state.value.copy(
            loading = true, phase = BrowsePhase.Loading, error = null, canRetry = false,
            searchedQuery = if (_state.value.mode == BrowseMode.DOCUMENTS) null else _state.value.searchedQuery,
            openedDocumentId = null, openedTitle = null, openedSource = null)
        lastRequest = { loadDocuments() }
        viewModelScope.launch(dispatcher) {
            if (generation.get() != token) return@launch
            val outcome = runCatching {
                withContext(dispatcher) { reader.listDocuments(null) }
            }
            if (generation.get() != token) return@launch
            outcome.fold(
                onSuccess = { found ->
                    when (val verdict = archiveVerdict()) {
                        is ArchiveState.Ready ->
                            _state.value = _state.value.copy(
                                loading = false,
                                phase = if (found.isEmpty()) BrowsePhase.NoResults else BrowsePhase.Ready,
                                mode = BrowseMode.DOCUMENTS,
                                documents = found,
                                passages = emptyList(),
                                openedDocumentId = null,
                                openedTitle = null,
                                openedSource = null,
                                error = null,
                                canRetry = false)
                        is ArchiveState.Unavailable ->
                            _state.value = _state.value.copy(
                                loading = false,
                                phase = BrowsePhase.Unavailable(verdict.reason, recoverable = false),
                                documents = emptyList(),
                                passages = emptyList(),
                                error = null,
                                canRetry = false)
                    }
                },
                onFailure = { exc -> publishFailure("the archive could not be read", exc) }
            )
        }
    }

    private fun publishFailure(what: String, exc: Throwable) {
        // the shown tale is sanitised: the cause's own words never travel
        // into the UI -- only the kind of the woe is named
        _state.value = _state.value.copy(
            loading = false,
            phase = BrowsePhase.Unavailable(
                "$what (" + (exc::class.simpleName ?: "unknown") + ")",
                recoverable = true),
            documents = emptyList(),
            passages = emptyList(),
            openedDocumentId = null,
            openedTitle = null,
            openedSource = null,
            error = what,
            canRetry = true)
    }

    private fun stashScene() {
        val s = _state.value
        if (s.mode != BrowseMode.DOCUMENT) {
            returnScene = Scene(s.mode, s.query, s.searchedQuery, s.documents,
                s.passages, null, null, null)
        }
    }

    private fun phaseOf(
        mode: BrowseMode,
        passages: List<ArchivePassage>,
        documents: List<ArchiveDocument>,
        searchedQuery: String?
    ): BrowsePhase = when (mode) {
        BrowseMode.SEARCH ->
            if (passages.isEmpty() && searchedQuery != null) BrowsePhase.NoResults else BrowsePhase.Ready
        BrowseMode.DOCUMENTS ->
            if (documents.isEmpty()) BrowsePhase.NoResults else BrowsePhase.Ready
        BrowseMode.DOCUMENT -> BrowsePhase.Ready
    }
}
