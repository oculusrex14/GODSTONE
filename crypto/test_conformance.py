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
from .cacophony import DEFAULT_FILE as CACOPHONY_FILE
from .cacophony import check as cacophony_check
from .noise_ref import run_handshake

VECTORS = Path(__file__).resolve().parent / "handshake_vectors.json"


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

    print("\n6. External conformance  (breaks the circularity of 1-5)")
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
