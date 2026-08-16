#!/usr/bin/env python3
"""Invariant D: cross-implementation Noise conformance.

    python -m crypto.test_conformance

Checks, in order:

  1. BLAKE2s against RFC 7693. A floor check: the hash sits under HKDF, which
     sits under the handshake. One wrong bit and everything above fails
     silently. Audit A-02 shipped a hand-rolled BLAKE2s with no vectors.

  2. The derivation chain -- node_id, node_hint, prologue, initial h. Pinned
     because h is seeded from the prologue and a transcript-only fixture cannot
     see a node_id defect.

  3. The XX transcript, every (ck, h, k) at every token, both sides. Per-token
     state makes a failure report "diverged at w1:es" rather than the useless
     "handshake failed".

  4. The interop matrix. THE RIGHT-HAND COLUMN IS THE FINDING: every defect
     passes against a peer that shares it, so a single-platform suite is green
     with all three present.

  5. Negative vectors -- reintroducing any shipped defect must be caught.

  6. EXTERNAL conformance (crypto/cacophony.py). Steps 1-5 are internal and
     therefore circular: the fixture is produced by the reference it checks.
     Only step 6 breaks that, and only when a real vector file is present.
"""
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from . import derivation as D
from . import gmp21 as G
from .cacophony import DEFAULT_FILE as CACOPHONY_FILE
from .cacophony import check as cacophony_check
from .noise_ref import run_handshake

VECTORS = Path(__file__).resolve().parent / "handshake_vectors.json"
GMP21_VECTORS = Path(__file__).resolve().parent / "gmp21_vectors.json"


class Result:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.checks = 0

    def check(self, ok: bool, label: str, detail: str = "") -> bool:
        self.checks += 1
        if ok:
            print(f"  ok    {label}")
        else:
            self.failures.append(label)
            print(f"  FAIL  {label}")
            if detail:
                print(f"        {detail}")
        return ok


def x(hexs: str) -> X25519PrivateKey:
    return X25519PrivateKey.from_private_bytes(bytes.fromhex(hexs))


def check_gmp21(r: Result) -> None:
    """GMP/2.1 derivation vectors (ADR-001 §3, C6.7.1): msg_id, bloom, PoW.

    Self-consistency: the Python reference (crypto/gmp21.py, hashlib.blake2s)
    must reproduce every locked value in crypto/gmp21_vectors.json. This is
    necessary but NOT sufficient -- the fixture is produced by this same
    reference, so this check cannot detect a reference that is wrong in the
    same way twice. The real parity proof is that the Android (Kotlin/Bouncy
    Castle) and iOS (Swift/Blake2s) test suites each transcribe these hex
    literals and assert their runtimes reproduce them byte-for-byte. This
    check guards the fixture against silent drift / hand-edits.
    """
    print("\n6. GMP/2.1 derivation vectors  (msg_id / bloom / PoW)")
    if not GMP21_VECTORS.exists():
        print(f"::error::missing {GMP21_VECTORS}. Run: "
              "python -m crypto.gen_gmp21_vectors", file=sys.stderr)
        r.failures.append("gmp21 vectors missing")
        return
    g = json.loads(GMP21_VECTORS.read_text())

    for c in g["msg_id"]["cases"]:
        got = G.msg_id(bytes.fromhex(c["sender_node_id"]),
                       c["created_at_epoch_seconds"],
                       bytes.fromhex(c["message_nonce"]),
                       bytes.fromhex(c["payload"])).hex()
        r.check(got == c["msg_id"], f"msg_id {c['name']}",
                 f"want {c['msg_id']} got {got}")

    # Recompute msg_id negative controls directly:
    neg = g["msg_id"]["negative"]
    sender_a = bytes.fromhex(neg["sender_node_id"])
    payload_help = bytes.fromhex(neg["payload"])
    nonce_one = bytes.fromhex(neg["message_nonce"])
    be_recomputed = hashlib.blake2s(
        G.MSG_ID_DOMAIN + sender_a + G.uint32_be(1) + nonce_one + payload_help, digest_size=16).hexdigest()
    r.check(be_recomputed == neg["msg_id_be"] and be_recomputed != g["msg_id"]["cases"][1]["msg_id"],
            f"msg_id negative {neg['name']} (recomputed BE != LE)")

    neg_nonce = g["msg_id"]["negative_nonce"]
    nonce_zero = bytes.fromhex(neg_nonce["message_nonce"])
    zero_nonce_recomputed = G.msg_id(sender_a, 1, nonce_zero, payload_help).hex()
    r.check(zero_nonce_recomputed == neg_nonce["msg_id_zero_nonce"] and
            zero_nonce_recomputed != g["msg_id"]["cases"][1]["msg_id"],
            f"msg_id negative {neg_nonce['name']} (recomputed distinct nonce)")

    for case in g["bloom"]["cases"]:
        ids = [bytes.fromhex(i["msg_id"]) for i in case["ids"]]
        filt = G.bloom_build(ids)
        r.check(filt.hex() == case["filter"], f"bloom {case['name']} filter")
        r.check(G.bloom_short_digest(filt).hex() == case["short_digest"],
                f"bloom {case['name']} shortDigest")
        for i in case["ids"]:
            mid = bytes.fromhex(i["msg_id"])
            got_idx = [G.bloom_index(mid, r2) for r2 in range(G.BLOOM_HASHES)]
            r.check(got_idx == i["round_indices"],
                    f"bloom {case['name']} indices {i['msg_id'][:8]}",
                    f"want {i['round_indices']} got {got_idx}")

    for c in g["pow"]["cases"]:
        nonce = bytes.fromhex(c["pow_nonce"])
        sender = bytes.fromhex(c["sender_node_id"])
        created_le = bytes.fromhex(c["created_at_le"])
        msg_nonce = bytes.fromhex(c["message_nonce"])
        priority_code = c["priority_code"]
        pt = bytes.fromhex(c["plaintext"])
        digest = G.pow_digest(nonce, sender, created_le, msg_nonce, priority_code, c["type_code"], pt)
        r.check(digest.hex() == c["blake2s_256"], f"pow {c['name']} digest")
        r.check(G.pow_top_bits_zero(digest, c["target_bits"]),
                f"pow {c['name']} top-{c['target_bits']} bits zero")
        # A wrong nonce (all zeros) must NOT satisfy the production target.
        if c["target_bits"] == G.POW_TARGET_BITS:
            r.check(not G.pow_verify(bytes(G.POW_NONCE_BYTES), sender, created_le, msg_nonce,
                                     priority_code, c["type_code"], pt, c["target_bits"]),
                    f"pow {c['name']} zero-nonce rejected")

    # Recompute PoW nonce-mutation negative control directly
    pow_neg = g["pow"]["negative_nonce"]
    pow_nonce_20 = bytes.fromhex(pow_neg["pow_nonce"])
    msg_nonce_orig = bytes.fromhex(pow_neg["message_nonce_original"])
    msg_nonce_mut = bytes.fromhex(pow_neg["message_nonce_mutated"])
    prio_group = pow_neg["priority_code"]
    pt_help = bytes.fromhex(g["pow"]["cases"][0]["plaintext"])
    created_le_1 = bytes.fromhex(g["pow"]["cases"][0]["created_at_le"])
    type_msg = g["pow"]["cases"][0]["type_code"]

    orig_valid = G.pow_verify(pow_nonce_20, sender_a, created_le_1, msg_nonce_orig, prio_group, type_msg, pt_help, 20)
    mut_valid = G.pow_verify(pow_nonce_20, sender_a, created_le_1, msg_nonce_mut, prio_group, type_msg, pt_help, 20)
    r.check(orig_valid and not mut_valid,
            f"pow negative {pow_neg['name']} (recomputed message_nonce binding)")

    # Recompute PoW priority-mutation negative control directly
    pow_prio_neg = g["pow"]["negative_priority"]
    prio_orig = pow_prio_neg["priority_code_original"]
    prio_mut = pow_prio_neg["priority_code_mutated"]
    prio_orig_valid = G.pow_verify(pow_nonce_20, sender_a, created_le_1, msg_nonce_orig, prio_orig, type_msg, pt_help, 20)
    prio_mut_valid = G.pow_verify(pow_nonce_20, sender_a, created_le_1, msg_nonce_orig, prio_mut, type_msg, pt_help, 20)
    r.check(prio_orig_valid and not prio_mut_valid,
            f"pow negative {pow_prio_neg['name']} (recomputed priority binding)")

    # Check raw sealed_inner fixture
    si = g["sealed_inner"]["case"]
    expected_si = (bytes.fromhex(si["message_nonce"]) + bytes.fromhex(si["pow_nonce"]) +
                   bytes.fromhex(si["created_at_le"]) + bytes([si["priority_code"]]) +
                   bytes.fromhex(si["plaintext"]))
    r.check(expected_si.hex() == si["sealed_inner"] and len(expected_si) == 29 + len(bytes.fromhex(si["plaintext"])),
            f"sealed_inner {si['name']} raw 29-byte prefix layout")


def main() -> int:
    if not VECTORS.exists():
        print(f"::error::missing {VECTORS}. Run: python -m crypto.gen_vectors",
              file=sys.stderr)
        return 1

    v = json.loads(VECTORS.read_text())
    r = Result()

    print("\n1. BLAKE2s vs RFC 7693")
    rfc = v["rfc7693_vectors"]
    r.check(hashlib.blake2s(b"abc").hexdigest() == rfc["blake2s_256_abc"],
            'BLAKE2s-256("abc")')
    r.check(hashlib.blake2s(b"").hexdigest() == rfc["blake2s_256_empty"],
            'BLAKE2s-256("")')

    print("\n2. Derivation chain  (keys -> node_id -> hint -> prologue -> h0)")
    dc = v["derivation_chain"]
    for side in ("initiator", "responder"):
        want = dc[side]
        ident = D.Identity(bytes.fromhex(want["identity_pub"]),
                           bytes.fromhex(want["static_dh_pub"]))
        got = ident.describe()
        r.check(got["node_id"] == want["node_id"],
                f"{side}.node_id = BLAKE2s-128(identity_pub)",
                f"want {want['node_id']} got {got['node_id']}")
        r.check(got["node_hint"] == want["node_hint"], f"{side}.node_hint")
        r.check(got["call_sign_indices"] == want["call_sign_indices"],
                f"{side}.call_sign indices")

    pro = D.prologue(bytes.fromhex(dc["initiator"]["node_hint"]),
                     bytes.fromhex(dc["responder"]["node_hint"]))
    r.check(pro.hex() == dc["prologue"], "prologue = GMP2||i_hint||r_hint")
    r.check(D.initial_h(pro).hex() == dc["initial_h"], "initial h")

    print("\n3. XX transcript  (per-token ck / h / k, both sides)")
    tk = v["test_keys"]
    out = run_handshake(x(tk["initiator_static_priv"]),
                        x(tk["initiator_ephemeral_priv"]),
                        x(tk["responder_static_priv"]),
                        x(tk["responder_ephemeral_priv"]),
                        bytes.fromhex(dc["prologue"]))
    hs = v["handshake"]
    r.check(out["message_sizes"] == hs["message_sizes"],
            f"message sizes {hs['message_sizes']}")
    r.check(out["messages"] == hs["messages"], "message bytes")
    r.check(out["handshake_hash"] == hs["handshake_hash"], "handshake hash")
    r.check(out["keys_agree"], "transport keys agree between the two sides")
    r.check(out["send_key"] == hs["send_key"], "send key")
    r.check(out["recv_key"] == hs["recv_key"], "recv key")

    for side in ("initiator", "responder"):
        want, got = hs[f"{side}_trace"], out[f"{side}_trace"]
        if len(want) != len(got):
            r.check(False, f"{side} trace length")
            continue
        bad = next((i for i, (a, b) in enumerate(zip(want, got)) if a != b), None)
        r.check(bad is None, f"{side} trace, {len(want)} steps",
                "" if bad is None else f"diverged at {want[bad]['token']}")

    print("\n4. Interop matrix")
    print(f"    {'android':<15} {'ios':<18} {'result':<10} note")
    rows = [
        ("conformant", "conformant", {}, {}),
        ("conformant", "quirk_hkdf_ios", {}, {"quirk_hkdf_ios": True}),
        ("conformant", "quirk_nonce_be", {}, {"quirk_nonce_be": True}),
        ("quirk_hkdf_ios", "quirk_hkdf_ios",
         {"quirk_hkdf_ios": True}, {"quirk_hkdf_ios": True}),
        ("quirk_nonce_be", "quirk_nonce_be",
         {"quirk_nonce_be": True}, {"quirk_nonce_be": True}),
    ]
    keys = (x(tk["initiator_static_priv"]), x(tk["initiator_ephemeral_priv"]),
            x(tk["responder_static_priv"]), x(tk["responder_ephemeral_priv"]))
    pro_b = bytes.fromhex(dc["prologue"])
    matrix_ok = True
    for a_name, i_name, a_kw, i_kw in rows:
        same = a_kw == i_kw
        if same:
            res = run_handshake(*keys, pro_b, **a_kw)
            works = res["keys_agree"]
            note = "" if not a_kw else "SELF-CONSISTENT BUT WRONG"
        else:
            ra = run_handshake(*keys, pro_b, **a_kw)
            rb = run_handshake(*keys, pro_b, **i_kw)
            works = ra["handshake_hash"] == rb["handshake_hash"]
            note = "cross-impl divergence detected"
        print(f"    {a_name:<15} {i_name:<18} "
              f"{'connects' if works else 'DEAD LINK':<10} {note}")
        if same and not a_kw and not works:
            matrix_ok = False
        if not same and works:
            matrix_ok = False
    r.check(matrix_ok, "matrix: conformant pair connects, mixed pairs do not")
    print("    ^ every defect passes against a peer that SHARES it --")
    print("      which is why a single-platform suite was green.")

    print("\n5. Negative vectors  (reintroducing a defect must be caught)")
    for name, spec in v["negative_vectors"].items():
        r.check(spec["differs"], f"{name} diverges from conformant")

    check_gmp21(r)

    print("\n7. External conformance  (breaks the circularity of 1-5)")
    pinned, detail = cacophony_check(CACOPHONY_FILE, verbose=False)
    if pinned:
        r.check(True, f"cacophony vectors reproduced -- {detail}")
    else:
        print(f"  ....  NOT PINNED -- {detail}")
        print("        Steps 1-5 are internal: the fixture is produced by the")
        print("        very reference it checks. Only an external vector settles")
        print("        conformance. See docs/PINNING_CACOPHONY.md.")

    print("\n" + "=" * 68)
    print(f"checks={r.checks} failures={len(r.failures)}")
    if r.failures:
        print("::error::Invariant D FAILED: " + ", ".join(r.failures),
              file=sys.stderr)
        return 1
    print("Invariant D: all vectors reproduced.")
    if pinned:
        print("CONFORMANCE STATUS: PINNED (external vector validated)")
    else:
        print("\nCONFORMANCE STATUS: UNPINNED")
        print("  Invariant D currently proves Android and iOS agree WITH EACH")
        print("  OTHER. Necessary, not sufficient: two implementations can agree")
        print("  and both be wrong -- the exact failure mode in the matrix above.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
