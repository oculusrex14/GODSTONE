import Foundation
import XCTest
@testable import GodstoneMesh
@testable import GodstoneCore

// T40 readiness court (iOS isle) -- twin of ReadinessT40Test.kt.
//
// The anti-entropy control plane (blueprint section 14, ADR-009): versioned
// payloads riding the EXISTING HELLO/DIGEST/WANT/PING codes, struck once by
// the independent reference (wire/anti_entropy_reference.py) from the one
// bloom authority (crypto/gmp21.py) into the one table
// (crypto/anti_entropy_vectors.json). This isle's codecs are measured against
// THAT table -- cross-platform exact bytes: the isles must agree with the
// table, not merely with each other.
//
// Witnesses: W1 cross-platform exact bytes; W2 truncations and size
// disorders by their named failures; W3 the builders refuse duplicates and
// out-of-range counts; W4 sequence discipline on the received pages; W5 the
// stale digest is ignored and the tracked one stands; W6 the inventory walk
// wraps around the end; W7 the full 512-byte bloom travels the ATT leg at
// MTU 20; W8 a forced bloom collision converges -- through exact
// reconciliation alone; W9 eviction is forgotten by the fresh capture (the
// semantic negative's first limb); W10 the snapshot authority's discipline;
// W11 the control campaign census: no control frame ever reaches held
// message storage, the seen window stays pure, and the sealed MESSAGE/SOS
// road remains open.
//
// Every assertion carries its positive counts (the card demands scenario
// assertions with positive counts).

// ------------------------------------------------------------------
// the one table, read whole: file-private JSON readers
// ------------------------------------------------------------------

private enum Json {
    case obj([String: Json])
    case arr([Json])
    case str(String)
    case num(String)
}

private struct JsonReader {
    let src: [Character]
    var i = 0

    init(_ s: String) { src = Array(s) }

    private mutating func skip() {
        while i < src.count && (src[i] == " " || src[i] == "\t" || src[i] == "\r" || src[i] == "\n") { i += 1 }
    }
    private mutating func expect(_ c: Character) throws {
        skip()
        guard i < src.count, src[i] == c else { throw ControlException(.truncated) }
        i += 1
    }
    private mutating func readValue() throws -> Json {
        skip()
        guard i < src.count else { throw ControlException(.truncated) }
        switch src[i] {
        case "{": return try readObj()
        case "[": return try readArr()
        case "\"": return .str(try readStr())
        default:
            if src[i] == "-" || (src[i] >= "0" && src[i] <= "9") { return readNum() }
            throw ControlException(.truncated)
        }
    }
    private mutating func readObj() throws -> Json {
        var d = [String: Json]()
        try expect("{")
        skip()
        if i < src.count && src[i] == "}" { i += 1; return .obj(d) }
        while true {
            skip()
            let k = try readStr()
            try expect(":")
            d[k] = try readValue()
            skip()
            guard i < src.count else { throw ControlException(.truncated) }
            let c = src[i]; i += 1
            if c == "," { continue }
            if c == "}" { break }
            throw ControlException(.truncated)
        }
        return .obj(d)
    }
    private mutating func readArr() throws -> Json {
        var a = [Json]()
        try expect("[")
        skip()
        if i < src.count && src[i] == "]" { i += 1; return .arr(a) }
        while true {
            a.append(try readValue())
            skip()
            guard i < src.count else { throw ControlException(.truncated) }
            let c = src[i]; i += 1
            if c == "," { continue }
            if c == "]" { break }
            throw ControlException(.truncated)
        }
        return .arr(a)
    }
    private mutating func readStr() throws -> String {
        try expect("\"")
        var s = ""
        while i < src.count {
            let c = src[i]; i += 1
            if c == "\"" { break }
            if c == "\\" {
                guard i < src.count else { throw ControlException(.truncated) }
                let e = src[i]; i += 1
                switch e {
                case "n": s.append("\n")
                case "t": s.append("\t")
                case "r": s.append("\r")
                case "\"": s.append("\"")
                case "\\": s.append("\\")
                case "/": s.append("/")
                default: throw ControlException(.truncated)
                }
            } else { s.append(c) }
        }
        return s
    }
    private mutating func readNum() -> Json {
        let start = i
        if src[i] == "-" { i += 1 }
        while i < src.count, "0123456789.eE+-".contains(src[i]) { i += 1 }
        return .num(String(src[start..<i]))
    }
    mutating func parseWhole() throws -> Json { try readValue() }
}

/// The house way of the T38 court: a failed read reports itself loudly and
/// returns a sentinel the later comparisons will catch.
private func failJson(_ why: String) {
    XCTFail("the table offends: \(why)")
}
private func jDict(_ j: Json?) -> [String: Json] {
    if case .obj(let d)? = j { return d }
    failJson("object expected")
    return [:]
}
private func jList(_ j: Json?) -> [Json] {
    if case .arr(let a)? = j { return a }
    failJson("array expected")
    return []
}
private func jString(_ j: Json?) -> String {
    if case .str(let s)? = j { return s }
    failJson("string expected")
    return ""
}
private func jU64(_ j: Json?) -> UInt64 {
    if case .num(let s)? = j, let v = UInt64(s) { return v }
    failJson("unsigned 64 expected")
    return 0
}
private func jInt(_ j: Json?) -> Int {
    if case .num(let s)? = j, let v = Int(s) { return v }
    failJson("integer expected")
    return 0
}

private final class Table {
    let constants: [String: Json]
    let payloads: [[String: Json]]
    let malformed: [[String: Json]]
    let frames: [[String: Json]]
    let walks: [[String: Json]]
    let collision: [String: Json]
    let att: [String: Json]
    let storeIds: [String]

    init(_ root: Json) {
        let r = jDict(root)
        constants = jDict(r["constants"])
        payloads = jList(r["payloads"]).map { jDict($0) }
        malformed = jList(r["malformed"]).map { jDict($0) }
        frames = jList(r["frames"]).map { jDict($0) }
        walks = jList(r["walk"]).map { jDict($0) }
        collision = jDict(r["collision"])
        att = jDict(r["att"])
        storeIds = jList(r["store"]).map { jString($0) }
    }
}

private func u8(_ x: Int) -> UInt8 { UInt8(x & 0xFF) }
private func u16(_ x: Int) -> UInt16 { UInt16(x & 0xFFFF) }

private protocol ControlEncodable { func encode() -> Data }
extension ControlDigest: ControlEncodable {}
extension ControlWant: ControlEncodable {}
extension ControlInventoryRequest: ControlEncodable {}
extension ControlInventoryPage: ControlEncodable {}
extension ControlReset: ControlEncodable {}
extension ControlPing: ControlEncodable {}

final class ReadinessT40Tests: XCTestCase {

    // ------------------------------------------------------------------
    // the one table
    // ------------------------------------------------------------------

    private static var cachedTable: Table?

    private func table() -> Table {
        if let cached = ReadinessT40Tests.cachedTable { return cached }
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir
                .appendingPathComponent("crypto")
                .appendingPathComponent("anti_entropy_vectors.json")
            if let raw = try? Data(contentsOf: candidate),
               let text = String(data: raw, encoding: .utf8) {
                var reader = JsonReader(text)
                guard let root = try? reader.parseWhole() else {
                    XCTFail("the table does not parse")
                    return Table(.obj([:]))
                }
                let t = Table(root)
                ReadinessT40Tests.cachedTable = t
                return t
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("no crypto/anti_entropy_vectors.json in view from \(#filePath)")
        return Table(.obj([:]))
    }

    // ------------------------------------------------------------------
    // fixtures
    // ------------------------------------------------------------------

    private func makeIdentity(_ seedByte: UInt8, _ xByte: UInt8) throws -> MeshIdentity {
        let state = try LocalIdentityStateV1(generation: 0,
            ed25519Seed: Data(repeating: seedByte, count: 32),
            x25519PrivateKey: Data(repeating: xByte, count: 32))
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.v1Tag] = try state.encode()
        return try MeshIdentity.loadFromKeychain(keychain: kc)
    }

    private func peer(_ seedByte: UInt8) -> Data {
        Data((0..<16).map { u8(Int(seedByte) &* 31 + $0) })
    }

    private final class NoAuth: AckAuthenticator, @unchecked Sendable {
        func verify(originalMsgId: Data, expectedRecipientNodeId: Data, ackFrame: FrameV2) -> Bool { false }
    }

    private func messageFrame(_ msgId: Data, _ payloadSize: Int = 40) -> FrameV2 {
        FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: Data(repeating: 0, count: 4),
            ttl: 4,
            hopCount: 0,
            flags: u16(3 << 8),                       // priority BROADCAST in bits 9..8
            payload: Data((0..<payloadSize).map { u8($0 &* 7 + 3) })
        )
    }

    /// The deterministic evict-campaign id, pre-verified against
    /// crypto/gmp21.py: octet 0 = 0xE4, octets 1..15 = the 15-digit
    /// zero-padded decimal of k (ASCII).
    private func evictId(_ k: Int) -> Data {
        let raw = String(k)
        let digits = String(repeating: "0", count: 15 - raw.count) + raw
        var out = Data(repeating: 0, count: 16)
        out[0] = 0xE4
        for (j, ch) in digits.enumerated() { out[j + 1] = UInt8(ascii: ch) }
        return out
    }

    private func unhex(_ s: String) -> Data {
        let clean = String(s.filter { !$0.isWhitespace })
        precondition(clean.count % 2 == 0, "hex must pair")
        var out = Data()
        var it = clean.startIndex
        while it < clean.endIndex {
            let nxt = clean.index(it, offsetBy: 2)
            out.append(UInt8(clean[it..<nxt], radix: 16)!)
            it = nxt
        }
        return out
    }

    /// A counting delegate: records every persist and every id ever seen.
    private final class CountingStore: MessageStore, @unchecked Sendable {
        let delegate: InMemoryMessageStore
        var persistCount = 0
        var seenAll = [Data]()
        var heldBytes: Int64 { delegate.heldBytes }
        init(delegate: InMemoryMessageStore) { self.delegate = delegate }
        func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult {
            persistCount += 1
            seenAll.append(frame.msgId)
            return delegate.persist(frame, receivedFrom: receivedFrom)
        }
        func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data, localOriginNodeId: Data) -> OutboundEnqueueResult {
            delegate.enqueueDirectOutbound(frame, expectedRecipient: expectedRecipient, localOriginNodeId: localOriginNodeId)
        }
        func allHeldOrderedByPriority() -> [FrameV2] { delegate.allHeldOrderedByPriority() }
        func allHeldMsgIds() -> [Data] { delegate.allHeldMsgIds() }
        func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) { delegate.forEachHeldOrderedByPriority(visit) }
        func forEachHeldMsgId(_ visit: (Data) -> Bool) { delegate.forEachHeldMsgId(visit) }
        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) { delegate.registerHeldSetObserver(observer) }
    }

    /// A store whose walk advances an injected clock: the read-budget trap.
    private final class BudgetTrapStore: MessageStore, @unchecked Sendable {
        let delegate: InMemoryMessageStore
        let advancePerVisit: Int64
        let sink: (Int64) -> Void
        var heldBytes: Int64 { delegate.heldBytes }
        init(delegate: InMemoryMessageStore, advancePerVisit: Int64, sink: @escaping (Int64) -> Void) {
            self.delegate = delegate
            self.advancePerVisit = advancePerVisit
            self.sink = sink
        }
        func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult { delegate.persist(frame, receivedFrom: receivedFrom) }
        func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data, localOriginNodeId: Data) -> OutboundEnqueueResult {
            delegate.enqueueDirectOutbound(frame, expectedRecipient: expectedRecipient, localOriginNodeId: localOriginNodeId)
        }
        func allHeldOrderedByPriority() -> [FrameV2] { delegate.allHeldOrderedByPriority() }
        func allHeldMsgIds() -> [Data] { delegate.allHeldMsgIds() }
        func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) { delegate.forEachHeldOrderedByPriority(visit) }
        func forEachHeldMsgId(_ visit: (Data) -> Bool) {
            for id in delegate.allHeldMsgIds() {
                sink(advancePerVisit)
                if !visit(id) { return }
            }
        }
        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) { delegate.registerHeldSetObserver(observer) }
    }

    private func armOf(_ name: String) -> ControlArm {
        guard let arm = ControlArm.fromWireName(name) else {
            XCTFail("the table names an unknown arm: \(name)")
            return .digest
        }
        return arm
    }

    private func decisionReason(_ d: SyncControlOwner.OwnerDecision) -> String {
        switch d {
        case .ignored(reason: let reason): return reason
        case .refused(reason: let reason): return reason
        default: return "accepted"
        }
    }

    /// A page speaks with its own snapshot id when it carries one; the lawful
    /// page_after output omits it and the stream's stands.
    private func pageSid(_ pageObj: [String: Json], _ stream: [String: Json]) -> UInt64 {
        if pageObj["snapshot_id"] != nil { return jU64(pageObj["snapshot_id"]) }
        return jU64(stream["snapshot_id"])
    }

    private func expectRefusal(_ what: String, _ name: String, _ body: () throws -> Void) {
        do {
            try body()
            XCTFail("\(what): must have raised \(name)")
        } catch let e as ControlException {
            XCTAssertEqual(e.failure.rawValue, name, "\(what): failure name")
        } catch {
            XCTFail("\(what): foreign error \(error)")
        }
    }

    // ------------------------------------------------------------------
    // W1 -- cross-platform exact bytes
    // ------------------------------------------------------------------
    func testEncodeDecodeCrossPlatformExactBytes() throws {
        let t = table()
        XCTAssertEqual(jInt(t.constants["version"]), 1, "version macro")
        XCTAssertEqual(jInt(t.constants["bloom_bytes"]), 512, "BLOOM_BYTES")
        XCTAssertEqual(jInt(t.constants["id_size_bytes"]), 16, "ID_BYTES")
        XCTAssertEqual(jInt(t.constants["max_ids_per_arm"]), 32, "MAX_IDS")
        let sub = jDict(t.constants["subtype"])
        XCTAssertEqual(jInt(sub["inventory_request"]), 1, "SUBTYPE request")
        XCTAssertEqual(jInt(sub["inventory_page"]), 2, "SUBTYPE page")
        XCTAssertEqual(jInt(sub["reset"]), 3, "SUBTYPE reset")

        var encoded = 0, decoded = 0
        for v in t.payloads {
            let name = jString(v["name"])
            let arm = armOf(jString(v["arm"]))
            let input = jDict(v["input"])
            let struct_ = jDict(v["struct"])
            let want = unhex(jString(v["payload_hex"]))

            let built: any ControlEncodable
            switch arm {
            case .digest:
                built = try ControlDigest(snapshotId: jU64(input["snapshot_id"]), bloom: unhex(jString(input["bloom"])))
            case .want:
                built = try ControlWant(snapshotId: jU64(input["snapshot_id"]), ids: jList(input["ids"]).map { unhex(jString($0)) })
            case .inventoryRequest:
                built = try ControlInventoryRequest(snapshotId: jU64(input["snapshot_id"]),
                                                   cursorPresent: u8(jInt(input["cursor_present"])),
                                                   cursor: unhex(jString(input["cursor"])))
            case .inventoryPage:
                built = try ControlInventoryPage(snapshotId: jU64(input["snapshot_id"]),
                                                done: u8(jInt(input["done"])),
                                                ids: jList(input["ids"]).map { unhex(jString($0)) })
            case .reset:
                built = try ControlReset(newSnapshotId: jU64(input["new_snapshot_id"]))
            case .ping:
                built = try ControlPing(reply: u8(jInt(input["reply"])), nonce: jU64(input["nonce"]))
            }
            let bytes = built.encode()
            XCTAssertEqual(bytes, want, "\(name): encode must equal the table octets")

            guard case .ok(let got) = ControlPayloadV1.decode(arm: arm, bytes) else {
                XCTFail("\(name): decode rejected a canonical payload")
                continue
            }
            switch (got, arm) {
            case (.digest(let g), .digest):
                XCTAssertEqual(g.snapshotId, jU64(struct_["snapshot_id"]), "\(name): sid")
                XCTAssertEqual(g.bloom, unhex(jString(struct_["bloom"])), "\(name): bloom")
            case (.want(let g), .want):
                XCTAssertEqual(g.snapshotId, jU64(struct_["snapshot_id"]), "\(name): sid")
                XCTAssertEqual(g.ids.count, jInt(struct_["count"]), "\(name): count")
                let ids = jList(struct_["ids"])
                for (k, e) in ids.enumerated() {
                    XCTAssertEqual(g.ids[k], unhex(jString(e)), "\(name): ids[\(k)] order preserved")
                }
            case (.inventoryRequest(let g), .inventoryRequest):
                XCTAssertEqual(g.snapshotId, jU64(struct_["snapshot_id"]), "\(name): sid")
                XCTAssertEqual(Int(g.cursorPresent), jInt(struct_["cursor_present"]), "\(name): cursorPresent")
                XCTAssertEqual(g.cursor, unhex(jString(struct_["cursor"])), "\(name): cursor")
            case (.inventoryPage(let g), .inventoryPage):
                XCTAssertEqual(g.snapshotId, jU64(struct_["snapshot_id"]), "\(name): sid")
                XCTAssertEqual(Int(g.done), jInt(struct_["done"]), "\(name): done")
                XCTAssertEqual(g.ids.count, jInt(struct_["count"]), "\(name): count")
                let ids = jList(struct_["ids"])
                for (k, e) in ids.enumerated() {
                    XCTAssertEqual(g.ids[k], unhex(jString(e)), "\(name): ids[\(k)]")
                }
            case (.reset(let g), .reset):
                XCTAssertEqual(g.newSnapshotId, jU64(struct_["new_snapshot_id"]), "\(name): new sid")
            case (.ping(let g), .ping):
                XCTAssertEqual(Int(g.reply), jInt(struct_["reply"]), "\(name): reply")
                XCTAssertEqual(g.nonce, jU64(struct_["nonce"]), "\(name): nonce")
            default:
                XCTFail("\(name): the arm and the payload disagree")
            }
            XCTAssertEqual(got.encode(), want, "\(name): re-encode reproduces the very octets")
            encoded += 1; decoded += 1
        }
        XCTAssertEqual(encoded, 18, "payload vectors encoded")
        XCTAssertEqual(decoded, 18, "payload vectors decoded back")

        var framed = 0
        for f in t.frames {
            let name = jString(f["name"])
            let arm = armOf(jString(f["arm"]))
            let wire = try ControlPayloadV1.frameFor(arm: arm,
                                                    msgId: unhex(jString(f["msg_id"])),
                                                    routingTag: unhex(jString(f["routing_tag"])),
                                                    payload: unhex(jString(f["payload_hex"])))
            XCTAssertEqual(wire.encode(), unhex(jString(f["frame_hex"])), "\(name): frame octets")
            XCTAssertEqual(Int(wire.ttl), 0, "\(name): ttl keeps the control-only zero")
            XCTAssertEqual(Int(wire.hopCount), 0, "\(name): hop keeps the control-only zero")
            XCTAssertEqual(wire.flags, 0, "\(name): flags keep the control-only zero")
            guard let back = FrameV2.decode(wire.encode()) else {
                XCTFail("\(name): the frozen decoder refuses its own frame")
                continue
            }
            XCTAssertEqual(back.type, arm.outerCode, "\(name): outer code")
            XCTAssertEqual(back.msgId, wire.msgId, "\(name): msg_id")
            XCTAssertEqual(back.routingTag, wire.routingTag, "\(name): routing_tag")
            XCTAssertEqual(back.payload, wire.payload, "\(name): payload")
            framed += 1
        }
        XCTAssertEqual(framed, 18, "frame vectors sealed and unsealed")
        XCTAssertEqual(TypeV2(rawValue: 0x12)!, .digest, "DIGEST rides 0x12")
        XCTAssertEqual(TypeV2(rawValue: 0x14)!, .want, "WANT rides 0x14")
        XCTAssertEqual(TypeV2(rawValue: 0x28)!, .ping, "PING rides 0x28")
        for n in ["inventory_request", "inventory_page", "reset"] {
            XCTAssertEqual(armOf(n).outerCode, .hello, "\(n) rides HELLO")
        }
    }

    // ------------------------------------------------------------------
    // W2 -- every malformed payload refused by its named failure
    // ------------------------------------------------------------------
    func testDecodeRejectsEveryMalformedPayloadByItsName() throws {
        let t = table()
        var refusedCount = 0
        var namesSeen = Set<String>()
        for m in t.malformed {
            let name = jString(m["name"])
            let arm = armOf(jString(m["arm"]))
            let expected = jString(m["expect_failure"])
            let raw = unhex(jString(m["payload_hex"]))
            guard case .err(failure: let failure, hint: _) = ControlPayloadV1.decode(arm: arm, raw) else {
                XCTFail("\(name): must refuse \(expected)")
                continue
            }
            XCTAssertEqual(failure.rawValue, expected, "\(name): failure name")
            XCTAssertTrue(ControlPayloadV1.failureNames.contains(failure.rawValue), "\(name): name must be in the alphabet")
            guard case .err(failure: let second, hint: _) = ControlPayloadV1.decode(arm: arm, raw) else {
                XCTFail("\(name): refusal is not stable")
                continue
            }
            XCTAssertEqual(second.rawValue, failure.rawValue, "\(name): refusal stable")
            namesSeen.insert(failure.rawValue)
            refusedCount += 1
        }
        XCTAssertEqual(refusedCount, 40, "malformed vectors refused")
        // the decoder's own alphabet is the ten wire laws; sequence_break is
        // the owner's law of the received stream, proven by W4 over the corrupted walks
        let decodeLaw = Set(ControlPayloadV1.failureNames).subtracting(["sequence_break"])
        XCTAssertEqual(namesSeen, decodeLaw, "every decoder-law name exercised")
        XCTAssertEqual(ControlPayloadV1.failureNames.count, 11, "the alphabet has eleven names")
        XCTAssertFalse(namesSeen.contains("sequence_break"), "sequence_break stands reserved for the owner")
    }

    // ------------------------------------------------------------------
    // W3 -- the builders validate and name their rejects
    // ------------------------------------------------------------------
    func testBuilderValidationNamesTheRejects() throws {
        var checked = 0
        func expectRaise(_ what: String, _ name: String, _ body: () throws -> Void) {
            expectRefusal(what, name, body)
            checked += 1
        }
        let a = Data((0..<16).map { u8($0) })
        let b = Data((0..<16).map { u8($0 + 1) })

        expectRaise("want 33 ids", "count_out_of_range") {
            _ = try ControlWant(snapshotId: 7, ids: (0...32).map { n in Data((0..<16).map { u8($0 + n + 1) }) })
        }
        expectRaise("want empty", "count_out_of_range") { _ = try ControlWant(snapshotId: 7, ids: []) }
        expectRaise("want duplicates", "duplicate_ids") { _ = try ControlWant(snapshotId: 7, ids: [a, b, a]) }
        expectRaise("want a 15-octet id", "wrong_size") { _ = try ControlWant(snapshotId: 7, ids: [Data(repeating: 0, count: 15)]) }
        expectRaise("want zero sid", "zero_snapshot_id") { _ = try ControlWant(snapshotId: 0, ids: [a]) }
        expectRaise("page done=0 empty", "bad_done") { _ = try ControlInventoryPage(snapshotId: 7, done: 0, ids: []) }
        expectRaise("page done=2", "bad_done") { _ = try ControlInventoryPage(snapshotId: 7, done: 2, ids: [a]) }
        expectRaise("page 33 ids", "count_out_of_range") {
            _ = try ControlInventoryPage(snapshotId: 7, done: 1, ids: (0...32).map { n in Data((0..<16).map { u8($0 + n + 1) }) })
        }
        expectRaise("page duplicates", "duplicate_ids") { _ = try ControlInventoryPage(snapshotId: 7, done: 0, ids: [a, a]) }
        expectRaise("request cp=2", "bad_cursor") { _ = try ControlInventoryRequest(snapshotId: 7, cursorPresent: 2, cursor: Data(repeating: 0, count: 16)) }
        expectRaise("request cp=0 with a non-zero filler", "bad_cursor") {
            var filler = Data(repeating: 0, count: 16); filler[15] = 1
            _ = try ControlInventoryRequest(snapshotId: 7, cursorPresent: 0, cursor: filler)
        }
        expectRaise("request a 15-octet cursor", "bad_cursor") { _ = try ControlInventoryRequest(snapshotId: 7, cursorPresent: 1, cursor: Data(repeating: 0, count: 15)) }
        expectRaise("request zero sid", "zero_snapshot_id") { _ = try ControlInventoryRequest(snapshotId: 0, cursorPresent: 0, cursor: Data(repeating: 0, count: 16)) }
        expectRaise("digest short bloom", "wrong_size") { _ = try ControlDigest(snapshotId: 1, bloom: Data(repeating: 0, count: 511)) }
        expectRaise("digest zero sid", "zero_snapshot_id") { _ = try ControlDigest(snapshotId: 0, bloom: Data(repeating: 0, count: 512)) }
        expectRaise("reset zero sid", "zero_snapshot_id") { _ = try ControlReset(newSnapshotId: 0) }
        expectRaise("ping reply=2", "bad_reply") { _ = try ControlPing(reply: 2, nonce: 9) }
        expectRaise("frame with a 15-octet msg_id", "wrong_size") {
            _ = try ControlPayloadV1.frameFor(arm: .ping, msgId: Data(repeating: 0, count: 15), routingTag: Data(repeating: 0, count: 4), payload: Data())
        }
        expectRaise("frame with a 3-octet tag", "wrong_size") {
            _ = try ControlPayloadV1.frameFor(arm: .ping, msgId: Data(repeating: 0, count: 16), routingTag: Data(repeating: 0, count: 3), payload: Data())
        }
        expectRaise("wantSplit maxPerWant=0", "count_out_of_range") { _ = try ControlPayloadV1.wantSplit(snapshotId: 7, ids: [a], maxPerWant: 0) }
        expectRaise("wantSplit maxPerWant=33", "count_out_of_range") { _ = try ControlPayloadV1.wantSplit(snapshotId: 7, ids: [a], maxPerWant: 33) }
        expectRaise("wantSplit over the arm bound", "count_out_of_range") {
            _ = try ControlPayloadV1.wantSplit(snapshotId: 7, ids: (0..<40).map { n in Data((0..<16).map { u8($0 + n + 1) }) }, maxPerWant: 16)
        }
        let ids = (0..<30).map { n in Data((0..<16).map { u8($0 + n + 1) }) }
        let parts = try ControlPayloadV1.wantSplit(snapshotId: 7, ids: ids, maxPerWant: 16)
        XCTAssertEqual(parts.map { $0.ids.count }, [16, 14], "the split keeps its measures")
        XCTAssertEqual(parts[0].ids[0], ids[0], "order preserved at the head")
        XCTAssertEqual(parts[1].ids[13], ids[29], "order preserved at the tail")
        XCTAssertGreaterThanOrEqual(checked, 22, "builder validations counted")
    }

    // ------------------------------------------------------------------
    // W4 -- sequence discipline on the received pages
    // ------------------------------------------------------------------
    func testSequenceDisciplineOnReceivedPages() throws {
        let t = table()
        let store = InMemoryMessageStore()
        var tnow: Int64 = 1_000
        let authority = InventorySnapshotAuthority(store: store, monotonicNowMillis: { tnow })
        let owner = SyncControlOwner(store: store, authority: authority, monotonicNowMillis: { tnow }, localNodeId: peer(9))
        let thePeer = peer(7)
        let bloom = Data(repeating: 0, count: 512)                    // the walk is about the sequence
        let rel = owner.relation(for: thePeer)

        let digest = try ControlDigest(snapshotId: 42, bloom: bloom)
        let df = try ControlPayloadV1.frameFor(arm: .digest,
            msgId: Data((0..<16).map { u8($0 + 3) }),
            routingTag: Data(repeating: 0, count: 4), payload: digest.encode())
        guard case .accepted = owner.handleControlFrame(df, from: thePeer) else {
            XCTFail("digest adopted")
            return
        }
        XCTAssertTrue(owner.startInventoryRun(thePeer), "the run opens")
        let first = owner.pumpNextInventoryFrames(thePeer)
        XCTAssertEqual(first.count, 1, "one request frame on the opening turn")
        guard case .ok(.inventoryRequest(let req0)) = ControlPayloadV1.decodeFor(type: first[0].type, first[0].payload) else {
            XCTFail("the request is canonical")
            return
        }
        XCTAssertEqual(Int(req0.cursorPresent), 0, "the walk starts at the beginning")
        XCTAssertEqual(req0.cursor, Data(repeating: 0, count: 16), "with the all-zero filler")

        guard let clean = t.walks.first(where: { jString($0["name"]) == "walk_100_by_32" }) else {
            XCTFail("the clean walk is missing")
            return
        }
        let pages = jList(clean["pages"]).map { jDict($0) }
        XCTAssertEqual(pages.count, 4, "the walk needs four pages")
        var pumpedWants = [FrameV2]()
        var fed = 0
        for (k, pageObj) in pages.enumerated() {
            let p = try ControlInventoryPage(
                snapshotId: pageSid(pageObj, clean),
                done: u8(jInt(pageObj["done"])),
                ids: jList(pageObj["ids"]).map { unhex(jString($0)) }
            )
            let pf = try ControlPayloadV1.frameFor(arm: .inventoryPage,
                msgId: Data((0..<16).map { u8($0 + 11 + k) }),
                routingTag: Data(repeating: 0, count: 4), payload: p.encode())
            let dec = owner.handleControlFrame(pf, from: thePeer)
            guard case .accepted = dec else {
                XCTFail("page \(k + 1) accepted, got \(dec)")
                return
            }
            fed += 1
            if k == 1 {
                let more = owner.pumpNextInventoryFrames(thePeer)
                pumpedWants += more.filter { $0.type == .want }
                guard let rq = more.first(where: { $0.type == .hello }) else {
                    XCTFail("the walk continues with a request")
                    return
                }
                guard case .ok(.inventoryRequest(let r2)) = ControlPayloadV1.decodeFor(type: rq.type, rq.payload) else {
                    XCTFail("the continuation is canonical")
                    return
                }
                guard let cont = t.payloads.first(where: { jString($0["name"]) == "request_continuation" }) else {
                    XCTFail("the continuation vector is missing")
                    return
                }
                XCTAssertEqual(r2.encode(), unhex(jString(cont["payload_hex"])),
                               "the resumable cursor names the very next request the table strikes")
                let lastOfSecond = jList(pages[1]["ids"])
                XCTAssertEqual(r2.cursor, unhex(jString(lastOfSecond[lastOfSecond.count - 1])),
                               "after page 2 the run waits on the right page")
            }
        }
        XCTAssertEqual(fed, 4, "pages fed")
        XCTAssertEqual(rel.pagesReceived, 4, "pages received")
        XCTAssertEqual(rel.pagesReceived, fed, "pages fed equal pages received")
        XCTAssertTrue(rel.runDone, "the run closed by the final done")
        XCTAssertNil(owner.checkSequence(rel), "the coherent stream certifies")

        pumpedWants += owner.pumpNextInventoryFrames(thePeer).filter { $0.type == .want }
        XCTAssertEqual(pumpedWants.count, 4, "the missing ids are requested in four want frames")
        var requested = 0
        for f in pumpedWants {
            guard case .ok(.want(let w)) = ControlPayloadV1.decode(arm: .want, f.payload) else {
                XCTFail("the want is canonical")
                continue
            }
            XCTAssertLessThanOrEqual(w.ids.count, 32, "a want never exceeds the arm bound")
            requested += w.ids.count
        }
        XCTAssertEqual(requested, 100, "every received-but-unheld id was requested")

        for (idx, cv) in t.walks.enumerated() where cv["expect_failure"] != nil {
            let cpeer = peer(u8(20 + idx))                          // a fresh relation per stream
            let crel = owner.relation(for: cpeer)
            let dd = try ControlDigest(snapshotId: jU64(cv["snapshot_id"]), bloom: bloom)
            let df2 = try ControlPayloadV1.frameFor(arm: .digest,
                msgId: Data((0..<16).map { u8($0 + 3) }),
                routingTag: Data(repeating: 0, count: 4), payload: dd.encode())
            _ = owner.handleControlFrame(df2, from: cpeer)
            XCTAssertTrue(owner.startInventoryRun(cpeer), "stream \(jString(cv["name"])) opens")
            _ = owner.pumpNextInventoryFrames(cpeer)                     // the opening request
            var verdict = SyncControlOwner.OwnerDecision.accepted
            for pageObj in jList(cv["pages"]).map({ jDict($0) }) {
                let p = try ControlInventoryPage(
                    snapshotId: pageSid(pageObj, cv),
                    done: u8(jInt(pageObj["done"])),
                    ids: jList(pageObj["ids"]).map { unhex(jString($0)) }
                )
                let pf = try ControlPayloadV1.frameFor(arm: .inventoryPage,
                    msgId: Data((0..<16).map { u8($0 + 5) }),
                    routingTag: Data(repeating: 0, count: 4), payload: p.encode())
                let dec = owner.handleControlFrame(pf, from: cpeer)
                if case .accepted = dec { continue }
                verdict = dec
                break
            }
            let expected = jString(cv["expect_failure"])
            let cert = owner.checkSequence(crel)
            var named = "no failure detected"
            switch verdict {
            case .refused(reason: let reason):
                named = reason
            default:
                if let cert = cert { named = cert }
            }
            XCTAssertEqual(named, expected, "corrupted stream \(jString(cv["name"])) must be named \(expected)")
        }
    }

    // ------------------------------------------------------------------
    // W5 -- the stale digest is ignored; the tracked one stands
    // ------------------------------------------------------------------
    func testStaleDigestIsIgnoredTheTrackedOneStands() throws {
        let t = table()
        let store = InMemoryMessageStore()
        let authority = InventorySnapshotAuthority(store: store, monotonicNowMillis: { 1_000 })
        let owner = SyncControlOwner(store: store, authority: authority, monotonicNowMillis: { 1_000 }, localNodeId: peer(9))
        let thePeer = peer(7)
        guard let basic = t.payloads.first(where: { jString($0["name"]) == "digest_basic" }) else {
            XCTFail("the basic digest is missing")
            return
        }
        let good = try ControlDigest(snapshotId: 42, bloom: unhex(jString(jDict(basic["input"])["bloom"])))

        func feed(_ d: ControlDigest) -> SyncControlOwner.OwnerDecision {
            let f = try! ControlPayloadV1.frameFor(arm: .digest,
                msgId: Data((0..<16).map { u8($0 + 3) }),
                routingTag: Data((0..<4).map { u8($0 + 1) }), payload: d.encode())
            return owner.handleControlFrame(f, from: thePeer)
        }

        let rel = owner.relation(for: thePeer)
        guard case .accepted = feed(good) else { XCTFail("the first digest is adopted"); return }
        XCTAssertEqual(rel.trackedSid, 42, "the tracked sid")
        let held = try XCTUnwrap(rel.trackedBloom, "the tracked bloom stands registered")
        XCTAssertEqual(held, good.bloom, "the tracked bloom is the table's own")

        let stale = try ControlDigest(snapshotId: 41, bloom: Data(repeating: 0xEE, count: 512))
        let sres = feed(stale)
        guard case .ignored(reason: let reason) = sres else {
            XCTFail("the stale digest must be ignored, got \(sres)")
            return
        }
        XCTAssertEqual(reason, "stale digest", "stale reason")
        XCTAssertEqual(rel.trackedSid, 42, "the tracked sid stands")
        XCTAssertEqual(rel.trackedBloom, held, "the tracked bloom stands")

        let sameSidOtherBloom = try ControlDigest(snapshotId: 42, bloom: Data(repeating: 0, count: 512))
        guard case .accepted = feed(sameSidOtherBloom) else { XCTFail("reaffirmation is accepted"); return }
        XCTAssertEqual(rel.trackedSid, 42, "the sid does not move")
        XCTAssertEqual(rel.trackedBloom, sameSidOtherBloom.bloom, "the bloom copy is refreshed")

        XCTAssertTrue(owner.startInventoryRun(thePeer), "the run opens for the walk")
        XCTAssertEqual(rel.runSid, 42, "the run rides the tracked sid")
        let newer = try ControlDigest(snapshotId: 43, bloom: held)
        guard case .accepted = feed(newer) else { XCTFail("the newer digest is adopted"); return }
        XCTAssertEqual(rel.trackedSid, 43, "the newer sid is tracked")
        XCTAssertEqual(rel.runSid, 0, "the elder run is discarded")
        XCTAssertEqual(rel.pagesReceived, 0, "and nothing was counted on it")
    }

    // ------------------------------------------------------------------
    // W6 -- the inventory walk wraps around the end
    // ------------------------------------------------------------------
    func testInventoryWalksWrapAroundTheEnd() throws {
        let t = table()
        let store = InMemoryMessageStore()
        var tnow: Int64 = 1_000
        let authority = InventorySnapshotAuthority(store: store, monotonicNowMillis: { tnow })
        for (k, hx) in t.storeIds.enumerated() {
            _ = store.persist(messageFrame(unhex(hx), 8), receivedFrom: peer(UInt8(k & 0x7F)))
        }
        guard let snap = authority.forceSnapshot() else { XCTFail("the capture must not be deferred"); return }
        XCTAssertEqual(snap.ids.count, 100, "the captured vector holds the store's ids")
        for k in 1..<snap.ids.count {
            XCTAssertLessThan(ControlPayloadV1.lexicographicCompare(snap.ids[k - 1], snap.ids[k]), 0,
                             "the vector is lexicographically sorted at \(k)")
        }
        guard let clean = t.walks.first(where: { jString($0["name"]) == "walk_100_by_32" }) else {
            XCTFail("the clean walk is missing")
            return
        }
        let pages = jList(clean["pages"]).map { jDict($0) }
        XCTAssertEqual(pages.count, 4, "the walk needs four pages")
        var cursor: Data? = nil
        var walked = 0
        for (k, p) in pages.enumerated() {
            let page = try snap.pageAfter(cursor: cursor, maxPerPage: 32)
            XCTAssertEqual(Int(page.done), jInt(p["done"]), "page \(k + 1) done")
            XCTAssertEqual(page.ids.count, jInt(p["count"]), "page \(k + 1) count")
            let ids = jList(p["ids"])
            for (m, e) in ids.enumerated() {
                XCTAssertEqual(page.ids[m], unhex(jString(e)), "page \(k + 1) id \(m)")
            }
            if let last = page.ids.last { cursor = last }
            walked += 1
        }
        XCTAssertEqual(walked, 4, "pages walked")
        let after = try snap.pageAfter(cursor: cursor, maxPerPage: 32)
        let ae = jDict(clean["after_end_empty"])
        XCTAssertEqual(Int(after.done), jInt(ae["done"]), "the page past the end is done")
        XCTAssertEqual(after.ids.count, jInt(ae["count"]), "and empty")
        let restart = try snap.pageAfter(cursor: nil, maxPerPage: 32)
        let rz = jDict(clean["restart_from_zero"])
        XCTAssertEqual(restart.ids.count, jInt(rz["count"]), "restart count")
        XCTAssertEqual(Int(restart.done), jInt(rz["done"]), "restart done")
        let rzids = jList(rz["ids"])
        for (m, e) in rzids.enumerated() {
            XCTAssertEqual(restart.ids[m], unhex(jString(e)), "restart id \(m)")
        }

        // the pages are pinned to the captured vector: new holds do not disturb a running walk
        _ = store.persist(messageFrame(evictId(900_001), 8), receivedFrom: peer(1))
        _ = store.persist(messageFrame(evictId(900_002), 8), receivedFrom: peer(2))
        let pinned = try snap.pageAfter(cursor: nil, maxPerPage: 32)
        XCTAssertEqual(pinned.ids[0], restart.ids[0], "the first page is pinned to the capture")
        XCTAssertEqual(snap.ids.count, 100, "the vector keeps its count")
        XCTAssertEqual(store.allHeldMsgIds().count, 102, "while the store grew by two")

        expectRefusal("the page size over the arm bound", "count_out_of_range") { _ = try snap.pageAfter(cursor: cursor, maxPerPage: 33) }
        expectRefusal("the page size under the arm bound", "count_out_of_range") { _ = try snap.pageAfter(cursor: cursor, maxPerPage: 0) }
        expectRefusal("a 15-octet cursor is no cursor", "bad_cursor") { _ = try snap.pageAfter(cursor: Data(repeating: 0, count: 15), maxPerPage: 32) }
        XCTAssertTrue(true, "walker bounds exercised thrice")

        // ordinary new holds do not restart the active immutable snapshot
        tnow += 1_000
        let again = authority.currentSnapshot()
        XCTAssertEqual(again, .some(snap), "the active snapshot stands")
    }

    // ------------------------------------------------------------------
    // W7 -- the full 512-byte bloom travels the ATT leg at MTU 20
    // ------------------------------------------------------------------
    func testFullBloomTravelsTheAtTwentyByteLink() throws {
        let t = table()
        let att = t.att
        let frameHex = jString(att["reassembled_frame_hex"])
        let frags = jList(att["fragments_hex"]).map { unhex(jString($0)) }
        let maxAtt = jInt(att["max_att_value_length"])
        let seq = u8(jInt(att["record_seq"]))
        guard let rtype = BleRecordType(rawValue: u8(jInt(att["record_type"]))) else {
            XCTFail("the table names no record type")
            return
        }
        XCTAssertEqual(maxAtt, 20, "the MTU of the smallest legal leg")
        XCTAssertEqual(rtype, .data, "control DATA rides the DATA record")

        let mine = try BleRecordFragmenter.fragment(recordType: rtype, recordSeq: seq,
                                                   payload: unhex(frameHex), maxAttValueLength: maxAtt)
        XCTAssertEqual(mine.count, frags.count, "the fragment count agrees with the table")
        XCTAssertEqual(mine.count, 47, "the count is 47")
        for k in 0..<mine.count {
            XCTAssertEqual(mine[k], frags[k], "fragment \(k) agrees with the table")
        }
        for (k, f) in mine.enumerated() {
            XCTAssertLessThanOrEqual(f.count, maxAtt, "fragment \(k) fits one ATT value")
        }

        let reas = BleRecordReassembler(timeProvider: { 0 })
        var rec: BleReassembledRecord? = nil
        for (k, f) in mine.enumerated() {
            rec = reas.receiveFragmentBytes(f)
            if k < mine.count - 1 { XCTAssertNil(rec, "no early reassembly at \(k)") }
        }
        guard let rec = rec else { XCTFail("the last fragment completes the record"); return }
        XCTAssertEqual(rec.payload, unhex(frameHex), "the reassembled frame is the frame that was sent")
        XCTAssertEqual(rec.recordType, rtype, "of the DATA type")
        XCTAssertEqual(rec.recordSeq, seq, "with the sequence kept")

        guard let wire = FrameV2.decode(rec.payload) else { XCTFail("the frozen envelope decodes"); return }
        XCTAssertEqual(wire.type, .digest, "DIGEST")
        XCTAssertEqual(wire.flags, 0, "flags stay zero")
        XCTAssertEqual(Int(wire.ttl), 0, "ttl stays zero")
        XCTAssertEqual(Int(wire.hopCount), 0, "hop stays zero")
        guard case .ok(.digest(let dg)) = ControlPayloadV1.decode(arm: .digest, wire.payload) else {
            XCTFail("the digest payload decodes")
            return
        }
        XCTAssertEqual(dg.bloom.count, 512, "the full bloom travels unabridged")
        guard let basic = t.payloads.first(where: { jString($0["name"]) == "digest_basic" }) else {
            XCTFail("the basic digest is missing")
            return
        }
        XCTAssertEqual(dg.bloom, unhex(jString(jDict(basic["struct"])["bloom"])),
                       "octet for octet with the gmp21-struck bloom")
        let bd = BloomDigest()
        for hx in t.storeIds { bd.add(unhex(hx)) }
        XCTAssertEqual(dg.bloom, bd.toBytes(), "the production bloom agrees with the authority")
        var bits = 0
        for b in dg.bloom { bits += b.nonzeroBitCount }
        XCTAssertGreaterThanOrEqual(bits, 250, "the filter is not empty (bits=\(bits))")
        XCTAssertLessThanOrEqual(bits, 650, "the filter is not saturated (bits=\(bits))")
        XCTAssertEqual(Data(dg.bloom.prefix(20)), bd.shortDigest(), "the short digest is the head of the filter")
    }

    // ------------------------------------------------------------------
    // W8 -- a forced bloom collision converges by exact reconciliation
    // ------------------------------------------------------------------
    func testForcedBloomCollisionConvergesByExactReconciliation() throws {
        let t = table()
        let coll = t.collision
        let realIds = jList(coll["store"]).map { jString($0) }
        let foreign = unhex(jString(coll["foreign"]))
        let indices = jList(coll["indices"]).map { jInt($0) }
        XCTAssertEqual(foreign.count, 16, "one foreign id pressed against the filter")
        XCTAssertEqual(indices.count, 4, "four rounds probe it")

        let storeA = InMemoryMessageStore()
        let storeB = InMemoryMessageStore()
        var tA: Int64 = 1_000
        let authA = InventorySnapshotAuthority(store: storeA, monotonicNowMillis: { tA })
        let authB = InventorySnapshotAuthority(store: storeB, monotonicNowMillis: { tA })
        let ownerA = SyncControlOwner(store: storeA, authority: authA, monotonicNowMillis: { tA }, localNodeId: peer(1))
        let ownerB = SyncControlOwner(store: storeB, authority: authB, monotonicNowMillis: { tA }, localNodeId: peer(2))
        let peerA = peer(1)
        let peerB = peer(2)

        let digestA = BloomDigest()
        for hx in realIds {
            _ = storeA.persist(messageFrame(unhex(hx), 16), receivedFrom: peerB)
            digestA.add(unhex(hx))
        }
        XCTAssertEqual(digestA.toBytes(), unhex(jString(coll["digest_hex"])), "the table's own digest and ours are one")
        XCTAssertFalse(storeA.allHeldMsgIds().contains { $0 == foreign }, "the foreign id is truly absent from A")
        XCTAssertTrue(digestA.mightContain(foreign), "the filter swears the foreign id may be there")
        for (k, idx) in indices.enumerated() {
            let byte = digestA.toBytes()[idx / 8]
            let bit = u8(1 << (idx % 8))
            XCTAssertNotEqual(byte & bit, 0, "round \(k) index \(idx) is set in A's filter")
        }

        // B holds the colliding id alone and would offer it; A's filter, a
        // false positive, suppresses the offering -- the digest-only exchange
        // would conceal the frame forever (the same filter as Android's pump).
        _ = storeB.persist(messageFrame(foreign, 24), receivedFrom: peerA)
        let offered = storeB.allHeldOrderedByPriority().filter { !digestA.mightContain($0.msgId) }
        XCTAssertEqual(offered.count, 0, "the digest-only exchange suppresses the colliding id")

        // exact reconciliation: A walks B's captured inventory
        guard let pair = ownerB.buildDigestFrame() else { XCTFail("B can build its digest"); return }
        XCTAssertEqual(pair.payload.bloom.count, 512, "B's bloom is full width")
        let relA = ownerA.relation(for: peerB)
        guard case .accepted = ownerA.handleControlFrame(pair.frame, from: peerB) else {
            XCTFail("A adopts B's digest")
            return
        }
        XCTAssertEqual(relA.trackedSid, pair.payload.snapshotId, "A tracks B's snapshot")
        XCTAssertTrue(ownerA.startInventoryRun(peerB), "A opens the run")
        guard let request = ownerA.pumpNextInventoryFrames(peerB).first(where: { $0.type == .hello }) else {
            XCTFail("the opening request rides")
            return
        }

        // B answers with the page that lists the exact id
        guard case .delivered(frames: let answerPages) = ownerB.handleControlFrame(request, from: peerA) else {
            XCTFail("B delivers a page")
            return
        }
        XCTAssertEqual(answerPages.count, 1, "one page frame")
        guard case .ok(.inventoryPage(let page)) = ControlPayloadV1.decodeFor(type: answerPages[0].type, answerPages[0].payload) else {
            XCTFail("the page is canonical")
            return
        }
        XCTAssertEqual(page.ids.count, 1, "the page lists exactly the id B holds")
        XCTAssertEqual(page.ids[0], foreign, "the exact id, bytewise")

        // A receives the page: absent locally, the id waits in the want queue
        guard case .accepted = ownerA.handleControlFrame(answerPages[0], from: peerB) else {
            XCTFail("A accepts the page")
            return
        }
        XCTAssertEqual(relA.pagesReceived, 1, "one page received")
        XCTAssertTrue(relA.runDone, "the run is closed by the done")
        XCTAssertNil(ownerA.checkSequence(relA), "the stream certifies")
        XCTAssertEqual(relA.wantQueue.count, 1, "the want queue holds the one missing id")
        XCTAssertEqual(relA.wantQueue[0], foreign, "waiting for the exact id")

        // A pumps the want (the drain runs even when the page walk is closed); B answers from the store
        let wantFrames = ownerA.pumpNextInventoryFrames(peerB).filter { $0.type == .want }
        XCTAssertEqual(wantFrames.count, 1, "one want frame")
        guard case .ok(.want(let want)) = ControlPayloadV1.decode(arm: .want, wantFrames[0].payload) else {
            XCTFail("the want is canonical")
            return
        }
        XCTAssertEqual(want.ids.count, 1, "asking for one id")
        guard case .delivered(frames: let answers) = ownerB.handleControlFrame(wantFrames[0], from: peerA) else {
            XCTFail("B answers")
            return
        }
        XCTAssertEqual(answers.count, 1, "the held frame is delivered")
        XCTAssertEqual(answers[0].msgId, foreign, "with the very msg_id that collides")
        XCTAssertEqual(answers[0].payload.count, 24, "bytes as stored, verbatim")

        // A converges: the once-suppressed id is now durably A's own
        let before = storeA.allHeldMsgIds().count
        _ = storeA.persist(answers[0], receivedFrom: peerB)
        let after = storeA.allHeldMsgIds().count
        XCTAssertEqual(after - before, 1, "A gained exactly one frame")
        XCTAssertTrue(storeA.allHeldMsgIds().contains { $0 == foreign }, "the converged id is held by A now")
        guard let snapA = authA.forceSnapshot() else { XCTFail("A can capture its grown store"); return }
        XCTAssertTrue(snapA.contains(foreign), "the captured vector includes the convergee")
        XCTAssertEqual(snapA.ids.count, 121, "and all that B ever listed")
    }

    // ------------------------------------------------------------------
    // W9 -- eviction is forgotten by the fresh capture
    // ------------------------------------------------------------------
    func testEvictionIsForgottenByTheFreshCapture() throws {
        let total = 200
        let payloadSize = 256                            // bytesOf = payload + 64; three fit under 1000
        let store = InMemoryMessageStore(maxBytes: 1_000)
        var ever = [Data]()
        var tnow: Int64 = 1_000
        let authority = InventorySnapshotAuthority(store: store, monotonicNowMillis: { tnow })
        for k in 0..<total {
            let id = evictId(k)
            _ = store.persist(messageFrame(id, payloadSize), receivedFrom: peer(UInt8(k & 0x7F)))
            ever.append(id)                              // what the node has ever seen, held or not
        }
        let survivors = store.allHeldMsgIds()
        XCTAssertGreaterThan(survivors.count, 0, "the cap kept something")
        XCTAssertLessThan(survivors.count, 7, "the hard cap evicted: survivors=\(survivors.count)")
        let kept = Set(survivors.map { ControlPayloadV1.hexOf($0) })
        let evicted = ever.filter { !kept.contains(ControlPayloadV1.hexOf($0)) }
        XCTAssertGreaterThanOrEqual(evicted.count, total - 6, "the head of the campaign was evicted (\(evicted.count) of them)")

        guard let snap = authority.forceSnapshot() else { XCTFail("the fresh capture succeeds"); return }
        XCTAssertEqual(snap.ids.count, survivors.count, "the vector holds what the store holds")
        for s in survivors { XCTAssertTrue(snap.contains(s), "a survivor is present") }
        for e in evicted { XCTAssertFalse(snap.contains(e), "the evicted are forgotten by the capture") }

        let fresh = BloomDigest()
        for id in snap.ids { fresh.add(id) }
        var forgotten = 0
        for e in evicted { if !fresh.mightContain(e) { forgotten += 1 } }
        XCTAssertEqual(forgotten, evicted.count, "every evicted id is forgotten by the fresh digest")
        for s in survivors { XCTAssertTrue(fresh.mightContain(s), "every held id is remembered") }

        // the semantic negative: a digest built from the SEEN list -- every id
        // that ever passed through, held or not -- would remember what the
        // store forgot; had the implementation taken that source, the
        // assertions above could not all hold
        let seen = BloomDigest()
        for id in ever { seen.add(id) }
        for e in evicted { XCTAssertTrue(seen.mightContain(e), "the seen-based construction would remember the evicted") }
        XCTAssertFalse(fresh.toBytes() == seen.toBytes(), "the two sources tell different truths")

        let pinned = authority.currentSnapshot()
        XCTAssertEqual(pinned, .some(snap), "the active snapshot stays pinned until expiry or rebuild")
        XCTAssertEqual(pinned?.ids.count, survivors.count, "and still tells of the survivors only")
        XCTAssertEqual(ever.count, total, "seen-all counted")
        XCTAssertEqual(kept.count, survivors.count, "survivors counted")
    }

    // ------------------------------------------------------------------
    // W10 -- the snapshot authority's discipline
    // ------------------------------------------------------------------
    func testSnapshotAuthorityKeepsTheLaw() throws {
        let store = InMemoryMessageStore()
        _ = store.persist(messageFrame(evictId(1), 8), receivedFrom: peer(1))
        _ = store.persist(messageFrame(evictId(2), 8), receivedFrom: peer(2))
        var tnow: Int64 = 1_000
        let authority = InventorySnapshotAuthority(store: store, monotonicNowMillis: { tnow })

        var previous: UInt64 = 0
        for k in 1...5 {
            guard let sid = authority.nextSnapshotId() else { XCTFail("allocation \(k)"); return }
            XCTAssertNotEqual(sid, 0, "the id is nonzero")
            XCTAssertGreaterThan(sid, previous, "the ids are strictly monotonic over \(previous)")
            previous = sid
        }

        let doomed = InventorySnapshotAuthority(store: store, monotonicNowMillis: { tnow }, firstId: UInt64.max - 1)
        let last = doomed.nextSnapshotId()
        XCTAssertEqual(last, UInt64.max, "the last lawful id")
        XCTAssertNil(doomed.nextSnapshotId(), "one past the end refuses")
        XCTAssertTrue(doomed.isRetired(), "the context is retired")
        XCTAssertNil(doomed.forceSnapshot(), "retired: no capture")
        XCTAssertEqual(doomed.refusedByExhaustion(), 1, "and it says why")

        let t0 = InventorySnapshotAuthority(store: store, monotonicNowMillis: { tnow })
        XCTAssertNotNil(t0.forceSnapshot(), "the first force captures")
        tnow += 1
        XCTAssertNil(t0.forceSnapshot(), "within the build gap the force is spent")
        XCTAssertEqual(t0.deferredByRate(), 1, "the deferral was counted")
        tnow += 300_000
        XCTAssertNotNil(t0.forceSnapshot(), "after the gap a fresh capture succeeds")

        // the leases: at most two outstanding; an expired snapshot is never served
        let leased = InventorySnapshotAuthority(store: store, monotonicNowMillis: { tnow })
        guard let l1 = leased.forceSnapshot() else { XCTFail("first capture"); return }
        XCTAssertTrue(leased.acquire(l1.snapshotId), "lease the current")
        tnow += 30_001
        guard let l2 = leased.forceSnapshot() else { XCTFail("the successor builds while one lease stands open"); return }
        XCTAssertTrue(leased.acquire(l2.snapshotId), "the successor is referenced and leased")
        XCTAssertGreaterThan(l2.snapshotId, l1.snapshotId, "the successor rides above the elder")
        tnow += 300_001                                                 // the current expired; both leased: no build
        XCTAssertNil(leased.currentSnapshot(), "the expired one is never served, the rebuild defers")
        XCTAssertEqual(leased.deferredByLeases(), 1, "deferred by leases")
        XCTAssertTrue(leased.release(l1.snapshotId), "release the elder")
        XCTAssertTrue(leased.release(l2.snapshotId), "release the current")
        XCTAssertEqual(leased.leasedOf(l2.snapshotId), 0, "no leases remain")
        tnow += 30_001
        guard let l3 = leased.currentSnapshot() else { XCTFail("once leases free, the rebuild proceeds"); return }
        XCTAssertGreaterThan(l3.snapshotId, l2.snapshotId, "with a fresh monotonic id")

        // the read budget: a walk that outlasts its two seconds aborts safely
        let trap = BudgetTrapStore(delegate: store, advancePerVisit: 1_001) { dt in tnow += dt }
        let budgeted = InventorySnapshotAuthority(store: trap, monotonicNowMillis: { tnow })
        tnow += 40_000
        XCTAssertNil(budgeted.forceSnapshot(), "the capture aborts when the walk overruns")
        XCTAssertEqual(budgeted.abortedByBudget(), 1, "the abort was counted")
        XCTAssertNil(budgeted.currentSnapshotOrNull(), "and nothing was installed")

        expectRefusal("rows over the bound", "count_out_of_range") {
            _ = try StableInventorySnapshot(snapshotId: 5, ids: (0...100_000).map { evictId($0) }, capturedAtMono: 0)
        }
        expectRefusal("an id of the wrong width", "wrong_size") {
            _ = try StableInventorySnapshot(snapshotId: 5, ids: [Data(repeating: 0, count: 15)], capturedAtMono: 0)
        }
        expectRefusal("a vector is of distinct ids", "duplicate_ids") {
            _ = try StableInventorySnapshot(snapshotId: 5, ids: [evictId(1), evictId(1)], capturedAtMono: 0)
        }
        expectRefusal("the id is nonzero", "zero_snapshot_id") {
            _ = try StableInventorySnapshot(snapshotId: 0, ids: [evictId(1)], capturedAtMono: 0)
        }
        XCTAssertTrue(true, "the gate refused four")

        // an ordinary new hold does not restart the active snapshot; the
        // consumer's pages stay pinned to the vector it walked
        let steady = InventorySnapshotAuthority(store: store, monotonicNowMillis: { tnow })
        tnow += 40_000
        guard let before = steady.forceSnapshot() else { XCTFail("steady capture"); return }
        _ = store.persist(messageFrame(evictId(4242), 8), receivedFrom: peer(3))
        tnow += 5
        let after = steady.currentSnapshot()
        XCTAssertEqual(after, .some(before), "the active snapshot stands unrestarted")
        let page = try XCTUnwrap(after?.pageAfter(cursor: nil, maxPerPage: 32), "the steady page rides")
        XCTAssertEqual(page.ids.count, 2, "the pinned page tells only what its capture saw")
        XCTAssertFalse(page.ids.contains { $0 == evictId(4242) }, "the later hold is no part of the pinned vector")
        XCTAssertEqual(steady.leasedOf(after!.snapshotId), 0, "leases open at zero")
    }

    // ------------------------------------------------------------------
    // W11 -- control frames never enter held message storage
    // ------------------------------------------------------------------
    func testControlCampaignNeverTouchesTheDurableStore() throws {
        let t = table()
        let counting = CountingStore(delegate: InMemoryMessageStore())
        let thePeer = peer(7)
        let rigStore = InMemoryMessageStore()
        let tracker = DeliveryTracker(repo: InMemoryStoreDeliveryRepository(store: rigStore), authenticator: NoAuth())
        let node = MeshNode(identity: try makeIdentity(0xA4, 0xB7), store: counting, deliveryTracker: tracker)
        var byName = [String: [String: Json]]()
        for p in t.payloads { byName[jString(p["name"])] = p }

        let CONTROL_ID = unhex("0A0B0C0D0E0F1011121314151617 1819")
        func controlFrame(_ arm: ControlArm, _ payload: Data) -> FrameV2 {
            try! ControlPayloadV1.frameFor(arm: arm, msgId: CONTROL_ID,
                                          routingTag: Data(repeating: 0, count: 4), payload: payload)
        }
        func payloadOf(_ name: String) -> Data {
            guard let v = byName[name] else { XCTFail("the table lacks \(name)"); return Data() }
            return unhex(jString(v["payload_hex"]))
        }
        func refusedFrame(_ type: TypeV2) -> FrameV2 {
            FrameV2(type: type,
                    msgId: unhex("0F0E0D0C0B0A090807060504030201 00"),
                    routingTag: Data(repeating: 0, count: 4), ttl: 4, hopCount: 0,
                    flags: u16(3 << 8), payload: Data(repeating: 0, count: 8))
        }

        // (label, frame, must the ingress accept it?) -- the page is unsolicited
        // (no run was ever opened through the node) and the bulk pair and
        // GOODBYE are refused in this profile
        let campaign: [(label: String, frame: FrameV2, accept: Bool)] = [
            ("ping", controlFrame(.ping, payloadOf("ping_request")), true),
            ("digest", controlFrame(.digest, payloadOf("digest_basic")), true),
            ("want", controlFrame(.want, payloadOf("want_mid")), true),
            ("request", controlFrame(.inventoryRequest, payloadOf("request_start")), true),
            ("page", controlFrame(.inventoryPage, payloadOf("page_mid")), false),
            ("reset", controlFrame(.reset, payloadOf("reset_min")), true),
            ("bulk offer", refusedFrame(.bulk_offer), false),
            ("bulk chunk", refusedFrame(.bulk_chunk), false),
            ("goodbye", refusedFrame(.goodbye), false),
        ]

        var accepted = 0, refused = 0
        var decisions = [String: SyncControlOwner.OwnerDecision]()
        for (k, leg) in campaign.enumerated() {
            let verdict = node.ingestInbound(leg.frame, receivedFrom: thePeer)
            XCTAssertEqual(verdict, leg.accept, "control campaign leg \(k) (\(leg.label))")
            decisions[leg.label] = node.lastControlDecision
            if leg.accept { accepted += 1 } else { refused += 1 }
        }
        guard let pageDecision = decisions["page"] else { XCTFail("the page leg left no decision"); return }
        XCTAssertEqual(decisionReason(pageDecision), "unsolicited page", "the unsolicited page was ignored, not held")
        XCTAssertEqual(counting.persistCount, 0, "nothing entered held storage from the campaign")
        XCTAssertEqual(counting.seenAll.count, 0, "and the seen list stands empty")
        XCTAssertEqual(accepted, 5, "controls accepted")
        XCTAssertEqual(refused, 4, "profiles refused")

        // the answers the owner produced rode back out: the ping reply echoes
        // the very nonce; the stale request drew the reset naming the fresh
        // sid plus the current digest
        let out = node.drainControlOutbox()
        let replies = out.filter { $0.type == .ping }
        XCTAssertEqual(replies.count, 1, "the ping was answered once")
        guard case .ok(.ping(let pingBack)) = ControlPayloadV1.decode(arm: .ping, replies[0].payload) else {
            XCTFail("the reply is canonical")
            return
        }
        XCTAssertEqual(Int(pingBack.reply), 1, "replying, not requesting")
        let requestStruct = jDict(byName["ping_request"]?["struct"])
        XCTAssertEqual(pingBack.nonce, jU64(requestStruct["nonce"]), "echoing the very nonce")
        XCTAssertTrue(out.contains { $0.type == .hello }, "the stale request drew the reset pair")
        XCTAssertTrue(out.contains { $0.type == .digest }, "and the current digest")
        XCTAssertEqual(out.count, 3, "three frames rode the outbox")

        // the sealed road remains open: MESSAGE and SOS pass as ever they did
        let msg = messageFrame(evictId(777), 32)
        XCTAssertTrue(node.ingestInbound(msg, receivedFrom: thePeer), "a MESSAGE is still accepted")
        XCTAssertEqual(counting.persistCount, 1, "and reached the durable store")
        XCTAssertEqual(counting.seenAll[0], msg.msgId, "the very id the node saw")
        let sos = FrameV2(type: .sos,
                          msgId: evictId(778),
                          routingTag: Data(repeating: 0, count: 4),
                          ttl: 4, hopCount: 0,
                          flags: FrameV2.Flags.sealed | FrameV2.Flags.ack_req | FrameV2.Flags.relay_ok,
                          payload: Data(repeating: 0, count: 16))
        XCTAssertTrue(node.ingestInbound(sos, receivedFrom: thePeer), "an SOS is still accepted")
        XCTAssertEqual(counting.persistCount, 2, "both arrived")

        // the purity of the seen window: a control frame's msg_id, reused by a
        // MESSAGE, is held for the first time -- the window never saw the
        // control that carried it
        let asMessage = messageFrame(CONTROL_ID, 20)
        XCTAssertTrue(node.ingestInbound(asMessage, receivedFrom: thePeer), "the re-used id is novel to the store")
        XCTAssertEqual(counting.persistCount, 3, "persisted, not suppressed by any control")
        XCTAssertTrue(counting.delegate.allHeldMsgIds().contains { $0 == CONTROL_ID }, "the store holds it")
    }
}

private extension UInt8 {
    init(ascii: Character) { self = ascii.asciiValue ?? 0x3F }  // ? sentinel: a non-ASCII slip speaks through the vector comparisons
}
