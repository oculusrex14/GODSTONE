#!/usr/bin/env python3
"""Candidate-bound build records; never generate or repair candidate sources at run time."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[2]
EXPECTED_SOURCE = "ios/Godstone/Sources/GodstoneMesh/SQLCipherTrustedExpectation.swift"
RECIPE_FILES = ("tools/supplychain/build_sqlcipher_simulator.sh", "tools/supplychain/verify_sqlcipher_artifact.py", "docs/supplychain/SQLCIPHER.pins.json", EXPECTED_SOURCE)


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1048576), b""):
            h.update(block)
    return h.hexdigest()


def digest_files(files: dict[str, str]) -> str:
    h = hashlib.sha256()
    for name, value in sorted(files.items()):
        h.update(name.encode()); h.update(b"\0"); h.update(value.encode()); h.update(b"\0")
    return h.hexdigest()


def git(*args: str) -> str:
    return subprocess.check_output(["git", "-C", str(REPO), *args], text=True).strip()


def source_identity(candidate: str | None = None) -> dict:
    head = git("rev-parse", "HEAD")
    if candidate is not None and candidate != head:
        raise ValueError("candidate must be the exact current HEAD commit")
    if git("status", "--porcelain", "--untracked-files=no"):
        raise ValueError("candidate has tracked changes; build evidence requires a clean whole source tree")
    names = subprocess.check_output(["git", "-C", str(REPO), "ls-files", "-z"]).decode().split("\0")
    files = {name: sha256(REPO / name) for name in names if name and (REPO / name).is_file()}
    return {"candidate_sha": head, "candidate_tree": git("rev-parse", "HEAD^{tree}"),
            "whole_source_digest": digest_files(files)}


def tree_digest(root: Path) -> str:
    if not root.is_dir():
        raise ValueError(f"built bundle absent: {root}")
    return digest_files({p.relative_to(root).as_posix(): sha256(p) for p in root.rglob("*") if p.is_file()})


def recipe_digest() -> str:
    return digest_files({name: sha256(REPO / name) for name in RECIPE_FILES})


def _register_entry(mode: str) -> tuple[dict, dict, dict]:
    """*** THE REGISTER READ STRICTLY: a missing or malformed field is a REFUSAL, not a default. ***

    *The register is the supply authority for the dlopened image. Every field the attestation will CLAIM
    (`commit`/`tag`/`repo`, per-mode `platform`/`arch`/`toolchain`, `expected_output` sha and byte count,
    `library_name`, `cipher_version_major`) must be PRESENT AND WELL-FORMED here, or there is nothing to attest
    and the build must not proceed. Silent `.get()` defaults turneth an incomplete register into a green
    attestation about nothing.*"""
    if mode not in ("macos", "ios-simulator"):
        raise ValueError(f"unknown SQLCipher mode {mode!r}; the register knows only macos and ios-simulator")
    path = REPO / "docs" / "supplychain" / "SQLCIPHER.pins.json"
    if not path.is_file():
        raise ValueError(f"SQLCipher pin register absent: {path}")
    register = json.loads(path.read_text(encoding="utf-8"))
    if register.get("schema") != 2:
        raise ValueError(f"{path}: the supply register schema must be 2")
    def required(owner: str, key: str, value):
        if value is None or value == "" or value == [] or value == {}:
            raise ValueError(f"{path}: {owner} carrieth no {key!r}")
        return value
    library_name = required("register", "library_name", register.get("library_name"))
    cipher_major = required("register", "cipher_version_major", register.get("cipher_version_major"))
    sources = required("register", "sources", register.get("sources"))
    source = sources[0]
    for key in ("commit", "tag", "repo"):
        required("source", key, source.get(key))
    entry = required("source", f"modes[{mode}]", (source.get("modes") or {}).get(mode))
    for key in ("platform", "arch", "toolchain"):
        required(f"mode {mode}", key, entry.get(key))
    expected = required(f"mode {mode}", "expected_output", entry.get("expected_output"))
    sha = required(f"mode {mode}", "expected_output.sha256", expected.get("sha256"))
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
        raise ValueError(f"{path}: mode {mode} expected_output.sha256 is not a lowercase sha256")
    nbytes = required(f"mode {mode}", "expected_output.bytes", expected.get("bytes"))
    if not isinstance(nbytes, int) or nbytes <= 0:
        raise ValueError(f"{path}: mode {mode} expected_output.bytes is not a positive count")
    return register, source, entry


def verify_image(mode: str, stage: Path) -> dict:
    register, source, entry = _register_entry(mode)
    stage = stage.resolve()
    if stage == REPO or REPO in stage.parents:
        raise ValueError("SQLCipher stage must be outside the candidate repository")
    # *** THE GENERATOR IS CHECKED AS A CONTRACT, IN DUAL MODE, ON BYTES. ***
    #
    # *The trusted expectation is a GENERATED compile input; the lane and the coordinator never re-write a
    # tracked source after a build. So the check must demaneth TWO things of the generator: it is DETERMINISTIC
    # (a second emission from the same verified image is BYTE-IDENTICAL -- an unstable generator would maketh
    # every `expected_source_sha256` binding a coin flip), and its output EQUALS the committed compile input BYTE
    # FOR BYTE (the bytes the compiler will bake are the bytes the register authoriseth). Both emissions land in
    # a temp dir OUTSIDE the repo; the tracked copy is only ever READ.*
    with tempfile.TemporaryDirectory(prefix="gs-pin-verify-") as tmp:
        emitted_a = Path(tmp) / "a" / "SQLCipherTrustedExpectation.swift"
        emitted_b = Path(tmp) / "b" / "SQLCipherTrustedExpectation.swift"
        emitted_a.parent.mkdir(); emitted_b.parent.mkdir()
        for emitted in (emitted_a, emitted_b):
            subprocess.run([sys.executable, str(REPO / "tools/supplychain/verify_sqlcipher_artifact.py"),
                            "--mode", mode, "--dir", str(stage), "--emit-swift", str(emitted)], check=True)
        bytes_a, bytes_b = emitted_a.read_bytes(), emitted_b.read_bytes()
        if bytes_a != bytes_b:
            raise ValueError("the trusted-expectation generator is not deterministic across dual emissions")
        if bytes_a != (REPO / EXPECTED_SOURCE).read_bytes():
            raise ValueError("committed dual-mode expected source differs from deterministic trusted generator")
    library = stage / register["library_name"]
    descriptor = stage / (register["library_name"] + ".artifact.json")
    expected = entry["expected_output"]
    if not library.is_file() or not descriptor.is_file():
        raise ValueError(f"stage carrieth no {register['library_name']} + .artifact.json pair")
    if sha256(library) != expected["sha256"] or library.stat().st_size != expected["bytes"]:
        raise ValueError("image does not match approved register bytes")
    return {"mode": mode, "library_name": register["library_name"], "library_sha256": sha256(library),
            "library_bytes": library.stat().st_size,
            # *** THE PATHS TRAVEL WITH THE DIGESTS SO THE GATE CAN RE-HASH THE ACTUAL BYTES. ***
            # *A recorded digest with no path to re-hash is a claim about bytes nobody can consult; the stage is
            # outside the repo by construction, and the gate re-readeth these files when the run is judged fresh.*
            "library_path": str(library), "descriptor_sha256": sha256(descriptor),
            "descriptor_path": str(descriptor),
            "pinned_source_commit": source["commit"], "pinned_source_tag": source["tag"],
            "pinned_source_repo": source["repo"], "pinned_platform": entry["platform"],
            "pinned_arch": entry["arch"], "pinned_cipher_version_major": register["cipher_version_major"],
            "approved_toolchain": entry["toolchain"], "expected_source_sha256": sha256(REPO / EXPECTED_SOURCE)}


def record_build(mode: str, stage: Path, bundle: Path, identity: dict, attempt: str) -> dict:
    if source_identity(identity["candidate_sha"]) != identity:
        raise ValueError("whole candidate source changed during build")
    return {"schema_version": 2, "producer": "tools/readiness/build_provenance.py",
            "producer_attempt": attempt, **identity, "recipe_digest": recipe_digest(),
            "bundle_digest": tree_digest(bundle), **verify_image(mode, stage)}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("action", choices=("identity", "verify", "record"))
    ap.add_argument("--candidate-sha")
    ap.add_argument("--mode", choices=("macos", "ios-simulator"))
    ap.add_argument("--stage", type=Path)
    ap.add_argument("--bundle", type=Path)
    ap.add_argument("--identity", type=Path)
    ap.add_argument("--attempt")
    ap.add_argument("--out", type=Path)
    args = ap.parse_args()
    try:
        if args.action == "identity":
            value = source_identity(args.candidate_sha)
        elif args.action == "verify":
            value = verify_image(args.mode, args.stage)
        else:
            if not args.attempt or not args.identity or not args.bundle:
                raise ValueError("record requires build identity, actual bundle, and unique producer attempt")
            value = record_build(args.mode, args.stage, args.bundle, json.loads(args.identity.read_text()), args.attempt)
        text = json.dumps(value, sort_keys=True, indent=2) + "\n"
        if args.out:
            args.out.write_text(text)
        else:
            print(text, end="")
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        print(f"build provenance REFUSED: {exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
