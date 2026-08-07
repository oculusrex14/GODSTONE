import SwiftUI
import GodstoneLLM

struct OracleView: View {
    @EnvironmentObject private var oracle: OracleViewModel

    var body: some View {
        VStack(spacing: 20) {
            TextField("Ask the Archive", text: $oracle.question, axis: .vertical)
                .font(.body)
                .lineLimit(1...6)
                .padding(14)
                .background(.secondary.opacity(0.12))
                .cornerRadius(12)
                .accessibilityLabel("Question for the Archive")
                .padding(.horizontal, 20)
                .padding(.top, 24)

            Button("Ask") { oracle.ask() }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 56)
                .disabled(isBusy || oracle.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 20)
                .accessibilityHint("Searches reviewed Archive sources and validates the complete answer before showing it")

            stateView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isBusy: Bool {
        switch oracle.state {
        case .retrieving, .generating: true
        default: false
        }
    }

    @ViewBuilder private var stateView: some View {
        switch oracle.state {
        case .idle:
            ContentUnavailableView("Ask the Archive", systemImage: "books.vertical",
                description: Text("Unsupported questions are refused rather than guessed."))
        case .retrieving:
            progress("Searching the Archive…")
        case .generating:
            progress("Generating and verifying privately…")
        case .answered(let text, let citations):
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(text).textSelection(.enabled)
                    if !citations.isEmpty {
                        Text("Sources").font(.headline)
                        ForEach(citations) { citation in
                            VStack(alignment: .leading) {
                                Text(citation.documentTitle).font(.headline)
                                Text(citation.section).font(.footnote)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        case .refused(let nearMisses):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Not verified by the Archive", systemImage: "hand.raised.fill")
                        .font(.headline)
                    Text("No generated answer was shown. Browse the related sources below.")
                    ForEach(nearMisses) { citation in
                        Text("\(citation.documentTitle) — \(citation.section)")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        case .degraded(let reason):
            ContentUnavailableView("Generation unavailable", systemImage: "exclamationmark.triangle",
                description: Text(reason))
        }
    }

    private func progress(_ label: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(label).font(.headline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
