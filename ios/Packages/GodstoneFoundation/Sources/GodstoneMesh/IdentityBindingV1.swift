import Foundation
import CryptoKit
import GodstoneCore

/// Canonical version identifier for IdentityBindingV1 (ADR-003, Phase C8.1A).
public let identityBindingVersion: UInt8 = 0x01

/// Fixed serialized byte length of an IdentityBindingV1 payload (133 bytes).
public let identityBindingSerializedLength: Int = 133

/// Fixed byte length of the signature preimage (80 bytes).
public let identityBindingPreimageLength: Int = 80

/// Authoritative byte length of an Ed25519 signing public key (32 bytes).
public let identityBindingSigningKeyLength: Int = 32

/// Authoritative byte length of an X25519 static DH public key (32 bytes).
public let identityBindingStaticDhKeyLength: Int = 32

/// Authoritative byte length of an Ed25519 signature (64 bytes).
public let identityBindingSignatureLength: Int = 64

/// Authoritative byte length of a node_id (16 bytes).
public let identityBindingNodeIdLength: Int = 16

/// Authoritative byte length of a discovery node hint (4 bytes).
public let identityBindingNodeHintLength: Int = 4

/// Domain separator for IdentityBindingV1 signature preimages.
public let identityBindingDomain = "GMP2-IDBIND"

/// Immutable canonical representation of an IdentityBindingV1 object (ADR-003, Phase C8.1A).
public struct IdentityBindingV1: Sendable, Equatable {
    public let version: UInt8
    public let generation: UInt32
    public let signingPublicKey: Data
    public let staticDhPublicKey: Data
    public let signature: Data

    public init(
        version: UInt8 = identityBindingVersion,
        generation: UInt32,
        signingPublicKey: Data,
        staticDhPublicKey: Data,
        signature: Data
    ) {
        precondition(version == identityBindingVersion, "Unsupported version")
        precondition(signingPublicKey.count == identityBindingSigningKeyLength, "Invalid signing public key size")
        precondition(staticDhPublicKey.count == identityBindingStaticDhKeyLength, "Invalid static DH public key size")
        precondition(signature.count == identityBindingSignatureLength, "Invalid signature size")
        self.version = version
        self.generation = generation
        self.signingPublicKey = signingPublicKey
        self.staticDhPublicKey = staticDhPublicKey
        self.signature = signature
    }

    public static func parse(_ serialized: Data) throws -> IdentityBindingV1 {
        guard serialized.count == identityBindingSerializedLength else {
            throw IdentityBindingError.malformedLength
        }
        let version = serialized[0]
        guard version == identityBindingVersion else {
            throw IdentityBindingError.unsupportedVersion
        }
        var genBe: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &genBe) { ptr in
            serialized.copyBytes(to: ptr, from: 1..<5)
        }
        let generation = UInt32(bigEndian: genBe)
        let signingPub = serialized.subdata(in: 5..<37)
        let staticPub = serialized.subdata(in: 37..<69)
        let sig = serialized.subdata(in: 69..<133)
        return IdentityBindingV1(
            version: version,
            generation: generation,
            signingPublicKey: signingPub,
            staticDhPublicKey: staticPub,
            signature: sig
        )
    }

    public func encode() -> Data {
        var data = Data(capacity: identityBindingSerializedLength)
        data.append(version)
        var genBe = generation.bigEndian
        withUnsafeBytes(of: &genBe) { data.append(contentsOf: $0) }
        data.append(signingPublicKey)
        data.append(staticDhPublicKey)
        data.append(signature)
        return data
    }

    public static func signaturePreimage(
        generation: UInt32,
        signingPublicKey: Data,
        staticDhPublicKey: Data,
        version: UInt8 = identityBindingVersion
    ) -> Data {
        precondition(version == identityBindingVersion, "Unsupported version")
        precondition(signingPublicKey.count == identityBindingSigningKeyLength, "Invalid signing public key size")
        precondition(staticDhPublicKey.count == identityBindingStaticDhKeyLength, "Invalid static DH public key size")
        var data = Data(capacity: identityBindingPreimageLength)
        data.append(Data(identityBindingDomain.utf8))
        data.append(version)
        var genBe = generation.bigEndian
        withUnsafeBytes(of: &genBe) { data.append(contentsOf: $0) }
        data.append(signingPublicKey)
        data.append(staticDhPublicKey)
        return data
    }

    public static func deriveNodeId(signingPublicKey: Data) -> Data {
        precondition(signingPublicKey.count == identityBindingSigningKeyLength, "Invalid signing public key size")
        return Blake2s.hash(signingPublicKey, digestLength: identityBindingNodeIdLength)
    }

    public static func deriveNodeHint(nodeId: Data) -> Data {
        precondition(nodeId.count == identityBindingNodeIdLength, "Invalid node_id size")
        return nodeId.prefix(identityBindingNodeHintLength)
    }
}

public enum IdentityBindingError: Error, Equatable {
    case malformedLength
    case unsupportedVersion
}

/// Immutable representation of a cryptographically validated peer identity binding (ADR-003, Phase C8.1A).
///
/// ValidatedPeerBinding is an unforgeable authority type: its initializer is fileprivate to this
/// source file and instances can ONLY be instantiated through canonical execution of the 10-step
/// cryptographic validation pipeline in `IdentityBindingValidator.validate(...)`.
public struct ValidatedPeerBinding: Sendable, Equatable {
    public let nodeId: Data
    public let signingPublicKey: Data
    public let staticDhPublicKey: Data
    public let generation: UInt32

    fileprivate init(
        nodeId: Data,
        signingPublicKey: Data,
        staticDhPublicKey: Data,
        generation: UInt32
    ) {
        precondition(nodeId.count == identityBindingNodeIdLength, "Invalid node_id size")
        precondition(signingPublicKey.count == identityBindingSigningKeyLength, "Invalid signing public key size")
        precondition(staticDhPublicKey.count == identityBindingStaticDhKeyLength, "Invalid static DH public key size")
        self.nodeId = nodeId
        self.signingPublicKey = signingPublicKey
        self.staticDhPublicKey = staticDhPublicKey
        self.generation = generation
    }
}

/// Result taxonomy for pure identity binding validation (ADR-003, Phase C8.1A).
public enum IdentityBindingValidationResult: Sendable, Equatable {
    case valid(ValidatedPeerBinding)
    case malformedLength
    case unsupportedVersion
    case invalidSignature
    case noiseStaticMismatch
    case advertisementHintMismatch
    case invalidContext
}

/// Pure validator executing the 10-step cryptographic validation pipeline (ADR-003, Phase C8.1A).
public enum IdentityBindingValidator {
    public static func validate(
        serialized: Data,
        authenticatedRemoteStaticKey: Data,
        advertisedNodeHint: Data
    ) -> IdentityBindingValidationResult {
        // Invariant check on context arguments
        guard authenticatedRemoteStaticKey.count == identityBindingStaticDhKeyLength,
              advertisedNodeHint.count == identityBindingNodeHintLength else {
            return .invalidContext
        }

        // 1. Length check
        guard serialized.count == identityBindingSerializedLength else {
            return .malformedLength
        }

        // 2. Version check
        let version = serialized[0]
        guard version == identityBindingVersion else {
            return .unsupportedVersion
        }

        // 3. Parse generation (uint32_be)
        var genBe: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &genBe) { ptr in
            serialized.copyBytes(to: ptr, from: 1..<5)
        }
        let generation = UInt32(bigEndian: genBe)

        // 4. Parse signing key (32 bytes)
        let signingPublicKey = serialized.subdata(in: 5..<37)

        // 5. Parse static DH key (32 bytes)
        let staticDhPublicKey = serialized.subdata(in: 37..<69)

        // 6. Parse signature (64 bytes)
        let signature = serialized.subdata(in: 69..<133)

        // 7. Verify Ed25519 signature over canonical GMP2-IDBIND preimage
        let preimage = IdentityBindingV1.signaturePreimage(
            generation: generation,
            signingPublicKey: signingPublicKey,
            staticDhPublicKey: staticDhPublicKey,
            version: version
        )
        guard let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: signingPublicKey),
              pubKey.isValidSignature(signature, for: preimage) else {
            return .invalidSignature
        }

        // 8. Derive node_id = BLAKE2s-128(signingPublicKey)
        let nodeId = IdentityBindingV1.deriveNodeId(signingPublicKey: signingPublicKey)

        // 9. Check static DH match
        guard staticDhPublicKey == authenticatedRemoteStaticKey else {
            return .noiseStaticMismatch
        }

        // 10. Check hint match
        let expectedHint = IdentityBindingV1.deriveNodeHint(nodeId: nodeId)
        guard expectedHint == advertisedNodeHint else {
            return .advertisementHintMismatch
        }

        let validated = ValidatedPeerBinding(
            nodeId: nodeId,
            signingPublicKey: signingPublicKey,
            staticDhPublicKey: staticDhPublicKey,
            generation: generation
        )
        return .valid(validated)
    }
}
