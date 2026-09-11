import Foundation
import GodstoneCore

/// Authoritative provider and precomputed cache of local LinkInfo V1 snapshots on iOS (ADR-002, Phase C8.4D1-R2.3).
///
/// Enforces:
/// - Real identity nodeHint derivation (no synthetic dummy values). Fails closed (nil) if identity is absent.
/// - Real MessageStore held message ID enumeration and Bloom digest calculation. Fails closed (nil) if store is absent.
/// - Canonical empty digest and queue depth 0 when store is real and empty.
/// - Exact held count queue depth, saturating at 255.
/// - Immutable precomputed snapshot caching: ATT callbacks NEVER perform durable store traversal.
/// - Automatic cache refresh on MessageStore mutation events without requiring manual caller invocation.
///
/// T25 platform layer (subscription-owned, nonblocking reads), the symmetric twin of the Kotlin authority:
/// - The held-set digest/queue-depth are computed on the store's post-commit notify path (the store
///   notifies ONLY after a transaction commits, on the committing thread) and published ATOMICALLY as an
///   immutable [HeldSnapshot] carrying a monotonic generation `storeVersion`; a stale compute never
///   overwrites a newer one (the token is captured before the traversal and revalidated before publish).
/// - The GATT read path (currentSnapshot/currentData/currentHeldSnapshot) is a PURE cached copy: it
///   NEVER traverses the store, so a blocked/unavailable store cannot stall or falsify a read.
/// - Exactly one observation lease is owned per runtime (startObserving/stopObserving); the store's
///   registry is grow-only, so the lease is a GATE -- a closed lease makes the single registration inert
///   (no recompute), and re-opening reuses that same one registration (never a second).
/// Note on platform fidelity: the iOS [MessageStore.forEachHeldMsgId] is synchronous and non-throwing, so
/// a storage fault is surfaced by the store's committed-only-notify gate (a rolled-back commit fire'th no
/// observer and so changeth no snapshot) rather than by a thrown-error seam; that is the same observable
/// law the Kotlin side enforces, realised at the seam this platform actually provideth.
public final class LinkInfoSnapshotAuthority: @unchecked Sendable {

    private let identityProvider: () -> MeshIdentity?
    private let storeProvider: () -> MessageStore?
    private let isSosPresentProvider: () -> Bool
    private let isClockUntrustedProvider: () -> Bool
    private let isPowerConstrainedProvider: () -> Bool

    // The cache lock guardeth the published triad + the lease reference ONLY, in short windows,
    // NEVER held across the store traversal. The meta lock guardeth the compute meta-state. They are
    // never acquired together, so the non-reentrant NSLock is never re-entered on one thread.
    private let lock = NSLock()
    private var cachedSnapshot: BleLinkInfoV1?
    private var cachedData: Data?
    private var published: HeldSnapshot?
    private var observingLease = SnapshotObservationLease()
    private weak var registeredStore: MessageStore?

    private let metaLock = NSLock()
    private var generationValue: Int = 0
    private var computingFlag: Bool = false
    private var rerunFlag: Bool = false

    public init(
        identityProvider: @escaping () -> MeshIdentity? = { nil },
        storeProvider: @escaping () -> MessageStore? = { nil },
        isSosPresentProvider: @escaping () -> Bool = { false },
        isClockUntrustedProvider: @escaping () -> Bool = { false },
        isPowerConstrainedProvider: @escaping () -> Bool = { false }
    ) {
        self.identityProvider = identityProvider
        self.storeProvider = storeProvider
        self.isSosPresentProvider = isSosPresentProvider
        self.isClockUntrustedProvider = isClockUntrustedProvider
        self.isPowerConstrainedProvider = isPowerConstrainedProvider

        attachStoreObserver()
        _ = refresh()
    }

    private func attachStoreObserver() {
        if let store = storeProvider(), store !== registeredStore {
            registeredStore = store
            store.registerHeldSetObserver { [weak self] in
                self?.onHeldSetChanged()
            }
        }
    }

    // The store fires this on the COMMITTING thread, after the transaction committed. Gated by the lease.
    private func onHeldSetChanged() {
        lock.lock(); let lease = observingLease; lock.unlock()
        guard lease.isActive else { return }
        bumpGeneration()
        requestCompute()
    }

    /// Open the single owned observation lease (idempotent); ensure the one registration exists.
    public func startObserving() {
        lock.lock(); let lease = observingLease; lock.unlock()
        if !lease.isActive {
            let fresh = SnapshotObservationLease()
            lock.lock(); observingLease = fresh; lock.unlock()
        }
        attachStoreObserver()
    }

    /// Close the owned lease: the single registration becometh inert (no recompute) until re-opened.
    public func stopObserving() {
        lock.lock(); let lease = observingLease; lock.unlock()
        lease.close()
    }

    public func isObserving() -> Bool {
        lock.lock(); let lease = observingLease; lock.unlock()
        return lease.isActive
    }

    @discardableResult
    public func refresh() -> BleLinkInfoV1? {
        attachStoreObserver()
        bumpGeneration()
        requestCompute()
        return currentSnapshot()
    }

    private func requestCompute() {
        guard enterCompute() else { markRerun(); return }   // reentrant notify: mark a re-run, never a nest
        defer { exitCompute() }
        var passes = 0
        repeat {
            clearRerun()
            doCompute()
            passes += 1
        } while isRerun() && passes < 8
    }

    private func doCompute() {
        // Capture the token BEFORE the traversal, so a commit that superveneth during the traversal
        // (a reentrant notify) advance'eth the generation and this compute's result is recognis'd as
        // stale and DROPP'd at the revalidate gate -- the latest then win'eth.
        let token = generationSnapshot()
        guard let identity = identityProvider(),
              identity.nodeHint.count == BleLinkInfoConstants.nodeHintBytes,
              let store = storeProvider() else {
            lock.lock()
            cachedSnapshot = nil
            cachedData = nil
            published = nil
            lock.unlock()
            return
        }

        let nodeHint = identity.nodeHint
        var count = 0
        var bloom = BloomDigest()
        store.forEachHeldMsgId { msgId in
            count += 1
            bloom.add(msgId)
            return true
        }

        let queueDepth = UInt8(min(count, 255))
        let shortDigest = bloom.toBytes().prefix(BleLinkInfoConstants.shortDigestBytes)

        var flags: UInt8 = 0
        if isSosPresentProvider() {
            flags |= BleLinkInfoConstants.flagSosPresent
        }
        if isClockUntrustedProvider() {
            flags |= BleLinkInfoConstants.flagClockUntrusted
        }
        if isPowerConstrainedProvider() {
            flags |= BleLinkInfoConstants.flagPowerConstrained
        }

        let info = BleLinkInfoV1(
            version: BleLinkInfoConstants.protocolVersion,
            flags: flags,
            nodeHint: nodeHint,
            shortDigest: Data(shortDigest),
            queueDepth: queueDepth
        )
        let encoded = BleLinkInfoCodec.encode(
            version: info.version,
            flags: info.flags,
            nodeHint: info.nodeHint,
            shortDigest: info.shortDigest,
            queueDepth: info.queueDepth
        )
        let snapshotOpt = HeldSnapshot(
            storeVersion: UInt64(token),
            hint4: Data(nodeHint),
            digest6: Data(shortDigest),
            queueDepth: Int(queueDepth)
        )
        // revalidate-before-publish: publish only if no newer committed event supervened the token.
        if generationSnapshot() == token, let snapshot = snapshotOpt {
            lock.lock()
            published = snapshot
            cachedSnapshot = info
            cachedData = encoded
            lock.unlock()
        }
    }

    public func currentSnapshot() -> BleLinkInfoV1? {
        lock.lock(); defer { lock.unlock() }
        return cachedSnapshot
    }

    public func currentData() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return cachedData
    }

    /// Pure cached read of the last committed immutable [HeldSnapshot]; never traverseth the store.
    public func currentHeldSnapshot() -> HeldSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return published
    }

    // ---- meta-lock-guarded accessors (short windows; never nested with the cache lock) ----
    private func bumpGeneration() { metaLock.lock(); generationValue += 1; metaLock.unlock() }
    private func generationSnapshot() -> Int { metaLock.lock(); defer { metaLock.unlock() }; return generationValue }
    private func enterCompute() -> Bool {
        metaLock.lock(); defer { metaLock.unlock() }
        if computingFlag { return false }
        computingFlag = true
        return true
    }
    private func exitCompute() { metaLock.lock(); computingFlag = false; metaLock.unlock() }
    private func markRerun() { metaLock.lock(); rerunFlag = true; metaLock.unlock() }
    private func isRerun() -> Bool { metaLock.lock(); defer { metaLock.unlock() }; return rerunFlag }
    private func clearRerun() { metaLock.lock(); rerunFlag = false; metaLock.unlock() }
}
