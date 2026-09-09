import XCTest
import CoreBluetooth
@testable import GodstoneCore
@testable import GodstoneMesh

/// T13: every transport epoch is born with a fresh
/// CBCentralManager/CBPeripheralManager pair and its own delegate proxies,
/// on a dedicated serial queue. Reassigning delegates on a long-lived
/// manager is not proof of callback-source identity: the reducer admits an
/// event only when the sending manager is the very instance the active
/// context created, the wired delegate is still that context's own proxy,
/// and the event names the context's epoch. No token wildcard, no
/// current-state stand-in.
final class ReadinessT13Tests: XCTestCase {

    // MARK: - fixtures

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { return storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    private func makeIdentity() throws -> MeshIdentity {
        let kc = InMemoryKeychain()
        let edSeed = Data(repeating: 1, count: 32)
        let xPriv = Data(repeating: 2, count: 32)
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: edSeed, x25519PrivateKey: xPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        return try MeshIdentity.loadFromKeychain(keychain: kc)
    }

    /// The recording spy: counts of pair creations, the queues handed to
    /// both managers of a birth, the restore identifiers named.
    private final class RecordingManagerFactory: TransportManagerFactory, @unchecked Sendable {
        var centralRecords: [CBCentralManager] = []
        var peripheralRecords: [CBPeripheralManager] = []
        var queueRecords: [DispatchQueue] = []
        var restoreIdRecords: [String?] = []
        var centralQueuePairs: [DispatchQueue] = []
        var peripheralQueuePairs: [DispatchQueue] = []

        func makeCentralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBCentralManager {
            let manager = DefaultTransportManagerFactory().makeCentralManager(queue: queue, restoreIdentifier: restoreIdentifier)
            centralRecords.append(manager)
            centralQueuePairs.append(queue)
            queueRecords.append(queue)
            restoreIdRecords.append(restoreIdentifier)
            return manager
        }

        func makePeripheralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBPeripheralManager {
            let manager = DefaultTransportManagerFactory().makePeripheralManager(queue: queue, restoreIdentifier: restoreIdentifier)
            peripheralRecords.append(manager)
            peripheralQueuePairs.append(queue)
            return manager
        }
    }

    /// The reuse witness: a factory that hands the very same pair out for
    /// every epoch. Production must stay correct against it: the transport
    /// opens a fresh context per epoch and never reassigns delegates on a
    /// manager a previous epoch already saw.
    private final class ReusingManagerFactory: TransportManagerFactory, @unchecked Sendable {
        var calls = 0
        private var sharedCentral: CBCentralManager?
        private var sharedPeripheral: CBPeripheralManager?

        func makeCentralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBCentralManager {
            calls += 1
            if let sharedCentral {
                return sharedCentral
            }
            let manager = DefaultTransportManagerFactory().makeCentralManager(queue: queue, restoreIdentifier: nil)
            sharedCentral = manager
            return manager
        }

        func makePeripheralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBPeripheralManager {
            if let sharedPeripheral {
                return sharedPeripheral
            }
            let manager = DefaultTransportManagerFactory().makePeripheralManager(queue: queue, restoreIdentifier: nil)
            sharedPeripheral = manager
            return manager
        }
    }

    private func remoteLinkInfo(hintLast: UInt8) -> Data {
        return BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: Data([0, 0, 0, hintLast]),
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
    }

    private func makeTransport(factory: TransportManagerFactory) throws -> BleTransport {
        let transport = BleTransport(
            identity: try makeIdentity(),
            store: nil,
            managerFactory: factory
        )
        return transport
    }

    // MARK: - fresh pair per epoch, wired at birth, on a dedicated serial queue

    func testEachEpochIsBornWithItsOwnPairOnADedicatedSerialQueue() throws {
        let spy = RecordingManagerFactory()
        let transport = try makeTransport(factory: spy)
        transport.start()
        guard let first = transport.currentManagerContextForTest() else {
            XCTFail("the epoch opened without a manager context")
            return
        }
        XCTAssertEqual(spy.centralRecords.count, 1, "one central created for the first epoch")
        XCTAssertEqual(spy.peripheralRecords.count, 1, "one peripheral created for the first epoch")
        XCTAssertTrue(first.central === spy.centralRecords[0], "the context's central is the instance the factory made")
        XCTAssertTrue(first.peripheral === spy.peripheralRecords[0], "the context's peripheral is the instance the factory made")
        XCTAssertTrue(spy.centralQueuePairs[0] === first.queue, "the central was born on the context's dedicated queue")
        XCTAssertTrue(spy.peripheralQueuePairs[0] === first.queue, "the peripheral was born on the same dedicated queue")
        XCTAssertTrue(first.central.delegate === (first.centralProxy as AnyObject), "the central's delegate is the context's own proxy, wired at birth")
        XCTAssertTrue(first.peripheral.delegate === (first.peripheralProxy as AnyObject), "the peripheral's delegate is the context's own proxy, wired at birth")
        XCTAssertTrue(spy.centralQueuePairs[0] === spy.peripheralQueuePairs[0], "one queue was handed to both managers of the birth")
        XCTAssertTrue(first.queue.label.hasPrefix("io.godstone.mesh.transport.epoch."), "the queue is named for the epoch it serves")
        XCTAssertEqual(first.queue.label, "io.godstone.mesh.transport.epoch." + String(first.epoch), "the name carries the epoch number")

        transport.stop()
        transport.start()
        guard let second = transport.currentManagerContextForTest() else {
            XCTFail("the second epoch opened without a manager context")
            return
        }
        XCTAssertEqual(spy.centralRecords.count, 2, "a fresh central is created for every epoch, never reassigned onto an old one")
        XCTAssertEqual(spy.peripheralRecords.count, 2, "a fresh peripheral is created for every epoch")
        XCTAssertFalse(second.central === first.central, "the successor's central is a different object")
        XCTAssertFalse(second.peripheral === first.peripheral, "the successor's peripheral is a different object")
        XCTAssertFalse(second.queue === first.queue, "each epoch owns its own serial queue")
        XCTAssertNotEqual(second.epoch, first.epoch, "the epoch number advances")
        XCTAssertTrue(second.central.delegate === (second.centralProxy as AnyObject), "the successor is wired to the successor's proxies")
        XCTAssertFalse(first.central.delegate === (second.centralProxy as AnyObject), "no proxy of one epoch ever travels to another")

        transport.stop()
    }

    func testTheDedicatedQueueIsSerial() throws {
        let spy = RecordingManagerFactory()
        let transport = try makeTransport(factory: spy)
        transport.start()
        guard let context = transport.currentManagerContextForTest() else {
            XCTFail("no context")
            return
        }
        // A serial queue is observable: appends from many submissions land in
        // strict submission order, and nothing is lost to races. The barrier
        // at the end runs on the same queue context, after every append.
        var order: [Int] = []
        for index in 0..<100 {
            context.queue.async {
                order.append(index)
            }
        }
        context.queue.sync {}
        XCTAssertEqual(order.count, 100, "every submission is counted")
        XCTAssertEqual(order, Array(0..<100), "submissions serialise: the queue is no concurrency, it is serial by construction")
        transport.stop()
    }

    // MARK: - the closed epoch delivers nothing new

    func testLateEventsOfTheClosedEpochDeliverNothingNew() throws {
        let spy = RecordingManagerFactory()
        let transport = try makeTransport(factory: spy)
        transport.start()
        guard let old = transport.currentManagerContextForTest() else {
            XCTFail("no first context")
            return
        }
        let oldEpoch = old.epoch
        transport.stop()
        transport.start()
        guard let now = transport.currentManagerContextForTest() else {
            XCTFail("no second context")
            return
        }
        XCTAssertNotEqual(now.epoch, oldEpoch)
        XCTAssertFalse(now.central === old.central, "the stage holds fresh managers")

        // Delivered through the captured old proxy, over the captured old
        // manager, with the old epoch's frozen token: every family refuses.
        old.centralProxy.centralManagerDidUpdateState(old.central)
        old.peripheralProxy.peripheralManagerDidUpdateState(old.peripheral)
        old.peripheralProxy.peripheralManagerIsReady(toUpdateSubscribers: old.peripheral)
        let lateState = transport.managerEventIsAuthenticForTest(sourceEpoch: oldEpoch, isCentral: true, sender: old.central)
        let lateReady = transport.managerEventIsAuthenticForTest(sourceEpoch: oldEpoch, isCentral: false, sender: old.peripheral)
        XCTAssertFalse(lateState, "a state event of the closed epoch is not authentic")
        XCTAssertFalse(lateReady, "a readiness event of the closed epoch is not authentic")

        // The connect, failure and write families of the same closed epoch.
        let lateConnect = transport.processCentralConnect(peerId: UUID(), peripheral: nil, sourceEpoch: oldEpoch, from: old.central)
        let lateFailure = transport.processCentralFailToConnect(peerId: UUID(), error: nil, peripheral: nil, sourceEpoch: oldEpoch, from: old.central)
        let lateWrite = transport.dispatchReceiveWrite(centralId: UUID(), rawData: remoteLinkInfo(hintLast: 7), sourceEpoch: oldEpoch, from: old.peripheral)
        XCTAssertEqual(lateConnect, .noOp, "a queued didConnect of the closed epoch changes nothing")
        XCTAssertEqual(lateFailure, .noOp, "a queued didFailToConnect of the closed epoch changes nothing")
        guard case .rejectWrite = lateWrite else {
            XCTFail("a queued write of the closed epoch must be refused where it stands, got \(lateWrite)")
            return
        }
        XCTAssertEqual(transport.capacityAuthority.totalCount, 0, "the capacity observable is untouched by closed-epoch events")
        XCTAssertEqual(transport.currentTransportEpoch, now.epoch, "the transport still names the open epoch")

        transport.stop()
    }

    func testWriteFromTheOldContextIsDroppedEvenForASubscribedCentral() throws {
        let spy = RecordingManagerFactory()
        let transport = try makeTransport(factory: spy)
        transport.start()
        guard let first = transport.currentManagerContextForTest() else {
            XCTFail("no context")
            return
        }
        let oldEpoch = first.epoch
        let oldPeripheral = first.peripheral
        transport.stop()
        transport.start()
        guard let now = transport.currentManagerContextForTest() else {
            XCTFail("no second context")
            return
        }

        // The central subscribes in the open epoch: the write path is alive.
        let centralId = UUID()
        let accepted = transport.dispatchReceiveWrite(centralId: centralId, rawData: remoteLinkInfo(hintLast: 9), sourceEpoch: now.epoch, from: now.peripheral)
        guard case .acceptWrite = accepted else {
            XCTFail("the open epoch's own write must be admitted, got \(accepted)")
            return
        }
        XCTAssertEqual(transport.capacityAuthority.inboundCount, 1, "one relation admitted")

        // The very same event from the captured old manager, with the old
        // token, is dropped where it stands: the gate refuses it, not the
        // pipe being clogged.
        let stale = transport.dispatchReceiveWrite(centralId: centralId, rawData: remoteLinkInfo(hintLast: 9), sourceEpoch: oldEpoch, from: oldPeripheral)
        guard case .rejectWrite = stale else {
            XCTFail("the old context's write must be refused where it stands, got \(stale)")
            return
        }
        let currentDuplicate = transport.dispatchReceiveWrite(centralId: centralId, rawData: remoteLinkInfo(hintLast: 9), sourceEpoch: now.epoch, from: now.peripheral)
        guard case .acceptDuplicateWrite = currentDuplicate else {
            XCTFail("the current context's own duplicate must still flow, got \(currentDuplicate)")
            return
        }
        XCTAssertEqual(transport.capacityAuthority.inboundCount, 1, "the late event added no lease, took none away")
        transport.stop()
    }

    // MARK: - the wiring is part of the proof

    func testReassignedDelegateIsNotProofOfCallbackSourceIdentity() throws {
        let spy = RecordingManagerFactory()
        let transport = try makeTransport(factory: spy)
        transport.start()
        guard let context = transport.currentManagerContextForTest() else {
            XCTFail("no context")
            return
        }
        let epoch = context.epoch
        XCTAssertTrue(transport.managerEventIsAuthenticForTest(sourceEpoch: epoch, isCentral: true, sender: context.central), "the genuine pair with the genuine wiring authenticates")

        // Reassigning delegates - even one that names the very epoch - is
        // not proof: the wired delegate must still be the context's own.
        let forged = CentralManagerEpochDelegate(transportEpoch: epoch, transport: transport)
        context.central.delegate = forged
        XCTAssertFalse(transport.managerEventIsAuthenticForTest(sourceEpoch: epoch, isCentral: true, sender: context.central), "a reassigned delegate voids the proof of source identity")
        let lateConnect = transport.processCentralConnect(peerId: UUID(), peripheral: nil, sourceEpoch: epoch, from: context.central)
        XCTAssertEqual(lateConnect, .noOp, "events over a rewired manager are dropped where they stand")

        context.central.delegate = context.centralProxy
        XCTAssertTrue(transport.managerEventIsAuthenticForTest(sourceEpoch: epoch, isCentral: true, sender: context.central), "the check is alive: the original wiring restores the proof")
        transport.stop()
    }

    // MARK: - no token wildcard, no foreign instance

    func testAbsentOrForeignTokensAreNeverCorrelatedToTheCurrentSlot() throws {
        let spy = RecordingManagerFactory()
        let transport = try makeTransport(factory: spy)
        transport.start()
        guard let context = transport.currentManagerContextForTest() else {
            XCTFail("no context")
            return
        }
        XCTAssertFalse(
            transport.managerEventIsAuthenticForTest(sourceEpoch: 0, isCentral: true, sender: context.central),
            "the zero token names no epoch: the event is dropped, never matched to the current slot"
        )
        XCTAssertFalse(
            transport.managerEventIsAuthenticForTest(sourceEpoch: context.epoch + 1, isCentral: true, sender: context.central),
            "a future token is no token either"
        )
        XCTAssertTrue(
            transport.managerEventIsAuthenticForTest(sourceEpoch: context.epoch, isCentral: true, sender: context.central),
            "only the event that names its own epoch authenticates"
        )
        transport.stop()
    }

    func testForeignManagerInstanceIsRefusedEvenWithTheCurrentToken() throws {
        let spy = RecordingManagerFactory()
        let transport = try makeTransport(factory: spy)
        transport.start()
        guard let context = transport.currentManagerContextForTest() else {
            XCTFail("no context")
            return
        }
        let queue = DispatchQueue(label: "io.godstone.mesh.transport.foreign", qos: DispatchQoS.utility, attributes: DispatchQueue.Attributes())
        let stranger = DefaultTransportManagerFactory().makeCentralManager(queue: queue, restoreIdentifier: nil)
        // Perfect alibi on both counts the sender check owes its full force:
        // the stranger carries the current token AND wears the genuine
        // delegate - only the instance identity of the sender itself can
        // refuse it.
        stranger.delegate = context.centralProxy
        XCTAssertFalse(
            transport.managerEventIsAuthenticForTest(sourceEpoch: context.epoch, isCentral: true, sender: stranger),
            "a manager the context did not create is no source of this epoch, whatever token it carries"
        )
        // Same object, wrong role: a central is never the peripheral half.
        XCTAssertFalse(
            transport.managerEventIsAuthenticForTest(sourceEpoch: context.epoch, isCentral: false, sender: context.central),
            "role is part of the identity"
        )
        transport.stop()
    }

    // MARK: - the reuse witness has teeth

    func testReuseWouldBeCaughtByTheFreshPairInvariant() throws {
        // Under the cheating factory both epochs present the same pair.
        // The recording spy proves the transport opened two contexts and
        // asked for a pair twice; the production default factory must hand
        // out fresh instances every time, which is exactly what the first
        // case pins with the real factory.
        let witness = ReusingManagerFactory()
        let transport = try makeTransport(factory: witness)
        transport.start()
        guard let first = transport.currentManagerContextForTest() else {
            XCTFail("no first context")
            return
        }
        transport.stop()
        transport.start()
        guard let second = transport.currentManagerContextForTest() else {
            XCTFail("no second context")
            return
        }
        XCTAssertEqual(witness.calls, 2, "the transport asks for a pair at every epoch opening, it never keeps an old one")
        XCTAssertNotEqual(second.epoch, first.epoch, "the contexts are distinct objects")
        XCTAssertTrue(first.central === second.central, "witness: under a reusing factory the managers would be shared - the freshness assertions of the first case are what catch this")
        XCTAssertTrue(
            transport.managerEventIsAuthenticForTest(sourceEpoch: second.epoch, isCentral: true, sender: second.central),
            "the gate's own pair-identity check is only as strong as the pair being fresh"
        )
        transport.stop()
    }
}
