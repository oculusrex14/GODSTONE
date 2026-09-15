package io.godstone.mesh.diag

// ---------------------------------------------------------------------------
// T71 -- bounded local diagnostics, with no private telemetry (Android isle).
//
// The twin of tools/readiness/diagnostics.py and of the iOS Diagnostics.swift:
// the SAME vocabulary, the SAME laws, the SAME bounds. "Correctness under load
// needs measurable limits, but this offline app must not introduce tracking."
//
//   * OPT-IN (off by default; OFF counteth nothing);
//   * a CLOSED metric vocabulary -- an unknown name is REFUSED, because free names
//     are how a peer id or a body fragment reacheth a label;
//   * BOUNDED, saturating counters and non-negative gauges;
//   * MONOTONIC microsecond durations only -- no wall-clock timestamp is recorded;
//   * EPHEMERAL per-process relation ordinals -- a peer key never reacheth output;
//   * a BOUNDED drop-oldest ring whose supersessions are COUNTED;
//   * REDACTION BY REFUSAL: numbers and booleans only, everything else thrown.
//
// Nothing here transmitteth anything: the module carrieth no network type, and the
// shipping manifest removeth INTERNET.
// ---------------------------------------------------------------------------

/** The mode. OFF is the default, and OFF recordeth nothing at all. */
enum class DiagnosticsMode { OFF, ON }

/** A refused diagnostic. Thrown rather than silently dropped. */
class DiagnosticsRefusal(message: String) : IllegalArgumentException(message)

/** One rendered line: a metric name, a number, a monotonic duration. */
data class DiagnosticsLine(
    val metric: String,
    val value: Long,
    val durationMicros: Long,
    val relation: String,
) {
    fun render(): String =
        "metric=$metric value=$value dur_us=$durationMicros rel=$relation"
}

/**
 * The recorder. Every bound is a CONSTRUCTION: the ring cannot exceed its capacity,
 * a counter cannot exceed its ceiling, and the vocabulary cannot be widened by a
 * caller.
 */
class Diagnostics(
    val mode: DiagnosticsMode = DiagnosticsMode.OFF,
    val capacity: Int = RING_CAPACITY,
) {
    private val counters = LinkedHashMap<String, Long>()
    private val lines = ArrayDeque<DiagnosticsLine>()
    private var superseded = 0L
    private var refusals = 0L
    private var relationSeq = 0
    private val relationByKey = LinkedHashMap<String, String>()

    var currentMode: DiagnosticsMode = mode
        private set

    fun enable() { currentMode = DiagnosticsMode.ON }
    fun disable() { currentMode = DiagnosticsMode.OFF }
    val isOn: Boolean get() = currentMode == DiagnosticsMode.ON

    // ---- counters -------------------------------------------------------

    private fun checkMetric(metric: String?): String {
        if (metric == null || metric !in METRIC_NAMES) {
            throw DiagnosticsRefusal(
                "the metric name '$metric' is not in the vocabulary: free names are how private " +
                    "data reacheth a label")
        }
        return metric
    }

    /** REDACTION BY REFUSAL: only a number (or a boolean) may be a value. */
    private fun checkValue(value: Any?): Long {
        val asLong = when (value) {
            is Boolean -> if (value) 1L else 0L
            is Byte, is Short, is Int, is Long -> (value as Number).toLong()
            else -> throw DiagnosticsRefusal(
                "a diagnostic value must be a number; '${value?.let { it::class.simpleName }}' is " +
                    "exactly how a message body or a key fragment would enter the log")
        }
        return asLong.coerceIn(0L, COUNTER_CEILING)
    }

    fun count(metric: String?, value: Any? = 1L, durationMicros: Any? = 0L,
              relationKey: String? = null): Long {
        val name = checkMetric(metric)
        val amount = checkValue(value)
        if (!isOn) return 0L
        val duration = checkValue(durationMicros)
        val updated = minOf((counters[name] ?: 0L) + amount, COUNTER_CEILING)
        counters[name] = updated
        append(name, amount, duration, relationKey)
        return updated
    }

    fun gauge(metric: String?, value: Any?, relationKey: String? = null): Long {
        val name = checkMetric(metric)
        val amount = checkValue(value)
        if (!isOn) return 0L
        counters[name] = amount
        append(name, amount, 0L, relationKey)
        return amount
    }

    // ---- the ring -------------------------------------------------------

    private fun append(metric: String, value: Long, durationMicros: Long, relationKey: String?) {
        val line = DiagnosticsLine(metric, value, durationMicros, relation(relationKey))
        if (lines.size >= capacity) {
            lines.removeFirst()          // drop-oldest, and COUNT it
            superseded++
        }
        lines.addLast(line)
    }

    /** An EPHEMERAL relation id: per-process, opaque, never a node id. */
    fun relation(key: String? = null): String {
        if (key == null) {
            relationSeq++
            return "r$relationSeq"
        }
        val existing = relationByKey[key]
        if (existing != null) return existing
        relationSeq++
        val made = "r$relationSeq"
        relationByKey[key] = made
        // GS-DIAG-001: the MAP is bounded exactly as the ring is -- the audit reproduced a
        // ten-thousand-peer churn retaining every historic key in a second unbounded map.
        // An evicted key simply receiveth a FRESH ordinal if it returneth.
        while (relationByKey.size > capacity) {
            val eldest = relationByKey.keys.first()
            relationByKey.remove(eldest)
            superseded++
        }
        return made
    }

    val ringSize: Int get() = lines.size
    val isBounded: Boolean get() = ringSize <= capacity
    fun supersededCount(): Long = superseded
    fun refusalCount(): Long = refusals
    fun countersSnapshot(): Map<String, Long> = LinkedHashMap(counters)
    fun linesSnapshot(): List<DiagnosticsLine> = lines.toList()

    /** The whole output, as it would be written. THE ONLY ROAD OUT. */
    fun render(): String {
        val header = "diagnostics mode=${currentMode.name.lowercase()} lines=$ringSize " +
            "superseded=$superseded refusals=$refusals"
        return (listOf(header) + lines.map { it.render() }).joinToString("\n")
    }

    /** Everything this recorder knoweth vanisheth, and the ordinals restart. */
    fun reset() {
        counters.clear()
        lines.clear()
        superseded = 0
        refusals = 0
        relationSeq = 0
        relationByKey.clear()
    }

    /** Count one refusal (the court's own seam, so a refusal is VISIBLE). */
    fun noteRefusal() { refusals++ }

    companion object {
        /** The ring's bound: memory is bounded by construction, not by hope. */
        const val RING_CAPACITY: Int = 256

        /** A counter's ceiling: saturating, so a flood cannot overflow into nonsense. */
        const val COUNTER_CEILING: Long = 1L shl 40

        /** THE VOCABULARY. A metric may only be named from this set. */
        val METRIC_NAMES: Set<String> = linkedSetOf(
            "peers_seen", "peers_trusted", "frames_persisted", "frames_duplicate",
            "frames_forwarded", "frames_dropped_capacity", "queue_depth",
            "queue_superseded", "acks_admitted", "acks_refused", "archive_documents",
            "archive_bytes", "inference_started", "inference_cancelled",
            "inference_completed", "wipe_stages", "relations_opened", "relations_closed",
        )
    }
}
