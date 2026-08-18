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

/// Production `WipeArtifacts` for iOS.
///
/// `eraseKeys` deletes the two Keychain identity items via
/// `MeshIdentity.deleteFromKeychain()` -- on iOS the private keys ARE the
/// secret (there is no separate KEK wrapping ciphertext files as on Android),
/// so this is both key destruction and artifact deletion in one step.
/// `deleteArtifacts` deletes the durable DTN store DB file (Phase G) when a
/// `storeUrl` is registered; the Keychain keys are already gone by this point
/// (eraseKeys), so this is cleanup of now-useless artifacts, coordinated with
/// the store + identity wipe as on Android. `regenerateIdentity` builds a fresh
/// identity via `MeshIdentity.generateAndStore()`.
///
/// Each step is idempotent: `SecItemDelete` on an absent item is a no-op,
/// `SqliteMessageStore.panicWipe(at:)` on an absent file is a no-op, and
/// `generateAndStore` creates fresh keys (deleting any same-tag item first).
public final class KeychainWipeArtifacts: WipeArtifacts {
    /// URL of the durable store DB file to wipe in `deleteArtifacts`. Nil when
    /// no durable store is configured (the wipe then only touches the Keychain).
    private let storeUrl: URL?

    /// `storeUrl` registers the durable DTN store for coordinated wipe.
    public init(storeUrl: URL? = nil) {
        self.storeUrl = storeUrl
    }

    public func eraseKeys() throws {
        // Crypto erasure: the keys are the secret. Deleting them makes prior
        // traffic permanently unlinkable. Idempotent (errSecItemNotFound ok).
        try MeshIdentity.deleteFromKeychain()
    }

    public func deleteArtifacts() {
        // Delete the durable store DB file (+ WAL/SHM). The Keychain keys are
        // already gone (eraseKeys); this is cleanup of the now-useless artifact
        // container, coordinated with the identity wipe. Idempotent.
        if let url = storeUrl {
            SqliteMessageStore.panicWipe(at: url)
        }
    }

    public func regenerateIdentity() throws {
        _ = try MeshIdentity.generateAndStore()
    }
}