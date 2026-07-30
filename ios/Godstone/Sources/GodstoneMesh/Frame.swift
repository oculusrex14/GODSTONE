import Foundation

/// GMP/1 wire frame. Byte-for-byte identical to the Android implementation in
/// tab 04. Big-endian throughout. See 02_MESH_PROTOCOL section 5.
///
///   0      1        2        3        4 .. 19      20 .. 23   24 .. 25   26 ..
///   ver    type     ttl      flags    msg_id(16)   routing    len(2)     payload
public struct Frame: Sendable, Equatable {

    public static let version: UInt8 = 1
    public static let headerSize = 26
    public static let maxPayload = 60_000

    public enum FrameType: UInt8, Sendable {
        case handshake = 0x01
        case sos       = 0x02
        case direct    = 0x03
        case group     = 0x04
        case broadcast = 0x05
        case bulk      = 0x06
        case digest    = 0x07
        case ack       = 0x08

        /// Delivery order under congestion. SOS always wins.
        var priority: Int {
            switch self {
            case .handshake: return 0
            case .sos:       return 1
            case .ack:       return 2
            case .direct:    return 3
            case .digest:    return 4
            case .group:     return 5
            case .broadcast: return 6
            case .bulk:      return 7
            }
        }
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let sealed      = Flags(rawValue: 1 << 0)
        public static let compressed  = Flags(rawValue: 1 << 1)
        public static let fragmented  = Flags(rawValue: 1 << 2)
        public static let hasProofOfWork = Flags(rawValue: 1 << 3)
        public static let requiresAck = Flags(rawValue: 1 << 4)
    }

    public let type: FrameType
    public let ttl: UInt8
    public let flags: Flags
    public let messageId: Data      // 16 bytes
    public let routingTag: Data     // 4 bytes, rotates daily
    public let payload: Data

    public init(type: FrameType, ttl: UInt8, flags: Flags,
                messageId: Data, routingTag: Data, payload: Data) {
        precondition(messageId.count == 16, "message id must be 16 bytes")
        precondition(routingTag.count == 4, "routing tag must be 4 bytes")
        precondition(payload.count <= Frame.maxPayload, "payload too large")
        self.type = type
        self.ttl = ttl
        self.flags = flags
        self.messageId = messageId
        self.routingTag = routingTag
        self.payload = payload
    }

    public func encode() -> Data {
        var out = Data(capacity: Frame.headerSize + payload.count)
        out.append(Frame.version)
        out.append(type.rawValue)
        out.append(ttl)
        out.append(flags.rawValue)
        out.append(messageId)
        out.append(routingTag)
        out.append(UInt8((payload.count >> 8) & 0xFF))
        out.append(UInt8(payload.count & 0xFF))
        out.append(payload)
        return out
    }

    /// Bounded parsing. Every length is validated against what actually remains
    /// in the buffer before a single byte is allocated. A malicious peer must
    /// not be able to make us allocate 60 KB by lying in a 2-byte field.
    public static func decode(_ data: Data) throws -> Frame {
        guard data.count >= headerSize else { throw MeshError.malformedFrame }
        let b = [UInt8](data)

        guard b[0] == version else { throw MeshError.malformedFrame }
        guard let type = FrameType(rawValue: b[1]) else { throw MeshError.malformedFrame }

        let declared = (Int(b[24]) << 8) | Int(b[25])
        guard declared <= maxPayload,
              data.count == headerSize + declared else {
            throw MeshError.malformedFrame
        }

        return Frame(
            type: type,
            ttl: b[2],
            flags: Flags(rawValue: b[3]),
            messageId: data.subdata(in: 4..<20),
            routingTag: data.subdata(in: 20..<24),
            payload: data.subdata(in: headerSize..<(headerSize + declared))
        )
    }

    public func decremented() -> Frame? {
        guard ttl > 1 else { return nil }
        return Frame(type: type, ttl: ttl - 1, flags: flags,
                     messageId: messageId, routingTag: routingTag, payload: payload)
    }
}
