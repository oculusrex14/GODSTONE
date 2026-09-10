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

/// The record that identifies an inbox subscription: which characteristic
/// the subscription is for and the updated value acknowledged at the
/// subscription. Presented by the subscribe callback, held with the lease.
public struct InboxSubscription: Equatable, Sendable {
    public let characteristicUuid: CBUUID
    public let maxUpdateLength: Int

    public init(characteristicUuid: CBUUID, maxUpdateLength: Int) {
        self.characteristicUuid = characteristicUuid
        self.maxUpdateLength = maxUpdateLength
    }
}

public struct InboundSubscriptionLifetime: Sendable {
    public let relationKey: RelationKey
    public let transportEpoch: UInt64
    /// T16: the actual CBCentral that presented the subscribe request,
    /// retained with the lease. Responder notifications are sent through
    /// this handle - never through a fresh lookup of the subscriber list,
    /// which a reused identity could have renewed in the meantime.
    public let retainedCentral: CBCentral?
    /// The inbox subscription this lease stands for, as presented by the
    /// callback; nil while the subscription was not distinguishable.
    public let inboxSubscription: InboxSubscription?

    public init(relationKey: RelationKey, transportEpoch: UInt64,
                retainedCentral: CBCentral? = nil, inboxSubscription: InboxSubscription? = nil) {
        self.relationKey = relationKey
        self.transportEpoch = transportEpoch
        self.retainedCentral = retainedCentral
        self.inboxSubscription = inboxSubscription
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
    /// T16: an implementation may lower the admission budget to exercise
    /// rotation; absent an override, the transport's own budget rules.
    var admissionBudgetOverride: Int? { get }

}

public extension TransportManagerFactory {
    public var admissionBudgetOverride: Int? { return nil }
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
        self.factoryRef = factory
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
        self.centralProxy.ownerContext = self
        self.peripheralProxy.ownerContext = self
        // The wiring belongs to the birth: it happens once, on the way to
        // the queue the pair will run on, and is never repeated.
        self.central.delegate = self.centralProxy
        self.peripheral.delegate = self.peripheralProxy
    }

    // MARK: - T16 quarantine and admission history (bounded, per epoch)
    //
    // When a callback cannot distinguish the reuse of an identity within
    // this epoch, the identity is quarantined for the epoch and released
    // only by rotation of the context - never by guessing a timeout. The
    // metadata is bounded: past the capacity the set holds its ground and
    // counts the refusals.
    static let quarantineCapacity = 1_024
    static let admissionBudget = 4_096

    private let quarantineLock = NSLock()
    private var quarantinedIdentities: [UUID: String] = [:]
    private var quarantineOverflowCount = 0
    private let admissionLock = NSLock()
    private var admittedIdentities: [UUID] = []
    private var admissionOverflowCount = 0
    private let factoryRef: TransportManagerFactory
    private var rotationDueFlag = false

    /// True while the identity stands quarantined in this context.
    public func isQuarantined(_ identity: UUID) -> Bool {
        quarantineLock.lock()
        let value = quarantinedIdentities[identity] != nil
        quarantineLock.unlock()
        return value
    }

    /// Put the identity under quarantine for the epoch, with bounded
    /// metadata. Answers false when the set is full and the identity is
    /// new; the count of refusals keeps the record.
    @discardableResult
    public func quarantine(_ identity: UUID, reason: String) -> Bool {
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        if quarantinedIdentities[identity] != nil {
            return true
        }
        if quarantinedIdentities.count >= ManagerContext.quarantineCapacity {
            quarantineOverflowCount += 1
            return false
        }
        quarantinedIdentities[identity] = reason
        return true
    }

    public func quarantineRecordCount() -> Int {
        quarantineLock.lock()
        let value = quarantinedIdentities.count
        quarantineLock.unlock()
        return value
    }

    public func quarantineOverflowRecords() -> Int {
        quarantineLock.lock()
        let value = quarantineOverflowCount
        quarantineLock.unlock()
        return value
    }

    public func releaseAllQuarantines() {
        quarantineLock.lock()
        quarantinedIdentities.removeAll()
        quarantineLock.unlock()
    }

    /// Note one admission against the history. Answers true when the
    /// budget is exhausted and a rotation of the context is due at the
    /// next drained point.
    @discardableResult
    public func noteAdmission(_ identity: UUID) -> Bool {
        admissionLock.lock()
        let budget = factoryRef.admissionBudgetOverride ?? ManagerContext.admissionBudget
        if admittedIdentities.count < budget {
            admittedIdentities.append(identity)
        } else {
            admissionOverflowCount += 1
        }
        let due = admittedIdentities.count >= budget
        admissionLock.unlock()
        return due
    }

    /// Mark that the admission budget is exhausted: a rotation of the
    /// context becomes due and executes at the next drained point.
    public func markRotationDue() {
        admissionLock.lock()
        rotationDueFlag = true
        admissionLock.unlock()
    }

    public func isRotationDue() -> Bool {
        admissionLock.lock()
        let value = rotationDueFlag
        admissionLock.unlock()
        return value
    }

    public func admissionHistoryCount() -> Int {
        admissionLock.lock()
        let value = admittedIdentities.count
        admissionLock.unlock()
        return value
    }

    public var isRetired: Bool {
        stateLock.lock()
        let value = retiredFlag
        stateLock.unlock()
        return value
    }

    /// Key into the calling thread's dictionary naming this context's
    /// serial executor: a thread carrying the marker is executing within
    /// the context, and reductions there are the serial reductions of
    /// this epoch.
    private var serialMarkerKey: String {
        return "godstone.mesh.serial." + queue.label
    }

    /// True while the calling thread executes within this context's serial
    /// executor.
    public var isOnSerialExecutor: Bool {
        return Thread.current.threadDictionary[serialMarkerKey] != nil
    }

    /// Runs the body while the calling thread is marked as executing
    /// within this executor. Already-marked callers run their body inline:
    /// the executor is serial, and the queue context is the same object.
    func withSerial<T>(_ body: () -> T) -> T {
        let key = serialMarkerKey
        let tagKey = "godstone.mesh.epoch.tag"
        if Thread.current.threadDictionary[key] != nil {
            return body()
        }
        Thread.current.threadDictionary[key] = NSNumber(value: true)
        Thread.current.threadDictionary[tagKey] = NSNumber(value: epoch)
        let result = body()
        Thread.current.threadDictionary.removeObject(forKey: key)
        Thread.current.threadDictionary.removeObject(forKey: tagKey)
        return result
    }

    /// Admits a reduction to this epoch's serial executor. A caller
    /// already inside the executor runs the body at once; any other
    /// caller is synchronised onto the queue, so validation, transition
    /// and effect scheduling of one event are never decomposed against
    /// another event, against stop/start, or against a timer fire.
    func serialise<T>(_ body: () -> T) -> T {
        if isOnSerialExecutor {
            return withSerial(body)
        }
        return queue.sync {
            return self.withSerial(body)
        }
    }

    /// Test seam: whether the calling thread executes within this
    /// executor, as the reduction trace records it.
    public func isOnSerialExecutorForTest() -> Bool {
        return isOnSerialExecutor
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
    /// Back pointer to the context that created this proxy, filled in at
    /// birth by ManagerContext's designated initialiser. It is weak: the
    /// context owns the proxy, the proxy only names its context.
    public weak var ownerContext: ManagerContext?

    public init(transportEpoch: UInt64, transport: BleTransport) {
        self.transportEpoch = transportEpoch
        self.transport = transport
        super.init()
    }

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        ownerContext?.withSerial {
        transport?.processCentralDidUpdateState(c, sourceEpoch: transportEpoch)
        }
    }


    public func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        ownerContext?.withSerial {
        transport?.processCentralWillRestoreState(c, dict: dict, sourceEpoch: transportEpoch)
        }
    }


    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        ownerContext?.withSerial {
        transport?.processCentralDidDiscover(c, peripheral: p, advertisementData: advertisementData, rssi: RSSI, sourceEpoch: transportEpoch)
        }
    }


    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        ownerContext?.withSerial {
        _ = transport?.processCentralConnect(peerId: p.identifier, peripheral: p, sourceEpoch: transportEpoch, from: c)
        }
    }


    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        ownerContext?.withSerial {
        _ = transport?.processCentralFailToConnect(peerId: p.identifier, error: error, peripheral: p, sourceEpoch: transportEpoch, from: c)
        }
    }


    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        ownerContext?.withSerial {
        _ = transport?.processOutboundDisconnect(peerId: p.identifier, expectedGen: 0, peripheral: p, sourceEpoch: transportEpoch, from: c)
        }
    }

}

public final class PeripheralManagerEpochDelegate: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    public let transportEpoch: UInt64
    public weak var transport: BleTransport?
    /// Back pointer to the context that created this proxy; weak, filled
    /// in at birth, never rewired afterwards.
    public weak var ownerContext: ManagerContext?

    public init(transportEpoch: UInt64, transport: BleTransport) {
        self.transportEpoch = transportEpoch
        self.transport = transport
        super.init()
    }

    public func peripheralManagerDidUpdateState(_ pm: CBPeripheralManager) {
        ownerContext?.withSerial {
        transport?.processPeripheralManagerDidUpdateState(pm, sourceEpoch: transportEpoch)
        }
    }


    public func peripheralManager(_ pm: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        ownerContext?.withSerial {
        transport?.processPeripheralDidAddService(pm, service: service, error: error, sourceEpoch: transportEpoch)
        }
    }


    public func peripheralManager(_ pm: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        ownerContext?.withSerial {
        transport?.processPeripheralWillRestoreState(pm, dict: dict, sourceEpoch: transportEpoch)
        }
    }


    public func peripheralManager(_ pm: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        ownerContext?.withSerial {
        transport?.processPeripheralReceiveRead(pm, request: request, sourceEpoch: transportEpoch)
        }
    }


    public func peripheralManager(_ pm: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        ownerContext?.withSerial {
        transport?.processPeripheralReceiveWrite(pm, requests: requests, sourceEpoch: transportEpoch)
        }
    }


    public func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral, didSubscribeTo ch: CBCharacteristic) {
        ownerContext?.withSerial {
        transport?.processPeripheralDidSubscribe(pm, central: central, characteristic: ch, sourceEpoch: transportEpoch)
        }
    }


    public func peripheralManager(_ pm: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom ch: CBCharacteristic) {
        ownerContext?.withSerial {
        transport?.processPeripheralDidUnsubscribe(pm, central: central, characteristic: ch, sourceEpoch: transportEpoch)
        }
    }


    public func peripheralManagerIsReady(toUpdateSubscribers pm: CBPeripheralManager) {
        ownerContext?.withSerial {
        transport?.processPeripheralIsReadyToUpdateSubscribers(pm, sourceEpoch: transportEpoch)
        }
    }

}

/// T15: every timer answers to an immutable whole key - the relation it
/// guards, the kind of the operation it times out, and a unique operation
/// id issued by the epoch's own counter. Fire, cancel and replace always
/// compare the whole key; no counter and no generation is ever trusted
/// without it.
public enum TimerOperationKind: UInt8, Hashable, Sendable {
    /// The provisional window of an outbound connect attempt.
    case provisionalOutbound
    /// The inactivity window of an accepted inbound subscription.
    case inboundInactivity
}

/// The slot a lease occupies: one pending timer per peer and operation
/// kind. It is always derived from the whole key, never held apart from it.
public struct TimerSlot: Hashable, Sendable {
    public let direction: BleDirection
    public let peerId: UUID
    public let operation: TimerOperationKind
}

public struct TimerKey: Hashable, Sendable {
    public let relation: RelationKey
    public let operation: TimerOperationKind
    public let operationId: UInt64

    public init(relation: RelationKey, operation: TimerOperationKind, operationId: UInt64) {
        self.relation = relation
        self.operation = operation
        self.operationId = operationId
    }

    public var slot: TimerSlot {
        return TimerSlot(direction: relation.direction, peerId: relation.peerId, operation: operation)
    }
}

/// The held grant over the slot: the explicit deadline in the injected
/// monotonic domain, the handle (whole key) it answers to, the scheduled
/// fire, and the epoch context that armed it - the fire is carried back to
/// that very executor, as in T14.
public struct TimerLease: Sendable {
    public let deadlineUptimeMillis: UInt64
    public let handle: TimerKey
    let timer: Timer
    let context: ManagerContext?

    init(deadlineUptimeMillis: UInt64, handle: TimerKey, timer: Timer, context: ManagerContext?) {
        self.deadlineUptimeMillis = deadlineUptimeMillis
        self.handle = handle
        self.timer = timer
        self.context = context
    }
}

/// Injected monotonic time: deadlines are computed against it, never
/// assumed from wall drift.
public protocol MonotonicClock: Sendable {
    func nowUptimeMillis() -> UInt64
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}
    public func nowUptimeMillis() -> UInt64 {
        return DispatchTime.now().uptimeNanoseconds / 1_000_000
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
    private let clock: MonotonicClock

    /// The pair of the active epoch, when one is open.
    private var central: CBCentralManager? {
        return activeManagerContext?.central
    }

    /// The pair of the active epoch, when one is open.
    private var peripheral: CBPeripheralManager? {
        return activeManagerContext?.peripheral
    }

    // MARK: - T15 timer leases
    //
    // Timers are stored, cancelled and replaced only through these reducer
    // bodies, each running on the epoch serial executor with the lock held
    // for the store touch. Fire, cancel and replace compare the whole key
    // before removing or transitioning anything.

    /// Arm the slot for the given relation with a fresh operation id. A
    /// current lease is compared by its whole key and only then cancelled:
    /// the cancel releases exactly the handle that matches, never a blind
    /// sweep of the slot that could catch a newer lease.
    private func armTimerLocked(relation: RelationKey) {
        let operation: TimerOperationKind
        switch relation.direction {
        case .outboundCentral:
            operation = .provisionalOutbound
        case .inboundPeripheral:
            operation = .inboundInactivity
        }
        let slot = TimerSlot(direction: relation.direction, peerId: relation.peerId, operation: operation)
        nextTimerOperationId += 1
        let key = TimerKey(relation: relation, operation: operation, operationId: nextTimerOperationId)
        if let current = timerSlots[slot], let lease = timerLeases[current] {
            // identity confirmed against the slot's own current key before
            // any removal
            lease.timer.invalidate()
            timerLeases.removeValue(forKey: current)
        }
        let deadline = clock.nowUptimeMillis() &+ UInt64((provisionalTimeoutSeconds * 1000).rounded())
        let timer = Timer(timeInterval: provisionalTimeoutSeconds, repeats: false) { [weak self] _ in
            self?.timerDidFire(key: key)
        }
        timerLeases[key] = TimerLease(deadlineUptimeMillis: deadline, handle: key, timer: timer,
                                      context: activeManagerContext)
        timerSlots[slot] = key
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Cancel the lease of the slot only when its whole key carries exactly
    /// the given relation: cancel/release only resources owned by the exact
    /// operation. A slot whose key names another generation is left alone.
    private func cancelTimerLocked(matching relation: RelationKey) {
        let slot = TimerSlot(direction: relation.direction, peerId: relation.peerId, operation: timerOperation(for: relation.direction))
        if let current = timerSlots[slot], let lease = timerLeases[current], current.relation == relation {
            lease.timer.invalidate()
            timerLeases.removeValue(forKey: current)
            timerSlots.removeValue(forKey: slot)
        }
    }

    /// The terminal and lifecycle sweep: every held fire is invalidated and
    /// every lease evicted - nothing is retained past the boundary.
    private func cancelAllTimerLeasesLocked() {
        for (_, lease) in timerLeases {
            lease.timer.invalidate()
        }
        timerLeases.removeAll()
        timerSlots.removeAll()
    }

    private func timerOperation(for direction: BleDirection) -> TimerOperationKind {
        switch direction {
        case .outboundCentral:
            return .provisionalOutbound
        case .inboundPeripheral:
            return .inboundInactivity
        }
    }

    /// The body every scheduled Timer runs: carry the fire, with its whole
    /// key, onto the executor of the very context that armed the lease.
    private func timerDidFire(key: TimerKey) {
        lockTransport()
        guard let lease = timerLeases[key], timerSlots[key.slot] == key else {
            lastTimerFireActedForTest = false
            unlockTransport()
            return
        }
        let context = lease.context
        unlockTransport()
        guard let context else {
            lastTimerFireActedForTest = false
            return
        }
        _ = onExecutorOf(context) {
            self.reductionTimerFired(key: key)
        }
    }

    /// The reduction of one fire: the whole-key identity is verified again
    /// under the lock before anything is removed, and only then the timed
    /// out operation proceeds on the executor.
    @discardableResult
    private func reductionTimerFired(key: TimerKey) -> Bool {
        lockTransport()
        guard timerLeases[key] != nil, timerSlots[key.slot] == key else {
            lastTimerFireActedForTest = false
            unlockTransport()
            return false
        }
        timerLeases.removeValue(forKey: key)
        timerSlots.removeValue(forKey: key.slot)
        unlockTransport()
        switch key.operation {
        case .provisionalOutbound:
            _ = reductionHandleOutboundTimeout(peerId: key.relation.peerId, generation: key.relation.generation)
        case .inboundInactivity:
            reductionHandleInboundTimeout(centralId: key.relation.peerId, generation: key.relation.generation)
        }
        lastTimerFireActedForTest = true
        return true
    }

    private var lastTimerFireActedForTest: Bool = false

    /// Test seam: run the fire body for the given key - the same path the
    /// scheduled Timer takes - and answer whether it acted.
    @discardableResult
    public func fireTimerForTest(_ key: TimerKey) -> Bool {
        timerDidFire(key: key)
        return lastTimerFireActedForTest
    }

    public struct TimerLeaseSnapshot: Sendable {
        public let direction: BleDirection
        public let peerId: UUID
        public let operation: TimerOperationKind
        public let generation: UInt64
        public let operationId: UInt64
        public let deadlineUptimeMillis: UInt64
    }

    /// Test seam: the held leases, ordered by slot then operation id.
    public func timerLeaseSnapshotForTest() -> [TimerLeaseSnapshot] {
        lockTransport()
        let leases = Array(timerLeases.values)
        unlockTransport()
        return leases.map { lease in
            TimerLeaseSnapshot(direction: lease.handle.relation.direction,
                               peerId: lease.handle.relation.peerId,
                               operation: lease.handle.operation,
                               generation: lease.handle.relation.generation,
                               operationId: lease.handle.operationId,
                               deadlineUptimeMillis: lease.deadlineUptimeMillis)
        }.sorted { lhs, rhs in
            if lhs.peerId != rhs.peerId {
                return lhs.peerId.uuidString < rhs.peerId.uuidString
            }
            if lhs.operation != rhs.operation {
                return lhs.operation.rawValue < rhs.operation.rawValue
            }
            return lhs.operationId < rhs.operationId
        }
    }

    // MARK: - T16 observation rings (forget-only writers under the lock, read-only here)
    static let responderSendRecordCapacity = 256
    public struct ResponderSendRecord: Sendable {
        public let centralId: UUID
        public let byteCount: Int
        public let via: ObjectIdentifier
        public let viaRetained: Bool
    }
    private var responderSendsForTest: [ResponderSendRecord] = []
    private var cancelRequestsForTest: [UUID] = []

    private func recordResponderSendLocked(_ record: ResponderSendRecord) {
        responderSendsForTest.append(record)
        if responderSendsForTest.count > BleTransport.responderSendRecordCapacity {
            responderSendsForTest.removeFirst()
        }
    }

    private func recordCancelRequestLocked(_ identity: UUID) {
        cancelRequestsForTest.append(identity)
        if cancelRequestsForTest.count > BleTransport.responderSendRecordCapacity {
            cancelRequestsForTest.removeFirst()
        }
    }

    public func responderSendRecordsForTest() -> [ResponderSendRecord] {
        lockTransport()
        let value = responderSendsForTest
        unlockTransport()
        return value
    }

    public func cancelRequestRecordsForTest() -> [UUID] {
        lockTransport()
        let value = cancelRequestsForTest
        unlockTransport()
        return value
    }

    public func isIdentityQuarantinedForTest(_ identity: UUID) -> Bool {
        lockTransport()
        let context = activeManagerContext
        unlockTransport()
        return context?.isQuarantined(identity) ?? false
    }

    public func quarantineRecordCountForTest() -> Int {
        lockTransport()
        let context = activeManagerContext
        unlockTransport()
        return context?.quarantineRecordCount() ?? 0
    }

    public func quarantineOverflowRecordsForTest() -> Int {
        lockTransport()
        let context = activeManagerContext
        unlockTransport()
        return context?.quarantineOverflowRecords() ?? 0
    }

    public func admissionHistoryCountForTest() -> Int {
        lockTransport()
        let context = activeManagerContext
        unlockTransport()
        return context?.admissionHistoryCount() ?? 0
    }

    public func timerLeaseCountForTest() -> Int {
        lockTransport()
        let count = timerLeases.count
        unlockTransport()
        return count
    }

    /// Test seam: the context of the active transport epoch, if any.
    public func currentManagerContextForTest() -> ManagerContext? {
        lockTransport()
        let value = activeManagerContext
        unlockTransport()
        return value
    }

    /// Test seam: the most recently retired context, kept so the
    /// late-callback cases can deliver through the very objects the
    /// previous epoch ran on.
    public func lastRetiredManagerContextForTest() -> ManagerContext? {
        lockTransport()
        let value = lastRetiredManagerContext
        unlockTransport()
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
        lockTransport()
        let value = activeManagerContext?.central ?? lastRetiredManagerContext?.central
        unlockTransport()
        precondition(value != nil, "no transport epoch has ever opened on this instance: start the transport before dispatching manager-sourced events")
        return value!
    }

    // MARK: - T14 serial reduction facility
    //
    // One admitted event is reduced in a single uninterrupted operation on
    // the epoch's dedicated serial queue: validation, transition and the
    // scheduling of effects. Callback adapters only package immutable
    // events; trust work (seal/open) runs outside the critical section and
    // its completion is token-checked before any effect commits.

    /// One reduction as it was admitted: which epoch's executor carried
    /// it, and whether the admitting thread was already inside the
    /// executor (re-entry from a callback or a nested reduction) or was
    /// synchronised onto the queue.
    public struct ReductionTrace: Equatable {
        public let epoch: UInt64
        public let ranOnSerialExecutor: Bool
        public let reentrant: Bool
    }

    /// Test seam: the trace of the most recent reduction admission.
    public private(set) var lastReductionTraceForTest: ReductionTrace?
    public func clearReductionTraceForTest() {
        lastReductionTraceForTest = nil
    }

    /// Test failpoint: when set, invoked on the executor between the
    /// validation of an event and the scheduling of its effects, for the
    /// named reduction. Production never sets it; the deterministic
    /// barrier-interleaving case does, at a real dependency boundary.
    public var failpointAfterValidationForTest: ((String) -> Void)?

    func onExecutor<T>(_ body: () -> T) -> T {
        lockTransport()
        let context = activeManagerContext ?? lastRetiredManagerContext
        unlockTransport()
        return onExecutorOf(context, body)
    }

    func onExecutorOf<T>(_ context: ManagerContext?, _ body: () -> T) -> T {
        if let context {
            let reentrant = context.isOnSerialExecutor
            let result = context.serialise {
                body()
            }
            lockTransport()
            lastReductionTraceForTest = ReductionTrace(
                epoch: context.epoch,
                ranOnSerialExecutor: true,
                reentrant: reentrant
            )
            unlockTransport()
            return result
        }
        lockTransport()
        lastReductionTraceForTest = ReductionTrace(
            epoch: currentTransportEpoch,
            ranOnSerialExecutor: false,
            reentrant: false
        )
        unlockTransport()
        return body()
    }

    private let lockAccountingForTest = NSLock()
    private var transportLockDepthForTest = 0

    private func lockTransport() {
        transportLock.lock()
        lockAccountingForTest.lock()
        transportLockDepthForTest += 1
        lockAccountingForTest.unlock()
    }

    private func unlockTransport() {
        lockAccountingForTest.lock()
        transportLockDepthForTest -= 1
        lockAccountingForTest.unlock()
        transportLock.unlock()
    }

    /// Whether the transport lock is held at this instant. Trust-work
    /// sites are asserted never to run under it.
    public func transportLockIsHeldForTest() -> Bool {
        lockAccountingForTest.lock()
        let held = transportLockDepthForTest > 0
        lockAccountingForTest.unlock()
        return held
    }

    /// What the trust-work sites were told to record: the operation, and
    /// the state of the world at the dispatch - read lock-free through the
    /// thread's own tags, so the act of observing never perturbs it.
    public struct TrustWorkProbe: Equatable {
        public let operation: String
        public let lockHeld: Bool
        public let onExecutor: Bool
    }

    public private(set) var lastTrustWorkProbeForTest: TrustWorkProbe?

    public func recordTrustWorkForTest(_ operation: String) {
        let key = "godstone.mesh.epoch.tag"
        let onExec = Thread.current.threadDictionary[key] != nil
        lockAccountingForTest.lock()
        let held = transportLockDepthForTest > 0
        lockAccountingForTest.unlock()
        lockTransport()
        lastTrustWorkProbeForTest = TrustWorkProbe(operation: operation, lockHeld: held, onExecutor: onExec)
        unlockTransport()
    }

    /// Test seam: the peripheral manager of the open epoch context.
    public func requireContextPeripheralForTest() -> CBPeripheralManager {
        lockTransport()
        let value = activeManagerContext?.peripheral ?? lastRetiredManagerContext?.peripheral
        unlockTransport()
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
        lockTransport()
        let value = managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: isCentral,
            sender: sender
        )
        unlockTransport()
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

    /// Leases by whole key, and the current key per slot. Both are
    /// mutated only by the reducer bodies below, with the lock held.
    private var timerLeases: [TimerKey: TimerLease] = [:]
    private var timerSlots: [TimerSlot: TimerKey] = [:]
    /// Per-epoch operation id source. Reset at every opening; never
    /// relied on without the whole key that carries it.
    private var nextTimerOperationId: UInt64 = 0

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
        managerFactory: TransportManagerFactory? = nil,
        clock: MonotonicClock? = nil
    ) {
        self.identity = identity
        self.store = store
        self.sessions = sessions
        self.provisionalTimeoutSeconds = provisionalTimeoutSeconds
        self.managerFactory = managerFactory ?? DefaultTransportManagerFactory()
        self.clock = clock ?? SystemMonotonicClock()
        super.init()
        self.snapshotAuthority = LinkInfoSnapshotAuthority(
            identityProvider: { [weak self] in self?.identity },
            storeProvider: { [weak self] in self?.store }
        )
    }

    public func getOutboundLifetime(_ peerId: UUID) -> OutboundPhysicalLifetime? {
        lockTransport()
        defer { unlockTransport() }
        return activeOutboundLifetimes[peerId]
    }

    public func getInboundLifetime(_ centralId: UUID) -> InboundSubscriptionLifetime? {
        lockTransport()
        defer { unlockTransport() }
        return activeInboundLifetimes[centralId]
    }

    public func getSubscribedCentral(_ id: UUID) -> CBCentral? {
        lockTransport()
        defer { unlockTransport() }
        return subscribedCentrals[id]
    }

    public func getRelationDelegate(_ peerId: UUID) -> RelationPeripheralDelegate? {
        lockTransport()
        defer { unlockTransport() }
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
        // T14: a restart first quiesces the previous epoch's executor:
        // in-flight reductions complete their one operation against the
        // drivers they were admitted with, and only then are fresh
        // drivers installed. No event mutates a replaced driver.
        lockTransport()
        let quiesceTarget = activeManagerContext ?? lastRetiredManagerContext
        unlockTransport()
        if let quiesceTarget {
            quiesceTarget.serialise {
                self.startInstalling()
            }
        } else {
            startInstalling()
        }
    }
    private func startInstalling() {
        lockTransport()
        guard !isStarted else {
            unlockTransport()
            return
        }
        installFreshContextLocked()
        let canAdv = isServiceRegistered && (peripheral?.state == .poweredOn)
        unlockTransport()

        if canAdv {
            startAdvertising()
        }
        startScanning()
    }

    /// Install the fresh pair for an opening or a rotation; the caller
    /// holds the lock. The epoch advances, the factory breeds the managers
    /// on their dedicated serial queue, the proxies are wired once at
    /// birth - the T13 discipline, shared by start() and by rotation.
    private func installFreshContextLocked() {
        currentTransportEpoch += 1
        // T15 by observation: the operation id source is never reset at an
        // opening. Were it restarted, a successor epoch could issue a key
        // equal to a retired one (same slot, same generation, same id) and
        // a stale fire would pass the whole-key comparison. Monotone over
        // the transport's lifetime, the id keeps every key unique across
        // epochs - and no counter is ever relied on without its epoch: the
        // lease binds the fire to the very context that armed it.
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
    }

    /// True when the maps hold nothing in flight: no lifetimes, leases,
    /// subscriptions, connections, queued updates or publications. Rotation
    /// takes place only where the context is fully drained.
    private func contextIsFullyDrainedLocked() -> Bool {
        return activeOutboundLifetimes.isEmpty && activeInboundLifetimes.isEmpty
            && timerLeases.isEmpty && subscribedCentrals.isEmpty
            && outboundCentralConnections.isEmpty && inboundPeripheralConnections.isEmpty
            && connectedPeripherals.isEmpty && pendingOutboundUpdates.isEmpty
            && pendingOutboundWrites.isEmpty && publishedRelations.isEmpty
    }

    /// Rotate a fully drained context whose admission budget is exhausted.
    /// The pair leaves the stage as it came and a fresh pair is born from
    /// the factory on a new dedicated queue; the epoch advances, so every
    /// token, quarantine and history record of the retired context retires
    /// together with it. Never called on a busy context. The caller holds
    /// the lock and re-kicks scanning and advertising outside it.
    private func executeRotationIfNeededLocked() -> Bool {
        guard isStarted, let context = activeManagerContext, context.isRotationDue() else { return false }
        guard contextIsFullyDrainedLocked() else { return false }
        context.retire()
        lastRetiredManagerContext = context
        installFreshContextLocked()
        return true
    }

    public func stop() {
        // T14: the closing epoch is quiesced on its own serial
        // executor: in-flight reductions complete their one operation
        // before the reset, and nothing of them mutates the new state.
        lockTransport()
        let closing = activeManagerContext
        unlockTransport()
        if let closing {
            closing.serialise {
                stopQuiesced()
            }
        } else {
            stopQuiesced()
        }
    }

    private func stopQuiesced() {
        lockTransport()
        guard isStarted else {
            unlockTransport()
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

        cancelAllTimerLeasesLocked()

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
        unlockTransport()
    }

    private func startScanning() -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionStartScanning()
        }
    }

    private func reductionStartScanning() {
        guard let central = central, central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [BleTransport.serviceUuid],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: !isBackgrounded]
        )
    }

    private func startAdvertising() -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionStartAdvertising()
        }
    }

    private func reductionStartAdvertising() {
        guard let peripheral = peripheral, peripheral.state == .poweredOn, isServiceRegistered else { return }
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BleTransport.serviceUuid]
        ])
    }

    public func setBackgrounded(_ backgrounded: Bool) {
        lockTransport()
        isBackgrounded = backgrounded
        unlockTransport()
        // The scan restart belongs on the serial executor, outside the
        // critical section: startScanning is itself an entry that queues
        // there, and blocking on the queue while holding the lock would
        // invert the order the reducer relies on.
        central?.stopScan()
        startScanning()
    }

    public func connection(for peerId: UUID) -> BleConnection? {
        lockTransport()
        defer { unlockTransport() }
        return outboundCentralConnections[peerId] ?? inboundPeripheralConnections[peerId]
    }

    public func discoveryMetadata(for peerId: UUID) -> BleDiscoveryMetadata? {
        lockTransport()
        defer { unlockTransport() }
        return discoveredPeers[peerId]
    }

    public func setMutableInboxCharacteristicForTesting(_ char: CBMutableCharacteristic?) {
        lockTransport()
        defer { unlockTransport() }
        mutableInboxCharacteristic = char
    }

    private func purgeCentralConnection(peerId: UUID, cancelPeripheral: Bool) {
        let gen = centralDriver?.getConnectionGeneration(peerId) ?? 0
        lockTransport()
        cancelTimerLocked(matching: RelationKey(direction: .outboundCentral, peerId: peerId, generation: gen))
        inboxCharacteristics.removeValue(forKey: peerId)
        digestCharacteristics.removeValue(forKey: peerId)
        linkInfoCharacteristics.removeValue(forKey: peerId)
        pendingInitiatorRemoteHints.removeValue(forKey: peerId)
        pendingOutboundWrites.removeValue(forKey: peerId)
        if cancelPeripheral, connectedPeripherals[peerId] != nil {
            recordCancelRequestLocked(peerId)
        }
        let periph = connectedPeripherals.removeValue(forKey: peerId)
        let conn = outboundCentralConnections.removeValue(forKey: peerId)
        conn?.markDisconnected()
        _ = centralDriver?.onProvisionalTimeout(peerId: peerId, expectedGen: gen)
        unlockTransport()

        if cancelPeripheral, let p = periph {
            central?.cancelPeripheralConnection(p)
        }
        let key = RelationKey(direction: .outboundCentral, peerId: peerId, generation: gen)
        unpublishRelation(key)
    }

    @discardableResult
    public func send(_ frame: FrameV2, to peerId: UUID) -> Bool {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionSend(frame, to: peerId)
        }
    }

    public func reductionSend(_ frame: FrameV2, to peerId: UUID) -> Bool {
        lockTransport()
        let conn = outboundCentralConnections[peerId] ?? inboundPeripheralConnections[peerId]
        guard let connection = conn, connection.state == .ready else {
            unlockTransport()
            return false
        }
        let epochAtAdmission = currentTransportEpoch
        unlockTransport()
        // T14: sealing is trust work. It runs outside the critical section,
        // on the serial executor, and returns a completion that is
        // token-checked before any effect commits. Authentication failure
        // (nil) is distinguished from success throughout: false names the
        // refusal, true names the queued write.
        recordTrustWorkForTest("seal")
        let sealedPayload = sessions?.seal(peerId, frame.encode()) ?? (sessions == nil ? frame.encode() : nil)
        guard let sealed = sealedPayload else {
            return false
        }
        lockTransport()
        guard isStarted, epochAtAdmission == currentTransportEpoch,
              let again = (outboundCentralConnections[peerId] ?? inboundPeripheralConnections[peerId]),
              again === connection, again.state == .ready else {
            unlockTransport()
            return false
        }
        let fragments = connection.fragmentOutbound(recordType: .data, payload: sealed)
        guard !fragments.isEmpty else {
            unlockTransport()
            return false
        }

        if connection.localRole == .initiator {
            guard let p = connectedPeripherals[peerId],
                  let ch = inboxCharacteristics[peerId] else {
                unlockTransport()
                return false
            }

            var queue = pendingOutboundWrites[peerId] ?? []
            if !queue.isEmpty {
                if queue.count + fragments.count > BleTransport.maxQueuedAttValues {
                    unlockTransport()
                    return false
                }
                queue.append(contentsOf: fragments)
                pendingOutboundWrites[peerId] = queue
                unlockTransport()
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
                    unlockTransport()
                    return false
                }
                queue.append(contentsOf: remaining)
                pendingOutboundWrites[peerId] = queue
            }
            unlockTransport()
            return true
        } else {
            // T16: notifications are sent through the central retained with
            // the lease - the subscriber list entry alone cannot prove which
            // very central presented the subscription. A quarantined
            // identity is suppressed altogether.
            if activeManagerContext?.isQuarantined(peerId) == true {
                unlockTransport()
                return false
            }
            guard let lease = activeInboundLifetimes[peerId],
                  let centralObj = lease.retainedCentral,
                  let inboxChar = mutableInboxCharacteristic else {
                unlockTransport()
                return false
            }

            var queue = pendingOutboundUpdates[peerId] ?? []
            for frag in fragments {
                if !queue.isEmpty {
                    if queue.count >= BleTransport.maxQueuedAttValues {
                        unlockTransport()
                        return false
                    }
                    queue.append(frag)
                } else {
                    let ok = peripheral?.updateValue(frag, for: inboxChar, onSubscribedCentrals: [centralObj]) ?? false
                    recordResponderSendLocked(ResponderSendRecord(centralId: peerId, byteCount: frag.count,
                                                        via: ObjectIdentifier(centralObj), viaRetained: true))
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
            unlockTransport()
            return true
        }
    }

    @discardableResult
    public func publishRelation(_ key: RelationKey) -> Bool {
        lockTransport()
        let hadAny = publishedRelations.contains(where: { $0.peerId == key.peerId })
        let (inserted, _) = publishedRelations.insert(key)
        unlockTransport()
        if inserted && !hadAny {
            delegate?.transportPhysicalDuplexReady(peerId: key.peerId)
            delegate?.transportDidConnect(peerId: key.peerId)
            return true
        }
        return false
    }

    @discardableResult
    public func unpublishRelation(_ key: RelationKey) -> Bool {
        lockTransport()
        let hadAny = publishedRelations.contains(where: { $0.peerId == key.peerId })
        let removed = publishedRelations.remove(key) != nil
        let hasRemaining = publishedRelations.contains(where: { $0.peerId == key.peerId })
        unlockTransport()
        if removed && hadAny && !hasRemaining {
            delegate?.transportDidDisconnect(peerId: key.peerId)
            return true
        }
        return false
    }

    public func processOutboundDiscover(peerId: UUID,
        rssi: Int = -60,
        serviceDataHint: Data? = nil,
        peripheral: CBPeripheral? = nil,
        sourceEpoch: UInt64, from manager: CBCentralManager) -> BleCentralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessOutboundDiscover(peerId: peerId, rssi: rssi, serviceDataHint: serviceDataHint, peripheral: peripheral, sourceEpoch: sourceEpoch, from: manager)
        }
    }

    public func reductionProcessOutboundDiscover(
        peerId: UUID,
        rssi: Int = -60,
        serviceDataHint: Data? = nil,
        peripheral: CBPeripheral? = nil,
        sourceEpoch: UInt64, from manager: CBCentralManager
    ) -> BleCentralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotCentral = centralDriver
        unlockTransport()

        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: manager
        ) else {
            unlockTransport()
            return .noOp
        }
        guard let driver = snapshotCentral else {
            unlockTransport()
            return .noOp
        }
        unlockTransport()

        let action = driver.onDiscover(peerId: peerId, rssi: rssi, serviceDataHint: serviceDataHint)
        if case .connectPeripheral(let pid) = action {
            lockTransport()
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

            // T15: the arm goes through the reducer; the lease captures the
            // whole key, the injected deadline and the epoch context.
            armTimerLocked(relation: key)
            unlockTransport()
        }
        return action
    }

    public func processCentralConnect(peerId: UUID, peripheral: CBPeripheral? = nil, sourceEpoch: UInt64, from manager: CBCentralManager) -> BleCentralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessCentralConnect(peerId: peerId, peripheral: peripheral, sourceEpoch: sourceEpoch, from: manager)
        }
    }

    public func reductionProcessCentralConnect(peerId: UUID, peripheral: CBPeripheral? = nil, sourceEpoch: UInt64, from manager: CBCentralManager) -> BleCentralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotCentral = centralDriver
        unlockTransport()

        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: manager
        ) else {
            unlockTransport()
            return .noOp
        }
        guard let lifetime = activeOutboundLifetimes[peerId], (sourceEpoch == 0 || lifetime.transportEpoch == sourceEpoch) else {
            unlockTransport()
            return .noOp
        }
        if let p = peripheral, let installedP = lifetime.peripheral, installedP !== p {
            unlockTransport()
            return .noOp
        }
        unlockTransport()
        if let failpoint = failpointAfterValidationForTest {
            failpoint("processCentralConnect")
        }
        let action = snapshotCentral?.onConnected(peerId: peerId) ?? .noOp
        if case .discoverServices = action {
            lockTransport()
            // T15: advancing into the handshake re-arms the slot's window
            // through the reducer. The replacement compares the whole key
            // of the current lease before cancelling exactly that handle,
            // then installs a fresh operation id over the same relation -
            // the mirrored shape of the Android driver's connect lease.
            armTimerLocked(relation: lifetime.relationKey)
            unlockTransport()
            if let p = peripheral ?? lifetime.peripheral {
                p.discoverServices([BleTransport.serviceUuid])
            }
        }
        return action
    }

    public func processCentralFailToConnect(peerId: UUID, error: Error? = nil, peripheral: CBPeripheral? = nil, sourceEpoch: UInt64, from manager: CBCentralManager) -> BleCentralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessCentralFailToConnect(peerId: peerId, error: error, peripheral: peripheral, sourceEpoch: sourceEpoch, from: manager)
        }
    }

    public func reductionProcessCentralFailToConnect(peerId: UUID, error: Error? = nil, peripheral: CBPeripheral? = nil, sourceEpoch: UInt64, from manager: CBCentralManager) -> BleCentralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotCentral = centralDriver
        unlockTransport()

        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: manager
        ) else {
            unlockTransport()
            return .noOp
        }
        guard let lifetime = activeOutboundLifetimes[peerId], (sourceEpoch == 0 || lifetime.transportEpoch == sourceEpoch) else {
            unlockTransport()
            return .noOp
        }
        if let p = peripheral, let installedP = lifetime.peripheral, installedP !== p {
            unlockTransport()
            return .noOp
        }
        let key = lifetime.relationKey
        activeOutboundLifetimes.removeValue(forKey: peerId)
        relationDelegates.removeValue(forKey: peerId)
        cancelTimerLocked(matching: key)
        let conn = outboundCentralConnections.removeValue(forKey: peerId)
        conn?.markDisconnected()
        connectedPeripherals.removeValue(forKey: peerId)
        inboxCharacteristics.removeValue(forKey: peerId)
        digestCharacteristics.removeValue(forKey: peerId)
        linkInfoCharacteristics.removeValue(forKey: peerId)
        pendingInitiatorRemoteHints.removeValue(forKey: peerId)
        pendingOutboundWrites.removeValue(forKey: peerId)
        unlockTransport()

        let action = snapshotCentral?.onFailedToConnect(peerId: peerId, error: error) ?? .noOp
        unpublishRelation(key)
        return action
    }

    public func processOutboundDisconnect(peerId: UUID, expectedGen: UInt64, peripheral: CBPeripheral? = nil, sourceEpoch: UInt64, from manager: CBCentralManager) -> BleCentralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessOutboundDisconnect(peerId: peerId, expectedGen: expectedGen, peripheral: peripheral, sourceEpoch: sourceEpoch, from: manager)
        }
    }

    public func reductionProcessOutboundDisconnect(peerId: UUID, expectedGen: UInt64, peripheral: CBPeripheral? = nil, sourceEpoch: UInt64, from manager: CBCentralManager) -> BleCentralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotCentral = centralDriver
        unlockTransport()

        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: manager
        ) else {
            unlockTransport()
            return .noOp
        }
        guard let lifetime = activeOutboundLifetimes[peerId], (sourceEpoch == 0 || lifetime.transportEpoch == sourceEpoch) else {
            unlockTransport()
            return .noOp
        }
        if let p = peripheral, let installedP = lifetime.peripheral, installedP !== p {
            unlockTransport()
            return .noOp
        }
        let key = lifetime.relationKey
        if expectedGen != 0 && key.generation != expectedGen {
            unlockTransport()
            return .noOp
        }
        activeOutboundLifetimes.removeValue(forKey: peerId)
        relationDelegates.removeValue(forKey: peerId)
        cancelTimerLocked(matching: key)
        outboundCentralConnections.removeValue(forKey: peerId)?.markDisconnected()
        connectedPeripherals.removeValue(forKey: peerId)
        inboxCharacteristics.removeValue(forKey: peerId)
        digestCharacteristics.removeValue(forKey: peerId)
        linkInfoCharacteristics.removeValue(forKey: peerId)
        pendingInitiatorRemoteHints.removeValue(forKey: peerId)
        pendingOutboundWrites.removeValue(forKey: peerId)
        unlockTransport()

        let action = snapshotCentral?.onDisconnected(peerId: peerId, expectedGen: key.generation) ?? .noOp
        unpublishRelation(key)
        return action
    }

    public func validateOutboundDelegate(_ delegate: RelationPeripheralDelegate, peerId: UUID) -> Bool {
        lockTransport()
        defer { unlockTransport() }
        guard delegate.transportEpoch == currentTransportEpoch else { return false }
        guard let lifetime = activeOutboundLifetimes[peerId] else { return false }
        return lifetime.transportEpoch == currentTransportEpoch && lifetime.relationKey == delegate.relationKey
    }

    public func processPeripheralDiscoverServices(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, error: Error? = nil) -> BleCentralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralDiscoverServices(p, delegate: delegate, error: error)
        }
    }

    public func reductionProcessPeripheralDiscoverServices(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, error: Error? = nil) -> BleCentralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotCentral = centralDriver
        unlockTransport()

        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return .noOp }
        let success = (error == nil && ((p?.services?.contains(where: { $0.uuid == BleTransport.serviceUuid })) ?? true))
        let action = snapshotCentral?.onServicesDiscovered(peerId: peerId, success: success) ?? .noOp
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
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralDiscoverCharacteristics(p, delegate: delegate, service: service, error: error)
        }
    }

    public func reductionProcessPeripheralDiscoverCharacteristics(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, service: CBService, error: Error? = nil) -> BleCentralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotCentral = centralDriver
        unlockTransport()

        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return .noOp }
        var tree: [ContractCharacteristic] = []
        for ch in service.characteristics ?? [] {
            tree.append(ContractCharacteristic(uuid: ch.uuid, properties: RequiredCharacteristicSet.propertiesOf(ch.properties)))
        }
        lockTransport()
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
        unlockTransport()

        // T10 provisioning gate: resolve the whole discovered tree against
        // the canonical profile -- all three roles exactly once, with their
        // required properties and nothing beyond the contract -- instead of
        // spot-checking the one characteristic this client happens to read.
        let success = (error == nil && BleTransport.meshProfile.accepts(tree))
        let action = snapshotCentral?.onCharacteristicsDiscovered(peerId: peerId, success: success) ?? .noOp
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
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralUpdateValue(p, delegate: delegate, characteristic: characteristic, error: error)
        }
    }

    public func reductionProcessPeripheralUpdateValue(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, characteristic: CBCharacteristic, error: Error? = nil) -> BleCentralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotCentral = centralDriver
        unlockTransport()

        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return .noOp }

        if characteristic.uuid == BleTransport.linkInfoCharacteristicUuid {
            let success = (error == nil)
            let action = snapshotCentral?.onLinkInfoReadResult(peerId: peerId, success: success, rawData: characteristic.value) ?? .noOp
            switch action {
            case .writeLinkInfo(_, let localData, let remoteHint):
                lockTransport()
                pendingInitiatorRemoteHints[peerId] = remoteHint
                unlockTransport()
                p?.writeValue(localData, for: characteristic, type: .withResponse)
            case .disconnectPeripheral:
                purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
            default: break
            }
            return action
        }

        if characteristic.uuid == BleTransport.inboxCharacteristicUuid {
            lockTransport()
            guard let conn = outboundCentralConnections[peerId], conn.isRoleBound else {
                unlockTransport()
                return .noOp
            }
            guard let record = conn.ingestInboundAttValue(characteristic.value ?? Data()) else {
                unlockTransport()
                return .noOp
            }
            unlockTransport()

            if record.recordType == .data && conn.state == .ready {
                // T14: opening a received record is trust work: it runs
                // outside the critical section, and its completion comes
                // back through the executor for a token check before the
                // delegate ever hears of it. An unauthenticated payload
                // (nil) is a failure, distinct from an empty success.
                recordTrustWorkForTest("open")
                if let clear = sessions?.open(peerId, record.payload) {
                    self.onExecutor {
                        self.lockTransport()
                        let still = self.isStarted
                            && (self.outboundCentralConnections[peerId] === conn)
                            && conn.state == .ready
                        self.unlockTransport()
                        guard still else { return }
                        self.delegate?.transportDidReceive(data: clear, peerId: peerId)
                    }
                }
            }
        }
        return .noOp
    }

    public func processPeripheralWriteValue(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, characteristic: CBCharacteristic, error: Error? = nil) -> BleCentralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralWriteValue(p, delegate: delegate, characteristic: characteristic, error: error)
        }
    }

    public func reductionProcessPeripheralWriteValue(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, characteristic: CBCharacteristic, error: Error? = nil) -> BleCentralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotCentral = centralDriver
        unlockTransport()

        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return .noOp }

        if characteristic.uuid == BleTransport.linkInfoCharacteristicUuid {
            lockTransport()
            let remoteHint = pendingInitiatorRemoteHints.removeValue(forKey: peerId)
            unlockTransport()

            let action = snapshotCentral?.onLinkInfoWriteAcknowledged(
                peerId: peerId,
                success: (error == nil),
                remoteHint: remoteHint ?? Data()
            ) ?? .noOp

            switch action {
            case .setNotify:
                lockTransport()
                if let inboxChar = inboxCharacteristics[peerId] {
                    let maxWrite = p?.maximumWriteValueLength(for: .withoutResponse) ?? 512
                    outboundCentralConnections[peerId]?.markConnected(negotiatedAttValueLength: maxWrite)
                    p?.setNotifyValue(true, for: inboxChar)
                }
                unlockTransport()
            case .disconnectPeripheral:
                purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
            default: break
            }
            return action
        }
        return .noOp
    }

    public func processPeripheralNotificationStateUpdated(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, characteristic: CBCharacteristic, error: Error? = nil) -> BleCentralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralNotificationStateUpdated(p, delegate: delegate, characteristic: characteristic, error: error)
        }
    }

    public func reductionProcessPeripheralNotificationStateUpdated(_ p: CBPeripheral?, delegate: RelationPeripheralDelegate, characteristic: CBCharacteristic, error: Error? = nil) -> BleCentralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotCentral = centralDriver
        unlockTransport()

        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return .noOp }

        if characteristic.uuid == BleTransport.inboxCharacteristicUuid {
            let success = (error == nil)
            let action = snapshotCentral?.onNotificationStateUpdated(peerId: peerId, success: success, isNotifying: characteristic.isNotifying) ?? .noOp
            switch action {
            case .physicalDuplexReady:
                lockTransport()
                cancelTimerLocked(matching: delegate.relationKey)
                unlockTransport()
                publishRelation(delegate.relationKey)
            case .disconnectPeripheral:
                purgeCentralConnection(peerId: peerId, cancelPeripheral: true)
            default: break
            }
            return action
        }
        return .noOp
    }

    public func processPeripheralIsReady(_ p: CBPeripheral, delegate: RelationPeripheralDelegate) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralIsReady(p, delegate: delegate)
        }
    }

    public func reductionProcessPeripheralIsReady(_ p: CBPeripheral, delegate: RelationPeripheralDelegate) {
        let peerId = delegate.relationKey.peerId
        guard validateOutboundDelegate(delegate, peerId: peerId) else { return }
        lockTransport()
        defer { unlockTransport() }
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
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionHandleOutboundTimeout(peerId: peerId, generation: generation)
        }
    }

    public func reductionHandleOutboundTimeout(peerId: UUID, generation: UInt64 = 0) -> BleCentralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotCentral = centralDriver
        unlockTransport()

        guard let driver = snapshotCentral else { return .noOp }
        lockTransport()
        cancelTimerLocked(matching: RelationKey(direction: .outboundCentral, peerId: peerId, generation: generation))
        unlockTransport()
        let currentGen = driver.getConnectionGeneration(peerId)
        if generation != 0 && currentGen != generation {
            return .noOp
        }
        if driver.isPhysicalReady(peerId) {
            return .noOp
        }
        let effectiveGen = (generation != 0) ? generation : currentGen
        let action = driver.onProvisionalTimeout(peerId: peerId, expectedGen: effectiveGen)
        lockTransport()
        activeOutboundLifetimes.removeValue(forKey: peerId)
        relationDelegates.removeValue(forKey: peerId)
        let p = connectedPeripherals.removeValue(forKey: peerId)
        outboundCentralConnections.removeValue(forKey: peerId)?.markDisconnected()
        inboxCharacteristics.removeValue(forKey: peerId)
        digestCharacteristics.removeValue(forKey: peerId)
        linkInfoCharacteristics.removeValue(forKey: peerId)
        pendingInitiatorRemoteHints.removeValue(forKey: peerId)
        pendingOutboundWrites.removeValue(forKey: peerId)
        unlockTransport()
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
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessInboundWrite(centralId: centralId, rawData: rawData, sourceEpoch: sourceEpoch, from: manager)
        }
    }

    public func reductionProcessInboundWrite(centralId: UUID, rawData: Data, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotPeripheral = peripheralDriver
        unlockTransport()

        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: manager
        ) else {
            unlockTransport()
            return .rejectWrite(centralId, "Transport not started or stale epoch")
        }
        guard let driver = snapshotPeripheral else {
            unlockTransport()
            return .noOp
        }
        unlockTransport()

        let action = driver.onCentralWrite(centralId: centralId, rawData: rawData)
        switch action {
        case .acceptWrite(let cid, let remoteHint),
             .acceptWriteAndDuplexReady(let cid, let remoteHint):
            lockTransport()
            let gen = driver.getCentralGeneration(cid)
            let key = RelationKey(direction: .inboundPeripheral, peerId: cid, generation: gen)
            let priorLease = activeInboundLifetimes[cid]
            activeInboundLifetimes[cid] = InboundSubscriptionLifetime(relationKey: key, transportEpoch: currentTransportEpoch,
                                                                      retainedCentral: priorLease?.retainedCentral,
                                                                      inboxSubscription: priorLease?.inboxSubscription)
            if let context = activeManagerContext, context.noteAdmission(cid) {
                context.markRotationDue()
            }

            if inboundPeripheralConnections[cid] == nil {
                inboundPeripheralConnections[cid] = driver.getInboundConnection(cid)
            }
            if let conn = inboundPeripheralConnections[cid], !conn.isRoleBound {
                conn.bindResponderFromAcceptedIncomingLinkInfo(remoteHint: remoteHint)
            }
            if timerSlots[TimerSlot(direction: .inboundPeripheral, peerId: cid, operation: .inboundInactivity)] == nil {
                // T15: no double-arm while a lease lives; the arm runs through
                // the reducer with the whole key.
                armTimerLocked(relation: key)
            }
            unlockTransport()
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

    public func processInboundSubscribe(centralId: UUID, central: CBCentral? = nil, characteristic: CBUUID = BleTransport.inboxCharacteristicUuid, maxUpdateLength: Int = 512, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessInboundSubscribe(centralId: centralId, central: central, characteristic: characteristic, maxUpdateLength: maxUpdateLength, sourceEpoch: sourceEpoch, from: manager)
        }
    }

    public func reductionProcessInboundSubscribe(centralId: UUID, central: CBCentral? = nil, characteristic: CBUUID = BleTransport.inboxCharacteristicUuid, maxUpdateLength: Int = 512, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotPeripheral = peripheralDriver
        unlockTransport()

        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: manager
        ) else {
            unlockTransport()
            return .noOp
        }
        guard let driver = snapshotPeripheral else {
            unlockTransport()
            return .noOp
        }
        unlockTransport()

        let action = driver.onCentralSubscribed(centralId: centralId)
        switch action {
        case .acceptSubscription(let cid), .acceptSubscriptionAndDuplexReady(let cid):
            lockTransport()
            // T16: distinguishability gate. A request that cannot tell which
            // very central presents itself - none offered where a central is
            // already retained, or another instance than the retained one
            // for this identity - is the reuse the platform callbacks cannot
            // distinguish within one manager epoch: quarantine the identity
            // for the epoch and refuse the request. Release is by rotation of
            // the context only, never by guessing a timeout.
            let existingLease = activeInboundLifetimes[cid]
            // A missing handle claims nothing: it renews the record and
            // keeps the retention. Only two distinct real instances
            // contending for one identity is the reuse the callbacks
            // cannot distinguish within one epoch - that is quarantined.
            if let lease = existingLease, let retained = lease.retainedCentral,
               let offered = central, offered !== retained {
                activeManagerContext?.quarantine(cid, reason: "indistinguishable-central-reuse")
                unlockTransport()
                return .rejectSubscription(cid)
            }
            if existingLease == nil, activeManagerContext?.isQuarantined(cid) == true {
                unlockTransport()
                return .rejectSubscription(cid)
            }
            let key = existingLease?.relationKey ?? RelationKey(direction: .inboundPeripheral, peerId: cid, generation: driver.getCentralGeneration(cid))
            cancelTimerLocked(matching: key)
            if let c = central {
                subscribedCentrals[cid] = c
            }
            activeInboundLifetimes[cid] = InboundSubscriptionLifetime(
                relationKey: key, transportEpoch: currentTransportEpoch,
                retainedCentral: central ?? existingLease?.retainedCentral,
                inboxSubscription: InboxSubscription(characteristicUuid: characteristic, maxUpdateLength: maxUpdateLength))
            if let context = activeManagerContext, context.noteAdmission(cid) {
                context.markRotationDue()
            }
            if inboundPeripheralConnections[cid] == nil {
                inboundPeripheralConnections[cid] = driver.getInboundConnection(cid)
            }
            if let conn = inboundPeripheralConnections[cid] {
                conn.markConnected(negotiatedAttValueLength: maxUpdateLength)
            }
            unlockTransport()
            if case .acceptSubscriptionAndDuplexReady = action {
                publishRelation(key)
            }
        default:
            break
        }
        return action
    }

    public func processInboundUnsubscribe(centralId: UUID, expectedGen: UInt64, characteristic: CBUUID? = nil, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessInboundUnsubscribe(centralId: centralId, expectedGen: expectedGen, characteristic: characteristic, sourceEpoch: sourceEpoch, from: manager)
        }
    }

    public func reductionProcessInboundUnsubscribe(centralId: UUID, expectedGen: UInt64, characteristic: CBUUID? = nil, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotPeripheral = peripheralDriver
        unlockTransport()

        guard let driver = snapshotPeripheral else { return .noOp }
        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: manager
        ) else {
            unlockTransport()
            return .noOp
        }
        guard let lifetime = activeInboundLifetimes[centralId], (sourceEpoch == 0 || lifetime.transportEpoch == sourceEpoch) else {
            unlockTransport()
            return .noOp
        }
        let key = lifetime.relationKey
        // T16: the characteristic filter. An unsubscribe request naming a
        // characteristic other than the inbox leaves the inbox subscription
        // intact - acknowledged, and nothing is touched. A request that
        // cannot say which characteristic was unsubscribed is the ambiguity
        // the callbacks must not guess through: the identity stands
        // quarantined for the epoch, the state frozen meanwhile.
        if let presented = characteristic, presented != BleTransport.inboxCharacteristicUuid {
            unlockTransport()
            return .acceptCharacteristicUnsubscribe(centralId, presented.uuidString)
        }
        // The legacy form cannot say which very characteristic was
        // unsubscribed: the identity is quarantined for the epoch, and
        // the removal proceeds all the same - the driver transitions the
        // slot and answers with its own action, as recorded.
        if characteristic == nil {
            activeManagerContext?.quarantine(centralId, reason: "ambiguous-unsubscribe")
        }
        // The inbox CCC: compare the generation the request itself carries
        // with the generation the subscription stands under - never resolve
        // the current one here, which would let a stale request remove a
        // replacement subscribed since.
        if expectedGen != 0 && key.generation != expectedGen {
            unlockTransport()
            return .rejectStaleUnsubscribe(centralId)
        }
        activeInboundLifetimes.removeValue(forKey: centralId)
        cancelTimerLocked(matching: key)
        inboundPeripheralConnections.removeValue(forKey: centralId)?.markDisconnected()
        subscribedCentrals.removeValue(forKey: centralId)
        pendingOutboundUpdates.removeValue(forKey: centralId)
        unlockTransport()

        let action = driver.onCentralUnsubscribed(centralId: centralId, expectedGen: key.generation)
        unpublishRelation(key)
        lockTransport()
        let rotated = executeRotationIfNeededLocked()
        let canAdv = isStarted && isServiceRegistered && (peripheral?.state == .poweredOn)
        unlockTransport()
        if rotated {
            if canAdv { startAdvertising() }
            startScanning()
        }
        return action
    }

    public func handleInboundTimeout(centralId: UUID, generation: UInt64 = 0) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionHandleInboundTimeout(centralId: centralId, generation: generation)
        }
    }

    public func reductionHandleInboundTimeout(centralId: UUID, generation: UInt64 = 0) {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotPeripheral = peripheralDriver
        unlockTransport()

        guard let driver = snapshotPeripheral else { return }
        lockTransport()
        cancelTimerLocked(matching: RelationKey(direction: .inboundPeripheral, peerId: centralId, generation: generation))
        unlockTransport()
        let currentGen = driver.getCentralGeneration(centralId)
        if generation != 0 && currentGen != generation {
            return
        }
        if generation != 0 && driver.isPhysicalReady(centralId) {
            return
        }
        let effectiveGen = (generation != 0) ? generation : currentGen
        driver.onInboundTimeout(centralId: centralId, expectedGen: effectiveGen)
        lockTransport()
        activeInboundLifetimes.removeValue(forKey: centralId)
        inboundPeripheralConnections.removeValue(forKey: centralId)?.markDisconnected()
        subscribedCentrals.removeValue(forKey: centralId)
        pendingOutboundUpdates.removeValue(forKey: centralId)
        unlockTransport()
        let key = RelationKey(direction: .inboundPeripheral, peerId: centralId, generation: effectiveGen)
        unpublishRelation(key)
        lockTransport()
        let rotated = executeRotationIfNeededLocked()
        let canAdv = isStarted && isServiceRegistered && (peripheral?.state == .poweredOn)
        unlockTransport()
        if rotated {
            if canAdv { startAdvertising() }
            startScanning()
        }
    }

    public func dispatchReceiveRead(centralId: UUID) -> BlePeripheralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionDispatchReceiveRead(centralId: centralId)
        }
    }

    public func reductionDispatchReceiveRead(centralId: UUID) -> BlePeripheralAction {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotPeripheral = peripheralDriver
        unlockTransport()

        return snapshotPeripheral?.onCentralRead(centralId: centralId) ?? .noOp
    }

    public func dispatchReceiveWrite(centralId: UUID, rawData: Data, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionDispatchReceiveWrite(centralId: centralId, rawData: rawData, sourceEpoch: sourceEpoch, from: manager)
        }
    }

    public func reductionDispatchReceiveWrite(centralId: UUID, rawData: Data, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        return processInboundWrite(centralId: centralId, rawData: rawData, sourceEpoch: sourceEpoch, from: manager)
    }

    public func dispatchSubscribe(centralId: UUID, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionDispatchSubscribe(centralId: centralId, sourceEpoch: sourceEpoch, from: manager)
        }
    }

    public func reductionDispatchSubscribe(centralId: UUID, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        return processInboundSubscribe(centralId: centralId, sourceEpoch: sourceEpoch, from: manager)
    }

    public func dispatchUnsubscribe(centralId: UUID, expectedGen: UInt64, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionDispatchUnsubscribe(centralId: centralId, expectedGen: expectedGen, sourceEpoch: sourceEpoch, from: manager)
        }
    }

    public func reductionDispatchUnsubscribe(centralId: UUID, expectedGen: UInt64, sourceEpoch: UInt64, from manager: CBPeripheralManager) -> BlePeripheralAction {
        return processInboundUnsubscribe(centralId: centralId, expectedGen: expectedGen, sourceEpoch: sourceEpoch, from: manager)
    }

    public func dispatchOutboundProvisionalTimeout(peerId: UUID, expectedGen: UInt64 = 0) -> BleCentralAction {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionDispatchOutboundProvisionalTimeout(peerId: peerId, expectedGen: expectedGen)
        }
    }

    public func reductionDispatchOutboundProvisionalTimeout(peerId: UUID, expectedGen: UInt64 = 0) -> BleCentralAction {
        return handleOutboundTimeout(peerId: peerId, generation: expectedGen)
    }

    public func dispatchInboundTimeout(centralId: UUID, expectedGen: UInt64 = 0) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionDispatchInboundTimeout(centralId: centralId, expectedGen: expectedGen)
        }
    }

    public func reductionDispatchInboundTimeout(centralId: UUID, expectedGen: UInt64 = 0) {
        handleInboundTimeout(centralId: centralId, generation: expectedGen)
    }

    public func isRelationPublished(direction: BleDirection, peerId: UUID, generation: UInt64 = 0) -> Bool {
        lockTransport()
        defer { unlockTransport() }
        if generation != 0 {
            return publishedRelations.contains(RelationKey(direction: direction, peerId: peerId, generation: generation))
        }
        return publishedRelations.contains(where: { $0.direction == direction && $0.peerId == peerId })
    }

    public func processCentralDidUpdateState(_ c: CBCentralManager, sourceEpoch: UInt64) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessCentralDidUpdateState(c, sourceEpoch: sourceEpoch)
        }
    }

    public func reductionProcessCentralDidUpdateState(_ c: CBCentralManager, sourceEpoch: UInt64) {
        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: c
        ) else {
            unlockTransport()
            return
        }
        let shouldScan = (c.state == .poweredOn)
        unlockTransport()
        if shouldScan {
            startScanning()
        }
    }

    public func processCentralWillRestoreState(_ c: CBCentralManager, dict: [String: Any], sourceEpoch: UInt64) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessCentralWillRestoreState(c, dict: dict, sourceEpoch: sourceEpoch)
        }
    }

    public func reductionProcessCentralWillRestoreState(_ c: CBCentralManager, dict: [String: Any], sourceEpoch: UInt64) {
        lockTransport()
        defer { unlockTransport() }
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

    public func processCentralDidDiscover(_ c: CBCentralManager,
        peripheral p: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber,
        sourceEpoch: UInt64) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessCentralDidDiscover(c, peripheral: p, advertisementData: advertisementData, rssi: RSSI, sourceEpoch: sourceEpoch)
        }
    }

    public func reductionProcessCentralDidDiscover(
        _ c: CBCentralManager,
        peripheral p: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber,
        sourceEpoch: UInt64
    ) {
        guard RSSI.intValue > -90 else { return }

        var metaHint: Data? = nil
        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: true,
            sender: c
        ) else {
            unlockTransport()
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
        unlockTransport()

        let action = processOutboundDiscover(peerId: p.identifier, rssi: RSSI.intValue, serviceDataHint: metaHint, peripheral: p, sourceEpoch: sourceEpoch, from: c)
        if case .connectPeripheral = action {
            c.connect(p, options: nil)
        }
    }

    public func processPeripheralManagerDidUpdateState(_ pm: CBPeripheralManager, sourceEpoch: UInt64) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralManagerDidUpdateState(pm, sourceEpoch: sourceEpoch)
        }
    }

    public func reductionProcessPeripheralManagerDidUpdateState(_ pm: CBPeripheralManager, sourceEpoch: UInt64) {
        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            unlockTransport()
            return
        }
        guard pm.state == .poweredOn else {
            unlockTransport()
            return
        }
        unlockTransport()

        let installed = BleTransport.characteristicsToInstall(BleTransport.meshProfile)
        let service = CBMutableService(type: BleTransport.meshProfile.serviceUuid, primary: true)
        service.characteristics = installed
        pm.add(service)

        lockTransport()
        mutableInboxCharacteristic = installed.first { $0.uuid == BleTransport.inboxCharacteristicUuid }
        mutableLinkInfoCharacteristic = installed.first { $0.uuid == BleTransport.linkInfoCharacteristicUuid }
        unlockTransport()
    }

    public func processPeripheralDidAddService(_ pm: CBPeripheralManager, service: CBService, error: Error?, sourceEpoch: UInt64) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralDidAddService(pm, service: service, error: error, sourceEpoch: sourceEpoch)
        }
    }

    public func reductionProcessPeripheralDidAddService(_ pm: CBPeripheralManager, service: CBService, error: Error?, sourceEpoch: UInt64) {
        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            unlockTransport()
            return
        }
        if error == nil && service.uuid == BleTransport.serviceUuid {
            isServiceRegistered = true
        }
        let shouldAdv = isStarted && isServiceRegistered
        unlockTransport()

        if shouldAdv {
            startAdvertising()
        }
    }

    public func processPeripheralWillRestoreState(_ pm: CBPeripheralManager, dict: [String: Any], sourceEpoch: UInt64) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralWillRestoreState(pm, dict: dict, sourceEpoch: sourceEpoch)
        }
    }

    public func reductionProcessPeripheralWillRestoreState(_ pm: CBPeripheralManager, dict: [String: Any], sourceEpoch: UInt64) {
        lockTransport()
        let authentic = managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        )
        guard isStarted, authentic else {
            unlockTransport()
            return
        }
        unlockTransport()

    }

    public func processPeripheralReceiveRead(_ pm: CBPeripheralManager, request: CBATTRequest, sourceEpoch: UInt64) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralReceiveRead(pm, request: request, sourceEpoch: sourceEpoch)
        }
    }

    public func reductionProcessPeripheralReceiveRead(_ pm: CBPeripheralManager, request: CBATTRequest, sourceEpoch: UInt64) {
        // T14: read the drivers once, at the critical instant of admission,
        // under the lock that guards their assignment; the reduction below
        // proceeds on these captured references, outside any lock.
        lockTransport()
        let snapshotPeripheral = peripheralDriver
        unlockTransport()

        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            unlockTransport()
            pm.respond(to: request, withResult: .unlikelyError)
            return
        }
        unlockTransport()

        if BleTransport.classifyInbound(request.characteristic.uuid) == .toLinkInfo {
            if request.offset != 0 {
                pm.respond(to: request, withResult: .invalidOffset)
                return
            }
            let action = snapshotPeripheral?.onCentralRead(centralId: request.central.identifier) ?? .noOp
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

    public func processPeripheralReceiveWrite(_ pm: CBPeripheralManager, requests: [CBATTRequest], sourceEpoch: UInt64) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralReceiveWrite(pm, requests: requests, sourceEpoch: sourceEpoch)
        }
    }

    public func reductionProcessPeripheralReceiveWrite(_ pm: CBPeripheralManager, requests: [CBATTRequest], sourceEpoch: UInt64) {
        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            unlockTransport()
            for r in requests {
                pm.respond(to: r, withResult: .unlikelyError)
            }
            return
        }
        unlockTransport()

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

                lockTransport()
                guard let conn = inboundPeripheralConnections[centralId], conn.isRoleBound else {
                    unlockTransport()
                    pm.respond(to: r, withResult: .unlikelyError)
                    continue
                }

                let record = conn.ingestInboundAttValue(v)
                unlockTransport()

                if let rec = record, rec.recordType == .data && conn.state == .ready {
                    // T14: as above - trust work outside, completion revalidated
                    // on the executor against the very connection that earned it.
                    recordTrustWorkForTest("open")
                    if let clear = sessions?.open(centralId, rec.payload) {
                        self.onExecutor {
                            self.lockTransport()
                            let still = self.isStarted
                                && (self.inboundPeripheralConnections[centralId] === conn)
                                && conn.state == .ready
                            self.unlockTransport()
                            guard still else { return }
                            self.delegate?.transportDidReceive(data: clear, peerId: centralId)
                        }
                    }
                }
                pm.respond(to: r, withResult: .success)
                continue
            }

            pm.respond(to: r, withResult: .requestNotSupported)
        }
    }

    public func processPeripheralDidSubscribe(_ pm: CBPeripheralManager, central: CBCentral, characteristic ch: CBCharacteristic, sourceEpoch: UInt64) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralDidSubscribe(pm, central: central, characteristic: ch, sourceEpoch: sourceEpoch)
        }
    }

    public func reductionProcessPeripheralDidSubscribe(_ pm: CBPeripheralManager, central: CBCentral, characteristic ch: CBCharacteristic, sourceEpoch: UInt64) {
        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            unlockTransport()
            return
        }
        unlockTransport()

        guard ch.uuid == BleTransport.inboxCharacteristicUuid else { return }
        _ = processInboundSubscribe(centralId: central.identifier, central: central, maxUpdateLength: central.maximumUpdateValueLength, sourceEpoch: sourceEpoch, from: pm)
    }

    public func processPeripheralDidUnsubscribe(_ pm: CBPeripheralManager, central: CBCentral, characteristic ch: CBCharacteristic, sourceEpoch: UInt64) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralDidUnsubscribe(pm, central: central, characteristic: ch, sourceEpoch: sourceEpoch)
        }
    }

    public func reductionProcessPeripheralDidUnsubscribe(_ pm: CBPeripheralManager, central: CBCentral, characteristic ch: CBCharacteristic, sourceEpoch: UInt64) {
        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            unlockTransport()
            return
        }
        unlockTransport()

        _ = processInboundUnsubscribe(centralId: central.identifier, expectedGen: 0, sourceEpoch: sourceEpoch, from: pm)
    }

    public func processPeripheralIsReadyToUpdateSubscribers(_ pm: CBPeripheralManager, sourceEpoch: UInt64) -> Void {
        // T14: the whole reduction of this event - validation, transition,
        // effect scheduling - is one operation on the epoch serial executor.
        return onExecutor {
            self.reductionProcessPeripheralIsReadyToUpdateSubscribers(pm, sourceEpoch: sourceEpoch)
        }
    }

    public func reductionProcessPeripheralIsReadyToUpdateSubscribers(_ pm: CBPeripheralManager, sourceEpoch: UInt64) {
        lockTransport()
        guard isStarted, managerEventIsAuthenticLocked(
            sourceEpoch: sourceEpoch,
            isCentral: false,
            sender: pm
        ) else {
            unlockTransport()
            return
        }
        guard let inboxChar = mutableInboxCharacteristic else {
            unlockTransport()
            return
        }

        for (centralId, var queue) in pendingOutboundUpdates {
            // T16: send through the retained handle; suppress a quarantined
            // identity altogether.
            if activeManagerContext?.isQuarantined(centralId) == true {
                continue
            }
            guard let lease = activeInboundLifetimes[centralId],
                  let centralObj = lease.retainedCentral else {
                pendingOutboundUpdates.removeValue(forKey: centralId)
                continue
            }

            while !queue.isEmpty {
                let nextItem = queue[0]
                let ok = pm.updateValue(nextItem, for: inboxChar, onSubscribedCentrals: [centralObj])
                recordResponderSendLocked(ResponderSendRecord(centralId: centralId, byteCount: nextItem.count,
                                                    via: ObjectIdentifier(centralObj), viaRetained: true))
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
        unlockTransport()
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
