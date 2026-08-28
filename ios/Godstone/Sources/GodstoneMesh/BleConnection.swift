import Foundation

/// Authoritative connection state and lifecycle for a persistent BLE link (ADR-002, Phase C8.4D1-A1/R2/R2.1).
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

    /// Validates and executes state transitions. Direct transitions to ready or backwards transitions are rejected.
    public func transitionTo(_ newState: BleConnectionState) {
        lock.lock()
        defer { lock.unlock() }
        if state == newState { return }

        let valid: Bool
        switch state {
        case .discovered:
            valid = (newState == .provisionalConnecting || newState == .closing || newState == .closed)
        case .provisionalConnecting:
            valid = (newState == .provisionalConnected || newState == .closing || newState == .closed)
        case .provisionalConnected:
            valid = (newState == .linkInfoReading || newState == .roleBound || newState == .closing || newState == .closed)
        case .linkInfoReading:
            valid = (newState == .linkInfoWriting || newState == .closing || newState == .closed)
        case .linkInfoWriting:
            valid = (newState == .roleBound || newState == .closing || newState == .closed)
        case .roleBound:
            valid = (newState == .handshakeInProgress || newState == .quarantined || newState == .closing || newState == .closed)
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

        guard newState != .ready else {
            // Cryptographic ready transition reserved for C8.4D2 trusted handshake
            return
        }
        precondition(valid, "Illegal state transition from \(state) to \(newState)")
        state = newState
    }

    /// One-way binding of remote node hint and elected role.
    /// Succeeds at most once from a valid pre-role-bound state.
    public func bindRole(hint: Data, role: BleRole) {
        lock.lock()
        defer { lock.unlock() }
        precondition(hint.count == BleRoleElection.nodeHintBytes, "remoteNodeHint must be 4 bytes")
        precondition(_remoteNodeHint == nil && _localRole == nil, "Cannot rebind role on BleConnection")
        precondition(state != .closed && state != .closing && state != .quarantined, "Cannot bind role on inactive connection")
        precondition(state == .linkInfoWriting || state == .provisionalConnected, "Cannot bind role from state \(state)")

        _remoteNodeHint = hint
        _localRole = role
        state = .roleBound
    }

    public func bindInitiatorAfterLinkInfoWriteAck(remoteHint: Data) {
        lock.lock()
        let s = state
        lock.unlock()
        precondition(s == .linkInfoWriting, "Cannot bind initiator from state \(s): must be in linkInfoWriting")
        bindRole(hint: remoteHint, role: .initiator)
    }

    public func bindResponderFromAcceptedIncomingLinkInfo(remoteHint: Data) {
        lock.lock()
        let s = state
        lock.unlock()
        precondition(s == .provisionalConnected, "Cannot bind responder from state \(s): must be in provisionalConnected")
        bindRole(hint: remoteHint, role: .responder)
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
    public func ingestInboundAttValue(_ data: Data) -> BleReassembledRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard state != .closed && state != .closing && state != .quarantined else { return nil }
        guard let frag = BleRecordCodec.decodeFragment(data) else { return nil }

        switch frag.header.recordType {
        case .data:
            if state != .ready { return nil }
        case .hs1, .hs2, .hs3:
            if !isHandshakeTransportReadyLocked || (state != .roleBound && state != .handshakeInProgress) {
                return nil
            }
        case .close:
            break
        }

        return reassembler.receiveFragment(frag)
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

