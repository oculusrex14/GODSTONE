import XCTest
import Foundation
import CoreBluetooth
import ObjectiveC
@testable import GodstoneCore
@testable import GodstoneMesh

/// T23: the cross-platform handshake POLICY of section thirteen - the island half.
///
/// The deadline is armed from the role binding and the owners hand reapeth a
/// stalled, half-spoken exchange only when nothing is in flight, so an idle
/// seat and a travelling reassembly are left to the lease that owns them. No
/// counsel is retransmitted in place: the exact frame is hearkened not, the
/// fresh sequence at a spent stage perisheth. The trusted hour publisheth no
/// application readiness; the sealed key-confirmation round, riding the DATA
/// channel of an established relation, is the gate to the single LinkReady.
/// Reflection, forgery, staleness, misshapen frames, the unanswered hour and
/// the wayward record are all observed, and fallen.
///
/// The harness is slic'd from the T22 witness, as the Android court slic'd its
/// own; the one deliberate graft is the INITIATORS EAR: the T22 rig heareth
/// only the responder inbound, while this court must also hearken what the
/// initiator is opened, both to let a sealed control be consum'd at all and to
/// witness that a control is NEVER forward'd to the application.
final class ReadinessT23Tests: XCTestCase {

    // MARK: - fixtures (the house idiom: each suite owns its witnesses)

    /// The one clock of the rig. Both transports are given this selfsame
    /// instance, and the connections inherit it through them, so advancing it
    /// lapseth the handshake hour and the confirming hour of either half at
    /// once - the twin of the Android `rigNow`.
    private final class T23Clock: MonotonicClock, @unchecked Sendable {
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

    private final class PresentCentral: NSObject, @unchecked Sendable {
        @objc let identifier: UUID
        let tag = UUID()
        @objc var maximumUpdateValueLength: Int = 512
        init(identifier: UUID) {
            self.identifier = identifier
            super.init()
        }
    }

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
        /// T23: the hand that striketh the record clean, that a court may tell
        /// the answer of the selfsame breath from the counsel it followeth.
        func clearCaptured() {
            lk.lock(); updates.removeAll(); attempts.removeAll(); lk.unlock()
        }
        var respondedResults: [CBATTError.Code] {
            lk.lock(); defer { lk.unlock() }
            return answers
        }
    }

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

    /// The ear of a half. `received` is what the APPLICATION was told; a sealed
    /// key-confirmation control must never stir it, which is the witness of the
    /// case that highteth `...publisheth nought of the control`.
    private final class T23DelegateSpy: TransportDelegate, @unchecked Sendable {
        private let lk = NSLock()
        private var recv: [(data: Data, peerId: UUID)] = []
        private var hs: [UUID] = []
        private var lr: [UUID] = []
        func transportDidReceive(data: Data, peerId: UUID) {
            lk.lock(); recv.append((data, peerId)); lk.unlock()
        }
        func transportDidHandshakeReady(peerId: UUID) {
            lk.lock(); hs.append(peerId); lk.unlock()
        }
        func transportApplicationLinkReady(peerId: UUID) {
            lk.lock(); lr.append(peerId); lk.unlock()
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
        var linkReadyPeers: [UUID] {
            lk.lock(); defer { lk.unlock() }
            return lr
        }
        func clearReceived() {
            lk.lock(); recv.removeAll(); lk.unlock()
        }
    }

    private final class T23MessageStore: MessageStore {
        var held: [Data] = []
        private var observers: [@Sendable () -> Void] = []
        private let lock = NSLock()
        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) {
            lock.lock(); defer { lock.unlock() }
            observers.append(observer)
        }
        func notifyObservers() {
            lock.lock()
            let obs = observers
            lock.unlock()
            obs.forEach { $0() }
        }
        func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult {
            lock.lock(); held.append(frame.msgId); lock.unlock()
            notifyObservers()
            return .heldNew
        }
        func removeHeld(_ msgId: Data) -> Bool {
            lock.lock()
            let initial = held.count
            held.removeAll { $0 == msgId }
            let removed = held.count < initial
            lock.unlock()
            if removed { notifyObservers() }
            return removed
        }
        func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data,
                                   localOriginNodeId: Data) -> OutboundEnqueueResult {
            .canonicalFrameMismatch
        }
        func allHeldOrderedByPriority() -> [FrameV2] { [] }
        func allHeldMsgIds() -> [Data] {
            lock.lock(); defer { lock.unlock() }
            return held
        }
        func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {}
        func forEachHeldMsgId(_ visit: (Data) -> Bool) {
            lock.lock()
            let copy = held
            lock.unlock()
            for id in copy { if !visit(id) { break } }
        }
        var heldBytes: Int64 {
            lock.lock(); defer { lock.unlock() }
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

    private final class NotifyingInboxCharacteristic: CBMutableCharacteristic {
        override var isNotifying: Bool { return true }
    }

    private static func provisionedService() -> CBMutableService {
        let installed = BleTransport.characteristicsToInstall(BleTransport.meshProfile)
        let service = CBMutableService(type: BleTransport.meshProfile.serviceUuid, primary: true)
        service.characteristics = installed
        return service
    }

    private static func remoteLinkInfoStatic(hint: Data) -> Data {
        return BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: hint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0)
    }

    /// The initiators legs, as the proven recipe drives them.
    private func advanceToRoleBound(_ alice: BleTransport, peerId: UUID,
                                    serviceDataHint: Data,
                                    capturePeer: CapturePeripheral) -> RelationPeripheralDelegate? {
        alice.start()
        alice.refreshLocalLinkInfoSnapshotSync()
        let cm = alice.requireContextCentralForTest()
        let advRecord: [String: Any] = [
            CBAdvertisementDataServiceDataKey: [BleTransport.serviceUuid:
                ReadinessT23Tests.remoteLinkInfoStatic(hint: serviceDataHint)]
        ]
        _ = alice.processCentralDidDiscover(
            cm, peripheral: unsafeBitCast(capturePeer, to: CBPeripheral.self),
            advertisementData: advRecord, rssi: NSNumber(value: -60),
            sourceEpoch: alice.currentTransportEpoch)
        guard let delegate = alice.getRelationDelegate(peerId) else { return nil }
        _ = alice.processCentralConnect(
            peerId: peerId, peripheral: nil,
            sourceEpoch: alice.currentTransportEpoch, from: cm)
        _ = alice.processPeripheralDiscoverServices(nil, delegate: delegate, error: nil)
        _ = alice.processPeripheralDiscoverCharacteristics(nil, delegate: delegate,
                                                          service: ReadinessT23Tests.provisionedService(), error: nil)
        let linkInfoChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: ReadinessT23Tests.remoteLinkInfoStatic(hint: serviceDataHint),
            permissions: [.readable, .writeable])
        _ = alice.processPeripheralUpdateValue(nil, delegate: delegate, characteristic: linkInfoChar, error: nil)
        let ackChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: serviceDataHint,
            permissions: [.readable, .writeable])
        _ = alice.processPeripheralWriteValue(nil, delegate: delegate, characteristic: ackChar, error: nil)
        let inboxChar = NotifyingInboxCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable])
        _ = alice.processPeripheralNotificationStateUpdated(nil, delegate: delegate, characteristic: inboxChar, error: nil)
        if alice.connection(for: peerId) == nil { return nil }
        return delegate
    }

    /// The responders legs.
    private func advanceToResponderBound(_ bob: BleTransport, pm: CBPeripheralManager,
                                        centralId: UUID, remoteHint: Data,
                                        updateCapacity: Int = 512) -> (Bool, String) {
        let w = bob.processInboundWrite(centralId: centralId,
                                        rawData: ReadinessT23Tests.remoteLinkInfoStatic(hint: remoteHint),
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

    // MARK: - the rig

    private struct T23Rig {
        let pair: ReadinessTrustedPairing.Pair
        let alice: BleTransport
        let bob: BleTransport
        let aliceSpy: T23DelegateSpy
        let bobSpy: T23DelegateSpy
        let capturePeer: CapturePeripheral
        let aliceFactory: CaptureFactory
        let bobFactory: CaptureFactory
        let handleA: UUID
        let handleB: UUID
        let aliceDelegate: RelationPeripheralDelegate
        let bobPM: CBPeripheralManager
        let clock: T23Clock
    }

    private func makeRig() throws -> T23Rig {
        let pair = try ReadinessTrustedPairing.barePair()
        let handleB = UUID()
        let handleA = UUID()
        let aliceFactory = CaptureFactory()
        let bobFactory = CaptureFactory()
        // THE GRAFT: one clock, both halves, the twin of the Android rigNow.
        let clock = T23Clock(startingAt: 9_300)
        let alice = BleTransport(identity: pair.aliceIdentity, store: T23MessageStore(),
                                sessions: pair.aliceManager,
                                managerFactory: aliceFactory, clock: clock)
        let bob = BleTransport(identity: pair.bobIdentity, store: nil, sessions: pair.bobManager,
                              managerFactory: bobFactory, clock: clock)
        let aliceSpy = T23DelegateSpy(); alice.delegate = aliceSpy
        let bobSpy = T23DelegateSpy(); bob.delegate = bobSpy
        let (_, capturePeer) = peripheralPunt(handleB)
        guard let aliceDelegate = advanceToRoleBound(alice, peerId: handleB,
                                                    serviceDataHint: pair.bobIdentity.nodeHint,
                                                    capturePeer: capturePeer) else {
            throw NSError(domain: "t23", code: 1, userInfo: [NSLocalizedDescriptionKey: "the initiator never bound"])
        }
        bob.start()
        let bobPM = bob.requireContextPeripheralForTest()
        let (bound, saw) = advanceToResponderBound(bob, pm: bobPM, centralId: handleA,
                                                   remoteHint: pair.aliceIdentity.nodeHint)
        guard bound else {
            throw NSError(domain: "t23", code: 2, userInfo: [NSLocalizedDescriptionKey: "the responder never bound: " + saw])
        }
        return T23Rig(pair: pair, alice: alice, bob: bob, aliceSpy: aliceSpy, bobSpy: bobSpy,
                      capturePeer: capturePeer, aliceFactory: aliceFactory, bobFactory: bobFactory,
                      handleA: handleA, handleB: handleB,
                      aliceDelegate: aliceDelegate, bobPM: bobPM, clock: clock)
    }

    /// Stands the rig upon both ladders, short of the exchange itself.
    private func standDoor() throws -> T23Rig { return try makeRig() }

    // MARK: - the measures

    private func typeOfByte(_ v: Data) -> Int { Int(v[v.startIndex.advanced(by: 1)]) }
    private func payloadOf(_ v: Data) -> Data { Data(v.dropFirst(8)) }
    private func seqOf(_ v: Data) -> UInt8 { v[v.startIndex.advanced(by: 2)] }
    private func kindOf(_ type: BleRecordType) -> Int { Int(type.rawValue) & 0xFF }

    private func forgeT23(_ type: BleRecordType, _ seq: UInt8, _ payload: Data) -> [Data] {
        return try! BleRecordFragmenter.fragment(recordType: type, recordSeq: seq,
                                                payload: payload, maxAttValueLength: 247)
    }
    private func forgeOne(_ type: BleRecordType, _ seq: UInt8, _ payload: Data) -> Data {
        return forgeT23(type, seq, payload).first!
    }
    private func clearOf(_ marker: Int, _ len: Int) -> Data {
        return Data((0..<len).map { i in
            if i == 0 { return UInt8(marker & 0xFF) }
            if i == 1 { return UInt8((marker >> 8) & 0xFF) }
            return UInt8((i &* 7 &+ 13 &+ marker) % 251)
        })
    }

    private func pushToResponder(_ r: T23Rig, _ fragments: [Data]) {
        for f in fragments { pushWrite(r.bob, r.bobPM, centralId: r.handleA, bytes: f) }
    }
    private func pushToInitiator(_ r: T23Rig, _ fragments: [Data]) {
        for f in fragments {
            let ch = CBMutableCharacteristic(type: BleTransport.inboxCharacteristicUuid,
                                            properties: [.read, .write, .notify],
                                            value: f, permissions: [.readable, .writeable])
            _ = r.alice.processPeripheralUpdateValue(nil, delegate: r.aliceDelegate,
                                                   characteristic: ch, error: nil)
        }
    }

    private func beginOn(_ r: T23Rig, _ hint: Data) -> TransportResult {
        r.alice.beginTrustedHandshake(peerId: r.handleB, remoteHint: hint)
    }

    private func initiatorConnection(_ r: T23Rig) -> BleConnection? { r.alice.connection(for: r.handleB) }
    private func responderConnection(_ r: T23Rig) -> BleConnection? { r.bob.connection(for: r.handleA) }

    private func ringOf(_ t: BleTransport) -> String {
        t.rejectionRecordsForTest().map { $0.site + "|" + $0.reason }.joined(separator: ", ")
    }
    private func ringHas(_ t: BleTransport, _ needle: String) -> Bool {
        t.rejectionRecordsForTest().contains { $0.site.contains(needle) || $0.reason.contains(needle) }
    }
    private func violationSeen(_ t: BleTransport, _ kind: HandshakeDispatchViolation) -> Bool {
        t.dispatchViolationsForTest().contains { $0.kind == kind }
    }

    private func waitUntil2(_ predicate: () -> Bool) -> Bool {
        for _ in 0..<1200 {
            if predicate() { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return predicate()
    }
    private func waitUntil2(_ what: String, _ predicate: () -> Bool) -> Bool {
        return waitUntil2(predicate)
    }
    private func sample(_ observe: () -> Data?) -> Data? {
        for _ in 0..<1200 {
            if let v = observe(), !v.isEmpty { return v }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return observe()
    }
    private func sampleAll(_ observe: () -> [Data]) -> [Data] {
        for _ in 0..<1200 {
            let seen = observe()
            if let first = seen.first, first.count > 4, Int(first[first.startIndex.advanced(by: 4)]) == seen.count {
                return seen
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return observe()
    }

    /// The captures of the responders outlet towards the initiator.
    private func responderCaptures(_ r: T23Rig) -> [Data] {
        guard let mgr = r.bobFactory.peripheralManagers.last as? CapturePeripheralManager else { return [] }
        return mgr.capturedUpdates.filter { $0.central == r.handleA }.map { $0.bytes }
    }
    private func lastResponderCapture(_ r: T23Rig) -> Data? { responderCaptures(r).last }
    private func capturedHS2(_ r: T23Rig) -> Data? {
        guard let mgr = r.bobFactory.peripheralManagers.last else { return nil }
        return firstCapture(of: mgr, towards: r.handleA)
    }
    private func clearResponderCaptures(_ r: T23Rig) {
        (r.bobFactory.peripheralManagers.last as? CapturePeripheralManager)?.clearCaptured()
    }

    /// The sealed round, step by step, to the trusted hour on both sides.
    @discardableResult
    private func driveToReady(_ r: T23Rig) throws -> Data? {
        r.capturePeer.clearWrites()
        clearResponderCaptures(r)
        XCTAssertEqual(beginOn(r, r.pair.bobIdentity.nodeHint), .admitted,
                       "the begin must stand upon the witnessed duplex; ring: " + ringOf(r.alice))
        guard let hs1 = sample({ r.capturePeer.writes.last }) else {
            XCTFail("the HS1 never came forth; ring: " + ringOf(r.alice)); return nil
        }
        r.capturePeer.clearWrites()
        pushToResponder(r, [hs1])
        guard let hs2 = sample({ lastResponderCapture(r) }) else {
            XCTFail("the HS2 never answered; ring: " + ringOf(r.bob)); return nil
        }
        clearResponderCaptures(r)
        pushToInitiator(r, [hs2])
        guard let hs3 = sample({ r.capturePeer.writes.last(where: { $0 != hs1 }) }) else {
            XCTFail("the HS3 never went out; ring: " + ringOf(r.alice)); return nil
        }
        r.capturePeer.clearWrites()
        pushToResponder(r, [hs3])
        XCTAssertTrue(waitUntil2 { r.pair.aliceManager.isReady(r.handleB) && r.pair.bobManager.isReady(r.handleA) },
                      "both registries must report the peer ready; ring: " + ringOf(r.alice) + " / " + ringOf(r.bob))
        XCTAssertTrue(waitUntil2 { self.initiatorConnection(r)?.state == .ready
                                 && self.responderConnection(r)?.state == .ready },
                      "both connections must stand ready")
        return hs2
    }

    /// Driveth the exchange but to the initiators own hour: the third is
    /// withholden from the responder, so one half is ready and the other is not.
    private func driveToInitiatorReadyOnly(_ r: T23Rig) throws -> (hs2: Data, hs3: Data)? {
        r.capturePeer.clearWrites()
        clearResponderCaptures(r)
        XCTAssertEqual(beginOn(r, r.pair.bobIdentity.nodeHint), .admitted,
                       "the begin must stand; ring: " + ringOf(r.alice))
        guard let hs1 = sample({ r.capturePeer.writes.last }) else { return nil }
        r.capturePeer.clearWrites()
        pushToResponder(r, [hs1])
        guard let hs2 = sample({ lastResponderCapture(r) }) else { return nil }
        clearResponderCaptures(r)
        pushToInitiator(r, [hs2])
        guard let hs3 = sample({ r.capturePeer.writes.last(where: { $0 != hs1 }) }) else { return nil }
        XCTAssertTrue(waitUntil2 { self.initiatorConnection(r)?.state == .ready },
                      "the initiator must stand ready upon its own third; ring: " + ringOf(r.alice))
        return (hs2, hs3)
    }

    /// Attacheth the initiators ear: a sentinel, sent by the responder over the
    /// trusted DATA channel and open'd at the initiators hand, proveth that the
    /// delegate is attach'd before any count of what the ear heareth.
    private func warmAliceStream(_ r: T23Rig) throws {
        let sentinel = Data([0x77])
        for _ in 0..<400 {
            let before = r.aliceSpy.received.count
            clearResponderCaptures(r)
            let verdict = r.bob.send(clear: sentinel, to: r.handleA)
            if verdict == .admitted {
                guard let captured = sample({ lastResponderCapture(r) }) else { continue }
                pushToInitiator(r, [captured])
                if waitUntil2({ r.aliceSpy.received.count > before }) {
                    // the sentinel hath prov'd the attachment and is struck from
                    // the record: the cases count onely their own traffic henceforth
                    r.aliceSpy.clearReceived()
                    clearResponderCaptures(r)
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTFail("the initiators ear never woke for the sentinel; ring: " + ringOf(r.alice))
    }

    // ================================================================ T23 ====

    // MARK: - case the first: the half-spoken exchange falleth at the hour

    func testTheHalfSpokenExchangeFallethAtTheTenSecondHour() throws {
        let r = try standDoor()
        XCTAssertEqual(beginOn(r, r.pair.bobIdentity.nodeHint), .admitted,
                       "the begin must stand; ring: " + ringOf(r.alice))
        // past the ten-second hour of section thirteen
        r.clock.advance(HandshakeDeadline.handshakeWindowMillis &+ 1)
        // an idle breath at the gate: no reassembly afoot, the seat half-spoken
        pushToInitiator(r, [Data(count: 8)])
        XCTAssertTrue(waitUntil2({ self.initiatorConnection(r) == nil }),
                      "the stalled, half-spoken exchange must perish; ring: " + ringOf(r.alice))
        XCTAssertTrue(violationSeen(r.alice, .handshakeDeadlineLapsed),
                      "the owners hand must observe the spent hour; ring: " + ringOf(r.alice))
        XCTAssertTrue(ringHas(r.alice, "handshake deadline lapsed"),
                      "the fall must ring its reason; ring: " + ringOf(r.alice))
        XCTAssertNotNil(responderConnection(r),
                        "the responders seat is none the wiser for the fall")
    }

    // MARK: - case the second: an idle, unspoken seat abideth the hour

    func testAnUnspokenSeatAbidethTheHourUnmoved() throws {
        let r = try standDoor()                                   // responder at roleBound, never engaged
        guard let conn = responderConnection(r) else { XCTFail("the responder must stand"); return }
        XCTAssertFalse(conn.handshakeEngaged, "a seat that heareth no counsel is not half-spoken")
        r.clock.advance(HandshakeDeadline.handshakeWindowMillis &+ 1)
        // a benign breath at the gate: DATA at an untrusted hour is a bounded refusal
        pushToResponder(r, [forgeOne(.data, 7, Data(repeating: 0x33, count: 8))])
        XCTAssertNotNil(responderConnection(r),
                         "an idle seat is not a half-spoken exchange; it abideth; ring: " + ringOf(r.bob))
        XCTAssertFalse(violationSeen(r.bob, .handshakeDeadlineLapsed),
                       "the hour may not fell an unengaged seat")
        XCTAssertFalse(conn.handshakeDeadline.hasFiredForTest(),
                       "the hour was never mark'd spent upon a silent gate")
    }

    // MARK: - case the third: a travelling reassembly is left to the lease

    func testATravellingReassemblyIsLeftUntoTheLeaseNotReapedByTheHour() throws {
        let r = try standDoor()
        XCTAssertEqual(beginOn(r, r.pair.bobIdentity.nodeHint), .admitted,
                       "the begin must stand; ring: " + ringOf(r.alice))
        guard let hs1 = sample({ r.capturePeer.writes.last }) else {
            XCTFail("hs1 must reach the outlet; ring: " + ringOf(r.alice)); return
        }
        r.capturePeer.clearWrites()
        pushToResponder(r, [hs1])
        XCTAssertTrue(waitUntil2({ self.responderConnection(r)?.state == .handshakeInProgress }),
                      "the responder must be half-spoken; ring: " + ringOf(r.bob))
        // held by hand: the connection outliveth its own removal, that the trace
        // may be read after the controller-reject path hath done with it
        guard let stalled = responderConnection(r) else { XCTFail("no responder connection"); return }
        // a counsel of the third that shall travel apace, in two fragments
        let faring = forgeT23(.hs3, 33, Data((0..<300).map { UInt8($0 % 251) }))
        XCTAssertEqual(faring.count, 2, "the tale must be two fragments afoot")
        pushToResponder(r, [faring[0]])
        XCTAssertEqual(stalled.leaseCountForTest(), 1, "a counsel must be in flight")
        r.clock.advance(HandshakeDeadline.handshakeWindowMillis &+ 1)   // past the hour...
        pushToResponder(r, [faring[1]])                                 // ...the rest cometh home
        XCTAssertFalse(violationSeen(r.bob, .handshakeDeadlineLapsed),
                       "the hour may not reap a reassembly the lease doth govern; ring: " + ringOf(r.bob))
        XCTAssertFalse(stalled.handshakeDeadline.hasFiredForTest(),
                       "the hour was never mark'd spent while a counsel travelled")
    }

    // MARK: - case the fourth: the second counsel rehearsed runneth not the gate

    func testTheDuplicateSecondTaleRunnethNotTheControllerTwice() throws {
        let r = try standDoor()
        guard let hs2 = try driveToReady(r) else { return }               // initiator READY, the second remembred
        guard let conn = initiatorConnection(r) else { XCTFail("no initiator connection"); return }
        XCTAssertEqual(conn.state, .ready, "the initiator standeth ready")
        let secondSeq = seqOf(hs2)
        let secondTale = payloadOf(hs2)
        let writesBefore = r.capturePeer.writes.count
        let heardBefore = conn.transcript.heardCountForTest(kindOf(.hs2))
        // the selfsame frame, byte for byte and sequence for sequence, again
        r.alice.feedInitiatorHandshakeRecordForTest(r.handleB,
            record: BleReassembledRecord(recordType: .hs2, recordSeq: secondSeq, payload: secondTale))
        XCTAssertEqual(conn.state, .ready,
                       "an idle re-presenting is hearkened not; the gate standeth ready; ring: " + ringOf(r.alice))
        XCTAssertEqual(r.capturePeer.writes.count, writesBefore,
                       "no second third goeth forth for a tale twice told")
        XCTAssertEqual(conn.transcript.heardCountForTest(kindOf(.hs2)), heardBefore,
                       "the tale was but once remembred")
        XCTAssertTrue(ringHas(r.alice, "hs2 duplicate hearkened not"),
                      "the door rang that the duplicate was hearkened; ring: " + ringOf(r.alice))
    }

    // MARK: - case the fifth: the exact duplicate is spared, the fresh sequence perisheth

    func testTheExactDuplicateIsSparedTheFreshSequencePerisheth() throws {
        let r = try standDoor()
        XCTAssertEqual(beginOn(r, r.pair.bobIdentity.nodeHint), .admitted,
                       "the begin must stand; ring: " + ringOf(r.alice))
        guard let hs1 = sample({ r.capturePeer.writes.last }) else {
            XCTFail("hs1 must reach the outlet; ring: " + ringOf(r.alice)); return
        }
        r.capturePeer.clearWrites()
        pushToResponder(r, [hs1])
        XCTAssertTrue(waitUntil2({ self.responderConnection(r)?.state == .handshakeInProgress }),
                      "the responder must be half-spoken; ring: " + ringOf(r.bob))
        let firstSeq = seqOf(hs1)
        let firstTale = payloadOf(hs1)
        guard let conn = responderConnection(r) else { XCTFail("no responder connection"); return }
        // (a) the selfsame first counsel, byte and sequence alike, is hearkened not
        r.bob.feedResponderHandshakeRecordForTest(r.handleA,
            record: BleReassembledRecord(recordType: .hs1, recordSeq: firstSeq, payload: firstTale))
        XCTAssertEqual(conn.state, .handshakeInProgress,
                       "the exact duplicate is hearkened not; the half-spoken stand remaineth")
        XCTAssertEqual(conn.transcript.heardCountForTest(kindOf(.hs1)), 1,
                       "the tale was but once remembred")
        XCTAssertTrue(ringHas(r.bob, "hs1 duplicate hearkened not"),
                      "the door rang that the duplicate was hearkened; ring: " + ringOf(r.bob))
        // (b) a fresh sequence bearing the selfsame tale is a conflicting counsel
        let fresh = UInt8((Int(firstSeq) + 1) & 0xFF)
        r.bob.feedResponderHandshakeRecordForTest(r.handleA,
            record: BleReassembledRecord(recordType: .hs1, recordSeq: fresh, payload: firstTale))
        XCTAssertTrue(waitUntil2({ self.responderConnection(r) == nil }),
                      "the fresh-sequence re-telling must be fated; ring: " + ringOf(r.bob))
        XCTAssertTrue(ringHas(r.bob, "hs1 at stage"),
                      "the gate rang the stage at which the counsel was too late; ring: " + ringOf(r.bob))
    }

    // MARK: - case the sixth: the trusted hour alone publisheth no readiness

    func testTheTrustedHourAlonePublishethNoApplicationReadiness() throws {
        let r = try standDoor()
        guard let _ = try driveToReady(r) else { return }        // both sides at trusted crypto READY
        XCTAssertEqual(initiatorConnection(r)?.state, .ready, "the initiators crypto must be ready")
        XCTAssertFalse(initiatorConnection(r)!.isKeyConfirmed, "the trusted hour is not yet the key confirmed")
        XCTAssertFalse(responderConnection(r)!.isKeyConfirmed, "nor the responders")
        XCTAssertTrue(r.alice.linkReadyPeersForTest().isEmpty,
                      "no application readiness may be published before the sealed round")
        XCTAssertTrue(r.bob.linkReadyPeersForTest().isEmpty,
                      "nor at the responder may it be published")
        XCTAssertTrue(r.aliceSpy.linkReadyPeers.isEmpty, "the drivers ear was not stirr'd")
        XCTAssertTrue(r.bobSpy.linkReadyPeers.isEmpty, "nor the responders ear")
    }

    // MARK: - case the seventh: the sealed round carrieth to readiness

    func testTheSealedRoundCarriethToApplicationReadinessOnce() throws {
        let r = try standDoor()
        guard let _ = try driveToReady(r) else { return }
        try warmAliceStream(r)                                    // attach the initiators ear for control
        let challenge = Data((0..<16).map { UInt8($0 &+ 0x31) })
        r.capturePeer.clearWrites()
        XCTAssertEqual(r.alice.beginKeyConfirmation(peerId: r.handleB, supplied: challenge), .admitted,
                       "the challenge must go forth; ring: " + ringOf(r.alice))
        guard let ping = sample({ r.capturePeer.writes.last }) else {
            XCTFail("the challenge never reach'd the wire; ring: " + ringOf(r.alice)); return
        }
        r.capturePeer.clearWrites()
        pushToResponder(r, [ping])                                // the responder heareth, and answereth
        guard let echo = sample({ lastResponderCapture(r) }) else {
            XCTFail("the answer never reach'd the wire; ring: " + ringOf(r.bob)); return
        }
        clearResponderCaptures(r)
        pushToInitiator(r, [echo])                                // the initiators D2 heareth the echo
        XCTAssertTrue(waitUntil2({ self.initiatorConnection(r)?.isKeyConfirmed == true }),
                      "the key must be confirmed upon the matching echo; ring: " + ringOf(r.alice))
        XCTAssertTrue(waitUntil2({ !r.alice.linkReadyPeersForTest().isEmpty }),
                      "application readiness must be published once")
        XCTAssertEqual(r.alice.linkReadyPeersForTest(), [r.handleB], "published once, and of the right relation")
        XCTAssertTrue(r.aliceSpy.received.isEmpty,
                      "the application must not be told of the control itself")
        XCTAssertTrue(r.bobSpy.received.isEmpty,
                      "nor was the control forward'd at the responders application either")
    }

    // MARK: - case the eighth: the publication is idempotent

    func testThePublicationIsIdempotentAndTheEchoSingleShotten() throws {
        let r = try standDoor()
        guard let _ = try driveToReady(r) else { return }
        try warmAliceStream(r)
        let challenge = Data((0..<16).map { UInt8($0 &+ 0x11) })
        r.capturePeer.clearWrites()
        XCTAssertEqual(r.alice.beginKeyConfirmation(peerId: r.handleB, supplied: challenge), .admitted,
                       "the challenge must go forth; ring: " + ringOf(r.alice))
        guard let ping = sample({ r.capturePeer.writes.last }) else {
            XCTFail("the challenge never reach'd the wire"); return
        }
        r.capturePeer.clearWrites()
        pushToResponder(r, [ping])
        guard let echo = sample({ lastResponderCapture(r) }) else {
            XCTFail("the answer never reach'd the wire"); return
        }
        clearResponderCaptures(r)
        pushToInitiator(r, [echo])
        XCTAssertTrue(waitUntil2({ self.initiatorConnection(r)?.isKeyConfirmed == true }),
                      "the key must be confirmed")
        XCTAssertTrue(waitUntil2({ r.alice.linkReadyPeersForTest().count == 1 }),
                      "readiness must be published")
        // the selfsame echo, flung again at a confirm'd gate, addeth nothing
        pushToInitiator(r, [echo])
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(r.alice.linkReadyPeersForTest().count, 1,
                       "the gate publisheth readiness once and once only")
        XCTAssertEqual(r.aliceSpy.linkReadyPeers.count, 1, "and the ear heard but one tale")
    }

    // MARK: - case the ninth: a forged echo is refused

    func testAForgedEchoIsRefusedAndPublishethNothing() throws {
        let r = try standDoor()
        guard let _ = try driveToReady(r) else { return }
        try warmAliceStream(r)
        let challenge = Data((0..<16).map { UInt8($0 &+ 0x51) })
        XCTAssertEqual(r.alice.beginKeyConfirmation(peerId: r.handleB, supplied: challenge), .admitted,
                       "the challenge must go forth; ring: " + ringOf(r.alice))
        // a forged answer, bearing a tale that was never the challenge
        let forged = Data((0..<16).map { UInt8($0 &+ 0x51 &+ 7) })
        let frame = KeyConfirmationControl.encodeResponse(forged)
        XCTAssertEqual(r.bob.transmitKeyConfirmationControlForTest(peerId: r.handleA, frame: frame), .admitted,
                       "the forged frame must go forth upon the wire; ring: " + ringOf(r.bob))
        guard let inbound = sample({ lastResponderCapture(r) }) else {
            XCTFail("the forged echo never reach'd the wire"); return
        }
        clearResponderCaptures(r)
        pushToInitiator(r, [inbound])
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(initiatorConnection(r)?.isKeyConfirmed ?? true,
                       "a forged echo confirmeth nothing")
        XCTAssertTrue(violationSeen(r.alice, .forgedOrStaleEcho),
                      "a forged echo must be observed as a wayward record; ring: " + ringOf(r.alice))
        XCTAssertTrue(r.alice.linkReadyPeersForTest().isEmpty, "no readiness may follow a forged echo")
        XCTAssertTrue(r.aliceSpy.received.isEmpty, "the application must not be told of the forged control")
    }

    // MARK: - case the tenth: a reflected challenge is not echoed again

    func testAReflectedChallengeIsNotEchoedAgain() throws {
        let r = try standDoor()
        guard let _ = try driveToReady(r) else { return }
        try warmAliceStream(r)
        let challenge = Data((0..<16).map { UInt8($0 &+ 0x21) })
        r.capturePeer.clearWrites()
        XCTAssertEqual(r.alice.beginKeyConfirmation(peerId: r.handleB, supplied: challenge), .admitted,
                       "the challenge must go forth; ring: " + ringOf(r.alice))
        guard let _ = sample({ r.capturePeer.writes.last }) else {
            XCTFail("the challenge never reach'd the wire"); return
        }
        r.capturePeer.clearWrites()
        // the network reflecteth the very challenge back as a challenge
        let reflected = KeyConfirmationControl.encodeChallenge(challenge)
        XCTAssertEqual(r.bob.transmitKeyConfirmationControlForTest(peerId: r.handleA, frame: reflected), .admitted,
                       "the reflection must go forth upon the wire; ring: " + ringOf(r.bob))
        guard let inbound = sample({ lastResponderCapture(r) }) else {
            XCTFail("the reflection never reach'd the wire"); return
        }
        clearResponderCaptures(r)
        pushToInitiator(r, [inbound])
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertFalse(initiatorConnection(r)?.isKeyConfirmed ?? true, "a reflection confirmeth nothing")
        XCTAssertTrue(violationSeen(r.alice, .reflectedChallenge),
                      "a reflection must be observed as a wayward record; ring: " + ringOf(r.alice))
        XCTAssertTrue(r.alice.linkReadyPeersForTest().isEmpty, "no readiness may follow a reflection")
        XCTAssertEqual(r.capturePeer.writes.count, 0,
                       "the reflection is not echo'd again: no answer goeth forth for a token of the own")
    }

    // MARK: - case the eleventh: a wayward counsel at the gate is observed and closed

    func testAWaywardCounselAtTheGateIsObservedAndClosed() throws {
        let r = try standDoor()
        guard let _ = try driveToReady(r) else { return }              // responder at trusted READY
        let waywardPeer = r.handleA
        // a first counsel, quite out of season, flung at the ready gate
        pushToResponder(r, [forgeOne(.hs1, 41, Data(repeating: 0x11, count: 32))])
        XCTAssertTrue(waitUntil2({ self.responderConnection(r) == nil }),
                      "the ready gate must fate the wayward counsel; ring: " + ringOf(r.bob))
        XCTAssertTrue(violationSeen(r.bob, .unsolicitedHSAfterReady),
                      "the wayward counsel must be observed; ring: " + ringOf(r.bob))
        XCTAssertTrue(ringHas(r.bob, "at stage"),
                      "the gate rang its reason; ring: " + ringOf(r.bob))
        XCTAssertFalse(r.pair.bobManager.isReady(waywardPeer),
                       "the responder slot must not be left standing ready")
    }

    // MARK: - case the twelfth: a misshapen control is taken for ordinary matter

    func testAMisshapenControlIsTakenForOrdinaryMatter() throws {
        let r = try standDoor()
        guard let _ = try driveToReady(r) else { return }
        try warmAliceStream(r)
        // a frame that looketh near a control yet faileth its strict shape
        let misshapen = Data((0..<17).map { UInt8($0 &+ 3) })
        XCTAssertEqual(r.bob.transmitKeyConfirmationControlForTest(peerId: r.handleA, frame: misshapen), .admitted,
                       "the misshapen frame must go forth upon the wire; ring: " + ringOf(r.bob))
        guard let inbound = sample({ lastResponderCapture(r) }) else {
            XCTFail("the misshapen frame never reach'd the wire"); return
        }
        clearResponderCaptures(r)
        pushToInitiator(r, [inbound])
        XCTAssertTrue(waitUntil2({ !r.aliceSpy.received.isEmpty }),
                      "the misshapen frame must be taken for ordinary matter; ring: " + ringOf(r.alice))
        XCTAssertFalse(initiatorConnection(r)?.isKeyConfirmed ?? true, "a misshapen control confirmeth nothing")
        XCTAssertTrue(r.alice.linkReadyPeersForTest().isEmpty, "no readiness may follow a misshapen control")
    }

    // MARK: - case the thirteenth: the confirming hour unanswered felleth the relation

    func testTheConfirmingHourUnansweredFellethTheRelation() throws {
        let r = try standDoor()
        guard let _ = try driveToReady(r) else { return }
        let challenge = Data((0..<16).map { UInt8($0 &+ 0x61) })
        r.capturePeer.clearWrites()
        XCTAssertEqual(r.alice.beginKeyConfirmation(peerId: r.handleB, supplied: challenge), .admitted,
                       "the challenge must go forth; ring: " + ringOf(r.alice))
        XCTAssertTrue(initiatorConnection(r)?.keyConfirmation.isAwaitingEcho() ?? false,
                      "the round must await its echo")
        guard let _ = sample({ r.capturePeer.writes.last }) else {
            XCTFail("the challenge never reach'd the wire"); return
        }
        r.clock.advance(KeyConfirmation.echoWindowMillis &+ 1)      // past the half-minute hour
        pushToInitiator(r, [Data(count: 8)])                       // an idle breath at the gate
        XCTAssertTrue(waitUntil2({ self.initiatorConnection(r) == nil }),
                      "the unanswered round must fate the relation; ring: " + ringOf(r.alice))
        XCTAssertTrue(violationSeen(r.alice, .keyConfirmationDeadlineLapsed),
                      "the timeout of the confirming hour must be observed; ring: " + ringOf(r.alice))
        XCTAssertTrue(ringHas(r.alice, "key confirmation timed out"),
                      "and ring its own reason; ring: " + ringOf(r.alice))
        XCTAssertTrue(r.alice.linkReadyPeersForTest().isEmpty,
                      "no readiness may be published upon an unanswered round")
    }

    // MARK: - case the fourteenth: one-sided readiness publisheth no matter

    func testOneSidedReadinessPublishethNoMatter() throws {
        let r = try standDoor()
        guard let driven = try driveToInitiatorReadyOnly(r) else {
            XCTFail("the one-sided hour could not be driven"); return
        }
        XCTAssertEqual(responderConnection(r)?.state, .handshakeInProgress,
                       "the responder is not yet come to its hour")
        XCTAssertTrue(r.alice.linkReadyPeersForTest().isEmpty && r.bob.linkReadyPeersForTest().isEmpty,
                      "neither side may publish readiness of the others trust")
        XCTAssertTrue(r.aliceSpy.received.isEmpty,
                      "no application matter may be inferred from a one-sided hour")
        // now let the third come home, and the hour be whole
        clearResponderCaptures(r)
        pushToResponder(r, [driven.hs3])
        XCTAssertTrue(waitUntil2({ self.responderConnection(r)?.state == .ready }),
                      "the responder must come to its hour upon the third; ring: " + ringOf(r.bob))
        XCTAssertTrue(waitUntil2({ r.pair.bobManager.isReady(r.handleA) }),
                      "and the slot with it")
    }

    // MARK: - case the fifteenth: a fresh course, with fresh keys

    func testAFreshCourseWithFreshKeysReestablishethTrust() throws {
        let fallen = try standDoor()
        XCTAssertEqual(beginOn(fallen, fallen.pair.bobIdentity.nodeHint), .admitted,
                       "the begin must stand; ring: " + ringOf(fallen.alice))
        fallen.clock.advance(HandshakeDeadline.handshakeWindowMillis &+ 1)
        pushToInitiator(fallen, [Data(count: 8)])            // the half-spoken perisheth at the hour
        XCTAssertTrue(waitUntil2({ self.initiatorConnection(fallen) == nil }),
                      "the first course must perish; ring: " + ringOf(fallen.alice))
        // a fresh course, a fresh pair, fresh keys
        let risen = try makeRig()
        guard let freshInitiator = initiatorConnection(risen) else { XCTFail("no fresh connection"); return }
        XCTAssertTrue(freshInitiator.transcript.isEmptyForTest(),
                      "a fresh relation beginneth with an empty memory")
        XCTAssertFalse(freshInitiator.handshakeEngaged, "a fresh relation beginneth unengaged")
        XCTAssertNil(freshInitiator.keyConfirmation.outstanding(),
                     "a fresh relation beginneth with an unissued challenge")
        XCTAssertFalse(freshInitiator.handshakeDeadline.hasFiredForTest(),
                       "and upon an hour never turn'd")
        guard let _ = try driveToReady(risen) else { XCTFail("the fresh course could not complete"); return }
        XCTAssertTrue(risen.pair.aliceManager.isReady(risen.handleB) && risen.pair.bobManager.isReady(risen.handleA),
                      "the fresh keys must establish the peers trust")
        let remembred = initiatorConnection(risen)?.transcript.heardCountForTest(kindOf(.hs2)) ?? 0
        XCTAssertTrue(remembred >= 1,
                      "the fresh course must re-member the counsel it heareth")
    }

}
