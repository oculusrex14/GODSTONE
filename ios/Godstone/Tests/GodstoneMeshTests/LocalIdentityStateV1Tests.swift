import XCTest
import CryptoKit
@testable import GodstoneMesh

/// In-memory Keychain fake for deterministic testing.
internal final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
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

/// Simple in-memory WipeJournal for deterministic testing.
internal final class InMemoryWipeJournal: WipeJournal {
    private var state: WipeState = .idle

    func read() -> WipeState { state }
    func write(_ state: WipeState) { self.state = state }
    func clear() { self.state = .idle }
}

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
        "0100000000d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c97787370faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f204c546a07b0e80598eb6a290e3e3c8f364c059edf3804bd42a6924a7b0186e68217af7316c5f93cc40e35bb2731e752e758e7206fa6061b6ab349280752ec1908"
    )

    private lazy var vec2EdPriv = hexToData("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    private lazy var vec2XPriv = hexToData("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f")
    private lazy var vec2Serialized = hexToData(
        "010102030403a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254595d507f2602b2f52fe4ed8c72a4720e6e37206c81aecaf725654fdd41a4a08c942b23022c352dee7583d11380e5d288fa5ebc6d7fb894c8e65e7052c1778d02"
    )

    private lazy var vec3EdPriv = hexToData(String(repeating: "a5", count: 32))
    private lazy var vec3XPriv = hexToData(String(repeating: "5a", count: 32))
    private lazy var vec3Serialized = hexToData(
        "01ffffffff29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55b0d08f35b4683381489afb32825e59152d47d19bc9e050d6d5a954984c9d1e2c1079c3b37526daba3ebc207f7d7802f750a21ad38442542f6ea504ef3f11453430aa06a673d483738a0ffc071ee6418ecc4c875072db6ec82bb20eedf44b9d02"
    )

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

    // 20. vector-1 state issues exact fresh_generation_zero binding (locked KAT)
    func test20Vector1IssuesExactFreshGenerationZeroBinding() throws {
        let kc = InMemoryKeychain()
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: vec1EdPriv, x25519PrivateKey: vec1XPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()

        let id = try MeshIdentity.loadFromKeychain(keychain: kc)
        let binding = try id.issueIdentityBinding()

        XCTAssertEqual(binding.version, 0x01)
        XCTAssertEqual(binding.generation, 0)
        XCTAssertEqual(binding.signingPublicKey, id.signingPublicKey)
        XCTAssertEqual(binding.signature.count, 64)
        XCTAssertEqual(binding.encode(), vec1Serialized)

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

    // 21. vector-2 state issues exact endian_lock binding (locked KAT)
    func test21Vector2IssuesExactEndianLockBinding() throws {
        let kc = InMemoryKeychain()
        let state = try LocalIdentityStateV1(generation: 0x01020304, ed25519Seed: vec2EdPriv, x25519PrivateKey: vec2XPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()

        let id = try MeshIdentity.loadFromKeychain(keychain: kc)
        let binding = try id.issueIdentityBinding()

        XCTAssertEqual(binding.version, 0x01)
        XCTAssertEqual(binding.generation, 0x01020304)
        XCTAssertEqual(binding.signingPublicKey, id.signingPublicKey)
        XCTAssertEqual(binding.staticDhPublicKey, id.staticDhPublicKey)
        XCTAssertEqual(binding.signature.count, 64)
        XCTAssertEqual(binding.encode(), vec2Serialized)

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

    // 22. vector-3 state issues exact max_generation binding (locked KAT)
    func test22Vector3IssuesExactMaxGenerationBinding() throws {
        let kc = InMemoryKeychain()
        let state = try LocalIdentityStateV1(generation: UInt32.max, ed25519Seed: vec3EdPriv, x25519PrivateKey: vec3XPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()

        let id = try MeshIdentity.loadFromKeychain(keychain: kc)
        let binding = try id.issueIdentityBinding()

        XCTAssertEqual(binding.version, 0x01)
        XCTAssertEqual(binding.generation, UInt32.max)
        XCTAssertEqual(binding.signingPublicKey, id.signingPublicKey)
        XCTAssertEqual(binding.staticDhPublicKey, id.staticDhPublicKey)
        XCTAssertEqual(binding.signature.count, 64)
        XCTAssertEqual(binding.encode(), vec3Serialized)

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
        let kc = InMemoryKeychain()
        let id = try MeshIdentity.generateAndStore(keychain: kc)

        // Verifies calling without parameters compiles and succeeds
        let binding = try id.issueIdentityBinding()
        XCTAssertEqual(binding.generation, 0)
    }

    // 24. issuer output passes C8 1A IdentityBindingValidator
    func test24IssuerOutputPassesIdentityBindingValidator() throws {
        let kc = InMemoryKeychain()
        let id = try MeshIdentity.generateAndStore(keychain: kc)

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

    // 27. wipe coordinator: erase failure leaves journal at requested
    func test27WipeEraseFailureLeavesJournalRequested() {
        let kc = InMemoryKeychain()
        kc.failDelete = errSecIO
        let journal = InMemoryWipeJournal()
        let artifacts = KeychainWipeArtifacts(keychain: kc)
        let wipe = PanicWipe(journal: journal, artifacts: artifacts)

        XCTAssertThrowsError(try wipe.begin())
        XCTAssertEqual(journal.read(), .requested)
    }

    // 28. wipe coordinator: regeneration add failure leaves journal at artifactsDeleted
    func test28WipeRegenerateAddFailureLeavesJournalArtifactsDeleted() throws {
        let kc = InMemoryKeychain()
        let state = try LocalIdentityStateV1(generation: 0, ed25519Seed: vec1EdPriv, x25519PrivateKey: vec1XPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()

        // Erase succeeds, but subsequent regeneration add fails
        kc.failAdd = errSecIO
        let journal = InMemoryWipeJournal()
        let artifacts = KeychainWipeArtifacts(keychain: kc)
        let wipe = PanicWipe(journal: journal, artifacts: artifacts)

        XCTAssertThrowsError(try wipe.begin())
        XCTAssertEqual(journal.read(), .artifactsDeleted)
    }

    // 29. wipe coordinator: successful wipe installs generation 0 in V1
    func test29SuccessfulWipeInstallsGeneration0InV1() throws {
        let kc = InMemoryKeychain()
        let state = try LocalIdentityStateV1(generation: 42, ed25519Seed: vec1EdPriv, x25519PrivateKey: vec1XPriv)
        kc.storage[MeshIdentity.v1Tag] = state.encode()

        let journal = InMemoryWipeJournal()
        let artifacts = KeychainWipeArtifacts(keychain: kc)
        let wipe = PanicWipe(journal: journal, artifacts: artifacts)

        try wipe.begin()
        XCTAssertEqual(journal.read(), .idle)

        let regenerated = try MeshIdentity.loadFromKeychain(keychain: kc)
        XCTAssertEqual(regenerated.bindingGeneration, 0)
    }
}
