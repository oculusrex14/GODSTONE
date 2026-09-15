package io.godstone.mesh.transport

import java.util.concurrent.atomic.AtomicLong

/**
 * ANDROID-07 / T26 -- THE PRE-AUTH ADMISSION BUDGET.
 *
 * The audited road chargeth its budget in the ROUTER: after reassembly, after the claim of an
 * identity, and only for traffic that survived parsing. So RAW, malformed, unknown-type, over-sized
 * and no-connection traffic is charged NOTHING, and a flood of it is free -- the card's own words:
 * "budgets are still after expensive decoding ... and miss raw traffic".
 *
 * This budget is charged AT THE TRANSPORT INGRESS DOOR, BEFORE parsing, reassembly or crypto:
 *  - [charge] taketh the relation's address (the only identity that existeth before authentication)
 *    and the octet count of the value ARRIVING, and it chargeth whatever arriveth -- an empty value,
 *    a malformed one, an unknown type, an over-sized one;
 *  - the clock is MONOTONIC and injected ([nowMillis]); the audited governor defaulted to a WALL clock,
 *    which a rollback can refund;
 *  - the registry is BOUNDED ([maxTrackedRelations] -- the specified 256): a relation beyond the bound
 *    is REFUSED deterministically rather than silently tracked, so a Sybil flood can never grow it;
 *  - a relation that stayeth under its own allowance is ADMITTED, so fair traffic is untouched.
 *
 * WHAT THIS IS NOT: not a device, radio or emulator result, and not a replacement for the ROUTER's
 * authenticated governor -- that one chargeth the authenticated identity AFTER AEAD, which is its own
 * step of this card and landeth separately.
 */
class AdmissionBudget(
    private val nowMillis: () -> Long,
    private val maxTrackedRelations: Int = DEFAULT_MAX_TRACKED_RELATIONS,
    private val recordsPerRelation: Int = DEFAULT_RECORDS_PER_RELATION,
    private val bytesPerRelation: Long = DEFAULT_BYTES_PER_RELATION,
) {
    enum class Verdict { ADMITTED, REFUSED }

    private class Window(var records: Int, var bytes: Long, var sinceMillis: Long)

    private val windows = HashMap<String, Window>()
    private val refused = AtomicLong(0L)
    private val admittedValues = AtomicLong(0L)

    /** Charge ONE arriving value against its relation's pre-auth allowance. */
    fun charge(relation: String, bytes: Int): Verdict {
        val now = nowMillis()
        synchronized(windows) {
            val existing = windows[relation]
            if (existing == null && windows.size >= maxTrackedRelations) {
                // THE BOUND IS THE DEFENCE: an unknown relation beyond it is refused deterministically,
                // never admitted so that the registry may grow for a flood's sake.
                refused.incrementAndGet()
                return Verdict.REFUSED
            }
            val w = existing ?: Window(0, 0L, now).also { windows[relation] = it }
            if (now < w.sinceMillis) {
                // a BACKWARD step (a rolled-back clock, or an injected one) refundeth nothing: the
                // window is restarted at the observed instant and the spend standeth.
                w.sinceMillis = now
            } else if (now - w.sinceMillis >= WINDOW_MILLIS) {
                w.sinceMillis = now
                w.records = 0
                w.bytes = 0L
            }
            val charge = if (bytes < 0) 0 else bytes
            if (w.records + 1 > recordsPerRelation || w.bytes + charge > bytesPerRelation) {
                refused.incrementAndGet()
                return Verdict.REFUSED
            }
            w.records += 1
            w.bytes += charge
            admittedValues.incrementAndGet()
            return Verdict.ADMITTED
        }
    }

    /**
     * ANDROID-07 / T26 STEP 2: THE AUTHENTICATED SCOPE. Charged AFTER AEAD, keyed on the identity the
     * trusted handshake BOUND to the relation -- never on a MAC, a hint or a claimed SOS priority,
     * which all arrive BEFORE authentication and may not choose a bucket or a key. Its key space is
     * PREFIXED so that an authenticated identity can never collide with a pre-auth address.
     *
     * The transport keepeth a SECOND instance for this scope, so each instance's counters report one
     * scope cleanly rather than two mixed together.
     */
    fun chargeAuthenticated(authenticatedId: ByteArray, bytes: Int): Verdict =
        charge(AUTHENTICATED_PREFIX + authenticatedId.joinToString("") { "%02x".format(it) }, bytes)

    /** Observation for courts and counters: how many values the budget admitted. */
    fun admittedCount(): Long = admittedValues.get()

    /** Observation for courts and counters: how many values the budget refused. */
    fun refusedCount(): Long = refused.get()

    /** Observation for courts and counters: how many relations the bounded registry holdeth. */
    fun trackedRelations(): Int = synchronized(windows) { windows.size }

    companion object {
        /** The card's specified bound: 256 tracked relations, never more. */
        const val DEFAULT_MAX_TRACKED_RELATIONS = 256
        // THE ALLOWANCE MUST NOT REFUSE FAIR TRAFFIC: the courts drive a sixty-four-fragment whole
        // record (T18) and a two-hundred-fifty-seven-record sequence wrap (T20) through ONE relation,
        // and both are legitimate. The bound is therefore generous enough for whole-record work and
        // still finite, which is what maketh a flood bounded.
        const val DEFAULT_RECORDS_PER_RELATION = 2048
        const val DEFAULT_BYTES_PER_RELATION = 1024L * 1024L
        const val WINDOW_MILLIS = 1_000L
        /** The authenticated scope key prefix: it may never collide with a pre-auth address. */
        const val AUTHENTICATED_PREFIX = "authenticated:"
    }
}
