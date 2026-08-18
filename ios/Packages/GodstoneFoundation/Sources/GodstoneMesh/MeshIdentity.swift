import Foundation
import CryptoKit
import Security
import GodstoneCore

/// Long-lived node identity and local binding authority (ADR-003, Phase C8.1B).
///
/// Owns durable [bindingGeneration], derived public keys, and private keys.
///
/// Two key pairs, never conflated:
///   * Ed25519 for signatures (authorship, non-repudiation within the mesh)
///   * X25519  for Noise key agreement (confidentiality)
///
/// Stored in the Keychain as a single 69-byte LocalIdentityStateV1 item with
/// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
public struct MeshIdentity: Sendable {

    public let bindingGeneration: UInt32
    private let signingKey: Curve25519.Signing.PrivateKey
    internal let agreementKey: Curve25519.KeyAgreement.PrivateKey

    public var signingPublicKey: Data { signingKey.publicKey.rawRepresentation }
    public var staticDhPublicKey: Data { agreementKey.publicKey.rawRepresentation }

    /// BLAKE2s-128 of the signing public key. 16 bytes. Matches Android.
    public var nodeId: Data {
        Blake2s.hash(signingPublicKey, digestLength: 16)
    }

    /// First 4 bytes, carried in the accepted BLE advertisement hint.
    public var nodeHint: Data { nodeId.prefix(4) }

    /// Six BIP-39 words derived from the node id, for verbal out-of-band verification.
    public var callSign: String {
        Bip39.words(from: nodeId, count: 6).joined(separator: "-")
    }

    private init(
        signingKey: Curve25519.Signing.PrivateKey,
        agreementKey: Curve25519.KeyAgreement.PrivateKey,
        bindingGeneration: UInt32
    ) {
        self.signingKey = signingKey
        self.agreementKey = agreementKey
        self.bindingGeneration = bindingGeneration
    }

    /// Sign a message using the long-term Ed25519 signing key.
    internal func sign(message: Data) throws -> Data {
        try signingKey.signature(for: message)
    }

    /// Canonical local issuer producing an IdentityBindingV1 for the local node (ADR-003, Phase C8.1B).
    ///
    /// Sourced directly from the owned identity authority without caller-supplied parameters.
    /// iOS EdDSA signatures are generated via Apple CryptoKit with self-verification.
    internal func issueIdentityBinding() throws -> IdentityBindingV1 {
        let gen = self.bindingGeneration
        let signingPub = self.signingPublicKey
        let staticPub = self.staticDhPublicKey
        let preimage = IdentityBindingV1.signaturePreimage(
            generation: gen,
            signingPublicKey: signingPub,
            staticDhPublicKey: staticPub
        )
        let signature = try signingKey.signature(for: preimage)

        guard signingKey.publicKey.isValidSignature(signature, for: preimage) else {
            throw MeshError.identityStateCorrupt("Local issuer self-verification failed")
        }

        return IdentityBindingV1(
            generation: gen,
            signingPublicKey: signingPub,
            staticDhPublicKey: staticPub,
            signature: signature
        )
    }

    // MARK: - Keychain Tags

    internal static let v1Tag = "io.godstone.mesh.identity.v1"
    internal static let legacySigningTag = "io.godstone.mesh.identity.ed25519"
    internal static let legacyAgreementTag = "io.godstone.mesh.identity.x25519"

    public static func generateAndStore() throws -> MeshIdentity {
        try generateAndStore(keychain: DefaultLocalIdentityKeychain())
    }

    internal static func generateAndStore(
        keychain: any LocalIdentityKeychain
    ) throws -> MeshIdentity {
        let v1Data = try keychain.read(tag: v1Tag)
        let legEd = try keychain.read(tag: legacySigningTag)
        let legX = try keychain.read(tag: legacyAgreementTag)

        if v1Data != nil || legEd != nil || legX != nil {
            throw MeshError.identityAlreadyExists
        }

        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        let state = try LocalIdentityStateV1(
            generation: 0,
            ed25519Seed: signing.rawRepresentation,
            x25519PrivateKey: agreement.rawRepresentation
        )

        try keychain.add(tag: v1Tag, data: state.encode())
        return MeshIdentity(signingKey: signing, agreementKey: agreement, bindingGeneration: 0)
    }

    public static func loadFromKeychain() throws -> MeshIdentity {
        try loadFromKeychain(keychain: DefaultLocalIdentityKeychain())
    }

    internal static func loadFromKeychain(
        keychain: any LocalIdentityKeychain
    ) throws -> MeshIdentity {
        let v1Data = try keychain.read(tag: v1Tag)
        let legEd = try keychain.read(tag: legacySigningTag)
        let legX = try keychain.read(tag: legacyAgreementTag)

        // CASE A -- EMPTY
        if v1Data == nil && legEd == nil && legX == nil {
            throw MeshError.identityNotFound
        }

        // CASE B -- V1 ONLY
        if let v1 = v1Data, legEd == nil && legX == nil {
            let state = try LocalIdentityStateV1.parse(v1)
            let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: state.ed25519Seed)
            let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.x25519PrivateKey)
            return MeshIdentity(signingKey: signing, agreementKey: agreement, bindingGeneration: state.generation)
        }

        // CASE C -- CANONICAL LEGACY MIGRATION
        if v1Data == nil, let ed = legEd, let x = legX {
            guard ed.count == 32, x.count == 32 else {
                throw MeshError.identityStateCorrupt("Invalid legacy key length")
            }
            let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: ed)
            let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: x)
            let state = try LocalIdentityStateV1(
                generation: 0,
                ed25519Seed: ed,
                x25519PrivateKey: x
            )
            // Write V1 state FIRST before deleting legacy entries
            try keychain.add(tag: v1Tag, data: state.encode())
            try keychain.delete(tag: legacySigningTag)
            try keychain.delete(tag: legacyAgreementTag)
            return MeshIdentity(signingKey: signing, agreementKey: agreement, bindingGeneration: 0)
        }

        // CASE D -- V1 + LEGACY REMNANTS (interrupted migration recovery)
        if let v1 = v1Data {
            let state = try LocalIdentityStateV1.parse(v1)
            guard state.generation == 0 else {
                throw MeshError.identityStateCorrupt("V1 generation is non-zero in mixed state")
            }
            if let ed = legEd, ed != state.ed25519Seed {
                throw MeshError.identityStateCorrupt("Surviving legacy Ed key does not match V1 state")
            }
            if let x = legX, x != state.x25519PrivateKey {
                throw MeshError.identityStateCorrupt("Surviving legacy X key does not match V1 state")
            }
            // All surviving remnants match V1: cleanup legacy entries
            if legEd != nil {
                try keychain.delete(tag: legacySigningTag)
            }
            if legX != nil {
                try keychain.delete(tag: legacyAgreementTag)
            }
            let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: state.ed25519Seed)
            let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.x25519PrivateKey)
            return MeshIdentity(signingKey: signing, agreementKey: agreement, bindingGeneration: state.generation)
        }

        // CASE E -- PARTIAL LEGACY WITHOUT V1
        throw MeshError.identityStateCorrupt("Partial legacy identity state without V1 state")
    }

    /// Delete identity key items from the Keychain.
    ///
    /// This is the cryptographic-erasure primitive for the iOS panic-wipe path
    /// (ADR-004 criterion 5, GST-WIPE-001).
    public static func deleteFromKeychain() throws {
        try deleteFromKeychain(keychain: DefaultLocalIdentityKeychain())
    }

    internal static func deleteFromKeychain(
        keychain: any LocalIdentityKeychain
    ) throws {
        try keychain.delete(tag: v1Tag)
        try keychain.delete(tag: legacySigningTag)
        try keychain.delete(tag: legacyAgreementTag)
    }
}

public enum MeshError: Error, Equatable {
    case identityNotFound
    case identityAlreadyExists
    case identityStateCorrupt(String)
    case unsupportedIdentityStateVersion(UInt8)
    case keychainFailure(OSStatus)
    case malformedFrame
    case handshakeFailed
    case payloadTooLarge
    case replayDetected
}
