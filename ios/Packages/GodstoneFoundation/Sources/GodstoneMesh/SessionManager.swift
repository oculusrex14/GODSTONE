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

    /// T08: one SessionSlot per relation keyed by the immutable RelationKey
    /// (the transport lookup handle). The slot owns its lock, so removing a
    /// retired slot reclaims its lock entry with it.
    private var slots: [UUID: SessionSlot] = [:]
    private let mapLock = NSRecursiveLock()
    /// T08: bounded last-generation registry. When a slot is reclaimed the
    /// generation its lease carried is remembered here, so a replacement for
    /// the SAME transport handle starts at the NEXT generation and a stale
    /// event captured against the previous incarnation can never be mistaken
    /// for one captured against the replacement. Bounded: the eldest
    /// remembered handle is evicted first, and a lost generation only weakens
    /// the stale-event guard - the terminal slot state and the replay window
    /// remain the authoritative defences.
    private var rememberedGenerations = [UUID: Int]()
    private var rememberedOrder = [UUID]()
    private let reclaimMaxRemembered = 256
    private let lifecycleRwLock = ReadWriteLock()
    private var managerState: ManagerState = .active

    internal var testOperationHook: ((String) -> Void)?
    internal var testInvalidationAttemptHook: (() -> Void)?

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

    /// T08 evidence hook: the slot handle for [peerId], live or held over.
    internal func slotForTest(_ peerId: UUID) -> SessionSlot? {
        slotFor(peerId)
    }

    /// T08 evidence hook: live entries in the relation-slot registry.
    internal func slotCountForTest() -> Int {
        mapLock.lock()
        defer { mapLock.unlock() }
        return slots.count
    }

    /// T08 evidence hook: remembered generations currently retained.
    internal func rememberedCountForTest() -> Int {
        mapLock.lock()
        defer { mapLock.unlock() }
        return rememberedGenerations.count
    }

    /// T08 evidence hook: lease generation of the live slot, if any.
    internal func slotLeaseGenerationForTest(_ peerId: UUID) -> Int? {
        guard let slot = slotFor(peerId) else { return nil }
        return slot.serialize { () -> Int in slot.lease.generation }
    }

    public var isInvalidated: Bool {
        mapLock.lock()
        defer { mapLock.unlock() }
        return managerState == .invalidated || (lifecycleGate?.isInvalidated == true)
    }

    public var isActive: Bool {
        return !isInvalidated
    }

    private func relationKey(_ peerId: UUID) -> RelationKey {
        return RelationKey(direction: .outboundCentral, peerId: peerId)
    }

    private func slotFor(_ peerId: UUID) -> SessionSlot? {
        mapLock.lock()
        defer { mapLock.unlock() }
        return slots[peerId]
    }

    private func getOrCreateSlot(_ peerId: UUID) -> SessionSlot {
        mapLock.lock()
        defer { mapLock.unlock() }
        if let slot = slots[peerId] { return slot }
        let generation = (rememberedGenerations[peerId] ?? -1) + 1
        let slot = SessionSlot(
            key: RelationKey(direction: .outboundCentral, peerId: peerId),
            lease: SlotLease(generation: generation))
        slots[peerId] = slot
        return slot
    }

    private func removeSlot(_ slot: SessionSlot) {
        mapLock.lock()
        defer { mapLock.unlock() }
        // Only the CURRENT incarnation is reclaimed: a stale caller that
        // still holds an already-replaced slot must not evict the replacement,
        // and the reclaimed lock entry leaves together with its slot.
        if slots[slot.key.peerId] === slot {
            slots.removeValue(forKey: slot.key.peerId)
            rememberGeneration(slot)
        }
    }

    private func rememberGeneration(_ slot: SessionSlot) {
        let handle = slot.key.peerId
        if let index = rememberedOrder.firstIndex(of: handle) {
            rememberedOrder.remove(at: index)
        } else if rememberedGenerations.count >= reclaimMaxRemembered {
            // removeFirst() hands back the element itself; eviction only
            // happens while the registry sits above its bound, so it is
            // never empty at this point.
            let victim = rememberedOrder.removeFirst()
            rememberedGenerations.removeValue(forKey: victim)
        }
        rememberedGenerations[handle] = slot.lease.generation
        rememberedOrder.append(handle)
    }

    /// True IFF the peer has an active TrustedHandshakeController in `.ready`
    /// and the manager is not invalidated.
    public func isReady(_ peerId: UUID) -> Bool {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return false }
            guard let slot = slotFor(peerId) else { return false }
            return slot.serialize { () -> Bool in
                guard let ctrl = slot.controller else { return false }
                return ctrl.isReady && ctrl.state == .ready
            }
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
            let slot = getOrCreateSlot(peerId)
            return slot.serialize { () -> Data? in
                guard isActive else { return nil }
                guard slot.state == .active else { return nil }
                guard slot.controller == nil else { return nil }
                let ctrl = TrustedHandshakeController.initiator(
                    identity: identity,
                    remoteHint: remoteHint,
                    trustAuthority: trustAuthority,
                    localBindingIssuer: localBindingIssuer
                )
                guard let hs1 = try? ctrl.initiatorWriteMessage1() else {
                    ctrl.destroy()
                    return nil
                }
                guard isActive else {
                    _ = slot.retire()
                    removeSlot(slot)
                    ctrl.destroy()
                    return nil
                }
                slot.controller = ctrl
                return hs1
            }
        }
    }

    /// Process HS2 from responder and emit HS3 (197 bytes).
    /// On success, transitions controller to `.ready`. On failure or non-READY, drops entry and returns nil.
    public func initiatorProcessHs2(_ peerId: UUID, hs2: Data, advertisedRemoteHint: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            testOperationHook?("initiatorProcessHs2")
            guard let slot = slotFor(peerId) else { return nil }
            var doomed: TrustedHandshakeController? = nil
            let result = slot.serialize { () -> Data? in
                guard isActive, slot.state == .active else { return nil }
                guard let ctrl = slot.controller else { return nil }
                guard let hs3 = ctrl.initiatorProcessMessage2(
                    hs2: hs2, advertisedRemoteHint: advertisedRemoteHint),
                    ctrl.isReady else {
                    // T08: terminal transition serialized with the operation;
                    // the destructive destroy is routed outside the slot lock.
                    doomed = slot.retire()
                    return nil
                }
                return hs3
            }
            if let doomed = doomed {
                removeSlot(slot)
                doomed.destroy()
            }
            return result
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
            let slot = getOrCreateSlot(peerId)
            return slot.serialize { () -> Data? in
                guard isActive, slot.state == .active else { return nil }
                guard slot.controller == nil else { return nil }
                let ctrl = TrustedHandshakeController.responder(
                    identity: identity,
                    remoteHint: remoteHint,
                    trustAuthority: trustAuthority
                )
                guard let hs2 = try? ctrl.responderProcessMessage1AndWriteMessage2(hs1: hs1) else {
                    ctrl.destroy()
                    return nil
                }
                guard isActive else {
                    _ = slot.retire()
                    removeSlot(slot)
                    ctrl.destroy()
                    return nil
                }
                slot.controller = ctrl
                return hs2
            }
        }
    }

    public func responderProcessHs3(_ peerId: UUID, hs3: Data, advertisedRemoteHint: Data) -> Bool {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return false }
            testOperationHook?("responderProcessHs3")
            guard let slot = slotFor(peerId) else { return false }
            var doomed: TrustedHandshakeController? = nil
            let result = slot.serialize {
                guard isActive, slot.state == .active else { return false }
                guard let ctrl = slot.controller else { return false }
                let ok = ctrl.responderProcessMessage3(
                    hs3: hs3, advertisedRemoteHint: advertisedRemoteHint)
                if !ok || !ctrl.isReady {
                    doomed = slot.retire()
                    return false
                }
                return true
            }
            if let doomed = doomed {
                removeSlot(slot)
                doomed.destroy()
            }
            return result
        }
    }

    /// Encrypt cleartext frame bytes for [peerId].
    /// Returns ciphertext IFF session is READY and manager is active.
    public func seal(_ peerId: UUID, _ frameBytes: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            testOperationHook?("seal")
            guard let slot = slotFor(peerId) else { return nil }
            return slot.serialize { () -> Data? in
                guard slot.state == .active else { return nil }
                guard let ctrl = slot.controller else { return nil }
                guard ctrl.isReady && ctrl.state == .ready else { return nil }
                return ctrl.seal(frameBytes)
            }
        }
    }

    /// Decrypt ciphertext bytes received from [peerId].
    /// Returns cleartext IFF session is READY and manager is active.
    public func open(_ peerId: UUID, _ ciphertext: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            testOperationHook?("open")
            guard let slot = slotFor(peerId) else { return nil }
            return slot.serialize { () -> Data? in
                guard slot.state == .active else { return nil }
                guard let ctrl = slot.controller else { return nil }
                guard ctrl.isReady && ctrl.state == .ready else { return nil }
                return ctrl.open(ciphertext)
            }
        }
    }

    public func drop(_ peerId: UUID) {
        lifecycleRwLock.withReadLock {
            guard let slot = slotFor(peerId) else { return }
            // T08: the terminal transition is serialized; the destructive
            // destroy is routed OUTSIDE the slot lock.
            removeSlot(slot)
            _ = slot.retire()?.destroy()
        }
    }

    public func destroyAll() {
        lifecycleRwLock.withWriteLock {
            mapLock.lock()
            defer { mapLock.unlock() }
            for slot in slots.values {
                slot.retire()?.destroy()
            }
            slots.removeAll()
        }
    }

    public func invalidateForWipe() {
        testInvalidationAttemptHook?()
        lifecycleRwLock.withWriteLock {
            mapLock.lock()
            defer { mapLock.unlock() }
            managerState = .invalidated
            for slot in slots.values {
                slot.state = .invalidated
                slot.controller?.destroy()
                slot.controller = nil
            }
            slots.removeAll()
        }
    }
}
