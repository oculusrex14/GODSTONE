#!/usr/bin/env python3
"""Structural and regression controls for Canonical BLE Record Layer (ADR-002, Phase C8.4C).

Verifies the presence, boundaries, and structural invariants of:
- BR01: Android BleRecordType enum with HS1(0x11), HS2(0x12), HS3(0x14), DATA(0x18), CLOSE(0x21)
- BR02: iOS BleRecordType enum with hs1=0x11, hs2=0x12, hs3=0x14, data=0x18, close=0x21
- BR03: Canonical constants: MAGIC=0x47, HEADER_BYTES=8, MAX_RECORD=16384, MAX_FRAGMENTS=64, MAX_CONCURRENT=4, REASSEMBLY_TIMEOUT_SECONDS=30
- BR04: Android BleRecordHeader and BleRecordCodec header encode/decode with XOR header_check and big-endian total_len
- BR05: iOS BleRecordHeader and BleRecordCodec header encode/decode with XOR header_check and big-endian total_len
- BR06: Android canonical balanced-stride fragmentation rule: capacity = maxAttValueLength - 8, stride = (totalLen + fragCount - 1) / fragCount
- BR07: iOS canonical balanced-stride fragmentation rule: capacity = maxAttValueLength - 8, stride = (totalLen + fragCount - 1) / fragCount
- BR08: Android decodeFragment validates canonical stride boundaries, payload length match, frag_index < frag_count, totalLen <= 16384
- BR09: iOS decodeFragment validates canonical stride boundaries, payload length match, fragIndex < fragCount, totalLen <= 16384
- BR10: Android BleRecordReassembler: max 4 concurrent assemblies, reject 5th without evicting active
- BR11: iOS BleRecordReassembler: max 4 concurrent assemblies, reject 5th without evicting active
- BR12: Android BleRecordReassembler: idempotent duplicate fragment, conflicting duplicate invalidates assembly and fails closed
- BR13: iOS BleRecordReassembler: idempotent duplicate fragment, conflicting duplicate invalidates assembly and fails closed
- BR14: Android BleRecordReassembler: completed fingerprint per connection-local record_seq prevents duplicate re-emission, allows sequence wrap
- BR15: iOS BleRecordReassembler: completed fingerprint per connection-local record_seq prevents duplicate re-emission, allows sequence wrap
- BR16: Android BleRecordReassembler: 30-second timeout with injected clock, resets all state on teardown
- BR17: iOS BleRecordReassembler: 30-second timeout with injected clock/timeProvider, resets all state on teardown
- BR18: wire/ble_record_reference.py exists and implements pure reference codec, fragmenter, reassembler, and self-test passes
- BR19: wire/ble_record_vectors.json exists with positive and negative cases matching reference generator
- BR20: Android BleRecordTest tests vectors, property tests, duplicate/conflict/timeout, encrypt-then-fragment semantic test, pure 32/229/197 handshake composition test
- BR21: iOS BleRecordTests tests vectors, property tests, duplicate/conflict/timeout, encrypt-then-fragment semantic test, pure 32/229/197 handshake composition test
- BR22: Android LINK_LAYER_READY remains false, iOS MeshNode.linkLayerReady remains false, LIGHT remains Archive-only / Mesh absent
- BR23: ADR-002 and ADR-003 status truthful representation of Phase C8.4C
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Paths
ANDROID_RECORD_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleRecord.kt"
ANDROID_TEST_RECORD_PATH = ROOT / "android" / "mesh" / "src" / "test" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleRecordTest.kt"
ANDROID_BLE_TRANSPORT_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "transport" / "BleTransport.kt"
ANDROID_MESH_NODE_PATH = ROOT / "android" / "mesh" / "src" / "main" / "java" / "io" / "godstone" / "mesh" / "MeshNode.kt"

IOS_RECORD_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "BleRecord.swift"
IOS_TEST_RECORD_PATH = ROOT / "ios" / "Godstone" / "Tests" / "GodstoneMeshTests" / "BleRecordTests.swift"
IOS_MESH_NODE_PATH = ROOT / "ios" / "Godstone" / "Sources" / "GodstoneMesh" / "MeshNode.swift"
IOS_APP_CONTAINER_PATH = ROOT / "ios" / "Godstone" / "Sources" / "App" / "AppContainer.swift"

PYTHON_REF_PATH = ROOT / "wire" / "ble_record_reference.py"
VECTORS_JSON_PATH = ROOT / "wire" / "ble_record_vectors.json"

ADR002_PATH = ROOT / "docs" / "adr" / "ADR-002-ble-record-layer.md"
ADR003_PATH = ROOT / "docs" / "adr" / "ADR-003-identity-and-sealed-sender.md"


def strip_comments(text: str) -> str:
    """Remove single-line and multi-line comments."""
    text = re.sub(r'//.*', '', text)
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
    return text


def check_controls(
    android_record_path: Path = ANDROID_RECORD_PATH,
    android_test_record_path: Path = ANDROID_TEST_RECORD_PATH,
    android_ble_transport_path: Path = ANDROID_BLE_TRANSPORT_PATH,
    android_mesh_node_path: Path = ANDROID_MESH_NODE_PATH,
    ios_record_path: Path = IOS_RECORD_PATH,
    ios_test_record_path: Path = IOS_TEST_RECORD_PATH,
    ios_mesh_node_path: Path = IOS_MESH_NODE_PATH,
    ios_app_container_path: Path = IOS_APP_CONTAINER_PATH,
    python_ref_path: Path = PYTHON_REF_PATH,
    vectors_json_path: Path = VECTORS_JSON_PATH,
    adr002_path: Path = ADR002_PATH,
    adr003_path: Path = ADR003_PATH,
) -> list[str]:
    """Run all structural checks BR01-BR23. Returns list of error messages (empty if all pass)."""
    errors: list[str] = []

    # ------------------------------------------------------------------------
    # BR01: Android BleRecordType enum
    # ------------------------------------------------------------------------
    if not android_record_path.exists():
        errors.append(f"BR01: Android record file not found: {android_record_path}")
    else:
        content = strip_comments(android_record_path.read_text(encoding="utf-8"))
        if not re.search(r'enum\s+class\s+BleRecordType', content):
            errors.append("BR01: BleRecordType enum class missing in Android BleRecord.kt")
        for t, code in [("HS1", "0x11"), ("HS2", "0x12"), ("HS3", "0x14"), ("DATA", "0x18"), ("CLOSE", "0x21")]:
            if not re.search(rf'{t}\s*\(\s*{code}', content):
                errors.append(f"BR01: Android BleRecordType.{t} with code {code} missing")

    # ------------------------------------------------------------------------
    # BR02: iOS BleRecordType enum
    # ------------------------------------------------------------------------
    if not ios_record_path.exists():
        errors.append(f"BR02: iOS record file not found: {ios_record_path}")
    else:
        content = strip_comments(ios_record_path.read_text(encoding="utf-8"))
        if not re.search(r'enum\s+BleRecordType\s*:\s*UInt8', content):
            errors.append("BR02: BleRecordType enum missing in iOS BleRecord.swift")
        for t, code in [("hs1", "0x11"), ("hs2", "0x12"), ("hs3", "0x14"), ("data", "0x18"), ("close", "0x21")]:
            if not re.search(rf'case\s+{t}\s*=\s*{code}', content):
                errors.append(f"BR02: iOS BleRecordType.{t} with raw value {code} missing")

    # ------------------------------------------------------------------------
    # BR03: Canonical Constants on Android and iOS
    # ------------------------------------------------------------------------
    if android_record_path.exists():
        c_kt = strip_comments(android_record_path.read_text(encoding="utf-8"))
        if not re.search(r'MAGIC\s*:\s*Byte\s*=\s*0x47', c_kt):
            errors.append("BR03: Android MAGIC 0x47 missing")
        if not re.search(r'HEADER_BYTES\s*:\s*Int\s*=\s*8', c_kt):
            errors.append("BR03: Android HEADER_BYTES 8 missing")
        if not re.search(r'MAX_RECORD\s*:\s*Int\s*=\s*16384', c_kt):
            errors.append("BR03: Android MAX_RECORD 16384 missing")
        if not re.search(r'MAX_FRAGMENTS\s*:\s*Int\s*=\s*64', c_kt):
            errors.append("BR03: Android MAX_FRAGMENTS 64 missing")
        if not re.search(r'MAX_CONCURRENT\s*:\s*Int\s*=\s*4', c_kt):
            errors.append("BR03: Android MAX_CONCURRENT 4 missing")
        if not re.search(r'REASSEMBLY_TIMEOUT_SECONDS\s*:\s*Long\s*=\s*30', c_kt):
            errors.append("BR03: Android REASSEMBLY_TIMEOUT_SECONDS 30 missing")

    if ios_record_path.exists():
        c_swift = strip_comments(ios_record_path.read_text(encoding="utf-8"))
        if not re.search(r'magic\s*:\s*UInt8\s*=\s*0x47', c_swift):
            errors.append("BR03: iOS magic 0x47 missing")
        if not re.search(r'headerBytes\s*:\s*Int\s*=\s*8', c_swift):
            errors.append("BR03: iOS headerBytes 8 missing")
        if not re.search(r'maxRecord\s*:\s*Int\s*=\s*16384', c_swift):
            errors.append("BR03: iOS maxRecord 16384 missing")
        if not re.search(r'maxFragments\s*:\s*Int\s*=\s*64', c_swift):
            errors.append("BR03: iOS maxFragments 64 missing")
        if not re.search(r'maxConcurrent\s*:\s*Int\s*=\s*4', c_swift):
            errors.append("BR03: iOS maxConcurrent 4 missing")
        if not re.search(r'reassemblyTimeoutSeconds\s*:\s*TimeInterval\s*=\s*30', c_swift):
            errors.append("BR03: iOS reassemblyTimeoutSeconds 30 missing")

    # ------------------------------------------------------------------------
    # BR04: Android BleRecordHeader & BleRecordCodec
    # ------------------------------------------------------------------------
    if android_record_path.exists():
        c_kt = strip_comments(android_record_path.read_text(encoding="utf-8"))
        if "data class BleRecordHeader" not in c_kt:
            errors.append("BR04: Android BleRecordHeader data class missing")
        if "object BleRecordCodec" not in c_kt:
            errors.append("BR04: Android BleRecordCodec object missing")
        if not re.search(r'b0\.toInt\(\)\s+xor\s+b1\.toInt\(\)\s+xor\s+b2\.toInt\(\)\s+xor\s+b3\.toInt\(\)\s+xor\s+b4\.toInt\(\)\s+xor\s+b5\.toInt\(\)\s+xor\s+b6\.toInt\(\)', c_kt):
            errors.append("BR04: Android computeHeaderCheck 7-byte XOR missing")
        if "ushr 8" not in c_kt:
            errors.append("BR04: Android totalLen big-endian encode missing")

    # ------------------------------------------------------------------------
    # BR05: iOS BleRecordHeader & BleRecordCodec
    # ------------------------------------------------------------------------
    if ios_record_path.exists():
        c_swift = strip_comments(ios_record_path.read_text(encoding="utf-8"))
        if "struct BleRecordHeader" not in c_swift:
            errors.append("BR05: iOS BleRecordHeader struct missing")
        if "enum BleRecordCodec" not in c_swift:
            errors.append("BR05: iOS BleRecordCodec enum missing")
        if "computeHeaderCheck" not in c_swift or "^" not in c_swift:
            errors.append("BR05: iOS computeHeaderCheck XOR missing")
        if "totalLen >> 8" not in c_swift:
            errors.append("BR05: iOS totalLen big-endian encode missing")

    # ------------------------------------------------------------------------
    # BR06: Android balanced stride rule
    # ------------------------------------------------------------------------
    if android_record_path.exists():
        c_kt = strip_comments(android_record_path.read_text(encoding="utf-8"))
        if "(totalLen + capacity - 1) / capacity" not in c_kt:
            errors.append("BR06: Android fragCount ceil division missing")
        if "(totalLen + fragCount - 1) / fragCount" not in c_kt:
            errors.append("BR06: Android stride ceil division missing")

    # ------------------------------------------------------------------------
    # BR07: iOS balanced stride rule
    # ------------------------------------------------------------------------
    if ios_record_path.exists():
        c_swift = strip_comments(ios_record_path.read_text(encoding="utf-8"))
        if "(totalLen + capacity - 1) / capacity" not in c_swift:
            errors.append("BR07: iOS fragCount ceil division missing")
        if c_swift.count("(totalLen + fragCount - 1) / fragCount") < 3:
            errors.append("BR07: iOS stride ceil division missing in bounds/fragmenter")

    # ------------------------------------------------------------------------
    # BR08: Android decodeFragment validation
    # ------------------------------------------------------------------------
    if android_record_path.exists():
        c_kt = strip_comments(android_record_path.read_text(encoding="utf-8"))
        if "fun decodeFragment(" not in c_kt:
            errors.append("BR08: Android decodeFragment missing")
        if "canonicalFragmentBounds" not in c_kt:
            errors.append("BR08: Android canonicalFragmentBounds validation missing")

    # ------------------------------------------------------------------------
    # BR09: iOS decodeFragment validation
    # ------------------------------------------------------------------------
    if ios_record_path.exists():
        c_swift = strip_comments(ios_record_path.read_text(encoding="utf-8"))
        if "func decodeFragment(" not in c_swift:
            errors.append("BR09: iOS decodeFragment missing")
        if "canonicalFragmentBounds" not in c_swift:
            errors.append("BR09: iOS canonicalFragmentBounds validation missing")

    # ------------------------------------------------------------------------
    # BR10: Android BleRecordReassembler concurrency limit
    # ------------------------------------------------------------------------
    if android_record_path.exists():
        c_kt = strip_comments(android_record_path.read_text(encoding="utf-8"))
        if "inFlight.size >= BleRecordConstants.MAX_CONCURRENT" not in c_kt:
            errors.append("BR10: Android BleRecordReassembler MAX_CONCURRENT check missing")

    # ------------------------------------------------------------------------
    # BR11: iOS BleRecordReassembler concurrency limit
    # ------------------------------------------------------------------------
    if ios_record_path.exists():
        c_swift = strip_comments(ios_record_path.read_text(encoding="utf-8"))
        if "inFlight.count < BleRecordConstants.maxConcurrent" not in c_swift:
            errors.append("BR11: iOS BleRecordReassembler maxConcurrent check missing")

    # ------------------------------------------------------------------------
    # BR12: Android duplicate fragment handling
    # ------------------------------------------------------------------------
    if android_record_path.exists():
        c_kt = strip_comments(android_record_path.read_text(encoding="utf-8"))
        if "existingPayload.contentEquals(frag.payload)" not in c_kt:
            errors.append("BR12: Android duplicate payload equality check missing")

    # ------------------------------------------------------------------------
    # BR13: iOS duplicate fragment handling
    # ------------------------------------------------------------------------
    if ios_record_path.exists():
        c_swift = strip_comments(ios_record_path.read_text(encoding="utf-8"))
        if "existingPayload ==" not in c_swift:
            errors.append("BR13: iOS duplicate payload equality check missing")

    # ------------------------------------------------------------------------
    # BR14: Android completed fingerprinting
    # ------------------------------------------------------------------------
    if android_record_path.exists():
        c_kt = strip_comments(android_record_path.read_text(encoding="utf-8"))
        if "completedFingerprints[seq] == fp" not in c_kt:
            errors.append("BR14: Android completedFingerprints check missing")

    # ------------------------------------------------------------------------
    # BR15: iOS completed fingerprinting
    # ------------------------------------------------------------------------
    if ios_record_path.exists():
        c_swift = strip_comments(ios_record_path.read_text(encoding="utf-8"))
        if "completedFingerprints[seq] == fp" not in c_swift:
            errors.append("BR15: iOS completedFingerprints check missing")

    # ------------------------------------------------------------------------
    # BR16: Android 30s timeout & clock injection
    # ------------------------------------------------------------------------
    if android_record_path.exists():
        c_kt = strip_comments(android_record_path.read_text(encoding="utf-8"))
        if "clock: () -> Long" not in c_kt or "evictExpired" not in c_kt:
            errors.append("BR16: Android injected clock and evictExpired missing")

    # ------------------------------------------------------------------------
    # BR17: iOS 30s timeout & clock injection
    # ------------------------------------------------------------------------
    if ios_record_path.exists():
        c_swift = strip_comments(ios_record_path.read_text(encoding="utf-8"))
        if "timeProvider: @escaping () -> TimeInterval" not in c_swift or "evictExpired" not in c_swift:
            errors.append("BR17: iOS injected timeProvider and evictExpired missing")

    # ------------------------------------------------------------------------
    # BR18: wire/ble_record_reference.py
    # ------------------------------------------------------------------------
    if not python_ref_path.exists():
        errors.append(f"BR18: Python reference missing at {python_ref_path}")
    else:
        c_py = python_ref_path.read_text(encoding="utf-8")
        if "class BleRecordReassembler:" not in c_py or "def fragment_record(" not in c_py:
            errors.append("BR18: Python reference missing BleRecordReassembler or fragment_record")

    # ------------------------------------------------------------------------
    # BR19: wire/ble_record_vectors.json
    # ------------------------------------------------------------------------
    if not vectors_json_path.exists():
        errors.append(f"BR19: Vectors JSON missing at {vectors_json_path}")
    else:
        try:
            vec_data = json.loads(vectors_json_path.read_text(encoding="utf-8"))
            if "positive_cases" not in vec_data or len(vec_data["positive_cases"]) < 6:
                errors.append("BR19: Incomplete positive_cases in ble_record_vectors.json")
            if "negative_cases" not in vec_data or len(vec_data["negative_cases"]) < 10:
                errors.append("BR19: Incomplete negative_cases in ble_record_vectors.json")
        except Exception as e:
            errors.append(f"BR19: Invalid JSON in ble_record_vectors.json: {e}")

    # ------------------------------------------------------------------------
    # BR20: Android BleRecordTest inventory
    # ------------------------------------------------------------------------
    if not android_test_record_path.exists():
        errors.append(f"BR20: Android BleRecordTest missing at {android_test_record_path}")
    else:
        c_test = strip_comments(android_test_record_path.read_text(encoding="utf-8"))
        req_tests = [
            "testVector_Positive_Hs1_SingleFragment",
            "testVector_Positive_Hs2_MultiFragment",
            "testVector_Positive_Hs3_MultiFragment",
            "testVector_Positive_Close_ZeroLength",
            "testVector_Positive_Data_MultiFragment",
            "testVector_Positive_MaxRecord_16384",
            "testVector_Negative_TruncatedHeader",
            "testVector_Negative_BadMagic",
            "testVector_Negative_UnknownRecordType",
            "testVector_Negative_CorruptHeaderXorCheck",
            "testVector_Negative_FragCountZero",
            "testVector_Negative_FragCount65ExceedsMax",
            "testVector_Negative_FragIndexEqualsFragCount",
            "testVector_Negative_TotalLen16385ExceedsMax",
            "testVector_Negative_TruncatedPayload",
            "testVector_Negative_ExcessPayload",
            "testReassembly_ReverseOrder",
            "testReassembly_ShuffledOrder",
            "testReassembly_IdempotentDuplicateFragment",
            "testReassembly_ConflictingDuplicateFragment_InvalidatesAssembly",
            "testReassembly_MetadataConflict_InvalidatesAssembly",
            "testReassembly_MaxConcurrentLimit",
            "testReassembly_TimeoutFailClosed",
            "testReassembly_DuplicateCompletedRecord_Suppressed",
            "testReassembly_SequenceWrap_Accepted",
            "testReassembly_ResetClearsAllState",
            "testEncryptThenFragment_SemanticDataFlow",
            "testPureHandshake_ThroughBleRecords_CompletesAndReachesReady",
        ]
        for t in req_tests:
            if t not in c_test:
                errors.append(f"BR20: Android BleRecordTest missing required test method {t}")

    # ------------------------------------------------------------------------
    # BR21: iOS BleRecordTests inventory
    # ------------------------------------------------------------------------
    if not ios_test_record_path.exists():
        errors.append(f"BR21: iOS BleRecordTests missing at {ios_test_record_path}")
    else:
        c_test = strip_comments(ios_test_record_path.read_text(encoding="utf-8"))
        req_tests = [
            "testVector_Positive_Hs1_SingleFragment",
            "testVector_Positive_Hs2_MultiFragment",
            "testVector_Positive_Hs3_MultiFragment",
            "testVector_Positive_Close_ZeroLength",
            "testVector_Positive_Data_MultiFragment",
            "testVector_Positive_MaxRecord_16384",
            "testVector_Negative_TruncatedHeader",
            "testVector_Negative_BadMagic",
            "testVector_Negative_UnknownRecordType",
            "testVector_Negative_CorruptHeaderXorCheck",
            "testVector_Negative_FragCountZero",
            "testVector_Negative_FragCount65ExceedsMax",
            "testVector_Negative_FragIndexEqualsFragCount",
            "testVector_Negative_TotalLen16385ExceedsMax",
            "testVector_Negative_TruncatedPayload",
            "testVector_Negative_ExcessPayload",
            "testReassembly_ReverseOrder",
            "testReassembly_ShuffledOrder",
            "testReassembly_IdempotentDuplicateFragment",
            "testReassembly_ConflictingDuplicateFragment_InvalidatesAssembly",
            "testReassembly_MetadataConflict_InvalidatesAssembly",
            "testReassembly_MaxConcurrentLimit",
            "testReassembly_TimeoutFailClosed",
            "testReassembly_DuplicateCompletedRecord_Suppressed",
            "testReassembly_SequenceWrap_Accepted",
            "testReassembly_ResetClearsAllState",
            "testEncryptThenFragment_SemanticDataFlow",
            "testPureHandshake_ThroughBleRecords_CompletesAndReachesReady",
        ]
        for t in req_tests:
            if t not in c_test:
                errors.append(f"BR21: iOS BleRecordTests missing required test method {t}")

    # ------------------------------------------------------------------------
    # BR22: LINK_LAYER_READY = false and Mesh absent from LIGHT
    # ------------------------------------------------------------------------
    if android_mesh_node_path.exists():
        c_node = strip_comments(android_mesh_node_path.read_text(encoding="utf-8"))
        if not re.search(r'const\s+val\s+LINK_LAYER_READY\s*=\s*false', c_node):
            errors.append("BR22: Android MeshNode.LINK_LAYER_READY must be false")

    if ios_mesh_node_path.exists():
        c_node = strip_comments(ios_mesh_node_path.read_text(encoding="utf-8"))
        if not re.search(r'public\s+static\s+let\s+linkLayerReady\s*=\s*false', c_node):
            errors.append("BR22: iOS MeshNode.linkLayerReady must be false")

    if ios_app_container_path.exists():
        c_app = strip_comments(ios_app_container_path.read_text(encoding="utf-8"))
        if "GodstoneMesh" in c_app or "MeshRuntime" in c_app or "BleRecord" in c_app:
            errors.append("BR22: iOS AppContainer must remain Archive-only (Mesh absent)")

    # ------------------------------------------------------------------------
    # BR23: ADR-002 and ADR-003 Status Consistency
    # ------------------------------------------------------------------------
    if adr002_path.exists():
        c_adr2 = adr002_path.read_text(encoding="utf-8")
        if not re.search(r'STATUS:\s*ACCEPTED\s*/\s*PHASE\s+C8\.4C', c_adr2):
            errors.append("BR23: ADR-002 missing C8.4C status documentation")

    if adr003_path.exists():
        c_adr3 = adr003_path.read_text(encoding="utf-8")
        if not re.search(r'Phase\s+C8\.4C\s+Canonical\s+BLE\s+Record\s+Layer', c_adr3):
            errors.append("BR23: ADR-003 missing C8.4C status documentation")

    return errors


def run_selftest() -> int:
    """Mutation testing for all BR01-BR23 control rules."""
    print("Running check_ble_record_controls selftest (mutation test battery)...")

    # 1. Baseline must pass
    baseline_errors = check_controls()
    if baseline_errors:
        print("FAIL: Baseline check failed with errors:", file=sys.stderr)
        for err in baseline_errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    mutations: list[tuple[str, str, str, str]] = [
        # (File to mutate, original snippet, mutant snippet, expected error substring)
        ("android_record", "HS2(0x12.toByte())", "HS2(0x99.toByte())", "BR01"),
        ("ios_record", "case hs2 = 0x12", "case hs2 = 0x99", "BR02"),
        ("android_record", "MAGIC: Byte = 0x47.toByte()", "MAGIC: Byte = 0x48.toByte()", "BR03"),
        ("ios_record", "maxRecord: Int = 16384", "maxRecord: Int = 32768", "BR03"),
        ("android_record", "b0.toInt() xor b1.toInt()", "b0.toInt() or b1.toInt()", "BR04"),
        ("ios_record", "totalLen >> 8", "totalLen & 0xFF", "BR05"),
        ("android_record", "(totalLen + capacity - 1) / capacity", "totalLen / capacity", "BR06"),
        ("ios_record", "let stride = (totalLen + fragCount - 1) / fragCount", "let stride = totalLen / fragCount", "BR07"),
        ("android_record", "fun decodeFragment(bytes: ByteArray)", "fun decodeFragmentUnsafe(bytes: ByteArray)", "BR08"),
        ("ios_record", "func decodeFragment(_ data: Data)", "func decodeFragmentUnsafe(_ data: Data)", "BR09"),
        ("android_record", "inFlight.size >= BleRecordConstants.MAX_CONCURRENT", "inFlight.size >= 999", "BR10"),
        ("ios_record", "inFlight.count < BleRecordConstants.maxConcurrent", "inFlight.count < 999", "BR11"),
        ("android_record", "existingPayload.contentEquals(frag.payload)", "false", "BR12"),
        ("ios_record", "existingPayload ==", "existingPayload !=", "BR13"),
        ("android_record", "completedFingerprints[seq] == fp", "false", "BR14"),
        ("ios_record", "completedFingerprints[seq] == fp", "false", "BR15"),
        ("android_record", "clock: () -> Long", "clock: () -> Unit", "BR16"),
        ("ios_record", "timeProvider: @escaping () -> TimeInterval", "timeProvider: () -> Void", "BR17"),
        ("python_ref", "class BleRecordReassembler:", "class BleRecordReassemblerDisabled:", "BR18"),
        ("android_test_record", "testEncryptThenFragment_SemanticDataFlow", "disabled_testEncryptThenFragment", "BR20"),
        ("ios_test_record", "testPureHandshake_ThroughBleRecords_CompletesAndReachesReady", "disabled_testHandshake", "BR21"),
        ("android_mesh_node", "const val LINK_LAYER_READY = false", "const val LINK_LAYER_READY = true", "BR22"),
        ("ios_mesh_node", "public static let linkLayerReady = false", "public static let linkLayerReady = true", "BR22"),
        ("ios_app_container", "import Foundation", "import Foundation\nimport GodstoneMesh", "BR22"),
        ("adr002", "PHASE C8.4C", "PHASE C8.4X_MUTATED", "BR23"),
        ("adr003", "Phase C8.4C Canonical BLE Record Layer", "Phase C8.4X Canonical BLE Record Layer", "BR23"),
    ]

    all_passed = True
    with tempfile.TemporaryDirectory() as tmp_dir:
        tmp_path = Path(tmp_dir)

        file_map = {
            "android_record": ANDROID_RECORD_PATH,
            "android_test_record": ANDROID_TEST_RECORD_PATH,
            "android_ble_transport": ANDROID_BLE_TRANSPORT_PATH,
            "android_mesh_node": ANDROID_MESH_NODE_PATH,
            "ios_record": IOS_RECORD_PATH,
            "ios_test_record": IOS_TEST_RECORD_PATH,
            "ios_mesh_node": IOS_MESH_NODE_PATH,
            "ios_app_container": IOS_APP_CONTAINER_PATH,
            "python_ref": PYTHON_REF_PATH,
            "vectors_json": VECTORS_JSON_PATH,
            "adr002": ADR002_PATH,
            "adr003": ADR003_PATH,
        }

        tmp_files: dict[str, Path] = {}
        for key, orig in file_map.items():
            t = tmp_path / orig.name
            t.write_text(orig.read_text(encoding="utf-8"), encoding="utf-8")
            tmp_files[key] = t

        for file_key, orig_str, mut_str, expected_err in mutations:
            target = tmp_files[file_key]
            orig_content = target.read_text(encoding="utf-8")
            if orig_str not in orig_content:
                print(f"FAIL: Mutation snippet not found in {file_key}: {orig_str!r}", file=sys.stderr)
                all_passed = False
                continue

            mut_content = orig_content.replace(orig_str, mut_str, 1)
            target.write_text(mut_content, encoding="utf-8")

            errs = check_controls(
                android_record_path=tmp_files["android_record"],
                android_test_record_path=tmp_files["android_test_record"],
                android_ble_transport_path=tmp_files["android_ble_transport"],
                android_mesh_node_path=tmp_files["android_mesh_node"],
                ios_record_path=tmp_files["ios_record"],
                ios_test_record_path=tmp_files["ios_test_record"],
                ios_mesh_node_path=tmp_files["ios_mesh_node"],
                ios_app_container_path=tmp_files["ios_app_container"],
                python_ref_path=tmp_files["python_ref"],
                vectors_json_path=tmp_files["vectors_json"],
                adr002_path=tmp_files["adr002"],
                adr003_path=tmp_files["adr003"],
            )

            # Revert mutation
            target.write_text(orig_content, encoding="utf-8")

            caught = any(expected_err in e for e in errs)
            if not caught:
                print(f"FAIL: Mutation {file_key} [{orig_str!r} -> {mut_str!r}] was NOT caught by {expected_err}", file=sys.stderr)
                all_passed = False
            else:
                print(f"  [ok] Mutation {file_key} caught by {expected_err}")

    if all_passed:
        print(f"All {len(mutations)} mutations caught deterministically.")
        return 0
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selftest", action="store_true", help="Run negative mutation self-test battery")
    args = parser.parse_args()

    if args.selftest:
        return run_selftest()

    errors = check_controls()
    if errors:
        print("BLE record structural control violations found:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print("BLE record layer structural controls: ALL PASSED (BR01-BR23).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
