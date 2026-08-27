package io.godstone.mesh.transport

/**
 * Pure, testable role-binding coordinator for Connect-First / Elect-Before-Handshake BLE links (ADR-002, Phase C8.4D1-R2).
 *
 * Owns no platform Bluetooth state, no coroutines, no SessionManager, and no cryptographic keys.
 * Encapsulates the deterministic role election and LinkInfo exchange decisions.
 */
sealed interface BleRoleBindingEvent {
    data class Discovered(val peerAddress: String) : BleRoleBindingEvent
    data class ProvisionalConnected(val peerAddress: String) : BleRoleBindingEvent
    data class RemoteLinkInfoRead(val peerAddress: String, val linkInfo: BleLinkInfoV1) : BleRoleBindingEvent
    data class RemoteLinkInfoReadRaw(val peerAddress: String, val bytes: ByteArray) : BleRoleBindingEvent
    data class LocalLinkInfoWriteAcknowledged(val peerAddress: String, val remoteHint: ByteArray) : BleRoleBindingEvent
    data class IncomingCentralLinkInfoWrite(val peerAddress: String, val bytes: ByteArray) : BleRoleBindingEvent
    data class Disconnected(val peerAddress: String) : BleRoleBindingEvent
    data class Failed(val peerAddress: String, val reason: String) : BleRoleBindingEvent
}

sealed interface BleRoleBindingAction {
    data class ConnectProvisionally(val peerAddress: String) : BleRoleBindingAction
    data class ReadRemoteLinkInfo(val peerAddress: String) : BleRoleBindingAction
    data class WriteLocalLinkInfo(val peerAddress: String, val remoteHint: ByteArray) : BleRoleBindingAction
    data class RoleBound(val peerAddress: String, val role: BleRole, val remoteHint: ByteArray) : BleRoleBindingAction
    data class CancelWrongDirectionLink(val peerAddress: String, val reason: String) : BleRoleBindingAction
    data class RejectIncomingWrite(val peerAddress: String, val reason: String) : BleRoleBindingAction
    data class AcceptIncomingWrite(val peerAddress: String, val remoteHint: ByteArray) : BleRoleBindingAction
    data class Reset(val peerAddress: String) : BleRoleBindingAction
}

class BleRoleBindingCoordinator(
    val localHint: ByteArray
) {
    init {
        require(localHint.size == BleRoleElection.NODE_HINT_BYTES) {
            "localHint must be exactly ${BleRoleElection.NODE_HINT_BYTES} bytes, got ${localHint.size}"
        }
    }

    /**
     * Process an event on an outgoing Central connection path.
     */
    fun processCentralEvent(event: BleRoleBindingEvent): BleRoleBindingAction {
        return when (event) {
            is BleRoleBindingEvent.Discovered -> {
                BleRoleBindingAction.ConnectProvisionally(event.peerAddress)
            }
            is BleRoleBindingEvent.ProvisionalConnected -> {
                BleRoleBindingAction.ReadRemoteLinkInfo(event.peerAddress)
            }
            is BleRoleBindingEvent.RemoteLinkInfoReadRaw -> {
                val linkInfo = BleLinkInfoCodec.decode(event.bytes)
                if (linkInfo == null) {
                    BleRoleBindingAction.CancelWrongDirectionLink(event.peerAddress, "Malformed remote LinkInfo payload")
                } else {
                    evaluateCentralElection(event.peerAddress, linkInfo)
                }
            }
            is BleRoleBindingEvent.RemoteLinkInfoRead -> {
                evaluateCentralElection(event.peerAddress, event.linkInfo)
            }
            is BleRoleBindingEvent.LocalLinkInfoWriteAcknowledged -> {
                BleRoleBindingAction.RoleBound(event.peerAddress, BleRole.INITIATOR, event.remoteHint)
            }
            is BleRoleBindingEvent.Disconnected, is BleRoleBindingEvent.Failed -> {
                val addr = when (event) {
                    is BleRoleBindingEvent.Disconnected -> event.peerAddress
                    is BleRoleBindingEvent.Failed -> event.peerAddress
                    else -> ""
                }
                BleRoleBindingAction.Reset(addr)
            }
            is BleRoleBindingEvent.IncomingCentralLinkInfoWrite -> {
                processPeripheralLinkInfoWrite(event.peerAddress, event.bytes)
            }
        }
    }

    private fun evaluateCentralElection(peerAddress: String, remoteLinkInfo: BleLinkInfoV1): BleRoleBindingAction {
        val election = BleRoleElection.elect(localHint, remoteLinkInfo.nodeHint)
        return when (election) {
            is BleRoleElectionResult.Elected -> {
                if (election.role == BleRole.INITIATOR) {
                    // local < remote: we are the initiator -> write local LinkInfo with response
                    BleRoleBindingAction.WriteLocalLinkInfo(peerAddress, remoteLinkInfo.nodeHint)
                } else {
                    // local > remote: we are the responder -> wrong direction, cancel central link immediately
                    BleRoleBindingAction.CancelWrongDirectionLink(
                        peerAddress,
                        "Elected RESPONDER on central link; cancelling wrong-direction connection"
                    )
                }
            }
            BleRoleElectionResult.Tie -> {
                BleRoleBindingAction.CancelWrongDirectionLink(peerAddress, "Equal node hints (tie detected); fail closed")
            }
            is BleRoleElectionResult.Invalid -> {
                BleRoleBindingAction.CancelWrongDirectionLink(peerAddress, "Invalid election: ${election.reason}")
            }
        }
    }

    /**
     * Process an incoming LinkInfo write on the Peripheral GATT server.
     */
    fun processPeripheralLinkInfoWrite(peerAddress: String, rawBytes: ByteArray): BleRoleBindingAction {
        val linkInfo = BleLinkInfoCodec.decode(rawBytes)
            ?: return BleRoleBindingAction.RejectIncomingWrite(peerAddress, "Malformed LinkInfo payload")

        val election = BleRoleElection.elect(localHint, linkInfo.nodeHint)
        return when (election) {
            is BleRoleElectionResult.Elected -> {
                if (election.role == BleRole.RESPONDER) {
                    // remote < local: Central is valid initiator, we are RESPONDER -> accept write and bind role
                    BleRoleBindingAction.AcceptIncomingWrite(peerAddress, linkInfo.nodeHint)
                } else {
                    // remote > local: Central should not initiate -> reject write
                    BleRoleBindingAction.RejectIncomingWrite(peerAddress, "Remote hint >= local hint; rejected")
                }
            }
            BleRoleElectionResult.Tie -> BleRoleBindingAction.RejectIncomingWrite(peerAddress, "Tie detected")
            is BleRoleElectionResult.Invalid -> BleRoleBindingAction.RejectIncomingWrite(peerAddress, election.reason)
        }
    }
}
