#!/usr/bin/env python3
"""Generate deterministic KAT vector fixtures for SignedSosV1 (T38, section15).

Canonical signed-SOS envelope (wire_v2.yaml sos_requirements, amended by the
T38 ADR-005 record; ADR-003 identity binding reused from T13 verbatim):

    frame payload   = ASCII("SOS1") || signature(64) || unsigned payload
    unsigned payload = version(1)=0x01 || identityBinding(133)
                       || created_at_le(4) || time_quality(1) || nonce(16)
                       || body_len_be(2) || utf8 body (<= 400)
    msg_id          = BLAKE2s-128("GMP2-MSGID" || node_id || created_at_le
                                   || nonce || unsigned payload)
    signature       = Ed25519(signing seed,
                              msg_id || ASCII("SOS1") || unsigned payload)

The identity binding is the T13 IdentityBindingV1: serialized 133 =
version || generation_be(4) || signing_pub(32) || static_dh_pub(32) ||
binding_signature(64), the binding signature taken over the 80-byte preimage
"GMP2-IDBIND" || version || generation_be || signing_pub || static_dh_pub,
and node_id = BLAKE2s-128(signing_pub).

Signed-SOS and signed-DIRECT families are kept SEPARATE (section15). The
structural golden SOS fixtures in wire/golden_vectors.json keep their
deliberate all-zero signature slots untouched; the reject_zero_signature
vector here pins that runtime authentication refuses exactly that shape.

Deterministic by construction (fixed seeds and nonces; the pure-python
RFC 8032 reference signer of the T13 house). The JVM court transcribes the
accept vectors and asserts byte-for-byte authorship equality; the iOS court
authenticates them under its randomized signer (verify-direction only, per
the T35 cross-platform finding).
"""
from __future__ import annotations

import json
import struct
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric import ed25519, x25519
from cryptography.hazmat.primitives import serialization

from crypto.identity_binding import (
    VERSION as BINDING_VERSION,
    identity_binding_preimage,
    serialize_identity_binding,
    derive_node_id,
)
from crypto.gmp21 import msg_id, uint32_le

SOS_MAGIC = b"SOS1"
PAYLOAD_VERSION = 0x01
TIME_QUALITY_UNKNOWN = 0
TIME_QUALITY_USER_CONFIRMED = 1
TIME_QUALITY_AUTHENTICATED_SOURCE = 2
MAX_BODY_BYTES = 400

HEADER = {
    "type": 0xF0,               # wire_v2.yaml message_types.SOS (outer code kept)
    "ttl": 16,                  # FrameV2.max_ttl initial (emergency floods the mesh)
    "hop": 0,
    "flags": 0x0030,            # ACK_REQ | RELAY_OK (required by sos_requirements)
    "routing_tag": "00000000",  # broadcast: no destination hint is carried
}

FIXTURES = [
    {
        "name": "accept_signed_ok_min",
        "generation": 0,
        "ed25519_seed_hex": "b1" * 32,
        "x25519_priv_hex": "b2" * 32,
        "created_at": 1700000200,
        "time_quality": TIME_QUALITY_USER_CONFIRMED,
        "nonce_hex": "c3" * 16,
        "body_text": "help",
    },
    {
        "name": "accept_signed_ok_max_body",
        "generation": 0x01020304,
        "ed25519_seed_hex": "d4" * 32,
        "x25519_priv_hex": "4d" * 32,
        "created_at": 0xFFFFFFFF,
        "time_quality": TIME_QUALITY_AUTHENTICATED_SOURCE,
        "nonce_hex": "e5" * 16,
        # 100 x U+00E9 (2 bytes) + 50 x U+20AC (3 bytes)
        # + 12 x U+1F600 (4 bytes) = 200 + 150 + 48 = 398 UTF-8 bytes.
        "body_text": ("é" * 100) + ("€" * 50) + ("\U0001F600" * 12),
    },
    {
        "name": "accept_unknown_time_zero_clock",
        "generation": 0xFFFFFFFF,
        "ed25519_seed_hex": "0f" * 31 + "f0",
        "x25519_priv_hex": "f0" * 31 + "0f",
        "created_at": 0,
        "time_quality": TIME_QUALITY_UNKNOWN,
        "nonce_hex": "0a" * 8 + "f5" * 8,
        "body_text": "panic",
    },
]


def raw_pair_keys(fixtures: list) -> list:
    """Materialise each fixture into full envelope bytes (accept kind)."""
    made = []
    for fix in fixtures:
        seed = bytes.fromhex(fix["ed25519_seed_hex"])
        xpriv = bytes.fromhex(fix["x25519_priv_hex"])
        gen = fix["generation"]
        created = fix["created_at"]
        tq = fix["time_quality"]
        nonce = bytes.fromhex(fix["nonce_hex"])
        body = fix["body_text"].encode("utf-8")
        assert len(body) <= MAX_BODY_BYTES, (fix["name"], len(body))

        ed_priv = ed25519.Ed25519PrivateKey.from_private_bytes(seed)
        signing_pub = ed_priv.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        x_signer = x25519.X25519PrivateKey.from_private_bytes(xpriv)
        static_dh_pub = x_signer.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        node = derive_node_id(signing_pub)
        binding_pre = identity_binding_preimage(
            gen, signing_pub, static_dh_pub, version=BINDING_VERSION)
        binding_sig = ed_priv.sign(binding_pre)
        binding = serialize_identity_binding(
            gen, signing_pub, static_dh_pub, binding_sig, version=BINDING_VERSION)
        unsigned = (bytes([PAYLOAD_VERSION]) + binding + uint32_le(created)
                    + bytes([tq]) + nonce + struct.pack(">H", len(body)) + body)
        mid = msg_id(node, created, nonce, unsigned)
        sig = ed_priv.sign(mid + SOS_MAGIC + unsigned)
        assert len(sig) == 64 and len(binding) == 133 and len(mid) == 16
        made.append({
            "fix": fix,
            "seed": seed, "ed_priv": ed_priv,
            "signing_pub": signing_pub, "static_dh_pub": static_dh_pub,
            "node": node, "binding": binding, "unsigned": unsigned,
            "mid": mid, "sig": sig,
        })
    return made


def tamper_payload(m: dict, *, sig: bytes = None, unsigned: bytes = None,
                   body: bytes = None) -> bytes:
    """Rebuild a frame payload, replacing the signature and/or unsigned span."""
    u = m["unsigned"] if unsigned is None else unsigned
    s = m["sig"] if sig is None else sig
    if body is not None:
        u = u[:155] + struct.pack(">H", len(body)) + body
    return SOS_MAGIC + s + u


def generate_vectors() -> dict:
    made = raw_pair_keys(FIXTURES)
    base = next(m for m in made if m["fix"]["name"] == "accept_signed_ok_min")
    vectors = []

    for m in made:
        fix = m["fix"]
        vectors.append({
            "kind": "accept",
            "name": fix["name"],
            "generation": fix["generation"],
            "ed25519_seed_hex": fix["ed25519_seed_hex"],
            "signing_public_key": m["signing_pub"].hex(),
            "static_dh_public_key": m["static_dh_pub"].hex(),
            "node_id": m["node"].hex(),
            "created_at": fix["created_at"],
            "time_quality": fix["time_quality"],
            "nonce_hex": fix["nonce_hex"],
            "body_hex": fix["body_text"].encode("utf-8").hex(),
            "binding_hex": m["binding"].hex(),
            "unsigned_hex": m["unsigned"].hex(),
            "msg_id_hex": m["mid"].hex(),
            "signature_hex": m["sig"].hex(),
            "frame_payload_hex": (SOS_MAGIC + m["sig"] + m["unsigned"]).hex(),
            "header": dict(HEADER),
        })

    def reject(name, field, reason, payload, header=None, note=None):
        entry = {
            "kind": "reject",
            "name": name,
            "tampered_field": field,
            "expected_reason": reason,
            "base": "accept_signed_ok_min",
            "frame_payload_hex": payload.hex() if payload is not None else None,
            "header": dict(header if header is not None else HEADER),
        }
        if note:
            entry["note"] = note
        vectors.append(entry)

    def flip(b: bytes, i: int) -> bytes:
        ba = bytearray(b)
        ba[i] ^= 0x01
        return bytes(ba)

    # The all-zero signature slot: structurally sound, authenticates to nothing.
    reject("reject_zero_signature_structural_only", "signature", "signature",
           tamper_payload(base, sig=bytes(64)),
           note="section15: the structural golden shape carries a zero signature; "
                "runtime authentication must refuse it although the validator passes")
    # One bit inside the 64-byte signature slot.
    reject("reject_signature_bit_flip", "signature", "signature",
           tamper_payload(base, sig=flip(base["sig"], 9)))
    # One bit inside the signed body: re-derivation of msg_id diverges first.
    reject("reject_body_bit_flip", "body", "message_id_mismatch",
           tamper_payload(base, body=base["fix"]["body_text"].encode("utf-8")[:-1]
                          + bytes([base["unsigned"][-1] ^ 0x01])))
    # The body-length field claims one byte more than the tail holds.
    liar = bytearray(base["unsigned"])
    liar[155:157] = struct.pack(">H", len(base["unsigned"]) - 157 + 1)
    reject("reject_body_length_liar", "body_len_be", "body_length",
           tamper_payload(base, unsigned=bytes(liar)),
           note="the signature still verifies over these bytes; only the "
                "exact-length obligation can refuse this frame")
    # The unsigned payload lies about its binding: one byte dropped from the
    # 133-byte binding field shifts every fixed offset behind it.
    short = (base["unsigned"][:1 + 132] + base["unsigned"][134:])
    reject("reject_truncated_binding", "identity_binding", "malformed",
           tamper_payload(base, unsigned=short),
           note="binding field is 132 bytes long; the exact-shape gate refuses "
                "before any cryptographic work")
    # The leading version byte claims 0x02; the table knows exactly one.
    badver = bytearray(base["unsigned"])
    badver[0] = 0x02
    reject("reject_bad_payload_version", "version", "malformed",
           tamper_payload(base, unsigned=bytes(badver)),
           note="version byte claims 0x02; fail closed, never try a legacy shape")
    # The time-quality octet claims a code outside the closed table.
    badtq = bytearray(base["unsigned"])
    badtq[138] = 0x03
    reject("reject_unknown_time_quality", "time_quality", "time_quality",
           tamper_payload(base, unsigned=bytes(badtq)))
    # created_at is zero while time_quality still claims USER_CONFIRMED:
    # the unknown-time pairing is broken in both directions.
    badpair = bytearray(base["unsigned"])
    badpair[134:138] = bytes(4)
    reject("reject_unknown_time_pairing", "created_at", "unknown_time_pairing",
           tamper_payload(base, unsigned=bytes(badpair)),
           note="created_at == 0 if and only if time_quality == UNKNOWN(0)")
    # A stranger's key pair recorded into the victim's binding: the binding
    # self-signature is taken over the victim's declared key with the
    # stranger's secret -- it verifies for nobody. The frame signature and
    # msg_id still stand (the unsigned bytes are the victim's), so ONLY the
    # identity equation gate can refuse this frame.
    stranger = ed25519.Ed25519PrivateKey.from_private_bytes(bytes.fromhex("99" * 32))
    stranger_pub = stranger.public_key().public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw)
    stranger_binding_pre = identity_binding_preimage(
        base["fix"]["generation"], base["signing_pub"], base["static_dh_pub"],
        version=BINDING_VERSION)
    stranger_binding_sig = stranger.sign(stranger_binding_pre)
    false_binding = serialize_identity_binding(
        base["fix"]["generation"], base["signing_pub"], base["static_dh_pub"],
        stranger_binding_sig, version=BINDING_VERSION)
    false_unsigned = (bytes([PAYLOAD_VERSION]) + false_binding
                      + base["unsigned"][134:])
    reject("reject_stranger_key_in_binding", "identity_binding.signature",
           "identity_binding",
           tamper_payload(base, unsigned=false_unsigned),
           note="the stranger re-signed the victim's declaration with its own "
                "secret; the binding self-signature verifies for nobody and "
                "only that gate refuses -- the frame signature and msg_id are "
                "the victim's untouched bytes")
    # The binding carries the stranger's own consistent key pair, yet the
    # node identity claimed by the msg_id derivation is the victim's: a
    # verifier that TRUSTS the embedded key instead of deriving the node id
    # from it would admit this frame (kills roster RC4).
    stranger2 = ed25519.Ed25519PrivateKey.from_private_bytes(bytes.fromhex("7e" * 32))
    s2pub = stranger2.public_key().public_bytes(
        encoding=serialization.Encoding.Raw, format=serialization.PublicFormat.Raw)
    s2pre = identity_binding_preimage(base["fix"]["generation"], s2pub,
                                       base["static_dh_pub"], version=BINDING_VERSION)
    s2binding = serialize_identity_binding(
        base["fix"]["generation"], s2pub, base["static_dh_pub"],
        stranger2.sign(s2pre), version=BINDING_VERSION)
    s2unsigned = bytes([PAYLOAD_VERSION]) + s2binding + base["unsigned"][134:]
    reject("reject_underived_node_claim", "identity_binding.signing_public_key",
           "identity_binding",
           tamper_payload(base, unsigned=s2unsigned),
           note="everything else re-verifies for the stranger's own key pair; "
                "the only falsehood is that BLAKE2s-128(embedded signing pub) "
                "does not equal the node_id the msg_id was derived over -- "
                "the receiver must DERIVE, never trust the claim")
    # Header tampering: the required flags are not both set.
    reject("reject_flags_missing_required", "header.flags", "missing_required_flags",
           SOS_MAGIC + base["sig"] + base["unsigned"],
           header={**HEADER, "flags": 0x0010})
    # Header tampering: one bit promoted the type octet into the SOS space
    # from the unassigned neighbour 0xE0 (no assigned type is one bit away).
    reject("reject_one_bit_type_promotion", "header.type", "wrong_type",
           SOS_MAGIC + base["sig"] + base["unsigned"],
           header={**HEADER, "type": 0xF0 ^ 0x10})
    # Header tampering: the msg_id field is censored one bit at a time while
    # the payload stands; re-derivation diverges.
    reject("reject_msg_id_bit_flip", "header.msg_id", "message_id_mismatch",
           SOS_MAGIC + base["sig"] + base["unsigned"],
           header={**HEADER, "msg_id_flip_byte": 0,
                   "flip_note": "court flips bit 0 of msg_id byte 0"})

    doc = {
        "schema": 1,
        "generator": "crypto/gen_sos_v1_vectors.py",
        "magic_ascii": "SOS1",
        "transcript": 'msg_id || ASCII("SOS1") || unsigned payload',
        "msgid_formula": ('BLAKE2s-128("GMP2-MSGID" || node_id || created_at_le '
                         "|| nonce || unsigned payload)"),
        "unsigned_layout": ("version1(0x01) || identityBinding133 || created_at_le4 "
                           "|| time_quality1 || nonce16 || body_len_be2 || "
                           "utf8body(<=400, strict)"),
        "header_constants": dict(HEADER),
        "one_bit_family_note": ("no assigned message type in wire_v2.yaml sits at "
                               "Hamming distance 1 from SOS=0xF0; the promoted "
                               "neighbours tested are the unassigned 0xE0"),
        "vectors": vectors,
    }
    return doc


def main() -> None:
    data = generate_vectors()
    accepts = [v for v in data["vectors"] if v["kind"] == "accept"]
    rejects = [v for v in data["vectors"] if v["kind"] == "reject"]
    assert len(accepts) == 3 and len(rejects) == 13, (len(accepts), len(rejects))
    for v in accepts:
        unsigned = bytes.fromhex(v["unsigned_hex"])
        body = bytes.fromhex(v["body_hex"])
        assert unsigned[0] == PAYLOAD_VERSION
        assert unsigned[1:134] == bytes.fromhex(v["binding_hex"])
        assert struct.unpack("<I", unsigned[134:138])[0] == v["created_at"]
        assert unsigned[138] == v["time_quality"]
        assert unsigned[139:155] == bytes.fromhex(v["nonce_hex"])
        assert struct.unpack(">H", unsigned[155:157])[0] == len(body)
        assert unsigned[157:] == body
        assert (v["created_at"] == 0) == (v["time_quality"] == TIME_QUALITY_UNKNOWN)
        assert bytes.fromhex(v["frame_payload_hex"]) == (
            SOS_MAGIC + bytes.fromhex(v["signature_hex"]) + unsigned)
        assert msg_id(bytes.fromhex(v["node_id"]), v["created_at"],
                      bytes.fromhex(v["nonce_hex"]), unsigned) == bytes.fromhex(v["msg_id_hex"])
        ed_pub = ed25519.Ed25519PublicKey.from_public_bytes(
            bytes.fromhex(v["signing_public_key"]))
        authenticates = True
        try:
            ed_pub.verify(bytes.fromhex(v["signature_hex"]),
                          bytes.fromhex(v["msg_id_hex"]) + SOS_MAGIC + unsigned)
        except InvalidSignature:
            authenticates = False
        assert authenticates, v["name"]
        assert derive_node_id(bytes.fromhex(v["signing_public_key"])) == bytes.fromhex(v["node_id"])
    out_path = Path(__file__).resolve().parent / "sos_v1_vectors.json"
    formatted = json.dumps(data, indent=2) + "\n"
    out_path.write_text(formatted, encoding="utf-8")
    print(f"Wrote {len(data['vectors'])} SignedSosV1 vectors "
          f"({len(accepts)} accept, {len(rejects)} reject) to {out_path.name}")


if __name__ == "__main__":
    main()
