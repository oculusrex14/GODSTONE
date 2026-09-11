import XCTest
import Foundation
@testable import GodstoneMesh

// ---------------------------------------------------------------------------
// T25 - the CANONICAL designated regression court (iOS), the symmetric twin of
// ReadinessT25Test.kt and the file the manifest's required_regression_paths +
// the narrow filter `--filter ReadinessT25Tests` name. It covereth the CONTRACT
// layer: HeldSnapshot and SnapshotObservationLease (widths REUSE'D from the
// frozen BleLinkInfoConstants; single-release / inert-closed law). Idiom note:
// iOS storeVersion is UInt64 (inherently nonnegative), the android Long use'th a
// require >= 0; the two refuse the selfsame malformed forms.
// ---------------------------------------------------------------------------

final class ReadinessT25Tests: XCTestCase {

    private func octets(_ count: Int, _ fill: UInt8) -> Data { Data([UInt8](repeating: fill, count: count)) }
    private func hint(_ fill: UInt8) -> Data { octets(BleLinkInfoConstants.nodeHintBytes, fill) }
    private func digest(_ fill: UInt8) -> Data { octets(BleLinkInfoConstants.shortDigestBytes, fill) }
    private func ramp(_ count: Int, _ base: UInt8) -> Data { Data((0..<count).map { base + UInt8($0) }) }

    private func snapshot(_ v: UInt64, _ h: Data, _ d: Data, _ q: Int,
                          file: StaticString = #file, line: UInt = #line) -> HeldSnapshot {
        guard let s = HeldSnapshot(storeVersion: v, hint4: h, digest6: d, queueDepth: q) else {
            XCTFail("expected a well-form'd snapshot to be accepted", file: file, line: line)
            fatalError("no snapshot")
        }
        return s
    }

    // (1) A malformed form is refus'd (nil): a wrong-width hint or digest.
    func testAHeldSnapshotRefusethAMalformedForm() throws {
        XCTAssertNotNil(HeldSnapshot(storeVersion: 0, hint4: hint(7), digest6: digest(9), queueDepth: 0),
                        "a well-form'd form is accept'd")
        XCTAssertNil(HeldSnapshot(storeVersion: 0, hint4: octets(BleLinkInfoConstants.nodeHintBytes - 1, 0), digest6: digest(9), queueDepth: 0),
                     "a short hint is refus'd")
        XCTAssertNil(HeldSnapshot(storeVersion: 0, hint4: octets(BleLinkInfoConstants.nodeHintBytes + 1, 0), digest6: digest(9), queueDepth: 0),
                     "a long hint is refus'd")
        XCTAssertNil(HeldSnapshot(storeVersion: 0, hint4: hint(7), digest6: octets(BleLinkInfoConstants.shortDigestBytes - 1, 0), queueDepth: 0),
                     "a short digest is refus'd")
        XCTAssertNil(HeldSnapshot(storeVersion: 0, hint4: hint(7), digest6: octets(BleLinkInfoConstants.shortDigestBytes + 1, 0), queueDepth: 0),
                     "a long digest is refus'd")
    }

    // (2) The form carrieth the canonical octets with value (copy) semantics:
    //     sledge'ing the caller's Data after construction doth not alter it.
    func testAHeldSnapshotCarriethTheFormsDefensivelyCopied() throws {
        let expectH = ramp(BleLinkInfoConstants.nodeHintBytes, 1)      // 1,2,3,4
        let expectD = ramp(BleLinkInfoConstants.shortDigestBytes, 2)   // 2,3,4,5,6,7
        var h = expectH
        var d = expectD
        let s = snapshot(3, h, d, 10)
        h[h.startIndex] = 0x7F
        d[d.startIndex] = 0x7F                                          // sledge the caller's copies
        XCTAssertEqual(s.hint4, expectH, "the stored hint is the value at construction, not the sledge'd caller array")
        XCTAssertEqual(s.digest6, expectD, "the stored digest is the value at construction, not the sledge'd caller array")
    }

    // (3) queueDepth is confin'd to the one on-wire byte (0..255).
    func testAHeldSnapshotConfinethQueueDepthToOneByte() throws {
        XCTAssertNotNil(HeldSnapshot(storeVersion: 0, hint4: hint(0), digest6: digest(0), queueDepth: 0), "zero is representable")
        XCTAssertNotNil(HeldSnapshot(storeVersion: 0, hint4: hint(0), digest6: digest(0), queueDepth: 255), "the saturating cap 255 is representable")
        XCTAssertNil(HeldSnapshot(storeVersion: 0, hint4: hint(0), digest6: digest(0), queueDepth: 256), "256 overflow'th the one-byte field and is refus'd")
        XCTAssertNil(HeldSnapshot(storeVersion: 0, hint4: hint(0), digest6: digest(0), queueDepth: -1), "a negative depth is refus'd")
    }

    // (4) Two snapshots compare by CONTENT, not by identity.
    func testTwoHeldSnapshotsCompareByContentNotIdentity() throws {
        let a = snapshot(5, hint(7), digest(9), 42)
        let b = snapshot(5, hint(7), digest(9), 42)
        XCTAssertEqual(a, b, "equal by content")
        XCTAssertEqual(a.hashValue, b.hashValue, "and equal in hash")
        XCTAssertNotEqual(a, snapshot(5, hint(7), digest(0xFF), 42), "a differant digest breaketh equality")
        XCTAssertNotEqual(a, snapshot(5, hint(0xFF), digest(9), 42), "a differant hint breaketh equality")
        XCTAssertNotEqual(a, snapshot(6, hint(7), digest(9), 42), "a differant generation breaketh equality")
        XCTAssertNotEqual(a, snapshot(5, hint(7), digest(9), 41), "a differant depth breaketh equality")
    }

    // (5) The lease is born active; the FIRST close performeth the transition and
    //     the one release; further closes are inert no-ops (release EXACTLY once).
    func testALeaseOpensActiveAndClosesthExactlyOnceIdempotently() throws {
        var releases = 0
        let lease = SnapshotObservationLease(onRelease: { releases += 1 })
        XCTAssertTrue(lease.isActive, "born active")
        XCTAssertEqual(lease.closeCount, 0, "not yet clos'd")
        XCTAssertTrue(lease.close(), "the first close transitioneth")
        XCTAssertEqual(releases, 1, "the release fired once")
        XCTAssertFalse(lease.close(), "a second close is a no-op")
        XCTAssertFalse(lease.close(), "a third close is a no-op")
        XCTAssertEqual(releases, 1, "the release fired EXACTLY once")
        XCTAssertEqual(lease.closeCount, 1, "closeCount is one")
        XCTAssertFalse(lease.isActive, "the lease is now inert")
    }

    // (6) After close the lease is INERT: a stale notification that consulteth
    //     isActive driveth NO compute; an active lease's gate admisseth one.
    func testAClosedLeaseIsInertToAStaleNotification() throws {
        var releases = 0
        var computes = 0
        let lease = SnapshotObservationLease(onRelease: { releases += 1 })
        XCTAssertTrue(lease.close())
        if lease.isActive { computes += 1 }
        XCTAssertEqual(computes, 0, "a stale notification upon a closed lease driveth no compute")
        XCTAssertEqual(releases, 1, "and no second release")
        let live = SnapshotObservationLease(onRelease: {})
        if live.isActive { computes += 1 }
        XCTAssertEqual(computes, 1, "an active lease's gate admisseth exactly one compute")
    }
}
