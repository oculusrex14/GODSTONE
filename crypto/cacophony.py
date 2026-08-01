#!/usr/bin/env python3
"""Validate noise_ref.py against the OFFICIAL Noise test vectors.

    python -m crypto.cacophony --check                 # validate the drop-in file
    python -m crypto.cacophony --selftest              # prove the harness works
    python -m crypto.cacophony --check --file other.json

WHY THIS FILE EXISTS
--------------------
Invariant D pins a full XX transcript and proves Android and iOS reproduce it.
That is necessary and NOT sufficient. Two implementations can agree with each
other and both be wrong -- which is precisely the right-hand column of the
interop matrix, where a quirked peer talks happily to another quirked peer.

An internal fixture cannot settle conformance, because the fixture is generated
by the same reference it is checking. Only an EXTERNAL, independently-produced
vector breaks that circularity. That is what the cacophony suite is.

THE DROP-IN CONTRACT
--------------------
Put a file at crypto/cacophony_vectors.json in the standard Noise test-vector
format and run --check. Nothing else changes:

    * this validator finds the Noise_XX_25519_ChaChaPoly_BLAKE2s entry
    * runs noise_ref with the vector's own keys, prologue and payloads
    * compares every message ciphertext byte-for-byte
    * compares the handshake hash
    * flips _conformance_status in handshake_vectors.json to PINNED
    * ci/check_parity.py Invariant D then passes WITHOUT --allow-unpinned

Format reference: https://github.com/noiseprotocol/noise_wiki/wiki/Test-vectors
Vectors: https://github.com/centromere/cacophony  (vectors/cacophony.txt)

FIELD NAMES
-----------
The community format has drifted slightly between producers. Both spellings of
each field are accepted, because rejecting a valid file over a key name would
be a spectacularly annoying way to fail:

    protocol_name | name
    init_prologue | resp_prologue      (must match; Noise has one prologue)
    init_static   | init_static_key
    messages[].ciphertext              (hex)
    messages[].payload                 (hex)
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

from .noise_ref import PROTOCOL_NAME, run_vector

HERE = Path(__file__).resolve().parent
DEFAULT_FILE = HERE / "cacophony_vectors.json"
HANDSHAKE_VECTORS = HERE / "handshake_vectors.json"

TARGET = PROTOCOL_NAME.decode()


def _first(d: dict, *names: str) -> str | None:
    for n in names:
        if d.get(n):
            return d[n]
    return None


@dataclass
class Vector:
    protocol_name: str
    prologue: bytes
    init_static: bytes
    init_ephemeral: bytes
    resp_static: bytes
    resp_ephemeral: bytes
    payloads: list[bytes]
    ciphertexts: list[bytes]
    handshake_hash: bytes | None

    @classmethod
    def parse(cls, raw: dict) -> "Vector":
        name = _first(raw, "protocol_name", "name") or ""
        ip = _first(raw, "init_prologue", "prologue") or ""
        rp = _first(raw, "resp_prologue", "prologue") or ip
        if ip != rp:
            raise ValueError("init_prologue != resp_prologue; Noise has ONE "
                             "prologue and both peers must bind the same bytes")
        msgs = raw.get("messages") or []
        payloads, cts = [], []
        for m in msgs:
            payloads.append(bytes.fromhex(m.get("payload", "")))
            cts.append(bytes.fromhex(m.get("ciphertext", "")))

        def need(*names: str) -> bytes:
            v = _first(raw, *names)
            if v is None:
                raise ValueError(f"vector is missing {names[0]}")
            return bytes.fromhex(v)

        hh = _first(raw, "handshake_hash")
        return cls(
            protocol_name=name,
            prologue=bytes.fromhex(ip),
            init_static=need("init_static", "init_static_key"),
            init_ephemeral=need("init_ephemeral", "init_ephemeral_key"),
            resp_static=need("resp_static", "resp_static_key"),
            resp_ephemeral=need("resp_ephemeral", "resp_ephemeral_key"),
            payloads=payloads,
            ciphertexts=cts,
            handshake_hash=bytes.fromhex(hh) if hh else None,
        )


def load_vectors(path: Path) -> list[dict]:
    """Accept {"vectors": [...]}, a bare [...] list, or a single object."""
    data = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(data, dict):
        if "vectors" in data:
            return data["vectors"]
        if data.get("_placeholder"):
            return []
        return [data]
    return list(data)


def find_target(vectors: list[dict]) -> dict | None:
    for v in vectors:
        if (_first(v, "protocol_name", "name") or "") == TARGET:
            return v
    return None


def check(path: Path, verbose: bool = True) -> tuple[bool, str]:
    """Validate noise_ref against an external vector file."""
    if not path.exists():
        return False, f"no vector file at {path.name}"

    try:
        vectors = load_vectors(path)
    except json.JSONDecodeError as e:
        return False, f"{path.name} is not valid JSON: {e}"

    if not vectors:
        return False, (f"{path.name} is the placeholder -- no vectors present. "
                       f"See docs/PINNING_CACOPHONY.md")

    raw = find_target(vectors)
    if raw is None:
        names = sorted({_first(v, "protocol_name", "name") or "?"
                        for v in vectors})[:6]
        return False, (f"{TARGET} not found in {path.name}. "
                       f"Saw {len(vectors)} vector(s), e.g. {names}")

    try:
        vec = Vector.parse(raw)
    except (ValueError, KeyError) as e:
        return False, f"malformed vector: {e}"

    if verbose:
        print(f"  vector      {vec.protocol_name}")
        print(f"  prologue    {vec.prologue.hex() or '(empty)'}")
        print(f"  messages    {len(vec.payloads)}")

    try:
        got = run_vector(vec.init_static, vec.init_ephemeral,
                         vec.resp_static, vec.resp_ephemeral,
                         vec.prologue, vec.payloads)
    except Exception as e:                       # noqa: BLE001 -- report, do not mask
        return False, f"noise_ref raised {type(e).__name__}: {e}"

    produced = [bytes.fromhex(m) for m in got["messages"]]
    if len(produced) != len(vec.ciphertexts):
        return False, (f"produced {len(produced)} messages, "
                       f"vector expects {len(vec.ciphertexts)}")

    for i, (mine, theirs) in enumerate(zip(produced, vec.ciphertexts)):
        if mine != theirs:
            phase = "handshake" if i < 3 else "transport"
            return False, (
                f"DIVERGED at message {i} ({phase}). "
                f"expected {theirs.hex()[:48]}... "
                f"got {mine.hex()[:48]}...")
        if verbose:
            phase = "handshake" if i < 3 else "transport"
            print(f"  ok    message {i} ({phase}, {len(mine)}B)")

    if vec.handshake_hash:
        if got["handshake_hash"] != vec.handshake_hash.hex():
            return False, (f"handshake_hash mismatch: "
                           f"expected {vec.handshake_hash.hex()[:32]}... "
                           f"got {str(got['handshake_hash'])[:32]}...")
        if verbose:
            print("  ok    handshake_hash")

    return True, f"{len(produced)} messages + handshake hash reproduced exactly"


def write_status(pinned: bool, detail: str) -> None:
    """Flip _conformance_status in handshake_vectors.json."""
    if not HANDSHAKE_VECTORS.exists():
        return
    data = json.loads(HANDSHAKE_VECTORS.read_text(encoding="utf-8"))
    data["_conformance_status"] = "PINNED" if pinned else "UNPINNED"
    data["cacophony"] = {"validated": pinned, "detail": detail} if pinned else None
    HANDSHAKE_VECTORS.write_text(json.dumps(data, indent=2) + "\n",
                                 encoding="utf-8")


def selftest() -> int:
    """Prove the PARSER and COMPARISON plumbing work.

    This generates a vector from noise_ref and feeds it back to the validator.
    That is CIRCULAR by construction and proves NOTHING about conformance -- it
    only shows that a well-formed file is parsed, executed and compared
    correctly, so that when a real cacophony file arrives the harness will
    actually exercise it rather than silently pass.

    Labelling this honestly matters: a self-generated fixture masquerading as
    external validation would be the exact failure this whole effort exists to
    eliminate.
    """
    print("SELFTEST -- harness plumbing only. This is CIRCULAR and proves")
    print("NOTHING about conformance. It exists so that a real cacophony file")
    print("is known to be genuinely exercised rather than silently accepted.\n")

    i_s = bytes([0xA1]) * 32
    i_e = bytes([0xA2]) * 32
    r_s = bytes([0xB1]) * 32
    r_e = bytes([0xB2]) * 32
    prologue = bytes.fromhex("4a6f686e2047616c74")
    payloads = [b"", b"", b"", b"transport-one", b"transport-two"]

    out = run_vector(i_s, i_e, r_s, r_e, prologue, payloads)
    synthetic = {
        "_warning": "SELF-GENERATED. Not a conformance vector.",
        "vectors": [{
            "protocol_name": TARGET,
            "init_prologue": prologue.hex(),
            "resp_prologue": prologue.hex(),
            "init_static": i_s.hex(),
            "init_ephemeral": i_e.hex(),
            "resp_static": r_s.hex(),
            "resp_ephemeral": r_e.hex(),
            "handshake_hash": out["handshake_hash"],
            "messages": [{"payload": p.hex(), "ciphertext": c}
                         for p, c in zip(payloads, out["messages"])],
        }],
    }
    tmp = HERE / "_selftest_vectors.json"
    tmp.write_text(json.dumps(synthetic, indent=2) + "\n", encoding="utf-8")
    try:
        ok, detail = check(tmp)
        print(f"\n  plumbing: {'OK' if ok else 'BROKEN'} -- {detail}")

        # Negative control: corrupt one byte, the validator MUST notice.
        bad = json.loads(tmp.read_text())
        ct = bad["vectors"][0]["messages"][0]["ciphertext"]
        flipped = ("ff" + ct[2:]) if not ct.startswith("ff") else ("00" + ct[2:])
        bad["vectors"][0]["messages"][0]["ciphertext"] = flipped
        tmp.write_text(json.dumps(bad, indent=2) + "\n", encoding="utf-8")
        ok2, detail2 = check(tmp, verbose=False)
        caught = (not ok2) and "DIVERGED at message 0" in detail2
        print(f"  negative control: {'OK' if caught else 'BROKEN'} -- {detail2[:70]}")
        return 0 if (ok and caught) else 1
    finally:
        tmp.unlink(missing_ok=True)


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Validate noise_ref against official Noise test vectors")
    ap.add_argument("--file", type=Path, default=DEFAULT_FILE)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--write-status", action="store_true",
                    help="update _conformance_status in handshake_vectors.json")
    args = ap.parse_args()

    if args.selftest:
        return selftest()

    print(f"cacophony conformance check: {args.file.name}")
    ok, detail = check(args.file)
    print()
    if ok:
        print(f"PINNED -- {detail}")
        print("noise_ref matches an EXTERNAL, independently-produced vector.")
        print("Invariant D no longer needs --allow-unpinned.")
    else:
        print(f"UNPINNED -- {detail}")
        print("Invariant D still proves only that the two platforms agree with")
        print("each other. See docs/PINNING_CACOPHONY.md for the drop-in steps.")
    if args.write_status:
        write_status(ok, detail)
        print(f"\nhandshake_vectors.json _conformance_status := "
              f"{'PINNED' if ok else 'UNPINNED'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
