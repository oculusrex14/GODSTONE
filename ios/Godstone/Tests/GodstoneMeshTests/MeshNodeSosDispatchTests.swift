import XCTest
import CryptoKit
@testable import GodstoneMesh
import GodstoneCore

/// Stage 4B.1 / B4: the iOS SOS dispatch must persist BEFORE any transport
/// operation and report a truthful [SosDispatchResult] (Android parity):
///   - persist fails -> `.notPersisted`, ZERO sends (exit before transport)
///   - persist succeeds + 0 peers -> `.queuedDurably` (durably held, no send)
///   - persist succeeds + N successful sends -> `.handedToRelays(N)`
///
/// These tests exercise the ungated `MeshNode.dispatchSos(payload:send:)` with an
/// injected send closure, so they never touch the lazy `ble` (which would need
/// CoreBluetooth) and never depend on `linkLayerReady` (which is false in
/// production and gates `broadcastSos`). The production `broadcastSos` body is
/// unreachable while `linkLayerReady=false`; these tests pin the logic so that
/// enabling M2-link later cannot expose the old bug (it ignored `router.ingest`'s
/// return and could BLE-send after a persistence failure). The capacity-rejection
/// (`rejectedCapacity`) path shares the same "do not send what you do not durably
/// hold" gate as the failure path and is covered at the store level by the B2
/// tests in `SqliteMessageStoreTests`.
final class MeshNodeSosDispatchTests: XCTestCase {

    /// Build a node with a fresh in-memory identity (CryptoKit default inits
    /// generate fresh keys on the macOS host -- no Keychain needed) and [store].
    private func makeNode(store: MessageStore) -> MeshNode {
        let identity = MeshIdentity(
            signingKey: Curve25519.Signing.PrivateKey(),
            agreementKey: Curve25519.KeyAgreement.PrivateKey())
        return MeshNode(identity: identity, store: store)
    }

    /// B4: persist fails -> `.notPersisted`, ZERO sends. The previous iOS
    /// `broadcastSos` ignored `router.ingest`'s return and could attempt BLE
    /// sends after a persistence failure; this gate exits before any transport op.
    func testDispatchSosPersistFailureReportsNotPersistedAndZeroSends() {
        let node = makeNode(store: AlwaysFailingStore())
        var sendCalls = 0
        let result = node.dispatchSos(payload: Data("SOS".utf8)) { _, _ in
            sendCalls += 1
            return true
        }
        XCTAssertEqual(result, .notPersisted)
        XCTAssertEqual(sendCalls, 0, "persistence failure must exit before any transport operation")
        XCTAssertEqual(node.store.allHeldMsgIds().count, 0, "nothing durably held")
    }

    /// B4: persist succeeds + zero peers -> `.queuedDurably`. The SOS is durably
    /// held (it reaches a peer on the next encounter via anti-entropy) and no
    /// send is attempted because there is no peer to send to.
    func testDispatchSosPersistSucceedsZeroPeersReportsQueuedDurably() {
        let node = makeNode(store: InMemoryMessageStore())
        var sendCalls = 0
        let result = node.dispatchSos(payload: Data("SOS".utf8)) { _, _ in
            sendCalls += 1
            return true
        }
        XCTAssertEqual(result, .queuedDurably)
        XCTAssertEqual(sendCalls, 0, "no peers -> no sends, but durably held")
        XCTAssertEqual(node.store.allHeldMsgIds().count, 1, "SOS durably held")
    }

    /// B4: persist succeeds + N successful sends -> `.handedToRelays(N)`. The SOS
    /// is also durably held (persist runs before the sends).
    func testDispatchSosPersistSucceedsWithNPeersReportsHandedToRelays() {
        let node = makeNode(store: InMemoryMessageStore())
        let peers = (0..<3).map { _ in UUID() }
        for p in peers { node.transportDidConnect(peerId: p) }
        var sentTo: [UUID] = []
        let result = node.dispatchSos(payload: Data("SOS".utf8)) { _, peer in
            sentTo.append(peer); return true
        }
        XCTAssertEqual(result, .handedToRelays(3))
        XCTAssertEqual(Set(sentTo), Set(peers))
        XCTAssertEqual(node.store.allHeldMsgIds().count, 1, "also durably held before sends")
    }

    /// B4: partial sends report the actual count (not the peer count, and not
    /// `.queuedDurably`). One peer of two accepts the record -> `.handedToRelays(1)`.
    func testDispatchSosPartialSendsReportActualCount() {
        let node = makeNode(store: InMemoryMessageStore())
        let p1 = UUID(), p2 = UUID()
        node.transportDidConnect(peerId: p1)
        node.transportDidConnect(peerId: p2)
        let result = node.dispatchSos(payload: Data("SOS".utf8)) { _, peer in
            peer == p1   // only p1 accepts the record
        }
        XCTAssertEqual(result, .handedToRelays(1))
    }
}

/// A `MessageStore` whose `persist` always fails (`.failedStorage`) -- exercises
/// the B4 "persist fails -> notPersisted, zero sends" gate without sqlite3.
private final class AlwaysFailingStore: MessageStore {
    func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult { .failedStorage }
    func allHeldOrderedByPriority() -> [FrameV2] { [] }
    func allHeldMsgIds() -> [Data] { [] }
    func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {}
    func forEachHeldMsgId(_ visit: (Data) -> Bool) {}
    var heldBytes: Int64 { 0 }
}