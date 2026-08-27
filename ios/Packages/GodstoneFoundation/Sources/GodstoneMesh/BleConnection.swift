import Foundation

/// Connection state for a persistent BLE link (ADR-002, Phase C8.4D1).
public enum BleConnectionState: Sendable, Equatable {
    case connecting
    case connected
    case disconnecting
    case disconnected
}

/// Persistent duplex connection abstraction representing an active or in-flight BLE link on iOS.
public final class BleConnection: @unchecked Sendable {

    public let peerId: UUID
    public let remoteNodeHint: Data
    public let localRole: BleRole

    public var maxAttValueLength: Int {
        didSet {
            precondition(
                maxAttValueLength >= BleRecordConstants.headerBytes + 1,
                "maxAttValueLength \(maxAttValueLength) must be >= \(BleRecordConstants.headerBytes + 1)"
            )
        }
    }

    public private(set) var state: BleConnectionState = .connecting
    public var isActive: Bool { state == .connected || state == .connecting }

    private let reassembler: BleRecordReassembler
    private var nextOutboundSeq: UInt8 = 0
    private let lock = NSLock()

    public init(
        peerId: UUID,
        remoteNodeHint: Data,
        localRole: BleRole,
        initialMaxAttValueLength: Int = 20,
        timeProvider: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        precondition(remoteNodeHint.count == BleRoleElection.nodeHintBytes, "remoteNodeHint must be 4 bytes")
        self.peerId = peerId
        self.remoteNodeHint = remoteNodeHint
        self.localRole = localRole
        self.maxAttValueLength = initialMaxAttValueLength
        self.reassembler = BleRecordReassembler(timeProvider: timeProvider)
    }

    public func markConnected(negotiatedAttValueLength: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let len = negotiatedAttValueLength {
            maxAttValueLength = len
        }
        state = .connected
    }

    public func markDisconnected() {
        lock.lock()
        defer { lock.unlock() }
        state = .disconnected
        resetLocked()
    }

    /// Fragment an outbound record into ordered BLE record fragments using connection-local sequence state.
    public func fragmentOutbound(recordType: BleRecordType, payload: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { return [] }

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
        guard isActive else { return nil }
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
    }
}
