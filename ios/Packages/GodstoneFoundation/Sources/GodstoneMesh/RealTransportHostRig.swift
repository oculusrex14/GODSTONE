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
//      `processPeripheralReceiveWrite` / the two IsReady callbacks **and nothing else**). **No transport method is
//      called for an event the radio did not bring, and no `PeerFound`, `drainSyncFrames`, `turnAcks`, readiness
//      setter or store write is ever reached by the rig's arms.**
//   3. **THE HOST KEYCHAIN FACADE** -- a dictionary, because a host court may not write the process's real keychain.
//
// **EVERYTHING ELSE IS PRODUCTION**: the graph is built by `MeshRuntime.createArchiveOnlyHostComposition` (the
// composition root, **over temp ON-DISK URLs**, so the stores are the real `SqliteMessageStore` /
// `SqlitePeerIdentityStore` and not an in-memory model of them), and each node is the runtime's OWN `MeshNode` and
// the runtime's OWN `BleTransport`.
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
    /// The window counters count bytes written between two marks, which is how a msg_id is attributed to the wire
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
        /// The link-info read the characteristic walk issues (`p.readValue(for:)`) resolves to this selector; the
        /// rig answers it and lets the read RESULT come back through the real `processPeripheralUpdateValue`, which
        /// is where production writes its own LinkInfo back.
        @objc(readValueForCharacteristic:)
        func readValue(for characteristic: CBCharacteristic) {}
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
        /// The two seed bytes the identity was minted from, so a reopen over the same estate can mint the SAME
        /// identity again (a host court may not write the real keychain, and the facade is per-node).
        internal let seedByte: UInt8
        internal let staticPrivByte: UInt8
        /// Whether this node's radio has been opened (through the node, so its delegate and session registry stand).
        internal var opened = false
        internal var urls: [URL] { [runtime.messageStoreUrl, runtime.peerStoreUrl] }

        internal init(label: String, runtime: MeshRuntime, keychain: HostKeychain,
                      journal: HostJournal, factory: HostManagerFactory, signingSeed: Data,
                      seedByte: UInt8, staticPrivByte: UInt8) {
            self.label = label
            self.runtime = runtime
            self.keychain = keychain
            self.journal = journal
            self.factory = factory
            self.signingSeed = signingSeed
            self.seedByte = seedByte
            self.staticPrivByte = staticPrivByte
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
        /// Whether `a` opened the exchange (the production hint election's answer).
        public let aOpened: Bool
        internal var peripheral: HostPeripheral?
    }

    // ============================================================================================
    // MARK: - state
    // ============================================================================================

    internal let fabric = RadioFabric()
    /// *** THE DELIVERY IS ASYNCHRONOUS, AND THAT IS A CORRECTNESS REQUIREMENT RATHER THAN A CONVENIENCE. ***
    ///
    /// **MEASURED: DELIVERING ON THE CALLER'S THREAD DEADLOCKED THE TWO TRANSPORTS.** *Each transport's reductions run
    /// through `onExecutor` -> `ManagerContext.serialise` -> `queue.sync` on its OWN epoch queue. A synchronous
    /// delivery therefore NESTS one transport's `queue.sync` inside the other's, and the two cross: A holds its queue
    /// waiting for B's, while B holds its waiting for A's.* **A REAL RADIO CANNOT DO THIS -- the stack delivers on its
    /// own queues, never on the sender's call stack -- so the fabric is given a dedicated serial delivery queue and
    /// every crossing is `async` there.** *The arms wait on the estate (bounded `waitUntil`), which is exactly how a
    /// court must observe an asynchronous radio in the first place.*
    internal let deliveryQueue = DispatchQueue(label: "io.godstone.rig.radio")
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

    /// *** CLOSE A NODE'S RUNTIME THE WAY A PROCESS EXIT WOULD, THEN REOPEN THE SAME ON-DISK ESTATE. ***
    ///
    /// *A wipe is not undone by restarting, so "reopen" cannot mean "un-close the gate". What CAN be done -- and what
    /// the card's `then reopen and continue` asketh -- is to stop the owner, RELEASE the SQLite handles, and construct
    /// a FRESH runtime over the SAME URLs with an idle journal.* **THE ESTATE IS THE SAME FILE, so a durable row that
    /// survived is a fact about the disk rather than about a live object.**
    internal func closeAndReopen(_ label: String, as newLabel: String) throws -> Node {
        guard let old = nodes[label] else { throw RigError.unknownNode(label) }
        old.runtime.lifecycle.stop()
        old.runtime.messageStore.close()
        old.runtime.peerIdentityStore.close()
        return try buildNode(label: newLabel, seedByte: old.seedByte, staticPrivByte: old.staticPrivByte,
                             lane: old.runtime.meshNode.compositionLane,
                             messageUrl: old.runtime.messageStoreUrl,
                             peerUrl: old.runtime.peerStoreUrl)
    }

    /// *** A REAL NODE, ON THE HOST LANE. *** *The identity is seeded from the keychain FACADE, and the graph is the
    /// composition root over temp on-disk URLs.*
    @discardableResult
    internal func makeNode(label: String, seedByte: UInt8, staticPrivByte: UInt8) throws -> Node {
        return try buildNode(label: label, seedByte: seedByte, staticPrivByte: staticPrivByte, lane: .labHost)
    }

    /// *** THE SHIPPING TWIN OF `makeNode`, BECAUSE THE LANE WITNESS NEEDETH BOTH HALVES FROM ONE ROOT. ***
    /// *Every other thing about the node is identical -- the same stores, the same factory override, the same pinned
    /// identity -- so the only difference a court can observe between the two is `compositionLane`.*
    @discardableResult
    internal func makeShippingNode(label: String, seedByte: UInt8, staticPrivByte: UInt8) throws -> Node {
        return try buildNode(label: label, seedByte: seedByte, staticPrivByte: staticPrivByte, lane: .shipping)
    }

    private func buildNode(label: String, seedByte: UInt8, staticPrivByte: UInt8,
                           lane: CompositionLane,
                           messageUrl: URL? = nil, peerUrl: URL? = nil) throws -> Node {
        let keychain = HostKeychain()
        let state = try LocalIdentityStateV1(generation: 0,
                                             ed25519Seed: Data(repeating: seedByte, count: 32),
                                             x25519PrivateKey: Data(repeating: staticPrivByte, count: 32))
        keychain.put(MeshIdentity.v1Tag, state.encode())
        let journal = HostJournal()
        let factory = HostManagerFactory()
        let urlSuffix = "\(label)_\(seedByte)"
        let messageUrl = messageUrl ?? tempRoot.appendingPathComponent("msg_\(urlSuffix).db")
        let peerUrl = peerUrl ?? tempRoot.appendingPathComponent("peer_\(urlSuffix).db")
        let runtime = try MeshRuntime.createArchiveOnlyHostComposition(
            messageStoreUrl: messageUrl,
            peerStoreUrl: peerUrl,
            journal: journal,
            keychain: keychain,
            compositionLane: lane)
        // *** THE OVERRIDE IS SET ON THE LIVE TRANSPORT, BEFORE THE EPOCH. *** *`installFreshContextLocked` readeth
        // it at birth; nothing else about the factory road changes.*
        runtime.meshNode.ble.testManagerFactoryOverride = factory
        let node = Node(label: label, runtime: runtime, keychain: keychain, journal: journal,
                        factory: factory, signingSeed: Data(repeating: seedByte, count: 32),
                        seedByte: seedByte, staticPrivByte: staticPrivByte)
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
        case notInitiator(String)

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
            case .notInitiator(let d): return "the role election named the other party the initiator: \(d)"
            }
        }
    }

    // ============================================================================================
    // MARK: - the radio open (through the NODE, so its delegate and session registry stand)
    // ============================================================================================

    /// *** OPEN A NODE'S RADIO THROUGH THE NODE, NOT THE BARE TRANSPORT. ***
    ///
    /// *`MeshNode.start()` installs its own consumers FIRST (`ble.delegate = self`, `ble.sessions = sessions`,
    /// `ble.identity`, `ble.store`) and only then opens the adapter -- which is the whole `consume-before-open` law.
    /// **A rig that called `ble.start()` directly would open a radio with NO delegate and NO session registry, and
    /// every handshake would refuse with `no trusted session registry`** -- measured, and it is exactly what a first
    /// version of this rig did.*
    internal func open(_ label: String) throws {
        guard let n = nodes[label] else { throw RigError.unknownNode(label) }
        guard !n.opened else { return }
        guard n.runtime.meshNode.start() else {
            throw RigError.notEstablished("the node refused to start for \(label)")
        }
        n.opened = true
    }

    // ============================================================================================
    // MARK: - the link: establishment through the REAL delegate surfaces ONLY
    // ============================================================================================

    /// *** ESTABLISH `a`-`b` OVER THE FABRIC, DRIVEN BY THE OS FACADES ONLY. ***
    ///
    /// *The sequence is the real one, in the real order, and every step enters a production entry point: discovery
    /// (`processCentralDidDiscover`), the connect leg (`processCentralConnect`), the service and characteristic walks,
    /// the link-info read and its write-back, the notification-state reduction -- **which is where production begins
    /// the trusted handshake** -- and then every counsel and every DATA record crosses the fabric into the peer's own
    /// CoreBluetooth entry.*
    ///
    /// **THE ROLE IS THE PRODUCTION ELECTION'S, NOT THE CALLER'S.** *`beginTrustedHandshake` refuseth unless the
    /// local hint is strictly ASCENDANT of the remote (`hintOrder(local:remote:) < 0`), so the lexicographically
    /// smaller hint opens the exchange. **This method therefore DERIVES the initiator from the two identities rather
    /// than trusting the argument order**, and a caller whose labels name the larger hint getteth the mirrored
    /// relation -- which is what a real radio does, and is why the arm that asserts "the responder answered the
    /// initiator's first counsel" must ask the rig which side opened.*
    ///
    /// **WHAT THE RIG NEVER DOES**: it never calls `beginTrustedHandshake` (production issueth HS1 by itself), never
    /// calls `markReadyForTesting`, never calls a session-manager handshake entry, and never writes a store row.
    @discardableResult
    public func link(_ aLabel: String, _ bLabel: String) throws -> Link {
        guard let na = nodes[aLabel] else { throw RigError.unknownNode(aLabel) }
        guard let nb = nodes[bLabel] else { throw RigError.unknownNode(bLabel) }
        // *** THE ELECTION IS THE PRODUCTION FUNCTION ITSELF, NOT A LOCAL COMPARISON. *** *`BleRoleElection.elect`
        // is what the responder's own `onCentralWrite` runneth, so calling it HERE guarantees the rig's opener and the
        // engine's opener are ONE answer rather than two that happen to look alike.*
        var aAscendant = true
        switch BleRoleElection.elect(localHint: na.identity.nodeHint, remoteHint: nb.identity.nodeHint) {
        case .elected(.initiator): aAscendant = true
        case .elected(.responder): aAscendant = false
        default:
            throw RigError.notInitiator("the election refused these two hints")
        }
        let (initiator, responder) = aAscendant ? (na, nb) : (nb, na)

        // ---- BOTH RADIOS OPEN THROUGH THEIR NODES -----------------------------------------------------
        try open(aLabel)
        try open(bLabel)

        let iHandle = UUID()   // the initiator's outbound peripheral handle
        let rHandle = UUID()   // the responder's inbound central handle
        var link = Link(a: aLabel, b: bLabel,
                        aHandle: aAscendant ? iHandle : rHandle,
                        bHandle: aAscendant ? rHandle : iHandle,
                        aOpened: aAscendant)
        let iPM = initiator.ble.requireContextPeripheralForTest()
        let rPM = responder.ble.requireContextPeripheralForTest()

        // ---- the responder's ground: the link-info write binds, the subscription seats ----------------
        let w = responder.ble.processInboundWrite(centralId: rHandle,
                                                  rawData: Self.linkInfo(initiator.identity.nodeHint),
                                                  sourceEpoch: responder.ble.currentTransportEpoch, from: rPM)
        guard String(describing: w).hasPrefix("accept") else {
            throw RigError.handshakeRefused(responder.label, "the link-info write answered \(w)")
        }
        let central = centralPresent(rHandle)
        let s = responder.ble.processInboundSubscribe(centralId: rHandle, central: central,
                                                     sourceEpoch: responder.ble.currentTransportEpoch, from: rPM)
        guard String(describing: s).hasPrefix("accept") else {
            throw RigError.handshakeRefused(responder.label, "the subscription answered \(s)")
        }
        responder.ble.setMutableInboxCharacteristicForTesting(CBMutableCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]))

        // ---- the initiator's ground: discovery -> connect -> the walks -> link-info -> notify ----------
        initiator.ble.refreshLocalLinkInfoSnapshotSync()
        let iCM = initiator.ble.requireContextCentralForTest()
        let peripheral = HostPeripheral(identifier: iHandle)
        link.peripheral = peripheral
        let iPeripheral = unsafeBitCast(peripheral, to: CBPeripheral.self)
        let adv: [String: Any] = [
            CBAdvertisementDataServiceDataKey: [BleTransport.serviceUuid:
                Self.linkInfo(responder.identity.nodeHint)]
        ]
        initiator.ble.processCentralDidDiscover(iCM, peripheral: iPeripheral,
                                               advertisementData: adv, rssi: NSNumber(value: -60),
                                               sourceEpoch: initiator.ble.currentTransportEpoch)
        guard let iDelegate = initiator.ble.getRelationDelegate(iHandle) else {
            throw RigError.discoveryRefused("the discovery door admitted no relation for \(iHandle)")
        }
        _ = initiator.ble.processCentralConnect(peerId: iHandle, peripheral: iPeripheral,
                                               sourceEpoch: initiator.ble.currentTransportEpoch, from: iCM)
        _ = initiator.ble.processPeripheralDiscoverServices(iPeripheral, delegate: iDelegate, error: nil)
        _ = initiator.ble.processPeripheralDiscoverCharacteristics(iPeripheral, delegate: iDelegate,
                                                                   service: Self.provisionedService(), error: nil)
        let remoteLinkInfo = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: Self.linkInfo(responder.identity.nodeHint),
            permissions: [.readable, .writeable])
        _ = initiator.ble.processPeripheralUpdateValue(iPeripheral, delegate: iDelegate,
                                                      characteristic: remoteLinkInfo, error: nil)
        let ackChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: responder.identity.nodeHint,
            permissions: [.readable, .writeable])
        _ = initiator.ble.processPeripheralWriteValue(iPeripheral, delegate: iDelegate,
                                                     characteristic: ackChar, error: nil)

        // ---- THE CROSSING: every byte either side puts on the wire enters the other side's real entry -----
        wire(initiator: initiator, responder: responder, link: link,
             iHandle: iHandle, rHandle: rHandle, iPM: iPM, rPM: rPM)

        let notifyChar = NotifyingInboxCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable])
        _ = initiator.ble.processPeripheralNotificationStateUpdated(iPeripheral, delegate: iDelegate,
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
    ///
    /// **AND BOTH RAISE THE READINESS CALLBACK AFTER EVERY DELIVERY**, because that is the ONLY thing that resumeth a
    /// writer whose window refused or completed a staged record: the responder through
    /// `processPeripheralIsReadyToUpdateSubscribers`, the initiator through `processPeripheralIsReady`. **Without them
    /// a second staged counsel or record waits for ever -- measured, and it is why the first version of this rig's
    /// handshake stalled after HS3.**
    internal func wire(initiator: Node, responder: Node, link: Link,
                       iHandle: UUID, rHandle: UUID,
                       iPM: CBPeripheralManager, rPM: CBPeripheralManager) {
        let fabric = self.fabric
        // *** THE CROSSING RUNS ON THE DEDICATED DELIVERY QUEUE, ASYNCHRONOUSLY. ***
        //
        // *THE DECLARATION ABOVE SAID "every crossing is `async` there" AND THE FIRST VERSION DELIVERED ON THE
        // CALLER'S THREAD ANYWAY.* **MEASURED CONSEQUENCE: the two transports' non-reentrant epoch queues nested, A
        // held its queue waiting for B's while B held its waiting for A's, and the A-R-B arm HUNG with no assertion
        // and no timeout.** *A real radio cannot do this -- the stack delivers on its own queues, never on the
        // sender's call stack -- so the delivery is hoisted here, where the comment always claimed it was.*
        //
        // *** ONLY SENDABLE VALUES ARE CAPTURED. *** *The node/transport objects are not `Sendable`, so they are
        // reached through a `@unchecked Sendable` box established ONCE, at wiring time, on the queue's own
        // context -- which is where every delivery then runs.*
        let relay = DeliveryRelay(initiator: initiator, responder: responder, link: link,
                                  iHandle: iHandle, rHandle: rHandle, rPM: rPM,
                                  fabric: fabric, rig: self)
        let queue = deliveryQueue
        link.peripheral?.onWrite = { bytes, uuid in
            // *The RECORD is taken synchronously -- the egress gate readeth it the moment the sender returns, and an
            // asynchronous record would make "the bytes left the node" a claim about a later queue hop rather than
            // about the send.*
            fabric.record(from: relay.aLabel, to: relay.bLabel, bytes: bytes,
                          characteristic: uuid == BleTransport.linkInfoCharacteristicUuid ? "linkInfo" : "inbox")
            queue.async { relay.deliverInitiatorToResponder(bytes: bytes, uuid: uuid) }
        }
        responder.factory.lastPeripheralManager?.onUpdate = { bytes, _, uuid in
            // *The onUpdate closure is called DURING the responder's own send; recording here as well would be a
            // second record for one write, so the inbound leg records inside the relay only.*
            queue.async { relay.deliverResponderToInitiator(bytes: bytes, uuid: uuid) }
        }
        _ = iPM
    }

    /// *** THE TWO DELIVERY LEGS, IN ONE `@unchecked Sendable` BOX SO THE QUEUE CLOSURE CAPTURETH ONLY SAFE VALUES. ***
    ///
    /// *Everything here runs on `deliveryQueue`, one delivery at a time: the receiving transport's own entry points
    /// are then never re-entered from a sender's stack, which is what removes the crossed `queue.sync`s.*
    internal final class DeliveryRelay: @unchecked Sendable {
        private let initiator: Node
        private let responder: Node
        private let link: Link
        private let iHandle: UUID
        private let rHandle: UUID
        private let rPM: CBPeripheralManager
        private let fabric: RadioFabric
        private unowned let rig: RealTransportHostRig
        let aLabel: String
        let bLabel: String

        init(initiator: Node, responder: Node, link: Link, iHandle: UUID, rHandle: UUID,
             rPM: CBPeripheralManager, fabric: RadioFabric, rig: RealTransportHostRig) {
            self.initiator = initiator; self.responder = responder; self.link = link
            self.iHandle = iHandle; self.rHandle = rHandle; self.rPM = rPM
            self.fabric = fabric; self.rig = rig
            self.aLabel = initiator.label; self.bLabel = responder.label
        }

        /// The initiator's peripheral -> the responder's real peripheral-manager entry.
        func deliverInitiatorToResponder(bytes: Data, uuid: CBUUID) {
            let isLinkInfo = (uuid == BleTransport.linkInfoCharacteristicUuid)
            let req = HostRequest(pinnedCentral: rig.centralPresent(rHandle),
                                  uuid: isLinkInfo ? BleTransport.linkInfoCharacteristicUuid
                                                   : BleTransport.inboxCharacteristicUuid,
                                  value: bytes)
            _ = responder.ble.processPeripheralReceiveWrite(
                rPM, requests: [unsafeBitCast(req, to: CBATTRequest.self)],
                sourceEpoch: responder.ble.currentTransportEpoch)
            if !isLinkInfo {
                responder.ble.processPeripheralIsReadyToUpdateSubscribers(
                    rPM, sourceEpoch: responder.ble.currentTransportEpoch)
            }
        }

        /// The responder's manager -> the initiator's real peripheral entry.
        func deliverResponderToInitiator(bytes: Data, uuid: CBUUID) {
            guard let iDelegate = initiator.ble.getRelationDelegate(iHandle) else { return }
            fabric.record(from: responder.label, to: initiator.label, bytes: bytes,
                          characteristic: uuid == BleTransport.linkInfoCharacteristicUuid ? "linkInfo" : "inbox")
            let ch = CBMutableCharacteristic(
                type: uuid,
                properties: [.read, .write, .notify],
                value: bytes,
                permissions: [.readable, .writeable])
            _ = initiator.ble.processPeripheralUpdateValue(unsafeBitCast(link.peripheral, to: CBPeripheral.self),
                                                          delegate: iDelegate, characteristic: ch, error: nil)
            initiator.ble.processPeripheralIsReady(unsafeBitCast(link.peripheral, to: CBPeripheral.self),
                                                   delegate: iDelegate)
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

    /// The production election, as a boolean: does `a` open the exchange against `b`?
    internal func opens(_ a: String, _ b: String) -> Bool? {
        guard let na = nodes[a], let nb = nodes[b] else { return nil }
        switch BleRoleElection.elect(localHint: na.identity.nodeHint, remoteHint: nb.identity.nodeHint) {
        case .elected(.initiator): return true
        case .elected(.responder): return false
        default: return nil
        }
    }

    // ============================================================================================
    // MARK: - driving, authoring, observing
    // ============================================================================================

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

    /// *** THE TRUSTED RELATIONS A NODE'S OWN DELEGATE PATH ADMITTED. ***
    ///
    /// *Read from `linkReadyPeersForTest()` -- the transport's APPLICATION LinkReady roster, which production
    /// publisheth ONLY upon the sealed key-confirmation round. **THIS IS DELIBERATELY NOT
    /// `publishedRelationsForTest()`, WHICH IS THE *PHYSICAL* DUPLEX ROSTER**: that one fires at the link-info
    /// binding, long before trust, and an arm that waited on it would dispatch into a node whose route-eligible view
    /// (populated by `transportApplicationLinkReady` -> `trustedPeerDidConnect`) was still empty -- so
    /// `dispatchDirect` would offer to NOBODY and the egress window would read zero for a reason that had nothing to
    /// do with the message. **MEASURED: THAT IS EXACTLY WHAT A FIRST VERSION OF THE D ARM DID.***
    internal func trustedHandles(_ label: String) -> [UUID] {
        guard let n = nodes[label] else { return [] }
        return n.ble.linkReadyPeersForTest()
    }

    /// The handle `a` nameth `b` by (the outbound relation the rig established, on whichever side opened).
    internal func linkHandle(_ a: String, _ b: String) -> UUID? { handle(between: a, and: b) }

    /// *** PRESENT ONE ALREADY-AUTHORED FRAME TO A NODE'S OWN RECIPIENT INBOX. ***
    ///
    /// *This is the inbox's typed door (`acceptVerifiedAndRequireAck`), which is the production road the node's own
    /// `transportDidReceive` useth -- so a scenario that must watch the COMMIT verdict (rather than a radio) reads
    /// the same result the production ingest would.*
    internal func offerToInbox(_ label: String, frame: FrameV2, from: Data) -> InboxCommitResult? {
        guard let n = nodes[label], let inbox = n.node.recipientInbox else { return nil }
        return try? inbox.acceptVerifiedAndRequireAck(frame, receivedFrom: from, fault: nil)
    }

    // ============================================================================================
    // MARK: - the court's observation doors (every one readeth an OWNER, never a court counter)
    // ============================================================================================

    internal func messageStore(_ label: String) -> SqliteMessageStore {
        precondition(nodes[label] != nil, "no node \(label)")
        return nodes[label]!.messageStore
    }

    internal func peripheralManager(_ label: String) -> HostPeripheralManager? {
        return nodes[label]?.factory.lastPeripheralManager
    }

    internal func managerFactoryIsOverridden(_ label: String) -> Bool {
        return nodes[label]?.ble.testManagerFactoryOverride != nil
    }

    /// *The composition's OWN transport object -- the one `UnifiedRuntimeLifecycle` holdeth through
    /// `LifecycleTransportAdapter` -- not a rig-built copy.*
    internal func transportIsTheCompositionsOwn(_ label: String) -> Bool {
        guard let n = nodes[label] else { return false }
        return (n.ble as AnyObject) === (n.runtime.meshNode.ble as AnyObject)
    }

    internal func inboxCensus(_ label: String) -> InboxCensus? {
        return nodes[label]?.node.recipientInbox?.census()
    }

    internal func ackOutboxDepth(_ label: String) -> Int {
        return nodes[label]?.node.ackOutboxDepthForTest() ?? -1
    }

    /// *** ONE CANONICAL ACK, AS PRODUCTION ISSUED IT -- TAKEN FROM THE NODE'S OWN OUTBOX, NEVER MINTED. ***
    internal func drainOneAck(_ label: String) -> FrameV2? {
        return nodes[label]?.node.drainAckOutboxForLink(1).first
    }

    internal func deliveryRow(_ label: String, msgId: Data) -> DeliveryRecord? {
        guard let n = nodes[label] else { return nil }
        if case .found(let rec) = n.runtime.deliveryTracker.lookup(msgId) { return rec }
        return nil
    }

    internal func relationRing(_ label: String) -> String { ring(label) }

    // ============================================================================================
    // MARK: - authoring and dispatch
    // ============================================================================================

    /// *** AUTHOR ONE SEALED DIRECT FRAME AS `authorLabel`, FOR `recipientLabel`. ***
    ///
    /// *The sealed inner payload is the frozen `SignedMessageV1` container (the same road `LabRuntime` and
    /// `SendDirectAuthority` travel): `SignedMessageV1.author` over the author's seed, then
    /// `Router.buildSealedMessage` under the RECIPIENT's static DH key.* **Nothing here dispatches, offers or
    /// writes -- so a scenario that must present a frame to a door (an inbox, a wipe gate, a refusal court) can do so
    /// without first running a radio.**
    internal func authorDirectFrame(from authorLabel: String, to recipientLabel: String,
                                    plaintext: Data) async throws -> FrameV2 {
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
        return try await a.node.router.buildSealedMessage(
            plaintext: container,
            recipientNodeId: b.identity.nodeId,
            recipientStaticPub: b.identity.staticDhPublicKey,
            identity: LogicalMessageIdentity(createdAtEpochSeconds: createdAt, messageNonce: nonce),
            priority: .direct)
    }

    /// *** AUTHOR AND DISPATCH ONE DIRECT MESSAGE OVER THE REAL TRANSPORT, AND RECORD THE SEND WINDOW. ***
    ///
    /// *The dispatch road is the node's own `dispatchDirect`, whose `send` closure is the PRODUCTION `ble.send` --
    /// so the bytes leave through the transport's own reservation, seal, fragmenter and writer, and cross the
    /// fabric's recorded `writeValue`.*
    ///
    /// **THE EGRESS WINDOW**: the fabric's write counter is marked before and read after the dispatch, and the delta
    /// is filed under the frame's `msgId` -- **because the ciphertext carrieth no sixteen-octet id, a decode cannot
    /// attribute it; the window can, and an arm that also proves the RECIPIENT holdeth that exact `msgId` cannot be
    /// satisfied by a silent no-op.**
    @discardableResult
    public func sendDirect(from authorLabel: String, to recipientLabel: String,
                           plaintext: Data) async throws -> (frame: FrameV2, result: String, egressBytes: Int) {
        guard let a = nodes[authorLabel] else { throw RigError.unknownNode(authorLabel) }
        let frame = try await authorDirectFrame(from: authorLabel, to: recipientLabel, plaintext: plaintext)
        guard let aHandle = handle(between: authorLabel, and: recipientLabel) else {
            throw RigError.noLink(authorLabel, recipientLabel)
        }
        guard let b = nodes[recipientLabel] else { throw RigError.unknownNode(recipientLabel) }
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

    /// *** CARRY ONE ALREADY-ISSUED FRAME OUT OVER THE REAL LINK WRITER. ***
    ///
    /// *This is the link writer's road (`ble.send`), NOT a pump: it is how the recipient's own canonical ACK leaves
    /// once production has issued it into the node's outbox.* (**RECORDED, NOT GLOSSED: this isle has NO production
    /// drain for the recipient's own ACK outbox** -- `drainAckOutboxForLink` is the T54 lab seam and its only callers
    /// are the harness and courts. **So an arm that carried an ACK without ever asking for it would be inventing the
    /// acknowledgement**; this verb takes the byte that production actually issued.)
    @discardableResult
    internal func carryToWire(_ frame: FrameV2, from label: String, to toLabel: String) -> TransportResult {
        guard let a = nodes[label] else { return .rejected("unknown node") }
        guard let handle = handle(between: label, and: toLabel) else { return .rejected("no link") }
        let mark = fabric.mark()
        let verdict = a.ble.send(frame, to: handle)
        egressByLabel[label, default: [:]][frame.msgId, default: 0] +=
            fabric.bytes(from: label, to: toLabel, since: mark)
        return verdict
    }

    /// The bytes this rig watched `label` write towards some peer, for the frame it authored with `msgId`.
    public func recordedEgressBytes(label: String, msgId: Data) -> Int {
        return egressByLabel[label]?[msgId] ?? 0
    }

    /// *** THE HANDLE `a` NAMETH `b` BY -- WHICH IS ALWAYS `link.aHandle`, BY CONSTRUCTION. ***
    ///
    /// *`aHandle` is defined as exactly that: the INITIATOR's outbound peripheral handle when `a` opened, and the
    /// RESPONDER's inbound central handle when `a` did not. **THE RESPONDER CAN SEND TOO** -- `reductionSendClear`
    /// resolveth `outboundCentralConnections[peerId] ?? inboundPeripheralConnections[peerId]` and pumps through
    /// `updateValue` when `connection.localRole != .initiator`, which is how HS2 and the key-confirmation echo
    /// travel -- so both directions are legitimate and each side uses its OWN handle.*
    ///
    /// **MEASURED: A FIRST VERSION RETURNED `b`'s HANDLE FOR A RESPONDER-SENDER**, which made every responder-side
    /// send name a handle it did not hold.*
    internal func handle(between a: String, and b: String) -> UUID? {
        return links.first(where: { $0.a == a && $0.b == b })?.aHandle
    }

    /// *** WHICH SIDE OPENED THE EXCHANGE (the production hint election), AND WHO IS ITS PEER. ***
    /// *The opener alone carrieth the OUTBOUND relation, so the opener alone can `ble.send`; a court must author from
    /// it. Exposed so an arm can say so rather than assume a direction the election did not grant.*
    internal func opener(of a: String, _ b: String) -> String? {
        guard let aOpens = opens(a, b) else { return nil }
        return aOpens ? a : b
    }

    internal func peer(of a: String, _ b: String) -> String? {
        guard let o = opener(of: a, b) else { return nil }
        return o == a ? b : a
    }

    /// *** THE DIRECTION THAT CAN LOCALLY DELIVER, AND WHY IT IS NOT ARBITRARY. ***
    ///
    /// *The recipient inbox is reached from the transport's RECEIVED road, and that road passeth the authenticated
    /// sender's node id ONLY when `capturedPeers[handle]` standeth -- populated by `captureTrustedPeerLocked`, called
    /// from `publishApplicationLinkReadyOnce`, reached (on this isle) **only from `takeInboundKeyConfirmation`'s
    /// RESPONSE branch.** *The initiator issueth the challenge and therefore receiveth the echo and captures; **the
    /// responder answereth the challenge and captures NOTHING** (its HS3 handler marks trusted-ready and publishes
    /// no Application LinkReady).* **SO THE SIDE THAT CAN DELIVER LOCALLY IS THE INITIATOR, AND THE HONEST ARM SENDS
    /// FROM THE RESPONDER TO IT.** *The alternative -- delivering to the responder -- takes the handle-only overload
    /// with `receivedFrom: Data()`, which the inbox refuseth at gate 0 (`receivedFrom.count == 16`) BEFORE its first
    /// counter bump; **that is exactly the all-zero census this rig first measured.***
    internal func deliverableDirection(_ a: String, _ b: String) -> (sender: String, receiver: String)? {
        guard let o = opener(of: a, b) else { return nil }
        return (sender: o == a ? b : a, receiver: o)
    }

    internal func links(of label: String) -> [Link] {
        return links.filter { $0.a == label || $0.b == label }
    }

    // ============================================================================================
    // MARK: - teardown
    // ============================================================================================

    public func tearDown() {
        for (_, n) in nodes where n.opened {
            n.runtime.meshNode.stop()
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
