#!/usr/bin/env python3
"""Noise_XX_25519_ChaChaPoly_BLAKE2s reference implementation.

Encodes the Noise Protocol Framework rev34 as read. Exists to generate and check
the cross-platform vectors behind Invariant D. NOT shipped in either app.

The three historical Godstone defects are reproducible as toggleable quirks, so
each divergence is a number in CI rather than a claim in a review:

    QUIRK_HKDF_IOS    Hkdf.swift returned temp_key as the chaining key (spec:
                      output1) and fed material||0x01 instead of the byte 0x01.
    QUIRK_NONCE_BE    NoiseSession.swift used big-endian nonces. Spec 12.3 is 32
                      zero bits then LITTLE-endian n. n=0 is identical under
                      both, which is why message 1 appeared to work.
    QUIRK_NODEID_DH   MeshIdentity.swift derived node_id from the X25519 key.
                      PROTOCOL.md:49 specifies BLAKE2s-128 of the Ed25519 key.
                      Changes node_hint -> prologue -> h, BEFORE the first DH.

CONFORMANCE: see handshake_vectors.json "_conformance_status". Self-consistency
proves nothing -- two implementations can agree and both be wrong. Only the
official cacophony vectors settle it; crypto/cacophony.py is the check.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field

from cryptography.hazmat.primitives.asymmetric.x25519 import (
    X25519PrivateKey,
    X25519PublicKey,
)
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    NoEncryption,
    PrivateFormat,
    PublicFormat,
)

PROTOCOL_NAME = b"Noise_XX_25519_ChaChaPoly_BLAKE2s"
HASHLEN = 32
DHLEN = 32
TAGLEN = 16
BLOCKLEN = 64          # BLAKE2s block, for HMAC
PROLOGUE_MAGIC = b"GMP2"
EMPTY = b""


# --------------------------------------------------------------------------
# Primitives
# --------------------------------------------------------------------------
def blake2s(data: bytes, digest_size: int = HASHLEN) -> bytes:
    return hashlib.blake2s(data, digest_size=digest_size).digest()


def hmac_blake2s(key: bytes, message: bytes) -> bytes:
    """RFC 2104 HMAC over BLAKE2s used as an ordinary hash.

    Deliberately NOT BLAKE2s's native keyed mode: Noise specifies HMAC-HASH, and
    Android reaches the same construction via BouncyCastle HMac/Blake2sDigest.
    """
    k = blake2s(key) if len(key) > BLOCKLEN else key
    k = k + b"\x00" * (BLOCKLEN - len(k))
    ipad = bytes(b ^ 0x36 for b in k)
    opad = bytes(b ^ 0x5C for b in k)
    return blake2s(opad + blake2s(ipad + message))


def hkdf(chaining_key: bytes, ikm: bytes, num_outputs: int = 2,
         quirk_ios: bool = False) -> tuple[bytes, ...]:
    """Noise rev34 section 4.3.

        temp_key = HMAC(ck, ikm)
        output1  = HMAC(temp_key, 0x01)
        output2  = HMAC(temp_key, output1 || 0x02)
        output3  = HMAC(temp_key, output2 || 0x03)
    """
    if quirk_ios:
        temp = hmac_blake2s(chaining_key, ikm)
        return (temp, hmac_blake2s(temp, ikm + b"\x01"))

    temp_key = hmac_blake2s(chaining_key, ikm)
    out1 = hmac_blake2s(temp_key, b"\x01")
    if num_outputs == 1:
        return (out1,)
    out2 = hmac_blake2s(temp_key, out1 + b"\x02")
    if num_outputs == 2:
        return (out1, out2)
    return (out1, out2, hmac_blake2s(temp_key, out2 + b"\x03"))


def nonce_bytes(n: int, big_endian: bool = False) -> bytes:
    """Noise 12.3: 32 bits of zeros followed by little-endian n."""
    return b"\x00" * 4 + n.to_bytes(8, "big" if big_endian else "little")


def dh(private: X25519PrivateKey, public_raw: bytes) -> bytes:
    return private.exchange(X25519PublicKey.from_public_bytes(public_raw))


def pub_raw(private: X25519PrivateKey) -> bytes:
    return private.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def priv_raw(private: X25519PrivateKey) -> bytes:
    return private.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())


# --------------------------------------------------------------------------
# Symmetric state
# --------------------------------------------------------------------------
@dataclass
class CipherState:
    k: bytes | None = None
    n: int = 0
    big_endian_nonce: bool = False

    def has_key(self) -> bool:
        return self.k is not None

    def encrypt_with_ad(self, ad: bytes, plaintext: bytes) -> bytes:
        if self.k is None:
            return plaintext
        ct = ChaCha20Poly1305(self.k).encrypt(
            nonce_bytes(self.n, self.big_endian_nonce), plaintext, ad)
        self.n += 1
        return ct

    def decrypt_with_ad(self, ad: bytes, ciphertext: bytes) -> bytes:
        if self.k is None:
            return ciphertext
        pt = ChaCha20Poly1305(self.k).decrypt(
            nonce_bytes(self.n, self.big_endian_nonce), ciphertext, ad)
        self.n += 1
        return pt


@dataclass
class SymmetricState:
    ck: bytes = EMPTY
    h: bytes = EMPTY
    cipher: CipherState = field(default_factory=CipherState)
    quirk_hkdf_ios: bool = False
    quirk_nonce_be: bool = False

    def initialize(self, protocol_name: bytes) -> None:
        if len(protocol_name) <= HASHLEN:
            self.h = protocol_name + b"\x00" * (HASHLEN - len(protocol_name))
        else:
            self.h = blake2s(protocol_name)
        self.ck = self.h
        self.cipher = CipherState(big_endian_nonce=self.quirk_nonce_be)

    def mix_hash(self, data: bytes) -> None:
        self.h = blake2s(self.h + data)

    def mix_key(self, ikm: bytes) -> None:
        out = hkdf(self.ck, ikm, 2, quirk_ios=self.quirk_hkdf_ios)
        self.ck = out[0]
        self.cipher = CipherState(k=out[1][:32], n=0,
                                  big_endian_nonce=self.quirk_nonce_be)

    def encrypt_and_hash(self, plaintext: bytes) -> bytes:
        ct = self.cipher.encrypt_with_ad(self.h, plaintext)
        self.mix_hash(ct)
        return ct

    def decrypt_and_hash(self, ciphertext: bytes) -> bytes:
        pt = self.cipher.decrypt_with_ad(self.h, ciphertext)
        self.mix_hash(ciphertext)
        return pt

    def split(self) -> tuple[bytes, bytes]:
        out = hkdf(self.ck, EMPTY, 2, quirk_ios=self.quirk_hkdf_ios)
        return out[0][:32], out[1][:32]


# --------------------------------------------------------------------------
# Handshake state -- XX
# --------------------------------------------------------------------------
XX_PATTERN = (("e",), ("e", "ee", "s", "es"), ("s", "se"))


@dataclass
class HandshakeState:
    """Noise XX. Records (ck, h, k) after every token for diagnostics.

    Per-token state is what makes Invariant D report "diverged at w1:es" rather
    than the useless "handshake failed".
    """
    initiator: bool
    s: X25519PrivateKey
    e: X25519PrivateKey
    prologue: bytes
    quirk_hkdf_ios: bool = False
    quirk_nonce_be: bool = False

    rs: bytes | None = None
    re: bytes | None = None
    msg_index: int = 0
    trace: list[dict] = field(default_factory=list)
    sym: SymmetricState = field(init=False)

    def __post_init__(self) -> None:
        self.sym = SymmetricState(quirk_hkdf_ios=self.quirk_hkdf_ios,
                                  quirk_nonce_be=self.quirk_nonce_be)
        self.sym.initialize(PROTOCOL_NAME)
        self._record("init")
        self.sym.mix_hash(self.prologue)
        self._record("prologue")

    def _record(self, token: str) -> None:
        self.trace.append({
            "token": token,
            "ck": self.sym.ck.hex(),
            "h": self.sym.h.hex(),
            "k": self.sym.cipher.k.hex() if self.sym.cipher.k else None,
        })

    def _dh_token(self, token: str) -> bytes:
        """Writer-relative DH resolution for ee / es / se."""
        if token == "ee":
            return dh(self.e, self.re)
        if token == "es":
            return dh(self.e, self.rs) if self.initiator else dh(self.s, self.re)
        if token == "se":
            return dh(self.s, self.re) if self.initiator else dh(self.e, self.rs)
        raise ValueError(token)

    def write_message(self, payload: bytes = EMPTY) -> bytes:
        tokens = XX_PATTERN[self.msg_index]
        buf = b""
        for t in tokens:
            if t == "e":
                epub = pub_raw(self.e)
                buf += epub
                self.sym.mix_hash(epub)
            elif t == "s":
                buf += self.sym.encrypt_and_hash(pub_raw(self.s))
            else:
                self.sym.mix_key(self._dh_token(t))
            self._record(f"w{self.msg_index}:{t}")
        buf += self.sym.encrypt_and_hash(payload)
        self._record(f"w{self.msg_index}:payload")
        self.msg_index += 1
        return buf

    def read_message(self, message: bytes) -> bytes:
        tokens = XX_PATTERN[self.msg_index]
        i = 0
        for t in tokens:
            if t == "e":
                self.re = message[i:i + DHLEN]
                self.sym.mix_hash(self.re)
                i += DHLEN
            elif t == "s":
                n = DHLEN + (TAGLEN if self.sym.cipher.has_key() else 0)
                self.rs = self.sym.decrypt_and_hash(message[i:i + n])
                i += n
            else:
                self.sym.mix_key(self._dh_token(t))
            self._record(f"r{self.msg_index}:{t}")
        payload = self.sym.decrypt_and_hash(message[i:])
        self._record(f"r{self.msg_index}:payload")
        self.msg_index += 1
        return payload

    def split(self) -> tuple[bytes, bytes]:
        return self.sym.split()


def build_prologue(initiator_hint: bytes, responder_hint: bytes) -> bytes:
    """prologue = "GMP1" || initiator_hint || responder_hint  (PROTOCOL.md s.4).

    Both peers must order the hints identically or h diverges at initialisation,
    before any DH happens.
    """
    if len(initiator_hint) != 4 or len(responder_hint) != 4:
        raise ValueError("node hints are 4 bytes each")
    return PROLOGUE_MAGIC + initiator_hint + responder_hint


def run_handshake(i_s: X25519PrivateKey, i_e: X25519PrivateKey,
                  r_s: X25519PrivateKey, r_e: X25519PrivateKey,
                  prologue: bytes, **quirks) -> dict:
    """Full XX exchange with empty payloads. Drives handshake_vectors.json."""
    ini = HandshakeState(True, i_s, i_e, prologue, **quirks)
    res = HandshakeState(False, r_s, r_e, prologue, **quirks)

    m1 = ini.write_message()
    res.read_message(m1)
    m2 = res.write_message()
    ini.read_message(m2)
    m3 = ini.write_message()
    res.read_message(m3)

    i_k1, i_k2 = ini.split()
    r_k1, r_k2 = res.split()
    return {
        "messages": [m1.hex(), m2.hex(), m3.hex()],
        "message_sizes": [len(m1), len(m2), len(m3)],
        "initiator_trace": ini.trace,
        "responder_trace": res.trace,
        "handshake_hash": ini.sym.h.hex(),
        "keys_agree": (i_k1, i_k2) == (r_k1, r_k2),
        "handshake_hash_agree": ini.sym.h == res.sym.h,
        "send_key": i_k1.hex(),
        "recv_key": i_k2.hex(),
    }


def run_vector(init_static: bytes, init_ephemeral: bytes,
               resp_static: bytes, resp_ephemeral: bytes,
               prologue: bytes, payloads: list[bytes],
               **quirks) -> dict:
    """Run an externally-specified vector: arbitrary keys, prologue and payloads.

    This is the shape the official Noise test vectors take, and it is what
    crypto/cacophony.py needs. run_handshake() above cannot be reused because it
    hardcodes empty payloads and the Godstone prologue.

    Message direction alternates from the initiator:

        msg 0  init -> resp        (handshake)
        msg 1  resp -> init        (handshake)
        msg 2  init -> resp        (handshake, XX completes; split() here)
        msg 3  resp -> init        (transport, responder's sending cipher)
        msg 4  init -> resp        (transport, initiator's sending cipher)

    After split the initiator sends under k1 and receives under k2; the
    responder is the mirror. Never the same key in both directions -- that would
    make nonce reuse trivially fatal.
    """
    ini = HandshakeState(True, X25519PrivateKey.from_private_bytes(init_static),
                         X25519PrivateKey.from_private_bytes(init_ephemeral),
                         prologue, **quirks)
    res = HandshakeState(False, X25519PrivateKey.from_private_bytes(resp_static),
                         X25519PrivateKey.from_private_bytes(resp_ephemeral),
                         prologue, **quirks)

    out: list[bytes] = []
    handshake_hash: bytes | None = None
    ini_send = ini_recv = res_send = res_recv = None

    for idx, payload in enumerate(payloads):
        from_initiator = (idx % 2 == 0)

        if idx < len(XX_PATTERN):
            writer, reader = (ini, res) if from_initiator else (res, ini)
            msg = writer.write_message(payload)
            got = reader.read_message(msg)
            if got != payload:
                raise ValueError(f"payload round-trip failed at message {idx}")
            out.append(msg)

            if idx == len(XX_PATTERN) - 1:
                handshake_hash = ini.sym.h
                if ini.sym.h != res.sym.h:
                    raise ValueError("handshake hashes disagree at split")
                k1, k2 = ini.split()
                r1, r2 = res.split()
                if (k1, k2) != (r1, r2):
                    raise ValueError("transport keys disagree at split")
                be = quirks.get("quirk_nonce_be", False)
                ini_send = CipherState(k=k1, big_endian_nonce=be)
                ini_recv = CipherState(k=k2, big_endian_nonce=be)
                res_send = CipherState(k=k2, big_endian_nonce=be)
                res_recv = CipherState(k=k1, big_endian_nonce=be)
            continue

        sender, receiver = ((ini_send, res_recv) if from_initiator
                            else (res_send, ini_recv))
        ct = sender.encrypt_with_ad(EMPTY, payload)
        got = receiver.decrypt_with_ad(EMPTY, ct)
        if got != payload:
            raise ValueError(f"transport round-trip failed at message {idx}")
        out.append(ct)

    return {
        "messages": [m.hex() for m in out],
        "handshake_hash": handshake_hash.hex() if handshake_hash else None,
    }
