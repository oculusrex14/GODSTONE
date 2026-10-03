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
//  `PrivateRuntimePermit` is made of `RecoveryEvidence`, whose initializer is `fileprivate` to this
//  file and is reachable only from `StartupRecoveryBootstrap.consumeCompositionTopology()` -- the
//  one-shot road that DRIVES the ladder and then issues. There is no `issue(_:)` helper, because a
//  helper taking a `StartupRecoveryDecision` would be a mint: every one of its six cases is public.
//
//  *** AND THE OUTSTANDING ESTATE GETS NO COMPOSITION AT ALL. *** An earlier draft answered a
//  pending wipe with a GATED PRIVATE RUNTIME. A review named that correctly: *stores opened and an
//  identity minted, then refused through a gate -- which is CONSTRUCTION PLUS A GATE, not the
//  "ZERO identity/key/store/runtime construction before terminal" the requirement states.* So a
//  nonterminal estate yields `.recoveryOnly(decision)`: a value with NO permit, whose only road is
//  `MeshRuntime.runRecoveryLadder` -- journal, key-delete, artifact-delete, identity-delete-and-
//  publish, and one live transport, opening no store and minting no ordinary identity.

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

    /// *** GS-FINAL-003: WHETHER A *RECOVERY* COMPOSITION MAY BE BUILT -- A THIRD QUESTION, AND A DIFFERENT ONE. ***
    ///
    /// *THE GAP THIS ANSWERS WAS MEASURED, NOT IMAGINED: with `.recoveryPending` and `.retryableFailure` the audit's
    /// clause ("private stores and identity issuance are unreachable while a wipe is pending") is satisfiable in TWO
    /// ways, and only one of them keeps the finding's own remedy reachable.*
    ///
    ///   * REFUSE EVERYTHING: sound, and the finding's own history says it is UNUSABLE -- "ANY MID-WIPE CRASH WOULD
    ///     BRICK THE APP", because the ONLY road that finishes a wipe is a runtime built from the stores the refusal
    ///     declines to open. `testSR02` measured exactly that, and the source kept the measurement.
    ///   * ADMIT THE RECOVERY-ONLY ROAD: `MeshRuntime.runRecoveryLadder` drives the durable ladder over the journal,
    ///     the key-delete seam, the artifact-delete seam, the identity-delete-and-publish seam and ONE LIVE TRANSPORT,
    ///     **and it constructs NO store, NO trust repository and NO ordinary identity** -- so the drain is reachable,
    ///     the ladder can advance, and *nothing sensitive exists at all* while it does.
    ///
    /// **THE SECOND IS WHAT THIS PROPERTY NAMES, AND IT IS DELIBERATELY NOT `allowsPrivateConstruction`:** *a decision
    /// that permits NORMAL construction may not be confused with one that permits a RECOVERY-ONLY road, which is why
    /// the two are separate properties -- and why only the first has a permit type at all.*
    public var permitsRecoveryConstruction: Bool {
        switch self {
        case .recoveryPending, .retryableFailure:
            return true
        case .cleanStart, .wipeCompleted, .corruptJournal, .terminalFailure:
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

/// *** GS-FINAL-003: THE RECOVERY-ONLY ROAD IS NOT A COMPOSITION OF THE SENSITIVE GRAPH AT ALL. ***
///
/// THE REQUIREMENT, AS THE REVIEW PUT IT AND AS IT MUST BE MET: **"the pre-private graph must NOT construct sensitive
/// runtime/store/identity just gated to gain a wipe owner... ZERO identity/key/store/runtime construction before
/// terminal."** *An earlier draft of this file answered an outstanding wipe with a GATED PRIVATE RUNTIME -- the stores
/// opened, the identity minted, and every sensitive road refused through the journal-bound gate.* **THAT IS NOT ZERO
/// CONSTRUCTION.** *It is construction plus a refusal, and a refusal is a runtime property that a future caller can
/// forget to consult, while the store handle and the minted key already exist.*
///
/// **SO THE RECOVERY ROAD OWNS RECOVERY CAPABILITIES AND NOTHING ELSE:**
///
///   * the durable JOURNAL (`WipeJournalDurabilityAdapter`);
///   * the KEY-DELETE seam (`WipeKeyVaultSeam` over the composition's keychain and DEK provider);
///   * the ARTIFACT-DELETE seam (`WipeArtifactFileSystemSeam` over the real DB/WAL/SHM urls);
///   * the IDENTITY-DELETE-AND-PUBLISH seam (`WipeIdentityAuthoritySeam`);
///   * and one live TRANSPORT, created before and independently of any store graph.
///
/// *It constructs NO `MeshRuntime`, NO message store, NO peer store, NO trust repository and NO identity that is not
/// the wipe's own new one.* **That road is `MeshRuntime.runRecoveryLadder` -- and it is the ONLY thing a nonterminal
/// estate may reach.**
///
/// **AND THE TOPOLOGY THEREFORE HAS NO CASE THAT OPENS THE SENSITIVE GRAPH.** *`PrivateRuntimePermit` is minted ONLY
/// for a SETTLED estate (`clean_start` / `wipe_completed`), by the bootstrap that just drove the ladder and observed
/// the durable rung. A nonterminal estate getteth `.recoveryOnly`, which carrieth a DECISION and NO PERMIT -- so there
/// is no type, no value and no initializer by which a pending wipe can reach a private store.*

/// *** THE PROOF A PERMIT IS MADE OF -- AND IT CANNOT BE WRITTEN DOWN. ***
///
/// *THE DEFECT THIS CLOSES, FOUND BY REVIEW AND PRESENT IN MY OWN FIRST DRAFT: a `static func issue(_ decision:)` ON
/// THE PERMIT IS **STILL A MINT**, because every one of the six outcomes is a PUBLIC ENUM CASE and therefore a value
/// any caller -- or any test -- may write down.* **`PrivateRuntimePermit.issue(.cleanStart)` IS THE UNFORGEABLE
/// PERMIT'S FORGERY ROAD:** *it needs no journal, no ladder, no drive and no durable record -- only the ability to
/// name a case the compiler already exports.*
///
/// **SO THE EVIDENCE IS WHAT IS UNFORGEABLE, AND THE PERMIT IS MADE OF IT.** *`RecoveryEvidence` can only be built
/// inside this FILE (`fileprivate init`), and the only code in this file that builds one is
/// `StartupRecoveryBootstrap.consumeCompositionTopology()`, WHICH HAS JUST DRIVEN THE LADDER over a real
/// `CrashResumableWipe`.* **Neither `MeshRuntime` nor a court nor a future refactor can name a witness into
/// existence.**
///
/// **IT CARRIETH THE DURABLE RUNG IT SAW, WHICH IS WHAT MAKES REUSE DETECTABLE RATHER THAN MERELY DISCOURAGED.** *A
/// permit says not only "a settled estate was decided" but "the record stood HERE when it was decided" -- so an audit
/// can compare a permit against the journal it was issued for.*
public struct RecoveryEvidence: @unchecked Sendable {
    /// The typed decision the drive produced.
    public let decision: StartupRecoveryDecision
    /// The durable rung the journal stood at when the drive finished, in the ladder's own wire spelling. `nil` when
    /// the view was empty -- which at a settled estate means `IDLE` (the ladder ran to its end).
    public let durableRung: String?
    /// Whether the ladder was driven by THIS bootstrap, as opposed to found already settled.
    public let droveTheLadder: Bool
    /// *** IOS-R1/R2: WHICH ESTATE THIS EVIDENCE IS ABOUT. *** *A permit that carrieth its estate cannot be presented
    /// against another one.*
    public let estateId: String
    /// *** IOS-R1/R3: THE DURABLE GENERATION OBSERVED AT THE DRIVE. *** *A permit minted at generation N is REFUSED
    /// once the record standeth at N+1 -- the ABA law.*
    public let generation: UInt64
    fileprivate let isCurrent: () -> Bool
    fileprivate init(decision: StartupRecoveryDecision, durableRung: String?, droveTheLadder: Bool,
                     estateId: String, generation: UInt64, isCurrent: @escaping () -> Bool) {
        self.decision = decision
        self.durableRung = durableRung
        self.droveTheLadder = droveTheLadder
        self.estateId = estateId
        self.generation = generation
        self.isCurrent = isCurrent
    }
}

/// *** IOS-R1: THE ONE-SHOT CONSUMPTION SLOT A PERMIT CARRIETH. ***
///
/// *A permit is a struct, so "reused" and "already spent" have no place to live in it -- **and that is exactly why the
/// review found the type "neither estate-bound nor consumed at private construction".** So each permit holdeth a
/// REFERENCE to one ledger entry; `consume()` answereth `true` exactly once, and a copy of the struct shareth that
/// entry, so copying a permit cannot buy a second construction.*
public final class PermitConsumptionLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    public init() {}
    /// TRUE the first time; FALSE on every replay.
    public func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
    public var isConsumed: Bool { lock.lock(); defer { lock.unlock() }; return consumed }
}

/// *** THE NON-FORGEABLE PERMIT: THE ONLY EVIDENCE THAT PRIVATE CONSTRUCTION IS ALLOWED. ***
///
/// **IT IS MADE OF `RecoveryEvidence` AND OF NOTHING ELSE**, and its initializer is `fileprivate` -- so the only way
/// to hold one is to have been handed one by `StartupRecoveryBootstrap.consumeCompositionTopology()` against a drive
/// whose typed decision SETTLED. *There is no `static func issue(_:)`, no public `init` and no memberwise
/// initializer.*
///
/// *AND IT IS A TYPE RATHER THAN A CHECK BECAUSE A CHECK CAN BE FORGOTTEN.* A composition that reads a `Bool` can
/// forget to read it; a composition that REQUIRES a `PrivateRuntimePermit` cannot be called without one, and the
/// compiler says so.
public struct PrivateRuntimePermit: Sendable {
    /// Which decision issued it -- carried so an audit can see WHY construction was allowed.
    public let issuedFrom: StartupRecoveryDecision
    /// The durable rung the drive observed, for the audit that must compare a permit against its journal.
    public let durableRung: String?
    /// *** IOS-R1: THE ESTATE THIS PERMIT IS ABOUT. *** *A permit issued over one estate cannot be presented against
    /// another.*
    public let estateId: String
    /// *** IOS-R1/R3: THE DURABLE GENERATION THIS PERMIT WAS JUDGED AT. ***
    public let generation: UInt64
    /// *** THE PROOF. UNREACHABLE FROM OUTSIDE THIS FILE. ***
    private let evidence: RecoveryEvidence
    /// *** IOS-R1: THE ONE-SHOT CONSUMPTION SLOT. *** *Shared by every copy of this permit, so copying cannot buy a
    /// second construction.*
    private let consumption: PermitConsumptionLedger

    /// FILEPRIVATE: only the bootstrap's consuming road may build one, and only from evidence it just took.
    fileprivate init(evidence: RecoveryEvidence) {
        self.evidence = evidence
        self.issuedFrom = evidence.decision
        self.durableRung = evidence.durableRung
        self.estateId = evidence.estateId
        self.generation = evidence.generation
        self.consumption = PermitConsumptionLedger()
    }

    /// Whether this permit came from a ladder that was actually DRIVEN (as opposed to an already-settled estate).
    public var wasDriven: Bool { evidence.droveTheLadder }

    /// Whether this permit's one-shot slot has already been spent.
    public var isConsumed: Bool { consumption.isConsumed }

    /// *** IOS-R1/R2: THE ATOMIC BOUNDARY CHECK -- ESTATE, GENERATION (ABA), AND ONE-SHOT CONSUMPTION. ***
    ///
    /// *THE FINDING, VERBATIM: the permit was "neither estate-bound nor consumed at private construction."* **So the
    /// ACTUAL construction boundary calls THIS, passing the estate it is about to build and the LIVE durable
    /// generation.** *It refuseth when the permit names another estate, when the record hath moved (ABA), or when the
    /// permit was already spent -- and it CONSUMES on success, so the same proof cannot open a second composition.*
    ///
    /// *It returns the consumption token on success so a caller may hold the fact that IT performed the boundary.*
    @discardableResult
    public func consumeForConstruction(estateId: String, liveGeneration: UInt64?) -> RecoveryEvidence? {
        PhysicalEstateAuthority.shared.serialized {
            guard self.estateId == estateId, let liveGeneration, self.generation == liveGeneration,
                  evidence.isCurrent(), consumption.consume() else { return nil }
            return evidence
        }
    }
}

/// *** GS-FINAL-003 `true-recovery-topology`: WHICH KIND OF ROAD A CALLER MAY TAKE. ***
///
/// **THERE ARE TWO ROADS AND ONLY ONE OF THEM CONSTRUCTS A SENSITIVE GRAPH:**
///
///   * `.normal(PrivateRuntimePermit)` -- a SETTLED estate. The permit is evidence of a terminal recovery (or of a
///     proven clean estate), and the private composition may be built.
///   * `.recoveryOnly(StartupRecoveryDecision)` -- an OUTSTANDING wipe. **CARRIES NO PERMIT AND NO CAPABILITY:** the
///     caller may drive the recovery-only road (`MeshRuntime.runRecoveryLadder`, which owns the journal, the
///     key-delete, artifact-delete and identity-delete-and-publish seams and one live transport, and OPENS NO STORE
///     AND MINTS NO IDENTITY OF ITS OWN), and may build NOTHING ELSE.
///   * `.refused(StartupRecoveryDecision)` -- unreadable record or policy: nothing at all, and an operator.
///   * `.alreadyConsumed(StartupRecoveryDecision)` -- this bootstrap's one permit was already spent.
///
/// **IT IS DELIBERATELY NOT `Equatable`:** *`PrivateRuntimePermit` now holds evidence that is not meaningfully
/// comparable, and an equality that ignored it would invite a court to assert two permits "equal" when one was driven
/// and one was not.*
public enum RecoveryCompositionTopology: Sendable {
    case normal(PrivateRuntimePermit)
    case recoveryOnly(StartupRecoveryDecision)
    case refused(StartupRecoveryDecision)
    case alreadyConsumed(StartupRecoveryDecision)
}

/// *** GS-FINAL-003 `true-recovery-topology`: WHAT ONE DRIVE OF THE RECOVERY LADDER LEFT BEHIND. ***
///
/// *THE FINDING'S OWN REMEDIATION CLAUSE: "Return a typed outcome to the caller and render completion only at durable
/// IDLE."* **THREE THINGS ARE NEEDED TO RENDER THAT HONESTLY, AND EACH IS A DIFFERENT KIND OF FACT:**
///
///   * `decision` -- the TYPED verdict, carrying which of the six estates the ladder reached and, where it stopped, WHY;
///   * `rungs` -- the DURABLE rungs as the next process will read them, in the wire spelling the journal carrieth, so
///     "wipe progress" is a read of the record rather than a recollection of the drive;
///   * `artifactsRemaining` -- the private artifacts still standing on disk, **MEASURED RATHER THAN INFERRED**: a ladder
///     that answered `wipeCompleted` while `mesh.db` still existed would be exactly the "plausible-looking success"
///     this repository's own doctrine refuses.
public struct RecoveryLadderOutcome: Sendable, Equatable {
    public let decision: StartupRecoveryDecision
    /// The durable rungs, in wire spelling (`REQUESTED`, `RUNTIME_DRAINED`, ...), read from the store after the drive.
    public let rungs: [String]
    /// The logical private-artifact names that still exist on disk after the drive.
    public let artifactsRemaining: [String]

    public init(decision: StartupRecoveryDecision, rungs: [String], artifactsRemaining: [String]) {
        self.decision = decision
        self.rungs = rungs
        self.artifactsRemaining = artifactsRemaining
    }

    /// TRUE ONLY WHEN THE LADDER RAN TO ITS END **AND** NOTHING IT WAS TO DELETE SURVIVES.
    ///
    /// *THE JOURNAL COLLAPSES A FINISHED LADDER TO AN EMPTY VIEW -- `WipeJournalDurabilityAdapter.readJournal()`
    /// answereth `[]` for `.idle`, deliberately, because `IDLE` and "nothing was ever requested" are the same estate
    /// and the adapter "reporteth a longer history than the store carrieth would be inventing a past" -- so `rungs`
    /// is EMPTY after a completed wipe and a test on its LAST element would never hold.* **SO THE TWO HALVES ARE: the
    /// TYPED DECISION (which the drive produced) and the FILESYSTEM (which the drive's deletions left).** *A caller that
    /// rendered completion from the rungs alone would be trusting a checkpoint over the file it describes; one that
    /// rendered it from `artifactsRemaining` alone would call a wipe complete while the keys still stood.*
    public var isComplete: Bool {
        decision == .wipeCompleted && artifactsRemaining.isEmpty
    }

    /// The words a surface may render for the ladder's position, **FROM THE DURABLE RUNG AND NOWHERE ELSE**.
    ///
    /// *A surface that rendered its own phrase would be a second vocabulary beside the journal's -- the defect the lab's
    /// `wipeStateName()` carried when it read a flag no ladder ever wrote. And where the record IS empty, the words say
    /// so rather than guessing: an empty view means `IDLE`-or-absent, and only the typed decision can tell the two
    /// apart.*
    public var rungWords: String {
        if !rungs.isEmpty { return "durable rung: " + rungs.joined(separator: " -> ") }
        switch decision {
        case .wipeCompleted:
            return "durable rung: IDLE (the ladder ran to its end)"
        case .cleanStart:
            return "no wipe is outstanding in the durable record"
        default:
            return "durable rung: none read (" + decision.name + ")"
        }
    }

    /// The remaining-artifact words, so a stuck deletion NAMES the file that survived rather than "cleanup failed".
    public var remainingWords: String {
        artifactsRemaining.isEmpty
            ? "no private artifact remains"
            : "still standing: " + artifactsRemaining.joined(separator: ",")
    }

    /// *** THE RENDERED ONE-LINE SUMMARY A CONTROL MAY SET, COMPOSED FROM THE TYPED FACTS ALONE. ***
    ///
    /// *A surface that wrote its own phrase would be a second vocabulary beside the journal's; this speaks the
    /// DECISION's own name, the DURABLE rung and the MEASURED artifacts, so a reader cannot be told a completion the
    /// record does not carry.*
    public var summaryWords: String {
        decision.name + " @" + (rungs.last ?? "no-rung") + " (" + remainingWords + ")"
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
    /// *** IOS-R1: THE ESTATE THIS BOOTSTRAP DRIVETH OVER. *** *The permit it issueth carrieth this, so it cannot be
    /// presented against another estate.*
    private let estateId: String

    /// - Parameter wipe: the journal-bound coordinator. It answers from the DURABLE record, so
    ///   this graph reads truth rather than a cached flag.
    /// - Parameter estateId: the estate the issued permit is bound to; a caller that omits it getteth an empty
    ///   estate, which no construction boundary accepts.
    public init(wipe: CrashResumableWipe, estateId: String = "") {
        self.wipe = wipe
        self.estateId = estateId
    }

    /// The typed decision produced by the last `decideAndDrive()` (or the direct drive below). Retained so the
    /// consuming road can name WHICH estate it is refusing or permitting without driving a second time.
    private var lastDecision: StartupRecoveryDecision = .cleanStart
    /// *** WHETHER THE ONE PERMIT HAS BEEN SPENT. *** *The road is one-shot so a permit issued against one estate
    /// cannot be presented twice, or against an estate that has since moved.*
    private var consumed = false
    private let consumeLock = NSLock()

    /// *** THE ONE-SHOT CONSUMING ROAD: THE ONLY PRODUCER OF A PERMIT IN THIS MODULE. ***
    ///
    /// *IT DRIVES THE LADDER ITSELF (rather than requiring a caller to have called `decideAndDrive` first), so the
    /// evidence it builds is evidence of a drive THIS object performed with the seams IT owns -- not of a decision
    /// value somebody handed it.* **THAT IS THE WHOLE DIFFERENCE BETWEEN A PROOF AND A PARAMETER:** *a caller cannot
    /// pass in a `StartupRecoveryDecision` and receive a permit for it, because there is no parameter to pass.*
    ///
    /// **AND IT IS ONE-SHOT.** *A second call answers `.alreadyConsumed`, so the same proof cannot open two
    /// compositions and a permit cannot survive an estate that has since changed. The evidence carrieth the durable
    /// rung, so an audit may compare it against the journal it was issued for.*
    ///
    /// **NO ROAD HERE OPENS A STORE OR MINTS AN ORDINARY IDENTITY:** *the decision is taken, and a SETTLED one yields
    /// the permit; every other outcome yields a value that carrieth no capability at all.*
    public func consumeCompositionTopology() -> RecoveryCompositionTopology {
        PhysicalEstateAuthority.shared.serialized {
            consumeLock.lock()
            defer { consumeLock.unlock() }
            if consumed { return .alreadyConsumed(lastDecision) }
            consumed = true
            let decision = driveLadderOnce()
            lastDecision = decision
            switch decision {
            case .cleanStart, .wipeCompleted:
                guard let snapshot = wipe.settledSnapshot() else {
                    lastDecision = .terminalFailure(reason: "settled generation was not durably acknowledged")
                    return .refused(lastDecision)
                }
                let revision = PhysicalEstateAuthority.shared.revision(for: estateId)
                let evidence = RecoveryEvidence(decision: decision, durableRung: nil, droveTheLadder: true,
                    estateId: estateId, generation: snapshot,
                    isCurrent: { [wipe, estateId] in
                        PhysicalEstateAuthority.shared.revision(for: estateId) == revision
                            && wipe.settledSnapshot() == snapshot
                    })
                return .normal(PrivateRuntimePermit(evidence: evidence))
            case .recoveryPending, .retryableFailure: return .recoveryOnly(decision)
            case .corruptJournal, .terminalFailure: return .refused(decision)
            }
        }
    }

    /// The decision this bootstrap last produced, without spending its permit.
    ///
    /// *A read for a surface or a court; it drives nothing and issues nothing.*
    public func reportedDecision() -> StartupRecoveryDecision {
        consumeLock.lock(); defer { consumeLock.unlock() }
        return lastDecision
    }

    /// Drive the ladder as far as the available seams allow, then answer with a TYPED decision.
    ///
    /// *** THIS IS THE FUNCTION THE OLD COMPOSITION DID NOT HAVE. *** *It previously wrote
    /// `_ = try resumeAuthority.resume()` and discarded the answer, then opened the private stores
    /// unconditionally. The result was not merely ignored: it was IGNORED AS AN INPUT, so no
    /// decision existed to act on.*
    @discardableResult
    public func decideAndDrive() -> StartupRecoveryDecision {
        PhysicalEstateAuthority.shared.serialized {
            let decision = driveLadderOnce()
            consumeLock.lock(); lastDecision = decision; consumeLock.unlock()
            return decision
        }
    }

    /// The drive itself, retaining nothing: `decideAndDrive` records what this returns.
    private func driveLadderOnce() -> StartupRecoveryDecision {
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
            return wipe.establishBaseline() ? .cleanStart : .terminalFailure(reason: "no acknowledged baseline generation")
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
