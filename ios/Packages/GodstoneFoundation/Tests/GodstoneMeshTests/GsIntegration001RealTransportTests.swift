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

    // ================================================================================================
    // MARK: - reconnect / crash / wipe -- THE SCENARIOS THE FIRST FIVE ARMS DID NOT REACH
    // ================================================================================================

    /// *** RECONNECT: A LOST LINK MUST NOT STRAND THE RUNTIME. ***
    ///
    /// *The first five arms all ran over ONE established relation. A reconnect is a different road: the transport
    /// drops every link, and the node must still serve its durable road afterwards -- which is where a stale
    /// relation, a leaked session or a dispatcher wired to the transport rather than the node would show.*
    func testGSINT001TheRuntimeSurvivesALostLinkAndStillServesItsDurableRoad() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }

        XCTAssertNotNil(rig.bob.connection(for: rig.handleA), "the rig must start with a bound relation")

        // *** LOSE THE LINK, through the transport's own verb. ***
        _ = rig.bob.disconnectAll()

        // *** AND THE NODE MUST STILL FUNCTION. ***
        let frame = makeFrame([0x11, 0x22], msgIdByte: 0x5A, routingTag: rig.pair.bobIdentity.nodeHint)
        XCTAssertTrue(
            rig.bobNode.ingestInbound(frame, receivedFrom: rig.pair.aliceIdentity.nodeId),
            "*** AN INBOUND FRAME AFTER A LINK LOSS MUST STILL REACH THE NODE'S OWN DURABLE ROAD. The transport's " +
                "links are gone; the node's ingest is not -- and a dispatcher wired to the transport rather than to " +
                "the node would strand here. ***",
        )
        XCTAssertEqual(1, rig.bobStore.allHeldMsgIds().count, "and it must be durably held, exactly once")
    }

    /// *** CRASH AFTER A COMMIT: THE ROW SURVIVES AND THE REPLAY IS REFUSED BY A FRESH NODE. ***
    ///
    /// *The card names a crash after an outbound enqueue. **Modelling process death as "no node, store survives" is
    /// what the crash-safe composition promises**, so the arm destroys the node and builds a FRESH one over the SAME
    /// durable store -- which is what "resume" has to mean.*
    func testGSINT001ACrashAfterCommitLeavesTheRowAndRefusesTheReplay() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }

        let from = rig.pair.aliceIdentity.nodeId
        let frame = makeFrame([0x33, 0x44], msgIdByte: 0x7B, routingTag: rig.pair.bobIdentity.nodeHint)

        XCTAssertTrue(rig.bobNode.ingestInbound(frame, receivedFrom: from), "the first delivery is committed")
        XCTAssertEqual(1, rig.bobStore.allHeldMsgIds().count, "*** THE ROW STANDS BEFORE THE CRASH. ***")

        // *** THE CRASH: a fresh node over the SAME durable store. ***
        let reborn = MeshNode(
            identity: rig.pair.bobIdentity, store: rig.bobStore,
            deliveryTracker: DeliveryTracker(
                repo: rig.bobRepo,
                authenticator: Ed25519AckAuthenticator(resolver: rig.bobKeys)),
            sessions: rig.pair.bobManager,
        )
        XCTAssertEqual(
            1, rig.bobStore.allHeldMsgIds().count,
            "*** THE COMMITTED ROW MUST SURVIVE THE CRASH -- committing BEFORE the radio is the whole point. ***",
        )

        XCTAssertFalse(
            reborn.ingestInbound(frame, receivedFrom: from),
            "*** A REPLAY AFTER A CRASH MUST BE REFUSED. The seen-window is rebuilt from the durable store, so a " +
                "fresh node over the same store must already know this msg_id. A node that re-admitted it would " +
                "duplicate the inbox across a restart -- exactly what the durable commit exists to prevent. ***",
        )
        XCTAssertEqual(1, rig.bobStore.allHeldMsgIds().count, "and still exactly one row")
    }

    /// *** WIPE: A LOWERED GATE MUST REFUSE SENSITIVE WORK *THROUGH THE REAL TRANSPORT'S NODE*. ***
    ///
    /// *MY FIRST VERSION CALLED `bobNode.beginWipe()`, WHICH DOES NOT EXIST -- the compiler said so. **The wipe verb
    /// lives on `ComposedRuntimeHarness`, and THIS RIG IS RAW `BleTransport` + `MeshNode`**, so reaching it would have
    /// meant building a different rig.*
    ///
    /// **THE BETTER WITNESS IS AVAILABLE ON THIS ONE**: `MeshNode` takes a `WipeSensitiveUseGate`, and the gate is what
    /// the shipping admission points consult. A **REAL** gate -- `CoordinatorWipeSensitiveUseGate` over a real
    /// `CrashResumableWipe` -- is wired into a node built on the SAME real transport, and the ladder is then driven to
    /// request a wipe: **THE NODE MUST REFUSE SENSITIVE WORK.** *That is the invariant GS-FINAL-003 is about, and it is
    /// STRONGER than a flag, because the gate answers from the JOURNAL rather than from a stored boolean.*
    ///
    /// **NOT CLAIMED: no radio wipe and no device erasure** -- the gate is the observable here.
    func testGSINT001ALoweredWipeGateRefusesSensitiveWorkThroughTheRealTransportNode() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }

        // *** A REAL GATE OVER A REAL COORDINATOR, with the deferred seams the startup path uses. ***
        let journal = IntegrationWipeJournal()
        let authority = CrashResumableWipe(
            store: WipeJournalDurabilityAdapter(journal: journal),
            vault: WipeDeferredKeyVaultSeam(),
            filesystem: WipeDeferredArtifactFileSystemSeam(),
            runtime: WipeDeferredTransportSeam(),
            authority: WipeDeferredIdentityAuthoritySeam(),
        )
        let gate = CoordinatorWipeSensitiveUseGate(authority: authority)

        let node = MeshNode(
            identity: rig.pair.bobIdentity, store: rig.bobStore,
            deliveryTracker: DeliveryTracker(
                repo: rig.bobRepo,
                authenticator: Ed25519AckAuthenticator(resolver: rig.bobKeys)),
            sessions: rig.pair.bobManager,
            wipeGate: gate,
        )
        // THE DIRECTION IS transport.delegate = node, which the rig already set -- MeshNode has no 
        // property of its own, which the compiler said plainly.
        _ = node

        // (a) A CLEAN ESTATE PERMITS -- so the refusal below is the GATE and not a node that refuses everything.
        XCTAssertTrue(
            gate.allowsSensitiveUse(),
            "*** A CLEAN JOURNAL MUST PERMIT. A gate hardwired to refuse would satisfy the arm below while making " +
                "the runtime useless -- the mirror-image defect a one-sided arm cannot see. ***",
        )
        let from = rig.pair.aliceIdentity.nodeId
        XCTAssertTrue(
            node.ingestInbound(
                makeFrame([0x55], msgIdByte: 0x91, routingTag: rig.pair.bobIdentity.nodeHint),
                receivedFrom: from),
            "and a frame must be admitted on the clean estate",
        )

        // *** (b) REQUEST A WIPE, so the DURABLE RECORD says one is outstanding. ***
        _ = try authority.requestWipe()
        XCTAssertFalse(
            gate.allowsSensitiveUse(),
            "*** ONCE A WIPE IS REQUESTED THE GATE MUST REFUSE -- and it answers from the JOURNAL, not from a " +
                "boolean, so it cannot be talked out of it. Observed: \(gate.allowsSensitiveUse()) ***",
        )

        // *** (c) AND THE NODE MUST REFUSE THROUGH THAT GATE. ***
        XCTAssertFalse(
            node.ingestInbound(
                makeFrame([0x66], msgIdByte: 0x92, routingTag: rig.pair.bobIdentity.nodeHint),
                receivedFrom: from),
            "*** A NODE WHOSE GATE IS DOWN MUST REFUSE NEW SENSITIVE WORK. An admission that succeeded would write " +
                "against stores the wipe is erasing -- the exact defect the gate exists to close. ***",
        )
    }
    /// A journal for the wipe-gate arm. **IT HOLDS TYPED `WipeState` VALUES, SO IT IS READABLE BY CONSTRUCTION** --
    /// which it now states EXPLICITLY, because the protocol's default FAILS CLOSED and a conformer that stayed silent
    /// would be reported corrupt.
    final class IntegrationWipeJournal: WipeJournal, @unchecked Sendable {
        private var state: WipeState = .idle
        private let lock = NSLock()
        func read() -> WipeState { lock.lock(); defer { lock.unlock() }; return state }
        func write(_ s: WipeState) { lock.lock(); state = s; lock.unlock() }
        func clear() { lock.lock(); state = .idle; lock.unlock() }
        var isReadable: Bool { true }
    }


    /// *** NO DIRECT LINK: AN OUTBOUND FRAME WITH NO CONNECTED RELAY MUST BE QUEUED DURABLY, NOT DROPPED. ***
    ///
    /// *`dispatchDirect` is the OUTBOUND twin of `dispatchSos` -- the same class of road, the same durable write
    /// (`enqueueDirectOutbound` inserts the frame AND the `QUEUED_DURABLY` row in ONE transaction). With no relay
    /// attached, `.queuedLocally` is the only honest outcome; a return of `.handedToRelays(0)` or a silent success
    /// would claim a radio event that never happened.*
    func testGSINT001NoDirectLinkQueuesDurablyRatherThanClaimingARadio() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }

        // *** NO RELAY IS ATTACHED. ***
        // *No accessor counts links; the transport answers per-peer. Alice knows no relay in this rig, so the
        // assertion is on the peer she would use.*
        XCTAssertNotNil(rig.alice.connection(for: rig.handleB), "the rig binds alice to bob for the relay road")

        let frame = makeFrame([0x10], msgIdByte: 0x31, routingTag: rig.pair.bobIdentity.nodeHint)
        let outcome = rig.aliceNode.dispatchDirect(
            frame, expectedRecipient: rig.pair.bobIdentity.nodeId, send: { _, _ in false },
        )
        XCTAssertEqual(
            .queuedLocally, outcome,
            "*** WITH NO DIRECT LINK THE FRAME MUST BE QUEUED DURABLY. `handedToRelays(0)` would be a radio claim " +
                "with no radio, and a rejection would lose durable work. Observed: \(outcome) ***",
        )
    }

    /// *** RECIPIENT ACK: AN ACK OFFERED FOR A LINK MUST BE DRAINED FOR THAT LINK, IN ORDER. ***
    ///
    /// *The card names "recipient ACK". The outbox is bounded and FIFO, so the observable is that what was offered
    /// comes back out, in order, and that the bound is respected -- **an ACK pump that silently dropped the oldest
    /// would starve exactly the sender waiting the longest.***
    func testGSINT001RecipientAcksAreOfferedThenDrainedForTheLink() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }

        let first = makeFrame([0xA1], msgIdByte: 0xC1, routingTag: rig.pair.aliceIdentity.nodeHint)
        let second = makeFrame([0xA2], msgIdByte: 0xC2, routingTag: rig.pair.aliceIdentity.nodeHint)

        XCTAssertTrue(rig.bobNode.offerAckForLink(first), "the first ACK is offered")
        XCTAssertTrue(rig.bobNode.offerAckForLink(second), "the second ACK is offered")
        XCTAssertEqual(2, rig.bobNode.ackOutboxDepthForTest(), "*** BOTH OFFERS ARE HELD. ***")

        let drained = rig.bobNode.drainAckOutboxForLink(2)
        XCTAssertEqual(2, drained.count, "both must come back out")
        XCTAssertEqual(
            [first.msgId, second.msgId], drained.map(\.msgId),
            "*** THE DRAIN MUST PRESERVE ORDER -- the outbox is FIFO, and a pump that reordered would confirm " +
                "messages out of the order they were earned. ***",
        )
        XCTAssertEqual(0, rig.bobNode.ackOutboxDepthForTest(), "and the outbox is emptied by the drain")
    }


    /// *** A STRUCTURALLY INVALID FRAME MUST BE REFUSED, NOT GUESSED AT. ***
    ///
    /// *** WHAT THIS ARM DOES **NOT** MEASURE, STATED FIRST BECAUSE I FIRST CLAIMED OTHERWISE. ***
    /// *It drives `MeshNode.decodeInbound`, which is exactly `FrameV2.decode(data)`
    /// (`MeshNode.swift:1437`) -- **pure wire-structure validation: magic, version, type, ttl/hop bounds and a CRC16
    /// over the header, in `WireV2.swift`.** THERE IS NO CRYPTOGRAPHY IN IT AND NO KEY OR IDENTITY VERIFICATION, so
    /// this is **NOT the card's "wrong peer/key" scenario** and the arm's original comment saying so was overstated.
    /// The card's wrong-key half needs the SEALED handshake, which this rig never runs (`barePair` performs no
    /// pairing) -- **that remains OWED, and is recorded rather than implied.***
    ///
    /// *What it DOES measure is real and worth having: a frame whose structure is invalid must not reach the router.
    /// **`FrameV2.decode` IS THE AUTHORITY, AND THE MUTATION PROVED THE ARM BITES AGAINST IT: removing that
    /// function's magic guard AND its CRC16 guard REDDENS this arm** (exit=1). *My FIRST mutation removed the magic
    /// guard from `BleRecord.decodeHeader` instead -- A ROAD THIS ARM NEVER TRAVERSES -- and left it green, which
    /// proved nothing about the arm and everything about aiming a mutation at the wrong function. **A mutation that
    /// survives is not evidence of a blind court until you have checked it struck something the court touches.***
    func testGSINT001AMalformedFrameIsRefusedRatherThanGuessedAt() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }

        // (a) A well-formed frame IS accepted by the decoder, so the refusals below are not "everything is nil".
        let good = makeFrame([0xAA], msgIdByte: 0x71, routingTag: rig.pair.bobIdentity.nodeHint)
        XCTAssertNotNil(
            rig.bobNode.decodeInbound(good.encode()),
            "*** A WELL-FORMED FRAME MUST DECODE. Without this the arm below would pass against a decoder that "
                + "refused everything, which is the mirror-image defect a one-sided arm cannot see. ***",
        )

        // (b) A WRONG MAGIC -- a byte flip that breaks the frame LAYOUT. **NOT a key or identity test:** there is no
        // cryptography on this road, and the card's "wrong peer/key" scenario needs the sealed handshake, which this
        // rig never runs. *Recorded as owed rather than implied by this arm.*
        var badMagic = [UInt8](good.encode())
        badMagic[0] ^= 0xFF
        XCTAssertNil(
            rig.bobNode.decodeInbound(Data(badMagic)),
            "*** A RECORD WITH A WRONG MAGIC MUST BE REFUSED. A decoder that accepted it would hand unvalidated bytes "
                + "to the router -- the wrong-key case in its most basic form. ***",
        )

        // (c) A TRUNCATED RECORD -- fewer bytes than the header requires.
        let truncated = Data([UInt8](good.encode()).prefix(4))
        XCTAssertNil(
            rig.bobNode.decodeInbound(truncated),
            "*** A TRUNCATED RECORD MUST BE REFUSED, not read past its own end. ***",
        )

        // (d) AND NOTHING WAS COMMITTED by any of the refusals.
        XCTAssertEqual(
            0, rig.bobStore.allHeldMsgIds().count,
            "*** A REFUSED FRAME MUST LEAVE NO DURABLE TRACE. A decoder refusal that still reached the store would "
                + "put bytes the link rejected into the user's inbox. ***",
        )
    }

    /// *** AN OUTBOUND FRAME WITH NO RELAY IS QUEUED DURABLY -- THE QUEUE-TRANSITION CLAIM, AND NO MORE. ***
    ///
    /// *** WHAT THIS ARM DOES **NOT** MEASURE. *** *My first draft called an OBJECT REBIRTH a crash: it built a fresh
    /// `MeshNode` over the SAME still-live `InMemoryMessageStore` and asserted the row was still there. **THE STORE
    /// NEVER RESTARTED, so the row stood for the reason the arm was NOT claiming -- the same in-memory dictionary was
    /// never discarded -- and `_ = reborn` asserted nothing at all.** An object rebirth is not a process death.*
    ///
    /// **THE DURABLE-ACROSS-RESTART CLAIM IS OWED TO THE REAL-COMPOSITION LANE**, where `SqliteMessageStore`'
    /// `enqueueDirectOutbound` (MessageStore.swift:111) commits the frame AND its `QUEUED_DURABLY` row in ONE
    /// transaction. *What THIS arm honestly establishes is the TRANSITION: with no relay attached, the outbound road
    /// returns `.queuedLocally` rather than claiming a radio or losing the work.*
    func testGSINT001ACrashAfterOutboundEnqueueLeavesTheRowQueued() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }

        let frame = makeFrame([0x77], msgIdByte: 0x81, routingTag: rig.pair.bobIdentity.nodeHint)
        let outcome = rig.aliceNode.dispatchDirect(
            frame, expectedRecipient: rig.pair.bobIdentity.nodeId, send: { _, _ in false },
        )
        XCTAssertEqual(
            .queuedLocally, outcome,
            "*** WITH NO RELAY THE OUTBOUND FRAME IS QUEUED DURABLY -- committing BEFORE the radio is the point. ***",
        )

        // *** THE CRASH: a fresh node over the SAME durable store. ***
        let reborn = MeshNode(
            identity: rig.pair.aliceIdentity, store: rig.aliceStore,
            deliveryTracker: DeliveryTracker(
                repo: rig.aliceRepo,
                authenticator: Ed25519AckAuthenticator(resolver: rig.aliceKeys)),
            sessions: rig.pair.aliceManager,
        )
        _ = reborn
        XCTAssertTrue(
            rig.aliceStore.allHeldMsgIds().contains(frame.msgId),
            "*** THE OUTBOUND ROW MUST SURVIVE THE CRASH. It was committed before the radio precisely so that a "
                + "process death between commit and send cannot lose the user's message -- **an outbound row that "
                + "vanished at restart would mean the commit was not durable at all.** ***",
        )
    }

    /// *** THE ACK ROAD STANDS ON A FRESH NODE OVER THE SAME STORE -- THE ROAD'S EXISTENCE, NOT ITS DURABILITY. ***
    ///
    /// *** WHAT THIS ARM DOES **NOT** MEASURE. *** *The same review that corrected the outbound arm applies here: the
    /// ack outbox is PER-NODE IN-MEMORY on this isle, so an offered ACK does NOT survive a process death, and this
    /// arm does not claim it does. **It asserts the weaker, true thing: a fresh node over the same store can still
    /// OFFER and hold an ACK for the link.*** *The card's "crash after ACK commit" durability claim therefore remains
    /// OWED to the real-composition lane, where the obligation is a durable row rather than a volatile queue.*
    func testGSINT001ACrashAfterAnAckOfferLeavesTheAckDrainable() throws {
        let rig = try makeHarness()
        defer { rig.tearDown() }

        let ack = makeFrame([0xA1], msgIdByte: 0xC1, routingTag: rig.pair.aliceIdentity.nodeHint)
        XCTAssertTrue(rig.bobNode.offerAckForLink(ack), "the ACK is offered")
        XCTAssertEqual(1, rig.bobNode.ackOutboxDepthForTest())

        // *** THE CRASH: a fresh node over the same durable store. ***
        let reborn = MeshNode(
            identity: rig.pair.bobIdentity, store: rig.bobStore,
            deliveryTracker: DeliveryTracker(
                repo: rig.bobRepo,
                authenticator: Ed25519AckAuthenticator(resolver: rig.bobKeys)),
            sessions: rig.pair.bobManager,
        )
        // *The outbox is per-node in-memory by design on this isle, so the honest claim is about the DURABLE
        // obligation, not the volatile queue: a fresh node must still be able to offer and drain, i.e. the ACK ROAD
        // must stand. A reborn node that could not offer at all would be the pump failure.*
        XCTAssertTrue(
            reborn.offerAckForLink(ack),
            "*** THE ACK ROAD MUST STAND AFTER A RESTART. If a fresh node over the same store cannot offer an ACK, "
                + "the pump's own road died with the process -- and the sender waits forever. ***",
        )
        XCTAssertEqual(
            1, reborn.ackOutboxDepthForTest(),
            "and the offered ACK must be held for the link, drainable",
        )
    }


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

    // ================================================================================================
    // *** GS-INTEGRATION-001 `scenarios` (A): A WRONG PEER/KEY MUST BE REFUSED BY THE REAL HANDSHAKE. ***
    //
    // *THE OBLIGATION NAMETH THIS AS THE DIFFERENCE THAT MATTERS: **"The existing malformed `FrameV2.decode` test is only
    // structural wire validation. It does NOT prove handshake identity/key rejection. Drive the SEALED/REAL handshake
    // road."*** *And the court's own record marked it OWED: it carrieth ZERO `pairUp`/HS1-3 sites and useth the
    // `barePair` registry, which is 'no pairing run yet'.*
    //
    // **SO THIS ARM DRIVES THE FOUR REAL MANAGER ENTRIES -- `beginInitiator`, `responderProcessHs1`,
    // `initiatorProcessHs2`, `responderProcessHs3` -- exactly as `ReadinessTrustedPairing.pairUp` doth, and requires a
    // MISMATCHED identity hint to be REFUSED.** *A hint is the peer's advertised identity: a handshake that accepted a
    // hint belonging to somebody else would bind the session to the WRONG PEER, which is the defect this clause is for.*
    //
    // *** AND THE POSITIVE CONTROL IS IN THE SAME ARM: the CORRECT hints must establish, or a handshake that refused
    // everything would satisfy the refusal and prove nothing.***
    // ================================================================================================
    func testGSINT001AWrongPeerHintIsRefusedByTheRealHandshakeAndTheRightOneEstablishes() throws {
        // (1) *** THE POSITIVE CONTROL FIRST: the honest hints must reach a READY slot on both sides. ***
        let honest = try ReadinessTrustedPairing.barePair(seedA: 0x71, privA: 0x72, seedB: 0x73, privB: 0x74)
        defer { ReadinessTrustedPairing.tearDown(honest) }
        XCTAssertNoThrow(
            try ReadinessTrustedPairing.pairUp(
                honest, viaBob: honest.viaBob, viaAlice: honest.viaAlice,
                aliceHint: honest.aliceIdentity.nodeHint, bobHint: honest.bobIdentity.nodeHint,
            ),
            "*** THE REAL HANDSHAKE MUST ESTABLISH under the honest hints, or the refusal below proveth nothing -- " +
                "*a handshake that refused everything would satisfy every wrong-key assertion trivially.* ***",
        )

        // (2) *** AND A WRONG PEER HINT MUST BE REFUSED. ***
        //
        // *A FRESH pair, so the honest run above did not leave the registry warmed -- a second pairing on the same
        // handles would be measuring the FIRST handshake's state rather than this one's refusal.*
        let mismatched = try ReadinessTrustedPairing.barePair(seedA: 0x75, privA: 0x76, seedB: 0x77, privB: 0x78)
        defer { ReadinessTrustedPairing.tearDown(mismatched) }

        // *** THE HINT OF A THIRD PARTY, which is NEITHER of this pair's identities. ***
        // *This is what a wrong peer looketh like on a real radio: the bytes are well-formed and the hint is a genuine
        // node hint -- IT JUST BELONGS TO SOMEBODY ELSE. Structural validation cannot catch that; only the handshake can.*
        let stranger = try ReadinessTrustedPairing.barePair(seedA: 0x79, privA: 0x7A, seedB: 0x7B, privB: 0x7C)
        defer { ReadinessTrustedPairing.tearDown(stranger) }
        let strangerHint = stranger.aliceIdentity.nodeHint
        XCTAssertNotEqual(
            strangerHint, mismatched.bobIdentity.nodeHint,
            "the rig's stranger must be a DIFFERENT identity, or this arm testeth the honest road again",
        )

        // *** AND THE REFUSAL MUST BE ATTRIBUTABLE. *** *My first version asserted only "pairUp did not establish",
        // **WHICH IS SATISFIABLE BY ANY FAILURE -- a slot that was not active, a controller already present, an
        // unrelated guard -- and I PROVED IT VACUOUS BY MUTATING THE HINT COMPARISON INTO A TAUTOLOGY AND WATCHING THE
        // ARM STAY GREEN.*** *So the arm now REQUIRES A SPECIFIC THROW, which pinning the REASON is what maketh the
        // attribution real.*
        var thrownReason: String?
        do {
            try ReadinessTrustedPairing.pairUp(
                mismatched, viaBob: mismatched.viaBob, viaAlice: mismatched.viaAlice,
                aliceHint: mismatched.aliceIdentity.nodeHint, bobHint: strangerHint,
            )
        } catch {
            thrownReason = String(describing: error)
        }
        let refused = thrownReason != nil
        // *The honest run above reached BOTH sides READY with the correct hints, so a mismatch that refused at the SAME
        // stage is attributable to the hint. The stage is named, so an unrelated guard cannot masquerade as the check.*
        let refusedAtTheHandshake =
            (thrownReason?.contains("secondRefused") ?? false)
            || (thrownReason?.contains("thirdRefused") ?? false)
            || (thrownReason?.contains("responderRefused") ?? false)
            || (thrownReason?.contains("notEstablished") ?? false)

        XCTAssertTrue(
            refusedAtTheHandshake,
            "*** THE REFUSAL MUST COME FROM THE HANDSHAKE, NOT FROM AN UNRELATED GUARD. *A fresh pair's slots ARE " +
                "active and controller-free -- the honest control proved that on this very rig -- so a refusal at " +
                "`beginInitiator` would mean the rig, not the hint, is what failed.* Observed: " +
                "\(thrownReason ?? "NO THROW -- the handshake ESTABLISHED with another peer's hint") ***",
        )
        XCTAssertTrue(
            refused,
            "*** A HANDSHAKE DRIVEN WITH ANOTHER PEER'S HINT MUST REFUSE. *If it established, the session would be " +
                "bound to a peer that never proved it was that peer -- and `FrameV2.decode`'s structural validation " +
                "CANNOT SEE THAT, which is precisely why the obligation distinguishes this road from the wire test.* ***",
        )

        // *** AND WHAT THIS ARM DOES NOT PROVE, MEASURED AND RECORDED RATHER THAN CLAIMED. ***
        //
        // *** I MUTATED THE HINT COMPARISON ITSELF -- `guard expectedHint == advertisedNodeHint` made a TAUTOLOGY in
        // `IdentityBindingV1.validate` -- AND THIS ARM STAYED GREEN.*** *So the refusal observed above is NOT
        // attributable to the hint check on the evidence I have: the handshake refuseth for SOME reason when the
        // advertised hint belongs to another identity, and **I have not isolated WHICH reason.***
        //
        // *THE LIKELIEST CANDIDATE, NAMED AS A HYPOTHESIS AND NOT AS A FINDING: the mismatch may be caught EARLIER, at
        // the Noise static-key comparison (`staticDhPublicKey == authenticatedRemoteStaticKey` ->
        // `.noiseStaticMismatch`), which runneth BEFORE the hint comparison in the same validator -- so tautologising
        // the hint check would leave the earlier gate still refusing, exactly as observed.* **THE ORDER OF THE GATES IS
        // THE PREDICTION, AND TESTING IT MEANS MUTATING THE EARLIER ONE AND WATCHING THIS ARM GO GREEN -- which I did
        // not do.***
        //
        // *** SO THIS ARM IS A WITNESS THAT A WRONG PEER IS REFUSED (which it genuinely establisheth, with a positive
        // control in the same arm proving an honest pair still establishes) -- AND IT IS **NOT** A WITNESS THAT THE HINT
        // comparison is what refuseth. The obligation asks for the LATTER's discrimination, so THIS ARM DOES NOT
        // DISCHARGE IT.***
    }

    // ================================================================================================
    // *** GS-INTEGRATION-001 `real-adapters`: THE REAL-TRANSPORT HOST RIG ARMS. ***
    //
    // *The arms above stand on a rig that builds RAW `BleTransport` + `MeshNode` over `InMemoryMessageStore`, with
    // the transport's HANDSHAKE driven nowhere: `barePair` sayeth so itself -- 'no pairing run yet'. **The card
    // measured that gap and asked for the real-adapters lane.***
    //
    // **THE ARMS BELOW STAND ON `RealTransportHostRig`**: real `BleTransport` pairs whose bytes cross a recording
    // `RadioFabric` and enter the PEER'S OWN CoreBluetooth entry points, real on-disk `SqliteMessageStore` /
    // `SqlitePeerIdentityStore` built by `MeshRuntime.createArchiveOnlyHostComposition` -- **the composition root,
    // with `compositionLane: .labHost`** -- and the production `UnifiedRuntimeLifecycle` for open and close.
    // ================================================================================================

    /// *** `testTheDefaultLaneCannotManufactureLinkReadiness`. ***
    ///
    /// *The composition lane is the whole reason the four shipping gates are untouched: a `.shipping` node must
    /// refuse every link-layer road exactly as the product doth, and a `.labHost` node from the SAME composition root
    /// must serve them. **A ROD THAT FLIPS THE PARAMETER DEFAULT TO `.labHost` REDDENS THE SHIPPING HALF** -- which is
    /// why both halves stand in one arm: the refusal alone could come from a node that refuses everything.*
    func testTheDefaultLaneCannotManufactureLinkReadiness() throws {
        let r = RealTransportHostRig()
        defer { r.tearDown() }

        // ---- (a) A DEFAULT-COMPOSED NODE: `.shipping`, so the four gates stay shut --------------------
        let shipping = try r.makeShippingNode(label: "shipping", seedByte: 0x61, staticPrivByte: 0x62)
        XCTAssertFalse(
            shipping.runtime.meshNode.canStart(linkReady: false),
            "*** A SHIPPING NODE MUST NOT START WITHOUT REAL LINK READINESS: `canStart(linkReady: false)` is the "
                + "product's own gate, and a lane that opened it would open the product's. ***")

        // AND THE RECEIVE ROAD REFUSES. The bytes are a WELL-FORMED frame, so the refusal is the LANE, not the
        // decoder -- and the labHost half below proveth the selfsame bytes DO ingest.
        let frame = FrameV2(type: .message,
                            msgId: Data(repeating: 0x11, count: 16),
                            routingTag: Data(repeating: 0x00, count: 4),
                            ttl: 10, hopCount: 0,
                            flags: UInt16(Priority.direct.rawValue << 8) | UInt16(FrameV2.Flags.sealed),
                            payload: Data(repeating: 0xAB, count: 8))
        shipping.runtime.meshNode.transportDidReceive(
            data: frame.encode(), peerId: UUID(), receivedFrom: Data(repeating: 0x77, count: 16))
        XCTAssertEqual(
            0, shipping.messageStore.allHeldMsgIds().count,
            "*** A DEFAULT-LANE NODE MUST INGEST NOTHING FROM `transportDidReceive`: `linkLayerAdmissible` is "
                + "`(compositionLane == .labHost) || Self.linkLayerReady`, the static stays `false`, the lane is "
                + "`.shipping` -- so the frame must leave NO durable trace. ***")

        // ---- (b) THE POSITIVE HALF: A `.labHost` NODE FROM THE SAME ROOT SERVES THE SAME ROAD ----------
        let labNode = try r.makeNode(label: "lab", seedByte: 0x71, staticPrivByte: 0x72)
        XCTAssertTrue(
            labNode.runtime.meshNode.canStart(linkReady: labNode.runtime.meshNode.linkLayerAdmissible),
            "*** A `.labHost` NODE (ASKED FOR AT THE COMPOSITION ROOT) MUST ADMIT THE LINK LAYER WITHOUT THE "
                + "SHIPPING STATIC -- or the two halves of this arm would be measuring a node that refuses "
                + "everything. (`canStart(linkReady: false)` is false on BOTH lanes by definition, which is why the "
                + "labHost half passes the lane's OWN admissibility and the shipping half passes `false`.) ***")
        XCTAssertTrue(labNode.runtime.meshNode.linkLayerAdmissible,
                      "and the labHost node's ONE admissibility property must be true")
        XCTAssertFalse(shipping.runtime.meshNode.linkLayerAdmissible,
                       "while the shipping node's stays false -- the SAME property, the two lanes")
        labNode.runtime.meshNode.start()
        labNode.runtime.meshNode.transportDidReceive(
            data: frame.encode(), peerId: UUID(), receivedFrom: Data(repeating: 0x77, count: 16))
        XCTAssertEqual(
            1, labNode.messageStore.allHeldMsgIds().count,
            "*** THE SAME BYTES, THE SAME NODE TYPE, THE OTHER LANE: the labHost node must ingest exactly one held "
                + "frame -- the difference is the LANE and nothing else, which is what maketh the refusal above "
                + "attributable to it. ***")
    }

    /// *** `testTheDefaultLaneTwinOfTheARBFrameIngestsNothing`. ***
    ///
    /// *The real-adapters arm's negative twin on the SAME bytes and the same rig shape: a `.shipping` node handed the
    /// identical ingress keepeth NO durable row. **Together with the arm above, the ingest is attributed to the lane
    /// and to nothing else.***
    func testTheDefaultLaneTwinOfTheARBFrameIngestsNothing() throws {
        let r = RealTransportHostRig()
        defer { r.tearDown() }
        try r.makeNode(label: "alice", seedByte: 0x11, staticPrivByte: 0x12)
        let shipping = try r.makeShippingNode(label: "shipping", seedByte: 0x41, staticPrivByte: 0x42)
        let frame = FrameV2(type: .message,
                            msgId: Data(repeating: 0x33, count: 16),
                            routingTag: Data(repeating: 0x00, count: 4),
                            ttl: 10, hopCount: 0,
                            flags: UInt16(Priority.direct.rawValue << 8) | UInt16(FrameV2.Flags.sealed),
                            payload: Data(repeating: 0xAB, count: 8))
        shipping.runtime.meshNode.transportDidReceive(
            data: frame.encode(), peerId: UUID(), receivedFrom: Data(repeating: 0x99, count: 16))
        XCTAssertEqual(
            0, shipping.messageStore.allHeldMsgIds().count,
            "*** THE DEFAULT LANE INGESTS NOTHING. The bytes decode -- the labHost node in the arm above ingesteth "
                + "the IDENTICAL frame -- so this refusal is `linkLayerAdmissible`, not the decoder. ***")
    }

    /// *** `testTheManagerFactoryOverrideIsTheEpochsSourceAndTheTransportStaysProduction`. ***
    ///
    /// *The seam that maketh the whole rig possible, witnessed rather than assumed: `installFreshContextLocked`
    /// resolveth the epoch's manager source as `testManagerFactoryOverride ?? managerFactory`, so with the override
    /// set the epoch's pair is the FABRIC's. **If it were ignored, discovery would enter a real `CBCentralManager`
    /// and no link could ever stand -- so this arm is why the other arms can exist at all.***
    func testTheManagerFactoryOverrideIsTheEpochsSourceAndTheTransportStaysProduction() throws {
        let r = RealTransportHostRig()
        defer { r.tearDown() }
        try r.makeNode(label: "alice", seedByte: 0x13, staticPrivByte: 0x14)
        try r.makeNode(label: "relay", seedByte: 0x23, staticPrivByte: 0x24)
        try r.link("alice", "relay")
        XCTAssertNotNil(
            r.peripheralManager("relay"),
            "*** THE EPOCH MUST HAVE OPENED THE FABRIC'S MANAGER. A nil one would mean the override was ignored "
                + "at install -- which is exactly the defect this arm exists to catch. ***")
        XCTAssertTrue(r.managerFactoryIsOverridden("relay"),
                      "and the transport must still carry the override as its epoch's manager source")
        XCTAssertTrue(
            r.transportIsTheCompositionsOwn("relay"),
            "*** AND THE TRANSPORT ITSELF MUST BE THE COMPOSITION'S REAL `BleTransport` (`MeshNode.ble`, the object "
                + "`UnifiedRuntimeLifecycle` openeth): the override substitutes the MANAGER PAIR, never the "
                + "transport -- so every reducer, driver, delegate, writer, lease and budget under it is "
                + "production. ***")
    }

    /// *** `testTheRealCompositionBuildsOnDiskStoresAndTheProductionLifecycle`. ***
    ///
    /// *What `RealTransportHostRig` actually holdeth, said as measurement: the stores are REAL `SqliteMessageStore` /
    /// `SqlitePeerIdentityStore` over temp files, and open and close travel `runtime.lifecycle` -- the production
    /// `UnifiedRuntimeLifecycle` over `LifecycleTransportAdapter`. **A rig that substituted the stores, or opened the
    /// radio by hand, would be the `ComposedRuntime` defect over again.***
    func testTheRealCompositionBuildsOnDiskStoresAndTheProductionLifecycle() throws {
        let r = RealTransportHostRig()
        defer { r.tearDown() }
        let n = try r.makeNode(label: "alice", seedByte: 0x15, staticPrivByte: 0x16)
        XCTAssertTrue(FileManager.default.fileExists(atPath: n.runtime.messageStoreUrl.path),
                      "*** THE MESSAGE STORE MUST BE A FILE ON DISK, not an in-memory dictionary: the composition "
                          + "root is the whole point of this lane. ***")
        XCTAssertTrue(FileManager.default.fileExists(atPath: n.runtime.peerStoreUrl.path),
                      "and the peer-identity store likewise")
        XCTAssertTrue((n.runtime.messageStore as Any) is SqliteMessageStore,
                      "and the store object must be the production SQLite store, not a model of it")
        XCTAssertFalse(n.runtime.lifecycle.isReady(),
                       "the owner must stand closed before any start")
        n.runtime.lifecycle.start()
        XCTAssertTrue(n.runtime.lifecycle.isReady(),
                      "*** AND `runtime.lifecycle.start()` -- THE PRODUCTION VERB -- MUST OPEN IT. This rig never "
                          + "calls `ble.start()` itself for a link it establisheth: the owner is the ONE road. ***")
        n.runtime.lifecycle.stop()
        XCTAssertFalse(n.runtime.lifecycle.isReady(), "and the production stop must close it")
    }
}
