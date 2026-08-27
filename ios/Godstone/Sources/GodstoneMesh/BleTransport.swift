import Foundation
import CoreBluetooth

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

    public var identity: MeshIdentity? {
        didSet {
            if let id = identity {
                roleCoordinator = BleRoleBindingCoordinator(localHint: id.nodeHint)
                refreshLocalLinkInfoSnapshotSync()
            }
        }
    }

    public private(set) var roleCoordinator: BleRoleBindingCoordinator

    // Separate identifier namespaces:
    // Outbound Central links keyed by CBPeripheral.identifier
    private var outboundCentralConnections: [UUID: BleConnection] = [:]
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private var inboxCharacteristics: [UUID: CBCharacteristic] = [:]
    private var linkInfoCharacteristics: [UUID: CBCharacteristic] = [:]
    private var pendingInitiatorRemoteHints: [UUID: Data] = [:]

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

    private var cachedLocalLinkInfoSnapshot: BleLinkInfoV1?
    private var cachedLocalLinkInfoData: Data?

    private let transportLock = NSLock()

    public weak var delegate: TransportDelegate?

    /// Noise sessions. Without this the transport cannot send -- by design.
    public var sessions: SessionManager?

    public private(set) var isBackgrounded = false
    public private(set) var isStarted = false
    public private(set) var isServiceRegistered = false

    public init(identity: MeshIdentity? = nil) {
        self.identity = identity
        let initialHint = identity?.nodeHint ?? Data(repeating: 0, count: BleRoleElection.nodeHintBytes)
        self.roleCoordinator = BleRoleBindingCoordinator(localHint: initialHint)
        super.init()

        refreshLocalLinkInfoSnapshotSync()

        #if targetEnvironment(simulator)
        central = CBCentralManager(delegate: self, queue: .global(qos: .utility))
        peripheral = CBPeripheralManager(delegate: self, queue: .global(qos: .utility))
        #else
        central = CBCentralManager(delegate: self, queue: .global(qos: .utility), options: [CBCentralManagerOptionRestoreIdentifierKey: "io.godstone.central"])
        peripheral = CBPeripheralManager(delegate: self, queue: .global(qos: .utility), options: [CBPeripheralManagerOptionRestoreIdentifierKey: "io.godstone.peripheral"])
        #endif
    }

    public func getLocalLinkInfoData() -> Data? {
        transportLock.lock()
        defer { transportLock.unlock() }
        if cachedLocalLinkInfoData == nil {
            refreshLocalLinkInfoSnapshotSyncLocked()
        }
        return cachedLocalLinkInfoData
    }

    public func refreshLocalLinkInfoSnapshotSync() {
        transportLock.lock()
        defer { transportLock.unlock() }
        refreshLocalLinkInfoSnapshotSyncLocked()
    }

    private func refreshLocalLinkInfoSnapshotSyncLocked() {
        let nodeHint = identity?.nodeHint ?? Data(repeating: 0, count: BleRoleElection.nodeHintBytes)
        let shortDigest = Data(repeating: 0, count: BleLinkInfoConstants.shortDigestBytes)
        let queueDepth: UInt8 = 0
        let flags: UInt8 = 0

        let info = BleLinkInfoV1(
            version: BleLinkInfoConstants.protocolVersion,
            flags: flags,
            nodeHint: nodeHint,
            shortDigest: shortDigest,
            queueDepth: queueDepth
        )
        cachedLocalLinkInfoSnapshot = info
        cachedLocalLinkInfoData = BleLinkInfoCodec.encode(
            version: info.version,
            flags: info.flags,
            nodeHint: info.nodeHint,
            shortDigest: info.shortDigest,
            queueDepth: info.queueDepth
        )
    }

    public func start() {
        transportLock.lock()
        guard !isStarted else {
            transportLock.unlock()
            return
        }
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
        defer { transportLock.unlock() }
        guard isStarted else { return }
        isStarted = false

        central.stopScan()
        peripheral.stopAdvertising()

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
            if !queue.isEmpty || !p.canSendWriteWithoutResponse {
                if queue.count + fragments.count > BleTransport.maxQueuedAttValues {
                    transportLock.unlock()
                    return false
                }
                queue.append(contentsOf: fragments)
                pendingOutboundWrites[peerId] = queue
                transportLock.unlock()
                return true
            }

            transportLock.unlock()
            for frag in fragments {
                p.writeValue(frag, for: ch, type: .withoutResponse)
            }
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

        transportLock.lock()
        defer { transportLock.unlock() }

        // Optional scan response metadata (if present)
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
        }

        // UUID-Only Discovery: Canonical Service UUID discovery is sufficient to initiate provisional connection
        if let existing = outboundCentralConnections[p.identifier], existing.isActive {
            return
        }

        guard outboundCentralConnections.count < BleTransport.maxActiveConnections else {
            return
        }

        let conn = BleConnection(peerId: p.identifier)
        outboundCentralConnections[p.identifier] = conn
        connectedPeripherals[p.identifier] = p
        p.delegate = self
        c.connect(p, options: nil)
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([BleTransport.serviceUuid])
        delegate?.transportDidConnect(peerId: p.identifier)
    }

    public func centralManager(_ c: CBCentralManager,
                               didDisconnectPeripheral p: CBPeripheral,
                               error: Error?) {
        transportLock.lock()
        inboxCharacteristics.removeValue(forKey: p.identifier)
        linkInfoCharacteristics.removeValue(forKey: p.identifier)
        pendingInitiatorRemoteHints.removeValue(forKey: p.identifier)
        pendingOutboundWrites.removeValue(forKey: p.identifier)
        if let conn = outboundCentralConnections.removeValue(forKey: p.identifier) {
            conn.markDisconnected()
        }
        connectedPeripherals.removeValue(forKey: p.identifier)
        transportLock.unlock()

        delegate?.transportDidDisconnect(peerId: p.identifier)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { return }
        p.services?.forEach {
            p.discoverCharacteristics(
                [BleTransport.inboxCharacteristicUuid, BleTransport.digestCharacteristicUuid, BleTransport.linkInfoCharacteristicUuid],
                for: $0
            )
        }
    }

    public func peripheral(_ p: CBPeripheral,
                            didDiscoverCharacteristicsFor service: CBService,
                            error: Error?) {
        guard error == nil else { return }
        transportLock.lock()
        for ch in service.characteristics ?? [] {
            if ch.uuid == BleTransport.inboxCharacteristicUuid {
                inboxCharacteristics[p.identifier] = ch
            } else if ch.uuid == BleTransport.linkInfoCharacteristicUuid {
                linkInfoCharacteristics[p.identifier] = ch
            }
        }

        guard let linkInfoChar = linkInfoCharacteristics[p.identifier] else {
            transportLock.unlock()
            central.cancelPeripheralConnection(p)
            return
        }

        outboundCentralConnections[p.identifier]?.transitionTo(.linkInfoReading)
        transportLock.unlock()

        // Read remote LinkInfo characteristic to evaluate role election
        p.readValue(for: linkInfoChar)
    }

    public func peripheral(_ p: CBPeripheral,
                            didUpdateValueFor ch: CBCharacteristic,
                            error: Error?) {
        guard error == nil, let raw = ch.value else { return }

        if ch.uuid == BleTransport.linkInfoCharacteristicUuid {
            transportLock.lock()
            guard raw.count == BleLinkInfoConstants.linkInfoBytes else {
                transportLock.unlock()
                central.cancelPeripheralConnection(p)
                return
            }

            let action = roleCoordinator.processCentralEvent(
                .remoteLinkInfoReadRaw(p.identifier, raw)
            )

            switch action {
            case .writeLocalLinkInfo(let peerId, let remoteHint):
                pendingInitiatorRemoteHints[peerId] = remoteHint
                outboundCentralConnections[peerId]?.transitionTo(.linkInfoWriting)
                let localData = getLocalLinkInfoData()
                transportLock.unlock()

                guard let data = localData, data.count == BleLinkInfoConstants.linkInfoBytes else {
                    central.cancelPeripheralConnection(p)
                    return
                }
                // Write local LinkInfo with response (acknowledged write)
                p.writeValue(data, for: ch, type: .withResponse)

            case .cancelWrongDirectionLink, .reset:
                transportLock.unlock()
                central.cancelPeripheralConnection(p)

            default:
                transportLock.unlock()
                central.cancelPeripheralConnection(p)
            }
            return
        }

        if ch.uuid == BleTransport.inboxCharacteristicUuid {
            transportLock.lock()
            guard let conn = outboundCentralConnections[p.identifier], conn.isRoleBound else {
                transportLock.unlock()
                return
            }
            guard let record = conn.ingestInboundAttValue(raw) else {
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
            guard error == nil else {
                transportLock.unlock()
                central.cancelPeripheralConnection(p)
                return
            }

            guard let remoteHint = pendingInitiatorRemoteHints.removeValue(forKey: p.identifier),
                  let conn = outboundCentralConnections[p.identifier],
                  let inboxChar = inboxCharacteristics[p.identifier] else {
                transportLock.unlock()
                central.cancelPeripheralConnection(p)
                return
            }

            // Role binding succeeds upon LinkInfo write acknowledgment
            conn.bindRole(hint: remoteHint, role: .initiator)
            p.setNotifyValue(true, for: inboxChar)
            conn.isNotificationSubscribed = true

            let maxWrite = p.maximumWriteValueLength(for: .withoutResponse)
            conn.markConnected(negotiatedAttValueLength: maxWrite)
            transportLock.unlock()
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
            guard let data = getLocalLinkInfoData(), data.count == BleLinkInfoConstants.linkInfoBytes else {
                pm.respond(to: request, withResult: .unlikelyError)
                return
            }
            request.value = data
            pm.respond(to: request, withResult: .success)
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

                transportLock.lock()
                let action = roleCoordinator.processPeripheralLinkInfoWrite(peerId: centralId, rawBytes: v)
                switch action {
                case .acceptIncomingWrite(_, let remoteHint):
                    var conn = inboundPeripheralConnections[centralId]
                    if conn == nil || !(conn?.isActive ?? false) {
                        conn = BleConnection(peerId: centralId)
                        inboundPeripheralConnections[centralId] = conn
                    }
                    if !(conn?.isRoleBound ?? false) {
                        conn?.bindRole(hint: remoteHint, role: .responder)
                    }
                    transportLock.unlock()
                    pm.respond(to: r, withResult: .success)
                default:
                    transportLock.unlock()
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
        transportLock.lock()
        subscribedCentrals[central.identifier] = central
        if let conn = inboundPeripheralConnections[central.identifier] {
            conn.isNotificationSubscribed = true
            let maxUpdate = central.maximumUpdateValueLength
            conn.markConnected(negotiatedAttValueLength: maxUpdate)
        }
        transportLock.unlock()
    }

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  central: CBCentral,
                                  didUnsubscribeFrom ch: CBCharacteristic) {
        transportLock.lock()
        subscribedCentrals.removeValue(forKey: central.identifier)
        pendingOutboundUpdates.removeValue(forKey: central.identifier)
        if let conn = inboundPeripheralConnections.removeValue(forKey: central.identifier) {
            conn.markDisconnected()
        }
        transportLock.unlock()
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
    func transportReady(peerId: UUID)
    func transportDidDisconnect(peerId: UUID)
    func transportDidReceive(data: Data, peerId: UUID)
}
