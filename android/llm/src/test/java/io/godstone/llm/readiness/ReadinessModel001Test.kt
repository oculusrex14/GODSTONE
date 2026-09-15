package io.godstone.llm.readiness

// GS-MODEL-001: runtime model staging must not be a lawful road to a usable model WITHOUT a sworn
// artifact identity. The audit reproduced, on these very sources:
//   * `ModelStaging.stage(..., artifact = null)` over an EXISTING GARBAGE file ACCEPTS it and
//     publishes the garbage `.gguf`;
//   * the null path useth `Long.MAX_VALUE` as its transfer CEILING, so an unpinned stream is
//     unbounded.
// The GGUF parser's refusal of garbage is the audit's POSITIVE CONTROL: it proveth that the
// parser is not the hole, and that any repair which merely refuseth everything is wrong.
import io.godstone.llm.provenance.ModelStaging
import io.godstone.llm.provenance.ProvenanceRefusal
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File

class ReadinessModel001Test {

    private fun temp(name: String): File =
        File.createTempFile(name, ".dir").also { it.delete(); it.mkdirs() }

    /** W01 -- THE AUDIT'S OWN ARM: an existing garbage model must not survive an unpinned stage. */
    @Test fun test_w01_an_existing_garbage_model_is_refused_even_without_a_sworn_artifact() {
        val root = temp("model001-garbage")
        val destination = File(root, "model.gguf")
        destination.writeBytes(byteArrayOf(1, 2, 3, 4, 5, 6, 7, 8))   // not a GGUF
        val staging = ModelStaging()
        try {
            staging.stage({ ByteArrayInputStream(ByteArray(0)) }, destination, artifact = null)
            org.junit.Assert.fail(
                "an EXISTING GARBAGE model was accepted without a sworn artifact: the audit's " +
                    "reproduced defect (GS-MODEL-001)")
        } catch (_expected: ProvenanceRefusal) {
            // the refusal: no provenance, no usable model
        }
        assertTrue("the refusal must not delete the operator's bytes", destination.exists())
    }

    /** W02 -- no unpinned stream may be transferred under an UNBOUNDED ceiling. */
    @Test fun test_w02_an_unpinned_stream_carrieth_a_bounded_ceiling() {
        val root = temp("model001-ceiling")
        val destination = File(root, "model.gguf")
        // 64 MiB of zeros: far past any sane model ceiling for a LIGHT asset, and no artifact sworn
        val giant = ByteArray(1 shl 20)
        val staging = ModelStaging()
        try {
            staging.stage({ ByteArrayInputStream(giant) }, destination, artifact = null)
            assertFalse("an unpinned stream of 64 MiB was accepted whole", destination.exists())
        } catch (_expected: ProvenanceRefusal) {
            // a bounded ceiling refused it, which is the law this arm defendeth
        }
    }
}
