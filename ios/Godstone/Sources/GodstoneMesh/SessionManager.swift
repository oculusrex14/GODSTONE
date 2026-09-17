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
/// T17: the typed outcome of one authenticated-open operation at the session
/// registry, in the vocabulary shared with the Android Noise layer
/// (CryptoOpenResult: Authenticated, Rejected, Expired).
public enum CryptoOpenResult: Equatable, Sendable {
    case authenticated(Data)
    case rejected
    case expired
}

public final class SessionManager {

    private enum ManagerState {
        case active
        case invalidated
    }

    private let identity: MeshIdentity
    private let trustAuthority: any PeerBindingTrustAuthority
    private let localBindingIssuer: any LocalBindingIssuer
    private let lifecycleGate: (any RuntimeLifecycleGate)?

    /// GS-CTRL-002 (R02): the per-relation registry under the contract's own name --
    /// every entry owns exactly one `TrustedHandshakeController` (`SessionSlot.controller`)
    /// and never a raw `NoiseSession`. T08 renamed this map to `slots` when it made the key a
    /// RELATION rather than a peer handle, and the repository's composition control, which
    /// readeth CODE TEXT with comments stripped, then reported a registry that doth not exist.
    /// The vocabulary is aligned rather than the rule loosened.
    ///
    /// CRYPTO-001 (T08 completion): the map is keyed by the RELATION'S PLACE --
    /// direction and handle -- and every entry carrieth its full `RelationAdmission`.
    /// ONE live incarnation per place: a newer incarnation SUPERSEDES the standing
    /// one, so the registry can never hold two lives of one relation, and an
    /// operation addressed to the superseded incarnation is refused as `.stale`
    /// without touching its replacement.
    ///
    /// The T08 "remembered generation" registry is RECLAIMED here, and deliberately:
    /// the generation now cometh from the orchestration owner through the admission,
    /// so a crypto-side history had nothing left to remember. A history whose only
    /// duty was to paper over an absent key is a liability, not a defence.
    private var controllers: [RelationHandle: SessionSlot] = [:]
    private let mapLock = NSRecursiveLock()
    private let lifecycleRwLock = ReadWriteLock()
    private var managerState: ManagerState = .active

    /// GS-CTRL-002 / CRYPTO-002 (the finding's TITLE): THE RETIREMENT EVENT TO THE TRANSPORT OWNER.
    ///
    /// "Session retirement never reaches the transport authority" -- the transport could tell the manager to drop a
    /// relation (six sites do), and NOTHING travelled the other way. So a session that reached its own terminus left
    /// the transport publishing a peer as ready, holding its leases and its connection, with no fresh handshake.
    /// THIS IS THE OTHER DIRECTION: the notice carrieth the EXACT admission (the token the transport minted for that
    /// relation, so a notice for a retired incarnation cannot touch its replacement) and the reason.
    ///
    /// DELIVERED OUTSIDE EVERY LOCK -- `retireSlotTerminally` only RECORDETH the notice and the drain delivereth it
    /// after the caller's locks are released, because a handler that closeth a connection and releaseth leases must
    /// be free to call back without deadlocking the registry that told it.
    /// GS-CTRL-002 / CRYPTO-002 STEP 4, THE AUDIT'S OWN ORDER: "Arm an IMMUTABLE RELATION-OWNED AGE TIMER at trusted
    /// establishment. Idle expiry must enter the same slot transition; OLD TIMER CALLBACKS CANNOT RETIRE A
    /// REPLACEMENT."
    ///
    /// AT THIS STEP THE SEAM ALONE EXISTETH (it answereth NOTHING ARMED), so the arm that demandeth a timer FAILETH ON
    /// ITS OWN SUBJECT rather than at compile time. The deadline is expressed in the INJECTED clock's own units -- the
    /// only clock this store trusteth -- and the firing is delegated to a SCHEDULER SEAM rather than to a run loop,
    /// because a registry that owned a run loop would own the process's liveness as well as its sessions.
    /// The armed deadlines, by admission. IMMUTABLE PER ADMISSION: arming again for an admission that already
    /// carrieth a deadline doth NOT extend it -- the audit asketh for an "IMMUTABLE relation-owned age timer", and a
    /// deadline that could be pushed back by a later event would be no deadline at all.
    private var armedAgeDeadlines: [RelationAdmission: Int64] = [:]

    internal func armedAgeDeadlinesForTest() -> [Int64] { armedAgeDeadlines.values.sorted() }

    /// THE FIRING'S SEAM (CRYPTO-002 step 4's second half). The deadline is ARMEd here; the delivering belongeth to
    /// whoever OWNETH A RUN LOOP (`scheduleAgeDeadline`), and the callback carrieth **THE EXACT ADMISSION** -- because
    /// the audit's clause is that "OLD TIMER CALLBACKS CANNOT RETIRE A REPLACEMENT", and a callback that carrieth only
    /// a peer would have no way to tell an incarnation from its successor.
    /// INSTALLING A SCHEDULER **RE-DELIVERETH EVERY ALREADY-ARMED DEADLINE**, and the reason is not convenience: a
    /// manager may be established BEFORE the owner of the run loop existeth (the composition buildeth the registry
    /// first), and a deadline armed into nothing would be a timer that never fireth -- which is exactly the audit's
    /// charge in another dress. THE ARMING AND THE DELIVERY ARE THEREFORE IDEMPOTENT IN BOTH ORDERS.
    internal var scheduleAgeDeadline: ((_ admission: RelationAdmission, _ deadlineMono: Int64, _ fire: @escaping () -> Void) -> Void)? {
        didSet {
            guard let schedule = scheduleAgeDeadline else { return }
            mapLock.lock()
            let armed = armedAgeDeadlines
            mapLock.unlock()
            for (admission, deadline) in armed {
                schedule(admission, deadline) { [weak self] in self?.fireAgeDeadline(admission) }
            }
        }
    }

    /// Called when the deadline is reached. AT THIS STEP IT IS A SEAM: it retireth NOTHING, so the arm that
    /// demandeth an idle expiry to enter "the same slot transition" FAILETH ON ITS OWN SUBJECT.
    internal func fireAgeDeadline(_ admission: RelationAdmission) {
        // *** THE EXACT INCARNATION IS THE WHOLE DEFENCE, AND IT IS WHY THE CALLBACK CARRIETH AN ADMISSION RATHER THAN
        // A PEER: if `slotFor(admission)` findeth nothing -- because the incarnation was replaced, dropped or already
        // retired -- then THIS CALLBACK IS THE OLD ONE, and the audit's clause applyeth: "OLD TIMER CALLBACKS CANNOT
        // RETIRE A REPLACEMENT." A successor carrieth a DIFFERENT admission, so it cannot be matched by this token. ***
        guard slotFor(admission) != nil else { return }
        // AND IT ENTERETH **THE SAME SLOT TRANSITION** the read path entereth -- the same single terminus, the same
        // token-bound notice -- so an idle expiry and an observed expiry cannot leave the world in two shapes.
        _ = retireSlotTerminally(admission, reason: "idle age deadline reached")
        drainRetirementNotices()
    }

    private func armAgeTimer(_ admission: RelationAdmission, controller: TrustedHandshakeController) {
        mapLock.lock(); defer { mapLock.unlock() }
        guard armedAgeDeadlines[admission] == nil else { return }   // IMMUTABLE: never extended
        let deadline = Int64(bitPattern: controller.noiseSession.ageDeadlineMono())
        armedAgeDeadlines[admission] = deadline
        // THE DELIVERY IS DELEGATED, NOT OWNED: a registry that owned a run loop would own the process's liveness.
        if let schedule = scheduleAgeDeadline {
            schedule(admission, deadline) { [weak self] in self?.fireAgeDeadline(admission) }
        }
    }

    internal var onTerminalRetirement: ((RelationAdmission, String) -> Void)?

    private var pendingRetirementNotices: [(RelationAdmission, String)] = []
    private let noticeLock = NSLock()

    private func recordRetirementNotice(_ admission: RelationAdmission, reason: String) {
        noticeLock.lock()
        pendingRetirementNotices.append((admission, reason))
        noticeLock.unlock()
    }

    /// Deliver every notice recorded so far, OUTSIDE the locks. Called at the end of the two public entries that can
    /// perform a terminus, never inside a locked region.
    internal func drainRetirementNotices() {
        noticeLock.lock()
        let pending = pendingRetirementNotices
        pendingRetirementNotices.removeAll()
        noticeLock.unlock()
        guard let sink = onTerminalRetirement else { return }
        for (admission, reason) in pending { sink(admission, reason) }
    }

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

    /// T08 evidence hook: the live incarnation standing for [peerId]. The
    /// outbound incarnation is preferred -- the host courts which drive ONE
    /// relation per handle speak that direction -- and an inbound-only handle
    /// is served when it is the one that standeth.
    internal func slotForTest(_ peerId: UUID) -> SessionSlot? {
        mapLock.lock()
        defer { mapLock.unlock() }
        if let outbound = controllers[RelationHandle(direction: .outboundCentral, peerId: peerId)] {
            return outbound
        }
        for (handle, slot) in controllers where handle.peerId == peerId { return slot }
        return nil
    }

    /// T08 evidence hook: live entries in the relation-slot registry.
    internal func slotCountForTest() -> Int {
        mapLock.lock()
        defer { mapLock.unlock() }
        return controllers.count
    }

    /// CRYPTO-001 evidence hook: the live incarnations of one platform handle.
    /// One per direction; TWO only while an inbound and an outbound relation of
    /// the same peer id stand together, which is the separation this finding
    /// demandeth.
    internal func incarnationCountForTest(_ peerId: UUID) -> Int {
        mapLock.lock()
        defer { mapLock.unlock() }
        return controllers.keys.filter { $0.peerId == peerId }.count
    }

    /// CRYPTO-001 evidence hook: the incarnation standing for an admission, if one
    /// standeth. The courts use it to MEASURE that their pre-pairing and the transport's
    /// own admission are one identity.
    internal func slotAdmissionForTest(_ admission: RelationAdmission) -> RelationAdmission? {
        slotFor(admission)?.admission
    }

    /// T08 evidence hook: the ORCHESTRATION-OWNED generation of the live
    /// incarnation, read from its admission. The registry minteth none.
    internal func slotLeaseGenerationForTest(_ peerId: UUID) -> Int? {
        guard let slot = slotForTest(peerId) else { return nil }
        return slot.serialize { () -> Int in Int(slot.generation) }
    }

    public var isInvalidated: Bool {
        mapLock.lock()
        defer { mapLock.unlock() }
        return managerState == .invalidated || (lifecycleGate?.isInvalidated == true)
    }

    public var isActive: Bool {
        return !isInvalidated
    }

    /// THE PRE-T08 HOST VOCABULARY (CRYPTO-001). A host court which driveth ONE
    /// relation per platform handle, and never mixeth directions, nameth that
    /// relation here. PRODUCTION NEVER SPEAKETH THIS: the transport holdeth the
    /// relation's admission -- minted by the link owner at admission and carried
    /// through every queued record, timer and teardown -- and presenteth THAT.
    /// An arm of the canonical suite refuseth this vocabulary in production
    /// sources by name, so the refusal is a control rather than an intention.
    internal static func hostAdmission(_ peerId: UUID,
                                       direction: BleDirection = .outboundCentral,
                                       generation: UInt64 = 0) -> RelationAdmission {
        RelationAdmission(direction: direction, peerId: peerId,
                          generation: generation, transportEpoch: 0)
    }

    /// IOS-05 / T27 (step 3): THE IMMUTABLE FULL NODE ID OF A RELATION -- the sixteen octets the
    /// TRUSTED HANDSHAKE validated and the controller RETAINED. Never derived from the static DH key
    /// (a DIFFERENT identity), never a MAC, a hint or a station handle; nil while trust was never
    /// marked, which is what maketh the PRE-AUTH budget the right instrument for everything earlier.
    ///
    /// CRYPTO-001: the query is addressed to an INCARNATION. A node id read against a
    /// relation that hath been replaced is nil, which is the same answer as an unmarked
    /// relation -- and the right one: no trust standeth for that incarnation.
    func authenticatedNodeIdOf(_ admission: RelationAdmission) -> Data? {
        guard let slot = slotFor(admission) else { return nil }
        return slot.serialize { slot.controller?.authenticatedNodeId }
    }

    /// IOS-04 (T24) slice (b): the authenticated IDENTITY PUBLIC KEY for a relation, under the SAME slot-serialisation
    /// discipline as the node-id accessor above. It is the source a `TrustedPeer` needeth -- `nodeId16` is DERIVED from
    /// this key -- and the twin of the android accessor added at round 225.
    func authenticatedIdentityPubOf(_ admission: RelationAdmission) -> Data? {
        guard let slot = slotFor(admission) else { return nil }
        return slot.serialize { slot.controller?.authenticatedIdentityPub }
    }

    /// CRYPTO-001: THE LOOKUP ITSELF IS THE LAW. An incarnation standeth IFF the
    /// entry's whole admission equalleth the one presented -- direction, handle,
    /// orchestration generation AND transport epoch. Anything else is no slot at
    /// all, so no operation of a replaced relation can reach its replacement.
    private func slotFor(_ admission: RelationAdmission) -> SessionSlot? {
        mapLock.lock()
        defer { mapLock.unlock() }
        guard let slot = controllers[admission.handle] else { return nil }
        guard slot.admission == admission else { return nil }
        return slot
    }

    /// GS-CTRL-002 (R06): the PER-PEER (per-relation) serialisation point, under the name the
    /// composition contract useth. The slot owneth the lock; `SessionSlot.serialize` acquireth the
    /// very same lock, and `isReady` taketh it explicitly through this accessor.
    private func getPeerLock(_ admission: RelationAdmission) -> NSRecursiveLock? {
        return slotFor(admission)?.getPeerLock()
    }

    /// CRYPTO-001: admit an incarnation, SUPERSEDING the standing one for the
    /// same place. The map lock is never held while the incumbent's slot lock is
    /// entered: the destructive retirement of the superseded incarnation runneth
    /// after the map lock is releas'd, so the documented order (gate, slot, map)
    /// is kept whole.
    private func getOrCreateSlot(_ admission: RelationAdmission) -> SessionSlot {
        var superseded: SessionSlot? = nil
        mapLock.lock()
        if let standing = controllers[admission.handle] {
            if standing.admission == admission {
                mapLock.unlock()
                return standing
            }
            superseded = standing
        }
        let fresh = SessionSlot(admission: admission)
        controllers[admission.handle] = fresh
        mapLock.unlock()
        if let superseded = superseded {
            _ = superseded.retire()?.destroy()
        }
        return fresh
    }

    /// Compare-and-remove on the WHOLE admission. A teardown addressed to an
    /// incarnation which no longer standeth taketh nothing away.
    private func removeSlot(_ admission: RelationAdmission) -> SessionSlot? {
        mapLock.lock()
        defer { mapLock.unlock() }
        guard let slot = controllers[admission.handle], slot.admission == admission else { return nil }
        controllers.removeValue(forKey: admission.handle)
        return slot
    }

    /// True IFF the peer has an active TrustedHandshakeController in `.ready`
    /// and the manager is not invalidated.
    public func isReady(_ admission: RelationAdmission) -> Bool {
        let answer: Bool = lifecycleRwLock.withReadLock {
            guard isActive else { return false }
            guard let slot = slotFor(admission) else { return false }
            // GS-CTRL-002 (R06): the readiness query taketh the PER-PEER lock EXPLICITLY, under the
            // name the composition contract useth -- the same lock `SessionSlot.serialize` acquireth,
            // so the behaviour is unchanged and the name is load-bearing rather than decorative.
            guard let peerLock = getPeerLock(admission) else { return false }
            peerLock.lock()
            defer { peerLock.unlock() }
            guard let ctrl = slot.controller else { return false }
            // CRYPTO-002: THE IDLE PATH. A session that reached its own terminus while `state` still sayeth
            // `.ready` must not keep publishing ready -- and THE PRIMITIVE IS THE AUTHORITY on its own terminus
            // (`isEstablished` falleth when it retireth, which the T07 court already proved at the primitive).
            // The retirement is performed HERE rather than merely reported, so the slot cannot leak either.
            if ctrl.state == .ready && ctrl.isTerminallyRetired {
                retireSlotTerminally(admission)
                return false
            }
            return ctrl.isReady && ctrl.state == .ready
        }
        drainRetirementNotices()
        return answer
    }

    /// Start initiator handshake for a relation and emit HS1 (32 bytes).
    @discardableResult
    public func beginInitiator(_ admission: RelationAdmission, remoteHint: Data) -> Data? {
        return initiatorStart(admission, remoteHint: remoteHint)
    }

    public func initiatorStart(_ admission: RelationAdmission, remoteHint: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            let slot = getOrCreateSlot(admission)
            guard slot.admission == admission else { return nil }
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
                    removeSlot(admission)
                    ctrl.destroy()
                    return nil
                }
                slot.controller = ctrl
                // CRYPTO-002 STEP 4: THE AGE TIMER IS ARMED WHERE TRUST IS ESTABLISHED, and NOWHERE ELSE.
                armAgeTimer(admission, controller: ctrl)
                return hs1
            }
        }
    }

    /// Process HS2 from responder and emit HS3 (197 bytes).
    /// On success, transitions controller to `.ready`. On failure or non-READY, drops entry and returns nil.
    public func initiatorProcessHs2(_ admission: RelationAdmission, hs2: Data, advertisedRemoteHint: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            testOperationHook?("initiatorProcessHs2")
            guard let slot = slotFor(admission) else { return nil }
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
                removeSlot(admission)
                doomed.destroy()
            }
            return result
        }
    }

    /// Start responder handshake for a relation, process inbound HS1, and emit HS2 (229 bytes).
    @discardableResult
    public func beginResponder(_ admission: RelationAdmission, remoteHint: Data, hs1: Data) -> Data? {
        return responderProcessHs1(admission, remoteHint: remoteHint, hs1: hs1)
    }

    public func responderProcessHs1(_ admission: RelationAdmission, remoteHint: Data, hs1: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            testOperationHook?("responderProcessHs1")
            let slot = getOrCreateSlot(admission)
            guard slot.admission == admission else { return nil }
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
                    removeSlot(admission)
                    ctrl.destroy()
                    return nil
                }
                slot.controller = ctrl
                // CRYPTO-002 STEP 4: THE AGE TIMER IS ARMED WHERE TRUST IS ESTABLISHED, and NOWHERE ELSE.
                armAgeTimer(admission, controller: ctrl)
                return hs2
            }
        }
    }

    public func responderProcessHs3(_ admission: RelationAdmission, hs3: Data, advertisedRemoteHint: Data) -> Bool {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return false }
            testOperationHook?("responderProcessHs3")
            guard let slot = slotFor(admission) else { return false }
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
                removeSlot(admission)
                doomed.destroy()
            }
            return result
        }
    }

    /// Encrypt cleartext frame bytes for a relation.
    /// Returns ciphertext IFF session is READY and manager is active.
    public func seal(_ admission: RelationAdmission, _ frameBytes: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            testOperationHook?("seal")
            guard let slot = slotFor(admission) else { return nil }
            return slot.serialize { () -> Data? in
                guard slot.state == .active else { return nil }
                guard let ctrl = slot.controller else { return nil }
                guard ctrl.isReady && ctrl.state == .ready else { return nil }
                return ctrl.seal(frameBytes)
            }
        }
    }

    /// Decrypt ciphertext bytes received for a relation.
    /// Returns cleartext IFF session is READY and manager is active.
    public func open(_ admission: RelationAdmission, _ ciphertext: Data) -> Data? {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return nil }
            testOperationHook?("open")
            guard let slot = slotFor(admission) else { return nil }
            return slot.serialize { () -> Data? in
                guard slot.state == .active else { return nil }
                guard let ctrl = slot.controller else { return nil }
                guard ctrl.isReady && ctrl.state == .ready else { return nil }
                return ctrl.open(ciphertext)
            }
        }
    }

    /// T17: the typed twin of the nullable open. The arms that answer nil -
    /// the inactive manager, the absent slot, the slot past its active life,
    /// the absent or unready controller - are recorded as rejected; the
    /// cleartext of a verified frame is recorded as authenticated.
    ///
    /// CRYPTO-001: the ABSENT SLOT arm now covereth the superseded relation: an
    /// operation addressed to a replaced incarnation is the same typed refusal
    /// as one addressed to a handle that never handshook.
    public func openWithResult(_ admission: RelationAdmission, _ ciphertext: Data) -> CryptoOpenResult {
        return lifecycleRwLock.withReadLock {
            guard isActive else { return .rejected }
            testOperationHook?("open")
            guard let slot = slotFor(admission) else { return .rejected }
            let outcome = slot.serialize { () -> CryptoOpenResult in
                guard slot.state == .active else { return .rejected }
                guard let ctrl = slot.controller else { return .rejected }
                // GS-CTRL-002 / CRYPTO-002: THE CONTROLLER IS ASKED **ONCE**, AND ITS TYPED ANSWER TRAVELS. The
                // pre-checks against `ctrl.isReady`/`ctrl.state` used to swallow the difference between A PACKET
                // THE PEER GOT WRONG (rejected) and THE SESSION REACHING ITS OWN TERMINUS (expired) -- so the
                // manager could never answer `expired`, and the audit's first probe measured exactly that.
                // TWO ENUMS SHARE A NAME AND A VOCABULARY (`NoiseSession.CryptoOpenResult` the primitive's,
                // `SessionManager.CryptoOpenResult` the registry's), SO THE CONVERSION HAPPENETH HERE, AT THE
                // BOUNDARY WHERE BOTH SPACES ARE KNOWN -- EXPLICITLY AND EXHAUSTIVELY. The compiler refused the
                // implicit form in one line ("cannot convert value of type NoiseSession.CryptoOpenResult to closure
                // result type CryptoOpenResult"): THE ROUND-314 FAMILY AGAIN -- TWO SPACES, ONE ROAD.
                switch ctrl.openWithResult(ciphertext) {
                case .authenticated(let clear): return .authenticated(clear)
                case .expired: return .expired
                case .rejected:
                    guard ctrl.isReady && ctrl.state == .ready else { return .rejected }
                    return .rejected
                }
            }
            // TERMINAL RETIREMENT, ROUTED OUTSIDE THE SLOT LOCK (the discipline `drop` already followeth): the exact
            // incarnation is removed and destroyed, so a retired session cannot leak its slot.
            if case .expired = outcome { retireSlotTerminally(admission, reason: "age budget exhausted") }
            drainRetirementNotices()
            return outcome
        }
    }

    /// CRYPTO-002: THE TERMINUS, IN ONE PLACE. The exact incarnation is removed and its controller destroyed
    /// OUTSIDE the slot lock -- the same order `drop` useth -- and the answer sayeth whether one truly stood.
    @discardableResult
    private func retireSlotTerminally(_ admission: RelationAdmission, reason: String = "terminus") -> RelationRetirement {
        // `.stale` when no such incarnation standeth -- the replacement is untouched, AND NO NOTICE IS SENT, because
        // a notice for an incarnation that no longer standeth must not reach the transport and retire its successor.
        guard let slot = removeSlot(admission) else { return .stale }
        _ = slot.retire()?.destroy()
        recordRetirementNotice(admission, reason: reason)
        return .retired
    }

    /// CRYPTO-001: THE RELATION'S TEARDOWN, ADDRESSED TO AN INCARNATION.
    /// `.stale` when no such incarnation standeth -- the replacement is untouched.
    @discardableResult
    public func drop(_ admission: RelationAdmission) -> RelationRetirement {
        return lifecycleRwLock.withReadLock {
            // T08: the terminal transition is serialized; the destructive
            // destroy is routed OUTSIDE the slot lock.
            guard let slot = removeSlot(admission) else { return .stale }
            _ = slot.retire()?.destroy()
            return .retired
        }
    }

    /// THE APP-LEVEL DEPARTURE: every incarnation of the platform handle is
    /// retired, whatever generation standeth. A node which learneth that a peer
    /// hath departed knoweth the PEER, not the relation -- and it must not
    /// pretend otherwise, so it speaketh this verb rather than guessing an
    /// admission. The answer counteth the incarnations retired.
    @discardableResult
    public func retireIncarnations(ofPeerId peerId: UUID) -> Int {
        return lifecycleRwLock.withReadLock {
            var doomed = [SessionSlot]()
            mapLock.lock()
            let handles = controllers.keys.filter { $0.peerId == peerId }
            for handle in handles {
                if let slot = controllers.removeValue(forKey: handle) { doomed.append(slot) }
            }
            mapLock.unlock()
            for slot in doomed { _ = slot.retire()?.destroy() }
            return doomed.count
        }
    }

    // ---------------------------------------------------------------- the pre-T08 host vocabulary
    //
    // These overloads exist for the HOST COURTS which drive one relation per
    // platform handle and never mix directions. They mint the documented
    // placeholder admission (outbound, generation 0, epoch 0). PRODUCTION
    // SPEAKETH THE KEYED SURFACE ABOVE ONLY, and the canonical suite carrieth an
    // arm which readeth the production sources and refuseth this vocabulary
    // there by name.
    //
    // They are `internal` on purpose: a consumer outside this module cannot
    // reach them at all, and inside the module they are named for what they are.
    //
    // A handle-scoped court which READS (isReady, seal, open, the authenticated
    // accessors) is answered from whichever incarnation standeth -- the outbound
    // one first -- because it name a HANDLE and not an incarnation. A court
    // which MUTATES nameth the direction its role playeth: the initiator surface
    // useth the outbound incarnation, the responder surface the inbound one.

    /// The host vocabulary nameth a HANDLE, not an incarnation, and the courts which speak it
    /// drive ONE relation per handle whose incarnation the link owner may have advanced. A
    /// handle-scoped READ is therefore answered from whatever incarnation standeth -- the
    /// outbound one first -- and from the placeholder when none standeth. This is exactly the
    /// pre-T08 reading, kept for those courts alone: a court which witnesseth STALENESS speaketh
    /// the keyed surface, where the incarnation is named and the refusal is typed.
    private func hostIncarnations(_ peerId: UUID) -> [RelationAdmission] {
        mapLock.lock()
        defer { mapLock.unlock() }
        let standing = [RelationHandle(direction: .outboundCentral, peerId: peerId),
                        RelationHandle(direction: .inboundPeripheral, peerId: peerId)]
            .compactMap { controllers[$0]?.admission }
        if standing.isEmpty {
            return [Self.hostAdmission(peerId, direction: .outboundCentral),
                    Self.hostAdmission(peerId, direction: .inboundPeripheral)]
        }
        return standing
    }

    /// The host vocabulary's HANDSHAKE step: the standing incarnation of that direction when
    /// one standeth -- so a court which pre-paired through the link owner's admission continueth
    /// on the SAME incarnation -- and the documented placeholder when the court is the one which
    /// beginneth the relation.
    private func hostHandshakeIncarnation(_ peerId: UUID, direction: BleDirection) -> RelationAdmission {
        mapLock.lock()
        defer { mapLock.unlock() }
        if let standing = controllers[RelationHandle(direction: direction, peerId: peerId)] {
            return standing.admission
        }
        return Self.hostAdmission(peerId, direction: direction)
    }

    internal func isReady(_ peerId: UUID) -> Bool {
        hostIncarnations(peerId).contains { isReady($0) }
    }

    internal func beginInitiator(_ peerId: UUID, remoteHint: Data) -> Data? {
        initiatorStart(hostHandshakeIncarnation(peerId, direction: .outboundCentral),
                       remoteHint: remoteHint)
    }

    internal func initiatorStart(_ peerId: UUID, remoteHint: Data) -> Data? {
        initiatorStart(hostHandshakeIncarnation(peerId, direction: .outboundCentral),
                       remoteHint: remoteHint)
    }

    internal func initiatorProcessHs2(_ peerId: UUID, hs2: Data, advertisedRemoteHint: Data) -> Data? {
        initiatorProcessHs2(hostHandshakeIncarnation(peerId, direction: .outboundCentral),
                            hs2: hs2, advertisedRemoteHint: advertisedRemoteHint)
    }

    internal func beginResponder(_ peerId: UUID, remoteHint: Data, hs1: Data) -> Data? {
        responderProcessHs1(hostHandshakeIncarnation(peerId, direction: .inboundPeripheral),
                            remoteHint: remoteHint, hs1: hs1)
    }

    internal func responderProcessHs1(_ peerId: UUID, remoteHint: Data, hs1: Data) -> Data? {
        responderProcessHs1(hostHandshakeIncarnation(peerId, direction: .inboundPeripheral),
                            remoteHint: remoteHint, hs1: hs1)
    }

    internal func responderProcessHs3(_ peerId: UUID, hs3: Data, advertisedRemoteHint: Data) -> Bool {
        responderProcessHs3(hostHandshakeIncarnation(peerId, direction: .inboundPeripheral),
                            hs3: hs3, advertisedRemoteHint: advertisedRemoteHint)
    }

    internal func seal(_ peerId: UUID, _ frameBytes: Data) -> Data? {
        for admission in hostIncarnations(peerId) {
            if let sealed = seal(admission, frameBytes) { return sealed }
        }
        return nil
    }

    internal func open(_ peerId: UUID, _ ciphertext: Data) -> Data? {
        for admission in hostIncarnations(peerId) {
            if let clear = open(admission, ciphertext) { return clear }
        }
        return nil
    }

    internal func openWithResult(_ peerId: UUID, _ ciphertext: Data) -> CryptoOpenResult {
        // CRYPTO-002: THE AGGREGATE MUST NOT SWALLOW A TERMINUS. The old body returned `.rejected` for EVERYTHING
        // that did not authenticate -- so an exhausted session was indistinguishable from a bad packet AT THE ONLY
        // API MOST CALLERS USE. A terminus is now reported AS a terminus (it is the more specific, and the more
        // actionable, of the two answers), while a plain rejection still falls through to `.rejected`.
        var sawExpired = false
        for admission in hostIncarnations(peerId) {
            let outcome = openWithResult(admission, ciphertext)
            if case .authenticated = outcome { return outcome }
            if case .expired = outcome { sawExpired = true }
        }
        return sawExpired ? .expired : .rejected
    }

    internal func authenticatedNodeIdOf(_ peerId: UUID) -> Data? {
        for admission in hostIncarnations(peerId) {
            if let nodeId = authenticatedNodeIdOf(admission) { return nodeId }
        }
        return nil
    }

    internal func authenticatedIdentityPubOf(_ peerId: UUID) -> Data? {
        for admission in hostIncarnations(peerId) {
            if let pub = authenticatedIdentityPubOf(admission) { return pub }
        }
        return nil
    }

    /// The host courts' teardown: EVERY incarnation of that handle, as the app-level
    /// departure doth -- the handle-scoped reading of the handle-scoped vocabulary. A court
    /// which needeth to name ONE incarnation speaketh the keyed surface and getteth the
    /// typed answer.
    internal func drop(_ peerId: UUID) {
        retireIncarnations(ofPeerId: peerId)
    }

    public func destroyAll() {
        lifecycleRwLock.withWriteLock {
            mapLock.lock()
            defer { mapLock.unlock() }
            for slot in controllers.values {
                slot.retire()?.destroy()
            }
            controllers.removeAll()
        }
    }

    public func invalidateForWipe() {
        testInvalidationAttemptHook?()
        lifecycleRwLock.withWriteLock {
            mapLock.lock()
            defer { mapLock.unlock() }
            managerState = .invalidated
            for slot in controllers.values {
                slot.state = .invalidated
                slot.controller?.destroy()
                slot.controller = nil
            }
            controllers.removeAll()
        }
    }
}
