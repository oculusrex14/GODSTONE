// SYNTHESIZED gap-closure file -- authored to make the project compile; see docs/AUDIT.md.

import XCTest
@testable import GodstoneMesh
import GodstoneCore

/// iOS mirror of RouterTest.kt.
///
/// The two implementations are separate code in separate languages and they
/// must behave identically, because they are peers on the same mesh. Any
/// divergence shows up as a message that crosses an Android hop and dies at an
/// iOS one. These tests are deliberately a direct translation -- exercised
/// against the shipped `Router` API (`ingest` / `drain` / `bloomDigest`), not
/// the earlier `selfKey` / `onReceive` sketch that was retired when the Router
/// was reshaped to its epidemic-relay form.
final class RouterTests: XCTestCase {

    private static let routingTag = Data(repeating: 0x01, count: 4)

    /// Builds a 16-byte message id from a string tag, zero-padded / truncated.
    private func frame(_ id: String,
                       ttl: UInt8 = 8,
                       type: Frame.FrameType = .direct,
                       flags: Frame.Flags = []) -> Frame {
        var messageId = Data(id.utf8)
        if messageId.count < 16 {
            messageId.append(Data(repeating: 0, count: 16 - messageId.count))
        }
        return Frame(type: type,
                     ttl: ttl,
                     flags: flags,
                     messageId: messageId.prefix(16),
                     routingTag: RouterTests.routingTag,
                     payload: Data(repeating: 0, count: 32))
    }

    func testIngestReturnsTrueFirstTimeFalseOnDuplicate() {
        let router = Router()
        let f = frame("msg-1")

        XCTAssertTrue(router.ingest(f, isAddressedToMe: false),
                      "first sighting of a frame must be accepted")
        XCTAssertFalse(router.ingest(f, isAddressedToMe: false),
                       "duplicate sighting must be suppressed -- dedup is what " +
                       "stops an epidemic protocol from melting the network")
    }

    func testTtlIsDecrementedOnRelay() {
        let router = Router()
        XCTAssertTrue(router.ingest(frame("msg-2", ttl: 5), isAddressedToMe: false))

        let drained = router.drain(limit: 1)
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?.ttl, 4,
                       "a relayed frame must have its ttl decremented by one")
    }

    func testSosIsDeliveredLocallyAndStillRelayed() {
        let router = Router()
        var delivered: Frame?
        router.onDeliverLocally = { delivered = $0 }

        let sos = frame("msg-sos", ttl: 8, type: .sos)
        XCTAssertTrue(router.ingest(sos, isAddressedToMe: true),
                      "SOS addressed to me must be accepted")
        XCTAssertEqual(delivered?.type, .sos,
                       "SOS addressed to me must fire onDeliverLocally")

        // SOS is still relayed after local delivery: someone further away may be
        // the one who can actually help, so the relay queue must not be empty.
        XCTAssertFalse(router.drain(limit: 8).isEmpty,
                       "SOS must remain queued for relay after local delivery")
    }

    func testBloomDigestIsNonEmptyAndStableAcrossReingest() {
        let router = Router()
        _ = router.ingest(frame("msg-bloom"), isAddressedToMe: false)

        let digest1 = router.bloomDigest()
        XCTAssertFalse(digest1.isEmpty,
                       "bloom digest must contain a held frame's message id")

        // Re-ingesting the same id is a no-op against the seen-set, so the
        // digest must not change -- a drifting digest would cause peers to
        // needlessly re-send frames we already hold.
        _ = router.ingest(frame("msg-bloom"), isAddressedToMe: false)
        let digest2 = router.bloomDigest()
        XCTAssertEqual(digest1, digest2,
                       "re-ingesting a seen id must keep the bloom digest stable")
    }
}
