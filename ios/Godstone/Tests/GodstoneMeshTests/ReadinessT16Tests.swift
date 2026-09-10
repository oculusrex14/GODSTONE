import XCTest
import Foundation
import CoreBluetooth
@testable import GodstoneCore
@testable import GodstoneMesh

/// T16: ambiguous subscription and terminal lifetimes are closed.
/// The actual CBCentral is retained with its inbound lease; responder
/// notifications are sent through that retained handle. Unsubscribe
/// requests are filtered by characteristic: a digest unsubscribe leaves
/// the inbox intact, an unsubscribe that cannot name its characteristic
/// quarantines the identity for the epoch - released only by rotation of
/// the manager context, never by guessing a timeout. didFailToConnect is
/// terminal without requesting a disconnect. The admission history is
/// bounded and a fully drained context rotates when its budget is spent.
final class ReadinessT16Tests: XCTestCase {

    // MARK: - fixtures (the proven corpus shapes)

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { return storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    private final class TestClock: MonotonicClock, @unchecked Sendable {
        private let lk = NSLock()
        private var base: UInt64
        init(startingAt: UInt64) { base = startingAt }
        func nowUptimeMillis() -> UInt64 {
            lk.lock(); defer { lk.unlock() }
            return base
        }
        func advance(_ ms: UInt64) {
            lk.lock(); base &+= ms; lk.unlock()
        }
    }

    /// A central present: a real NSObject carrying the identifier the stack
    /// resolves, bridged to CBCentral by reference - the same idiom the
    /// substrate's responder sequences use.
    /// T19: the responder's own capture manager. The house record of this
    /// sandbox is that an update towards the retained handle reaches the
    /// subscriber; the manager states that truth and nothing else.
    private final class PinnedResponderManager: CBPeripheralManager, @unchecked Sendable {
        override func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic,
                                  onSubscribedCentrals centrals: [CBCentral]?) -> Bool {
            return true
        }
        override func respond(to request: CBATTRequest, withResult result: CBATTError.Code) {}
    }

    private final class PinnedResponderFactory: NSObject, TransportManagerFactory, @unchecked Sendable {
        func makeCentralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBCentralManager {
            return CBCentralManager(delegate: nil, queue: queue)
        }
        func makePeripheralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBPeripheralManager {
            return PinnedResponderManager(delegate: nil, queue: queue)
        }
    }

    private final class PresentCentral: NSObject, @unchecked Sendable {
        @objc let identifier: UUID
        // T19: the responder's send asks the destination central what it may
        // carry as an update before it reserves the record; the house default.
        @objc var maximumUpdateValueLength: Int = 512
        let tag = UUID()
        init(identifier: UUID) {
            self.identifier = identifier
            super.init()
        }
    }

    /// A peripheral present for the contrast leg: identifier, state and the
    /// delegate the stack wires at admission.
    private final class PresentPeripheral: NSObject, @unchecked Sendable {
        @objc let identifier: UUID
        @objc var state: CBPeripheralState = .disconnected
        @objc var services: [CBService]?
        @objc var delegate: CBPeripheralDelegate?
        init(identifier: UUID) {
            self.identifier = identifier
            super.init()
        }

        // The stack messages the whole family to the handle; the present
        // answers each selector with an empty body and remembers nothing.
        @objc func discoverServices(_ services: [CBUUID]) {}
        @objc func discoverCharacteristics(_ characteristics: [CBUUID], for service: CBService) {}
        @objc func readRSSI() {}
        @objc func readCharacter(_ characteristic: CBCharacteristic) {}
        @objc func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {}
        @objc func setNotifyValue(_ v: Bool, for characteristic: CBCharacteristic) {}
    }

    private final class OpeningFactory: TransportManagerFactory, @unchecked Sendable {
        private let lock = NSLock()
        private var centralOpenings = 0
        private var peripheralOpenings = 0
        private var queueLabels: [String] = []
        var budgetOverride: Int?
        init(budgetOverride: Int? = nil) { self.budgetOverride = budgetOverride }
        func makeCentralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBCentralManager {
            lock.lock(); centralOpenings += 1; queueLabels.append(queue.label); lock.unlock()
            return CBCentralManager(delegate: nil, queue: queue)
        }
        func makePeripheralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBPeripheralManager {
            lock.lock(); peripheralOpenings += 1; queueLabels.append(queue.label); lock.unlock()
            return CBPeripheralManager(delegate: nil, queue: queue)
        }
        var admissionBudgetOverride: Int? { return budgetOverride }
        func openings() -> (central: Int, peripheral: Int, labels: [String]) {
            lock.lock(); defer { lock.unlock() }
            return (centralOpenings, peripheralOpenings, queueLabels)
        }
    }

    private func makeIdentity(seedByte: UInt8 = 1, staticPrivByte: UInt8 = 2, generation: UInt32 = 0) throws -> MeshIdentity {
        let kc = InMemoryKeychain()
        let edSeed = Data(repeating: seedByte, count: 32)
        let xPriv = Data(repeating: staticPrivByte, count: 32)
        let state = try LocalIdentityStateV1(generation: generation, ed25519Seed: edSeed, x25519PrivateKey: xPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        return try MeshIdentity.loadFromKeychain(keychain: kc)
    }

    private func remoteLinkInfo(hint: Data) -> Data {
        return BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: hint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
    }

    private var retainedPresents: [AnyObject] = []

    private func centralPresent(_ identity: UUID) -> CBCentral {
        let peer = PresentCentral(identifier: identity)
        // The present outlives the test: the stack sends it messages long
        // after this function returns, so the instance keeps it alive.
        retainedPresents.append(peer)
        return unsafeBitCast(peer, to: CBCentral.self)
    }

    private func peripheralPresent(_ identity: UUID) -> CBPeripheral {
        let peer = PresentPeripheral(identifier: identity)
        retainedPresents.append(peer)
        return unsafeBitCast(peer, to: CBPeripheral.self)
    }

    private func inboundGeneration(_ driver: BlePeripheralOrchestrationDriver?, _ id: UUID) -> UInt64 {
        switch driver?.getInboundSlotState(id) {
        case .active(let g)?: return g
        case .quarantined(_, let g)?: return g
        default: return 0
        }
    }

    /// The accepted-incoming + subscribed preamble that puts one inbound
    /// connection into the ready state through the real entries.
    @discardableResult
    private func establishInbound(_ transport: BleTransport, centralId: UUID,
                                  central: CBCentral?) -> Bool {
        let pm = transport.requireContextPeripheralForTest()
        let w = transport.processInboundWrite(centralId: centralId,
                                              rawData: remoteLinkInfo(hint: Data([0, 0, 0, 1])),
                                              sourceEpoch: transport.currentTransportEpoch, from: pm)
        guard String(describing: w).hasPrefix("accept") else { return false }
        let s = transport.processInboundSubscribe(centralId: centralId, central: central,
                                                 sourceEpoch: transport.currentTransportEpoch, from: pm)
        guard String(describing: s).hasPrefix("accept") else { return false }
        transport.setMutableInboxCharacteristicForTesting(CBMutableCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        ))
        guard let conn = transport.connection(for: centralId) else { return false }
        conn.markReadyForTesting()
        return true
    }

    private func makeFrame(_ payload: [UInt8]) -> FrameV2 {
        return FrameV2(
            type: .message,
            msgId: Data(repeating: 0x7E, count: 16),
            routingTag: Data(repeating: 0, count: 4),
            ttl: 10,
            hopCount: 0,
            flags: Priority.toFlags(.direct),
            payload: Data(payload)
        )
    }

    // MARK: - digest unsubscribe leaves the inbox intact

    func testDigestUnsubscribeLeavesTheInboxIntact() throws {
        let pairing = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pairing) }
        let pinnedFactory = PinnedResponderFactory()
        let transport = BleTransport(identity: pairing.bobIdentity, store: nil,
                                     managerFactory: pinnedFactory,
                                     clock: TestClock(startingAt: 5_000))
        transport.sessions = pairing.bobManager
        transport.start()
        let centralId = pairing.viaAlice
        let handle = centralPresent(centralId)
        guard establishInbound(transport, centralId: centralId, central: handle) else {
            XCTFail("the inbound preamble did not establish"); return
        }
        let ringBefore = transport.responderSendRecordsForTest().count

        // T19 pins the responder's manager: the real stack's answer to an
        // update towards a mock handle is its own business, and a fixture
        // must not rest on it. The capture manager below answers as this
        // house has always recorded in this sandbox: the update reaches the
        // subscribed central through the retained handle.
        XCTAssertEqual(transport.send(makeFrame([1, 2, 3]), to: centralId), .admitted,
                       "the responder has data to send")
        XCTAssertEqual(transport.responderSendRecordsForTest().count, ringBefore + 1,
                       "the update reached the subscribers")

        // The unsubscribe names the digest characteristic, not the inbox.
        let gen = inboundGeneration(transport.peripheralDriver, centralId)
        let outcome = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: gen,
                                                          characteristic: BleTransport.digestCharacteristicUuid,
                                                          sourceEpoch: transport.currentTransportEpoch,
                                                          from: transport.requireContextPeripheralForTest())
        XCTAssertTrue(String(describing: outcome).hasPrefix("acceptCharacteristicUnsubscribe"),
                      "the digest unsubscribe is acknowledged: \(outcome)")
        XCTAssertNotNil(transport.getInboundLifetime(centralId),
                        "the inbox subscription stands untouched")

        // And notifications still flow through the retained handle.
        XCTAssertEqual(transport.send(makeFrame([4, 5, 6]), to: centralId), .admitted)
        let records = transport.responderSendRecordsForTest()
        XCTAssertEqual(records.count, ringBefore + 2)
        XCTAssertEqual(records.last?.via, ObjectIdentifier(handle),
                       "notifications go through the central retained with the lease")
        XCTAssertTrue(records.last?.viaRetained ?? false)
        transport.stop()
    }

    // MARK: - the ambiguous (legacy) unsubscribe quarantines until rotation

    func testAmbiguousUnsubscribeQuarantinesUntilRotationOnly() throws {
        let pairing = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pairing) }
        let clock = TestClock(startingAt: 5_000)
        let transport = BleTransport(identity: pairing.bobIdentity, store: nil, clock: clock)
        transport.sessions = pairing.bobManager
        transport.start()
        let centralId = pairing.viaAlice
        let handle = centralPresent(centralId)
        guard establishInbound(transport, centralId: centralId, central: handle) else {
            XCTFail("the inbound preamble did not establish"); return
        }
        let gen = inboundGeneration(transport.peripheralDriver, centralId)

        // The callback cannot say which very characteristic was written.
        _ = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: gen,
                                                characteristic: nil,
                                                sourceEpoch: transport.currentTransportEpoch,
                                                from: transport.requireContextPeripheralForTest())
        XCTAssertTrue(transport.isIdentityQuarantinedForTest(centralId),
                      "the ambiguity is not guessed through - the identity stands quarantined")

        // No timeout releases it: the injected clock runs past every deadline
        // and the quarantine keeps its ground.
        clock.advance(600_000)
        XCTAssertTrue(transport.isIdentityQuarantinedForTest(centralId),
                      "the quarantine is not released by guessing a timeout")

        // A fresh subscription of the quarantined identity is refused.
        let refused = transport.processInboundSubscribe(centralId: centralId, central: handle,
                                                       sourceEpoch: transport.currentTransportEpoch,
                                                       from: transport.requireContextPeripheralForTest())
        XCTAssertEqual(refused, .rejectSubscription(centralId))
        XCTAssertFalse(transport.send(makeFrame([9]), to: centralId) == .admitted,
                       "nothing is sent to a quarantined identity whose removal completed")

        // Rotation of the context is the only release.
        transport.stop()
        transport.start()
        XCTAssertFalse(transport.isIdentityQuarantinedForTest(centralId),
                       "the rotation retires the context that held the quarantine")
        XCTAssertTrue(establishInbound(transport, centralId: centralId, central: handle),
                      "after rotation the identity may subscribe anew")
        XCTAssertEqual(transport.send(makeFrame([8]), to: centralId), .admitted,
                       "after the rotation the trusted path admits again")
        transport.stop()
    }

    // MARK: - a stale unsubscribe cannot remove the replacement
    //
    // The same UUID is subscribed afresh after the rotation resets the
    // quarantine; its generation is remembered and bumped, so the old
    // number survives only in the hands of stale requests - which must
    // not remove the replacement standing under the newer one.

    func testStaleUnsubscribeCannotRemoveTheReplacement() throws {
        let transport = BleTransport(identity: try makeIdentity(), store: nil,
                                     clock: TestClock(startingAt: 1_000))
        transport.start()
        let centralId = UUID()
        let handle = centralPresent(centralId)
        guard establishInbound(transport, centralId: centralId, central: handle) else {
            XCTFail("the inbound preamble did not establish"); return
        }
        let firstGen = inboundGeneration(transport.peripheralDriver, centralId)
        XCTAssertGreaterThan(firstGen, 0)

        // A request bearing a number never issued this epoch must be
        // rejected while the subscription stands - distinguishably.
        let pm = transport.requireContextPeripheralForTest()
        let stranger = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: 7_777,
                                                           characteristic: BleTransport.inboxCharacteristicUuid,
                                                           sourceEpoch: transport.currentTransportEpoch, from: pm)
        XCTAssertEqual(stranger, .rejectStaleUnsubscribe(centralId),
                       "the generation the request carries is compared, never the current one resolved")
        XCTAssertNotNil(transport.getInboundLifetime(centralId), "the subscription stands")

        // The honest request removes it.
        _ = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: firstGen,
                                                characteristic: BleTransport.inboxCharacteristicUuid,
                                                sourceEpoch: transport.currentTransportEpoch, from: pm)
        XCTAssertNil(transport.getInboundLifetime(centralId), "the removal is complete")

        // The rotation re-initialises the drivers: the generation numbers
        // belong to the context's own epoch and restart with it. What
        // disambiguates the requests of a retired context is the epoch
        // token, not the number - so the stack must drop whatever the old
        // managers' callbacks carry, whoever those callbacks name.
        let retiredToken = transport.currentTransportEpoch
        transport.stop()
        transport.start()
        let pm2 = transport.requireContextPeripheralForTest()
        XCTAssertGreaterThan(transport.currentTransportEpoch, retiredToken, "the epoch advanced")
        let w = transport.processInboundWrite(centralId: centralId,
                                             rawData: remoteLinkInfo(hint: Data([0, 0, 0, 1])),
                                             sourceEpoch: transport.currentTransportEpoch, from: pm2)
        XCTAssertTrue(String(describing: w).hasPrefix("accept"), "re-admission after rotation: \(w)")
        let re = transport.processInboundSubscribe(centralId: centralId, central: handle,
                                                   sourceEpoch: transport.currentTransportEpoch, from: pm2)
        XCTAssertTrue(String(describing: re).hasPrefix("accept"), "the replacement is subscribed: \(re)")
        let secondGen = inboundGeneration(transport.peripheralDriver, centralId)
        XCTAssertEqual(secondGen, 1, "the numbers restart with the new context and are judged within its own epoch")

        // A request from the retired context's own manager is dropped by
        // the authenticity gate, whoever it names: the state is preserved.
        transport.clearReductionTraceForTest()
        _ = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: secondGen,
                                                characteristic: BleTransport.inboxCharacteristicUuid,
                                                sourceEpoch: retiredToken, from: pm)
        XCTAssertNotNil(transport.getInboundLifetime(centralId),
                        "the subscription of this epoch stands unharmed by a foreign request")
        switch transport.peripheralDriver?.getInboundSlotState(centralId) {
        case .active(let g)?: XCTAssertEqual(g, secondGen, "and the driver slot keeps its number")
        default: XCTFail("the driver slot should stand active under the new generation")
        }
        if let trace = transport.lastReductionTraceForTest {
            XCTAssertEqual(trace.epoch, transport.currentTransportEpoch,
                           "every reduction runs on its own epoch's executor")
            XCTAssertTrue(trace.ranOnSerialExecutor, "the drop went through the serial admission")
        }

        // The honest request of the standing number removes it.
        let honest = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: secondGen,
                                                         characteristic: BleTransport.inboxCharacteristicUuid,
                                                         sourceEpoch: transport.currentTransportEpoch, from: pm2)
        XCTAssertFalse(String(describing: honest).hasPrefix("rejectStale"),
                       "the matching generation is not stale-rejected: \(honest)")
        XCTAssertNil(transport.getInboundLifetime(centralId), "the removal is complete")
        transport.stop()
    }

    // MARK: - responder notifications use the retained central

    func testResponderNotificationUsesTheRetainedHandleNotTheLatestRenewal() throws {
        let pairing = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pairing) }
        let transport = BleTransport(identity: pairing.bobIdentity, store: nil,
                                     clock: TestClock(startingAt: 1_000))
        transport.sessions = pairing.bobManager
        transport.start()
        let centralId = pairing.viaAlice
        let first = centralPresent(centralId)
        guard establishInbound(transport, centralId: centralId, central: first) else {
            XCTFail("the inbound preamble did not establish"); return
        }

        // A second, different real instance contending the same identity in
        // the same epoch is the reuse the callbacks cannot distinguish.
        let rival = centralPresent(centralId)
        let clash = transport.processInboundSubscribe(centralId: centralId, central: rival,
                                                      sourceEpoch: transport.currentTransportEpoch,
                                                      from: transport.requireContextPeripheralForTest())
        XCTAssertEqual(clash, .rejectSubscription(centralId),
                       "the contending instance is refused")
        XCTAssertTrue(transport.isIdentityQuarantinedForTest(centralId),
                      "and the identity is quarantined for the epoch")

        // While quarantined, notifications are suppressed: the ring stays.
        let ringBefore = transport.responderSendRecordsForTest().count
        XCTAssertFalse(transport.send(makeFrame([7, 7]), to: centralId) == .admitted,
                       "sending to a quarantined identity is suppressed")
        let suppressed = transport.rejectionRecordsForTest().last
        XCTAssertEqual(suppressed?.site, "send.responder")
        XCTAssertEqual(suppressed?.reason, "quarantined identity",
                       "the connection stands, the registry is live, the seal ran - the gate is what stopped it")
        XCTAssertEqual(transport.responderSendRecordsForTest().count, ringBefore,
                       "no record was made - the map could have held the rival, the lease did not")

        // The quarantine binds the epoch: rotation of the context is the
        // only release. After a stop-start the identity may be subscribed
        // anew and notifications flow again through the newly retained handle.
        transport.stop()
        transport.start()
        let second = centralPresent(centralId)
        XCTAssertTrue(establishInbound(transport, centralId: centralId, central: second),
                      "after rotation the identity may be subscribed anew")
        XCTAssertEqual(transport.send(makeFrame([6, 6]), to: centralId), .admitted,
                       "the notification goes out over the trusted path")
        XCTAssertEqual(transport.responderSendRecordsForTest().last?.via, ObjectIdentifier(second),
                       "through the handle retained with the lease, not whatever the map last held")
        transport.stop()
    }

    // MARK: - didFailToConnect is terminal without a disconnect request

    func testFailToConnectIsTerminalWithoutDisconnectRequest() throws {
        let transport = BleTransport(identity: try makeIdentity(), store: nil,
                                     clock: TestClock(startingAt: 1))
        transport.start()
        let cm = transport.requireContextCentralForTest()

        // Leg A: a failed attempt with no handle installed is terminal at
        // once and requests no cancellation.
        let peerA = UUID()
        _ = transport.processOutboundDiscover(
            peerId: peerA, rssi: -60, serviceDataHint: Data([0xFE, 0, 0, 0]), peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        _ = transport.processCentralConnect(
            peerId: peerA, peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        XCTAssertNotNil(transport.connection(for: peerA), "the attempt stands")
        XCTAssertEqual(transport.cancelRequestRecordsForTest(), [], "nothing cancelled so far")

        _ = transport.processCentralFailToConnect(
            peerId: peerA, error: nil, peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        XCTAssertNil(transport.connection(for: peerA), "the failure is terminal immediately")
        XCTAssertEqual(transport.cancelRequestRecordsForTest(), [],
                       "a never-connected peripheral requests no cancellation")
        XCTAssertEqual(transport.timerLeaseCountForTest(), 0, "its lease was swept with it")

        // Leg B (contrast): a fully staged initiator whose service discovery
        // is lost does request a cancellation of the connection attempt.
        let peerB = UUID()
        let handle = peripheralPresent(peerB)
        _ = transport.processOutboundDiscover(
            peerId: peerB, rssi: -60, serviceDataHint: Data([0xFE, 0, 0, 0]), peripheral: handle,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        _ = transport.processCentralConnect(
            peerId: peerB, peripheral: handle,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        guard let delegate = transport.getRelationDelegate(peerB) else {
            XCTFail("the relation delegate was not wired at admission"); return
        }
        let lost = NSError(domain: "CBErrorDomain", code: 4, userInfo: nil)
        for _ in 0..<6 {
            if transport.cancelRequestRecordsForTest().contains(peerB) { break }
            _ = transport.processPeripheralDiscoverServices(handle, delegate: delegate, error: lost)
        }
        XCTAssertEqual(transport.cancelRequestRecordsForTest(), [peerB],
                       "the lost discovery of a staged connection requests one cancellation")
        XCTAssertFalse(transport.cancelRequestRecordsForTest().contains(peerA),
                       "the failed attempt never requested one")
        transport.stop()
    }

    // MARK: - quarantine metadata stays bounded

    func testQuarantineMetadataIsBoundedUnderContention() throws {
        let transport = BleTransport(identity: try makeIdentity(), store: nil,
                                     clock: TestClock(startingAt: 1))
        transport.start()
        let pm = transport.requireContextPeripheralForTest()
        for _ in 0..<2_000 {
            let centralId = UUID()
            let a = centralPresent(centralId)
            let b = centralPresent(centralId)
            _ = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo(hint: Data([0, 0, 0, 9])),
                                             sourceEpoch: transport.currentTransportEpoch, from: pm)
            _ = transport.processInboundSubscribe(centralId: centralId, central: a,
                                                  sourceEpoch: transport.currentTransportEpoch, from: pm)
            _ = transport.processInboundSubscribe(centralId: centralId, central: b,
                                                  sourceEpoch: transport.currentTransportEpoch, from: pm)
            // The honest release: the driver slot frees its admission again,
            // so the loop stays within the capacity while the quarantine
            // accumulates only the clashed identities.
            let gen = inboundGeneration(transport.peripheralDriver, centralId)
            _ = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: gen,
                                                    characteristic: BleTransport.inboxCharacteristicUuid,
                                                    sourceEpoch: transport.currentTransportEpoch, from: pm)
        }
        XCTAssertEqual(transport.quarantineRecordCountForTest(), 1_024,
                       "the quarantine holds its capacity and no more")
        XCTAssertEqual(transport.quarantineOverflowRecordsForTest(), 976,
                       "the refusals past the bound are counted, not stored")
        transport.stop()
    }

    // MARK: - a fully drained context rotates when its budget is spent

    func testRotationFollowsDrainedBudgetExhaustion() throws {
        let factory = OpeningFactory(budgetOverride: 6)
        let transport = BleTransport(identity: try makeIdentity(), store: nil,
                                     provisionalTimeoutSeconds: 10.0,
                                     managerFactory: factory,
                                     clock: TestClock(startingAt: 1))
        transport.start()
        var openingsAfterFirstStart = factory.openings().central
        XCTAssertEqual(openingsAfterFirstStart, 1, "the opening made one pair")

        // Two full cycles: write + subscribe (2 admissions each) + honest
        // unsubscribe. Four admissions do not exhaust the budget of six.
        for _ in 0..<2 {
            let centralId = UUID()
            let handle = centralPresent(centralId)
            let pm = transport.requireContextPeripheralForTest()
            _ = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo(hint: Data([0, 0, 0, 4])),
                                              sourceEpoch: transport.currentTransportEpoch, from: pm)
            _ = transport.processInboundSubscribe(centralId: centralId, central: handle,
                                                  sourceEpoch: transport.currentTransportEpoch, from: pm)
            let gen = inboundGeneration(transport.peripheralDriver, centralId)
            _ = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: gen,
                                                    characteristic: BleTransport.inboxCharacteristicUuid,
                                                    sourceEpoch: transport.currentTransportEpoch, from: pm)
        }
        XCTAssertEqual(factory.openings().central, openingsAfterFirstStart,
                       "while admissions remain below the budget, no rotation")

        // The third cycle spends the budget: two admissions bring six, and
        // the unsubscribe that drains the context executes the rotation.
        let centralId = UUID()
        let handle = centralPresent(centralId)
        let pm = transport.requireContextPeripheralForTest()
        _ = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo(hint: Data([0, 0, 0, 5])),
                                          sourceEpoch: transport.currentTransportEpoch, from: pm)
        _ = transport.processInboundSubscribe(centralId: centralId, central: handle,
                                              sourceEpoch: transport.currentTransportEpoch, from: pm)
        XCTAssertEqual(factory.openings().central, openingsAfterFirstStart,
                       "the busy context is not rotated while it still holds a subscription")
        let gen = inboundGeneration(transport.peripheralDriver, centralId)
        _ = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: gen,
                                                 characteristic: BleTransport.inboxCharacteristicUuid,
                                                 sourceEpoch: transport.currentTransportEpoch, from: pm)
        openingsAfterFirstStart += 1
        XCTAssertEqual(factory.openings().central, openingsAfterFirstStart,
                       "at the drained point the exhausted budget rotates the context")
        XCTAssertEqual(factory.openings().peripheral, openingsAfterFirstStart,
                       "the fresh pair is complete")
        XCTAssertGreaterThan(transport.currentTransportEpoch, 1, "the epoch advanced with the rotation")
        let openings = factory.openings()
        XCTAssertEqual(Set(openings.labels).count, openings.central,
                       "every context ran on its own dedicated queue, shared by its pair")
        transport.stop()
    }
}
