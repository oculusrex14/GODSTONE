// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import SwiftUI
import GodstoneLLM

/// The Ask tab. The Oracle only ever answers from the Archive; when the
/// Archive is silent it says so (refused), and when the model cannot load it
/// degrades gracefully (degraded). This view renders every state in
/// OracleViewModel.State honestly -- no spinning indeterminate that resolves
/// into a fabricated answer.
///
/// Styling mirrors SosView: dark stone field, heavy rounded type, ember as the
/// action colour. Constraint C7: large text and a 56pt-minimum Ask button.
struct OracleView: View {

    @EnvironmentObject private var oracle: OracleViewModel

    var body: some View {
        VStack(spacing: 20) {

            questionField
                .padding(.horizontal, 20)
                .padding(.top, 24)

            askButton

            stateView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GodstoneTheme.stone)
    }

    // MARK: - Input

    private var questionField: some View {
        TextField("Ask the Archive", text: $oracle.question, axis: .vertical)
            .font(.system(size: GodstoneTheme.bodyTextSize))
            .foregroundStyle(.white)
            .lineLimit(1...4)
            .padding(14)
            .background(Color.white.opacity(0.06))
            .cornerRadius(12)
            .tint(GodstoneTheme.ember)
            .accessibilityLabel("Question for the Archive")
    }

    private var askButton: some View {
        Button {
            oracle.ask()
        } label: {
            Text("Ask")
                .font(.system(size: GodstoneTheme.bodyTextSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: GodstoneTheme.minimumTapTarget)
                .background(isBusy ? GodstoneTheme.ember.opacity(0.4)
                                   : GodstoneTheme.ember)
                .cornerRadius(12)
        }
        .disabled(isBusy || oracle.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .padding(.horizontal, 20)
        .accessibilityHint("Search the Archive and answer from it.")
    }

    /// Retrieving and generating are both non-interruptible from the user's
    /// perspective: the Ask button is disabled so a second tap cannot spawn a
    /// racing Task.
    private var isBusy: Bool {
        switch oracle.state {
        case .retrieving, .generating: return true
        default: return false
        }
    }

    // MARK: - State

    @ViewBuilder
    private var stateView: some View {
        switch oracle.state {
        case .idle:
            idlePrompt
        case .retrieving:
            progressView("Searching the Archive\u{2026}")
        case .generating(let partial):
            streamingView(partial)
        case .answered(let text, let citations):
            answeredView(text: text, citations: citations)
        case .refused(let nearMisses):
            refusedView(nearMisses: nearMisses)
        case .degraded(let reason):
            degradedView(reason: reason)
        }
    }

    private var idlePrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(GodstoneTheme.ember.opacity(0.8))
            Text("Ask a clinical or practical question.")
                .font(.system(size: GodstoneTheme.bodyTextSize, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Answers come only from the documents on this phone. If the Archive has nothing relevant, the Oracle will say so rather than guess.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
    }

    private func progressView(_ label: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(GodstoneTheme.ember)
                .scaleEffect(1.4)
            Text(label)
                .font(.system(size: GodstoneTheme.bodyTextSize, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private func streamingView(_ partial: String) -> some View {
        ScrollView {
            Text(partial.isEmpty ? "\u{2026}" : partial)
                .font(.system(size: GodstoneTheme.bodyTextSize))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func answeredView(text: String, citations: [Citation]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(text)
                    .font(.system(size: GodstoneTheme.bodyTextSize))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)

                if !citations.isEmpty {
                    Text("Sources")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .foregroundStyle(GodstoneTheme.ember)
                    VStack(spacing: 10) {
                        ForEach(citations) { citation in
                            citationCard(citation)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func citationCard(_ citation: Citation) -> some View {
        // TODO: tapping a source should open the document at its section in the
        // Archive tab. Deferred until ArchiveView is wired to ArchiveRepository.
        VStack(alignment: .leading, spacing: 4) {
            Text(citation.documentTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Text(citation.section)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("relevance \(String(format: "%.0f%%", citation.score * 100))")
                .font(.caption2)
                .foregroundStyle(GodstoneTheme.ember)
        }
        .frame(maxWidth: .infinity, minHeight: GodstoneTheme.minimumTapTarget / 1.5,
               alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.06))
        .cornerRadius(10)
        .accessibilityElement(children: .combine)
    }

    private func refusedView(nearMisses: [Citation]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(GodstoneTheme.warning)
                    Text("Not in the Archive")
                        .font(.system(size: GodstoneTheme.bodyTextSize, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("The Oracle will not answer from memory. The closest documents it found are below, but they did not clear the confidence floor.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if !nearMisses.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(nearMisses) { citation in
                            citationCard(citation)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func degradedView(reason: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(GodstoneTheme.warning)
            Text("Generation unavailable")
                .font(.system(size: GodstoneTheme.bodyTextSize, weight: .bold))
                .foregroundStyle(.white)
            Text(reason)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
        }
    }
}
