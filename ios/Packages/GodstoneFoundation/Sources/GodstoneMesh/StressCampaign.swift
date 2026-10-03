import Foundation

// ---------------------------------------------------------------------------
// T72 -- bounded production-path stress and deterministic fault campaigns (iOS
// isle). The twin of tools/readiness/stress.py and of the Android StressCampaign:
// the SAME invariants, the SAME fault kinds, the SAME bounds.
//
// A campaign runneth from an EXPLICIT SEED, every fault is scheduled at an explicit
// step, and a red run recordeth its seed and failing step so it can be replayed
// exactly. A red run that cannot be replayed is a rumour, not evidence.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// GS-STRESS-001 step 1: THE CATEGORY THIS CAMPAIGN BELONGETH TO, NAMED WHERE IT LIVETH.
//
// `StressCampaign` MEASURES A **RESOURCE MODEL**, NOT THE PRODUCTION RUNTIME: its counters describe ITS OWN local
// bookkeeping -- the card's step 6 sayeth so in its own words ('a mutation confined to StressCampaign's local
// bookkeeping') -- so a result from here is evidence about THE MODEL'S INVARIANTS and never about a real device,
// radio or store. THE AUDIT'S DISCIPLINE IS THAT SUCH A RESULT MUST NOT BE RELABELLED, AND ITS FIRST LINE IS TO NAME
// THE CATEGORY WHERE IT LIVETH.
//
// *** THIS IS STEP 1 ON THE **SECOND** ISLE, AND THAT IS WHY IT IS HERE. MEASURED at round 521: the Android isle
// named this category at `StressCampaign.kt:14`, and the string appeared NOWHERE ELSE IN THE REPOSITORY -- grepped
// across every `.swift`, `.py` and `.kt`. A READER CONSULTING THE iOS EVIDENCE MET NO NAME AT ALL, so a result from
// this isle could be read as a production stress result by a reader who had no way to learn otherwise. A CATEGORY
// THAT HOLDETH ON ONE ISLE IS NOT A CATEGORY; the human's phase-two law requireth the shared contract on BOTH.
//
// THE NAME IS DELIBERATELY THE SAME SPELLING AS THE ANDROID AND PYTHON TWINS, in breach of this isle's usual camelCase
// habit, SO THAT ONE GREP FOR `RESOURCE_MODEL_CATEGORY` FINDETH THE CONTRACT ON EVERY ISLE -- a contract a reader must
// already know the spelling of is a contract that will be missed.
// ---------------------------------------------------------------------------
public let RESOURCE_MODEL_CATEGORY: String = "resource-model"

/// *** WHERE A RESULT SAYETH WHAT IT IS (round 727). ***
///
/// `RESOURCE_MODEL_CATEGORY` is the NAME of this campaign's category; `Category.resourceModel` is the VALUE a
/// `CampaignResult` carrieth, and `Category.productionRuntime` is the category it MUST NEVER claim. *MEASURED: the
/// constant was declared here and asserted against ITSELF in a court while appearing in NO result field and NO report
/// -- a name a reader of a RESULT never meeteth.*
public enum Category {
    public static let resourceModel = RESOURCE_MODEL_CATEGORY
    public static let productionRuntime = "production-runtime"
}

/**
 * *** A HARNESS-INTEGRITY TOKEN, NOT ONE OF THE ELEVEN NAMED INVARIANTS. *** *The fault-liveness clause reporteth that
 * the SCHEDULE did not fire -- a property of the harness, not of a runtime owner -- so it carrieth its own name rather
 * than masquerading as `no_uncaught_malformed`.*
 */
public let FAULT_CAMPAIGN_INACTIVE: String = "fault_campaign_inactive"

/// *** THE SENTINEL FOR AN OWNER WHOSE KIND A SEAM CANNOT CENSUS -- NEVER COUNTED AS ZERO. *** Spelled as the Android
/// isle spell it (`ResourceCensusSource.NOT_MEASURED`), so ONE GREP FINDETH THE CONTRACT ON EVERY ISLE.
public let NOT_MEASURED: Int = -1

/**
 * *** GS-STRESS-001 STEP 3 (round 535): THE OWNER CENSUS -- **THE SWIFT TWIN**, BECAUSE THE CONTRACT IS SHARED. ***
 *
 * THE CARD'S OWN WORDS: *'Read resource census from the owners that allocate timers, writer reservations, SESSIONS,
 * observers, inventory leases, ACK work and database rows.'*
 *
 * MEASURED BEFORE THIS WAS ADDED, AND IT IS WHY IT EXISTETH: the Android isle hath carried an owner census since
 * round 521 (`io.godstone.mesh.stress.ResourceCensusSource`) while **THIS ISLE CARRIED NONE AT ALL** -- a grep for
 * any owner or census concept in this file returned only the `censusHighWater` FIELD. **SO A CONTRACT THE HUMAN'S
 * LAW REQUIREth ON *BOTH* ISLES WAS MET ON ONE**, which is an asymmetry of the exact kind the audit's own
 * method is built to find.
 *
 * WHY A SEAM RATHER THAN A SECOND COUNTER: a number only the campaign can move is evidence about the campaign, and
 * **NO MUTATION OF THE CAMPAIGN'S OWN BOOKKEEPING CAN EVER FALSIFY AN INVARIANT ABOUT A RUNTIME**. An owner
 * answereth through **ITS OWN** evidence hook (`SessionManager.slotCountForTest()`), so the number is the OWNER'S.
 *
 * THE NAMES ARE THE ANDROID ISLE'S, SPELLED THE SAME WAY, so that ONE GREP FINDETH THE CONTRACT ON EVERY ISLE.
 */
public protocol ResourceCensusSource: AnyObject {
    /// The owner's own name, so a failure can NAME whom it accuseth rather than saying 'sessions'.
    var ownerName: String { get }

    /// How many live session slots the REAL owner holdeth RIGHT NOW, read through its own evidence hook.
    func liveSessionSlots() -> Int

    /// *** GS-STRESS-001 (round 727): THE SECOND OWNER, ASKED OF THIS ISLE TOO. ***
    ///
    /// *MEASURED: this protocol carrieth ONE hook, so six of the eleven invariant names on this isle were
    /// DECLARATIONS ONLY -- `noLeakedReservations` among them, and the ONLY iOS conformance used `liveSessionSlots` to
    /// report a QUARANTINE count under the sessions invariant.* `liveReservations` asketh the reservation owner the
    /// project already made askable (`RecordWriter.reservedCountForTest()`), and its DEFAULT IS THE HONEST ONE: an
    /// owner that carrieth no reservations answereth `NOT_MEASURED`, NOT 0 -- *"nothing is leaking"* and *"nobody asked
    /// my kind of owner"* are different answers.* The remaining owner-kind names stay in `Invariants.ownerKind` and
    /// are carried as unmeasured until their owners are made askable (do NOT claim a census this seam cannot take).
    ///
    /// The sentinel is spelled `NOT_MEASURED`, the Android isle's own name, so ONE GREP FINDETH IT ON EVERY ISLE.
    func liveReservations() -> Int
}

public extension ResourceCensusSource {
    /// The default is NOT_MEASURED, never zero: a kind this seam cannot census is named, not reported clean.
    func liveReservations() -> Int { NOT_MEASURED }
}

public enum FaultKind {
    public static let clockJump = "clock_jump"
    public static let diskFull = "disk_full"
    public static let corruption = "corruption"
    public static let slowAtt = "slow_att"
    public static let malformed = "malformed"
    public static let all = [clockJump, diskFull, corruption, slowAtt, malformed]
}

/// The invariant ids: a failure NAMETH the invariant it broke.
public enum Invariants {
    public static let noLeakedLeases = "no_leaked_leases"
    public static let noLeakedTimers = "no_leaked_timers"
    public static let noLeakedSessions = "no_leaked_sessions"
    // *** GS-STRESS-001 (round 727): THE FOUR OWNERS THIS ISLE DID NOT NAME -- AND THE COURT ALREADY SAID SO. ***
    //
    // **`ReadinessT72Test.test_w12_the_isles_carry_the_same_invariants_and_faults` ASSERTETH THAT THE TWO ISLES CARRY THE
    // SAME INVARIANTS, AND IT WAS FAILING: `"the iOS twin must carry no_leaked_reservations"`.** *Android had grown to
    // TWELVE names across rounds 643/651/671 while this isle stayed at EIGHT* -- **so the cross-isle contract the court
    // enforce th was already broken, and the court was the instrument that said so.** *Measured by comparing the quoted
    // name sets on both isles: Android carrieth `no_leaked_reservations`, `no_leaked_inventory_leases`,
    // `pending_ack_work` and `no_leaked_observers`; this isle carried NONE of them.*
    /** Writer reservations -- one of the card's named owners. */
    public static let noLeakedReservations = "no_leaked_reservations"
    /** Admitted inventory leases -- the card's own term. */
    public static let noLeakedInventoryLeases = "no_leaked_inventory_leases"
    /** Pending ACK obligations: work the system owed and did not discharge. */
    public static let pendingAckWork = "pending_ack_work"
    /** Observer registrations, which name their OWNER because the two owners share the NAME `observers`. */
    public static let noLeakedObservers = "no_leaked_observers"
    public static let noDuplicateInbox = "no_duplicate_inbox"
    public static let noDuplicateDelivery = "no_duplicate_delivery"
    public static let noUncaughtMalformed = "no_uncaught_malformed"
    public static let boundedCensus = "bounded_census"
    /** *** AND THE LIST IS COMPLETED -- it named SEVEN of the ELEVEN names above, the same stale-list shape as Android's. *** */
    public static let all = [noLeakedLeases, noLeakedTimers, noLeakedSessions,
                             noLeakedReservations, noLeakedInventoryLeases,
                             pendingAckWork, noLeakedObservers,
                             noDuplicateInbox, noDuplicateDelivery,
                             noUncaughtMalformed, boundedCensus]
    /// How many invariant names this enum DEFINETH -- the census `all` must reproduce. *A load-time check rather than a
    /// court, because the defect it preventeth is IN THIS FILE: the name and the list stand lines apart, and only their
    /// COUNT can tell whether they agree.*
    private static let definedCount = 11
    /// *** GS-STRESS-001 (round 727): WHAT THIS MODEL MEASURES, AND WHAT IT EMITS ONLY THROUGH A REAL OWNER. ***
    /// *MEASURED by the read-only audit: this isle's `ResourceCensusSource` carrieth ONE hook, so four of the eleven
    /// names could never be emitted here at all -- and the court looped over `Invariants.all` asserting they were
    /// absent from a healthy run, which was TRUE BY CONSTRUCTION. A check that cannot fail is not a check.* The split
    /// is typed here and CARRIED on the result (`unmeasuredInvariants`), so "nothing is leaking" and "nobody asked my
    /// kind of owner" are distinguishable by any reader.
    public static let measuredFromTheModel = [noLeakedLeases, noLeakedTimers, noLeakedSessions,
                                              noDuplicateInbox, noDuplicateDelivery,
                                              noUncaughtMalformed, boundedCensus]
    public static let ownerKind = [noLeakedReservations, noLeakedInventoryLeases,
                                   pendingAckWork, noLeakedObservers]
    private static let censusCheck: Void = {
        precondition(all.count == definedCount,
                     "Invariants.all carrieth \(all.count) of the \(definedCount) defined invariants -- a name was " +
                     "added without being listed, which is how four owners went unmeasured (GS-STRESS-001, round 727).")
        precondition(Set(all).count == all.count, "Invariants.all carrieth a duplicate")
        precondition(Set(measuredFromTheModel + ownerKind) == Set(all),
                     "the model/owner split must cover Invariants.all exactly")
        precondition(Set(measuredFromTheModel).isDisjoint(with: Set(ownerKind)),
                     "a name cannot be both model- and owner-kind")
    }()
    /// Touch to run the census check.
    public static func censusChecked() -> Int { _ = censusCheck; return all.count }
}

public enum CampaignDefect {
    public static let none = "none"
    public static let noLeaseRelease = "no_lease_release"
    public static let noRetryCap = "no_retry_cap"
    public static let noDedup = "no_dedup"
    public static let malformedEscapes = "malformed_escapes"
    public static let unboundedCensus = "unbounded_census"
    /// *** ONE DEFECT PER LIFECYCLE OWNER (round 727). *** *MEASURED: the timer and session clauses had NO defect of
    /// their own -- only `noLeaseRelease` (named for leases) kept them standing. A lifecycle owner that cannot be
    /// leaked alone is an owner whose invariant is not really measured.*
    public static let noTimerRelease = "no_timer_release"
    public static let noSessionRelease = "no_session_release"
    /// The defects the court requireth to be CAUGHT, one per invariant family.
    public static let all = [noLeaseRelease, noTimerRelease, noSessionRelease, noRetryCap, noDedup,
                             malformedEscapes, unboundedCensus]
}

public struct Fault: Sendable, Equatable {
    public let kind: String
    public let atStep: Int
    public let magnitude: Int64

    public init(kind: String, atStep: Int, magnitude: Int64 = 0) {
        precondition(FaultKind.all.contains(kind), "unknown fault kind \(kind)")
        precondition(atStep >= 0, "a fault is scheduled at a non-negative step")
        self.kind = kind; self.atStep = atStep; self.magnitude = magnitude
    }
}

/// A BOUNDED, deterministic schedule: the same seed giveth the same faults.
public struct FaultSchedule: Sendable {
    public let faults: [Fault]

    public init(_ faults: [Fault] = []) { self.faults = faults }

    public func at(_ step: Int) -> [Fault] { faults.filter { $0.atStep == step } }
    public func kinds() -> Set<String> { Set(faults.map { $0.kind }) }

    public static let density = 512

    public static func fromSeed(_ seed: Int64, cycles: Int,
                                density: Int = FaultSchedule.density) -> FaultSchedule {
        // a small deterministic generator: the campaign must be reproducible on
        // EVERY isle, so it must not depend on a platform RNG
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let shifted = Int(truncatingIfNeeded: state >> 33)
            let modulo = ((shifted % bound) + bound) % bound
            return modulo
        }
        let magnitudes: [Int64] = [1, 2, 8, 64, 250, 3_600_000]
        var scheduled: [Fault] = []
        var step = density
        while step < cycles {
            scheduled.append(Fault(kind: FaultKind.all[next(FaultKind.all.count)],
                                   atStep: step, magnitude: magnitudes[next(magnitudes.count)]))
            step += density
        }
        return FaultSchedule(scheduled)
    }
}

public struct CampaignResult: Sendable {
    public let seed: Int64
    public let cycles: Int
    public let failures: [String]
    public let censusHighWater: Int
    public let inboxRows: Int
    public let deliveryAdvances: Int
    public let refusals: Int
    public let leasesAfterShutdown: Int
    public let timersAfterShutdown: Int
    public let sessionsAfterShutdown: Int
    /// *** GS-STRESS-001 (round 727): THE OWNERS THIS CENSUS COULD NOT ASK, AND THE INVARIANTS THAT WENT UNMEASURED. ***
    /// *MEASURED: this struct ended at `sessionsAfterShutdown` -- NO `unmeasuredOwners`, no sentinel, no split -- so on
    /// this isle "nothing is leaking" and "nobody asked my kind of owner" were INDISTINGUISHABLE. The Android isle
    /// armed the opposite, and this isle now carrieth the same distinction.*
    public let unmeasuredOwners: [String]
    public let unmeasuredInvariants: [String]
    /// The category this result belongeth to -- `resource-model`, and NEVER the production runtime.
    public let category: String

    public var passed: Bool { failures.isEmpty }

    public var isResourceModel: Bool { category == Category.resourceModel }

    public func replayHint() -> String {
        "seed=\(seed) cycles=\(cycles) first_failure=\(failures.first ?? "none")"
    }
}

public final class StressCampaign {
    public static let defaultCycles = 10_000
    public static let peerCount = 8
    public static let leaseCapacity = 64
    public static let retryCap = 3

    public let seed: Int64
    public let cycles: Int
    public let peers: Int
    public let schedule: FaultSchedule
    public let defect: String
    /// GS-STRESS-001 step 3 (round 535): the real owners this campaign shall ask, if any were given.
    public let owners: [any ResourceCensusSource]

    private var state: Int64
    private func next(_ bound: Int) -> Int {
        state = state &* 2862933555777941757 &+ 3037000493
        let shifted = Int(truncatingIfNeeded: state >> 33)
        return ((shifted % bound) + bound) % bound
    }

    public private(set) var leases = 0
    public private(set) var timers = 0
    public private(set) var sessions = 0
    public private(set) var refusals = 0
    public private(set) var inbox: [Int: Int] = [:]
    public private(set) var delivery: [Int: Int] = [:]
    public private(set) var retries: [Int: Int] = [:]

    public init(seed: Int64, cycles: Int = StressCampaign.defaultCycles,
                peers: Int = StressCampaign.peerCount,
                schedule: FaultSchedule? = nil, defect: String = CampaignDefect.none,
                /// *** GS-STRESS-001 step 3: THE REAL OWNERS THIS CAMPAIGN SHALL ASK. ***
                /// EMPTY BY DEFAULT, so nothing that stood before this finding changeth behaviour -- the campaign
                /// remaineth the resource model it was. Where an owner IS given, the session invariant is asked OF
                /// IT, through the owner's own hook, AND THE FAILURE NAMETH IT.
                owners: [any ResourceCensusSource] = []) {
        precondition(cycles >= 1, "a campaign carrieth at least one cycle")
        self.seed = seed; self.cycles = cycles; self.peers = peers
        self.schedule = schedule ?? FaultSchedule.fromSeed(seed, cycles: cycles)
        self.defect = defect
        // AND THE OWNERS ARE KEPT: a seam that the initializer DROPPETH is a seam no campaign ever asketh, and the
        // COMPILER named exactly this omission ("return from initializer without initializing all stored
        // properties") -- WHICH IS WHY A DECLARATION IS NOT A CAPABILITY.
        self.owners = owners
        self.state = seed &* 2862933555777941757 &+ 3037000493
    }

    public func cycle(_ step: Int) {
        let msg = next(max(1, cycles / 4))

        // A SHUTDOWN ARRIVETH WITH WORK IN FLIGHT: the final cycle leaveth its
        // resources HELD, so "shutdown releaseth everything" is a real law
        let inFlight = step >= cycles - 1

        if defect == CampaignDefect.unboundedCensus || leases < StressCampaign.leaseCapacity {
            leases += 1
        }
        if !inFlight && defect != CampaignDefect.noLeaseRelease
            && defect != CampaignDefect.unboundedCensus {
            leases = max(0, leases - 1)
        }
        timers += 1
        if !inFlight && defect != CampaignDefect.noTimerRelease { timers = max(0, timers - 1) }
        sessions += 1
        if !inFlight && defect != CampaignDefect.noSessionRelease { sessions = max(0, sessions - 1) }

        if defect == CampaignDefect.noDedup || inbox[msg] == nil {
            inbox[msg] = (inbox[msg] ?? 0) + 1
        }
        let used = retries[msg] ?? 0
        if defect == CampaignDefect.noRetryCap || used < StressCampaign.retryCap {
            delivery[msg] = (delivery[msg] ?? 0) + 1
            retries[msg] = used + 1
        }

        for fault in schedule.at(step) { apply(fault) }
    }

    /// A malformed record is REFUSED -- unless the defect saith it escapeth.
    public func apply(_ fault: Fault) {
        switch fault.kind {
        case FaultKind.clockJump:
            timers = min(timers, 1)
        case FaultKind.slowAtt:
            timers = max(0, timers - 1)
        default:
            refusals += 1
        }
        if fault.kind == FaultKind.malformed && defect == CampaignDefect.malformedEscapes {
            // the escape is RECORDED by run(), never left to kill the process
            escapedAt = lastStep
        }
    }

    private var lastStep = 0
    private var escapedAt: Int?

    public func shutdown() {
        if defect == CampaignDefect.noLeaseRelease { return }
        if defect != CampaignDefect.noTimerRelease { timers = 0 }
        if defect != CampaignDefect.noSessionRelease { sessions = 0 }
        leases = 0
    }

    public func run() -> CampaignResult {
        var failures: [String] = []
        var unmeasuredOwners: [String] = []
        // *** THE INVARIANTS THIS RUN COULD NOT MEASURE, CARRIED RATHER THAN ABSENT (round 727). *** This isle's
        // protocol carrieth only the session hook plus the reservation hook; the other owner-kind names in
        // `Invariants.ownerKind` (inventory leases, ACK work, observers) have NO hook here at all -- and with no owner
        // handed in, NONE of them can be asked. They are named, so a reader cannot take the empty failure list for a
        // clean census.
        var unmeasuredInvariants: [String] = [Invariants.noLeakedInventoryLeases,
                                              Invariants.pendingAckWork, Invariants.noLeakedObservers]
        if owners.isEmpty { unmeasuredInvariants.insert(Invariants.noLeakedReservations, at: 0) }
        var censusHigh = 0
        var step = 0
        while step < cycles {
            lastStep = step
            cycle(step)
            if let escaped = escapedAt {
                failures.append("\(Invariants.noUncaughtMalformed): the malformed record "
                                + "escaped the loop at step \(escaped)")
                break
            }
            censusHigh = max(censusHigh, leases + timers + sessions + inbox.count + delivery.count)
            step += 1
        }
        shutdown()
        let distinct = max(1, cycles / 4)
        let bound = StressCampaign.leaseCapacity + (StressCampaign.retryCap + 1)
            + 2 * distinct + 8
        if leases != 0 {
            failures.append("\(Invariants.noLeakedLeases): \(leases) lease(s) leaked after shutdown")
        }
        if timers != 0 {
            failures.append("\(Invariants.noLeakedTimers): \(timers) timer(s) leaked after shutdown")
        }
        if sessions != 0 {
            failures.append("\(Invariants.noLeakedSessions): \(sessions) session(s) leaked after shutdown")
        }
        // *** GS-STRESS-001 step 3: AND THE INVARIANT IS ASKED OF THE REAL OWNERS. The clause above readeth the
        // MODEL'S OWN integer, which only this campaign can move -- so it cannot be falsified by a real leak, and a
        // model that agreeth with itself is not evidence about a runtime. THE NUMBERS BELOW ARE THE OWNERS' OWN,
        // read through the owners' evidence hooks, and a failure NAMETH the owner it accuseth.
        // IT IS ASKED AFTER `shutdown()` (above), because the question is whether the owner RETAINED anything. ***
        for owner in owners {
            let live = owner.liveSessionSlots()
            if live != 0 {
                failures.append("\(Invariants.noLeakedSessions): \(live) session slot(s) still live in the REAL "
                    + "owner '\(owner.ownerName)' after shutdown")
            }
            // *** GS-STRESS-001 (round 727): THE SECOND OWNER, ASKED OF THIS ISLE TOO -- AND AN UNMEASURABLE ONE IS
            // NAMED, NOT TREATED AS CLEAN. *** `liveReservations`' DEFAULT is `NOT_MEASURED`, so an owner that carrieth
            // no reservations is NEVER a false zero. A leak in this kind was previously reported (if at all) under the
            // SESSIONS invariant by the only existing conformance; it now carrieth its own name.
            let reservations = owner.liveReservations()
            if reservations == NOT_MEASURED {
                unmeasuredOwners.append("\(owner.ownerName) (reservations)")
                unmeasuredInvariants.append(Invariants.noLeakedReservations)
            } else if reservations != 0 {
                failures.append("\(Invariants.noLeakedReservations): \(reservations) writer reservation(s) still live "
                    + "in the REAL owner '\(owner.ownerName)' after shutdown")
            }
        }
        // GS-STRESS-001 (round 274): THE REPORTED INSTANCE IS CANONICAL, AND THIS IS A WITNESS REPAIR RATHER
        // THAN A BEHAVIOURAL ONE. `first(where:)` over a Dictionary chooseth WHICHEVER offending entry the
        // table's ITERATION ORDER presenteth first, so two runs of the SAME seed could name DIFFERENT msg_ids
        // while agreeing in every measured quantity -- which is exactly what the probe measured (inboxRows
        // 4096, deliveryAdvances 2701, refusals 6, census 2001, leases 0 in BOTH runs, and only the NAMED id
        // differing). The replay hint is the campaign's own promise, and a hint that nameth an arbitrary
        // instance is not that promise kept. The SMALLEST offending key is chosen instead, so the message is
        // a function of the CAMPAIGN and not of a hash table's order.
        if let dup = inbox.filter({ $0.value != 1 }).min(by: { $0.key < $1.key }) {
            failures.append("\(Invariants.noDuplicateInbox): msg_id \(dup.key) entered the "
                            + "inbox \(dup.value) times")
        }
        if let over = retries.filter({ $0.value > StressCampaign.retryCap }).min(by: { $0.key < $1.key }) {
            failures.append("\(Invariants.noDuplicateDelivery): msg_id \(over.key) was retried "
                            + "\(over.value) times, over the cap \(StressCampaign.retryCap)")
        }
        // *** THE FAULT CAMPAIGN MUST ACTUALLY HAVE FIRED A REFUSING FAULT (round 727). *** *MEASURED: nothing
        // asserted a scheduled fault was ever APPLIED -- the default density of 512 giveth an EMPTY schedule under 512
        // cycles, and the T72 owner arm ran 64 cycles with zero faults.*
        let refusalsExpected = schedule.faults.filter {
            $0.kind == FaultKind.diskFull || $0.kind == FaultKind.corruption || $0.kind == FaultKind.malformed
        }.count
        if refusalsExpected > 0 && refusals < refusalsExpected {
            failures.append("\(FAULT_CAMPAIGN_INACTIVE): \(refusalsExpected) refusing fault(s) were scheduled but "
                + "only \(refusals) were refused -- the fault campaign did not fire")
        }
        if censusHigh > bound {
            failures.append("\(Invariants.boundedCensus): the census reached \(censusHigh), "
                            + "over the plateau \(bound)")
        }
        return CampaignResult(seed: seed, cycles: cycles, failures: failures,
                              censusHighWater: censusHigh,
                              inboxRows: inbox.values.reduce(0, +),
                              deliveryAdvances: delivery.values.reduce(0, +),
                              refusals: refusals, leasesAfterShutdown: leases,
                              timersAfterShutdown: timers, sessionsAfterShutdown: sessions,
                              unmeasuredOwners: unmeasuredOwners,
                              unmeasuredInvariants: unmeasuredInvariants,
                              category: Category.resourceModel)
    }
}
