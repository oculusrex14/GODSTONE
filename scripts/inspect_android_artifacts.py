#!/usr/bin/env python3
"""Archive-only release-artifact inspector (Stage 3 Phase I; A-17).

Inspects built Android release artifacts (APK / AAB) and FAILS iff the LIGHT
release is not Archive-only -- i.e. iff it contains the on-device model, the
non-shipping `:llm` native bridge, or a cross-tier asset. The LIGHT release must
link only `:core` (Archive repository + crypto); the on-device model / Oracle /
RAG graph (`:llm`, llama.cpp, the gguf model) is non-shipping.

Forbidden entry markers (an artifact whose namelist contains any of these FAILS):
  * `.gguf`                        -- any on-device model weight file
  * `libgodstone_llm`              -- the :llm JNI bridge (System.loadLibrary)
  * `libllama`, `libLlamaBridge`   -- llama.cpp / the iOS bridge, if present
  * `archive_medium`, `archive_large`, `qwen3-1.7`, `qwen3-4b` -- cross-tier

This is the "release binary inspection" half of A-17; the build-config half is
ci/check_shipping_path.py (forbids a shipping project(:llm) edge). The actual
LIGHT release artifact is built in a provisioned environment (Phase J / device
build); this inspector is runnable against any build root and has a --selftest
so the Archive-only contract is executable repo-side without a build.

Usage:
    python3 scripts/inspect_android_artifacts.py <build_root> <out_dir>
    python3 scripts/inspect_android_artifacts.py --selftest
"""
from __future__ import annotations
import argparse
import hashlib
import json
import tempfile
import zipfile
from pathlib import Path

# Cross-tier contamination (non-LIGHT archives / models).
CROSS_TIER_MARKERS = ("archive_medium", "archive_large", "qwen3-1.7", "qwen3-4b")
# The on-device model + the non-shipping :llm native bridge -- the Archive-only
# contract: the LIGHT release must NOT contain these.
ARCHIVE_ONLY_FORBIDDEN = (".gguf", "libgodstone_llm", "libllama", "libLlamaBridge")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _violations(names: list[str]) -> list[str]:
    """Forbidden entry names in an artifact's namelist."""
    out: list[str] = []
    low = {n.lower(): n for n in names}
    for marker in CROSS_TIER_MARKERS:
        for low_n, orig in low.items():
            if marker in low_n:
                out.append(f"cross-tier asset contamination: {orig}")
    for marker in ARCHIVE_ONLY_FORBIDDEN:
        for low_n, orig in low.items():
            if marker in low_n:
                out.append(f"non-Archive-only entry present ({marker}): {orig}")
    return out


def inspect(build_root: Path, out: Path) -> tuple[int, list[dict]]:
    """Inspect every APK/AAB under build_root. Returns (rc, inventory)."""
    artifacts = sorted(list(build_root.rglob("*.apk")) + list(build_root.rglob("*.aab")))
    if not artifacts:
        print("no APK/AAB artifacts found")
        return 1, []
    out.mkdir(parents=True, exist_ok=True)
    inventory: list[dict] = []
    for artifact in artifacts:
        with zipfile.ZipFile(artifact) as zf:
            names = sorted(zf.namelist())
        bad = _violations(names)
        if bad:
            print(f"Archive-only inspection FAILED for {artifact}:")
            for b in bad:
                print(f"  - {b}")
            return 1, []
        inventory.append({"path": str(artifact), "bytes": artifact.stat().st_size,
                          "sha256": digest(artifact), "entries": names})
    (out / "artifact-inventory.json").write_text(
        json.dumps(inventory, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0, inventory


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("build_root", type=Path, nargs="?", default=None)
    parser.add_argument("out", type=Path, nargs="?", default=None)
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        return selftest()
    if args.build_root is None or args.out is None:
        parser.error("build_root and out are required (or use --selftest)")
    rc, _inv = inspect(args.build_root, args.out)
    if rc == 0:
        print(f"Archive-only inspection PASSED: {len(_inv)} artifact(s) free of model/:llm/cross-tier entries")
    return rc


def selftest() -> int:
    """Build synthetic APK zips and assert the Archive-only contract."""
    failures: list[str] = []

    def make_apk(path: Path, entries: dict[str, bytes]) -> None:
        with zipfile.ZipFile(path, "w") as zf:
            for name, data in entries.items():
                zf.writestr(name, data)

    def expect_pass(desc: str, entries: dict[str, bytes]) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            make_apk(root / "app-light-release.apk", entries)
            rc, _inv = inspect(root, root / "out")
            if rc != 0:
                failures.append(f"[{desc}] expected PASS, got FAIL")

    def expect_fail(desc: str, entries: dict[str, bytes]) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            make_apk(root / "app-light-release.apk", entries)
            rc, _inv = inspect(root, root / "out")
            if rc == 0:
                failures.append(f"[{desc}] expected FAIL, got PASS")

    # Clean Archive-only APK: archive db + dex + core native (no model, no :llm).
    expect_pass("clean Archive-only APK", {
        "classes.dex": b"",
        "assets/archive_light.db": b"",
        "lib/arm64-v8a/libcore.so": b"",
    })

    # Dirty: the on-device model gguf ships -> FAIL.
    expect_fail("model gguf present", {
        "classes.dex": b"",
        "assets/qwen3-0.6b-q4km.gguf": b"",
    })
    # Dirty: the :llm JNI bridge ships -> FAIL.
    expect_fail(":llm native bridge present", {
        "classes.dex": b"",
        "lib/arm64-v8a/libgodstone_llm.so": b"",
    })
    # Dirty: llama.cpp native lib ships -> FAIL.
    expect_fail("llama.cpp native lib present", {
        "classes.dex": b"",
        "lib/arm64-v8a/libllama.so": b"",
    })
    # Dirty: cross-tier MEDIUM archive ships -> FAIL.
    expect_fail("cross-tier archive_medium present", {
        "classes.dex": b"",
        "assets/archive_medium.db": b"",
    })
    # No artifacts -> FAIL (inspection could not run).
    with tempfile.TemporaryDirectory() as td:
        rc, _inv = inspect(Path(td), Path(td) / "out")
        if rc == 0:
            failures.append("[no artifacts] expected FAIL, got PASS")

    if failures:
        print("inspect_android_artifacts selftest FAILED:")
        for f in failures:
            print("  - " + f)
        return 1
    print("inspect_android_artifacts selftest PASSED: clean Archive-only APK passes; model/:llm/llama/cross-tier all rejected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())