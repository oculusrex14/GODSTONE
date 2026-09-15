package io.godstone.mesh.readiness

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.mesh.identity.IdentityBindingV1
import io.godstone.mesh.wire.v2.SosSigningAuthority

/**
 * GS-SOS-001 — A COURT THAT DISPATCHETH AN SOS MUST WIRE AN AUTHORITY.
 *
 * The audit's card: "missing signing authority still queues and offers an unauthenticated SOS." The
 * node now REFUSES when no authority is wired (and when the authority yields no material), so a court
 * that dispatches an SOS must supply one. Several courts never did: measured at round 144, `ReadinessT39Test`,
 * `ReadinessT43Test`, `ReadinessT44Test` and `MeshNodeDeliveryIntegrationTest` mention `sosAuthority`
 * ZERO TIMES -- they relied on the legacy unauthenticated path as a CONVENIENCE while testing
 * cancellation, durable projections, torn-pair campaigns and the C6 delivery ledger.
 *
 * THIS IS A COURT FIXTURE AND NOTHING ELSE: the material below is FIXED, PUBLIC and DELIBERATELY NOT
 * SECRET. It proves no real key, signs no real distress call, and is never used outside the :mesh test
 * source set. Its only job is to let those courts dispatch an AUTHORED SOS so that they may go on
 * testing what they were written to test.
 *
 * WIRE IT WITH ONE LINE, right after the node is constructed:
 *
 *     node.sosAuthority = SosTestAuthority()
 *
 * NOTE ON INTENT, SO THAT A LATER READER DOTH NOT MISREAD IT: a court that ASSERTETH the unauthenticated
 * shape must NOT be repaired this way -- the ONLY such arm was `ReadinessT38Test`'s legacy arm, which
 * round 143 REVERSED with the reversal recorded inside the arm itself.
 */
internal class SosTestAuthority(
    private val seed: ByteArray = ByteArray(32) { (it + 1).toByte() },
    private val dhPublicKey: ByteArray = ByteArray(32) { (it + 0x40).toByte() },
    private val nonce: ByteArray = ByteArray(16) { (it + 0x11).toByte() },
    private val generation: Long = 1L,
    private val clock: Long = 1_700_000_000L,
) : SosSigningAuthority {
    /** How many times the authority was consulted; courts may assert it was used. */
    var calls: Int = 0
        private set

    override fun currentNonce(): ByteArray { calls++; return nonce.copyOf() }
    override fun currentSigningSeed(): ByteArray? = seed.copyOf()
    override fun currentStaticDhPublicKey(): ByteArray? = dhPublicKey.copyOf()
    override fun currentGeneration(): Long = generation
    override fun currentTimeEpochSeconds(): Long = clock

    /** GS-SOS-001, second defect: the AUTHORITY issueth the binding, so the author path needeth
     *  never strike one. Built here in TEST sources, where the construction is legitimate -- the
     *  repository control scaneth production (main) files only. */
    override fun currentIdentityBinding(): IdentityBindingV1 = bind()

    /** The binding this fixture issueth; courts MAY compare it against what a frame carrieth. */
    fun issuedBinding(): IdentityBindingV1 = bind()

    private fun bind(): IdentityBindingV1 {
        val pub = Ed25519Keys.publicKeyFromPrivate(seed)
        return IdentityBindingV1.create(
            generation = generation,
            signingPublicKey = pub,
            staticDhPublicKey = dhPublicKey,
            signature = Ed25519Keys.sign(
                IdentityBindingV1.signaturePreimage(generation, pub, dhPublicKey), seed),
        )
    }
}
