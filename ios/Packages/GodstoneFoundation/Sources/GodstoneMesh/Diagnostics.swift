import Foundation

// ---------------------------------------------------------------------------
// T71 -- bounded local diagnostics, with no private telemetry (iOS isle).
//
// The twin of tools/readiness/diagnostics.py and of the Android Diagnostics.kt:
// the SAME vocabulary, the SAME laws, the SAME bounds.
//
//   * OPT-IN (off by default; OFF counteth nothing);
//   * a CLOSED metric vocabulary -- an unknown name is REFUSED;
//   * BOUNDED, saturating counters and non-negative gauges;
//   * MONOTONIC microsecond durations only -- no wall-clock date is recorded;
//   * EPHEMERAL per-process relation ordinals -- a peer key never reacheth output;
//   * a BOUNDED drop-oldest ring whose supersessions are COUNTED;
//   * REDACTION BY REFUSAL: numbers and booleans only, everything else thrown.
//
// Nothing here transmitteth anything: the module importeth no networking, and the
// shipping app carrieth no analytics.
// ---------------------------------------------------------------------------

/// The mode. OFF is the default, and OFF recordeth nothing at all.
public enum DiagnosticsMode: String, Sendable { case off, on }

/// A refused diagnostic. Thrown rather than silently dropped.
public struct DiagnosticsRefusal: Error, Equatable, CustomStringConvertible {
    public let reason: String
    public var description: String { reason }
}

/// One rendered line: a metric name, a number, a monotonic duration.
public struct DiagnosticsLine: Sendable, Equatable {
    public let metric: String
    public let value: Int64
    public let durationMicros: Int64
    public let relation: String

    public func render() -> String {
        "metric=\(metric) value=\(value) dur_us=\(durationMicros) rel=\(relation)"
    }
}

/// The recorder. Every bound is a CONSTRUCTION.
public final class Diagnostics: @unchecked Sendable {
    /// The ring's bound: memory is bounded by construction, not by hope.
    public static let ringCapacity = 256
    /// A counter's ceiling: saturating, so a flood cannot overflow into nonsense.
    public static let counterCeiling: Int64 = 1 << 40

    /// THE VOCABULARY. A metric may only be named from this set.
    public static let metricNames: [String] = [
        "peers_seen", "peers_trusted", "frames_persisted", "frames_duplicate",
        "frames_forwarded", "frames_dropped_capacity", "queue_depth",
        "queue_superseded", "acks_admitted", "acks_refused", "archive_documents",
        "archive_bytes", "inference_started", "inference_cancelled",
        "inference_completed", "wipe_stages", "relations_opened", "relations_closed",
    ]

    private let lock = NSLock()
    public let capacity: Int
    private var mode: DiagnosticsMode
    private var counters: [String: Int64] = [:]
    private var lines: [DiagnosticsLine] = []
    private var superseded: Int64 = 0
    private var refusals: Int64 = 0
    private var relationSeq = 0
    private var relationByKey: [String: String] = [:]

    public init(mode: DiagnosticsMode = .off, capacity: Int = Diagnostics.ringCapacity) {
        self.mode = mode
        self.capacity = capacity
    }

    public var currentMode: DiagnosticsMode { lock.lock(); defer { lock.unlock() }; return mode }
    public func enable() { lock.lock(); mode = .on; lock.unlock() }
    public func disable() { lock.lock(); mode = .off; lock.unlock() }
    public var isOn: Bool { currentMode == .on }

    // ---- counters -------------------------------------------------------

    private func checkedMetric(_ metric: String) throws -> String {
        guard Diagnostics.metricNames.contains(metric) else {
            throw DiagnosticsRefusal(reason: "the metric name '\(metric)' is not in the vocabulary: "
                                     + "free names are how private data reacheth a label")
        }
        return metric
    }

    /// REDACTION BY REFUSAL: only a number (or a boolean) may be a value.
    private func checkedValue(_ value: Any) throws -> Int64 {
        let raw: Int64
        if let flag = value as? Bool {
            raw = flag ? 1 : 0
        } else if let number = value as? Int64 {
            raw = number
        } else if let number = value as? Int {
            raw = Int64(number)
        } else {
            throw DiagnosticsRefusal(reason: "a diagnostic value must be a number; "
                                     + "'\(type(of: value))' is exactly how a message body or a key "
                                     + "fragment would enter the log")
        }
        return min(max(raw, 0), Diagnostics.counterCeiling)
    }

    @discardableResult
    public func count(_ metric: String, _ value: Any = Int64(1), durationMicros: Any = Int64(0),
                      relationKey: String? = nil) throws -> Int64 {
        let name = try checkedMetric(metric)
        let amount = try checkedValue(value)
        guard isOn else { return 0 }
        let duration = try checkedValue(durationMicros)
        lock.lock()
        let updated = min((counters[name] ?? 0) + amount, Diagnostics.counterCeiling)
        counters[name] = updated
        appendLocked(name, amount, duration, relationKey)
        lock.unlock()
        return updated
    }

    @discardableResult
    public func gauge(_ metric: String, _ value: Any, relationKey: String? = nil) throws -> Int64 {
        let name = try checkedMetric(metric)
        let amount = try checkedValue(value)
        guard isOn else { return 0 }
        lock.lock()
        counters[name] = amount
        appendLocked(name, amount, 0, relationKey)
        lock.unlock()
        return amount
    }

    // ---- the ring -------------------------------------------------------

    private func appendLocked(_ metric: String, _ value: Int64, _ durationMicros: Int64,
                              _ relationKey: String?) {
        let line = DiagnosticsLine(metric: metric, value: value,
                                   durationMicros: durationMicros,
                                   relation: relationLocked(relationKey))
        if lines.count >= capacity {
            lines.removeFirst()                     // drop-oldest, and COUNT it
            superseded += 1
        }
        lines.append(line)
    }

    /// An EPHEMERAL relation id: per-process, opaque, never a node id.
    public func relation(_ key: String? = nil) -> String {
        lock.lock(); defer { lock.unlock() }
        return relationLocked(key)
    }

    private func relationLocked(_ key: String?) -> String {
        guard let key else {
            relationSeq += 1
            return "r\(relationSeq)"
        }
        if let existing = relationByKey[key] { return existing }
        relationSeq += 1
        let made = "r\(relationSeq)"
        relationByKey[key] = made
        // GS-DIAG-001: the MAP is bounded exactly as the ring is -- the audit reproduced a
        // ten-thousand-peer churn retaining every historic key in a second unbounded map.
        // An evicted key simply receiveth a FRESH ordinal if it returneth.
        while relationByKey.count > capacity, let eldest = relationByKey.keys.first {
            relationByKey.removeValue(forKey: eldest)
            superseded += 1
        }
        return made
    }

    public var ringSize: Int { lock.lock(); defer { lock.unlock() }; return lines.count }
    public var isBounded: Bool { ringSize <= capacity }
    public var supersededCount: Int64 { lock.lock(); defer { lock.unlock() }; return superseded }
    public var refusalCount: Int64 { lock.lock(); defer { lock.unlock() }; return refusals }
    public var countersSnapshot: [String: Int64] { lock.lock(); defer { lock.unlock() }; return counters }
    public var linesSnapshot: [DiagnosticsLine] { lock.lock(); defer { lock.unlock() }; return lines }
    public func noteRefusal() { lock.lock(); refusals += 1; lock.unlock() }

    /// The whole output, as it would be written. THE ONLY ROAD OUT.
    public func render() -> String {
        lock.lock(); defer { lock.unlock() }
        let header = "diagnostics mode=\(mode.rawValue) lines=\(lines.count) "
            + "superseded=\(superseded) refusals=\(refusals)"
        return ([header] + lines.map { $0.render() }).joined(separator: "\n")
    }

    /// Everything this recorder knoweth vanisheth, and the ordinals restart.
    public func reset() {
        lock.lock()
        counters.removeAll(); lines.removeAll()
        superseded = 0; refusals = 0; relationSeq = 0; relationByKey.removeAll()
        lock.unlock()
    }
}
