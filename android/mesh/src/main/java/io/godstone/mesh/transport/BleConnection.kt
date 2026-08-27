package io.godstone.mesh.transport

import java.util.concurrent.atomic.AtomicBoolean

/**
 * Connection state and lifecycle for a persistent BLE link (ADR-002, Phase C8.4D1-A1).
 */
enum class BleConnectionState {
    DISCOVERED,
    PROVISIONAL_CONNECTING,
    PROVISIONAL_CONNECTED,
    LINK_INFO_READING,
    LINK_INFO_WRITING,
    ROLE_BOUND,
    HANDSHAKE_IN_PROGRESS,
    READY,
    QUARANTINED,
    CLOSING,
    CLOSED,

    // Backward-compatible lifecycle states
    CONNECTING,
    CONNECTED,
    DISCONNECTING,
    DISCONNECTED
}

/**
 * Persistent duplex connection abstraction representing an active or in-flight BLE link.
 *
 * Encapsulates:
 * - Transport peer identifier (MAC address bytes on Android)
 * - Actual observed remote node_hint (from discovery payload)
 * - Elected local role (INITIATOR vs RESPONDER)
 * - Negotiated safe ATT value capacity (maxAttValueLength)
 * - Connection-local BleRecord reassembler and sequence counter
 */
class BleConnection(
    val peerId: ByteArray,
    val remoteNodeHint: ByteArray,
    val localRole: BleRole,
    initialMaxAttValueLength: Int = DEFAULT_MAX_ATT_VALUE_LENGTH,
    private val clock: () -> Long = { System.currentTimeMillis() / 1000L }
) {
    var maxAttValueLength: Int = initialMaxAttValueLength
        set(value) {
            require(value >= BleRecordConstants.HEADER_BYTES + 1) {
                "maxAttValueLength $value must be >= ${BleRecordConstants.HEADER_BYTES + 1}"
            }
            field = value
        }

    private val _state = java.util.concurrent.atomic.AtomicReference(BleConnectionState.CONNECTING)
    val state: BleConnectionState get() = _state.get()

    val isActive: Boolean get() = state == BleConnectionState.CONNECTED || state == BleConnectionState.CONNECTING

    private val reassembler = BleRecordReassembler(clock)
    private var nextOutboundSeq: Int = 0
    private val lock = Any()

    init {
        require(peerId.isNotEmpty()) { "peerId must not be empty" }
        require(remoteNodeHint.size == BleRoleElection.NODE_HINT_BYTES) {
            "remoteNodeHint must be exactly ${BleRoleElection.NODE_HINT_BYTES} bytes"
        }
    }

    fun markConnected(negotiatedAttValueLength: Int? = null) {
        if (negotiatedAttValueLength != null) {
            maxAttValueLength = negotiatedAttValueLength
        }
        _state.set(BleConnectionState.CONNECTED)
    }

    fun markDisconnected() {
        _state.set(BleConnectionState.DISCONNECTED)
        reset()
    }

    /**
     * Fragment an outbound record into ordered BLE record fragments using connection-local sequence state.
     */
    fun fragmentOutbound(recordType: BleRecordType, payload: ByteArray): List<ByteArray> = synchronized(lock) {
        if (!isActive) return emptyList()
        val seq = nextOutboundSeq
        nextOutboundSeq = (nextOutboundSeq + 1) and 0xFF
        return BleRecordFragmenter.fragment(recordType, seq, payload, maxAttValueLength)
    }

    /**
     * Ingest an inbound ATT value, decode it as a canonical BleRecord fragment, and reassemble.
     */
    fun ingestInboundAttValue(bytes: ByteArray): BleReassembledRecord? = synchronized(lock) {
        if (!isActive) return null
        val frag = BleRecordCodec.decodeFragment(bytes) ?: return null
        return reassembler.receiveFragment(frag)
    }

    /**
     * Reset connection-local record state (purge in-flight and completed record state, reset sequence counter).
     */
    fun reset() = synchronized(lock) {
        reassembler.reset()
        nextOutboundSeq = 0
    }

    companion object {
        const val DEFAULT_MAX_ATT_VALUE_LENGTH = 20 // Default legacy ATT MTU 23 - 3 bytes opcode/handle
    }
}
