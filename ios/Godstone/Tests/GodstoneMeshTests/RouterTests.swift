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
}

/// A `MessageStore` whose `persist` always fails -- exercises the persist-result
/// gate in `Router.ingest` without touching sqlite3.
private final class FailingStore: MessageStore {
    func persist(_ frame: FrameV2, receivedFrom: Data) -> Bool { false }
    func allHeldOrderedByPriority() -> [FrameV2] { [] }
    func allHeldMsgIds() -> [Data] { [] }
    func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {}
    func forEachHeldMsgId(_ visit: (Data) -> Bool) {}
    var heldBytes: Int64 { 0 }
}