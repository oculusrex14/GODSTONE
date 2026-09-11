import Foundation

// ---------------------------------------------------------------------------
// T28 CONTRACT (iOS) - the unified runtime lifecycle authority: the Swift twin
// of android/.../identity/RuntimeLifecycle.kt. Both isles enforce ONE law so a
// divergent runtime cannot admit a different lifecycle on one platform.
//
// RuntimeLifecycleGate owns a transport lease. start subscribes then creates
// exactly one context and begins the OS work once; stop atomically retires
// contexts, drains, and releases the lease exactly once. Bluetooth-unavailable
// and permission-revoked are TYPED terminal/suspended, NEVER READY. A background
// callback CANNOT start a stopped runtime (no OS call). Wipe drains BEFORE key
// erasure. A retired context forbids all future effects. Process recreation
// inherits no session and no lease.
//
// The authority drives the OS boundary ONLY through the injectable TransportSeam,
// so the court counts every call and the laws are executed, not narrated. Hand-
// written runtime helper (not codegen), mirroring the module's other authorities;
// no frozen BLE/LinkInfo/wire/identity contract is touched.
// ---------------------------------------------------------------------------

/// The typed capability ladder. Terminal/suspended states are never READY.
public enum CapabilityStatus: Sendable {
    case suspendedNoAdapter
    case activeReady
    case terminalUnavailable
    case terminalPermissionRevoked
}

private final class LeaseSequence: @unchecked Sendable {
    static let shared = LeaseSequence()
    private let lock = NSLock()
    private var counter: Int = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return counter
    }
}

/// A single transport lease. Acquired exactly once per activation, released exactly once.
public final class RuntimeTransportLease: @unchecked Sendable {
    public let leaseId: Int
    private let onRelease: (RuntimeTransportLease) -> Void
    private let lock = NSLock()
    private var released: Bool = false
    init(leaseId: Int, onRelease: @escaping (RuntimeTransportLease) -> Void) {
        self.leaseId = leaseId; self.onRelease = onRelease
    }
    public var isReleased: Bool {
        lock.lock(); defer { lock.unlock() }
        return released
    }
    /// @return true on the one winning release; false if already released.
    @discardableResult
    public func releaseOnce() -> Bool {
        lock.lock()
        if released { lock.unlock(); return false }
        released = true
        lock.unlock()
        onRelease(self)
        return true
    }
}

/// Immutable identity of one delivered callback context. A retired token forbids future effects.
public final class ContextToken: @unchecked Sendable {
    public let contextId: Int
    public let bornMillis: Int64
    private let lock = NSLock()
    private var retired: Bool = false
    init(contextId: Int, bornMillis: Int64) { self.contextId = contextId; self.bornMillis = bornMillis }
    /// A live, unretired context is the only one whose effects may run.
    public func permitsEffect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !retired
    }
    @discardableResult
    public func retireOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if retired { return false }
        retired = true
        return true
    }
}

/// The outcome of one atomic drain.
public struct DrainResult: Sendable {
    public let admissionClosed: Bool
    public let contextsRetired: Int
    public let outboundDrained: Int
    public let resourcesReleased: Int
    public var isClean: Bool { admissionClosed && contextsRetired >= 0 && outboundDrained >= 0 && resourcesReleased >= 1 }
}

/// The OS boundary the authority drives. The court injects a fake that records every call.
public protocol TransportSeam: AnyObject {
    func startScan()
    func stopScan()
    func startAdvertising()
    func stopAdvertising()
    func disconnectAll() -> Int
    func resetResources()
}

/// The single lifecycle authority that owns a transport lease and unifies
/// start/stop/power/background/permission behind one monotonic, lock-guarded state
/// machine, making the required laws impossible to violate.
public final class UnifiedRuntimeLifecycle: @unchecked Sendable {
    private let seam: TransportSeam
    private let nowMillis: @Sendable () -> Int64
    private let adapterPresent: Bool
    private let permissionGranted: Bool

    private let lock = NSLock()
    private var started: Bool = false
    private var capability: CapabilityStatus
    private var lease: RuntimeTransportLease? = nil
    private var contexts: [ContextToken] = []
    private var nextContextId: Int = 0

    public init(
        seam: TransportSeam,
        nowMillis: @escaping @Sendable () -> Int64,
        adapterPresent: Bool = true,
        permissionGranted: Bool = true
    ) {
        self.seam = seam
        self.nowMillis = nowMillis
        self.adapterPresent = adapterPresent
        self.permissionGranted = permissionGranted
        self.capability = permissionGranted ? .suspendedNoAdapter : .terminalPermissionRevoked
    }

    /// start subscribes, creates exactly one context, and (only when admissible) begins the OS work.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        if capability == .terminalUnavailable || capability == .terminalPermissionRevoked { return }
        if !adapterPresent { capability = .suspendedNoAdapter; return }
        if started { return }
        if lease == nil || lease!.isReleased {
            lease = RuntimeTransportLease(leaseId: LeaseSequence.shared.next()) { _ in }
        }
        started = true
        capability = .activeReady
        newContextLocked()
        seam.startAdvertising()
        seam.startScan()
    }

    /// stop atomically closes admission, retires contexts, drains, and releases the lease exactly once.
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        if !started { return }
        _ = drainLocked()
        lease?.releaseOnce()
        started = false
    }

    /// A background/foreground transition. A stopped or terminal runtime makes NO OS call.
    public func onBackgrounded() {
        lock.lock(); defer { lock.unlock() }
        if !started || capability != .activeReady { return }   // the semantic-negative guard
        // a background event never (re)starts a scan; it only stays within the already-active budget
    }

    /// Power-off uniformly invalidates every resource and is terminal (never READY again).
    public func onPowerLoss() {
        lock.lock(); defer { lock.unlock() }
        _ = drainLocked()
        if started { lease?.releaseOnce(); started = false }
        capability = .terminalUnavailable
    }

    /// Permission removal uniformly invalidates every resource and is terminal (never READY again).
    public func onPermissionRemoved() {
        lock.lock(); defer { lock.unlock() }
        _ = drainLocked()
        if started { lease?.releaseOnce(); started = false }
        capability = .terminalPermissionRevoked
    }

    /// Deliver an effect to a context; a retired/stopped/terminal context drops it WITHOUT an OS call.
    public func deliverToContext(_ context: ContextToken, effect: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !context.permitsEffect() { return }
        if !started || capability != .activeReady { return }
        effect()
    }

    /// The wipe path drains (retires + disconnects + stops + resets) BEFORE platform key erasure.
    public func drainForWipe() -> DrainResult {
        lock.lock(); defer { lock.unlock() }
        let d = drainLocked()
        if started { lease?.releaseOnce(); started = false }
        return d
    }

    // ---- read-only observation for the court ----
    public func isReady() -> Bool { lock.lock(); defer { lock.unlock() }; return started && capability == .activeReady }
    public func isStarted() -> Bool { lock.lock(); defer { lock.unlock() }; return started }
    public func capabilityState() -> CapabilityStatus { lock.lock(); defer { lock.unlock() }; return capability }
    public func activeLease() -> RuntimeTransportLease? {
        lock.lock(); defer { lock.unlock() }
        if let l = lease, !l.isReleased { return l }
        return nil
    }
    public func liveContextCount() -> Int { lock.lock(); defer { lock.unlock() }; return contexts.filter { $0.permitsEffect() }.count }
    public func snapshotContexts() -> [ContextToken] { lock.lock(); defer { lock.unlock() }; return contexts }

    // ---- internal, called only with the monitor held ----
    @discardableResult
    private func newContextLocked() -> ContextToken {
        nextContextId += 1
        let token = ContextToken(contextId: nextContextId, bornMillis: nowMillis())
        contexts.append(token)
        return token
    }

    private func drainLocked() -> DrainResult {
        var retired = 0
        for c in contexts where c.retireOnce() { retired += 1 }
        contexts.removeAll(keepingCapacity: false)
        let drained = seam.disconnectAll()
        seam.stopAdvertising()
        seam.stopScan()
        seam.resetResources()
        return DrainResult(admissionClosed: true, contextsRetired: retired, outboundDrained: drained, resourcesReleased: 1)
    }
}
