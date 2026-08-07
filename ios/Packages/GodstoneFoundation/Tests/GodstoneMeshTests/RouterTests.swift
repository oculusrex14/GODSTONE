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
        XCTAssertTrue(router.ingest(f, isAddressedToMe: false))
        XCTAssertFalse(router.ingest(f, isAddressedToMe: false))
    }

    func testTtlAndHopCountChangeOnRelay() throws {
        let router = Router()
        XCTAssertTrue(router.ingest(frame("msg-2", ttl: 5), isAddressedToMe: false))
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
        XCTAssertTrue(router.ingest(sos, isAddressedToMe: true))
        XCTAssertEqual(delivered?.type, .sos)
        XCTAssertFalse(router.drain(limit: 8).isEmpty)
    }

    func testNonSosLocalDeliveryDoesNotRelay() {
        let router = Router()
        XCTAssertTrue(router.ingest(frame("local"), isAddressedToMe: true))
        XCTAssertTrue(router.drain(limit: 8).isEmpty)
    }

    func testBloomDigestIsStableAcrossDuplicate() {
        let router = Router()
        _ = router.ingest(frame("msg-bloom"), isAddressedToMe: false)
        let first = router.bloomDigest()
        XCTAssertEqual(first.count, 512)
        _ = router.ingest(frame("msg-bloom"), isAddressedToMe: false)
        XCTAssertEqual(first, router.bloomDigest())
    }
}
