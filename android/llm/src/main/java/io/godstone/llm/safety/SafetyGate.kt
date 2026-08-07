package io.godstone.llm.safety

import io.godstone.llm.rag.Chunk
import kotlin.math.ln

/**
 * The C3 grounding gate, ported from safety/gate.py.
 *
 * THE DEFECT THIS CLOSES. safety/gate.py was written, probed red/green, and
 * proven to discriminate -- and then the shipping apps went on using
 * `bestScore >= 0.35` over a reciprocal-rank-fusion score. The repository's own
 * audit explains at length why that rule cannot discriminate, and the app kept
 * using it anyway. The improved gate lived in the test harness; the product
 * shipped the gate the audit had already condemned.
 *
 * WHY RRF COULD NOT BE RETUNED. RRF is a RANK statistic. Rank 1 exists in every
 * non-empty result set, so the score says "something was returned", never
 * "something was relevant". With K=60 the entire top-20 spans 0.500 -> 0.381,
 * all of it above the 0.35 floor, and sanitiseFts ORs the terms so the set is
 * essentially never empty. Rank 3 of a perfect match and rank 20 of pure noise
 * differ by 0.06. No threshold separates them.
 *
 * WHAT REPLACES IT. A hard pre-check plus four fail-closed signals. S2
 * (colocation) is the one that matters: requiring the query's rare terms to
 * co-occur INSIDE A SINGLE PASSAGE is what turns "the words exist somewhere in
 * the archive" into "a passage supports this answer".
 *
 * PARITY. Every constant here is mirrored in safety/gate.py and
 * ios/.../SafetyGate.swift. Invariant G fails the build if they drift.
 */
object SafetyGate {

    const val ANCHOR_RECALL_FLOOR = 0.60
    const val COLOCATION_FLOOR = 0.50
    const val DOMAIN_COHERENCE_FLOOR = 0.40
    const val CAVEAT_MARGIN = 0.15
    const val MIN_ANCHOR_LEN = 3
    const val STEM_PREFIX_LEN = 5

    enum class Verdict {
        ALLOW,
        ALLOW_WITH_CAVEAT,
        REFUSE_NO_EVIDENCE,
        REFUSE_SCATTERED_EVIDENCE;

        val allowsGeneration: Boolean
            get() = this == ALLOW || this == ALLOW_WITH_CAVEAT
    }

    data class Result(
        val verdict: Verdict,
        val reasons: List<String>,
        val anchorRecall: Double,
        val colocation: Double,
        val domainCoherence: Double,
        val oovTerms: List<String>
    ) {
        val allowsGeneration: Boolean get() = verdict.allowsGeneration

        /** What the user is actually shown. Never a fabricated answer. */
        fun userMessage(): String = when (verdict) {
            Verdict.REFUSE_NO_EVIDENCE ->
                if (oovTerms.isNotEmpty())
                    "The archive does not cover this. It contains no guidance on " +
                        oovTerms.sorted().joinToString(", ") + "."
                else "The archive does not cover this."
            Verdict.REFUSE_SCATTERED_EVIDENCE ->
                "The archive does not cover this. Related words appear, but no " +
                    "single passage supports an answer."
            Verdict.ALLOW_WITH_CAVEAT ->
                "Supported, but the evidence is thin. Check the sources."
            Verdict.ALLOW -> ""
        }
    }

    private val STOPWORDS = setOf(
        "a","an","the","is","are","was","were","be","been","being","am","do","does",
        "did","doing","how","what","when","where","which","who","whom","why","can",
        "could","should","would","will","shall","may","might","must","i","you","he",
        "she","it","we","they","my","your","his","her","its","our","their","me","him",
        "them","this","that","these","those","there","here","about","into","over",
        "under","of","to","in","on","at","for","from","with","without","and","or",
        "but","if","then","than","as","by","so","such","no","not","only","own","same",
        "too","very","just","now","also","get","got","make","made","want","need",
        "use","used","using","please","tell","show","give"
    )

    /**
     * Terms denoting an ACTION or QUANTITY the archive would have to cover
     * explicitly. If one is absent from the corpus vocabulary, no amount of
     * retrieval recovers it, so we refuse BEFORE scoring.
     */
    private val ACTION_TERMS = setOf(
        "dose","dosage","inject","injection","prescribe","prescription",
        "synthesise","synthesize","manufacture","buy","sell","trade","invest",
        "translate","summarise","summarize","plot","price","share","stock",
        "cryptocurrency","phone","number","address","latitude","longitude",
        "coordinate"
    )

    private val WORD = Regex("[a-z0-9]+")
    private val NUMERIC = Regex(
        """\b\d+(?:\.\d+)?\s*(?:mg|ml|mcg|g|kg|l|litres?|liters?|drops?|minutes?|hours?|days?|percent|%|degrees?|cm|mm|m)\b""",
        RegexOption.IGNORE_CASE)

    /**
     * Deliberately crude morphological normalisation. The first draft of the
     * Python gate refused "how long should I boil water" because `boil` and
     * `boiling` were treated as different terms.
     */
    fun stem(word: String): String {
        var w = word.lowercase()
        for (suf in listOf("ational","ization","isation","ation","ings","ing",
                           "ed","ies","es","s")) {
            if (w.endsWith(suf) && w.length - suf.length >= 3) {
                w = w.dropLast(suf.length); break
            }
        }
        if (w.length > 3 && w[w.length - 1] == w[w.length - 2]) w = w.dropLast(1)
        return w
    }

    private fun tokens(text: String) = WORD.findAll(text.lowercase()).map { it.value }.toList()

    private fun contentTerms(text: String) =
        tokens(text).filter { it.length >= MIN_ANCHOR_LEN && it !in STOPWORDS }

    /** Corpus vocabulary + IDF, built once from the archive. */
    class CorpusIndex(chunks: List<Chunk>) {
        val vocabulary = HashSet<String>()
        val stems = HashSet<String>()
        val idf = HashMap<String, Double>()

        init {
            val df = HashMap<String, Int>()
            for (c in chunks) {
                val terms = contentTerms(c.text + " " + c.documentTitle)
                vocabulary.addAll(terms)
                stems.addAll(terms.map { stem(it) })
                for (t in terms.map { stem(it) }.toSet()) df[t] = (df[t] ?: 0) + 1
            }
            val n = maxOf(1, chunks.size)
            for ((t, d) in df) idf[t] = ln((n - d + 0.5) / (d + 0.5) + 1.0)
        }

        /** Membership tolerant of inflection: `purify` must match `purification`. */
        fun known(term: String): Boolean {
            if (term in vocabulary) return true
            val s = stem(term)
            if (s in stems) return true
            if (s.length >= STEM_PREFIX_LEN) {
                val p = s.take(STEM_PREFIX_LEN)
                return stems.any { it.startsWith(p) }
            }
            return false
        }
    }

    private fun presentIn(text: String, term: String): Boolean {
        val toks = contentTerms(text).map { stem(it) }.toSet()
        val s = stem(term)
        if (s in toks) return true
        if (s.length >= STEM_PREFIX_LEN) {
            val p = s.take(STEM_PREFIX_LEN)
            return toks.any { it.startsWith(p) }
        }
        return false
    }

    /**
     * The single entry point. Nothing else may decide whether an answer is
     * grounded -- that separation is what Invariant B exists to enforce.
     */
    fun evaluate(question: String, chunks: List<Chunk>, index: CorpusIndex): Result {
        val anchors = contentTerms(question).distinct()
        val oovAny = anchors.filter { !index.known(it) }
        val oovActions = anchors.filter { it in ACTION_TERMS && !index.known(it) }

        if (oovActions.isNotEmpty()) {
            return Result(Verdict.REFUSE_NO_EVIDENCE,
                listOf("archive has no material on action term(s): " +
                    oovActions.joinToString(", ")),
                0.0, 0.0, 0.0, oovActions)
        }
        if (anchors.isNotEmpty() && oovAny.size.toDouble() / anchors.size >= 0.5) {
            return Result(Verdict.REFUSE_NO_EVIDENCE,
                listOf("${oovAny.size}/${anchors.size} query terms absent from the archive"),
                0.0, 0.0, 0.0, oovAny)
        }
        if (chunks.isEmpty()) {
            return Result(Verdict.REFUSE_NO_EVIDENCE,
                listOf("retrieval returned nothing"), 0.0, 0.0, 0.0, oovAny)
        }

        val known = anchors.filter { index.known(it) }
        if (known.isEmpty()) {
            return Result(Verdict.REFUSE_NO_EVIDENCE,
                listOf("no usable query terms"), 0.0, 0.0, 0.0, oovAny)
        }

        // IDF weighting: rare terms carry the meaning.
        val weights = known.associateWith { (index.idf[stem(it)] ?: 1.0) }
        val totalW = weights.values.sum().takeIf { it > 0 } ?: 1.0

        // S1 anchor_recall: union coverage across the whole result set.
        val union = chunks.joinToString(" ") { it.text + " " + it.documentTitle }
        val s1 = known.filter { presentIn(union, it) }.sumOf { weights[it]!! } / totalW

        // S2 colocation: the best SINGLE passage. THIS is the signal that works.
        var s2 = 0.0
        for (c in chunks) {
            val blob = c.text + " " + c.documentTitle
            val hit = known.filter { presentIn(blob, it) }.sumOf { weights[it]!! } / totalW
            if (hit > s2) s2 = hit
        }

        // S3 domain coherence: is the evidence from one place?
        val doms = chunks.groupingBy { it.domain }.eachCount()
        val s3 = (doms.values.maxOrNull() ?: 0).toDouble() / chunks.size

        val reasons = ArrayList<String>()
        if (s1 < ANCHOR_RECALL_FLOOR) {
            reasons.add("anchor_recall %.2f < %.2f: key terms missing from every retrieved passage"
                .format(s1, ANCHOR_RECALL_FLOOR))
            return Result(Verdict.REFUSE_NO_EVIDENCE, reasons, s1, s2, s3, oovAny)
        }
        if (s2 < COLOCATION_FLOOR) {
            reasons.add("colocation %.2f < %.2f: terms appear in the archive but scattered across unrelated passages"
                .format(s2, COLOCATION_FLOOR))
            return Result(Verdict.REFUSE_SCATTERED_EVIDENCE, reasons, s1, s2, s3, oovAny)
        }
        if (s3 < DOMAIN_COHERENCE_FLOOR) {
            reasons.add("domain_coherence %.2f < %.2f: evidence drawn from sections the corpus keeps separate"
                .format(s3, DOMAIN_COHERENCE_FLOOR))
            return Result(Verdict.REFUSE_SCATTERED_EVIDENCE, reasons, s1, s2, s3, oovAny)
        }
        if (s2 < COLOCATION_FLOOR + CAVEAT_MARGIN) {
            reasons.add("supported but thin: surface sources prominently")
            return Result(Verdict.ALLOW_WITH_CAVEAT, reasons, s1, s2, s3, oovAny)
        }
        reasons.add("anchors co-occur in a single supporting passage")
        return Result(Verdict.ALLOW, reasons, s1, s2, s3, oovAny)
    }

    /**
     * Post-generation numeric provenance. Retrieval gates cannot catch this,
     * because retrieval already SUCCEEDED: this is a small model turning
     * 500 mg into 750 mg, or 1 minute into 10. Runs immediately before display.
     */
    fun numericProvenance(answer: String, evidence: List<Chunk>): Pair<Boolean, List<String>> {
        val quantities = NUMERIC.findAll(answer).map { it.value.trim() }.toList()
        if (quantities.isEmpty()) return true to emptyList()
        val blob = evidence.joinToString(" ") { it.text }.lowercase()
        val blobNums = NUMERIC.findAll(blob).map { it.value.replace(Regex("\\s+"), "").lowercase() }.toSet()
        // Exact quantity+unit only. A matching bare number in a different
        // unit or dimension is never evidence (GST-SAFE-002).
        val unsupported = quantities.filter { q ->
            q.replace(Regex("\\s+"), "").lowercase() !in blobNums
        }
        return unsupported.isEmpty() to unsupported
    }
}
