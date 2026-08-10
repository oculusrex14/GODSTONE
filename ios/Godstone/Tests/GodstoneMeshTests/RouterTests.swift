import XCTest
@testable import GodstoneMesh
import GodstoneCore

final class RouterTests: XCTestCase {
    private static let routingTag = Data(repeating: 0x01, count: 4)

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
        let router = Router()
        let f = frame("msg-1")
        XCTAssertTrue(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
        XCTAssertFalse(router.ingest(f, isAddressedToMe: false, receivedFrom: Data()))
    }

    func testTtlAndHopCountChangeOnRelay() throws {
        let router = Router()
        XCTAssertTrue(router.ingest(frame("msg-2", ttl: 5), isAddressedToMe: false, receivedFrom: Data()))
        let relayed = try XCTUnwrap(router.drain(limit: 1).first)
        XCTAssertEqual(relayed.ttl, 4)
        XCTAssertEqual(relayed.hopCount, 1)
    }

    func testSosIsDeliveredLocallyAndStillRelayed() {
        let router = Router()
        var delivered: FrameV2?
        router.onDeliverLocally = { delivered = $0 }

        let sos = frame("msg-sos", ttl: 8, type: .sos,
                        flags: UInt16(FrameV2.Flags.ack_req | FrameV2.Flags.relay_ok))
        XCTAssertTrue(router.ingest(sos, isAddressedToMe: true, receivedFrom: Data()))
        XCTAssertEqual(delivered?.type, .sos)
        XCTAssertFalse(router.drain(limit: 8).isEmpty)
    }

    func testNonSosLocalDeliveryDoesNotRelay() {
        let router = Router()
        XCTAssertTrue(router.ingest(frame("local"), isAddressedToMe: true, receivedFrom: Data()))
        XCTAssertTrue(router.drain(limit: 8).isEmpty)
    }

    /// Stage 4B: with a durable store attached the digest is built from the
    /// store's held msg_ids (ADR-004 criterion 6), not the dedup window. A
    /// duplicate ingest does not change the held set, so the digest is stable,
    /// and the held msg_id is present in the 512-byte filter.
    func testBloomDigestIsStableAcrossDuplicate() {
        let router = Router()
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
        let router = Router()
        let digest = router.bloomDigest()
        XCTAssertEqual(digest.count, 512)
        XCTAssertEqual(digest, Data(repeating: 0, count: 512))
    }

    /// Stage 4B: persist before forward (ADR-004). A novel accepted frame is
    /// durably held AND forwarded to the relay queue.
    func testIngestPersistsBeforeForwardWhenStoreAttached() {
        let router = Router()
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
        let router = Router()
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
        let router = Router()
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
        let router = Router()
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
        let router = Router(seenCacheCapacity: 2)
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

    /// B1: at-most-once forwarding under concurrency. N "simultaneous" arrivals
    /// of the same msg_id must result in exactly one accept, one forward and one
    /// durable hold. The router lock serialises the accept decision; the first
    /// persist returns .heldNew (forward + seen.insert), the rest are duplicates.
    func testConcurrentSameMsgIdForwardsAtMostOnce() {
        let store = InMemoryMessageStore()
        let router = Router()
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