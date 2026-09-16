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

    # GS-LAB-001 (T54): THE LAB MUST BE LAUNCHABLE -- asked here, where every other lab invariant is
    # asked, so that a lab nobody can start falleth the SAME gate as a lab that reacheth a shipping surface.
    launchable, why = check_the_lab_is_launchable()
    (f.notes if launchable else f.errors).append(why)

    # GS-LAB-001 step 1: ONE RETAINED RUNTIME, OWNED BY THE APPLICATION AND NOT BY A VIEW.
    retained, why = check_the_lab_runtime_is_retained()
    (f.notes if retained else f.errors).append(why)

    # GS-LAB-001 step 2: THE iOS TWIN -- @main, WindowGroup, one retained owner.
    iosOk, iosWhy = check_the_ios_lab_is_launchable()
    (f.notes if iosOk else f.errors).append(iosWhy)

    # GS-LAB-001 step 4: THE LIFECYCLE REACHETH THE SAME RUNTIME OWNER (the iOS isle, where it was named).
    lifeOk, lifeWhy = check_the_lab_lifecycle_reacheth_the_owner()
    (f.notes if lifeOk else f.errors).append(lifeWhy)

    # GS-LAB-001 step 4's navigation half: the five journeys the card nameth.
    navOk, navWhy = check_the_lab_navigateth_the_five_journeys()
    (f.notes if navOk else f.errors).append(navWhy)

    # GS-UX-001 step 5: 'a label reading Hold is not a gesture.'
    sosOk, sosWhy = check_the_lab_sos_is_a_real_gesture()
    (f.notes if sosOk else f.errors).append(sosWhy)

    # GS-UX-001 step 7: meaningful accessibility semantics on each journey.
    a11yOk, a11yWhy = check_the_lab_journeys_carry_accessibility_semantics()
    (f.notes if a11yOk else f.errors).append(a11yWhy)
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



def check_the_lab_is_launchable():
    """T54 / GS-LAB-001: THE LAB TARGET MUST BE LAUNCHABLE.

    A lab nobody can start is not a lab. The audit found the LabMesh application targets WITHOUT launchable
    entry points -- no activity at all in the lab manifest -- so this control asserteth BOTH halves: that the
    manifest declares one activity with the MAIN/LAUNCHER intent filter and an EXPLICIT exported status, and that
    the class it nameth really existeth in the lab's own source set.
    """
    # THE ROOT IS DERIVED FROM THIS FILE'S OWN LOCATION (ci/ sits beside android/), so the check needeth no
    # convention from its caller -- a first draft used a REPO name this control doth not carry, and A NAMEERROR IN A
    # MANDATORY CONTROL is exactly the kind of self-inflicted red this programme keepeth having to repair.
    root = Path(__file__).resolve().parent.parent
    manifest = root / "android/labmesh/src/main/AndroidManifest.xml"
    if not manifest.exists():
        return False, "the lab manifest is missing"
    text = manifest.read_text(encoding="utf-8")
    m = re.search(r"<activity[^>]*android:name=\"([^\"]+)\"([\s\S]*?)</activity>", text)
    if not m:
        return False, "the lab manifest declares NO activity: the target cannot be launched at all (T54)"
    name, body = m.group(1), m.group(2)
    if "android.intent.action.MAIN" not in body or "android.intent.category.LAUNCHER" not in body:
        return False, "the lab activity " + name + " carries no MAIN/LAUNCHER intent filter"
    head = m.group(0)
    if "android:exported" not in head:
        return False, "the lab activity " + name + " must declare its exported status EXPLICITLY"
    rel = name.replace(".", "/")
    for base in ("android/labmesh/src/main/java/", "android/labmesh/src/main/kotlin/"):
        if (root / (base + rel + ".kt")).exists() or (root / (base + rel + ".java")).exists():
            return True, "the lab is launchable: " + name + " (MAIN/LAUNCHER, exported, class present)"
    return False, "the lab activity " + name + " is declared but its class existeth nowhere in the lab source set"




def strip_kotlin_comments(text: str) -> str:
    """Kotlin line comments removed, so a COMMENT quoting a composition is not mistaken for one."""
    return "\n".join(re.sub(r"//.*$", "", line) for line in text.split("\n"))







def check_the_lab_journeys_carry_accessibility_semantics():
    """GS-UX-001 step 7: MEANINGFUL ACCESSIBILITY SEMANTICS ON EACH JOURNEY.

    The card: "Add navigation and meaningful accessibility semantics; exercise the rendered controls rather than setting model
    state directly." A visible word is not a semantic -- a screen reader announces the LABEL and a test addresses the
    IDENTIFIER -- so this invariant asketh, FOR EACH OF THE FIVE TABS, that the tab itself carrieth both. It asketh it ON THE
    TAB rather than anywhere in the file, which is round 268's own lesson: a declaration is not a journey.
    """
    root = Path(__file__).resolve().parent.parent
    text = ""
    for f in sorted((root / "ios/Godstone/Sources/LabMesh").glob("*.swift")):
        text += strip_kotlin_comments(f.read_text(encoding="utf-8").replace("///", "//")) + "\n"
    # PER TAB, OVER THE WHOLE SOURCE -- NOT OVER A SINGLE `{}`-BOUNDED CAPTURE. A `[\s\S]*?\n\s*\}` capture STOPPETH at the
    # FIRST TAB'S OWN CLOSING BRACE once a tab is written across lines, so tabs looked label-less while carrying labels -- and
    # ITS NEGATIVE CASE AGREED WITH THE FALSE RESULT, because A NEGATIVE CASE CAN ONLY REFUTE A CHECK THAT IS RIGHT ABOUT
    # EVERYTHING ELSE. When a POSITIVE case faileth, THE POSITIVE CASE IS THE EVIDENCE.
    if "TabView" not in text:
        return False, "the iOS lab carrieth no navigation at all (no TabView)"
    tabs = text
    # ON THE TAB'S OWN TEXT LINE -- NOT WITHIN A WINDOW THAT CAN REACH THE NEXT TAB. The second draft used a 400-character
    # window and ITS NEGATIVE CASE FAILED TO FAIL, because removing one tab's label left the NEIGHBOUR's within reach: A WINDOW
    # THAT REACHES PAST THE THING IT JUDGES IS NOT A CHECK, and this is the FIFTH species of this session's control family
    # (a comment for code, a declaration for a use, a repair breaking its neighbour, a bounded capture that truncateth, and
    # now a window that spans). The assertion is therefore made ON THE LINE: `Text("<name>").accessibilityLabel(`.
    missing = []
    for name in ("Identity", "Contacts", "Conversation", "SOS", "Diagnostics"):
        if not re.search(r'Text\("' + name + r'"\)\s*\.accessibilityLabel\("', tabs):
            missing.append(name)
    if missing:
        return False, "no ACCESSIBILITY LABEL on the tab(s): " + ", ".join(missing)
    if not re.search(r'\.accessibilityIdentifier\("lab\.tab\.', tabs):
        return False, "the tabs carrieth labels but no ACCESSIBILITY IDENTIFIER (a test cannot address them)"
    return True, "all five journeys carrieth accessibility labels and an identifier on the tab itself"


def check_the_lab_sos_is_a_real_gesture():
    """GS-UX-001 step 5: "A LABEL READING HOLD IS NOT A GESTURE."

    The card asketh for an actual CANCELLABLE hold with a MONOTONIC confirmation threshold AND an accessible
    alternative. So this invariant asketh three things of the lab's own sources: a real gesture existeth; its threshold
    is measured on a MONOTONIC clock (`ContinuousClock`), never on wall time; and an ACCESSIBLE ALTERNATIVE existeth,
    because a hold must never be the only road.
    """
    root = Path(__file__).resolve().parent.parent
    text = ""
    for f in sorted((root / "ios/Godstone/Sources/LabMesh").glob("*.swift")):
        text += strip_kotlin_comments(f.read_text(encoding="utf-8").replace("///", "//")) + "\n"
    if not re.search(r"onLongPressGesture|DragGesture|LongPressGesture", text):
        return False, "the lab's SOS carrieth NO gesture: a label reading Hold is not a gesture (GS-UX-001 step 5)"
    if "ContinuousClock" not in text:
        return False, "the hold's threshold is not measured on a MONOTONIC clock: a wall-clock step could arm it early"
    if re.search(r"Date\(\)", text):
        return False, "the lab's gesture measureth with Date(): wall time may step backwards and the threshold would drift"
    if 'Button("Send SOS' not in text:
        return False, "no ACCESSIBLE ALTERNATIVE to the hold existeth: a hold must never be the only road"
    return True, "the SOS is a real, cancellable hold on a MONOTONIC threshold, with an accessible alternative"


def check_the_lab_navigateth_the_five_journeys():
    """T54 / GS-LAB-001 step 4: MINIMAL NAVIGATION TO THE FIVE JOURNEYS THE CARD NAMETH.

    The card: "Add minimal navigation to identity, contacts, conversation, SOS and diagnostics views." So this invariant
    asketh that EACH of the five is reachable by name from the lab's own iOS sources -- a TabView without them, or a
    screen renamed away, would leave a journey unreachable while every other control stayed green.
    """
    root = Path(__file__).resolve().parent.parent
    text = ""
    for f in sorted((root / "ios/Godstone/Sources/LabMesh").glob("*.swift")):
        text += strip_kotlin_comments(f.read_text(encoding="utf-8").replace("///", "//")) + "\n"
    if "TabView" not in text:
        return False, "the iOS lab carrieth no navigation at all (no TabView): four of the five journeys are unreachable"
    # REACHABILITY, NOT MERELY DECLARATION -- and the negative case TAUGHT ME THE DIFFERENCE: with one tab's view
    # renamed, the control still PASSED, because a `struct LabSosView` DECLARATION remained in the file while the TAB no
    # longer reached it. A declaration is not a journey. So each view must appear AS AN INSTANTIATED TAB.
    # PER TAB, OVER THE WHOLE SOURCE -- NOT OVER A SINGLE `{}`-BOUNDED CAPTURE. A `[\s\S]*?\n\s*\}` capture STOPPETH at the
    # FIRST TAB'S OWN CLOSING BRACE once a tab is written across lines, so tabs looked label-less while carrying labels -- and
    # ITS NEGATIVE CASE AGREED WITH THE FALSE RESULT, because A NEGATIVE CASE CAN ONLY REFUTE A CHECK THAT IS RIGHT ABOUT
    # EVERYTHING ELSE. When a POSITIVE case faileth, THE POSITIVE CASE IS THE EVIDENCE.
    if "TabView" not in text:
        return False, "the iOS lab carrieth no navigation at all (no TabView)"
    tabs = text
    missing = [name for name in ("Identity", "Contacts", "Conversation", "SOS", "Diagnostics")
               if not re.search(r"Lab" + name + r"View\(\)\s*\.tabItem", tabs)]
    if missing:
        return False, "no TAB reacheth: " + ", ".join(missing) + " (a declaration is not a journey)"
    return True, "the lab navigateth all five journeys (identity, contacts, conversation, SOS, diagnostics)"


def check_the_lab_lifecycle_reacheth_the_owner():
    """T54 / GS-LAB-001 step 4: THE LIFECYCLE MUST REACH THE **SAME RUNTIME OWNER**.

    The card: "Connect foreground/background/protected-data lifecycle to the same runtime owner." A lifecycle told to a
    VIEW would be a second owner in all but name -- and a protected-data transition could pause one and not the other. So
    this invariant asketh BOTH halves, on the iOS isle where the owner was named: the App observeth its scene phase AND
    passeth it to the holder; and the HOLDER carrieth the state, not the view.
    """
    root = Path(__file__).resolve().parent.parent
    sources = root / "ios/Godstone/Sources/LabMesh"
    text = ""
    for f in sorted(sources.glob("*.swift")):
        text += strip_kotlin_comments(f.read_text(encoding="utf-8").replace("///", "//")) + "\n"
    if not re.search(r"@Environment\(\\\.scenePhase\)", text):
        return False, "the iOS lab's @main observeth no scene phase: its lifecycle reacheth nothing"
    if not re.search(r"holder\.lifecycleChanged\(to:", text):
        return False, "the scene phase is not passed to the RETAINED OWNER -- a view told instead would be a second owner"
    if not re.search(r"var lastLifecyclePhase", text):
        return False, "the runtime owner carrieth no lifecycle state of its own"
    return True, "the iOS lab's lifecycle reacheth the SAME retained runtime owner"


def check_the_ios_lab_is_launchable():
    """T54 / GS-LAB-001 step 2: THE iOS LAB MUST HAVE ITS OWN @main APP WITH A RETAINED RUNTIME OWNER.

    The card: "Add an iOS @main App inside Sources/LabMesh, with a WindowGroup for the lab root and ONE RETAINED RUNTIME
    OWNER. Keep the existing shipping App entry excluded from the lab target." So three things are asked: the @main
    existeth in the LAB'S OWN sources; it carrieth a WindowGroup; and it OWNETH a runtime outside any view -- with the
    SHIPPING entry left where it is (this control neither moves nor copies it).
    """
    root = Path(__file__).resolve().parent.parent
    sources = root / "ios/Godstone/Sources/LabMesh"
    if not sources.exists():
        return False, "the iOS lab source directory is missing"
    text = ""
    for f in sorted(sources.glob("*.swift")):
        text += strip_kotlin_comments(f.read_text(encoding="utf-8").replace("///", "//")) + "\n"
    if "@main" not in text:
        return False, "the iOS lab carrieth NO @main entry: the target cannot be launched"
    if "WindowGroup" not in text:
        return False, "the iOS lab's @main carrieth no WindowGroup for the lab root"
    # THE CALL MAY BE THROWING -- round 266's own fix added `try!`, WHICH BROKE THIS REGEX, AND THE CONTROL WENT RED FOR A
    # REASON THAT HAD NOTHING TO DO WITH THE LAB. A CONTROL MUST SURVIVE THE REPAIRS MADE BESIDE IT, so the `try` is optional.
    if not re.search(r"runtime\s*=\s*(?:try!?\s*)?LabRuntime\.compose\(\)", text):
        return False, "the iOS lab owns no runtime composed by an OWNER (LabRuntime.compose() must appear in a holder)"
    shipping = root / "ios/Godstone/Sources/App/GodstoneApp.swift"
    if not shipping.exists():
        return False, "the shipping App entry is MISSING: the lab's @main must stand BESIDE it, never replace it"
    return True, "the iOS lab is launchable: @main + WindowGroup + one retained runtime owner, beside the shipping entry"


def check_the_lab_runtime_is_retained():
    """T54 / GS-LAB-001 step 1: ONE RETAINED RUNTIME, OWNED BY THE APPLICATION -- NOT BY A VIEW.

    The card's own words. So this invariant asserteth three things: the lab manifest declares its OWN Application class;
    that class carrieth a `runtime`; and THE COMPOSITION SITE (`LabMeshApp.compose()`) appeareth in the APPLICATION and NOT
    in the activity -- because a runtime composed by a view is composed again on every recomposition, and the lab declareth
    ONE.
    """
    root = Path(__file__).resolve().parent.parent
    man = (root / "android/labmesh/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
    m = re.search(r'<application[^>]*android:name="([^"]+)"', man)
    if not m:
        return False, "the lab declares no Application owner: the retained runtime hath nowhere to live"
    owner_rel = m.group(1).replace(".", "/") + ".kt"
    owner = root / "android/labmesh/src/main/java" / owner_rel
    if not owner.exists():
        return False, "the lab's Application owner " + m.group(1) + " hath no source file"
    # COMMENTS ARE STRIPPED AND THE COMPOSITION'S OWN FORM IS MATCHED, because a first draft searched the raw text for
    # `LabMeshApp.compose()` -- AND THE FILE'S OWN DOC COMMENT QUOTES IT -- so the invariant was satisfied by a COMMENT.
    # THE NEGATIVE CASE CAUGHT IT (the composition was replaced and the control still passed), which is the whole reason
    # this file insisteth on negative cases. The same trap was recorded at rounds 163 and 208 for other controls.
    text = strip_kotlin_comments(owner.read_text(encoding="utf-8"))
    if not re.search(r"by lazy \{ *LabMeshApp\.compose\(\)", text):
        return False, "the Application owner " + m.group(1) + " never COMPOSES the runtime (a comment mentioning it is not a composition)"
    activity = root / "android/labmesh/src/main/java/io/godstone/labmesh/LabMainActivity.kt"
    if activity.exists() and re.search(r"LabMeshApp\.compose\(\)", strip_kotlin_comments(activity.read_text(encoding="utf-8"))):
        return False, "the ACTIVITY composeth the runtime: it must be the Application owner's, not a view's"
    return True, "one retained lab runtime, owned by " + m.group(1) + " and composed nowhere else"


if __name__ == "__main__":
    raise SystemExit(main())
