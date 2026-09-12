// T83 readiness court (iOS isle) -- the twin of ReadinessT83Test.kt.
//
// Add ack_obligations and ack_frames namespaces as section14 specifies. One reviewed
// scenario per witness; every assertion is positive and expected (a present side
// effect is captured, an absent one is CAPTURED as absence through a typed .absent /
// zero-count observation); the observable counters on the injected fakes and the
// paired-store census are the oracles that make the five named falsifications
// killable (an ACK stored into the message namespace, the obligation omitted from
// the inbox transaction, candidates deduped across distinct signatures, the pair
// quota removed, the retirement unbound from the frame transaction).
import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

final class ReadinessT83Tests: XCTestCase {

    // ------------------------------------------------------------------ fakes (deterministic; counters observable)

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
        func dropAll() { table.removeAll() }
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

    private struct Rig {
        let me: Local
        let originId: Data
        let store: InMemoryMessageStore
        let router: Router
        let keys: KeyTable
        let authenticator: Ed25519AckAuthenticator
    }

    private func rig(_ tag: Int) throws -> Rig {
        let me = try newLocal(UInt8((tag & 0x7F) + 1), 0x22)
        let origin = nodeOf(tag, 0x11)
        let base = InMemoryMessageStore()
        let router = Router(selfNodeId: origin)
        let keys = KeyTable()
        return Rig(me: me, originId: origin, store: base, router: router,
                   keys: keys, authenticator: Ed25519AckAuthenticator(resolver: keys))
    }

    // the first four bytes carry the seed injectively (no mod-256 collapse);
    // the tail is layout-fixed per salt, so pairs and probes never collide
    private func nodeOf(_ seed: Int, _ salt: Int) -> Data {
        Data((0..<16).map { i -> UInt8 in
            if i < 4 { return UInt8((seed >> (8 * (3 - i))) & 0xFF) }
            return UInt8((i * 17 + salt * 3 + 1) & 0xFF)
        })
    }

    private func nonceOf(_ seed: Int) -> Data {
        Data((0..<16).map { UInt8(($0 * 31 + seed * 5 + 3) & 0xFF) })
    }

    private func hintOf(_ nodeId: Data) -> Data { Data(nodeId.prefix(4)) }

    private func inboxFrame(_ r: Rig, _ tag: Int) async throws -> FrameV2 {
        let identity = LogicalMessageIdentity.of(createdAtEpochSeconds: 1700000200, messageNonce: Data(nonceOf(tag)))
        return try await r.router.buildSealedMessage(
            plaintext: Data("t83-inbox-\(tag)".utf8),
            recipientNodeId: r.me.id.nodeId,
            recipientStaticPub: r.me.id.staticDhPublicKey,
            identity: identity,
            priority: .direct
        )
    }

    private func commitInbound(_ r: Rig, _ frame: FrameV2, _ generation: Int64,
                               _ lifetimeMs: Int64) -> InboundCommitResult {
        r.store.commitInboundWithObligationAtWithFault(
            frame, receivedFrom: r.originId, localRecipientNodeId: r.me.id.nodeId,
            identityGeneration: generation, obligationLifetimeMs: lifetimeMs,
            receivedAt: 1700000201, fault: nil
        )
    }

    private func driverOf(_ r: Rig, _ signer: TestSigner) -> AckObligationDriver {
        AckObligationDriver(store: r.store.ackStore, signer: signer,
                            authenticator: r.authenticator, resolver: r.keys)
    }

    private func isCommitted(_ c: InboundCommitResult) -> Bool {
        if case .committed = c { return true }
        return false
    }

    // ------------------------------------------------------------------ witnesses

    func testCrashAfterInboxCommitBeforeSigningResumesDeterministically() async throws {
        let r = try rig(101)
        r.keys.put(r.me.id.nodeId, r.me.id.signingPublicKey)
        let frame = try await inboxFrame(r, 11)
        XCTAssertTrue(isCommitted(commitInbound(r, frame, 7, 60000)), "the inbox commit reports itself committed with a fresh obligation")
        // crash at the signing boundary: the worker dies before it holds the pen
        let dying = driverOf(r, TestSigner(r.me))
        var raised = false
        do {
            try dying.runPendingOnce(8) { point in
                if point == "signing" { throw NSError(domain: "ReadinessT83", code: 1) }
            }
            raised = false
        } catch {
            raised = true
        }
        XCTAssertTrue(raised, "the seam death is observable")
        XCTAssertEqual(r.store.ackStore.countFrames(), 0, "no frame half-acknowledged survives the crash")
        if case .found(let pending) = r.store.ackStore.lookupObligation(frame.msgId, recipientNodeId: r.me.id.nodeId) {
            XCTAssertEqual(pending.state, .pending, "the obligation endures as pending (retryable)")
        } else {
            XCTFail("the durable obligation must survive the crash")
        }
        // restart with a fresh worker over the same durable state
        let revived = driverOf(r, TestSigner(r.me))
        let report = try revived.runPendingOnce(8)
        XCTAssertEqual(report.scanned, 1, "the resumed scan finds the one pending obligation")
        XCTAssertEqual(report.signed, 1, "the resumed worker signs once")
        XCTAssertEqual(report.retired, 1, "and retires once")
        XCTAssertEqual(report.keyUnavailable + report.storageFailures + report.idempotent + report.refusedQuota, 0, "claiming nothing else")
        XCTAssertEqual(r.store.ackStore.countObligations(), 0, "the obligation table drains empty")
        // the resumed outcome is byte-identical to the canonical one built directly
        // the survivor is exactly one row, keyed by the honest digest of its own
        // stored parts, and authenticating over the frozen wire
        guard case .records(let rows) = try r.store.ackStore.candidatesForPair(frame.msgId, recipientNodeId: r.me.id.nodeId, bound: 8), rows.count == 1 else {
            XCTFail("exactly one canonical row must survive the restart"); return
        }
        let got = rows[0]
        guard let key = AckCacheKey.compute(msgId: got.msgId, recipientNodeId: got.recipientNodeId,
                                            signature: got.signature) else {
            XCTFail("the local cache key must be computable"); return
        }
        XCTAssertEqual(key, got.ackKey, "the stored key is the digest of the stored parts")
        guard let decoded = FrameV2.decode(got.encodedFrame) else {
            XCTFail("the stored encoding must decode"); return
        }
        XCTAssertEqual(decoded.payload.count, 80, "the canonical payload keeps its shape")
        XCTAssertTrue(r.authenticator.verify(originalMsgId: frame.msgId, expectedRecipientNodeId: r.me.id.nodeId,
                                             ackFrame: decoded),
                      "the resumed reply authenticates over the frozen wire")
    }

    func testSigningKeyUnavailableLeavesRetryableObligationAndNoClaimedDelivery() async throws {
        let r = try rig(102)
        r.keys.put(r.me.id.nodeId, r.me.id.signingPublicKey)
        let frame = try await inboxFrame(r, 21)
        XCTAssertTrue(isCommitted(commitInbound(r, frame, 7, 60000)), "commit ok")
        let starvingSigner = TestSigner(nil)               // no local identity stands ready
        let starving = driverOf(r, starvingSigner)
        let s1 = try starving.runPendingOnce(8)
        XCTAssertEqual(s1.scanned, 1, "one row scanned")
        XCTAssertEqual(s1.keyUnavailable, 1, "the key could not be had once")
        XCTAssertEqual(s1.signed + s1.retired + s1.storageFailures, 0, "nothing signed")
        XCTAssertEqual(starvingSigner.asks, 0, "no key was even asked for")
        XCTAssertEqual(r.store.ackStore.countFrames(), 0, "the frame namespace stays empty")
        if case .found(let ob) = r.store.ackStore.lookupObligation(frame.msgId, recipientNodeId: r.me.id.nodeId) {
            XCTAssertTrue(ob.state == .pending && ob.remainingLifetimeMs == 60000, "the obligation survives pending and retryable, lifetime untouched")
        } else {
            XCTFail("the obligation must survive the outage")
        }
        let staleSigner = TestSigner(r.me)
        staleSigner.pinnedGeneration = 0                   // older than the accepted pin of seven
        let stale = driverOf(r, staleSigner)
        let s1b = try stale.runPendingOnce(8)
        XCTAssertEqual(s1b.keyUnavailable, 1, "a stale key must not sign")
        XCTAssertEqual(s1b.signed, 0, "and must not claim")
        XCTAssertEqual(r.store.ackStore.countObligations(), 1, "the obligation still waits")
        let healthy = driverOf(r, TestSigner(r.me))
        let s2 = try healthy.runPendingOnce(8)
        XCTAssertEqual(s2.signed, 1, "the retry completes after the outage")
        XCTAssertEqual(s2.retired, 1, "and retires the survivor")
        XCTAssertEqual(r.store.ackStore.countFrames(), 1, "one row in the frame namespace")
    }

    func testMessageAndAckCoexistUnderSameMsgIdDistinctNamespaces() async throws {
        let r = try rig(103)
        r.keys.put(r.me.id.nodeId, r.me.id.signingPublicKey)
        let frame = try await inboxFrame(r, 31)
        XCTAssertTrue(isCommitted(commitInbound(r, frame, 7, 60000)), "commit ok")
        let rep = try driverOf(r, TestSigner(r.me)).runPendingOnce(8)
        XCTAssertEqual(rep.signed, 1, "one signed")
        // the message original still lives, byte-for-byte untouched
        let held = r.store.allHeldOrderedByPriority()
        XCTAssertEqual(held.count, 1, "the held set still carries the one message")
        XCTAssertEqual(frame.encode(), held[0].encode(), "the reply never clobbered the original")
        // the acknowledgement dwells beside it: same msg id, other namespace
        if case .records(let pair) = try r.store.ackStore.candidatesForPair(frame.msgId, recipientNodeId: r.me.id.nodeId, bound: 8) {
            XCTAssertEqual(pair.count, 1, "the pair holds exactly one candidate")
            XCTAssertEqual(frame.msgId, pair[0].msgId, "the ACK names the very same msg id")
            XCTAssertFalse(pair[0].encodedFrame == frame.encode(), "yet the two namespaces are distinct: the stored bytes differ from the original")
        } else {
            XCTFail("the pair scan must succeed")
        }
        XCTAssertEqual(r.store.ackStore.countObligations(), 0, "and the obligation is discharged")
    }

    func testForgedCandidateThenValidSignatureAdmitsBothSlotsDistinguishable() async throws {
        let r = try rig(104)
        let frame = try await inboxFrame(r, 41)
        let genuine = try AckFrame.build(msgId: frame.msgId, recipientSigningPrivKey: r.me.seed,
                                         recipientNodeId: r.me.id.nodeId, routingTag: hintOf(r.me.id.nodeId))
        // one byte flipped inside the signature field: a forgery on the wire
        var tampered = Array(genuine.payload)
        tampered[3] = tampered[3] ^ 0xFF
        let forged = FrameV2(type: genuine.type, msgId: genuine.msgId, routingTag: genuine.routingTag,
                             ttl: genuine.ttl, hopCount: genuine.hopCount, flags: genuine.flags,
                             payload: Data(tampered))
        // an available authenticated recipient key: the forgery is caught BEFORE any write
        r.keys.put(r.me.id.nodeId, r.me.id.signingPublicKey)
        let d = driverOf(r, TestSigner(r.me))
        XCTAssertTrue(d.admitForeignCandidate(forged.encode(), receivedFrom: r.originId) == .refusedKnownInvalid, "invalid signature under an available key is refused")
        XCTAssertEqual(r.store.ackStore.countFrames(), 0, "the refusal stores nothing")
        // and can never suppress the later valid signature
        let acceptance = d.admitForeignCandidate(genuine.encode(), receivedFrom: r.originId)
        if case .stored = acceptance {} else { XCTFail("the valid one must be admitted"); return }
        XCTAssertEqual(r.store.ackStore.countFrames(), 1, "one verified row")
        XCTAssertTrue(0 < r.keys.queries, "the classifier asked the key table")
        // an unknown key relays a copy only as a bounded opaque candidate, never labelled verified
        r.keys.dropAll()
        let alienSeed = Data((0..<32).map { UInt8(($0 * 23 + 9) & 0xFF) })
        let alien = try AckFrame.build(msgId: frame.msgId, recipientSigningPrivKey: alienSeed,
                                       recipientNodeId: r.me.id.nodeId, routingTag: hintOf(r.me.id.nodeId))
        guard case .stored(let opaqueKey) = d.admitForeignCandidate(alien.encode(), receivedFrom: r.originId) else {
            XCTFail("the unknown-key copy must be admitted opaquely"); return
        }
        if case .found(let lk) = r.store.ackStore.lookupByAckKey(opaqueKey) {
            XCTAssertEqual(lk.verificationClass, .opaqueCandidate, "the unknown-key copy is opaque, not verified")
        } else {
            XCTFail("the opaque candidate must be readable back")
        }
        if case .records(let both) = try r.store.ackStore.candidatesForPair(frame.msgId, recipientNodeId: r.me.id.nodeId, bound: 8) {
            XCTAssertEqual(both.count, 2, "verified and opaque coexist as distinct rows")
            var verified = 0
            var opaque = 0
            for rec in both {
                if rec.verificationClass == .verifiedRecipiant { verified += 1 }
                if rec.verificationClass == .opaqueCandidate { opaque += 1 }
            }
            XCTAssertEqual(verified, 1, "exactly one row claims verification")
            XCTAssertEqual(opaque, 1, "exactly one row stays opaque")
        } else {
            XCTFail("the pair scan must succeed")
        }
    }

    func testFourCandidateVariantsBoundedPerPair() async throws {
        let r = try rig(105)
        let frame = try await inboxFrame(r, 51)
        let d = driverOf(r, TestSigner(r.me))
        r.keys.dropAll()   // unknown keys -> all variants enter opaquely and must not dedup each other
        var seen: [Data] = []
        for i in 0..<4 {
            let seed = Data((0..<32).map { UInt8(($0 * 13 + i * 101 + 5) & 0xFF) })
            let v = try AckFrame.build(msgId: frame.msgId, recipientSigningPrivKey: seed,
                                       recipientNodeId: r.me.id.nodeId, routingTag: hintOf(r.me.id.nodeId))
            guard case .stored(let k) = d.admitForeignCandidate(v.encode(), receivedFrom: r.originId) else {
                XCTFail("variant \(i) must be admitted"); return
            }
            seen.append(Data(k))
            XCTAssertEqual(r.store.ackStore.countForPair(frame.msgId, recipientNodeId: r.me.id.nodeId), i + 1, "variant \(i) stands alone so far")
        }
        // the same candidate again: an idempotent Duplicate, not a dedup
        // interference -- re-admit the very bytes the store already holds
        guard case .records(let fetched) = try r.store.ackStore.candidatesForPair(frame.msgId, recipientNodeId: r.me.id.nodeId, bound: 8), fetched.count == 4 else {
            XCTFail("the four variants must be fetchable"); return
        }
        XCTAssertTrue(d.admitForeignCandidate(Data(fetched[0].encodedFrame), receivedFrom: r.originId) == .duplicate,
                      "an identical copy is a Duplicate")
        XCTAssertEqual(r.store.ackStore.countForPair(frame.msgId, recipientNodeId: r.me.id.nodeId), 4, "the pair still holds the four distinct ones")
        // the fifth distinct variant is explicitly refused at the bound
        let fifthSeedBytes: [UInt8] = (0..<32).map { idx in
            let a = idx * 13
            let b = 4 * 101 + 5
            return UInt8((a + b) & 0xFF)
        }
        let fifthSeed = Data(fifthSeedBytes)
        let fifth = try AckFrame.build(msgId: frame.msgId, recipientSigningPrivKey: fifthSeed,
                                       recipientNodeId: r.me.id.nodeId, routingTag: hintOf(r.me.id.nodeId))
        XCTAssertTrue(d.admitForeignCandidate(fifth.encode(), receivedFrom: r.originId) == .refusedQuotaPair, "capacity refuses further custody explicitly")
        XCTAssertEqual(r.store.ackStore.countForPair(frame.msgId, recipientNodeId: r.me.id.nodeId), 4, "and the first four stand untouched")
        XCTAssertEqual(r.store.ackStore.countFrames(), 4, "no other namespace moved")
        // the four keys are pairwise distinct: they do not dedup each other
        for a in 0..<seen.count {
            for b in (a + 1)..<seen.count {
                XCTAssertFalse(seen[a] == seen[b], "distinct signatures yield distinct keys")
            }
        }
    }

    func testGlobalQuotaSaturationRefusesExplicitlyAndWipePreservesOriginals() async throws {
        let r = try rig(106)
        let acks = r.store.ackStore
        var admitted = 0
        for p in 0..<1024 {
            let m = nodeOf(p, 0x21)
            let recip = nodeOf(p, 0x5E)
            for k in 0..<4 {
                let sig = Data((0..<64).map { UInt8(($0 * 7 + p * 3 + k + 1) & 0xFF) })
                guard let key = AckCacheKey.compute(msgId: m, recipientNodeId: recip, signature: sig) else {
                    XCTFail("fixture digest"); return
                }
                let enc = Data((0..<20).map { UInt8(($0 + p + k) & 0xFF) })
                guard let rec = AckFrameRecord.of(ackKey: key, msgId: m, recipientNodeId: recip,
                                                 signature: sig, encodedFrame: enc, receivedFrom: r.originId,
                                                 remainingLifetimeMs: Int64(1000 + k),
                                                 verificationClass: .opaqueCandidate) else {
                    XCTFail("fixture record"); return
                }
                if case .stored = acks.storeCandidate(rec) { admitted += 1 } else { XCTFail("the census fill must admit (\(p),\(k))") }
            }
        }
        XCTAssertEqual(admitted, 4096, "the census reaches the global bound")
        XCTAssertEqual(acks.countFrames(), 4096)
        // one candidate beyond the bound is refused explicitly, never silently dropped
        let mOut = nodeOf(9999, 0x77)
        let rOut = nodeOf(9998, 0x78)
        let sigOut = Data((0..<64).map { UInt8(($0 * 11 + 3) & 0xFF) })
        guard let keyOut = AckCacheKey.compute(msgId: mOut, recipientNodeId: rOut, signature: sigOut) else {
            XCTFail("fixture digest"); return
        }
        let encOut = Data((0..<20).map { UInt8(($0 + 1) & 0xFF) })
        guard let recOut = AckFrameRecord.of(ackKey: keyOut, msgId: mOut, recipientNodeId: rOut,
                                             signature: sigOut, encodedFrame: encOut, receivedFrom: r.originId,
                                             remainingLifetimeMs: 1, verificationClass: .opaqueCandidate) else {
            XCTFail("fixture record"); return
        }
        XCTAssertTrue(acks.storeCandidate(recOut) == .refusedQuotaGlobal, "the shared quota refuses the next pair explicitly")
        XCTAssertEqual(acks.countFrames(), 4096, "the bound stands")
        // first put one message through the very inbox, then wipe the ACK namespace:
        // the quota-governed wipe must not touch the message originals
        r.keys.put(r.me.id.nodeId, r.me.id.signingPublicKey)
        let frame = try await inboxFrame(r, 61)
        XCTAssertTrue(isCommitted(commitInbound(r, frame, 3, 60000)), "inbox commit ok")
        XCTAssertEqual(acks.deleteAllFrames(), 4096, "the wipe reports the exact count it removed")
        XCTAssertEqual(acks.countFrames(), 0, "the ACK namespace stands empty")
        let held = r.store.allHeldMsgIds()
        XCTAssertEqual(held.count, 1, "the message originals survived the wipe")
        XCTAssertTrue(held[0] == frame.msgId, "and the one held message is the committed original")
    }

    func testDuplicateValidMessageRegeneratesSameDeterministicAckNoDuplicateInbox() async throws {
        let r = try rig(107)
        r.keys.put(r.me.id.nodeId, r.me.id.signingPublicKey)
        let frame = try await inboxFrame(r, 71)
        if case .committed(let heldNew, let obNew, let dup) = commitInbound(r, frame, 7, 60000) {
            XCTAssertTrue(heldNew && obNew && !dup, "the first commit is fresh")
        } else {
            XCTFail("the first commit must succeed"); return
        }
        var genBefore: Int64 = -1
        var remBefore: Int64 = -1
        if case .found(let before) = r.store.ackStore.lookupObligation(frame.msgId, recipientNodeId: r.me.id.nodeId) {
            genBefore = before.identityGeneration
            remBefore = before.remainingLifetimeMs
        } else {
            XCTFail("the obligation must stand before the re-delivery"); return
        }
        // the same msg id arrives again; a newer pin offered must NOT replenish the row
        if case .committed(let heldNew, let obNew, let dup) = commitInbound(r, frame, 9, 90000) {
            XCTAssertTrue(!heldNew && !obNew && dup, "the duplicate reports itself a duplicate")
        } else {
            XCTFail("the duplicate commit must succeed as a duplicate"); return
        }
        XCTAssertEqual(r.store.allHeldMsgIds().count, 1, "one inbox row only")
        XCTAssertEqual(r.store.ackStore.countObligations(), 1, "one obligation row only")
        if case .found(let after) = r.store.ackStore.lookupObligation(frame.msgId, recipientNodeId: r.me.id.nodeId) {
            XCTAssertEqual(after.identityGeneration, genBefore, "the generation pin is not replenished by the re-delivery")
            XCTAssertEqual(after.remainingLifetimeMs, remBefore, "the remaining lifetime is not replenished either")
        } else {
            XCTFail("the obligation must stand after the re-delivery")
        }
        let rep = try driverOf(r, TestSigner(r.me)).runPendingOnce(8)
        XCTAssertEqual(rep.signed, 1, "one signed")
        guard case .records(let rows) = try r.store.ackStore.candidatesForPair(frame.msgId, recipientNodeId: r.me.id.nodeId, bound: 8), rows.count == 1 else {
            XCTFail("one ack, one row"); return
        }
        guard let expectedKey = AckCacheKey.compute(msgId: rows[0].msgId, recipientNodeId: rows[0].recipientNodeId,
                                                     signature: rows[0].signature) else {
            XCTFail("the deterministic key must be computable"); return
        }
        XCTAssertEqual(expectedKey, rows[0].ackKey, "one ack, one row, keyed by the digest of its stored parts")
        guard let decodedReply = FrameV2.decode(rows[0].encodedFrame) else {
            XCTFail("the stored reply must decode"); return
        }
        XCTAssertTrue(r.authenticator.verify(originalMsgId: frame.msgId, expectedRecipientNodeId: r.me.id.nodeId,
                                             ackFrame: decodedReply),
                      "the regenerated reply authenticates under the pinned key")
        let again = try driverOf(r, TestSigner(r.me)).runPendingOnce(8)
        XCTAssertEqual(again.scanned + again.signed + again.retired, 0, "the worker claims nothing twice")
    }

    func testObligationRetiredOnlyWithFrameTransaction() async throws {
        let acks = InMemoryAckStore()
        let m = nodeOf(81, 0x01)
        let recip = nodeOf(82, 0x02)
        let sig = Data((0..<64).map { UInt8(($0 * 3 + 11) & 0xFF) })
        guard let key = AckCacheKey.compute(msgId: m, recipientNodeId: recip, signature: sig) else {
            XCTFail("fixture key"); return
        }
        let enc = Data((0..<24).map { UInt8(($0 * 5 + 1) & 0xFF) })
        guard let record = AckFrameRecord.of(ackKey: key, msgId: m, recipientNodeId: recip, signature: sig,
                                             encodedFrame: enc, receivedFrom: nil, remainingLifetimeMs: 5000,
                                             verificationClass: .verifiedRecipiant) else {
            XCTFail("fixture record"); return
        }
        guard let ob = AckObligation.of(msgId: m, recipientNodeId: recip, identityGeneration: 2,
                                        remainingLifetimeMs: 5000, state: .pending) else {
            XCTFail("fixture obligation"); return
        }
        // (a) the pair step moves frame insert and retirement together
        XCTAssertTrue(acks.insertIfAbsent(ob) == .stored, "insert the fixture obligation")
        XCTAssertTrue(acks.commitFrameAndRetireObligation(record, msgId: m, recipientNodeId: recip) == .committed, "the pair step must commit")
        XCTAssertEqual(acks.countFrames(), 1, "the frame arrived")
        XCTAssertTrue(acks.lookupObligation(m, recipientNodeId: recip) == .absent, "and the obligation retired in the same step")
        // (b) replaying the pair step is idempotent
        XCTAssertTrue(acks.commitFrameAndRetireObligation(record, msgId: m, recipientNodeId: recip) == .idempotent, "the replay must be idempotent")
        XCTAssertEqual(acks.countFrames(), 1, "still exactly one frame row")
        // (c) the guarded mark advances once; drift is named; absence is not a failure
        let m2 = nodeOf(83, 0x03)
        guard let ob2 = AckObligation.of(msgId: m2, recipientNodeId: recip, identityGeneration: 3,
                                         remainingLifetimeMs: 4000, state: .pending) else {
            XCTFail("fixture obligation"); return
        }
        XCTAssertTrue(acks.insertIfAbsent(ob2) == .stored, "insert the second fixture obligation")
        XCTAssertTrue(acks.markSigned(m2, recipientNodeId: recip) == .advanced, "markSigned advances a pending row")
        if case .stateDrift(let st) = acks.markSigned(m2, recipientNodeId: recip) {
            XCTAssertEqual(st, .signed, "the second mark reports the drift it saw")
        } else {
            XCTFail("the second mark must report drift, not advance")
        }
        XCTAssertTrue(acks.markSigned(nodeOf(99, 0x99), recipientNodeId: recip) == .absent, "absence is Absent, never a failure")
        // (d) the resume scan re-drives half-finished pairs: a SIGNED row stays visible
        if case .rows(let pl) = try acks.listPending(8) {
            XCTAssertEqual(pl.count, 1, "the SIGNED row is still awaiting retirement")
            XCTAssertEqual(pl[0].state, .signed)
        } else {
            XCTFail("the resume scan must succeed")
        }
        let sig2 = Data((0..<64).map { UInt8(($0 * 9 + 1) & 0xFF) })
        guard let key2 = AckCacheKey.compute(msgId: m2, recipientNodeId: recip, signature: sig2) else {
            XCTFail("fixture key"); return
        }
        let enc2 = Data((0..<24).map { UInt8(($0 * 7 + 3) & 0xFF) })
        guard let record2 = AckFrameRecord.of(ackKey: key2, msgId: m2, recipientNodeId: recip, signature: sig2,
                                              encodedFrame: enc2, receivedFrom: nil, remainingLifetimeMs: 4000,
                                              verificationClass: .verifiedRecipiant) else {
            XCTFail("fixture record"); return
        }
        XCTAssertTrue(acks.commitFrameAndRetireObligation(record2, msgId: m2, recipientNodeId: recip) == .committed, "the half-finished pair must complete atomically")
        if case .rows(let pl2) = try acks.listPending(8) {
            XCTAssertEqual(pl2.count, 0, "the scan drains to zero")
        } else {
            XCTFail("the final scan must succeed")
        }
    }

    func testStorageFailureYieldsNeitherAckNorClaimedAcceptance() async throws {
        let r = try rig(109)
        r.keys.put(r.me.id.nodeId, r.me.id.signingPublicKey)
        let frame = try await inboxFrame(r, 91)
        // the fault seam at the obligation boundary: the WHOLE inbox commit rolls back
        let c = r.store.commitInboundWithObligationAtWithFault(
            frame, receivedFrom: r.originId, localRecipientNodeId: r.me.id.nodeId,
            identityGeneration: 7, obligationLifetimeMs: 60000, receivedAt: 1700000201
        ) { point in
            if point == "obligation" { throw NSError(domain: "ReadinessT83", code: 7) }
        }
        XCTAssertEqual(c, .storageFailure, "the in-memory commit names the storage failure")
        XCTAssertEqual(r.store.allHeldMsgIds().count, 0, "the held set stayed empty: no half-delivered inbox")
        XCTAssertEqual(r.store.ackStore.countObligations(), 0, "and no obligation was claimed")
        // the failure did not poison the store: an unrelated commit still succeeds
        let frame2 = try await inboxFrame(r, 92)
        XCTAssertTrue(isCommitted(commitInbound(r, frame2, 7, 60000)), "a later commit succeeds")
        // the real engine: the same law through the transaction, CHECKs at the gate
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("godstone-t83-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        let originRouter = Router(selfNodeId: r.originId)
        originRouter.store = db
        let sqlIdentity = LogicalMessageIdentity.of(createdAtEpochSeconds: 1700000205, messageNonce: Data(nonceOf(93)))
        let sqlFrame = try await originRouter.buildSealedMessage(
            plaintext: Data("t83-sql-93".utf8), recipientNodeId: r.me.id.nodeId,
            recipientStaticPub: r.me.id.staticDhPublicKey, identity: sqlIdentity, priority: .direct
        )
        let cSql = db.commitInboundWithObligationAtWithFault(
            sqlFrame, receivedFrom: r.originId, localRecipientNodeId: r.me.id.nodeId,
            identityGeneration: 7, obligationLifetimeMs: 60000, receivedAt: 1700000206
        ) { point, _ in
            if point == "obligation" { throw NSError(domain: "ReadinessT83", code: 9) }
        }
        XCTAssertEqual(cSql, .storageFailure, "the SQL commit names the storage failure")
        XCTAssertEqual(db.allHeldMsgIds().count, 0, "no held row survived the rolled-back transaction")
        XCTAssertEqual(try db.listPendingObligations(8).count, 0, "no obligation row either")
        // and the clean commit right after still succeeds through the real engine
        let cSql2 = db.commitInboundWithObligationAtWithFault(
            sqlFrame, receivedFrom: r.originId, localRecipientNodeId: r.me.id.nodeId,
            identityGeneration: 7, obligationLifetimeMs: 60000, receivedAt: 1700000206, fault: nil
        )
        if case .committed(let heldNew, let obNew, let dup) = cSql2 {
            XCTAssertTrue(heldNew && obNew && !dup, "the clean commit reports fresh held + stored obligation")
        } else {
            XCTFail("the clean commit must succeed")
        }
        // CHECK constraints refuse forgeries the constructors would never build
        var raised = false
        do {
            _ = try db.insertObligation(nodeOf(93, 1), recipientNodeId: nodeOf(94, 2),
                                       identityGeneration: 1, remainingLifetimeMs: 1, stateCode: 9)
            raised = false
        } catch {
            raised = true
        }
        XCTAssertTrue(raised, "the state-domain CHECK refuses the code 9")
        raised = false
        do {
            _ = try db.insertObligation(Data(nodeOf(93, 1).prefix(15)), recipientNodeId: nodeOf(94, 2),
                                        identityGeneration: 1, remainingLifetimeMs: 1, stateCode: 0)
            raised = false
        } catch {
            raised = true
        }
        XCTAssertTrue(raised, "the length CHECK refuses a 15-byte msg id")
        XCTAssertTrue(try db.insertObligation(nodeOf(93, 1), recipientNodeId: nodeOf(94, 2),
                                              identityGeneration: 4, remainingLifetimeMs: 60000, stateCode: 0), "a well-formed row is accepted")
        guard let twin = AckObligation.of(msgId: nodeOf(93, 1), recipientNodeId: nodeOf(94, 2),
                                          identityGeneration: 4, remainingLifetimeMs: 60000, state: .pending) else {
            XCTFail("fixture obligation"); return
        }
        XCTAssertTrue(SqliteAckStore(engine: db).insertIfAbsent(twin) == .duplicate, "the very same pair is a Duplicate, not a failure")
        XCTAssertTrue(SqliteAckStore(engine: db).lookupObligation(nodeOf(99, 9), recipientNodeId: nodeOf(98, 8)) == .absent, "an absent pair must read Absent before any close")
        // the pair step over the real engine: frame and retirement move together
        let pm = nodeOf(95, 3)
        let pr = nodeOf(96, 4)
        let ps = Data((0..<64).map { UInt8(($0 * 9 + 7) & 0xFF) })
        guard let pk = AckCacheKey.compute(msgId: pm, recipientNodeId: pr, signature: ps) else {
            XCTFail("fixture key"); return
        }
        let pe = Data((0..<18).map { UInt8(($0 * 3 + 2) & 0xFF) })
        guard let prec = AckFrameRecord.of(ackKey: pk, msgId: pm, recipientNodeId: pr, signature: ps,
                                           encodedFrame: pe, receivedFrom: nil, remainingLifetimeMs: 4000,
                                           verificationClass: .verifiedRecipiant) else {
            XCTFail("fixture record"); return
        }
        _ = try db.insertObligation(pm, recipientNodeId: pr, identityGeneration: 5, remainingLifetimeMs: 4000, stateCode: 0)
        XCTAssertEqual(try db.commitAckPair(prec.toView(), msgId: pm, recipientNodeId: pr), .committed, "the pair step commits atomically")
        XCTAssertNotNil(try db.readAckFrameRowByAckKey(pk), "the frame row persists")
        XCTAssertNil(try db.readObligation(pm, recipientNodeId: pr), "the obligation row retired")
        // reboot over the same file: the four-table DDL fingerprint validates, rows endure
        db.close()
        let db2 = SqliteMessageStore(url: url, maxBytes: .max, fileProtection: .complete)
        XCTAssertNotNil(try db2.readAckFrameRowByAckKey(pk), "the frame row survives the reopen")
        XCTAssertNil(try db2.readObligation(pm, recipientNodeId: pr), "the obligation stays retired across the reopen")
        // failure distinguished from absence once the engine is no more
        db2.close()
        XCTAssertTrue(SqliteAckStore(engine: db2).lookupObligation(pm, recipientNodeId: pr) == .storageFailure, "a closed engine must answer StorageFailure, never Absent")
    }

    func testWrongSizedInputsRejectedBeforeAnyWrite() async throws {
        let good = nodeOf(10, 0x0A)
        // obligations: every wrong width is refused by the constructor
        XCTAssertNil(AckObligation.of(msgId: Data(good.prefix(15)), recipientNodeId: good,
                                                          identityGeneration: 1, remainingLifetimeMs: 1, state: .pending), "a 15-byte msg id")
        XCTAssertNil(AckObligation.of(msgId: good + Data([1, 2]), recipientNodeId: good,
                                                          identityGeneration: 1, remainingLifetimeMs: 1, state: .pending), "a 17-byte msg id")
        XCTAssertNil(AckObligation.of(msgId: good, recipientNodeId: Data(good.prefix(15)),
                                                             identityGeneration: 1, remainingLifetimeMs: 1, state: .pending), "a 15-byte recipient")
        XCTAssertNil(AckObligation.of(msgId: good, recipientNodeId: good,
                                                              identityGeneration: -1, remainingLifetimeMs: 1, state: .pending), "a negative generation")
        XCTAssertNil(AckObligation.of(msgId: good, recipientNodeId: good,
                                                            identityGeneration: 1, remainingLifetimeMs: -1, state: .pending), "a negative lifetime")
        // frame records: the key, the signature and the widths are all policed
        let sig = Data((0..<64).map { UInt8($0 & 0xFF) })
        let enc = Data((0..<10).map { UInt8($0 & 0xFF) })
        guard let key = AckCacheKey.compute(msgId: good, recipientNodeId: good, signature: sig) else {
            XCTFail("fixture key"); return
        }
        XCTAssertNil(AckFrameRecord.of(ackKey: Data(key.prefix(31)), msgId: good, recipientNodeId: good,
                                                       signature: sig, encodedFrame: enc, receivedFrom: nil,
                                                       remainingLifetimeMs: 1, verificationClass: .verifiedRecipiant), "a 31-byte key")
        XCTAssertNil(AckFrameRecord.of(ackKey: key + Data([3]), msgId: good, recipientNodeId: good,
                                                        signature: sig, encodedFrame: enc, receivedFrom: nil,
                                                        remainingLifetimeMs: 1, verificationClass: .verifiedRecipiant), "a 33-byte key")
        XCTAssertNil(AckFrameRecord.of(ackKey: key, msgId: good, recipientNodeId: good,
                                                              signature: Data(sig.prefix(63)), encodedFrame: enc, receivedFrom: nil,
                                                              remainingLifetimeMs: 1, verificationClass: .verifiedRecipiant), "a 63-byte signature")
        XCTAssertNil(AckFrameRecord.of(ackKey: key, msgId: good, recipientNodeId: good,
                                                            signature: sig, encodedFrame: Data(), receivedFrom: nil,
                                                            remainingLifetimeMs: 1, verificationClass: .verifiedRecipiant), "an empty encoding")
        XCTAssertNil(AckFrameRecord.of(ackKey: key, msgId: good, recipientNodeId: good,
                                                                  signature: sig, encodedFrame: enc, receivedFrom: Data(good.prefix(15)),
                                                                  remainingLifetimeMs: 1, verificationClass: .verifiedRecipiant), "a 15-byte receivedFrom")
        XCTAssertNil(AckFrameRecord.of(ackKey: key, msgId: good, recipientNodeId: good,
                                                                signature: sig, encodedFrame: enc, receivedFrom: nil,
                                                                remainingLifetimeMs: -1, verificationClass: .verifiedRecipiant), "a negative remaining")
        // the classifier refuses malformed wire before the table ever sees it
        let r = try rig(110)
        let d = driverOf(r, TestSigner(r.me))
        XCTAssertTrue(d.admitForeignCandidate(Data([0x47, 0x53, 0x02, 0x00, 0x00, 0x00, 0x01]), receivedFrom: nil) == .refusedBadFrame, "truncated bytes")
        let message = try await inboxFrame(r, 1091)
        XCTAssertTrue(d.admitForeignCandidate(message.encode(), receivedFrom: nil) == .refusedBadFrame, "a MESSAGE frame cannot be admitted as an ACK")
        let genuine = try AckFrame.build(msgId: message.msgId, recipientSigningPrivKey: r.me.seed,
                                         recipientNodeId: r.me.id.nodeId, routingTag: hintOf(r.me.id.nodeId))
        let shrunk = FrameV2(type: genuine.type, msgId: genuine.msgId, routingTag: genuine.routingTag,
                             ttl: genuine.ttl, hopCount: genuine.hopCount, flags: genuine.flags,
                             payload: Data(genuine.payload.prefix(79)))
        XCTAssertTrue(d.admitForeignCandidate(shrunk.encode(), receivedFrom: nil) == .refusedBadFrame, "a 79-byte payload is out of shape")
        XCTAssertTrue(d.admitForeignCandidate(genuine.encode(), receivedFrom: Data(good.prefix(15))) == .refusedBadFrame, "a 15-byte receivedFrom is out of shape")
        XCTAssertEqual(r.store.ackStore.countFrames(), 0, "nothing reached any table")
        // the profile gates of the inbox commit refuse a non-DIRECT and an unsealed frame
        let groupFrame = try await r.router.buildSealedMessage(
            plaintext: Data("t83-group".utf8), recipientNodeId: r.me.id.nodeId,
            recipientStaticPub: r.me.id.staticDhPublicKey,
            identity: LogicalMessageIdentity.of(createdAtEpochSeconds: 1700000202, messageNonce: Data(nonceOf(91))),
            priority: .group
        )
        XCTAssertTrue(r.store.commitInboundWithObligationAtWithFault(
                        groupFrame, receivedFrom: r.originId, localRecipientNodeId: r.me.id.nodeId,
                        identityGeneration: 1, obligationLifetimeMs: 1000, receivedAt: 1700000203, fault: nil
                      ) == .invalidArgument, "a GROUP message is out of the DIRECT profile")
        let unsealed = FrameV2(type: .message, msgId: message.msgId, routingTag: message.routingTag,
                               ttl: message.ttl, hopCount: message.hopCount,
                               flags: Priority.toFlags(.direct), payload: message.payload)
        XCTAssertTrue(r.store.commitInboundWithObligationAtWithFault(
                        unsealed, receivedFrom: r.originId, localRecipientNodeId: r.me.id.nodeId,
                        identityGeneration: 1, obligationLifetimeMs: 1000, receivedAt: 1700000203, fault: nil
                      ) == .invalidArgument, "an unsealed frame is out of profile")
        XCTAssertEqual(r.store.ackStore.countObligations(), 0, "no obligation row was written by the refusals")
        XCTAssertEqual(r.store.allHeldMsgIds().count, 0, "no frame was held by the refusals")
    }

    func testCanonicalAckBytesEndToEnd() async throws {
        let r = try rig(111)
        r.keys.put(r.me.id.nodeId, r.me.id.signingPublicKey)
        let frame = try await inboxFrame(r, 1111)
        if case .committed(let heldNew, let obNew, let dup) = commitInbound(r, frame, 7, 60000) {
            XCTAssertTrue(heldNew && obNew && !dup, "held new, obligation stored, not a duplicate")
        } else {
            XCTFail("the inbox commit must succeed"); return
        }
        let rep = try driverOf(r, TestSigner(r.me)).runPendingOnce(8)
        XCTAssertEqual(rep.signed + rep.retired, 2, "one signed, one retired")
        guard case .records(let pl) = try r.store.ackStore.candidatesForPair(frame.msgId, recipientNodeId: r.me.id.nodeId, bound: 8),
              pl.count == 1 else {
            XCTFail("exactly one reply row"); return
        }
        let rec = pl[0]
        XCTAssertNil(rec.receivedFrom, "locally authored: no peer was seen")
        XCTAssertEqual(rec.verificationClass, .verifiedRecipiant, "class VERIFIED under the own key")
        XCTAssertEqual(rec.remainingLifetimeMs, 60000, "the lifetime is carried from the obligation, not replenished")
        guard let dec = FrameV2.decode(rec.encodedFrame) else {
            XCTFail("the stored encoding must decode"); return
        }
        XCTAssertEqual(dec.type, .ack, "the reply names an ACK")
        XCTAssertEqual(frame.msgId, dec.msgId, "over the very msg id")
        XCTAssertEqual(dec.payload.count, 80, "the canonical payload is signature(64) || recipient(16)")
        XCTAssertEqual(rec.signature, Data(dec.payload.prefix(64)), "the signature field")
        XCTAssertEqual(r.me.id.nodeId, Data(dec.payload.suffix(16)), "the recipient field")
        XCTAssertEqual(hintOf(r.me.id.nodeId), dec.routingTag, "the routing tag is the canonical recipient hint")
        XCTAssertTrue(r.authenticator.verify(originalMsgId: frame.msgId, expectedRecipientNodeId: r.me.id.nodeId,
                                             ackFrame: dec), "the frozen authenticator, the wire's own gate, accepts the stored reply")
        guard let ky = AckCacheKey.compute(msgId: frame.msgId, recipientNodeId: r.me.id.nodeId,
                                           signature: rec.signature) else {
            XCTFail("the digest must be computable"); return
        }
        XCTAssertEqual(ky, rec.ackKey, "key == SHA256(domain || msg || recipient || signature)")
        let held = r.store.allHeldOrderedByPriority()
        XCTAssertEqual(held.count, 1, "the original still stands")
        XCTAssertEqual(frame.encode(), held[0].encode(), "byte for byte")
        XCTAssertEqual(r.store.ackStore.countObligations(), 0, "the obligation is discharged")
        let idle = try driverOf(r, TestSigner(r.me)).runPendingOnce(8)
        XCTAssertEqual(idle.scanned + idle.signed + idle.retired + idle.keyUnavailable + idle.storageFailures, 0, "a restart finds nothing pending and claims nothing afresh")
    }
}
