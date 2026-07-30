import Foundation
import CryptoKit

/// Noise_XX_25519_ChaChaPoly_BLAKE2s.
///
/// XX is chosen because neither side knows the other's static key in advance —
/// the whole point is meeting strangers — and because it gives mutual
/// authentication with identity hiding for the responder.
///
/// The prologue binds the handshake to the protocol name and both node hints,
/// which kills downgrade and cross-protocol attacks before they start.
public final class NoiseSession {

    public enum Role { case initiator, responder }

    private let role: Role
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey

    private var chainingKey: Data
    private var handshakeHash: Data

    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendNonce: UInt64 = 0
    private var receiveNonce: UInt64 = 0
    private var messagesSinceRekey: UInt64 = 0
    private var sessionStart = Date()

    public private(set) var remoteStaticKey: Data?
    public private(set) var isEstablished = false

    private static let protocolName = "Noise_XX_25519_ChaChaPoly_BLAKE2s"

    /// Rekey aggressively. Forward secrecy is worth the handful of CPU cycles.
    private static let rekeyMessageLimit: UInt64 = 1 << 20
    private static let rekeyTimeLimit: TimeInterval = 30 * 60

    public init(role: Role,
                staticKey: Curve25519.KeyAgreement.PrivateKey,
                localHint: Data,
                remoteHint: Data) {
        self.role = role
        self.staticKey = staticKey
        self.ephemeral = Curve25519.KeyAgreement.PrivateKey()

        var prologue = Data("GMP1".utf8)
        // Ordering is canonical: initiator hint first, both sides agree.
        if role == .initiator {
            prologue.append(localHint); prologue.append(remoteHint)
        } else {
            prologue.append(remoteHint); prologue.append(localHint)
        }

        self.chainingKey = Blake2s.hash(Data(NoiseSession.protocolName.utf8),
                                        digestLength: 32)
        self.handshakeHash = Blake2s.hash(chainingKey + prologue, digestLength: 32)
    }

    // MARK: - Handshake

    /// Message 1 (initiator): -> e
    public func writeMessage1() -> Data {
        let e = ephemeral.publicKey.rawRepresentation
        mixHash(e)
        return e
    }

    /// Message 2 (responder): <- e, ee, s, es
    public func readMessage1AndWrite2(_ msg1: Data) throws -> Data {
        guard msg1.count == 32 else { throw MeshError.handshakeFailed }
        mixHash(msg1)

        let remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: msg1)

        let e = ephemeral.publicKey.rawRepresentation
        mixHash(e)

        mixKey(try ephemeral.sharedSecretFromKeyAgreement(with: remoteEphemeral))

        let encryptedStatic = try encryptAndHash(
            staticKey.publicKey.rawRepresentation)

        mixKey(try staticKey.sharedSecretFromKeyAgreement(with: remoteEphemeral))

        return e + encryptedStatic
    }

    /// Message 3 (initiator): -> s, se  — completes mutual authentication.
    public func readMessage2AndWrite3(_ msg2: Data) throws -> Data {
        guard msg2.count > 32 else { throw MeshError.handshakeFailed }

        let remoteEphemeralRaw = msg2.prefix(32)
        mixHash(remoteEphemeralRaw)

        let remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: remoteEphemeralRaw)
        mixKey(try ephemeral.sharedSecretFromKeyAgreement(with: remoteEphemeral))

        let remoteStatic = try decryptAndHash(msg2.suffix(from: 32))
        self.remoteStaticKey = remoteStatic

        let remoteStaticPub = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: remoteStatic)
        mixKey(try ephemeral.sharedSecretFromKeyAgreement(with: remoteStaticPub))

        let encryptedStatic = try encryptAndHash(
            staticKey.publicKey.rawRepresentation)
        mixKey(try staticKey.sharedSecretFromKeyAgreement(with: remoteEphemeral))

        splitKeys()
        return encryptedStatic
    }

    public func readMessage3(_ msg3: Data) throws {
        let remoteStatic = try decryptAndHash(msg3)
        self.remoteStaticKey = remoteStatic

        let remoteStaticPub = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: remoteStatic)
        mixKey(try ephemeral.sharedSecretFromKeyAgreement(with: remoteStaticPub))

        splitKeys()
    }

    // MARK: - Transport

    public func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = sendKey else { throw MeshError.handshakeFailed }
        rekeyIfNeeded()

        let nonce = try ChaChaPoly.Nonce(data: Data(count: 4) + sendNonce.bigEndianBytes)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce)
        sendNonce += 1
        messagesSinceRekey += 1
        return box.ciphertext + box.tag
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = receiveKey, ciphertext.count > 16 else {
            throw MeshError.handshakeFailed
        }
        let nonce = try ChaChaPoly.Nonce(
            data: Data(count: 4) + receiveNonce.bigEndianBytes)
        let box = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16))
        let plain = try ChaChaPoly.open(box, using: key)
        receiveNonce += 1
        return plain
    }

    // MARK: - Symmetric state

    private func mixHash(_ data: Data) {
        handshakeHash = Blake2s.hash(handshakeHash + data, digestLength: 32)
    }

    private func mixKey(_ secret: SharedSecret) {
        let material = secret.withUnsafeBytes { Data($0) }
        let (ck, k) = Hkdf.split(chainingKey: chainingKey, material: material)
        chainingKey = ck
        sendKey = SymmetricKey(data: k)
    }

    private func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let key = sendKey else {
            mixHash(plaintext)
            return plaintext
        }
        let nonce = try ChaChaPoly.Nonce(data: Data(count: 12))
        let box = try ChaChaPoly.seal(plaintext, using: key,
                                      nonce: nonce,
                                      authenticating: handshakeHash)
        let out = box.ciphertext + box.tag
        mixHash(out)
        return out
    }

    private func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let key = sendKey else {
            mixHash(ciphertext)
            return ciphertext
        }
        let saved = handshakeHash
        let box = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: Data(count: 12)),
            ciphertext: ciphertext.dropLast(16),
            tag: ciphertext.suffix(16))
        let plain = try ChaChaPoly.open(box, using: key, authenticating: saved)
        mixHash(Data(ciphertext))
        return plain
    }

    private func splitKeys() {
        let (k1, k2) = Hkdf.split(chainingKey: chainingKey, material: Data())
        // Initiator sends with k1, responder sends with k2. Never the same key
        // in both directions: that would make nonce reuse trivially fatal.
        sendKey    = SymmetricKey(data: role == .initiator ? k1 : k2)
        receiveKey = SymmetricKey(data: role == .initiator ? k2 : k1)
        sendNonce = 0
        receiveNonce = 0
        messagesSinceRekey = 0
        sessionStart = Date()
        isEstablished = true
    }

    private func rekeyIfNeeded() {
        let expired = Date().timeIntervalSince(sessionStart)
            > NoiseSession.rekeyTimeLimit
        guard messagesSinceRekey >= NoiseSession.rekeyMessageLimit || expired else {
            return
        }
        if let k = sendKey {
            sendKey = SymmetricKey(data: Blake2s.hash(
                k.withUnsafeBytes { Data($0) }, digestLength: 32))
        }
        if let k = receiveKey {
            receiveKey = SymmetricKey(data: Blake2s.hash(
                k.withUnsafeBytes { Data($0) }, digestLength: 32))
        }
        sendNonce = 0
        receiveNonce = 0
        messagesSinceRekey = 0
        sessionStart = Date()
    }
}

extension UInt64 {
    var bigEndianBytes: Data {
        var v = self.bigEndian
        return Data(bytes: &v, count: 8)
    }
}
