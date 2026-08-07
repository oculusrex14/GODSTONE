import XCTest
@testable import GodstoneMesh
import GodstoneCore

/// GMP/2.1 proof-of-work byte-parity (ADR-001 §3, Stage 3 Phase C / C4).
///
/// The canonical preimage is pinned against crypto/gmp21_vectors.json, generated
/// by the independent Python reference crypto/gmp21.py (hashlib.blake2s, RFC 7693):
///
///     BLAKE2s-256(pow_nonce[8] ‖ sender_node_id[16] ‖ created_at_le[4] ‖
///                 type_code[1] ‖ plaintext)
///
/// created_at is LITTLE-ENDIAN -- the same canonical encoding used by
/// MessageId.derive (§3.3) and the sealed payload.
///
/// DETERMINISM. Every assertion here is deterministic -- none rely on a weak
/// target coincidentally rejecting content. The KAT tests transcribe the locked
/// (sender, created_at_le, type_code, plaintext, nonce, blake2s_256) tuples and
/// assert both the digest literal AND verify(). The binding tests assert
/// `digest(field=X) != digest(field=Y)` -- BLAKE2s collision resistance makes
/// this certain, and it proves the field is part of the preimage without any
/// 1/2^target coin flip. The zero-nonce test uses the locked KAT content: the
/// Python mine search is a deterministic big-endian increment from zero, so the
/// locked 20-bit solution 0x0a40d7 PROVES nonces 0..0x0a40d6 (including zero) all
/// fail at 20 bits. The Android twin (ProofOfWorkTest.kt) transcribes the same
/// literals and is identical in structure.
final class ProofOfWorkTests: XCTestCase {

    private func data(fromHex hex: String) -> Data {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // --- locked KAT (crypto/gmp21_vectors.json pow cases) ---

    // pow_20bit_message_help: sender 00..0f, created_at_le = epoch 1, type MESSAGE,
    // plaintext "help", target 20 bits.
    private var katSender: Data { data(fromHex: "000102030405060708090a0b0c0d0e0f") }
    private var katCreatedAtLe: Data { data(fromHex: "01000000") }   // LE epoch 1
    private var katPlaintext: Data { data(fromHex: "68656c70") }     // "help"
    private var katNonce20: Data { data(fromHex: "00000000000a40d7") }
    private let katDigest20 = "00000c2aa22402bcc4040a3fb91c95e54495c18f86c4eae5c37aef702e7f8963"

    // pow_8bit_message_help: same inputs, target 8 bits.
    private var katNonce8: Data { data(fromHex: "0000000000000142") }
    private let katDigest8 = "00513306e730855b5c2547a43ea20e4172f09622841ec34806feb96d69294e61"

    // A second sender / created_at / plaintext for the binding tests.
    private var altSender: Data { data(fromHex: "0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a") }
    private var altCreatedAtLe: Data { data(fromHex: "02000000") }   // LE epoch 2
    private var altPlaintext: Data { data(fromHex: "776f726c64") }   // "world"

    func testLocked20BitKatDigestReproducesPythonReference() {
        XCTAssertEqual(
            katDigest20,
            hex(ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                                   plaintext: katPlaintext)))
    }

    func testLocked20BitKatNonceVerifiesAtProductionTarget() {
        XCTAssertTrue(
            ProofOfWork.verify(powNonce: katNonce20, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                               plaintext: katPlaintext,
                               targetBits: ProofOfWork.targetBits))
    }

    func testLocked8BitKatDigestReproducesPythonReference() {
        XCTAssertEqual(
            katDigest8,
            hex(ProofOfWork.digest(powNonce: katNonce8, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                                   plaintext: katPlaintext)))
    }

    func testLocked8BitKatNonceVerifiesAt8BitAndFailsAt20Bit() {
        XCTAssertTrue(
            ProofOfWork.verify(powNonce: katNonce8, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                               plaintext: katPlaintext, targetBits: 8))
        // The locked 8-bit digest is 00513306... -- top 8 bits zero, but bits
        // 8-19 (0x513...) are nonzero, so the 20-bit production target rejects
        // it. Deterministic: the digest literal fixes this.
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: katNonce8, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                               plaintext: katPlaintext,
                               targetBits: ProofOfWork.targetBits))
    }

    func testZeroNonceFailsAtProductionTargetForKatContent() {
        // The Python mine is a deterministic big-endian increment from zero. The
        // locked 20-bit solution is 0x00000000000a40d7, which PROVES nonces
        // 0x0 .. 0x0a40d6 (including the all-zero nonce) all fail at 20 bits for
        // this content. So verify(zeroNonce, ..., 20) is deterministically false.
        let zero = Data(count: ProofOfWork.nonceBytes)
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: zero, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                               plaintext: katPlaintext,
                               targetBits: ProofOfWork.targetBits))
    }

    // --- binding (deterministic via digest inequality; no weak-target coin flip) ---

    func testDigestBindsTypeCode() {
        let m = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                                   plaintext: katPlaintext)
        let s = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, typeCode: TypeV2.sos.rawValue,
                                   plaintext: katPlaintext)
        XCTAssertNotEqual(m, s)
    }

    func testDigestBindsPlaintext() {
        let a = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                                   plaintext: katPlaintext)
        let b = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                                   plaintext: altPlaintext)
        XCTAssertNotEqual(a, b)
    }

    func testDigestBindsSender() {
        let a = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                                   plaintext: katPlaintext)
        let b = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: altSender,
                                   createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                                   plaintext: katPlaintext)
        XCTAssertNotEqual(a, b)
    }

    func testDigestBindsCreatedAt() {
        let a = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                                   plaintext: katPlaintext)
        let b = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: altCreatedAtLe, typeCode: TypeV2.message.rawValue,
                                   plaintext: katPlaintext)
        XCTAssertNotEqual(a, b)
    }

    // --- mine/verify round-trip (deterministic: mine guarantees verify) ---

    func testMinedNonceIs8BytesAndVerifiesAtEasyTarget() async throws {
        let nonce = try await ProofOfWork.mine(senderNodeId: altSender,
                                               createdAtLe: katCreatedAtLe,
                                               typeCode: TypeV2.message.rawValue,
                                               plaintext: altPlaintext,
                                               targetBits: 8)
        XCTAssertEqual(ProofOfWork.nonceBytes, nonce.count)
        XCTAssertTrue(
            ProofOfWork.verify(powNonce: nonce, senderNodeId: altSender,
                               createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                               plaintext: altPlaintext, targetBits: 8))
    }
}