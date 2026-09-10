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
final class ReadinessT21Tests: XCTestCase {

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
                ReadinessT21Tests.remoteLinkInfoStatic(hint: serviceDataHint)]
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
                                                          service: ReadinessT21Tests.provisionedService(), error: nil)
        walkLog.append("characteristics -> " + String(describing: a2) + " @ " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let linkInfoChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: ReadinessT21Tests.remoteLinkInfoStatic(hint: serviceDataHint),
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
                                        rawData: ReadinessT21Tests.remoteLinkInfoStatic(hint: remoteHint),
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
            if ReadinessT21Tests.hintAscending(c, local) { return c }
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
            if ReadinessT21Tests.hintAscending(local, c) { return c }
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

    private struct T21Rig {
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

    private func rigT21() throws -> T21Rig {
        let pair = try ReadinessTrustedPairing.barePair()
        let handleB = UUID()
        let handleA = UUID()
        let aliceFactory = CaptureFactory()
        let bobFactory = CaptureFactory()
        let alice = BleTransport(identity: pair.aliceIdentity, store: T21MessageStore(),
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
            throw NSError(domain: "t21", code: 1, userInfo: [NSLocalizedDescriptionKey: "the initiator never bound"])
        }
        bob.start()
        let bobPM = bob.requireContextPeripheralForTest()
        let (bound, saw) = advanceToResponderBound(bob, pm: bobPM, centralId: handleA,
                                                   remoteHint: pair.aliceIdentity.nodeHint)
        guard bound else {
            throw NSError(domain: "t21", code: 2, userInfo: [NSLocalizedDescriptionKey: "the responder never bound: " + saw])
        }
        return T21Rig(pair: pair, alice: alice, bob: bob, aliceSpy: aliceSpy, bobSpy: bobSpy,
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

    private func beginWith(_ r: T21Rig, _ hint: Data) -> TransportResult {
        r.alice.beginTrustedHandshake(peerId: r.handleB, remoteHint: hint)
    }

    private func capturedHS2(_ r: T21Rig) -> Data? {
        guard let mgr = r.bobFactory.peripheralManagers.last else { return nil }
        return firstCapture(of: mgr, towards: r.handleA)
    }

    /** Drives the exchange step by step, asserting the passage at every
     *  door, and brings the pair to the trusted READY. The HS2 fragments
     *  as they travelled are handed back for the trials that reuse them. */
    private func driveToReady(_ r: T21Rig) throws -> Data? {
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

    func testTheInitiatorEmittehHS1UponTheDuplexWitnessedInAscendantOrder() throws {
        let r = try rigT21()
        defer { cleanup(r) }
        r.capturePeer.clearWrites()
        XCTAssertEqual(beginWith(r, r.pair.bobIdentity.nodeHint), .admitted,
                       "the begin must be admitted upon the witnessed duplex")
        guard let hs1 = waitWhile({ r.capturePeer.writes.last }, nonEmpty: true) else {
            return XCTFail("the HS1 never came forth; ring: " + ringOf(r.alice))
        }
        XCTAssertEqual(typeOfByte(hs1), Int(BleRecordType.hs1.rawValue), "the first record must be HS1")
        XCTAssertEqual(fragCountOf(hs1), 1, "the HS1 must travel whole in one fraction")
        XCTAssertEqual(payloadOf(hs1).count, 32, "the HS1 message is thirty-two octets")
        XCTAssertEqual(r.alice.connection(for: r.handleB)?.state, .handshakeInProgress,
                       "the state must progress to the handshake in progress")
        XCTAssertNotNil(r.pair.aliceManager.slotForTest(r.handleB),
                        "the relation must stand admitted with its session slot")
        // no second begin while the exchange liveth: the slot beareth a controller
        let again = beginWith(r, r.pair.bobIdentity.nodeHint)
        XCTAssertTrue(again != .admitted, "a second begin upon the living exchange must be refused")
        XCTAssertTrue(ringOf(r.alice).contains("begin initiator refused"),
                      "the ring must name the second refusal: " + ringOf(r.alice))
    }

    func testTheBeginIsRefusedWhileTheDuplexLiesUnwitnessed() throws {
        let r = try rigT21()
        defer { cleanup(r) }
        guard let conn = r.alice.connection(for: r.handleB) else { return XCTFail("no conn") }
        conn.maxAttValueLength = 10   // below the floor of twenty the witness faileth
        r.capturePeer.clearWrites()
        let verdict = beginWith(r, r.pair.bobIdentity.nodeHint)
        XCTAssertTrue(verdict != .admitted, "an unwitnessed duplex must refuse the begin")
        XCTAssertTrue(ringOf(r.alice).contains("physical duplex not witnessed"),
                      "the ring must name the missing witness: " + ringOf(r.alice))
        XCTAssertTrue(r.capturePeer.writes.isEmpty, "no record may travel an unwitnessed duplex")
        XCTAssertNil(r.pair.aliceManager.slotForTest(r.handleB), "no slot may be born of a refused begin")
        XCTAssertEqual(r.alice.connection(for: r.handleB)?.state, .roleBound,
                       "the state must stand where it stood")
    }

    func testTheBeginIsRefusedWhenTheHintsDescendOrMeet() throws {
        let r = try rigT21()
        defer { cleanup(r) }
        let equal = beginWith(r, r.pair.aliceIdentity.nodeHint)
        XCTAssertTrue(equal != .admitted, "equal hints know no ascendant seat")
        let descending = beginWith(r, Data([0, 0, 0, 0]))
        XCTAssertTrue(descending != .admitted, "descending hints must refuse the begin")
        let named = r.alice.rejectionRecordsForTest().filter {
            $0.site == "hs.begin" && $0.reason.contains("hint order not ascendant")
        }
        XCTAssertEqual(named.count, 2, "both refusals must ring at the begin door: " + ringOf(r.alice))
        XCTAssertTrue(r.capturePeer.writes.isEmpty, "no HS1 may travel a disordered order")
        XCTAssertNil(r.pair.aliceManager.slotForTest(r.handleB), "no slot may be born of disordered counsel")
    }

    func testTheComparatorOrderedAsTheLawStates() throws {
        let r = try rigT21()
        defer { cleanup(r) }
        let cmpr = r.alice
        XCTAssertTrue(cmpr.hintOrder(local: Data([1, 2, 3, 4]), remote: Data([1, 2, 3, 5])) < 0,
                      "the ascendant pair readeth lesser")
        XCTAssertEqual(cmpr.hintOrder(local: Data([9, 9, 9, 9]), remote: Data([9, 9, 9, 9])), 0,
                        "equal hints meet at zero")
        XCTAssertTrue(cmpr.hintOrder(local: Data([0xFF, 0, 0, 0]), remote: Data([1, 0, 0, 0])) > 0,
                      "the unsigned reading ruleth above the sign")
        XCTAssertTrue(cmpr.hintOrder(local: Data([1, 2, 3]), remote: Data([1, 2, 3, 0])) < 0,
                      "the shorter prefix is the lesser")
        XCTAssertTrue(cmpr.hintOrder(local: Data(), remote: Data([0])) < 0,
                      "the empty key is the least of all")
    }

    func testTheHS2TraveltToItsOwnRelationAloneAndBoreTheImmutableHint() throws {
        let r = try rigT21()
        defer { cleanup(r) }
        r.capturePeer.clearWrites()
        XCTAssertEqual(beginWith(r, r.pair.bobIdentity.nodeHint), .admitted)
        guard let hs1 = waitWhile({ r.capturePeer.writes.last }, nonEmpty: true) else {
            return XCTFail("no HS1; ring: " + ringOf(r.alice))
        }
        r.capturePeer.clearWrites()
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: hs1)
        guard let hs2 = waitWhile({ capturedHS2(r) }, nonEmpty: true) else {
            return XCTFail("no HS2; ring: " + ringOf(r.bob))
        }
        XCTAssertEqual(typeOfByte(hs2), Int(BleRecordType.hs2.rawValue), "the answer must be HS2")
        XCTAssertEqual(payloadOf(hs2).count, 229, "the HS2 message is two hundred twenty-nine octets")
        XCTAssertTrue(r.capturePeer.writes.isEmpty,
                      "the HS2 must not be written upon the initiators own outlet")
        let priorCount = r.capturePeer.writes.count
        pushToInitiator(r.alice, r.aliceDelegate, hs2)
        var hs3: Data? = nil
        for _ in 0..<800 {
            let w = r.capturePeer.writes
            if w.count > priorCount, let last = w.last { hs3 = last; break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard let hs3 = hs3 else {
            let st = r.alice.connection(for: r.handleB).map { String(describing: $0.state) } ?? "nil"
            let wr = r.capturePeer.writes.map { typeOfByte($0) }
            let slot = r.pair.aliceManager.slotForTest(r.handleB) != nil
            return XCTFail("the HS3 never answered; ring: " + ringOf(r.alice)
                + " | state=" + st + " | writes=" + String(wr.count) + " kinds=" + wr.description
                + " | slot=" + String(slot))
        }
        XCTAssertEqual(typeOfByte(hs3), Int(BleRecordType.hs3.rawValue), "the third record must be HS3")
        XCTAssertEqual(payloadOf(hs3).count, 197, "the HS3 message is one hundred ninety-seven octets")
        XCTAssertEqual(r.bob.connection(for: r.handleA)?.state, .handshakeInProgress,
                       "the responder must still await its own leg")
        XCTAssertNotNil(r.pair.aliceManager.slotForTest(r.handleB),
                         "the slot must outlive the third record")
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: hs3)
        XCTAssertTrue(waitUntil2 { r.pair.bobManager.isReady(r.handleA) })
    }

    func testTheTrustRejectionWithheldHS3AndClosedTheRelationExactly() throws {
        let r = try rigT21()
        defer { cleanup(r) }
        r.capturePeer.clearWrites()
        XCTAssertEqual(beginWith(r, r.pair.bobIdentity.nodeHint), .admitted)
        guard let hs1 = waitWhile({ r.capturePeer.writes.last }, nonEmpty: true) else {
            return XCTFail("no HS1")
        }
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: hs1)
        guard let hs2 = waitWhile({ capturedHS2(r) }, nonEmpty: true) else {
            return XCTFail("no HS2")
        }
        // the villain: one octet of the sealed span falsified, the header true
        var tampered = payloadOf(hs2)
        let at = tampered.index(tampered.startIndex, offsetBy: tampered.count - 1)
        tampered[at] = tampered[at] ^ 0x5A
        let forged = try! BleRecordFragmenter.fragment(recordType: .hs2,
                                                       recordSeq: hs2[2],
                                                       payload: tampered,
                                                       maxAttValueLength: 247)
        pushToInitiator(r.alice, r.aliceDelegate, forged[0])
        XCTAssertTrue(waitUntil2 { self.ringOf(r.alice).contains("hs2 rejected") },
                      "the forged counsel must be refused; ring: " + ringOf(r.alice))
        XCTAssertTrue(ringOf(r.alice).contains("hs.read.initiator"), "the door must ring its own site")
        let kinds = r.capturePeer.writes.map { typeOfByte($0) }
        XCTAssertFalse(kinds.contains(Int(BleRecordType.hs3.rawValue)), "the HS3 must be withheld")
        XCTAssertNil(r.pair.aliceManager.slotForTest(r.handleB), "the slot must perish with the relation")
        XCTAssertTrue(waitUntil2 { r.alice.connection(for: r.handleB) == nil })
        XCTAssertNil(r.alice.connection(for: r.handleB), "the relation must close exactly")
        XCTAssertTrue(r.bobSpy.received.isEmpty, "no application record may ride the fallen trust")
    }

    func testTheBadBindingAndBadStaticKeyAndBadHintEachWithheldAllApplicationData() throws {
        for villainy in ["binding", "static", "hint"] {
            let r = try rigT21()
            defer { cleanup(r) }
            r.capturePeer.clearWrites()
            var hintUsed = r.pair.bobIdentity.nodeHint
            if villainy == "hint" {
                // the expectation is taintedd at the begin itself
                var wrong = r.pair.bobIdentity.nodeHint
                let i = wrong.index(wrong.startIndex, offsetBy: wrong.count - 1)
                wrong[i] = (wrong[i] == 0xFF) ? 0xFE : 0xFF
                hintUsed = wrong
            }
            XCTAssertEqual(beginWith(r, hintUsed), .admitted,
                           "the begin must stand for the " + villainy + " trial; ring: " + ringOf(r.alice))
            guard let hs1 = waitWhile({ r.capturePeer.writes.last }, nonEmpty: true) else {
                XCTFail("no HS1 for " + villainy); continue
            }
            r.capturePeer.clearWrites()
            pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: hs1)
            guard let hs2 = waitWhile({ capturedHS2(r) }, nonEmpty: true) else {
                XCTFail("no HS2 for " + villainy); continue
            }
            if villainy != "hint" {
                var tampered = payloadOf(hs2)
                let at = tampered.index(tampered.startIndex,
                                       offsetBy: villainy == "binding" ? tampered.count / 8 : tampered.count / 2)
                tampered[at] = tampered[at] ^ 0xA5
                let forged = try! BleRecordFragmenter.fragment(recordType: .hs2,
                                                              recordSeq: UInt8(hs2[2]),
                                                              payload: tampered,
                                                              maxAttValueLength: 247)
                pushToInitiator(r.alice, r.aliceDelegate, forged[0])
            } else {
                pushToInitiator(r.alice, r.aliceDelegate, hs2)
            }
            XCTAssertTrue(waitUntil2 { self.ringOf(r.alice).contains("hs2 rejected") },
                          "the " + villainy + " villain must be refused; ring: " + ringOf(r.alice))
            let kinds = r.capturePeer.writes.map { typeOfByte($0) }
            XCTAssertFalse(kinds.contains(Int(BleRecordType.hs3.rawValue)),
                          "the " + villainy + " villain must have the HS3 withheld")
            XCTAssertNil(r.pair.aliceManager.slotForTest(r.handleB),
                         "the " + villainy + " slot must perish with the relation")
            XCTAssertTrue(waitUntil2 { r.alice.connection(for: r.handleB) == nil })
            XCTAssertNil(r.alice.connection(for: r.handleB),
                         "the " + villainy + " relation must close exactly")
            XCTAssertTrue(r.bobSpy.received.isEmpty, "the " + villainy + " trial brought no application DATA")
        }
    }

    func testAnUnexpectedRecordAfterTheTrustClosedTheRelationExactly() throws {
        let r = try rigT21()
        defer { cleanup(r) }
        guard let hs2 = try driveToReady(r) else { return }
        // a fresh sequence number, the HS2 shape: after the trust no HS2 is
        // expected at all - the section thirteen law closes the relation
        let forged = try! BleRecordFragmenter.fragment(recordType: .hs2,
                                                     recordSeq: UInt8((Int(hs2[2]) + 7) & 0xFF),
                                                     payload: payloadOf(hs2),
                                                     maxAttValueLength: 247)
        pushToInitiator(r.alice, r.aliceDelegate, forged[0])
        XCTAssertTrue(waitUntil2 { self.ringOf(r.alice).contains("at stage") },
                      "the gate must refuse the out-of-order counsel; ring: " + ringOf(r.alice))
        XCTAssertTrue(ringOf(r.alice).contains("ingest.notify"), "the gate must ring its own site")
        XCTAssertTrue(waitUntil2 { r.alice.connection(for: r.handleB) == nil })
        XCTAssertNil(r.alice.connection(for: r.handleB), "the relation must close exactly")
        XCTAssertFalse(r.pair.aliceManager.isReady(r.handleB), "the slot must perish with the relation")
        XCTAssertTrue(r.bobSpy.received.isEmpty, "no application record may ride the fallen relation")
    }

    func testTheHS3PrecededEveryDATAInTheWriterOrder() throws {
        let r = try rigT21()
        defer { cleanup(r) }
        guard let _chain = try driveToReady(r) else { return }
        let beforeData = r.capturePeer.writes
        let kindsBefore = beforeData.map { typeOfByte($0) }
        XCTAssertEqual(kindsBefore.last, Int(BleRecordType.hs3.rawValue),
                       "the last writing of the exchange must be the HS3")
        let plain = makeFrame(clearOf(771, 120))
        XCTAssertEqual(r.alice.send(plain, to: r.handleB), .admitted,
                       "the application must be admitted after the trust")
        let afterData = r.capturePeer.writes
        XCTAssertTrue(waitUntil2 { afterData.count > beforeData.count })
        let kinds = afterData.map { typeOfByte($0) }
        guard let firstData = kinds.firstIndex(of: Int(BleRecordType.data.rawValue)),
              let lastHs3 = kinds.lastIndex(of: Int(BleRecordType.hs3.rawValue)) else {
            return XCTFail("the writings must hold both the HS3 and the DATA")
        }
        XCTAssertLessThan(lastHs3, firstData, "the HS3 must be queued ahead of every DATA record")
        let fresh = Array(afterData.dropFirst(beforeData.count))
        pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: fresh[0])
        XCTAssertTrue(waitUntil2 { r.bobSpy.received.count == 1 })
    }

    func testNoApplicationDATAProceededBeforeTheTrustedCryptographicReady() throws {
        let r = try rigT21()
        defer { cleanup(r) }
        r.capturePeer.clearWrites()
        XCTAssertEqual(beginWith(r, r.pair.bobIdentity.nodeHint), .admitted)
        guard let _ = waitWhile({ r.capturePeer.writes.last }, nonEmpty: true) else {
            return XCTFail("no HS1")
        }
        XCTAssertEqual(r.alice.connection(for: r.handleB)?.state, .handshakeInProgress,
                       "the exchange must stand in progress")
        let verdict = r.alice.send(makeFrame(clearOf(301, 120)), to: r.handleB)
        XCTAssertNotEqual(verdict, TransportResult.admitted,
                         "DATA before the trusted READY must not be admitted")
        let kinds = r.capturePeer.writes.map { typeOfByte($0) }
        XCTAssertFalse(kinds.contains(Int(BleRecordType.data.rawValue)), "no DATA may travel before the trust")
        XCTAssertTrue(r.bobSpy.received.isEmpty, "the responder must collect nothing of the untrusted hour")
    }

    func testTheControllerReadyAlonePublishedNoLinkReady() throws {
        let r = try rigT21()
        defer { cleanup(r) }
        let censusA0 = r.alice.publishedRelationsForTest().count
        let censusB0 = r.bob.publishedRelationsForTest().count
        guard let _chain = try driveToReady(r) else { return }
        XCTAssertTrue(waitUntil2 { !r.bobSpy.handshakeReadyPeers.isEmpty },
                      "the completion hook must note the trusted passage")
        XCTAssertEqual(r.alice.publishedRelationsForTest().count, censusA0,
                       "the exchange must add no publication to the initiator")
        XCTAssertEqual(r.bob.publishedRelationsForTest().count, censusB0,
                       "the exchange must add no publication to the responder")
        // the positive control upon the very relation of the exchange: the
        // ladders own enrollment, withdrawn and re-inlisted - the ledger
        // keepeth but one entrance per peer, so a second key under the same
        // central is refused by that law, as this witness trial proved
        let census0 = r.bob.publishedRelationsForTest()
        XCTAssertEqual(census0.count, censusB0, "the exchange added nought to the responders ledger")
        guard let key = census0.first(where: { $0.peerId == r.handleA }) else {
            return XCTFail("the ladder enrolled nought for this central; census: " + census0.description)
        }
        XCTAssertTrue(r.bob.unpublishRelation(key), "the enrollment must withdraw")
        XCTAssertEqual(r.bob.publishedRelationsForTest().count, censusB0 - 1, "the census must see the withdrawal")
        XCTAssertTrue(r.bob.publishRelation(key), "the hand-standing publication must be re-enrolled")
        XCTAssertEqual(r.bob.publishedRelationsForTest().count, censusB0, "the census must see the re-enlistment")
    }

    func testTheHS3ReservationFailureClosedTheRelationExactly() throws {
        // the reservation flood on the island is beyond the tests reach by
        // any public handle: the pump draineth as it runneth, and the
        // staging is private. That branch is proven on the other island by
        // the flooder and here by inspection. What the fixture can raise is
        // the duplicate counsel after the consumption: the second HS2, the
        // selfsame bytes, must be refused and the relation must fall.
        let r = try rigT21()
        defer { cleanup(r) }
        guard let hs2 = try driveToReady(r) else { return }
        let kindsBefore = r.capturePeer.writes.map { typeOfByte($0) }
        let hs3CountBefore = kindsBefore.filter { $0 == Int(BleRecordType.hs3.rawValue) }.count
        XCTAssertGreaterThan(hs3CountBefore, 0, "the first HS3 must stand upon the wire")
        pushToInitiator(r.alice, r.aliceDelegate, hs2)
        XCTAssertTrue(waitUntil2 { self.ringOf(r.alice).contains("at stage") },
                      "the duplicate counsel must be refused by the gate; ring: " + ringOf(r.alice))
        XCTAssertTrue(waitUntil2 { r.alice.connection(for: r.handleB) == nil })
        XCTAssertNil(r.alice.connection(for: r.handleB), "the relation must close exactly")
        XCTAssertFalse(r.pair.aliceManager.isReady(r.handleB), "the slot must perish with the relation")
        let kindsAfter = r.capturePeer.writes.map { typeOfByte($0) }
        XCTAssertEqual(kindsAfter.filter { $0 == Int(BleRecordType.hs3.rawValue) }.count, hs3CountBefore,
                       "no second HS3 may follow the duplicate counsel")
    }

    func testTheStorageFailureKeptThePriorTruthUnmutated() throws {
        // the acceptor consulteth the store; a failed persist refuseth the
        // frame AND leaveth the seen ledger unmarked - the proof that no
        // phantom of a failed admission surviveneth: the selfsame frame is
        // taken at its first true admission when the store is whole, and
        // only then doth the ledger refuse it, twice told
        let store = T21MessageStore()
        let router = Router(selfNodeId: Data(repeating: 0x0A, count: 16))
        router.store = store
        let f1 = frameWithByte(0x7E)
        let f2 = frameWithByte(0x7F)
        store.failNextPersist = true
        XCTAssertFalse(router.ingest(f1, isAddressedToMe: true, receivedFrom: Data()),
                       "the frame must not be accepted while the store is fainthe")
        XCTAssertEqual(store.persistCount, 1, "the store must have been asked once")
        store.failNextPersist = false
        XCTAssertTrue(router.ingest(f1, isAddressedToMe: true, receivedFrom: Data()),
                      "the selfsame frame must be admitted once the store is whole - the failure leaved no phantom")
        XCTAssertFalse(router.ingest(f1, isAddressedToMe: true, receivedFrom: Data()),
                       "the seen ledger must refuse the very frame twice told")
        XCTAssertTrue(router.ingest(f2, isAddressedToMe: true, receivedFrom: Data()),
                      "a distinct frame must be accepted freely when the store is whole")
    }

    private func frameWithByte(_ b: UInt8) -> FrameV2 {
        return FrameV2(type: .message,
                       msgId: Data(repeating: b, count: 16),
                       routingTag: Data(repeating: 0, count: 4),
                       ttl: 10,
                       hopCount: 0,
                       flags: Priority.toFlags(.direct),
                       payload: Data([1, 2, 3, 4]))
    }

    private func cleanup(_ r: T21Rig) {
        r.alice.stop()
        r.bob.stop()
        ReadinessTrustedPairing.tearDown(r.pair)
    }

    // MARK: - the store that faileth on cue

    private final class T21MessageStore: MessageStore {
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
