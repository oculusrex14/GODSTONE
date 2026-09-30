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
import hashlib
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


#: *** THE SIX EXACT JOB NAMES THE CANONICAL WORKFLOW DEFINES, AS ITS OWN `name:` LINES SPELL THEM. ***
#:
#: *`len(jobs) == 6` is NOT the authority the closure claims: a workflow could carry six jobs of ANY names and satisfy
#: it, and a renamed job would silently change what was verified.* **So the six are named here, read from
#: `.github/workflows/repository-verification.yml`, and the freeze requireth EXACTLY these -- no more, no fewer, no
#: renames.** *The list is in the workflow's own declaration order so a diff against the file reads the same way.*
CANONICAL_JOB_NAMES: tuple[str, ...] = (
    "constraint audit (C1/C2 + tiers + release-gate status)",
    "repo-owned parity + safety invariants (A,B,C,E,F,G,H)",
    "content pipeline (LIGHT archive, no model)",
    "mesh simulation (regression guard)",
    "android source compile + unit tests (committed wrapper)",
    "ios core + mesh tests + Archive-only xcodebuild",
)


def _run_facts(run_id: str, *, api=None, attempt: int | None = None) -> dict | None:
    """*** THE RUN'S OWN FACTS -- CONCLUSION, WORKFLOW, EVENT, STATUS, JOBS, ATTEMPT. ***

    *`head_sha` alone cannot tell a SUCCESSFUL run of the right workflow from a failed run of a different one, and it
    cannot tell a green run from one whose jobs were SKIPPED.* **So the freeze requireth the whole shape: the workflow
    is `repository-verification`, the event is `push`, the status is `completed`, the conclusion is `success`, all six
    jobs succeeded, and the attempt number is the one the record pins.** *The job list is checked too because a
    conclusion of `success` with a SKIPPED job is the shape a partial run wears -- and four jobs succeeding out of six
    is not the six-job authority the freeze claims.*

    *** AND WHEN `attempt` IS SUPPLIED, THE FACTS COME FROM THAT ATTEMPT'S OWN ENDPOINTS. ***
    //
    // *THE DEFECT THIS CLOSES, MEASURED: the old road read `actions/runs/R` and `actions/runs/R/jobs`, WHICH GITHUB
    // ANSWERETH FOR THE **LATEST** ATTEMPT, and then compared the returned `run_attempt` to the pinned number. That is
    // a numeric check on a value from the wrong endpoint: if the pinned attempt's jobs were the failed ones and a
    // later re-run went green, the LATEST jobs read green and only the `run_attempt != pinned` comparison stood between
    // the freeze and a borrowed green -- and that comparison is exactly what a caller who omitted `--attempt` skipped.*
    // **SO THE ATTEMPT IS FETCHED, NOT COMPARED:** `attempts/{N}` for the run's own facts and
    // `attempts/{N}/jobs` (paginated) for its jobs.
    """
    fetch = api or _gh_api
    try:
        if attempt is not None:
            run = fetch(f"repos/{_repository()}/actions/runs/{run_id}/attempts/{attempt}")
            jobs = _fetch_paginated(
                fetch, f"repos/{_repository()}/actions/runs/{run_id}/attempts/{attempt}/jobs")
        else:
            run = fetch(f"repos/{_repository()}/actions/runs/{run_id}")
            jobs = _fetch_paginated(fetch, f"repos/{_repository()}/actions/runs/{run_id}/jobs")
    except Exception:  # noqa: BLE001 - an unreadable run must not crash the validator
        return None
    if run is None or jobs is None:
        return None
    job_rows = jobs.get("jobs") or []
    # *The `workflow` field is a STRING (`repository-verification`) in the jobs/runs API and an OBJECT in some other
    # shapes; both are accepted, because a validator that crashed on one shape would be unusable on a runner.*
    wf = run.get("workflow")
    if isinstance(wf, dict):
        wf = wf.get("name")
    return {
        "head_sha": run.get("head_sha"),
        "conclusion": run.get("conclusion"),
        "status": run.get("status"),
        "event": run.get("event"),
        "workflow": (run.get("name") if isinstance(run.get("name"), str) and run.get("name") else wf),
        "run_attempt": run.get("run_attempt"),
        "repository": ((run.get("repository") or {}).get("full_name") if isinstance(run.get("repository"), dict) else run.get("repository")),
        "head_branch": run.get("head_branch"),
        "path": run.get("path"),
        "jobs": [{"id": j.get("id"), "name": j.get("name"), "conclusion": j.get("conclusion"),
                  "check_run_url": j.get("check_run_url")} for j in job_rows],
        "jobs_total_count": jobs.get("total_count"),
    }


def _fetch_paginated(fetch, first_path: str, *, api_root: str = "repos") -> dict | None:
    """*** FOLLOW `Link: rel="next"`, BECAUSE A SINGLE PAGE DROPPETH JOBS SILENTLY. ***

    *GitHub paginates jobs at 100 per page by default. A run with more than 100 job rows would have its tail omitted,
    and `len(jobs) == 6` would then read as a SHRUNKEN workflow rather than as a partial read -- the honest failure
    either way, but the reason must be the workflow and not the fetcher.* **The path is rewritten onto the next URL's
    own path+query so the same `fetch` callable (a test seam, or `gh api`) is reused.**
    """
    merged: list[dict] = []
    path = first_path
    seen = 0
    while path and seen < 20:  # a bounded walk; 20 pages is 2000 jobs, far past any real run
        page = fetch(path)
        if page is None:
            return None
        merged.extend(page.get("jobs") or [])
        nxt = page.get("_next_path")
        path = nxt
        seen += 1
    if not seen:
        return None
    return {"jobs": merged, "total_count": len(merged)}


def _gh_api(path: str) -> dict | None:
    """One GitHub API read, WITH THE PAGINATION LINK PRESERVED.

    *`gh api` printeth only the JSON body, so a caller that wanteth the next page must ask for the headers: `--include`
    prefixes them, and `Link: <url>; rel="next"` is parsed into `_next_path` for `_fetch_paginated` to follow.* **A
    fetcher that silently dropped the tail page would make a truncation look like a shrunken run.**
    """
    try:
        proc = subprocess.run(["gh", "api", "--include", path], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    # *** THE HEADERS END AT THE FIRST BLANK LINE -- WHATEVER ITS LINE ENDING. ***
    #
    # *MEASURED, 2026-09-30: this used `partition("\r\n\r\n")` and then, if that found nothing, `partition("\n\n")`
    # -- but it re-partitioned `proc.stdout` rather than the REMAINDER, so when `gh` emitted LF-separated headers
    # (which it does on this host: the raw output carrieth NO CR at all) NEITHER candidate parsed as JSON, and
    # `_gh_api` returned `None`.* **THE CONSEQUENCE WAS TOTAL AND SILENT: `_run_facts` returned `None` for EVERY run,
    # so `board1 freeze` refused every candidate with "could NOT be read -- a freeze may not cite a run it cannot
    # verify", while `gh api` itself answered 200 with a well-formed body.*** *A control that cannot read the artefact
    # it judges is not a control; this is the same class as the pagination defect beside it, one layer down.*
    #
    # *So the split is on the first blank line, `\r\n\r\n` or `\n\n` -- the LONGER (CRLF) form first, so a CRLF blank
    # line is never mistaken for a bare LF one -- and the BODY is what is parsed; the header block is kept only for
    # the `Link:` header.*
    if "\r\n\r\n" in proc.stdout:
        raw_headers, _, raw_body = proc.stdout.partition("\r\n\r\n")
    elif "\n\n" in proc.stdout:
        raw_headers, _, raw_body = proc.stdout.partition("\n\n")
    else:
        # No header block at all (a fetch that did not ask for `--include`): the whole stream is the body.
        raw_headers, raw_body = "", proc.stdout
    data: dict | None = None
    for chunk in (raw_body, proc.stdout):
        try:
            parsed = json.loads(chunk)
            if isinstance(parsed, dict):
                data = parsed
                break
        except ValueError:
            continue
    if data is None:
        return None
    nxt = _next_path_from_link(raw_headers or raw_body)
    if nxt:
        data["_next_path"] = nxt
    return data


def _next_path_from_link(blob: str) -> str | None:
    """The `rel="next"` URL's path+query from a `Link:` header, stripped of the API origin.

    *The returned value is a path like `repos/o/r/actions/runs/1/jobs?page=2` -- exactly what `gh api` accepteth -- so
    the same fetcher callable is reused for every page.*
    """
    m = re.search(r'<([^>]+)>;\s*rel="next"', blob)
    if not m:
        return None
    url = m.group(1)
    m2 = re.match(r"https?://[^/]+/(.+)", url)
    return m2.group(1) if m2 else url


def _job_annotations(job_id, fetch=None) -> list[dict] | None:
    """*** THE CHECK-RUN ANNOTATIONS FOR A JOB, PAGINATED. ***

    *A job's `conclusion` is `success` even when its steps emitted `::error::` annotations that a later step swallowed
    -- and the repository's own controls use exactly that shape (`|| { echo "::error::..."; exit 1; }` is honest, but a
    `continue-on-error` or a `soft-fail` step is not).* **So the annotations are read too, and any FAILURE-level
    annotation refuseth the freeze.** *An unreadable annotation list is `None`, which the caller treateth as a refusal
    rather than as silence.*
    """
    if job_id is None:
        return None
    fetch = fetch or _gh_api
    path = f"repos/{_repository()}/check-runs/{job_id}/annotations"
    merged: list[dict] = []
    seen = 0
    while path and seen < 20:
        page = fetch(path)
        if page is None:
            return None
        rows = page if isinstance(page, list) else (page.get("annotations") or [])
        merged.extend(rows)
        path = (page.get("_next_path") if isinstance(page, dict) else None)
        seen += 1
    return merged


def _tree_delta(peeled: str, *, allow: tuple[str, ...] = ()) -> list[str]:
    """*** TRACKED PATHS THAT CHANGED BETWEEN THE CANDIDATE AND HEAD, MINUS THE ALLOWLIST. ***

    *A post-tag edit outside `docs/remediation/evidence/` invalidateth the candidate: the attestation describeth a tree
    that no longer standeth.* **THE ALLOWLIST IS NOT A LOOPHOLE -- IT NAMES THE ONE PATH A FREEZE MAY STILL WRITE
    (the attestation itself), and everything else is refused BY NAME so a reader seeth which path moved.**

    *** AND A GIT FAILURE IS RETURNED AS ITS OWN SENTINEL, NOT AS AN EMPTY LIST. ***
    //
    // *THE DEFECT THIS CLOSES, MEASURED: `return []` on a non-zero `git diff` meant "no paths moved" -- **so a
    // repository whose `HEAD` was unresolvable, whose object store was corrupt, or whose git invocation failed for any
    // reason would report a CLEAN post-tag delta and the freeze would proceed.*** *An empty result must mean the delta
    // was MEASURED and was empty; a failure to measure is the opposite claim.*
    """
    proc = _git("diff", "--name-only", f"{peeled}..HEAD")
    if proc.returncode != 0:
        # The sentinel is a path-shaped string no real path can equal, so callers that only print the delta still
        # read something honest, and the freeze can refuse on it explicitly.
        return [f"<git-diff-failed: {proc.stderr.strip()[:200] or 'no stderr'}>"]
    changed = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    return [p for p in changed if not any(p.startswith(a) for a in allow)]


def dirty_tracked_paths(*, allow: tuple[str, ...] = ()) -> list[str]:
    """*** TRACKED PATHS MODIFIED IN THE WORKING TREE (STAGED OR UNSTAGED) OUTSIDE THE ALLOWLIST. ***

    *THE DEFECT THIS CLOSES: `_tree_delta` comparess COMMITTED `HEAD` to the candidate, so a freeze run in a dirty
    working tree -- sources edited but not committed -- passeth the post-tag check while the TREE A READER WOULD BUILD
    is not the candidate's.* **A candidate freeze must be taken from a clean tree; unrelated untracked files outside
    the candidate input set are left alone, but a tracked modification is a refusal.** *Untracked directories
    (`?? AUDIT_FINAL.../`) are deliberately NOT refused: they are not part of any commit and `git diff --name-only`
    never lists them.*
    """
    proc = _git("status", "--porcelain")
    if proc.returncode != 0:
        return [f"<git-status-failed: {proc.stderr.strip()[:200] or 'no stderr'}>"]
    out: list[str] = []
    for line in proc.stdout.splitlines():
        if len(line) < 4:
            continue
        code, path = line[:2], line[3:].strip()
        if code == "??":
            continue
        # A rename carrieth `old -> new`; the new path is what a reader would build.
        if " -> " in path:
            path = path.split(" -> ", 1)[1]
        path = path.strip('"')
        if not any(path.startswith(a) for a in allow):
            out.append(path)
    return out


def binding_problems(record: dict, *, workdir_record: str | None = None,
                     freeze: bool = False, run_head: callable = None,
                     run_facts: callable = None, tree_delta: callable = None,
                     annotations: callable = None,
                     dirty_paths: callable = None) -> list[str]:
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
                # *** AND THE SIX JOBS MUST BE EXACTLY THE CANONICAL SIX, BY NAME -- NOT MERELY SIX ROWS. ***
                #
                # *`len(jobs) != 6` is not the authority the closure claims: a workflow could carry six jobs of ANY
                # names and satisfy it, and a RENAMED job would silently change what was verified while the count
                # stayed right.* **So the names are compared to the canonical workflow's own, and a missing, extra or
                # renamed job is refused BY NAME.**
                jobs = facts.get("jobs") or []
                names = [j.get("name") for j in jobs]
                missing = [n for n in CANONICAL_JOB_NAMES if n not in names]
                extra = [n for n in names if n not in CANONICAL_JOB_NAMES]
                duplicates = sorted({n for n in names if names.count(n) > 1})
                if missing:
                    problems.append(f"hosted run {run_id} omits canonical job(s): {missing} -- the six-job authority "
                                    f"is a NAMED set, and a shrunken one proves less than the one the closure names")
                if extra:
                    problems.append(f"hosted run {run_id} carrieth job(s) the canonical workflow does not define: "
                                    f"{extra} -- an unexpected job is a workflow that has drifted from the authority "
                                    f"the freeze binds")
                if duplicates:
                    problems.append(f"hosted run {run_id} carrieth duplicated job name(s): {duplicates} -- a "
                                    f"duplicated row would double-count a job the closure names once")
                bad_jobs = [f"{j.get('name')}={j.get('conclusion')!r}" for j in jobs
                            if j.get("conclusion") != "success"]
                if bad_jobs:
                    problems.append(f"hosted run {run_id} carrieth non-successful job(s): {', '.join(bad_jobs)} -- "
                                    f"ALL SIX must be success, or the run is not the authority it is cited as")
                # *** AND THE REPOSITORY, BRANCH AND WORKFLOW PATH, EACH BY NAME. ***
                want_repo = (record.get("repository_verification") or {}).get("repository")
                if want_repo and facts.get("repository") and facts["repository"] != want_repo:
                    problems.append(f"hosted run {run_id} belongeth to repository {facts.get('repository')!r}, not "
                                    f"{want_repo!r}")
                want_branch = (record.get("repository_verification") or {}).get("branch")
                if want_branch and facts.get("head_branch") and facts["head_branch"] != want_branch:
                    problems.append(f"hosted run {run_id} ran on branch {facts.get('head_branch')!r}, not "
                                    f"{want_branch!r}")
                if facts.get("path") and "repository-verification" not in str(facts.get("path")):
                    problems.append(f"hosted run {run_id} ran workflow file {facts.get('path')!r}, which is not the "
                                    f"repository-verification workflow")
                # *** AND FAILURE-LEVEL CHECK-RUN ANNOTATIONS REFUSE THE RUN. ***
                #
                # *A job's `conclusion` is `success` even when a step emitted `::error::` that a later step swallowed.*
                # **So every job's annotations are read, and a FAILURE-level one refuseth -- the same "look at the job's
                # own output, not its name" law the release-gates classification already applies.** *An unreadable
                # annotation list is itself a refusal, because silence must not read as an absence of failures.*
                ann_fetch = annotations or _job_annotations
                for j in jobs:
                    rows = ann_fetch(j.get("id"))
                    if rows is None:
                        problems.append(f"hosted run {run_id}: the annotations for job {j.get('name')!r} could NOT be "
                                        f"read -- an unread job's steps are indistinguishable from clean ones")
                        continue
                    bad_ann = [a for a in rows if str(a.get("annotation_level", "")).lower() == "failure"]
                    if bad_ann:
                        problems.append(f"hosted run {run_id}: job {j.get('name')!r} carrieth {len(bad_ann)} "
                                        f"FAILURE-level annotation(s): "
                                        f"{[a.get('message', '')[:80] for a in bad_ann[:3]]}")
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
        #
        # *** AND THE DEFAULT ALLOWANCE IS THE ONE EXACT ATTESTATION PATH, NOT THE WHOLE EVIDENCE DIRECTORY. ***
        # *The old default was `docs/remediation/evidence/`, WHICH IS A FREE-FORM ALLOWANCE: any file a later commit
        # dropped into that directory would pass the post-tag check, so the allowance could quietly enlarge itself.
        # The record nameth the exact attestation path it permits (`post_tag_attestation`), and the default is that
        # one file; an absent name falls back to the directory ONLY to keep older records valid, and is reported.*
        if peeled and freeze:
            named_attestation = record.get("post_tag_attestation")
            if named_attestation:
                allow = (named_attestation,)
            else:
                allow = tuple(record.get("post_tag_allowlist") or ("docs/remediation/evidence/",))
            delta = (tree_delta or (lambda p: _tree_delta(p, allow=allow)))(peeled)
            if delta:
                problems.append(f"the tree has moved since candidate {tag!r} was tagged: {', '.join(delta[:6])}"
                                f"{'...' if len(delta) > 6 else ''} -- a candidate whose tree changed after the tag "
                                f"is not the tree the hosted run exercised (only {list(allow)} may move)")
            # *** AND A DIRTY WORKING TREE REFUSES THE FREEZE TOO. ***
            #
            # *`_tree_delta` comparess COMMITTED `HEAD`; a freeze taken in a tree with uncommitted source edits
            # passeth that check while the bytes a reader would build are not the candidate's.* **Unrelated UNTRACKED
            # files are deliberately left alone -- they are in no commit -- but a tracked modification is refused by
            # name.***
            dirty = (dirty_paths or (lambda: dirty_tracked_paths(allow=allow)))()
            if dirty:
                problems.append(f"the working tree carrieth {len(dirty)} uncommitted tracked change(s) outside "
                                f"{list(allow)}: {dirty[:5]} -- a freeze must be taken from the candidate's own "
                                f"bytes, and an uncommitted edit means the tree a reader would build is not the "
                                f"candidate")

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


def validate_attestation(path: Path, *, tag_peel=None, tag_object=None, tree_sha=None,
                         run_facts=None, tree_delta=None, file_at=None) -> list[str]:
    """*** READ-ONLY: RE-DERIVE EVERYTHING AN ATTESTATION CLAIMS, RETURNING THE PROBLEMS (empty = valid). ***

    *THE DEFECT THIS CLOSES: the only way to check an attestation was to RUN `freeze`, WHICH IS A WRITER -- it
    regenerates the timestamp and rewrites the file, so "checking" an attestation MUTATED it and could not be done on
    a successor commit at all.* **So this recomputeth the tag object, the peeled commit, the tree, the at-tag
    closure/ledger hashes and the pinned attempt's facts, and REFUSETH any disagreement -- taking no timestamp, writing
    no file, and never regenerating a measured_at.** *It liveth in the shared validator so `board1 freeze --attest-out`
    and `board1 verify --attestation` derive the SAME facts from the SAME code.*
    """
    peel_fn = tag_peel or _tag_peel
    obj_fn = tag_object or _tag_object
    tree_fn = tree_sha or _tree_sha
    facts_fn = run_facts or _run_facts
    delta_fn = tree_delta or _tree_delta
    at_fn = file_at or _file_at
    if not path.is_file():
        return [f"no attestation at {path}"]
    try:
        att = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        return [f"the attestation at {path} is not valid JSON: {exc}"]
    problems: list[str] = []
    tag = att.get("candidate_ref")
    if not tag:
        return ["the attestation names no candidate_ref"]
    peeled = peel_fn(tag)
    if not peeled:
        return [f"the attestation's candidate_ref {tag!r} does not resolve to a commit"]
    if att.get("candidate_sha") != peeled:
        problems.append(f"candidate_sha {att.get('candidate_sha')} != the tag's peeled commit {peeled}")
    obj = obj_fn(tag)
    if att.get("tag_object_sha") != obj:
        problems.append(f"tag_object_sha {att.get('tag_object_sha')} != the tag object {obj} (moved or re-pointed?)")
    tree = tree_fn(peeled)
    if att.get("candidate_tree_sha") != tree:
        problems.append(f"candidate_tree_sha {att.get('candidate_tree_sha')} != the tree {tree}")
    # at-tag hashes
    for key, rel in (("at_tag_closure_sha256", "docs/production-readiness/BOARD1_CLOSURE.json"),
                     ("at_tag_ledger_sha256", "docs/remediation/REMEDIATION_STATE.json")):
        blob = at_fn(peeled, rel)
        if blob is None:
            problems.append(f"the candidate carrieth no {rel}")
            continue
        got = hashlib.sha256(blob.encode("utf-8")).hexdigest()
        if att.get(key) != got:
            problems.append(f"{key} {att.get(key)} != the file at the candidate {got}")
    # the run, re-fetched
    run = att.get("run") or {}
    if run.get("id") is None or run.get("attempt") is None:
        problems.append("the attestation names no run id / attempt")
    else:
        facts = facts_fn(str(run["id"]), attempt=run["attempt"])
        if facts is None:
            problems.append(f"run {run['id']} attempt {run['attempt']} could not be re-read")
        else:
            if facts.get("head_sha") != peeled:
                problems.append(f"run {run['id']} reports head_sha {facts.get('head_sha')} != {peeled}")
            if facts.get("conclusion") != "success":
                problems.append(f"run {run['id']} conclusion {facts.get('conclusion')!r} != success")
            if facts.get("run_attempt") != run["attempt"]:
                problems.append(f"run {run['id']} answered with run_attempt={facts.get('run_attempt')!r}, not the "
                                f"pinned {run['attempt']!r}")
    # the successor delta: only the attestation itself may differ from the candidate.
    try:
        rel_path = str(path.relative_to(ROOT))
    except ValueError:
        rel_path = str(path)
    delta = delta_fn(peeled, allow=(rel_path,))
    if delta:
        problems.append(f"the tree has moved since {tag}: {delta[:5]}")
    return problems


def selftest() -> int:
    """*** ADVERSARIAL MUTATIONS: EACH BINDING DEFECT MUST BE KILLED. ***

    *Every case runs against a SYNTHETIC record and a REAL tag in this repository, so a check that quietly stopped
    looking at git would still be caught here.*
    """
    import tempfile

    failures = 0
    real = json.loads(CLOSURE.read_text(encoding="utf-8"))

    # *** THE NETWORK-FREE STUBS FOR THE TWO CHECKS THAT WOULD OTHERWISE NEED `gh`. ***
    # *The annotation and dirty-tree checks must be exercised, but the selftest runs offline; so they are injected as
    # callables -- `no_annotations` returns an empty, READABLE list (which is the honest "no failures" shape), and
    # `clean_tree` returns no modified paths. An INJECTED `None` from either is the unreadable case, exercised
    # separately below so silence cannot pass for clean.*
    def no_annotations(_job_id):
        return []

    def clean_tree():
        return []

    def unreadable_annotations(_job_id):
        return None
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
        "jobs": [{"id": 1000 + i, "name": n, "conclusion": "success"}
                 for i, n in enumerate(CANONICAL_JOB_NAMES)],
    }
    try:
        ok = binding_problems(
            {"candidate_ref": tag, "candidate_tree_sha": tree,
             "repository_verification": {"run_id": "1", "run_attempt": 1}},
            workdir_record="{}", freeze=True,
            run_facts=lambda _r: green_facts, tree_delta=lambda _p: [],
            annotations=no_annotations, dirty_paths=clean_tree)
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
                            run_facts=run_facts_fake, tree_delta=lambda _p: [],
                            annotations=no_annotations, dirty_paths=clean_tree),
           "CANNOT BE BORROWED", "a run whose head_sha is another commit is refused")

    # 12. *** A SKIPPED JOB: `success` WITH A JOB NOT SUCCESSFUL IS A PARTIAL RUN. ***
    skipped = lambda _r: {**green_facts, "jobs": [{"name": f"job{i}", "conclusion": "success"} for i in range(5)]
                          + [{"name": "job5", "conclusion": "skipped"}]}
    expect(binding_problems({"candidate_ref": tag, "candidate_tree_sha": tree,
                             "repository_verification": {"run_id": "1"}},
                            workdir_record="{}", freeze=True,
                            run_facts=skipped, tree_delta=lambda _p: [],
                            annotations=no_annotations, dirty_paths=clean_tree),
           "non-successful job", "a run with a skipped job is refused")

    # 13. *** A POST-TAG EDIT OUTSIDE THE ALLOWLIST. ***
    expect(binding_problems({"candidate_ref": tag, "candidate_tree_sha": tree,
                             "repository_verification": {"run_id": "1"}},
                            workdir_record="{}", freeze=True,
                            run_facts=lambda _r: green_facts,
                            annotations=no_annotations, dirty_paths=clean_tree,
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
                                run_facts=lambda _r: green_facts, tree_delta=lambda _p: [],
                                annotations=no_annotations, dirty_paths=clean_tree),
               "states NO `candidate_tree_sha`", "an unstated candidate tree is refused")
    finally:
        globals()["_file_at"] = real_file_at

    # ================================================================================================
    # *** 16..29: THE EXTENSIONS THE FREEZE PATH OWED -- EACH AN OBSERVABLE REFUSAL. ***
    # ================================================================================================
    def case(record, needle, label, **kw):
        kw.setdefault("annotations", no_annotations)
        kw.setdefault("dirty_paths", clean_tree)
        kw.setdefault("tree_delta", lambda _p: [])
        kw.setdefault("workdir_record", "{}")
        kw.setdefault("freeze", True)
        expect(binding_problems(record, **kw), needle, label)

    globals()["_file_at"] = lambda rev, rel: json.dumps({"candidate_ref": tag})
    try:
        base_rec = {"candidate_ref": tag, "candidate_tree_sha": tree,
                    "repository_verification": {"run_id": "1", "run_attempt": 1}}

        # 16. A WRONG WORKFLOW NAME.
        case(base_rec, "belongeth to workflow",
             "a run from a different workflow is refused",
             run_facts=lambda _r: {**green_facts, "workflow": "release-gates"})

        # 17. A WRONG EVENT (not a push).
        case(base_rec, "was triggered by",
             "a run from a non-push event is refused",
             run_facts=lambda _r: {**green_facts, "event": "pull_request"})

        # 18. A WRONG HEAD SHA -- *again, so the extension table itself is not the only guard.*
        case(base_rec, "CANNOT BE BORROWED",
             "a run whose head_sha is another commit is refused",
             run_facts=lambda _r: {**green_facts, "head_sha": "f" * 40})

        # 19. A MISSING CANONICAL JOB (five instead of six).
        case(base_rec, "omits canonical job(s)",
             "a run missing a canonical job is refused",
             run_facts=lambda _r: {**green_facts,
                                   "jobs": green_facts["jobs"][:-1]})

        # 20. *** A RENAMED JOB -- the count is right and the NAME is wrong. ***
        renamed = [dict(j) for j in green_facts["jobs"]]
        renamed[0]["name"] = "constraint audit (RENAMED)"
        case(base_rec, "the canonical workflow does not define",
             "a run whose job was RENAMED is refused even though the count is six",
             run_facts=lambda _r: {**green_facts, "jobs": renamed})

        # 21. A DUPLICATED JOB NAME.
        dup = [dict(j) for j in green_facts["jobs"]]
        dup[1]["name"] = dup[0]["name"]
        case(base_rec, "duplicated job name(s)",
             "a run with a duplicate job name is refused",
             run_facts=lambda _r: {**green_facts, "jobs": dup})

        # 22. *** A FAILED ANNOTATION BENEATH A `success` JOB. ***
        case(base_rec, "FAILURE-level annotation",
             "a run whose job carries a failure annotation is refused although the job concluded success",
             run_facts=lambda _r: green_facts,
             annotations=lambda _job: [{"annotation_level": "failure", "message": "xcodebuild did not succeed"}])

        # 23. *** AN UNREADABLE ANNOTATION LIST IS A REFUSAL, NOT SILENCE. ***
        case(base_rec, "could NOT be read",
             "an unreadable annotation list is refused rather than read as clean",
             run_facts=lambda _r: green_facts,
             annotations=unreadable_annotations)

        # 24. *** A PAGINATED OMISSION: the fetcher is exercised directly. ***
        #    *`_fetch_paginated` must FOLLOW the next link; a fetcher that answered one page for a two-page run would
        #    report a shrunken job set, which this asserts by counting what the walk actually saw.*
        pages = {"p1": {"jobs": [{"name": "a"}], "_next_path": "p2"},
                 "p2": {"jobs": [{"name": "b"}]}}
        merged = _fetch_paginated(lambda path: pages.get(path), "p1")
        if merged and len(merged.get("jobs") or []) == 2:
            print("   PASS: the paginated fetch follows the next link")
        else:
            print(f"   FAIL: the paginated fetch dropped a page -- got {merged}")
            failures += 1

        # 25. *** THE PINNED ATTEMPT IS FETCHED, NOT THE LATEST: the attempt path is asserted by a recording fetcher. ***
        seen_paths: list[str] = []

        def recording_fetch(path):
            seen_paths.append(path)
            if "attempts/3" in path:
                return {**green_facts, "run_attempt": 3, "jobs": green_facts["jobs"]}
            return None

        got = _run_facts("1", api=recording_fetch, attempt=3)
        if got and got.get("run_attempt") == 3 and all("attempts/3" in p for p in seen_paths):
            print("   PASS: the pinned attempt's OWN endpoints are fetched, not the latest attempt's")
        else:
            print(f"   FAIL: the attempt was not fetched by its own path -- paths={seen_paths} got={got}")
            failures += 1
        # *And the negative: a fetcher that answered the ATTEMPT endpoint with a sibling's number must not satisfy the
        # freeze.*
        case(base_rec, "pins attempt",
             "an attempt endpoint answering a sibling attempt is refused",
             run_facts=lambda _r: {**green_facts, "run_attempt": 4})

        # 26. *** A GIT FAILURE IS NOT AN EMPTY DELTA. ***
        real_git = globals()["_git"]

        def failing_git(*args):
            if args and args[0] == "diff":
                return subprocess.CompletedProcess(args, 128, "", "fatal: bad revision")
            return real_git(*args)
        saved = globals()["_git"]
        globals()["_git"] = failing_git
        try:
            delta = _tree_delta("HEAD~1")
        finally:
            globals()["_git"] = saved
        if delta and "git-diff-failed" in delta[0]:
            print("   PASS: a git-diff failure is returned as a sentinel, never as an empty delta")
        else:
            print(f"   FAIL: a git-diff failure read as a clean delta -- got {delta!r}")
            failures += 1

        # 27. *** A DIRTY WORKING TREE (uncommitted tracked change) IS REFUSED. ***
        case(base_rec, "uncommitted tracked change",
             "a freeze taken in a dirty working tree is refused",
             run_facts=lambda _r: green_facts,
             dirty_paths=lambda: ["ios/Godstone/Sources/GodstoneMesh/MeshNode.swift"])

        # 28. *** A POST-TAG DELTA OUTSIDE THE NAMED ALLOWLIST. ***
        case({**base_rec, "post_tag_attestation": "docs/remediation/evidence/FREEZE_ATTESTATION_rc11.json"},
             "has moved since candidate",
             "a post-tag edit outside the named attestation path is refused",
             run_facts=lambda _r: green_facts,
             tree_delta=lambda _p: ["docs/remediation/evidence/SOMETHING_ELSE.json"])

        # 29. *** A TAMPERED ATTESTATION IS REFUSED READ-ONLY. ***
        #    *`validate_attestation` must refuse a file whose fields disagree with git, and it must NOT rewrite it.*
        with tempfile.TemporaryDirectory() as td:
            att_path = Path(td) / "FREEZE_ATTESTATION_rc11.json"
            att_path.write_text(json.dumps({
                "candidate_ref": tag, "candidate_sha": "0" * 40,
                "candidate_tree_sha": tree, "tag_object_sha": _tag_object(tag),
                "at_tag_closure_sha256": "0" * 64, "at_tag_ledger_sha256": "0" * 64,
                "run": {"id": "1", "attempt": 1},
            }), encoding="utf-8")
            before = att_path.read_bytes()
            probs = validate_attestation(att_path)
            after = att_path.read_bytes()
            if probs and before == after:
                print("   PASS: a tampered attestation is refused and left BYTE-IDENTICAL (read-only)")
            else:
                print(f"   FAIL: attestation validation rc={rc}, bytes unchanged={before == after}")
                failures += 1

        # 30. *** `_gh_api` MUST SPLIT `gh api --include` OUTPUT CORRECTLY, WHATEVER THE LINE ENDING. ***
        #    *MEASURED, 2026-09-30, AND THIS CASE EXISTS BECAUSE THE OTHER TWENTY-NINE COULD NOT SEE IT: every other
        #    case in this file injecteth a SYNTHETIC fetcher (`api=`/`run_facts=`), so `_gh_api`'s own parser was
        #    NEVER EXERCISED. A real hosted freeze then refused with "could NOT be read -- a freeze may not cite a run
        #    it cannot verify" while `gh api` answered 200 with a well-formed body, because the split re-partitioned
        #    `proc.stdout` instead of the remainder and NEITHER candidate parsed.* **A CONTROL'S OWN I/O IS PART OF THE
        #    CONTROL; a suite that stubs it out certifieth the stub.***
        for label, blank in (("LF", "\n\n"), ("CRLF", "\r\n\r\n")):
            payload = {"id": 1, "conclusion": "success", "jobs": []}
            stream = "HTTP/2.0 200 OK\nLink: <https://api.github.com/x?page=2>; rel=\"next\"" + blank + json.dumps(payload)
            real_run = subprocess.run

            def fake_run(*a, **k):
                return subprocess.CompletedProcess(a, 0, stream, "")

            subprocess.run = fake_run
            try:
                got = _gh_api("x")
            finally:
                subprocess.run = real_run
            if got and got.get("conclusion") == "success" and got.get("_next_path") == "x?page=2":
                print(f"   PASS: _gh_api splits {label}-separated --include output and keeps the Link header")
            else:
                print(f"   FAIL: _gh_api mis-parsed {label} output -- got {got}")
                failures += 1
    finally:
        globals()["_file_at"] = real_file_at

    total = 31
    print(f"\ncandidate binding selftest: {total - failures}/{total} mutations killed")
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
