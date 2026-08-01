import Foundation
import CryptoKit
import GodstoneCore

/// Per-peer Noise session registry -- the layer that was MISSING from the runtime.
///
/// THE DEFECT THIS CLOSES. `NoiseSession.swift` existed and was carefully
/// written, and nothing in the app ever constructed one. `BleTransport.send`
/// wrote `frame.encode()` straight to the characteristic, so every byte the
/// mesh sent was PLAINTEXT while the app, the store listing and the threat
/// model all described end-to-end encryption.
///
/// There is deliberately no plaintext fallback: if no session is established
/// the send fails and the delay-tolerant router carries the frame to the next
/// encounter. Delay is the designed behaviour. Leaking is not.
public final class SessionManager {

    private let identity: MeshIdentity
    private var sessions: [UUID: NoiseSession] = [:]
    private let lock = NSLock()

    public init(identity: MeshIdentity) {
        self.identity = identity
    }

    public func established(_ peerId: UUID) -> NoiseSession? {
        lock.lock(); defer { lock.unlock() }
        guard let s = sessions[peerId], s.isEstablished else { return nil }
        return s
    }

    @discardableResult
    public func beginInitiator(_ peerId: UUID, remoteHint: Data) -> NoiseSession {
        lock.lock(); defer { lock.unlock() }
        if let existing = sessions[peerId] { return existing }
        let s = NoiseSession(role: .initiator,
                             staticKey: identity.agreementKey,
                             localHint: identity.nodeHint,
                             remoteHint: remoteHint)
        sessions[peerId] = s
        return s
    }

    @discardableResult
    public func beginResponder(_ peerId: UUID, remoteHint: Data) -> NoiseSession {
        lock.lock(); defer { lock.unlock() }
        if let existing = sessions[peerId] { return existing }
        let s = NoiseSession(role: .responder,
                             staticKey: identity.agreementKey,
                             localHint: identity.nodeHint,
                             remoteHint: remoteHint)
        sessions[peerId] = s
        return s
    }

    /// Encrypt an encoded GMP/2 frame. Nil means "cannot send yet", never
    /// "send in the clear".
    public func seal(_ peerId: UUID, _ frameBytes: Data) -> Data? {
        guard let s = established(peerId) else { return nil }
        return try? s.encrypt(frameBytes)
    }

    /// Decrypt inbound bytes. Nil on tamper, replay or no session -- the frame
    /// is dropped rather than processed.
    public func open(_ peerId: UUID, _ ciphertext: Data) -> Data? {
        guard let s = established(peerId) else { return nil }
        return try? s.decrypt(ciphertext)
    }

    public func drop(_ peerId: UUID) {
        lock.lock(); defer { lock.unlock() }
        sessions.removeValue(forKey: peerId)
    }

    public func destroyAll() {
        lock.lock(); defer { lock.unlock() }
        sessions.removeAll()
    }
}
