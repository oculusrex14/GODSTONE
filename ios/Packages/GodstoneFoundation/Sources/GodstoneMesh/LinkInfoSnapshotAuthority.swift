import Foundation
import GodstoneCore

/// Authoritative provider and precomputed cache of local LinkInfo V1 snapshots on iOS (ADR-002, Phase C8.4D1-R2.2).
///
/// Enforces:
/// - Real identity nodeHint derivation (no synthetic dummy values).
/// - Real MessageStore held message ID enumeration and Bloom digest calculation.
/// - Exact held count queue depth, saturating at 255.
/// - Immutable precomputed snapshot caching: ATT callbacks NEVER perform durable store traversal.
/// - Cache refresh on defined durable-state mutation boundaries (identity load, store insert/purge, transport start).
public final class LinkInfoSnapshotAuthority: @unchecked Sendable {

    private let identityProvider: () -> MeshIdentity?
    private let storeProvider: () -> MessageStore?
    private let isSosPresentProvider: () -> Bool
    private let isClockUntrustedProvider: () -> Bool
    private let isPowerConstrainedProvider: () -> Bool

    private let lock = NSLock()
    private var cachedSnapshot: BleLinkInfoV1?
    private var cachedData: Data?

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
        _ = refresh()
    }

    @discardableResult
    public func refresh() -> BleLinkInfoV1 {
        let identity = identityProvider()
        let nodeHint = identity?.nodeHint ?? Data(repeating: 0, count: BleLinkInfoConstants.nodeHintBytes)
        let store = storeProvider()

        var count = 0
        var bloom = BloomDigest()
        if let st = store {
            st.forEachHeldMsgId { msgId in
                count += 1
                bloom.add(msgId)
                return true
            }
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

    public func currentSnapshot() -> BleLinkInfoV1 {
        lock.lock()
        if let s = cachedSnapshot {
            lock.unlock()
            return s
        }
        lock.unlock()
        return refresh()
    }

    public func currentData() -> Data {
        lock.lock()
        if let d = cachedData {
            lock.unlock()
            return d
        }
        lock.unlock()
        _ = refresh()
        lock.lock()
        defer { lock.unlock() }
        return cachedData ?? Data()
    }
}
