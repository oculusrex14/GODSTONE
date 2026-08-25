import Foundation
import CryptoKit
import GodstoneCore

/// Per-peer trusted session registry (Stage 4 Phase C8.4B).
///
/// Replaces the untrusted raw NoiseSession registry. Owns and gates on
/// `TrustedHandshakeController` instances rather than raw Noise establishment.
/// Seal and open are permitted IFF the transport peer's controller has reached `.ready`.
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
    private let lock = NSRecursiveLock()
    private var managerState: ManagerState = .active

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
        lock.lock()
        defer { lock.unlock() }
        return managerState == .invalidated || (lifecycleGate?.isInvalidated == true)
    }

    public var isActive: Bool {
        return !isInvalidated
    }

    private func getPeerLock(_ peerId: UUID) -> NSRecursiveLock {
        lock.lock()
        defer { lock.unlock() }
        if let l = peerLocks[peerId] { return l }
        let l = NSRecursiveLock()
        peerLocks[peerId] = l
        return l
    }

    /// True IFF the peer has an active TrustedHandshakeController in `.ready`
    /// and the manager is not invalidated.
    public func isReady(_ peerId: UUID) -> Bool {
        guard isActive else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let ctrl = controllers[peerId] else { return false }
        return ctrl.isReady && ctrl.state == .ready
    }

    /// Start initiator handshake for [peerId] and emit HS1 (32 bytes).
    @discardableResult
    public func beginInitiator(_ peerId: UUID, remoteHint: Data) -> Data? {
        return initiatorStart(peerId, remoteHint: remoteHint)
    }

    public func initiatorStart(_ peerId: UUID, remoteHint: Data) -> Data? {
        guard isActive else { return nil }
        let pLock = getPeerLock(peerId)
        pLock.lock()
        defer { pLock.unlock() }

        guard isActive else { return nil }
        lock.lock()
        if controllers[peerId] != nil {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let ctrl = TrustedHandshakeController.initiator(
            identity: identity,
            remoteHint: remoteHint,
            trustAuthority: trustAuthority,
            localBindingIssuer: localBindingIssuer
        )
        guard let hs1 = try? ctrl.initiatorWriteMessage1() else { return nil }

        lock.lock()
        guard isActive else {
            lock.unlock()
            return nil
        }
        controllers[peerId] = ctrl
        lock.unlock()
        return hs1
    }

    /// Process HS2 from responder and emit HS3 (197 bytes).
    /// On success, transitions controller to `.ready`. On failure or non-READY, drops entry and returns nil.
    public func initiatorProcessHs2(_ peerId: UUID, hs2: Data, advertisedRemoteHint: Data) -> Data? {
        guard isActive else { return nil }
        let pLock = getPeerLock(peerId)
        pLock.lock()
        defer { pLock.unlock() }

        guard isActive else { return nil }
        lock.lock()
        guard let ctrl = controllers[peerId] else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let hs3 = ctrl.initiatorProcessMessage2(hs2: hs2, advertisedRemoteHint: advertisedRemoteHint),
              ctrl.isReady else {
            lock.lock()
            controllers.removeValue(forKey: peerId)
            lock.unlock()
            ctrl.destroy()
            return nil
        }
        return hs3
    }

    /// Start responder handshake for [peerId], process inbound HS1, and emit HS2 (229 bytes).
    @discardableResult
    public func beginResponder(_ peerId: UUID, remoteHint: Data, hs1: Data) -> Data? {
        return responderProcessHs1(peerId, remoteHint: remoteHint, hs1: hs1)
    }

    public func responderProcessHs1(_ peerId: UUID, remoteHint: Data, hs1: Data) -> Data? {
        guard isActive else { return nil }
        let pLock = getPeerLock(peerId)
        pLock.lock()
        defer { pLock.unlock() }

        guard isActive else { return nil }
        lock.lock()
        if controllers[peerId] != nil {
            lock.unlock()
            return nil
        }
        lock.unlock()

        let ctrl = TrustedHandshakeController.responder(
            identity: identity,
            remoteHint: remoteHint,
            trustAuthority: trustAuthority
        )
        guard let hs2 = try? ctrl.responderProcessMessage1AndWriteMessage2(hs1: hs1) else {
            ctrl.destroy()
            return nil
        }

        lock.lock()
        guard isActive else {
            lock.unlock()
            ctrl.destroy()
            return nil
        }
        controllers[peerId] = ctrl
        lock.unlock()
        return hs2
    }

    /// Process inbound HS3 from initiator.
    /// Returns true IFF handshake reaches `.ready`.
    public func responderProcessHs3(_ peerId: UUID, hs3: Data, advertisedRemoteHint: Data) -> Bool {
        guard isActive else { return false }
        let pLock = getPeerLock(peerId)
        pLock.lock()
        defer { pLock.unlock() }

        guard isActive else { return false }
        lock.lock()
        guard let ctrl = controllers[peerId] else {
            lock.unlock()
            return false
        }
        lock.unlock()

        guard ctrl.responderProcessMessage3(hs3: hs3, advertisedRemoteHint: advertisedRemoteHint),
              ctrl.isReady else {
            lock.lock()
            controllers.removeValue(forKey: peerId)
            lock.unlock()
            ctrl.destroy()
            return false
        }
        return true
    }

    /// Encrypt cleartext frame bytes for [peerId].
    /// Returns ciphertext IFF session is READY and manager is active.
    public func seal(_ peerId: UUID, _ frameBytes: Data) -> Data? {
        guard isActive else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let ctrl = controllers[peerId] else { return nil }
        guard ctrl.isReady && ctrl.state == .ready else { return nil }
        return ctrl.seal(frameBytes)
    }

    /// Decrypt ciphertext bytes received from [peerId].
    /// Returns cleartext IFF session is READY and manager is active.
    public func open(_ peerId: UUID, _ ciphertext: Data) -> Data? {
        guard isActive else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let ctrl = controllers[peerId] else { return nil }
        guard ctrl.isReady && ctrl.state == .ready else { return nil }
        return ctrl.open(ciphertext)
    }

    public func drop(_ peerId: UUID) {
        lock.lock()
        let ctrl = controllers.removeValue(forKey: peerId)
        lock.unlock()
        ctrl?.destroy()
    }

    public func destroyAll() {
        lock.lock()
        defer { lock.unlock() }
        for ctrl in controllers.values {
            ctrl.destroy()
        }
        controllers.removeAll()
    }

    public func invalidateForWipe() {
        lock.lock()
        defer { lock.unlock() }
        managerState = .invalidated
        for ctrl in controllers.values {
            ctrl.destroy()
        }
        controllers.removeAll()
    }
}
