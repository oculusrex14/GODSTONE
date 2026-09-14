#! /usr/bin/env python3
"""T54 readiness court: isolated experimental runtime targets.

The card's law, one witness each where the rule speaketh:

  W01 the profiles are RESOLVED FROM BUILD-CONFIG EVIDENCE, not narrated: the
      LIGHT android module's identity, source roots and link map, and the LIGHT
      iOS target's bundle, source allowlist and products
  W02 the LIGHT release carrieth NO lab source set, NO lab module edge and NO
      `:mesh` / `:llm` shipping edge
  W03 the LIGHT release carrieth NO readiness override (a capability field is
      false, and a mutated true is refused by name)
  W04 the LIGHT iOS application product-linketh only GodstoneCore, and a mutated
      GodstoneMesh edge is refused
  W05 the LAB carrieth its OWN identity, DISTINCT from the shipping one, on both
      platforms (and a lab that masqueradeth is refused)
  W06 the LAB reacheth the CANONICAL runtime components -- :mesh and
      GodstoneMesh -- so it testeth the real thing and never a twin
  W07 the LAB carrieth NO synthetic READY setter, and the readiness statement
      carrieth no parameter that could argue it true
  W08 the LAB carrieth its own explicit test capability on both platforms, and
      the targets are declared in the real project/graph files
  W09 the RELEASE MANIFEST is unchanged: readiness stays false and no gate citeth
      a lab
  W10 the gate's own controls are exercised (the selftest) and every control is
      refused by name
  W11 the real repository, judged by the real resolvers, standeth clean -- and
      the gate is wired into the repository checks, not merely written
  W12 the declared `srcDir(...)` hole stayeth closed: a lab root declared rather
      than materialized is still SEEN (the escape the first resolver allowed)

No external gate is closed by any witness; readiness stays false; the physical
device matrix stays external (T73-T75 own it). The lab targets are host-side
build-config facts -- declaring them proveth the SEPARATION, never a runtime
behaviour on a device.
"""
from __future__ import annotations

import importlib.util
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
CI = ROOT / "ci"

sys.path.insert(0, str(CI))


def _load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, CI / filename)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    # register BEFORE exec: a dataclass-using module needeth its own namespace in
    # sys.modules while it is being built (the first form of this loader did not,
    # and the loader itself failed rather than the law)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


resolver = _load("t54_profile_resolver", "profile_resolver.py")
gate = _load("t54_lab_isolation", "check_lab_isolation.py")


class T54ProfileResolutionTest(unittest.TestCase):
    """W01 -- the profiles, resolved from evidence."""

    def test_w01_the_profiles_are_resolved_from_build_config_evidence(self):
        profiles = resolver.resolve_profiles(ROOT)
        light_android = profiles["LIGHT_ANDROID"]["profile"]
        self.assertEqual(light_android.module, "app")
        self.assertEqual(light_android.path, "android/app")
        self.assertEqual(light_android.application_id, "io.godstone.app")
        self.assertIn("src/main/java", light_android.source_roots)
        self.assertTrue(light_android.source_files, "the shipping module carrieth sources")
        self.assertTrue(any(f.endswith(".kt") for f in light_android.source_files))

        light_ios = profiles["LIGHT_IOS"]["profile"]
        self.assertEqual(light_ios.target, "Godstone")
        self.assertEqual(light_ios.type, "application")
        self.assertEqual(light_ios.bundle_id, "io.godstone.app")
        self.assertIn("Godstone/Sources/App/GodstoneApp.swift", light_ios.sources)
        self.assertIn("GodstoneCore", light_ios.products)

        lab_android = profiles["LAB_ANDROID"]["profile"]
        self.assertEqual(lab_android.application_id, "io.godstone.labmesh")
        self.assertEqual(lab_android.namespace, "io.godstone.labmesh")

        lab_ios = profiles["LAB_IOS"]["profile"]
        self.assertEqual(lab_ios.type, "application")
        self.assertEqual(lab_ios.bundle_id, "io.godstone.labmesh")
        self.assertEqual(lab_ios.sources, ["Godstone/Sources/LabMesh"])

    def test_w12_a_declared_srcDir_is_seen_even_when_not_materialized(self):
        """A lab root declared with srcDir(...) is build-config truth."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "android" / "app").mkdir(parents=True)
            (root / "android" / "app" / "build.gradle.kts").write_text(
                'android {\n    namespace = "io.godstone.app"\n'
                '    sourceSets["main"].java.srcDir("src/labmesh/java")\n}\n',
                encoding="utf-8")
            profile = resolver.resolve_android(root, "app")
            self.assertIn("src/labmesh/java", profile.source_roots,
                          "a DECLARED source root is compiled whether or not it exists")
            findings = gate.Findings()
            gate.check_light_android(findings, profile)
            self.assertTrue(any("lab root" in e for e in findings.errors),
                            f"a declared lab root must be refused: {findings.errors}")


class T54LightIsolationTest(unittest.TestCase):
    """W02-W04 -- what the LIGHT release may not carry."""

    def setUp(self):
        self.profiles = resolver.resolve_profiles(ROOT)

    def test_w02_the_light_release_carrieth_no_lab_and_no_mesh_edge(self):
        android = self.profiles["LIGHT_ANDROID"]["profile"]
        self.assertNotIn("mesh", android.link_map)
        self.assertNotIn("llm", android.link_map)
        self.assertEqual(android.link_map, ["core"])
        for rel in android.source_files:
            self.assertNotIn("labmesh", rel.lower())
        findings = gate.Findings()
        gate.check_light_android(findings, android)
        self.assertEqual(findings.errors, [])

    def test_w03_a_readiness_override_in_the_light_flavour_is_refused(self):
        android = resolver.resolve_profiles(ROOT)["LIGHT_ANDROID"]["profile"]
        fields = dict(android.build_config)
        self.assertEqual(fields.get("MESH_ENABLED"), '"false"')
        self.assertEqual(fields.get("ORACLE_ENABLED"), '"false"')
        self.assertEqual(fields.get("SOS_ENABLED"), '"false"')
        self.assertEqual(fields.get("BULK_TRANSFER_ENABLED"), '"false"')

        # a mutated override is refused BY NAME
        android.build_config["MESH_ENABLED"] = '"true"'
        findings = gate.Findings()
        gate.check_light_android(findings, android)
        self.assertTrue(any("readiness override MESH_ENABLED" in e
                            for e in findings.errors), findings.errors)
        # ... and the quoted-"false" form is NOT an override (the first form of
        # the gate called it one, and this witness existed to catch that)
        android.build_config["MESH_ENABLED"] = '"false"'
        clean = gate.Findings()
        gate.check_light_android(clean, android)
        self.assertEqual([e for e in clean.errors if "override" in e], [])

    def test_w04_the_light_ios_app_links_only_the_core_product(self):
        ios = self.profiles["LIGHT_IOS"]["profile"]
        self.assertEqual(ios.products, ["GodstoneCore"])
        findings = gate.Findings()
        gate.check_light_ios(findings, ios)
        self.assertEqual(findings.errors, [])
        ios.products = ["GodstoneCore", "GodstoneMesh"]
        mutated = gate.Findings()
        gate.check_light_ios(mutated, ios)
        self.assertTrue(any("GodstoneMesh" in e for e in mutated.errors),
                        mutated.errors)
        for rel in ios.sources:
            self.assertNotIn("LabMesh", rel)


class T54LabTargetTest(unittest.TestCase):
    """W05-W08 -- what the LAB carrieth, and what it may not."""

    def setUp(self):
        self.profiles = resolver.resolve_profiles(ROOT)

    def test_w05_the_lab_carrieth_its_own_distinct_identity(self):
        for key, shipping in (("LAB_ANDROID", "io.godstone.app"),
                              ("LAB_IOS", "io.godstone.app")):
            profile = self.profiles[key]["profile"]
            ident = (profile.application_id if key == "LAB_ANDROID"
                     else profile.bundle_id)
            self.assertIsNotNone(ident)
            self.assertNotEqual(ident, shipping)
            self.assertEqual(ident, "io.godstone.labmesh")
        # a lab that masqueradeth is refused by name
        lab = resolver.resolve_profiles(ROOT)["LAB_ANDROID"]["profile"]
        lab.application_id = "io.godstone.app"
        findings = gate.Findings()
        gate.check_lab(findings, "android", lab, ROOT, "io.godstone.app")
        self.assertTrue(any("SHIPPING identity" in e for e in findings.errors),
                        findings.errors)

    def test_w06_the_lab_reacheth_the_canonical_components(self):
        android = self.profiles["LAB_ANDROID"]["profile"]
        self.assertIn("mesh", android.link_map)
        self.assertIn("core", android.link_map)
        ios = self.profiles["LAB_IOS"]["profile"]
        self.assertIn("GodstoneMesh", ios.products)
        self.assertIn("GodstoneCore", ios.products)
        # the lab entry must name the REAL composition, not a twin
        entry = (ROOT / "android/mesh/src/main/java/io/godstone/mesh/lab/LabRuntime.kt")
        text = entry.read_text(encoding="utf-8")
        self.assertIn("ComposedRuntimeHarness", text)
        self.assertIn("MeshNode", (ROOT / "android/mesh/src/main/java/io/godstone/mesh/runtime/ComposedRuntime.kt").read_text(encoding="utf-8"))
        swift = (ROOT / "ios/Godstone/Sources/GodstoneMesh/LabRuntime.swift").read_text(encoding="utf-8")
        self.assertIn("ComposedRuntimeHarness", swift)
        # a lab with no :mesh edge is refused by name
        starved = resolver.resolve_profiles(ROOT)["LAB_ANDROID"]["profile"]
        starved.link_map = ["core"]
        findings = gate.Findings()
        gate.check_lab(findings, "android", starved, ROOT, "io.godstone.app")
        self.assertTrue(any("twin rather than the canonical runtime" in e
                            for e in findings.errors), findings.errors)

    def test_w07_the_lab_cannot_manufacture_readiness(self):
        for profile, platform in ((self.profiles["LAB_ANDROID"]["profile"], "android"),
                                  (self.profiles["LAB_IOS"]["profile"], "ios")):
            findings = gate.Findings()
            gate.check_lab(findings, platform, profile, ROOT, "io.godstone.app")
            self.assertEqual([e for e in findings.errors if "READY setter" in e], [])

        kt = (ROOT / "android/mesh/src/main/java/io/godstone/mesh/lab/LabRuntime.kt").read_text(encoding="utf-8")
        self.assertIn("MANUFACTURES_READINESS: Boolean = false", kt)
        self.assertNotIn("fun setReady", kt)
        self.assertNotIn("LINK_LAYER_READY = true", kt)
        swift = (ROOT / "ios/Godstone/Sources/GodstoneMesh/LabRuntime.swift").read_text(encoding="utf-8")
        self.assertIn("manufacturesReadiness: Bool = false", swift)
        self.assertNotIn("func setReady", swift)
        # the readiness statement carrieth no parameter to argue with
        self.assertIn("fun readinessStatement(): LabReadiness = LabReadiness(",
                      kt)
        self.assertIn("static func readinessStatement() -> LabReadiness {", swift)

    def test_w08_the_lab_carrieth_its_own_test_capability(self):
        findings = gate.Findings()
        gate.check_lab_test_capability(findings, ROOT)
        self.assertEqual(findings.errors, [])
        for rel in ("android/labmesh/src/test/java/io/godstone/labmesh/LabMeshAppTest.kt",
                    "ios/Godstone/Tests/LabMeshTests/LabMeshAppTests.swift"):
            self.assertTrue((ROOT / rel).is_file(), rel)
        settings = (ROOT / "android/settings.gradle.kts").read_text(encoding="utf-8")
        self.assertIn('include(":labmesh")', settings)
        project = (ROOT / "ios/project.yml").read_text(encoding="utf-8")
        self.assertIn("  LabMesh:", project)
        self.assertIn("PRODUCT_BUNDLE_IDENTIFIER: io.godstone.labmesh", project)
        self.assertIn("  LabMeshTests:", project)
        # the lab is NOT a product flavour of the shipping app (the tier invariant
        # requires Gradle to declare exactly the shipping tiers)
        app_gradle = (ROOT / "android/app/build.gradle.kts").read_text(encoding="utf-8")
        self.assertNotIn('create("labmesh")', app_gradle)
        self.assertNotIn("labmesh", app_gradle.replace("labmesh/java", ""))


class T54ManifestAndControlsTest(unittest.TestCase):
    """W09-W11 -- the manifest, the gate's own controls, and the real wiring."""

    def test_w09_the_release_manifest_is_unchanged(self):
        findings = gate.Findings()
        gate.check_release_manifest(findings, ROOT)
        self.assertEqual(findings.errors, [])
        invariants = json.loads(
            (ROOT / "docs/production-readiness/ARCHITECTURE_INVARIANTS.json")
            .read_text(encoding="utf-8"))
        self.assertIs(invariants["readiness"]["android_LINK_LAYER_READY"], False)
        self.assertIs(invariants["readiness"]["ios_linkLayerReady"], False)

    def test_w10_the_gate_controls_are_exercised_and_all_killed(self):
        rc = gate.selftest(ROOT)
        self.assertEqual(rc, 0, "every selftest control must be refused by name")

    def test_w11_the_real_repository_standeth_clean_and_the_gate_is_wired(self):
        findings = gate.run(ROOT)
        self.assertEqual(findings.errors, [], findings.errors)
        self.assertTrue(any("LIGHT android" in n for n in findings.notes))
        self.assertTrue(any("LAB ios" in n for n in findings.notes))
        # the gate must be WIRED into the repository checks, not merely written
        repo_check = (ROOT / "ci/check_repository.py").read_text(encoding="utf-8")
        self.assertIn("check_lab_isolation", repo_check)
        workflow = (ROOT / ".github/workflows/repository-verification.yml").read_text(encoding="utf-8")
        self.assertIn("ci/check_lab_isolation.py", workflow)
        self.assertIn(":labmesh:testDebugUnitTest", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=2)
