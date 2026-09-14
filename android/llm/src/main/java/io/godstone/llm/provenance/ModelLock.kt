package io.godstone.llm.provenance

import java.security.MessageDigest

/**
 * T61 model-provenance law, Android isle. Twin of the tested Python authority
 * scripts/model_provenance.py and of the iOS GodstoneLLMProvenance module.
 *
 * The strict register (schema 2, ModelLockV1) refuseth: future or unknown
 * schemas; a mutable branch head where an immutable 40-hex source commit is
 * demanded; missing or malformed digests; absent licence oaths; path traversal
 * in either door (source_file, output_file); duplicate identifiers and
 * duplicate destinations; truncating GGUF containers; unsupported
 * architectures; unknown fields of every estate; embedding models that will
 * not swear their pooling, normalization and dimension. An UNPINNED register
 * must be wholly unsworn: any half-pinned mixture is the very mutable-trusting
 * disease this gate keepeth out.
 */

private val HEX64 = Regex("[0-9a-f]{64}")
private val HEX40 = Regex("[0-9a-f]{40}")
private val BASENAME = Regex("[A-Za-z0-9._-]+\\.gguf")
private val IDPAT = Regex("[a-z0-9][a-z0-9_-]*")
private val REPOPAT = Regex("[A-Za-z0-9._-]+/[A-Za-z0-9._-]+")
private val FLAGPAT = Regex("-[A-Za-z0-9+=,/._%-]+")
private val TOOLVERPAT = Regex("[0-9][0-9.]*")

val TIERS = listOf("LIGHT", "MEDIUM", "LARGE")
val POOLINGS = listOf("none", "mean", "cls", "last")
val NORMALIZATIONS = listOf("none", "l2")
val KINDS = listOf("generation", "embedding")
val ABIS = listOf("arm64-v8a", "x86-64")
val STATUSES = listOf("UNPINNED", "PINNED")
val ARTIFACT_KEYS = listOf("id", "kind", "tiers", "repo", "source_commit",
    "source_file", "output_file", "sha256", "size_bytes", "license",
    "tokenizer", "context_tokens", "embedding", "native_abi")
val PROVENANCE_KEYS = listOf("source_commit", "sha256", "size_bytes", "license",
    "tokenizer", "context_tokens", "embedding", "native_abi")
val TOP_KEYS = listOf("schema", "status", "verified_on", "verified_by", "notes",
    "native", "artifacts")
val NATIVE_KEYS = listOf("llama_revision", "source_repo", "build_flags",
    "toolchains", "abis")
val EMBEDDING_KEYS = listOf("pooling", "normalization", "dimension")

class ProvenanceRefusal(message: String) : IllegalArgumentException(message)

private fun refuse(cry: String): Nothing = throw ProvenanceRefusal(cry)

private fun swear(condition: Boolean, cry: () -> String) {
    if (!condition) refuse(cry())
}

private fun shaHex(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { b -> "%02x".format(b.toInt() and 0xFF) }

class EmbeddingFingerprint(val pooling: String, val normalization: String, val dimension: Long) {
    init {
        swear(pooling in POOLINGS) { "unknown pooling '" + pooling + "': must be one of " + POOLINGS.toString() }
        swear(normalization in NORMALIZATIONS) { "unknown normalization '" + normalization + "': must be one of " + NORMALIZATIONS.toString() }
        swear(dimension > 0L) { "embedding dimension must be a positive integer, got " + dimension }
    }
}

class ContentAddressedArtifact(
    val id: String,
    val kind: String,
    val tiers: List<String>,
    val repo: String,
    val sourceCommit: String,
    val sourceFile: String,
    val outputFile: String,
    val sha256: String,
    val sizeBytes: Long,
    val licenseName: String,
    val tokenizer: String,
    val contextTokens: Long,
    val fingerprint: EmbeddingFingerprint?,
    val nativeAbi: String
) {
    init {
        swear(IDPAT.matches(id)) { "artifact id must match [a-z0-9][a-z0-9_-]*: '" + id + "'" }
        swear(kind in KINDS) { "'" + id + "': kind must be one of " + KINDS.toString() + ", got '" + kind + "'" }
        swear(tiers.isNotEmpty() && tiers.all { it in TIERS }) { "'" + id + "': tiers must be drawn from " + TIERS.toString() }
        swear(REPOPAT.matches(repo)) { "'" + id + "': repo must be 'owner/name': '" + repo + "'" }
        swear(BASENAME.matches(sourceFile)) { "'" + id + "'.source_file must be a plain .gguf basename: '" + sourceFile + "'" }
        swear(BASENAME.matches(outputFile)) { "'" + id + "'.output_file must be a plain .gguf basename without separators or traversal: '" + outputFile + "'" }
        swear(HEX40.matches(sourceCommit)) { "'" + id + "'.source_commit must be a full 40-character lower-case hexadecimal revision, never a mutable branch head such as '" + sourceCommit + "'" }
        swear(HEX64.matches(sha256)) { "'" + id + "'.sha256 must be a full 64-character lower-case hexadecimal digest" }
        swear(sizeBytes > 0L) { "'" + id + "'.size_bytes must be a positive integer" }
        swear(licenseName.isNotEmpty()) { "'" + id + "'.license must be a non-empty string" }
        swear(tokenizer.isNotEmpty()) { "'" + id + "'.tokenizer must be a non-empty string" }
        swear(contextTokens > 0L) { "'" + id + "'.context_tokens must be a positive integer" }
        swear(nativeAbi in ABIS) { "'" + id + "': native_abi '" + nativeAbi + "' is not a compatible ABI of this repository (known: " + ABIS.toString() + ")" }
        if (kind == "embedding") {
            swear(fingerprint != null) { "'" + id + "': an embedding model must swear its full fingerprint (pooling, normalization, dimension)" }
        } else {
            swear(fingerprint == null) { "'" + id + "': a generation model hath no embedding fingerprint to swear" }
        }
    }

    /** The immutable coordinate: a pinned commit, never a branch head. */
    fun url(): String =
        "https://huggingface.co/" + repo + "/resolve/" + sourceCommit + "/" + sourceFile
}

class T61Toolchain(val name: String, val version: String) {
    init {
        swear(name.isNotEmpty()) { "toolchain name must be a non-empty string" }
        swear(TOOLVERPAT.matches(version)) { "toolchain version must be dotted digits: '" + version + "'" }
    }
}

class NativeLockV1(
    val llamaRevision: String?,
    val sourceRepo: String,
    val buildFlags: List<String>,
    val toolchains: List<T61Toolchain>,
    val abis: List<String>
) {
    init {
        if (llamaRevision != null) {
            swear(HEX40.matches(llamaRevision)) { "native.llama_revision must be null or a full 40-hex revision, never a mutable branch head: '" + llamaRevision + "'" }
        }
        swear(REPOPAT.matches(sourceRepo)) { "native.source_repo must be 'owner/name': '" + sourceRepo + "'" }
        swear(buildFlags.isNotEmpty() && buildFlags.all { FLAGPAT.matches(it) }) { "native.build_flags must be non-empty -D/-f/-W tokens without separators or traversal" }
        swear(toolchains.isNotEmpty()) { "native.toolchains must be a non-empty list" }
        swear(abis.isNotEmpty() && abis.all { it in ABIS }) { "native.abis must be drawn from " + ABIS.toString() }
    }
}

class ModelLockV1(
    val schema: Long,
    val status: String,
    val verifiedOn: String?,
    val verifiedBy: String?,
    val notes: String?,
    val nativeLock: NativeLockV1,
    val blobs: List<Map<String, Any?>>,
    val artifacts: List<ContentAddressedArtifact>
) {
    init {
        swear(schema == 1L || schema == 2L) { "unsupported model-lock schema '" + schema + "'; this tool understandeth [1, 2] and refuseth every future version" }
        swear(status in STATUSES) { "lock status '" + status + "' is not one of " + STATUSES.toString() }
        swear(blobs.isNotEmpty()) { "model lock containeth no artifacts" }
        val seenIds = mutableListOf<String>()
        val seenOutputs = mutableListOf<String>()
        for (blob in blobs) {
            val id = blob["id"] as? String
            swear(id != null) { "artifact wanteth an id" }
            id!!
            swear(!seenIds.contains(id)) { "duplicate artifact id '" + id + "'" }
            seenIds.add(id)
            val output = blob["output_file"] as? String
            swear(output != null) { "'" + id + "': wanteth output_file" }
            output!!
            swear(!seenOutputs.contains(output)) { "duplicate output_file '" + output + "' (two ids, one destination is a collision)" }
            seenOutputs.add(output)
            if (schema == 2L) {
                for (key in blob.keys) {
                    swear(key in ARTIFACT_KEYS) { "artifact '" + id + "': unknown field '" + key + "'" }
                }
                for (key in ARTIFACT_KEYS) {
                    swear(blob.containsKey(key)) { "artifact '" + id + "': wanteth field '" + key + "'" }
                }
            } else {
                // the legacy estate knoweth coordinates alone
                for (key in listOf("id", "tiers", "repo", "source_file", "output_file")) {
                    swear(blob.containsKey(key)) { "artifact '" + id + "': legacy estate wanteth field '" + key + "'" }
                }
                for (key in blob.keys) {
                    swear(key in listOf("id", "tiers", "repo", "source_file", "output_file", "sha256")) {
                        "artifact '" + id + "': legacy estate knoweth not field '" + key + "'"
                    }
                }
            }
            if (status == "PINNED" && schema == 2L) {
                val art = artifactFrom(blob)
                swear(art.nativeAbi in nativeLock.abis) {
                    "artifact '" + id + "': native_abi '" + art.nativeAbi + "' is not compatible: the native lock listeth " + nativeLock.abis.toString()
                }
            } else if (status == "PINNED") {
                val sha = blob["sha256"]
                swear(sha is String && HEX64.matches(sha)) { "artifact '" + id + "': PINNED legacy artifact lacketh a valid sha256" }
            } else {
                if (schema == 2L) {
                    for (key in PROVENANCE_KEYS) {
                        swear(blob[key] == null) { "'" + id + "': the register is UNPINNED yet the provenance field '" + key + "' is sworn: verify them all or none" }
                    }
                } else {
                    val sha = blob["sha256"]
                    swear(sha == null || (sha is String && HEX64.matches(sha))) { "'" + id + "': UNPINNED legacy artifact must keep sha256 null" }
                }
                swear(IDPAT.matches(id)) { "artifact id must match [a-z0-9][a-z0-9_-]*: '" + id + "'" }
                if (schema == 2L) {
                    val kind = blob["kind"] as? String
                    swear(kind != null && kind in KINDS) { "'" + id + "': kind must be one of " + KINDS.toString() }
                }
                @Suppress("UNCHECKED_CAST")
                val tiers = blob["tiers"] as List<String>
                swear(tiers.isNotEmpty() && tiers.all { it in TIERS }) { "'" + id + "': tiers must be drawn from " + TIERS.toString() }
                val repo = blob["repo"] as? String
                swear(repo != null && REPOPAT.matches(repo)) { "'" + id + "': repo must be 'owner/name'" }
                val sf = blob["source_file"] as? String
                if (schema == 2L) {
                    swear(sf != null && BASENAME.matches(sf)) { "'" + id + "'.source_file must be a plain .gguf basename" }
                } else {
                    swear(sf is String && sf.isNotEmpty() && sf.indexOf("/") < 0) { "'" + id + "'.source_file must be a plain basename" }
                }
                if (schema == 2L) {
                    swear(BASENAME.matches(output)) { "'" + id + "'.output_file must be a plain .gguf basename" }
                } else {
                    swear(output.indexOf("/") < 0 && output != "." && output != "..") { "'" + id + "'.output_file must be a plain basename" }
                }
            }
        }
        if (status == "PINNED") {
            if (schema == 2L) {
                swear(verifiedOn != null && verifiedOn!!.isNotEmpty()) { "verified_on must be a non-empty string under the strict PINNED estate" }
                swear(verifiedBy != null && verifiedBy!!.isNotEmpty()) { "verified_by must be a non-empty string under the strict PINNED estate" }
            } else {
                swear(verifiedOn != null && verifiedOn!!.isNotEmpty() && verifiedBy != null && verifiedBy!!.isNotEmpty()) { "PINNED legacy lock lacketh verifier metadata" }
            }
        } else {
            swear(verifiedOn == null && verifiedBy == null) { "an UNPINNED lock must not name a verifier or a date: the oath belongeth to the PINNED estate only" }
        }
    }

    fun selectForTier(tier: String): List<ContentAddressedArtifact> {
        swear(schema == 2L) { "schema 1 is the legacy proposed-coordinates estate: validate only; reforge the register to schema 2 before fetch or verify" }
        swear(status == "PINNED") { "the model lock is UNPINNED; independently verify every upstream artifact and its SHA-256 before use (status must read PINNED with verified_on/verified_by sworn)" }
        swear(tier == "ALL" || tier in TIERS) { "tier must be ALL, LIGHT, MEDIUM or LARGE, got '" + tier + "'" }
        val chosen = artifacts.filter { tier == "ALL" || tier in it.tiers }
        swear(chosen.isNotEmpty()) { "no locked artifacts selected for tier '" + tier + "'" }
        return chosen
    }

    companion object {
        /** Parse the strict register; every malformed or future face is refused. */
        fun fromText(text: String): ModelLockV1 {
            val root = t61ParseJson(text)
            swear(root is Map<*, *>) { "model lock must be an object" }
            @Suppress("UNCHECKED_CAST")
            val top = root as Map<String, Any?>
            for (key in top.keys) {
                swear(key in TOP_KEYS) { "model lock: unknown top-level field '" + key + "'" }
            }
            for (key in listOf("schema", "status", "artifacts")) {
                swear(top.containsKey(key)) { "model lock wanteth field '" + key + "'" }
            }
            val schema = top["schema"] as? Long ?: refuse("model lock schema must be an integer")
            val status = top["status"] as? String ?: refuse("model lock status must be a string")
            var native: NativeLockV1
            if (schema == 1L) {
                // The legacy estate never saw the native block; the bootstrap
                // tale is the one the authority itself telleth in parity with
                // scripts/model_provenance.py.  An archived register that
                // writhe "native": {} verbatim is tolerated; a native tale
                // under the read-only estate is the very drift we refuse.
                val block = top["native"]
                if (block != null) {
                    swear(block is Map<*, *> && block.isEmpty()) {
                        "schema 1 is the legacy estate; it knoweth no native block"
                    }
                }
                native = NativeLockV1(null, "ggml-org/llama.cpp", listOf("-O0"),
                    listOf(T61Toolchain("bootstrap", "0")), listOf("arm64-v8a"))
            } else {
                // The strict estate must tell its native tale: absent, null or
                // a non-object block are all refusals alike -- the Python
                // authority confoundeth absent with null by the shape of its
                // reader, and refuseth both; so do we, by containsKey and by
                // the is-test that stayeth clear of the unchecked cast.
                val swornBlock = top["native"]
                swear(swornBlock is Map<*, *>) { "model lock wanteth field 'native'" }
                @Suppress("UNCHECKED_CAST")
                val nativeBlock = swornBlock as Map<String, Any?>
                native = nativeFrom(nativeBlock)
            }
            @Suppress("UNCHECKED_CAST")
            val list = top["artifacts"] as List<Map<String, Any?>>
            val sworn = mutableListOf<ContentAddressedArtifact>()
            if (status == "PINNED" && schema == 2L) {
                for (blob in list) sworn.add(artifactFrom(blob))
            }
            return ModelLockV1(schema, status, top["verified_on"] as? String,
                top["verified_by"] as? String, top["notes"] as? String, native, list, sworn)
        }

        private fun nativeFrom(block: Map<String, Any?>): NativeLockV1 {
            for (key in block.keys) {
                swear(key in NATIVE_KEYS) { "native block: unknown field '" + key + "'" }
            }
            for (key in NATIVE_KEYS) {
                swear(block.containsKey(key)) { "native block wanteth field '" + key + "'" }
            }
            val rev = block["llama_revision"] as? String
            val repo = block["source_repo"] as? String ?: refuse("native block wanteth source_repo")
            @Suppress("UNCHECKED_CAST")
            val flags = block["build_flags"] as List<String>
            @Suppress("UNCHECKED_CAST")
            val abis = block["abis"] as List<String>
            @Suppress("UNCHECKED_CAST")
            val tools = block["toolchains"] as List<Map<String, Any?>>
            val tcs = tools.map {
                val n = it["name"] as? String ?: refuse("toolchain entry wanteth a name")
                val v = it["version"] as? String ?: refuse("toolchain entry wanteth a version")
                for (k in it.keys) swear(k in listOf("name", "version")) { "toolchain entry: unknown field '" + k + "'" }
                T61Toolchain(n, v)
            }
            return NativeLockV1(rev, repo, flags, tcs, abis)
        }

        private fun artifactFrom(blob: Map<String, Any?>): ContentAddressedArtifact {
            for (key in blob.keys) {
                swear(key in ARTIFACT_KEYS) { "artifact '" + (blob["id"] as? String) + "': unknown field '" + key + "'" }
            }
            for (key in ARTIFACT_KEYS) {
                swear(blob.containsKey(key)) { "artifact '" + (blob["id"] as? String) + "': wanteth field '" + key + "'" }
            }
            val id = blob["id"] as? String ?: refuse("artifact wanteth an id")
            val kind = blob["kind"] as? String ?: refuse("'" + id + "': wanteth kind")
            @Suppress("UNCHECKED_CAST")
            val tiers = blob["tiers"] as List<String>
            val repo = blob["repo"] as? String ?: refuse("'" + id + "': wanteth repo")
            val sourceCommit = blob["source_commit"] as? String ?: refuse("'" + id + "': wanteth source_commit")
            val sourceFile = blob["source_file"] as? String ?: refuse("'" + id + "': wanteth source_file")
            val outputFile = blob["output_file"] as? String ?: refuse("'" + id + "': wanteth output_file")
            val sha = blob["sha256"] as? String ?: refuse("'" + id + "': wanteth sha256")
            val size = blob["size_bytes"] as? Long ?: refuse("'" + id + "': wanteth size_bytes")
            val license = blob["license"] as? String ?: refuse("'" + id + "': wanteth license")
            val tokenizer = blob["tokenizer"] as? String ?: refuse("'" + id + "': wanteth tokenizer")
            val context = blob["context_tokens"] as? Long ?: refuse("'" + id + "': wanteth context_tokens")
            val abi = blob["native_abi"] as? String ?: refuse("'" + id + "': wanteth native_abi")
            var fp: EmbeddingFingerprint? = null
            val emb = blob["embedding"]
            if (emb != null) {
                swear(emb is Map<*, *>) { "'" + id + "': embedding fingerprint must be an object" }
                @Suppress("UNCHECKED_CAST")
                val e = emb as Map<String, Any?>
                for (k in e.keys) swear(k in EMBEDDING_KEYS) { "'" + id + "': unknown embedding fingerprint field '" + k + "'" }
                val pooling = e["pooling"] as? String ?: refuse("'" + id + "': embedding wanteth pooling")
                val normalization = e["normalization"] as? String ?: refuse("'" + id + "': embedding wanteth normalization")
                val dimension = e["dimension"] as? Long ?: refuse("'" + id + "': embedding wanteth dimension")
                fp = EmbeddingFingerprint(pooling, normalization, dimension)
            }
            return ContentAddressedArtifact(id, kind, tiers, repo, sourceCommit, sourceFile,
                outputFile, sha, size, license, tokenizer, context, fp, abi)
        }
    }
}

// ---------------------------------------------------------------------------
// The strict JSON reader: duplicate keys, trailing matter, fractions,
// exponents and deep nesting are all refused. Integers arrive as Long.
// ---------------------------------------------------------------------------

private const val T61_MAX_DEPTH = 24

internal fun t61ParseJson(text: String): Any? {
    val reader = T61JsonReader(text)
    val value = reader.readValue(0)
    reader.skipBlank(0)
    swear(reader.atEnd()) { "trailing matter after the model lock document" }
    return value
}

private class T61JsonReader(private val text: String) {
    private var index = 0

    private fun fail(cry: String): Nothing = refuse("model lock JSON: " + cry + " (offset " + index + ")")

    fun atEnd(): Boolean = index >= text.length

    fun skipBlank(depth: Int) {
        while (index < text.length && text[index].let { it == ' ' || it == '\n' || it == '\t' || it == '\r' }) index += 1
    }

    private fun peek(): Char {
        if (index >= text.length) fail("document enddeth unexpectidly")
        return text[index]
    }

    private fun expect(c: Char, depth: Int) {
        if (peek() != c) fail("expected '" + c + "'")
        index += 1
    }

    fun readValue(depth: Int): Any? {
        if (depth > T61_MAX_DEPTH) fail("nesting deeper than " + T61_MAX_DEPTH)
        skipBlank(depth)
        return when (peek()) {
            '{' -> readObject(depth)
            '[' -> readArray(depth)
            '"' -> readString()
            'n' -> readLiteral("null", null)
            't' -> readLiteral("true", true)
            'f' -> readLiteral("false", false)
            else -> readNumber()
        }
    }

    private fun readObject(depth: Int): Map<String, Any?> {
        expect('{', depth)
        val out = LinkedHashMap<String, Any?>()
        skipBlank(depth)
        if (peek() == '}') { index += 1; return out }
        while (true) {
            skipBlank(depth)
            val key = readString()
            if (out.containsKey(key)) fail("duplicate key '" + key + "' in one object")
            skipBlank(depth)
            expect(':', depth)
            val value = readValue(depth + 1)
            out.put(key, value)
            skipBlank(depth)
            when (peek()) {
                ',' -> index += 1
                '}' -> { index += 1; return out }
                else -> fail("expected ',' or '}'")
            }
        }
        fail("unterminated object") // unreachable; placeth the compiler's peace
    }

    private fun readArray(depth: Int): List<Any?> {
        expect('[', depth)
        val out = mutableListOf<Any?>()
        skipBlank(depth)
        if (peek() == ']') { index += 1; return out }
        while (true) {
            out.add(readValue(depth + 1))
            skipBlank(depth)
            when (peek()) {
                ',' -> index += 1
                ']' -> { index += 1; return out }
                else -> fail("expected ',' or ']'")
            }
        }
        fail("unterminated array") // unreachable
    }

    private fun readString(): String {
        expect('"', 0)
        val out = StringBuilder()
        while (true) {
            if (index >= text.length) fail("unterminated string")
            val c = text[index]
            index += 1
            if (c == '"') return out.toString()
            if (c != '\\') { out.append(c); continue }
            if (index >= text.length) fail("unterminated escape")
            val e = text[index]
            index += 1
            when (e) {
                '"' -> out.append('"')
                '\\' -> out.append('\\')
                '/' -> out.append('/')
                'b' -> out.append('\u0008')
                'f' -> out.append('\u000C')
                'n' -> out.append('\n')
                'r' -> out.append('\r')
                't' -> out.append('\t')
                'u' -> {
                    if (index + 4 > text.length) fail("truncated \\u escape")
                    val code = text.substring(index, index + 4)
                    var value = 0
                    var walk = 0
                    while (walk < 4) {
                        val d = code[walk]
                        val digit = when {
                            d in '0'..'9' -> d - '0'
                            d in 'a'..'f' -> d - 'a' + 10
                            d in 'A'..'F' -> d - 'A' + 10
                            else -> -1
                        }
                        if (digit < 0) fail("bad hex digit in \\u escape")
                        value = value * 16 + digit
                        walk += 1
                    }
                    index += 4
                    out.append(value.toInt().toChar())
                }
                else -> fail("unknown escape '\\" + e + "'")
            }
        }
        fail("unterminated string") // unreachable
    }

    private fun startsAt(word: String): Boolean {
        if (index + word.length > text.length) return false
        var walk = 0
        while (walk < word.length) {
            if (text[index + walk] != word[walk]) return false
            walk += 1
        }
        return true
    }

    private fun readLiteral(word: String, value: Any?): Any? {
        if (!startsAt(word)) fail("expected '" + word + "'")
        index += word.length
        return value
    }

    private fun readNumber(): Long {
        val start = index
        if (peek() == '-') index += 1
        var digits = 0
        while (index < text.length && text[index].let { it in '0'..'9' }) { index += 1; digits += 1 }
        if (digits == 0) fail("malformed number")
        if (index < text.length && (text[index] == '.' || text[index] == 'e' || text[index] == 'E'))
            fail("fractional and exponent numbers have no place in a strict register")
        return text.substring(start, index).toLong()
    }
}

// ---------------------------------------------------------------------------
// GGUF header walk -- the container must tell its whole tale, or nothing is
// promoted. Parity of the walk with the Python authority and the iOS twin.
// ---------------------------------------------------------------------------

class GgufHeader(val version: Long, val nTensors: Long, val nKv: Long)

private const val GGUF_MAGIC_0 = 71   // 'G'
private const val GGUF_MAGIC_1 = 71   // 'G'
private const val GGUF_MAGIC_2 = 85   // 'U'
private const val GGUF_MAGIC_3 = 70   // 'F'
private const val T61_MAX_CHUNK = 1048576   // one mebibyte, the bounded read

private fun valueSizeOf(type: Int): Int =
    when (type) { 0, 1, 7 -> 1; 2, 3 -> 2; 4, 5, 6 -> 4; else -> -1 }

fun ggufWalk(data: ByteArray): GgufHeader {
    var at = 0
    fun take(n: Int, what: String): ByteArray {
        if (data.size - at < n) refuse("gguf header truncated: wanteth " + n + " byte(s) for " + what + ", the container holdeth but " + (data.size - at))
        val out = data.copyOfRange(at, at + n)
        at += n
        return out
    }
    fun u32(what: String): Long {
        val b = take(4, what)
        var v = 0L
        var i = 0
        while (i < 4) { v = v or ((b[i].toLong() and 0xFFL) shl (8 * i)); i += 1 }
        return v
    }
    fun u64(what: String): Long {
        val b = take(8, what)
        var v = 0L
        var i = 0
        while (i < 8) { v = v or ((b[i].toLong() and 0xFFL) shl (8 * i)); i += 1 }
        return v
    }
    fun skipString(what: String) {
        val n = u32(what + " length")
        if (n < 0L || n > T61_MAX_CHUNK) refuse(what + " length out of bounds")
        take(n.toInt(), what)
    }
    if (!(data.size >= 24 && data[0].toInt() == GGUF_MAGIC_0 && data[1].toInt() == GGUF_MAGIC_1 &&
            data[2].toInt() == GGUF_MAGIC_2 && data[3].toInt() == GGUF_MAGIC_3))
        refuse("not a GGUF container: magic mismatch")
    take(4, "magic")
    val version = u32("version")
    if (version < 1L || version > 3L) refuse("unsupported GGUF version " + version + "; this walk understandeth 1..3")
    val nTensors = u64("n_tensors")
    val nKv = u64("n_kv")
    if (nTensors > 65536L || nKv > 4096L) refuse("implausible header counts (n_tensors=" + nTensors + ", n_kv=" + nKv + ")")
    var k = 0L
    while (k < nKv) {
        skipString("metadata key")
        val vtype = take(1, "metadata value type")[0].toInt() and 0xFF
        if ((vtype and 0xF8) == 0) {
            take(valueSizeOf(vtype), "metadata value")
        } else if (vtype == 8) {
            val elem = take(1, "array element type")[0].toInt() and 0xFF
            if ((elem and 0xF8) != 0) refuse("unknown GGUF array element type " + elem)
            val count = u32("array count")
            if (count * valueSizeOf(elem) > 1073741824L) refuse("array byte count out of bounds")
            take((count * valueSizeOf(elem)).toInt(), "array bytes")
        } else {
            refuse("unknown GGUF metadata value type " + vtype)
        }
        k += 1L
    }
    var seen = 0L
    while (seen < nTensors) {
        skipString("tensor name")
        val nDims = u32("tensor n_dims")
        if (nDims > 16L) refuse("implausible tensor rank " + nDims)
        take((8L * nDims).toInt(), "tensor dimensions")
        take(1, "tensor type")
        take(8, "tensor offset")
        seen += 1L
    }
    if (seen != nTensors) refuse("GGUF tensor count mismatch: header promised " + nTensors + ", the walk fond " + seen)
    return GgufHeader(version, nTensors, nKv)
}

/** The content-addressed law: digest, length AND header -- never the name. */
fun verifyContentAddressed(artifact: ContentAddressedArtifact, data: ByteArray): List<String> {
    val cries = mutableListOf<String>()
    val digest = shaHex(data)
    if (digest != artifact.sha256) {
        cries.add(artifact.outputFile + ": content digest mismatch -- the lock sweareth " +
            artifact.sha256 + ", the bytes answer to " + digest +
            " (a file of the same name and length is NOT the sworn content)")
    }
    if (data.size.toLong() != artifact.sizeBytes) {
        cries.add(artifact.outputFile + ": length mismatch -- the lock sweareth " +
            artifact.sizeBytes + " byte(s), the bytes count " + data.size)
    }
    try {
        ggufWalk(data)
    } catch (mischief: ProvenanceRefusal) {
        cries.add(artifact.outputFile + ": " + mischief.message)
    }
    return cries
}
