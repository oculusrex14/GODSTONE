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
  W12 the two isles carrieth the same invariants and the same fault kinds
  W13 the verification matrix keepeth the stress campaign apart from the device rows
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
    ALL_FAULTS, CONDUCTOR_FAULTS, DEFAULT_CYCLES, DEFECT_TO_INVARIANT, LEASE_CAPACITY,
    PEER_COUNT, RETRY_CAP, RESOURCE_MODEL_CATEGORY, CampaignDefect, CampaignResult,
    Fault, FaultKind, FaultSchedule, Invariant, StressCampaign, campaign_report,
    run_campaign,
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
        observed = {}
        for kind in ALL_FAULTS:
            campaign = StressCampaign(seed=23, cycles=2_048,
                                      schedule=FaultSchedule((Fault(kind, 1_024),)))
            campaign.run()
            observed[kind] = campaign.refusals
        # the three that REFUSE something all count a refusal; the two that move a
        # resource (a clock jump and a slow ATT) leave the counters bounded
        self.assertGreater(observed[FaultKind.DISK_FULL], 0)
        self.assertGreater(observed[FaultKind.CORRUPTION], 0)
        self.assertGreater(observed[FaultKind.MALFORMED], 0)
        # a clock jump never leaveth a timer standing
        jumped = StressCampaign(seed=23, cycles=2_048,
                                schedule=FaultSchedule((Fault(FaultKind.CLOCK_JUMP, 1_024,
                                                             3_600_000),)))
        jumped.run()
        self.assertLessEqual(jumped.timers, 1)
        for fault in CONDUCTOR_FAULTS:
            self.assertTrue(fault.magnitude >= 1 or fault.kind == FaultKind.MALFORMED)

    def test_w09_the_named_negative_each_defect_is_caught_by_name(self):
        """Disabling ONE capacity release or ONE retry cap must break an invariant."""
        for defect, invariant in DEFECT_TO_INVARIANT.items():
            result = run_campaign(29, cycles=4_096, defect=defect)
            self.assertFalse(result.passed, "%s must fail" % defect)
            self.assertTrue(any(invariant in failure for failure in result.failures),
                            "%s: expected %s, got %r" % (defect, invariant, result.failures))
        # and the healthy campaign carrieth NONE of those failures
        healthy = run_campaign(29, cycles=4_096)
        self.assertTrue(healthy.passed, healthy.failures)
        for invariant in Invariant.ALL:
            self.assertFalse(any(invariant in f for f in healthy.failures), invariant)

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


class T72ParityTest(unittest.TestCase):
    """W12-W13 -- the isles, and the matrix's boundary."""

    def test_w12_the_two_isles_carry_the_same_invariants_and_faults(self):
        kotlin = ROOT / "android/mesh/src/main/java/io/godstone/mesh/stress/StressCampaign.kt"
        swift = ROOT / "ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift"
        self.assertTrue(kotlin.is_file(), "the Android twin must exist")
        self.assertTrue(swift.is_file(), "the iOS twin must exist")
        ktext = kotlin.read_text(encoding="utf-8")
        stext = swift.read_text(encoding="utf-8")
        for invariant in ("no_leaked_leases", "no_duplicate_inbox", "no_duplicate_delivery",
                          "no_uncaught_malformed", "bounded_census"):
            self.assertIn(invariant, ktext, "the Android twin must carry %s" % invariant)
            self.assertIn(invariant, stext, "the iOS twin must carry %s" % invariant)
            self.assertIn(invariant, Invariant.ALL)
        for kind in ALL_FAULTS:
            self.assertIn(kind, ktext, kind)
            self.assertIn(kind, stext, kind)

    def test_w13_the_matrix_keepeth_stress_apart_from_the_device_rows(self):
        matrix = (ROOT / "docs/production/VERIFICATION_MATRIX.md").read_text(encoding="utf-8")
        self.assertIn("Mesh simulation regression", matrix)
        self.assertIn("Simulation, not device", matrix)
        self.assertIn("BLOCKED", matrix)
        # the conductor itself never claimeth a device observation: its CODE is
        # scanned, with the docstrings and comments stripped (a comment that NAMETH
        # the device rows it excludeth is not a claim about a device)
        source = (ROOT / "tools/readiness/stress.py").read_text(encoding="utf-8")
        code = "\n".join(line for line in source.splitlines()
                         if not line.strip().startswith("#"))
        code = code.split('"""')
        code = "".join(code[::2])            # keep only the parts OUTSIDE docstrings
        for forbidden in ("device", "phone", "hardware"):
            self.assertNotIn(forbidden, code.lower(),
                             "the conductor must not claim a device observation (%s)" % forbidden)


class T72NamedCategoryTest(unittest.TestCase):
    """W14 -- GS-STRESS-001 step 1 ON THE THIRD ISLE.

    The card: "Keep the current class under an explicitly named resource-model test category." A conductor whose
    counters describe its own model must never be read as a production stress result -- and the honest way to keep
    that so is to NAME the category where the result is read, and to ASSERT it HERE.

    MEASURED at round 521: before this arm, this isle carrieth NO name at all -- a reader consulting the conductor's
    evidence could take a model result for a runtime result and had no way to learn otherwise. A CATEGORY THAT
    HOLDETH ON ONE ISLE IS NOT A CATEGORY.
    """

    def test_w14_the_conductors_category_is_named(self):
        self.assertEqual(
            RESOURCE_MODEL_CATEGORY, "resource-model",
            "the conductor must declare its CATEGORY by name, so no reader mistaketh a model for a runtime")

    def test_w14_the_category_does_not_name_the_runtime_it_does_not_measure(self):
        self.assertNotEqual(
            RESOURCE_MODEL_CATEGORY, "production",
            "and it must NOT be named for the production runtime it doth not measure")


if __name__ == "__main__":
    unittest.main(verbosity=2)
