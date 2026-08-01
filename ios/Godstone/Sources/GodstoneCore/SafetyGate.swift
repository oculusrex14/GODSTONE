import Foundation

/// The C3 grounding gate. Swift port of `safety/gate.py`, byte-for-byte
/// equivalent in behaviour to `io.godstone.llm.safety.SafetyGate` on Android.
///
/// THE DEFECT THIS CLOSES. `safety/gate.py` was written, probed red/green, and
/// proven to discriminate -- and both shipping apps went on using
/// `bestScore >= 0.35` over a reciprocal-rank-fusion score. The repository's own
/// audit explains why that rule cannot discriminate; the product shipped it
/// anyway. The improved gate lived in the test harness only.
///
/// WHY RRF COULD NOT BE RETUNED. RRF is a RANK statistic. Rank 1 exists in every
/// non-empty result set, so the score says "something was returned", never
/// "something was relevant". The whole top-20 spans 0.500...0.381, all above the
/// floor, and the FTS query ORs its terms so the set is never empty.
///
/// S2 (colocation) is the signal that works: requiring the query's rare terms to
/// co-occur INSIDE A SINGLE PASSAGE is what separates "these words exist
/// somewhere in the archive" from "a passage supports this answer".
///
/// PARITY: every constant below is mirrored in safety/gate.py and SafetyGate.kt.
/// Invariant G fails the build if they drift.
public enum SafetyGate {

    public static let anchorRecallFloor = 0.60
    public static let colocationFloor = 0.50
    public static let domainCoherenceFloor = 0.40
    public static let caveatMargin = 0.15
    public static let minAnchorLen = 3
    public static let stemPrefixLen = 5

    public enum Verdict: String, Sendable {
        case allow = "ALLOW"
        case allowWithCaveat = "ALLOW_WITH_CAVEAT"
        case refuseNoEvidence = "REFUSE_NO_EVIDENCE"
        case refuseScatteredEvidence = "REFUSE_SCATTERED_EVIDENCE"

        public var allowsGeneration: Bool {
            self == .allow || self == .allowWithCaveat
        }
    }

    public struct Result: Sendable {
        public let verdict: Verdict
        public let reasons: [String]
        public let anchorRecall: Double
        public let colocation: Double
        public let domainCoherence: Double
        public let oovTerms: [String]

        public var allowsGeneration: Bool { verdict.allowsGeneration }

        /// What a frightened user is actually shown. Never a fabricated answer.
        public func userMessage() -> String {
            switch verdict {
            case .refuseNoEvidence:
                if !oovTerms.isEmpty {
                    return "The archive does not cover this. It contains no guidance on "
                        + oovTerms.sorted().joined(separator: ", ") + "."
                }
                return "The archive does not cover this."
            case .refuseScatteredEvidence:
                return "The archive does not cover this. Related words appear, but no "
                    + "single passage supports an answer."
            case .allowWithCaveat:
                return "Supported, but the evidence is thin. Check the sources."
            case .allow:
                return ""
            }
        }
    }

    static let stopwords: Set<String> = [
        "a","an","the","is","are","was","were","be","been","being","am","do","does",
        "did","doing","how","what","when","where","which","who","whom","why","can",
        "could","should","would","will","shall","may","might","must","i","you","he",
        "she","it","we","they","my","your","his","her","its","our","their","me","him",
        "them","this","that","these","those","there","here","about","into","over",
        "under","of","to","in","on","at","for","from","with","without","and","or",
        "but","if","then","than","as","by","so","such","no","not","only","own","same",
        "too","very","just","now","also","get","got","make","made","want","need",
        "use","used","using","please","tell","show","give"
    ]

    /// Terms denoting an ACTION or QUANTITY the archive would have to cover
    /// explicitly. If one is absent from the corpus, retrieval cannot recover
    /// it, so we refuse BEFORE scoring anything.
    static let actionTerms: Set<String> = [
        "dose","dosage","inject","injection","prescribe","prescription",
        "synthesise","synthesize","manufacture","buy","sell","trade","invest",
        "translate","summarise","summarize","plot","price","share","stock",
        "cryptocurrency","phone","number","address","latitude","longitude",
        "coordinate"
    ]

    /// Deliberately crude morphological normalisation. An earlier draft refused
    /// "how long should I boil water" because `boil` and `boiling` differed.
    public static func stem(_ word: String) -> String {
        var w = word.lowercased()
        for suf in ["ational","ization","isation","ation","ings","ing",
                    "ed","ies","es","s"] {
            if w.hasSuffix(suf) && w.count - suf.count >= 3 {
                w = String(w.dropLast(suf.count)); break
            }
        }
        if w.count > 3 {
            let chars = Array(w)
            if chars[chars.count - 1] == chars[chars.count - 2] { w = String(w.dropLast()) }
        }
        return w
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    static func contentTerms(_ text: String) -> [String] {
        tokens(text).filter { $0.count >= minAnchorLen && !stopwords.contains($0) }
    }

    /// Corpus vocabulary and IDF, built once from the archive.
    public struct CorpusIndex: Sendable {
        public var vocabulary: Set<String> = []
        public var stems: Set<String> = []
        public var idf: [String: Double] = [:]

        public init(chunks: [RetrievedChunk]) {
            var df: [String: Int] = [:]
            for c in chunks {
                let terms = contentTerms(c.text + " " + c.documentTitle)
                vocabulary.formUnion(terms)
                let st = terms.map { stem($0) }
                stems.formUnion(st)
                for t in Set(st) { df[t, default: 0] += 1 }
            }
            let n = max(1, chunks.count)
            for (t, d) in df {
                // Parenthesised to match gate.py and SafetyGate.kt exactly.
                idf[t] = log((Double(n - d) + 0.5) / (Double(d) + 0.5) + 1.0)
            }
        }

        /// Tolerant of inflection: `purify` must match `purification`.
        public func known(_ term: String) -> Bool {
            if vocabulary.contains(term) { return true }
            let s = stem(term)
            if stems.contains(s) { return true }
            if s.count >= stemPrefixLen {
                let p = String(s.prefix(stemPrefixLen))
                return stems.contains { $0.hasPrefix(p) }
            }
            return false
        }
    }

    static func presentIn(_ text: String, _ term: String) -> Bool {
        let toks = Set(contentTerms(text).map { stem($0) })
        let s = stem(term)
        if toks.contains(s) { return true }
        if s.count >= stemPrefixLen {
            let p = String(s.prefix(stemPrefixLen))
            return toks.contains { $0.hasPrefix(p) }
        }
        return false
    }

    /// The single entry point. Nothing else may decide whether an answer is
    /// grounded -- that separation is exactly what Invariant B enforces.
    public static func evaluate(question: String,
                                chunks: [RetrievedChunk],
                                index: CorpusIndex) -> Result {
        var seen = Set<String>()
        let anchors = contentTerms(question).filter { seen.insert($0).inserted }
        let oovAny = anchors.filter { !index.known($0) }
        let oovActions = anchors.filter { actionTerms.contains($0) && !index.known($0) }

        if !oovActions.isEmpty {
            return Result(verdict: .refuseNoEvidence,
                reasons: ["archive has no material on action term(s): "
                          + oovActions.joined(separator: ", ")],
                anchorRecall: 0, colocation: 0, domainCoherence: 0,
                oovTerms: oovActions)
        }
        if !anchors.isEmpty && Double(oovAny.count) / Double(anchors.count) >= 0.5 {
            return Result(verdict: .refuseNoEvidence,
                reasons: ["\(oovAny.count)/\(anchors.count) query terms absent from the archive"],
                anchorRecall: 0, colocation: 0, domainCoherence: 0, oovTerms: oovAny)
        }
        if chunks.isEmpty {
            return Result(verdict: .refuseNoEvidence,
                reasons: ["retrieval returned nothing"],
                anchorRecall: 0, colocation: 0, domainCoherence: 0, oovTerms: oovAny)
        }

        let known = anchors.filter { index.known($0) }
        if known.isEmpty {
            return Result(verdict: .refuseNoEvidence, reasons: ["no usable query terms"],
                anchorRecall: 0, colocation: 0, domainCoherence: 0, oovTerms: oovAny)
        }

        var weights: [String: Double] = [:]
        for t in known { weights[t] = index.idf[stem(t)] ?? 1.0 }
        let totalW = max(weights.values.reduce(0, +), 0.000001)

        // S1 anchor_recall: union coverage across the whole result set.
        let union = chunks.map { $0.text + " " + $0.documentTitle }.joined(separator: " ")
        let s1 = known.filter { presentIn(union, $0) }
                      .reduce(0.0) { $0 + (weights[$1] ?? 0) } / totalW

        // S2 colocation: the best SINGLE passage. THIS is the signal that works.
        var s2 = 0.0
        for c in chunks {
            let blob = c.text + " " + c.documentTitle
            let hit = known.filter { presentIn(blob, $0) }
                           .reduce(0.0) { $0 + (weights[$1] ?? 0) } / totalW
            if hit > s2 { s2 = hit }
        }

        // S3 domain coherence: is the evidence from one place?
        var doms: [String: Int] = [:]
        for c in chunks { doms[c.domain, default: 0] += 1 }
        let s3 = Double(doms.values.max() ?? 0) / Double(chunks.count)

        var reasons: [String] = []
        if s1 < anchorRecallFloor {
            reasons.append(String(format:
                "anchor_recall %.2f < %.2f: key terms missing from every retrieved passage",
                s1, anchorRecallFloor))
            return Result(verdict: .refuseNoEvidence, reasons: reasons,
                anchorRecall: s1, colocation: s2, domainCoherence: s3, oovTerms: oovAny)
        }
        if s2 < colocationFloor {
            reasons.append(String(format:
                "colocation %.2f < %.2f: terms appear in the archive but scattered across unrelated passages",
                s2, colocationFloor))
            return Result(verdict: .refuseScatteredEvidence, reasons: reasons,
                anchorRecall: s1, colocation: s2, domainCoherence: s3, oovTerms: oovAny)
        }
        if s3 < domainCoherenceFloor {
            reasons.append(String(format:
                "domain_coherence %.2f < %.2f: evidence drawn from sections the corpus keeps separate",
                s3, domainCoherenceFloor))
            return Result(verdict: .refuseScatteredEvidence, reasons: reasons,
                anchorRecall: s1, colocation: s2, domainCoherence: s3, oovTerms: oovAny)
        }
        if s2 < colocationFloor + caveatMargin {
            reasons.append("supported but thin: surface sources prominently")
            return Result(verdict: .allowWithCaveat, reasons: reasons,
                anchorRecall: s1, colocation: s2, domainCoherence: s3, oovTerms: oovAny)
        }
        reasons.append("anchors co-occur in a single supporting passage")
        return Result(verdict: .allow, reasons: reasons,
            anchorRecall: s1, colocation: s2, domainCoherence: s3, oovTerms: oovAny)
    }

    /// Post-generation numeric provenance. Retrieval gates cannot catch this,
    /// because retrieval already SUCCEEDED: this is the model turning 500 mg
    /// into 750 mg. Runs immediately before the answer is displayed.
    public static func numericProvenance(answer: String,
                                         evidence: [RetrievedChunk]) -> (Bool, [String]) {
        let pattern = #"\b\d+(?:\.\d+)?\s*(?:mg|ml|mcg|g|kg|l|litres?|liters?|drops?|minutes?|hours?|days?|percent|%|degrees?|cm|mm|m)\b"#
        guard let rx = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return (true, []) }

        func matches(_ s: String) -> [String] {
            let ns = s as NSString
            return rx.matches(in: s, range: NSRange(location: 0, length: ns.length))
                     .map { ns.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
        }

        let quantities = matches(answer)
        if quantities.isEmpty { return (true, []) }

        let blob = evidence.map { $0.text }.joined(separator: " ").lowercased()
        let blobNums = Set(matches(blob).map {
            $0.replacingOccurrences(of: " ", with: "").lowercased() })
        let digits = try? NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#)
        let nsBlob = blob as NSString
        let blobBare = Set((digits?.matches(in: blob,
            range: NSRange(location: 0, length: nsBlob.length)) ?? [])
            .map { nsBlob.substring(with: $0.range) })

        let unsupported = quantities.filter { q in
            let norm = q.replacingOccurrences(of: " ", with: "").lowercased()
            if blobNums.contains(norm) { return false }
            let nsQ = q as NSString
            let n = (digits?.firstMatch(in: q,
                range: NSRange(location: 0, length: nsQ.length)))
                .map { nsQ.substring(with: $0.range) }
            if let n, blobBare.contains(n) { return false }
            return true
        }
        return (unsupported.isEmpty, unsupported)
    }
}
