// GENERATED FROM wire/wire_v2.yaml -- DO NOT EDIT BY HAND.
// Regenerate with `python -m wire.codegen`.
// ci/check_parity.py Invariant A fails the build on any hand edit.
import Foundation

/// GMP/2 frame. Header is 32 bytes, big-endian.
public struct FrameV2: Equatable {
    public static let magic: UInt16 = 0x4753
    public static let version: UInt8 = 0x02
    public static let headerSize = 32
    public static let maxPayload = 60000
    public static let maxTtl: UInt8 = 16
    public static let defaultTtl: UInt8 = 12

    /// Shared BLE identifiers. Both platforms MUST use these exact values.
    public static let serviceUuidString = "6764A001-9A5E-4C7B-B0A1-3E5D8C2F7A10"
    public static let inboxUuidString = "6764A002-9A5E-4C7B-B0A1-3E5D8C2F7A10"
    public static let digestUuidString = "6764A003-9A5E-4C7B-B0A1-3E5D8C2F7A10"

    public enum Flags {
        public static let sealed = 0x0001
        public static let compressed = 0x0002
        public static let fragmented = 0x0004
        public static let has_pow = 0x0008
        public static let ack_req = 0x0010
        public static let relay_ok = 0x0020
        public static let priority_mask = 0x0700
    }

    public let type: TypeV2
    public let msgId: Data        // 16 bytes
    public let routingTag: Data   // 4 bytes
    public let ttl: UInt8
    public let hopCount: UInt8
    public let flags: UInt16
    public let payload: Data

    public init(type: TypeV2, msgId: Data, routingTag: Data, ttl: UInt8,
                hopCount: UInt8, flags: UInt16, payload: Data) {
        precondition(msgId.count == 16, "msg_id must be 16 bytes")
        precondition(routingTag.count == 4, "routing_tag must be 4 bytes")
        precondition(ttl <= FrameV2.maxTtl, "ttl out of range")
        precondition(hopCount <= FrameV2.maxTtl, "hop_count out of range")
        precondition(payload.count <= FrameV2.maxPayload, "payload too large")
        self.type = type; self.msgId = msgId; self.routingTag = routingTag
        self.ttl = ttl; self.hopCount = hopCount; self.flags = flags
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: FrameV2.headerSize + payload.count)
        out.append(UInt8((FrameV2.magic >> 8) & 0xFF))
        out.append(UInt8(FrameV2.magic & 0xFF))
        out.append(FrameV2.version)
        out.append(type.rawValue)
        out.append(msgId)
        out.append(routingTag)
        out.append(ttl)
        out.append(hopCount)
        out.append(UInt8((flags >> 8) & 0xFF)); out.append(UInt8(flags & 0xFF))
        let len = UInt16(payload.count)
        out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
        let crc = FrameV2.crc16([UInt8](out))
        out.append(UInt8((crc >> 8) & 0xFF)); out.append(UInt8(crc & 0xFF))
        out.append(payload)
        return out
    }

    /// Bounded, fail-closed parsing. Magic, version, CRC and the declared
    /// length are validated BEFORE any allocation, so a desynced or corrupted
    /// frame is rejected rather than half-parsed into a different message.
    public static func decode(_ data: Data) -> FrameV2? {
        guard data.count >= headerSize else { return nil }
        let b = [UInt8](data)
        guard (UInt16(b[0]) << 8 | UInt16(b[1])) == magic else { return nil }
        guard b[2] == version else { return nil }
        guard let type = TypeV2(rawValue: b[3]) else { return nil }
        let ttl = b[24]
        guard ttl <= maxTtl else { return nil }
        let hop = b[25]
        guard hop <= maxTtl else { return nil }
        let flags = UInt16(b[26]) << 8 | UInt16(b[27])
        let len = Int(b[28]) << 8 | Int(b[29])
        let crc = UInt16(b[30]) << 8 | UInt16(b[31])
        guard crc == crc16(Array(b[0..<(headerSize - 2)])) else { return nil }
        guard len <= maxPayload, data.count == headerSize + len else { return nil }
        return FrameV2(type: type,
                       msgId: data.subdata(in: 4..<20),
                       routingTag: data.subdata(in: 20..<24),
                       ttl: ttl, hopCount: hop, flags: flags,
                       payload: data.subdata(in: headerSize..<(headerSize + len)))
    }

    public static func crc16(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}

public enum TypeV2: UInt8 {
    case hello = 0x11
    case digest = 0x12
    case want = 0x14
    case message = 0x18
    case ack = 0x21
    case bulk_offer = 0x22
    case bulk_chunk = 0x24
    case ping = 0x28
    case goodbye = 0x41
    case sos = 0xF0
}
