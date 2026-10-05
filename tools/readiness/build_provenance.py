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
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[2]
# Generated per-build input; the attestation binds its bytes separately.
EXPECTED_SOURCE = "ios/Godstone/Sources/GodstoneMesh/SQLCipherTrustedExpectation.swift"
# Recipe inputs must be available in a clean checkout, before a lane emits outputs.
RECIPE_FILES = ("tools/supplychain/build_sqlcipher_simulator.sh", "tools/supplychain/verify_sqlcipher_artifact.py", "docs/supplychain/SQLCIPHER.pins.json")
#: The single archive that carries the ACTUAL tested bytes beside the record. One regular file, uncompressed TAR.
TESTED_BYTES_ARCHIVE = "tested-bytes.tar"
BUNDLE_MEMBER_PREFIX = "bundle/"
IMAGE_MEMBER_PREFIX = "image/"
_ARCHIVE_MEMBER_RE = re.compile(r"^(?:bundle|image)/.+$")


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
    """Hash the tracked native builder, expectation generator and pin register."""
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
            # *** ORIGINAL PATHS RECORD RUNTIME PROVENANCE; THE ARCHIVE SERVES THE TESTED BYTES. ***
            # *The stage remains outside the repository. Fresh consumers re-hash the retained bundle/image/
            # descriptor in tested-bytes.tar, never a local rebuild or the producing runner's temporary path.*
            "library_path": str(library), "descriptor_sha256": sha256(descriptor),
            "descriptor_path": str(descriptor),
            "pinned_source_commit": source["commit"], "pinned_source_tag": source["tag"],
            "pinned_source_repo": source["repo"], "pinned_platform": entry["platform"],
            "pinned_arch": entry["arch"], "pinned_cipher_version_major": register["cipher_version_major"],
            "approved_toolchain": entry["toolchain"], "expected_source_sha256": sha256(REPO / EXPECTED_SOURCE)}


def record_build(mode: str, stage: Path, bundle: Path, identity: dict, attempt: str,
                 evidence_dir: Path) -> dict:
    """*** THE RECORD IS READ-ONLY: IT RE-DERIVES THE *EXISTING* ARCHIVE, IT NEVER REGENERATES IT. ***

    *The bytes that were tested are captured ONCE at build time by `retain_tested_bytes`; a later caller (a
    `--skip-build` live comparison, the CLI) must not be able to conjure an archive from whatever is currently on
    disk -- that would make the record a self-healing claim rather than a fact about the past run. So this function
    DEMANDETH the archive under `evidence_dir`, re-hasheth its members, and REFUSETH when it is missing, when its
    bytes disagree with the actual bundle/image/descriptor, or when it names no image pair or bundle file. Only a
    real build invoketh `retain_tested_bytes` BEFORE this function.*"""
    if source_identity(identity["candidate_sha"]) != identity:
        raise ValueError("whole candidate source changed during build")
    value = {"schema_version": 3, "producer": "tools/readiness/build_provenance.py",
             "producer_attempt": attempt, **identity, "recipe_digest": recipe_digest(),
             "bundle_digest": tree_digest(bundle), **verify_image(mode, stage)}
    value["tested_bytes"] = _existing_tested_bytes(Path(evidence_dir), value)
    return value


def _archive_error(exc: Exception) -> ValueError:
    return ValueError(f"{TESTED_BYTES_ARCHIVE}: {exc}")


def _existing_tested_bytes(evidence_dir: Path, facts: dict) -> dict:
    """Re-read the archive that ALREADY exists and bind it to the live bundle/image/descriptor. NEVER writes."""
    tested = tested_bytes_facts(evidence_dir / TESTED_BYTES_ARCHIVE, facts["library_name"])
    if (tested["bundle_digest"] != facts["bundle_digest"] or tested["library_sha256"] != facts["library_sha256"]
            or tested["library_bytes"] != facts["library_bytes"]
            or tested["descriptor_sha256"] != facts["descriptor_sha256"]):
        raise ValueError(f"{TESTED_BYTES_ARCHIVE} does not carry the bytes this record claims "
                         "(bundle/image/descriptor mismatch)")
    return {"path": TESTED_BYTES_ARCHIVE, "sha256": tested["archive_sha256"], "bytes": tested["archive_bytes"]}


def tested_bytes_facts(archive: Path, library_name: str) -> dict:
    """*** THE NON-EXTRACTING SHARED BYTE-HASH UTILITY. ***

    *Stream the members of `archive` -- `bundle/<relative bundle file>` for each regular file of the tested bundle
    and exactly `image/<library_name>` + `image/<library_name>.artifact.json` -- and return their exact facts without
    extracting a byte to disk or holding the archive in memory. A symlink, hardlink, duplicate, special, traversal
    or outside-root member is a REFUSAL, as is a missing image pair or an empty bundle. The bundle digest and the
    image/descriptor facts are recomputed from the archive's OWN payload in the same path->content shape as
    `tree_digest`.*"""
    if not re.fullmatch(r"[^/]+", library_name):
        raise ValueError(f"library_name {library_name!r} is not a bare file name")
    archive = Path(archive)
    if not archive.is_file():
        raise ValueError(f"tested-bytes archive absent: {archive}")
    library_member = f"{IMAGE_MEMBER_PREFIX}{library_name}"
    descriptor_member = library_member + ".artifact.json"
    h_archive, h_bundle, h_image, h_descriptor = hashlib.sha256(), hashlib.sha256(), hashlib.sha256(), hashlib.sha256()
    archive_bytes = 0
    entries: set[str] = set()
    payload: dict[str, tuple[str, int]] = {}
    try:
        with archive.open("rb") as fh:
            while True:
                block = fh.read(1048576)
                if not block:
                    break
                h_archive.update(block)
                archive_bytes += len(block)
        with tarfile.open(archive, "r:") as tar:
            for member in tar:
                name = member.name
                if not member.isfile():
                    raise ValueError(f"member {name!r} is type {member.type!r}; only regular files are allowed")
                if not _ARCHIVE_MEMBER_RE.fullmatch(name) or "//" in name:
                    raise ValueError(f"member {name!r} is outside the bundle/image roots")
                parts = name.split("/")
                if any(part in ("", ".", "..") for part in parts):
                    raise ValueError(f"member {name!r} contains an empty or traversal component")
                if name in entries:
                    raise ValueError(f"duplicate member {name!r}")
                entries.add(name)
                source = tar.extractfile(member)
                digest = hashlib.sha256()
                size = 0
                while True:
                    block = source.read(1048576)
                    if not block:
                        break
                    digest.update(block)
                    size += len(block)
                if name == library_member:
                    h_image = digest
                elif name == descriptor_member:
                    h_descriptor = digest
                elif name.startswith(BUNDLE_MEMBER_PREFIX):
                    rel = name[len(BUNDLE_MEMBER_PREFIX):]
                    h_bundle.update(rel.encode()); h_bundle.update(b"\0")
                    h_bundle.update(digest.hexdigest().encode()); h_bundle.update(b"\0")
                payload[name] = (digest.hexdigest(), size)
    except ValueError:
        raise
    except (tarfile.TarError, OSError) as exc:
        raise _archive_error(exc) from exc
    if not any(name.startswith(BUNDLE_MEMBER_PREFIX) for name in entries):
        raise ValueError(f"{TESTED_BYTES_ARCHIVE}: carries no bundle files")
    for required in (library_member, descriptor_member):
        if required not in entries:
            raise ValueError(f"{TESTED_BYTES_ARCHIVE}: carries no {required}")
    return {"archive_sha256": h_archive.hexdigest(), "archive_bytes": archive_bytes,
            "bundle_digest": h_bundle.hexdigest(),
            "library_sha256": h_image.hexdigest(),
            "library_bytes": payload[library_member][1], "descriptor_sha256": h_descriptor.hexdigest()}


def retain_tested_bytes(bundle: Path, image: dict, evidence_dir: Path) -> dict:
    """*** CAPTURE THE ACTUAL TESTED BYTES, ONCE, BESIDE THE RECORD. ***

    *The record must travel with the real bytes it describes: a report whose bundle/image paths reach into a local
    `.build` tree or a `/var/folders` temp stage proves nothing to a reader who lacks those paths. So this reads the
    VERIFIED register image and descriptor, DEREFERENCES every source file of the actual bundle, and writes exactly
    ONE uncompressed TAR -- `bundle/<relative>` files, `image/<library_name>`, `image/<library_name>.artifact.json`
    -- re-hashing the copied payload and REFUSING if any byte differs from the bundle's `tree_digest` or the
    image/descriptor digests. It NEVER rebuilds and NEVER invents bytes.*"""
    library_name = image["library_name"]
    library = Path(image["library_path"])
    descriptor = Path(image["descriptor_path"])
    if not bundle.is_dir():
        raise ValueError(f"built bundle absent: {bundle}")
    if not library.is_file() or not descriptor.is_file():
        raise ValueError("the retained image/descriptor pair is absent")
    evidence_dir = Path(evidence_dir)
    evidence_dir.mkdir(parents=True, exist_ok=True)
    archive = evidence_dir / TESTED_BYTES_ARCHIVE

    bundle_files: list[tuple[Path, str]] = []
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"bundle carrieth a symlink: {path.relative_to(bundle).as_posix()}")
        if path.is_file():
            bundle_files.append((path, path.relative_to(bundle).as_posix()))
    if not bundle_files:
        raise ValueError("bundle carrieth no regular files")
    bundle_digest_value = digest_files({rel: sha256(path) for path, rel in bundle_files})

    tmp = archive.with_suffix(archive.suffix + ".tmp")
    try:
        with tarfile.open(tmp, "w", format=tarfile.GNU_FORMAT) as tar:
            tar.dereference = True
            for path, rel in bundle_files:
                tar.add(path, arcname=BUNDLE_MEMBER_PREFIX + rel, recursive=False)
            tar.add(library, arcname=IMAGE_MEMBER_PREFIX + library_name, recursive=False)
            tar.add(descriptor, arcname=f"{IMAGE_MEMBER_PREFIX}{library_name}.artifact.json", recursive=False)
        checked = tested_bytes_facts(tmp, library_name)
        if (checked["bundle_digest"] != bundle_digest_value
                or checked["library_sha256"] != image["library_sha256"]
                or checked["library_bytes"] != image["library_bytes"]
                or checked["descriptor_sha256"] != image["descriptor_sha256"]):
            raise ValueError(f"captured {TESTED_BYTES_ARCHIVE} does not match the tested bundle/image")
        tmp.replace(archive)
    except (tarfile.TarError, OSError) as exc:
        tmp.unlink(missing_ok=True)
        raise _archive_error(exc) from exc
    except ValueError:
        tmp.unlink(missing_ok=True)
        raise
    return {"path": TESTED_BYTES_ARCHIVE, "sha256": checked["archive_sha256"], "bytes": checked["archive_bytes"]}


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
            if args.out is None:
                raise ValueError("record requires --out: the tested-bytes archive MUST travel beside the record, "
                                 "so the record's evidence directory is the --out file's parent")
            identity = json.loads(args.identity.read_text())
            image = verify_image(args.mode, args.stage)
            retain_tested_bytes(args.bundle, image, args.out.parent)
            value = record_build(args.mode, args.stage, args.bundle, identity, args.attempt, args.out.parent)
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
