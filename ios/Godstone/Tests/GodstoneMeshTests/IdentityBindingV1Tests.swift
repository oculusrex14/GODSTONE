import XCTest
@testable import GodstoneMesh
import GodstoneCore
import CryptoKit

final class IdentityBindingV1Tests: XCTestCase {

    private func data(fromHex hex: String) -> Data {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // Authoritative Vector 1: fresh_generation_zero
    private let vec1Name = "fresh_generation_zero"
    private let vec1Gen: UInt32 = 0
    private let vec1EdSeedHex = "1111111111111111111111111111111111111111111111111111111111111111"
    private let vec1SigningPubHex = "d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c9778737"
    private let vec1StaticDhPubHex = "0faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20"
    private let vec1NodeIdHex = "8d17e35ae833d7c0ce931166dacf1311"
    private let vec1PreimageHex = "474d50322d494442494e440100000000d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c97787370faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20"
    private let vec1SigHex = "4c546a07b0e80598eb6a290e3e3c8f364c059edf3804bd42a6924a7b0186e68217af7316c5f93cc40e35bb2731e752e758e7206fa6061b6ab349280752ec1908"
    private let vec1SerializedHex = "0100000000d04ab232742bb4ab3a1368bd4615e4e6d0224ab71a016baf8520a332c97787370faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f204c546a07b0e80598eb6a290e3e3c8f364c059edf3804bd42a6924a7b0186e68217af7316c5f93cc40e35bb2731e752e758e7206fa6061b6ab349280752ec1908"

    // Authoritative Vector 2: endian_lock
    private let vec2Name = "endian_lock"
    private let vec2Gen: UInt32 = 16909060 // 0x01020304
    private let vec2EdSeedHex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private let vec2SigningPubHex = "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8"
    private let vec2StaticDhPubHex = "358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254"
    private let vec2NodeIdHex = "43a49857a024ee41b7f247d7d234fbc6"
    private let vec2PreimageHex = "474d50322d494442494e44010102030403a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254"
    private let vec2SigHex = "595d507f2602b2f52fe4ed8c72a4720e6e37206c81aecaf725654fdd41a4a08c942b23022c352dee7583d11380e5d288fa5ebc6d7fb894c8e65e7052c1778d02"
    private let vec2SerializedHex = "010102030403a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8358072d6365880d1aeea329adf9121383851ed21a28e3b75e965d0d2cd166254595d507f2602b2f52fe4ed8c72a4720e6e37206c81aecaf725654fdd41a4a08c942b23022c352dee7583d11380e5d288fa5ebc6d7fb894c8e65e7052c1778d02"

    // Authoritative Vector 3: max_generation
    private let vec3Name = "max_generation"
    private let vec3Gen: UInt32 = 4294967295 // 0xffffffff
    private let vec3EdSeedHex = "a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5"
    private let vec3SigningPubHex = "29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55"
    private let vec3StaticDhPubHex = "b0d08f35b4683381489afb32825e59152d47d19bc9e050d6d5a954984c9d1e2c"
    private let vec3NodeIdHex = "fa6673ab45e5bdf47d2969afa59d71cb"
    private let vec3PreimageHex = "474d50322d494442494e4401ffffffff29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55b0d08f35b4683381489afb32825e59152d47d19bc9e050d6d5a954984c9d1e2c"
    private let vec3SigHex = "1079c3b37526daba3ebc207f7d7802f750a21ad38442542f6ea504ef3f11453430aa06a673d483738a0ffc071ee6418ecc4c875072db6ec82bb20eedf44b9d02"
    private let vec3SerializedHex = "01ffffffff29e5833a915a6429a4e3a7948475c338ef436eb82be89c92f059704403db9d55b0d08f35b4683381489afb32825e59152d47d19bc9e050d6d5a954984c9d1e2c1079c3b37526daba3ebc207f7d7802f750a21ad38442542f6ea504ef3f11453430aa06a673d483738a0ffc071ee6418ecc4c875072db6ec82bb20eedf44b9d02"

    func testFreshGenerationZeroKat() throws {
        let serialized = data(fromHex: vec1SerializedHex)
        let staticDh = data(fromHex: vec1StaticDhPubHex)
        let expectedNodeId = data(fromHex: vec1NodeIdHex)
        let hint = expectedNodeId.prefix(4)

        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: staticDh,
            advertisedNodeHint: hint
        )

        guard case .valid(let binding) = result else {
            XCTFail("Expected .valid for fresh_generation_zero KAT")
            return
        }

        XCTAssertEqual(binding.generation, 0)
        XCTAssertEqual(binding.nodeId, expectedNodeId)
        XCTAssertEqual(binding.signingPublicKey, data(fromHex: vec1SigningPubHex))
        XCTAssertEqual(binding.staticDhPublicKey, staticDh)

        let parsed = try IdentityBindingV1.parse(serialized)
        XCTAssertEqual(parsed.generation, 0)
        XCTAssertEqual(parsed.encode(), serialized)
    }

    func testEndianLockKat() throws {
        let serialized = data(fromHex: vec2SerializedHex)
        let staticDh = data(fromHex: vec2StaticDhPubHex)
        let expectedNodeId = data(fromHex: vec2NodeIdHex)
        let hint = expectedNodeId.prefix(4)

        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: staticDh,
            advertisedNodeHint: hint
        )

        guard case .valid(let binding) = result else {
            XCTFail("Expected .valid for endian_lock KAT")
            return
        }

        XCTAssertEqual(binding.generation, 16909060)
        XCTAssertEqual(binding.nodeId, expectedNodeId)
        XCTAssertEqual(binding.signingPublicKey, data(fromHex: vec2SigningPubHex))
        XCTAssertEqual(binding.staticDhPublicKey, staticDh)

        let parsed = try IdentityBindingV1.parse(serialized)
        XCTAssertEqual(parsed.generation, 0x01020304)
        XCTAssertEqual(parsed.encode(), serialized)
    }

    func testMaxGenerationKat() throws {
        let serialized = data(fromHex: vec3SerializedHex)
        let staticDh = data(fromHex: vec3StaticDhPubHex)
        let expectedNodeId = data(fromHex: vec3NodeIdHex)
        let hint = expectedNodeId.prefix(4)

        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: staticDh,
            advertisedNodeHint: hint
        )

        guard case .valid(let binding) = result else {
            XCTFail("Expected .valid for max_generation KAT")
            return
        }

        XCTAssertEqual(binding.generation, 4294967295)
        XCTAssertEqual(binding.nodeId, expectedNodeId)
        XCTAssertEqual(binding.signingPublicKey, data(fromHex: vec3SigningPubHex))
        XCTAssertEqual(binding.staticDhPublicKey, staticDh)

        let parsed = try IdentityBindingV1.parse(serialized)
        XCTAssertEqual(parsed.generation, 0xFFFFFFFF)
        XCTAssertEqual(parsed.encode(), serialized)
    }

    func testExact80BytePreimageReproduction() {
        let p1 = IdentityBindingV1.signaturePreimage(
            generation: vec1Gen,
            signingPublicKey: data(fromHex: vec1SigningPubHex),
            staticDhPublicKey: data(fromHex: vec1StaticDhPubHex)
        )
        XCTAssertEqual(p1.count, 80)
        XCTAssertEqual(hex(p1), vec1PreimageHex)

        let p2 = IdentityBindingV1.signaturePreimage(
            generation: vec2Gen,
            signingPublicKey: data(fromHex: vec2SigningPubHex),
            staticDhPublicKey: data(fromHex: vec2StaticDhPubHex)
        )
        XCTAssertEqual(p2.count, 80)
        XCTAssertEqual(hex(p2), vec2PreimageHex)

        let p3 = IdentityBindingV1.signaturePreimage(
            generation: vec3Gen,
            signingPublicKey: data(fromHex: vec3SigningPubHex),
            staticDhPublicKey: data(fromHex: vec3StaticDhPubHex)
        )
        XCTAssertEqual(p3.count, 80)
        XCTAssertEqual(hex(p3), vec3PreimageHex)
    }

    func testExact133ByteSerialization() {
        let obj = IdentityBindingV1(
            generation: vec1Gen,
            signingPublicKey: data(fromHex: vec1SigningPubHex),
            staticDhPublicKey: data(fromHex: vec1StaticDhPubHex),
            signature: data(fromHex: vec1SigHex)
        )
        let enc = obj.encode()
        XCTAssertEqual(enc.count, 133)
        XCTAssertEqual(hex(enc), vec1SerializedHex)
    }

    func testParseAndEncodeRoundTripByteIdentical() throws {
        for hexStr in [vec1SerializedHex, vec2SerializedHex, vec3SerializedHex] {
            let raw = data(fromHex: hexStr)
            let parsed = try IdentityBindingV1.parse(raw)
            XCTAssertEqual(parsed.encode(), raw)
        }
    }

    func testValidSignatureAccepted() throws {
        let signingPub = data(fromHex: vec1SigningPubHex)
        let staticDh = data(fromHex: vec1StaticDhPubHex)
        let sig = data(fromHex: vec1SigHex)
        let preimage = IdentityBindingV1.signaturePreimage(
            generation: vec1Gen,
            signingPublicKey: signingPub,
            staticDhPublicKey: staticDh
        )
        let pubKey = try Curve25519.Signing.PublicKey(rawRepresentation: signingPub)
        XCTAssertTrue(pubKey.isValidSignature(sig, for: preimage))
    }

    func testBadSignatureOneBitCorruptionRejected() {
        var serialized = data(fromHex: vec1SerializedHex)
        let staticDh = data(fromHex: vec1StaticDhPubHex)
        let hint = data(fromHex: vec1NodeIdHex).prefix(4)

        // Corrupt signature byte
        serialized[69] ^= 0x01
        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: staticDh,
            advertisedNodeHint: hint
        )
        XCTAssertEqual(result, .invalidSignature)
    }

    func testWrongSigningPublicKeyRejected() {
        var serialized = data(fromHex: vec1SerializedHex)
        let staticDh = data(fromHex: vec1StaticDhPubHex)
        let hint = data(fromHex: vec1NodeIdHex).prefix(4)

        // Overwrite signing key with Vector 2's signing key
        let wrongKey = data(fromHex: vec2SigningPubHex)
        serialized.replaceSubrange(5..<37, with: wrongKey)
        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: staticDh,
            advertisedNodeHint: hint
        )
        XCTAssertEqual(result, .invalidSignature)
    }

    func testRemoteNoiseStaticMismatchRejected() {
        let serialized = data(fromHex: vec1SerializedHex)
        let wrongStaticDh = data(fromHex: vec2StaticDhPubHex)
        let hint = data(fromHex: vec1NodeIdHex).prefix(4)

        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: wrongStaticDh,
            advertisedNodeHint: hint
        )
        XCTAssertEqual(result, .noiseStaticMismatch)
    }

    func testAdvertisedHintMismatchRejected() {
        let serialized = data(fromHex: vec1SerializedHex)
        let staticDh = data(fromHex: vec1StaticDhPubHex)
        let wrongHint = Data([0x00, 0x00, 0x00, 0x00])

        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: staticDh,
            advertisedNodeHint: wrongHint
        )
        XCTAssertEqual(result, .advertisementHintMismatch)
    }

    func testBadVersionRejected() {
        var serialized = data(fromHex: vec1SerializedHex)
        let staticDh = data(fromHex: vec1StaticDhPubHex)
        let hint = data(fromHex: vec1NodeIdHex).prefix(4)

        serialized[0] = 0x02
        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: staticDh,
            advertisedNodeHint: hint
        )
        XCTAssertEqual(result, .unsupportedVersion)
        XCTAssertThrowsError(try IdentityBindingV1.parse(serialized))
    }

    func testTruncated132BytePayloadRejected() {
        let serialized = data(fromHex: vec1SerializedHex).prefix(132)
        let staticDh = data(fromHex: vec1StaticDhPubHex)
        let hint = data(fromHex: vec1NodeIdHex).prefix(4)

        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: staticDh,
            advertisedNodeHint: hint
        )
        XCTAssertEqual(result, .malformedLength)
        XCTAssertThrowsError(try IdentityBindingV1.parse(serialized))
    }

    func testOversized134BytePayloadRejected() {
        var serialized = data(fromHex: vec1SerializedHex)
        serialized.append(0x00)
        let staticDh = data(fromHex: vec1StaticDhPubHex)
        let hint = data(fromHex: vec1NodeIdHex).prefix(4)

        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: staticDh,
            advertisedNodeHint: hint
        )
        XCTAssertEqual(result, .malformedLength)
        XCTAssertThrowsError(try IdentityBindingV1.parse(serialized))
    }

    func testMalformedAuthenticatedStaticContextRejected() {
        let serialized = data(fromHex: vec1SerializedHex)
        let badStatic = Data(repeating: 0x00, count: 31)
        let hint = data(fromHex: vec1NodeIdHex).prefix(4)

        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: badStatic,
            advertisedNodeHint: hint
        )
        XCTAssertEqual(result, .invalidContext)
    }

    func testMalformedAdvertisedHintContextRejected() {
        let serialized = data(fromHex: vec1SerializedHex)
        let staticDh = data(fromHex: vec1StaticDhPubHex)
        let badHint = Data(repeating: 0x00, count: 5)

        let result = IdentityBindingValidator.validate(
            serialized: serialized,
            authenticatedRemoteStaticKey: staticDh,
            advertisedNodeHint: badHint
        )
        XCTAssertEqual(result, .invalidContext)
    }

    func testSwiftBufferIndependence() throws {
        var mutableBuffer = data(fromHex: vec1SerializedHex)
        let parsed = try IdentityBindingV1.parse(mutableBuffer)

        // Mutate original buffer
        mutableBuffer[5] ^= 0xFF
        XCTAssertNotEqual(mutableBuffer[5], parsed.signingPublicKey[0])

        // Verify ValidatedPeerBinding independence
        let staticDh = data(fromHex: vec1StaticDhPubHex)
        let hint = data(fromHex: vec1NodeIdHex).prefix(4)
        var freshBuffer = data(fromHex: vec1SerializedHex)
        let result = IdentityBindingValidator.validate(
            serialized: freshBuffer,
            authenticatedRemoteStaticKey: staticDh,
            advertisedNodeHint: hint
        )
        guard case .valid(let validated) = result else {
            XCTFail("Expected .valid")
            return
        }
        freshBuffer[5] ^= 0xFF
        XCTAssertNotEqual(freshBuffer[5], validated.signingPublicKey[0])
    }

    func testGenerationBigEndianParsingVerification() throws {
        let serialized = data(fromHex: vec2SerializedHex)
        let parsed = try IdentityBindingV1.parse(serialized)
        XCTAssertEqual(parsed.generation, 16909060)
        XCTAssertEqual(parsed.generation, 0x01020304)
    }

    func testGenerationUnsignedMaxParsingVerification() throws {
        let serialized = data(fromHex: vec3SerializedHex)
        let parsed = try IdentityBindingV1.parse(serialized)
        XCTAssertEqual(parsed.generation, 4294967295)
        XCTAssertEqual(parsed.generation, 0xFFFFFFFF)
    }
}
