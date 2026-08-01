import XCTest
@testable import GodstoneCore
@testable import GodstoneMesh
import CryptoKit

final class PortVectorTests: XCTestCase {
    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testBlake2sPortMatchesGeneratedVectors() {
        let cases: [(Data, Int, String)] = [
            (Data(), 32, "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9"),
            (Data("abc".utf8), 32, "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982"),
            (Data("abc".utf8), 16, "aa4938119b1dc7b87cbad0ffd200d0ae"),
            (Data("abc".utf8), 8, "972e9d2cd6de6402"),
            (Data(repeating: 0xA5, count: 64), 32, "f85b88e0ac55872416d202c5f4881e7dbc9c7270542ef75074ff9b0a610b5a0e"),
            (Data(repeating: 0xA5, count: 65), 32, "65bba861969fcb5f1d8ec69e1dbd3e891f546b02203ce73b27958b9589a6789d")
        ]
        for (input, length, expected) in cases {
            XCTAssertEqual(hex(Blake2s.hash(input, digestLength: length)), expected)
        }
    }

    func testNoiseXXEmptyPayloadMessageSizesAndTransport() throws {
        let initiatorStatic = Curve25519.KeyAgreement.PrivateKey()
        let responderStatic = Curve25519.KeyAgreement.PrivateKey()
        let initiatorHint = Data([1, 2, 3, 4])
        let responderHint = Data([5, 6, 7, 8])

        let initiator = NoiseSession(role: .initiator, staticKey: initiatorStatic,
                                     localHint: initiatorHint, remoteHint: responderHint)
        let responder = NoiseSession(role: .responder, staticKey: responderStatic,
                                     localHint: responderHint, remoteHint: initiatorHint)

        let m1 = try initiator.writeMessage1()
        let m2 = try responder.readMessage1AndWrite2(m1)
        let m3 = try initiator.readMessage2AndWrite3(m2)
        try responder.readMessage3(m3)

        XCTAssertEqual([m1.count, m2.count, m3.count], [32, 96, 64])
        XCTAssertTrue(initiator.isEstablished)
        XCTAssertTrue(responder.isEstablished)
        XCTAssertEqual(initiator.transcriptHash, responder.transcriptHash)

        let message = Data("godstone-port-vector".utf8)
        XCTAssertEqual(try responder.decrypt(initiator.encrypt(message)), message)
        XCTAssertEqual(try initiator.decrypt(responder.encrypt(message)), message)
    }
}
