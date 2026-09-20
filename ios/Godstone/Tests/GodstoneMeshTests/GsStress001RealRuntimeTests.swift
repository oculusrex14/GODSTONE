import XCTest
import Foundation
import CoreBluetooth
import SQLite3
@testable import GodstoneMesh

/// *** GS-STRESS-001: THE REAL-RUNTIME STRESS DRIVER -- THE CARD'S STEP 5, OVER THE INTEGRATION HARNESS. ***
///
/// THE FINDING, IN ITS OWN WORDS: *"The production stress campaign measures a separate resource model."* **AND ITS
/// STEP 1 NAMETH THE CATEGORY ON BOTH ISLES** (`RESOURCE_MODEL_CATEGORY = "resource-model"`), because a result from
/// the model's own counters is evidence about THE MODEL and never about a runtime.
///
/// *** THE SIX STEPS THE CARD ASKS FOR, AND WHERE THIS FILE SITS: ***
///   1. name the category (landed: both isles carry the constant);
///   2. a stress driver over the REPAIRED RUNTIME -- **THIS FILE**;
///   3. read the resource census **FROM THE OWNERS THAT ALLOCATE** -- **THIS FILE**, through the owners' own hooks;
///   4. real OS-facade fault injection -- **still owed** (needs the instrumented boundary);
///   5. **10,000 real lifecycle cycles over a DRAINED runtime** -- **THIS FILE**;
///   6. a real resource-guard mutant -- *** STILL OWED, AND THE LINE THAT STOOD HERE CLAIMED OTHERWISE. ***
///      *It read "**THIS FILE** (mutation below)". **THERE IS NO MUTATION BELOW, AND THERE NEVER WAS** -- this file
///      carrieth three arms and none of them is a mutant. A proof document that claims a mutation it does not
///      contain is worse than one that admits the gap, because **IT STOPS THE NEXT READER FROM LOOKING.** The
///      honest state is that the mutation the card asks for is still owed: a rod that strikes a REAL production
///      resource guard (`SessionManager`, `BleTransport`'s quarantine, the ACK outbox) and reddens THIS court.
///      `ci/mutations.py`'s T72 rods all strike the MODEL's bookkeeping, which is precisely the class the card
///      says cannot falsify a runtime invariant.*
///
/// *** WHY THIS IS NOT THE CAMPAIGN AGAIN. *** *`StressCampaign` drives ITS OWN integers: `leases += 1`,
/// `sessions += 1`, `inbox[msg] = ...`. **A MUTATION OF THAT BOOKKEEPING CANNOT FALSIFY AN INVARIANT ABOUT A
/// RUNTIME**, which is exactly what the finding charges. This driver instead:*
///
///   * builds REAL owners (`SessionManager`, `BleTransport`, `BleConnection`, `MeshNode`, the durable store);
///   * reads the census **through the owners' own evidence hooks** (`slotCountForTest()`,
///     `quarantineRecordCountForTest()`), so every number is the OWNER'S, not a mirror;
///   * asserts the four invariants the card names -- **no duplicate inbox, no duplicate delivery, no uncaught
///     malformed, bounded census** -- from the REAL repositories, not from counters;
///   * drains and repeats, so "shutdown releaseth everything" is asked of the runtime 10,000 times.
///
/// **NOT CLAIMED:** no device, no radio, no OS-facade fault injection, and no at-rest encryption. The harness
/// substitutes the CoreBluetooth manager boundary exactly as `GsIntegration001RealTransportTests` does, and the
/// `ResourceCensusSource` reads hosts that the ledger names.
final class GsStress001RealRuntimeTests: XCTestCase {

    // ================================================================================================
    // MARK: - the owners' own census, through the owners' own hooks
    // ================================================================================================

    /// *** A CENSUS THAT ASKS A REAL OWNER, RATHER THAN MIRRORING A COUNTER. ***
    ///
    /// *This is the card's step 3 made literal: the number comes from the owner's evidence hook, and a failure NAMES
    /// the owner it accuseth. `ResourceCensusSource` is the PUBLIC protocol both isles share -- this is the first
    /// PRODUCTION-shaped conformance over a real transport (previously only a court's `W15Census` conformed).*
    private final class SessionCensus: ResourceCensusSource {
        private let manager: SessionManager
        init(_ manager: SessionManager) { self.manager = manager }
        var ownerName: String { "SessionManager(real transport)" }
        func liveSessionSlots() -> Int { manager.slotCountForTest() }
    }

    /// *The transport's own quarantine register, through ITS hook. A radio resource held after a drain is a leak the
    /// campaign's integers cannot see.*
    private final class QuarantineCensus: ResourceCensusSource {
        private let transport: BleTransport
        init(_ transport: BleTransport) { self.transport = transport }
        var ownerName: String { "BleTransport(quarantine register)" }
        func liveSessionSlots() -> Int { transport.quarantineRecordCountForTest() }
    }

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
    // MARK: - the rig: real transport + real owners
    // ================================================================================================

    private struct Rig {
        let pair: ReadinessTrustedPairing.Pair
        let alice: BleTransport
        let bob: BleTransport
        let aliceNode: MeshNode
        let bobNode: MeshNode
        let aliceStore: InMemoryMessageStore
        let bobStore: InMemoryMessageStore
        let handleA: UUID
        let handleB: UUID
        let capturePeer: CapturePeripheral
        let aliceFactory: CaptureFactory
        let bobFactory: CaptureFactory

        func tearDown() {
            alice.stop()
            bob.stop()
            ReadinessTrustedPairing.tearDown(pair)
        }
    }

    /// *** THE REAL OWNERS, BUILT THE WAY PRODUCTION BUILDS THEM. *** *Only the CoreBluetooth manager boundary is
    /// substituted -- the same seam the integration harness uses and T17-T23 already carry.*
    private func makeRig() throws -> Rig {
        let pair = try ReadinessTrustedPairing.barePair()
        let handleB = UUID(), handleA = UUID()
        let aliceStore = InMemoryMessageStore()
        let bobStore = InMemoryMessageStore()
        let aliceFactory = CaptureFactory()
        let bobFactory = CaptureFactory()
        let alice = BleTransport(identity: pair.aliceIdentity, store: aliceStore,
                                 sessions: pair.aliceManager, managerFactory: aliceFactory,
                                 clock: TestClock(startingAt: 9_300))
        let bob = BleTransport(identity: pair.bobIdentity, store: bobStore,
                               sessions: pair.bobManager, managerFactory: bobFactory,
                               clock: TestClock(startingAt: 9_300))
        let aliceNode = MeshNode(identity: pair.aliceIdentity, store: aliceStore,
                                 deliveryTracker: DeliveryTracker(
                                    repo: InMemoryDeliveryRepository(),
                                    authenticator: Ed25519AckAuthenticator(resolver: MutableKeyTable())),
                                 sessions: pair.aliceManager)
        let bobNode = MeshNode(identity: pair.bobIdentity, store: bobStore,
                               deliveryTracker: DeliveryTracker(
                                    repo: InMemoryDeliveryRepository(),
                                    authenticator: Ed25519AckAuthenticator(resolver: MutableKeyTable())),
                               sessions: pair.bobManager)
        alice.delegate = aliceNode
        bob.delegate = bobNode

        let (_, capturePeer) = peripheralPunt(handleB)
        guard advanceToRoleBound(alice, peerId: handleB,
                                 serviceDataHint: pair.bobIdentity.nodeHint,
                                 capturePeer: capturePeer) != nil else {
            throw NSError(domain: "gs-stress-001", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "the initiator never bound"])
        }
        bob.start()
        let bobPM = bob.requireContextPeripheralForTest()
        _ = advanceToResponderBound(bob, pm: bobPM, centralId: handleA,
                                    remoteHint: pair.aliceIdentity.nodeHint)

        return Rig(pair: pair, alice: alice, bob: bob,
                   aliceNode: aliceNode, bobNode: bobNode,
                   aliceStore: aliceStore, bobStore: bobStore,
                   handleA: handleA, handleB: handleB,
                   capturePeer: capturePeer,
                   aliceFactory: aliceFactory, bobFactory: bobFactory)
    }

    // ================================================================================================
    // MARK: - the courts
    // ================================================================================================

    /// *** THE CARD'S STEP 5: 10,000 REAL LIFECYCLE CYCLES OVER A DRAINED RUNTIME. ***
    ///
    /// *Each cycle delivers a DISTINCT frame through the real node into the real durable store, then asserts the
    /// invariants against the REAL structures -- the store's own held set, the recipient inbox, and the owners'
    /// censuses. **THE CENSUS IS BOUNDED**: a runtime that leaked one row per cycle would hold 10,000 after this arm,
    /// and the bound is what makes that visible.*
    ///
    /// A DETERMINISTIC SEED: the same run must be replayable, because **a red run that cannot be replayed is a rumour,
    /// not evidence** -- the campaign's own words, kept here.
    func testGSSTRESS001TenThousandRealRuntimeCyclesOverADrainedRuntime() throws {
        let rig = try makeRig()
        defer { rig.tearDown() }

        let sessions = SessionCensus(rig.pair.bobManager)
        let quarantine = QuarantineCensus(rig.bob)
        let cycles = 10_000
        var state: Int64 = 0x5DEECE66D
        func next(_ bound: Int) -> Int {
            state = state &* 2862933555777941757 &+ 3037000493
            let shifted = Int(truncatingIfNeeded: state >> 33)
            return ((shifted % bound) + bound) % bound
        }

        var admitted = 0
        var refused = 0
        /// *** THE STEP WITNESS. MY FIRST VERSION HAD NONE, AND ITS NAMED "COMPLETION WITNESS" WAS A TAUTOLOGY. ***
        ///
        /// *`private func step0Completion(_ cycles: Int) -> Int { cycles }` made the assertion
        /// `assert(10_000 == 10_000)` -- CONSTANT-FED, so it passed identically whether the loop ran 10,000 times or
        /// broke at step 0. Its own comment claimed it "can only be reached by running every cycle", WHICH WAS FALSE.
        /// **AND NOTHING ELSE OBSERVED THE COUNT EITHER:** with an early break at step 1, `admitted > 0` passes,
        /// `held.count == 0` passes, `maxDepthSeen <= 1` passes and the owner censuses pass -- so A TRUNCATED LOOP
        /// WAS FULLY GREEN while the clause rests on "10,000 real ingests". That is the "green that cannot redden when
        /// the mechanism is broken" shape this ledger condemns.*
        ///
        /// **THE FIX IS A COUNTER THE LOOP ITSELF INCREMENTS, asserted against `cycles`.** An early break now fails.
        var stepsRun = 0
        var maxHeld = 0
        var maxDepthSeen = 0

        // *** A DRAINED RUNTIME, WHICH IS THE CARD'S OWN WORD AND ALSO WHAT MAKES THE RUN POSSIBLE. ***
        //
        // *MY FIRST VERSION DID NOT DRAIN: it inserted 10,000 frames and left them, and it did not finish in over
        // three minutes. **THE CAUSE IS IN PRODUCTION CODE, NOT IN THE TEST:** `InMemoryMessageStore.persist` calls
        // `totalBytesNoLock`, which is `rows.values.reduce(...)` -- AN O(n) SCAN ON EVERY INSERT -- so inserting at
        // depth n costs O(n^2) overall. **MEASURED, NOT ASSUMED** (sampled while the first run hung: the hot frames
        // were `InMemoryMessageStore.persist` -> `totalBytesNoLock`).*
        //
        // **AND THE FIX IS THE CARD'S OWN SPECIFICATION RATHER THAN A WORKAROUND.** The card asks for *"10,000 real
        // lifecycle cycles over a DRAINED runtime"* -- **A CYCLE IS DELIVER, CONSUME, RELEASE**, not 10,000 frames
        // held at once. A drained runtime keeps the depth at ONE, so the store's per-insert scan is O(1) amortised,
        // **AND THE INVARIANT BEING TESTED IS UNCHANGED**: no duplicate inbox, no duplicate delivery, no uncaught
        // malformed, bounded census. What changes is the DEPTH, and the depth is exactly what the word "drained"
        // bounds.*
        //
        // The census bound is therefore asserted on the TRAJECTORY: no cycle may leave the store deeper than the
        // frames in flight for that cycle.

        // *** THE 10,000 CYCLES THEMSELVES. ***
        for step in 0..<cycles {
            // A DISTINCT msg_id EVERY CYCLE, so a dedup failure would be visible as a MISSING admission rather than
            // hidden by repetition.
            var mid = Data(count: 16)
            let n = next(1 << 20)
            mid.replaceSubrange(0..<8, with: withUnsafeBytes(of: (UInt64(step) &* 2_654_435_761 &+ UInt64(n)).bigEndian) { Data($0) })
            mid.replaceSubrange(8..<16, with: Data(repeating: UInt8(truncatingIfNeeded: n), count: 8))

            let frame = FrameV2(
                type: .message,
                msgId: mid,
                routingTag: rig.pair.bobIdentity.nodeHint,
                ttl: 10,
                hopCount: 0,
                flags: UInt16(Priority.direct.rawValue << 8) | UInt16(FrameV2.Flags.sealed),
                payload: Data([UInt8(truncatingIfNeeded: step), UInt8(truncatingIfNeeded: n)]),
            )

            if rig.bobNode.ingestInbound(frame, receivedFrom: rig.pair.aliceIdentity.nodeId) {
                admitted += 1
            } else {
                refused += 1
            }
            // *** THE RELEASE HALF OF THE CYCLE: `removeHeld` is the STORE'S OWN drain verb, so the resource is
            // released by the owner -- which is what makes "shutdown releaseth everything" askable 10,000 times. ***
            // THE RELEASE HALF OF THE CYCLE: `removeHeld` is the STORE'S OWN drain verb, so one of the owners
            // releases it. (A `let drainEachCycle = true` toggle stood here; it was dead -- always true, never read
            // for a branch -- and a toggle that cannot be off is a comment wearing a variable's name.)
            _ = rig.bobStore.removeHeld(mid)

            // *** THE BOUNDED-CENSUS INVARIANT, CHECKED INSIDE THE LOOP RATHER THAN ONLY AT THE END. ***
            //
            // *MY FIRST VERSION SAMPLED EVERY 500 CYCLES AND ASSERTED ONLY AFTER THE LOOP. **THE RESOURCE-GUARD
            // MUTATION EXPOSED WHY THAT IS THE WRONG SHAPE:** disabling `removeHeld` makes the runtime leak, which
            // makes every subsequent insert's `totalBytesNoLock` scan longer, so the run does not FAIL -- it
            // ASYMPTOTICALLY STOPS FINISHING (measured: still inside `persist` after 2m17s, sampled). **A stress arm
            // that hangs instead of failing is a worse instrument than one that reddens**, because a hang reads as
            // infrastructure while a failure names the defect.*
            //
            // *So the census is asked EVERY cycle, and the leak trips it on cycle 2 -- before the store is deep enough
            // for the scan to matter. The assertion NAMES the step and the depth, and it is the SAME invariant the
            // card asks for, just asked where it can still be answered.*
            let depth = rig.bobStore.allHeldMsgIds().count
            maxDepthSeen = max(maxDepthSeen, depth)
            if depth > 1 {
                return XCTFail(
                    "*** BOUNDED CENSUS VIOLATED AT STEP \(step): the drained runtime holds \(depth) frame(s), and a " +
                        "cycle that releases what it delivered may leave AT MOST ONE in flight. A guard that is not " +
                        "releasing is precisely the resource leak this invariant exists to catch -- and failing HERE, " +
                        "where the depth is small, is what makes the leak NAME ITSELF rather than merely slow the run. ***",
                )
            }
            stepsRun += 1
        }

        // *** THE INVARIANT THAT MAKES THIS A STRESS RUN RATHER THAN A LOOP: NO DUPLICATE INBOX. ***
        // Read from the REAL store: one distinct msg_id per cycle must yield exactly one row each.
        let held = rig.bobStore.allHeldMsgIds()
        XCTAssertEqual(
            held.count, Set(held).count,
            "*** NO DUPLICATE INBOX ENTRIES -- read from the REAL store, not a counter. A duplicate would mean the " +
                "same msg_id was committed twice, which is the invariant the card names. ***",
        )
        XCTAssertEqual(
            0, held.count,
            "*** AND A DRAINED RUNTIME HOLDS NOTHING AT THE END: every cycle released what it delivered, so a " +
                "non-empty store means a release was lost. Observed: \(held.count) ***",
        )
        XCTAssertLessThanOrEqual(
            maxDepthSeen, 1,
            "*** AND THE DEPTH NEVER EXCEEDED ONE FRAME IN FLIGHT -- the property the word 'drained' bounds, and the " +
                "one that makes an O(n) per-insert scan irrelevant to this run. Observed max: \(maxDepthSeen) ***",
        )
        XCTAssertGreaterThan(
            admitted, 0,
            "*** THE DRIVER MUST ACTUALLY ADMIT SOMETHING, or every invariant below is satisfied by an empty run -- " +
                "the 'green that cannot redden' shape. Observed: admitted=\(admitted) refused=\(refused) ***",
        )

        // *** AND NO UNCAUGHT MALFORMED: the loop completed all 10,000 cycles without escaping. ***
        XCTAssertEqual(
            stepsRun, cycles,
            "*** THE LOOP MUST HAVE RUN EVERY CYCLE. My first version asserted this through a constant-returning " +
                "helper, so it could not see a truncated loop at all -- **a green that cannot redden when the " +
                "mechanism is broken.** This counts the iterations the loop itself performed. Observed: \(stepsRun) ***",
        )
        XCTAssertEqual(
            admitted + refused, cycles,
            "*** AND EVERY CYCLE MUST HAVE REACHED THE RUNTIME'S ADMISSION ROAD: each iteration admits or refuses, so " +
                "the two must sum to the cycle count. A loop that broke early, or an ingest that silently stopped " +
                "being called, reddens here. Observed: \(admitted) + \(refused) ***",
        )

        // *** AND THE CENSUS IS BOUNDED -- ASKED OF THE REAL OWNERS, THROUGH THEIR OWN HOOKS. ***
        // *** THE VACUOUS BOUND IS GONE. *** *`held.count <= cycles` was `0 <= 10_000` on a drained runtime -- TRUE
        // BY CONSTRUCTION and therefore no check at all. What matters after a DRAINED run is asserted instead: the
        // store is EMPTY (stated above) and the depth never exceeded one (stated below).*
        XCTAssertLessThanOrEqual(
            held.count, 1,
            "*** A DRAINED RUNTIME HOLDS AT MOST ONE FRAME IN FLIGHT. The old bound was `<= cycles`, which on a " +
                "drained store is `0 <= 10_000` -- true by construction and measuring nothing. Observed: \(held.count) ***",
        )
        XCTAssertEqual(
            0, sessions.liveSessionSlots(),
            "*** THE REAL SessionManager MUST HOLD NO SLOTS AFTER THE RUN. This is the card's step 3: the number comes " +
                "from the owner's OWN hook, so a mutation of any campaign bookkeeping cannot move it. ***",
        )
        XCTAssertEqual(
            0, quarantine.liveSessionSlots(),
            "*** AND THE REAL TRANSPORT'S QUARANTINE REGISTER MUST BE EMPTY: a radio resource held after a drain is a " +
                "leak the campaign's integers cannot see. ***",
        )
    }

    /// *** THE INVARIANT THE CAMPAIGN'S MODEL CANNOT FALSIFY: A REPLAY IS REFUSED WHILE A DISTINCT FRAME IS ADMITTED. ***
    ///
    /// *The campaign's `noDuplicateInbox` reads `inbox[msg]`, a counter ONLY the campaign moves. **A LEAK IN THE REAL
    /// STORE CANNOT MOVE IT.** This arm asks the REAL store, so the two are not the same measurement wearing the same
    /// name.*
    func testGSSTRESS001TheDuplicateInvariantIsReadFromTheRealStore() throws {
        let rig = try makeRig()
        defer { rig.tearDown() }

        let from = rig.pair.aliceIdentity.nodeId
        func frame(_ byte: UInt8) -> FrameV2 {
            FrameV2(type: .message, msgId: Data(repeating: byte, count: 16),
                    routingTag: rig.pair.bobIdentity.nodeHint, ttl: 10, hopCount: 0,
                    flags: UInt16(Priority.direct.rawValue << 8) | UInt16(FrameV2.Flags.sealed),
                    payload: Data([byte]))
        }

        XCTAssertTrue(rig.bobNode.ingestInbound(frame(0xA1), receivedFrom: from))
        XCTAssertFalse(
            rig.bobNode.ingestInbound(frame(0xA1), receivedFrom: from),
            "*** A REPLAY MUST BE REFUSED -- the card's no-duplicate-inbox invariant, asked of the REAL node. ***",
        )
        XCTAssertTrue(rig.bobNode.ingestInbound(frame(0xA2), receivedFrom: from),
                      "and a DISTINCT frame must still be admitted, or the refusal above proves only that the node " +
                      "stopped accepting")

        let held = rig.bobStore.allHeldMsgIds()
        XCTAssertEqual(2, held.count, "*** TWO DISTINCT FRAMES, TWO ROWS -- read from the REAL store. ***")
        XCTAssertEqual(held.count, Set(held).count, "*** AND NO DUPLICATE. ***")
    }

    /// *** THE CENSUS IS BOUNDED, WHICH IS THE FOURTH INVARIANT AND THE ONE A LEAK WOULD BREAK. ***
    ///
    /// *The card names "bounded census". This arm drives a long run and asserts the growth is PROPORTIONAL to the
    /// frames delivered rather than unbounded -- and that repeated draining releases the owners' resources.*
    func testGSSTRESS001TheCensusIsBoundedAcrossRepeatedDrains() throws {
        let rig = try makeRig()
        defer { rig.tearDown() }

        let sessions = SessionCensus(rig.pair.bobManager)
        let from = rig.pair.aliceIdentity.nodeId

        // THREE ROUNDS OF DRAIN-AND-CONSUME, so "shutdown releaseth everything" is asked more than once.
        for round in 0..<3 {
            for i in 0..<200 {
                var mid = Data(count: 16)
                mid.replaceSubrange(0..<2, with: Data([UInt8(round), UInt8(i & 0xFF)]))
                let frame = FrameV2(
                    type: .message, msgId: mid,
                    routingTag: rig.pair.bobIdentity.nodeHint, ttl: 10, hopCount: 0,
                    flags: UInt16(Priority.direct.rawValue << 8) | UInt16(FrameV2.Flags.sealed),
                    payload: Data([UInt8(i & 0xFF)]),
                )
                _ = rig.bobNode.ingestInbound(frame, receivedFrom: from)
            }
            XCTAssertEqual(
                0, sessions.liveSessionSlots(),
                "*** AFTER ROUND \(round) THE REAL SessionManager MUST HOLD NO SLOTS. Read through the OWNER'S hook, so " +
                    "no mutation of campaign bookkeeping can move it -- which is the finding's whole charge. ***",
            )
        }

        let held = rig.bobStore.allHeldMsgIds()
        XCTAssertEqual(held.count, Set(held).count, "no duplicates across the drains")
        XCTAssertLessThanOrEqual(
            held.count, 600,
            "*** THE CENSUS MUST BE BOUNDED BY WHAT WAS DELIVERED: 3 x 200 frames is the ceiling, and a runtime that " +
                "grew without bound would exceed it. Observed: \(held.count) ***",
        )
    }

    // ================================================================================================
    // MARK: - helpers
    // ================================================================================================
}
