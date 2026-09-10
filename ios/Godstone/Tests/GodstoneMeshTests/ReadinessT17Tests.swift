import XCTest
import Foundation
import CoreBluetooth
import ObjectiveC
@testable import GodstoneCore
@testable import GodstoneMesh

/// T17: the trust boundary of the transport. No frame goes out unsealed,
/// no record arrives unauthenticated, and the cryptographic ready is
/// reached only through the real handshake entries - never through the
/// physical test seams. The required cases of the card:
///  - a transport without a trusted session registry is rejected (01);
///  - pretrust DATA is rejected (02);
///  - authentication failure then valid input succeeds (03);
///  - the release symbols carry no test factories nor plaintext fallback (04),
///    proven by the selector inventory and by the zero captures on the wire.
/// The chain case (05) runs the whole way: link-info, role binding, the
/// handshake record writer, the session slots, authenticated events.
final class ReadinessT17Tests: XCTestCase {

    // MARK: - fixtures (the house idiom: each suite owns its witnesses)

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
        // T19: the responder send asks the destination central what it may
        // carry as an update before it reserves the record; the answer is
        // the att maximum of the subscription, here the house default.
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
        // T19: the initiator send asks the peer what it may write before
        // reserving; the selector is pinned to the name the framework
        // imports under its own declaration, as the crash taught.
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
        // T19: the leg answers as the suite scripts it, and every attempt is
        // recorded - refusals as faithfully as deliveries - for the ring of
        // the queue full and the witness that the re-hand carries the very
        // same fragment. capturedUpdates keeps its old meaning: the accepted
        // notifications only.
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
        // The bridge names the read 'uuid' speak as selector "UUID" - the
        // holder must answer the all-caps spelling the stack really sends,
        // and the plain one too for callers that resolve it lower.
        @objc func UUID() -> CBUUID { return BleTransport.inboxCharacteristicUuid }
        @objc func uuid() -> CBUUID { return BleTransport.inboxCharacteristicUuid }
    }

    private final class T17DelegateSpy: TransportDelegate, @unchecked Sendable {
        private let lk = NSLock()
        private var recv: [(data: Data, peerId: UUID)] = []
        private var hs: [UUID] = []
        func transportDidReceive(data: Data, peerId: UUID) {
            lk.lock(); recv.append((data, peerId)); lk.unlock()
        }
        func transportDidHandshakeReady(peerId: UUID) {
            lk.lock(); hs.append(peerId); lk.unlock()
        }
        func transportDidConnect(peerId: UUID) {}
        func transportDidDisconnect(peerId: UUID) {}
        func transportPhysicalDuplexReady(peerId: UUID) {}
        var received: [(data: Data, peerId: UUID)] {
            lk.lock(); defer { lk.unlock() }
            return recv
        }
        var handshakeReadyPeers: [UUID] {
            lk.lock(); defer { lk.unlock() }
            return hs
        }
    }

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { return storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
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
    private final class NotifyingInboxCharacteristic: CBMutableCharacteristic {
        override var isNotifying: Bool { return true }
    }
    private static func provisionedService() -> CBMutableService {
        let installed = BleTransport.characteristicsToInstall(BleTransport.meshProfile)
        let service = CBMutableService(type: BleTransport.meshProfile.serviceUuid, primary: true)
        service.characteristics = installed
        return service
    }
    private final class T17MessageStore: MessageStore {
        var held: [Data] = []
        private var observers: [@Sendable () -> Void] = []
        private let lock = NSLock()

        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            observers.append(observer)
        }

        func notifyObservers() {
            lock.lock()
            let obs = observers
            lock.unlock()
            obs.forEach { $0() }
        }

        func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult {
            lock.lock()
            held.append(frame.msgId)
            lock.unlock()
            notifyObservers()
            return .heldNew
        }

        func removeHeld(_ msgId: Data) -> Bool {
            lock.lock()
            let initial = held.count
            held.removeAll { $0 == msgId }
            let removed = held.count < initial
            lock.unlock()
            if removed {
                notifyObservers()
            }
            return removed
        }

        func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data, localOriginNodeId: Data) -> OutboundEnqueueResult {
            .canonicalFrameMismatch
        }
        func allHeldOrderedByPriority() -> [FrameV2] { [] }
        func allHeldMsgIds() -> [Data] {
            lock.lock()
            defer { lock.unlock() }
            return held
        }
        func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {}
        func forEachHeldMsgId(_ visit: (Data) -> Bool) {
            lock.lock()
            let copy = held
            lock.unlock()
            for id in copy {
                if !visit(id) { break }
            }
        }
        var heldBytes: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return Int64(held.count * 32)
        }
    }

    private var pins: [AnyObject] = []

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

    private func pushWrite(_ bob: BleTransport, _ pm: CBPeripheralManager,
                           centralId: UUID, bytes: Data) {
        let pinned = centralPresent(centralId)
        let req = CaptureRequest(centralId: centralId, pinnedCentral: pinned, value: bytes)
        pins.append(req)
        _ = bob.processPeripheralReceiveWrite(pm, requests: [unsafeBitCast(req, to: CBATTRequest.self)],
                                             sourceEpoch: bob.currentTransportEpoch)
    }

    private func firstCapture(of manager: CapturePeripheralManager, towards central: UUID) -> Data? {
        return manager.capturedUpdates.last(where: { $0.central == central })?.bytes
    }

    /// The initiator's legs, as the T14 recipe drives them, with the
    /// capture peripheral standing at the connected peripheral's place.
    private func advanceToRoleBound(_ alice: BleTransport, peerId: UUID,
                                    serviceDataHint: Data,
                                    capturePeer: CapturePeripheral) -> RelationPeripheralDelegate? {
        alice.start()
        alice.refreshLocalLinkInfoSnapshotSync()
        let cm = alice.requireContextCentralForTest()
        // The one true discovery entry: it decodes the advertisement's
        // embedded link-info record, stores the discovery metadata the HS2
        // check will consult, registers the found peripheral with the
        // connected family, and forwards the outbound discover itself.
        let advRecord: [String: Any] = [
            CBAdvertisementDataServiceDataKey: [BleTransport.serviceUuid:
                ReadinessT17Tests.remoteLinkInfoStatic(hint: serviceDataHint)]
        ]
        _ = alice.processCentralDidDiscover(
            cm, peripheral: unsafeBitCast(capturePeer, to: CBPeripheral.self),
            advertisementData: advRecord, rssi: NSNumber(value: -60),
            sourceEpoch: alice.currentTransportEpoch)
        guard let delegate = alice.getRelationDelegate(peerId) else { return nil }
        // The connect leg is deferred, as the proven recipe drives it: the
        // punted handle must never reach the real manager's connect.
        _ = alice.processCentralConnect(
            peerId: peerId, peripheral: nil,
            sourceEpoch: alice.currentTransportEpoch, from: cm)
        walkLog.append("after connect: " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let a1 = alice.processPeripheralDiscoverServices(nil, delegate: delegate, error: nil)
        walkLog.append("services -> " + String(describing: a1) + " @ " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let a2 = alice.processPeripheralDiscoverCharacteristics(nil, delegate: delegate,
                                                          service: ReadinessT17Tests.provisionedService(), error: nil)
        walkLog.append("characteristics -> " + String(describing: a2) + " @ " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let linkInfoChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: ReadinessT17Tests.remoteLinkInfoStatic(hint: serviceDataHint),
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

    private var walkLog: [String] = []
    private func walk(_ s: String) -> String { walkLog.append(s); return s }

    /// The responder's legs: the accepted incoming link-info and the
    /// subscription, both through the real entries. The caller must have
    /// opened an epoch already: manager-sourced events need a live context,
    /// and the transport's precondition guards exactly that.
    private func advanceToResponderBound(_ bob: BleTransport, pm: CBPeripheralManager,
                                         centralId: UUID, remoteHint: Data,
                                         updateCapacity: Int = 512) -> (Bool, String) {
        let w = bob.processInboundWrite(centralId: centralId,
                                        rawData: ReadinessT17Tests.remoteLinkInfoStatic(hint: remoteHint),
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

    /// The lexicographic order the election consults over the hint bytes.
    static func hintAscending(_ x: Data, _ y: Data) -> Bool {
        let a = [UInt8](x), b = [UInt8](y)
        for i in 0..<min(a.count, b.count) {
            if a[i] != b[i] { return a[i] < b[i] }
        }
        return a.count < b.count
    }

    /// A hint that places the local node above the peer on the wire: the
    /// local side is then elected responder. (The smaller hint initiates.)
    static func lesserHint(than local: Data) -> Data {
        var b: UInt8 = 254
        while b > 0 {
            let c = Data([b, 0, 0, 0])
            if ReadinessT17Tests.hintAscending(c, local) { return c }
            b -= 1
        }
        return Data([0x00, 0x00, 0x00, 0x01])
    }

    /// A hint that places the local node below the peer: the local side is
    /// elected initiator, as the outbound legs require.
    static func greaterHint(than local: Data) -> Data {
        var b: UInt8 = 1
        while b < 255 {
            let c = Data([b, 0, 0, 0])
            if ReadinessT17Tests.hintAscending(local, c) { return c }
            b += 1
        }
        return Data([0xFF, 0xFF, 0xFF, 0xFE])
    }

    private static func remoteLinkInfoStatic(hint: Data) -> Data {
        return BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: hint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0)
    }

    private func containsBytes(_ haystack: Data, _ needle: Data) -> Bool {
        guard needle.count > 0, haystack.count >= needle.count else { return false }
        let h = [UInt8](haystack), n = [UInt8](needle)
        for i in 0...(h.count - n.count) where Array(h[i..<(i + n.count)]) == n { return true }
        return false
    }

    // MARK: - required case 1: no trusted registry, nothing ships

    func testTransportWithoutRegistryRefusesToShipAnything() throws {
        let identity = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let alice = BleTransport(identity: identity, store: T17MessageStore(),
                                 managerFactory: CaptureFactory(), clock: TestClock(startingAt: 9_000))
        let peerId = UUID()
        let (_, capturePeer) = peripheralPunt(peerId)
        let hint = ReadinessT17Tests.greaterHint(than: identity.nodeHint)
        _ = advanceToRoleBound(alice, peerId: peerId, serviceDataHint: hint, capturePeer: capturePeer)
        alice.connection(for: peerId)?.markReadyForTesting()

        // The registry is absent: the frame must die before the outlet.
        let verdict = alice.send(makeFrame([1, 2, 3]), to: peerId)
        XCTAssertEqual(verdict, .rejected("no trusted session registry"), "walk: " + walkLog.joined(separator: " | "))
        XCTAssertTrue(capturePeer.writes.isEmpty, "the plaintext never reaches the wire")
        let events = alice.rejectionRecordsForTest()
        XCTAssertEqual(events.last?.peerId, peerId)
        XCTAssertEqual(events.last?.site, "send")
        XCTAssertEqual(events.last?.reason, "no trusted session registry")
        alice.stop()
    }

    func testFailClosedRegistryShipsNothingEither() throws {
        // The contrast arm: a registry is wired, but it trusts no binding,
        // so no session can open and no seal can be made. The distinction
        // from the missing registry is the reason the ring reports.
        let identity = try makeIdentity(seedByte: 0x11, staticPrivByte: 0x22)
        let failClosed = SessionManager(identity: identity,
                                        trustAuthority: ReadinessTrustedPairing.FailClosedTrustAuthority())
        let alice = BleTransport(identity: identity, store: T17MessageStore(), sessions: failClosed,
                                 managerFactory: CaptureFactory(), clock: TestClock(startingAt: 9_000))
        let peerId = UUID()
        let (_, capturePeer) = peripheralPunt(peerId)
        _ = advanceToRoleBound(alice, peerId: peerId, serviceDataHint: ReadinessT17Tests.greaterHint(than: identity.nodeHint),
                               capturePeer: capturePeer)
        alice.connection(for: peerId)?.markReadyForTesting()

        let verdict = alice.send(makeFrame([1, 2, 3]), to: peerId)
        XCTAssertEqual(verdict, .rejected("seal refused"))
        XCTAssertTrue(capturePeer.writes.isEmpty, "an unsealed frame never goes out either")
        XCTAssertEqual(alice.rejectionRecordsForTest().last?.site, "seal")
        alice.stop()
    }

    // MARK: - required case 2: pretrust DATA is rejected

    func testPretrustDataFrameIsRejectedAndTheCollectorSurvives() throws {
        let pair = try ReadinessTrustedPairing.barePair()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let bobFactory = CaptureFactory()
        let bob = BleTransport(identity: pair.bobIdentity, store: nil, sessions: pair.bobManager,
                               managerFactory: bobFactory, clock: TestClock(startingAt: 9_100))
        let spy = T17DelegateSpy()
        bob.delegate = spy
        bob.start()
        let pm = bob.requireContextPeripheralForTest()
        let centralId = UUID()
        let (bound2, saw2) = advanceToResponderBound(bob, pm: pm, centralId: centralId,
                                                   remoteHint: ReadinessT17Tests.lesserHint(than: pair.bobIdentity.nodeHint))
        XCTAssertTrue(bound2, "the responder never bound its role: " + saw2)
        bob.connection(for: centralId)?.markReadyForTesting()   // physical only - no pairing has run

        // Build a DATA record with the connection's own writer and push it.
        let writer = BleConnection(peerId: centralId, initialMaxAttValueLength: 512)
        writer.markReadyForTesting()
        let frags = writer.fragmentOutbound(recordType: .data, payload: Data([7, 1, 3, 3, 7]))
        XCTAssertFalse(frags.isEmpty)
        pushWrite(bob, pm, centralId: centralId, bytes: frags[0])

        // Admitted by the state gate, refused by the cryptographic gate.
        XCTAssertTrue(spy.received.isEmpty, "nothing is delivered out of an unauthenticated session")
        let events = bob.rejectionRecordsForTest()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.last?.site, "open.write")
        XCTAssertEqual(events.last?.reason, "unauthenticated payload")

        // The collector keeps running: a second, different bad record makes
        // a second event. (The very same fragment twice is a duplicate,
        // which the deframer rightly swallows - so the retry varies.)
        let second = writer.fragmentOutbound(recordType: .data, payload: Data([8, 8, 9]))
        XCTAssertFalse(second.isEmpty)
        XCTAssertNotEqual(Array(second[0]), Array(frags[0]), "the retry must be a fresh record")
        pushWrite(bob, pm, centralId: centralId, bytes: second[0])
        XCTAssertEqual(bob.rejectionRecordsForTest().count, 2)
        XCTAssertTrue(spy.received.isEmpty)
        bob.stop()
    }

    // MARK: - required case 3: authentication failure, then valid input

    func testAuthenticationFailureThenValidInputSucceeds() throws {
        let pair = try ReadinessTrustedPairing.barePair()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let bobFactory = CaptureFactory()
        let bob = BleTransport(identity: pair.bobIdentity, store: nil, sessions: pair.bobManager,
                               managerFactory: bobFactory, clock: TestClock(startingAt: 9_200))
        let spy = T17DelegateSpy()
        bob.delegate = spy
        bob.start()
        let pm = bob.requireContextPeripheralForTest()
        let centralId = UUID()
        let (bound3, saw3) = advanceToResponderBound(bob, pm: pm, centralId: centralId,
                                                   remoteHint: pair.aliceIdentity.nodeHint)
        XCTAssertTrue(bound3, "the responder never bound its role: " + saw3)
        bob.connection(for: centralId)?.markReadyForTesting()

        let writer = BleConnection(peerId: centralId, initialMaxAttValueLength: 512)
        writer.markReadyForTesting()
        let payload = Data([7, 1, 3, 3, 7])
        let frags = writer.fragmentOutbound(recordType: .data, payload: payload)
        XCTAssertFalse(frags.isEmpty)

        // First: the open fails, the record is refused, nothing is delivered.
        pushWrite(bob, pm, centralId: centralId, bytes: frags[0])
        XCTAssertTrue(spy.received.isEmpty)
        XCTAssertEqual(bob.rejectionRecordsForTest().count, 1)

        // Then trust is established through the real manager entries.
        try ReadinessTrustedPairing.pairUp(pair, viaBob: centralId, viaAlice: centralId,
                                           aliceHint: pair.aliceIdentity.nodeHint,
                                           bobHint: pair.bobIdentity.nodeHint)

        // A fresh record from the same writer now authenticates and is
        // delivered - the session's replay window would, correctly, silence
        // an exact repeat, so the retry varies while remaining the same kind.
        guard let sealedRenew = pair.aliceManager.seal(centralId, Data(payload)) else {
            XCTFail("the initiator could not seal towards the responder"); return
        }
        let renewWriter = BleConnection(peerId: centralId, initialMaxAttValueLength: 512)
        renewWriter.markReadyForTesting()
        let renewed = renewWriter.fragmentOutbound(recordType: .data, payload: sealedRenew)
        XCTAssertFalse(renewed.isEmpty)
        pushWrite(bob, pm, centralId: centralId, bytes: renewed[0])
        XCTAssertEqual(spy.received.count, 1, "the collector never stopped; the retry got through")
        XCTAssertEqual(spy.received.last?.data, payload)
        XCTAssertEqual(spy.received.last?.peerId, centralId)
        XCTAssertEqual(bob.rejectionRecordsForTest().count, 1, "no new event was raised")
        bob.stop()
    }

    // MARK: - required case 4: the release symbol inventory

    func testReleaseSymbolsCarryNoTestFactories() throws {
        // The shipping surface of the transport stack, enumerated through
        // the runtime's own inventory. Test seams are Swift-internal and
        // unexposed; had any been left public or @objc-visible, this scan
        // would name them. (The behavioural half of this card - the absent
        // plaintext fallback - is proven by the zero captures of cases 01
        // and 05, where every byte that reached the wire was sealed.)
        var scanned: [String] = []
        let classes: [AnyClass] = [BleTransport.self, BleConnection.self, SessionManager.self, MeshNode.self]
        for cls in classes {
            scanned += ReadinessT17Tests.enumerateSelectors(of: cls)
        }
        XCTAssertFalse(scanned.isEmpty, "the scan must see something")
        let lower = scanned.map { $0.lowercased() }
        XCTAssertFalse(lower.contains(where: { $0.contains("fortest") }),
                       "a test factory stands open on the shipping surface: " +
                       scanned.filter { $0.lowercased().contains("fortest") }.joined(separator: ", "))
        XCTAssertFalse(lower.contains(where: { $0.contains("fortesting") }),
                       "a test seam is exported: " +
                       scanned.filter { $0.lowercased().contains("fortesting") }.joined(separator: ", "))
        XCTAssertFalse(lower.contains(where: { $0.contains("dummy") }),
                       "the relocated dummy factory leaked back in: " +
                       scanned.filter { $0.lowercased().contains("dummy") }.joined(separator: ", "))
    }

    private static func enumerateSelectors(of cls: AnyClass) -> [String] {
        var names: [String] = []
        var count: UInt32 = 0
        if let methods = class_copyMethodList(cls, &count) {
            defer { free(UnsafeMutableRawPointer(methods)) }
            for i in 0..<Int(count) {
                names.append(NSStringFromSelector(method_getName(methods[i])) as String)
            }
        }
        if let props = class_copyPropertyList(cls, &count) {
            defer { free(UnsafeMutableRawPointer(props)) }
            for i in 0..<Int(count) {
                names.append(String(cString: property_getName(props[i])))
            }
        }
        return names
    }

    // MARK: - the chain: link-info, binding, handshake, slot, events

    func testTheWholeChainRunsThroughRealEntries() throws {
        let pair = try ReadinessTrustedPairing.barePair()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let aliceFactory = CaptureFactory()
        let bobFactory = CaptureFactory()
        let alice = BleTransport(identity: pair.aliceIdentity, store: T17MessageStore(), sessions: pair.aliceManager,
                                 managerFactory: aliceFactory, clock: TestClock(startingAt: 9_300))
        let bob = BleTransport(identity: pair.bobIdentity, store: nil, sessions: pair.bobManager,
                               managerFactory: bobFactory, clock: TestClock(startingAt: 9_300))
        let aliceSpy = T17DelegateSpy(); alice.delegate = aliceSpy
        let bobSpy = T17DelegateSpy(); bob.delegate = bobSpy
        let handleB = UUID()   // how alice names bob
        let handleA = UUID()   // how bob names alice
        let aliceHint = pair.aliceIdentity.nodeHint
        let bobHint = pair.bobIdentity.nodeHint

        // The initiator walks the real legs; no ready mark touches this path.
        let (_, capturePeer) = peripheralPunt(handleB)
        guard let aliceDelegate = advanceToRoleBound(alice, peerId: handleB, serviceDataHint: bobHint,
                                                     capturePeer: capturePeer) else {
            XCTFail("the initiator never reached the role bound"); return
        }
        XCTAssertEqual(alice.connection(for: handleB)?.state, .roleBound, "walk: " + walkLog.joined(separator: " | "))

        // The responder accepts the incoming link-info and the subscription.
        bob.start()
        let bobPM = bob.requireContextPeripheralForTest()
        let (boundChain, sawChain) = advanceToResponderBound(bob, pm: bobPM, centralId: handleA, remoteHint: aliceHint)
        XCTAssertTrue(boundChain, "the responder never bound its role: " + sawChain)
        XCTAssertEqual(bob.connection(for: handleA)?.state, .roleBound)

        // The handshake record writer takes over: message 1 out.
        XCTAssertEqual(alice.beginTrustedHandshake(peerId: handleB, remoteHint: bobHint), .admitted)
        guard let hs1 = capturePeer.writes.last, hs1.isEmpty == false else {
            XCTFail("message 1 never went out"); return
        }
        // message 2: the responder reads it and answers through the retained handle.
        pushWrite(bob, bobPM, centralId: handleA, bytes: hs1)
        guard let hs2 = firstCapture(of: bobFactory.peripheralManagers.last!, towards: handleA),
              hs2.isEmpty == false else {
            let ring = bob.rejectionRecordsForTest().map { $0.site + ":" + $0.reason }.joined(separator: ", ")
            XCTFail("message 2 never went out; bob's ring: [\(ring)]")
            return
        }
        // message 3: the initiator reads the answer and completes the exchange.
        let hs2Char = CBMutableCharacteristic(type: BleTransport.inboxCharacteristicUuid,
                                             properties: [.read, .write, .notify],
                                             value: hs2, permissions: [.readable, .writeable])
        _ = alice.processPeripheralUpdateValue(nil, delegate: aliceDelegate, characteristic: hs2Char, error: nil)
        guard let hs3 = capturePeer.writes.last, hs3.isEmpty == false, hs3 != hs1 else {
            XCTFail("message 3 never went out"); return
        }
        capturePeer.clearWrites()
        pushWrite(bob, bobPM, centralId: handleA, bytes: hs3)

        // Both slots reached the cryptographic ready through the driver alone.
        XCTAssertTrue(pair.aliceManager.isReady(handleB), "the initiator slot never opened")
        XCTAssertTrue(pair.bobManager.isReady(handleA), "the responder slot never opened")
        XCTAssertEqual(alice.connection(for: handleB)?.state, .ready)
        XCTAssertEqual(bob.connection(for: handleA)?.state, .ready)
        XCTAssertEqual(aliceSpy.handshakeReadyPeers, [handleB])
        XCTAssertEqual(bobSpy.handshakeReadyPeers, [handleA])

        // The payload flows authenticated end to end, sealed on the wire.
        let payload: [UInt8] = [1, 2, 3, 4]
        let plain = makeFrame(payload).encode()
        XCTAssertEqual(alice.send(makeFrame(payload), to: handleB), .admitted)
        guard let sealed = capturePeer.writes.last else {
            XCTFail("the sealed record never went out"); return
        }
        XCTAssertFalse(capturePeer.writes.count >= 3, "one sealed record, one fragment, one write")
        XCTAssertFalse(sealed == plain, "the wire carried the frame itself")
        XCTAssertFalse(containsBytes(sealed, plain), "the plaintext bytes are nowhere on the wire")
        XCTAssertGreaterThan(sealed.count, plain.count, "the seal adds the authentication tag")
        pushWrite(bob, bobPM, centralId: handleA, bytes: sealed)
        XCTAssertEqual(bobSpy.received.count, 1, "the responder never got the payload")
        // It is the frame that travels sealed: the open returns the frame's
        // encoding, the payload inside it intact.
        XCTAssertEqual(bobSpy.received.last?.data, plain, "the round trip authenticates the frame")
        XCTAssertTrue(containsBytes(bobSpy.received.last?.data ?? Data(), Data(payload)),
                      "the payload survives the cipher intact")
        XCTAssertEqual(bobSpy.received.last?.peerId, handleA)
        XCTAssertFalse(bobFactory.peripheralManagers.last!.respondedResults.contains { $0 != CBATTError.success },
                     "the ATT answers were not all successes")
        alice.stop(); bob.stop()
    }

    // MARK: - the reserved entrances refuse the shortcuts

    func testSealedReadyRequiresTrustedHandle() throws {
        // The state machine reserves ready, roleBound and handshakeInProgress
        // for the bind family and the driver; every shortcut is an error
        // return, never an abort, and the state stands where it was.
        let c = BleConnection(peerId: UUID(), initialMaxAttValueLength: 64)
        XCTAssertEqual(c.state, .provisionalConnecting)
        XCTAssertFalse(c.transitionTo(.ready), "ready is reserved for the driver")
        XCTAssertEqual(c.state, .provisionalConnecting, "the state stood where it was")
        XCTAssertFalse(c.transitionTo(.roleBound))
        XCTAssertFalse(c.beginHandshake(), "nothing is bound yet")

        XCTAssertTrue(c.transitionTo(.provisionalConnected))
        c.startLinkInfoRead()
        XCTAssertEqual(c.state, .linkInfoReading)
        XCTAssertTrue(c.transitionTo(.linkInfoWriting))
        XCTAssertEqual(c.state, .linkInfoWriting)
        XCTAssertFalse(c.bindInitiatorAfterLinkInfoWriteAck(remoteHint: Data([1, 2, 3])),
                       "a three-byte hint is the wrong size")
        XCTAssertEqual(c.state, .linkInfoWriting, "the wrong-size hint changed nothing")
        XCTAssertTrue(c.bindInitiatorAfterLinkInfoWriteAck(remoteHint: Data([1, 2, 3, 4])))
        XCTAssertEqual(c.state, .roleBound)

        XCTAssertFalse(c.beginHandshake(), "the duplex is not ready: no subscription")
        XCTAssertFalse(c.markTrustedReady(),
                       "the trusted door stays shut while the handshake has not begun")
        XCTAssertEqual(c.state, .roleBound, "the refusal preserved the stage")
        c.isNotificationSubscribed = true
        XCTAssertTrue(c.beginHandshake())
        XCTAssertEqual(c.state, .handshakeInProgress)
        XCTAssertFalse(c.bindResponderFromAcceptedIncomingLinkInfo(remoteHint: Data([9, 9, 9, 9])),
                       "the binding is one-way")
        XCTAssertTrue(c.markTrustedReady(), "the driver's entrance stands open")
        XCTAssertEqual(c.state, .ready)

        // A synthetic mark cannot reach the trusted half: a fresh
        // connection marked ready by the seam still fails both driver gates.
        let seam = BleConnection(peerId: UUID(), initialMaxAttValueLength: 64)
        XCTAssertTrue(seam.markReadyForTesting())
        XCTAssertEqual(seam.state, .ready)
        XCTAssertFalse(seam.beginHandshake(), "the seam does not open the driver's path")
        XCTAssertFalse(seam.markTrustedReady(), "the trusted ready needs the handshake phase")
    }

    func testBeginTrustedHandshakeNeedsAStandingRelation() throws {
        let pair = try ReadinessTrustedPairing.barePair()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let alice = BleTransport(identity: pair.aliceIdentity, store: nil, sessions: pair.aliceManager,
                                 managerFactory: CaptureFactory(), clock: TestClock(startingAt: 9_400))
        alice.start()
        XCTAssertEqual(alice.beginTrustedHandshake(peerId: UUID(), remoteHint: Data([1, 2, 3, 4])),
                       .rejected("no such connection"))
        let missing = try ReadinessTrustedPairing.makeIdentity(seedByte: 0x51, staticPrivByte: 0x52)
        XCTAssertEqual(alice.beginTrustedHandshake(peerId: UUID(), remoteHint: missing.nodeHint),
                       .rejected("no such connection"))
        alice.stop()
    }

    // MARK: - backpressure is reported, not silently dropped

    func testBackpressureIsReportedNotSilentlyDropped() throws {
        let pair = try ReadinessTrustedPairing.establish()   // both slots opened for business
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let aliceFactory = CaptureFactory()
        let peerId = pair.viaBob
        let alice = BleTransport(identity: pair.aliceIdentity, store: T17MessageStore(), sessions: pair.aliceManager,
                                  managerFactory: aliceFactory, clock: TestClock(startingAt: 9_500))
        let (_, capturePeer) = peripheralPunt(peerId)
        capturePeer.canSendWriteWithoutResponse = false   // the channel is closed
        _ = advanceToRoleBound(alice, peerId: peerId, serviceDataHint: ReadinessT17Tests.greaterHint(than: pair.aliceIdentity.nodeHint),
                               capturePeer: capturePeer)
        alice.connection(for: peerId)?.markReadyForTesting()

        var verdicts: [TransportResult] = []
        var bytesQueued = 0
        for i in 0..<260 {
            let verdict = alice.send(makeFrame([UInt8(i % 251) + 4]), to: peerId)
            _ = walk("send \(i) -> " + String(describing: verdict))
            verdicts.append(verdict)
            if case .backpressured = verdict { break }
        }
        let firstBackpressure = verdicts.firstIndex(where: { $0 == .backpressured })
        guard let first = firstBackpressure else {
            let seen = Set(verdicts.map { String(describing: $0) }).sorted().joined(separator: ", ")
            XCTFail("an unbounded queue never reports its full; verdicts seen: \(seen)")
            return
        }
        // T19: under the window law the verdict follows the leg. With the
        // channel closed the very first send may report backpressure while
        // its value waits in the staging for the ready report; the event is
        // raised and nothing is silently dropped. The case was written
        // against the old queue's counting, where a few sends were admitted
        // before the full was reached; the same truths are now told through
        // the direction's writer, which must still hold what was committed.
        for v in verdicts[0..<first] { XCTAssertEqual(v, .admitted) }
        XCTAssertTrue(capturePeer.writes.isEmpty,
                      "while the channel is closed nothing may go out through the back door")
        let writer = alice.centralWriterForTest(peerId)
        XCTAssertNotNil(writer, "the committed records stand in the direction's writer")
        XCTAssertGreaterThan(writer?.stagedValues() ?? 0, 0,
                             "the closed leg holds its values; none is dropped")
        XCTAssertTrue(alice.rejectionRecordsForTest().contains(where: { $0.site == "send.initiator" && $0.reason == "queue full" }),
                      "the full queue must raise its event")
        alice.stop()
    }

    // MARK: - the unexpected stage answers typed and bounded

    func testUnexpectedStageIsTypedAndBounded() throws {
        let pair = try ReadinessTrustedPairing.barePair()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let bobFactory = CaptureFactory()
        let bob = BleTransport(identity: pair.bobIdentity, store: nil, sessions: pair.bobManager,
                               managerFactory: bobFactory, clock: TestClock(startingAt: 9_600))
        let spy = T17DelegateSpy()
        bob.delegate = spy
        bob.start()
        let pm = bob.requireContextPeripheralForTest()
        let centralId = UUID()
        let (bound8, saw8) = advanceToResponderBound(bob, pm: pm, centralId: centralId,
                                                   remoteHint: ReadinessT17Tests.lesserHint(than: pair.bobIdentity.nodeHint))
        XCTAssertTrue(bound8, "the responder never bound its role: " + saw8)
        // The connection stays at roleBound - no ready mark - while DATA
        // records are pushed at it: the reader must answer each with the
        // typed stage rejection, never an abort through the callback.
        // One writer for the whole case: the deframer deduplicates by the
        // record's sequence, so a fresh writer would restart the count and
        // its records would be consumed as repeats.
        let writer = BleConnection(peerId: centralId, initialMaxAttValueLength: 20)
        writer.markReadyForTesting()
        let one = writer.fragmentOutbound(recordType: .data, payload: Data([4, 5, 6]))
        let two = writer.fragmentOutbound(recordType: .data, payload: Data([5, 6, 7]))
        XCTAssertFalse(one.isEmpty); XCTAssertFalse(two.isEmpty)

        pushWrite(bob, pm, centralId: centralId, bytes: one[0])
        pushWrite(bob, pm, centralId: centralId, bytes: two[0])
        var events = bob.rejectionRecordsForTest()
        XCTAssertEqual(events.count, 2, "each bad record raises exactly one event")
        XCTAssertEqual(events.last?.site, "ingest.write")
        XCTAssertTrue(events.last?.reason.contains("stage") ?? false,
                      "the event must name the stage: " + (events.last?.reason ?? "nil"))
        XCTAssertTrue(events.last?.reason.contains("expected") ?? false)
        XCTAssertTrue(spy.received.isEmpty, "nothing was delivered")

        // Now the physical mark goes up. An incomplete record is in flight,
        // not a failure: the reassembler waits, the ring stands still.
        guard let serverConn = bob.connection(for: centralId) else {
            XCTFail("the inbound connection vanished before the mark - centralId " + centralId.uuidString)
            return
        }
        XCTAssertTrue(serverConn.markReadyForTesting(), "the seam refused the mark")
        XCTAssertEqual(serverConn.state, .ready, "the mark did not stick")
        let twin = writer.fragmentOutbound(recordType: .data, payload: Data(repeating: 0x33, count: 80))
        XCTAssertGreaterThan(twin.count, 1, "the payload must span fragments")
        pushWrite(bob, pm, centralId: centralId, bytes: twin[0])
        XCTAssertEqual(bob.rejectionRecordsForTest().count, events.count,
                       "pending reassembly is silent, not a rejection")
        for k in 1..<(twin.count - 1) { pushWrite(bob, pm, centralId: centralId, bytes: twin[k]) }

        // The second fragment completes it: admitted by the gates, and the
        // only failure left standing is the cryptographic one.
        pushWrite(bob, pm, centralId: centralId, bytes: twin[twin.count - 1])
        events = bob.rejectionRecordsForTest()
        XCTAssertEqual(events.count, 3,
                       "one fresh event for the completion; ring: " +
                       events.map { $0.site + "|" + $0.reason }.joined(separator: ", ") +
                       " state now " + String(describing: serverConn.state))
        XCTAssertEqual(events.last?.site, "open.write")
        XCTAssertEqual(events.last?.reason, "unauthenticated payload")
        XCTAssertTrue(spy.received.isEmpty)

        // Trust up through the real entries, and a fresh record is delivered:
        // the collector never stopped.
        try ReadinessTrustedPairing.pairUp(pair, viaBob: centralId, viaAlice: centralId,
                                           aliceHint: pair.aliceIdentity.nodeHint,
                                           bobHint: pair.bobIdentity.nodeHint)
        guard let sealedFinal = pair.aliceManager.seal(centralId, Data([6, 6])) else {
            XCTFail("the initiator could not seal towards the responder"); return
        }
        let finalWriter = BleConnection(peerId: centralId, initialMaxAttValueLength: 512)
        finalWriter.markReadyForTesting()
        let finalRecord = finalWriter.fragmentOutbound(recordType: .data, payload: sealedFinal)
        XCTAssertFalse(finalRecord.isEmpty)
        pushWrite(bob, pm, centralId: centralId, bytes: finalRecord[0])
        XCTAssertEqual(spy.received.count, 1, "the record arrived after the trust, the loop held")
        XCTAssertEqual(spy.received.last?.data, Data([6, 6]))
        bob.stop()
    }
}
