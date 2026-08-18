package io.godstone.mesh.delivery

import io.godstone.mesh.store.StoreDb
import io.godstone.mesh.store.StoreSchema

// Stage 4C.1 / C6.3 / **C6.4** -- production [DeliveryRepository] backed by the
// SAME SQLite DB as the held-frames store. Folds the C6.1 `DeliveryJournal` plus
// the enqueue / transition / retire classification into ONE atomic aggregate over
// the `delivery_state` row keyed by msg_id, so the ACK authenticity decision (C2)
// binds to the recipient recorded in durable outbound state INDEPENDENT of the
// ACK frame (ADR-005: do not claim an ACK is from the intended recipient unless
// the expected recipient comes from durable outbound state).
//
// C6.4 hardening (see [DeliveryRepository] / [DeliveryTracker] doc):
//  * StorageFailure is REAL (C6.4-A): every StoreDb call is wrapped in
//    `try { ... } catch (e: Exception) { ... StorageFailure }` (NOT Throwable).
//    Absence / conflict / no-match use their own sentinels (null / false / 0 row
//    count) and are NEVER folded into a thrown failure.
//  * 16-byte msg_id (C6.4-D): every method rejects a non-16-byte msg_id with
//    `InvalidArgument` BEFORE any SQL (the GMP/2.1 msg_id is BLAKE2s-128 = 16
//    bytes; the schema `CHECK (length(msg_id) = 16)` is defense-in-depth).
//  * Real SQL CAS (C6.4-F): [transition] runs a guarded
//    `UPDATE ... SET state WHERE msg_id AND state IN (...)` and decides [Applied]
//    by the affected row count (1), NOT a stale pre-read; a 0-row CAS is re-read
//    ONCE to classify.
//  * Lifecycle truth-table owned here (C6.4-G / C7.5.1): [transition] takes a
//    [DeliveryTransition] which explicitly and exhaustively specifies the target
//    state, valid from-states, and held-frame disposition ([HeldDisposition.RETAIN]
//    vs [HeldDisposition.RETIRE_ATOMICALLY]).
//  * MARK_HANDED (C7.5.1): guarded state-only CAS (held frame retained for relay transport).
//  * ACK (C7.4 / C7.4.1): authenticated guarded CAS + exact held frame delete in ONE transaction.
//  * EXPIRE / CANCEL (C7.5 / C7.5.1): guarded terminal CAS + exact held frame delete in ONE transaction.
//  * Terminal delivery row remains historical authority.
//  * [clear] is typed (C6.4-J): a failed destructive operation is never
//    indistinguishable from success.
//
// C6.4.1-A: production CAS is UNCONDITIONAL. The state / mode / recipient WHERE
// predicates are ALWAYS present -- there is no production API to drop a
// predicate. The C6.4-M mutation controls were REMOVED from this class; mutation
// testing moved to the TEST-ONLY `MutatedDeliveryRepository` (test source),
// which rebuilds the WEAKENED SQL to prove each predicate is load-bearing.
// `ci/no_delivery_guard_bypass.py` fails the build if a guard-bypass token
// re-enters production source.
//
// C6.4-N: row-atomicity here is the `delivery_state` row only. It does NOT yet
// make `persist held frame` + `enqueue delivery record` atomic -- that
// cross-table outbound transaction is C6.6. The int state / ack_mode codes are
// the cross-platform persistence contract (NOT enum ordinals). An unknown state
// or ack_mode code, or a row that violates the C6.1 binding invariant, or a
// persisted state code 0 (UNAVAILABLE -- not a legal durable row, C6.4-C),
// decodes to [DeliveryLookup.Corrupt] -- fail closed (C6.5), never silently to
// UNAVAILABLE. Mirrors `SqliteDeliveryRepository` on iOS (byte-identical schema
// + SQL + codes).
internal class SqliteDeliveryRepository(
    private val db: StoreDb,
) : DeliveryRepository {

    override fun get(msgId: ByteArray): DeliveryLookup {
        if (msgId.size != 16) return DeliveryLookup.InvalidArgument // C6.4-D
        return try {
            val row = db.readDelivery(msgId) ?: return DeliveryLookup.NotFound
            // C6.4-C: fromPersistedCode rejects code 0 (UNAVAILABLE) -- a persisted
            // UNAVAILABLE is corrupt, NOT a legal durable row.
            val state = DeliveryState.fromPersistedCode(row.state) ?: return DeliveryLookup.Corrupt
            val ackMode = AckMode.fromCode(row.ackMode) ?: return DeliveryLookup.Corrupt
            // C6.1 binding invariant (mirrors the schema CHECK): NONE -> null
            // recipient; SINGLE_RECIPIENT -> 16-byte recipient. A row that violates
            // it (e.g. directly mutated) is corrupt -- fail closed.
            if (!bindingConsistent(ackMode, row.expectedRecipient)) return DeliveryLookup.Corrupt
            DeliveryLookup.Found(DeliveryRecord(msgId, state, ackMode, row.expectedRecipient))
        } catch (e: Exception) {
            DeliveryLookup.StorageFailure // C6.4-A: absence (null) != failure (throw)
        }
    }

    override fun enqueue(
        msgId: ByteArray,
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): EnqueueResult {
        // C6.4-D: reject a non-16-byte msg_id before any SQL.
        if (msgId.size != 16) return EnqueueResult.InvalidArgument
        // C6.1 invariant: NONE -> no recipient; SINGLE_RECIPIENT -> 16-byte recipient.
        if (!bindingConsistent(ackMode, expectedRecipient)) return EnqueueResult.Corrupt
        return try {
            when (val l = get(msgId)) {
                DeliveryLookup.NotFound -> {
                    if (db.insertDelivery(
                            msgId, DeliveryState.QUEUED_DURABLY.code, ackMode.code, expectedRecipient,
                        )
                    ) {
                        EnqueueResult.Created
                    } else {
                        // ON CONFLICT DO NOTHING -> a row appeared mid-call; re-read to classify.
                        classifyExisting(msgId, ackMode, expectedRecipient)
                    }
                }
                is DeliveryLookup.Found -> classifyExisting(l.record, ackMode, expectedRecipient)
                DeliveryLookup.Corrupt -> EnqueueResult.Corrupt
                DeliveryLookup.StorageFailure -> EnqueueResult.StorageFailure
                DeliveryLookup.InvalidArgument -> EnqueueResult.InvalidArgument // unreachable (msgId validated)
            }
        } catch (e: Exception) {
            EnqueueResult.StorageFailure // C6.4-A
        }
    }

    override fun transition(msgId: ByteArray, transition: DeliveryTransition): TransitionResult {
        if (msgId.size != 16) return TransitionResult.InvalidArgument // C6.4-D
        val spec = transitionSpec(transition)
        val sql = transitionSql(spec.target, spec.validFroms)

        return when (spec.heldDisposition) {
            HeldDisposition.RETAIN -> executeStateOnlyTransition(msgId, spec, sql)
            HeldDisposition.RETIRE_ATOMICALLY -> executeRetiringTransition(msgId, spec, sql)
        }
    }

    private fun executeStateOnlyTransition(
        msgId: ByteArray,
        spec: TransitionSpec,
        sql: String,
    ): TransitionResult {
        return try {
            val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))
            when (affected) {
                1 -> TransitionResult.Applied
                0 -> classifyZeroRowTransition(msgId, spec.target, spec.validFroms)
                else -> TransitionResult.StorageFailure // affected > 1: invariant violation (PK is msg_id)
            }
        } catch (e: Exception) {
            TransitionResult.StorageFailure // C6.4-A
        }
    }

    private fun executeRetiringTransition(
        msgId: ByteArray,
        spec: TransitionSpec,
        sql: String,
    ): TransitionResult {
        return try {
            val result = db.inTransaction { tx ->
                val affected = tx.execDeliveryUpdate(sql, arrayOf(msgId))
                if (affected == 0) {
                    return@inTransaction CrossTableRetireResult.NO_MATCH
                }
                if (affected != 1) {
                    throw IllegalStateException("invariant violation: affected > 1")
                }
                val deleted = tx.deleteHeld(msgId)
                if (deleted != 1) {
                    throw MissingHeldException()
                }
                CrossTableRetireResult.APPLIED
            }
            when (result) {
                CrossTableRetireResult.APPLIED -> TransitionResult.Applied
                CrossTableRetireResult.NO_MATCH -> classifyZeroRowTransition(msgId, spec.target, spec.validFroms)
            }
        } catch (e: MissingHeldException) {
            TransitionResult.Corrupt // Transaction rolled back; missing held row is cross-table corruption
        } catch (e: Exception) {
            TransitionResult.StorageFailure // C6.4-A
        }
    }

    private class MissingHeldException : RuntimeException("active delivery missing held frame")

    private enum class CrossTableRetireResult {
        APPLIED,
        NO_MATCH,
    }

    override fun acknowledgeBoundAndRetire(
        msgId: ByteArray,
        expectedRecipient: ByteArray,
    ): AckResult {
        // C6.4-D + binding guard: the authenticated binding is a SINGLE_RECIPIENT
        // binding with a 16-byte recipient. The tracker only calls this for such a
        // record (it gates `none` / null first); a malformed call fails closed
        // before any SQL. C6.4.1-I: `ackMode` + optionality are removed -- the SQL
        // hard-codes `ack_mode = 1` and the recipient is always bound.
        // C7.4: runs guarded ACK CAS AND exact held frame deletion in ONE atomic
        // transaction. Missing held row triggers rollback and yields Corrupt.
        if (msgId.size != 16) return AckResult.InvalidArgument
        if (expectedRecipient.size != 16) return AckResult.InvalidArgument
        val sql = acknowledgeBoundSql()
        val bindArgs: Array<ByteArray?> = arrayOf(msgId, expectedRecipient)
        return try {
            val result = db.inTransaction { tx ->
                val affected = tx.execDeliveryUpdate(sql, bindArgs)
                if (affected == 0) {
                    return@inTransaction CrossTableRetireResult.NO_MATCH
                }
                if (affected != 1) {
                    throw IllegalStateException("invariant violation: affected > 1")
                }
                val deleted = tx.deleteHeld(msgId)
                if (deleted != 1) {
                    throw MissingHeldException()
                }
                CrossTableRetireResult.APPLIED
            }
            when (result) {
                CrossTableRetireResult.APPLIED -> AckResult.Applied
                CrossTableRetireResult.NO_MATCH -> classifyZeroRowAck(msgId, expectedRecipient)
            }
        } catch (e: MissingHeldException) {
            AckResult.Corrupt // Transaction rolled back; missing held row is cross-table corruption
        } catch (e: Exception) {
            AckResult.StorageFailure // Transaction rolled back
        }
    }

    override fun clear(msgId: ByteArray): ClearResult {
        if (msgId.size != 16) return ClearResult.InvalidArgument // C6.4-D
        return try {
            val affected = db.execDeliveryUpdate(StoreSchema.clearDeliverySql(), arrayOf(msgId))
            when (affected) {
                1 -> ClearResult.Cleared
                0 -> ClearResult.AlreadyAbsent
                else -> ClearResult.StorageFailure
            }
        } catch (e: Exception) {
            ClearResult.StorageFailure // C6.4-A
        }
    }

    // --- C6.4-F/G / C7.5.1: guarded SQL CAS builders & transition specs -----

    /** Explicit disposition for held frames on a delivery transition (C7.5.1). */
    internal enum class HeldDisposition {
        RETAIN,
        RETIRE_ATOMICALLY,
    }

    /** Explicit transition specification (target state, valid source states, held disposition). */
    internal data class TransitionSpec(
        val target: DeliveryState,
        val validFroms: Set<DeliveryState>,
        val heldDisposition: HeldDisposition,
    )

    /** Canonical mapping of [DeliveryTransition] to its explicit specification (C7.5.1). */
    internal fun transitionSpec(
        transition: DeliveryTransition,
    ): TransitionSpec =
        when (transition) {
            DeliveryTransition.MARK_HANDED -> TransitionSpec(
                target = DeliveryState.HANDED_TO_RELAY,
                validFroms = setOf(DeliveryState.QUEUED_DURABLY),
                heldDisposition = HeldDisposition.RETAIN,
            )

            DeliveryTransition.EXPIRE -> TransitionSpec(
                target = DeliveryState.EXPIRED,
                validFroms = setOf(
                    DeliveryState.QUEUED_DURABLY,
                    DeliveryState.HANDED_TO_RELAY,
                ),
                heldDisposition = HeldDisposition.RETIRE_ATOMICALLY,
            )

            DeliveryTransition.CANCEL -> TransitionSpec(
                target = DeliveryState.CANCELLED_LOCALLY,
                validFroms = setOf(
                    DeliveryState.QUEUED_DURABLY,
                    DeliveryState.HANDED_TO_RELAY,
                ),
                heldDisposition = HeldDisposition.RETIRE_ATOMICALLY,
            )
        }

    /** The fixed (target, validFroms) mapping the repository owns (C6.4-G).
     *  C6.4.1-A: `internal` so the test-only `MutatedDeliveryRepository` reuses
     *  the exact lifecycle truth-table without duplicating it. */
    internal fun transitionMapping(t: DeliveryTransition): Pair<DeliveryState, Set<DeliveryState>> {
        val spec = transitionSpec(t)
        return spec.target to spec.validFroms
    }

    /**
     * `UPDATE delivery_state SET state = target WHERE msg_id = ? AND state IN (...)`.
     * C6.4-F: the state predicate is the load-bearing CAS guard. C6.4.1-A:
     * production builds this UNCONDITIONALLY; the test-only
     * `MutatedDeliveryRepository` rebuilds it without the state predicate to
     * prove it is load-bearing.
     */
    private fun transitionSql(target: DeliveryState, validFroms: Set<DeliveryState>): String {
        val codes = validFroms.joinToString(",") { it.code.toString() }
        return "UPDATE ${StoreSchema.DELIVERY_TABLE} " +
            "SET ${StoreSchema.COL_D_STATE} = ${target.code} " +
            "WHERE ${StoreSchema.COL_D_MSG_ID} = ? AND ${StoreSchema.COL_D_STATE} IN ($codes)"
    }

    /**
     * `UPDATE delivery_state SET state = ACKNOWLEDGED WHERE msg_id = ? AND state
     * IN (QUEUED, HANDED) AND ack_mode = SINGLE_RECIPIENT AND expected_recipient = ?`.
     * C6.4-H: state + mode + the EXACT durable recipient in ONE WHERE clause; the
     * recipient is ALWAYS bound (bind slot 2). C6.4.1-A: production builds this
     * UNCONDITIONALLY; the test-only `MutatedDeliveryRepository` rebuilds it minus
     * a predicate to prove each is load-bearing.
     */
    private fun acknowledgeBoundSql(): String =
        "UPDATE ${StoreSchema.DELIVERY_TABLE} " +
            "SET ${StoreSchema.COL_D_STATE} = ${DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code} " +
            "WHERE ${StoreSchema.COL_D_MSG_ID} = ? " +
            "AND ${StoreSchema.COL_D_STATE} IN (${DeliveryState.QUEUED_DURABLY.code}, ${DeliveryState.HANDED_TO_RELAY.code}) " +
            "AND ${StoreSchema.COL_D_ACK_MODE} = ${AckMode.SINGLE_RECIPIENT.code} " +
            "AND ${StoreSchema.COL_D_EXPECTED} = ?"

    // --- C6.4-F/H: zero-row CAS reclassification ----------------------------

    /**
     * Classify a 0-row transition CAS (C6.4-F): re-read ONCE.
     *  * NotFound -> [UnknownMessage];
     *  * Corrupt -> [Corrupt]; StorageFailure -> [StorageFailure];
     *  * state == target -> [AlreadyInTarget];
     *  * state in validFroms -> [StorageFailure] (invariant violation -- the
     *    guarded SQL should have matched; only reachable under a weakened-state
     *    mutation (test-only) or a raced same-microsecond write);
     *  * any other legal durable state -> [RejectedState].
     * C6.4.1-A: `internal` so the test-only `MutatedDeliveryRepository` reuses
     * the exact reclassification (no duplication / no drift).
     */
    internal fun classifyZeroRowTransition(
        msgId: ByteArray,
        target: DeliveryState,
        validFroms: Set<DeliveryState>,
    ): TransitionResult = when (val l = get(msgId)) {
        DeliveryLookup.NotFound -> TransitionResult.UnknownMessage
        DeliveryLookup.Corrupt -> TransitionResult.Corrupt
        DeliveryLookup.StorageFailure -> TransitionResult.StorageFailure
        DeliveryLookup.InvalidArgument -> TransitionResult.InvalidArgument // unreachable
        is DeliveryLookup.Found -> {
            val s = l.record.state
            when {
                s == target -> TransitionResult.AlreadyInTarget
                s in validFroms -> TransitionResult.StorageFailure // SQL should have matched
                else -> TransitionResult.RejectedState
            }
        }
    }

    /**
     * Classify a 0-row ACK CAS (C6.4-H): re-read ONCE. The tracker ALREADY
     * authenticated this ACK before calling [acknowledgeBound], so a same-binding
     * ACKNOWLEDGED row is a legitimate [DuplicateAuthenticatedAck] (the ACK lost
     * the CAS to another authenticated ACK), NOT a re-verification.
     *  * NotFound -> [UnknownMessage];
     *  * Corrupt -> [Corrupt]; StorageFailure -> [StorageFailure];
     *  * binding changed (ack_mode or recipient differ) -> [UnknownMessage]
     *    (an old ACK must NEVER bind to a re-bound row);
     *  * state == ACKNOWLEDGED + same binding -> [DuplicateAuthenticatedAck];
     *  * state == EXPIRED / CANCELLED -> [RejectedState];
     *  * same binding + QUEUED/HANDED still present -> [StorageFailure]
     *    (invariant violation -- the guarded SQL should have matched; only
     *    reachable under a weakened-predicate mutation (test-only));
     *  * any other state -> [RejectedState].
     * C6.4.1-A: `internal` so the test-only `MutatedDeliveryRepository` reuses
     * the exact reclassification (no duplication / no drift).
     */
    internal fun classifyZeroRowAck(msgId: ByteArray, expectedRecipient: ByteArray): AckResult =
        when (val l = get(msgId)) {
            DeliveryLookup.NotFound -> AckResult.UnknownMessage
            DeliveryLookup.Corrupt -> AckResult.Corrupt
            DeliveryLookup.StorageFailure -> AckResult.StorageFailure
            DeliveryLookup.InvalidArgument -> AckResult.InvalidArgument // unreachable
            is DeliveryLookup.Found -> {
                val rec = l.record
                val sameBinding = rec.ackMode == AckMode.SINGLE_RECIPIENT &&
                    rec.expectedRecipientNodeId.contentEquals(expectedRecipient)
                if (!sameBinding) {
                    AckResult.UnknownMessage // old ACK must never bind to a re-bound row
                } else when (rec.state) {
                    DeliveryState.ACKNOWLEDGED_BY_RECIPIENT -> AckResult.DuplicateAuthenticatedAck
                    DeliveryState.EXPIRED, DeliveryState.CANCELLED_LOCALLY -> AckResult.RejectedState
                    DeliveryState.QUEUED_DURABLY, DeliveryState.HANDED_TO_RELAY ->
                        AckResult.StorageFailure // SQL should have matched
                    else -> AckResult.RejectedState
                }
            }
        }

    // --- enqueue classification ---------------------------------------------

    private fun classifyExisting(
        msgId: ByteArray,
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): EnqueueResult = when (val l = get(msgId)) {
        is DeliveryLookup.Found -> classifyExisting(l.record, ackMode, expectedRecipient)
        DeliveryLookup.NotFound -> EnqueueResult.StorageFailure // row vanished -- storage anomaly
        DeliveryLookup.Corrupt -> EnqueueResult.Corrupt
        DeliveryLookup.StorageFailure -> EnqueueResult.StorageFailure
        DeliveryLookup.InvalidArgument -> EnqueueResult.InvalidArgument // unreachable
    }

    private fun classifyExisting(
        rec: DeliveryRecord,
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): EnqueueResult {
        if (rec.state.isTerminal) return EnqueueResult.RejectedTerminalState
        // Non-terminal (QUEUED / HANDED): same binding -> idempotent; else conflict.
        return if (rec.ackMode == ackMode &&
            rec.expectedRecipientNodeId.contentEquals(expectedRecipient)
        ) EnqueueResult.AlreadyQueuedSameBinding
        else EnqueueResult.ConflictRecipient
    }

    /** C6.1 invariant: NONE -> null recipient; SINGLE_RECIPIENT -> 16-byte recipient. */
    private fun bindingConsistent(ackMode: AckMode, expectedRecipient: ByteArray?): Boolean =
        when (ackMode) {
            AckMode.NONE -> expectedRecipient == null
            AckMode.SINGLE_RECIPIENT -> expectedRecipient != null && expectedRecipient.size == 16
        }
}