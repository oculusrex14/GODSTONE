import Foundation

// T40 (ADR-009, blueprint section 14) -- the versioned control payloads that
// ride the EXISTING HELLO/DIGEST/WANT/PING codes, the twin of the Android
// router/ControlPayloadV1.kt. The bytewise law, the check order, the failure
// names and the widths come from the one table
// (crypto/anti_entropy_vectors.json), struck by the independent reference
// (wire/anti_entropy_reference.py) from the one bloom authority
// (crypto/gmp21.py). The isles must agree with the table, not with each
// other. Construction is fail-closed everywhere: no route may build an
// unvalid arm, by the builder or by the decoder alike.

/// The named failures, one shared alphabet (section 14). The raw value is
/// the table's name; both isles spell every refusal identically.
public enum ControlDecodeFailure: String, Sendable, CaseIterable {
    case truncated = "truncated"
    case wrongSize = "wrong_size"
    case unsupportedVersion = "unsupported_version"
    case countOutOfRange = "count_out_of_range"
    case duplicateIds = "duplicate_ids"
    case badCursor = "bad_cursor"
    case badDone = "bad_done"
    case badReply = "bad_reply"
    case zeroSnapshotId = "zero_snapshot_id"
    case unknownSubtype = "unknown_subtype"
    case sequenceBreak = "sequence_break"
}

/// The failure raised by any fail-closed construction; carries its name.
public struct ControlException: Error, Sendable {
    public let failure: ControlDecodeFailure
    public init(_ failure: ControlDecodeFailure) { self.failure = failure }
    public var description: String { "control refusal: \(failure.rawValue)" }
}

/// The six arms: wireName is the table's name; outerCode the frozen TypeV2
/// the frame carries; subtype the HELLO arm's selector (nil for the plain
/// codes). The bulk pair, GOODBYE and the unknown have no arm here: they are
/// refused in this profile.
public enum ControlArm: Sendable, Equatable, CaseIterable {
    case digest
    case want
    case inventoryRequest
    case inventoryPage
    case reset
    case ping

    public var wireName: String {
        switch self {
        case .digest: return "digest"
        case .want: return "want"
        case .inventoryRequest: return "inventory_request"
        case .inventoryPage: return "inventory_page"
        case .reset: return "reset"
        case .ping: return "ping"
        }
    }

    public var outerCode: TypeV2 {
        switch self {
        case .digest: return .digest
        case .want: return .want
        case .inventoryRequest, .inventoryPage, .reset: return .hello
        case .ping: return .ping
        }
    }

    public var subtype: UInt8? {
        switch self {
        case .inventoryRequest: return ControlPayloadV1.subtypeInventoryRequest
        case .inventoryPage: return ControlPayloadV1.subtypeInventoryPage
        case .reset: return ControlPayloadV1.subtypeReset
        default: return nil
        }
    }

    public static func fromWireName(_ name: String) -> ControlArm? {
        for arm in allCases where arm.wireName == name { return arm }
        return nil
    }
}

// MARK: - the six payloads (fail-closed to the core)

public struct ControlDigest: Sendable, Equatable {
    public let snapshotId: UInt64
    public let bloom: Data

    public init(snapshotId: UInt64, bloom: Data) throws {
        if snapshotId == 0 { throw ControlException(.zeroSnapshotId) }
        if bloom.count != ControlPayloadV1.bloomBytes { throw ControlException(.wrongSize) }
        self.snapshotId = snapshotId
        self.bloom = bloom
    }

    public func encode() -> Data {
        var out = Data(capacity: 1 + 8 + ControlPayloadV1.bloomBytes)
        out.append(UInt8(ControlPayloadV1.version))
        ControlPayloadV1.putU64Be(&out, snapshotId)
        out.append(bloom)
        return out
    }
}

public struct ControlWant: Sendable, Equatable {
    public let snapshotId: UInt64
    public let ids: [Data]

    public init(snapshotId: UInt64, ids: [Data]) throws {
        if snapshotId == 0 { throw ControlException(.zeroSnapshotId) }
        if ids.count < 1 || ids.count > ControlPayloadV1.maxIdsPerArm {
            throw ControlException(.countOutOfRange)
        }
        if !ControlPayloadV1.idsDistinct(ids) { throw ControlException(.duplicateIds) }
        for id in ids where id.count != ControlPayloadV1.idBytes { throw ControlException(.wrongSize) }
        self.snapshotId = snapshotId
        self.ids = ids.map { $0 }
    }

    public func encode() -> Data {
        var out = Data(capacity: 1 + 8 + 1 + 16 * ids.count)
        out.append(UInt8(ControlPayloadV1.version))
        ControlPayloadV1.putU64Be(&out, snapshotId)
        out.append(UInt8(ids.count))
        for id in ids { out.append(id) }
        return out
    }
}

public struct ControlInventoryRequest: Sendable, Equatable {
    public let snapshotId: UInt64
    public let cursorPresent: UInt8
    public let cursor: Data

    public init(snapshotId: UInt64, cursorPresent: UInt8, cursor: Data) throws {
        if snapshotId == 0 { throw ControlException(.zeroSnapshotId) }
        if cursorPresent != 0 && cursorPresent != 1 { throw ControlException(.badCursor) }
        if cursor.count != ControlPayloadV1.idBytes { throw ControlException(.badCursor) }
        if cursorPresent == 0 && !ControlPayloadV1.isZeroCursor(cursor) { throw ControlException(.badCursor) }
        self.snapshotId = snapshotId
        self.cursorPresent = cursorPresent
        self.cursor = cursor
    }

    public func encode() -> Data {
        var out = Data(capacity: 1 + 1 + 8 + 1 + ControlPayloadV1.idBytes)
        out.append(UInt8(ControlPayloadV1.version))
        out.append(ControlPayloadV1.subtypeInventoryRequest)
        ControlPayloadV1.putU64Be(&out, snapshotId)
        out.append(cursorPresent)
        out.append(cursor)
        return out
    }
}

public struct ControlInventoryPage: Sendable, Equatable {
    public let snapshotId: UInt64
    public let done: UInt8
    public let ids: [Data]

    public init(snapshotId: UInt64, done: UInt8, ids: [Data]) throws {
        if snapshotId == 0 { throw ControlException(.zeroSnapshotId) }
        if done != 0 && done != 1 { throw ControlException(.badDone) }
        if ids.count > ControlPayloadV1.maxIdsPerArm { throw ControlException(.countOutOfRange) }
        if done == 0 && ids.isEmpty { throw ControlException(.badDone) }    // an empty page closes only a walk
        if !ControlPayloadV1.idsDistinct(ids) { throw ControlException(.duplicateIds) }
        for id in ids where id.count != ControlPayloadV1.idBytes { throw ControlException(.wrongSize) }
        self.snapshotId = snapshotId
        self.done = done
        self.ids = ids.map { $0 }
    }

    public func encode() -> Data {
        var out = Data(capacity: 1 + 1 + 8 + 1 + 1 + 16 * ids.count)
        out.append(UInt8(ControlPayloadV1.version))
        out.append(ControlPayloadV1.subtypeInventoryPage)
        ControlPayloadV1.putU64Be(&out, snapshotId)
        out.append(done)
        out.append(UInt8(ids.count))
        for id in ids { out.append(id) }
        return out
    }
}

public struct ControlReset: Sendable, Equatable {
    public let newSnapshotId: UInt64

    public init(newSnapshotId: UInt64) throws {
        if newSnapshotId == 0 { throw ControlException(.zeroSnapshotId) }
        self.newSnapshotId = newSnapshotId
    }

    public func encode() -> Data {
        var out = Data(capacity: 1 + 1 + 8)
        out.append(UInt8(ControlPayloadV1.version))
        out.append(ControlPayloadV1.subtypeReset)
        ControlPayloadV1.putU64Be(&out, newSnapshotId)
        return out
    }
}

public struct ControlPing: Sendable, Equatable {
    public let reply: UInt8
    public let nonce: UInt64

    public init(reply: UInt8, nonce: UInt64) throws {
        if reply != 0 && reply != 1 { throw ControlException(.badReply) }
        self.reply = reply
        self.nonce = nonce
    }

    public func encode() -> Data {
        var out = Data(capacity: 1 + 1 + 8)
        out.append(UInt8(ControlPayloadV1.version))
        out.append(reply)
        ControlPayloadV1.putU64Be(&out, nonce)
        return out
    }
}

/// The decoded arm, whichever it be.
public enum ControlPayload: Sendable, Equatable {
    case digest(ControlDigest)
    case want(ControlWant)
    case inventoryRequest(ControlInventoryRequest)
    case inventoryPage(ControlInventoryPage)
    case reset(ControlReset)
    case ping(ControlPing)

    public func encode() -> Data {
        switch self {
        case .digest(let p): return p.encode()
        case .want(let p): return p.encode()
        case .inventoryRequest(let p): return p.encode()
        case .inventoryPage(let p): return p.encode()
        case .reset(let p): return p.encode()
        case .ping(let p): return p.encode()
        }
    }
}

public enum ControlDecodeResult: Sendable, Equatable {
    case ok(ControlPayload)
    case err(failure: ControlDecodeFailure, hint: String?)
}

// MARK: - the namespace: constants, validators, the decoder, the writers

public enum ControlPayloadV1 {

    public static let version: Int = 1
    public static let bloomBytes: Int = 512
    public static let idBytes: Int = 16
    public static let maxIdsPerArm: Int = 32
    public static let subtypeInventoryRequest: UInt8 = 1
    public static let subtypeInventoryPage: UInt8 = 2
    public static let subtypeReset: UInt8 = 3

    public static let failureNames: [String] = [
        "truncated", "wrong_size", "unsupported_version", "count_out_of_range",
        "duplicate_ids", "bad_cursor", "bad_done", "bad_reply", "zero_snapshot_id",
        "unknown_subtype", "sequence_break",
    ]

    // -- validators, the shared measures --

    public static func lexicographicCompare(_ a: Data, _ b: Data) -> Int {
        let n = min(a.count, b.count)
        let ab = [UInt8](a), bb = [UInt8](b)
        for i in 0..<n {
            if ab[i] != bb[i] { return ab[i] < bb[i] ? -1 : 1 }
        }
        if a.count == b.count { return 0 }
        return a.count < b.count ? -1 : 1
    }

    public static func idsDistinct(_ ids: [Data]) -> Bool {
        var seen = Set<String>()
        for id in ids where !seen.insert(hexOf(id)).inserted { return false }
        return true
    }

    public static func isZeroCursor(_ cursor: Data) -> Bool {
        for byte in cursor where byte != 0 { return false }
        return true
    }

    public static func u64Be(_ data: Data) -> UInt64? {
        guard data.count == 8 else { return nil }
        var v: UInt64 = 0
        for b in data { v = (v << 8) | UInt64(b) }
        return v
    }

    public static func putU64Be(_ out: inout Data, _ value: UInt64) {
        out.append(UInt8((value >> 56) & 0xFF))
        out.append(UInt8((value >> 48) & 0xFF))
        out.append(UInt8((value >> 40) & 0xFF))
        out.append(UInt8((value >> 32) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static let hexDigits = Array("0123456789ABCDEF")

    public static func hexOf(_ bytes: Data) -> String {
        var s = ""
        s.reserveCapacity(bytes.count * 2)
        for b in bytes {
            s.append(hexDigits[Int(b >> 4)])
            s.append(hexDigits[Int(b & 0x0F)])
        }
        return s
    }

    // -- the fail-closed builders (the same constructors the decoder calls) --

    public static func digest(snapshotId: UInt64, bloom: Data) throws -> ControlDigest {
        try ControlDigest(snapshotId: snapshotId, bloom: bloom)
    }

    public static func want(snapshotId: UInt64, ids: [Data]) throws -> ControlWant {
        try ControlWant(snapshotId: snapshotId, ids: ids)
    }

    public static func inventoryRequest(snapshotId: UInt64, cursorPresent: UInt8, cursor: Data) throws -> ControlInventoryRequest {
        try ControlInventoryRequest(snapshotId: snapshotId, cursorPresent: cursorPresent, cursor: cursor)
    }

    public static func inventoryPage(snapshotId: UInt64, done: UInt8, ids: [Data]) throws -> ControlInventoryPage {
        try ControlInventoryPage(snapshotId: snapshotId, done: done, ids: ids)
    }

    public static func reset(newSnapshotId: UInt64) throws -> ControlReset {
        try ControlReset(newSnapshotId: newSnapshotId)
    }

    public static func ping(reply: UInt8, nonce: UInt64) throws -> ControlPing {
        try ControlPing(reply: reply, nonce: nonce)
    }

    /// Split the wanted ids into want payloads as the writer capacity requires.
    public static func wantSplit(snapshotId: UInt64, ids: [Data], maxPerWant: Int) throws -> [ControlWant] {
        if maxPerWant < 1 || maxPerWant > maxIdsPerArm { throw ControlException(.countOutOfRange) }
        if ids.isEmpty || ids.count > maxIdsPerArm { throw ControlException(.countOutOfRange) }
        var out: [ControlWant] = []
        var start = 0
        while start < ids.count {
            let end = min(start + maxPerWant, ids.count)
            out.append(try ControlWant(snapshotId: snapshotId, ids: Array(ids[start..<end])))
            start = end
        }
        return out
    }

    // -- the decoder: strict, fail-closed; mirrors the reference branch for branch,
    //    the Kotlin gate for gate (the check order is the law; both isles must
    //    name the same refusal for the same bytes) --

    public static func decode(arm: ControlArm, _ buf: Data) -> ControlDecodeResult {
        let n = buf.count
        let at = buf.startIndex
        func byte(_ i: Int) -> UInt8 { buf[at + i] }
        func tail(_ i: Int) -> Data { buf.subdata(in: at + i..<at + i + 8) }
        func slice(_ f: Int, _ t: Int) -> Data { buf.subdata(in: at + f..<at + t) }
        switch arm {
        case .digest:
            let need = 1 + 8 + bloomBytes
            if n < need { return .err(failure: .truncated, hint: "digest") }
            if n > need { return .err(failure: .wrongSize, hint: "digest") }
            if byte(0) != UInt8(version) { return .err(failure: .unsupportedVersion, hint: "digest") }
            let sid = u64Be(tail(1)) ?? 0
            if sid == 0 { return .err(failure: .zeroSnapshotId, hint: "digest") }
            guard let p = try? ControlDigest(snapshotId: sid, bloom: slice(9, 9 + bloomBytes)) else {
                return .err(failure: .wrongSize, hint: "digest")
            }
            return .ok(.digest(p))
        case .want:
            if n < 10 { return .err(failure: .truncated, hint: "want") }
            if byte(0) != UInt8(version) { return .err(failure: .unsupportedVersion, hint: "want") }
            let sid = u64Be(tail(1)) ?? 0
            if sid == 0 { return .err(failure: .zeroSnapshotId, hint: "want") }
            let count = Int(byte(9))
            if count < 1 || count > maxIdsPerArm { return .err(failure: .countOutOfRange, hint: "want") }
            let need = 10 + 16 * count
            if n < need { return .err(failure: .truncated, hint: "want") }
            if n > need { return .err(failure: .wrongSize, hint: "want") }
            var ids: [Data] = []
            ids.reserveCapacity(count)
            for k in 0..<count { ids.append(slice(10 + 16 * k, 10 + 16 * (k + 1))) }
            if !idsDistinct(ids) { return .err(failure: .duplicateIds, hint: "want") }
            guard let p = try? ControlWant(snapshotId: sid, ids: ids) else {
                return .err(failure: .wrongSize, hint: "want")
            }
            return .ok(.want(p))
        case .inventoryRequest, .inventoryPage, .reset:
            if n < 2 { return .err(failure: .truncated, hint: "hello") }
            if byte(0) != UInt8(version) { return .err(failure: .unsupportedVersion, hint: "hello") }
            let subtype = byte(1)
            switch subtype {
            case ControlPayloadV1.subtypeInventoryRequest:
                if arm != .inventoryRequest { return .err(failure: .unknownSubtype, hint: "hello") }
                let need = 2 + 8 + 1 + 16
                if n < need { return .err(failure: .truncated, hint: "inventory_request") }
                if n > need { return .err(failure: .wrongSize, hint: "inventory_request") }
                let sid = u64Be(tail(2)) ?? 0
                if sid == 0 { return .err(failure: .zeroSnapshotId, hint: "inventory_request") }
                let cp = byte(10)
                if cp != 0 && cp != 1 { return .err(failure: .badCursor, hint: "inventory_request") }
                let cursor = slice(11, 27)
                if cp == 0 && !isZeroCursor(cursor) { return .err(failure: .badCursor, hint: "inventory_request") }
                guard let p = try? ControlInventoryRequest(snapshotId: sid, cursorPresent: cp, cursor: cursor) else {
                    return .err(failure: .badCursor, hint: "inventory_request")
                }
                return .ok(.inventoryRequest(p))
            case ControlPayloadV1.subtypeInventoryPage:
                if arm != .inventoryPage { return .err(failure: .unknownSubtype, hint: "hello") }
                if n < 4 { return .err(failure: .truncated, hint: "inventory_page") }
                let sid = u64Be(tail(2)) ?? 0
                if sid == 0 { return .err(failure: .zeroSnapshotId, hint: "inventory_page") }
                let done = byte(10)
                let count = Int(byte(11))
                if done != 0 && done != 1 { return .err(failure: .badDone, hint: "inventory_page") }
                if count > maxIdsPerArm { return .err(failure: .countOutOfRange, hint: "inventory_page") }
                if done == 0 && count == 0 { return .err(failure: .badDone, hint: "inventory_page") }
                let need = 12 + 16 * count
                if n < need { return .err(failure: .truncated, hint: "inventory_page") }
                if n > need { return .err(failure: .wrongSize, hint: "inventory_page") }
                var ids: [Data] = []
                ids.reserveCapacity(count)
                for k in 0..<count { ids.append(slice(12 + 16 * k, 12 + 16 * (k + 1))) }
                if !idsDistinct(ids) { return .err(failure: .duplicateIds, hint: "inventory_page") }
                guard let p = try? ControlInventoryPage(snapshotId: sid, done: done, ids: ids) else {
                    return .err(failure: .badDone, hint: "inventory_page")
                }
                return .ok(.inventoryPage(p))
            case ControlPayloadV1.subtypeReset:
                if arm != .reset { return .err(failure: .unknownSubtype, hint: "hello") }
                let need = 2 + 8
                if n < need { return .err(failure: .truncated, hint: "reset") }
                if n > need { return .err(failure: .wrongSize, hint: "reset") }
                let sid = u64Be(tail(2)) ?? 0
                if sid == 0 { return .err(failure: .zeroSnapshotId, hint: "reset") }
                guard let p = try? ControlReset(newSnapshotId: sid) else {
                    return .err(failure: .zeroSnapshotId, hint: "reset")
                }
                return .ok(.reset(p))
            default:
                return .err(failure: .unknownSubtype, hint: "hello")
            }
        case .ping:
            let need = 2 + 8
            if n < need { return .err(failure: .truncated, hint: "ping") }
            if n > need { return .err(failure: .wrongSize, hint: "ping") }
            if byte(0) != UInt8(version) { return .err(failure: .unsupportedVersion, hint: "ping") }
            let reply = byte(1)
            if reply != 0 && reply != 1 { return .err(failure: .badReply, hint: "ping") }
            guard let p = try? ControlPing(reply: reply, nonce: u64Be(tail(2)) ?? 0) else {
                return .err(failure: .badReply, hint: "ping")
            }
            return .ok(.ping(p))
        }
    }

    /// Decode by the frame's outer code alone (the demultiplex path).
    public static func decodeFor(type: TypeV2, _ buf: Data) -> ControlDecodeResult {
        let arm: ControlArm
        switch type {
        case .digest: arm = .digest
        case .want: arm = .want
        case .ping: arm = .ping
        case .hello:
            // HELLO carries three subtypes plus the bare hello; the second
            // octet discriminates. A non-control hello is not this profile's
            // creature: reject by name, mutate nothing.
            if buf.isEmpty || buf[buf.startIndex] != UInt8(version) {
                return .err(failure: .unsupportedVersion, hint: "hello")
            }
            switch buf[buf.startIndex + 1] {
            case subtypeInventoryRequest: arm = .inventoryRequest
            case subtypeInventoryPage: arm = .inventoryPage
            case subtypeReset: arm = .reset
            default: return .err(failure: .unknownSubtype, hint: "hello")
            }
        default:
            return .err(failure: .unknownSubtype, hint: "type \(type.rawValue)")
        }
        return decode(arm: arm, buf)
    }

    /// Seal an arm into its frame: the frozen envelope with the control-only
    /// zero values (ttl 0, hop 0, flags 0 -- local to the authenticated link,
    /// never forwarded, never held).
    public static func frameFor(arm: ControlArm, msgId: Data, routingTag: Data, payload: Data) throws -> FrameV2 {
        if msgId.count != idBytes { throw ControlException(.wrongSize) }
        if routingTag.count != 4 { throw ControlException(.wrongSize) }
        return FrameV2(
            type: arm.outerCode,
            msgId: msgId,
            routingTag: routingTag,
            ttl: 0,
            hopCount: 0,
            flags: 0,
            payload: payload
        )
    }
}
