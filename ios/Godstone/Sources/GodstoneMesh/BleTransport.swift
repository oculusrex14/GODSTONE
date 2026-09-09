import Foundation
import CoreBluetooth
import GodstoneCore

public struct OutboundPhysicalLifetime: Sendable {
    public let relationKey: RelationKey
    public let transportEpoch: UInt64
    public let peripheral: CBPeripheral?

    public init(relationKey: RelationKey, transportEpoch: UInt64, peripheral: CBPeripheral? = nil) {
        self.relationKey = relationKey
        self.transportEpoch = transportEpoch
        self.peripheral = peripheral
    }
}

public struct InboundSubscriptionLifetime: Sendable {
    public let relationKey: RelationKey
    public let transportEpoch: UInt64

    public init(relationKey: RelationKey, transportEpoch: UInt64) {
        self.relationKey = relationKey
        self.transportEpoch = transportEpoch
    }
}

public final class RelationPeripheralDelegate: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    public let relationKey: RelationKey
    public let transportEpoch: UInt64
    public weak var transport: BleTransport?

    public init(relationKey: RelationKey, transportEpoch: UInt64, transport: BleTransport) {
        self.relationKey = relationKey
        self.transportEpoch = transportEpoch
        self.transport = transport
        super.init()
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        _ = transport?.processPeripheralDiscoverServices(p, delegate: self, error: error)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        _ = transport?.processPeripheralDiscoverCharacteristics(p, delegate: self, service: service, error: error)
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        _ = transport?.processPeripheralUpdateValue(p, delegate: self, characteristic: ch, error: error)
    }

    public func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        _ = transport?.processPeripheralWriteValue(p, delegate: self, characteristic: ch, error: error)
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        _ = transport?.processPeripheralNotificationStateUpdated(p, delegate: self, characteristic: ch, error: error)
    }

    public func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        transport?.processPeripheralIsReady(p, delegate: self)
    }
}

///
/// T13: the transport epoch's manager pair, created fresh per epoch.
///
/// Reassigning delegates on long-lived managers is not proof of
/// callback-source identity: a reused manager carries state, wiring and
/// in-flight callbacks across the epoch boundary. A transport epoch
/// therefore owns a fresh CBCentralManager/CBPeripheralManager pair, born
/// on a dedicated serial queue, with the epoch's delegate proxies wired
/// at creation and never rewired afterwards. The reducer authenticates
/// every manager-sourced event by three identities that must agree: the
/// sending manager is the very instance of the active context, the wired
/// delegate is still the context's own proxy, and the event names the
/// context's epoch.
///
public protocol TransportManagerFactory {
    func makeCentralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBCentralManager
    func makePeripheralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBPeripheralManager
}

public final class DefaultTransportManagerFactory: TransportManagerFactory, @unchecked Sendable {
    public init() {}

    public func makeCentralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBCentralManager {
        if let restoreIdentifier {
            return CBCentralManager(
                delegate: nil,
                queue: queue,
                options: [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
            )
        }
        return CBCentralManager(delegate: nil, queue: queue)
    }

    public func makePeripheralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBPeripheralManager {
        if let restoreIdentifier {
            return CBPeripheralManager(
                delegate: nil,
                queue: queue,
                options: [CBPeripheralManagerOptionRestoreIdentifierKey: restoreIdentifier]
            )
        }
        return CBPeripheralManager(delegate: nil, queue: queue)
    }
}

public final class ManagerContext: @unchecked Sendable {
    public let epoch: UInt64
    public let queue: DispatchQueue
    public let central: CBCentralManager
    public let peripheral: CBPeripheralManager
    public let centralProxy: CentralManagerEpochDelegate
    public let peripheralProxy: PeripheralManagerEpochDelegate
    private var retiredFlag = false
    private let stateLock = NSLock()

    init(
        epoch: UInt64,
        transport: BleTransport,
        factory: TransportManagerFactory,
        restoresState: Bool
    ) {
        self.epoch = epoch
        self.queue = DispatchQueue(
            label: "io.godstone.mesh.transport.epoch." + String(epoch),
            qos: .utility,
            attributes: []
        )
        let restorePrefix = restoresState ? "io.godstone.mesh.transport." + String(epoch) + "." : nil
        self.central = factory.makeCentralManager(
            queue: self.queue,
            restoreIdentifier: restorePrefix.map { $0 + "central" }
        )
        self.peripheral = factory.makePeripheralManager(
            queue: self.queue,
            restoreIdentifier: restorePrefix.map { $0 + "peripheral" }
        )
        self.centralProxy = CentralManagerEpochDelegate(transportEpoch: epoch, transport: transport)
        self.peripheralProxy = PeripheralManagerEpochDelegate(transportEpoch: epoch, transport: transport)
        // The wiring belongs to the birth: it happens once, on the way to
        // the queue the pair will run on, and is never repeated.
        self.central.delegate = self.centralProxy
        self.peripheral.delegate = self.peripheralProxy
    }

    public var isRetired: Bool {
        stateLock.lock()
        let value = retiredFlag
        stateLock.unlock()
        return value
    }

    public func retire() {
        stateLock.lock()
        retiredFlag = true
        stateLock.unlock()
    }
}

public final class CentralManagerEpochDelegate: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    public let transportEpoch: UInt64
    public weak var transport: BleTransport?

    public init(transportEpoch: UInt64, transport: BleTransport) {
        self.transportEpoch = transportEpoch
        self.transport = transport
        super.init()
    }

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        transport?.processCentralDidUpdateState(c, sourceEpoch: transportEpoch)
    }

    public func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        transport?.processCentralWillRestoreState(c, dict: dict, sourceEpoch: transportEpoch)
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        transport?.processCentralDidDiscover(c, peripheral: p, advertisementData: advertisementData, rssi: RSSI, sourceEpoch: transportEpoch)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        _ = transport?.processCentralConnect(peerId: p.identifier, peripheral: p, sourceEpoch: transportEpoch, from: c)
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        _ = transport?.processCentralFailToConnect(peerId: p.identifier, error: error, peripheral: p, sourceEpoch: transportEpoch, from: c)
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        _ = transport?.processOutboundDisconnect(peerId: p.identifier, expectedGen: 0, peripheral: p, sourceEpoch: transportEpoch, from: c)
    }
}

public final class PeripheralManagerEpochDelegate: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    public let transportEpoch: UInt64
    public weak var transport: BleTransport?

    public init(transportEpoch: UInt64, transport: BleTransport) {
        self.transportEpoch = transportEpoch
        self.transport = transport
        super.init()
    }

    public func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        transport?.processPeripheralManagerDidUpdateState(pm, sourceEpoch: transportEpoch)
    }

    public func peripheralManager(_ pm: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        transport?.processPeripheralDidAddService(pm, service: service, error: error, sourceEpoch: transportEpoch)
    }

    public func peripheralManager(_ pm: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        transport?.processPeripheralWillRestoreState(pm, dict: dict, sourceEpoch: transportEpoch)
    }

    public func peripheralManager(_ pm: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        transport?.processPeripheralReceiveRead(pm, request: request, sourceEpoch: transportEpoch)
    }

    public func peripheralManager(_ pm: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        transport?.processPeripheralReceiveWrite(pm, requests: requests, sourceEpoch: transportEpoch)
    }

    public func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral, didSubscribeTo ch: CBCharacteristic) {
        transport?.processPeripheralDidSubscribe(pm, central: central, characteristic: ch, sourceEpoch: transportEpoch)
    }

    public func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom ch: CBCharacteristic) {
        transport?.processPeripheralDidUnsubscribe(pm, central: central, characteristic: ch, sourceEpoch: transportEpoch)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers pm: CBPeripheralManager) {
        transport?.processPeripheralIsReadyToUpdateSubscribers(pm, sourceEpoch: transportEpoch)
    }
}

public final class BleTransport: NSObject, @unchecked Sendable {

    public static let serviceUuid = CBUUID(string: FrameV2.serviceUuidString)
    // T10: every GATT identifier is the generated wire-contract value. The
    // historical hand-rolled FD short-form characteristic constants
    // (0000FD01/0000FD02) are the non-shipping legacy profile: removed,
    // never dual-registered, and rejected by RequiredCharacteristicSet's
    // provisioning gate. Aliases keep their established names.
    public static let inboxCharacteristicUuid = CBUUID(string: FrameV2.inboxUuidString)
    public static let digestCharacteristicUuid = CBUUID(string: FrameV2.digestUuidString)
    public static let linkInfoCharacteristicUuid = CBUUID(string: FrameV2.linkInfoUuidString)

    /// The one canonical profile; the server installs from it, the central
    /// resolves discovered trees against it.
    public static let meshProfile = RequiredCharacteristicSet.mesh

    /// The one platform mapping: contract entries to installable CoreBluetooth
    /// characteristics, generated as one data-driven pass over the profile.
    /// Every property set and permission mask derives from the contract, and
    /// the CCC descriptor travels with each notify-capable characteristic
    /// (attached by the system, as our Android server adds it explicitly).
    public static func characteristicsToInstall(_ set: RequiredCharacteristicSet) -> [CBMutableCharacteristic] {
        var installed: [CBMutableCharacteristic] = []
        for entry in set.characteristics {
            installed.append(CBMutableCharacteristic(
                type: entry.uuid,
                properties: RequiredCharacteristicSet.cbProperties(of: entry.properties),
                value: nil,
                permissions: RequiredCharacteristicSet.permissionsFor(entry.properties)
            ))
        }
        return installed
    }

    /// Inbound routing decision by uuid equality against the configured
    /// roles: LinkInfo records go to the link info store, never through the
    /// record decoder; frame records go to the record decoder; anything else
    /// is answered request-not-supported, including the legacy FD values.
    public static func classifyInbound(_ uuid: CBUUID) -> InboundRoute {
        if uuid.isEqual(linkInfoCharacteristicUuid) {
            return .toLinkInfo
        }
        if uuid.isEqual(inboxCharacteristicUuid) {
            return .toDeframer
        }
        return .notSupported
    }

    public static let maxActiveConnections = 7
    public static let maxDiscoveredPeers = 64
    public static let maxQueuedAttValues = 16
    public static let linkLayerReady = false

    public var isBulkCapable: Bool { false }
    public var name: String { "BLE" }

    public weak var delegate: TransportDelegate?
    public var roleCoordinator: BleRoleBindingCoordinator?

    public private(set) var centralDriver: BleCentralOrchestrationDriver?
    public private(set) var peripheralDriver: BlePeripheralOrchestrationDriver?
    public let capacityAuthority = BleGlobalCapacityAuthority()

    public private(set) var currentTransportEpoch: UInt64 = 0
    public private(set) var activeCentralEpochDelegate: CentralManagerEpochDelegate?
    public private(set) var activePeripheralEpochDelegate: PeripheralManagerEpochDelegate?

    private var activeOutboundLifetimes: [UUID: OutboundPhysicalLifetime] = [:]
    private var activeInboundLifetimes: [UUID: InboundSubscriptionLifetime] = [:]
    private var relationDelegates: [UUID: RelationPeripheralDelegate] = [:]

    private var activeManagerContext: ManagerContext?
    private var lastRetiredManagerContext: ManagerContext?
    private let managerFactory: TransportManagerFactory

    /// The pair of the active epoch, when one is open.
    private var central: CBCentralManager? {
        return activeManagerContext?.central
    }

    /// The pair of the active epoch, when one is open.
    private var peripheral: CBPeripheralManager? {
        return activeManagerContext?.peripheral
    }

    /// Test seam: the context of the active transport epoch, if any.
    public func currentManagerContextForTest() -> ManagerContext? {
        transportLock.lock()
        let value = activeManagerContext
        transportLock.unlock()
        return value
    }

    /// Test seam: the most recently retired context, kept so the
    /// late-callback cases can deliver through the very objects the
    /// previous epoch ran on.
    public func lastRetiredManagerContextForTest() -> ManagerContext? {
        transportLock.lock()
        let value = lastRetiredManagerContext
        transportLock.unlock()
        return value
    }

    /// Authenticates one manager-sourced event. The sending manager must
    /// be the very instance of the active context, the wired delegate must
    /// still be the context's own proxy, and the event must name the
    /// context's epoch. No token wildcard, no current-state stand-in:
    /// reassigning delegates on a reused manager proves nothing.
    /// The transport lock is held by the calling reducer.
    private func managerEventIsAuthenticLocked(
        sourceEpoch: UInt64,
        isCentral: Bool,
        sender: AnyObject?
    ) -> Bool {
        guard isStarted else { return false }
        guard let context = activeManagerContext else { return false }
        if context.isRetired {
            return false
        }
        guard sourceEpoch == context.epoch, context.epoch == currentTransportEpoch else { return false }
        guard let sender else { return false }
        let expectedManager: AnyObject = isCentral ? context.central : context.peripheral
        guard sender === expectedManager else { return false }
        let wired: AnyObject? = isCentral ? (context.central.delegate as AnyObject?) : (context.peripheral.delegate as AnyObject?)
        let proxy: AnyObject = isCentral ? context.centralProxy : context.peripheralProxy
        guard wired === proxy else { return false }
        return true
    }

    /// Test seam: the central manager of the open epoch context; the
    /// composition harness attributes its dispatched central events to it,
    /// so no event travels without naming its source instance.
    public func requireContextCentralForTest() -> CBCentralManager {
        transportLock.lock()
        let value = activeManagerContext?.central ?? lastRetiredManagerContext?.central
        transportLock.unlock()
        precondition(value != nil, "no transport epoch has ever opened on this instance: start the transport before dispatching manager-sourced events")
        return value!
    }

    /// Test seam: the peripheral manager of the open epoch context.
    public func requireContextPeripheralForTest() -> CBPeripheralManager {
        transportLock.lock()
        let value = activeManagerContext?.peripheral ?? lastRetiredManagerContext?.peripheral
        transportLock.unlock()
        precondition(value != nil, "no transport epoch has ever opened on this instance: start the transport before dispatching manager-sourced events")
        return value!
    }

    /// Test seam: deliver the authentication decision the reducer makes for
    /// one manager-sourced event, so the suite can pin refusals directly.
    public func managerEventIsAuthenticForTest(
        sourceEpoch: UInt64,
        isCentral: Bool,
        sender: AnyObject?
    ) -> Bool {
        transportLock.lock()
        let value = managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: isCentral,
            sender: sender
        )
        transportLock.unlock()
        return value
    }

    private var isStarted = false
    private var isBackgrounded = false
    private var isServiceRegistered = false

    private var mutableInboxCharacteristic: CBMutableCharacteristic?
    private var mutableLinkInfoCharacteristic: CBMutableCharacteristic?

    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private var inboxCharacteristics: [UUID: CBCharacteristic] = [:]
    private var digestCharacteristics: [UUID: CBCharacteristic] = [:]
    private var linkInfoCharacteristics: [UUID: CBCharacteristic] = [:]
    private var pendingInitiatorRemoteHints: [UUID: Data] = [:]
    private var subscribedCentrals: [UUID: CBCentral] = [:]

    var outboundCentralConnections: [UUID: BleConnection] = [:]
    var inboundPeripheralConnections: [UUID: BleConnection] = [:]

    private var provisionalTimers: [UUID: Timer] = [:]
    private var inboundTimers: [UUID: Timer] = [:]

    private var publishedRelations: Set<RelationKey> = []
    private var discoveredPeers: [UUID: BleDiscoveryMetadata] = [:]
    private var pendingOutboundWrites: [UUID: [Data]] = [:]
    private var pendingOutboundUpdates: [UUID: [Data]] = [:]

    private let transportLock = NSLock()
    public var identity: MeshIdentity? {
        didSet {
            refreshLocalLinkInfoSnapshotSync()
        }
    }
    public var store: MessageStore? {
        didSet {
            refreshLocalLinkInfoSnapshotSync()
        }
    }
    public var sessions: SessionManager?
    public private(set) var snapshotAuthority: LinkInfoSnapshotAuthority!
    private let provisionalTimeoutSeconds: TimeInterval

    public init(
        identity: MeshIdentity? = nil,
        store: MessageStore? = nil,
        sessions: SessionManager? = nil,
        provisionalTimeoutSeconds: TimeInterval = 10.0,
        managerFactory: TransportManagerFactory? = nil
    ) {
        self.identity = identity
        self.store = store
        self.sessions = sessions
        self.provisionalTimeoutSeconds = provisionalTimeoutSeconds
        self.managerFactory = managerFactory ?? DefaultTransportManagerFactory()
        super.init()
        self.snapshotAuthority = LinkInfoSnapshotAuthority(
            identityProvider: { [weak self] in self?.identity },
            storeProvider: { [weak self] in self?.store }
        )
    }

    public func getOutboundLifetime(_ peerId: UUID) -> OutboundPhysicalLifetime? {
        transportLock.lock()
        defer { transportLock.unlock() }
        return activeOutboundLifetimes[peerId]
    }

    public func getInboundLifetime(_ centralId: UUID) -> InboundSubscriptionLifetime? {
        transportLock.lock()
        defer { transportLock.unlock() }
        return activeInboundLifetimes[centralId]
    }

    public func getSubscribedCentral(_ id: UUID) -> CBCentral? {
        transportLock.lock()
        defer { transportLock.unlock() }
        return subscribedCentrals[id]
    }

    public func getRelationDelegate(_ peerId: UUID) -> RelationPeripheralDelegate? {
        transportLock.lock()
        defer { transportLock.unlock() }
        return relationDelegates[peerId]
    }

    func getLocalLinkInfoDataLocked() -> Data? {
        return snapshotAuthority.currentData()
    }

    public func getLocalLinkInfoData() -> Data? {
        return snapshotAuthority.currentData()
    }

    public func refreshLocalLinkInfoSnapshotSync() {
        _ = snapshotAuthority.refresh()
    }

    public func start() {
        transportLock.lock()
        guard !isStarted else {
            transportLock.unlock()
            return
        }
        currentTransportEpoch += 1
        // T13: the epoch opens with a fresh pair on a dedicated serial
        // queue, wired to its own proxies at birth. Reassigning delegates
        // on a reused manager is not the design: nothing here touches a
        // manager that a previous epoch already saw.
        #if !os(macOS)
        let restoresState = !ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("XCTest") })
        #else
        let restoresState = false
        #endif
        let context = ManagerContext(
            epoch: currentTransportEpoch,
            transport: self,
            factory: managerFactory,
            restoresState: restoresState
        )
        activeManagerContext = context
        activeCentralEpochDelegate = context.centralProxy
        activePeripheralEpochDelegate = context.peripheralProxy

        let localHint = identity?.nodeHint ?? Data(repeating: 0, count: BleRoleElection.nodeHintBytes)
        centralDriver = BleCentralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { [weak self] in self?.getLocalLinkInfoData() },
            capacityAuthority: capacityAuthority
        )
        _ = centralDriver?.startNewTransportEpoch(currentTransportEpoch)
        peripheralDriver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { [weak self] in self?.getLocalLinkInfoData() },
            capacityAuthority: capacityAuthority
        )
        _ = peripheralDriver?.startNewTransportEpoch(currentTransportEpoch)
        activeOutboundLifetimes.removeAll()
        activeInboundLifetimes.removeAll()
        relationDelegates.removeAll()
        isStarted = true
        let canAdv = isServiceRegistered && (peripheral?.state == .poweredOn)
        transportLock.unlock()

        if canAdv {
            startAdvertising()
        }
        startScanning()
    }

    public func stop() {
        transportLock.lock()
        guard isStarted else {
            transportLock.unlock()
            return
        }
        // FIRST: Invalidate active transport epoch
        isStarted = false
        currentTransportEpoch += 1
        // T13: the closing epoch retires its pair. The objects leave the
        // stage as they came; the next opening creates fresh ones.
        if let context = activeManagerContext {
            context.retire()
            lastRetiredManagerContext = context
        }
        activeManagerContext = nil
        activeCentralEpochDelegate = nil
        activePeripheralEpochDelegate = nil
        #if !os(macOS)
        central?.delegate = nil
        peripheral?.delegate = nil
        #endif

        central?.stopScan()
        peripheral?.stopAdvertising()

        for (_, timer) in provisionalTimers {
            timer.invalidate()
        }
        provisionalTimers.removeAll()

        for (_, timer) in inboundTimers {
            timer.invalidate()
        }
        inboundTimers.removeAll()

        for (_, p) in connectedPeripherals {
            central?.cancelPeripheralConnection(p)
        }
        connectedPeripherals.removeAll()
        inboxCharacteristics.removeAll()
        digestCharacteristics.removeAll()
        linkInfoCharacteristics.removeAll()
        pendingInitiatorRemoteHints.removeAll()
        subscribedCentrals.removeAll()

        for (_, conn) in outboundCentralConnections {
            conn.markDisconnected()
        }
        outboundCentralConnections.removeAll()

        for (_, conn) in inboundPeripheralConnections {
            conn.markDisconnected()
        }
        inboundPeripheralConnections.removeAll()

        _ = centralDriver?.startNewTransportEpoch(currentTransportEpoch)
        _ = peripheralDriver?.startNewTransportEpoch(currentTransportEpoch)
        activeOutboundLifetimes.removeAll()
        activeInboundLifetimes.removeAll()
        relationDelegates.removeAll()
        centralDriver?.reset()
        peripheralDriver?.reset()
        capacityAuthority.reset()

        publishedRelations.removeAll()
        discoveredPeers.removeAll()
        pendingOutboundWrites.removeAll()
        pendingOutboundUpdates.removeAll()
        transportLock.unlock()
    }

    private func startScanning() {
        guard let central = central, central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [BleTransport.serviceUuid],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: !isBackgrounded]
        )
    }

    private func startAdvertising() {
        guard let peripheral = peripheral, peripheral.state == .poweredOn, isServiceRegistered else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BleTransport.serviceUuid]
        ])
    }

    public func setBackgrounded(_ backgrounded: Bool) {
        transportLock.lock()
        defer { transportLock.unlock() }
        isBackgrounded = backgrounded
        central?.stopScan()
        startScanning()
    }

    public func connection(for peerId: UUID) -> BleConnection? {
        transportLock.lock()
        defer { transportLock.unlock() }
        return outboundCentralConnections[peerId] ?? inboundPeripheralConnections[peerId]
    }

    public func discoveryMetadata(for peerId: UUID) -> BleDiscoveryMetadata? {
        transportLock.lock()
        defer { transportLock.unlock() }
        return discoveredPeers[peerId]
    }

    public func setMutableInboxCharacteristicForTesting(_ char: CBMutableCharacteristic?) {
        transportLock.lock()
        defer { transportLock.unlock() }
        mutableInboxCharacteristic = char
    }

    private func purgeCentralConnection(peerId: UUID, cancelPeripheral: Bool) {
        let gen = centralDriver?.getConnectionGeneration(peerId) ?? 0
        transportLock.lock()
        provisionalTimers.removeValue(forKey: peerId)?.invalidate()
        inboxCharacteristics.removeValue(forKey: peerId)
        digestCharacteristics.removeValue(forKey: peerId)
        linkInfoCharacteristics.removeValue(forKey: peerId)
        pendingInitiatorRemoteHints.removeValue(forKey: peerId)
        pendingOutboundWrites.removeValue(forKey: peerId)
        let periph = connectedPeripherals.removeValue(forKey: peerId)
        let conn = outboundCentralConnections.removeValue(forKey: peerId)
        conn?.markDisconnected()
        _ = centralDriver?.onProvisionalTimeout(peerId: peerId, expectedGen: gen)
        transportLock.unlock()

        if cancelPeripheral, let p = periph {
            central?.cancelPeripheralConnection(p)
        }
        let key = RelationKey(direction: .outboundCentral, peerId: peerId, generation: gen)
        unpublishRelation(key)
    }

    @discardableResult
    public func send(_ frame: FrameV2, to peerId: UUID) -> Bool {
        transportLock.lock()
        let conn = outboundCentralConnections[peerId] ?? inboundPeripheralConnections[peerId]
        guard let connection = conn, connection.state == .ready else {
            transportLock.unlock()
            return false
        }
        let sealedPayload = sessions?.seal(peerId, frame.encode()) ?? (sessions == nil ? frame.encode() : nil)
        guard let sealed = sealedPayload else {
            transportLock.unlock()
            return false
        }

        let fragments = connection.fragmentOutbound(recordType: .data, payload: sealed)
        guard !fragments.isEmpty else {
            transportLock.unlock()
            return false
        }

        if connection.localRole == .initiator {
            guard let p = connectedPeripherals[peerId],
                  let ch = inboxCharacteristics[peerId] else {
                transportLock.unlock()
                return false
            }

            var queue = pendingOutboundWrites[peerId] ?? []
            if !queue.isEmpty {
                if queue.count + fragments.count > BleTransport.maxQueuedAttValues {
                    transportLock.unlock()
                    return false
                }
                queue.append(contentsOf: fragments)
                pendingOutboundWrites[peerId] = queue
                transportLock.unlock()
                return true
            }

            var remaining: [Data] = []
            var idx = 0
            while idx < fragments.count {
                let frag = fragments[idx]
                if p.canSendWriteWithoutResponse {
                    p.writeValue(frag, for: ch, type: .withoutResponse)
                    idx += 1
                } else {
                    remaining = Array(fragments[idx...])
                    break
                }
            }

            if !remaining.isEmpty {
                if queue.count + remaining.count > BleTransport.maxQueuedAttValues {
                    transportLock.unlock()
                    return false
                }
                queue.append(contentsOf: remaining)
                pendingOutboundWrites[peerId] = queue
            }
            transportLock.unlock()
            return true
        } else {
            guard let centralObj = subscribedCentrals[peerId],
                  let inboxChar = mutableInboxCharacteristic else {
                transportLock.unlock()
                return false
            }

            var queue = pendingOutboundUpdates[peerId] ?? []
            for frag in fragments {
                if !queue.isEmpty {
                    if queue.count >= BleTransport.maxQueuedAttValues {
                        transportLock.unlock()
                        return false
                    }
                    queue.append(frag)
                } else {
                    let ok = peripheral?.updateValue(frag, for: inboxChar, onSubscribedCentrals: [centralObj]) ?? false
                    if !ok {
                        queue.append(frag)
                    }
                }
            }

            if queue.isEmpty {
                pendingOutboundUpdates.removeValue(forKey: peerId)
            } else {
                pendingOutboundUpdates[peerId] = queue
            }
            transportLock.unlock()
            return true
        }
    }

    @discardableResult
    public func publishRelation(_ key: RelationKey) -> Bool {
        transportLock.lock()
        let hadAny = publishedRelations.contains(where: { $0.peerId == key.peerId })
        let (inserted, _) = publishedRelations.insert(key)
        transportLock.unlock()
        if inserted && !hadAny {
            delegate?.transportPhysicalDuplexReady(peerId: key.peerId)
            delegate?.transportDidConnect(peerId: key.peerId)
            return true
        }
        return false
    }

    @discardableResult
    public func unpublishRelation(_ key: RelationKey) -> Bool {
        transportLock.lock()
        let hadAny = publishedRelations.contains(where: { $0.peerId == key.peerId })
        let removed = publishedRelations.remove(key) != nil
        let hasRemaining = publishedRelations.contains(where: { $0.peerId == key.peerId })
        transportLock.unlock()
        if removed && hadAny && !hasRemaining {
            delegate?.transportDidDisconnect(peerId: key.peerId)
            return true
        }
        return false
    }

    public func processOutboundDiscover(
        peerId: UUID,
        rssi: Int = -60,
        serviceDataHint: Data? = nil,
        peripheral: CBPeripheral? = nil,
        sourceEpoch: UInt64, from manager: CBCentralManager
    ) -> BleCentralAction {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: manager
        ) else {
            transportLock.unlock()
            return .noOp
        }
        guard let driver = centralDriver else {
            transportLock.unlock()
            return .noOp
        }
        transportLock.unlock()

        let action = driver.onDiscover(peerId: peerId, rssi: rssi, serviceDataHint: serviceDataHint)
        if case .connectPeripheral(let pid) = action {
            transportLock.lock()
            let gen = driver.getConnectionGeneration(pid)
            let key = RelationKey(direction: .outboundCentral, peerId: pid, generation: gen)
            let lifetime = OutboundPhysicalLifetime(relationKey: key, transportEpoch: currentTransportEpoch, peripheral: peripheral)
            let proxy = RelationPeripheralDelegate(relationKey: key, transportEpoch: currentTransportEpoch, transport: self)
            activeOutboundLifetimes[pid] = lifetime
            relationDelegates[pid] = proxy
            if let p = peripheral {
                connectedPeripherals[pid] = p
                p.delegate = proxy
            }
            let conn = driver.getActiveConnection(pid) ?? BleConnection(peerId: pid)
            outboundCentralConnections[pid] = conn

            let timer = Timer(timeInterval: provisionalTimeoutSeconds, repeats: false) { [weak self] _ in
                _ = self?.handleOutboundTimeout(peerId: pid, generation: gen)
            }
            RunLoop.main.add(timer, forMode: .common)
            provisionalTimers[pid] = timer
            transportLock.unlock()
        }
        return action
    }

    public func processCentralConnect(peerId: UUID, peripheral: CBPeripheral? = nil, sourceEpoch: UInt64, from manager: CBCentralManager) -> BleCentralAction {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: manager
        ) else {
            transportLock.unlock()
            return .noOp
        }
        guard let lifetime = activeOutboundLifetimes[peerId], (sourceEpoch == 0 || lifetime.transportEpoch == sourceEpoch) else {
            transportLock.unlock()
            return .noOp
        }
        if let p = peripheral, let installedP = lifetime.peripheral, installedP !== p {
            transportLock.unlock()
            return .noOp
        }
        transportLock.unlock()
        let action = centralDriver?.onConnected(peerId: peerId) ?? .noOp
        if case .discoverServices = action {
            if let p = peripheral ?? lifetime.peripheral {
                p.discoverServices([BleTransport.serviceUuid])
            }
        }
        return action
    }

    public func processCentralFailToConnect(peerId: UUID, error: Error? = nil, peripheral: CBPeripheral? = nil, sourceEpoch: UInt64, from manager: CBCentralManager) -> BleCentralAction {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: manager
        ) else {
            transportLock.unlock()
            return .noOp
        }
        guard let lifetime = activeOutboundLifetimes[peerId], (sourceEpoch == 0 || lifetime.transportEpoch == sourceEpoch) else {
            transportLock.unlock()
            return .noOp
        }
        if let p = peripheral, let installedP = lifetime.peripheral, installedP !== p {
            transportLock.unlock()
            return .noOp
        }
        let key = lifetime.relationKey
        activeOutboundLifetimes.removeValue(forKey: peerId)
        relationDelegates.removeValue(forKey: peerId)
        provisionalTimers.removeValue(forKey: peerId)?.invalidate()
        let conn = outboundCentralConnections.removeValue(forKey: peerId)
        conn?.markDisconnected()
        connectedPeripherals.removeValue(forKey: peerId)
        inboxCharacteristics.removeValue(forKey: peerId)
        digestCharacteristics.removeValue(forKey: peerId)
        linkInfoCharacteristics.removeValue(forKey: peerId)
        pendingInitiatorRemoteHints.removeValue(forKey: peerId)
        pendingOutboundWrites.removeValue(forKey: peerId)
        transportLock.unlock()

        let action = centralDriver?.onFailedToConnect(peerId: peerId, error: error) ?? .noOp
        unpublishRelation(key)
        return action
    }

    public func processOutboundDisconnect(peerId: UUID, expectedGen: UInt64, peripheral: CBPeripheral? = nil, sourceEpoch: UInt64, from manager: CBCentralManager) -> BleCentralAction {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: manager
        ) else {
            transportLock.unlock()
            return .noOp
        }
        guard let lifetime = activeOutboundLifetimes[peerId], (sourceEpoch == 0 || lifetime.transportEpoch == sourceEpoch) else {
            transportLock.unlock()
            return .noOp
        }
        if let p = peripheral, let installedP = lifetime.peripheral, installedP !== p {
            transportLock.unlock()
            return .noOp
        }
        let key = lifetime.relationKey
        if expectedGen != 0 && key.generation != expectedGen {
            transportLock.unlock()
            return .noOp
        }
        activeOutboundLifetimes.removeValue(forKey: peerId)
        relationDelegates.removeValue(forKey: peerId)
        provisionalTimers.removeValue(forKey: peerId)?.invalidate()
        outboundCentralConnections.removeValue(forKey: peerId)?.markDisconnected()
        connectedPeripherals.removeValue(forKey: peerId)
        inboxCharacteristics.removeValue(forKey: peerId)
        digestCharacteristics.removeValue(forKey: peerId)
        linkInfoCharacteristics.removeValue(forKey: peerId)
        pendingInitiatorRemoteHints.removeValue(forKey: peerId)
        pendingOutboundWrites.removeValue(forKey: peerId)
        transportLock.unlock()

        let action = centralDriver?.onDisconnected(peerId: peerId, expectedGen: key.generation) ?? .noOp
        unpublishRelation(key)
        return action
    }

    public func validateOutboundDelegate(_ delegate: RelationPeripheralDelegate, peerId: UUID) -> Bool {
        transportLock.lock()
        defer { transportLock.unlock() }
        guard delegate.transportEpoch == currentTransportEpoch else { return false }
        guard let lifetime = activeOutboundLifetimes[peerId] else { return false }
        return lifetime.transportEpoch == currentTransportEpoch && lifetime.relationKey == delegate.relationKey
    }

    public func processPeripheralDiscoverServices(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, error: Error? = nil) -> BleCentralAction {
        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return .noOp }
        let success = (error == nil && ((p?.services?.contains(where: { $0.uuid == BleTransport.serviceUuid })) ?? true))
        let action = centralDriver?.onServicesDiscovered(peerId: peerId, success: success) ?? .noOp
        switch action {
        case .discoverCharacteristics:
            if let p = p {
                for s in p.services ?? [] where s.uuid == BleTransport.serviceUuid {
                    p.discoverCharacteristics(
                        [BleTransport.inboxCharacteristicUuid, BleTransport.digestCharacteristicUuid, BleTransport.linkInfoCharacteristicUuid],
                        for: s
                    )
                }
            }
        case .disconnectPeripheral:
            purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
        default: break
        }
        return action
    }

    public func processPeripheralDiscoverCharacteristics(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, service: CBService, error: Error? = nil) -> BleCentralAction {
        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return .noOp }
        var tree: [ContractCharacteristic] = []
        for ch in service.characteristics ?? [] {
            tree.append(ContractCharacteristic(uuid: ch.uuid, properties: RequiredCharacteristicSet.propertiesOf(ch.properties)))
        }
        transportLock.lock()
        for ch in service.characteristics ?? [] {
            if ch.uuid == BleTransport.inboxCharacteristicUuid {
                inboxCharacteristics[peerId] = ch
            } else if ch.uuid == BleTransport.digestCharacteristicUuid {
                digestCharacteristics[peerId] = ch
            } else if ch.uuid == BleTransport.linkInfoCharacteristicUuid {
                linkInfoCharacteristics[peerId] = ch
            }
        }
        let linkInfoChar = linkInfoCharacteristics[peerId]
        transportLock.unlock()

        // T10 provisioning gate: resolve the whole discovered tree against
        // the canonical profile -- all three roles exactly once, with their
        // required properties and nothing beyond the contract -- instead of
        // spot-checking the one characteristic this client happens to read.
        let success = (error == nil && BleTransport.meshProfile.accepts(tree))
        let action = centralDriver?.onCharacteristicsDiscovered(peerId: peerId, success: success) ?? .noOp
        switch action {
        case .readLinkInfo:
            if let ch = linkInfoChar, let p = p {
                p.readValue(for: ch)
            }
        case .disconnectPeripheral:
            purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
        default: break
        }
        return action
    }

    public func processPeripheralUpdateValue(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, characteristic: CBCharacteristic, error: Error? = nil) -> BleCentralAction {
        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return .noOp }

        if characteristic.uuid == BleTransport.linkInfoCharacteristicUuid {
            let success = (error == nil)
            let action = centralDriver?.onLinkInfoReadResult(peerId: peerId, success: success, rawData: characteristic.value) ?? .noOp
            switch action {
            case .writeLinkInfo(_, let localData, let remoteHint):
                transportLock.lock()
                pendingInitiatorRemoteHints[peerId] = remoteHint
                transportLock.unlock()
                p?.writeValue(localData, for: characteristic, type: .withResponse)
            case .disconnectPeripheral:
                purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
            default: break
            }
            return action
        }

        if characteristic.uuid == BleTransport.inboxCharacteristicUuid {
            transportLock.lock()
            guard let conn = outboundCentralConnections[peerId], conn.isRoleBound else {
                transportLock.unlock()
                return .noOp
            }
            guard let record = conn.ingestInboundAttValue(characteristic.value ?? Data()) else {
                transportLock.unlock()
                return .noOp
            }
            transportLock.unlock()

            if record.recordType == .data && conn.state == .ready {
                if let clear = sessions?.open(peerId, record.payload) {
                    self.delegate?.transportDidReceive(data: clear, peerId: peerId)
                }
            }
        }
        return .noOp
    }

    public func processPeripheralWriteValue(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, characteristic: CBCharacteristic, error: Error? = nil) -> BleCentralAction {
        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return .noOp }

        if characteristic.uuid == BleTransport.linkInfoCharacteristicUuid {
            transportLock.lock()
            let remoteHint = pendingInitiatorRemoteHints.removeValue(forKey: peerId)
            transportLock.unlock()

            let action = centralDriver?.onLinkInfoWriteAcknowledged(
                peerId: peerId,
                success: (error == nil),
                remoteHint: remoteHint ?? Data()
            ) ?? .noOp

            switch action {
            case .setNotify:
                transportLock.lock()
                if let inboxChar = inboxCharacteristics[peerId] {
                    let maxWrite = p?.maximumWriteValueLength(for: .withoutResponse) ?? 512
                    outboundCentralConnections[peerId]?.markConnected(negotiatedAttValueLength: maxWrite)
                    p?.setNotifyValue(true, for: inboxChar)
                }
                transportLock.unlock()
            case .disconnectPeripheral:
                purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
            default: break
            }
            return action
        }
        return .noOp
    }

    public func processPeripheralNotificationStateUpdated(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, characteristic: CBCharacteristic, error: Error? = nil) -> BleCentralAction {
        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return .noOp }

        if characteristic.uuid == BleTransport.inboxCharacteristicUuid {
            let success = (error == nil)
            let action = centralDriver?.onNotificationStateUpdated(peerId: peerId, success: success, isNotifying: characteristic.isNotifying) ?? .noOp
            switch action {
            case .physicalDuplexReady:
                transportLock.lock()
                provisionalTimers.removeValue(forKey: peerId)?.invalidate()
                transportLock.unlock()
                publishRelation(delegate.relationKey)
            case .disconnectPeripheral:
                purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
            default: break
            }
            return action
        }
        return .noOp
    }

    public func processPeripheralIsReady(_ p: CBPeripheral, delegate: RelationPeripheralDelegate) {
        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return }
        transportLock.lock()
        defer { transportLock.unlock() }
        guard isStarted, delegate.transportEpoch == currentTransportEpoch else { return }
        guard let ch = inboxCharacteristics[peerId] else { return }

        var queue = pendingOutboundWrites[peerId] ?? []
        while !queue.isEmpty && p.canSendWriteWithoutResponse {
            let item = queue.removeFirst()
            p.writeValue(item, for: ch, type: .withoutResponse)
        }

        if queue.isEmpty {
            pendingOutboundWrites.removeValue(forKey: peerId)
        } else {
            pendingOutboundWrites[peerId] = queue
        }
    }

    public func handleOutboundTimeout(peerId: UUID, generation: UInt64 = 0) -> BleCentralAction {
        guard let driver = centralDriver else { return .noOp }
        transportLock.lock()
        provisionalTimers.removeValue(forKey: peerId)?.invalidate()
        transportLock.unlock()
        let currentGen = driver.getConnectionGeneration(peerId)
        if generation != 0 && currentGen != generation {
            return .noOp
        }
        if driver.isPhysicalReady(peerId) {
            return .noOp
        }
        let effectiveGen = (generation != 0) ? generation : currentGen
        let action = driver.onProvisionalTimeout(peerId: peerId, expectedGen: effectiveGen)
        transportLock.lock()
        activeOutboundLifetimes.removeValue(forKey: peerId)
        relationDelegates.removeValue(forKey: peerId)
        let p = connectedPeripherals.removeValue(forKey: peerId)
        outboundCentralConnections.removeValue(forKey: peerId)?.markDisconnected()
        inboxCharacteristics.removeValue(forKey: peerId)
        digestCharacteristics.removeValue(forKey: peerId)
        linkInfoCharacteristics.removeValue(forKey: peerId)
        pendingInitiatorRemoteHints.removeValue(forKey: peerId)
        pendingOutboundWrites.removeValue(forKey: peerId)
        transportLock.unlock()
        if let p = p {
            central?.cancelPeripheralConnection(p)
        }
        let key = RelationKey(direction: .outboundCentral, peerId: peerId, generation: effectiveGen)
        unpublishRelation(key)
        return action
    }

    public func decideInboundWriteAttResponse(action: BlePeripheralAction) -> CBATTError.Code {
        switch action {
        case .acceptWrite, .acceptDuplicateWrite, .acceptWriteAndDuplexReady:
            return .success
        default:
            return .unlikelyError
        }
    }

    public func processInboundWrite(centralId: UUID, rawData: Data, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: manager
        ) else {
            transportLock.unlock()
            return .rejectWrite(centralId, "Transport not started or stale epoch")
        }
        guard let driver = peripheralDriver else {
            transportLock.unlock()
            return .noOp
        }
        transportLock.unlock()

        let action = driver.onCentralWrite(centralId: centralId, rawData: rawData)
        switch action {
        case .acceptWrite(let cid, let remoteHint),
             .acceptWriteAndDuplexReady(let cid, let remoteHint):
            transportLock.lock()
            let gen = driver.getCentralGeneration(cid)
            let key = RelationKey(direction: .inboundPeripheral, peerId: cid, generation: gen)
            activeInboundLifetimes[cid] = InboundSubscriptionLifetime(relationKey: key, transportEpoch: currentTransportEpoch)

            if inboundPeripheralConnections[cid] == nil {
                inboundPeripheralConnections[cid] = driver.getInboundConnection(cid)
            }
            if let conn = inboundPeripheralConnections[cid], !conn.isRoleBound {
                conn.bindResponderFromAcceptedIncomingLinkInfo(remoteHint: remoteHint)
            }
            if inboundTimers[cid] == nil {
                let timer = Timer(timeInterval: provisionalTimeoutSeconds, repeats: false) { [weak self] _ in
                    self?.handleInboundTimeout(centralId: cid, generation: gen)
                }
                RunLoop.main.add(timer, forMode: .common)
                inboundTimers[cid] = timer
            }
            transportLock.unlock()
            if case .acceptWriteAndDuplexReady = action {
                publishRelation(key)
            }
        case .acceptDuplicateWrite:
            // Exact duplicate write: idempotent, does not allocate timer or change state
            break
        default:
            break
        }
        return action
    }

    public func processInboundSubscribe(centralId: UUID, central: CBCentral? = nil, maxUpdateLength: Int = 512, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: manager
        ) else {
            transportLock.unlock()
            return .noOp
        }
        guard let driver = peripheralDriver else {
            transportLock.unlock()
            return .noOp
        }
        transportLock.unlock()

        let action = driver.onCentralSubscribed(centralId: centralId)
        switch action {
        case .acceptSubscription(let cid), .acceptSubscriptionAndDuplexReady(let cid):
            transportLock.lock()
            inboundTimers.removeValue(forKey: cid)?.invalidate()
            if let c = central {
                subscribedCentrals[cid] = c
            }
            if inboundPeripheralConnections[cid] == nil {
                inboundPeripheralConnections[cid] = driver.getInboundConnection(cid)
            }
            if let conn = inboundPeripheralConnections[cid] {
                conn.markConnected(negotiatedAttValueLength: maxUpdateLength)
            }
            let key = activeInboundLifetimes[cid]?.relationKey ?? RelationKey(direction: .inboundPeripheral, peerId: cid, generation: driver.getCentralGeneration(cid))
            transportLock.unlock()
            if case .acceptSubscriptionAndDuplexReady = action {
                publishRelation(key)
            }
        default:
            break
        }
        return action
    }

    public func processInboundUnsubscribe(centralId: UUID, expectedGen: UInt64, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        guard let driver = peripheralDriver else { return .noOp }
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: manager
        ) else {
            transportLock.unlock()
            return .noOp
        }
        guard let lifetime = activeInboundLifetimes[centralId], (sourceEpoch == 0 || lifetime.transportEpoch == sourceEpoch) else {
            transportLock.unlock()
            return .noOp
        }
        let key = lifetime.relationKey
        if expectedGen != 0 && key.generation != expectedGen {
            transportLock.unlock()
            return .noOp
        }
        activeInboundLifetimes.removeValue(forKey: centralId)
        inboundTimers.removeValue(forKey: centralId)?.invalidate()
        inboundPeripheralConnections.removeValue(forKey: centralId)?.markDisconnected()
        subscribedCentrals.removeValue(forKey: centralId)
        pendingOutboundUpdates.removeValue(forKey: centralId)
        transportLock.unlock()

        let action = driver.onCentralUnsubscribed(centralId: centralId, expectedGen: key.generation)
        unpublishRelation(key)
        return action
    }

    public func handleInboundTimeout(centralId: UUID, generation: UInt64 = 0) {
        guard let driver = peripheralDriver else { return }
        transportLock.lock()
        inboundTimers.removeValue(forKey: centralId)?.invalidate()
        transportLock.unlock()
        let currentGen = driver.getCentralGeneration(centralId)
        if generation != 0 && currentGen != generation {
            return
        }
        if generation != 0 && driver.isPhysicalReady(centralId) {
            return
        }
        let effectiveGen = (generation != 0) ? generation : currentGen
        driver.onInboundTimeout(centralId: centralId, expectedGen: effectiveGen)
        transportLock.lock()
        activeInboundLifetimes.removeValue(forKey: centralId)
        inboundPeripheralConnections.removeValue(forKey: centralId)?.markDisconnected()
        subscribedCentrals.removeValue(forKey: centralId)
        pendingOutboundUpdates.removeValue(forKey: centralId)
        transportLock.unlock()
        let key = RelationKey(direction: .inboundPeripheral, peerId: centralId, generation: effectiveGen)
        unpublishRelation(key)
    }

    public func dispatchReceiveRead(centralId: UUID) -> BlePeripheralAction {
        return peripheralDriver?.onCentralRead(centralId: centralId) ?? .noOp
    }

    public func dispatchReceiveWrite(centralId: UUID, rawData: Data, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        return processInboundWrite(centralId: centralId, rawData: rawData, sourceEpoch: sourceEpoch, from: manager)
    }

    public func dispatchSubscribe(centralId: UUID, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        return processInboundSubscribe(centralId: centralId, sourceEpoch: sourceEpoch, from: manager)
    }

    public func dispatchUnsubscribe(centralId: UUID, expectedGen: UInt64, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        return processInboundUnsubscribe(centralId: centralId, expectedGen: expectedGen, sourceEpoch: sourceEpoch, from: manager)
    }

    public func dispatchOutboundProvisionalTimeout(peerId: UUID, expectedGen: UInt64 = 0) -> BleCentralAction {
        return handleOutboundTimeout(peerId: peerId, generation: expectedGen)
    }

    public func dispatchInboundTimeout(centralId: UUID, expectedGen: UInt64 = 0) {
        handleInboundTimeout(centralId: centralId, generation: expectedGen)
    }

    public func isRelationPublished(direction: BleDirection, peerId: UUID, generation: UInt64 = 0) -> Bool {
        transportLock.lock()
        defer { transportLock.unlock() }
        if generation != 0 {
            return publishedRelations.contains(RelationKey(direction: direction, peerId: peerId, generation: generation))
        }
        return publishedRelations.contains(where: { $0.direction == direction && $0.peerId == peerId })
    }

    public func processCentralDidUpdateState(_ c: CBCentralManager, sourceEpoch: UInt64) {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: c
        ) else {
            transportLock.unlock()
            return
        }
        let shouldScan = (c.state == .poweredOn)
        transportLock.unlock()
        if shouldScan {
            startScanning()
        }
    }

    public func processCentralWillRestoreState(_ c: CBCentralManager, dict: [String: Any], sourceEpoch: UInt64) {
        transportLock.lock()
        defer { transportLock.unlock() }
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: c
        ) else { return }
        if let peers = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for p in peers {
                connectedPeripherals[p.identifier] = p
            }
        }
    }

    public func processCentralDidDiscover(
        _ c: CBCentralManager,
        peripheral p: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber,
        sourceEpoch: UInt64
    ) {
        guard RSSI.intValue > -90 else { return }

        var metaHint: Data? = nil
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: c
        ) else {
            transportLock.unlock()
            return
        }
        if let serviceDataDict = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           let rawPayload = serviceDataDict[BleTransport.serviceUuid],
           rawPayload.count == BleLinkInfoConstants.linkInfoBytes,
           let meta = BleLinkInfoCodec.decode(rawPayload) {
            if discoveredPeers.count >= BleTransport.maxDiscoveredPeers && discoveredPeers[p.identifier] == nil {
                if let oldest = discoveredPeers.keys.first {
                    discoveredPeers.removeValue(forKey: oldest)
                }
            }
            discoveredPeers[p.identifier] = meta
            metaHint = meta.nodeHint
        }
        transportLock.unlock()

        let action = processOutboundDiscover(peerId: p.identifier, rssi: RSSI.intValue, serviceDataHint: metaHint, peripheral: p, sourceEpoch: sourceEpoch, from: c)
        if case .connectPeripheral = action {
            c.connect(p, options: nil)
        }
    }

    public func processPeripheralManagerDidUpdateState(_ pm: CBPeripheralManager, sourceEpoch: UInt64) {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            transportLock.unlock()
            return
        }
        guard pm.state == .poweredOn else {
            transportLock.unlock()
            return
        }
        transportLock.unlock()

        let installed = BleTransport.characteristicsToInstall(BleTransport.meshProfile)
        let service = CBMutableService(type: BleTransport.meshProfile.serviceUuid, primary: true)
        service.characteristics = installed
        pm.add(service)

        transportLock.lock()
        mutableInboxCharacteristic = installed.first { $0.uuid == BleTransport.inboxCharacteristicUuid }
        mutableLinkInfoCharacteristic = installed.first { $0.uuid == BleTransport.linkInfoCharacteristicUuid }
        transportLock.unlock()
    }

    public func processPeripheralDidAddService(_ pm: CBPeripheralManager, service: CBService, error: Error?, sourceEpoch: UInt64) {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            transportLock.unlock()
            return
        }
        if error == nil && service.uuid == BleTransport.serviceUuid {
            isServiceRegistered = true
        }
        let shouldAdv = isStarted && isServiceRegistered
        transportLock.unlock()

        if shouldAdv {
            startAdvertising()
        }
    }

    public func processPeripheralWillRestoreState(_ pm: CBPeripheralManager, dict: [String: Any], sourceEpoch: UInt64) {
        transportLock.lock()
        let authentic = managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        )
        guard isStarted, authentic else {
            transportLock.unlock()
            return
        }
        transportLock.unlock()

    }

    public func processPeripheralReceiveRead(_ pm: CBPeripheralManager, request: CBATTRequest, sourceEpoch: UInt64) {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            transportLock.unlock()
            pm.respond(to: request, withResult: .unlikelyError)
            return
        }
        transportLock.unlock()

        if BleTransport.classifyInbound(request.characteristic.uuid) == .toLinkInfo {
            if request.offset != 0 {
                pm.respond(to: request, withResult: .invalidOffset)
                return
            }
            let action = peripheralDriver?.onCentralRead(centralId: request.central.identifier) ?? .noOp
            switch action {
            case .sendReadResponse(_, let data):
                request.value = data
                pm.respond(to: request, withResult: .success)
            default:
                pm.respond(to: request, withResult: .unlikelyError)
            }
            return
        }

        pm.respond(to: request, withResult: .requestNotSupported)
    }

    public func processPeripheralReceiveWrite(_ pm: CBPeripheralManager, requests: [CBATTRequest], sourceEpoch: UInt64) {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            transportLock.unlock()
            for r in requests {
                pm.respond(to: r, withResult: .unlikelyError)
            }
            return
        }
        transportLock.unlock()

        for r in requests {
            let centralId = r.central.identifier

            if BleTransport.classifyInbound(r.characteristic.uuid) == .toLinkInfo {
                if r.offset != 0 {
                    pm.respond(to: r, withResult: .invalidOffset)
                    continue
                }
                guard let v = r.value, v.count == BleLinkInfoConstants.linkInfoBytes else {
                    pm.respond(to: r, withResult: .invalidAttributeValueLength)
                    continue
                }

                let action = processInboundWrite(centralId: centralId, rawData: v, sourceEpoch: sourceEpoch, from: pm)
                let result = decideInboundWriteAttResponse(action: action)
                pm.respond(to: r, withResult: result)
                continue
            }

            if BleTransport.classifyInbound(r.characteristic.uuid) == .toDeframer {
                guard let v = r.value else {
                    pm.respond(to: r, withResult: .invalidAttributeValueLength)
                    continue
                }

                transportLock.lock()
                guard let conn = inboundPeripheralConnections[centralId], conn.isRoleBound else {
                    transportLock.unlock()
                    pm.respond(to: r, withResult: .unlikelyError)
                    continue
                }

                let record = conn.ingestInboundAttValue(v)
                transportLock.unlock()

                if let rec = record, rec.recordType == .data && conn.state == .ready {
                    if let clear = sessions?.open(centralId, rec.payload) {
                        delegate?.transportDidReceive(data: clear, peerId: centralId)
                    }
                }
                pm.respond(to: r, withResult: .success)
                continue
            }

            pm.respond(to: r, withResult: .requestNotSupported)
        }
    }

    public func processPeripheralDidSubscribe(_ pm: CBPeripheralManager, central: CBCentral, characteristic ch: CBCharacteristic, sourceEpoch: UInt64) {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            transportLock.unlock()
            return
        }
        transportLock.unlock()

        guard ch.uuid == BleTransport.inboxCharacteristicUuid else { return }
        _ = processInboundSubscribe(centralId: central.identifier, central: central, maxUpdateLength: central.maximumUpdateValueLength, sourceEpoch: sourceEpoch, from: pm)
    }

    public func processPeripheralDidUnsubscribe(_ pm: CBPeripheralManager, central: CBCentral, characteristic ch: CBCharacteristic, sourceEpoch: UInt64) {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            transportLock.unlock()
            return
        }
        transportLock.unlock()

        _ = processInboundUnsubscribe(centralId: central.identifier, expectedGen: 0, sourceEpoch: sourceEpoch, from: pm)
    }

    public func processPeripheralIsReadyToUpdateSubscribers(_ pm: CBPeripheralManager, sourceEpoch: UInt64) {
        transportLock.lock()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            transportLock.unlock()
            return
        }
        guard let inboxChar = mutableInboxCharacteristic else {
            transportLock.unlock()
            return
        }

        for (centralId, var queue) in pendingOutboundUpdates {
            guard let centralObj = subscribedCentrals[centralId] else {
                pendingOutboundUpdates.removeValue(forKey: centralId)
                continue
            }

            while !queue.isEmpty {
                let nextItem = queue[0]
                let ok = pm.updateValue(nextItem, for: inboxChar, onSubscribedCentrals: [centralObj])
                if ok {
                    queue.removeFirst()
                } else {
                    break
                }
            }

            if queue.isEmpty {
                pendingOutboundUpdates.removeValue(forKey: centralId)
            } else {
                pendingOutboundUpdates[centralId] = queue
            }
        }
        transportLock.unlock()
    }
}

public protocol TransportDelegate: AnyObject {
    func transportDidConnect(peerId: UUID)
    func transportPhysicalDuplexReady(peerId: UUID)
    func transportReady(peerId: UUID)
    func transportDidDisconnect(peerId: UUID)
    func transportDidReceive(data: Data, peerId: UUID)
}

public extension TransportDelegate {
    func transportPhysicalDuplexReady(peerId: UUID) {}
    func transportReady(peerId: UUID) {}
}
