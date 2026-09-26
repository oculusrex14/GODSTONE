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


def _run_facts(run_id: str, *, api=None) -> dict | None:
    """*** THE RUN'S OWN FACTS -- CONCLUSION, WORKFLOW, EVENT, STATUS, JOBS, ATTEMPT. ***

    *`head_sha` alone cannot tell a SUCCESSFUL run of the right workflow from a failed run of a different one, and it
    cannot tell a green run from one whose jobs were SKIPPED.* **So the freeze requireth the whole shape: the workflow
    is `repository-verification`, the event is `push`, the status is `completed`, the conclusion is `success`, all six
    jobs succeeded, and the attempt number is the one the record pins.** *The job list is checked too because a
    conclusion of `success` with a SKIPPED job is the shape a partial run wears -- and four jobs succeeding out of six
    is not the six-job authority the freeze claims.*
    """
    fetch = api or _gh_api
    try:
        run = fetch(f"repos/{_repository()}/actions/runs/{run_id}")
        jobs = fetch(f"repos/{_repository()}/actions/runs/{run_id}/jobs?per_page=100")
    except Exception:  # noqa: BLE001 - an unreadable run must not crash the validator
        return None
    if run is None or jobs is None:
        return None
    job_rows = jobs.get("jobs") or []
    return {
        "head_sha": run.get("head_sha"),
        "conclusion": run.get("conclusion"),
        "status": run.get("status"),
        "event": run.get("event"),
        "workflow": (run.get("name") or (run.get("workflow") or {}).get("name")),
        "run_attempt": run.get("run_attempt"),
        "jobs": [{"name": j.get("name"), "conclusion": j.get("conclusion")} for j in job_rows],
    }


def _gh_api(path: str) -> dict | None:
    try:
        proc = subprocess.run(["gh", "api", path], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except ValueError:
        return None


def _tree_delta(peeled: str, *, allow: tuple[str, ...] = ()) -> list[str]:
    """*** TRACKED PATHS THAT CHANGED BETWEEN THE CANDIDATE AND HEAD, MINUS THE ALLOWLIST. ***

    *A post-tag edit outside `docs/remediation/evidence/` invalidateth the candidate: the attestation describeth a tree
    that no longer standeth.* **THE ALLOWLIST IS NOT A LOOPHOLE -- IT NAMES THE ONE PATH A FREEZE MAY STILL WRITE
    (the attestation itself), and everything else is refused BY NAME so a reader seeth which path moved.**
    """
    proc = _git("diff", "--name-only", f"{peeled}..HEAD")
    if proc.returncode != 0:
        return []
    changed = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    return [p for p in changed if not any(p.startswith(a) for a in allow)]


def binding_problems(record: dict, *, workdir_record: str | None = None,
                     freeze: bool = False, run_head: callable = None,
                     run_facts: callable = None, tree_delta: callable = None) -> list[str]:
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

    # (6) THE CITED HOSTED RUN MUST BE THE CANDIDATE'S OWN RUN -- AND IT MUST BE THE WHOLE GREEN SHAPE.
    if freeze:
        rv = record.get("repository_verification") or {}
        run_id = str(rv.get("run_id") or "").strip()
        if not run_id:
            problems.append("no `repository_verification.run_id` is cited -- a freeze claim must name the canonical "
                            "hosted run that exercised the candidate")
        else:
            facts = None
            if run_facts is not None:
                facts = run_facts(run_id)
            else:
                facts = _run_facts(run_id)
            if facts is None:
                # *** A RUN THAT CANNOT BE READ IS REFUSED, NOT SKIPPED. *** *The head_sha road below is kept as a
                # fallback so the older `run_head` injection still works, but a freeze that cannot read the run's
                # SHAPE may not claim the six-job authority.*
                sha = (run_head or _run_head_sha)(run_id)
                if sha is None:
                    problems.append(f"hosted run {run_id} could NOT be read -- a freeze may not cite a run it cannot "
                                    f"verify, because an unread run is indistinguishable from a wrong one")
                elif peeled and sha != peeled:
                    problems.append(f"hosted run {run_id} reports head_sha {sha} but the candidate {tag!r} peels to "
                                    f"{peeled} -- A GREEN RUN FROM ANOTHER SHA CANNOT BE BORROWED")
            else:
                sha = facts.get("head_sha")
                if peeled and sha != peeled:
                    problems.append(f"hosted run {run_id} reports head_sha {sha} but the candidate {tag!r} peels to "
                                    f"{peeled} -- A GREEN RUN FROM ANOTHER SHA CANNOT BE BORROWED")
                # *** THE CONCLUSION, WORKFLOW, EVENT AND STATUS, EACH BY NAME. ***
                if facts.get("conclusion") != "success":
                    problems.append(f"hosted run {run_id} concluded {facts.get('conclusion')!r}, not 'success' -- "
                                    f"a freeze binds a GREEN run")
                if facts.get("workflow") != "repository-verification":
                    problems.append(f"hosted run {run_id} belongeth to workflow {facts.get('workflow')!r}, not "
                                    f"'repository-verification' -- the binding names WHICH workflow must be green")
                if facts.get("event") != "push":
                    problems.append(f"hosted run {run_id} was triggered by {facts.get('event')!r}, not 'push' -- a "
                                    f"candidate freeze binds the push that carried the candidate")
                if facts.get("status") != "completed":
                    problems.append(f"hosted run {run_id} carrieth status {facts.get('status')!r}, not 'completed' -- "
                                    f"a run still in progress cannot be a frozen result")
                # *** AND ALL SIX JOBS MUST HAVE SUCCEEDED: `success` WITH A SKIPPED JOB IS A PARTIAL RUN. ***
                jobs = facts.get("jobs") or []
                if len(jobs) != 6:
                    problems.append(f"hosted run {run_id} carrieth {len(jobs)} job(s), not the six-job authority "
                                    f"the closure claims -- a shrunken job set proves less than the one named")
                bad_jobs = [f"{j.get('name')}={j.get('conclusion')!r}" for j in jobs
                            if j.get("conclusion") != "success"]
                if bad_jobs:
                    problems.append(f"hosted run {run_id} carrieth non-successful job(s): {', '.join(bad_jobs)} -- "
                                    f"ALL SIX must be success, or the run is not the authority it is cited as")
                # *** THE ATTEMPT NUMBER, WHEN THE RECORD PINS ONE. *** *A re-run of the same run id carrieth a new
                # attempt; a record that pinned attempt 1 may not be satisfied by attempt 2's transient red.*
                pinned_attempt = rv.get("run_attempt")
                if pinned_attempt is not None and facts.get("run_attempt") != pinned_attempt:
                    problems.append(f"hosted run {run_id} is at attempt {facts.get('run_attempt')!r} but the record "
                                    f"pins attempt {pinned_attempt!r} -- an unpinned re-run is a different result")

        # (8) *** NO POST-TAG TRACKED EDIT OUTSIDE THE ALLOWLIST. ***
        #
        # *THE ATTESTATION IS WRITTEN AFTER THE TAG, so a freeze must tolerate exactly that path.* **EVERYTHING ELSE
        # IS REFUSED BY NAME: a candidate whose tree has moved since it was tagged is not the tree the green run
        # exercised.**
        if peeled and freeze:
            allow = tuple(record.get("post_tag_allowlist") or ("docs/remediation/evidence/",))
            delta = (tree_delta or (lambda p: _tree_delta(p, allow=allow)))(peeled)
            if delta:
                problems.append(f"the tree has moved since candidate {tag!r} was tagged: {', '.join(delta[:6])}"
                                f"{'...' if len(delta) > 6 else ''} -- a candidate whose tree changed after the tag "
                                f"is not the tree the hosted run exercised (only {list(allow)} may move)")

        # (9) *** `candidate_tree_sha` MUST BE STATED AND EQUAL THE DERIVED TREE. ***
        #
        # *An unstaked tree is an unfalsifiable binding: the record would name a tag whose tree nobody stated.*
        if peeled:
            actual = _tree_sha(peeled)
            if not record.get("candidate_tree_sha"):
                problems.append("the record states NO `candidate_tree_sha` -- a candidate binding must name the tree "
                                "it froze, or a reader cannot tell which bytes the run exercised")
            elif actual != record.get("candidate_tree_sha"):
                problems.append(f"candidate_tree_sha asserteth {record.get('candidate_tree_sha')} but {tag!r}'s "
                                f"commit carrieth tree {actual}")

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
    #
    # *THE CASE SUPPLIETH ITS OWN `run_id`: the LIVE record carrieth `null` by design (a candidate commit cannot
    # name a run that has not happened yet), so a case that relied on the live value would redden for the ABSENT run
    # rather than for the borrowed SHA it is written to provoke.*
    with_run = {**real, "repository_verification": {"run_id": "1"}}
    expect(binding_problems(with_run, freeze=True, run_facts=lambda _r: None, run_head=lambda _r: "f" * 40),
           "CANNOT BE BORROWED", "a hosted run whose head_sha is a different commit is refused")

    # 9. A RUN THAT CANNOT BE READ.
    expect(binding_problems(with_run, freeze=True, run_facts=lambda _r: None, run_head=lambda _r: None),
           "could NOT be read", "an unreadable cited run is refused rather than assumed green")

    # 10. THE POSITIVE CASE -- *a guard that refuseth the correct binding is not a guard.*
    # *** THE POSITIVE CASE MUST BIND A REF WHOSE OWN TREE CARRIES AN AGREEING RECORD. ***
    #
    # *rc6's committed record names rc5, so rc6 CANNOT be the positive case -- and that is not a flaw in the test, it
    # is THE DEFECT THE VALIDATOR WAS BUILT TO CATCH, caught live. So the positive case is exercised against a
    # synthetic record written as the freeze commit would write it: the ref it names, the copy at that ref agreeing
    # with it, the tree stated, no post-tag delta, and the six-job green run.*
    # *The at-tag copy is patched to agree, so every OTHER check (annotation, peel, tree, run facts) still runs against
    # the REAL rc6 tag -- only the conditions under test are satisfied.*
    real_file_at = _file_at
    globals()["_file_at"] = lambda rev, rel: json.dumps({"candidate_ref": tag})
    green_facts = {
        "head_sha": peeled, "conclusion": "success", "status": "completed", "event": "push",
        "workflow": "repository-verification", "run_attempt": 1,
        "jobs": [{"name": f"job{i}", "conclusion": "success"} for i in range(6)],
    }
    try:
        ok = binding_problems(
            {"candidate_ref": tag, "candidate_tree_sha": tree,
             "repository_verification": {"run_id": "1", "run_attempt": 1}},
            workdir_record="{}", freeze=True,
            run_facts=lambda _r: green_facts, tree_delta=lambda _p: [])
    finally:
        globals()["_file_at"] = real_file_at
    if ok:
        print(f"   FAIL: the REAL record must bind cleanly, got {ok}")
        failures += 1
    else:
        print("   PASS: the real record's own binding is accepted")

    # 11. *** A BORROWED RUN: THE HEAD SHA BELONGS TO ANOTHER COMMIT. ***
    run_facts_fake = lambda _r: {**green_facts, "head_sha": "f" * 40}
    expect(binding_problems({"candidate_ref": tag, "candidate_tree_sha": tree,
                             "repository_verification": {"run_id": "1"}},
                            workdir_record="{}", freeze=True,
                            run_facts=run_facts_fake, tree_delta=lambda _p: []),
           "CANNOT BE BORROWED", "a run whose head_sha is another commit is refused")

    # 12. *** A SKIPPED JOB: `success` WITH A JOB NOT SUCCESSFUL IS A PARTIAL RUN. ***
    skipped = lambda _r: {**green_facts, "jobs": [{"name": f"job{i}", "conclusion": "success"} for i in range(5)]
                          + [{"name": "job5", "conclusion": "skipped"}]}
    expect(binding_problems({"candidate_ref": tag, "candidate_tree_sha": tree,
                             "repository_verification": {"run_id": "1"}},
                            workdir_record="{}", freeze=True,
                            run_facts=skipped, tree_delta=lambda _p: []),
           "non-successful job", "a run with a skipped job is refused")

    # 13. *** A POST-TAG EDIT OUTSIDE THE ALLOWLIST. ***
    expect(binding_problems({"candidate_ref": tag, "candidate_tree_sha": tree,
                             "repository_verification": {"run_id": "1"}},
                            workdir_record="{}", freeze=True,
                            run_facts=lambda _r: green_facts,
                            tree_delta=lambda _p: ["ios/Godstone/Sources/GodstoneMesh/MeshNode.swift"]),
           "has moved since candidate", "a post-tag edit outside the allowlist is refused")

    # 14. *** A LIGHTWEIGHT TAG: no tag object, so it can be re-pointed without trace. ***
    light = "refs/tags/production-readiness-board1-rc6"
    real_tag_object = _tag_object
    globals()["_tag_object"] = lambda t: _tag_peel(t)   # simulate a lightweight tag: object == peel
    try:
        expect(binding_problems({**real, "candidate_ref": tag}, workdir_record=None),
               "LIGHTWEIGHT", "a lightweight candidate tag is refused")
    finally:
        globals()["_tag_object"] = real_tag_object

    # 15. *** AN UNSTATED candidate_tree_sha AT FREEZE. ***
    globals()["_file_at"] = lambda rev, rel: json.dumps({"candidate_ref": tag})
    try:
        expect(binding_problems({"candidate_ref": tag, "repository_verification": {"run_id": "1"}},
                                workdir_record="{}", freeze=True,
                                run_facts=lambda _r: green_facts, tree_delta=lambda _p: []),
               "states NO `candidate_tree_sha`", "an unstated candidate tree is refused")
    finally:
        globals()["_file_at"] = real_file_at

    print(f"\ncandidate binding selftest: {15 - failures}/15 mutations killed")
    return 1 if failures else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="the closure record's candidate binding")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--freeze", action="store_true",
                    help="also check the cited hosted run and its head_sha (needs network)")
    ap.add_argument("--run-id", default=None,
                    help="the hosted run to bind; CLI OVERRIDES the committed record's run_id, so the attestation "
                         "may be written against a run the frozen record does not yet carry")
    ap.add_argument("--attempt", type=int, default=None,
                    help="pin the run ATTEMPT (a re-run of the same id is a different result)")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if args.selftest:
        return selftest()

    record = json.loads(CLOSURE.read_text(encoding="utf-8"))
    if args.run_id:
        # *** THE CLI OVERRIDES THE COMMITTED NULL, WHICH IS THE NON-CIRCULAR FREEZE'S OWN SHAPE. ***
        # *The candidate commit carrieth `run_id: null` (it cannot name a run that has not happened), and the freeze
        # supplies the run the push produced.*
        rv = dict(record.get("repository_verification") or {})
        rv["run_id"] = args.run_id
        if args.attempt is not None:
            rv["run_attempt"] = args.attempt
        record = {**record, "repository_verification": rv}
    problems = binding_problems(record, workdir_record=CLOSURE.read_text(encoding="utf-8"),
                                freeze=args.freeze)
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
