import Foundation

/// IOS-05 / T27 (the card's steps 1 and 2) -- THE PRE-AUTH ADMISSION BUDGET, the iOS twin of
/// `android/mesh/src/main/java/io/godstone/mesh/transport/AdmissionBudget.kt` (sealed at T26).
///
/// The audited iOS isle chargeth NOTHING at its ingress: `PeerGovernor` is referenced NOWHERE in
/// production except one comment, so raw air traffic, malformed values and values from addresses with no
/// relation are all free work. This budget is charged AT THE REAL DOORS, BEFORE parsing, reassembly,
/// DH or trust work -- the card's own words -- and it is charged whatever arriveth: an empty value, a
/// malformed one, an unknown type, an over-sized one, an advertisement.
///
/// TWO SCOPES, because one bound cannot serve both:
///   * the RELATION scope (`charge(_:bytes:)`) -- keyed by the relation/address, the only identity that
///     existeth before authentication, with the card's SPECIFIED 256-relation bound and a deterministic
///     refusal beyond it;
///   * the GLOBAL scope (`chargeGlobal(bytes:)`) -- for RAW AIR TRAFFIC, which arriveth before any
///     relation at all and can be keyed by nothing but the fact of its arrival. Its allowance sitteth far
///     above any physical advertising rate (tens per second per advertiser) while still bounding a flood,
///     and it is deliberately generous relative to host-side churn witnesses, which are not air traffic.
///
/// The clock is MONOTONIC and injectable; never a wall clock, which a rollback can step backwards.
///
/// WHAT THIS IS NOT: not a device, radio or emulator result. It is the shape by which the ingress can
/// refuse work it never measured before.
public final class AdmissionBudget: @unchecked Sendable {
    public enum Verdict { case admitted, refused }

    /// The production clock: MONOTONIC, in milliseconds.
    public static let monotonicClock: @Sendable () -> Int64 = {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }

    /// IOS-05 / T27: the pre-auth relation registry's bound. IT IS **NOT** THE CARD'S 256: that number
    /// is the GOVERNOR's tracked-IDENTITY bound (a different instrument, and it is set to 256 in
    /// `PeerGovernor`). Applying it here REFUSED a legitimate court that exercises a thousand and
    /// twenty-four distinct relations through the write door (ReadinessT16's quarantine-metadata
    /// witness), which is the same lesson the android isle learned for the GLOBAL scope: a pre-auth
    /// bound that is too tight is indistinguishable from a denial of service the transport inflicteth
    /// on its own peers. The FLOOD defence is the per-relation allowance, not this registry's size.
    public static let defaultMaxTrackedRelations = 4096
    public static let defaultRecordsPerRelation = 2048
    public static let defaultBytesPerRelation = 1024 * 1024
    public static let defaultGlobalRecordsPerWindow = 65_536
    public static let defaultGlobalBytesPerWindow = 64 * 1024 * 1024
    public static let windowMillis: Int64 = 1_000

    private struct Window { var records: Int; var bytes: Int; var sinceMillis: Int64 }

    private let nowMillis: @Sendable () -> Int64
    private let maxTrackedRelations: Int
    private let recordsPerRelation: Int
    private let bytesPerRelation: Int
    private let globalRecordsPerWindow: Int
    private let globalBytesPerWindow: Int

    private let lock = NSLock()
    private var windows: [String: Window] = [:]
    private var globalWindow = Window(records: 0, bytes: 0, sinceMillis: 0)
    private var refusedCountValue = 0
    private var admittedCountValue = 0

    public init(nowMillis: @escaping @Sendable () -> Int64 = AdmissionBudget.monotonicClock,
                maxTrackedRelations: Int = AdmissionBudget.defaultMaxTrackedRelations,
                recordsPerRelation: Int = AdmissionBudget.defaultRecordsPerRelation,
                bytesPerRelation: Int = AdmissionBudget.defaultBytesPerRelation,
                globalRecordsPerWindow: Int = AdmissionBudget.defaultGlobalRecordsPerWindow,
                globalBytesPerWindow: Int = AdmissionBudget.defaultGlobalBytesPerWindow) {
        self.nowMillis = nowMillis
        self.maxTrackedRelations = maxTrackedRelations
        self.recordsPerRelation = recordsPerRelation
        self.bytesPerRelation = bytesPerRelation
        self.globalRecordsPerWindow = globalRecordsPerWindow
        self.globalBytesPerWindow = globalBytesPerWindow
    }

    /// Charge ONE arriving value against its RELATION's pre-auth allowance.
    public func charge(_ relation: String, bytes: Int) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        let now = nowMillis()
        if windows[relation] == nil && windows.count >= maxTrackedRelations {
            refusedCountValue += 1
            return .refused    // THE BOUND IS THE DEFENCE: a fresh relation beyond it is refused, never admitted
        }
        var w = windows[relation] ?? Window(records: 0, bytes: 0, sinceMillis: now)
        roll(&w, now: now)
        let charge = max(bytes, 0)
        if w.records + 1 > recordsPerRelation || w.bytes + charge > bytesPerRelation {
            windows[relation] = w
            refusedCountValue += 1
            return .refused
        }
        w.records += 1
        w.bytes += charge
        windows[relation] = w
        admittedCountValue += 1
        return .admitted
    }

    /// Charge RAW AIR TRAFFIC, which arriveth before any relation exists.
    public func chargeGlobal(bytes: Int) -> Verdict {
        lock.lock(); defer { lock.unlock() }
        let now = nowMillis()
        roll(&globalWindow, now: now)
        let charge = max(bytes, 0)
        if globalWindow.records + 1 > globalRecordsPerWindow
            || globalWindow.bytes + charge > globalBytesPerWindow {
            refusedCountValue += 1
            return .refused
        }
        globalWindow.records += 1
        globalWindow.bytes += charge
        admittedCountValue += 1
        return .admitted
    }

    private func roll(_ w: inout Window, now: Int64) {
        if now < w.sinceMillis {
            w.sinceMillis = now            // a BACKWARD step refundeth nothing: the window restarts, the spend stands
        } else if now - w.sinceMillis >= AdmissionBudget.windowMillis {
            w.sinceMillis = now
            w.records = 0
            w.bytes = 0
        }
    }

    /// Observation for courts and counters: how many values this budget REFUSED.
    public func refusedCount() -> Int { lock.lock(); defer { lock.unlock() }; return refusedCountValue }
    /// Observation for courts and counters: how many relations the bounded registry holdeth.
    public func trackedRelationCount() -> Int { lock.lock(); defer { lock.unlock() }; return windows.count }
}
