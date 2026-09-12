import XCTest
@testable import GodstoneMesh
import GodstoneCore
import CryptoKit

/// T35 readiness court (iOS isle) -- the twin of ReadinessT35Test.kt. SignedMessageV1
/// authorship binding inside the sealed envelope, exactly as section 15. The frozen
/// outer frame, the 29-byte sealed prefix, the MessageId formula, the PoW/priority
/// policy and every golden vector are read-only authorities exercised here, never
/// rewritten. The same pinned cross-platform vector was produced and verified by the
/// foreign raw signer (openssl pkeyutl -rawin); this isle must reproduce and
/// authenticate it byte for byte through CryptoKit Curve25519.
final class ReadinessT35Tests: XCTestCase {

    // ---- pinned cross-platform vector constants (foreign-signer produced) ----------------
    fileprivate static let PRV = hexD("d09deef5f114172233445566778899aabbccddeeff00112233445566778899aa")
    fileprivate static let PUB = hexD("a720fa37a67ee233c29f4c7473852e73e4bd2e90dcf4abbc288b0d7a6b3935dc")
    fileprivate static let NOD = hexD("d285a925802330c7d66708b19856a38d")
    fileprivate static let RCP = hexD("72656369702d6e6f6465212100000000")          // "recip-node!!"
    fileprivate static let NON = hexD("6d6573736167652d6e6f6e6365210000")          // "message-nonce!"
    fileprivate static let CREAT: Int64 = 1700000000
    fileprivate static let BOD = Data("SignedMessageV1 cross-platform pinned vector!!".utf8)
    fileprivate static let SPD = hexD("01"
        + "a720fa37a67ee233c29f4c7473852e73e4bd2e90dcf4abbc288b0d7a6b3935dc"
        + "72656369702d6e6f6465212100000000" + "01" + "002e"
        + "5369676e65644d65737361676556312063726f73732d706c6174666f726d2070696e6e656420766563746f722121"
        + "172ba189d6c1bd8f7b50e0ce045212ad32afc65e243ed1acd95a8e7328a0b1bf5003a2e65b711464338309ac3fc74df845901ba6680564d9904f2336097d420e")
    fileprivate static let MID = hexD("3ec672aca155b2678c7533b46d944156")
    /// An iOS-AUTHORED frame (Curve25519 native signer, randomized per RFC 8032 section 9.1 --
    /// the bytes are therefore PINNED once here rather than re-derived per run), captured from a
    /// real run of this court and authenticated by the JVM isle's verifier in ReadinessT35Test.kt.
    fileprivate static let SPD2 = hexD("01a720fa37a67ee233c29f4c7473852e73e4bd2e90dcf4abbc288b0d7a6b3935dc72656369702d6e6f646521210000000001002e5369676e65644d65737361676556312063726f73732d706c6174666f726d2070696e6e656420766563746f72212105743cc3b6833727a6a83f93adaba49257a2b81f37e4e915ce8762743075238c0db142eedcdcf8663cfa33cc15055a567638bb7b12779505576b078492833400")

    fileprivate static func hexD(_ s: String) -> Data {
        var bytes: [UInt8] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let b = UInt8(String(s[idx..<next]), radix: 16) else { break }
            bytes.append(b); idx = next
        }
        return Data(bytes)
    }
    private func le32(_ d: Data) -> Int64 {
        let b = [UInt8](d)
        return Int64(b[0]) | (Int64(b[1]) << 8) | (Int64(b[2]) << 16) | (Int64(b[3]) << 24)
    }
    /// sealed_inner = messageNonce16 || powNonce8 || createdAt_le4 || priorityCode1 || signedPlaintext
    private func sealInner(_ nonce: Data, _ pow: Data, _ created: Int64, _ prio: Int, _ sp: Data) -> Data {
        nonce + pow + MessageId.uint32Le(created) + Data([UInt8(prio & 0xFF)]) + sp
    }
    private func unseal(_ inner: Data) -> (nonce: Data, created: Int64, prio: Int) {
        let b = [UInt8](inner)
        return (Data(b[0..<16]), le32(Data(b[24..<28])), Int(b[28]))
    }
    private func tamper(_ d: Data, _ i: Int, _ mask: UInt8 = 0x01) -> Data {
        var b = [UInt8](d); b[i] ^= mask; return Data(b)
    }
    private func honestSign(_ priv: Data, _ pub: Data, _ node: Data, _ recip: Data,
                            _ nonce: Data, _ created: Int64, _ body: Data) throws -> Data {
        try SignedMessageV1.author(senderIdentityPriv: priv, senderIdentityPub: pub, senderNodeId: node,
                                   recipientNodeId: recip, messageNonce: nonce, createdAtEpochSeconds: created,
                                   priority: .direct, timeQuality: .userConfirmed, bodyUtf8: body)
    }
    private func newPair() throws -> (priv: Data, pub: Data) {
        let k = Curve25519.Signing.PrivateKey()
        return (k.rawRepresentation, k.publicKey.rawRepresentation)
    }

    // -- verdict helpers ---------------------------------------------------------------------
    private func isVerified(_ r: SenderVerificationResult) -> Bool { if case .verified = r { return true }; return false }
    private func invalidReason(_ r: SenderVerificationResult) -> String? {
        if case let .invalid(reason) = r { return reason }
        return nil
    }

    // (1) known-recipient-key impersonation: possession identifies a key, not a person
    func testKnownRecipientKeyImpersonationIsRejected() throws {
        let victim = try newPair(); let victimNode = SignedMessageV1.nodeIdOf(victim.pub)
        let carol = try newPair()
        // Carol knows the victim's public key and node id (both public); she authors with HER OWN
        // key yet claims the victim's node id -- the id/key binding must catch the impersonation.
        let forged = try SignedMessageV1.author(senderIdentityPriv: carol.priv, senderIdentityPub: carol.pub,
            senderNodeId: victimNode, recipientNodeId: Self.RCP, messageNonce: Self.NON,
            createdAtEpochSeconds: Self.CREAT, priority: .direct, timeQuality: .userConfirmed, bodyUtf8: Self.BOD)
        let r = SignedMessageV1.verify(signedPlaintext: forged, senderNodeId: victimNode, recipientLocalNodeId: Self.RCP,
                                       messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)
        let reason = invalidReason(r)
        XCTAssertNotNil(reason, "a stranger cannot sign as the victim: the id/key binding rejects it")
        XCTAssertTrue(reason!.contains("BLAKE2s128"), "the rejection names the id/key binding")
        // an honest message under the victim's own key verifies -- the rejection is not blanket
        let honest = try honestSign(victim.priv, victim.pub, victimNode, Self.RCP, Self.NON, Self.CREAT, Self.BOD)
        XCTAssertTrue(isVerified(SignedMessageV1.verify(signedPlaintext: honest, senderNodeId: victimNode, recipientLocalNodeId: Self.RCP,
                                                        messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)),
                      "the genuine author still verifies")
        // tampering the embedded public key breaks the binding (checked before the signature)
        let r2 = SignedMessageV1.verify(signedPlaintext: tamper(honest, 1), senderNodeId: victimNode, recipientLocalNodeId: Self.RCP,
                                        messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)
        XCTAssertNotNil(invalidReason(r2), "a modified embedded key is Invalid")
    }

    // (2) valid signature, wrong recipient: rejected BEFORE inbox/ACK admission (side effect absent)
    func testValidSignatureWrongRecipientRejectedBeforeInbox() throws {
        let alice = try newPair(); let aliceNode = SignedMessageV1.nodeIdOf(alice.pub)
        let bobNode = SignedMessageV1.nodeIdOf(try newPair().pub)       // the intended local recipient
        let malloryNode = SignedMessageV1.nodeIdOf(try newPair().pub)   // some other node
        let sp = try honestSign(alice.priv, alice.pub, aliceNode, bobNode, Self.NON, Self.CREAT, Self.BOD)
        var inbox: [VerifiedApplicationMessage] = []
        var acks: [Data] = []
        func admit(_ r: SenderVerificationResult) { if case let .verified(m) = r { inbox.append(m); acks.append(m.msgId) } }
        // a delivery attempt at the WRONG local endpoint: the signature is valid over the claimed
        // fields, yet the embedded recipient differs from the intended local recipient -> refuse
        admit(SignedMessageV1.verify(signedPlaintext: sp, senderNodeId: aliceNode, recipientLocalNodeId: malloryNode,
                                     messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue))
        XCTAssertEqual(inbox.count, 0, "the wrong-recipient frame reached no inbox")
        XCTAssertEqual(acks.count, 0, "and it reached no ACK log")
        admit(SignedMessageV1.verify(signedPlaintext: sp, senderNodeId: aliceNode, recipientLocalNodeId: bobNode,
                                     messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue))
        XCTAssertEqual(inbox.count, 1, "the right-recipient frame is admitted exactly once")
        XCTAssertEqual(acks.count, 1, "with exactly one ACK")
    }

    // (3) modified priority / time / body each break the signature; untouched authenticates
    func testModifiedPriorityTimeOrBodyBreaksTheSignature() throws {
        let alice = try newPair(); let aliceNode = SignedMessageV1.nodeIdOf(alice.pub)
        let sp = try honestSign(alice.priv, alice.pub, aliceNode, Self.RCP, Self.NON, Self.CREAT, Self.BOD)
        let pow = Data((0..<8).map { UInt8($0 &* 7 &+ 3) })
        let u = unseal(sealInner(Self.NON, pow, Self.CREAT, Priority.direct.rawValue, sp))
        XCTAssertTrue(isVerified(SignedMessageV1.verify(signedPlaintext: sp, senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
                                                        messageNonce: u.nonce, createdAtEpochSeconds: u.created, priorityCode: u.prio)),
                      "the untouched sealed frame authenticates")
        let rp = SignedMessageV1.verify(signedPlaintext: sp, senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
                                        messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.bulk.rawValue)
        let rps = invalidReason(rp)
        XCTAssertNotNil(rps, "a relay cannot rewrite the sealed priority byte: the signature covers it")
        XCTAssertTrue(rps!.contains("signature"), "the failure is the signature, named as such")
        XCTAssertNotNil(invalidReason(SignedMessageV1.verify(signedPlaintext: sp, senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
            messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT &+ 1, priorityCode: Priority.direct.rawValue)),
            "a shifted creation time breaks the signature")
        XCTAssertNotNil(invalidReason(SignedMessageV1.verify(signedPlaintext: tamper(sp, 55), senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
            messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)),
            "one modified body byte breaks the signature")
        XCTAssertNotNil(invalidReason(SignedMessageV1.verify(signedPlaintext: tamper(sp, sp.count &- 1), senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
            messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)),
            "one modified signature byte breaks the signature")
    }

    // (4) malformed length / UTF-8 / version: fail closed, never throw out of the receiver loop
    func testMalformedLengthAndUtf8RejectedFailClosed() throws {
        let alice = try newPair(); let aliceNode = SignedMessageV1.nodeIdOf(alice.pub)
        let sp = try honestSign(alice.priv, alice.pub, aliceNode, Self.RCP, Self.NON, Self.CREAT, Self.BOD)
        let a = [UInt8](sp)
        let cases: [(String, Data)] = [
            ("truncated tail", Data(a.dropLast())),
            ("shorter than the fixed layout", Data(a.prefix(40))),
            ("lied bodyLength", { var b = a; b[51] = b[51] &+ 1; return Data(b) }()),
            ("unknown version", { var b = a; b[0] = 0x02; return Data(b) }()),
            ("lone continuation byte", { var b = a; b[52] = 0x80; return Data(b) }()),
            ("overlong form", { var b = a; b[52] = 0xC0; b[53] = 0x80; return Data(b) }()),
            ("surrogate", { var b = a; b[52] = 0xED; b[53] = 0xA0; b[54] = 0x80; return Data(b) }()),
            ("beyond the plane", { var b = a; b[52] = 0xF5; return Data(b) }()),
        ]
        for (name, bad) in cases {
            let r = SignedMessageV1.verify(signedPlaintext: bad, senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
                                           messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)
            let reason = invalidReason(r)
            XCTAssertNotNil(reason, "\(name) is Invalid")
            XCTAssertFalse(reason!.isEmpty, "\(name) carries a non-empty reason")
        }
        // attacker-SELF-SIGNED hostile frames: the intruder holds a key pair and signs the EXACT hostile
        // bytes, so the Ed25519 check VALIDATES over them; only the receiving structural gates (version,
        // UTF-8, exact length) can refuse. Without these cases the gates are defense-in-depth shadowed by
        // the signature and a mutant that removes one would escape every tamper-of-honest-frame probe.
        let carol = try newPair(); let carolNode = SignedMessageV1.nodeIdOf(carol.pub)
        func attackerSigned(_ unsigned: Data) throws -> Data {
            let pre = try SignedMessageV1.signaturePreimage(senderNodeId: carolNode, recipientNodeId: Self.RCP,
                messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue, unsigned: unsigned)
            let sig = try Curve25519.Signing.PrivateKey(rawRepresentation: carol.priv).signature(for: pre)
            return unsigned + sig
        }
        let baseU = try SignedMessageV1.buildUnsigned(senderIdentityPub: carol.pub, recipientNodeId: Self.RCP,
                                                      timeQuality: .userConfirmed, bodyUtf8: Self.BOD)
        var vB = [UInt8](baseU); vB[0] = 0x02
        var uB = [UInt8](baseU); uB[52] = 0x80
        var lB = [UInt8](baseU); lB[51] = lB[51] &+ 1
        let hostiles: [(String, Data, String)] = [
            ("attacker-signed unknown version", try attackerSigned(Data(vB)), "version"),
            ("attacker-signed malformed body", try attackerSigned(Data(uB)), "UTF-8"),
            ("attacker-signed lied length", try attackerSigned(Data(lB)), "exact"),
        ]
        for (name, frame, marker) in hostiles {
            let r = SignedMessageV1.verify(signedPlaintext: frame, senderNodeId: carolNode, recipientLocalNodeId: Self.RCP,
                                          messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)
            let reason = invalidReason(r)
            XCTAssertNotNil(reason, "\(name) must be Invalid -- the signature validates over these exact bytes; only the receiving gate stands")
            XCTAssertTrue(reason!.contains(marker), "\(name) refused by the \(marker) gate")
        }
    }

    // (5) low-order / non-canonical sealed DH inputs are refused by the input filter
    func testLowOrderDhInputsAreRejected() throws {
        // the filter guards the X25519 u-coordinate inputs of the sealed agreement (the 29-byte
        // prefix layer), NOT the Ed25519 identity keys (whose top bit is a legitimate sign bit)
        let zero = Data(repeating: 0, count: 32)
        XCTAssertFalse(SignedMessageV1.acceptableSealedDhPublicKey(zero), "the all-zero (identity) public value is low order: refuse")
        var p = [UInt8](repeating: 0xFF, count: 32); p[0] = 0xED; p[31] = 0x7F
        XCTAssertFalse(SignedMessageV1.acceptableSealedDhPublicKey(Data(p)), "u == p is a non-canonical encoding: refuse")
        var above = [UInt8](repeating: 0xFF, count: 32); above[0] = 0xEE; above[31] = 0x7F
        XCTAssertFalse(SignedMessageV1.acceptableSealedDhPublicKey(Data(above)), "u > p is a non-canonical encoding: refuse")
        let privSeed = Data((0..<32).map { UInt8(($0 &* 13 &+ 7) & 0x7F) })
        let real = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privSeed).publicKey.rawRepresentation
        XCTAssertTrue(SignedMessageV1.acceptableSealedDhPublicKey(real), "a canonical generated public value is accepted")
        var masked = [UInt8](real); masked[31] |= 0x80
        XCTAssertFalse(SignedMessageV1.acceptableSealedDhPublicKey(Data(masked)), "the sign/masking bit must be clear in a canonical u encoding: refuse")
        XCTAssertFalse(SignedMessageV1.acceptableSealedDhPublicKey(real.prefix(31)), "a 31-byte short value is refused")
    }

    // (6) cross-platform pinned bytes and signature vectors: layout parity is byte-for-byte
    // deterministic on both isles; AUTHENTICATION parity is bidirectional over pinned vectors
    // (the JVM/openssl-signed frame authenticates here, the iOS-authored frame authenticates on
    // the JVM -- see ReadinessT35Test.kt W6b). The native Curve25519 signer is randomized per
    // RFC 8032 section 9.1, so signing determinism is NOT claimed across isles; fresh frames
    // must merely authenticate, which is the security property the card names.
    func testCrossPlatformBytesAndSignatureVectors() throws {
        XCTAssertEqual(SignedMessageV1.nodeIdOf(Self.PUB), Self.NOD, "BLAKE2s-128 identity binding is byte-for-byte across isles")
        let unsigned = try SignedMessageV1.buildUnsigned(senderIdentityPub: Self.PUB, recipientNodeId: Self.RCP,
                                                         timeQuality: .userConfirmed, bodyUtf8: Self.BOD)
        XCTAssertEqual(unsigned, Self.SPD.prefix(98), "the canonical unsigned layout (version..body) is byte-for-byte across isles")
        let r = SignedMessageV1.verify(signedPlaintext: Self.SPD, senderNodeId: Self.NOD, recipientLocalNodeId: Self.RCP,
                                       messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)
        XCTAssertTrue(isVerified(r), "the foreign (JVM/openssl)-signed vector authenticates on this isle")
        if case let .verified(m) = r {
            XCTAssertEqual(m.msgId, Self.MID, "msgID matches the independently computed pinned vector")
            XCTAssertEqual(m.msgId, MessageId.derive(senderNodeId: Self.NOD, createdAtEpochSeconds: Self.CREAT, messageNonce: Self.NON, plaintext: Self.SPD),
                           "msgID equals the frozen MessageId.derive over the signed plaintext")
        }
        let r2 = SignedMessageV1.verify(signedPlaintext: Self.SPD2, senderNodeId: Self.NOD, recipientLocalNodeId: Self.RCP,
                                        messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)
        XCTAssertTrue(isVerified(r2), "the iOS-authored pinned frame re-authenticates deterministically on its home isle")
        XCTAssertEqual(Self.SPD2.count, 162, "the iOS-authored frame has the exact 162-byte layout")
        XCTAssertEqual(Self.SPD2.prefix(98), Self.SPD.prefix(98), "only the signature region differs between the two isles signed frames")
        if case let .verified(m2) = r2 {
            // msgID hashes the WHOLE signed plaintext, signature bytes included (section 15: "msgID uses
            // signedPlaintext exactly"). A randomized-signer frame therefore carries its OWN msgID --
            // the law that holds is self-consistency of the frozen derivation over its own bytes.
            XCTAssertEqual(m2.msgId, MessageId.derive(senderNodeId: Self.NOD, createdAtEpochSeconds: Self.CREAT, messageNonce: Self.NON, plaintext: Self.SPD2),
                           "its msgID is the frozen derivation over its own signed plaintext")
            XCTAssertNotEqual(m2.msgId, Self.MID, "and it differs from the JVM-signed vector's msgID as the formula demands")
        }
        let fresh = try SignedMessageV1.author(senderIdentityPriv: Self.PRV, senderIdentityPub: Self.PUB, senderNodeId: Self.NOD,
            recipientNodeId: Self.RCP, messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT,
            priority: .direct, timeQuality: .userConfirmed, bodyUtf8: Self.BOD)
        XCTAssertEqual(fresh.count, 162, "author produces the exact 162-byte layout")
        let r3 = SignedMessageV1.verify(signedPlaintext: fresh, senderNodeId: Self.NOD, recipientLocalNodeId: Self.RCP,
                                        messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)
        XCTAssertTrue(isVerified(r3), "a freshly authored frame authenticates under its key (randomized signer: bytes need not repeat)")
        XCTAssertNotNil(invalidReason(SignedMessageV1.verify(signedPlaintext: tamper(Self.SPD2, 98), senderNodeId: Self.NOD, recipientLocalNodeId: Self.RCP,
            messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)),
            "one flipped signature byte is rejected")
        XCTAssertEqual([UInt8](Self.SPD)[0], 0x01, "and the version byte is 0x01")
    }

    // (7) msgID binds the signed plaintext; the PoW nonce stays outside (no circular inclusion)
    func testMsgIdBoundWithoutCircularInclusion() throws {
        let alice = try newPair(); let aliceNode = SignedMessageV1.nodeIdOf(alice.pub)
        let sp = try honestSign(alice.priv, alice.pub, aliceNode, Self.RCP, Self.NON, Self.CREAT, Self.BOD)
        let pow = Data((0..<8).map { UInt8($0 &* 3 &+ 1) })
        let u = unseal(sealInner(Self.NON, pow, Self.CREAT, Priority.direct.rawValue, sp))
        let r = SignedMessageV1.verify(signedPlaintext: sp, senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
                                       messageNonce: u.nonce, createdAtEpochSeconds: u.created, priorityCode: u.prio)
        XCTAssertTrue(isVerified(r), "the sealed frame authenticates")
        var msgIdA: Data = Data()
        if case let .verified(m) = r {
            XCTAssertEqual(m.msgId, MessageId.derive(senderNodeId: aliceNode, createdAtEpochSeconds: Self.CREAT, messageNonce: Self.NON, plaintext: sp),
                           "msgID is the frozen derivation over the signed plaintext")
            msgIdA = m.msgId
        }
        // the PoW nonce is NOT in the signature preimage: rewriting it leaves authorship valid
        let pow2 = Data((0..<8).map { UInt8($0 &* 3 &+ 2) })
        let u2 = unseal(sealInner(Self.NON, pow2, Self.CREAT, Priority.direct.rawValue, sp))
        let r2 = SignedMessageV1.verify(signedPlaintext: sp, senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
                                        messageNonce: u2.nonce, createdAtEpochSeconds: u2.created, priorityCode: u2.prio)
        XCTAssertTrue(isVerified(r2), "a different PoW nonce still authenticates (signature excludes it: no circular search dependence)")
        if case let .verified(m2) = r2 { XCTAssertEqual(m2.msgId, msgIdA, "and the authorship binding is unchanged") }
        // while msgID is bound to every signed byte: flipping one body bit changes the derived msgID
        XCTAssertFalse(MessageId.derive(senderNodeId: aliceNode, createdAtEpochSeconds: Self.CREAT, messageNonce: Self.NON, plaintext: tamper(sp, 55)) == msgIdA,
                       "a flipped signed byte changes the derived msgID")
    }

    // (8) unknown-time rule and the time-quality binding; no new header flag exists
    func testUnknownTimeRuleAndTimeQualityBinding() throws {
        let alice = try newPair(); let aliceNode = SignedMessageV1.nodeIdOf(alice.pub)
        // unknown time: createdAt 0 with timeQuality 0 stand together
        let sp0 = try SignedMessageV1.author(senderIdentityPriv: alice.priv, senderIdentityPub: alice.pub,
            senderNodeId: aliceNode, recipientNodeId: Self.RCP, messageNonce: Self.NON, createdAtEpochSeconds: 0,
            priority: .direct, timeQuality: .unknown, bodyUtf8: Self.BOD)
        let r0 = SignedMessageV1.verify(signedPlaintext: sp0, senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
                                        messageNonce: Self.NON, createdAtEpochSeconds: 0, priorityCode: Priority.direct.rawValue)
        XCTAssertTrue(isVerified(r0), "zero time with UNKNOWN quality authenticates")
        if case let .verified(m) = r0 { XCTAssertEqual(m.timeQuality, TimeQuality.unknown, "and carries TimeQuality.unknown") }
        // tampering the timeQuality byte (0 -> 1) while claiming nonzero time breaks the signature
        let tqBad = tamper(sp0, 49, 0x01)
        XCTAssertNotNil(invalidReason(SignedMessageV1.verify(signedPlaintext: tqBad, senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
            messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)),
            "a re-stamped quality byte cannot survive: the signature covered the binding")
        XCTAssertNotNil(invalidReason(SignedMessageV1.verify(signedPlaintext: tqBad, senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
            messageNonce: Self.NON, createdAtEpochSeconds: 0, priorityCode: Priority.direct.rawValue)),
            "even at zero time the re-stamped frame fails (byte 49 no longer 0)")
        // an out-of-range timeQuality code cannot be forged past the verifier
        var oor = [UInt8](sp0); oor[49] = 3
        XCTAssertNotNil(invalidReason(SignedMessageV1.verify(signedPlaintext: Data(oor), senderNodeId: aliceNode, recipientLocalNodeId: Self.RCP,
            messageNonce: Self.NON, createdAtEpochSeconds: 0, priorityCode: Priority.direct.rawValue)),
            "timeQuality 3 is Invalid")
        // authoring refuses a mismatched binding up front
        XCTAssertThrowsError(try SignedMessageV1.author(senderIdentityPriv: alice.priv, senderIdentityPub: alice.pub,
            senderNodeId: aliceNode, recipientNodeId: Self.RCP, messageNonce: Self.NON, createdAtEpochSeconds: 0,
            priority: .direct, timeQuality: .userConfirmed, bodyUtf8: Self.BOD),
            "author() binds createdAt 0 with UNKNOWN only")
        // the layout has no field where a new timestamp/header flag could stand
        XCTAssertEqual(sp0.count, 162, "the signed plaintext is exactly 1+32+16+1+2+46+64 bytes -- no room for an extra flag")
    }

    // (9) structural zero-signature fixtures stay structural; runtime authentication rejects them
    func testStructuralZeroSignatureSosFixtureRejectedAtRuntime() throws {
        // the existing structural golden SOS fixtures deliberately carry ZERO signatures: they are
        // STRUCTURAL. A frame with a 64-byte zero signature must NOT pass runtime authentication
        // (a structural codec test is not a signature-validity test), while the signed-DIRECT
        // family keeps its separate authenticated path.
        let unsigned = try SignedMessageV1.buildUnsigned(senderIdentityPub: Self.PUB, recipientNodeId: Self.RCP,
            timeQuality: .authenticatedSource, bodyUtf8: Self.BOD)
        XCTAssertEqual(unsigned.count, 98, "the unsigned part is exactly 1+32+16+1+2+46 bytes")
        let zeroSig = unsigned + Data(repeating: 0, count: 64)
        XCTAssertNotNil(invalidReason(SignedMessageV1.verify(signedPlaintext: zeroSig, senderNodeId: Self.NOD, recipientLocalNodeId: Self.RCP,
            messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)),
            "a zero signature is rejected by the verifier")
        let genuine = SignedMessageV1.verify(signedPlaintext: Self.SPD, senderNodeId: Self.NOD, recipientLocalNodeId: Self.RCP,
                                              messageNonce: Self.NON, createdAtEpochSeconds: Self.CREAT, priorityCode: Priority.direct.rawValue)
        XCTAssertTrue(isVerified(genuine), "the signed-DIRECT family still authenticates")
        if case let .verified(m) = genuine {
            XCTAssertFalse(MessageId.derive(senderNodeId: Self.NOD, createdAtEpochSeconds: Self.CREAT, messageNonce: Self.NON, plaintext: zeroSig) == m.msgId,
                           "and its msgID differs from any structural (zero-signature) msgId")
        }
    }
}
