#!/usr/bin/env python3
"""Audit an Android release artifact: ABI coverage, page size, R8, the Archive.

    python3 scripts/inspect_android_release.py android/app/build/outputs/apk/light/release/...apk \
        [--aab android/app/build/outputs/bundle/lightRelease/app-lightRelease.aab] \
        [--merged-manifest .../AndroidManifest.xml] [--mapping .../mapping.txt] \
        [--approved-manifest APPROVED_ASSETS.json] [--release-candidate] [--out DIR]

WHY THIS IS NOT THE OTHER INSPECTOR
-----------------------------------
scripts/inspect_android_artifacts.py answereth "did the approved Archive reach
the package, and are the package's own bytes what they claim to be" -- T51/T52's
question, with nineteen presence faces that ci/check_content_release_integration.py
checks by name. This module answereth T70's question, which is different: does
the RELEASE package actually work as built -- every ABI covered, the bundled
native library compatible with 16 KiB pages, R8 keeping what reflection and JNI
reach for, the backup surface excluded, the merged manifest carrying no
forbidden permission, and the exact approved Archive inside. The sealed
inspector is therefore imported for the Archive's bytes and left untouched.

WHAT IT READS, AND HOW
----------------------
* APK and AAB are read as zip containers here (python's zipfile), with traversal,
  symlink and world-writable entries refused.
* ELF program headers are parsed in Python, because the 16 KiB page-size question
  is answered by each PT_LOAD segment's p_align and by nothing else. A library
  whose segments are 4 KiB-aligned cannot be loaded on a 16 KiB-page device.
* The merged manifest is the build's own plain-XML merge output, not a binary
  AXML guess: it is what the build tool actually produced.
* R8's keep rules are read from the module's proguard file, and every class they
  name is looked for in the dex by its descriptor -- a keep rule that kept
  nothing is a rule nobody needed, and a class R8 stripped while JNI still
  calleth it is the release-only failure this exists to catch.

The device claims -- installation and a real FTS5 query on a minAPI26 device and
on a current supported target -- are EXTERNAL and are recorded as UNVERIFIED.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import struct
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any, Iterable, Mapping

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts"))

ARCHIVE_NAME = "archive_light.db"
ARCHIVE_ASSET = f"assets/{ARCHIVE_NAME}"
REQUIRED_ABIS = ("arm64-v8a",)
FORBIDDEN_PERMISSIONS = (
    "android.permission.BLUETOOTH_ADVERTISE", "android.permission.BLUETOOTH_SCAN",
    "android.permission.BLUETOOTH_CONNECT", "android.permission.NEARBY_WIFI_DEVICES",
    "android.permission.ACCESS_FINE_LOCATION", "android.permission.RECORD_AUDIO",
    "android.permission.INTERNET", "android.permission.ACCESS_NETWORK_STATE",
)
PAGE_SIZE_16K = 16384
SHA256_RE = re.compile(r"[0-9a-f]{64}")


class ReleaseArtifactError(RuntimeError):
    """A refusal. Every refusal precedeth any report being published."""


def _require(condition: Any, message: str) -> None:
    if not condition:
        raise ReleaseArtifactError(message)


def sha256_bytes(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False)
            + "\n").encode("utf-8")


def write_document(path: Path, document: Any) -> str:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    blob = canonical(document)
    handle = tempfile.NamedTemporaryFile(prefix=".androidaudit-", dir=path.parent,
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


# ---------------------------------------------------------------------------
# ELF: the 16 KiB page-size question is answered by p_align and nothing else
# ---------------------------------------------------------------------------
def elf_load_alignments(blob: bytes) -> list[int]:
    """The p_align of every PT_LOAD segment of an ELF64/ELF32 little-endian file."""
    _require(len(blob) >= 64, "the ELF is too short to carry a header")
    _require(blob[:4] == b"\x7fELF", "the file is not an ELF image")
    bits = blob[4]
    _require(bits in (1, 2), f"an unknown ELF class: {bits}")
    _require(blob[5] == 1, "only little-endian ELF images are expected")
    if bits == 2:
        e_phoff, = struct.unpack_from("<Q", blob, 0x20)
        e_phentsize, e_phnum = struct.unpack_from("<HH", blob, 0x36)
        base, entry = 0x38, 56
    else:
        e_phoff, = struct.unpack_from("<I", blob, 0x1C)
        e_phentsize, e_phnum = struct.unpack_from("<HH", blob, 0x2A)
        base, entry = 0x2C, 32
    _require(0 < e_phnum <= 128, f"implausible program-header count: {e_phnum}")
    _require(e_phoff + e_phnum * e_phentsize <= len(blob),
             "the program headers reach past the end of the file")
    alignments: list[int] = []
    for index in range(e_phnum):
        offset = e_phoff + index * e_phentsize
        p_type, = struct.unpack_from("<I", blob, offset)
        if p_type != 1:                      # PT_LOAD
            continue
        if bits == 2:
            p_align, = struct.unpack_from("<Q", blob, offset + 48)
        else:
            p_align, = struct.unpack_from("<I", blob, offset + 28)
        alignments.append(p_align)
    _require(alignments, "the ELF carrieth no PT_LOAD segment")
    return alignments


def page_size_face(alignment: int) -> str:
    return "16KiB-compatible" if alignment >= PAGE_SIZE_16K else (
        f"4KiB-only (p_align={alignment})")


# ---------------------------------------------------------------------------
# Containers
# ---------------------------------------------------------------------------
def _container_entries(archive: zipfile.ZipFile, origin: str) -> list[zipfile.ZipInfo]:
    entries = archive.infolist()
    for entry in entries:
        name = entry.filename
        if name.startswith("/") or ".." in Path(name).parts:
            raise ReleaseArtifactError(f"{origin} carrieth a traversal entry: {name}")
        mode = entry.external_attr >> 16
        if mode and (mode & 0o170000) == 0o120000:
            raise ReleaseArtifactError(f"{origin} carrieth a symlink entry: {name}")
        if mode and (mode & 0o002):
            raise ReleaseArtifactError(f"{origin} carrieth a world-writable entry: "
                                       f"{name}")
    return entries


def abi_face(entries: Iterable[zipfile.ZipInfo], *, prefix: str) -> dict[str, Any]:
    """Which ABIs the container carrieth, and which native libraries in each."""
    by_abi: dict[str, list[str]] = {}
    for entry in entries:
        match = re.match(rf"{prefix}([^/]+)/(.+\.so)$", entry.filename)
        if match:
            by_abi.setdefault(match.group(1), []).append(match.group(2))
    for abi in by_abi:
        by_abi[abi] = sorted(set(by_abi[abi]))
    return by_abi


def dex_face(entries: Iterable[zipfile.ZipInfo]) -> list[str]:
    return sorted(entry.filename for entry in entries
                  if re.fullmatch(r"classes\d*\.dex", entry.filename))


def signature_face(entries: Iterable[zipfile.ZipInfo]) -> dict[str, Any]:
    names = [entry.filename for entry in entries]
    v1 = sorted(name for name in names if name.upper().startswith("META-INF/")
                and name.upper().endswith((".RSA", ".DSA", ".EC")))
    v2_files = sorted(name for name in names
                      if re.fullmatch(r"META-INF/[^/]+\.(SF|MF)", name, re.I))
    return {"signed": bool(v1), "v1_blocks": v1, "manifests": v2_files,
            "note": ("an unsigned release build is reported as unsigned rather than "
                     "as a failure: signing is external until credentials exist")}


# ---------------------------------------------------------------------------
# The merged manifest and R8
# ---------------------------------------------------------------------------
def manifest_face(path: Path | None) -> dict[str, Any]:
    if path is None or not Path(path).is_file():
        return {"present": False, "path": None,
                "failures": ["the merged release manifest is absent: the permissions "
                             "and backup surface cannot be judged"]}
    import xml.etree.ElementTree as ET
    text = Path(path).read_text(encoding="utf-8", errors="replace")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as exc:
        return {"present": True, "path": str(path),
                "failures": [f"the merged manifest is not parseable XML: {exc}"]}
    ns = "{http://schemas.android.com/apk/res/android}"
    permissions = sorted({node.get(f"{ns}name", "") for node in root.iter("uses-permission")
                          if node.get(f"{ns}name")})
    application = next((node for node in root.iter("application")), None)
    attributes = {} if application is None else {
        key.rpartition("}")[2]: value for key, value in application.attrib.items()}
    debuggable = str(attributes.get("debuggable", "false")).lower() == "true"
    failures: list[str] = []
    for permission in permissions:
        if permission in FORBIDDEN_PERMISSIONS:
            failures.append(f"the release manifest requesteth the disabled permission "
                            f"{permission}")
    if debuggable:
        failures.append("the release manifest setteth android:debuggable=true")
    allow_backup = str(attributes.get("allowBackup", "true")).lower()
    if allow_backup != "false":
        failures.append(f"android:allowBackup readeth {allow_backup!r}: the backup "
                        f"surface is not excluded, and an Archive-only release "
                        f"shipeth no user data to be backed up")
    return {"present": True, "path": str(path), "permissions": permissions,
            "application": attributes, "debuggable": debuggable,
            "allow_backup": allow_backup,
            "extract_native_libs": attributes.get("extractNativeLibs"),
            "failures": failures}


def r8_face(rules_path: Path | None, mapping_path: Path | None,
            dex_blobs: Mapping[str, bytes], *, minify_declared: bool,
            shipped_prefix: str = "io.godstone.app",
            excluded_prefixes: Iterable[str] = ("io.godstone.llm",
                                                "io.godstone.mesh")) -> dict[str, Any]:
    """Judge R8 by what its keep rules reach IN THIS BUILD.

    A rule naming an excluded module is not a defect: the LIGHT release carrieth
    no :llm and no :mesh dependency on purpose, so those rules stand inert and
    are recorded as evidence that the exclusion is deliberate and known. A rule
    naming one of the APPLICATION's own classes that the dex carrieth not is the
    failure this face exists for -- R8 stripped, or renamed, something the build
    swore to keep. Wildcards and conditional forms are judged by prefix rather
    than demanded as literals."""
    failures: list[str] = []
    keep_rules: list[str] = []
    if rules_path is not None and Path(rules_path).is_file():
        for line in Path(rules_path).read_text(encoding="utf-8").splitlines():
            stripped = line.split("#", 1)[0].strip()
            if stripped.startswith("-keep") or stripped.startswith("-if"):
                keep_rules.append(stripped)
    if not minify_declared:
        failures.append("the release configuration doth not declare minifyEnabled: "
                        "R8 is not shrinking the release build at all")
    if not keep_rules:
        failures.append("no -keep rule existeth for the release build: the JNI and "
                        "reflection surfaces would be stripped or renamed")
    mapping_present = mapping_path is not None and Path(mapping_path).is_file()
    if minify_declared and not mapping_present:
        failures.append("minification is declared and no mapping.txt was produced: "
                        "the build did not actually shrink, or its map was lost")
    dex = b"".join(dex_blobs.values())
    shipped_missing: list[str] = []
    excluded_rules: list[str] = []
    absent_library: list[str] = []
    spec_re = re.compile(r"-keep\w*\s+(?:class|interface|enum)\s+([^\s{]+)")
    extends_re = re.compile(r"(?:extends|implements)\s+([A-Za-z_][\w.$]*)")
    for rule in keep_rules:
        specs = spec_re.findall(rule) + extends_re.findall(rule)
        for spec in specs:
            if spec.startswith("*"):
                # "class *" and "class * extends X": the wildcard carrieth no
                # name of its own, and the superclass (when one is named) is
                # judged as the library class it is
                continue
            package = spec.rstrip("*").rstrip(".")
            if any(package == prefix or package.startswith(prefix + ".")
                   for prefix in excluded_prefixes):
                if rule not in excluded_rules:
                    excluded_rules.append(rule)
                continue
            prefix = "L" + package.replace(".", "/")
            if "*" in spec:
                if prefix.encode() not in dex:
                    absent_library.append(spec)
                continue
            if (prefix + ";").encode() in dex:
                continue
            if package == shipped_prefix or package.startswith(shipped_prefix + "."):
                shipped_missing.append(spec)
            else:
                absent_library.append(spec)
    if shipped_missing:
        failures.append("the keep rules name classes of THIS application that the "
                        f"dex carrieth not: {sorted(set(shipped_missing))[:4]}")
    return {"minify_declared": minify_declared,
            "keep_rules": keep_rules, "mapping_present": mapping_present,
            "mapping_sha256": sha256_file(mapping_path) if mapping_present else None,
            "dex_files": sorted(dex_blobs),
            "application_targets_missing_from_dex": sorted(set(shipped_missing)),
            "excluded_module_rules": excluded_rules,
            "absent_library_targets": sorted(set(absent_library)),
            "note": ("rules naming an excluded module are recorded rather than "
                     "refused: the LIGHT release carrieth no :llm and no :mesh "
                     "dependency, so those rules stand inert by design, and their "
                     "presence is evidence that the exclusion was deliberate"),
            "failures": failures}


def classpath_face(dependencies_text: str | None) -> dict[str, Any]:
    if not dependencies_text:
        return {"present": False,
                "failures": ["the release runtime classpath was not captured"]}
    coordinates = sorted(set(re.findall(r"([\w.\-]+:[\w.\-]+:[\w.\-]+)",
                                        dependencies_text)))
    forbidden = sorted({coordinate for coordinate in coordinates
                        if re.search(r":(llm|mesh)[:]", coordinate)
                        or coordinate.startswith("io.godstone.llm")
                        or coordinate.startswith("io.godstone.mesh")})
    failures = [f"the release runtime classpath carrieth the excluded module "
                f"{coordinate}" for coordinate in forbidden]
    return {"present": True, "count": len(coordinates),
            "digest": sha256_bytes(dependencies_text.encode("utf-8")),
            "coordinates": coordinates, "forbidden": forbidden,
            "failures": failures}


# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------
def inspect(apk: Path, *, aab: Path | None = None,
            merged_manifest: Path | None = None, mapping: Path | None = None,
            rules: Path | None = None, dependencies_text: str | None = None,
            approved_manifest: Path | None = None,
            expected_archive: Path | None = None,
            release_candidate: bool = False) -> dict[str, Any]:
    apk = Path(apk)
    _require(apk.is_file(), f"the APK is missing: {apk}")
    _require(zipfile.is_zipfile(apk), f"the APK is not a zip container: {apk}")
    failures: list[str] = []
    warnings: list[str] = []
    with zipfile.ZipFile(apk) as container:
        entries = _container_entries(container, "the APK")
        blobs = {entry.filename: container.read(entry.filename)
                 for entry in entries if not entry.is_dir()}
    abi = abi_face(entries, prefix="lib/")
    aab_abi = {}
    aab_digest = None
    if aab is not None:
        aab = Path(aab)
        _require(aab.is_file(), f"the AAB is missing: {aab}")
        aab_digest = sha256_file(aab)
        with zipfile.ZipFile(aab) as container:
            aab_entries = _container_entries(container, "the AAB")
            aab_abi = abi_face(aab_entries, prefix="base/lib/")

    # ---- ABI coverage: the card's named semantic negative -----------------
    for required in REQUIRED_ABIS:
        if required not in abi:
            failures.append(f"the APK carrieth no native library for the required ABI "
                            f"{required}")
    libs = sorted({name for names in abi.values() for name in names})
    for library in libs:
        missing = sorted(set(abi) - {name for name, names in abi.items()
                                     if library in names})
        for abi_name in missing:
            failures.append(f"the native library {library} is absent from ABI "
                            f"{abi_name}: half the devices would install and fail at "
                            f"first use")
    if aab is not None:
        for required in REQUIRED_ABIS:
            if required not in aab_abi:
                failures.append(f"the AAB carrieth no native library for the required "
                                f"ABI {required}")

    # ---- the page size, from the ELF headers themselves -------------------
    page: dict[str, Any] = {}
    for abi_name, names in sorted(abi.items()):
        for name in names:
            blob = blobs.get(f"lib/{abi_name}/{name}")
            if blob is None:
                continue
            alignments = elf_load_alignments(blob)
            worst = min(alignments)
            face = page_size_face(worst)
            page.setdefault(abi_name, {})[name] = {
                "alignments": alignments, "minimum": worst, "face": face}
            if worst < PAGE_SIZE_16K:
                failures.append(f"{abi_name}/{name} is not 16 KiB page compatible: "
                                f"its smallest PT_LOAD alignment is {worst}")

    # ---- the Archive ------------------------------------------------------
    approved = None
    if approved_manifest is not None:
        from inspect_android_artifacts import load_approved_manifest
        try:
            approved = load_approved_manifest(Path(approved_manifest))
        except (ValueError, OSError, KeyError) as exc:
            raise ReleaseArtifactError(f"the approved manifest is refused: {exc}") from exc
    expected_digest = None
    if approved is not None:
        expected_digest = approved["sha256"]
    elif expected_archive is not None:
        expected_digest = sha256_file(Path(expected_archive))
    archive_blob = blobs.get(ARCHIVE_ASSET)
    archive = {"expected_sha256": expected_digest, "asset": ARCHIVE_ASSET,
               "packaged_sha256": sha256_bytes(archive_blob)
               if archive_blob is not None else None,
               "bytes": len(archive_blob) if archive_blob is not None else None}
    if archive_blob is None:
        archive["status"] = "absent"
        if expected_digest is not None:
            failures.append("the expected Archive is absent from the package")
    elif expected_digest is None:
        archive["status"] = "present-unverified"
        warnings.append("an Archive is packaged and nothing approved its bytes")
    elif archive["packaged_sha256"] == expected_digest:
        archive["status"] = "byte-matched"
    else:
        archive["status"] = "byte-mismatch"
        failures.append("the packaged Archive is not the approved Archive: "
                        f"{archive['packaged_sha256']} != {expected_digest}")

    # ---- the other faces --------------------------------------------------
    manifest = manifest_face(merged_manifest)
    failures.extend(manifest.get("failures", []))
    dex_blobs = {name: blobs[name] for name in dex_face(entries) if name in blobs}
    rules_text = Path(rules).read_text(encoding="utf-8") if (
        rules is not None and Path(rules).is_file()) else ""
    r8 = r8_face(rules, mapping, dex_blobs,
                 minify_declared="isMinifyEnabled = true" in Path(
                     ROOT / "android/app/build.gradle.kts").read_text(encoding="utf-8")
                 if (ROOT / "android/app/build.gradle.kts").is_file() else False)
    failures.extend(r8.get("failures", []))
    classpath = classpath_face(dependencies_text)
    failures.extend(classpath.get("failures", []))
    signature = signature_face(entries)

    if failures:
        classification = "refused"
    elif archive["status"] == "byte-matched" and approved is not None:
        classification = "release-candidate-content"
    elif archive["status"] == "byte-matched":
        classification = "present-unverified"
    else:
        classification = "source-only-exclusion"
    if release_candidate and classification != "release-candidate-content":
        failures.append(f"this run claimeth a release candidate and the artifact is "
                        f"classified {classification!r}")
        classification = "refused"

    return {
        "schema": 1,
        "apk": {"path": str(apk), "sha256": sha256_file(apk),
                "bytes": apk.stat().st_size,
                "entries": sorted(entry.filename for entry in entries)},
        "AAB": None if aab is None else {"path": str(aab), "sha256": aab_digest,
                                         "abi": aab_abi},
        "classpaths": classpath,
        "manifest": manifest,
        "ABI": {"apk": abi, "required": list(REQUIRED_ABIS), "libraries": libs},
        "pageSize": page,
        "R8": r8,
        "signature": signature,
        "approvedArchive": archive,
        "approved_manifest": None if approved is None else {
            "tier": approved["tier"], "sha256": approved["sha256"]},
        "classification": classification,
        "device": {
            "installed_min_api26": "UNVERIFIED (external: no device in this lane)",
            "installed_current_target": "UNVERIFIED (external: no device in this lane)",
            "fts5_query": "UNVERIFIED (external: no device in this lane)",
            "offline_start": "UNVERIFIED (external: no device in this lane)",
            "note": ("installation on a minAPI26 device and on a current supported "
                     "target, the read-only FTS5 query in the shrunk app, and the "
                     "store's current target requirements at submission are external "
                     "evidence; this report carrieth none of it"),
        },
        "failures": failures,
        "warnings": warnings,
        "verdict": "FAIL" if failures else "PASS",
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _selftest() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as work:
        root = Path(work)
        apk = root / "fixture.apk"
        _write_synthetic_apk(apk, abis=("arm64-v8a",), page_size=PAGE_SIZE_16K)
        report = inspect(apk, merged_manifest=_write_manifest(root, allow_backup="false"),
                         rules=_write_rules(root), mapping=_write_mapping(root),
                         dependencies_text="+--- io.godstone:core:1.0\n")
        if report["verdict"] != "PASS":
            failures.append(f"a clean synthetic release failed: {report['failures']}")
        poisoned = root / "poisoned.apk"
        _write_synthetic_apk(poisoned, abis=(), page_size=PAGE_SIZE_16K)
        bad = inspect(poisoned, merged_manifest=_write_manifest(root, allow_backup="false"),
                      rules=_write_rules(root), mapping=_write_mapping(root),
                      dependencies_text="+--- io.godstone:core:1.0\n")
        if bad["verdict"] != "FAIL" or not any("required ABI" in item
                                               for item in bad["failures"]):
            failures.append("a package missing its ABI was not refused")
        small = root / "small.apk"
        _write_synthetic_apk(small, abis=("arm64-v8a",), page_size=4096)
        sized = inspect(small, merged_manifest=_write_manifest(root, allow_backup="false"),
                        rules=_write_rules(root), mapping=_write_mapping(root),
                        dependencies_text="+--- io.godstone:core:1.0\n")
        if not any("16 KiB page compatible" in item for item in sized["failures"]):
            failures.append("a 4 KiB-aligned library was not refused")
    for line in failures:
        print(f"::error::{line}")
    if failures:
        print(f"selftest FAILED ({len(failures)})")
        return 1
    print("selftest OK: the reader passed a clean release and refused both the missing "
          "ABI and the 4 KiB-aligned library")
    return 0


def _write_manifest(root: Path, *, allow_backup: str = "false",
                    permissions: Iterable[str] = ()) -> Path:
    path = Path(root)
    if path.suffix != ".xml":
        path = path / "AndroidManifest.xml"
    path.parent.mkdir(parents=True, exist_ok=True)
    entries = "".join(f'<uses-permission android:name="{name}"/>'
                      for name in permissions)
    path.write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
        'package="io.godstone.app">' + entries
        + f'<application android:allowBackup="{allow_backup}" '
          'android:label="Godstone"/></manifest>\n', encoding="utf-8")
    return path


def _write_rules(root: Path, class_name: str = "io.godstone.app.MainActivity") -> Path:
    path = root / "proguard-rules.pro"
    path.write_text(f"-keep class {class_name} {{ *; }}\n", encoding="utf-8")
    return path


def _write_mapping(root: Path) -> Path:
    path = root / "mapping.txt"
    path.write_text("io.godstone.app.MainActivity -> a.b:\n", encoding="utf-8")
    return path


def _synthetic_elf(page_size: int) -> bytes:
    """A minimal ELF64 with one PT_LOAD segment whose p_align is given."""
    header = bytearray(64)
    header[0:4] = b"\x7fELF"
    header[4] = 2
    header[5] = 1
    struct.pack_into("<H", header, 0x10, 3)          # ET_DYN
    struct.pack_into("<H", header, 0x12, 0xB7)       # EM_AARCH64
    struct.pack_into("<I", header, 0x14, 1)
    struct.pack_into("<Q", header, 0x20, 64)         # e_phoff
    struct.pack_into("<H", header, 0x36, 56)         # e_phentsize
    struct.pack_into("<H", header, 0x38, 1)          # e_phnum
    program = bytearray(56)
    struct.pack_into("<I", program, 0, 1)            # PT_LOAD
    struct.pack_into("<I", program, 4, 5)            # R+X
    struct.pack_into("<Q", program, 48, page_size)   # p_align
    return bytes(header) + bytes(program)


def _write_synthetic_apk(path: Path, *, abis: Iterable[str],
                         page_size: int) -> Path:
    with zipfile.ZipFile(path, "w") as container:
        container.writestr("classes.dex",
                           b"Lio/godstone/app/MainActivity;\x00" + b"\x00" * 32)
        container.writestr("AndroidManifest.xml", b"\x03\x00\x08\x00binary axml")
        container.writestr("resources.arsc", b"\x02\x00\x0c\x00")
        for abi in abis:
            container.writestr(f"lib/{abi}/libgodstone_sqlite.so",
                               _synthetic_elf(page_size))
            container.writestr(f"lib/{abi}/libgodstone_core.so",
                               _synthetic_elf(page_size))
    return path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Audit an Android release artifact")
    parser.add_argument("apk", nargs="?", type=Path)
    parser.add_argument("--aab", type=Path, default=None)
    parser.add_argument("--merged-manifest", type=Path, default=None)
    parser.add_argument("--mapping", type=Path, default=None)
    parser.add_argument("--rules", type=Path, default=None)
    parser.add_argument("--dependencies", type=Path, default=None)
    parser.add_argument("--approved-manifest", type=Path, default=None)
    parser.add_argument("--expected-archive", type=Path, default=None)
    parser.add_argument("--release-candidate", action="store_true")
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    if args.selftest:
        return _selftest()
    if args.apk is None:
        parser.error("an APK is required unless --selftest is asked")
    try:
        report = inspect(
            args.apk, aab=args.aab, merged_manifest=args.merged_manifest,
            mapping=args.mapping, rules=args.rules,
            dependencies_text=(args.dependencies.read_text(encoding="utf-8")
                               if args.dependencies and args.dependencies.is_file()
                               else None),
            approved_manifest=args.approved_manifest,
            expected_archive=args.expected_archive,
            release_candidate=args.release_candidate)
    except (ReleaseArtifactError, OSError, ValueError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    if args.out is not None:
        target = Path(args.out)
        target = (target / "android-release-report.json"
                  if target.is_dir() or target.suffix == "" else target)
        write_document(target, report)
    for item in report["failures"]:
        print(f"::error::{item}")
    for item in report["warnings"]:
        print(f"::warning::{item}")
    print(f"{report['verdict']}: {report['classification']} "
          f"(ABIs {sorted(report['ABI']['apk'])}, "
          f"{len(report['ABI']['libraries'])} native librar(y|ies), archive "
          f"{report['approvedArchive']['status']}, signed "
          f"{report['signature']['signed']})")
    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
