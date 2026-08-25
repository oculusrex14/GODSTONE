import Foundation
import CryptoKit
import GodstoneCore

internal enum HandshakeTrustState: Equatable, Sendable {
    case initial
    case handshakeInProgress
    case noiseEstablished
    case ready
    case quarantined
    case securityReject
    case corrupt
    case storageFailure
}

internal protocol PeerBindingTrustAuthority: Sendable {
    func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult
}

internal final class RepositoryPeerBindingTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
    private let repository: PeerIdentityRepository

    init(repository: PeerIdentityRepository) {
        self.repository = repository
    }

    func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
        repository.applyValidatedBinding(binding)
    }
}

internal final class TrustedHandshakeController: @unchecked Sendable {
    let noiseSession: NoiseSession
    let trustAuthority: any PeerBindingTrustAuthority
    let localIdentity: MeshIdentity

    private(set) var state: HandshakeTrustState = .initial

    var isReady: Bool { state == .ready }

    var authenticatedRemoteStaticKey: Data? {
        noiseSession.remoteStaticKey
    }

    init(
        noiseSession: NoiseSession,
        trustAuthority: any PeerBindingTrustAuthority,
        localIdentity: MeshIdentity
    ) {
        self.noiseSession = noiseSession
        self.trustAuthority = trustAuthority
        self.localIdentity = localIdentity
    }

    /// Initiator step 1: write HS1 (32 bytes).
    func initiatorWriteMessage1() throws -> Data {
        guard state == .initial else {
            throw MeshError.handshakeFailed
        }
        let hs1 = try noiseSession.writeMessage1(payload: Data())
        guard hs1.count == 32 else {
            throw MeshError.handshakeFailed
        }
        state = .handshakeInProgress
        return hs1
    }

    /// Initiator step 2: read HS2 (229 bytes), validate responder binding, apply to trust authority,
    /// and only on Accepted / FirstSeenPinned write HS3 (197 bytes) and advance to READY.
    /// Returns HS3 bytes on success, or nil on rejection / quarantine / error.
    func initiatorProcessMessage2(hs2: Data, advertisedRemoteHint: Data) -> Data? {
        guard state == .handshakeInProgress else { return nil }

        let readResult: HandshakeReadResult
        do {
            readResult = try noiseSession.readMessage2(hs2)
        } catch {
            state = .securityReject
            return nil
        }

        guard let remoteStatic = readResult.authenticatedRemoteStaticKey, remoteStatic.count == 32 else {
            state = .securityReject
            return nil
        }

        let validation = IdentityBindingValidator.validate(
            serialized: readResult.payload,
            authenticatedRemoteStaticKey: remoteStatic,
            advertisedNodeHint: advertisedRemoteHint
        )

        guard case .valid(let binding) = validation else {
            state = .securityReject
            return nil
        }

        let applyResult = trustAuthority.applyValidatedBinding(binding)
        switch applyResult {
        case .accepted, .firstSeenPinned:
            do {
                let localBinding = try localIdentity.issueIdentityBinding()
                let localBytes = localBinding.encode()
                guard localBytes.count == 133 else { return nil }
                let hs3 = try noiseSession.writeMessage3(payload: localBytes)
                guard hs3.count == 197 else { return nil }
                state = .ready
                return hs3
            } catch {
                state = .securityReject
                return nil
            }
        case .keyChangedQuarantined:
            state = .quarantined
            return nil
        case .rejected:
            state = .securityReject
            return nil
        case .corrupt:
            state = .corrupt
            return nil
        case .storageFailure:
            state = .storageFailure
            return nil
        }
    }

    /// Responder step 1: read HS1 (32 bytes with empty payload), issue local binding, write HS2 (229 bytes).
    /// Returns HS2 bytes on success, or nil on rejection.
    func responderProcessMessage1AndWriteMessage2(hs1: Data) -> Data? {
        guard state == .initial else { return nil }

        let readResult: HandshakeReadResult
        do {
            readResult = try noiseSession.readMessage1(hs1)
        } catch {
            state = .securityReject
            return nil
        }

        guard readResult.payload.isEmpty else {
            state = .securityReject
            return nil
        }

        do {
            let localBinding = try localIdentity.issueIdentityBinding()
            let localBytes = localBinding.encode()
            guard localBytes.count == 133 else { return nil }
            let hs2 = try noiseSession.writeMessage2(payload: localBytes)
            guard hs2.count == 229 else { return nil }
            state = .handshakeInProgress
            return hs2
        } catch {
            state = .securityReject
            return nil
        }
    }

    /// Responder step 2: read HS3 (197 bytes), validate initiator binding, apply to trust authority,
    /// and only on Accepted / FirstSeenPinned advance to READY.
    /// Returns true on success (READY), false on rejection / quarantine / error.
    func responderProcessMessage3(hs3: Data, advertisedRemoteHint: Data) -> Bool {
        guard state == .handshakeInProgress else { return false }

        let readResult: HandshakeReadResult
        do {
            readResult = try noiseSession.readMessage3(hs3)
        } catch {
            state = .securityReject
            return false
        }

        guard let remoteStatic = readResult.authenticatedRemoteStaticKey, remoteStatic.count == 32 else {
            state = .securityReject
            return false
        }

        let validation = IdentityBindingValidator.validate(
            serialized: readResult.payload,
            authenticatedRemoteStaticKey: remoteStatic,
            advertisedNodeHint: advertisedRemoteHint
        )

        guard case .valid(let binding) = validation else {
            state = .securityReject
            return false
        }

        let applyResult = trustAuthority.applyValidatedBinding(binding)
        switch applyResult {
        case .accepted, .firstSeenPinned:
            state = .ready
            return true
        case .keyChangedQuarantined:
            state = .quarantined
            return false
        case .rejected:
            state = .securityReject
            return false
        case .corrupt:
            state = .corrupt
            return false
        case .storageFailure:
            state = .storageFailure
            return false
        }
    }

    /// Application seal: encrypts plaintext only if state == READY.
    func seal(_ plaintext: Data) -> Data? {
        guard state == .ready else { return nil }
        return try? noiseSession.encrypt(plaintext)
    }

    /// Application open: decrypts ciphertext only if state == READY.
    func open(_ ciphertext: Data) -> Data? {
        guard state == .ready else { return nil }
        return try? noiseSession.decrypt(ciphertext)
    }

    static func initiator(
        identity: MeshIdentity,
        remoteHint: Data,
        trustAuthority: any PeerBindingTrustAuthority
    ) -> TrustedHandshakeController {
        let session = NoiseSession(
            role: .initiator,
            staticKey: identity.agreementKey,
            localHint: identity.nodeHint,
            remoteHint: remoteHint
        )
        return TrustedHandshakeController(
            noiseSession: session,
            trustAuthority: trustAuthority,
            localIdentity: identity
        )
    }

    static func responder(
        identity: MeshIdentity,
        remoteHint: Data,
        trustAuthority: any PeerBindingTrustAuthority
    ) -> TrustedHandshakeController {
        let session = NoiseSession(
            role: .responder,
            staticKey: identity.agreementKey,
            localHint: identity.nodeHint,
            remoteHint: remoteHint
        )
        return TrustedHandshakeController(
            noiseSession: session,
            trustAuthority: trustAuthority,
            localIdentity: identity
        )
    }
}
