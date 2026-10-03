import Foundation
import CryptoKit

/// Owner census issued by the physical authority. A caller-created empty census is not cold proof.
public final class EstateOwnerRegistry: @unchecked Sendable {
    public final class Entry: @unchecked Sendable {
        public let name: String
        fileprivate let drain: () throws -> Void
        fileprivate let token: Int
        fileprivate init(name: String, token: Int, drain: @escaping () throws -> Void) {
            self.name = name; self.token = token; self.drain = drain
        }
    }

    fileprivate var parent: EstateOwnerRegistry?
    fileprivate var root: EstateOwnerRegistry { parent?.root ?? self }
    fileprivate var entries: [Int: Entry] = [:]
    fileprivate var inventory: [String: URL] = [:]
    fileprivate var verifiedCatalog = false
    fileprivate var revision: UInt64 = 0
    fileprivate var lastClosedCount = 0

    /// An independent registry can collect owners but cannot assert physical absence.
    public init() {}

    @discardableResult
    public func register(name: String, drain: @escaping () throws -> Void) -> Int {
        PhysicalEstateAuthority.shared.serialized {
            let token = PhysicalEstateAuthority.shared.nextOwnerToken()
            root.entries[token] = Entry(name: name, token: token, drain: drain)
            return token
        }
    }

    public func unregister(_ token: Int) {
        PhysicalEstateAuthority.shared.serialized { root.entries.removeValue(forKey: token) }
    }

    public func drainAll() -> OwnerDrainResult {
        PhysicalEstateAuthority.shared.serialized {
            let census = root
            guard census.verifiedCatalog else {
                return .ownersLive(reason: "no authority-owned durable physical inventory")
            }
            let live = census.entries.values.sorted { $0.token < $1.token }
            if live.isEmpty { return .cold(reason: "durable inventory and physical owner census prove no live owner") }
            var failures: [String] = []
            var closed = 0
            for entry in live {
                do {
                    try entry.drain()
                    census.entries.removeValue(forKey: entry.token)
                    closed += 1
                } catch { failures.append("\(entry.name): \(error)") }
            }
            census.lastClosedCount = closed
            guard failures.isEmpty, census.entries.isEmpty else {
                return .ownersLive(reason: failures.isEmpty ? "owners registered during drain" : failures.joined(separator: "; "))
            }
            return .drained(reason: "physically closed \(closed) registered owners")
        }
    }

    public func isClosureMeasured() -> Bool {
        PhysicalEstateAuthority.shared.serialized { root.verifiedCatalog && root.entries.isEmpty }
    }
    internal var closedCount: Int { PhysicalEstateAuthority.shared.serialized { root.lastClosedCount } }
    internal var artifactPaths: [String: URL] { PhysicalEstateAuthority.shared.serialized { root.inventory } }

    /// *** IOS-FOLLOWUP-CURRENT-06: THE FULL PHYSICAL/KEY-DOMAIN UNION, AS THE DELETION SCOPE. ***
    ///
    /// *The finding measured that the never-shrinking union `bindInventory` persisteth was never CONSUMED: the
    /// retained wipe and the recovery wrappers deleted only their own local six paths, so wiping root A could erase the
    /// shared DEKs and report completion while root B's cataloged DB/WAL/SHM files remained. This is the UNION the
    /// destructive paths must iterate -- keyed by the SAME logical names the artifact seams address.*
    internal var unionArtifactPaths: [String: URL] {
        PhysicalEstateAuthority.shared.serialized { root.inventory }
    }

    internal func revokeAdmissions() { PhysicalEstateAuthority.shared.serialized { root.revision &+= 1 } }
}

public final class EstateOwnerDrainSeam: TransportRuntimeSeam, WipeOwnerDraining, @unchecked Sendable {
    private let registry: EstateOwnerRegistry
    private var quiesced = false
    public init(registry: EstateOwnerRegistry) { self.registry = registry }
    public func drainOwners() -> OwnerDrainResult {
        PhysicalEstateAuthority.shared.serialized {
            let result = registry.drainAll()
            quiesced = result.isDrainable
            return result
        }
    }
    public func drainTransport() -> RuntimeDrainReceipt {
        switch drainOwners() {
        case .drained: return .drained(closedTransports: registry.closedCount, quiescedRuntime: true)
        case .cold: return .drained(closedTransports: 0, quiescedRuntime: true)
        case .ownersLive(let reason): return .notDrained(reason: reason)
        }
    }
    public func isQuiesced() -> Bool { PhysicalEstateAuthority.shared.serialized { quiesced } }
    public func fireRadio(_ msg: String) -> Bool { false }
    public func sendVia(_ msg: String) -> Bool { false }
}

/// One serialization point covers census, oracle snapshots, permit issuance/consumption and every private effect.
/// Capability namespaces, resolved paths and existing inode aliases all join the same physical owner set.
public final class PhysicalEstateAuthority: @unchecked Sendable {
    public static let shared = PhysicalEstateAuthority()
    private let lock = NSRecursiveLock()
    private var registries: [String: EstateOwnerRegistry] = [:]
    private var nextToken = 1
    private init() {}

    internal func serialized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
    internal func serialized<T>(for estateId: String, _ body: () throws -> T) rethrows -> T {
        try serialized(body)
    }
    fileprivate func nextOwnerToken() -> Int { let token = nextToken; nextToken += 1; return token }

    internal static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    internal static func identityDomain(_ keychain: any LocalIdentityKeychain) -> String {
        if keychain is DefaultLocalIdentityKeychain { return "keychain:io.godstone.mesh.identity:global" }
        return "identity-object:\(ObjectIdentifier(keychain as AnyObject))"
    }

    private static func catalogTag(_ capability: String) -> String {
        let digest = SHA256.hash(data: Data(capability.utf8)).map { String(format: "%02x", $0) }.joined()
        return "io.godstone.mesh.physical-inventory." + digest
    }

    /// Register the actual inventory durably before constructing or deleting resources. Catalogs never shrink:
    /// old roots sharing a Keychain capability remain in the erasure set after their process has exited.
    internal func bindInventory(estateId: String, artifactPaths: [String: URL],
                                keychain: any LocalIdentityKeychain, keyDomain: String) throws -> EstateOwnerRegistry {
        try serialized {
            guard !estateId.isEmpty, !artifactPaths.isEmpty, !keyDomain.isEmpty else {
                throw MeshRuntime.MeshRuntimeError.startupRefusedByRecovery(decision: "inventory_refused", reason: "physical estate inventory or key capability is absent")
            }
            let capabilities = ["identity:" + Self.identityDomain(keychain), "dek:" + keyDomain]
            var paths = Set(artifactPaths.values.map(Self.canonicalPath))
            for capability in capabilities {
                if let data = try keychain.read(tag: Self.catalogTag(capability)) {
                    let saved = try JSONDecoder().decode([String].self, from: data)
                    guard saved.allSatisfy({ $0.hasPrefix("/") }) else {
                        throw MeshRuntime.MeshRuntimeError.startupRefusedByRecovery(decision: "inventory_corrupt", reason: "physical catalog contains a nonabsolute path")
                    }
                    paths.formUnion(saved)
                }
            }
            var aliases = capabilities + ["estate:" + estateId]
            for path in paths {
                aliases.append("path:" + path)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                   let device = attrs[.systemNumber] as? NSNumber, let inode = attrs[.systemFileNumber] as? NSNumber {
                    aliases.append("inode:\(device):\(inode)")
                }
            }
            let registry = aliases.compactMap { registries[$0]?.root }.first ?? EstateOwnerRegistry()
            for alias in aliases {
                if let old = registries[alias]?.root, old !== registry {
                    registry.entries.merge(old.entries) { existing, _ in existing }
                    registry.inventory.merge(old.inventory) { existing, _ in existing }
                    // *** CURRENT-05 / the 107-consumer probe: THE REVISION MOVETH ONLY WHEN *THIS* REGISTRY ACQUIRETH
                    // LIVE OWNERS FROM ANOTHER. ***
                    //
                    // *An unconditional bump revoked every permit already issued for this estate: `beginConstruction`
                    // issues the lease (capturing the revision), `bindInventory` then bumps it, and
                    // `ConstructionLease.isCurrent` compares `revision == captured` -- so a FRESH pristine estate
                    // refusing with `startupRefusedByRecovery(permit_refused)` was measuring THIS bump rather than a
                    // real admission failure (the 107-consumer probe).* **`registry` IS `old` whenever the alias
                    // resolution already selected the same root, so the old guard let a self-merge raise the revision;
                    // the guard below asks only whether owners were really ACQUIRED by a DIFFERENT root. A registry
                    // with no entries carrieth no admission to revoke, so an owner-free estate keeps its revision.**
                    if old !== registry, !old.entries.isEmpty {
                        registry.revision = max(registry.revision, old.revision) &+ 1
                    }
                    old.parent = registry
                }
                registries[alias] = registry
            }
            paths.formUnion(registry.inventory.values.map(Self.canonicalPath))
            let encoded = try JSONEncoder().encode(paths.sorted())
            for capability in capabilities {
                let tag = Self.catalogTag(capability)
                try keychain.upsert(tag: tag, data: encoded)
                guard try keychain.read(tag: tag) == encoded else {
                    throw MeshRuntime.MeshRuntimeError.startupRefusedByRecovery(decision: "inventory_unacknowledged", reason: "Keychain physical inventory verification failed")
                }
            }
            registry.inventory = Dictionary(uniqueKeysWithValues: paths.map { ("physical:" + $0, URL(fileURLWithPath: $0)) })
            registry.verifiedCatalog = true
            registries["estate:" + estateId] = registry
            return registry
        }
    }

    internal func registry(for estateId: String) -> EstateOwnerRegistry {
        serialized {
            let key = "estate:" + estateId
            if let existing = registries[key] { return existing.root }
            let registry = EstateOwnerRegistry()
            registries[key] = registry
            return registry
        }
    }

    internal func revision(for estateId: String) -> UInt64 { serialized { registry(for: estateId).root.revision } }

    /// Sealed factory issuer. Neither a caller-written generation nor a test metadata mint can construct this.
    public final class ConstructionLease: @unchecked Sendable {
        public let estateId: String
        public let generation: UInt64
        internal let registry: EstateOwnerRegistry
        private let journal: WipeJournal
        private let revision: UInt64
        private let keyDomain: String
        private let stores: [String: String]
        private var spent: Set<String> = []
        private var retired = false
        fileprivate init(estateId: String, generation: UInt64, journal: WipeJournal,
                         registry: EstateOwnerRegistry, keyDomain: String, stores: [String: String]) {
            self.estateId = estateId; self.generation = generation; self.journal = journal
            self.registry = registry; self.revision = registry.root.revision
            self.keyDomain = keyDomain; self.stores = stores
        }
        public var isCurrent: Bool {
            PhysicalEstateAuthority.shared.serialized {
                // *** THE PERMIT BOUND ESTATE AND GENERATION BEFORE THE LEASE WAS ISSUED; WHAT THE LEASE MUST STILL
                // PROVE IS THAT ITS OWN RECORD IS THE SAME SETTLED ONE AND THAT NO REVOCATION HAS LANDED. *** *The
                // registry revision is captured DURING `beginConstruction`'s own `bindInventory`, which legitimately
                // raises it while merging live owners -- so the captured number is the post-bind one and comparing it
                // here is exact. `revokeAdmissions` (terminal wipe) is the only other raiser, and that raise IS the
                // revocation this test wants to catch.*
                guard !retired, registry.root.revision == revision, journal.isReadable,
                      let live = journal.readDurable(), live.state == .idle, live.epoch == generation else { return false }
                return true
            }
        }
        internal func retire() { PhysicalEstateAuthority.shared.serialized { retired = true } }
        /// Spend an attempt atomically, including a failing attempt, before the factory touches any key API.
        internal func claim(path: String, tag: String, keyDomain: String) -> Bool {
            PhysicalEstateAuthority.shared.serialized {
                let canonical = PhysicalEstateAuthority.canonicalPath(URL(fileURLWithPath: path))
                guard isCurrent, self.keyDomain == keyDomain, stores[tag] == canonical,
                      registry.root.inventory["physical:" + canonical] != nil, !spent.contains(tag) else { return false }
                spent.insert(tag)
                return true
            }
        }
    }

    internal func beginConstruction(permit: PrivateRuntimePermit, estateId: String, journal: WipeJournal,
                                   artifactPaths: [String: URL], keychain: any LocalIdentityKeychain,
                                   keyDomain: String, stores: [String: URL]) throws -> ConstructionLease {
        try serialized {
            let registry = try bindInventory(estateId: estateId, artifactPaths: artifactPaths, keychain: keychain, keyDomain: keyDomain)
            guard journal.isReadable, let snapshot = journal.readDurable(), snapshot.state == .idle,
                  let generation = snapshot.epoch,
                  permit.consumeForConstruction(estateId: estateId, liveGeneration: generation) != nil else {
                throw MeshRuntime.MeshRuntimeError.startupRefusedByRecovery(decision: "permit_refused", reason: "settled durable estate, current generation and unspent permit are required")
            }
            return ConstructionLease(estateId: estateId, generation: generation, journal: journal,
                                     registry: registry, keyDomain: keyDomain,
                                     stores: stores.mapValues(Self.canonicalPath))
        }
    }
}
