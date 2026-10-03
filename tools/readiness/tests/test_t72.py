#! /usr/bin/env python3
"""T72 readiness court: bounded production-path stress and deterministic faults.

The card's law, one witness each where the rule speaketh:

  W01 TEN THOUSAND LIFECYCLE CYCLES over multiple peers, bounded and deterministic
  W02 ZERO LEAKED LEASES / TIMERS / SESSIONS after shutdown
  W03 NO DUPLICATE INBOX row for one msg_id, however often the record arriveth
  W04 NO DUPLICATE DELIVERY: the retry cap boundeth the advances
  W05 NO UNCAUGHT MALFORMED INPUT: a malformed record is refused and COUNTED
  W06 THE CENSUS PLATEAU: the bound is a STRUCTURAL FORMULA, not a magic number
  W07 the FAULT SCHEDULE is bounded, deterministic and carrieth every kind
  W08 the FIVE FAULTS are applied at their steps: clock jump, disk-full, corruption,
      slow ATT and a malformed record
  W09 THE NAMED NEGATIVE: disabling ONE capacity release or ONE retry cap falleth
      the invariant -- each defect is caught BY NAME
  W10 a FAILED SEED is RECORDED and REPRODUCIBLE: the same seed giveth the same
      failure at the same step, twice
  W11 the campaign is BOUNDED in time: 10k cycles settle inside the court's budget
  W12 the two isles carrieth the same invariants and the same fault kinds -- OWNED BY THE TWIN COURTS; this court no
      longer copies twin source text, and a source-body read is not semantic proof
  W13 THE CONDUCTOR claimeth no device observation -- scanned over THIS conductor's own code only; the matrix row is
      owned by the matrix's own gate, not re-read here
  W14 THE CONDUCTOR BELONGETH TO A **NAMED** CATEGORY, and doth NOT claim to measure the production runtime
      (GS-STRESS-001 step 1 on THIS isle -- before round 521 the category was named on the Android isle alone)

No external gate is closed; readiness stays false; no device is claimed.
"""
from __future__ import annotations

import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

from stress import (  # noqa: E402
    ALL_FAULTS, CONDUCTOR_FAULTS, CONDUCTOR_SCHEDULE, DEFAULT_CYCLES, DEFECT_TO_INVARIANT,
    FAULT_CAMPAIGN_INACTIVE, LEASE_CAPACITY, PEER_COUNT, RETRY_CAP, RESOURCE_MODEL_CATEGORY,
    UNMEASURED_OWNER_KINDS, CampaignDefect, CampaignResult, Category, Fault, FaultKind,
    FaultSchedule, Invariant, StressCampaign, campaign_report, run_campaign,
)


class T72CampaignTest(unittest.TestCase):
    """W01-W02 -- the campaign, and the leaks."""

    def test_w01_ten_thousand_lifecycle_cycles_over_multiple_peers(self):
        self.assertEqual(10_000, DEFAULT_CYCLES)
        self.assertGreater(PEER_COUNT, 1, "the card requireth MULTIPLE peers")
        started = time.monotonic()
        result = run_campaign(20_260_915)
        elapsed = time.monotonic() - started
        self.assertEqual(10_000, result.cycles)
        self.assertTrue(result.passed, result.failures)
        self.assertGreater(result.inbox_rows, 0)
        self.assertGreater(result.delivery_advances, 0)
        # the SAME seed giveth the SAME campaign: determinism is the point
        again = run_campaign(20_260_915)
        self.assertEqual(result.inbox_rows, again.inbox_rows)
        self.assertEqual(result.delivery_advances, again.delivery_advances)
        self.assertEqual(result.census_high_water, again.census_high_water)
        self.assertLess(elapsed, 20.0, "the campaign must settle inside the court's budget")

    def test_w02_zero_leaked_leases_timers_sessions_after_shutdown(self):
        result = run_campaign(7)
        self.assertTrue(result.passed, result.failures)
        self.assertEqual(0, result.leases_after_shutdown)
        self.assertEqual(0, result.timers_after_shutdown)
        self.assertEqual(0, result.sessions_after_shutdown)
        self.assertFalse(result.leaked_capacity)
        # a campaign with a defect leaketh, and the failure NAMETH the invariant
        leaked = run_campaign(7, defect=CampaignDefect.NO_LEASE_RELEASE)
        self.assertFalse(leaked.passed)
        self.assertTrue(any(Invariant.NO_LEAKED_LEASES in f for f in leaked.failures))
        self.assertGreater(leaked.leases_after_shutdown, 0)


class T72DedupAndMalformedTest(unittest.TestCase):
    """W03-W06 -- duplicates, malformed input, the plateau."""

    def test_w03_no_duplicate_inbox_row(self):
        campaign = StressCampaign(seed=11, cycles=2_000)
        result = campaign.run()
        self.assertTrue(result.passed, result.failures)
        for msg, count in campaign.inbox.items():
            self.assertEqual(1, count, "msg_id %d entered the inbox %d times" % (msg, count))
        # the defect proveth the check biteth
        broken = run_campaign(11, cycles=2_000, defect=CampaignDefect.NO_DEDUP)
        self.assertTrue(any(Invariant.NO_DUPLICATE_INBOX in f for f in broken.failures))

    def test_w04_no_duplicate_delivery_under_the_retry_cap(self):
        campaign = StressCampaign(seed=13, cycles=2_000)
        campaign.run()
        for msg, used in campaign.retries.items():
            self.assertLessEqual(used, RETRY_CAP, "msg_id %d exceeded the retry cap" % msg)
        for msg, advances in campaign.delivery.items():
            self.assertLessEqual(advances, RETRY_CAP)
        broken = run_campaign(13, cycles=2_000, defect=CampaignDefect.NO_RETRY_CAP)
        self.assertTrue(any(Invariant.NO_DUPLICATE_DELIVERY in f for f in broken.failures))

    def test_w05_no_uncaught_malformed_input(self):
        # a healthy campaign MEETS malformed records and refuseth them
        campaign = StressCampaign(seed=17, cycles=4_096,
                                  schedule=FaultSchedule((Fault(FaultKind.MALFORMED, 1_024),)))
        result = campaign.run()
        self.assertTrue(result.passed, result.failures)
        self.assertGreater(result.refusals, 0, "the malformed record must have been REFUSED")
        # the defect: the malformed record ESCAPES, and the conductor RECORDETH it
        # rather than dying (a conductor that cannot report a red run is useless)
        broken = run_campaign(17, cycles=4_096, defect=CampaignDefect.MALFORMED_ESCAPES)
        self.assertFalse(broken.passed)
        self.assertTrue(any(Invariant.NO_UNCAUGHT_MALFORMED in f for f in broken.failures))
        self.assertIn("step", broken.failures[0])

    def test_w06_the_census_plateau_is_a_structural_formula(self):
        campaign = StressCampaign(seed=19, cycles=4_000)
        result = campaign.run()
        self.assertTrue(result.passed, result.failures)
        distinct = 4_000 // 4
        bound = LEASE_CAPACITY + (RETRY_CAP + 1) + 2 * distinct + 8
        self.assertLessEqual(result.census_high_water, bound)
        # the plateau is INDEPENDENT of how many cycles run: the SAME seed at twice
        # the cycles must not double the LIVE resources
        short = StressCampaign(seed=19, cycles=2_000)
        long = StressCampaign(seed=19, cycles=10_000)
        short.run()
        long.run()
        self.assertLessEqual(long.leases, LEASE_CAPACITY)
        self.assertLessEqual(long.timers, 1)
        self.assertLessEqual(long.sessions, 1)
        # and the defect proveth the plateau check biteth
        broken = run_campaign(19, cycles=10_000, defect=CampaignDefect.UNBOUNDED_CENSUS)
        self.assertTrue(any(Invariant.BOUNDED_CENSUS in f for f in broken.failures))


class T72FaultsTest(unittest.TestCase):
    """W07-W11 -- the schedule, the faults, the named negative, the seed."""

    def test_w07_the_fault_schedule_is_bounded_and_deterministic(self):
        schedule = FaultSchedule.from_seed(3, 4_096)
        self.assertTrue(schedule.faults)
        for fault in schedule.faults:
            self.assertIn(fault.kind, ALL_FAULTS)
            self.assertGreaterEqual(fault.at_step, 0)
            self.assertLess(fault.at_step, 4_096)
        # the SAME seed giveth the SAME schedule
        self.assertEqual(schedule.faults, FaultSchedule.from_seed(3, 4_096).faults)
        self.assertNotEqual(schedule.faults, FaultSchedule.from_seed(4, 4_096).faults)
        # and the conductor's own schedule carrieth EVERY kind, inside the ten thousand
        kinds = {fault.kind for fault in CONDUCTOR_FAULTS}
        self.assertEqual(set(ALL_FAULTS), kinds, "the conductor must schedule every fault kind")
        for fault in CONDUCTOR_FAULTS:
            self.assertLess(fault.at_step, DEFAULT_CYCLES)

    def test_w08_the_five_faults_are_applied_at_their_steps(self):
        """*** EACH FAULT'S OWN EFFECT, MEASURED -- NOT MERELY "SOMETHING WAS REFUSED". ***

        *MEASURED (round 727 audit): the refusing kinds were asserted `> 0` and the two resource-moving kinds were
        asserted not at all (the `timers <= 1` arm was a TAUTOLOGY -- the baseline is 1 at end of run regardless).*
        Here each kind carrieth its own observable effect, with a baseline to compare against.
        """
        # (A) THE REFUSING KINDS ARE COUNTED, EXACTLY -- one scheduled fault, one refusal (the card's "refused and
        # COUNTED", asserted rather than described).
        for kind in (FaultKind.DISK_FULL, FaultKind.CORRUPTION, FaultKind.MALFORMED):
            campaign = StressCampaign(seed=23, cycles=2_048,
                                      schedule=FaultSchedule((Fault(kind, 1_024),)))
            campaign.run()
            self.assertEqual(1, campaign.refusals,
                             "%s must be REFUSED and COUNTED exactly once" % kind)

        # (B) THE TWO RESOURCE-MOVING KINDS, EACH AGAINST A BASELINE. A timer is armed and cancelled every cycle,
        # so on the healthy path the count is 1 at end of run no matter what a fault does -- the fault is only
        # OBSERVABLE against an owner that is NOT releasing, which is exactly the defect below. The run is cut ONE
        # cycle past the fault, so the count at the fault step IS the final count.
        def timers_after(schedule, defect=CampaignDefect.NO_TIMER_RELEASE):
            campaign = StressCampaign(seed=23, cycles=1_025, schedule=schedule, defect=defect)
            campaign.run()
            return campaign.timers

        baseline = timers_after(FaultSchedule(()))
        self.assertEqual(1_025, baseline, "the premise: a standing timer owner accumulates one per cycle")
        jumped = timers_after(FaultSchedule((Fault(FaultKind.CLOCK_JUMP, 1_024, 3_600_000),)))
        self.assertEqual(1, jumped, "a clock jump must leave EXACTLY ONE timer standing (min(timers, 1))")
        slowed = timers_after(FaultSchedule((Fault(FaultKind.SLOW_ATT, 1_024, 250),)))
        self.assertEqual(baseline - 1, slowed,
                         "a slow ATT must release exactly one standing timer -- previously UNASSERTED anywhere")

        # (C) THE CONDUCTOR'S OWN SCHEDULE IS WIRED, NOT DEAD: run over it and observe its faults fire. Its fixed
        # steps (97..1024) all lie inside a 2_048-cycle run, so disk-full, corruption and malformed each refuse once
        # -- and the clock jump and slow ATT move the timers alongside.
        conductor = StressCampaign(seed=23, cycles=2_048, schedule=CONDUCTOR_SCHEDULE).run()
        self.assertTrue(conductor.passed, conductor.failures)
        self.assertEqual(3, conductor.refusals,
                         "the conductor's schedule carrieth disk-full, corruption and malformed, each counted once")
        self.assertEqual(set(ALL_FAULTS), {fault.kind for fault in CONDUCTOR_FAULTS})

    def test_w08b_the_fault_liveness_clause_biteth(self):
        """*** THE FAULT CAMPAIGN MUST ACTUALLY FIRE -- AND A DEAF SCHEDULE IS REDDENED BY NAME. ***

        *The audit MEASURED that nothing asserted a scheduled fault was ever APPLIED (`CONDUCTOR_FAULTS` was dead, and
        `density=512` giveth an EMPTY schedule under 512 cycles).* This arm reddens the new clause directly: a refusing
        fault scheduled BEYOND the horizon is never applied, and the run must say so under its OWN harness token --
        not under `no_uncaught_malformed`, which would misname a deaf schedule as a malformed record.
        """
        deaf = StressCampaign(seed=23, cycles=64,
                              schedule=FaultSchedule((Fault(FaultKind.DISK_FULL, 10_000),))).run()
        self.assertFalse(deaf.passed, "a scheduled refusing fault that never fired must redden the run")
        self.assertTrue(any(FAULT_CAMPAIGN_INACTIVE in failure for failure in deaf.failures),
                        "the deaf schedule must be named by its own harness token: %r" % deaf.failures)
        self.assertFalse(any(Invariant.NO_UNCAUGHT_MALFORMED in f for f in deaf.failures),
                         "a deaf schedule is not a malformed record and must not be called one")
        # AND THE CLAUSE IS NOT A UNIVERSAL FALSE CHECK: an empty (legitimate) schedule is silent, and a schedule that
        # fires is silent too.
        self.assertTrue(StressCampaign(seed=23, cycles=64).run().passed)
        firing = StressCampaign(seed=23, cycles=64,
                                schedule=FaultSchedule((Fault(FaultKind.DISK_FULL, 8),))).run()
        self.assertTrue(firing.passed, firing.failures)

    def test_w09_the_named_negative_each_defect_is_caught_by_name(self):
        """Disabling ONE capacity release or ONE retry cap must break an invariant.

        *** ROUND 727: ONE DEFECT PER LIFECYCLE OWNER, AND THE UNMEASURED NAMES ARE NO LONGER CALLED "CLEAN". ***
        *MEASURED before this repair: `DEFECT_TO_INVARIANT` had FIVE entries and the healthy loop swept all ELEVEN
        names -- so `no_leaked_timers`, `no_leaked_sessions` and the four owner-kind names were asserted "absent from a
        healthy run" while NOTHING here could ever emit them. A check that cannot fail is not a check.* Now the
        defect table carrieth a defect per MEASURED invariant, and the healthy loop sweeps `Invariant.MEASURED` only.
        """
        for defect, invariant in DEFECT_TO_INVARIANT.items():
            result = run_campaign(29, cycles=4_096, defect=defect)
            self.assertFalse(result.passed, "%s must fail" % defect)
            self.assertTrue(any(invariant in failure for failure in result.failures),
                            "%s: expected %s, got %r" % (defect, invariant, result.failures))
        # EVERY MEASURED INVARIANT CARRIETH ITS OWN DEFECT -- otherwise a measured name could ride on another's rod.
        self.assertEqual(set(DEFECT_TO_INVARIANT.values()), set(Invariant.MEASURED),
                         "one defect per MEASURED invariant, and no defect for a name this isle cannot emit")
        # and the healthy campaign carrieth NONE of the MEASURED failures (the four UNMEASURED names are not swept:
        # nothing here can emit them, so asserting their absence would be the very vacuity this repair removeth)
        healthy = run_campaign(29, cycles=4_096)
        self.assertTrue(healthy.passed, healthy.failures)
        for invariant in Invariant.MEASURED:
            self.assertFalse(any(invariant in f for f in healthy.failures), invariant)

    def test_w09b_the_measured_and_unmeasured_sets_are_typed_and_carried(self):
        """*** THE 11-NAMES/7-MEASURED GAP, TYPED RATHER THAN NARRATED, AND CARRIED ON THE RESULT. ***

        The read-only audit MEASURED that four of the eleven names could never be emitted here, and that a result
        carried no statement of the gap. This arm pins: the split is exact and disjoint; the four owner-kind names
        are exactly what is unmeasured; and a RESULT carrieth them BY NAME so "nothing is leaking" is never confused
        with "nobody asked my kind of owner".
        """
        self.assertEqual(len(Invariant.ALL), 11)
        self.assertEqual(len(Invariant.MEASURED), 7)
        self.assertEqual(len(Invariant.UNMEASURED), 4)
        self.assertEqual(set(Invariant.MEASURED) | set(Invariant.UNMEASURED), set(Invariant.ALL))
        self.assertFalse(set(Invariant.MEASURED) & set(Invariant.UNMEASURED))
        self.assertEqual(set(Invariant.UNMEASURED),
                         {Invariant.NO_LEAKED_RESERVATIONS, Invariant.NO_LEAKED_INVENTORY_LEASES,
                          Invariant.PENDING_ACK_WORK, Invariant.NO_LEAKED_OBSERVERS})
        # THE MEASURED SET IS DERIVED FROM THE EMITTERS, NOT TYPED: every measured name appeareth in the source of a
        # failure string, and no unmeasured name is ever emitted (that is WHY it is unmeasured).
        source = (ROOT / "tools/readiness/stress.py").read_text(encoding="utf-8")
        result = run_campaign(20_260_915)
        self.assertEqual(result.unmeasured_invariants, Invariant.UNMEASURED)
        self.assertEqual(result.unmeasured_owners, UNMEASURED_OWNER_KINDS)
        self.assertEqual(result.category, Category.RESOURCE_MODEL)
        self.assertTrue(result.resource_model_category)
        for invariant in Invariant.MEASURED:
            self.assertIn(invariant, source, "%s must be emittable here" % invariant)

    def test_w09c_the_report_nameth_the_category_and_the_unmeasured_names(self):
        """*** A RESULT MUST SAY WHAT IT IS, AT THE POINT A READER MEETETH IT. ***"""
        report = campaign_report(run_campaign(20_260_915))
        self.assertIn("category=%s" % Category.RESOURCE_MODEL, report)
        self.assertNotIn(Category.PRODUCTION_RUNTIME, report)
        self.assertIn("measured=7/11", report)
        for invariant in Invariant.UNMEASURED:
            self.assertIn(invariant, report)

    def test_w10_a_failed_seed_is_recorded_and_reproducible(self):
        seed = 31
        first = run_campaign(seed, cycles=4_096, defect=CampaignDefect.NO_DEDUP)
        second = run_campaign(seed, cycles=4_096, defect=CampaignDefect.NO_DEDUP)
        self.assertFalse(first.passed)
        # the REPLAY HINT carrieth the seed, the size and the first failure
        hint = first.replay_hint()
        self.assertIn("seed=%d" % seed, hint)
        self.assertIn("cycles=4096", hint)
        self.assertIn("first_failure=", hint)
        # and the replay is EXACT: the same failure, at the same step, twice
        self.assertEqual(first.failures, second.failures)
        self.assertEqual(first.failures[0], second.failures[0])
        # a DIFFERENT seed giveth a DIFFERENT campaign, so the failure is not an
        # artefact of the harness itself
        other = StressCampaign(seed=32, cycles=4_096)
        same = StressCampaign(seed=seed, cycles=4_096)
        other.run()
        same.run()
        self.assertNotEqual(sum(other.inbox.values()), sum(same.inbox.values()),
                            "two seeds must not produce the identical trace")

    def test_w11_the_campaign_is_bounded_in_time(self):
        started = time.monotonic()
        result = run_campaign(37, cycles=DEFAULT_CYCLES)
        elapsed = time.monotonic() - started
        self.assertTrue(result.passed, result.failures)
        self.assertLess(elapsed, 20.0, "10k cycles must settle inside the budget")
        # and a campaign with EVERY fault kind scheduled settles too
        schedule = FaultSchedule.from_seed(37, DEFAULT_CYCLES, density=64)
        full = StressCampaign(seed=37, cycles=DEFAULT_CYCLES, schedule=schedule).run()
        self.assertTrue(full.passed, full.failures)
        self.assertEqual(set(ALL_FAULTS), set(schedule.kinds()))


class T72NamedCategoryTest(unittest.TestCase):
    """W14 -- GS-STRESS-001 step 1 ON THE THIRD ISLE, NOW WITH THE CATEGORY CARRIED.

    The card: "Keep the current class under an explicitly named resource-model test category." A conductor whose
    counters describe its own model must never be read as a production stress result -- and the honest way to keep
    that so is to NAME the category where the result is read, and to ASSERT it HERE.

    MEASURED at round 521: before this arm, this isle carrieth NO name at all -- a reader consulting the conductor's
    evidence could take a model result for a runtime result and had no way to learn otherwise. A CATEGORY THAT
    HOLDETH ON ONE ISLE IS NOT A CATEGORY.

    *** AND MEASURED AT ROUND 727: THE NAME WAS DECLARED AND NOWHERE CARRIED. *** *The constant existed, three courts
    asserted it against ITSELF, and no `CampaignResult`, no report line and no ledger row carrieth it -- so a reader
    who held a RESULT still met no name. A DECLARATION IS NOT A CAPABILITY; this arm now asserteth the CARRY.*
    """

    def test_w14_the_conductors_category_is_named(self):
        self.assertEqual(
            RESOURCE_MODEL_CATEGORY, "resource-model",
            "the conductor must declare its CATEGORY by name, so no reader mistaketh a model for a runtime")
        self.assertEqual(Category.RESOURCE_MODEL, RESOURCE_MODEL_CATEGORY)

    def test_w14_the_category_does_not_name_the_runtime_it_does_not_measure(self):
        self.assertNotEqual(
            RESOURCE_MODEL_CATEGORY, "production",
            "and it must NOT be named for the production runtime it doth not measure")
        self.assertNotEqual(Category.RESOURCE_MODEL, Category.PRODUCTION_RUNTIME)

    def test_w14b_the_category_is_carried_on_the_result_and_in_the_report(self):
        """*** THE CARRY, WHICH IS THE DIFFERENCE BETWEEN A NAME AND A CONTRACT. ***

        A result that carrieth `category=resource-model` cannot be mistaken for the production runtime at the point a
        reader meeteth it; and a result that carrieth the four UNMEASURED names cannot be mistaken for one that asked
        every owner and found them clean.
        """
        result = run_campaign(20_260_915)
        self.assertIsInstance(result, CampaignResult)
        self.assertEqual(result.category, Category.RESOURCE_MODEL)
        self.assertTrue(result.resource_model_category)
        self.assertNotEqual(result.category, Category.PRODUCTION_RUNTIME)
        self.assertIn("category=resource-model", campaign_report(result))


if __name__ == "__main__":
    unittest.main(verbosity=2)
