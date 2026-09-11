import Foundation

/// Authoritative connection state and lifecycle for a persistent BLE link (ADR-002, Phase C8.4D1-A1/R2/R2.1).
/// T17: the typed reason of one rejected inbound record at the connection's
/// input queue. A malformed fragment, an inactive connection and a record
/// seen at a stage that does not accept its type are three distinct
/// failures; the old code answered all of them - and a mere incomplete
/// reassembly - with one and the same nothing.
public enum BleRecordRejection: Equatable, Sendable {
    case inactive
    case malformedRecord
    case unexpectedStage(expected: [BleConnectionState], observed: BleConnectionState, recordType: BleRecordType)
}

/// T17: the typed result of ingesting one inbound ATT value. The three
/// outcomes a queue admits - a complete record, an incomplete one still
/// in flight, and a rejection with its reason - are returned apart.
public enum BleIngestResult: Sendable {
    case admitted(BleReassembledRecord)
    case pending
    case rejected(BleRecordRejection)

    public var admittedRecord: BleReassembledRecord? {
        if case .admitted(let record) = self { return record }
        return nil
    }

    public var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }

    public var isPending: Bool {
        if case .pending = self { return true }
        return false
    }
}

public enum BleConnectionState: Sendable, Equatable {
    case discovered
    case provisionalConnecting
    case provisionalConnected
    case linkInfoReading
    case linkInfoWriting
    case roleBound
    case handshakeInProgress
    case ready
    case quarantined
    case closing
    case closed
}

/// Persistent duplex connection abstraction representing an active or in-flight BLE link on iOS.
///
/// A provisional connection is constructible without remote node_hint or elected role.
/// Role and remote node_hint are bound one-way via `bindRole` during LinkInfo exchange.
public final class BleConnection: @unchecked Sendable {

    public let peerId: UUID

    public var maxAttValueLength: Int {
        didSet {
            precondition(
                maxAttValueLength >= BleRecordConstants.headerBytes + 1,
                "maxAttValueLength \(maxAttValueLength) must be >= \(BleRecordConstants.headerBytes + 1)"
            )
        }
    }

    public private(set) var state: BleConnectionState = .provisionalConnecting
    private var _remoteNodeHint: Data?
    private var _localRole: BleRole?

    public var remoteNodeHint: Data? {
        lock.lock()
        defer { lock.unlock() }
        return _remoteNodeHint
    }

    public var localRole: BleRole? {
        lock.lock()
        defer { lock.unlock() }
        return _localRole
    }

    public var isRoleBound: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _remoteNodeHint != nil && _localRole != nil
    }

    public var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state != .closed && state != .closing && state != .quarantined
    }

    public var isNotificationSubscribed: Bool = false

    /// Predicate defining physical duplex readiness for subsequent handshake records (ADR-002 §6).
    /// Distinct from cryptographic `BleConnectionState.ready`.
    private var isHandshakeTransportReadyLocked: Bool {
        let bound = (state == .roleBound || state == .handshakeInProgress)
        guard bound else { return false }
        return _remoteNodeHint != nil && _localRole != nil && isNotificationSubscribed && maxAttValueLength >= 20
    }

    public var isHandshakeTransportReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isHandshakeTransportReadyLocked
    }

    private let reassembler: BleRecordReassembler

    /// T20: the relation this connection's ingress belongs to, as the owner
    /// binds it from the registration it currently holds. A bare connection
    /// keeps the documented unclaimed placeholder, whose leases govern no
    /// live relation and raise no fall.
    internal var relationKeyProvider: (() -> RelationKey)?

    // T23: the shadow projections of the handshake law, each a servant of this
    // relation alone. They mutate no authoritative state.
    internal let transcript = TranscriptCache()
    internal let handshakeDeadline: HandshakeDeadline
    internal let keyConfirmation: KeyConfirmation
    internal private(set) var handshakeStage: HandshakeStage = .idle
    internal private(set) var handshakeEngaged: Bool = false

    private let noticeLock = NSLock()
    private var leaseExpiryNotice: AssemblyLease?

    internal func noteLeaseExpiry(_ lease: AssemblyLease) {
        noticeLock.lock()
        defer { noticeLock.unlock() }
        if leaseExpiryNotice == nil { leaseExpiryNotice = lease }
    }

    /// The owner asks once per ingress what lapsed; the notice is consumed.
    internal func takeLeaseExpiryNotice() -> AssemblyLease? {
        noticeLock.lock()
        defer { noticeLock.unlock() }
        let notice = leaseExpiryNotice
        leaseExpiryNotice = nil
        return notice
    }

    /// Observation only: the standing notice, for the suites' sight.
    internal func peekLeaseExpiryNotice() -> AssemblyLease? {
        noticeLock.lock()
        defer { noticeLock.unlock() }
        return leaseExpiryNotice
    }

    /// T20: the heartbeat's question - sweep at the clock's instant and
    /// report whether a lease lapsed. The notice is consumed here; the
    /// owner who hears it performs the fall.
    internal func sweepLeases() -> Bool {
        reassembler.sweepAtNow()
        return takeLeaseExpiryNotice() != nil
    }

    internal func activeLeaseOf(_ seq: UInt8) -> AssemblyLease? { reassembler.activeLeaseOf(seq) }
    internal func leaseCount() -> Int { reassembler.leaseCount() }
    /// T23: the in-flight witness of the assemblers lease, in the name the
    /// Android twin weareth. The owners hand consulteth it before it letteth a
    /// stalled exchange fall, that a counsel afoot be never pre-empted by the
    /// hour-glass, which is not its to govern.
    internal func leaseCountForTest() -> Int { reassembler.leaseCount() }
    internal func sweepLeasesAt(_ now: TimeInterval) { reassembler.sweepExpiredAt(now) }
    private var nextOutboundSeq: UInt8 = 0
    private let lock = NSLock()

    /// T23: the relations monotonic clock, in uptime millis. The owner (the
    /// transport) bindeth it from the very instance it was itself given, so a
    /// rig which advancech that clock lapseth the hour-glass and the
    /// confirming hour; a bare connection keepeth the system clock.
    private let relationClock: MonotonicClock

    public init(
        peerId: UUID,
        initialMaxAttValueLength: Int = 20,
        timeProvider: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 },
        clock: MonotonicClock? = nil
    ) {
        self.peerId = peerId
        self.maxAttValueLength = initialMaxAttValueLength
        self.reassembler = BleRecordReassembler(timeProvider: timeProvider)
        // T23: the two hour-keepers are turn'd upon the relations monotonic
        // clock - the uptime-MILLIS domain, where the handshake hour is
        // 10_000 and the confirming hour 30_000.
        let hour = clock ?? SystemMonotonicClock()
        self.relationClock = hour
        self.handshakeDeadline = HandshakeDeadline(now: { hour.nowUptimeMillis() })
        self.keyConfirmation = KeyConfirmation(now: { hour.nowUptimeMillis() })
        // T20: the owner's seats are bound once the connection stands whole
        // - weak on the connection, so the reassembler never keeps its own
        // alive; the binding order is law: the last to be bound is the
        // reassembler's counsel for every later admission.
        reassembler.onLeaseExpiry = { [weak self] lease in self?.noteLeaseExpiry(lease) }
        reassembler.relationKeyOf = { [weak self] in
            (self?.relationKeyProvider ?? { LifetimeControl.unclaimedRelation })()
        }
    }

    /// The present instant of the relations clock, for the instruments and
    /// for the courts inspection of the hour.
    internal func nowUptimeMillis() -> UInt64 { relationClock.nowUptimeMillis() }

    /// Validates and executes state transitions. Direct transitions to roleBound, handshakeInProgress, or ready are rejected.
    @discardableResult
    public func transitionTo(_ newState: BleConnectionState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if state == newState { return true }

        // T17: the reserved entrances reject outright - roleBound is reached
        // only through the bind family, handshakeInProgress only through
        // beginHandshake, ready only through markTrustedReady. A rejected
        // transition preserves the state and answers false: no platform
        // callback aborts over a malformed record any more.
        if newState == .roleBound || newState == .handshakeInProgress || newState == .ready {
            return false
        }

        let valid: Bool
        switch state {
        case .discovered:
            valid = (newState == .provisionalConnecting || newState == .closing || newState == .closed)
        case .provisionalConnecting:
            valid = (newState == .provisionalConnected || newState == .closing || newState == .closed)
        case .provisionalConnected:
            valid = (newState == .linkInfoReading || newState == .closing || newState == .closed)
        case .linkInfoReading:
            valid = (newState == .linkInfoWriting || newState == .closing || newState == .closed)
        case .linkInfoWriting:
            valid = (newState == .closing || newState == .closed)
        case .roleBound:
            valid = (newState == .quarantined || newState == .closing || newState == .closed)
        case .handshakeInProgress:
            valid = (newState == .quarantined || newState == .closing || newState == .closed)
        case .ready:
            valid = (newState == .quarantined || newState == .closing || newState == .closed)
        case .quarantined:
            valid = (newState == .closing || newState == .closed)
        case .closing:
            valid = (newState == .closed)
        case .closed:
            valid = false
        }

        guard valid else { return false }
        state = newState
        return true
    }

    /// T17: advances a role-bound connection whose physical duplex is ready
    /// into the handshake phase. False when either guard fails; the state
    /// is preserved.
    @discardableResult
    internal func beginHandshake() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .roleBound, isHandshakeTransportReadyLocked else { return false }
        state = .handshakeInProgress
        handshakeStage = .hsIn
        return true
    }

    /// T17: the only production entrance to cryptographic ready: the caller
    /// - the transport's trusted handshake driver - has proved the peer's
    /// slot ready in the session registry. A synthetic ready created by
    /// the test seam never opens this gate.
    @discardableResult
    internal func markTrustedReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .handshakeInProgress else { return false }
        state = .ready
        handshakeDeadline.stop()
        handshakeStage = .trustedCryptoReady
        return true
    }

    /// Nonshipping test seam: advances the physical state for plumbing
    /// exercises. It cannot open the trusted path - sends over it answer
    /// rejected until a session slot proves ready through the handshake.
    @discardableResult
    internal func markReadyForTesting() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state != .closed && state != .closing else { return false }
        state = .ready
        handshakeDeadline.stop()
        handshakeStage = .trustedCryptoReady
        return true
    }

    // MARK: - T23 the doors servants (called by the transport, never under the lock)
    internal func markHandshakeEngaged() {
        lock.lock(); defer { lock.unlock() }
        handshakeEngaged = true
    }
    internal func advanceStage(to stage: HandshakeStage) {
        lock.lock(); defer { lock.unlock() }
        if stage.rawValue > handshakeStage.rawValue { handshakeStage = stage }
    }
    internal func handshakeDeadlineExpired() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .roleBound || state == .handshakeInProgress else { return false }
        return handshakeDeadline.expired()
    }
    var isKeyConfirmed: Bool { keyConfirmation.isConfirmed }
    @discardableResult
    internal func markKeyConfirmed() -> Bool {
        guard keyConfirmation.isConfirmed else { return false }
        advanceStage(to: .keyConfirmed)
        return true
    }
    internal func armHandshakeDeadline() { handshakeDeadline.arm() }
    internal func stopHandshakeDeadline() { handshakeDeadline.stop() }

    /// One-way binding of remote node hint and elected role.
    /// Accessible only through authoritative bind methods.
    /// T17: the pure predicate of the bind family - a caller that must not
    /// corrupt authoritative state validates the hint with it before
    /// attempting the bind.
    public static func canBindRemoteHint(_ hint: Data) -> Bool {
        return hint.count == BleRoleElection.nodeHintBytes
    }

    private func bindRoleInternal(hint: Data, role: BleRole) -> Bool {
        guard hint.count == BleRoleElection.nodeHintBytes else { return false }
        guard _remoteNodeHint == nil && _localRole == nil else { return false }
        guard state != .closed && state != .closing && state != .quarantined else { return false }
        guard state == .linkInfoWriting || state == .provisionalConnected else { return false }

        _remoteNodeHint = hint
        _localRole = role
        state = .roleBound
        handshakeDeadline.arm()
        handshakeStage = .roleBound
        return true
    }

    @discardableResult
    public func bindInitiatorAfterLinkInfoWriteAck(remoteHint: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .linkInfoWriting else { return false }
        return bindRoleInternal(hint: remoteHint, role: .initiator)
    }

    @discardableResult
    public func bindResponderFromAcceptedIncomingLinkInfo(remoteHint: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .provisionalConnected else { return false }
        return bindRoleInternal(hint: remoteHint, role: .responder)
    }

    public func startLinkInfoRead() {
        transitionTo(.linkInfoReading)
    }

    public func startLinkInfoWrite() {
        transitionTo(.linkInfoWriting)
    }

    public func markConnected(negotiatedAttValueLength: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let len = negotiatedAttValueLength {
            maxAttValueLength = len
        }
        if state == .provisionalConnecting || state == .discovered {
            state = .provisionalConnected
        }
    }

    public func markDisconnected() {
        lock.lock()
        defer { lock.unlock() }
        state = .closed
        resetLocked()
        _remoteNodeHint = nil
        _localRole = nil
    }

    /// Fragment an outbound record into ordered BLE record fragments using connection-local sequence state.
    /// Enforces phase-specific record type restrictions. The capacity is the
    /// direction's own maximum when given (T19: the write leg and the update
    /// leg may report different maxima); when omitted the connection fragments
    /// at its negotiated attribute space, as before.
    public func fragmentOutbound(recordType: BleRecordType, payload: Data,
                                 capacity: Int? = nil) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        guard state != .closed && state != .closing && state != .quarantined else { return [] }
        guard mayCarryLocked(recordType) else { return [] }

        let seq = nextOutboundSeq
        nextOutboundSeq = UInt8((Int(nextOutboundSeq) + 1) & 0xFF)

        return (try? BleRecordFragmenter.fragment(
            recordType: recordType,
            recordSeq: seq,
            payload: payload,
            maxAttValueLength: capacity ?? maxAttValueLength
        )) ?? []
    }

    /// T19: the phase gate of the fragmenter, factored out; the whole-record
    /// writer consults it before taking a sequence number, so a record that
    /// the station may not carry is refused with nothing consumed.
    private func mayCarryLocked(_ recordType: BleRecordType) -> Bool {
        switch recordType {
        case .data:
            return state == .ready
        case .hs1, .hs2, .hs3:
            return isHandshakeTransportReadyLocked &&
                (state == .roleBound || state == .handshakeInProgress)
        case .close:
            return true
        }
    }

    /// T19: the single consumption point of the outbound sequence number for
    /// the whole-record writer. The phase gate is consulted under the same
    /// lock as the take, so the number is consumed exactly once per record
    /// the station may carry - and never at all for a record it may not.
    public func takeOutboundSequenceIfReady(_ recordType: BleRecordType) -> UInt8? {
        lock.lock()
        defer { lock.unlock() }
        guard state != .closed && state != .closing && state != .quarantined else { return nil }
        guard mayCarryLocked(recordType) else { return nil }
        let seq = nextOutboundSeq
        nextOutboundSeq = UInt8((Int(nextOutboundSeq) + 1) & 0xFF)
        return seq
    }

    /// The witness: the number the next take would hand, without consuming.
    public func peekOutboundSequence() -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        return nextOutboundSeq
    }

    /// Ingest an inbound ATT value, decode it as a canonical BleRecord fragment, and reassemble.
    /// Gating is strictly enforced BEFORE fragment is passed to the reassembler.
    public func ingestInboundAttValue(_ data: Data) -> BleIngestResult {
        lock.lock()
        defer { lock.unlock() }
        guard state != .closed && state != .closing && state != .quarantined else {
            return .rejected(.inactive)
        }
        guard let frag = BleRecordCodec.decodeFragment(data) else {
            return .rejected(.malformedRecord)
        }

        switch frag.header.recordType {
        case .data:
            if state != .ready {
                return .rejected(.unexpectedStage(expected: [.ready], observed: state,
                                                recordType: frag.header.recordType))
            }
        case .hs1, .hs2, .hs3:
            if !isHandshakeTransportReadyLocked || (state != .roleBound && state != .handshakeInProgress) {
                return .rejected(.unexpectedStage(expected: [.roleBound, .handshakeInProgress],
                                                observed: state, recordType: frag.header.recordType))
            }
        case .close:
            break
        }

        guard let record = reassembler.receiveFragment(frag) else {
            return .pending
        }
        return .admitted(record)
    }

    /// Reset connection-local record state (purge in-flight and completed record state, reset sequence counter).
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        resetLocked()
    }

    private func resetLocked() {
        reassembler.reset()
        nextOutboundSeq = 0
        isNotificationSubscribed = false
        transcript.forgetAll()
        keyConfirmation.clear()
        handshakeDeadline.reset()
        handshakeEngaged = false
    }
}

