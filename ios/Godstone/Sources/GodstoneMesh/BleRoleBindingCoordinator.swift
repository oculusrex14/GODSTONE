import Foundation

/// Events processed by the role-binding coordinator.
public enum BleRoleBindingEvent: Sendable {
    case discovered(UUID)
    case provisionalConnected(UUID)
    case remoteLinkInfoRead(UUID, BleLinkInfoV1)
    case remoteLinkInfoReadRaw(UUID, Data)
    case localLinkInfoWriteAcknowledged(UUID, Data)
    case incomingCentralLinkInfoWrite(UUID, Data)
    case disconnected(UUID)
    case failed(UUID, String)
}

/// Actions produced by the pure role-binding coordinator.
public enum BleRoleBindingAction: Equatable, Sendable {
    case connectProvisionally(UUID)
    case readRemoteLinkInfo(UUID)
    case writeLocalLinkInfo(UUID, remoteHint: Data)
    case roleBound(UUID, role: BleRole, remoteHint: Data)
    case cancelWrongDirectionLink(UUID, reason: String)
    case rejectIncomingWrite(UUID, reason: String)
    case acceptIncomingWrite(UUID, remoteHint: Data)
    case reset(UUID)
}

/// Pure, testable role-binding coordinator for Connect-First / Elect-Before-Handshake BLE links on iOS (ADR-002, Phase C8.4D1-R2).
public final class BleRoleBindingCoordinator: Sendable {

    public let localHint: Data

    public init(localHint: Data) {
        precondition(localHint.count == BleRoleElection.nodeHintBytes, "localHint must be exactly 4 bytes")
        self.localHint = localHint
    }

    /// Process an event on an outgoing Central connection path.
    public func processCentralEvent(_ event: BleRoleBindingEvent) -> BleRoleBindingAction {
        switch event {
        case .discovered(let peerId):
            return .connectProvisionally(peerId)
        case .provisionalConnected(let peerId):
            return .readRemoteLinkInfo(peerId)
        case .remoteLinkInfoReadRaw(let peerId, let data):
            guard let linkInfo = BleLinkInfoCodec.decode(data) else {
                return .cancelWrongDirectionLink(peerId, reason: "Malformed remote LinkInfo payload")
            }
            return evaluateCentralElection(peerId: peerId, remoteLinkInfo: linkInfo)
        case .remoteLinkInfoRead(let peerId, let linkInfo):
            return evaluateCentralElection(peerId: peerId, remoteLinkInfo: linkInfo)
        case .localLinkInfoWriteAcknowledged(let peerId, let remoteHint):
            return .roleBound(peerId, role: .initiator, remoteHint: remoteHint)
        case .disconnected(let peerId), .failed(let peerId, _):
            return .reset(peerId)
        case .incomingCentralLinkInfoWrite(let peerId, let data):
            return processPeripheralLinkInfoWrite(peerId: peerId, rawBytes: data)
        }
    }

    private func evaluateCentralElection(peerId: UUID, remoteLinkInfo: BleLinkInfoV1) -> BleRoleBindingAction {
        let election = BleRoleElection.elect(localHint: localHint, remoteHint: remoteLinkInfo.nodeHint)
        switch election {
        case .elected(let role):
            if role == .initiator {
                // local < remote: we are initiator -> write local LinkInfo with response
                return .writeLocalLinkInfo(peerId, remoteHint: remoteLinkInfo.nodeHint)
            } else {
                // local > remote: we are responder -> wrong direction, cancel central link
                return .cancelWrongDirectionLink(
                    peerId,
                    reason: "Elected RESPONDER on central link; cancelling wrong-direction connection"
                )
            }
        case .tie:
            return .cancelWrongDirectionLink(peerId, reason: "Equal node hints (tie detected); fail closed")
        case .invalid(let reason):
            return .cancelWrongDirectionLink(peerId, reason: "Invalid election: \(reason)")
        }
    }

    /// Process an incoming LinkInfo write on the Peripheral GATT server.
    public func processPeripheralLinkInfoWrite(peerId: UUID, rawBytes: Data) -> BleRoleBindingAction {
        guard let linkInfo = BleLinkInfoCodec.decode(rawBytes) else {
            return .rejectIncomingWrite(peerId, reason: "Malformed LinkInfo payload")
        }

        let election = BleRoleElection.elect(localHint: localHint, remoteHint: linkInfo.nodeHint)
        switch election {
        case .elected(let role):
            if role == .responder {
                // remote < local: Central is valid initiator, we are RESPONDER -> accept and bind role
                return .acceptIncomingWrite(peerId, remoteHint: linkInfo.nodeHint)
            } else {
                // remote > local: Central should not initiate -> reject write
                return .rejectIncomingWrite(peerId, reason: "Remote hint >= local hint; rejected")
            }
        case .tie:
            return .rejectIncomingWrite(peerId, reason: "Tie detected")
        case .invalid(let reason):
            return .rejectIncomingWrite(peerId, reason: reason)
        }
    }
}
