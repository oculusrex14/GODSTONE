#!/usr/bin/env python3
"""Pin the build supply chain, and prove that restoration works offline.

    python3 tools/supplychain/supply_chain.py capture  --out docs/supplychain/TOOLCHAIN.lock.json
    python3 tools/supplychain/supply_chain.py lock     --wheelhouse ~/.cache/godstone-wheelhouse
    python3 tools/supplychain/supply_chain.py cache    --wheelhouse ~/.cache/godstone-wheelhouse
    python3 tools/supplychain/supply_chain.py sbom     --out docs/supplychain/SBOM.json
    python3 tools/supplychain/supply_chain.py verify   --all
    python3 tools/supplychain/supply_chain.py restore  --lane dev --venv /tmp/gs-venv
    python3 tools/supplychain/supply_chain.py compare  --previous DIR --current DIR \
        --name archive_light.db --out docs/supplychain/NONDETERMINISM.json

WHAT THIS IS FOR
----------------
The workflows pin their Actions, and the Archive build pins its models, but the
stuff *between* those two -- the Python environment, the Gradle dependency graph,
the host toolchain, the cache a rebuild restores from -- was still whatever the
machine happened to have. A build that cannot be reproduced is not an offline
archive, it is a rumour. This tool makes each of those legible:

  ToolchainLock                 what this host actually IS (Xcode, SDK, NDK,
                                CMake, JDK, Swift, Python, XcodeGen, the Gradle
                                wrapper and its pinned distribution digest),
                                beside the digests of every reviewed input file,
                                and beside the version each is EXPECTED to be
  DependencyVerificationManifest Gradle's own dependency verification metadata
                                plus a function-split, hash-locked Python
                                environment
  SBOM                          every component the locks name, with its licence
                                where one is known and counted as unknown where
                                it is not
  OfflineCacheManifest          the blobs a rebuild restores from, each with its
                                digest, and a restore that refuseth a blob whose
                                bytes are not the bytes the manifest swore
  NondeterminismRecord          what two runs of the same build produced, and an
                                explicit reason wherever they differed

THE THREE LAWS IT REFUSETH TO BREAK
-----------------------------------
* No hash is invented. A distribution the wheelhouse does not hold is recorded
  UNPINNED with the reason, and a lock whose status is PINNED while any entry
  lacketh a digest is refused as a half-sworn mixture (the register law of
  scripts/model_provenance.py, applied to a different register).
* No tool is assumed. Every version here was measured by running the tool; a
  tool that is absent is recorded ABSENT rather than defaulted, and a measured
  version that disagrees with the pinned expectation is a refusal.
* No secret reacheth the log. Every line this tool writes into a restoration log
  passeth a scanner that refuseth private keys, bearer tokens, and the usual
  credential spellings.

WHAT IT DOES NOT DO
-------------------
It closes no external gate. `NATIVE_MODELS` still owns the model artifacts,
`APPROVED_CONTENT` still owns the corpus, and the native lane
(llama-cpp-python, the NDK-built engine) is recorded UNPINNED because its
closure cannot be restored here. Nothing in this tool may be quoted as evidence
that an installed artifact, a device, or a signed release was verified.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = 1
STATUSES = ("PINNED", "UNPINNED")
TOOL_STATUSES = ("MEASURED", "ABSENT", "MISMATCH", "UNEXPECTED")

REQUIREMENT_RE = re.compile(r"^(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)==(?P<version>[A-Za-z0-9][A-Za-z0-9._+!-]*)$")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")

REQUIREMENT_SOURCES = ("content/requirements.txt", "content/requirements-dev.txt")
MODELS_LOCK = "docs/packaging/MODELS.lock.json"
GRADLE_METADATA = "android/gradle/verification-metadata.xml"
GRADLE_WRAPPER = "android/gradle/wrapper/gradle-wrapper.properties"
TOOLCHAIN_LOCK = "docs/supplychain/TOOLCHAIN.lock.json"
DEPENDENCIES = "docs/supplychain/DEPENDENCIES.json"
CACHE_MANIFEST = "docs/supplychain/OFFLINE_CACHE.json"
SBOM = "docs/supplychain/SBOM.json"
NONDETERMINISM = "docs/supplychain/NONDETERMINISM.json"
REQUIREMENTS_LOCK = "requirements.lock"
LLM_BUILD = "android/llm/build.gradle.kts"
SWIFT_MANIFEST = "ios/Godstone/Package.swift"
PROJECT_SPEC = "ios/project.yml"

# The reviewed inputs whose digests the lock records. A change to any of them
# is a change to what the build is made of.
TOOLCHAIN_INPUTS = (
    (GRADLE_WRAPPER, "the Gradle wrapper's distribution URL and its pinned SHA-256"),
    (LLM_BUILD, "the NDK, CMake, JDK and ABI pins of the native module"),
    ("android/app/build.gradle.kts", "the application's compile/target SDK and JDK"),
    ("android/build.gradle.kts", "the root build's plugin and repository pins"),
    (SWIFT_MANIFEST, "the Swift tools version, platforms and package pins"),
    (PROJECT_SPEC, "the Xcode project specification XcodeGen regenerateth from"),
    ("content/requirements.txt", "the content pipeline's exact pins"),
    ("content/requirements-dev.txt", "the verification lane's exact pins"),
    (MODELS_LOCK, "the model register's coordinates and native toolchain"),
)

# The function split. Every pinned package must appear in at least one lane, or
# a package could be pinned and never installed by any lane -- pinned on paper
# only. The split itself is a reviewable judgement, recorded in the lock.
LANES: tuple[dict[str, Any], ...] = (
    {"lane": "dev", "source": "content/requirements-dev.txt", "packages": None,
     "self_contained": True,
     "rationale": "repository verification and lexical Archive builds; the source "
                  "stateth that no native or model stack is needed, so its closure "
                  "is small enough to restore whole from a local wheelhouse"},
    {"lane": "content", "source": "content/requirements.txt", "packages": None,
     "self_contained": False,
     "rationale": "the full content pipeline, including the native model stack "
                  "whose build needs an NDK toolchain and the external NATIVE_MODELS "
                  "gate"},
    {"lane": "signing", "source": "content/requirements.txt",
     "packages": ("cryptography",), "self_contained": True,
     "rationale": "the Ed25519 signing and verification path of "
                  "content/archive_manifest.py; its closure is a subset of the dev "
                  "lane's and is delivered as wheels, so it is the lane that can be "
                  "restored whole offline on any interpreter"},
    {"lane": "eval", "source": "content/requirements.txt", "packages": ("numpy",),
     "self_contained": True,
     "rationale": "the offline retrieval evaluation, which the source noteth is "
                  "the only consumer of numpy"},
    {"lane": "native", "source": "content/requirements.txt",
     "packages": ("llama-cpp-python",), "self_contained": False,
     "resolution": "content", "requires_native_build": True,
     "rationale": "the model stack: its closure is a subset of the content lane's, so "
                  "it reuseth that resolution rather than downloading the same blobs "
                  "twice, and its sdist must be compiled against the NDK toolchain, "
                  "which belongeth to the external NATIVE_MODELS gate"},
)

SECRET_PATTERNS = (
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "a private key block"),
    (re.compile(r"\b(?:ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{16,}"), "a GitHub token"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "an AWS access key id"),
    (re.compile(r"(?i)\b(?:api[_-]?key|secret|password|passwd|token)\b\s*[:=]\s*\S"),
     "a credential assignment"),
    (re.compile(r"(?i)\bAuthorization\s*:\s*Bearer\s+\S"), "a bearer token"),
    (re.compile(r"(?i)\bhttps?://[^\s/@:]+:[^\s/@]+@"), "credentials in a URL"),
)


class SupplyChainError(RuntimeError):
    """A refusal. Every refusal precedeth every write."""


# ---------------------------------------------------------------------------
# Canonical bytes, strict JSON, digests
# ---------------------------------------------------------------------------
def _require(condition: Any, message: str) -> None:
    if not condition:
        raise SupplyChainError(message)


def canonical(value: Any) -> bytes:
    try:
        text = json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False,
                          allow_nan=False)
    except ValueError as exc:
        raise SupplyChainError(f"the document carrieth a non-finite number: {exc}") from exc
    return (text + "\n").encode("utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_bytes(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def _no_duplicates(pairs: Sequence[tuple[str, Any]]) -> dict[str, Any]:
    seen: set[str] = set()
    out: dict[str, Any] = {}
    for key, value in pairs:
        _require(key not in seen, f"duplicate key {key!r} in supply-chain JSON")
        seen.add(key)
        out[key] = value
    return out


def strict_json(text: str, origin: str = "<json>") -> Any:
    def reject(token: str) -> Any:
        raise SupplyChainError(f"{origin}: JSON constant {token} is not permitted")
    try:
        return json.loads(text, object_pairs_hook=_no_duplicates, parse_constant=reject)
    except json.JSONDecodeError as exc:
        raise SupplyChainError(f"{origin}: not valid JSON: {exc}") from exc


def load_document(path: Path) -> Any:
    path = Path(path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise SupplyChainError(f"cannot read {path}: {exc}") from exc
    return strict_json(text, str(path))


def write_document(path: Path, document: Any) -> str:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    blob = canonical(document)
    handle = tempfile.NamedTemporaryFile(prefix=".supplychain-", dir=path.parent,
                                        delete=False)
    try:
        handle.write(blob)
        handle.flush()
        os.fsync(handle.fileno())
        handle.close()
        os.replace(handle.name, path)
    except BaseException:
        try:
            handle.close()
        except OSError:
            pass
        try:
            os.unlink(handle.name)
        except OSError:
            pass
        raise
    return sha256_bytes(blob)


def _clock_default() -> str:
    return datetime.datetime.now(datetime.timezone.utc).replace(
        microsecond=0).isoformat()


def _hex64(value: Any, label: str) -> str:
    _require(isinstance(value, str) and bool(SHA256_RE.fullmatch(value)),
             f"{label} must be a lower-case SHA-256")
    return value


def _status(value: Any, label: str, allowed: Iterable[str] = STATUSES) -> str:
    _require(value in allowed, f"{label} must be one of {list(allowed)}: {value!r}")
    return str(value)


def canonical_name(name: str) -> str:
    """PEP 503 normalisation: the one spelling of a distribution's name."""
    _require(bool(NAME_RE.fullmatch(name)), f"not a distribution name: {name!r}")
    return re.sub(r"[-_.]+", "-", name).lower()


# ---------------------------------------------------------------------------
# The pinned requirement sources and the function split
# ---------------------------------------------------------------------------
def parse_requirements(path: Path) -> dict[str, str]:
    """Read a pinned requirement file. Only exact `==` pins may stand.

    Ranges, extras, markers, URLs and includes are refused by name: each is a
    coordinate that resolveth differently on a different day, which is the
    property this whole file exists to remove."""
    path = Path(path)
    _require(path.is_file(), f"the requirement source is missing: {path}")
    pinned: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("-"):
            raise SupplyChainError(
                f"{path}:{number}: an option or include is not an exact pin: {line!r}")
        for token, why in (("://", "a direct URL"), ("git+", "a VCS coordinate"),
                           ("@", "a direct URL"), (";", "an environment marker"),
                           ("[", "an extra"), (">", "a range"), ("<", "a range"),
                           ("~", "a compatible release"), ("*", "a wildcard"),
                           (" ", "a stray token")):
            _require(token not in line,
                     f"{path}:{number}: {why} is not an exact pin: {line!r}")
        match = REQUIREMENT_RE.match(line)
        _require(match is not None,
                 f"{path}:{number}: {line!r} is not an exact 'name==version' pin")
        name = canonical_name(match.group("name"))
        version = match.group("version")
        if name in pinned:
            _require(pinned[name] == version,
                     f"{path}:{number}: {name} is pinned twice, to "
                     f"{pinned[name]} and to {version}")
            continue
        pinned[name] = version
    _require(pinned, f"{path}: carrieth no pin at all")
    return pinned


def lane_table(repo: Path = ROOT) -> dict[str, dict[str, Any]]:
    """The function split, with every pinned package accounted for."""
    sources = {rel: parse_requirements(Path(repo) / rel) for rel in REQUIREMENT_SOURCES}
    every: set[str] = set()
    for pinned in sources.values():
        every |= set(pinned)
    lanes: dict[str, dict[str, Any]] = {}
    covered: set[str] = set()
    for spec in LANES:
        pinned = sources[spec["source"]]
        if spec["packages"] is None:
            chosen = dict(pinned)
        else:
            chosen = {}
            for item in spec["packages"]:
                name = canonical_name(item)
                _require(name in pinned,
                         f"lane {spec['lane']!r} nameth {item!r}, which "
                         f"{spec['source']} doth not pin: a lane may only carry "
                         f"packages its own source pinneth")
                chosen[name] = pinned[name]
        _require(chosen, f"lane {spec['lane']!r} carrieth no package")
        lanes[spec["lane"]] = {"source": spec["source"], "packages": chosen,
                               "self_contained": bool(spec["self_contained"]),
                               "rationale": spec["rationale"]}
        covered |= set(chosen)
    missing = sorted(every - covered)
    _require(not missing,
             f"package(s) {missing} are pinned by a requirement source and named by "
             f"no lane: a pin no lane installs is pinned on paper alone")
    return lanes


# ---------------------------------------------------------------------------
# ToolchainLock: what this host is, measured, beside what it is expected to be
# ---------------------------------------------------------------------------
def _probe(argv: Sequence[str]) -> str | None:
    try:
        result = subprocess.run(list(argv), capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    blob = (result.stdout or "") + (result.stderr or "")
    _require(not no_secret_in_log(blob),
             f"the probe {' '.join(argv)} printed something that looketh like a "
             f"credential; refusing to record it")
    return blob


def _first_line(blob: str | None) -> str | None:
    if not blob:
        return None
    for line in blob.splitlines():
        line = line.strip()
        if line:
            return line
    return None


def _wrapper_pins(repo: Path) -> dict[str, str | None]:
    text = (Path(repo) / GRADLE_WRAPPER).read_text(encoding="utf-8")
    url = re.search(r"^distributionUrl=(.+)$", text, re.M)
    digest = re.search(r"^distributionSha256Sum=([0-9a-f]{64})$", text, re.M)
    _require(url is not None, f"{GRADLE_WRAPPER}: no distributionUrl")
    _require(digest is not None,
             f"{GRADLE_WRAPPER}: no distributionSha256Sum; the wrapper would accept "
             f"whatever the network handed it")
    _require(str(url.group(1)).startswith("https\\://") or
             str(url.group(1)).startswith("https://"),
             f"{GRADLE_WRAPPER}: the distribution must be fetched over https")
    version = re.search(r"gradle-([0-9][0-9._]*)-\w+\.zip", str(url.group(1)))
    return {"version": version.group(1) if version else None,
            "sha256": digest.group(1), "url": str(url.group(1))}


def _llm_pins(repo: Path) -> dict[str, str | None]:
    text = (Path(repo) / LLM_BUILD).read_text(encoding="utf-8")
    def grab(pattern: str) -> str | None:
        found = re.search(pattern, text)
        return found.group(1) if found else None
    return {
        "ndk": grab(r'ndkVersion\s*=\s*"([^"]+)"'),
        "cmake": grab(r'version\s*=\s*"([^"]+)"'),
        "jdk": grab(r"VERSION_(\d+)"),
        "compile_sdk": grab(r"compileSdk\s*=\s*(\d+)"),
        "min_sdk": grab(r"minSdk\s*=\s*(\d+)"),
    }


def _swift_pins(repo: Path) -> dict[str, str | None]:
    text = (Path(repo) / SWIFT_MANIFEST).read_text(encoding="utf-8")
    tools = re.search(r"swift-tools-version:\s*([0-9.]+)", text)
    return {"tools_version": tools.group(1) if tools else None}


def _models_lock_pins(repo: Path) -> dict[str, Any]:
    document = load_document(Path(repo) / MODELS_LOCK)
    tools: dict[str, str] = {}
    native = document.get("native") or {}
    for entry in native.get("toolchains") or []:
        if isinstance(entry, Mapping) and entry.get("name"):
            tools[str(entry["name"])] = str(entry.get("version"))
    return {"toolchains": tools, "lock_status": document.get("status")}


def measure_toolchain(repo: Path = ROOT, *,
                      probe: Callable[[Sequence[str]], str | None] | None = None,
                      ndk_versions: Sequence[str] | None = None) -> dict[str, Any]:
    """Measure the host. Nothing here is inferred from a document.

    *** THE NDK WAS THE ONE MEASUREMENT THAT COULD NOT BE INJECTED, AND THAT IS A
    TESTABILITY GAP, NOT A PROPERTY OF THE PROBLEM. *** Every other tool reacheth
    the host through `probe`, so a court can drive it with a deterministic fake and
    no toolchain installed. The NDK alone was read straight off the filesystem
    (`ANDROID_HOME/ndk`, else a Homebrew default), which meant the arm asserting a
    MEASURED NDK could not run anywhere the SDK happeneth to be absent -- **i.e. on
    every hosted runner, which is where the arm matters most.**

    `ndk_versions` is the seam: a caller who NAMES the installed versions getteth
    exactly those, and the default still readeth the real filesystem. The
    measurement is unchanged for production callers; it is merely reachable now.
    """
    probe = probe or _probe
    wrapper = _wrapper_pins(repo)
    llm = _llm_pins(repo)
    swift = _swift_pins(repo)
    models = _models_lock_pins(repo)
    ndk_root = Path(os.environ.get("ANDROID_HOME") or
                    os.environ.get("ANDROID_SDK_ROOT") or
                    "/opt/homebrew/share/android-commandlinetools") / "ndk"
    if ndk_versions is not None:
        ndk_present = sorted(str(v) for v in ndk_versions)
    else:
        ndk_present = sorted(p.name for p in ndk_root.iterdir()) if ndk_root.is_dir() else []

    def tool(name: str, measured: str | None, expected: str | None, *,
             probe_argv: Sequence[str], note: str = "") -> dict[str, Any]:
        if measured is None:
            status = "ABSENT"
        elif expected is None:
            status = "UNEXPECTED"
        elif measured == expected:
            status = "MEASURED"
        else:
            status = "MISMATCH"
        return {"name": name, "measured": measured, "expected": expected,
                "status": status, "probe": " ".join(probe_argv), "note": note}

    java = _first_line(probe(["java", "-version"]))
    java_version = None
    if java:
        found = re.search(r'version "([^"]+)"', java)
        java_version = found.group(1) if found else java
    swift_version = None
    swift_blob = probe(["swift", "--version"])
    if swift_blob:
        found = re.search(r"Apple Swift version ([0-9][0-9.]*)", swift_blob)
        swift_version = found.group(1) if found else _first_line(swift_blob)
    xcode = _first_line(probe(["xcodebuild", "-version"]))
    xcode_version = None
    if xcode:
        found = re.search(r"Xcode ([0-9][0-9.]*)", xcode)
        xcode_version = found.group(1) if found else xcode
    xcodegen_blob = probe(["xcodegen", "--version"])
    xcodegen = None
    if xcodegen_blob:
        found = re.search(r"([0-9]+\.[0-9]+\.[0-9]+)", xcodegen_blob)
        xcodegen = found.group(1) if found else _first_line(xcodegen_blob)
    cmake = None
    cmake_blob = probe(["cmake", "--version"])
    if cmake_blob:
        found = re.search(r"cmake version ([0-9][0-9.]*)", cmake_blob)
        cmake = found.group(1) if found else _first_line(cmake_blob)
    python = _first_line(probe(["python3", "-V"]))
    python_version = None
    if python:
        found = re.search(r"Python ([0-9][0-9.]*)", python)
        python_version = found.group(1) if found else python
    os_name, os_build, arch = platform.system(), platform.version(), platform.machine()
    if platform.system() == "Darwin":
        version_blob = probe(["sw_vers"])
        if version_blob:
            name = re.search(r"ProductName:\s*(.+)", version_blob)
            number = re.search(r"ProductVersion:\s*(\S+)", version_blob)
            build = re.search(r"BuildVersion:\s*(\S+)", version_blob)
            if name and number:
                os_name = f"{name.group(1).strip()} {number.group(1).strip()}"
            if build:
                os_build = build.group(1).strip()

    tools = [
        tool("python", python_version, None, probe_argv=["python3", "-V"],
             note="the interpreter the courts and the content pipeline run under; "
                  "the repo carrieth no pin for it, so it is recorded rather than "
                  "expected"),
        tool("java", java_version, None, probe_argv=["java", "-version"],
             note="the measured JDK; the repository pinneth the LANGUAGE LEVEL "
                  "(17), recorded separately as jdk-target, not the JDK build"),
        tool("jdk-target", llm["jdk"], llm["jdk"],
             probe_argv=["read", LLM_BUILD],
             note="sourceCompatibility/targetCompatibility/jvmTarget, read from "
                  "android/llm/build.gradle.kts rather than probed"),
        tool("swift", swift_version, None, probe_argv=["swift", "--version"],
             note="the compiler; Package.swift's swift-tools-version is recorded "
                  "separately as swift-tools"),
        tool("swift-tools", swift["tools_version"], swift["tools_version"],
             probe_argv=["read", SWIFT_MANIFEST],
             note="swift-tools-version, read from the manifest rather than probed"),
        tool("xcode", xcode_version, None, probe_argv=["xcodebuild", "-version"],
             note="the App Store toolchain cannot be pinned from inside the "
                  "repository; it is recorded so a change is visible"),
        tool("macos", os_name, None, probe_argv=["sw_vers"],
             note=f"build {os_build}, arch {arch}"),
        tool("xcodegen", xcodegen, xcodegen, probe_argv=["xcodegen", "--version"],
             note="the CI lane installeth xcodegen unpinned (brew install xcodegen); "
                  "the expectation recorded here is the version this repository's "
                  "evidence was produced with, and a run that disagrees is visible"),
        tool("cmake", cmake, llm["cmake"] or models["toolchains"].get("cmake"),
             probe_argv=["cmake", "--version"],
             note="expected from android/llm/build.gradle.kts (externalNativeBuild)"),
        tool("ndk", (llm["ndk"] if llm["ndk"] in ndk_present else None), llm["ndk"],
             probe_argv=["ls", str(ndk_root)],
             note=f"installed under {ndk_root}: {ndk_present or 'none'}"),
        tool("gradle-wrapper", wrapper["version"], wrapper["version"],
             probe_argv=["read", GRADLE_WRAPPER],
             note=f"distribution {wrapper['url']} pinned by sha256 "
                  f"{str(wrapper['sha256'])[:12]}..."),
    ]
    for name, expected in sorted(models["toolchains"].items()):
        if name in {t["name"] for t in tools}:
            continue
        tools.append(tool(name, None, expected,
                          probe_argv=["read", MODELS_LOCK],
                          note="declared by the model register's native block; not "
                               "probed here"))

    inputs = []
    for rel, role in TOOLCHAIN_INPUTS:
        path = Path(repo) / rel
        _require(path.is_file(), f"the reviewed input is missing: {rel}")
        inputs.append({"path": rel, "role": role, "bytes": path.stat().st_size,
                       "sha256": sha256_file(path)})

    unresolved = []
    unpinned = []
    for entry in tools:
        if entry["status"] == "ABSENT":
            unresolved.append(
                f"{entry['name']} is absent on this host while "
                f"{entry['expected'] or 'a measured version'} is expected; the lane "
                f"that needeth it must be provisioned before it can be claimed")
        elif entry["status"] == "MISMATCH":
            unresolved.append(
                f"{entry['name']} measureth {entry['measured']} where "
                f"{entry['expected']} is expected")
        elif entry["status"] == "UNEXPECTED":
            unpinned.append(
                f"{entry['name']} measureth {entry['measured']} and the repository "
                f"carrieth no expectation to compare it against: recorded, not pinned")
    return {"tools": tools, "inputs": inputs, "unresolved": unresolved,
            "unpinned": unpinned,
            "host": {"os": os_name, "build": os_build, "arch": arch},
            "models_lock": {"status": models["lock_status"],
                            "toolchains": models["toolchains"]}}


def capture_toolchain(repo: Path = ROOT, *, clock: Callable[[], str] | None = None,
                      probe: Callable[[Sequence[str]], str | None] | None = None,
                      ndk_versions: Sequence[str] | None = None,
                      out: Path | None = None) -> dict[str, Any]:
    measured = measure_toolchain(repo, probe=probe, ndk_versions=ndk_versions)
    document = {
        "schema": SCHEMA,
        "captured_utc": (clock or _clock_default)(),
        "status": "PINNED" if all(t["status"] == "MEASURED"
                                  for t in measured["tools"]) else "UNPINNED",
        "host": measured["host"],
        "tools": measured["tools"],
        "inputs": measured["inputs"],
        "models_lock": measured["models_lock"],
        "unresolved": measured["unresolved"],
        "unpinned": measured["unpinned"],
    }
    if out is not None:
        write_document(Path(out), document)
    return document


def verify_toolchain(document: Any, repo: Path = ROOT) -> list[str]:
    errors: list[str] = []
    if not isinstance(document, Mapping):
        return ["the toolchain lock must be an object"]
    if type(document.get("schema")) is not int or document.get("schema") != SCHEMA:
        errors.append(f"the toolchain lock schema must be {SCHEMA}")
    status = document.get("status")
    if status not in STATUSES:
        errors.append(f"the toolchain lock status must be one of {list(STATUSES)}")
    tools = document.get("tools")
    if not isinstance(tools, list) or not tools:
        return errors + ["the toolchain lock carrieth no tools"]
    names = set()
    for entry in tools:
        if not isinstance(entry, Mapping):
            errors.append("every tool entry must be an object")
            continue
        name = str(entry.get("name"))
        if name in names:
            errors.append(f"tool {name!r} is recorded twice")
        names.add(name)
        if entry.get("status") not in TOOL_STATUSES:
            errors.append(f"tool {name!r}: unknown status {entry.get('status')!r}")
        if entry.get("status") == "MEASURED" and entry.get("measured") != entry.get("expected"):
            errors.append(f"tool {name!r}: status MEASURED but "
                          f"{entry.get('measured')!r} != {entry.get('expected')!r}")
        if entry.get("status") == "MISMATCH":
            errors.append(f"tool {name!r} measureth {entry.get('measured')!r} where the "
                          f"repository pinneth {entry.get('expected')!r}: a measured "
                          f"tool that disagrees with its pin is a refusal, not a note")
        if entry.get("status") != "MEASURED" and status == "PINNED":
            errors.append(f"tool {name!r} standeth {entry.get('status')} yet the lock "
                          f"claimeth PINNED: a half-measured toolchain cannot be sworn")
    if status == "PINNED" and document.get("unresolved"):
        errors.append("the lock claimeth PINNED while carrying unresolved items")
    inputs = document.get("inputs")
    if not isinstance(inputs, list) or not inputs:
        errors.append("the toolchain lock carrieth no reviewed-input digests")
    else:
        for entry in inputs:
            if not isinstance(entry, Mapping):
                errors.append("every input entry must be an object")
                continue
            path = Path(repo) / str(entry.get("path"))
            if not path.is_file():
                errors.append(f"the reviewed input {entry.get('path')!r} is missing")
                continue
            if sha256_file(path) != entry.get("sha256"):
                errors.append(f"the reviewed input {entry.get('path')!r} changed since "
                              f"the lock was captured ({entry.get('sha256')} -> "
                              f"{sha256_file(path)})")
    return errors


# ---------------------------------------------------------------------------
# The hash-locked Python environment
# ---------------------------------------------------------------------------
def _distribution_files(wheelhouse: Path, name: str, version: str) -> list[dict[str, Any]]:
    wheelhouse = Path(wheelhouse)
    if not wheelhouse.is_dir():
        return []
    wanted = canonical_name(name)
    found: list[dict[str, Any]] = []
    for path in sorted(wheelhouse.iterdir()):
        if not path.is_file():
            continue
        stem = path.name.lower()
        base = None
        for suffix in (".tar.gz", ".whl", ".zip"):
            if stem.endswith(suffix):
                base = stem[: -len(suffix)]
                break
        if base is None:
            continue
        # PyPI spelling is not uniform: a distribution whose name carrieth
        # underscores is published as `llama_cpp_python-0.3.2.tar.gz` while its
        # wheel carrieth the platform tag. The NAME is normalised the way a
        # distribution name is normalised; the version is compared exactly, and
        # never normalised (collapsing its dots would make 6.0.2 read 6-0-2).
        match = re.match(r"^(?P<name>.+?)[-_](?P<version>\d[^-_]*)", base)
        if match is None:
            continue
        try:
            published = canonical_name(match.group("name"))
        except SupplyChainError:
            continue
        if published != wanted or match.group("version") != version.lower():
            continue
        kind = ("wheel" if stem.endswith(".whl")
                else "sdist" if stem.endswith(".tar.gz") else "archive")
        found.append({"file": path.name, "kind": kind, "bytes": path.stat().st_size,
                      "sha256": sha256_file(path)})
    return found


def parse_resolution(path: Path) -> dict[str, dict[str, Any]]:
    """Read pip's own resolution report: the closure and the hashes it chose.

    Nothing here is computed by this tool. The report is pip's answer to "what
    exactly wouldst thou install", including the transitive packages a direct
    pin drags in -- which is the half of a hash-locked environment usually left
    out, and the reason a lock listing only direct pins is not installable with
    --require-hashes."""
    path = Path(path)
    _require(path.is_file(), f"the resolution report is missing: {path}")
    document = load_document(path)
    entries = document.get("install")
    _require(isinstance(entries, list) and entries,
             f"{path}: the report carrieth no install entry")
    resolved: dict[str, dict[str, Any]] = {}
    for entry in entries:
        if not isinstance(entry, Mapping):
            raise SupplyChainError(f"{path}: a resolution entry must be an object")
        metadata = entry.get("metadata") or {}
        info = entry.get("download_info") or {}
        archive = info.get("archive_info") or {}
        hashes = archive.get("hashes") or {}
        name = canonical_name(str(metadata.get("name")))
        version = str(metadata.get("version"))
        digest = hashes.get("sha256")
        _require(isinstance(digest, str) and bool(SHA256_RE.fullmatch(digest)),
                 f"{path}: {name}=={version} carrieth no sha256 in its resolution; a "
                 f"resolution without a digest is not a pin")
        resolved[name] = {"version": version, "sha256": digest,
                          "url": str(info.get("url", "")),
                          "requested": bool(entry.get("requested"))}
    return resolved


def _distribution_with_digest(wheelhouse: Path, name: str, version: str,
                              digest: str) -> dict[str, Any] | None:
    """The blob in the wheelhouse whose bytes are the resolved distribution."""
    for item in _distribution_files(wheelhouse, name, version):
        if item["sha256"] == digest:
            return item
    return None


def build_lock(wheelhouse: Path, *, repo: Path = ROOT,
               resolutions: Mapping[str, Path] | None = None,
               clock: Callable[[], str] | None = None) -> dict[str, Any]:
    """Build the function-split, hash-locked manifest.

    Each lane carrieth its closure: the direct pins from the requirement source
    plus every transitive package pip's own resolution named, each with the
    digest pip chose and the blob in the wheelhouse whose bytes are that digest.
    A lane whose closure is not fully present standeth UNPINNED and nameth what
    is missing; nothing is guessed and no hash is invented."""
    wheelhouse = Path(wheelhouse)
    resolutions = dict(resolutions or {})
    lanes = lane_table(repo)
    lane_specs = {spec["lane"]: spec for spec in LANES}
    parsed: dict[str, dict[str, Any]] = {}
    document_lanes: dict[str, Any] = {}
    unresolved: list[str] = []
    caveats: list[str] = []
    for lane, spec in sorted(lanes.items()):
        source_lane = lane_specs[lane].get("resolution", lane)
        if source_lane not in parsed:
            path = resolutions.get(source_lane)
            parsed[source_lane] = parse_resolution(path) if path is not None else {}
        resolved = parsed[source_lane]
        closure: list[dict[str, Any]] = []
        if not resolved:
            reason = ("no resolution report was furnished for this lane, so its "
                      "transitive closure is unknown and a hash-locked environment "
                      "cannot be restored from it")
            unresolved.append(f"lane {lane}: {reason}")
            for name, version in sorted(spec["packages"].items()):
                closure.append({"name": name, "version": version, "origin": "pinned",
                                "status": "UNPINNED", "distributions": [],
                                "reason": reason})
        else:
            for name, pin in sorted(spec["packages"].items()):
                entry = resolved.get(name)
                if entry is None:
                    raise SupplyChainError(
                        f"lane {lane}: {spec['source']} pinneth {name}=={pin} and "
                        f"pip's resolution carrieth it not")
                if entry["version"] != pin:
                    raise SupplyChainError(
                        f"lane {lane}: {name} is pinned to {pin} by "
                        f"{spec['source']} while pip resolved {entry['version']}: the "
                        f"pin and the resolution disagree, and neither may be silently "
                        f"preferred")
            for name, entry in sorted(resolved.items()):
                distribution = _distribution_with_digest(wheelhouse, name,
                                                         entry["version"],
                                                         entry["sha256"])
                origin = "pinned" if name in spec["packages"] else "transitive"
                if distribution is None:
                    reason = (f"the wheelhouse carrieth no distribution whose bytes "
                              f"are pip's resolved {entry['sha256'][:12]}... for "
                              f"{name}=={entry['version']}")
                    closure.append({"name": name, "version": entry["version"],
                                    "origin": origin, "status": "UNPINNED",
                                    "distributions": [], "reason": reason,
                                    "resolved_sha256": entry["sha256"]})
                    unresolved.append(f"lane {lane}: {name}=={entry['version']}: "
                                      f"{reason}")
                else:
                    closure.append({"name": name, "version": entry["version"],
                                    "origin": origin, "status": "PINNED",
                                    "distributions": [distribution],
                                    "resolved_sha256": entry["sha256"]})
        status = ("PINNED" if all(entry["status"] == "PINNED" for entry in closure)
                  else "UNPINNED")
        if lane_specs[lane].get("requires_native_build"):
            caveats.append(
                f"lane {lane}: its closure includeth a distribution that must be "
                f"compiled against the NDK toolchain, which belongeth to the external "
                f"NATIVE_MODELS gate; the digests are pinned, the restoration is not "
                f"claimed here")
        document_lanes[lane] = {
            "source": spec["source"], "rationale": spec["rationale"],
            "resolution_source": source_lane, "status": status,
            "requires_native_build": bool(lane_specs[lane].get("requires_native_build")),
            "direct": sorted(spec["packages"]), "closure": closure,
        }
    status = ("PINNED" if all(l["status"] == "PINNED" for l in document_lanes.values())
              else "UNPINNED")
    return {"schema": SCHEMA, "built_utc": (clock or _clock_default)(),
            "status": status, "wheelhouse": str(wheelhouse), "lanes": document_lanes,
            "unresolved": unresolved, "caveats": caveats}


def render_lock(document: Mapping[str, Any]) -> str:
    """The pip-readable face: `name==version --hash=sha256:...` per lane."""
    lines = [
        "# Hash-locked Python environments, split by function.",
        "#",
        "# Generated by tools/supplychain/supply_chain.py from the pinned requirement",
        "# sources and the reviewed wheelhouse; the machine-readable manifest standeth",
        "# beside it at docs/supplychain/DEPENDENCIES.json. Install a lane with:",
        "#",
        "#   pip install --require-hashes --no-index --find-links <wheelhouse> \\",
        "#       $(sed -n '/^# lane: dev$/,/^# end lane/p' requirements.lock | grep -v '^#')",
        "#",
        f"# status: {document.get('status')}",
    ]
    for lane, spec in sorted((document.get("lanes") or {}).items()):
        lines.append("")
        lines.append(f"# lane: {lane}")
        lines.append(f"# {spec.get('rationale')}")
        lines.append(f"# status: {spec.get('status')}")
        for entry in spec.get("closure") or []:
            hashes = " ".join(f"--hash=sha256:{d['sha256']}"
                              for d in entry.get("distributions") or [])
            if hashes:
                lines.append(f"{entry['name']}=={entry['version']} {hashes}")
            else:
                lines.append(f"# {entry['name']}=={entry['version']}  # UNPINNED: "
                             f"{entry.get('reason')}")
        lines.append("# end lane")
    return "\n".join(lines) + "\n"


def verify_lock(document: Any, *, repo: Path = ROOT,
                lock_text: str | None = None) -> list[str]:
    errors: list[str] = []
    if not isinstance(document, Mapping):
        return ["the dependency manifest must be an object"]
    if type(document.get("schema")) is not int or document.get("schema") != SCHEMA:
        errors.append(f"the dependency manifest schema must be {SCHEMA}")
    lanes = document.get("lanes")
    if not isinstance(lanes, Mapping) or not lanes:
        return errors + ["the dependency manifest carrieth no lanes"]
    expected_lanes = lane_table(repo)
    for lane, spec in expected_lanes.items():
        got = lanes.get(lane)
        if not isinstance(got, Mapping):
            errors.append(f"lane {lane!r} is missing from the manifest")
            continue
        closure = got.get("closure")
        if not isinstance(closure, list) or not closure:
            errors.append(f"lane {lane!r} carrieth no closure")
            continue
        by_name: dict[str, Mapping[str, Any]] = {}
        for entry in closure:
            if not isinstance(entry, Mapping):
                errors.append(f"lane {lane!r} carrieth a malformed closure entry")
                continue
            name = str(entry.get("name"))
            if name in by_name:
                errors.append(f"lane {lane!r}: {name} appeareth twice in the closure")
            by_name[name] = entry
            if entry.get("origin") not in ("pinned", "transitive"):
                errors.append(f"lane {lane!r}: {name} carrieth origin "
                              f"{entry.get('origin')!r}")
            status = entry.get("status")
            if status not in STATUSES:
                errors.append(f"lane {lane!r}: {name} carrieth status {status!r}")
            distributions = entry.get("distributions")
            if not isinstance(distributions, list):
                errors.append(f"lane {lane!r}: {name} carrieth no distributions list")
                continue
            if status == "PINNED" and not distributions:
                errors.append(f"lane {lane!r}: {name} claimeth PINNED while carrying "
                              f"no distribution digest -- a half-sworn mixture")
            for item in distributions:
                if not isinstance(item, Mapping):
                    errors.append(f"lane {lane!r}: {name} carrieth a malformed "
                                  f"distribution")
                    continue
                if not isinstance(item.get("sha256"), str) or not SHA256_RE.fullmatch(
                        str(item.get("sha256"))):
                    errors.append(f"lane {lane!r}: {name} carrieth a digest that is "
                                  f"not a lower-case SHA-256: {item.get('sha256')!r}")
                if type(item.get("bytes")) is not int or item["bytes"] <= 0:
                    errors.append(f"lane {lane!r}: {name} carrieth a non-positive "
                                  f"byte count")
                if (entry.get("resolved_sha256")
                        and item.get("sha256") != entry["resolved_sha256"]):
                    errors.append(f"lane {lane!r}: {name} carrieth a distribution "
                                  f"whose bytes are not pip's resolved digest")
        for name, version in spec["packages"].items():
            entry = by_name.get(name)
            if entry is None:
                errors.append(f"lane {lane!r} wanteth {name}=={version} in its closure")
                continue
            if entry.get("version") != version:
                errors.append(f"lane {lane!r}: {name} is pinned to "
                              f"{entry.get('version')} in the manifest and to "
                              f"{version} in {spec['source']}")
            if entry.get("origin") != "pinned":
                errors.append(f"lane {lane!r}: {name} is pinned by {spec['source']} "
                              f"and the closure calleth it {entry.get('origin')!r}")
    if document.get("status") == "PINNED":
        weak = [f"{lane}/{entry.get('name')}" for lane, spec in lanes.items()
                for entry in (spec.get("closure") or [])
                if entry.get("status") != "PINNED"]
        if weak:
            errors.append(f"the manifest claimeth PINNED while {sorted(weak)} stand "
                          f"UNPINNED")
        if document.get("unresolved"):
            errors.append("the manifest claimeth PINNED while carrying unresolved items: "
                          "an unresolved item is a pin that could not be sworn")
        for item in document.get("caveats") or []:
            if not isinstance(item, str) or not item.strip():
                errors.append("a caveat must be a non-empty string")
    if lock_text is not None:
        for lane, spec in lanes.items():
            for entry in spec.get("closure") or []:
                for item in entry.get("distributions") or []:
                    if f"sha256:{item['sha256']}" not in lock_text:
                        errors.append(f"the rendered requirements.lock carrieth no "
                                      f"hash for {entry.get('name')} ({item['file']})")
    return errors


# ---------------------------------------------------------------------------
# The offline cache and its restoration
# ---------------------------------------------------------------------------
def build_cache_manifest(wheelhouse: Path, *, repo: Path = ROOT,
                         clock: Callable[[], str] | None = None) -> dict[str, Any]:
    wheelhouse = Path(wheelhouse)
    _require(wheelhouse.is_dir(), f"the cache directory is missing: {wheelhouse}")
    blobs = []
    for path in sorted(wheelhouse.iterdir()):
        if not path.is_file():
            continue
        _require(not path.is_symlink(),
                 f"the cache carrieth a symlink, {path.name}; a link is not bytes")
        blobs.append({"name": path.name, "bytes": path.stat().st_size,
                      "sha256": sha256_file(path)})
    _require(blobs, f"the cache directory carrieth no blob: {wheelhouse}")
    return {"schema": SCHEMA, "built_utc": (clock or _clock_default)(),
            "status": "PINNED", "blobs": blobs,
            "restore": {
                "command": "python3 tools/supplychain/supply_chain.py restore "
                           "--lane <lane> --wheelhouse <cache> --venv <dir>",
                "network": "refused: the restore passeth --no-index to pip, so a "
                           "dependency that is not in this cache cannot be fetched",
                "law": "every blob's digest is verified before any file is written, "
                       "so a cache whose bytes changed restoreth nothing",
            },
            "unresolved": [
                "the Gradle module cache is provisioned by the machine (419 MB under "
                "~/.gradle/caches/modules-2) and is not manifested here: a gradle "
                "--offline build on this host cannot resolve "
                "com.android.application:8.6.0 from it, which was measured and "
                "recorded rather than papered over",
            ]}


def verify_cache_manifest(document: Any, *, source_dir: Path | None = None) -> list[str]:
    errors: list[str] = []
    if not isinstance(document, Mapping):
        return ["the cache manifest must be an object"]
    if type(document.get("schema")) is not int or document.get("schema") != SCHEMA:
        errors.append(f"the cache manifest schema must be {SCHEMA}")
    blobs = document.get("blobs")
    if not isinstance(blobs, list) or not blobs:
        return errors + ["the cache manifest carrieth no blobs"]
    seen = set()
    for entry in blobs:
        if not isinstance(entry, Mapping):
            errors.append("every blob must be an object")
            continue
        name = str(entry.get("name"))
        if name in seen:
            errors.append(f"blob {name!r} is manifested twice")
        seen.add(name)
        if not isinstance(entry.get("sha256"), str) or not SHA256_RE.fullmatch(
                str(entry.get("sha256"))):
            errors.append(f"blob {name!r} carrieth no lower-case SHA-256")
        if type(entry.get("bytes")) is not int or entry["bytes"] <= 0:
            errors.append(f"blob {name!r} carrieth a non-positive byte count")
    if not isinstance(document.get("restore"), Mapping):
        errors.append("the cache manifest carrieth no restoration law")
    if source_dir is not None:
        source_dir = Path(source_dir)
        for entry in blobs:
            path = source_dir / str(entry.get("name"))
            if not path.is_file():
                errors.append(f"the cache is missing the blob {entry.get('name')!r}")
            elif (sha256_file(path) != entry.get("sha256")
                  or path.stat().st_size != entry.get("bytes")):
                errors.append(f"the cache blob {entry.get('name')!r} is not the blob "
                              f"the manifest sweareth")
    return errors


def plan_restore(document: Mapping[str, Any], source_dir: Path) -> list[dict[str, Any]]:
    """Verify every blob before a single write. Returns the ordered plan."""
    errors = verify_cache_manifest(document, source_dir=source_dir)
    _require(not errors, "the cache is not restorable:\n- " + "\n- ".join(errors))
    return [dict(entry) for entry in document["blobs"]]


def restore(document: Mapping[str, Any], source_dir: Path, dest_dir: Path, *,
            log_path: Path | None = None, clock: Callable[[], str] | None = None,
            lane: str | None = None) -> dict[str, Any]:
    """Restore the cache into dest_dir, verifying bytes at every step."""
    source_dir, dest_dir = Path(source_dir), Path(dest_dir)
    plan = plan_restore(document, source_dir)
    # GS-SUPPLY-001: a restore NAME must be a plain file name. The audit reproduced a manifest
    # naming `../escape.whl` writing OUTSIDE the requested destination
    # ({"rejected": false, "wrote_outside_destination": true}), and a SOURCE SYMLINK being
    # followed into a file that is not the cache blob at all. Both are refused BEFORE a byte is
    # written, by name.
    dest_root = dest_dir.resolve()
    for entry in plan:
        name = entry["name"]
        candidate = Path(name)
        if candidate.is_absolute() or candidate.name != name or name in (".", "..") \
                or ".." in candidate.parts:
            raise SupplyChainError(
                f"restore name {name!r} is not a plain file name: a traversal name may not "
                f"write outside the destination (GS-SUPPLY-001)")
    dest_dir.mkdir(parents=True, exist_ok=True)
    for entry in plan:
        source = source_dir / entry["name"]
        if source.is_symlink():
            raise SupplyChainError(
                f"the cache source {entry['name']!r} is a SYMLINK: a blob must be a real file "
                f"in the cache, never a link to somewhere else (GS-SUPPLY-001)")
        if source.exists() and source.resolve().parent != source_dir.resolve():
            raise SupplyChainError(
                f"the cache source {entry['name']!r} resolveth outside the cache directory "
                f"(GS-SUPPLY-001)")
        target = (dest_dir / entry["name"]).resolve()
        if dest_root not in target.parents and target != dest_root:
            raise SupplyChainError(
                f"the restore target for {entry['name']!r} resolveth outside the destination "
                f"(GS-SUPPLY-001)")
    lines = [f"restore lane={lane or 'all'} at {(clock or _clock_default)()}",
             f"source {source_dir} -> destination {dest_dir}",
             f"{len(plan)} blob(s) verified before any write"]
    restored = []
    for entry in plan:
        source = source_dir / entry["name"]
        target = dest_dir / entry["name"]
        candidate = target.with_name("." + target.name + ".restoring")
        shutil.copyfile(source, candidate)
        _require(sha256_file(candidate) == entry["sha256"],
                 f"the restored copy of {entry['name']} is not the blob the manifest "
                 f"sweareth")
        os.replace(candidate, target)
        restored.append({"name": entry["name"], "sha256": entry["sha256"],
                         "bytes": entry["bytes"]})
        lines.append(f"restored {entry['name']} sha256={entry['sha256']} "
                     f"bytes={entry['bytes']}")
    document_out = {"schema": SCHEMA, "lane": lane, "blobs": restored,
                    "source": str(source_dir), "destination": str(dest_dir),
                    "at_utc": (clock or _clock_default)()}
    log = "\n".join(lines) + "\n"
    leaked = no_secret_in_log(log)
    _require(not leaked, f"the restoration log would carry {leaked}; refusing to write it")
    if log_path is not None:
        Path(log_path).parent.mkdir(parents=True, exist_ok=True)
        Path(log_path).write_text(log, encoding="utf-8")
    return document_out


def no_secret_in_log(text: str) -> list[str]:
    """The scanner the logs pass through. Returns what it found, not a verdict."""
    return [why for pattern, why in SECRET_PATTERNS if pattern.search(text or "")]


def install_lane(lock: Mapping[str, Any], lane: str, wheelhouse: Path, venv: Path, *,
                 python: str = sys.executable, log_path: Path | None = None,
                 timeout: int = 900) -> dict[str, Any]:
    """Restore one lane into a fresh venv, offline and hash-required.

    This is the proof the card asketh for: pip is passed --no-index, so nothing
    can be fetched, and --require-hashes, so nothing whose bytes disagree with
    the lock can be installed."""
    lane = str(lane)
    spec = (lock.get("lanes") or {}).get(lane)
    _require(isinstance(spec, Mapping), f"the lock carrieth no lane {lane!r}")
    wheelhouse, venv = Path(wheelhouse), Path(venv)
    requirements = []
    for entry in spec.get("closure") or []:
        name = str(entry.get("name"))
        _require(entry.get("status") == "PINNED" and entry.get("distributions"),
                 f"lane {lane!r}: {name} is UNPINNED, so this lane cannot be restored "
                 f"offline and no success may be claimed for it")
        for item in entry["distributions"]:
            blob = wheelhouse / item["file"]
            _require(blob.is_file(),
                     f"the cache is missing {item['file']} for {name}=={entry['version']}")
            _require(sha256_file(blob) == item["sha256"],
                     f"the cached {item['file']} is not the distribution the lock "
                     f"sweareth")
        requirements.append(f"{name}=={entry['version']} " + " ".join(
            f"--hash=sha256:{i['sha256']}" for i in entry["distributions"]))
    _require(requirements, f"lane {lane!r} carrieth an empty closure")
    with tempfile.TemporaryDirectory(prefix=".supplychain-lane-") as work:
        req = Path(work) / "requirements.txt"
        req.write_text("\n".join(requirements) + "\n", encoding="utf-8")
        subprocess.run([python, "-m", "venv", str(venv)], check=True,
                       capture_output=True, timeout=timeout)
        pip = venv / "bin" / "pip"
        _require(pip.is_file(), f"the venv carrieth no pip at {pip}")
        result = subprocess.run(
            [str(pip), "install", "--no-index", "--require-hashes",
             "--find-links", str(wheelhouse), "--disable-pip-version-check",
             "-r", str(req)],
            capture_output=True, text=True, timeout=timeout)
    blob = (result.stdout or "") + (result.stderr or "")
    leaked = no_secret_in_log(blob)
    _require(not leaked, f"the install log would carry {leaked}")
    if log_path is not None:
        Path(log_path).parent.mkdir(parents=True, exist_ok=True)
        Path(log_path).write_text(blob, encoding="utf-8")
    _require(result.returncode == 0,
             f"the offline restoration of lane {lane!r} failed (rc={result.returncode}): "
             f"{_first_line(blob.splitlines()[-1] if blob.splitlines() else '')}")
    installed = sorted((p.name.split("-")[0].replace("_", "-"), )
                       for p in (venv / "lib").glob("python*/site-packages/*.dist-info"))
    packages = sorted({name for (name,) in installed})
    return {"lane": lane, "offline": True, "require_hashes": True,
            "packages": packages, "rc": result.returncode,
            "venv": str(venv), "wheelhouse": str(wheelhouse),
            "log_sha256": sha256_bytes(blob.encode("utf-8"))}


# ---------------------------------------------------------------------------
# Gradle's own dependency verification
# ---------------------------------------------------------------------------
def parse_gradle_metadata(path: Path) -> dict[str, Any]:
    path = Path(path)
    if not path.is_file():
        return {"path": str(path), "present": False, "components": [],
                "unresolved": ["Gradle dependency verification metadata is absent: "
                               "the dependency graph is not verified"]}
    root = ET.parse(path).getroot()
    # The document carrieth a namespace, so tags are matched by their local
    # part: an exact-tag search findeth nothing at all, and an empty component
    # list would acquit an unverified graph by silence.
    def local(element: Any, name: str) -> bool:
        return str(element.tag).rpartition("}")[2] == name

    def children(element: Any, name: str) -> list[Any]:
        return [child for child in list(element) if local(child, name)]

    components = []
    for component in [node for node in root.iter() if local(node, "component")]:
        artifacts: list[str] = []
        digests: list[dict[str, str]] = []
        for artifact in children(component, "artifact"):
            artifacts.append(artifact.get("name") or "")
            for kind in ("sha256", "sha1", "md5"):
                for node in children(artifact, kind):
                    value = (node.get("value") or "").strip()
                    if value:
                        digests.append({"algorithm": kind, "value": value,
                                        "artifact": artifact.get("name") or ""})
        components.append({"group": component.get("group") or "",
                           "name": component.get("name") or "",
                           "version": component.get("version") or "",
                           "artifacts": sorted(a for a in artifacts if a),
                           "digests": digests})
    signature_policy = False
    for node in root.iter():
        if local(node, "verify-signatures"):
            signature_policy = (node.text or "").strip().lower() == "true"
    return {"path": str(path), "present": True, "components": components,
            "verify_signatures": signature_policy,
            "trusted_keys": [k.get("id") for k in root.iter("trusted-key")],
            "unresolved": ([] if signature_policy else
                           ["signature verification is off in this metadata: the "
                            "dependency graph is verified by checksum alone, and PGP "
                            "verification awaiteth keyring provisioning"])}


def verify_gradle_metadata(document: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(document, Mapping):
        return ["the dependency verification manifest must be an object"]
    if not document.get("present"):
        return ["Gradle dependency verification metadata is absent, so the "
                "dependency graph is not verified"]
    components = document.get("components")
    if not isinstance(components, list) or not components:
        return ["the verification metadata carrieth no component"]
    seen = set()
    for entry in components:
        if not isinstance(entry, Mapping):
            errors.append("every component must be an object")
            continue
        key = f"{entry.get('group')}:{entry.get('name')}:{entry.get('version')}"
        if key in seen:
            errors.append(f"component {key} is verified twice")
        seen.add(key)
        digests = entry.get("digests") or []
        strong = [d for d in digests if d.get("algorithm") == "sha256"]
        if not strong:
            weak = sorted({d.get("algorithm") for d in digests})
            errors.append(f"component {key} carrieth no SHA-256"
                          + (f" (only {weak})" if weak else " at all"))
            continue
        for item in strong:
            if not SHA256_RE.fullmatch(str(item.get("value"))):
                errors.append(f"component {key} carrieth a malformed SHA-256: "
                              f"{item.get('value')!r}")
    if document.get("verify_signatures") and not document.get("trusted_keys"):
        errors.append("the verification metadata asketh for signature verification "
                      "while carrying no trusted key")
    return errors


def verify_component(document: Mapping[str, Any], group: str, name: str, version: str,
                     artifact: Path) -> list[str]:
    """The named semantic negative: same version, different bytes."""
    artifact = Path(artifact)
    errors: list[str] = []
    _require(artifact.is_file(), f"the artifact is missing: {artifact}")
    actual = sha256_file(artifact)
    matching = [c for c in document.get("components") or []
                if c.get("group") == group and c.get("name") == name
                and c.get("version") == version]
    if not matching:
        return [f"{group}:{name}:{version} is not verified at all"]
    declared = {d["value"] for c in matching for d in c.get("digests") or []
                if d.get("algorithm") == "sha256"}
    if actual not in declared:
        errors.append(f"{group}:{name}:{version} carrieth bytes that no verified "
                      f"digest sweareth: {actual} is not among "
                      f"{sorted(declared)[:2]}; a same-version dependency with "
                      f"different bytes is refused")
    return errors


# ---------------------------------------------------------------------------
# The SBOM
# ---------------------------------------------------------------------------
def build_sbom(*, repo: Path = ROOT, wheelhouse: Path | None = None,
               clock: Callable[[], str] | None = None,
               toolchain: Mapping[str, Any] | None = None,
               lock: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """Every component the locks name, with its licence where one is known.

    The dependency half is read from the published manifest when one is given,
    so the inventory describeth the closure that was actually pinned rather
    than a second, weaker resolution computed here."""
    repo = Path(repo)
    wheelhouse = Path(wheelhouse) if wheelhouse is not None else None
    components: list[dict[str, Any]] = []
    unknown: list[str] = []

    if lock is None and wheelhouse is not None and Path(wheelhouse).is_dir():
        lock = build_lock(wheelhouse, repo=repo)
    if lock is not None:
        # A component belongeth to the inventory once. A distribution pinned by
        # three lanes is one component carried by three lanes, not three
        # components -- an inventory that counted it three times would inflate
        # its own licence census and hide which lane actually needeth it.
        pypi: dict[str, dict[str, Any]] = {}
        for lane, spec in sorted(lock["lanes"].items()):
            for entry in spec.get("closure") or []:
                name = str(entry.get("name"))
                version = str(entry.get("version"))
                digests = [d["sha256"] for d in entry.get("distributions") or []]
                slot = pypi.setdefault(f"{name}:{version}", {
                    "ecosystem": "pypi", "name": name, "version": version,
                    "lanes": [], "origin": entry.get("origin"),
                    "digest": None, "digest_status": entry["status"],
                    "license": "unknown", "license_source": "not carried by the pin",
                    "supplied_by": "docs/supplychain/DEPENDENCIES.json"})
                if lane not in slot["lanes"]:
                    slot["lanes"].append(lane)
                if slot["digest"] is None and digests:
                    slot["digest"] = digests[0]
                if entry["status"] == "UNPINNED":
                    slot["digest_status"] = "UNPINNED"
                    slot["reason"] = entry.get("reason")
                elif "reason" not in slot:
                    slot["digest_status"] = "PINNED"
        for key in sorted(pypi):
            slot = pypi[key]
            slot["lanes"] = sorted(slot["lanes"])
            components.append(slot)
            if slot["digest"] is None:
                unknown.append(f"pypi:{slot['name']}:{slot['version']} carrieth no "
                               f"digest")

    metadata = parse_gradle_metadata(repo / GRADLE_METADATA)
    for entry in metadata.get("components") or []:
        strong = [d["value"] for d in entry.get("digests") or []
                  if d.get("algorithm") == "sha256"]
        components.append({
            "ecosystem": "maven",
            "name": f"{entry.get('group')}:{entry.get('name')}",
            "version": entry.get("version"),
            "lane": "android", "digest": strong[0] if strong else None,
            "digest_status": "PINNED" if strong else "UNPINNED",
            "license": "unknown", "license_source": "not carried by the metadata",
            "supplied_by": GRADLE_METADATA,
        })
        if not strong:
            unknown.append(f"maven:{entry.get('group')}:{entry.get('name')} carrieth "
                           f"no SHA-256")

    models = load_document(repo / MODELS_LOCK)
    for artifact in models.get("artifacts") or []:
        components.append({
            "ecosystem": "model", "name": str(artifact.get("id")),
            "version": artifact.get("source_commit") or "UNPINNED",
            "lane": "models",
            "digest": artifact.get("sha256"),
            "digest_status": "PINNED" if artifact.get("sha256") else "UNPINNED",
            "license": artifact.get("license") or "unknown",
            "license_source": MODELS_LOCK
            if artifact.get("license") else "the register standeth UNPINNED",
            "supplied_by": MODELS_LOCK,
        })
        if not artifact.get("sha256"):
            unknown.append(f"model:{artifact.get('id')} standeth UNPINNED "
                           f"(external gate NATIVE_MODELS)")

    swift_text = (repo / SWIFT_MANIFEST).read_text(encoding="utf-8")
    for match in re.finditer(r'\.package\(\s*(?:url|path):\s*"([^"]+)"', swift_text):
        components.append({
            "ecosystem": "swift", "name": match.group(1), "version": "UNPINNED",
            "lane": "ios", "digest": None, "digest_status": "UNPINNED",
            "license": "unknown", "license_source": "no Package.resolved present",
            "supplied_by": SWIFT_MANIFEST,
        })
        unknown.append(f"swift:{match.group(1)} carrieth no resolution pin")

    document_tools = (toolchain or {}).get("tools") or []
    for entry in document_tools:
        components.append({
            "ecosystem": "toolchain", "name": str(entry.get("name")),
            "version": str(entry.get("measured") or "ABSENT"),
            "lane": "host", "digest": None,
            "digest_status": "PINNED" if entry.get("status") == "MEASURED"
            else "UNPINNED",
            "license": "n/a", "license_source": "the host toolchain is not distributed "
                                                "by this repository",
            "supplied_by": TOOLCHAIN_LOCK,
        })

    licenses: dict[str, int] = {}
    for entry in components:
        licenses[str(entry["license"])] = licenses.get(str(entry["license"]), 0) + 1
    unlicensed = [f"{c['ecosystem']}:{c['name']}:{c['version']}" for c in components
                  if str(c["license"]) == "unknown"]
    if unlicensed:
        unknown.append(f"{len(unlicensed)} component(s) carry an unknown licence; the "
                       f"inventory recordeth them by name rather than omitting them")
    return {"schema": SCHEMA, "built_utc": (clock or _clock_default)(),
            "components": components,
            "licence_census": licenses,
            "unknowns": unknown,
            "status": "PINNED" if not unknown else "UNPINNED",
            "note": ("An unknown licence is counted, never omitted: a component whose "
                     "licence nobody recorded is a fact about this inventory, not a "
                     "blank to be filled in later.")}


def verify_sbom(document: Any, *, lock: Mapping[str, Any] | None = None,
                gradle: Mapping[str, Any] | None = None,
                toolchain: Mapping[str, Any] | None = None) -> list[str]:
    errors: list[str] = []
    if not isinstance(document, Mapping):
        return ["the SBOM must be an object"]
    if type(document.get("schema")) is not int or document.get("schema") != SCHEMA:
        errors.append(f"the SBOM schema must be {SCHEMA}")
    components = document.get("components")
    if not isinstance(components, list) or not components:
        return errors + ["the SBOM carrieth no component"]
    names: dict[str, int] = {}
    for entry in components:
        if not isinstance(entry, Mapping):
            errors.append("every component must be an object")
            continue
        # The version is part of a component's identity: a build legitimately
        # carrieth two versions of one artifact (a BOM pulls an older copy for
        # one consumer), and calling those duplicates would hide a real fact.
        key = f"{entry.get('ecosystem')}:{entry.get('name')}:{entry.get('version')}"
        names[key] = names.get(key, 0) + 1
        if "license" not in entry:
            errors.append(f"component {key} carrieth no licence field at all; an "
                          f"unknown licence must be recorded as unknown, not omitted")
        if entry.get("digest_status") not in STATUSES:
            errors.append(f"component {key} carrieth digest_status "
                          f"{entry.get('digest_status')!r}")
        if entry.get("digest") is not None and not SHA256_RE.fullmatch(
                str(entry.get("digest"))):
            errors.append(f"component {key} carrieth a malformed digest")
    for key, count in names.items():
        if count > 1:
            errors.append(f"component {key} is listed {count} times")
    census = document.get("licence_census") or {}
    counted = sum(int(v) for v in census.values())
    if counted != len(components):
        errors.append(f"the licence census counteth {counted} component(s) and the "
                      f"inventory carrieth {len(components)}")
    if lock is not None:
        for lane, spec in (lock.get("lanes") or {}).items():
            for entry in spec.get("closure") or []:
                name = entry.get("name")
                if not any(key.startswith(f"pypi:{name}:") for key in names):
                    errors.append(f"the dependency lock nameth pypi:{name} and the "
                                  f"SBOM carrieth it not")
    if gradle is not None and gradle.get("present"):
        for entry in gradle.get("components") or []:
            key = (f"maven:{entry.get('group')}:{entry.get('name')}:"
                   f"{entry.get('version')}")
            if key not in names:
                errors.append(f"the Gradle verification nameth {key} and the SBOM "
                              f"carrieth it not")
    if toolchain is not None:
        for entry in toolchain.get("tools") or []:
            if not any(key.startswith(f"toolchain:{entry.get('name')}:")
                       for key in names):
                errors.append(f"the toolchain lock nameth {entry.get('name')} and the "
                              f"SBOM carrieth it not")
    return errors


# ---------------------------------------------------------------------------
# The nondeterminism record
# ---------------------------------------------------------------------------
def compare_outputs(previous: Path, current: Path, names: Sequence[str], *,
                    causes: Mapping[str, str] | None = None,
                    clock: Callable[[], str] | None = None) -> dict[str, Any]:
    """Two runs of the same clean build, compared by content."""
    previous, current = Path(previous), Path(current)
    causes = dict(causes or {})
    comparisons = []
    for name in names:
        left, right = previous / name, current / name
        entry: dict[str, Any] = {"name": name}
        if not left.is_file() or not right.is_file():
            entry.update({"identical": False, "status": "INCOMPARABLE",
                          "reason": "the output is missing from one of the runs: "
                                    + ", ".join(p.name for p in
                                                (left, right) if not p.is_file())})
            comparisons.append(entry)
            continue
        left_digest, right_digest = sha256_file(left), sha256_file(right)
        identical = left_digest == right_digest
        entry.update({"first": left_digest, "second": right_digest,
                      "identical": identical,
                      "status": "IDENTICAL" if identical else "DIVERGENT",
                      "reason": "" if identical else causes.get(
                          name, "no cause recorded: an unexplained divergence is a "
                                "defect, not a note")})
        comparisons.append(entry)
    divergent = [c for c in comparisons if c["status"] == "DIVERGENT"]
    incomparable = [c for c in comparisons if c["status"] == "INCOMPARABLE"]
    explained = [c for c in divergent if c["reason"] and not c["reason"].startswith(
        "no cause recorded")]
    status = ("COMPARABLE" if not divergent and not incomparable
              else "INCOMPARABLE" if incomparable and not divergent
              else "NONDETERMINISTIC" if divergent and len(explained) == len(divergent)
              else "UNEXPLAINED")
    return {"schema": SCHEMA, "at_utc": (clock or _clock_default)(),
            "status": status, "comparisons": comparisons,
            "unexplained": [c["name"] for c in divergent
                            if c not in explained],
            "note": ("An unsigned binary is rarely byte-identical across runs: zip "
                     "entry timestamps, build metadata and debug paths all move. Every "
                     "divergence here carrieth its cause or is counted unexplained; no "
                     "divergence is ever averaged into a pass.")}


def verify_determinism(document: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(document, Mapping):
        return ["the nondeterminism record must be an object"]
    if type(document.get("schema")) is not int or document.get("schema") != SCHEMA:
        errors.append(f"the nondeterminism record schema must be {SCHEMA}")
    comparisons = document.get("comparisons")
    if not isinstance(comparisons, list) or not comparisons:
        return errors + ["the record carrieth no comparison"]
    for entry in comparisons:
        if not isinstance(entry, Mapping):
            errors.append("every comparison must be an object")
            continue
        name = entry.get("name")
        if entry.get("status") not in ("IDENTICAL", "DIVERGENT", "INCOMPARABLE"):
            errors.append(f"comparison {name!r} carrieth status "
                          f"{entry.get('status')!r}")
        if entry.get("status") == "DIVERGENT":
            reason = str(entry.get("reason") or "")
            if not reason or reason.startswith("no cause recorded"):
                errors.append(f"comparison {name!r} diverged and carrieth no cause: an "
                              f"unexplained divergence is a defect")
            # A divergence that carrieth its measured cause is a FINDING, not a
            # refusal: it is reported, and refusing it would only teach the next
            # hand to stop recording divergences at all.
        if entry.get("status") == "INCOMPARABLE":
            errors.append(f"comparison {name!r} could not be made: "
                          f"{entry.get('reason')}")
        for side in ("first", "second"):
            value = entry.get(side)
            if value is not None and not SHA256_RE.fullmatch(str(value)):
                errors.append(f"comparison {name!r}: {side} is not a lower-case "
                              f"SHA-256")
    if document.get("status") == "COMPARABLE" and any(
            c.get("status") != "IDENTICAL" for c in comparisons
            if isinstance(c, Mapping)):
        errors.append("the record claimeth COMPARABLE while carrying a non-identical "
                      "comparison")
    for name in document.get("unexplained") or []:
        errors.append(f"comparison {name!r} is recorded unexplained")
    return errors


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _verify_all(repo: Path, *, toolchain_path: Path, lock_path: Path,
                cache_path: Path, sbom_path: Path, determinism_path: Path,
                wheelhouse: Path | None) -> int:
    problems: list[str] = []
    toolchain = None
    lock = None
    gradle = parse_gradle_metadata(Path(repo) / GRADLE_METADATA)
    for path, verifier, label in (
            (toolchain_path, lambda d: verify_toolchain(d, repo), "toolchain lock"),
            (lock_path, lambda d: verify_lock(d, repo=repo), "dependency manifest"),
            (cache_path, lambda d: verify_cache_manifest(
                d, source_dir=wheelhouse), "offline cache manifest"),
            (determinism_path, verify_determinism, "nondeterminism record")):
        if not Path(path).is_file():
            problems.append(f"the {label} is missing: {path}")
            continue
        document = load_document(path)
        if label == "toolchain lock":
            toolchain = document
        if label == "dependency manifest":
            lock = document
        problems.extend(f"{label}: {item}" for item in verifier(document))
        if label == "toolchain lock":
            for item in document.get("unresolved") or []:
                print(f"::warning::{label}: {item}")
            for item in document.get("unpinned") or []:
                print(f"::warning::{label}: {item}")
    problems.extend(f"gradle verification: {item}" for item in
                    verify_gradle_metadata(gradle))
    if Path(sbom_path).is_file():
        problems.extend(f"SBOM: {item}" for item in verify_sbom(
            load_document(sbom_path), lock=lock, gradle=gradle, toolchain=toolchain))
    else:
        problems.append(f"the SBOM is missing: {sbom_path}")
    if determinism_path.is_file():
        for entry in (load_document(determinism_path).get("comparisons") or []):
            if entry.get("status") == "DIVERGENT" and str(entry.get("reason")).strip():
                print(f"::warning::nondeterminism record: {entry.get('name')} diverged "
                      f"between the two runs: {entry.get('reason')}")
    for line in problems:
        print(f"::error::{line}")
    if problems:
        print(f"{len(problems)} refusal(s)")
        return 1
    print("the supply chain standeth pinned as far as this host alloweth: toolchain, "
          "dependency manifests, cache and SBOM agree")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Pin the build supply chain and prove offline restoration")
    sub = parser.add_subparsers(dest="command", required=True)

    capture = sub.add_parser("capture", help="measure the host into a ToolchainLock")
    capture.add_argument("--out", type=Path, default=Path(TOOLCHAIN_LOCK))
    capture.add_argument("--repo", type=Path, default=ROOT)

    lock = sub.add_parser("lock", help="build the hash-locked dependency manifest")
    lock.add_argument("--wheelhouse", type=Path, required=True)
    lock.add_argument("--manifest", type=Path, default=Path(DEPENDENCIES))
    lock.add_argument("--requirements", type=Path, default=Path(REQUIREMENTS_LOCK))
    lock.add_argument("--resolution", action="append", default=[],
                      metavar="LANE=PATH",
                      help="pip's own resolution report for a lane; without it the "
                           "lane's transitive closure is unknown and the lane cannot "
                           "be PINNED")

    cache = sub.add_parser("cache", help="manifest the offline cache")
    cache.add_argument("--wheelhouse", type=Path, required=True)
    cache.add_argument("--out", type=Path, default=Path(CACHE_MANIFEST))

    sbom = sub.add_parser("sbom", help="build the SBOM and licence inventory")
    sbom.add_argument("--wheelhouse", type=Path, default=None)
    sbom.add_argument("--manifest", type=Path, default=Path(DEPENDENCIES))
    sbom.add_argument("--toolchain", type=Path, default=Path(TOOLCHAIN_LOCK))
    sbom.add_argument("--out", type=Path, default=Path(SBOM))

    verify = sub.add_parser("verify", help="verify every supply-chain document")
    verify.add_argument("--all", action="store_true")
    verify.add_argument("--wheelhouse", type=Path, default=None)
    verify.add_argument("--toolchain", type=Path, default=Path(TOOLCHAIN_LOCK))
    verify.add_argument("--manifest", type=Path, default=Path(DEPENDENCIES))
    verify.add_argument("--cache", type=Path, default=Path(CACHE_MANIFEST))
    verify.add_argument("--sbom", type=Path, default=Path(SBOM))
    verify.add_argument("--determinism", type=Path, default=Path(NONDETERMINISM))

    restore_parser = sub.add_parser("restore", help="restore a cache, offline")
    restore_parser.add_argument("--cache", type=Path, default=Path(CACHE_MANIFEST))
    restore_parser.add_argument("--manifest", type=Path, default=Path(DEPENDENCIES))
    restore_parser.add_argument("--wheelhouse", type=Path, required=True)
    restore_parser.add_argument("--lane", default=None)
    restore_parser.add_argument("--venv", type=Path, default=None)
    restore_parser.add_argument("--log", type=Path, default=None)

    compare = sub.add_parser("compare", help="record two runs' outputs")
    compare.add_argument("--previous", type=Path, required=True)
    compare.add_argument("--current", type=Path, required=True)
    compare.add_argument("--name", action="append", required=True)
    compare.add_argument("--cause", action="append", default=[], metavar="NAME=REASON",
                         help="the measured cause of a divergence; a divergence with "
                              "no cause is recorded UNEXPLAINED and refused")
    compare.add_argument("--out", type=Path, default=Path(NONDETERMINISM))

    args = parser.parse_args(argv)
    try:
        if args.command == "capture":
            document = capture_toolchain(args.repo, out=args.out)
            print(f"toolchain captured: {document['status']}, "
                  f"{len(document['tools'])} tool(s), "
                  f"{len(document['unresolved'])} unresolved")
            return 0
        if args.command == "lock":
            resolutions: dict[str, Path] = {}
            for item in args.resolution:
                _require("=" in item, f"--resolution wanteth LANE=PATH, got {item!r}")
                lane, _, path = item.partition("=")
                resolutions[lane] = Path(path)
            document = build_lock(args.wheelhouse, resolutions=resolutions)
            write_document(args.manifest, document)
            args.requirements.write_text(render_lock(document), encoding="utf-8")
            print(f"dependency manifest: {document['status']}, "
                  f"{len(document['unresolved'])} unresolved")
            return 0
        if args.command == "cache":
            document = build_cache_manifest(args.wheelhouse)
            write_document(args.out, document)
            print(f"cache manifested: {len(document['blobs'])} blob(s)")
            return 0
        if args.command == "sbom":
            toolchain = (load_document(args.toolchain)
                         if args.toolchain.is_file() else None)
            manifest = (load_document(args.manifest)
                        if args.manifest.is_file() else None)
            document = build_sbom(wheelhouse=args.wheelhouse, toolchain=toolchain,
                                  lock=manifest)
            write_document(args.out, document)
            print(f"SBOM: {len(document['components'])} component(s), "
                  f"{len(document['unknowns'])} unpinned or unlicensed")
            return 0
        if args.command == "verify":
            return _verify_all(ROOT, toolchain_path=args.toolchain,
                               lock_path=args.manifest, cache_path=args.cache,
                               sbom_path=args.sbom, determinism_path=args.determinism,
                               wheelhouse=args.wheelhouse)
        if args.command == "restore":
            manifest = load_document(args.manifest)
            cache_document = load_document(args.cache)
            if args.lane and args.venv:
                result = install_lane(manifest, args.lane, args.wheelhouse, args.venv,
                                      log_path=args.log)
                print(f"lane {args.lane} restored offline: "
                      f"{', '.join(result['packages'])}")
                return 0
            document = restore(cache_document, args.wheelhouse,
                               Path(args.venv or (args.wheelhouse.parent / "restored")),
                               log_path=args.log, lane=args.lane)
            print(f"restored {len(document['blobs'])} blob(s)")
            return 0
        if args.command == "compare":
            causes: dict[str, str] = {}
            for item in args.cause:
                _require("=" in item, f"--cause wanteth NAME=REASON, got {item!r}")
                name, _, reason = item.partition("=")
                causes[name] = reason
            document = compare_outputs(args.previous, args.current, args.name,
                                       causes=causes)
            write_document(args.out, document)
            print(f"comparison recorded: {document['status']}")
            return 0
    except SupplyChainError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
