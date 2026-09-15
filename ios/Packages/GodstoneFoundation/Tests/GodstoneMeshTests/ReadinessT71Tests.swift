// T71 readiness court (iOS isle) -- bounded diagnostics without private telemetry.
// The twin of the python conductor and the Android court, with the SAME laws and
// the SAME sentinel set.
import XCTest
@testable import GodstoneMesh

final class ReadinessT71Tests: XCTestCase {
    private let sentinelBody = "SENTINEL-BODY-do-not-log-me-4417"
    private let sentinelKey = "SENTINEL-KEY-do-not-log-me-8823"
    private let sentinelNodeId = "SENTINEL-NODE-do-not-log-me-1193"

    private func live(capacity: Int = Diagnostics.ringCapacity) -> Diagnostics {
        let made = Diagnostics(capacity: capacity)
        made.enable()
        return made
    }

    // ------------------------------------------------------------ W01

    func testW01TheRecorderIsOptIn() throws {
        let quiet = Diagnostics()
        XCTAssertFalse(quiet.isOn)
        XCTAssertEqual(try quiet.count("frames_persisted"), 0)
        XCTAssertEqual(quiet.ringSize, 0)
        XCTAssertTrue(quiet.render().contains("mode=off"))
        XCTAssertTrue(quiet.countersSnapshot.isEmpty)
        XCTAssertThrowsError(try quiet.count("not_a_metric"),
                             "an unknown metric is refused even while OFF")
        quiet.enable()
        XCTAssertEqual(try quiet.count("frames_persisted"), 1)
        quiet.disable()
        XCTAssertEqual(try quiet.count("frames_persisted"), 0)
    }

    // ------------------------------------------------------------ W02

    func testW02ABodyOrAKeyIsRefusedByName() throws {
        let diag = live()
        XCTAssertThrowsError(try diag.count(sentinelBody)) { error in
            XCTAssertTrue("\(error)".contains("vocabulary"), "\(error)")
        }
        XCTAssertThrowsError(try diag.count("peers_seen", sentinelKey)) { error in
            XCTAssertTrue("\(error)".contains("must be a number"), "\(error)")
        }
        XCTAssertThrowsError(try diag.count("peers_seen", sentinelNodeId))
        let rendered = diag.render()
        for sentinel in [sentinelBody, sentinelKey, sentinelNodeId] {
            XCTAssertFalse(rendered.contains(sentinel), "the output leaked \(sentinel)")
        }
        XCTAssertEqual(diag.ringSize, 0, "a refused call appendeth nothing")
    }

    // ------------------------------------------------------------ W03

    func testW03TheRingIsBoundedAndDropOldestIsCounted() throws {
        let diag = live(capacity: 16)
        for _ in 0..<100 { _ = try diag.count("queue_superseded") }
        XCTAssertEqual(diag.ringSize, 16)
        XCTAssertTrue(diag.isBounded)
        XCTAssertEqual(diag.supersededCount, 84, "every supersession is COUNTED")
        XCTAssertTrue(diag.render().contains("superseded=84"))

        let tiny = live(capacity: 1)
        for _ in 0..<5 { _ = try tiny.count("frames_persisted") }
        XCTAssertEqual(tiny.ringSize, 1)
        XCTAssertEqual(tiny.supersededCount, 4)
    }

    // ------------------------------------------------------------ W04

    func testW04CountersSaturateAndGaugesNeverGoNegative() throws {
        let diag = live()
        _ = try diag.count("frames_persisted", Diagnostics.counterCeiling * 4)
        XCTAssertEqual(diag.countersSnapshot["frames_persisted"], Diagnostics.counterCeiling)
        _ = try diag.count("frames_persisted", Int64(10))
        XCTAssertEqual(diag.countersSnapshot["frames_persisted"], Diagnostics.counterCeiling)
        _ = try diag.gauge("queue_depth", Int64(-5))
        XCTAssertEqual(diag.countersSnapshot["queue_depth"], 0)
    }

    // ------------------------------------------------------------ W05

    func testW05DurationsAreMonotonicMicroseconds() throws {
        let diag = live()
        _ = try diag.count("frames_persisted", Int64(1), durationMicros: Int64(1500))
        XCTAssertEqual(diag.linesSnapshot.last?.durationMicros, 1500)
        let rendered = diag.render()
        XCTAssertTrue(rendered.contains("dur_us=1500"))
        XCTAssertNil(rendered.range(of: "\\b(19|20)\\d\\d-\\d\\d-\\d\\d\\b", options: .regularExpression),
                     "no calendar date may be recorded")
        XCTAssertNil(rendered.range(of: "\\d{10,}", options: .regularExpression),
                     "no epoch-like timestamp may be recorded")
        _ = try diag.count("frames_persisted", Int64(1), durationMicros: Int64(-9))
        XCTAssertEqual(diag.linesSnapshot.last?.durationMicros, 0)
    }

    // ------------------------------------------------------------ W06

    func testW06RelationIdsAreEphemeralAndOpaque() throws {
        let diag = live()
        let first = diag.relation("peer:\(sentinelNodeId)")
        XCTAssertEqual(first, "r1")
        XCTAssertEqual(diag.relation("peer:\(sentinelNodeId)"), first)
        XCTAssertEqual(diag.relation("peer:another"), "r2")
        _ = try diag.count("peers_seen", Int64(1), relationKey: "peer:\(sentinelNodeId)")
        let rendered = diag.render()
        XCTAssertTrue(rendered.contains("rel=r1"))
        XCTAssertFalse(rendered.contains(sentinelNodeId), "a peer key NEVER reacheth the output")
        diag.reset()
        XCTAssertEqual(diag.relation("peer:\(sentinelNodeId)"), "r1",
                       "a reset restarteth the ordinals, so lines cannot be correlated")
        XCTAssertEqual(diag.ringSize, 0)
        XCTAssertTrue(diag.countersSnapshot.isEmpty)
    }

    // ------------------------------------------------------------ W07

    func testW07TheFiveScenariosRunAgainstALiveRecorder() throws {
        for name in ["tampered_data", "peer_churn_10k", "queue_flood",
                     "large_archive", "cancelled_inference"] {
            let diag = live()
            try runScenario(name, diag, scale: 200)
            XCTAssertTrue(diag.isBounded, name)
            XCTAssertGreaterThan(diag.ringSize, 0, name)
            for metric in diag.countersSnapshot.keys {
                XCTAssertTrue(Diagnostics.metricNames.contains(metric), name + ": " + metric)
            }
        }
    }

    private func runScenario(_ name: String, _ diag: Diagnostics, scale: Int) throws {
        switch name {
        case "tampered_data":
            _ = try diag.count("frames_persisted", Int64(1), durationMicros: Int64(120))
            _ = try diag.count("frames_dropped_capacity")
            do { _ = try diag.count(sentinelBody) } catch { diag.noteRefusal() }
            do { _ = try diag.count("peers_seen", sentinelKey) } catch { diag.noteRefusal() }
        case "peer_churn_10k":
            for peer in 0..<scale {
                _ = try diag.count("peers_seen", Int64(1), relationKey: "peer:\(peer % 64)")
                if peer % 3 == 0 {
                    _ = try diag.count("relations_opened", Int64(1), relationKey: "peer:\(peer % 64)")
                }
                if peer % 5 == 0 {
                    _ = try diag.count("relations_closed", Int64(1), relationKey: "peer:\(peer % 64)")
                }
            }
        case "queue_flood":
            for i in 0..<scale {
                _ = try diag.gauge("queue_depth", Int64(i % 512))
                _ = try diag.count("queue_superseded")
            }
        case "large_archive":
            _ = try diag.gauge("archive_documents", Int64(scale))
            _ = try diag.gauge("archive_bytes", Int64(scale * 1024))
            _ = try diag.count("frames_persisted")
        case "cancelled_inference":
            _ = try diag.count("inference_started")
            _ = try diag.count("inference_cancelled")
            do { _ = try diag.count("inference_completed", sentinelBody) } catch { diag.noteRefusal() }
        default:
            XCTFail("unknown scenario \(name)")
        }
    }

    // ------------------------------------------------------------ W08

    func testW08TheSentinelsAppearNowhereInAnyScenario() throws {
        for name in ["tampered_data", "peer_churn_10k", "queue_flood",
                     "large_archive", "cancelled_inference"] {
            let diag = live()
            try runScenario(name, diag, scale: 500)
            let rendered = diag.render()
            for sentinel in [sentinelBody, sentinelKey, sentinelNodeId] {
                XCTAssertFalse(rendered.contains(sentinel), "\(name) leaked \(sentinel)")
            }
            for line in diag.linesSnapshot {
                XCTAssertNotNil(line.relation.range(of: "^r\\d+$", options: .regularExpression),
                                line.relation)
                XCTAssertFalse(line.metric.contains("SENTINEL"))
            }
        }
    }

    // ------------------------------------------------------------ W09

    func testW09TheVocabularyIsClosed() throws {
        let diag = live()
        for metric in Diagnostics.metricNames { _ = try diag.count(metric) }
        XCTAssertEqual(diag.countersSnapshot.count, Diagnostics.metricNames.count)
        for stranger in ["message_body", "peer_id", "key", "SENTINEL", "metric",
                         "peers_seen ", "PEERS_SEEN", ""] {
            XCTAssertThrowsError(try diag.count(stranger), "'\(stranger)' must be refused")
        }
        for metric in Diagnostics.metricNames {
            XCTAssertNotNil(metric.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression), metric)
            XCTAssertFalse(metric.contains("body"))
            XCTAssertFalse(metric.contains("key"))
            XCTAssertFalse(metric.contains("node"))
        }
    }

    // ------------------------------------------------------------ W10

    func testW10RedactionIsByRefusal() throws {
        let diag = live()
        for value in ["a string", Data([1, 2, 3]), ["a"]] as [Any] {
            XCTAssertThrowsError(try diag.count("peers_seen", value), "\(value) must be refused")
        }
        XCTAssertEqual(diag.ringSize, 0)
        XCTAssertEqual(try diag.count("peers_seen", true), 1)
        XCTAssertEqual(diag.countersSnapshot["peers_seen"], 1)
    }

    // ------------------------------------------------------------ W11

    func testW11TheRingBoundIsAConstruction() throws {
        XCTAssertEqual(Diagnostics.ringCapacity, 256)
        XCTAssertEqual(Diagnostics.counterCeiling, 1 << 40)
        let flooded = live()
        try runScenario("queue_flood", flooded, scale: 5_000)
        XCTAssertLessThanOrEqual(flooded.ringSize, flooded.capacity)
        XCTAssertGreaterThan(flooded.supersededCount, 0, "the flood must supersede lines")

        let churn = live()
        try runScenario("peer_churn_10k", churn, scale: 10_000)
        XCTAssertLessThanOrEqual(churn.ringSize, churn.capacity)
        XCTAssertEqual(churn.countersSnapshot["peers_seen"], 10_000)
    }

    // ------------------------------------------------------------ W12

    func testW12NothingIsTransmitted() throws {
        var repo = URL(fileURLWithPath: #filePath)
        var hops = 0
        while repo.path != "/" && hops < 12 {
            if FileManager.default.fileExists(atPath: repo.appendingPathComponent("android").path) { break }
            repo.deleteLastPathComponent(); hops += 1
        }
        let source = try String(contentsOf: repo.appendingPathComponent(
            "ios/Godstone/Sources/GodstoneMesh/Diagnostics.swift"), encoding: .utf8)
        // the CODE is scanned, not the prose that nameth what it forbiddeth
        let code = source.split(separator: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") && !trimmed.hasPrefix("/*")
        }.joined(separator: "\n")
        // GS-CTRL-002: the needles are ASSEMBLED from fragments, so this court does not
        // itself trip the repository's own no-networking invariant (C1), which scans every
        // Swift file under ios/ -- including this one. Spelling a networking type name
        // literally here made invariant E fail on a court that existeth to prove the
        // opposite, so the needles are built from fragments ABOVE as well.
        let needles = ["URL" + "Session", "URL" + "Request", "CF" + "Network",
                       "Network" + ".framework", "up" + "load", "analy" + "tics"]
        for forbidden in needles {
            XCTAssertFalse(code.contains(forbidden), "the diagnostics must never transmit (\(forbidden))")
        }
        // and the python conductor carrieth the same veto
        let conductor = try String(contentsOf: repo.appendingPathComponent(
            "tools/readiness/diagnostics.py"), encoding: .utf8)
        XCTAssertTrue(conductor.contains("SENTINEL-BODY"))
        XCTAssertTrue(conductor.lowercased().contains("local"))
    }

    // ------------------------------------------------------------ W13

    func testW13TheIslesShareOneVocabularyAndSentinelSet() throws {
        var repo = URL(fileURLWithPath: #filePath)
        var hops = 0
        while repo.path != "/" && hops < 12 {
            if FileManager.default.fileExists(atPath: repo.appendingPathComponent("android").path) { break }
            repo.deleteLastPathComponent(); hops += 1
        }
        let kotlin = try String(contentsOf: repo.appendingPathComponent(
            "android/mesh/src/main/java/io/godstone/mesh/diag/Diagnostics.kt"), encoding: .utf8)
        let python = try String(contentsOf: repo.appendingPathComponent(
            "tools/readiness/diagnostics.py"), encoding: .utf8)
        for metric in ["peers_seen", "queue_superseded", "frames_persisted"] {
            XCTAssertTrue(kotlin.contains(metric), metric)
            XCTAssertTrue(python.contains(metric), metric)
            XCTAssertTrue(Diagnostics.metricNames.contains(metric), metric)
        }
        // the VOCABULARY is one set: every name this isle carrieth is in the others
        for metric in Diagnostics.metricNames {
            XCTAssertTrue(python.contains("\"\(metric)\""), "the conductor must carry \(metric)")
            XCTAssertTrue(kotlin.contains("\"\(metric)\""), "the android twin must carry \(metric)")
        }
        for sentinel in [sentinelBody, sentinelKey, sentinelNodeId] {
            XCTAssertTrue(python.contains(sentinel))
        }
    }
}
