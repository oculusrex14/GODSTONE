import XCTest
import CryptoKit
import GodstoneCore
@testable import GodstoneMesh

final class SessionManagerTests: XCTestCase {

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    private func randomPeerId() -> UUID {
        UUID()
    }

    private final class RecordingTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
        var resultToReturn: PeerTrustApplyResult
        var applyCount = 0
        var lastBinding: ValidatedPeerBinding?
        private let lock = NSLock()

        init(resultToReturn: PeerTrustApplyResult = .accepted) {
            self.resultToReturn = resultToReturn
        }

        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            lock.lock()
            defer { lock.unlock() }
            applyCount += 1
            lastBinding = binding
            return resultToReturn
        }
    }

    func testSessionManager_InitiatorStart_Returns32ByteHs1() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let peerB = UUID()

        let hs1 = smA.initiatorStart(peerB, remoteHint: identityB.nodeHint)
        XCTAssertNotNil(hs1)
        XCTAssertEqual(hs1?.count, 32)
        XCTAssertFalse(smA.isReady(peerB))
    }

    func testSessionManager_ResponderProcessHs1_Returns229ByteHs2() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1)

        XCTAssertNotNil(hs2)
        XCTAssertEqual(hs2?.count, 229)
        XCTAssertFalse(smB.isReady(peerA))
    }

    func testSessionManager_InitiatorProcessHs2_Emits197ByteHs3_AndReachesReady() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let trustA = RecordingTrustAuthority()
        let trustB = RecordingTrustAuthority()
        let smA = SessionManager(identity: identityA, trustAuthority: trustA)
        let smB = SessionManager(identity: identityB, trustAuthority: trustB)

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))

        let hs3 = smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint)
        XCTAssertNotNil(hs3)
        XCTAssertEqual(hs3?.count, 197)
        XCTAssertTrue(smA.isReady(peerB))
        XCTAssertEqual(trustA.applyCount, 1)
    }

    func testSessionManager_ResponderProcessHs3_ReachesReady() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let trustA = RecordingTrustAuthority()
        let trustB = RecordingTrustAuthority()
        let smA = SessionManager(identity: identityA, trustAuthority: trustA)
        let smB = SessionManager(identity: identityB, trustAuthority: trustB)

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))

        let ready = smB.responderProcessHs3(peerA, hs3: hs3, advertisedRemoteHint: identityA.nodeHint)
        XCTAssertTrue(ready)
        XCTAssertTrue(smB.isReady(peerA))
        XCTAssertEqual(trustB.applyCount, 1)
    }

    func testSessionManager_SealAndOpen_RoundTripSucceedsOnlyWhenReady() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))
        let okB = smB.responderProcessHs3(peerA, hs3: hs3, advertisedRemoteHint: identityA.nodeHint)
        XCTAssertTrue(okB)

        let payload = Data("Hello secure mesh runtime on iOS".utf8)
        let cipherAtoB = try XCTUnwrap(smA.seal(peerB, payload))

        let plainB = try XCTUnwrap(smB.open(peerA, cipherAtoB))
        XCTAssertEqual(plainB, payload)

        let reply = Data("Reply from B on iOS".utf8)
        let cipherBtoA = try XCTUnwrap(smB.seal(peerA, reply))

        let plainA = try XCTUnwrap(smA.open(peerB, cipherBtoA))
        XCTAssertEqual(plainA, reply)
    }

    func testSessionManager_SealBeforeReady_ReturnsNull() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let peerB = randomPeerId()

        XCTAssertNil(smA.seal(peerB, Data("cleartext".utf8)))
    }

    func testSessionManager_OpenBeforeReady_ReturnsNull() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let peerB = randomPeerId()

        XCTAssertNil(smA.open(peerB, Data("ciphertext".utf8)))
    }

    func testSessionManager_QuarantinedHandshake_NeverReachesReady_SealFails() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let trustA = RecordingTrustAuthority(resultToReturn: .keyChangedQuarantined)
        let smA = SessionManager(identity: identityA, trustAuthority: trustA)
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))

        let hs3 = smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.seal(peerB, Data("data".utf8)))
    }

    func testSessionManager_RejectedHandshake_NeverReachesReady_SealFails() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let trustA = RecordingTrustAuthority(resultToReturn: .rejected(.rollback))
        let smA = SessionManager(identity: identityA, trustAuthority: trustA)
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))

        let hs3 = smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint)
        XCTAssertNil(hs3)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.seal(peerB, Data("data".utf8)))
    }

    func testSessionManager_DropPeer_CleansUpController_SealFails() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))
        _ = smB.responderProcessHs3(peerA, hs3: hs3, advertisedRemoteHint: identityA.nodeHint)

        XCTAssertTrue(smA.isReady(peerB))
        smA.drop(peerB)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.seal(peerB, Data("data".utf8)))
    }

    func testSessionManager_DestroyAll_DestroysAllControllers() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        _ = smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint)

        XCTAssertTrue(smA.isReady(peerB))
        smA.destroyAll()
        XCTAssertFalse(smA.isReady(peerB))
    }

    func testSessionManager_InvalidateForWipe_PermanentlyRefusesNewAndExistingSessions() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let gate = DefaultRuntimeLifecycleGate()
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority(), lifecycleGate: gate)
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        _ = smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint)
        XCTAssertTrue(smA.isReady(peerB))

        smA.invalidateForWipe()
        XCTAssertTrue(smA.isInvalidated)
        XCTAssertFalse(smA.isActive)
        XCTAssertFalse(smA.isReady(peerB))
        XCTAssertNil(smA.seal(peerB, Data("data".utf8)))
        XCTAssertNil(smA.open(peerB, Data("data".utf8)))

        // Refuses new sessions
        XCTAssertNil(smA.initiatorStart(randomPeerId(), remoteHint: Data(count: 4)))
        XCTAssertNil(smA.responderProcessHs1(randomPeerId(), remoteHint: Data(count: 4), hs1: Data(count: 32)))
    }

    // ------------------------------------------------------------- CRYPTO-001
    //
    // The law these arms assert is the audit's own: THE SESSION AUTHORITY ITSELF
    // must refuse an operation that belongeth to a relation which hath been
    // replaced, and a relation's crypto slot must be keyed by the WHOLE relation --
    // direction included -- and not by the platform handle alone.
    //
    // These arms were run RED against the tree BEFORE any production line was
    // touched; the failing run is kept in the finding's evidence log, separate from
    // the repaired run. In their RED form the teardown could only be addressed to
    // the handle, and it slew the replacement (assertion: "a teardown that belongs
    // to the REPLACED relation slew its replacement"), and the responder's slot was
    // stamped outbound. The law asserted is unchanged; only the vocabulary is now
    // the production one -- an ADMISSION -- because the finding WAS the absence of
    // that vocabulary.

    /// Drives one full trusted handshake between two registries over ONE platform
    /// handle, each side presenting the admission its own direction carrieth.
    @discardableResult
    private func handshake(_ initiator: SessionManager, _ responder: SessionManager,
                           outbound: RelationAdmission, inbound: RelationAdmission,
                           initiatorHint: Data, responderHint: Data) throws -> Bool {
        let hs1 = try XCTUnwrap(initiator.initiatorStart(outbound, remoteHint: responderHint))
        let hs2 = try XCTUnwrap(responder.responderProcessHs1(
            inbound, remoteHint: initiatorHint, hs1: hs1))
        let hs3 = try XCTUnwrap(initiator.initiatorProcessHs2(
            outbound, hs2: hs2, advertisedRemoteHint: responderHint))
        return responder.responderProcessHs3(inbound, hs3: hs3,
                                             advertisedRemoteHint: initiatorHint)
    }

    private func admission(_ handle: UUID, generation: UInt64,
                           epoch: UInt64 = 1) -> (outbound: RelationAdmission,
                                                  inbound: RelationAdmission) {
        (RelationAdmission(direction: .outboundCentral, peerId: handle,
                           generation: generation, transportEpoch: epoch),
         RelationAdmission(direction: .inboundPeripheral, peerId: handle,
                           generation: generation, transportEpoch: epoch))
    }

    func testCRYPTO001_aTeardownAddressedToAReplacedRelationMustNotSlayItsReplacement() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        // ONE platform handle, TWO incarnations: the station is replaced while
        // the handle stands. This is the audit's own reproduction.
        let handle = randomPeerId()
        let a = admission(handle, generation: 0)
        let b = admission(handle, generation: 1)

        // Incarnation A: admitted, handshaken, READY.
        XCTAssertTrue(try handshake(smA, smB, outbound: a.outbound, inbound: a.inbound,
                                    initiatorHint: identityA.nodeHint,
                                    responderHint: identityB.nodeHint))
        XCTAssertTrue(smA.isReady(a.outbound))
        let aToB = try XCTUnwrap(smA.seal(a.outbound, Data("incarnation A".utf8)))
        XCTAssertEqual(try smB.open(a.inbound, aToB), Data("incarnation A".utf8))
        let backFromB = try XCTUnwrap(smB.seal(a.inbound, Data("and back".utf8)))
        XCTAssertEqual(try smA.open(a.outbound, backFromB), Data("and back".utf8))
        XCTAssertEqual(smA.drop(a.outbound), .retired)
        XCTAssertEqual(smB.drop(a.inbound), .retired)

        // A is gone. The replacement B occupies the very same handle.
        XCTAssertTrue(try handshake(smA, smB, outbound: b.outbound, inbound: b.inbound,
                                    initiatorHint: identityA.nodeHint,
                                    responderHint: identityB.nodeHint))
        XCTAssertTrue(smA.isReady(b.outbound), "the replacement must be READY before the stale work arrives")

        // Now A's DELAYED teardown arrives -- the teardown that was queued against
        // the incarnation the station already replaced. It must be REFUSED BY NAME.
        XCTAssertEqual(smA.drop(a.outbound), .stale,
                       "a teardown of the replaced incarnation was accepted")
        XCTAssertEqual(smB.drop(a.inbound), .stale,
                       "the responder accepted a teardown of the replaced incarnation")

        XCTAssertTrue(smA.isReady(b.outbound),
                      "a teardown that belongs to the REPLACED relation slew its replacement")
        XCTAssertTrue(smB.isReady(b.inbound),
                      "the responder side of the replacement was slain by stale work")
        let live = try XCTUnwrap(smA.seal(b.outbound, Data("replacement lives".utf8)))
        XCTAssertEqual(try smB.open(b.inbound, live), Data("replacement lives".utf8))
        // The replacement's own teardown still worketh, and only it.
        XCTAssertEqual(smA.drop(b.outbound), .retired)
        XCTAssertFalse(smA.isReady(b.outbound))
        XCTAssertNil(smA.seal(b.outbound, Data("gone".utf8)))
    }

    func testCRYPTO001_staleHandshakeAndCipherWorkIsRefusedAtTheAuthority() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())
        let handle = randomPeerId()
        let a = admission(handle, generation: 0)
        let b = admission(handle, generation: 1)

        XCTAssertTrue(try handshake(smA, smB, outbound: a.outbound, inbound: a.inbound,
                                    initiatorHint: identityA.nodeHint,
                                    responderHint: identityB.nodeHint))
        let cipherFromA = try XCTUnwrap(smA.seal(a.outbound, Data("A only".utf8)))
        XCTAssertEqual(smA.drop(a.outbound), .retired)
        XCTAssertEqual(smB.drop(a.inbound), .retired)
        XCTAssertTrue(try handshake(smA, smB, outbound: b.outbound, inbound: b.inbound,
                                    initiatorHint: identityA.nodeHint,
                                    responderHint: identityB.nodeHint))

        // A's queued ciphertext, delivered into the replacement's lifetime: the
        // authority refuseth it, and the replacement's own traffic is unharmed --
        // the stale frame is not opened against the replacement's keys, and its
        // failed open doth not consume the replacement's state.
        XCTAssertNil(smB.open(a.inbound, cipherFromA))
        if case .authenticated = smB.openWithResult(a.inbound, cipherFromA) {
            XCTFail("the authority authenticated work of a replaced incarnation")
        }
        // A's half-spoken handshake step, on the same terms.
        XCTAssertFalse(smB.responderProcessHs3(a.inbound, hs3: Data(count: 197),
                                               advertisedRemoteHint: identityA.nodeHint))
        XCTAssertNil(smA.initiatorProcessHs2(a.outbound, hs2: Data(count: 229),
                                             advertisedRemoteHint: identityB.nodeHint))
        XCTAssertNil(smA.seal(a.outbound, Data("stale seal".utf8)))
        XCTAssertTrue(smA.isReady(b.outbound), "stale work disturbed the replacement")
        XCTAssertTrue(smB.isReady(b.inbound), "stale work disturbed the responder's replacement")
        let genuine = try XCTUnwrap(smA.seal(b.outbound, Data("genuine".utf8)))
        XCTAssertEqual(try smB.open(b.inbound, genuine), Data("genuine".utf8))
    }

    func testCRYPTO001_anInboundAndAnOutboundRelationOfOneHandleAreTwoRelations() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())
        let centralHandle = randomPeerId()
        let peripheralHandle = randomPeerId()

        // TWO relations of ONE manager, in OPPOSITE directions: the responder of a
        // first relation and the initiator of a second. A registry which stampeth
        // every relation outbound collapseth them into one slot on the first side.
        let asInbound = admission(centralHandle, generation: 0)
        let asOutbound = admission(peripheralHandle, generation: 0)

        let hs1 = try XCTUnwrap(smA.initiatorStart(asOutbound.outbound,
                                                   remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(asInbound.inbound,
                                                        remoteHint: identityA.nodeHint, hs1: hs1))
        _ = smA.initiatorProcessHs2(asOutbound.outbound, hs2: hs2,
                                    advertisedRemoteHint: identityB.nodeHint)

        // The responder's slot carrieth the direction of ITS relation.
        let responderSlot = try XCTUnwrap(smB.slotForTest(centralHandle))
        XCTAssertEqual(responderSlot.key.direction, .inboundPeripheral,
                       "the responder's relation was stamped outbound: the key carrieth no direction")
        XCTAssertEqual(responderSlot.admission.generation, 0)
        XCTAssertEqual(responderSlot.admission.transportEpoch, 1)
        // And one manager holdeth a second, outbound relation of ANOTHER handle
        // without either disturbing the other.
        XCTAssertEqual(smB.incarnationCountForTest(centralHandle), 1)
        XCTAssertEqual(smA.incarnationCountForTest(peripheralHandle), 1)
        XCTAssertEqual(smA.incarnationCountForTest(centralHandle), 0)
        XCTAssertEqual(smB.drop(asInbound.inbound), .retired)
        XCTAssertNil(smB.slotForTest(centralHandle),
                     "the responder's slot perished with its own relation")
        XCTAssertTrue(smA.isReady(asOutbound.outbound),
                      "the initiator's relation of another handle was disturbed")
    }

    func testCRYPTO001_aNewerIncarnationSupersedesTheStandingOne() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let handle = randomPeerId()
        let first = admission(handle, generation: 0)
        let second = admission(handle, generation: 1)

        _ = smA.initiatorStart(first.outbound, remoteHint: Data(count: 4))
        XCTAssertEqual(smA.incarnationCountForTest(handle), 1)
        let firstSlot = try XCTUnwrap(smA.slotForTest(handle))

        // The NEXT generation of the same place is admitted: ONE live incarnation,
        // and it is not the old one.
        _ = smA.initiatorStart(second.outbound, remoteHint: Data(count: 4))
        XCTAssertEqual(smA.incarnationCountForTest(handle), 1,
                       "two incarnations of one place stood together")
        let secondSlot = try XCTUnwrap(smA.slotForTest(handle))
        XCTAssertFalse(firstSlot === secondSlot, "the admission did not supersede the incumbent")
        XCTAssertEqual(secondSlot.admission, second.outbound)
        // A third generation of the SAME place: still one, and the second is refused
        // by its own name once replaced.
        let third = admission(handle, generation: 2)
        _ = smA.initiatorStart(third.outbound, remoteHint: Data(count: 4))
        XCTAssertEqual(smA.incarnationCountForTest(handle), 1)
        XCTAssertEqual(smA.drop(second.outbound), .stale)
        XCTAssertEqual(smA.slotCountForTest(), 1)
    }

    func testCRYPTO001_theAppLevelDepartureRetiresEveryIncarnationOfTheHandle() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let sm = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let other = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())
        let handle = randomPeerId()
        let elsewhere = randomPeerId()
        let both = admission(handle, generation: 0)
        let untouched = admission(elsewhere, generation: 0)

        // sm playeth the INITIATOR on one relation of [handle] ...
        let hs1 = try XCTUnwrap(sm.initiatorStart(both.outbound, remoteHint: identityB.nodeHint))
        _ = try XCTUnwrap(other.responderProcessHs1(both.inbound, remoteHint: identityA.nodeHint, hs1: hs1))
        // ... and the RESPONDER on the OTHER direction of the same handle ...
        let inboundHs1 = try XCTUnwrap(other.initiatorStart(
            untouched.outbound, remoteHint: identityA.nodeHint))
        _ = sm.responderProcessHs1(both.inbound, remoteHint: identityB.nodeHint, hs1: inboundHs1)
        // ... and holdeth a third relation of ANOTHER handle.
        _ = sm.initiatorStart(untouched.outbound, remoteHint: identityB.nodeHint)

        XCTAssertEqual(sm.incarnationCountForTest(handle), 2,
                       "the two directions of one handle must be two relations")
        XCTAssertEqual(sm.incarnationCountForTest(elsewhere), 1)
        XCTAssertEqual(sm.retireIncarnations(ofPeerId: handle), 2)
        XCTAssertEqual(sm.incarnationCountForTest(handle), 0)
        XCTAssertEqual(sm.incarnationCountForTest(elsewhere), 1)
        XCTAssertNotNil(sm.slotForTest(elsewhere))
    }
}
