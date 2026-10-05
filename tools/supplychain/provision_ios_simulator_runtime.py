#!/usr/bin/env python3
"""Provision the MEASURED iOS Simulator runtime (and a device bound to it) the
simulator lane will resolve -- so the lane no longer inherits whatever runtime
the runner image happens to ship as its newest.

    tools/supplychain/provision_ios_simulator_runtime.py [--pins PATH] [--github-env PATH]

WHY THIS EXISTS
---------------
The simulator lane (`tools/readiness/run_ios_simulator_lane.sh`) picks the newest
available iPhone when `GS_SIM` is unset, so on a hosted image that ships ONLY a
newer runtime the lane resolves THAT runtime's root -- and the stock SQLite
oracle (`tools/supplychain/stage_stock_sqlite.sh`) then stages whatever that
runtime carrieth. Where that runtime packs its SQLite into the dyld shared cache
rather than a plain `usr/lib/libsqlite3.dylib` on disk, the stager's fail-closed
guard reddens the lane. *MEASURED, hosted run `37266700328`: the iOS 27 cryptex
RuntimeRoot carried no plain `usr/lib/libsqlite3.dylib`, while the iOS 26.3
profile root DID.*

This script CLOSES that by choosing a runtime DELIBERATELY rather than by
newness: it reads the ONE registered measured runtime identity from
`docs/supplychain/STOCK_SQLITE.pins.json`, inspects `xcrun simctl list runtimes
--json`, and:

  1. if the EXACT runtime (identifier + version + build + platform + arch +
     device type) is already installed and available, USES IT -- no runtime
     download (the local host carrieth it; a device may still be created for
     the lane);
  2. otherwise installs exactly that runtime with the actual `xcodebuild
     -downloadPlatform iOS -buildVersion <version> -architectureVariant arm64`
     CLI, then re-reads the installed state and RE-VALIDATES it rather than
     trusting the download's exit status;
  3. reuses (or, if absent, creates) ONE uniquely named device bound to that
     runtime, and emits its NAME through `$GITHUB_ENV` as `GS_SIM` for the
     committed lane -- the lane's parser (`grep -F "$SIM ("` under the runtime's
     group header) then resolves THIS device and THIS runtime root.

NO FALLBACK RUNTIME, NO SILENT 'LATEST'. *A missing Apple asset stays a FAILED
PROVISION: the download's non-zero status is propagated, and an installed
runtime that does not match the register exactly is refused by name.*
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PINS = REPO_ROOT / "docs" / "supplychain" / "STOCK_SQLITE.pins.json"
REGISTER_KEY = "simulator_runtime"
REQUIRED_KEYS = (
    "runtime_identifier",
    "version",
    "build",
    "platform",
    "architecture",
    "device_type_identifier",
    "device_name",
)


class ProvisionError(RuntimeError):
    """A NAMED refusal, so a red step names its cause rather than a bare traceback."""


def _run(argv: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(argv, capture_output=True, text=True)


def _simctl_json(*args: str) -> dict:
    """`xcrun simctl list <kind> --json`, parsed; a non-zero status is refused by name."""
    proc = _run(["xcrun", "simctl", "list", *args, "--json"])
    if proc.returncode != 0:
        raise ProvisionError(
            f"`xcrun simctl list {' '.join(args)} --json` exited {proc.returncode}: "
            f"{proc.stderr.strip() or proc.stdout.strip()}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:  # pragma: no cover - defensive
        raise ProvisionError(f"simctl emitted non-JSON for `list {' '.join(args)}`: {exc}") from exc


def read_register(path: Path) -> dict:
    if not path.is_file():
        raise ProvisionError(f"the stock register is absent: {path}")
    doc = json.loads(path.read_text(encoding="utf-8"))
    entry = doc.get(REGISTER_KEY)
    if not isinstance(entry, dict):
        raise ProvisionError(
            f"the register carrieth no `{REGISTER_KEY}` object; the measured runtime "
            f"identity has no single authority")
    missing = [k for k in REQUIRED_KEYS if not entry.get(k)]
    if missing:
        raise ProvisionError(
            f"the register's `{REGISTER_KEY}` omits {missing}; every identity field is required")
    return entry


def find_runtime(entry: dict) -> dict | None:
    """The registered runtime IF it is installed AND matches EVERY declared identity field."""
    runtimes = _simctl_json("runtimes").get("runtimes", [])
    for rt in runtimes:
        if rt.get("identifier") != entry["runtime_identifier"]:
            continue
        reasons = []
        if rt.get("version") != entry["version"]:
            reasons.append(f"version {rt.get('version')!r} != {entry['version']!r}")
        if rt.get("buildversion") != entry["build"]:
            reasons.append(f"build {rt.get('buildversion')!r} != {entry['build']!r}")
        if rt.get("platform") != entry["platform"]:
            reasons.append(f"platform {rt.get('platform')!r} != {entry['platform']!r}")
        if not rt.get("isAvailable"):
            reasons.append("isAvailable is not true")
        archs = rt.get("supportedArchitectures") or []
        if entry["architecture"] not in archs:
            reasons.append(f"architecture {entry['architecture']!r} not in {archs}")
        dtypes = {d.get("identifier") for d in (rt.get("supportedDeviceTypes") or [])}
        if entry["device_type_identifier"] not in dtypes:
            reasons.append(
                f"device type {entry['device_type_identifier']!r} not supported by this runtime")
        if reasons:
            raise ProvisionError(
                "*** the installed runtime "
                f"{entry['runtime_identifier']} MATCHES BY ID BUT NOT BY IDENTITY: "
                + "; ".join(reasons)
                + ". A runtime that is not the measured one is refused, never substituted. ***")
        return rt
    return None


def provision_runtime(entry: dict) -> dict:
    """Use the installed runtime, or install EXACTLY the registered one and re-validate."""
    runtime = find_runtime(entry)
    if runtime is not None:
        print(f"ios-simulator-runtime: using already-installed {entry['runtime_identifier']} "
              f"({entry['version']} - {entry['build']}), no download")
        return runtime

    if shutil.which("xcodebuild") is None:
        raise ProvisionError("xcodebuild is absent; cannot install the registered runtime")
    argv = [
        "xcodebuild", "-downloadPlatform", entry["platform"],
        "-buildVersion", entry["version"],
        "-architectureVariant", entry["architecture"],
    ]
    print(f"ios-simulator-runtime: installing {entry['version']} "
          f"({entry['architecture']}) via: {' '.join(argv)}")
    # *** THE DOWNLOAD STREAMS TO THE JOB'S OWN STDOUT/STDERR (no capture_output): a potentially long
    # xcodebuild download exposes REAL progress rather than being buffered whole and reprinted. ***
    proc = subprocess.run(argv)
    if proc.returncode != 0:
        # NO RETRY, NO SUBSTITUTION: a missing Apple asset is a FAILED PROVISION.
        raise ProvisionError(
            f"`xcodebuild -downloadPlatform {entry['platform']} -buildVersion {entry['version']}` "
            f"exited {proc.returncode}; the measured runtime asset is unavailable -- this is a "
            f"FAILED PROVISION, not a cue to pick another runtime")

    # Re-read the ACTUAL installed state (the exit status alone is not the identity).
    runtime = find_runtime(entry)
    if runtime is None:
        raise ProvisionError(
            f"after installing, {entry['runtime_identifier']} is still not a registered, available "
            f"runtime; the download did not produce the measured runtime")
    return runtime


def ensure_device(entry: dict) -> str:
    """Reuse the ONE uniquely named device bound to the registered runtime, else create it."""
    name = entry["device_name"]
    devices = _simctl_json("devices").get("devices", {})
    # *** THE NAME IS THIS PROVISIONER'S TO OWN: IT MUST IDENTIFY EXACTLY ONE DEVICE. *** *The lane
    # resolves by NAME and taketh the FIRST `$SIM (` hit, so two same-named devices -- across
    # runtimes or within one -- could bind the run to the WRONG runtime's root. A duplicate is
    # REFUSED, never first-won.*
    matches: list[tuple[str, dict]] = [
        (rt, dev)
        for rt, devs in devices.items()
        for dev in devs
        if dev.get("name") == name
    ]
    if len(matches) > 1:
        found = "; ".join(f"{rt}:{dev.get('udid')}" for rt, dev in matches)
        raise ProvisionError(
            f"the device name {name!r} is AMBIGUOUS -- it nameth {len(matches)} devices ({found}); "
            f"the lane would take the first match and could bind the wrong runtime")
    if matches:
        rt, dev = matches[0]
        reasons = []
        if rt != entry["runtime_identifier"]:
            reasons.append(f"runtime {rt!r} != {entry['runtime_identifier']!r}")
        if not dev.get("isAvailable"):
            reasons.append("isAvailable is not true")
        if dev.get("deviceTypeIdentifier") != entry["device_type_identifier"]:
            reasons.append(f"deviceTypeIdentifier {dev.get('deviceTypeIdentifier')!r} != "
                           f"{entry['device_type_identifier']!r}")
        if reasons:
            # Refuse rather than rebind or delete -- the name is this provisioner's to own.
            raise ProvisionError(
                f"the device named {name!r} is not the registered one: " + "; ".join(reasons)
                + "; refusing to reuse or rebind it")
        print(f"ios-simulator-runtime: reusing device {name!r} ({dev.get('udid')}) on {rt} "
              f"({entry['version']} - {entry['build']})")
        return name

    proc = _run(["xcrun", "simctl", "create", name,
                 entry["device_type_identifier"], entry["runtime_identifier"]])
    if proc.returncode != 0:
        raise ProvisionError(
            f"`xcrun simctl create {name!r} {entry['device_type_identifier']} "
            f"{entry['runtime_identifier']}` exited {proc.returncode}: {proc.stderr.strip()}")
    udid = proc.stdout.strip()
    # *** THE CONFIRMATION READS THE ACTUAL INSTALLED STATE, NOT THE CREATE CALL'S STATUS: *** *the
    # created device must REALLY be the registered one -- by udid, NAME, DEVICE TYPE and AVAILABILITY
    # under the registered runtime key. A create that returned zero while landing a differently
    # typed or unavailable device is refused.*
    devices = _simctl_json("devices").get("devices", {})
    for dev in devices.get(entry["runtime_identifier"], []):
        if (dev.get("udid") == udid and dev.get("name") == name
                and dev.get("deviceTypeIdentifier") == entry["device_type_identifier"]
                and dev.get("isAvailable")):
            print(f"ios-simulator-runtime: created device {name!r} ({udid}) "
                  f"on {entry['runtime_identifier']} ({entry['version']} - {entry['build']})")
            return name
    raise ProvisionError(
        f"the created device did not land as the registered one under "
        f"{entry['runtime_identifier']}: udid={udid!r}, name={name!r}, "
        f"type={entry['device_type_identifier']!r}, availability required")


def emit_env(device_name: str, github_env: str | None) -> None:
    """Export the ONE variable the committed lane consumes; the selected runtime is already
    recorded by the status messages above, so no GS_SIM_RUNTIME_* variable is invented."""
    line = f"GS_SIM={device_name}"
    if github_env:
        with open(github_env, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    print(line)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pins", default=str(DEFAULT_PINS),
                    help="the supply-chain register that carrieth the measured runtime identity")
    ap.add_argument("--github-env", default=os.environ.get("GITHUB_ENV") or None,
                    help="append GS_SIM (defaults to $GITHUB_ENV when set)")
    args = ap.parse_args(argv)
    try:
        if shutil.which("xcrun") is None:
            raise ProvisionError("xcrun is absent; the simulator runtime cannot be inspected or bound")
        entry = read_register(Path(args.pins))
        provision_runtime(entry)
        device_name = ensure_device(entry)
        emit_env(device_name, args.github_env)
    except ProvisionError as exc:
        print(f"::error::*** {exc} ***", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
