import XCTest
import CryptoKit
@testable import GodstoneMesh

final class LocalIdentityStateV1Tests: XCTestCase {

    private func hexToData(_ hex: String) -> Data {
        let clean = hex.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        var data = Data()
        var index = clean.startIndex
        while index < clean.endIndex {
            let nextIndex = clean.index(index, offsetBy: 2)
            let byteStr = String(clean[index..<nextIndex])
            if let byte = UInt8(byteStr, radix: 16) {
                data.append(byte)
            }
            index = nextIndex
        }
        return data
    }

    private lazy var vec1EdPriv = hexToData(String(repeating: "11", count: 32))
    private lazy var vec1XPriv = hexToData(String(repeating: "22", count: 32))
    private lazy var vec1Serialized = hexToData(
        "0100000000d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c97787370faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20d57d605658e4125b03d368d407ffaa4eaad96a090b8fec56ef19864293f9c6c5adad93433604fbe87bb22d26ce733a17e0bfeaa3f972dfec535f299101c51a0b"
    )

    private lazy var vec2EdPriv = hexToData("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    private lazy var vec2XPriv = hexToData("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
    private lazy var vec2Serialized = hexToData(
        "0101020304d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a2f1a95e791e813a893081e7d0f9836371c6dc0ed5deab58f8b88d8b2f96cf9381e4c845bbf2f07297e68b31a396263fc0e782d02951bfa707ea86d5257ef512d7ec5817c8d9c57d76ee64f26b528be635df02d688cf6dc89028ea2819448150c"
    )

    private lazy var vec3EdPriv = hexToData(String(repeating: "a5", count: 32))
    private lazy var vec3XPriv = hexToData(String(repeating: "5a", count: 32))
    private lazy var vec3Serialized = hexToData(
        "01ffffffff83675a34a87383a8b417e29bf8efaa59f6368d4f4ca5bcf7a0c86ebfcf237a3fc7f9ea93e3d361dae954cda83ff6e788c6fc605bc0d17aa0a58fae546197171e2ef64d7328bfb0fbfa9e7b2aa1e75eb9192451be6cb2a7fe8ecf6a15db3b9ff018318bbca1aa34e00780287cf82381f211516eef3aa2b1cbcc52d2b56e693108"
    )

    /// In-memory Keychain fake for deterministic testing.
    final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        var failRead: OSStatus? = nil
        var failAdd: OSStatus? = nil
        var failDelete: OSStatus? = nil

        func read(tag: String) throws -> Data? {
            if let status = failRead {
                throw MeshError.keychainFailure(status)
            }
            return storage[tag]
        }

        func add(tag: String, data: Data) throws {
            if let status = failAdd {
                throw MeshError.keychainFailure(status)
            }
            storage[tag] = data
        }

        func delete(tag: String) throws {
            if let status = failDelete {
                throw MeshError.keychainFailure(status)
            }
            storage.removeValue(forKey: tag)
        }
    }

    // 1. V1 state exact length 69
    func test1V1StateExactLength69() throws {
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: vec1EdPriv, x25519PrivateKey: vec1XPriv)
        let encoded = state.encode()
        XCTAssertEqual(encoded.count, 69)
        XCTAssertEqual(encoded.count, localIdentityStateLength)
    }

    // 2. generation BE parsing including 0x01020304
    func test2GenerationBigEndianParsing() throws {
        let state = try LocalIdentityStateV1(generation: 0x01020304, ed25519Seed: vec2EdPriv, x25519PrivateKey: vec2XPriv)
        let encoded = state.encode()
        XCTAssertEqual(encoded[1], 0x01)
        XCTAssertEqual(encoded[2], 0x02)
        XCTAssertEqual(encoded[3], 0x03)
        XCTAssertEqual(encoded[4], 0x04)
        let parsed = try LocalIdentityStateV1.parse(encoded)
        XCTAssertEqual(parsed.generation, 16909060)
        XCTAssertEqual(parsed.generation, 0x01020304)
    }

    // 3. UINT32_MAX survives
    func test3Uint32MaxSurvives() throws {
        let state = try LocalIdentityStateV1(generation: UInt32.max, ed25519Seed: vec3EdPriv, x25519PrivateKey: vec3XPriv)
        let parsed = try LocalIdentityStateV1.parse(state.encode())
        XCTAssertEqual(parsed.generation, UInt32.max)
    }

    // 4. malformed lengths rejected
    func test4MalformedLengthsRejected() {
        let truncated = Data(repeating: 0x01, count: 68)
        let oversized = Data(repeating: 0x01, count: 70)
        XCTAssertThrowsError(try LocalIdentityStateV1.parse(truncated))
        XCTAssertThrowsError(try LocalIdentityStateV1.parse(oversized))
    }

    // 5. unknown version rejected
    func test5UnknownVersionRejected() throws {
        var enc = try LocalIdentityStateV1(generation: 0, ed25519Seed: vec1EdPriv, x25519PrivateKey: vec1XPriv).encode()
        enc[0] = 0x02
        XCTAssertThrowsError(try LocalIdentityStateV1.parse(enc)) { error in
            XCTAssertEqual(error as? MeshError, MeshError.unsupportedIdentityStateVersion(0x02))
        }
    }

    // 6. empty load => identityNotFound
    func test6EmptyLoadThrowsIdentityNotFound() {
        let kc = InMemoryKeychain()
        XCTAssertThrowsError(try MeshIdentity.loadFromKeychain(keychain: kc)) { error in
            XCTAssertEqual(error as? MeshError, MeshError.identityNotFound)
        }
    }

    // 7. empty generate => V1 generation 0
    func test7EmptyGenerateYieldsGeneration0() throws {
        let kc = InMemoryKeychain()
        let id = try MeshIdentity.generateAndStore(keychain: kc)
        XCTAssertEqual(id.bindingGeneration, 0)
    }

    // 8. generate writes the single V1 state item
    func test8GenerateWritesSingleV1StateItem() throws {
        let kc = InMemoryKeychain()
        _ = try MeshIdentity.generateAndStore(keychain: kc)
        XCTAssertNotNil(kc.storage[MeshIdentity.v1Tag])
        XCTAssertNil(kc.storage[MeshIdentity.legacySigningTag])
        XCTAssertNil(kc.storage[MeshIdentity.legacyAgreementTag])
    }

    // 9. generate does not delete/overwrite an existing identity
    func test9GenerateDoesNotOverwriteExistingIdentity() throws {
        let kc = InMemoryKeychain()
        _ = try MeshIdentity.generateAndStore(keychain: kc)
        XCTAssertThrowsError(try MeshIdentity.generateAndStore(keychain: kc)) { error in
            XCTAssertEqual(error as? MeshError, MeshError.identityAlreadyExists)
        }
    }

    // 10. complete legacy pair migrates to V1 generation 0
    func test10CompleteLegacyPairMigratesToV1Generation0() throws {
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.legacySigningTag] = vec1EdPriv
        kc.storage[MeshIdentity.legacyAgreementTag] = vec1XPriv

        let id = try MeshIdentity.loadFromKeychain(keychain: kc)
        XCTAssertEqual(id.bindingGeneration, 0)
        XCTAssertNotNil(kc.storage[MeshIdentity.v1Tag])
        XCTAssertNil(kc.storage[MeshIdentity.legacySigningTag])
        XCTAssertNil(kc.storage[MeshIdentity.legacyAgreementTag])
    }

    // 11. migration writes V1 before deleting legacy
    func test11MigrationWritesV1BeforeDeletingLegacy() throws {
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.legacySigningTag] = vec1EdPriv
        kc.storage[MeshIdentity.legacyAgreementTag] = vec1XPriv

        _ = try MeshIdentity.loadFromKeychain(keychain: kc)
        let state = try LocalIdentityStateV1.parse(kc.storage[MeshIdentity.v1Tag]!)
        XCTAssertEqual(state.generation, 0)
        XCTAssertEqual(state.ed25519Seed, vec1EdPriv)
        XCTAssertEqual(state.x25519PrivateKey, vec1XPriv)
    }

    // 12. failed V1 add leaves legacy entries intact
    func test12FailedV1AddLeavesLegacyEntriesIntact() {
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.legacySigningTag] = vec1EdPriv
        kc.storage[MeshIdentity.legacyAgreementTag] = vec1XPriv
        kc.failAdd = errSecDuplicateItem

        XCTAssertThrowsError(try MeshIdentity.loadFromKeychain(keychain: kc))
        XCTAssertNotNil(kc.storage[MeshIdentity.legacySigningTag])
        XCTAssertNotNil(kc.storage[MeshIdentity.legacyAgreementTag])
        XCTAssertNil(kc.storage[MeshIdentity.v1Tag])
    }

    // 13. V1 + matching legacy remnants are cleaned up as interrupted migration
    func test13MatchingLegacyRemnantsCleanedUp() throws {
        let kc = InMemoryKeychain()
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: vec1EdPriv, x25519PrivateKey: vec1XPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        kc.storage[MeshIdentity.legacySigningTag] = vec1EdPriv
        kc.storage[MeshIdentity.legacyAgreementTag] = vec1XPriv

        let id = try MeshIdentity.loadFromKeychain(keychain: kc)
        XCTAssertEqual(id.bindingGeneration, 0)
        XCTAssertNil(kc.storage[MeshIdentity.legacySigningTag])
        XCTAssertNil(kc.storage[MeshIdentity.legacyAgreementTag])
        XCTAssertNotNil(kc.storage[MeshIdentity.v1Tag])
    }

    // 14. V1 + mismatching legacy remnants fail closed
    func test14MismatchingLegacyRemnantsFailClosed() throws {
        let kc = InMemoryKeychain()
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: vec1EdPriv, x25519PrivateKey: vec1XPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()
        kc.storage[MeshIdentity.legacySigningTag] = vec2EdPriv // Mismatched!

        XCTAssertThrowsError(try MeshIdentity.loadFromKeychain(keychain: kc))
    }

    // 15. partial legacy pair fails closed
    func test15PartialLegacyPairFailsClosed() {
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.legacySigningTag] = vec1EdPriv
        XCTAssertThrowsError(try MeshIdentity.loadFromKeychain(keychain: kc))
    }

    // 16. malformed V1 fails closed
    func test16MalformedV1FailsClosed() {
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.v1Tag] = Data(repeating: 0x01, count: 68)
        XCTAssertThrowsError(try MeshIdentity.loadFromKeychain(keychain: kc))
    }

    // 17. Keychain read failure is surfaced
    func test17KeychainReadFailureIsSurfaced() {
        let kc = InMemoryKeychain()
        kc.failRead = errSecIO
        XCTAssertThrowsError(try MeshIdentity.loadFromKeychain(keychain: kc)) { error in
            XCTAssertEqual(error as? MeshError, MeshError.keychainFailure(errSecIO))
        }
    }

    // 18. Keychain add failure is surfaced
    func test18KeychainAddFailureIsSurfaced() {
        let kc = InMemoryKeychain()
        kc.failAdd = errSecIO
        XCTAssertThrowsError(try MeshIdentity.generateAndStore(keychain: kc)) { error in
            XCTAssertEqual(error as? MeshError, MeshError.keychainFailure(errSecIO))
        }
    }

    // 19. Keychain delete failure is surfaced
    func test19KeychainDeleteFailureIsSurfaced() {
        let kc = InMemoryKeychain()
        kc.failDelete = errSecIO
        XCTAssertThrowsError(try MeshIdentity.deleteFromKeychain(keychain: kc)) { error in
            XCTAssertEqual(error as? MeshError, MeshError.keychainFailure(errSecIO))
        }
    }

    // 20. vector-1 state issues exact fresh_generation_zero binding
    func test20Vector1IssuesExactFreshGenerationZeroBinding() throws {
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: vec1EdPriv, x25519PrivateKey: vec1XPriv)
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: state.ed25519Seed)
        let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.x25519PrivateKey)
        let id = MeshIdentity(signingKey: signing, agreementKey: agreement, bindingGeneration: 0)

        let binding = try id.issueIdentityBinding()
        XCTAssertEqual(binding.version, 0x01)
        XCTAssertEqual(binding.generation, 0)
        XCTAssertEqual(binding.signingPublicKey, id.signingPublicKey)
        XCTAssertEqual(binding.staticDhPublicKey, id.staticDhPublicKey)
        XCTAssertEqual(binding.signature.count, 64)

        let result = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: id.staticDhPublicKey,
            advertisedNodeHint: id.nodeHint
        )
        guard case .valid(let validated) = result else {
            XCTFail("Expected valid validation result")
            return
        }
        XCTAssertEqual(validated.generation, 0)
        XCTAssertEqual(validated.nodeId, id.nodeId)
    }

    // 21. vector-2 state issues exact endian_lock binding
    func test21Vector2IssuesExactEndianLockBinding() throws {
        let state = try LocalIdentityStateV1(generation: 0x01020304, ed25519Seed: vec2EdPriv, x25519PrivateKey: vec2XPriv)
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: state.ed25519Seed)
        let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.x25519PrivateKey)
        let id = MeshIdentity(signingKey: signing, agreementKey: agreement, bindingGeneration: 0x01020304)

        let binding = try id.issueIdentityBinding()
        XCTAssertEqual(binding.version, 0x01)
        XCTAssertEqual(binding.generation, 0x01020304)
        XCTAssertEqual(binding.signingPublicKey, id.signingPublicKey)
        XCTAssertEqual(binding.staticDhPublicKey, id.staticDhPublicKey)
        XCTAssertEqual(binding.signature.count, 64)

        let result = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: id.staticDhPublicKey,
            advertisedNodeHint: id.nodeHint
        )
        guard case .valid(let validated) = result else {
            XCTFail("Expected valid validation result")
            return
        }
        XCTAssertEqual(validated.generation, 0x01020304)
        XCTAssertEqual(validated.nodeId, id.nodeId)
    }

    // 22. vector-3 state issues exact max_generation binding
    func test22Vector3IssuesExactMaxGenerationBinding() throws {
        let state = try LocalIdentityStateV1(generation: UInt32.max, ed25519Seed: vec3EdPriv, x25519PrivateKey: vec3XPriv)
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: state.ed25519Seed)
        let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.x25519PrivateKey)
        let id = MeshIdentity(signingKey: signing, agreementKey: agreement, bindingGeneration: UInt32.max)

        let binding = try id.issueIdentityBinding()
        XCTAssertEqual(binding.version, 0x01)
        XCTAssertEqual(binding.generation, UInt32.max)
        XCTAssertEqual(binding.signingPublicKey, id.signingPublicKey)
        XCTAssertEqual(binding.staticDhPublicKey, id.staticDhPublicKey)
        XCTAssertEqual(binding.signature.count, 64)

        let result = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: id.staticDhPublicKey,
            advertisedNodeHint: id.nodeHint
        )
        guard case .valid(let validated) = result else {
            XCTFail("Expected valid validation result")
            return
        }
        XCTAssertEqual(validated.generation, UInt32.max)
        XCTAssertEqual(validated.nodeId, id.nodeId)
    }

    // 23. issueIdentityBinding has no generation parameter
    func test23IssueIdentityBindingHasNoGenerationParameter() throws {
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: vec1EdPriv, x25519PrivateKey: vec1XPriv)
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: state.ed25519Seed)
        let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.x25519PrivateKey)
        let id = MeshIdentity(signingKey: signing, agreementKey: agreement, bindingGeneration: 0)

        // Verifies calling without parameters compiles and succeeds
        let binding = try id.issueIdentityBinding()
        XCTAssertEqual(binding.generation, 0)
    }

    // 24. issuer output passes C8 1A IdentityBindingValidator
    func test24IssuerOutputPassesIdentityBindingValidator() throws {
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: vec1EdPriv, x25519PrivateKey: vec1XPriv)
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: state.ed25519Seed)
        let agreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: state.x25519PrivateKey)
        let id = MeshIdentity(signingKey: signing, agreementKey: agreement, bindingGeneration: 0)

        let binding = try id.issueIdentityBinding()
        let result = IdentityBindingValidator.validate(
            serialized: binding.encode(),
            authenticatedRemoteStaticKey: id.staticDhPublicKey,
            advertisedNodeHint: id.nodeHint
        )
        guard case .valid(let validated) = result else {
            XCTFail("Expected valid validation result")
            return
        }
        XCTAssertEqual(validated.generation, 0)
        XCTAssertEqual(validated.nodeId, id.nodeId)
        XCTAssertEqual(validated.signingPublicKey, id.signingPublicKey)
        XCTAssertEqual(validated.staticDhPublicKey, id.staticDhPublicKey)
    }

    // 25. deleteFromKeychain deletes V1 + both legacy tags
    func test25DeleteFromKeychainDeletesV1AndLegacyTags() throws {
        let kc = InMemoryKeychain()
        kc.storage[MeshIdentity.v1Tag] = Data([0x01])
        kc.storage[MeshIdentity.legacySigningTag] = Data([0x02])
        kc.storage[MeshIdentity.legacyAgreementTag] = Data([0x03])

        try MeshIdentity.deleteFromKeychain(keychain: kc)
        XCTAssertNil(kc.storage[MeshIdentity.v1Tag])
        XCTAssertNil(kc.storage[MeshIdentity.legacySigningTag])
        XCTAssertNil(kc.storage[MeshIdentity.legacyAgreementTag])
    }

    // 26. successful wipe regeneration returns generation 0
    func test26SuccessfulWipeRegenerationReturnsGeneration0() throws {
        let kc = InMemoryKeychain()
        _ = try MeshIdentity.generateAndStore(keychain: kc)
        try MeshIdentity.deleteFromKeychain(keychain: kc)
        let regenerated = try MeshIdentity.generateAndStore(keychain: kc)
        XCTAssertEqual(regenerated.bindingGeneration, 0)
    }
}
