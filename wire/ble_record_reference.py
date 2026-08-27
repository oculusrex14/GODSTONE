#!/usr/bin/env python3
"""Canonical BLE Record Layer reference implementation (ADR-002, Phase C8.4C).

Pure record codec, fragmentation, and reassembly specification and reference.

Header layout (8 bytes total):
    offset 0 [1 byte]:  magic        (0x47, ASCII 'G')
    offset 1 [1 byte]:  record_type  (HS1=0x11, HS2=0x12, HS3=0x14, DATA=0x18, CLOSE=0x21)
    offset 2 [1 byte]:  record_seq   (uint8, connection-local, wraps modulo 256)
    offset 3 [1 byte]:  frag_index   (uint8, 0-based)
    offset 4 [1 byte]:  frag_count   (uint8, 1..64)
    offset 5 [2 bytes]: total_len    (uint16 big-endian, length of complete reassembled payload)
    offset 7 [1 byte]:  header_check (XOR of bytes 0..6)

Constants:
    HEADER_BYTES = 8
    MAX_RECORD = 16384
    MAX_FRAGMENTS = 64
    MAX_CONCURRENT = 4
    REASSEMBLY_TIMEOUT_SECONDS = 30
"""
from __future__ import annotations

import enum
import hashlib
import json
import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional, Set, Tuple

MAGIC: int = 0x47
HEADER_BYTES: int = 8
MAX_RECORD: int = 16384
MAX_FRAGMENTS: int = 64
MAX_CONCURRENT: int = 4
REASSEMBLY_TIMEOUT_SECONDS: int = 30


class BleRecordType(enum.IntEnum):
    HS1 = 0x11
    HS2 = 0x12
    HS3 = 0x14
    DATA = 0x18
    CLOSE = 0x21

    @classmethod
    def from_byte(cls, b: int) -> Optional[BleRecordType]:
        try:
            return cls(b)
        except ValueError:
            return None


def header_check(header_first_7_bytes: bytes) -> int:
    """Compute XOR of the first 7 bytes of the header."""
    if len(header_first_7_bytes) != 7:
        raise ValueError(f"header_check requires exactly 7 bytes, got {len(header_first_7_bytes)}")
    res = 0
    for b in header_first_7_bytes:
        res ^= b
    return res


def encode_header(
    record_type: BleRecordType | int,
    record_seq: int,
    frag_index: int,
    frag_count: int,
    total_len: int,
    magic: int = MAGIC,
) -> bytes:
    """Encode an 8-byte canonical BLE record header."""
    if isinstance(record_type, BleRecordType):
        type_val = record_type.value
    else:
        if BleRecordType.from_byte(record_type) is None:
            raise ValueError(f"Invalid record type: {record_type:#04x}")
        type_val = record_type

    if not (0 <= record_seq <= 255):
        raise ValueError(f"record_seq out of range 0..255: {record_seq}")
    if not (1 <= frag_count <= MAX_FRAGMENTS):
        raise ValueError(f"frag_count out of range 1..{MAX_FRAGMENTS}: {frag_count}")
    if not (0 <= frag_index < frag_count):
        raise ValueError(f"frag_index out of range 0..{frag_count - 1}: {frag_index}")
    if not (0 <= total_len <= MAX_RECORD):
        raise ValueError(f"total_len out of range 0..{MAX_RECORD}: {total_len}")

    raw_7 = bytes([
        magic,
        type_val,
        record_seq,
        frag_index,
        frag_count,
        (total_len >> 8) & 0xFF,
        total_len & 0xFF,
    ])
    chk = header_check(raw_7)
    return raw_7 + bytes([chk])


@dataclass(frozen=True)
class BleRecordHeader:
    magic: int
    record_type: BleRecordType
    record_seq: int
    frag_index: int
    frag_count: int
    total_len: int
    header_check: int


@dataclass(frozen=True)
class BleRecordFragment:
    header: BleRecordHeader
    payload: bytes


def decode_header(data: bytes) -> Optional[BleRecordHeader]:
    """Decode and validate an 8-byte BLE record header. Returns None if invalid."""
    if len(data) < HEADER_BYTES:
        return None

    magic = data[0]
    if magic != MAGIC:
        return None

    rec_type = BleRecordType.from_byte(data[1])
    if rec_type is None:
        return None

    record_seq = data[2]
    frag_index = data[3]
    frag_count = data[4]
    total_len = (data[5] << 8) | data[6]
    chk = data[7]

    if header_check(data[:7]) != chk:
        return None

    if not (1 <= frag_count <= MAX_FRAGMENTS):
        return None
    if not (0 <= frag_index < frag_count):
        return None
    if not (0 <= total_len <= MAX_RECORD):
        return None

    return BleRecordHeader(
        magic=magic,
        record_type=rec_type,
        record_seq=record_seq,
        frag_index=frag_index,
        frag_count=frag_count,
        total_len=total_len,
        header_check=chk,
    )


def canonical_fragment_bounds(total_len: int, frag_count: int, frag_index: int) -> Tuple[int, int]:
    """Compute canonical [start, end) byte offsets for fragment i under ADR-002 balanced stride."""
    if total_len == 0:
        if frag_count != 1 or frag_index != 0:
            raise ValueError(f"total_len=0 requires frag_count=1, frag_index=0; got count={frag_count}, index={frag_index}")
        return 0, 0

    if not (1 <= frag_count <= MAX_FRAGMENTS):
        raise ValueError(f"frag_count {frag_count} outside 1..{MAX_FRAGMENTS}")
    if not (0 <= frag_index < frag_count):
        raise ValueError(f"frag_index {frag_index} outside 0..{frag_count - 1}")

    stride = (total_len + frag_count - 1) // frag_count
    start = frag_index * stride
    if start >= total_len:
        raise ValueError(f"canonical start {start} >= total_len {total_len}")
    end = min(start + stride, total_len)
    return start, end


def decode_fragment(data: bytes) -> Optional[BleRecordFragment]:
    """Decode and validate a complete BLE record fragment. Returns None on validation failure."""
    if len(data) < HEADER_BYTES:
        return None

    hdr = decode_header(data[:HEADER_BYTES])
    if hdr is None:
        return None

    try:
        start, end = canonical_fragment_bounds(hdr.total_len, hdr.frag_count, hdr.frag_index)
    except ValueError:
        return None

    expected_payload_len = end - start
    actual_payload = data[HEADER_BYTES:]

    if len(actual_payload) != expected_payload_len:
        return None

    return BleRecordFragment(header=hdr, payload=actual_payload)


def fragment_record(
    record_type: BleRecordType | int,
    record_seq: int,
    payload: bytes,
    max_att_value_length: int,
) -> List[bytes]:
    """Fragment a complete record payload into canonical BLE record fragments."""
    capacity = max_att_value_length - HEADER_BYTES
    if capacity < 1:
        raise ValueError(f"max_att_value_length {max_att_value_length} must be >= {HEADER_BYTES + 1}")

    total_len = len(payload)
    if total_len > MAX_RECORD:
        raise ValueError(f"payload size {total_len} exceeds MAX_RECORD {MAX_RECORD}")

    if total_len == 0:
        hdr = encode_header(record_type, record_seq, 0, 1, 0)
        return [hdr]

    frag_count = (total_len + capacity - 1) // capacity
    if frag_count > MAX_FRAGMENTS:
        raise ValueError(f"frag_count {frag_count} exceeds MAX_FRAGMENTS {MAX_FRAGMENTS}")

    stride = (total_len + frag_count - 1) // frag_count
    fragments: List[bytes] = []

    for i in range(frag_count):
        start = i * stride
        end = min(start + stride, total_len)
        frag_payload = payload[start:end]
        hdr = encode_header(record_type, record_seq, i, frag_count, total_len)
        fragments.append(hdr + frag_payload)

    return fragments


@dataclass
class _InFlightAssembly:
    record_type: BleRecordType
    total_len: int
    frag_count: int
    stride: int
    received_indices: Set[int]
    buffer: bytearray
    created_time: float
    last_activity_time: float


@dataclass(frozen=True)
class ReassembledRecord:
    record_type: BleRecordType
    record_seq: int
    payload: bytes


class BleRecordReassembler:
    """Manages fragment reassembly for one BLE connection."""

    def __init__(self, time_provider: Optional[Callable[[], float]] = None):
        self._time_provider = time_provider if time_provider is not None else (lambda: 0.0)
        self._in_flight: Dict[int, _InFlightAssembly] = {}
        self._completed_fingerprints: Dict[int, str] = {}

    def _evict_expired(self, now: float) -> None:
        expired_seqs = [
            seq for seq, asm in self._in_flight.items()
            if (now - asm.last_activity_time) > REASSEMBLY_TIMEOUT_SECONDS
        ]
        for seq in expired_seqs:
            del self._in_flight[seq]

    def receive_fragment_bytes(self, raw_bytes: bytes) -> Optional[ReassembledRecord]:
        """Process raw fragment bytes. Returns ReassembledRecord upon completion, or None."""
        frag = decode_fragment(raw_bytes)
        if frag is None:
            return None
        return self.receive_fragment(frag)

    def receive_fragment(self, frag: BleRecordFragment) -> Optional[ReassembledRecord]:
        """Process a validated BleRecordFragment."""
        now = self._time_provider()
        self._evict_expired(now)

        hdr = frag.header
        seq = hdr.record_seq

        if seq not in self._in_flight:
            # Check capacity
            if len(self._in_flight) >= MAX_CONCURRENT:
                return None  # Reject 5th concurrent assembly

            stride = (hdr.total_len + hdr.frag_count - 1) // hdr.frag_count if hdr.total_len > 0 else 0
            asm = _InFlightAssembly(
                record_type=hdr.record_type,
                total_len=hdr.total_len,
                frag_count=hdr.frag_count,
                stride=stride,
                received_indices=set(),
                buffer=bytearray(hdr.total_len),
                created_time=now,
                last_activity_time=now,
            )
            self._in_flight[seq] = asm
        else:
            asm = self._in_flight[seq]

        # Validate metadata consistency
        if (
            asm.record_type != hdr.record_type
            or asm.total_len != hdr.total_len
            or asm.frag_count != hdr.frag_count
        ):
            # Conflicting metadata: invalidate and discard
            del self._in_flight[seq]
            return None

        asm.last_activity_time = now

        start, end = canonical_fragment_bounds(hdr.total_len, hdr.frag_count, hdr.frag_index)

        # Check duplicate fragment index
        if hdr.frag_index in asm.received_indices:
            existing_payload = bytes(asm.buffer[start:end])
            if existing_payload == frag.payload:
                # Idempotent duplicate: ignore
                return None
            else:
                # Conflicting duplicate: invalidate and discard
                del self._in_flight[seq]
                return None

        # Store fragment payload
        asm.buffer[start:end] = frag.payload
        asm.received_indices.add(hdr.frag_index)

        # Check if complete
        if len(asm.received_indices) == asm.frag_count:
            complete_payload = bytes(asm.buffer)
            del self._in_flight[seq]

            # Compute completed fingerprint (sha256 digest of type + seq + payload)
            fp = hashlib.sha256(bytes([hdr.record_type.value, seq]) + complete_payload).hexdigest()
            if self._completed_fingerprints.get(seq) == fp:
                # Retransmitted completion duplicate
                return None

            self._completed_fingerprints[seq] = fp
            return ReassembledRecord(
                record_type=hdr.record_type,
                record_seq=seq,
                payload=complete_payload,
            )

        return None

    def reset(self) -> None:
        """Reset all in-flight and completed state upon connection teardown."""
        self._in_flight.clear()
        self._completed_fingerprints.clear()


def generate_vectors() -> dict:
    """Generate canonical test vectors for BLE record layer verification."""
    positive_cases = []
    negative_cases = []

    # 1. Single-fragment HS1 (32 bytes)
    hs1_payload = bytes([i % 256 for i in range(32)])
    hs1_frags = fragment_record(BleRecordType.HS1, 0, hs1_payload, max_att_value_length=100)
    positive_cases.append({
        "name": "hs1_single_fragment_seq0",
        "record_type": "HS1",
        "record_type_code": 0x11,
        "record_seq": 0,
        "payload_hex": hs1_payload.hex(),
        "total_len": 32,
        "max_att_value_length": 100,
        "frag_count": 1,
        "fragments_hex": [f.hex() for f in hs1_frags],
    })

    # 2. Multi-fragment HS2 (229 bytes, max_att=60 -> capacity=52 -> frag_count=5, stride=46)
    hs2_payload = bytes([(i * 7 + 3) % 256 for i in range(229)])
    hs2_frags = fragment_record(BleRecordType.HS2, 1, hs2_payload, max_att_value_length=60)
    positive_cases.append({
        "name": "hs2_multi_fragment_seq1",
        "record_type": "HS2",
        "record_type_code": 0x12,
        "record_seq": 1,
        "payload_hex": hs2_payload.hex(),
        "total_len": 229,
        "max_att_value_length": 60,
        "frag_count": len(hs2_frags),
        "fragments_hex": [f.hex() for f in hs2_frags],
    })

    # 3. Multi-fragment HS3 (197 bytes, max_att=50 -> capacity=42 -> frag_count=5, stride=40)
    hs3_payload = bytes([(i * 13 + 7) % 256 for i in range(197)])
    hs3_frags = fragment_record(BleRecordType.HS3, 2, hs3_payload, max_att_value_length=50)
    positive_cases.append({
        "name": "hs3_multi_fragment_seq2",
        "record_type": "HS3",
        "record_type_code": 0x14,
        "record_seq": 2,
        "payload_hex": hs3_payload.hex(),
        "total_len": 197,
        "max_att_value_length": 50,
        "frag_count": len(hs3_frags),
        "fragments_hex": [f.hex() for f in hs3_frags],
    })

    # 4. Zero-length CLOSE (0 bytes)
    close_payload = b""
    close_frags = fragment_record(BleRecordType.CLOSE, 3, close_payload, max_att_value_length=100)
    positive_cases.append({
        "name": "close_zero_length_seq3",
        "record_type": "CLOSE",
        "record_type_code": 0x21,
        "record_seq": 3,
        "payload_hex": close_payload.hex(),
        "total_len": 0,
        "max_att_value_length": 100,
        "frag_count": 1,
        "fragments_hex": [f.hex() for f in close_frags],
    })

    # 5. Multi-fragment DATA (500 bytes, max_att=128 -> capacity=120 -> frag_count=5, stride=100)
    data_payload = bytes([(i * 17 + 1) % 256 for i in range(500)])
    data_frags = fragment_record(BleRecordType.DATA, 255, data_payload, max_att_value_length=128)
    positive_cases.append({
        "name": "data_multi_fragment_seq255",
        "record_type": "DATA",
        "record_type_code": 0x18,
        "record_seq": 255,
        "payload_hex": data_payload.hex(),
        "total_len": 500,
        "max_att_value_length": 128,
        "frag_count": len(data_frags),
        "fragments_hex": [f.hex() for f in data_frags],
    })

    # 6. Boundary MAX_RECORD (16384 bytes, max_att=264 -> capacity=256 -> frag_count=64, stride=256)
    max_payload = bytes([(i * 31) % 256 for i in range(16384)])
    max_frags = fragment_record(BleRecordType.DATA, 100, max_payload, max_att_value_length=264)
    positive_cases.append({
        "name": "data_max_record_16384_seq100",
        "record_type": "DATA",
        "record_type_code": 0x18,
        "record_seq": 100,
        "payload_hex": max_payload.hex(),
        "total_len": 16384,
        "max_att_value_length": 264,
        "frag_count": 64,
        "fragments_hex": [f.hex() for f in max_frags],
    })

    # Negative test vectors (raw invalid fragments that must fail decoding / validation)
    # 1. Truncated header (< 8 bytes)
    negative_cases.append({
        "name": "truncated_header_7_bytes",
        "raw_hex": "47110000010020",
        "expected_error": "TRUNCATED_HEADER",
    })

    # 2. Bad magic (0x48 != 0x47)
    bad_magic_hdr = bytes([0x48, 0x11, 0x00, 0x00, 0x01, 0x00, 0x20])
    bad_magic_chk = header_check(bad_magic_hdr)
    negative_cases.append({
        "name": "bad_magic_0x48",
        "raw_hex": (bad_magic_hdr + bytes([bad_magic_chk]) + hs1_payload).hex(),
        "expected_error": "BAD_MAGIC",
    })

    # 3. Unknown record type (0x99)
    bad_type_hdr = bytes([0x47, 0x99, 0x00, 0x00, 0x01, 0x00, 0x20])
    bad_type_chk = header_check(bad_type_hdr)
    negative_cases.append({
        "name": "unknown_record_type_0x99",
        "raw_hex": (bad_type_hdr + bytes([bad_type_chk]) + hs1_payload).hex(),
        "expected_error": "UNKNOWN_RECORD_TYPE",
    })

    # 4. Bad header XOR check
    corrupt_chk_hdr = encode_header(BleRecordType.HS1, 0, 0, 1, 32)
    corrupted_chk = corrupt_chk_hdr[:7] + bytes([corrupt_chk_hdr[7] ^ 0xFF])
    negative_cases.append({
        "name": "corrupt_header_xor_check",
        "raw_hex": (corrupted_chk + hs1_payload).hex(),
        "expected_error": "BAD_HEADER_CHECK",
    })

    # 5. frag_count 0
    hdr_fc0 = bytes([0x47, 0x11, 0x00, 0x00, 0x00, 0x00, 0x20])
    chk_fc0 = header_check(hdr_fc0)
    negative_cases.append({
        "name": "frag_count_zero",
        "raw_hex": (hdr_fc0 + bytes([chk_fc0]) + hs1_payload).hex(),
        "expected_error": "INVALID_FRAG_COUNT",
    })

    # 6. frag_count 65 (> 64)
    hdr_fc65 = bytes([0x47, 0x11, 0x00, 0x00, 65, 0x00, 0x20])
    chk_fc65 = header_check(hdr_fc65)
    negative_cases.append({
        "name": "frag_count_65_exceeds_max",
        "raw_hex": (hdr_fc65 + bytes([chk_fc65]) + hs1_payload).hex(),
        "expected_error": "INVALID_FRAG_COUNT",
    })

    # 7. frag_index == frag_count (frag_index 2, frag_count 2)
    hdr_idx_eq_cnt = bytes([0x47, 0x11, 0x00, 0x02, 0x02, 0x00, 0x20])
    chk_idx_eq_cnt = header_check(hdr_idx_eq_cnt)
    negative_cases.append({
        "name": "frag_index_equals_frag_count",
        "raw_hex": (hdr_idx_eq_cnt + bytes([chk_idx_eq_cnt]) + hs1_payload).hex(),
        "expected_error": "FRAG_INDEX_OUT_OF_BOUNDS",
    })

    # 8. total_len 16385 (> 16384)
    hdr_len_overflow = bytes([0x47, 0x18, 0x00, 0x00, 0x01, 0x40, 0x01])  # 0x4001 = 16385
    chk_len_overflow = header_check(hdr_len_overflow)
    negative_cases.append({
        "name": "total_len_16385_exceeds_max",
        "raw_hex": (hdr_len_overflow + bytes([chk_len_overflow])).hex(),
        "expected_error": "TOTAL_LEN_EXCEEDS_MAX",
    })

    # 9. Incorrect canonical fragment payload length (expected 32 bytes, provided 31 bytes)
    hdr_valid_hs1 = encode_header(BleRecordType.HS1, 0, 0, 1, 32)
    negative_cases.append({
        "name": "truncated_payload_31_bytes_instead_of_32",
        "raw_hex": (hdr_valid_hs1 + hs1_payload[:31]).hex(),
        "expected_error": "PAYLOAD_LENGTH_MISMATCH",
    })

    # 10. Excess payload bytes (expected 32 bytes, provided 33 bytes)
    negative_cases.append({
        "name": "excess_payload_33_bytes_instead_of_32",
        "raw_hex": (hdr_valid_hs1 + hs1_payload + b"\x00").hex(),
        "expected_error": "PAYLOAD_LENGTH_MISMATCH",
    })

    return {
        "version": 1,
        "spec": "ADR-002 Canonical BLE Record Layer",
        "constants": {
            "magic": 0x47,
            "header_bytes": 8,
            "max_record": 16384,
            "max_fragments": 64,
            "max_concurrent": 4,
            "reassembly_timeout_seconds": 30,
            "record_types": {
                "HS1": 0x11,
                "HS2": 0x12,
                "HS3": 0x14,
                "DATA": 0x18,
                "CLOSE": 0x21,
            },
        },
        "positive_cases": positive_cases,
        "negative_cases": negative_cases,
    }


def main() -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check that committed vectors match generator")
    parser.add_argument("--generate", action="store_true", help="Generate and commit vectors")
    args = parser.parse_args()

    vec_path = Path(__file__).parent / "ble_record_vectors.json"
    vectors = generate_vectors()
    vectors_json = json.dumps(vectors, indent=2) + "\n"

    if args.check:
        if not vec_path.exists():
            print(f"::error::Vectors file {vec_path} does not exist", file=sys.stderr)
            return 1
        committed = vec_path.read_text(encoding="utf-8")
        if committed != vectors_json:
            print(f"::error::Committed {vec_path} differs from generated vectors", file=sys.stderr)
            return 1
        print("BLE RECORD VECTORS: CHECK PASSED (byte-identical)")
        return 0

    if args.generate or not vec_path.exists():
        vec_path.write_text(vectors_json, encoding="utf-8")
        print(f"Wrote canonical BLE record vectors to {vec_path}")
        return 0

    # Default: self-test
    print("Running BLE record reference self-test...")
    # Self-test reassembly of all positive cases
    for case in vectors["positive_cases"]:
        reassembler = BleRecordReassembler()
        result = None
        for frag_hex in case["fragments_hex"]:
            raw = bytes.fromhex(frag_hex)
            res = reassembler.receive_fragment_bytes(raw)
            if res is not None:
                result = res
        assert result is not None, f"Failed to reassemble positive case {case['name']}"
        assert result.payload.hex() == case["payload_hex"], f"Payload mismatch in {case['name']}"
        assert result.record_type.value == case["record_type_code"], f"Record type mismatch in {case['name']}"
        assert result.record_seq == case["record_seq"], f"Record seq mismatch in {case['name']}"

    # Self-test negative cases
    for case in vectors["negative_cases"]:
        raw = bytes.fromhex(case["raw_hex"])
        frag = decode_fragment(raw)
        assert frag is None, f"Expected negative case {case['name']} to fail decode"

    print("BLE record reference self-test PASSED.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
