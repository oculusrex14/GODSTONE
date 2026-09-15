// BL22 -- THE SUBSTRATE'S OWN HANDSHAKE AUTHORITY (the iOS twin of Android's
// `transport/BleHandshakeAuthority.kt`).
//
// The production BLE transport MUST NOT call the session registry's handshake surface directly
// (`beginInitiator`, `initiatorProcessHs2`, `responderProcessHs1`, `responderProcessHs3`). That
// surface belongeth to the crypto owner (`SessionManager`); a transport that reacheth into it
// couples the radio to ONE implementation of trust establishment, and the audit's control refuseth
// the coupling by name.
//
// The transport speaketh THIS protocol instead, and `SessionHandshakeAuthority` adapteth it to the
// registry. So the dependency pointeth at the substrate seam: the handshake vocabulary is the
// SUBSTRATE'S (start, continue, accept, complete), a court may drive the transport with a fake
// authority and NO session manager at all, and the registry's own method names appear in exactly one
// adapter rather than scattered through the radio.
//
// WHAT THIS IS NOT: it is not a new trust decision. Every method delegates to the same registry call
// it replaceth, so the wire bytes, the trust table and the refusal semantics are unchanged -- the
// readiness courts that drive real handshakes end-to-end are the control that proveth it.
import Foundation

internal protocol BleHandshakeAuthority: AnyObject {
    /// Open the OUTBOUND (initiator) handshake, yielding HS1 -- or nil when trust refuseth.
    func startOutboundHandshake(peerId: UUID, remoteHint: Data) -> Data?

    /// Continue the OUTBOUND handshake with the peer's HS2, yielding HS3 -- or nil when refused.
    func continueOutboundHandshake(peerId: UUID, hs2: Data, advertisedRemoteHint: Data) -> Data?

    /// Accept an INBOUND (responder) handshake from the peer's HS1, yielding HS2 -- or nil.
    func acceptInboundHandshake(peerId: UUID, remoteHint: Data, hs1: Data) -> Data?

    /// Complete the INBOUND handshake with the peer's HS3: true only when trust standeth.
    func completeInboundHandshake(peerId: UUID, hs3: Data, advertisedRemoteHint: Data) -> Bool
}

/// The production adapter: the session registry IS the authority behind the substrate seam. This is
/// the ONE place in the transport package where the registry's handshake vocabulary is spoken.
internal final class SessionHandshakeAuthority: BleHandshakeAuthority {
    private let sessions: SessionManager

    internal init(sessions: SessionManager) {
        self.sessions = sessions
    }

    internal func startOutboundHandshake(peerId: UUID, remoteHint: Data) -> Data? {
        return sessions.beginInitiator(peerId, remoteHint: remoteHint)
    }

    internal func continueOutboundHandshake(peerId: UUID, hs2: Data,
                                            advertisedRemoteHint: Data) -> Data? {
        return sessions.initiatorProcessHs2(peerId, hs2: hs2,
                                            advertisedRemoteHint: advertisedRemoteHint)
    }

    internal func acceptInboundHandshake(peerId: UUID, remoteHint: Data, hs1: Data) -> Data? {
        return sessions.responderProcessHs1(peerId, remoteHint: remoteHint, hs1: hs1)
    }

    internal func completeInboundHandshake(peerId: UUID, hs3: Data,
                                           advertisedRemoteHint: Data) -> Bool {
        return sessions.responderProcessHs3(peerId, hs3: hs3,
                                            advertisedRemoteHint: advertisedRemoteHint)
    }
}
