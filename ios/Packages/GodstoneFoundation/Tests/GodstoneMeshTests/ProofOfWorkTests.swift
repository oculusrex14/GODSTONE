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
/// The KAT tests below transcribe the locked (sender, created_at_le, type_code,
/// plaintext, nonce, blake2s_256) tuples verbatim and assert both the digest
/// literal AND the boolean verify(), which is true cross-platform byte-for-byte
/// parity with Python / Android. The Android twin (ProofOfWorkTest.kt)
/// transcribes the same literals. created_at is LITTLE-ENDIAN -- the same
/// canonical encoding used by MessageId.derive (§3.3) and the sealed payload.
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

    // round-trip inputs (LE created_at = epoch 1).
    private var rtSender: Data { data(fromHex: "0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a") }
    private var rtCreatedAtLe: Data { data(fromHex: "01000000") }
    private var rtPlaintext: Data { data(fromHex: "68656c6c6f") }     // "hello"
    private let easyTarget = 8

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
        // Only the top 8 bits are zero; the 20-bit production target rejects it.
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: katNonce8, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, typeCode: TypeV2.message.rawValue,
                               plaintext: katPlaintext,
                               targetBits: ProofOfWork.targetBits))
    }

    // --- mine/verify round-trip (LE created_at) ---

    func testMinedNonceIs8BytesAndVerifiesAtEasyTarget() async throws {
        let nonce = try await ProofOfWork.mine(senderNodeId: rtSender,
                                               createdAtLe: rtCreatedAtLe,
                                               typeCode: TypeV2.message.rawValue,
                                               plaintext: rtPlaintext,
                                               targetBits: easyTarget)
        XCTAssertEqual(ProofOfWork.nonceBytes, nonce.count)
        XCTAssertTrue(
            ProofOfWork.verify(powNonce: nonce, senderNodeId: rtSender,
                               createdAtLe: rtCreatedAtLe, typeCode: TypeV2.message.rawValue,
                               plaintext: rtPlaintext, targetBits: easyTarget))
    }

    func testZeroNonceDoesNotVerifyForFreshContent() {
        let zero = Data(count: ProofOfWork.nonceBytes)
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: zero, senderNodeId: rtSender,
                               createdAtLe: rtCreatedAtLe, typeCode: TypeV2.message.rawValue,
                               plaintext: rtPlaintext, targetBits: easyTarget))
    }

    func testMinedNonceBoundToPlaintextDoesNotVerifyDifferentPlaintext() async throws {
        let nonce = try await ProofOfWork.mine(senderNodeId: rtSender,
                                               createdAtLe: rtCreatedAtLe,
                                               typeCode: TypeV2.message.rawValue,
                                               plaintext: rtPlaintext,
                                               targetBits: easyTarget)
        let other = data(fromHex: "776f726c64")  // "world"
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: nonce, senderNodeId: rtSender,
                               createdAtLe: rtCreatedAtLe, typeCode: TypeV2.message.rawValue,
                               plaintext: other, targetBits: easyTarget))
    }

    func testMinedNonceBoundToTypeCodeDoesNotVerifyDifferentType() async throws {
        let nonce = try await ProofOfWork.mine(senderNodeId: rtSender,
                                               createdAtLe: rtCreatedAtLe,
                                               typeCode: TypeV2.message.rawValue,
                                               plaintext: rtPlaintext,
                                               targetBits: easyTarget)
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: nonce, senderNodeId: rtSender,
                               createdAtLe: rtCreatedAtLe, typeCode: TypeV2.sos.rawValue,
                               plaintext: rtPlaintext, targetBits: easyTarget))
    }

    func testProduction20BitTargetRejects8BitNonce() async throws {
        // An 8-bit-mined nonce has only its top 8 bits zero; the 20-bit production
        // target demands 20, so the same nonce must fail at the harder target.
        let nonce = try await ProofOfWork.mine(senderNodeId: rtSender,
                                               createdAtLe: rtCreatedAtLe,
                                               typeCode: TypeV2.message.rawValue,
                                               plaintext: rtPlaintext,
                                               targetBits: easyTarget)
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: nonce, senderNodeId: rtSender,
                               createdAtLe: rtCreatedAtLe, typeCode: TypeV2.message.rawValue,
                               plaintext: rtPlaintext,
                               targetBits: ProofOfWork.targetBits))
    }
}