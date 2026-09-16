#! /usr/bin/env python3
"""Every run-specific evidence digest in the remediation ledger, VERIFIED -- and EVERY registered
entry EXAMINED.

WHY THIS INSTRUMENT EXISTETH. It was written in round 278, for the NINTH species of this session's
control family. Before it, the digest check lived only in an AD-HOC SHELL ONE-LINER run by hand each
round: it resolved each registered path with `os.path.exists(p)` AGAINST THE WORKING DIRECTORY. 86 of
the 304 entries were bare RELATIVE paths (`ANDROID-02/green/...`), which resolve under neither the
checkout nor the evidence root -- so the check counted them as NEITHER an ok NOR a mismatch and
reported "218 ok, 0 mismatched" WHILE NEVER EXAMINING 28% OF WHAT IT CLAIMED TO HAVE AUDITED. The 86
files were all present and all correct; THE INSTRUMENT WAS BLIND, AND A DENOMINATOR QUIETLY SHRUNK IS
NOT A DENOMINATOR. A discipline that liveth only in a hand-typed command is not an instrument.

WHAT THIS INSTRUMENT DOETH, in the shape a control must have:

  1. IT READETH THE ROOT FROM THE RECORD. The canonical evidence root cometh from the ledger's own
     `evidence_root` field -- so the meaning of a relative path is RECORDED rather than assumed from
     whoever's shell happened to run the check. `--root` may override it for a deliberate experiment.

  2. IT RESOLVETH RELATIVE PATHS THE WAY THE RECORD MEANT THEM: against `<root>/<path>`, then against
     `<root>/REMEDIATION/<path>`, where the finding directories actually live.

  3. IT REFUSETH TO SKIP. An entry with no path, or a path that resolveth nowhere, is an ERROR NAMED
     WITH ITS FINDING ID -- never a silent omission. The check printeth its own denominator
     (registered / examined / verified / mismatched / unresolved / unnamed) and REQUIRETH that
     registered == examined + unresolved + unnamed, so it cannot quietly audit less than it claims.

  4. IT FAILETH LOUDLY: rc 1 with every defect listed, each as a `::error::` line.

Usage:
    python3 ci/check_evidence_digests.py [--ledger PATH] [--root PATH] [--json]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"


def resolve(path_text: str, root: Path):
    """Absolute paths are used as given; relative paths are the record's, not the shell's."""
    p = Path(path_text)
    if p.is_absolute():
        return p if p.exists() else None
    for base in (root, root / "REMEDIATION"):
        candidate = base / p
        if candidate.exists():
            return candidate
    return None


def audit(ledger_path: Path, root_override=None) -> dict:
    state = json.loads(Path(ledger_path).read_text(encoding="utf-8"))
    declared_root = root_override or state.get("evidence_root") or ""
    root = Path(declared_root)

    registered = examined = verified = 0
    unresolved, mismatched, unnamed = [], [], []

    for fid, entry in state.get("findings", {}).items():
        for index, ev in enumerate(entry.get("my_logs") or []):
            registered += 1
            path_text = (ev.get("log") or "").strip()
            if not path_text:
                unnamed.append("%s[%d] carrieth no path" % (fid, index))
                continue
            if not declared_root:
                unresolved.append((fid, path_text, "the ledger recordeth no evidence_root"))
                continue
            found = resolve(path_text, root)
            if found is None:
                unresolved.append((fid, path_text, "resolveth nowhere under the recorded root"))
                continue
            examined += 1
            actual = hashlib.sha256(found.read_bytes()).hexdigest()
            if actual == (ev.get("sha256") or ""):
                verified += 1
            else:
                mismatched.append((fid, path_text, ev.get("sha256") or "", actual))

    return {
        "ledger": str(ledger_path),
        "root": declared_root,
        "root_exists": bool(declared_root) and root.exists(),
        "registered": registered,
        "examined": examined,
        "verified": verified,
        "mismatched": [{"finding": f, "log": p, "registered": r, "actual": a} for f, p, r, a in mismatched],
        "unresolved": [{"finding": f, "log": p, "why": w} for f, p, w in unresolved],
        "unnamed": unnamed,
    }


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="verify every registered remediation evidence digest")
    ap.add_argument("--ledger", default=str(DEFAULT_LEDGER))
    ap.add_argument("--root", default=None, help="override the ledger's recorded evidence_root")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    r = audit(Path(args.ledger), args.root)

    # THE DENOMINATOR MUST ADD UP. If it doeth not, this instrument is the thing that is broken.
    accounted = r["examined"] + len(r["unresolved"]) + len(r["unnamed"])
    if accounted != r["registered"]:
        print("::error::the denominator is inconsistent: registered %d, accounted %d"
              % (r["registered"], accounted))
        return 1

    for item in r["unresolved"]:
        print("::error::evidence for %s resolveth nowhere: %s (%s)"
              % (item["finding"], item["log"], item["why"]))
    for item in r["unnamed"]:
        print("::error::evidence entry carrieth no path: %s" % item)
    for item in r["mismatched"]:
        print("::error::digest MISMATCH for %s: %s (recorded %s..., actual %s...)"
              % (item["finding"], item["log"], item["registered"][:12], item["actual"][:12]))

    if args.json:
        print(json.dumps(r, indent=1, ensure_ascii=False))
        return 1 if (r["mismatched"] or r["unresolved"] or r["unnamed"]) else 0

    print("evidence digests: %d registered | %d examined | %d verified | %d mismatched | %d unresolved | %d unnamed"
          % (r["registered"], r["examined"], r["verified"], len(r["mismatched"]),
             len(r["unresolved"]), len(r["unnamed"])))
    print("  root: %s%s" % (r["root"] or "<none recorded>", "" if r["root_exists"] else "  (MISSING)"))
    defects = len(r["mismatched"]) + len(r["unresolved"]) + len(r["unnamed"])
    if defects or not r["root_exists"]:
        print("evidence digests: FAILED (%d defect(s)); UNEXAMINED EVIDENCE IS NOT VERIFIED EVIDENCE" % defects)
        return 1
    print("evidence digests: PASSED (every registered entry examined, every digest matching)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
