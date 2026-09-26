package io.godstone.mesh.di

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * *** GS-FINAL-003 `zero-private-opens`: THE CONSTRUCTION COUNTERS, PLACED AT THE REAL SEAMS. ***
 *
 * *THE OBLIGATION'S OWN WORDS, AND EVERY CLAUSE IS LOAD-BEARING: **"pending / retryable / corrupt recovery causes ZERO
 * identity and ZERO private DB opens, PROVEN AT THE REAL CONSTRUCTION SEAMS WITH COUNTERS."***
 *
 * *** THE STATE BEFORE THIS FILE EXISTED, MEASURED RATHER THAN ARGUED. *** *The isle had DECISION-LEVEL arms and a
 * PERMIT-level roster -- `GsFinal003StartupDecisionTest` proveth the typed decision is right on every rung, and
 * `GsFinal003ZeroPrivateOpensTest` proveth no permit is issued for a refusing one.* **BOTH ARE NECESSARY AND NEITHER IS
 * THE CLAUSE.** *The clause asketh for a count AT THE CONSTRUCTION SEAMS: a correct decision that nothing consulteth,
 * or a permit that a provider taketh and then ignoreth, satisfies every permit-level arm while constructing the estate
 * a later resume is going to erase. That is precisely the defect class this finding is about, one level down.*
 *
 * **SO THIS COUNTER IS DELIBERATELY NOT A DAGGER KEY.** *A rebound counter is a FAKENABLE counter: a graph could bind a
 * no-op implementation and every arm would read zero. It is a plain `object`, so the three providers that construct
 * private state call the SAME counter the court reads -- and there is no binding through which a substitute could be
 * introduced.*
 *
 * *** AND THE COUNT IS TAKEN **BEFORE** THE PLATFORM CONSTRUCTOR, WHICH IS THE WHOLE POINT ON A HOST. *** *`Identity`,
 * `SqliteMessageStore` and `SqlcipherPeerIdentityStore` all reach device-only facilities (the AndroidKeyStore, the
 * SQLCipher native library), so on a JVM host the platform throws.* **THE THROW IS EVIDENCE AND NOT AN OBSTACLE: the
 * counter incremented BEFORE the throw, so a host run proves the body WALKED TO the platform -- and the count proves
 * the ATTEMPT.** *A counter taken after the constructor would read zero on every host run and measure nothing.*
 */
object PrivateConstructionCounter {

    /**
     * *** THE THREE PRIVATE-STATE SEAMS THE OBLIGATION NAMES. ***
     *
     * *An identity and two private databases -- exactly the three providers that REQUIRE a `PrivateStorePermit`, and
     * therefore exactly the three the clause's "ZERO identity and ZERO private DB opens" speaks of.* **A seam added to
     * this enum without a `noteAttempt` call site would be visible as a permanently-zero row, which is why the court
     * asserts each one moves on the permitted road.**
     */
    enum class Seam {
        /** `Identity.loadOrCreate(ctx)` -- the private cryptographic identity. */
        IDENTITY,

        /** `SqliteMessageStore(ctx, ...)` -- the private message database. */
        MESSAGE_STORE,

        /** `SqlcipherPeerIdentityStore(ctx)` -- the private peer-identity database. */
        PEER_STORE,
    }

    private class Rec {
        val count = AtomicLong(0)

        /** *Written BEFORE the increment, so a reader that sees a count never sees a stale authority.* */
        @Volatile
        var lastDecision: StartupWipeDecision? = null
    }

    private val records = ConcurrentHashMap<Seam, Rec>()

    private fun rec(seam: Seam): Rec = records.computeIfAbsent(seam) { Rec() }

    /**
     * *** ONE ATTEMPT TO CONSTRUCT PRIVATE STATE, RECORDED AT THE SEAM. ***
     *
     * *`internal` because it is the composition's own instrument: a caller outside this module cannot move the count,
     * so a court elsewhere cannot accidentally satisfy an arm by construction.* **THE DECISION IS SET BEFORE THE COUNT
     * IS INCREMENTED** -- so a concurrent reader can never observe an increment without the authority that authorised
     * it, which matters because this runs in a process that may be draining a wipe on another thread.
     */
    internal fun noteAttempt(seam: Seam, authorizedBy: StartupWipeDecision) {
        val r = rec(seam)
        r.lastDecision = authorizedBy
        r.count.incrementAndGet()
    }

    /** The number of attempts recorded at [seam] since the last [reset]. */
    fun attempts(seam: Seam): Long = rec(seam).count.get()

    /**
     * *** THE AUTHORITY THE LAST ATTEMPT WAS MADE UNDER -- the half that makes the count falsifiable. ***
     *
     * *A count alone sayeth "something was constructed"; this sayeth WHAT AUTHORISED IT.* **An arm that reads only the
     * count could be satisfied by a construction under a REFUSING decision -- the very defect the gate exists to
     * prevent -- so the permitted-road arm asserts both the delta AND that the authority was `CLEAN_START`.**
     */
    fun lastAuthorizedBy(seam: Seam): StartupWipeDecision? = rec(seam).lastDecision

    /** Every seam's count, for a court that wants the whole census in one read. */
    fun snapshot(): Map<Seam, Long> = Seam.entries.associateWith { attempts(it) }

    /** *Test-support: a court must be able to start from zero without depending on another arm's history.* */
    internal fun reset() {
        records.clear()
    }
}
