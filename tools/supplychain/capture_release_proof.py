#!/usr/bin/env python3
"""Capture a release-proof record FROM the real hosted run's own facts.

    python3 tools/supplychain/capture_release_proof.py \
        --repo oculusrex14/GODSTONE --run-id 36864119928 --attempt 2 \
        --candidate-sha 0364eace... --out /tmp/board1-proof
    python3 tools/supplychain/capture_release_proof.py --selftest

WHY THIS EXISTS
---------------
A release proof is not authored, it is CAPTURED. This tool readeth the run's
OWN facts from the GitHub API -- its jobs, their conclusions, the boundary a
failed external job stopped at, and the digests of the artifacts it uploaded --
and SEALETH them into the schema-2 document `verify_release_proof.py` checketh.
Nothing here is hand-written JSON, so a proof cannot claim a job or an artifact
the run did not produce.

THE LAWS
--------
* The internal roster is FIXED. The two LIGHT jobs must be present, green, and
  must have INSPECTED their built artifact (the inspection step ran, not
  SKIPPED); the artifact digests are taken from the uploads, not from a guess.
* THE INTERNAL ROAD PRECEDETH THE EXTERNAL. The two internal jobs are judged
  FIRST and must be complete and green; only then may an external job be filed
  BLOCKED_EXTERNAL. A prerequisite that never succeeded has not reached any
  external boundary.
* A MARKER IS NOT PROOF. An internally executable failure (a real compile error,
  a CMake configure failure) disqualifies the boundary claim EVEN WHEN a
  well-formed marker is present -- otherwise a genuine internal red plus a forged
  marker would be filed as external. A bare task NAME is not a failure: a healthy
  run PRINTS `> Task :llm:compileReleaseKotlin`, so the tool requireth a FAILURE
  marker (a `FAILED` task line, a `BUILD FAILED`, a compiler error).
* The bound register is recorded, not asserted. A marker that carrieth no bound
  source id, or bindeth one without a digest_status, is refused: the reason must
  come from the register the helper read, not from a caller's prose.
* The record is SEPARATE from the repository: `--out` must be OUTSIDE the repo.
* Authenticity requireth a REFETCH: this tool readeth the live attempt, and the
  consumer MUST re-read the run for authenticity (the self-digest proveth only
  integrity).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))
import verify_release_proof as RP  # noqa: E402

#: The workflow whose five release-gates jobs this authority pin, and the repo
#: the pinned run must belong to (refused against live facts, never assumed).
WORKFLOW_PATH = ".github/workflows/release-gates.yml"
REQUIRED_WORKFLOW = "release-gates"
REQUIRED_REPOSITORY = "oculusrex14/GODSTONE"

#: The DISPLAY NAMES the workflow assigneth to the five release-gates jobs. A run
#: job's `name` is this display string; matching by display name AND by the job id
#: it carrieth (the workflow file names the same id) refuseth an invented job.
INTERNAL_JOB_SPECS: tuple[dict[str, Any], ...] = (
    {"job_id": "android-archive-only-release",
     "display_name": "Android Archive-only LIGHT release (repo-owned; green without "
                     "llama.cpp/model/Oracle)",
     "artifacts": ("android-archive-only-unsigned",)},
    {"job_id": "ios-archive-only-release",
     "display_name": "iOS Archive-only LIGHT unsigned artifact (internal; production "
                     "content and signing external)",
     "artifacts": ("ios-archive-only-unsigned",)},
)
EXTERNAL_JOB_SPECS: tuple[dict[str, Any], ...] = (
    {"job_id": "noise-conformance",
     "display_name": "A-06 independent Noise conformance (fail-closed until pinned)",
     "boundary": "noise_fixture",
     "boundaries": ("noise_fixture",),
     "step_names": ("verify independently approved Noise input",)},
    {"job_id": "llm-native-stack",
     "display_name": "LLM native stack (:llm release; fail-closed until pinned "
                     "llama.cpp restored)",
     "boundary": "native_models",
     "boundaries": ("native_models",),
     "step_names": ("verify approved native stack input",)},
    {"job_id": "production-corpus",
     "display_name": "production corpus + embedded archive (fail-closed until model "
                     "pinned)",
     "boundary": "model_weights",
     "boundaries": ("model_weights", "approved_content"),
     "step_names": ("verify independently approved model weights",
                    "verify independently approved content inputs")},
)

#: The EXTERNAL boundary step names the workflow's fail-closed jobs run -- the
#: union of `EXTERNAL_JOB_SPECS[*]["step_names"]`, so a boundary marker is
#: admissible ONLY from the log file a job's own NAMED boundary step captured.
EXTERNAL_STEP_NAMES: tuple[str, ...] = tuple(sorted(
    {name for spec in EXTERNAL_JOB_SPECS for name in spec["step_names"]}))

#: The structured marker an external job's log must carry to be filed
#: BLOCKED_EXTERNAL. The workflow's boundary helper emitteth exactly this line.
BOUNDARY_MARKER = re.compile(r"::godstone-boundary::(\{.*\})")

#: A step banner in a raw GitHub job log. MEASURED against real
#: `gh api repos/{repo}/actions/jobs/{id}/logs`: the runner rendereth the COMMAND,
#: never a human step name --
#:   <ts> ##[group]Run python tools/supplychain/emit_boundary.py --boundary X --check-inputs
#: then the shell/env metadata, then `##[endgroup]`, and the command's OWN output
#: followeth the endgroup until the next `Run …` header. The optional leading token
#: tolerateth both the raw timestamp and the `gh run view --log` per-line prefix
#: (`Job\tStep\tTimestamp\t`). The boundary is therefore found by its ACTUAL command.
RUN_HEADER = re.compile(r"^.*?##\[group\]Run\s+(.*)$", re.M)
RUN_ENDGROUP = re.compile(r"^.*?##\[endgroup\]\s*$", re.M)
#: The one command that emiteth a typed external boundary. A marker is admissible
#: ONLY from the output of THIS command (with the expected `--boundary <enum>`).
EMIT_BOUNDARY_SCRIPT = "tools/supplychain/emit_boundary.py"

#: Internal-prerequisite failure signatures that may NEVER be classified as an
#: external boundary -- an internally executable compile must be run and fixed, not
#: filed as "missing native input". These are FAILURE signatures ONLY: a HEALTHY
#: run PRINTS the task name (`> Task :llm:compileReleaseKotlin`), so a bare task
#: name is NOT a failure.
INTERNAL_FAILURE_SIGNATURES = (
    "CMake Error", "Execution failed for task", "unresolved reference:",
    "error: cannot find symbol", "e: file://",
)
#: Failure PATTERNS, matched as regexes so a passing task banner is never mistaken
#: for a failure (only a `FAILED` line, a `BUILD FAILED`, or a Kotlin FAILED task
#: counteth).
INTERNAL_FAILURE_PATTERNS = (
    re.compile(r"^> Task .*FAILED\s*$", re.M),
    re.compile(r"\bBUILD FAILED\b"),
    re.compile(r"\bcompile[A-Za-z]*Kotlin\b[^\n]*\bFAILED\b"),
)


class CaptureError(RuntimeError):
    """A refusal. Every refusal precedeth a record being written."""


def _run(argv: Sequence[str]) -> str:
    try:
        result = subprocess.run(list(argv), capture_output=True, text=True, check=False)
    except OSError as exc:
        raise CaptureError(f"could not run {argv[0]}: {exc}") from exc
    if result.returncode != 0:
        raise CaptureError(f"{' '.join(argv)} exited {result.returncode}: "
                           f"{result.stderr.strip()[:400]}")
    return result.stdout


def gh_api(path: str) -> Any:
    return json.loads(_run(["gh", "api", path]) or "null")


def fetch_run(repo: str, run_id: int) -> dict[str, Any]:
    return gh_api(f"repos/{repo}/actions/runs/{run_id}")


def fetch_jobs(repo: str, run_id: int, attempt: int) -> list[dict[str, Any]]:
    payload = gh_api(f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs"
                     f"?per_page=100")
    return list(payload.get("jobs") or [])


def fetch_artifacts(repo: str, run_id: int) -> list[dict[str, Any]]:
    return list(gh_api(f"repos/{repo}/actions/runs/{run_id}/artifacts"
                       f"?per_page=100").get("artifacts") or [])


def job_log_text(repo: str, job_id: int) -> str:
    """The job's raw log, or '' when the API will not serve it (a 302 to a blob)."""
    try:
        return _run(["gh", "api", f"repos/{repo}/actions/jobs/{job_id}/logs"])
    except CaptureError:
        return ""


def boundary_from_log(text: str) -> dict[str, Any] | None:
    """The LAST structured boundary marker a job's log carrieth, or None."""
    found = None
    for match in BOUNDARY_MARKER.finditer(text or ""):
        try:
            found = json.loads(match.group(1))
        except ValueError:
            continue
    return found


def _boundary_step_of(step: Mapping[str, Any]) -> bool:
    """True when a step IS the intended external boundary step (its own emit)."""
    return str(step.get("name") or "") in EXTERNAL_STEP_NAMES


def _run_sections(log_text: str) -> list[tuple[str, str]]:
    """The (command, body) pairs of a raw GH job log's `##[group]Run …` sections.

    MEASURED shape: the runner writeth `<ts> ##[group]Run <command>`, then the
    shell/env metadata, then `##[endgroup]`, and the command's OWN output followeth
    the endgroup until the next `Run …` header. The body is everything between this
    section's `##[endgroup]` and the next `Run …` header (or end of log)."""
    raw = log_text if log_text else ""
    headers = list(RUN_HEADER.finditer(raw))
    sections: list[tuple[str, str]] = []
    for index, header in enumerate(headers):
        next_header = headers[index + 1].start() if index + 1 < len(headers) else len(raw)
        end = RUN_ENDGROUP.search(raw, header.end(), next_header)
        start = end.end() if end else header.end()
        sections.append((header.group(1).strip(), raw[start:next_header]))
    return sections


def expected_emit_command(boundary: str) -> str:
    """The exact `emit_boundary` command the workflow runneth for a boundary."""
    return f"python {EMIT_BOUNDARY_SCRIPT} --boundary {boundary} --check-inputs"


def _normalise_command(command: str) -> str:
    return " ".join((command or "").split())


def boundary_sections(log_text: str, boundaries: Sequence[str]) -> list[tuple[str, str]]:
    """The `(boundary, body)` pairs of a job log's ACTUAL `emit_boundary` Run
    sections for the ALLOWED boundaries only. [] when the raw log carrieth none.

    *A marker is admissible ONLY from the output of the exact
    `Run python tools/supplychain/emit_boundary.py --boundary <enum> --check-inputs`
    command the workflow runneth* -- never from a human-named group (the raw log has
    none), never from another Run command, and never from an emit for a DIFFERENT
    boundary. Raises `CaptureError` on a duplicate boundary command."""
    raw = log_text if log_text else ""
    allow = {_normalise_command(expected_emit_command(b)): b for b in boundaries}
    pairs: list[tuple[str, str]] = []
    seen: set[str] = set()
    for command, body in _run_sections(raw):
        normalised = _normalise_command(command)
        if normalised not in allow:
            continue
        if normalised in seen:
            raise CaptureError(f"the raw log carrieth the boundary command "
                               f"{normalised!r} more than once: a required boundary "
                               f"step may not be duplicated")
        seen.add(normalised)
        pairs.append((allow[normalised], body))
    return pairs


def misdirected_marker_sections(log_text: str,
                                boundaries: Sequence[str]) -> list[str]:
    """emit_boundary Run commands carrying a marker but NOT for an allowed boundary.

    *This is how a marker echoed under a DIFFERENT (or unrelated) Run command is
    caught and named, rather than silently ignored.*"""
    raw = log_text if log_text else ""
    allowed = {_normalise_command(expected_emit_command(b)) for b in boundaries}
    offenders: list[str] = []
    for command, body in _run_sections(raw):
        normalised = _normalise_command(command)
        if normalised in allowed:
            continue
        if EMIT_BOUNDARY_SCRIPT in normalised and boundary_from_log(body) is not None:
            offenders.append(normalised)
    return offenders


def internal_failure_signatures(log_text: str, job: Mapping[str, Any] | None = None
                                ) -> list[str]:
    """Unmistakable INTERNAL failure evidence in a log -- never a bare task name.

    A healthy Gradle run PRINTS `> Task :llm:compileReleaseKotlin`, so the task
    name is not evidence of failure. Evidence is a FAILURE SIGNATURE (`CMake
    Error`, a compiler error) or a FAILURE PATTERN (a `> Task … FAILED` line, a
    `BUILD FAILED`, a Kotlin task marked FAILED); a step whose recorded conclusion
    is `failure` is ALSO evidence *unless it IS the named external boundary step,
    whose non-zero emit exit is the intended fail-closed boundary itself.*"""
    text = log_text or ""
    found = [signature for signature in INTERNAL_FAILURE_SIGNATURES if signature in text]
    for pattern in INTERNAL_FAILURE_PATTERNS:
        if pattern.search(text):
            found.append(f"pattern:{pattern.pattern}")
    if isinstance(job, Mapping):
        for step in job.get("steps") or []:
            if not isinstance(step, Mapping) or step.get("conclusion") != "failure":
                continue
            if _boundary_step_of(step):
                continue  # the intended external emit failing is the boundary, not a red
            found.append(f"failed step: {step.get('name')}")
    return found


def classify_external(job: Mapping[str, Any], expected: Mapping[str, str],
                      log_text: str, *, internal_ok: bool = True) -> dict[str, Any]:
    """File an external job: reached the boundary, or refused as misclassified.

    A marker alone is NOT proof of an external boundary. An internally executable
    failure (a real compile error, a CMake configure) disqualifies the boundary
    claim EVEN WHEN a marker is present -- otherwise a genuine internal compile
    failure plus a forged marker would be filed as external. And nothing may be
    filed BLOCKED_EXTERNAL while the internal road is not green: a prerequisite
    that never succeeded has not earned the right to blame an external input.

    *THE ACTUAL-COMMAND ADMISSION: the marker is read from the output of the job's
    REAL `Run python tools/supplychain/emit_boundary.py --boundary <enum>
    --check-inputs` section -- the raw log carrieth the command, never a human step
    name -- and only for the boundary(ies) THIS job is allowed to reach, cross-checked
    against the API's named failed step / command. A marker from another Run
    command, or an emit for a different boundary, is refused. The boundary step's
    non-zero emit exit is the INTENDED failure, so it is not counted as
    internal-failure evidence -- but EVERY other failed step (and any compiler
    signature) still refuseth, so a forged marker cannot launder an internal red.*"""
    conclusion = str(job.get("conclusion") or "")
    allowed = tuple(expected.get("boundaries") or (expected.get("boundary"),))
    sections = boundary_sections(log_text, allowed)
    misdirected = misdirected_marker_sections(log_text, allowed)
    if misdirected:
        raise CaptureError(f"external job {expected['job_id']!r} carrieth a "
                           f"::godstone-boundary:: marker under a Run command that is "
                           f"not the allowed boundary emit {list(allowed)}: "
                           f"{misdirected} -- a marker is admissible ONLY from the "
                           f"actual emit_boundary command for THIS job's boundary")
    if len(sections) > 1:
        raise CaptureError(f"external job {expected['job_id']!r} carrieth "
                           f"{len(sections)} boundary emit sections "
                           f"{[b for b, _ in sections]}: a job's boundary may be named "
                           f"only once")
    marker = boundary_from_log(sections[0][1]) if sections else None
    if conclusion == "success":
        return {"id": expected["job_id"],
                "boundary_step": sections[0][0] if sections else allowed[0],
                "boundary_result": "success",
                "actual_ids": marker.get("ids") if marker else None,
                "refusal_reason": ""}
    signatures = internal_failure_signatures(log_text, job)
    if signatures:
        raise CaptureError(f"external job {expected['job_id']!r} carrieth internal "
                           f"failure evidence {signatures}: an internally executable "
                           f"prerequisite failed, so its red may not be filed as the "
                           f"external boundary {allowed[0]!r} (a marker does not make "
                           f"an internal failure external)")
    if not internal_ok:
        raise CaptureError(f"external job {expected['job_id']!r} may not be filed "
                           f"BLOCKED_EXTERNAL while the internal road is not green: a "
                           f"prerequisite that never succeeded has not reached any "
                           f"external boundary")
    if not sections:
        raise CaptureError(f"external job {expected['job_id']!r} failed "
                           f"({conclusion}) with NO `Run {EMIT_BOUNDARY_SCRIPT} "
                           f"--boundary …` section: its failure cannot be shown to be "
                           f"the external boundary rather than an internal prerequisite "
                           f"or an unrelated command")
    boundary, body = sections[0]
    if marker is None:
        raise CaptureError(f"external job {expected['job_id']!r} failed "
                           f"({conclusion}) but its boundary emit command for "
                           f"{boundary!r} carrieth NO ::godstone-boundary:: marker: the "
                           f"boundary was not shown to be reached")
    if marker.get("boundary") != boundary:
        raise CaptureError(f"external job {expected['job_id']!r} ran the emit for "
                           f"{boundary!r} but its marker declared "
                           f"{marker.get('boundary')!r}")
    ids = marker.get("ids")
    if not isinstance(ids, Mapping) or not ids:
        raise CaptureError(f"external job {expected['job_id']!r} marker carrieth no "
                           f"bound ids: the register it read must be named, not a bare "
                           f"caller reason")
    for source_id, fact in ids.items():
        if not isinstance(fact, Mapping) or not fact.get("digest_status"):
            raise CaptureError(f"external job {expected['job_id']!r} marker bindeth "
                              f"{source_id!r} with no digest_status: an absent/unpinned/"
                              f"measured state must be recorded, not asserted")
    return {"id": expected["job_id"], "boundary_step": boundary,
            "boundary_result": "blocked", "actual_ids": dict(ids),
            "refusal_reason": str(marker.get("reason") or "boundary reached")}


def inspection_step_verdict(job: Mapping[str, Any]) -> str:
    """The internal verdict of a job's inspection step, from its step list."""
    for step in job.get("steps") or []:
        name = str(step.get("name") or "")
        if "inspect" in name.lower():
            conclusion = str(step.get("conclusion") or "")
            if conclusion == "success":
                return "PASS"
            if conclusion == "skipped":
                return "SKIPPED"
            return "FAIL"
    return "UNVERIFIED"


def _job_for(spec: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]],
             seen: dict[int, str]) -> Mapping[str, Any]:
    """The ONE run job a required spec mapeth to, refusing a duplicate population.

    *THE DEFECT THIS CLOSES: the old mapping used `setdefault`, so a run carrying
    the required job TWICE (or an extra job whose display name matched) silently
    hid the real one -- a duplicate required job is refused, not overwritten.*
    """
    matches = [j for j in jobs if str(j.get("name") or "") == spec["display_name"]
               or spec["job_id"] in str(j.get("name") or "")]
    if not matches:
        raise CaptureError(f"the run carrieth no job {spec['job_id']!r} "
                           f"({spec['display_name']!r})")
    if len(matches) > 1:
        raise CaptureError(f"the run carrieth {len(matches)} jobs matching the required "
                           f"job {spec['job_id']!r}: a required job population may not "
                           f"be duplicated or invented")
    job = matches[0]
    jid = int(job.get("id") or 0)
    if jid in seen:
        raise CaptureError(f"the run maps two required jobs ({seen[jid]!r} and "
                           f"{spec['job_id']!r}) to the same job id {jid}")
    seen[jid] = spec["job_id"]
    return job


def _artifact_row(name: str, meta: Mapping[str, Any]) -> dict[str, Any]:
    """The uploaded artifact's identity and digest, from the API's own shape."""
    digest = str(meta.get("digest") or meta.get("sha256") or "")
    return {"name": name, "path": name, "sha256": digest.removeprefix("sha256:"),
            "bytes": int(meta.get("size_in_bytes", meta.get("bytes", 0)) or 0)}


def map_facts_to_document(*, candidate_sha: str, tree_sha: str,
                          run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]],
                          artifacts: Mapping[str, Mapping[str, Any]],
                          logs: Mapping[str, str]) -> dict[str, Any]:
    """The pure transformation: real facts -> a schema-2 record. No network.

    The REQUIRED five-job population is matched by the workflow's own display
    names, all five judged exactly once, and the required uploaded artifact
    identities/digests taken from the facts -- never invented, never hidden by a
    dictionary overwrite. `capture()` pins the workflow/repo/tree against the live
    remote before ever calling this."""
    seen: dict[int, str] = {}
    internal_jobs: list[dict[str, Any]] = []
    internal_artifacts: list[dict[str, Any]] = []
    # PASS 1 -- the INTERNAL road is judged FIRST, and must be complete and green
    # before any external red may be blamed on an external input.
    for spec in INTERNAL_JOB_SPECS:
        job = _job_for(spec, jobs, seen)
        verdict = inspection_step_verdict(job)
        internal_jobs.append({
            "job_id": spec["job_id"], "id": int(job["id"]),
            "name": str(job.get("name") or ""),
            "conclusion": str(job.get("conclusion") or ""),
            "steps": [{"name": "artifact-inspection", "conclusion":
                       "success" if verdict == "PASS" else str(job.get("conclusion")),
                       "internal_verdict": verdict,
                       "source": "job-log"}]})
        for artifact in spec["artifacts"]:
            meta = artifacts.get(artifact)
            if meta is None:
                raise CaptureError(f"the run uploaded no artifact {artifact!r} for the "
                                   f"required job {spec['job_id']!r}")
            internal_artifacts.append(_artifact_row(artifact, meta))
    internal_green = (all(j["conclusion"] == "success" for j in internal_jobs)
                      and all(j["steps"][0]["internal_verdict"] == "PASS"
                              for j in internal_jobs))
    internal_refusals: list[str] = []
    if internal_green:
        internal_verdict = "PASS"
    else:
        internal_verdict = "FAIL"
        for j in internal_jobs:
            if j["conclusion"] != "success":
                internal_refusals.append(f"internal job {j['job_id']!r} concluded "
                                         f"{j['conclusion']!r}")
            elif j["steps"][0]["internal_verdict"] != "PASS":
                internal_refusals.append(f"internal job {j['job_id']!r} did not inspect "
                                         f"its artifact")
        if not internal_refusals:
            internal_refusals.append("an internal job did not conclude success")
    # PASS 2 -- only now may an external job be filed, and only against its own
    # bound register (never a caller-asserted reason).
    external_roster: list[dict[str, Any]] = []
    for spec in EXTERNAL_JOB_SPECS:
        job = _job_for(spec, jobs, seen)
        external_roster.append(classify_external(
            job, spec, logs.get(str(job["id"]), ""), internal_ok=internal_green))
    external_verdict = ("BLOCKED_EXTERNAL"
                        if any(e["boundary_result"] != "success"
                               for e in external_roster)
                        else "PASS")
    return RP.seal({
        "schema": 2,
        "candidate": {"sha": candidate_sha, "tree_sha": tree_sha},
        # *The recorded run attempt IS the requested pinned attempt:* `capture()`
        # refuseth a run whose own attempt is not the one requested, so this file
        # can never claim a different attempt than the facts it read.
        "run": {"id": int(run["id"]), "attempt": int(run.get("run_attempt") or 0),
                "workflow": str(run.get("name") or ""),
                "event": str(run.get("event") or ""),
                "ref": str(run.get("head_branch") or ""),
                "head_sha": str(run.get("head_sha") or "")},
        "internal": {"verdict": internal_verdict, "jobs": internal_jobs,
                     "artifacts": internal_artifacts,
                     "refusals": internal_refusals if internal_verdict != "PASS" else []},
        "external": {"verdict": external_verdict, "roster": external_roster},
    })


def _marker(boundary: str, source_id: str, status: str) -> str:
    return "::godstone-boundary::" + json.dumps(
        {"boundary": boundary, "reason": f"{source_id} {status}",
         "ids": {source_id: {"path": source_id, "digest": None,
                             "digest_status": status}}}, sort_keys=True)


def marker_log(boundary: str, source_id: str, status: str, *,
               ts: str = "2026-10-02T00:00:00.0000000Z") -> str:
    """A raw GH job log section carrying the ACTUAL boundary emit command and its
    marker output -- the shape MEASURED from `gh api .../jobs/{id}/logs`.

    The runner rendereth `<ts> ##[group]Run <command>`, the shell/env metadata, then
    `<ts> ##[endgroup]`, then the command's OWN output (the marker here). This is
    what a consumer/test must build for a genuine blocked-external job; a human-named
    `##[group]<step name>` is NOT the real shape and is refused."""
    return run_command_section(expected_emit_command(boundary),
                               _marker(boundary, source_id, status), ts=ts)


def run_command_section(command: str, output: str, *,
                        ts: str = "2026-10-02T00:00:00.0000000Z") -> str:
    """A raw GH job log `Run …` section: header + shell metadata + endgroup + output."""
    prefixed = "\n".join(f"{ts} {line}" for line in (output or "").splitlines())
    return (f"{ts} ##[group]Run {command}\n"
            f"{ts} shell: /usr/bin/bash -e {{0}}\n"
            f"{ts} ##[endgroup]\n"
            f"{prefixed}\n")


def fetch_commit(repo: str, sha: str) -> dict[str, Any]:
    return gh_api(f"repos/{repo}/commits/{sha}")


def actual_remote_tree(repo: str, candidate_sha: str, tree_sha: str | None = None) -> str:
    """The ACTUAL remote commit's tree, from GitHub -- never a caller's assertion.

    The candidate tree is a binding, so it is read from the remote commit, not
    trusted from a parameter; a supplied `tree_sha` that is not the remote tree is
    refused."""
    commit = fetch_commit(repo, candidate_sha)
    actual = str(((commit.get("commit") or {}).get("tree") or {}).get("sha") or "")
    if not actual:
        raise CaptureError(f"the remote commit {candidate_sha!r} carrieth no tree: the "
                           f"actual remote tree cannot be read")
    if tree_sha is not None and str(tree_sha).lower() != actual.lower():
        raise CaptureError(f"the supplied tree {tree_sha!r} is not the remote commit "
                           f"{candidate_sha!r}'s ACTUAL tree {actual!r}")
    return actual


def _required_uploaded_artifacts(uploaded: Sequence[Mapping[str, Any]]) -> dict[str, dict]:
    """The REQUIRED uploaded artifact rows, by name, refusing a duplicate/absent one."""
    names = {a for spec in INTERNAL_JOB_SPECS for a in spec["artifacts"]}
    by_name: dict[str, dict] = {}
    for meta in uploaded:
        name = str(meta.get("name") or "")
        if name in names:
            if name in by_name:
                raise CaptureError(f"the run uploaded the required artifact {name!r} "
                                   f"more than once: a required artifact population may "
                                   f"not be duplicated")
            by_name[name] = dict(meta)
    for name in names:
        if name not in by_name:
            raise CaptureError(f"the run uploaded no required artifact {name!r}: the "
                               f"pinned attempt's artifact population is incomplete")
    return by_name


def _pinned_logs(repo: str, jobs: Sequence[Mapping[str, Any]]) -> dict[str, str]:
    """The logs of the five required jobs, keyed by job id -- no other job's log."""
    specs = INTERNAL_JOB_SPECS + EXTERNAL_JOB_SPECS
    wanted = []
    for job in jobs:
        name = str(job.get("name") or "")
        if any(spec["display_name"] == name or spec["job_id"] in name for spec in specs):
            wanted.append(job)
    return {str(j["id"]): job_log_text(repo, int(j["id"])) for j in wanted}


def capture(repo: str, run_id: int, attempt: int, candidate_sha: str,
            tree_sha: str | None = None) -> dict[str, Any]:
    """*** CAPTURE THE PINNED ATTEMPT'S ACTUAL RELEASE FACTS INTO A SEALED DOCUMENT. ***

    *THE ONE COLLECTION POINT: the CLI and any authenticating consumer call THIS.
    It pin fetch the live run, requirith the exact requested attempt and candidate
    head, readeth the five required jobs and the REQUIRED uploaded artifact
    identities/digests and the typed external boundary logs from the run's OWN
    facts, and readeth the candidate's ACTUAL remote commit tree -- then sealt them
    into the schema-2 document `verify_release_proof.verify_release_proof` checketh.
    Nothing here is hand-written JSON, so a proof cannot claim a job, an artifact or
    a tree the run did not produce.* It raiseth `CaptureError` on every refusal; it
    writeth nothing.
    """
    run = fetch_run(repo, run_id)
    # *THE EXACT PINNED RUN: the repository, workflow, requested attempt and the
    # candidate head are all required to match the run's OWN facts.*
    if str(run.get("id") or "") != str(run_id):
        raise CaptureError(f"the run id read back from GitHub is {run.get('id')}, not "
                           f"the pinned {run_id}")
    actual_repo = str(((run.get("repository") or {}).get("full_name"))
                      or run.get("head_repository", {}).get("full_name") or "")
    if actual_repo and actual_repo.lower() != repo.lower():
        raise CaptureError(f"the run belongeth to repository {actual_repo!r}, not the "
                           f"pinned {repo!r}")
    workflow = str(((run.get("workflow_file") or {}) if isinstance(
        run.get("workflow_file"), Mapping) else {}).get("name")
        or run.get("path") or run.get("workflow_path") or "")
    if workflow and REQUIRED_WORKFLOW not in workflow and WORKFLOW_PATH not in workflow:
        raise CaptureError(f"the run's workflow {workflow!r} is not the release-gates "
                           f"workflow {WORKFLOW_PATH!r}")
    if int(run.get("run_attempt") or 0) != int(attempt):
        raise CaptureError(f"run attempt {run.get('run_attempt')} is not the requested "
                           f"{attempt}")
    if str(run.get("head_sha") or "") != candidate_sha:
        raise CaptureError(f"run head sha {run.get('head_sha')} is not the candidate "
                           f"{candidate_sha}")
    if str(run.get("conclusion") or "") not in ("success", "failure", ""):
        raise CaptureError(f"the pinned run's conclusion {run.get('conclusion')!r} is "
                           f"neither a green nor a truthful red -- the run is not the "
                           f"pinned release attempt")
    jobs = fetch_jobs(repo, run_id, attempt)
    uploaded = _required_uploaded_artifacts(fetch_artifacts(repo, run_id))
    artifacts = {name: _artifact_row(name, meta) for name, meta in uploaded.items()}
    logs = _pinned_logs(repo, jobs)
    remote_tree = actual_remote_tree(repo, candidate_sha, tree_sha)
    document = map_facts_to_document(candidate_sha=candidate_sha, tree_sha=remote_tree,
                                     run=run, jobs=jobs, artifacts=artifacts, logs=logs)
    problems = RP.verify_release_proof(document)
    if problems:
        raise CaptureError("the captured document refuseth its own verifier: "
                           + "; ".join(problems))
    return document


def _selftest() -> int:
    failures: list[str] = []

    def check(name: str, ok: bool) -> None:
        if not ok:
            failures.append(name)

    run = {"id": 36864119928, "run_attempt": 2, "name": "release-gates",
           "event": "push", "head_branch": "board1/x", "head_sha": "c" * 40}
    jobs = [
        {"id": 1, "name": "android-archive-only-release", "conclusion": "success",
         "steps": [{"name": "inspect release artifacts", "conclusion": "success"}]},
        {"id": 2, "name": "ios-archive-only-release", "conclusion": "success",
         "steps": [{"name": "inspect the actual unsigned iOS artifact",
                    "conclusion": "success"}]},
        {"id": 3, "name": "noise-conformance", "conclusion": "failure",
         "steps": [{"name": "repository-owned parity prerequisites",
                    "conclusion": "success"},
                   {"name": "verify independently approved Noise input",
                    "conclusion": "failure"}]},
        {"id": 4, "name": "llm-native-stack", "conclusion": "failure",
         "steps": [{"name": "compile repository-owned LLM Kotlin",
                    "conclusion": "success"},
                   {"name": "verify approved native stack input",
                    "conclusion": "failure"}]},
        {"id": 5, "name": "production-corpus", "conclusion": "failure",
         "steps": [{"name": "verify independently approved model weights",
                    "conclusion": "failure"},
                   {"name": "verify independently approved content inputs",
                    "conclusion": "skipped"}]},
    ]
    arts = {"android-archive-only-unsigned": {"name": "android-archive-only-unsigned",
                                              "path": "a/", "sha256": "a" * 64,
                                              "bytes": 10},
            "ios-archive-only-unsigned": {"name": "ios-archive-only-unsigned",
                                          "path": "i/", "sha256": "b" * 64,
                                          "bytes": 20}}

    logs = {
        "3": marker_log("noise_fixture", "crypto/cacophony_vectors.json", "ABSENT"),
        "4": run_command_section("python -m pip install -r content/requirements.txt",
                                 "ok")
             + marker_log("native_models", "docs/packaging/MODELS.lock.json",
                          "UNPINNED"),
        "5": marker_log("model_weights", "docs/packaging/MODELS.lock.json", "UNPINNED"),
    }
    doc = map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                                jobs=jobs, artifacts=arts, logs=logs)
    check("a captured record was refused by the verifier",
          RP.verify_release_proof(doc) == [])
    check("the internal verdict is PASS", doc["internal"]["verdict"] == "PASS")
    check("the external verdict is BLOCKED_EXTERNAL",
          doc["external"]["verdict"] == "BLOCKED_EXTERNAL")
    check("the genuine boundary failure is represented with its actual boundary",
          [(e["id"], e["boundary_step"]) for e in doc["external"]["roster"]]
          == [("noise-conformance", "noise_fixture"),
              ("llm-native-stack", "native_models"),
              ("production-corpus", "model_weights")])
    # (i) an external failure with NO boundary emit command at all is refused
    try:
        map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                              jobs=jobs, artifacts=arts,
                              logs={k: "" for k in logs})
        check("a boundary-less external failure was tolerated", False)
    except CaptureError:
        pass
    # (ii) A HEALTHY compile that merely PRINTS the task name does NOT disqualify a
    # genuine external boundary: the :llm job then stopped at the missing native
    # input, emitting the boundary from its OWN actual emit_boundary command.
    healthy = dict(logs, **{"4": run_command_section(
        "cd android && ./gradlew --no-daemon :llm:compileReleaseKotlin",
        "> Task :llm:compileReleaseKotlin\n> Task :llm:compileDebugKotlin")
        + marker_log("native_models", "docs/packaging/MODELS.lock.json", "UNPINNED")})
    try:
        blocked = map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40,
                                        run=run, jobs=jobs, artifacts=arts, logs=healthy)
        check("a healthy compile + genuine native boundary was wrongly refused",
              blocked["external"]["verdict"] == "BLOCKED_EXTERNAL")
    except CaptureError:
        check("a healthy compile + genuine native boundary was wrongly refused", False)
    # (iii) A TRUE failed compile carrying a valid marker in the boundary emit is
    # still refused: the other failed step IS internal-failure evidence.
    failed_compile_jobs = [dict(j) for j in jobs]
    failed_compile_jobs[3] = dict(failed_compile_jobs[3], steps=[
        {"name": "compile repository-owned LLM Kotlin", "conclusion": "failure"},
        {"name": "verify approved native stack input", "conclusion": "failure"}])
    forged = dict(logs, **{"4": run_command_section(
        "cd android && ./gradlew --no-daemon :llm:compileReleaseKotlin",
        "> Task :llm:compileReleaseKotlin FAILED\n"
        "e: file:///x/Y.kt:1:1 unresolved reference: foo")
        + marker_log("native_models", "docs/packaging/MODELS.lock.json", "UNPINNED")})
    try:
        map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                              jobs=failed_compile_jobs, artifacts=arts, logs=forged)
        check("a failed compile with a forged marker was filed external", False)
    except CaptureError as exc:
        check("the forged-marker refusal did not name the internal failure",
              "internally executable" in str(exc))
    # (iv) an UNRELATED failed step beside the valid boundary emit is refused.
    unrelated_jobs = [dict(j) for j in jobs]
    unrelated_jobs[2] = dict(unrelated_jobs[2], steps=[
        {"name": "repository-owned parity prerequisites", "conclusion": "failure"},
        {"name": "verify independently approved Noise input", "conclusion": "failure"}])
    try:
        map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                              jobs=unrelated_jobs, artifacts=arts, logs=logs)
        check("an unrelated failed step was tolerated", False)
    except CaptureError as exc:
        check("the unrelated-step refusal did not name the failed step",
              "failed step" in str(exc))
    # (v) a marker under an UNRELATED Run command is not the boundary's emit: refused
    misplaced = dict(logs, **{"3": run_command_section(
        "python ci/check_parity.py --scope all",
        _marker("noise_fixture", "crypto/cacophony_vectors.json", "ABSENT"))})
    try:
        map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                              jobs=jobs, artifacts=arts, logs=misplaced)
        check("a marker under an unrelated Run command was tolerated", False)
    except CaptureError:
        pass
    # (v-bis) an emit for a DIFFERENT boundary than the job may reach is refused
    wrong_boundary = dict(logs, **{"3": marker_log(
        "approved_content", "env:GODSTONE_APPROVALS_DIR", "ABSENT")})
    try:
        map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                              jobs=jobs, artifacts=arts, logs=wrong_boundary)
        check("an emit for a different boundary was tolerated", False)
    except CaptureError as exc:
        check("the wrong-boundary refusal did not name the misdirected emit",
              "not the allowed boundary emit" in str(exc))
    # (vi) ORDERING: nothing may be filed BLOCKED_EXTERNAL while an internal job is red
    internal_red = [dict(j) for j in jobs]
    internal_red[1] = dict(internal_red[1], conclusion="failure")
    try:
        map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                              jobs=internal_red, artifacts=arts, logs=logs)
        check("an external block was allowed while the internal road was red", False)
    except CaptureError as exc:
        check("the ordering refusal did not name the internal road",
              "internal road is not green" in str(exc))
    # (vii) a marker that bindeth no register is a caller assertion, not a measurement
    unbound = dict(logs, **{"3": run_command_section(
        expected_emit_command("noise_fixture"),
        '::godstone-boundary::{"boundary":"noise_fixture","reason":"because I say so"}')})
    try:
        map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                              jobs=jobs, artifacts=arts, logs=unbound)
        check("a self-echoed reason with no bound register was tolerated", False)
    except CaptureError:
        pass
    # (viii) a missing internal job is refused
    try:
        map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                              jobs=[j for j in jobs if j["id"] != 1], artifacts=arts,
                              logs=logs)
        check("a missing internal job was tolerated", False)
    except CaptureError:
        pass
    # (ix) a REQUIRED job population duplicated is refused, not silently overwritten
    try:
        map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                              jobs=jobs + [dict(jobs[0], id=999)], artifacts=arts,
                              logs=logs)
        check("a duplicated required internal job was tolerated", False)
    except CaptureError as exc:
        check("the duplicate refusal did not name the duplicated population",
              "duplicated or invented" in str(exc))
    for line in failures:
        print(f"::error::{line}")
    if failures:
        print(f"selftest FAILED ({len(failures)})")
        return 1
    print("selftest OK: captured a sound record with genuine ACTUAL-command boundary "
          "failures; accepted a healthy compile + genuine native boundary; refused a "
          "boundary-less external failure, a failed compile with a forged marker, an "
          "unrelated failed step, a marker under an unrelated Run command, a "
          "wrong-boundary emit, an external block while the internal road was red, a "
          "self-echoed reason, a missing internal job and a duplicated required job")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Capture a release-proof record from a real hosted run")
    parser.add_argument("--repo", help="owner/name")
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--attempt", type=int)
    parser.add_argument("--candidate-sha")
    parser.add_argument("--tree-sha", help="optional; fetched from the commit if absent")
    parser.add_argument("--out", type=Path,
                        help="an output DIRECTORY OUTSIDE the repository")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    if args.selftest:
        return _selftest()
    if not all((args.repo, args.run_id, args.attempt, args.candidate_sha, args.out)):
        parser.error("--repo --run-id --attempt --candidate-sha --out are required")
    repo_root = HERE.parent.parent
    out = args.out.resolve()
    if out == repo_root or repo_root in out.parents:
        print(f"::error::--out must be OUTSIDE the repository ({repo_root}); a proof is "
              f"never committed after the candidate", file=sys.stderr)
        return 1
    try:
        document = capture(args.repo, args.run_id, args.attempt, args.candidate_sha,
                           args.tree_sha)
    except CaptureError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    out.mkdir(parents=True, exist_ok=True)
    target = out / f"{args.run_id}-{args.attempt}.json"
    target.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n",
                      encoding="utf-8")
    print(f"captured {target} (internal {document['internal']['verdict']}, external "
          f"{document['external']['verdict']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
