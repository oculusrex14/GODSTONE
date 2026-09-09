import XCTest
import Foundation
import CoreBluetooth
@testable import GodstoneCore
@testable import GodstoneMesh

/// T14: all connection state, capacity, publication and driver actions of
/// a transport epoch are reduced on the ManagerContext serial executor.
/// Callback adapters package immutable events only; validation, transition
/// and action scheduling form one reducer operation; actions retain the
/// validated context; blocking store/trust work runs outside the executor
/// and returns token-checked completion events.
///
/// Swift mirror of the card's scenarios: pause exactly between validation
/// and action and queue a stop/start; duplicate terminals; a callback from
/// an unexpected queue; no storage I/O under the lock held; failure is
/// distinguished from empty no-op success.
final class ReadinessT14Tests: XCTestCase {

    // MARK: - fixtures

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { return storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    private final class RecordingTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
        var applyCount = 0
        private let lock = NSLock()
        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            lock.lock()
            applyCount += 1
            lock.unlock()
            return .accepted
        }
    }

    /// The real SDK exposes isNotifying as get-only, reflecting the CCCD of
    /// a live stack. A test double overrides the getter - the conforming
    /// host-side route to observe the notification-enable step.
    private final class NotifyingInboxCharacteristic: CBMutableCharacteristic {
        override var isNotifying: Bool { return true }
    }

    private final class T14MessageStore: MessageStore {
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

        private final class RecordingTransportDelegate: TransportDelegate, @unchecked Sendable {
        var receivedData: [(data: Data, peerId: UUID)] = []
        var duplexReadyPeers: [UUID] = []
        var connectedPeers: [UUID] = []
        var disconnectedPeers: [UUID] = []
        private let lock = NSLock()

        func transportDidConnect(peerId: UUID) {
            lock.lock()
            connectedPeers.append(peerId)
            lock.unlock()
        }

        func transportDidReceive(data: Data, peerId: UUID) {
            lock.lock()
            receivedData.append((data, peerId))
            lock.unlock()
        }
        func transportPhysicalDuplexReady(peerId: UUID) {
            lock.lock()
            duplexReadyPeers.append(peerId)
            lock.unlock()
        }
        func transportDidDisconnect(peerId: UUID) {
            lock.lock()
            disconnectedPeers.append(peerId)
            lock.unlock()
        }
    }

    /// A thread-safe box for handing results between threads.
    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        func set(_ value: Value) {
            lock.lock()
            stored = value
            lock.unlock()
        }
        func get() -> Value? {
            lock.lock()
            let value = stored
            lock.unlock()
            return value
        }
    }

    /// A shared ordering log; append is serialised so the recorded sequence
    /// reflects the order in which the barrier participants arrived.
    private final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ item: String) {
            lock.lock()
            items.append(item)
            lock.unlock()
        }
        func snapshot() -> [String] {
            lock.lock()
            let copy = items
            lock.unlock()
            return copy
        }
    }

    /// The corpus' deterministic seed recipe: hints derive from fixed key
    /// material, so the election predicate admits the outbound candidate
    /// exactly as the proven sequences in the substrate do.
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

    /// The composition sequence that takes an outbound relation from
    /// nothing to link-info acknowledged and the role bound, on the public
    /// entry points only - adapter included, no driver-level shortcuts.
    @discardableResult
    private func advanceToRoleBound(_ transport: BleTransport, peerId: UUID) -> RelationPeripheralDelegate? {
        transport.start()
        // The local link-info snapshot is computed from the identity and the
        // store; refresh it once so the election's write step has its local
        // data to advertise, as the composition does before opening.
        transport.refreshLocalLinkInfoSnapshotSync()
        let centralManager = transport.requireContextCentralForTest()
        _ = transport.processOutboundDiscover(
            peerId: peerId,
            rssi: -60,
            serviceDataHint: Data([0xFE, 0, 0, 0]),
            peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch,
            from: centralManager
        )
        guard let delegate = transport.getRelationDelegate(peerId) else {
            return nil
        }
        _ = transport.processCentralConnect(
            peerId: peerId, peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: centralManager
        )
        _ = transport.processPeripheralDiscoverServices(nil, delegate: delegate, error: nil)
        _ = transport.processPeripheralDiscoverCharacteristics(nil, delegate: delegate, service: ReadinessT14Tests.provisionedService(), error: nil)
        let linkInfoChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: remoteLinkInfo(hint: Data([0xFE, 0, 0, 0])),
            permissions: [.readable, .writeable]
        )
        _ = transport.processPeripheralUpdateValue(nil, delegate: delegate, characteristic: linkInfoChar, error: nil)
        let ackChar = CBMutableCharacteristic(
            type: BleTransport.linkInfoCharacteristicUuid,
            properties: [.read, .write],
            value: Data([0xFE, 0, 0, 0]),
            permissions: [.readable, .writeable]
        )
        _ = transport.processPeripheralWriteValue(nil, delegate: delegate, characteristic: ackChar, error: nil)
        let inboxChar = NotifyingInboxCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
        _ = transport.processPeripheralNotificationStateUpdated(nil, delegate: delegate, characteristic: inboxChar, error: nil)
        // The final transition to .ready is the higher layer's step (the
        // composition signals it via the delegate); the published test seam
        // stands in for it here, exactly as the corpus' responder-send
        // sequences do.
        transport.connection(for: peerId)?.markReadyForTesting()
        return delegate
    }

    // MARK: - the reduction of one event is not decomposable

    func testQueuedStopStartCannotSplitValidationFromAction() throws {
        let transport = BleTransport(identity: try makeIdentity(), store: T14MessageStore())
        transport.start()
        let peerId = UUID()
        let centralManager = transport.requireContextCentralForTest()
        _ = transport.processOutboundDiscover(
            peerId: peerId, rssi: -50, serviceDataHint: nil, peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: centralManager
        )
        let driverBefore = try XCTUnwrap(transport.centralDriver)
        let driverIdentityBefore = ObjectIdentifier(driverBefore)

        let order = OrderLog()
        let reached = DispatchSemaphore(value: 0)
        let resumed = DispatchSemaphore(value: 0)
        let returnedAction = Box<BleCentralAction>()
        let capacityDuring = Box<Int>()

        transport.failpointAfterValidationForTest = { name in
            order.append("validated:" + name)
            // The world as the reduction sees it while parked between
            // validation and action: no stop has run, the authority still
            // carries the admission, the driver is the one the epoch opened
            // with.
            capacityDuring.set(transport.capacityAuthority.totalCount)
            reached.signal()
            _ = resumed.wait(timeout: .now() + 5.0)
        }

        let connectDone = expectation(description: "connect reduction completed")
        let lifecycleDone = expectation(description: "stop and start completed")
        var stopReturned = false
        let stateLock = NSLock()

        DispatchQueue.global(qos: .userInitiated).async {
            let act = transport.processCentralConnect(
                peerId: peerId, peripheral: nil,
                sourceEpoch: transport.currentTransportEpoch, from: centralManager
            )
            returnedAction.set(act)
            order.append("connect-return")
            connectDone.fulfill()
        }
        _ = reached.wait(timeout: .now() + 5.0)
        XCTAssertEqual(capacityDuring.get(), 1, "the admission stood while the pause held")

        // While the executor carries the paused reduction, a stop/start is
        // queued behind it. It cannot overtake: the reduction of one event
        // is one uninterrupted operation.
        let stopperEntered = DispatchSemaphore(value: 0)
        let stopperProgressed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            stopperEntered.signal()
            transport.stop()
            order.append("stop-done")
            transport.start()
            order.append("start-done")
            stateLock.lock()
            stopReturned = true
            stateLock.unlock()
            stopperProgressed.signal()
            lifecycleDone.fulfill()
        }
        _ = stopperEntered.wait(timeout: .now() + 5.0)

        // Bounded observation: with the failpoint held, the lifecycle worker
        // must still be blocked behind the queue. Under the named mutation -
        // reading the mutable current driver outside the serialised region -
        // the stopper slips through this very window and the wait succeeds.
        let progressed = stopperProgressed.wait(timeout: .now() + 0.5)
        XCTAssertNotEqual(progressed, .success, "the queued stop/start cannot overtake the in-flight reduction")
        XCTAssertNil(returnedAction.get(), "the paused reduction has scheduled no effect yet")
        stateLock.lock()
        XCTAssertFalse(stopReturned, "the stop has not passed the barrier")
        stateLock.unlock()

        resumed.signal()
        wait(for: [connectDone, lifecycleDone], timeout: 10)

        let driverAfter = try XCTUnwrap(transport.centralDriver)
        XCTAssertNotIdentical(driverAfter, driverBefore, "the restart installed fresh drivers")
        XCTAssertEqual(transport.capacityAuthority.totalCount, 0, "the stop released the authority after the reduction had committed")
        transport.stop()
    }

    // MARK: - duplicate terminals

    func testDuplicateTerminalsChangeNothingTheSecondTime() throws {
        let transport = BleTransport(identity: try makeIdentity(), store: T14MessageStore())
        let peerId = UUID()
        guard let delegate = advanceToRoleBound(transport, peerId: peerId) else {
            XCTFail("the composition sequence admitted no relation")
            return
        }
        let gen = transport.centralDriver!.getConnectionGeneration(peerId)

        XCTAssertEqual(transport.capacityAuthority.outboundCount, 1, "one admission")

        let first = transport.processOutboundDisconnect(
            peerId: peerId, expectedGen: gen, peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: transport.requireContextCentralForTest()
        )
        XCTAssertNotEqual(first, .noOp, "the terminal event acts the first time")
        XCTAssertEqual(transport.capacityAuthority.outboundCount, 0)

        let second = transport.processOutboundDisconnect(
            peerId: peerId, expectedGen: gen, peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: transport.requireContextCentralForTest()
        )
        XCTAssertEqual(second, .noOp, "a duplicate terminal changes nothing")
        XCTAssertEqual(transport.capacityAuthority.outboundCount, 0, "no lease was taken twice, none given away twice")

        let staleTimeout = transport.handleOutboundTimeout(peerId: peerId, generation: gen)
        XCTAssertEqual(staleTimeout, .noOp, "the timeout of an ended relation is a duplicate terminal too")

        // Publication follows the state, not the message: unpublishing an
        // unpublished key reports the absence.
        XCTAssertFalse(transport.unpublishRelation(delegate.relationKey), "the publication was already withdrawn")
        transport.stop()
    }

    // MARK: - callbacks from an unexpected queue

    func testCallbackFromUnexpectedQueueIsCarriedOntoTheExecutor() throws {
        let transport = BleTransport(identity: try makeIdentity(), store: T14MessageStore())
        transport.start()
        let ctx = try XCTUnwrap(transport.currentManagerContextForTest())

        // Delivered from this test thread - a queue the executor never
        // expects: the reduction must still be carried onto the serial
        // queue context before it touches anything.
        ctx.centralProxy.centralManagerDidUpdateState(ctx.central)
        guard let trace = transport.lastReductionTraceForTest else {
            XCTFail("the reduction left no trace")
            return
        }
        XCTAssertEqual(trace.epoch, ctx.epoch, "the event was reduced by its own epoch")
        XCTAssertTrue(trace.ranOnSerialExecutor, "reductions run on the serial executor")

        // Re-entry: an event admitted from inside the executor (here, from
        // within a failpoint of another reduction) is carried through
        // without recursion into the queue.
        let innerTrace = Box<BleTransport.ReductionTrace>()
        transport.failpointAfterValidationForTest = { _ in
            _ = transport.processCentralDidUpdateState(ctx.central, sourceEpoch: ctx.epoch)
            if let inner = transport.lastReductionTraceForTest {
                innerTrace.set(inner)
            }
        }
        let peerId = UUID()
        _ = transport.processOutboundDiscover(
            peerId: peerId, rssi: -50, serviceDataHint: nil, peripheral: nil,
            sourceEpoch: ctx.epoch, from: ctx.central
        )
        _ = transport.processCentralConnect(
            peerId: peerId, peripheral: nil,
            sourceEpoch: ctx.epoch, from: ctx.central
        )
        if let inner = innerTrace.get() {
            XCTAssertTrue(inner.ranOnSerialExecutor)
            XCTAssertTrue(inner.reentrant, "a nested admission on the same executor is inline, never a queue of its own")
        } else {
            XCTFail("the nested reduction left no trace")
        }
        transport.failpointAfterValidationForTest = nil
        transport.stop()
    }

    // MARK: - no blocking work under the lock held

    func testTrustWorkIsNeverPerformedUnderTheLock() throws {
        let transport = BleTransport(identity: try makeIdentity(), store: T14MessageStore())
        let peerId = UUID()
        _ = advanceToRoleBound(transport, peerId: peerId)
        guard let conn = transport.connection(for: peerId) else {
            XCTFail("the relation was never established")
            return
        }
        conn.markReadyForTesting()

        let frame = FrameV2(
            type: .message,
            msgId: Data(repeating: 0x2A, count: 16),
            routingTag: Data(repeating: 0, count: 4),
            ttl: 10,
            hopCount: 0,
            flags: Priority.toFlags(.direct),
            payload: Data([1, 2, 3])
        )
        // The sealing site dispatches outside the critical section even
        // when the write itself is refused later (no captured peripheral
        // stands at this address on the host).
        let sent = transport.send(frame, to: peerId)
        XCTAssertFalse(sent, "the write is refused where the peripheral is missing")
        guard let sealProbe = transport.lastTrustWorkProbeForTest else {
            XCTFail("the sealing site recorded nothing")
            return
        }
        XCTAssertEqual(sealProbe.operation, "seal")
        XCTAssertFalse(sealProbe.lockHeld, "trust work never runs while the transport lock is held")
        XCTAssertTrue(sealProbe.onExecutor, "trust work runs on the serial executor")
        XCTAssertFalse(transport.transportLockIsHeldForTest(), "the quiescent transport holds no lock")
        transport.stop()
    }

    // MARK: - failure is distinguished from empty success

    func testOpenCompletionDistinguishesFailureFromEmptySuccess() throws {
        let nearIdentity = try makeIdentity(seedByte: 1, staticPrivByte: 2)
        let farIdentity = try makeIdentity(seedByte: 2, staticPrivByte: 3)
        let trust = RecordingTrustAuthority()
        let sessionsNear = SessionManager(identity: nearIdentity, trustAuthority: trust)
        let sessionsFar = SessionManager(identity: farIdentity, trustAuthority: RecordingTrustAuthority())

        let transport = BleTransport(identity: nearIdentity, store: T14MessageStore(), sessions: sessionsNear)
        let peerId = UUID()
        guard let delegate = advanceToRoleBound(transport, peerId: peerId) else {
            XCTFail("the composition sequence admitted no relation")
            return
        }
        guard let conn = transport.connection(for: peerId) else {
            XCTFail("the relation was never established")
            return
        }
        conn.markReadyForTesting()

        // The four-way handshake of the session, keys agreeing with the
        // relation the transport registered.
        let hs1 = try XCTUnwrap(sessionsFar.initiatorStart(peerId, remoteHint: nearIdentity.nodeHint))
        let hs2 = try XCTUnwrap(sessionsNear.responderProcessHs1(peerId, remoteHint: farIdentity.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(sessionsFar.initiatorProcessHs2(peerId, hs2: hs2, advertisedRemoteHint: nearIdentity.nodeHint))
        let ready = sessionsNear.responderProcessHs3(peerId, hs3: hs3, advertisedRemoteHint: farIdentity.nodeHint)
        XCTAssertTrue(ready, "the session stands established")

        let recorder = RecordingTransportDelegate()
        transport.delegate = recorder
        // The ladder's link-info writes consumed the connection's outbound
        // sequence window; reset the record state so the inbound data record
        // below reassembles against a fresh expectation, as the peer's
        // reassembly baseline does at the opening of a new exchange.
        conn.reset()

        let inboxChar = CBMutableCharacteristic(
            type: BleTransport.inboxCharacteristicUuid,
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )

        // 1. Failure: an unauthenticated ciphertext opens to nothing and
        //    the delegate never hears of it.
        inboxChar.value = firstFragment(of: conn, recordType: .data, payload: Data("not a ciphertext at all".utf8))
        _ = transport.processPeripheralUpdateValue(nil, delegate: delegate, characteristic: inboxChar, error: nil)
        XCTAssertEqual(recorder.receivedData.count, 0, "failure is not silence-of-success")

        // 2. Empty success: an authenticated empty plaintext opens to an
        //    empty payload and IS delivered - distinguished from failure.
        let emptyCipher = try XCTUnwrap(sessionsFar.seal(peerId, Data()))
        inboxChar.value = firstFragment(of: conn, recordType: .data, payload: emptyCipher)
        _ = transport.processPeripheralUpdateValue(nil, delegate: delegate, characteristic: inboxChar, error: nil)
        XCTAssertEqual(recorder.receivedData.count, 1, "the empty success is delivered")
        XCTAssertEqual(recorder.receivedData.first?.data, Data(), "as empty, not as absent")
        XCTAssertEqual(recorder.receivedData.first?.peerId, peerId)

        // 3. Success with payload.
        let plain = Data("serialised trust on the mesh".utf8)
        let cipher = try XCTUnwrap(sessionsFar.seal(peerId, plain))
        inboxChar.value = firstFragment(of: conn, recordType: .data, payload: cipher)
        _ = transport.processPeripheralUpdateValue(nil, delegate: delegate, characteristic: inboxChar, error: nil)
        XCTAssertEqual(recorder.receivedData.count, 2, "the success is delivered once more")
        XCTAssertEqual(recorder.receivedData.last?.data, plain)

        guard let openProbe = transport.lastTrustWorkProbeForTest else {
            XCTFail("the opening site recorded nothing")
            return
        }
        XCTAssertEqual(openProbe.operation, "open")
        XCTAssertFalse(openProbe.lockHeld, "the opening site never works under the lock")
        XCTAssertTrue(openProbe.onExecutor, "the opening site works on the serial executor")
        transport.stop()
    }

    /// The service object as the provisioning path installs it: with the
    /// required characteristic set present, so the gate admits discovery
    /// rather than refusing it.
    private static func provisionedService() -> CBMutableService {
        let installed = BleTransport.characteristicsToInstall(BleTransport.meshProfile)
        let service = CBMutableService(type: BleTransport.meshProfile.serviceUuid, primary: true)
        service.characteristics = installed
        return service
    }

    private func firstFragment(of conn: BleConnection, recordType: BleRecordType, payload: Data) -> Data {
        let fragments = conn.fragmentOutbound(recordType: recordType, payload: payload)
        precondition(!fragments.isEmpty, "the connection encodes at least one fragment")
        return fragments[0]
    }

    // MARK: - late deliveries of a closed epoch

    func testLateDeliveriesThroughCapturedOldProxiesDeliverNothingNew() throws {
        let transport = BleTransport(identity: try makeIdentity(), store: T14MessageStore())
        let peerId = UUID()
        _ = advanceToRoleBound(transport, peerId: peerId)
        let oldCtx = try XCTUnwrap(transport.currentManagerContextForTest())
        let oldGen = transport.centralDriver!.getConnectionGeneration(peerId)
        transport.stop()
        transport.start()

        let before = transport.capacityAuthority.totalCount
        // The delegate itself, captured from the closed epoch, still speaks
        // - and is heard as nothing.
        oldCtx.centralProxy.centralManagerDidUpdateState(oldCtx.central)
        oldCtx.peripheralProxy.peripheralManagerDidUpdateState(oldCtx.peripheral)
        let lateConnect = transport.processCentralConnect(
            peerId: peerId, peripheral: nil,
            sourceEpoch: oldCtx.epoch, from: oldCtx.central
        )
        XCTAssertEqual(lateConnect, .noOp, "a connect of the closed epoch is not the epoch's manager speaking")
        let lateTerminal = transport.processOutboundDisconnect(
            peerId: peerId, expectedGen: oldGen, peripheral: nil,
            sourceEpoch: oldCtx.epoch, from: oldCtx.central
        )
        XCTAssertEqual(lateTerminal, .noOp, "a terminal of the closed epoch changes no new state")
        XCTAssertEqual(transport.capacityAuthority.totalCount, before, "the new epoch's state stands unaltered")
        transport.stop()
    }

    // MARK: - actions retain the validated owner

    func testTimeoutActionsCarryTheIdentityTheyWereAdmittedWith() throws {
        let transport = BleTransport(identity: try makeIdentity(), store: T14MessageStore())
        transport.start()
        let peerId = UUID()
        // A provisional relation: the timeout handler guards connections in
        // the provisional state, which is exactly the state the timer is
        // armed for at the connect branch.
        _ = transport.processOutboundDiscover(
            peerId: peerId, rssi: -50, serviceDataHint: Data([0xFE, 0, 0, 0]), peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: transport.requireContextCentralForTest()
        )
        let gen = transport.centralDriver!.getConnectionGeneration(peerId)

        // The provisional timeout of the live relation acts once.
        let live = transport.dispatchOutboundProvisionalTimeout(peerId: peerId, expectedGen: gen)
        XCTAssertNotEqual(live, .noOp, "the timer of the live relation fires its release")

        // After the epoch closed and a fresh one opened, the very same
        // event - naming the same peer and the same generation - meets a
        // gate that refuses it: the action belongs to the old context.
        transport.stop()
        transport.start()
        let late = transport.dispatchOutboundProvisionalTimeout(peerId: peerId, expectedGen: gen)
        XCTAssertEqual(late, .noOp, "an action retains the identity of the context it was admitted with")
        transport.stop()
    }

    // MARK: - every admitted event is reduced on the executor

    func testTheWholeAdmissionStreamReducesOnTheSerialExecutor() throws {
        let transport = BleTransport(identity: try makeIdentity(), store: T14MessageStore())
        transport.start()
        let ctx = try XCTUnwrap(transport.currentManagerContextForTest())
        let centralId = UUID()
        let rawInfo = remoteLinkInfo(hint: Data([0, 0, 0, 1]))

        var traces: [BleTransport.ReductionTrace] = []
        _ = transport.processInboundWrite(
            centralId: centralId, rawData: rawInfo,
            sourceEpoch: ctx.epoch, from: ctx.peripheral
        )
        traces.append(try XCTUnwrap(transport.lastReductionTraceForTest))
        _ = transport.processInboundSubscribe(
            centralId: centralId, central: nil,
            sourceEpoch: ctx.epoch, from: ctx.peripheral
        )
        traces.append(try XCTUnwrap(transport.lastReductionTraceForTest))
        ctx.peripheralProxy.peripheralManagerDidUpdateState(ctx.peripheral)
        traces.append(try XCTUnwrap(transport.lastReductionTraceForTest))

        XCTAssertEqual(traces.count, 3)
        for trace in traces {
            XCTAssertTrue(trace.ranOnSerialExecutor, "no reduction runs off the executor")
            XCTAssertEqual(trace.epoch, ctx.epoch, "each event was reduced by the epoch that owns the manager")
        }
        // The callback path re-enters: the proxy already executes within
        // the context when the reduction is admitted.
        XCTAssertTrue(traces[2].reentrant, "the callback path is already inside its executor")
        XCTAssertFalse(traces[0].reentrant, "the dispatch path was carried onto the queue")
        transport.stop()
    }
}
