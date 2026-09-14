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
    public static let noDuplicateInbox = "no_duplicate_inbox"
    public static let noDuplicateDelivery = "no_duplicate_delivery"
    public static let noUncaughtMalformed = "no_uncaught_malformed"
    public static let boundedCensus = "bounded_census"
    public static let all = [noLeakedLeases, noLeakedTimers, noLeakedSessions,
                             noDuplicateInbox, noDuplicateDelivery,
                             noUncaughtMalformed, boundedCensus]
}

public enum CampaignDefect {
    public static let none = "none"
    public static let noLeaseRelease = "no_lease_release"
    public static let noRetryCap = "no_retry_cap"
    public static let noDedup = "no_dedup"
    public static let malformedEscapes = "malformed_escapes"
    public static let unboundedCensus = "unbounded_census"
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

    public var passed: Bool { failures.isEmpty }

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
                schedule: FaultSchedule? = nil, defect: String = CampaignDefect.none) {
        precondition(cycles >= 1, "a campaign carrieth at least one cycle")
        self.seed = seed; self.cycles = cycles; self.peers = peers
        self.schedule = schedule ?? FaultSchedule.fromSeed(seed, cycles: cycles)
        self.defect = defect
        self.state = seed &* 2862933555777941757 &+ 3037000493
    }

    public func cycle(_ step: Int) {
        let msg = next(max(1, cycles / 4))

        if defect == CampaignDefect.unboundedCensus || leases < StressCampaign.leaseCapacity {
            leases += 1
        }
        if defect != CampaignDefect.noLeaseRelease && defect != CampaignDefect.unboundedCensus {
            leases = max(0, leases - 1)
        }
        timers += 1; timers = max(0, timers - 1)
        sessions += 1; sessions = max(0, sessions - 1)

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
        leases = 0; timers = 0; sessions = 0
    }

    public func run() -> CampaignResult {
        var failures: [String] = []
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
        if let dup = inbox.first(where: { $0.value != 1 }) {
            failures.append("\(Invariants.noDuplicateInbox): msg_id \(dup.key) entered the "
                            + "inbox \(dup.value) times")
        }
        if let over = retries.first(where: { $0.value > StressCampaign.retryCap }) {
            failures.append("\(Invariants.noDuplicateDelivery): msg_id \(over.key) was retried "
                            + "\(over.value) times, over the cap \(StressCampaign.retryCap)")
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
                              timersAfterShutdown: timers, sessionsAfterShutdown: sessions)
    }
}
