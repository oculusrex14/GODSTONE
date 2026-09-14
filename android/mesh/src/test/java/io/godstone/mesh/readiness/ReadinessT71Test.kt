// T71 readiness court (android isle) -- bounded diagnostics without private
// telemetry, the twin of the python conductor and the iOS contract.
//
// THE SENTINEL LAW: private sentinels are injected into the data being measured and
// must appear NOWHERE in the output -- under tampered data, ten-thousand-peer churn,
// a queue flood, a large archive and a cancelled inference.
package io.godstone.mesh.readiness

import io.godstone.mesh.diag.Diagnostics
import io.godstone.mesh.diag.DiagnosticsMode
import io.godstone.mesh.diag.DiagnosticsRefusal
import org.junit.Assert
import org.junit.Test
import java.util.regex.Pattern

class ReadinessT71Test {
    private val sentinelBody = "SENTINEL-BODY-do-not-log-me-4417"
    private val sentinelKey = "SENTINEL-KEY-do-not-log-me-8823"
    private val sentinelNodeId = "SENTINEL-NODE-do-not-log-me-1193"

    private fun live(capacity: Int = Diagnostics.RING_CAPACITY): Diagnostics =
        Diagnostics(capacity = capacity).also { it.enable() }

    // ------------------------------------------------------------ W01

    /** W01 -- the recorder is OPT-IN, and OFF recordeth nothing. */
    @Test
    fun test_w01_the_recorder_is_opt_in() {
        val quiet = Diagnostics()
        Assert.assertFalse(quiet.isOn)
        Assert.assertEquals(0L, quiet.count("frames_persisted"))
        Assert.assertEquals(0, quiet.ringSize)
        Assert.assertTrue(quiet.render().contains("mode=off"))
        Assert.assertTrue(quiet.countersSnapshot().isEmpty())
        // the vocabulary is a law of the RECORDER, not of the mode
        var refused = false
        try {
            quiet.count("not_a_metric")
        } catch (_e: DiagnosticsRefusal) {
            refused = true
        }
        Assert.assertTrue("an unknown metric is refused even while OFF", refused)
        quiet.enable()
        Assert.assertEquals(1L, quiet.count("frames_persisted"))
        quiet.disable()
        Assert.assertEquals(0L, quiet.count("frames_persisted"))
    }

    // ------------------------------------------------------------ W02

    /** W02 -- THE NAMED NEGATIVE, first limb: a body or a key is REFUSED. */
    @Test
    fun test_w02_a_body_or_a_key_is_refused_by_name() {
        val diag = live()
        var bodyRefused: String? = null
        try {
            diag.count(sentinelBody)
        } catch (e: DiagnosticsRefusal) {
            bodyRefused = e.message
        }
        Assert.assertNotNull(bodyRefused)
        Assert.assertTrue(bodyRefused!!.contains("vocabulary"))

        var keyRefused: String? = null
        try {
            diag.count("peers_seen", sentinelKey)
        } catch (e: DiagnosticsRefusal) {
            keyRefused = e.message
        }
        Assert.assertNotNull(keyRefused)
        Assert.assertTrue(keyRefused!!.contains("must be a number"))

        try {
            diag.count("peers_seen", sentinelNodeId)
            Assert.fail("a node id string must be refused")
        } catch (_e: DiagnosticsRefusal) {
        }

        val rendered = diag.render()
        for (sentinel in listOf(sentinelBody, sentinelKey, sentinelNodeId)) {
            Assert.assertFalse("the output leaked $sentinel", rendered.contains(sentinel))
        }
        Assert.assertEquals("a refused call appendeth nothing", 0, diag.ringSize)
    }

    // ------------------------------------------------------------ W03

    /** W03 -- THE NAMED NEGATIVE, second limb: the ring is BOUNDED, and counted. */
    @Test
    fun test_w03_the_ring_is_bounded_and_drop_oldest_is_counted() {
        val diag = live(capacity = 16)
        repeat(100) { diag.count("queue_superseded", 1L) }
        Assert.assertEquals(16, diag.ringSize)
        Assert.assertTrue(diag.isBounded)
        Assert.assertEquals("every supersession is COUNTED", 84L, diag.supersededCount())
        Assert.assertTrue(diag.render().contains("superseded=84"))

        val tiny = live(capacity = 1)
        repeat(5) { tiny.count("frames_persisted", 1L) }
        Assert.assertEquals(1, tiny.ringSize)
        Assert.assertEquals(4L, tiny.supersededCount())
    }

    // ------------------------------------------------------------ W04

    /** W04 -- counters saturate; gauges never go negative. */
    @Test
    fun test_w04_counters_saturate_and_gauges_never_go_negative() {
        val diag = live()
        diag.count("frames_persisted", Diagnostics.COUNTER_CEILING * 4)
        Assert.assertEquals(Diagnostics.COUNTER_CEILING,
            diag.countersSnapshot()["frames_persisted"])
        diag.count("frames_persisted", 10L)
        Assert.assertEquals(Diagnostics.COUNTER_CEILING,
            diag.countersSnapshot()["frames_persisted"])
        diag.gauge("queue_depth", -5L)
        Assert.assertEquals(0L, diag.countersSnapshot()["queue_depth"])
        diag.gauge("queue_depth", Diagnostics.COUNTER_CEILING * 2)
        Assert.assertEquals(Diagnostics.COUNTER_CEILING,
            diag.countersSnapshot()["queue_depth"])
    }

    // ------------------------------------------------------------ W05

    /** W05 -- durations are MONOTONIC microseconds; no wall-clock date. */
    @Test
    fun test_w05_durations_are_monotonic_microseconds() {
        val diag = live()
        diag.count("frames_persisted", 1L, durationMicros = 1500L)
        Assert.assertEquals(1500L, diag.linesSnapshot().last().durationMicros)
        val rendered = diag.render()
        Assert.assertTrue(rendered.contains("dur_us=1500"))
        Assert.assertFalse("no calendar date may be recorded",
            Pattern.compile("\\b(19|20)\\d\\d-\\d\\d-\\d\\d\\b").matcher(rendered).find())
        Assert.assertFalse("no epoch-like timestamp may be recorded",
            Pattern.compile("\\d{10,}").matcher(rendered).find())
        diag.count("frames_persisted", 1L, durationMicros = -9L)
        Assert.assertEquals(0L, diag.linesSnapshot().last().durationMicros)
    }

    // ------------------------------------------------------------ W06

    /** W06 -- relation ids are EPHEMERAL, opaque, and never a peer key. */
    @Test
    fun test_w06_relation_ids_are_ephemeral_and_opaque() {
        val diag = live()
        val first = diag.relation("peer:$sentinelNodeId")
        Assert.assertEquals("r1", first)
        Assert.assertEquals(first, diag.relation("peer:$sentinelNodeId"))
        Assert.assertEquals("r2", diag.relation("peer:another"))
        diag.count("peers_seen", 1L, relationKey = "peer:$sentinelNodeId")
        val rendered = diag.render()
        Assert.assertTrue(rendered.contains("rel=r1"))
        Assert.assertFalse("a peer key NEVER reacheth the output",
            rendered.contains(sentinelNodeId))
        diag.reset()
        Assert.assertEquals("r1", diag.relation("peer:$sentinelNodeId"))
        Assert.assertEquals(0, diag.ringSize)
        Assert.assertTrue(diag.countersSnapshot().isEmpty())
    }

    // ------------------------------------------------------------ W07

    /** W07 -- the five scenarios, against a live recorder. */
    @Test
    fun test_w07_the_five_scenarios_run_against_a_live_recorder() {
        val scenarios = listOf("tampered_data", "peer_churn_10k", "queue_flood",
            "large_archive", "cancelled_inference")
        for (name in scenarios) {
            val diag = live()
            runScenario(name, diag, scale = 200)
            Assert.assertTrue("$name must stay bounded", diag.isBounded)
            Assert.assertTrue("$name must have recorded something", diag.ringSize > 0)
            for (metric in diag.countersSnapshot().keys) {
                Assert.assertTrue("$name: $metric is in the vocabulary",
                    Diagnostics.METRIC_NAMES.contains(metric))
            }
        }
    }

    private fun runScenario(name: String, diag: Diagnostics, scale: Int) {
        when (name) {
            "tampered_data" -> {
                diag.count("frames_persisted", 1L, durationMicros = 120L)
                diag.count("frames_dropped_capacity", 1L)
                try { diag.count(sentinelBody) } catch (_e: DiagnosticsRefusal) { diag.noteRefusal() }
                try { diag.count("peers_seen", sentinelKey) } catch (_e: DiagnosticsRefusal) { diag.noteRefusal() }
            }
            "peer_churn_10k" -> {
                for (peer in 0 until scale) {
                    diag.count("peers_seen", 1L, relationKey = "peer:${peer % 64}")
                    if (peer % 3 == 0) diag.count("relations_opened", 1L, relationKey = "peer:${peer % 64}")
                    if (peer % 5 == 0) diag.count("relations_closed", 1L, relationKey = "peer:${peer % 64}")
                }
            }
            "queue_flood" -> {
                for (i in 0 until scale) {
                    diag.gauge("queue_depth", (i % 512).toLong())
                    diag.count("queue_superseded", 1L)
                }
            }
            "large_archive" -> {
                diag.gauge("archive_documents", scale.toLong())
                diag.gauge("archive_bytes", scale.toLong() * 1024L)
                diag.count("frames_persisted", 1L)
            }
            "cancelled_inference" -> {
                diag.count("inference_started", 1L)
                diag.count("inference_cancelled", 1L)
                try { diag.count("inference_completed", sentinelBody) } catch (_e: DiagnosticsRefusal) { diag.noteRefusal() }
            }
        }
    }

    // ------------------------------------------------------------ W08

    /** W08 -- THE SENTINEL LAW: no sentinel in any scenario's output. */
    @Test
    fun test_w08_the_sentinels_appear_nowhere_in_any_scenario() {
        for (name in listOf("tampered_data", "peer_churn_10k", "queue_flood",
            "large_archive", "cancelled_inference")) {
            val diag = live()
            runScenario(name, diag, scale = 500)
            val rendered = diag.render()
            for (sentinel in listOf(sentinelBody, sentinelKey, sentinelNodeId)) {
                Assert.assertFalse("$name leaked $sentinel", rendered.contains(sentinel))
            }
            // every line carrieth a NUMBER and an opaque ordinal
            for (line in diag.linesSnapshot()) {
                Assert.assertTrue(line.relation.matches(Regex("r\\d+")))
                Assert.assertFalse(line.metric.contains("SENTINEL"))
            }
            // and the header carrieth no metric NAME from outside the vocabulary
            for (metric in diag.countersSnapshot().keys) {
                Assert.assertTrue(Diagnostics.METRIC_NAMES.contains(metric))
            }
        }
    }

    // ------------------------------------------------------------ W09

    /** W09 -- the vocabulary is CLOSED. */
    @Test
    fun test_w09_the_vocabulary_is_closed() {
        val diag = live()
        for (metric in Diagnostics.METRIC_NAMES) diag.count(metric, 1L)
        Assert.assertEquals(Diagnostics.METRIC_NAMES.size, diag.countersSnapshot().size)
        for (stranger in listOf("message_body", "peer_id", "key", "SENTINEL", "metric",
            "peers_seen ", "PEERS_SEEN", "")) {
            var refused = false
            try { diag.count(stranger) } catch (_e: DiagnosticsRefusal) { refused = true }
            Assert.assertTrue("'$stranger' must be refused", refused)
        }
        for (metric in Diagnostics.METRIC_NAMES) {
            Assert.assertTrue(metric, metric.matches(Regex("[a-z][a-z0-9_]*")))
            Assert.assertFalse(metric, metric.contains("body"))
            Assert.assertFalse(metric, metric.contains("key"))
            Assert.assertFalse(metric, metric.contains("node"))
        }
    }

    // ------------------------------------------------------------ W10

    /** W10 -- redaction is BY REFUSAL: numbers and booleans only. */
    @Test
    fun test_w10_redaction_is_by_refusal() {
        val diag = live()
        val values: List<Any?> = listOf("a string", byteArrayOf(1, 2, 3), listOf("a"), null)
        for (value in values) {
            var refused = false
            try { diag.count("peers_seen", value) } catch (_e: DiagnosticsRefusal) { refused = true }
            Assert.assertTrue("$value must be refused", refused)
        }
        Assert.assertEquals(0, diag.ringSize)
        Assert.assertEquals(1L, diag.count("peers_seen", true))
        Assert.assertEquals(1L, diag.countersSnapshot()["peers_seen"])
    }

    // ------------------------------------------------------------ W11

    /** W11 -- the bound is a CONSTRUCTION under churn and flood. */
    @Test
    fun test_w11_the_ring_bound_is_a_construction() {
        Assert.assertEquals(256, Diagnostics.RING_CAPACITY)
        Assert.assertEquals(1L shl 40, Diagnostics.COUNTER_CEILING)
        val flooded = live()
        runScenario("queue_flood", flooded, scale = 5_000)
        Assert.assertTrue(flooded.ringSize <= flooded.capacity)
        Assert.assertTrue("the flood must have superseded lines", flooded.supersededCount() > 0)

        val churn = live()
        runScenario("peer_churn_10k", churn, scale = 10_000)
        Assert.assertTrue(churn.ringSize <= churn.capacity)
        Assert.assertEquals(10_000L, churn.countersSnapshot()["peers_seen"])
    }

    // ------------------------------------------------------------ W12

    /** W12 -- nothing is transmitted: the module carrieth no network type, and the
     *  shipping manifest REMOVETH the internet permission. */
    @Test
    fun test_w12_nothing_is_transmitted() {
        val source = java.io.File(
            "src/main/java/io/godstone/mesh/diag/Diagnostics.kt").readText()
        // the CODE is scanned, not the prose: a comment that NAMES what it forbiddeth
        // is not a transmission (the first form of this scan failed on its own KDoc)
        val code = source.lines().filterNot { line ->
            val trimmed = line.trim()
            trimmed.startsWith("//") || trimmed.startsWith("*") || trimmed.startsWith("/*")
        }.joinToString("\n")
        for (forbidden in listOf("java.net", "HttpURLConnection", "okhttp", "Socket",
            "URLConnection", "OutputStream")) {
            Assert.assertFalse("the diagnostics must never transmit ($forbidden)",
                code.contains(forbidden))
        }
        val manifest = java.io.File("../app/src/main/AndroidManifest.xml").readText()
        Assert.assertTrue(manifest.contains("android.permission.INTERNET\" tools:node=\"remove\""))
    }

    // ------------------------------------------------------------ W13

    /** W13 -- the isles share the ONE vocabulary and the ONE sentinel set. */
    @Test
    fun test_w13_the_isles_share_one_vocabulary() {
        val swift = java.io.File(
            "../../ios/Godstone/Sources/GodstoneMesh/Diagnostics.swift")
        Assert.assertTrue("the iOS twin must exist: ${swift.path}", swift.isFile)
        val stext = swift.readText()
        for (metric in listOf("peers_seen", "queue_superseded", "frames_persisted")) {
            Assert.assertTrue("the iOS twin must speak $metric", stext.contains(metric))
        }
        val python = java.io.File("../../tools/readiness/diagnostics.py")
        Assert.assertTrue("the python conductor must exist", python.isFile)
        val ptext = python.readText()
        for (metric in listOf("peers_seen", "queue_superseded", "frames_persisted")) {
            Assert.assertTrue("the conductor must speak $metric", ptext.contains(metric))
        }
        // the SENTINELS live in the COURTS (they are injection fixtures, not
        // production vocabulary): each isle's court must carry the same three
        val pythonCourt = java.io.File("../../tools/readiness/tests/test_t71.py")
        val iosCourt = java.io.File(
            "../../ios/Godstone/Tests/GodstoneMeshTests/ReadinessT71Tests.swift")
        Assert.assertTrue("the iOS court must exist", iosCourt.isFile)
        Assert.assertTrue("the python court must exist", pythonCourt.isFile)
        // the LITERALS live in the python conductor and in the two isle COURTS (the
        // python court importeth them, so it need not respell them)
        for (sentinel in listOf(sentinelBody, sentinelKey, sentinelNodeId)) {
            Assert.assertTrue("the conductor carrieth the sentinel",
                ptext.contains(sentinel))
            Assert.assertTrue("and so doth the iOS court",
                iosCourt.readText().contains(sentinel))
        }
        Assert.assertTrue("the python court must exist", pythonCourt.isFile)
    }
}
