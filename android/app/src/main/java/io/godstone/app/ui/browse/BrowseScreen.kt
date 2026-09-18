package io.godstone.app.ui.browse

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.snapshotFlow
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.testTag
import androidx.compose.runtime.key
import kotlinx.coroutines.flow.distinctUntilChanged
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.godstone.core.archive.ArchiveDocument
import io.godstone.core.archive.ArchivePassage

/** The production reading list's handle, so a court can drive a REAL gesture against the REAL composable. */
internal const val READING_LIST_TAG = "reading-list"

/** Search and document browsing remain available even when the model and radios do not. */
@Composable
fun BrowseScreen(vm: BrowseViewModel = hiltViewModel()) {
    val state by vm.state.collectAsStateWithLifecycle()

    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(state.openedTitle ?: "Archive", style = MaterialTheme.typography.titleLarge)
            state.openedSource?.let { provenance ->
                // T49 (s17): source/revision display -- where a passage came from
                Text(
                    "source " + provenance.sourceId + " . revision " + provenance.revision +
                        " . licence " + provenance.licence,
                    style = MaterialTheme.typography.bodySmall
                )
            }
            if (state.openedTitle != null || state.passages.isNotEmpty()) {
                Button(onClick = vm::backToDocuments) { Text("All documents") }
            }
            if (state.mode == BrowseMode.DOCUMENT) {
                Button(onClick = vm::back) { Text("Back") }
            } else if (state.mode == BrowseMode.SEARCH) {
                Button(onClick = vm::back) { Text("Documents") }
            }
        }

        OutlinedTextField(
            value = state.query,
            onValueChange = vm::onQueryChanged,
            label = { Text("Search every document") },
            modifier = Modifier.fillMaxWidth(),
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
            keyboardActions = KeyboardActions(onSearch = { vm.search() })
        )
        Button(onClick = vm::search, modifier = Modifier.fillMaxWidth()) { Text("Search offline") }

        state.error?.let {
            Card(
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                    contentColor = MaterialTheme.colorScheme.onErrorContainer
                )
            ) { Text(it, modifier = Modifier.padding(16.dp)) }
        }

        // T49 (s17): the typed phases speak for themselves. An unavailable
        // archive nameth its cause; retry is offered only where the road may
        // mend (canRetry), never to knock upon an absent installation.
        (state.phase as? BrowsePhase.Unavailable)?.let { unavailable ->
            Card(
                colors = CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.errorContainer,
                    contentColor = MaterialTheme.colorScheme.onErrorContainer
                )
            ) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("Archive unavailable: " + unavailable.reason)
                    if (unavailable.recoverable) {
                        Text("This may be tried again once the archive is installed.",
                            style = MaterialTheme.typography.bodySmall)
                    }
                }
            }
        }
        if (state.canRetry) {
            Button(onClick = vm::retry, modifier = Modifier.fillMaxWidth()) { Text("Retry") }
        }

        if (state.loading) {
            CircularProgressIndicator(modifier = Modifier.align(Alignment.CenterHorizontally))
        } else {
            // *** GS-FINAL-006 (the independent audit, 2026-09-18): THE READING LIST OWNS ITS STATE AND ITS PLACE. ***
            //
            // THE AUDIT'S CHARGE ON THIS ISLE: *"Android `BrowseScreen` has no list state or scroll action consuming
            // the stored anchor."* MEASURED BEFORE THIS EDIT: it was TRUE -- a grep of this file for `LazyListState`,
            // `rememberLazyListState` and `scrollTo` returned NOTHING. ONE flat `LazyColumn` served BOTH the document
            // list and the passages, so:
            //   * `state.readingTargetPassageId` -- RESOLVED correctly by the ViewModel through
            //     `ArchiveReadingAnchor.target` -- was NEVER CONSUMED, and a returning reader was placed at the top;
            //   * no visible passage was ever reported back, so nothing could be persisted for the next return.
            //
            // **THE VIEWMODEL HAD ALREADY DONE ITS HALF.** This is the SAME shape the audit named on the other isle:
            // a resolved identity with no consumer.
            if (state.mode == BrowseMode.DOCUMENT) {
                ReadingList(state, vm)
            } else {
            LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                items(state.documents, key = { it.id }) { DocumentCard(it, vm::open) }
                // GS-ARCHIVE-003: a search hit must OPEN its document -- the audit found that
                // every result was a non-clickable card with no action, so a reader could never
                // reach the full document from a search.
                items(state.passages, key = { it.chunkId }) { PassageCard(it, vm::openHit) }
                if (state.phase is BrowsePhase.NoResults) {
                    item {
                        // the honest empty phase, RENDERED: the archive is ready and answered
                        // nothing -- with an action to change the query
                        Column(Modifier.padding(16.dp),
                            verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text("No matches in the archive.")
                            Text("Try a different word or a broader term.",
                                style = MaterialTheme.typography.bodySmall)
                            if (state.query.isNotBlank()) {
                                Button(onClick = vm::clearQuery) { Text("Clear the query") }
                            }
                        }
                    }
                }
            }
            }
        }
    }
}

/**
 * *** THE READING ROAD -- AND THE THREE THINGS THE CARD ASKS OF IT. ***
 *
 * ITS OWN WORDS: *"On Android remember a `LazyListState`, consume the resolved anchor only after matching document
 * data/layout exists, and observe visible item identity into saved state. Clear obsolete anchors on document
 * changes."*
 *
 * EACH CLAUSE, AND HOW IT IS HONOURED:
 *   * **remember a `LazyListState`** -- `rememberLazyListState()`, keyed to the opened document so a NEW document
 *     starteth at the top rather than inheriting the last one's offset;
 *   * **consume the resolved anchor ONLY AFTER matching document data/layout exists** -- the scroll runs in a
 *     `LaunchedEffect` keyed on the OPENED DOCUMENT and the RESOLVED TARGET, so it fires after `state.passages` are
 *     the ones the target was resolved against. A target resolved for a different document cannot be consumed here
 *     by construction: the effect restarts whenever either changes;
 *   * **observe visible item identity into saved state** -- `snapshotFlow` over the list's own layout info reports
 *     the FIRST VISIBLE passage's id through `vm.noteScroll`, which is what makes a return possible at all.
 *
 * AND AN OBSOLETE TARGET IS HARMLESS BY CONSTRUCTION: `readingTargetPassageId` is resolved through
 * `ArchiveReadingAnchor.target`, which honours the asked-for passage only while it still stands in THIS document --
 * so a target that no longer exists falls back to the first, and `scrollToItem` is asked for an index that is really
 * there.
 */
/**
 * *** THE REPORT DECISION, PURE AND THEREFORE COURT-COVERED -- BECAUSE THE OBVIOUS WIRING IS WRONG. ***
 *
 * THE DEFECT THIS PREVENTETH, NAMED BY REVIEW AND REAL: `snapshotFlow { firstVisibleItemIndex }` EMITS THE CURRENT
 * INDEX IMMEDIATELY ON COLLECTION -- index 0 on a fresh composition -- AND AGAIN EACH TIME `ids` CHANGES AND THE
 * EFFECT RESTARTS. THAT EMISSION ARRIVES BEFORE THE SIBLING CONSUME-EFFECT'S `scrollToItem` HAS TAKEN LAYOUT EFFECT.
 * So an unguarded report would `noteScroll(passageId = ids[0])` and OVERWRITE THE JUST-RESTORED ANCHOR WITH THE FIRST
 * PASSAGE -- **"AN ANCHOR THE READER NEVER SET", REINTRODUCED ONE LAYER ABOVE THE CLAUSE THAT EXISTS TO PREVENT IT.**
 * The reader returns, is placed correctly, and the act of returning destroys the place.
 *
 * AND THE COURT COULD NOT SEE IT: no `androidTest` target existeth on this isle, so the Compose half is never
 * executed. **THEREFORE THE DECISION IS NOT ALLOWED TO LIVE IN THE EFFECT WHERE NOTHING MEASURES IT.**
 *
 * THE RULE: A REPORT IS ONLY THE READER'S OWN MOVEMENT IF THE INDEX THEY ARE AT IS THE INDEX THEY WERE PLACED AT.
 * While a programmatic placement is still outstanding, the visible index is the APP's doing, not the reader's.
 *
 * @param visibleIndex the passage index currently on screen
 * @param targetIndex  the index the app is placing the reader at, or null when no placement is outstanding
 * @return the passage id the READER may be said to have chosen, or null while the app's own scroll is in flight
 */
internal fun reportedAnchorPassageId(
    previousVisibleIndex: Int?,
    visibleIndex: Int,
    targetIndex: Int?,
    placementLanded: Boolean,
    ids: List<Long>,
): Long? {
    // (1) *** THE INITIAL EMISSION IS NEVER THE READER'S MOVEMENT. *** `snapshotFlow` EMITS THE CURRENT VALUE ON
    // COLLECTION, so the first value is wherever the list happened to start -- the reader has not touched anything
    // yet. Reporting it would RECORD AN ANCHOR THE READER NEVER SET and persist it on the next snapshot. **THE REAL
    // UI COURT CAUGHT THIS: with no target at all the initial emission still reported `passage 1`.**
    if (previousVisibleIndex == null) return null
    // (2) *** AND WHILE A PLACEMENT IS OUTSTANDING, THE POSITION IS THE APP'S DOING, NOT THE READER'S. *** This
    // covereth the emission that arrives BEFORE `scrollToItem` takes layout effect -- the one that would overwrite
    // the just-restored anchor with the first passage -- AND the landing emission itself, which must NOT be recorded
    // either: `readingTargetPassageId` is the RESOLVED target, and when the asked-for anchor fell back (because it no
    // longer standeth in this document) recording the fallback would REPLACE the reader's asked-for place with the
    // first passage. The T49 arm nameth this exactly: *"the asked-for anchor is remembered AS ASKED FOR -- it is not
    // silently discarded."*
    if (targetIndex != null && !placementLanded) return null
    // (3) AND ONCE THE PLACEMENT HAS LANDED, A GENUINE CHANGE OF POSITION IS THE READER'S OWN MOVEMENT.
    return ids.getOrNull(visibleIndex)
}

@Composable
// `internal` RATHER THAN `private` SO THE REAL COMPOSABLE CAN BE RENDERED BY THE UI COURT: a court that drove a
// REPLICA of this wiring would be asserting an architecture rather than observing the runtime, which is worse than
// no court at all. The evidence is the real thing or it is nothing.
internal fun ReadingList(state: BrowseUiState, vm: BrowseViewModel) {
    // *** KEYED TO THE DOCUMENT -- CORRECT, AND DOMINATED TODAY BY THE CONSUME-EFFECT's `scrollTo(0)`. ***
    //
    // MY FIRST DRAFT SAID "KEYED TO THE DOCUMENT" WHILE CALLING `rememberLazyListState()` WITH NO KEY AT ALL:
    // `rememberLazyListState(initialFirstVisibleItemIndex, initialFirstVisibleItemScrollOffset)` TAKES NO `vararg`
    // KEYS, so the comment described an intention the code did not implement. **A COMMENT THAT CLAIMS BEHAVIOUR THE
    // CALL DOES NOT HAVE IS THE SAME DEFECT AS A GATE NOBODY CONSULTS.**
    //
    // *** AND MY SECOND EXPLANATION WAS ALSO WRONG, AND THIS ONE MATTERS MORE BECAUSE A WRONG RATIONALE MISLEADS THE
    // NEXT MAINTAINER: I WROTE THAT THE TRANSITION WAS *UNREACHABLE*. IT IS NOT. *** `openPassage`/`openHit` (a
    // passage card tapped while already in DOCUMENT mode) DO SWAP DOCUMENT A FOR B WITH `mode` STAYING DOCUMENT, so
    // `ReadingList` STAYETH MOUNTED ACROSS THE SWAP AND THE TRANSITION IS REACHABLE.
    //
    // THE ACCURATE REASON, FROM THE SOURCE TRACE: on a fresh open of a DIFFERENT document the cross-document anchor is
    // cleared by `openDocumentInternal`'s ownership guard -> `ArchiveReadingAnchor.target(ids, null)`RETURNETH THE
    // FIRST PASSAGE -> `readingTargetPassageId` IS B'S FIRST PASSAGE -> **THE CONSUME-EFFECT RUNNETH `scrollToItem(0)`,
    // WHICH FORCETH THE TOP WHATEVER OFFSET WAS INHERITED.** So the key is MASKED BY DOMINANCE, NOT BY UNREACHABILITY.
    // **IT IS THE CORRECT FIX AND IT IS INDEPENDENTLY NEEDED: if a future change makes a same-document re-entry or a
    // "next/previous chapter" affordance resolve the target to a NON-ZERO index, the consume-effect no longer masketh
    // the inherited offset AND THIS KEY BECOMES LOAD-BEARING.**
    //
    // AND THE MEASUREMENT, RUN TWICE BECAUSE THE FIRST RUN WAS UNRELIABLE: removing this key LEAVES ALL SEVEN RENDERED
    // ARMS GREEN -- deterministically, THREE CONSECUTIVE FULL-SUITE RUNS, and ALSO 3/3 WITH THE ARM ISOLATED. Early
    // "reds" under this mutation were HARNESS NONDETERMINISM (the court's `waitForIdle` was racing the
    // `LaunchedEffect`'s coroutine), NOT a real dependency: THE SAME MUTATION WITH THE SAME CODE WENT RED, THEN GREEN,
    // THEN GREEN. The court's waits are now condition-based (`waitUntil`), and under them the result is stable.
    // **RECORDED AS UNEXERCISED BY ANY ARM, AND NOT COUNTED AS COVERED.**
    val listState = key(state.openedDocumentId) { rememberLazyListState() }

    // *** A REVIEW WARNED THAT THIS INLINE MAP FEEDS A FRESH `List` INTO BOTH EFFECTS' KEYS ON EVERY RECOMPOSITION,
    // AND THAT `LaunchedEffect` KEYS COMPARE LISTS BY REFERENCE -- SO EQUAL CONTENTS WOULD STILL RE-FIRE, THE REPORT
    // EFFECT WOULD RESTART ITSELF THROUGH ITS OWN `vm.noteScroll` WRITE, `previous`/`placementLanded` WOULD RESET,
    // AND THE READER'S LATER SCROLLS WOULD SILENTLY STOP BEING RECORDED. ***
    //
    // **MEASURED IN ISOLATION, AND THE PREMISE IS FALSE: `LaunchedEffect` KEYS COMPARE WITH STRUCTURAL EQUALITY, NOT
    // BY REFERENCE.** A composable that built `val ids = listOf(1L, 2L, 3L)` fresh on every composition, keyed an
    // effect on it, and then FORCED a real recomposition (a click writing state) observed the effect start **EXACTLY
    // ONCE**. (The probe was a throwaway and is deleted; the finding is here so the next maintainer does not re-derive
    // it or "fix" a non-problem. The two-scroll arm below is what would catch a real restart, and it passeth.)
    //
    // (AND IT IS `state.passages` -- a STABLE model-state reference assigned once per successful load -- that the map
    // deriveth from, so even under reference comparison this would not churn: the input is stable and the output is
    // content-equal.)
    val ids = state.passages.map { it.chunkId }
    val target = state.readingTargetPassageId

    // (2) CONSUME THE RESOLVED ANCHOR -- after the data it was resolved against is what is on screen.
    LaunchedEffect(state.openedDocumentId, target, ids) {
        if (target == null) return@LaunchedEffect
        val index = ids.indexOf(target)
        if (index >= 0) listState.scrollToItem(index)
    }

    // (3) AND REPORT WHAT IS VISIBLE -- BUT ONLY THE READER'S OWN MOVEMENT. See `reportedAnchorPassageId` above for
    // the defect this gate preventeth: an unguarded report CLOBBERS THE ANCHOR IT WAS MEANT TO PROTECT, because
    // `snapshotFlow` emits the current index (0 on a fresh composition) BEFORE `scrollToItem` has taken effect.
    LaunchedEffect(listState, ids, target) {
        val targetIndex = target?.let { ids.indexOf(it) }?.takeIf { it >= 0 }
        var previous: Int? = null
        var placementLanded = false
        snapshotFlow { listState.firstVisibleItemIndex }
            .distinctUntilChanged()
            .collect { index ->
                // NULL MEANS "THE APP'S OWN SCROLL, OR THE INITIAL LAYOUT" -- and nothing may be recorded for either.
                val chosen = reportedAnchorPassageId(previous, index, targetIndex, placementLanded, ids)
                // THE PLACEMENT IS MARKED LANDED *AFTER* THE DECISION, so the landing emission itself stayeth
                // unreported while every LATER move belongeth to the reader again.
                if (targetIndex != null && index == targetIndex) placementLanded = true
                previous = index
                if (chosen == null) return@collect
                vm.noteScroll(documentId = state.openedDocumentId, passageId = chosen)
            }
    }

    // `testTag` IS A DELIBERATE, MINIMAL SEAM: without a handle on THIS node a court cannot perform a real
    // gesture against the production list, and the alternative -- driving a hand-written copy of the wiring -- is
    // the false assurance this court exists to end. It changeth no behaviour and is inert in production.
    LazyColumn(state = listState, verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.testTag(READING_LIST_TAG)) {
        items(state.passages, key = { it.chunkId }) { PassageCard(it, vm::openHit) }
    }
}

@Composable
private fun DocumentCard(document: ArchiveDocument, onOpen: (ArchiveDocument) -> Unit) {
    Card(
        onClick = { onOpen(document) },
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(document.title, fontWeight = FontWeight.Bold)
            Text(document.domain, style = MaterialTheme.typography.bodyMedium)
            if (document.isCritical) Text("Critical procedure", color = MaterialTheme.colorScheme.error)
        }
    }
}

@Composable
private fun PassageCard(passage: ArchivePassage, onOpen: (ArchivePassage) -> Unit) {
    // GS-ARCHIVE-003: the card is CLICKABLE and carrieth an ACCESSIBLE action naming what it
    // doth, so a reader (including a screen-reader user) can open the whole document.
    Card(
        onClick = { onOpen(passage) },
        modifier = Modifier.fillMaxWidth().semantics {
            contentDescription = "Read the full document: " + passage.documentTitle
        },
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(passage.documentTitle, fontWeight = FontWeight.Bold)
            if (passage.section.isNotBlank()) Text(passage.section, style = MaterialTheme.typography.bodyMedium)
            Text(passage.text, style = MaterialTheme.typography.bodyLarge)
            Text("Read full document", style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary)
        }
    }
}
