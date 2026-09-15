// GS-SOS-001 -- the SOS signing authority the COURTS wire into a node they build.
//
// This file liveth in TEST sources ON PURPOSE, and that is load-bearing: the repository's
// local-identity control scaneth PRODUCTION sources only (`ios/Godstone/Sources/GodstoneMesh`
// and its Android twin), because the rule it enforces is that a production file outside the
// AUTHORITY files may not issue an identity binding. A COURT, by contrast, must be able to
// strike one: it is exactly how a fixture simulates an authority that holds material. The
// Android isle carrieth the same fixture for the same reason (`readiness/SosTestAuthority.kt`).
//
// WHAT IT IS NOT: not a device, radio or runtime result. The material is FIXED AND PUBLIC by
// construction, so a court that ASSERTETH the authenticity of a frame under a real node's
// identity must NOT use this -- it must wire material that belongs to the node (the composed
// harness doth that: it hands `SimulatedSosAuthority` the seed IT generated). This fixture
// existeth for the courts that assert DELIVERY, QUEUEING and REFUSAL outcomes.
import Foundation
import CryptoKit
@testable import GodstoneMesh

final class SosTestAuthority: SosSigningAuthority, @unchecked Sendable {
    private let seedV: Data
    private let dhV: Data
    private let generationV: UInt32
    private let clockV: Int64
    private let nonceV: Data
    /// How many times the authority was consulted; a court may assert it was used.
    var calls: Int = 0

    init(seed: Data = Data(repeating: 0x1B, count: 32),
         dhPublicKey: Data = Data(repeating: 0x4D, count: 32),
         generation: UInt32 = 1,
         clock: Int64 = 1_700_000_000,
         nonce: Data = Data(repeating: 0x2E, count: 16)) {
        self.seedV = seed
        self.dhV = dhPublicKey
        self.generationV = generation
        self.clockV = clock
        self.nonceV = nonce
    }

    func currentNonce() -> Data { calls += 1; return nonceV }
    func currentSigningSeed() -> Data? { seedV }
    func currentStaticDhPublicKey() -> Data? { dhV }
    func currentGeneration() -> UInt32 { generationV }
    func currentTimeEpochSeconds() -> Int64 { clockV }

    /// GS-SOS-001, second defect: the AUTHORITY issueth the binding, so the author path never
    /// needeth to strike one. Test-side construction is legitimate here (see the header note).
    func currentIdentityBinding() -> IdentityBindingV1? { issuedBinding() }

    /// The binding this fixture issueth; a court MAY compare it against what a frame carrieth.
    func issuedBinding() -> IdentityBindingV1 {
        let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: seedV)
        let pub = key.publicKey.rawRepresentation
        let preimage = IdentityBindingV1.signaturePreimage(
            generation: generationV, signingPublicKey: pub, staticDhPublicKey: dhV)
        return IdentityBindingV1(
            generation: generationV,
            signingPublicKey: pub,
            staticDhPublicKey: dhV,
            signature: try! key.signature(for: preimage))
    }
}
