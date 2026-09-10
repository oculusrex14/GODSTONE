package io.godstone.mesh.transport

/**
 * T18: the whole-record writer of the outbound path.
 *
 * The law this file keeps, stated once:
 *
 *   reserve(kind, clearLength)      - every check that can refuse a record
 *                                     does so here, by value, consuming
 *                                     nothing: no sequence number is taken,
 *                                     no nonce is burnt, no byte is staged.
 *   reservation.sealAndQueue(...)   - the one seal and the one fragmentation,
 *                                     after admission and only once;
 *   nextOut / completed / rewindInFlight / failed
 *                                   - the pump: at most one value in flight
 *                                     per direction, advanced only by real
 *                                     completions; a partial failure closes
 *                                     the relation and releases the staging,
 *                                     never the durable application data.
 *
 * The bounds are the card's and the codec's own: a sealed record may not
 * exceed min(MAX_RECORD, MAX_FRAGMENTS * (maxAttValueLength - HEADER_BYTES)),
 * a relation holds at most four admitted records, a direction at most
 * sixteen staged values, and one operation in flight. Every answer is a
 * sealed value; nothing here throws across the platform boundary.
 */

/** The typed completion of one staged ATT value as the outlet reports it. */
sealed class WriteCompletion {
    /** The value travelled; the pump may retire it and advance. */
    object Accepted : WriteCompletion()

    /** The outlet's own buffer refused the value; the pump stands still
     * and may re-hand the very same fragment when it is ready again. */
    object QueueFull : WriteCompletion()

    /** The write failed midway; the relation cannot stand. */
    object Failed : WriteCompletion()
}

/** The token that identifies one fragment on the wire, carried with the
 * relation it belongs to: a completion is honoured only when it names the
 * operation standing in flight, so a stale or duplicate completion moves
 * nothing. */
data class WriteOperation(
    val relationKey: RelationKey,
    val operationId: Long,
    val fragmentIndex: Int,
)

/** The bounded refusals of [RecordWriter.reserve]. */
sealed class AdmissionError {
    /** The sealed record would outgrow the record ceiling or the fragment
     * ceiling: the 65th fragment is told here, before the seal. */
    data class NotEnoughCapacity(
        val sealedLength: Int,
        val ceiling: Int,
        val fragmentCount: Int,
    ) : AdmissionError()

    /** More than [limit] admitted records stand on the relation. */
    data class TooManyAdmitted(val limit: Int) : AdmissionError()

    /** Staging this record would stage more than [limit] values. */
    data class TooManyStaged(val limit: Int) : AdmissionError()

    /** One operation already stands in flight for the direction. */
    object BusyInFlight : AdmissionError()

    /** The relation has fallen; the writer accepts nothing further. */
    object Inactive : AdmissionError()
}

/** The answer of [RecordWriter.reserve]. */
sealed class ReservationAnswer {
    data class Admitted(val reservation: Reservation) : ReservationAnswer()
    data class Refused(val error: AdmissionError) : ReservationAnswer()
}

/** The answer of [Reservation.sealAndQueue]. */
sealed class SealAnswer {
    /** Sealed once, fragmented once, staged; the pump may take it. */
    object Queued : SealAnswer()

    /** The seal refused, or the envelope lied about its length: nothing
     * was consumed - the sequence number stands where it stood. */
    data class Refused(val reason: String) : SealAnswer()
}

/** One fragment handed to the pump: the operation token and the bytes. */
data class OutgoingFragment(val operation: WriteOperation, val bytes: ByteArray)

/**
 * A reserved whole record. The reservation checked the length, the
 * ceilings, and the budgets; [sealAndQueue] now seals the clear text
 * exactly once with the session's sealer, fragments the sealed record
 * exactly once, takes the connection's next sequence number - consumed
 * here and only here - and stages the fragments.
 */
class Reservation internal constructor(
    private val writer: RecordWriter,
    internal val operationId: Long,
    internal val recordType: BleRecordType,
    internal val clearLength: Int,
) {
    /**
     * Seal [payload] with [sealer] (which returns null when the session
     * refuses), fragment once, and stage. The payload must be the very
     * clear text whose length stood reserved; any drift refuses the seal
     * before anything is consumed.
     */
    fun sealAndQueue(payload: ByteArray, sealer: (ByteArray) -> ByteArray?): SealAnswer =
        writer.sealAndQueueOf(this, payload, sealer)
}

/**
 * The writer of one direction of one relation. It is pure bookkeeping:
 * it owns no thread and speaks to no outlet; the transport drives the
 * pump loop, because only the transport can await the outlet's answer.
 */
class RecordWriter(
    internal val connection: BleConnection,
    internal val relationKey: RelationKey,
    private val maxAdmittedRecords: Int = DEFAULT_MAX_ADMITTED_RECORDS,
    private val maxStagedValues: Int = DEFAULT_MAX_STAGED_VALUES,
    private val maxInFlight: Int = DEFAULT_MAX_IN_FLIGHT,
) {
    companion object {
        /** The envelope the session's seal adds: the nonce the seal
         * carries and the authentication tag, as the transport
         * ciphertext format lays them out. */
        const val SEAL_NONCE_BYTES: Int = 8
        const val SEAL_TAG_BYTES: Int = 16
        const val SEAL_OVERHEAD_BYTES: Int = SEAL_NONCE_BYTES + SEAL_TAG_BYTES

        const val DEFAULT_MAX_ADMITTED_RECORDS: Int = 4
        const val DEFAULT_MAX_STAGED_VALUES: Int = 16
        const val DEFAULT_MAX_IN_FLIGHT: Int = 1
    }

    private inner class AdmittedRecord(
        val operationId: Long,
        val recordSeq: Int,
        val fragments: List<ByteArray>,
    ) {
        var nextFragment: Int = 0
        var stagedUpTo: Int = 0
        val remaining: Int get() = fragments.size - stagedUpTo
        val held: Int get() = stagedUpTo - nextFragment
    }

    private val lock = Any()
    private val admitted = ArrayDeque<AdmittedRecord>()

    /** The single value in flight for this direction, or null. */
    private var inFlight: WriteOperation? = null

    /** The bytes of the value in flight, kept for re-handing after a
     * queue-full refusal. */
    private var inFlightBytes: ByteArray? = null

    /** True once a partial failure has closed the relation. */
    private var closed = false

    private var nextOperationId: Long = 1L
    private var operationsIssued: Long = 0L
    private var staleCompletions: Long = 0L

    /**
     * Everything that can refuse a whole record refuses here, by value,
     * consuming nothing: neither the connection's sequence number nor the
     * session's nonce is touched, and no byte is staged.
     */
    fun reserve(recordType: BleRecordType, clearLength: Int): ReservationAnswer = synchronized(lock) {
        if (closed || !connection.isActive) {
            return@synchronized ReservationAnswer.Refused(AdmissionError.Inactive)
        }
        val capacity = connection.maxAttValueLength - BleRecordConstants.HEADER_BYTES
        if (capacity < 1 || clearLength < 0) {
            return@synchronized ReservationAnswer.Refused(
                AdmissionError.NotEnoughCapacity(clearLength + SEAL_OVERHEAD_BYTES, 0, 0)
            )
        }
        val sealedLength = clearLength + SEAL_OVERHEAD_BYTES
        val ceiling = minOf(
            BleRecordConstants.MAX_RECORD,
            BleRecordConstants.MAX_FRAGMENTS * capacity,
        )
        // The zero-length record still travels, in one fragment, as the
        // codec's canonical form lays it out.
        val fragmentCount = if (sealedLength == 0) 1
        else (sealedLength + capacity - 1) / capacity
        if (sealedLength > ceiling || fragmentCount > BleRecordConstants.MAX_FRAGMENTS) {
            return@synchronized ReservationAnswer.Refused(
                AdmissionError.NotEnoughCapacity(sealedLength, ceiling, fragmentCount)
            )
        }
        if (admitted.size >= maxAdmittedRecords) {
            return@synchronized ReservationAnswer.Refused(AdmissionError.TooManyAdmitted(maxAdmittedRecords))
        }
        // The bound of sixteen staged values is an invariant of the
        // staging, kept by topUpLocked, not a bar at the gate: a record
        // enters and its remainder follows as the pump drains.

        val operationId = nextOperationId++
        operationsIssued += 1
        return@synchronized ReservationAnswer.Admitted(
            Reservation(this, operationId, recordType, clearLength)
        )
    }

    /**
     * The one seal, the one fragmentation, the one consumption of the
     * sequence number. Called through [Reservation.sealAndQueue]; kept
     * here so the writer's lock is the single serialisation point.
     */
    internal fun sealAndQueueOf(reservation: Reservation, payload: ByteArray,
                                sealer: (ByteArray) -> ByteArray?): SealAnswer = synchronized(lock) {
        if (closed || !connection.isActive) {
            return@synchronized SealAnswer.Refused("the relation fell before the seal")
        }
        if (payload.size != reservation.clearLength) {
            return@synchronized SealAnswer.Refused("the payload drifted from the reservation")
        }
        val sealed = try {
            sealer(payload)
        } catch (_: Throwable) {
            null
        } ?: return@synchronized SealAnswer.Refused("the seal refused")
        if (sealed.size != reservation.clearLength + SEAL_OVERHEAD_BYTES) {
            return@synchronized SealAnswer.Refused("the seal lied about the envelope")
        }
        val capacity = connection.maxAttValueLength - BleRecordConstants.HEADER_BYTES
        val fragmentCount = if (sealed.size == 0) 1
        else (sealed.size + capacity - 1) / capacity
        val ceiling = minOf(
            BleRecordConstants.MAX_RECORD,
            BleRecordConstants.MAX_FRAGMENTS * capacity,
        )
        if (sealed.size > ceiling || fragmentCount > BleRecordConstants.MAX_FRAGMENTS) {
            // The belt and braces of the reservation's arithmetic: the seal
            // may not have lied, yet what it sealed is measured again
            // before the sequence number is consumed. Nothing is burnt.
            return@synchronized SealAnswer.Refused("the sealed record outgrew the ceiling")
        }
        if (admitted.size >= maxAdmittedRecords) {
            return@synchronized SealAnswer.Refused("the staging filled before the seal")
        }
        // What fits the window enters now; the rest follows on the
        // drains. The fullness itself is told by the transport as an
        // event, through stagingSaturatedForTest.

        // Consumed here, exactly once, after every check has passed.
        val seq = connection.takeOutboundSequence()
        val fragments = try {
            BleRecordFragmenter.fragment(reservation.recordType, seq, sealed,
                connection.maxAttValueLength)
        } catch (_: Throwable) {
            null
        } ?: return@synchronized SealAnswer.Refused("the fragmenter refused the record")
        if (fragments.isEmpty()) {
            return@synchronized SealAnswer.Refused("the fragmenter refused the record")
        }
        val record = AdmittedRecord(reservation.operationId, seq, fragments)
        val free = maxOf(0, maxStagedValues - stagedLocked())
        record.stagedUpTo = minOf(fragments.size, free)
        admitted.addLast(record)
        return@synchronized SealAnswer.Queued
    }

    /**
     * Hand the next fragment, if the direction is idle and a record stands
     * admitted. At most [maxInFlight] value is ever in flight.
     */
    fun nextOut(): OutgoingFragment? = synchronized(lock) {
        if (closed) return@synchronized null
        if (inFlight != null) return@synchronized null
        // Fill the window from the head before handing: values enter as
        // the pump frees space, in the order the records were admitted.
        topUpLocked()
        val record = admitted.firstOrNull { it.nextFragment < it.stagedUpTo }
            ?: return@synchronized null
        val index = record.nextFragment
        val operation = WriteOperation(relationKey, record.operationId, index)
        inFlight = operation
        inFlightBytes = record.fragments[index]
        return@synchronized OutgoingFragment(operation, record.fragments[index])
    }

    /**
     * A real completion of [operation]: the value travelled, the pump may
     * advance. A completion that does not name the standing in-flight
     * operation is stale or duplicate: it is counted and changes nothing.
     */
    fun completed(operation: WriteOperation): Boolean = synchronized(lock) {
        val standing = inFlight
        if (standing == null || standing != operation) {
            staleCompletions += 1
            return@synchronized false
        }
        val record = admitted.firstOrNull { it.operationId == operation.operationId }
            ?: run { staleCompletions += 1; inFlight = null; inFlightBytes = null
                     return@synchronized false }
        if (record.nextFragment != operation.fragmentIndex) {
            staleCompletions += 1
            return@synchronized false
        }
        record.nextFragment += 1
        if (record.nextFragment >= record.fragments.size &&
            record.stagedUpTo >= record.fragments.size) {
            admitted.remove(record)
        }
        inFlight = null
        inFlightBytes = null
        topUpLocked()
        return@synchronized true
    }

    /**
     * The outlet's own buffer refused the value: the in-flight operation
     * stands down so the very same fragment can be re-handed when the
     * outlet is ready again. Nothing is lost, nothing is retired.
     */
    fun rewindInFlight(operation: WriteOperation): Boolean = synchronized(lock) {
        val standing = inFlight
        if (standing == null || standing != operation) {
            staleCompletions += 1
            return@synchronized false
        }
        // The value was handed but never travelled: it returns to the
        // window for the very same fragment to be re-handed.
        inFlight = null
        inFlightBytes = null
        return@synchronized true
    }

    /**
     * A write failed midway: the relation cannot stand. The admitted
     * records and every staged value are released - the durable
     * application data is not the writer's to touch - and the writer
     * accepts nothing further.
     */
    fun failed(operation: WriteOperation): Boolean = synchronized(lock) {
        val standing = inFlight
        if (standing == null || standing != operation) {
            staleCompletions += 1
            return@synchronized false
        }
        closed = true
        admitted.clear()
        inFlight = null
        inFlightBytes = null
        return@synchronized true
    }

    /** The relation fell by other means (a disconnect, a quarantine):
     * release what was staged, accept nothing further. */
    fun shutdown() = synchronized(lock) {
        closed = true
        admitted.clear()
        inFlight = null
        inFlightBytes = null
    }

    private fun stagedLocked(): Int {
        var total = 0
        for (record in admitted) total += record.held
        return total
    }

    /** The window is full while some admitted record still waits to
     * stage and no value can be added: the truth the transport tells
     * to the ring when it sees it. */
    private fun stagingSaturatedLocked(): Boolean {
        if (stagedLocked() < maxStagedValues) return false
        for (record in admitted) if (record.stagedUpTo < record.fragments.size) return true
        return false
    }

    /** Fill the head record's window as far as the bound allows;
     * records are staged in the order they were admitted. */
    private fun topUpLocked() {
        var free = maxStagedValues - stagedLocked()
        if (free <= 0) return
        for (record in admitted) {
            if (record.stagedUpTo >= record.fragments.size) continue
            val take = minOf(record.fragments.size - record.stagedUpTo, free)
            record.stagedUpTo += take
            free -= take
            if (free <= 0) return
        }
    }

    // The witnesses the suite reads; internal, so the release symbols
    // carry the module mangling that the reflection scan insists upon.

    internal fun admittedCountForTest(): Int = synchronized(lock) { admitted.size }

    internal fun stagedValuesForTest(): Int = synchronized(lock) { stagedLocked() }

    internal fun inFlightForTest(): WriteOperation? = synchronized(lock) { inFlight }

    internal fun staleCompletionsForTest(): Long = synchronized(lock) { staleCompletions }

    internal fun stagingSaturatedForTest(): Boolean = synchronized(lock) { stagingSaturatedLocked() }

    internal fun operationsIssuedForTest(): Long = synchronized(lock) { operationsIssued }

    internal fun isClosedForTest(): Boolean = synchronized(lock) { closed }
}
