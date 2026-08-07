import Foundation

/// Fail-closed final validation for a complete, private Oracle draft.
public enum OracleAnswerValidator {
    public struct Result: Sendable {
        public let isValid: Bool
        public let citedIndices: [Int]
        public let reason: String?
        public let unsupported: [String]

        public static func accepted(_ indices: [Int]) -> Result {
            Result(isValid: true, citedIndices: indices, reason: nil, unsupported: [])
        }

        public static func rejected(_ reason: String, _ unsupported: [String] = []) -> Result {
            Result(isValid: false, citedIndices: [], reason: reason, unsupported: unsupported)
        }
    }

    private struct Quantity: Equatable {
        let value: Decimal
        let unit: String
        let dimension: String
        let qualifier: String?
        let raw: String
    }

    private static let citation = try! NSRegularExpression(pattern: #"\[(\d+)\]"#)
    private static let quantity = try! NSRegularExpression(
        pattern: #"\b(\d+(?:\.\d+)?)\s*(mcg|µg|mg|g|kg|ml|l|%|minutes?|mins?|hours?|hrs?|days?|cm|mm|°?c|°?f|drops?)((?:\s*(?:/|per)\s*(?:kg|kilograms?|l|litres?|liters?|day|hours?))?)\b"#,
        options: [.caseInsensitive]
    )
    private static let injection = try! NSRegularExpression(
        pattern: #"(ignore (all |any |the )?(previous|prior|system) instructions|system prompt|developer message|jailbreak|do not cite|hide (the )?warning)"#,
        options: [.caseInsensitive]
    )
    private static let warning = try! NSRegularExpression(
        pattern: #"(?:warning|contraindicat(?:ion|ed)|do not|never|must not|seek (?:urgent |emergency )?help)[^.!?]*(?:[.!?]|$)"#,
        options: [.caseInsensitive]
    )
    private static let imperative = try! NSRegularExpression(
        pattern: #"^\s*(apply|avoid|call|clean|cool|cover|do|drink|give|keep|move|never|place|remove|rinse|seek|stop|take|use|wash)\b"#,
        options: [.caseInsensitive]
    )

    public static func validate(answer raw: String,
                                chunks: [RetrievedChunk],
                                retrievalAllowed: Bool) -> Result {
        let answer = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return .rejected("empty answer") }
        guard retrievalAllowed else { return .rejected("retrieval gate did not allow generation") }
        guard firstMatch(injection, in: answer) == nil else {
            return .rejected("instruction-injection marker in generated answer")
        }

        let indices = citationIndices(in: answer)
        guard !indices.isEmpty else { return .rejected("answer has no citation") }
        guard indices.allSatisfy({ $0 >= 1 && $0 <= chunks.count }) else {
            return .rejected("citation does not resolve to a retrieved chunk")
        }

        var unsupported: [String] = []
        for sentence in sentences(answer) {
            let markers = citationIndices(in: sentence)
            let body = replacingMatches(citation, in: sentence, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { continue }
            let quantities = extractQuantities(body)
            let highRisk = firstMatch(imperative, in: body) != nil ||
                (chunks.contains { highRiskDomains.contains($0.domain.lowercased()) } && !quantities.isEmpty)
            if highRisk && markers.isEmpty {
                unsupported.append("uncited high-risk instruction: \(body)")
                continue
            }
            if !quantities.isEmpty {
                if markers.isEmpty {
                    unsupported.append("uncited quantity: \(body)")
                } else {
                    let cited = markers.compactMap { (1...chunks.count).contains($0) ? chunks[$0 - 1] : nil }
                    unsupported.append(contentsOf: unsupportedQuantities(
                        sentence: body, quantities: quantities, chunks: cited))
                }
            }
        }

        let citedChunks = Array(Set(indices)).sorted().map { chunks[$0 - 1] }
        unsupported.append(contentsOf: missingWarnings(answer: answer, chunks: citedChunks))
        guard unsupported.isEmpty else {
            return .rejected("answer is not fully supported", Array(Set(unsupported)).sorted())
        }
        return .accepted(Array(Set(indices)).sorted())
    }

    /// Exact value+unit+qualifier provenance, retained as the strict replacement
    /// for SafetyGate.numericProvenance. Bare-number fallback is forbidden.
    public static func strictNumericProvenance(answer: String,
                                               evidence: [RetrievedChunk]) -> (Bool, [String]) {
        let quantities = extractQuantities(answer)
        if quantities.isEmpty { return (true, []) }
        let unsupported = unsupportedQuantities(
            sentence: answer, quantities: quantities, chunks: evidence)
        return (unsupported.isEmpty, unsupported)
    }

    private static func unsupportedQuantities(sentence: String,
                                              quantities: [Quantity],
                                              chunks: [RetrievedChunk]) -> [String] {
        quantities.compactMap { candidate in
            let supported = chunks.contains { chunk in
                extractQuantities(chunk.text).contains { evidence in
                    candidate.value == evidence.value &&
                    candidate.unit == evidence.unit &&
                    candidate.dimension == evidence.dimension &&
                    candidate.qualifier == evidence.qualifier &&
                    contextSupported(answer: sentence, evidence: chunk.text)
                }
            }
            return supported ? nil : "unsupported quantity/unit/context: \(candidate.raw)"
        }
    }

    private static func extractQuantities(_ text: String) -> [Quantity] {
        let ns = text as NSString
        return quantity.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            guard match.numberOfRanges >= 4 else { return nil }
            let rawValue = ns.substring(with: match.range(at: 1))
            guard let value = Decimal(string: rawValue, locale: Locale(identifier: "en_US_POSIX")) else {
                return nil
            }
            let unit = canonicalUnit(ns.substring(with: match.range(at: 2)))
            let qualifierRaw = match.range(at: 3).location == NSNotFound ? "" : ns.substring(with: match.range(at: 3))
            return Quantity(value: value,
                            unit: unit,
                            dimension: dimension(unit),
                            qualifier: canonicalQualifier(qualifierRaw),
                            raw: ns.substring(with: match.range))
        }
    }

    private static func canonicalUnit(_ raw: String) -> String {
        switch raw.lowercased() {
        case "µg", "mcg": return "mcg"
        case "minute", "minutes", "min", "mins": return "min"
        case "hour", "hours", "hr", "hrs": return "h"
        case "day", "days": return "d"
        case "°c", "c": return "degC"
        case "°f", "f": return "degF"
        case "drop", "drops": return "drop"
        default: return raw.lowercased()
        }
    }

    private static func canonicalQualifier(_ raw: String) -> String? {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw.lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "kilograms", with: "kg")
            .replacingOccurrences(of: "kilogram", with: "kg")
            .replacingOccurrences(of: "litres", with: "l")
            .replacingOccurrences(of: "liters", with: "l")
            .replacingOccurrences(of: "litre", with: "l")
            .replacingOccurrences(of: "liter", with: "l")
            .replacingOccurrences(of: "per", with: "/")
    }

    private static func dimension(_ unit: String) -> String {
        switch unit {
        case "mcg", "mg", "g", "kg": return "mass"
        case "ml", "l": return "volume"
        case "min", "h", "d": return "time"
        case "cm", "mm": return "length"
        case "degC", "degF": return "temperature"
        case "%": return "percent"
        case "drop": return "count"
        default: return "unknown"
        }
    }

    private static func contextSupported(answer: String, evidence: String) -> Bool {
        let answerTerms = contextTerms(answer)
        guard !answerTerms.isEmpty else { return false }
        let evidenceTerms = contextTerms(evidence)
        return answerTerms.filter { evidenceTerms.contains($0) }.count >= min(2, answerTerms.count)
    }

    private static func contextTerms(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter }.map(String.init)
            .filter { $0.count >= 3 && !contextStopWords.contains($0) })
    }

    private static func missingWarnings(answer: String, chunks: [RetrievedChunk]) -> [String] {
        let answerTokens = meaningfulTokens(answer)
        return chunks.flatMap { chunk -> [String] in
            let ns = chunk.text as NSString
            return warning.matches(in: chunk.text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
                let warningText = ns.substring(with: match.range)
                let required = meaningfulTokens(warningText)
                let coverage = required.isEmpty ? 1.0 :
                    Double(required.filter { answerTokens.contains($0) }.count) / Double(required.count)
                return coverage < 0.60
                    ? "required warning omitted from \(chunk.documentTitle): \(warningText)"
                    : nil
            }
        }
    }

    private static func meaningfulTokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
            .filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    private static func citationIndices(in text: String) -> [Int] {
        let ns = text as NSString
        return citation.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            Int(ns.substring(with: match.range(at: 1)))
        }
    }

    private static func sentences(_ text: String) -> [String] {
        text.split(whereSeparator: { ".!?".contains($0) })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }

    private static func replacingMatches(_ regex: NSRegularExpression,
                                         in text: String,
                                         with replacement: String) -> String {
        regex.stringByReplacingMatches(in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: replacement)
    }

    private static let highRiskDomains: Set<String> = [
        "medical", "first_aid", "medicine", "chemical", "water", "food_safety", "emergency"
    ]
    private static let contextStopWords: Set<String> = [
        "and", "the", "for", "with", "from", "into", "onto", "that", "this", "then", "use"
    ]
    private static let stopWords: Set<String> = [
        "and", "the", "for", "with", "from", "that", "this", "your", "you", "are", "not"
    ]
}
