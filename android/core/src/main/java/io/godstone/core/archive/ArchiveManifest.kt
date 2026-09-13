package io.godstone.core.archive

import java.io.File
import java.security.MessageDigest

/**
 * The trusted manifest of one shipped Archive, the record the installer
 * writes beside the selected bytes, and the strict reader for both
 * (blueprint s17).
 *
 * The manifest is the operator's word about the bytes that ship: which
 * file, how many, which digest. The installer believeth it not on its
 * face -- it proveth the bytes against it -- but the words must be well
 * formed before the proof begins:
 *   * duplicate keys are refused (a collapsing reader letteth the last
 *     key win; that is a smuggling gap, not a parser);
 *   * unknown future schema versions are refused outright (the
 *     pure-tooling version clause -- no auto-detection, no lenient
 *     fallback, no silent migration);
 *   * trailing matter after the document is refused;
 *   * numbers are carried as written: integers keep, anything else is
 *     refused where an integer was commanded.
 */
data class ArchiveManifestFacts(
    val schema: Int,
    val archiveSchema: Int,
    val tier: String,
    val fileName: String,
    val bytes: Long,
    val sha256: String,
    val approvalsSha256: String?,
) {
    companion object {
        const val MANIFEST_SCHEMA: Int = 1
        const val ARCHIVE_SCHEMA: Int = 3
        private val HEX = Regex("[0-9a-f]{64}")

        /** Parse the trusted manifest. Throws IllegalArgumentException
         * naming the fault; the caller refuseth and reporteth it. */
        fun fromJson(text: String): ArchiveManifestFacts {
            val root = StrictJson.parse(text)
            val obj = root as? StrictJson.Obj
                ?: throw IllegalArgumentException("manifest root must be an object")
            val schema = obj.intAt("schema")
            if (schema > MANIFEST_SCHEMA) {
                throw IllegalArgumentException(
                    "unsupported future archive-manifest schema $schema " +
                        "(this build understandeth $MANIFEST_SCHEMA)")
            }
            if (schema != MANIFEST_SCHEMA) {
                throw IllegalArgumentException(
                    "archive-manifest schema must be $MANIFEST_SCHEMA, found $schema")
            }
            val archiveSchema = obj.intAt("archive_schema")
            if (archiveSchema != ARCHIVE_SCHEMA) {
                throw IllegalArgumentException(
                    "archive schema $archiveSchema is incompatible with this build " +
                        "(understandeth $ARCHIVE_SCHEMA)")
            }
            val tier = obj.strAt("tier")
            if (tier != "LIGHT" && tier != "MEDIUM" && tier != "LARGE") {
                throw IllegalArgumentException("manifest tier is invalid: $tier")
            }
            val fileName = obj.strAt("archive_file")
            if (fileName.isEmpty() || fileName.contains('/') ||
                fileName.contains('\\') || fileName.contains("\u0000") ||
                fileName == "." || fileName == ".." || fileName.contains("..") ||
                fileName != fileName.trim() ||
                (fileName.length > 1 && fileName[1] == ':')
            ) {
                throw IllegalArgumentException(
                    "manifest archive_file is not a plain file name: $fileName")
            }
            val bytes = obj.longAt("archive_bytes")
            if (bytes <= 0L) {
                throw IllegalArgumentException("manifest archive_bytes must be positive")
            }
            val sha = obj.strAt("archive_sha256")
            if (!HEX.matches(sha)) {
                throw IllegalArgumentException(
                    "manifest archive_sha256 must be a lowercase SHA-256")
            }
            val meta = obj.get("archive_meta") as? StrictJson.Obj
            val approvals = meta?.get("approvals_sha256") as? StrictJson.Str
            if (approvals != null && !HEX.matches(approvals.value)) {
                throw IllegalArgumentException(
                    "manifest approvals_sha256 must be a lowercase SHA-256")
            }
            return ArchiveManifestFacts(
                schema = schema,
                archiveSchema = archiveSchema,
                tier = tier,
                fileName = fileName,
                bytes = bytes,
                sha256 = sha,
                approvalsSha256 = approvals?.value,
            )
        }
    }
}

/** The record the installer writes beside the selected bytes: what was
 * installed, proven by which digest, believed from which manifest. */
data class ArchiveRecord(
    val schema: Int,
    val sha256: String,
    val bytes: Long,
    val origin: String,
    val selectedAtMs: Long,
) {
    /** Canonical bytes: sorted keys, tight separators. The digest of the
     * record is the digest of THIS text, so the writer must be deterministic. */
    fun toCanonJson(): String = StrictJson.canon(
        listOf(
            "schema" to schema.toString(),
            "sha256" to sha256,
            "bytes" to bytes.toString(),
            "origin" to origin,
            "selected_at_ms" to selectedAtMs.toString(),
        ))

    companion object {
        const val RECORD_SCHEMA: Int = 1
        private val HEX = Regex("[0-9a-f]{64}")

        fun fromJson(text: String): ArchiveRecord {
            val root = StrictJson.parse(text)
            val obj = root as? StrictJson.Obj
                ?: throw IllegalArgumentException("record root must be an object")
            val schema = obj.intAt("schema")
            if (schema > RECORD_SCHEMA) {
                throw IllegalArgumentException(
                    "unsupported future archive record schema $schema")
            }
            if (schema != RECORD_SCHEMA) {
                throw IllegalArgumentException("archive record schema must be 1")
            }
            val sha = obj.strAt("sha256")
            if (!HEX.matches(sha)) {
                throw IllegalArgumentException("archive record sha256 is not lowercase hex")
            }
            return ArchiveRecord(
                schema = schema,
                sha256 = sha,
                bytes = obj.longAt("bytes"),
                origin = obj.strAt("origin"),
                selectedAtMs = obj.longAt("selected_at_ms"),
            )
        }
    }
}

/** SHA-256 over files and bytes, streamed. The workhorse of proof. */
object Sha256 {
    fun hexOf(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                md.update(buffer, 0, read)
            }
        }
        return toHex(md.digest())
    }

    fun hexOf(bytes: ByteArray): String =
        toHex(MessageDigest.getInstance("SHA-256").let { it.update(bytes); it.digest() })

    fun toHex(digest: ByteArray): String = digest.joinToString("") { "%02x".format(it) }
}

/* ---------------------------------------------------------------------- */
/* StrictJson -- a small, strict recursive-descent reader for the JSON    */
/* the Archive pipeline writes. Duplicate keys, control characters in     */
/* strings, non-integer numbers where integers are commanded, and         */
/* trailing matter are all refused. Nothing lenient lurketh here.          */
/* ---------------------------------------------------------------------- */
object StrictJson {
    sealed class Value
    object Null : Value()
    data class Bool(val value: Boolean) : Value()
    data class Num(val value: String) : Value()          // carried as written
    data class Str(val value: String) : Value()
    data class Arr(val items: List<Value>) : Value()
    class Obj(val entries: List<Pair<String, Value>>) : Value() {
        private val index: Map<String, Value> = buildMap()

        private fun buildMap(): Map<String, Value> {
            val m = LinkedHashMap<String, Value>()
            for ((k, v) in entries) m[k] = v            // duplicates were refused by the reader
            return m
        }

        fun get(key: String): Value? = index[key]

        fun strAt(key: String): String =
            ((get(key) as? Str)
                ?: throw IllegalArgumentException("$key must be a string")).value

        fun intAt(key: String): Int {
            val v = longAt(key)
            if (v > Int.MAX_VALUE || v < Int.MIN_VALUE) {
                throw IllegalArgumentException("$key is out of int range")
            }
            return v.toInt()
        }

        fun longAt(key: String): Long {
            val n = get(key) as? Num
                ?: throw IllegalArgumentException("$key must be a number")
            return n.value.toLongOrNull()
                ?: throw IllegalArgumentException("$key must be an integer")
        }
    }

    class JsonFault(message: String) : IllegalArgumentException(message)

    fun parse(text: String): Value = Reader(text).document()

    /** Canonical output for records: sorted keys, tight separators. Values
     * arrive already rendered as strings; string values are quoted and
     * escaped here, numeric words are carried as written. */
    fun canon(fields: List<Pair<String, String>>): String {
        val sb = StringBuilder()
        sb.append('{')
        for ((n, pair) in fields.sortedBy { (k, _) -> k }.withIndex()) {
            if (n > 0) sb.append(',')
            sb.append('"').append(escape(pair.first)).append("\":")
            val value = pair.second
            if (value == "null" || isNumericWord(value)) {
                sb.append(value)
            } else {
                sb.append('"').append(escape(value)).append('"')
            }
        }
        sb.append('}')
        return sb.toString()
    }

    private fun isNumericWord(text: String): Boolean =
        text.isNotEmpty() && text.all { it in '0'..'9' || it == '-' } &&
            text.first() != '-' && text.last() != '-' &&
            !text.contains("--") && (text.count { it == '-' } <= 1)

    private fun escape(value: String): String {
        val sb = StringBuilder()
        for (c in value) {
            when (c) {
                '"' -> sb.append("\\\"")
                '\\' -> sb.append("\\\\")
                '\n' -> sb.append("\\n")
                '\r' -> sb.append("\\r")
                '\t' -> sb.append("\\t")
                else -> if (c.code < 0x20) sb.append("\\u").append("%04x".format(c.code))
                else sb.append(c)
            }
        }
        return sb.toString()
    }

    private class Reader(private val s: String) {
        private var i = 0

        fun document(): Value {
            skipWs()
            val v = value()
            skipWs()
            if (i != s.length) throw JsonFault("trailing matter at offset $i")
            return v
        }

        private fun skipWs() {
            while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++
        }

        private fun value(): Value {
            skipWs()
            if (i >= s.length) throw JsonFault("unexpected end of document")
            return when (s[i]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> literal("true", Bool(true))
                'f' -> literal("false", Bool(false))
                'n' -> literal("null", Null)
                else -> number()
            }
        }

        private fun literal(word: String, lit: Value): Value {
            if (!s.startsWith(word, i)) throw JsonFault("bad literal at offset $i")
            i += word.length
            return lit
        }

        private fun obj(): Value {
            expect('{')
            skipWs()
            val entries = ArrayList<Pair<String, Value>>()
            if (peek() == '}') { i++; return Obj(entries) }
            while (true) {
                skipWs()
                val key = str().value
                skipWs()
                expect(':')
                val v = value()
                for (prior in entries) {
                    if (prior.first == key) throw JsonFault("duplicate key \"$key\"")
                }
                entries.add(key to v)
                skipWs()
                val c = take()
                if (c == ',') continue
                if (c == '}') return Obj(entries)
                throw JsonFault("expected , or } at offset ${i - 1}, found '$c'")
            }
        }

        private fun arr(): Value {
            expect('[')
            skipWs()
            val items = ArrayList<Value>()
            if (peek() == ']') { i++; return Arr(items) }
            while (true) {
                items.add(value())
                skipWs()
                val c = take()
                if (c == ',') continue
                if (c == ']') return Arr(items)
                throw JsonFault("expected , or ] at offset ${i - 1}, found '$c'")
            }
        }

        private fun str(): Str {
            expect('"')
            val sb = StringBuilder()
            while (true) {
                if (i >= s.length) throw JsonFault("unterminated string")
                val c = s[i++]
                if (c == '"') return Str(sb.toString())
                if (c == '\\') {
                    if (i >= s.length) throw JsonFault("unterminated escape")
                    when (val e = s[i++]) {
                        '"', '\\', '/' -> sb.append(e)
                        'b' -> sb.append('\b')
                        'f' -> sb.append('\u000C')
                        'n' -> sb.append('\n')
                        'r' -> sb.append('\r')
                        't' -> sb.append('\t')
                        'u' -> {
                            if (i + 4 > s.length) throw JsonFault("unterminated \\u escape")
                            val hex = s.substring(i, i + 4)
                            val cp = hex.toIntOrNull(16)
                                ?: throw JsonFault("bad \\u escape \"$hex\"")
                            i += 4
                            sb.append(cp.toChar())
                        }
                        else -> throw JsonFault("unknown escape '\\$e'")
                    }
                } else if (c.code < 0x20) {
                    throw JsonFault("unescaped control character at offset ${i - 1}")
                } else {
                    sb.append(c)
                }
            }
        }

        private fun number(): Value {
            val start = i
            if (i < s.length && s[i] == '-') i++
            val digitsStart = i
            while (i < s.length && s[i] in '0'..'9') i++
            if (i == digitsStart) throw JsonFault("bad number at offset $start")
            if (i < s.length && (s[i] == '.' || s[i] == 'e' || s[i] == 'E')) {
                throw JsonFault("non-integer number at offset $start")
            }
            return Num(s.substring(start, i))
        }

        private fun peek(): Char {
            if (i >= s.length) throw JsonFault("unexpected end of document")
            return s[i]
        }

        private fun take(): Char {
            if (i >= s.length) throw JsonFault("unexpected end of document")
            return s[i++]
        }

        private fun expect(c: Char) {
            if (i >= s.length || s[i] != c) throw JsonFault("expected '$c' at offset $i")
            i++
        }
    }
}
