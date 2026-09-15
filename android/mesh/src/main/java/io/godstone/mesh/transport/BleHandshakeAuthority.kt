package io.godstone.mesh.transport

import io.godstone.mesh.crypto.SessionManager

/**
 * BL22 -- THE SUBSTRATE'S OWN HANDSHAKE AUTHORITY.
 *
 * The production BLE transport MUST NOT call the session registry's handshake surface directly
 * (`beginInitiator`, `initiatorProcessHs2`, `responderProcessHs1`, `responderProcessHs3`). That
 * surface belongeth to the crypto owner (`io.godstone.mesh.crypto.SessionManager`); a transport that
 * reacheth into it couples the radio to ONE implementation of trust establishment, and the audit's
 * control refuseth the coupling by name.
 *
 * The transport speaketh THIS interface instead, and [SessionHandshakeAuthority] adapteth it to the
 * registry. So the dependency pointeth at the substrate seam: the handshake vocabulary is the
 * SUBSTRATE'S (start, continue, accept, complete), a court may drive the transport with a fake
 * authority and NO session manager at all, and the registry's own method names appear in exactly one
 * adapter rather than scattered through the radio.
 *
 * WHAT THIS IS NOT: it is not a new trust decision. Every method delegate th to the same registry
 * call it replaceth, so the wire bytes, the trust table and the refusal semantics are unchanged --
 * the readiness courts that drive real handshakes end-to-end are the control that proveth it.
 */
internal interface BleHandshakeAuthority {
    /** Open the OUTBOUND (initiator) handshake, yielding HS1 -- or null when trust refuseth. */
    fun startOutboundHandshake(peerId: ByteArray, remoteHint: ByteArray): ByteArray?

    /** Continue the OUTBOUND handshake with the peer's HS2, yielding HS3 -- or null when refused. */
    fun continueOutboundHandshake(
        peerId: ByteArray,
        hs2: ByteArray,
        advertisedRemoteHint: ByteArray,
    ): ByteArray?

    /** Accept an INBOUND (responder) handshake from the peer's HS1, yielding HS2 -- or null. */
    fun acceptInboundHandshake(
        peerId: ByteArray,
        remoteHint: ByteArray,
        hs1: ByteArray,
    ): ByteArray?

    /** Complete the INBOUND handshake with the peer's HS3: true only when trust standeth. */
    fun completeInboundHandshake(
        peerId: ByteArray,
        hs3: ByteArray,
        advertisedRemoteHint: ByteArray,
    ): Boolean
}

/**
 * The production adapter: the session registry IS the authority behind the substrate seam. This is
 * the ONE place in the transport package where the registry's handshake vocabulary is spoken.
 */
internal class SessionHandshakeAuthority(
    private val sessions: SessionManager,
) : BleHandshakeAuthority {
    override fun startOutboundHandshake(peerId: ByteArray, remoteHint: ByteArray): ByteArray? =
        sessions.beginInitiator(peerId, remoteHint)

    override fun continueOutboundHandshake(
        peerId: ByteArray,
        hs2: ByteArray,
        advertisedRemoteHint: ByteArray,
    ): ByteArray? = sessions.initiatorProcessHs2(peerId, hs2, advertisedRemoteHint)

    override fun acceptInboundHandshake(
        peerId: ByteArray,
        remoteHint: ByteArray,
        hs1: ByteArray,
    ): ByteArray? = sessions.responderProcessHs1(peerId, remoteHint, hs1)

    override fun completeInboundHandshake(
        peerId: ByteArray,
        hs3: ByteArray,
        advertisedRemoteHint: ByteArray,
    ): Boolean = sessions.responderProcessHs3(peerId, hs3, advertisedRemoteHint)
}
