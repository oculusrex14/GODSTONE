#!/usr/bin/env python3
"""Fail-fast Android toolchain preflight.

Runs BEFORE Gradle. Every failure here is an *environment* problem (missing or
wrong toolchain), printed with an ``ENV:`` prefix and a distinct exit code, so
the Phase 0 runner can stop without ever invoking Gradle -- and therefore can
never mislabel an environment failure as a source-code test failure.

Distinguished failures (exit codes):
    2  missing JDK
    3  wrong Java version
    4  missing Android SDK
    5  missing platform / build-tools
    6  wrapper JAR checksum failure
    7  Gradle distribution checksum not pinned (wrapper properties)
    8  Gradle distribution unavailable offline   (--offline only)
    9  missing CMake / NDK                       (--require-native only)
   10  wrapper properties missing / unreadable

The NDK is pinned to an exact version (``EXPECTED_NDK``); a present-but-wrong
NDK version is reported as ``missing_native_tools``, not accepted.

Usage:
    python3 scripts/check_android_toolchain.py [--offline] [--require-native]
                                               [--selftest]

``--offline``         require the Gradle 8.9 distribution to already be cached
                      locally (offline-preprovisioned mode). Without it, a missing
                      distribution is a NOTE, not a failure (online bootstrap will
                      download it).
``--require-native``  treat a missing/wrong CMake/NDK as a failure (needed when the
                      native :llm build is assembled, and by the Phase 0 runner so
                      the pinned NDK is verified on every provisioned machine). By
                      default it is a warning, because the Phase 0 JVM test path
                      does not compile native code.
``--selftest``        exercise every failure branch against synthetic inputs and
                      report which fire, then exit 0. Proves the branches have teeth.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# --- Contract constants (mirror docs/production/ANDROID_TOOLCHAIN_CONTRACT.md) ---
EXPECTED_GRADLE = "8.9"
EXPECTED_DIST_SHA = "d725d707bfabd4dfdc958c624003b3c80accc03f7037b5122c4b1d0ef15cecab"
EXPECTED_WRAPPER_JAR_SHA = (
    "498495120a03b9a6ab5d155f5de3c8f0d986a449153702fb80fc80e134484f17"
)
EXPECTED_JAVA_MAJOR = 17
EXPECTED_COMPILE_SDK = 35
EXPECTED_BUILD_TOOLS = "35.0.0"
EXPECTED_CMAKE = "3.22.1"
# NDK r27b; the exact version AGP 8.6.0 selects as its bundled default on this
# host. Pinned so the native build is reproducible across local + CI machines.
EXPECTED_NDK = "27.0.12077973"

EXIT = {
    "ok": 0,
    "missing_jdk": 2,
    "wrong_java": 3,
    "missing_sdk": 4,
    "missing_platform_bt": 5,
    "wrapper_jar_checksum": 6,
    "dist_not_pinned": 7,
    "dist_offline_unavailable": 8,
    "missing_native_tools": 9,
    "wrapper_props_unreadable": 10,
}

ROOT = Path(__file__).resolve().parents[1]
WRAPPER_PROPS = ROOT / "android" / "gradle" / "wrapper" / "gradle-wrapper.properties"
WRAPPER_JAR = ROOT / "android" / "gradle" / "wrapper" / "gradle-wrapper.jar"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def find_java_home() -> Path | None:
    jh = os.environ.get("JAVA_HOME")
    if jh:
        p = Path(jh)
        if (p / "bin" / "java").exists() or (p / "bin" / "java.exe").exists():
            return p
    which = shutil.which("java")
    if which:
        # Resolve the real path; JAVA_HOME is the parent of bin/.
        return Path(which).resolve().parent.parent
    return None


def java_major_version(java_home: Path) -> int | None:
    java = java_home / "bin" / "java"
    if not java.exists():
        java = java_home / "bin" / "java.exe"
    try:
        out = subprocess.run(
            [str(java), "-version"],
            capture_output=True, text=True, timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    blob = (out.stderr or "") + (out.stdout or "")
    # openjdk version "17.0.10" / version "17" / "1.8.0_362" (legacy 8)
    m = re.search(r'version "(\d+)(?:\.|")', blob)
    if not m:
        return None
    major = int(m.group(1))
    # Legacy scheme: "1.8" => major 8.
    if major == 1:
        m2 = re.search(r'version "1\.(\d+)', blob)
        return int(m2.group(1)) if m2 else None
    return major


def find_sdk() -> Path | None:
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if sdk and Path(sdk).is_dir():
        return Path(sdk)
    return None


def gradle_dist_cached() -> bool:
    """True iff the pinned Gradle distribution is extracted in the local cache."""
    home = Path(os.environ.get("GRADLE_USER_HOME", str(Path.home() / ".gradle")))
    dists = home / "wrapper" / "dists"
    if not dists.is_dir():
        return False
    for entry in dists.glob("gradle-8.9-bin/*"):
        if entry.is_dir() and (entry / "gradle-8.9" / "bin" / "gradle").exists():
            return True
    return False


def parse_wrapper_props() -> dict[str, str]:
    props: dict[str, str] = {}
    for line in WRAPPER_PROPS.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        props[k.strip()] = v.strip().replace("\\:", ":")
    return props


# --- Individual checks. Each returns (ok, category_or_None, detail). ----------

def check_jdk() -> tuple[bool, str | None, str]:
    jh = find_java_home()
    if jh is None:
        return False, "missing_jdk", "no JAVA_HOME and no java on PATH"
    major = java_major_version(jh)
    if major is None:
        return False, "missing_jdk", f"JAVA_HOME={jh} but `java -version` could not be parsed"
    if major != EXPECTED_JAVA_MAJOR:
        return False, "wrong_java", f"Java {major} found, need Java {EXPECTED_JAVA_MAJOR}"
    return True, None, f"Java {major} at {jh}"


def check_sdk() -> tuple[bool, str | None, str]:
    sdk = find_sdk()
    if sdk is None:
        return False, "missing_sdk", "neither ANDROID_HOME nor ANDROID_SDK_ROOT is set to a directory"
    return True, None, f"SDK at {sdk}"


def check_platform_build_tools(sdk: Path) -> tuple[bool, str | None, str]:
    plat = sdk / "platforms" / f"android-{EXPECTED_COMPILE_SDK}"
    bt = sdk / "build-tools" / EXPECTED_BUILD_TOOLS
    missing = []
    if not plat.is_dir():
        missing.append(f"platforms;android-{EXPECTED_COMPILE_SDK} ({plat})")
    if not bt.is_dir():
        missing.append(f"build-tools;{EXPECTED_BUILD_TOOLS} ({bt})")
    if missing:
        return False, "missing_platform_bt", "; ".join(missing)
    return True, None, f"platform android-{EXPECTED_COMPILE_SDK} + build-tools {EXPECTED_BUILD_TOOLS}"


def check_wrapper_props() -> tuple[bool, str | None, str]:
    if not WRAPPER_PROPS.is_file():
        return False, "wrapper_props_unreadable", str(WRAPPER_PROPS)
    try:
        props = parse_wrapper_props()
    except OSError as e:
        return False, "wrapper_props_unreadable", str(e)
    sha = props.get("distributionSha256Sum")
    url = props.get("distributionUrl", "")
    if not sha:
        return False, "dist_not_pinned", "distributionSha256Sum is absent from gradle-wrapper.properties"
    if sha != EXPECTED_DIST_SHA:
        return False, "dist_not_pinned", (
            f"distributionSha256Sum={sha} != contract {EXPECTED_DIST_SHA}"
        )
    if "validateDistributionUrl=true" not in WRAPPER_PROPS.read_text(encoding="utf-8"):
        return False, "dist_not_pinned", "validateDistributionUrl is not true"
    return True, None, f"Gradle {EXPECTED_GRADLE} distribution pinned ({url})"


def check_wrapper_jar() -> tuple[bool, str | None, str]:
    if not WRAPPER_JAR.is_file():
        return False, "wrapper_jar_checksum", f"missing {WRAPPER_JAR}"
    actual = sha256(WRAPPER_JAR)
    if actual != EXPECTED_WRAPPER_JAR_SHA:
        return False, "wrapper_jar_checksum", (
            f"gradle-wrapper.jar sha256={actual} != expected {EXPECTED_WRAPPER_JAR_SHA}"
        )
    return True, None, "gradle-wrapper.jar checksum matches"


def check_dist_offline() -> tuple[bool, str | None, str]:
    if gradle_dist_cached():
        return True, None, "Gradle 8.9 distribution present in local cache"
    return False, "dist_offline_unavailable", (
        "Gradle 8.9 distribution not extracted under GRADLE_USER_HOME/wrapper/dists; "
        "run once online to populate the cache, or provision it offline"
    )


def check_native_tools(sdk: Path) -> tuple[bool, str | None, str]:
    cmake = sdk / "cmake" / EXPECTED_CMAKE / "bin" / "cmake"
    ndk_dir = sdk / "ndk" / EXPECTED_NDK
    missing = []
    if not cmake.exists():
        missing.append(f"cmake;{EXPECTED_CMAKE} ({cmake})")
    if not ndk_dir.is_dir():
        # Report any other NDK versions present so a wrong-version host is
        # diagnosed as a pin mismatch, not a silent acceptance.
        others = sorted(p.name for p in (sdk / "ndk").glob("*")) if (sdk / "ndk").is_dir() else []
        if others:
            missing.append(
                f"ndk;{EXPECTED_NDK} (found {', '.join(others)} -- version pin mismatch)"
            )
        else:
            missing.append(f"ndk;{EXPECTED_NDK} (no sdk/ndk/{EXPECTED_NDK} directory)")
    if missing:
        return False, "missing_native_tools", "; ".join(missing)
    return True, None, f"cmake {EXPECTED_CMAKE} + ndk {EXPECTED_NDK}"


# --- Driver -------------------------------------------------------------------

def run_checks(require_native: bool, offline: bool) -> int:
    # JDK
    ok, cat, detail = check_jdk()
    if not ok:
        return fail(cat, detail)
    print(f"  ok   JDK: {detail}")

    # SDK
    ok, cat, detail = check_sdk()
    if not ok:
        return fail(cat, detail)
    print(f"  ok   SDK: {detail}")
    sdk = Path(os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT"))  # type: ignore[arg-type]

    # platform / build-tools
    ok, cat, detail = check_platform_build_tools(sdk)
    if not ok:
        return fail(cat, detail)
    print(f"  ok   platform/build-tools: {detail}")

    # wrapper properties (distribution checksum pinned)
    ok, cat, detail = check_wrapper_props()
    if not ok:
        return fail(cat, detail)
    print(f"  ok   wrapper properties: {detail}")

    # wrapper JAR checksum
    ok, cat, detail = check_wrapper_jar()
    if not ok:
        return fail(cat, detail)
    print(f"  ok   wrapper JAR: {detail}")

    # native tools (warning unless --require-native)
    ok, cat, detail = check_native_tools(sdk)
    if not ok:
        if require_native:
            return fail(cat, detail)
        print(f"  warn native tools (not required for JVM Phase 0): {detail}")
    else:
        print(f"  ok   native tools: {detail}")

    # Gradle distribution offline availability
    if offline:
        ok, cat, detail = check_dist_offline()
        if not ok:
            return fail(cat, detail)
        print(f"  ok   dist (offline): {detail}")
    else:
        if gradle_dist_cached():
            print("  ok   dist: Gradle 8.9 distribution present in local cache")
        else:
            print("  note dist: Gradle 8.9 not in local cache (online bootstrap will download it)")

    print("ENV: toolchain preflight passed")
    return 0


def fail(category: str, detail: str) -> int:
    code = EXIT[category]
    print(f"ENV: {category.replace('_', ' ')}: {detail}")
    print(f"ENV: toolchain preflight FAILED (exit {code}). This is an environment "
          f"problem, not a source-code test failure.")
    return code


# --- Selftest ------------------------------------------------------------------

def selftest() -> int:
    """Exercise each failure branch against synthetic inputs; report which fire."""
    print("selftest: exercising failure branches (none should be skipped)...")
    fired: list[str] = []

    # missing_jdk: no JAVA_HOME, no java on PATH
    old_jh = os.environ.pop("JAVA_HOME", None)
    old_path = os.environ.get("PATH", "")
    os.environ["PATH"] = "/nonexistent"
    ok, cat, _ = check_jdk()
    if not ok and cat == "missing_jdk":
        fired.append("missing_jdk")
    os.environ["PATH"] = old_path
    if old_jh is not None:
        os.environ["JAVA_HOME"] = old_jh

    # missing_sdk
    os.environ.pop("ANDROID_HOME", None)
    os.environ.pop("ANDROID_SDK_ROOT", None)
    ok, cat, _ = check_sdk()
    if not ok and cat == "missing_sdk":
        fired.append("missing_sdk")
    # missing_platform_bt against an empty SDK dir
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        os.environ["ANDROID_HOME"] = d
        sdk = Path(d)
        ok, cat, _ = check_platform_build_tools(sdk)
        if not ok and cat == "missing_platform_bt":
            fired.append("missing_platform_bt")
        ok, cat, _ = check_native_tools(sdk)
        if not ok and cat == "missing_native_tools":
            fired.append("missing_native_tools")
        # wrong NDK version: an ndk dir with a different version name must
        # fire missing_native_tools (version pin mismatch), not pass.
        wrong_ndk = sdk / "ndk" / "99.0.00000000"
        wrong_ndk.mkdir(parents=True)
        ok, cat, detail = check_native_tools(sdk)
        if not ok and cat == "missing_native_tools" and "pin mismatch" in detail:
            fired.append("missing_native_tools (wrong ndk version)")

    # dist_not_pinned: feed a properties blob without distributionSha256Sum
    global WRAPPER_PROPS
    import tempfile  # noqa: E402
    with tempfile.NamedTemporaryFile("w", suffix=".properties", delete=False) as t:
        t.write("distributionUrl=https\\://services.gradle.org/distributions/gradle-8.9-bin.zip\n")
        t.write("validateDistributionUrl=true\n")
        tmp_props = Path(t.name)
    saved = WRAPPER_PROPS
    WRAPPER_PROPS = tmp_props
    ok, cat, _ = check_wrapper_props()
    if not ok and cat == "dist_not_pinned":
        fired.append("dist_not_pinned")
    # wrong checksum
    with open(tmp_props, "w") as f:
        f.write("distributionSha256Sum=deadbeef\n")
        f.write("validateDistributionUrl=true\n")
    ok, cat, _ = check_wrapper_props()
    if not ok and cat == "dist_not_pinned":
        fired.append("dist_not_pinned (wrong checksum)")
    WRAPPER_PROPS = saved
    tmp_props.unlink(missing_ok=True)

    # wrapper_jar_checksum: point at a non-wrapper file
    global WRAPPER_JAR
    saved_jar = WRAPPER_JAR
    WRAPPER_JAR = Path(__file__)  # this script is not the wrapper jar
    ok, cat, _ = check_wrapper_jar()
    if not ok and cat == "wrapper_jar_checksum":
        fired.append("wrapper_jar_checksum")
    WRAPPER_JAR = saved_jar

    # dist_offline_unavailable: bogus GRADLE_USER_HOME
    old_guh = os.environ.pop("GRADLE_USER_HOME", None)
    os.environ["GRADLE_USER_HOME"] = "/nonexistent/gradle-home"
    ok, cat, _ = check_dist_offline()
    if not ok and cat == "dist_offline_unavailable":
        fired.append("dist_offline_unavailable")
    if old_guh is not None:
        os.environ["GRADLE_USER_HOME"] = old_guh
    else:
        os.environ.pop("GRADLE_USER_HOME", None)

    # wrong_java: synthesise a JDK home + wrong major version. Patching
    # __main__'s globals (where check_jdk resolves them) makes this
    # host-independent -- it fires even on a machine with no JDK installed.
    import __main__ as self_mod  # type: ignore
    orig_find = self_mod.find_java_home
    orig_java = self_mod.java_major_version
    self_mod.find_java_home = lambda: Path("/fake/jdk")  # type: ignore
    self_mod.java_major_version = lambda _jh: 11  # type: ignore
    ok, cat, _ = check_jdk()
    if not ok and cat == "wrong_java":
        fired.append("wrong_java")
    self_mod.find_java_home = orig_find  # type: ignore
    self_mod.java_major_version = orig_java  # type: ignore

    expected_branches = {
        "missing_jdk", "wrong_java", "missing_sdk", "missing_platform_bt",
        "wrapper_jar_checksum", "dist_not_pinned", "dist_offline_unavailable",
        "missing_native_tools",
    }
    print("selftest fired branches:")
    for b in fired:
        print(f"  - {b}")
    got = set(fired)
    # 'dist_not_pinned' and 'dist_not_pinned (wrong checksum)' both map to the category
    got_categories = {b.split(" (")[0] for b in got}
    missing = expected_branches - got_categories
    if missing:
        print(f"selftest: branches did NOT fire: {sorted(missing)}")
        return 1
    print("selftest: all failure branches fire correctly")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    ap.add_argument("--offline", action="store_true",
                    help="require the Gradle distribution to be cached locally")
    ap.add_argument("--require-native", action="store_true",
                    help="treat missing CMake/NDK as a failure")
    ap.add_argument("--selftest", action="store_true",
                    help="exercise every failure branch against synthetic inputs")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    return run_checks(require_native=args.require_native, offline=args.offline)


if __name__ == "__main__":
    raise SystemExit(main())