package io.godstone.mesh.delivery

import io.godstone.mesh.store.StoreDb
import io.godstone.mesh.store.StoreSchema

// C6.4.1-A / C7.4.1 -- TEST-ONLY mutation-control repository (Android). Lives in TEST
// source; NOT compiled into any shipping build. Production
// [SqliteDeliveryRepository] builds its CAS WHERE clause UNCONDITIONALLY and
// atomically deletes the held frame within a transaction -- there is no production
// API to drop the state / mode / recipient predicate or skip held retirement.
// This class rebuilds the WEAKENED SQL (a guard dropped) and optionally skips held
// retirement to PROVE each predicate and the held retirement are load-bearing:
// with a guard off or retirement skipped, the WRONG outcome results, so the
// production implementation (always on) is what makes the concurrency guarantees
// hold. `ci/no_delivery_guard_bypass.py` fails the build if a guard-bypass
// token re-enters a main-source directory, so this class can NEVER migrate
// into production by accident.
//
// Reads / enqueue / clear delegate to a production [SqliteDeliveryRepository]
// over the SAME [db]; only [transition] / [acknowledgeBoundAndRetire] are weakened.
// The 0-row CAS reclassification and the lifecycle truth-table are reused from the
// production repo (`internal` `transitionMapping` / `classifyZeroRowTransition`
// / `classifyZeroRowAck`), so the weakened repo and the production repo
// classify identical inputs identically -- no duplicated classification logic
// to drift.
internal class MutatedDeliveryRepository(
    private val db: StoreDb,
    private val stateGuard: Boolean = true,
    private val modeGuard: Boolean = true,
    private val recipientGuard: Boolean = true,
    private val skipHeldRetirement: Boolean = false,
) : DeliveryRepository {

    private val strong = SqliteDeliveryRepository(db)

    private class MutatedMissingHeldException : RuntimeException("active delivery missing held frame")
    private enum class MutatedAckRetireResult { APPLIED, NO_MATCH }

    override fun get(msgId: ByteArray): DeliveryLookup = strong.get(msgId)

    override fun enqueue(
        msgId: ByteArray,
        ackMode: AckMode,
        expectedRecipient: ByteArray?,
    ): EnqueueResult = strong.enqueue(msgId, ackMode, expectedRecipient)

    override fun clear(msgId: ByteArray): ClearResult = strong.clear(msgId)

    override fun transition(msgId: ByteArray, transition: DeliveryTransition): TransitionResult {
        if (msgId.size != 16) return TransitionResult.InvalidArgument
        val (target, validFroms) = strong.transitionMapping(transition)
        val sql = transitionSql(target, validFroms)
        return try {
            val affected = db.execDeliveryUpdate(sql, arrayOf(msgId))
            when (affected) {
                1 -> TransitionResult.Applied
                0 -> strong.classifyZeroRowTransition(msgId, target, validFroms)
                else -> TransitionResult.StorageFailure
            }
        } catch (e: Exception) {
            TransitionResult.StorageFailure
        }
    }

    override fun acknowledgeBoundAndRetire(
        msgId: ByteArray,
        expectedRecipient: ByteArray,
    ): AckResult {
        if (msgId.size != 16) return AckResult.InvalidArgument
        if (expectedRecipient.size != 16) return AckResult.InvalidArgument
        val sql = acknowledgeBoundSql()
        // Recipient bind slot is present ONLY when recipientGuard is on (mirrors the
        // pre-C6.4.1 guarded builder). Declared `Array<ByteArray?>` so expected-type
        // inference flows into both branches.
        val bindArgs: Array<ByteArray?> =
            if (recipientGuard) arrayOf(msgId, expectedRecipient) else arrayOf(msgId)
        return try {
            val result = db.inTransaction { tx ->
                val affected = tx.execDeliveryUpdate(sql, bindArgs)
                if (affected == 0) {
                    return@inTransaction MutatedAckRetireResult.NO_MATCH
                }
                if (affected != 1) {
                    throw IllegalStateException("invariant violation: affected > 1")
                }
                if (!skipHeldRetirement) {
                    val deleted = tx.deleteHeld(msgId)
                    if (deleted != 1) {
                        throw MutatedMissingHeldException()
                    }
                }
                MutatedAckRetireResult.APPLIED
            }
            when (result) {
                MutatedAckRetireResult.APPLIED -> AckResult.Applied
                MutatedAckRetireResult.NO_MATCH -> strong.classifyZeroRowAck(msgId, expectedRecipient)
            }
        } catch (e: MutatedMissingHeldException) {
            AckResult.Corrupt // Transaction rolled back; missing held row is cross-table corruption
        } catch (e: Exception) {
            AckResult.StorageFailure // Transaction rolled back
        }
    }

    // --- weakened CAS SQL builders (mirror the removed pre-C6.4.1 builders) ----

    private fun transitionSql(target: DeliveryState, validFroms: Set<DeliveryState>): String {
        val sb = StringBuilder("UPDATE ${StoreSchema.DELIVERY_TABLE} ")
            .append("SET ${StoreSchema.COL_D_STATE} = ").append(target.code)
            .append(" WHERE ${StoreSchema.COL_D_MSG_ID} = ?")
        if (stateGuard) {
            sb.append(" AND ").append(StoreSchema.COL_D_STATE).append(" IN (")
                .append(validFroms.joinToString(",") { it.code.toString() }).append(")")
        }
        return sb.toString()
    }

    private fun acknowledgeBoundSql(): String {
        val sb = StringBuilder("UPDATE ${StoreSchema.DELIVERY_TABLE} ")
            .append("SET ${StoreSchema.COL_D_STATE} = ").append(DeliveryState.ACKNOWLEDGED_BY_RECIPIENT.code)
            .append(" WHERE ${StoreSchema.COL_D_MSG_ID} = ?")
        if (stateGuard) {
            sb.append(" AND ").append(StoreSchema.COL_D_STATE).append(" IN (")
                .append(DeliveryState.QUEUED_DURABLY.code).append(", ")
                .append(DeliveryState.HANDED_TO_RELAY.code).append(")")
        }
        if (modeGuard) {
            sb.append(" AND ").append(StoreSchema.COL_D_ACK_MODE).append(" = ").append(AckMode.SINGLE_RECIPIENT.code)
        }
        if (recipientGuard) {
            sb.append(" AND ").append(StoreSchema.COL_D_EXPECTED).append(" = ?")
        }
        return sb.toString()
    }
}