import Foundation

/// iOS twin of android/.../mesh/abuse/PeerGovernor.kt (sealed at T26). T27:
/// equivalent iOS traffic governance -- the SAME bounded, authenticated
/// token-bucket budget and trust discipline, so one adversarial trace decides
/// identically admit/drop on both isles.
///
/// The three T26 laws are preserved bit-for-bit at the decision level:
///  - BOUNDED IDENTITY GOVERNOR. A global cap ([maxTrackedPeers]) is consulted
///    BEFORE any per-peer entry is allocated ([admitIdentity]); a fresh peer
///    beyond the cap is refused WITHOUT allocating, so a Sybil flood cannot grow
///    the registries unbounded. An already-tracked identity is always served.
///  - ATOMIC BUDGET CONSUME. A bucket's refill-then-debit runs under the bucket's
///    own lock, so concurrent frames for one (peer, priority) admit at most its
///    tokens, never more.
///  - WALL-CLOCK ROLLBACK SAFETY. A bucket stamp never moves backwards and a
///    negative interval pays no tokens; a refuse window only ever EXTENDS.
///
/// SECURITY (the T27 semantic negative): the budget identity is the AUTHENTICATED
/// node id ([allowInbound]'s first argument), never the untrusted advertised hint.
/// The hint is carried for provenance only and MUST NOT key the buckets or the
/// trust registry -- two distinct peers that share a spoofed/advertised hint stay
/// independently governed.
///
/// Lock discipline mirrors the platform's LinkInfoSnapshotAuthority: two NSLocks
/// (the registry lock and a per-bucket lock), each held only in short windows,
/// never co-held, so the non-reentrant NSLock is never re-entered on one thread.
/// Hand-written runtime helper (not codegen), mirroring Priority.swift's standing.
public final class PeerGovernor: @unchecked Sendable {

    private final class Bucket: @unchecked Sendable {
        var tokens: Double
        var lastMillis: Int64
        let lock = NSLock()
        init(tokens: Double, lastMillis: Int64) { self.tokens = tokens; self.lastMillis = lastMillis }
    }

    private final class Trust: @unchecked Sendable {
        var score: Double = 1.0
        var strikes: Int = 0
        var refuseUntilMillis: Int64 = 0
    }

    private let nowMillis: @Sendable () -> Int64
    private let maxTrackedPeers: Int
    private let capacity: [Priority: Int]
    private let refillPerSecond: [Priority: Double]

    private let registryLock = NSLock()
    private var buckets: [String: [Priority: Bucket]] = [:]
    private var trust: [String: Trust] = [:]
    private var trackedCount: Int = 0

    public init(
        nowMillis: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        maxTrackedPeers: Int = PeerGovernor.defaultMaxTrackedPeers,
        capacity: [Priority: Int] = PeerGovernor.defaultCapacity,
        refillPerSecond: [Priority: Double] = PeerGovernor.defaultRefill
    ) {
        self.nowMillis = nowMillis
        self.maxTrackedPeers = maxTrackedPeers
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
    }

    private func keyOf(_ id: Data) -> String {
        var out = ""
        out.reserveCapacity(id.count * 2)
        for byte in id { out += String(format: "%02x", byte) }
        return out
    }

    /// Global admission gate. A known identity is admitted unconditionally; a fresh
    /// one is admitted only while the bounded registry has room, tested BEFORE the
    /// entry is allocated (the "allocate a governor entry before global admission"
    /// falsification). A single, non-nested acquisition of the registry lock.
    private func admitIdentity(_ k: String) -> Bool {
        registryLock.lock()
        if trust[k] != nil || buckets[k] != nil { registryLock.unlock(); return true }
        if trackedCount >= maxTrackedPeers { registryLock.unlock(); return false }
        trust[k] = Trust()
        trackedCount += 1
        registryLock.unlock()
        return true
    }

    /// The trust record for [k], allocating it only if global admission permits.
    private func mutableTrust(_ k: String) -> Trust? {
        registryLock.lock()
        if let t = trust[k] { registryLock.unlock(); return t }
        if trackedCount >= maxTrackedPeers { registryLock.unlock(); return nil }
        let t = Trust()
        trust[k] = t
        trackedCount += 1
        registryLock.unlock()
        return t
    }

    /// Should we even talk to this peer? Low trust earns a refusal window that only
    /// ever extends, so a rolled-back clock cannot shrink an exclusion.
    public func admits(_ authenticatedNodeId: Data) -> Bool {
        let k = keyOf(authenticatedNodeId)
        registryLock.lock(); let t = trust[k]; registryLock.unlock()
        guard let t = t else { return true }
        return nowMillis() >= t.refuseUntilMillis
    }

    /// Consume one token for an inbound frame; `false` means DROP IT UNPARSED.
    /// The budget identity is the AUTHENTICATED node id; the advertised hint is
    /// deliberately not used to select the bucket -- only carried for provenance.
    public func allowInbound(_ authenticatedNodeId: Data, priority: Priority, advertisedHint: Data? = nil) -> Bool {
        _ = advertisedHint                                   // NEVER the budget identity
        let k = keyOf(authenticatedNodeId)
        if !admits(authenticatedNodeId) { return false }
        if !admitIdentity(k) { return false }                // bounded governor: bound tested BEFORE allocation

        let capD = Double(capacity[priority] ?? PeerGovernor.unknownCapacity)
        let refill = refillPerSecond[priority] ?? PeerGovernor.unknownRefill

        registryLock.lock()
        var perPeer = buckets[k] ?? [:]
        let bucket: Bucket
        if let existing = perPeer[priority] {
            bucket = existing
        } else {
            bucket = Bucket(tokens: capD, lastMillis: nowMillis())
            perPeer[priority] = bucket
            buckets[k] = perPeer
        }
        registryLock.unlock()

        var admit = false
        bucket.lock.lock()
        let present = nowMillis()
        if present >= bucket.lastMillis {                    // never move the stamp back; never pay a negative interval
            let elapsedSec = Double(present &- bucket.lastMillis) / 1000.0
            let refilled = bucket.tokens + elapsedSec * refill
            bucket.tokens = refilled < capD ? refilled : capD
            bucket.lastMillis = present
        }
        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0
            admit = true
        }
        bucket.lock.unlock()

        if !admit { penalise(authenticatedNodeId, amount: 0.05) }   // sustained overrun is evidence; charged OUTSIDE the bucket lock
        return admit
    }

    /// Well-formed, useful traffic slowly restores trust.
    public func reward(_ authenticatedNodeId: Data) {
        guard let t = mutableTrust(keyOf(authenticatedNodeId)) else { return }
        t.score = min(1.0, t.score + 0.01)
        if t.score > 0.5 { t.strikes = 0 }
    }

    /// Malformed frames, failed MACs and duplicate floods cost trust. Below the
    /// floor the peer is refused for a window that doubles each strike, capped so a
    /// transient fault cannot permanently partition an honest neighbour. The window
    /// only ever EXTENDS.
    public func penalise(_ authenticatedNodeId: Data, amount: Double = 0.2) {
        guard let t = mutableTrust(keyOf(authenticatedNodeId)) else { return }
        t.score -= amount
        if t.score <= 0.25 {
            t.strikes = min(t.strikes + 1, PeerGovernor.maxStrikes)
            let until = nowMillis() + Int64(Double(PeerGovernor.baseBackoffMillis) * pow(2.0, Double(t.strikes - 1)))
            if until > t.refuseUntilMillis { t.refuseUntilMillis = until }
            t.score = 0.3                                    // leave a path back: permanent bans partition the mesh
        }
    }

    public func trustOf(_ authenticatedNodeId: Data) -> Double {
        registryLock.lock(); let t = trust[keyOf(authenticatedNodeId)]; registryLock.unlock()
        return t?.score ?? 1.0
    }

    public func forget(_ authenticatedNodeId: Data) {
        let k = keyOf(authenticatedNodeId)
        registryLock.lock()
        let hadIdentity = (trust.removeValue(forKey: k) != nil)
        buckets.removeValue(forKey: k)
        let stillThere = (trust[k] != nil) || (buckets[k] != nil)
        if hadIdentity && !stillThere && trackedCount > 0 { trackedCount -= 1 }
        registryLock.unlock()
    }

    // Gauges for the readiness court (visible via the module's @testable import).
    internal func trackedPeerCount() -> Int {
        registryLock.lock(); defer { registryLock.unlock() }
        return trackedCount
    }
    internal var maxTrackedPeersLimit: Int { maxTrackedPeers }

    // Mirrored EXACTLY from the sealed android companion constants.
    public static let defaultMaxTrackedPeers = 4096
    private static let unknownCapacity = 10
    private static let unknownRefill = 0.25
    private static let baseBackoffMillis = 30_000
    private static let maxStrikes = 5
    public static let defaultCapacity: [Priority: Int] = [
        .sos: 30, .direct: 60, .group: 30, .broadcast: 20, .bulk: 10,
    ]
    public static let defaultRefill: [Priority: Double] = [
        .sos: 0.5, .direct: 1.0, .group: 0.5, .broadcast: 0.25, .bulk: 0.1,
    ]
}
