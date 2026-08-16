import XCTest
@testable import GodstoneMesh
import GodstoneCore

/// GMP/2.1 proof-of-work byte-parity (ADR-001 §3, Stage 3 Phase C / C6.7.1).
///
/// The canonical preimage is pinned against crypto/gmp21_vectors.json, generated
/// by the independent Python reference crypto/gmp21.py (hashlib.blake2s, RFC 7693):
///
///     BLAKE2s-256(ASCII("GMP2-POW") ‖ pow_nonce[8] ‖ sender_node_id[16] ‖ created_at_le[4] ‖
///                 message_nonce[16] ‖ type_code[1] ‖ plaintext)
///
/// created_at is LITTLE-ENDIAN -- the same canonical encoding used by
/// MessageId.derive (§3.3) and the sealed payload.
///
/// message_nonce binds the PoW stamp to the unique logical message identity.
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

    // pow_20bit_message_help_group: sender 00..0f, created_at_le = epoch 1, priority GROUP (2),
    // type MESSAGE, message_nonce 0101...01, plaintext "help", target 20 bits.
    private var katSender: Data { data(fromHex: "000102030405060708090a0b0c0d0e0f") }
    private var katCreatedAtLe: Data { data(fromHex: "01000000") }   // LE epoch 1
    private var katMessageNonce: Data { data(fromHex: "01010101010101010101010101010101") }
    private var katPlaintext: Data { data(fromHex: "68656c70") }     // "help"
    private let katPriorityGroup: UInt8 = 2                         // GROUP
    private var katNonce20: Data { data(fromHex: "00000000000fe48c") }
    private let katDigest20 = "00000f3615a49552df8cb9941dc1a7316ba5de36a79089b84a4d26d9a8036cea"

    // pow_8bit_message_help_group: same inputs, target 8 bits.
    private var katNonce8: Data { data(fromHex: "00000000000000c2") }
    private let katDigest8 = "00737167d06eef12d0bab941a4ac8529b91ed7768408527f5d47d02c229fec51"

    // Mutated values for binding tests.
    private let altPriorityBroadcast: UInt8 = 3                     // BROADCAST
    private let altPriorityDirect: UInt8 = 1                        // DIRECT
    private var altMessageNonce: Data { data(fromHex: "00000000000000000000000000000000") }
    private var altSender: Data { data(fromHex: "0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a") }
    private var altCreatedAtLe: Data { data(fromHex: "02000000") }   // LE epoch 2
    private var altPlaintext: Data { data(fromHex: "776f726c64") }   // "world"

    func testLocked20BitKatDigestReproducesPythonReference() {
        XCTAssertEqual(
            katDigest20,
            hex(ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)))
    }

    func testLocked20BitKatNonceVerifiesAtProductionTarget() {
        XCTAssertTrue(
            ProofOfWork.verify(powNonce: katNonce20, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                               priorityCode: katPriorityGroup,
                               typeCode: TypeV2.message.rawValue, plaintext: katPlaintext,
                               targetBits: ProofOfWork.targetBits))
    }

    func testLocked8BitKatDigestReproducesPythonReference() {
        XCTAssertEqual(
            katDigest8,
            hex(ProofOfWork.digest(powNonce: katNonce8, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)))
    }

    func testLocked8BitKatNonceVerifiesAt8BitAndFailsAt20Bit() {
        XCTAssertTrue(
            ProofOfWork.verify(powNonce: katNonce8, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                               priorityCode: katPriorityGroup,
                               typeCode: TypeV2.message.rawValue, plaintext: katPlaintext, targetBits: 8))
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: katNonce8, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                               priorityCode: katPriorityGroup,
                               typeCode: TypeV2.message.rawValue, plaintext: katPlaintext,
                               targetBits: ProofOfWork.targetBits))
    }

    func testZeroNonceFailsAtProductionTargetForKatContent() {
        let zero = Data(count: ProofOfWork.nonceBytes)
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: zero, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                               priorityCode: katPriorityGroup,
                               typeCode: TypeV2.message.rawValue, plaintext: katPlaintext,
                               targetBits: ProofOfWork.targetBits))
    }

    /// LOAD-BEARING: PoW mined for message_nonce A MUST fail verification when tested against message_nonce B.
    func testPowNonceMinedForMessageNonceAFailsAgainstMessageNonceB() {
        XCTAssertTrue(
            ProofOfWork.verify(powNonce: katNonce20, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                               priorityCode: katPriorityGroup,
                               typeCode: TypeV2.message.rawValue, plaintext: katPlaintext, targetBits: 20)
        )
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: katNonce20, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, messageNonce: altMessageNonce,
                               priorityCode: katPriorityGroup,
                               typeCode: TypeV2.message.rawValue, plaintext: katPlaintext, targetBits: 20)
        )
    }

    /// LOAD-BEARING: PoW mined for GROUP priority MUST fail verification when evaluated against BROADCAST or DIRECT.
    func testPowNonceMinedForGroupPriorityFailsAgainstBroadcastOrDirect() {
        XCTAssertTrue(
            ProofOfWork.verify(powNonce: katNonce20, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                               priorityCode: katPriorityGroup,
                               typeCode: TypeV2.message.rawValue, plaintext: katPlaintext, targetBits: 20)
        )
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: katNonce20, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                               priorityCode: altPriorityBroadcast,
                               typeCode: TypeV2.message.rawValue, plaintext: katPlaintext, targetBits: 20)
        )
        XCTAssertFalse(
            ProofOfWork.verify(powNonce: katNonce20, senderNodeId: katSender,
                               createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                               priorityCode: altPriorityDirect,
                               typeCode: TypeV2.message.rawValue, plaintext: katPlaintext, targetBits: 20)
        )
    }

    // --- binding tests ---

    func testDigestBindsMessageNonce() {
        let a = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)
        let b = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: altMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)
        XCTAssertNotEqual(a, b)
    }

    func testDigestBindsPriorityCode() {
        let g = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)
        let bc = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                    createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                    priorityCode: altPriorityBroadcast,
                                    typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)
        let d = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: altPriorityDirect,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)
        XCTAssertNotEqual(g, bc)
        XCTAssertNotEqual(g, d)
    }

    func testDigestBindsTypeCode() {
        let m = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)
        let s = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.sos.rawValue, plaintext: katPlaintext)
        XCTAssertNotEqual(m, s)
    }

    func testDigestBindsPlaintext() {
        let a = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)
        let b = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: altPlaintext)
        XCTAssertNotEqual(a, b)
    }

    func testDigestBindsSender() {
        let a = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)
        let b = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: altSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)
        XCTAssertNotEqual(a, b)
    }

    func testDigestBindsCreatedAt() {
        let a = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: katCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)
        let b = ProofOfWork.digest(powNonce: katNonce20, senderNodeId: katSender,
                                   createdAtLe: altCreatedAtLe, messageNonce: katMessageNonce,
                                   priorityCode: katPriorityGroup,
                                   typeCode: TypeV2.message.rawValue, plaintext: katPlaintext)
        XCTAssertNotEqual(a, b)
    }

    // --- mine/verify round-trip ---

    func testMinedNonceIs8BytesAndVerifiesAtEasyTarget() async throws {
        let nonce = try await ProofOfWork.mine(senderNodeId: altSender,
                                               createdAtLe: katCreatedAtLe,
                                               messageNonce: altMessageNonce,
                                               priorityCode: katPriorityGroup,
                                               typeCode: TypeV2.message.rawValue,
                                               plaintext: altPlaintext,
                                               targetBits: 8)
        XCTAssertEqual(ProofOfWork.nonceBytes, nonce.count)
        XCTAssertTrue(
            ProofOfWork.verify(powNonce: nonce, senderNodeId: altSender,
                               createdAtLe: katCreatedAtLe, messageNonce: altMessageNonce,
                               priorityCode: katPriorityGroup,
                               typeCode: TypeV2.message.rawValue,
                               plaintext: altPlaintext, targetBits: 8))
    }
}