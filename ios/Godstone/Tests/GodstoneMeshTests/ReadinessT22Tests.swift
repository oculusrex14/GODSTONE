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
final class ReadinessT22Tests: XCTestCase {

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
                ReadinessT22Tests.remoteLinkInfoStatic(hint: serviceDataHint)]
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
                                                          service: ReadinessT22Tests.provisionedService(), error: nil)
        walkLog.append("characteristics -> " + String(describing: a2) + " @ " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let linkInfoChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: ReadinessT22Tests.remoteLinkInfoStatic(hint: serviceDataHint),
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
                                        rawData: ReadinessT22Tests.remoteLinkInfoStatic(hint: remoteHint),
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
            if ReadinessT22Tests.hintAscending(c, local) { return c }
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
            if ReadinessT22Tests.hintAscending(local, c) { return c }
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

    // ---------------------------------------------------------------- T21
    //
    // The trusted initiator upon the record path, island dialect. Every
    // case traces actual adapter input through the doors; every refusal
    // names itself in the ring; the relations that fall, fall exactly, and
    // the session slot perishes with them.

    private func typeOfByte(_ v: Data) -> Int { Int(v[1]) }
    private func payloadOf(_ v: Data) -> Data { Data(v.dropFirst(8)) }
    private func fragCountOf(_ value: Data) -> Int { Int(value[4]) }
    private func clearOf(_ marker: Int, _ len: Int) -> [UInt8] {
        return (0..<len).map { i in
            if i == 0 { return UInt8(marker & 0xFF) }
            if i == 1 { return UInt8((marker >> 8) & 0xFF) }
            return UInt8((i &* 7 &+ 13 &+ marker) % 251)
        }
    }

    private struct T22Rig {
        let pair: ReadinessTrustedPairing.Pair
        let alice: BleTransport
        let bob: BleTransport
        let aliceSpy: T17DelegateSpy
        let bobSpy: T17DelegateSpy
        let capturePeer: CapturePeripheral
        let aliceFactory: CaptureFactory
        let bobFactory: CaptureFactory
        let handleA: UUID
        let handleB: UUID
        let aliceDelegate: RelationPeripheralDelegate
        let bobPM: CBPeripheralManager
    }

    private func rigT22() throws -> T22Rig {
        let pair = try ReadinessTrustedPairing.barePair()
        let handleB = UUID()
        let handleA = UUID()
        let aliceFactory = CaptureFactory()
        let bobFactory = CaptureFactory()
        let alice = BleTransport(identity: pair.aliceIdentity, store: T22MessageStore(),
                                 sessions: pair.aliceManager,
                                 managerFactory: aliceFactory, clock: TestClock(startingAt: 9_300))
        let bob = BleTransport(identity: pair.bobIdentity, store: nil, sessions: pair.bobManager,
                               managerFactory: bobFactory, clock: TestClock(startingAt: 9_300))
        let aliceSpy = T17DelegateSpy(); alice.delegate = aliceSpy
        let bobSpy = T17DelegateSpy(); bob.delegate = bobSpy
        let (_, capturePeer) = peripheralPunt(handleB)
        guard let aliceDelegate = advanceToRoleBound(alice, peerId: handleB,
                                                    serviceDataHint: pair.bobIdentity.nodeHint,
                                                    capturePeer: capturePeer) else {
            throw NSError(domain: "t22", code: 1, userInfo: [NSLocalizedDescriptionKey: "the initiator never bound"])
        }
        bob.start()
        let bobPM = bob.requireContextPeripheralForTest()
        let (bound, saw) = advanceToResponderBound(bob, pm: bobPM, centralId: handleA,
                                                   remoteHint: pair.aliceIdentity.nodeHint)
        guard bound else {
            throw NSError(domain: "t22", code: 2, userInfo: [NSLocalizedDescriptionKey: "the responder never bound: " + saw])
        }
        return T22Rig(pair: pair, alice: alice, bob: bob, aliceSpy: aliceSpy, bobSpy: bobSpy,
                      capturePeer: capturePeer, aliceFactory: aliceFactory, bobFactory: bobFactory,
                      handleA: handleA, handleB: handleB,
                      aliceDelegate: aliceDelegate, bobPM: bobPM)
    }

    private func pushToInitiator(_ alice: BleTransport, _ delegate: RelationPeripheralDelegate,
                                 _ bytes: Data) {
        let ch = CBMutableCharacteristic(type: BleTransport.inboxCharacteristicUuid,
                                        properties: [.read, .write, .notify],
                                        value: bytes, permissions: [.readable, .writeable])
        _ = alice.processPeripheralUpdateValue(nil, delegate: delegate, characteristic: ch, error: nil)
    }

    private func beginWith(_ r: T22Rig, _ hint: Data) -> TransportResult {
        r.alice.beginTrustedHandshake(peerId: r.handleB, remoteHint: hint)
    }

    private func capturedHS2(_ r: T22Rig) -> Data? {
        guard let mgr = r.bobFactory.peripheralManagers.last else { return nil }
        return firstCapture(of: mgr, towards: r.handleA)
    }

    /** Drives the exchange step by step, asserting the passage at every
     *  door, and brings the pair to the trusted READY. The HS2 fragments
     *  as they travelled are handed back for the trials that reuse them. */
    private func driveToReady(_ r: T22Rig) throws -> Data? {
        r.capturePeer.clearWrites()
        XCTAssertEqual(beginWith(r, r.pair.bobIdentity.nodeHint), .admitted,
                       "the begin must stand upon the witnessed duplex; ring: " + ringOf(r.alice))
        guard let hs1 = waitWhile({ r.capturePeer.writes.last }, nonEmpty: true) else {
            XCTFail("the HS1 never came forth; ring: " + ringOf(r.alice)); return nil
        }
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: hs1)
        guard let hs2 = waitWhile({ capturedHS2(r) }, nonEmpty: true) else {
            XCTFail("the HS2 never answered; ring: " + ringOf(r.bob)); return nil
        }
        let priorCount = r.capturePeer.writes.count
        pushToInitiator(r.alice, r.aliceDelegate, hs2)
        var hs3: Data? = nil
        for _ in 0..<800 {
            let w = r.capturePeer.writes
            if w.count > priorCount, let last = w.last, last != hs1 { hs3 = last; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard let hs3 = hs3 else {
            XCTFail("the HS3 never went out; ring: " + ringOf(r.alice)); return nil
        }
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: hs3)
        XCTAssertTrue(waitUntil2 { r.pair.aliceManager.isReady(r.handleB) && r.pair.bobManager.isReady(r.handleA) })
        XCTAssertTrue(waitUntil2 { (r.alice.connection(for: r.handleB)?.state == .ready) &&
                                  (r.bob.connection(for: r.handleA)?.state == .ready) })
        return hs2
    }

    private func ringOf(_ t: BleTransport) -> String {
        t.rejectionRecordsForTest().map { $0.site + "|" + $0.reason }.joined(separator: ", ")
    }
    private func waitWhile(_ sample: () -> Data?, nonEmpty: Bool) -> Data? {
        for _ in 0..<400 {
            let v = sample()
            if let v = v, (v.isEmpty == false) == nonEmpty { return v }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return sample()
    }
    private func waitUntil2(_ predicate: () -> Bool) -> Bool {
        for _ in 0..<800 {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }

    // MARK: - the initiators door

    // ---------------------------------------------------------------- T22
    //
    // The trusted responder upon the record path, island dialect. After
    // ROLE_BOUND the door keepeth its stage, its direction, and its verdict:
    // exactly the expected first counsel is accepted; the second is queued
    // by the writers hand and its verdict heard; the third alone, opened
    // through the registry and proved by the binder, installeth a usable
    // session. Every refusal ringeth its reason in the collector and the
    // exact relation perisheth with its slot. Trust is never inferred from
    // the subscription that the ladders brought.

    private struct DenyingT22Authority: PeerBindingTrustAuthority, @unchecked Sendable {
        let reason: PeerTrustRejectReason
        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            return .rejected(reason)
        }
    }

    private func t22TempDb(_ name: String) -> URL {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("t22_pair_" + name + "_" + UUID().uuidString + ".db")
    }

    private func forgeT22(_ type: BleRecordType, _ seq: UInt8, _ payload: Data) -> Data {
        return try! BleRecordFragmenter.fragment(recordType: type, recordSeq: seq,
                                                 payload: payload, maxAttValueLength: 247).first!
    }

    private func t22Hs1(_ r: T22Rig) -> Data? {
        return r.pair.aliceManager.beginInitiator(r.handleB, remoteHint: r.pair.bobIdentity.nodeHint)
    }

    /** Begynneth the exchange by the transports own entry (so the initiators
     *  state advanceth to handshakeInProgress, as the law requireth), pusheth
     *  the authentic first counsel and awaiteth the queued answer. */
    private func driveToAnswered(_ r: T22Rig) throws -> (Data, Data)? {
        r.capturePeer.clearWrites()
        XCTAssertEqual(beginWith(r, r.pair.bobIdentity.nodeHint), .admitted,
                       "the begin must stand upon the witnessed duplex; ring: " + ringOf(r.alice))
        guard let hs1 = waitWhile({ r.capturePeer.writes.last }, nonEmpty: true) else {
            XCTFail("the HS1 never came forth; ring: " + ringOf(r.alice)); return nil
        }
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: hs1)
        guard let hs2 = waitWhile({ capturedHS2(r) }, nonEmpty: true) else {
            XCTFail("the HS2 never answered; ring: " + ringOf(r.bob)); return nil
        }
        return (hs1, hs2)
    }

    /** The third as it travelled from the initiators side, by the growth of
     *  the capture peripheral own writes (the elder recipe: baseline BEFORE
     *  the push, the type octet as the true filter). */
    private func harvestThird(_ r: T22Rig, afterPushToInitiator hs2: Data, against hs1: Data) -> Data? {
        let prior = r.capturePeer.writes.count
        pushToInitiator(r.alice, r.aliceDelegate, hs2)
        for _ in 0..<800 {
            let w = r.capturePeer.writes
            if w.count > prior, let last = w.last, last != hs1 {
                return last
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    // MARK: - the answer and its government

    func testTheResponderAnswerethTheExpectedFirstWithTheQueuedSecond() throws {
        let r = try rigT22()
        guard let (_, hs2) = try driveToAnswered(r) else { return }
        XCTAssertEqual(typeOfByte(hs2), 0x12, "the answer must be of the second form")
        XCTAssertEqual(payloadOf(hs2).count, 229, "the second counsel beareth two hundred twenty-nine octets")
        XCTAssertEqual(r.bob.connection(for: r.handleA)?.state, .handshakeInProgress,
                       "the responder must stand mid the handshake")
        XCTAssertFalse(r.pair.bobManager.isReady(r.handleA), "the second maketh no trusted session")
        XCTAssertFalse(r.bobSpy.handshakeReadyPeers.contains(r.handleA),
                       "no announcement may precede the third")
        XCTAssertTrue(!ringOf(r.bob).contains("hs1 rejected"),
                      "the true first must be accepted; ring: " + ringOf(r.bob))
    }

    func testTheResponderIsNotTrustedByTheFirstNorTheSecondAloneAndNoDATARidesTheStream() throws {
        let r = try rigT22()
        guard let (_, hs2) = try driveToAnswered(r) else { return }
        XCTAssertEqual(r.bob.connection(for: r.handleA)?.state, .handshakeInProgress)
        XCTAssertFalse(r.pair.bobManager.isReady(r.handleA), "the first and second alone make no trust")
        XCTAssertFalse(r.bobSpy.handshakeReadyPeers.contains(r.handleA))
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: forgeT22(.data, 9, Data(clearOf(411, 120))))
        XCTAssertTrue(waitUntil2 { ringOf(r.bob).contains("at stage") },
                      "the gate must ring the bounded refusal; ring: " + ringOf(r.bob))
        XCTAssertNotNil(r.bob.connection(for: r.handleA), "the bounded refusal slayeth not the relation")
        XCTAssertEqual(r.bob.connection(for: r.handleA)?.state, .handshakeInProgress,
                       "the relation abideth mid the handshake")
        XCTAssertFalse(r.bobSpy.received.contains { $0.peerId == r.handleA },
                       "no application stream may ride the untrusted hour")
    }

    // MARK: - the refusals and their exact falls

    func testTheTamperedThirdPerishethTheRelationExactly() throws {
        // the responder weigheth the seal at the third, not at the first:
        // the first passeth the gate by its shape alone; the binding and
        // the static key are proved when the third is opened
        let r = try rigT22()
        guard let (hs1, hs2) = try driveToAnswered(r) else { return }
        guard let third = harvestThird(r, afterPushToInitiator: hs2, against: hs1) else {
            XCTFail("the third never came forth; ring: " + ringOf(r.alice)); return
        }
        var tampered = payloadOf(third)
        tampered[tampered.count / 2] ^= 0x5A
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: forgeT22(.hs3, third[2], tampered))
        XCTAssertTrue(waitUntil2 { ringOf(r.bob).contains("hs3 rejected") },
                      "the false seal must be refused; ring: " + ringOf(r.bob))
        XCTAssertTrue(waitUntil2 { r.bob.connection(for: r.handleA) == nil },
                      "the relation must perish with the refusal")
        XCTAssertNil(r.pair.bobManager.slotForTest(r.handleA), "the slot must perish with the relation")
        XCTAssertFalse(r.pair.bobManager.isReady(r.handleA), "no session of a refused counsel")
    }

    func testTheSecondSpokenAtTheRespondersGateIsAConflictingSequence() throws {
        let r = try rigT22()
        guard let hs2 = try driveToReady(r) else { return }
        XCTAssertTrue(r.pair.bobManager.isReady(r.handleA), "the exchange must have trusted the pair")
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: forgeT22(.hs2, 0x3F, payloadOf(hs2)))
        XCTAssertTrue(waitUntil2 { ringOf(r.bob).contains("at stage") },
                      "the own voice come again must be refused; ring: " + ringOf(r.bob))
        XCTAssertTrue(waitUntil2 { r.bob.connection(for: r.handleA) == nil },
                      "the exact relation must fall upon the stranger")
        XCTAssertNil(r.pair.bobManager.slotForTest(r.handleA), "and the slot with it")
        XCTAssertEqual(r.alice.connection(for: r.handleB)?.state, .ready,
                       "the fall is of the responders side alone")
    }

    func testTheThirdRecordBeforeTheFirstIsRefusedAndTheRelationFalleth() throws {
        let r = try rigT22()
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: forgeT22(.hs3, 7, Data(clearOf(99, 197))))
        XCTAssertTrue(waitUntil2 { ringOf(r.bob).contains("hs3 at stage") },
                      "the third before the first must be refused; ring: " + ringOf(r.bob))
        XCTAssertTrue(waitUntil2 { r.bob.connection(for: r.handleA) == nil },
                      "the out of order counsel felleth the relation")
        XCTAssertNil(r.pair.bobManager.slotForTest(r.handleA), "and the slot with it")
    }

    func testTheDuplicateFirstMessageInHandPerishethTheRelation() throws {
        let r = try rigT22()
        guard let (hs1Frag, _) = try driveToAnswered(r) else { return }
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: forgeT22(.hs1, 1, payloadOf(hs1Frag)))
        XCTAssertTrue(waitUntil2 { ringOf(r.bob).contains("hs1 at stage") },
                      "the duplicate in hand must be refused; ring: " + ringOf(r.bob))
        XCTAssertTrue(waitUntil2 { r.bob.connection(for: r.handleA) == nil },
                      "the duplicate felleth the relation")
        XCTAssertNil(r.pair.bobManager.slotForTest(r.handleA), "and the slot with it")
        guard let mgr = r.bobFactory.peripheralManagers.last else { XCTFail("no responder manager"); return }
        XCTAssertEqual(mgr.capturedUpdates.filter { $0.central == r.handleA && $0.bytes.count > 1
            && Int($0.bytes[1]) == 0x12 }.count, 1, "but one answer ever travelled the outlet")
    }

    func testTheLateFirstMessageAfterTheTrustClosethTheRelationExactly() throws {
        let r = try rigT22()
        guard let _ = try driveToReady(r) else { return }
        XCTAssertTrue(r.pair.bobManager.isReady(r.handleA), "the pair must stand trusted before the trial")
        let alien = try ReadinessTrustedPairing.barePair(seedA: 0x51, seedB: 0x73)
        guard let alienHs1 = alien.aliceManager.beginInitiator(UUID(), remoteHint: alien.bobIdentity.nodeHint)
        else { XCTFail("an alien first counsel must be formable for the trial"); return }
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: forgeT22(.hs1, 0x2C, alienHs1))
        XCTAssertTrue(waitUntil2 { ringOf(r.bob).contains("hs1 at stage") },
                      "the late first must be refused; ring: " + ringOf(r.bob))
        XCTAssertTrue(waitUntil2 { r.bob.connection(for: r.handleA) == nil },
                      "the late counsel felleth the relation")
        XCTAssertFalse(r.pair.bobManager.isReady(r.handleA), "and the session with it")
        XCTAssertEqual(r.alice.connection(for: r.handleB)?.state, .ready,
                       "the fall is exact, one side alone")
    }

    func testTheResponderHearkentheVerdictOfTheQueuedSecond() throws {
        let r = try rigT22Flooded()
        guard let hs1 = t22Hs1(r) else { XCTFail("the first counsel could not be formed"); return }
        // the leg is flooded: the answer can not be staged, the writers verdict
        // must reach the door and the relation must fall upon it
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: forgeT22(.hs1, 0, hs1))
        if !waitUntil2({ ringOf(r.bob).contains("hs2 reservation refused") }) {
            XCTFail("the refused reservation must ring at the door; ring(after): " + ringOf(r.bob)
                    + " state: " + (r.bob.connection(for: r.handleA).map { String(describing: $0.state) } ?? "nil"))
        }
        XCTAssertTrue(ringOf(r.bob).contains("hs.write.responder"),
                      "the writer must tell its own tale; ring(after): " + ringOf(r.bob))
        if !waitUntil2({ r.bob.connection(for: r.handleA) == nil }) {
            XCTFail("the relation must perish upon the refused verdict; ring(after): " + ringOf(r.bob)
                    + " state: " + (r.bob.connection(for: r.handleA).map { String(describing: $0.state) } ?? "nil"))
        }
        XCTAssertNil(r.pair.bobManager.slotForTest(r.handleA), "and the slot perish with it")
        XCTAssertFalse(r.pair.bobManager.isReady(r.handleA), "no ready hour from a refused reservation")
        XCTAssertFalse(r.bobSpy.handshakeReadyPeers.contains(r.handleA),
                       "no announcement may rise from a refused reservation")
    }

    // MARK: - the seal, the size, and the bound remembrance

    func testThePublicShapeAdmittethTheAlienSealDenieth() throws {
        // the discovery field is public and serveth the gate: a first
        // counsel of another pairing, of the right shape, is ANSWERED. The
        // authenticated field is separate: when the alien third is opened,
        // the binder of the responder proveth the static key against its
        // own remembrance, findeth it other, and casteth the relation out
        let r = try rigT22()
        let alienA = try rigT22()
        guard let alienHs1 = t22Hs1(alienA) else { XCTFail("the alien first counsel must be formable"); return }
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: forgeT22(.hs1, 0, alienHs1))
        guard let answered = waitWhile({ capturedHS2(r) }, nonEmpty: true) else {
            XCTFail("the alien shape must be answered; ring: " + ringOf(r.bob)); return
        }
        XCTAssertEqual(typeOfByte(answered), 0x12, "the answer beareth the second form")
        XCTAssertNotNil(r.bob.connection(for: r.handleA), "the shape alone may not slay the relation")
        let alienB = try rigT22()
        guard let _ = try driveToReady(alienB) else { XCTFail("the alien exchange must complete"); return }
        guard let thirdFrag = alienB.capturePeer.writes.first(where: { $0.count > 2 && Int($0[1]) == 0x14 })
        else { XCTFail("the alien third must have travelled"); return }
        let alienThird = payloadOf(thirdFrag)
        XCTAssertEqual(alienThird.count, 197, "the alien third beareth the authentic length")
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: forgeT22(.hs3, 9, alienThird))
        XCTAssertTrue(waitUntil2 { ringOf(r.bob).contains("hs3 rejected") },
                      "the alien seal must be refused at the third; ring: " + ringOf(r.bob))
        XCTAssertTrue(waitUntil2 { r.bob.connection(for: r.handleA) == nil },
                      "the alien seal felleth the relation")
        XCTAssertNil(r.pair.bobManager.slotForTest(r.handleA), "and the slot with it")
        XCTAssertFalse(r.pair.bobManager.isReady(r.handleA), "no session was ever installed")
    }

    func testTheWrongSizedRecordsAreRefusedAndTheTruthPreserved() throws {
        let rA = try rigT22()
        pushWrite(rA.bob, rA.bobPM, centralId: rA.handleA, bytes: forgeT22(.hs1, 0, Data(clearOf(616, 24))))
        XCTAssertTrue(waitUntil2 { ringOf(rA.bob).contains("hs1 rejected") },
                      "the stunted first must be refused; ring: " + ringOf(rA.bob))
        XCTAssertTrue(waitUntil2 { rA.bob.connection(for: rA.handleA) == nil },
                      "the stunted counsel felleth the relation")
        XCTAssertNil(rA.pair.bobManager.slotForTest(rA.handleA), "and the slot with it")
        let rB = try rigT22()
        guard let (_, _) = try driveToAnswered(rB) else { return }
        pushWrite(rB.bob, rB.bobPM, centralId: rB.handleA, bytes: forgeT22(.hs3, 3, Data(clearOf(5, 120))))
        XCTAssertTrue(waitUntil2 { ringOf(rB.bob).contains("hs3 rejected") },
                      "the stunted third must be refused; ring: " + ringOf(rB.bob))
        XCTAssertTrue(waitUntil2 { rB.bob.connection(for: rB.handleA) == nil },
                      "the stunted third felleth the relation")
        XCTAssertNil(rB.pair.bobManager.slotForTest(rB.handleA), "and the slot with it")
    }

    func testTheRejectedAndRevokedBindingsPerishTheRelationAtTheThirdCounsel() throws {
        for reason in [PeerTrustRejectReason.revoked, .rollback] {
            let r = try rigT22Denying(reason: reason)
            guard let (hs1, hs2) = try driveToAnswered(r) else { return }
            // the ladders rose and the subscriptions came, yet the trust is
            // not inferred therefrom: the binder consulteth the authority at
            // the third, and is denied
            guard let third = harvestThird(r, afterPushToInitiator: hs2, against: hs1) else {
                XCTFail("the third must come forth; ring: " + ringOf(r.alice)); return
            }
            pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: third)
            XCTAssertTrue(waitUntil2 { ringOf(r.bob).contains("hs3 rejected") },
                          "the denied binding must refuse the seal; ring: " + ringOf(r.bob))
            XCTAssertTrue(waitUntil2 { r.bob.connection(for: r.handleA) == nil },
                          "the denied binding felleth the relation")
            XCTAssertNil(r.pair.bobManager.slotForTest(r.handleA), "and the slot with it")
            XCTAssertFalse(r.pair.bobManager.isReady(r.handleA), "no session of a denied binding")
            XCTAssertFalse(r.bobSpy.handshakeReadyPeers.contains(r.handleA),
                          "no announcement may rise from a denied binding")
        }
    }

    func testTheResponderPublishethNoughtTillTheThirdIsTrusted() throws {
        let r = try rigT22()
        let ledger0 = r.bob.publishedRelationsForTest().count
        guard let _ = try driveToReady(r) else { return }
        XCTAssertEqual(r.bob.publishedRelationsForTest().count, ledger0,
                       "the third alone publisheth no link-ready relation")
        XCTAssertTrue(waitUntil2 { r.bobSpy.handshakeReadyPeers == [r.handleA] },
                      "the announcement must have reached the peers")
        // the positive control upon the selfsame ledger: withdraw, then
        // re-enlist, that the census may be seen to move
        let keys = r.bob.publishedRelationsForTest().filter { $0.peerId == r.handleA }
        XCTAssertTrue(keys.count <= 1, "the ledger keepeth one entrance per peer")
        if let key = keys.first {
            XCTAssertTrue(r.bob.unpublishRelation(key), "the hand of the owner muft withdraw")
            XCTAssertEqual(r.bob.publishedRelationsForTest().count, ledger0 - 1, "the census must see the wering")
            XCTAssertTrue(r.bob.publishRelation(key), "and the hand muft re-enlist")
            XCTAssertEqual(r.bob.publishedRelationsForTest().count, ledger0, "the census must see the rest")
        } else {
            let gen = r.bob.peripheralDriver?.getCentralGeneration(r.handleA) ?? 0
            XCTAssertTrue(r.bob.publishRelation(RelationKey(direction: .inboundPeripheral,
                                                           peerId: r.handleA, generation: gen)),
                          "the hand-standing enrolment must be listed")
            XCTAssertEqual(r.bob.publishedRelationsForTest().count, ledger0 + 1,
                          "the census must see the one enrolment")
        }
    }

    func testTheThirdSpokenAgainAfterTheTrustIsAConflictingSequence() throws {
        let r = try rigT22()
        guard let (hs1, hs2) = try driveToAnswered(r) else { return }
        guard let third = harvestThird(r, afterPushToInitiator: hs2, against: hs1) else {
            XCTFail("the third must come forth; ring: " + ringOf(r.alice)); return
        }
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: third)
        XCTAssertTrue(waitUntil2 { r.pair.bobManager.isReady(r.handleA) }, "the pair must stand trusted")
        // the selfsame counsel again, with a fresh sequence: the stage is
        // spent, the record is late - the exact relation falleth
        pushWrite(r.bob, r.bobPM, centralId: r.handleA,
                  bytes: forgeT22(.hs3, third[2] &+ 7, payloadOf(third)))
        XCTAssertTrue(waitUntil2 { ringOf(r.bob).contains("hs3 at stage") },
                      "the third again must be refused; ring: " + ringOf(r.bob))
        XCTAssertTrue(waitUntil2 { r.bob.connection(for: r.handleA) == nil },
                      "the late third felleth the relation")
        XCTAssertNil(r.pair.bobManager.slotForTest(r.handleA), "and the slot with it")
        XCTAssertEqual(r.alice.connection(for: r.handleB)?.state, .ready, "the initiators relation yet standeth")
    }

    private func t22BarePair(seedA: UInt8 = 0x11, privA: UInt8 = 0x22,
                         seedB: UInt8 = 0x33, privB: UInt8 = 0x44,
                         denyReason reason: PeerTrustRejectReason? = nil) throws
                         -> ReadinessTrustedPairing.Pair {
        // The election elects the lexicographically smaller node hint as the
        // initiator, so the pair must be seeded with the digests pointing the
        // right way: alice below bob. Search forward from the requested seed.
        var aliceIdentity = try ReadinessTrustedPairing.makeIdentity(seedByte: seedA, staticPrivByte: privA)
        var bobIdentity = try ReadinessTrustedPairing.makeIdentity(seedByte: seedB, staticPrivByte: privB)
        var candidate = seedA
        while ReadinessTrustedPairing.hintOrder(aliceIdentity.nodeHint, bobIdentity.nodeHint) != .orderedAscending {
            candidate += 1
            if candidate == 0 { throw NSError(domain: "t22", code: 7, userInfo: [NSLocalizedDescriptionKey: "the seed is exhausted"]) }
            aliceIdentity = try ReadinessTrustedPairing.makeIdentity(seedByte: candidate, staticPrivByte: privA)
        }
        if ReadinessTrustedPairing.hintOrder(aliceIdentity.nodeHint, bobIdentity.nodeHint) != .orderedAscending {
            throw NSError(domain: "t22", code: 7, userInfo: [NSLocalizedDescriptionKey: "the seed is exhausted"])
        }
        let urlA = t22TempDb("a")
        let urlB = t22TempDb("b")
        let storeA = try SqlitePeerIdentityStore(url: urlA)
        let storeB = try SqlitePeerIdentityStore(url: urlB)
        let repoA = PeerIdentityRepository(store: storeA)
        let repoB = PeerIdentityRepository(store: storeB)
        let aliceManager = SessionManager(identity: aliceIdentity,
                                          trustAuthority: RepositoryPeerBindingTrustAuthority(repository: repoA))
        let bobTrust: any PeerBindingTrustAuthority
        if let reason = reason {
            bobTrust = DenyingT22Authority(reason: reason)
        } else {
            bobTrust = RepositoryPeerBindingTrustAuthority(repository: repoB)
        }
        let bobManager = SessionManager(identity: bobIdentity, trustAuthority: bobTrust)
        return ReadinessTrustedPairing.Pair(aliceIdentity: aliceIdentity, bobIdentity: bobIdentity,
                    aliceManager: aliceManager, bobManager: bobManager,
                    viaBob: UUID(), viaAlice: UUID(), urls: [urlA, urlB])
    }

    private func rigT22Flooded() throws -> T22Rig {
        let pair = try ReadinessTrustedPairing.barePair()
        let handleB = UUID()
        let handleA = UUID()
        let aliceFactory = CaptureFactory()
        let bobFactory = CaptureFactory()
        let alice = BleTransport(identity: pair.aliceIdentity, store: T22MessageStore(),
                                 sessions: pair.aliceManager,
                                 managerFactory: aliceFactory, clock: TestClock(startingAt: 9_300))
        let bob = BleTransport(identity: pair.bobIdentity, store: nil, sessions: pair.bobManager,
                               managerFactory: bobFactory, clock: TestClock(startingAt: 9_300))
        let aliceSpy = T17DelegateSpy(); alice.delegate = aliceSpy
        let bobSpy = T17DelegateSpy(); bob.delegate = bobSpy
        let (_, capturePeer) = peripheralPunt(handleB)
        guard let aliceDelegate = advanceToRoleBound(alice, peerId: handleB,
                                                    serviceDataHint: pair.bobIdentity.nodeHint,
                                                    capturePeer: capturePeer) else {
            throw NSError(domain: "t22", code: 1, userInfo: [NSLocalizedDescriptionKey: "the initiator never bound"])
        }
        bob.start()
        let bobPM = bob.requireContextPeripheralForTest()
        let (bound, saw) = advanceToResponderBound(bob, pm: bobPM, centralId: handleA,
                                                   remoteHint: pair.aliceIdentity.nodeHint, updateCapacity: 10)
        guard bound else {
            throw NSError(domain: "t22", code: 2, userInfo: [NSLocalizedDescriptionKey: "the responder never bound: " + saw])
        }
        return T22Rig(pair: pair, alice: alice, bob: bob, aliceSpy: aliceSpy, bobSpy: bobSpy,
                      capturePeer: capturePeer, aliceFactory: aliceFactory, bobFactory: bobFactory,
                      handleA: handleA, handleB: handleB,
                      aliceDelegate: aliceDelegate, bobPM: bobPM)
    }

    private func rigT22Denying(reason: PeerTrustRejectReason?) throws -> T22Rig {
        let pair = try t22BarePair(denyReason: reason)
        let handleB = UUID()
        let handleA = UUID()
        let aliceFactory = CaptureFactory()
        let bobFactory = CaptureFactory()
        let alice = BleTransport(identity: pair.aliceIdentity, store: T22MessageStore(),
                                 sessions: pair.aliceManager,
                                 managerFactory: aliceFactory, clock: TestClock(startingAt: 9_300))
        let bob = BleTransport(identity: pair.bobIdentity, store: nil, sessions: pair.bobManager,
                               managerFactory: bobFactory, clock: TestClock(startingAt: 9_300))
        let aliceSpy = T17DelegateSpy(); alice.delegate = aliceSpy
        let bobSpy = T17DelegateSpy(); bob.delegate = bobSpy
        let (_, capturePeer) = peripheralPunt(handleB)
        guard let aliceDelegate = advanceToRoleBound(alice, peerId: handleB,
                                                    serviceDataHint: pair.bobIdentity.nodeHint,
                                                    capturePeer: capturePeer) else {
            throw NSError(domain: "t22", code: 1, userInfo: [NSLocalizedDescriptionKey: "the initiator never bound"])
        }
        bob.start()
        let bobPM = bob.requireContextPeripheralForTest()
        let (bound, saw) = advanceToResponderBound(bob, pm: bobPM, centralId: handleA,
                                                   remoteHint: pair.aliceIdentity.nodeHint)
        guard bound else {
            throw NSError(domain: "t22", code: 2, userInfo: [NSLocalizedDescriptionKey: "the responder never bound: " + saw])
        }
        return T22Rig(pair: pair, alice: alice, bob: bob, aliceSpy: aliceSpy, bobSpy: bobSpy,
                      capturePeer: capturePeer, aliceFactory: aliceFactory, bobFactory: bobFactory,
                      handleA: handleA, handleB: handleB,
                      aliceDelegate: aliceDelegate, bobPM: bobPM)
    }

    private final class T22MessageStore: MessageStore {
        var held: [Data] = []
        var failNextPersist = false
        var persistCount = 0
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
            persistCount += 1
            if failNextPersist {
                lock.unlock()
                return .failedStorage
            }
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

}
