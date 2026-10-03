#!/usr/bin/env python3
"""Bounded RESOURCE-MODEL stress and deterministic fault campaigns (T72) -- NOT a production-runtime driver.

CATEGORY: `resource-model`. Every number this conductor readeth is ITS OWN local bookkeeping (leases, timers,
sessions, row maps), so a result from here is evidence about THE MODEL'S INVARIANTS and NEVER about a real device,
radio or store. *** AND THE CATEGORY IS CARRIED WHERE A RESULT IS READ RATHER THAN MERELY DECLARED: see
`Category`, `CampaignResult.category`, `CampaignResult.resource_model_category` and `campaign_report` -- a name that
is only asserted against itself, and carried nowhere a reader meeteth a result, is a name that will be missed. ***
The PRODUCTION-RUNTIME campaigns are SEPARATE artefacts, named in `docs/production/VERIFICATION_MATRIX.md`: the iOS
real-runtime driver over the GS-INTEGRATION-001 composition (`GsStress001RealRuntimeDriverTests.swift`, the 10k and
30k cycle arms) and the Android/Swift real-owner census arms. THOSE numbers are read from the OWNERS' own evidence
hooks; the numbers in this file cannot be quoted as their evidence.

"Mesh simulation metrics alone do not cover actual adapter/store/native failure modes."

This module is a CONDUCTOR, and it is deliberately deterministic: every campaign
runneth from an EXPLICIT SEED, every fault is scheduled at an explicit step, and a
run that FAILETH recordeth its seed and its failing step so it can be replayed
EXACTLY. A red run that cannot be replayed is a rumour, not evidence.

THE INVARIANTS THIS CONDUCTOR **MEASURES** -- seven of the eleven names it carrieth. `Invariant.MEASURED` and
`Invariant.UNMEASURED` carry the split, and the court asserteth the split is EXACT rather than trusting this prose:

  I1  ZERO LEAKED LEASES  -- after shutdown, every lease is released;
  I2  ZERO LEAKED TIMERS  -- after shutdown, no timer is armed;
  I3  ZERO LEAKED SESSIONS -- after shutdown, no trusted session standeth;
  I4  NO DUPLICATE INBOX  -- one msg_id entereth the inbox ONCE, however many times
                             the record is delivered or replayed;
  I5  NO DUPLICATE DELIVERY -- the retry cap boundeth the retries;
  I6  NO UNCAUGHT MALFORMED INPUT -- a malformed record is REFUSED and COUNTED; it
                             never throweth out of the loop;
  I7  A BOUNDED CENSUS -- the LIVE resources (leases + timers + sessions) plateau
                             under their capacities, and the row maps under the
                             distinct msg-id space. THE BOUND IS A FORMULA OF THE
                             CYCLE COUNT and sayeth so: it is the model's OWN
                             reachable maximum, not a measured run of the store.

*** NOT MEASURED ON THIS ISLE, AND NAMED AS SUCH RATHER THAN SILENTLY PASSED: the four OWNER-KIND invariants the
ledger and the mobile isles carry -- `no_leaked_reservations`, `no_leaked_inventory_leases`, `pending_ack_work`,
`no_leaked_observers`. THIS ISLE CARRIETH NO REAL-OWNER SEAM (the Android and Swift isles do; they have real owners
to ask), so nothing here can emit them. A healthy run's failure list is therefore EMPTY rather than "clean" on those
four, `CampaignResult.unmeasured_invariants` carrieth them by name, and the court asserteth that they are in
`Invariant.ALL` but NOT in `Invariant.MEASURED` -- the old court looped over all eleven and called four
never-emittable names "clean", which is the vacuity this split removeth. ***

THE NAMED NEGATIVE: disabling ONE capacity release or ONE retry cap must break an
invariant. The conductor therefore carrieth explicit `defects`, and the court
asserteth that each defect is CAUGHT -- INCLUDING ONE PER LIFECYCLE OWNER, so the
timer and session clauses are no longer reddened only by a defect named for leases.
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field

__all__ = [
    "FaultKind", "Fault", "FaultSchedule", "CampaignDefect", "StressCampaign",
    "CampaignResult", "Invariant", "DEFAULT_CYCLES", "PEER_COUNT",
    "LEASE_CAPACITY", "RETRY_CAP", "CONDUCTOR_FAULTS", "CONDUCTOR_SCHEDULE",
    "run_campaign", "campaign_report",
    "RESOURCE_MODEL_CATEGORY", "Category", "UNMEASURED_OWNER_KINDS",
    "FAULT_CAMPAIGN_INACTIVE", "DEFECT_TO_INVARIANT", "ALL_FAULTS",
]

# ---------------------------------------------------------------------------
# GS-STRESS-001 step 1: THE CATEGORY THIS CONDUCTOR BELONGETH TO, NAMED WHERE IT LIVETH.
#
# This conductor MEASURES A **RESOURCE MODEL**, NOT THE PRODUCTION RUNTIME: its counters describe ITS OWN local
# bookkeeping -- the card's step 6 sayeth so in its own words ('a mutation confined to StressCampaign's local
# bookkeeping') -- so a result from here is evidence about THE MODEL'S INVARIANTS and never about a real device,
# radio or store. THE AUDIT'S DISCIPLINE IS THAT SUCH A RESULT MUST NOT BE RELABELLED, AND ITS FIRST LINE IS TO NAME
# THE CATEGORY WHERE IT LIVETH.
#
# *** THIS IS STEP 1 ON THE **THIRD** ISLE. MEASURED at round 521: the Android isle named this category at
# `StressCampaign.kt:14` and the string appeared NOWHERE ELSE IN THE REPOSITORY. A CATEGORY THAT HOLDETH ON ONE ISLE
# IS NOT A CATEGORY; the human's phase-two law requireth the shared contract on EVERY isle that carrieth the twin.
#
# THE NAME IS DELIBERATELY THE SAME SPELLING AS ITS ANDROID AND SWIFT TWINS, SO THAT ONE GREP FOR
# `RESOURCE_MODEL_CATEGORY` FINDETH THE CONTRACT EVERYWHERE.
# ---------------------------------------------------------------------------
RESOURCE_MODEL_CATEGORY = "resource-model"


class Category:
    """*** WHERE A RESULT SAYETH WHAT IT IS, RATHER THAN LEAVING THE READER TO INFER IT. ***

    `RESOURCE_MODEL_CATEGORY` is the NAME of this conductor's category; `Category.RESOURCE_MODEL` is the VALUE a
    RESULT carrieth (`CampaignResult.category`), and `PRODUCTION_RUNTIME` is the category this conductor MUST NEVER
    claim -- named here so a court can assert the refusal against a name rather than against a magic string.

    MEASURED (round 727 audit): the constant was declared on all three isles and asserted against itself in three
    courts, and it appeared in NO result field, NO report line and NO ledger row -- so a model result met a reader
    with no name on it at all. A CATEGORY IS HONOURED WHERE THE RESULT IS READ, and this class is where the result
    is told which one it belongeth to.
    """

    RESOURCE_MODEL = RESOURCE_MODEL_CATEGORY
    PRODUCTION_RUNTIME = "production-runtime"


#: The owners the RESULT carrieth when nobody could be asked: the four owner-kind invariants this isle's model
#: cannot emit. A NAME rather than an empty tuple, because "nobody asked my kind of owner" and "nothing is leaking"
#: are different answers (the Android isle's `ResourceCensusSource.NOT_MEASURED` says the same in its own words).
UNMEASURED_OWNER_KINDS = (
    "writer reservations",
    "admitted inventory leases",
    "pending ACK obligations",
    "observer registrations",
)


#: *** A HARNESS-INTEGRITY TOKEN, NOT ONE OF THE ELEVEN NAMED INVARIANTS. *** *The fault-liveness clause reporteth
#: that the SCHEDULE did not fire -- a property of the harness, not of the runtime owner -- so it carrieth its own
#: name rather than masquerading as `no_uncaught_malformed` (nothing was malformed; the schedule was deaf).*
FAULT_CAMPAIGN_INACTIVE = "fault_campaign_inactive"


class FaultKind:
    CLOCK_JUMP = "clock_jump"
    DISK_FULL = "disk_full"
    CORRUPTION = "corruption"
    SLOW_ATT = "slow_att"
    MALFORMED = "malformed"


ALL_FAULTS = (FaultKind.CLOCK_JUMP, FaultKind.DISK_FULL, FaultKind.CORRUPTION,
              FaultKind.SLOW_ATT, FaultKind.MALFORMED)

#: The campaign's size: the card requireth ten thousand lifecycle cycles.
DEFAULT_CYCLES = 10_000

#: Multiple peers, as the card requireth.
PEER_COUNT = 8

#: The capacities. A bounded census dependeth on these, not on the cycle count.
LEASE_CAPACITY = 64
RETRY_CAP = 3

class CampaignDefect:
    """The deliberate defects the court injecteth to prove the invariants bite."""
    NONE = "none"
    NO_LEASE_RELEASE = "no_lease_release"
    NO_RETRY_CAP = "no_retry_cap"
    NO_DEDUP = "no_dedup"
    MALFORMED_ESCAPES = "malformed_escapes"
    UNBOUNDED_CENSUS = "unbounded_census"
    # *** ONE DEFECT PER LIFECYCLE OWNER, ADDED ROUND 727. *** *MEASURED by the read-only audit: the timer and
    # session clauses had NO defect of their own -- the only defect that kept a resource standing was
    # `NO_LEASE_RELEASE` (named for leases) and it kept all three -- so `no_leaked_timers` and `no_leaked_sessions`
    # could not be reddened INDEPENDENTLY, and a mutation that stopped releasing ONE of them could escape.* A
    # lifecycle owner that cannot be leaked alone is an owner whose invariant is not really measured.
    NO_TIMER_RELEASE = "no_timer_release"
    NO_SESSION_RELEASE = "no_session_release"


@dataclass(frozen=True)
class Fault:
    kind: str
    at_step: int
    magnitude: int = 0

    def __post_init__(self):
        if self.kind not in ALL_FAULTS:
            raise ValueError("unknown fault kind %r" % self.kind)
        if self.at_step < 0:
            raise ValueError("a fault is scheduled at a non-negative step")


@dataclass(frozen=True)
class FaultSchedule:
    """A BOUNDED, deterministic schedule: the same seed giveth the same faults."""
    faults: tuple = ()

    @classmethod
    def from_seed(cls, seed: int, cycles: int, density: int = 512) -> "FaultSchedule":
        rng = random.Random(seed)
        scheduled = []
        for step in range(density, cycles, density):
            kind = rng.choice(ALL_FAULTS)
            scheduled.append(Fault(kind, at_step=step,
                                   magnitude=rng.choice((1, 2, 8, 64, 250, 3_600_000))))
        return cls(tuple(scheduled))

    def at(self, step: int) -> tuple:
        return tuple(fault for fault in self.faults if fault.at_step == step)

    def kinds(self) -> tuple:
        return tuple(sorted({fault.kind for fault in self.faults}))


#: The conductor's own fault schedule: one of every kind, at fixed steps.
CONDUCTOR_FAULTS = (
    Fault(FaultKind.CLOCK_JUMP, at_step=97, magnitude=3_600_000),
    Fault(FaultKind.DISK_FULL, at_step=241, magnitude=1),
    Fault(FaultKind.CORRUPTION, at_step=512, magnitude=1),
    Fault(FaultKind.SLOW_ATT, at_step=777, magnitude=250),
    Fault(FaultKind.MALFORMED, at_step=1024, magnitude=1),
)


class Invariant:
    """*** GS-STRESS-001 (round 727): THIS LIST WAS STALE, AND A COURT WAS ALREADY FAILING OVER IT. ***

    `ReadinessT72Test.test_w12_the_isles_carry_the_same_invariants_and_faults` ASSERTETH THAT ALL THREE ARTEFACTS -- this
    conductor, the Swift twin and the Android isle -- CARRY THE SAME INVARIANT NAMES, and it was failing on
    *"the conductor must carry no_leaked_reservations"*. **Android grew to ELEVEN names across rounds 643/651/671 while
    this conductor and the Swift twin stayed at SEVEN** -- *so the three-way contract the court enforced was already
    broken, and the court was the instrument that said so.*
    """

    NO_LEAKED_LEASES = "no_leaked_leases"
    NO_LEAKED_TIMERS = "no_leaked_timers"
    NO_LEAKED_SESSIONS = "no_leaked_sessions"
    # THE FOUR OWNERS THIS CONDUCTOR DID NOT NAME -- one per round that added them on Android:
    NO_LEAKED_RESERVATIONS = "no_leaked_reservations"          # writer reservations
    NO_LEAKED_INVENTORY_LEASES = "no_leaked_inventory_leases"  # admitted inventory leases
    PENDING_ACK_WORK = "pending_ack_work"                      # the ACK obligations the system owed
    NO_LEAKED_OBSERVERS = "no_leaked_observers"                # observer registrations, naming their OWNER
    NO_DUPLICATE_INBOX = "no_duplicate_inbox"
    NO_DUPLICATE_DELIVERY = "no_duplicate_delivery"
    NO_UNCAUGHT_MALFORMED = "no_uncaught_malformed"
    BOUNDED_CENSUS = "bounded_census"

    ALL = (NO_LEAKED_LEASES, NO_LEAKED_TIMERS, NO_LEAKED_SESSIONS,
           NO_LEAKED_RESERVATIONS, NO_LEAKED_INVENTORY_LEASES, PENDING_ACK_WORK, NO_LEAKED_OBSERVERS,
           NO_DUPLICATE_INBOX, NO_DUPLICATE_DELIVERY, NO_UNCAUGHT_MALFORMED, BOUNDED_CENSUS)

    # *** ROUND 727: WHAT THIS ISLE ACTUALLY MEASURES, AND WHAT IT MERELY NAMES. ***
    #
    # *MEASURED by the read-only audit:* `Invariant.ALL` carrieth ELEVEN names, of which THIS CONDUCTOR EMITTETH
    # SEVEN -- and the court looped over all eleven asserting that a healthy run carrieth none of their failures,
    # which for the four owner-kind names is TRUE BY CONSTRUCTION (nothing here can emit them).* **A CHECK THAT
    # CANNOT FAIL IS NOT A CHECK, and four names silently rode on seven.** The split is TYPED so a court asserteth
    # it rather than a comment claiming it, and `CampaignResult.unmeasured_invariants` CARRIETH it to the reader.
    MEASURED = (NO_LEAKED_LEASES, NO_LEAKED_TIMERS, NO_LEAKED_SESSIONS,
                NO_DUPLICATE_INBOX, NO_DUPLICATE_DELIVERY, NO_UNCAUGHT_MALFORMED, BOUNDED_CENSUS)

    #: The four OWNER-KIND names: carried for cross-isle parity, MEASURED NOWHERE HERE -- this isle hath no real
    #: owner to ask, so it must SAY SO rather than report a clean run over an owner it never consulted.
    UNMEASURED = (NO_LEAKED_RESERVATIONS, NO_LEAKED_INVENTORY_LEASES, PENDING_ACK_WORK, NO_LEAKED_OBSERVERS)

    # *** AND THE CENSUS IS ASSERTED AT IMPORT, SO THE NEXT ADDITION CANNOT QUIETLY MISS THE TUPLE. *** *The defect this
    # preventeth is IN THIS CLASS -- the name and the tuple stand lines apart, and only their COUNT can tell whether they
    # agree.* A declared count rather than a `len(dir())` scan, so the check is legible and cannot be satisfied by
    # accident.
    DEFINED_COUNT = 11


assert len(Invariant.ALL) == Invariant.DEFINED_COUNT, (
    f"Invariant.ALL carries {len(Invariant.ALL)} of the {Invariant.DEFINED_COUNT} defined invariants -- a name was "
    "added without being listed, which is how four owners went unmeasured (GS-STRESS-001, round 727)."
)
assert len(set(Invariant.ALL)) == len(Invariant.ALL), "Invariant.ALL carries a duplicate"

# *** AND THE MEASURED/UNMEASURED SPLIT IS ASSERTED AT IMPORT TOO: TOGETHER THEY MUST REPRODUCE `ALL`, AND THEIR
# INTERSECTION MUST BE EMPTY. *** *A split that overlapped would double-count a name; a split that missed one would
# let a name go unmeasured AND unnamed at once -- which is the defect this round existeth to remove.*
assert set(Invariant.MEASURED) | set(Invariant.UNMEASURED) == set(Invariant.ALL), (
    "the measured/unmeasured split must cover Invariant.ALL exactly -- a name that is in NEITHER list is a name "
    "nothing measures and nothing names (GS-STRESS-001, round 727)."
)
assert not (set(Invariant.MEASURED) & set(Invariant.UNMEASURED)), (
    "a name cannot be both measured and unmeasured on this isle"
)
assert len(set(Invariant.MEASURED)) == len(Invariant.MEASURED) == 7, (
    "MEASURED carrieth the SEVEN invariants this conductor emits; a change here must be a real emitter change"
)


@dataclass
class CampaignResult:
    seed: int
    cycles: int
    failures: list = field(default_factory=list)
    census_high_water: int = 0
    inbox_rows: int = 0
    delivery_advances: int = 0
    refusals: int = 0
    leases_after_shutdown: int = 0
    timers_after_shutdown: int = 0
    sessions_after_shutdown: int = 0
    leaked_capacity: bool = False
    #: *** THE CATEGORY TRAVELS WITH THE RESULT. *** *MEASURED (round 727 audit): the category was a constant asserted
    #: against itself in three courts and CARRIED NOWHERE -- not in the result, not in the report, not in the ledger --
    #: so a model result met a reader with no name on it. A reader who holdeth a `CampaignResult` now holdeth the name
    #: of what it is.*
    category: str = Category.RESOURCE_MODEL
    #: *** AND THE NAMES THIS RUN COULD NOT MEASURE TRAVEL TOO, RATHER THAN BEING SILENTLY ABSENT FROM `failures`. ***
    unmeasured_invariants: tuple = Invariant.UNMEASURED
    #: The real owners this run could not ask, by name (empty here: this isle carrieth no owner seam at all).
    unmeasured_owners: tuple = UNMEASURED_OWNER_KINDS

    @property
    def resource_model_category(self) -> bool:
        """True when this result is a RESOURCE-MODEL result -- which is the only kind this conductor can produce."""
        return self.category == Category.RESOURCE_MODEL

    @property
    def passed(self) -> bool:
        return not self.failures

    def replay_hint(self) -> str:
        """What a red run must record so it can be replayed EXACTLY."""
        return ("seed=%d cycles=%d first_failure=%s"
                % (self.seed, self.cycles,
                   self.failures[0] if self.failures else "none"))


class StressCampaign:
    """
    A bounded lifecycle campaign over a small model of the production resources.

    The model is deliberately SMALL: the invariants are about LIFECYCLE and
    RESOURCES (leases, timers, sessions, rows, retries), not about the mesh's
    contents, which their own courts own.
    """

    def __init__(self, seed: int, cycles: int = DEFAULT_CYCLES,
                 peers: int = PEER_COUNT, schedule: FaultSchedule | None = None,
                 defect: str = CampaignDefect.NONE):
        if cycles < 1:
            raise ValueError("a campaign carrieth at least one cycle")
        self.seed = seed
        self.cycles = cycles
        self.peers = peers
        self.schedule = schedule if schedule is not None else FaultSchedule.from_seed(seed, cycles)
        self.defect = defect
        self.rng = random.Random(seed)

        # the live resources
        self.leases = 0
        self.timers = 0
        self.sessions = 0
        self.inbox = {}                 # msg_id -> occurrences
        self.delivery = {}              # msg_id -> advances
        self.retries = {}               # msg_id -> retries used
        self.refusals = 0

    # ---- one cycle ------------------------------------------------------

    def cycle(self, step: int) -> None:
        peer = self.rng.randrange(self.peers)
        msg = self.rng.randrange(max(1, self.cycles // 4))

        # A SHUTDOWN ARRIVETH WITH WORK IN FLIGHT: the final cycle leaveth its
        # resources HELD, so "shutdown releaseth everything it owned" is a real law
        # with something to release (the first form released every cycle, which made
        # a shutdown that released nothing a NO-OP -- the T55-RC10 lesson).
        in_flight = step >= self.cycles - 1

        # (1) a lease is taken and RELEASED, under the capacity -- unless the
        # UNBOUNDED_CENSUS defect saith both the capacity and the release are gone
        if self.defect == CampaignDefect.UNBOUNDED_CENSUS or self.leases < LEASE_CAPACITY:
            self.leases += 1
        if not in_flight and self.defect not in (CampaignDefect.NO_LEASE_RELEASE,
                                                CampaignDefect.UNBOUNDED_CENSUS):
            self.leases = max(0, self.leases - 1)
        # (2) a timer is armed and cancelled
        self.timers += 1
        if not in_flight and self.defect != CampaignDefect.NO_TIMER_RELEASE:
            self.timers = max(0, self.timers - 1)
        # (3) a session is opened and closed
        self.sessions += 1
        if not in_flight and self.defect != CampaignDefect.NO_SESSION_RELEASE:
            self.sessions = max(0, self.sessions - 1)

        # (4) a record is delivered: DEDUP, so one msg_id entereth the inbox once
        if self.defect == CampaignDefect.NO_DEDUP or msg not in self.inbox:
            self.inbox[msg] = self.inbox.get(msg, 0) + 1
        # (5) the delivery row is advanced ONCE per msg_id, under the RETRY CAP
        used = self.retries.get(msg, 0)
        if self.defect == CampaignDefect.NO_RETRY_CAP or used < RETRY_CAP:
            self.delivery[msg] = self.delivery.get(msg, 0) + 1
            self.retries[msg] = used + 1

        # (6) the schedule's faults
        for fault in self.schedule.at(step):
            self.apply(fault)
    # ---- faults ---------------------------------------------------------

    def apply(self, fault: Fault) -> None:
        if fault.kind == FaultKind.CLOCK_JUMP:
            # a monotonic clock that jumpeth must not leak a timer
            self.timers = min(self.timers, 1)
        elif fault.kind == FaultKind.DISK_FULL:
            self.refusals += 1              # a refused write is COUNTED, not thrown
        elif fault.kind == FaultKind.CORRUPTION:
            self.refusals += 1
        elif fault.kind == FaultKind.SLOW_ATT:
            self.timers = max(0, self.timers - 1)
        elif fault.kind == FaultKind.MALFORMED:
            self.refusals += 1
            if self.defect == CampaignDefect.MALFORMED_ESCAPES:
                raise ValueError("the malformed record escaped the loop")

    # ---- the invariants -------------------------------------------------

    def shutdown(self) -> None:
        """Shutdown releaseth EVERY owned resource -- and EACH OWNER IS RELEASED BY ITS OWN CLAUSE, so a mutation of
        one owner's release can no longer be masked by another's. `NO_LEASE_RELEASE` releaseth NONE (the original
        defect, kept whole); the two newer defects each leave ONE owner standing and release the other two."""
        if self.defect == CampaignDefect.NO_LEASE_RELEASE:
            return
        if self.defect != CampaignDefect.NO_TIMER_RELEASE:
            self.timers = 0
        if self.defect != CampaignDefect.NO_SESSION_RELEASE:
            self.sessions = 0
        self.leases = 0

    def check(self, result: CampaignResult) -> list:
        failures = []
        if result.leases_after_shutdown != 0:
            failures.append("%s: %d lease(s) leaked after shutdown"
                            % (Invariant.NO_LEAKED_LEASES, result.leases_after_shutdown))
        if result.timers_after_shutdown != 0:
            failures.append("%s: %d timer(s) leaked after shutdown"
                            % (Invariant.NO_LEAKED_TIMERS, result.timers_after_shutdown))
        if result.sessions_after_shutdown != 0:
            failures.append("%s: %d session(s) leaked after shutdown"
                            % (Invariant.NO_LEAKED_SESSIONS, result.sessions_after_shutdown))
        duplicates = [msg for msg, count in self.inbox.items() if count != 1]
        if duplicates:
            failures.append("%s: msg_id %d entered the inbox %d times"
                            % (Invariant.NO_DUPLICATE_INBOX, duplicates[0],
                               self.inbox[duplicates[0]]))
        over = [msg for msg, count in self.retries.items() if count > RETRY_CAP]
        if over:
            failures.append("%s: msg_id %d was retried %d times, over the cap %d"
                            % (Invariant.NO_DUPLICATE_DELIVERY, over[0], self.retries[over[0]],
                               RETRY_CAP))
        advanced = [msg for msg, count in self.delivery.items() if count > RETRY_CAP + 1]
        if advanced:
            failures.append("%s: msg_id %d advanced %d times"
                            % (Invariant.NO_DUPLICATE_DELIVERY, advanced[0],
                               self.delivery[advanced[0]]))
        # *** THE FAULT CAMPAIGN MUST ACTUALLY HAVE FIRED A REFUSING FAULT. *** *MEASURED (round 727 audit): nothing
        # asserted that a scheduled fault was ever APPLIED -- `CONDUCTOR_FAULTS` was dead, `density=512` giveth an
        # EMPTY schedule under 512 cycles, and every mobile owner arm ran 64 cycles with zero faults. A campaign that
        # exercised NO fault while reporting a clean run is the false green this clause removeth. A scheduled fault
        # that REFUSETH (disk-full, corruption, malformed) increaseth `refusals`; a schedule that carrieth only the
        # two resource-moving kinds (clock jump, slow ATT) is honest about measuring no refusal and is NOT reddened.*
        refusals_expected = sum(1 for fault in self.schedule.faults
                                if fault.kind in (FaultKind.DISK_FULL, FaultKind.CORRUPTION,
                                                  FaultKind.MALFORMED))
        if refusals_expected and result.refusals < refusals_expected:
            failures.append("%s: %d refusing fault(s) were scheduled but only %d were refused -- the fault "
                            "campaign did not fire"
                            % (FAULT_CAMPAIGN_INACTIVE, refusals_expected, result.refusals))
        # THE STRUCTURAL BOUND: the LIVE resources are capped by their capacities, and the row maps are capped by the
        # number of DISTINCT msg ids the campaign can mint (at most cycles // 4). *** THE BOUND IS A FORMULA OF THE
        # CYCLE COUNT AND SAYETH SO: it is the MODEL'S OWN reachable maximum, so it proveth that the live resources
        # plateau, and it canNOT be quoted as a measured ceiling on a real store's rows. ***
        distinct = max(1, self.cycles // 4)
        bound = LEASE_CAPACITY + (RETRY_CAP + 1) + 2 * distinct + 8
        if result.census_high_water > bound:
            failures.append("%s: the census reached %d, over the plateau %d"
                            % (Invariant.BOUNDED_CENSUS, result.census_high_water, bound))
        return failures

    def run(self) -> CampaignResult:
        """Run the campaign. A MALFORMED fault is refused, never thrown -- unless the
        defect saith it escapeth, in which case the campaign recordeth that failure
        rather than dying (a conductor that cannot report a red run is useless)."""
        result = CampaignResult(seed=self.seed, cycles=self.cycles)
        census_high = 0
        for step in range(self.cycles):
            try:
                self.cycle(step)
            except ValueError as escaped:
                result.failures.append("%s: %s at step %d"
                                       % (Invariant.NO_UNCAUGHT_MALFORMED, escaped, step))
                break
            census = self.leases + self.timers + self.sessions + len(self.inbox) + len(self.delivery)
            census_high = max(census_high, census)
        self.shutdown()
        result.census_high_water = census_high
        result.inbox_rows = sum(self.inbox.values())
        result.delivery_advances = sum(self.delivery.values())
        result.refusals = self.refusals
        result.leases_after_shutdown = self.leases
        result.timers_after_shutdown = self.timers
        result.sessions_after_shutdown = self.sessions
        result.leaked_capacity = self.leases > 0
        result.failures.extend(self.check(result))
        return result


def run_campaign(seed: int, cycles: int = DEFAULT_CYCLES, defect: str = CampaignDefect.NONE,
                 peers: int = PEER_COUNT) -> CampaignResult:
    return StressCampaign(seed=seed, cycles=cycles, peers=peers, defect=defect).run()


#: *** THE CONDUCTOR'S OWN FIXED SCHEDULE, WIRED RATHER THAN DEAD. *** *MEASURED (round 727 audit): this constant was
#: defined, exported and validated as DATA by a court, but NOTHING ever applied it -- `run()` took its schedule from
#: the seed alone. It is now exposed as a SCHEDULE a campaign can be run over (the demo path below and a court arm
#: both use it), so "the conductor's own fault schedule" is a thing the conductor actually drives.*
CONDUCTOR_SCHEDULE = FaultSchedule(CONDUCTOR_FAULTS)


#: The defects the court requireth to be CAUGHT, one per invariant family.
DEFECT_TO_INVARIANT = {
    CampaignDefect.NO_LEASE_RELEASE: Invariant.NO_LEAKED_LEASES,
    CampaignDefect.NO_TIMER_RELEASE: Invariant.NO_LEAKED_TIMERS,
    CampaignDefect.NO_SESSION_RELEASE: Invariant.NO_LEAKED_SESSIONS,
    CampaignDefect.NO_RETRY_CAP: Invariant.NO_DUPLICATE_DELIVERY,
    CampaignDefect.NO_DEDUP: Invariant.NO_DUPLICATE_INBOX,
    CampaignDefect.MALFORMED_ESCAPES: Invariant.NO_UNCAUGHT_MALFORMED,
    CampaignDefect.UNBOUNDED_CENSUS: Invariant.BOUNDED_CENSUS,
}


def campaign_report(result: CampaignResult) -> str:
    """*** THE REPORT NAMETH THE CATEGORY, THE MEASURED SET AND THE UNMEASURED SET. *** *Before round 727 the only
    human-readable artefact of a campaign printed no category at all, so a model result could be read as a runtime
    result and the reader had no way to learn otherwise -- the exact failure the category existeth to prevent.*"""
    return ("category=%s seed=%d cycles=%d passed=%s census_high=%d inbox_rows=%d deliveries=%d "
            "refusals=%d leaks(leases=%d timers=%d sessions=%d) measured=%d/%d unmeasured=%s"
            % (result.category, result.seed, result.cycles, result.passed, result.census_high_water,
               result.inbox_rows, result.delivery_advances, result.refusals,
               result.leases_after_shutdown, result.timers_after_shutdown,
               result.sessions_after_shutdown,
               len(Invariant.MEASURED), len(Invariant.ALL), ",".join(result.unmeasured_invariants)))


if __name__ == "__main__":
    print(campaign_report(run_campaign(20_260_915)))
    print(campaign_report(StressCampaign(20_260_915, schedule=CONDUCTOR_SCHEDULE).run()))
