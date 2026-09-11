import XCTest
@testable import GodstoneMesh

// ---------------------------------------------------------------------------
// T27 - the CANONICAL designated regression court (iOS). The manifest's
// required_regression_paths names this file; the narrow filter is
// `swift test --filter ReadinessT27Tests`. It replays the SHARED budget vector
// (wire/traffic_governor_vectors.txt) through the iOS PeerGovernor and asserts
// every decision equals the shared expect column -- the SAME file the sealed
// android governor reproduces (android ReadinessT27AndroidParityTest). Both
// isles matching one shared oracle is the "same adversarial trace, identical
// admit/drop on both platforms" evidence. It then witnesses the four required
// cases: shared-vector replay, bounded cache under churn, denial leaves existing
// trusted peers intact, and the semantic negative that the advertised hint is
// never the authenticated budget identity. The frozen Priority enum is read,
// never altered.
// ---------------------------------------------------------------------------

final class ReadinessT27Tests: XCTestCase {

    private let frozenMillis: Int64 = 1_700_000_000_000

    private func clock() -> () -> Int64 { let t = self.frozenMillis; return { t } }

    private func node(_ n: UInt8) -> Data {
        var d = Data(repeating: 0, count: 16)
        d[15] = n
        return d
    }

    private func hexToData(_ hex: String) -> Data {
        var s = Array(hex)
        if s.count % 2 == 1 { s.insert("0", at: 0) }
        var d = Data()
        var i = 0
        while i < s.count {
            if let b = UInt8(String(s[i..<(i + 2)]), radix: 16) { d.append(b) }
            i += 2
        }
        return d
    }

    private func loadVectorLines() throws -> [String] {
        var candidateUrls: [URL] = []
        let thisFile = URL(fileURLWithPath: #filePath)
        var root = thisFile
        for _ in 0..<5 { root = root.deletingLastPathComponent() }
        candidateUrls.append(root.appendingPathComponent("wire/traffic_governor_vectors.txt"))
        let candidatePaths = [
            "wire/traffic_governor_vectors.txt",
            "../wire/traffic_governor_vectors.txt",
            "../../wire/traffic_governor_vectors.txt",
            "../../../wire/traffic_governor_vectors.txt",
            "../../../../wire/traffic_governor_vectors.txt",
        ]
        for p in candidatePaths { candidateUrls.append(URL(fileURLWithPath: p)) }
        for url in candidateUrls {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                // the vector is pure ASCII; decode byte-wise so no String(contentsOf:) alias is needed
                var chars: [Character] = []
                chars.reserveCapacity(data.count)
                for b in data { chars.append(Character(UnicodeScalar(b))) }
                return String(chars).split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
            }
        }
        throw NSError(domain: "ReadinessT27Tests", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: "wire/traffic_governor_vectors.txt not found from " + #filePath])
    }

    // (1) shared budget vectors replay to the same decisions as the sealed android oracle
    func testSharedBudgetVectorsReplayIdenticalDecisionsOnIos() throws {
        let lines = try loadVectorLines()
        XCTAssertTrue(lines.first?.hasPrefix("#godstone-tgv-") ?? false, "recognise the vector format header")
        var gov: PeerGovernor?
        var scenario = "<none>"
        var step = 0
        var events = 0
        for raw in lines {
            let l = raw
            if l.isEmpty || l.hasPrefix("#") { continue }
            if l.hasPrefix("S ") {
                let parts = l.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
                scenario = parts[1]
                let maxToken = parts[2]
                let maxStr = maxToken.split(separator: "=", omittingEmptySubsequences: true).map { String($0) }
                let mx = Int(maxStr[1]) ?? 4096
                gov = PeerGovernor(nowMillis: clock(), maxTrackedPeers: mx)
                step = 0
                continue
            }
            if l.hasPrefix("E ") {
                guard let g = gov else { XCTFail("E line outside a scenario in " + scenario, file: #file, line: #line); continue }
                let parts = l.split(separator: " ", omittingEmptySubsequences: true).map { String($0) }
                let idHex = parts[1]
                let prio = Priority(rawValue: Int(parts[3]) ?? 1) ?? .direct
                let expect = parts[4] == "1"
                step += 1
                events += 1
                let hintTok = parts[2]
                let hint: Data? = (hintTok == "-") ? nil : hexToData(hintTok)
                let actual = g.allowInbound(hexToData(idHex), priority: prio, advertisedHint: hint)
                XCTAssertEqual(actual, expect,
                               "parity divergence in scenario '\(scenario)' step \(step) id=\(idHex) prio=\(parts[3]): expected \(expect) got \(actual)",
                               file: #file, line: #line)
            }
        }
        XCTAssertGreaterThan(events, 200, "the vector carried a meaningful number of events")
    }

    // (2) bounded cache under Sybil churn: tracked set is capped; a known peer is served
    func testBoundedCacheHoldsUnderSybilChurn() {
        let g = PeerGovernor(nowMillis: clock(), maxTrackedPeers: 8)
        var served = 0
        for k in 0..<12 {
            if g.allowInbound(node(UInt8(0xD0 &+ k)), priority: .direct) { served += 1 }
        }
        XCTAssertEqual(served, 8, "the eight within the bound are served")
        XCTAssertEqual(g.trackedPeerCount(), 8, "the registry is capped at maxTrackedPeers")
        XCTAssertFalse(g.allowInbound(node(0xEE), priority: .direct), "a fresh over-cap identity is refused")
        XCTAssertEqual(g.trackedPeerCount(), 8, "the registry stays bounded -- no entry for the refused Sybil")
        XCTAssertTrue(g.allowInbound(node(0xD0), priority: .direct), "a tracked identity is still served at the cap")
    }

    // (3) denial leaves EXISTING trusted peers intact (per-identity isolation)
    func testDenialLeavesExistingTrustedPeersIntact() {
        let g = PeerGovernor(nowMillis: clock(), maxTrackedPeers: 64)
        let attacker = node(0xE3)
        let bystander = node(0xE1)
        var by = 0
        for _ in 0..<10 { if g.allowInbound(bystander, priority: .direct) { by += 1 } }
        var drop = 0
        for _ in 0..<18 { if g.allowInbound(attacker, priority: .bulk) { drop += 1 } }
        var after = 0
        for _ in 0..<2 { if g.allowInbound(bystander, priority: .direct) { after += 1 } }
        XCTAssertEqual(by, 10, "the bystander keeps its own full budget before the flood")
        XCTAssertEqual(drop, 10, "the attacker is bounded to its 10-token BULK bucket")
        XCTAssertEqual(after, 2, "the bystander is undisturbed by the attacker's denials")
    }

    // (4) the ADVERTISED HINT is never the authenticated budget identity (semantic negative):
    //     two DISTINCT authenticated peers that SHARE one advertised hint must be governed
    //     SEPARATELY -- each gets its own full DIRECT bucket. A governor that keyed the budget
    //     by the untrusted hint would conflate them into one 60-token bucket, so the second
    //     peer's calls would begin to drop -- this witness is the T27-SM1 killer.
    func testAdvertisedHintIsNeverTheAuthenticatedIdentity() {
        let g = PeerGovernor(nowMillis: clock(), maxTrackedPeers: 64)
        let sharedHint = Data([0x0B, 0xAD, 0xF0, 0x0D])
        let a = node(0xF1)
        let b = node(0xF2)
        XCTAssertNotEqual(a, b, "the two authenticated ids are distinct")
        var aServed = 0
        for _ in 0..<60 { if g.allowInbound(a, priority: .direct, advertisedHint: sharedHint) { aServed += 1 } }
        var bServed = 0
        for _ in 0..<60 { if g.allowInbound(b, priority: .direct, advertisedHint: sharedHint) { bServed += 1 } }
        XCTAssertEqual(aServed, 60, "peer A gets its own full 60-token DIRECT budget")
        XCTAssertEqual(bServed, 60, "peer B -- sharing the advertised hint -- ALSO gets its own full 60-token budget, never a shared/conflated one")
    }

    // (5) a malformed/short advertised hint cannot collapse distinct identities
    func testMalformedHintDoesNotCollapseDistinctIdentities() {
        let g = PeerGovernor(nowMillis: clock(), maxTrackedPeers: 64)
        let x = node(0x34)
        let y = node(0x78)
        var xs = 0
        for _ in 0..<10 { if g.allowInbound(x, priority: .bulk, advertisedHint: Data([0xFF])) { xs += 1 } }
        var ys = 0
        for _ in 0..<10 { if g.allowInbound(y, priority: .bulk, advertisedHint: nil) { ys += 1 } }
        XCTAssertEqual(xs, 10, "distinct authenticated id with a 1-byte hint keeps its own BULK budget")
        XCTAssertEqual(ys, 10, "distinct authenticated id with a nil hint keeps its OWN separate BULK budget")
    }
}
