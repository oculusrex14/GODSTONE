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
/// **IT LIVES BEHIND THE EXISTING ENTRY POINT, WHICH IS THE CARD'S OWN INSTRUCTION** ("do not leave two competing public
/// wipe coordinators"): the durable record stayeth `WipeJournal` -- the field-proven `UserDefaultsWipeJournal` with its
/// own key -- and nothing here inventeth a second store.
///
/// **AND IT FAILETH CLOSED ON AN UNKNOWN NAME**: a stage the journal cannot express is NOT silently dropped, because a
/// dropped checkpoint is a wipe that restarteth later than it should; the append is refused and the caller's step
/// remaineth pending. The READ direction answers the LAST checkpoint the journal standeth at, which is what "resume"
/// meaneth.
public final class WipeJournalDurabilityAdapter: WipeDurabilityStore {
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

    /// Appending a stage WRITES IT THROUGH, and REFUSETH an unknown name (`WipeJournal.write` taketh a typed state, so
    /// an unmappable stage cannot be recorded and must not be pretended).
    public func appendJournal(_ stateName: String) {
        guard let state = Self.state(forStage: stateName) else { return }
        lock.lock()
        defer { lock.unlock() }
        journal.write(state)
    }
}
