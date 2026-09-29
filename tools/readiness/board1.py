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
import re
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
    # *** AND THE CAMPAIGN MANIFEST ITSELF -- THE SELFTEST ABOVE PROVES THE HARNESS DECIDETH; THIS PROVES A CAMPAIGN
    # RAN, WITH THE REQUIRED BOARD 1 IDS ALL KILLED AND THE PHASE HASHES AND TESTED-INPUT EQUALITY BOUND. ***
    #
    # *THE DEFECT THIS CLOSES: the gate set ran `ci/mutations.py --selftest` and NOTHING ELSE, so a `board1 verify`
    # could pass while the last real campaign -- the one that would produce the KILLED rows the closure cites -- had
    # never been run against this tree.* **`--group board1` names the required set, and the checker requirith the
    # campaign manifest it produced to bind the tested inputs and carry every required row.** *The manifest's path is
    # fixed (the campaign is invoked with `--emit-dir docs/remediation/evidence/board1-rc11-rods`), and the checker
    # refuseth an absent or unbound one rather than reading absence as success.*
    ("board1 campaign manifest",
     [sys.executable, "ci/mutations.py", "--selftest-manifest", "--group", "board1"]),
]

CLOSURE = ROOT / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"
LEDGER = ROOT / "docs" / "remediation" / "REMEDIATION_STATE.json"


def _run(argv: list[str], timeout: int = 3600) -> tuple[int, str, str]:
    """Run one gate from the REPOSITORY ROOT, returning `(rc, tail, full_output)`.

    *`capture_output` is used so the verdict is parsed rather than merely printed; the TAIL is returned for the
    concise terminal summary and the FULL output for the retained artifact, which is the lesson the lane checker
    already paid for.*
    """
    try:
        proc = subprocess.run(argv, cwd=str(ROOT), capture_output=True, text=True, timeout=timeout)
        rc, blob = proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except subprocess.TimeoutExpired as exc:
        # *** A HUNG GATE IS A FAILURE WITH ITS PARTIAL OUTPUT, NOT A LOST GATE. ***
        # *The default handler would propagate and take the whole verdict with it, leaving no artifact for the gate
        # that hung -- which is exactly the shape a run with no verdict wears.*
        rc = 124
        partial = exc.stdout or ""
        if isinstance(partial, bytes):
            partial = partial.decode("utf-8", "replace")
        blob = f"(the gate did not settle inside {timeout}s)\n{partial}"
    return rc, "\n".join(blob.strip().splitlines()[-12:]), blob


def verify(*, only: list[str] | None = None, artifact_dir: Path | None = None) -> int:
    """*** RUN THE ORDERED GATE SET AND PRINT ONE VERDICT. ***

    *A subset is allowed (`--only`), but the verdict then SAYETH it judged a subset -- so a partial run can never be
    quoted as the whole.* **Every failing gate is named WITH ITS OWN OUTPUT TAIL**, because a bare "one gate failed"
    would send the next reader hunting.

    *** AND EVERY GATE'S COMPLETE OUTPUT IS RETAINED, NOT ONLY THE LAST TWELVE LINES. *** *`board1._run` used to keep
    twelve lines and print them only on failure, so a PASSING gate's real evidence was discarded -- and the twelve lines
    of a FAILING one were the only artifact.* **A reader who must reconcile a verdict against the gate's own output
    needs the whole thing, so each gate writeth `<dir>/<slug>.log` with its exit status and full streams.**
    *The concise terminal summary is unchanged.*
    """
    selected = [(lbl, argv) for lbl, argv in GATES if not only or lbl in only]
    if only:
        unknown = sorted(set(only) - {lbl for lbl, _ in GATES})
        if unknown:
            print(f"::error::unknown gate(s): {', '.join(unknown)}", file=sys.stderr)
            return 2
    if artifact_dir is not None:
        artifact_dir.mkdir(parents=True, exist_ok=True)
    failed: list[tuple[str, str]] = []
    print(f"BOARD 1 verify: {len(selected)} gate(s)"
          + (" (A SUBSET -- this is not the whole set)" if only else ""))
    for label, argv in selected:
        rc, tail, blob = _run(argv)
        if artifact_dir is not None:
            slug = re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")
            (artifact_dir / f"{slug}.log").write_text(
                f"# gate: {label}\n# argv: {' '.join(argv)}\n# rc: {rc}\n\n{blob}",
                encoding="utf-8")
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


def freeze(run_id: str, tag: str, attest_out: Path, attempt: int) -> int:
    """*** THE FREEZE SEQUENCE: TAG ON THE COMMIT, BIND THE HOSTED RUN, WRITE THE ATTESTATION. ***

    *IT REFUSES TO PERFORM THE PARTS A HUMAN MUST DO (the tag creation and the push), and it CHECKS they happened
    before it writes anything:* **a `freeze` that created its own tag would be attesting a state it had just made,
    which is the circularity this whole sequence exists to avoid.**

    *** `--attempt N` IS MANDATORY, AND THE ATTEMPT IS FETCHED RATHER THAN COMPARED. ***
    // *The old road read `actions/runs/R` and `actions/runs/R/jobs` -- THE LATEST ATTEMPT'S ENDPOINTS -- and then
    // compared the returned `run_attempt` to a pinned number. If the pinned attempt had failed and a later re-run went
    // green, those endpoints answered GREEN and only the numeric comparison stood in the way; a caller who omitted the
    // attempt skipped even that.* **So the attempt is now REQUIRED, and `_run_facts` fetcheth `attempts/{N}` and
    // `attempts/{N}/jobs` -- the pinned attempt's own facts, which cannot be satisfied by a sibling attempt.**
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

    # *** AND THE REMOTE TAG MUST AGREE WITH THE LOCAL ONE -- A LOCAL TAG NOBODY PUSHED IS NOT THE BOUND ARTIFACT. ***
    remote = _git("ls-remote", "--tags", "origin", tag)
    if remote.returncode == 0 and remote.stdout.strip():
        remote_obj = remote.stdout.split()[0]
        if remote_obj != tag_object:
            print(f"::error::the REMOTE tag {tag!r} carrieth object {remote_obj} while the local one carrieth "
                  f"{tag_object} -- a moved or re-pointed remote tag is not the artifact the candidate froze",
                  file=sys.stderr)
            return 1
    else:
        print(f"::error::the remote (origin) carrieth NO tag {tag!r} -- the candidate tag must be PUSHED before a "
              f"freeze can bind it (a local-only tag is not the artifact a reader checks out)", file=sys.stderr)
        return 1

    # (2) THE CITED RUN MUST BE THE CANDIDATE'S OWN, WITH THE WHOLE GREEN SHAPE, FROM THE PINNED ATTEMPT.
    sys.path.insert(0, str(ROOT / "ci"))
    import check_candidate_binding as ccb  # noqa: PLC0415 - imported here so a missing module degrades loudly
    facts = ccb._run_facts(run_id, attempt=attempt)
    if facts is None:
        print(f"::error::hosted run {run_id} attempt {attempt} could NOT be read -- a freeze may not cite a run it "
              f"cannot verify", file=sys.stderr)
        return 1
    if facts.get("head_sha") != peeled:
        print(f"::error::hosted run {run_id} attempt {attempt} reports head_sha {facts.get('head_sha')} but {tag!r} "
              f"peels to {peeled} -- A GREEN RUN FROM ANOTHER SHA CANNOT BE BORROWED", file=sys.stderr)
        return 1
    if facts.get("run_attempt") != attempt:
        print(f"::error::hosted run {run_id} attempt {attempt} answered with run_attempt="
              f"{facts.get('run_attempt')!r} -- the attempt-specific endpoint did not describe the pinned attempt",
              file=sys.stderr)
        return 1
    for what, want in (("conclusion", "success"), ("workflow", "repository-verification"),
                       ("event", "push"), ("status", "completed")):
        if facts.get(what) != want:
            print(f"::error::hosted run {run_id} attempt {attempt} carrieth {what}={facts.get(what)!r}, not {want!r}",
                  file=sys.stderr)
            return 1
    # *** THE SIX EXACT JOB NAMES, WITH ANNOTATIONS -- DELEGATED TO THE ONE VALIDATOR, SO THE TWO ROADS AGREE. ***
    problems = ccb.binding_problems(
        {"candidate_ref": tag,
         "candidate_tree_sha": tree,
         "repository_verification": {"run_id": run_id, "run_attempt": attempt, "repository": facts.get("repository"),
                                     "branch": facts.get("head_branch")},
         "post_tag_attestation": None,   # set below, once the attestation path is known
         },
        workdir_record=ccb._file_at(peeled, "docs/production-readiness/BOARD1_CLOSURE.json"),
        freeze=True,
        run_facts=lambda _r: facts,
        tree_delta=lambda p: ccb._tree_delta(p, allow=(str(attest_out.relative_to(ROOT)),)),
        annotations=ccb._job_annotations,
        dirty_paths=lambda: ccb.dirty_tracked_paths(allow=(str(attest_out.relative_to(ROOT)),)),
    )
    # The record at the tag need not yet name the attestation path; only the run/jobs/delta/dirty clauses are judged
    # here, so a `candidate_ref` mismatch in the synthetic record above is filtered out deliberately.
    problems = [p for p in problems if "has been edited since the candidate was frozen" not in p]
    if problems:
        for p in problems:
            print(f"::error::{p}", file=sys.stderr)
        return 1

    # (3) *** THE AT-TAG DIGESTS: THE CLOSURE RECORD AND THE LEDGER AS THEY STOOD AT THE CANDIDATE. ***
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

    # *** AND AN EXISTING UNEQUAL ATTESTATION IS NEVER OVERWRITTEN. ***
    if attest_out.is_file():
        try:
            existing = json.loads(attest_out.read_text(encoding="utf-8"))
        except ValueError:
            existing = None
        new_stub = {"candidate_sha": peeled, "candidate_tree_sha": tree,
                    "run": {"id": int(run_id) if str(run_id).isdigit() else run_id, "attempt": attempt}}
        if existing != new_stub and existing is not None:
            print(f"::error::{attest_out} already existeth and describeth a DIFFERENT candidate/run -- an attestation "
                  f"is written once; refusing to overwrite it", file=sys.stderr)
            return 1

    attestation = {
        "schema": 1,
        "candidate_ref": tag,
        "candidate_sha": peeled,
        "candidate_tree_sha": tree,
        "tag_object_sha": tag_object,
        "closure_record_sha": peeled,
        "run": {
            "id": int(run_id) if str(run_id).isdigit() else run_id,
            "attempt": attempt,
            "workflow": facts.get("workflow"),
            "workflow_path": facts.get("path"),
            "event": facts.get("event"),
            "repository": facts.get("repository"),
            "head_branch": facts.get("head_branch"),
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
    print(f"FREEZE: {tag} -> {peeled} (tree {tree}) bound to run {run_id} attempt {attempt} 6/6 success")
    print(f"  attestation written to {attest_out}")
    print(f"  auditor block stays NULL: the terminal builder verdict is READY_FOR_EXTERNAL_REAUDIT, "
          f"NEVER VERIFIED_FIXED")
    return 0


def validate_attestation(path: Path) -> int:
    """*** READ-ONLY: RE-DERIVE EVERYTHING AN ATTESTATION CLAIMS, WITHOUT REWRITING IT. ***

    *THE DEFECT THIS CLOSES: the only way to check an attestation was to RUN `freeze`, WHICH IS A WRITER -- it
    regenerates the timestamp and rewrites the file, so "checking" an attestation MUTATED it and could not be done on
    a successor commit at all.* **So `verify --attestation` recomputeth the tag object, the peeled commit, the tree,
    the at-tag closure/ledger hashes and the pinned attempt's facts, and REFUSETH any disagreement -- taking no
    timestamp and writing no file.** *The derivation lives in `ci/check_candidate_binding.validate_attestation`, so
    this road and the checker's own selftest exercise ONE implementation.*
    """
    sys.path.insert(0, str(ROOT / "ci"))
    import check_candidate_binding as ccb  # noqa: PLC0415
    problems = ccb.validate_attestation(path)
    if problems:
        for p in problems:
            print(f"::error::{p}", file=sys.stderr)
        return 1
    att = json.loads(path.read_text(encoding="utf-8"))
    print(f"ATTESTATION VALID: {att.get('candidate_ref')} -> {att.get('candidate_sha')} "
          f"(tree {att.get('candidate_tree_sha')}); run {(att.get('run') or {}).get('id')} attempt "
          f"{(att.get('run') or {}).get('attempt')}; re-derived without rewriting the file")
    return 0


def main(argv=None) -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Board 1: the repository-owned verify/freeze road")
    sub = ap.add_subparsers(dest="command", required=True)
    p_verify = sub.add_parser("verify", help="run the ordered internal gate set and print one verdict")
    p_verify.add_argument("--only", action="append", default=None,
                          help="run only this gate (repeatable); the verdict then SAYETH it judged a subset")
    p_verify.add_argument("--artifacts", default=None,
                          help="verify: a directory to retain EVERY gate's full output (not only the twelve-line "
                               "summary), one <slug>.log per gate")
    p_verify.add_argument("--attestation", default=None,
                          help="READ-ONLY: re-derive the claims of a written freeze attestation instead of running "
                               "the gates; never regenerates the timestamp or rewrites the file")
    p_freeze = sub.add_parser("freeze", help="write the freeze attestation against a hosted run")
    p_freeze.add_argument("--run-id", required=True)
    p_freeze.add_argument("--attempt", type=int, required=True,
                          help="the run's ATTEMPT number (mandatory: the pinned attempt's own facts are fetched, "
                               "never the latest attempt's)")
    p_freeze.add_argument("--tag", required=True)
    p_freeze.add_argument("--attest-out", required=True)
    args = ap.parse_args(argv)
    if args.command == "verify":
        if args.attestation:
            return validate_attestation(Path(args.attestation))
        return verify(only=args.only,
                      artifact_dir=Path(args.artifacts) if args.artifacts else None)
    if args.command == "freeze":
        return freeze(args.run_id, args.tag, Path(args.attest_out), args.attempt)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
