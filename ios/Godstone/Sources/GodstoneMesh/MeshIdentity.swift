import Foundation
import CryptoKit
import Security

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
        Blake2s.hash(agreementKey.publicKey.rawRepresentation, digestLength: 16)
    }

    /// First 4 bytes, carried in the 26-byte BLE advertisement.
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
}

public enum MeshError: Error {
    case identityNotFound
    case malformedFrame
    case handshakeFailed
    case payloadTooLarge
    case replayDetected
}
