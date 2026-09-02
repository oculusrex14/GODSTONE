import Foundation
import GodstoneCore

/// Authoritative production orchestration driver for BLE link state transitions, capacity bounding,
/// role election, and callback correlation on iOS (ADR-002, Phase C8.4D1-R2.6).
///
/// Used by production BleTransport and driven directly by host orchestration tests.

public enum BleDirection: String, Sendable {
    case outboundCentral
    case inboundPeripheral
}

public struct RelationKey: Hashable, Sendable {
    public let direction: BleDirection
    public let peerId: UUID
    public let generation: UInt64

    public init(direction: BleDirection, peerId: UUID, generation: UInt64 = 0) {
        self.direction = direction
        self.peerId = peerId
        self.generation = generation
    }
}

public struct CapacityLease: Equatable, Hashable, Sendable {
    public let direction: BleDirection
    public let peerId: UUID
    public let generation: UInt64
    public let leaseId: UInt64

    public init(direction: BleDirection, peerId: UUID, generation: UInt64, leaseId: UInt64) {
        self.direction = direction
        self.peerId = peerId
        self.generation = generation
        self.leaseId = leaseId
    }
}

public final class BleGlobalCapacityAuthority: @unchecked Sendable {
    public let maxTotalPeers: Int
    private var outboundLeases: [UUID: CapacityLease] = [:]
    private var inboundLeases: [UUID: CapacityLease] = [:]
    private var leaseIdCounter: UInt64 = 1
    private let lock = NSLock()

    public var outboundCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outboundLeases.count
    }

    public var inboundCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inboundLeases.count
    }

    public var totalCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outboundLeases.count + inboundLeases.count
    }

    public init(maxTotalPeers: Int = 7) {
        self.maxTotalPeers = maxTotalPeers
    }

    public func tryAdmitOutbound(peerId: UUID, generation: UInt64 = 0) -> CapacityLease? {
        lock.lock()
        defer { lock.unlock() }
        if outboundLeases[peerId] != nil {
            let leaseId = leaseIdCounter
            leaseIdCounter += 1
            let updated = CapacityLease(direction: .outboundCentral, peerId: peerId, generation: generation, leaseId: leaseId)
            outboundLeases[peerId] = updated
            return updated
        }
        if outboundLeases.count + inboundLeases.count < maxTotalPeers {
            let leaseId = leaseIdCounter
            leaseIdCounter += 1
            let lease = CapacityLease(direction: .outboundCentral, peerId: peerId, generation: generation, leaseId: leaseId)
            outboundLeases[peerId] = lease
            return lease
        }
        return nil
    }

    public func tryAdmitInbound(peerId: UUID, generation: UInt64 = 0) -> CapacityLease? {
        lock.lock()
        defer { lock.unlock() }
        if inboundLeases[peerId] != nil {
            let leaseId = leaseIdCounter
            leaseIdCounter += 1
            let updated = CapacityLease(direction: .inboundPeripheral, peerId: peerId, generation: generation, leaseId: leaseId)
            inboundLeases[peerId] = updated
            return updated
        }
        if outboundLeases.count + inboundLeases.count < maxTotalPeers {
            let leaseId = leaseIdCounter
            leaseIdCounter += 1
            let lease = CapacityLease(direction: .inboundPeripheral, peerId: peerId, generation: generation, leaseId: leaseId)
            inboundLeases[peerId] = lease
            return lease
        }
        return nil
    }

    public func tryAdmitOutbound() -> Bool {
        return tryAdmitOutbound(peerId: UUID()) != nil
    }

    public func tryAdmitInbound() -> Bool {
        return tryAdmitInbound(peerId: UUID()) != nil
    }

    public func releaseOutbound() {
        lock.lock()
        defer { lock.unlock() }
        if let first = outboundLeases.keys.first {
            outboundLeases.removeValue(forKey: first)
        }
    }

    public func releaseInbound() {
        lock.lock()
        defer { lock.unlock() }
        if let first = inboundLeases.keys.first {
            inboundLeases.removeValue(forKey: first)
        }
    }

    @discardableResult
    public func releaseLease(_ lease: CapacityLease?) -> Bool {
        guard let lease = lease else { return false }
        lock.lock()
        defer { lock.unlock() }
        switch lease.direction {
        case .outboundCentral:
            if let current = outboundLeases[lease.peerId],
               current.leaseId == lease.leaseId && current.generation == lease.generation {
                outboundLeases.removeValue(forKey: lease.peerId)
                return true
            }
            return false
        case .inboundPeripheral:
            if let current = inboundLeases[lease.peerId],
               current.leaseId == lease.leaseId && current.generation == lease.generation {
                inboundLeases.removeValue(forKey: lease.peerId)
                return true
            }
            return false
        }
    }

    public func isLeaseActive(_ lease: CapacityLease?) -> Bool {
        guard let lease = lease else { return false }
        lock.lock()
        defer { lock.unlock() }
        let current = (lease.direction == .outboundCentral) ? outboundLeases[lease.peerId] : inboundLeases[lease.peerId]
        return current != nil && current?.leaseId == lease.leaseId && current?.generation == lease.generation
    }

    public func releaseAllInbound() {
        lock.lock()
        defer { lock.unlock() }
        inboundLeases.removeAll()
    }

    public func releaseAllOutbound() {
        lock.lock()
        defer { lock.unlock() }
        outboundLeases.removeAll()
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        outboundLeases.removeAll()
        inboundLeases.removeAll()
    }
}

public struct BleElectionContext: Sendable {
    public let remoteLinkInfo: BleLinkInfoV1
    public let remoteNodeHint: Data
    public let generation: UInt64

    public init(remoteLinkInfo: BleLinkInfoV1, remoteNodeHint: Data, generation: UInt64) {
        self.remoteLinkInfo = remoteLinkInfo
        self.remoteNodeHint = remoteNodeHint
        self.generation = generation
    }
}

public enum OutboundSlotState: Equatable, Sendable {
    case idle
    case active(UInt64)
    case closing(UInt64)
    case quarantined(UInt64, UInt64) // (transportEpoch, generation)
}

public struct OutboundPeerSlot: Equatable, Sendable {
    public let state: OutboundSlotState
    public let generation: UInt64
    public let peerId: UUID
    public let lease: CapacityLease?

    public init(state: OutboundSlotState, generation: UInt64, peerId: UUID, lease: CapacityLease? = nil) {
        self.state = state
        self.generation = generation
        self.peerId = peerId
        self.lease = lease
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
    private var connectionGenerations: [UUID: UInt64] = [:]
    private var activeLeases: [UUID: CapacityLease] = [:]
    private var electionContexts: [UUID: BleElectionContext] = [:]
    private var discoveredHints: [UUID: Data] = [:]
    private var peerRssi: [UUID: Int] = [:]
    private var physicalReadyPeers: Set<UUID> = []
    private var outboundSlots: [UUID: OutboundPeerSlot] = [:]
    private var transportEpoch: UInt64 = 0
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

    public func startNewTransportEpoch(_ epoch: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        transportEpoch = epoch
        for (_, conn) in activeConnections {
            conn.transitionTo(.closed)
        }
        activeConnections.removeAll()
        activeLeases.removeAll()
        electionContexts.removeAll()
        discoveredHints.removeAll()
        peerRssi.removeAll()
        physicalReadyPeers.removeAll()
        for (peerId, slot) in outboundSlots {
            outboundSlots[peerId] = OutboundPeerSlot(state: .idle, generation: slot.generation, peerId: peerId, lease: nil)
        }
        capacityAuthority?.releaseAllOutbound()
        return transportEpoch
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

    public func getActiveLease(_ peerId: UUID) -> CapacityLease? {
        lock.lock()
        defer { lock.unlock() }
        return activeLeases[peerId]
    }

    public func getElectionContext(_ peerId: UUID) -> BleElectionContext? {
        lock.lock()
        defer { lock.unlock() }
        return electionContexts[peerId]
    }

    public func getConnectionGeneration(_ peerId: UUID) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return connectionGenerations[peerId] ?? 0
    }

    public func isPhysicalReady(_ peerId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return physicalReadyPeers.contains(peerId)
    }

    public func getOutboundSlot(_ peerId: UUID) -> OutboundPeerSlot? {
        lock.lock()
        defer { lock.unlock() }
        return outboundSlots[peerId]
    }

    public func getOutboundSlotState(_ peerId: UUID) -> OutboundSlotState {
        lock.lock()
        defer { lock.unlock() }
        return outboundSlots[peerId]?.state ?? .idle
    }

    private func releaseLeaseLocked(_ peerId: UUID) {
        if let lease = activeLeases.removeValue(forKey: peerId) {
            capacityAuthority?.releaseLease(lease)
        }
    }

    private func removeConnection(_ peerId: UUID) {
        activeConnections.removeValue(forKey: peerId)
        electionContexts.removeValue(forKey: peerId)
        releaseLeaseLocked(peerId)
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

        let slot = outboundSlots[peerId]
        if case .closing = slot?.state {
            return .noOp
        }
        if case .active = slot?.state {
            return .noOp
        }
        if case .quarantined(let qEpoch, _) = slot?.state, qEpoch == transportEpoch {
            return .noOp
        }

        if let existing = activeConnections[peerId], existing.isActive {
            return .noOp
        }

        let nextGen = (connectionGenerations[peerId] ?? 0) + 1
        var lease: CapacityLease? = nil
        if let cap = capacityAuthority {
            guard let l = cap.tryAdmitOutbound(peerId: peerId, generation: nextGen) else {
                return .noOp
            }
            lease = l
            activeLeases[peerId] = l
        } else {
            if activeConnections.count >= BleTransport.maxActiveConnections {
                return .noOp
            }
        }

        connectionGenerations[peerId] = nextGen
        let conn = BleConnection(peerId: peerId)
        activeConnections[peerId] = conn
        outboundSlots[peerId] = OutboundPeerSlot(state: .active(nextGen), generation: nextGen, peerId: peerId, lease: lease)
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
        let gen = connectionGenerations[peerId] ?? 0
        if let conn = activeConnections.removeValue(forKey: peerId) {
            conn.transitionTo(.closed)
        }
        removeConnection(peerId)
        physicalReadyPeers.remove(peerId)
        outboundSlots[peerId] = OutboundPeerSlot(state: .quarantined(transportEpoch, gen), generation: gen, peerId: peerId, lease: nil)
        return .disconnectPeripheral(peerId, error?.localizedDescription ?? "Connection failed")
    }

    public func onServicesDiscovered(peerId: UUID, success: Bool) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        let gen = connectionGenerations[peerId] ?? 0
        if !success {
            conn.transitionTo(.closed)
            removeConnection(peerId)
            outboundSlots[peerId] = OutboundPeerSlot(state: .closing(gen), generation: gen, peerId: peerId, lease: nil)
            return .disconnectPeripheral(peerId, "Service discovery failed")
        }
        guard conn.state == .provisionalConnected else { return .noOp }
        return .discoverCharacteristics(peerId)
    }

    public func onCharacteristicsDiscovered(peerId: UUID, success: Bool) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        let gen = connectionGenerations[peerId] ?? 0
        if !success {
            conn.transitionTo(.closed)
            removeConnection(peerId)
            outboundSlots[peerId] = OutboundPeerSlot(state: .closing(gen), generation: gen, peerId: peerId, lease: nil)
            return .disconnectPeripheral(peerId, "Characteristic discovery failed")
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
        let gen = connectionGenerations[peerId] ?? 0

        guard success, let data = rawData, data.count == BleLinkInfoConstants.linkInfoBytes,
              let remoteInfo = BleLinkInfoCodec.decode(data) else {
            conn.transitionTo(.closed)
            removeConnection(peerId)
            outboundSlots[peerId] = OutboundPeerSlot(state: .closing(gen), generation: gen, peerId: peerId, lease: nil)
            return .disconnectPeripheral(peerId, "Malformed or missing LinkInfo")
        }

        let election = BleRoleElection.elect(localHint: localHint, remoteHint: remoteInfo.nodeHint)
        switch election {
        case .elected(let role):
            if role == .initiator {
                guard let localData = localLinkInfoProvider(), localData.count == BleLinkInfoConstants.linkInfoBytes else {
                    conn.transitionTo(.closed)
                    removeConnection(peerId)
                    outboundSlots[peerId] = OutboundPeerSlot(state: .closing(gen), generation: gen, peerId: peerId, lease: nil)
                    return .disconnectPeripheral(peerId, "Local LinkInfo unavailable")
                }
                electionContexts[peerId] = BleElectionContext(remoteLinkInfo: remoteInfo, remoteNodeHint: remoteInfo.nodeHint, generation: gen)
                conn.transitionTo(.linkInfoWriting)
                return .writeLinkInfo(peerId, localData, remoteInfo.nodeHint)
            } else {
                conn.transitionTo(.closed)
                removeConnection(peerId)
                outboundSlots[peerId] = OutboundPeerSlot(state: .closing(gen), generation: gen, peerId: peerId, lease: nil)
                return .disconnectPeripheral(peerId, "Elected RESPONDER on central link")
            }
        case .tie, .invalid:
            conn.transitionTo(.closed)
            removeConnection(peerId)
            outboundSlots[peerId] = OutboundPeerSlot(state: .closing(gen), generation: gen, peerId: peerId, lease: nil)
            return .disconnectPeripheral(peerId, "Role election tie or invalid")
        }
    }

    public func onLinkInfoWriteAcknowledged(peerId: UUID, success: Bool, remoteHint: Data) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        guard conn.state == .linkInfoWriting else { return .noOp }
        let gen = connectionGenerations[peerId] ?? 0

        if !success {
            conn.transitionTo(.closed)
            removeConnection(peerId)
            outboundSlots[peerId] = OutboundPeerSlot(state: .closing(gen), generation: gen, peerId: peerId, lease: nil)
            return .disconnectPeripheral(peerId, "LinkInfo write failed")
        }

        let hint = electionContexts[peerId]?.remoteNodeHint ?? remoteHint
        conn.bindInitiatorAfterLinkInfoWriteAck(remoteHint: hint)
        return .setNotify(peerId)
    }

    public func onNotificationStateUpdated(peerId: UUID, success: Bool, isNotifying: Bool) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = activeConnections[peerId] else { return .noOp }
        guard conn.isRoleBound else { return .noOp }
        let gen = connectionGenerations[peerId] ?? 0

        if !success || !isNotifying {
            conn.transitionTo(.closed)
            removeConnection(peerId)
            outboundSlots[peerId] = OutboundPeerSlot(state: .closing(gen), generation: gen, peerId: peerId, lease: nil)
            return .disconnectPeripheral(peerId, "Notification subscribe failed")
        }

        conn.isNotificationSubscribed = true
        if conn.isHandshakeTransportReady && !physicalReadyPeers.contains(peerId) {
            physicalReadyPeers.insert(peerId)
            return .physicalDuplexReady(peerId, peerRssi[peerId])
        }
        return .noOp
    }

    public func onProvisionalTimeout(peerId: UUID, expectedGen: UInt64 = 0) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }
        let currentGen = connectionGenerations[peerId] ?? 0
        if expectedGen != 0 && currentGen != expectedGen {
            return .noOp
        }
        if let conn = activeConnections.removeValue(forKey: peerId) {
            conn.transitionTo(.closed)
            electionContexts.removeValue(forKey: peerId)
            releaseLeaseLocked(peerId)
            physicalReadyPeers.remove(peerId)
            outboundSlots[peerId] = OutboundPeerSlot(state: .quarantined(transportEpoch, currentGen), generation: currentGen, peerId: peerId, lease: nil)
            return .disconnectPeripheral(peerId, "Provisional timeout")
        }
        return .noOp
    }

    public func onDisconnected(peerId: UUID, expectedGen: UInt64 = 0) -> BleCentralAction {
        lock.lock()
        defer { lock.unlock() }

        let slot = outboundSlots[peerId]
        let currentGen = slot?.generation ?? (connectionGenerations[peerId] ?? 0)
        if expectedGen != 0 && currentGen != expectedGen {
            return .noOp
        }
        if case .quarantined(let qEpoch, _) = slot?.state, qEpoch == transportEpoch {
            return .noOp
        }

        let existing = activeConnections[peerId]
        if existing != nil {
            removeConnection(peerId)
        }

        let wasReady = physicalReadyPeers.remove(peerId) != nil
        outboundSlots[peerId] = OutboundPeerSlot(state: .quarantined(transportEpoch, currentGen), generation: currentGen, peerId: peerId, lease: nil)
        if wasReady || existing != nil {
            return .didDisconnect(peerId)
        }
        return .noOp
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        for (_, conn) in activeConnections {
            conn.transitionTo(.closed)
        }
        activeConnections.removeAll()
        activeLeases.removeAll()
        electionContexts.removeAll()
        discoveredHints.removeAll()
        peerRssi.removeAll()
        physicalReadyPeers.removeAll()
        outboundSlots.removeAll()
        capacityAuthority?.releaseAllOutbound()
    }
}

public enum InboundSlotState: Equatable, Sendable {
    case idle
    case active(UInt64)
    case closing(UInt64)
    case quarantined(UInt64, UInt64) // (transportEpoch, generation)
}

public struct InboundPeerSlot: Equatable, Sendable {
    public let state: InboundSlotState
    public let generation: UInt64
    public let centralId: UUID
    public let lease: CapacityLease?

    public init(state: InboundSlotState, generation: UInt64, centralId: UUID, lease: CapacityLease? = nil) {
        self.state = state
        self.generation = generation
        self.centralId = centralId
        self.lease = lease
    }
}

public enum BlePeripheralAction: Equatable, Sendable {
    case sendReadResponse(UUID, Data)
    case rejectRead(UUID)
    case acceptWrite(UUID, Data)
    case acceptDuplicateWrite(UUID, Data)
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
    private var centralGenerations: [UUID: UInt64] = [:]
    private var inboundLeases: [UUID: CapacityLease] = [:]
    private var subscribedCentrals: Set<UUID> = []
    private var inboundConnections: [UUID: BleConnection] = [:]
    private var acceptedRemoteLinkInfo: [UUID: BleLinkInfoV1] = [:]
    private var physicalReadyCentrals: Set<UUID> = []
    private var inboundSlots: [UUID: InboundPeerSlot] = [:]
    private var managerEpoch: UInt64 = 0
    private var transportEpoch: UInt64 = 0
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

    public func startNewTransportEpoch(_ epoch: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        transportEpoch = epoch
        managerEpoch = epoch
        for (_, conn) in inboundConnections {
            conn.transitionTo(.closed)
        }
        inboundConnections.removeAll()
        admittedCentrals.removeAll()
        inboundLeases.removeAll()
        acceptedRemoteLinkInfo.removeAll()
        subscribedCentrals.removeAll()
        physicalReadyCentrals.removeAll()
        for (centralId, slot) in inboundSlots {
            inboundSlots[centralId] = InboundPeerSlot(state: .idle, generation: slot.generation, centralId: centralId, lease: nil)
        }
        capacityAuthority?.releaseAllInbound()
        return transportEpoch
    }

    public func startNewManagerEpoch() -> UInt64 {
        return startNewTransportEpoch(managerEpoch + 1)
    }

    public func isCentralAdmitted(_ centralId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return admittedCentrals.contains(centralId)
    }

    public func getInboundConnection(_ centralId: UUID) -> BleConnection? {
        lock.lock()
        defer { lock.unlock() }
        return inboundConnections[centralId]
    }

    public func getAdmittedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return admittedCentrals.count
    }

    public func getSubscribedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribedCentrals.count
    }

    public func getInboundLease(_ centralId: UUID) -> CapacityLease? {
        lock.lock()
        defer { lock.unlock() }
        return inboundLeases[centralId]
    }

    public func isCentralSubscribed(_ centralId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscribedCentrals.contains(centralId)
    }

    public func getAcceptedRemoteLinkInfo(_ centralId: UUID) -> BleLinkInfoV1? {
        lock.lock()
        defer { lock.unlock() }
        return acceptedRemoteLinkInfo[centralId]
    }

    public func getCentralGeneration(_ centralId: UUID) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return inboundSlots[centralId]?.generation ?? (centralGenerations[centralId] ?? 0)
    }

    public func getInboundSlot(_ centralId: UUID) -> InboundPeerSlot? {
        lock.lock()
        defer { lock.unlock() }
        return inboundSlots[centralId]
    }

    public func getInboundSlotState(_ centralId: UUID) -> InboundSlotState {
        lock.lock()
        defer { lock.unlock() }
        return inboundSlots[centralId]?.state ?? .idle
    }

    private func releaseLeaseLocked(_ centralId: UUID) {
        if let lease = inboundLeases.removeValue(forKey: centralId) {
            capacityAuthority?.releaseLease(lease)
        }
    }

    private func removeAdmitted(centralId: UUID) {
        admittedCentrals.remove(centralId)
        releaseLeaseLocked(centralId)
    }

    public func onCentralRead(centralId: UUID) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }

        // Non-allocating pure cache read
        guard let data = localLinkInfoProvider(), data.count == BleLinkInfoConstants.linkInfoBytes else {
            return .rejectRead(centralId)
        }
        return .sendReadResponse(centralId, data)
    }

    public func onCentralWrite(centralId: UUID, rawData: Data) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }

        let slot = inboundSlots[centralId]
        if case .closing = slot?.state {
            return .rejectWrite(centralId, "Slot is closing")
        }
        if case .quarantined(let qEpoch, _) = slot?.state, qEpoch == transportEpoch {
            return .rejectWrite(centralId, "Central is quarantined")
        }

        guard rawData.count == BleLinkInfoConstants.linkInfoBytes else {
            return .rejectWrite(centralId, "Invalid LinkInfo length")
        }

        guard let remoteInfo = BleLinkInfoCodec.decode(rawData) else {
            return .rejectWrite(centralId, "Malformed LinkInfo payload")
        }

        // Check if central is already admitted and role-bound:
        if admittedCentrals.contains(centralId), let conn = inboundConnections[centralId] {
            if conn.isRoleBound || conn.state == .ready {
                if let existing = acceptedRemoteLinkInfo[centralId], existing == remoteInfo {
                    // Exact duplicate: idempotently ACK without state transition or extra lease
                    if conn.isHandshakeTransportReady && !physicalReadyCentrals.contains(centralId) {
                        physicalReadyCentrals.insert(centralId)
                        return .acceptWriteAndDuplexReady(centralId, remoteInfo.nodeHint)
                    }
                    return .acceptDuplicateWrite(centralId, remoteInfo.nodeHint)
                } else {
                    // Conflicting LinkInfo on active relation: reject cleanly without crash
                    return .rejectWrite(centralId, "Conflicting LinkInfo write on active relation")
                }
            }
        }

        let election = BleRoleElection.elect(localHint: localHint, remoteHint: remoteInfo.nodeHint)
        switch election {
        case .elected(let role):
            if role == .responder {
                let gen = (centralGenerations[centralId] ?? 0) + 1
                var lease: CapacityLease? = nil
                if !admittedCentrals.contains(centralId) {
                    if let cap = capacityAuthority {
                        guard let l = cap.tryAdmitInbound(peerId: centralId, generation: gen) else {
                            return .rejectWrite(centralId, "Capacity exhausted")
                        }
                        lease = l
                        inboundLeases[centralId] = l
                    }
                    admittedCentrals.insert(centralId)
                }

                centralGenerations[centralId] = gen
                acceptedRemoteLinkInfo[centralId] = remoteInfo

                let conn = BleConnection(peerId: centralId)
                conn.transitionTo(.provisionalConnected)
                conn.bindResponderFromAcceptedIncomingLinkInfo(remoteHint: remoteInfo.nodeHint)
                inboundConnections[centralId] = conn
                inboundSlots[centralId] = InboundPeerSlot(state: .active(gen), generation: gen, centralId: centralId, lease: lease)

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

    public func isPhysicalReady(_ centralId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return physicalReadyCentrals.contains(centralId)
    }

    public func onCentralSubscribed(centralId: UUID) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }

        let slot = inboundSlots[centralId]
        if case .closing = slot?.state {
            return .rejectSubscription(centralId)
        }
        if case .quarantined(let qEpoch, _) = slot?.state, qEpoch == transportEpoch {
            return .rejectSubscription(centralId)
        }

        guard admittedCentrals.contains(centralId), let conn = inboundConnections[centralId] else {
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

    public func onCentralUnsubscribed(centralId: UUID, expectedGen: UInt64 = 0) -> BlePeripheralAction {
        lock.lock()
        defer { lock.unlock() }

        let slot = inboundSlots[centralId]
        let currentGen = slot?.generation ?? (centralGenerations[centralId] ?? 0)
        if expectedGen != 0 && currentGen != expectedGen {
            return .noOp
        }
        if case .quarantined(let qEpoch, _) = slot?.state, qEpoch == transportEpoch {
            return .noOp
        }

        subscribedCentrals.remove(centralId)
        physicalReadyCentrals.remove(centralId)
        removeAdmitted(centralId: centralId)
        acceptedRemoteLinkInfo.removeValue(forKey: centralId)
        if let conn = inboundConnections.removeValue(forKey: centralId) {
            conn.transitionTo(.closed)
        }
        inboundSlots[centralId] = InboundPeerSlot(state: .quarantined(transportEpoch, currentGen), generation: currentGen, centralId: centralId, lease: nil)
        return .noOp
    }

    public func onInboundTimeout(centralId: UUID, expectedGen: UInt64 = 0) {
        lock.lock()
        defer { lock.unlock() }
        let slot = inboundSlots[centralId]
        let currentGen = slot?.generation ?? (centralGenerations[centralId] ?? 0)
        if expectedGen != 0 && currentGen != expectedGen {
            return
        }

        subscribedCentrals.remove(centralId)
        physicalReadyCentrals.remove(centralId)
        removeAdmitted(centralId: centralId)
        acceptedRemoteLinkInfo.removeValue(forKey: centralId)
        if let conn = inboundConnections.removeValue(forKey: centralId) {
            conn.transitionTo(.closed)
        }
        inboundSlots[centralId] = InboundPeerSlot(state: .quarantined(transportEpoch, currentGen), generation: currentGen, centralId: centralId, lease: nil)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        for (_, conn) in inboundConnections {
            conn.transitionTo(.closed)
        }
        admittedCentrals.removeAll()
        subscribedCentrals.removeAll()
        physicalReadyCentrals.removeAll()
        inboundConnections.removeAll()
        acceptedRemoteLinkInfo.removeAll()
        inboundLeases.removeAll()
        inboundSlots.removeAll()
        capacityAuthority?.releaseAllInbound()
    }
}
