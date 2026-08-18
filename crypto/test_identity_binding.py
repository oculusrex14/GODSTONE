#!/usr/bin/env python3
"""Conformance tests for IdentityBindingV1 reference implementation (ADR-003, Phase C8.1A).

Tests all 3 locked KAT vectors and proves negative rejection properties.
"""
from __future__ import annotations

import json
import unittest
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric import ed25519, x25519
from cryptography.hazmat.primitives import serialization

from crypto.identity_binding import (
    VERSION,
    DOMAIN,
    DOMAIN_LENGTH,
    PREIMAGE_LENGTH,
    SERIALIZED_LENGTH,
    IdentityBindingV1,
    identity_binding_preimage,
    serialize_identity_binding,
    verify_identity_binding_signature,
    derive_node_id,
    uint32_be,
)


class IdentityBindingConformanceTest(unittest.TestCase):
    def setUp(self) -> None:
        fixture_path = Path(__file__).resolve().parent / "identity_binding_vectors.json"
        self.fixtures = json.loads(fixture_path.read_text(encoding="utf-8"))

    def test_constants_and_lengths(self) -> None:
        self.assertEqual(len(DOMAIN), DOMAIN_LENGTH)
        self.assertEqual(DOMAIN, b"GMP2-IDBIND")
        self.assertEqual(PREIMAGE_LENGTH, 80)
        self.assertEqual(SERIALIZED_LENGTH, 133)
        self.assertEqual(VERSION, 1)

    def test_endian_lock_encoding(self) -> None:
        gen = 0x01020304
        encoded = uint32_be(gen)
        self.assertEqual(encoded, bytes([1, 2, 3, 4]))
        self.assertEqual(int.from_bytes(encoded, "big"), 16909060)

    def test_max_generation_unsigned_roundtrip(self) -> None:
        gen = 0xFFFFFFFF
        encoded = uint32_be(gen)
        self.assertEqual(encoded, bytes([0xFF, 0xFF, 0xFF, 0xFF]))
        self.assertEqual(int.from_bytes(encoded, "big"), 4294967295)

    def test_kat_vectors_reproduction(self) -> None:
        for vec in self.fixtures["vectors"]:
            name = vec["name"]
            gen = vec["generation"]
            ed_seed = bytes.fromhex(vec["ed25519_private_seed"])
            x_priv_bytes = bytes.fromhex(vec["x25519_private_key"])

            # 1. Regenerate keys
            ed_priv = ed25519.Ed25519PrivateKey.from_private_bytes(ed_seed)
            signing_pub = ed_priv.public_key().public_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PublicFormat.Raw,
            )
            self.assertEqual(signing_pub.hex(), vec["signing_public_key"], f"{name}: signing public key mismatch")

            x_priv = x25519.X25519PrivateKey.from_private_bytes(x_priv_bytes)
            static_pub = x_priv.public_key().public_bytes(
                encoding=serialization.Encoding.Raw,
                format=serialization.PublicFormat.Raw,
            )
            self.assertEqual(static_pub.hex(), vec["static_dh_public_key"], f"{name}: static public key mismatch")

            # 2. Derive node_id
            nid = derive_node_id(signing_pub)
            self.assertEqual(nid.hex(), vec["node_id"], f"{name}: node_id mismatch")
            self.assertEqual(len(nid), 16)

            # 3. Construct preimage
            preimage = identity_binding_preimage(gen, signing_pub, static_pub, version=VERSION)
            self.assertEqual(preimage.hex(), vec["preimage"], f"{name}: preimage mismatch")
            self.assertEqual(len(preimage), 80)

            # 4. Reproduce signature
            sig = ed_priv.sign(preimage)
            self.assertEqual(sig.hex(), vec["signature"], f"{name}: signature mismatch")
            self.assertEqual(len(sig), 64)

            # 5. Reproduce serialized
            serialized = serialize_identity_binding(gen, signing_pub, static_pub, sig, version=VERSION)
            self.assertEqual(serialized.hex(), vec["serialized"], f"{name}: serialized mismatch")
            self.assertEqual(len(serialized), 133)

            # 6. Verify signature via helper
            self.assertTrue(
                verify_identity_binding_signature(gen, signing_pub, static_pub, sig, version=VERSION),
                f"{name}: verify_identity_binding_signature failed",
            )

            # 7. Parse object and round-trip
            obj = IdentityBindingV1.parse(serialized)
            self.assertEqual(obj.version, VERSION)
            self.assertEqual(obj.generation, gen)
            self.assertEqual(obj.signing_public_key, signing_pub)
            self.assertEqual(obj.static_dh_public_key, static_pub)
            self.assertEqual(obj.signature, sig)
            self.assertEqual(obj.serialize(), serialized)
            self.assertEqual(obj.derive_node_id(), nid)
            self.assertTrue(obj.verify_signature())

    def test_negative_one_bit_signature_corruption(self) -> None:
        vec = self.fixtures["vectors"][0]
        gen = vec["generation"]
        signing_pub = bytes.fromhex(vec["signing_public_key"])
        static_pub = bytes.fromhex(vec["static_dh_public_key"])
        sig = bytearray(bytes.fromhex(vec["signature"]))

        # Flip 1 bit in signature
        sig[0] ^= 0x01
        self.assertFalse(verify_identity_binding_signature(gen, signing_pub, static_pub, bytes(sig)))

    def test_negative_wrong_signing_public_key(self) -> None:
        vec0 = self.fixtures["vectors"][0]
        vec1 = self.fixtures["vectors"][1]
        gen = vec0["generation"]
        wrong_signing_pub = bytes.fromhex(vec1["signing_public_key"])
        static_pub = bytes.fromhex(vec0["static_dh_public_key"])
        sig = bytes.fromhex(vec0["signature"])

        self.assertFalse(verify_identity_binding_signature(gen, wrong_signing_pub, static_pub, sig))

    def test_negative_changed_static_public_key(self) -> None:
        vec0 = self.fixtures["vectors"][0]
        vec1 = self.fixtures["vectors"][1]
        gen = vec0["generation"]
        signing_pub = bytes.fromhex(vec0["signing_public_key"])
        wrong_static_pub = bytes.fromhex(vec1["static_dh_public_key"])
        sig = bytes.fromhex(vec0["signature"])

        self.assertFalse(verify_identity_binding_signature(gen, signing_pub, wrong_static_pub, sig))

    def test_negative_changed_generation(self) -> None:
        vec = self.fixtures["vectors"][0]
        gen = 1  # Original was 0
        signing_pub = bytes.fromhex(vec["signing_public_key"])
        static_pub = bytes.fromhex(vec["static_dh_public_key"])
        sig = bytes.fromhex(vec["signature"])

        self.assertFalse(verify_identity_binding_signature(gen, signing_pub, static_pub, sig))

    def test_negative_truncated_serialized_payload(self) -> None:
        raw = bytes.fromhex(self.fixtures["vectors"][0]["serialized"])
        with self.assertRaises(ValueError):
            IdentityBindingV1.parse(raw[:132])
        with self.assertRaises(ValueError):
            IdentityBindingV1.parse(raw[:50])

    def test_negative_oversized_serialized_payload(self) -> None:
        raw = bytes.fromhex(self.fixtures["vectors"][0]["serialized"])
        with self.assertRaises(ValueError):
            IdentityBindingV1.parse(raw + b"\x00")

    def test_negative_unsupported_version(self) -> None:
        raw = bytearray(bytes.fromhex(self.fixtures["vectors"][0]["serialized"]))
        raw[0] = 0x02  # Version 2
        with self.assertRaises(ValueError):
            IdentityBindingV1.parse(bytes(raw))


if __name__ == "__main__":
    unittest.main()
