import Foundation
import GodstoneCore

// ---------------------------------------------------------------------------
// T25 contract layer (iOS), the symmetric twin of LinkInfoSnapshotTypes.kt.
// Two ADDITIVE types mandated by the T25 card's Required design / Interfaces:
//     HeldSnapshot{ storeVersion, hint4, digest6, queueDepth }
//     SnapshotObservationLease
// Purely additive: no behaviour added to the running system, no frozen contract
// touch'd. The widths are REUSE'D from the frozen BleLinkInfoConstants
// (nodeHintBytes, shortDigestBytes) -- referenced, NEVER re-derived.
// ---------------------------------------------------------------------------

/// An immutable, atomically-publishable snapshot of the held set. GATT reads
/// receiv'e a copy of the last committed value; the compute that produceth it
/// runneth on the store executor after commit (the platform child wires that).
/// Data is a value type, so the canonical octets are carried with copy semantics.
public struct HeldSnapshot: Equatable, Hashable, Sendable {
    public let storeVersion: UInt64
    public let hint4: Data
    public let digest6: Data
    public let queueDepth: Int

    /// Failable: a wrong-width hint/digest or an out-of-range depth is refus'd
    /// (nil), so a malformed form never entereth circulation.
    public init?(storeVersion: UInt64, hint4: Data, digest6: Data, queueDepth: Int) {
        guard hint4.count == BleLinkInfoConstants.nodeHintBytes else { return nil }
        guard digest6.count == BleLinkInfoConstants.shortDigestBytes else { return nil }
        guard queueDepth >= 0 && queueDepth <= 255 else { return nil }
        self.storeVersion = storeVersion
        self.hint4 = hint4
        self.digest6 = digest6
        self.queueDepth = queueDepth
    }
}

/// The ONE observation lease an authority holdeth over the store's held-set
/// registry for the life of a runtime. Born active; `close()` is idempotent and
/// on the FIRST transition invoc'eth the release action EXACTLY once; after close
/// the lease is inert (a stale/rolled-back notification that consulteth `isActive`
/// findeth it false and driveth no compute). The release action is the platform
/// child's to supply; this type owneth the single-release + idempotent-close law.
public final class SnapshotObservationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var activeFlag: Bool = true
    private var closes: Int = 0
    private let onRelease: (() -> Void)?

    public init(onRelease: (() -> Void)? = nil) {
        self.onRelease = onRelease
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeFlag
    }

    public var closeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return closes
    }

    /// True iff THIS call perform'd the active->closed transition and the one release.
    @discardableResult
    public func close() -> Bool {
        lock.lock()
        guard activeFlag else { lock.unlock(); return false }
        activeFlag = false
        closes += 1
        lock.unlock()
        onRelease?()          // releaseth the owned resource exactly once, outside the lock
        return true
    }
}
