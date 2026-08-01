#!/usr/bin/env python3
"""Generate crypto/handshake_vectors.json -- the Invariant D fixture.

    python -m crypto.gen_vectors

Pins the FULL chain, not just the transcript:

    identity keys -> node_id -> node_hint -> prologue -> h0 -> XX transcript

Pinning only the transcript is a test that cannot see the defect it was written
to catch: a fixed prologue string makes both platforms reproduce every step
byte-for-byte while production still diverges at node_id.

Ephemeral keys are deterministic. Catastrophic in production; precisely what
makes a handshake checkable in CI without hardware.
"""
from __future__ import annotations

import json
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from . import derivation as D
from .noise_ref import PROTOCOL_NAME, run_handshake

OUT = Path(__file__).resolve().parent / "handshake_vectors.json"

SEEDS = {"initiator_static": 0x11, "initiator_ephemeral": 0x22,
         "responder_static": 0x33, "responder_ephemeral": 0x44,
         "initiator_identity": 0x55, "responder_identity": 0x66}


def x(seed: int) -> X25519PrivateKey:
    return X25519PrivateKey.from_private_bytes(bytes([seed]) * 32)


def ed_pub(seed: int) -> bytes:
    return (Ed25519PrivateKey.from_private_bytes(bytes([seed]) * 32)
            .public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))


def xpub(k: X25519PrivateKey) -> bytes:
    return k.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def build() -> dict:
    i_s, i_e = x(SEEDS["initiator_static"]), x(SEEDS["initiator_ephemeral"])
    r_s, r_e = x(SEEDS["responder_static"]), x(SEEDS["responder_ephemeral"])
    ini = D.Identity(ed_pub(SEEDS["initiator_identity"]), xpub(i_s))
    res = D.Identity(ed_pub(SEEDS["responder_identity"]), xpub(r_s))

    i_hint, r_hint = ini.node_hint(), res.node_hint()
    pro = D.prologue(i_hint, r_hint)
    h0 = D.initial_h(pro)
    ok = run_handshake(i_s, i_e, r_s, r_e, pro)

    negatives = {}
    for name, kw in (("quirk_hkdf_ios", {"quirk_hkdf_ios": True}),
                     ("quirk_nonce_be", {"quirk_nonce_be": True})):
        bad = run_handshake(i_s, i_e, r_s, r_e, pro, **kw)
        negatives[name] = {
            "description": {
                "quirk_hkdf_ios": "Hkdf.swift returned temp_key as ck and fed "
                                  "material||0x01 instead of 0x01",
                "quirk_nonce_be": "NoiseSession.swift used big-endian ChaCha "
                                  "nonces; spec 12.3 is little-endian",
            }[name],
            "must_differ_from_conformant": True,
            "handshake_hash": bad["handshake_hash"],
            "send_key": bad["send_key"],
            "differs": bad["handshake_hash"] != ok["handshake_hash"]
                       or bad["send_key"] != ok["send_key"],
        }

    bad_hint = ini.node_hint(quirk_use_dh_key=True)
    bad_pro = D.prologue(bad_hint, r_hint)
    negatives["quirk_nodeid_from_dh_key"] = {
        "description": "MeshIdentity.swift derived node_id from the X25519 "
                       "agreement key; PROTOCOL.md:49 specifies the Ed25519 "
                       "identity key. Diverges h BEFORE the first DH.",
        "must_differ_from_conformant": True,
        "node_hint": bad_hint.hex(),
        "prologue": bad_pro.hex(),
        "initial_h": D.initial_h(bad_pro).hex(),
        "differs": D.initial_h(bad_pro) != h0,
    }

    return {
        "_comment": "Invariant D fixture. Both platforms must reproduce every "
                    "value here byte-for-byte. Regenerate with "
                    "`python -m crypto.gen_vectors`.",
        "_conformance_status": "UNPINNED",
        "_conformance_note": (
            "noise_ref.py encodes Noise rev34 s.4.3 and s.12.3 as read and is "
            "self-consistent: sizes are [32,96,64] and transport round-trips "
            "both ways. It has NOT been checked against an EXTERNAL vector. "
            "Self-consistency proves nothing -- two implementations can agree "
            "and both be wrong, which is exactly the failure this fixture "
            "exists to catch. Drop a real vector file into "
            "crypto/cacophony_vectors.json and run "
            "`python -m crypto.cacophony --check --write-status`. "
            "See docs/PINNING_CACOPHONY.md."),
        "cacophony": None,
        "protocol_name": PROTOCOL_NAME.decode(),
        "hash": "BLAKE2s",
        "rfc7693_vectors": {
            "blake2s_256_abc":
                "508c5e8c327c14e2e1a72ba34eeb452f37458b209ed63a294d999b4c86675982",
            "blake2s_256_empty":
                "69217a3079908094e11121d042354a7c1f55b6482ca1a51e1b250dfd1ed0eef9",
        },
        "test_keys": {
            "_warning": "TEST ONLY. Deterministic ephemerals are catastrophic "
                        "in production and are what makes this CI-checkable.",
            **{f"{k}_priv": (bytes([v]) * 32).hex() for k, v in SEEDS.items()},
        },
        "derivation_chain": {
            "_comment": "PROTOCOL.md:49 node_id = BLAKE2s-128(identity_pub). "
                        "Pinned because h is seeded from the prologue, which is "
                        "built from node_hint. A transcript-only fixture cannot "
                        "see a node_id defect.",
            "initiator": ini.describe(),
            "responder": res.describe(),
            "prologue": pro.hex(),
            "initial_h": h0.hex(),
        },
        "handshake": {
            "pattern": "XX",
            "messages": ok["messages"],
            "message_sizes": ok["message_sizes"],
            "handshake_hash": ok["handshake_hash"],
            "send_key": ok["send_key"],
            "recv_key": ok["recv_key"],
            "initiator_trace": ok["initiator_trace"],
            "responder_trace": ok["responder_trace"],
        },
        "negative_vectors": negatives,
    }


def main() -> int:
    data = build()
    OUT.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    hs = data["handshake"]
    print(f"wrote {OUT.name}")
    print(f"  sizes            {hs['message_sizes']}")
    print(f"  trace steps/side {len(hs['initiator_trace'])}")
    print(f"  prologue         {data['derivation_chain']['prologue']}")
    print(f"  status           {data['_conformance_status']}")
    for k, v in data["negative_vectors"].items():
        print(f"  negative {k:<28} differs={v['differs']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
