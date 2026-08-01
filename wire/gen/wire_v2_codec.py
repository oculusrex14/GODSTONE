"""GENERATED FROM wire/wire_v2.yaml -- DO NOT EDIT BY HAND.
Regenerate with `python -m wire.codegen`.
ci/check_parity.py Invariant A fails the build on any hand edit."""
from __future__ import annotations

MAGIC = 0x4753
VERSION = 0x02
HEADER_SIZE = 32
MAX_PAYLOAD = 60000
MAX_TTL = 16
DEFAULT_TTL = 12

TYPES = {
    "HELLO": 0x11,
    "DIGEST": 0x12,
    "WANT": 0x14,
    "MESSAGE": 0x18,
    "ACK": 0x21,
    "BULK_OFFER": 0x22,
    "BULK_CHUNK": 0x24,
    "PING": 0x28,
    "GOODBYE": 0x41,
    "SOS": 0xF0,
}
FLAGS = {
    "SEALED": 0x0001,
    "COMPRESSED": 0x0002,
    "FRAGMENTED": 0x0004,
    "HAS_POW": 0x0008,
    "ACK_REQ": 0x0010,
    "RELAY_OK": 0x0020,
    "PRIORITY_MASK": 0x0700,
}
NAME_BY_CODE = {v: k for k, v in TYPES.items()}


def crc16(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def encode(type_code: int, msg_id: bytes, routing_tag: bytes, ttl: int,
           hop_count: int, flags: int, payload: bytes) -> bytes:
    assert len(msg_id) == 16 and len(routing_tag) == 4
    assert 0 <= ttl <= MAX_TTL and 0 <= hop_count <= MAX_TTL
    assert len(payload) <= MAX_PAYLOAD
    h = (MAGIC.to_bytes(2, "big") + bytes([VERSION, type_code]) + msg_id
         + routing_tag + bytes([ttl, hop_count])
         + flags.to_bytes(2, "big") + len(payload).to_bytes(2, "big"))
    return h + crc16(h).to_bytes(2, "big") + payload


def decode(raw: bytes) -> dict | None:
    """Fail-closed: magic, version, type, CRC and length all validated first."""
    if len(raw) < HEADER_SIZE:
        return None
    if int.from_bytes(raw[0:2], "big") != MAGIC:
        return None
    if raw[2] != VERSION:
        return None
    if raw[3] not in NAME_BY_CODE:
        return None
    ttl = raw[24]
    if ttl > MAX_TTL:
        return None
    hop = raw[25]
    if hop > MAX_TTL:
        return None
    length = int.from_bytes(raw[28:30], "big")
    if int.from_bytes(raw[30:32], "big") != crc16(raw[0:HEADER_SIZE - 2]):
        return None
    if length > MAX_PAYLOAD or len(raw) != HEADER_SIZE + length:
        return None
    return {
        "type": NAME_BY_CODE[raw[3]],
        "msg_id": raw[4:20].hex(),
        "routing_tag": raw[20:24].hex(),
        "ttl": ttl,
        "hop_count": hop,
        "flags": int.from_bytes(raw[26:28], "big"),
        "payload": raw[HEADER_SIZE:].hex(),
    }
