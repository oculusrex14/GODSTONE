import XCTest
@testable import GodstoneCore
@testable import GodstoneMesh
import CryptoKit

/// T07: replace unilateral rekey with deterministic session retirement.
///
/// Regression targets: the Swift engine rehashed directional keys without
/// peer coordination. After T07: no rekey-in-place API remains; the session
/// budget is monotonic from trusted establishment (2^20 records per
/// direction or 30 minutes); retirement is terminal (keys and readiness
/// cleared, fresh trusted session required); counters never reset.
final class ReadinessT07Tests: XCTestCase {

    private func establishPair() throws
        -> (NoiseSession, NoiseSession) {
        let alice = NoiseSession(
            role: .initiator,
            staticKey: try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: Data(repeating: 0xA7, count: 32)),
            localHint: Data([0x07, 0x07, 0x07, 0x07]),
            remoteHint: Data([0x08, 0x08, 0x08, 0x08]))
        let bob = NoiseSession(
            role: .responder,
            staticKey: try Curve25519.KeyAgreement.PrivateKey(
                rawRepresentation: Data(repeating: 0xB7, count: 32)),
            localHint: Data([0x08, 0x08, 0x08, 0x08]),
            remoteHint: Data([0x07, 0x07, 0x07, 0x07]))
        let m1 = try alice.writeMessage1()
        let m2 = try bob.readMessage1AndWrite2(m1)
        _ = try alice.readMessage2(m2)
        let m3 = try alice.writeMessage3()
        try bob.readMessage3(m3)
        XCTAssertTrue(alice.isEstablished)
        XCTAssertTrue(bob.isEstablished)
        return (alice, bob)
    }

    func testSendBudgetExhaustion_RetiresTerminal() throws {
        let (alice, _) = try establishPair()
        alice.recordBudgetForTest = 2
        _ = try alice.encrypt(Data("a".utf8))
        _ = try alice.encrypt(Data("b".utf8))
        XCTAssertThrowsError(try alice.encrypt(Data("c".utf8))) { error in
            guard let expired = error as? NoiseSession.SessionExpired else {
                XCTFail("expected SessionExpired, got \(error)")
                return
            }
            XCTAssertEqual("send budget exceeded (records)", expired.reason)
        }
        // Terminal: readiness and key material are cleared.
        XCTAssertFalse(alice.isEstablished)
        XCTAssertThrowsError(try alice.encrypt(Data("d".utf8))) { error in
            XCTAssertTrue(error is NoiseSession.SessionExpired,
                          "retired sessions must refuse further operations: \(error)")
        }
        // A fresh trusted session establishes and works.
        let (alice2, bob2) = try establishPair()
        let plain = try bob2.decrypt(try alice2.encrypt(Data("fresh".utf8)))
        XCTAssertEqual(plain, Data("fresh".utf8))
    }

    func testReceiveBudgetExhaustion_ReturnsExpired() throws {
        let (alice, bob) = try establishPair()
        bob.recordBudgetForTest = 2
        if case .authenticated = try bob.openWithResult(
            try alice.encrypt(Data("a".utf8))) {} else {
            XCTFail("vector a must authenticate")
        }
        if case .authenticated = try bob.openWithResult(
            try alice.encrypt(Data("b".utf8))) {} else {
            XCTFail("vector b must authenticate")
        }
        // The third open is outside the budget: typed Expired, retired.
        let expiredOutcome = try bob.openWithResult(
            try alice.encrypt(Data("c".utf8)))
        if case .expired = expiredOutcome {} else {
            XCTFail("budget exhaustion must return .expired")
        }
        XCTAssertFalse(bob.isEstablished)
    }

    func testTimeBudgetExpiry_RetiresSession() throws {
        let (alice, _) = try establishPair()
        alice.ageBudgetForTest = 0.000001
        alice.establishedMonoForTest =
            DispatchTime.now().uptimeNanoseconds &- 31 * 1_000_000_000
        XCTAssertThrowsError(try alice.encrypt(Data("late".utf8))) { error in
            guard let expired = error as? NoiseSession.SessionExpired else {
                XCTFail("expected SessionExpired, got \(error)")
                return
            }
            XCTAssertEqual("send budget exceeded (time)", expired.reason)
        }
        XCTAssertFalse(alice.isEstablished)
    }

    func testPeerNonceBeyondBudgetRejected() throws {
        let (alice, bob) = try establishPair()
        // A peer nonce at the agreed budget boundary is outside the budget.
        let forged = TransportCiphertextV1.encode(
            nonce: UnsignedNonce.policyCeiling, ciphertextAndTag: Data(count: 16))
        // CRYPTO-002: THE AUDIT'S LAW FOR THIS INPUT, QUOTED, because this arm previously asserted the OPPOSITE and
        // the difference is load-bearing: "Bad tag, replay and forged high nonce remain BOUNDED REJECTION; a later
        // genuine in-policy nonce still authenticates. Do not close a healthy session just because an attacker
        // supplies an excessive nonce." A forged high nonce that RETIRED the session would be a ONE-PACKET
        // denial-of-service against a healthy relation, so the bounded rejection is the correct expectation and this
        // assertion is CORRECTED TO THE FINDING rather than bent to make a repair pass.
        guard case .rejected = try bob.openWithResult(forged) else {
            XCTFail("a forged high nonce is a BOUNDED REJECTION, never a retirement (CRYPTO-002)")
            return
        }
        XCTAssertTrue(bob.isEstablished, "and the session survives it")
        // The window mutated nothing: the next legitimate frame works.
        if case .authenticated = try bob.openWithResult(
            try alice.encrypt(Data("next".utf8))) {} else {
            XCTFail("recovery frame must authenticate")
        }
    }

    func testNoCounterResetUnderExistingKey() throws {
        let (alice, bob) = try establishPair()
        for index in 0..<5 {
            let sealed = try alice.encrypt(Data("m\(index)".utf8))
            let decoded = TransportCiphertextV1.decode(sealed)
            XCTAssertEqual(decoded!.nonce, UInt64(index),
                           "nonces never reset under an existing key")
            if case .authenticated = try bob.openWithResult(sealed) {} else {
                XCTFail("frame \(index) must authenticate")
            }
        }
        alice.recordBudgetForTest = 8
        var sent = 0
        XCTAssertThrowsError(try repeatElement(0, count: 100).forEach { _ in
            _ = try alice.encrypt(Data("bulk\(sent)".utf8))
            sent += 1
        }) { error in
            XCTAssertTrue(error is NoiseSession.SessionExpired,
                          "budget must terminate the loop")
        }
        XCTAssertFalse(alice.isEstablished)
    }

    /// The repo's Swift sources, located by WALKING UP from this file's own path.
    ///
    /// *** THE HARD-CODED `../../Godstone/...` WAS CORRECT FOR EXACTLY ONE TEST RUNNER, AND THE OTHER ONE IS
    /// THE SIMULATOR. *** *`#filePath` is not the same string under `swift test` and under `xcodebuild test`:
    /// the package runner reports `.../ios/Godstone/Tests/GodstoneMeshTests/X.swift`, while the simulator
    /// reports `.../ios/Packages/GodstoneFoundation/Tests/GodstoneMeshTests/X.swift` (the generated mirror).
    /// The fixed substitution therefore resolved to `.../ios/Godstone/../../Godstone/Sources/...` -- a path
    /// with a DOUBLED `ios/`, and NSCocoaErrorDomain 260. MEASURED on the simulator, which is the first run in
    /// which this arm executed at all.* **Walking up to the first ancestor that actually CARRIES the tree is
    /// correct under either layout, and if no ancestor carries it the arm FAILS rather than skipping -- a skip
    /// would be a silent exemption.**
    private func godstoneSource(_ relative: String) throws -> String {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }
            dir = dir.deletingLastPathComponent()
        }
        XCTFail("the Swift source tree is not reachable from \(#filePath); looked for \(relative)")
        throw NSError(domain: "ReadinessT07", code: 1)
    }

    func testRekeyInPlaceApiRemoved() throws {
        // L0 source-integrity: the ad hoc rehashing API is gone; the
        // retirement budget replaced it.
        let session = try godstoneSource("Sources/GodstoneMesh/NoiseSession.swift")
        XCTAssertFalse(session.contains("rekeyIfNeeded"),
                       "no rekey-in-place API remains")
        XCTAssertFalse(session.contains("rekeyMessageLimit"),
                       "no unilateral rekey thresholds remain")
        XCTAssertTrue(session.contains("SessionBudget"))
        XCTAssertTrue(session.contains("SessionExpired"))
    }
}