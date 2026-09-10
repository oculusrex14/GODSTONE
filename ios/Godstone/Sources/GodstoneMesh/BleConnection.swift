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
    private var nextOutboundSeq: UInt8 = 0
    private let lock = NSLock()

    public init(
        peerId: UUID,
        initialMaxAttValueLength: Int = 20,
        timeProvider: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.peerId = peerId
        self.maxAttValueLength = initialMaxAttValueLength
        self.reassembler = BleRecordReassembler(timeProvider: timeProvider)
    }

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
        return true
    }

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
    /// Enforces phase-specific record type restrictions.
    public func fragmentOutbound(recordType: BleRecordType, payload: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        guard state != .closed && state != .closing && state != .quarantined else { return [] }

        switch recordType {
        case .data:
            if state != .ready { return [] }
        case .hs1, .hs2, .hs3:
            if !isHandshakeTransportReadyLocked || (state != .roleBound && state != .handshakeInProgress) {
                return []
            }
        case .close:
            break
        }

        let seq = nextOutboundSeq
        nextOutboundSeq = UInt8((Int(nextOutboundSeq) + 1) & 0xFF)

        return (try? BleRecordFragmenter.fragment(
            recordType: recordType,
            recordSeq: seq,
            payload: payload,
            maxAttValueLength: maxAttValueLength
        )) ?? []
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
    }
}

