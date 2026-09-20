import Foundation

//  GS-FINAL-003: THE TYPED STARTUP DECISION, AND THE NON-FORGEABLE PERMIT.
//
//  *** THE AUDIT'S CHARGE, QUOTED: ***
//
//      "iOS discards the result of resume before creating identity/stores." Android's
//      `MeshStartupWipeBarrier` "returns Unit", so "construction of a barrier object says nothing
//      about a successful state transition." Root cause, in the audit's own words: *"DI sequencing
//      is mistaken for successful state transition."*
//
//  *** AND THE FIRST ATTEMPT AT A FIX WAS WORSE THAN THE DEFECT, WHICH IS WHY THIS FILE EXISTS. ***
//
//  The repo previously tried to REFUSE CONSTRUCTION on a pending wipe, on both isles, and MEASURED
//  the consequence: `testSR02` threw `startupBlockedByPendingWipe`, and Android's own comment
//  records that "ANY MID-WIPE CRASH WOULD BRICK THE APP UNTIL THE JOURNAL WAS CLEARED BY HAND --
//  STRICTLY WORSE THAN THE DISCARD BEING REPAIRED." *A gate that makes its own remedy unreachable
//  is worse than the defect it closes*, because the only thing that can finish a wipe is a runtime,
//  and that runtime was built from the very stores the gate refused to open.
//
//  SO THE REFUSAL MOVES TO THE RIGHT PLACE. It is not "may we construct?" but:
//
//      * a RECOVERY/BOOTSTRAP composition, whose transport seam exists BEFORE and INDEPENDENTLY of
//        the store graph, drives the ladder to a TYPED DECISION;
//      * a PRIVATE RUNTIME composition may be constructed only against a permit that only that
//        typed decision can mint.
//
//  The two graphs are separate, so the recovery graph is reachable during a pending wipe and the
//  private graph is unreachable without a permit. Nothing deadlocks and nothing is discarded.
//
//  *** WHY A PERMIT AND NOT A BOOLEAN. *** The audit forbids all three shortcuts by name: "Do not
//  use a bare Boolean. Do not use a log statement. Do not use a public initializer that lets
//  tests/callers mint the permit themselves." A `Bool` is a value anyone can produce; a log line
//  is a value nobody reads; a public initializer is the same as a Bool with more ceremony. A
//  `PrivateRuntimePermit` has a PRIVATE initializer, so the only way to hold one is to have been
//  issued one by a decision that permitted it -- and that is a property of the type system rather
//  than of a reviewer's attention.

/// *** THE TYPED STARTUP DECISION. ***
///
/// Six outcomes, because the audit asked for six and because collapsing any two of them loses the
/// distinction a caller must act on:
///
///   * `cleanStart`      -- nothing was ever requested. Private construction is allowed.
///   * `wipeCompleted`   -- the erasure ran to its end. The material is gone and the node is a
///                          stranger; that is a legitimate estate to start from, NOT a block.
///   * `recoveryPending` -- a wipe is outstanding and CANNOT be finished from this seam (no
///                          transport, no keychain). Private construction is refused: *a store
///                          opened now is a store opened on the key a later resume will erase.*
///   * `retryableFailure`-- the ladder advanced and stopped at a rung whose seam is temporarily
///                          unavailable. Refused, and distinguished from pending because the
///                          caller may retry WITHOUT operator action.
///   * `corruptJournal`  -- the durable record cannot be parsed. Refused, and distinguished
///                          because retrying will never help.
///   * `terminalFailure` -- policy blocks normal startup. Refused, and the only outcome where a
///                          human must be involved.
///
/// *** `retryableFailure` AND `recoveryPending` ARE DELIBERATELY NOT THE SAME CASE. *** *One says
/// "this seam is not ready yet" and the other says "this cannot be done from here at all". A
/// caller that cannot tell them apart either retries forever or gives up on work that would have
/// succeeded.*
public enum StartupRecoveryDecision: Equatable, Sendable {
    case cleanStart
    case wipeCompleted
    case recoveryPending(reason: String)
    case retryableFailure(reason: String)
    case corruptJournal(reason: String)
    case terminalFailure(reason: String)

    /// Only the two outcomes that describe a SETTLED estate allow private construction.
    public var allowsPrivateConstruction: Bool {
        switch self {
        case .cleanStart, .wipeCompleted:
            return true
        case .recoveryPending, .retryableFailure, .corruptJournal, .terminalFailure:
            return false
        }
    }

    /// Whether an operator is required. NOT the same question as `allowsPrivateConstruction`:
    /// a retryable failure blocks construction and needs no human.
    public var requiresOperator: Bool {
        switch self {
        case .corruptJournal, .terminalFailure:
            return true
        default:
            return false
        }
    }

    /// A short machine-readable name, for logs and for tests that must not match prose.
    public var name: String {
        switch self {
        case .cleanStart:       return "clean_start"
        case .wipeCompleted:    return "wipe_completed"
        case .recoveryPending:  return "recovery_pending"
        case .retryableFailure: return "retryable_failure"
        case .corruptJournal:   return "corrupt_journal"
        case .terminalFailure:  return "terminal_failure"
        }
    }

    /// The refusal reason, where there is one -- so a caller can NAME what stopped it.
    public var refusalReason: String? {
        switch self {
        case .cleanStart, .wipeCompleted:
            return nil
        case .recoveryPending(let r), .retryableFailure(let r),
             .corruptJournal(let r), .terminalFailure(let r):
            return r
        }
    }
}

/// *** THE NON-FORGEABLE PERMIT: THE ONLY EVIDENCE THAT PRIVATE CONSTRUCTION IS ALLOWED. ***
///
/// THE INITIALIZER IS PRIVATE, AND THAT IS THE ENTIRE MECHANISM. There is no public `init`, no
/// public memberwise initializer, and no default construction -- so the only way to hold one of
/// these is to have been handed one by `issue(_:)` against a decision that permitted it. A test
/// cannot mint one; a caller cannot mint one; a future refactor that wants to skip the gate has to
/// change this type rather than quietly pass `true`.
///
/// *AND IT IS A TYPE RATHER THAN A CHECK BECAUSE A CHECK CAN BE FORGOTTEN.* A composition that
/// reads a `Bool` can forget to read it; a composition that REQUIRES a `PrivateRuntimePermit`
/// cannot be called without one, and the compiler says so. The audit asked for exactly this:
/// *"Constructible only after a non-forgeable typed startup decision says private construction is
/// allowed."*
public struct PrivateRuntimePermit: Sendable {
    /// Which decision issued it -- carried so an audit can see WHY construction was allowed,
    /// rather than only that it was.
    public let issuedFrom: StartupRecoveryDecision

    /// *** PRIVATE. THIS IS THE WHOLE POINT. ***
    private init(issuedFrom: StartupRecoveryDecision) {
        self.issuedFrom = issuedFrom
    }

    /// The ONLY way to obtain a permit. Returns `nil` -- rather than throwing -- for every
    /// decision that does not allow private construction, so an optional binding is the natural
    /// shape at the call site and there is no error a caller might swallow.
    public static func issue(_ decision: StartupRecoveryDecision) -> PrivateRuntimePermit? {
        guard decision.allowsPrivateConstruction else { return nil }
        return PrivateRuntimePermit(issuedFrom: decision)
    }
}

/// *** THE RECOVERY/BOOTSTRAP GRAPH: WHAT DRIVES THE LADDER *BEFORE* ANY PRIVATE STORE EXISTS. ***
///
/// This type exists so the decision above can be REACHED during a pending wipe. It owns the journal
/// and the wipe coordinator and NOTHING ELSE -- no identity, no message store, no peer store --
/// because *a graph that needs those in order to decide whether they may be opened can never
/// decide "no".*
///
/// THE TRANSPORT SEAM IS INJECTED RATHER THAN CONSTRUCTED. The ladder's drain rung needs the
/// runtime quiesced and its transports closed; on a pending wipe at `runtimeDrained` that seam is
/// simply ABSENT, and the honest answer is `recoveryPending` rather than a fabricated success. When
/// a caller can supply a live transport -- because it built the recovery graph first -- the ladder
/// advances and the decision becomes `wipeCompleted`. That is the architectural separation the
/// ledger demanded and could not previously express.
public final class StartupRecoveryBootstrap {
    private let wipe: CrashResumableWipe

    /// - Parameter wipe: the journal-bound coordinator. It answers from the DURABLE record, so
    ///   this graph reads truth rather than a cached flag.
    public init(wipe: CrashResumableWipe) {
        self.wipe = wipe
    }

    /// Drive the ladder as far as the available seams allow, then answer with a TYPED decision.
    ///
    /// *** THIS IS THE FUNCTION THE OLD COMPOSITION DID NOT HAVE. *** *It previously wrote
    /// `_ = try resumeAuthority.resume()` and discarded the answer, then opened the private stores
    /// unconditionally. The result was not merely ignored: it was IGNORED AS AN INPUT, so no
    /// decision existed to act on.*
    @discardableResult
    public func decideAndDrive() -> StartupRecoveryDecision {
        // A CORRUPT JOURNAL IS TERMINAL AND MUST BE CHECKED FIRST: `resume()` would itself refuse,
        // but its refusal is indistinguishable from "nothing to resume" at the call site, and
        // treating a malformed record as a clean start is the one confusion here that would open
        // private stores over material that may be mid-erasure.
        guard wipe.isSupportedJournal() else {
            return .corruptJournal(
                reason: "the wipe journal carries an unsupported or malformed state; refusing to guess")
        }

        // *** AN EMPTY VIEW MEANS "NOTHING WAS EVER REQUESTED" *ONLY IF THE RECORD WAS READABLE*. ***
        //
        // *MEASURED AND FIXED: the durability adapter reports an empty journal for BOTH "no wipe was
        // ever requested" and "the durable value could not be parsed", because the journal's own
        // parser coerced an unknown spelling to `idle`. A bootstrap that answered `cleanStart` for
        // both would open private stores over a record nobody could read -- the unsound direction,
        // and exactly the confusion the audit forbids between "no pending wipe" and "malformed
        // journal". The two are therefore separated HERE, at the decision, rather than left to a
        // caller to notice.*
        guard wipe.isReadableJournal() else {
            return .corruptJournal(
                reason: "the durable wipe record carries a value this build does not understand; "
                      + "refusing to treat an unreadable record as a clean start")
        }

        // NO WIPE WAS EVER REQUESTED -- the clean first launch.
        //
        // `current()` is PRIVATE to the coordinator (it reads the durable journal, and only the
        // coordinator may interpret it), so this asks the PUBLIC accessor instead. The last rung
        // is the current state: an EMPTY view means nothing was ever requested.
        let view = wipe.journalView()
        guard let currentRung = view.last ?? nil else {
            return .cleanStart
        }
        _ = currentRung

        let outcome: WipeStepResult
        do {
            outcome = try wipe.resume()
        } catch let error as WipeCrashError {
            // A THROW IS A RETRYABLE FAILURE, NOT A TERMINAL ONE: the ladder could not complete
            // FROM THIS SEAM. The journal keeps the truth, so a later composition with a live
            // transport may finish what this one could not.
            return .retryableFailure(
                reason: "the recovery ladder threw from this seam: \(error.msg)")
        } catch {
            return .terminalFailure(reason: "the recovery ladder failed unexpectedly: \(error)")
        }

        switch outcome {
        case .alreadyAtOrPast(let state):
            // `alreadyAtOrPast(.idle)` means the ladder ran to its end -- the erasure happened and
            // the node is a stranger. That is a legitimate estate, NOT a block. Any other rung
            // means work remains.
            return state == .idle
                ? .wipeCompleted
                : .recoveryPending(
                    reason: "a wipe is outstanding at \(WipeJournalState.wireName(state)); the ladder cannot advance "
                          + "from this seam, which owns no transport and no key material")

        case .advanced(_, let to):
            return to == .idle
                ? .wipeCompleted
                : .recoveryPending(
                    reason: "a wipe advanced to \(WipeJournalState.wireName(to)) and stopped; the remaining rungs "
                          + "need a seam this composition does not own")

        case .retryLater(let at, let reason):
            return .retryableFailure(
                reason: "the ladder is retryable at \(WipeJournalState.wireName(at)): \(reason)")

        case .refused(let reason):
            // A REFUSAL FROM THE COORDINATOR IS AMBIGUOUS BY CONSTRUCTION -- it is used for both
            // "nothing to resume" and a malformed journal -- so it is treated as CORRUPT rather
            // than as a clean start. *Guessing "clean" here would open private stores over a
            // record nobody could read, which is the unsound direction.*
            return .corruptJournal(reason: "the recovery coordinator refused: \(reason)")
        }
    }
}
