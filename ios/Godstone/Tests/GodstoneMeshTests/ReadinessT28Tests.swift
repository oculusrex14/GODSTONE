import XCTest
@testable import GodstoneMesh

// ---------------------------------------------------------------------------
// T28 - the CANONICAL designated regression court, iOS side. The manifest
// required_regression_paths names this file; the narrow filter is
// `swift test --filter ReadinessT28Tests`. It drives the iOS twin authority
// (GodstoneMesh/UnifiedRuntimeLifecycle) through a fake transport seam that
// records EVERY OS-boundary call, so the required lifecycle laws are executed:
// repeated start/stop, background cannot start a stopped runtime (no OS calls),
// power loss / permission revocation uniformly invalidate and are terminal (never
// READY), a lifecycle callback during a wipe is dropped by the retired context,
// the wipe drains before key erasure, and process recreation inherits no session
// and no lease. The android twin ReadinessT28Test.kt asserts the SAME seven
// laws against the same contract; the T28-SM roster strikes the two named
// falsifications on BOTH isles.
// ---------------------------------------------------------------------------

private final class FakeSeam: TransportSeam {
    var scanStarts = 0
    var scanStops = 0
    var advStarts = 0
    var advStops = 0
    var disconnects = 0
    var resets = 0
    var ops: [String] = []
    func startScan() { scanStarts += 1; ops.append("startScan") }
    func stopScan() { scanStops += 1; ops.append("stopScan") }
    func startAdvertising() { advStarts += 1; ops.append("startAdvertising") }
    func stopAdvertising() { advStops += 1; ops.append("stopAdvertising") }
    func disconnectAll() -> Int { disconnects += 1; ops.append("disconnectAll"); return disconnects }
    func resetResources() { resets += 1; ops.append("resetResources") }
    func startsOsCalls() -> Int { scanStarts + advStarts }
}

final class ReadinessT28Tests: XCTestCase {

    private let frozenMillis: Int64 = 1_700_000_000_000

    private func newAuthority(_ fake: FakeSeam, adapterPresent: Bool = true, permissionGranted: Bool = true) -> UnifiedRuntimeLifecycle {
        let t = frozenMillis
        return UnifiedRuntimeLifecycle(seam: fake, nowMillis: { t }, adapterPresent: adapterPresent, permissionGranted: permissionGranted)
    }

    // (1) repeated start is idempotent: one context, one lease, one scan
    func testStartIsIdempotentAndBeginsExactlyOneContext() {
        let fake = FakeSeam()
        let a = newAuthority(fake)
        a.start(); a.start(); a.start()
        XCTAssertEqual(fake.scanStarts, 1, "a repeated start begins the scanner once")
        XCTAssertEqual(fake.advStarts, 1, "a repeated start begins advertising once")
        XCTAssertEqual(a.liveContextCount(), 1, "exactly one live context per activation")
        XCTAssertTrue(a.isReady(), "the authority is READY once started with adapter + permission")
    }

    // (2) BACKGROUND cannot start a STOPPED runtime -- semantic-negative core (T28-SM1 witness)
    func testBackgroundCanNotStartAStoppedRuntimeMakesNoOsCalls() {
        let fake = FakeSeam()
        let a = newAuthority(fake)
        a.start()
        let before = fake.startsOsCalls()
        a.stop()
        XCTAssertFalse(a.isReady(), "the runtime is not READY once stopped")
        a.onBackgrounded(); a.onBackgrounded()
        XCTAssertEqual(fake.startsOsCalls(), before, "a background event on a stopped runtime issues NO OS call")
        XCTAssertFalse(a.isReady(), "still not READY after background churn")
    }

    // (3) power loss mid-run UNIFORMLY invalidates and is terminal, never READY (T28-SM2 witness)
    func testPowerLossUniformlyInvalidatesAndIsTerminalNeverReady() {
        let fake = FakeSeam()
        let a = newAuthority(fake)
        a.start()
        a.onPowerLoss()
        XCTAssertGreaterThanOrEqual(fake.disconnects, 1, "power-off disconnected the transport")
        XCTAssertGreaterThanOrEqual(fake.scanStops, 1, "power-off stopped the scanner")
        XCTAssertGreaterThanOrEqual(fake.advStops, 1, "power-off stopped advertising")
        XCTAssertEqual(a.capabilityState(), .terminalUnavailable, "power-off is a typed terminal capability")
        XCTAssertFalse(a.isReady(), "a powered-off runtime is never READY")
        let after = fake.startsOsCalls()
        a.start()
        a.onBackgrounded()
        XCTAssertEqual(fake.startsOsCalls(), after, "a terminal runtime cannot be restarted into new OS calls")
        XCTAssertFalse(a.isReady(), "still terminal, never READY")
    }

    // (4) permission removal is a typed terminal state, never READY
    func testPermissionRemovalIsTerminalNeverReady() {
        let fake = FakeSeam()
        let a = newAuthority(fake)
        a.start()
        a.onPermissionRemoved()
        XCTAssertEqual(a.capabilityState(), .terminalPermissionRevoked, "revoked permission is a typed terminal capability")
        XCTAssertFalse(a.isReady(), "a permission-revoked runtime is never READY")
        let after = fake.startsOsCalls()
        a.start(); a.onBackgrounded()
        XCTAssertEqual(fake.startsOsCalls(), after, "a revoked runtime cannot be restarted into new OS calls")
        XCTAssertFalse(a.isReady(), "still terminal, never READY")
    }

    // (5) a lifecycle callback arriving during/after the wipe is dropped by the retired context
    func testLifecycleCallbackDuringWipeIsDroppedByRetiredContext() {
        let fake = FakeSeam()
        let a = newAuthority(fake)
        a.start()
        let live = a.snapshotContexts().first!
        let before = fake.startsOsCalls()
        var effectRan = 0
        _ = a.drainForWipe()
        a.deliverToContext(live) { effectRan += 1; fake.startScan() }
        XCTAssertEqual(effectRan, 0, "a retired context forbids all future effects")
        XCTAssertEqual(fake.startsOsCalls(), before, "the dropped callback made no OS call")
        XCTAssertEqual(a.liveContextCount(), 0, "no live context survives the wipe drain")
    }

    // (6) the wipe path drains (retire + disconnect + stop + reset) BEFORE key erasure
    func testWipeDrainsBeforeKeyErasure() {
        let fake = FakeSeam()
        let a = newAuthority(fake)
        a.start()
        fake.ops.removeAll(keepingCapacity: false)
        let drained = a.drainForWipe()
        fake.ops.append("eraseKeys")                       // platform key erasure the caller performs AFTER the drain returns
        guard let eraseIdx = fake.ops.firstIndex(where: { $0 == "eraseKeys" }) else { XCTFail("no erase marker"); return }
        for op in ["disconnectAll", "stopAdvertising", "stopScan", "resetResources"] {
            guard let i = fake.ops.firstIndex(where: { $0 == op }) else { XCTFail("\(op) missing from the drain"); continue }
            XCTAssertLessThan(i, eraseIdx, "the wipe drained \(op) before key erasure")
        }
        XCTAssertTrue(drained.isClean, "the drain reported a clean release")
        XCTAssertFalse(a.isStarted(), "the runtime is no longer started after a wipe drain")
    }

    // (7) process recreation creates NO inherited session and NO inherited lease
    func testProcessRecreationInheritsNoSessionAndNoLease() {
        let fakeA = FakeSeam()
        let a = newAuthority(fakeA)
        a.start()
        let leaseA = a.activeLease()!
        XCTAssertGreaterThanOrEqual(a.liveContextCount(), 1, "a running authority holds a live lease")
        a.stop()
        XCTAssertTrue(leaseA.isReleased, "the old lease is released exactly once on stop")

        let fakeB = FakeSeam()
        let b = newAuthority(fakeB)
        XCTAssertNil(b.activeLease(), "a fresh authority inherits NO lease")
        XCTAssertEqual(b.liveContextCount(), 0, "a fresh authority inherits NO session context")
        b.start()
        let leaseB = b.activeLease()!
        XCTAssertFalse(leaseA === leaseB, "the fresh authority acquires its OWN lease, never the inherited one")
        XCTAssertNotEqual(leaseA.leaseId, leaseB.leaseId, "the fresh lease is a distinct globally-unique token")
        XCTAssertEqual(b.liveContextCount(), 1, "the fresh authority begins exactly one context")
    }

    // ---- integration: the authority composed over the REAL Transport contract via the production adapter ----
    private final class RecordingTransport: Transport {
        var starts = 0
        var stops = 0
        let name = "recording"
        let isBulkCapable = false
        func start() { starts += 1 }
        func stop() { stops += 1 }
    }

    func testAdapterGovernsTheRealTransportAndBackgroundCannotStartAStoppedRuntime() {
        let t = RecordingTransport()
        let a = UnifiedRuntimeLifecycle(seam: LifecycleTransportAdapter(transport: t), nowMillis: { Int64(1_700_000_000_000) })
        a.start()
        XCTAssertEqual(t.starts, 1, "a single activation starts the real transport exactly once")
        a.stop()
        XCTAssertEqual(t.stops, 1, "a drain stops the real transport exactly once")
        let before = t.starts
        a.onBackgrounded(); a.onBackgrounded()
        XCTAssertEqual(t.starts, before, "a background event on a stopped runtime must not re-start the real transport")
    }

    func testAdapterPowerOffUniformlyStopsTheRealTransportAndIsTerminal() {
        let t = RecordingTransport()
        let a = UnifiedRuntimeLifecycle(seam: LifecycleTransportAdapter(transport: t), nowMillis: { Int64(1_700_000_000_000) })
        a.start()
        a.onPowerLoss()
        XCTAssertGreaterThanOrEqual(t.stops, 1, "power-off drove the real transport to stop once (uniform invalidation)")
        XCTAssertFalse(a.isReady(), "a powered-off runtime is never READY")
        let before = t.starts
        a.start(); a.onBackgrounded()
        XCTAssertEqual(t.starts, before, "a terminal runtime cannot re-start the real transport")
        XCTAssertFalse(a.isReady(), "still terminal, never READY")
    }

    func testAdapterRepeatedAuthorityStartStartsTheRealTransportOnce() {
        let t = RecordingTransport()
        let a = UnifiedRuntimeLifecycle(seam: LifecycleTransportAdapter(transport: t), nowMillis: { Int64(1_700_000_000_000) })
        a.start(); a.start(); a.start()
        XCTAssertEqual(t.starts, 1, "repeated authority start issues exactly one real Transport.start")
    }
}
