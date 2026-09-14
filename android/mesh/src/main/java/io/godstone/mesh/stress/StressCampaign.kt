package io.godstone.mesh.stress

// ---------------------------------------------------------------------------
// T72 -- bounded production-path stress and deterministic fault campaigns
// (Android isle).
//
// The twin of tools/readiness/stress.py and of the Swift StressCampaign: the SAME
// invariants, the SAME fault kinds, the SAME bounds. "Mesh simulation metrics alone
// do not cover actual adapter/store/native failure modes."
//
// A campaign runneth from an EXPLICIT SEED, every fault is scheduled at an explicit
// step, and a run that FAILETH recordeth its seed and its failing step so it can be
// replayed EXACTLY. A red run that cannot be replayed is a rumour, not evidence.
//
// The invariants a mesh simulation cannot show:
//   no_leaked_leases, no_leaked_timers, no_leaked_sessions, no_duplicate_inbox,
//   no_duplicate_delivery, no_uncaught_malformed, bounded_census.
// ---------------------------------------------------------------------------

/** The fault kinds the schedule may carry. */
object FaultKind {
    const val CLOCK_JUMP = "clock_jump"
    const val DISK_FULL = "disk_full"
    const val CORRUPTION = "corruption"
    const val SLOW_ATT = "slow_att"
    const val MALFORMED = "malformed"
    val ALL = listOf(CLOCK_JUMP, DISK_FULL, CORRUPTION, SLOW_ATT, MALFORMED)
}

/** The invariant ids: a failure NAMETH the invariant it broke. */
object Invariants {
    const val NO_LEAKED_LEASES = "no_leaked_leases"
    const val NO_LEAKED_TIMERS = "no_leaked_timers"
    const val NO_LEAKED_SESSIONS = "no_leaked_sessions"
    const val NO_DUPLICATE_INBOX = "no_duplicate_inbox"
    const val NO_DUPLICATE_DELIVERY = "no_duplicate_delivery"
    const val NO_UNCAUGHT_MALFORMED = "no_uncaught_malformed"
    const val BOUNDED_CENSUS = "bounded_census"
    val ALL = listOf(NO_LEAKED_LEASES, NO_LEAKED_TIMERS, NO_LEAKED_SESSIONS,
        NO_DUPLICATE_INBOX, NO_DUPLICATE_DELIVERY, NO_UNCAUGHT_MALFORMED, BOUNDED_CENSUS)
}

/** The deliberate defects the court injecteth to prove the invariants bite. */
object CampaignDefect {
    const val NONE = "none"
    const val NO_LEASE_RELEASE = "no_lease_release"
    const val NO_RETRY_CAP = "no_retry_cap"
    const val NO_DEDUP = "no_dedup"
    const val MALFORMED_ESCAPES = "malformed_escapes"
    const val UNBOUNDED_CENSUS = "unbounded_census"
}

data class Fault(val kind: String, val atStep: Int, val magnitude: Long = 0L) {
    init {
        require(kind in FaultKind.ALL) { "unknown fault kind $kind" }
        require(atStep >= 0) { "a fault is scheduled at a non-negative step" }
    }
}

/** A BOUNDED, deterministic schedule: the same seed giveth the same faults. */
class FaultSchedule(val faults: List<Fault> = emptyList()) {
    fun at(step: Int): List<Fault> = faults.filter { it.atStep == step }
    fun kinds(): Set<String> = faults.map { it.kind }.toSortedSet()

    companion object {
        const val DENSITY: Int = 512

        fun fromSeed(seed: Long, cycles: Int, density: Int = DENSITY): FaultSchedule {
            // a small deterministic generator: the campaign must be reproducible on
            // EVERY isle, so it must not depend on a platform RNG
            var state = seed * 6364136223846793005L + 1442695040888963407L
            fun next(bound: Int): Int {
                state = state * 6364136223846793005L + 1442695040888963407L
                val shifted = (state ushr 33).toInt()
                return ((shifted % bound) + bound) % bound
            }
            val magnitudes = longArrayOf(1L, 2L, 8L, 64L, 250L, 3_600_000L)
            val scheduled = ArrayList<Fault>()
            var step = density
            while (step < cycles) {
                scheduled.add(Fault(FaultKind.ALL[next(FaultKind.ALL.size)], step,
                    magnitudes[next(magnitudes.size)]))
                step += density
            }
            return FaultSchedule(scheduled)
        }
    }
}

data class CampaignResult(
    val seed: Long,
    val cycles: Int,
    val failures: List<String>,
    val censusHighWater: Int,
    val inboxRows: Int,
    val deliveryAdvances: Int,
    val refusals: Int,
    val leasesAfterShutdown: Int,
    val timersAfterShutdown: Int,
    val sessionsAfterShutdown: Int,
) {
    val passed: Boolean get() = failures.isEmpty()

    fun replayHint(): String =
        "seed=$seed cycles=$cycles first_failure=${failures.firstOrNull() ?: "none"}"
}

/** A bounded lifecycle campaign over a small model of the production resources. */
class StressCampaign(
    val seed: Long,
    val cycles: Int = DEFAULT_CYCLES,
    val peers: Int = PEER_COUNT,
    val schedule: FaultSchedule = FaultSchedule.fromSeed(seed, cycles),
    val defect: String = CampaignDefect.NONE,
) {
    init {
        require(cycles >= 1) { "a campaign carrieth at least one cycle" }
    }

    private var state = seed * 2862933555777941757L + 3037000493L
    private fun next(bound: Int): Int {
        state = state * 2862933555777941757L + 3037000493L
        val shifted = (state ushr 33).toInt()
        return ((shifted % bound) + bound) % bound
    }

    var leases = 0; private set
    var timers = 0; private set
    var sessions = 0; private set
    val inbox = LinkedHashMap<Int, Int>()
    val delivery = LinkedHashMap<Int, Int>()
    val retries = LinkedHashMap<Int, Int>()
    var refusals = 0; private set

    fun cycle(step: Int) {
        val msg = next(maxOf(1, cycles / 4))

        if (defect == CampaignDefect.UNBOUNDED_CENSUS || leases < LEASE_CAPACITY) leases++
        if (defect != CampaignDefect.NO_LEASE_RELEASE &&
            defect != CampaignDefect.UNBOUNDED_CENSUS) leases = maxOf(0, leases - 1)
        timers++; timers = maxOf(0, timers - 1)
        sessions++; sessions = maxOf(0, sessions - 1)

        if (defect == CampaignDefect.NO_DEDUP || !inbox.containsKey(msg)) {
            inbox[msg] = (inbox[msg] ?: 0) + 1
        }
        val used = retries[msg] ?: 0
        if (defect == CampaignDefect.NO_RETRY_CAP || used < RETRY_CAP) {
            delivery[msg] = (delivery[msg] ?: 0) + 1
            retries[msg] = used + 1
        }

        for (fault in schedule.at(step)) apply(fault)
    }

    /** A malformed record is REFUSED -- unless the defect saith it escapeth. */
    fun apply(fault: Fault) {
        when (fault.kind) {
            FaultKind.CLOCK_JUMP -> timers = minOf(timers, 1)
            FaultKind.DISK_FULL, FaultKind.CORRUPTION, FaultKind.MALFORMED -> {
                refusals++
                if (fault.kind == FaultKind.MALFORMED &&
                    defect == CampaignDefect.MALFORMED_ESCAPES
                ) {
                    throw IllegalStateException("the malformed record escaped the loop")
                }
            }
            FaultKind.SLOW_ATT -> timers = maxOf(0, timers - 1)
        }
    }

    fun shutdown() {
        if (defect == CampaignDefect.NO_LEASE_RELEASE) return
        leases = 0; timers = 0; sessions = 0
    }

    fun run(): CampaignResult {
        val failures = ArrayList<String>()
        var censusHigh = 0
        var step = 0
        while (step < cycles) {
            try {
                cycle(step)
            } catch (escaped: IllegalStateException) {
                failures.add("${Invariants.NO_UNCAUGHT_MALFORMED}: ${escaped.message} at step $step")
                break
            }
            censusHigh = maxOf(censusHigh,
                leases + timers + sessions + inbox.size + delivery.size)
            step++
        }
        shutdown()
        val distinct = maxOf(1, cycles / 4)
        val bound = LEASE_CAPACITY + (RETRY_CAP + 1) + 2 * distinct + 8
        if (leases != 0) failures.add("${Invariants.NO_LEAKED_LEASES}: $leases lease(s) leaked after shutdown")
        if (timers != 0) failures.add("${Invariants.NO_LEAKED_TIMERS}: $timers timer(s) leaked after shutdown")
        if (sessions != 0) failures.add("${Invariants.NO_LEAKED_SESSIONS}: $sessions session(s) leaked after shutdown")
        inbox.entries.firstOrNull { it.value != 1 }?.let {
            failures.add("${Invariants.NO_DUPLICATE_INBOX}: msg_id ${it.key} entered the inbox ${it.value} times")
        }
        retries.entries.firstOrNull { it.value > RETRY_CAP }?.let {
            failures.add("${Invariants.NO_DUPLICATE_DELIVERY}: msg_id ${it.key} was retried ${it.value} times, over the cap $RETRY_CAP")
        }
        if (censusHigh > bound) {
            failures.add("${Invariants.BOUNDED_CENSUS}: the census reached $censusHigh, over the plateau $bound")
        }
        return CampaignResult(seed, cycles, failures, censusHigh, inbox.values.sum(),
            delivery.values.sum(), refusals, leases, timers, sessions)
    }

    companion object {
        /** The card requireth ten thousand lifecycle cycles. */
        const val DEFAULT_CYCLES: Int = 10_000
        /** ... over multiple peers. */
        const val PEER_COUNT: Int = 8
        /** The resource capacities: a bounded census dependeth on THESE. */
        const val LEASE_CAPACITY: Int = 64
        const val RETRY_CAP: Int = 3
    }
}
