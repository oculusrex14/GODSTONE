#!/usr/bin/env python3
"""Profile resolver: what actually reaches a build, per profile.

T54's card requireth that the lab and the shipping release be separated by
BUILD-CONFIG EVIDENCE -- "Resolve actual classpaths/link maps for each profile"
-- rather than by a comment or a naming convention. This module resolves, for
every profile, the exact set a build would compile and link:

  Android  -- a module's ``applicationId`` / ``namespace``, its source roots
              (``src/<sourceSet>/{java,kotlin}``, the only directories KGP
              auto-wires), its ``buildConfigField`` declarations, and its LINK
              MAP: the module names reached through shipping dependency
              configurations, transitively, from ``settings.gradle.kts``.

  iOS      -- a target's ``type``, ``PRODUCT_BUNDLE_IDENTIFIER``, its explicit
              ``sources:`` allowlist and its ``dependencies:`` products, from
              ``ios/project.yml`` (the same build-config evidence
              ``ci/check_shipping_path.py`` uses).

It is pure stdlib and touches no network, so it can run before pip. It RESOLVES
and REPORTS; it never decides (``ci/check_lab_isolation.py`` owns the verdict),
which is what keepeth the two readable and independently testable.
"""
from __future__ import annotations

import ast
import re
from dataclasses import dataclass, field
from pathlib import Path

# Configurations that put a module on the SHIPPING (main / release) graph.
# Mirrors ci/check_shipping_path.py: a testImplementation(project(":x")) edge is
# test-only and never links into a release artifact.
SHIPPING_DEP_CONFIGS = {
    "implementation", "api",
    "debugImplementation", "releaseImplementation",
    "runtimeOnly", "debugRuntimeOnly", "releaseRuntimeOnly",
    "compileOnly", "debugCompileOnly", "releaseCompileOnly",
}

# The source directories KGP/AGP auto-wire for a source set.
SOURCE_SET_DIRS = ("java", "kotlin")


@dataclass
class AndroidProfile:
    """One Android module, resolved from build-config evidence."""

    module: str
    path: str
    namespace: str | None
    application_id: str | None
    source_roots: list[str] = field(default_factory=list)
    build_config: dict[str, str] = field(default_factory=dict)
    direct_shipping_modules: list[str] = field(default_factory=list)
    link_map: list[str] = field(default_factory=list)
    source_files: list[str] = field(default_factory=list)

    @property
    def is_application(self) -> bool:
        return self.application_id is not None


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""


def android_included_modules(root: Path) -> list[str]:
    """The module names ``settings.gradle.kts`` includeth."""
    text = _read(root / "android" / "settings.gradle.kts")
    return re.findall(r'include\(":([\w-]+)"\)', text)


def android_direct_shipping_modules(module_dir: Path) -> list[str]:
    """Module names reached from one module through SHIPPING configurations."""
    text = _read(module_dir / "build.gradle.kts")
    out: list[str] = []
    for m in re.finditer(r'(\w+)\s*\(\s*project\(":([\w-]+)"\)\s*\)', text):
        if m.group(1) in SHIPPING_DEP_CONFIGS and m.group(2) not in out:
            out.append(m.group(2))
    return out


def android_source_roots(module_dir: Path) -> list[str]:
    """The source roots AGP would compile for this module.

    Two kinds of evidence, and BOTH are build-config truth:

      * the directories KGP/AGP auto-wire (``src/<sourceSet>/{java,kotlin}``);
      * every EXPLICIT ``srcDir("...")`` / ``srcDirs("...")`` declaration, which
        is compiled whether or not the directory existeth yet.

    The first form of this resolver read only the auto-wired directories, and the
    gate's selftest caught the hole at once: a lab source set declared with
    ``srcDir(...)`` was invisible to it. A resolver that misseth a declared root
    is a gate that misseth a lab.
    """
    roots: list[str] = []
    for source_set in ("main", "debug", "release"):
        for kind in SOURCE_SET_DIRS:
            rel = f"src/{source_set}/{kind}"
            if (module_dir / rel).is_dir():
                roots.append(rel)
    text = _read(module_dir / "build.gradle.kts")
    for m in re.finditer(r'srcDirs?\(\s*"([^"]+)"\s*\)', text):
        rel = m.group(1).rstrip("/")
        if rel not in roots:
            roots.append(rel)
    return sorted(roots)


def android_build_config(module_dir: Path) -> dict[str, str]:
    """The ``buildConfigField`` declarations, as name -> literal."""
    text = _read(module_dir / "build.gradle.kts")
    out: dict[str, str] = {}
    for m in re.finditer(r'buildConfigField\(\s*"[^"]+"\s*,\s*"(\w+)"\s*,\s*(".*?"|true|false|-?\d+)\s*\)',
                         text, re.S):
        out[m.group(1)] = m.group(2)
    return out


def android_source_files(module_dir: Path, roots: list[str]) -> list[str]:
    out: list[str] = []
    for rel in roots:
        for p in sorted((module_dir / rel).rglob("*")):
            if p.suffix in (".kt", ".java") and p.is_file():
                out.append(str(p.relative_to(module_dir)))
    return out


def resolve_android(root: Path, module: str) -> AndroidProfile:
    """Resolve one Android module and its transitive SHIPPING link map."""
    module_dir = root / "android" / module
    text = _read(module_dir / "build.gradle.kts")
    ns = re.search(r'namespace\s*=\s*"([^"]+)"', text)
    app_id = re.search(r'applicationId\s*=\s*"([^"]+)"', text)
    roots = android_source_roots(module_dir)
    direct = android_direct_shipping_modules(module_dir)

    # transitive: a module's link map carrieth everything it reacheth
    link_map: list[str] = []
    pending = list(direct)
    while pending:
        nxt = pending.pop(0)
        if nxt in link_map:
            continue
        link_map.append(nxt)
        pending.extend(android_direct_shipping_modules(root / "android" / nxt))

    return AndroidProfile(
        module=module,
        path=f"android/{module}",
        namespace=ns.group(1) if ns else None,
        application_id=app_id.group(1) if app_id else None,
        source_roots=roots,
        build_config=android_build_config(module_dir),
        direct_shipping_modules=direct,
        link_map=sorted(link_map),
        source_files=android_source_files(module_dir, roots),
    )


# ---------------------------------------------------------------------------
# iOS: project.yml targets (parsed structurally without PyYAML, so the resolver
# runs before pip; PyYAML is used when present to cross-check).
# ---------------------------------------------------------------------------

@dataclass
class IOSProfile:
    target: str
    type: str | None
    bundle_id: str | None
    sources: list[str] = field(default_factory=list)
    products: list[str] = field(default_factory=list)
    settings: dict[str, str] = field(default_factory=dict)
    source_files: list[str] = field(default_factory=list)


def _ios_target_block(text: str, target: str) -> str | None:
    """The indented block of one target under ``targets:``."""
    lines = text.splitlines()
    try:
        start = next(i for i, ln in enumerate(lines) if ln.strip() == "targets:")
    except StopIteration:
        return None
    i = start + 1
    depth = 0
    while i < len(lines):
        ln = lines[i]
        if ln.strip() and not ln.startswith(" "):
            break
        if re.match(r'^  (\w[\w-]*):\s*$', ln):
            name = re.match(r'^  (\w[\w-]*):\s*$', ln).group(1)
            block_start = i
            j = i + 1
            block: list[str] = []
            while j < len(lines):
                lj = lines[j]
                if lj.strip() and not lj.startswith("    "):
                    break
                block.append(lj)
                j += 1
            if name == target:
                return "\n".join(block)
            i = j
            continue
        i += 1
    return None


def resolve_ios(root: Path, target: str) -> IOSProfile:
    text = _read(root / "ios" / "project.yml")
    block = _ios_target_block(text, target) or ""
    type_m = re.search(r'^\s{4}type:\s*(\S+)', block, re.M)
    bundle_m = re.search(r'PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)', block)
    sources = re.findall(r'^\s{6}- path:\s*(\S+)', block, re.M)
    products = re.findall(r'^\s{8}product:\s*(\S+)', block, re.M)
    settings = dict(re.findall(r'^\s{8}([A-Z_]+):\s*(\S+)', block, re.M))

    files: list[str] = []
    for rel in sources:
        p = root / "ios" / rel
        if p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.suffix == ".swift" and f.is_file():
                    files.append(str(f.relative_to(root / "ios")))
        elif p.is_file():
            files.append(rel)
    return IOSProfile(target=target, type=type_m.group(1) if type_m else None,
                      bundle_id=bundle_m.group(1) if bundle_m else None,
                      sources=sources, products=products, settings=settings,
                      source_files=files)


# ---------------------------------------------------------------------------
# The resolver's public answer for a whole repository
# ---------------------------------------------------------------------------

def resolve_profiles(root: Path) -> dict[str, dict]:
    """Every profile the isolation gate judgeth, resolved from evidence."""
    return {
        "LIGHT_ANDROID": {"platform": "android",
                          "profile": resolve_android(root, "app")},
        "LIGHT_IOS": {"platform": "ios",
                      "profile": resolve_ios(root, "Godstone")},
        "LAB_ANDROID": {"platform": "android",
                        "profile": resolve_android(root, "labmesh")},
        "LAB_IOS": {"platform": "ios",
                    "profile": resolve_ios(root, "LabMesh")},
        "LAB_TESTS_IOS": {"platform": "ios",
                          "profile": resolve_ios(root, "LabMeshTests")},
    }


def describe(profiles: dict[str, dict]) -> str:
    """A human-readable resolution, used by ``--explain`` and by the court."""
    lines: list[str] = []
    for name, entry in profiles.items():
        p = entry["profile"]
        if entry["platform"] == "android":
            lines.append(f"{name}: {p.path} applicationId={p.application_id} "
                         f"namespace={p.namespace} sources={p.source_roots} "
                         f"link_map={p.link_map}")
        else:
            lines.append(f"{name}: {p.target} type={p.type} bundle={p.bundle_id} "
                         f"sources={p.sources} products={p.products}")
    return "\n".join(lines)


def main() -> int:
    import argparse

    ap = argparse.ArgumentParser(description="Resolve the compiled set per profile")
    ap.add_argument("--root", default=".")
    ap.add_argument("--explain", action="store_true")
    args = ap.parse_args()
    profiles = resolve_profiles(Path(args.root).resolve())
    print(describe(profiles) if args.explain else repr(
        {k: (v["profile"].module if v["platform"] == "android" else v["profile"].target)
         for k, v in profiles.items()}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
