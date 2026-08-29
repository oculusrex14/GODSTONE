import Foundation
import CoreBluetooth
import GodstoneCore

public final class BleTransport: NSObject, @unchecked Sendable {

    public static let serviceUuid = CBUUID(string: FrameV2.serviceUuidString)
    public static let inboxCharacteristicUuid = CBUUID(string: "0000FD01-0000-1000-8000-00805F9B34FB")
    public static let digestCharacteristicUuid = CBUUID(string: "0000FD02-0000-1000-8000-00805F9B34FB")
    public static let linkInfoCharacteristicUuid = CBUUID(string: FrameV2.linkInfoUuidString)

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

    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?

    private var isStarted = false
    private var isBackgrounded = false
    private var isServiceRegistered = false

    private var mutableInboxCharacteristic: CBMutableCharacteristic?
    private var mutableLinkInfoCharacteristic: CBMutableCharacteristic?

    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private var inboxCharacteristics: [UUID: CBCharacteristic] = [:]
    private var linkInfoCharacteristics: [UUID: CBCharacteristic] = [:]
    private var pendingInitiatorRemoteHints: [UUID: Data] = [:]
    private var subscribedCentrals: [UUID: CBCentral] = [:]

    var outboundCentralConnections: [UUID: BleConnection] = [:]
    var inboundPeripheralConnections: [UUID: BleConnection] = [:]

    private var provisionalTimers: [UUID: Timer] = [:]
    private var provisionalGenerations: [UUID: UInt64] = [:]
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
        provisionalTimeoutSeconds: TimeInterval = 10.0
    ) {
        self.identity = identity
        self.store = store
        self.sessions = sessions
        self.provisionalTimeoutSeconds = provisionalTimeoutSeconds
        super.init()
        self.snapshotAuthority = LinkInfoSnapshotAuthority(
            identityProvider: { [weak self] in self?.identity },
            storeProvider: { [weak self] in self?.store }
        )

        #if !os(macOS)
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
        if isTesting {
            central = CBCentralManager(delegate: self, queue: .global(qos: .utility))
            peripheral = CBPeripheralManager(delegate: self, queue: .global(qos: .utility))
        } else {
            central = CBCentralManager(delegate: self, queue: .global(qos: .utility), options: [CBCentralManagerOptionRestoreIdentifierKey: "io.godstone.central"])
            peripheral = CBPeripheralManager(delegate: self, queue: .global(qos: .utility), options: [CBPeripheralManagerOptionRestoreIdentifierKey: "io.godstone.peripheral"])
        }
        #endif
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
        let localHint = identity?.nodeHint ?? Data(repeating: 0, count: BleRoleElection.nodeHintBytes)
        centralDriver = BleCentralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { [weak self] in self?.getLocalLinkInfoData() },
            capacityAuthority: capacityAuthority
        )
        peripheralDriver = BlePeripheralOrchestrationDriver(
            localHint: localHint,
            localLinkInfoProvider: { [weak self] in self?.getLocalLinkInfoData() },
            capacityAuthority: capacityAuthority
        )
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
        isStarted = false

        central?.stopScan()
        peripheral?.stopAdvertising()

        for (_, timer) in provisionalTimers {
            timer.invalidate()
        }
        provisionalTimers.removeAll()
        provisionalGenerations.removeAll()

        for (_, timer) in inboundTimers {
            timer.invalidate()
        }
        inboundTimers.removeAll()

        for (_, p) in connectedPeripherals {
            central?.cancelPeripheralConnection(p)
        }
        connectedPeripherals.removeAll()
        inboxCharacteristics.removeAll()
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

    private func purgeCentralConnection(peerId: UUID, cancelPeripheral: Bool) {
        let gen = centralDriver?.getConnectionGeneration(peerId) ?? 0
        transportLock.lock()
        provisionalTimers.removeValue(forKey: peerId)?.invalidate()
        inboxCharacteristics.removeValue(forKey: peerId)
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
        guard let sealed = sessions?.seal(peerId, frame.encode()) else {
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

    public func processInboundWrite(centralId: UUID, rawData: Data) -> BlePeripheralAction {
        guard let driver = peripheralDriver else { return .noOp }
        let action = driver.onCentralWrite(centralId: centralId, rawData: rawData)
        switch action {
        case .acceptWrite(let cid, let remoteHint),
             .acceptWriteAndDuplexReady(let cid, let remoteHint):
            transportLock.lock()
            if inboundPeripheralConnections[cid] == nil {
                inboundPeripheralConnections[cid] = driver.getInboundConnection(cid)
            }
            if let conn = inboundPeripheralConnections[cid], !conn.isRoleBound {
                conn.bindResponderFromAcceptedIncomingLinkInfo(remoteHint: remoteHint)
            }
            let gen = driver.getCentralGeneration(cid)
            if inboundTimers[cid] == nil {
                let timer = Timer(timeInterval: provisionalTimeoutSeconds, repeats: false) { [weak self] _ in
                    self?.handleInboundTimeout(centralId: cid, generation: gen)
                }
                RunLoop.main.add(timer, forMode: .common)
                inboundTimers[cid] = timer
            }
            transportLock.unlock()
            if case .acceptWriteAndDuplexReady = action {
                let key = RelationKey(direction: .inboundPeripheral, peerId: cid, generation: gen)
                publishRelation(key)
            }
        default:
            break
        }
        return action
    }

    public func processInboundSubscribe(centralId: UUID, maxUpdateLength: Int = 512) -> BlePeripheralAction {
        guard let driver = peripheralDriver else { return .noOp }
        let action = driver.onCentralSubscribed(centralId: centralId)
        switch action {
        case .acceptSubscription(let cid), .acceptSubscriptionAndDuplexReady(let cid):
            transportLock.lock()
            inboundTimers.removeValue(forKey: cid)?.invalidate()
            if inboundPeripheralConnections[cid] == nil {
                inboundPeripheralConnections[cid] = driver.getInboundConnection(cid)
            }
            if let conn = inboundPeripheralConnections[cid] {
                conn.markConnected(negotiatedAttValueLength: maxUpdateLength)
            }
            let gen = driver.getCentralGeneration(cid)
            transportLock.unlock()
            if case .acceptSubscriptionAndDuplexReady = action {
                let key = RelationKey(direction: .inboundPeripheral, peerId: cid, generation: gen)
                publishRelation(key)
            }
        default:
            break
        }
        return action
    }

    public func processInboundUnsubscribe(centralId: UUID, expectedGen: UInt64 = 0) -> BlePeripheralAction {
        guard let driver = peripheralDriver else { return .noOp }
        let currentGen = driver.getCentralGeneration(centralId)
        if expectedGen != 0 && currentGen != expectedGen {
            return .noOp
        }
        let effectiveGen = (expectedGen != 0) ? expectedGen : currentGen
        let action = driver.onCentralUnsubscribed(centralId: centralId, expectedGen: effectiveGen)
        transportLock.lock()
        inboundTimers.removeValue(forKey: centralId)?.invalidate()
        inboundPeripheralConnections.removeValue(forKey: centralId)?.markDisconnected()
        subscribedCentrals.removeValue(forKey: centralId)
        pendingOutboundUpdates.removeValue(forKey: centralId)
        transportLock.unlock()
        let key = RelationKey(direction: .inboundPeripheral, peerId: centralId, generation: effectiveGen)
        unpublishRelation(key)
        return action
    }

    public func handleInboundTimeout(centralId: UUID, generation: UInt64 = 0) {
        guard let driver = peripheralDriver else { return }
        let currentGen = driver.getCentralGeneration(centralId)
        if generation != 0 && currentGen != generation {
            return
        }
        if driver.isPhysicalReady(centralId) {
            return
        }
        let effectiveGen = (generation != 0) ? generation : currentGen
        driver.onInboundTimeout(centralId: centralId, expectedGen: effectiveGen)
        transportLock.lock()
        inboundTimers.removeValue(forKey: centralId)?.invalidate()
        inboundPeripheralConnections.removeValue(forKey: centralId)?.markDisconnected()
        subscribedCentrals.removeValue(forKey: centralId)
        pendingOutboundUpdates.removeValue(forKey: centralId)
        transportLock.unlock()
        let key = RelationKey(direction: .inboundPeripheral, peerId: centralId, generation: effectiveGen)
        unpublishRelation(key)
    }

    public func processOutboundDisconnect(peerId: UUID, expectedGen: UInt64 = 0) -> BleCentralAction {
        guard let driver = centralDriver else { return .noOp }
        let currentGen = driver.getConnectionGeneration(peerId)
        if expectedGen != 0 && currentGen != expectedGen {
            return .noOp
        }
        let effectiveGen = (expectedGen != 0) ? expectedGen : currentGen
        transportLock.lock()
        provisionalTimers.removeValue(forKey: peerId)?.invalidate()
        outboundCentralConnections.removeValue(forKey: peerId)?.markDisconnected()
        connectedPeripherals.removeValue(forKey: peerId)
        inboxCharacteristics.removeValue(forKey: peerId)
        linkInfoCharacteristics.removeValue(forKey: peerId)
        pendingInitiatorRemoteHints.removeValue(forKey: peerId)
        pendingOutboundWrites.removeValue(forKey: peerId)
        transportLock.unlock()
        let action = driver.onDisconnected(peerId: peerId, expectedGen: effectiveGen)
        let key = RelationKey(direction: .outboundCentral, peerId: peerId, generation: effectiveGen)
        unpublishRelation(key)
        return action
    }

    public func handleOutboundTimeout(peerId: UUID, generation: UInt64 = 0) -> BleCentralAction {
        guard let driver = centralDriver else { return .noOp }
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
        provisionalTimers.removeValue(forKey: peerId)?.invalidate()
        let p = connectedPeripherals.removeValue(forKey: peerId)
        outboundCentralConnections.removeValue(forKey: peerId)?.markDisconnected()
        inboxCharacteristics.removeValue(forKey: peerId)
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

    public func dispatchReceiveRead(centralId: UUID) -> BlePeripheralAction {
        return peripheralDriver?.onCentralRead(centralId: centralId) ?? .noOp
    }

    public func dispatchReceiveWrite(centralId: UUID, rawData: Data) -> BlePeripheralAction {
        return processInboundWrite(centralId: centralId, rawData: rawData)
    }

    public func dispatchSubscribe(centralId: UUID) -> BlePeripheralAction {
        return processInboundSubscribe(centralId: centralId)
    }

    public func dispatchUnsubscribe(centralId: UUID, expectedGen: UInt64 = 0) -> BlePeripheralAction {
        return processInboundUnsubscribe(centralId: centralId, expectedGen: expectedGen)
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
}

extension BleTransport: CBCentralManagerDelegate, CBPeripheralDelegate {

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn && isStarted {
            startScanning()
        }
    }

    public func centralManager(_ c: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        transportLock.lock()
        defer { transportLock.unlock() }
        if let peers = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for p in peers {
                p.delegate = self
                connectedPeripherals[p.identifier] = p
            }
        }
    }

    public func centralManager(_ c: CBCentralManager,
                               didDiscover p: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        guard RSSI.intValue > -90 else { return }

        var metaHint: Data? = nil
        transportLock.lock()
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

        let action = centralDriver?.onDiscover(peerId: p.identifier, rssi: RSSI.intValue, serviceDataHint: metaHint) ?? .noOp
        if case .connectPeripheral(let peerId) = action {
            if outboundCentralConnections[peerId] == nil {
                let conn = centralDriver?.getActiveConnection(peerId) ?? BleConnection(peerId: peerId)
                outboundCentralConnections[peerId] = conn
                connectedPeripherals[peerId] = p
                p.delegate = self

                let gen = (provisionalGenerations[peerId] ?? 0) + 1
                provisionalGenerations[peerId] = gen
                let timer = Timer(timeInterval: provisionalTimeoutSeconds, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    self.transportLock.lock()
                    let isCurrentGen = (self.provisionalGenerations[peerId] == gen)
                    let isReady = self.outboundCentralConnections[peerId]?.isHandshakeTransportReady ?? false
                    self.transportLock.unlock()
                    if isCurrentGen && !isReady {
                        self.purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                provisionalTimers[peerId] = timer
                transportLock.unlock()
                c.connect(p, options: nil)
                return
            }
        }
        transportLock.unlock()
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        let action = centralDriver?.onConnected(peerId: p.identifier) ?? .noOp
        if case .discoverServices(let peerId) = action {
            p.discoverServices([BleTransport.serviceUuid])
        }
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        _ = centralDriver?.onFailedToConnect(peerId: p.identifier, error: error)
        purgeCentralConnection(peerId: p.identifier, cancelPeripheral: false)
    }

    public func centralManager(_ c: CBCentralManager,
                               didDisconnectPeripheral p: CBPeripheral,
                               error: Error?) {
        _ = processOutboundDisconnect(peerId: p.identifier)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let success = (error == nil && (p.services?.contains(where: { $0.uuid == BleTransport.serviceUuid }) ?? false))
        let action = centralDriver?.onServicesDiscovered(peerId: p.identifier, success: success) ?? .noOp
        switch action {
        case .discoverCharacteristics(let peerId):
            for s in p.services ?? [] where s.uuid == BleTransport.serviceUuid {
                p.discoverCharacteristics(
                    [BleTransport.inboxCharacteristicUuid, BleTransport.digestCharacteristicUuid, BleTransport.linkInfoCharacteristicUuid],
                    for: s
                )
            }
        case .disconnectPeripheral(let peerId, _):
            purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
        default: break
        }
    }

    public func peripheral(_ p: CBPeripheral,
                            didDiscoverCharacteristicsFor service: CBService,
                            error: Error?) {
        transportLock.lock()
        for ch in service.characteristics ?? [] {
            if ch.uuid == BleTransport.inboxCharacteristicUuid {
                inboxCharacteristics[p.identifier] = ch
            } else if ch.uuid == BleTransport.linkInfoCharacteristicUuid {
                linkInfoCharacteristics[p.identifier] = ch
            }
        }
        let linkInfoChar = linkInfoCharacteristics[p.identifier]
        transportLock.unlock()

        let success = (error == nil && linkInfoChar != nil)
        let action = centralDriver?.onCharacteristicsDiscovered(peerId: p.identifier, success: success) ?? .noOp
        switch action {
        case .readLinkInfo(let peerId):
            if let ch = linkInfoChar {
                p.readValue(for: ch)
            }
        case .disconnectPeripheral(let peerId, _):
            purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
        default: break
        }
    }

    public func peripheral(_ p: CBPeripheral,
                            didUpdateValueFor ch: CBCharacteristic,
                            error: Error?) {
        if ch.uuid == BleTransport.linkInfoCharacteristicUuid {
            let success = (error == nil)
            let action = centralDriver?.onLinkInfoReadResult(peerId: p.identifier, success: success, rawData: ch.value) ?? .noOp
            switch action {
            case .writeLinkInfo(let peerId, let localData, let remoteHint):
                transportLock.lock()
                pendingInitiatorRemoteHints[peerId] = remoteHint
                transportLock.unlock()
                p.writeValue(localData, for: ch, type: .withResponse)
            case .disconnectPeripheral(let peerId, _):
                purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
            default: break
            }
            return
        }

        if ch.uuid == BleTransport.inboxCharacteristicUuid {
            transportLock.lock()
            guard let conn = outboundCentralConnections[p.identifier], conn.isRoleBound else {
                transportLock.unlock()
                return
            }
            guard let record = conn.ingestInboundAttValue(ch.value ?? Data()) else {
                transportLock.unlock()
                return
            }
            transportLock.unlock()

            if record.recordType == .data && conn.state == .ready {
                guard let clear = sessions?.open(p.identifier, record.payload) else { return }
                delegate?.transportDidReceive(data: clear, peerId: p.identifier)
            }
        }
    }

    public func peripheral(_ p: CBPeripheral,
                            didWriteValueFor ch: CBCharacteristic,
                            error: Error?) {
        if ch.uuid == BleTransport.linkInfoCharacteristicUuid {
            transportLock.lock()
            let remoteHint = pendingInitiatorRemoteHints.removeValue(forKey: p.identifier)
            transportLock.unlock()

            let action = centralDriver?.onLinkInfoWriteAcknowledged(
                peerId: p.identifier,
                success: (error == nil),
                remoteHint: remoteHint ?? Data()
            ) ?? .noOp

            switch action {
            case .setNotify(let peerId):
                transportLock.lock()
                if let inboxChar = inboxCharacteristics[peerId] {
                    let maxWrite = p.maximumWriteValueLength(for: .withoutResponse)
                    outboundCentralConnections[peerId]?.markConnected(negotiatedAttValueLength: maxWrite)
                    p.setNotifyValue(true, for: inboxChar)
                }
                transportLock.unlock()
            case .disconnectPeripheral(let peerId, _):
                purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
            default: break
            }
        }
    }

    public func peripheral(_ p: CBPeripheral,
                            didUpdateNotificationStateFor ch: CBCharacteristic,
                            error: Error?) {
        if ch.uuid == BleTransport.inboxCharacteristicUuid {
            let success = (error == nil)
            let action = centralDriver?.onNotificationStateUpdated(peerId: p.identifier, success: success, isNotifying: ch.isNotifying) ?? .noOp
            switch action {
            case .physicalDuplexReady(let peerId, _):
                transportLock.lock()
                provisionalTimers.removeValue(forKey: peerId)?.invalidate()
                let gen = centralDriver?.getConnectionGeneration(peerId) ?? 0
                transportLock.unlock()
                let key = RelationKey(direction: .outboundCentral, peerId: peerId, generation: gen)
                publishRelation(key)
            case .disconnectPeripheral(let peerId, _):
                purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
            default: break
            }
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        transportLock.lock()
        defer { transportLock.unlock() }
        guard let ch = inboxCharacteristics[p.identifier] else { return }

        var queue = pendingOutboundWrites[p.identifier] ?? []
        while !queue.isEmpty && p.canSendWriteWithoutResponse {
            let item = queue.removeFirst()
            p.writeValue(item, for: ch, type: .withoutResponse)
        }

        if queue.isEmpty {
            pendingOutboundWrites.removeValue(forKey: p.identifier)
        } else {
            pendingOutboundWrites[p.identifier] = queue
        }
    }
}

extension BleTransport: CBPeripheralManagerDelegate {

    public func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        guard pm.state == .poweredOn else { return }

        let inbox = CBMutableCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.writeWithoutResponse, .write, .notify],
            value: nil,
            permissions: [.writeable]
        )

        let digest = CBMutableCharacteristic(
            type: BleTransport.digestCharacteristicUuid,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )

        let linkInfo = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: nil,
            permissions: [.readable, .writeable]
        )

        let service = CBMutableService(type: BleTransport.serviceUuid, primary: true)
        service.characteristics = [inbox, digest, linkInfo]
        pm.add(service)

        mutableInboxCharacteristic = inbox
        mutableLinkInfoCharacteristic = linkInfo
    }

    public func peripheralManager(_ pm: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        transportLock.lock()
        if error == nil && service.uuid == BleTransport.serviceUuid {
            isServiceRegistered = true
        }
        let shouldAdv = isStarted && isServiceRegistered
        transportLock.unlock()

        if shouldAdv {
            startAdvertising()
        }
    }

    public func peripheralManager(_ pm: CBPeripheralManager, willRestoreState dict: [String: Any]) {
    }

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  didReceiveRead request: CBATTRequest) {
        if request.characteristic.uuid == BleTransport.linkInfoCharacteristicUuid {
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

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let centralId = r.central.identifier

            if r.characteristic.uuid == BleTransport.linkInfoCharacteristicUuid {
                if r.offset != 0 {
                    pm.respond(to: r, withResult: .invalidOffset)
                    continue
                }
                guard let v = r.value, v.count == BleLinkInfoConstants.linkInfoBytes else {
                    pm.respond(to: r, withResult: .invalidAttributeValueLength)
                    continue
                }

                let action = processInboundWrite(centralId: centralId, rawData: v)
                switch action {
                case .acceptWrite, .acceptWriteAndDuplexReady:
                    pm.respond(to: r, withResult: .success)
                default:
                    pm.respond(to: r, withResult: .unlikelyError)
                }
                continue
            }

            if r.characteristic.uuid == BleTransport.inboxCharacteristicUuid {
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

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  central: CBCentral,
                                  didSubscribeTo ch: CBCharacteristic) {
        guard ch.uuid == BleTransport.inboxCharacteristicUuid else { return }
        _ = processInboundSubscribe(centralId: central.identifier, maxUpdateLength: central.maximumUpdateValueLength)
    }

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  central: CBCentral,
                                  didUnsubscribeFrom ch: CBCharacteristic) {
        _ = processInboundUnsubscribe(centralId: central.identifier)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers pm: CBPeripheralManager) {
        transportLock.lock()
        defer { transportLock.unlock() }
        guard let inboxChar = mutableInboxCharacteristic else { return }

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
