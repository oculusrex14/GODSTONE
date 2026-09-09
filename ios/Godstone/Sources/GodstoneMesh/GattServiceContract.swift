import Foundation
import CoreBluetooth

///
/// T10: the canonical GATT profile of a GodStone peripheral, Swift mirror of
/// io.godstone.mesh.transport.GattServiceContract.
///
/// One service and its three characteristics are defined once, as generated
/// values from the wire contract (wire/wire_v2.yaml through FrameV2), and
/// every installer, every resolver and every controller in this tree reads
/// these values:
///
///   service   FrameV2.serviceUuidString   (A001)
///   inbox     FrameV2.inboxUuidString     (A002)  W | WR | N
///   digest    FrameV2.digestUuidString    (A003)  R | N
///   link info FrameV2.linkInfoUuidString  (A004)  R | W
///
/// The historical, hand-rolled FD short-form characteristic values
/// (0000FD01-... inbox, 0000FD02-... digest) are the non-shipping legacy
/// profile: this contract never names them and the resolvers reject trees
/// that carry them. The transport does not dual-register (advertise or scan
/// for) both protocols; there is no auto-detection.
///

/// Semantic property bits of a contract characteristic.
public enum GattProperty: Hashable, Sendable {
    case read
    case write
    case writeWithoutResponse
    case notify
}

/// One installed or installable characteristic of the canonical service tree.
public struct ContractCharacteristic: Equatable, @unchecked Sendable {
    public let uuid: CBUUID
    public let properties: Set<GattProperty>

    public init(uuid: CBUUID, properties: Set<GattProperty>) {
        self.uuid = uuid
        self.properties = properties
    }

    public static func == (left: ContractCharacteristic, right: ContractCharacteristic) -> Bool {
        return left.uuid.isEqual(right.uuid) && left.properties == right.properties
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(uuid.hashValue)
        hasher.combine(properties.hashValue)
    }
}

/// Result of resolving an inbound GATT tree against the canonical profile.
public enum ProvisionCheck: Equatable, @unchecked Sendable {
    /// The tree is exactly the canonical profile.
    case match
    /// The service itself is not the canonical service (e.g. a legacy FD-base one).
    case wrongService(CBUUID)
    /// The tree names a characteristic the contract does not recognise.
    case unexpected(CBUUID)
    /// The tree registers one characteristic uuid more than once.
    case duplicate(CBUUID)
    /// The tree carries the uuid but not (all) the required properties.
    case missing(CBUUID, required: Set<GattProperty>, found: Set<GattProperty>)
}

/// Routing decision of the server for one inbound write, by uuid equality
/// against the configured roles. LinkInfo records never reach the record
/// decoder; frame records never reach the link info store.
public enum InboundRoute: Equatable, Sendable {
    case toLinkInfo
    case toDeframer
    case notSupported
}

///
/// The canonical characteristic set, its resolvers and its mapping helpers.
///
/// A set is the service uuid plus three named, pairwise distinct roles. The
/// check resolver reports duplicate first (a tree is a set, never a bag),
/// then unexpected (any uuid beyond the contract), then missing (absent
/// characteristic or a gap in the required properties). Match requires every
/// role present exactly once with at least the required properties, and the
/// tree containing nothing beyond the contract.
///
public final class RequiredCharacteristicSet: @unchecked Sendable {
    public let serviceUuid: CBUUID
    public let inbox: ContractCharacteristic
    public let digest: ContractCharacteristic
    public let linkInfo: ContractCharacteristic

    public init(serviceUuid: CBUUID,
                 inbox: ContractCharacteristic,
                 digest: ContractCharacteristic,
                 linkInfo: ContractCharacteristic) {
        let keys = [inbox.uuid, digest.uuid, linkInfo.uuid].map { $0.uuidString.uppercased() }
        precondition(Set(keys).count == 3, "the three characteristic roles must be pairwise distinct")
        self.serviceUuid = serviceUuid
        self.inbox = inbox
        self.digest = digest
        self.linkInfo = linkInfo
    }

    public var characteristics: [ContractCharacteristic] {
        return [inbox, digest, linkInfo]
    }

    /// Resolve the service itself.
    public func checkService(_ uuid: CBUUID) -> ProvisionCheck {
        return uuid.isEqual(serviceUuid) ? .match : .wrongService(uuid)
    }

    /// Resolve a whole characteristic tree against the set.
    public func check(_ tree: [ContractCharacteristic]) -> ProvisionCheck {
        var buckets: [String: [Set<GattProperty>]] = [:]
        var order: [String] = []
        for entry in tree {
            let key = entry.uuid.uuidString.uppercased()
            if buckets[key] == nil {
                order.append(key)
            }
            var bucket = buckets[key] ?? []
            bucket.append(entry.properties)
            buckets[key] = bucket
        }

        for role in characteristics {
            let key = role.uuid.uuidString.uppercased()
            if let bucket = buckets[key], bucket.count > 1 {
                return .duplicate(role.uuid)
            }
        }

        for key in order {
            var known = false
            for role in characteristics where role.uuid.uuidString.uppercased() == key {
                known = true
            }
            if !known {
                for entry in tree where entry.uuid.uuidString.uppercased() == key {
                    return .unexpected(entry.uuid)
                }
            }
        }

        for role in characteristics {
            let key = role.uuid.uuidString.uppercased()
            guard let bucket = buckets[key] else {
                return .missing(role.uuid, required: role.properties, found: [])
            }
            let found = bucket[0]
            if !found.isSuperset(of: role.properties) {
                return .missing(role.uuid, required: role.properties, found: found)
            }
        }
        return .match
    }

    /// Convenience for the provisioning gate: true when the tree is the profile.
    public func accepts(_ tree: [ContractCharacteristic]) -> Bool {
        return check(tree) == .match
    }

    /// The one canonical set: generated UUIDs, hand-checked property masks.
    public static let mesh = RequiredCharacteristicSet(
        serviceUuid: CBUUID(string: FrameV2.serviceUuidString),
        inbox: ContractCharacteristic(
            uuid: CBUUID(string: FrameV2.inboxUuidString),
            properties: [.write, .writeWithoutResponse, .notify]
        ),
        digest: ContractCharacteristic(
            uuid: CBUUID(string: FrameV2.digestUuidString),
            properties: [.read, .notify]
        ),
        linkInfo: ContractCharacteristic(
            uuid: CBUUID(string: FrameV2.linkInfoUuidString),
            properties: [.read, .write]
        )
    )

    /// Encode a semantic property set into the platform properties mask.
    public static func cbProperties(of properties: Set<GattProperty>) -> CBCharacteristicProperties {
        var raw: UInt = 0
        if properties.contains(.read) {
            raw |= CBCharacteristicProperties.read.rawValue
        }
        if properties.contains(.write) {
            raw |= CBCharacteristicProperties.write.rawValue
        }
        if properties.contains(.writeWithoutResponse) {
            raw |= CBCharacteristicProperties.writeWithoutResponse.rawValue
        }
        if properties.contains(.notify) {
            raw |= CBCharacteristicProperties.notify.rawValue
        }
        return CBCharacteristicProperties(rawValue: raw)
    }

    /// Decode a platform properties mask into the semantic property set.
    public static func propertiesOf(_ cb: CBCharacteristicProperties) -> Set<GattProperty> {
        var out: Set<GattProperty> = []
        if cb.contains(.read) {
            out.insert(.read)
        }
        if cb.contains(.write) {
            out.insert(.write)
        }
        if cb.contains(.writeWithoutResponse) {
            out.insert(.writeWithoutResponse)
        }
        if cb.contains(.notify) {
            out.insert(.notify)
        }
        return out
    }

    /// Map a property set to the platform permission mask, preserving the
    /// historical installation: READ grants readable, WRITE and
    /// WRITE_NO_RESPONSE grant writeable, NOTIFY grants no access permission
    /// of its own (subscription travels on the CCC descriptor).
    public static func permissionsFor(_ properties: Set<GattProperty>) -> CBAttributePermissions {
        var perms: CBAttributePermissions = []
        if properties.contains(.read) {
            perms.insert(.readable)
        }
        if properties.contains(.write) || properties.contains(.writeWithoutResponse) {
            perms.insert(.writeable)
        }
        return perms
    }

    /// The legacy, non-shipping FD short-form profile. The contract never
    /// names these values and the resolvers reject trees that carry them.
    public static func isLegacyFdValue(_ uuid: CBUUID) -> Bool {
        return uuid.uuidString.uppercased().hasPrefix("0000FD")
    }
}
