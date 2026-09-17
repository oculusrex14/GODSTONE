import Foundation

/// CRYPTO-005: **THE SEAM OVER THE STORE'S OWN VERBS** -- the type that binds `SqliteMessageStore`'s three intent verbs
/// (`readIntent`, `insertIntent`, `advanceIntent`) to `OutboundIntentJournal`, so that a RUNTIME can hand `SendDirectAuthority` a
/// JOURNAL THAT SURVIVES A PROCESS (which is the audit's whole charge: the only implementation was a process-local map).
///
/// **IT ADDETH NOTHING BUT THE TRANSLATION**: every act is the store's own method, called on the store's own handle, inside the store's
/// own lock discipline -- so this type inventeth no second path to the durable rows, EXACTLY AS THE ISLE'S OWN DOCTRINE REQUIRETH.
///
/// **AND IT FAILETH CLOSED, WHICH IS THE CARD'S OWN WORD**: a THROW from the store becometh `.storageFailure` (never `.notFound`), so a
/// caller that must not proceed on a fault can see that it happened -- which is what `SendDirectAuthority` now checketh before deciding
/// that an intent was never stored.
///
/// *** AND ONE HONEST LIMITATION, STATED RATHER THAN HIDDEN: `readIntent` ANSWERETH `nil` BOTH FOR A ROW THAT IS ABSENT **AND** FOR A
/// ROW THAT STANDETH BUT CANNOT BE REBUILT THROUGH `JournalEntry`'s FAILABLE `init?` (A SHORT BINDING DIGEST, A MALFORMED NONCE). SO
/// THIS TYPE MAPS BOTH TO `.notFound`, AND THE SEAM'S `.corrupt` CASE IS **NOT YET REACHED**. THAT IS A REAL GAP -- THE FIFTH PLACE IN
/// THIS FINDING WHERE THE ABSENT/CORRUPT DISTINCTION IS LOST -- AND IT IS NAMED HERE, IN THE CODE, FOR THE AUDITOR: the repair is to
/// have `readIntent` distinguish them (a typed store-level read), which is a change to the READER rather than to this seam. ***
public final class SqliteOutboundIntentJournal: OutboundIntentJournal, @unchecked Sendable {
    private let store: SqliteMessageStore

    public init(store: SqliteMessageStore) {
        self.store = store
    }

    public func load(_ intentId: Data) -> JournalLoadResult {
        do {
            guard let entry = try store.readIntent(intentId) else { return .notFound }
            return .found(entry)
        } catch {
            // A THROW IS A FAULT AND IS REPORTED AS ONE: `.storageFailure`, never folded into absence.
            return .storageFailure(reason: String(describing: error))
        }
    }

    public func insertIfAbsent(_ entry: JournalEntry) -> JournalInsertResult {
        do {
            if try store.insertIntent(entry) { return .stored }
            // THE CONFLICT IS CLASSIFIED BY RE-READING, so the WINNER is the row that actually governs rather than one this type
            // guessed at insert time.
            guard let winner = try store.readIntent(entry.intentId) else {
                // (`JournalInsertResult.storageFailure` CARRIETH NO REASON -- unlike `JournalLoadResult`'s -- so the distinction
                // between the two result types is itself the isle's shape and is honoured here rather than flattened.)
                return .storageFailure
            }
            return .duplicate(winner: winner)
        } catch {
            return .storageFailure
        }
    }

    public func advance(intentId: Data, from: IntentStateRank, to: IntentStateRank) -> JournalAdvanceResult {
        do {
            let moved = try store.advanceIntent(intentId: intentId, from: from, to: to)
            // THE AFFECTED-ROW COUNT IS THE ANSWER: one row moved means the token was revalidated and advanced; none means the row had
            // already moved (`.stale`), which is the CAS's own vocabulary.
            return moved == 1 ? .advanced : .stale
        } catch {
            return .storageFailure
        }
    }
}
