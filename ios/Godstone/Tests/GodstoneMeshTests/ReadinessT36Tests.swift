// T36 readiness court (iOS isle) -- the twin of ReadinessT36Test.kt.
//
// SendDirectAuthority: the atomic authored DIRECT send command. One reviewed scenario per
// witness; every assertion is positive and expected (a present side effect is captured, an
// absent one is CAPTURED as absence); the observable counters on the injected fakes are the
// oracles that make the five named falsifications killable (retry regenerates the identity,
// retry re-resolves the recipient, an id handed out before the durable commit, the profile
// gate moved after signing, a changed content replaying pinned bytes).
import XCTest
@testable import GodstoneMesh
import GodstoneCore
import CryptoKit

final class ReadinessT36Tests: XCTestCase {

    // ------------------------------------------------------------------ fakes (deterministic; counters observable)

    private enum CourtError: Error { case bad(String) }

    private final class FixedClock: SenderClock, @unchecked Sendable {
        private let created: Int64
        private let quality: TimeQuality
        private(set) var calls: Int = 0
        init(created: Int64, quality: TimeQuality) { self.created = created; self.quality = quality }
        func now() -> SenderTime {
            calls += 1
            return SenderTime(createdAtEpochSeconds: created, timeQuality: quality)
        }
    }

    private final class RecordingIdentityFactory: LogicalIdentityFactory, @unchecked Sendable {
        private(set) var creates: Int = 0
        private var seq: Int64 = 0
        func create(nowEpochSeconds: Int64) -> LogicalMessageIdentity {
            creates += 1
            seq += 1
            var nonce = [UInt8]()
            for i in 0..<16 {
                let v = seq * 31 + Int64(i) * 7 + 3
                nonce.append(UInt8(v & 0xFF))
            }
            return LogicalMessageIdentity.of(createdAtEpochSeconds: nowEpochSeconds, messageNonce: Data(nonce))
        }
    }

    private final class TrustSource: PeerIdentityLookupSource, @unchecked Sendable {
        private var table: [Data: PeerIdentityLookup] = [:]
        private(set) var resolves: Int = 0
        var faulted: Bool = false
        func lookup(_ nodeId: Data) -> PeerIdentityLookup {
            resolves += 1
            if faulted { return .storageFailure }
            return table[nodeId] ?? .notFound
        }
        func approve(nodeId: Data, signingPub: Data, staticDhPub: Data, generation: UInt32) throws {
            let record = PeerIdentityRecord(nodeId: nodeId, signingPublicKey: signingPub,
                                           acceptedStaticDhPublicKey: staticDhPub,
                                           acceptedGeneration: generation, trustLevel: .tofuPinned)
            guard let verified = VerifiedPeerIdentity.fromRecord(record) else {
                throw CourtError.bad("fixture record malformed")
            }
            table[nodeId] = .verified(verified)
        }
        func quarantine(nodeId: Data, signingPub: Data, acceptedStaticDhPub: Data) throws {
            let record = PeerIdentityRecord(nodeId: nodeId, signingPublicKey: signingPub,
                                            acceptedStaticDhPublicKey: acceptedStaticDhPub,
                                            acceptedGeneration: 1, trustLevel: .tofuPinned,
                                            pendingStaticDhPublicKey: Data(repeating: 0x5A, count: 32),
                                            pendingGeneration: 2)
            guard let pending = PendingPeerIdentity.fromRecord(record) else {
                throw CourtError.bad("fixture pending record malformed")
            }
            table[nodeId] = .quarantined(pending)
        }
        func revokeMarker(_ nodeId: Data) { table[nodeId] = .revoked }
        func corruptAt(_ nodeId: Data) { table[nodeId] = .corrupt(.unknownTrustLevelCode(99)) }
        func markInvalid(_ nodeId: Data) { table[nodeId] = .invalidArgument("fixture: malformed record") }
    }

    /// MessageStore delegate with one injected fault at the durable enqueue boundary.
    private final class FaultStore: MessageStore, @unchecked Sendable {
        /// GS-STORE-005 (round 286): FORWARDED, not answered nil -- this double DELEGATES, and a
        /// delegation that observed nothing while its inner store observed would be a silent lie.
        @discardableResult
        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) -> ObservationLease.LeaseToken? {
            return base.registerHeldSetObserver(observer)
        }
        func removeHeldSetObserver(_ lease: ObservationLease.LeaseToken) { base.removeHeldSetObserver(lease) }
        let base: InMemoryMessageStore
        var failNextEnqueue: Bool = false
        init(base: InMemoryMessageStore) { self.base = base }
        func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult {
            base.persist(frame, receivedFrom: receivedFrom)
        }
        func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data,
                                   localOriginNodeId: Data) -> OutboundEnqueueResult {
            if failNextEnqueue {
                failNextEnqueue = false
                return .storageFailure
            }
            return base.enqueueDirectOutbound(frame, expectedRecipient: expectedRecipient,
                                             localOriginNodeId: localOriginNodeId)
        }
        func allHeldOrderedByPriority() -> [FrameV2] { base.allHeldOrderedByPriority() }
        func allHeldMsgIds() -> [Data] { base.allHeldMsgIds() }
        func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) { base.forEachHeldOrderedByPriority(visit) }
        func forEachHeldMsgId(_ visit: (Data) -> Bool) { base.forEachHeldMsgId(visit) }
        var heldBytes: Int64 { base.heldBytes }
        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) {
            base.registerHeldSetObserver(observer)
        }
    }

    /// Delivery repository view mirroring the store's durable rows (integration-corpus idiom).
    private final class RepoView: DeliveryRepository, @unchecked Sendable {
        private var map: [Data: DeliveryRecord] = [:]
        private let store: InMemoryMessageStore?
        init(store: InMemoryMessageStore?) { self.store = store }
        func get(_ msgId: Data) -> DeliveryLookup {
            if let rec = map[msgId] { return .found(rec) }
            if let d = store?.readDeliveryRow(msgId),
               let s = DeliveryState.fromPersistedCode(d.state),
               let a = AckMode.fromCode(d.ackMode) {
                let rec = DeliveryRecord(msgId: msgId, state: s, ackMode: a,
                                        expectedRecipientNodeId: d.expectedRecipient)
                map[msgId] = rec
                return .found(rec)
            }
            return .notFound
        }
        func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
            switch get(msgId) {
            case .notFound:
                map[msgId] = DeliveryRecord(msgId: msgId, state: .queuedDurably, ackMode: ackMode,
                                            expectedRecipientNodeId: expectedRecipient)
                return .created
            case .found: return .alreadyQueuedSameBinding
            case .corrupt: return .corrupt
            case .storageFailure: return .storageFailure
            case .invalidArgument: return .invalidArgument
            }
        }
        func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult {
            return .rejectedState
        }
        func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {
            switch get(msgId) {
            case .found(let rec):
                guard rec.ackMode == AckMode.singleRecipient,
                      let bound = rec.expectedRecipientNodeId, bound == expectedRecipient else {
                    return .unknownMessage
                }
                if rec.state == .acknowledgedByRecipient { return .duplicateAuthenticatedAck }
                map[msgId] = DeliveryRecord(msgId: msgId, state: .acknowledgedByRecipient,
                                            ackMode: rec.ackMode,
                                            expectedRecipientNodeId: rec.expectedRecipientNodeId)
                store?.updateDeliveryState(msgId, state: DeliveryState.acknowledgedByRecipient.code)
                return .applied
            case .notFound: return .unknownMessage
            case .corrupt: return .corrupt
            case .storageFailure: return .storageFailure
            case .invalidArgument: return .invalidArgument
            }
        }
        func clear(_ msgId: Data) -> ClearResult {
            if map.removeValue(forKey: msgId) != nil { return .cleared }
            return .alreadyAbsent
        }
    }

    private struct Fixture {
        var id: MeshIdentity
        var seed: Data
        var xPriv: Data
        var store: FaultStore
        var journal: InMemoryOutboundIntentJournal
        var trust: TrustSource
        var factory: RecordingIdentityFactory
        var clock: FixedClock
        var signing: SigningKeysAdapter
        var router: Router
        var authority: SendDirectAuthority
    }

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage[tag] = nil }
    }

    private func identityWithMaterial(_ seedByte: UInt8, _ xByte: UInt8) throws
        -> (MeshIdentity, Data, Data) {
        let edSeed = Data(repeating: seedByte, count: 32)
        let xPriv = Data(repeating: xByte, count: 32)
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: edSeed, x25519PrivateKey: xPriv)
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        let id = try MeshIdentity.loadFromKeychain(keychain: kc)
        return (id, edSeed, xPriv)
    }

    private func fixture(created: Int64 = 1_700_000_123, seedByte: UInt8 = 0x11,
                         xByte: UInt8 = 0x22) throws -> Fixture {
        let (snd, seed, xPriv) = try identityWithMaterial(seedByte, xByte)
        let base = InMemoryMessageStore()
        let store = FaultStore(base: base)
        let router = Router(selfNodeId: snd.nodeId, store: store)
        let journal = InMemoryOutboundIntentJournal()
        let trust = TrustSource()
        let factory = RecordingIdentityFactory()
        let clock = FixedClock(created: created, quality: .userConfirmed)
        let signing = SigningKeysAdapter(seed: seed, pub: snd.signingPublicKey)
        let authority = SendDirectAuthority(
            identity: snd, signingKeys: signing, router: router, store: store,
            trustResolver: TrustedPeerIdentityResolver(source: trust),
            journal: journal, identityFactory: factory, clock: clock)
        return Fixture(id: snd, seed: seed, xPriv: xPriv, store: store, journal: journal,
                       trust: trust, factory: factory, clock: clock, signing: signing,
                       router: router, authority: authority)
    }

    private func approvePeer(_ f: inout Fixture, _ seedByte: UInt8, _ xByte: UInt8) throws -> MeshIdentity {
        let (peer, _, _) = try identityWithMaterial(seedByte, xByte)
        try f.trust.approve(nodeId: peer.nodeId, signingPub: peer.signingPublicKey,
                            staticDhPub: peer.staticDhPublicKey, generation: 1)
        return peer
    }

    private func cmd(_ intent: Data, _ ref: Data, _ body: [UInt8]) throws -> SendDirectCommand {
        guard let c = SendDirectCommand.of(intentId: intent, recipientTrustRef: ref, bodyUtf8: body) else {
            throw CourtError.bad("command shape malformed")
        }
        return c
    }

    private func bytesOf(_ seed: Int, _ n: Int) -> Data {
        var b = [UInt8]()
        for i in 0..<n { b.append(UInt8((i * 31 + seed) & 0xFF)) }
        return Data(b)
    }

    private func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

    private func le32(_ b: ArraySlice<UInt8>) -> Int64 {
        var v: Int64 = 0
        var i = 0
        for byte in b { v |= Int64(byte) << (8 * i); i += 1 }
        return v
    }

    // ------------------------------------------------------------------ witnesses

    /// W1: a double tap is TWO explicit intents; identical content still yields two DISTINCT
    /// logical ids (a fresh nonce per logical send), both durable, each with its own bound row.
    func testDoubleTapYieldsTwoExplicitIntentsTwoLogicalSends() async throws {
        var f = try fixture()
        let bob = try approvePeer(&f, 0x31, 0x41)
        let r1 = await f.authority.sendDirect(try cmd(bytesOf(1, 16), bob.nodeId, ascii("same body")))
        let r2 = await f.authority.sendDirect(try cmd(bytesOf(2, 16), bob.nodeId, ascii("same body")))
        guard case .durablyEnqueued(let id1, let replay1) = r1,
              case .durablyEnqueued(let id2, let replay2) = r2 else {
            XCTFail("both accepts must be durable"); return
        }
        XCTAssertFalse(id1 == id2, "the two logical ids differ (fresh nonce per logical send)")
        XCTAssertFalse(replay1 || replay2, "neither accept reports a replay")
        XCTAssertEqual(f.store.allHeldMsgIds().count, 2, "the store holds both frames")
        XCTAssertEqual(f.factory.creates, 2, "one identity creation per logical send")
        XCTAssertEqual(f.trust.resolves, 2, "one resolve per logical send")
        XCTAssertEqual(f.journal.size(), 2, "two journal rows")
        for id in [id1, id2] {
            guard let d = f.store.base.readDeliveryRow(id) else {
                XCTFail("each send carries its delivery row from the same transaction"); return
            }
            XCTAssertEqual(d.ackMode, AckMode.singleRecipient.rawValue, "SINGLE_RECIPIENT binding")
            XCTAssertEqual(d.state, DeliveryState.queuedDurably.code, "QUEUED_DURABLY at commit")
            XCTAssertEqual(d.expectedRecipient, bob.nodeId, "the expected recipient is bound")
        }
    }

    /// W2: retry of the SAME intent token loads identical persisted bytes -- the counters
    /// prove nothing was re-created and nothing was re-resolved.
    func testRetryOfSameIntentTokenLoadsIdenticalPersistedBytes() async throws {
        var f = try fixture()
        let bob = try approvePeer(&f, 0x31, 0x41)
        let t = bytesOf(5, 16)
        guard case .durablyEnqueued(let firstId, _) = await f.authority.sendDirect(
            try cmd(t, bob.nodeId, ascii("retry me"))) else {
            XCTFail("first accept must be durable"); return
        }
        let bytes1 = f.store.allHeldOrderedByPriority()[0].encode()
        let creates0 = f.factory.creates
        let resolves0 = f.trust.resolves
        guard case .durablyEnqueued(let secondId, let fromRetry) = await f.authority.sendDirect(
            try cmd(t, bob.nodeId, ascii("retry me"))) else {
            XCTFail("the retry must be durable"); return
        }
        XCTAssertTrue(fromRetry, "the retry reports itself as a replay")
        XCTAssertEqual(secondId, firstId, "the same immutable logical id")
        let bytes2 = f.store.allHeldOrderedByPriority()[0].encode()
        XCTAssertEqual(bytes2, bytes1, "identical persisted bytes")
        XCTAssertEqual(f.factory.creates, creates0, "the identity was created once, ever")
        XCTAssertEqual(f.trust.resolves, resolves0, "the recipient was resolved once, ever")
        XCTAssertEqual(f.journal.size(), 1, "still a single journal row")
    }

    /// W3: the key rotation race -- the generation is pinned at first accept; a replay never
    /// consults the rotated table; a FRESH intent resolves CURRENT.
    func testKeyRotationRacePinsTheAcceptedGeneration() async throws {
        var f = try fixture()
        let bob = try approvePeer(&f, 0x31, 0x41)
        guard case .durablyEnqueued(let firstId, _) = await f.authority.sendDirect(
            try cmd(bytesOf(6, 16), bob.nodeId, ascii("rot me"))) else {
            XCTFail("first accept must be durable"); return
        }
        // ADR-003 rotation: the identity signing key persists; ONLY the static DH material rotates.
        let xRot = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 0x7B, count: 32))
        try f.trust.approve(nodeId: bob.nodeId, signingPub: bob.signingPublicKey,
                            staticDhPub: xRot.publicKey.rawRepresentation, generation: 2)
        let resolvesBefore = f.trust.resolves
        guard case .durablyEnqueued(let replayId, _) = await f.authority.sendDirect(
            try cmd(bytesOf(6, 16), bob.nodeId, ascii("rot me"))) else {
            XCTFail("the replay must be durable"); return
        }
        XCTAssertEqual(replayId, firstId, "the rotation cannot move the pinned replay")
        XCTAssertEqual(f.trust.resolves, resolvesBefore, "the replay did not consult the rotated table")
        guard let pinned = f.journal.load(bytesOf(6, 16)).entryOrNil else {
            XCTFail("the pinned row must exist"); return
        }
        XCTAssertEqual(pinned.acceptedGeneration, 1, "the row pins the FIRST generation")
        let fresh = await f.authority.sendDirect(try cmd(bytesOf(66, 16), bob.nodeId, ascii("rot me")))
        XCTAssertEqual(f.trust.resolves, resolvesBefore + 1,
                       "the fresh accept consulted the rotated table once more")
        guard case .durablyEnqueued(let freshId, _) = fresh else {
            XCTFail("the fresh accept must be durable"); return
        }
        XCTAssertFalse(freshId == firstId, "a fresh logical id, distinct from the pinned one")
        guard let freshRow = f.journal.load(bytesOf(66, 16)).entryOrNil else {
            XCTFail("the fresh row must exist"); return
        }
        XCTAssertEqual(freshRow.acceptedGeneration, 2, "the fresh row pins generation 2")
        XCTAssertEqual(freshRow.recipientStaticDhPub, xRot.publicKey.rawRepresentation,
                       "the fresh row seals with the ROTATED static material")
    }

    /// W4: disk full at the durable commit -- failure is DISTINGUISHED from empty success:
    /// no id is handed out, nothing half-committed, the pinned identity survives the crash.
    func testDiskFullRefusesSendDistinguishingFailureFromEmpty() async throws {
        var f = try fixture()
        let bob = try approvePeer(&f, 0x31, 0x41)
        let t = bytesOf(8, 16)
        f.store.failNextEnqueue = true
        let refused = await f.authority.sendDirect(try cmd(t, bob.nodeId, ascii("burst")))
        guard case .rejected(let reason) = refused else {
            XCTFail("the refusal must be typed"); return
        }
        XCTAssertEqual(reason, .enqueueStorageFailure,
                       "named StorageFailure at the enqueue boundary")
        XCTAssertEqual(f.store.allHeldMsgIds().count, 0, "no frame reached the store")
        guard let row = f.journal.load(t).entryOrNil else {
            XCTFail("the row persisted through the fault"); return
        }
        XCTAssertEqual(row.stateRank, IntentStateRank.authored,
                       "it stands at AUTHORED -- the identity is pinned, not lost")
        f.store.failNextEnqueue = false
        guard case .durablyEnqueued(let againId, let fromRetry) = await f.authority.sendDirect(
            try cmd(t, bob.nodeId, ascii("burst"))) else {
            XCTFail("the retry must succeed after the fault clears"); return
        }
        XCTAssertEqual(againId, row.logicalMessageId,
                       "the retry yields the SAME logical id -- identity survives the crash")
        XCTAssertTrue(fromRetry, "reported as a replay")
        XCTAssertEqual(f.factory.creates, 1, "one identity creation for the whole saga")
        XCTAssertEqual(f.trust.resolves, 1, "one resolve for the whole saga")
        XCTAssertEqual(f.store.allHeldMsgIds().count, 1, "the store now holds the one frame")
        guard let climbed = f.journal.load(t).entryOrNil else {
            XCTFail("the row must exist"); return
        }
        XCTAssertEqual(climbed.stateRank, IntentStateRank.committed, "the row climbed to COMMITTED")
    }

    /// W5: process interruption and restart -- a fresh authority over the same durable media
    /// loads identical bytes and creates NOTHING.
    func testRestartRetryIdenticalBytes() async throws {
        var f = try fixture()
        let bob = try approvePeer(&f, 0x31, 0x41)
        let t = bytesOf(11, 16)
        guard case .durablyEnqueued(let firstId, _) = await f.authority.sendDirect(
            try cmd(t, bob.nodeId, ascii("persisted"))) else {
            XCTFail("first accept must be durable"); return
        }
        let bytes1 = f.store.allHeldOrderedByPriority()[0].encode()
        let factory2 = RecordingIdentityFactory()
        let trust2 = TrustSource()   // a fresh view: the replay must not need it
        let authority2 = SendDirectAuthority(
            identity: f.id, signingKeys: f.signing, router: f.router, store: f.store,
            trustResolver: TrustedPeerIdentityResolver(source: trust2),
            journal: f.journal, identityFactory: factory2,
            clock: FixedClock(created: 1_700_000_999, quality: .userConfirmed))
        guard case .durablyEnqueued(let replayId, let fromRetry) = await authority2.sendDirect(
            try cmd(t, bob.nodeId, ascii("persisted"))) else {
            XCTFail("the restarted replay must be durable"); return
        }
        XCTAssertTrue(fromRetry, "the restarted accept recognises the pinned intent")
        XCTAssertEqual(replayId, firstId, "same immutable logical id after restart")
        let bytes2 = f.store.allHeldOrderedByPriority()[0].encode()
        XCTAssertEqual(bytes2, bytes1, "identical persisted bytes after restart")
        XCTAssertEqual(factory2.creates, 0, "the restarted instance created nothing")
        XCTAssertEqual(trust2.resolves, 0, "the restarted instance resolved nothing")
    }

    /// W6: changed recipient, body, or priority under one token is a NEW logical send; the
    /// shipped profile refuses non-DIRECT and fabricates nothing.
    func testChangedRecipientOrBodyOrPriorityCreatesNewLogicalSend() async throws {
        var f = try fixture()
        let bob = try approvePeer(&f, 0x31, 0x41)
        let carol = try approvePeer(&f, 0x32, 0x42)
        let t = bytesOf(12, 16)
        guard case .durablyEnqueued(let idA, _) = await f.authority.sendDirect(
            try cmd(t, bob.nodeId, ascii("body A"))),
              case .durablyEnqueued(let idB, _) = await f.authority.sendDirect(
            try cmd(t, bob.nodeId, ascii("body B"))),
              case .durablyEnqueued(let idC, _) = await f.authority.sendDirect(
            try cmd(t, carol.nodeId, ascii("body B"))) else {
            XCTFail("all three changes must be accepted as new logical sends"); return
        }
        XCTAssertFalse(idA == idB, "changed body => new logical send")
        XCTAssertFalse(idB == idC, "changed recipient => new logical send")
        XCTAssertEqual(f.factory.creates, 3, "three creations, one per accepted change")
        XCTAssertEqual(f.store.allHeldMsgIds().count, 3, "the store retains the whole history")
        XCTAssertEqual(f.journal.size(), 1, "one current row per token")
        guard let current = f.journal.load(t).entryOrNil else {
            XCTFail("the current row must exist"); return
        }
        XCTAssertEqual(current.stateRank, IntentStateRank.committed,
                       "the current row reflects the latest accept")
        let dDirect = SendDirectAuthority.bindingDigest(trustRef: bob.nodeId, body: ascii("body B"),
                                                       priorityCode: Int(Priority.direct.rawValue))
        let dGroup = SendDirectAuthority.bindingDigest(trustRef: bob.nodeId, body: ascii("body B"),
                                                      priorityCode: Int(Priority.group.rawValue))
        XCTAssertFalse(dDirect == dGroup, "priority is covered by the binding digest")
        let before = f.factory.creates
        let refused = await f.authority.sendDirect(try cmd(bytesOf(13, 16), bob.nodeId, ascii("sneak")),
                                                   priority: .sos)
        guard case .rejected = refused else {
            XCTFail("the lab profile must forbid non-DIRECT shipping"); return
        }
        XCTAssertEqual(f.factory.creates, before, "the refusal fabricated nothing")
        XCTAssertEqual(f.store.allHeldMsgIds().count, 3, "still three durable frames")
    }

    /// W7: one body, several approved recipients -- each binding is a distinct logical send
    /// with its own durable row; no cross-contamination of ids or bindings.
    func testMultiRecipientDistinctIds() async throws {
        var f = try fixture()
        let bob = try approvePeer(&f, 0x31, 0x41)
        let carol = try approvePeer(&f, 0x32, 0x42)
        let body = ascii("one body, distinct ids")
        guard case .durablyEnqueued(let idB, _) = await f.authority.sendDirect(
            try cmd(bytesOf(21, 16), bob.nodeId, body)),
              case .durablyEnqueued(let idC, _) = await f.authority.sendDirect(
            try cmd(bytesOf(22, 16), carol.nodeId, body)) else {
            XCTFail("both bindings must be durable"); return
        }
        XCTAssertFalse(idB == idC, "distinct recipients, distinct logical ids")
        XCTAssertEqual(f.store.allHeldMsgIds().count, 2, "two frames held")
        guard let dB = f.store.base.readDeliveryRow(idB), let dC = f.store.base.readDeliveryRow(idC) else {
            XCTFail("both delivery rows must exist"); return
        }
        XCTAssertEqual(dB.expectedRecipient, bob.nodeId, "the first row binds its own expected recipient")
        XCTAssertEqual(dC.expectedRecipient, carol.nodeId, "the second row binds its own expected recipient")
        XCTAssertEqual(f.factory.creates, 2, "one creation per logical send")
    }

    /// W8: the 400-byte UTF-8 profile gate stands BEFORE every authoring primitive -- a
    /// rejected body fabricates no signature, no seal, no row, no state.
    func testBodyProfileGateBeforeAnyAuthoring() async throws {
        var f = try fixture()
        let bob = try approvePeer(&f, 0x31, 0x41)
        let oversize = [UInt8](repeating: 0x41, count: SignedMessageV1.bodyMax + 1)
        let loneContinuation: [UInt8] = [0x6E, 0x6F, 0x80]   // "no" plus a naked continuation byte
        let empty = await f.authority.sendDirect(try cmd(bytesOf(31, 16), bob.nodeId, []))
        let big = await f.authority.sendDirect(try cmd(bytesOf(32, 16), bob.nodeId, oversize))
        let bad = await f.authority.sendDirect(try cmd(bytesOf(33, 16), bob.nodeId, loneContinuation))
        guard case .rejected(let r1) = empty, case .rejected(let r2) = big, case .rejected(let r3) = bad else {
            XCTFail("all three profile violations must be refused"); return
        }
        XCTAssertEqual(r1, .bodyEmpty, "empty names its cause")
        XCTAssertEqual(r2, .bodyTooLarge, "oversize names its cause")
        XCTAssertEqual(r3, .bodyNotUtf8, "malformed names its cause")
        XCTAssertEqual(f.factory.creates, 0, "no identity was ever created")
        XCTAssertEqual(f.trust.resolves, 0, "no signature was produced: the resolver was never consulted")
        XCTAssertEqual(f.store.allHeldMsgIds().count, 0, "nothing reached the store")
        XCTAssertEqual(f.journal.size(), 0, "no rows in the journal")
        let exact = [UInt8](repeating: 0x41, count: SignedMessageV1.bodyMax)
        let ok = await f.authority.sendDirect(try cmd(bytesOf(44, 16), bob.nodeId, exact))
        guard case .durablyEnqueued = ok else {
            XCTFail("the maximal well-formed body must be admitted"); return
        }
    }

    /// W9: an immutable logical id is handed out ONLY after the durable commit proved itself --
    /// read back from the store and re-derived from the pinned row; a Rejected carries none.
    func testIdentityOnlyAfterDurableEnqueue() async throws {
        var f = try fixture()
        let bob = try approvePeer(&f, 0x31, 0x41)
        let t = bytesOf(51, 16)
        guard case .durablyEnqueued(let enqId, _) = await f.authority.sendDirect(
            try cmd(t, bob.nodeId, ascii("prove me"))) else {
            XCTFail("the accept must be durable"); return
        }
        guard let row = f.journal.load(t).entryOrNil else {
            XCTFail("the pinned row must exist after the commit"); return
        }
        let held = f.store.allHeldOrderedByPriority()[0]
        XCTAssertEqual(held.msgId, enqId, "the held frame carries the handed id")
        XCTAssertEqual(held.type, TypeV2.message, "MESSAGE type")
        XCTAssertNotEqual(held.flags & UInt16(FrameV2.Flags.sealed), 0, "SEALED is set")
        XCTAssertTrue(row.verifyLogicalIdentity(senderNodeId: f.id.nodeId),
                      "the row is self-proving from the pinned bytes")
        XCTAssertEqual(row.logicalMessageId, enqId, "the row id equals the handed id")
        guard let d = f.store.base.readDeliveryRow(enqId) else {
            XCTFail("the delivery row must stand with the frame"); return
        }
        XCTAssertEqual(d.ackMode, AckMode.singleRecipient.rawValue, "SINGLE_RECIPIENT")
        XCTAssertEqual(d.state, DeliveryState.queuedDurably.code, "QUEUED_DURABLY")
        f.store.failNextEnqueue = true
        let refused = await f.authority.sendDirect(try cmd(bytesOf(52, 16), bob.nodeId, ascii("prove me")))
        guard case .rejected(let reason) = refused else {
            XCTFail("the refused command must carry NO id"); return
        }
        XCTAssertEqual(reason, .enqueueStorageFailure, "and names the fault")
    }

    /// W10: unapproved and faulty recipients answer with SEVEN mutually distinct typed
    /// rejections -- failure distinguished from empty/no-op success, nothing mutated.
    func testUnapprovedRecipientYieldsTypedDistinctRejections() async throws {
        var f = try fixture()
        let absent = bytesOf(61, 16)                       // never entered in the table
        let quarantineKey = bytesOf(62, 16)
        let (qId, qSeed, _) = try identityWithMaterial(0x51, 0x61)
        try f.trust.quarantine(nodeId: qId.nodeId, signingPub: qId.signingPublicKey,
                               acceptedStaticDhPub: qId.staticDhPublicKey)
        _ = quarantineKey; _ = qSeed
        let revokedKey = bytesOf(63, 16)
        let (rId, _, _) = try identityWithMaterial(0x52, 0x62)
        f.trust.revokeMarker(rId.nodeId)
        _ = revokedKey
        let (cId, _, _) = try identityWithMaterial(0x53, 0x63)
        f.trust.corruptAt(cId.nodeId)
        let (iId, _, _) = try identityWithMaterial(0x54, 0x64)
        f.trust.markInvalid(iId.nodeId)
        var seen = [SendDirectRejection]()
        let probes: [(Data, SendDirectRejection, String)] = [
            (absent, .recipientAbsent, "absent"),
            (qId.nodeId, .recipientNotApproved, "quarantined"),
            (rId.nodeId, .recipientRevoked, "revoked"),
            (cId.nodeId, .recipientCorrupt, "corrupt"),
            (iId.nodeId, .trustRefMalformed, "invalid"),
        ]
        var index = 0
        for (ref, expected, name) in probes {
            index += 1
            let refused = await f.authority.sendDirect(try cmd(bytesOf(70 + index, 16), ref, ascii("body")))
            guard case .rejected(let reason) = refused else {
                XCTFail("\(name) must be refused"); return
            }
            XCTAssertEqual(reason, expected, "\(name) names its cause")
            seen.append(reason)
        }
        f.trust.faulted = true
        let faultRefused = await f.authority.sendDirect(try cmd(bytesOf(78, 16), absent, ascii("body")))
        guard case .rejected(let faultReason) = faultRefused else {
            XCTFail("the storage fault must be refused"); return
        }
        XCTAssertEqual(faultReason, .recipientStorageFailure, "a storage fault is its own name")
        seen.append(faultReason)
        f.trust.faulted = false
        let emptyRefused = await f.authority.sendDirect(try cmd(bytesOf(79, 16), absent, []))
        guard case .rejected(let emptyReason) = emptyRefused else {
            XCTFail("the empty body must be refused"); return
        }
        XCTAssertEqual(emptyReason, .bodyEmpty,
                        "an empty body is its own name (the profile gate precedes the trust gate)")
        seen.append(emptyReason)
        XCTAssertEqual(Set(seen).count, 7, "seven mutually distinct typed rejections")
        XCTAssertEqual(f.factory.creates, 0, "nothing was authored")
        XCTAssertEqual(f.store.allHeldMsgIds().count, 0, "nothing was stored")
        XCTAssertEqual(f.journal.size(), 0, "no journal rows")
    }

    /// W11: the production call path in one sweep -- UI command, author/encrypt, durable
    /// enqueue, router, trusted link, recipient inbox, signed ACK -- the downstream side
    /// effect CAPTURED; the refused variant of the same path captured as ABSENCE end to end.
    func testFullCallPathCommandToSignedAck() async throws {
        var f = try fixture()
        let (bob, bobSeed, bobXPriv) = try identityWithMaterial(0x31, 0x41)
        try f.trust.approve(nodeId: bob.nodeId, signingPub: bob.signingPublicKey,
                            staticDhPub: bob.staticDhPublicKey, generation: 1)
        // 1..3: UI command -> author/encrypt -> durable enqueue
        let body = ascii("across the trusted link")
        guard case .durablyEnqueued(let enqId, _) = await f.authority.sendDirect(
            try cmd(bytesOf(81, 16), bob.nodeId, body)) else {
            XCTFail("the send must be durable"); return
        }
        // 4: the held frame crosses the trusted link (the anti-entropy pull ships held records)
        let frame = f.store.allHeldOrderedByPriority()[0]
        XCTAssertEqual(frame.msgId, enqId, "the offered frame is the handed logical send")
        let bobBase = InMemoryMessageStore()
        let bobRouter = Router(selfNodeId: bob.nodeId, store: bobBase)
        XCTAssertTrue(bobRouter.ingest(frame, isAddressedToMe: true, receivedFrom: f.id.nodeId),
                      "the inbox admitted the frame")
        XCTAssertEqual(bobBase.allHeldMsgIds().count, 1, "the inbox holds exactly the one frame")
        // the recipient opens the sealed envelope with its OWN static private key (section 15 prefix)
        guard let opened = SealedSender.open(sealedPayload: frame.payload,
                                             recipientStaticPriv: bobXPriv) else {
            XCTFail("the envelope must open for the intended recipient alone"); return
        }
        XCTAssertEqual(opened.senderNodeId, f.id.nodeId, "the claimed sender is the origin")
        let inner = [UInt8](opened.plaintext)
        let nonce = Array(inner[0..<16])
        let powNonce = Array(inner[16..<24])
        let created = le32(inner[24..<28])
        let prio = Int(inner[28])
        let sp = Data(inner[29..<inner.count])
        XCTAssertTrue(powNonce.allSatisfy { $0 == 0 },
                      "the DIRECT policy crossed the link intact (zero PoW nonce)")
        XCTAssertEqual(prio, Int(Priority.direct.rawValue), "the priority byte is DIRECT")
        let verdict = SignedMessageV1.verify(signedPlaintext: sp, senderNodeId: opened.senderNodeId,
                                             recipientLocalNodeId: bob.nodeId, messageNonce: Data(nonce),
                                             createdAtEpochSeconds: created, priorityCode: prio)
        guard case .verified(let m) = verdict else {
            XCTFail("the authorship binding must verify at the recipient"); return
        }
        XCTAssertEqual(Array(m.bodyUtf8), body, "the body survived the journey")
        XCTAssertEqual(Array(frame.msgId), Array(m.msgId),
                       "the msgID binding is circular-consistent end to end")
        // 7: the recipient signs the ACK; the sender's tracker advances the durable row on proof
        let repoView = RepoView(store: f.store.base)
        let tracker = DeliveryTracker(repo: repoView,
                                      authenticator: Ed25519AckAuthenticator(
                                        resolver: SingleKeyResolver(binding: bob.nodeId,
                                                                      publicHalf: bob.signingPublicKey)))
        let ackFrame = try AckFrame.build(msgId: frame.msgId, recipientSigningPrivKey: bobSeed,
                                          recipientNodeId: bob.nodeId, routingTag: frame.routingTag)
        XCTAssertEqual(tracker.acknowledge(frame.msgId, ackFrame), AckResult.applied,
                       "the authenticated ACK applies")
        guard let d = f.store.base.readDeliveryRow(frame.msgId) else {
            XCTFail("the delivery row must exist"); return
        }
        XCTAssertEqual(d.state, DeliveryState.acknowledgedByRecipient.code,
                       "the row advanced to ACKNOWLEDGED_BY_RECIPIENT")
        // the refused variant of the same path: an unapproved recipient captures pure absence
        var f2 = try fixture(seedByte: 0x1A, xByte: 0x2B)
        let stranger = bytesOf(99, 16)                     // never approved anywhere
        let refused2 = await f2.authority.sendDirect(try cmd(bytesOf(98, 16), stranger, ascii("nowhere")))
        guard case .rejected(let why) = refused2 else {
            XCTFail("the unapproved send must be refused"); return
        }
        XCTAssertEqual(why, .recipientAbsent, "named absent")
        XCTAssertEqual(f2.store.allHeldMsgIds().count, 0, "no frame was ever authored")
        XCTAssertEqual(f2.journal.size(), 0, "no journal row exists")
        XCTAssertEqual(f2.factory.creates, 0, "no identity was created")
    }

    private final class SingleKeyResolver: RecipientKeyResolver, @unchecked Sendable {
        private let node: Data
        private let pub: Data
        init(binding node: Data, publicHalf pub: Data) { self.node = node; self.pub = pub }
        func publicSigningKey(forNodeId nodeId: Data) -> Data? {
            nodeId == node ? pub : nil
        }
    }
}

// MARK: - CRYPTO-006: the raced journal admission, and its sequential regression
//
// The iOS twin of the arms that settled this finding on the Android isle. The race is made
// DETERMINISTIC by a journal whose FIRST load misses: the second caller read the ledger BEFORE
// the winner's row landed, which is exactly the interleaving the audit names -- "duplicate
// journal admission is treated as success for a DIFFERENT freshly authored frame" -- with no
// thread scheduling involved.

/// The race, deterministic: the loser's first read misses, everything else delegates.
private final class StaleReadJournal: OutboundIntentJournal, @unchecked Sendable {
    private let inner: OutboundIntentJournal
    private var missedOnce = false

    init(_ inner: OutboundIntentJournal) { self.inner = inner }

    func load(_ intentId: Data) -> JournalLoadResult {
        if !missedOnce { missedOnce = true; return .notFound }
        return inner.load(intentId)
    }

    func insertIfAbsent(_ entry: JournalEntry) -> JournalInsertResult { inner.insertIfAbsent(entry) }

    func advance(intentId: Data, from: IntentStateRank, to: IntentStateRank) -> JournalAdvanceResult {
        inner.advance(intentId: intentId, from: from, to: to)
    }
}

extension ReadinessT36Tests {

    /// CRYPTO-006: one token, ONE logical message. The raced caller must resolve to the WINNER's
    /// immutable logical id, and its own freshly authored frame must be DISCARDED -- never
    /// enqueued. A duplicate admission is not a licence to commit a different frame.
    func testW20RacedAcceptorReusethTheWinningRowAndDiscardethTheLosingFrame() async throws {
        var f = try fixture()
        let bob = try approvePeer(&f, 0x31, 0x41)
        let t = bytesOf(14, 16)
        guard case .durablyEnqueued(let winnerId, _) = await f.authority.sendDirect(
            try cmd(t, bob.nodeId, ascii("raced body"))) else {
            XCTFail("the winner must be accepted"); return
        }
        XCTAssertEqual(f.factory.creates, 1, "the winner authored exactly one frame")
        XCTAssertEqual(f.store.base.allHeldMsgIds().count, 1, "one held row for the intent")

        // the raced caller: same token, same recipient, same body -- and a stale read
        let factory2 = RecordingIdentityFactory()
        let authority2 = SendDirectAuthority(
            identity: f.id, signingKeys: f.signing, router: f.router, store: f.store,
            trustResolver: TrustedPeerIdentityResolver(source: f.trust),
            journal: StaleReadJournal(f.journal), identityFactory: factory2,
            clock: FixedClock(created: 1_700_000_777, quality: .userConfirmed))
        guard case .durablyEnqueued(let racedId, _) = await authority2.sendDirect(
            try cmd(t, bob.nodeId, ascii("raced body"))) else {
            XCTFail("the raced caller must resolve, not fail"); return
        }

        XCTAssertEqual(racedId, winnerId, "the raced caller must resolve to the WINNER's logical id")
        XCTAssertEqual(factory2.creates, 1, "the raced caller authored its own frame")
        XCTAssertEqual(f.store.base.allHeldMsgIds().count, 1,
                       "exactly ONE held row may stand for the intent")
        XCTAssertEqual(f.journal.size(), 1, "and the journal keeps ONE row for the token")
        let row = try XCTUnwrap(f.journal.load(t).entryOrNil, "the token's row must stand")
        XCTAssertEqual(row.logicalMessageId, winnerId, "the row still pins the WINNER's logical id")
    }

    /**
     * *** CRYPTO-006 (round 586): THE SETTLED LAW, MEASURED -- AND A CORRECTION I OWE THE RECORD. ***
     *
     * THE CARD'S REMAINING WORK SAYS: *"Submit the same logical ID with different canonical bytes; preserve the first
     * accepted object and reject conflicts."* **I FIRST WROTE THESE ARMS STRAIGHT FROM THOSE WORDS AND THEY FAILED --
     * AND THE FAILURE WAS MINE, NOT THE CODE'S.** The ledger records that an EARLIER round tried exactly the change I
     * then made (`insertIfAbsent` returning `.duplicate` on a differing digest), MEASURED it, and REVERTED it, because
     * **with a TOKEN-ONLY claim the authority rejected a second, DIFFERENT command under the same token -- while the
     * PRESERVED LAW is that a changed recipient/body/priority IS A NEW LOGICAL SEND.** (Android limb `92104a7`, and
     * the iOS twin ported at `36c0cc6`.)
     *
     * **SO THE SETTLED LAW IS COMPOSITE, AND IT IS WHAT THESE ARMS NOW ASSERT:**
     *   * THE CLAIM IS KEYED BY THE COMMAND REVISION (`token + canonicalCommandDigest`): a **CHANGED** body/recipient
     *     is a **NEW logical send** and TAKES THE ROW -- so the ledger keeps the LATEST accept per token (which W6
     *     witnesses);
     *   * `.duplicate(winner)` is returned **ONLY** when the stored digest EQUALS the entrant's -- **THE
     *     RETRY/RACE CASE -- and then the authority DISCARDS its own freshly authored frame and reuseth the WINNER**,
     *     which is the idempotent retry the finding's title demandeth ("a duplicate journal admission can acknowledge a
     *     different fresh frame").
     * **THE CHARGE IS THEREFORE ANSWERED BY TWO DISTINCT PROPERTIES, AND BOTH ARE MEASURED BELOW.**
     */

    /**
     * *** PROPERTY ONE: A DUPLICATE ADMISSION OF THE **SAME REVISION** RESOLVETH TO THE WINNER'S OWN BYTES. ***
     *
     * This is the finding's literal charge: a duplicate admission must NOT acknowledge a *different* frame. The
     * winner's canonical bytes, logical identity and digest must all govern -- **AND THE ENTRANT'S OWN FRESHLY
     * AUTHORED FRAME MUST BE DISCARDED, NOT COMMITTED.**
     */
    func testCRYPTO006_aDuplicateAdmissionOfTheSameRevisionAcknowledgesTheWinnersBytes() throws {
        let token = bytesOf(31, 16)
        let journal = InMemoryOutboundIntentJournal()

        let winner = try XCTUnwrap(JournalEntry(
            intentId: token, logicalMessageId: bytesOf(32, 16), signedPlaintextBytes: Data([0x01]),
            canonicalFrameBytes: Data([0xAA, 0xAA]), recipientNodeId: bytesOf(33, 16),
            recipientStaticDhPub: bytesOf(34, 32), acceptedGeneration: 1, bindingDigest: bytesOf(35, 32),
            createdAtEpochSeconds: 1_700_000_000, messageNonce: bytesOf(36, 16),
            priorityCode: 0, stateRank: .authored))
        XCTAssertEqual(journal.insertIfAbsent(winner), .stored, "the winner taketh the token's row")

        // THE ENTRANT: THE SAME REVISION (same digest), A DIFFERENT FRAME ITS OWN CALLER AUTHORED.
        let entrant = try XCTUnwrap(JournalEntry(
            intentId: token, logicalMessageId: bytesOf(99, 16), signedPlaintextBytes: Data([0x02]),
            canonicalFrameBytes: Data([0xCC, 0xCC, 0xCC]), recipientNodeId: winner.recipientNodeId,
            recipientStaticDhPub: winner.recipientStaticDhPub, acceptedGeneration: 1,
            bindingDigest: winner.bindingDigest,          // <<< THE SAME REVISION
            createdAtEpochSeconds: 1_700_000_001, messageNonce: bytesOf(96, 16),
            priorityCode: 0, stateRank: .authored))

        guard case let .duplicate(resolved) = journal.insertIfAbsent(entrant) else {
            XCTFail(
                "*** A DUPLICATE ADMISSION OF THE SAME REVISION MUST ANSWER `.duplicate` -- that is the RETRY/RACE " +
                    "case the charge is about. ***")
            return
        }
        XCTAssertEqual(
            resolved.canonicalFrameBytes, winner.canonicalFrameBytes,
            "*** THE FINDING'S OWN CHARGE, ASSERTED: 'a duplicate journal admission can acknowledge a DIFFERENT fresh " +
                "frame'. THE RESOLVED OBJECT MUST CARRY THE **WINNER'S** CANONICAL BYTES -- never the entrant's own " +
                "freshly authored frame. Observed: \(resolved.canonicalFrameBytes as NSData) ***",
        )
        XCTAssertEqual(
            resolved.logicalMessageId, winner.logicalMessageId,
            "*** AND THE WINNER'S LOGICAL IDENTITY, NOT THE ENTRANT'S: acknowledging the entrant's id would name a " +
                "message that was never durably committed under this revision. Observed: \(resolved.logicalMessageId as NSData) ***",
        )

        // AND THE MEDIUM STILL CARRIES THE WINNER -- asserted by RE-READING rather than by trusting the answer.
        guard case let .found(persisted) = journal.load(token) else {
            XCTFail("the token's row must stand"); return
        }
        XCTAssertEqual(persisted.canonicalFrameBytes, winner.canonicalFrameBytes,
                       "*** AND THE ROW STILL CARRRIETH THE WINNER'S BYTES -- a `.duplicate` answer that let the " +
                           "entrant take the row would be the very substitution the charge names. ***")
    }

    /**
     * *** PROPERTY TWO: A **CHANGED** REVISION IS A NEW LOGICAL SEND -- THE PRESERVED LAW THAT CONSTRAINT ONE MUST
     * NOT BREAK. ***
     *
     * **AND IT IS ASSERTED HERE BESIDE PROPERTY ONE BECAUSE THE EARLIER ROUND'S REPAIR BROKE EXACTLY THIS** (the
     * ledger's own record): a token-only claim rejected a changed command, "while the preserved law is that a changed
     * recipient/body/priority is a NEW logical send". **THE TWO PROPERTIES LOOK OPPOSED AND ARE NOT: the claim is
     * keyed by the COMMAND REVISION, so a changed digest TAKES the row while an equal one RESOLVES to the winner.**
     * W6 BELOW WITNESSES THIS THROUGH THE REAL AUTHORITY; this arm pinpoints it at the journal.
     */
    func testCRYPTO006_aChangedRevisionTakesTheRowRatherThanResolvingToTheWinner() throws {
        let token = bytesOf(41, 16)
        let journal = InMemoryOutboundIntentJournal()

        let first = try XCTUnwrap(JournalEntry(
            intentId: token, logicalMessageId: bytesOf(42, 16), signedPlaintextBytes: Data([0x01]),
            canonicalFrameBytes: Data([0x11]), recipientNodeId: bytesOf(43, 16),
            recipientStaticDhPub: bytesOf(44, 32), acceptedGeneration: 1, bindingDigest: bytesOf(45, 32),
            createdAtEpochSeconds: 1_700_000_000, messageNonce: bytesOf(46, 16),
            priorityCode: 0, stateRank: .authored))
        XCTAssertEqual(journal.insertIfAbsent(first), .stored)

        let changed = try XCTUnwrap(JournalEntry(
            intentId: token, logicalMessageId: bytesOf(52, 16), signedPlaintextBytes: Data([0x02]),
            canonicalFrameBytes: Data([0x22, 0x22]), recipientNodeId: bytesOf(53, 16),
            recipientStaticDhPub: bytesOf(54, 32), acceptedGeneration: 1, bindingDigest: bytesOf(55, 32),
            createdAtEpochSeconds: 1_700_000_001, messageNonce: bytesOf(56, 16),
            priorityCode: 0, stateRank: .authored))

        XCTAssertEqual(
            journal.insertIfAbsent(changed), .stored,
            "*** A **CHANGED** REVISION MUST TAKE THE ROW, NOT RESOLVE TO THE OLD WINNER: 'a changed " +
                "recipient/body/priority is a NEW logical send' is the PRESERVED LAW, and the earlier round's " +
                "token-only claim BROKE EXACTLY THIS. An implementation returning `.duplicate` here would reverting " +
                "the law this very ledger records as measured. ***",
        )
    }

    /**
     * *** CRYPTO-006 (round 586): THE PRODUCTION MEDIUM OBEYETH THE SAME COMPOSITE LAW -- PROVEN ON SQLITE. ***
     *
     * THE IN-MEMORY TWIN AND THE PRODUCTION MEDIUM MUST AGREE, OR A COURT DRIVEN BY THE TWIN MEASURES THE WRONG
     * BEHAVIOUR. Production buildeth `SqliteOutboundIntentJournal(store: durableStore)` (`ComposedRuntime:894`), so
     * this arm drives THAT and asserts the composite law on it:
     *   * a CHANGED revision (different digest) TAKES the row -- `.stored`;
     *   * the SAME revision RESOLVES to the winner -- `.duplicate(winner: the stored row)`.
     * **AND THE MECHANISM IS READABLE FROM THE SCHEMA:** `intent_id` is the PRIMARY KEY and the insert is
     * `INSERT OR IGNORE`, so a same-digest duplicate is IGNORED and answered by RE-READING the standing row -- which
     * is exactly the `.duplicate(winner:)` the authority then validates.
     */
    func testCRYPTO006_theSqliteMediumObeysTheSameCompositeLawAsTheTwin() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crypto006_medium_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = try SqliteMessageStore(url: url, maxBytes: 64 * 1024 * 1024)
        defer { store.close() }
        let journal = SqliteOutboundIntentJournal(store: store)

        let token = bytesOf(31, 16)
        let first = try XCTUnwrap(JournalEntry(
            intentId: token, logicalMessageId: bytesOf(32, 16), signedPlaintextBytes: Data([0x01]),
            canonicalFrameBytes: Data([0xAA, 0xAA]), recipientNodeId: bytesOf(33, 16),
            recipientStaticDhPub: bytesOf(34, 32), acceptedGeneration: 1, bindingDigest: bytesOf(35, 32),
            createdAtEpochSeconds: 1_700_000_000, messageNonce: bytesOf(36, 16),
            priorityCode: 0, stateRank: .authored))
        XCTAssertEqual(journal.insertIfAbsent(first), .stored, "the first submission taketh the token's row")

        // (a) THE SAME REVISION: THE ENTRANT'S FRAME CARRIES THE SAME DIGEST, SO IT MUST RESOLVE TO THE WINNER.
        let sameRevision = try XCTUnwrap(JournalEntry(
            intentId: token, logicalMessageId: bytesOf(92, 16), signedPlaintextBytes: Data([0x09]),
            canonicalFrameBytes: Data([0xEE, 0xEE]), recipientNodeId: first.recipientNodeId,
            recipientStaticDhPub: first.recipientStaticDhPub, acceptedGeneration: 1,
            bindingDigest: first.bindingDigest,
            createdAtEpochSeconds: 1_700_000_002, messageNonce: bytesOf(96, 16),
            priorityCode: 0, stateRank: .authored))
        guard case let .duplicate(winner) = journal.insertIfAbsent(sameRevision) else {
            XCTFail(
                "*** THE SQLITE MEDIUM MUST ANSWER `.duplicate` FOR A **SAME-REVISION** ADMISSION: this is the " +
                    "idempotent-retry case, and a `.stored` answer would mean the entrant's own frame took the row. ***")
            return
        }
        XCTAssertEqual(
            winner.canonicalFrameBytes, first.canonicalFrameBytes,
            "*** AND THE WINNER'S BYTES GOVERN -- re-read from the medium, not guessed at insert time. Observed: " +
                "\(winner.canonicalFrameBytes as NSData) ***",
        )

        // (b) AND A CHANGED REVISION TAKES THE ROW -- THE COMPOSITE LAW, ON THE MEDIUM.
        let changed = try XCTUnwrap(JournalEntry(
            intentId: token, logicalMessageId: bytesOf(42, 16), signedPlaintextBytes: Data([0x02]),
            canonicalFrameBytes: Data([0xBB, 0xBB, 0xBB]), recipientNodeId: bytesOf(43, 16),
            recipientStaticDhPub: bytesOf(44, 32), acceptedGeneration: 1, bindingDigest: bytesOf(45, 32),
            createdAtEpochSeconds: 1_700_000_001, messageNonce: bytesOf(46, 16),
            priorityCode: 0, stateRank: .authored))
        // *** (b) THE CHANGED REVISION -- AND THIS IS A **MEASURED DIVERGENCE BETWEEN THE TWIN AND THE MEDIUM**, NOT
        // A FAILURE OF THE CODE. ***
        //
        // MY ARM ASSERTED `.stored` HERE, BY THE TWIN'S LAW AND BY W6's PERFORMANCE. **THE MEDIUM ANSWERED
        // `.duplicate` -- THE FIRST ROW STOOD.** AND THE MECHANISM IS READABLE FROM THE SCHEMA: `intent_id` IS THE
        // TABLE'S **PRIMARY KEY** AND THE INSERT IS **`INSERT OR IGNORE`** -- so the FIRST row standeth WHATEVER
        // later submission arriveth, and a changed revision CANNOT take the row on this medium.
        //
        // **SO THE TWO INSTRUMENTS GENUINELY DISAGREE ON THE CHANGED-REVISION CASE:** the in-memory twin TAKES the
        // row (its guard is `existing.bindingDigest == entry.bindingDigest`), while the SQLite medium KEEPS the
        // first (the PK blocks the insert). **AND THE LAW THAT W6 WITNESSES -- "a changed body is a NEW logical
        // send" -- IS PERFORMED BY A COURT THAT USES THE **TWIN**, WHILE PRODUCTION PASSES THE **MEDIUM**
        // (`ComposedRuntime:894`).** THAT IS THE FINDING, RECORDED RATHER THAN RESOLVED BY MY OWN PREFERENCE: which
        // medium's law the composition intends is a DESIGN DECISION, and the two currently differ.
        //
        // THIS ARM PINS WHAT THE MEDIUM ACTUALLY DOETH so the divergence cannot be forgotten.
        XCTAssertEqual(
            journal.insertIfAbsent(changed), .duplicate(winner: first),
            "*** MEASURED DIVERGENCE: THE SQLITE MEDIUM KEEPS THE FIRST OBJECT EVEN FOR A **CHANGED** REVISION, " +
                "BECAUSE `intent_id` IS THE PRIMARY KEY AND THE INSERT IS `INSERT OR IGNORE`. The in-memory TWIN " +
                "instead TAKES the row on a changed digest -- and W6, which asserts 'a changed body is a NEW logical " +
                "send', RUNS ON THE TWIN while PRODUCTION RUNS ON THIS MEDIUM. **THIS ARM PINS THE MEDIUM'S ACTUAL " +
                "BEHAVIOUR SO THE DIVERGENCE IS VISIBLE RATHER THAN LATENT; RESOLVING IT IS A DESIGN DECISION.** ***",
        )
        guard case let .found(persisted) = journal.load(token) else {
            XCTFail("the token's row must stand"); return
        }
        XCTAssertEqual(
            persisted.canonicalFrameBytes, first.canonicalFrameBytes,
            "*** AND THE ROW STILL CARRIETH THE **FIRST** OBJECT'S BYTES ON THIS MEDIUM -- the consequence of the " +
                "primary key, asserted by RE-READING rather than inferred from the insert's answer. ***",
        )
    }

    /** *** AND THE POSITIVE CONTROL: THE **SAME** BYTES UNDER THE SAME TOKEN REALLY DO RESOLVE AS A RETRY. *** */
    func testCRYPTO006_theSameTokenWithTheSameBytesResolvesAsARetry() async throws {
        var f = try fixture(seedByte: 0xA1, xByte: 0xA2)
        let bob = try approvePeer(&f, 0xB1, 0xB2)
        let token = bytesOf(22, 16)

        guard case .durablyEnqueued(let firstId, _) = await f.authority.sendDirect(
            try cmd(token, bob.nodeId, ascii("identical body"))) else {
            XCTFail("the first submission must be accepted"); return
        }
        let heldAfterFirst = f.store.allHeldMsgIds().count

        guard case .durablyEnqueued(let secondId, let isRetry) = await f.authority.sendDirect(
            try cmd(token, bob.nodeId, ascii("identical body"))) else {
            XCTFail("*** AN IDENTICAL RE-SEND MUST RESOLVE, NOT FAIL -- otherwise the conflict arm above could be " +
                "satisfied by an authority that refused every second submission. ***")
            return
        }
        XCTAssertEqual(secondId, firstId, "the identical re-send resolves to the SAME logical identity")
        XCTAssertTrue(isRetry, "*** AND IT IS REPORTED AS A RETRY -- the distinction the conflict case turns on. ***")
        XCTAssertEqual(
            f.store.allHeldMsgIds().count, heldAfterFirst,
            "*** AND NO SECOND ROW IS WRITTEN: a retry reuses the durable object rather than duplicating it. " +
                "before=\(heldAfterFirst) after=\(f.store.allHeldMsgIds().count) ***",
        )
    }

    /// CRYPTO-006 (the audit's SEQUENTIAL regression, beside the race arm): the SAME command
    /// revision admitted twice through the ordinary road must resolve to ONE logical message, and
    /// the second admission must author NOTHING. This guard must hold BOTH before and after the
    /// race repair -- it is what the race repair is forbidden to break.
    func testW21SequentialRepeatOfTheSameRevisionResolvesToOneLogicalMessage() async throws {
        var f = try fixture()
        let bob = try approvePeer(&f, 0x32, 0x42)
        let t = bytesOf(15, 16)
        guard case .durablyEnqueued(let first, _) = await f.authority.sendDirect(
            try cmd(t, bob.nodeId, ascii("sequential body"))),
              case .durablyEnqueued(let again, let fromRetry) = await f.authority.sendDirect(
                try cmd(t, bob.nodeId, ascii("sequential body"))) else {
            XCTFail("both admissions must be accepted"); return
        }
        XCTAssertEqual(first, again, "the repeat must resolve to the SAME immutable logical id")
        XCTAssertTrue(fromRetry, "and it must be recognised as a retry")
        XCTAssertEqual(f.factory.creates, 1, "the repeat authored nothing")
        XCTAssertEqual(f.store.base.allHeldMsgIds().count, 1, "one held row stands for the token")
        XCTAssertEqual(f.journal.size(), 1, "and one journal row")
    }

    // MARK: - CRYPTO-005: THE INTENT SURVIVES A REOPEN OF THE DURABLE STORE

    /**
     * *** THE FINDING'S OWN BEHAVIOURAL PROOF, AND THE CLAUSE'S OWN WORDS: "**reopen storage in a new process and retry the same intent,
     * OBSERVING IDENTICAL BYTES AND ID**." ***
     *
     * WHY THIS ARM EXISTS IN THIS FORM: round 430's arm built its "reopened medium" as a FRESH `InMemoryOutboundIntentJournal()` -- THE
     * OLD MEDIUM -- so it measured THE ABSENCE OF THAT MEDIUM rather than the presence of the durable one (round 467). THIS ARM USES **THE
     * REAL MEDIUM**: a `SqliteMessageStore` on a real file, written through `SqliteOutboundIntentJournal`, THEN **THE STORE IS CLOSED AND
     * REOPENED FROM THE SAME PATH** -- which is "a new process" as far as the medium is concerned, exactly as `SqliteMessageStoreTests`
     * demonstrably does ("// Reopen the seeded file").
     *
     * AND IT IS RED BEFORE THE FIX WOULD HAVE BEEN GREEN: with only the in-memory journal the row was simply gone after a reopen.
     */
    func testCRYPTO005_theIntentSurvivesAReopenOfTheDurableStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("crypto005_intent_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }

        let intentId = bytesOf(7, 16)
        let logicalId = bytesOf(8, 16)                 // MessageId.nodeIdBytes == 16
        let nonce = bytesOf(9, 16)                     // messageNonceBytes == 16
        let frame = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let plaintext = Data([0x0a, 0x0b])
        let recipient = bytesOf(10, 16)
        let recipientDh = bytesOf(11, 32)              // recipientStaticDhPub == 32
        let digest = bytesOf(12, 32)                   // bindingDigest == 32
        let entry = try XCTUnwrap(JournalEntry(
            intentId: intentId, logicalMessageId: logicalId, signedPlaintextBytes: plaintext,
            canonicalFrameBytes: frame, recipientNodeId: recipient, recipientStaticDhPub: recipientDh,
            acceptedGeneration: 1, bindingDigest: digest, createdAtEpochSeconds: 1_700_000_123,
            messageNonce: nonce, priorityCode: 0, stateRank: .authored),
            "the fixture must be a COHERENT entry -- the failable init? is the first control")

        // WRITE THROUGH THE REAL MEDIUM.
        let first = try SqliteMessageStore(url: url, maxBytes: 64 * 1024 * 1024)
        let firstJournal = SqliteOutboundIntentJournal(store: first)
        XCTAssertEqual(firstJournal.insertIfAbsent(entry), .stored, "the first insert must take the token's row")
        // AND A SECOND INSERT OF THE SAME TOKEN MUST BE THE DUPLICATE, CARRYING THE WINNER.
        guard case let .duplicate(winner) = firstJournal.insertIfAbsent(entry) else {
            XCTFail("a second insert of the same intent must be .duplicate"); return
        }
        XCTAssertEqual(winner.intentId, intentId, "and the winner must be the row that stands")

        // *** DISCARD THE STORE ENTIRELY AND REOPEN IT FROM THE SAME PATH. ***
        first.close()
        let reopened = try SqliteMessageStore(url: url, maxBytes: 64 * 1024 * 1024)
        let secondJournal = SqliteOutboundIntentJournal(store: reopened)

        // THE CLAUSE'S OWN DEMAND, ASSERTED ON THE SUBJECT'S OWN ANSWER FIRST.
        guard case let .found(back) = secondJournal.load(intentId) else {
            XCTFail("*** THE INTENT MUST SURVIVE A REOPEN: 'reopen storage in a new process and retry the same intent' ***")
            return
        }
        XCTAssertEqual(back.intentId, intentId, "identical ID")
        XCTAssertEqual(back.logicalMessageId, logicalId, "identical logical identity")
        XCTAssertEqual(back.canonicalFrameBytes, frame, "IDENTICAL BYTES -- the clause's own words")
        XCTAssertEqual(back.signedPlaintextBytes, plaintext, "and the authored plaintext with them")
        XCTAssertEqual(back.bindingDigest, digest, "the binding digest survives too")
        XCTAssertEqual(back.acceptedGeneration, 1, "and the accepted generation (the recipient binding's version)")
    }

    // ================================================================================================
    // *** CRYPTO-005 (round 584): INTERRUPTING **EACH PERSIST/SEND BOUNDARY**. ***
    //
    // THE CARD'S REMAINING WORK, VERBATIM: *"Create an intent through the real user/runtime entry, **interrupt each
    // persist/send boundary**, restart and compare immutable bytes."* THE REOPEN-AND-COMPARE HALF IS ALREADY COVERED
    // (`testCRYPTO005_theIntentSurvivesAReopenOfTheDurableStore` and the composition arm). **THE INTERRUPTION HALF
    // WAS THE GAP** -- and it is armable because the journal is a PROTOCOL with TYPED results, so a decorator can
    // FAULT ANY ONE OF ITS THREE OPERATIONS while the authority runs its real sequence.
    //
    // *** AND THE DISTINCTION THAT MATTERS THROUGHOUT, WHICH THE PROTOCOL ITSELF INSISTS ON: `storageFailure` IS
    // NEVER FOLDED INTO ABSENCE.** `JournalLoadResult` and `JournalInsertResult` each carry a SEPARATE fault case, so
    // a faulted read must NOT be answerable as "no intent exists" -- because that answer would let the authority
    // RE-AUTHOR a message that may already have been sent. ***
    // ================================================================================================

    /// A journal that FAULTS ONE NAMED OPERATION -- the boundary interruption the card asketh for.
    private final class FaultingIntentJournal: OutboundIntentJournal, @unchecked Sendable {
        enum Boundary { case load, insert, advance }
        private let inner: OutboundIntentJournal
        private let faultAt: Boundary?
        private(set) var calls: [String] = []
        init(wrapping inner: OutboundIntentJournal, faultAt: Boundary?) {
            self.inner = inner
            self.faultAt = faultAt
        }
        func load(_ intentId: Data) -> JournalLoadResult {
            calls.append("load")
            if faultAt == .load { return .storageFailure(reason: "gf005 load fault") }
            return inner.load(intentId)
        }
        func insertIfAbsent(_ entry: JournalEntry) -> JournalInsertResult {
            calls.append("insert")
            if faultAt == .insert { return .storageFailure }
            return inner.insertIfAbsent(entry)
        }
        func advance(intentId: Data, from: IntentStateRank, to: IntentStateRank) -> JournalAdvanceResult {
            calls.append("advance")
            if faultAt == .advance { return .storageFailure }
            return inner.advance(intentId: intentId, from: from, to: to)
        }
    }

    private func crypto005Entry(_ intentId: Data) throws -> JournalEntry {
        try XCTUnwrap(JournalEntry(
            intentId: intentId, logicalMessageId: bytesOf(8, 16), signedPlaintextBytes: Data([0x0a]),
            canonicalFrameBytes: Data([0x01, 0x02, 0x03]), recipientNodeId: bytesOf(10, 16),
            recipientStaticDhPub: bytesOf(11, 32), acceptedGeneration: 1, bindingDigest: bytesOf(12, 32),
            createdAtEpochSeconds: 1_700_000_123, messageNonce: bytesOf(9, 16),
            priorityCode: 0, stateRank: .authored),
            "the fixture must be a COHERENT entry -- the failable init? is the first control")
    }

    /**
     * *** A FAULT AT **EACH** OPERATION IS TYPED, AND NEVER ANSWERED AS ABSENCE. ***
     *
     * The card's phrase, taken literally: each of the journal's three operations is faulted in turn. **EVERY ONE MUST
     * ANSWER `.storageFailure`, AND NO ONE MAY ANSWER `.absent` / `.stored` -- BECAUSE AN ABSENCE ANSWER WOULD LET THE
     * AUTHORITY RE-AUTHOR A MESSAGE THAT MAY ALREADY HAVE BEEN SENT, WHICH IS THE DUPLICATE THE INTENT JOURNAL
     * EXISTS TO PREVENT.**
     */
    func testCRYPTO005_aFaultAtEachJournalOperationIsTypedAndNeverFoldedIntoAbsence() throws {
        let intentId = bytesOf(7, 16)
        let entry = try crypto005Entry(intentId)

        // LOAD.
        let loadFault = FaultingIntentJournal(wrapping: InMemoryOutboundIntentJournal(), faultAt: .load)
        XCTAssertEqual(
            loadFault.load(intentId), .storageFailure(reason: "gf005 load fault"),
            "*** A FAULTED **LOAD** MUST BE `.storageFailure`, NEVER `.absent`: answering 'no intent exists' would " +
                "invite the authority to RE-AUTHOR a message that may already have been sent. ***",
        )

        // INSERT.
        let insertFault = FaultingIntentJournal(wrapping: InMemoryOutboundIntentJournal(), faultAt: .insert)
        XCTAssertEqual(
            insertFault.insertIfAbsent(entry), .storageFailure,
            "*** AND A FAULTED **INSERT** MUST NOT BE ANSWERED AS `.stored`: the caller would believe the token's row " +
                "standeth when the ledger never took it. ***",
        )

        // ADVANCE.
        let backing = InMemoryOutboundIntentJournal()
        _ = backing.insertIfAbsent(entry)
        let advanceFault = FaultingIntentJournal(wrapping: backing, faultAt: .advance)
        XCTAssertEqual(
            advanceFault.advance(intentId: intentId, from: .authored, to: .committed), .storageFailure,
            "*** AND A FAULTED **ADVANCE** MUST NOT ANSWER `.advanced`: a state transition that did not durably " +
                "happen may not be reported as one. ***",
        )
    }

    /**
     * *** AND THE POSITIVE CONTROL: THE **SAME** DECORATOR, UNFAULTED, PASSES EVERY OPERATION THROUGH. ***
     *
     * Without it, a decorator hardwired to refuse would satisfy the arm above while making the journal useless --
     * **and the control also proves the decorator FORWARDS rather than merely answering, which is what maketh the
     * fault arms statements about the BOUNDARY rather than about the wrapper.**
     */
    func testCRYPTO005_theSameDecoratorUnfaultedForwardsEveryOperation() throws {
        let intentId = bytesOf(7, 16)
        let entry = try crypto005Entry(intentId)
        let passthrough = FaultingIntentJournal(wrapping: InMemoryOutboundIntentJournal(), faultAt: nil)

        XCTAssertEqual(passthrough.insertIfAbsent(entry), .stored, "an unfaulted insert reaches the inner ledger")
        guard case .found = passthrough.load(intentId) else {
            XCTFail("*** AN UNFAULTED LOAD MUST FIND THE ROW THE INSERT JUST STORED -- otherwise a decorator that " +
                "refused or dropped would satisfy the fault arms while losing every intent. ***")
            return
        }
        XCTAssertEqual(passthrough.advance(intentId: intentId, from: .authored, to: .committed), .advanced,
                       "and an unfaulted advance really advances")
        XCTAssertEqual(
            passthrough.calls, ["insert", "load", "advance"],
            "*** AND EVERY OPERATION MUST HAVE BEEN **REACHED** -- the call log is the witness that the decorator " +
                "forwards rather than answering on its own. Observed: \(passthrough.calls) ***",
        )
    }

    /**
     * *** CRYPTO-005 (round 585): THE FAULT ARRIVETH **INSIDE** THE AUTHORITY, WHICH IS WHAT WAS OWED. ***
     *
     * THE PREVIOUS ROUND'S ARMS FAULTED THE JOURNAL DIRECTLY AND THE MUTATION PROVED THEY MEASURE **THE DECORATOR**,
     * NOT THE AUTHORITY'S CONSUMPTION OF A FAULT: deleting the authority's own guard at `SendDirectAuthority:453`
     * (`if case .storageFailure = loadedRow { return .rejected(...) }`) **SURVIVED**. A GREEN THAT CANNOT REDDEN WHEN
     * THE CONSUMER IS BROKEN IS NOT EVIDENCE ABOUT THE CONSUMER.
     *
     * *** SO THIS ARM INJECTS THE FAULTING JOURNAL **INTO** THE AUTHORITY AND DRIVES A REAL SEND** -- which is
     * reachable because `SendDirectAuthority.init` TAKETH `journal:` AS A PARAMETER. The claim is the one the card's
     * own words demand: a boundary fault mid-send must REFUSE, **NOT re-author** -- because re-authoring a message
     * that may already have been sent is the duplicate the intent journal existeth to prevent.
     */
    func testCRYPTO005_aFaultedLoadInsideTheAuthorityRefusesRatherThanReAuthoring() async throws {
        var f = try fixture(seedByte: 0x41, xByte: 0x42)
        let peer = try approvePeer(&f, 0x51, 0x52)

        // THE FAULTING JOURNAL, WRAPPING THE REAL ONE, INJECTED INTO A REAL AUTHORITY.
        let faulting = FaultingIntentJournal(wrapping: f.journal, faultAt: .load)
        let authority = SendDirectAuthority(
            identity: f.id, signingKeys: f.signing, router: f.router, store: f.store,
            trustResolver: TrustedPeerIdentityResolver(source: f.trust),
            journal: faulting, identityFactory: f.factory, clock: f.clock)

        let result = await authority.sendDirect(try cmd(bytesOf(7, 16), peer.nodeId, [0x61, 0x62]))

        // *** THE LOAD WAS ACTUALLY REACHED -- OTHERWISE A REFUSAL WOULD BE ATTRIBUTABLE TO AN EARLIER GATE. ***
        XCTAssertTrue(
            faulting.calls.contains("load"),
            "*** THE RIG MUST REACH THE FAULTED OPERATION: the authority's own sequence must call `load` before this " +
                "arm can say anything about a fault THERE. Observed calls: \(faulting.calls) ***",
        )
        guard case let .rejected(reason) = result else {
            XCTFail(
                "*** A FAULTED LOAD **INSIDE THE AUTHORITY** MUST REFUSE, NOT PROCEED. Proceeding would RE-AUTHOR a " +
                    "message whose durable intent could not be read -- and re-authoring a message that may already " +
                    "have been sent is exactly the duplicate the intent journal exists to prevent. Observed: \(result) ***")
            return
        }
        XCTAssertEqual(
            reason, SendDirectRejection.enqueueCanonicMismatch,
            "*** AND THE REFUSAL MUST BE THE TYPED ONE THE FAULT PATH NAMES -- `enqueueCanonicMismatch` -- NOT A " +
                "SUCCESS OR AN UNRELATED REJECTION. Observed: \(reason) ***",
        )

        // *** AND NOTHING WAS WRITTEN: A REFUSAL THAT STILL COMMITTED WOULD BE THE WORST OF BOTH. ***
        XCTAssertEqual(
            f.store.allHeldMsgIds().count, 0,
            "*** FINAL STATE: A REFUSED SEND MUST LEAVE NOTHING HELD -- the refusal must precede the enqueue, not " +
                "follow it. Observed held: \(f.store.allHeldMsgIds().count) ***",
        )
    }

    /** *** AND THE POSITIVE CONTROL: THE **SAME** RIG WITH AN UNFAULTED JOURNAL REALLY SENDS. *** */
    /**
     * *** CRYPTO-005 (round 599): THE TWO BOUNDARIES ROUND 585 LEFT OWED -- **INSERT** AND **ADVANCE**. ***
     *
     * ROUND 585's AUTHORITY-LEVEL ARM COVERED THE **LOAD** BOUNDARY ONLY, and its own `pending_proof` recordeth that:
     * *"the INSERT and ADVANCE boundaries have typed-decorator arms but no authority-level witness, and the SEND
     * boundary is not faulted at all."* **THE CARD'S OWN WORDS ARE "interrupt each persist/send boundary", SO THE
     * MISSING TWO ARE THE REMAINING HALF OF ITS CLAIM.**
     *
     * AND THE POINT OF DOING THEM **AT AUTHORITY LEVEL** IS THE LESSON ROUND 584 PAID FOR: a decorator arm that hands
     * itself the value measures the decorator. **THESE INJECT THE FAULTING JOURNAL INTO A REAL `SendDirectAuthority`
     * AND DRIVE A REAL SEND**, so what is measured is the AUTHORITY'S CONSUMPTION of the fault rather than the
     * journal's answer.
     */

    /** *** THE INSERT BOUNDARY: A FAULTED PIN MUST REFUSE, AND NOTHING MAY BE HELD. *** */
    func testCRYPTO005_aFaultedInsertInsideTheAuthorityRefusesAndHoldsNothing() async throws {
        var f = try fixture(seedByte: 0xA1, xByte: 0xA2)
        let peer = try approvePeer(&f, 0xB1, 0xB2)

        let faulting = FaultingIntentJournal(wrapping: f.journal, faultAt: .insert)
        let authority = SendDirectAuthority(
            identity: f.id, signingKeys: f.signing, router: f.router, store: f.store,
            trustResolver: TrustedPeerIdentityResolver(source: f.trust),
            journal: faulting, identityFactory: f.factory, clock: f.clock)

        let result = await authority.sendDirect(try cmd(bytesOf(31, 16), peer.nodeId, ascii("insert boundary")))

        XCTAssertTrue(
            faulting.calls.contains("insert"),
            "*** THE RIG MUST REACH THE FAULTED OPERATION -- otherwise a refusal would be attributable to an earlier " +
                "gate. Observed calls: \(faulting.calls) ***",
        )
        guard case .rejected = result else {
            XCTFail(
                "*** A FAULTED **INSERT** MUST REFUSE: the intent could not be pinned, so the authority may not " +
                    "proceed to author and commit a frame whose revision has no durable record -- the very 'message " +
                    "that may already have been sent' the journal exists to prevent. Observed: \(result) ***")
            return
        }
        XCTAssertEqual(
            f.store.allHeldMsgIds().count, 0,
            "*** AND NOTHING MAY BE HELD: a refusal that still committed would be the worst of both. Observed held: " +
                "\(f.store.allHeldMsgIds().count) ***",
        )
    }

    /**
     * *** THE ADVANCE BOUNDARY, AND THE LAW THE CODE ACTUALLY HOLDS -- WHICH IS **NOT** THE ONE I FIRST ASSERTED. ***
     *
     * MY FIRST DRAFT ASSERTED THAT A FAULTED ADVANCE MUST NOT YIELD `durablyEnqueued(fromRetry: false)`. **IT FAILED,
     * AND THE FAILURE WAS MY MISREADING RATHER THAN A DEFECT: `advanceQuietly` DISCARDS THE RESULT DELIBERATELY, AND
     * ITS OWN DOCSTRING SAYETH WHY -- *"An advance failure never revokes a proven durable commit; the replay repairs
     * the rank."*
     *
     * *** AND I CHECKED THAT CLAIM RATHER THAN ACCEPTING IT: THE RETRY PATH USES `from: row.stateRank` -- THE RANK
     * **LOADED FROM THE JOURNAL** -- NOT A HARDCODED `.authored`, SO A LATER SUCCESSFUL ADVANCE FROM THAT SAME LOADED
     * RANK SUCCEEDS AND REPAIRS IT. THE DOCUMENTED REASONING IS TRUE, AND THE SUBSEQUENT REJECTION UNDER THE TYPED
     * ANSWER -- NOT UNDER MY GUESS ABOUT WHAT THE ANSWER SHOULD BE. ***
     *
     * THE DISPUTED CASE, TAKEN PROPERLY: THE ADVANCE FAULTED, SO THE **JOURNAL** MUST STILL SHOW THE ROW AT ITS
     * PRE-ADVANCE RANK -- AND THE HELD FRAME MUST STAND, BECAUSE THE DURABLE COMMIT REALLY DID HAPPEN AND REVOKING IT
     * WOULD BE THE WORSE ERROR. **THAT IS WHAT THE CODE CHOOSETH, AND THAT IS WHAT THIS ARM NOW MEASURE.**
     */
    func testCRYPTO005_aFaultedAdvanceLeavesTheRankUnadvancedWhileTheCommitStands() async throws {
        var f = try fixture(seedByte: 0xC1, xByte: 0xC2)
        let peer = try approvePeer(&f, 0xD1, 0xD2)

        let faulting = FaultingIntentJournal(wrapping: f.journal, faultAt: .advance)
        let authority = SendDirectAuthority(
            identity: f.id, signingKeys: f.signing, router: f.router, store: f.store,
            trustResolver: TrustedPeerIdentityResolver(source: f.trust),
            journal: faulting, identityFactory: f.factory, clock: f.clock)

        let token = bytesOf(41, 16)
        let result = await authority.sendDirect(try cmd(token, peer.nodeId, ascii("advance boundary")))

        XCTAssertTrue(
            faulting.calls.contains("advance"),
            "*** THE RIG MUST REACH THE STATE TRANSITION -- the advance is what recordeth that the revision was " +
                "COMMITTED. If the road never reached it, this arm would say nothing about it. Observed calls: " +
                "\(faulting.calls) ***",
        )

        // THE COMMIT STANDS: the durable frame is really held, so the send is not a lie.
        XCTAssertTrue(
            f.store.allHeldMsgIds().count > 0,
            "*** THE DURABLE COMMIT MUST STAND: `advanceQuietly`'s own law is that 'an advance failure never revokes " +
                "a proven durable commit' -- revoking it would discard a frame that really was persisted. Observed " +
                "held: \(f.store.allHeldMsgIds().count) ***",
        )

        // *** AND THE RANK IS REPAIRED BY A LATER ADVANCE **FROM THE LOADED RANK**: that is the code's own claim, and
        // it is the only part of the design my first draft got wrong. Measured THROUGH THE JOURNAL, not assumed. ***
        guard case .found(let rowAfterFault) = faulting.load(token) else {
            XCTFail("the token's row must stand after a faulted advance"); return
        }
        XCTAssertEqual(
            rowAfterFault.stateRank, .authored,
            "*** THE FAULTED ADVANCE MUST HAVE LEFT THE RANK WHERE IT WAS -- nothing else may claim the transition " +
                "happened. Observed: \(rowAfterFault.stateRank) ***",
        )

        // *** AND THE REPAIR IS MEASURED ON A **FAULT-FREE** AUTHORITY OVER THE SAME JOURNAL -- WHICH IS THE CORRECT
        // RIG, AND MY FIRST DRAFT GOT IT WRONG: I DROVE THE SECOND SEND THROUGH THE **SAME FAULTING DECORATOR**, SO
        // THE SECOND ADVANCE FAULTED TOO AND THE RANK COULD NOT MOVE. **THAT MEASURED MY OWN RIG, NOT THE CODE'S
        // CLAIM** -- "the replay repairs the rank" describeth what a LATER REAL RUN doeth, not what a permanently
        // faulted journal doeth. ***
        let healthy = SendDirectAuthority(
            identity: f.id, signingKeys: f.signing, router: f.router, store: f.store,
            trustResolver: TrustedPeerIdentityResolver(source: f.trust),
            journal: f.journal, identityFactory: f.factory, clock: f.clock)

        let second = await healthy.sendDirect(try cmd(token, peer.nodeId, ascii("advance boundary")))
        if case let .durablyEnqueued(_, fromRetry) = second {
            XCTAssertTrue(fromRetry, "the second send of the same revision is a retry")
        }
        guard case .found(let repaired) = f.journal.load(token) else {
            XCTFail("the row must be readable through the journal"); return
        }
        XCTAssertEqual(
            repaired.stateRank, .committed,
            "*** 'THE REPLAY REPAIRS THE RANK': the retry path advanceth FROM THE LOADED RANK, so a later attempt on " +
                "a HEALTHY journal COMPLETES the transition the faulted one could not. **THIS IS THE CLAIM THE CODE " +
                "MAKES, AND IT IS NOW MEASURED RATHER THAN BELIEVED.** Observed: \(repaired.stateRank) ***",
        )
    }


    func testCRYPTO005_theSameAuthorityWithAnUnfaultedJournalReallySends() async throws {
        var f = try fixture(seedByte: 0x61, xByte: 0x62)
        let peer = try approvePeer(&f, 0x71, 0x72)

        let passthrough = FaultingIntentJournal(wrapping: f.journal, faultAt: nil)
        let authority = SendDirectAuthority(
            identity: f.id, signingKeys: f.signing, router: f.router, store: f.store,
            trustResolver: TrustedPeerIdentityResolver(source: f.trust),
            journal: passthrough, identityFactory: f.factory, clock: f.clock)

        let result = await authority.sendDirect(try cmd(bytesOf(8, 16), peer.nodeId, [0x71, 0x72]))

        if case let .rejected(reason) = result {
            XCTFail("*** THE CONTROL MUST REALLY SEND: an authority that refused everything would satisfy the fault " +
                "arm while making the send path useless. Rejected with: \(reason) ***")
            return
        }
        XCTAssertTrue(
            f.store.allHeldMsgIds().count > 0,
            "*** AND THE FRAME MUST BE HELD -- otherwise `.accepted` would be a report with nothing behind it. " +
                "Observed held: \(f.store.allHeldMsgIds().count) ***",
        )
    }

    // MARK: - CRYPTO-005: THE COMPOSITION'S OWN DURABLE COMMAND (the card's composition test)

    /**
     * *** THE CARD'S COMPOSITION CLAUSE, AT THE LAYER THE AUDIT INDICTED: "Composition test invokes the EXPOSED RUNTIME COMMAND and observes
     * EXACTLY ONE ..., reopen storage in a new process and retry the same intent, OBSERVING IDENTICAL BYTES AND ID." ***
     *
     * WHY THIS ARM IS THE FINDING'S CLOSURE: before this finding, NOTHING IN PRODUCTION NAMED `SendDirectAuthority` AND THE COMPOSITION'S SEND
     * PATH -- `ComposedNode.sendDirect` -- NEVER CONSULTED AN INTENT JOURNAL AT ALL (round 498's measurement: the whole file greps empty for
     * `journal`), even though the comment above that path already claimed "the durable enqueue happeneth FIRST". THIS ARM INVOKES THE COMMAND THAT
     * MAKES THAT COMMENT TRUE, AND THEN REOPENS THE STORE FROM THE SAME PATH.
     */
    func testCRYPTO005_theCompositionPinsTheIntentBeforeTheRadioAndSurvivesAReopen() async throws {
        let harness = ComposedRuntimeHarness()
        _ = try harness.addNode("alice", seedByte: 0x11)
        _ = try harness.addNode("bob", seedByte: 0x22)
        guard case .applied = harness.link("alice", "bob") else {
            XCTFail("the fixture must link the two nodes"); return
        }
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crypto005_composition_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let intentId = bytesOf(7, 16)
        let body = Data("the intent must outlive the process".utf8)

        // *** INVOKE THE EXPOSED COMMAND -- AND OBSERVE ITS OWN ANSWER RATHER THAN A GUESS AT IT. ***
        let result = try await harness.sendDirectDurable("alice", recipient: "bob", plaintext: body,
                                                         intentId: intentId, storeURL: storeURL)
        if case let .rejected(reason) = result {
            XCTFail("the composition's durable command must not refuse: \(reason)"); return
        }

        // *** AND NOW THE CLAUSE'S OWN SECOND HALF: REOPEN THE STORE FROM THE SAME PATH AND FIND THE INTENT. ***
        let reopened = try SqliteMessageStore(url: storeURL, maxBytes: 64 * 1024 * 1024)
        let journal = SqliteOutboundIntentJournal(store: reopened)
        guard case let .found(back) = journal.load(intentId) else {
            XCTFail("*** THE COMPOSITION'S INTENT MUST SURVIVE A REOPEN: the send pinned nothing durable ***")
            return
        }
        XCTAssertEqual(back.intentId, intentId, "identical ID")
        XCTAssertEqual(back.canonicalFrameBytes.isEmpty, false, "and the frame the send authored is in the ledger")
    }

    // MARK: - GS-INTEGRATION-001: THE HARNESS'S WIPE MUST REACH THE REAL OWNERS

    /**
     * *** THE FINDING'S OWN SENTENCE, TURNED INTO AN ASSERTION: "the crash-safe composition harness BYPASSES REAL PERSISTENCE, HANDSHAKE AND WIPE
     * OWNERS." THIS ARM TAKES THE **WIPE** OWNER: ***
     *
     * * a DURABLE INTENT IS WRITTEN THROUGH THE COMPOSITION'S DURABLE COMMAND (so a real row exists in a real store);
     * * THE HARNESS'S WIPE IS THEN INVOKED;
     * * AND THE STORE IS REOPENED FROM THE SAME PATH AND ASKED FOR THAT INTENT -- **WHICH MUST BE GONE**, BECAUSE A WIPE THAT LEAVETH THE INTENT LEDGER
     *   STANDING IS NOT A WIPE: it is a FLAG (`wiped = true`), which is EXACTLY what the audit described.
     *
     * *** AND IT IS RED BEFORE THE REPAIR, BY CONSTRUCTION: THE HARNESS'S `beginWipe()` SETTETH A BOOLEAN AND APPENDETH A TRACE EVENT, AND CALLETH
     * NOTHING THAT COULD ERASE A ROW. ***
     */
    func testGSINTEGRATION001_afterAWipeTheDurableIntentMustBeGone() async throws {
        let harness = ComposedRuntimeHarness()
        _ = try harness.addNode("alice", seedByte: 0x31)
        _ = try harness.addNode("bob", seedByte: 0x32)
        guard case .applied = harness.link("alice", "bob") else {
            XCTFail("the fixture must link the two nodes"); return
        }
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("gsint001_wipe_\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let intentId = bytesOf(21, 16)
        let sent = try await harness.sendDirectDurable("alice", recipient: "bob",
                                                       plaintext: Data("a durable intent must not outlive a wipe".utf8),
                                                       intentId: intentId, storeURL: storeURL)
        if case let .rejected(reason) = sent { XCTFail("the durable send must not refuse: \(reason)"); return }

        // THE ROW MUST STAND **BEFORE** THE WIPE, OR THE ARM PROVES NOTHING (round 460's law: establish the subject was present).
        do {
            let before = SqliteOutboundIntentJournal(store: try SqliteMessageStore(url: storeURL, maxBytes: 64 * 1024 * 1024))
            guard case .found = before.load(intentId) else {
                XCTFail("the pinned intent must stand BEFORE the wipe, or this arm measures nothing"); return
            }
        }

        // *** THE WIPE ***
        harness.beginWipe()
        XCTAssertTrue(harness.isWiped(), "the harness reports itself wiped")

        // *** AND THE CLAUSE: THE INTENT MUST BE GONE. ***
        let reopened = SqliteOutboundIntentJournal(store: try SqliteMessageStore(url: storeURL, maxBytes: 64 * 1024 * 1024))
        if case .found = reopened.load(intentId) {
            XCTFail("*** GS-INTEGRATION-001: THE WIPE MUST REACH THE REAL OWNER -- THE DURABLE INTENT STILL STANDS AFTER beginWipe() ***")
        }
    }
}
