import XCTest
import CoreBluetooth
@testable import GodstoneCore
@testable import GodstoneMesh

/// T10: the GATT profile speaks the generated wire contract, on the wire and
/// in the resolvers (Swift mirror of ReadinessT10Test.kt - same cases, same
/// expectations).
///
/// Every mesh identifier the transport installs, resolves or advertises is
/// the FrameV2 value (service A001, inbox A002, digest A003, link info
/// A004). The hand-rolled FD short-form values of the non-shipping legacy
/// profile are never named by the contract, never installed, and rejected
/// whenever a resolver meets them in a tree. The provisioning gate is the
/// whole-tree resolver RequiredCharacteristicSet.check: duplicate first,
/// then unknown, then property gaps; a tree that is not the profile fails
/// discovery rather than half-connecting.
final class ReadinessT10Tests: XCTestCase {

    private func canonicalTree() -> [ContractCharacteristic] {
        let set = BleTransport.meshProfile
        return [set.inbox, set.digest, set.linkInfo]
    }

    private func legacyInboxUuid() -> CBUUID {
        return CBUUID(string: "0000FD01-0000-1000-8000-00805F9B34FB")
    }

    private func legacyDigestUuid() -> CBUUID {
        return CBUUID(string: "0000FD02-0000-1000-8000-00805F9B34FB")
    }

    private func legacyServiceUuid() -> CBUUID {
        return CBUUID(string: "0000FD00-0000-1000-8000-00805F9B34FB")
    }

    func testMeshIdentifiersAreTheGeneratedValues() {
        let set = BleTransport.meshProfile
        XCTAssertEqual(set.serviceUuid.uuidString.uppercased(), "6764A001-9A5E-4C7B-B0A1-3E5D8C2F7A10", "service A001")
        XCTAssertEqual(set.inbox.uuid.uuidString.uppercased(), FrameV2.inboxUuidString.uppercased(), "inbox A002 is the generated value")
        XCTAssertEqual(set.digest.uuid.uuidString.uppercased(), FrameV2.digestUuidString.uppercased(), "digest A003 is the generated value")
        XCTAssertEqual(set.linkInfo.uuid.uuidString.uppercased(), FrameV2.linkInfoUuidString.uppercased(), "link info A004 is the generated value")
        XCTAssertEqual(BleTransport.serviceUuid, set.serviceUuid, "transport service alias shares the contract")
        XCTAssertEqual(BleTransport.inboxCharacteristicUuid, set.inbox.uuid, "transport inbox alias follows the contract")
        XCTAssertEqual(BleTransport.digestCharacteristicUuid, set.digest.uuid, "transport digest alias follows the contract")
        XCTAssertEqual(BleTransport.linkInfoCharacteristicUuid, set.linkInfo.uuid, "transport link info alias follows the contract")
    }

    func testLegacyFdValuesAreNeverNamedAndAlwaysRejected() {
        let set = BleTransport.meshProfile
        let named = [set.serviceUuid, set.inbox.uuid, set.digest.uuid, set.linkInfo.uuid]
        for uuid in named {
            XCTAssertEqual(RequiredCharacteristicSet.isLegacyFdValue(uuid), false, "no mesh identifier may be an FD short-form value: \(uuid.uuidString)")
            XCTAssertEqual(uuid.isEqual(legacyInboxUuid()), false, uuid.uuidString)
            XCTAssertEqual(uuid.isEqual(legacyDigestUuid()), false, uuid.uuidString)
        }
        XCTAssertEqual(RequiredCharacteristicSet.isLegacyFdValue(legacyInboxUuid()), true, "the resolver recognises the legacy FD form")
        XCTAssertEqual(RequiredCharacteristicSet.isLegacyFdValue(legacyDigestUuid()), true, "the resolver recognises the legacy FD form")

        var tainted = canonicalTree()
        tainted.append(ContractCharacteristic(uuid: legacyInboxUuid(), properties: [.write, .writeWithoutResponse, .notify]))
        XCTAssertEqual(set.check(tainted), ProvisionCheck.unexpected(legacyInboxUuid()), "a tree carrying the legacy inbox is an unknown member")

        XCTAssertEqual(set.checkService(legacyServiceUuid()), ProvisionCheck.wrongService(legacyServiceUuid()), "the legacy service is refused, not auto-detected")
    }

    func testServerBlueprintIsTheCanonicalTree() {
        let set = BleTransport.meshProfile
        let blueprint = set.characteristics
        XCTAssertEqual(blueprint.count, 3, "one service installs three characteristics")
        XCTAssertEqual(blueprint, [set.inbox, set.digest, set.linkInfo], "the blueprint is the contract, element by element")
        XCTAssertEqual(blueprint[0].properties, Set<GattProperty>([.write, .writeWithoutResponse, .notify]), "inbox: write, write no response, notify")
        XCTAssertEqual(blueprint[1].properties, Set<GattProperty>([.read, .notify]), "digest: read, notify")
        XCTAssertEqual(blueprint[2].properties, Set<GattProperty>([.read, .write]), "link info: read, write")
        let roles = Set<String>(blueprint.map { $0.uuid.uuidString.uppercased() })
        XCTAssertEqual(roles.count, 3, "pairwise distinct roles")
    }

    func testInstalledTreeIsGeneratedFromTheContractOnTheRealPlatformSurface() {
        let set = BleTransport.meshProfile
        let installed = BleTransport.characteristicsToInstall(set)
        XCTAssertEqual(installed.count, 3, "the generation installs the profile")
        let roles = set.characteristics
        for index in 0..<3 {
            XCTAssertEqual(installed[index].uuid.isEqual(roles[index].uuid), true, "characteristic \(index) carries the contract uuid")
            XCTAssertEqual(installed[index].properties, RequiredCharacteristicSet.cbProperties(of: roles[index].properties), "characteristic \(index) carries the contract properties")
            XCTAssertEqual(installed[index].permissions, RequiredCharacteristicSet.permissionsFor(roles[index].properties), "characteristic \(index) carries the mapped permissions")
        }
        XCTAssertEqual(installed[0].properties.rawValue, CBCharacteristicProperties.writeWithoutResponse.rawValue | CBCharacteristicProperties.write.rawValue | CBCharacteristicProperties.notify.rawValue, "inbox mask is WR | W | N")
        XCTAssertEqual(installed[1].properties.rawValue, CBCharacteristicProperties.read.rawValue | CBCharacteristicProperties.notify.rawValue, "digest mask is R | N")
        XCTAssertEqual(installed[2].properties.rawValue, CBCharacteristicProperties.read.rawValue | CBCharacteristicProperties.write.rawValue, "link info mask is R | W")
    }

    func testPropertyAndPermissionMappingPreservesTheHistoricalInstallation() {
        let set = BleTransport.meshProfile
        XCTAssertEqual(RequiredCharacteristicSet.cbProperties(of: set.inbox.properties).rawValue, CBCharacteristicProperties.writeWithoutResponse.rawValue | CBCharacteristicProperties.write.rawValue | CBCharacteristicProperties.notify.rawValue, "inbox mask")
        XCTAssertEqual(RequiredCharacteristicSet.cbProperties(of: set.digest.properties).rawValue, CBCharacteristicProperties.read.rawValue | CBCharacteristicProperties.notify.rawValue, "digest mask")
        XCTAssertEqual(RequiredCharacteristicSet.cbProperties(of: set.linkInfo.properties).rawValue, CBCharacteristicProperties.read.rawValue | CBCharacteristicProperties.write.rawValue, "link info mask")
        XCTAssertEqual(RequiredCharacteristicSet.permissionsFor(set.inbox.properties), CBAttributePermissions.writeable, "inbox permission is writeable only")
        XCTAssertEqual(RequiredCharacteristicSet.permissionsFor(set.digest.properties), CBAttributePermissions.readable, "digest permission is readable only")
        let linkInfoPermissions: CBAttributePermissions = [.readable, .writeable]
        XCTAssertEqual(RequiredCharacteristicSet.permissionsFor(set.linkInfo.properties), linkInfoPermissions, "link info permission is readable and writeable")
        // The descriptor attaches to every notify-capable characteristic: the
        // decision is observable on the blueprint's property sets.
        XCTAssertEqual(set.inbox.properties.contains(.notify), true, "inbox carries notify")
        XCTAssertEqual(set.digest.properties.contains(.notify), true, "digest carries notify")
        XCTAssertEqual(set.linkInfo.properties.contains(.notify), false, "link info does not carry notify")
        // Round trip through the masks for every role.
        for entry in set.characteristics {
            XCTAssertEqual(RequiredCharacteristicSet.propertiesOf(RequiredCharacteristicSet.cbProperties(of: entry.properties)), entry.properties, "round trip \(entry.uuid.uuidString)")
        }
    }

    func testResolverAcceptsTheCanonicalTree() {
        let set = BleTransport.meshProfile
        XCTAssertEqual(set.check(canonicalTree()), ProvisionCheck.match, "the profile resolves to match")
        XCTAssertEqual(set.accepts(canonicalTree()), true, "the provisioning gate accepts it")
        XCTAssertEqual(set.checkService(set.serviceUuid), ProvisionCheck.match, "the canonical service resolves to match")
        // The gate's acceptance function must refuse the negatives too:
        // every tree that is not the profile returns false, on the very
        // entry point the central provisioning gate calls in production.
        XCTAssertEqual(set.accepts([set.inbox, set.linkInfo]), false, "no digest does not pass the gate")
        XCTAssertEqual(set.accepts([set.digest, set.linkInfo]), false, "no inbox does not pass the gate")
        XCTAssertEqual(set.accepts([set.inbox, set.digest]), false, "no link info does not pass the gate")
        XCTAssertEqual(
            set.accepts([
                set.inbox,
                ContractCharacteristic(uuid: set.digest.uuid, properties: [.read]),
                set.linkInfo
            ]),
            false,
            "a property gap does not pass the gate"
        )
        XCTAssertEqual(
            set.accepts([
                set.inbox,
                set.digest,
                set.linkInfo,
                ContractCharacteristic(uuid: legacyInboxUuid(), properties: [.write])
            ]),
            false,
            "an unknown member does not pass the gate"
        )
        XCTAssertEqual(
            set.accepts([set.inbox, set.digest, set.linkInfo, set.linkInfo]),
            false,
            "a duplicate does not pass the gate"
        )
        XCTAssertEqual(set.accepts([]), false, "an empty tree does not pass the gate")
    }

    func testResolverReportsEveryPropertyGap() {
        let set = BleTransport.meshProfile
        let noDigest = [set.inbox, set.linkInfo]
        XCTAssertEqual(
            set.check(noDigest),
            ProvisionCheck.missing(set.digest.uuid, required: [.read, .notify], found: []),
            "absent digest is reported as missing"
        )

        let digestWithoutNotify = [
            set.inbox,
            ContractCharacteristic(uuid: set.digest.uuid, properties: [.read]),
            set.linkInfo
        ]
        XCTAssertEqual(
            set.check(digestWithoutNotify),
            ProvisionCheck.missing(set.digest.uuid, required: [.read, .notify], found: [.read]),
            "a digest without notify is a property gap"
        )

        let inboxWithoutWriteNoResponse = [
            ContractCharacteristic(uuid: set.inbox.uuid, properties: [.write, .notify]),
            set.digest,
            set.linkInfo
        ]
        XCTAssertTrue(
            set.check(inboxWithoutWriteNoResponse) == ProvisionCheck.missing(set.inbox.uuid, required: [.write, .writeWithoutResponse, .notify], found: [.write, .notify]),
            "an inbox without write-no-response is a property gap"
        )

        XCTAssertTrue(set.check([set.digest, set.linkInfo]) == ProvisionCheck.missing(set.inbox.uuid, required: [.write, .writeWithoutResponse, .notify], found: []), "absent inbox is reported as missing")
        XCTAssertTrue(set.check([set.inbox, set.digest]) == ProvisionCheck.missing(set.linkInfo.uuid, required: [.read, .write], found: []), "absent link info is reported as missing")
    }

    func testResolverPrefersDuplicateThenUnknownThenMissing() {
        let set = BleTransport.meshProfile
        var doubled = canonicalTree()
        doubled.append(set.linkInfo)
        XCTAssertEqual(set.check(doubled), ProvisionCheck.duplicate(set.linkInfo.uuid), "a tree is a set, never a bag: duplicates are reported first")

        let unknownAndMissing = [set.inbox, set.linkInfo, ContractCharacteristic(uuid: legacyDigestUuid(), properties: [.read, .notify])]
        XCTAssertEqual(set.check(unknownAndMissing), ProvisionCheck.unexpected(legacyDigestUuid()), "an unknown member outranks a missing one")

        var duplicateAndUnknown = canonicalTree()
        duplicateAndUnknown.append(ContractCharacteristic(uuid: legacyInboxUuid(), properties: [.write]))
        duplicateAndUnknown.append(set.inbox)
        XCTAssertEqual(set.check(duplicateAndUnknown), ProvisionCheck.duplicate(set.inbox.uuid), "duplicates outrank unknown members")
    }

    func testInboundRoutingIsSingleAuthority() {
        let set = BleTransport.meshProfile
        XCTAssertEqual(BleTransport.classifyInbound(set.linkInfo.uuid), InboundRoute.toLinkInfo, "LinkInfo bytes never enter the record decoder")
        XCTAssertEqual(BleTransport.classifyInbound(set.inbox.uuid), InboundRoute.toDeframer, "frame records are the deframer's concern")
        XCTAssertEqual(BleTransport.classifyInbound(legacyInboxUuid()), InboundRoute.notSupported, "the legacy inbox value routes nowhere")
        XCTAssertEqual(BleTransport.classifyInbound(legacyDigestUuid()), InboundRoute.notSupported, "the legacy digest value routes nowhere")
        XCTAssertEqual(BleTransport.classifyInbound(CBUUID(string: "6764A099-9A5E-4C7B-B0A1-3E5D8C2F7A10")), InboundRoute.notSupported, "an alien characteristic routes nowhere")
    }

    func testDiscoveredTreeFromRealPlatformCharacteristicsResolves() {
        let inboxCh = CBMutableCharacteristic(
            type: CBUUID(string: FrameV2.inboxUuidString),
            properties: [.writeWithoutResponse, .write, .notify],
            value: nil,
            permissions: [.writeable]
        )
        let digestCh = CBMutableCharacteristic(
            type: CBUUID(string: FrameV2.digestUuidString),
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )
        let linkCh = CBMutableCharacteristic(
            type: CBUUID(string: FrameV2.linkInfoUuidString),
            properties: [.read, .write],
            value: nil,
            permissions: [.readable, .writeable]
        )
        var tree: [ContractCharacteristic] = []
        for ch in [inboxCh as CBCharacteristic, digestCh as CBCharacteristic, linkCh as CBCharacteristic] {
            tree.append(ContractCharacteristic(uuid: ch.uuid, properties: RequiredCharacteristicSet.propertiesOf(ch.properties)))
        }
        XCTAssertEqual(BleTransport.meshProfile.accepts(tree), true, "the discovered canonical tree is the profile")

        var legacyTwin: [ContractCharacteristic] = []
        for ch in [CBMutableCharacteristic(
            type: CBUUID(string: "0000FD01-0000-1000-8000-00805F9B34FB"),
            properties: [.writeWithoutResponse, .write, .notify],
            value: nil,
            permissions: [.writeable]
        ) as CBCharacteristic] {
            legacyTwin.append(ContractCharacteristic(uuid: ch.uuid, properties: RequiredCharacteristicSet.propertiesOf(ch.properties)))
        }
        for ch in [inboxCh as CBCharacteristic, digestCh as CBCharacteristic, linkCh as CBCharacteristic] {
            legacyTwin.append(ContractCharacteristic(uuid: ch.uuid, properties: RequiredCharacteristicSet.propertiesOf(ch.properties)))
        }
        XCTAssertEqual(BleTransport.meshProfile.check(legacyTwin), ProvisionCheck.unexpected(CBUUID(string: "0000FD01-0000-1000-8000-00805F9B34FB")), "the legacy twin on the real platform surface is the unknown member it always was")
    }

    func testGeneratedStringsMatchTheWireText() {
        // The resolvers compare numerically, but the shipping evidence is
        // rendered text: pin the case against wire/wire_v2.yaml verbatim.
        XCTAssertEqual(BleTransport.meshProfile.serviceUuid.uuidString, "6764A001-9A5E-4C7B-B0A1-3E5D8C2F7A10")
        XCTAssertEqual(BleTransport.meshProfile.inbox.uuid.uuidString, "6764A002-9A5E-4C7B-B0A1-3E5D8C2F7A10")
        XCTAssertEqual(BleTransport.meshProfile.digest.uuid.uuidString, "6764A003-9A5E-4C7B-B0A1-3E5D8C2F7A10")
        XCTAssertEqual(BleTransport.meshProfile.linkInfo.uuid.uuidString, "6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10")
    }
}
