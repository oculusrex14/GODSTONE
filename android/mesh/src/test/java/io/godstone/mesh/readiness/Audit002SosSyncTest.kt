package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// GS-SOS-001 -- *** THE AUDITOR'S OWN ARMS, MOVED INTO THE CANONICAL SUITE. ***
//
// THE CARD'S STEP 1, IN ITS OWN WORDS: "Copy Audit002SosSyncTest.missingSigningAuthorityMustNotQueueUnauthenticatedSos
// into the canonical mesh tests and preserve its empty-store expectation. Keep
// configuredAuthorityProducesVerifiableSos as the positive control."
//
// THIS FILE IS THE AUDIT'S OWN INDEPENDENT ASSERTION, NOT THE AUTHOR'S, and it is the FIRST such in this
// programme: the arm was written by the auditor, RUN BY THE AUDITOR on the audited tree, and its own recorded XML
// carrieth the verdict --
//
//     Audit002SosSyncTest   tests="4"  failures="3"
//     missingSigningAuthorityMustNotQueueUnauthenticatedSos  FAILED
//         java.lang.AssertionError: Missing signing authority must be typed failure, got QueuedLocally
//     configuredAuthorityProducesVerifiableSos              PASSED   <- the positive control
//
// -- so the ARM and its FAILURE both pre-date this remediation, and the repair is measured against a bar THE
// AUDITOR ERECTED rather than one this span chose for itself.
//
// WHY IT HAD NOT BEEN COPIED UNTIL NOW: MEASURED at round 522 -- the string
// `missingSigningAuthorityMustNotQueueUnauthenticatedSos` appeared NOWHERE in the repository, on either isle, while
// the card's ordered remediation placeth this copy FIRST. The finding's other work landed on other arms.
//
// THE SOURCE IS READ-ONLY AND IS NAMED EXACTLY:
//   AUDIT_FINAL_2026-09-15/evidence/AUDIT-002/sos_sync/Audit002SosSyncTest.kt
//
// *** THE TWO DEVIATIONS FROM THE AUDITOR'S TEXT, NAMED RATHER THAN SILENT, BECAUSE A COPY THAT DRIFTS IN SILENCE
// IS NOT A COPY: ***
//   (1) THE POSITIVE CONTROL'S AUTHORITY GAINED `currentIdentityBinding()`. The interface GROWTH is this finding's
//       OWN second defect (the author path must OBTAIN the binding from the authority rather than strike its own --
//       `SosSigningAuthority:139`), so the auditor's arm predateth that member and CANNOT COMPILE as written. The
//       member is added IN THE AUDITOR'S OWN IDIOM: the authority issueth a binding over the very material it
//       yieldeth, exactly as the court fixture `SosTestAuthority.kt` doth it.
//   (2) NOTHING ELSE IS CHANGED. Every assertion, every expectation and every message is the auditor's own text.
//
// AND WHAT WAS **NOT** COPIED, WITH ITS REASON: the auditor's file carrieth FOUR arms, and two of them -- 
// `cancelDuringFirstPendingOfferMustSuppressLaterPeerOffer` and `inventoryReceiverMustEnforce64PageRunLimit` -- also
// FAILED on the audited tree ("No later peer may receive new work after local cancellation expected:<1> but was:<2>",
// and "65th page must be refused, got Accepted"). THEY ARE NOT COPIED HERE, because A MANDATORY LANE MAY NOT BE
// MADE RED BY A COPY: they are a separate piece of work, and they are NAMED so that nothing claimeth they are done.
// ---------------------------------------------------------------------------

import io.godstone.core.crypto.Ed25519Keys
import io.godstone.core.crypto.X25519Keys
import io.godstone.mesh.*
import io.godstone.mesh.identity.Identity
import io.godstone.mesh.identity.IdentityBindingV1
import io.godstone.mesh.delivery.*
import io.godstone.mesh.store.InMemoryMessageStore
import io.godstone.mesh.wire.v2.*
import java.security.SecureRandom
import kotlinx.coroutines.test.runTest
import org.junit.Test
import org.junit.Assert.*

class Audit002SosSyncTest {
    private fun rig(signed: Boolean): Pair<MeshNode, InMemoryMessageStore> {
        val rng = SecureRandom(); val ed = Ed25519Keys.generate(rng); val dh = X25519Keys.generate(rng)
        val store = InMemoryMessageStore()
        val auth = object : AckAuthenticator {
            override fun verify(originalMsgId: ByteArray, expectedRecipientNodeId: ByteArray, ackFrame: FrameV2) = false
        }
        val node = MeshNode(null, Identity.fromKeyMaterial(ed.pub, ed.priv, dh.pub, dh.priv), store,
                            DeliveryTracker(InMemoryStoreDeliveryRepository(store), auth))
        if (signed) node.sosAuthority = object : SosSigningAuthority {
            override fun currentNonce() = ByteArray(16) { 3 }
            override fun currentSigningSeed() = ed.priv
            override fun currentStaticDhPublicKey() = dh.pub
            override fun currentGeneration() = 1L
            override fun currentTimeEpochSeconds() = 0L
            // DEVIATION (1) OF TWO, AND IT IS FORCED BY THIS FINDING'S OWN SECOND DEFECT: the interface gained this
            // member, so the auditor's five-member object cannot satisfy it. The binding is ISSUED BY THE AUTHORITY
            // over the material it yieldeth -- the auditor's own idiom, taken from `SosTestAuthority.kt:55-63`.
            override fun currentIdentityBinding(): IdentityBindingV1 {
                val pub = Ed25519Keys.publicKeyFromPrivate(ed.priv)
                return IdentityBindingV1.create(
                    generation = 1L,
                    signingPublicKey = pub,
                    staticDhPublicKey = dh.pub,
                    signature = Ed25519Keys.sign(
                        IdentityBindingV1.signaturePreimage(1L, pub, dh.pub), ed.priv),
                )
            }
        }
        return node to store
    }

    /** THE CARD'S KEY ARM, ITS ASSERTIONS AND ITS MESSAGE UNCHANGED. Its second line IS the "empty-store
     *  expectation" the card demandeth be preserved. */
    @Test
    fun missingSigningAuthorityMustNotQueueUnauthenticatedSos() = runTest {
        val (node, store) = rig(false)
        val result = node.dispatchSos("help".toByteArray()) { _, _ -> false }
        assertTrue("Missing signing authority must be typed failure, got $result",
                   result is SosDispatchResult.Failed || result is SosDispatchResult.Unavailable)
        assertEquals(0, store.allHeldMsgIds().size)
    }

    /** THE CARD'S POSITIVE CONTROL, and it is what maketh the arm above JUDGE: without it, a node that refused
     *  EVERY dispatch would satisfy the first arm while being useless. */
    @Test
    fun configuredAuthorityProducesVerifiableSos() = runTest {
        val (node, store) = rig(true)
        assertEquals(SosDispatchResult.QueuedLocally, node.dispatchSos("help".toByteArray()) { _, _ -> false })
        assertTrue(SignedSosV1.verify(store.allHeldOrderedByPriority().single(), null) is SosAuthResult.Authenticated)
    }
}
