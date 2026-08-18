import XCTest
import CryptoKit
@testable import GodstoneMesh

final class PeerTrustEngineTests: XCTestCase {

    private let seedA = Data(repeating: 0x11, count: 32)
    private let seedB = Data(repeating: 0x33, count: 32)

    private let staticPrivA = Data(repeating: 0x22, count: 32)
    private let staticPrivB = Data(repeating: 0x44, count: 32)
    private let staticPrivC = Data(repeating: 0x66, count: 32)

    private func makeValidatedBinding(
        seed: Data,
        generation: UInt32,
        staticDhPriv: Data
    ) throws -> ValidatedPeerBinding {
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let agreementKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticDhPriv)
        let preimage = IdentityBindingV1.signaturePreimage(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation
        )
        let sig = try signingKey.signature(for: preimage)
        let binding = try IdentityBindingV1(
            generation: generation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            staticDhPublicKey: agreementKey.publicKey.rawRepresentation,
            signature: sig
        )
        let result = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: agreementKey.publicKey.rawRepresentation,
            advertisedNodeHint: IdentityBindingV1.deriveNodeHint(
                nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signingKey.publicKey.rawRepresentation)
            )
        )
        guard case .valid(let validated) = result else {
            XCTFail("Failed to create test ValidatedPeerBinding")
            fatalError()
        }
        return validated
    }

    private func makeRecord(
        seed: Data,
        acceptedGeneration: UInt32 = 0,
        trustLevel: PeerTrustLevel = .tofuPinned,
        acceptedStaticPriv: Data,
        pendingGeneration: UInt32? = nil,
        pendingStaticPriv: Data? = nil
    ) throws -> PeerIdentityRecord {
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let accDh = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: acceptedStaticPriv)
        let pendDh = try pendingStaticPriv.map { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
        return PeerIdentityRecord(
            nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signingKey.publicKey.rawRepresentation),
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            acceptedStaticDhPublicKey: accDh.publicKey.rawRepresentation,
            acceptedGeneration: acceptedGeneration,
            trustLevel: trustLevel,
            pendingStaticDhPublicKey: pendDh?.publicKey.rawRepresentation,
            pendingGeneration: pendingGeneration
        )
    }

    // =========================================================================
    // 1. CROSS-PLATFORM SEMANTIC TEST MATRIX (T01 - T25)
    // =========================================================================

    // T01: unseen generation 0 -> InsertFirstSeen
    func testT01UnseenGeneration0() throws {
        let binding = try makeValidatedBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: nil)
        XCTAssertEqual(plan, .insertFirstSeen)
    }

    // T02: unseen generation 7 -> InsertFirstSeen
    func testT02UnseenGeneration7() throws {
        let binding = try makeValidatedBinding(seed: seedA, generation: 7, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: nil)
        XCTAssertEqual(plan, .insertFirstSeen)
    }

    // T03: unseen UINT32_MAX -> InsertFirstSeen
    func testT03UnseenUint32Max() throws {
        let binding = try makeValidatedBinding(seed: seedA, generation: UInt32.max, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: nil)
        XCTAssertEqual(plan, .insertFirstSeen)
    }

    // T04: exact accepted TOFU reconnect -> AcceptExisting
    func testT04ExactAcceptedTofuReconnect() throws {
        let record = try makeRecord(seed: seedA, acceptedGeneration: 0, trustLevel: .tofuPinned, acceptedStaticPriv: staticPrivA)
        let binding = try makeValidatedBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .acceptExisting)
    }

    // T05: exact accepted USER_VERIFIED reconnect -> AcceptExisting
    func testT05ExactAcceptedUserVerifiedReconnect() throws {
        let record = try makeRecord(seed: seedA, acceptedGeneration: 5, trustLevel: .userVerified, acceptedStaticPriv: staticPrivA)
        let binding = try makeValidatedBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .acceptExisting)
    }

    // T06: accepted lower generation -> Reject Rollback
    func testT06AcceptedLowerGeneration() throws {
        let record = try makeRecord(seed: seedA, acceptedGeneration: 5, acceptedStaticPriv: staticPrivA)
        let binding = try makeValidatedBinding(seed: seedA, generation: 4, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.rollback))
    }

    // T07: same accepted generation / different static -> Reject SameGenerationConflict
    func testT07SameAcceptedGenerationDifferentStatic() throws {
        let record = try makeRecord(seed: seedA, acceptedGeneration: 5, acceptedStaticPriv: staticPrivA)
        let binding = try makeValidatedBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivB)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.sameGenerationConflict))
    }

    // T08: higher generation / accepted static -> Reject NoncanonicalGenerationAdvance
    func testT08HigherGenerationAcceptedStatic() throws {
        let record = try makeRecord(seed: seedA, acceptedGeneration: 5, acceptedStaticPriv: staticPrivA)
        let binding = try makeValidatedBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.noncanonicalGenerationAdvance))
    }

    // T09: higher generation / distinct static -> SetInitialPendingCandidate
    func testT09HigherGenerationDistinctStatic() throws {
        let record = try makeRecord(seed: seedA, acceptedGeneration: 5, acceptedStaticPriv: staticPrivA)
        let binding = try makeValidatedBinding(seed: seedA, generation: 6, staticDhPriv: staticPrivB)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .setInitialPendingCandidate)
    }

    // T10: pending exact candidate -> KeepQuarantined
    func testT10PendingExactCandidate() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 10, staticDhPriv: staticPrivB)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .keepQuarantined)
    }

    // T11: pending + old accepted exact reconnect -> KeepQuarantined
    func testT11PendingOldAcceptedExactReconnect() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .keepQuarantined)
    }

    // T12: pending + gen lower than accepted -> Reject Rollback
    func testT12PendingGenLowerThanAccepted() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 4, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.rollback))
    }

    // T13: pending + accepted generation / different static -> Reject SameGenerationConflict
    func testT13PendingAcceptedGenerationDifferentStatic() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivC)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.sameGenerationConflict))
    }

    // T14: pending + intermediate generation / novel static -> Reject StaleRelativeToPending
    func testT14PendingIntermediateGenerationNovelStatic() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 7, staticDhPriv: staticPrivC)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.staleRelativeToPending))
    }

    // T15: pending + intermediate generation / accepted static -> Reject StaleRelativeToPending
    func testT15PendingIntermediateGenerationAcceptedStatic() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 7, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.staleRelativeToPending))
    }

    // T16: pending + intermediate generation / pending static -> Reject StaleRelativeToPending
    func testT16PendingIntermediateGenerationPendingStatic() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 7, staticDhPriv: staticPrivB)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.staleRelativeToPending))
    }

    // T17: pending generation / exact pending static -> KeepQuarantined
    func testT17PendingGenerationExactPendingStatic() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 10, staticDhPriv: staticPrivB)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .keepQuarantined)
    }

    // T18: pending generation / different static -> Reject PendingGenerationConflict
    func testT18PendingGenerationDifferentStatic() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 10, staticDhPriv: staticPrivC)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.pendingGenerationConflict))
    }

    // T19: pending generation / accepted static -> Reject PendingGenerationConflict
    func testT19PendingGenerationAcceptedStatic() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 10, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.pendingGenerationConflict))
    }

    // T20: newer-than-pending / novel static -> AdvancePendingCandidate
    func testT20NewerThanPendingNovelStatic() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 11, staticDhPriv: staticPrivC)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .advancePendingCandidate)
    }

    // T21: newer-than-pending / accepted static -> Reject NoncanonicalGenerationAdvance
    func testT21NewerThanPendingAcceptedStatic() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 11, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.noncanonicalGenerationAdvance))
    }

    // T22: newer-than-pending / pending static -> Reject NoncanonicalGenerationAdvance
    func testT22NewerThanPendingPendingStatic() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 11, staticDhPriv: staticPrivB)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.noncanonicalGenerationAdvance))
    }

    // T23: revoked exact reconnect -> Reject Revoked
    func testT23RevokedExactReconnect() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            trustLevel: .revoked,
            acceptedStaticPriv: staticPrivA
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 5, staticDhPriv: staticPrivA)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.revoked))
    }

    // T24: revoked higher generation -> Reject Revoked
    func testT24RevokedHigherGeneration() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            trustLevel: .revoked,
            acceptedStaticPriv: staticPrivA
        )
        let binding = try makeValidatedBinding(seed: seedA, generation: 20, staticDhPriv: staticPrivC)
        let plan = PeerTrustEngine.evaluate(binding: binding, current: record)
        XCTAssertEqual(plan, .reject(.revoked))
    }

    // T25: active node-id/signing-key collision -> Reject NodeIdSigningKeyCollision
    func testT25ActiveNodeIdSigningKeyCollision() throws {
        // Synthetic branch test: node ID matched during DB lookup, but signing key differs
        let binding = try makeValidatedBinding(seed: seedA, generation: 0, staticDhPriv: staticPrivA)
        let otherSigningKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seedB)
        let collisionRecord = PeerIdentityRecord(
            nodeId: binding.nodeId, // lookup identity matched
            signingPublicKey: otherSigningKey.publicKey.rawRepresentation, // different stored key!
            acceptedStaticDhPublicKey: binding.staticDhPublicKey,
            acceptedGeneration: 0,
            trustLevel: .tofuPinned
        )
        let plan = PeerTrustEngine.evaluate(binding: binding, current: collisionRecord)
        XCTAssertEqual(plan, .reject(.nodeIdSigningKeyCollision))
    }

    // =========================================================================
    // 2. RECORD VALIDATION TESTS (V01 - V15)
    // =========================================================================

    // V01: valid TOFU active record
    func testV01ValidTofuActiveRecord() throws {
        let record = try makeRecord(seed: seedA, acceptedGeneration: 0, trustLevel: .tofuPinned, acceptedStaticPriv: staticPrivA)
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .valid)
    }

    // V02: valid USER_VERIFIED active record
    func testV02ValidUserVerifiedActiveRecord() throws {
        let record = try makeRecord(seed: seedA, acceptedGeneration: 5, trustLevel: .userVerified, acceptedStaticPriv: staticPrivA)
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .valid)
    }

    // V03: valid pending record
    func testV03ValidPendingRecord() throws {
        let record = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .valid)
    }

    // V04: valid revoked record
    func testV04ValidRevokedRecord() throws {
        let record = try makeRecord(seed: seedA, acceptedGeneration: 5, trustLevel: .revoked, acceptedStaticPriv: staticPrivA)
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .valid)
    }

    // V05: nodeId length != 16 -> Corrupt
    func testV05NodeIdLengthInvalid() throws {
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let dh = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let record = PeerIdentityRecord(
            nodeId: Data(repeating: 0x01, count: 15),
            signingPublicKey: signing.publicKey.rawRepresentation,
            acceptedStaticDhPublicKey: dh.publicKey.rawRepresentation,
            acceptedGeneration: 0,
            trustLevel: .tofuPinned
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .corrupt(.invalidNodeIdLength))
    }

    // V06: signing key length != 32 -> Corrupt
    func testV06SigningKeyLengthInvalid() throws {
        let dh = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let record = PeerIdentityRecord(
            nodeId: Data(repeating: 0x01, count: 16),
            signingPublicKey: Data(repeating: 0x01, count: 31),
            acceptedStaticDhPublicKey: dh.publicKey.rawRepresentation,
            acceptedGeneration: 0,
            trustLevel: .tofuPinned
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .corrupt(.invalidSigningKeyLength))
    }

    // V07: accepted static length != 32 -> Corrupt
    func testV07AcceptedStaticLengthInvalid() throws {
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let record = PeerIdentityRecord(
            nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signing.publicKey.rawRepresentation),
            signingPublicKey: signing.publicKey.rawRepresentation,
            acceptedStaticDhPublicKey: Data(repeating: 0x01, count: 33),
            acceptedGeneration: 0,
            trustLevel: .tofuPinned
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .corrupt(.invalidAcceptedStaticKeyLength))
    }

    // V08: nodeId != hash(signing key) -> Corrupt
    func testV08NodeIdSigningKeyMismatch() throws {
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let dh = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let record = PeerIdentityRecord(
            nodeId: Data(repeating: 0xFF, count: 16), // mismatched
            signingPublicKey: signing.publicKey.rawRepresentation,
            acceptedStaticDhPublicKey: dh.publicKey.rawRepresentation,
            acceptedGeneration: 0,
            trustLevel: .tofuPinned
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .corrupt(.nodeIdSigningKeyMismatch))
    }

    // V09: pending generation only -> Corrupt
    func testV09PendingGenerationOnly() throws {
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let dh = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let record = PeerIdentityRecord(
            nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signing.publicKey.rawRepresentation),
            signingPublicKey: signing.publicKey.rawRepresentation,
            acceptedStaticDhPublicKey: dh.publicKey.rawRepresentation,
            acceptedGeneration: 0,
            trustLevel: .tofuPinned,
            pendingStaticDhPublicKey: nil,
            pendingGeneration: 5
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .corrupt(.pendingCouplingViolation))
    }

    // V10: pending static only -> Corrupt
    func testV10PendingStaticOnly() throws {
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let dhA = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let dhB = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivB)
        let record = PeerIdentityRecord(
            nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signing.publicKey.rawRepresentation),
            signingPublicKey: signing.publicKey.rawRepresentation,
            acceptedStaticDhPublicKey: dhA.publicKey.rawRepresentation,
            acceptedGeneration: 0,
            trustLevel: .tofuPinned,
            pendingStaticDhPublicKey: dhB.publicKey.rawRepresentation,
            pendingGeneration: nil
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .corrupt(.pendingCouplingViolation))
    }

    // V11: pending static wrong length -> Corrupt
    func testV11PendingStaticWrongLength() throws {
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let dhA = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let record = PeerIdentityRecord(
            nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signing.publicKey.rawRepresentation),
            signingPublicKey: signing.publicKey.rawRepresentation,
            acceptedStaticDhPublicKey: dhA.publicKey.rawRepresentation,
            acceptedGeneration: 0,
            trustLevel: .tofuPinned,
            pendingStaticDhPublicKey: Data(repeating: 0x01, count: 16),
            pendingGeneration: 5
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .corrupt(.invalidPendingStaticKeyLength))
    }

    // V12: pendingGeneration == acceptedGeneration -> Corrupt
    func testV12PendingGenerationEqualsAccepted() throws {
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let dhA = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let dhB = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivB)
        let record = PeerIdentityRecord(
            nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signing.publicKey.rawRepresentation),
            signingPublicKey: signing.publicKey.rawRepresentation,
            acceptedStaticDhPublicKey: dhA.publicKey.rawRepresentation,
            acceptedGeneration: 5,
            trustLevel: .tofuPinned,
            pendingStaticDhPublicKey: dhB.publicKey.rawRepresentation,
            pendingGeneration: 5
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .corrupt(.pendingNotNewer))
    }

    // V13: pendingGeneration < acceptedGeneration -> Corrupt
    func testV13PendingGenerationLessThanAccepted() throws {
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let dhA = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let dhB = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivB)
        let record = PeerIdentityRecord(
            nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signing.publicKey.rawRepresentation),
            signingPublicKey: signing.publicKey.rawRepresentation,
            acceptedStaticDhPublicKey: dhA.publicKey.rawRepresentation,
            acceptedGeneration: 5,
            trustLevel: .tofuPinned,
            pendingStaticDhPublicKey: dhB.publicKey.rawRepresentation,
            pendingGeneration: 4
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .corrupt(.pendingNotNewer))
    }

    // V14: pending static == accepted static -> Corrupt
    func testV14PendingStaticEqualsAccepted() throws {
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let dhA = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let record = PeerIdentityRecord(
            nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signing.publicKey.rawRepresentation),
            signingPublicKey: signing.publicKey.rawRepresentation,
            acceptedStaticDhPublicKey: dhA.publicKey.rawRepresentation,
            acceptedGeneration: 5,
            trustLevel: .tofuPinned,
            pendingStaticDhPublicKey: dhA.publicKey.rawRepresentation, // identical!
            pendingGeneration: 10
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .corrupt(.pendingStaticEqualsAccepted))
    }

    // V15: REVOKED + pending -> Corrupt
    func testV15RevokedWithPending() throws {
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: seedA)
        let dhA = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivA)
        let dhB = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: staticPrivB)
        let record = PeerIdentityRecord(
            nodeId: IdentityBindingV1.deriveNodeId(signingPublicKey: signing.publicKey.rawRepresentation),
            signingPublicKey: signing.publicKey.rawRepresentation,
            acceptedStaticDhPublicKey: dhA.publicKey.rawRepresentation,
            acceptedGeneration: 5,
            trustLevel: .revoked,
            pendingStaticDhPublicKey: dhB.publicKey.rawRepresentation,
            pendingGeneration: 10
        )
        XCTAssertEqual(PeerIdentityRecordValidator.validate(record: record), .corrupt(.revokedWithPending))
    }

    // =========================================================================
    // 3. EFFECTIVE STATE TESTS (Section 23)
    // =========================================================================

    func testEffectiveStatePrecedence() throws {
        // TOFU, no pending -> activeTofu
        let r1 = try makeRecord(seed: seedA, acceptedGeneration: 0, trustLevel: .tofuPinned, acceptedStaticPriv: staticPrivA)
        XCTAssertEqual(r1.effectiveState, .activeTofu)

        // USER_VERIFIED, no pending -> activeUserVerified
        let r2 = try makeRecord(seed: seedA, acceptedGeneration: 5, trustLevel: .userVerified, acceptedStaticPriv: staticPrivA)
        XCTAssertEqual(r2.effectiveState, .activeUserVerified)

        // TOFU + pending -> keyChangedQuarantined
        let r3 = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            trustLevel: .tofuPinned,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        XCTAssertEqual(r3.effectiveState, .keyChangedQuarantined)

        // USER_VERIFIED + pending -> keyChangedQuarantined
        let r4 = try makeRecord(
            seed: seedA,
            acceptedGeneration: 5,
            trustLevel: .userVerified,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 10,
            pendingStaticPriv: staticPrivB
        )
        XCTAssertEqual(r4.effectiveState, .keyChangedQuarantined)

        // REVOKED, no pending -> revoked
        let r5 = try makeRecord(seed: seedA, acceptedGeneration: 5, trustLevel: .revoked, acceptedStaticPriv: staticPrivA)
        XCTAssertEqual(r5.effectiveState, .revoked)
    }

    // =========================================================================
    // 4. READ-ONLY VIEW TYPES TESTS (Section 19)
    // =========================================================================

    func testVerifiedPeerIdentityView() throws {
        let validRecord = try makeRecord(seed: seedA, acceptedGeneration: 0, trustLevel: .tofuPinned, acceptedStaticPriv: staticPrivA)
        let verified = VerifiedPeerIdentity.fromRecord(validRecord)
        XCTAssertNotNil(verified)
        XCTAssertEqual(verified?.acceptedGeneration, 0)
        XCTAssertEqual(verified?.trustLevel, .tofuPinned)

        // Cannot view verified identity from quarantined or revoked record
        let pendingRecord = try makeRecord(
            seed: seedA,
            acceptedGeneration: 0,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 5,
            pendingStaticPriv: staticPrivB
        )
        XCTAssertNil(VerifiedPeerIdentity.fromRecord(pendingRecord))

        let revokedRecord = try makeRecord(seed: seedA, acceptedGeneration: 0, trustLevel: .revoked, acceptedStaticPriv: staticPrivA)
        XCTAssertNil(VerifiedPeerIdentity.fromRecord(revokedRecord))
    }

    func testPendingPeerIdentityView() throws {
        let pendingRecord = try makeRecord(
            seed: seedA,
            acceptedGeneration: 0,
            acceptedStaticPriv: staticPrivA,
            pendingGeneration: 5,
            pendingStaticPriv: staticPrivB
        )
        let pending = PendingPeerIdentity.fromRecord(pendingRecord)
        XCTAssertNotNil(pending)
        XCTAssertEqual(pending?.acceptedGeneration, 0)
        XCTAssertEqual(pending?.pendingGeneration, 5)

        // Cannot view pending identity from unquarantined active record
        let activeRecord = try makeRecord(seed: seedA, acceptedGeneration: 0, acceptedStaticPriv: staticPrivA)
        XCTAssertNil(PendingPeerIdentity.fromRecord(activeRecord))
    }

    func testTrustLevelPersistedCodes() {
        XCTAssertEqual(PeerTrustLevel.tofuPinned.rawValue, 1)
        XCTAssertEqual(PeerTrustLevel.userVerified.rawValue, 2)
        XCTAssertEqual(PeerTrustLevel.revoked.rawValue, 3)

        XCTAssertEqual(PeerTrustLevel.fromPersistedCode(1), .tofuPinned)
        XCTAssertEqual(PeerTrustLevel.fromPersistedCode(2), .userVerified)
        XCTAssertEqual(PeerTrustLevel.fromPersistedCode(3), .revoked)
        XCTAssertNil(PeerTrustLevel.fromPersistedCode(0))
        XCTAssertNil(PeerTrustLevel.fromPersistedCode(4))
    }
}
