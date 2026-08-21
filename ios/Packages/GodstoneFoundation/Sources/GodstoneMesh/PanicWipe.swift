import Foundation
import Security

// MARK: - Coordinated, resumable, cryptographic-erasure panic wipe

/// The persisted phase of an in-progress wipe (ADR-004 criterion 5,
/// GST-WIPE-001). Ordered by the `PanicWipe.run()` ladder.
public enum WipeState: String, Sendable {
    case idle
    case requested
    case keyErased
    case artifactsDeleted
    case newIdentity
}

/// Crash-safe marker for the wipe state machine. Implementations must persist
/// across a reboot/jetsam so `PanicWipe.resumeIfPending()` can finish an
/// interrupted wipe.
public protocol WipeJournal: AnyObject {
    func read() -> WipeState
    func write(_ state: WipeState)
    func clear()
}

/// The three idempotent destroy/rebuild steps, injectable so the state machine
/// is host-testable without the Keychain. See `PanicWipe` for the ordering
/// contract.
public protocol WipeArtifacts: AnyObject {
    /// Destroy the long-lived secret keys. After this, prior data is
    /// cryptographically erased (unrecoverable) even if its container still
    /// exists. This is the point of no return. Throwing propagates as a wipe
    /// failure: the journal is NOT advanced past this step, so the next
    /// `resumeIfPending()` retries it.
    func eraseKeys() throws
    /// Delete the now-useless artifact containers (ciphertext files, DBs,
    /// prefs). Idempotent. On iOS this deletes the durable DTN store DB file
    /// (Phase G); the Keychain keys themselves are removed by `eraseKeys`.
    func deleteArtifacts() throws
    /// Generate + store a fresh identity.
    func regenerateIdentity() throws
}

/// A small persisted state machine that destroys long-lived secrets across the
/// store + identity + the key material that protects them, then regenerates a
/// fresh identity so prior traffic cannot be linked to the new node.
///
/// It is crash-safe: the state is written to a durable `WipeJournal` AFTER each
/// step completes, and every step is idempotent, so a crash-then-resume re-runs
/// at most the one step that was interrupted and then continues forward. The
/// ordering is deliberate:
///
///     idle -> requested -> keyErased -> artifactsDeleted -> newIdentity -> idle
///
///       requested        -- wipe requested, nothing destroyed yet
///       eraseKeys()      -- destroy the keys. After this the data is
///                           cryptographically erased. Point of no return.
///       keyErased        -- keys gone, containers may still exist but unreadable
///       deleteArtifacts()-- delete the now-useless containers. Idempotent.
///       artifactsDeleted -- no recoverable artifacts remain
///       regenerateIdentity() -- create a fresh identity.
///       newIdentity      -- new identity in place
///       clear()          -- drop the journal; back to idle.
///
/// Crypto-erasure-first is the safety property: even a total failure after
/// `eraseKeys()` cannot leave prior data recoverable. The remaining steps are
/// cleanup + re-identity, and the journal guarantees they eventually run.
///
/// The machine itself is pure (no Keychain/Security/UserDefaults touch); the
/// platform glue (`UserDefaultsWipeJournal`, `KeychainWipeArtifacts`) is
/// injected. `PanicWipeTests` drives the machine with fakes -- simulating a
/// crash before each step -- and asserts resumability + ordering + the
/// no-op-when-idle contract without a device or Keychain.
public final class PanicWipe {
    private let journal: WipeJournal
    private let artifacts: WipeArtifacts

    public init(journal: WipeJournal, artifacts: WipeArtifacts) {
        self.journal = journal
        self.artifacts = artifacts
    }

    /// Begin a wipe from a clean (idle) state. Writes `requested`, then
    /// advances as far as it can. A step that throws (a wipe failure / simulated
    /// crash) propagates: the journal is left at the last completed step, so the
    /// next `resumeIfPending()` finishes it.
    public func begin() throws {
        journal.write(.requested)
        try run()
    }

    /// If a wipe was in progress (journal != idle), finish it. Safe to call on
    /// every app launch. No-op when no wipe is pending.
    public func resumeIfPending() throws {
        guard journal.read() != .idle else { return }
        try run()
    }

    /// Advance from the persisted state to completion. Each rung checks the
    /// persisted state, performs that rung's step, then persists the next state
    /// -- so a throw between perform and persist re-runs that one idempotent
    /// step on resume, and a throw after persist skips it. The cascade runs
    /// every remaining rung unless a step throws; the journal then reflects the
    /// last completed rung and the next resume continues from there.
    private func run() throws {
        var s = journal.read()
        if s == .idle { s = .requested; journal.write(s) }
        if s == .requested {
            try artifacts.eraseKeys()
            s = .keyErased; journal.write(s)
        }
        if s == .keyErased {
            try artifacts.deleteArtifacts()
            s = .artifactsDeleted; journal.write(s)
        }
        if s == .artifactsDeleted {
            try artifacts.regenerateIdentity()
            s = .newIdentity; journal.write(s)
        }
        if s == .newIdentity {
            journal.clear()
        }
    }

    // MARK: - Production entry points

    /// Production entry point: start a full wipe using platform glue.
    public static func begin(journal: WipeJournal = UserDefaultsWipeJournal(),
                             artifacts: WipeArtifacts = KeychainWipeArtifacts()) throws {
        try PanicWipe(journal: journal, artifacts: artifacts).begin()
    }

    /// Call on app launch: finishes a wipe that a crash interrupted.
    public static func resumeIfPending(journal: WipeJournal = UserDefaultsWipeJournal(),
                                       artifacts: WipeArtifacts = KeychainWipeArtifacts()) throws {
        try PanicWipe(journal: journal, artifacts: artifacts).resumeIfPending()
    }
}

// MARK: - Production glue

/// Journal backed by UserDefaults. The marker is a single state string; it is
/// not sensitive and a leftover `.idle` marker is harmless. A non-idle marker
/// after a reboot is exactly the signal `resumeIfPending` acts on.
public final class UserDefaultsWipeJournal: WipeJournal {
    private let key = "io.godstone.wipe.state"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func read() -> WipeState {
        guard let raw = defaults.string(forKey: key) else { return .idle }
        return WipeState(rawValue: raw) ?? .idle
    }

    public func write(_ state: WipeState) {
        defaults.set(state.rawValue, forKey: key)
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }
}

/// Error taxonomy for panic wipe operations (ADR-004, Phase C8.2C).
public enum PanicWipeError: Error, Sendable, Equatable {
    case artifactDeletionFailed(String)
}

/// Production `WipeArtifacts` for iOS.
///
/// `eraseKeys` deletes the single authoritative V1 Keychain identity item
/// and any legacy migration items via `MeshIdentity.deleteFromKeychain()`.
/// Legacy two-key items may exist only during migration or interrupted migration.
/// `deleteFromKeychain` removes V1 and both legacy items.
///
/// `deleteArtifacts` deletes the durable DTN store DB file (Phase G) and peer store DB file
/// (Phase C8.2C) when configured; the Keychain keys are already gone by this point
/// (eraseKeys), so this is cleanup of now-useless artifacts, coordinated with
/// the store + identity wipe as on Android.
///
/// `regenerateIdentity` builds a fresh identity via `MeshIdentity.generateAndStore()`,
/// which creates generation 0 keys only into an EMPTY authority state and does NOT
/// delete or overwrite an existing identity.
///
/// Each step is idempotent: `SecItemDelete` on an absent item is a no-op,
/// `SqliteMessageStore.panicWipe(at:)` and `SqlitePeerIdentityStore.panicWipe(at:)` on absent files are no-ops.
public final class KeychainWipeArtifacts: WipeArtifacts {
    private let keychain: any LocalIdentityKeychain
    /// URL of the durable store DB file to wipe in `deleteArtifacts`. Nil when
    /// no durable store is configured (the wipe then only touches the Keychain).
    private let storeUrl: URL?
    /// URL of the durable peer store DB file to wipe in `deleteArtifacts`. Nil when
    /// no peer store is configured (the wipe then only touches the Keychain).
    private let peerStoreUrl: URL?

    private let messageStoreWiper: ((URL) -> Bool)?
    private let peerStoreWiper: ((URL) -> Bool)?

    /// `storeUrl` and `peerStoreUrl` register the durable DTN and peer stores for coordinated wipe.
    public init(storeUrl: URL? = nil, peerStoreUrl: URL? = nil) {
        self.keychain = DefaultLocalIdentityKeychain()
        self.storeUrl = storeUrl
        self.peerStoreUrl = peerStoreUrl
        self.messageStoreWiper = nil
        self.peerStoreWiper = nil
    }

    internal init(
        keychain: any LocalIdentityKeychain,
        storeUrl: URL? = nil,
        peerStoreUrl: URL? = nil,
        messageStoreWiper: ((URL) -> Bool)? = nil,
        peerStoreWiper: ((URL) -> Bool)? = nil
    ) {
        self.keychain = keychain
        self.storeUrl = storeUrl
        self.peerStoreUrl = peerStoreUrl
        self.messageStoreWiper = messageStoreWiper
        self.peerStoreWiper = peerStoreWiper
    }

    public func eraseKeys() throws {
        // Crypto erasure: the keys are the secret. Deleting them makes prior
        // traffic permanently unlinkable. Idempotent (errSecItemNotFound ok).
        try MeshIdentity.deleteFromKeychain(keychain: keychain)
    }

    public func deleteArtifacts() throws {
        // Delete the durable store DB files (+ WAL/SHM/journal). The Keychain keys are
        // already gone (eraseKeys); this is cleanup of the now-useless artifact
        // container, coordinated with the identity wipe. Idempotent.
        if let url = storeUrl {
            let ok = messageStoreWiper?(url) ?? SqliteMessageStore.panicWipe(at: url)
            if !ok {
                throw PanicWipeError.artifactDeletionFailed("Message store deletion failed")
            }
        }
        if let url = peerStoreUrl {
            let ok = peerStoreWiper?(url) ?? SqlitePeerIdentityStore.panicWipe(at: url)
            if !ok {
                throw PanicWipeError.artifactDeletionFailed("Peer identity store deletion failed")
            }
        }
    }

    public func regenerateIdentity() throws {
        _ = try MeshIdentity.generateAndStore(keychain: keychain)
    }
}