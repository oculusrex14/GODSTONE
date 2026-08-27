package io.godstone.mesh.transport

import java.util.concurrent.atomic.AtomicReference

/**
 * Authoritative connection state and lifecycle for a persistent BLE link (ADR-002, Phase C8.4D1-A1/R2).
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
    CLOSED
}

/**
 * Persistent duplex connection abstraction representing an active or in-flight BLE link.
 *
 * A provisional connection is constructible without remote node_hint or elected role.
 * Role and remote node_hint are bound one-way via [bindRole] during the LinkInfo exchange.
 */
class BleConnection(
    val peerId: ByteArray,
    initialMaxAttValueLength: Int = DEFAULT_MAX_ATT_VALUE_LENGTH,
    private val clock: () -> Long = { System.currentTimeMillis() / 1000L }
) {
    init {
        require(peerId.isNotEmpty()) { "peerId must not be empty" }
    }

    var maxAttValueLength: Int = initialMaxAttValueLength
        set(value) {
            require(value >= BleRecordConstants.HEADER_BYTES + 1) {
                "maxAttValueLength $value must be >= ${BleRecordConstants.HEADER_BYTES + 1}"
            }
            field = value
        }

    private val _state = AtomicReference(BleConnectionState.PROVISIONAL_CONNECTING)
    val state: BleConnectionState get() = _state.get()

    private var _remoteNodeHint: ByteArray? = null
    val remoteNodeHint: ByteArray?
        get() = _remoteNodeHint?.copyOf()

    private var _localRole: BleRole? = null
    val localRole: BleRole?
        get() = _localRole

    val isRoleBound: Boolean
        get() = _localRole != null && _remoteNodeHint != null

    val isActive: Boolean
        get() {
            val s = state
            return s != BleConnectionState.CLOSED && s != BleConnectionState.CLOSING && s != BleConnectionState.QUARANTINED
        }

    @Volatile
    var isNotificationSubscribed: Boolean = false

    /**
     * Predicate defining physical duplex readiness for subsequent handshake records (ADR-002 §6).
     * Distinct from cryptographic [BleConnectionState.READY].
     */
    val isHandshakeTransportReady: Boolean
        get() {
            val s = state
            val bound = s == BleConnectionState.ROLE_BOUND || s == BleConnectionState.HANDSHAKE_IN_PROGRESS
            if (!bound) return false
            return isNotificationSubscribed && maxAttValueLength >= DEFAULT_MAX_ATT_VALUE_LENGTH
        }

    private val reassembler = BleRecordReassembler(clock)
    private var nextOutboundSeq: Int = 0
    private val lock = Any()

    fun transitionTo(newState: BleConnectionState) {
        _state.set(newState)
    }

    /**
     * One-way binding of remote node hint and elected role.
     * Succeeds at most once from a valid pre-role-bound state.
     */
    fun bindRole(hint: ByteArray, role: BleRole) = synchronized(lock) {
        require(hint.size == BleRoleElection.NODE_HINT_BYTES) {
            "remoteNodeHint must be exactly ${BleRoleElection.NODE_HINT_BYTES} bytes, got ${hint.size}"
        }
        check(_remoteNodeHint == null && _localRole == null) {
            "Cannot rebind role: already bound to role $_localRole with hint ${_remoteNodeHint?.joinToString("") { "%02x".format(it) }}"
        }
        val s = state
        check(s != BleConnectionState.CLOSED && s != BleConnectionState.CLOSING && s != BleConnectionState.QUARANTINED) {
            "Cannot bind role on inactive connection in state $s"
        }

        _remoteNodeHint = hint.copyOf()
        _localRole = role
        _state.set(BleConnectionState.ROLE_BOUND)
    }

    fun markConnected(negotiatedAttValueLength: Int? = null) {
        if (negotiatedAttValueLength != null) {
            maxAttValueLength = negotiatedAttValueLength
        }
        val current = _state.get()
        if (current == BleConnectionState.PROVISIONAL_CONNECTING || current == BleConnectionState.DISCOVERED) {
            _state.set(BleConnectionState.PROVISIONAL_CONNECTED)
        }
    }

    fun markDisconnected() = synchronized(lock) {
        _state.set(BleConnectionState.CLOSED)
        resetLocked()
    }

    /**
     * Fragment an outbound record into ordered BLE record fragments using connection-local sequence state.
     */
    fun fragmentOutbound(recordType: BleRecordType, payload: ByteArray): List<ByteArray> = synchronized(lock) {
        if (!isActive) return emptyList()
        // DATA records are strictly forbidden before cryptographic READY
        if (recordType == BleRecordType.DATA && state != BleConnectionState.READY) {
            return emptyList()
        }
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
        resetLocked()
    }

    private fun resetLocked() {
        reassembler.reset()
        nextOutboundSeq = 0
        isNotificationSubscribed = false
    }

    companion object {
        const val DEFAULT_MAX_ATT_VALUE_LENGTH = 20 // Default legacy ATT MTU 23 - 3 bytes opcode/handle
    }
}
