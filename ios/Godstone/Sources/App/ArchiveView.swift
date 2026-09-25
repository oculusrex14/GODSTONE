import SwiftUI
import GodstoneCore

/// The always-available browser over the immutable on-device Archive.
///
/// T50 (s17): the reader model is wired in at the composition root and the
/// view rendereth the SCENE -- the isle twin of the sealed android browse
/// journey. Modes (documents/search/document), the immutable identity of the
/// published search, back restoration by stash, the earned retry, the
/// sanitised banner and the provenance display all pass through the scene;
/// the view keepeth no state of its own but the field's live text.
struct ArchiveView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        ArchiveBrowser(scene: container.scene, library: container.archiveLibrary)
    }
}

private struct ArchiveBrowser: View {
    @ObservedObject private var scene: ArchiveSceneModel
    private let library: ArchiveLibrary

    @State private var fieldText = ""
    @State private var submittedQuery = ""
    @State private var retry = 0

    // --------------------------------------------------------------------------------------
    // *** GS-ARCHIVE-005 STEP 4: THE SCENE'S PLACE, PERSISTED -- AND `snapshot`/`restore` GAIN THEIR FIRST
    // PRODUCTION CALLER. ***
    //
    // THE DEFECT, MEASURED AT ROUNDS 523, 524 AND AGAIN AT 525 BEFORE THIS EDIT: `ArchiveSceneModel.snapshot(into:)`
    // and `restore(from:)` HAD NO PRODUCTION CALLER WHATSOEVER -- the only callers were courts -- so a process
    // recreation LOST the promised query and document place. The card's own words: "Both apps implement
    // snapshot/restore methods but no production caller persists/restores them."
    //
    // *** AND THE VEHICLE BELOW WAS WRONG FOR ONE MORE ROUND, WHICH IS WHY THE ARM STAYED RED. ***
    //
    // *The record stood in `@SceneStorage`, justified by this note:* ***"W16 (a behavioural arm in GodstoneCoreTests)
    // MEASURABLY PROVETH that the handle surviveth a real `PropertyListSerialization` round-trip INTO A FRESH SCENE
    // with its identity and metadata intact."*** **THAT EXPERIMENT MEASURED THE SERIALISATION, NOT THE DURABILITY, AND
    // THE DIFFERENCE IS THE ENTIRE DEFECT:** *a plist round-trip into a fresh model proveth the handle can be ENCODED
    // AND DECODED, and saith nothing about whether the STORE surviveth a `terminate()`.* *`@SceneStorage` is
    // scene-scoped by contract -- iOS discardeth it with the scene, and restoreth it only for an app that OPTS INTO
    // STATE RESTORATION, which this target does not (no scene manifest, no scene delegate, no restoration
    // identifier).*
    //
    // **MEASURED, LOCAL AND HOSTED: the recreation arm was DETERMINISTICALLY RED, the relaunch landing at the document
    // list.** *So the write-timing fix (now also in place, at a guaranteed transition) could not have helped: **the
    // system was throwing the store away.*** **THE VEHICLE IS `UserDefaults` NOW -- process-durable, on disk, requiring
    // no restoration opt-in -- and the fail-closed rule is preserved from the old code because it was correct: a
    // half-written place is worse than an old one, so a record that cannot be encoded is NOT written.**
    // --------------------------------------------------------------------------------------
    @Environment(\.scenePhase) private var scenePhase
    @State private var placeStore = ArchivePlaceStore()

    // --------------------------------------------------------------------------------------
    // *** GS-ARCHIVE-005 STEP 1, THE CLAUSE LEFT OWED UNTIL ROUND 536: **THE `NavigationStack` IS BOUND.** ***
    //
    // The card offereth two options for step 1, and round 524 took the SECOND (a destination that publisheth its
    // own checked metadata). IT NAMED THE FIRST AS OWED, and this is it: *'Bind `NavigationStack` to an explicit
    // path/document identity.'* MEASURED BEFORE THIS EDIT: `NavigationStack {` carrieth NO `path:` argument, and a
    // grep of the whole App source set for `NavigationPath` returned NOTHING -- so the stack's own path was THE
    // VIEW'S PRIVATE BUSINESS and **NOTHING OUTSIDE IT COULD PLACE, READ OR RESTORE A DESTINATION.**
    // WITH THE PATH NAMED: restoration can PUT the reader back in its document, and that is the difference betwixt a
    // stack that merely showeth a document and one a process recreation can RETURN TO.
    // --------------------------------------------------------------------------------------
    @State private var path: [ArchiveDocument] = []
    /// The document the path was last synchronised with, so that a change of direction is TOLD APART from a no-op
    /// -- an unguarded sync would either fight the user's taps or never run at all.
    @State private var pathSyncTarget: Int64?

    /// Restoration happeneth ONCE per scene: the `.task` below re-runneth on every submitted query, and a second
    /// restoration would strike out the reader's own place.
    @State private var restoredOnce = false

    private struct SceneID: Equatable {
        let submitted: String
        let retry: Int
    }

    init(scene: ArchiveSceneModel, library: ArchiveLibrary) {
        _scene = ObservedObject(wrappedValue: scene)
        self.library = library
    }

    /// *** GS-ARCHIVE-005 STEP 4: THE PLACE, WRITTEN INTO A STORE THAT SURVIVETH THE PROCESS. ***
    ///
    /// *`snapshot(into:)` is the model's own serialisable place, and `ArchivePlaceStore` is a `UserDefaults` record.*
    /// **THE COMMENT HERE PREVIOUSLY SAID "THE SCENE-SCOPED STORE ... `SceneStorage`, WHICH THE CARD NAMETH BY NAME",
    /// AND THE CARD'S NAME WAS THE BUG:** *a scene-scoped store is discarded with the scene, so it cannot survive the
    /// `terminate()` this step existeth to survive.* ***A COMMENT THAT NAMETH THE DEFECTIVE MECHANISM AS THE INTENDED
    /// ONE IS HOW THE DEFECT SURVIVED A ROUND -- so the correction is recorded here rather than silently swapped.***
    ///
    /// *AND THE FAIL-CLOSED RULE STANDS, BECAUSE IT WAS CORRECT: a record that cannot be written is NOT written and
    /// the previous one standeth -- **A HALF-WRITTEN PLACE IS WORSE THAN AN OLD ONE**, because it restores something
    /// that was never true.*
    private func persistScenePlace() {
        var handle: [String: Any] = [:]
        scene.snapshot(into: &handle)
        // *** THE FAIL-CLOSED RULE STANDS: A HALF-WRITTEN PLACE IS WORSE THAN AN OLD ONE. *** *The store returneth
        // whether the write landed, and a record that cannot be encoded is NOT written -- so the previous place
        // remaineth rather than being replaced by one that was never true. The return value is deliberately unused
        // here because there is no useful recovery: the old place is already the correct fallback.*
        placeStore.write(handle)
    }

    /// *** GS-ARCHIVE-005 step 1 (round 536): THE PATH FOLLOWETH THE SCENE. ***
    ///
    /// A restoration placeth the SCENE in a document while the STACK's path standeth empty (the process is new), so
    /// the path must be PUT BACK; and a return to the list must CLEAR it, or the stack would stand ahead of the
    /// scene and Back would land the reader in a document the scene no longer carrieth. THE GUARD (`pathSyncTarget`)
    /// telleth a no-op from a change, so this never fighteth the user's own taps.
    private func syncPathWithScene() {
        guard scene.openedDocumentId != pathSyncTarget else { return }
        pathSyncTarget = scene.openedDocumentId
        guard let id = scene.openedDocumentId else {
            path.removeAll()
            return
        }
        guard path.last?.id != id else { return }
        // THE DOCUMENT'S OWN TITLE IS WHAT THE SCENE RESTORED; `ArchiveDocument`'s provenance fields are DERIVED BY
        // THE DESTINATION from the library (`sourceMetadata(documentId:)`), which is round 524's law and the reason
        // this reconstruction needeth no more than the identity and the title.
        path = [ArchiveDocument(id: id, title: scene.openedTitle ?? "", domain: "", isCritical: false)]
    }

    /// *** THE RENDERED FIELD MUST SHOW THE SUBMITTED QUERY, NOT ONLY THE MODEL. ***
    ///
    /// **MEASURED, HOSTED RUN `35903873741`: after opening a hit and pressing Back, the scene stood in `.search` with
    /// `searchedQuery` intact -- and the RENDERED search field was EMPTY, its value reading the placeholder
    /// `"Search every document"`.** *`ArchiveSceneModel.back()` restores the MODEL's query; `fieldText` is a separate
    /// `@State` that NOTHING restored, so wherever SwiftUI resets the search bar's own text across the push/pop the
    /// reader is shown an empty field over a populated model.*
    ///
    /// **THAT IS EXACTLY THE OBSERVABLE THE ARM'S DOCSTRING NAMES** -- *"A model can hold `searchedQuery` while the
    /// rendered surface shows it empty -- and THIS is the observable a model test cannot reach"* -- **and it is the loss
    /// the card's "Back returns to the submitted query" clause forbids.**
    ///
    /// *THE GUARDS MAKE THIS ADDITIVE: it fires ONLY in `.search` mode, ONLY when the field is EMPTY, and ONLY from a
    /// non-empty submitted query.* **It cannot overwrite what the reader is typing, and it cannot invent a query the
    /// scene never submitted.**
    private func restoreSubmittedQueryIntoField() {
        guard scene.mode == .search else { return }
        guard fieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let submitted = scene.searchedQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
              !submitted.isEmpty
        else { return }
        fieldText = submitted
    }

    /// *** GS-FINAL-006 (the independent audit, 2026-09-18): THE OTHER DIRECTION WAS NEVER WIRED, SO THE SCENE WAS
    /// NEVER TOLD. ***
    ///
    /// THE AUDIT'S MEASUREMENT, WHICH I REPRODUCED EXACTLY: *"iOS NavigationLink values update a local navigation
    /// stack without calling the scene open operations whose identities are saved. ... Parallel navigation owners on
    /// iOS."* A grep of the whole App source set for `scene.open(` returned **NOTHING** -- so:
    ///
    ///   * `NavigationLink(value:)` pushed onto `path`;
    ///   * `syncPathWithScene()` drove `path` FROM `scene`;
    ///   * **AND NOTHING DROVE `scene` FROM `path`.**
    ///
    /// TWO OWNERS FOR ONE FACT, and the consequences were real on both sides of that gap:
    ///   * `scene.openedDocumentId` stayed NIL while a document was on screen, so `persistScenePlace()` wrote a place
    ///     with no document -- **the restoration charged in GS-ARCHIVE-005 step 4 had nothing to restore**;
    ///   * `scene.mode` stayed whatever it was, so the toolbar and title rendered the OLD mode's controls over the
    ///     new screen;
    ///   * and the reader's own `noteScroll`/anchor road ran against a scene that did not know where it was.
    ///
    /// THE REMEDY IS THE AUDIT'S OWN: *"Choose one iOS route authority. Replace value-only navigation with actions
    /// that open through ArchiveSceneModel."* THE SCENE IS THE AUTHORITY FOR NAVIGATION, and the path is its
    /// REFLECTION rather than a rival. The list and the hits therefore call `open(document:)` -- the scene's own
    /// checked road, which sets `openedDocumentId`, `openedTitle`, the return scene, and the mode -- and the `onChange`
    /// below then brings the path into line.
    private func openFromPath(_ document: ArchiveDocument) {
        guard scene.openedDocumentId != document.id else { return }
        Task { await scene.open(document: document) }
    }

    /// A record that will not deserialise is **NO RECORD, not a crash**: a stale or corrupt store must leave the
    /// reader at a first browse rather than refuse to open the Archive.
    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch scene.phase {
                case .loading:
                    ProgressView("Opening Archive…")
                case .unavailable(let reason, _):
                    // the typed verdict speaketh; the banner carrieth no SQL.
                    // The retry button appeareth only where the road may mend.
                    ArchiveNotice(title: "Archive unavailable", detail: reason,
                                  retry: scene.canRetry ? { retry &+= 1 } : nil)
                case .noResults:
                    ArchiveNotice(title: "No matches",
                                  detail: "Try a different word or clear the search to browse all documents.")
                case .ready:
                    if scene.mode == .search {
                        searchHits
                    } else {
                        documentList
                    }
                }
            }
            .navigationTitle(scene.openedTitle ?? (scene.mode == .search ? scene.searchedQuery ?? "Archive" : "Archive"))
            .toolbar {
                if scene.mode != .documents {
                    Button(scene.mode == .document ? "Back" : "Documents") { scene.back() }
                        // GS-FINAL-006: an identifier so an EXECUTED app test can ADDRESS the control proving Back
                        // leaves the document, rather than inferring it from a label that may be localized.
                        .accessibilityIdentifier("archive.back")
                }
                if scene.mode == .search || scene.mode == .document {
                    Button("All documents") { scene.backToDocuments() }
                }
            }
            .searchable(text: $fieldText, prompt: "Search every document")
            .onSubmit(of: .search) {
                submittedQuery = fieldText.trimmingCharacters(in: .whitespacesAndNewlines)
                retry &+= 1
            }
            .onChange(of: fieldText) { value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    submittedQuery = ""
                }
            }
            .task(id: SceneID(submitted: submittedQuery, retry: retry)) {
                // *** GS-ARCHIVE-005 STEP 4: **RESTORATION COMETH FIRST**, OR THE FIRST BROWSE OVERWRITETH THE PLACE.
                // The card's clause is an ORDER -- "invoke the actual restore path BEFORE the first browse overwrites
                // it" -- AND THE ORDER IS THE WHOLE OF IT: a restoration run after `loadDocuments()` would replace a
                // restored document with the browse's own empty query, which is exactly the loss the finding chargeth.
                if !restoredOnce {
                    restoredOnce = true
                    if let handle = placeStore.read() {
                        await scene.restore(from: handle)
                        return
                    }
                }
                if submittedQuery.isEmpty {
                    await scene.loadDocuments()
                } else {
                    scene.onQueryChanged(submittedQuery)
                    await scene.search()
                }
            }
            // *** GS-ARCHIVE-005 step 1 (round 536): AND THE PATH IS **DRIVEN**, NOT MERELY BOUND. *** A path
            // nobody readeth is a DECLARED DOOR, and this one carrieth the review's own law: *'a declaration is not
            // a capability -- THE ACCESS MODIFIER IS PART OF THE CLAIM.'* SO WHEN THE SCENE STANDS IN A DOCUMENT
            // THE PATH DOTH NOT CARRY -- and that is EXACTLY what a restoration giveth: an `openedDocumentId`
            // restored from the durable record, with the stack's path empty because the process is new -- THE PATH
            // IS PUT BACK, SO THE READER RETURNETH TO ITS DOCUMENT RATHER THAN TO A BARE LIST.
            //
            // AND IT IS GUARDED AGAINST BOTH WAYS IT COULD GO WRONG: the target is remembered, so a no-op is
            // TOLD APART from a change (else this would fight every tap the user made), and the path is CLEARED
            // when the scene returneth to the list (else Back would leave the stack ahead of the scene).
            // *AND THE RENDERED FIELD IS BROUGHT INTO LINE WITH THE SCENE AT THE SAME MOMENT*, so a Back that the
            // model answered correctly is not nonetheless rendered as an empty search bar.
            .onChange(of: scene.openedDocumentId) { _ in
                syncPathWithScene()
                restoreSubmittedQueryIntoField()
                // *** GS-ARCHIVE-005 / GS-FINAL-006: THE PLACE IS WRITTEN **HERE**, AT THE TRANSITION THAT MAKETH IT TRUE. ***
                //
                // **MEASURED, HOSTED: `testGSA005DocumentReopensAfterCleanProcessDeath` IS DETERMINISTICALLY RED, `rows=2
                // passages=0` ON RELAUNCH.** *And the diagnosis was already written in the arm's own message, which is worth
                // repeating because it was correct:* ***"a hard `terminate()` comes back to the document list, because
                // `onChange(of: scenePhase)` never runs to write the record."***
                //
                // **THE DESIGN DEFECT, NAMED PLAINLY: PERSISTENCE DEPENDED ON A LIFECYCLE CALLBACK THAT A CLEAN PROCESS
                // TERMINATION CAN BYPASS.** *`scenePhase` going non-`.active` and `onDisappear` are OPPORTUNISTIC -- the
                // system fireth them when it chooseth to, and a `terminate()` taketh the process away first.* **A PLACE THAT
                // IS ONLY WRITTEN WHEN THE SYSTEM HAPPENETH TO SUSPEND US IS NOT A DURABLE PLACE; IT IS A HOPE.**
                //
                // *** SO THE WRITE MOVETH TO THE MOMENT THE DOCUMENT COMES TO STAND -- A TRANSITION THE APP ITSELF
                // GUARANTEES, BECAUSE IT IS THE APP'S OWN STATE CHANGE.*** *`openedDocumentId` changing IS that moment:
                // whenever a reader entereth a document, the place becometh true and is written.*
                //
                // *AND THE ANCHOR COMETH WITH IT, which the arm's own clause requireth (step 5: "reach/record a stable
                // passage"): the reader noteth scroll positions through `noteScroll`, so the write must follow those as
                // well or a restored document would land at the top instead of the passage the reader left.* **BOTH HOOKS
                // ARE IDEMPOTENT WRITES OF THE SAME SNAPSHOT**, so overlapping them costeth one small plist and cannot
                // corrupt the record -- *`persistScenePlace` already refuseth a half-written place, keeping the previous
                // one, precisely so that a bad write can never restore something that was never true.*
                persistScenePlace()
            }
            // *** AND THE SCROLL ANCHOR IS WRITTEN AT ITS OWN TRANSITION, for the same reason. ***
            // *`scene.scrollAnchor` is what step 5 of the card's journey nameth ("reach/record a stable passage"), and a
            // place persisted without it restores the document but not the PLACE WITHIN IT.*
            .onChange(of: scene.scrollAnchor) { _ in
                persistScenePlace()
            }
            // *** GS-FINAL-006: AND THE PATH TELLETH THE SCENE WHEN *IT* MOVES. ***
            // A swipe-back pop removes the last path element WITHOUT `scene.back()` ever running, so the scene would
            // keep `openedDocumentId` set while the reader is back at the list -- the divergence in the other
            // direction, and the one the toolbar's own Back button could never fix. An empty path now returns the
            // scene to its list, and a non-empty one re-opens the document the stack now shows.
            .onChange(of: path) { newPath in
                guard let shown = newPath.last else {
                    if scene.mode == .document { scene.back() }
                    return
                }
                if scene.openedDocumentId != shown.id { openFromPath(shown) }
            }
            .onAppear {
                syncPathWithScene()
                restoreSubmittedQueryIntoField()
            }
            .onChange(of: scenePhase) { phase in
                // the standard iOS moment: the place is written before the app may be suspended and killed
                if phase != .active { persistScenePlace() }
            }
            .onDisappear {
                persistScenePlace()
                scene.dismiss()   // dismissal striketh out the in-flight petition
            }
            .navigationDestination(for: ArchiveDocument.self) { document in
                ArchiveDocumentReader(document: document, library: library, scene: scene)
            }
        }
    }

    private var documentList: some View {
        List(scene.documents) { document in
            // *** GS-FINAL-006: THE SELECTION GOETH THROUGH THE SCENE, NOT PAST IT. ***
            // A `NavigationLink(value:)` alone would push the path while leaving `scene.openedDocumentId` nil -- the
            // parallel-owner defect verbatim. `simultaneousGesture` lets the link's own push stand AND tells the scene,
            // so the two owners are updated from ONE tap and cannot disagree about which document is open.
            NavigationLink(value: document) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(document.title).font(.headline)
                    Text(document.domain).font(.subheadline).foregroundStyle(.secondary)
                    // T50 (s17): source/revision display -- the provenance the
                    // frozen columns carry, the projection hereby carried forth.
                    if !document.sourceId.isEmpty || !document.revision.isEmpty {
                        Text("source " + document.sourceId + " · revision " + document.revision)
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel("source " + document.sourceId + ", revision " + document.revision)
                    }
                    if document.isCritical {
                        Text("Critical procedure").font(.caption.weight(.semibold))
                            .foregroundStyle(GodstoneTheme.danger)
                    }
                }
                .frame(minHeight: GodstoneTheme.minimumTapTarget, alignment: .leading)
            }
            // GS-FINAL-006: addressable BY DOCUMENT, so an executed app test opens a NAMED document. IT SITS ON THE
            // LINK, NOT INSIDE ITS LABEL: placing it on the label's VStack pushed an already-heavy SwiftUI
            // expression past the type-checker's budget and the app stopped compiling ("unable to type-check this
            // expression in reasonable time"). A modifier on the link is also the more honest place for it -- the
            // identity belongs to the CONTROL, not to the text it draws.
            .accessibilityIdentifier("archive.document." + String(document.id))
            // THE SCENE IS TOLD IN THE SAME TAP THAT PUSHES THE PATH (GS-FINAL-006).
            .simultaneousGesture(TapGesture().onEnded { openFromPath(document) })
        }
        .listStyle(.plain)
    }

    private var searchHits: some View {
        List {
            Text("\(scene.passages.count) passage\(scene.passages.count == 1 ? "" : "s")"
                + (scene.passages.count == 40 ? " · showing the first 40" : ""))
                .font(.footnote).foregroundStyle(.secondary)
                // *** A POSITIVE WITNESS THAT THE SEARCH SURFACE IS RENDERED. ***
                // *MEASURED, HOSTED RUN `35914747948`: the arm that verifiest "Back returneth to the submitted query"
                // had **NO OBSERVABLE THAT THE SEARCH EVER COMPLETED** -- it waited on `archive.document.*`, an
                // identifier that the BROWSE list carrieth too (see `documentList`), so a search that never submitted
                // satisfied the wait and the arm proceeded to open a row that was there all along.* **A WITNESS THAT
                // CANNOT DISTINGUISH "AFTER" FROM "BEFORE" CANNOT WITNESS A TRANSITION.** *This summary exists ONLY
                // in `searchHits`, so its presence IS the transition.*
                .accessibilityIdentifier("archive.search.results")
            ForEach(scene.passages) { passage in
                NavigationLink(value: ArchiveDocument(id: passage.documentId,
                    title: passage.documentTitle, domain: passage.domain, isCritical: false)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(passage.documentTitle).font(.headline)
                        if !passage.section.isEmpty {
                            Text(passage.section).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(passage.text).font(.body).lineLimit(4)
                        Text("Read full document").font(.footnote.weight(.semibold))
                            .foregroundStyle(.tint)
                    }
                    .padding(.vertical, 8)
                }
                // *** AND THE SEARCH ROAD MUST BE ADDRESSABLE -- IN ITS OWN NAMESPACE. ***
                // *A search result and a list row are the SAME KIND of control to a user and to assistive
                // technology, so an identifier that exists on one and not the other is an inconsistency.*
                //
                // **BUT A SHARED IDENTIFIER WAS THE WORSE DEFECT: THE ROW BELOW WAS KEYED
                // `archive.document.<documentId>` -- EXACTLY THE BROWSE LIST'S NAMESPACE -- SO A WITNESS COULD NOT
                // TELL "THE SEARCH RENDERED THIS" FROM "THE BROWSE LIST WAS STILL ON SCREEN."** *MEASURED, HOSTED RUN
                // `35914747948`: the arm waited for `archive.document.*`, matched a row that predated the search, and
                // tapped it -- **so the journey under test never began, while the arm reported a failure about the
                // query's fate.***
                //
                // *** AND IT IS KEYED TO THE PASSAGE, NOT THE DOCUMENT: MANY HITS BELONG TO ONE DOCUMENT, so a
                // document-keyed identifier cannot name "a hit that is not the first" -- which is precisely what the
                // sibling arm must address.*** *`passage.id` is the same stable identity the reader's scroll proxy
                // already useth.*
                .accessibilityIdentifier("archive.search.hit." + String(passage.id))
                // AND THE SEARCH ROAD GETTETH THE SAME TREATMENT, so a hit and a list row cannot disagree about
                // whether the scene was told (GS-FINAL-006).
                .simultaneousGesture(TapGesture().onEnded {
                    openFromPath(ArchiveDocument(id: passage.documentId,
                        title: passage.documentTitle, domain: passage.domain, isCritical: false))
                })
            }
        }
        .listStyle(.plain)
    }
}

private struct ArchiveDocumentReader: View {
    let document: ArchiveDocument
    /// *** GS-ARCHIVE-005 (round 524): THE DESTINATION PUBLISHETH ITS OWN CHECKED PROVENANCE, AND IT IS THE
    /// LIBRARY THAT ANSWERETH -- NOT THE SCENE. *** The library was ALREADY handed to this view and DISCARDED (it
    /// was used onely to build the reader model), while the provenance line was sourced from `scene.openedSource`,
    /// which THE ROUTE NEVER SETTETH. `ArchiveLibrary` conformeth to `ArchiveReading` and carrieth
    /// `nonisolated public func sourceMetadata(documentId:)`, so the metadata OF THE DOCUMENT ACTUALLY ON SCREEN is
    /// one synchronous call away -- and it belongeth to the document this view was constructed FOR, so a NEIGHBOUR'S
    /// provenance cannot be displayed by construction ("never metadata from a previous selection").
    private let library: ArchiveLibrary
    @ObservedObject private var scene: ArchiveSceneModel
    @StateObject private var model: ArchiveReaderModel
    @State private var retry = 0
    // The WIP's Dynamic Type change, reviewed and kept: the reading size
    // scaleth with the body category, never a fixed point size.
    @ScaledMetric(relativeTo: .body) private var readingSize = GodstoneTheme.bodyTextSize

    init(document: ArchiveDocument, library: ArchiveLibrary, scene: ArchiveSceneModel) {
        self.document = document
        self.library = library
        _scene = ObservedObject(wrappedValue: scene)
        _model = StateObject(wrappedValue: ArchiveReaderModel(library: library))
    }

    @ViewBuilder private func readingView(found: [ArchivePassage]) -> some View {
        // GS-ARCHIVE-004: the reader carrieth a SCROLLING CONTAINER, and the proxy is USED
        // rather than discarded: a document longer than a screen must be readable, and a
        // returning reader is placed at the passage the scene remembered -- or at the
        // beginning when that passage no longer existeth in the selected archive.
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 24) {
                    Text(document.title).font(.title.bold()).accessibilityAddTraits(.isHeader)
                    provenanceLine()
                    ForEach(found) { passage in
                        passageBlock(passage: passage)
                            .id(passage.id)          // a STABLE passage identity for the proxy
                    }
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .task(id: found.map(\.id)) {
                guard let target = ArchiveReadingAnchor.target(
                    passageIds: found.map(\.id),
                    saved: scene.scrollAnchor?.passageId) else { return }
                // *** GS-ARCHIVE-005 STEP 6 (round 537): **THE VISIBLE PASSAGE IS RECORDED RIGHT HERE**, WHERE THE
                // SCROLL ITSELF ALREADY COMPUTED IT. *** MEASURED BEFORE THIS EDIT: the app called
                // `noteScroll(documentId:)` **without a `passageId`**, so `scrollAnchor?.passageId` was ALWAYS NIL
                // and a returning reader was put at the TOP of the document -- the card's own charge: *'the current
                // `noteScroll(documentId:)` records no passage position'*.
                //
                // *** AND THE FIRST ATTEMPT OF THIS REPAIR WAS WRONG, WHICH IS WHY IT IS RECORDED HERE: I PUT THE
                // CALL ON THE READER'S `body`, WHERE `found` IS **NOT IN SCOPE**, AND THE SHIPPING BUILD NAMED IT --
                // `cannot find 'found' in scope`. THE SWIFTPM LANE NEVER COMPILES THIS FILE, SO **ONELY THE SHIPPING
                // BUILD COULD HAVE CAUGHT IT**, and it did. THE LESSON IS THIS PROGRAMME'S OWN: PUT THE CALL WHERE
                // THE MATERIAL ALREADY IS, NOT WHERE IT READS WELL. ***
                scene.noteScroll(passageId: target)
                proxy.scrollTo(target, anchor: .top)
            }
        }
        // *** GS-FINAL-006 / GS-ARCHIVE-005: THE READER CARRIES ITS OWN RENDERED WAY BACK. ***
        //
        // *MEASURED WITH THE EXECUTED APP TEST, AND IT FOUND A REAL GAP: the toolbar that declares
        // `archive.back` sits on the ROOT view, so a PUSHED reader never renders it -- the ONLY back
        // control on screen was SwiftUI's system `BackButton`, which four separate tap strategies
        // (plain tap, coordinate tap, `element(boundBy: 0)`, and after dismissing every presentation)
        // all failed to operate. **TWO taps left the reader still on the stack, `navid` still the
        // document title.**
        //
        // SO THE AFFORDANCE THE CARD NAMES DID NOT EXIST ON THIS ROAD: "Back returns to the submitted
        // query" is not performable if the only way out is chrome the app does not own. THIS BUTTON IS
        // IN THE READER'S OWN CONTENT, carries the identifier the witness addresses, and calls the SAME
        // `scene.back()` the toolbar's control does -- **one scene owner, two rendered affordances, no
        // second navigator.***
        .safeAreaInset(edge: .top) {
            HStack {
                Button { scene.back() } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .accessibilityIdentifier("archive.back")
                .accessibilityHint("Returns to the search results or the document list you came from")
                .padding(.vertical, 8)
                Spacer()
            }
            .padding(.horizontal)
            .background(.bar)
        }
    }

    @ViewBuilder private func provenanceLine() -> some View {
        // *** GS-ARCHIVE-005 (round 524): THE LINE IS SOURCED FROM THE DOCUMENT THIS VIEW WAS CONSTRUCTED FOR. ***
        // IT USED TO BE SOURCED FROM `scene.openedSource`, GUARDED BY `scene.openedDocumentId == document.id` -- and
        // MEASURED: `.navigationDestination(for: ArchiveDocument.self)` calleth `scene.open(` NOWHERE, so that guard
        // was NEVER SATISFIED AND THE REQUIRED PROVENANCE LINE RENDERED NOTHING. A guard that cannot be satisfied is
        // not a provenance line; it is an absence with a condition in front of it.
        if let source = library.sourceMetadata(documentId: document.id) {
            let tale: String = "source " + source.sourceId + " · revision " + source.revision
                + " · licence " + source.licence
            Text(tale).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func passageBlock(passage: ArchivePassage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !passage.section.isEmpty {
                Text(passage.section).font(.headline).accessibilityAddTraits(.isHeader)
            }
            Text(passage.text)
                .font(.system(size: readingSize))
                .textSelection(.enabled)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // *** GS-FINAL-006: A PASSAGE MUST BE ADDRESSABLE, OR "SCROLL TO A STABLE PASSAGE AND RETURN TO IT"
        // CANNOT BE WITNESSED -- the card nameth that journey exactly, and an unaddressable block leaves an
        // executed app test unable to say WHICH passage it reached. ***
        .accessibilityIdentifier("archive.passage." + String(passage.id))
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView("Opening document…")
            case .failed(let error):
                // the spoken tale is sanitised; the engine's words stay in the log
                ArchiveNotice(title: "Document unavailable",
                              detail: ArchiveUserMessage.spoken(for: error),
                              retry: { retry &+= 1 })
            case .loaded(let page):
                switch page {
                case .passages(let found) where !found.isEmpty:
                    readingView(found: found)
                default:
                    ArchiveNotice(title: "Document is empty",
                                  detail: "No readable passages were found in this document.")
                }
            case .loaded(.documents):
                EmptyView()
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: retry) { await model.load(.document(document.id)) }
        .onDisappear { model.cancelInFlight() }   // dismissal striketh out the in-flight petition
    }
}

private struct ArchiveNotice: View {
    let title: String
    let detail: String
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical").font(.largeTitle).accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let retry {
                Button("Try again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: GodstoneTheme.minimumTapTarget)
            }
        }
        .padding(32)
    }
}
