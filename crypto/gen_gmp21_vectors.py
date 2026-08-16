#!/usr/bin/env python3
"""Generate crypto/gmp21_vectors.json -- the locked GMP/2.1 byte-parity fixture.

    python -m crypto.gen_gmp21_vectors

Pins the three ADR-001 §3 content-derived primitives (msg_id, bloom, PoW) so
the Android and iOS runtimes can be held to byte-for-byte equality against an
independent Python (hashlib.blake2s, RFC 7693) reference. The platform test
suites transcribe these values as hex literals (mirroring WireV2VectorTest);
this file is the single source of truth.

Determinism: every input is fixed and the PoW nonce search starts from zero
and increments big-endian, so regeneration reproduces the committed bytes
exactly. Production mine() uses a SecureRandom start nonce -- only the KAT
search is deterministic.
"""
from __future__ import annotations

import json
from pathlib import Path

from . import gmp21 as G

OUT = Path(__file__).resolve().parent / "gmp21_vectors.json"

SENDER_A = bytes(range(16))                 # 000102...0f
SENDER_B = bytes([0xAA] * 16)               # aaaa...aa
NONCE_ZERO = bytes(16)                      # 0000...00
NONCE_ONE = bytes([0x01] * 16)              # 0101...01
NONCE_KAT = bytes.fromhex("00112233445566778899aabbccddeeff")
PAYLOAD_HELP = b"help"
PAYLOAD_SOS = b"SOS payload"
TYPE_MESSAGE = 0x18
TYPE_SOS = 0xF0


def _msg_id_case(name: str, sender: bytes, created_at: int, nonce: bytes, payload: bytes) -> dict:
    mid = G.msg_id(sender, created_at, nonce, payload)
    return {
        "name": name,
        "sender_node_id": sender.hex(),
        "created_at_epoch_seconds": created_at,
        "created_at_le": G.uint32_le(created_at).hex(),
        "message_nonce": nonce.hex(),
        "payload": payload.hex(),
        "payload_utf8": payload.decode("utf-8", "replace") if payload else "",
        "msg_id": mid.hex(),
    }


def _bloom_case(name: str, msg_ids: list[bytes]) -> dict:
    indices = []
    for mid in msg_ids:
        indices.append({
            "msg_id": mid.hex(),
            "round_indices": [G.bloom_index(mid, r) for r in range(G.BLOOM_HASHES)],
        })
    filt = G.bloom_build(msg_ids)
    return {
        "name": name,
        "ids": indices,
        "filter": filt.hex(),
        "short_digest": G.bloom_short_digest(filt).hex(),
        "size_bytes": G.BLOOM_SIZE_BYTES,
        "hashes": G.BLOOM_HASHES,
    }


def _pow_kat(name: str, sender: bytes, created_at: int, type_code: int,
             plaintext: bytes, target_bits: int) -> dict:
    created_le = G.uint32_le(created_at)
    nonce, digest = G.pow_mine(sender, created_le, type_code, plaintext,
                               target_bits=target_bits)
    return {
        "name": name,
        "sender_node_id": sender.hex(),
        "created_at_epoch_seconds": created_at,
        "created_at_le": created_le.hex(),
        "type_code": type_code,
        "plaintext": plaintext.hex(),
        "plaintext_utf8": plaintext.decode("utf-8", "replace"),
        "target_bits": target_bits,
        "pow_nonce": nonce.hex(),
        "blake2s_256": digest.hex(),
        "verified": G.pow_verify(nonce, sender, created_le, type_code, plaintext,
                                 target_bits),
    }


def build() -> dict:
    # ---- msg_id: three positive cases + byte-order and nonce mutation negatives ----
    m1 = _msg_id_case("empty_payload_zero_time_zero_nonce", SENDER_A, 0, NONCE_ZERO, b"")
    m2 = _msg_id_case("help_epoch_1_nonce_all_ones", SENDER_A, 1, NONCE_ONE, PAYLOAD_HELP)
    m3 = _msg_id_case("sos_payload_real_epoch_kat_nonce", SENDER_B, 1700000000, NONCE_KAT, PAYLOAD_SOS)

    # Mutation: same inputs as m2 but created_at encoded BIG-endian.
    import hashlib
    be_msg_id = hashlib.blake2s(
        G.MSG_ID_DOMAIN + SENDER_A + G.uint32_be(1) + NONCE_ONE + PAYLOAD_HELP, digest_size=16).hexdigest()
    msg_id_negative_be = {
        "name": "help_epoch_1_big_endian_created_at_must_differ",
        "description": "same inputs as help_epoch_1 but created_at encoded uint32_be.",
        "sender_node_id": SENDER_A.hex(),
        "created_at_be": G.uint32_be(1).hex(),
        "message_nonce": NONCE_ONE.hex(),
        "payload": PAYLOAD_HELP.hex(),
        "msg_id_be": be_msg_id,
        "must_differ_from": m2["msg_id"],
        "differs": be_msg_id != m2["msg_id"],
    }

    # Distinct nonce mutation: same content but NONCE_ZERO instead of NONCE_ONE
    zero_nonce_msg_id = G.msg_id(SENDER_A, 1, NONCE_ZERO, PAYLOAD_HELP).hex()
    msg_id_negative_nonce = {
        "name": "help_epoch_1_distinct_nonce_must_differ",
        "description": "same content and time as help_epoch_1 but distinct message_nonce (zero).",
        "sender_node_id": SENDER_A.hex(),
        "created_at_epoch_seconds": 1,
        "message_nonce": NONCE_ZERO.hex(),
        "payload": PAYLOAD_HELP.hex(),
        "msg_id_zero_nonce": zero_nonce_msg_id,
        "must_differ_from": m2["msg_id"],
        "differs": zero_nonce_msg_id != m2["msg_id"],
    }

    # ---- bloom: single-id and three-id filters built from the msg_id cases ----
    mid1 = bytes.fromhex(m1["msg_id"])
    mid2 = bytes.fromhex(m2["msg_id"])
    mid3 = bytes.fromhex(m3["msg_id"])
    bloom_single = _bloom_case("single_id", [mid2])
    bloom_triple = _bloom_case("three_ids", [mid1, mid2, mid3])

    # ---- PoW: production 20-bit KAT + a fast 8-bit KAT ----
    pow_20 = _pow_kat("pow_20bit_message_help", SENDER_A, 1, TYPE_MESSAGE,
                      PAYLOAD_HELP, G.POW_TARGET_BITS)
    pow_8 = _pow_kat("pow_8bit_message_help", SENDER_A, 1, TYPE_MESSAGE,
                      PAYLOAD_HELP, 8)

    return {
        "_comment": "GMP/2.1 locked byte-parity fixture (ADR-001 §3). Both "
                    "platforms must reproduce every value here byte-for-byte. "
                    "Regenerate with `python -m crypto.gen_gmp21_vectors`. The "
                    "platform tests transcribe these as hex literals; this file "
                    "is the single source of truth.",
        "reference": "crypto/gmp21.py (hashlib.blake2s, RFC 7693)",
        "constants": {
            "msg_id_domain": G.MSG_ID_DOMAIN.decode("ascii"),
            "msg_id_domain_bytes": len(G.MSG_ID_DOMAIN),
            "message_nonce_bytes": G.MESSAGE_NONCE_BYTES,
            "msg_id_bytes": G.MSG_ID_BYTES,
            "bloom_size_bits": G.BLOOM_SIZE_BITS,
            "bloom_size_bytes": G.BLOOM_SIZE_BYTES,
            "bloom_short_bytes": G.BLOOM_SHORT_BYTES,
            "bloom_hashes": G.BLOOM_HASHES,
            "pow_nonce_bytes": G.POW_NONCE_BYTES,
            "pow_target_bits": G.POW_TARGET_BITS,
            "type_message": TYPE_MESSAGE,
            "type_sos": TYPE_SOS,
        },
        "msg_id": {
            "spec": "msg_id = BLAKE2s-128(b'GMP2-MSGID' ‖ sender[16] ‖ created_at_le[4] ‖ message_nonce[16] ‖ payload)",
            "cases": [m1, m2, m3],
            "negative": msg_id_negative_be,
            "negative_nonce": msg_id_negative_nonce,
        },
        "bloom": {
            "spec": "index = BLAKE2s-64(msg_id[16] ‖ uint32_be(round)) mod 4096; "
                    "4 rounds; 512-byte filter; 20-byte shortDigest",
            "cases": [bloom_single, bloom_triple],
        },
        "pow": {
            "spec": "BLAKE2s-256(pow_nonce[8] ‖ sender[16] ‖ created_at_le[4] ‖ "
                    "type_code[1] ‖ plaintext); top target_bits bits zero",
            "cases": [pow_20, pow_8],
        },
    }


def main() -> int:
    data = build()
    OUT.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {OUT.name}")
    print(f"  msg_id cases    {len(data['msg_id']['cases'])} "
          f"(neg differs={data['msg_id']['negative']['differs']})")
    print(f"  bloom cases     {len(data['bloom']['cases'])}")
    print(f"  pow cases       {len(data['pow']['cases'])} "
          f"(20-bit nonce={data['pow']['cases'][0]['pow_nonce']}, "
          f"8-bit nonce={data['pow']['cases'][1]['pow_nonce']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())