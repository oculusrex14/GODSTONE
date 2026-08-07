#!/usr/bin/env python3
"""Shipping-path gate for legacy Mesh / GMP-1 wire.

This is a GATE: it fails (exit 1) iff a forbidden legacy Mesh / GMP-1 type or
dependency is reachable from a LIGHT *shipping* build. "Reachable from a shipping
build" is decided by BUILD-CONFIG EVIDENCE, not by a blind text scan:

  * Android  -- the compiled source set of :app is the union of
               ``android/app/src/main/java`` (shipping sources) and
               ``android/app/src/main/dormant/java`` (dormant Mesh/SOS sources
               kept out of the Kotlin compile tree -- KGP auto-wires
               ``src/<sourceSet>/{java,kotlin}`` only, so ``src/main/dormant/java``
               is inert to the compiler while remaining on the gate's scan path),
               MINUS the ``java.exclude(...)`` globs declared in
               ``android/app/build.gradle.kts``, and the ``project(":...")``
               dependency edges in the same file. A forbidden reference in an
               excluded source is NOT a shipping-path violation (it is dormant
               debt -- see ci/inventory_dormant_wire.py); a forbidden reference
               in an *included* source, or a ``:mesh`` dependency edge, IS.

  * iOS      -- the compiled source set of the application target is the
               explicit ``sources:`` allowlist in ``ios/project.yml`` (the
               ``Godstone`` target of ``type: application``), and the
               ``dependencies:`` products. A file not on the allowlist is NOT
               compiled into the LIGHT app (dormant debt); a forbidden
               reference in an allowlisted source, or a ``GodstoneMesh`` product
               dependency, IS.

Forbidden needles (the legacy wire surface):
    io.godstone.mesh.wire.Frame   GodstoneMesh   MeshNode   MeshCoordinator
    GMP/1 frame                   PROTOCOL_VERSION: Byte = 0x01

This gate does NOT close A-01 (docs/AUDIT.md). A clean shipping path proves the
shipping app does not depend on legacy Mesh wire; it does NOT prove the Android
and iOS mesh runtimes share a canonical GMP/2.1 frame path. A-01 stays OPEN.

Usage:
    python3 ci/check_shipping_path.py [--root DIR] [--selftest]
"""
from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

FORBIDDEN_IN_SOURCE = (
    "io.godstone.mesh.wire.Frame",
    "GodstoneMesh",            # matches `import GodstoneMesh`
    "MeshNode",
    "MeshCoordinator",
    "GMP/1 frame",
    "PROTOCOL_VERSION: Byte = 0x01",
)
SOURCE_SUFFIXES = {".kt", ".java", ".swift", ".mm", ".m", ".h", ".hpp"}

# Modules whose project() dependency from :app would pull legacy wire into shipping.
FORBIDDEN_ANDROID_DEP_MODULES = {"mesh"}

# Source roots the gate scans for :app. ``src/main/java`` holds the SHIPPING .kt
# sources (compiled by KGP). ``src/main/dormant/java`` holds the dormant Mesh/SOS
# .kt files that KGP must NOT compile -- they reference :mesh-only symbols, and
# AGP/KGP ignores SourceDirectorySet.exclude() metadata, so the only way to keep
# them out of the compile is to keep them out of a source directory KGP auto-wires
# (KGP auto-wires src/<sourceSet>/{java,kotlin} only). The java.exclude globs in
# build.gradle.kts classify the dormant files as dormant debt on this scan path.
ANDROID_SOURCE_ROOTS = ("java", "dormant/java")


# ---------------------------------------------------------------------------
# Android build-config evidence
# ---------------------------------------------------------------------------

def android_exclude_globs(gradle_file: Path) -> list[str]:
    """The ``java.exclude("<glob>")`` globs from the :app main source set."""
    if not gradle_file.is_file():
        return []
    text = gradle_file.read_text(encoding="utf-8", errors="replace")
    return re.findall(r'java\.exclude\("([^"]+)"\)', text)


def android_project_deps(gradle_file: Path) -> list[str]:
    """Module names from ``project(":<mod>")`` dependency edges in :app."""
    if not gradle_file.is_file():
        return []
    text = gradle_file.read_text(encoding="utf-8", errors="replace")
    return re.findall(r'project\(":(\w+)"\)', text)


def glob_to_regex(glob: str) -> re.Pattern[str]:
    """Gradle source-path glob -> anchored regex. ``**`` spans directories."""
    out: list[str] = []
    i, n = 0, len(glob)
    while i < n:
        if glob[i:i + 2] == "**":
            out.append(".*")
            i += 2
            if i < n and glob[i] == "/":   # consume separator so **/ spans dirs
                i += 1
            continue
        if glob[i] == "*":
            out.append("[^/]*")
            i += 1
            continue
        out.append(re.escape(glob[i]))
        i += 1
    return re.compile("^" + "".join(out) + "$")


def _android_source_files(app_src_main: Path):
    """Yield (root, path) for each source file under each Android source root.

    ``root`` is the per-root directory (e.g. src/main/java or src/main/dormant/java)
    so callers compute the glob-relative path against the right root.
    """
    for rel_root in ANDROID_SOURCE_ROOTS:
        root = app_src_main / rel_root
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if path.is_file() and path.suffix in SOURCE_SUFFIXES:
                yield root, path


def android_included_sources(app_src_main: Path, excludes: list[str]) -> list[Path]:
    """Source files compiled into :app: under src/main minus the exclude globs.

    Scans both src/main/java (shipping) and src/main/dormant/java (dormant
    Mesh/SOS); the java.exclude globs are applied to each root so glob-matched
    files are dormant debt, not shipping path.
    """
    patterns = [glob_to_regex(g) for g in excludes]
    included: list[Path] = []
    for root, path in _android_source_files(app_src_main):
        rel = path.relative_to(root).as_posix()
        if any(p.match(rel) for p in patterns):
            continue  # compile-excluded -> dormant debt, not shipping path
        included.append(path)
    return included


def android_excluded_sources(app_src_main: Path, excludes: list[str]) -> list[tuple[Path, str]]:
    """:app sources a java.exclude glob removes from the LIGHT build (dormant debt).

    Complementary to android_included_sources: the files MATCHING a glob. Shared
    with ci/inventory_dormant_wire.py so "included" vs "excluded" is decided by
    the same build-config evidence (single source of truth).
    """
    patterns = [glob_to_regex(g) for g in excludes]
    excluded: list[tuple[Path, str]] = []
    for root, path in _android_source_files(app_src_main):
        rel = path.relative_to(root).as_posix()
        for g, p in zip(excludes, patterns):
            if p.match(rel):
                excluded.append((path, g))
                break
    return excluded


# ---------------------------------------------------------------------------
# iOS build-config evidence
# ---------------------------------------------------------------------------

def parse_ios_app_target(project_yml: Path) -> tuple[list[str], list[tuple[str, str]]]:
    """Return (sources, deps) for the ``type: application`` target.

    Dependency-free, indentation-aware. Sources are the ``- path:`` entries of
    the ``sources:`` block; deps are the (package, product) pairs of the
    ``dependencies:`` block. Both are read from build config, so a file not on
    the allowlist is provably not compiled into the LIGHT app.
    """
    if not project_yml.is_file():
        return [], []
    lines = [ln.split("#", 1)[0].rstrip() for ln in project_yml.read_text(encoding="utf-8").splitlines()]
    i, n = 0, len(lines)
    while i < n and lines[i].strip() != "targets:":
        i += 1
    i += 1
    app_sources: list[str] = []
    app_deps: list[tuple[str, str]] = []
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            break
        if indent == 2 and line.strip().endswith(":"):
            i += 1
            t_type: str | None = None
            t_sources: list[str] = []
            t_deps: list[tuple[str, str]] = []
            section: str | None = None
            cur_dep: dict[str, str] = {}

            def flush_dep() -> None:
                nonlocal cur_dep
                if cur_dep:
                    t_deps.append((cur_dep.get("package", ""), cur_dep.get("product", "")))
                    cur_dep = {}

            while i < n:
                l2 = lines[i]
                if not l2.strip():
                    i += 1
                    continue
                ind2 = len(l2) - len(l2.lstrip())
                if ind2 <= 2:
                    break
                s2 = l2.strip()
                if ind2 == 4 and s2.endswith(":") and " " not in s2:
                    flush_dep()
                    key = s2[:-1]
                    section = "sources" if key == "sources" else ("deps" if key == "dependencies" else None)
                    i += 1
                    continue
                if ind2 == 4 and ":" in s2:
                    flush_dep()
                    key, _, val = s2.partition(":")
                    if key.strip() == "type":
                        t_type = val.strip()
                    section = None
                    i += 1
                    continue
                if ind2 == 6 and s2.startswith("- "):
                    if section == "sources":
                        m = re.match(r'path:\s*(.+)$', s2[2:].strip())
                        if m:
                            t_sources.append(m.group(1).strip())
                    elif section == "deps":
                        flush_dep()
                        m = re.match(r'package:\s*(.+)$', s2[2:].strip())
                        if m:
                            cur_dep = {"package": m.group(1).strip()}
                    i += 1
                    continue
                if ind2 == 8 and section == "deps" and not s2.startswith("- "):
                    key, _, val = s2.partition(":")
                    if key.strip() == "product":
                        cur_dep["product"] = val.strip()
                    i += 1
                    continue
                i += 1
            flush_dep()
            if t_type == "application":
                app_sources, app_deps = t_sources, t_deps
        else:
            i += 1
    return app_sources, app_deps


def ios_included_sources(root: Path, project_yml: Path) -> list[Path]:
    srcs, _deps = parse_ios_app_target(project_yml)
    # project.yml lives in ios/; its `sources:` paths are relative to that dir.
    base = project_yml.parent
    out: list[Path] = []
    for rel in srcs:
        p = base / rel
        if p.is_file() and p.suffix in SOURCE_SUFFIXES:
            out.append(p)
    return out


# ---------------------------------------------------------------------------
# Gate
# ---------------------------------------------------------------------------

def scan_sources(files: list[Path], root: Path) -> list[str]:
    hits: list[str] = []
    for f in files:
        text = f.read_text(encoding="utf-8", errors="replace")
        for needle in FORBIDDEN_IN_SOURCE:
            if needle in text:
                hits.append(f"{f.relative_to(root)}: forbidden legacy wire `{needle}` in SHIPPING source")
    return hits


def shipping_path_violations(root: Path) -> tuple[list[str], dict]:
    """Return (violations, evidence). Empty list => gate passes."""
    evidence: dict = {"android_excludes": [], "android_deps": [], "ios_sources": [], "ios_deps": []}
    violations: list[str] = []

    # ---- Android ----
    app_gradle = root / "android/app/build.gradle.kts"
    excludes = android_exclude_globs(app_gradle)
    deps = android_project_deps(app_gradle)
    evidence["android_excludes"] = excludes
    evidence["android_deps"] = deps
    included_android = android_included_sources(root / "android/app/src/main", excludes)
    violations += scan_sources(included_android, root)
    bad_mods = [m for m in deps if m in FORBIDDEN_ANDROID_DEP_MODULES]
    for m in bad_mods:
        violations.append(f"android/app/build.gradle.kts: shipping :app depends on project(:{m})")

    # ---- iOS ----
    project_yml = root / "ios/project.yml"
    ios_srcs, ios_deps = parse_ios_app_target(project_yml)
    evidence["ios_sources"] = ios_srcs
    evidence["ios_deps"] = ios_deps
    included_ios = ios_included_sources(root, project_yml)
    violations += scan_sources(included_ios, root)
    for pkg, prod in ios_deps:
        if prod == "GodstoneMesh":
            violations.append(f"ios/project.yml: shipping app depends on product GodstoneMesh (via {pkg})")

    return violations, evidence


def run_gate(root: Path) -> int:
    violations, evidence = shipping_path_violations(root)
    if violations:
        print("SHIPPING-PATH GATE: FAIL -- legacy Mesh / GMP-1 wire is reachable from a LIGHT shipping build:")
        for v in violations:
            print("  - " + v)
        print("Build-config evidence used: android excludes=%s deps=%s; ios sources=%s deps=%s"
              % (evidence["android_excludes"], evidence["android_deps"],
                 evidence["ios_sources"], evidence["ios_deps"]))
        print("This gate does NOT close A-01 (canonical GMP/2.1 frame path); A-01 remains OPEN.")
        return 1
    print("SHIPPING-PATH GATE: PASS -- LIGHT shipping path has no Mesh/GMP-1 dependency edge.")
    print("  android excludes=%s deps=%s" % (evidence["android_excludes"], evidence["android_deps"]))
    print("  ios sources=%s deps=%s" % (evidence["ios_sources"], evidence["ios_deps"]))
    print("  (A-01 remains OPEN: a clean shipping path is not GMP/2.1 canonical-frame evidence.)")
    return 0


# ---------------------------------------------------------------------------
# Selftest -- three required negative controls + dependency-edge controls
# ---------------------------------------------------------------------------

def _synth_repo(tmp: Path) -> Path:
    """A minimal repo mirroring the real build-config shapes."""
    root = tmp / "repo"
    # Android
    (root / "android/app/src/main/java/io/godstone/app/ui/home").mkdir(parents=True)
    # Dormant Mesh source lives under src/main/dormant/java (NOT compiled by
    # KGP, which auto-wires src/main/{java,kotlin} only), but on the gate's scan
    # path so the java.exclude glob classifies it as dormant debt and the sanity
    # control (drop the glob -> it becomes shipping) still fires.
    (root / "android/app/src/main/dormant/java/io/godstone/app/ui/mesh").mkdir(parents=True)
    (root / "android/app/build.gradle.kts").write_text(
        'sourceSets { getByName("main") {\n'
        '  java.exclude("io/godstone/app/ui/mesh/**")\n'
        '  java.exclude("io/godstone/app/ui/sos/**")\n'
        '} }\n'
        'dependencies {\n'
        '  implementation(project(":core"))\n'
        '  implementation(project(":llm"))\n'
        '}\n', encoding="utf-8")
    (root / "android/app/src/main/java/io/godstone/app/ui/home/HomeScreen.kt").write_text(
        "package io.godstone.app.ui.home\nfun Home() {}\n", encoding="utf-8")
    # excluded source carrying a forbidden import (must NOT fail the gate)
    (root / "android/app/src/main/dormant/java/io/godstone/app/ui/mesh/MeshScreen.kt").write_text(
        "import io.godstone.mesh.MeshNode\nfun MeshScreen(n: MeshNode) {}\n", encoding="utf-8")
    # iOS
    (root / "ios/Godstone/Sources/App").mkdir(parents=True)
    (root / "ios/project.yml").write_text(
        "name: Godstone\nconfigs:\n  LightDebug: debug\ntargets:\n"
        "  Godstone:\n    type: application\n    platform: iOS\n    sources:\n"
        "      - path: Godstone/Sources/App/RootView.swift\n    dependencies:\n"
        "      - package: GodstonePackages\n        product: GodstoneCore\n",
        encoding="utf-8")
    (root / "ios/Godstone/Sources/App/RootView.swift").write_text(
        "import SwiftUI\nstruct RootView: View { var body: some View { EmptyView() } }\n",
        encoding="utf-8")
    # excluded iOS source carrying a forbidden import (must NOT fail the gate)
    (root / "ios/Godstone/Sources/App/MeshView.swift").write_text(
        "import GodstoneMesh\nstruct MeshView: View { @EnvironmentObject var mesh: MeshCoordinator }\n",
        encoding="utf-8")
    return root


def selftest() -> int:
    failures: list[str] = []

    def expect_fail(desc: str, mutator) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = _synth_repo(Path(td))
            mutator(root)
            v, _e = shipping_path_violations(root)
            if not v:
                failures.append(f"[{desc}] expected gate FAIL, got PASS")

    def expect_pass(desc: str, mutator=None) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = _synth_repo(Path(td))
            if mutator:
                mutator(root)
            v, _e = shipping_path_violations(root)
            if v:
                failures.append(f"[{desc}] expected gate PASS, got FAIL: {v}")

    # Control 3: excluded Mesh/SOS files present -> gate PASSES.
    expect_pass("control-3: excluded mesh/sos present")

    # Control 1: add legacy Frame import to an INCLUDED Android source -> FAIL.
    def add_frame_included(root: Path) -> None:
        (root / "android/app/src/main/java/io/godstone/app/ui/home/HomeScreen.kt").write_text(
            "import io.godstone.mesh.wire.Frame\nfun Home() { val f: Frame? = null }\n", encoding="utf-8")
    expect_fail("control-1: Frame import in included Android source", add_frame_included)

    # Control 2: add GodstoneMesh to an INCLUDED iOS source -> FAIL.
    def add_godstonemesh_included(root: Path) -> None:
        (root / "ios/Godstone/Sources/App/RootView.swift").write_text(
            "import GodstoneMesh\nstruct RootView: View { @EnvironmentObject var m: MeshCoordinator }\n",
            encoding="utf-8")
    expect_fail("control-2: GodstoneMesh in included iOS source", add_godstonemesh_included)

    # Dependency-edge control A: :app depends on :mesh -> FAIL.
    def add_mesh_dep(root: Path) -> None:
        g = (root / "android/app/build.gradle.kts").read_text(encoding="utf-8")
        g = g.replace('implementation(project(":llm"))',
                      'implementation(project(":llm"))\n  implementation(project(":mesh"))')
        (root / "android/app/build.gradle.kts").write_text(g, encoding="utf-8")
    expect_fail("dep-edge: :app -> :mesh", add_mesh_dep)

    # Dependency-edge control B: iOS app depends on GodstoneMesh -> FAIL.
    def add_godstonemesh_dep(root: Path) -> None:
        y = (root / "ios/project.yml").read_text(encoding="utf-8")
        y = y.replace("        product: GodstoneCore\n",
                      "        product: GodstoneCore\n"
                      "      - package: GodstonePackages\n        product: GodstoneMesh\n")
        (root / "ios/project.yml").write_text(y, encoding="utf-8")
    expect_fail("dep-edge: iOS app -> GodstoneMesh", add_godstonemesh_dep)

    # Sanity: removing the Android exclude makes the excluded file included -> FAIL.
    def drop_android_exclude(root: Path) -> None:
        g = (root / "android/app/build.gradle.kts").read_text(encoding="utf-8")
        g = g.replace('  java.exclude("io/godstone/app/ui/mesh/**")\n', "")
        (root / "android/app/build.gradle.kts").write_text(g, encoding="utf-8")
    expect_fail("sanity: dropping Android mesh exclude -> mesh source becomes shipping", drop_android_exclude)

    # Sanity: adding MeshView.swift to the iOS allowlist -> FAIL.
    def add_meshview_to_allowlist(root: Path) -> None:
        y = (root / "ios/project.yml").read_text(encoding="utf-8")
        y = y.replace("      - path: Godstone/Sources/App/RootView.swift\n",
                      "      - path: Godstone/Sources/App/RootView.swift\n"
                      "      - path: Godstone/Sources/App/MeshView.swift\n")
        (root / "ios/project.yml").write_text(y, encoding="utf-8")
    expect_fail("sanity: adding MeshView.swift to iOS allowlist -> it becomes shipping", add_meshview_to_allowlist)

    if failures:
        print("shipping-path selftest FAILED:")
        for f in failures:
            print("  - " + f)
        return 1
    print("shipping-path selftest PASSED: 3 negative controls + 2 dep-edge + 2 sanity checks all behaved correctly")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1] if __doc__ else "")
    ap.add_argument("--root", type=Path, default=Path.cwd())
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    return run_gate(args.root.resolve())


if __name__ == "__main__":
    raise SystemExit(main())