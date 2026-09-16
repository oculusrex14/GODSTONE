// T72 readiness court (android isle) -- bounded production-path stress and
// deterministic fault campaigns. The twin of the python conductor and the iOS
// campaign, with the SAME invariants, fault kinds and bounds.
package io.godstone.mesh.readiness

import io.godstone.mesh.stress.CampaignDefect
import io.godstone.mesh.stress.Fault
import io.godstone.mesh.stress.FaultKind
import io.godstone.mesh.stress.FaultSchedule
import io.godstone.mesh.stress.Invariants
import io.godstone.mesh.stress.StressCampaign
import org.junit.Assert
import org.junit.Test

class ReadinessT72Test {
    private val healthy = StressCampaign(seed = 20_260_915L)

    // ------------------------------------------------------------ W00

    /**
     * GS-STRESS-001 step 1: THE CAMPAIGN BELONGETH TO A **NAMED** CATEGORY, AND SAYETH WHAT IT IS NOT.
     *
     * The card: "Keep the current class under an explicitly named resource-model test category." A campaign whose counters
     * describe its own model must never be read as a production stress result -- and the honest way to keep that so is to
     * NAME the category in the class and ASSERT it here, where the results are read.
     */
    @Test
    fun test_w00_the_campaign_is_a_named_resource_model() {
        Assert.assertEquals("the campaign must declare its CATEGORY by name, so no reader mistaketh a model for a runtime",
            "resource-model", io.godstone.mesh.stress.RESOURCE_MODEL_CATEGORY)
        Assert.assertNotEquals("and it must NOT be named for the production runtime it doth not measure",
            "production", io.godstone.mesh.stress.RESOURCE_MODEL_CATEGORY)
    }

    // ------------------------------------------------------------ W01

    /** W01 -- ten thousand lifecycle cycles over multiple peers, deterministically. */
    @Test
    fun test_w01_ten_thousand_cycles_over_multiple_peers() {
        Assert.assertEquals(10_000, StressCampaign.DEFAULT_CYCLES)
        Assert.assertTrue(StressCampaign.PEER_COUNT > 1)
        val started = System.nanoTime()
        val result = healthy.run()
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        Assert.assertTrue("the campaign must pass: " + result.failures, result.passed)
        Assert.assertEquals(10_000, result.cycles)
        Assert.assertTrue(result.inboxRows > 0)
        // the SAME seed giveth the SAME campaign
        val again = StressCampaign(seed = 20_260_915L).run()
        Assert.assertEquals(result.inboxRows, again.inboxRows)
        Assert.assertEquals(result.deliveryAdvances, again.deliveryAdvances)
        Assert.assertEquals(result.censusHighWater, again.censusHighWater)
        Assert.assertTrue("10k cycles must settle inside the budget: ${elapsedMs}ms", elapsedMs < 20_000)
    }

    // ------------------------------------------------------------ W02

    /** W02 -- zero leaked leases, timers or sessions after shutdown. */
    @Test
    fun test_w02_zero_leaks_after_shutdown() {
        val result = StressCampaign(seed = 7L).run()
        Assert.assertTrue(result.failures.toString(), result.passed)
        Assert.assertEquals(0, result.leasesAfterShutdown)
        Assert.assertEquals(0, result.timersAfterShutdown)
        Assert.assertEquals(0, result.sessionsAfterShutdown)
        // the defect leaketh, and the failure NAMETH the invariant
        val leaked = StressCampaign(seed = 7L, defect = CampaignDefect.NO_LEASE_RELEASE).run()
        Assert.assertFalse(leaked.passed)
        Assert.assertTrue(leaked.failures.any { it.contains(Invariants.NO_LEAKED_LEASES) })
        Assert.assertTrue(leaked.leasesAfterShutdown > 0)
    }

    // ------------------------------------------------------------ W03

    /** W03 -- no duplicate inbox row for one msg_id. */
    @Test
    fun test_w03_no_duplicate_inbox_row() {
        val campaign = StressCampaign(seed = 11L, cycles = 2_000)
        val result = campaign.run()
        Assert.assertTrue(result.failures.toString(), result.passed)
        for ((msg, count) in campaign.inbox) {
            Assert.assertEquals("msg_id $msg entered the inbox $count times", 1, count)
        }
        val broken = StressCampaign(seed = 11L, cycles = 2_000, defect = CampaignDefect.NO_DEDUP).run()
        Assert.assertTrue(broken.failures.any { it.contains(Invariants.NO_DUPLICATE_INBOX) })
    }

    // ------------------------------------------------------------ W04

    /** W04 -- no duplicate delivery: the retry cap boundeth the advances. */
    @Test
    fun test_w04_no_duplicate_delivery_under_the_retry_cap() {
        val campaign = StressCampaign(seed = 13L, cycles = 2_000)
        campaign.run()
        for ((msg, used) in campaign.retries) {
            Assert.assertTrue("msg_id $msg exceeded the retry cap", used <= StressCampaign.RETRY_CAP)
        }
        val broken = StressCampaign(seed = 13L, cycles = 2_000,
            defect = CampaignDefect.NO_RETRY_CAP).run()
        Assert.assertTrue(broken.failures.any { it.contains(Invariants.NO_DUPLICATE_DELIVERY) })
    }

    // ------------------------------------------------------------ W05

    /** W05 -- no uncaught malformed input: it is refused and COUNTED. */
    @Test
    fun test_w05_no_uncaught_malformed_input() {
        val campaign = StressCampaign(seed = 17L, cycles = 4_096,
            schedule = FaultSchedule(listOf(Fault(FaultKind.MALFORMED, 1_024))))
        val result = campaign.run()
        Assert.assertTrue(result.failures.toString(), result.passed)
        Assert.assertTrue("the malformed record must have been REFUSED", result.refusals > 0)
        // the defect: it ESCAPES, and the conductor RECORDETH it rather than dying
        val broken = StressCampaign(seed = 17L, cycles = 4_096,
            defect = CampaignDefect.MALFORMED_ESCAPES).run()
        Assert.assertFalse(broken.passed)
        Assert.assertTrue(broken.failures.any { it.contains(Invariants.NO_UNCAUGHT_MALFORMED) })
        Assert.assertTrue(broken.failures.first().contains("step"))
    }

    // ------------------------------------------------------------ W06

    /** W06 -- the census plateau is a STRUCTURAL FORMULA, not a magic number. */
    @Test
    fun test_w06_the_census_plateau_is_structural() {
        val result = StressCampaign(seed = 19L, cycles = 4_000).run()
        Assert.assertTrue(result.failures.toString(), result.passed)
        val distinct = 4_000 / 4
        val bound = StressCampaign.LEASE_CAPACITY + (StressCampaign.RETRY_CAP + 1) +
            2 * distinct + 8
        Assert.assertTrue(result.censusHighWater <= bound)
        // the LIVE resources are independent of the cycle count
        val long = StressCampaign(seed = 19L, cycles = 10_000)
        long.run()
        Assert.assertTrue(long.leases <= StressCampaign.LEASE_CAPACITY)
        Assert.assertTrue(long.timers <= 1)
        Assert.assertTrue(long.sessions <= 1)
        val broken = StressCampaign(seed = 19L, cycles = 10_000,
            defect = CampaignDefect.UNBOUNDED_CENSUS).run()
        Assert.assertTrue(broken.failures.any { it.contains(Invariants.BOUNDED_CENSUS) })
    }

    // ------------------------------------------------------------ W07

    /** W07 -- the schedule is bounded, deterministic and carrieth every kind. */
    @Test
    fun test_w07_the_fault_schedule_is_bounded_and_deterministic() {
        val schedule = FaultSchedule.fromSeed(3L, 4_096)
        Assert.assertTrue(schedule.faults.isNotEmpty())
        for (fault in schedule.faults) {
            Assert.assertTrue(FaultKind.ALL.contains(fault.kind))
            Assert.assertTrue(fault.atStep >= 0 && fault.atStep < 4_096)
        }
        Assert.assertEquals(schedule.faults, FaultSchedule.fromSeed(3L, 4_096).faults)
        Assert.assertNotEquals(schedule.faults, FaultSchedule.fromSeed(4L, 4_096).faults)
        val dense = FaultSchedule.fromSeed(23L, StressCampaign.DEFAULT_CYCLES, density = 64)
        Assert.assertEquals(FaultKind.ALL.toSet(), dense.kinds())
    }

    // ------------------------------------------------------------ W08

    /** W08 -- the five faults are applied at their steps. */
    @Test
    fun test_w08_the_five_faults_are_applied_at_their_steps() {
        val refusals = HashMap<String, Int>()
        for (kind in FaultKind.ALL) {
            val campaign = StressCampaign(seed = 23L, cycles = 2_048,
                schedule = FaultSchedule(listOf(Fault(kind, 1_024))))
            campaign.run()
            refusals[kind] = campaign.refusals
        }
        Assert.assertTrue(refusals[FaultKind.DISK_FULL]!! > 0)
        Assert.assertTrue(refusals[FaultKind.CORRUPTION]!! > 0)
        Assert.assertTrue(refusals[FaultKind.MALFORMED]!! > 0)
        val jumped = StressCampaign(seed = 23L, cycles = 2_048,
            schedule = FaultSchedule(listOf(Fault(FaultKind.CLOCK_JUMP, 1_024, 3_600_000L))))
        jumped.run()
        Assert.assertTrue("a clock jump leaveth no timer standing", jumped.timers <= 1)
    }

    // ------------------------------------------------------------ W09

    /** W09 -- THE NAMED NEGATIVE: each defect is caught BY NAME. */
    @Test
    fun test_w09_each_defect_is_caught_by_name() {
        val expected = mapOf(
            CampaignDefect.NO_LEASE_RELEASE to Invariants.NO_LEAKED_LEASES,
            CampaignDefect.NO_RETRY_CAP to Invariants.NO_DUPLICATE_DELIVERY,
            CampaignDefect.NO_DEDUP to Invariants.NO_DUPLICATE_INBOX,
            CampaignDefect.MALFORMED_ESCAPES to Invariants.NO_UNCAUGHT_MALFORMED,
            CampaignDefect.UNBOUNDED_CENSUS to Invariants.BOUNDED_CENSUS,
        )
        for ((defect, invariant) in expected) {
            val result = StressCampaign(seed = 29L, cycles = 4_096, defect = defect).run()
            Assert.assertFalse("$defect must fail", result.passed)
            Assert.assertTrue("$defect: expected $invariant, got ${result.failures}",
                result.failures.any { it.contains(invariant) })
        }
        // and a healthy campaign carrieth NONE of them
        val clean = StressCampaign(seed = 29L, cycles = 4_096).run()
        Assert.assertTrue(clean.failures.toString(), clean.passed)
        for (invariant in Invariants.ALL) {
            Assert.assertFalse(clean.failures.any { it.contains(invariant) })
        }
    }

    // ------------------------------------------------------------ W10

    /** W10 -- a FAILED SEED is recorded and REPRODUCIBLE. */
    @Test
    fun test_w10_a_failed_seed_is_recorded_and_reproducible() {
        val seed = 31L
        val first = StressCampaign(seed = seed, cycles = 4_096,
            defect = CampaignDefect.NO_DEDUP).run()
        val second = StressCampaign(seed = seed, cycles = 4_096,
            defect = CampaignDefect.NO_DEDUP).run()
        Assert.assertFalse(first.passed)
        val hint = first.replayHint()
        Assert.assertTrue(hint.contains("seed=$seed"))
        Assert.assertTrue(hint.contains("cycles=4096"))
        Assert.assertTrue(hint.contains("first_failure="))
        // the replay is EXACT
        Assert.assertEquals(first.failures, second.failures)
        // and a DIFFERENT seed giveth a different trace
        val other = StressCampaign(seed = 32L, cycles = 4_096)
        val same = StressCampaign(seed = seed, cycles = 4_096)
        other.run(); same.run()
        Assert.assertNotEquals(other.inbox.values.sum(), same.inbox.values.sum())
    }

    // ------------------------------------------------------------ W11

    /** W11 -- the campaign is bounded in time, even with every fault dense. */
    @Test
    fun test_w11_the_campaign_is_bounded_in_time() {
        val started = System.nanoTime()
        val result = StressCampaign(seed = 37L).run()
        val elapsedMs = (System.nanoTime() - started) / 1_000_000
        Assert.assertTrue(result.failures.toString(), result.passed)
        Assert.assertTrue("10k cycles settled in ${elapsedMs}ms", elapsedMs < 20_000)
        val schedule = FaultSchedule.fromSeed(37L, StressCampaign.DEFAULT_CYCLES, density = 64)
        val full = StressCampaign(seed = 37L, schedule = schedule).run()
        Assert.assertTrue(full.failures.toString(), full.passed)
        Assert.assertEquals(FaultKind.ALL.toSet(), schedule.kinds())
    }

    // ------------------------------------------------------------ W12

    /** W12 -- the isles carrieth the SAME invariants and fault kinds. */
    @Test
    fun test_w12_the_isles_carry_the_same_invariants_and_faults() {
        val swift = java.io.File("../../ios/Godstone/Sources/GodstoneMesh/StressCampaign.swift")
        Assert.assertTrue("the iOS twin must exist: ${swift.path}", swift.isFile)
        val stext = swift.readText()
        for (invariant in Invariants.ALL) {
            Assert.assertTrue("the iOS twin must carry $invariant", stext.contains(invariant))
        }
        for (kind in FaultKind.ALL) {
            Assert.assertTrue("the iOS twin must carry $kind", stext.contains(kind))
        }
        val python = java.io.File("../../tools/readiness/stress.py")
        Assert.assertTrue(python.isFile)
        val ptext = python.readText()
        for (invariant in Invariants.ALL) {
            Assert.assertTrue("the conductor must carry $invariant", ptext.contains(invariant))
        }
        Assert.assertTrue(ptext.contains("10_000"))
    }

    // ------------------------------------------------------------ W13

    /** W13 -- the conductor never claimeth a device observation. */
    @Test
    fun test_w13_the_conductor_never_claimeth_a_device() {
        val python = java.io.File("../../tools/readiness/stress.py").readText()
        val code = python.lines().filterNot { it.trimStart().startsWith("#") }
            .joinToString("\n").split("\"\"\"")
            .filterIndexed { index, _ -> index % 2 == 0 }
            .joinToString("")
        for (forbidden in listOf("device", "phone", "hardware")) {
            Assert.assertFalse("the conductor must not claim a device observation ($forbidden)",
                code.lowercase().contains(forbidden))
        }
        // and the matrix keepeth the simulation apart from the device rows
        val matrix = java.io.File("../../docs/production/VERIFICATION_MATRIX.md").readText()
        Assert.assertTrue(matrix.contains("Mesh simulation regression"))
        Assert.assertTrue(matrix.contains("Simulation, not device"))
        Assert.assertTrue(matrix.contains("BLOCKED"))
    }
}
