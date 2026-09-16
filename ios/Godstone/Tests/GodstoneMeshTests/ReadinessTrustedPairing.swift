import XCTest
import Foundation
import SQLite3
import CryptoKit
@testable import GodstoneCore
@testable import GodstoneMesh

/// T17: the nonshipping test adapter. What the production types must never
/// export lives here: the node composition factory with its fail-closed pair
/// of eyes, and the pairing that brings two session registries up through the
/// real handshake sequence - HS1 from the initiator, HS2 back from the
/// responder, HS3 from the initiator again - until both managers report their
/// slots ready. Suites wire a transport through a trusted pairing and then
/// send and receive over it; the cryptographic ready is reached only the long
/// way round, never through a seam.
enum ReadinessTrustedPairing {

    // MARK: - the relocated node factory (was a public convenience of MeshNode)

    struct FailClosedTrustAuthority: PeerBindingTrustAuthority {
        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            return .storageFailure
        }
    }

    static func makeFailClosedNode(identity: MeshIdentity, store: MessageStore,
                                    deliveryTracker: DeliveryTracker) -> MeshNode {
        let sessions = SessionManager(identity: identity,
                                      trustAuthority: FailClosedTrustAuthority())
        return MeshNode(identity: identity, store: store,
                        deliveryTracker: deliveryTracker, sessions: sessions)
    }

    // MARK: - the pairing

    struct Pair {
        let aliceIdentity: MeshIdentity
        let bobIdentity: MeshIdentity
        let aliceManager: SessionManager
        let bobManager: SessionManager
        /// The handle by which alice names the responder.
        let viaBob: UUID
        /// The handle by which bob names the initiator.
        let viaAlice: UUID
        let urls: [URL]
    }

    enum PairingError: Error {
        case initiatorRefused, responderRefused, secondRefused, thirdRefused, notEstablished, seedExhausted
    }

    enum HintOrder { case orderedAscending, orderedDescending, ascendingOrEqual }
    static func hintOrder(_ x: Data, _ y: Data) -> HintOrder {
        let a = [UInt8](x), b = [UInt8](y)
        for i in 0..<min(a.count, b.count) {
            if a[i] < b[i] { return .orderedAscending }
            if a[i] > b[i] { return .orderedDescending }
        }
        if a.count < b.count { return .orderedAscending }
        if a.count > b.count { return .orderedDescending }
        return .ascendingOrEqual
    }

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { return storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    static func makeIdentity(seedByte: UInt8, staticPrivByte: UInt8) throws -> MeshIdentity {
        let kc = InMemoryKeychain()
        let edSeed = Data(repeating: seedByte, count: 32)
        let xPriv = Data(repeating: staticPrivByte, count: 32)
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: edSeed, x25519PrivateKey: xPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        return try MeshIdentity.loadFromKeychain(keychain: kc)
    }

    private static func tempDbUrl(_ name: String) -> URL {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("t17_pair_" + name + "_" + UUID().uuidString + ".db")
    }

    /// Two registries with empty slots: identities, repositories and
    /// authorities in place, no pairing run yet. Suites that drive the
    /// handshake through the transport's own entries start here.
    static func barePair(seedA: UInt8 = 0x11, privA: UInt8 = 0x22,
                         seedB: UInt8 = 0x33, privB: UInt8 = 0x44) throws -> Pair {
        // The election elects the lexicographically smaller node hint as the
        // initiator, so the pair must be seeded with the digests pointing the
        // right way: alice below bob. Search forward from the requested seed.
        var aliceIdentity = try makeIdentity(seedByte: seedA, staticPrivByte: privA)
        var bobIdentity = try makeIdentity(seedByte: seedB, staticPrivByte: privB)
        var candidate = seedA
        while ReadinessTrustedPairing.hintOrder(aliceIdentity.nodeHint, bobIdentity.nodeHint) != .orderedAscending {
            candidate += 1
            if candidate == 0 { throw PairingError.seedExhausted }
            aliceIdentity = try makeIdentity(seedByte: candidate, staticPrivByte: privA)
        }
        if ReadinessTrustedPairing.hintOrder(aliceIdentity.nodeHint, bobIdentity.nodeHint) != .orderedAscending {
            throw PairingError.seedExhausted
        }
        let urlA = tempDbUrl("a")
        let urlB = tempDbUrl("b")
        let storeA = try SqlitePeerIdentityStore(url: urlA)
        let storeB = try SqlitePeerIdentityStore(url: urlB)
        let repoA = PeerIdentityRepository(store: storeA)
        let repoB = PeerIdentityRepository(store: storeB)
        let aliceManager = SessionManager(identity: aliceIdentity,
                                          trustAuthority: RepositoryPeerBindingTrustAuthority(repository: repoA))
        let bobManager = SessionManager(identity: bobIdentity,
                                        trustAuthority: RepositoryPeerBindingTrustAuthority(repository: repoB))
        return Pair(aliceIdentity: aliceIdentity, bobIdentity: bobIdentity,
                    aliceManager: aliceManager, bobManager: bobManager,
                    viaBob: UUID(), viaAlice: UUID(), urls: [urlA, urlB])
    }

    /// CRYPTO-001: THE ADMISSION A FRESHLY STARTED TRANSPORT MINTETH for the FIRST relation
    /// of a handle. The link owner's generation counter for a handle beginneth at zero and is
    /// incremented when the relation is admitted, and the transport's radio epoch beginneth at
    /// zero and is incremented when it starteth -- so the first relation of a handle standeth
    /// at generation 1 in epoch 1.
    ///
    /// A court which pre-paireth a registry before wiring a transport must present THIS
    /// admission, because the transport presenteth it: the crypto slot and the transport's
    /// registration must be ONE identity rather than two which happen to look alike. The court
    /// is not asked to believe the numbers: `assertMintedAdmission` MEASURES them against the
    /// transport's own registration, and a divergence fails loudly instead of sealing nothing.
    static func firstRelationAdmission(_ handle: UUID, direction: BleDirection) -> RelationAdmission {
        RelationAdmission(direction: direction, peerId: handle, generation: 1, transportEpoch: 1)
    }

    /// CRYPTO-001: the SUCCESSOR of an incarnation already measured -- the next generation in
    /// the next radio epoch. A court which must handshake a relation anew (because the radio
    /// underneath it was replaced) deriveth the counterpart's fresh incarnation from the one
    /// that standeth, so no number is written before the run.
    static func successor(of admission: RelationAdmission) -> RelationAdmission {
        RelationAdmission(direction: admission.direction, peerId: admission.peerId,
                          generation: admission.relation.generation + 1,
                          transportEpoch: admission.transportEpoch + 1)
    }

    /// The measurement which replaceth the assumption: the admission the TRANSPORT minted for
    /// that relation must be the very admission the registry holdeth for it.
    static func assertMintedAdmission(_ transport: BleTransport, manager: SessionManager,
                                      handle: UUID, direction: BleDirection,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let minted = transport.admissionForTest(handle, direction: direction)
        XCTAssertNotNil(minted, "the transport minted no admission for this relation",
                        file: file, line: line)
        XCTAssertTrue(minted.map { manager.slotAdmissionForTest($0) != nil } ?? false,
                      "the registry holdeth no incarnation for the admission this transport minted"
                        + " -- the court's pre-pairing and the transport disagree",
                      file: file, line: line)
    }

    /// Runs the four real manager entries over the given handles until both
    /// registries report the slots ready. The bytes travel the same shape
    /// the transport's own handshake driver will carry them.
    ///
    /// CRYPTO-001: the entries are addressed by the relation's ADMISSION -- by default the one a
    /// freshly started transport minteth for the first relation of that handle.
    @discardableResult
    static func pairUp(_ pair: Pair, viaBob: UUID, viaAlice: UUID,
                       aliceHint: Data, bobHint: Data,
                       aliceAdmission: RelationAdmission? = nil,
                       bobAdmission: RelationAdmission? = nil) throws {
        let aliceRelation = aliceAdmission ?? firstRelationAdmission(viaBob, direction: .outboundCentral)
        let bobRelation = bobAdmission ?? firstRelationAdmission(viaAlice, direction: .inboundPeripheral)
        guard let hs1 = pair.aliceManager.beginInitiator(aliceRelation, remoteHint: bobHint) else {
            throw PairingError.initiatorRefused
        }
        guard let hs2 = pair.bobManager.responderProcessHs1(bobRelation, remoteHint: aliceHint, hs1: hs1) else {
            throw PairingError.responderRefused
        }
        guard let hs3 = pair.aliceManager.initiatorProcessHs2(aliceRelation, hs2: hs2,
                                                              advertisedRemoteHint: bobHint) else {
            throw PairingError.secondRefused
        }
        guard pair.bobManager.responderProcessHs3(bobRelation, hs3: hs3,
                                                 advertisedRemoteHint: aliceHint) else {
            throw PairingError.thirdRefused
        }
        guard pair.aliceManager.isReady(aliceRelation), pair.bobManager.isReady(bobRelation) else {
            throw PairingError.notEstablished
        }
    }

    /// The convenience pairing: bare pair, then the entries over the pair's
    /// own handles with the hints the bindings advertise.
    @discardableResult
    static func establish(seedA: UInt8 = 0x11, privA: UInt8 = 0x22,
                          seedB: UInt8 = 0x33, privB: UInt8 = 0x44) throws -> Pair {
        let pair = try barePair(seedA: seedA, privA: privA, seedB: seedB, privB: privB)
        try pairUp(pair, viaBob: pair.viaBob, viaAlice: pair.viaAlice,
                   aliceHint: pair.aliceIdentity.nodeHint, bobHint: pair.bobIdentity.nodeHint)
        return pair
    }

    static func tearDown(_ pair: Pair) {
        for url in pair.urls {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

extension MeshNode {
    /// The convenience relocated from the production type: suites that
    /// neither verify a peer nor bind a trust compose a fail-closed node
    /// through this nonshipping entrance only.
    convenience init(identity: MeshIdentity, store: MessageStore,
                     deliveryTracker: DeliveryTracker) {
        let sessions = SessionManager(identity: identity,
                                       trustAuthority: ReadinessTrustedPairing.FailClosedTrustAuthority())
        self.init(identity: identity, store: store,
                  deliveryTracker: deliveryTracker, sessions: sessions)
    }
}
