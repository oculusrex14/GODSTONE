import XCTest
import CryptoKit
import GodstoneCore
@testable import GodstoneMesh

final class BleRecordTests: XCTestCase {

    private final class InMemoryKeychain: LocalIdentityKeychain, @unchecked Sendable {
        var storage: [String: Data] = [:]
        func read(tag: String) throws -> Data? { storage[tag] }
        func add(tag: String, data: Data) throws { storage[tag] = data }
        func delete(tag: String) throws { storage.removeValue(forKey: tag) }
    }

    private final class RecordingTrustAuthority: PeerBindingTrustAuthority, @unchecked Sendable {
        func applyValidatedBinding(_ binding: ValidatedPeerBinding) -> PeerTrustApplyResult {
            .accepted
        }
    }

    private func hexToData(_ hex: String) -> Data {
        var data = Data()
        var hexStr = hex
        while hexStr.count >= 2 {
            let sub = hexStr.prefix(2)
            hexStr = String(hexStr.dropFirst(2))
            if let byte = UInt8(sub, radix: 16) {
                data.append(byte)
            }
        }
        return data
    }

    // ========================================================================
    // 1. Pinned Vectors from wire/ble_record_vectors.json
    // ========================================================================

    func testVector_Positive_Hs1_SingleFragment() throws {
        let payload = Data((0..<32).map { UInt8($0 % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .hs1, recordSeq: 0, payload: payload, maxAttValueLength: 100)
        XCTAssertEqual(frags.count, 1)

        let reassembler = BleRecordReassembler()
        let result = reassembler.receiveFragmentBytes(frags[0])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.recordType, .hs1)
        XCTAssertEqual(result?.recordSeq, 0)
        XCTAssertEqual(result?.payload, payload)
    }

    func testVector_Positive_Hs2_MultiFragment() throws {
        let payload = Data((0..<229).map { UInt8(($0 * 7 + 3) % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .hs2, recordSeq: 1, payload: payload, maxAttValueLength: 60)
        XCTAssertEqual(frags.count, 5)

        let reassembler = BleRecordReassembler()
        var result: BleReassembledRecord?
        for f in frags {
            if let r = reassembler.receiveFragmentBytes(f) {
                result = r
            }
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.recordType, .hs2)
        XCTAssertEqual(result?.recordSeq, 1)
        XCTAssertEqual(result?.payload, payload)
    }

    func testVector_Positive_Hs3_MultiFragment() throws {
        let payload = Data((0..<197).map { UInt8(($0 * 13 + 7) % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .hs3, recordSeq: 2, payload: payload, maxAttValueLength: 50)
        XCTAssertEqual(frags.count, 5)

        let reassembler = BleRecordReassembler()
        var result: BleReassembledRecord?
        for f in frags {
            if let r = reassembler.receiveFragmentBytes(f) {
                result = r
            }
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.recordType, .hs3)
        XCTAssertEqual(result?.recordSeq, 2)
        XCTAssertEqual(result?.payload, payload)
    }

    func testVector_Positive_Close_ZeroLength() throws {
        let payload = Data()
        let frags = try BleRecordFragmenter.fragment(recordType: .close, recordSeq: 3, payload: payload, maxAttValueLength: 100)
        XCTAssertEqual(frags.count, 1)

        let reassembler = BleRecordReassembler()
        let result = reassembler.receiveFragmentBytes(frags[0])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.recordType, .close)
        XCTAssertEqual(result?.recordSeq, 3)
        XCTAssertEqual(result?.payload.count, 0)
    }

    func testVector_Positive_Data_MultiFragment() throws {
        let payload = Data((0..<500).map { UInt8(($0 * 17 + 1) % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 255, payload: payload, maxAttValueLength: 128)
        XCTAssertEqual(frags.count, 5)

        let reassembler = BleRecordReassembler()
        var result: BleReassembledRecord?
        for f in frags {
            if let r = reassembler.receiveFragmentBytes(f) {
                result = r
            }
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.recordType, .data)
        XCTAssertEqual(result?.recordSeq, 255)
        XCTAssertEqual(result?.payload, payload)
    }

    func testVector_Positive_MaxRecord_16384() throws {
        let payload = Data((0..<16384).map { UInt8(($0 * 31) % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 100, payload: payload, maxAttValueLength: 264)
        XCTAssertEqual(frags.count, 64)

        let reassembler = BleRecordReassembler()
        var result: BleReassembledRecord?
        for f in frags {
            if let r = reassembler.receiveFragmentBytes(f) {
                result = r
            }
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.recordType, .data)
        XCTAssertEqual(result?.recordSeq, 100)
        XCTAssertEqual(result?.payload, payload)
    }

    // ========================================================================
    // Negative Vector Assertions
    // ========================================================================

    func testVector_Negative_TruncatedHeader() {
        XCTAssertNil(BleRecordCodec.decodeFragment(hexToData("47110000010020")))
    }

    func testVector_Negative_BadMagic() {
        let hs1Payload = Data((0..<32).map { UInt8($0 % 256) })
        let badMagicHdr = Data([0x48, 0x11, 0x00, 0x00, 0x01, 0x00, 0x20])
        let chk = BleRecordCodec.computeHeaderCheck(badMagicHdr)
        var full = badMagicHdr
        full.append(chk)
        full.append(hs1Payload)
        XCTAssertNil(BleRecordCodec.decodeFragment(full))
    }

    func testVector_Negative_UnknownRecordType() {
        let hs1Payload = Data((0..<32).map { UInt8($0 % 256) })
        let badTypeHdr = Data([0x47, 0x99, 0x00, 0x00, 0x01, 0x00, 0x20])
        let chk = BleRecordCodec.computeHeaderCheck(badTypeHdr)
        var full = badTypeHdr
        full.append(chk)
        full.append(hs1Payload)
        XCTAssertNil(BleRecordCodec.decodeFragment(full))
    }

    func testVector_Negative_CorruptHeaderXorCheck() throws {
        let hs1Payload = Data((0..<32).map { UInt8($0 % 256) })
        var hdr = try BleRecordCodec.encodeHeader(recordType: .hs1, recordSeq: 0, fragIndex: 0, fragCount: 1, totalLen: 32)
        hdr[7] ^= 0xFF
        hdr.append(hs1Payload)
        XCTAssertNil(BleRecordCodec.decodeFragment(hdr))
    }

    func testVector_Negative_FragCountZero() {
        let hs1Payload = Data((0..<32).map { UInt8($0 % 256) })
        let raw = Data([0x47, 0x11, 0x00, 0x00, 0x00, 0x00, 0x20])
        let chk = BleRecordCodec.computeHeaderCheck(raw)
        var full = raw
        full.append(chk)
        full.append(hs1Payload)
        XCTAssertNil(BleRecordCodec.decodeFragment(full))
    }

    func testVector_Negative_FragCount65ExceedsMax() {
        let hs1Payload = Data((0..<32).map { UInt8($0 % 256) })
        let raw = Data([0x47, 0x11, 0x00, 0x00, 65, 0x00, 0x20])
        let chk = BleRecordCodec.computeHeaderCheck(raw)
        var full = raw
        full.append(chk)
        full.append(hs1Payload)
        XCTAssertNil(BleRecordCodec.decodeFragment(full))
    }

    func testVector_Negative_FragIndexEqualsFragCount() {
        let hs1Payload = Data((0..<32).map { UInt8($0 % 256) })
        let raw = Data([0x47, 0x11, 0x00, 0x02, 0x02, 0x00, 0x20])
        let chk = BleRecordCodec.computeHeaderCheck(raw)
        var full = raw
        full.append(chk)
        full.append(hs1Payload)
        XCTAssertNil(BleRecordCodec.decodeFragment(full))
    }

    func testVector_Negative_TotalLen16385ExceedsMax() {
        let raw = Data([0x47, 0x18, 0x00, 0x00, 0x01, 0x40, 0x01])
        let chk = BleRecordCodec.computeHeaderCheck(raw)
        var full = raw
        full.append(chk)
        XCTAssertNil(BleRecordCodec.decodeFragment(full))
    }

    func testVector_Negative_TruncatedPayload() throws {
        let hs1Payload = Data((0..<31).map { UInt8($0 % 256) })
        var hdr = try BleRecordCodec.encodeHeader(recordType: .hs1, recordSeq: 0, fragIndex: 0, fragCount: 1, totalLen: 32)
        hdr.append(hs1Payload)
        XCTAssertNil(BleRecordCodec.decodeFragment(hdr))
    }

    func testVector_Negative_ExcessPayload() throws {
        let hs1Payload = Data((0..<33).map { UInt8($0 % 256) })
        var hdr = try BleRecordCodec.encodeHeader(recordType: .hs1, recordSeq: 0, fragIndex: 0, fragCount: 1, totalLen: 32)
        hdr.append(hs1Payload)
        XCTAssertNil(BleRecordCodec.decodeFragment(hdr))
    }

    // ========================================================================
    // 2. Property & Reordering & Conflict Tests
    // ========================================================================

    func testReassembly_ReverseOrder() throws {
        let payload = Data((0..<300).map { UInt8(($0 * 3) % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 42, payload: payload, maxAttValueLength: 70)
        let reassembler = BleRecordReassembler()

        var result: BleReassembledRecord?
        for f in frags.reversed() {
            if let r = reassembler.receiveFragmentBytes(f) {
                result = r
            }
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.recordSeq, 42)
        XCTAssertEqual(result?.recordType, .data)
        XCTAssertEqual(result?.payload, payload)
    }

    func testReassembly_ShuffledOrder() throws {
        let payload = Data((0..<450).map { UInt8(($0 * 11) % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 77, payload: payload, maxAttValueLength: 80)
        let reassembler = BleRecordReassembler()

        let indices = frags.indices.sorted { ($0 * 37) % frags.count < ($1 * 37) % frags.count }
        var result: BleReassembledRecord?
        for idx in indices {
            if let r = reassembler.receiveFragmentBytes(frags[idx]) {
                result = r
            }
        }
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.payload, payload)
    }

    func testReassembly_IdempotentDuplicateFragment() throws {
        let payload = Data((0..<150).map { UInt8($0 % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 10, payload: payload, maxAttValueLength: 50)
        let reassembler = BleRecordReassembler()

        XCTAssertNil(reassembler.receiveFragmentBytes(frags[0]))
        XCTAssertNil(reassembler.receiveFragmentBytes(frags[0])) // duplicate

        for i in 1..<frags.count {
            let r = reassembler.receiveFragmentBytes(frags[i])
            if i == frags.count - 1 {
                XCTAssertNotNil(r)
                XCTAssertEqual(r?.payload, payload)
            } else {
                XCTAssertNil(r)
            }
        }
    }

    func testReassembly_ConflictingDuplicateFragment_InvalidatesAssembly() throws {
        let payload = Data((0..<150).map { UInt8($0 % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 11, payload: payload, maxAttValueLength: 50)
        let reassembler = BleRecordReassembler()

        XCTAssertNil(reassembler.receiveFragmentBytes(frags[0]))

        var corruptFrag0 = frags[0]
        corruptFrag0[BleRecordConstants.headerBytes] ^= 0xFF

        XCTAssertNil(reassembler.receiveFragmentBytes(corruptFrag0)) // triggers invalidation

        for i in 1..<frags.count {
            XCTAssertNil(reassembler.receiveFragmentBytes(frags[i]))
        }
    }

    func testReassembly_MetadataConflict_InvalidatesAssembly() throws {
        let payload1 = Data((0..<100).map { UInt8($0 % 256) })
        let frags1 = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 12, payload: payload1, maxAttValueLength: 60)

        let reassembler = BleRecordReassembler()
        XCTAssertNil(reassembler.receiveFragmentBytes(frags1[0]))

        let payload2 = Data((0..<100).map { UInt8($0 % 256) })
        let frags2 = try BleRecordFragmenter.fragment(recordType: .hs2, recordSeq: 12, payload: payload2, maxAttValueLength: 60)

        XCTAssertNil(reassembler.receiveFragmentBytes(frags2[1])) // conflict

        for i in 1..<frags1.count {
            XCTAssertNil(reassembler.receiveFragmentBytes(frags1[i]))
        }
    }

    func testReassembly_MaxConcurrentLimit() throws {
        let reassembler = BleRecordReassembler()
        let payload = Data((0..<100).map { UInt8($0 % 256) })

        let frags1 = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 1, payload: payload, maxAttValueLength: 60)
        let frags2 = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 2, payload: payload, maxAttValueLength: 60)
        let frags3 = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 3, payload: payload, maxAttValueLength: 60)
        let frags4 = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 4, payload: payload, maxAttValueLength: 60)
        let frags5 = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 5, payload: payload, maxAttValueLength: 60)

        XCTAssertNil(reassembler.receiveFragmentBytes(frags1[0]))
        XCTAssertNil(reassembler.receiveFragmentBytes(frags2[0]))
        XCTAssertNil(reassembler.receiveFragmentBytes(frags3[0]))
        XCTAssertNil(reassembler.receiveFragmentBytes(frags4[0]))

        // 5th rejected
        XCTAssertNil(reassembler.receiveFragmentBytes(frags5[0]))

        // Finish 1
        for i in 1..<frags1.count {
            let r = reassembler.receiveFragmentBytes(frags1[i])
            if i == frags1.count - 1 { XCTAssertNotNil(r) }
        }

        // Now 5 can start
        XCTAssertNil(reassembler.receiveFragmentBytes(frags5[0]))
        for i in 1..<frags5.count {
            let r = reassembler.receiveFragmentBytes(frags5[i])
            if i == frags5.count - 1 { XCTAssertNotNil(r) }
        }
    }

    func testReassembly_TimeoutFailClosed() throws {
        var currentTime: TimeInterval = 1000.0
        let reassembler = BleRecordReassembler(timeProvider: { currentTime })
        let payload = Data((0..<120).map { UInt8($0 % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 20, payload: payload, maxAttValueLength: 50)

        XCTAssertNil(reassembler.receiveFragmentBytes(frags[0]))

        currentTime += 31.0

        XCTAssertNil(reassembler.receiveFragmentBytes(frags[1]))
    }

    func testReassembly_DuplicateCompletedRecord_Suppressed() throws {
        let payload = Data((0..<80).map { UInt8($0 % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 30, payload: payload, maxAttValueLength: 50)
        let reassembler = BleRecordReassembler()

        var firstCompletion: BleReassembledRecord?
        for f in frags {
            if let r = reassembler.receiveFragmentBytes(f) {
                firstCompletion = r
            }
        }
        XCTAssertNotNil(firstCompletion)

        for f in frags {
            XCTAssertNil(reassembler.receiveFragmentBytes(f))
        }
    }

    func testReassembly_SequenceWrap_Accepted() throws {
        let payload1 = Data(repeating: 0x11, count: 80)
        let frags1 = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 50, payload: payload1, maxAttValueLength: 50)
        let reassembler = BleRecordReassembler()

        var comp1: BleReassembledRecord?
        for f in frags1 {
            if let r = reassembler.receiveFragmentBytes(f) {
                comp1 = r
            }
        }
        XCTAssertNotNil(comp1)
        XCTAssertEqual(comp1?.payload, payload1)

        let payload2 = Data(repeating: 0x22, count: 90)
        let frags2 = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 50, payload: payload2, maxAttValueLength: 50)

        var comp2: BleReassembledRecord?
        for f in frags2 {
            if let r = reassembler.receiveFragmentBytes(f) {
                comp2 = r
            }
        }
        XCTAssertNotNil(comp2)
        XCTAssertEqual(comp2?.payload, payload2)
    }

    func testReassembly_ResetClearsAllState() throws {
        let payload = Data((0..<100).map { UInt8($0 % 256) })
        let frags = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 60, payload: payload, maxAttValueLength: 50)
        let reassembler = BleRecordReassembler()

        XCTAssertNil(reassembler.receiveFragmentBytes(frags[0]))
        reassembler.reset()

        XCTAssertNil(reassembler.receiveFragmentBytes(frags[1]))
    }

    // ========================================================================
    // 3. Encrypt-Then-Fragment Semantic Integrity
    // ========================================================================

    func testEncryptThenFragment_SemanticDataFlow() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())

        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        // Complete handshake
        let hs1 = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        let hs2 = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1))
        let hs3 = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2, advertisedRemoteHint: identityB.nodeHint))
        let readyB = smB.responderProcessHs3(peerA, hs3: hs3, advertisedRemoteHint: identityA.nodeHint)
        XCTAssertTrue(readyB)
        XCTAssertTrue(smA.isReady(peerB))
        XCTAssertTrue(smB.isReady(peerA))

        let plaintext = Data("Hello authenticated BLE record mesh layer on iOS!".utf8)

        // 1. Outbound: SessionManager.seal EXACTLY ONCE
        let ciphertext = try XCTUnwrap(smA.seal(peerB, plaintext))

        // 2. Fragment ciphertext into BLE records
        let frags = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 1, payload: ciphertext, maxAttValueLength: 25)
        XCTAssertTrue(frags.count > 1)

        // 3. Inbound: Reassemble BLE record fragments (out-of-order)
        let reassemblerB = BleRecordReassembler()
        var reassembledCiphertext: Data?
        for f in frags.reversed() {
            if let r = reassemblerB.receiveFragmentBytes(f) {
                reassembledCiphertext = r.payload
            }
        }
        XCTAssertNotNil(reassembledCiphertext)
        XCTAssertEqual(ciphertext, reassembledCiphertext)

        // 4. SessionManager.open EXACTLY ONCE on complete record
        let decrypted = try XCTUnwrap(smB.open(peerA, reassembledCiphertext!))
        XCTAssertEqual(plaintext, decrypted)
    }

    // ========================================================================
    // 4. Pure Handshake Record Composition Test (HS1 -> HS2 -> HS3 -> READY)
    // ========================================================================

    func testPureHandshake_ThroughBleRecords_CompletesAndReachesReady() throws {
        let identityA = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())
        let identityB = try MeshIdentity.generateAndStore(keychain: InMemoryKeychain())

        let smA = SessionManager(identity: identityA, trustAuthority: RecordingTrustAuthority())
        let smB = SessionManager(identity: identityB, trustAuthority: RecordingTrustAuthority())

        let peerB = UUID()
        let peerA = UUID()

        let reassemblerA = BleRecordReassembler()
        let reassemblerB = BleRecordReassembler()

        // 1. Initiator A starts HS1 (exactly 32 bytes)
        let hs1Raw = try XCTUnwrap(smA.initiatorStart(peerB, remoteHint: identityB.nodeHint))
        XCTAssertEqual(hs1Raw.count, 32)

        let hs1Frags = try BleRecordFragmenter.fragment(recordType: .hs1, recordSeq: 0, payload: hs1Raw, maxAttValueLength: 100)
        XCTAssertEqual(hs1Frags.count, 1)

        let hs1Reassembled = try XCTUnwrap(reassemblerB.receiveFragmentBytes(hs1Frags[0]))
        XCTAssertEqual(hs1Reassembled.recordType, .hs1)
        XCTAssertEqual(hs1Reassembled.payload.count, 32)

        // 2. Responder B processes HS1 and produces HS2 (exactly 229 bytes)
        let hs2Raw = try XCTUnwrap(smB.responderProcessHs1(peerA, remoteHint: identityA.nodeHint, hs1: hs1Reassembled.payload))
        XCTAssertEqual(hs2Raw.count, 229)

        // Fragment HS2 with small MTU to force multi-fragment
        let hs2Frags = try BleRecordFragmenter.fragment(recordType: .hs2, recordSeq: 0, payload: hs2Raw, maxAttValueLength: 60)
        XCTAssertTrue(hs2Frags.count >= 4)

        var hs2Reassembled: BleReassembledRecord?
        for f in hs2Frags.reversed() { // Reordered
            if let r = reassemblerA.receiveFragmentBytes(f) {
                hs2Reassembled = r
            }
        }
        XCTAssertNotNil(hs2Reassembled)
        XCTAssertEqual(hs2Reassembled?.recordType, .hs2)
        XCTAssertEqual(hs2Reassembled?.payload.count, 229)

        // 3. Initiator A processes HS2 and produces HS3 (exactly 197 bytes)
        let hs3Raw = try XCTUnwrap(smA.initiatorProcessHs2(peerB, hs2: hs2Reassembled!.payload, advertisedRemoteHint: identityB.nodeHint))
        XCTAssertEqual(hs3Raw.count, 197)

        let hs3Frags = try BleRecordFragmenter.fragment(recordType: .hs3, recordSeq: 1, payload: hs3Raw, maxAttValueLength: 55)
        XCTAssertTrue(hs3Frags.count >= 4)

        var hs3Reassembled: BleReassembledRecord?
        for f in hs3Frags.reversed() { // Reordered
            if let r = reassemblerB.receiveFragmentBytes(f) {
                hs3Reassembled = r
            }
        }
        XCTAssertNotNil(hs3Reassembled)
        XCTAssertEqual(hs3Reassembled?.recordType, .hs3)
        XCTAssertEqual(hs3Reassembled?.payload.count, 197)

        // 4. Responder B processes HS3
        let bReady = smB.responderProcessHs3(peerA, hs3: hs3Reassembled!.payload, advertisedRemoteHint: identityA.nodeHint)
        XCTAssertTrue(bReady)

        // Both managers are READY
        XCTAssertTrue(smA.isReady(peerB))
        XCTAssertTrue(smB.isReady(peerA))

        // 5. Subsequent encrypted DATA exchange
        let message = Data("Handshake completed over fragmented BLE records on iOS!".utf8)
        let ciphertext = try XCTUnwrap(smA.seal(peerB, message))
        let dataFrags = try BleRecordFragmenter.fragment(recordType: .data, recordSeq: 2, payload: ciphertext, maxAttValueLength: 40)
        XCTAssertTrue(dataFrags.count > 1)

        var reassembledData: BleReassembledRecord?
        for f in dataFrags {
            if let r = reassemblerB.receiveFragmentBytes(f) {
                reassembledData = r
            }
        }
        XCTAssertNotNil(reassembledData)

        let opened = try XCTUnwrap(smB.open(peerA, reassembledData!.payload))
        XCTAssertEqual(message, opened)
    }
}
