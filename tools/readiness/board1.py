#!/usr/bin/env python3
"""*** BOARD 1: THE ONE REPOSITORY-OWNED ROAD TO `verify` AND `freeze`. ***

*THE OBLIGATION: "Add `tools/readiness/board1.py` (helper) plus a `board1 verify|freeze` subcommand in
`tools/readiness/run.py`: `verify` runs the ordered internal gate set importably and prints one verdict; `freeze
--run-id R --tag T --attest-out P` performs the freeze sequence."*

*** WHY A SINGLE OBVIOUS PATH RATHER THAN A LIST OF COMMANDS IN A DOCUMENT. *** *A reader who must assemble the gate set
from prose will run a subset, and a subset that is green readeth as the whole being green -- which is the vacuous-green
class this programme keeps removing.* **HERE THE SET IS ONE PYTHON LIST, IN ORDER, WITH EACH ENTRY NAMED AND ITS EXIT
CODE CHECKED; `verify` runneth them all and printeth ONE verdict.**

**AND `freeze` IS DELIBERATELY NON-CIRCULAR:** *the candidate commit carrieth `run_id: null` (it cannot name a run that
has not happened yet), the tag is created on that commit, the push produceth the hosted run, and ONLY THEN is the
attestation written against `--run-id` -- so no artifact ever claims a result it could not have known.*
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# ----------------------------------------------------------------------------------------------------------------
# *** THE ORDERED INTERNAL GATE SET. ***
#
# *Each entry is `(label, argv)`. The order is the order a reader should run them: the cheap structural checks first,
# then the lanes, then the campaign that runs harnesses.*
# ----------------------------------------------------------------------------------------------------------------
GATES: list[tuple[str, list[str]]] = [
    ("candidate binding selftest", [sys.executable, "ci/check_candidate_binding.py", "--selftest"]),
    ("closure law", [sys.executable, "scripts/build_structured_closure.py", "--check"]),
    ("required runs", [sys.executable, "ci/check_required_runs.py"]),
    ("evidence digests", [sys.executable, "ci/check_evidence_digests.py"]),
    ("release gates status", [sys.executable, "ci/check_release_gates_status.py"]),
    ("blockers", [sys.executable, "tools/readiness/blockers.py", "--check"]),
    ("readiness suites", [sys.executable, "-m", "unittest", "discover", "-s", "tools/readiness/tests"]),
    ("lane results", [sys.executable, "ci/check_lane_results.py", "--scope", "all"]),
    ("mutation harness selftest", [sys.executable, "ci/mutations.py", "--selftest"]),
]

CLOSURE = ROOT / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"


def _run(argv: list[str], timeout: int = 3600) -> tuple[int, str]:
    """Run one gate from the REPOSITORY ROOT, returning `(rc, tail)`.

    *`capture_output` is used so the verdict is parsed rather than merely printed; the tail is returned so a refusal
    is DIAGNOSABLE from the caller's own output, which is the lesson the lane checker already paid for.*
    """
    proc = subprocess.run(argv, cwd=str(ROOT), capture_output=True, text=True, timeout=timeout)
    tail = ((proc.stdout or "") + (proc.stderr or "")).strip().splitlines()
    return proc.returncode, "\n".join(tail[-12:])


def verify(*, only: list[str] | None = None) -> int:
    """*** RUN THE ORDERED GATE SET AND PRINT ONE VERDICT. ***

    *A subset is allowed (`--only`), but the verdict then SAYETH it judged a subset -- so a partial run can never be
    quoted as the whole.* **Every failing gate is named WITH ITS OWN OUTPUT TAIL**, because a bare "one gate failed"
    would send the next reader hunting.
    """
    selected = [(lbl, argv) for lbl, argv in GATES if not only or lbl in only]
    if only:
        unknown = sorted(set(only) - {lbl for lbl, _ in GATES})
        if unknown:
            print(f"::error::unknown gate(s): {', '.join(unknown)}", file=sys.stderr)
            return 2
    failed: list[tuple[str, str]] = []
    print(f"BOARD 1 verify: {len(selected)} gate(s)"
          + (" (A SUBSET -- this is not the whole set)" if only else ""))
    for label, argv in selected:
        rc, tail = _run(argv)
        print(f"  {'PASS' if rc == 0 else 'FAIL'}  {label}  (rc={rc})")
        if rc != 0:
            failed.append((label, tail))
    if failed:
        print("\nBOARD 1 verify: FAILED")
        for label, tail in failed:
            print(f"\n--- {label} ---")
            print(tail)
        return 1
    print("\nBOARD 1 verify: PASSED" + (f" ({len(selected)} of {len(GATES)} gates)" if only else ""))
    return 0


def _sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, timeout=300)


def freeze(run_id: str, tag: str, attest_out: Path) -> int:
    """*** THE FREEZE SEQUENCE: TAG ON THE COMMIT, BIND THE HOSTED RUN, WRITE THE ATTESTATION. ***

    *IT REFUSES TO PERFORM THE PARTS A HUMAN MUST DO (the tag creation and the push), and it CHECKS they happened
    before it writes anything:* **a `freeze` that created its own tag would be attesting a state it had just made,
    which is the circularity this whole sequence exists to avoid.**
    """
    # (1) THE TAG MUST ALREADY EXIST AND BE ANNOTATED -- created by a human against a commit that exists.
    peel = _git("rev-parse", f"{tag}^{{commit}}")
    obj = _git("rev-parse", tag)
    if peel.returncode != 0:
        print(f"::error::candidate tag {tag!r} does not exist -- create it first "
              f"(`git tag -a {tag} <commit> -m '<identity>'`) and push it", file=sys.stderr)
        return 1
    peeled, tag_object = peel.stdout.strip(), obj.stdout.strip()
    if tag_object == peeled:
        print(f"::error::candidate tag {tag!r} is LIGHTWEIGHT -- it carrieth no tag object and can be re-pointed "
              f"without trace", file=sys.stderr)
        return 1
    tree = _git("rev-parse", f"{peeled}^{{tree}}").stdout.strip()

    # (2) THE CITED RUN MUST BE THE CANDIDATE'S OWN, WITH THE WHOLE GREEN SHAPE.
    sys.path.insert(0, str(ROOT / "ci"))
    import check_candidate_binding as ccb  # noqa: PLC0415 - imported here so a missing module degrades loudly
    facts = ccb._run_facts(run_id)
    if facts is None:
        print(f"::error::hosted run {run_id} could NOT be read -- a freeze may not cite a run it cannot verify",
              file=sys.stderr)
        return 1
    if facts.get("head_sha") != peeled:
        print(f"::error::hosted run {run_id} reports head_sha {facts.get('head_sha')} but {tag!r} peels to {peeled} "
              f"-- A GREEN RUN FROM ANOTHER SHA CANNOT BE BORROWED", file=sys.stderr)
        return 1
    for what, want in (("conclusion", "success"), ("workflow", "repository-verification"),
                       ("event", "push"), ("status", "completed")):
        if facts.get(what) != want:
            print(f"::error::hosted run {run_id} carrieth {what}={facts.get(what)!r}, not {want!r}", file=sys.stderr)
            return 1
    jobs = facts.get("jobs") or []
    if len(jobs) != 6 or any(j.get("conclusion") != "success" for j in jobs):
        print(f"::error::hosted run {run_id} carrieth {len(jobs)} job(s) and/or a non-successful one -- ALL SIX must "
              f"be success: {jobs}", file=sys.stderr)
        return 1

    # (3) NO POST-TAG TRACKED EDIT OUTSIDE THE ATTESTATION'S OWN PATH.
    allow = ("docs/remediation/evidence/",)
    delta = ccb._tree_delta(peeled, allow=allow)
    if delta:
        print(f"::error::the tree has moved since {tag!r} was tagged: {delta[:6]} -- only {list(allow)} may move "
              f"after the tag", file=sys.stderr)
        return 1

    # (4) *** THE AT-TAG DIGESTS: THE CLOSURE RECORD AND THE LEDGER AS THEY STOOD AT THE CANDIDATE. ***
    # *A digest taken now would describe the WORKING tree; the attestation must describe the CANDIDATE.*
    closure_at = ccb._file_at(peeled, "docs/production-readiness/BOARD1_CLOSURE.json")
    ledger_at = ccb._file_at(peeled, "docs/remediation/REMEDIATION_STATE.json")
    if closure_at is None or ledger_at is None:
        print(f"::error::candidate {tag!r} carrieth no closure record and/or ledger at the tag", file=sys.stderr)
        return 1
    try:
        closure_doc = json.loads(closure_at)
    except ValueError as exc:
        print(f"::error::the closure record at {tag!r} is not valid JSON: {exc}", file=sys.stderr)
        return 1
    if closure_doc.get("status") != "READY_FOR_EXTERNAL_REAUDIT":
        print(f"::error::the closure record at {tag!r} carrieth status {closure_doc.get('status')!r}, not "
              f"READY_FOR_EXTERNAL_REAUDIT -- a freeze binds a candidate that claimeth readiness", file=sys.stderr)
        return 1
    if closure_doc.get("verified_fixed") not in (None, 0):
        print(f"::error::the closure record at {tag!r} carrieth verified_fixed="
              f"{closure_doc.get('verified_fixed')!r} -- only the INDEPENDENT auditor may write it", file=sys.stderr)
        return 1

    attestation = {
        "candidate_ref": tag,
        "candidate_sha": peeled,
        "candidate_tree_sha": tree,
        "tag_object_sha": tag_object,
        "closure_record_sha": peeled,
        "run": {
            "id": int(run_id) if str(run_id).isdigit() else run_id,
            "attempt": facts.get("run_attempt"),
            "workflow": facts.get("workflow"),
            "event": facts.get("event"),
            "head_sha": facts.get("head_sha"),
            "conclusion": facts.get("conclusion"),
            "jobs": facts.get("jobs"),
        },
        "at_tag_closure_sha256": hashlib.sha256(closure_at.encode("utf-8")).hexdigest(),
        "at_tag_ledger_sha256": hashlib.sha256(ledger_at.encode("utf-8")).hexdigest(),
        "measured_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "builder_verdict": "READY_FOR_EXTERNAL_REAUDIT",
        # *** THE AUDITOR'S BLOCK STAYS NULL: ONLY AN INDEPENDENT AUDIT MAY WRITE IT. ***
        "auditor": {"verdict": None, "signed_at": None},
    }
    attest_out.parent.mkdir(parents=True, exist_ok=True)
    attest_out.write_text(json.dumps(attestation, indent=1) + "\n", encoding="utf-8")
    print(f"FREEZE: {tag} -> {peeled} (tree {tree}) bound to run {run_id} attempt "
          f"{facts.get('run_attempt')} 6/6 success")
    print(f"  attestation written to {attest_out}")
    print(f"  auditor block stays NULL: the terminal builder verdict is READY_FOR_EXTERNAL_REAUDIT, "
          f"NEVER VERIFIED_FIXED")
    return 0


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Board 1: the repository-owned verify/freeze road")
    sub = ap.add_subparsers(dest="command", required=True)
    p_verify = sub.add_parser("verify", help="run the ordered internal gate set and print one verdict")
    p_verify.add_argument("--only", action="append", default=None,
                          help="run only this gate (repeatable); the verdict then SAYETH it judged a subset")
    p_freeze = sub.add_parser("freeze", help="write the freeze attestation against a hosted run")
    p_freeze.add_argument("--run-id", required=True)
    p_freeze.add_argument("--tag", required=True)
    p_freeze.add_argument("--attest-out", required=True)
    args = ap.parse_args(argv)
    if args.command == "verify":
        return verify(only=args.only)
    if args.command == "freeze":
        return freeze(args.run_id, args.tag, Path(args.attest_out))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
