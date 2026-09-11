import Foundation

// ---------------------------------------------------------------------------
// T30 FACTORY - the fail-closed EncryptedStoreFactory.
//
// It opens (or reopens) a private message / peer store ONLY through:
//   * the [PrivateStoreKeyProvider] Keychain seam, to obtain the ThisDeviceOnly
//     StoreDEK -- and it NEVER falls back to a plaintext or empty store when the
//     DEK, the Keychain, or file protection is unavailable; and
//   * an [EncryptedStoreEngine] seam that MUST report kind == .pinnedSQLCipher --
//     a plain SQLite engine is refused outright (the "no fallback plain SQLite"
//     law), so the system SQLite path can never masquerade as the encrypted store.
//
// The decision is TOTAL and FAIL-CLOSED: every thrown fault maps to a typed
// non-available EncryptedStoreOpenResult, and an opened handle that does not
// itself assert encrypted-at-rest on the pinned SQLCipher engine is rejected. A
// reopen of an EXISTING store requires the DEK: a missing DEK yields `.unavailable`,
// never a silently-empty healthy store. The concrete SQLCipher engine (the real
// PRAGMA key / cipher_version / cipher settings) and the Keychain items are the
// device adapter; on the host the injected seams drive the SAME decision laws the
// ReadinessT30Tests court asserts. Physical at-rest bytes are device evidence.
// ---------------------------------------------------------------------------

public enum StoreEngineKind: String, Sendable {
    case pinnedSQLCipher
    case plainSQLite
}

/// A successfully opened, encrypted private store handle. It carries the at-rest
/// assertions the factory verifies before ever returning `.available`.
public struct EncryptedStoreHandle: Equatable, @unchecked Sendable {
    public let path: String
    public let kind: StoreEngineKind
    public let encryptedAtRest: Bool
    public let cipherVersion: Int
    public init(path: String, kind: StoreEngineKind, encryptedAtRest: Bool, cipherVersion: Int) {
        self.path = path; self.kind = kind; self.encryptedAtRest = encryptedAtRest; self.cipherVersion = cipherVersion
    }
}

public enum EncryptedStoreOpenResult: Equatable {
    case available(EncryptedStoreHandle)
    case locked            // the DEK is present but the store cannot be decrypted with it
    case corrupt           // malformed header / an unclassified fault fails CLOSED here
    case unavailable       // DEK / Keychain / protection unavailable, or a plain-engine fallback refused
    case unsupportedVersion(found: Int, supported: Int)
    public var isAvailable: Bool { if case .available = self { return true }; return false }
}

/// The fault vocabulary an [EncryptedStoreEngine] throws; the factory classifies it.
public enum StoreOpenFault: Error, Equatable {
    case wrongKey
    case corruptHeader
    case cipherVersionMismatch(found: Int, supported: Int)
    case io(String)
}

/// The concrete engine seam (the real SQLCipher binding on the device; a deterministic
/// fake in the court). It must report its kind and open the file with the DEK applied.
public protocol EncryptedStoreEngine: AnyObject {
    var kind: StoreEngineKind { get }
    var supportedCipherVersion: Int { get }
    func openForWriting(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle
    func reopenRequiringDEK(path: String, dek: StoreDEK) throws -> EncryptedStoreHandle
}

public final class EncryptedStoreFactory: @unchecked Sendable {
    private let provider: PrivateStoreKeyProvider
    private let engine: EncryptedStoreEngine
    public init(provider: PrivateStoreKeyProvider, engine: EncryptedStoreEngine) {
        self.provider = provider; self.engine = engine
    }

    /// Open (creating if first install) the encrypted store at `path`, keyed by `tag`.
    public func openStore(path: String, tag: String) -> EncryptedStoreOpenResult {
        guard engine.kind == .pinnedSQLCipher else { return .unavailable }   // no plaintext fallback, ever
        let dek: StoreDEK
        do {
            dek = try provider.fetchDEK(tag: tag)
        } catch let e {
            if case StoreKeyError.dekNotFound = e {
                do { dek = try provider.createDEK(tag: tag) }                  // first install: mint the DEK
                catch let e2 { return mapProviderError(e2) }
            } else { return mapProviderError(e) }
        }
        let protection = provider.applyFileProtection(paths: [path], protection: .complete)
        guard protection.isSuccess else { return .unavailable }               // never swallow a protection error
        return finalize { try self.engine.openForWriting(path: path, dek: dek) }
    }

    /// Reopen an EXISTING encrypted store at `path`. Requires the DEK; a missing DEK is
    /// `.unavailable`, never an empty healthy store (this is the reopen-without-DEK law).
    public func reopenExisting(path: String, tag: String) -> EncryptedStoreOpenResult {
        guard engine.kind == .pinnedSQLCipher else { return .unavailable }
        let dek: StoreDEK
        do {
            dek = try provider.fetchDEK(tag: tag)                              // MUST exist; no create-on-reopen
        } catch let e {
            return mapProviderError(e)                                         // dekNotFound -> .unavailable (fail-closed)
        }
        let protection = provider.applyFileProtection(paths: [path], protection: .complete)
        guard protection.isSuccess else { return .unavailable }
        return finalize { try self.engine.reopenRequiringDEK(path: path, dek: dek) }
    }

    /// Classify a provider (Keychain / DEK / protection) error to a typed result -- fail-closed.
    private func mapProviderError(_ e: Error) -> EncryptedStoreOpenResult {
        if let k = e as? StoreKeyError {
            switch k {
            case .dekNotFound, .keychainUnavailable, .deviceLocked, .dekWrongLength, .protectionFailure: return .unavailable
            case .decodingFailure: return .corrupt
            }
        }
        return .unavailable                                                    // an unknown Keychain fault fails CLOSED
    }

    /// Run an engine open, classify a thrown fault, and enforce the encrypted-at-rest pin.
    private func finalize(_ open: () throws -> EncryptedStoreHandle) -> EncryptedStoreOpenResult {
        let handle: EncryptedStoreHandle
        do { handle = try open() }
        catch let f { return classifyEngineFault(f) }
        guard handle.kind == .pinnedSQLCipher, handle.encryptedAtRest else { return .locked }  // reject a non-encrypted handle
        return .available(handle)
    }

    private func classifyEngineFault(_ f: Error) -> EncryptedStoreOpenResult {
        if let sf = f as? StoreOpenFault {
            switch sf {
            case .wrongKey: return .locked
            case .corruptHeader: return .corrupt
            case .cipherVersionMismatch(let found, let supported): return .unsupportedVersion(found: found, supported: supported)
            case .io: return .corrupt                                            // an io fault fails CLOSED, not empty-healthy
            }
        }
        return .corrupt                                                          // any unclassified open fault fails CLOSED
    }
}
