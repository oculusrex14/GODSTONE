import Foundation

/// Bulk transfer is deliberately unavailable in V4.
///
/// The earlier MultipeerConnectivity implementation was not bound to the BLE
/// Noise session, generated random UUIDs for callbacks, and sent encoded frames
/// without a record-level identity binding. Advertising that as a secure bulk
/// plane would violate C1/C6 and the threat model. ADR-006 defines the decision
/// required before a real implementation can be enabled.
public final class BulkTransport {
    public static let unavailableReason =
        "Bulk transfer is disabled until ADR-006 is implemented and device-tested."

    public private(set) var isActive = false
    public var isAvailable: Bool { false }

    public init(displayName: String) { }
    public func activate() { isActive = false }
    public func deactivate() { isActive = false }

    @discardableResult
    public func send(_ frame: FrameV2) -> Bool { false }
}
