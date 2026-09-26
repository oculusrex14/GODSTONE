import Foundation
import CoreBluetooth
import GodstoneCore

// ================================================================================================
// GS-INTEGRATION-001 `real-adapters`: THE REAL-TRANSPORT HOST RIG.
//
// *** THE CARD'S OWN COMPLAINT, WHICH IS THE WHOLE REASON THIS FILE EXISTS: *** *"The existing malformed
// `FrameV2.decode` test is only structural wire validation. It does NOT prove handshake identity/key rejection.
// Drive the SEALED/REAL handshake road."* **AND THE COURT'S OWN RECORD OF THE GAP: THE COMPONENT-INTEGRATION
// HARNESS (`ComposedRuntime.swift`) CARRIETH NO TRANSPORT AT ALL** -- it hands `FrameV2` objects to a dictionary of
// byte arrays, so no handshake, no sealed record, no fragmenter, no lease, no admission budget and no real SQLite
// store is ever exercised by it.
//
// **SO THIS RIG SUBSTITUTES ONLY WHAT A HOST CANNOT OWN, AND NAMES THEM EXHAUSTIVELY:**
//
//   1. **THE PLATFORM'S MANAGER PAIR** (`TransportManagerFactory`) -- `CBCentralManager`/`CBPeripheralManager` need a
//      real radio and a real process entitlement; the pair is a subclass that records the calls the stack would make.
//   2. **THE RADIO ITSELF** (`RadioFabric`) -- bytes cross a registry of links, **RECORDED VERBATIM PER WRITE**, and
//      are re-delivered by entering the RECEIVING side's **REAL** CoreBluetooth entry points
//      (`processCentralDidDiscover` / `processCentralConnect` / `processPeripheralDiscoverServices` /
//      `processPeripheralDiscoverCharacteristics` / `processPeripheralUpdateValue` / `processPeripheralWriteValue` /
//      `processPeripheralNotificationStateUpdated` / `processInboundWrite` / `processInboundSubscribe` /
//      `processPeripheralReceiveWrite` **and nothing else**). No transport method is called for an event the radio
//      did not bring, and no `PeerFound`, `drainSyncFrames`, `turnAcks`, readiness setter or store write is ever
//      reached by the rig's arms.
//   3. **THE HOST KEYCHAIN FACADE** -- a dictionary, because a host court may not write the process's real keychain.
//
// **EVERYTHING ELSE IS PRODUCTION**: the graph is built by `MeshRuntime.createArchiveOnlyHostComposition` (the
// composition root, **over temp ON-DISK URLs**, so the stores are the real `SqliteMessageStore` /
// `SqlitePeerIdentityStore` and not an in-memory model of them), and each node is the runtime's OWN `MeshNode` and
// the runtime's OWN `BleTransport`, opened through `UnifiedRuntimeLifecycle` over `LifecycleTransportAdapter`.
//
// *** THE LANE: `compositionLane: .labHost`. *** *Every node built here takes the host lane **through the
// composition root** -- not by editing the shipping static -- so the four link-layer gates (`start()`,
// `broadcastSos`, the two `transportDidReceive`) are open for the rig while `BleTransport.linkLayerReady` stays
// `false` for the product. That is also why the rig can never leak into shipping: `Godstone-Light` does not link
// this module, and a `.shipping` composition of the same code still refuses every one of those four roads.*
//
// **PUBLIC HANDLE, INTERNAL GUTS** (per the assignment): the type and its node/link verbs are public so the court
// can name them; the doubles, the fabric and the wiring helpers are `internal`.
// ================================================================================================

public final class RealTransportHostRig {

    // ============================================================================================
    // MARK: - the fabric (the ONLY thing that crosses a "radio")
    // ============================================================================================

    /// One recorded write: the exact bytes the stack was handed, and where they went.
    public struct WireWrite: Sendable, Equatable {
        public let from: String
        public let to: String
        public let bytes: Data
        /// The GATT characteristic the write named, as the classifier read it (`inbox` or `linkInfo`).
        public let characteristic: String
        public let atSeq: Int
    }

    /// *** THE RADIO, AS A RECORD. *** *Every byte handed to `writeValue`/`updateValue` is appended HERE, verbatim,
    /// before it is delivered -- so "the frame left the node" is a fact about captured bytes rather than a claim.
    /// The `egress` window counts bytes written between two marks, which is how a msg_id is attributed to the wire
    /// without pretending to find a sixteen-octet id inside ciphertext.*
    internal final class RadioFabric {
        private let lock = NSLock()
        private var writes: [WireWrite] = []
        private var seq = 0
        /// Bound on the record: telemetry, drop-oldest, counted (the T44 idiom).
        static let maxRecorded = 20_000
        private(set) var dropped = 0

        @discardableResult
        func record(from: String, to: String, bytes: Data, characteristic: String) -> Int {
            lock.lock()
            seq += 1
            let s = seq
            while writes.count >= RadioFabric.maxRecorded { writes.removeFirst(); dropped += 1 }
            writes.append(WireWrite(from: from, to: to, bytes: Data(bytes),
                                    characteristic: characteristic, atSeq: s))
            lock.unlock()
            return s
        }

        func mark() -> Int { lock.lock(); defer { lock.unlock() }; return seq }

        func recordCount() -> Int { lock.lock(); defer { lock.unlock() }; return writes.count }

        func allWrites() -> [WireWrite] { lock.lock(); defer { lock.unlock() }; return writes }

        func writes(since: Int) -> [WireWrite] {
            lock.lock(); defer { lock.unlock() }
            return writes.filter { $0.atSeq > since }
        }

        func bytes(since: Int) -> Int { writes(since: since).reduce(0) { $0 + $1.bytes.count } }

        func bytes(from: String, to: String, since: Int) -> Int {
            writes(since: since).filter { $0.from == from && $0.to == to }
                .reduce(0) { $0 + $1.bytes.count }
        }

        func clear() { lock.lock(); writes.removeAll(); seq = 0; dropped = 0; lock.unlock() }
    }

    // ============================================================================================
    // MARK: - the substituted platform facades
    // ============================================================================================

    internal final class HostKeychain: LocalIdentityKeychain, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: Data] = [:]
        func read(tag: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return store[tag] }
        func add(tag: String, data: Data) throws { lock.lock(); store[tag] = data; lock.unlock() }
        func delete(tag: String) throws { lock.lock(); store[tag] = nil; lock.unlock() }
        func put(_ tag: String, _ data: Data) { lock.lock(); store[tag] = data; lock.unlock() }
    }

    /// The journal the composition is given: in memory, idle, readable. *The ONE thing a host run may not write is
    /// the process's real `UserDefaults`; the wipe GATE reads it either way.*
    internal final class HostJournal: WipeJournal, @unchecked Sendable {
        private let lock = NSLock()
        private var state: WipeState = .idle
        func read() -> WipeState { lock.lock(); defer { lock.unlock() }; return state }
        func write(_ s: WipeState) { lock.lock(); state = s; lock.unlock() }
        func clear() { lock.lock(); state = .idle; lock.unlock() }
        var isReadable: Bool { true }
        func set(_ s: WipeState) { write(s) }
    }

    /// A central as the stack resolves one: a real `NSObject` carrying the identifier, bridged by reference.
    internal final class HostCentralPresent: NSObject, @unchecked Sendable {
        @objc let identifier: UUID
        @objc var maximumUpdateValueLength: Int = 512
        init(identifier: UUID) { self.identifier = identifier; super.init() }
    }

    /// The peripheral's place on the wire. It answers every selector the stack messages to a connected peripheral
    /// -- including `writeValue`, whose bytes are handed to the fabric's delivery closure.
    internal final class HostPeripheral: NSObject, @unchecked Sendable {
        @objc let identifier: UUID
        @objc var state: CBPeripheralState = .connected
        @objc var services: [CBService]?
        @objc var delegate: CBPeripheralDelegate?
        @objc var canSendWriteWithoutResponse = true
        private let lock = NSLock()
        private var written: [Data] = []
        /// Where a write goes: `(bytes, characteristicUuid)`.
        var onWrite: ((Data, CBUUID) -> Void)?
        var maxWrite = 512

        init(identifier: UUID) { self.identifier = identifier; super.init() }

        @objc(maximumWriteValueLengthForType:)
        func maximumWriteValueLength(for writeType: CBCharacteristicWriteType) -> Int { maxWrite }

        @objc(writeValue:forCharacteristic:type:)
        func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
            lock.lock(); written.append(data); lock.unlock()
            onWrite?(data, characteristic.uuid)
        }
        @objc func discoverServices(_ services: [CBUUID]) {}
        @objc func discoverCharacteristics(_ characteristics: [CBUUID], for service: CBService) {}
        @objc func readRSSI() {}
        @objc func readCharacter(_ characteristic: CBCharacteristic) {}
        @objc(setNotifyValue:forCharacteristic:)
        func setNotifyValue(_ v: Bool, for characteristic: CBCharacteristic) {}
        var writes: [Data] { lock.lock(); defer { lock.unlock() }; return written }
        func clearWrites() { lock.lock(); written.removeAll(); lock.unlock() }
    }

    /// The responder's manager: records every `updateValue` and hands the accepted bytes to the fabric, **with the
    /// subscribed central's own identifier** so the rig delivers to the relation the value was staged for.
    internal final class HostPeripheralManager: CBPeripheralManager, @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [Data] = []
        private var answers: [CBATTError.Code] = []
        var updateAnswer: (Data) -> Bool = { _ in true }
        /// `(bytes, centralIdentifier, characteristicUuid)`.
        var onUpdate: ((Data, UUID, CBUUID) -> Void)?

        override func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic,
                                 onSubscribedCentrals centrals: [CBCentral]?) -> Bool {
            lock.lock(); attempts.append(value); lock.unlock()
            guard updateAnswer(value) else { return false }
            if let first = centrals?.first {
                onUpdate?(value, first.identifier, characteristic.uuid)
            }
            return true
        }
        override func respond(to request: CBATTRequest, withResult result: CBATTError.Code) {
            lock.lock(); answers.append(result); lock.unlock()
        }
        var updateAttempts: [Data] { lock.lock(); defer { lock.unlock() }; return attempts }
        func clearAttempts() { lock.lock(); attempts.removeAll(); lock.unlock() }
        var respondedResults: [CBATTError.Code] { lock.lock(); defer { lock.unlock() }; return answers }
    }

    /// The central manager of an epoch: `connect` is RECORDED and answered here, because a fabricated handle must
    /// never reach the system's connection machinery.
    internal final class HostCentralManager: CBCentralManager, @unchecked Sendable {
        private let lock = NSLock()
        private var connects: [UUID] = []
        private var scanned = 0
        override func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {
            lock.lock(); connects.append(peripheral.identifier); lock.unlock()
        }
        override func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]?) {
            lock.lock(); scanned += 1; lock.unlock()
        }
        override func stopScan() {}
        override func cancelPeripheralConnection(_ peripheral: CBPeripheral) {}
        var capturedConnects: [UUID] { lock.lock(); defer { lock.unlock() }; return connects }
        var scanCalls: Int { lock.lock(); defer { lock.unlock() }; return scanned }
    }

    /// The factory the epoch is built over: **ONE pair per node**, so the node's inbound and outbound legs are the
    /// same objects throughout (the transport's own `ManagerContext` still owns and wires them).
    internal final class HostManagerFactory: NSObject, TransportManagerFactory, @unchecked Sendable {
        private let lock = NSLock()
        private var centers: [HostCentralManager] = []
        private var peripherals: [HostPeripheralManager] = []
        func makeCentralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBCentralManager {
            let m = HostCentralManager(delegate: nil, queue: queue)
            lock.lock(); centers.append(m); lock.unlock()
            return m
        }
        func makePeripheralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBPeripheralManager {
            let m = HostPeripheralManager(delegate: nil, queue: queue)
            lock.lock(); peripherals.append(m); lock.unlock()
            return m
        }
        var centralManagers: [HostCentralManager] { lock.lock(); defer { lock.unlock() }; return centers }
        var peripheralManagers: [HostPeripheralManager] { lock.lock(); defer { lock.unlock() }; return peripherals }
        var lastPeripheralManager: HostPeripheralManager? { peripheralManagers.last }
    }

    /// The pinned request: answers every selector the responder's write loop messages, so no fabricated handle
    /// reaches the framework's own ATT map.
    internal final class HostRequest: NSObject, @unchecked Sendable {
        @objc let central: CBCentral?
        @objc var characteristic: CBCharacteristic?
        @objc var offset: UInt16 = 0
        @objc var value: Data?
        init(pinnedCentral: CBCentral, uuid: CBUUID, value: Data) {
            self.central = pinnedCentral
            self.value = value
            super.init()
            self.characteristic = unsafeBitCast(HostCharacteristic(uuid: uuid), to: CBCharacteristic.self)
        }
    }

    internal final class HostCharacteristic: NSObject, @unchecked Sendable {
        private let id: CBUUID
        init(uuid: CBUUID) { self.id = uuid; super.init() }
        @objc func UUID() -> CBUUID { return id }
        @objc func uuid() -> CBUUID { return id }
    }

    internal final class NotifyingInboxCharacteristic: CBMutableCharacteristic {
        override var isNotifying: Bool { return true }
    }

    // ============================================================================================
    // MARK: - one node of the rig
    // ============================================================================================

    /// *** ONE REAL NODE: THE COMPOSITION ROOT'S RUNTIME, ITS OWN NODE, ITS OWN TRANSPORT. ***
    public final class Node {
        public let label: String
        internal let runtime: MeshRuntime
        internal let keychain: HostKeychain
        internal let journal: HostJournal
        internal let factory: HostManagerFactory
        /// The signing seed the identity was seeded with, so the rig can AUTHOR as this node (production identities
        /// never release their seed -- the composition's own `IdentityAckSigner` signeth internally, and this is the
        /// rig's authoring material only).
        internal let signingSeed: Data
        internal var urls: [URL] { [runtime.messageStoreUrl, runtime.peerStoreUrl] }

        internal init(label: String, runtime: MeshRuntime, keychain: HostKeychain,
                      journal: HostJournal, factory: HostManagerFactory, signingSeed: Data) {
            self.label = label
            self.runtime = runtime
            self.keychain = keychain
            self.journal = journal
            self.factory = factory
            self.signingSeed = signingSeed
        }

        public var identity: MeshIdentity { runtime.identity }
        public var messageStore: SqliteMessageStore { runtime.messageStore }
        internal var node: MeshNode { runtime.meshNode }
        internal var ble: BleTransport { runtime.meshNode.ble }
    }

    /// One established relation, as BOTH sides name it: the handle the initiator knows the responder by, and the
    /// handle the responder knows the initiator by. **They are not the same UUID, exactly as on a real radio.**
    public struct Link {
        public let a: String
        public let b: String
        /// The handle `a` names `b` by (its outbound peripheral).
        public let aHandle: UUID
        /// The handle `b` names `a` by (its inbound central).
        public let bHandle: UUID
        internal var peripheral: HostPeripheral?
    }

    // ============================================================================================
    // MARK: - state
    // ============================================================================================

    internal let fabric = RadioFabric()
    internal var nodes: [String: Node] = [:]
    internal var links: [Link] = []
    private var tempRoot: URL
    /// Every message a node handed to a link, attributed by the send window it stood in.
    internal var egressByLabel: [String: [Data: Int]] = [:]

    public init(tempDirectory: URL? = nil) {
        let root = tempDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("gs_rig_" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.tempRoot = root
    }

    // ============================================================================================
    // MARK: - construction
    // ============================================================================================

    /// *** BUILD A REAL NODE. *** *The identity is seeded from the keychain FACADE with the given bytes, the graph is
    /// the composition root over temp on-disk URLs, and the node's transport is handed the manager-factory override
    /// BEFORE any epoch exists -- so the epoch's managers are the fabric's.*
    @discardableResult
    internal func makeNode(label: String, seedByte: UInt8, staticPrivByte: UInt8) throws -> Node {
        let keychain = HostKeychain()
        let state = try LocalIdentityStateV1(generation: 0,
                                             ed25519Seed: Data(repeating: seedByte, count: 32),
                                             x25519PrivateKey: Data(repeating: staticPrivByte, count: 32))
        keychain.put(MeshIdentity.v1Tag, state.encode())
        let journal = HostJournal()
        let factory = HostManagerFactory()
        let urlSuffix = "\(label)_\(seedByte)"
        let messageUrl = tempRoot.appendingPathComponent("msg_\(urlSuffix).db")
        let peerUrl = tempRoot.appendingPathComponent("peer_\(urlSuffix).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: messageUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain,
            compositionLane: .labHost)
        // *** THE OVERRIDE IS SET ON THE LIVE TRANSPORT, BEFORE THE EPOCH. *** *`installFreshContextLocked` readeth
        // it at birth; nothing else about the factory road changes.*
        runtime.meshNode.ble.testManagerFactoryOverride = factory
        let node = Node(label: label, runtime: runtime, keychain: keychain, journal: journal,
                        factory: factory, signingSeed: Data(repeating: seedByte, count: 32))
        // *** AND THE NODE'S OWN IDENTITY IS PINNED THROUGH THE PRODUCTION VALIDATOR ROAD, *** *because the ACK road
        // verifyeth its own fresh signature through the resolver, and the composition pins no row for its own node
        // id -- measured in `GsStress001RealRuntimeDriverTests` and re-measured here.*
        try pin(runtime.identity, into: node)
        nodes[label] = node
        return node
    }

    internal func node(_ label: String) -> Node? { nodes[label] }

    internal static func linkInfo(_ hint: Data) -> Data {
        return BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: hint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0)
    }

    internal static func provisionedService() -> CBMutableService {
        let installed = BleTransport.characteristicsToInstall(BleTransport.meshProfile)
        let service = CBMutableService(type: BleTransport.meshProfile.serviceUuid, primary: true)
        service.characteristics = installed
        return service
    }

    /// *** ONE IDENTITY PINNED THROUGH THE FROZEN VALIDATOR, NOT A BYPASS. *** *An invalid binding cannot be minted
    /// (the `ValidatedPeerBinding` initializer is fileprivate), and a wrong static key or hint is refused by the
    /// validator itself -- so this is the production road (`LabRuntime` useth the same three calls).*
    internal func pin(_ identity: MeshIdentity, into node: Node) throws {
        let serialized = try identity.issueIdentityBinding().encode()
        guard case .valid(let binding) = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: identity.staticDhPublicKey,
            advertisedNodeHint: identity.nodeHint) else {
            throw RigError.bindingRefused(identity.nodeHint.map { String(format: "%02x", $0) }.joined())
        }
        let applied = node.runtime.peerRepository.applyValidatedBinding(binding)
        switch applied {
        case .firstSeenPinned, .accepted:
            return
        default:
            throw RigError.pinRefused(String(describing: applied))
        }
    }

    public enum RigError: Error, CustomStringConvertible {
        case unknownNode(String)
        case bindingRefused(String)
        case pinRefused(String)
        case discoveryRefused(String)
        case connectRefused(String)
        case handshakeRefused(String, String)
        case notEstablished(String)
        case noLink(String, String)
        case noWriter(String)

        public var description: String {
            switch self {
            case .unknownNode(let l): return "unknown node \(l)"
            case .bindingRefused(let h): return "the frozen validator refused the binding for hint \(h)"
            case .pinRefused(let r): return "the repository refused the pinned binding: \(r)"
            case .discoveryRefused(let r): return "the discovery door refused: \(r)"
            case .connectRefused(let r): return "the connect door refused: \(r)"
            case .handshakeRefused(let side, let ring): return "the handshake refused on \(side); ring: \(ring)"
            case .notEstablished(let d): return "the relation never became ready: \(d)"
            case .noLink(let a, let b): return "no link from \(a) to \(b)"
            case .noWriter(let l): return "no writer stood for \(l)"
            }
        }
    }

    // ============================================================================================
    // MARK: - the link: establishment through the REAL delegate surfaces ONLY
    // ============================================================================================

    /// *** ESTABLISH `a`-`b` OVER THE FABRIC, DRIVEN BY THE OS FACADES ONLY. ***
    ///
    /// *The sequence is the real one, in the real order, and every step enters a production entry point: discovery
    /// (`processCentralDidDiscover`), the connect leg (`processCentralConnect`), the service and characteristic walks,
    /// the link-info read and its write-back, the notification-state reduction -- **which is where IOS-02 makes
    /// production begin the trusted handshake** -- and then every counsel and every DATA record crosses the fabric
    /// into the peer's own CoreBluetooth entry.*
    ///
    /// **WHAT THE RIG NEVER DOES**: it never calls `beginTrustedHandshake` (production issueth HS1 by itself), never
    /// calls `markReadyForTesting`, never calls a session-manager handshake entry, and never writes a store row.
    @discardableResult
    public func link(_ aLabel: String, _ bLabel: String) throws -> Link {
        guard let a = nodes[aLabel] else { throw RigError.unknownNode(aLabel) }
        guard let b = nodes[bLabel] else { throw RigError.unknownNode(bLabel) }
        let aHandle = UUID()
        let bHandle = UUID()
        var link = Link(a: aLabel, b: bLabel, aHandle: aHandle, bHandle: bHandle)

        // ---- the responder's ground: the link-info write binds the relation, the subscription seats it ---------
        b.ble.start()
        let bPM = b.ble.requireContextPeripheralForTest()
        let w = b.ble.processInboundWrite(centralId: bHandle,
                                          rawData: Self.linkInfo(a.identity.nodeHint),
                                          sourceEpoch: b.ble.currentTransportEpoch, from: bPM)
        guard String(describing: w).hasPrefix("accept") else {
            throw RigError.handshakeRefused(bLabel, "the link-info write answered \(w)")
        }
        let central = HostCentralPresent(identifier: bHandle)
        let pinnedCentral = unsafeBitCast(central, to: CBCentral.self)
        let s = b.ble.processInboundSubscribe(centralId: bHandle, central: pinnedCentral,
                                             sourceEpoch: b.ble.currentTransportEpoch, from: bPM)
        guard String(describing: s).hasPrefix("accept") else {
            throw RigError.handshakeRefused(bLabel, "the subscription answered \(s)")
        }
        // The responder's own inbox characteristic, so `updateValue` may stage its counsels.
        b.ble.setMutableInboxCharacteristicForTesting(CBMutableCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]))

        // ---- the initiator's ground: discovery -> connect -> the walks -> link-info -> notify -----------------
        a.ble.start()
        a.ble.refreshLocalLinkInfoSnapshotSync()
        let aCM = a.ble.requireContextCentralForTest()
        let peripheral = HostPeripheral(identifier: aHandle)
        link.peripheral = peripheral
        let aPeripheral = unsafeBitCast(peripheral, to: CBPeripheral.self)
        let adv: [String: Any] = [
            CBAdvertisementDataServiceDataKey: [BleTransport.serviceUuid:
                Self.linkInfo(b.identity.nodeHint)]
        ]
        a.ble.processCentralDidDiscover(aCM, peripheral: aPeripheral,
                                        advertisementData: adv, rssi: NSNumber(value: -60),
                                        sourceEpoch: a.ble.currentTransportEpoch)
        guard let aDelegate = a.ble.getRelationDelegate(aHandle) else {
            throw RigError.discoveryRefused("the discovery door admitted no relation for \(aHandle)")
        }
        _ = a.ble.processCentralConnect(peerId: aHandle, peripheral: aPeripheral,
                                        sourceEpoch: a.ble.currentTransportEpoch, from: aCM)
        _ = a.ble.processPeripheralDiscoverServices(aPeripheral, delegate: aDelegate, error: nil)
        _ = a.ble.processPeripheralDiscoverCharacteristics(aPeripheral, delegate: aDelegate,
                                                           service: Self.provisionedService(), error: nil)
        // the link-info read result: production writes its own LinkInfo back over the SAME peripheral
        let remoteLinkInfo = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: Self.linkInfo(b.identity.nodeHint),
            permissions: [.readable, .writeable])
        _ = a.ble.processPeripheralUpdateValue(aPeripheral, delegate: aDelegate,
                                               characteristic: remoteLinkInfo, error: nil)
        // the link-info write's own acknowledgement -> production armeth the notification
        let ackChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: b.identity.nodeHint,
            permissions: [.readable, .writeable])
        _ = a.ble.processPeripheralWriteValue(aPeripheral, delegate: aDelegate,
                                              characteristic: ackChar, error: nil)

        // ---- THE CROSSING: every byte either side puts on the wire enters the other side's real entry ---------
        wire(a: a, b: b, link: link)

        let notifyChar = NotifyingInboxCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable])
        _ = a.ble.processPeripheralNotificationStateUpdated(aPeripheral, delegate: aDelegate,
                                                            characteristic: notifyChar, error: nil)

        links.append(link)
        return link
    }

    /// *** THE FABRIC'S TWO WIRINGS, INSTALLED ONCE PER LINK. ***
    ///
    /// *The initiator's peripheral carrieth `writeValue` (HS1, HS3, DATA, the challenge); the responder's manager
    /// carrieth `updateValue` (HS2, the echo, the recipient ACK). **BOTH HAND THE BYTES TO THE RECEIVING SIDE'S OWN
    /// COREBLUETOOTH ENTRY**, so the receiver's reassembly, transcript, stage machine, leases, admission budgets and
    /// session registry are the production ones -- the fabric replaces the air, not the stack.*
    internal func wire(a: Node, b: Node, link: Link) {
        let bHandle = link.bHandle
        let bPM = b.ble.requireContextPeripheralForTest()
        let fabric = self.fabric
        link.peripheral?.onWrite = { bytes, uuid in
            fabric.record(from: a.label, to: b.label, bytes: bytes,
                          characteristic: uuid == BleTransport.linkInfoCharacteristicUuid ? "linkInfo" : "inbox")
            if uuid == BleTransport.linkInfoCharacteristicUuid {
                let req = HostRequest(pinnedCentral: self.centralPresent(bHandle),
                                      uuid: BleTransport.linkInfoCharacteristicUuid, value: bytes)
                _ = b.ble.processPeripheralReceiveWrite(bPM, requests: [unsafeBitCast(req, to: CBATTRequest.self)],
                                                        sourceEpoch: b.ble.currentTransportEpoch)
                return
            }
            let req = HostRequest(pinnedCentral: self.centralPresent(bHandle),
                                  uuid: BleTransport.inboxCharacteristicUuid, value: bytes)
            _ = b.ble.processPeripheralReceiveWrite(bPM, requests: [unsafeBitCast(req, to: CBATTRequest.self)],
                                                    sourceEpoch: b.ble.currentTransportEpoch)
        }
        b.factory.lastPeripheralManager?.onUpdate = { bytes, centralId, uuid in
            guard let aDelegate = a.ble.getRelationDelegate(link.aHandle) else { return }
            fabric.record(from: b.label, to: a.label, bytes: bytes,
                          characteristic: uuid == BleTransport.linkInfoCharacteristicUuid ? "linkInfo" : "inbox")
            let ch = CBMutableCharacteristic(
                type: uuid,
                properties: [.read, .write, .notify],
                value: bytes,
                permissions: [.readable, .writeable])
            _ = a.ble.processPeripheralUpdateValue(unsafeBitCast(link.peripheral, to: CBPeripheral.self),
                                                   delegate: aDelegate, characteristic: ch, error: nil)
        }
    }

    /// The pinned central for a handle: **ONE object per identifier**, so the transport's retained-central identity
    /// and the identifier the value was staged for cannot drift.
    private var centralPins: [UUID: HostCentralPresent] = [:]
    internal func centralPresent(_ id: UUID) -> CBCentral {
        if let existing = centralPins[id] { return unsafeBitCast(existing, to: CBCentral.self) }
        let p = HostCentralPresent(identifier: id)
        centralPins[id] = p
        return unsafeBitCast(p, to: CBCentral.self)
    }

    // ============================================================================================
    // MARK: - driving, authoring, observing
    // ============================================================================================

    /// Arm the owner and open both radios for `label` (the production lifecycle verb).
    internal func start(_ label: String) throws {
        guard let n = nodes[label] else { throw RigError.unknownNode(label) }
        n.runtime.lifecycle.start()
    }

    /// The trusted relations a node's OWN delegate path admitted, read from the node's route-eligible view.
    internal func trustedHandles(_ label: String) -> [UUID] {
        guard let n = nodes[label] else { return [] }
        // read through the node's own send path answer rather than a parallel census
        return n.ble.publishedRelationsForTest().map { $0.peerId }
    }

    /// Wait (bounded, no sleeps beyond a small poll) for a predicate over the real estate.
    internal func waitUntil(_ limit: Int = 400, _ predicate: () -> Bool) -> Bool {
        for _ in 0..<limit {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }

    internal func ring(_ label: String) -> String {
        guard let n = nodes[label] else { return "no node" }
        return n.ble.rejectionRecordsForTest().map { $0.site + "|" + $0.reason }.joined(separator: ", ")
    }

    /// *** AUTHOR AND DISPATCH ONE DIRECT MESSAGE OVER THE REAL TRANSPORT, AND RECORD THE SEND WINDOW. ***
    ///
    /// *The sealed inner payload is the frozen `SignedMessageV1` container (the same road `LabRuntime` and
    /// `SendDirectAuthority` travel): `SignedMessageV1.author` over the author's seed, then
    /// `Router.buildSealedMessage` under the RECIPIENT's static DH key, then the node's own `dispatchDirect` -- whose
    /// `send` closure is the production `ble.send`, so the bytes leave through the transport's own writer.*
    ///
    /// **THE EGRESS WINDOW**: the fabric's write counter is marked before and read after the dispatch, and the delta
    /// is filed under the frame's `msgId` -- **because the ciphertext carrieth no sixteen-octet id, a decode cannot
    /// attribute it; the window can, and an arm that also proves the RECIPIENT holdeth that exact `msgId` cannot be
    /// satisfied by a silent no-op.**
    @discardableResult
    public func sendDirect(from authorLabel: String, to recipientLabel: String,
                           plaintext: Data) async throws -> (frame: FrameV2, result: String, egressBytes: Int) {
        guard let a = nodes[authorLabel] else { throw RigError.unknownNode(authorLabel) }
        guard let b = nodes[recipientLabel] else { throw RigError.unknownNode(recipientLabel) }
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let createdAt = Int64(Date().timeIntervalSince1970)
        let container = try SignedMessageV1.author(
            senderIdentityPriv: a.signingSeed,
            senderIdentityPub: a.identity.signingPublicKey,
            senderNodeId: a.identity.nodeId,
            recipientNodeId: b.identity.nodeId,
            messageNonce: nonce,
            createdAtEpochSeconds: createdAt,
            priority: .direct,
            timeQuality: .userConfirmed,
            bodyUtf8: plaintext)
        let frame = try await a.node.router.buildSealedMessage(
            plaintext: container,
            recipientNodeId: b.identity.nodeId,
            recipientStaticPub: b.identity.staticDhPublicKey,
            identity: LogicalMessageIdentity(createdAtEpochSeconds: createdAt, messageNonce: nonce),
            priority: .direct)
        guard let aHandle = handle(between: authorLabel, and: recipientLabel) else {
            throw RigError.noLink(authorLabel, recipientLabel)
        }
        let mark = fabric.mark()
        let outcome = a.node.dispatchDirect(frame, expectedRecipient: b.identity.nodeId) { f, peer in
            // the PRODUCTION send road, keyed by the handle the relation was admitted under
            guard peer == aHandle else { return false }
            return a.ble.send(f, to: peer) == .admitted
        }
        let delta = fabric.bytes(from: authorLabel, to: recipientLabel, since: mark)
        egressByLabel[authorLabel, default: [:]][frame.msgId] = delta
        return (frame, String(describing: outcome), delta)
    }

    /// The bytes this rig watched `label` write towards some peer, for the frame it authored with `msgId`.
    public func recordedEgressBytes(label: String, msgId: Data) -> Int {
        return egressByLabel[label]?[msgId] ?? 0
    }

    internal func handle(between a: String, and b: String) -> UUID? {
        return links.first { $0.a == a && $0.b == b }?.aHandle
    }

    internal func links(of label: String) -> [Link] {
        return links.filter { $0.a == label || $0.b == label }
    }

    // ============================================================================================
    // MARK: - teardown
    // ============================================================================================

    public func tearDown() {
        for (_, n) in nodes {
            n.runtime.lifecycle.stop()
        }
        for url in nodes.values.flatMap({ $0.urls }) { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: tempRoot)
        nodes.removeAll()
        links.removeAll()
        fabric.clear()
        egressByLabel.removeAll()
        centralPins.removeAll()
    }
}
