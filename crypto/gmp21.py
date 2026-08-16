"""GMP/2.1 cross-platform byte-parity reference (ADR-001 §3, C6.7.1).

The three content-derived primitives that MUST be byte-identical across the
Android (Kotlin/Bouncy Castle) and iOS (Swift/Blake2s) runtimes:

    msg_id   = BLAKE2s-128(b"GMP2-MSGID" ‖ sender[16] ‖ created_at_le[4] ‖ message_nonce[16] ‖ payload)   §3.3
    bloom    = index = BLAKE2s-64(msg_id[16] ‖ uint32_be(round)) mod 4096     §3.4
    pow      = BLAKE2s-256(b"GMP2-POW" ‖ pow_nonce[8] ‖ sender[16] ‖ created_at_le[4] ‖
                            message_nonce[16] ‖ type_code[1] ‖ plaintext), top TARGET_BITS bits 0  §3.3

This module is the INDEPENDENT Python reference (hashlib.blake2s, RFC 7693).
crypto/gmp21_vectors.json is generated from it by crypto.gen_gmp21_vectors;
the Android and iOS test suites transcribe those vectors as hex literals and
assert their runtimes reproduce them byte-for-byte. The fixture is produced by
this reference, so Python self-consistency (crypto.test_conformance) is
necessary-but-not-sufficient -- the platform tests are the real parity proof,
exactly as wire/golden_vectors.json is consumed by WireV2VectorTest on both
sides.

BYTE ORDER. ADR-001 §3.3 spells the msg_id input ``created_at_le`` and §3.4
spells the bloom input ``uint32_be(round)``. The contrast is deliberate:
``_le`` and ``_be`` are byte-order specifiers, not "the logical element". The
created_at epoch-second count is therefore LITTLE-ENDIAN in the msg_id and PoW
preimages, and the round index is BIG-ENDIAN in the bloom input. The sealed
payload's created_at field is also little-endian under GMP/2.1 so the recipient
reconstructs the PoW preimage from the sealed bytes without any conversion --
one canonical encoding for created_at across every GMP/2.1 derivation.
"""
from __future__ import annotations

import hashlib

MSG_ID_DOMAIN = b"GMP2-MSGID"
POW_DOMAIN = b"GMP2-POW"
MESSAGE_NONCE_BYTES = 16
NODE_ID_BYTES = 16
MSG_ID_BYTES = 16
BLOOM_SIZE_BITS = 4096
BLOOM_SIZE_BYTES = BLOOM_SIZE_BITS // 8   # 512
BLOOM_SHORT_BYTES = 20
BLOOM_HASHES = 4
POW_NONCE_BYTES = 8
POW_TARGET_BITS = 20


def blake2s(data: bytes, digest_size: int) -> bytes:
    return hashlib.blake2s(data, digest_size=digest_size).digest()


def uint32_le(value: int) -> bytes:
    """Little-endian uint32 of an epoch-second count (ADR-001 §3.3 created_at_le)."""
    return (value & 0xFFFFFFFF).to_bytes(4, "little")


def uint32_be(value: int) -> bytes:
    """Big-endian uint32 (ADR-001 §3.4 round index, and the legacy sealed spelling)."""
    return (value & 0xFFFFFFFF).to_bytes(4, "big")


def msg_id(sender_node_id: bytes, created_at_epoch_seconds: int, message_nonce: bytes, payload: bytes) -> bytes:
    """§3.3: BLAKE2s-128(b"GMP2-MSGID" ‖ sender[16] ‖ created_at_le[4] ‖ message_nonce[16] ‖ payload). 16 bytes."""
    if len(sender_node_id) != NODE_ID_BYTES:
        raise ValueError("sender_node_id must be 16 bytes")
    if len(message_nonce) != MESSAGE_NONCE_BYTES:
        raise ValueError("message_nonce must be 16 bytes")
    return blake2s(MSG_ID_DOMAIN + sender_node_id + uint32_le(created_at_epoch_seconds) + message_nonce + payload,
                   MSG_ID_BYTES)


def bloom_index(msg_id_bytes: bytes, round_index: int) -> int:
    """§3.4: BLAKE2s-64(msg_id[16] ‖ uint32_be(round)) mod 4096.

    Mirrors Android BloomDigest.index exactly: the 8-byte digest is read
    big-endian, shifted unsigned right by 1, masked to Int.MAX_VALUE (bit 31
    clear) and reduced mod 4096.
    """
    if len(msg_id_bytes) != MSG_ID_BYTES:
        raise ValueError("msg_id must be 16 bytes")
    digest = blake2s(msg_id_bytes + uint32_be(round_index), 8)
    v = int.from_bytes(digest, "big")          # 64-bit unsigned, big-endian
    return ((v >> 1) & 0x7FFFFFFF) % BLOOM_SIZE_BITS


def bloom_build(msg_ids: list[bytes]) -> bytes:
    """512-byte filter with the 4 indices of every id set, matching Android."""
    bits = bytearray(BLOOM_SIZE_BYTES)
    for mid in msg_ids:
        for r in range(BLOOM_HASHES):
            idx = bloom_index(mid, r)
            bits[idx >> 3] |= 1 << (idx & 7)
    return bytes(bits)


def bloom_short_digest(filter_bytes: bytes) -> bytes:
    """First 20 bytes of the 512-byte filter (carried in the BLE advertisement)."""
    if len(filter_bytes) != BLOOM_SIZE_BYTES:
        raise ValueError("filter must be 512 bytes")
    return filter_bytes[:BLOOM_SHORT_BYTES]


PRIORITY_DIRECT = 1
PRIORITY_GROUP = 2
PRIORITY_BROADCAST = 3


def pow_preimage(pow_nonce: bytes, sender_node_id: bytes,
                 created_at_le: bytes, message_nonce: bytes,
                 priority_code: int, type_code: int, plaintext: bytes) -> bytes:
    """§3.3: b"GMP2-POW" ‖ pow_nonce[8] ‖ sender[16] ‖ created_at_le[4] ‖ message_nonce[16] ‖ priority_code[1] ‖ type_code[1] ‖ plaintext."""
    if len(pow_nonce) != POW_NONCE_BYTES:
        raise ValueError("pow_nonce must be 8 bytes")
    if len(sender_node_id) != NODE_ID_BYTES:
        raise ValueError("sender_node_id must be 16 bytes")
    if len(created_at_le) != 4:
        raise ValueError("created_at must be 4 bytes")
    if len(message_nonce) != MESSAGE_NONCE_BYTES:
        raise ValueError("message_nonce must be 16 bytes")
    return (POW_DOMAIN + pow_nonce + sender_node_id + created_at_le
            + message_nonce + bytes([priority_code & 0xFF, type_code & 0xFF]) + plaintext)


def pow_digest(pow_nonce: bytes, sender_node_id: bytes, created_at_le: bytes,
               message_nonce: bytes, priority_code: int, type_code: int, plaintext: bytes) -> bytes:
    return blake2s(pow_preimage(pow_nonce, sender_node_id, created_at_le,
                                message_nonce, priority_code, type_code, plaintext), 32)


def pow_top_bits_zero(digest: bytes, target_bits: int) -> bool:
    """True iff the top [target_bits] bits of [digest] are all zero (big-endian)."""
    if not 1 <= target_bits <= 32:
        raise ValueError("target_bits out of range")
    remaining, i = target_bits, 0
    while remaining >= 8:
        if digest[i] != 0:
            return False
        remaining -= 8
        i += 1
    if remaining > 0:
        mask = (0xFF << (8 - remaining)) & 0xFF
        if digest[i] & mask != 0:
            return False
    return True


def pow_verify(pow_nonce: bytes, sender_node_id: bytes, created_at_le: bytes,
               message_nonce: bytes, priority_code: int, type_code: int, plaintext: bytes,
               target_bits: int = POW_TARGET_BITS) -> bool:
    return pow_top_bits_zero(
        pow_digest(pow_nonce, sender_node_id, created_at_le, message_nonce, priority_code, type_code, plaintext),
        target_bits)


def pow_mine(sender_node_id: bytes, created_at_le: bytes, message_nonce: bytes,
             priority_code: int, type_code: int, plaintext: bytes, target_bits: int = POW_TARGET_BITS,
             start_nonce: bytes = bytes(POW_NONCE_BYTES)) -> tuple[bytes, bytes]:
    """Deterministic nonce search (big-endian increment from start_nonce).

    Returns (nonce, digest). Used ONLY by the vector generator to pin a KAT --
    production uses a SecureRandom start nonce (Android ProofOfWork.mine /
    iOS ProofOfWork.mine). The increment is big-endian and unsigned, matching
    the Kotlin/Swift mine loops.
    """
    nonce = bytearray(start_nonce)
    if len(nonce) != POW_NONCE_BYTES:
        raise ValueError("start_nonce must be 8 bytes")
    while True:
        digest = pow_digest(nonce, sender_node_id, created_at_le, message_nonce, priority_code, type_code, plaintext)
        if pow_top_bits_zero(digest, target_bits):
            return bytes(nonce), digest
        # big-endian unsigned increment
        i = len(nonce) - 1
        while i >= 0:
            if nonce[i] == 0xFF:
                nonce[i] = 0
                i -= 1
            else:
                nonce[i] += 1
                break
        else:
            raise OverflowError("nonce space exhausted")