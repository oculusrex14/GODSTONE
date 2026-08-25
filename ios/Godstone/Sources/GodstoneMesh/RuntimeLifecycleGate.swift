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

    internal init(
        lifecycleGate: DefaultRuntimeLifecycleGate,
        sessions: SessionManager? = nil,
        peerStore: SqlitePeerIdentityStore? = nil,
        messageStore: SqliteMessageStore? = nil
    ) {
        self.lifecycleGate = lifecycleGate
        self.sessions = sessions
        self.peerStore = peerStore
        self.messageStore = messageStore
    }

    public func invalidateForWipe() {
        lifecycleGate.invalidateForWipe()
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
