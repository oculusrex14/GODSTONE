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

    private struct SceneID: Equatable {
        let submitted: String
        let retry: Int
    }

    init(scene: ArchiveSceneModel, library: ArchiveLibrary) {
        _scene = ObservedObject(wrappedValue: scene)
        self.library = library
    }

    var body: some View {
        NavigationStack {
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
                if submittedQuery.isEmpty {
                    await scene.loadDocuments()
                } else {
                    scene.onQueryChanged(submittedQuery)
                    await scene.search()
                }
            }
            .onDisappear { scene.dismiss() }   // dismissal striketh out the in-flight petition
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
    @ObservedObject private var scene: ArchiveSceneModel
    @StateObject private var model: ArchiveReaderModel
    @State private var retry = 0
    // The WIP's Dynamic Type change, reviewed and kept: the reading size
    // scaleth with the body category, never a fixed point size.
    @ScaledMetric(relativeTo: .body) private var readingSize = GodstoneTheme.bodyTextSize

    init(document: ArchiveDocument, library: ArchiveLibrary, scene: ArchiveSceneModel) {
        self.document = document
        _scene = ObservedObject(wrappedValue: scene)
        _model = StateObject(wrappedValue: ArchiveReaderModel(library: library))
    }

    @ViewBuilder private func readingView(found: [ArchivePassage]) -> some View {
        ScrollViewReader { _ in
            LazyVStack(alignment: .leading, spacing: 24) {
                Text(document.title).font(.title.bold()).accessibilityAddTraits(.isHeader)
                provenanceLine()
                ForEach(found) { passage in
                    passageBlock(passage: passage)
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func provenanceLine() -> some View {
        if let source = scene.openedSource, scene.openedDocumentId == document.id {
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
