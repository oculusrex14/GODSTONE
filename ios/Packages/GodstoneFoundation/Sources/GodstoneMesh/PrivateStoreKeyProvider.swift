import Foundation
import Security

// ---------------------------------------------------------------------------
// T30 CONTRACT - iOS private stores get an ERASABLE encryption key.
//
// The card: private message and peer stores must be SQLCipher-encrypted at rest
// under a SEPARATE, random, per-install data-encryption key (the StoreDEK) that
// is itself protected by a ThisDeviceOnly Keychain item -- so deleting the DEK
// cryptographically erases the stores (system SQLite + file protection alone, with
// a swallowed setAttributes error, cannot do that). This file is the CONTRACT and
// the deterministic Keychain seam ONLY; the fail-closed EncryptedStoreFactory and
// the verify-before-select PlaintextToEncryptedMigration are separate children.
//
// Determinism follows the codebase seam precedent: the protocol is public (the
// factory/migration depend on it, as they depend on the public TransportSeam),
// the production Keychain adapter is internal (DefaultLocalIdentityKeychain
// precedent), and the ReadinessT30Tests court injects a fake conformer via
// `@testable import GodstoneMesh` (FakeSeam: TransportSeam precedent). The host
// exercises the DECISION LAWS here; physical Keychain availability, the real
// ThisDeviceOnly Data-Protection class, locked-device behaviour and the actual
// SQLCipher-at-rest bytes are DEVICE evidence (deferred to the device gate).
// ---------------------------------------------------------------------------

/// The data-protection class a private store file must carry. Pinned to `.complete`
/// so a regression to a weaker class is a test failure, not a silent weakening.
public enum FileProtectionClass: String, Sendable {
    case complete
}

/// A separate random per-install data-encryption key. Deliberately distinct from the
/// identity key: cryptographically erasing the private stores means destroying THIS
/// key, which system-SQLite file protection alone cannot achieve.
public struct StoreDEK: Equatable, @unchecked Sendable {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
    public var isEmpty: Bool { bytes.isEmpty }
    public static func == (lhs: StoreDEK, rhs: StoreDEK) -> Bool { lhs.bytes == rhs.bytes }
}

/// Typed failure of a Keychain / file-protection / DEK operation. The point of the
/// taxonomy is that NO such failure may be swallowed to a success: an unavailable
/// Keychain, a locked device, a wrong-length or missing DEK, or a failed protection
/// attribute must all surface as one of these, never as `ProtectionResult.success`.
public enum StoreKeyError: Error, Equatable {
    case dekNotFound
    case dekWrongLength(found: Int, expected: Int)
    case keychainUnavailable
    case deviceLocked
    case protectionFailure(status: Int32, operation: String)
    case decodingFailure
}

/// The outcome of applying a protection attribute / obtaining a DEK. `.success` is the
/// ONLY acceptable state for a store to be used; `.failure` carries the reason and must
/// be propagated fail-closed -- it is never collapsed into `.success`.
public enum ProtectionResult: Equatable {
    case success
    case failure(StoreKeyError)
    public var isSuccess: Bool { if case .success = self { return true }; return false }
}

/// The deterministic Keychain/DEK seam. The production adapter is
/// `DefaultPrivateStoreKeyProvider`; the court injects a fake to drive wrong-DEK,
/// Keychain-unavailable, locked-device and protection-failure decisions on the host.
public protocol PrivateStoreKeyProvider: AnyObject {
    /// The pinned DEK length in bytes (AES-256).
    var dekByteCount: Int { get }
    /// Fetch the ThisDeviceOnly-protected DEK for `tag`, throwing a `StoreKeyError`
    /// on Keychain unavailability / locked device / missing or malformed DEK.
    func fetchDEK(tag: String) throws -> StoreDEK
    /// Create and store a fresh random DEK under `tag` (ThisDeviceOnly), returning it.
    func createDEK(tag: String) throws -> StoreDEK
    /// Destroy the DEK for `tag`; after this the encrypted stores are cryptographically
    /// erased and MUST NOT be reopenable. Idempotent.
    func deleteDEK(tag: String) throws
    /// Apply `protection` at-rest to the store files at `paths`. MUST NOT swallow an
    /// attribute-set error: a failure returns `ProtectionResult.failure`, never `.success`.
    func applyFileProtection(paths: [String], protection: FileProtectionClass) -> ProtectionResult
}

/// The production Keychain adapter. DEK items are stored under the ThisDeviceOnly
/// accessible class (so they do not travel in backups and cannot be read on another
/// device); OSStatus codes are checked and surfaced, never swallowed. The file-protection
/// attribute application is the iOS-only Data-Protection concern (mirrors SqlitePeerIdentityStore),
/// and its error -- if any -- is returned as a typed failure rather than discarded.
internal final class DefaultPrivateStoreKeyProvider: PrivateStoreKeyProvider, @unchecked Sendable {
    public var dekByteCount: Int { 32 }   // AES-256 key width

    internal init() {}

    internal func fetchDEK(tag: String) throws -> StoreDEK {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess {
            guard let data = out as? Data else { throw StoreKeyError.decodingFailure }
            guard data.count == dekByteCount else { throw StoreKeyError.dekWrongLength(found: data.count, expected: dekByteCount) }
            return StoreDEK(bytes: data)
        } else if status == errSecItemNotFound {
            throw StoreKeyError.dekNotFound
        } else if status == errSecInteractionNotAllowed {
            throw StoreKeyError.deviceLocked
        } else {
            throw StoreKeyError.keychainUnavailable
        }
    }

    internal func createDEK(tag: String) throws -> StoreDEK {
        let dek = Self.randomDEK(byteCount: dekByteCount)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: dek.bytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreKeyError.keychainUnavailable }
        return dek
    }

    internal func deleteDEK(tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreKeyError.keychainUnavailable
        }
    }

    internal func applyFileProtection(paths: [String], protection: FileProtectionClass) -> ProtectionResult {
        #if os(iOS)
        let fp: FileProtectionType
        switch protection { case .complete: fp = .complete }
        for path in paths {
            do {
                try FileManager.default.setAttributes([.protectionKey: fp], ofItemAtPath: path)
            } catch {
                return .failure(.protectionFailure(status: -1, operation: "setAttributes[\(path)]"))
            }
        }
        return .success
        #else
        // Device Data-Protection is a physical iOS concern; on the host there is no
        // enforced class to apply. The DECISION laws are exercised through the injected
        // fake; the real attribute application and its proof are device evidence.
        return .success
        #endif
    }

    /// Generate a fresh random DEK via the platform CSPRNG (the codebase MessageId/SealedSender
    /// SecRandomCopyBytes idiom), never a weak PRNG. On the device this is the per-install secret
    /// whose destruction cryptographically erases the stores.
    internal static func randomDEK(byteCount: Int) -> StoreDEK {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, ptr.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed to seed the store DEK")
        return StoreDEK(bytes: data)
    }
}
