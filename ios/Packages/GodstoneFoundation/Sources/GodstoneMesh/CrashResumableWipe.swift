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
/// *** IOS-R4: `verifiedAbsent` IS THE ERASURE THE SEAM *CONFIRMED*, NOT MERELY ATTEMPTED. *** *`absent` meaneth a
/// composition that carrieth no DEK provider at all; `verifiedAbsent` meaneth the real account was deleted AND a
/// follow-up read confirmed nothing standeth there.*
public enum KeyDeletionResult {
    case absent
    case deleted
    case verifiedAbsent(name: String)
    case failed(keyName: String, retryable: Bool, reason: String)
    public var satisfiesErasure: Bool {
        switch self {
        case .absent, .deleted, .verifiedAbsent: return true
        case .failed: return false
        }
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


/// *** IOS-R3: A DURABLE APPEND MUST RETURN AN ACKNOWLEDGMENT, NOT `Void`. ***
///
/// *THE FINDING, VERBATIM: "appendJournal/write return no commit result. The coordinator unconditionally appends the
/// rung to memory and later labels that cached rung durable."* **A store whose durable write DROPPED still let the
/// coordinator advance its in-memory ladder to `IDLE` and issue a private permit from an UNCOMMITTED terminal
/// state.** *So the append now ANSWEReth, and only `.committed` may advance the cached rung.*
public enum WipeDurableCheckpoint: Equatable, Sendable {
    /// The value REACHED durable storage, and stands at this rung of this generation.
    case committed(generation: UInt64, rung: WipeJournalState)
    /// The value did NOT reach durable storage (or reached it at another rung). The ladder must NOT advance.
    /// `rung` is `nil` when the caller named a stage that is not in the ladder at all.
    case refused(rung: WipeJournalState?, reason: String)
}

/// *** IOS-R3: AN EPOCH SOURCE, SO A PERMIT CAN BE BOUND TO THE RECORD'S OWN GENERATION. ***
///
/// *`durableEpoch` is MONOTONE and incremented when a NEW wipe is durably requested, and `bumpEpoch()` RETURNeth the
/// new value. A store that carrieth no such counter answereth `nil` -- and the coordinator then keeps its own
/// monotone generation, so ABA detection never silently disappearreth.*
public protocol WipeEpochReporting: AnyObject {
    var durableEpoch: UInt64? { get }
    /// Advance the generation and return the new value; `nil` when this store carrieth no counter.
    func bumpEpoch() -> UInt64?
}

public protocol WipeDurabilityStore: AnyObject {
    func readJournal() -> [String]
    /// *** IOS-R3: THE CHECKED APPEND. *** *`@discardableResult` because a court may drive a raw append; production
    /// MUST consume the answer, and `CrashResumableWipe` does.*
    @discardableResult
    func appendJournal(_ stateName: String) -> WipeDurableCheckpoint
    /// *** IOS-R3 (fail-closed): THE DURABLE MEDIUM'S OWN ANSWER, OR `nil` WHEN THIS STORE CANNOT VOUCH FOR IT. ***
    ///
    /// *THE PARENT'S RULING: the acknowledgment must be verified against the MEDIUM, not an in-process cache, and the
    /// verifier MUST fail closed -- "the verifiable journal default protocol fails closed".* **THE PROTOCOL EXTENSION
    /// BELOW DEFAULTS TO `nil`, so a store that does not explicitly answer the medium REFUSES every commit; only a
    /// store that really carries durable bytes (the production `FileWipeJournal`) or an explicit, typed court fake
    /// answereth non-nil.** *There is no `read()` fallback: a cache read cannot vouch for the medium.*
    func readDurable() -> (state: WipeState, epoch: UInt64?)?
    /// *** WHETHER THE DURABLE VALUE WAS READABLE AT ALL (GS-FINAL-003), FOLDED HERE SO NO CAST IS NEEDED AND THE
    /// DEFAULT FAILS CLOSED. *** *A store that cannot answer must not read as a clean start.*
    var isReadable: Bool { get }
}

public extension WipeDurabilityStore {
    /// *** FAIL-CLOSED DEFAULT: A STORE THAT HATH NOT ANSWERED THE MEDIUM ADMITTS NOTHING. *** *A court fake must
    /// explicitly implement this to be acknowledged; the production file journal answers it from the filesystem.*
    func readDurable() -> (state: WipeState, epoch: UInt64?)? { nil }
    /// *** FAIL-CLOSED DEFAULT: A STORE THAT HATH NOT ANSWERED THE READABILITY QUESTION IS NOT READABLE. ***
    var isReadable: Bool { false }
}

/// *** IOS-R5: THE RECOVERY ESTATE'S OWNER-DRAIN CAPABILITY. ***
///
/// *THE FINDING, VERBATIM: the recovery entry supplied `WipeTransportDrainSeam(transport: BleTransport())` -- "a
/// NEW transport [with] no active context; its barrier immediately succeeds ... without touching the estate's live
/// transport, stores, sessions, or producers."* **So the drain must be answered by the ESTATE that owns those
/// owners, and a cold/no-owner case must be POSITIVELY VERIFIED rather than assumed from an empty barrier.**
public enum OwnerDrainResult: Equatable, Sendable {
    /// Every live owner was drained and closed; the reason nameth what was drained.
    case drained(reason: String)
    /// The estate POSITIVELY verified that no owner exists (a real cold estate).
    case cold(reason: String)
    /// Owners are still live and could not be drained; the ladder must NOT advance past the drain rung.
    case ownersLive(reason: String)

    public var isDrainable: Bool {
        switch self {
        case .drained, .cold: return true
        case .ownersLive: return false
        }
    }
}

public protocol WipeOwnerDraining: AnyObject {
    func drainOwners() -> OwnerDrainResult
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
    /// *** GS-STORE-006: A TYPED FAILURE CHANNEL, WHICH IS THE FIX AN ARM FORCED (round 421). ***
    ///
    /// IT RETURNED A NON-OPTIONAL `String`, AND A `String` CANNOT SAY "I DID NOT PUBLISH AN IDENTITY": the deferred seam
    /// answered a NAME THAT SAID WHAT HAPPENED -- honest prose -- and the ladder, having no way to read a refusal as a
    /// refusal, ADVANCED TO `IDLE` BELIEVING AN IDENTITY STOOD WHEN NONE DID. An authority that cannot FAIL where it must
    /// not succeed is the very species of defect this finding is about, and I had built one into the seam whose job was to
    /// prevent it.
    ///
    /// `nil` MEANS **NOT PUBLISHED**, and the ladder must therefore STAY PENDING rather than reach `IDLE`.
    func publishNewIdentity() -> String?
    func identity() -> String?
    /// *** IOS-R8: PUBLISH *OR ADOPT* THE IDENTITY FOR THIS WIPE GENERATION -- CRASH-SAFE AND IDEMPOTENT. ***
    ///
    /// *THE FINDING: at `ARTIFACTS_DELETED`, recovery wrote a replacement identity BEFORE recording `NEW_IDENTITY`.
    /// If the process died in between, the next attempt called `generateAndStore` again -- and THAT REFUSED the
    /// already-present identity, so the journal stayed at `ARTIFACTS_DELETED` on every retry.* **So the ladder asks
    /// THIS road, whose contract is: if an identity for `wipeGeneration` ALREADY standeth, ADOPT it and return its
    /// name; otherwise publish a fresh one and return ITS name; and return `nil` only when neither is possible.**
    /// *A crash between publication and the `NEW_IDENTITY` write therefore re-opens on the SAME identity and
    /// settlETH with ONE identity -- rather than generating a second.*
    func publishOrAdoptIdentity(wipeGeneration: UInt64) -> String?
}

public extension IdentityAuthoritySeam {
    /// **THE FAIL-SAFE DEFAULT:** *a conformer that hath not implemented adoption FALLETH BACK to the plain publish,
    /// so no existing authority silently loses its publication road.*
    func publishOrAdoptIdentity(wipeGeneration: UInt64) -> String? {
        _ = wipeGeneration
        return publishNewIdentity()
    }
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
    /// *** IOS-R4: THE DEK ACCOUNTS THE PRIVATE STORES ACTUALLY USE -- AND NOT A BOGUS TAG. ***
    ///
    /// *THE FINDING, VERBATIM: the actual keyed connections fetch DEKs under `message-store` and
    /// `peer-identity-store`, while `WipeKeyVaultSeam` deleted only `godstone.store.dek` -- "a different Keychain
    /// account. Both actual encryption keys survive KEYS_ERASED and terminal completion."* **So the scope nameth the
    /// TWO REAL ACCOUNTS** (*`EncryptedStoreFactory` fetcheth them under the store tags `MeshRuntime.create` passes:
    /// `"message-store"` and `"peer-identity-store"`*), each routed to the DEK provider's own `deleteDEK(tag:)` AND
    /// VERIFIED ABSENT. *A skipped real-account deletion now reddens, because the court seeds and checks both.*
    ///
    /// **AND `binding-salt` STAYS GONE (GS-FINAL-002):** it had no owner anywhere, and a name with no owner must not
    /// hold a wipe open forever.
    public static let privateKeys: [String] = [
        "store-dek-message", "store-dek-peer", "identity-ed25519", "identity-x25519",
    ]
    /// GS-FINAL-002: **EVERY NAME HERE HAS AN OWNER, AND THAT IS NOW A REQUIREMENT RATHER THAN A HOPE.**
    ///
    /// The list formerly ended `..., "export.tmp", "relay.cache"`. NEITHER NAME HAS ANY OWNER IN THIS CODEBASE: no file
    /// is ever written under either name, on either isle (the Android twin carrieth the same two speculative names).
    /// A NAME WITH NO OWNER IS NOT A DEFENSIVE EXTRA -- IT IS A TRAP, and it fired: with the artifact map in place the
    /// unmapped name correctly answers `.failed`, which is RETRYABLE, WHICH STALLED THE LADDER AT `KEYS_ERASED`
    /// FOREVER. Measured: "the wipe is complete" became `retryLater(at: .keysErased, reason: "mesh.db,...,export.tmp,
    /// relay.cache")`.
    ///
    /// THE RULE THIS LIST NOW OBEYS: every entry must be an artifact the runtime can actually address, because a
    /// deletion the composition cannot perform must not be able to hold a wipe open. If such an artifact is ever
    /// introduced, its owner names it here AND maps it in the composition's `realPaths`.
    ///
    /// AND THE PEER-IDENTITY STORE IS NAMED, WHICH IT WAS NOT BEFORE -- the old `PanicWipe` path deleted both durable
    /// stores through `SqliteMessageStore.panicWipe` and `SqlitePeerIdentityStore.panicWipe`, so a scope naming only
    /// `mesh.db` would have silently stopped deleting it. The crash-restart arm SR06 measured exactly that.
    public static let privateArtifacts: [String] = [
        "mesh.db", "mesh.db-wal", "mesh.db-shm",
        "peer.db", "peer.db-wal", "peer.db-shm",
    ]
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
    /// *** IOS-R7: THE ESTATE'S OWN ARTIFACT INVENTORY, ITERATED AS THE LOGICAL NAMES. ***
    ///
    /// *THE FINDING, VERBATIM: "LabEstateSeam maps artifacts under lab:<filename>, while the coordinator deletes only
    /// the fixed mesh.db/peer.db logical artifact names. Every deletion lookup is therefore unmapped and the ladder
    /// remains at KEYS_ERASED."* **So the deletion rung iterates BOTH the built-in default inventory AND the estate's
    /// own names -- and a name with no mapping answereth `.failed`, which is exactly what stalled the lab. A lab name
    /// is NOT required to be a member of `WipeScope.privateArtifacts`; the estate's own inventory is authoritative for
    /// the files it really wrote.**
    private let estateArtifacts: [String]
    /// *** IOS-R2: THE JOURNAL IS RE-READ FROM THE DURABLE STORE ON EVERY QUESTION. ***
    ///
    /// *THE FINDING, VERBATIM: "CrashResumableWipe reads the journal only at initialization. allowsSensitiveApi(),
    /// current state, and bootstrap evidence subsequently inspect its local array."* **So the array below is a
    /// MIRROR, refreshed from the store on every read, and the gate/ladder questions answer from the STORE rather
    /// than from a snapshot taken at birth.** *A wipe requested through ANOTHER owner is therefore observed here.*
    private var journal: [String]

    /// *** IOS-R1/R2: ONE SERIALIZATION POINT PER COORDINATOR, WITH A REENTRANCY REFUSAL. ***
    /// *Every real drive holds it, so a reentrant drive (an injected hook or seam that re-enters) is REFUSED rather
    /// than run twice -- the "duplicate effects / checkpoint regression" the review named.*
    private let driveLock = NSRecursiveLock()
    private var inDrive = false

    /// *** THE DURABLE MONOTONE GENERATION: ADVANCED ONCE WHEN A NEW WIPE IS DURABLY REQUESTED. ***
    ///
    /// *It is the basis for ABA detection: a permit minted at generation N is REFUSED once the record standeth at
    /// generation N+1, even if the rung spelling returned to where it was.* **The store's own `WipeEpochReporting`
    /// counter wins where there is one, so two coordinators over one durable record share the generation.**
    private var localGeneration: UInt64

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
                runtime: TransportRuntimeSeam, authority: IdentityAuthoritySeam, hooks: WipeHooks = NoHooks(),
                estateArtifacts: [String] = []) {
        self.store = store
        self.vault = vault
        self.filesystem = filesystem
        self.runtime = runtime
        self.authority = authority
        self.hooks = hooks
        self.estateArtifacts = estateArtifacts
        self.journal = store.readJournal()
        self.localGeneration = (store as? WipeEpochReporting)?.durableEpoch ?? 0
    }

    /// *** IOS-R2: THE DURABLE RUNG, READ FROM THE STORE *NOW* -- never from the cached mirror. ***
    ///
    /// *A write performed by another instance (or an operator) moveth this answer immediately, which is what makes
    /// "a wipe requested through another owner" observable at this one.*
    private func liveJournal() -> [String] { store.readJournal() }

    /// *** THE DURABLE GENERATION, LIVE: the store's own counter where it hath one, else this instance's monotone. ***
    public func durableGeneration() -> UInt64 {
        (store as? WipeEpochReporting)?.durableEpoch ?? localGeneration
    }

    /// *** IOS-FOLLOWUP-C1/C3: THE SETTLED ESTATE'S *ACKNOWLEDGED* GENERATION, OR NOTHING. ***
    ///
    /// *The bootstrap may issue a permit for a settled decision ONLY against this snapshot. The record must be
    /// readable, its medium must vouch for itself (`readDurable` answers non-nil), it must stand at IDLE, and the
    /// rung must carry a KNOWN generation. There is no fabricated zero and no `permit.generation` fallback: a
    /// record that cannot name its own acknowledged generation admits nothing -- validating the rung, not merely the
    /// `committed` case, is what this answers.*
    /// *** CURRENT-02 (the parent's real Foundation compile): A SCALAR, NOT A SINGLE-ELEMENT LABELLED TUPLE. ***
    /// *Swift cannot give a single-element tuple a label (`(generation: UInt64)?` is invalid, and `.generation` on it
    /// has no member), so callers could neither compile nor compare. The generation is a plain `UInt64?` -- boring, no
    /// allocation, and the only thing the settled/admission roads ever asked for.*
    public func settledSnapshot() -> UInt64? {
        guard isSupportedJournal(), let durable = store.readDurable(),
              durable.state == .idle, let generation = durable.epoch else { return nil }
        return generation
    }

    /// *** IOS-FOLLOWUP-C1/C2: THE CLEAN ESTATE'S BASELINE, DURABLY ESTABLISHED AND *CHECKED*. ***
    ///
    /// *A brand-new estate carries no generation, and a permit may only bind to a generation the medium has
    /// ACKNOWLEDGED. So the baseline advances through the checked epoch road and its success is REQUIRED: a
    /// visible-but-unsynchronized baseline answers `false`, the bootstrap answers `terminalFailure`, and no permit
    /// mints. Idempotent: a baseline already standing on the medium is accepted because the medium itself vouches
    /// for it (`readDurable` is the medium's own answer, never a cache).*
    public func establishBaseline() -> Bool {
        guard isReadableJournal(), liveJournal().isEmpty,
              let durable = store.readDurable(), durable.state == .idle else { return false }
        if durable.epoch != nil { return true }   // already-acknowledged baseline
        // *** CURRENT-01: HISTORY IS NOT A FIRST LAUNCH. *** *A store that carrieth no nameable generation but DOES
        // carry a record (or a standing floor) is refused by the bump below (a claiming store answereth `nil` there),
        // so this answereth `false` and the bootstrap tell the caller the estate's history cannot be established
        // instead of minting a permit at a recycled generation.*
        guard (store as? WipeEpochReporting)?.bumpEpoch() != nil else { return false }
        // *** AND THE PHASE IS STAMPED WITH THAT GENERATION, so the durable record and the floor agree and the
        // settled/admission roads (which require BOTH) can name this estate. A record without its floor, or a floor
        // without its record, is UNPINNED by construction and would be refused. ***
        do {
            try writeChecked(WipeJournalState.wireName(.idle), to: .idle)
        } catch {
            return false
        }
        return true
    }

    /// *** IOS-FOLLOWUP-C3: THE GENERATION THE MEDIUM ITSELF VOUCHETH FOR -- NO COORDINATOR-LOCAL FABRICATION. ***
    ///
    /// *`durableGeneration()` is the reporting read (it may fall back to the instance mirror for courts that own no
    /// counter). This is the authority read a PRODUCTION effect must be bound to: the store's own counter where it
    /// claimeth one, else the medium's OWN bytes via `readDurable` -- and `nil` when neither can answer, which the
    /// ladder treateth as refusal rather than a recycled zero.*
    private func verifiedMediumGeneration() -> UInt64? {
        if let reported = (store as? WipeEpochReporting)?.durableEpoch { return reported }
        return store.readDurable()?.epoch
    }

    /// The current durable state, or nil when the journal is empty (nothing ever requested) -- **LIVE**.
    private func current() -> WipeJournalState? {
        guard let last = liveJournal().last else { return nil }
        return WipeJournalState.fromWire(last)
    }

    /// True while any ladder state is outstanding: the gate must stay closed across the whole span.
    /// *** IOS-R2: ASKED OF THE DURABLE RECORD, NOT OF A BIRTH-TIME SNAPSHOT. ***
    public var isWipePending: Bool {
        guard let c = current() else { return false }
        return c != .idle
    }

    /// The gate answers from the LIVE journal alone -- it cannot be bypassed by a cached flag, and it observeth a
    /// wipe requested through another owner.
    public func allowsStartup() -> Bool { allowsSensitiveApi() }
    public func allowsSensitiveApi() -> Bool {
        guard isSupportedJournal(), let durable = store.readDurable(), durable.epoch != nil else { return false }
        return durable.state == .idle
    }

    /// A journal is well-formed when every line parses and, within each completed wipe
    /// segment (a segment ends at IDLE), ranks strictly increase. Segmentation honours the
    /// append-only durability: a second wipe legitimately restarts the ladder at REQUESTED.
    /// *** GS-FINAL-003: IS THE DURABLE RECORD READABLE AT ALL? ***
    ///
    /// *`isSupportedJournal()` answers about the LOADED rungs; this answers about the SOURCE.* The
    /// difference is measured: a journal whose durable value cannot be parsed loads as an EMPTY
    /// ladder -- which `isSupportedJournal()` reports as well-formed -- so a caller asking only that
    /// question would see "no pending wipe" where the truth is "the record is unreadable". The
    /// adapter is asked directly, and a store with no such notion answers `true` rather than
    /// pretending to know.
    public func isReadableJournal() -> Bool {
        // FAIL-CLOSED, matching `WipeJournal.isReadable`'s own default and for the same reason:
        // a store that has not been asked the question has not answered it, and the permissive
        // reading of an unanswerable question is the one that opens private stores over material
        // nobody managed to read. `WipeJournalDurabilityAdapter` answers explicitly, so this
        // default is reached only by a conformer that has not considered it.
        store.isReadable
    }

    /// *** IOS-FOLLOWUP-H1: A SUPPORTED JOURNAL MUST ALSO BE READABLE. ***
    ///
    /// *THE REVIEW: "`allowsSensitiveApi` still returns only `!isWipePending`. An unreadable value is coerced to
    /// idle; the adapter turns idle into an empty list; the gate then returns true."* **So an UNREADABLE record is
    /// NEVER "supported": the retained admission consulteth this, and a corrupt record therefore refuses rather than
    /// resembling an empty clean one.**
    public func isSupportedJournal() -> Bool { isReadableJournal() && Self.supported(liveJournal()) }

    /// *** The normalized view of the journal for assertions (legacy spellings mapped, never mutated) -- **LIVE**. ***
    public func journalView() -> [WipeJournalState?] { liveJournal().map { WipeJournalState.fromWire($0) } }

    private static func supported(_ lines: [String]) -> Bool {
        var rank = 0
        for line in lines {
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

    /// *** IOS-R1/R2: ONE SERIALIZATION POINT AROUND EVERY REAL DRIVE, WITH A REENTRANCY REFUSAL. ***
    ///
    /// *Two owners over one durable record are refused rather than interleaved; a reentrant drive (a seam that
    /// re-enters) is refused rather than run twice -- which is the "duplicate effects / checkpoint regression" the
    /// review named.*
    /// *** IOS-R1/R2 + IOS-FOLLOWUP-CURRENT-07: ONE SERIALIZATION POINT AROUND EVERY REAL DRIVE. ***
    ///
    /// *Two owners over one durable record are refused rather than interleaved; a reentrant drive (a seam that
    /// re-enters) is refused rather than run twice. **AND THE MUTATION ALSO HOLDS THE SHARED PHYSICAL-ESTATE
    /// AUTHORITY'S LOCK**, because the finding measured that `requestFresh`/`resume`/operator resolution wrote the
    /// journal while another composition held the global admission/construction lock: the coordinator's own
    /// `driveLock` excludes other COORDINATORS, but not a private construction. The authority's lock is recursive, so
    /// this nests safely inside the composition's own `serialized` section.*
    private func serialized<T>(_ body: () throws -> T) throws -> T {
        try PhysicalEstateAuthority.shared.serialized {
            driveLock.lock()
            defer { driveLock.unlock() }
            if inDrive { throw WipeDriveError.reentrant }
            inDrive = true
            defer { inDrive = false }
            return try body()
        }
    }

    /// Begin a wipe. From IDLE/empty this records REQUESTED DURABLY FIRST (and bumps the generation), then drives
    /// the ladder as far as it can.
    /// Records REQUESTED durably in the journal (bumping generation), without driving the ladder yet.
    public func recordWipeRequest() throws {
        try serialized {
            if !isSupportedJournal() { return }
            if isWipePending { return }
            try persistRequest()
        }
    }

    public func requestWipe() throws -> WipeStepResult {
        try serialized {
            if !isSupportedJournal() { return .refused(reason: "journal carries an unsupported state; refusing to guess") }
            if isWipePending { return .refused(reason: "a wipe is already outstanding; one composition root drives the ladder") }
            try persistRequest()
            return try runLadder()
        }
    }

    /// Resume after death: drive strictly from the durable journal.
    public func resume() throws -> WipeStepResult {
        try serialized {
            if !isSupportedJournal() { return .refused(reason: "journal carries an unsupported state; refusing to guess") }
            guard let c = current() else { return .refused(reason: "nothing to resume; no wipe was ever requested") }
            if c == .idle { return .alreadyAtOrPast(c) }
            return try runLadder()
        }
    }

    /// Drive the ladder one call, advancing as far as the seams allow.
    public func step() throws -> WipeStepResult {
        try serialized {
            if !isSupportedJournal() { return .refused(reason: "journal carries an unsupported state; refusing to guess") }
            guard let c = current() else { return .refused(reason: "no journal entry") }
            if c == .idle { return .alreadyAtOrPast(c) }
            return try runLadder()
        }
    }

    /// *** IOS-R3: REQUESTED IS COMMITTED *BEFORE* ANY EFFECT, AND ITS ACKNOWLEDGMENT IS REQUIRED. ***
    ///
    /// *A dropped or refused `REQUESTED` write THROWETH here, so the ladder never begins and no destruction happens
    /// on an unrecorded request.* **And the durable generation is bumped HERE, once, so a permit minted before this
    /// request is invalidated by it (ABA).**
    private func persistRequest() throws {
        // THE GENERATION ADVANCETH BEFORE THE WRITE, so the committed checkpoint carrieth the NEW generation.
        //
        // *** IOS-FOLLOWUP-C3: WHEN THE STORE CLAIMS AN EPOCH COUNTER, THAT COUNTER IS THE AUTHORITY. ***
        // *A `nil` answer from `bumpEpoch()` is NOT a licence to fabricate a local successor: it sayeth the medium
        // could not advance the generation (a synchronization refusal on the production journal). Silently
        // incrementing `localGeneration` there would let the ladder run a full rung span whose checkpoints are
        // bound to a number the medium never acknowledged. So a claiming store that cannot advance THROWS, the
        // request stayeth unrecorded, and no destruction beginneth. Only a store that never claimed a counter at
        // all (no conformance) keeps the coordinator-local monotone fallback the protocol documents.*
        if let reporting = store as? WipeEpochReporting {
            guard let advanced = reporting.bumpEpoch() else {
                throw WipeCheckpointError(
                    rung: .requested,
                    reason: "the durable epoch counter could not be advanced on the medium (no fabricated generation)")
            }
            localGeneration = advanced
        } else {
            localGeneration &+= 1
        }
        try writeChecked(WipeJournalState.wireName(.requested), to: .requested)
    }

    /// *** IOS-R3: A WRITE THAT DROPPED MUST NOT ADVANCE THE LADDER. ***
    ///
    /// *The append ANSWEReth; `.refused` throweth a `WipeCheckpointError` so the rung the ladder just performed is
    /// NOT recorded, the wipe stayeth pending, and no private permit can be issued from an uncommitted terminal.*
    private func persist(_ from: WipeJournalState, _ to: WipeJournalState) throws {
        precondition(to.rawValue == from.rawValue + 1, "illegal ladder step")
        try writeChecked(WipeJournalState.wireName(to), to: to)
    }

    private func writeChecked(_ name: String, to state: WipeJournalState) throws {
        try hooks.beforeWrite(name)
        let checkpoint = store.appendJournal(name)
        guard case .committed = checkpoint else {
            let reason: String
            if case let .refused(_, r) = checkpoint { reason = r } else { reason = "the durable store did not commit the checkpoint" }
            throw WipeCheckpointError(rung: state, reason: reason)
        }
        journal.append(name)
    }

    private func runLadder() throws -> WipeStepResult {
        guard var from = current() else { return .refused(reason: "no journal entry") }
        while true {
            switch from {
            case .requested:
                // *** IOS-R5: THE DRAIN IS ANSWERED BY THE ESTATE'S OWN OWNERS. ***
                //
                // *The finding measured a recovery entry that drained a NEW `BleTransport()` -- "a new transport
                // [with] no active context; its barrier immediately succeeds ... without touching the estate's live
                // transport, stores, sessions, or producers."* **So when the estate supplyeth an owner-drain
                // capability, it is THAT answer which governeth the rung; the transport seam is the fallback for a
                // coordinator that owns a real radio directly.** *A `.ownersLive` answer keepeth the wipe pending.*
                if let owners = runtime as? WipeOwnerDraining {
                    switch owners.drainOwners() {
                    case .drained, .cold:
                        break
                    case .ownersLive(let reason):
                        return .retryLater(at: from, reason: reason)
                    }
                } else {
                    let receipt = runtime.drainTransport()
                    if !receipt.isDrained {
                        if case let .notDrained(reason) = receipt { return .retryLater(at: from, reason: reason) }
                        return .retryLater(at: from, reason: "drain refused")
                    }
                }
                try persist(from, .runtimeDrained)
            case .runtimeDrained:
                // the drain is a THIS-lifetime property: after a reboot the volatile queues are live
                // again, so the quiesce must be re-proven in this process before the point of no return
                //
                // *** IOS-FOLLOWUP-C6: AN `WipeOwnerDraining` SEAM IS RE-PROVEN TOO, AND ITS VERDICT IS HONOURED. ***
                //
                // *THE REVIEW, VERBATIM: "The runtimeDrained branch re-drains only when the runtime is not
                // WipeOwnerDraining. Both new estate seams are WipeOwnerDraining, so a fresh seam with isQuiesced ==
                // false resumes straight into key erasure."* **So the owner drain is ALWAYS consulted for a
                // WipeOwnerDraining seam -- a `.ownersLive` answer STOPS the ladder here, BEFORE any key is erased.***
                if let owners = runtime as? WipeOwnerDraining {
                    switch owners.drainOwners() {
                    case .drained, .cold:
                        break
                    case .ownersLive(let reason):
                        return .retryLater(at: from, reason: reason)
                    }
                } else if !runtime.isQuiesced() {
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
                // *** IOS-R7: THE ESTATE'S OWN INVENTORY IS ITERATED, not only the fixed default names. ***
                // *Names are de-duplicated and ordered (deterministic), and an unmapped name answers `.failed` --
                // which is the honest reason a wipe stalls rather than a silent success against a file it never
                // addressed.*
                var inventory = estateArtifacts.isEmpty
                    ? WipeScope.filterPrivatePaths(WipeScope.privateArtifacts)
                    : estateArtifacts
                for p in inventory.sorted() {
                    if case let .failed(path, _) = filesystem.deleteArtifact(p) { failedPaths.append(path) }
                }
                if !failedPaths.isEmpty {
                    return .retryLater(at: from, reason: failedPaths.joined(separator: ","))
                }
                try persist(from, .artifactsDeleted)
            case .artifactsDeleted:
                // *** IOS-R8: PUBLICATION IS IDEMPOTENT AND BOUND TO THIS WIPE'S GENERATION. ***
                //
                // *THE FINDING: at ARTIFACTS_DELETED, recovery wrote a replacement identity BEFORE recording
                // NEW_IDENTITY; if the process died in between, the next attempt called `generateAndStore` again,
                // and that REFUSED the already-present identity -- bricking recovery at ARTIFACTS_DELETED forever.*
                // **So the identity authority is asked to publish OR ADOPT the identity for THIS generation: a
                // crash between publication and the NEW_IDENTITY write then RE-OPENS on the SAME identity and
                // settlETH, rather than generating a second (refused) one.**
                // *** IOS-FOLLOWUP-C3: THE PUBLICATION IS BOUND TO THE *MEDIUM'S* GENERATION, NEVER THE LOCAL MIRROR. ***
                // *`durableGeneration()` fallseth back to a coordinator-local counter when the store claimeth no
                // epoch -- a number the medium never acknowledged. Binding an identity publication to that
                // fabrication would let a replayed or epoch-less record adopt an identity under a generation no
                // commit ever carried, so the rung reads the MEDIUM and refuseth when the medium cannot answer.*
                guard let generation = verifiedMediumGeneration() else {
                    return .retryLater(at: from, reason: "the durable record carryeth no acknowledged generation; "
                        + "no identity may be published against a fabricated one")
                }
                guard authority.publishOrAdoptIdentity(wipeGeneration: generation) != nil else {
                    return .retryLater(at: from, reason: "no identity could be published")
                }
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

    /// *** IOS-R6/A7: THE OPERATOR'S EXPLICIT RESOLUTION OF A CORRUPT RECORD -- ERASURE, NOT A CLEAR. ***
    ///
    /// *THE FINDING: "Corrupt operator resolution: complete own wipe, not clear journal normal."* **So the operator's
    /// act DURABLY RECORDS `REQUESTED` first and then performs the FULL owned wipe through the same ladder -- it
    /// NEVER clearéth the journal to read as a clean start over whatever material made it unreadable.** *The
    /// resolution is RESTRICTED to a genuinely corrupt record; a readable estate answereth a named refusal.*
    public func resolveCorruptForOperator() throws -> WipeStepResult {
        try serialized {
            if isReadableJournal(), isSupportedJournal() {
                return .refused(reason: "the operator's corrupt resolution is offered only for an unreadable record")
            }
            // (1) DURABLY RECORD THE REQUEST before any effect -- a resolution that erased without recording is not
            // resumable. `recordRequestDurably` bumps the generation and writes CHECKED `REQUESTED`.
            try persistRequest()
            // (2) THE SAME LADDER PERFORMS THE FULL ERASURE AND ANSWERETH ITS TYPED RESULT.
            return try runLadder()
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

/// *** IOS-R3: A CHECKPOINT THAT DID NOT COMMIT. *** *The ladder stopped at `rung` and the wipe stayeth pending.*
public struct WipeCheckpointError: Error, Equatable {
    public let rung: WipeJournalState
    public let reason: String
    public init(rung: WipeJournalState, reason: String) { self.rung = rung; self.reason = reason }
}

/// *** IOS-R1/R2: A REENTRANT OR CONCURRENT DRIVE WAS REFUSED. ***
public struct WipeDriveError: Error, Equatable {
    public let reason: String
    public static let reentrant = WipeDriveError(
        reason: "a drive of this estate is already in progress; refused rather than run twice")
    public init(reason: String) { self.reason = reason }
}
