#!/usr/bin/env python3
"""Identity derivation chain: keys -> node_id -> node_hint -> prologue -> h0.

PROTOCOL.md section 2:

    identity_key    Ed25519 keypair    long-term, signs and authenticates
    static_dh_key   X25519 keypair     long-term, Noise static key
    node_id         BLAKE2s-128(identity_pub)   16 bytes, the node address

This module exists because pinning a Noise transcript is NOT sufficient to prove
two platforms can talk.

h is seeded from the prologue; the prologue is built from node_hint; node_hint
is the first 4 bytes of node_id. If a fixture pins a fixed prologue byte string,
both platforms reproduce every transcript step byte-for-byte and STILL fail on
real devices, because production derives the prologue from node_id -- which the
two platforms computed from different keys:

    Android Identity.kt:95      nodeIdOf(ed.pub)        -> Ed25519  (spec)
    iOS     MeshIdentity.swift  agreementKey.publicKey  -> X25519   (WRONG)

That is a divergence BEFORE the first DH, and no transcript-only test detects
it. Invariant D therefore pins this whole chain.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass

NODE_ID_BYTES = 16
NODE_HINT_BYTES = 4
PROLOGUE_MAGIC = b"GMP2"
PROTOCOL_NAME = b"Noise_XX_25519_ChaChaPoly_BLAKE2s"
HASHLEN = 32


def blake2s(data: bytes, digest_size: int = HASHLEN) -> bytes:
    return hashlib.blake2s(data, digest_size=digest_size).digest()


def node_id(identity_pub_ed25519: bytes, quirk_use_dh_key: bool = False,
            static_dh_pub: bytes | None = None) -> bytes:
    """PROTOCOL.md:49 -- BLAKE2s-128 of the Ed25519 identity public key."""
    if quirk_use_dh_key:
        if static_dh_pub is None:
            raise ValueError("quirk requires the X25519 key")
        return blake2s(static_dh_pub, NODE_ID_BYTES)
    if len(identity_pub_ed25519) != 32:
        raise ValueError("Ed25519 public key must be 32 bytes")
    return blake2s(identity_pub_ed25519, NODE_ID_BYTES)


def node_hint(nid: bytes) -> bytes:
    """First 4 bytes of node_id. Carried in the BLE advertisement AND the Noise
    prologue, which is why an error here is fatal twice over."""
    if len(nid) != NODE_ID_BYTES:
        raise ValueError("node_id must be 16 bytes")
    return nid[:NODE_HINT_BYTES]


def prologue(initiator_hint: bytes, responder_hint: bytes) -> bytes:
    """prologue = "GMP2" || initiator_hint || responder_hint."""
    if len(initiator_hint) != NODE_HINT_BYTES or len(responder_hint) != NODE_HINT_BYTES:
        raise ValueError("node hints are 4 bytes each")
    return PROLOGUE_MAGIC + initiator_hint + responder_hint


def initial_h(pro: bytes) -> bytes:
    """h after InitializeSymmetric(protocol_name) then MixHash(prologue)."""
    if len(PROTOCOL_NAME) <= HASHLEN:
        h = PROTOCOL_NAME + b"\x00" * (HASHLEN - len(PROTOCOL_NAME))
    else:
        h = blake2s(PROTOCOL_NAME)
    return blake2s(h + pro)


def call_sign_indices(nid: bytes, count: int = 6) -> list[int]:
    """11-bit indices read MSB-first from node_id.

    Both platforms must produce the same words for the same identity, or two
    people verifying by voice read different call signs and conclude they are
    being attacked.
    """
    out: list[int] = []
    acc = bits = idx = 0
    while len(out) < count:
        if bits < 11:
            acc = (acc << 8) | nid[idx % len(nid)]
            bits += 8
            idx += 1
            continue
        out.append((acc >> (bits - 11)) & 0x7FF)
        bits -= 11
    return out


@dataclass
class Identity:
    """One Ed25519 signing key, one X25519 agreement key."""
    identity_pub: bytes
    static_dh_pub: bytes

    def node_id(self, quirk_use_dh_key: bool = False) -> bytes:
        return node_id(self.identity_pub, quirk_use_dh_key, self.static_dh_pub)

    def node_hint(self, quirk_use_dh_key: bool = False) -> bytes:
        return node_hint(self.node_id(quirk_use_dh_key))

    def describe(self, quirk_use_dh_key: bool = False) -> dict:
        nid = self.node_id(quirk_use_dh_key)
        return {
            "identity_pub": self.identity_pub.hex(),
            "static_dh_pub": self.static_dh_pub.hex(),
            "node_id": nid.hex(),
            "node_hint": node_hint(nid).hex(),
            "call_sign_indices": call_sign_indices(nid),
        }
