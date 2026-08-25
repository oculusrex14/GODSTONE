import XCTest
@testable import GodstoneCore
@testable import GodstoneMesh
import CryptoKit

/// Cross-platform Noise conformance for the GMP/2.1 prologue (ADR-008 patch 21).
///
/// Patch 20 flipped the Noise_XX prologue magic ``GMP1`` -> ``GMP2`` across both
/// platforms so a GMP/2.1 node cannot complete a handshake with a GMP/1 node
/// (downgrade / cross-protocol isolation: the handshake hash diverges before
/// the first DH). The Android mirror -- `NoiseSessionTest.kt` -- proves that
/// with a live alice<->bob handshake executed under `:mesh:testDebugUnitTest`.
///
/// This file is the iOS execution evidence the same gate demanded: it runs the
/// GMP2 prologue on iOS via `xcodebuild test` (the patch 21 gate) and proves
/// three things that are NOT visible to the static parity gate (Invariant A/F/H
/// never execute Swift):
///
///  (1) The prologue bound into the transcript is literally ``"GMP2"`` -- a
///      deterministic, pinned assertion against Blake2s, so a regression back to
///      ``"GMP1"`` fails this test, not just a code review.
///
///  (2) A live alice<->bob Noise_XX handshake completes with the GMP2 prologue
///      and both sides reach an identical transcript hash (the property that
///      makes transport keys agree). This is the same shape of proof the Android
///      mirror uses; the two platform suites now both EXECUTE the GMP2
///      handshake rather than asserting it in a comment.
///
///  (3) A divergent prologue (a peer that computed its handshake hash from a
///      different prologue) cannot complete the handshake -- the first AEAD
///      operation (encrypted static key in message 2) fails because the AAD
///      (handshake hash) disagrees. This is the isolation property the prologue
///      exists for, executed rather than assumed. The GMP1-vs-GMP2 case is the
///      same mechanism (the magic is part of the prologue); the divergence is
///      induced via mismatched hints here because the prologue magic is a
///      compile-time constant in `NoiseSession` and cannot be injected without
///      a second Noise implementation, which is out of scope (the Android mirror
///      does not pin it either).
///
/// This is NOT a pinned external Noise vector (A-06 stays OPEN / Invariant D
/// UNPINNED): both sides here are the same iOS implementation agreeing with
/// itself. The cross-platform conformance that closes patch 21 is "iOS executes
/// the GMP2 handshake and agrees with Android on the wire + Noise prologue",
/// not "iOS matches an independent Noise fixture".
final class NoiseSessionTests: XCTestCase {

    private static let protocolName = "Noise_XX_25519_ChaChaPoly_BLAKE2s"

    // MARK: - (1) the prologue bound into the transcript is literally "GMP2"

    /// Right after `init`, before any message is mixed in, the handshake hash is
    /// `Blake2s(h0 || prologue)` where `h0` is the padded/hashed protocol name
    /// (33 bytes -> hashed to 32) and `prologue = "GMP2" || i_hint || r_hint`
    /// (initiator ordering: local then remote). `transcriptHash` exposes that
    /// pre-message hash, so we can pin the GMP2 bytes deterministically.
    func testPrologueIsGmp2BoundIntoTranscript() {
        let hintA = Data([0xaa, 0x01, 0x02, 0x03])
        let hintB = Data([0xbb, 0x04, 0x05, 0x06])

        let alice = NoiseSession(role: .initiator,
                                staticKey: Curve25519.KeyAgreement.PrivateKey(),
                                localHint: hintA,
                                remoteHint: hintB)

        let name = Data(NoiseSessionTests.protocolName.utf8)
        // name.count == 33 > HASHLEN(32) -> InitializeSymmetric hashes it.
        let h0 = Blake2s.hash(name, digestLength: 32)
        let prologue = Data("GMP2".utf8) + hintA + hintB
        let expected = Blake2s.hash(h0 + prologue, digestLength: 32)

        XCTAssertEqual(alice.transcriptHash, expected,
                       "transcript hash must be Blake2s(h0 || \"GMP2\" || hints); "
                       + "a regression to GMP1 would change this")
    }

    // MARK: - (2) a live alice<->bob handshake completes with the GMP2 prologue

    func testHandshakeEstablishsBothSidesAndTranscriptMatches() throws {
        let hintA = Data(repeating: 0x01, count: 8)   // initiator hint
        let hintB = Data(repeating: 0x02, count: 8)   // responder hint

        let alice = NoiseSession(role: .initiator,
                                staticKey: Curve25519.KeyAgreement.PrivateKey(),
                                localHint: hintA,
                                remoteHint: hintB)
        let bob = NoiseSession(role: .responder,
                              staticKey: Curve25519.KeyAgreement.PrivateKey(),
                              localHint: hintB,
                              remoteHint: hintA)

        // XX: -> e   <- e, ee, s, es   -> s, se
        let m1 = try alice.writeMessage1()
        let m2 = try bob.readMessage1AndWrite2(m1)
        _ = try alice.readMessage2(m2)
        let m3 = try alice.writeMessage3()
        try bob.readMessage3(m3)

        XCTAssertTrue(alice.isEstablished, "alice must be established after XX")
        XCTAssertTrue(bob.isEstablished, "bob must be established after XX")
        XCTAssertEqual(alice.transcriptHash, bob.transcriptHash,
                       "both sides must agree on the transcript hash (the GMP2 "
                       + "prologue is shared, so the hashes match)")

        // Transport keys derived from the same handshake must round-trip.
        let plaintext = Data("ping-over-gmp2".utf8)
        let ciphertext = try alice.encrypt(plaintext)
        let recovered = try bob.decrypt(ciphertext)
        XCTAssertEqual(recovered, plaintext,
                       "transport must round-trip once the GMP2 handshake completes")
    }

    // MARK: - (3) a divergent prologue cannot complete the handshake (isolation)

    func testDivergentPrologueBreaksHandshake() throws {
        let hintA = Data(repeating: 0x01, count: 8)
        let hintB = Data(repeating: 0x02, count: 8)

        let alice = NoiseSession(role: .initiator,
                                 staticKey: Curve25519.KeyAgreement.PrivateKey(),
                                 localHint: hintA,
                                 remoteHint: hintB)
        // bob computes its prologue from the WRONG remote hint, so the two
        // handshake hashes diverge from the start (same effect as a GMP1 peer).
        let bob = NoiseSession(role: .responder,
                               staticKey: Curve25519.KeyAgreement.PrivateKey(),
                               localHint: hintB,
                               remoteHint: Data(repeating: 0xff, count: 8))

        let m1 = try alice.writeMessage1()
        let m2 = try bob.readMessage1AndWrite2(m1)

        XCTAssertThrowsError(try alice.readMessage2(m2)) { err in
            // The first AEAD open (encrypted static in message 2) fails because
            // the AAD (handshake hash, seeded by the prologue) disagrees.
            // ChaChaPoly.open surfaces that as a CryptoKitError (authentication
            // failure), which propagates uncaught; the handshake does NOT
            // complete and isEstablished stays false -- which is the property
            // that isolates a GMP2 node from any peer with a different prologue.
            _ = err
        }
        XCTAssertFalse(alice.isEstablished,
                       "alice must NOT be established against a divergent-prologue peer")
    }
}