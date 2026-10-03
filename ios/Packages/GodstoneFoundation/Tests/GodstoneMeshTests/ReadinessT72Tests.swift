// T72 readiness court (iOS isle) -- bounded production-path stress and deterministic
// fault campaigns. The twin of the python conductor and the Android court.
import XCTest
@testable import GodstoneMesh

final class ReadinessT72Tests: XCTestCase {
    // ------------------------------------------------------------ W01

    func testW01TenThousandCyclesOverMultiplePeers() {
        XCTAssertEqual(StressCampaign.defaultCycles, 10_000)
        XCTAssertGreaterThan(StressCampaign.peerCount, 1)
        let started = Date()
        let result = StressCampaign(seed: 20_260_915).run()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(result.passed, "\(result.failures)")
        XCTAssertEqual(result.cycles, 10_000)
        XCTAssertGreaterThan(result.inboxRows, 0)
        let again = StressCampaign(seed: 20_260_915).run()
        XCTAssertEqual(result.inboxRows, again.inboxRows)
        XCTAssertEqual(result.deliveryAdvances, again.deliveryAdvances)
        XCTAssertEqual(result.censusHighWater, again.censusHighWater)
        XCTAssertLessThan(elapsed, 20.0, "10k cycles must settle inside the budget")
    }

    // ------------------------------------------------------------ W02

    func testW02ZeroLeaksAfterShutdown() {
        let result = StressCampaign(seed: 7).run()
        XCTAssertTrue(result.passed, "\(result.failures)")
        XCTAssertEqual(result.leasesAfterShutdown, 0)
        XCTAssertEqual(result.timersAfterShutdown, 0)
        XCTAssertEqual(result.sessionsAfterShutdown, 0)
        let leaked = StressCampaign(seed: 7, defect: CampaignDefect.noLeaseRelease).run()
        XCTAssertFalse(leaked.passed)
        XCTAssertTrue(leaked.failures.contains { $0.contains(Invariants.noLeakedLeases) },
                      "\(leaked.failures)")
        XCTAssertGreaterThan(leaked.leasesAfterShutdown, 0)
    }

    // ------------------------------------------------------------ W03

    func testW03NoDuplicateInboxRow() {
        let campaign = StressCampaign(seed: 11, cycles: 2_000)
        let result = campaign.run()
        XCTAssertTrue(result.passed, "\(result.failures)")
        for (msg, count) in campaign.inbox {
            XCTAssertEqual(count, 1, "msg_id \(msg) entered the inbox \(count) times")
        }
        let broken = StressCampaign(seed: 11, cycles: 2_000,
                                    defect: CampaignDefect.noDedup).run()
        XCTAssertTrue(broken.failures.contains { $0.contains(Invariants.noDuplicateInbox) })
    }

    // ------------------------------------------------------------ W04

    func testW04NoDuplicateDeliveryUnderTheRetryCap() {
        let campaign = StressCampaign(seed: 13, cycles: 2_000)
        _ = campaign.run()
        for (msg, used) in campaign.retries {
            XCTAssertLessThanOrEqual(used, StressCampaign.retryCap, "msg_id \(msg)")
        }
        let broken = StressCampaign(seed: 13, cycles: 2_000,
                                    defect: CampaignDefect.noRetryCap).run()
        XCTAssertTrue(broken.failures.contains { $0.contains(Invariants.noDuplicateDelivery) })
    }

    // ------------------------------------------------------------ W05

    func testW05NoUncaughtMalformedInput() {
        let campaign = StressCampaign(seed: 17, cycles: 4_096,
                                      schedule: FaultSchedule([Fault(kind: FaultKind.malformed,
                                                                    atStep: 1_024)]))
        let result = campaign.run()
        XCTAssertTrue(result.passed, "\(result.failures)")
        XCTAssertGreaterThan(result.refusals, 0, "the malformed record must be REFUSED")
        let broken = StressCampaign(seed: 17, cycles: 4_096,
                                    defect: CampaignDefect.malformedEscapes).run()
        XCTAssertFalse(broken.passed)
        XCTAssertTrue(broken.failures.contains { $0.contains(Invariants.noUncaughtMalformed) })
        XCTAssertTrue(broken.failures[0].contains("step"))
    }

    // ------------------------------------------------------------ W06

    func testW06TheCensusPlateauIsStructural() {
        let result = StressCampaign(seed: 19, cycles: 4_000).run()
        XCTAssertTrue(result.passed, "\(result.failures)")
        let distinct = 4_000 / 4
        let bound = StressCampaign.leaseCapacity + (StressCampaign.retryCap + 1)
            + 2 * distinct + 8
        XCTAssertLessThanOrEqual(result.censusHighWater, bound)
        let long = StressCampaign(seed: 19, cycles: 10_000)
        _ = long.run()
        XCTAssertLessThanOrEqual(long.leases, StressCampaign.leaseCapacity)
        XCTAssertLessThanOrEqual(long.timers, 1)
        XCTAssertLessThanOrEqual(long.sessions, 1)
        let broken = StressCampaign(seed: 19, cycles: 10_000,
                                    defect: CampaignDefect.unboundedCensus).run()
        XCTAssertTrue(broken.failures.contains { $0.contains(Invariants.boundedCensus) })
    }

    // ------------------------------------------------------------ W07

    func testW07TheFaultScheduleIsBoundedAndDeterministic() {
        let schedule = FaultSchedule.fromSeed(3, cycles: 4_096)
        XCTAssertFalse(schedule.faults.isEmpty)
        for fault in schedule.faults {
            XCTAssertTrue(FaultKind.all.contains(fault.kind))
            XCTAssertGreaterThanOrEqual(fault.atStep, 0)
            XCTAssertLessThan(fault.atStep, 4_096)
        }
        XCTAssertEqual(schedule.faults, FaultSchedule.fromSeed(3, cycles: 4_096).faults)
        XCTAssertNotEqual(schedule.faults, FaultSchedule.fromSeed(4, cycles: 4_096).faults)
        let dense = FaultSchedule.fromSeed(23, cycles: StressCampaign.defaultCycles, density: 64)
        XCTAssertEqual(dense.kinds(), Set(FaultKind.all))
    }

    // ------------------------------------------------------------ W08

    func testW08TheFiveFaultsAreAppliedAtTheirSteps() {
        var refusals: [String: Int] = [:]
        for kind in FaultKind.all {
            let campaign = StressCampaign(seed: 23, cycles: 2_048,
                                          schedule: FaultSchedule([Fault(kind: kind, atStep: 1_024)]))
            _ = campaign.run()
            refusals[kind] = campaign.refusals
        }
        XCTAssertGreaterThan(refusals[FaultKind.diskFull] ?? 0, 0)
        XCTAssertGreaterThan(refusals[FaultKind.corruption] ?? 0, 0)
        XCTAssertGreaterThan(refusals[FaultKind.malformed] ?? 0, 0)
        let jumped = StressCampaign(seed: 23, cycles: 2_048,
                                    schedule: FaultSchedule([Fault(kind: FaultKind.clockJump,
                                                                  atStep: 1_024,
                                                                  magnitude: 3_600_000)]))
        _ = jumped.run()
        XCTAssertLessThanOrEqual(jumped.timers, 1, "a clock jump leaveth no timer standing")
    }

    // ------------------------------------------------------------ W09

    func testW09EachDefectIsCaughtByName() {
        let expected: [(String, String)] = [
            (CampaignDefect.noLeaseRelease, Invariants.noLeakedLeases),
            (CampaignDefect.noTimerRelease, Invariants.noLeakedTimers),
            (CampaignDefect.noSessionRelease, Invariants.noLeakedSessions),
            (CampaignDefect.noRetryCap, Invariants.noDuplicateDelivery),
            (CampaignDefect.noDedup, Invariants.noDuplicateInbox),
            (CampaignDefect.malformedEscapes, Invariants.noUncaughtMalformed),
            (CampaignDefect.unboundedCensus, Invariants.boundedCensus),
        ]
        for (defect, invariant) in expected {
            let result = StressCampaign(seed: 29, cycles: 4_096, defect: defect).run()
            XCTAssertFalse(result.passed, "\(defect) must fail")
            XCTAssertTrue(result.failures.contains { $0.contains(invariant) },
                          "\(defect): expected \(invariant), got \(result.failures)")
        }
        // *** EVERY MEASURED INVARIANT CARRIETH ITS OWN DEFECT -- otherwise a measured name could ride on a sibling's
        // rod (round 727). *** And the healthy run carrieth NONE of the MEASURED names: the owner-kind names are NOT
        // swept, because with the model alone they cannot be emitted at all (their measurement liveth in W15).
        XCTAssertEqual(Set(expected.map { $0.1 }), Set(Invariants.measuredFromTheModel))
        let clean = StressCampaign(seed: 29, cycles: 4_096).run()
        XCTAssertTrue(clean.passed, "\(clean.failures)")
        for invariant in Invariants.measuredFromTheModel {
            XCTAssertFalse(clean.failures.contains { $0.contains(invariant) }, invariant)
        }
    }

    /// *** W15b -- GS-STRESS-001 (round 727): THE CATEGORY AND THE UNMEASURED SET ARE CARRIED ON THE RESULT. ***
    func testW15bTheResultCarriethItsCategoryAndItsUnmeasuredSet() {
        XCTAssertEqual(Invariants.all.count, 11)
        XCTAssertEqual(Invariants.measuredFromTheModel.count, 7)
        XCTAssertEqual(Invariants.ownerKind.count, 4)
        XCTAssertEqual(Set(Invariants.measuredFromTheModel + Invariants.ownerKind), Set(Invariants.all))
        XCTAssertTrue(Set(Invariants.measuredFromTheModel).isDisjoint(with: Set(Invariants.ownerKind)))
        _ = Invariants.censusChecked()
        let result = StressCampaign(seed: 29, cycles: 64).run()
        XCTAssertEqual(result.category, Category.resourceModel)
        XCTAssertTrue(result.isResourceModel)
        XCTAssertNotEqual(result.category, Category.productionRuntime)
        XCTAssertEqual(Set(result.unmeasuredInvariants), Set(Invariants.ownerKind),
                       "with no owner handed in, every owner-kind invariant is UNMEASURED and named: "
                       + "\(result.unmeasuredInvariants)")
        // *** AND THE FAULT CAMPAIGN MUST ACTUALLY FIRE: a refusing fault beyond the horizon reddens under its OWN
        // harness token. ***
        let deaf = StressCampaign(seed: 29, cycles: 64,
                                  schedule: FaultSchedule([Fault(kind: FaultKind.diskFull, atStep: 10_000)])).run()
        XCTAssertFalse(deaf.passed)
        XCTAssertTrue(deaf.failures.contains { $0.contains(FAULT_CAMPAIGN_INACTIVE) }, "\(deaf.failures)")
        XCTAssertFalse(deaf.failures.contains { $0.contains(Invariants.noUncaughtMalformed) })
    }

    /// *** W15c -- THE SECOND OWNER ON THIS ISLE: A LEAK IN `reservations` IS NAMED, AND AN UNMEASURABLE ONE IS NOT
    /// TREATED AS CLEAN. ***
    private final class W15cReservations: ResourceCensusSource {
        let ownerName: String
        private let slots: Int
        private let reservations: Int?
        init(_ name: String, slots: Int = 0, reservations: Int?) {
            self.ownerName = name; self.slots = slots; self.reservations = reservations
        }
        func liveSessionSlots() -> Int { slots }
        func liveReservations() -> Int { reservations ?? NOT_MEASURED }
    }

    func testW15cTheReservationOwnerIsCensusedOnThisIsleToo() {
        let accused = StressCampaign(seed: 29, cycles: 64,
                                     owners: [W15cReservations("RecordWriter", reservations: 3)]).run()
        XCTAssertTrue(accused.failures.contains {
            $0.contains(Invariants.noLeakedReservations) && $0.contains("RecordWriter")
        }, "\(accused.failures)")
        XCTAssertFalse(accused.unmeasuredInvariants.contains(Invariants.noLeakedReservations))
        let measured = StressCampaign(seed: 29, cycles: 64,
                                      owners: [W15cReservations("RecordWriter", reservations: 0)]).run()
        XCTAssertFalse(measured.failures.contains { $0.contains("RecordWriter") })
        XCTAssertFalse(measured.unmeasuredOwners.contains { $0.contains("reservations") },
                       "a MEASURED clean owner must not be listed as unmeasured: \(measured.unmeasuredOwners)")
        // AND THE DEFAULT IS THE HONEST ONE: an owner that overrideth nothing is NOT_MEASURED, never a false zero.
        let unmeasured = StressCampaign(seed: 29, cycles: 64,
                                        owners: [W15cReservations("TimerWheel", reservations: nil)]).run()
        XCTAssertTrue(unmeasured.unmeasuredOwners.contains { $0.contains("TimerWheel") },
                      "\(unmeasured.unmeasuredOwners)")
        XCTAssertFalse(unmeasured.failures.contains { $0.contains("TimerWheel") })
    }

    // ------------------------------------------------------------ W10

    func testW10AFailedSeedIsRecordedAndReproducible() {
        let seed: Int64 = 31
        let first = StressCampaign(seed: seed, cycles: 4_096,
                                   defect: CampaignDefect.noDedup).run()
        let second = StressCampaign(seed: seed, cycles: 4_096,
                                    defect: CampaignDefect.noDedup).run()
        XCTAssertFalse(first.passed)
        let hint = first.replayHint()
        XCTAssertTrue(hint.contains("seed=\(seed)"))
        XCTAssertTrue(hint.contains("cycles=4096"))
        XCTAssertTrue(hint.contains("first_failure="))
        XCTAssertEqual(first.failures, second.failures, "the replay must be EXACT")
        let other = StressCampaign(seed: 32, cycles: 4_096)
        let same = StressCampaign(seed: seed, cycles: 4_096)
        _ = other.run(); _ = same.run()
        XCTAssertNotEqual(other.inbox.values.reduce(0, +), same.inbox.values.reduce(0, +))
    }

    // ------------------------------------------------------------ W11

    func testW11TheCampaignIsBoundedInTime() {
        let started = Date()
        let result = StressCampaign(seed: 37).run()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(result.passed, "\(result.failures)")
        XCTAssertLessThan(elapsed, 20.0)
        let schedule = FaultSchedule.fromSeed(37, cycles: StressCampaign.defaultCycles, density: 64)
        let full = StressCampaign(seed: 37, schedule: schedule).run()
        XCTAssertTrue(full.passed, "\(full.failures)")
        XCTAssertEqual(schedule.kinds(), Set(FaultKind.all))
    }

    // ------------------------------------------------------------ W12/W13

    /// *** W12/W13 ARE THE TWIN COURTS' TO EXECUTE, AND THIS ISLE NO LONGER COPIES THEIR SOURCE TEXT (round 727). ***
    ///
    /// *MEASURED: this arm read the Kotlin and python FILES and asserted `contains(name)` -- a source-body read is NOT
    /// semantic proof, and it stayed GREEN while the python isle emitted none of the four owner-kind invariants. The
    /// matrix arm re-read `docs/production/VERIFICATION_MATRIX.md` (a file this task does not own) and asserted strings
    /// belonging to UNRELATED rows. Both are DELETED rather than re-pinned: the twins' own courts
    /// (`ReadinessT72Test`, `tools/readiness/tests/test_t72.py`) and the matrix's own gate are the executable
    /// contracts, and each asserts the same names against its OWN model.*
    ///
    /// THE CONSUMER-VISIBLE FACTS THIS ISLE'S COURT KEEPS ARE ITS OWN: `result.category`, the carried unmeasured set,
    /// the per-owner defects, and the real-owner reservation census (W15b/W15c below).

    // ------------------------------------------------------------ W14

    /// *** GS-STRESS-001 step 1 ON THE **SECOND** ISLE. The card: "Keep the current class under an explicitly named
    /// resource-model test category." A campaign whose counters describe its own model must never be read as a
    /// production stress result -- and the honest way to keep that so is to NAME the category where the result is
    /// read, and to ASSERT it HERE, on this isle, not merely on the Android one.
    ///
    /// MEASURED at round 521: before this arm, the iOS isle carrieth NO name at all -- a reader consulting this isle's
    /// T72 evidence could take a model result for a runtime result and had no way to learn otherwise. A CATEGORY THAT
    /// HOLDETH ON ONE ISLE IS NOT A CATEGORY.
    func testW14TheCampaignIsANamedResourceModel() {
        XCTAssertEqual(RESOURCE_MODEL_CATEGORY, "resource-model",
                       "the campaign must declare its CATEGORY by name, so no reader mistaketh a model for a runtime")
        XCTAssertNotEqual(RESOURCE_MODEL_CATEGORY, "production",
                          "and it must NOT be named for the production runtime it doth not measure")
    }

    // ------------------------------------------------------------ W15

    /**
     * *** GS-STRESS-001 STEP 3 ON THE **SECOND** ISLE: THE SESSION INVARIANT IS ASKED OF A REAL OWNER, AND NAMETH IT. ***
     *
     * MEASURED AT ROUND 535: THIS ISLE CARRIED NO OWNER CENSUS AT ALL while Android hath carried one since round 521
     * -- **A CONTRACT THE HUMAN'S LAW REQUIREth ON BOTH ISLES WAS MET ON ONE.** This arm is the mirror of Android's
     * `test_w14_the_session_invariant_is_asked_of_a_real_owner`, clause for clause.
     *
     * THE ARM HOLDS A **REAL** `SessionManager` SLOT -- driv'n through the manager's OWN handshake ladder, the idiom
     * `SessionManagerConcurrencyTests` owneth -- and asketh the campaign about it. BOTH clauses read a REAL owner
     * through `slotCountForTest()`, so neither is a stub:
     *   CLAUSE 1 -- the live slot is reported, and the failure NAMETH the owner that holdeth it;
     *   CLAUSE 2 -- THE DISCRIMINATOR: a SECOND real `SessionManager`, never handshaken, retaineth nothing, and the
     *               selfsame campaign accuseth NOBODY -- so clause 1 is not a clause that fireth for anything.
     */
    private final class W15Keychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    private final class W15TrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult { .accepted }
    }

    func testW15TheSessionInvariantIsAskedOfARealOwnerAndNamethIt() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: W15Keychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: W15Keychain())
        let live = SessionManager(identity: identityA, trustAuthority: W15TrustAuthority())
        let peerSide = SessionManager(identity: identityB, trustAuthority: W15TrustAuthority())

        // A REAL handshake, through the managers' OWN ladder: hs1 -> hs2 -> hs3 -> sealed.
        let peerB = UUID()
        let peerA = UUID()
        let hs1 = try XCTUnwrap(live.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(peerSide.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(live.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))
        XCTAssertTrue(peerSide.responderProcessHs3(peerA, hs3: hs3, advertisedRemoteHint: identityA.nodeHint),
                      "the REAL handshake must seal")
        XCTAssertGreaterThan(live.slotCountForTest(), 0, "a REAL slot must stand in the real owner")

        let adapter = W15Census(ownerName: "SessionManager", slots: { live.slotCountForTest() })

        // CLAUSE 1 -- THE INVARIANT IS ASKED OF THE REAL OWNER, AND NAMETH IT.
        let accused = StressCampaign(seed: 7, cycles: 64, owners: [adapter]).run()
        XCTAssertTrue(accused.failures.contains {
            $0.contains(Invariants.noLeakedSessions) && $0.contains("SessionManager")
        }, "a REAL live slot must be reported against the owner that holdeth it: \(accused.failures)")

        // CLAUSE 2 -- THE DISCRIMINATOR, ALSO A REAL OWNER: a second manager never handshaken retaineth nothing,
        // and the selfsame campaign must accuse NOBODY.
        let fresh = SessionManager(identity: try MeshIdentity.generateAndStore(keychain: W15Keychain()),
                                   trustAuthority: W15TrustAuthority())
        XCTAssertEqual(fresh.slotCountForTest(), 0,
                       "the discriminator's premise must be MEASURED, not assumed")
        let clean = W15Census(ownerName: "SessionManager", slots: { fresh.slotCountForTest() })
        let clear = StressCampaign(seed: 7, cycles: 64, owners: [clean]).run()
        XCTAssertTrue(clear.failures.allSatisfy { !$0.contains("REAL owner") },
                      "a real owner that retained nothing must NOT be accused: \(clear.failures)")
    }

    /// The adapter the arm hands the campaign: the owner's OWN hook, never a copy the campaign keepeth.
    private final class W15Census: ResourceCensusSource {
        let ownerName: String
        private let slots: () -> Int
        init(ownerName: String, slots: @escaping () -> Int) {
            self.ownerName = ownerName
            self.slots = slots
        }
        func liveSessionSlots() -> Int { slots() }
    }

}
