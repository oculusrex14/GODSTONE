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
//   6. any failure at any step preserves a recoverable source and refuses to
//      select -- there is no plaintext fallback and no destroyed original.
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
    public var didMigrate: Bool { if case .migrated = self { return true }; return false }
    public var sourcePreserved: Bool {
        switch self {
        case .sourcePreservedOnFailure, .refusedByGate, .alreadyEncrypted, .archiveSkipped: return true
        case .migrated: return false
        }
    }
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
        catch { return .sourcePreservedOnFailure(.ioFailure("prepareEncryptedCopy")) }
        // (5) VERIFY the encrypted copy BEFORE selecting.
        let verification: MigrationVerification
        do { verification = try engine.verifyEncryptedCopy(encryptedPath: encryptedPath, dek: dek, expectedRowCount: expected) }
        catch { return .sourcePreservedOnFailure(.corruptEncryptedCopy) }
        guard verification.isGood else { return .sourcePreservedOnFailure(.verificationMismatch) }  // never select an unverified copy
        // (6) Select (atomic swap) only after a good verification.
        do { try engine.selectEncryptedCopy(plaintextPath: plaintextPath, encryptedPath: encryptedPath) }
        catch { return .sourcePreservedOnFailure(.ioFailure("selectEncryptedCopy")) }
        return .migrated(verifiedRows: expected)
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
