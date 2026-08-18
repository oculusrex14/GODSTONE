#!/usr/bin/env python3
"""Canonical IdentityBindingV1 reference implementation (ADR-003, Phase C8.1A).

Provides canonical parsing, serialization, preimage construction, node_id
derivation, and Ed25519 signature verification for IdentityBindingV1.

Binary layout (133 bytes total):
    version:               uint8     [1 byte]   (0x01)
    generation:            uint32_be [4 bytes]
    signing_public_key:    bytes     [32 bytes] (Ed25519)
    static_dh_public_key:  bytes     [32 bytes] (X25519)
    signature:             bytes     [64 bytes] (Ed25519)

Preimage (80 bytes total):
    b"GMP2-IDBIND" (11) || version[1] (0x01) || generation_be[4] || signing_public_key[32] || static_dh_public_key[32]

Derived node_id:
    BLAKE2s-128(signing_public_key) [16 bytes]
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.exceptions import InvalidSignature

VERSION: int = 1
DOMAIN: bytes = b"GMP2-IDBIND"
DOMAIN_LENGTH: int = 11
PREIMAGE_LENGTH: int = 80
SERIALIZED_LENGTH: int = 133
SIGNING_PUBLIC_KEY_LENGTH: int = 32
STATIC_DH_PUBLIC_KEY_LENGTH: int = 32
SIGNATURE_LENGTH: int = 64
NODE_ID_LENGTH: int = 16
NODE_HINT_LENGTH: int = 4
MAX_GENERATION: int = 0xFFFFFFFF


def uint32_be(val: int) -> bytes:
    """Encode an unsigned 32-bit integer as 4-byte big-endian."""
    if not (0 <= val <= MAX_GENERATION):
        raise ValueError(f"generation out of range: {val}")
    return val.to_bytes(4, "big")


def derive_node_id(signing_public_key: bytes) -> bytes:
    """Derive full 16-byte node_id as BLAKE2s-128(signing_public_key)."""
    if len(signing_public_key) != SIGNING_PUBLIC_KEY_LENGTH:
        raise ValueError(f"signing_public_key must be 32 bytes, got {len(signing_public_key)}")
    return hashlib.blake2s(signing_public_key, digest_size=NODE_ID_LENGTH).digest()


def derive_node_hint(node_id_bytes: bytes) -> bytes:
    """Derive 4-byte node_hint as first4(node_id)."""
    if len(node_id_bytes) != NODE_ID_LENGTH:
        raise ValueError(f"node_id must be 16 bytes, got {len(node_id_bytes)}")
    return node_id_bytes[:NODE_HINT_LENGTH]


def identity_binding_preimage(
    generation: int,
    signing_public_key: bytes,
    static_dh_public_key: bytes,
    version: int = VERSION,
) -> bytes:
    """Construct canonical 80-byte signature preimage for IdentityBindingV1."""
    if version != VERSION:
        raise ValueError(f"unsupported version: {version}")
    if len(signing_public_key) != SIGNING_PUBLIC_KEY_LENGTH:
        raise ValueError(f"signing_public_key must be 32 bytes, got {len(signing_public_key)}")
    if len(static_dh_public_key) != STATIC_DH_PUBLIC_KEY_LENGTH:
        raise ValueError(f"static_dh_public_key must be 32 bytes, got {len(static_dh_public_key)}")
    preimage = DOMAIN + bytes([version]) + uint32_be(generation) + signing_public_key + static_dh_public_key
    if len(preimage) != PREIMAGE_LENGTH:
        raise ValueError(f"preimage length must be {PREIMAGE_LENGTH}, got {len(preimage)}")
    return preimage


def serialize_identity_binding(
    generation: int,
    signing_public_key: bytes,
    static_dh_public_key: bytes,
    signature: bytes,
    version: int = VERSION,
) -> bytes:
    """Serialize IdentityBindingV1 into exact 133-byte canonical payload."""
    if version != VERSION:
        raise ValueError(f"unsupported version: {version}")
    if len(signing_public_key) != SIGNING_PUBLIC_KEY_LENGTH:
        raise ValueError(f"signing_public_key must be 32 bytes, got {len(signing_public_key)}")
    if len(static_dh_public_key) != STATIC_DH_PUBLIC_KEY_LENGTH:
        raise ValueError(f"static_dh_public_key must be 32 bytes, got {len(static_dh_public_key)}")
    if len(signature) != SIGNATURE_LENGTH:
        raise ValueError(f"signature must be 64 bytes, got {len(signature)}")
    serialized = bytes([version]) + uint32_be(generation) + signing_public_key + static_dh_public_key + signature
    if len(serialized) != SERIALIZED_LENGTH:
        raise ValueError(f"serialized length must be {SERIALIZED_LENGTH}, got {len(serialized)}")
    return serialized


def verify_identity_binding_signature(
    generation: int,
    signing_public_key: bytes,
    static_dh_public_key: bytes,
    signature: bytes,
    version: int = VERSION,
) -> bool:
    """Verify Ed25519 signature over canonical 80-byte preimage."""
    try:
        preimage = identity_binding_preimage(generation, signing_public_key, static_dh_public_key, version=version)
        pub_key = ed25519.Ed25519PublicKey.from_public_bytes(signing_public_key)
        pub_key.verify(signature, preimage)
        return True
    except (InvalidSignature, ValueError):
        return False


@dataclass(frozen=True)
class IdentityBindingV1:
    version: int
    generation: int
    signing_public_key: bytes
    static_dh_public_key: bytes
    signature: bytes

    @classmethod
    def parse(cls, data: bytes) -> IdentityBindingV1:
        if len(data) != SERIALIZED_LENGTH:
            raise ValueError(f"invalid serialized length: expected {SERIALIZED_LENGTH}, got {len(data)}")
        version = data[0]
        if version != VERSION:
            raise ValueError(f"unsupported version: {version}")
        generation = int.from_bytes(data[1:5], "big")
        signing_pub = data[5:37]
        static_pub = data[37:69]
        sig = data[69:133]
        return cls(
            version=version,
            generation=generation,
            signing_public_key=signing_pub,
            static_dh_public_key=static_pub,
            signature=sig,
        )

    def serialize(self) -> bytes:
        return serialize_identity_binding(
            self.generation,
            self.signing_public_key,
            self.static_dh_public_key,
            self.signature,
            version=self.version,
        )

    def verify_signature(self) -> bool:
        return verify_identity_binding_signature(
            self.generation,
            self.signing_public_key,
            self.static_dh_public_key,
            self.signature,
            version=self.version,
        )

    def derive_node_id(self) -> bytes:
        return derive_node_id(self.signing_public_key)
