package io.godstone.mesh.readiness

// ---------------------------------------------------------------------------
// T24 - the capture-at-the-authenticated-moment primitive (android, pure host).
//
// The routing-carriage integration will construct a peer's immutable identity
// ONLY from the authenticated identity public key the transport learned when the
// relation was seal'd. The raw TrustedPeer constructor trusteth any node id the
// caller supplyeth; this witness proveth that TrustedPeer.capture FORCETH the
// frozen identity law (node_id = BLAKE2s-128(identityPub)) upon the capture, so
// a captured peer can never disagree with its own identity, and that it refuseth
// a malformed capture and copies its inputs defensively.
//
// It toucheth no live path and no frozen wire/identity code: it onely DEFERETH
// to the canonical derivation the identity layer alreadi employeth.
// ---------------------------------------------------------------------------

import io.godstone.mesh.identity.Identity
import io.godstone.mesh.transport.BleDirection
import io.godstone.mesh.transport.RelationKey
import io.godstone.mesh.transport.TrustedPeer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadinessT24CaptureTest {

    private fun relation(gen: Long): RelationKey =
        RelationKey(BleDirection.INBOUND, "AA:BB:CC:DD:EE:FF", gen)

    // A deterministick, well-form'd 32-byte authenticated identity public key.
    private fun identityPub(seed: Int): ByteArray = ByteArray(32) { index -> ((index * 7 + seed) and 0xFF).toByte() }

    // The heart of the law: capture DERIVETH the node id from the identity, so it
    // cannot be coaxed into carrying an inconsistent one.
    @Test
    fun testCaptureDerivetheTheNodeIdFromTheAuthenticatedIdentity() {
        val pub = identityPub(11)
        val canonical = Identity.nodeIdOf(pub)
        assertEquals("the canonical derivation is sixteene bytes", 16, canonical.size)

        val captured = TrustedPeer.capture(relation(1L), pub, 3L)
        assertArrayEquals("capture deferreth to the canonical authority", canonical, captured.copyNodeId())
        assertEquals("the identity is carried verbatim (defensive read)", 32, captured.copyIdentityPub().size)
        assertArrayEquals("the identity is preserved", pub, captured.copyIdentityPub())
        assertEquals("the trust version is kept", 3L, captured.trustVersion)
    }

    // A peer built by hand with a node id that DOETH NOT match its identity is the
    // very inconsistency capture must forbid; capture, given the same identity,
    // yieldeth the true derivation and none other.
    @Test
    fun testCaptureRefusethToCarryAnInconsistentHandMadeNodeId() {
        val pub = identityPub(23)
        val wrong = ByteArray(16) { 0x5A } // a plausible-width but WRONG node id
        val byHand = TrustedPeer(relation(1L), wrong, pub, 3L) // the raw door accepteth it
        val captured = TrustedPeer.capture(relation(1L), pub, 3L)

        assertFalse("the hand-made identity is inconsistent with its node id", byHand.nodeId16.contentEquals(Identity.nodeIdOf(pub)))
        assertArrayEquals("capture deriveth the true node id, not the hand-made one", Identity.nodeIdOf(pub), captured.copyNodeId())
        assertNotEquals("a captured peer is not the inconsistent hand-made peer", byHand, captured)
    }

    // The capture defendeth its identity: a later mutation of the caller's array
    // leaveth the captured copy whole.
    @Test
    fun testCaptureCopiethTheAuthenticatedIdentityDefensively() {
        val pub = identityPub(31)
        val before = pub.copyOf()
        val captured = TrustedPeer.capture(relation(1L), pub, 2L)
        pub[0] = 0x00
        pub[31] = 0xFF.toByte()
        assertArrayEquals("the captured identity is a defensive copy", before, captured.copyIdentityPub())
    }

    // A malformed authenticated identity (a wrong-width public key) is refus'd at
    // the gate, before any derivation.
    @Test
    fun testAwrongWidthIdentityIsRefusedEreDerivation() {
        val tooShort = ByteArray(31) { 0x11 }
        val tooLong = ByteArray(33) { 0x22 }
        var refusedShort = false
        try { TrustedPeer.capture(relation(1L), tooShort, 1L) } catch (e: IllegalArgumentException) { refusedShort = true }
        var refusedLong = false
        try { TrustedPeer.capture(relation(1L), tooLong, 1L) } catch (e: IllegalArgumentException) { refusedLong = true }
        assertTrue("a thirty-one-byte identity is refus'd", refusedShort)
        assertTrue("a thirty-three-byte identity is refus'd", refusedLong)
    }

    // A trust version must be a non-negative count.
    @Test
    fun testAnegativeTrustVersionIsRefusedAtTheGate() {
        var refused = false
        try { TrustedPeer.capture(relation(1L), identityPub(7), -1L) } catch (e: IllegalArgumentException) { refused = true }
        assertTrue("a negative trust version is refus'd", refused)
    }

    // Two captures of the selfsame authenticated relation and identity are one peer.
    @Test
    fun testTwoCapturesOfTheSelfsameRelationAreOnePeer() {
        val a = TrustedPeer.capture(relation(9L), identityPub(3), 5L)
        val b = TrustedPeer.capture(relation(9L), identityPub(3), 5L)
        assertEquals("the captures agree by content", a, b)
        assertEquals("and agree in hash", a.hashCode(), b.hashCode())
    }

    // Cross-platform invariant (section 5: preserve the canonical generated identity
    // formula). The android and iOS capture primitive MUST derive the selfsame node id
    // from the selfsame authenticated identity. For the fixed identity below, BOTH
    // isles' canonical BLAKE2s-128 derivations were observ'd to yield the identical
    // sixteen-octet vector here pinned; any divergence of the two crypto implementations
    // (which no single-isle suite can see) is caught by this one assertion.
    @Test
    fun testTheIdentityDerivationAgreethAcrossIslesForAFixedVector() {
        val pub = identityPub(13)
        val expected = intArrayOf(
            0x3B, 0xAF, 0x31, 0xFE, 0x8B, 0xE5, 0x64, 0xAC,
            0xAA, 0xD5, 0xD4, 0xA7, 0xD9, 0xB4, 0x40, 0x3D,
        ).map { it.toByte() }.toByteArray()
        val captured = TrustedPeer.capture(relation(1L), pub, 0L)
            ?: throw AssertionError("a well-form'd capture must succeed")
        assertArrayEquals(
            "the identity derivation matcheth the canonical cross-isle vector",
            expected, captured.copyNodeId(),
        )
        assertEquals("the node id is sixteene octets", 16, captured.copyNodeId().size)
    }
}
