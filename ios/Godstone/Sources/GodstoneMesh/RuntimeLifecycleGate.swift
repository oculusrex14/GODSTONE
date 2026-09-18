import Foundation
import GodstoneCore

/// Interface for invalidating runtime handles upon panic wipe (ADR-003 / Stage 4B / C8.4B).
public protocol RuntimeInvalidator: AnyObject {
    func invalidateForWipe() throws
}

/// Monotonic lifecycle gate interface for the non-shipping mesh runtime.
public protocol RuntimeLifecycleGate: AnyObject {
    var isActive: Bool { get }
    var isInvalidated: Bool { get }
}

/// Thread-safe monotonic runtime lifecycle gate.
public final class DefaultRuntimeLifecycleGate: RuntimeLifecycleGate, RuntimeInvalidator, @unchecked Sendable {
    private var _invalidated = false
    private let lock = NSLock()

    public init() {}

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !_invalidated
    }

    public var isInvalidated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _invalidated
    }

    public func invalidateForWipe() {
        lock.lock()
        defer { lock.unlock() }
        _invalidated = true
    }
}

/// Decorates `WipeArtifacts` to guarantee deterministic runtime invalidation
/// BEFORE cryptographic key erasure is executed (ADR-003 / Stage 4B / C8.4B).
public final class RuntimeAwareWipeArtifacts: WipeArtifacts {
    private let invalidator: RuntimeInvalidator
    private let delegate: WipeArtifacts

    public init(invalidator: RuntimeInvalidator, delegate: WipeArtifacts) {
        self.invalidator = invalidator
        self.delegate = delegate
    }

    public func eraseKeys() throws {
        try invalidator.invalidateForWipe()
        try delegate.eraseKeys()
    }

    public func deleteArtifacts() throws {
        try delegate.deleteArtifacts()
    }

    public func regenerateIdentity() throws {
        try delegate.regenerateIdentity()
    }
}

/// Runtime invalidator that coordinates lifecycle state, session destruction,
/// and database closure across stores in the process.
public final class MeshRuntimeInvalidator: RuntimeInvalidator {
    private let lifecycleGate: DefaultRuntimeLifecycleGate
    private let sessions: SessionManager?
    private let peerStore: SqlitePeerIdentityStore?
    private let messageStore: SqliteMessageStore?
    /// GS-RUNTIME-001 step 6: **THE NODE IS HELD SO THAT IT CAN BE DRAINED.** Until this landed, the invalidator
    /// closed the stores WITHOUT holding the node at all -- and no production call to `meshNode.stop()` existed
    /// anywhere -- so an ACK deadline armed by the runtime could fire AFTER the keys were gone.
    private let node: MeshNode?

    internal init(
        lifecycleGate: DefaultRuntimeLifecycleGate,
        sessions: SessionManager? = nil,
        peerStore: SqlitePeerIdentityStore? = nil,
        messageStore: SqliteMessageStore? = nil,
        node: MeshNode? = nil
    ) {
        self.lifecycleGate = lifecycleGate
        self.sessions = sessions
        self.peerStore = peerStore
        self.messageStore = messageStore
        self.node = node
    }

    /// **THE ORDER IS THE LAW: STOP/DRAIN WORKERS *BEFORE* DELETING KEYS.** The node is drained FIRST -- which
    /// cancellath its ACK deadline and forgetteth its relation mappings -- and only THEN are the stores closed.
    /// MEASURED BEFORE THIS REPAIR: the turn census climbed from 1 to 6 AFTER `invalidateForWipe()`, which is a
    /// worker firing for keys that are already gone.
    public func invalidateForWipe() {
        lifecycleGate.invalidateForWipe()
        node?.stop()
        sessions?.invalidateForWipe()
        peerStore?.close()
        messageStore?.close()
    }
}

/// Adapter ensuring `PeerIdentityLookupSource` fails closed (returns .storageFailure)
/// when the runtime lifecycle gate has been invalidated.
internal final class RuntimeGatedPeerIdentityLookupSource: PeerIdentityLookupSource, @unchecked Sendable {
    private let delegate: any PeerIdentityLookupSource
    private let lifecycleGate: any RuntimeLifecycleGate

    internal init(delegate: any PeerIdentityLookupSource, lifecycleGate: any RuntimeLifecycleGate) {
        self.delegate = delegate
        self.lifecycleGate = lifecycleGate
    }

    internal func lookup(_ nodeId: Data) -> PeerIdentityLookup {
        guard lifecycleGate.isActive else { return .storageFailure }
        return delegate.lookup(nodeId)
    }
}

/// Adapter ensuring `PeerBindingTrustAuthority` fails closed (returns .storageFailure)
/// when the runtime lifecycle gate has been invalidated.
internal final class RuntimeGatedPeerBindingTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
    private let delegate: any PeerBindingTrustAuthority
    private let lifecycleGate: any RuntimeLifecycleGate

    internal init(delegate: any PeerBindingTrustAuthority, lifecycleGate: any RuntimeLifecycleGate) {
        self.delegate = delegate
        self.lifecycleGate = lifecycleGate
    }

    internal func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
        guard lifecycleGate.isActive else { return .storageFailure }
        return delegate.applyValidatedBinding(binding)
    }
}

// ================================================================================================
// *** GS-FINAL-003 (the independent audit, 2026-09-18): THE JOURNAL-BOUND GATE, AT AN ADMISSION POINT. ***
//
// THE AUDIT'S CHARGE: *"Startup proceeds after wipe recovery returns a non-complete outcome. ... Android
// `MeshStartupWipeBarrier` returns Unit after calling resume; providers require the barrier object, not a successful
// recovery capability."* AND ITS REMEDY: *"block private opens while a wipe is pending."*
//
// *** ROUND 549 MEASURED WHY THE OBVIOUS PLACE -- REFUSING CONSTRUCTION -- DEADLOCKS: *** the barrier's own inputs feed
// `MeshNode`, and `MeshNode` carrieth the live transport the wipe must drain, so a throwing constructor makes the
// wipe's REMEDY unreachable. A gate that makes its own remedy unreachable is worse than the defect it closeth.
//
// THE MECHANISM THAT DOES NOT DEADLOCK ALREADY EXISTED, AND NOTHING CONSULTED IT:
// `CrashResumableWipe.allowsStartup()` / `allowsSensitiveApi()` are JOURNAL-BOUND -- the authority's own words: *"The
// gate answers from the journal alone -- it cannot be bypassed by a cached flag."* MEASURED BEFORE THIS EDIT: those two
// functions were called by FOUR TEST SITES AND ZERO PRODUCTION SITES. **A GATE NOBODY CONSULTS IS NOT A GATE.**
//
// SO: CONSTRUCTION PROCEEDS, AND SENSITIVE **USE** IS REFUSED, THROUGH THE ADMISSION POINT. The shape follows the
// established `RuntimeGatedPeerIdentityLookupSource` / `RuntimeGatedPeerBindingTrustAuthority` decorators on this isle
// -- they fail closed when the lifecycle gate is inactive; these fail closed when a wipe is pending.
//
// AND THE GATE IS ASKED PER CALL, NOT SAMPLED AT CONSTRUCTION, because a decorator that cached the verdict would answer
// from a stale one -- which is precisely the "DI sequencing mistaken for a successful state transition" the audit
// named. ONE ARM MEASURES EXACTLY THAT.
// ================================================================================================

/// *** THE ADMISSION SEAM: whether a wipe's journal permitteth sensitive use RIGHT NOW. ***
///
/// It is a PROTOCOL rather than a concrete `CrashResumableWipe` so a court can drive both answers without a journal,
/// and so the decorators depend on the LAW rather than on the coordinator's whole surface.
public protocol WipeSensitiveUseGate: AnyObject, Sendable {
    /// True iff the journal carrieth no outstanding wipe. Bound to
    /// `CrashResumableWipe.allowsSensitiveApi()` in the composition.
    func allowsSensitiveUse() -> Bool
}

/// The composition's adapter: the coordinator's OWN journal-bound answer, unaltered.
public final class CoordinatorWipeSensitiveUseGate: WipeSensitiveUseGate, @unchecked Sendable {
    private let authority: CrashResumableWipe
    public init(authority: CrashResumableWipe) { self.authority = authority }
    /// *** ASKED PER CALL, NEVER CACHED: `allowsSensitiveApi()` readeth the durable journal each time. ***
    public func allowsSensitiveUse() -> Bool { authority.allowsSensitiveApi() }
}

/// The one-slot holder that letteth a decorator be built during `init` and resolveth its authority afterwards.
public final class WipeGateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _authority: CrashResumableWipe?
    public init() {}
    public var authority: CrashResumableWipe? {
        get { lock.lock(); defer { lock.unlock() }; return _authority }
        set { lock.lock(); _authority = newValue; lock.unlock() }
    }
}

/// *** THE COMPOSITION'S DEFERRED READ, FOR THE LIVENESS REASON THE AUTHORITY ITSELF IS LAZY. ***
///
/// `MeshRuntime.wipeAuthority` is a `lazy var` because constructing it reacheth `meshNode`, which is assigned later in
/// `init`. A decorator built during `init` would therefore have to read it too early. This adapter resolveth the
/// authority AT CALL TIME -- after construction -- so the one-authority rule and the initialisation order both hold.
///
/// **AND IT FAILS CLOSED WHEN THE READER IS GONE:** if the runtime hath been released, the answer is `false`, which
/// refuseth sensitive use. A vanished owner is not permission.
public final class DeferredWipeSensitiveUseGate: WipeSensitiveUseGate, @unchecked Sendable {
    private let read: @Sendable () -> Bool
    public init(read: @escaping @Sendable () -> Bool) { self.read = read }
    public func allowsSensitiveUse() -> Bool { read() }
}

/// Reroutes lookups to `.storageFailure` while a wipe is pending. The delegate is NOT reached.
internal final class WipeGatedPeerIdentityLookupSource: PeerIdentityLookupSource, @unchecked Sendable {
    private let delegate: any PeerIdentityLookupSource
    private let wipeGate: any WipeSensitiveUseGate

    internal init(delegate: any PeerIdentityLookupSource, wipeGate: any WipeSensitiveUseGate) {
        self.delegate = delegate
        self.wipeGate = wipeGate
    }

    internal func lookup(_ nodeId: Data) -> PeerIdentityLookup {
        guard wipeGate.allowsSensitiveUse() else { return .storageFailure }
        return delegate.lookup(nodeId)
    }
}

/// Reroutes binding applications to `.storageFailure` while a wipe is pending. The delegate is NOT reached.
internal final class WipeGatedPeerBindingTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
    private let delegate: any PeerBindingTrustAuthority
    private let wipeGate: any WipeSensitiveUseGate

    internal init(delegate: any PeerBindingTrustAuthority, wipeGate: any WipeSensitiveUseGate) {
        self.delegate = delegate
        self.wipeGate = wipeGate
    }

    internal func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
        guard wipeGate.allowsSensitiveUse() else { return .storageFailure }
        return delegate.applyValidatedBinding(binding)
    }
}
