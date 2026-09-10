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
final class ReadinessT20Tests: XCTestCase {

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
                ReadinessT20Tests.remoteLinkInfoStatic(hint: serviceDataHint)]
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
                                                          service: ReadinessT20Tests.provisionedService(), error: nil)
        walkLog.append("characteristics -> " + String(describing: a2) + " @ " + (alice.connection(for: peerId).map { String(describing: $0.state) } ?? "nil"))
        let linkInfoChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: ReadinessT20Tests.remoteLinkInfoStatic(hint: serviceDataHint),
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
                                        rawData: ReadinessT20Tests.remoteLinkInfoStatic(hint: remoteHint),
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
            if ReadinessT20Tests.hintAscending(c, local) { return c }
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
            if ReadinessT20Tests.hintAscending(local, c) { return c }
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
                                updateCapacity: Int = 512,
                                leaseClock: (() -> TimeInterval)? = nil) throws -> (CapturePeripheralManager?, String) {
        bob.start()
        if let leaseClock = leaseClock {
            bob.peripheralDriver?.connectionClockForTest = leaseClock
        }
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

    // MARK: - T20 the lifetime schedules: the absolute lease, the wrap, the trace
    //
    // The same identical schedules the Android island runs, in this island's
    // speech: the absolute term no refresh moves; the gate that refuses the
    // stranger before the reassembler ever sees it; the sequence that wraps
    // at two hundred fifty six with the framing untouched; the trace that
    // speaks only through injected identities; the fall that closes through
    // the owner's arm alone; and the ledger that reports every check.

    private func clearOf(_ marker: Int, _ len: Int) -> [UInt8] {
        return (0..<len).map { i in
            if i == 0 { return UInt8(marker & 0xFF) }
            if i == 1 { return UInt8((marker >> 8) & 0xFF) }
            return UInt8((i &* 7 &+ 13 &+ marker) % 251)
        }
    }

    /// Seals n whole records through the initiator's writer and brings back
    /// the fragments exactly as the outlet captured them.
    private func sealRecords(_ n: Int, marker base: Int, clearLen: Int,
                             via alice: BleTransport, peerId: UUID,
                             capturePeer: CapturePeripheral) -> [(seq: Int, frags: [Data])] {
        var out: [(seq: Int, frags: [Data])] = []
        for k in 0..<n {
            let f = makeFrame(clearOf(base &+ k, clearLen))
            capturePeer.clearWrites()
            let verdict = alice.send(f, to: peerId)
            XCTAssertEqual(verdict, .admitted, "the writer must admit the whole record")
            let captured = capturePeer.writes
            XCTAssertFalse(captured.isEmpty, "the pump delivered nothing")
            out.append((Int(captured[0][2]), captured))
        }
        return out
    }

    /// Stands the initiator beside the pair, wired to the managers the
    /// pairing established, and brings the role up to the ready state.
    private func standInitiator(_ pair: ReadinessTrustedPairing.Pair) throws
        -> (BleTransport, CapturePeripheral) {
        let alice = BleTransport(identity: pair.aliceIdentity, store: T17MessageStore(),
                                 sessions: pair.aliceManager, managerFactory: CaptureFactory(),
                                 clock: TestClock(startingAt: 9_700))
        alice.start()
        let (peerHandle, capturePeer) = peripheralPunt(pair.viaBob)
        _ = peerHandle
        _ = advanceToRoleBound(alice, peerId: pair.viaBob,
                               serviceDataHint: ReadinessT20Tests.greaterHint(
                                   than: pair.aliceIdentity.nodeHint),
                       capturePeer: capturePeer)
        alice.connection(for: pair.viaBob)?.markReadyForTesting()
        return (alice, capturePeer)
    }

    private func awaitTrue(limit: Int = 400, _ predicate: () -> Bool) -> Bool {
        for _ in 0..<limit {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }

    /// The adapter-facing trace fixture. It keeps the ledger of the manager
    /// identities the factory injected and delivers trace events through
    /// the very production entries the platform's own callbacks travel.
    /// Every argument is one the real callback passes; the fixture invents
    /// nothing. An event naming a manager identity that was never injected,
    /// or a peer other than the one the identity was injected with, is
    /// refused at the fixture and makes no delivery at all.
    private final class AdapterTraceFixture {
        private let presenter: (UUID) -> CBCentral
        private var injected: [UInt64: (CBPeripheralManager, UUID)] = [:]
        private var pins: [Any] = []
        private(set) var deliveries: [String] = []

        init(presenter: @escaping (UUID) -> CBCentral) { self.presenter = presenter }

        func inject(_ identity: UInt64, _ manager: CBPeripheralManager, _ address: UUID) {
            injected[identity] = (manager, address)
        }

        func canDeliver(_ source: AdapterCallbackSource) -> Bool {
            switch source {
            case .didUpdateState, .didWriteValue: return true
            default: return false
            }
        }

        func deliver(_ trace: AdapterTraceEvent, to bob: BleTransport) -> Int {
            guard let named = injected[trace.managerIdentity] else { return 0 }
            if let dev = trace.deviceUUID, dev != named.1 { return 0 }
            switch trace.source {
            case .didUpdateState:
                deliveries.append("didUpdateState@" + named.1.uuidString)
                return 1
            case .didWriteValue:
                guard let bytes = trace.payload, !bytes.isEmpty else { return 0 }
                let req = CaptureRequest(centralId: named.1, pinnedCentral: presenter(named.1),
                                        value: bytes)
                pins.append(req)
                bob.processPeripheralReceiveWrite(
                    named.0,
                    requests: [unsafeBitCast(req, to: CBATTRequest.self)],
                    sourceEpoch: trace.epochAtDelivery)
                deliveries.append("didWriteValue@" + named.1.uuidString)
                return 1
            default:
                return 0
            }
        }
    }

    func testTheAbsoluteTermExpiresTheDribbledAssemblyThoughTheSlidingWindowIsRefreshed() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        var now = TimeInterval(1_700_000_000)
        let bob = BleTransport(identity: pair.bobIdentity, store: T17MessageStore(),
                               sessions: pair.bobManager, managerFactory: CaptureFactory(),
                               clock: TestClock(startingAt: 9_700))
        let (pm, why) = try responderReady(bob, centralId: centralId,
                                       remoteHint: pair.aliceIdentity.nodeHint,
                                       leaseClock: { now })
        guard let pm = pm else { XCTFail("the responder never stood ready: " + why); return }
        guard let conn = bob.connection(for: centralId) else {
            XCTFail("the responder has no connection"); return
        }
        let (alice, capturePeer) = try standInitiator(pair)
        let sealed = sealRecords(1, marker: 7, clearLen: 1888, via: alice,
                                 peerId: pair.viaBob, capturePeer: capturePeer)
        let frags = sealed[0].frags
        XCTAssertGreaterThanOrEqual(frags.count, 3, "the record must outlive its term only on paper")
        for i in 0..<(frags.count - 1) {
            pushWrite(bob, pm, centralId: centralId, bytes: frags[i])
            now = TimeInterval(1_700_000_000) + TimeInterval(4 * i)  // every gap sits well under the sliding term
        }
        let seq = UInt8(sealed[0].seq)
        guard let firstLease = conn.activeLeaseOf(seq) else {
            XCTFail("the admission left no lease standing"); return
        }
        XCTAssertEqual(firstLease.deadlineMono, TimeInterval(1_700_000_000) + 30,
                       "the term is absolute: thirty seconds from the admission")
        // the last fraction arrives at the very instant of the term: the
        // absolute strikes first, the sliding courtesy has not yet earned
        // its silence
        now = firstLease.deadlineMono + 1
        pushWrite(bob, pm, centralId: centralId, bytes: frags[frags.count - 1])
        XCTAssertNil(bob.connection(for: centralId),
                     "the relation fell when the absolute term passed")
        XCTAssertNil(conn.activeLeaseOf(seq), "the close purged the registers whole")
        pushWrite(bob, pm, centralId: centralId, bytes: frags[0])
        XCTAssertNil(conn.activeLeaseOf(seq), "the shut door admits no later traffic")
        bob.stop()
        alice.stop()
    }

    func testFourWholeRecordsArePinnedAndTheFifthIsRefusedItsSlot() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        var now = TimeInterval(1_700_000_000)
        let bob = BleTransport(identity: pair.bobIdentity, store: T17MessageStore(),
                               sessions: pair.bobManager, managerFactory: CaptureFactory(),
                               clock: TestClock(startingAt: 9_700))
        let (pm, why) = try responderReady(bob, centralId: centralId,
                                       remoteHint: pair.aliceIdentity.nodeHint,
                                       leaseClock: { now })
        guard let pm = pm else { XCTFail("the responder never stood ready: " + why); return }
        guard let conn = bob.connection(for: centralId) else {
            XCTFail("the responder has no connection"); return
        }
        let (alice, capturePeer) = try standInitiator(pair)
        let sealed = sealRecords(5, marker: 11, clearLen: 600, via: alice,
                                 peerId: pair.viaBob, capturePeer: capturePeer)
        for k in 0..<4 {
            pushWrite(bob, pm, centralId: centralId, bytes: sealed[k].frags[0])
        }
        XCTAssertEqual(conn.leaseCount(), 4, "four leases stand pinned")
        pushWrite(bob, pm, centralId: centralId, bytes: sealed[4].frags[0])
        XCTAssertEqual(conn.leaseCount(), 4, "the fifth concurrent assembly is refused its slot")
        XCTAssertNil(conn.activeLeaseOf(UInt8(sealed[4].seq)),
                     "the refused admission left no lease behind")
        XCTAssertNotNil(bob.connection(for: centralId), "the relation did not fall on the refusal")
        bob.stop()
        alice.stop()
    }

    func testTheSequenceWrapsAtTwoHundredFiftySixWholeRecordsAndTheDuplicateIsRefused() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        var now = TimeInterval(1_700_000_000)
        let recorder = T17DelegateSpy()
        let bob = BleTransport(identity: pair.bobIdentity, store: T17MessageStore(),
                               sessions: pair.bobManager, managerFactory: CaptureFactory(),
                               clock: TestClock(startingAt: 9_700))
        bob.delegate = recorder
        pins.append(recorder)
        let (pm, why) = try responderReady(bob, centralId: centralId,
                                       remoteHint: pair.aliceIdentity.nodeHint,
                                       leaseClock: { now })
        guard let pm = pm else { XCTFail("the responder never stood ready: " + why); return }
        let (alice, capturePeer) = try standInitiator(pair)
        let sealed = sealRecords(257, marker: 1500, clearLen: 4, via: alice,
                                 peerId: pair.viaBob, capturePeer: capturePeer)
        var observed: [Int] = []
        var pushes = 0
        for k in 0..<257 {
            for frag in sealed[k].frags {
                pushWrite(bob, pm, centralId: centralId, bytes: frag)
            }
            observed.append(sealed[k].seq)
            pushes += 1
            if pushes % 32 == 0 {
                _ = awaitTrue { recorder.received.count >= pushes }
            }
        }
        XCTAssertTrue(awaitTrue(limit: 2000) { recorder.received.count == 257 },
                      "two hundred fifty seven whole records arrived across the wrap")
        for i in 1..<observed.count {
            XCTAssertEqual(observed[i], (observed[i - 1] + 1) % 256,
                           "the carried sequence advances by one across the wrap, bit by bit")
        }
        XCTAssertTrue(zip(observed, observed.dropFirst()).contains { (a, b) in a == 255 && b == 0 },
                      "the wrap itself was witnessed at the crossing of two hundred fifty five")
        for frag in sealed[0].frags {
            pushWrite(bob, pm, centralId: centralId, bytes: frag)
        }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(recorder.received.count, 257,
                       "a completed record delivered twice changes nothing")
        bob.stop()
        alice.stop()
    }

    func testTheStaleStragglerAtTheWrapFailsClosedAtTheGateAndTheRetransmissionCompletes() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        var now = TimeInterval(1_700_000_000)
        let recorder = T17DelegateSpy()
        let bob = BleTransport(identity: pair.bobIdentity, store: T17MessageStore(),
                               sessions: pair.bobManager, managerFactory: CaptureFactory(),
                               clock: TestClock(startingAt: 9_700))
        bob.delegate = recorder
        pins.append(recorder)
        let (pm, why) = try responderReady(bob, centralId: centralId,
                                       remoteHint: pair.aliceIdentity.nodeHint,
                                       leaseClock: { now })
        guard let pm = pm else { XCTFail("the responder never stood ready: " + why); return }
        guard let conn = bob.connection(for: centralId) else {
            XCTFail("the responder has no connection"); return
        }
        let (alice, capturePeer) = try standInitiator(pair)
        let sealed = sealRecords(1, marker: 4242, clearLen: 600, via: alice,
                                 peerId: pair.viaBob, capturePeer: capturePeer)
        let seq = UInt8(sealed[0].seq)
        let trueFrags = sealed[0].frags
        for frag in trueFrags.dropLast() {
            pushWrite(bob, pm, centralId: centralId, bytes: frag)
        }
        XCTAssertNotNil(conn.activeLeaseOf(seq), "the assembly stands mid-way on its lease")
        // a straggler of the elder epoch: the same sequence, another shape
        var head = Data(trueFrags[0].prefix(8))
        head[3] = 0
        head[4] = UInt8(trueFrags.count + 1)
        head[5] = UInt8((624 + 101) >> 8)
        head[6] = UInt8((624 + 101) & 0xFF)
        let straggler = head + Data(repeating: 0x42, count: 60)
        let ringBefore = bob.rejectionRecordsForTest().count
        pushWrite(bob, pm, centralId: centralId, bytes: straggler)
        XCTAssertNotNil(conn.activeLeaseOf(seq),
                        "the gate refused the stranger; the assembly stands unharmed")
        XCTAssertEqual(recorder.received.count, 0, "the refused straggler admitted nothing")
        XCTAssertGreaterThan(bob.rejectionRecordsForTest().count, ringBefore,
                             "the rejection ring names the stranger at the write door")
        for frag in trueFrags {
            pushWrite(bob, pm, centralId: centralId, bytes: frag)
        }
        XCTAssertTrue(awaitTrue { recorder.received.count == 1 },
                      "the record arrived whole after the straggler")
        bob.stop()
        alice.stop()
    }

    func testTheIdempotentDuplicateStandsAndTheConflictingDuplicateFailsClosed() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        var now = TimeInterval(1_700_000_000)
        let recorder = T17DelegateSpy()
        let bob = BleTransport(identity: pair.bobIdentity, store: T17MessageStore(),
                               sessions: pair.bobManager, managerFactory: CaptureFactory(),
                               clock: TestClock(startingAt: 9_700))
        bob.delegate = recorder
        pins.append(recorder)
        let (pm, why) = try responderReady(bob, centralId: centralId,
                                       remoteHint: pair.aliceIdentity.nodeHint,
                                       leaseClock: { now })
        guard let pm = pm else { XCTFail("the responder never stood ready: " + why); return }
        guard let conn = bob.connection(for: centralId) else {
            XCTFail("the responder has no connection"); return
        }
        let (alice, capturePeer) = try standInitiator(pair)
        let sealed = sealRecords(1, marker: 77, clearLen: 1100, via: alice,
                                 peerId: pair.viaBob, capturePeer: capturePeer)
        let seq = UInt8(sealed[0].seq)
        pushWrite(bob, pm, centralId: centralId, bytes: sealed[0].frags[0])
        pushWrite(bob, pm, centralId: centralId, bytes: sealed[0].frags[0])   // the selfsame bytes
        XCTAssertNotNil(conn.activeLeaseOf(seq),
                        "the idempotent duplicate left the assembly standing")
        XCTAssertEqual(recorder.received.count, 0, "the duplicate admitted nothing new")
        var conflicting = Data(sealed[0].frags[0].prefix(8))
        conflicting.append(Data(repeating: 0xEE, count: sealed[0].frags[0].count - 8))
        pushWrite(bob, pm, centralId: centralId, bytes: conflicting)           // same index, other bytes
        XCTAssertNil(conn.activeLeaseOf(seq), "the conflicting duplicate failed closed")
        XCTAssertEqual(recorder.received.count, 0, "the conflict admitted nothing")
        bob.stop()
        alice.stop()
    }

    func testTheCrossedTraceFromAForeignManagerIsRefusedAndTheWrongTokenDiscarded() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        var now = TimeInterval(1_700_000_000)
        let bob = BleTransport(identity: pair.bobIdentity, store: T17MessageStore(),
                               sessions: pair.bobManager, managerFactory: CaptureFactory(),
                               clock: TestClock(startingAt: 9_700))
        let (pm, why) = try responderReady(bob, centralId: centralId,
                                       remoteHint: pair.aliceIdentity.nodeHint,
                                       leaseClock: { now })
        guard let pm = pm else { XCTFail("the responder never stood ready: " + why); return }
        guard let conn = bob.connection(for: centralId) else {
            XCTFail("the responder has no connection"); return
        }
        let gen = bob.peripheralDriver?.getCentralGeneration(centralId) ?? 0
        let trueManager = bob.requireContextPeripheralForTest()
        let fixture = AdapterTraceFixture(presenter: { id in self.centralPresent(id) })
        fixture.inject(UInt64(ObjectIdentifier(trueManager).hashValue & 0x7FFF_FFFF_FFFF_FFFF),
                       trueManager, centralId)
        let alien = CapturePeripheralManager(delegate: nil, queue: DispatchQueue.main)
        let crossed = AdapterTraceEvent(
            source: .didUpdateState, deviceUUID: centralId, propertyValue: nil, payload: nil,
            managerIdentity: UInt64(ObjectIdentifier(alien).hashValue & 0x7FFF_FFFF_FFFF_FFFF),
            epochAtDelivery: bob.currentTransportEpoch)
        XCTAssertEqual(fixture.deliver(crossed, to: bob), 0,
                       "a trace from an uninjected manager makes no delivery")
        XCTAssertNotNil(bob.connection(for: centralId), "the registry stands where it stood")
        // the production entry discards the misdocumented terminal
        _ = bob.reductionProcessInboundUnsubscribe(centralId: centralId, expectedGen: gen + 7,
                                                  characteristic: nil,
                                                  sourceEpoch: bob.currentTransportEpoch,
                                                  from: trueManager)
        XCTAssertNotNil(bob.connection(for: centralId),
                        "a terminal naming the wrong generation is discarded")
        XCTAssertTrue(bob.isRelationPublished(direction: .inboundPeripheral, peerId: centralId,
                                              generation: gen),
                      "the publication of the relation stands")
        // the true trace, through the injected identity, reaches its entry
        let trueTrace = AdapterTraceEvent(
            source: .didUpdateState, deviceUUID: centralId, propertyValue: nil, payload: nil,
            managerIdentity: UInt64(ObjectIdentifier(trueManager).hashValue & 0x7FFF_FFFF_FFFF_FFFF),
            epochAtDelivery: bob.currentTransportEpoch)
        XCTAssertEqual(fixture.deliver(trueTrace, to: bob), 1,
                       "the trace of the injected manager reaches the production entry")
        bob.stop()
    }

    func testTheMisdatedTerminalFromThePastChangesNothing() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        var now = TimeInterval(1_700_000_000)
        let bob = BleTransport(identity: pair.bobIdentity, store: T17MessageStore(),
                               sessions: pair.bobManager, managerFactory: CaptureFactory(),
                               clock: TestClock(startingAt: 9_700))
        let (pm, why) = try responderReady(bob, centralId: centralId,
                                       remoteHint: pair.aliceIdentity.nodeHint,
                                       leaseClock: { now })
        guard let pm = pm else { XCTFail("the responder never stood ready: " + why); return }
        let gen = bob.peripheralDriver?.getCentralGeneration(centralId) ?? 0
        bob.publishRelation(RelationKey(direction: .inboundPeripheral, peerId: centralId,
                                        generation: gen))
        XCTAssertTrue(bob.isRelationPublished(direction: .inboundPeripheral, peerId: centralId,
                                              generation: gen),
                      "the responder relation stands published")
        let trueManager = bob.requireContextPeripheralForTest()
        _ = bob.reductionProcessInboundUnsubscribe(centralId: centralId, expectedGen: gen + 1,
                                                  characteristic: nil,
                                                  sourceEpoch: bob.currentTransportEpoch,
                                                  from: trueManager)
        XCTAssertNotNil(bob.connection(for: centralId),
                        "a terminal for another generation changes nothing")
        XCTAssertTrue(bob.isRelationPublished(direction: .inboundPeripheral, peerId: centralId,
                                              generation: gen),
                      "the publication stands")
        bob.stop()
    }

    func testTheSilentPeerFallsToTheHeartbeatAlone() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        var now = TimeInterval(1_700_000_000)
        let recorder = T17DelegateSpy()
        let bob = BleTransport(identity: pair.bobIdentity, store: T17MessageStore(),
                               sessions: pair.bobManager, managerFactory: CaptureFactory(),
                               clock: TestClock(startingAt: 9_700))
        bob.delegate = recorder
        pins.append(recorder)
        let (pm, why) = try responderReady(bob, centralId: centralId,
                                       remoteHint: pair.aliceIdentity.nodeHint,
                                       leaseClock: { now })
        guard let pm = pm else { XCTFail("the responder never stood ready: " + why); return }
        guard let conn = bob.connection(for: centralId) else {
            XCTFail("the responder has no connection"); return
        }
        let gen = bob.peripheralDriver?.getCentralGeneration(centralId) ?? 0
        bob.publishRelation(RelationKey(direction: .inboundPeripheral, peerId: centralId,
                                        generation: gen))
        XCTAssertTrue(bob.isRelationPublished(direction: .inboundPeripheral, peerId: centralId,
                                              generation: gen),
                      "the hand-standing publication is witnessed")
        let (alice, capturePeer) = try standInitiator(pair)
        let sealed = sealRecords(1, marker: 909, clearLen: 1100, via: alice,
                                 peerId: pair.viaBob, capturePeer: capturePeer)
        let seq = UInt8(sealed[0].seq)
        for frag in sealed[0].frags.prefix(2) {
            pushWrite(bob, pm, centralId: centralId, bytes: frag)
        }
        guard let lease = conn.activeLeaseOf(seq) else {
            XCTFail("the admission left no lease"); return
        }
        // the peer falls silent altogether: no delivery ever arrives again
        now = lease.deadlineMono
        bob.sweepInboundLeases()
        XCTAssertNil(bob.connection(for: centralId),
                     "the silent relation fell through the heartbeat alone")
        XCTAssertFalse(bob.isRelationPublished(direction: .inboundPeripheral, peerId: centralId,
                                               generation: gen),
                       "the publication was withdrawn with it")
        XCTAssertEqual(recorder.received.count, 0, "nothing was admitted of the silent dribble")
        bob.stop()
        alice.stop()
    }

    func testTheRaceAtTheDeadlineInstantSettlesTheSameBothWays() throws {
        let pair = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pair) }
        let centralId = pair.viaAlice
        var now = TimeInterval(1_700_000_000)
        let recorder = T17DelegateSpy()
        let bob = BleTransport(identity: pair.bobIdentity, store: T17MessageStore(),
                               sessions: pair.bobManager, managerFactory: CaptureFactory(),
                               clock: TestClock(startingAt: 9_700))
        bob.delegate = recorder
        pins.append(recorder)
        let (pm, why) = try responderReady(bob, centralId: centralId,
                                       remoteHint: pair.aliceIdentity.nodeHint,
                                       leaseClock: { now })
        guard let pm = pm else { XCTFail("the responder never stood ready: " + why); return }
        guard let conn = bob.connection(for: centralId) else {
            XCTFail("the responder has no connection"); return
        }
        let (alice, capturePeer) = try standInitiator(pair)
        let sealed = sealRecords(2, marker: 31, clearLen: 600, via: alice,
                                 peerId: pair.viaBob, capturePeer: capturePeer)
        // (a) the sweep one instant short of the term finds nothing lapsed
        pushWrite(bob, pm, centralId: centralId, bytes: sealed[0].frags[0])
        let seqA = UInt8(sealed[0].seq)
        guard let lease = conn.activeLeaseOf(seqA) else {
            XCTFail("no lease for the half-open record"); return
        }
        conn.sweepLeasesAt(lease.deadlineMono - 1)
        XCTAssertNotNil(conn.activeLeaseOf(seqA), "one instant short of the term the assembly stands")
        XCTAssertNotNil(bob.connection(for: centralId), "and the relation stands with it")
        // (b) at the very instant the term passes, the sweep takes the lapsed lease
        conn.sweepLeasesAt(lease.deadlineMono)
        XCTAssertNil(conn.activeLeaseOf(seqA), "at the term itself the lease is released")
        XCTAssertNotNil(conn.peekLeaseExpiryNotice(),
                        "the sweep at the term raised the notice for its owner alone")
        _ = conn.takeLeaseExpiryNotice()
        // (c) a record completed before its term leaves nothing to lapse
        for frag in sealed[1].frags {
            pushWrite(bob, pm, centralId: centralId, bytes: frag)
        }
        XCTAssertTrue(awaitTrue { recorder.received.count == 1 },
                      "the record completed while its term still ran")
        conn.sweepLeasesAt(lease.deadlineMono + 40)
        XCTAssertNil(conn.activeLeaseOf(UInt8(sealed[1].seq)),
                     "the completed record left no lease behind")
        XCTAssertNotNil(bob.connection(for: centralId),
                        "the relation of a completed record does not fall")
        bob.stop()
        alice.stop()
    }

    func testTheLedgerOfInvariantsStandsWholeAndReportsEveryCheck() throws {
        let ledger = InvariantLedger(owner: "T20 ios identical schedules")
        // schedule A: the dribbled assembly to its fall, upon one rig
        let pairA = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pairA) }
        var now = TimeInterval(1_700_000_000)
        let base = now
        let bobA = BleTransport(identity: pairA.bobIdentity, store: T17MessageStore(),
                                sessions: pairA.bobManager, managerFactory: CaptureFactory(),
                                clock: TestClock(startingAt: 9_700))
        let (pmA, whyA) = try responderReady(bobA, centralId: pairA.viaAlice,
                                         remoteHint: pairA.aliceIdentity.nodeHint,
                                         leaseClock: { now })
        guard let pmA = pmA else { XCTFail("responder A never stood ready: " + whyA); return }
        guard let connA = bobA.connection(for: pairA.viaAlice) else {
            XCTFail("responder A has no connection"); return
        }
        let genA = bobA.peripheralDriver?.getCentralGeneration(pairA.viaAlice) ?? 0
        bobA.publishRelation(RelationKey(direction: .inboundPeripheral, peerId: pairA.viaAlice,
                                         generation: genA))
        XCTAssertTrue(bobA.isRelationPublished(direction: .inboundPeripheral,
                                               peerId: pairA.viaAlice, generation: genA),
                      "the hand-standing publication is witnessed")
        let (aliceA, capturePeerA) = try standInitiator(pairA)
        let sealedA = sealRecords(1, marker: 501, clearLen: 1888, via: aliceA,
                                  peerId: pairA.viaBob, capturePeer: capturePeerA)
        let seqA = UInt8(sealedA[0].seq)
        for i in 0..<(sealedA[0].frags.count - 1) {
            pushWrite(bobA, pmA, centralId: pairA.viaAlice, bytes: sealedA[0].frags[i])
            now = base + TimeInterval(4 * i)
        }
        guard let leaseA = connA.activeLeaseOf(seqA) else {
            XCTFail("the admission left no lease"); return
        }
        ledger.check("LEASE-ABSOLUTE", "dribble",
                     "the term is absolute from the admission",
                     leaseA.deadlineMono == base + 30)
        ledger.check("REFRESH-IMMOBILE", "dribble",
                     "no arrival moved the deadline", now < leaseA.deadlineMono)
        // the first fall, upon the living connection
        connA.sweepLeasesAt(leaseA.deadlineMono)
        ledger.check("REGISTERS-PURGED", "double fall",
                     "the sweep at the term purged the register whole",
                     connA.activeLeaseOf(seqA) == nil)
        ledger.check("NOTICE-RAISED", "double fall",
                     "the sweep raised the notice for its owner to take",
                     connA.peekLeaseExpiryNotice() != nil)
        _ = connA.takeLeaseExpiryNotice()
        // re-admission afresh upon the same living connection, twice, and
        // never the same admission identity twice
        _ = connA.ingestInboundAttValue(sealedA[0].frags[0])
        let t1 = connA.activeLeaseOf(seqA)?.admissionId
        connA.sweepLeasesAt(leaseA.deadlineMono + 31)
        _ = connA.ingestInboundAttValue(sealedA[0].frags[0])
        let t2Time = now
        let t2 = connA.activeLeaseOf(seqA)?.admissionId
        ledger.check("DIFFERENT-ADMISSION", "double fall",
                     "no admission identity is ever borne twice (observed t1=\(String(describing: t1)) t2=\(String(describing: t2)))",
                     t1 != nil && t2 != nil && t1 != t2)
        // the transport's own fall, reserved for the last act
        now = t2Time + 30
        pushWrite(bobA, pmA, centralId: pairA.viaAlice,
                  bytes: sealedA[0].frags[sealedA[0].frags.count - 1])
        ledger.check("OWNER-CLOSES", "dribble fall",
                     "the relation fell through the owner arm alone",
                     bobA.connection(for: pairA.viaAlice) == nil)
        ledger.check("PUBLICATION-WITHDRAWN", "dribble fall",
                     "the fall brought the publication down again",
                     !bobA.isRelationPublished(direction: .inboundPeripheral,
                                               peerId: pairA.viaAlice, generation: genA))
        bobA.stop()
        aliceA.stop()
        // schedule B: the wrap of two hundred fifty six, upon a fresh rig
        let pairB = try ReadinessTrustedPairing.establish()
        defer { ReadinessTrustedPairing.tearDown(pairB) }
        now = TimeInterval(1_700_000_000)
        let recorderB = T17DelegateSpy()
        let bobB = BleTransport(identity: pairB.bobIdentity, store: T17MessageStore(),
                                sessions: pairB.bobManager, managerFactory: CaptureFactory(),
                                clock: TestClock(startingAt: 9_700))
        bobB.delegate = recorderB
        pins.append(recorderB)
        let (pmB, whyB) = try responderReady(bobB, centralId: pairB.viaAlice,
                                         remoteHint: pairB.aliceIdentity.nodeHint,
                                         leaseClock: { now })
        guard let pmB = pmB else { XCTFail("responder B never stood ready: " + whyB); return }
        let (aliceB, capturePeerB) = try standInitiator(pairB)
        let sealedB = sealRecords(257, marker: 1500, clearLen: 4, via: aliceB,
                                  peerId: pairB.viaBob, capturePeer: capturePeerB)
        var observed: [Int] = []
        var pushes = 0
        for k in 0..<257 {
            for frag in sealedB[k].frags {
                pushWrite(bobB, pmB, centralId: pairB.viaAlice, bytes: frag)
            }
            observed.append(sealedB[k].seq)
            pushes += 1
            if pushes % 32 == 0 {
                _ = awaitTrue(limit: 400) { recorderB.received.count >= pushes }
            }
        }
        let arrived = awaitTrue(limit: 2000) { recorderB.received.count == 257 }
        ledger.check("WRAP-COMPLETE", "wrap",
                     "every whole record arrived across the wrap", arrived)
        ledger.check("WRAP-FRAMING", "wrap",
                     "the uint8 framing was not altered for the wrap",
                     observed.count == 257 && zip(observed, observed.dropFirst()).allSatisfy {
                         $1 == ($0 + 1) % 256
                     })
        if let connB = bobB.connection(for: pairB.viaAlice) {
            ledger.check("SLOTS-RECYCLED", "wrap",
                         "the register never grew beyond its concurrent bound",
                         connB.leaseCount() <= 4)
        }
        XCTAssertEqual(ledger.broken().count, 0,
                       "the ledger records no broken invariant; broken: " +
                       ledger.broken().map { "\($0.invariantId)@\($0.scenario) [\($0.statement)]" }
                           .joined(separator: "; "))
        XCTAssertTrue(ledger.report().contains("HELD"), "the ledger names every check it made")
        XCTAssertGreaterThanOrEqual(ledger.entriesCount(), 9,
                                    "the schedule weighed at least nine checks")
        print(ledger.report())
        bobB.stop()
        aliceB.stop()
    }

    func testEverySourceOfTheCallbackSurfaceIsDeliveredOrNamedForTheRecord() throws {
        let fixture = AdapterTraceFixture(presenter: { id in self.centralPresent(id) })
        let ledger = InvariantLedger(owner: "T20 callback inventory")
        for source in AdapterCallbackSource.allCases {
            if fixture.canDeliver(source) {
                ledger.check("INVENTORY", source.rawValue,
                             "deliverable through a production entry", true)
            } else {
                ledger.skip("INVENTORY", source.rawValue,
                           "awaiting the device gates",
                           "the host harness carries no real callback for this source")
            }
        }
        XCTAssertEqual(ledger.entriesCount(), AdapterCallbackSource.allCases.count,
                       "every source of the surface was accounted for")
        XCTAssertEqual(ledger.broken().count, 0, "no inventory check was broken")
    }
}
