import Foundation

/// GS-STORE-006: **THE PRODUCTION `WipeDurabilityStore`** -- the third of the five adapters, and A MAPPING between two
/// state machines rather than a second state machine of its own.
///
/// THE CARD'S STEP 1 FORK, SETTLED BY MEASUREMENT RATHER THAN BY TASTE: the crash-resumable coordinator carrieth the
/// ladder `REQUESTED -> RUNTIME_DRAINED -> KEYS_ERASED -> ARTIFACTS_DELETED -> NEW_IDENTITY -> IDLE` (as a LIST of
/// stage names), while the production journal carrieth ONE TYPED `WipeState`. Reading the enum showed it had a case per
/// ladder stage EXCEPT `RUNTIME_DRAINED` -- THE MISSING STAGE WAS THE MISSING GUARANTEE -- so the card's FIRST option
/// applied ("adapt the existing PanicWipe journal compatibly"), that case was added, and this adapter is the mapping.
///
/// **IT LIVES BEHIND THE EXISTING ENTRY POINT** ("do not leave two competing public wipe coordinators"): the durable
/// record stayeth `WipeJournal` -- the field-proven `UserDefaultsWipeJournal` with its own key -- and nothing here
/// inventeth a second store.
///
/// **AND IT FAILETH CLOSED ON AN UNKNOWN NAME**: a stage the journal cannot express is NOT silently dropped, because a
/// dropped checkpoint is a wipe that restarteth later than it should; the append is refused and the caller's step
/// remaineth pending.
///
/// *** IOS-R3: THE APPEND IS *CHECKED*. ***
///
/// *THE FINDING, VERBATIM: "The UserDefaults implementation only calls set; this route has no durable acknowledgment
/// boundary. A readable journal that drops a write is enough to authorize private construction from an uncommitted
/// terminal state."* **SO `appendJournal` NOW WRITETH THROUGH AND *RE-READS* THE DURABLE VALUE: only a round-trip that
/// observeth the state it just wrote answereth `.committed`. A store that dropped the write (or wrote elsewhere)
/// answereth `.refused`, the coordinator doth NOT advance, and no private permit issueth.** *The write-then-verify is
/// the acknowledgment boundary the finding demanded; and the generation is read from the journal's OWN durable counter
/// so a permit can be bound to it (ABA).*
public final class WipeJournalDurabilityAdapter: WipeDurabilityStore, WipeEpochReporting {
    private let journal: WipeJournal
    private let lock = NSLock()

    public init(journal: WipeJournal) {
        self.journal = journal
    }

    /// The coordinator's own stage vocabulary, in ITS order -- the ladder, named by the strings it persisteth.
    public static let ladder: [String] = [
        "REQUESTED", "RUNTIME_DRAINED", "KEYS_ERASED", "ARTIFACTS_DELETED", "NEW_IDENTITY", "IDLE",
    ]

    /// Map ONE ladder stage name onto the journal's own typed state. `nil` when the name is not a ladder stage -- the
    /// caller then refuses rather than guessing.
    static func state(forStage stage: String) -> WipeState? {
        switch stage {
        case "REQUESTED": return .requested
        case "RUNTIME_DRAINED": return .runtimeDrained
        case "KEYS_ERASED": return .keyErased
        case "ARTIFACTS_DELETED": return .artifactsDeleted
        case "NEW_IDENTITY": return .newIdentity
        case "IDLE": return .idle
        default: return nil
        }
    }

    static func stage(forState state: WipeState) -> String {
        switch state {
        case .requested: return "REQUESTED"
        case .runtimeDrained: return "RUNTIME_DRAINED"
        case .keyErased: return "KEYS_ERASED"
        case .artifactsDeleted: return "ARTIFACTS_DELETED"
        case .newIdentity: return "NEW_IDENTITY"
        case .idle: return "IDLE"
        }
    }

    /// The journal holdeth ONE state, so the "list" is the single checkpoint it standeth at -- and the coordinator
    /// resumeTH from exactly that. Reporting a longer history than the store carrieth would be inventing a past.
    public func readJournal() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let state = journal.read()
        return state == .idle ? [] : [Self.stage(forState: state)]
    }

    /// GS-FINAL-003 / IOS-FOLLOWUP-H1: published forward from the journal, so an unreadable durable value is
    /// visible to the coordinator -- AND it consulteth the MEDIUM (a journal that cannot vouch for its medium
    /// cannot vouch for readability either). *The retained gate's `isSupportedJournal()` depends on this.*
    public var isReadable: Bool {
        guard journal.isReadable else { return false }
        return journal.readDurable() != nil
    }

    /// *** IOS-R1/R3: THE DURABLE GENERATION, FROM THE JOURNAL'S OWN COUNTER. ***
    public var durableEpoch: UInt64? { journal.durableEpoch }
    public func bumpEpoch() -> UInt64? { journal.bumpEpoch() }

    /// *** IOS-R3: THE STORE'S DURABLE-MEDIUM ANSWER, FORWARDED FROM THE JOURNAL. ***
    public func readDurable() -> (state: WipeState, epoch: UInt64?)? { journal.readDurable() }

    /// *** IOS-R3: WRITE, THEN *VERIFY BY RE-READ*, AND ONLY THEN ACKNOWLEDGE. ***
    ///
    /// *An unknown stage name is REFUSED (never written), a dropped write is REFUSED, and a write that landed at a
    /// different rung than intended is REFUSED. Only a committed, re-observed value answereth `.committed`.*
    @discardableResult
    public func appendJournal(_ stateName: String) -> WipeDurableCheckpoint {
        // AN UNKNOWN NAME IS NOT SILENTLY DROPPED: it never reacheth the journal, and the caller is told.
        guard let state = Self.state(forStage: stateName) else {
            return .refused(rung: nil, reason: "'\(stateName)' is not a ladder stage; the checkpoint was refused")
        }
        lock.lock()
        defer { lock.unlock() }
        // *** IOS-FOLLOWUP-C2: THE CHECKED WRITE -- the sync RESULT is required, not merely a matching reread. ***
        //
        // *THE REVIEW, VERBATIM: "persist now returns false on file/directory synchronization failure, but write
        // discards it. If the replacement is visible and directory fsync fails, the adapter rereads the intended state
        // and acknowledges it anyway."* **So the adapter consumes `writeChecked`'s `synchronized` result, which only a
        // real medium (or an explicit court fake) can vouch for -- a visible-but-unsynced record is REFUSED.***
        let rung = WipeJournalState.fromWire(Self.stage(forState: state))
        let written = journal.writeChecked(state)
        guard written.synchronized else {
            return .refused(
                rung: rung,
                reason: "the durable write did not synchronize (file or directory fsync failed, or the medium cannot "
                      + "vouch); the checkpoint is refused")
        }
        // AND A SECOND, INDEPENDENT ROUND-TRIP: the acknowledged rung must be what the medium now carrieth.
        guard let durable = journal.readDurable(), durable.state == state else {
            return .refused(
                rung: rung,
                reason: "the durable record does not carry \(state.rawValue) after the write; the checkpoint is refused")
        }
        // *** IOS-FOLLOWUP-C3: NEVER FABRICATE COMMITTED(generation: 0). *** *A missing epoch is REFUSED, not
        // defaulted -- a committed checkpoint MUST carry the generation that actually reached the medium.*
        guard let epoch = written.epoch ?? durable.epoch else {
            return .refused(
                rung: rung,
                reason: "the durable record carries no generation; a committed checkpoint requires one (no fabricated 0)")
        }
        return .committed(generation: epoch, rung: rung ?? .requested)
    }
}
