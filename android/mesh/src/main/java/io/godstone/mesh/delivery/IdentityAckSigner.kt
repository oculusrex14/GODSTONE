// GS-RUNTIME-001 step 2, THE ANDROID TWIN OF iOS's `IdentityAckSigner` -- THE PRODUCTION ACK SIGNER OVER THE
// PINNED IDENTITY.
//
// THE DEFECT THIS CLOSETH, MEASURED AT ROUND 228: `interface AckSignerSeam` asked for "THE 32-BYTE ED25519 SEED OF
// THE STILL-VALID LOCAL IDENTITY", and its ONLY concrete conformer stood in the HARNESS
// (`runtime/ComposedRuntime.kt:603`) -- so no production signer could exist there, for the same measured reason
// the Swift isle found: THE SEAM'S SHAPE ASSUMED THE HARNESS.
//
// THIS SIGNER NEVER RELEASES ANYTHING THROUGH THE SEAM: `signingSeed` answereth null (the harness road is not for
// production, and a caller that receiveth null learneth the truth rather than a stand-in), and `signAck` signeth
// the canonical preimage with the identity's own seed, which never leaveth this module.

package io.godstone.mesh.delivery

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.mesh.identity.Identity

internal class IdentityAckSigner(private val identity: Identity) : AckSignerSeam {

    override val nodeId: ByteArray get() = identity.nodeId

    override fun generation(): Long = identity.bindingGeneration

    /** THE HARNESS ROAD IS REFUSED BY CONSTRUCTION. */
    override fun signingSeed(msgId: ByteArray, recipientNodeId: ByteArray): ByteArray? = null

    /** THE PRODUCTION ROAD: the identity signeth the canonical preimage itself. */
    override fun signAck(msgId: ByteArray, recipientNodeId: ByteArray): ByteArray? =
        Ed25519Keys.sign(AckFrame.preimage(msgId, recipientNodeId), identity.identityPriv)
}
