import Foundation

// ---------------------------------------------------------------------------
// T30 MIGRATION - the transactional PlaintextToEncryptedMigration.
//
// Migrates an existing NON-SHIPPING plaintext store to the encrypted store,
// under the wipe/runtime gate, and NEVER selects an unverified copy:
//   1. the public read-only Archive is NOT a migration subject -- it is skipped
//      and stays separate (never encrypted, never swapped);
//   2. the wipe/runtime gate is consulted first; when it does not permit, nothing
//      on disk is touched (refusedByGate);
//   3. the DEK is obtained (created on first migration), fail-closed -- if the
//      Keychain/DEK is unavailable the ORIGINAL plaintext source is left intact
//      and recoverable (sourcePreservedOnFailure), never dropped;
//   4. an encrypted copy is prepared but NOT yet selected;
//   5. the encrypted copy is VERIFIED against the expected row count / header /
//      cipher version; ONLY a good verification is followed by selectEncryptedCopy
//      (the atomic swap that retires the plaintext);
//   6. any failure at any step refuses to select -- there is no plaintext
//      fallback and no destroyed original -- AND THE "SOURCE IS PRESERVED"
//      CLAIM IS **MEASURED**, NOT DERIVED FROM WHERE THE FAILURE HAPPENED
//      (GS-FINAL-004 clause (d): "...a separate RESUMABLE operation with
//      PRESERVED ROLLBACK EVIDENCE"). A torn swap -- the encrypted copy
//      adopted, the plaintext retired, the operation then failed -- reports
//      `sourceRetiredCopyUnselected` with `requiresResume`, because NEITHER
//      "migrated" NOR "source preserved" is true.
//
// The concrete file copy+encrypt and the SQLCipher restore-from-back are the
// device [PlaintextMigrationEngine]; on the host the injected engine + fake drive
// the SAME ordering laws the ReadinessT30Tests court asserts (verify-before-select,
// source-preserved-on-failure, gate-refusal, archive-separate). Physical bytes are
// device evidence.
// ---------------------------------------------------------------------------

public protocol WipeRuntimeGate: AnyObject {
    func allowsStoreMigration() -> Bool
}

public struct MigrationVerification: Equatable, @unchecked Sendable {
    public let rowCountMatched: Bool
    public let headerOk: Bool
    public let cipherVersionMatched: Bool
    public init(rowCountMatched: Bool, headerOk: Bool, cipherVersionMatched: Bool) {
        self.rowCountMatched = rowCountMatched; self.headerOk = headerOk; self.cipherVersionMatched = cipherVersionMatched
    }
    public var isGood: Bool { rowCountMatched && headerOk && cipherVersionMatched }
}

public enum MigrationFailureReason: Equatable, @unchecked Sendable {
    case keychainUnavailable
    case deviceLocked
    case verificationMismatch
    case corruptEncryptedCopy
    case ioFailure(String)
}

public enum MigrationOutcome: Equatable, @unchecked Sendable {
    case migrated(verifiedRows: Int)
    case alreadyEncrypted
    case refusedByGate
    case sourcePreservedOnFailure(MigrationFailureReason)
    case archiveSkipped
    /// *** GS-FINAL-004 CLAUSE (d): THE SOURCE IS GONE AND THE COPY WAS NEVER SELECTED. ***
    ///
    /// THIS IS THE TORN SWAP -- the encrypted copy was prepared (and may even be adoptable), the plaintext source was
    /// RETIRED, and the operation then failed. **NEITHER `migrated` NOR `sourcePreservedOnFailure` IS TRUE**: nothing
    /// is selected, and there is no plaintext source left to fall back to. IT IS NOT A DATA LOSS, because the prepared
    /// encrypted copy remaineth on disk and the operation is RESUMABLE -- but **THE CALLER MUST NOT BE TOLD EITHER OF
    /// THE TWO COMFORTABLE THINGS, WHICH IS EXACTLY WHAT "PRESERVED ROLLBACK EVIDENCE" MEANS.**
    case sourceRetiredCopyUnselected(MigrationFailureReason)
    public var didMigrate: Bool { if case .migrated = self { return true }; return false }
    public var sourcePreserved: Bool {
        switch self {
        case .sourcePreservedOnFailure, .refusedByGate, .alreadyEncrypted, .archiveSkipped: return true
        case .migrated, .sourceRetiredCopyUnselected: return false
        }
    }
    /// True when the operation must be RESUMED rather than repeated -- the source is consumed but nothing was
    /// selected, so a blind retry would migrate a store that no longer exists. This is the flag a resumable caller
    /// branches on.
    public var requiresResume: Bool { if case .sourceRetiredCopyUnselected = self { return true }; return false }
}

/// The device-side copy/encrypt/verify/select seam. On the device these are real file
/// + SQLCipher operations; the contract is that NOTHING is selected until verified and
/// the plaintext source is never destroyed before the encrypted copy is verified good.
public protocol PlaintextMigrationEngine: AnyObject {
    /// True when `path` is a non-shipping plaintext store needing migration; false when it is
    /// already on the pinned SQLCipher engine (already encrypted). Throws on an io fault.
    func sourceRequiresMigration(path: String) throws -> Bool
    /// The row count the encrypted copy must reproduce for verification. Throws on an io fault.
    func expectedRowCount(plaintextPath: String) throws -> Int
    /// Copy + encrypt WITHOUT selecting (does not touch/retire the source). Throws on failure.
    func prepareEncryptedCopy(plaintextPath: String, encryptedPath: String, dek: StoreDEK) throws
    /// Verify the prepared encrypted copy against the expected row count / header / cipher version.
    func verifyEncryptedCopy(encryptedPath: String, dek: StoreDEK, expectedRowCount: Int) throws -> MigrationVerification
    /// The atomic swap that selects the verified encrypted copy and retires the plaintext.
    func selectEncryptedCopy(plaintextPath: String, encryptedPath: String) throws
    /// *** GS-FINAL-004 CLAUSE (d): IS THE PLAINTEXT SOURCE STILL ON DISK? ***
    ///
    /// THE CARD ASKETH FOR *"...A SEPARATE RESUMABLE OPERATION WITH PRESERVED ROLLBACK EVIDENCE"*. **A "PRESERVED"
    /// CLAIM THAT NOBODY CHECKS IS AN ASSUMPTION, NOT EVIDENCE** -- and the swap it describerth is not atomic in the
    /// sense the old code assumed: the encrypted copy is ADOPTED, the source is RETIRED, and **A CRASH BETWEEN THOSE
    /// TWO STEPS LEAVETH THE SOURCE GONE.** The old outcome map derived `sourcePreserved` from WHERE the failure
    /// happened (anything before the final throw counted as preserved), so THE ONE CASE WHERE THE CLAIM IS FALSE WAS
    /// THE ONE CASE THE CODE COULD NOT SEE. This query is the observable that settlerh it, and it is ALSO the
    /// resume's first question: **a resumed migration asketh "does the source still need migrating?" and must be able
    /// to ask "did my previous attempt already consume it?"**
    func sourceIsPresent(plaintextPath: String) throws -> Bool
}

public final class PlaintextToEncryptedMigration: @unchecked Sendable {
    private let engine: PlaintextMigrationEngine
    private let provider: PrivateStoreKeyProvider
    private let gate: WipeRuntimeGate
    private let cipherVersion: Int

    public init(engine: PlaintextMigrationEngine, provider: PrivateStoreKeyProvider, gate: WipeRuntimeGate, cipherVersion: Int) {
        self.engine = engine; self.provider = provider; self.gate = gate; self.cipherVersion = cipherVersion
    }

    /// Migrate `plaintextPath` to an encrypted store at `encryptedPath`, keyed by `tag`.
    /// `isArchive` marks the public read-only Archive, which is never migrated or encrypted.
    public func migrate(plaintextPath: String, encryptedPath: String, tag: String, isArchive: Bool = false) -> MigrationOutcome {
        // (1) The Archive stays public read-only SQLite and separate -- never a migration subject.
        if isArchive { return .archiveSkipped }
        // (2) Under the wipe/runtime gate: consult it FIRST; refuse without touching disk when closed.
        guard gate.allowsStoreMigration() else { return .refusedByGate }
        // (3) Detect need; on an io fault the untouched source is trivially recoverable.
        let requires: Bool
        do { requires = try engine.sourceRequiresMigration(path: plaintextPath) }
        catch { return .sourcePreservedOnFailure(.ioFailure("sourceRequiresMigration")) }
        if !requires { return .alreadyEncrypted }
        // (3) Obtain the DEK; never drop the source if the Keychain/DEK is unavailable.
        let dek: StoreDEK
        do {
            dek = try provider.fetchDEK(tag: tag)
        } catch let e {
            if case StoreKeyError.dekNotFound = e {
                do { dek = try provider.createDEK(tag: tag) }
                catch let e2 { return .sourcePreservedOnFailure(mapProvider(e2)) }
            } else { return .sourcePreservedOnFailure(mapProvider(e)) }
        }
        let expected: Int
        do { expected = try engine.expectedRowCount(plaintextPath: plaintextPath) }
        catch { return .sourcePreservedOnFailure(.ioFailure("expectedRowCount")) }
        // (4) Prepare the encrypted copy WITHOUT selecting it.
        do { try engine.prepareEncryptedCopy(plaintextPath: plaintextPath, encryptedPath: encryptedPath, dek: dek) }
        catch { return failurePreservingSource(plaintextPath: plaintextPath, reason: .ioFailure("prepareEncryptedCopy")) }
        // (5) VERIFY the encrypted copy BEFORE selecting.
        let verification: MigrationVerification
        do { verification = try engine.verifyEncryptedCopy(encryptedPath: encryptedPath, dek: dek, expectedRowCount: expected) }
        catch { return failurePreservingSource(plaintextPath: plaintextPath, reason: .corruptEncryptedCopy) }
        guard verification.isGood else { return failurePreservingSource(plaintextPath: plaintextPath, reason: .verificationMismatch) }  // never select an unverified copy
        // (6) Select (atomic swap) only after a good verification.
        do { try engine.selectEncryptedCopy(plaintextPath: plaintextPath, encryptedPath: encryptedPath) }
        catch { return failurePreservingSource(plaintextPath: plaintextPath, reason: .ioFailure("selectEncryptedCopy")) }
        return .migrated(verifiedRows: expected)
    }

    /// *** THE ROLLBACK CLAIM, MEASURED. ***
    ///
    /// EVERY FAILURE PATH BEYOND THE DEK GOES THROUGH HERE, AND THE OUTCOME IS DECIDED BY ASKING THE ENGINE **WHERE
    /// THE SOURCE ACTUALLY IS** -- never by where in this function the failure happened. **THE OLD CODE MADE THE
    /// POSITIONAL ASSUMPTION AND WAS WRONG IN THE ONE CASE THAT MATTERED: a crash after the encrypted copy was
    /// adopted but before the source was retired returned `sourcePreservedOnFailure` while the source was gone.** A
    /// query that throws is treated as the WORSE case (the source cannot be shown to survive), because failing closed
    /// must never manufacture a comfortable answer.
    private func failurePreservingSource(plaintextPath: String, reason: MigrationFailureReason) -> MigrationOutcome {
        let present = (try? engine.sourceIsPresent(plaintextPath: plaintextPath)) ?? false
        return present ? .sourcePreservedOnFailure(reason) : .sourceRetiredCopyUnselected(reason)
    }

    private func mapProvider(_ e: Error) -> MigrationFailureReason {
        if let k = e as? StoreKeyError {
            switch k {
            case .keychainUnavailable, .dekNotFound, .dekWrongLength, .protectionFailure: return .keychainUnavailable
            case .deviceLocked: return .deviceLocked
            case .decodingFailure: return .corruptEncryptedCopy
            }
        }
        return .keychainUnavailable   // fail-closed: treat an unknown Keychain fault as unavailable and preserve the source
    }
}
