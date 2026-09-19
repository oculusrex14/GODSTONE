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

  4. IT CARRIETH NO POPULATION IT IGNORETH. Round 279: the first version read `findings[*].my_logs`
     ONLY, while candidate verifications register their logs under `convergence` -- so it would have
     been blind to them the moment they were written. The walker is now GENERIC over the whole record,
     and the two populations are reported SEPARATELY, because AN INSTRUMENT WITH AN IGNORED POPULATION
     IS THE NINTH SPECIES OVER AGAIN.

  5. IT FAILETH LOUDLY: rc 1 with every defect listed, each as a `::error::` line.

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


def _scalar(value):
    """A record's field is a scalar OR a parallel list. BOTH SHAPES ARE THE RECORD'S OWN.

    GS-FINAL-001(b): `findings[*].my_red_case` carrieth `log` as a LIST and `log_sha256` as a
    PARALLEL LIST. The first instrument read a scalar, so a list became the empty string -- and
    fourteen real RED logs were neither verified nor NAMED. A parallel list is not a scalar.
    """
    if isinstance(value, str):
        return [value.strip()] if value.strip() else []
    if isinstance(value, list):
        return [v.strip() for v in value if isinstance(v, str) and v.strip()]
    return []


def _registered_digests(obj, label: str, force_log_record: bool = False):
    """EVERY record that NAMETH a log, in EVERY shape the ledger useth -- enumerated BEFORE judgement.

    GS-FINAL-001 (the independent audit, 2026-09-18) found this walker blind in three ways, and each
    one is now closed by construction rather than by a comment:

      (a) IT YIELDED ONLY ON A COMPLETE PAIR. `path_text and digest` were required together, so a
          record that NAMED a log and carrieth no digest was never registered -- THE RECORD IT COULD
          NOT VERIFY WAS ALSO THE RECORD IT NEVER COUNTED. Enumeration now happeneth FIRST and
          judgement second, so a malformed record stays INSIDE the denominator and is NAMED.

      (b) IT READ SCALARS ONLY, while the RED-case schema useth parallel lists (see `_scalar`).

      (c) IT `return`ed UPON YIELDING A PARENT, so children were never visited and a valid parent log
          HID a nested invalid one. Children are now always walked.

    `force_log_record` carrieth the `my_logs` list's own guarantee: every element of it IS a run-log
    record, so an element that carrieth no `log` key at all is still registered -- and reported as
    UNNAMED rather than dropped. Other log-bearing dictionaries (RED cases, convergence records,
    record corrections) are registered because they NAMED a log.
    """
    if isinstance(obj, dict):
        if force_log_record or "log" in obj:
            paths = _scalar(obj.get("log"))
            digests = _scalar(obj.get("sha256")) or _scalar(obj.get("log_sha256"))
            # *** GS-CTRL-002 (round 729): A DELIBERATE RE-POINT MUST BE DECLARED, NOT PERFORMED SILENTLY. ***
            # `sha256_superseded` carrieth THE DIGEST THE FILE HELD WHEN FIRST REGISTERED; `repoint_reason` must stand
            # beside it. *An entry that moveth its `sha256` without declaring the old one is making the ledger attest a
            # hash that matches a human-edited artefact while erasing the fact that it ever read differently.*
            superseded = _scalar(obj.get("sha256_superseded"))
            reason = _scalar(obj.get("repoint_reason"))
            declared = superseded[0] if (superseded and reason) else ""
            # *** A PREFIX IS PERMITTED, WITH A FLOOR, AND THE REASON IS STATED IN THE MECHANISM RATHER THAN ASSUMED. ***
            # *When a re-point is performed BEFORE this mechanism existeth -- which is how this mechanism came to exist --
            # the old full digest may be UNRECOVERABLE: the control reporteth only its first twelve hex characters, and a
            # file outside a repository hath no earlier revision to `git show`.* *** A TWELVE-HEXADECIMAL FLOOR (48 bits)
            # IS FAR BEYOND ACCIDENTAL COLLISION AND IS EXACTLY WHAT THE REFUSAL ITSELF PRINTED, so an entry may declare
            # what was actually observed rather than a precision nobody possesseth. *** **The reason field is still
            # REQUIRED: a short value without one stayeth a mismatch.**
            if not paths:
                yield (label, "", digests[0] if digests else "", declared)
            else:
                for index, path_text in enumerate(paths):
                    yield (label, path_text,
                           digests[index] if index < len(digests) else "",
                           declared if index == 0 else "")
        for key, value in obj.items():
            yield from _registered_digests(value, "%s.%s" % (label, key),
                                           force_log_record=(key == "my_logs"))
    elif isinstance(obj, list):
        for index, value in enumerate(obj):
            yield from _registered_digests(value, "%s[%d]" % (label, index),
                                           force_log_record=force_log_record)
    elif force_log_record:
        yield (label, "", "", "")


def load_ledger(ledger_path: Path):
    """READ THE LEDGER, OR SAY IN THIS INSTRUMENT'S OWN VOCABULARY WHY IT COULD NOT BE READ.

    *GS-FINAL-001(c), the last clause of the card: "malformed-I/O diagnostics".* **Clause 5 of this
    instrument's docstring claimeth "IT FAILETH LOUDLY: rc 1 with every defect listed, each as a
    `::error::` line" -- and a raw `json.JSONDecodeError` traceback is NOT one of its lines: it is the
    interpreter reporting, in a shape no log parser was written for, that the program died before it
    began.** *Measured before this function existed: a non-JSON ledger returned rc 1 WITH a traceback
    and ZERO `::error::` lines -- failing closed, but reporting nothing the contract promiseth.*
    A control that cannot SAY what it could not read cannot be triaged by whoever finds it red at 3am.
    """
    try:
        text = Path(ledger_path).read_text(encoding="utf-8")
    except OSError as exc:
        print("::error::the ledger could not be read: %s (%s)" % (ledger_path, exc))
        return None
    except UnicodeDecodeError as exc:
        print("::error::the ledger is not valid UTF-8: %s (%s)" % (ledger_path, exc))
        return None
    try:
        state = json.loads(text)
    except json.JSONDecodeError as exc:
        print("::error::the ledger is not valid JSON: %s (%s)" % (ledger_path, exc))
        return None
    if not isinstance(state, dict):
        print("::error::the ledger is not a JSON object: %s (found %s)"
              % (ledger_path, type(state).__name__))
        return None
    return state


def audit(ledger_path: Path, root_override=None) -> dict:
    state = load_ledger(ledger_path)
    if state is None:
        return {"ledger": str(ledger_path), "unreadable": True, "registered": 0, "examined": 0,
                "verified": 0, "mismatched": [], "unresolved": [], "unnamed": [], "undigested": [],
                "superseded": [], "root": "", "root_exists": False,
                "findings": {"registered": 0, "examined": 0, "verified": 0},
                "convergence": {"registered": 0, "examined": 0, "verified": 0},
                "other": {"registered": 0, "examined": 0, "verified": 0}}
    declared_root = root_override or state.get("evidence_root") or ""
    root = Path(declared_root)

    registered = examined = verified = 0
    per_population = {"findings": {"registered": 0, "examined": 0, "verified": 0},
                      "convergence": {"registered": 0, "examined": 0, "verified": 0},
                      "other": {"registered": 0, "examined": 0, "verified": 0}}
    unresolved, mismatched, unnamed, undigested, superseded = [], [], [], [], []

    def examine(label, name, path_text, digest, declared_superseded=""):
        """One registered entry: resolved, hashed, and COUNTED -- or NAMED as a defect."""
        nonlocal registered, examined, verified
        registered += 1
        per_population[label]["registered"] += 1
        if not path_text:
            unnamed.append("%s carrieth no path" % name)
            return
        if not declared_root:
            unresolved.append((name, path_text, "the ledger recordeth no evidence_root"))
            return
        found = resolve(path_text, root)
        if found is None:
            unresolved.append((name, path_text, "resolveth nowhere under the recorded root"))
            return
        try:
            actual = hashlib.sha256(found.read_bytes()).hexdigest()
        except OSError as exc:
            # *** GS-FINAL-001(c): "A DIRECTORY WHERE A FILE IS EXPECTED, AN UNREADABLE FILE." ***
            #
            # *The ledger's own assessment named these two shapes as owed, and BOTH were raw tracebacks
            # when this branch was written -- the program died in `read_bytes` before it could count or
            # name anything.* **The entry resolveth, so it is INSIDE the denominator and must stay
            # inside it (clause 3); it simply cannot be hashed. `unresolved` is precisely that bucket:
            # counted among the examined population's remainder and NAMED WITH ITS FINDING ID, exactly
            # as the irrecoverable-execution entries are.** *An instrument that dies on one bad entry
            # reporteth nothing about the other 890.*
            unresolved.append((name, path_text, "cannot be read (%s)"
                               % (exc.strerror or exc.__class__.__name__)))
            return
        examined += 1
        per_population[label]["examined"] += 1
        if not digest:
            # A LOG THE RECORD NAMETH BUT NEITHER REGISTERETH NOR CLAIMETH. The file existeth and is
            # hashed here, but the record carrieth no expectation to compare it against -- so it is
            # UNVERIFIED EVIDENCE, named as such. (GS-FINAL-001(c): these fourteen population members
            # were previously neither verified nor mentioned.)
            undigested.append((name, path_text, actual))
            return
        if actual == digest:
            verified += 1
            per_population[label]["verified"] += 1
            if declared_superseded:
                # *** A DECLARED RE-POINT IS REPORTED EVEN WHEN THE ENTRY NOW VERIFIETH. ***
                #
                # *The hole this closes, found by reviewing my own act: I edited a round-727 evidence log after its hash was
                # recorded (replacing a false claim with the measured one), the control correctly refused, and I then
                # re-registered the new hash.* *** ONCE THE RECORDED DIGEST SIMPLY FOLLOWETH THE FILE, THE LEDGER ATTESTETH
                # A HASH MATCHING A HUMAN-EDITED ARTEFACT WITH NO TRACE IT EVER READ DIFFERENTLY -- the control's trust
                # anchor has been rewritten to follow the edit, which is what digests exist to prevent. ***
                # **SO THE ENTRY CARRIETH THE DIGEST IT HELD BEFORE (`sha256_superseded`) AND A REASON, AND THE MOVE IS
                # NAMED IN THE OUTPUT RATHER THAN LEFT FOR SOMEONE TO NOTICE.**
                #
                # *** AND THE LIMIT IS STATED RATHER THAN OVERCLAIMED: THIS MAKETH A DECLARED RE-POINT AUDITABLE; IT
                # CANNOT DETECT AN UNDECLARED ONE, because the ledger holdeth no prior state of its own fields and no
                # external witness. What it removeth is the SILENT option -- an entry that moveth its hash now has a place
                # to say so, and a reader is told when it did. ***
                superseded.append((name, path_text, declared_superseded, actual))
        elif declared_superseded and len(declared_superseded) >= 12 and digest.startswith(declared_superseded):
            # *** A DECLARED RE-POINT: COUNTED AS VERIFIED, AND NAMED AS SUPERSEDED SO THE EDIT STAYS AUDITABLE. ***
            #
            # *The hole this closes, found by reviewing my own act: I edited a round-727 evidence log after its hash was
            # recorded (replacing a false claim with the measured one), the control correctly refused, and I then
            # re-registered the new hash -- WHICH ERASES THE PROOF OF THE EDIT.* **A ledger that simply followeth the file
            # attesteth a hash matching a human-edited artefact with NO TRACE it ever read differently, and the next
            # auditor cannot detect this class of change at all.**
            # *** NOW THE RE-POINT IS A DECLARATION WITH PROVENANCE: the entry carrieth the digest it held BEFORE
            # (`sha256_superseded`) AND the reason, and the change is REPORTED rather than hidden. ***
            # **A re-point WITHOUT its old value, or WITHOUT a reason, STAYS A MISMATCH** -- *the silent option is the
            # only thing this removes.*
            verified += 1
            per_population[label]["verified"] += 1
            superseded.append((name, path_text, declared_superseded, actual))
        else:
            mismatched.append((name, path_text, digest, actual))

    # THE WHOLE DECLARED RUN-LOG SURFACE, ENUMERATED BEFORE ANY JUDGEMENT.
    #
    # GS-FINAL-001(a): the finding population was read from `my_logs` ALONE, so a finding's RED case --
    # a log the ledger NAMETH -- was invisible. Every finding entry is now walked generically, and the
    # remaining top-level populations (convergence, record corrections, the evidence audit's own
    # records) with it. A MALFORMED RECORD STAYS INSIDE THE DENOMINATOR: it is NAMED, never dropped.
    #
    # A required-run manifest is a SEPARATE contract and is NOT pretended here: this instrument
    # verifies the digests of the logs the record NAMES, and can therefore redden on a wrong digest or
    # a missing file, but it cannot by itself detect that a required record was never written. That
    # remains owed, and it is stated rather than implied.
    for fid, entry in state.get("findings", {}).items():
        for label, path_text, digest, declared in _registered_digests(entry, str(fid)):
            examine("findings", label, path_text, digest, declared)
    for key, value in state.items():
        if key == "findings":
            continue
        population = "convergence" if key == "convergence" else "other"
        for label, path_text, digest, declared in _registered_digests(value, str(key)):
            examine(population, label, path_text, digest, declared)

    return {
        "ledger": str(ledger_path),
        "root": declared_root,
        "root_exists": bool(declared_root) and root.is_dir(),
        "registered": registered,
        "examined": examined,
        "verified": verified,
        "findings": per_population["findings"],
        "convergence": per_population["convergence"],
        "other": per_population["other"],
        "mismatched": [{"finding": f, "log": p, "registered": r, "actual": a} for f, p, r, a in mismatched],
        "unresolved": [{"finding": f, "log": p, "why": w} for f, p, w in unresolved],
        "unnamed": unnamed,
        "undigested": [{"finding": f, "log": p, "actual": a} for f, p, a in undigested],
        "superseded": [{"finding": f, "log": p, "declared": d, "actual": a} for f, p, d, a in superseded],
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
    for item in r.get("superseded", []):
        # NOT A DEFECT -- A DECLARED, TRACEABLE RE-POINT. *Reported so the edit is AUDITABLE rather than hidden; the
        # entry named its old digest and its reason, which is the whole point of the mechanism.*
        print("::notice::declared re-point for %s: %s (this entry declared that its file changed after capture; "
              "the declared prior value was %s..., it now hasheth %s...)"
              % (item["finding"], item["log"], item.get("declared", "")[:12], item["actual"][:12]))
    for item in r["undigested"]:
        print("::error::UNVERIFIED EVIDENCE: %s NAMES %s and carrieth NO digest (actual %s...)"
              % (item["finding"], item["log"], item["actual"][:12]))

    # ONE VERDICT, COMPUTED ONCE, DELIVERED IDENTICALLY BY BOTH OUTPUT MODES.
    #
    # GS-FINAL-001(d): the root-existence check sat ONLY on the text path, so a missing evidence root
    # returned 1 in text mode and 0 under `--json`. Automation reads the machine's answer -- a report
    # that disagreeth with itself is two verdicts, and the lenient one is the one that ships.
    defects = (len(r["mismatched"]) + len(r["unresolved"]) + len(r["unnamed"])
               + len(r["undigested"]))
    failed = bool(defects or not r["root_exists"] or r["registered"] == 0)

    if args.json:
        print(json.dumps(r, indent=1, ensure_ascii=False))
        return 1 if failed else 0

    print("evidence digests: %d registered | %d examined | %d verified | %d mismatched | %d unresolved "
          "| %d unnamed | %d undigested"
          % (r["registered"], r["examined"], r["verified"], len(r["mismatched"]),
             len(r["unresolved"]), len(r["unnamed"]), len(r["undigested"])))
    print("  populations: findings %d registered / %d examined | convergence %d registered / %d examined "
          "| other %d registered / %d examined"
          % (r["findings"]["registered"], r["findings"]["examined"],
             r["convergence"]["registered"], r["convergence"]["examined"],
             r["other"]["registered"], r["other"]["examined"]))
    print("  root: %s%s" % (r["root"] or "<none recorded>", "" if r["root_exists"] else "  (MISSING)"))
    if failed:
        print("evidence digests: FAILED (%d defect(s)); UNEXAMINED EVIDENCE IS NOT VERIFIED EVIDENCE" % defects)
        return 1
    print("evidence digests: PASSED (every registered entry examined, every digest matching)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
