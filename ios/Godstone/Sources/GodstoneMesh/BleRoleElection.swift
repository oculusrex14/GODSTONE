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

/// Pure, platform-independent helper for deterministic BLE role election (ADR-002 §3).
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

        let lBytes = [UInt8](localHint)
        let rBytes = [UInt8](remoteHint)

        for i in 0..<nodeHintBytes {
            let l = lBytes[i]
            let r = rBytes[i]
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

/// Discovered BLE peer metadata parsed from the 13-byte scan-response payload (ADR-002 §2).
public struct BleDiscoveryMetadata: Equatable, Sendable {
    public let version: UInt8
    public let flags: UInt8
    public let nodeHint: Data
    public let shortDigest: Data
    public let queueDepth: UInt8

    public var isSosPresent: Bool { (flags & BleDiscoveryConstants.flagSos) != 0 }
    public var isBulkCapable: Bool { (flags & BleDiscoveryConstants.flagBulkCapable) != 0 }
    public var isPowerConstrained: Bool { (flags & BleDiscoveryConstants.flagPowerConstrained) != 0 }
    public var isVerifiedOnly: Bool { (flags & BleDiscoveryConstants.flagVerifiedOnly) != 0 }
    public var isClockUntrusted: Bool { (flags & BleDiscoveryConstants.flagClockUntrusted) != 0 }

    public init(version: UInt8, flags: UInt8, nodeHint: Data, shortDigest: Data, queueDepth: UInt8) {
        self.version = version
        self.flags = flags
        self.nodeHint = nodeHint
        self.shortDigest = shortDigest
        self.queueDepth = queueDepth
    }
}

public enum BleDiscoveryConstants {
    public static let discoveryPayloadBytes = 13
    public static let protocolVersion: UInt8 = 0x02
    public static let nodeHintBytes = 4
    public static let shortDigestBytes = 6

    public static let flagSos: UInt8 = 0x01
    public static let flagBulkCapable: UInt8 = 0x02
    public static let flagPowerConstrained: UInt8 = 0x04
    public static let flagVerifiedOnly: UInt8 = 0x08
    public static let flagClockUntrusted: UInt8 = 0x10
}

public enum BleDiscoveryCodec {

    public static func encode(
        version: UInt8 = BleDiscoveryConstants.protocolVersion,
        flags: UInt8,
        nodeHint: Data,
        shortDigest: Data,
        queueDepth: UInt8
    ) -> Data {
        precondition(nodeHint.count == BleDiscoveryConstants.nodeHintBytes, "nodeHint must be 4 bytes")
        precondition(shortDigest.count == BleDiscoveryConstants.shortDigestBytes, "shortDigest must be 6 bytes")

        var data = Data(capacity: BleDiscoveryConstants.discoveryPayloadBytes)
        data.append(version)
        data.append(flags)
        data.append(nodeHint)
        data.append(shortDigest)
        data.append(queueDepth)
        return data
    }

    public static func decode(_ data: Data) -> BleDiscoveryMetadata? {
        guard data.count >= BleDiscoveryConstants.discoveryPayloadBytes else { return nil }

        let bytes = [UInt8](data)
        let version = bytes[0]
        guard version == BleDiscoveryConstants.protocolVersion else { return nil }

        let flags = bytes[1]
        let nodeHint = Data(bytes[2..<6])
        let shortDigest = Data(bytes[6..<12])
        let queueDepth = bytes[12]

        return BleDiscoveryMetadata(
            version: version,
            flags: flags,
            nodeHint: nodeHint,
            shortDigest: shortDigest,
            queueDepth: queueDepth
        )
    }
}
