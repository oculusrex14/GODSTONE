import Foundation
import CoreBluetooth
import GodstoneCore

/// BLE control plane. Always on, duty-cycled, background-capable (with the
/// caveats documented below and surfaced in the UI).
///
/// Persistent duplex BLE link substrate and role election (ADR-002, Phase C8.4D1-A1/R2).
public final class BleTransport: NSObject {

    public static let serviceUuid = CBUUID(string: FrameV2.serviceUuidString)
    public static let inboxCharacteristicUuid = CBUUID(string: FrameV2.inboxUuidString)
    public static let digestCharacteristicUuid = CBUUID(string: FrameV2.digestUuidString)
    public static let linkInfoCharacteristicUuid = CBUUID(string: FrameV2.linkInfoUuidString)

    public static let maxDiscoveredPeers = 64
    public static let maxActiveConnections = 7
    public static let maxQueuedAttValues = 16

    private var central: CBCentralManager!
    private var peripheral: CBPeripheralManager!

    public var store: MessageStore? {
        didSet {
            snapshotAuthority?.refresh()
        }
    }

    public var identity: MeshIdentity? {
        didSet {
            if let id = identity {
                
                snapshotAuthority?.refresh()
            }
        }
    }

    public private(set) var roleCoordinator: BleRoleBindingCoordinator
    private var capacityAuthority = BleGlobalCapacityAuthority(maxTotalPeers: BleTransport.maxActiveConnections)
    private var centralDriver: BleCentralOrchestrationDriver?
    private var peripheralDriver: BlePeripheralOrchestrationDriver?
    public private(set) var snapshotAuthority: LinkInfoSnapshotAuthority!

    // Separate identifier namespaces:
    // Outbound Central links keyed by CBPeripheral.identifier
    private var outboundCentralConnections: [UUID: BleConnection] = [:]
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private var inboxCharacteristics: [UUID: CBCharacteristic] = [:]
    private var linkInfoCharacteristics: [UUID: CBCharacteristic] = [:]
    private var pendingInitiatorRemoteHints: [UUID: Data] = [:]
    private var provisionalTimers: [UUID: Timer] = [:]
    private var provisionalGenerations: [UUID: UInt64] = [:]

    // Inbound Peripheral links keyed by CBCentral.identifier
    private var inboundPeripheralConnections: [UUID: BleConnection] = [:]
    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var mutableInboxCharacteristic: CBMutableCharacteristic?
    private var mutableLinkInfoCharacteristic: CBMutableCharacteristic?

    // Discovered peer metadata cache (optional UI/scan-response hint)
    private var discoveredPeers: [UUID: BleDiscoveryMetadata] = [:]

    // Queued outbound writes awaiting peripheralIsReady(toSendWriteWithoutResponse:)
    private var pendingOutboundWrites: [UUID: [Data]] = [:]

    // Queued outbound notifications awaiting peripheralManagerIsReady(toUpdateSubscribers:)
    private var pendingOutboundUpdates: [UUID: [Data]] = [:]

    private let transportLock = NSLock()

    public weak var delegate: TransportDelegate?

    /// Noise sessions. Without this the transport cannot send -- by design.
    public var sessions: SessionManager?

    public private(set) var isBackgrounded = false
    public private(set) var isStarted = false
    public private(set) var isServiceRegistered = false

    public var provisionalTimeoutSeconds: TimeInterval = 10.0

    public init(identity: MeshIdentity? = nil, store: MessageStore? = nil) {
        self.identity = identity
        self.store = store
        self.roleCoordinator = BleRoleBindingCoordinator(localHint: Data((identity?.nodeHint ?? Data(repeating: 0, count: 4)).prefix(4)))
        
        super.init()

        self.snapshotAuthority = LinkInfoSnapshotAuthority(
            identityProvider: { [weak self] in self?.identity },
            storeProvider: { [weak self] in self?.store }
        )

        #if targetEnvironment(simulator)
        central = CBCentralManager(delegate: self, queue: .global(qos: .utility))
        peripheral = CBPeripheralManager(delegate: self, queue: .global(qos: .utility))
        #else
        central = CBCentralManager(delegate: self, queue: .global(qos: .utility), options: [CBCentralManagerOptionRestoreIdentifierKey: "io.godstone.central"])
        peripheral = CBPeripheralManager(delegate: self, queue: .global(qos: .utility), options: [CBPeripheralManagerOptionRestoreIdentifierKey: "io.godstone.peripheral"])
        #endif
    }

    /// Retrieve local LinkInfo bytes when transportLock is ALREADY held by the caller.
    func getLocalLinkInfoDataLocked() -> Data? {
        return snapshotAuthority.currentData()
    }

    /// Retrieve local LinkInfo bytes safely from external/unlocked callers.
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
        let canAdv = isServiceRegistered && peripheral.state == .poweredOn
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

        central.stopScan()
        peripheral.stopAdvertising()

        for (_, timer) in provisionalTimers {
            timer.invalidate()
        }
        provisionalTimers.removeAll()

        for (_, p) in connectedPeripherals {
            central.cancelPeripheralConnection(p)
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

        discoveredPeers.removeAll()
        pendingOutboundWrites.removeAll()
        pendingOutboundUpdates.removeAll()
        transportLock.unlock()
    }

    private func startScanning() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [BleTransport.serviceUuid],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: !isBackgrounded]
        )
    }

    private func startAdvertising() {
        guard peripheral.state == .poweredOn, isServiceRegistered else { return }
        // Privacy: service UUID only, no local name broadcast (ADR-002 §2 / §7b)
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BleTransport.serviceUuid]
        ])
    }

    public func setBackgrounded(_ backgrounded: Bool) {
        transportLock.lock()
        defer { transportLock.unlock() }
        isBackgrounded = backgrounded
        central.stopScan()
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

    /// Transactionally purges an outbound central provisional/canonical link on failure or disconnect.
    private func purgeCentralConnection(peerId: UUID, cancelPeripheral: Bool) {
        transportLock.lock()
        provisionalTimers.removeValue(forKey: peerId)?.invalidate()
        inboxCharacteristics.removeValue(forKey: peerId)
        linkInfoCharacteristics.removeValue(forKey: peerId)
        pendingInitiatorRemoteHints.removeValue(forKey: peerId)
        pendingOutboundWrites.removeValue(forKey: peerId)
        let periph = connectedPeripherals.removeValue(forKey: peerId)
        let conn = outboundCentralConnections.removeValue(forKey: peerId)
        conn?.markDisconnected()
        transportLock.unlock()

        if cancelPeripheral, let p = periph {
            central.cancelPeripheralConnection(p)
        }
        delegate?.transportDidDisconnect(peerId: peerId)
    }

    /// Send [frame] to [peerId] through the Noise session and BleRecord layer.
    /// Application DATA is strictly forbidden unless both link connection and Noise session are READY.
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
                    let ok = peripheral.updateValue(frag, for: inboxChar, onSubscribedCentrals: [centralObj])
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
        let action = centralDriver?.onDisconnected(peerId: p.identifier) ?? .noOp
        purgeCentralConnection(peerId: p.identifier, cancelPeripheral: false)
        if case .didDisconnect(let peerId) = action {
            // Already handled by purgeCentralConnection delegating out
        }
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
                delegate?.transportPhysicalDuplexReady(peerId: peerId)
                delegate?.transportDidConnect(peerId: peerId)
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

                let action = peripheralDriver?.onCentralWrite(centralId: centralId, rawData: v) ?? .noOp
                switch action {
                case .acceptWrite(let centralId, let remoteHint),
                     .acceptWriteAndDuplexReady(let centralId, let remoteHint):
                    transportLock.lock()
                    if inboundPeripheralConnections[centralId] == nil {
                        inboundPeripheralConnections[centralId] = peripheralDriver?.getInboundConnection(centralId)
                    }
                    if let conn = inboundPeripheralConnections[centralId], !(conn.isRoleBound) {
                        conn.bindResponderFromAcceptedIncomingLinkInfo(remoteHint: remoteHint)
                    }
                    transportLock.unlock()
                    pm.respond(to: r, withResult: .success)
                    
                    if case .acceptWriteAndDuplexReady = action {
                        delegate?.transportPhysicalDuplexReady(peerId: centralId)
                        delegate?.transportDidConnect(peerId: centralId)
                    }
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
        
        let action = peripheralDriver?.onCentralSubscribed(centralId: central.identifier) ?? .noOp
        switch action {
        case .acceptSubscription(let centralId), .acceptSubscriptionAndDuplexReady(let centralId):
            transportLock.lock()
            subscribedCentrals[centralId] = central
            if inboundPeripheralConnections[centralId] == nil {
                inboundPeripheralConnections[centralId] = peripheralDriver?.getInboundConnection(centralId)
            }
            if let conn = inboundPeripheralConnections[centralId] {
                let maxUpdate = central.maximumUpdateValueLength
                conn.markConnected(negotiatedAttValueLength: maxUpdate)
            }
            transportLock.unlock()
            
            if case .acceptSubscriptionAndDuplexReady = action {
                delegate?.transportPhysicalDuplexReady(peerId: centralId)
                delegate?.transportDidConnect(peerId: centralId)
            }
        default:
            break
        }
    }

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  central: CBCentral,
                                  didUnsubscribeFrom ch: CBCharacteristic) {
        _ = peripheralDriver?.onCentralUnsubscribed(centralId: central.identifier)
        transportLock.lock()
        subscribedCentrals.removeValue(forKey: central.identifier)
        pendingOutboundUpdates.removeValue(forKey: central.identifier)
        if let conn = inboundPeripheralConnections.removeValue(forKey: central.identifier) {
            conn.markDisconnected()
        }
        transportLock.unlock()
        delegate?.transportDidDisconnect(peerId: central.identifier)
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
