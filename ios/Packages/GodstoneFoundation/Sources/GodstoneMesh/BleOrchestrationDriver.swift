import Foundation
import GodstoneCore

/// Authoritative production orchestration driver for BLE link state transitions, capacity bounding,
/// role election, and callback correlation on iOS (ADR-002, Phase C8.4D1-R2.3).
///
/// Used by production BleTransport and driven directly by host orchestration tests.

public enum BleCentralAction: Equatable, Sendable {
    case connectPeripheral(UUID)
    case discoverServices(UUID)
    case readLinkInfo(UUID)
    case writeLinkInfo(UUID, Data, Data)
    case setNotify(UUID)
    case disconnectPeripheral(UUID, String)
    case physicalDuplexReady(UUID, Int?)
    case didDisconnect(UUID)
    case noOp
}

public final class BleCentralOrchestrationDriver: @unchecked Sendable {
    public let localHint: Data
    public let localLinkInfoProvider: @Sendable () -> Data?
    public let maxActiveConnections: Int

    private var activeConnections: [UUID: BleConnection] = [:]
    private var discoveredHints: [UUID: Data] = [:]
    private var peerRssi: [UUID: Int] = [:]
    private var physicalReadyPeers: Set<UUID> = []
    private let lock = NSLock()

    public init(
        localHint: Data,
        localLinkInfoProvider: @escaping @Sendable () -> Data?,
        maxActiveConnections: Int = BleTransport.maxActiveConnections
    ) {
        precondition(localHint.count == BleRoleElection.nodeHintBytes, "localHint must be 4 bytes")
        self.localHint = localHint
        self.localLinkInfoProvider = localLinkInfoProvider
        self.maxActiveConnections = maxActiveConnections
    }

    public func getActiveConnection(_ peerId: UUID) -> BleConnection? {
        lock.lock()
        defer { lock.unlock() }
        return activeConnections[peerId]
    }

    public func getActiveConnectionCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeConnections.count
    }

    public func isPhysicalReady(_ peerId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return physicalReadyPeers.contains(peerId)
    }

    public func onDiscover(peerId: UUID, rssi: Int?, serviceDataHint: Data?) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        if let hint = serviceDataHint, hint.count == BleRoleElection.nodeHintBytes {
            discoveredHints[peerId] = hint
        }
        if let r = rssi {
            peerRssi[peerId] = r
        }

        if let existing = activeConnections[peerId], existing.isActive {
            return .noOp
        }

        if activeConnections.count >= maxActiveConnections {
            return .noOp
        }

        let conn = BleConnection(peerId: peerId)
        activeConnections[peerId] = conn
        return .connectPeripheral(peerId)
    }

    public func onConnected(peerId: UUID) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        guard conn.state == .provisionalConnecting else { return .noOp }
        conn.transitionTo(.provisionalConnected)
        return .discoverServices(peerId)
    }

    public func onServicesDiscovered(peerId: UUID, success: Bool) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        if !success {
            conn.transitionTo(.closed)
            activeConnections.removeValue(forKey: peerId)
            return .disconnectPeripheral(peerId, "Service discovery failed")
        }
        guard conn.state == .provisionalConnected else { return .noOp }
        conn.transitionTo(.linkInfoReading)
        return .readLinkInfo(peerId)
    }

    public func onLinkInfoReadResult(peerId: UUID, rawData: Data?) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        guard conn.state == .linkInfoReading else { return .noOp }

        guard let data = rawData, data.count == BleLinkInfoConstants.linkInfoBytes else {
            conn.transitionTo(.closed)
            activeConnections.removeValue(forKey: peerId)
            return .disconnectPeripheral(peerId, "Malformed or missing LinkInfo")
        }

        guard let remoteInfo = BleLinkInfoCodec.decode(data) else {
            conn.transitionTo(.closed)
            activeConnections.removeValue(forKey: peerId)
            return .disconnectPeripheral(peerId, "Malformed LinkInfo payload")
        }

        let election = BleRoleElection.elect(localHint: localHint, remoteHint: remoteInfo.nodeHint)
        switch election {
        case .elected(let role):
            if role == .initiator {
                guard let localData = localLinkInfoProvider(), localData.count == BleLinkInfoConstants.linkInfoBytes else {
                    conn.transitionTo(.closed)
                    activeConnections.removeValue(forKey: peerId)
                    return .disconnectPeripheral(peerId, "Local LinkInfo unavailable")
                }
                conn.transitionTo(.linkInfoWriting)
                return .writeLinkInfo(peerId, localData, remoteInfo.nodeHint)
            } else {
                // Local > remote: We are responder; central link is wrong direction
                conn.transitionTo(.closed)
                activeConnections.removeValue(forKey: peerId)
                return .disconnectPeripheral(peerId, "Elected RESPONDER on central link")
            }
        case .tie, .invalid:
            conn.transitionTo(.closed)
            activeConnections.removeValue(forKey: peerId)
            return .disconnectPeripheral(peerId, "Role election tie or invalid")
        }
    }

    public func onLinkInfoWriteAcknowledged(peerId: UUID, success: Bool, remoteHint: Data) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        guard conn.state == .linkInfoWriting else { return .noOp }

        if !success {
            conn.transitionTo(.closed)
            activeConnections.removeValue(forKey: peerId)
            return .disconnectPeripheral(peerId, "LinkInfo write failed")
        }

        conn.bindInitiatorAfterLinkInfoWriteAck(remoteHint: remoteHint)
        return .setNotify(peerId)
    }

    public func onNotificationStateUpdated(peerId: UUID, success: Bool, isNotifying: Bool) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        guard conn.isRoleBound else { return .noOp }

        if !success || !isNotifying {
            conn.transitionTo(.closed)
            activeConnections.removeValue(forKey: peerId)
            return .disconnectPeripheral(peerId, "Notification subscribe failed")
        }

        conn.isNotificationSubscribed = true
        if conn.isHandshakeTransportReady && !physicalReadyPeers.contains(peerId) {
            physicalReadyPeers.insert(peerId)
            return .physicalDuplexReady(peerId, peerRssi[peerId])
        }
        return .noOp
    }

    public func onDisconnected(peerId: UUID) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        activeConnections.removeValue(forKey: peerId)
        let wasReady = physicalReadyPeers.remove(peerId) != nil
        if wasReady {
            return .didDisconnect(peerId)
        }
        return .noOp
    }
}

public enum BlePeripheralAction: Equatable, Sendable {
    case admitCentral(UUID)
    case rejectCentral(UUID)
    case sendReadResponse(UUID, Data)
    case rejectRead(UUID)
    case acceptWrite(UUID, Data)
    case acceptWriteAndDuplexReady(UUID, Data)
    case rejectWrite(UUID, String)
    case acceptSubscription(UUID)
    case acceptSubscriptionAndDuplexReady(UUID)
    case rejectSubscription(UUID)
    case noOp
}

public final class BlePeripheralOrchestrationDriver: @unchecked Sendable {
    public let localHint: Data
    public let localLinkInfoProvider: @Sendable () -> Data?
    public let maxAdmittedCentrals: Int

    private var admittedCentrals: Set<UUID> = []
    private var subscribedCentrals: Set<UUID> = []
    private var inboundConnections: [UUID: BleConnection] = [:]
    private var physicalReadyCentrals: Set<UUID> = []
    private let lock = NSLock()

    public init(
        localHint: Data,
        localLinkInfoProvider: @escaping @Sendable () -> Data?,
        maxAdmittedCentrals: Int = BleTransport.maxActiveConnections
    ) {
        precondition(localHint.count == BleRoleElection.nodeHintBytes, "localHint must be 4 bytes")
        self.localHint = localHint
        self.localLinkInfoProvider = localLinkInfoProvider
        self.maxAdmittedCentrals = maxAdmittedCentrals
    }

    public func getAdmittedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return admittedCentrals.count
    }

    public func isCentralAdmitted(_ centralId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return admittedCentrals.contains(centralId)
    }

    public func isCentralSubscribed(_ centralId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscribedCentrals.contains(centralId)
    }

    public func getInboundConnection(_ centralId: UUID) -> BleConnection? {
        lock.lock()
        defer { lock.unlock() }
        return inboundConnections[centralId]
    }

    public func onCentralConnected(_ centralId: UUID) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }
        if admittedCentrals.contains(centralId) {
            return .admitCentral(centralId)
        }

        if admittedCentrals.count >= maxAdmittedCentrals {
            return .rejectCentral(centralId)
        }

        admittedCentrals.insert(centralId)
        let conn = BleConnection(peerId: centralId)
        conn.transitionTo(.provisionalConnected)
        inboundConnections[centralId] = conn
        return .admitCentral(centralId)
    }

    public func onCentralDisconnected(_ centralId: UUID) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }
        admittedCentrals.remove(centralId)
        subscribedCentrals.remove(centralId)
        let conn = inboundConnections.removeValue(forKey: centralId)
        conn?.transitionTo(.closed)
        physicalReadyCentrals.remove(centralId)
        return .noOp
    }

    public func onLinkInfoReadRequest(centralId: UUID) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }
        guard admittedCentrals.contains(centralId) else {
            return .rejectRead(centralId)
        }
        guard let data = localLinkInfoProvider(), data.count == BleLinkInfoConstants.linkInfoBytes else {
            return .rejectRead(centralId)
        }
        return .sendReadResponse(centralId, data)
    }

    public func onLinkInfoWriteRequest(centralId: UUID, rawData: Data) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }
        guard admittedCentrals.contains(centralId) else {
            return .rejectWrite(centralId, "Unadmitted central")
        }
        guard let conn = inboundConnections[centralId] else {
            return .rejectWrite(centralId, "No inbound connection")
        }
        guard conn.state == .provisionalConnected else {
            return .rejectWrite(centralId, "Connection is not in provisionalConnected")
        }

        guard let remoteInfo = BleLinkInfoCodec.decode(rawData) else {
            return .rejectWrite(centralId, "Malformed LinkInfo payload")
        }

        let election = BleRoleElection.elect(localHint: localHint, remoteHint: remoteInfo.nodeHint)
        switch election {
        case .elected(let role):
            if role == .responder {
                conn.bindResponderFromAcceptedIncomingLinkInfo(remoteHint: remoteInfo.nodeHint)
                if subscribedCentrals.contains(centralId) {
                    conn.isNotificationSubscribed = true
                }
                if conn.isHandshakeTransportReady && !physicalReadyCentrals.contains(centralId) {
                    physicalReadyCentrals.insert(centralId)
                    return .acceptWriteAndDuplexReady(centralId, remoteInfo.nodeHint)
                }
                return .acceptWrite(centralId, remoteInfo.nodeHint)
            } else {
                return .rejectWrite(centralId, "Central is not initiator")
            }
        case .tie, .invalid:
            return .rejectWrite(centralId, "Role election tie or invalid")
        }
    }

    public func onSubscriptionUpdate(centralId: UUID, isSubscribed: Bool) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }
        guard admittedCentrals.contains(centralId) else {
            return .rejectSubscription(centralId)
        }
        guard let conn = inboundConnections[centralId] else {
            return .rejectSubscription(centralId)
        }

        if isSubscribed {
            subscribedCentrals.insert(centralId)
            conn.isNotificationSubscribed = true
        } else {
            subscribedCentrals.remove(centralId)
            conn.isNotificationSubscribed = false
        }

        if conn.isHandshakeTransportReady && !physicalReadyCentrals.contains(centralId) {
            physicalReadyCentrals.insert(centralId)
            return .acceptSubscriptionAndDuplexReady(centralId)
        }
        return .acceptSubscription(centralId)
    }
}
