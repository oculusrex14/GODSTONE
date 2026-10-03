#!/usr/bin/env python3
"""Verify a release-proof record: how one hosted run proved the candidate.

    python3 tools/supplychain/verify_release_proof.py --path RECORD.json [--json]
    python3 tools/supplychain/verify_release_proof.py --selftest

WHY THIS EXISTS
---------------
A hosted green is not one fact, it is two POPULATIONS that must never be
conflated:

  * the INTERNAL road -- the exact candidate compiled, its controls held, both
    LIGHT artifacts were built and inspected. This can be proven today, on the
    candidate's own commit, BEFORE any tag exists.
  * the EXTERNAL road -- install on a device, at-rest bytes, signing, approved
    content and models. This CANNOT be proven in CI; its honest state is a
    structured BLOCKED_EXTERNAL naming the boundary that was actually reached
    and refused.

Conflating them produceth the two false-greens this module forbids: demanding an
external tag/release identity for an internal pass (which cannot exist before the
new tag), and dressing an internal failure as an external blocker.

THE LAWS
--------
* The candidate is an EXACT sha and tree sha. No tag is required prior to
  tagging, and a PASS carrieth no external identity requirement.
* The internal roster is CANONICAL: the required jobs, controls and artifacts
  must be present exactly once, all green, with NO skipped internal control and a
  non-empty artifact population. A missing, renamed or duplicated job, a skipped
  inspection, or an empty artifact list under PASS is refused.
* The run's own facts (run id, attempt, workflow, head sha) are recorded; the
  run's head sha must BE the candidate sha, so a borrowed other sha is refused.
  These facts are authenticated against GitHub by the CONSUMER -- this module
  checketh structure and consistency, never authenticity by digest alone.
* The external roster is separate. A PASS entry must have reached its boundary
  (actual ids present); a BLOCKED_EXTERNAL entry must name a boundary that is
  GENUINELY external and carry its refusal. An internal prerequisite failure
  wearing an external name (a compile error "misclassified external") is refused.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import re
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

SCHEMA = 2
INTERNAL_VERDICTS = ("PASS", "FAIL", "UNVERIFIED")
STEP_VERDICTS = ("PASS", "FAIL", "SKIPPED")
EXTERNAL_VERDICTS = ("PASS", "BLOCKED_EXTERNAL", "UNVERIFIED")
SHA1_RE = re.compile(r"[0-9a-f]{40}")
SHA256_RE = re.compile(r"[0-9a-f]{64}")

#: The canonical internal job roster: the release-gates jobs whose green is the
#: candidate's INTERNAL acceptance (the two that build and inspect the unsigned
#: LIGHT shipping artifacts). Keyed by the workflow job id (`jobs.<id>`), which is
#: stable; the display name is recorded beside it.
REQUIRED_INTERNAL_JOB_IDS: tuple[str, ...] = (
    "android-archive-only-release",
    "ios-archive-only-release",
)
#: The internal artifacts a PASS must name (the upload names of the two LIGHT
#: artifact evidences: the APK/AAB and the .app, each with its inspection report).
REQUIRED_INTERNAL_ARTIFACTS: tuple[str, ...] = (
    "android-archive-only-unsigned",
    "ios-archive-only-unsigned",
)
#: The EXTERNAL boundaries the release-gates workflow's fail-closed jobs actually
#: emit. A BLOCKED_EXTERNAL roster must represent EVERY external JOB (below),
#: exactly once, at a boundary that job actually reacheth: `production-corpus`
#: runneth `verify independently approved model weights` BEFORE
#: `verify independently approved content inputs`, so its honest first blocked
#: boundary is `model_weights` while the weights stand UNPINNED, and `approved_content`
#: once the weights are pinned. Naming an unreachable boundary is refused.
REQUIRED_EXTERNAL_BOUNDARIES: tuple[str, ...] = (
    "noise_fixture", "native_models", "model_weights", "approved_content",
)
#: The external JOBS and the boundary(ies) each is allowed to name -- the workflow's
#: own `emit_boundary` boundaries, never an invented alias. A roster representeth
#: each job EXACTLY ONCE; a missing, duplicated or un-allowed job/boundary is an
#: unreported external road.
EXTERNAL_JOB_BOUNDARIES: dict[str, tuple[str, ...]] = {
    "noise-conformance": ("noise_fixture",),
    "llm-native-stack": ("native_models",),
    "production-corpus": ("model_weights", "approved_content"),
}
REQUIRED_EXTERNAL_JOB_IDS: tuple[str, ...] = tuple(EXTERNAL_JOB_BOUNDARIES)
#: A boundary is EXTERNAL only if it is one of these. Anything else wearing an
#: external label is an internal failure misclassified.
EXTERNAL_BOUNDARIES: tuple[str, ...] = (
    "noise_fixture", "device_install", "device_launch", "at_rest_bytes", "signing",
    "approved_content", "native_models", "model_weights", "hardware", "app_store",
)


def canonical_bytes(document: Any) -> bytes:
    return json.dumps(document, sort_keys=True, separators=(",", ":")).encode("utf-8")


def canonical_document_sha256(document: Mapping[str, Any]) -> str:
    """The digest of the record's own body, excluding the field that carries it."""
    body = {key: value for key, value in document.items()
            if key != "document_sha256"}
    return hashlib.sha256(canonical_bytes(body)).hexdigest()


def seal(document: Mapping[str, Any]) -> dict[str, Any]:
    """Return the record with its integrity digest filed. The producer calls this.

    This digest proveth INTEGRITY (the record was not edited after sealing); it is
    NOT authenticity, and a locally sealed document is trivially forgeable.
    Authenticity cometh ONLY from `authenticate_release_proof`, which RE-READS the
    pinned run's own facts through `capture_release_proof.capture` and compares them
    with this document; a consumer that accepteth a seal as AUTH is unsound. An
    absent/undecodable digest FAILETH; it is never silently absent."""
    body = {key: value for key, value in document.items()
            if key != "document_sha256"}
    body["document_sha256"] = canonical_document_sha256(body)
    return body


def _hex(value: Any, width: int) -> bool:
    return isinstance(value, str) and bool(re.fullmatch(rf"[0-9a-f]{{{width}}}", value))


def verify_release_proof(document: Any, *,
                         required_job_ids: Sequence[str] = REQUIRED_INTERNAL_JOB_IDS,
                         required_artifacts: Sequence[str] = REQUIRED_INTERNAL_ARTIFACTS,
                         required_boundaries: Sequence[str] = REQUIRED_EXTERNAL_BOUNDARIES,
                         required_external_jobs: Sequence[str] = REQUIRED_EXTERNAL_JOB_IDS,
                         ) -> list[str]:
    """Judge a release-proof record. Returns the problems; empty is a pass."""
    if not isinstance(document, Mapping):
        return ["the release proof must be an object"]
    errors: list[str] = []
    if type(document.get("schema")) is not int or document.get("schema") != SCHEMA:
        errors.append(f"the release proof schema must be {SCHEMA}")

    # ---- the candidate: an exact sha and tree sha, NO tag required --------
    candidate = document.get("candidate")
    if not isinstance(candidate, Mapping):
        errors.append("candidate must be an object with sha and tree_sha")
        candidate = {}
    if not _hex(candidate.get("sha"), 40):
        errors.append("candidate.sha must be the exact 40-character commit sha")
    if not _hex(candidate.get("tree_sha"), 40):
        errors.append("candidate.tree_sha must be the exact 40-character tree sha")
    if candidate.get("tag") is not None:
        # A tag is allowed once it exists, but it is never REQUIRED and never
        # substituted for the exact sha -- the proof bindeth the sha, not the name.
        if not isinstance(candidate["tag"], str) or not candidate["tag"]:
            errors.append("candidate.tag, when present, must be a non-empty string")

    # ---- the run's own facts (the consumer authenticates these) -----------
    run = document.get("run")
    if not isinstance(run, Mapping):
        errors.append("run must be an object (run id, attempt, workflow, head_sha)")
        run = {}
    if not isinstance(run.get("id"), int) or run["id"] <= 0:
        errors.append("run.id must be a positive integer")
    if not isinstance(run.get("attempt"), int) or run["attempt"] < 1:
        errors.append("run.attempt must be an integer >= 1")
    for key in ("workflow", "event", "ref"):
        if not isinstance(run.get(key), str) or not run.get(key):
            errors.append(f"run.{key} must be a non-empty string")
    if not _hex(run.get("head_sha"), 40):
        errors.append("run.head_sha must be the 40-character commit the run built")
    elif run.get("head_sha") != candidate.get("sha"):
        errors.append("run.head_sha is not candidate.sha: the run built a BORROWED "
                      "sha, not the candidate this proof nameth")

    # ---- the internal road ------------------------------------------------
    internal = document.get("internal")
    if not isinstance(internal, Mapping):
        errors.append("internal must be an object (verdict, jobs, refusals)")
        internal = {}
    verdict = internal.get("verdict")
    if verdict not in INTERNAL_VERDICTS:
        errors.append(f"internal.verdict must be one of {list(INTERNAL_VERDICTS)}: "
                      f"{verdict!r}")
    jobs = internal.get("jobs")
    by_id: dict[str, Any] = {}
    if not isinstance(jobs, list) or not jobs:
        errors.append("internal.jobs must be a non-empty list")
        jobs = []
    for index, job in enumerate(jobs):
        if not isinstance(job, Mapping):
            errors.append(f"internal.jobs[{index}] must be an object")
            continue
        jid = job.get("job_id")
        if not jid:
            errors.append(f"internal.jobs[{index}] carrieth no job_id (the workflow "
                          f"job id, e.g. 'ios-archive-only-release')")
            continue
        if jid in by_id:
            errors.append(f"internal job {jid!r} is listed more than once")
        by_id[jid] = job
    for required in required_job_ids:
        if required not in by_id:
            errors.append(f"the canonical internal job {required!r} is MISSING or "
                          f"RENAMED: a candidate cannot be accepted without it")
    artifacts: dict[str, Mapping[str, Any]] = {}
    for jid, job in by_id.items():
        job_id = job.get("id")
        if not (isinstance(job_id, int) and job_id > 0):
            errors.append(f"internal job {jid!r} carrieth no positive numeric id")
        steps = job.get("steps")
        if not isinstance(steps, list) or not steps:
            errors.append(f"internal job {jid!r} carrieth no step")
            steps = []
        for sindex, step in enumerate(steps):
            if not isinstance(step, Mapping):
                errors.append(f"job {jid!r} steps[{sindex}] must be an object")
                continue
            sv = step.get("internal_verdict")
            if sv not in STEP_VERDICTS:
                errors.append(f"job {jid!r} steps[{sindex}] carrieth internal_verdict "
                              f"{sv!r}; the verdict must be derived from the job's own "
                              f"output, one of {list(STEP_VERDICTS)}")
            if step.get("name") == "artifact-inspection" and sv == "SKIPPED":
                errors.append(f"job {jid!r} SKIPPED its artifact inspection: a "
                              f"skipped internal control is not a pass")
        for artifact in job.get("artifacts") or []:
            if not isinstance(artifact, Mapping):
                continue
            aname = artifact.get("name")
            if aname:
                artifacts[aname] = artifact
    for artifact in internal.get("artifacts") or []:
        if isinstance(artifact, Mapping) and artifact.get("name"):
            artifacts[artifact["name"]] = artifact
    for artifact in artifacts.values():
        if not SHA256_RE.fullmatch(str(artifact.get("sha256"))):
            errors.append(f"artifact {artifact.get('name')!r} carrieth no lower-case "
                          f"SHA-256")
        if not isinstance(artifact.get("bytes"), int) or artifact["bytes"] < 0:
            errors.append(f"artifact {artifact.get('name')!r} carrieth no byte count")
    refusals = internal.get("refusals")
    if not isinstance(refusals, list):
        errors.append("internal.refusals must be a list")
        refusals = []
    if verdict == "PASS":
        for required in required_job_ids:
            job = by_id.get(required)
            if isinstance(job, Mapping) and job.get("conclusion") != "success":
                errors.append(f"the canonical internal job {required!r} concluded "
                              f"{job.get('conclusion')!r}, not success")
        for required in required_artifacts:
            if required not in artifacts:
                errors.append(f"internal PASS carrieth no {required!r}: an empty "
                              f"artifact population cannot be a pass")
        if refusals:
            errors.append(f"internal PASS carrieth {len(refusals)} refusal(s): "
                          f"{refusals[:3]}")
    elif not refusals:
        errors.append(f"internal {verdict} must name at least one refusal")

    # ---- the external road, kept SEPARATE ---------------------------------
    external = document.get("external")
    if not isinstance(external, Mapping):
        errors.append("external must be an object (verdict, roster)")
        external = {}
    ex_verdict = external.get("verdict")
    if ex_verdict not in EXTERNAL_VERDICTS:
        errors.append(f"external.verdict must be one of {list(EXTERNAL_VERDICTS)}: "
                      f"{ex_verdict!r}")
    roster = external.get("roster")
    if not isinstance(roster, list):
        errors.append("external.roster must be a list")
        roster = []
    if ex_verdict == "BLOCKED_EXTERNAL":
        seen_jobs: dict[str, int] = {}
        for index, entry in enumerate(roster):
            if not isinstance(entry, Mapping):
                errors.append(f"external.roster[{index}] must be an object")
                continue
            jid = entry.get("id")
            boundary = entry.get("boundary_step")
            result = entry.get("boundary_result")
            if jid not in EXTERNAL_JOB_BOUNDARIES:
                errors.append(f"external.roster[{index}] nameth job {jid!r}, which is "
                              f"not one of the release-gates external jobs -- an "
                              f"invented job may not stand for an external road")
            elif boundary not in EXTERNAL_JOB_BOUNDARIES[jid]:
                errors.append(f"external.roster[{index}] bindeth job {jid!r} to boundary "
                              f"{boundary!r}, which that job never reacheth ({', '.join(EXTERNAL_JOB_BOUNDARIES[jid])})")
            if boundary not in EXTERNAL_BOUNDARIES:
                errors.append(f"external.roster[{index}] nameth boundary "
                              f"{boundary!r}, which is NOT an external boundary: an "
                              f"internal prerequisite failure may not wear an "
                              f"external name")
            if boundary not in required_boundaries:
                errors.append(f"external.roster[{index}] nameth boundary "
                              f"{boundary!r}, which the release-gates workflow never "
                              f"emitteth: only {list(required_boundaries)} are real")
            if isinstance(jid, str) and jid in seen_jobs:
                errors.append(f"external job {jid!r} is represented more than once: a "
                              f"job's external road may not be duplicated or hidden")
            if isinstance(jid, str):
                seen_jobs[jid] = index
            if result == "success":
                errors.append(f"external.roster[{index}] is BLOCKED_EXTERNAL and yet "
                              f"its boundary succeeded")
            if not entry.get("refusal_reason"):
                errors.append(f"external.roster[{index}] is BLOCKED_EXTERNAL and "
                              f"carrieth no refusal_reason")
        for required_job in required_external_jobs:
            if required_job not in seen_jobs:
                errors.append(f"external BLOCKED_EXTERNAL carrieth no entry for the "
                              f"required external job {required_job!r}: an un-named "
                              f"external job is an unreported one")
    else:
        for index, entry in enumerate(roster):
            if not isinstance(entry, Mapping):
                errors.append(f"external.roster[{index}] must be an object")
                continue
            boundary = entry.get("boundary_step")
            result = entry.get("boundary_result")
            if ex_verdict == "PASS":
                if result != "success":
                    errors.append(f"external.roster[{index}] is PASS and its boundary "
                                  f"result is {result!r}, not success")
                if not entry.get("actual_ids"):
                    errors.append(f"external.roster[{index}] is PASS and carrieth no "
                                  f"actual external ids (the boundary was not reached)")
    if ex_verdict == "UNVERIFIED" and roster:
        errors.append("external UNVERIFIED carrieth a roster: an unverified road "
                      "nameth no boundary")

    # ---- integrity (NOT authenticity) ------------------------------------
    filed = document.get("document_sha256")
    if filed is None:
        errors.append("the record carrieth no document_sha256")
    elif not SHA256_RE.fullmatch(str(filed)):
        errors.append("document_sha256 is not a lower-case SHA-256")
    elif filed != canonical_document_sha256(document):
        errors.append("document_sha256 does not recompute over the record's own body: "
                      "the record was edited after it was sealed")
    return errors


def authenticate_release_proof(document: Any, *, repo: str, candidate_sha: str,
                               candidate_tree_sha: str) -> list[str]:
    """*** AUTHENTICATE a bound release proof against the live hosted FACTS. ***

    *This is the common consumer authority: the shared reader and the freeze MUST
    call it. `verify_release_proof` alone proveth only structure and INTEGRITY -- a
    locally sealed document can carry invented run/job ids, artifact digests and
    boundary claims. Authenticity cometh from RE-READING the pinned run's own facts
    through the SAME capture authority that produced the record and comparing them.*

    It:
      1. runneth the structural/integrity validator FIRST (a malformed or re-sealed
         record is refused before any network read);
      2. refuseth unless the document's own candidate SHA/tree bind the caller's
         exact C and the git-derived C tree;
      3. RE-DERIVES the pinned release document through
         `capture_release_proof.capture` -- which requirith the exact run/attempt,
         the candidate head, the five-job population and its inspection steps, the
         REQUIRED uploaded artifact identities/digests, the typed external boundary
         logs, and the candidate's ACTUAL remote commit tree (refusing a supplied
         tree that is not the remote tree);
      4. requirith the actual remote tree to BE the git-derived C tree, and the
         document candidate SHA/tree to BE C;
      5. compareth the deterministic canonical captured body digest with the
         supplied bound document's -- an altered job/artifact digest/boundary claim
         or a self-sealed forgery differeth and is refused.

    *It requirith NO prior replay, accepteth NO local-signed JSON substitute and
    overrideth nothing on a transport success alone: an unreadable remote, a
    fabricated id/digest or a mismatched document FAILETH CLOSED. Returns the
    problems; empty is a pass.*
    """
    problems: list[str] = []
    # 1. structure and integrity FIRST.
    problems.extend(verify_release_proof(document))
    if not isinstance(document, Mapping):
        return problems
    # 2. the document must bind the caller's EXACT candidate and its git tree.
    candidate = document.get("candidate")
    candidate = candidate if isinstance(candidate, Mapping) else {}
    if str(candidate.get("sha") or "").lower() != str(candidate_sha).lower():
        problems.append(f"the release proof bindeth candidate "
                        f"{candidate.get('sha')!r}, not {candidate_sha!r}")
    if str(candidate.get("tree_sha") or "").lower() != str(candidate_tree_sha).lower():
        problems.append(f"the release proof bindeth candidate tree "
                        f"{candidate.get('tree_sha')!r}, not the git-derived C tree "
                        f"{candidate_tree_sha!r}")
    run = document.get("run")
    run = run if isinstance(run, Mapping) else {}
    run_id, attempt = run.get("id"), run.get("attempt")
    if not (isinstance(run_id, int) and isinstance(attempt, int)):
        problems.append("the release proof carrieth no pinned run id/attempt and cannot "
                        "be re-derived against the hosted facts")
        return problems
    # 3. RE-DERIVE the pinned facts. The local import avoideth a module cycle:
    #    capture_release_proof importeth THIS module at import time, so THIS side
    #    importeth it lazily, inside the call. *The capture module is resolved from
    #    sys.modules FIRST, so an in-process consumer and the capture authority
    #    share ONE module identity (and one transport seam) rather than a duplicate
    #    `tools.supplychain.*` and `capture_release_proof` pair.*
    _capture = None
    try:
        _module = sys.modules.get("capture_release_proof")
        if _module is None:
            _module = sys.modules.get("tools.supplychain.capture_release_proof")
        if _module is None:
            try:
                _module = importlib.import_module("tools.supplychain.capture_release_proof")
            except Exception:  # noqa: BLE001
                _module = importlib.import_module("capture_release_proof")
        _capture = getattr(_module, "capture", None)
    except Exception as exc:  # noqa: BLE001
        problems.append(f"the capture authority is not importable, so the pinned "
                        f"release run cannot be authenticated: {exc}")
        return problems
    if not callable(_capture):
        problems.append("the capture authority is importable but exporteth no "
                        "capture(); the pinned release run cannot be authenticated")
        return problems
    try:
        captured = _capture(repo, run_id, attempt, candidate_sha, candidate_tree_sha)
    except Exception as exc:  # noqa: BLE001
        problems.append(f"the pinned release run {run_id} attempt {attempt} could not "
                        f"be re-read from the hosted facts (FAIL CLOSED): {exc}")
        return problems
    if not isinstance(captured, Mapping):
        problems.append("the capture authority returned no document")
        return problems
    # 4. the ACTUAL remote tree and the document bindings must be the caller's C.
    cap_candidate = captured.get("candidate")
    cap_candidate = cap_candidate if isinstance(cap_candidate, Mapping) else {}
    if str(cap_candidate.get("tree_sha") or "").lower() != str(candidate_tree_sha).lower():
        problems.append(f"the ACTUAL remote tree {cap_candidate.get('tree_sha')!r} is "
                        f"not the git-derived C tree {candidate_tree_sha!r}")
    # 5. the supplied bound document must BE the freshly captured actual document.
    if canonical_document_sha256(captured) != canonical_document_sha256(document):
        problems.append("the supplied release document does not match the facts the "
                        "pinned run actually produced: its run/job/artifact/boundary "
                        "claims are altered or fabricated")
    return problems


def _sound_record() -> dict[str, Any]:
    job_ids = {jid: 1000 + i for i, jid in enumerate(REQUIRED_INTERNAL_JOB_IDS)}
    jobs = []
    for jid in REQUIRED_INTERNAL_JOB_IDS:
        jobs.append({
            "job_id": jid, "id": job_ids[jid], "conclusion": "success",
            "steps": [{"name": "verify the pinned build supply chain",
                       "conclusion": "success", "internal_verdict": "PASS",
                       "source": "step-json"},
                      {"name": "artifact-inspection", "conclusion": "success",
                       "internal_verdict": "PASS", "source": "inspector-report"}],
            "artifacts": [],
        })
    artifacts = [{"name": "ios-archive-only-unsigned", "path": "ios/",
                  "sha256": "a" * 64, "bytes": 4096},
                 {"name": "android-archive-only-unsigned", "path": "android/",
                  "sha256": "b" * 64, "bytes": 8192}]
    return {
        "schema": 2,
        "candidate": {"sha": "4c0569ee" + "0" * 32, "tree_sha": "1" * 40},
        "run": {"id": 36864119928, "attempt": 2, "workflow": "release-gates",
                "event": "push", "ref": "refs/heads/board1/x",
                "head_sha": "4c0569ee" + "0" * 32},
        "internal": {"verdict": "PASS", "jobs": jobs, "artifacts": artifacts,
                     "refusals": []},
        "external": {"verdict": "BLOCKED_EXTERNAL", "roster": [
            {"id": "noise-conformance", "boundary_step": "noise_fixture",
             "boundary_result": "blocked", "actual_ids": None,
             "refusal_reason": "no approved independent Noise vector is pinned"},
            {"id": "llm-native-stack", "boundary_step": "native_models",
             "boundary_result": "blocked", "actual_ids": None,
             "refusal_reason": "llama.cpp native stack is absent and unpinned"},
            {"id": "production-corpus", "boundary_step": "model_weights",
             "boundary_result": "blocked", "actual_ids": None,
             "refusal_reason": "no independently approved model WEIGHTS are pinned "
                               "(checked before the approved content inputs)"}]},
    }


def _selftest() -> int:
    failures: list[str] = []

    def check(name: str, condition: bool) -> None:
        if not condition:
            failures.append(name)

    good = seal(_sound_record())
    check("a sound record was refused", verify_release_proof(good) == [])

    # a missing/renamed canonical job
    renamed = json.loads(json.dumps(good))
    renamed["internal"]["jobs"][0]["job_id"] = "some other job"
    renamed = seal(renamed)
    check("a renamed canonical job was tolerated",
          any("MISSING or RENAMED" in e for e in verify_release_proof(renamed)))
    # a duplicated job
    dup = json.loads(json.dumps(good))
    dup["internal"]["jobs"].append(dict(dup["internal"]["jobs"][0]))
    dup = seal(dup)
    check("a duplicated job was tolerated",
          any("more than once" in e for e in verify_release_proof(dup)))
    # a skipped internal artifact inspection
    skipped = json.loads(json.dumps(good))
    skipped["internal"]["jobs"][0]["steps"][1]["internal_verdict"] = "SKIPPED"
    skipped = seal(skipped)
    check("a skipped artifact inspection was tolerated",
          any("SKIPPED its artifact inspection" in e
              for e in verify_release_proof(skipped)))
    # empty artifact population under PASS
    empty = json.loads(json.dumps(good))
    empty["internal"]["artifacts"] = []
    for job in empty["internal"]["jobs"]:
        job["artifacts"] = []
    empty = seal(empty)
    check("an empty artifact population was tolerated",
          any("empty artifact population" in e for e in verify_release_proof(empty)))
    # a borrowed other sha
    borrowed = json.loads(json.dumps(good))
    borrowed["run"]["head_sha"] = "a" * 40
    borrowed = seal(borrowed)
    check("a borrowed sha was tolerated",
          any("BORROWED" in e for e in verify_release_proof(borrowed)))
    # an internal failure misclassified as external
    misclass = json.loads(json.dumps(good))
    misclass["external"]["roster"] = [
        {"id": "x", "boundary_step": "android:compileDebugKotlin",
         "boundary_result": "failed", "actual_ids": None,
         "refusal_reason": "unrelated compile error"}]
    misclass = seal(misclass)
    check("an internal failure misclassified as external was tolerated",
          any("NOT an external boundary" in e for e in verify_release_proof(misclass)))
    # an external PASS entry with no actual ids
    noids = json.loads(json.dumps(good))
    noids["external"]["verdict"] = "PASS"
    noids["external"]["roster"] = [
        {"id": "x", "boundary_step": "signing", "boundary_result": "success",
         "actual_ids": None, "refusal_reason": ""}]
    noids = seal(noids)
    check("a boundary-less external PASS was tolerated",
          any("no actual external ids" in e for e in verify_release_proof(noids)))
    # an edited body
    edited = json.loads(json.dumps(good))
    edited["run"]["attempt"] = 99
    check("an edited body was not caught by its self-digest",
          any("does not recompute" in e for e in verify_release_proof(edited)))

    for line in failures:
        print(f"::error::{line}")
    if failures:
        print(f"selftest FAILED ({len(failures)})")
        return 1
    print("selftest OK: a sound record passed; a renamed/duplicated job, a skipped "
          "inspection, an empty artifact population, a borrowed sha, a misclassified "
          "external and a boundary-less external PASS were refused")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Verify a release-proof record")
    parser.add_argument("--path", type=Path)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    if args.selftest:
        return _selftest()
    if args.path is None:
        parser.error("--path is required unless --selftest")
    try:
        document = json.loads(Path(args.path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    problems = verify_release_proof(document)
    if args.json:
        print(json.dumps({"problems": problems}, indent=2, sort_keys=True))
    else:
        for line in problems:
            print(f"::error::{line}")
    if problems:
        print(f"{len(problems)} refusal(s)", file=sys.stderr)
        return 1
    print(f"the release proof is sound: run {document.get('run', {}).get('id')} "
          f"attempt {document.get('run', {}).get('attempt')} proved internal "
          f"{document.get('internal', {}).get('verdict')} on "
          f"{document.get('candidate', {}).get('sha')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
