package io.godstone.mesh.delivery

import io.godstone.mesh.store.MigrationExecutor
import io.godstone.mesh.store.MigrationStep

// ---------------------------------------------------------------------------
// T43 -- "Align delivery labels with durable evidence". The card's defect:
//
//   "A Boolean send currently advances HANDED_TO_RELAY even though it only
//    proves local ATT admission."
//
// So a message whose bytes were accepted by a local radio was recorded as
// durably handed to a relay -- a custody claim the node could not honour, and
// one that a restart would keep repeating. The laws of this file:
//
//   1. THE DURABLE STATE IS THE ONLY LABEL. A message standeth QUEUED_DURABLY
//      until an authenticated ACK from the INTENDED recipient produceth
//      ACKNOWLEDGED_BY_RECIPIENT. Nothing local moveth it.
//   2. A LINK OFFER IS EPHEMERAL TELEMETRY. [LinkOffer] recordeth that a radio
//      admitted some bytes. It is never persisted, never surviveth a restart,
//      and never calleth itself custody or delivery.
//   3. THE PROJECTION CLAIMETH NO MORE THAN THE DURABLE STATE SUPPORTETH.
//      [DeliveryProjection.label] is derived from the committed row plus the
//      ephemeral offers; an offer can only distinguisheth QUEUED from OFFERED,
//      and BOTH remain retryable. DELIVERED requireth the ACK.
//   4. LEGACY ROWS ARE MIGRATED CONSERVATIVELY. A persisted HANDED_TO_RELAY row
//      was never more than an ATT admission, so [LegacyHandedLabels] rewriteth
//      it to QUEUED_DURABLY (retryable) and preserveth the history; and even
//      BEFORE that migration runs, the projection of such a row is QUEUED.
//   5. NO RELAY RECEIPTS. This release profile carrieth none: an intermediate
//      relay's custody is not evidence, and no label may imply it.
//
// Nonshipping: the lab mesh path. The shipping LIGHT Archive-only graph
// carrieth no :mesh dependency, readiness stays false, and no device claim is
// made here.
// ---------------------------------------------------------------------------

/**
 * One LOCAL link admission: the radio accepted these bytes onto a link. It
 * proveth nothing about the recipient, and it is deliberately NOT durable --
 * a restart forgetteth it, which is exactly why it may never be the basis of a
 * custody label.
 */
class LinkOffer internal constructor(
    val msgId: ByteArray,
    /** The LINK's own identity key -- on this isle the peer key the transport
     *  useth (a node id), which sayeth WHERE the bytes were offered and nothing
     *  about the recipient. */
    val linkId: ByteArray,
    val admitted: Boolean,
    val atMonoMillis: Long,
) {
    fun msgIdCopy(): ByteArray = msgId.copyOf()
    fun linkIdCopy(): ByteArray = linkId.copyOf()
}

/** The honest label a consumer may display. */
enum class DeliveryLabel {
    /** No usable estate standeth. */
    UNAVAILABLE,
    /** Durably queued and retryable. The label of a message nothing has acknowledged. */
    QUEUED,
    /** Durably queued, AND a local link accepted some bytes at least once. STILL retryable. */
    OFFERED,
    /** The INTENDED recipient's authenticated ACK committed. The only delivery claim. */
    DELIVERED,
    EXPIRED,
    CANCELLED,
}

/**
 * The label a consumer readeth, with everything it is derived from.
 *
 * [retryable] is true exactly while the durable state is QUEUED_DURABLY --
 * an offer NEVER clear it, because an offer is not progress toward delivery.
 * [linkOffers] is the ephemeral count, [lastOfferMonoMillis] its recency; both
 * vanish on restart and neither is evidence.
 */
data class DeliveryProjection(
    val msgId: ByteArray,
    val state: DeliveryState,
    val label: DeliveryLabel,
    val retryable: Boolean,
    /** ADMITTED local offers only: the ones that make the label OFFERED. */
    val linkOffers: Int,
    /** Offered-but-refused local attempts: telemetry, and they raise no label. */
    val refusedOffers: Int,
    val lastOfferMonoMillis: Long?,
    val legacyHandedToRelay: Boolean,
) {
    companion object {
        /**
         * Derive the honest label. A legacy HANDED_TO_RELAY row is treated as
         * QUEUED_DURABLY's equivalent (law 4): the migration rewrite it, and
         * until then nothing may read custody from it.
         */
        fun of(
            msgId: ByteArray,
            state: DeliveryState,
            linkOffers: Int = 0,
            refusedOffers: Int = 0,
            lastOfferMonoMillis: Long? = null,
        ): DeliveryProjection {
            val legacy = state == DeliveryState.HANDED_TO_RELAY
            val effective = if (legacy) DeliveryState.QUEUED_DURABLY else state
            val label = when (effective) {
                DeliveryState.UNAVAILABLE -> DeliveryLabel.UNAVAILABLE
                DeliveryState.QUEUED_DURABLY ->
                    if (linkOffers > 0) DeliveryLabel.OFFERED else DeliveryLabel.QUEUED
                DeliveryState.ACKNOWLEDGED_BY_RECIPIENT -> DeliveryLabel.DELIVERED
                DeliveryState.EXPIRED -> DeliveryLabel.EXPIRED
                DeliveryState.CANCELLED_LOCALLY -> DeliveryLabel.CANCELLED
                // unreachable: `legacy` was already mapped above
                DeliveryState.HANDED_TO_RELAY -> DeliveryLabel.QUEUED
            }
            return DeliveryProjection(
                msgId = msgId.copyOf(),
                state = effective,
                label = label,
                retryable = effective == DeliveryState.QUEUED_DURABLY,
                linkOffers = linkOffers,
                refusedOffers = refusedOffers,
                lastOfferMonoMillis = lastOfferMonoMillis,
                legacyHandedToRelay = legacy,
            )
        }

        /** A refused read: a corrupt or absent row is never labelled queued. */
        fun unavailable(msgId: ByteArray): DeliveryProjection = DeliveryProjection(
            msgId = msgId.copyOf(), state = DeliveryState.UNAVAILABLE,
            label = DeliveryLabel.UNAVAILABLE, retryable = false,
            linkOffers = 0, refusedOffers = 0, lastOfferMonoMillis = null,
            legacyHandedToRelay = false,
        )
    }

    /** True only for the one honest delivery claim. */
    val claimsDelivery: Boolean get() = label == DeliveryLabel.DELIVERED

    /** True only when the durable state (not an offer) sayeth a relay holdeth it. */
    val claimsRelayCustody: Boolean get() = state == DeliveryState.HANDED_TO_RELAY

    fun msgIdCopy(): ByteArray = msgId.copyOf()
}

/**
 * The bounded, ephemeral ledger of local link admissions. It is memory only by
 * construction -- there is no persist, no load, and no store dependency -- so no
 * offer can ever become a durable claim.
 */
class LinkOfferLedger(
    private val bound: Int = MAX_OFFERS,
) {
    private val lock = Any()
    private val offers = ArrayDeque<LinkOffer>()
    private var dropped = 0L

    init {
        require(bound > 0) { "the ledger bound must be positive" }
    }

    /** Record one local admission verdict. Never persists anything. */
    fun record(msgId: ByteArray, linkId: ByteArray, admitted: Boolean, atMonoMillis: Long): LinkOffer {
        require(msgId.size == 16) { "a link offer names a 16-octet msg_id" }
        require(linkId.isNotEmpty()) { "a link offer names the link it was offered on" }
        val offer = LinkOffer(msgId.copyOf(), linkId.copyOf(), admitted, atMonoMillis)
        synchronized(lock) {
            while (offers.size >= bound) {
                offers.removeFirst()
                dropped++
            }
            offers.addLast(offer)
        }
        return offer
    }

    fun offersFor(msgId: ByteArray): List<LinkOffer> = synchronized(lock) {
        offers.filter { it.msgId.contentEquals(msgId) }
    }

    /** Every recorded attempt (admitted or refused): the telemetry census. */
    fun countFor(msgId: ByteArray): Int = synchronized(lock) {
        offers.count { it.msgId.contentEquals(msgId) }
    }

    /** ADMITTED attempts only: these are what raise the label to OFFERED. */
    fun admittedCountFor(msgId: ByteArray): Int = synchronized(lock) {
        offers.count { it.msgId.contentEquals(msgId) && it.admitted }
    }

    /** Refused attempts: telemetry that raiseth NO label. */
    fun refusedCountFor(msgId: ByteArray): Int = synchronized(lock) {
        offers.count { it.msgId.contentEquals(msgId) && !it.admitted }
    }

    fun lastOfferMonoFor(msgId: ByteArray): Long? = synchronized(lock) {
        offers.lastOrNull { it.msgId.contentEquals(msgId) }?.atMonoMillis
    }

    /** True iff a radio ADMITTED these bytes at least once: "copies may be out". */
    fun anyAdmitted(msgId: ByteArray): Boolean = synchronized(lock) {
        offers.any { it.msgId.contentEquals(msgId) && it.admitted }
    }

    fun total(): Int = synchronized(lock) { offers.size }

    fun droppedCount(): Long = synchronized(lock) { dropped }

    /** Everything this ledger knoweth vanisheth with the process. */
    fun clear() = synchronized(lock) {
        offers.clear()
        dropped = 0
    }

    companion object {
        /** The bound: telemetry only, so drop-oldest is honest and sufficient. */
        const val MAX_OFFERS: Int = 512
    }
}

/**
 * T43 law 4 -- the LEGACY label migration.
 *
 * Before T43 a Boolean send advanced the durable row to HANDED_TO_RELAY, which
 * only ever proved a local ATT admission. Those rows are migrated CONSERVATIVELY
 * back to QUEUED_DURABLY (retryable), and the fact of the legacy label is
 * preserved rather than erased. The migration is a data step the T31 engine
 * runneth inside its own transaction; this object owneth the step and the
 * honest read of a row that has not been migrated yet.
 */
object LegacyHandedLabels {
    /** The persisted code of the legacy label (DeliveryState.HANDED_TO_RELAY). */
    const val LEGACY_CODE: Int = 2

    /** The persisted code every legacy row migrateth TO (QUEUED_DURABLY). */
    const val MIGRATED_CODE: Int = 1

    /** The revision this migration belongeth to (the T31 engine's `to`). */
    const val TO_REVISION: Int = 2

    /** The statements the engine executeth: one guarded rewrite, nothing deleted. */
    fun statements(table: String = "delivery_state", column: String = "state"): List<String> = listOf(
        "UPDATE $table SET $column = $MIGRATED_CODE WHERE $column = $LEGACY_CODE",
    )

    /**
     * The T31 step itself: the apply re-writeth every legacy row THROUGH the
     * injected executor, so the whole step stayeth transactional and a crash
     * leaveth the store at the prior revision.
     */
    fun step(
        table: String = "delivery_state",
        column: String = "state",
        history: MutableList<Int>? = null,
    ): MigrationStep {
        val sql = statements(table, column)
        val declared = MigrationStep(from = 1, to = TO_REVISION, statements = sql, apply = null)
        return MigrationStep(
            from = 1,
            to = TO_REVISION,
            statements = sql,
            apply = { executor ->
                executor.execute(declared, sql)
                history?.add(LEGACY_CODE)
            },
        )
    }

    /**
     * How a row that still carrieth the legacy code must be READ, before any
     * migration: as a queued, retryable estate. Never as custody.
     */
    fun projectionForLegacyRow(msgId: ByteArray, code: Int): DeliveryProjection {
        val state = DeliveryState.fromPersistedCode(code) ?: return DeliveryProjection.unavailable(msgId)
        return DeliveryProjection.of(msgId, state)
    }

    /** True iff this persisted code is the legacy label the migration rewriteth. */
    fun isLegacy(code: Int): Boolean = code == LEGACY_CODE
}
