#!/usr/bin/env python3
"""Generate deterministic KAT vector fixtures for IdentityBindingV1 (ADR-003, Phase C8.1A).

Locks three authoritative KAT vectors:
1. fresh_generation_zero: generation = 0
2. endian_lock: generation = 0x01020304 (16909060)
3. max_generation: generation = 0xFFFFFFFF (4294967295)
"""
from __future__ import annotations

import json
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric import ed25519, x25519
from cryptography.hazmat.primitives import serialization

from crypto.identity_binding import (
    VERSION,
    DOMAIN,
    PREIMAGE_LENGTH,
    SERIALIZED_LENGTH,
    identity_binding_preimage,
    serialize_identity_binding,
    derive_node_id,
)

FIXTURES = [
    {
        "name": "fresh_generation_zero",
        "generation": 0,
        "ed25519_seed_hex": "11" * 32,
        "x25519_priv_hex": "22" * 32,
    },
    {
        "name": "endian_lock",
        "generation": 0x01020304,
        "ed25519_seed_hex": bytes(range(32)).hex(),
        "x25519_priv_hex": bytes(range(0x20, 0x40)).hex(),
    },
    {
        "name": "max_generation",
        "generation": 0xFFFFFFFF,
        "ed25519_seed_hex": "a5" * 32,
        "x25519_priv_hex": "5a" * 32,
    },
]


def generate_vectors() -> dict:
    vectors = []
    for fix in FIXTURES:
        gen = fix["generation"]
        ed_seed = bytes.fromhex(fix["ed25519_seed_hex"])
        x_priv_bytes = bytes.fromhex(fix["x25519_priv_hex"])

        # Generate Ed25519 public key
        ed_priv = ed25519.Ed25519PrivateKey.from_private_bytes(ed_seed)
        signing_pub = ed_priv.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )

        # Generate X25519 public key
        x_priv = x25519.X25519PrivateKey.from_private_bytes(x_priv_bytes)
        static_pub = x_priv.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )

        node_id_bytes = derive_node_id(signing_pub)
        preimage = identity_binding_preimage(gen, signing_pub, static_pub, version=VERSION)
        sig = ed_priv.sign(preimage)
        serialized = serialize_identity_binding(gen, signing_pub, static_pub, sig, version=VERSION)

        vectors.append({
            "name": fix["name"],
            "generation": gen,
            "ed25519_private_seed": fix["ed25519_seed_hex"],
            "signing_public_key": signing_pub.hex(),
            "x25519_private_key": fix["x25519_priv_hex"],
            "static_dh_public_key": static_pub.hex(),
            "node_id": node_id_bytes.hex(),
            "preimage": preimage.hex(),
            "signature": sig.hex(),
            "serialized": serialized.hex(),
        })

    return {
        "schema": 1,
        "domain_ascii": DOMAIN.decode("ascii"),
        "version": VERSION,
        "preimage_length": PREIMAGE_LENGTH,
        "serialized_length": SERIALIZED_LENGTH,
        "vectors": vectors,
    }


def main() -> None:
    data = generate_vectors()
    out_path = Path(__file__).resolve().parent / "identity_binding_vectors.json"
    formatted = json.dumps(data, indent=2) + "\n"
    out_path.write_text(formatted, encoding="utf-8")
    print(f"Wrote {len(data['vectors'])} IdentityBindingV1 vectors to {out_path}")


if __name__ == "__main__":
    main()
