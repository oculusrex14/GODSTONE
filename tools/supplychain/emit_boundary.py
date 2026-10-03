#!/usr/bin/env python3
"""Decide an EXTERNAL boundary from the repository's REAL registers, then emit it.

    # the fail-closed way: consult the registers, do not assert
    python3 tools/supplychain/emit_boundary.py --boundary native_models --check-inputs
    python3 tools/supplychain/emit_boundary.py --boundary noise_fixture   --check-inputs
    python3 tools/supplychain/emit_boundary.py --boundary approved_content --check-inputs
    python3 tools/supplychain/emit_boundary.py --boundary model_weights   --check-inputs

    # the explicit way (kept for a caller that has ALREADY measured the register)
    python3 tools/supplychain/emit_boundary.py --boundary noise_fixture \
        --reason "…" --source-id crypto/cacophony_vectors.json --digest-status ABSENT

EXIT MEANINGS
-------------
    0  the external input is PRESENT and VALID  -> the real gate must now RUN;
                                                       nothing was blocked here
    1  the external input is genuinely ABSENT   -> a structured boundary was emitted
    2  the register could not be JUDGED           -> an ERROR, deliberately NOT a
                                                       boundary (a corrupt lock is not
                                                       evidence that content is missing)

WHY `--check-inputs` IS THE DEFAULT PATH
----------------------------------------
An unconditional "the input is missing" print is a CLAIM, not a measurement: it
stays red after the owner provisions the input, so the gate can never go green,
and it lets the CALLER supply the reason and the expected id (a self-echo). Under
`--check-inputs` this tool READS the pinned register itself, bindeth the actual
source id / path / digest status it found, and returneth 0 when the input really
is present -- so the external step runs its real check instead of being forced RED.

THE COMPONENTS ARE SPLIT
------------------------
The `native_models` boundary is the NATIVE STACK (a pinned llama.cpp revision and
its source tree), NOT the model weights, because `llm-native-stack` buildeth the
native engine: an UNPINNED model-weight status must not stand in for the native
prerequisite. The weights are a DIFFERENT input, judged by `model_weights` (used
by the production-corpus pre-check alongside `approved_content`).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Sequence

ROOT = Path(__file__).resolve().parents[2]

#: What each boundary actually dependeth on, and how its register is judged.
#: A register is ABSENT only on the NAMED evidence; anything else is UNDECIDABLE.
NOISE_VECTORS = "crypto/cacophony_vectors.json"
MODELS_LOCK = "docs/packaging/MODELS.lock.json"
LLAMA_TREE = "third_party/llama.cpp"
APPROVALS_ENV = "GODSTONE_APPROVALS_DIR"
KEYSET_ENV = "GODSTONE_REVIEWER_KEYSET"


class RegisterError(RuntimeError):
    """The register could not be judged. NOT evidence of an absent input."""


def _load_json(path: Path) -> Any:
    if not path.is_file():
        raise RegisterError(f"{path} is not a readable file")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RegisterError(f"{path}: {exc}") from exc


def _sha256(path: Path) -> str:
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_noise_fixture(root: Path) -> dict[str, Any]:
    """An approved INDEPENDENT vector set: not a placeholder, non-empty, sourced."""
    path = root / NOISE_VECTORS
    document = _load_json(path)
    if not isinstance(document, dict):
        raise RegisterError(f"{NOISE_VECTORS} is not an object")
    vectors = document.get("vectors")
    if not isinstance(vectors, list):
        raise RegisterError(f"{NOISE_VECTORS}: 'vectors' is not an array")
    placeholder = bool(document.get("_placeholder"))
    origin = document.get("_where_to_get_it") or {}
    if placeholder or not vectors:
        return {"present": False,
                "source_id": NOISE_VECTORS,
                "path": str(path.relative_to(root)),
                "digest": None,
                "digest_status": "ABSENT",
                "reason": (f"{NOISE_VECTORS} carrieth _placeholder="
                          f"{placeholder} and {len(vectors)} vector(s); an approved "
                          f"independent fixture from "
                          f"{origin.get('source', 'an external source')} is required "
                          f"(self-generated vectors are not accepted)")}
    return {"present": True, "source_id": NOISE_VECTORS,
            "path": str(path.relative_to(root)), "digest": _sha256(path),
            "digest_status": "MEASURED", "reason": ""}


def check_native_models(root: Path) -> dict[str, Any]:
    """The NATIVE STACK: a pinned llama.cpp revision and its source present.

    This is NOT the model-weight register. `llm-native-stack` buildeth the NATIVE
    engine from `docs/packaging/MODELS.lock.json`'s `native` block and the
    `third_party/llama.cpp` tree -- model WEIGHTS are a DIFFERENT input, judged by
    `check_model_weights`. An UNPINNED model-weight status must not stand in for
    the native prerequisite, and an empty/malformed native descriptor is an ERROR,
    not an absence."""
    path = root / MODELS_LOCK
    document = _load_json(path)
    if not isinstance(document, dict):
        raise RegisterError(f"{MODELS_LOCK} is not an object")
    native = document.get("native")
    if native is None:
        raise RegisterError(f"{MODELS_LOCK}: no 'native' component to judge")
    if not isinstance(native, dict):
        raise RegisterError(f"{MODELS_LOCK}: 'native' is not an object")
    revision = native.get("llama_revision")
    repo = native.get("source_repo")
    if not isinstance(repo, str) or not repo:
        raise RegisterError(f"{MODELS_LOCK}: native.source_repo is absent")
    source = root / LLAMA_TREE
    if not revision or not isinstance(revision, str):
        return {"present": False, "source_id": f"{MODELS_LOCK}:native.llama_revision",
                "path": str(path.relative_to(root)), "digest": None,
                "digest_status": "UNPINNED",
                "reason": f"{MODELS_LOCK}: native.llama_revision is absent; the "
                          f"llama.cpp source ({repo}) that :llm buildeth from must be "
                          f"pinned to an exact revision"}
    if not source.is_dir():
        return {"present": False, "source_id": LLAMA_TREE, "path": LLAMA_TREE,
                "digest": None, "digest_status": "ABSENT",
                "reason": f"native.llama_revision {revision} is pinned but the source "
                          f"tree {LLAMA_TREE} is ABSENT: the native stack cannot be "
                          f"built"}
    return {"present": True, "source_id": f"{MODELS_LOCK}:native.llama_revision",
            "path": str(path.relative_to(root)), "digest": _sha256(path),
            "digest_status": "MEASURED", "reason": ""}


def check_model_weights(root: Path) -> dict[str, Any]:
    """The MODEL WEIGHTS: PINNED status and a real digest per artifact."""
    path = root / MODELS_LOCK
    document = _load_json(path)
    if not isinstance(document, dict):
        raise RegisterError(f"{MODELS_LOCK} is not an object")
    status = document.get("status")
    if not isinstance(status, str):
        raise RegisterError(f"{MODELS_LOCK}: no status field")
    artifacts = document.get("artifacts")
    if not isinstance(artifacts, list):
        raise RegisterError(f"{MODELS_LOCK}: artifacts is not an array")
    unspinned = [str(a.get("id")) for a in artifacts if isinstance(a, dict)
                 and not a.get("sha256")]
    if status != "PINNED" or unspinned:
        return {"present": False, "source_id": MODELS_LOCK,
                "path": str(path.relative_to(root)), "digest": None,
                "digest_status": "UNPINNED" if status != "PINNED" else "PARTIAL",
                "reason": (f"{MODELS_LOCK} standeth {status} "
                           f"with {len(unspinned)} digest-less model artifact(s)"
                           + (f": {unspinned[:4]}" if unspinned else "")
                           + "; the weights must be independently verified and pinned")}
    return {"present": True, "source_id": MODELS_LOCK,
            "path": str(path.relative_to(root)), "digest": _sha256(path),
            "digest_status": "MEASURED", "reason": ""}


def check_approved_content(root: Path) -> dict[str, Any]:
    """The approval bundle: a configured dir holding reviewable approval files."""
    approvals_dir = os.environ.get(APPROVALS_ENV) or ""
    keyset = os.environ.get(KEYSET_ENV) or ""
    source_id = f"env:{APPROVALS_ENV}+{KEYSET_ENV}"
    if not approvals_dir or not keyset:
        missing = [name for name, value in ((APPROVALS_ENV, approvals_dir),
                                            (KEYSET_ENV, keyset)) if not value]
        return {"present": False, "source_id": source_id,
                "path": approvals_dir or "(unset)", "digest": None,
                "digest_status": "ABSENT",
                "reason": f"{'/'.join(missing)} not configured; independently reviewed "
                         f"chunk approvals are an external input and a self-generated "
                         f"fixture is not an approval"}
    directory = Path(approvals_dir)
    if not directory.is_dir():
        return {"present": False, "source_id": source_id, "path": approvals_dir,
                "digest": None, "digest_status": "ABSENT",
                "reason": f"{APPROVALS_ENV}={approvals_dir} is not a directory"}
    files = sorted(p for p in directory.rglob("*") if p.is_file())
    if not files:
        return {"present": False, "source_id": source_id, "path": approvals_dir,
                "digest": None, "digest_status": "EMPTY",
                "reason": f"{APPROVALS_ENV} holds no approval files"}
    import hashlib
    rolling = hashlib.sha256()
    for item in files:
        rolling.update(item.name.encode("utf-8"))
        rolling.update(item.read_bytes())
    return {"present": True, "source_id": source_id, "path": approvals_dir,
            "digest": rolling.hexdigest(), "digest_status": "MEASURED",
            "reason": ""}


CHECKERS = {"noise_fixture": check_noise_fixture,
            "native_models": check_native_models,
            "model_weights": check_model_weights,
            "approved_content": check_approved_content}


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Decide an external boundary from the repository's real registers")
    parser.add_argument("--boundary", required=True, choices=tuple(CHECKERS))
    parser.add_argument("--check-inputs", action="store_true",
                        help="judge presence from the pinned register (never assume)")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--expected-id", action="append", default=[])
    parser.add_argument("--reason")
    parser.add_argument("--source-id")
    parser.add_argument("--digest-status")
    args = parser.parse_args(argv)

    if args.check_inputs:
        try:
            verdict = CHECKERS[args.boundary](Path(args.root))
        except RegisterError as exc:
            # An UNJUDGABLE register is an error, not evidence that the input is away.
            print(f"::error::cannot judge the {args.boundary} register: {exc}",
                  file=sys.stderr)
            return 2
        if verdict["present"]:
            print(f"external input for {args.boundary} is PRESENT "
                  f"({verdict['source_id']} digest {str(verdict['digest'])[:12]}… "
                  f"{verdict['digest_status']}): the real gate must now run")
            return 0
        marker = {"boundary": args.boundary, "reason": verdict["reason"],
                  "ids": {verdict["source_id"]: {"path": verdict["path"],
                                                 "digest": verdict["digest"],
                                                 "digest_status": verdict["digest_status"]}}}
        print("::godstone-boundary::" + json.dumps(marker, sort_keys=True))
        print(f"::error::external boundary {args.boundary} not reached: "
              f"{verdict['reason']}", file=sys.stderr)
        return 1

    # Explicit mode: the caller has already measured the register and bindeth what
    # it found. A reason is required, and so is the source it was read from.
    if not args.reason or not args.source_id:
        print("::error::without --check-inputs the caller must supply --reason AND "
              "--source-id (the register it actually measured)", file=sys.stderr)
        return 2
    marker = {"boundary": args.boundary, "reason": args.reason,
              "ids": {args.source_id: {"path": args.source_id, "digest": None,
                                       "digest_status": args.digest_status or "UNVERIFIED"}}}
    if args.expected_id:
        for entry in args.expected_id:
            marker["ids"].setdefault(entry, {"status": "ABSENT"})
    print("::godstone-boundary::" + json.dumps(marker, sort_keys=True))
    print(f"::error::external boundary {args.boundary} not reached: {args.reason}",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
