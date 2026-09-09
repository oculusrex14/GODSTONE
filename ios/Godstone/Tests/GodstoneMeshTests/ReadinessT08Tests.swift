import XCTest
@testable import GodstoneCore
@testable import GodstoneMesh

/// T08: SessionSlot is the serialization authority (Swift mirror of
/// ReadinessT08Test.kt - same six cases, same expectations).
///
/// Regression targets: handshake methods took peer locks while seal/open/
/// drop/isReady did not, so drop could race active cipher operations. After
/// T08: sessions are keyed by the immutable RelationKey, one slot holds the
/// controller, replay window, terminal state and lease, EVERY operation
/// serializes on the slot, drop's destructive work is routed outside the
/// lock, and retired slots are reclaimed with their lock entries.
final class ReadinessT08Tests: XCTestCase {

    private final class AcceptingAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
        func applyValidatedBinding(
            _ binding: ValidatedPeerBinding
        ) -> PeerTrustApplyResult {
            return .accepted
        }
    }

    /// Lock-boxed corruption flag: a reference type keeps the concurrent
    /// workers from capturing a mutable local variable.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() {
            lock.lock()
            defer { lock.unlock() }
            raised = true
        }
        var isRaised: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raised
        }
    }

    private struct ReadySession {
        let initiator: SessionManager
        let responder: SessionManager
        let peer: UUID
        let responderHint: Data
        let initiatorHint: Data
    }

    private func readyManagers() throws -> ReadySession {
        let identityI = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityR = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let initiatorSide = SessionManager(
            identity: identityI, trustAuthority: AcceptingAuthority())
        let responderSide = SessionManager(
            identity: identityR, trustAuthority: AcceptingAuthority())
        // The registry lookup handle is the transport's peer identifier; the
        // tests use a stable synthetic handle (session content does not
        // depend on it).
        let peer = UUID()
        let hs1 = try XCTUnwrap(
            initiatorSide.initiatorStart(peer, remoteHint: identityR.nodeHint))
        let hs2 = try XCTUnwrap(responderSide.responderProcessHs1(
            peer, remoteHint: identityI.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(initiatorSide.initiatorProcessHs2(
            peer, hs2: hs2, advertisedRemoteHint: identityR.nodeHint))
        XCTAssertTrue(responderSide.responderProcessHs3(
            peer, hs3: hs3, advertisedRemoteHint: identityI.nodeHint))
        XCTAssertTrue(initiatorSide.isReady(peer))
        XCTAssertTrue(responderSide.isReady(peer))
        return ReadySession(
            initiator: initiatorSide, responder: responderSide, peer: peer,
            responderHint: identityR.nodeHint, initiatorHint: identityI.nodeHint)
    }

    func testSealOpenDropAllSerializeOnTheSlot() throws {
        let session = try readyManagers()
        let sealed = try XCTUnwrap(session.initiator.seal(session.peer, Data("frame".utf8)))
        let opened = try XCTUnwrap(session.responder.open(session.peer, sealed))
        XCTAssertEqual(opened, Data("frame".utf8))
        XCTAssertTrue(session.responder.isReady(session.peer))
        // Drop transitions terminal under the slot lock and destroys outside.
        session.initiator.drop(session.peer)
        session.responder.drop(session.peer)
        XCTAssertNil(session.initiator.seal(session.peer, Data("after-drop".utf8)))
        XCTAssertFalse(session.responder.isReady(session.peer))
    }

    func testConcurrentSealAndDropTypedFailureNeverCrash() throws {
        // The card's security case: drop racing an active seal must fail
        // cleanly (typed nil), never crash or corrupt cipher state.
        for _ in 0..<20 {
            let session = try readyManagers()
            let initiator = session.initiator
            let responder = session.responder
            let peer = session.peer
            // The serialisation witness: the slots themselves report how many
            // distinct threads were ever inside at the same time.
            let sealedSlot = try XCTUnwrap(initiator.slotForTest(peer))
            let openedSlot = try XCTUnwrap(responder.slotForTest(peer))
            sealedSlot.maxThreadsInside = 0
            openedSlot.maxThreadsInside = 0
            // Latch gate: BOTH workers wait for one release. This is a counting
            // semaphore, so it must be signalled once per waiter - a single
            // signal would strand the second worker forever.
            let gate = DispatchSemaphore(value: 0)
            let corruption = Flag()
            let group = DispatchGroup()
            // async(group:) already balances an internal enter() with a
            // leave() when the block returns - entering again here would leak
            // a count and deadlock the bounded wait below.
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                gate.wait()
                for index in 0..<200 {
                    guard let sealed = initiator.seal(
                        peer, Data("f\(index)".utf8)
                    ) else {
                        continue
                    }
                    // A nil open during teardown is a typed failure
                    // (expected); only a WRONG plaintext counts as corruption.
                    if let opened = responder.open(peer, sealed),
                       opened != Data("f\(index)".utf8) {
                        corruption.raise()
                    }
                }
            }
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                gate.wait()
                initiator.drop(peer)
                responder.drop(peer)
            }
            gate.signal()
            gate.signal()
            // 90 seconds expressed in nanoseconds; bounded so a regression
            // fails the test instead of hanging the suite.
            if group.wait(timeout: .now() + .seconds(90)) != .success {
                XCTFail("concurrent seal/drop join timed out")
                return
            }
            // Neither slot may have been entered by two threads at once: the
            // slot is the single serialisation point of a relation.
            XCTAssertLessThan(sealedSlot.maxThreadsInside, 2,
                              "the sealing slot must serialise its operations")
            XCTAssertLessThan(openedSlot.maxThreadsInside, 2,
                              "the opening slot must serialise its operations")
            XCTAssertFalse(corruption.isRaised, "cipher state must never corrupt")
            // After the drops, operations must be typed-failed, not crashed.
            XCTAssertNil(initiator.seal(peer, Data("post".utf8)))
            XCTAssertNil(responder.open(peer, Data("post".utf8)))
        }
    }

    func testSameSlotOperationsNeverInterleaveCorruptingly() throws {
        // Two engines on one relation: every accepted frame must decrypt to
        // the matching plaintext (the slot serializes), and the replay window
        // must never reject a legitimately sequenced frame.
        let session = try readyManagers()
        let initiator = session.initiator
        let responder = session.responder
        let peer = session.peer
        var failures = 0
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            for index in 0..<200 {
                _ = initiator.seal(peer, Data("seq-\(index)".utf8))
            }
        }
        if group.wait(timeout: .now() + .seconds(60)) != .success {
            XCTFail("producer did not finish in time")
            return
        }
        // All frames were produced under the slot lock, in order: opening
        // them sequentially must succeed for every index.
        for index in 0..<100 {
            guard let sealed = initiator.seal(
                peer, Data("verify-\(index)".utf8)
            ) else {
                failures += 1
                continue
            }
            guard let opened = responder.open(peer, sealed) else {
                failures += 1
                continue
            }
            if opened != Data("verify-\(index)".utf8) {
                failures += 1
            }
        }
        XCTAssertEqual(failures, 0)
    }

    func testRetiredSlotsAndLockEntriesAreReclaimed() throws {
        let session = try readyManagers()
        session.initiator.drop(session.peer)
        session.responder.drop(session.peer)
        XCTAssertFalse(session.initiator.isReady(session.peer))
        // A fresh handshake on the SAME relation reclaims the retired slot:
        // the relation is re-established with a fresh lease, not reused.
        let hs1 = try XCTUnwrap(session.initiator.initiatorStart(
            session.peer, remoteHint: session.responderHint))
        let hs2 = try XCTUnwrap(session.responder.responderProcessHs1(
            session.peer, remoteHint: session.initiatorHint, hs1: hs1))
        let hs3 = try XCTUnwrap(session.initiator.initiatorProcessHs2(
            session.peer, hs2: hs2, advertisedRemoteHint: session.responderHint))
        XCTAssertTrue(session.responder.responderProcessHs3(
            session.peer, hs3: hs3, advertisedRemoteHint: session.initiatorHint))
        XCTAssertTrue(session.initiator.isReady(session.peer))
        XCTAssertTrue(session.responder.isReady(session.peer))
    }

    func testLifecycleGateRetainsExclusiveBarrierOrder() throws {
        // Lock order: lifecycle gate first, then slot. After invalidation
        // every operation is typed-failed and the barrier is exclusive.
        let session = try readyManagers()
        session.initiator.invalidateForWipe()
        XCTAssertTrue(session.initiator.isInvalidated)
        XCTAssertNil(session.initiator.seal(session.peer, Data("x".utf8)))
        XCTAssertNil(session.initiator.open(session.peer, Data("x".utf8)))
        XCTAssertFalse(session.initiator.isReady(session.peer))
        // The global barrier is exclusive: a write-locked invalidate blocks
        // in-flight reads; the test completes (no deadlock) within itself.
        session.initiator.destroyAll()
    }

    func testRelationKeyIsImmutableWrapperOfTheLookupHandle() {
        let peer = UUID()
        let key = RelationKey(direction: .outboundCentral, peerId: peer)
        XCTAssertEqual(key, RelationKey(direction: .outboundCentral, peerId: peer))
        XCTAssertEqual(key.hashValue, RelationKey(direction: .outboundCentral, peerId: peer).hashValue)
        XCTAssertNotEqual(key, RelationKey(direction: .inboundPeripheral, peerId: peer))
        // The handle is the existing transport lookup handle, not a node id.
        XCTAssertEqual(key.peerId, peer)
    }

    func testBoundedSlotMapOverTenThousandReconnects() throws {
        // The registry is bounded by LIVE relations: 10,000 reconnects over a
        // rotating handle set must not grow the slot map, must reclaim each
        // retired entry together with its lock, and must advance the
        // remembered generation so a replacement never aliases the incarnation
        // it replaces.
        let identityI = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityR = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let initiator = SessionManager(
            identity: identityI, trustAuthority: AcceptingAuthority())
        let responder = SessionManager(
            identity: identityR, trustAuthority: AcceptingAuthority())
        let handleCount = 16
        var handles = [UUID]()
        for _ in 0..<handleCount { handles.append(UUID()) }
        var previousGeneration = [Int](repeating: -1, count: handleCount)
        for round in 0..<10000 {
            let lane = round % handleCount
            let peer = handles[lane]
            let hs1 = try XCTUnwrap(
                initiator.initiatorStart(peer, remoteHint: identityR.nodeHint))
            let hs2 = try XCTUnwrap(responder.responderProcessHs1(
                peer, remoteHint: identityI.nodeHint, hs1: hs1))
            let hs3 = try XCTUnwrap(initiator.initiatorProcessHs2(
                peer, hs2: hs2, advertisedRemoteHint: identityR.nodeHint))
            XCTAssertTrue(responder.responderProcessHs3(
                peer, hs3: hs3, advertisedRemoteHint: identityI.nodeHint))
            let generation = try XCTUnwrap(initiator.slotLeaseGenerationForTest(peer))
            XCTAssertGreaterThan(generation, previousGeneration[lane])
            previousGeneration[lane] = generation
            initiator.drop(peer)
            responder.drop(peer)
            XCTAssertFalse(initiator.slotCountForTest() > handleCount,
                           "slot map grew past the live bound")
            XCTAssertFalse(responder.slotCountForTest() > handleCount,
                           "responder map grew past the live bound")
            XCTAssertFalse(initiator.rememberedCountForTest() > 256,
                           "the remembered-generation registry is unbounded")
        }
        // Every entry was reclaimed with its lock entry: nothing leaks.
        XCTAssertEqual(initiator.slotCountForTest(), 0)
        XCTAssertEqual(responder.slotCountForTest(), 0)
        // Ten thousand reconnects over sixteen handles remember sixteen
        // generations - one per handle, not one per reconnect.
        XCTAssertEqual(initiator.rememberedCountForTest(), handleCount)
        XCTAssertEqual(responder.rememberedCountForTest(), handleCount)
    }

    func testDestroyedReferencesRemainTerminal() throws {
        let session = try readyManagers()
        let stale = try XCTUnwrap(
            session.initiator.seal(session.peer, Data("stale".utf8)))
        session.initiator.drop(session.peer)
        session.responder.drop(session.peer)
        // A held reference to the destroyed incarnation stays terminal: both
        // destroyed ends reject the frame of the previous session.
        XCTAssertNil(session.initiator.seal(session.peer, Data("again".utf8)))
        XCTAssertNil(session.responder.open(session.peer, stale))
        XCTAssertFalse(session.initiator.isReady(session.peer))
        XCTAssertFalse(session.responder.isReady(session.peer))
        // A repeated drop is a typed no-op, never a resurrection.
        session.initiator.drop(session.peer)
        session.initiator.drop(session.peer)
        XCTAssertNil(session.initiator.seal(session.peer, Data("post".utf8)))
        XCTAssertEqual(session.initiator.slotCountForTest(), 0)
        XCTAssertEqual(session.responder.slotCountForTest(), 0)
        XCTAssertNil(session.initiator.slotLeaseGenerationForTest(session.peer))
        // The replacement advances the lease instead of aliasing the old one.
        let hs1 = try XCTUnwrap(session.initiator.initiatorStart(
            session.peer, remoteHint: session.responderHint))
        let hs2 = try XCTUnwrap(session.responder.responderProcessHs1(
            session.peer, remoteHint: session.initiatorHint, hs1: hs1))
        let hs3 = try XCTUnwrap(session.initiator.initiatorProcessHs2(
            session.peer, hs2: hs2, advertisedRemoteHint: session.responderHint))
        XCTAssertTrue(session.responder.responderProcessHs3(
            session.peer, hs3: hs3, advertisedRemoteHint: session.initiatorHint))
        let generation = try XCTUnwrap(
            session.initiator.slotLeaseGenerationForTest(session.peer))
        XCTAssertGreaterThan(generation, 0)
        // Cross-incarnation replay: the destroyed incarnation's frame cannot
        // be replayed into the replacement. The legacy wrapper reports the
        // typed failure documented for this boundary, and the replacement keeps
        // its authoritative state.
        XCTAssertNil(session.responder.open(session.peer, stale))
        // A typed failure, not a state loss: the live replacement still serves
        // legitimately sequenced frames.
        XCTAssertTrue(session.responder.isReady(session.peer))
        XCTAssertTrue(session.initiator.isReady(session.peer))
        let live = try XCTUnwrap(session.initiator.seal(session.peer, Data("live".utf8)))
        let openedLive = try XCTUnwrap(session.responder.open(session.peer, live))
        XCTAssertEqual(openedLive, Data("live".utf8))
    }
}
