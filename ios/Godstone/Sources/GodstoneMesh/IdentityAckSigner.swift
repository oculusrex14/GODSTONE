// GS-RUNTIME-001 step 2 -- THE PRODUCTION ACK SIGNER, OVER THE PINNED IDENTITY.

// THE DEFECT THIS CLOSETH, MEASURED AT ROUND 212: the only concrete `AckSignerSeam` implementations in the
// repository were `ComposedRuntime.TestAckSigner` (whose own confession is "IT IS HARNESS SUPPORT AND NOT A
// DEVICE RESULT") and a test-local signer -- because the seam ASKED FOR A PRIVATE SEED, which `MeshIdentity`
// keepeth private and MUST keep private. So no production signer could exist, and the durable ACK road could not
// be constructed over the pinned identity at all.

// THIS SIGNER NEVER RELEASES ANYTHING: `signingSeed` answereth nil (the harness road is not for production),
// and `signAck` signeth the canonical preimage with the identity's own key, through `MeshIdentity.sign`, whose
// key material never leaveth the identity.

import Foundation

final class IdentityAckSigner: AckSignerSeam, @unchecked Sendable {
    private let identity: MeshIdentity

    init(identity: MeshIdentity) {
        self.identity = identity
    }

    var nodeId: Data? { identity.nodeId }

    func generation() -> Int64 { Int64(identity.bindingGeneration) }

    /// THE HARNESS ROAD IS REFUSED BY CONSTRUCTION: a production identity doth not export its signing seed, and
    /// a caller that receiveth nil here learneth the truth rather than a stand-in.
    func signingSeed(msgId: Data, recipientNodeId: Data) throws -> Data? { nil }

    /// THE PRODUCTION ROAD: the identity signeth the canonical preimage itself.
    func signAck(msgId: Data, recipientNodeId: Data) throws -> Data? {
        try identity.sign(message: AckFrame.preimage(msgId: msgId, recipientNodeId: recipientNodeId))
    }
}
