import Foundation
import Security

/// Canonical version identifier for LocalIdentityStateV1 (0x01).
internal let localIdentityStateVersion: UInt8 = 0x01

/// Authoritative byte length of LocalIdentityStateV1 (69 bytes).
internal let localIdentityStateLength: Int = 69

/// Byte length of an Ed25519 private seed (32 bytes).
internal let localIdentityEd25519PrivLength: Int = 32

/// Byte length of an X25519 static private key (32 bytes).
internal let localIdentityX25519PrivLength: Int = 32

/// Immutable representation of canonical local identity storage state (ADR-003, Phase C8.1B).
///
/// 69-byte binary layout:
/// - offset 0: version (0x01)
/// - offset 1..4: binding_generation uint32 big-endian
/// - offset 5..36: Ed25519 private seed (32 bytes)
/// - offset 37..68: X25519 static private key (32 bytes)
internal struct LocalIdentityStateV1: Sendable, Equatable {
    internal let version: UInt8
    internal let generation: UInt32
    internal let ed25519Seed: Data
    internal let x25519PrivateKey: Data

    internal init(
        version: UInt8 = localIdentityStateVersion,
        generation: UInt32,
        ed25519Seed: Data,
        x25519PrivateKey: Data
    ) throws {
        guard version == localIdentityStateVersion else {
            throw MeshError.unsupportedIdentityStateVersion(version)
        }
        guard ed25519Seed.count == localIdentityEd25519PrivLength else {
            throw MeshError.identityStateCorrupt("Invalid Ed25519 seed length: \(ed25519Seed.count)")
        }
        guard x25519PrivateKey.count == localIdentityX25519PrivLength else {
            throw MeshError.identityStateCorrupt("Invalid X25519 private key length: \(x25519PrivateKey.count)")
        }
        self.version = version
        self.generation = generation
        self.ed25519Seed = ed25519Seed
        self.x25519PrivateKey = x25519PrivateKey
    }

    internal func encode() -> Data {
        var data = Data(capacity: localIdentityStateLength)
        data.append(version)
        var genBe = generation.bigEndian
        withUnsafeBytes(of: &genBe) { data.append(contentsOf: $0) }
        data.append(ed25519Seed)
        data.append(x25519PrivateKey)
        return data
    }

    internal static func parse(_ data: Data) throws -> LocalIdentityStateV1 {
        guard data.count == localIdentityStateLength else {
            throw MeshError.identityStateCorrupt(
                "Invalid local identity state length: expected \(localIdentityStateLength), got \(data.count)"
            )
        }
        let version = data[data.startIndex]
        guard version == localIdentityStateVersion else {
            throw MeshError.unsupportedIdentityStateVersion(version)
        }
        let generation =
            (UInt32(data[data.startIndex + 1]) << 24) |
            (UInt32(data[data.startIndex + 2]) << 16) |
            (UInt32(data[data.startIndex + 3]) << 8) |
            UInt32(data[data.startIndex + 4])
        let edSeed = data.subdata(in: (data.startIndex + 5)..<(data.startIndex + 37))
        let xPriv = data.subdata(in: (data.startIndex + 37)..<(data.startIndex + 69))
        return try LocalIdentityStateV1(
            version: version,
            generation: generation,
            ed25519Seed: edSeed,
            x25519PrivateKey: xPriv
        )
    }
}

/// Internal Keychain abstraction for local identity state to enable deterministic testing without Keychain mutation.
internal protocol LocalIdentityKeychain: Sendable {
    func read(tag: String) throws -> Data?
    func add(tag: String, data: Data) throws
    func delete(tag: String) throws
}

/// Production Keychain adapter checking OSStatus codes.
internal final class DefaultLocalIdentityKeychain: LocalIdentityKeychain, @unchecked Sendable {
    internal init() {}

    internal func read(tag: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecSuccess {
            return out as? Data
        } else if status == errSecItemNotFound {
            return nil
        } else {
            throw MeshError.keychainFailure(status)
        }
    }

    internal func add(tag: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MeshError.keychainFailure(status)
        }
    }

    internal func delete(tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MeshError.keychainFailure(status)
        }
    }
}
