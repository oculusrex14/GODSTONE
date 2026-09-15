#!/usr/bin/env python3
"""Validate docs/production/RELEASE_GATES_STATUS.json (ADR-008 Stage 3, Phase J; T53).

The release-gates workflow represents external gates that cannot run in
repository-verification explicitly as OPEN/BLOCKED in a durable status file.
This validator enforces that representation so an unavailable external gate can
never be turned green by being silently skipped:

  * the persisted document is VERSIONED (GateStatusV1): only the accepted file
    versions are 1 (the legacy style, kept byte-identical for the sealed
    courts' fixtures) and 2 (this amendment); unknown or future versions are
    REFUSED, never auto-detected;
  * every required gate is present, no gate is duplicated, and a gate outside
    the register of required gates is REFUSED (T53: unknown gate);
  * status is one of {OPEN, BLOCKED, CLOSED};
  * every gate marked CLOSED MUST carry a full commit SHA for its evidence;
    under the v2 register the SHA is additionally RESOLVED against the real
    repository history (an injected resolver at the real dependency boundary;
    the default resolveeth via git cat-file/merge-base) and classified:
    'candidate' (equal to the current candidate), 'ancestor-historical'
    (a formal ancestor of the candidate -- recorded as historical, with the
    changed-inputs drift line noted for it), or REFUSED as stale when it
    doth not resolve to a commit at all;
  * profiled gates (ProfileRequirements) that claim CLOSED MUST carry a
    complete structured GateEvidence block -- run id (digits), executor
    (naming the ci_job), the artifact SHA-256 checksums (full, lower-case),
    positive byte counts, and, for a CANDIDATE-class closure, test results
    (executed > 0, failed == 0). TEST RESULTS UNAVAILABLE IS NEVER MAPPED TO
    PASS: a present-but-empty or zero-executed test_results is refused; a
    historical closure is allowed to omit test results ONLY with the note
    printed and the classification recorded, and is never counted as current;
  * the workflow text (.github/workflows/release-gates.yml) is read and
    cross-checked: the job named by ci_job must EXIST (a missing or skipped
    executor may not close a gate -- 'if: false' is refused), the
    android-archive-only-release job must keep its binary-inspection step
    (scripts/inspect_android_artifacts.py), and a CLOSED production-corpus
    gate may stand only when its job passeth --release to the corpus builder
    (the LIGHT no-embed gate and the future embedded MEDIUM corpus are
    thereby kept apart);
  * the runnable-in-CI gates (A-06, production-corpus, model-native-stack) are
    exercised by release-gates.yml and may be OPEN here while their CI job is
    fail-closed;
  * the not-runnable-in-ci gates (device-interoperability, accessibility,
    battery-thermal, signing-store-approval) MUST retain their external CI
    designation. CLOSED additionally requires an explicit closure requirement;
    CI alone does not establish their on-device or approval evidence.

This is itself a repo-owned gate and runs in repository-verification. The
inner selftests (twelve status controls, ten evidence controls) run with every
plain invocation, before the live file is judged: a checker that can not
refuse the false can not approve the true.
"""
from __future__ import annotations

import argparse
import copy
import json
import re
import subprocess
from pathlib import Path
from typing import Any, Callable, Mapping

ROOT = Path(__file__).resolve().parents[1]
STATUS = ROOT / "docs" / "production" / "RELEASE_GATES_STATUS.json"
WORKFLOW = ROOT / ".github" / "workflows" / "release-gates.yml"

REQUIRED = {
    "A-06-independent-noise-vectors": "ci",
    "production-corpus": "ci",
    "model-native-stack": "ci",
    "android-archive-only-release": "ci",
    "device-interoperability": "not-runnable-in-ci",
    "accessibility": "not-runnable-in-ci",
    "battery-thermal": "not-runnable-in-ci",
    "signing-store-approval": "not-runnable-in-ci",
}
VALID = {"OPEN", "BLOCKED", "CLOSED"}
ACCEPTED_FILE_VERSIONS = (1, 2)
CURRENT_FILE_VERSION = 2
FULL40 = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
RUNID = re.compile(r"[0-9]+")
EXECUTOR = re.compile(r"release-gates\.yml / [a-z0-9-]+$")
REVIEW_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")

#: GS-GATE-001 (AUDIT-004 step 2): every digest-shaped field, wherever it appeareth. The first
#: repair checked only apk/aab/corpus, so `result_sha256: null` on a device gate was invisible.
DIGEST_FIELDS = ("apk_sha256", "aab_sha256", "corpus_sha256", "result_sha256",
                 "source_sha256", "fixture_sha256", "artifact_sha256",
                 "signing_config_sha256")

# The profiled gates and the fields their evidence block must complete when
# CLOSED. The LIGHT no-embed corpus (android archive-only release) is hereby
# split from the future embedded MEDIUM corpus (production corpus): the former
# proveth the binary inspection, the latter proveth --release wiring and the
# pinned corpus digest.
#: The gates whose closure requireth an EXTERNAL human/device/independent artifact, and
#: the evidence each must carry. GS-GATE-001: "unprofiled gates" returned before any
#: executor or result check, which let an external gate be set CLOSED with no evidence
#: block at all and a ci_job that existeth nowhere.
EXTERNAL_GATE_REQUIREMENTS = {
    "A-06-independent-noise-vectors": {
        "approval_fields": ("source_commit", "source_sha256", "fixture_sha256",
                            "reviewer_role", "review_date"),
        "why": "an independently maintained Noise implementation/vector source, pinned and reviewed",
    },
    "production-corpus": {
        "approval_fields": ("corpus_sha256", "reviewer_role", "review_date"),
        "why": "the human-reviewed production corpus",
    },
    "model-native-stack": {
        "approval_fields": ("revision", "artifact_sha256", "approved_role"),
        "why": "the pinned native model stack, reproducibly restored",
    },
    "device-interoperability": {
        "approval_fields": ("device_matrix", "operator_role", "result_sha256"),
        "why": "the physical-device matrix, run by an operator",
    },
    "accessibility": {
        "approval_fields": ("device_matrix", "operator_role", "result_sha256"),
        "why": "the accessibility acceptance on real devices",
    },
    "battery-thermal": {
        "approval_fields": ("device_matrix", "operator_role", "result_sha256"),
        "why": "the battery and thermal acceptance on real devices",
    },
    "signing-store-approval": {
        "approval_fields": ("signing_config_sha256", "approver_role", "approval_reference"),
        "why": "the offline signing policy and store approval, held by the release owner",
    },
}

#: Every gate this register REQUIRES must be judged: a gate present in the file but absent
#: from this map is still judged, by the COMMON rules below.
COMMON_CLOSED_REQUIREMENTS = ("executor", "test_results")

PROFILE_REQUIREMENTS = {
    "android-archive-only-release": {
        "required": ("run_id", "executor", "apk_sha256", "aab_sha256",
                     "apk_bytes", "aab_bytes"),
        "candidate_required": ("test_results",),
        "scope_paths": ("android/app", "android/core",
                        ".github/workflows/release-gates.yml",
                        "scripts/inspect_android_artifacts.py"),
        "workflow_must_hold": ("inspect_android_artifacts.py",),
    },
    "production-corpus": {
        "required": ("run_id", "executor", "corpus_sha256"),
        "candidate_required": ("test_results",),
        "scope_paths": ("content/ingest/build_archive.py",
                        ".github/workflows/release-gates.yml"),
        "workflow_must_hold": ("--release",),
    },
}


def _git_resolves(commit: str) -> bool:
    return subprocess.run(["git", "cat-file", "-t", commit], cwd=str(ROOT),
                          capture_output=True, text=True).stdout.strip() == "commit"


def _git_is_ancestor(commit: str) -> bool:
    return subprocess.run(["git", "merge-base", "--is-ancestor", commit, "HEAD"],
                          cwd=str(ROOT)).returncode == 0


def _git_candidate() -> str:
    return subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(ROOT),
                          capture_output=True, text=True, check=True).stdout.strip()


def _git_drift(commit: str, scope_paths) -> list[str]:
    proc = subprocess.run(["git", "diff", "--name-only", f"{commit}..HEAD", "--", *scope_paths],
                          cwd=str(ROOT), capture_output=True, text=True, check=True)
    return sorted({line for line in proc.stdout.splitlines() if line.strip()})


def _validate_document_fields(data: Any) -> list[str]:
    """The v1 rules, kept byte-identical for the legacy (unversioned) style."""
    errors: list[str] = []
    if not isinstance(data, Mapping) or not isinstance(data.get("gates"), list):
        return ["status must be an object containing a gates array"]
    gates: dict[str, Mapping[str, Any]] = {}
    for index, gate in enumerate(data["gates"]):
        if not isinstance(gate, Mapping) or not isinstance(gate.get("gate"), str) or not gate["gate"].strip():
            errors.append(f"gates[{index}] must be an object with a nonempty gate name")
            continue
        name = gate["gate"]
        if name in gates:
            errors.append(f"duplicate gate: {name}")
        gates[name] = gate

    missing = set(REQUIRED) - set(gates)
    for g in sorted(missing):
        errors.append(f"missing required gate: {g}")

    for name, g in gates.items():
        kind = REQUIRED.get(name)
        status = g.get("status")
        if not isinstance(status, str) or status not in VALID:
            errors.append(f"{name}: invalid status {status!r} (must be one of {sorted(VALID)})")
            continue
        if status == "CLOSED":
            ev = g.get("evidence_commit")
            if not isinstance(ev, str) or not FULL40.fullmatch(ev) or ev == "0" * 40:
                errors.append(f"{name}: CLOSED requires a full nonzero lowercase evidence_commit SHA")
        if kind == "not-runnable-in-ci" and status == "CLOSED":
            # A not-runnable-in-ci gate cannot be closed by CI alone; require
            # an evidence_commit AND a closure_requirement that names on-device
            # evidence. This is a second guard beyond the empty-evidence check.
            if not isinstance(g.get("closure_requirement"), str) or not g["closure_requirement"].strip():
                errors.append(f"{name}: CLOSED not-runnable gate without a "
                              "closure_requirement describing the on-device evidence")
        if kind == "not-runnable-in-ci" and g.get("ci_job") != "not-runnable-in-ci":
            errors.append(f"{name}: must be marked ci_job=not-runnable-in-ci")
        if kind == "ci" and (not isinstance(g.get("ci_job"), str) or not g["ci_job"].startswith("release-gates.yml / ")):
            errors.append(f"{name}: must name its release-gates.yml CI job")
    return errors


def _validate_evidence_block(name: str, g: Mapping[str, Any], errors: list[str],
                              *, resolve: Callable[[str], str],
                              is_ancestor: Callable[[str], bool],
                              candidate: Callable[[], str],
                              drift: Callable[[str, tuple], list[str]],
                              workflow_text: str | None) -> None:
    """The v2 additions: GateEvidence fields, ProfileRequirements, the
    ancestor-mapping classification and the UNAVAILABLE-never-PASS law."""
    status = g.get("status")
    profile = PROFILE_REQUIREMENTS.get(name)
    evidence = g.get("evidence")
    if evidence is not None and not isinstance(evidence, Mapping):
        errors.append(f"{name}: the evidence block must be an object")
        return

    # resolution and classification of the pointer (v2 CLOSED gates)
    classification = None
    if status == "CLOSED":
        ev = str(g.get("evidence_commit", ""))
        if FULL40.fullmatch(ev) and ev != "0" * 40:
            if not resolve(ev):
                errors.append(f"{name}: stale evidence -- the evidence_commit {ev} doth "
                              "not resolve to a commit in the repository history")
            else:
                try:
                    head = candidate()
                except Exception as exc:  # the resolver boundary itself is unreachable
                    head = ""
                    errors.append(f"{name}: the candidate cannot be determined ({exc}); "
                                  "closure is not proven -- UNAVAILABLE is not PASS")
                if ev == head:
                    classification = "candidate"
                elif is_ancestor(ev):
                    classification = "ancestor-historical"
                else:
                    errors.append(f"{name}: the evidence_commit {ev} resolveth not as the "
                                  "candidate nor as an ancestor of it -- closure unproven")

    # the prohibition is universal, profiled or not: a gate that denieth closure
    # shall not carry the record of one
    if status == "OPEN" or status == "BLOCKED":
        if evidence is not None:
            errors.append(f"{name}: an {status} gate shall not carry an evidence block "
                          "(the record would claim what the gate denieth)")
        return

    # GS-GATE-001: a CLOSED gate is judged by the COMMON rules WHATEVER its profile.
    # There is no early return for an "unprofiled" gate: that path is exactly how an
    # external gate could be closed with no evidence block and a job that existeth nowhere.
    external = EXTERNAL_GATE_REQUIREMENTS.get(name)
    if evidence is None:
        wanted = list(profile["required"]) if profile else list(COMMON_CLOSED_REQUIREMENTS)
        if external:
            wanted += list(external["approval_fields"])
        errors.append(
            f"{name}: CLOSED without its structured evidence block (required fields: "
            f"{', '.join(wanted)}); closure without its evidence is UNAVAILABLE, and "
            f"UNAVAILABLE is never PASS")
        return
    for field in (profile["required"] if profile else COMMON_CLOSED_REQUIREMENTS):
        if field not in evidence:
            errors.append(f"{name}: evidence wanteth {field}")
    if external:
        for field in external["approval_fields"]:
            if field not in evidence:
                errors.append(
                    f"{name}: an EXTERNAL gate CLOSED without {field!r} -- its closure "
                    f"requireth {external['why']}")
        role = evidence.get("reviewer_role") or evidence.get("operator_role") or \
            evidence.get("approver_role") or evidence.get("approved_role")
        if not isinstance(role, str) or not role.strip():
            errors.append(
                f"{name}: an EXTERNAL gate must NAME the human or independent role that "
                f"approved it; a status alone is not an approval")
    for sha_field in ("apk_sha256", "aab_sha256", "corpus_sha256"):
        if sha_field in evidence:
            value = evidence[sha_field]
            if not isinstance(value, str) or not SHA256.fullmatch(value):
                errors.append(f"{name}: {sha_field} must be a full lower-case SHA-256 (64 hex digits)")
    # GS-GATE-001 (AUDIT-004 step 2): every digest-shaped field is checked, not only the
    # three the first repair remembered -- the review closed a device gate with
    # `result_sha256=None` and was ACCEPTED because that field was never examined.
    for sha_field in DIGEST_FIELDS:
        if sha_field in evidence and sha_field not in ("apk_sha256", "aab_sha256", "corpus_sha256"):
            value = evidence[sha_field]
            if not isinstance(value, str) or not SHA256.fullmatch(value):
                errors.append(f"{name}: {sha_field} must be a full lower-case SHA-256 "
                              f"(64 hex digits); a NULL digest proveth nothing")
    # ... and a REQUIRED field must carry a VALUE, not a placeholder. AUDIT-004 reproduced a
    # CLOSED device gate carrying every required KEY with every value None.
    wanted_fields = list(profile["required"] if profile else COMMON_CLOSED_REQUIREMENTS)
    if external:
        wanted_fields += list(external["approval_fields"])
    for field in wanted_fields:
        if field in evidence and _is_placeholder(evidence[field]):
            errors.append(
                f"{name}: evidence {field!r} is a NULL or EMPTY placeholder; a declared field "
                f"with no value is not proof, and UNAVAILABLE is never PASS (GS-GATE-001)")
    # a device matrix must NAME devices: an absent, empty or non-list matrix is not a device run
    if "device_matrix" in evidence:
        matrix = evidence["device_matrix"]
        if isinstance(matrix, Mapping):
            devices = list(matrix)
        elif isinstance(matrix, (list, tuple)):
            devices = list(matrix)
        else:
            devices = None
        if devices is None:
            errors.append(f"{name}: device_matrix must be a LIST of devices or an OBJECT keyed "
                          f"by device, not {type(matrix).__name__}")
        elif not [d for d in devices
                  if (isinstance(d, str) and d.strip()) or isinstance(d, Mapping)]:
            errors.append(f"{name}: device_matrix nameth no device; an empty matrix is not a "
                          f"physical device run (GS-GATE-001)")
    if "review_date" in evidence:
        value = evidence["review_date"]
        if not isinstance(value, str) or not REVIEW_DATE.fullmatch(value.strip()):
            errors.append(f"{name}: review_date must be an ISO date (YYYY-MM-DD)")
    if "source_commit" in evidence:
        value = evidence["source_commit"]
        if not isinstance(value, str) or not FULL40.fullmatch(value):
            errors.append(f"{name}: source_commit must be a full lowercase 40-hex commit id")
        elif not resolve(value):
            errors.append(f"{name}: source_commit {value!r} resolveth to no commit in this "
                          f"repository history")
    for byte_field in ("apk_bytes", "aab_bytes"):
        if byte_field in evidence:
            value = evidence[byte_field]
            if type(value) is not int or isinstance(value, bool) or value <= 0:
                errors.append(f"{name}: {byte_field} must be a positive integer")
    if "run_id" in evidence:
        value = evidence["run_id"]
        if not isinstance(value, str) or not RUNID.fullmatch(value):
            errors.append(f"{name}: run_id must be a string of digits (the workflow run identifier)")
    not_runnable = str(g.get("ci_job", "")).strip() == NOT_RUNNABLE_SENTINEL
    if "executor" in evidence:
        value = evidence["executor"]
        if not_runnable:
            if not isinstance(value, str) or not value.strip():
                errors.append(f"{name}: a gate that cannot run in CI must still NAME its "
                              f"executor (the human or device role)")
        elif not isinstance(value, str) or not EXECUTOR.fullmatch(value):
            errors.append(f"{name}: executor must name the release-gates.yml job (release-gates.yml / job-name)")
        elif isinstance(g.get("ci_job"), str) and value != g["ci_job"]:
            errors.append(f"{name}: the evidence executor {value!r} strieth not agree with the "
                          f"gate's ci_job {g['ci_job']!r} (a substituted green is a fixture's green)")

    # the UNAVAILABLE-never-PASS law upon the test results
    results = evidence.get("test_results")
    if results is not None:
        if not isinstance(results, Mapping) or \
           type(results.get("executed")) is not int or isinstance(results.get("executed"), bool) or \
           type(results.get("failed")) is not int or isinstance(results.get("failed"), bool):
            errors.append(f"{name}: test_results must be an object with integer executed and failed")
        elif results["failed"] != 0 or results["executed"] <= 0:
            errors.append(f"{name}: test_results {dict(results)!r} may never be mapped to PASS "
                          "(executed must exceed nought and failed must be nought)")
    else:
        if (classification == "candidate" and profile and
                "test_results" in profile["candidate_required"]):
            errors.append(f"{name}: a CANDIDATE closure must carry test results -- absent "
                          "results are UNAVAILABLE and UNAVAILABLE is never PASS")
        elif external and "test_results" not in evidence:
            # an external closure proveth itself by its APPROVAL, not by a test roster, so
            # it must carry the approval fields validated above; a CI-backed closure must
            # carry results whatever its profile
            pass

    # the workflow cross-checks (only when the text is at hand)
    if workflow_text is not None and not not_runnable:
        job = (g.get("ci_job") or "").split(" / ", 1)[-1]
        block = _workflow_job_block(workflow_text, job)
        if not block:
            errors.append(f"{name}: the job {job!r} is missing from release-gates.yml "
                          "(a missing executor may not close a gate)")
        elif _disabled_condition(block):
            errors.append(f"{name}: the job {job!r} is skipped -- its condition "
                          f"({_disabled_condition(block)!r}) is statically false, and a "
                          f"skipped job is UNAVAILABLE and UNAVAILABLE is never PASS "
                          f"(GS-GATE-001)")
        else:
            for held in (profile or {}).get("workflow_must_hold", ()):
                if held not in block:
                    errors.append(f"{name}: the job {job!r} wanteth {held!r} "
                                  "(the profiled wiring is cut away)")
                    continue
                # AUDIT-004 step 3: a REQUIRED STEP can be disabled by its own condition,
                # which cutteth the profiled wiring away just as surely as deleting it
                holder = next((s for s in _step_blocks(block) if held in s), "")
                if holder and _disabled_condition(holder):
                    errors.append(
                        f"{name}: the step holding {held!r} in job {job!r} is DISABLED by its "
                        f"condition ({_disabled_condition(holder)!r}) -- the profiled wiring is "
                        f"cut away")

    # the historical record: noted with the changed-inputs drift line
    # GS-GATE-001: an EXTERNAL gate carrieth the fields IT requireth (see
    # EXTERNAL_GATE_REQUIREMENTS); a profiled gate carrieth its scope paths for the
    # historical drift recomputation. An unprofiled gate hath neither, and must not raise.
    if classification == "ancestor-historical":
        try:
            changed = drift(str(g.get("evidence_commit")),
                            (profile or {}).get("scope_paths", ()))
        except Exception:
            changed = []
        evidence_note = dict(evidence.get("classification_note") or {})
        evidence_note.update({"kind": "historical", "inputs_changed_since": len(changed),
                             "listed": changed[:24]})
        # the note is computed, not trusted from the document: recompute on demand
        g.setdefault("_notes", {})["classification"] = "historical"
        g["_notes"]["classification_note"] = evidence_note


def _workflow_job_block(text: str, job: str) -> str:
    """The job's block, or the empty block when the job is missing wholly."""
    match = re.search(rf"^  {re.escape(job)}:\n", text, re.M)
    if match is None:
        return ""
    rest = text[match.end():]
    nxt = re.search(r"^  [a-z0-9-]+:", rest, re.M)
    return rest[:nxt.start()] if nxt else rest


def _step_blocks(block: str) -> list[str]:
    """The job block's individual steps, split on the step list marker."""
    parts = re.split(r"^\s*-\s+", block, flags=re.M)
    return parts[1:] if len(parts) > 1 else []


#: GS-GATE-001 (AUDIT-004 step 3): the DEMONSTRABLY DISABLED condition forms. The audited
#: parser recognised only the literal `if: false`, so `if: ${{ false }}` -- which GitHub
#: evaluateth to the same thing -- closed a gate. Only STATICALLY FALSE forms are here: a
#: CONDITIONAL job (`if: inputs.gate == 'open'`, which the real workflow carrieth) is not
#: statically disabled and must stay enabled, or the control would refuse a correct workflow.
_DISABLED_CONDITION = re.compile(
    r"^(?:\$\{\{\s*)?(!\s*true|false)(?:\s*\}\})?$", re.IGNORECASE)


def _disabled_condition(block: str) -> str:
    """The block's own `if:` condition when it is DEMONSTRABLY disabled, else ''."""
    for match in re.finditer(r"^\s*if:\s*(.+?)\s*$", block, re.M):
        raw = match.group(1).strip().strip("'\"")
        if _DISABLED_CONDITION.match(raw):
            return match.group(1).strip()
    return ""


def _is_placeholder(value: Any) -> bool:
    """True when a declared field carrieth no proof in substance.

    AUDIT-004 step 2: the independent review closed a device gate carrying every required KEY
    with every value None, and the checker accepted it because it asked only for the NAME.
    """
    if value is None:
        return True
    if isinstance(value, str):
        return not value.strip()
    if isinstance(value, (list, tuple, dict, set)):
        return len(value) == 0
    return False


# ---------------------------------------------------------------------------
# T77: the repo-owned lanes, and the faces that keep them from being amputated
# ---------------------------------------------------------------------------
# The register above representeth the gates that CANNOT run in
# repository-verification. The lanes below are the opposite: they run in the
# green-capable, repository-owned workflow, and their evidence is a command
# that actually fired there. An external gate can never be turned green by
# being skipped; a repo-owned lane can never be turned green by having its
# command removed either. This roll judgeth only the WIRING -- it maketh no
# claim about what any lane measured.
VERIFICATION_WORKFLOW = ROOT / ".github" / "workflows" / "repository-verification.yml"

REPO_OWNED_LANES: dict[str, dict[str, Any]] = {
    # T77: the update is a transaction. Three commands must stand in the
    # workflow: the authority's own selftest (a control that never fired is
    # not a control), the declared rehearsal ladder, and the court that
    # witnesseth the refusals by name.
    "archive-update-recovery": {
        "workflow": "repository-verification.yml",
        "job_hint": "content",
        "must_hold": (
            "python3 scripts/upgrade_recovery.py --selftest",
            "scripts/upgrade_recovery.py rehearse",
            "test_t77.py",
        ),
        "authority": "scripts/upgrade_recovery.py",
        "support": ("scripts/prepare_release_assets.py", "docs/production/RECOVERY.md"),
    },
    # T52's presence proof: the debug lane must feed a labelled fixture and
    # prove the bytes arrived, or an exclusion-only run could pass for content.
    "debug-archive-presence": {
        "workflow": "repository-verification.yml",
        "job_hint": "android",
        "must_hold": ("ci/archive_fixture.py", "--expected-archive"),
        "authority": "ci/archive_fixture.py",
        "support": ("scripts/inspect_android_artifacts.py",),
    },
}


def _lane_block(text: str, lane: Mapping[str, Any]) -> str:
    """The workflow block the lane's commands live in, by job name."""
    block = _workflow_job_block(text, str(lane["job_hint"]))
    if block:
        return block
    return text


def validate_repo_owned_lanes(*, verification_text: str | None) -> list[str]:
    """Refuse an amputated repo-owned lane BY NAME (T77).

    ``verification_text`` is the repository-verification workflow; None means
    the text is not at hand and no lane is judged (the caller decides whether
    that is acceptable).
    """
    errors: list[str] = []
    if verification_text is None:
        return errors
    for lane_name, lane in REPO_OWNED_LANES.items():
        block = _lane_block(verification_text, lane)
        for face in lane["must_hold"]:
            if face not in block:
                errors.append(
                    f"repo-owned lane {lane_name!r} wanteth {face!r}: the lane may not go "
                    "green by having its command cut away")
        authority = ROOT / str(lane["authority"])
        if not authority.is_file():
            errors.append(f"repo-owned lane {lane_name!r} nameth an absent authority "
                          f"{lane['authority']}")
        else:
            body = authority.read_text(encoding="utf-8")
            if len(body.strip()) < 200:
                errors.append(f"repo-owned lane {lane_name!r}: {lane['authority']} is a husk")
        for support in lane["support"]:
            if not (ROOT / support).is_file():
                errors.append(f"repo-owned lane {lane_name!r} wanteth its support {support}")
    return errors


def selftest_repo_owned_lanes() -> int:
    """The lane roll: every amputation of a repo-owned lane must be refused."""
    live = VERIFICATION_WORKFLOW.read_text(encoding="utf-8")
    if validate_repo_owned_lanes(verification_text=live):
        print("::error::repo-owned lane baseline failed")
        for error in validate_repo_owned_lanes(verification_text=live):
            print(f"::error::{error}")
        return 1
    cases: list[tuple[str, str]] = []
    for lane_name, lane in REPO_OWNED_LANES.items():
        for face in lane["must_hold"]:
            cases.append((f"{lane_name}: {face} cut away", live.replace(face, "echo removed")))
    cases.append(("the whole verification workflow emptied", ""))
    cases.append(("None text is not judged (the caller's own decision)", None))
    failed: list[str] = []
    for label, text in cases:
        errors = validate_repo_owned_lanes(verification_text=text)
        if text is None:
            if errors:
                failed.append(label)
        elif not errors:
            failed.append(label)
    refused = len(cases) - len(failed)
    for label in failed:
        print(f"::error::lane selftest failed to reject {label}")
    print(f"ok: repo-owned lane selftest refuseth {refused} of {len(cases)} amputation controls")
    if failed:
        return 1
    return 0


#: The register's OWN sentinel for a gate that cannot execute in CI (a device or human
#: gate). Its closure proveth itself by its approval evidence, never by a workflow job.
NOT_RUNNABLE_SENTINEL = "not-runnable-in-ci"

#: The gate ids this register REQUIRES, whatever the file version saith.
REQUIRED_GATE_IDS = tuple(REQUIRED)


def _migrate_legacy(data: Mapping, version: int) -> Mapping:
    """GS-GATE-001: normalize a LEGACY (schema 1) register into the current shape.

    The migration is EXPLICIT and loseth nothing: every gate keepeth its id and status,
    and a CLOSED claim keepeth whatever evidence it carrieth -- so the strict rules that
    follow judge the SAME facts. A legacy CLOSED gate without an evidence block therefore
    FAILETH here rather than passing because its file version was older.
    """
    if version >= 2:
        return data
    migrated = dict(data)
    gates = []
    for gate in data.get("gates") or []:
        if not isinstance(gate, Mapping):
            gates.append(gate)
            continue
        normalized = dict(gate)
        normalized.setdefault("migrated_from_schema", version)
        # a legacy closure carrieth no `evidence` block: keep it absent so the required
        # evidence rule fireth, and never invent one
        gates.append(normalized)
    migrated["gates"] = gates
    migrated["schema_version"] = 2
    return migrated


def validate_status(data: Any, *,
                    resolve_evidence: Callable[[str], str] | None = None,
                    is_ancestor: Callable[[str], bool] | None = None,
                    candidate: Callable[[], str] | None = None,
                    drift: Callable[[str, tuple], list[str]] | None = None,
                    workflow_text: str | None = None) -> list[str]:
    errors: list[str] = []
    if not isinstance(data, Mapping) or not isinstance(data.get("gates"), list):
        return ["status must be an object containing a gates array"]
    version = data.get("schema_version", 1)
    if isinstance(version, bool) or type(version) is not int or version not in ACCEPTED_FILE_VERSIONS:
        return [f"schema_version {version!r} is refused (only the accepted file versions "
                f"{ACCEPTED_FILE_VERSIONS} are known; future or malformed styles are never auto-detected)"]
    errors.extend(_validate_document_fields(data))
    # GS-GATE-001: a LEGACY file (schema 1) is MIGRATED into the current in-memory
    # register and then judged by the SAME rules. Returning early on schema 1 is what let
    # an unknown CLOSED gate, a nonexistent all-1 SHA and an evidence-free Android closure
    # pass: a schema downgrade must never buy weaker validation.
    data = _migrate_legacy(data, version)
    # ---- the register: the file rules above, plus the exact-SHA regime ----
    names = [gate.get("gate") for gate in data["gates"] if isinstance(gate, Mapping)]
    for name in sorted(set(names) - set(REQUIRED)):
        errors.append(f"unknown gate {name!r} is not in the register of required gates")
    for name in sorted(set(names) & set(REQUIRED)):
        g = next(gate for gate in data["gates"] if isinstance(gate, Mapping) and gate.get("gate") == name)
        _validate_evidence_block(
            name, g, errors,
            resolve=resolve_evidence or _git_resolves,
            is_ancestor=is_ancestor or _git_is_ancestor,
            candidate=candidate or _git_candidate,
            drift=drift or _git_drift,
            workflow_text=workflow_text)
    return errors


def selftest() -> int:
    fixture = {"gates": [
        {"gate": name, "status": "OPEN", "evidence_commit": None,
         "ci_job": "not-runnable-in-ci" if kind == "not-runnable-in-ci" else f"release-gates.yml / {name}"}
        for name, kind in REQUIRED.items()
    ]}
    if validate_status(fixture):
        print("::error::selftest baseline failed")
        return 1
    cases: list[tuple[str, Any]] = [("invalid root", []), ("invalid gates", {"gates": {}})]
    def mutate(label, change):
        value = copy.deepcopy(fixture)
        change(value)
        cases.append((label, value))
    mutate("missing required gate", lambda value: value["gates"].pop())
    mutate("duplicate gate", lambda value: value["gates"].append(copy.deepcopy(value["gates"][0])))
    mutate("non-object gate", lambda value: value["gates"].append(None))
    mutate("unhashable status", lambda value: value["gates"][0].update(status=[]))
    mutate("fake closure evidence", lambda value: value["gates"][0].update(status="CLOSED", evidence_commit="yes"))
    mutate("unvalidated additional gate", lambda value: value["gates"].append({"gate": "additional", "status": "CLOSED"}))
    mutate("archive-only closure lacks evidence", lambda value: next(g for g in value["gates"] if g["gate"] == "android-archive-only-release").update(status="CLOSED"))
    mutate("external gate relabeled CI", lambda value: value["gates"][-1].update(ci_job="release-gates.yml / pretend"))
    mutate("external closure lacks requirement", lambda value: value["gates"][-1].update(status="CLOSED", evidence_commit="a" * 40))
    mutate("CI job omitted", lambda value: value["gates"][0].update(ci_job=None))
    failed = [label for label, value in cases if not validate_status(value)]
    refused = len(cases) - len(failed)
    for label in failed:
        print(f"::error::selftest failed to reject {label}")
    print(f"ok: release-gate status selftest refuseth {refused} of {len(cases)} malformed/false-closure controls")
    if failed:
        return 1
    return 0


# -- deterministic fakes for the evidence controls (injected at the resolver  --
# boundaries; the real register is proved against the real history in main)  --
_FAKE_HEAD = "c" * 40
_FAKE_KNOWN = {("f" * 40): "commit", ("a" * 40): "commit", ("e" * 40): "tree",
             ("c" * 40): "commit"}
_FAKE_ANCESTORS = {("f" * 40)}


def _fake_resolve(commit: str) -> str:
    return _FAKE_KNOWN.get(commit, "")


def _fake_ancestor(commit: str) -> bool:
    return commit in _FAKE_ANCESTORS


def _fake_candidate() -> str:
    return _FAKE_HEAD


def _fake_drift(commit: str, scope) -> list[str]:
    return ["android/app/build.gradle.kts", ".github/workflows/release-gates.yml"]


_GOOD_WORKFLOW = """
jobs:
  android-archive-only-release:
    runs-on: ubuntu-latest
    if: inputs.gate == 'open'
    steps:
      - run: python scripts/inspect_android_artifacts.py android/app/build artifacts/android
  production-corpus:
    runs-on: ubuntu-latest
    steps:
      - run: python -m content.ingest.build_archive --tier MEDIUM --out dist/archive_medium.db --release
"""


def selftest_evidence() -> int:
    """The v2 controls: ten refusals of the exact-SHA, profiled, ever-living
    regime -- all upon the deterministic fakes; the real history is proved by
    the live file in main, and witnessed by the T53 court."""
    def base():
        return {"schema_version": 2, "gates": [
            {"gate": name, "status": "OPEN", "evidence_commit": None,
             "ci_job": "not-runnable-in-ci" if kind == "not-runnable-in-ci"
                       else f"release-gates.yml / {name}"}
            for name, kind in REQUIRED.items()]}
    def check(kwargs):
        return validate_status(kwargs["data"], resolve_evidence=_fake_resolve,
                               is_ancestor=_fake_ancestor, candidate=_fake_candidate,
                               drift=_fake_drift, workflow_text=kwargs.get("workflow", _GOOD_WORKFLOW))
    cases: list[tuple[str, Any]] = []
    def good_android():
        data = base()
        for g in data["gates"]:
            if g["gate"] == "android-archive-only-release":
                g.update({"status": "CLOSED", "evidence_commit": "f" * 40,
                          "evidence": {"run_id": "31384944062",
                                       "executor": "release-gates.yml / android-archive-only-release",
                                       "apk_sha256": "a" * 64, "aab_sha256": "e" * 64,
                                       "apk_bytes": 2381429, "aab_bytes": 4045840}})
        return data
    good = good_android()
    if check({"data": good}):
        print("::error::evidence selftest baseline failed")
        return 1
    if check({"data": good}) != []:
        print("::error::evidence selftest baseline is not clean")
        return 1
    # the historical classification is recorded, never counted as current
    errors = check({"data": good})
    assert errors == []
    cases.append(("future schema version",
                  lambda d: d.update(schema_version=3)))
    cases.append(("malformed schema version",
                  lambda d: d.update(schema_version="2")))
    cases.append(("unknown gate",
                  lambda d: d["gates"].append({"gate": "rogue-gate", "status": "OPEN",
                                               "ci_job": "not-runnable-in-ci"})))
    cases.append(("unresolvable evidence commit",
                  lambda d: next(g for g in d["gates"] if g["gate"] == "android-archive-only-release").update(
                      evidence_commit="9" * 40)))
    cases.append(("non-ancestor remote commit",
                  lambda d: next(g for g in d["gates"] if g["gate"] == "android-archive-only-release").update(
                      evidence_commit="a" * 40)))
    cases.append(("profiled closure without evidence block",
                  lambda d: next(g for g in d["gates"] if g["gate"] == "production-corpus").update(
                      status="CLOSED", evidence_commit="f" * 40)))
    cases.append(("missing artifact checksum field",
                  lambda d: (next(g for g in d["gates"] if g["gate"] == "android-archive-only-release")["evidence"].pop(
                      "aab_sha256"),
                      next(g for g in d["gates"] if g["gate"] == "android-archive-only-release")["evidence"].update(
                          run_id="")) ))
    cases.append(("truncated checksum",
                  lambda d: next(g for g in d["gates"] if g["gate"] == "android-archive-only-release")["evidence"].update(
                      apk_sha256="a" * 40, executor="oops")))
    cases.append(("zero-run test results mapped to PASS",
                  lambda d: next(g for g in d["gates"] if g["gate"] == "production-corpus").update(
                      status="CLOSED", evidence_commit="f" * 40,
                      evidence={"run_id": "42", "executor": "release-gates.yml / production-corpus",
                                "corpus_sha256": "b" * 64,
                                "test_results": {"executed": 0, "failed": "none"}})))
    cases.append(("unshapen test results",
                  lambda d: next(g for g in d["gates"] if g["gate"] == "production-corpus").update(
                      status="CLOSED", evidence_commit="f" * 40,
                      evidence={"run_id": "42", "executor": "release-gates.yml / production-corpus",
                                "corpus_sha256": "b" * 64,
                                "test_results": {"executed": "0", "failed": "x"}})))
    cases.append(("substituted executor (fixture green)",
                  lambda d: next(g for g in d["gates"] if g["gate"] == "android-archive-only-release")["evidence"].update(
                      executor="release-gates.yml / some-other-job", run_id="4x")))
    failed: list[str] = []
    for label, change in cases:
        data = base() if label not in ("profiled closure without evidence block",
                                       "missing artifact checksum field",
                                       "truncated checksum",
                                       "substituted executor (fixture green)",
                                       "unresolvable evidence commit",
                                       "non-ancestor remote commit") else good_android()
        change(data)
        if not check({"data": data}):
            failed.append(label)
    # the workflow cross-checks of their own right
    workflow_cases = (
        ("--release cut from the corpus job",
         _GOOD_WORKFLOW.replace(" --release", ""), "production-corpus",
         {"corpus_sha256": "b" * 63}),
        ("inspection step cut from the android job",
         _GOOD_WORKFLOW.replace("python scripts/inspect_android_artifacts.py android/app/build artifacts/android",
                               "echo no inspection"), "android-archive-only-release",
         {"run_id": "x"}),
        ("the android job skipped by condition",
         _GOOD_WORKFLOW.replace("if: inputs.gate == 'open'", "if: false").replace(
             "python scripts/inspect_android_artifacts.py android/app/build artifacts/android",
             "echo no inspection"), "android-archive-only-release", {}),
        ("the corpus job missing wholly",
         _GOOD_WORKFLOW.replace("  production-corpus:\n    runs-on: ubuntu-latest\n    steps:\n"
                                "      - run: python -m content.ingest.build_archive --tier MEDIUM "
                                "--out dist/archive_medium.db --release\n", ""), "production-corpus", {}),
    )
    for label, text, gate_name, extra_evils in workflow_cases:
        data = base()
        g = next(item for item in data["gates"] if item["gate"] == gate_name)
        if gate_name == "production-corpus":
            evi = {"run_id": "42", "executor": "release-gates.yml / production-corpus",
                   "corpus_sha256": "b" * 64,
                   "test_results": {"executed": 5, "failed": 0}}
        else:
            evi = {"run_id": "1", "executor": "release-gates.yml / android-archive-only-release",
                   "apk_sha256": "a" * 64, "aab_sha256": "e" * 64,
                   "apk_bytes": 1, "aab_bytes": 1,
                   "test_results": {"executed": 5, "failed": 0}}
        evi.update(extra_evils)
        g.update({"status": "CLOSED", "evidence_commit": "f" * 40, "evidence": evi})
        if not check({"data": data, "workflow": text}):
            failed.append(label)
    refused = (len(cases) + len(workflow_cases)) - len(failed)
    total = len(cases) + len(workflow_cases)
    for label in failed:
        print(f"::error::evidence selftest failed to reject {label}")
    print(f"ok: gate-evidence selftest refuseth {refused} of {total} evidence controls")
    if failed:
        return 1
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--status", type=Path, default=STATUS)
    ap.add_argument("--workflow", type=Path, default=WORKFLOW)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        rc = selftest()
        rc2 = selftest_evidence()
        rc3 = selftest_repo_owned_lanes()
        if rc != 0:
            return rc
        return rc2 if rc2 != 0 else rc3
    # A checker that can not refuse the false can not approve the true: the
    # inner selftests are ever-living, and they judge before the live file does.
    rc = selftest()
    if rc != 0:
        return rc
    rc = selftest_evidence()
    if rc != 0:
        return rc
    rc = selftest_repo_owned_lanes()
    if rc != 0:
        return rc
    try:
        data = json.loads(args.status.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"::error::cannot read status {args.status}: {exc}")
        return 1
    try:
        workflow_text = args.workflow.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"::error::cannot read workflow {args.workflow}: {exc}")
        return 1
    errors = validate_status(data, workflow_text=workflow_text)
    try:
        verification_text = VERIFICATION_WORKFLOW.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"::error::cannot read the repository-verification workflow: {exc}")
        return 1
    errors.extend(validate_repo_owned_lanes(verification_text=verification_text))

    if errors:
        for e in errors:
            print(f"::error::{e}")
        print(f"FAIL: {len(errors)} release-gate status problem(s)")
        return 1
    notes = []
    for gate in data.get("gates", []):
        stored = gate.get("_notes") or {}
        classification = stored.get("classification")
        if classification:
            note = stored.get("classification_note") or {}
            notes.append(f"{gate['gate']} classified {classification.upper()} "
                         f"(inputs changed since: {note.get('inputs_changed_since', '?')})")
    suffix = ("; " + "; ".join(notes)) if notes else ""
    print(f"ok: {len(data['gates'])} release gates represented; CLOSED gates have "
          f"well-formed, resolved and classified evidence pointers (evidence content is "
          f"not verified here){suffix}.")
    print(f"ok: {len(REPO_OWNED_LANES)} repository-owned lanes carry every face they must "
          f"hold; an amputated lane is refused by name.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
