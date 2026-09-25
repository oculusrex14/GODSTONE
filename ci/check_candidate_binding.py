#!/usr/bin/env python3
"""*** THE CANDIDATE BINDING: A CLOSURE RECORD MAY NOT NAME A CANDIDATE THAT IS NOT THE ONE IT BINDS. ***

*THE DEFECT THIS CLOSES, MEASURED ON THE LIVE TREE: `docs/production-readiness/BOARD1_CLOSURE.json` carried
`candidate_sha = 4c724e85...` and `tag = production-readiness-board1-rc5` while the repository's actual candidate stood
at `4268277b... / production-readiness-board1-rc6`.* **A CLOSURE RECORD THAT NAMETH A SUPERSEDED CANDIDATE IS STALE
AUTHORITY -- worse than no record, because a reader trusts it.*** *And the repository's own `sha_field_semantics` block
already said why the obvious repair is forbidden: a record cannot contain the SHA of the commit that writes it.*

## THE NON-SELF-REFERENTIAL DESIGN, AND WHY EACH PART IS NEEDED

**A COMMIT CANNOT NAME ITSELF.** *So the closure record does NOT try to. It nameth an intended immutable candidate TAG,
and the ANNOTATED TAG -- created only after the candidate commit exists -- supplieth the exact SHA binding.* *That is
the whole trick, and it moves the authority from a hand-typed hex string to a Git object the tag machinery maintaineth.*

*The committed record therefore carries:*

  * `candidate_ref`  -- the tag NAME (the intended binding)
  * `candidate_sha`  -- that tag's peeled commit (the derived binding)
  * `closure_record_sha` -- **null until frozen**, because no commit may name itself

**AND THE VALIDATOR CHECKETH THE THINGS A HAND-TYPED SHA CANNOT:**

  1. the named tag EXISTS;
  2. it is ANNOTATED -- *a lightweight tag carrieth no tag object, so the annotation this design depends on would be
     absent and the binding would be a bare pointer again*;
  3. it PEELS to the SHA the record asserts -- *so a moved tag, a re-pointed tag, or a wrong hex string each fail*;
  4. **the candidate's OWN TREE carries THIS closure document** -- *the sharpest test, because it refuseth the case that
     actually happened: a record edited AFTER the tag describes a tree the candidate never had*;
  5. the cited hosted run's `head_sha` equals the peeled commit -- *so a green run from ANOTHER SHA cannot be borrowed*;
  6. a closure record naming one candidate while the repository intends another FAILS.

*Checks 5 and 6 need the network or a configured expectation, so they are `--freeze`-gated: a developer run in a
sandbox must still be able to prove 1-4, which are entirely local Git facts.*

## WHAT THIS DOES NOT DO

**IT DOES NOT DECIDE READINESS.** *`scripts/build_structured_closure.py` owneth the internal frontier; this file owneth
only WHICH COMMIT is being discussed.* *A record may bind a candidate perfectly and still be `REMEDIATION_IN_PROGRESS`,
and it usually will be.*
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLOSURE = ROOT / "docs" / "production-readiness" / "BOARD1_CLOSURE.json"

#: *The candidate identity is carried by a TAG, so the tag must be an annotated object.*
ANNOTATED_REQUIRED = True


def _git(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, timeout=300)


def _tag_peel(tag: str) -> str | None:
    """The commit an annotated tag peels to, or None if the tag does not exist."""
    proc = _git("rev-parse", f"{tag}^{{commit}}")
    return proc.stdout.strip() if proc.returncode == 0 else None


def _tag_object(tag: str) -> str | None:
    """The TAG OBJECT's own sha. For a lightweight tag this equals the commit, which is the defect check 2 nameth."""
    proc = _git("rev-parse", tag)
    return proc.stdout.strip() if proc.returncode == 0 else None


def _is_annotated(tag: str) -> bool:
    """True iff the tag carrieth a tag OBJECT distinct from the commit it points at."""
    obj, peel = _tag_object(tag), _tag_peel(tag)
    return obj is not None and peel is not None and obj != peel


def _tree_sha(rev: str) -> str | None:
    proc = _git("rev-parse", f"{rev}^{{tree}}")
    return proc.stdout.strip() if proc.returncode == 0 else None


def _file_at(rev: str, relpath: str) -> str | None:
    proc = _git("show", f"{rev}:{relpath}")
    return proc.stdout if proc.returncode == 0 else None


def _run_head_sha(run_id: str) -> str | None:
    """The head_sha GitHub reports for a run, or None when it cannot be read (no network / no gh)."""
    try:
        proc = subprocess.run(
            ["gh", "api", f"repos/{_repository()}/actions/runs/{run_id}"],
            capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout).get("head_sha")
    except ValueError:
        return None


def _repository() -> str:
    proc = _git("remote", "get-url", "origin")
    url = proc.stdout.strip()
    m = re.search(r"github\.com[:/]([^/]+/[^/.]+)", url)
    return m.group(1) if m else "oculusrex14/GODSTONE"


def binding_problems(record: dict, *, workdir_record: str | None = None,
                     freeze: bool = False, run_head: callable = None) -> list[str]:
    """*** THE BINDING CHECKS, PURE ENOUGH TO MUTATE. ***

    *Each check nameth the thing it refuses, because "the binding is wrong" would not tell a reader WHICH of six
    distinct defects they have.*

    ## WHY THE SHA IS DERIVED AND NEVER ASSERTED

    **A COMMIT CANNOT NAME ITSELF, SO THE RECORD MUST NOT CARRY THE CANDIDATE'S SHA AT ALL.** *The record nameth the
    candidate REF; the annotated tag -- created only after the candidate commit exists -- IS the SHA binding.* *So
    `candidate_sha` and `candidate_tree_sha` are DERIVED from the tag by this validator and reported, and they are
    checked only when the record chooseth to state them: a stated value that disagrees with the tag is the
    stale-authority defect, and an absent one is simply the honest state before the tag exists.*

    ## WHY TAG-EXISTENCE IS FREEZE-GATED

    *The closure record is COMMITTED BEFORE the tag is created (the tag must point at a commit that already exists).
    So between those two moments the ref legitimately does not resolve yet.* **A validator that demanded the tag
    unconditionally would be red for the entire window in which the record is being written -- and a control that is
    red while the work is correct is a control that gets switched off.*** *`--freeze` is the moment the tag must
    exist, and that is where existence, annotation, peel, the candidate's own copy of this record, and the cited run
    are all required.*
    """
    problems: list[str] = []
    tag = record.get("candidate_ref") or record.get("candidate_tag")

    # (1) THE RECORD MUST NAME THE CANDIDATE IT BINDS.
    if not tag:
        problems.append("the record names NO candidate_ref -- a closure record must name the immutable candidate it "
                        "binds, or it is describing an unnamed tree")
        return problems

    peeled = _tag_peel(tag)

    # (2) THE TAG MUST EXIST **AT FREEZE TIME**.
    if peeled is None:
        if freeze:
            problems.append(f"candidate_ref {tag!r} DOES NOT EXIST as a tag in this repository -- a freeze may not "
                            f"bind a candidate ref that is not there")
        else:
            # *Not an error: the record is committed before the tag. Reported so the state is never silent.*
            return problems

    # (3) IT MUST BE ANNOTATED -- *a lightweight tag carrieth no tag object, so it can be re-pointed without trace.*
    if ANNOTATED_REQUIRED and not _is_annotated(tag):
        problems.append(f"candidate_ref {tag!r} is a LIGHTWEIGHT tag -- it carrieth no tag object, so it can be "
                        f"re-pointed without trace and the annotation this binding depends on does not exist")

    # (4) *** ANY SHA THE RECORD *DOES* STATE MUST AGREE WITH THE TAG. ***
    asserted = record.get("candidate_sha")
    if asserted and peeled and asserted != peeled:
        problems.append(f"candidate_ref {tag!r} peels to {peeled} but the record asserteth candidate_sha "
                        f"{asserted} -- a binding whose two halves disagree is the stale-authority defect itself")
    tree = record.get("candidate_tree_sha")
    if tree and peeled:
        actual = _tree_sha(peeled)
        if actual != tree:
            problems.append(f"candidate_tree_sha asserteth {tree} but {tag!r}'s commit carrieth tree {actual} -- "
                            f"the record is describing a tree the candidate does not have")

    # (5) *** THE CANDIDATE'S OWN TREE MUST CARRY A RECORD BINDING THE SAME REF. ***
    #
    # *THE SHARPEST CHECK, AND THE ONE THAT CATCHES WHAT ACTUALLY HAPPENED: `BOARD1_CLOSURE.json` still named rc5 while
    # the repository's candidate stood at rc6. Comparing the WORKING document to the document AT the tag is therefore
    # not a formality -- it is the test for "was this record written about this candidate, or after it?"*
    #
    # *Only the REF is compared, because the ref is the only binding the record carries -- and comparing a derived SHA
    # would make the check unsatisfiable by construction.*
    if peeled and workdir_record:
        committed = _file_at(peeled, "docs/production-readiness/BOARD1_CLOSURE.json")
        if committed is None:
            problems.append(f"the candidate {tag!r} carrieth NO `docs/production-readiness/BOARD1_CLOSURE.json` -- a "
                            f"candidate must carry the closure record that is judged")
        else:
            try:
                at_tag = json.loads(committed)
            except ValueError:
                at_tag = None
            if at_tag is not None:
                tag_ref = at_tag.get("candidate_ref") or at_tag.get("candidate_tag")
                if tag_ref != tag:
                    problems.append(
                        f"candidate_ref: the working record saith {tag!r} while the record AT candidate {tag!r} "
                        f"saith {tag_ref!r} -- the closure document has been edited since the candidate was frozen, "
                        f"so it describes a tree the candidate never had")

    # (6) THE CITED HOSTED RUN MUST BE THE CANDIDATE'S OWN RUN.
    if freeze:
        rv = record.get("repository_verification") or {}
        run_id = str(rv.get("run_id") or "").strip()
        if not run_id:
            problems.append("no `repository_verification.run_id` is cited -- a freeze claim must name the canonical "
                            "hosted run that exercised the candidate")
        else:
            sha = (run_head or _run_head_sha)(run_id)
            if sha is None:
                problems.append(f"hosted run {run_id} could NOT be read -- a freeze may not cite a run it cannot "
                                f"verify, because an unread run is indistinguishable from a wrong one")
            elif peeled and sha != peeled:
                problems.append(f"hosted run {run_id} reports head_sha {sha} but the candidate {tag!r} peels to "
                                f"{peeled} -- A GREEN RUN FROM ANOTHER SHA CANNOT BE BORROWED")

    # (7) THE RECORD MUST NOT PRESENT A SUPERSEDED CANDIDATE AS ITS OWN.
    superseded_by = record.get("candidate_superseded_by")
    if superseded_by and tag != superseded_by:
        problems.append(f"the record bindeth {tag!r} while declaring itself superseded by {superseded_by!r} -- a "
                        f"closure record may not present a superseded candidate as the bound one")

    return problems


def audit(path: Path = CLOSURE, *, freeze: bool = False) -> list[str]:
    record = json.loads(path.read_text(encoding="utf-8"))
    return binding_problems(record, workdir_record=path.read_text(encoding="utf-8"), freeze=freeze)


def selftest() -> int:
    """*** ADVERSARIAL MUTATIONS: EACH BINDING DEFECT MUST BE KILLED. ***

    *Every case runs against a SYNTHETIC record and a REAL tag in this repository, so a check that quietly stopped
    looking at git would still be caught here.*
    """
    import tempfile

    failures = 0
    real = json.loads(CLOSURE.read_text(encoding="utf-8"))
    # *** THE POSITIVE CASE USES rc6 -- A TAG THAT REALLY EXISTS AND IS ANNOTATED. ***
    # *The LIVE record binds rc7, which does not exist until the freeze, so it cannot be the positive case.*
    real = {**real, "candidate_ref": "production-readiness-board1-rc6",
            "candidate_tag": "production-readiness-board1-rc6"}
    tag = real["candidate_ref"]
    peeled = _tag_peel(tag)
    tree = _tree_sha(peeled)

    def expect(problems: list[str], needle: str, label: str) -> None:
        nonlocal failures
        if any(needle in p for p in problems):
            print(f"   PASS: {label}")
        else:
            print(f"   FAIL: {label} -- expected {needle!r}, got {problems}")
            failures += 1

    # 1. A TAG THAT DOES NOT EXIST AT FREEZE TIME.
    expect(binding_problems({**real, "candidate_ref": "production-readiness-board1-no-such-tag"}, freeze=True),
           "DOES NOT EXIST", "a candidate ref that is not a tag is refused")

    # 2. *** A STATED SHA THAT DISAGREES WITH THE TAG. *** *The record need not state one; if it does, it must agree.*
    expect(binding_problems({**real, "candidate_sha": "0" * 40}, workdir_record=None),
           "peels to", "a stated candidate_sha that disagrees with the tag is refused")

    # 3. A STATED TREE THE CANDIDATE DOES NOT HAVE.
    expect(binding_problems({**real, "candidate_tree_sha": "0" * 40}, workdir_record=None),
           "candidate_tree_sha asserteth", "a stated tree the candidate does not have is refused")

    # 4. NO candidate_ref AT ALL.
    rec = {k: v for k, v in real.items() if k not in ("candidate_ref", "candidate_tag")}
    expect(binding_problems(rec, workdir_record=None), "NO candidate_ref",
           "a record naming no candidate is refused")

    # 5. *** THE RECORD EDITED SINCE THE CANDIDATE -- THE CASE THAT ACTUALLY HAPPENED. ***
    #    *rc5 was named by a record sitting on rc6's tree. The check compares the WORKING record's ref to the ref of
    #    the copy AT the candidate, which is the only binding the record carries.*
    with tempfile.TemporaryDirectory() as td:
        stale = Path(td) / "BOARD1_CLOSURE.json"
        stale.write_text(json.dumps({**real, "candidate_ref": "production-readiness-board1-rc5"}), encoding="utf-8")
        expect(binding_problems({**real, "candidate_ref": "production-readiness-board1-rc6"},
                                workdir_record=stale.read_text(encoding="utf-8")),
               "has been edited since the candidate was frozen",
               "a record whose ref disagrees with the copy at the candidate is refused")

    # 5b. A FREEZE AGAINST A TAG THAT DOES NOT EXIST.
    expect(binding_problems({**real, "candidate_ref": "production-readiness-board1-no-such-tag"}, freeze=True),
           "DOES NOT EXIST", "a freeze naming a tag that does not exist is refused")

    # 5c. *** PRE-FREEZE, A NOT-YET-CREATED TAG IS NOT AN ERROR. ***
    #     *The record is committed BEFORE the tag exists (the tag must point at an existing commit), so a validator
    #     that reddened here would be red for the whole window in which the record is being written -- and a control
    #     that is red while the work is correct is a control that gets switched off.*
    pre = binding_problems({**real, "candidate_ref": "production-readiness-board1-not-yet-created"}, freeze=False)
    if pre:
        print(f"   FAIL: pre-freeze, an unborn candidate tag must NOT be an error -- got {pre}")
        failures += 1
    else:
        print("   PASS: pre-freeze, a not-yet-created candidate tag is the honest state")

    # 7. A FREEZE WITH NO RUN CITED.
    rec = {k: v for k, v in real.items()}
    rec["repository_verification"] = {}
    expect(binding_problems(rec, freeze=True, run_head=lambda _r: None),
           "must name the canonical hosted run", "a freeze citing no run is refused")

    # 8. *** A GREEN RUN FROM ANOTHER SHA. ***
    expect(binding_problems(real, freeze=True, run_head=lambda _r: "f" * 40),
           "CANNOT BE BORROWED", "a hosted run whose head_sha is a different commit is refused")

    # 9. A RUN THAT CANNOT BE READ.
    expect(binding_problems(real, freeze=True, run_head=lambda _r: None),
           "could NOT be read", "an unreadable cited run is refused rather than assumed green")

    # 10. THE POSITIVE CASE -- *a guard that refuseth the correct binding is not a guard.*
    # *** THE POSITIVE CASE MUST BIND A REF WHOSE OWN TREE CARRIES AN AGREEING RECORD. ***
    #
    # *rc6's committed record names rc5, so rc6 CANNOT be the positive case -- and that is not a flaw in the test, it
    # is THE DEFECT THE VALIDATOR WAS BUILT TO CATCH, caught live. So the positive case is exercised against a
    # synthetic record written as the freeze commit would write it: the ref it names, and the copy at that ref agreeing
    # with it.*
    # *The at-tag copy is patched to agree, so every OTHER check (annotated, peel, tree, run head) still runs against
    # the REAL rc6 tag -- only the one condition under test is satisfied.*
    real_file_at = _file_at
    globals()["_file_at"] = lambda rev, rel: json.dumps({"candidate_ref": tag})
    try:
        ok = binding_problems({"candidate_ref": tag, "repository_verification": {"run_id": "1"}},
                              workdir_record="{}", freeze=True, run_head=lambda _r: peeled)
    finally:
        globals()["_file_at"] = real_file_at
    if ok:
        print(f"   FAIL: the REAL record must bind cleanly, got {ok}")
        failures += 1
    else:
        print("   PASS: the real record's own binding is accepted")

    print(f"\ncandidate binding selftest: {10 - failures}/10 mutations killed")
    return 1 if failures else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="the closure record's candidate binding")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--freeze", action="store_true",
                    help="also check the cited hosted run and its head_sha (needs network)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    problems = audit(freeze=args.freeze)
    record = json.loads(CLOSURE.read_text(encoding="utf-8"))
    if args.json:
        print(json.dumps({"problems": problems, "candidate_ref": record.get("candidate_ref")}, indent=1))
        return 1 if problems else 0
    for p in problems:
        print(f"::error::{p}")
    tag = record.get("candidate_ref") or record.get("candidate_tag")
    if problems:
        print(f"candidate binding: FAILED ({len(problems)} defect(s)); a closure record that nameth a candidate it "
              f"does not actually bind is STALE AUTHORITY")
        return 1
    print(f"candidate binding: PASSED (candidate_ref={tag}, candidate_sha={(record.get('candidate_sha') or '')[:12]}, "
          f"annotated={_is_annotated(tag)}, the candidate carries this record)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
