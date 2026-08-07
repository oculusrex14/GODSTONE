#!/usr/bin/env python3
"""Dormant-wire technical-debt inventory (NOT a gate).

Companion to ci/check_shipping_path.py. Where the gate proves the LIGHT
*shipping* path is free of legacy Mesh / GMP-1 wire, this script reports the
*compile-excluded* legacy and future-feature sources that still live in the
tree. It is deliberately NON-PASSING: it does not return a pass/fail verdict
and always exits 0. It is an inventory of technical debt.

IMPORTANT -- what this inventory is NOT:
  * It is NOT proof of GMP/2.1. Listing dormant Mesh sources does not mean the
    Android and iOS mesh runtimes share a canonical frame path.
  * It does NOT close A-01 (docs/AUDIT.md). A-01 requires generated GMP/2.1
    routers/stores plus a golden cross-device round trip. A-01 remains OPEN.

Dormant sources reported:
  Android:
    - :app main sources matching a ``java.exclude(...)`` glob (mesh/sos) -- not
      compiled into the LIGHT :app. These live under ``src/main/dormant/java``
      (KGP auto-wires ``src/main/{java,kotlin}`` only, so that directory is not
      a compile source), and the gate scans it as dormant debt.
    - the separate ``:mesh`` module main sources -- not a dependency of :app.
  iOS:
    - ``.swift`` files under ios/Godstone/Sources/App/ that are NOT on the
      application target's ``sources:`` allowlist in ios/project.yml.
    - the separate ``GodstoneMesh`` product sources -- not a dependency of the
      LIGHT app.

Usage:
    python3 ci/inventory_dormant_wire.py [--root DIR] [--selftest]
"""
from __future__ import annotations

import argparse
import sys
import tempfile
from pathlib import Path

# Reuse the build-config parsers from the gate so "included" vs "excluded" is
# decided by the same build-config evidence (single source of truth).
from check_shipping_path import (  # noqa: E402  (sibling module in ci/)
    SOURCE_SUFFIXES,
    android_exclude_globs,
    android_excluded_sources,
    android_project_deps,
    parse_ios_app_target,
)

MESH_DIR_NAMES = {"mesh", "sos"}


def android_excluded_app_sources(root: Path) -> list[tuple[Path, str]]:
    """:app main sources that a java.exclude glob removes from the LIGHT build.

    Delegates to check_shipping_path.android_excluded_sources so "included" vs
    "excluded" is decided by the same build-config evidence (single source of
    truth). The dormant files live under src/main/dormant/java (see
    ANDROID_SOURCE_ROOTS in check_shipping_path).
    """
    gradle = root / "android/app/build.gradle.kts"
    excludes = android_exclude_globs(gradle)
    excluded = android_excluded_sources(root / "android/app/src/main", excludes)
    return [(p, f'excluded from :app LIGHT by java.exclude("{g}")') for p, g in excluded]


def android_mesh_module_sources(root: Path) -> list[tuple[Path, str]]:
    """Separate :mesh module main sources (not a dependency of :app)."""
    app_deps = set(android_project_deps(root / "android/app/build.gradle.kts"))
    mesh_main = root / "android/mesh/src/main"
    out: list[tuple[Path, str]] = []
    if not mesh_main.is_dir():
        return out
    edge = "not a dependency of :app" if "mesh" not in app_deps else "WARNING: :app depends on :mesh"
    for path in sorted(mesh_main.rglob("*")):
        if path.is_file() and path.suffix in SOURCE_SUFFIXES:
            out.append((path, f":mesh module main source ({edge})"))
    return out


def ios_excluded_app_sources(root: Path) -> list[tuple[Path, str]]:
    """.swift files under Sources/App/ not on the application target allowlist."""
    project_yml = root / "ios/project.yml"
    allowlist, _deps = parse_ios_app_target(project_yml)
    allow_basenames = {Path(s).name for s in allowlist}
    app_dir = project_yml.parent / "Godstone/Sources/App"
    out: list[tuple[Path, str]] = []
    if not app_dir.is_dir():
        return out
    for path in sorted(app_dir.rglob("*")):
        if path.is_file() and path.suffix == ".swift" and path.name not in allow_basenames:
            out.append((path, "not on application target sources allowlist (ios/project.yml)"))
    return out


def ios_godstonemesh_product_sources(root: Path) -> list[tuple[Path, str]]:
    """Separate GodstoneMesh product sources (not a dependency of the LIGHT app)."""
    project_yml = root / "ios/project.yml"
    _srcs, deps = parse_ios_app_target(project_yml)
    edge = "not a dependency of the LIGHT app" if not any(p == "GodstoneMesh" for _, p in deps) \
        else "WARNING: LIGHT app depends on GodstoneMesh"
    mesh_dir = project_yml.parent / "Godstone/Sources/GodstoneMesh"
    out: list[tuple[Path, str]] = []
    if not mesh_dir.is_dir():
        return out
    for path in sorted(mesh_dir.rglob("*")):
        if path.is_file() and path.suffix == ".swift":
            out.append((path, f"GodstoneMesh product source ({edge})"))
    return out


def build_inventory(root: Path) -> list[tuple[str, str, str]]:
    """Return [(category, repo-relative path, reason)]."""
    items: list[tuple[str, str, str]] = []
    for p, reason in android_excluded_app_sources(root):
        items.append(("android: excluded :app source", p.relative_to(root).as_posix(), reason))
    for p, reason in android_mesh_module_sources(root):
        items.append(("android: :mesh module", p.relative_to(root).as_posix(), reason))
    for p, reason in ios_excluded_app_sources(root):
        items.append(("ios: excluded App source", p.relative_to(root).as_posix(), reason))
    for p, reason in ios_godstonemesh_product_sources(root):
        items.append(("ios: GodstoneMesh product", p.relative_to(root).as_posix(), reason))
    return items


def run_inventory(root: Path) -> int:
    items = build_inventory(root)
    print("DORMANT-WIRE TECHNICAL-DEBT INVENTORY (non-passing; informational)")
    print("=" * 72)
    print("This is technical debt. It is NOT proof of GMP/2.1.")
    print("It does NOT close A-01 (docs/AUDIT.md) -- A-01 remains OPEN.")
    print("A-01 closure requires: generated GMP/2.1 routers/stores + golden cross-device round trip.")
    print("-" * 72)
    if not items:
        print("No compile-excluded legacy/future Mesh/SOS sources found.")
    else:
        by_cat: dict[str, list[tuple[str, str]]] = {}
        for cat, path, reason in items:
            by_cat.setdefault(cat, []).append((path, reason))
        for cat in by_cat:
            print(f"\n[{cat}]  ({len(by_cat[cat])} file(s))")
            for path, reason in by_cat[cat]:
                print(f"  - {path}  ({reason})")
    print("-" * 72)
    print(f"Total dormant items: {len(items)}. A-01 status: OPEN.")
    return 0  # always informational -- this is not a gate


# ---------------------------------------------------------------------------
# Selftest
# ---------------------------------------------------------------------------

def _synth_repo(tmp: Path) -> Path:
    root = tmp / "repo"
    (root / "android/app/src/main/java/io/godstone/app/ui/home").mkdir(parents=True)
    # Dormant mesh/sos live under src/main/dormant/java (not compiled by KGP;
    # see check_shipping_path.ANDROID_SOURCE_ROOTS), excluded by the globs.
    (root / "android/app/src/main/dormant/java/io/godstone/app/ui/mesh").mkdir(parents=True)
    (root / "android/app/src/main/dormant/java/io/godstone/app/ui/sos").mkdir(parents=True)
    (root / "android/mesh/src/main/java/io/godstone/mesh").mkdir(parents=True)
    (root / "android/app/build.gradle.kts").write_text(
        'sourceSets { getByName("main") {\n'
        '  java.exclude("io/godstone/app/ui/mesh/**")\n'
        '  java.exclude("io/godstone/app/ui/sos/**")\n'
        '} }\ndependencies {\n  implementation(project(":core"))\n  implementation(project(":llm"))\n}\n',
        encoding="utf-8")
    (root / "android/app/src/main/java/io/godstone/app/ui/home/HomeScreen.kt").write_text("fun Home() {}\n", encoding="utf-8")
    (root / "android/app/src/main/dormant/java/io/godstone/app/ui/mesh/MeshScreen.kt").write_text("import io.godstone.mesh.MeshNode\n", encoding="utf-8")
    (root / "android/app/src/main/dormant/java/io/godstone/app/ui/sos/SosScreen.kt").write_text("import io.godstone.mesh.MeshNode\n", encoding="utf-8")
    (root / "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt").write_text("class MeshNode\n", encoding="utf-8")
    (root / "ios/Godstone/Sources/App").mkdir(parents=True)
    (root / "ios/Godstone/Sources/GodstoneMesh").mkdir(parents=True)
    (root / "ios/project.yml").write_text(
        "name: Godstone\ntargets:\n  Godstone:\n    type: application\n    platform: iOS\n    sources:\n"
        "      - path: Godstone/Sources/App/RootView.swift\n    dependencies:\n"
        "      - package: GodstonePackages\n        product: GodstoneCore\n", encoding="utf-8")
    (root / "ios/Godstone/Sources/App/RootView.swift").write_text("struct RootView {}\n", encoding="utf-8")
    (root / "ios/Godstone/Sources/App/MeshView.swift").write_text("import GodstoneMesh\n", encoding="utf-8")
    (root / "ios/Godstone/Sources/App/SosView.swift").write_text("import GodstoneMesh\n", encoding="utf-8")
    (root / "ios/Godstone/Sources/GodstoneMesh/MeshCoordinator.swift").write_text("class MeshCoordinator {}\n", encoding="utf-8")
    return root


def selftest() -> int:
    failures: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        root = _synth_repo(Path(td))
        items = build_inventory(root)
        paths = {p for _c, p, _r in items}
        # Must list the excluded/dormant files...
        for expected in ("android/app/src/main/dormant/java/io/godstone/app/ui/mesh/MeshScreen.kt",
                         "android/app/src/main/dormant/java/io/godstone/app/ui/sos/SosScreen.kt",
                         "android/mesh/src/main/java/io/godstone/mesh/MeshNode.kt",
                         "ios/Godstone/Sources/App/MeshView.swift",
                         "ios/Godstone/Sources/App/SosView.swift",
                         "ios/Godstone/Sources/GodstoneMesh/MeshCoordinator.swift"):
            if expected not in paths:
                failures.append(f"inventory missing dormant file: {expected}")
        # ...and must NOT list the included (shipping) files.
        for shipping in ("android/app/src/main/java/io/godstone/app/ui/home/HomeScreen.kt",
                         "ios/Godstone/Sources/App/RootView.swift"):
            if shipping in paths:
                failures.append(f"inventory should not list shipping file: {shipping}")
        # The report must carry the A-01-OPEN / not-GMP-2.1 language.
        import io as _io, contextlib
        buf = _io.StringIO()
        with contextlib.redirect_stdout(buf):
            run_inventory(root)
        report = buf.getvalue()
        for token in ("A-01", "OPEN", "NOT proof of GMP/2.1", "technical debt"):
            if token not in report:
                failures.append(f"report missing required token: {token!r}")
    if failures:
        print("inventory selftest FAILED:")
        for f in failures:
            print("  - " + f)
        return 1
    print("inventory selftest PASSED: lists dormant files, excludes shipping files, keeps A-01 OPEN language")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    ap.add_argument("--root", type=Path, default=Path.cwd())
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    return run_inventory(args.root.resolve())


if __name__ == "__main__":
    raise SystemExit(main())