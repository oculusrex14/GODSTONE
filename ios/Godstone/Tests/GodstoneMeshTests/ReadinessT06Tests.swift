import XCTest
@testable import GodstoneCore
@testable import GodstoneMesh
import CryptoKit

/// T06: unify Swift DATA nonce framing with Android.
///
/// Wire contract under test: DATA ciphertext = uint64_be(nonce) || ChaChaPoly
/// ciphertext || tag, with the internal ChaChaPoly nonce staying
/// zero32 || uint64_le(n). The shared transport vector manifest
/// (wire/transport_vectors_android.json, origin_engine "android") is verified
/// here against the REAL Swift engine; this suite also exports the Swift
/// engine's own vectors (fixed keys, deterministic bytes) for the Android
/// mirror to verify.
///
/// Canonical location: ios/Godstone/Tests/ - the Foundation package Tests
/// tree is a destructive sync product of this file (never edit the copy).
final class ReadinessT06Tests: XCTestCase {

    // MARK: - deterministic fixtures (identical to the Android exporter)

    private static let initiatorDh = Data(repeating: 0xA1, count: 32)
    private static let responderDh = Data(repeating: 0xB1, count: 32)
    private static let hintI = Data([0x11, 0x11, 0x11, 0x11])
    private static let hintR = Data([0x22, 0x22, 0x22, 0x22])
    private static let plaintexts: [Data] = [
        Data(), Data("transport-one".utf8), Data("transport-two".utf8),
        Data(),
    ]

    private func fixedKey(_ raw: Data) throws
        -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    private func makePair() throws -> (NoiseSession, NoiseSession) {
        let alice = NoiseSession(
            role: .initiator,
            staticKey: try fixedKey(ReadinessT06Tests.initiatorDh),
            localHint: ReadinessT06Tests.hintI,
            remoteHint: ReadinessT06Tests.hintR)
        let bob = NoiseSession(
            role: .responder,
            staticKey: try fixedKey(ReadinessT06Tests.responderDh),
            localHint: ReadinessT06Tests.hintR,
            remoteHint: ReadinessT06Tests.hintI)
        return (alice, bob)
    }

    private func establishPair() throws -> (NoiseSession, NoiseSession) {
        let (alice, bob) = try makePair()
        try driveHandshake(alice: alice, bob: bob)
        XCTAssertTrue(alice.isEstablished)
        XCTAssertTrue(bob.isEstablished)
        return (alice, bob)
    }

    private func driveHandshake(alice: NoiseSession, bob: NoiseSession) throws {
        let m1 = try alice.writeMessage1()
        let m2 = try bob.readMessage1AndWrite2(m1)
        _ = try alice.readMessage2(m2)
        let m3 = try alice.writeMessage3()
        try bob.readMessage3(m3)
    }

    private func repoWireURL() -> URL {
        // .../GodstoneFoundation/Tests/GodstoneMeshTests/<file>.swift after
        // the sync; resolve the repository-root wire/ directory by walking up.
        let url = URL(fileURLWithPath: #filePath)
        var root = url.deletingLastPathComponent()
        repeat {
            let wire = root.appendingPathComponent("wire")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: wire.path,
                                             isDirectory: &isDirectory),
               isDirectory.boolValue {
                return wire
            }
            let parent = root.deletingLastPathComponent()
            if parent.path == root.path { break }
            root = parent
        } while root.path != "/"
        XCTFail("wire directory not found above \(#filePath)")
        return root
    }

    private func hexData(_ s: String) -> Data {
        var bytes: [UInt8] = []
        var iterator = s.startIndex
        while iterator < s.endIndex {
            let next = s.index(iterator, offsetBy: 2)
            bytes.append(UInt8(s[iterator..<next], radix: 16)!)
            iterator = next
        }
        return Data(bytes)
    }

    private func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - exporter (real Swift engine, fixture transport key)

    private static let fixtureKey = Data(repeating: 0x5A, count: 32)

    func testExportSwiftTransportVectors() throws {
        let sender = NoiseSession(
            role: .initiator,
            staticKey: try fixedKey(ReadinessT06Tests.initiatorDh),
            localHint: ReadinessT06Tests.hintI,
            remoteHint: ReadinessT06Tests.hintR)
        sender.installSendKeyForTest(SymmetricKey(data: ReadinessT06Tests.fixtureKey))
        let receiver = NoiseSession(
            role: .responder,
            staticKey: try fixedKey(ReadinessT06Tests.responderDh),
            localHint: ReadinessT06Tests.hintR,
            remoteHint: ReadinessT06Tests.hintI)
        receiver.installReceiveKeyForTest(SymmetricKey(data: ReadinessT06Tests.fixtureKey))
        var steps: [[String: String]] = []
        for (index, plaintext) in ReadinessT06Tests.plaintexts.enumerated() {
            let sealed = try sender.encrypt(plaintext)
            let decoded = TransportCiphertextV1.decode(sealed)
            XCTAssertNotNil(decoded, "frame \(index) must carry the nonce prefix")
            XCTAssertEqual(decoded!.nonce, UInt64(index),
                           "wire nonce must be the explicit BE prefix")
            let opened = try receiver.decrypt(sealed)
            XCTAssertEqual(opened, plaintext)
            steps.append([
                "nonce_u64": String(index),
                "plaintext_hex": hexString(plaintext),
                "ciphertext_hex": hexString(sealed),
            ])
        }
        let manifest: [String: Any] = [
            "schema_version": 1,
            "origin_engine": "swift",
            "suite": "Noise_XX_25519_ChaChaPoly_BLAKE2s",
            "transport": steps,
            "transport_key_hex": hexString(ReadinessT06Tests.fixtureKey),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
        let url = repoWireURL()
            .appendingPathComponent("transport_vectors_swift.json")
        try data.write(to: url, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - cross-engine verification of the ANDROID vectors

    func testSwiftEngineVerifiesAndroidTransportVectors() throws {
        let url = repoWireURL()
            .appendingPathComponent("transport_vectors_android.json")
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data)
            as! [String: Any]
        XCTAssertEqual(json["origin_engine"] as? String, "android",
                       "must verify the other engine's vectors")
        XCTAssertEqual(json["suite"] as? String,
                       "Noise_XX_25519_ChaChaPoly_BLAKE2s")
        XCTAssertEqual(json["transport_key_hex"] as? String,
                       hexString(ReadinessT06Tests.fixtureKey),
                       "fixture transport key must match the shared constant")
        let receiver = NoiseSession(
            role: .responder,
            staticKey: try fixedKey(ReadinessT06Tests.responderDh),
            localHint: ReadinessT06Tests.hintR,
            remoteHint: ReadinessT06Tests.hintI)
        receiver.installReceiveKeyForTest(
            SymmetricKey(data: ReadinessT06Tests.fixtureKey))
        let steps = json["transport"] as! [[String: Any]]
        var accepted = 0
        for (index, step) in steps.enumerated() {
            let ciphertext = hexData(step["ciphertext_hex"] as! String)
            let expected = hexData(step["plaintext_hex"] as? String ?? "")
            let outcome = try receiver.openWithResult(ciphertext)
            guard case .authenticated(let plain) = outcome else {
                XCTFail("android vector \(index) must authenticate: \(outcome)")
                continue
            }
            XCTAssertEqual(plain, expected,
                           "cross-engine plaintext must match (vector \(index))")
            accepted += 1
        }
        XCTAssertGreaterThanOrEqual(accepted, 4)
        // A replay of the last committed vector must be expired.
        let replayOutcome = try receiver.openWithResult(
            hexData(steps.last!["ciphertext_hex"] as! String))
        if case .authenticated = replayOutcome {
            XCTFail("replay must expire")
        }
    }

    // MARK: - framing and rejection parity

    func testLegacyImplicitCounterCiphertextIsNeverAutoDetected() throws {
        let (alice, bob) = try establishPair()
        _ = try bob.decrypt(try alice.encrypt(Data("seed".utf8)))
        // Legacy shape: a REAL sealed box with the uint64_be prefix STRIPPED -
        // exactly the pre-T06 implicit-counter wire bytes.
        let sealed = try alice.encrypt(Data("legacy-shape".utf8))
        let legacyShape = TransportCiphertextV1.decode(sealed)!.ciphertextAndTag
        // Never auto-detect: the first 8 bytes are parsed as a nonce, so the
        // AEAD opens against the wrong material and must not authenticate.
        let outcome = try bob.openWithResult(legacyShape)
        if case .authenticated = outcome {
            XCTFail("legacy implicit-counter ciphertext must never " +
                    "auto-detect")
        }
    }

    func testForgedHighNonceCommitsNothingAndRecoveryWorks() throws {
        let (alice, bob) = try establishPair()
        for n in 0...3 {
            let sealed = try alice.encrypt(ReadinessT06Tests.plaintexts[n])
            if case .authenticated = try bob.openWithResult(sealed) {} else {
                XCTFail("vector \(n) must authenticate")
            }
        }
        // T07: forge at the last IN-BUDGET nonce so the preview/AEAD
        // failure path (not the parser) is what rejects it.
        let forged = TransportCiphertextV1.encode(
            nonce: UnsignedNonce.policyCeiling - 1, ciphertextAndTag: Data(count: 16))
        if case .rejected = try bob.openWithResult(forged) {} else {
            XCTFail("forged frame must be rejected")
        }
        // The real next frame (nonce 4) still authenticates.
        let next = try alice.encrypt(Data("five".utf8))
        if case .authenticated = try bob.openWithResult(next) {} else {
            XCTFail("recovery frame must authenticate")
        }
    }

    func testEmptyPlaintextAcceptedAndTyped() throws {
        let (alice, bob) = try establishPair()
        let sealed = try alice.encrypt(Data())
        let outcome = try bob.openWithResult(sealed)
        var plain: Data? = nil
        if case .authenticated(let opened) = outcome { plain = opened }
        if plain == nil {
            XCTFail("empty primitive plaintext must authenticate")
        }
        XCTAssertEqual(plain, Data())
    }

    func testReplayWindowPreviewPurityParity() {
        let window = ReplayWindow()
        let first = window.preview(10)
        XCTAssertEqual(first, .accept(nonce: 10, forwardShift: 11, index: -1))
        XCTAssertEqual(window.preview(10), first)
        XCTAssertNil(window.highest())
        window.commit(first)
        XCTAssertEqual(window.highest(), 10)
        XCTAssertEqual(window.preview(10), .reject)
    }
}