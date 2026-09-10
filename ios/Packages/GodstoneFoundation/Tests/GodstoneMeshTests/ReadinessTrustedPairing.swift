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

    /// Runs the four real manager entries over the given handles until both
    /// registries report the slots ready. The bytes travel the same shape
    /// the transport's own handshake driver will carry them.
    @discardableResult
    static func pairUp(_ pair: Pair, viaBob: UUID, viaAlice: UUID,
                       aliceHint: Data, bobHint: Data) throws {
        guard let hs1 = pair.aliceManager.beginInitiator(viaBob, remoteHint: bobHint) else {
            throw PairingError.initiatorRefused
        }
        guard let hs2 = pair.bobManager.responderProcessHs1(viaAlice, remoteHint: aliceHint, hs1: hs1) else {
            throw PairingError.responderRefused
        }
        guard let hs3 = pair.aliceManager.initiatorProcessHs2(viaBob, hs2: hs2,
                                                              advertisedRemoteHint: bobHint) else {
            throw PairingError.secondRefused
        }
        guard pair.bobManager.responderProcessHs3(viaAlice, hs3: hs3,
                                                 advertisedRemoteHint: aliceHint) else {
            throw PairingError.thirdRefused
        }
        guard pair.aliceManager.isReady(viaBob), pair.bobManager.isReady(viaAlice) else {
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
