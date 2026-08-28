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
public final class LinkInfoSnapshotAuthority: @unchecked Sendable {

    private let identityProvider: () -> MeshIdentity?
    private let storeProvider: () -> MessageStore?
    private let isSosPresentProvider: () -> Bool
    private let isClockUntrustedProvider: () -> Bool
    private let isPowerConstrainedProvider: () -> Bool

    private let lock = NSLock()
    private var cachedSnapshot: BleLinkInfoV1?
    private var cachedData: Data?
    private weak var registeredStore: MessageStore?

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
                _ = self?.refresh()
            }
        }
    }

    @discardableResult
    public func refresh() -> BleLinkInfoV1? {
        attachStoreObserver()
        guard let identity = identityProvider(),
              identity.nodeHint.count == BleLinkInfoConstants.nodeHintBytes,
              let store = storeProvider() else {
            lock.lock()
            cachedSnapshot = nil
            cachedData = nil
            lock.unlock()
            return nil
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

        lock.lock()
        cachedSnapshot = info
        cachedData = encoded
        lock.unlock()

        return info
    }

    public func currentSnapshot() -> BleLinkInfoV1? {
        lock.lock()
        defer { lock.unlock() }
        return cachedSnapshot
    }

    public func currentData() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return cachedData
    }
}
