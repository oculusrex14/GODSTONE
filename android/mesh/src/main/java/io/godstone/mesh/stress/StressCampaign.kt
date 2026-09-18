package io.godstone.mesh.stress

/**
 * GS-STRESS-001 step 1: THE CATEGORY THIS CAMPAIGN BELONGETH TO, NAMED WHERE IT LIVETH.
 *
 * `StressCampaign` MEASURES A **RESOURCE MODEL**, NOT THE PRODUCTION RUNTIME: its counters describe ITS OWN local
 * bookkeeping -- the card's step 6 sayeth so in its own words ('a mutation confined to StressCampaign's local
 * bookkeeping') -- so a result from here is evidence about THE MODEL'S INVARIANTS and never about a real device, radio or
 * store. THE AUDIT'S DISCIPLINE IS THAT SUCH A RESULT MUST NOT BE RELABELLED, AND ITS FIRST LINE IS TO NAME THE CATEGORY.
 *
 * (A TOP-LEVEL CONSTANT RATHER THAN A COMPANION MEMBER: the file carrieth SEVERAL classes, and a first attempt put this
 * in the WRONG `companion object` -- the compiler named the unresolved reference, and the placement was corrected.)
 */
const val RESOURCE_MODEL_CATEGORY: String = "resource-model"

/**
 * GS-STRESS-001 step 3: **THE OWNER CENSUS** -- the seam by which the campaign asketh a REAL owner instead of reading
 * its own model.
 *
 * The card's charge is that 'the stress campaign measures a separate resource model', and step 3 nameth the remedy in
 * its own words: 'READ RESOURCE CENSUS FROM THE OWNERS THAT ALLOCATE timers, writer reservations, SESSIONS, observers,
 * inventory leases, ACK work and database rows.'
 *
 * WHY A SEAM RATHER THAN A SECOND COUNTER: a number only the campaign can move is evidence about the campaign, and
 * **NO MUTATION OF THE CAMPAIGN'S OWN BOOKKEEPING CAN EVER FALSIFY AN INVARIANT ABOUT A RUNTIME** -- which is exactly
 * why the card's step 6 forbiddeth a mutation confined to `StressCampaign`'s local bookkeeping as the production
 * negative control. An owner answereth through **ITS OWN** evidence hook (`SessionManager.slotCountForTest()` for the
 * session half), so the number is the OWNER'S and never a copy the campaign keepeth.
 */
interface ResourceCensusSource {
    /** The owner's own name, so a failure can NAME whom it accuseth rather than saying 'sessions'. */
    val ownerName: String

    /** How many live session slots the REAL owner holdeth RIGHT NOW, read through its own evidence hook. */
    fun liveSessionSlots(): Int

    /**
     * *** GS-STRESS-001 step 3 (round 643): THE OTHER OWNERS THE CARD NAMETH BY NAME -- $RESERVATIONS$. ***
     *
     * THE CARD'S OWN REMAINING-WORK LINE SAYETH: *"THE OTHER OWNERS THE CARD NAMETH ARE UNREAD ON BOTH ISLES --
     * timers, observers, inventory leases, ACK work, database rows."* **`liveSessionSlots` COULD ONLY EVER ASK ONE OF
     * THEM**, so the seam's NAME promised a census it could not take. **A SEAM WHOSE ONLY VERB COVERS ONE OWNER IS A
     * SEAM THAT SILENTLY LIMITS EVERY FUTURE CALLER TO THAT OWNER** -- the same shape as a gate carried but not
     * consulted, one layer out.
     *
     * `liveReservations` ASKETH THE SECOND OWNER THE PROJECT ALREADY MADE ASKABLE (`RecordWriter
     * .reservedCountForTest()`, the hook whose arm found the `failed()`-leaves-reservations-standing defect).
     *
     * **AND ITS DEFAULT IS THE HONEST ONE RATHER THAN A CONVENIENT ZERO**: an owner that carrieth no reservations
     * answereth `NOT_MEASURED`, **NOT 0** -- because *"nothing is leaking"* and *"nobody asked my kind of owner"* are
     * DIFFERENT ANSWERS, and collapsing them would make this seam into the very thing it was built to replace: **a
     * number that agrees with itself.** A caller that cannot measure an owner excludes it BY NAME rather than by
     * silence.
     */
    fun liveReservations(): Int = NOT_MEASURED

    /**
     * *** GS-STRESS-001 step 3 (round 651): THE THIRD OWNER -- `ADMITTED`, WHICH IS ONE OF THE CARD'S OWN
     * "INVENTORY LEASES". ***
     *
     * The card nameth its owners: *"timers, writer reservations, sessions, observers, **inventory leases**, ACK work and
     * database rows."* **`RecordWriter.admittedCountForTest()` IS THE INVENTORY-LEASE HOOK** and it already existeth --
     * *added for the same reason `reservedCountForTest()` was: an owner that allocateth must be askable what it
     * holdeth.* **SO THIS IS THE THIRD OWNER MADE ASKABLE, AND THE THIRD KIND THIS SEAM CAN CENSUS.**
     *
     * *AND IT IS ADDED BECAUSE THE SEAM NOW MAKETH THE DISTINCTION POSSIBLE: before round 643 an owner had ONE verb and
     * an unmeasurable owner was indistinguishable from a clean one.*
     */
    fun liveAdmittedLeases(): Int = NOT_MEASURED

    /**
     * *** GS-STRESS-001 step 3 (round 653): THE FOURTH OWNER -- `TIMERS`, WHICH THE CARD NAMETH FIRST. ***
     *
     * `SessionManager.armedAgeDeadlinesForTest()` IS THE TIMER HOOK AND IT ALREADY EXISTED -- *it is the hook round 534's
     * sibling used when it found that `failed()` left reservations standing.* **AND A TIMER IS THE OWNER MOST LIKELY TO
     * OUTLIVE A SHUTDOWN SILENTLY**, because nothing else observeth it: a leaked session slot is countable from the
     * session map, but an ARMED DEADLINE that nobody fired leaveth no other trace.
     */
    fun liveArmedTimers(): Int = NOT_MEASURED

    /**
     * *** AND THE FIFTH -- `OBSERVERS`, ALSO THE CARD'S OWN WORD. ***
     *
     * `LinkInfoSnapshotAuthority.registrationsForTest()` IS THE OBSERVER HOOK AND IT ALREADY EXISTED. **AN OBSERVER
     * WHOSE REGISTRATION OUTLIVETH ITS OWNER IS A CALLBACK INTO A DEAD OBJECT** -- *which is the failure mode this
     * programme's earlier rounds named as "stale callbacks".*
     */
    fun liveObservers(): Int = NOT_MEASURED

    companion object {
        /** The sentinel for an owner whose kind this seam cannot yet census. NEVER counted as zero. */
        const val NOT_MEASURED: Int = -1
    }
}

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
    /**
     * *** GS-STRESS-001 step 3 (round 643): THE OWNERS THIS CENSUS COULD NOT MEASURE, NAMED. ***
     *
     * *"Nothing is leaking"* and *"nobody asked my kind of owner"* are DIFFERENT ANSWERS. **A RESULT THAT SILENTLY
     * TREATED AN UNMEASURABLE OWNER AS CLEAN WOULD BE THE SELF-AGREEING NUMBER THIS SEAM EXISTETH TO REPLACE** -- so
     * the unmeasured owners are CARRIED IN THE RESULT rather than dropped, and a reader can see the difference between
     * a census that found nothing and one that could not look.
     */
    val unmeasuredOwners: List<String> = emptyList(),
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
    /**
     * GS-STRESS-001 step 3: THE REAL OWNERS THIS CAMPAIGN SHALL ASK.
     *
     * EMPTY BY DEFAULT, so nothing that stood before this finding changeth behaviour -- the campaign remaineth the
     * resource model it was and its own counters are untouched. WHERE AN OWNER IS GIVEN, the session invariant is
     * asked OF THAT OWNER, through the owner's own evidence hook, AND THE FAILURE NAMETH IT.
     */
    val owners: List<ResourceCensusSource> = emptyList(),
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

        // A SHUTDOWN ARRIVETH WITH WORK IN FLIGHT: the final cycle leaveth its
        // resources HELD, so "shutdown releaseth everything" is a real law
        val inFlight = step >= cycles - 1

        if (defect == CampaignDefect.UNBOUNDED_CENSUS || leases < LEASE_CAPACITY) leases++
        if (!inFlight && defect != CampaignDefect.NO_LEASE_RELEASE &&
            defect != CampaignDefect.UNBOUNDED_CENSUS) leases = maxOf(0, leases - 1)
        timers++
        if (!inFlight) timers = maxOf(0, timers - 1)
        sessions++
        if (!inFlight) sessions = maxOf(0, sessions - 1)

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
        val unmeasuredOwners = ArrayList<String>()
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
        // *** GS-STRESS-001 step 3: AND THE INVARIANT IS ASKED OF THE REAL OWNERS. The clause above readeth the
        // MODEL'S OWN integer, which only this campaign can move -- so it cannot be falsified by a real leak, and a
        // model that agreeth with itself is not evidence about a runtime. THE NUMBERS BELOW ARE THE OWNERS' OWN, read
        // through the owners' evidence hooks, and a failure NAMETH the owner it accuseth.
        // IT IS ASKED AFTER `shutdown()` (above), because the question is whether the owner RETAINED anything -- the
        // very question the model's clause asketh of itself, now askable of something that actually allocateth. ***
        for (owner in owners) {
            val live = owner.liveSessionSlots()
            if (live != 0) {
                failures.add("${Invariants.NO_LEAKED_SESSIONS}: $live session slot(s) still live in the REAL owner " +
                    "'${owner.ownerName}' after shutdown")
            }
            // *** GS-STRESS-001 step 3 (round 643): THE SAME INVARIANT, ASKED OF THE OTHER OWNER THE PROJECT MADE
            // ASKABLE. *** One owner census is not a resource model; **THIS IS THE SECOND, AND IT IS THE CARD'S OWN
            // NAMED OWNER (`reservations`).** AN OWNER THAT CANNOT BE MEASURED IS **NAMED IN THE RESULT, NOT SILENTLY
            // TREATED AS CLEAN** -- *"nothing is leaking"* and *"nobody asked my kind of owner"* are different answers,
            // and a census that collapsed them would be the self-agreeing number this seam existeth to replace.
            val reservations = owner.liveReservations()
            when {
                reservations == ResourceCensusSource.NOT_MEASURED -> unmeasuredOwners.add(
                    "${owner.ownerName} (reservations)")
                reservations != 0 -> failures.add(
                    "${Invariants.NO_LEAKED_SESSIONS}: $reservations writer reservation(s) still live in the REAL " +
                        "owner '${owner.ownerName}' after shutdown")
            }
            // THE THIRD OWNER: THE INVENTORY LEASES THE CARD NAMETH -- `admitted`, whose hook already existeth.
            val admittedLeases = owner.liveAdmittedLeases()
            when {
                admittedLeases == ResourceCensusSource.NOT_MEASURED -> unmeasuredOwners.add(
                    "${owner.ownerName} (admitted leases)")
                admittedLeases != 0 -> failures.add(
                    "${Invariants.NO_LEAKED_SESSIONS}: $admittedLeases admitted lease(s) still live in the REAL " +
                        "owner '${owner.ownerName}' after shutdown")
            }
            // THE FOURTH OWNER: TIMERS -- an armed deadline that nobody fired leaves NO OTHER TRACE.
            val armedTimers = owner.liveArmedTimers()
            when {
                armedTimers == ResourceCensusSource.NOT_MEASURED -> unmeasuredOwners.add(
                    "${owner.ownerName} (timers)")
                armedTimers != 0 -> failures.add(
                    "${Invariants.NO_LEAKED_TIMERS}: $armedTimers armed timer(s) still live in the REAL owner " +
                        "'${owner.ownerName}' after shutdown")
            }
            // THE FIFTH OWNER: OBSERVERS -- a registration that outlives its owner is a callback into a dead object.
            val observers = owner.liveObservers()
            when {
                observers == ResourceCensusSource.NOT_MEASURED -> unmeasuredOwners.add(
                    "${owner.ownerName} (observers)")
                observers != 0 -> failures.add(
                    "${Invariants.NO_LEAKED_LEASES}: $observers observer registration(s) still live in the REAL " +
                        "owner '${owner.ownerName}' after shutdown")
            }
        }
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
            delivery.values.sum(), refusals, leases, timers, sessions, unmeasuredOwners)
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
