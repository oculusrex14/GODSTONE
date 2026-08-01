import SwiftUI
import GodstoneCore

/// The always-available browser over the immutable on-device Archive.
struct ArchiveView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var query = ""
    @State private var documents: [ArchiveDocument] = []
    @State private var passages: [ArchivePassage] = []
    @State private var openedTitle: String?

    var body: some View {
        NavigationStack {
            Group {
                if !container.archive.isAvailable {
                    emptyState(
                        icon: "externaldrive.badge.exclamationmark",
                        title: "Archive unavailable",
                        detail: "The tier database is missing or could not be opened read-only."
                    )
                } else if documents.isEmpty && passages.isEmpty {
                    emptyState(
                        icon: "magnifyingglass",
                        title: "No matches",
                        detail: "Try a different word or clear the search to browse every document."
                    )
                } else {
                    List {
                        ForEach(documents) { document in
                            Button { open(document) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(document.title).font(.headline).foregroundStyle(.primary)
                                    Text(document.domain).font(.footnote).foregroundStyle(.secondary)
                                    if document.isCritical {
                                        Text("Critical procedure").font(.caption).foregroundStyle(GodstoneTheme.danger)
                                    }
                                }
                                .frame(minHeight: GodstoneTheme.minimumTapTarget, alignment: .leading)
                            }
                        }
                        ForEach(passages) { passage in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(passage.documentTitle).font(.headline)
                                if !passage.section.isEmpty {
                                    Text(passage.section).font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text(passage.text)
                                    .font(.system(size: GodstoneTheme.bodyTextSize))
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(openedTitle ?? "Archive")
            .toolbar {
                if openedTitle != nil || !passages.isEmpty {
                    Button("All documents") { loadDocuments() }
                }
            }
            .searchable(text: $query, prompt: "Search every document")
            .onSubmit(of: .search) { search() }
            .onChange(of: query) { value in
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    loadDocuments()
                }
            }
            .onAppear { if documents.isEmpty && passages.isEmpty { loadDocuments() } }
        }
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private func loadDocuments() {
        query = ""
        openedTitle = nil
        passages = []
        documents = container.archive.listDocuments()
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { loadDocuments(); return }
        openedTitle = nil
        documents = []
        passages = container.archive.search(q)
    }

    private func open(_ document: ArchiveDocument) {
        documents = []
        openedTitle = document.title
        passages = container.archive.passages(documentId: document.id)
    }
}
