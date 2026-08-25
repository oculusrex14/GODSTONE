import Foundation
import CryptoKit
import GodstoneCore

/// POSIX Read-Write lock wrapper for lifecycle linearizability.
internal final class ReadWriteLock {
    private var rwlock = pthread_rwlock_t()

    init() {
        pthread_rwlock_init(&rwlock, nil)
    }

    deinit {
        pthread_rwlock_destroy(&rwlock)
    }

    func readLock() {
        pthread_rwlock_rdlock(&rwlock)
    }

    func writeLock() {
        pthread_rwlock_wrlock(&rwlock)
    }

    func unlock() {
        pthread_rwlock_unlock(&rwlock)
    }

    func withReadLock<T>(_ block: () throws -> T) rethrows -> T {
        readLock()
        defer { unlock() }
        return try block()
    }

    func withWriteLock<T>(_ block: () throws -> T) rethrows -> T {
        writeLock()
        defer { unlock() }
        return try block()
    }
}

/// Per-peer trusted session registry (Stage 4 Phase C8.4B / C8.4B.1).
///
/// Replaces the untrusted raw NoiseSession registry. Owns and gates on
/// `TrustedHandshakeController` instances rather than raw Noise establishment.
/// Seal and open are permitted IFF the transport peer's controller has reached `.ready`.
///
/// LOCK ORDER HIERARCHY:
/// 1. Lifecycle Read/Write Lock (`lifecycleRwLock`):
///    - In-flight operations hold the read lock for their entire execution (including controller calls).
///    - Invalidation (`invalidateForWipe`) holds the exclusive write lock, ensuring all in-flight operations
///      drain completely before controllers are destroyed and the registry cleared.
/// 2. Per-Peer Lock (`peerLocks`):
///    - Serializes handshakes (initiator/responder processing) for a specific peer.
/// 3. Map Lock (`mapLock`):
///    - Protects insertion, removal, and lookup in `controllers`.
///
/// Invalidation for panic wipe destroys all sessions and permanently transitions
/// the manager to invalidated state.
public final class SessionManager {

    private enum ManagerState {
        case active
        case invalidated
    }

    private let identity: MeshIdentity
    private let trustAuthority: any PeerBindingTrustAuthority
    private let localBindingIssuer: any LocalBindingIssuer
    private let lifecycleGate: (any RuntimeLifecycleGate)?

    private var controllers: [UUID: TrustedHandshakeController] = [:]
    private var peerLocks: [UUID: NSRecursiveLock] = [:]
    private let mapLock = NSRecursiveLock()
    private let lifecycleRwLock = ReadWriteLock()
    private var managerState: ManagerState = .active

    internal var testOperationHook: ((String) -> Void)?

    internal init(
        identity: MeshIdentity,
        trustAuthority: any PeerBindingTrustAuthority,
        localBindingIssuer: (any LocalBindingIssuer)? = nil,
        lifecycleGate: (any RuntimeLifecycleGate)? = nil
    ) {
        self.identity = identity
        self.trustAuthority = trustAuthority
        self.localBindingIssuer = localBindingIssuer ?? DefaultLocalBindingIssuer(identity: identity)
        self.lifecycleGate = lifecycleGate
    }

    public var isInvalidated: Bool {
        mapLock.lock()
        defer { mapLock.unlock() }
        return managerState == .invalidated || (lifecycleGate?.isInvalidated == true)
    }

    public var isActive: Bool {
        return !isInvalidated
    }

    private func getPeerLock(_ peerId: UUID) -> NSRecursiveLock {
        mapLock.lock()
        defer { mapLock.unlock() }
        if let l = peerLocks[peerId] { return l }
        let l = NSRecursiveLock()
        peerLocks[peerId] = l
        return l
    }

    /// True IFF the peer has an active TrustedHandshakeController in `.ready`
    /// and the manager is not invalidated.
    public func isReady(_ peerId: UUID) -> Bool {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return false }
            mapLock.lock()
            defer { mapLock.unlock() }
            guard let ctrl = controllers[peerId] else { return false }
            return ctrl.isReady && ctrl.state == .ready
        }
    }

    /// Start initiator handshake for [peerId] and emit HS1 (32 bytes).
    @discardableResult
    public func beginInitiator(_ peerId: UUID, remoteHint: Data) -> Data? {
        return initiatorStart(peerId, remoteHint: remoteHint)
    }

    public func initiatorStart(_ peerId: UUID, remoteHint: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            let pLock = getPeerLock(peerId)
            pLock.lock()
            defer { pLock.unlock() }

            guard isActive else { return nil }
            mapLock.lock()
            if controllers[peerId] != nil {
                mapLock.unlock()
                return nil
            }
            mapLock.unlock()

            let ctrl = TrustedHandshakeController.initiator(
                identity: identity,
                remoteHint: remoteHint,
                trustAuthority: trustAuthority,
                localBindingIssuer: localBindingIssuer
            )
            guard let hs1 = try? ctrl.initiatorWriteMessage1() else { return nil }

            mapLock.lock()
            guard isActive else {
                mapLock.unlock()
                ctrl.destroy()
                return nil
            }
            controllers[peerId] = ctrl
            mapLock.unlock()
            return hs1
        }
    }

    /// Process HS2 from responder and emit HS3 (197 bytes).
    /// On success, transitions controller to `.ready`. On failure or non-READY, drops entry and returns nil.
    public func initiatorProcessHs2(_ peerId: UUID, hs2: Data, advertisedRemoteHint: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            testOperationHook?("initiatorProcessHs2")
            let pLock = getPeerLock(peerId)
            pLock.lock()
            defer { pLock.unlock() }

            guard isActive else { return nil }
            mapLock.lock()
            guard let ctrl = controllers[peerId] else {
                mapLock.unlock()
                return nil
            }
            mapLock.unlock()

            guard let hs3 = ctrl.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: advertisedRemoteHint),
                  ctrl.isReady else {
                mapLock.lock()
                controllers.removeValue(forKey: peerId)
                mapLock.unlock()
                ctrl.destroy()
                return nil
            }
            return hs3
        }
    }

    /// Start responder handshake for [peerId], process inbound HS1, and emit HS2 (229 bytes).
    @discardableResult
    public func beginResponder(_ peerId: UUID, remoteHint: Data, hs1: Data) -> Data? {
        return responderProcessHs1(peerId, remoteHint: remoteHint, hs1: hs1)
    }

    public func responderProcessHs1(_ peerId: UUID, remoteHint: Data, hs1: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            testOperationHook?("responderProcessHs1")
            let pLock = getPeerLock(peerId)
            pLock.lock()
            defer { pLock.unlock() }

            guard isActive else { return nil }
            mapLock.lock()
            if controllers[peerId] != nil {
                mapLock.unlock()
                return nil
            }
            mapLock.unlock()

            let ctrl = TrustedHandshakeController.responder(
                identity: identity,
                remoteHint: remoteHint,
                trustAuthority: trustAuthority
            )
            guard let hs2 = try? ctrl.responderProcessMessage1AndWriteMessage2(hs1: hs1) else {
                ctrl.destroy()
                return nil
            }

            mapLock.lock()
            guard isActive else {
                mapLock.unlock()
                ctrl.destroy()
                return nil
            }
            controllers[peerId] = ctrl
            mapLock.unlock()
            return hs2
        }
    }

    /// Process inbound HS3 from initiator.
    /// Returns true IFF handshake reaches `.ready`.
    public func responderProcessHs3(_ peerId: UUID, hs3: Data, advertisedRemoteHint: Data) -> Bool {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return false }
            testOperationHook?("responderProcessHs3")
            let pLock = getPeerLock(peerId)
            pLock.lock()
            defer { pLock.unlock() }

            guard isActive else { return false }
            mapLock.lock()
            guard let ctrl = controllers[peerId] else {
                mapLock.unlock()
                return false
            }
            mapLock.unlock()

            guard ctrl.responderProcessMessage3(hs3: hs3, advertisedRemoteHint: advertisedRemoteHint),
                  ctrl.isReady else {
                mapLock.lock()
                controllers.removeValue(forKey: peerId)
                mapLock.unlock()
                ctrl.destroy()
                return false
            }
            return true
        }
    }

    /// Encrypt cleartext frame bytes for [peerId].
    /// Returns ciphertext IFF session is READY and manager is active.
    public func seal(_ peerId: UUID, _ frameBytes: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            testOperationHook?("seal")
            mapLock.lock()
            guard let ctrl = controllers[peerId] else {
                mapLock.unlock()
                return nil
            }
            guard ctrl.isReady && ctrl.state == .ready else {
                mapLock.unlock()
                return nil
            }
            mapLock.unlock()
            return ctrl.seal(frameBytes)
        }
    }

    /// Decrypt ciphertext bytes received from [peerId].
    /// Returns cleartext IFF session is READY and manager is active.
    public func open(_ peerId: UUID, _ ciphertext: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            testOperationHook?("open")
            mapLock.lock()
            guard let ctrl = controllers[peerId] else {
                mapLock.unlock()
                return nil
            }
            guard ctrl.isReady && ctrl.state == .ready else {
                mapLock.unlock()
                return nil
            }
            mapLock.unlock()
            return ctrl.open(ciphertext)
        }
    }

    public func drop(_ peerId: UUID) {
        lifecycleRwLock.withReadLock {
            mapLock.lock()
            let ctrl = controllers.removeValue(forKey: peerId)
            mapLock.unlock()
            ctrl?.destroy()
        }
    }

    public func destroyAll() {
        lifecycleRwLock.withWriteLock {
            mapLock.lock()
            defer { mapLock.unlock() }
            for ctrl in controllers.values {
                ctrl.destroy()
            }
            controllers.removeAll()
        }
    }

    public func invalidateForWipe() {
        lifecycleRwLock.withWriteLock {
            mapLock.lock()
            defer { mapLock.unlock() }
            managerState = .invalidated
            for ctrl in controllers.values {
                ctrl.destroy()
            }
            controllers.removeAll()
        }
    }
}
