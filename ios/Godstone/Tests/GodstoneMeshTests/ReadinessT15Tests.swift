import XCTest
import Foundation
import CoreBluetooth
@testable import GodstoneCore
@testable import GodstoneMesh

/// T15: every timer owns an immutable operation key
/// (TimerKey = RelationKey + operation kind + unique operation id). Timers
/// are stored, cancelled and replaced only through the context reducer;
/// callbacks capture the whole key and compare its identity before removing
/// or transitioning anything; deadlines are explicit under the injected
/// monotonic clock; counters are never relied on without their epoch.
///
/// Swift mirror of the card's scenarios: an old timer fires after
/// stop/start with reused generation; duplicate fire; replaced timer
/// cancellation; exact deadline; no timer retained after terminal.
final class ReadinessT15Tests: XCTestCase {

    // MARK: - fixtures

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { return storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    /// Deterministic monotonic time at the real dependency boundary the
    /// card names; the production SystemMonotonicClock is never exercised
    /// by assertion here - only its protocol is replaced.
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

    private func makeIdentity(seedByte: UInt8 = 1, staticPrivByte: UInt8 = 2, generation: UInt32 = 0) throws -> MeshIdentity {
        let kc = InMemoryKeychain()
        let edSeed = Data(repeating: seedByte, count: 32)
        let xPriv = Data(repeating: staticPrivByte, count: 32)
        let state = try LocalIdentityStateV1(generation: generation, ed25519Seed: edSeed, x25519PrivateKey: xPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        return try MeshIdentity.loadFromKeychain(keychain: kc)
    }

    private func key(of snap: BleTransport.TimerLeaseSnapshot) -> TimerKey {
        return TimerKey(relation: RelationKey(direction: snap.direction, peerId: snap.peerId, generation: snap.generation),
                        operation: snap.operation, operationId: snap.operationId)
    }

    private func leaseOf(_ transport: BleTransport, peerId: UUID, operation: TimerOperationKind) -> BleTransport.TimerLeaseSnapshot? {
        return transport.timerLeaseSnapshotForTest().first { $0.peerId == peerId && $0.operation == operation }
    }

    /// The inbound link-info advertisement the subscription path accepts,
    /// verbatim from the proven composition sequences.
    private func remoteLinkInfo(hint: Data) -> Data {
        return BleLinkInfoCodec.encode(
            version: BleLinkInfoConstants.protocolVersion,
            flags: 0,
            nodeHint: hint,
            shortDigest: Data(repeating: 0, count: 6),
            queueDepth: 0
        )
    }

    // MARK: - old timer, reused generation, stop/start in between

    func testStaleFireAfterReopenCannotActOnTheReusedGeneration() throws {
        let clock = TestClock(startingAt: 5_000)
        let transport = BleTransport(identity: try makeIdentity(), store: nil, clock: clock)
        transport.start()
        let peerA = UUID()
        let cm = transport.requireContextCentralForTest()
        _ = transport.processOutboundDiscover(
            peerId: peerA, rssi: -60, serviceDataHint: Data([0xFE, 0, 0, 0]), peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        guard let firstLease = leaseOf(transport, peerId: peerA, operation: .provisionalOutbound) else {
            XCTFail("the admission armed no lease")
            return
        }
        let staleKey = key(of: firstLease)
        XCTAssertEqual(firstLease.generation, 1, "the fresh driver issues generation one")

        // The epoch closes and a successor opens: the driver is replaced and
        // its generation counter starts again - the very reuse the card
        // names. A different peer is admitted, so its lease bears the same
        // direction, the same operation and again generation one.
        transport.stop()
        XCTAssertEqual(transport.timerLeaseCountForTest(), 0, "the closing sweep left no lease held")
        transport.start()
        let peerB = UUID()
        let cm2 = transport.requireContextCentralForTest()
        _ = transport.processOutboundDiscover(
            peerId: peerB, rssi: -60, serviceDataHint: Data([0xFE, 0, 0, 0]), peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm2
        )
        guard let liveLease = leaseOf(transport, peerId: peerB, operation: .provisionalOutbound) else {
            XCTFail("the reopened epoch armed no lease")
            return
        }
        XCTAssertEqual(liveLease.generation, 1, "the generation was genuinely reused")
        XCTAssertNotEqual(liveLease.operationId, staleKey.operationId,
                          "the operation id source is never reset, so no key of the old epoch can collide with the new")

        // The old fire, with its whole captured key, reaches the executor:
        // identity refuses it and the live lease stands untouched.
        XCTAssertFalse(transport.fireTimerForTest(staleKey), "a stale fire acts nowhere")
        let afterStale = try XCTUnwrap(leaseOf(transport, peerId: peerB, operation: .provisionalOutbound))
        XCTAssertEqual(afterStale.operationId, liveLease.operationId, "the live lease is where it was")
        XCTAssertEqual(afterStale.deadlineUptimeMillis, liveLease.deadlineUptimeMillis, "nothing moved under the refused fire")

        // The live fire acts exactly once.
        XCTAssertTrue(transport.fireTimerForTest(key(of: afterStale)), "the lease's own fire acts")
        XCTAssertEqual(transport.timerLeaseCountForTest(), 0, "acting consumed the lease")
        transport.stop()
    }

    // MARK: - duplicate fire

    func testDuplicateFireActsExactlyOnce() throws {
        let clock = TestClock(startingAt: 1_000)
        let transport = BleTransport(identity: try makeIdentity(), store: nil, clock: clock)
        transport.start()
        let peerId = UUID()
        let cm = transport.requireContextCentralForTest()
        _ = transport.processOutboundDiscover(
            peerId: peerId, rssi: -50, serviceDataHint: Data([0xFE, 0, 0, 0]), peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        XCTAssertEqual(transport.capacityAuthority.outboundCount, 1, "one admission stands")
        guard let lease = leaseOf(transport, peerId: peerId, operation: .provisionalOutbound) else {
            XCTFail("no lease was armed"); return
        }
        let k = key(of: lease)
        XCTAssertTrue(transport.fireTimerForTest(k), "the first fire acts")
        XCTAssertFalse(transport.fireTimerForTest(k), "the duplicate fire is refused by the whole-key check")
        XCTAssertEqual(transport.timerLeaseCountForTest(), 0, "the lease was consumed once, by the first fire")
        XCTAssertEqual(transport.capacityAuthority.outboundCount, 0, "the release ran exactly once")
        XCTAssertEqual(transport.connection(for: peerId)?.state ?? .closed, .closed,
                       "the relation terminated once, not twice")
        transport.stop()
    }

    // MARK: - replaced timer cancellation

    func testReplacedLeaseSurvivesTheStaleFiresOfItsSlot() throws {
        let clock = TestClock(startingAt: 5_000)
        let transport = BleTransport(identity: try makeIdentity(), store: nil, clock: clock)
        transport.start()
        let peerId = UUID()
        let cm = transport.requireContextCentralForTest()
        _ = transport.processOutboundDiscover(
            peerId: peerId, rssi: -60, serviceDataHint: Data([0xFE, 0, 0, 0]), peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        guard let elder = leaseOf(transport, peerId: peerId, operation: .provisionalOutbound) else {
            XCTFail("the admission armed no lease"); return
        }

        // The attempt advances into the handshake: the reducer re-arms the
        // slot - the replacement compares the whole key of the current lease
        // before cancelling exactly that handle, and installs a fresh
        // operation id over the same relation. Under the named mutation -
        // removing the current timer before the key comparison - the blind
        // cancel catches the NEWER lease and this table comes up empty.
        clock.advance(1_000)
        _ = transport.processCentralConnect(
            peerId: peerId, peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        XCTAssertEqual(transport.timerLeaseCountForTest(), 1, "the slot holds exactly one lease after replacement")
        guard let younger = leaseOf(transport, peerId: peerId, operation: .provisionalOutbound) else {
            XCTFail("the replacement evicted the slot without installing a lease"); return
        }
        XCTAssertNotEqual(younger.operationId, elder.operationId, "the replacement carries a fresh operation id")
        XCTAssertEqual(younger.generation, elder.generation, "the relation is the same attempt's")
        XCTAssertEqual(younger.deadlineUptimeMillis, 6_000 + 10_000,
                       "the replacement recomputed the deadline against the advanced injected clock")

        XCTAssertFalse(transport.fireTimerForTest(key(of: elder)), "the superseded fire is refused by identity")
        let stillThere = try XCTUnwrap(leaseOf(transport, peerId: peerId, operation: .provisionalOutbound))
        XCTAssertEqual(stillThere.operationId, younger.operationId, "the replacement survived the stale fire")
        XCTAssertTrue(transport.fireTimerForTest(key(of: stillThere)), "the living lease answers its own fire")
        XCTAssertEqual(transport.timerLeaseCountForTest(), 0, "and consumed itself in the acting")
        transport.stop()
    }

    // MARK: - exact deadline under the injected clock

    func testDeadlinesAreExactUnderTheInjectedList() throws {
        let clock = TestClock(startingAt: 4_321)
        let transport = BleTransport(identity: try makeIdentity(), store: nil, provisionalTimeoutSeconds: 10.0, clock: clock)
        transport.start()
        let peerA = UUID()
        let peerB = UUID()
        let cm = transport.requireContextCentralForTest()
        _ = transport.processOutboundDiscover(
            peerId: peerA, rssi: -60, serviceDataHint: Data([0xFE, 0, 0, 0]), peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        guard let a = leaseOf(transport, peerId: peerA, operation: .provisionalOutbound) else {
            XCTFail("no lease for the first admission"); return
        }
        XCTAssertEqual(a.deadlineUptimeMillis, 4_321 + 10_000, "the deadline is computed against the injected monotonic time")

        clock.advance(2_500)
        _ = transport.processOutboundDiscover(
            peerId: peerB, rssi: -60, serviceDataHint: Data([0xFE, 0, 0, 0]), peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        guard let b = leaseOf(transport, peerId: peerB, operation: .provisionalOutbound) else {
            XCTFail("no lease for the second admission"); return
        }
        XCTAssertEqual(b.deadlineUptimeMillis, 4_321 + 2_500 + 10_000,
                       "the second arm sees the advanced clock, never the stale one")
        XCTAssertNotEqual(a.operationId, b.operationId, "distinct operations, distinct ids")
        transport.stop()
    }

    // MARK: - nothing retained after the terminal

    func testNoLeaseSurvivesAnyTerminalPath() throws {
        let transport = BleTransport(identity: try makeIdentity(), store: nil, clock: TestClock(startingAt: 1))
        transport.start()

        // Outbound terminal through the failure path.
        let peerFail = UUID()
        let cm = transport.requireContextCentralForTest()
        _ = transport.processOutboundDiscover(
            peerId: peerFail, rssi: -60, serviceDataHint: Data([0xFE, 0, 0, 0]), peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        XCTAssertNotNil(leaseOf(transport, peerId: peerFail, operation: .provisionalOutbound), "armed while provisional")
        _ = transport.processCentralFailToConnect(
            peerId: peerFail, error: nil, peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        XCTAssertNil(leaseOf(transport, peerId: peerFail, operation: .provisionalOutbound),
                     "the failure terminal released the lease")

        // Outbound terminal through the disconnect path.
        let peerBye = UUID()
        _ = transport.processOutboundDiscover(
            peerId: peerBye, rssi: -60, serviceDataHint: Data([0xFE, 0, 0, 0]), peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        XCTAssertNotNil(leaseOf(transport, peerId: peerBye, operation: .provisionalOutbound))
        _ = transport.processOutboundDisconnect(
            peerId: peerBye, expectedGen: 0, peripheral: nil,
            sourceEpoch: transport.currentTransportEpoch, from: cm
        )
        XCTAssertNil(leaseOf(transport, peerId: peerBye, operation: .provisionalOutbound),
                     "the disconnect terminal released the lease")

        // Inbound terminal through unsubscribe.
        let pm = transport.requireContextPeripheralForTest()
        let centralId = UUID()
        _ = transport.processInboundWrite(centralId: centralId, rawData: remoteLinkInfo(hint: Data([0, 0, 0, 3])), sourceEpoch: transport.currentTransportEpoch, from: pm)
        XCTAssertNotNil(leaseOf(transport, peerId: centralId, operation: .inboundInactivity), "the inbound window stands armed")
        _ = transport.processInboundSubscribe(centralId: centralId, central: nil, sourceEpoch: transport.currentTransportEpoch, from: pm)
        XCTAssertNil(leaseOf(transport, peerId: centralId, operation: .inboundInactivity),
                     "the accepted subscription cancelled the window through the reducer")
        _ = transport.processInboundUnsubscribe(centralId: centralId, expectedGen: 0, sourceEpoch: transport.currentTransportEpoch, from: pm)
        XCTAssertNil(leaseOf(transport, peerId: centralId, operation: .inboundInactivity),
                     "the unsubscribe terminal released nothing that was still held")

        // The closing sweep holds nothing.
        transport.stop()
        XCTAssertEqual(transport.timerLeaseCountForTest(), 0, "no timer is retained past the boundary")
    }
}
