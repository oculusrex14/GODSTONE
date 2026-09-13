package io.godstone.core.archive

import java.util.LinkedHashSet

/**
 * The bounded tokenised search-query builder (blueprint s17).
 *
 * The road from a user's words to an FTS5 MATCH expression is the one
 * place where untrusted text toucheth the query grammar. The laws here:
 *   * the raw text NEVER entereth the MATCH string; every term is
 *     quarantined inside double quotes, so the grammar characters the
 *     engine would otherwise interpret -- the double-quote, the star,
 *     the parentheses, the colon, the caret, the hyphen, the bare
 *     OR/AND/NOT words -- cannot steer the parse;
 *   * the phrase may be no longer than [MAX_PHRASE_CHARS] characters;
 *   * the query may carry no more than [MAX_TERMS] distinct terms;
 *   * a page may be no bigger than [MAX_RESULTS] rows, and every limit
 *     is clamped into that bound;
 *   * a refusal names its own cause -- nothing silently answereth.
 */
object SearchQuery {
    const val MAX_PHRASE_CHARS: Int = 512
    const val MAX_TERMS: Int = 32
    const val MAX_RESULTS: Int = 200

    /** The grammar characters an unquoted term must never carry; they are
     * boundaries here, never content. */
    private val STRIPPED = "\"*():^-\\"

    sealed class Built {
        /** Nothing to ask: the caller shall return no rows, not an error. */
        object Empty : Built()

        /** A safe MATCH expression: every term quoted, joined by OR. */
        data class Ready(val match: String, val termCount: Int) : Built()

        /** The query was refused, and this is why. */
        data class Refused(val reason: String) : Built()
    }

    fun build(raw: String?): Built {
        if (raw == null) return Built.Empty
        if (raw.length > MAX_PHRASE_CHARS) {
            return Built.Refused(
                "the phrase carries " + raw.length + " characters; the bound is " +
                    MAX_PHRASE_CHARS)
        }
        val terms = ArrayList<String>()
        val seen = LinkedHashSet<String>()
        val current = StringBuilder()
        for (c in raw) {
            if (c.isWhitespace() || c in STRIPPED) {
                if (current.isNotEmpty()) {
                    val term = current.toString()
                    current.clear()
                    if (seen.add(term)) terms.add(term)
                }
            } else {
                current.append(c)
            }
        }
        if (current.isNotEmpty()) {
            val term = current.toString()
            if (seen.add(term)) terms.add(term)
        }
        if (terms.isEmpty()) return Built.Empty
        if (terms.size > MAX_TERMS) {
            return Built.Refused(
                "the query carries " + terms.size + " distinct terms; the bound is " +
                    MAX_TERMS)
        }
        val match = terms.joinToString(" OR ") { "\"" + it + "\"" }
        return Built.Ready(match, terms.size)
    }

    /** Clamp a requested page size into the house bound. */
    fun bound(limit: Int): Int = limit.coerceIn(1, MAX_RESULTS)
}
