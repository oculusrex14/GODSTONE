import Foundation

/// Elected role for a BLE link between two peers (ADR-002, Phase C8.4D1).
public enum BleRole: Sendable, Equatable {
    case initiator
    case responder
}

/// Result of deterministic role election based on unsigned-byte lexicographic comparison of 4-byte node hints.
public enum BleRoleElectionResult: Equatable, Sendable {
    case elected(BleRole)
    case tie
    case invalid(String)
}

/// Pure, platform-independent helper for deterministic BLE role election (ADR-002 §3, Phase C8.4D1-A1).
///
/// For unequal 4-byte node hints:
///   initiator = peer with lexicographically smaller node_hint (unsigned byte comparison).
///
/// For equal 4-byte hints:
///   Returns `.tie` (fails closed, no silent tie-breaker fallback).
public enum BleRoleElection {

    public static let nodeHintBytes = 4

    public static func elect(localHint: Data, remoteHint: Data) -> BleRoleElectionResult {
        guard localHint.count == nodeHintBytes else {
            return .invalid("localHint count \(localHint.count) != \(nodeHintBytes)")
        }
        guard remoteHint.count == nodeHintBytes else {
            return .invalid("remoteHint count \(remoteHint.count) != \(nodeHintBytes)")
        }

        let localBytes = [UInt8](localHint)
        let remoteBytes = [UInt8](remoteHint)

        for i in 0..<nodeHintBytes {
            let l = localBytes[i]
            let r = remoteBytes[i]
            if l < r {
                return .elected(.initiator)
            } else if l > r {
                return .elected(.responder)
            }
        }

        // Equal hints: fail closed
        return .tie
    }
}

/// Canonical 13-byte LinkInfo structure exchanged over the link_info GATT characteristic (ADR-002 §2, Phase C8.4D1-A1/R2).
public struct BleLinkInfoV1: Equatable, Sendable {
    public let version: UInt8
    public let flags: UInt8
    public let nodeHint: Data
    public let shortDigest: Data
    public let queueDepth: UInt8

    public var isSosPresent: Bool { (flags & BleLinkInfoConstants.flagSosPresent) != 0 }
    public var isBulkCapable: Bool { (flags & BleLinkInfoConstants.flagBulkCapable) != 0 }
    public var isPowerConstrained: Bool { (flags & BleLinkInfoConstants.flagPowerConstrained) != 0 }
    public var isVerifiedOnly: Bool { (flags & BleLinkInfoConstants.flagVerifiedOnly) != 0 }
    public var isClockUntrusted: Bool { (flags & BleLinkInfoConstants.flagClockUntrusted) != 0 }

    public init(
        version: UInt8,
        flags: UInt8,
        nodeHint: Data,
        shortDigest: Data,
        queueDepth: UInt8
    ) {
        self.version = version
        self.flags = flags
        self.nodeHint = nodeHint
        self.shortDigest = shortDigest
        self.queueDepth = queueDepth
    }
}

public typealias BleDiscoveryMetadata = BleLinkInfoV1

public enum BleLinkInfoConstants {
    public static let linkInfoBytes = 13
    public static let discoveryPayloadBytes = 13
    public static let protocolVersion: UInt8 = 0x02
    public static let nodeHintBytes = 4
    public static let shortDigestBytes = 6

    public static let flagSosPresent: UInt8 = 0x01
    public static let flagSos: UInt8 = 0x01
    public static let flagBulkCapable: UInt8 = 0x02
    public static let flagPowerConstrained: UInt8 = 0x04
    public static let flagVerifiedOnly: UInt8 = 0x08
    public static let flagClockUntrusted: UInt8 = 0x10
}

public enum BleDiscoveryConstants {
    public static let discoveryPayloadBytes = 13
    public static let protocolVersion: UInt8 = 0x02
    public static let nodeHintBytes = 4
    public static let shortDigestBytes = 6

    public static let flagSosPresent: UInt8 = 0x01
    public static let flagSos: UInt8 = 0x01
    public static let flagBulkCapable: UInt8 = 0x02
    public static let flagPowerConstrained: UInt8 = 0x04
    public static let flagVerifiedOnly: UInt8 = 0x08
    public static let flagClockUntrusted: UInt8 = 0x10
}

public enum BleLinkInfoCodec {

    public static func encode(
        version: UInt8 = BleLinkInfoConstants.protocolVersion,
        flags: UInt8,
        nodeHint: Data,
        shortDigest: Data,
        queueDepth: UInt8
    ) -> Data {
        precondition(nodeHint.count == BleLinkInfoConstants.nodeHintBytes, "nodeHint must be exactly 4 bytes")
        precondition(shortDigest.count == BleLinkInfoConstants.shortDigestBytes, "shortDigest must be exactly 6 bytes")

        var out = Data(capacity: BleLinkInfoConstants.linkInfoBytes)
        out.append(version)
        out.append(flags)
        out.append(nodeHint)
        out.append(shortDigest)
        out.append(queueDepth)
        return out
    }

    /// Decode and validate a canonical 13-byte LinkInfo payload.
    /// Normative requirement: length == 13 and version == 0x02.
    public static func decode(_ data: Data) -> BleLinkInfoV1? {
        guard data.count == BleLinkInfoConstants.linkInfoBytes else { return nil }

        let b = [UInt8](data)
        let version = b[0]
        guard version == BleLinkInfoConstants.protocolVersion else { return nil }

        let flags = b[1]
        let nodeHint = data.subdata(in: 2..<6)
        let shortDigest = data.subdata(in: 6..<12)
        let queueDepth = b[12]

        return BleLinkInfoV1(
            version: version,
            flags: flags,
            nodeHint: nodeHint,
            shortDigest: shortDigest,
            queueDepth: queueDepth
        )
    }
}

public enum BleDiscoveryCodec {
    public static func encode(
        version: UInt8 = BleDiscoveryConstants.protocolVersion,
        flags: UInt8,
        nodeHint: Data,
        shortDigest: Data,
        queueDepth: UInt8
    ) -> Data {
        return BleLinkInfoCodec.encode(
            version: version,
            flags: flags,
            nodeHint: nodeHint,
            shortDigest: shortDigest,
            queueDepth: queueDepth
        )
    }

    public static func decode(_ data: Data) -> BleDiscoveryMetadata? {
        return BleLinkInfoCodec.decode(data)
    }
}
