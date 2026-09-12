import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

// T37 readiness court (iOS isle) -- the twin of ReadinessT37Test.kt.
//
// Persist received inbox messages before generating recipient ACKs, using the
// authenticated TrustedPeer only as immediate-hop identity (section 14). One
// reviewed scenario per witness; every assertion is positive and expected;
// the observable counters on the injected seams and the paired-store census
// are the oracles that make the five named falsifications killable.
//
// HOST CRYPTO PROPERTY (the T83 finding, binding on this isle): the host
// Ed25519 layer signs RANDOMIZED -- same seed, same preimage, distinct
// signature bytes across builds. The section-14 laws are carried here by the
// VERIFIER and the DIGEST forms: the stored row's key equals the SHA256 over
// the row's OWN stored parts, re-admission of the very stored bytes
// classifies Duplicate, and the frozen Ed25519AckAuthenticator accepts the
// stored reply under the pinned key. Duplicate regeneration compares the
// STORED-row read-back bytes (firstAck vs secondAck) -- lawful across both
// isles, because both come from the one durable row; no witness here asserts
// byte-identity against a directly built re-signature (that leg stands only
// on the deterministic android isle).
final class ReadinessT37Tests: XCTestCase {

    private let t37FixedDay: Int64 = 12345
    private let t37Created: Int64 = 1700000200
    private let t37Clock: Int64 = 1700000201

    // ------------------------------------------------------------------ fakes

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage[tag] = nil }
    }

    private struct Local { let id: MeshIdentity; let seed: Data; let xPriv: Data }

    private func newLocal(_ seedByte: UInt8, _ xByte: UInt8) throws -> Local {
        let edSeed = Data(repeating: seedByte, count: 32)
        let xPriv = Data(repeating: xByte, count: 32)
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: edSeed, x25519PrivateKey: xPriv)
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        let id = try MeshIdentity.loadFromKeychain(keychain: kc)
        return Local(id: id, seed: edSeed, xPriv: xPriv)
    }

    private final class KeyTable: RecipientKeyResolver, @unchecked Sendable {
        private var table: [Data: Data] = [:]
        var queries: Int = 0
        func put(_ nodeId: Data, _ key: Data) { table[Data(nodeId)] = Data(key) }
        func publicSigningKey(forNodeId nodeId: Data) -> Data? {
            queries += 1
            if let v = table[Data(nodeId)] { return Data(v) }
            return nil
        }
    }

    private final class TestSigner: AckSignerSeam, @unchecked Sendable {
        private let local: Local?
        var asks: Int = 0
        var pinnedGeneration: Int64 = Int64.max
        init(_ local: Local?) { self.local = local }
        var nodeId: Data? { local.map { Data($0.id.nodeId) } }
        func generation() -> Int64 { pinnedGeneration }
        func signingSeed(msgId: Data, recipientNodeId: Data) throws -> Data? {
            asks += 1
            if let s = local?.seed { return Data(s) }
            return nil
        }
    }

    /// The never-exercised delivery repository of the T24 integration recipe.
    private final class DeadDeliveryRepository: DeliveryRepository, @unchecked Sendable {
        func get(_ msgId: Data) -> DeliveryLookup { fatalError("unused by these witnesses") }
        func enqueue(_ msgId: Data, ackMode: AckMode, expectedRecipient: Data?) -> EnqueueResult {
            fatalError("unused by these witnesses")
        }
        func transition(_ msgId: Data, _ transition: DeliveryTransition) -> TransitionResult {
            fatalError("unused by these witnesses")
        }
        func acknowledgeBoundAndRetire(_ msgId: Data, expectedRecipient: Data) -> AckResult {
            fatalError("unused by these witnesses")
        }
        func clear(_ msgId: Data) -> ClearResult { fatalError("unused by these witnesses") }
    }

    private final class RevokingPolicy: RecipientSenderTrustPolicy, @unchecked Sendable {
        private let rogue: Data
        init(_ rogue: Data) { self.rogue = rogue }
        func admits(senderNodeId: Data) -> Bool { senderNodeId != rogue }
    }

    private struct Rig37 {
        let me: Local
        let base: InMemoryMessageStore
        let keys: KeyTable
        let signer: TestSigner
        let auth: Ed25519AckAuthenticator
        let repo: RecipientInboxRepository
    }

    private func rig(_ tag: Int, policy: RecipientSenderTrustPolicy? = nil) throws -> Rig37 {
        let me = try newLocal(UInt8((tag & 0x7F) + 1), 0x22)
        let base = InMemoryMessageStore()
        let keys = KeyTable()
        keys.put(me.id.nodeId, me.id.signingPublicKey) // own key resolvable: the self-check walks this pin
        let signer = TestSigner(me)
        let repo = RecipientInboxRepository(
            router: Router(selfNodeId: me.id.nodeId),
            ourNodeId: me.id.nodeId,
            localDhPrivate: { Data(me.xPriv) },
            signer: signer,
            resolver: keys,
            authenticator: Ed25519AckAuthenticator(resolver: keys),
            pairedStore: base.ackStore,
            commitInbound: { f, rf, lr, g, l, t, fl in
                base.commitInboundWithObligationAtWithFault(
                    f, receivedFrom: rf, localRecipientNodeId: lr,
                    identityGeneration: g, obligationLifetimeMs: l,
                    receivedAt: t, fault: fl)
            },
            trustPolicy: policy ?? AdmitAllSenders(),
            clockSeconds: { self.t37Clock },
            epochDay: { self.t37FixedDay },
            identityGeneration: { 7 }
        )
        return Rig37(me: me, base: base, keys: keys, signer: signer,
                     auth: Ed25519AckAuthenticator(resolver: keys), repo: repo)
    }

    // injective builders: four verbatim seed bytes + fixed salt tail (T83 law)
    private func nodeOf(_ seed: Int, _ salt: Int) -> Data {
        Data((0..<16).map { i -> UInt8 in
            if i < 4 { return UInt8((seed >> (8 * (3 - i))) & 0xFF) }
            return UInt8((i * 17 + salt * 3 + 1) & 0xFF)
        })
    }

    private func nonceOf(_ seed: Int) -> Data {
        Data((0..<16).map { i -> UInt8 in
            let a = i * 31
            let b = seed * 5 + 3
            return UInt8((a + b) & 0xFF)
        })
    }

    private func hintOf(_ nodeId: Data) -> Data { Data(nodeId.prefix(4)) }

    private func rebuilt(_ frame: FrameV2, msgId: Data? = nil,
                         routingTag: Data? = nil) -> FrameV2 {
        FrameV2(type: frame.type, msgId: msgId ?? frame.msgId,
                routingTag: routingTag ?? frame.routingTag,
                ttl: frame.ttl, hopCount: frame.hopCount,
                flags: frame.flags, payload: frame.payload)
    }

    private func signedContainer(_ sender: Local, _ recipientId: Data, _ nonceSeed: Int,
                                 _ createdAt: Int64, _ body: String) throws -> Data {
        try SignedMessageV1.author(
            senderIdentityPriv: sender.seed,
            senderIdentityPub: sender.id.signingPublicKey,
            senderNodeId: sender.id.nodeId,
            recipientNodeId: recipientId,
            messageNonce: nonceOf(nonceSeed),
            createdAtEpochSeconds: createdAt,
            priority: .direct,
            timeQuality: .userConfirmed,
            bodyUtf8: Data(body.utf8)
        )
    }

    /// Author the sealed inbound frame; the court normalizes the public
    /// rotating tag onto the rig's pinned day so the hint census is
    /// deterministic (the tag is transport metadata: msgId and the signature
    /// bind to the container, never to the tag).
    private func inboundFrame(_ r: Rig37, _ sender: Local, _ nonceSeed: Int) async throws -> FrameV2 {
        let container = try signedContainer(sender, r.me.id.nodeId, nonceSeed, t37Created,
                                            "t37-body-\(nonceSeed)")
        let authoring = Router(selfNodeId: sender.id.nodeId)
        let identity = LogicalMessageIdentity.of(createdAtEpochSeconds: t37Created,
                                                 messageNonce: nonceOf(nonceSeed))
        let built = try await authoring.buildSealedMessage(
            plaintext: container,
            recipientNodeId: r.me.id.nodeId,
            recipientStaticPub: r.me.id.staticDhPublicKey,
            identity: identity,
            priority: .direct
        )
        return rebuilt(built, routingTag: SealedSender.routingTag(recipientNodeId: r.me.id.nodeId,
                                                                   epochDay: t37FixedDay))
    }

    private func accept(_ r: Rig37, _ frame: FrameV2, _ hop: Data,
                        _ fault: ((String) throws -> Void)? = nil) throws -> InboxCommitResult {
        try r.repo.acceptVerifiedAndRequireAck(frame, receivedFrom: hop, fault: fault)
    }

    private func ackOf(_ x: InboxCommitResult) -> FrameV2? {
        switch x {
        case .new(ack: let a): return a
        case .duplicate(ack: let a): return a
        case .rejected: return nil
        }
    }

    private func isAccepted(_ x: InboxCommitResult) -> Bool {
        if case .new = x { return true }
        if case .duplicate = x { return true }
        return false
    }

    private func rejectReason(_ x: InboxCommitResult) -> RejectionReason? {
        if case .rejected(reason: let reason, detail: _) = x { return reason }
        return nil
    }

    // ------------------------------------------------------------------ witnesses

    /** W1 -- the card's integration scenario through the composition root:
     *  author/seal -> trusted link (handleInboundFrame) -> recipient inbox ->
     *  signed ACK on the bounded outbox. The relay decision of the router
     *  stands untouched beside the local destination attempt. */
    func testActualDirectedSendThroughBothAdaptersToDurableInboxAndSignedAck() async throws {
        let r = try rig(201)
        let sender = try newLocal(0x31, 0x41)
        r.keys.put(sender.id.nodeId, sender.id.signingPublicKey)
        let node = MeshNode(
            identity: r.me.id,
            store: r.base,
            deliveryTracker: DeliveryTracker(
                repo: DeadDeliveryRepository(),
                authenticator: Ed25519AckAuthenticator(resolver: UnresolvedRecipientKeyResolver()))
        )
        node.recipientInbox = r.repo
        let frame = try await inboundFrame(r, sender, 21)
        let hop = nodeOf(0x5E17, 0x77) // the immediate-hop trusted peer: not the sender
        let relayed = node.handleInboundFrame(frame, receivedFrom: hop)
        XCTAssertTrue(relayed, "the relay decision stands: the frame was novel")
        let queued = node.drainAckOutboxForLink(4)
        XCTAssertEqual(queued.count, 1, "exactly one canonical ACK queued for the link")
        guard queued.count == 1 else { XCTFail("exactly one queued answer is required to inspect"); return }
        let ack = queued[0]
        XCTAssertEqual(ack.msgId, frame.msgId, "the answer names the original msg")
        XCTAssertEqual(ack.payload.count, 80, "the payload is signature64||recipient16")
        XCTAssertEqual(Int(ack.ttl), 12, "the TTL is the production constant")
        XCTAssertEqual(r.base.allHeldMsgIds().count, 1, "one inbox row")
        XCTAssertEqual(r.base.ackStore.countFrames(), 1, "one ack row")
        XCTAssertEqual(r.base.ackStore.countObligations(), 0, "the obligation drained")
        XCTAssertTrue(r.auth.verify(originalMsgId: frame.msgId, expectedRecipientNodeId: r.me.id.nodeId,
                                    ackFrame: ack),
                      "the queued answer authenticates under the pinned key")
        let census = r.repo.census()
        XCTAssertEqual(census.committedNew + census.committedDuplicate, 1, "one admission counted")
        XCTAssertEqual(census.acksIssued, 1, "one ACK issued")
        XCTAssertEqual(census.acksRefusedQuota + census.acksRefusedKey + census.acksRefusedSelfVerify, 0,
                       "no refusal counted")
        let second = node.drainAckOutboxForLink(4)
        XCTAssertEqual(second.count, 0, "the outbox drained dry")
    }

    /** W2 -- duplicate valid delivery: no duplicate inbox content; the SAME ACK
     *  returned. The signer is asked EXACTLY once across both accepts: the
     *  second answer is read from the stored row, never re-signed. */
    func testDuplicateValidDeliveryRegeneratesSameAckWithoutDuplicateInbox() async throws {
        let r = try rig(202)
        let sender = try newLocal(0x32, 0x42)
        r.keys.put(sender.id.nodeId, sender.id.signingPublicKey)
        let frame = try await inboundFrame(r, sender, 22)
        let hop = nodeOf(0x60, 0x11)
        let first = try accept(r, frame, hop)
        XCTAssertTrue(isAccepted(first), "the first delivery is accepted")
        guard let firstAck = ackOf(first) else { XCTFail("the first delivery carries the canonical ACK"); return }
        XCTAssertEqual(r.signer.asks, 1, "the signer was asked once")
        let second = try accept(r, frame, hop)
        XCTAssertTrue(isDuplicate(second), "the duplicate is admitted as already held")
        guard let secondAck = ackOf(second) else { XCTFail("the duplicate still carries an ACK"); return }
        XCTAssertEqual(firstAck.encode(), secondAck.encode(),
                       "the very bytes first filed are handed out again -- read back from the stored row, not re-signed")
        XCTAssertEqual(r.signer.asks, 1, "the signer was NOT asked again: stored row, not re-signature")
        XCTAssertEqual(r.base.allHeldMsgIds().count, 1, "one inbox row only")
        XCTAssertEqual(r.base.ackStore.countFrames(), 1, "one ack row only")
        XCTAssertEqual(r.base.ackStore.countObligations(), 0, "obligations stay drained")
    }

    private func isDuplicate(_ x: InboxCommitResult) -> Bool {
        if case .duplicate = x { return true }
        return false
    }

    /** W3 -- bad signature: refused at the frozen verifier BEFORE admission;
     *  every table stands at zero. */
    func testBadSignatureRefusedBeforeAnyAdmission() async throws {
        let r = try rig(203)
        let sender = try newLocal(0x33, 0x43)
        r.keys.put(sender.id.nodeId, sender.id.signingPublicKey)
        var container = [UInt8](try signedContainer(sender, r.me.id.nodeId, 23, t37Created, "t37-tampered"))
        container[container.count - 1] = container[container.count - 1] ^ 0x01
        let authoring = Router(selfNodeId: sender.id.nodeId)
        let identity = LogicalMessageIdentity.of(createdAtEpochSeconds: t37Created, messageNonce: nonceOf(23))
        let built = try await authoring.buildSealedMessage(
            plaintext: Data(container),
            recipientNodeId: r.me.id.nodeId,
            recipientStaticPub: r.me.id.staticDhPublicKey,
            identity: identity,
            priority: .direct
        )
        let frame = rebuilt(built, routingTag: SealedSender.routingTag(recipientNodeId: r.me.id.nodeId,
                                                                         epochDay: t37FixedDay))
        let before = r.repo.census()
        let result = try accept(r, frame, nodeOf(0x61, 0x02))
        XCTAssertEqual(rejectReason(result), .verificationFailed,
                       "the forged signature is refused at the verifier, not at the envelope")
        let after = r.repo.census()
        XCTAssertEqual(after.verificationRejections - before.verificationRejections, 1,
                       "the verifier rejected exactly one")
        XCTAssertEqual(after.committedNew + after.committedDuplicate, 0, "no admission counted")
        XCTAssertEqual(after.acksIssued, before.acksIssued, "no ACK issued")
        XCTAssertEqual(r.base.ackStore.countFrames(), 0, "nothing was filed")
        XCTAssertEqual(r.base.ackStore.countObligations(), 0, "no obligation stands")
        XCTAssertEqual(r.base.allHeldMsgIds().count, 0, "no inbox row")
    }

    /** W4 -- bad msgID: the framed id no longer matches the frozen derivation;
     *  the closed ladder of the core names it. The hint still counted a hit. */
    func testBadMsgIdRefusedByTheClosedLadder() async throws {
        let r = try rig(204)
        let sender = try newLocal(0x34, 0x44)
        r.keys.put(sender.id.nodeId, sender.id.signingPublicKey)
        let honest = try await inboundFrame(r, sender, 24)
        var flipped = [UInt8](honest.msgId)
        flipped[0] = flipped[0] ^ 0x01
        let frame = rebuilt(honest, msgId: Data(flipped))
        let before = r.repo.census()
        let result = try accept(r, frame, nodeOf(0x62, 0x03))
        XCTAssertEqual(rejectReason(result), .messageIdMismatch,
                       "the envelope's id disagrees with the frozen derivation")
        let after = r.repo.census()
        XCTAssertEqual(after.hintHits - before.hintHits, 1, "the tag still counted as a hint")
        XCTAssertEqual(after.committedNew + after.committedDuplicate, 0, "yet nothing was admitted")
        XCTAssertEqual(r.base.ackStore.countFrames(), 0, "nothing filed")
        XCTAssertEqual(r.base.allHeldMsgIds().count, 0, "no inbox row")
    }

    /** W5 -- wrong recipient: a validly signed container naming ANOTHER node is
     *  the wrong recipient; the frozen binding law refuses before any write. */
    func testWrongEmbeddedRecipientRefusedByBindingLaw() async throws {
        let r = try rig(205)
        let sender = try newLocal(0x35, 0x45)
        r.keys.put(sender.id.nodeId, sender.id.signingPublicKey)
        let other = try newLocal(0x71, 0x72) // the container names this other node instead
        let container = try signedContainer(sender, other.id.nodeId, 25, t37Created, "t37-other")
        let authoring = Router(selfNodeId: sender.id.nodeId)
        let identity = LogicalMessageIdentity.of(createdAtEpochSeconds: t37Created, messageNonce: nonceOf(25))
        let built = try await authoring.buildSealedMessage(
            plaintext: container,
            recipientNodeId: r.me.id.nodeId, // the envelope still rotates under our tag
            recipientStaticPub: r.me.id.staticDhPublicKey, // sealed under our DH: the unseal succeeds
            identity: identity,
            priority: .direct
        )
        let frame = rebuilt(built, routingTag: SealedSender.routingTag(recipientNodeId: r.me.id.nodeId,
                                                                         epochDay: t37FixedDay))
        let result = try accept(r, frame, nodeOf(0x63, 0x04))
        XCTAssertEqual(rejectReason(result), .verificationFailed, "the foreign recipient is refused")
        if case .rejected(reason: _, detail: let detail) = result {
            XCTAssertEqual(detail,
                           "embedded recipientNodeId differs from the intended local recipient",
                           "the refusal names the recipient binding")
        } else {
            XCTFail("the binding law must answer rejected")
        }
        XCTAssertEqual(r.base.ackStore.countFrames(), 0, "nothing filed")
        XCTAssertEqual(r.base.allHeldMsgIds().count, 0, "no inbox row")
    }

    /** W6 -- revoked sender policy: proof stands, yet policy refuses; the
     *  verifier is not even reached for a refusal (policy is not proof). */
    func testRevokedSenderPolicyRefusesWithoutTouchingTables() async throws {
        let sender = try newLocal(0x36, 0x46)
        let r = try rig(206, policy: RevokingPolicy(sender.id.nodeId))
        r.keys.put(sender.id.nodeId, sender.id.signingPublicKey)
        let frame = try await inboundFrame(r, sender, 26)
        let before = r.repo.census()
        let result = try accept(r, frame, nodeOf(0x64, 0x05))
        XCTAssertEqual(rejectReason(result), .senderRevoked, "the revoked sender is refused by policy")
        let after = r.repo.census()
        XCTAssertEqual(after.policyRejections - before.policyRejections, 1, "policy refused exactly one")
        XCTAssertEqual(after.verificationRejections - before.verificationRejections, 0,
                       "the cryptographic verifier was not consulted for a refusal")
        XCTAssertEqual(r.base.ackStore.countFrames(), 0, "nothing filed")
        XCTAssertEqual(r.base.ackStore.countObligations(), 0, "no obligation stands")
        XCTAssertEqual(r.base.allHeldMsgIds().count, 0, "no inbox row")
    }

    /** W7 -- disk failure: the whole inbox transaction rolls back; no ACK and
     *  no claimed local acceptance (the card's named negative). */
    func testDiskFailureYieldsNeitherAckNorClaimedAcceptance() async throws {
        let r = try rig(207)
        let sender = try newLocal(0x37, 0x47)
        r.keys.put(sender.id.nodeId, sender.id.signingPublicKey)
        let frame = try await inboundFrame(r, sender, 27)
        var raised = false
        let fault: (String) throws -> Void = { point in
            if point == "obligation" {
                raised = true
                throw NSError(domain: "ReadinessT37", code: 7)
            }
        }
        let result = try accept(r, frame, nodeOf(0x65, 0x06), fault)
        XCTAssertTrue(raised, "the fault seam was reached")
        XCTAssertEqual(rejectReason(result), .storageFailure,
                       "storage failure, not a rejection of the sender")
        let census = r.repo.census()
        XCTAssertEqual(census.acksIssued, 0, "no ACK was issued")
        XCTAssertEqual(r.signer.asks, 0, "the signer never stirred")
        XCTAssertEqual(r.base.allHeldMsgIds().count, 0,
                       "the whole transaction rolled back: no inbox row")
        XCTAssertEqual(r.base.ackStore.countObligations(), 0, "no obligation survived")
        XCTAssertEqual(r.base.ackStore.countFrames(), 0, "no frame filed")
        // and the authority recovers: a later honest delivery still completes
        let next = try await inboundFrame(r, sender, 127)
        let again = try accept(r, next, nodeOf(0x65, 0x06))
        XCTAssertTrue(isAccepted(again), "a later delivery still completes")
    }

    /** W8 -- process kill after commit before ACK: the dying run throws at the
     *  signing seam; the durable row and the pending obligation survive; a
     *  fresh run over the SAME authorities regenerates the one true ACK. */
    func testProcessKillAfterCommitBeforeAckRegeneratesExactlyOnce() async throws {
        let r = try rig(208)
        let sender = try newLocal(0x38, 0x48)
        r.keys.put(sender.id.nodeId, sender.id.signingPublicKey)
        let frame = try await inboundFrame(r, sender, 28)
        let hop = nodeOf(0x66, 0x07)
        var hitSigning = false
        var died = false
        let crash: (String) throws -> Void = { point in
            if point == "signing" {
                hitSigning = true
                throw NSError(domain: "ReadinessT37", code: 8)
            }
        }
        do {
            _ = try accept(r, frame, hop, crash)
        } catch {
            died = true
        }
        XCTAssertTrue(hitSigning, "the dying run reached the signing seam")
        XCTAssertTrue(died, "the death propagated out of the receiver")
        XCTAssertEqual(r.base.allHeldMsgIds().count, 1, "the committed inbox row survived the kill")
        if case .found(let ob) = r.base.ackStore.lookupObligation(frame.msgId, recipientNodeId: r.me.id.nodeId) {
            XCTAssertEqual(ob.state, .pending, "the obligation stands pending, retryable")
        } else {
            XCTFail("the obligation must have survived the commit")
        }
        XCTAssertEqual(r.base.ackStore.countFrames(), 0, "no ACK row was filed by the dying run")
        // revival: the same frame over the same authorities, clean this time
        let revived = try accept(r, frame, hop)
        XCTAssertTrue(isAccepted(revived), "the revived run completes")
        guard let ack = ackOf(revived) else { XCTFail("the revived run issues the ACK"); return }
        XCTAssertEqual(r.signer.asks, 1, "the signer was asked exactly once in total")
        XCTAssertEqual(r.base.ackStore.countFrames(), 1, "one frame filed")
        XCTAssertEqual(r.base.ackStore.countObligations(), 0, "the obligation retired with it")
        XCTAssertTrue(
            r.auth.verify(originalMsgId: frame.msgId, expectedRecipientNodeId: r.me.id.nodeId,
                          ackFrame: ack),
            "the regenerated answer authenticates under the pinned key -- the one true canonical row"
        )
    }

    /** W9 -- the rotating tag is a hint, not identity: a stale tag outside the
     *  window still delivers (clock skew is not authentication failure); a
     *  matching tag over a forged signature is still refused BY THE VERIFIER. */
    func testStaleTagStillDeliversAndMatchedTagAdmitsNothingAlone() async throws {
        // leg one: the stale (out-of-window) tag is charged and delivered
        let r1 = try rig(209)
        let s1 = try newLocal(0x39, 0x49)
        r1.keys.put(s1.id.nodeId, s1.id.signingPublicKey)
        let staleBase = try await inboundFrame(r1, s1, 29)
        let stale = rebuilt(staleBase, routingTag: SealedSender.routingTag(
            recipientNodeId: r1.me.id.nodeId, epochDay: t37FixedDay - 3))
        let beforeOne = r1.repo.census()
        let resOne = try accept(r1, stale, nodeOf(0x67, 0x08))
        XCTAssertTrue(isAccepted(resOne), "the stale-tagged frame still stands accepted")
        let afterOne = r1.repo.census()
        XCTAssertEqual(afterOne.hintMissesUnsealed - beforeOne.hintMissesUnsealed, 1,
                       "the miss was charged to the hint census")
        XCTAssertEqual(afterOne.unsealedAccepted - beforeOne.unsealedAccepted, 1,
                       "and the frame was unsealed notwithstanding")
        // leg two: a matched tag over a forged signature -- the verifier refuses
        let r2 = try rig(1209)
        let s2 = try newLocal(0x3A, 0x4A)
        r2.keys.put(s2.id.nodeId, s2.id.signingPublicKey)
        var forgedBytes = [UInt8](try signedContainer(s2, r2.me.id.nodeId, 129, t37Created,
                                                     "t37-forged-under-honest-tag"))
        forgedBytes[forgedBytes.count - 10] = forgedBytes[forgedBytes.count - 10] ^ 0x40
        let authoring = Router(selfNodeId: s2.id.nodeId)
        let identity = LogicalMessageIdentity.of(createdAtEpochSeconds: t37Created, messageNonce: nonceOf(129))
        let built = try await authoring.buildSealedMessage(
            plaintext: Data(forgedBytes),
            recipientNodeId: r2.me.id.nodeId,
            recipientStaticPub: r2.me.id.staticDhPublicKey,
            identity: identity,
            priority: .direct
        )
        let forged = rebuilt(built, routingTag: SealedSender.routingTag(
            recipientNodeId: r2.me.id.nodeId, epochDay: t37FixedDay)) // the honest, MATCHING tag
        let beforeTwo = r2.repo.census()
        let resTwo = try accept(r2, forged, nodeOf(0x68, 0x09))
        XCTAssertEqual(rejectReason(resTwo), .verificationFailed,
                       "the forgery is refused by the verifier, not the tag")
        let afterTwo = r2.repo.census()
        XCTAssertEqual(afterTwo.hintHits - beforeTwo.hintHits, 1,
                       "the tag matched, yet the match admitted nothing")
        XCTAssertEqual(r2.base.ackStore.countFrames(), 0, "nothing filed")
    }

    /** W10 -- the immediate hop is not the sender: one message delivered via
     *  two distinct hop tokens is admitted once, duplicated honestly, and the
     *  stored row keeps the FIRST filing's receipt (non-replenishing). */
    func testImmediateHopIsNotTheSenderAndReceiptStands() async throws {
        let r = try rig(210)
        let sender = try newLocal(0x3B, 0x4B)
        r.keys.put(sender.id.nodeId, sender.id.signingPublicKey)
        let frame = try await inboundFrame(r, sender, 30)
        let hopA = nodeOf(0x70A, 0x21)
        let hopB = nodeOf(0x70B, 0x22)
        XCTAssertTrue(hopA != hopB, "the hops are distinct tokens")
        XCTAssertTrue(hopA != sender.id.nodeId, "neither hop is the sender")
        XCTAssertTrue(hopB != sender.id.nodeId, "neither hop is the sender")
        let first = try accept(r, frame, hopA)
        XCTAssertTrue(isAccepted(first), "the first delivery is accepted")
        let second = try accept(r, frame, hopB)
        XCTAssertTrue(isDuplicate(second), "the second delivery via a different hop duplicates honestly")
        XCTAssertEqual(r.signer.asks, 1, "no re-signature across hops")
        switch try r.base.ackStore.candidatesForPair(frame.msgId, recipientNodeId: r.me.id.nodeId,
                                                     bound: Int32(4)) {
        case .records(let rows):
            XCTAssertEqual(rows.count, 1, "exactly one filed row")
            guard rows.count >= 1 else { XCTFail("a filed row is required to inspect"); return }
            let row = rows[0]
            if let rf = row.receivedFrom {
                XCTAssertEqual(rf, hopA,
                               "the row keeps the first filing's receipt: later hops do not replenish the durable row")
            } else {
                XCTFail("the receipt metadata must stand filed")
            }
            XCTAssertEqual(row.verificationClass, .verifiedRecipiant, "the row is recipient-verified")
            XCTAssertEqual(row.recipientNodeId, r.me.id.nodeId, "the row names us as its recipient")
        default:
            XCTFail("the pair census must answer with records")
        }
        let census = r.repo.census()
        XCTAssertEqual(census.acksRefusedKey, 0, "the hop token never entered any identity decision")
    }

    /** W11 -- canonical ACK bytes end to end through the production entry:
     *  type ACK, 80-byte payload = signature64||recipient16, tag the recipient
     *  hint, ttl 12 (the section-14 production constant), hop 0, flags 0; the
     *  frozen authenticator accepts the stored row; the message and its ACK
     *  coexist in the two namespaces under one msg id. */
    func testCanonicalAckBytesEndToEndThroughTheProductionEntry() async throws {
        let r = try rig(211)
        let sender = try newLocal(0x3C, 0x4C)
        r.keys.put(sender.id.nodeId, sender.id.signingPublicKey)
        let frame = try await inboundFrame(r, sender, 31)
        let result = try accept(r, frame, nodeOf(0x69, 0x0A))
        guard let ack = ackOf(result) else { XCTFail("the production entry issued the ACK"); return }
        XCTAssertEqual(ack.type, .ack, "type ACK")
        XCTAssertEqual(ack.payload.count, 80, "payload is signature64||recipient16")
        XCTAssertEqual(Data(ack.payload.dropFirst(64)), r.me.id.nodeId, "the tail names the recipient")
        XCTAssertEqual(ack.msgId, frame.msgId, "the id is the original message's")
        XCTAssertEqual(ack.routingTag, hintOf(r.me.id.nodeId), "the tag is the canonical recipient hint")
        XCTAssertEqual(Int(ack.ttl), 12, "ttl is the production constant")
        XCTAssertEqual(Int(ack.hopCount), 0, "hop stands at zero")
        XCTAssertEqual(Int(ack.flags), 0, "flags stay canonical")
        switch try r.base.ackStore.candidatesForPair(frame.msgId, recipientNodeId: r.me.id.nodeId,
                                                     bound: Int32(4)) {
        case .records(let rows):
            XCTAssertEqual(rows.count, 1, "one row filed")
            guard rows.count >= 1 else { XCTFail("a filed row is required to inspect"); return }
            let row = rows[0]
            guard let stored = FrameV2.decode(row.encodedFrame) else {
                XCTFail("the stored encoding decodes"); return
            }
            XCTAssertTrue(r.auth.verify(originalMsgId: frame.msgId, expectedRecipientNodeId: r.me.id.nodeId,
                                       ackFrame: stored),
                          "the frozen authenticator accepts the stored row")
            guard let digest = AckCacheKey.compute(msgId: row.msgId, recipientNodeId: row.recipientNodeId,
                                                  signature: row.signature) else {
                XCTFail("the cache key is computable"); return
            }
            XCTAssertEqual(row.ackKey, digest,
                           "the key is the honest digest of the row's own parts")
        default:
            XCTFail("a row must stand filed")
        }
        XCTAssertEqual(r.base.allHeldMsgIds().count, 1, "the message stands held")
        XCTAssertEqual(r.base.ackStore.countFrames(), 1, "the answer lives beside it")
        let held = r.base.allHeldOrderedByPriority()
        XCTAssertEqual(held.count, 1, "one held frame")
        guard held.count >= 1 else { XCTFail("a held frame is required to inspect"); return }
        XCTAssertEqual(held[0].encode(), frame.encode(), "the held row is the original bytes")
    }
}
