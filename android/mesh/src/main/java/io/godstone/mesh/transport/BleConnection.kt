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
     * Validates and executes state transitions. Direct transitions to ROLE_BOUND, HANDSHAKE_IN_PROGRESS, or READY are rejected.
     */
    fun transitionTo(newState: BleConnectionState): Boolean = synchronized(lock) {
        val current = _state.get()
        if (current == newState) return@synchronized true

        // T17: the reserved entrances reject by answer, never by escape -
        // roleBound is reached only through the bind family, handshake
        // progress only through beginHandshake, ready only through
        // markTrustedReady. A rejected transition preserves the state.
        if (newState == BleConnectionState.ROLE_BOUND ||
            newState == BleConnectionState.HANDSHAKE_IN_PROGRESS ||
            newState == BleConnectionState.READY) {
            return@synchronized false
        }

        val valid = when (current) {
            BleConnectionState.DISCOVERED ->
                newState == BleConnectionState.PROVISIONAL_CONNECTING || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.PROVISIONAL_CONNECTING ->
                newState == BleConnectionState.PROVISIONAL_CONNECTED || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.PROVISIONAL_CONNECTED ->
                newState == BleConnectionState.LINK_INFO_READING || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.LINK_INFO_READING ->
                newState == BleConnectionState.LINK_INFO_WRITING || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.LINK_INFO_WRITING ->
                newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.ROLE_BOUND ->
                newState == BleConnectionState.QUARANTINED || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.HANDSHAKE_IN_PROGRESS ->
                newState == BleConnectionState.QUARANTINED || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.READY ->
                newState == BleConnectionState.QUARANTINED || newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.QUARANTINED ->
                newState == BleConnectionState.CLOSING || newState == BleConnectionState.CLOSED
            BleConnectionState.CLOSING ->
                newState == BleConnectionState.CLOSED
            BleConnectionState.CLOSED -> false
        }

        if (!valid) return@synchronized false
        _state.set(newState)
        return@synchronized true
    }

    /**
     * One-way binding of remote node hint and elected role.
     * Accessible only through authoritative bind methods.
     */
    private fun bindRoleInternal(hint: ByteArray, role: BleRole): Boolean = synchronized(lock) {
        if (hint.size != BleRoleElection.NODE_HINT_BYTES) return@synchronized false
        if (_remoteNodeHint != null || _localRole != null) return@synchronized false
        val s = state
        if (s == BleConnectionState.CLOSED || s == BleConnectionState.CLOSING || s == BleConnectionState.QUARANTINED) {
            return@synchronized false
        }
        if (s != BleConnectionState.LINK_INFO_WRITING && s != BleConnectionState.PROVISIONAL_CONNECTED) {
            return@synchronized false
        }
        _remoteNodeHint = hint.copyOf()
        _localRole = role
        _state.set(BleConnectionState.ROLE_BOUND)
        return@synchronized true
    }

    fun bindInitiatorAfterLinkInfoWriteAck(remoteHint: ByteArray): Boolean = synchronized(lock) {
        if (state != BleConnectionState.LINK_INFO_WRITING) return@synchronized false
        return@synchronized bindRoleInternal(remoteHint, BleRole.INITIATOR)
    }

    fun bindResponderFromAcceptedIncomingLinkInfo(remoteHint: ByteArray): Boolean = synchronized(lock) {
        if (state != BleConnectionState.PROVISIONAL_CONNECTED) return@synchronized false
        return@synchronized bindRoleInternal(remoteHint, BleRole.RESPONDER)
    }

    /**
     * T17: advances a role-bound connection whose physical duplex is ready
     * into the handshake phase. False when either guard fails; the state is
     * preserved.
     */
    internal fun beginHandshake(): Boolean = synchronized(lock) {
        val s = _state.get()
        // T17: idempotent for the handshake's own course: a station that has
        // already entered the phase stays entitled to send its next record.
        if (s == BleConnectionState.HANDSHAKE_IN_PROGRESS) return@synchronized true
        if (s != BleConnectionState.ROLE_BOUND) return@synchronized false
        if (!isHandshakeTransportReady) return@synchronized false
        _state.set(BleConnectionState.HANDSHAKE_IN_PROGRESS)
        return@synchronized true
    }

    /**
     * T17: the only production entrance to cryptographic READY: the caller -
     * the transport's trusted handshake driver - has proved the peer's slot
     * ready in the session registry.
     */
    internal fun markTrustedReady(): Boolean = synchronized(lock) {
        if (_state.get() != BleConnectionState.HANDSHAKE_IN_PROGRESS) return@synchronized false
        _state.set(BleConnectionState.READY)
        return@synchronized true
    }

    fun startLinkInfoRead(): Boolean = synchronized(lock) {
        transitionTo(BleConnectionState.LINK_INFO_READING)
    }

    fun startLinkInfoWrite() = synchronized(lock) {
        transitionTo(BleConnectionState.LINK_INFO_WRITING)
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
     * T18: the single consumption point of the outbound sequence number. The
     * whole-record writer takes the number here, exactly once, after every
     * admission check has passed; a refused reservation never burns one.
     * The handshake fragmenters keep their own one consumption within
     * [fragmentOutbound], so each record consumes a number once and only once.
     */
    internal fun takeOutboundSequence(): Int = synchronized(lock) {
        val seq = nextOutboundSeq
        nextOutboundSeq = (nextOutboundSeq + 1) and 0xFF
        seq
    }

    internal fun peekOutboundSequenceForTest(): Int = synchronized(lock) { nextOutboundSeq }

    /**
     * Ingest an inbound ATT value, decode it as a canonical BleRecord fragment, and reassemble.
     * Gating is strictly enforced BEFORE fragment is passed to the reassembler.
     */
    fun ingestInboundAttValue(bytes: ByteArray): BleRecordIngestResult = synchronized(lock) {
        if (!isActive) return BleRecordIngestResult.Rejected(BleRecordRejection.INACTIVE)
        val frag = BleRecordCodec.decodeFragment(bytes)
            ?: return BleRecordIngestResult.Rejected(BleRecordRejection.MALFORMED_RECORD)

        when (frag.header.recordType) {
            BleRecordType.DATA -> {
                if (state != BleConnectionState.READY) return BleRecordIngestResult.Rejected(
                    BleRecordRejection.UNEXPECTED_STAGE)
            }
            BleRecordType.HS1, BleRecordType.HS2, BleRecordType.HS3 -> {
                val s = state
                if (!isHandshakeTransportReady || (s != BleConnectionState.ROLE_BOUND && s != BleConnectionState.HANDSHAKE_IN_PROGRESS)) {
                    return BleRecordIngestResult.Rejected(BleRecordRejection.UNEXPECTED_STAGE)
                }
            }
            BleRecordType.CLOSE -> {
                // CLOSE allowed if active
            }
        }

        val record = reassembler.receiveFragment(frag) ?: return BleRecordIngestResult.Pending
        return BleRecordIngestResult.Admitted(record)
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
        /**
         * T17: the pure predicate of the bind family - a caller that must
         * not corrupt authoritative state validates the hint with it
         * before attempting the bind.
         */
        fun canBindRemoteHint(hint: ByteArray): Boolean =
            hint.size == BleRoleElection.NODE_HINT_BYTES
        const val DEFAULT_MAX_ATT_VALUE_LENGTH = 20 // Default legacy ATT MTU 23 - 3 bytes opcode/handle
    }
}

/** T17: the typed reason of one rejected inbound record at the connection's
 * input queue: an inactive connection, a malformed fragment, or a record
 * seen at a state that does not accept its type. */
enum class BleRecordRejection {
    INACTIVE,
    MALFORMED_RECORD,
    UNEXPECTED_STAGE
}

/** T17: the typed result of ingesting one inbound ATT value. The three
 * outcomes a queue admits - a complete record, an incomplete one still in
 * flight, and a rejection with its reason - are returned apart, where the
 * old nullable answer conflated all four into null. */
sealed class BleRecordIngestResult {
    data class Admitted(val record: BleReassembledRecord) : BleRecordIngestResult()
    object Pending : BleRecordIngestResult()
    data class Rejected(val reason: BleRecordRejection) : BleRecordIngestResult()

    val isRejected: Boolean get() = this is Rejected
    val isPending: Boolean get() = this is Pending
    val admittedRecord: BleReassembledRecord? get() = (this as? Admitted)?.record
}
