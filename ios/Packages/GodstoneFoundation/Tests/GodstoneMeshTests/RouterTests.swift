import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

final class RouterTests: XCTestCase {
    private static let routingTag = Data(repeating: 0x01, count: 4)
    private static let testSelfNodeId = Data(repeating: 0x0A, count: 16)

    private func frame(_ id: String,
                       ttl: UInt8 = 8,
                       type: TypeV2 = .message,
                       flags: UInt16 = UInt16(FrameV2.Flags.relay_ok)) -> FrameV2 {
        var messageId = Data(id.utf8)
        if messageId.count < 16 {
            messageId.append(Data(repeating: 0, count: 16 - messageId.count))
        }
        return FrameV2(
            type: type,
            msgId: Data(messageId.prefix(16)),
            routingTag: Self.routingTag,
            ttl: ttl,
            hopCount: 0,
            flags: flags,
            payload: Data(repeating: 0, count: 32)
        )
    }

    func testDuplicateIsSuppressed() {
        let router = Router(selfNodeId: Self.testSelfNodeId)
        let f = frame("msg-1")
        XCTAssertTrue(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertFalse(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
    }

    func testTtlAndHopCountChangeOnRelay() throws {
        let router = Router(selfNodeId: Self.testSelfNodeId)
        XCTAssertTrue(router.ingest(frame("msg-2", ttl: 5), isAddressedToMe: false, receivedFrom: Data()))
        let relayed = try XCTUnwrap(router.drain(limit: 1).first)
        XCTAssertEqual(relayed.ttl, 4)
        XCTAssertEqual(relayed.hopCount, 1)
    }

    func testSosIsDeliveredLocallyAndStillRelayed() {
        let router = Router(selfNodeId: Self.testSelfNodeId)
        var delivered: FrameV2?
        router.onDeliverLocally = { delivered = $0 }

        let sos = frame("msg-sos", ttl: 8, type: .sos,
                        flags: UInt16(FrameV2.Flags.ack_req | FrameV2.Flags.relay_ok))
        XCTAssertTrue(router.ingest(sos, isAddressedToMe: true, receivedFrom: Data()))
        XCTAssertEqual(delivered?.type, .sos)
        XCTAssertFalse(router.drain(limit: 8).isEmpty)
    }

    func testNonSosLocalDeliveryDoesNotRelay() {
        let router = Router(selfNodeId: Self.testSelfNodeId)
        XCTAssertTrue(router.ingest(frame("local"), isAddressedToMe: true, receivedFrom: Data()))
        XCTAssertTrue(router.drain(limit: 8).isEmpty)
    }

    /// Stage 4B: with a durable store attached the digest is built from the
    /// store's held msg_ids (ADR-004 criterion 6), not the dedup window. A
    /// duplicate ingest does not change the held set, so the digest is stable,
    /// and the held msg_id is present in the 512-byte filter.
    func testBloomDigestIsStableAcrossDuplicate() {
        let router = Router(selfNodeId: Self.testSelfNodeId)
        let store = InMemoryMessageStore()
        router.store = store
        let f = frame("msg-bloom")
        XCTAssertTrue(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
        let first = router.bloomDigest()
        XCTAssertEqual(first.count, 512)
        XCTAssertTrue(BloomDigest.fromBytes(first).mightContain(f.msgId))
        _ = router.ingest(f, isAddressedToMe: false, receivedFrom: Data())
        XCTAssertEqual(first, router.bloomDigest())
    }

    /// Stage 4B: a storeless router returns an empty digest (the previous
    /// `seen.elements` fallback is removed -- it described a different set).
    func testStorelessBloomDigestIsEmpty() {
        let router = Router(selfNodeId: Self.testSelfNodeId)
        let digest = router.bloomDigest()
        XCTAssertEqual(digest.count, 512)
        XCTAssertEqual(digest, Data(repeating: 0, count: 512))
    }

    /// Stage 4B: persist before forward (ADR-004). A novel accepted frame is
    /// durably held AND forwarded to the relay queue.
    func testIngestPersistsBeforeForwardWhenStoreAttached() {
        let router = Router(selfNodeId: Self.testSelfNodeId)
        let store = InMemoryMessageStore()
        router.store = store
        var delivered = 0
        router.onDeliverLocally = { _ in delivered += 1 }
        let fromPeer = Data(repeating: 0xAB, count: 16)
        let f = frame("msg-pf")

        XCTAssertTrue(router.ingest(f, isAddressedToMe: false, receivedFrom: fromPeer))
        XCTAssertEqual(store.allHeldMsgIds(), [f.msgId])           // durably held
        XCTAssertFalse(router.drain(limit: 8).isEmpty)            // forwarded
        XCTAssertEqual(delivered, 0)                              // not addressed to me
    }

    /// Stage 4B: persist result checked. When the durable store cannot hold the
    /// frame, the router does NOT forward or deliver it -- relaying what this
    /// node cannot itself carry would let the only copy be dropped.
    func testIngestDoesNotForwardWhenPersistFails() {
        let router = Router(selfNodeId: Self.testSelfNodeId)
        router.store = FailingStore()
        var delivered = 0
        router.onDeliverLocally = { _ in delivered += 1 }
        let f = frame("msg-fail")

        XCTAssertFalse(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertTrue(router.drain(limit: 8).isEmpty)             // not forwarded
        XCTAssertEqual(delivered, 0)                              // not delivered
        XCTAssertEqual(router.store!.allHeldMsgIds(), [])         // not held
    }

    /// Stage 4B: an addressed non-SOS frame is delivered locally and is NOT
    /// relayed, but it IS durably held (persist before forward/delivery).
    func testAddressedNonSosIsPersistedAndDeliveredButNotRelayed() {
        let router = Router(selfNodeId: Self.testSelfNodeId)
        let store = InMemoryMessageStore()
        router.store = store
        var delivered: FrameV2?
        router.onDeliverLocally = { delivered = $0 }
        let f = frame("local-2")

        XCTAssertTrue(router.ingest(f, isAddressedToMe: true, receivedFrom: Data()))
        XCTAssertEqual(delivered?.msgId, f.msgId)                 // delivered locally
        XCTAssertEqual(store.allHeldMsgIds(), [f.msgId])           // durably held
        XCTAssertTrue(router.drain(limit: 8).isEmpty)              // not relayed
    }

    // MARK: - Stage 4B.1 / B1: a persist failure must NOT poison retry

    /// B1: the durable store is the dedup authority and `seen` is only an
    /// optimisation populated AFTER durable acceptance. A frame whose first
    /// persist FAILS must not be permanently marked seen -- after the store
    /// recovers the same msg_id must be accepted, held and forwarded exactly
    /// once, and a third (now-duplicate) arrival must be suppressed.
    func testPersistFailureDoesNotPoisonRetry() {
        let store = FailThenSucceedStore()
        let router = Router(selfNodeId: Self.testSelfNodeId)
        router.store = store
        var delivered = 0
        router.onDeliverLocally = { _ in delivered += 1 }
        let f = frame("msg-retry", ttl: 5)

        // 1st arrival: store fails -> .failedStorage -> NOT marked seen, NOT
        // forwarded, NOT delivered, NOT held. The msg_id is NOT poisoned.
        XCTAssertFalse(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertTrue(router.drain(limit: 8).isEmpty, "failed persist must not forward")
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(store.allHeldMsgIds(), [], "failed persist must not hold the frame")

        // 2nd arrival, SAME msg_id: store now succeeds -> .heldNew -> held,
        // forwarded exactly once. This is the retry B1 guarantees is possible.
        XCTAssertTrue(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertEqual(router.drain(limit: 8).count, 1, "recovered retry forwarded exactly once")
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(store.allHeldMsgIds(), [f.msgId], "recovered retry durably held once")

        // 3rd arrival, SAME msg_id: now a duplicate (seen hit) -> suppressed.
        XCTAssertFalse(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertTrue(router.drain(limit: 8).isEmpty, "duplicate not forwarded again")
        XCTAssertEqual(store.allHeldMsgIds(), [f.msgId], "still held exactly once")
    }

    /// B1: with the durable store as authority, a duplicate whose id has aged out
    /// of the small in-memory LRU (but is still durably held) MUST be caught by the
    /// durable UNIQUE(msg_id) and reported `.heldDuplicate` -- not re-forwarded.
    func testDurableUniqueCatchesDuplicateAgedOutOfLru() {
        let store = InMemoryMessageStore()
        let router = Router(selfNodeId: Self.testSelfNodeId, seenCacheCapacity: 2)
        router.store = store
        let f = frame("msg-aged", ttl: 5)

        // Persist f -> .heldNew, seen=[f], forwarded.
        XCTAssertTrue(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertEqual(router.drain(limit: 8).count, 1)   // clear f's forward
        // Two distinct ids evict f from the 2-entry LRU: seen=[other-1,other-2].
        XCTAssertTrue(router.ingest(frame("other-1", ttl: 5), isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertTrue(router.ingest(frame("other-2", ttl: 5), isAddressedToMe: false, receivedFrom: Data()))
        _ = router.drain(limit: 8)                          // clear their forwards
        // f is gone from the LRU but still durably held. Re-offering it is a LRU
        // MISS -> persist -> .heldDuplicate -> suppressed (NOT re-forwarded).
        XCTAssertFalse(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertTrue(router.drain(limit: 8).isEmpty, "aged-out duplicate must not re-forward")
        // Still held exactly once among the three.
        XCTAssertEqual(store.allHeldMsgIds().count, 3)
    }

    func testIngestForwardCopyPreservesCanonicalFields() throws {
        let router = Router(selfNodeId: Self.testSelfNodeId)
        let original = frame("msg-fwd-fields", ttl: 7, flags: UInt16(FrameV2.Flags.relay_ok))
        XCTAssertTrue(router.ingest(original, isAddressedToMe: false, receivedFrom: Data()))
        let forwarded = try XCTUnwrap(router.drain(limit: 1).first)
        XCTAssertEqual(forwarded.type, original.type)
        XCTAssertEqual(forwarded.msgId, original.msgId)
        XCTAssertEqual(forwarded.routingTag, original.routingTag)
        XCTAssertEqual(forwarded.flags, original.flags)
        XCTAssertEqual(forwarded.payload, original.payload)
        XCTAssertEqual(forwarded.ttl, 6)
        XCTAssertEqual(forwarded.hopCount, 1)
    }

    func testDedupLRUEvictionUnderCapacity() {
        let router = Router(selfNodeId: Self.testSelfNodeId, seenCacheCapacity: 2)
        let f1 = frame("msg-1")
        let f2 = frame("msg-2")
        let f3 = frame("msg-3")

        XCTAssertTrue(router.ingest(f1, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertTrue(router.ingest(f2, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertTrue(router.ingest(f3, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertTrue(router.ingest(f1, isAddressedToMe: false, receivedFrom: Data()))
    }

    func testConcurrentIngestOfSameMsgIdForwardsAtMostOnce() {
        let store = InMemoryMessageStore()
        let router = Router(selfNodeId: Self.testSelfNodeId)
        router.store = store
        let f = frame("msg-concurrent", ttl: 5)
        let n = 8
        let group = DispatchGroup()
        let queue = DispatchQueue.global()
        let counterLock = NSLock()
        var acceptedCount = 0
        for _ in 0..<n {
            group.enter()
            queue.async {
                let r = router.ingest(f, isAddressedToMe: false, receivedFrom: Data())
                counterLock.lock(); if r { acceptedCount += 1 }; counterLock.unlock()
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(acceptedCount, 1, "exactly one of N concurrent arrivals accepted")
        XCTAssertEqual(router.drain(limit: 8).count, 1, "forwarded exactly once")
        XCTAssertEqual(store.allHeldMsgIds(), [f.msgId], "held exactly once")
    }

    // MARK: - C6.7.2 Sealed Message Policy & Verified Open Tests

    func testBuildSealedMessageAndOpenSealedMessageAccepted() async throws {
        let senderNodeId = Data((0..<16).map { UInt8($0) })
        let router = Router(selfNodeId: senderNodeId)

        let recipientPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPriv = recipientPrivKey.rawRepresentation
        let recipientPub = recipientPrivKey.publicKey.rawRepresentation
        let recipientNodeId = Data(repeating: 0x55, count: 16)

        let plaintext = Data("Hello secure mesh on iOS".utf8)
        let identity = LogicalMessageIdentity.of(createdAtEpochSeconds: 1700000000, messageNonce: Data(repeating: 0x01, count: 16))

        let frame = try await router.buildSealedMessage(
            plaintext: plaintext,
            recipientNodeId: recipientNodeId,
            recipientStaticPub: recipientPub,
            identity: identity,
            priority: .direct
        )

        XCTAssertEqual(frame.type, TypeV2.message)
        XCTAssertEqual(frame.msgId.count, 16)

        let result = router.openSealedMessage(frame, ourStaticDhPriv: recipientPriv)
        guard case let .accepted(opened) = result else {
            XCTFail("Expected .accepted result, got \(result)")
            return
        }

        XCTAssertEqual(opened.senderNodeId, senderNodeId)
        XCTAssertEqual(opened.identity, identity)
        XCTAssertEqual(opened.priority, .direct)
        XCTAssertTrue(opened.powNonce.allSatisfy { $0 == 0 })
        XCTAssertEqual(opened.plaintext, plaintext)

        // Tampering negative control 1: Mutated header msg_id -> messageIdMismatch
        var tamperedMsgId = frame
        let tamperedBytes = Data(repeating: 0x99, count: 16)
        tamperedMsgId = FrameV2(
            type: frame.type,
            msgId: tamperedBytes,
            routingTag: frame.routingTag,
            ttl: frame.ttl,
            hopCount: frame.hopCount,
            flags: frame.flags,
            payload: frame.payload
        )
        let resTamperedId = router.openSealedMessage(tamperedMsgId, ourStaticDhPriv: recipientPriv)
        XCTAssertEqual(resTamperedId, OpenMessageResult.messageIdMismatch)

        // Tampering negative control 2: Wrong DH private key -> notForUs
        let wrongPriv = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
        let resWrongKey = router.openSealedMessage(frame, ourStaticDhPriv: wrongPriv)
        XCTAssertEqual(resWrongKey, OpenMessageResult.notForUs)
    }

    func testGroupMessageWithLockedPowKatVerifiesOnOpen() async throws {
        let senderNodeId = Data((0..<16).map { UInt8($0) })
        let router = Router(selfNodeId: senderNodeId)

        let recipientPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPriv = recipientPrivKey.rawRepresentation
        let recipientPub = recipientPrivKey.publicKey.rawRepresentation
        let recipientNodeId = Data(repeating: 0x77, count: 16)

        // Construct sealed inner with locked 20-bit PoW KAT
        let plaintext = Data("help".utf8)
        let identity = LogicalMessageIdentity.of(createdAtEpochSeconds: 1, messageNonce: Data(repeating: 0x01, count: 16))
        var powNonceBytes = [UInt8]()
        let powNonceHex = "00000000000fe48c"
        var idx = powNonceHex.startIndex
        while idx < powNonceHex.endIndex {
            let next = powNonceHex.index(idx, offsetBy: 2)
            powNonceBytes.append(UInt8(powNonceHex[idx..<next], radix: 16)!)
            idx = next
        }
        let powNonce = Data(powNonceBytes)

        var sealedInner = Data()
        sealedInner.append(identity.messageNonce)
        sealedInner.append(powNonce)
        sealedInner.append(identity.createdAtLe())
        sealedInner.append(UInt8(Priority.group.rawValue))
        sealedInner.append(plaintext)

        let sealed = try SealedSender.seal(
            plaintext: sealedInner,
            senderNodeId: senderNodeId,
            recipientStaticPub: recipientPub
        )
        let msgId = MessageId.derive(senderNodeId: senderNodeId, identity: identity, plaintext: plaintext)
        let frame = FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: SealedSender.routingTag(recipientNodeId: recipientNodeId, epochDay: SealedSender.currentEpochDay()),
            ttl: 8,
            hopCount: 0,
            flags: UInt16(FrameV2.Flags.sealed) | Priority.toFlags(.group) | UInt16(FrameV2.Flags.has_pow),
            payload: sealed
        )

        let result = router.openSealedMessage(frame, ourStaticDhPriv: recipientPriv)
        guard case let .accepted(opened) = result else {
            XCTFail("Expected .accepted for valid PoW message, got \(result)")
            return
        }
        XCTAssertEqual(opened.priority, .group)
        XCTAssertEqual(opened.powNonce, powNonce)
        XCTAssertEqual(opened.plaintext, plaintext)
    }

    /// CRITICAL SECURITY TEST: Downgrade attack
    /// Attacker mutates header priority to DIRECT and clears HAS_POW.
    /// Recipient MUST reject with .policyMismatch because authenticated sealed priority is GROUP.
    func testDowngradeAttackOnGroupMessageToDirectHeaderIsRejectedWithPolicyMismatch() async throws {
        let senderNodeId = Data((0..<16).map { UInt8($0) })
        let router = Router(selfNodeId: senderNodeId)

        let recipientPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPriv = recipientPrivKey.rawRepresentation
        let recipientPub = recipientPrivKey.publicKey.rawRepresentation

        let identity = LogicalMessageIdentity.createNew()
        let dummyPowNonce = Data(repeating: 0x01, count: 8)
        let plaintext = Data("High-priority group alert".utf8)
        var sealedInner = Data()
        sealedInner.append(identity.messageNonce)
        sealedInner.append(dummyPowNonce)
        sealedInner.append(identity.createdAtLe())
        sealedInner.append(UInt8(Priority.group.rawValue))
        sealedInner.append(plaintext)

        let sealed = try SealedSender.seal(
            plaintext: sealedInner,
            senderNodeId: senderNodeId,
            recipientStaticPub: recipientPub
        )
        let msgId = MessageId.derive(senderNodeId: senderNodeId, identity: identity, plaintext: plaintext)

        // Attacker frames with DIRECT header and NO has_pow flag
        let downgradedFrame = FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: Data(count: 4),
            ttl: 8,
            hopCount: 0,
            flags: UInt16(FrameV2.Flags.sealed) | Priority.toFlags(.direct),
            payload: sealed
        )

        let result = router.openSealedMessage(downgradedFrame, ourStaticDhPriv: recipientPriv)
        XCTAssertEqual(result, OpenMessageResult.policyMismatch)
    }

    func testHeaderPriorityMismatchAgainstSealedPriorityIsRejectedWithPolicyMismatch() async throws {
        let senderNodeId = Data((0..<16).map { UInt8($0) })
        let router = Router(selfNodeId: senderNodeId)

        let recipientPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPriv = recipientPrivKey.rawRepresentation
        let recipientPub = recipientPrivKey.publicKey.rawRepresentation

        let identity = LogicalMessageIdentity.createNew()
        let dummyPowNonce = Data(repeating: 0x01, count: 8)
        let plaintext = Data("Policy check message".utf8)
        var sealedInner = Data()
        sealedInner.append(identity.messageNonce)
        sealedInner.append(dummyPowNonce)
        sealedInner.append(identity.createdAtLe())
        sealedInner.append(UInt8(Priority.group.rawValue))
        sealedInner.append(plaintext)

        let sealed = try SealedSender.seal(
            plaintext: sealedInner,
            senderNodeId: senderNodeId,
            recipientStaticPub: recipientPub
        )
        let msgId = MessageId.derive(senderNodeId: senderNodeId, identity: identity, plaintext: plaintext)

        // Mutate header priority to BROADCAST while leaving HAS_POW
        let mutatedFlags = UInt16(FrameV2.Flags.sealed) | Priority.toFlags(.broadcast) | UInt16(FrameV2.Flags.has_pow)
        let mutatedFrame = FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: Data(count: 4),
            ttl: 8,
            hopCount: 0,
            flags: mutatedFlags,
            payload: sealed
        )

        let result = router.openSealedMessage(mutatedFrame, ourStaticDhPriv: recipientPriv)
        XCTAssertEqual(result, OpenMessageResult.policyMismatch)
    }

    func testMissingSealedFlagIsRejectedWithMissingSealedFlag() async throws {
        let senderNodeId = Data((0..<16).map { UInt8($0) })
        let router = Router(selfNodeId: senderNodeId)

        let recipientPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPriv = recipientPrivKey.rawRepresentation
        let recipientPub = recipientPrivKey.publicKey.rawRepresentation
        let recipientNodeId = Data(repeating: 0x55, count: 16)

        let frame = try await router.authorSealedMessage(
            plaintext: Data("test".utf8),
            recipientNodeId: recipientNodeId,
            recipientStaticPub: recipientPub
        )
        let unsealedFrame = FrameV2(
            type: frame.type,
            msgId: frame.msgId,
            routingTag: frame.routingTag,
            ttl: frame.ttl,
            hopCount: frame.hopCount,
            flags: frame.flags & ~UInt16(FrameV2.Flags.sealed),
            payload: frame.payload
        )

        let result = router.openSealedMessage(unsealedFrame, ourStaticDhPriv: recipientPriv)
        XCTAssertEqual(result, OpenMessageResult.missingSealedFlag)
    }

    func testWrongFrameTypeIsRejectedWithWrongFrameType() async throws {
        let senderNodeId = Data((0..<16).map { UInt8($0) })
        let router = Router(selfNodeId: senderNodeId)

        let recipientPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPriv = recipientPrivKey.rawRepresentation
        let recipientPub = recipientPrivKey.publicKey.rawRepresentation
        let recipientNodeId = Data(repeating: 0x55, count: 16)

        let frame = try await router.authorSealedMessage(
            plaintext: Data("test".utf8),
            recipientNodeId: recipientNodeId,
            recipientStaticPub: recipientPub
        )
        let sosFrame = FrameV2(
            type: .sos,
            msgId: frame.msgId,
            routingTag: frame.routingTag,
            ttl: frame.ttl,
            hopCount: frame.hopCount,
            flags: frame.flags,
            payload: frame.payload
        )

        let result = router.openSealedMessage(sosFrame, ourStaticDhPriv: recipientPriv)
        XCTAssertEqual(result, OpenMessageResult.wrongFrameType)
    }

    func testDirectMessageWithHasPowFlagIsRejectedWithPolicyMismatch() async throws {
        let senderNodeId = Data((0..<16).map { UInt8($0) })
        let router = Router(selfNodeId: senderNodeId)

        let recipientPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPriv = recipientPrivKey.rawRepresentation
        let recipientPub = recipientPrivKey.publicKey.rawRepresentation
        let recipientNodeId = Data(repeating: 0x55, count: 16)

        let frame = try await router.authorSealedMessage(
            plaintext: Data("test".utf8),
            recipientNodeId: recipientNodeId,
            recipientStaticPub: recipientPub,
            priority: .direct
        )
        let invalidFrame = FrameV2(
            type: frame.type,
            msgId: frame.msgId,
            routingTag: frame.routingTag,
            ttl: frame.ttl,
            hopCount: frame.hopCount,
            flags: frame.flags | UInt16(FrameV2.Flags.has_pow),
            payload: frame.payload
        )

        let result = router.openSealedMessage(invalidFrame, ourStaticDhPriv: recipientPriv)
        XCTAssertEqual(result, OpenMessageResult.policyMismatch)
    }

    func testDirectMessageWithNonZeroPowNonceIsRejectedWithPolicyMismatch() async throws {
        let senderNodeId = Data((0..<16).map { UInt8($0) })
        let router = Router(selfNodeId: senderNodeId)

        let recipientPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPriv = recipientPrivKey.rawRepresentation
        let recipientPub = recipientPrivKey.publicKey.rawRepresentation

        let identity = LogicalMessageIdentity.createNew()
        let badPowNonce = Data(repeating: 0x01, count: 8)
        let plaintext = Data("test".utf8)
        var sealedInner = Data()
        sealedInner.append(identity.messageNonce)
        sealedInner.append(badPowNonce)
        sealedInner.append(identity.createdAtLe())
        sealedInner.append(UInt8(Priority.direct.rawValue))
        sealedInner.append(plaintext)

        let sealed = try SealedSender.seal(
            plaintext: sealedInner,
            senderNodeId: senderNodeId,
            recipientStaticPub: recipientPub
        )
        let msgId = MessageId.derive(senderNodeId: senderNodeId, identity: identity, plaintext: plaintext)
        let frame = FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: Data(count: 4),
            ttl: 8,
            hopCount: 0,
            flags: UInt16(FrameV2.Flags.sealed) | Priority.toFlags(.direct),
            payload: sealed
        )

        let result = router.openSealedMessage(frame, ourStaticDhPriv: recipientPriv)
        XCTAssertEqual(result, OpenMessageResult.policyMismatch)
    }

    func testInvalidSealedPriorityCodeIsRejectedWithPolicyMismatch() async throws {
        let senderNodeId = Data((0..<16).map { UInt8($0) })
        let router = Router(selfNodeId: senderNodeId)

        let recipientPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPriv = recipientPrivKey.rawRepresentation
        let recipientPub = recipientPrivKey.publicKey.rawRepresentation

        let identity = LogicalMessageIdentity.createNew()
        let powNonce = Data(count: 8)
        let plaintext = Data("test".utf8)
        var sealedInner = Data()
        sealedInner.append(identity.messageNonce)
        sealedInner.append(powNonce)
        sealedInner.append(identity.createdAtLe())
        sealedInner.append(UInt8(0)) // SOS priority code 0 (invalid for sealed MESSAGE)
        sealedInner.append(plaintext)

        let sealed = try SealedSender.seal(
            plaintext: sealedInner,
            senderNodeId: senderNodeId,
            recipientStaticPub: recipientPub
        )
        let msgId = MessageId.derive(senderNodeId: senderNodeId, identity: identity, plaintext: plaintext)
        let frame = FrameV2(
            type: .message,
            msgId: msgId,
            routingTag: Data(count: 4),
            ttl: 8,
            hopCount: 0,
            flags: UInt16(FrameV2.Flags.sealed) | Priority.toFlags(.direct),
            payload: sealed
        )

        let result = router.openSealedMessage(frame, ourStaticDhPriv: recipientPriv)
        XCTAssertEqual(result, OpenMessageResult.policyMismatch)
    }

    func testTruncatedSealedInnerPayloadIsRejectedWithMalformed() async throws {
        let senderNodeId = Data((0..<16).map { UInt8($0) })
        let router = Router(selfNodeId: senderNodeId)

        let recipientPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let recipientPriv = recipientPrivKey.rawRepresentation
        let recipientPub = recipientPrivKey.publicKey.rawRepresentation

        let shortInner = Data(count: 20) // < 29 bytes
        let sealed = try SealedSender.seal(
            plaintext: shortInner,
            senderNodeId: senderNodeId,
            recipientStaticPub: recipientPub
        )
        let frame = FrameV2(
            type: .message,
            msgId: Data(count: 16),
            routingTag: Data(count: 4),
            ttl: 8,
            hopCount: 0,
            flags: UInt16(FrameV2.Flags.sealed) | Priority.toFlags(.direct),
            payload: sealed
        )

        let result = router.openSealedMessage(frame, ourStaticDhPriv: recipientPriv)
        XCTAssertEqual(result, OpenMessageResult.malformed)
    }

    func testAuthorSealedMessageConcurrentSendsToAliceAndBob() async throws {
        let senderNodeId = Data((0..<16).map { UInt8($0) })
        let router = Router(selfNodeId: senderNodeId)

        let alicePrivKey = Curve25519.KeyAgreement.PrivateKey()
        let alicePriv = alicePrivKey.rawRepresentation
        let alicePub = alicePrivKey.publicKey.rawRepresentation
        let aliceNodeId = Data(repeating: 0x11, count: 16)

        let bobPrivKey = Curve25519.KeyAgreement.PrivateKey()
        let bobPriv = bobPrivKey.rawRepresentation
        let bobPub = bobPrivKey.publicKey.rawRepresentation
        let bobNodeId = Data(repeating: 0x22, count: 16)

        let content = Data("rendezvous at checkpoint 4".utf8)
        let frameAlice = try await router.authorSealedMessage(
            plaintext: content,
            recipientNodeId: aliceNodeId,
            recipientStaticPub: alicePub
        )
        let frameBob = try await router.authorSealedMessage(
            plaintext: content,
            recipientNodeId: bobNodeId,
            recipientStaticPub: bobPub
        )

        XCTAssertNotEqual(frameAlice.msgId, frameBob.msgId)

        let resAlice = router.openSealedMessage(frameAlice, ourStaticDhPriv: alicePriv)
        let resBob = router.openSealedMessage(frameBob, ourStaticDhPriv: bobPriv)

        guard case .accepted = resAlice, case .accepted = resBob else {
            XCTFail("Both Alice and Bob messages must be Accepted")
            return
        }
    }
}

/// A `MessageStore` whose `persist` always fails -- exercises the persist-result
/// gate in `Router.ingest` without touching sqlite3.
private final class FailingStore: MessageStore {
    func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult { .failedStorage }
    func allHeldOrderedByPriority() -> [FrameV2] { [] }
    func allHeldMsgIds() -> [Data] { [] }
    func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {}
    func forEachHeldMsgId(_ visit: (Data) -> Bool) {}
    var heldBytes: Int64 { 0 }
}

/// B1 test fake: the first persist of a given msg_id FAILS (`.failedStorage`),
/// subsequent ones delegate to a backing [InMemoryMessageStore] (`.heldNew` then
/// `.heldDuplicate`). Mirrors a store that recovers after a transient failure:
/// the same msg_id must be re-acceptable, proving the failed first attempt did
/// not poison the dedup window.
private final class FailThenSucceedStore: MessageStore {
    private let backing = InMemoryMessageStore()
    private let lock = NSLock()
    private var attempts: [Data: Int] = [:]

    func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult {
        lock.lock()
        let n = (attempts[frame.msgId] ?? 0) + 1
        attempts[frame.msgId] = n
        lock.unlock()
        if n == 1 { return .failedStorage }   // first attempt: storage unavailable
        return backing.persist(frame, receivedFrom: receivedFrom)   // retry: held
    }

    func allHeldOrderedByPriority() -> [FrameV2] { backing.allHeldOrderedByPriority() }
    func allHeldMsgIds() -> [Data] { backing.allHeldMsgIds() }
    func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {
        backing.forEachHeldOrderedByPriority(visit)
    }
    func forEachHeldMsgId(_ visit: (Data) -> Bool) { backing.forEachHeldMsgId(visit) }
    var heldBytes: Int64 { backing.heldBytes }
}