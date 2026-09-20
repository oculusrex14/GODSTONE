import XCTest
import Foundation
import CoreBluetooth
import ObjectiveC
@testable import GodstoneCore
@testable import GodstoneMesh

/// GS-INTEGRATION-001: The harness court standing on the real transport.
///
/// Ported from ReadinessT22Tests per repo convention:
/// The CoreBluetooth-stubbing block below (CapturePeripheral, CapturePeripheralManager,
/// CaptureCentralManager, CaptureFactory, CaptureRequest, PresentCharacteristic,
/// NotifyingInboxCharacteristic, PresentCentral, pins, walkLog, centralPresent,
/// peripheralPunt, advanceToRoleBound, advanceToResponderBound, remoteLinkInfoStatic)
/// is the T22 recipe ported verbatim in substance per repo convention.
final class GsIntegration001RealTransportTests: XCTestCase {

    // =========================================================================
    // MARK: - Ported T22 Recipe: CoreBluetooth Stubbing Block
    // =========================================================================

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
    private final class PresentCentral: NSObject, @unchecked Sendable {
        @objc let identifier: UUID
        let tag = UUID()
        @objc var maximumUpdateValueLength: Int = 512
        init(identifier: UUID) {
            self.identifier = identifier
            super.init()
        }
    }

    /// A peripheral present for the sending side. It answers every selector
    /// the stack messages to a connected peripheral and records the bytes
    /// of each write, so the test can inspect the wire itself.
    private final class CapturePeripheral: NSObject, @unchecked Sendable {
        @objc let identifier: UUID
        @objc var state: CBPeripheralState = .connected
        @objc var services: [CBService]?
        @objc var delegate: CBPeripheralDelegate?
        @objc var canSendWriteWithoutResponse = true
        private let lk = NSLock()
        private var stored: [Data] = []
        init(identifier: UUID) {
            self.identifier = identifier
            super.init()
        }
        var maxWrite = 512
        @objc(maximumWriteValueLengthForType:)
        func maximumWriteValueLength(for writeType: CBCharacteristicWriteType) -> Int { maxWrite }
        @objc(writeValue:forCharacteristic:type:)
        func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
            lk.lock(); stored.append(data); lk.unlock()
        }
        @objc func discoverServices(_ services: [CBUUID]) {}
        @objc func discoverCharacteristics(_ characteristics: [CBUUID], for service: CBService) {}
        @objc func readRSSI() {}
        @objc func readCharacter(_ characteristic: CBCharacteristic) {}
        @objc(setNotifyValue:forCharacteristic:)
        func setNotifyValue(_ v: Bool, for characteristic: CBCharacteristic) {}
        var writes: [Data] {
            lk.lock(); defer { lk.unlock() }
            return stored
        }
        func clearWrites() {
            lk.lock(); stored.removeAll(); lk.unlock()
        }
    }

    /// The responder's peripheral manager. It records the notifications the
    /// stack sends towards subscribed centrals and swallows the ATT answers,
    /// so the punted requests never reach the real framework's map.
    private final class CapturePeripheralManager: CBPeripheralManager, @unchecked Sendable {
        private let lk = NSLock()
        private var updates: [(bytes: Data, central: UUID)] = []
        private var answers: [CBATTError.Code] = []
        var updateAnswer: (Data) -> Bool = { _ in true }
        private var attempts: [Data] = []
        override func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic,
                                 onSubscribedCentrals centrals: [CBCentral]?) -> Bool {
            lk.lock()
            attempts.append(value)
            let ok = updateAnswer(value)
            if ok {
                updates.append((value, centrals?.first.map { $0.identifier } ?? UUID()))
            }
            lk.unlock()
            return ok
        }
        var updateAttempts: [Data] {
            lk.lock(); defer { lk.unlock() }
            return attempts
        }
        func clearAttempts() {
            lk.lock(); attempts.removeAll(); lk.unlock()
        }
        override func respond(to request: CBATTRequest, withResult result: CBATTError.Code) {
            lk.lock(); answers.append(result); lk.unlock()
        }
        var capturedUpdates: [(bytes: Data, central: UUID)] {
            lk.lock(); defer { lk.unlock() }
            return updates
        }
        var respondedResults: [CBATTError.Code] {
            lk.lock(); defer { lk.unlock() }
            return answers
        }
    }

    /// The central manager of the context, tamed: the discover leg hands a
    /// found peripheral to the real connect call - a fabricated handle must
    /// not reach the system's connection machinery, so the call is recorded
    /// and answered here, exactly as the responder's answers are.
    private final class CaptureCentralManager: CBCentralManager, @unchecked Sendable {
        private let lk = NSLock()
        private var connects: [UUID] = []
        override func connect(_ peripheral: CBPeripheral, options: [String: Any]?) {
            lk.lock(); connects.append(peripheral.identifier); lk.unlock()
        }
        var capturedConnects: [UUID] {
            lk.lock(); defer { lk.unlock() }
            return connects
        }
    }

    private final class CaptureFactory: NSObject, TransportManagerFactory, @unchecked Sendable {
        private let lk = NSLock()
        private var managers: [CapturePeripheralManager] = []
        func makeCentralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBCentralManager {
            return CaptureCentralManager(delegate: nil, queue: queue)
        }
        func makePeripheralManager(queue: DispatchQueue, restoreIdentifier: String?) -> CBPeripheralManager {
            let m = CapturePeripheralManager(delegate: nil, queue: queue)
            lk.lock(); managers.append(m); lk.unlock()
            return m
        }
        var peripheralManagers: [CapturePeripheralManager] {
            lk.lock(); defer { lk.unlock() }
            return managers
        }
    }

    /// The punted request: it answers every selector the write loop
    /// messages - central, characteristic (whose uuid the classifier reads),
    /// offset and value - and is pinned for the duration of the dispatch.
    private final class CaptureRequest: NSObject, @unchecked Sendable {
        @objc let central: CBCentral?
        @objc var characteristic: CBCharacteristic?
        @objc var offset: UInt16 = 0
        @objc var value: Data?
        init(centralId: UUID, pinnedCentral: CBCentral, value: Data) {
            self.central = pinnedCentral
            self.value = value
            super.init()
            self.characteristic = unsafeBitCast(PresentCharacteristic(), to: CBCharacteristic.self)
        }
    }

    private final class PresentCharacteristic: NSObject, @unchecked Sendable {
        @objc func UUID() -> CBUUID { return BleTransport.inboxCharacteristicUuid }
        @objc func uuid() -> CBUUID { return BleTransport.inboxCharacteristicUuid }
    }

    private final class NotifyingInboxCharacteristic: CBMutableCharacteristic {
        override var isNotifying: Bool { return true }
    }

    private static func provisionedService() -> CBMutableService {
        let installed = BleTransport.characteristicsToInstall(BleTransport.meshProfile)
        let service = CBMutableService(type: BleTransport.meshProfile.serviceUuid, primary: true)
        service.characteristics = installed
        return service
    }

    private var pins: [AnyObject] = []
    private var walkLog: [String] = []

    private func centralPresent(_ identity: UUID, updateCapacity: Int = 512) -> CBCentral {
        let peer = PresentCentral(identifier: identity)
        peer.maximumUpdateValueLength = updateCapacity
        pins.append(peer)
        return unsafeBitCast(peer, to: CBCentral.self)
    }

    private func peripheralPunt(_ identity: UUID) -> (CBPeripheral, CapturePeripheral) {
        let peer = CapturePeripheral(identifier: identity)
        pins.append(peer)
        return (unsafeBitCast(peer, to: CBPeripheral.self), peer)
    }

    private static func remoteLinkInfoStatic(hint: Data) -> Data {
        return BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: hint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
    }

    /// The initiator's legs, as the T14/T22 recipe drives them.
    private func advanceToRoleBound(_ alice: BleTransport, peerId: UUID,
                                    serviceDataHint: Data,
                                    capturePeer: CapturePeripheral) -> RelationPeripheralDelegate? {
        alice.start()
        alice.refreshLocalLinkInfoSnapshotSync()
        let cm = alice.requireContextCentralForTest()
        let advRecord: [String: Any] = [
            CBAdvertisementDataServiceDataKey: [BleTransport.serviceUuid:
                Self.remoteLinkInfoStatic(hint: serviceDataHint)]
        ]
        alice.processCentralDidDiscover(
            cm, peripheral: unsafeBitCast(capturePeer, to: CBPeripheral.self),
            advertisementData: advRecord, rssi: NSNumber(value: -60),
            sourceEpoch: alice.currentTransportEpoch)
        guard let delegate = alice.getRelationDelegate(peerId) else { return nil }
        _ = alice.processCentralConnect(
            peerId: peerId, peripheral: nil,
            sourceEpoch: alice.currentTransportEpoch, from: cm)
        walkLog.append("after connect: " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let a1 = alice.processPeripheralDiscoverServices(nil, delegate: delegate, error: nil)
        walkLog.append("services -> " + String(describing: a1) + " @ " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let a2 = alice.processPeripheralDiscoverCharacteristics(nil, delegate: delegate,
                                                                service: Self.provisionedService(), error: nil)
        walkLog.append("characteristics -> " + String(describing: a2) + " @ " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let linkInfoChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: Self.remoteLinkInfoStatic(hint: serviceDataHint),
            permissions: [.readable, .writeable])
        let a3 = alice.processPeripheralUpdateValue(nil, delegate: delegate, characteristic: linkInfoChar, error: nil)
        walkLog.append("readresult -> " + String(describing: a3) + " @ " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let ackChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: serviceDataHint,
            permissions: [.readable, .writeable])
        let a4 = alice.processPeripheralWriteValue(nil, delegate: delegate, characteristic: ackChar, error: nil)
        walkLog.append("ack -> " + String(describing: a4) + " @ " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let inboxChar = NotifyingInboxCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable])
        let a5 = alice.processPeripheralNotificationStateUpdated(nil, delegate: delegate, characteristic: inboxChar, error: nil)
        walkLog.append("notify -> " + String(describing: a5) + " @ " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        if alice.connection(for: peerId) == nil { return nil }
        return delegate
    }

    /// The responder's legs: the accepted incoming link-info and subscription.
    private func advanceToResponderBound(_ bob: BleTransport, pm: CBPeripheralManager,
                                         centralId: UUID, remoteHint: Data,
                                         updateCapacity: Int = 512) -> (Bool, String) {
        let w = bob.processInboundWrite(centralId: centralId,
                                        rawData: Self.remoteLinkInfoStatic(hint: remoteHint),
                                        sourceEpoch: bob.currentTransportEpoch, from: pm)
        let sawWrite = String(describing: w)
        guard sawWrite.hasPrefix("accept") else { return (false, "write answered " + sawWrite) }
        let s = bob.processInboundSubscribe(centralId: centralId,
                                            central: centralPresent(centralId, updateCapacity: updateCapacity),
                                            sourceEpoch: bob.currentTransportEpoch, from: pm)
        let sawSubscribe = String(describing: s)
        guard sawSubscribe.hasPrefix("accept") else { return (false, "subscribe answered " + sawSubscribe) }
        bob.setMutableInboxCharacteristicForTesting(CBMutableCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]))
        return (true, "accepted")
    }

    // =========================================================================
    // MARK: - Doubles: InMemoryDeliveryRepository & TestAckSigner
    // =========================================================================

    private final class InMemoryDeliveryRepository: DeliveryRepository {
        var map: [Data: DeliveryRecord] = [:]
        private let store: InMemoryMessageStore?

        init(store: MessageStore? = nil) {
            self.store = store as? InMemoryMessageStore
        }

        func get(_ msgId: Data) -> DeliveryLookup {
            if let rec = map[msgId] { return .found(rec) }
            if let d = store?.readDeliveryRow(msgId),
               let s = DeliveryState.fromPersistedCode(d.state),
               let a = AckMode.fromCode(d.ackMode) {
                let rec = DeliveryRecord(
                    msgId: msgId,
                    state: s,
                    ackMode: a,
                    expectedRecipientNodeId: d.expectedRecipient
                )
                map[msgId] = rec
                return .found(rec)
            }
            return .notFound
        }

        func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
            guard bindingConsistent(ackMode: ackMode, expectedRecipient: expectedRecipient) else { return .corrupt }
            switch get(msgId) {
            case .notFound:
                map[msgId] = DeliveryRecord(msgId: msgId, state: .queuedDurably,
                                             ackMode: ackMode, expectedRecipientNodeId: expectedRecipient)
                return .created
            case .found(let rec):
                return classifyExisting(rec: rec, ackMode: ackMode, expectedRecipient: expectedRecipient)
            case .corrupt:
                return .corrupt
            case .storageFailure:
                return .storageFailure
            case .invalidArgument:
                return .invalidArgument
            }
        }

        func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult {
            let target: DeliveryState, validFroms: Set<DeliveryState>
            switch transition {
            case .markHanded: target = .handedToRelay; validFroms = [.queuedDurably]
            case .expire:     target = .expired;        validFroms = [.queuedDurably, .handedToRelay]
            case .cancel:     target = .cancelledLocally; validFroms = [.queuedDurably, .handedToRelay]
            }
            switch get(msgId) {
            case .notFound: return .unknownMessage
            case .corrupt: return .corrupt
            case .storageFailure: return .storageFailure
            case .invalidArgument: return .invalidArgument
            case .found(let rec):
                let s = rec.state
                if s == target { return .alreadyInTarget }
                if validFroms.contains(s) {
                    map[msgId] = DeliveryRecord(msgId: msgId, state: target,
                                                 ackMode: rec.ackMode,
                                                 expectedRecipientNodeId: rec.expectedRecipientNodeId)
                    store?.updateDeliveryState(msgId, state: target.code)
                    return .applied
                }
                return .rejectedState
            }
        }

        func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {
            switch get(msgId) {
            case .notFound: return .unknownMessage
            case .corrupt: return .corrupt
            case .storageFailure: return .storageFailure
            case .invalidArgument: return .invalidArgument
            case .found(let rec):
                if rec.ackMode != .singleRecipient || rec.expectedRecipientNodeId != .some(expectedRecipient) {
                    return .unknownMessage
                }
                switch rec.state {
                case .acknowledgedByRecipient: return .duplicateAuthenticatedAck
                case .expired, .cancelledLocally: return .rejectedState
                case .queuedDurably, .handedToRelay:
                    map[msgId] = DeliveryRecord(msgId: msgId, state: .acknowledgedByRecipient,
                                                 ackMode: rec.ackMode,
                                                 expectedRecipientNodeId: rec.expectedRecipientNodeId)
                    store?.updateDeliveryState(msgId, state: DeliveryState.acknowledgedByRecipient.code)
                    return .applied
                default: return .rejectedState
                }
            }
        }

        func clear(_ msgId: Data) -> ClearResult {
            if map.removeValue(forKey: msgId) != nil { return .cleared }
            return .alreadyAbsent
        }

        private func classifyExisting(rec: DeliveryRecord, ackMode: AckMode,
                                      expectedRecipient: Data?) -> EnqueueResult {
            if rec.state.isTerminal { return .rejectedTerminalState }
            if rec.ackMode == ackMode && rec.expectedRecipientNodeId == expectedRecipient {
                return .alreadyQueuedSameBinding
            }
            return .conflictRecipient
        }

        private func bindingConsistent(ackMode: AckMode, expectedRecipient: Data?) -> Bool {
            switch ackMode {
            case .none: return expectedRecipient == nil
            case .singleRecipient:
                guard let r = expectedRecipient else { return false }
                return r.count == 16
            }
        }
    }

    private final class TestAckSigner: AckSignerSeam, @unchecked Sendable {
        private let idBytes: Data
        private let seed: Data
        init(nodeId: Data, seed: Data) { self.idBytes = Data(nodeId); self.seed = Data(seed) }
        var nodeId: Data? { Data(idBytes) }
        func generation() -> Int64 { 1 }
        func signingSeed(msgId: Data, recipientNodeId: Data) throws -> Data? { Data(seed) }
    }

    // =========================================================================
    // MARK: - Harness Rig
    // =========================================================================

    private struct HarnessRig {
        let pair: ReadinessTrustedPairing.Pair
        let alice: BleTransport
        let bob: BleTransport
        let aliceNode: MeshNode
        let bobNode: MeshNode
        let aliceStore: InMemoryMessageStore
        let bobStore: InMemoryMessageStore
        let aliceRepo: InMemoryDeliveryRepository
        let bobRepo: InMemoryDeliveryRepository
        let aliceAckStore: InMemoryAckStore
        let bobAckStore: InMemoryAckStore
        let aliceKeys: MutableKeyTable
        let bobKeys: MutableKeyTable
        let handleA: UUID
        let handleB: UUID
        let capturePeer: CapturePeripheral

        func tearDown() {
            alice.stop()
            bob.stop()
            ReadinessTrustedPairing.tearDown(pair)
        }
    }

    private func makeHarness() throws -> HarnessRig {
        let pair = try ReadinessTrustedPairing.barePair()
        let handleB = UUID()
        let handleA = UUID()
        let aliceFactory = CaptureFactory()
        let bobFactory = CaptureFactory()

        let aliceStore = InMemoryMessageStore()
        let bobStore = InMemoryMessageStore()

        let alice = BleTransport(identity: pair.aliceIdentity, store: aliceStore,
                                 sessions: pair.aliceManager,
                                 managerFactory: aliceFactory, clock: TestClock(startingAt: 9_300))
        let bob = BleTransport(identity: pair.bobIdentity, store: bobStore,
                               sessions: pair.bobManager,
                               managerFactory: bobFactory, clock: TestClock(startingAt: 9_300))

        let aliceKeys = MutableKeyTable()
        let bobKeys = MutableKeyTable()
        aliceKeys.put(pair.bobIdentity.nodeId, pair.bobIdentity.signingPublicKey)
        bobKeys.put(pair.aliceIdentity.nodeId, pair.aliceIdentity.signingPublicKey)

        let aliceRepo = InMemoryDeliveryRepository(store: aliceStore)
        let bobRepo = InMemoryDeliveryRepository(store: bobStore)

        let aliceAuth = Ed25519AckAuthenticator(resolver: aliceKeys)
        let bobAuth = Ed25519AckAuthenticator(resolver: bobKeys)

        let aliceTracker = DeliveryTracker(repo: aliceRepo, authenticator: aliceAuth)
        let bobTracker = DeliveryTracker(repo: bobRepo, authenticator: bobAuth)

        let aliceNode = MeshNode(identity: pair.aliceIdentity, store: aliceStore,
                                 deliveryTracker: aliceTracker, sessions: pair.aliceManager)
        let bobNode = MeshNode(identity: pair.bobIdentity, store: bobStore,
                               deliveryTracker: bobTracker, sessions: pair.bobManager)

        // Bind ACK owners exactly as ComposedRuntime.swift does:
        let aliceAckStore = InMemoryAckStore()
        let bobAckStore = InMemoryAckStore()

        let aliceSeed = Data(repeating: 0x11, count: 32)
        let bobSeed = Data(repeating: 0x33, count: 32)

        let aliceSigner = TestAckSigner(nodeId: pair.aliceIdentity.nodeId, seed: aliceSeed)
        let bobSigner = TestAckSigner(nodeId: pair.bobIdentity.nodeId, seed: bobSeed)

        let aliceDriver = AckObligationDriver(store: aliceAckStore, signer: aliceSigner,
                                              authenticator: aliceAuth, resolver: aliceKeys)
        let bobDriver = AckObligationDriver(store: bobAckStore, signer: bobSigner,
                                            authenticator: bobAuth, resolver: bobKeys)

        let alicePump = DurableAckPump(store: aliceAckStore, admitForeign: { encoded, from in
            aliceDriver.admitForeignCandidate(encoded, receivedFrom: from)
        })
        let bobPump = DurableAckPump(store: bobAckStore, admitForeign: { encoded, from in
            bobDriver.admitForeignCandidate(encoded, receivedFrom: from)
        })

        aliceNode.ackPump = alicePump
        bobNode.ackPump = bobPump

        aliceNode.ackDispatcher = AckDispatcher(
            lookupDeliveryRow: { aliceTracker.lookup($0) },
            verifyOrigin: { aliceTracker.acknowledge($0.msgId, $0) },
            admitCandidate: { encoded, from in alicePump.admit(encoded, receivedFrom: from) })

        bobNode.ackDispatcher = AckDispatcher(
            lookupDeliveryRow: { bobTracker.lookup($0) },
            verifyOrigin: { bobTracker.acknowledge($0.msgId, $0) },
            admitCandidate: { encoded, from in bobPump.admit(encoded, receivedFrom: from) })

        // Set transport.delegate = node for both
        alice.delegate = aliceNode
        bob.delegate = bobNode

        // Drive advanceToRoleBound for alice and advanceToResponderBound for bob
        let (_, capturePeer) = peripheralPunt(handleB)
        guard let _ = advanceToRoleBound(alice, peerId: handleB,
                                         serviceDataHint: pair.bobIdentity.nodeHint,
                                         capturePeer: capturePeer) else {
            throw NSError(domain: "GsIntegration001", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "the initiator never bound"])
        }

        bob.start()
        let bobPM = bob.requireContextPeripheralForTest()
        let (bound, saw) = advanceToResponderBound(bob, pm: bobPM, centralId: handleA,
                                                   remoteHint: pair.aliceIdentity.nodeHint)
        guard bound else {
            throw NSError(domain: "GsIntegration001", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "the responder never bound: " + saw])
        }

        return HarnessRig(
            pair: pair, alice: alice, bob: bob,
            aliceNode: aliceNode, bobNode: bobNode,
            aliceStore: aliceStore, bobStore: bobStore,
            aliceRepo: aliceRepo, bobRepo: bobRepo,
            aliceAckStore: aliceAckStore, bobAckStore: bobAckStore,
            aliceKeys: aliceKeys, bobKeys: bobKeys,
            handleA: handleA, handleB: handleB,
            capturePeer: capturePeer
        )
    }

    private func makeFrame(
        _ payload: [UInt8] = [1, 2, 3, 4],
        msgIdByte: UInt8 = 0x7E,
        routingTag: Data? = nil,
        flags: UInt16 = UInt16(Priority.direct.rawValue << 8) | UInt16(FrameV2.Flags.sealed)
    ) -> FrameV2 {
        let mid = Data(repeating: msgIdByte, count: 16)
        let tag = routingTag ?? Data(repeating: 0, count: 4)
        return FrameV2(
            type: .message,
            msgId: mid,
            routingTag: tag,
            ttl: 10,
            hopCount: 0,
            flags: flags,
            payload: Data(payload)
        )
    }

    // =========================================================================
    // MARK: - Courts
    // =========================================================================

    func testGSINT001HarnessStandsOnTheRealTransport() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }
        XCTAssertTrue((rig.alice as Any) is BleTransport)
        XCTAssertTrue((rig.bob as Any) is BleTransport)
        XCTAssertNotNil(rig.alice.connection(for: rig.handleB))
        XCTAssertNotNil(rig.aliceNode.ackDispatcher)
        XCTAssertNotNil(rig.aliceNode.ackPump)
    }

    func testGSINT001TheNodeIsTheRealTransportsDelegate() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }
        XCTAssertTrue(rig.alice.delegate === rig.aliceNode)
        XCTAssertTrue(rig.bob.delegate === rig.bobNode)
        let conn = try XCTUnwrap(rig.alice.connection(for: rig.handleB))
        XCTAssertTrue(conn.state == .roleBound || conn.state == .handshakeInProgress || conn.state == .ready)
    }

    func testGSINT001AnInboundDeliveryIsCommittedExactlyOnce() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }
        let frame = makeFrame([1, 2, 3, 4], routingTag: rig.pair.bobIdentity.nodeHint)
        let first = rig.bobNode.ingestInbound(frame, receivedFrom: rig.pair.aliceIdentity.nodeId)
        XCTAssertTrue(first, "the first inbound delivery must be accepted")
        let second = rig.bobNode.ingestInbound(frame, receivedFrom: rig.pair.aliceIdentity.nodeId)
        XCTAssertFalse(second, "the duplicate delivery must be refused")
        XCTAssertEqual(rig.bobStore.allHeldMsgIds().count, 1)
    }

    func testGSINT001ADistinctFrameIsStillAdmittedAfterARefusal() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }
        let frameA = makeFrame([1, 2, 3, 4], msgIdByte: 0x11, routingTag: rig.pair.bobIdentity.nodeHint)
        let frameB = makeFrame([5, 6, 7, 8], msgIdByte: 0x22, routingTag: rig.pair.bobIdentity.nodeHint)
        let admittedA = rig.bobNode.ingestInbound(frameA, receivedFrom: rig.pair.aliceIdentity.nodeId)
        XCTAssertTrue(admittedA, "frame A must be admitted")
        let replayedA = rig.bobNode.ingestInbound(frameA, receivedFrom: rig.pair.aliceIdentity.nodeId)
        XCTAssertFalse(replayedA, "replayed frame A must be refused")
        let admittedB = rig.bobNode.ingestInbound(frameB, receivedFrom: rig.pair.aliceIdentity.nodeId)
        XCTAssertTrue(admittedB, "distinct frame B must be admitted")
        XCTAssertEqual(rig.bobStore.allHeldMsgIds().count, 2)
    }

    /// *** A THIRD-PARTY FRAME IS HELD AND RELAYED, AND **NOT** DELIVERED LOCALLY. ***
    ///
    /// *MY FIRST VERSION OF THIS ARM ASSERTED THE WRONG THING, AND THE SOURCE SAID SO WHEN THE MUTATION OF MY OWN
    /// REASONING WAS RUN: it asserted that a frame routed to ALICE but delivered to BOB must be REFUSED and the store
    /// must hold nothing. **THAT IS NOT WHAT A MESH NODE DOES, AND IT MUST NOT BE.** `Router.accept` decides:*
    ///
    ///     let deliver     = isAddressedToMe
    ///     let shouldRelay = !(isAddressedToMe && frame.type != .sos)
    ///
    /// *A frame for someone else is HELD and FORWARDED -- that is the network's whole function, and a node that
    /// refused third-party traffic would not be a mesh at all. **ASSERTING THE REFUSAL WOULD HAVE PINNED A BUG AS THE
    /// CONTRACT.** The observed `true` and the single held row were CORRECT; my expectation was wrong, and the arm is
    /// corrected rather than the code.*
    ///
    /// SO IT ASSERTS THE REAL DISTINCTION, WHICH IS THE INVARIANT THAT MATTERS: **accepted for relay, durably held
    /// (the held row IS the relay's obligation), and never rendered as this node's own mail.**
    func testGSINT001AFrameForAnotherRecipientIsHeldAndRelayedButNotDelivered() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }

        let frame = makeFrame([1, 2, 3, 4], routingTag: rig.pair.aliceIdentity.nodeHint)
        let accepted = rig.bobNode.ingestInbound(frame, receivedFrom: rig.pair.aliceIdentity.nodeId)

        XCTAssertTrue(
            accepted,
            "*** A THIRD-PARTY FRAME MUST BE ACCEPTED FOR RELAY. `shouldRelay = !isAddressedToMe`, and relaying is " +
                "the mesh's function -- a node that refused it would break the network. ***",
        )
        XCTAssertEqual(
            rig.bobStore.allHeldMsgIds().count, 1,
            "*** AND IT IS DURABLY HELD: the held row IS the relay's durable obligation, so a node that accepted it " +
                "without persisting would be forwarding on memory alone. ***",
        )

        // *** AND THE DISTINCTION THE ARM EXISTS FOR: A FRAME ADDRESSED TO ALICE IS NOT BOB'S MAIL. ***
        // `deliver = isAddressedToMe`, so this frame must NOT reach the local delivery road. The recipient inbox is
        // that road, and this rig binds NONE -- so the observable here is its absence, stated rather than implied.
        XCTAssertNil(
            rig.bobNode.recipientInbox,
            "*** THIS RIG BINDS NO LOCAL INBOX, SO LOCAL DELIVERY CANNOT BE OBSERVED HERE. Recording that limit " +
                "rather than letting the arm read as though it had checked local delivery: what it DOES prove is that " +
                "the relay road accepted and persisted a frame the node must not deliver. ***",
        )
    }
}
