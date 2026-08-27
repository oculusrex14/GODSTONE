import Foundation
import CoreBluetooth

/// BLE control plane. Always on, duty-cycled, background-capable (with the
/// caveats documented below and surfaced in the UI).
///
/// Persistent duplex BLE link substrate and role election (ADR-002, Phase C8.4D1).
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

    public var identity: MeshIdentity?

    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private var inboxCharacteristics: [UUID: CBCharacteristic] = [:]
    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var mutableInboxCharacteristic: CBMutableCharacteristic?

    // Discovered peer metadata cache
    private var discoveredPeers: [UUID: BleDiscoveryMetadata] = [:]

    // Active connection state abstractions
    private var activeConnections: [UUID: BleConnection] = [:]

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

    public init(identity: MeshIdentity? = nil) {
        self.identity = identity
        super.init()
        #if targetEnvironment(simulator)
        central = CBCentralManager(delegate: self, queue: .global(qos: .utility))
        peripheral = CBPeripheralManager(delegate: self, queue: .global(qos: .utility))
        #else
        central = CBCentralManager(delegate: self, queue: .global(qos: .utility), options: [CBCentralManagerOptionRestoreIdentifierKey: "io.godstone.central"])
        peripheral = CBPeripheralManager(delegate: self, queue: .global(qos: .utility), options: [CBPeripheralManagerOptionRestoreIdentifierKey: "io.godstone.peripheral"])
        #endif
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
        subscribedCentrals.removeAll()

        for (_, conn) in activeConnections {
            conn.markDisconnected()
        }
        activeConnections.removeAll()
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
        return activeConnections[peerId]
    }

    public func discoveryMetadata(for peerId: UUID) -> BleDiscoveryMetadata? {
        transportLock.lock()
        defer { transportLock.unlock() }
        return discoveredPeers[peerId]
    }

    /// Send [frame] to [peerId] through the Noise session and BleRecord layer.
    @discardableResult
    public func send(_ frame: FrameV2, to peerId: UUID) -> Bool {
        transportLock.lock()
        guard let conn = activeConnections[peerId], conn.isActive else {
            transportLock.unlock()
            return false
        }
        guard let sealed = sessions?.seal(peerId, frame.encode()) else {
            transportLock.unlock()
            return false
        }

        let fragments = conn.fragmentOutbound(recordType: .data, payload: sealed)
        guard !fragments.isEmpty else {
            transportLock.unlock()
            return false
        }

        if conn.localRole == .initiator {
            guard let p = connectedPeripherals[peerId],
                  let ch = inboxCharacteristics[peerId] else {
                transportLock.unlock()
                return false
            }

            var queue = pendingOutboundWrites[peerId] ?? []
            if !queue.isEmpty || !p.canSendWriteWithoutResponse {
                if queue.count + fragments.count > BleTransport.maxQueuedAttValues {
                    transportLock.unlock()
                    return false // Bound overflow: fail-closed
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
                        return false // Bound overflow: fail-closed
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

    private func getOrCreateConnection(
        peerId: UUID,
        remoteNodeHint: Data,
        localRole: BleRole
    ) -> BleConnection? {
        if let existing = activeConnections[peerId], existing.isActive {
            return existing
        }
        guard activeConnections.count < BleTransport.maxActiveConnections || activeConnections[peerId] != nil else {
            return nil
        }
        let conn = BleConnection(
            peerId: peerId,
            remoteNodeHint: remoteNodeHint,
            localRole: localRole
        )
        activeConnections[peerId] = conn
        return conn
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

        var metadata: BleDiscoveryMetadata? = nil
        if let serviceDataDict = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
           let rawPayload = serviceDataDict[BleTransport.serviceUuid] {
            metadata = BleDiscoveryCodec.decode(rawPayload)
        }

        // Role Election Authority: require actual discovered metadata and local identity
        guard let meta = metadata, let localHint = identity?.nodeHint else {
            // Missing discovery metadata or local identity: fail-closed, do NOT connect!
            return
        }

        if discoveredPeers.count >= BleTransport.maxDiscoveredPeers && discoveredPeers[p.identifier] == nil {
            if let oldest = discoveredPeers.keys.first {
                discoveredPeers.removeValue(forKey: oldest)
            }
        }
        discoveredPeers[p.identifier] = meta

        let election = BleRoleElection.elect(localHint: localHint, remoteHint: meta.nodeHint)
        switch election {
        case .elected(let role):
            _ = getOrCreateConnection(peerId: p.identifier, remoteNodeHint: meta.nodeHint, localRole: role)
            if role == .initiator {
                connectedPeripherals[p.identifier] = p
                p.delegate = self
                c.connect(p, options: nil)
            }
            // If responder: do NOT connect as central; wait for peer connection.
        case .tie, .invalid:
            // Equal hint or invalid: fail closed! Do NOT connect!
            break
        }
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
        pendingOutboundWrites.removeValue(forKey: p.identifier)
        if let conn = activeConnections.removeValue(forKey: p.identifier) {
            conn.markDisconnected()
        }
        connectedPeripherals.removeValue(forKey: p.identifier)
        transportLock.unlock()

        delegate?.transportDidDisconnect(peerId: p.identifier)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        p.services?.forEach {
            p.discoverCharacteristics(
                [BleTransport.inboxCharacteristicUuid, BleTransport.digestCharacteristicUuid],
                for: $0
            )
        }
    }

    public func peripheral(_ p: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        transportLock.lock()
        for ch in service.characteristics ?? [] {
            if ch.uuid == BleTransport.inboxCharacteristicUuid {
                inboxCharacteristics[p.identifier] = ch
                p.setNotifyValue(true, for: ch)

                let maxWrite = p.maximumWriteValueLength(for: .withoutResponse)
                activeConnections[p.identifier]?.markConnected(negotiatedAttValueLength: maxWrite)
            }
        }
        transportLock.unlock()

        delegate?.transportReady(peerId: p.identifier)
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

    public func peripheral(_ p: CBPeripheral,
                           didUpdateValueFor ch: CBCharacteristic,
                           error: Error?) {
        guard let raw = ch.value else { return }

        transportLock.lock()
        guard let conn = activeConnections[p.identifier] else {
            transportLock.unlock()
            return
        }
        guard let record = conn.ingestInboundAttValue(raw) else {
            transportLock.unlock()
            return
        }
        transportLock.unlock()

        if record.recordType == .data {
            guard let clear = sessions?.open(p.identifier, record.payload) else { return }
            delegate?.transportDidReceive(data: clear, peerId: p.identifier)
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

        let service = CBMutableService(type: BleTransport.serviceUuid, primary: true)
        service.characteristics = [inbox, digest]
        pm.add(service)

        mutableInboxCharacteristic = inbox
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
        // State restoration hook for peripheral manager
    }

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }

        for r in requests {
            guard let v = r.value else { continue }
            let centralId = r.central.identifier

            transportLock.lock()
            let conn = activeConnections[centralId]
            let record = conn?.ingestInboundAttValue(v)
            transportLock.unlock()

            if let rec = record, rec.recordType == .data {
                if let clear = sessions?.open(centralId, rec.payload) {
                    delegate?.transportDidReceive(data: clear, peerId: centralId)
                }
            }
        }
        pm.respond(to: first, withResult: .success)
    }

    public func peripheralManager(_ pm: CBPeripheralManager,
                                  central: CBCentral,
                                  didSubscribeTo ch: CBCharacteristic) {
        transportLock.lock()
        subscribedCentrals[central.identifier] = central
        if let conn = activeConnections[central.identifier] {
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
        if let conn = activeConnections.removeValue(forKey: central.identifier) {
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
