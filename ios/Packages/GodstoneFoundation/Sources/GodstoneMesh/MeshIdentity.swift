import Foundation
import CryptoKit
import Security
import GodstoneCore

/// Long-lived node identity.
///
/// Two key pairs, never conflated:
///   * Ed25519 for signatures (authorship, non-repudiation within the mesh)
///   * X25519  for Noise key agreement (confidentiality)
///
/// Both are stored in the Keychain with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
/// AfterFirstUnlock rather than WhenUnlocked, because the mesh must keep relaying
/// while the phone is locked in a pocket. ThisDeviceOnly so keys never enter an
/// iCloud backup.
public struct MeshIdentity: Sendable {

    public let signingKey: Curve25519.Signing.PrivateKey
    public let agreementKey: Curve25519.KeyAgreement.PrivateKey

    /// BLAKE2s-128 of the agreement public key. 16 bytes. Matches Android.
    public var nodeId: Data {
        // PROTOCOL.md:49 -- node_id = BLAKE2s-128(identity_pub), the Ed25519
        // signing key. This previously used agreementKey (X25519), producing a
        // different node_id, hence a different node_hint, hence a different
        // Noise prologue -- so h diverged BEFORE the first DH and no transcript
        // test could have seen it. Pinned by handshake_vectors.json.
        Blake2s.hash(signingKey.publicKey.rawRepresentation, digestLength: 16)
    }

    /// First 4 bytes, carried in the accepted 13-byte BLE scan response.
    public var nodeHint: Data { nodeId.prefix(4) }

    /// Six BIP-39 words derived from the node id, for verbal out-of-band
    /// verification. "Is your call sign amber-tiger-...?" over actual voice is
    /// the only trustworthy channel when everything else is compromised.
    public var callSign: String {
        Bip39.words(from: nodeId, count: 6).joined(separator: "-")
    }

    // MARK: - Keychain

    private static let signingTag   = "io.godstone.mesh.identity.ed25519"
    private static let agreementTag = "io.godstone.mesh.identity.x25519"

    public static func generateAndStore() -> MeshIdentity {
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()

        store(signing.rawRepresentation, tag: signingTag)
        store(agreement.rawRepresentation, tag: agreementTag)

        return MeshIdentity(signingKey: signing, agreementKey: agreement)
    }

    public static func loadFromKeychain() throws -> MeshIdentity {
        guard let s = load(tag: signingTag), let a = load(tag: agreementTag) else {
            throw MeshError.identityNotFound
        }
        return MeshIdentity(
            signingKey: try Curve25519.Signing.PrivateKey(rawRepresentation: s),
            agreementKey: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: a)
        )
    }

    private static func store(_ data: Data, tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func load(tag: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else {
            return nil
        }
        return out as? Data
    }

    /// Delete both identity key items from the Keychain.
    ///
    /// This is the cryptographic-erasure primitive for the iOS panic-wipe path
    /// (ADR-004 criterion 5, GST-WIPE-001). The private keys ARE the secret here
    /// -- unlike Android, where a KEK wraps ciphertext files, on iOS the keys
    /// live directly in the Keychain -- so deleting them is both key destruction
    /// and artifact deletion in one step. Idempotent: `errSecItemNotFound` is
    /// treated as success. Used by `KeychainWipeArtifacts.eraseKeys()`.
    @discardableResult
    public static func deleteFromKeychain() -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: signingTag
        ]
        let r1 = SecItemDelete(query as CFDictionary)
        query[kSecAttrAccount as String] = agreementTag
        let r2 = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound (-25300) means already gone -- fine for a wipe.
        return [r1, r2].first { $0 != errSecSuccess && $0 != errSecItemNotFound } ?? errSecSuccess
    }
}

public enum MeshError: Error {
    case identityNotFound
    case malformedFrame
    case handshakeFailed
    case payloadTooLarge
    case replayDetected
}
