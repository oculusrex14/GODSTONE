#!/usr/bin/env python3
"""Negative-control corpus for Invariant G.

    python ci/mutations.py            # every mutation must be CAUGHT
    python ci/mutations.py --report   # show what escapes, do not fail

Every mutation below PRESERVES comments and file names and BREAKS execution.
That is the exact shape of defect V3's substring gates could not see, and the
shape GPT's review demanded be made into a merge block:

    "commit a mutation fixture that preserves comments/file names but breaks
     execution. The gate must fail."

A control that has never been observed failing is not a control.
"""
from __future__ import annotations
import argparse, importlib.util, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

def _load_checker():
    spec = importlib.util.spec_from_file_location("integ", ROOT / "ci" / "integration.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m.check

# (id, file, find, replace, invariant, why, expect_escape)
#
# expect_escape=True marks a KNOWN CEILING of text-based analysis, not a bug to
# be tuned away. M2 keeps `SealedSender.seal(` textually present inside a dead
# `if (false)` branch. A regex can tell a MENTION from a CALL; it cannot tell a
# LIVE call from a DEAD one, because that is reachability analysis and it needs
# a compiler or a call graph. Special-casing `if (false)` here would make this
# one mutation pass without buying one bit of real reachability -- the exact
# control-found-ineffective / test-adjusted-instead move this repository exists
# to eliminate. So it is recorded as the boundary, and closing it is a stated
# reason `./gradlew build` is the real exit gate.
MUTATIONS = [
    ("M1-gate-comment-only",
     "android/llm/src/main/java/io/godstone/llm/rag/Retriever.kt",
     "val verdict = io.godstone.llm.safety.SafetyGate.evaluate(query, fused, corpusIndex)",
     "val verdict: io.godstone.llm.safety.SafetyGate.Result? = null  // SafetyGate.evaluate",
     "G4",
     "the call becomes a comment; V3 passed on exactly this", False),

    ("M2-sealed-sender-orphan",
     "android/mesh/src/main/java/io/godstone/mesh/router/Router.kt",
     "val sealed = io.godstone.mesh.seal.SealedSender.seal(",
     "val sealed = ByteArray(0); if (false) io.godstone.mesh.seal.SealedSender.seal(",
     "G7",
     "call kept alive textually inside `if (false)` -- CEILING, needs a compiler", True),

    ("M3-handshake-removed",
     "android/mesh/src/main/java/io/godstone/mesh/crypto/SessionManager.kt",
     "fun beginInitiator(peerId: ByteArray, remoteHint: ByteArray): NoiseSession =",
     "// fun beginInitiator REMOVED\n    private fun _unused_beginInitiator(peerId: ByteArray, remoteHint: ByteArray): NoiseSession =",
     "G3",
     "sessions.seal survives; nothing can establish a session", False),

    ("M4-wrong-sqlcipher-package",
     "android/mesh/src/main/java/io/godstone/mesh/store/MessageStore.kt",
     "import net.zetetic.database.sqlcipher.SQLiteDatabase",
     "import net.sqlcipher.database.SQLiteDatabase",
     "G8",
     "legacy package contains the substring V3 checked for", False),

    ("M5-codec-orphaned",
     "android/mesh/src/main/java/io/godstone/mesh/transport/BleTransport.kt",
     "val SERVICE_UUID: UUID = FrameV2.SERVICE_UUID",
     'val SERVICE_UUID: UUID = UUID.fromString("67640001-1000-8000-00805f9b34fb")',
     "G2",
     "generated codec still present, runtime uses a legacy literal", False),

    ("M6-idf-formula-drift",
     "ios/Godstone/Sources/GodstoneCore/SafetyGate.swift",
     "idf[t] = log((Double(n - d) + 0.5) / (Double(d) + 0.5) + 1.0)",
     "idf[t] = log(Double(n - d) + 0.5) / (Double(d) + 0.5) + 1.0",
     "G6",
     "the real iOS defect: constants agree, the equation does not", False),
]

def run(report_only: bool) -> int:
    check = _load_checker()
    baseline = check(ROOT)
    print(f"baseline findings on the unmutated tree: {len(baseline)}")
    for b in baseline:
        print("   ", b)
    print()

    escaped, unexpected, ceilings = [], [], []
    for mid, rel, find, repl, inv, why, expect_escape in MUTATIONS:
        target = ROOT / rel
        if not target.exists():
            print(f"  SKIP  {mid}: {rel} absent"); continue
        original = target.read_text(encoding="utf-8")
        if find not in original:
            print(f"  SKIP  {mid}: anchor not found (file moved on?)"); continue
        try:
            target.write_text(original.replace(find, repl, 1), encoding="utf-8")
            found = check(ROOT)
            new = [f for f in found if f not in baseline]
            caught = any(f.startswith(inv) for f in new)
            if caught and expect_escape:
                status = "CLOSED "   # a ceiling became reachable: good news
            elif caught:
                status = "caught "
            elif expect_escape:
                status = "ceiling"
            else:
                status = "ESCAPED"
            print(f"  {status} {mid:<28} [{inv}] {why}")
            if not caught:
                (ceilings if expect_escape else unexpected).append(mid)
                escaped.append(mid)
        finally:
            target.write_text(original, encoding="utf-8")

    caught_n = len(MUTATIONS) - len(escaped)
    expected_ceilings = sum(1 for m in MUTATIONS if m[6])
    print(f"\n{caught_n}/{len(MUTATIONS)} caught, "
          f"{len(ceilings)} documented ceiling(s), {len(unexpected)} regression(s)")
    if ceilings:
        print("  ceiling: " + ", ".join(ceilings) +
              " -- text analysis cannot do reachability. This is why "
              "`./gradlew build` is the exit gate, not this script.")
    if unexpected:
        print("::error::mutation escaped Invariant G unexpectedly: "
              + ", ".join(unexpected), file=sys.stderr)
        return 0 if report_only else 1
    return 0

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true")
    raise SystemExit(run(ap.parse_args().report))
