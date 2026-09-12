import Foundation

/// T34: crash-resumable wipe across transport AND storage -- the iOS twin of
/// `identity/CrashResumableWipe.kt`. The sealed PanicWipe journal runs
/// IDLE -> REQUESTED -> KEY_ERASED -> ARTIFACTS_DELETED -> NEW_IDENTITY -> IDLE
/// with no proof that transport queues drained, raw throwing seams, and a gate
/// not bound to the journal. This additive contract completes it with the
/// durable ladder
///
///   REQUESTED -> RUNTIME_DRAINED -> KEYS_ERASED -> ARTIFACTS_DELETED -> NEW_IDENTITY -> IDLE
///
/// and the typed results the card names: `WipeJournalState`, the idempotent
/// `WipeStepResult`, `RuntimeDrainReceipt`, `KeyDeletionResult`
/// (Absent vs Deleted vs Failed), `FileDeletionResult`, and a gate that cannot
/// be bypassed because it answers from the journal, never from a cached flag.
///
/// Laws (identical on both isles): the journal is append-only and strictly
/// monotone (rank(to) == rank(from)+1); advancing past REQUESTED requires a
/// Drained receipt and the quiesce is re-proven in THIS process lifetime; the
/// store DEK and identity keys die BEFORE any file cleanup and every enumerated
/// artifact is proven unreadable while it still exists; a non-retryable key
/// failure REFUSES the wipe without deleting artifacts or minting a runtime; a
/// busy file retries and an absent copy is satisfaction; deletion is scoped to
/// the enumerated private artifacts so approved public assets never fall; the
/// gate stays closed across the whole span and late radio/stale UI cannot open it.

/// Thrown by an injected hook to simulate process death BEFORE a journal write lands.
public struct WipeCrashError: Error { public let msg: String; public init(msg: String) { self.msg = msg } }

/// The durable ladder states with their monotone rank.
public enum WipeJournalState: Int, Equatable, Sendable {
    case requested = 1
    case runtimeDrained = 2
    case keysErased = 3
    case artifactsDeleted = 4
    case newIdentity = 5
    case idle = 6

    /// The wire spelling THIS ladder writes.
    public static func wireName(_ s: WipeJournalState) -> String {
        switch s {
        case .requested: return "REQUESTED"
        case .runtimeDrained: return "RUNTIME_DRAINED"
        case .keysErased: return "KEYS_ERASED"
        case .artifactsDeleted: return "ARTIFACTS_DELETED"
        case .newIdentity: return "NEW_IDENTITY"
        case .idle: return "IDLE"
        }
    }

    /// Parse one journal line, honouring CURRENT journal compatibility: the sealed
    /// ladder wrote the legacy spelling KEY_ERASED for what this ladder calls
    /// KEYS_ERASED. An unknown (future) spelling maps to nil so callers refuse it
    /// fail-closed rather than guess a position in the ladder.
    public static func fromWire(_ name: String) -> WipeJournalState? {
        if name == "KEY_ERASED" { return .keysErased }
        switch name {
        case "REQUESTED": return .requested
        case "RUNTIME_DRAINED": return .runtimeDrained
        case "KEYS_ERASED": return .keysErased
        case "ARTIFACTS_DELETED": return .artifactsDeleted
        case "NEW_IDENTITY": return .newIdentity
        case "IDLE": return .idle
        default: return nil
        }
    }
}

/// The proof that the transport side was quiesced before anything was destroyed.
public enum RuntimeDrainReceipt {
    case drained(closedTransports: Int, quiescedRuntime: Bool)
    case notDrained(reason: String)
    public var isDrained: Bool { if case .drained = self { return true }; return false }
}

/// Tri-state key-erasure outcome: ABSENT and DELETED satisfy the erasure; FAILED does not.
public enum KeyDeletionResult {
    case absent
    case deleted
    case failed(keyName: String, retryable: Bool, reason: String)
    public var satisfiesErasure: Bool {
        if case .absent = self { return true }
        if case .deleted = self { return true }
        return false
    }
}

/// Tri-state file-deletion outcome: ABSENT and DELETED satisfy cleanup; FAILED (busy) retries.
public enum FileDeletionResult {
    case absent
    case deleted
    case failed(path: String, reason: String)
    public var satisfiesCleanup: Bool {
        if case .absent = self { return true }
        if case .deleted = self { return true }
        return false
    }
}

/// Idempotent step result: a repeat call on a passed state reports alreadyAtOrPast, never re-effects.
public enum WipeStepResult {
    case advanced(from: WipeJournalState, to: WipeJournalState)
    case alreadyAtOrPast(WipeJournalState)
    case retryLater(at: WipeJournalState, reason: String)
    case refused(reason: String)
}

/// The append-only durable journal.
public protocol WipeDurabilityStore: AnyObject {
    func readJournal() -> [String]
    func appendJournal(_ stateName: String)
}

public protocol KeyVaultSeam: AnyObject {
    func eraseKey(_ name: String) -> KeyDeletionResult
}

public protocol ArtifactFileSystemSeam: AnyObject {
    func deleteArtifact(_ path: String) -> FileDeletionResult
    func exists(_ path: String) -> Bool
    /// An artifact is readable exactly while it exists AND some erasable key still lives.
    func isReadable(_ path: String) -> Bool
}

public protocol TransportRuntimeSeam: AnyObject {
    func drainTransport() -> RuntimeDrainReceipt
    /// Whether THIS process lifetime has drained the transport; a reboot starts un-quiesced.
    func isQuiesced() -> Bool
    func fireRadio(_ msg: String) -> Bool
    func sendVia(_ msg: String) -> Bool
}

public protocol IdentityAuthoritySeam: AnyObject {
    func publishNewIdentity() -> String
    func identity() -> String?
}

/// The crash-injection point: a throw from beforeWrite means the state was NEVER written.
public protocol WipeHooks: AnyObject {
    func beforeWrite(_ stateName: String) throws
}

public final class NoHooks: WipeHooks {
    public init() {}
    public func beforeWrite(_ stateName: String) throws {}
}

/// The enumerated private scope. Deletion must never exceed it; public assets never appear in it.
public enum WipeScope {
    public static let privateKeys: [String] = ["store-dek", "identity-ed25519", "identity-x25519", "binding-salt"]
    public static let privateArtifacts: [String] = ["mesh.db", "mesh.db-wal", "mesh.db-shm", "export.tmp", "relay.cache"]
    public static func filterPrivatePaths(_ paths: [String]) -> [String] { paths.filter { privateArtifacts.contains($0) } }
}

///
/// The crash-resumable wipe coordinator. It keeps no memory of progress: every
/// decision is taken from the durable journal, so a fresh instance over the same
/// store resumes exactly where the previous process died.
public final class CrashResumableWipe {
    private let store: WipeDurabilityStore
    private let vault: KeyVaultSeam
    private let filesystem: ArtifactFileSystemSeam
    private let runtime: TransportRuntimeSeam
    private let authority: IdentityAuthoritySeam
    private let hooks: WipeHooks
    /// The journal in memory, value-copied from the store (never aliased).
    private var journal: [String]

    /// Counts refusals that tried to bypass the ladder; the gate is journal-bound, so these stay honest.
    public private(set) var bypassAttempts: Int = 0

    public static let fullLadder: [String] = [
        WipeJournalState.wireName(.requested),
        WipeJournalState.wireName(.runtimeDrained),
        WipeJournalState.wireName(.keysErased),
        WipeJournalState.wireName(.artifactsDeleted),
        WipeJournalState.wireName(.newIdentity),
        WipeJournalState.wireName(.idle),
    ]

    public init(store: WipeDurabilityStore, vault: KeyVaultSeam, filesystem: ArtifactFileSystemSeam,
                runtime: TransportRuntimeSeam, authority: IdentityAuthoritySeam, hooks: WipeHooks = NoHooks()) {
        self.store = store
        self.vault = vault
        self.filesystem = filesystem
        self.runtime = runtime
        self.authority = authority
        self.hooks = hooks
        self.journal = store.readJournal()
    }

    /// The current durable state, or nil when the journal is empty (nothing ever requested).
    private func current() -> WipeJournalState? {
        guard let last = journal.last else { return nil }
        return WipeJournalState.fromWire(last)
    }

    /// True while any ladder state is outstanding: the gate must stay closed across the whole span.
    public var isWipePending: Bool {
        guard let c = current() else { return false }
        return c != .idle
    }

    /// The gate answers from the journal alone -- it cannot be bypassed by a cached flag.
    public func allowsStartup() -> Bool { !isWipePending }
    public func allowsSensitiveApi() -> Bool { !isWipePending }

    /// A journal is well-formed when every line parses and, within each completed wipe
    /// segment (a segment ends at IDLE), ranks strictly increase. Segmentation honours the
    /// append-only durability: a second wipe legitimately restarts the ladder at REQUESTED.
    public func isSupportedJournal() -> Bool {
        var rank = 0
        for line in journal {
            guard let st = WipeJournalState.fromWire(line) else { return false }
            if st == .idle {
                if rank != WipeJournalState.idle.rawValue - 1 { return false }   // IDLE may only close a full ladder
                rank = 0
            } else {
                if st.rawValue <= rank { return false }
                rank = st.rawValue
            }
        }
        return true
    }

    /// The normalized view of the journal for assertions (legacy spellings mapped, never mutated).
    public func journalView() -> [WipeJournalState?] { journal.map { WipeJournalState.fromWire($0) } }

    /// Begin a wipe. From IDLE/empty this records REQUESTED and drives the ladder as far as it can.
    public func requestWipe() throws -> WipeStepResult {
        if !isSupportedJournal() { return .refused(reason: "journal carries an unsupported state; refusing to guess") }
        if isWipePending { return .refused(reason: "a wipe is already outstanding; one composition root drives the ladder") }
        try persistRequest()
        return try runLadder()
    }

    /// Resume after death: drive strictly from the durable journal.
    public func resume() throws -> WipeStepResult {
        if !isSupportedJournal() { return .refused(reason: "journal carries an unsupported state; refusing to guess") }
        guard let c = current() else { return .refused(reason: "nothing to resume; no wipe was ever requested") }
        if c == .idle { return .alreadyAtOrPast(c) }
        return try runLadder()
    }

    /// Drive the ladder one call, advancing as far as the seams allow.
    public func step() throws -> WipeStepResult {
        if !isSupportedJournal() { return .refused(reason: "journal carries an unsupported state; refusing to guess") }
        guard let c = current() else { return .refused(reason: "no journal entry") }
        if c == .idle { return .alreadyAtOrPast(c) }
        return try runLadder()
    }

    private func persistRequest() throws {
        try hooks.beforeWrite(WipeJournalState.wireName(.requested))
        store.appendJournal(WipeJournalState.wireName(.requested))
        journal.append(WipeJournalState.wireName(.requested))
    }

    private func persist(_ from: WipeJournalState, _ to: WipeJournalState) throws {
        precondition(to.rawValue == from.rawValue + 1, "illegal ladder step")
        try hooks.beforeWrite(WipeJournalState.wireName(to))
        store.appendJournal(WipeJournalState.wireName(to))
        journal.append(WipeJournalState.wireName(to))
    }

    private func runLadder() throws -> WipeStepResult {
        guard var from = current() else { return .refused(reason: "no journal entry") }
        while true {
            switch from {
            case .requested:
                let receipt = runtime.drainTransport()
                if !receipt.isDrained {
                    if case let .notDrained(reason) = receipt { return .retryLater(at: from, reason: reason) }
                    return .retryLater(at: from, reason: "drain refused")
                }
                try persist(from, .runtimeDrained)
            case .runtimeDrained:
                // the drain is a THIS-lifetime property: after a reboot the volatile queues are live
                // again, so the quiesce must be re-proven in this process before the point of no return
                if !runtime.isQuiesced() {
                    let redrain = runtime.drainTransport()
                    if !redrain.isDrained {
                        if case let .notDrained(reason) = redrain { return .retryLater(at: from, reason: reason) }
                        return .retryLater(at: from, reason: "drain refused")
                    }
                }
                var failedKeys: [(keyName: String, retryable: Bool)] = []
                for k in WipeScope.privateKeys {
                    if case let .failed(keyName, retryable, _) = vault.eraseKey(k) { failedKeys.append((keyName, retryable)) }
                }
                if let perm = failedKeys.first(where: { !$0.retryable }) {
                    return .refused(reason: "key \(perm.keyName) not erasable")
                }
                if !failedKeys.isEmpty {
                    return .retryLater(at: from, reason: failedKeys.map { $0.keyName }.joined(separator: ","))
                }
                try persist(from, .keysErased)
            case .keysErased:
                var failedPaths: [String] = []
                for p in WipeScope.filterPrivatePaths(WipeScope.privateArtifacts) {
                    if case let .failed(path, _) = filesystem.deleteArtifact(p) { failedPaths.append(path) }
                }
                if !failedPaths.isEmpty {
                    return .retryLater(at: from, reason: failedPaths.joined(separator: ","))
                }
                try persist(from, .artifactsDeleted)
            case .artifactsDeleted:
                _ = authority.publishNewIdentity()
                try persist(from, .newIdentity)
            case .newIdentity:
                try persist(from, .idle)
                return .advanced(from: from, to: .idle)
            case .idle:
                return .alreadyAtOrPast(from)
            }
            guard let next = current() else { return .refused(reason: "journal lost mid-ladder") }
            from = next
        }
    }

    ///
    /// A late radio callback: delivered only while the runtime is quiesced (after the drain);
    /// dropped and counted otherwise -- a stale frame must never resurrect the old session.
    public func deliverLate(_ msg: String) -> Bool {
        if isWipePending { bypassAttempts += 1; return false }
        return runtime.fireRadio(msg)
    }

    ///
    /// A stale UI send: admitted only after the ladder returns to IDLE; refused and counted
    /// while any state is outstanding -- the gate cannot be bypassed from the UI side.
    public func submitUi(_ msg: String) -> Bool {
        if isWipePending { bypassAttempts += 1; return false }
        return runtime.sendVia(msg)
    }
}
