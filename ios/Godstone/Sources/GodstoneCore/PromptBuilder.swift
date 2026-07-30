// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.
import Foundation

/// Assembles the grounded prompt.
///
/// The system rules are the single most safety-critical string in the product:
/// they are written to make refusal the default and invention impossible. The
/// model answers ONLY from the numbered CONTEXT passages; if the context does
/// not contain the answer it says so, in those exact words.
///
/// The context budget is enforced with the model's own tokenizer (via the
/// `countTokens` closure) rather than a length-based guess: the weakest chunks
/// are dropped from the tail until the prompt fits, always keeping at least the
/// strongest source -- an over-budget single source is still safer than an
/// empty context.
///
/// Mirrors `io.godstone.llm.rag.PromptBuilder` (Android); the system rules and
/// chat template are identical so both platforms render byte-equivalent prompts
/// for the same retrieval.
public final class PromptBuilder {

    public let contextTokens: Int
    public let reservedForAnswer: Int

    public init() {
        self.contextTokens = Tier.current.contextTokens
        self.reservedForAnswer = 512
    }

    public init(contextTokens: Int, reservedForAnswer: Int) {
        self.contextTokens = contextTokens
        self.reservedForAnswer = reservedForAnswer
    }

    private let systemRules = """
        You are Godstone, an offline survival reference. You are being used by \
        someone who may be injured, frightened, and without any other help.

        ABSOLUTE RULES:
        1. Answer ONLY from the numbered CONTEXT passages below. If the context \
        does not contain the answer, say exactly: "The archive does not cover \
        this." Do not guess. Do not use general knowledge.
        2. Cite every factual claim with the bracketed number of the passage it \
        came from, like [2].
        3. Give steps in the order they must be performed. Put any action that \
        prevents immediate death first.
        4. State dosages, ratios, times and temperatures exactly as written in \
        the context. Never round, convert or estimate them yourself.
        5. If the context contains a warning or contraindication, you MUST \
        include it. Never omit a safety warning to make an answer shorter.
        6. Be brief and concrete. Short sentences. No preamble, no reassurance, \
        no filler. The user does not have time.
        """

    /// Build the grounded prompt, dropping the weakest chunks from the tail
    /// until `countTokens(prompt) <= budget`. At least the strongest chunk is
    /// always kept.
    public func build(question: String,
                      chunks: [RetrievedChunk],
                      budget: Int,
                      countTokens: (String) async -> Int) async -> String {
        // Strongest first: the model sees the most relevant passage earliest,
        // and any trimming drops the weakest material from the tail.
        let ranked = chunks.sorted { $0.score > $1.score }

        // Greedy tail-trim: render the full set, measure, drop the lowest-scored
        // chunk, repeat until it fits or only the strongest remains. An
        // over-budget single source is still safer than an empty context.
        var kept = ranked
        while kept.count > 1 {
            let prompt = render(question: question, chunks: kept)
            if await countTokens(prompt) <= budget { return prompt }
            kept.removeLast()
        }
        return render(question: question, chunks: kept)
    }

    private func render(question: String, chunks: [RetrievedChunk]) -> String {
        var sb = String()
        sb.append("<|im_start|>system\n")
        sb.append(systemRules)
        sb.append("\n<|im_end|>\n")

        sb.append("<|im_start|>user\n")
        sb.append("CONTEXT:\n")
        for (i, c) in chunks.enumerated() {
            sb.append("[")
            sb.append(String(i + 1))
            sb.append("] (")
            sb.append(c.domain)
            sb.append(" — ")
            sb.append(c.documentTitle)
            sb.append(")\n")
            sb.append(c.text.trimmingCharacters(in: .whitespacesAndNewlines))
            sb.append("\n\n")
        }
        sb.append("QUESTION: ")
        sb.append(question.trimmingCharacters(in: .whitespacesAndNewlines))
        sb.append("\n<|im_end|>\n")
        sb.append("<|im_start|>assistant\n")
        return sb
    }

    /// Clinical questions get the conservative sampling profile. True when the
    /// question mentions dosages, ratios, concentrations, timing or
    /// temperatures -- the domains where an invented answer can kill.
    public func isClinical(_ question: String) -> Bool {
        let lower = question.lowercased()
        let keywords = ["dose", "dosage", "ratio", "mg", "ml", "mcg",
                        "timing", "minutes", "hours", "temperature",
                        "celsius", "fahrenheit", "boil", "concentration"]
        return keywords.contains(where: { lower.contains($0) })
    }
}