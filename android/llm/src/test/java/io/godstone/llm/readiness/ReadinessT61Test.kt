package io.godstone.llm.readiness

import io.godstone.llm.provenance.CancellationToken
import io.godstone.llm.provenance.ContentAddressedArtifact
import io.godstone.llm.provenance.EmbeddingFingerprint
import io.godstone.llm.provenance.ModelLockV1
import io.godstone.llm.provenance.ModelStaging
import io.godstone.llm.provenance.PROVENANCE_KEYS
import io.godstone.llm.provenance.ProvenanceRefusal
import io.godstone.llm.provenance.StreamGate
import io.godstone.llm.provenance.ggufWalk
import io.godstone.llm.provenance.verifyContentAddressed
import java.io.File
import java.io.InputStream
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertFailsWith
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

/*
 * T61 readiness court, Android isle -- the twin of the iOS
 * ReadinessT61Tests and of the tested Python authority
 * scripts/model_provenance.py. The required cases of the card are tried
 * here upon the real production classes: the strict register's refusals
 * (wrong or missing hash, mutable revision, licence absent, path traversal,
 * duplicate identifiers, unsupported architecture), the content-addressed
 * law (a truncated GGUF is refused though the name and the length agree;
 * the file name and the length alone are not trusted), the bounded
 * temporary with atomic promotion (repeated restore determinist; an
 * interruption preserveth the prior authoritative state), and the consumer's
 * cancellation token standing independent of every worker queue.
 */

private const val T61_COMMIT40 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
private const val T61_SHA_A = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

private val T61_PRINTABLES: String = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

private fun t61Q(s: String): String = "\"" + s + "\""

private fun t61Scratch(name: String): File {
    val dir = File("/tmp/" + name + "-" + System.nanoTime())
    dir.mkdirs()
    dir.deleteOnExit()
    return dir
}

private fun t61RepoRoot(): File {
    var dir = File(System.getProperty("user.dir")).absoluteFile
    while (dir != null && !(File(dir, "scripts").isDirectory() && File(File(dir, "docs"), "packaging").isDirectory()))
        dir = dir.parentFile
    if (dir == null) throw ProvenanceRefusal("the repository root is not to be fond")
    return dir
}

private fun t61ReadUnder(root: File, vararg parts: String): String {
    var f = root
    var i = 0
    while (i < parts.size) { f = File(f, parts[i]); i += 1 }
    if (!f.isFile()) throw ProvenanceRefusal("no such face to read: " + f.absolutePath)
    return f.readText()
}

private fun t61Ord(c: Char): Int {
    val k = T61_PRINTABLES.indexOf(c)
    if (k < 0) throw ProvenanceRefusal("character out of the printable tale: " + c)
    return k + 32
}
private fun t61ShaHex(bytes: ByteArray): String =
    java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
        .joinToString("") { b -> "%02x".format(b.toInt() and 0xFF) }

/** The synthetic vessel: a GGUF container the header walk must finish wholly. */
private fun t61Gguf(version: Long, nTensors: Long, nKv: Long, tail: Boolean): ByteArray {
    val out = mutableListOf<Byte>()
    fun putByte(value: Int) { out.add((value and 0xFF).toByte()) }
    fun putLe(value: Long, width: Int) {
        var i = 0
        while (i < width) { putByte(((value shr (8 * i)) and 0xFF).toInt()); i += 1 }
    }
    fun putWord(word: String) {
        var i = 0
        while (i < word.length) { putByte(t61Ord(word[i])); i += 1 }
    }
    fun putField(word: String) { putLe(word.length.toLong(), 4); putWord(word) }
    putWord("GGUF")
    putLe(version, 4)
    putLe(nTensors, 8)
    putLe(nKv, 8)
    if (nKv >= 1L) {
        putField("general.name")
        putByte(8); putByte(4); putLe(2L, 4); putLe(7L, 4); putLe(11L, 4)
    }
    if (nKv >= 2L) {
        putField("tokenizer.ggml.add_bos")
        putByte(7); putByte(1)
    }
    var t = 0L
    while (t < nTensors) {
        putField("blk." + t + ".weight")
        putLe(2L, 4)
        putLe(64L, 8); putLe(32L, 8)
        putByte(10)
        putLe(4096L * t, 8)
        t += 1L
    }
    if (tail) { putByte(0); putByte(0) }
    return out.toByteArray()
}

private fun t61Artifact(sha: String, size: Long, abi: String): ContentAddressedArtifact =
    ContentAddressedArtifact("generation-court", "generation", listOf("LIGHT"),
        "court-synthesists/fake-models", T61_COMMIT40, "Court.gguf", "court.gguf",
        sha, size, "apache-2.0", "gpt2", 2048L, null, abi)

private fun t61ArtifactJson(idF: String, kindF: String, tiersF: String, repoF: String,
    commitF: String, sourceF: String, outputF: String, shaF: String, sizeF: String,
    licenceF: String, tokenizerF: String, contextF: String, embeddingF: String,
    abiF: String): String =
    "{" +
        "\"id\": " + idF + ", " +
        "\"kind\": " + kindF + ", " +
        "\"tiers\": " + tiersF + ", " +
        "\"repo\": " + repoF + ", " +
        "\"source_commit\": " + commitF + ", " +
        "\"source_file\": " + sourceF + ", " +
        "\"output_file\": " + outputF + ", " +
        "\"sha256\": " + shaF + ", " +
        "\"size_bytes\": " + sizeF + ", " +
        "\"license\": " + licenceF + ", " +
        "\"tokenizer\": " + tokenizerF + ", " +
        "\"context_tokens\": " + contextF + ", " +
        "\"embedding\": " + embeddingF + ", " +
        "\"native_abi\": " + abiF +
    "}"

private fun t61GoodArtifactJson(): String = t61ArtifactJson(
    t61Q("generation-court"), t61Q("generation"), "[\"LIGHT\", \"MEDIUM\", \"LARGE\"]",
    t61Q("court-synthesists/fake-models"), t61Q(T61_COMMIT40), t61Q("Court.gguf"),
    t61Q("court.gguf"), t61Q(T61_SHA_A), "7", t61Q("apache-2.0"), t61Q("gpt2"),
    "2048", "null", t61Q("arm64-v8a"))

private fun t61NativeTale(): String =
    "{ \"llama_revision\": null, " +
    "\"source_repo\": \"ggml-org/llama.cpp\", " +
    "\"build_flags\": [\"-O3\", \"-ffast-math\", \"-funroll-loops\", \"-fno-exceptions\", \"-fno-rtti\"], " +
    "\"toolchains\": [{\"name\": \"ndk\", \"version\": \"27.0.12077973\"}, " +
    "{\"name\": \"cmake\", \"version\": \"3.22.1\"}], " +
    "\"abis\": [\"arm64-v8a\"] }"

private fun t61LockJson(schemaF: String, statusF: String, verifiedOnF: String,
    verifiedByF: String, nativeF: String, bodies: String, extraTop: String): String =
    "{" +
        "\"schema\": " + schemaF + ", " +
        "\"status\": " + statusF + ", " +
        "\"verified_on\": " + verifiedOnF + ", " +
        "\"verified_by\": " + verifiedByF + ", " +
        "\"notes\": null, " +
        "\"native\": " + nativeF + ", " +
        "\"artifacts\": [" + bodies + "]" + extraTop +
    "}"

private fun t61LegacyDoc(nativeFragment: String): String {
    val nativePart = if (nativeFragment.isEmpty()) "" else "\"native\": " + nativeFragment + ", "
    return "{\"schema\": 1, \"status\": \"UNPINNED\", \"verified_on\": null, " +
        "\"verified_by\": null, " + nativePart + "\"notes\": null, \"artifacts\": [{" +
        "\"id\": \"generation-light\", \"tiers\": [\"LIGHT\"], " +
        "\"repo\": \"Qwen/Qwen3-0.6B-GGUF\", " +
        "\"source_file\": \"Qwen3-0.6B-Q4_K_M.gguf\", " +
        "\"output_file\": \"qwen3-0.6b-q4km.gguf\", \"sha256\": null}]}"
}

private fun t61GoodLockJson(): String =
    t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"), t61Q("the court's own eye"),
        t61NativeTale(), t61GoodArtifactJson(), "")

private fun t61AnyCries(cries: List<String>, needle: String): Boolean {
    var i = 0
    while (i < cries.size) { if (cries[i].indexOf(needle) >= 0) return true; i += 1 }
    return false
}

private fun t61CountParts(dir: File): Int {
    val names = dir.list()
    if (names == null) return 0
    var n = 0
    var i = 0
    while (i < names.size) { if (names[i].indexOf(".part") >= 0) n += 1; i += 1 }
    return n
}

private class T61ScriptedStream(private val words: List<ByteArray>, private val burst: Int) : InputStream() {
    private var chunk = 0
    private var pos = 0

    override fun read(): Int {
        val one = ByteArray(1)
        val got = read(one, 0, 1)
        if (got <= 0) return -1
        return one[0].toInt() and 0xFF
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (burst >= 0 && chunk >= burst) throw ProvenanceRefusal("the well runneth dry mid-transfer")
        if (chunk >= words.size) return -1
        val word = words[chunk]
        var n = word.size - pos
        if (len < n) n = len
        var i = 0
        while (i < n) { b[off + i] = word[pos + i]; i += 1 }
        pos += n
        if (pos >= word.size) { chunk += 1; pos = 0 }
        return n
    }

    override fun close() {}
}

class ReadinessT61Test {

    @Test fun testWrongDigestIsRefusedAndNothingStandethPromoted() {
        val good = t61Gguf(3L, 2L, 2L, false)
        val foul = good.copyOfRange(0, good.size)
        foul[good.size - 1] = ((foul[good.size - 1].toInt() + 7) and 0xFF).toByte()
        val art = t61Artifact(t61ShaHex(good), good.size.toLong(), "arm64-v8a")
        val dir = t61Scratch("t61-w01")
        assertFailsWith<IllegalArgumentException> { ModelStaging().restore(art, foul, dir) }
        assertFalse(File(dir, art.outputFile).exists())
        assertTrue(t61CountParts(dir) == 0)
    }

    @Test fun testMissingHashFieldIsRefusedAtTheRegisterDoor() {
        val body = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(T61_COMMIT40),
            t61Q("Court.gguf"), t61Q("court.gguf"), "null", "7", t61Q("apache-2.0"),
            t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), body, ""))
        }
    }

    @Test fun testShortHexDigestIsRefusedAtTheRegisterDoor() {
        val body = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(T61_COMMIT40),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(T61_SHA_A + "0"), "7", t61Q("apache-2.0"),
            t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), body, ""))
        }
    }

    @Test fun testMutableBranchHeadCoordinateIsRefused() {
        val body = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q("main"),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(T61_SHA_A), "7",
            t61Q("apache-2.0"), t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), body, ""))
        }
        val art = t61Artifact(t61ShaHex(t61Gguf(3L, 2L, 2L, false)), 214L, "arm64-v8a")
        assertContains(art.url(), "/resolve/" + T61_COMMIT40 + "/")
        assertFalse(art.url().indexOf("/main/") >= 0)
    }

    @Test fun testAbsentLicenceOathIsRefused() {
        val body = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(T61_COMMIT40),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(T61_SHA_A), "7", "null",
            t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), body, ""))
        }
    }

    @Test fun testPathTraversalIsRefusedAtBothDoors() {
        val traversalOut = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(T61_COMMIT40),
            t61Q("Court.gguf"), t61Q("../evil.gguf"), t61Q(T61_SHA_A), "7",
            t61Q("apache-2.0"), t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), traversalOut, ""))
        }
        val traversalSource = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(T61_COMMIT40),
            t61Q("../Court.gguf"), t61Q("court.gguf"), t61Q(T61_SHA_A), "7",
            t61Q("apache-2.0"), t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), traversalSource, ""))
        }
    }

    @Test fun testTruncatedGgufIsRefusedThoughNameAndLengthAgree() {
        val good = t61Gguf(3L, 2L, 2L, false)
        val trunc = good.copyOfRange(0, good.size - 20)
        val art = t61Artifact(t61ShaHex(trunc), trunc.size.toLong(), "arm64-v8a")
        assertFailsWith<IllegalArgumentException> { ggufWalk(trunc) }
        val cries = verifyContentAddressed(art, trunc)
        assertTrue(cries.isNotEmpty())
        assertTrue(t61AnyCries(cries, "truncated"))
        val dir = t61Scratch("t61-w06")
        assertFailsWith<IllegalArgumentException> { ModelStaging().restore(art, trunc, dir) }
        assertFalse(File(dir, art.outputFile).exists())
    }

    @Test fun testDuplicateIdentifiersAreRefused() {
        val body = t61GoodArtifactJson()
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), body + ", " + body, ""))
        }
        val twin = t61ArtifactJson(t61Q("generation-court-twin"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(T61_COMMIT40),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(T61_SHA_A), "7",
            t61Q("apache-2.0"), t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), body + ", " + twin, ""))
        }
    }

    @Test fun testUnsupportedArchitectureIsRefused() {
        val offList = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(T61_COMMIT40),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(T61_SHA_A), "7",
            t61Q("apache-2.0"), t61Q("gpt2"), "2048", "null", t61Q("riscv-9"))
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), offList, ""))
        }
        val unlisted = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(T61_COMMIT40),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(T61_SHA_A), "7",
            t61Q("apache-2.0"), t61Q("gpt2"), "2048", "null", t61Q("x86-64"))
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), unlisted, ""))
        }
    }

    @Test fun testRepeatedRestoreIsDeterministAndLeavethNoTemporary() {
        val good = t61Gguf(3L, 2L, 2L, false)
        val art = t61Artifact(t61ShaHex(good), good.size.toLong(), "arm64-v8a")
        val dir = t61Scratch("t61-w09")
        val first = ModelStaging().restore(art, good, dir)
        val second = ModelStaging().restore(art, good, dir)
        assertEquals(first.absolutePath, second.absolutePath)
        assertEquals(t61ShaHex(good), t61ShaHex(first.readBytes()))
        assertEquals(t61ShaHex(good), t61ShaHex(second.readBytes()))
        assertTrue(t61CountParts(dir) == 0)
        assertTrue(File(dir, art.outputFile).exists())
    }

    @Test fun testFileNameAndLengthAloneAreNotTrusted() {
        val good = t61Gguf(3L, 2L, 2L, false)
        val foul = good.copyOfRange(0, good.size)
        foul[good.size - 1] = ((foul[good.size - 1].toInt() + 9) and 0xFF).toByte()
        assertEquals(good.size, foul.size)
        val art = t61Artifact(t61ShaHex(good), good.size.toLong(), "arm64-v8a")
        val cries = verifyContentAddressed(art, foul)
        assertEquals(1, cries.size)
        assertTrue(t61AnyCries(cries, "digest"))
        val dir = t61Scratch("t61-w10")
        assertFailsWith<IllegalArgumentException> { ModelStaging().restore(art, foul, dir) }
        assertFalse(File(dir, art.outputFile).exists())
        assertTrue(t61CountParts(dir) == 0)
    }

    @Test fun testCorruptStandingFileIsNotOverwrittenByTheSwornGate() {
        val good = t61Gguf(3L, 2L, 2L, false)
        val foul = good.copyOfRange(0, good.size)
        foul[good.size - 1] = ((foul[good.size - 1].toInt() + 7) and 0xFF).toByte()
        val art = t61Artifact(t61ShaHex(good), good.size.toLong(), "arm64-v8a")
        val dir = t61Scratch("t61-w11")
        dir.mkdirs()
        val standing = File(dir, art.outputFile)
        standing.outputStream().use { sink -> sink.write(foul) }
        assertFailsWith<IllegalArgumentException> { ModelStaging().restore(art, good, dir) }
        assertTrue(t61ShaHex(foul) == t61ShaHex(standing.readBytes()))
        assertTrue(t61CountParts(dir) == 0)
    }

    @Test fun testInterruptionMidStagingLeavethNoAuthoritativeTrace() {
        val good = t61Gguf(3L, 2L, 2L, false)
        val art = t61Artifact(t61ShaHex(good), good.size.toLong(), "arm64-v8a")
        val words = mutableListOf<ByteArray>()
        var at = 0
        while (at < good.size) {
            val n = if (good.size - at < 24) good.size - at else 24
            words.add(good.copyOfRange(at, at + n))
            at += n
        }
        assertTrue(words.size >= 2)
        val dir = t61Scratch("t61-w12")
        dir.mkdirs()
        val doomed = File(dir, art.outputFile)
        assertFailsWith<IllegalArgumentException> {
            ModelStaging().stage({ name -> T61ScriptedStream(words, 1) }, doomed, art)
        }
        assertFalse(doomed.exists())
        assertTrue(t61CountParts(dir) == 0)
        val gentle = ModelStaging().stage({ name -> T61ScriptedStream(words, -1) }, doomed, art)
        assertTrue(gentle.exists())
        assertEquals(t61ShaHex(good), t61ShaHex(gentle.readBytes()))
        assertTrue(t61CountParts(dir) == 0)
    }

    @Test fun testEmbeddingFingerprintLawsAreEnforced() {
        assertFailsWith<IllegalArgumentException> { EmbeddingFingerprint("meanq", "l2", 384L) }
        assertFailsWith<IllegalArgumentException> { EmbeddingFingerprint("mean", "l1", 384L) }
        assertFailsWith<IllegalArgumentException> { EmbeddingFingerprint("mean", "l2", 0L) }
        val sworn = EmbeddingFingerprint("mean", "l2", 384L)
        assertEquals(384L, sworn.dimension)
        assertEquals("mean", sworn.pooling)
        assertEquals("l2", sworn.normalization)
        val sha = t61ShaHex(t61Gguf(3L, 2L, 2L, false))
        assertFailsWith<IllegalArgumentException> {
            ContentAddressedArtifact("embedding-court", "generation", listOf("LIGHT"),
                "court-synthesists/fake-models", T61_COMMIT40, "Court.gguf", "court.gguf",
                sha, 214L, "apache-2.0", "gpt2", 2048L, sworn, "arm64-v8a")
        }
        assertFailsWith<IllegalArgumentException> {
            ContentAddressedArtifact("embedding-court", "embedding", listOf("LIGHT"),
                "court-synthesists/fake-models", T61_COMMIT40, "Court.gguf", "court.gguf",
                sha, 214L, "apache-2.0", "gpt2", 2048L, null, "arm64-v8a")
        }
    }

    @Test fun testTheTokenCeasethForwardingAndTheGateKeepethRecord() {
        val token = CancellationToken()
        val gate = StreamGate(token)
        assertTrue(gate.forward("the "))
        assertTrue(gate.forward("quick "))
        assertEquals(2, gate.forwardedCount)
        assertTrue(token.cancel())
        assertFalse(token.cancel())
        assertFalse(gate.forward("brown "))
        assertEquals(2, gate.forwardedCount)
        val second = StreamGate(token)
        assertFalse(second.forward("fox"))
        val free = StreamGate(CancellationToken())
        assertTrue(free.forward("jumps"))
        assertEquals(1, free.forwardedCount)
    }

    @Test fun testTheNativeTaleIsToldFromTheBuildFiles() {
        val lock = ModelLockV1.fromText(t61GoodLockJson())
        assertEquals(2L, lock.schema)
        assertEquals("PINNED", lock.status)
        val tale = lock.nativeLock
        assertTrue(tale.llamaRevision == null)
        assertEquals("ggml-org/llama.cpp", tale.sourceRepo)
        assertEquals(listOf("arm64-v8a"), tale.abis)
        assertEquals(5, tale.buildFlags.size)
        assertTrue(t61AnyCries(tale.buildFlags, "-O3"))
        assertTrue(t61AnyCries(tale.buildFlags, "-fno-exceptions"))
        assertTrue(t61AnyCries(tale.buildFlags, "-fno-rtti"))
        assertTrue(t61AnyCries(tale.buildFlags, "-ffast-math"))
        assertTrue(t61AnyCries(tale.buildFlags, "-funroll-loops"))
        assertEquals(2, tale.toolchains.size)
        assertEquals("ndk", tale.toolchains[0].name)
        assertEquals("27.0.12077973", tale.toolchains[0].version)
        assertEquals("cmake", tale.toolchains[1].name)
        assertEquals("3.22.1", tale.toolchains[1].version)
    }

    @Test fun testTheBridgeKeepethOneWorkerAndTheGateWordsAtSeethe() {
        val root = t61RepoRoot()
        val lb = t61ReadUnder(root, "android", "llm", "src", "main", "java", "io", "godstone",
            "llm", "LlamaBridge.kt")
        assertContains(lb, "var handle: Long = 0L")
        assertContains(lb, "if (isLoaded) return true")
        assertContains(lb, "val gate = StreamGate(token)")
        assertContains(lb, "if (gate.forward(piece)) trySend(piece)")
        val mm = t61ReadUnder(root, "android", "llm", "src", "main", "java", "io", "godstone",
            "llm", "ModelManager.kt")
        assertContains(mm, "private val staging = ModelStaging()")
        assertContains(mm, "staging.stage(")
        assertContains(mm, "private val artifact: ContentAddressedArtifact? = null")
    }

    @Test fun testThePythonAuthorityKeepethItsFaceClean() {
        val root = t61RepoRoot()
        val py = t61ReadUnder(root, "scripts", "model_provenance.py")
        assertContains(py, "def gguf_verify")
        assertContains(py, "def verify_content_addressed")
        assertContains(py, "def restore")
        assertContains(py, "os.replace")
        assertContains(py, "/resolve/")
        assertContains(py, "UNPINNED")
        assertFalse(py.indexOf("mapfile") >= 0)
        val sh = t61ReadUnder(root, "scripts", "fetch_models.sh")
        assertFalse(sh.indexOf("mapfile") >= 0)
        assertFalse(sh.indexOf("MODELS=(") >= 0)
        assertContains(sh, "model_provenance.py")
        assertContains(sh, "lock.get(\"status\")")
        assertContains(sh, "!= \"PINNED\"")
    }

    @Test fun testTheShippedRegisterIsUnpinnedAndWhollyUnsworn() {
        val text = t61ReadUnder(t61RepoRoot(), "docs", "packaging", "MODELS.lock.json")
        val lock = ModelLockV1.fromText(text)
        assertEquals(2L, lock.schema)
        assertEquals("UNPINNED", lock.status)
        assertEquals(5, lock.blobs.size)
        assertTrue(lock.artifacts.isEmpty())
        var i = 0
        while (i < lock.blobs.size) {
            val b = lock.blobs[i]
            var k = 0
            while (k < PROVENANCE_KEYS.size) {
                assertTrue(b[PROVENANCE_KEYS[k]] == null)
                k += 1
            }
            i += 1
        }
        val ids = mutableListOf<String>()
        var j = 0
        while (j < lock.blobs.size) { ids.add(lock.blobs[j]["id"] as String); j += 1 }
        assertEquals(listOf("generation-light", "generation-medium", "generation-large",
            "embedding-small", "embedding-base"), ids)
        assertNotEquals(lock.status, "PINNED")
        assertTrue(lock.nativeLock.llamaRevision == null)
    }

    @Test fun testUnknownFieldsAndFutureSchemasAreRefused() {
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("3", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), t61GoodArtifactJson(), "")) }
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(), t61GoodArtifactJson(),
                ", \"future_field\": true"))
        }
        val surcharged = t61ArtifactJson(t61Q("generation-court"), t61Q("generation"),
            "[\"LIGHT\"]", t61Q("court-synthesists/fake-models"), t61Q(T61_COMMIT40),
            t61Q("Court.gguf"), t61Q("court.gguf"), t61Q(T61_SHA_A), "7",
            t61Q("apache-2.0"), t61Q("gpt2"), "2048", "null", t61Q("arm64-v8a"))
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), t61NativeTale(),
                surcharged.substring(0, surcharged.length - 1) + ", \"surcharge\": true}", ""))
        }
    }

    @Test fun testLegacySchemaOneIsTheReadonlyEstate() {
        val lock = ModelLockV1.fromText(t61LegacyDoc(""))
        assertEquals(1L, lock.schema)
        assertEquals("UNPINNED", lock.status)
        assertTrue(lock.artifacts.isEmpty())
        assertFailsWith<IllegalArgumentException> { lock.selectForTier("ALL") }
        // an archived register that writhe "native": {} verbatim is tolerated
        assertEquals(1L, ModelLockV1.fromText(t61LegacyDoc("{}")).schema)
        // a native tale under the read-only estate is the very drift refused
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LegacyDoc("{\"abis\": [\"arm64-v8a\"]}"))
        }
        // the strict estate keeping silent about its native tale is refused --
        // present-null and absent are refusals alike, as with the authority
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), "null", t61GoodArtifactJson(), ""))
        }
        assertFailsWith<IllegalArgumentException> {
            ModelLockV1.fromText(t61LockJson("2", t61Q("PINNED"), t61Q("2026-09-13"),
                t61Q("the court's own eye"), "\"llama.cpp\"", t61GoodArtifactJson(), ""))
        }
    }
}
