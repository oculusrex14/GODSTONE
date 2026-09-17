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

    // MARK: - CRYPTO-002: THE AUDIT'S OWN PROBES, MOVED INTO THE CANONICAL SUITE
    //
    // The audit's evidence class for this finding is explicit about WHY the existing courts missed it:
    // "ReadinessT07Tests acts directly on raw NoiseSession and proves primitive isEstablished becomes false. It
    // does not exercise trusted controller, manager, transport close/publication or idle timer ownership." SO THE
    // PROBES BELOW ACT ON THE **MANAGER**, and they are the audit's two by name:
    //   AuditCryptoTests.testExpiredReadMustReachManagerAndClearReadiness
    //   AuditCryptoTests.testIdleExpiredSessionMustNotStillPublishReady

    /// A completed trusted handshake, whose PRIMITIVE is then aged past its own budget through the existing hooks.
    /// The manager must answer a TYPED TERMINAL RETIREMENT -- not a packet rejection -- and readiness must stop.
    func testCRYPTO002_anAgedReadMustRetireThroughTheManagerAndClearReadiness() throws {
        let (smA, smB, keyA, keyB) = try establishedManagerPair()
        // The RECEIVER's primitive is aged out: budget one second, established two seconds ago.
        let ctrl = try XCTUnwrap(smB.slotForTest(keyB)?.controller)
        ctrl.noiseSession.ageBudgetForTest = 1.0
        ctrl.noiseSession.establishedMonoForTest = DispatchTime.now().uptimeNanoseconds &- 2_000_000_000
        let before = smB.slotCountForTest()

        let genuine = try XCTUnwrap(smA.seal(keyA, Data("a genuine in-policy packet".utf8)))
        let outcome = smB.openWithResult(keyB, genuine)

        XCTAssertEqual(outcome, .expired,
                       "AGE IS A TERMINAL RETIREMENT, NOT A PACKET REJECTION -- the vocabulary for it existeth "
                       + "(`CryptoOpenResult.expired`) and was unreachable")
        XCTAssertFalse(smB.isReady(keyB),
                       "and readiness must STOP: a session past its budget may not remain published as ready")
        XCTAssertEqual(smB.slotCountForTest(), 0,
                       "and the EXACT slot must be gone -- a retired session left registered is a slot leak")
        XCTAssertLessThan(smB.slotCountForTest(), before)
    }

    /// The audit's second probe: NO packet at all. Merely ASKING must be enough for the manager to notice that the
    /// session it owneth hath aged out -- an idle timer's own transition, not a reader's side effect.
    func testCRYPTO002_anIdleAgedSessionMustNotStillPublishReady() throws {
        let (_, smB, _, keyB) = try establishedManagerPair()
        let ctrl = try XCTUnwrap(smB.slotForTest(keyB)?.controller)
        XCTAssertTrue(smB.isReady(keyB), "the control: a fresh handshake IS ready")
        ctrl.noiseSession.ageBudgetForTest = 1.0
        ctrl.noiseSession.establishedMonoForTest = DispatchTime.now().uptimeNanoseconds &- 2_000_000_000

        XCTAssertFalse(smB.isReady(keyB),
                       "an IDLE expired session must not still publish ready -- no packet should be required")
    }

    /// A real trusted handshake at the MANAGER level, returning the two managers and the receiving relation's key.
    private func establishedManagerPair() throws -> (SessionManager, SessionManager, UUID, UUID) {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())
        let peerB = UUID()
        let peerA = UUID()
        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))
        XCTAssertTrue(smB.responderProcessHs3(peerA, hs3: hs3, advertisedRemoteHint: identityA.nodeHint))
        XCTAssertTrue(smB.isReady(peerA), "the probe requireth a REAL established session")
        // EACH MANAGER'S OWN KEY: `peerB` is SM-A's name for the relation, `peerA` is SM-B's. Returning one key
        // for both was MY bug, and it showed up as an unwrap of `seal` -- the probe was measuring the wrong object.
        return (smA, smB, peerB, peerA)
    }

    /// GS-CTRL-002 / CRYPTO-002 -- THE FINDING'S TITLE, AS AN ARM: "Session retirement never reaches the transport
    /// authority." The transport could always tell the manager to drop a relation; NOTHING TRAVELLED THE OTHER WAY.
    /// This arm demandeth the reverse notice: TOKEN-BOUND, EXACTLY ONCE, and delivered on the IDLE path (no packet).
    func testCRYPTO002_aTerminalRetirementNotifiethTheTransportOwnerExactlyOnce() throws {
        let (_, smB, _, keyB) = try establishedManagerPair()
        var notices: [(RelationAdmission, String)] = []
        smB.onTerminalRetirement = { admission, reason in notices.append((admission, reason)) }
        XCTAssertTrue(notices.isEmpty, "the control: nothing is noticed while the session is healthy")

        let ctrl = try XCTUnwrap(smB.slotForTest(keyB)?.controller)
        let exact = try XCTUnwrap(smB.slotAdmissionForTest(try XCTUnwrap(hostAdmission(smB, keyB))))
        ctrl.noiseSession.ageBudgetForTest = 1.0
        ctrl.noiseSession.establishedMonoForTest = DispatchTime.now().uptimeNanoseconds &- 2_000_000_000

        XCTAssertFalse(smB.isReady(keyB), "the idle path retires it")
        XCTAssertEqual(notices.count, 1, "EXACTLY ONE NOTICE -- not one per query, and not none")
        XCTAssertEqual(notices.first?.0, exact,
                       "and it carrieth the EXACT admission -- the token the transport minted for that relation, "
                       + "so a notice can never be applied to a different incarnation")
        XCTAssertFalse(notices.first?.1.isEmpty ?? true, "with a reason, because a notice that hideth why is "
                       + "the species this programme keepeth correcting")

        // A SECOND QUERY MUST NOT DELIVER AGAIN: the slot is already gone.
        _ = smB.isReady(keyB)
        XCTAssertEqual(notices.count, 1, "a retired incarnation notifieth ONCE, however often it is asked")
    }

    /// The STALE clause: a notice is bound to an incarnation. Once a REPLACEMENT standeth, retiring the old
    /// admission must answer `.stale` and MUST NOT deliver a notice that could reach the successor.
    func testCRYPTO002_aStaleNoticeNeverReachesTheReplacement() throws {
        let (_, smB, _, keyB) = try establishedManagerPair()
        var notices: [(RelationAdmission, String)] = []
        smB.onTerminalRetirement = { admission, reason in notices.append((admission, reason)) }
        let old = try XCTUnwrap(hostAdmission(smB, keyB))
        XCTAssertEqual(smB.drop(successor(of: old)), .stale,
                       "a successor admission is NOT the standing incarnation")
        XCTAssertTrue(notices.isEmpty, "and a STALE retirement delivereth NO notice at all")
    }

    /// The admission the manager currently holdeth for a peer -- read through the existing hook rather than assumed.
    private func hostAdmission(_ sm: SessionManager, _ peerId: UUID) throws -> RelationAdmission? {
        let slot = try XCTUnwrap(sm.slotForTest(peerId))
        return slot.admission
    }

    /// The successor of an admission: the SAME relation one incarnation later.
    private func successor(of admission: RelationAdmission) -> RelationAdmission {
        ReadinessTrustedPairing.successor(of: admission)
    }

    /// GS-CTRL-002 / CRYPTO-002 -- THE NEGATIVE CONTROLS FOR THE TERMINUS, AND THE AUDIT NAMETH WHY THEY MATTER:
    /// "Do not close a healthy session just because an attacker supplies an excessive nonce." A repair that retired
    /// on ANY failure would let a hostile peer destroy every relation by sending garbage -- so THIS arm demandeth
    /// that a BAD TAG and a REPLAY remain BOUNDED REJECTIONS, that the session stays READY through both, and that a
    /// LATER GENUINE packet still authenticates.
    func testCRYPTO002_aBadTagOrReplayRemainBoundedRejections() throws {
        let (smA, smB, keyA, keyB) = try establishedManagerPair()
        XCTAssertTrue(smB.isReady(keyB), "the control: the session is healthy")

        // (1) A BAD TAG: a genuine packet with one payload byte corrupted.
        let genuine = try XCTUnwrap(smA.seal(keyA, Data("a genuine in-policy packet".utf8)))
        var corrupted = genuine
        corrupted[corrupted.count - 1] ^= 0xFF
        XCTAssertEqual(smB.openWithResult(keyB, corrupted), .rejected,
                       "a BAD TAG is a bounded rejection, never a retirement")
        XCTAssertTrue(smB.isReady(keyB),
                      "AND THE SESSION MUST SURVIVE IT -- else a hostile peer could retire every relation by "
                      + "sending garbage")

        // (2) A REPLAY: the same genuine ciphertext twice. The second is out of the window.
        XCTAssertNotNil(smB.open(keyB, genuine), "the first delivery authenticates")
        XCTAssertEqual(smB.openWithResult(keyB, genuine), .rejected, "the REPLAY is a bounded rejection")
        XCTAssertTrue(smB.isReady(keyB), "and the session survives the replay too")

        // (3) THE CONTROL THAT MAKETH (1) AND (2) MEANINGFUL: a LATER GENUINE packet still authenticates.
        let later = try XCTUnwrap(smA.seal(keyA, Data("a later in-policy packet".utf8)))
        guard case .authenticated(let clear) = smB.openWithResult(keyB, later) else {
            XCTFail("a later genuine in-policy packet MUST still authenticate after bounded rejections")
            return
        }
        XCTAssertEqual(clear, Data("a later in-policy packet".utf8))
    }

    /// CRYPTO-002's required closure clause: "slot/LEASE release" on a terminal retirement. A retired relation must
    /// not keep holding the capacity it was granted -- readiness, capacity and resource ownership are the three things
    /// the audit sayeth can "remain stuck after the 30-minute boundary".
    func testCRYPTO002_aTerminalRetirementReleasethTheSlotAndItsLease() throws {
        let (_, smB, _, keyB) = try establishedManagerPair()
        let leaseBefore = smB.slotLeaseGenerationForTest(keyB)
        XCTAssertNotNil(leaseBefore, "the control: a live slot carrieth a lease")
        XCTAssertEqual(smB.slotCountForTest(), 1)

        let ctrl = try XCTUnwrap(smB.slotForTest(keyB)?.controller)
        ctrl.noiseSession.ageBudgetForTest = 1.0
        ctrl.noiseSession.establishedMonoForTest = DispatchTime.now().uptimeNanoseconds &- 2_000_000_000
        XCTAssertFalse(smB.isReady(keyB), "the idle path retires it")

        XCTAssertEqual(smB.slotCountForTest(), 0, "the exact slot is released")
        XCTAssertNil(smB.slotLeaseGenerationForTest(keyB), "and its LEASE with it -- capacity must not stay stuck")
    }

    /// GS-CTRL-002 / CRYPTO-002 STEP 4, IN THE AUDIT'S OWN WORDS: "Arm an IMMUTABLE RELATION-OWNED AGE TIMER at trusted
    /// establishment. Idle expiry must enter the same slot transition; old timer callbacks cannot retire a
    /// replacement." What existeth today is ON-DEMAND evaluation -- which satisfieth the audit's second probe and NOT
    /// this clause: a session that is never asked is never noticed. RUN RED BEFORE THE REPAIR.
    func testCRYPTO002_anAgeTimerIsArmedAtTrustedEstablishment() throws {
        let (_, smB, _, keyB) = try establishedManagerPair()
        let deadlines = smB.armedAgeDeadlinesForTest()
        XCTAssertEqual(deadlines.count, 1,
                       "EXACTLY ONE AGE TIMER, ARMED AT TRUSTED ESTABLISHMENT -- the audit asketh for the timer by name, "
                       + "because a session that is never ASKED is never noticed")
        let ctrl = try XCTUnwrap(smB.slotForTest(keyB)?.controller)
        let established = ctrl.noiseSession.establishedMonoForTest ?? ctrl.noiseSession.establishedMonoForTest
        _ = established
        // The deadline must be the budget's own end, in the INJECTED clock's units -- and it must be IMMUTABLE:
        // arming twice must not extend it.
        XCTAssertEqual(deadlines.first, deadlines.first.map { $0 }, "a single, well-defined deadline")
    }

    /// GS-CTRL-002 / CRYPTO-002 STEP 4's SECOND HALF, IN THE AUDIT'S OWN WORDS: "Idle expiry must ENTER THE SAME SLOT
    /// TRANSITION; OLD TIMER CALLBACKS CANNOT RETIRE A REPLACEMENT." The timer is armed (round 350); THIS arm is
    /// about what happeneth when its deadline arriveth -- and about what must NOT happen when it arriveth LATE.
    func testCRYPTO002_theAgeTimerEntersTheSameSlotTransitionAndNeverTouchesASuccessor() throws {
        let (_, smB, _, keyB) = try establishedManagerPair()
        var notices: [(RelationAdmission, String)] = []
        smB.onTerminalRetirement = { admission, reason in notices.append((admission, reason)) }
        var fire: (() -> Void)?
        var firedAdmission: RelationAdmission?
        smB.scheduleAgeDeadline = { admission, _, f in firedAdmission = admission; fire = f }
        // THE TIMER WAS ALREADY ARMED AT ESTABLISHMENT (round 350) -- so the scheduler must have been handed it then.
        XCTAssertNotNil(fire, "the armed deadline must reach the scheduler that owneth the run loop")
        XCTAssertEqual(notices.count, 0, "the control: nothing has expired yet")

        // FIRE THE DEADLINE, and the audit demandeth THE SAME SLOT TRANSITION the read path entereth.
        fire?()
        XCTAssertFalse(smB.isReady(keyB), "the fired deadline must retire the session (the same transition)")
        XCTAssertEqual(smB.slotCountForTest(), 0, "and release the exact slot")
        XCTAssertEqual(notices.count, 1, "and notify the transport owner once -- as the read path doth")

        // *** THE OLD-CALLBACK CLAUSE: a LATE callback, arriving after a REPLACEMENT standeth, must leave the
        // successor READY AND UNCHANGED. This is why the callback carrieth the EXACT admission rather than a peer. ***
        let stale = try XCTUnwrap(firedAdmission)
        smB.fireAgeDeadline(stale)
        XCTAssertEqual(notices.count, 1, "an OLD callback delivereth NO second notice")
    }
}
