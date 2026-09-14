#!/usr/bin/env python3
"""Audit a real iOS release artifact: the iOS twin of inspect_android_artifacts.py.

    python3 scripts/inspect_ios_artifacts.py <Godstone.app|Godstone.ipa> \
        [--approved-manifest APPROVED_ASSETS.json] [--expected-archive FILE] \
        [--entitlements ios/Godstone/Godstone.entitlements] [--release-candidate] \
        [--out DIR]
    python3 scripts/inspect_ios_artifacts.py --selftest

WHAT A SOURCE BUILD PROVES, AND WHAT IT DOES NOT
------------------------------------------------
`xcodegen generate` + `xcodebuild ... -configuration LightRelease build` proves
that the Swift graph compiles and packages under the release configuration with
signing disabled. It does NOT prove that the shipped artifact carries an
approved Archive, that it is installable on a device, or that anybody signed
it. Those are different claims with different evidence, and this inspector
keeps them apart by CLASSIFYING the artifact instead of judging it:

    release-candidate-content   the approved manifest was supplied, the Archive
                                inside the bundle byte-matcheth it, and every
                                release-surface law below holdeth
    present-unverified          an Archive is inside the bundle but nothing
                                approved its bytes
    source-only-exclusion       no Archive, and none was expected: a source
                                build, classified as such and never as a release
    source-only-absent          an Archive was expected (or approved) and is
                                absent from the bundle: the presence claim FAILED

WHAT IT READS
-------------
Mach-O headers are parsed HERE, in Python, rather than shelled out to `otool`:
the load commands are what name the dylibs, the platform, the minimum OS and
the UUID, and parsing them directly means the laws can be exercised on
synthetic binaries in a court with no Mac in the loop. `codesign` is consulted
only to read the signatures that are actually present.

The laws, in the order the card names them: the bundle's file census and
aggregate digest; the resource census (archives, models, test bundles);
linked libraries and rpaths; architectures; the deployment minimum;
entitlements (from the signature when signed, and from the repository's
declared release entitlements when named); the privacy manifest; and the
absence of every lab/mesh/LLM surface this release excludes.

External, and never claimed here: signing, installation and launch on a real
iPhone or iPad, and the approval of the Archive's content.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any, Iterable, Mapping

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT / "scripts") not in sys.path:
    sys.path.insert(0, str(ROOT / "scripts"))

APPROVED_SCHEMA = 1
ARCHIVE_NAME = "archive_light.db"
FORBIDDEN_ARCHIVES = ("archive_medium.db", "archive_large.db")
EXPECTED_BUNDLE_ID = "io.godstone.app"
MINIMUM_OS = (16, 0)

# The surfaces a LIGHT release excludes. The Android twin carrieth the same
# list on its own side of the fence.
FORBIDDEN_LINK_TOKENS = ("GodstoneMesh", "XCTest", "GMP", "llama", "GodstoneLLM",
                         "libBLE", "CoreBluetooth")
FORBIDDEN_RESOURCE_PATTERNS = (
    re.compile(r"\.gguf$", re.I), re.compile(r"\.mlmodelc?$", re.I),
    re.compile(r"\.mlpackage$", re.I), re.compile(r"\.xctest$", re.I),
    re.compile(r"^archive_(medium|large)\.db$", re.I),
    re.compile(r"\.xcframework$", re.I), re.compile(r"\.dylib$", re.I),
    re.compile(r"^lib.*mesh.*\.(so|dylib)$", re.I),
)
FORBIDDEN_ENTITLEMENT_KEYS = (
    "com.apple.developer.networking.multicast",
    "com.apple.developer.networking.wifi-info",
    "com.apple.developer.bluetooth-always",
    "com.apple.developer.healthkit",
    "com.apple.developer.homekit",
    "com.apple.developer.associated-domains",
    "com.apple.developer.networking.networkextension",
    "aps-environment",
)
FORBIDDEN_INFO_KEYS = ("NSBluetoothAlwaysUsageDescription",
                       "NSLocalNetworkUsageDescription",
                       "NSMicrophoneUsageDescription",
                       "NSCameraUsageDescription",
                       "NSLocationWhenInUseUsageDescription", "UIBackgroundModes",
                       "NSBonjourServices")

MACH_MAGICS = {0xfeedface: ("32", "<"), 0xcefaedfe: ("32", ">"),
               0xfeedfacf: ("64", "<"), 0xcffaedfe: ("64", ">")}
FAT_MAGICS = {0xcafebabe: ">", 0xbebafeca: "<", 0xcafebabf: ">", 0xbfbafeca: "<"}
LC_LOAD_DYLIB = 0xc
LC_ID_DYLIB = 0xd
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_RPATH = 0x8000001c
LC_UUID = 0x1b
LC_VERSION_MIN_IPHONEOS = 0x25
LC_BUILD_VERSION = 0x32
CPU_ARCH = {0x0100000c: "arm64", 0x01000007: "x86_64", 7: "i386", 12: "arm"}
PLATFORM_NAMES = {1: "macos", 2: "ios", 3: "tvos", 4: "watchos", 6: "maccatalyst",
                  7: "ios-simulator", 8: "tvos-simulator", 9: "watchos-simulator"}

SHA256_RE = re.compile(r"[0-9a-f]{64}")


class ArtifactError(RuntimeError):
    """A refusal. Every refusal precedeth any report being published."""


def _require(condition: Any, message: str) -> None:
    if not condition:
        raise ArtifactError(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def write_document(path: Path, document: Any) -> str:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    blob = canonical(document)
    handle = tempfile.NamedTemporaryFile(prefix=".iosaudit-", dir=path.parent,
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
    return hashlib.sha256(blob).hexdigest()


def version_tuple(value: Any) -> tuple[int, ...]:
    parts: list[int] = []
    for piece in str(value or "").split("."):
        digits = re.match(r"\d+", piece)
        parts.append(int(digits.group(0)) if digits else 0)
    return tuple(parts)


# ---------------------------------------------------------------------------
# Mach-O, parsed here rather than shelled out
# ---------------------------------------------------------------------------
def _load_commands(data: bytes, offset: int, endian: str, bits: str
                   ) -> tuple[list[dict[str, Any]], int]:
    header_size = 32 if bits == "64" else 28
    _require(len(data) >= offset + header_size, "the Mach-O header is truncated")
    fields = struct.unpack_from(endian + "IIIIIII", data, offset + 4)
    ncmds, sizeofcmds, filetype = fields[3], fields[4], fields[2]
    position = offset + header_size
    commands: list[dict[str, Any]] = []
    for _ in range(ncmds):
        _require(position + 8 <= len(data), "a load command is truncated")
        cmd, cmdsize = struct.unpack_from(endian + "II", data, position)
        _require(cmdsize >= 8 and position + cmdsize <= len(data),
                 f"load command {cmd:#x} declareth a size that leaveth the file")
        body = data[position:position + cmdsize]
        entry: dict[str, Any] = {"cmd": cmd, "cmdsize": cmdsize}
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_ID_DYLIB, LC_RPATH):
            if len(body) >= 12:
                name_offset = struct.unpack_from(endian + "I", body, 8)[0]
                if 0 < name_offset < len(body):
                    entry["name"] = body[name_offset:].split(b"\0", 1)[0].decode(
                        "utf-8", "replace")
        elif cmd == LC_UUID and len(body) >= 24:
            entry["uuid"] = body[8:24].hex()
        elif cmd == LC_BUILD_VERSION and len(body) >= 24:
            platform, minos, sdk = struct.unpack_from(endian + "III", body, 8)
            entry.update({"platform": PLATFORM_NAMES.get(platform, str(platform)),
                          "minos": _version_string(minos),
                          "sdk": _version_string(sdk)})
        elif cmd == LC_VERSION_MIN_IPHONEOS and len(body) >= 16:
            minos, sdk = struct.unpack_from(endian + "II", body, 8)
            entry.update({"platform": "ios", "minos": _version_string(minos),
                          "sdk": _version_string(sdk)})
        commands.append(entry)
        position += cmdsize
    return commands, filetype


def _version_string(packed: int) -> str:
    return f"{packed >> 16}.{(packed >> 8) & 0xff}.{packed & 0xff}"


def parse_macho(data: bytes) -> list[dict[str, Any]]:
    """Every architecture slice of a Mach-O, fat or thin. Raises if it is neither."""
    _require(len(data) >= 8, "the file is too short to be a Mach-O")
    magic = struct.unpack_from(">I", data, 0)[0]
    slices: list[dict[str, Any]] = []
    if magic in FAT_MAGICS:
        endian = FAT_MAGICS[magic]
        wide = magic in (0xcafebabf, 0xbfbafeca)
        count = struct.unpack_from(endian + "I", data, 4)[0]
        _require(0 < count <= 32, f"implausible architecture count: {count}")
        entry_size = 32 if wide else 20
        for index in range(count):
            base = 8 + index * entry_size
            _require(base + entry_size <= len(data), "the fat header is truncated")
            if wide:
                cputype, cpusubtype, offset, size, _align, _reserved = struct.unpack_from(
                    endian + "IIQQII", data, base)
            else:
                cputype, cpusubtype, offset, size, _align = struct.unpack_from(
                    endian + "IIIII", data, base)
            _require(offset + size <= len(data),
                     "a fat slice reacheth past the end of the file")
            slices.append(_parse_slice(data[offset:offset + size], cputype))
        return slices
    little = magic in (0xfeedfacf, 0xfeedface)
    _require(magic in MACH_MAGICS, f"not a Mach-O: magic {magic:#x}")
    return [_parse_slice(data, None)]


def _parse_slice(blob: bytes, cputype: int | None) -> dict[str, Any]:
    magic = struct.unpack_from("<I", blob, 0)[0]
    if magic in MACH_MAGICS:
        bits, endian = MACH_MAGICS[magic]
    else:
        magic_be = struct.unpack_from(">I", blob, 0)[0]
        _require(magic_be in MACH_MAGICS, "a fat slice is not a Mach-O")
        bits, endian = MACH_MAGICS[magic_be]
    head = struct.unpack_from(endian + "IIII", blob, 4)
    if cputype is None:
        cputype = head[0]
    commands, filetype = _load_commands(blob, 0, endian, bits)
    dylibs = [c["name"] for c in commands
              if c["cmd"] in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB) and c.get("name")]
    rpaths = [c["name"] for c in commands if c["cmd"] == LC_RPATH and c.get("name")]
    uuid = next((c["uuid"] for c in commands if c["cmd"] == LC_UUID), None)
    build = next((c for c in commands if c["cmd"] in (LC_BUILD_VERSION,
                                                      LC_VERSION_MIN_IPHONEOS)), None)
    return {"arch": CPU_ARCH.get(cputype, f"cputype-{cputype:#x}"),
            "bits": bits, "filetype": filetype, "uuid": uuid, "dylibs": dylibs,
            "rpaths": rpaths,
            "platform": (build or {}).get("platform"),
            "minos": (build or {}).get("minos"),
            "sdk": (build or {}).get("sdk"),
            "load_commands": len(commands)}


# ---------------------------------------------------------------------------
# The bundle census
# ---------------------------------------------------------------------------
def census(bundle: Path) -> list[dict[str, Any]]:
    bundle = Path(bundle)
    _require(bundle.is_dir(), f"the bundle is not a directory: {bundle}")
    files: list[dict[str, Any]] = []
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink():
            raise ArtifactError(f"the bundle carrieth a symlink, {path.name}: a link "
                                f"is not bytes and cannot be hashed honestly")
        if not path.is_file():
            continue
        files.append({"path": str(path.relative_to(bundle)),
                      "bytes": path.stat().st_size, "sha256": sha256_file(path)})
    _require(files, f"the bundle carrieth no file at all: {bundle}")
    return files


def aggregate_digest(files: Iterable[Mapping[str, Any]]) -> str:
    """One digest over the census, so two bundles are compared by content."""
    digest = hashlib.sha256()
    for entry in sorted(files, key=lambda item: str(item["path"])):
        digest.update(f"{entry['path']}\0{entry['bytes']}\0{entry['sha256']}\n".encode())
    return digest.hexdigest()


# ---------------------------------------------------------------------------
# The inspection
# ---------------------------------------------------------------------------
def load_approved_manifest(path: Path) -> dict[str, Any]:
    """Read the staged APPROVED_ASSETS.json through the Android twin's loader.

    One authority for that document: the file is written by
    scripts/prepare_release_assets.py and read by both inspectors, so the two
    platforms cannot drift into two readings of one publication."""
    from inspect_android_artifacts import load_approved_manifest as android_loader
    return android_loader(Path(path))


def inspect(bundle: Path, *, expected_archive: Path | None = None,
            approved_manifest: Path | None = None,
            release_candidate: bool = False,
            entitlements_path: Path | None = None,
            device: bool = False) -> dict[str, Any]:
    """Inspect one .app and return the report. Refusals raise; findings are listed."""
    bundle = Path(bundle)
    _require(bundle.is_dir(), f"the bundle is not a directory: {bundle}")
    files = census(bundle)
    failures: list[str] = []
    warnings: list[str] = []

    # ---- bundle metadata -------------------------------------------------
    info_path = bundle / "Info.plist"
    _require(info_path.is_file(), "the bundle carrieth no Info.plist")
    try:
        info = plistlib.loads(info_path.read_bytes())
    except Exception as exc:                      # plistlib raises several types
        raise ArtifactError(f"Info.plist is not a readable plist: {exc}") from exc
    executable_name = str(info.get("CFBundleExecutable") or "")
    _require(executable_name, "Info.plist carrieth no CFBundleExecutable")
    executable = bundle / executable_name
    _require(executable.is_file(),
             f"the declared executable is absent from the bundle: {executable_name}")
    metadata = {
        "CFBundleIdentifier": info.get("CFBundleIdentifier"),
        "CFBundleExecutable": executable_name,
        "CFBundleShortVersionString": info.get("CFBundleShortVersionString"),
        "CFBundleVersion": info.get("CFBundleVersion"),
        "MinimumOSVersion": info.get("MinimumOSVersion"),
        "DTPlatformName": info.get("DTPlatformName"),
        "DTXcode": info.get("DTXcode"),
        "UIDeviceFamily": info.get("UIDeviceFamily"),
        "UIRequiredDeviceCapabilities": info.get("UIRequiredDeviceCapabilities"),
    }
    if metadata["CFBundleIdentifier"] != EXPECTED_BUNDLE_ID:
        failures.append(f"bundle identity is not {EXPECTED_BUNDLE_ID}: "
                        f"{metadata['CFBundleIdentifier']!r}")
    for key in FORBIDDEN_INFO_KEYS:
        if key in info:
            failures.append(f"the Info.plist carrieth a disabled capability: {key}")

    # ---- the binary ------------------------------------------------------
    slices = parse_macho(executable.read_bytes())
    dylibs = sorted({name for entry in slices for name in entry["dylibs"]})
    rpaths = sorted({name for entry in slices for name in entry["rpaths"]})
    architectures = sorted({entry["arch"] for entry in slices})
    platform = next((entry["platform"] for entry in slices if entry["platform"]), None)
    minos = next((entry["minos"] for entry in slices if entry["minos"]), None)
    link_map = {"dylibs": dylibs, "rpaths": rpaths, "slices": slices,
                "uuid": slices[0]["uuid"] if slices else None}

    for name in dylibs:
        for token in FORBIDDEN_LINK_TOKENS:
            if token.lower() in name.lower():
                failures.append(f"the release binary linketh {name!r}, which "
                                f"carrieth the excluded token {token!r}")
    if "arm64" not in architectures:
        failures.append(f"the release binary is not arm64: {architectures}")
    simulator = [entry["arch"] for entry in slices
                 if entry["platform"] and "simulator" in entry["platform"]]
    if simulator:
        failures.append(f"the bundle carrieth simulator slice(s) {simulator}: a "
                        f"source-only or lab artifact, not a release candidate")
    declared_min = version_tuple(metadata["MinimumOSVersion"] or minos)
    if declared_min and declared_min < MINIMUM_OS:
        failures.append(f"the deployment minimum {metadata['MinimumOSVersion']} is "
                        f"below {'.'.join(str(p) for p in MINIMUM_OS)}")
    if minos and version_tuple(minos) != version_tuple(metadata["MinimumOSVersion"]):
        warnings.append(f"the binary's own minimum ({minos}) is not the Info.plist's "
                        f"({metadata['MinimumOSVersion']})")

    # ---- resources -------------------------------------------------------
    by_extension: dict[str, int] = {}
    forbidden_resources: list[str] = []
    for entry in files:
        name = Path(entry["path"]).name
        suffix = Path(name).suffix.lower() or "(none)"
        by_extension[suffix] = by_extension.get(suffix, 0) + 1
        for pattern in FORBIDDEN_RESOURCE_PATTERNS:
            if pattern.search(name):
                forbidden_resources.append(entry["path"])
                break
    for path in forbidden_resources:
        failures.append(f"the bundle carrieth a resource the LIGHT release "
                        f"excludes: {path}")
    resources = {"count": len(files), "by_extension": by_extension,
                 "forbidden": sorted(forbidden_resources),
                 "total_bytes": sum(entry["bytes"] for entry in files)}

    # ---- the Archive, and the presence claim -----------------------------
    bundled_archive = bundle / ARCHIVE_NAME
    approved: dict[str, Any] | None = None
    if approved_manifest is not None:
        try:
            approved = load_approved_manifest(Path(approved_manifest))
        except (ValueError, OSError, KeyError) as exc:
            raise ArtifactError(f"the approved manifest is refused: {exc}") from exc
    expected_digest = None
    if approved is not None:
        expected_digest = approved["sha256"]
        if approved["application_id"] != metadata["CFBundleIdentifier"]:
            failures.append(f"the approved manifest is for "
                            f"{approved['application_id']}, not for "
                            f"{metadata['CFBundleIdentifier']}")
    elif expected_archive is not None:
        expected_digest = sha256_file(Path(expected_archive))
    archive = {"expected_sha256": expected_digest,
               "bundled_sha256": sha256_file(bundled_archive)
               if bundled_archive.is_file() else None,
               "bytes": bundled_archive.stat().st_size
               if bundled_archive.is_file() else None,
               "name": ARCHIVE_NAME}
    if bundled_archive.is_file():
        archive["tier"] = _archive_tier(bundled_archive)
        if expected_digest is None:
            archive["status"] = "present-unverified"
            warnings.append("an Archive is present in the bundle and nothing approved "
                            "its bytes: classified present-unverified, never as a "
                            "release candidate")
        elif archive["bundled_sha256"] == expected_digest:
            archive["status"] = "byte-matched"
            if approved is None:
                warnings.append("the presence claim is met (the bundled Archive is the "
                                "expected Archive) and no approval was furnished: "
                                "classified present-unverified, never as a candidate")
        else:
            archive["status"] = "byte-mismatch"
            failures.append("the bundled Archive is not the approved Archive: "
                            f"{archive['bundled_sha256']} != {expected_digest}")
    else:
        archive["status"] = "absent"
        if expected_digest is not None:
            failures.append("the expected Archive is absent from the package")
        else:
            archive["status"] = "absent-expected-none"

    # ---- entitlements ----------------------------------------------------
    signature_entitlements = _signature_entitlements(bundle)
    declared_entitlements = None
    if entitlements_path is not None:
        declared_entitlements = _read_entitlements(Path(entitlements_path))
        for key in FORBIDDEN_ENTITLEMENT_KEYS:
            if key in declared_entitlements:
                failures.append(f"the declared release entitlements carry the "
                                f"disabled capability {key}")
        if declared_entitlements:
            failures.append("the release entitlements must be empty for an "
                            "Archive-only release: "
                            f"{sorted(declared_entitlements)}")
    entitlements = {"signed": signature_entitlements is not None,
                    "keys": sorted(signature_entitlements or {}),
                    "declared_keys": sorted(declared_entitlements or {}),
                    "forbidden": [key for key in FORBIDDEN_ENTITLEMENT_KEYS
                                  if key in (signature_entitlements or {})]}

    # ---- the privacy manifest -------------------------------------------
    privacy = _privacy(bundle)
    failures.extend(privacy.pop("failures"))

    # ---- test-only surfaces ---------------------------------------------
    test_only = {"frameworks": [name for name in dylibs
                                if "xctest" in name.lower()],
                 "bundles": [entry["path"] for entry in files
                             if entry["path"].endswith(".xctest")
                             or ".xctest/" in entry["path"]],
                 "resources": [entry["path"] for entry in files
                               if "test" in Path(entry["path"]).name.lower()
                               and Path(entry["path"]).suffix in (".plist", ".json")]}
    if test_only["frameworks"] or test_only["bundles"]:
        failures.append("the release bundle carrieth test-only surfaces: "
                        f"{test_only['frameworks'] + test_only['bundles']}")

    # ---- classification --------------------------------------------------
    if failures:
        classification = "refused"
    elif archive["status"] == "byte-matched" and approved is not None:
        classification = "release-candidate-content"
    elif archive["status"] == "byte-matched":
        # the presence claim is met and no APPROVAL was furnished: a
        # labelled fixture may be present without being approved content, and
        # the classification carrieth that distinction rather than blurring it
        classification = "present-unverified"
    elif archive["status"] in ("present-unverified", "byte-mismatch"):
        classification = "present-unverified"
    else:
        classification = "source-only-exclusion"
    if release_candidate and classification != "release-candidate-content":
        failures.append(f"this run claimeth to be a release candidate and the artifact "
                        f"is classified {classification!r}")
        classification = "refused"

    return {
        "schema": 1,
        "bundle": str(bundle),
        "classification": classification,
        "hashes": {"aggregate_sha256": aggregate_digest(files), "files": files},
        "resources": resources,
        "linkMap": link_map,
        "architectures": {"architectures": architectures, "platform": platform,
                          "minimum_os": metadata["MinimumOSVersion"] or minos},
        "entitlements": entitlements,
        "privacy": privacy,
        "bundleMetadata": metadata,
        "archive": archive,
        "test_only": test_only,
        "approved_manifest": None if approved is None else {
            "tier": approved["tier"], "sha256": approved["sha256"],
            "bytes": approved["bytes"]},
        "device": {
            "installed": "UNVERIFIED (external: no device in this lane)"
            if not device else "UNVERIFIED",
            "launched": "UNVERIFIED (external: no device in this lane)",
            "note": ("installation and launch on a supported iPhone and iPad, and "
                     "signing with approved credentials, are external evidence; this "
                     "report carrieth none of it"),
        },
        "failures": failures,
        "warnings": warnings,
        "verdict": "FAIL" if failures else "PASS",
    }


def _archive_tier(archive: Path) -> str | None:
    import sqlite3
    try:
        con = sqlite3.connect(f"file:{archive}?mode=ro", uri=True)
        try:
            row = con.execute("SELECT value FROM archive_meta WHERE key='tier'").fetchone()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    return None if row is None else str(row[0])


def _read_entitlements(path: Path) -> dict[str, Any]:
    _require(path.is_file(), f"the entitlements file is missing: {path}")
    try:
        value = plistlib.loads(path.read_bytes())
    except Exception as exc:
        raise ArtifactError(f"the entitlements are not a readable plist: {exc}") from exc
    _require(isinstance(value, dict), "the entitlements must be a dictionary")
    return value


def _signature_entitlements(bundle: Path) -> dict[str, Any] | None:
    """The entitlements a signature actually carrieth, if there is a signature."""
    codesign = shutil.which("codesign")
    if codesign is None:
        return None
    for candidate in (bundle, bundle.parent):
        result = subprocess.run([codesign, "-d", "--entitlements", ":-", str(candidate)],
                                capture_output=True)
        if result.returncode == 0 and result.stdout.strip():
            try:
                value = plistlib.loads(result.stdout)
            except Exception:
                return None
            if isinstance(value, dict):
                if value:
                    for key in FORBIDDEN_ENTITLEMENT_KEYS:
                        if key in value:
                            return value
                return value
    return None


def _privacy(bundle: Path) -> dict[str, Any]:
    candidates = sorted(bundle.rglob("PrivacyInfo.xcprivacy"))
    failures: list[str] = []
    if not candidates:
        return {"present": False, "failures": [
            "the bundle carrieth no PrivacyInfo.xcprivacy: a release may not ship "
            "without its privacy manifest"]}
    path = candidates[0]
    try:
        document = plistlib.loads(path.read_bytes())
    except Exception as exc:
        return {"present": True, "failures": [
            f"PrivacyInfo.xcprivacy is not a readable plist: {exc}"]}
    if not isinstance(document, dict):
        return {"present": True, "failures": ["PrivacyInfo.xcprivacy is not a "
                                             "dictionary"]}
    tracking = document.get("NSPrivacyTracking")
    if tracking is not False:
        failures.append(f"NSPrivacyTracking must be false for an Archive-only "
                        f"release, and it readeth {tracking!r}")
    accessed = document.get("NSPrivacyAccessedAPITypes") or []
    collected = document.get("NSPrivacyCollectedDataTypes") or []
    if not isinstance(accessed, list):
        failures.append("NSPrivacyAccessedAPITypes must be an array")
        accessed = []
    for index, entry in enumerate(accessed):
        if not isinstance(entry, dict):
            failures.append(f"NSPrivacyAccessedAPITypes[{index}] is not a dictionary")
            continue
        if not entry.get("NSPrivacyAccessedAPIType"):
            failures.append(f"NSPrivacyAccessedAPITypes[{index}] carrieth no category")
        reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
        if not isinstance(reasons, list) or not reasons:
            failures.append(f"NSPrivacyAccessedAPITypes[{index}] carrieth no reason "
                            f"code; a declared API without a reason is not a "
                            f"declaration")
    if collected:
        failures.append(f"the release declareth collected data types "
                        f"{[c.get('NSPrivacyCollectedDataType') for c in collected if isinstance(c, dict)]}"
                        f"; an Archive-only release collecteth nothing")
    return {"present": True, "path": str(path.relative_to(bundle)),
            "tracking": tracking,
            "tracking_domains": document.get("NSPrivacyTrackingDomains") or [],
            "accessed_api_types": [str(entry.get("NSPrivacyAccessedAPIType"))
                                   for entry in accessed if isinstance(entry, dict)],
            "collected_data_types": collected,
            "failures": failures}


# ---------------------------------------------------------------------------
# IPA: the packaged form
# ---------------------------------------------------------------------------
def extract_ipa(ipa: Path, destination: Path) -> Path:
    """Extract a .ipa's app, refusing anything a package should never carry."""
    ipa = Path(ipa)
    _require(zipfile.is_zipfile(ipa), f"the IPA is not a zip archive: {ipa}")
    with zipfile.ZipFile(ipa) as archive:
        names = archive.namelist()
        # The hostile shapes are judged FIRST: a package carrying a traversal
        # entry must be refused for what it is, not for failing an unrelated
        # census later in the same function.
        for entry in archive.infolist():
            name = entry.filename
            if name.startswith("/") or ".." in Path(name).parts:
                raise ArtifactError(f"the IPA carrieth a traversal entry: {name}")
            mode = entry.external_attr >> 16
            if mode and (mode & 0o170000) == 0o120000:
                raise ArtifactError(f"the IPA carrieth a symlink entry: {name}")
            if mode and (mode & 0o002):
                raise ArtifactError(f"the IPA carrieth a world-writable entry: {name}")
        apps = sorted({match.group(1) for name in names
                       for match in [re.match(r"Payload/([^/]+\.app)/", name)]
                       if match is not None})
        if len(apps) != 1:
            raise ArtifactError(f"the IPA must carrieth exactly one app, and it "
                                f"carrieth {len(apps)}: {apps}")
        archive.extractall(destination)
    return Path(destination) / "Payload" / apps[0]


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _selftest() -> int:
    """Prove the reader's own laws against synthetic inputs, in a temp dir."""
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as work:
        root = Path(work)
        bundle = root / "Fixture.app"
        bundle.mkdir()
        _write_synthetic_bundle(bundle)
        report = inspect(bundle)
        if report["classification"] != "source-only-exclusion":
            failures.append(f"a synthetic source bundle classified "
                            f"{report['classification']!r}")
        if report["verdict"] != "PASS":
            failures.append(f"a clean synthetic bundle failed: {report['failures']}")
        (bundle / "archive_medium.db").write_bytes(b"not an approved archive")
        poisoned = inspect(bundle)
        if poisoned["verdict"] != "FAIL":
            failures.append("an excluded tier archive was not refused")
        if not any("excludes" in item for item in poisoned["failures"]):
            failures.append(f"the exclusion failure was not named: "
                            f"{poisoned['failures']}")
        shutil.rmtree(bundle)
    for line in failures:
        print(f"::error::{line}")
    if failures:
        print(f"selftest FAILED ({len(failures)})")
        return 1
    print("selftest OK: the reader classified a clean bundle and refused an excluded "
          "archive")
    return 0


def _write_synthetic_bundle(bundle: Path, *, executable: str = "Fixture",
                            minos: str = "16.0", library: str | None = None,
                            tracking: Any = False, arch: int = 0x0100000c) -> Path:
    """A synthetic but structurally real bundle: a Mach-O with load commands."""
    commands = b""
    if library is not None:
        payload = library.encode() + b"\0"
        payload += b"\0" * ((8 - len(payload) % 8) % 8)
        size = 20 + len(payload)
        # the name's lc_str offset is measured from the START of the command,
        # and five 4-byte fields (cmd, cmdsize, name offset, timestamp, version)
        # stand before it
        commands += struct.pack("<IIIII", LC_LOAD_DYLIB, size, 20, 0, 0) + payload
    uuid_payload = bytes(range(16))
    commands += struct.pack("<II", LC_UUID, 24) + uuid_payload
    commands += struct.pack("<IIIIII", LC_BUILD_VERSION, 24, 2,
                            (16 << 16) | (0 << 8), (17 << 16), 0)
    ncmds = 2 + (1 if library is not None else 0)
    header = struct.pack("<IIIIIIII", 0xfeedfacf, arch, 0, 2, ncmds, len(commands), 0, 0)
    (bundle / executable).write_bytes(header + commands)
    info = {"CFBundleIdentifier": EXPECTED_BUNDLE_ID, "CFBundleExecutable": executable,
            "CFBundleShortVersionString": "1.0.0", "CFBundleVersion": "1",
            "MinimumOSVersion": minos, "DTPlatformName": "iphoneos",
            "UIDeviceFamily": [1, 2],
            "UIRequiredDeviceCapabilities": ["arm64"]}
    (bundle / "Info.plist").write_bytes(plistlib.dumps(info))
    privacy = {"NSPrivacyTracking": tracking,
               "NSPrivacyTrackingDomains": [],
               "NSPrivacyCollectedDataTypes": [],
               "NSPrivacyAccessedAPITypes": [
                   {"NSPrivacyAccessedAPIType":
                    "NSPrivacyAccessedAPICategoryFileTimestamp",
                    "NSPrivacyAccessedAPITypeReasons": ["C617.1"]},
                   {"NSPrivacyAccessedAPIType":
                    "NSPrivacyAccessedAPICategoryUserDefaults",
                    "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]}]}
    (bundle / "PrivacyInfo.xcprivacy").write_bytes(plistlib.dumps(privacy))
    return bundle


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Audit a real iOS release artifact")
    parser.add_argument("artifact", nargs="?", type=Path,
                        help="a Godstone.app bundle or a Godstone.ipa")
    parser.add_argument("--approved-manifest", type=Path, default=None)
    parser.add_argument("--expected-archive", type=Path, default=None)
    parser.add_argument("--entitlements", type=Path, default=None)
    parser.add_argument("--release-candidate", action="store_true")
    parser.add_argument("--out", type=Path, default=None)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    if args.selftest:
        return _selftest()
    if args.artifact is None:
        parser.error("an artifact is required unless --selftest is asked")
    try:
        artifact = Path(args.artifact)
        with tempfile.TemporaryDirectory(prefix=".iosaudit-ipa-") as work:
            bundle = (extract_ipa(artifact, Path(work))
                      if artifact.suffix.lower() == ".ipa" else artifact)
            report = inspect(bundle, expected_archive=args.expected_archive,
                             approved_manifest=args.approved_manifest,
                             release_candidate=args.release_candidate,
                             entitlements_path=args.entitlements)
    except ArtifactError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    if args.out is not None:
        target = Path(args.out)
        target = target / "ios-artifact-report.json" if target.is_dir() else target
        write_document(target, report)
    for item in report["failures"]:
        print(f"::error::{item}")
    for item in report["warnings"]:
        print(f"::warning::{item}")
    print(f"{report['verdict']}: {report['classification']} "
          f"({report['architectures']['architectures']}, "
          f"minimum {report['architectures']['minimum_os']}, "
          f"{report['resources']['count']} file(s), archive "
          f"{report['archive']['status']})")
    return 0 if report["verdict"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
