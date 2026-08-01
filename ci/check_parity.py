#!/usr/bin/env python3
"""Godstone parity and safety gate. The control that stops recurrence.

    python ci/check_parity.py

Every defect this repository has shipped shared one root cause: A CLAIM ABOUT
THE SYSTEM LIVED IN A COMMENT OR A TEST INSTEAD OF IN AN EXECUTABLE CHECK.

    "Byte-for-byte identical to the Android implementation"   -- it was not
    "grounding verified"                                      -- by a metric the app never ran
    "node_id = BLAKE2s-128(identity_pub)"                     -- iOS used the other key
    "SOS is >= 2 Hamming bits from every code"                -- it was 1 bit from WANT
    "the key the user scanned completed the handshake"        -- asserted the wrong key
    Router called store.forEachHeldOrderedByPriority()        -- the interface never declared it
    "the wire/Noise/gate fixes are done"                     -- no app imported any of them

So each fix ships with the mechanism that prevents recurrence, not just the patch.

    A  wire codecs regenerate with no diff
    B  no file under eval/ computes a grounding verdict of its own
    C  the C3 red/green probe suite passes
    D  Noise conformance: derivation chain + full XX transcript
    E  constraint gates C1/C2 and the tier tables
    F  every cross-file Kotlin call resolves to a declaration
    G  structural integration, port-vector coverage, and fail-closed feature gates

Invariant B is the audit-relevant one. A/C/D/E are cheap. B makes the original
anti-pattern -- control found ineffective, TEST adjusted instead of control --
a merge block rather than something invisible to the pipeline.
"""
from __future__ import annotations

import argparse
import filecmp
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Patterns that mean "this file decided for itself whether an answer is grounded".
FORBIDDEN_IN_EVAL = [
    (re.compile(r"^\s*def\s+coverage\s*\(", re.M),
     "defines its own coverage metric"),
    (re.compile(r"^\s*def\s+.*reciprocal_rank_fusion|RRF_K\s*=", re.M),
     "reimplements RRF"),
    (re.compile(r"CONFIDENCE_THRESHOLD\s*=\s*0?\.\d+", re.M),
     "hardcodes a confidence threshold"),
    (re.compile(r">=\s*0\.35|>\s*0\.35", re.M),
     "hardcodes the legacy 0.35 floor"),
]


class Report:
    def __init__(self) -> None:
        self.failed: list[str] = []
        self.passed: list[str] = []

    def ok(self, inv: str, msg: str) -> None:
        self.passed.append(inv)
        print(f"  ok    [{inv}] {msg}")

    def bad(self, inv: str, msg: str) -> None:
        self.failed.append(inv)
        print(f"  FAIL  [{inv}] {msg}")
        print(f"::error::Invariant {inv}: {msg}", file=sys.stderr)


def run(mod: list[str]) -> tuple[int, str]:
    p = subprocess.run([sys.executable, *mod], cwd=ROOT,
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


# ---------------------------------------------------------------- A
def invariant_a(r: Report) -> None:
    """Regenerating from wire_v2.yaml must produce no diff."""
    gen = ROOT / "wire" / "gen"
    if not gen.exists():
        r.bad("A", "wire/gen missing; run python -m wire.codegen")
        return
    with tempfile.TemporaryDirectory() as td:
        backup = Path(td) / "gen"
        shutil.copytree(gen, backup)
        vec = ROOT / "wire" / "golden_vectors.json"
        vec_backup = Path(td) / "golden_vectors.json"
        shutil.copy2(vec, vec_backup)

        code, out = run(["-m", "wire.codegen"])
        if code != 0:
            r.bad("A", f"codegen failed: {out.strip().splitlines()[-1:]}")
            return

        drifted = [f.name for f in sorted(gen.iterdir())
                   if f.is_file() and (not (backup / f.name).exists()
                                       or not filecmp.cmp(f, backup / f.name,
                                                          shallow=False))]
        if not filecmp.cmp(vec, vec_backup, shallow=False):
            drifted.append("golden_vectors.json")
        if drifted:
            r.bad("A", "generated files differ after regeneration "
                       f"(hand-edited?): {', '.join(drifted)}")
        else:
            r.ok("A", "wire codecs regenerate byte-identically from wire_v2.yaml")


# ---------------------------------------------------------------- B
def invariant_b(r: Report) -> None:
    """No eval file may compute a grounding verdict of its own."""
    targets = list((ROOT / "content" / "eval").rglob("*.py"))
    if (ROOT / "eval").exists():
        targets += list((ROOT / "eval").rglob("*.py"))
    offenders: list[str] = []
    importers = 0
    for f in targets:
        if f.name == "__init__.py":
            continue
        src = f.read_text(encoding="utf-8")
        rel = f.relative_to(ROOT)
        for pattern, why in FORBIDDEN_IN_EVAL:
            if pattern.search(src):
                offenders.append(f"{rel}: {why}")
        if "safety.gate" in src or "from safety" in src:
            importers += 1
    if offenders:
        r.bad("B", "eval computes its own verdict -- the harness must import "
                   "safety.gate.evaluate and assert on ITS verdict, so the eval "
                   "cannot pass a gate the app does not run:\n        "
              + "\n        ".join(offenders))
    else:
        r.ok("B", f"no eval file computes its own grounding verdict "
                  f"({len(targets)} scanned, {importers} import safety.gate)")


# ---------------------------------------------------------------- C
def invariant_c(r: Report, db: Path) -> None:
    if not db.exists():
        r.bad("C", f"missing {db.relative_to(ROOT)}; build the archive first")
        return
    code, out = run(["-m", "safety.probes", "--db", str(db)])
    tail = [l for l in out.splitlines() if "checks passed" in l]
    if code == 0:
        r.ok("C", f"C3 probe suite: {tail[-1].strip() if tail else 'passed'}")
    else:
        r.bad("C", f"C3 probe suite failed: {tail[-1] if tail else out[-300:]}")


# ---------------------------------------------------------------- D
def invariant_d(r: Report, allow_unpinned: bool) -> None:
    code, out = run(["-m", "crypto.test_conformance"])
    if code != 0:
        bad = [l.strip() for l in out.splitlines() if l.strip().startswith("FAIL")]
        r.bad("D", "Noise conformance failed: " + ("; ".join(bad) or out[-300:]))
        return
    checks = next((l for l in out.splitlines() if l.startswith("checks=")), "")
    unpinned = "CONFORMANCE STATUS: UNPINNED" in out
    if unpinned and not allow_unpinned:
        r.bad("D", "vectors are UNPINNED. Invariant D currently proves only that "
                   "Android and iOS agree WITH EACH OTHER; two implementations "
                   "can agree and both be wrong. Drop a real vector file into "
                   "crypto/cacophony_vectors.json (see docs/PINNING_CACOPHONY.md), "
                   "or pass --allow-unpinned to acknowledge the gap.")
        return
    note = "  [UNPINNED, acknowledged]" if unpinned else "  [PINNED]"
    r.ok("D", f"Noise derivation chain + XX transcript reproduced ({checks}){note}")


# ---------------------------------------------------------------- E
def invariant_e(r: Report) -> None:
    """C1/C2 constraint gates and the tier tables."""
    android = ROOT / "android"
    ios = ROOT / "ios"

    grants = []
    for x in android.rglob("*.xml"):
        for line in x.read_text(encoding="utf-8", errors="ignore").splitlines():
            if ("uses-permission" in line
                    and "android.permission.INTERNET" in line
                    and 'tools:node="remove"' not in line):
                grants.append(str(x.relative_to(ROOT)))
    if grants:
        r.bad("E", f"C1: INTERNET permission granted in {grants}")
        return

    net = re.compile(r"URLSession|NSURLConnection|CFStream|Network\.framework")
    hits = [str(f.relative_to(ROOT)) for f in ios.rglob("*")
            if f.suffix in {".swift", ".m", ".mm"} and net.search(
                f.read_text(encoding="utf-8", errors="ignore"))]
    if hits:
        r.bad("E", f"C1: iOS networking API referenced in {hits}")
        return

    tele = re.compile(r"firebase|crashlytics|sentry|amplitude|mixpanel|appcenter", re.I)
    thits = [str(f.relative_to(ROOT))
             for base in (android, ios) for f in base.rglob("*")
             if f.suffix in {".kts", ".gradle", ".plist", ".yml", ".resolved"}
             and tele.search(f.read_text(encoding="utf-8", errors="ignore"))]
    if thits:
        r.bad("E", f"C2: telemetry dependency in {thits}")
        return

    code, out = run([str(ROOT / "scripts" / "check_tiers.py")])
    if code != 0:
        r.bad("E", "tier tables disagree across platforms")
        return
    r.ok("E", "C1 no network, C2 no telemetry, tier tables agree")


# ---------------------------------------------------------------- F
def invariant_f(r: Report) -> None:
    """Type-aware Kotlin cross-file symbol resolution (ci/symbols.py).

    Kotlin and Swift are NEVER COMPILED here, so A-E are structurally blind to
    an unresolved reference. That blind spot shipped a real inherited defect:
    Router.kt called store.forEachHeldOrderedByPriority() while the MessageStore
    interface declared no such member.

    The FIRST version of this invariant was a name-existence check and it FAILED
    its own negative control -- it reported ok with the defect reintroduced,
    because the concrete classes still declared the method. It was replaced, not
    tuned. ci/symbols.py --selftest is the standing proof that it fires.
    """
    code, out = run([str(ROOT / "ci" / "symbols.py")])
    tail = [l for l in out.splitlines() if "Kotlin files scanned" in l]
    if code == 0:
        r.ok("F", tail[-1].strip() if tail else "cross-file symbols resolve")
    else:
        found = [l.strip() for l in out.splitlines() if "UNRESOLVED" in l]
        r.bad("F", "unresolved cross-file call(s) -- compile errors A-E cannot "
                   "see because Kotlin is never compiled:\n        "
              + "\n        ".join(found))

# ---------------------------------------------------------------- G
def invariant_g(r: Report) -> None:
    """Integration reachability (ci/integration.py).

    A-F check that the reference implementation is CORRECT. None of them check
    that the product USES it. An external review found exactly that gap: the
    GMP/2 codec, the Noise session and the safety gate were all implemented,
    verified, and imported by neither app -- so at runtime the platforms still
    could not talk, the mesh still sent plaintext, and the apps still gated on
    the 0.35 RRF floor the audit had already proven inert.

    That is this repository's own root cause one level up: the fix existed, was
    verified, and was orphaned. G makes orphaning a merge block.
    """
    code, out = run([str(ROOT / "ci" / "integration.py")])
    warns = [l.strip() for l in out.splitlines() if l.strip().startswith("warn")]
    if code == 0:
        note = f"  [{len(warns)} warning(s)]" if warns else ""
        r.ok("G", f"integration checks hold; unfinished mesh paths remain fail-closed{note}")
    else:
        found = [l.strip() for l in out.splitlines() if "ORPHANED" in l]
        r.bad("G", "integration or fail-closed controls failed:\n        "
              + "\n        ".join(found))


def main() -> int:
    ap = argparse.ArgumentParser(description="Godstone parity and safety gate")
    ap.add_argument("--db", type=Path,
                    default=ROOT / "dist" / "archive_medium.db")
    ap.add_argument("--allow-unpinned", action="store_true",
                    help="accept UNPINNED Noise vectors (acknowledges that "
                         "conformance rests on an unvalidated reference)")
    args = ap.parse_args()

    print("Godstone parity + safety gate\n" + "=" * 62)
    r = Report()
    invariant_a(r)
    invariant_b(r)
    invariant_c(r, args.db)
    invariant_d(r, args.allow_unpinned)
    invariant_e(r)
    invariant_f(r)
    invariant_g(r)

    print("=" * 62)
    print(f"passed={len(r.passed)} failed={len(r.failed)}")
    if r.failed:
        print("FAILED: " + ", ".join(sorted(set(r.failed))))
        return 1
    print("all invariants hold")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
