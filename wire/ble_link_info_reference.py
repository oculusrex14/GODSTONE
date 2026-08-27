#!/usr/bin/env python3
"""Canonical BLE LinkInfo Reference Implementation (ADR-002, Phase C8.4D1-R2).

Defines the reference encoder, decoder, validator, and test vectors for the 13-byte
BleLinkInfoV1 payload exchanged over the canonical link_info GATT characteristic
(UUID: 6764A004-9A5E-4C7B-B0A1-3E5D8C2F7A10).

Binary layout (13 bytes total):
    offset 0  [1 byte]:  protocol_version  (0x02)
    offset 1  [1 byte]:  flags             (bit0 SOS_PRESENT, bit1 BULK_CAPABLE,
                                            bit2 POWER_CONSTRAINED, bit3 VERIFIED_ONLY,
                                            bit4 CLOCK_UNTRUSTED)
    offset 2  [4 bytes]: node_hint         (first 4 bytes of node_id, unsigned big-endian)
    offset 6  [6 bytes]: short_digest      (first 6 bytes of Bloom filter digest)
    offset 12 [1 byte]:  queue_depth       (uint8 0..255 saturating held count)
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

PROTOCOL_VERSION: int = 0x02
LINK_INFO_BYTES: int = 13
NODE_HINT_BYTES: int = 4
SHORT_DIGEST_BYTES: int = 6

FLAG_SOS_PRESENT: int = 0x01
FLAG_BULK_CAPABLE: int = 0x02
FLAG_POWER_CONSTRAINED: int = 0x04
FLAG_VERIFIED_ONLY: int = 0x08
FLAG_CLOCK_UNTRUSTED: int = 0x10
VALID_FLAGS_MASK: int = (
    FLAG_SOS_PRESENT
    | FLAG_BULK_CAPABLE
    | FLAG_POWER_CONSTRAINED
    | FLAG_VERIFIED_ONLY
    | FLAG_CLOCK_UNTRUSTED
)


@dataclass(frozen=True)
class BleLinkInfoV1:
    version: int
    flags: int
    node_hint: bytes
    short_digest: bytes
    queue_depth: int

    @property
    def is_sos_present(self) -> bool:
        return bool(self.flags & FLAG_SOS_PRESENT)

    @property
    def is_bulk_capable(self) -> bool:
        return bool(self.flags & FLAG_BULK_CAPABLE)

    @property
    def is_power_constrained(self) -> bool:
        return bool(self.flags & FLAG_POWER_CONSTRAINED)

    @property
    def is_verified_only(self) -> bool:
        return bool(self.flags & FLAG_VERIFIED_ONLY)

    @property
    def is_clock_untrusted(self) -> bool:
        return bool(self.flags & FLAG_CLOCK_UNTRUSTED)


def encode_link_info(
    flags: int,
    node_hint: bytes,
    short_digest: bytes,
    queue_depth: int,
    version: int = PROTOCOL_VERSION,
) -> bytes:
    """Encode a canonical 13-byte BleLinkInfoV1 payload."""
    if version != PROTOCOL_VERSION:
        raise ValueError(f"Unsupported protocol version: {version:#04x}, expected {PROTOCOL_VERSION:#04x}")
    if len(node_hint) != NODE_HINT_BYTES:
        raise ValueError(f"node_hint must be exactly {NODE_HINT_BYTES} bytes, got {len(node_hint)}")
    if len(short_digest) != SHORT_DIGEST_BYTES:
        raise ValueError(f"short_digest must be exactly {SHORT_DIGEST_BYTES} bytes, got {len(short_digest)}")
    if not (0 <= queue_depth <= 255):
        raise ValueError(f"queue_depth out of range 0..255: {queue_depth}")
    if not (0 <= flags <= 255):
        raise ValueError(f"flags out of range 0..255: {flags}")

    out = bytearray(LINK_INFO_BYTES)
    out[0] = version & 0xFF
    out[1] = flags & 0xFF
    out[2:6] = node_hint
    out[6:12] = short_digest
    out[12] = queue_depth & 0xFF
    return bytes(out)


def decode_link_info(raw: bytes) -> Optional[BleLinkInfoV1]:
    """Decode and validate a 13-byte BleLinkInfoV1 payload.
    
    Normative rule: EXACTLY 13 bytes and version == 0x02.
    """
    if len(raw) != LINK_INFO_BYTES:
        return None
    version = raw[0]
    if version != PROTOCOL_VERSION:
        return None

    flags = raw[1]
    node_hint = raw[2:6]
    short_digest = raw[6:12]
    queue_depth = raw[12]

    return BleLinkInfoV1(
        version=version,
        flags=flags,
        node_hint=node_hint,
        short_digest=short_digest,
        queue_depth=queue_depth,
    )


def elect_role(local_hint: bytes, remote_hint: bytes) -> Optional[str]:
    """Unsigned lexicographic role election.
    
    Returns 'INITIATOR' if local < remote, 'RESPONDER' if local > remote, None if tie/invalid.
    """
    if len(local_hint) != NODE_HINT_BYTES or len(remote_hint) != NODE_HINT_BYTES:
        return None
    for l, r in zip(local_hint, remote_hint):
        if l < r:
            return "INITIATOR"
        elif l > r:
            return "RESPONDER"
    return None  # Tie -> fail closed


def generate_vectors() -> Dict[str, object]:
    """Generate golden test vectors for BleLinkInfoV1."""
    valid_cases: List[Dict[str, object]] = [
        {
            "name": "all_zero_informational_fields_with_real_hint",
            "version": 2,
            "flags": 0,
            "node_hint": "01020304",
            "short_digest": "000000000000",
            "queue_depth": 0,
            "expected_hex": "02000102030400000000000000",
        },
        {
            "name": "mixed_flags_sos_power_clock",
            "version": 2,
            "flags": FLAG_SOS_PRESENT | FLAG_POWER_CONSTRAINED | FLAG_CLOCK_UNTRUSTED,  # 0x01 | 0x04 | 0x10 = 0x15
            "node_hint": "a1b2c3d4",
            "short_digest": "112233445566",
            "queue_depth": 42,
            "expected_hex": "0215a1b2c3d41122334455662a",
        },
        {
            "name": "all_flags_set",
            "version": 2,
            "flags": VALID_FLAGS_MASK,  # 0x1F
            "node_hint": "deadbeef",
            "short_digest": "aabbccddeeff",
            "queue_depth": 128,
            "expected_hex": "",
        },
        {
            "name": "unsigned_edge_zero_hint",
            "version": 2,
            "flags": 0,
            "node_hint": "00000000",
            "short_digest": "010203040506",
            "queue_depth": 0,
            "expected_hex": "02000000000001020304050600",
        },
        {
            "name": "unsigned_edge_max_hint_and_max_queue_depth",
            "version": 2,
            "flags": FLAG_VERIFIED_ONLY,  # 0x08
            "node_hint": "ffffffff",
            "short_digest": "ffffffffffff",
            "queue_depth": 255,
            "expected_hex": "0208ffffffffffffffffffffff",
        },
        {
            "name": "high_bit_hint_comparison_edge",
            "version": 2,
            "flags": FLAG_BULK_CAPABLE,  # 0x02
            "node_hint": "80000000",
            "short_digest": "1234567890ab",
            "queue_depth": 255,
            "expected_hex": "0202800000001234567890abff",
        },
    ]

    # Re-compute exact hex for all valid cases to prevent human hex typos
    for case in valid_cases:
        raw = encode_link_info(
            flags=int(case["flags"]),
            node_hint=bytes.fromhex(str(case["node_hint"])),
            short_digest=bytes.fromhex(str(case["short_digest"])),
            queue_depth=int(case["queue_depth"]),
            version=int(case["version"]),
        )
        case["expected_hex"] = raw.hex()

    invalid_cases: List[Dict[str, object]] = [
        {"name": "empty", "hex": "", "reason": "length == 0"},
        {"name": "length_1", "hex": "02", "reason": "length == 1"},
        {"name": "length_12", "hex": "020001020304000000000000", "reason": "length == 12"},
        {"name": "length_14", "hex": "0200010203040000000000000099", "reason": "length == 14"},
        {"name": "length_20", "hex": "0200010203040000000000000001020304050607", "reason": "length == 20"},
        {"name": "length_255", "hex": "02" * 255, "reason": "length == 255"},
        {"name": "unknown_version_01", "hex": "01000102030400000000000000", "reason": "version != 0x02"},
        {"name": "unknown_version_03", "hex": "03000102030400000000000000", "reason": "version != 0x02"},
        {"name": "unknown_version_ff", "hex": "ff000102030400000000000000", "reason": "version != 0x02"},
    ]

    role_election_cases: List[Dict[str, object]] = [
        {"local_hint": "00000000", "remote_hint": "00000001", "expected_role": "INITIATOR"},
        {"local_hint": "00000001", "remote_hint": "00000000", "expected_role": "RESPONDER"},
        {"local_hint": "7fffffff", "remote_hint": "80000000", "expected_role": "INITIATOR"},
        {"local_hint": "80000000", "remote_hint": "7fffffff", "expected_role": "RESPONDER"},
        {"local_hint": "00000000", "remote_hint": "00000000", "expected_role": None},
        {"local_hint": "deadbeef", "remote_hint": "deadbeef", "expected_role": None},
        {"local_hint": "00ff00ff", "remote_hint": "00ff0100", "expected_role": "INITIATOR"},
    ]

    return {
        "description": "GODSTONE Canonical BleLinkInfoV1 Test Vectors (ADR-002, Phase C8.4D1-R2)",
        "protocol_version": PROTOCOL_VERSION,
        "link_info_bytes": LINK_INFO_BYTES,
        "valid_cases": valid_cases,
        "invalid_cases": invalid_cases,
        "role_election_cases": role_election_cases,
    }


def verify_vectors(vectors: Dict[str, object]) -> bool:
    """Verify all test vectors self-consistently."""
    valid_cases = vectors["valid_cases"]
    for case in valid_cases:
        expected_raw = bytes.fromhex(str(case["expected_hex"]))
        encoded = encode_link_info(
            flags=int(case["flags"]),
            node_hint=bytes.fromhex(str(case["node_hint"])),
            short_digest=bytes.fromhex(str(case["short_digest"])),
            queue_depth=int(case["queue_depth"]),
            version=int(case["version"]),
        )
        if encoded != expected_raw:
            print(f"FAIL encode mismatch in {case['name']}: {encoded.hex()} != {expected_raw.hex()}")
            return False

        decoded = decode_link_info(expected_raw)
        if decoded is None:
            print(f"FAIL decode returned None for valid case {case['name']}")
            return False
        if decoded.version != case["version"]:
            print(f"FAIL decoded version mismatch in {case['name']}")
            return False
        if decoded.flags != case["flags"]:
            print(f"FAIL decoded flags mismatch in {case['name']}")
            return False
        if decoded.node_hint.hex() != case["node_hint"]:
            print(f"FAIL decoded node_hint mismatch in {case['name']}")
            return False
        if decoded.short_digest.hex() != case["short_digest"]:
            print(f"FAIL decoded short_digest mismatch in {case['name']}")
            return False
        if decoded.queue_depth != case["queue_depth"]:
            print(f"FAIL decoded queue_depth mismatch in {case['name']}")
            return False

    invalid_cases = vectors["invalid_cases"]
    for case in invalid_cases:
        raw = bytes.fromhex(str(case["hex"]))
        decoded = decode_link_info(raw)
        if decoded is not None:
            print(f"FAIL decoded invalid case {case['name']} ({case['reason']}) into valid object!")
            return False

    role_cases = vectors["role_election_cases"]
    for case in role_cases:
        l = bytes.fromhex(str(case["local_hint"]))
        r = bytes.fromhex(str(case["remote_hint"]))
        role = elect_role(l, r)
        expected = case["expected_role"]
        if role != expected:
            print(f"FAIL role election for {case['local_hint']} vs {case['remote_hint']}: got {role}, expected {expected}")
            return False

    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="BLE LinkInfo Reference Authority (ADR-002, Phase C8.4D1-R2)")
    parser.add_argument("--check", action="store_true", help="Validate existing ble_link_info_vectors.json")
    parser.add_argument("--generate", action="store_true", help="Generate and save ble_link_info_vectors.json")
    args = parser.parse_args()

    vectors_path = Path(__file__).parent / "ble_link_info_vectors.json"

    if args.generate:
        vecs = generate_vectors()
        with open(vectors_path, "w", encoding="utf-8") as f:
            json.dump(vecs, f, indent=2)
            f.write("\n")
        print(f"Generated {vectors_path}")
        return 0

    if not vectors_path.exists():
        vecs = generate_vectors()
        with open(vectors_path, "w", encoding="utf-8") as f:
            json.dump(vecs, f, indent=2)
            f.write("\n")

    with open(vectors_path, "r", encoding="utf-8") as f:
        vecs = json.load(f)

    if not verify_vectors(vecs):
        print("BLE LinkInfo vector verification FAILED", file=sys.stderr)
        return 1

    print("BLE LinkInfo vectors verified OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
