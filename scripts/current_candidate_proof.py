"""Consume external measured controls for an exact candidate; never author a green.

Source plans and historical logs cannot discharge current work. This consumer
requires the actual external manifest's digest binding and independently reads
every control artifact before allowing a runtime transition to DISCHARGED.
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

REQUIRED_FIELDS = ("behavior", "implementation", "reachability", "test", "positive", "negative",
                   "mutation", "independent_counts", "fault_controls", "exact_result", "candidate_binding")
CONTROL_ROLES = ("positive", "negative", "independent_counts", "fault_controls", "reachability")
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
GIT_SHA = re.compile(r"[0-9a-f]{40}\Z")


def _read_object(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ValueError(f"Cannot read proof authority {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError(f"Proof authority {path} must be a JSON object")
    return value


def block_problems(oid: str, block: dict, *, candidate: dict | None = None,
                   evidence_root: Path | None = None, repository: Path | None = None) -> list[str]:
    problems: list[str] = []
    if not isinstance(block, dict):
        return [f"{oid}: structured_discharge must be a mapping"]
    missing = [key for key in REQUIRED_FIELDS if not block.get(key)]
    if missing:
        problems.append(f"{oid}: structured_discharge MISSING {missing}")
    if block.get("reachability") != "production":
        problems.append(f"{oid}: terminal reachability CONTRADICTS a production discharge")
    binding = block.get("candidate_binding")
    if not isinstance(binding, dict):
        return problems + [f"{oid}: candidate_binding is mandatory"]
    for key in ("external_manifest", "attestation", "control_results", "scope"):
        if not binding.get(key):
            problems.append(f"{oid}: candidate_binding missing {key}")
    if binding.get("scope") != "CURRENTC":
        problems.append(f"{oid}: historical candidate binding cannot discharge CURRENTC")
    if "candidate_sha" in binding or "candidate_commit" in binding or "tag_object" in binding:
        problems.append(f"{oid}: source binding may not embed candidate_sha or historical identity")
    if candidate is None or evidence_root is None or repository is None:
        return problems + [f"{oid}: live CURRENTC SHA/tree and external controls were not provided"]
    current = block.get("currentCandidate")
    if not isinstance(current, dict) or current.get("candidate") != candidate:
        problems.append(f"{oid}: currentCandidate does not bind the supplied candidate SHA/tree")
    elif not isinstance(current.get("explanation"), str) or not current["explanation"].strip():
        problems.append(f"{oid}: currentCandidate needs an exact behavior explanation")
    chain = block.get("production_path")
    if not isinstance(chain, list) or len(chain) < 2:
        problems.append(f"{oid}: actual production entry-to-effect path is absent")
    else:
        for step in chain:
            if not isinstance(step, dict) or not all(step.get(k) for k in ("file", "symbol", "effect")):
                problems.append(f"{oid}: malformed production path step")
    artifacts = block.get("artifacts")
    if not isinstance(artifacts, list):
        return problems + [f"{oid}: live control artifacts are absent"]
    roles = set()
    for record in artifacts:
        if not isinstance(record, dict):
            problems.append(f"{oid}: malformed control artifact")
            continue
        role = record.get("role")
        if role not in CONTROL_ROLES:
            problems.append(f"{oid}: unknown control artifact role {role!r}")
            continue
        roles.add(role)
        rel = record.get("path")
        if not isinstance(rel, str) or Path(rel).is_absolute() or ".." in Path(rel).parts:
            problems.append(f"{oid}: invalid external artifact path")
            continue
        path = evidence_root / rel
        try:
            path.resolve().relative_to(evidence_root.resolve())
            if path.is_symlink():
                raise ValueError("symlink control artifact")
            data = path.read_bytes()
        except (OSError, ValueError) as exc:
            problems.append(f"{oid}: cannot read {role} artifact {rel}: {exc}")
            continue
        expected = record.get("sha256")
        if not isinstance(expected, str) or not SHA256.fullmatch(expected) or hashlib.sha256(data).hexdigest() != expected:
            problems.append(f"{oid}: {role} artifact digest mismatch: {rel}")
        # The control describes measured outcomes, never a bare nonempty log or rc=0.
        observations = record.get("observations")
        if not isinstance(observations, list) or not observations:
            problems.append(f"{oid}: {role} has no operation-bound observations")
            continue
        try:
            content = json.loads(data)
        except (UnicodeError, ValueError):
            problems.append(f"{oid}: {role} must contain machine-readable measured results")
            continue
        if not isinstance(content, dict) or content.get("candidate") != candidate:
            problems.append(f"{oid}: {role} artifact belongs to a different candidate")
            continue
        measured = content.get("observations")
        if not isinstance(measured, dict):
            problems.append(f"{oid}: {role} has no measured observation map")
            continue
        for observation in observations:
            if not isinstance(observation, dict) or not all(k in observation for k in ("id", "expected")):
                problems.append(f"{oid}: malformed {role} observation")
            elif observation["id"] not in measured or measured[observation["id"]] != observation["expected"]:
                problems.append(f"{oid}: {role} observation {observation.get('id')} did not establish exact behavior")
    for role in set(CONTROL_ROLES) - roles:
        problems.append(f"{oid}: missing live {role} control")
    return problems


def read_controls(path: Path, *, manifest: dict, candidate: dict, repository: Path) -> tuple[dict, list[str]]:
    """Read only an externally bound current-C producer result, with no fallback."""
    problems: list[str] = []
    try:
        path.resolve().relative_to(repository.resolve())
    except ValueError:
        pass
    else:
        return {}, ["CURRENTC proof must live outside the candidate repository"]
    if not all(isinstance(candidate.get(k), str) and GIT_SHA.fullmatch(candidate[k]) for k in ("commit_sha", "tree_sha")):
        return {}, ["Actual current candidate SHA/tree must be supplied"]
    authority = manifest.get("current_candidate_controls")
    if not isinstance(authority, dict):
        return {}, ["External manifest does not bind current_candidate_controls"]
    try:
        document = _read_object(path)
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
    except (OSError, ValueError) as exc:
        return {}, [str(exc)]
    if authority.get("sha256") != actual or authority.get("path") != path.name:
        problems.append("Control results are not the exact externally manifested artifact")
    if document.get("schema") != 1 or document.get("kind") != "current-candidate-control-results":
        problems.append("Control results have an unsupported schema/kind")
    if document.get("candidate") != candidate or manifest.get("candidate") != candidate:
        problems.append("CURRENTC producer/manifest SHA/tree differs from actual supplied candidate")
    records = document.get("obligations")
    if not isinstance(records, dict) or not records:
        return {}, problems + ["Current control-result obligation register is absent or empty"]
    out = {}
    for oid, block in records.items():
        errors = block_problems(oid, block, candidate=candidate, evidence_root=path.parent, repository=repository)
        problems.extend(errors)
        if not errors:
            out[oid] = block
    return out, problems
