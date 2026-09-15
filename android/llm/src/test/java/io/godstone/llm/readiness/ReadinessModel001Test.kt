package io.godstone.llm.readiness

// GS-MODEL-001: the provenance identity is REQUIRED, and the staging verifieth against it.
//
// The audit reproduced the opposite on these very sources: `ModelStaging.stage(..., artifact = null)`
// ACCEPTED an existing garbage `.gguf` (its `if (artifact != null)` guard skipped verification and
// returned the destination) and transferreth an unpinned stream under `Long.MAX_VALUE` -- under NO
// ceiling at all. The repair madeth the parameter REQUIRED, so the unpinned road cannot be taken; the
// arms below witness the law that remaineth, and W03 witnesseth the REQUIREMENT itself.
import io.godstone.llm.provenance.ContentAddressedArtifact
import io.godstone.llm.provenance.ModelStaging
import io.godstone.llm.provenance.ProvenanceRefusal
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File

class ReadinessModel001Test {

    private fun temp(name: String): File =
        File.createTempFile(name, ".dir").also { it.delete(); it.mkdirs() }

    /** An artifact whose declared identity describeth OTHER bytes. */
    private fun artifactOf(sizeBytes: Long, sha256: String = "0".repeat(64)) =
        ContentAddressedArtifact(
            id = "GATE-FIXTURE", kind = "model", tiers = listOf("LIGHT"),
            repo = "fixture", sourceCommit = "0".repeat(40), sourceFile = "fixture.gguf",
            outputFile = "fixture.gguf", sha256 = sha256, sizeBytes = sizeBytes,
            licenseName = "fixture", tokenizer = "fixture", contextTokens = 2048,
            fingerprint = null, nativeAbi = "arm64-v8a",
        )

    /** W01 -- an existing file that doth NOT answer to the sworn artifact is REFUSED. */
    @Test fun test_w01_an_existing_file_that_doth_not_answer_the_artifact_is_refused() {
        val destination = File(temp("model001-mismatch"), "model.gguf")
        destination.writeBytes(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8))   // not a GGUF, and not this sha
        try {
            ModelStaging().stage({ ByteArrayInputStream(ByteArray(0)) }, destination,
                                 artifactOf(sizeBytes = 8L))
            org.junit.Assert.fail(
                "an existing garbage model was accepted although it doth not answer the sworn " +
                    "artifact (GS-MODEL-001)")
        } catch (_expected: ProvenanceRefusal) {
            // the refusal: no provenance match, no usable model
        }
        assertTrue("the refusal must not delete the operator's bytes", destination.exists())
    }

    /** W02 -- the transfer ceiling is the ARTIFACT's own size: a longer stream is refused. */
    @Test fun test_w02_a_stream_longer_than_the_artifact_is_refused() {
        val destination = File(temp("model001-ceiling"), "model.gguf")
        val stream = ByteArray(1 shl 16)          // 64 KiB, while the artifact declareth 1 KiB
        try {
            ModelStaging().stage({ ByteArrayInputStream(stream) }, destination,
                                 artifactOf(sizeBytes = 1L shl 10))
            org.junit.Assert.fail("a stream longer than the declared size was accepted whole " +
                "(the audit's unbounded ceiling, GS-MODEL-001)")
        } catch (_expected: ProvenanceRefusal) {
            // the ceiling is structural: artifact.sizeBytes, never Long.MAX_VALUE
        }
    }

    /** W03 -- THE REQUIREMENT ITSELF: neither the staging nor the manager may offer a null road. */
    @Test fun test_w03_the_law_carrieth_no_optional_identity() {
        val staging = File(repoFile("android/llm/src/main/java/io/godstone/llm/provenance/ModelStaging.kt")).readText()
        val manager = File(repoFile("android/llm/src/main/java/io/godstone/llm/ModelManager.kt")).readText()
        assertTrue("the staging parameter must be REQUIRED, not nullable",
            staging.contains("artifact: ContentAddressedArtifact)") &&
                !staging.contains("artifact: ContentAddressedArtifact?"))
        // the CODE is read, not the prose: this file's own comment QUOTES the audited ceiling to
        // explain why it was removed, and a scan that cannot tell a bound from the sentence that
        // describeth it would fail on a correct file (the lesson this session taught three times).
        val code = staging.lines()
            .map { line -> line.substringBefore("//") }      // a TRAILING comment is prose too
            .filterNot { line ->
                val trimmed = line.trimStart()
                trimmed.startsWith("*") || trimmed.startsWith("/*")
            }.joinToString("\n")
        assertTrue("Long.MAX_VALUE must not be a transfer ceiling",
            !code.contains("Long.MAX_VALUE"))
        assertTrue("the manager's identity must be REQUIRED at construction",
            manager.contains("private val artifact: ContentAddressedArtifact") &&
                !manager.contains("private val artifact: ContentAddressedArtifact?"))
    }

    private fun repoFile(rel: String): String {
        var probe = File(System.getProperty("user.dir")).absoluteFile
        while (probe != null) {
            if (File(probe, rel).isFile) return File(probe, rel).absolutePath
            probe = probe.parentFile
        }
        error("$rel not found from " + System.getProperty("user.dir"))
    }
}
