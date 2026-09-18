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
    // THE VEHICLE IS THE ONE THE CARD NAMETH (`SceneStorage`), and the record is the model's own serialisable place:
    // W16 (a behavioural arm in GodstoneCoreTests) MEASURABLY PROVETH that the handle surviveth a real
    // `PropertyListSerialization` round-trip INTO A FRESH SCENE with its identity and metadata intact -- so this
    // store is backed by a measured semantic and not by a hope about `[String: Any]`.
    // --------------------------------------------------------------------------------------
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("godstone.archive.scene") private var sceneRecord: Data = Data()

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

    /// *** GS-ARCHIVE-005 STEP 4: THE PLACE, WRITTEN INTO THE SCENE-SCOPED STORE. *** `snapshot(into:)` is the
    /// model's own serialisable place; the store is `SceneStorage`, which the card nameth by name. A record that
    /// cannot be written is NOT written and the previous one standeth: A HALF-WRITTEN PLACE IS WORSE THAN AN OLD ONE,
    /// because it restores something that was never true.
    private func persistScenePlace() {
        var handle: [String: Any] = [:]
        scene.snapshot(into: &handle)
        if let data = try? PropertyListSerialization.data(fromPropertyList: handle, format: .binary, options: 0) {
            sceneRecord = data
        }
    }

    /// *** GS-ARCHIVE-005 step 1 (round 536): THE PATH FOLLOWETH THE SCENE, IN BOTH DIRECTIONS. ***
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

    /// A record that will not deserialise is **NO RECORD, not a crash**: a stale or corrupt store must leave the
    /// reader at a first browse rather than refuse to open the Archive.
    private static func decodeSceneRecord(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return nil }
        return plist as? [String: Any]
    }

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
                    if let handle = Self.decodeSceneRecord(sceneRecord) {
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
            .onChange(of: scene.openedDocumentId) { _ in syncPathWithScene() }
            .onAppear { syncPathWithScene() }
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
        }
        .listStyle(.plain)
    }

    private var searchHits: some View {
        List {
            Text("\(scene.passages.count) passage\(scene.passages.count == 1 ? "" : "s")"
                + (scene.passages.count == 40 ? " · showing the first 40" : ""))
                .font(.footnote).foregroundStyle(.secondary)
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
                proxy.scrollTo(target, anchor: .top)
            }
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
        .onAppear { scene.noteScroll(documentId: document.id) }
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
