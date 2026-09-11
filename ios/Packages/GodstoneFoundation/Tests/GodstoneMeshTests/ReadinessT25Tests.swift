import XCTest
import Foundation
@testable import GodstoneMesh
import GodstoneCore

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

    // =====================================================================
    // PLATFORM child -- the five required behavioural cases, at the live
    // store<->authority seam (symmetric to the Kotlin court; design A: the same-
    // thread synchronous compute is kept; a generation token + revalidate-before-
    // publish drop a stale in-flight result; the owned lease gates the store
    // callback; a rolled-back commit fire'th no observer so no snapshot is born).
    // =====================================================================

    private func msgId(_ n: Int) -> Data { Data((0..<16).map { j in UInt8((n &* 16 &+ j) % 256) }) }

    private func bloomDigest(_ ids: [Data]) -> Data {
        var b = BloomDigest()
        for id in ids { b.add(id) }
        return Data(b.toBytes().prefix(BleLinkInfoConstants.shortDigestBytes))
    }

    // (7) A GATT read copieth the last committed snapshot WITHOUT touching the
    //     store -- a blocked/unavailable store cannot stall or falsify a read.
    func testTheReadPathCopiethTheCommittedValueEvenWhileTheStoreIsBlocked() throws {
        let identity = try makeIdentity()
        let store = ProbeStoreDouble()
        store.seed([msgId(10), msgId(11)])
        let auth = LinkInfoSnapshotAuthority(identityProvider: { identity }, storeProvider: { store })
        let held0 = auth.currentHeldSnapshot(); XCTAssertNotNil(held0)
        let data0 = auth.currentData(); XCTAssertNotNil(data0)
        let depth0 = auth.currentSnapshot()?.queueDepth
        let traversalsAtPrime = store.traversalCount
        store.blockNextTraversal = true                     // any NEW traversal would fault and visit nothing
        for _ in 0..<64 {
            XCTAssertEqual(held0, auth.currentHeldSnapshot(), "the held-snapshot is a pure copy")
            XCTAssertEqual(data0, auth.currentData(), "the data is a pure copy")
            XCTAssertEqual(depth0, auth.currentSnapshot()?.queueDepth, "the on-wire snapshot is a pure copy")
        }
        XCTAssertEqual(traversalsAtPrime, store.traversalCount, "a read trigger'd NO durable traversal")
    }

    // (8) A nested (reentrant) commit notified DURING a traversal must not let the
    //     stale in-flight result win: the compute that captur'd an older token is
    //     DROPP'D and the latest is published exactly once (bounded re-run).
    func testObserverReentrancyPublishethTheLatestValueExactlyOnce() throws {
        let identity = try makeIdentity()
        let store = ProbeStoreDouble()
        store.seed([msgId(1)])
        let auth = LinkInfoSnapshotAuthority(identityProvider: { identity }, storeProvider: { store })
        let prime = auth.currentHeldSnapshot(); XCTAssertNotNil(prime)
        XCTAssertEqual(prime!.queueDepth, 1, "the prime reflecteth the one seeded item")
        let vBefore = prime!.storeVersion
        let b = msgId(2)
        store.reentrantOnce = { store.held.append(b); store.emitObservers() }   // fires DURING the next traversal
        _ = auth.refresh()
        let snap = auth.currentHeldSnapshot(); XCTAssertNotNil(snap)
        XCTAssertEqual(snap!.queueDepth, 2, "the reentrant latest commit is reflected exactly once")
        XCTAssertEqual(snap!.digest6, bloomDigest(store.held), "the digest covereth both the pre- and mid-traversal item")
        XCTAssertGreaterThan(snap!.storeVersion, vBefore, "the generation advanced past the pre-hook token")
    }

    // (9) A commit that ROLLED BACK fire'th no observer and must change NO snapshot;
    //     only a genuinely committed change advance'th it (the contrast is the proof).
    func testARolledBackCommitCausethNoNewSnapshot() throws {
        let identity = try makeIdentity()
        let store = ProbeStoreDouble()
        store.seed([msgId(20)])
        let auth = LinkInfoSnapshotAuthority(identityProvider: { identity }, storeProvider: { store })
        let before = auth.currentHeldSnapshot()
        let dataBefore = auth.currentData()
        let tr = store.traversalCount
        store.simulateRolledBackCommit([msgId(20), msgId(21)])    // no durable change survives, NO observer fire'n
        XCTAssertEqual(tr, store.traversalCount, "a rolled-back commit fire'th no observer")
        XCTAssertEqual(before, auth.currentHeldSnapshot(), "the snapshot is unchang'd")
        XCTAssertEqual(dataBefore, auth.currentData(), "the bytes are unchang'd")
        store.committed([msgId(20), msgId(21)])                  // contrast: a genuine commit advance'th
        XCTAssertEqual(auth.currentHeldSnapshot()?.queueDepth, 2, "a committed change advance'th the snapshot")
        XCTAssertGreaterThan(auth.currentHeldSnapshot()?.storeVersion ?? 0, before?.storeVersion ?? 0, "and the generation")
    }

    // (10) Repeated runtime start/stop leaveth exactly ONE registration (the grow-only
    //      registry is gated, never re-added); while stopp'd the observation is zero-
    //      active (no recompute); while start'd it observeth again on the same registration.
    func testRepeatedRuntimeStartStopLeavethOneRegistrationThenZeroActive() throws {
        let identity = try makeIdentity()
        let store = ProbeStoreDouble()
        store.seed([msgId(30)])
        let auth = LinkInfoSnapshotAuthority(identityProvider: { identity }, storeProvider: { store })
        XCTAssertEqual(store.registrations, 1, "exactly one registration at construction")
        XCTAssertTrue(auth.isObserving())
        for _ in 0..<3 { auth.stopObserving(); auth.startObserving() }
        XCTAssertEqual(store.registrations, 1, "repeated start/stop addeth no second registration")
        auth.stopObserving()
        XCTAssertFalse(auth.isObserving(), "the lease readeth as stopp'd")
        let trStop = store.traversalCount
        let qStop = auth.currentHeldSnapshot()?.queueDepth
        store.committed([msgId(30), msgId(31)])                  // gated: reacheth no observer effect
        XCTAssertEqual(trStop, store.traversalCount, "while stopp'd the observation is zero-active (no recompute)")
        XCTAssertEqual(qStop, auth.currentHeldSnapshot()?.queueDepth, "the snapshot is frozen while stopp'd")
        auth.startObserving()
        XCTAssertTrue(auth.isObserving(), "the lease readeth as start'd")
        store.committed([msgId(30), msgId(31)])                  // now it recomputeth on the SAME registration
        XCTAssertGreaterThan(store.traversalCount, trStop, "while start'd the observation recomputeth")
        XCTAssertEqual(auth.currentHeldSnapshot()?.queueDepth, 2, "the committed change is reflect'd")
    }

    // (11) The held count saturateth at the one-byte bound (255) and the digest is the
    //      frozen generator over the FULL held set (not a fresh formula).
    func testQueueDepthSaturatethAtTheOneByteBoundViaTheFrozenGenerators() throws {
        let identity = try makeIdentity()
        let store = ProbeStoreDouble()
        let many = (0..<300).map { msgId($0) }
        store.seed(many)
        let auth = LinkInfoSnapshotAuthority(identityProvider: { identity }, storeProvider: { store })
        let held = auth.currentHeldSnapshot(); XCTAssertNotNil(held)
        XCTAssertEqual(held!.queueDepth, 255, "the held count saturateth at the one-byte cap")
        XCTAssertEqual(held!.digest6, bloomDigest(many), "the digest is the frozen generator over the FULL held set")
        XCTAssertEqual(auth.currentSnapshot()?.queueDepth, UInt8(255), "the on-wire snapshot agree'th with the held-snapshot")
    }

    // ---- deterministic double for the store<->authority boundary ----
    private final class ProbeStoreDouble: MessageStore {
        var held: [Data] = []
        private var observers: [@Sendable () -> Void] = []
        private let slock = NSLock()
        var registrations = 0
        var traversalCount = 0
        var blockNextTraversal = false
        var reentrantOnce: (() -> Void)? = nil
        func seed(_ ids: [Data]) { held = ids }
        func committed(_ ids: [Data]) { held = ids; emitObservers() }
        /// Models a transaction that rolled back: no durable change survives, and the store fire'th NO observer.
        func simulateRolledBackCommit(_ ids: [Data]) { /* deliberately inert: no mutation, no notify */ }
        func emitObservers() { slock.lock(); let obs = observers; slock.unlock(); obs.forEach { $0() } }
        func registerHeldSetObserver(_ observer: @escaping @Sendable () -> Void) {
            slock.lock(); observers.append(observer); registrations += 1; slock.unlock()
        }
        func persist(_ frame: FrameV2, receivedFrom: Data) -> PersistResult { .heldNew }
        func enqueueDirectOutbound(_ frame: FrameV2, expectedRecipient: Data, localOriginNodeId: Data) -> OutboundEnqueueResult {
            .canonicalFrameMismatch
        }
        func allHeldOrderedByPriority() -> [FrameV2] { [] }
        func allHeldMsgIds() -> [Data] { slock.lock(); defer { slock.unlock() }; return held }
        func forEachHeldOrderedByPriority(_ visit: (FrameV2) -> Bool) {}
        func forEachHeldMsgId(_ visit: (Data) -> Bool) {
            slock.lock(); let copy = held; slock.unlock()
            traversalCount += 1
            if blockNextTraversal { blockNextTraversal = false; return }        // the store is unavail'able: visit nothing
            for id in copy { if !visit(id) { break } }
            if let hook = reentrantOnce { reentrantOnce = nil; hook() }          // fire the nested commit-notify once
        }
        var heldBytes: Int64 { Int64(held.count &* 32) }
    }

    private func makeIdentity() throws -> MeshIdentity {
        let kc = InMemoryKeychain()
        let edSeed = Data(repeating: 1, count: 32)
        let xPriv = Data(repeating: 2, count: 32)
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: edSeed, x25519PrivateKey: xPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        return try MeshIdentity.loadFromKeychain(keychain: kc)
    }
}
