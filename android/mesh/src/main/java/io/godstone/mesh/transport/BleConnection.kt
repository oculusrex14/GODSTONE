package io.godstone.mesh.transport

import java.util.concurrent.atomic.AtomicReference

/**
 * Authoritative connection state and lifecycle for a persistent BLE link (ADR-002, Phase C8.4D1-A1/R2/R2.1).
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
        get() = synchronized(lock) { _remoteNodeHint?.copyOf() }

    private var _localRole: BleRole? = null
    val localRole: BleRole?
        get() = synchronized(lock) { _localRole }

    val isRoleBound: Boolean
        get() = synchronized(lock) { _localRole != null && _remoteNodeHint != null }

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
            return isRoleBound && isNotificationSubscribed && maxAttValueLength >= DEFAULT_MAX_ATT_VALUE_LENGTH
        }

    private val reassembler = BleRecordReassembler(clock)
    private var nextOutboundSeq: Int = 0
    private val lock = Any()

    /**
     * Validates and executes state transitions. Direct transitions to READY or backwards transitions are rejected.
     */
    fun transitionTo(newState: BleConnectionState) = synchronized(lock) {
        val current = _state.get()
        if (current == newState) return@synchronized

        val valid = when (current) {
            BleConnectionState.DISCOVERED ->
                newState == BleConnectionState.PROVISIONAL_CONNECTING || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.PROVISIONAL_CONNECTING ->
                newState == BleConnectionState.PROVISIONAL_CONNECTED || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.PROVISIONAL_CONNECTED ->
                newState == BleConnectionState.LINK_INFO_READING || newState == BleConnectionState.ROLE_BOUND || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.LINK_INFO_READING ->
                newState == BleConnectionState.LINK_INFO_WRITING || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.LINK_INFO_WRITING ->
                newState == BleConnectionState.ROLE_BOUND || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.ROLE_BOUND ->
                newState == BleConnectionState.HANDSHAKE_IN_PROGRESS || newState == BleConnectionState.QUARANTINED || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.HANDSHAKE_IN_PROGRESS ->
                (newState == BleConnectionState.READY && isHandshakeTransportReady) || newState == BleConnectionState.QUARANTINED || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.READY ->
                newState == BleConnectionState.QUARANTINED || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.QUARANTINED ->
                newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.CLOSING ->
                newState == BleConnectionState.CLOSED
            BleConnectionState.CLOSED -> false
        }

        check(valid) { "Illegal state transition from $current to $newState" }
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
        check(s == BleConnectionState.PROVISIONAL_CONNECTED || s == BleConnectionState.LINK_INFO_WRITING || s == BleConnectionState.PROVISIONAL_CONNECTING || s == BleConnectionState.DISCOVERED) {
            "Cannot bind role from state $s"
        }

        _remoteNodeHint = hint.copyOf()
        _localRole = role
        _state.set(BleConnectionState.ROLE_BOUND)
    }

    fun bindInitiatorAfterLinkInfoWriteAck(remoteHint: ByteArray) = synchronized(lock) {
        bindRole(remoteHint, BleRole.INITIATOR)
    }

    fun bindResponderFromAcceptedIncomingLinkInfo(remoteHint: ByteArray) = synchronized(lock) {
        bindRole(remoteHint, BleRole.RESPONDER)
    }

    fun markConnected(negotiatedAttValueLength: Int? = null) = synchronized(lock) {
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
        _remoteNodeHint = null
        _localRole = null
    }

    /**
     * Fragment an outbound record into ordered BLE record fragments using connection-local sequence state.
     * Enforces phase-specific record type restrictions.
     */
    fun fragmentOutbound(recordType: BleRecordType, payload: ByteArray): List<ByteArray> = synchronized(lock) {
        if (!isActive) return emptyList()

        when (recordType) {
            BleRecordType.DATA -> {
                if (state != BleConnectionState.READY) return emptyList()
            }
            BleRecordType.HS1, BleRecordType.HS2, BleRecordType.HS3 -> {
                val s = state
                if (!isHandshakeTransportReady || (s != BleConnectionState.ROLE_BOUND && s != BleConnectionState.HANDSHAKE_IN_PROGRESS)) {
                    return emptyList()
                }
            }
            BleRecordType.CLOSE -> {
                // CLOSE allowed if active
            }
        }

        val seq = nextOutboundSeq
        nextOutboundSeq = (nextOutboundSeq + 1) and 0xFF
        return BleRecordFragmenter.fragment(recordType, seq, payload, maxAttValueLength)
    }

    /**
     * Ingest an inbound ATT value, decode it as a canonical BleRecord fragment, and reassemble.
     * Gating is strictly enforced BEFORE fragment is passed to the reassembler.
     */
    fun ingestInboundAttValue(bytes: ByteArray): BleReassembledRecord? = synchronized(lock) {
        if (!isActive) return null
        val frag = BleRecordCodec.decodeFragment(bytes) ?: return null

        when (frag.header.recordType) {
            BleRecordType.DATA -> {
                if (state != BleConnectionState.READY) return null
            }
            BleRecordType.HS1, BleRecordType.HS2, BleRecordType.HS3 -> {
                val s = state
                if (!isHandshakeTransportReady || (s != BleConnectionState.ROLE_BOUND && s != BleConnectionState.HANDSHAKE_IN_PROGRESS)) {
                    return null
                }
            }
            BleRecordType.CLOSE -> {
                // CLOSE allowed if active
            }
        }

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
