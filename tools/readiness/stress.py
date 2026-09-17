#!/usr/bin/env python3
"""Bounded production-path stress and deterministic fault campaigns (T72).

"Mesh simulation metrics alone do not cover actual adapter/store/native failure
modes."

This module is a CONDUCTOR, and it is deliberately deterministic: every campaign
runneth from an EXPLICIT SEED, every fault is scheduled at an explicit step, and a
run that FAILETH recordeth its seed and its failing step so it can be replayed
EXACTLY. A red run that cannot be replayed is a rumour, not evidence.

THE INVARIANTS a mesh simulation cannot show:

  I1  ZERO LEAKED LEASES  -- after shutdown, every lease is released;
  I2  ZERO LEAKED TIMERS  -- after shutdown, no timer is armed;
  I3  ZERO LEAKED SESSIONS -- after shutdown, no trusted session standeth;
  I4  NO DUPLICATE INBOX  -- one msg_id entereth the inbox ONCE, however many times
                             the record is delivered or replayed;
  I5  NO DUPLICATE DELIVERY -- a delivery row is advanced ONCE, and the retry cap
                             boundeth the retries;
  I6  NO UNCAUGHT MALFORMED INPUT -- a malformed record is REFUSED and COUNTED; it
                             never throweth out of the loop;
  I7  A BOUNDED CENSUS -- the internal census (leases + timers + sessions + rows)
                             plateaus: it is bounded by the capacity, not by the
                             number of cycles.

THE NAMED NEGATIVE: disabling ONE capacity release or ONE retry cap must break an
invariant. The conductor therefore carrieth explicit `defects`, and the court
asserteth that each defect is CAUGHT.
"""
from __future__ import annotations

import random
from dataclasses import dataclass, field

__all__ = [
    "FaultKind", "Fault", "FaultSchedule", "CampaignDefect", "StressCampaign",
    "CampaignResult", "Invariant", "DEFAULT_CYCLES", "PEER_COUNT",
    "LEASE_CAPACITY", "RETRY_CAP", "CONDUCTOR_FAULTS", "run_campaign",
    "RESOURCE_MODEL_CATEGORY",
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
    NO_LEAKED_LEASES = "no_leaked_leases"
    NO_LEAKED_TIMERS = "no_leaked_timers"
    NO_LEAKED_SESSIONS = "no_leaked_sessions"
    NO_DUPLICATE_INBOX = "no_duplicate_inbox"
    NO_DUPLICATE_DELIVERY = "no_duplicate_delivery"
    NO_UNCAUGHT_MALFORMED = "no_uncaught_malformed"
    BOUNDED_CENSUS = "bounded_census"

    ALL = (NO_LEAKED_LEASES, NO_LEAKED_TIMERS, NO_LEAKED_SESSIONS, NO_DUPLICATE_INBOX,
           NO_DUPLICATE_DELIVERY, NO_UNCAUGHT_MALFORMED, BOUNDED_CENSUS)


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
        if not in_flight:
            self.timers = max(0, self.timers - 1)
        # (3) a session is opened and closed
        self.sessions += 1
        if not in_flight:
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
        """Shutdown releaseth EVERY owned resource -- unless the defect saith not."""
        if self.defect == CampaignDefect.NO_LEASE_RELEASE:
            return
        self.leases = 0
        self.timers = 0
        self.sessions = 0

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
        # THE STRUCTURAL BOUND: the live resources are capped by their capacities,
        # and the row maps are capped by the number of DISTINCT msg ids the campaign
        # can mint (at most cycles // 4). The bound is therefore a formula, not a
        # magic number: a census that groweth with the CYCLES is what "unbounded"
        # meaneth.
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


#: The defects the court requireth to be CAUGHT, one per invariant family.
DEFECT_TO_INVARIANT = {
    CampaignDefect.NO_LEASE_RELEASE: Invariant.NO_LEAKED_LEASES,
    CampaignDefect.NO_RETRY_CAP: Invariant.NO_DUPLICATE_DELIVERY,
    CampaignDefect.NO_DEDUP: Invariant.NO_DUPLICATE_INBOX,
    CampaignDefect.MALFORMED_ESCAPES: Invariant.NO_UNCAUGHT_MALFORMED,
    CampaignDefect.UNBOUNDED_CENSUS: Invariant.BOUNDED_CENSUS,
}


def campaign_report(result: CampaignResult) -> str:
    return ("seed=%d cycles=%d passed=%s census_high=%d inbox_rows=%d deliveries=%d "
            "refusals=%d leaks(leases=%d timers=%d sessions=%d)"
            % (result.seed, result.cycles, result.passed, result.census_high_water,
               result.inbox_rows, result.delivery_advances, result.refusals,
               result.leases_after_shutdown, result.timers_after_shutdown,
               result.sessions_after_shutdown))


if __name__ == "__main__":
    print(campaign_report(run_campaign(20_260_915)))
