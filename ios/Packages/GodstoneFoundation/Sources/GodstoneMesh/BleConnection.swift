import Foundation

/// Authoritative connection state and lifecycle for a persistent BLE link (ADR-002, Phase C8.4D1-A1/R2).
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
    public var isHandshakeTransportReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        let bound = (state == .roleBound || state == .handshakeInProgress)
        guard bound else { return false }
        return isNotificationSubscribed && maxAttValueLength >= 20
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

    public func transitionTo(_ newState: BleConnectionState) {
        lock.lock()
        defer { lock.unlock() }
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

        _remoteNodeHint = hint
        _localRole = role
        state = .roleBound
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
    }

    /// Fragment an outbound record into ordered BLE record fragments using connection-local sequence state.
    public func fragmentOutbound(recordType: BleRecordType, payload: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        guard state != .closed && state != .closing && state != .quarantined else { return [] }
        // DATA records strictly forbidden before cryptographic ready
        if recordType == .data && state != .ready {
            return []
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
    public func ingestInboundAttValue(_ data: Data) -> BleReassembledRecord? {
        lock.lock()
        defer { lock.unlock() }
        guard state != .closed && state != .closing && state != .quarantined else { return nil }
        guard let frag = BleRecordCodec.decodeFragment(data) else { return nil }
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
