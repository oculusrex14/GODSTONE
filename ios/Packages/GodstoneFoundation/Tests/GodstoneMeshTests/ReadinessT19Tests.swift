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
final class ReadinessT19Tests: XCTestCase {

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
                ReadinessT19Tests.remoteLinkInfoStatic(hint: serviceDataHint)]
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
                                                          service: ReadinessT19Tests.provisionedService(), error: nil)
        walkLog.append("characteristics -> " + String(describing: a2) + " @ " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let linkInfoChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: ReadinessT19Tests.remoteLinkInfoStatic(hint: serviceDataHint),
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
                                        rawData: ReadinessT19Tests.remoteLinkInfoStatic(hint: remoteHint),
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
            if ReadinessT19Tests.hintAscending(c, local) { return c }
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
            if ReadinessT19Tests.hintAscending(local, c) { return c }
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

    // MARK: - T19 whole-record reservations and the sliding window
    //
    // The card's roster, every case with at least one assertion that can
    // fail: the full digest at the minimal agreed maximum, the sixty-four
    // whole fractions, the sixty-fifth refused before the seal, the full
    // staging, completions lost and duplicated, a fall midway preserving
    // the durable store, the nonce burned once per submission, the
    // wrong-sized payload refused before the seal, the retained fragment
    // across a refused update, the notification by the very handle
    // retained, the stale manager's readiness repelled, and the two
    // directions fragmenting at their own maxima.

    private func frameOfExactEncodedLength(_ want: Int) -> FrameV2? {
        let base = makeFrame([]).encode().count
        guard want >= base else { return nil }
        let f = makeFrame(Array(repeating: UInt8(0xA7), count: want - base))
        guard f.encode().count == want else { return nil }
        return f
    }

    // The record header, as the codec lays it: magic, type, sequence,
    // fragment index, fragment count, total length (two), check. The nonce
    // of the envelope within is observable only where the head fragment
    // carries the sealed text's opening eight octets.
    private func fragSeqOf(_ value: Data) -> Int { Int(value[2]) }
    private func fragIndexIsHead(_ value: Data) -> Bool { value.count > 3 && value[3] == 0 }
    private func fragCountOf(_ value: Data) -> Int { Int(value[4]) }
    private func totalLenOf(_ value: Data) -> Int { Int(value[5]) << 8 | Int(value[6]) }

    private func nonce(of value: Data) -> Data {
        // The fragment header is eight octets; the envelope opens with the
        // eight-octet nonce the seal drew, then the ciphertext and the tag.
        return Data(value[8..<16])
    }

    /// Brings the responder side up: the transport is started first, so the
    /// epoch's context - and with it the capture manager the factory made -
    /// stands ready before any hand reaches for it. Answers the manager and
    /// a failure reason; nil with a reason tells the whole tale.
    private func responderReady(_ bob: BleTransport, centralId: UUID, remoteHint: Data,
                                updateCapacity: Int = 512) throws -> (CapturePeripheralManager?, String) {
        bob.start()
        guard let pm = bob.requireContextPeripheralForTest() as? CapturePeripheralManager else {
            return (nil, "the context's manager is not the capture one")
        }
        let (bound, saw) = advanceToResponderBound(bob, pm: pm, centralId: centralId,
                                                   remoteHint: remoteHint,
                                                   updateCapacity: updateCapacity)
        guard bound else { return (nil, "responder ladder: " + saw) }
        bob.connection(for: centralId)?.markReadyForTesting()
        guard bob.connection(for: centralId)?.state == .ready else {
            return (nil, "the responder never reached the ready state")
        }
        return (pm, "ready")
    }

    // MARK: case 1: the full digest at the minimal agreed maximum

    func testAttestTwentyTwentyCarriesTheFullDigest() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let peerId = pair.viaBob
        let aliceFactory = CaptureFactory()
        let alice = BleTransport(identity: pair.aliceIdentity, store: T17MessageStore(),
                                 sessions: pair.aliceManager, managerFactory: aliceFactory,
                                 clock: TestClock(startingAt: 9_700))
        alice.start()
        let (_, capturePeer) = peripheralPunt(peerId)
        capturePeer.maxWrite = 20                       // the minimal agreed ATT
        _ = advanceToRoleBound(alice, peerId: peerId,
                                serviceDataHint: ReadinessT19Tests.greaterHint(than: pair.aliceIdentity.nodeHint),
                                capturePeer: capturePeer)
        alice.connection(for: peerId)?.markReadyForTesting()
        let f = makeFrame((0..<32).map { UInt8(($0 &* 7 &+ 13) % 251 &+ 4) })
        let sealed = f.encode().count + RecordWriter.sealOverheadBytes
        XCTAssertEqual(alice.send(f, to: peerId), .admitted)
        let space = capturePeer.maxWrite - BleRecordConstants.headerBytes
        let fragments = (sealed + space - 1) / space
        XCTAssertEqual(capturePeer.writes.count, fragments,
                       "the full digest flows at the minimum, in " + String(fragments) + " values")
        XCTAssertGreaterThan(fragments, 0)
        for w in capturePeer.writes { XCTAssertLessThanOrEqual(w.count, capturePeer.maxWrite) }
        var total = 0
        for w in capturePeer.writes { total += w.count - BleRecordConstants.headerBytes }
        XCTAssertEqual(total, sealed, "the whole sealed record, octet for octet")
        alice.stop()
    }

    // MARK: case 2: the sixty-fourth whole fraction

    func testSixtyFourWholeFractionsAreAdmitted() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let peerId = pair.viaBob
        let alice = BleTransport(identity: pair.aliceIdentity, store: T17MessageStore(),
                                 sessions: pair.aliceManager, managerFactory: CaptureFactory(),
                                 clock: TestClock(startingAt: 9_701))
        alice.start()
        let (_, capturePeer) = peripheralPunt(peerId)
        capturePeer.maxWrite = 264      // where the fraction ceiling meets the record ceiling
        let space = capturePeer.maxWrite - BleRecordConstants.headerBytes   // 256 octets
        guard let f = frameOfExactEncodedLength(64 * space - RecordWriter.sealOverheadBytes) else {
            XCTFail("the calibration of the whole-numbered frame failed"); return
        }
        _ = advanceToRoleBound(alice, peerId: peerId,
                               serviceDataHint: ReadinessT19Tests.greaterHint(than: pair.aliceIdentity.nodeHint),
                               capturePeer: capturePeer)
        alice.connection(for: peerId)?.markReadyForTesting()
        XCTAssertEqual(alice.send(f, to: peerId), .admitted)
        XCTAssertEqual(capturePeer.writes.count, 64, "sixty four whole fractions, none sparred")
        for w in capturePeer.writes {
            // The value on the wire is the record's eight-octet header plus
            // its fraction of the sealed text: at this capacity the whole
            // maximum is filled, octet for octet.
            XCTAssertEqual(w.count, capturePeer.maxWrite, "every fraction fills the direction's maximum")
        }
        var total = 0
        for w in capturePeer.writes { total += w.count - BleRecordConstants.headerBytes }
        XCTAssertEqual(total, 64 * space, "and the fractions reassemble the sealed record whole")
        alice.stop()
    }

    // MARK: case 3: the sixty-fifth fraction refused before the seal

    func testTheSixtyFifthFractionIsRefusedBeforeTheSeal() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let peerId = pair.viaBob
        let alice = BleTransport(identity: pair.aliceIdentity, store: T17MessageStore(),
                                 sessions: pair.aliceManager, managerFactory: CaptureFactory(),
                                 clock: TestClock(startingAt: 9_702))
        alice.start()
        let (_, capturePeer) = peripheralPunt(peerId)
        capturePeer.maxWrite = 264      // the same meeting of the two ceilings
        let space = capturePeer.maxWrite - BleRecordConstants.headerBytes
        let ceiling = min(BleRecordConstants.maxRecord, BleRecordConstants.maxFragments * space)
        let sealed = ceiling + 1   // one octet past where both ceilings bind
        guard let f = frameOfExactEncodedLength(sealed - RecordWriter.sealOverheadBytes) else {
            XCTFail("the calibration of the overlong frame failed"); return
        }
        _ = advanceToRoleBound(alice, peerId: peerId,
                               serviceDataHint: ReadinessT19Tests.greaterHint(than: pair.aliceIdentity.nodeHint),
                               capturePeer: capturePeer)
        guard let conn = alice.connection(for: peerId) else { XCTFail("no connection"); return }
        conn.markReadyForTesting()
        let seqBefore = conn.peekOutboundSequence()
        let verdict = alice.send(f, to: peerId)
        if case .rejected(let why) = verdict {
            XCTAssertTrue(why.contains("in 65 fragments"), "the refusal names the count: " + why)
            XCTAssertTrue(why.contains(String(sealed)), "the refusal names the sealed length: " + why)
            XCTAssertTrue(why.contains(String(ceiling)), "the refusal names the ceiling: " + why)
        } else {
            XCTFail("the overlong record must be refused by value, saw \(verdict)"); return
        }
        XCTAssertTrue(capturePeer.writes.isEmpty, "the seal never burned for a doomed record")
        XCTAssertEqual(conn.peekOutboundSequence(), seqBefore, "the sequence number stands unconsumed")
        XCTAssertTrue(alice.rejectionRecordsForTest().contains { $0.site == "send.capacity" },
                      "the ring records the refusal at the capacity gate")
        alice.stop()
    }

    // MARK: case 4: the full staging is backpressure, not a silent drop

    func testTheStagingIsFullAndTheSendIsBackpressured() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        let bobFactory = CaptureFactory()
        let bob = BleTransport(identity: pair.bobIdentity, store: T17MessageStore(),
                               sessions: pair.bobManager, managerFactory: bobFactory,
                               clock: TestClock(startingAt: 9_703))
        let (pmOpt, why) = try responderReady(bob, centralId: centralId,
                                              remoteHint: pair.aliceIdentity.nodeHint)
        guard let pm = pmOpt else { XCTFail(why); return }
        var accepts = false
        pm.updateAnswer = { _ in accepts }
        let space = 512 - BleRecordConstants.headerBytes     // the pinned central's maximum
        guard let f1 = frameOfExactEncodedLength(12 * space - RecordWriter.sealOverheadBytes),
              let f2 = frameOfExactEncodedLength(5 * space - RecordWriter.sealOverheadBytes) else {
            XCTFail("the calibration of the staged frames failed"); return
        }
        XCTAssertEqual(bob.send(f1, to: centralId), .backpressured, "the leg refused, the value waits")
        XCTAssertEqual(bob.send(f2, to: centralId), .backpressured, "the head value refuses again")
        let writer = bob.responderWriterForTest(centralId)
        XCTAssertNotNil(writer, "the direction's writer stands where the sends committed")
        XCTAssertEqual(writer?.stagedValues() ?? -1, 16, "the window holds its bound and no more")
        XCTAssertEqual(writer?.admittedCount() ?? -1, 2, "both records are admitted, none dropped")
        let ring = bob.rejectionRecordsForTest().filter { $0.site == "send.responder" }
        XCTAssertTrue(ring.contains { $0.reason == "queue full" }, "the queue full is told")
        XCTAssertTrue(ring.contains { $0.reason == "the staging is full" }, "the full staging is told")
        // The very same context reports itself ready again: the window drains.
        accepts = true
        bob.processPeripheralIsReadyToUpdateSubscribers(pm, sourceEpoch: bob.currentTransportEpoch)
        XCTAssertEqual(pm.capturedUpdates.count, 17, "twelve and five flow out in order")
        XCTAssertEqual(pm.updateAttempts.count, 19, "the two refusals stand recorded as attempts")
        // The peer's eye: a fresh station in the initiating posture ingests
        // the very bytes the responder sent and defragments them whole.
        let peerConn = BleConnection(peerId: centralId, initialMaxAttValueLength: 512)
        XCTAssertTrue(peerConn.markReadyForTesting())
        var reassembled: [Data] = []
        for u in pm.capturedUpdates {
            if let record = peerConn.ingestInboundAttValue(u.bytes).admittedRecord {
                reassembled.append(record.payload)
            }
        }
        XCTAssertEqual(reassembled.count, 2, "the two records reassemble whole at the peer")
        // What arrives is the sealed text; the very manager that sealed it
        // on the far hand opens it back to the frame that was sent.
        XCTAssertEqual(reassembled[0].count, f1.encode().count + RecordWriter.sealOverheadBytes,
                       "the envelope adds its twenty-four octets")
        // The far station opens them: each manager keeps its own sequence
        // numbers and its own window, and the nonces bob drew were never
        // seen on alice's side of the session.
        XCTAssertEqual(pair.aliceManager.open(pair.viaBob, reassembled[0]), f1.encode(),
                       "opened by the counterpart, in the order sent")
        XCTAssertEqual(pair.aliceManager.open(pair.viaBob, reassembled[1]), f2.encode())
        bob.stop()
    }

    // MARK: case 5: completions lost and duplicated change nothing

    func testCallbacksLostAndDuplicatesChangeNothing() throws {
        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 512)
        conn.markReadyForTesting()
        let rk = RelationKey(direction: .outboundCentral, peerId: conn.peerId)
        let writer = RecordWriter(connection: conn, relationKey: rk)
        let answer: (Data) -> Data? = { p in Data(count: p.count + RecordWriter.sealOverheadBytes) }
        guard case .admitted(let res) = writer.reserve(recordType: .data, clearLength: 980, capacity: 512) else {
            XCTFail("the two-value record must be admitted"); return
        }
        XCTAssertEqual(res.sealAndQueue(Data(repeating: 0x33, count: 980), sealer: answer), .queued)
        XCTAssertEqual(writer.admittedCount(), 1)
        guard let first = writer.nextOut() else { XCTFail("the pump must hand the first value"); return }
        XCTAssertEqual(writer.stagedValues(), 2,
                       "both values are held until a completion retires them; one flies")
        XCTAssertTrue(writer.completed(first.operation), "the first completion travels")
        XCTAssertFalse(writer.completed(first.operation), "the duplicate changes nothing")
        XCTAssertEqual(writer.staleCompletionsCount(), 1, "the duplicate is told as stale")
        guard let second = writer.nextOut() else { XCTFail("the pump must hand the second value"); return }
        XCTAssertNil(writer.nextOut(), "at most one value flies")
        XCTAssertFalse(writer.completed(first.operation), "a token naming the travelled fragment is told")
        XCTAssertEqual(writer.staleCompletionsCount(), 2, "the loss invented nothing")
        XCTAssertTrue(writer.completed(second.operation), "the real completion travels at last")
        XCTAssertEqual(writer.admittedCount(), 0, "the record retires whole")
        XCTAssertEqual(writer.stagedValues(), 0)
        XCTAssertNil(writer.inFlightOperation())
    }

    // MARK: case 6: a fall midway closes the relation and preserves the store

    func testFailedMidwayClosesTheRelationAndPreservesTheStore() throws {
        let store = T17MessageStore()
        let f = makeFrame([11, 22, 33, 44])
        XCTAssertEqual(store.persist(f, receivedFrom: Data([1, 2, 3, 4])), .heldNew,
                       "the application's data is durably held before the leg runs")
        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 512)
        conn.markReadyForTesting()
        let rk = RelationKey(direction: .outboundCentral, peerId: conn.peerId)
        let writer = RecordWriter(connection: conn, relationKey: rk)
        let answer: (Data) -> Data? = { p in Data(count: p.count + RecordWriter.sealOverheadBytes) }
        guard case .admitted(let res) = writer.reserve(recordType: .data, clearLength: 980, capacity: 512) else {
            XCTFail("admission expected"); return
        }
        XCTAssertEqual(res.sealAndQueue(Data(repeating: 0x5C, count: 980), sealer: answer), .queued)
        guard let a = writer.nextOut() else { XCTFail("the first value must be handed"); return }
        XCTAssertTrue(writer.completed(a.operation), "the first value completes cleanly")
        guard let b = writer.nextOut() else { XCTFail("the second value must be handed"); return }
        XCTAssertTrue(writer.failed(b.operation), "a fall midway closes the relation")
        XCTAssertTrue(writer.isClosed(), "the writer accepts nothing further")
        XCTAssertEqual(writer.admittedCount(), 0, "the staging is released whole")
        XCTAssertNil(writer.nextOut(), "no value leaves the closed hand")
        guard case .refused(.inactive) = writer.reserve(recordType: .data, clearLength: 10, capacity: 512) else {
            XCTFail("a closed writer must refuse as inactive"); return
        }
        // The application's data stands where it stood: the fall touched only
        // the staging. The store is the application's own recorder; what it
        // received before the fall it still holds, msg_id and all.
        XCTAssertEqual(store.persist(f, receivedFrom: Data([1, 2, 3, 4])), .heldNew,
                       "the record may be committed again; the recorder records")
        XCTAssertTrue(store.allHeldMsgIds().contains(f.msgId),
                      "the data held through the fall is the same data held before it")
        // A fresh writer over the selfsame station serves again.
        let w2 = RecordWriter(connection: conn, relationKey: rk)
        guard case .admitted(let res2) = w2.reserve(recordType: .data, clearLength: 10, capacity: 512) else {
            XCTFail("the station is still active for a fresh relation"); return
        }
        XCTAssertEqual(res2.sealAndQueue(Data(repeating: 0x22, count: 10), sealer: answer), .queued)
        XCTAssertNotNil(w2.nextOut(), "the new hand hands values again")
    }

    // MARK: case 7: the nonce is burned once per submission

    func testTheNonceIsBurnedOnceAndNeverAgain() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        let bobFactory = CaptureFactory()
        let bob = BleTransport(identity: pair.bobIdentity, store: T17MessageStore(),
                               sessions: pair.bobManager, managerFactory: bobFactory,
                               clock: TestClock(startingAt: 9_704))
        let (pmOpt, why) = try responderReady(bob, centralId: centralId,
                                              remoteHint: pair.aliceIdentity.nodeHint)
        guard let pm = pmOpt else { XCTFail(why); return }
        var firstRefusal = true
        pm.updateAnswer = { _ in
            if firstRefusal { firstRefusal = false; return false }
            return true
        }
        let clear = (0..<900).map { UInt8(($0 &* 3 &+ 29) % 251 &+ 4) }
        let f1 = makeFrame(clear)
        let f2 = makeFrame(clear)
        XCTAssertEqual(bob.send(f1, to: centralId), .backpressured, "the leg refuses the first value")
        XCTAssertEqual(bob.send(f2, to: centralId), .admitted, "the submission afresh flows")
        let att = pm.updateAttempts
        XCTAssertEqual(att.count, 5, "one refusal and four deliveries")
        XCTAssertTrue(att[0] == att[1], "the re-handed fragment is the very same, octet for octet - unsealed, unreshaped, unread")
        let sealed = f1.encode().count + RecordWriter.sealOverheadBytes
        let expectedFrags = (sealed + 504 - 1) / 504      // the central's own space at 512
        let heads = att.filter { fragIndexIsHead($0) }
        XCTAssertEqual(heads.count, expectedFrags &+ 1,
                       "three heads among five attempts: the refused one stands recorded too")
        XCTAssertEqual(heads[0], att[0], "the first head is the refused attempt itself")
        XCTAssertEqual(heads[1], att[1], "and travelled unchanged when the leg turned ready")
        XCTAssertGreaterThan(expectedFrags, 1, "the record truly had more than one fraction")
        // The two submissions' delivered heads: one nonce each, never the same.
        XCTAssertTrue(nonce(of: heads[1]) != nonce(of: heads[2]), "the two submissions drew two nonces")
        XCTAssertTrue(fragSeqOf(att[1]) == fragSeqOf(att[2]), "the record's fragments share its sequence")
        XCTAssertTrue(fragSeqOf(att[3]) == fragSeqOf(att[4]), "and so the fresh record's own")
        XCTAssertNotEqual(fragSeqOf(att[1]), fragSeqOf(att[3]), "two records, two numbers, taken at the one seat")
        XCTAssertTrue(att.allSatisfy { fragCountOf($0) == expectedFrags },
                      "every value says the record was " + String(expectedFrags) + " fractions")
        XCTAssertTrue(att.allSatisfy { totalLenOf($0) == sealed }, "and all tell one total length")
        bob.stop()
    }

    // MARK: case 8: the wrong-sized payload is refused before the seal

    func testTheWrongSizedPayloadIsRefusedBeforeTheSeal() throws {
        let conn = BleConnection(peerId: UUID(), initialMaxAttValueLength: 512)
        conn.markReadyForTesting()
        let writer = RecordWriter(connection: conn,
                                  relationKey: RelationKey(direction: .outboundCentral, peerId: conn.peerId))
        let seqBefore = conn.peekOutboundSequence()
        var sealerCalls = 0
        guard case .admitted(let res) = writer.reserve(recordType: .data, clearLength: 100, capacity: 512) else {
            XCTFail("the honest size must be admitted"); return
        }
        let drift = res.sealAndQueue(Data(repeating: 0x11, count: 99), sealer: { p in
            sealerCalls += 1
            return Data(count: p.count + RecordWriter.sealOverheadBytes)
        })
        if case .refused(let why) = drift {
            XCTAssertEqual(why, "the payload drifted from the reservation")
        } else { XCTFail("the drift must be refused, saw \(drift)") }
        XCTAssertEqual(sealerCalls, 0, "the sealer was never spoken to")
        let liar = res.sealAndQueue(Data(repeating: 0x11, count: 100), sealer: { p in
            sealerCalls += 1
            return Data(count: p.count + RecordWriter.sealOverheadBytes - 1)   // one octet short
        })
        if case .refused(let why) = liar {
            XCTAssertEqual(why, "the seal lied about the envelope")
        } else { XCTFail("the lie must be refused, saw \(liar)") }
        XCTAssertEqual(sealerCalls, 1, "the seal was asked once, and its lie told")
        XCTAssertEqual(conn.peekOutboundSequence(), seqBefore, "the sequence number stands")
        XCTAssertEqual(writer.admittedCount(), 0, "nothing was staged by the two refusals")
        XCTAssertEqual(writer.stagedValues(), 0)
    }

    // MARK: case 9: a refused update retains the very same fragment

    func testUpdateValueFalseRetainsTheSameFragment() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        let bobFactory = CaptureFactory()
        let bob = BleTransport(identity: pair.bobIdentity, store: nil,
                               sessions: pair.bobManager, managerFactory: bobFactory,
                               clock: TestClock(startingAt: 9_705))
        let (pmOpt, why) = try responderReady(bob, centralId: centralId,
                                              remoteHint: pair.aliceIdentity.nodeHint)
        guard let pm = pmOpt else { XCTFail(why); return }
        var remainingRefusals = 2
        pm.updateAnswer = { _ in
            if remainingRefusals > 0 { remainingRefusals -= 1; return false }
            return true
        }
        let space = 512 - BleRecordConstants.headerBytes
        guard let f = frameOfExactEncodedLength(3 * space - RecordWriter.sealOverheadBytes) else {
            XCTFail("calibration failed"); return
        }
        XCTAssertEqual(bob.send(f, to: centralId), .backpressured, "the first attempt is refused")
        bob.processPeripheralIsReadyToUpdateSubscribers(pm, sourceEpoch: bob.currentTransportEpoch)
        XCTAssertEqual(bob.responderWriterForTest(centralId)?.stagedValues() ?? -1, 3,
                       "all three values still wait; none is dropped")
        let att = pm.updateAttempts
        XCTAssertEqual(att.count, 2, "two refusals stand recorded")
        XCTAssertTrue(att[0] == att[1], "the retry speaks the very same ciphertext, unaltered")
        let writer = bob.responderWriterForTest(centralId)
        XCTAssertEqual(writer?.operationsIssuedCount() ?? 0, 1, "the record was fragmented once, not twice")
        bob.processPeripheralIsReadyToUpdateSubscribers(pm, sourceEpoch: bob.currentTransportEpoch)
        XCTAssertEqual(pm.capturedUpdates.count, 3, "at last all three flow out")
        let att2 = pm.updateAttempts
        XCTAssertTrue(att2[0] == att2[1] && att2[1] == att2[2], "the retained fragment never changed")
        XCTAssertTrue(att2[2] == pm.capturedUpdates[0].bytes)
        bob.stop()
    }

    // MARK: case 10: the notification travels by the very handle retained

    func testNotificationTravelsByTheRetainedCentralAlone() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        let bobFactory = CaptureFactory()
        let bob = BleTransport(identity: pair.bobIdentity, store: nil,
                               sessions: pair.bobManager, managerFactory: bobFactory,
                               clock: TestClock(startingAt: 9_706))
        let (pmOpt, why) = try responderReady(bob, centralId: centralId,
                                               remoteHint: pair.aliceIdentity.nodeHint)
        guard let pm = pmOpt else { XCTFail(why); return }
        let f = makeFrame([7, 7, 7, 7])
        XCTAssertEqual(bob.send(f, to: centralId), .admitted)
        let records = bob.responderSendRecordsForTest()
        XCTAssertEqual(records.count, 1, "the single value, recorded as the responder sent it")
        XCTAssertTrue(records.allSatisfy { $0.viaRetained }, "by the handle retained, never by a lookup")
        let first = records[0].via
        XCTAssertTrue(records.allSatisfy { $0.via == first }, "all updates share the one retained handle")
        XCTAssertTrue(pm.capturedUpdates.allSatisfy { $0.central == centralId },
                      "every update is addressed to the subscribed central it was made for")
        bob.stop()
    }

    // MARK: case 11: a stale manager's readiness moves nothing

    func testAStaleManagersReadinessMovesNothing() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        let bobFactory = CaptureFactory()
        let bob = BleTransport(identity: pair.bobIdentity, store: nil,
                               sessions: pair.bobManager, managerFactory: bobFactory,
                               clock: TestClock(startingAt: 9_707))
        let (pmOpt, why) = try responderReady(bob, centralId: centralId,
                                              remoteHint: pair.aliceIdentity.nodeHint)
        guard let pm = pmOpt else { XCTFail(why); return }
        var accepts = false
        pm.updateAnswer = { _ in accepts }
        let f = makeFrame([9, 8, 7, 6, 5, 4])
        XCTAssertEqual(bob.send(f, to: centralId), .backpressured, "values wait in the window")
        let staleEpoch = bob.currentTransportEpoch
        let staleAttempts = pm.updateAttempts.count
        bob.stop()                                     // the writers are purged with the context
        bob.start()                                    // a fresh context, a fresh pair, a fresh epoch
        XCTAssertNotEqual(bob.currentTransportEpoch, staleEpoch, "the epoch moved on")
        // Re-establish the selfsame relation upon the fresh context, so a
        // live window stands ready to be moved - and can be proved unmoved
        // by a pretender's call.
        let (reOpt, reWhy) = try responderReady(bob, centralId: centralId,
                                                remoteHint: pair.aliceIdentity.nodeHint)
        guard reOpt != nil else { XCTFail("re-establishment: " + reWhy); return }
        guard let fresh = bob.requireContextPeripheralForTest() as? CapturePeripheralManager else {
            XCTFail("the fresh context made no capture manager"); return
        }
        XCTAssertFalse(fresh === pm, "another manager stands in its place")
        var acceptsAgain = false
        fresh.updateAnswer = { _ in acceptsAgain }
        XCTAssertEqual(bob.send(f, to: centralId), .backpressured, "the fresh window takes the value")
        let freshAttempts = fresh.updateAttempts.count
        XCTAssertGreaterThan(freshAttempts, 0, "the send itself attempted through the fresh handle")
        // The stale manager reports readiness for the old epoch: the
        // threefold authentication must repel it, and the live window must
        // stand unmoved - attempts, staging and all.
        bob.processPeripheralIsReadyToUpdateSubscribers(pm, sourceEpoch: staleEpoch)
        XCTAssertEqual(fresh.updateAttempts.count, freshAttempts,
                       "the stale manager's readiness moved nothing")
        XCTAssertEqual(pm.updateAttempts.count, staleAttempts, "and the old handle stays as it was")
        let writerAfter = bob.responderWriterForTest(centralId)
        XCTAssertNotNil(writerAfter, "the values yet wait in the new window")
        XCTAssertGreaterThan(writerAfter?.stagedValues() ?? 0, 0, "untouched by the pretender")
        // The true manager's report moves them indeed.
        acceptsAgain = true
        bob.processPeripheralIsReadyToUpdateSubscribers(fresh, sourceEpoch: bob.currentTransportEpoch)
        XCTAssertEqual(writerAfter?.stagedValues() ?? -1, 0, "the real readiness drains the window")
        bob.stop()
    }

    // MARK: case 13: the stalled write leg holds its values and resumes as they were staged

    func testTheStalledWriteLegHoldsItsValuesAndResumesAsTheyWereStaged() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let peerId = pair.viaBob
        let alice = BleTransport(identity: pair.aliceIdentity, store: T17MessageStore(),
                                 sessions: pair.aliceManager, managerFactory: CaptureFactory(),
                                 clock: TestClock(startingAt: 9_709))
        alice.start()
        let (peerHandle, capturePeer) = peripheralPunt(peerId)
        capturePeer.canSendWriteWithoutResponse = false          // the leg is stalled
        guard let delegate = advanceToRoleBound(alice, peerId: peerId,
                                                serviceDataHint: ReadinessT19Tests.greaterHint(than: pair.aliceIdentity.nodeHint),
                                                capturePeer: capturePeer) else {
            XCTFail("the initiator never stood a connection: " + walkLog.joined(separator: " | ")); return
        }
        alice.connection(for: peerId)?.markReadyForTesting()
        let space = capturePeer.maxWrite - BleRecordConstants.headerBytes
        guard let f = frameOfExactEncodedLength(3 * space - RecordWriter.sealOverheadBytes) else {
            XCTFail("the calibration of the three-value frame failed"); return
        }
        XCTAssertEqual(alice.send(f, to: peerId), .backpressured, "the stalled leg refuses the hand")
        let writer = alice.centralWriterForTest(peerId)
        XCTAssertNotNil(writer, "the direction's writer stands")
        XCTAssertEqual(writer?.stagedValues() ?? -1, 3, "all three values wait; none is claimed away")
        XCTAssertNil(writer?.inFlightOperation(), "nothing flies while the leg is barred")
        XCTAssertTrue(capturePeer.writes.isEmpty, "the barred leg carried nothing out")
        // The very context reports itself ready again: the window drains in order.
        capturePeer.canSendWriteWithoutResponse = true
        alice.processPeripheralIsReady(peerHandle, delegate: delegate)
        XCTAssertEqual(capturePeer.writes.count, 3, "the three values flow out, in the order staged")
        XCTAssertEqual(writer?.stagedValues() ?? -1, 0, "the window stands empty")
        XCTAssertEqual(writer?.admittedCount() ?? -1, 0, "the record retired whole")
        XCTAssertTrue(fragIndexIsHead(capturePeer.writes[0]), "the first value leads as the head")
        alice.stop()
    }

    // MARK: case 12: the two directions fragment at their own maxima

    func testFragmentationDiffersByTheirDirections() throws {
        // One record, two legs, two maxima: the write leg and the update leg
        // speak their own capacities, and the reservation is made against
        // the maximum of the direction the record is travelling.
        // The whole-chain idiom: the ladders walk while the transports are
        // yet unstarted, each reading the other's advertised link-info; the
        // initiator starts only after her legs are through, and the pair is
        // wired for business by the real pairing entry.
        let pair = try ReadinessTrustedPairing.barePair()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let aliceFactory = CaptureFactory()
        let bobFactory = CaptureFactory()
        let alice = BleTransport(identity: pair.aliceIdentity, store: T17MessageStore(),
                                 sessions: pair.aliceManager, managerFactory: aliceFactory,
                                 clock: TestClock(startingAt: 9_708))
        let bob = BleTransport(identity: pair.bobIdentity, store: nil,
                               sessions: pair.bobManager, managerFactory: bobFactory,
                               clock: TestClock(startingAt: 9_708))
        let handleB = UUID()   // how alice names bob
        let handleA = UUID()   // how bob names alice
        let aliceHint = pair.aliceIdentity.nodeHint
        let bobHint = pair.bobIdentity.nodeHint
        let (_, capturePeer) = peripheralPunt(handleB)
        capturePeer.maxWrite = 20                      // the write leg speaks the minimum
        _ = advanceToRoleBound(alice, peerId: handleB, serviceDataHint: bobHint,
                               capturePeer: capturePeer)
        alice.start()
        guard let aConn = alice.connection(for: handleB) else {
            XCTFail("the initiator never stood a connection: " + walkLog.joined(separator: " | ")); return
        }
        aConn.markReadyForTesting()
        let (pmOpt, why) = try responderReady(bob, centralId: handleA,
                                              remoteHint: aliceHint, updateCapacity: 247)
        guard let pm = pmOpt else { XCTFail(why); return }
        try ReadinessTrustedPairing.pairUp(pair, viaBob: handleB, viaAlice: handleA,
                                           aliceHint: aliceHint, bobHint: bobHint)
        let sealed = 5024
        guard let f = frameOfExactEncodedLength(sealed - RecordWriter.sealOverheadBytes) else {
            XCTFail("calibration of the long frame failed"); return
        }
        XCTAssertEqual(f.encode().count + RecordWriter.sealOverheadBytes, sealed)
        let verdict = alice.send(f, to: handleB)
        if case .rejected(let reason) = verdict {
            XCTAssertTrue(reason.contains("sealed 5024"), "the refusal names the sealed length: " + reason)
            XCTAssertTrue(reason.contains("against 768"), "and the write leg's ceiling: " + reason)
            XCTAssertTrue(reason.contains("in 419 fragments"), "and the count it would have needed: " + reason)
        } else { XCTFail("the write leg must refuse at the reservation, saw \(verdict)"); return }
        XCTAssertTrue(capturePeer.writes.isEmpty, "nothing was sealed for the leg that cannot carry it")
        XCTAssertEqual(bob.send(f, to: handleA), .admitted,
                       "what the write leg refused, the update leg carries")
        XCTAssertEqual(pm.capturedUpdates.count, 22, "twenty-two fractions at the central's 239-octet space")
        XCTAssertTrue(pm.capturedUpdates.allSatisfy { $0.bytes.count <= 247 },
                      "no fraction outruns the direction's own maximum")
        var total = 0
        for u in pm.capturedUpdates { total += u.bytes.count - BleRecordConstants.headerBytes }
        XCTAssertEqual(total, sealed, "one record, whole, by the other direction's law")
        alice.stop(); bob.stop()
    }
}
