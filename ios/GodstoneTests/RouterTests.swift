import XCTest
@testable import GodstoneMesh

/// iOS mirror of RouterTest.kt.
///
/// The two implementations are separate code in separate languages and they
/// must behave identically, because they are peers on the same mesh. Any
/// divergence shows up as a message that crosses an Android hop and dies at an
/// iOS one. These tests are deliberately a direct translation.
final class RouterTests: XCTestCase {

    private let peerA = Data(repeating: 0x0A, count: 32)
    private let peerB = Data(repeating: 0x0B, count: 32)
    private let peerC = Data(repeating: 0x0C, count: 32)
    private let peerE = Data(repeating: 0x0E, count: 32)
    private let broadcast = Data(repeating: 0xFF, count: 32)

    private func frame(_ id: String,
                       ttl: UInt8 = 8,
                       destination: Data? = nil) -> Frame {
        var messageId = Data(id.utf8)
        messageId.append(Data(repeating: 0, count: max(0, 16 - messageId.count)))
        return Frame(messageId: messageId.prefix(16),
                     destination: destination ?? peerB,
                     ttl: ttl,
                     payload: Data(repeating: 0, count: 32))
    }

    func testDuplicateMessageIsNotRelayedTwice() {
        let router = Router(selfKey: peerA)
        let f = frame("msg-1")

        XCTAssertTrue(router.onReceive(f, from: peerC).shouldRelay)
        XCTAssertFalse(router.onReceive(f, from: peerE).shouldRelay)
    }

    func testTtlIsDecrementedOnRelay() {
        let router = Router(selfKey: peerA)
        let result = router.onReceive(frame("msg-2", ttl: 5), from: peerC)

        XCTAssertTrue(result.shouldRelay)
        XCTAssertEqual(result.frame?.ttl, 4)
    }

    func testExhaustedTtlIsDropped() {
        let router = Router(selfKey: peerA)
        XCTAssertFalse(router.onReceive(frame("msg-3", ttl: 0), from: peerC).shouldRelay)
    }

    func testFrameForSelfIsDeliveredNotRelayed() {
        let router = Router(selfKey: peerA)
        let result = router.onReceive(frame("msg-4", destination: peerA), from: peerC)

        XCTAssertTrue(result.shouldDeliver)
        XCTAssertFalse(result.shouldRelay)
    }

    func testBroadcastIsDeliveredAndRelayed() {
        let router = Router(selfKey: peerA)
        let result = router.onReceive(frame("msg-5", destination: broadcast), from: peerC)

        XCTAssertTrue(result.shouldDeliver)
        XCTAssertTrue(result.shouldRelay)
    }

    func testSeenCacheStaysBounded() {
        let router = Router(selfKey: peerA, seenCapacity: 4)
        for i in 0..<6 {
            _ = router.onReceive(frame("msg-cap-\(i)"), from: peerC)
        }

        XCTAssertTrue(router.onReceive(frame("msg-cap-0"), from: peerC).shouldRelay)
        XCTAssertFalse(router.onReceive(frame("msg-cap-5"), from: peerC).shouldRelay)
    }

    func testUndeliverableMessageIsQueued() {
        let router = Router(selfKey: peerA)
        router.send(frame("msg-6", destination: peerE))

        XCTAssertEqual(router.pendingCount, 1)
        XCTAssertEqual(router.onPeerAvailable(peerE).count, 1)
        XCTAssertEqual(router.pendingCount, 0)
    }

    func testRelaySuppressedWhenBatteryCritical() {
        let router = Router(selfKey: peerA)
        router.onBatteryLevelChanged(0.04, charging: false)

        XCTAssertFalse(router.onReceive(frame("msg-7"), from: peerC).shouldRelay)
        XCTAssertTrue(router.onReceive(frame("msg-8", destination: peerA),
                                       from: peerC).shouldDeliver)
    }

    func testRelayResumesWhenCharging() {
        let router = Router(selfKey: peerA)
        router.onBatteryLevelChanged(0.04, charging: true)

        XCTAssertTrue(router.onReceive(frame("msg-9"), from: peerC).shouldRelay)
    }
}
