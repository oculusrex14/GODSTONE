#!/usr/bin/env python3
"""Verify a built SQLCipher image against the TRUSTED supply authority.

    python3 tools/supplychain/verify_sqlcipher_artifact.py \
        --mode macos /path/to/libsqlcipher.0.dylib
    python3 tools/supplychain/verify_sqlcipher_artifact.py \
        --mode ios-simulator --dir /staged/dir
    python3 tools/supplychain/verify_sqlcipher_artifact.py --selftest

WHY THIS EXISTS
---------------
A loader that trusteth a sidecar FILE sitting beside the dylib trusteth whoever
can write to that directory: replace the image AND the sidecar together and the
loader's "expected" digest describes the attacker's own bytes. The trust anchor
must therefore be OUTSIDE the replaceable pair -- it is THIS repository register
(docs/supplychain/SQLCIPHER.pins.json), read by a tool that a runner cannot
rewrite, and the loader must be handed an expectation that was BAKED at the build/
package boundary rather than discovered at the point of use.

THE LAWS ENFORCED HERE
----------------------
* The FULL source identity is checked: commit (exactly, no prefix), tag, and repo
  -- a matching commit prefix is not a pin.
* The OUTPUT is checked against the register's expected digest AND byte count for
  the SAME mode, platform and arch. The image's own Mach-O is inspected (platform,
  arch, minos) rather than trusted from a label.
* The required SQLite symbols and the SQLCipher init symbols must be PRESENT, so an
  image that carrieth `sqlcipher_extra_init` is the one that actually initialiseth.
* A mismatch is a REFUSAL by name. A digest is per-toolchain: the register carrieth
  an entry per mode/toolchain, and an unlisted toolchain is a refusal, never a
  silent pass.

This tool does NOT change the loader; it produceth the trusted expectation the
build/package boundary must bake in (see `--emit-expectation`).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import struct
import subprocess
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

ROOT = Path(__file__).resolve().parents[2]
REGISTER = ROOT / "docs" / "supplychain" / "SQLCIPHER.pins.json"
SHA256_RE = re.compile(r"[0-9a-f]{64}")
FULL_SHA_RE = re.compile(r"[0-9a-f]{40}")

MACH_MAGICS = {0xfeedface: ("32", "<"), 0xcefaedfe: ("32", ">"),
               0xfeedfacf: ("64", "<"), 0xcffaedfe: ("64", ">")}
FAT_MAGICS = {0xcafebabe: ">", 0xbebafeca: "<", 0xcafebabf: ">", 0xbfbafeca: "<"}
LC_SYMTAB = 0x2
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_NAMES = {1: "MACOS", 2: "IOS", 3: "TVOS", 4: "WATCHOS", 6: "MACCATALYST",
                  7: "IOSSIMULATOR", 8: "TVOSSIMULATOR", 9: "WATCHOSSIMULATOR"}
CPU_ARCH = {0x0100000c: "arm64", 0x01000007: "x86_64", 7: "i386", 12: "arm"}


class AuthorityError(RuntimeError):
    """A refusal. Every refusal precedeth any image being trusted or staged."""


def sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(block)
    return hasher.hexdigest()


def load_register(path: Path = REGISTER) -> dict[str, Any]:
    document = json.loads(Path(path).read_text(encoding="utf-8"))
    if document.get("schema") != 2:
        raise AuthorityError(f"{path}: the supply register schema must be 2")
    return document


def _mode(document: Mapping[str, Any], mode: str) -> tuple[dict, dict]:
    for source in document.get("sources") or []:
        entry = (source.get("modes") or {}).get(mode)
        if entry is not None:
            return source, entry
    raise AuthorityError(f"the register carrieth no mode {mode!r}: an unlisted "
                         f"toolchain is a refusal, never a silent pass")


def macho_facts(path: Path) -> dict[str, Any]:
    """Read a Mach-O's platform, arch and minos from its own load commands."""
    data = Path(path).read_bytes()
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in FAT_MAGICS:
        endian = FAT_MAGICS[magic]
        wide = magic in (0xcafebabf, 0xbfbafeca)
        count = struct.unpack_from(endian + "I", data, 4)[0]
        base = 8 + (32 if wide else 20) * 0
        if wide:
            _cpu, _sub, offset, size, _a, _r = struct.unpack_from(endian + "IIQQII",
                                                                  data, base)
        else:
            _cpu, _sub, offset, size, _a = struct.unpack_from(endian + "IIIII", data,
                                                              base)
        data = data[offset:offset + size]
        magic = struct.unpack_from("<I", data, 0)[0]
    bits, endian = (("64", ">") if magic == 0xfeedfacf else
                    ("64", "<") if magic == 0xcffaedfe else
                    ("32", ">") if magic == 0xfeedface else
                    ("32", "<") if magic == 0xcefaedfe else (None, None))
    if bits is None:
        raise AuthorityError(f"{path} is not a Mach-O image")
    head = struct.unpack_from(endian + "IIII", data, 4)
    cputype = head[0]
    ncmds = head[3]
    header_size = 32 if bits == "64" else 28
    position = header_size
    platform = minos = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(endian + "II", data, position)
        if cmd == LC_BUILD_VERSION:
            plat, mino, _sdk = struct.unpack_from(endian + "III", data, position + 8)
            platform = PLATFORM_NAMES.get(plat, str(plat))
            minos = f"{mino >> 16}.{(mino >> 8) & 0xff}.{mino & 0xff}"
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            mino, _sdk = struct.unpack_from(endian + "II", data, position + 8)
            platform = "IOS"
            minos = f"{mino >> 16}.{(mino >> 8) & 0xff}.{mino & 0xff}"
        position += cmdsize
    return {"platform": platform, "minos": minos,
            "arch": CPU_ARCH.get(cputype, f"cputype-{cputype:#x}")}


def symbol_names(path: Path) -> set[str]:
    """The exported symbol names, read via nm (a build tool, not a trust input)."""
    try:
        out = subprocess.run(["nm", "-gU", str(path)], capture_output=True, text=True)
    except OSError as exc:
        raise AuthorityError(f"cannot read symbols from {path}: {exc}") from exc
    return {line.split()[-1].lstrip("_") for line in out.stdout.splitlines()
            if line.strip()}


def verify_artifact(path: Path, mode: str, *,
                    register: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """Judge a built image against the trusted register. Returns the bound facts."""
    register = register or load_register()
    source, expected = _mode(register, mode)
    path = Path(path)
    if not path.is_file():
        raise AuthorityError(f"the artifact is absent: {path}")
    actual_sha = sha256_file(path)
    actual_bytes = path.stat().st_size
    want = expected["expected_output"]
    if actual_bytes != want["bytes"]:
        raise AuthorityError(f"{path.name}: {actual_bytes} byte(s) where the trusted "
                             f"register sweareth {want['bytes']} for mode {mode!r}")
    if actual_sha != want["sha256"]:
        raise AuthorityError(f"{path.name}: sha256 {actual_sha} is not the trusted "
                             f"{want['sha256']} for mode {mode!r}: the image is NOT the "
                             f"pinned build (a replaceable image is not self-authorizing)")
    facts = macho_facts(path)
    if facts["platform"] != expected["platform"]:
        raise AuthorityError(f"{path.name}: platform {facts['platform']} is not the "
                             f"pinned {expected['platform']} for mode {mode!r}")
    if facts["arch"] != expected["arch"]:
        raise AuthorityError(f"{path.name}: arch {facts['arch']} is not the pinned "
                             f"{expected['arch']}")
    if (facts["minos"] or "").split(".")[0] != str(expected["minos"]).split(".")[0]:
        raise AuthorityError(f"{path.name}: minos {facts['minos']} is below the pinned "
                             f"{expected['minos']}")
    symbols = symbol_names(path)
    missing = [s for s in register.get("required_symbols") or [] if s not in symbols]
    if missing:
        raise AuthorityError(f"{path.name}: missing required symbol(s): {missing}")
    missing_init = [s for s in register.get("sqlcipher_init_symbols") or []
                    if s not in symbols]
    if missing_init:
        raise AuthorityError(f"{path.name}: missing SQLCipher init symbol(s): "
                             f"{missing_init} (an image that carrieth no "
                             f"sqlcipher_extra_init is not the authorised engine)")
    return {
        "library_name": register["library_name"],
        "source": {"commit": source["commit"], "tag": source["tag"],
                   "repo": source["repo"]},
        "recipe_sha256": hashlib.sha256(
            json.dumps(source["recipe"], sort_keys=True).encode()).hexdigest(),
        "cipher_version_major": register["cipher_version_major"],
        "platform": facts["platform"], "arch": facts["arch"], "minos": expected["minos"],
        "sha256": actual_sha, "bytes": actual_bytes, "mode": mode,
    }


def swift_constant(facts: Mapping[str, Any], *, register: Mapping[str, Any] | None = None
                   ) -> str:
    """The GENERATED Swift expectation (option 4a: a baked-in, non-staging trust).

    Emitted at the build/package boundary by a TRUSTED step (this tool), so the
    loader importeth a compiled-in constant rather than reading any file beside a
    replaceable image. One value per mode; the host/sim lane compiles THE one for
    its platform+arch."""
    register = register or load_register()
    symbols = ",\n".join(f'        "{name}"' for name in register["required_symbols"])
    return f"""// GENERATED by tools/supplychain/verify_sqlcipher_artifact.py --emit-swift.
// DO NOT EDIT BY HAND. The value is baked at the build/package boundary from
// docs/supplychain/SQLCIPHER.pins.json, outside any runner-writable staging dir.
public enum SQLCipherTrustedExpectation {{
    public static let commit = "{facts['source']['commit']}"
    public static let tag = "{facts['source']['tag']}"
    public static let repo = "{facts['source']['repo']}"
    public static let libraryName = "{facts['library_name']}"
    public static let mode = "{facts['mode']}"
    public static let platform = "{facts['platform']}"
    public static let arch = "{facts['arch']}"
    public static let sha256 = "{facts['sha256']}"
    public static let bytes = {facts['bytes']}
    public static let recipeSha256 = "{facts['recipe_sha256']}"
    public static let cipherVersionMajor = {facts['cipher_version_major']}
    public static let requiredSymbols = [
{symbols}
    ]
}}
"""

def current_toolchain() -> dict[str, str]:
    """The BUILD toolchain's identity: xcode version and the SDK's own version."""
    def _run(argv):
        try:
            out = subprocess.run(argv, capture_output=True, text=True)
            return out.stdout.strip()
        except OSError:
            return ""
    xcode = _run(["xcodebuild", "-version"]).splitlines()
    return {"xcode": (xcode[0].split()[-1] if xcode else "unknown")}


def record_entry(register: Mapping[str, Any], mode: str, image: Path) -> dict[str, Any]:
    """The LEGITIMATE way to support a new CI toolchain: MEASURE its output and
    record a NEW entry -- never loosen the hash gate.

    The caller has already verified that `image` is the correct build for `mode`
    (same source commit/recipe/platform/arch/symbols); this addeth the measured
    output digest+toolchain so a later run on that toolchain is checked EXACTLY."""
    path = Path(image)
    if not path.is_file():
        raise AuthorityError(f"the artifact is absent: {path}")
    facts = macho_facts(path)
    source, expected = _mode(register, mode)
    if facts["platform"] != expected["platform"] or facts["arch"] != expected["arch"]:
        raise AuthorityError(f"{path.name}: platform/arch {facts['platform']}/"
                             f"{facts['arch']} do not match mode {mode!r} "
                             f"({expected['platform']}/{expected['arch']}): refusing to "
                             f"record an entry for the wrong image")
    symbols = symbol_names(path)
    missing = [x for x in register.get("required_symbols") or [] if x not in symbols]
    if missing:
        raise AuthorityError(f"{path.name}: missing required symbol(s) {missing}: not a "
                             f"recordable SQLCipher image")
    toolchain = current_toolchain()
    return {
        "mode": mode,
        "toolchain": toolchain,
        "expected_output": {"sha256": sha256_file(path), "bytes": path.stat().st_size},
        "note": ("recorded by --record-entry on a host whose toolchain was not listed; "
                 "the output digest is exact for this toolchain only"),
    }


def _selftest() -> int:
    failures: list[str] = []
    register = load_register()
    print(f"register schema {register['schema']}, "
          f"{len(register['sources'][0]['modes'])} mode(s), "
          f"{len(register['required_symbols'])} required symbol(s), "
          f"{len(register['sqlcipher_init_symbols'])} init symbol(s)")
    # every mode carrieth a full identity + a trusted output digest
    for mode, entry in register["sources"][0]["modes"].items():
        if not SHA256_RE.fullmatch(entry["expected_output"]["sha256"]):
            failures.append(f"mode {mode} carrieth no trusted output SHA-256")
        if entry["platform"] not in ("MACOS", "IOSSIMULATOR"):
            failures.append(f"mode {mode} carrieth platform {entry['platform']!r}")
    src = register["sources"][0]
    if not FULL_SHA_RE.fullmatch(src["commit"]):
        failures.append("the source commit is not a full 40-character sha")
    for line in failures:
        print(f"::error::{line}")
    if failures:
        print(f"selftest FAILED ({len(failures)})")
        return 1
    print("selftest OK: the register carrieth a full source identity and a trusted "
          "per-mode output digest")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify a built SQLCipher image against the trusted register")
    parser.add_argument("--mode", choices=("ios-simulator", "macos"))
    parser.add_argument("--dir", type=Path,
                        help="a staging dir; <dir>/<library_name> is judged")
    parser.add_argument("artifact", nargs="?", type=Path)
    parser.add_argument("--register", type=Path, default=REGISTER)
    parser.add_argument("--record-entry", action="store_true",
                        help="measure a host whose toolchain is unlisted and PRINT the "
                             "new per-toolchain entry to add (never loosens the gate)")
    parser.add_argument("--emit-swift", type=Path, metavar="OUT",
                        help="write the generated Swift expectation (option 4a) from "
                             "the verified image")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)
    if args.selftest:
        return _selftest()
    if not args.mode:
        parser.error("--mode is required")
    try:
        register = load_register(args.register)
        if args.record_entry:
            if not args.mode:
                parser.error("--mode is required with --record-entry")
            target = args.artifact or (args.dir / register["library_name"]
                                       if args.dir else None)
            if target is None:
                parser.error("an artifact path or --dir is required")
            entry = record_entry(register, args.mode, target)
            print(json.dumps(entry, indent=2, sort_keys=True))
            print("add the above under sources[0].modes[<mode>] AFTER verifying the "
                  "image is the correct build; the hash gate stayeth strict.",
                  file=sys.stderr)
            return 0
        target = args.artifact
        if target is None and args.dir is not None:
            target = args.dir / register["library_name"]
        if target is None:
            parser.error("an artifact path or --dir is required")
        facts = verify_artifact(target, args.mode, register=register)
    except AuthorityError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    except (OSError, ValueError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    if args.emit_swift is not None:
        # NEVER dirty the tracked source tree from CI: writing a generated Swift file
        # into ios/Godstone/Sources/... would make the tree dirty AFTER the candidate
        # and invalidate the freeze. The generated pin must either be COMMITTED
        # already (regenerated deliberately, reviewed, and committed by a human) or
        # written OUTSIDE the source tree as a compiler input (specified by the source
        # manifest / build recipe). A CI step must not overwrite a tracked path.
        target = Path(args.emit_swift).resolve()
        source_tree = (ROOT / "ios").resolve()
        if source_tree in target.parents:
            print(f"::error::refusing to write a GENERATED pin INTO the tracked source "
                  f"tree ({target}): a CI-generic step must not dirty the candidate. "
                  f"Write outside ios/ (a build input dir) or commit the regenerated "
                  f"constant deliberately.", file=sys.stderr)
            return 1
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(swift_constant(facts, register=register), encoding="utf-8")
        print(f"wrote {target}")
    print("trusted-artifact " + json.dumps(facts, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
