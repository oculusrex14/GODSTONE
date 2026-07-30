// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import SwiftUI

/// The Archive tab. The full-text and vector indexes live in a per-tier SQLite
/// database (see ArchiveRepository in GodstoneCore); this screen is the
/// human-facing browser over them.
///
/// Constraint C7 drives every layout choice here: large tap targets, generous
/// body text, and a flat list with no nested disclosure triangles. Someone
/// scrolling for a tourniquet procedure in the dark does not need a hierarchy
/// to navigate first.
struct ArchiveView: View {

    // TODO: wire ArchiveRepository via an injected model. AppContainer owns an
    // ArchiveRepository, but it is not currently published as an
    // EnvironmentObject. Once it is (or an ArchiveViewModel wraps it), replace
    // the placeholder rows below with the real domain/document tree.
    @State private var searchText: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if filteredDomains.isEmpty {
                    emptyState
                } else {
                    List(filteredDomains, id: \.self) { domain in
                        domainRow(domain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Archive")
            .searchable(text: $searchText, prompt: "Search the archive")
        }
        .background(GodstoneTheme.stone)
    }

    /// Placeholder domains. The real domains come from ArchiveRepository; these
    /// exist so the screen renders and the search field is testable before the
    /// repository is wired in.
    private let placeholderDomains: [String] = [
        "Trauma & Bleeding",
        "Medications & Dosing",
        "Paediatrics",
        "Environmental",
        "Navigation & Signals"
    ]

    private var filteredDomains: [String] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return placeholderDomains }
        return placeholderDomains.filter { $0.lowercased().contains(q) }
    }

    private func domainRow(_ domain: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 22))
                .foregroundStyle(GodstoneTheme.ember)
            Text(domain)
                .font(.system(size: GodstoneTheme.bodyTextSize, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: GodstoneTheme.minimumTapTarget)
        .padding(.vertical, 6)
        // TODO: navigationDestination to a document list once ArchiveRepository
        // is injected. Until then the chevron is decorative.
        .accessibilityElement(children: .combine)
        .accessibilityHint("Browse documents in \(domain).")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No matches in the Archive")
                .font(.system(size: GodstoneTheme.bodyTextSize, weight: .semibold))
                .foregroundStyle(.white)
            Text("The Archive is indexed locally. Try a different word, or browse the full list by clearing the search.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
