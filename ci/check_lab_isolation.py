#!/usr/bin/env python3
"""Lab-isolation gate (T54).

The shipped apps intentionally exclude the mesh runtime and every readiness flag
is false. T54 addeth nonshipping LabMesh targets so complete product flows can be
driven against the REAL composition -- and this gate is what keepeth "nonshipping"
a fact rather than a claim. It resolveth each profile's compiled set and link map
from BUILD-CONFIG EVIDENCE (ci/profile_resolver.py) and fails unless:

  LIGHT (the shipping Archive-only profile, Android and iOS)
    * carrieth NO lab source root and NO lab source file;
    * reacheth NO lab module and NO `:mesh` / `:llm` module edge;
    * carrieth NO readiness override (a build-config field that would turn a
      disabled capability on, or a link-layer readiness flag set true);
    * keepeth its OWN bundle/application identity.

  LAB (the LabMesh targets, Android and iOS)
    * carrieth a bundle/application identity DISTINCT from the shipping one;
    * reacheth the canonical runtime components (:mesh / GodstoneMesh) -- a lab
      that did not would be testing a twin;
    * carrieth NO synthetic READY setter: no function, property or build field
      that could manufacture crypto readiness;
    * carrieth its own explicit test capability that drives the real composition.

  THE RELEASE MANIFEST
    * the readiness statements stay FALSE and the lab is referenced by neither
      docs/production/RELEASE_GATES_STATUS.json nor the readiness invariants: a
      lab target may not move a gate, and no gate may cite a lab.

This gate does NOT close any external gate, does NOT make readiness true, and
does NOT prove anything about a physical device. It proveth the SEPARATION.

Usage:
    python3 ci/check_lab_isolation.py [--root DIR] [--explain] [--selftest]
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from profile_resolver import (AndroidProfile, IOSProfile, resolve_profiles)  # noqa: E402

SHIPPING_ANDROID_ID = "io.godstone.app"
SHIPPING_IOS_BUNDLE = "io.godstone.app"

# Modules a LAB is allowed (and required) to reach; a LIGHT profile may reach none.
CANONICAL_ANDROID_MODULES = {"mesh", "core"}
FORBIDDEN_ANDROID_MODULES = {"mesh", "llm"}
FORBIDDEN_IOS_PRODUCTS = {"GodstoneMesh", "GodstoneLLM"}

# Source roots that mark a lab source set wherever they appear.
LAB_SOURCE_MARKERS = ("labmesh", "LabMesh", "lab/", "Sources/LabMesh")

# A build-config field that would MANUFACTURE readiness. The shipping flavor
# declareth these as false; true is a readiness override.
READINESS_FIELDS = ("MESH_ENABLED", "SOS_ENABLED", "ORACLE_ENABLED",
                    "BULK_TRANSFER_ENABLED", "MANUFACTURES_READINESS",
                    "LINK_LAYER_READY", "IOS_LINK_LAYER_READY")

# A synthetic READY setter: a declaration whose NAME suggests it setteth a
# readiness flag. Matched over the lab's own sources.
READY_SETTER_PATTERNS = (
    r"\bfun\s+set[A-Z]\w*Ready\b",
    r"\bfunc\s+set[A-Z]\w*Ready\b",
    r"\bforceReady\b",
    r"\bmarkReady\s*[(=]",
    r"\bvar\s+\w*[Rr]eady\w*\s*=\s*true\b",
    r"\bLINK_LAYER_READY\s*=\s*true\b",
    r"\bMANUFACTURES_READINESS\s*=\s*true\b",
)


class Findings:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.notes: list[str] = []

    def error(self, message: str) -> None:
        self.errors.append(message)

    def note(self, message: str) -> None:
        self.notes.append(message)


def _lab_source_files(root: Path, profile) -> list[str]:
    """The lab's own source files (Android module or iOS target allowlist)."""
    out: list[str] = []
    if isinstance(profile, AndroidProfile):
        base = root / profile.path
        for rel in profile.source_files:
            out.append(rel)
        for extra in ("src/test",):
            d = base / extra
            if d.is_dir():
                out.extend(str(p.relative_to(base)) for p in sorted(d.rglob("*.kt")))
    else:
        out = list(profile.source_files)
    return out


def check_light_android(f: Findings, profile) -> None:
    if profile.application_id != SHIPPING_ANDROID_ID:
        f.error(f"LIGHT android: applicationId is {profile.application_id!r}, not "
                f"{SHIPPING_ANDROID_ID!r}")
    for mod in profile.link_map:
        if mod in FORBIDDEN_ANDROID_MODULES:
            f.error(f"LIGHT android: the shipping link map reacheth :{mod} "
                    f"({profile.link_map})")
    for mod in profile.link_map:
        if "lab" in mod.lower():
            f.error(f"LIGHT android: the shipping link map reacheth the lab module "
                    f":{mod}")
    for rel in profile.source_roots:
        if any(marker in rel for marker in LAB_SOURCE_MARKERS):
            f.error(f"LIGHT android: the compiled source set carrieth a lab root "
                    f"{rel!r}")
    for rel in profile.source_files:
        if any(marker in rel for marker in LAB_SOURCE_MARKERS):
            f.error(f"LIGHT android: the compiled source set carrieth a lab source "
                    f"{rel!r}")
    for field_name, raw in profile.build_config.items():
        # the literal is captured with its Kotlin quotes: normalize before judging,
        # or a correct "false" would read as an override (the first form of this
        # gate did exactly that, and the clean fixture caught it)
        value = raw.strip()
        if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
            value = value[1:-1]
        if field_name in READINESS_FIELDS and value.lower() not in ("false", "0", ""):
            f.error(f"LIGHT android: readiness override {field_name}={raw} in the "
                    f"shipping profile")
    f.note(f"LIGHT android: applicationId={profile.application_id} "
           f"link_map={profile.link_map} sources={profile.source_roots}")


def check_light_ios(f: Findings, profile) -> None:
    if profile.bundle_id != SHIPPING_IOS_BUNDLE:
        f.error(f"LIGHT ios: bundle id is {profile.bundle_id!r}, not "
                f"{SHIPPING_IOS_BUNDLE!r}")
    for product in profile.products:
        if product in FORBIDDEN_IOS_PRODUCTS:
            f.error(f"LIGHT ios: the shipping app product-links {product} "
                    f"({profile.products})")
    for rel in profile.sources:
        if any(marker in rel for marker in LAB_SOURCE_MARKERS):
            f.error(f"LIGHT ios: the compiled allowlist carrieth a lab source {rel!r}")
    f.note(f"LIGHT ios: bundle={profile.bundle_id} products={profile.products} "
           f"sources={profile.sources}")


def check_lab(f: Findings, platform: str, profile, root: Path,
              shipping_id: str) -> None:
    ident = profile.application_id if platform == "android" else profile.bundle_id
    if ident is None:
        f.error(f"LAB {platform}: carrieth no bundle/application identity")
    elif ident == shipping_id:
        f.error(f"LAB {platform}: carrieth the SHIPPING identity {ident!r} -- a lab "
                f"install could be confused with the release")
    if platform == "android":
        reached = set(profile.link_map)
        if not (CANONICAL_ANDROID_MODULES & reached):
            f.error(f"LAB android: reacheth none of the canonical modules "
                    f"{sorted(CANONICAL_ANDROID_MODULES)} (link_map={profile.link_map})")
        if "mesh" not in reached:
            f.error("LAB android: the lab does not reach :mesh, so it would test a "
                    "twin rather than the canonical runtime")
    else:
        if "GodstoneMesh" not in profile.products:
            f.error(f"LAB ios: the lab does not product-link GodstoneMesh "
                    f"({profile.products})")
    if not profile.source_files and not profile.sources:
        f.error(f"LAB {platform}: carrieth no sources")

    # no synthetic READY setter anywhere in the lab's own sources
    for rel in _lab_source_files(root, profile):
        path = (root / (("android/labmesh/" + rel) if platform == "android"
                        else ("ios/" + rel)))
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for pattern in READY_SETTER_PATTERNS:
            m = re.search(pattern, text)
            if m:
                f.error(f"LAB {platform}: {path.name} carrieth a synthetic readiness "
                        f"setter ({m.group(0)!r}) -- the lab may not manufacture "
                        f"crypto READY")
    f.note(f"LAB {platform}: identity={ident} "
           f"{'link_map=' + str(profile.link_map) if platform == 'android' else 'products=' + str(profile.products)}")


def check_lab_test_capability(f: Findings, root: Path) -> None:
    android_tests = list((root / "android" / "labmesh" / "src" / "test").rglob("*Test.kt")) \
        if (root / "android" / "labmesh" / "src" / "test").is_dir() else []
    ios_tests = list((root / "ios" / "Godstone" / "Tests" / "LabMeshTests").rglob("*.swift")) \
        if (root / "ios" / "Godstone" / "Tests" / "LabMeshTests").is_dir() else []
    if not android_tests:
        f.error("LAB android: carrieth no explicit test capability under "
                "android/labmesh/src/test")
    if not ios_tests:
        f.error("LAB ios: carrieth no explicit test capability under "
                "ios/Godstone/Tests/LabMeshTests")
    f.note(f"LAB test capability: android={len(android_tests)} file(s), "
           f"ios={len(ios_tests)} file(s)")


def check_release_manifest(f: Findings, root: Path) -> None:
    invariants = root / "docs" / "production-readiness" / "ARCHITECTURE_INVARIANTS.json"
    gates = root / "docs" / "production" / "RELEASE_GATES_STATUS.json"
    if not invariants.is_file():
        f.error("the readiness invariants document is missing")
    else:
        doc = json.loads(invariants.read_text(encoding="utf-8"))
        readiness = doc.get("readiness", {})
        for key, value in readiness.items():
            if value is not False:
                f.error(f"the release manifest carrieth readiness {key}={value!r} "
                        f"(a lab may not move a gate)")
        f.note(f"readiness unchanged: {readiness}")
    lab_needles = ("labmesh", "LabMesh", "LABMESH")
    for path in (invariants, gates):
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for needle in lab_needles:
            if needle in text:
                f.error(f"{path.name} referenceth the lab ({needle!r}): no gate may "
                        f"cite a lab target")


def run(root: Path) -> Findings:
    f = Findings()
    profiles = resolve_profiles(root)
    check_light_android(f, profiles["LIGHT_ANDROID"]["profile"])
    check_light_ios(f, profiles["LIGHT_IOS"]["profile"])
    check_lab(f, "android", profiles["LAB_ANDROID"]["profile"], root,
              SHIPPING_ANDROID_ID)
    check_lab(f, "ios", profiles["LAB_IOS"]["profile"], root, SHIPPING_IOS_BUNDLE)
    check_lab_test_capability(f, root)
    check_release_manifest(f, root)
    return f


# ---------------------------------------------------------------------------
# selftest: each rule is exercised by a corrupted fixture that MUST trip it
# ---------------------------------------------------------------------------

def _copy_tree(src: Path, dst: Path, files: list[str]) -> None:
    for rel in files:
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text((src / rel).read_text(encoding="utf-8"), encoding="utf-8")


SELFTEST_FILES = (
    "android/settings.gradle.kts",
    "android/app/build.gradle.kts",
    "android/labmesh/build.gradle.kts",
    "android/labmesh/src/main/java/io/godstone/labmesh/LabMeshApp.kt",
    "android/labmesh/src/test/java/io/godstone/labmesh/LabMeshAppTest.kt",
    "android/mesh/build.gradle.kts",
    "android/core/build.gradle.kts",
    "ios/project.yml",
    "ios/Godstone/Sources/LabMesh/LabMeshApp.swift",
    "ios/Godstone/Tests/LabMeshTests/LabMeshAppTests.swift",
    "docs/production-readiness/ARCHITECTURE_INVARIANTS.json",
    "docs/production/RELEASE_GATES_STATUS.json",
)


def selftest(root: Path) -> int:
    ok = True
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        _copy_tree(root, base, SELFTEST_FILES)
        clean = run(base)
        if clean.errors:
            ok = False
            print("selftest: the clean fixture must pass, got:")
            for e in clean.errors:
                print("   ", e)
        else:
            print("selftest: clean profile set PASSES")

        cases = [
            ("a lab source set in the LIGHT android source set",
             "android/app/build.gradle.kts",
             lambda t: t.replace('namespace = "io.godstone.app"',
                                 'namespace = "io.godstone.app"\n    sourceSets["main"].java.srcDir("src/labmesh/java")')),
            ("a :mesh shipping edge on LIGHT android",
             "android/app/build.gradle.kts",
             lambda t: t.replace("dependencies {", "dependencies {\n    implementation(project(\":mesh\"))", 1)),
            ("a readiness override in the LIGHT flavour",
             "android/app/build.gradle.kts",
             lambda t: t.replace('buildConfigField("boolean", "MESH_ENABLED", "false")',
                                 'buildConfigField("boolean", "MESH_ENABLED", "true")')),
            ("the lab masquerading as the shipping android identity",
             "android/labmesh/build.gradle.kts",
             lambda t: t.replace('applicationId = "io.godstone.labmesh"',
                                 'applicationId = "io.godstone.app"')),
            ("the lab dropping its :mesh dependency",
             "android/labmesh/build.gradle.kts",
             lambda t: t.replace('implementation(project(":mesh"))', "")),
            ("a synthetic READY setter in the lab",
             "android/labmesh/src/main/java/io/godstone/labmesh/LabMeshApp.kt",
             lambda t: t + "\nfun forceReady() { }\n"),
            ("the LIGHT ios app linking GodstoneMesh",
             "ios/project.yml",
             lambda t: t.replace("      - package: GodstonePackages\n        product: GodstoneCore\n    settings:\n      base:\n        PRODUCT_BUNDLE_IDENTIFIER: io.godstone.app",
                                 "      - package: GodstonePackages\n        product: GodstoneCore\n      - package: GodstonePackages\n        product: GodstoneMesh\n    settings:\n      base:\n        PRODUCT_BUNDLE_IDENTIFIER: io.godstone.app")),
            ("the lab sharing the shipping ios bundle id",
             "ios/project.yml",
             lambda t: t.replace("PRODUCT_BUNDLE_IDENTIFIER: io.godstone.labmesh",
                                 "PRODUCT_BUNDLE_IDENTIFIER: io.godstone.app")),
            ("readiness turned true in the manifest",
             "docs/production-readiness/ARCHITECTURE_INVARIANTS.json",
             lambda t: t.replace('"android_LINK_LAYER_READY": false',
                                 '"android_LINK_LAYER_READY": true')),
            ("a gate citing the lab",
             "docs/production/RELEASE_GATES_STATUS.json",
             lambda t: t.replace("{", '{"lab_note": "measured on LabMesh",', 1)),
        ]
        for label, rel, mutate in cases:
            with tempfile.TemporaryDirectory() as tmp2:
                d = Path(tmp2)
                _copy_tree(root, d, SELFTEST_FILES)
                target = d / rel
                target.write_text(mutate(target.read_text(encoding="utf-8")),
                                  encoding="utf-8")
                result = run(d)
                if result.errors:
                    print(f"selftest: KILLED  {label}")
                else:
                    ok = False
                    print(f"selftest: ESCAPED {label}")
    print("selftest:", "OK" if ok else "FAILED")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Lab-isolation gate (T54)")
    ap.add_argument("--root", default=".")
    ap.add_argument("--explain", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    root = Path(args.root).resolve()
    if args.selftest:
        return selftest(root)
    findings = run(root)
    if args.explain:
        for note in findings.notes:
            print("  note:", note)
    for error in findings.errors:
        print("::error::" + error, file=sys.stderr)
    print(f"lab isolation: {'FAILED' if findings.errors else 'PASSED'} "
          f"({len(findings.errors)} error(s), {len(findings.notes)} note(s))")
    return 1 if findings.errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
