import Foundation
import GodstoneCore

/// Authoritative production orchestration driver for BLE link state transitions, capacity bounding,
/// role election, and callback correlation on iOS (ADR-002, Phase C8.4D1-R2.3).
///
/// Used by production BleTransport and driven directly by host orchestration tests.

public final class BleGlobalCapacityAuthority: @unchecked Sendable {
    public private(set) var outboundCount: Int = 0
    public private(set) var inboundCount: Int = 0
    public let maxTotalPeers: Int
    private let lock = NSLock()

    public init(maxTotalPeers: Int = 7) {
        self.maxTotalPeers = maxTotalPeers
    }

    public func tryAdmitOutbound() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if outboundCount + inboundCount < maxTotalPeers {
            outboundCount += 1
            return true
        }
        return false
    }

    public func tryAdmitInbound() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if outboundCount + inboundCount < maxTotalPeers {
            inboundCount += 1
            return true
        }
        return false
    }

    public func releaseOutbound() {
        lock.lock()
        defer { lock.unlock() }
        if outboundCount > 0 { outboundCount -= 1 }
    }

    public func releaseInbound() {
        lock.lock()
        defer { lock.unlock() }
        if inboundCount > 0 { inboundCount -= 1 }
    }
}

public enum BleCentralAction: Equatable, Sendable {
    case connectPeripheral(UUID)
    case discoverServices(UUID)
    case discoverCharacteristics(UUID)
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
    public let capacityAuthority: BleGlobalCapacityAuthority?

    private var activeConnections: [UUID: BleConnection] = [:]
    private var discoveredHints: [UUID: Data] = [:]
    private var peerRssi: [UUID: Int] = [:]
    private var physicalReadyPeers: Set<UUID> = []
    private let lock = NSLock()

    public init(
        localHint: Data,
        localLinkInfoProvider: @escaping @Sendable () -> Data?,
        capacityAuthority: BleGlobalCapacityAuthority? = nil
    ) {
        precondition(localHint.count == BleRoleElection.nodeHintBytes, "localHint must be 4 bytes")
        self.localHint = localHint
        self.localLinkInfoProvider = localLinkInfoProvider
        self.capacityAuthority = capacityAuthority
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

    private func removeConnection(_ peerId: UUID) {
        activeConnections.removeValue(forKey: peerId)
        capacityAuthority?.releaseOutbound()
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

        if let cap = capacityAuthority {
            guard cap.tryAdmitOutbound() else { return .noOp }
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

    public func onFailedToConnect(peerId: UUID, error: Error?) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        if let conn = activeConnections[peerId] {
            conn.transitionTo(.closed)
            removeConnection(peerId)
        }
        return .disconnectPeripheral(peerId, "Failed to connect")
    }

    public func onServicesDiscovered(peerId: UUID, success: Bool) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        if !success {
            conn.transitionTo(.closed)
            removeConnection(peerId)
            return .disconnectPeripheral(peerId, "Service discovery failed")
        }
        guard conn.state == .provisionalConnected else { return .noOp }
        return .discoverCharacteristics(peerId)
    }

    public func onCharacteristicsDiscovered(peerId: UUID, success: Bool) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        if !success {
            conn.transitionTo(.closed)
            removeConnection(peerId)
            return .disconnectPeripheral(peerId, "Characteristics discovery failed")
        }
        guard conn.state == .provisionalConnected else { return .noOp }
        conn.transitionTo(.linkInfoReading)
        return .readLinkInfo(peerId)
    }

    public func onLinkInfoReadResult(peerId: UUID, success: Bool, rawData: Data?) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        guard conn.state == .linkInfoReading else { return .noOp }
        
        if !success {
            conn.transitionTo(.closed)
            removeConnection(peerId)
            return .disconnectPeripheral(peerId, "LinkInfo read failed")
        }

        guard let data = rawData, data.count == BleLinkInfoConstants.linkInfoBytes else {
            conn.transitionTo(.closed)
            removeConnection(peerId)
            return .disconnectPeripheral(peerId, "Malformed or missing LinkInfo")
        }

        guard let remoteInfo = BleLinkInfoCodec.decode(data) else {
            conn.transitionTo(.closed)
            removeConnection(peerId)
            return .disconnectPeripheral(peerId, "Malformed LinkInfo payload")
        }

        let election = BleRoleElection.elect(localHint: localHint, remoteHint: remoteInfo.nodeHint)
        switch election {
        case .elected(let role):
            if role == .initiator {
                guard let localData = localLinkInfoProvider(), localData.count == BleLinkInfoConstants.linkInfoBytes else {
                    conn.transitionTo(.closed)
                    removeConnection(peerId)
                    return .disconnectPeripheral(peerId, "Local LinkInfo unavailable")
                }
                conn.transitionTo(.linkInfoWriting)
                return .writeLinkInfo(peerId, localData, remoteInfo.nodeHint)
            } else {
                // Local > remote: We are responder; central link is wrong direction
                conn.transitionTo(.closed)
                removeConnection(peerId)
                return .disconnectPeripheral(peerId, "Elected RESPONDER on central link")
            }
        case .tie, .invalid:
            conn.transitionTo(.closed)
            removeConnection(peerId)
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
            removeConnection(peerId)
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
            removeConnection(peerId)
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
        
        let existing = activeConnections[peerId]
        if existing != nil {
            removeConnection(peerId)
        }
        
        let wasReady = physicalReadyPeers.remove(peerId) != nil
        if wasReady || existing != nil {
            return .didDisconnect(peerId)
        }
        return .noOp
    }
}

public enum BlePeripheralAction: Equatable, Sendable {
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
    public let capacityAuthority: BleGlobalCapacityAuthority?

    private var admittedCentrals: Set<UUID> = []
    private var subscribedCentrals: Set<UUID> = []
    private var inboundConnections: [UUID: BleConnection] = [:]
    private var physicalReadyCentrals: Set<UUID> = []
    private let lock = NSLock()

    public init(
        localHint: Data,
        localLinkInfoProvider: @escaping @Sendable () -> Data?,
        capacityAuthority: BleGlobalCapacityAuthority? = nil
    ) {
        precondition(localHint.count == BleRoleElection.nodeHintBytes, "localHint must be 4 bytes")
        self.localHint = localHint
        self.localLinkInfoProvider = localLinkInfoProvider
        self.capacityAuthority = capacityAuthority
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

    private func ensureAdmitted(centralId: UUID) -> Bool {
        if admittedCentrals.contains(centralId) {
            return true
        }
        if let cap = capacityAuthority {
            if !cap.tryAdmitInbound() {
                return false
            }
        }
        admittedCentrals.insert(centralId)
        let conn = BleConnection(peerId: centralId)
        conn.transitionTo(.provisionalConnected)
        inboundConnections[centralId] = conn
        return true
    }
    
    private func removeAdmitted(centralId: UUID) {
        if admittedCentrals.contains(centralId) {
            admittedCentrals.remove(centralId)
            capacityAuthority?.releaseInbound()
        }
    }

    public func onCentralRead(centralId: UUID) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }
        
        guard ensureAdmitted(centralId: centralId) else {
            return .rejectRead(centralId)
        }
        
        guard let data = localLinkInfoProvider(), data.count == BleLinkInfoConstants.linkInfoBytes else {
            return .rejectRead(centralId)
        }
        return .sendReadResponse(centralId, data)
    }

    public func onCentralWrite(centralId: UUID, rawData: Data) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }
        
        guard ensureAdmitted(centralId: centralId) else {
            return .rejectWrite(centralId, "Capacity exhausted")
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

    public func onCentralSubscribed(centralId: UUID) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }
        
        guard ensureAdmitted(centralId: centralId) else {
            return .rejectSubscription(centralId)
        }
        
        guard let conn = inboundConnections[centralId] else {
            return .rejectSubscription(centralId)
        }

        subscribedCentrals.insert(centralId)
        conn.isNotificationSubscribed = true

        if conn.isHandshakeTransportReady && !physicalReadyCentrals.contains(centralId) {
            physicalReadyCentrals.insert(centralId)
            return .acceptSubscriptionAndDuplexReady(centralId)
        }
        return .acceptSubscription(centralId)
    }
    
    public func onCentralUnsubscribed(centralId: UUID) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }
        
        subscribedCentrals.remove(centralId)
        if let conn = inboundConnections.removeValue(forKey: centralId) {
            conn.transitionTo(.closed)
        }
        removeAdmitted(centralId: centralId)
        physicalReadyCentrals.remove(centralId)
        return .noOp
    }

    public func onReadyToUpdateSubscribers() -> BlePeripheralAction {
        return .noOp
    }
}
