#! /usr/bin/env python3
"""T62-T65/T81 readiness court (python isle): the NATIVE/MODEL artifact machinery.

These five tasks need approved native and model binaries that nobody here may
produce, vendor or licence. That much is external and stays blocked. What is NOT
external is the machinery that will VALIDATE and CONSUME those artifacts when
they arrive, and this court proves it exists and refuses every absent,
unpinned, misidentified and unlicensed artifact.

  W01  the model register EXISTS with a complete per-artifact SCHEMA: identity,
       kind, tier, source coordinates, output name, digest, size, licence,
       tokenizer, context length, embedding and native ABI
  W02  the native toolchain block names its revision, ABIs and build flags
  W03  EVERY artifact standeth UNPINNED today: no digest is recorded, and the
       register says so rather than carrying a guessed hash
  W04  no licence is INVENTED for an absent artifact -- the field is null, not a
       plausible-looking string
  W05  a MISSING digest is recorded honestly, and a MALFORMED digest would be
       refused by the register's own law
  W06  the release surface prohibits a placeholder/stub fallback: the shipping
       path may not substitute a stub for an absent model
  W07  the NATIVE_MODELS gate is BLOCKED and carrieth no closure evidence
  W08  no readiness flag is flipped by this court

The register is a RECEIPT FORM: it says exactly what must arrive and how it will
be judged. Nothing here fabricates a model, and no gate is closed.
"""
from __future__ import annotations

import json
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

MODELS_LOCK = "docs/packaging/MODELS.lock.json"
BLOCKERS = "docs/production-readiness/EXTERNAL_BLOCKERS.json"
BUILD_STATE = "docs/production-readiness/BUILD_STATE.json"

#: The five tasks this court covers, and the task each artifact ultimately serves.
NATIVE_TASKS = ("T62", "T63", "T64", "T65", "T81")

SHA256 = re.compile(r"[0-9a-f]{64}")

#: Every field a receipt must eventually carry. A register that dropped one of
#: these could not judge an artifact when it arrived.
REQUIRED_ARTIFACT_FIELDS = (
    "id", "kind", "tiers", "repo", "source_commit", "source_file",
    "output_file", "sha256", "size_bytes", "license", "tokenizer",
    "context_tokens", "embedding", "native_abi",
)


def load(rel):
    return json.loads((ROOT / rel).read_text(encoding="utf-8"))


def register():
    return load(MODELS_LOCK)


class NativeArtifactReceiptCourt(unittest.TestCase):
    """W01-W06 -- the receipt form the artifacts will be judged against."""

    maxDiff = None

    def test_w01_the_register_carries_a_complete_artifact_schema(self):
        document = register()
        self.assertIsInstance(document.get("schema"), int)
        artifacts = document.get("artifacts")
        self.assertIsInstance(artifacts, list)
        self.assertTrue(artifacts, "the register carrieth no artifact at all")
        for artifact in artifacts:
            for field in REQUIRED_ARTIFACT_FIELDS:
                self.assertIn(field, artifact,
                              f"artifact {artifact.get('id')!r} lacketh the field "
                              f"{field!r}: the register could not judge it on arrival")
            self.assertTrue(artifact["id"])
            self.assertIsInstance(artifact["tiers"], list)
            self.assertTrue(artifact["output_file"])

    def test_w02_the_native_toolchain_block_names_its_build_identity(self):
        native = register().get("native")
        self.assertIsInstance(native, dict, "the register carrieth no native block")
        self.assertIn("llama_revision", native)
        self.assertTrue(native.get("abis"), "the native block nameth no ABI")
        self.assertTrue(native.get("build_flags"), "the native block nameth no flags")
        self.assertTrue(native.get("toolchains"), "the native block nameth no toolchain")
        for tool in native["toolchains"]:
            self.assertTrue(tool.get("name"))
            self.assertTrue(tool.get("version"))

    def test_w03_every_artifact_stands_unpinned_today(self):
        """No digest is recorded, and the register SAYS SO."""
        document = register()
        unpinned = [a for a in document["artifacts"] if a.get("sha256") is None]
        self.assertEqual(len(document["artifacts"]), len(unpinned),
                         "an artifact carrieth a digest, but no approved binary has "
                         "been supplied: a digest nobody measured would be invented")
        self.assertEqual("UNPINNED", document.get("status"),
                         "the register must declare its own status as UNPINNED")
        # ... and the SBOM must count them as unknown rather than omitting them
        sbom = load("docs/supplychain/SBOM.json")
        self.assertTrue(any("model" in str(u).lower() for u in sbom.get("unknowns", [])),
                        "the SBOM must record the unpinned models as an unknown")

    def test_w04_no_licence_is_invented_for_an_absent_artifact(self):
        for artifact in register()["artifacts"]:
            self.assertIsNone(
                artifact.get("license"),
                f"artifact {artifact['id']!r} carrieth a licence but no artifact has "
                "arrived: a licence nobody supplied would be fabricated external "
                "approval")

    def test_w05_a_digest_is_absent_or_a_valid_sha256(self):
        """The register's own law: a digest is either absent or a real SHA-256."""
        for artifact in register()["artifacts"]:
            digest = artifact.get("sha256")
            if digest is None:
                continue
            self.assertRegex(digest, SHA256,
                             f"artifact {artifact['id']!r} carrieth a malformed digest")
            self.assertIsInstance(artifact.get("size_bytes"), int,
                                  f"artifact {artifact['id']!r} carrieth a digest but no "
                                  "size: a digest without a size cannot be verified")

    def test_w06_the_shipping_path_may_not_substitute_a_stub(self):
        """A placeholder fallback for an absent model is the failure this gate
        exists to prevent. Three real mechanisms enforce it, and this witness
        checks EACH rather than looking for a reassuring word in a field."""
        # (1) the register carrieth NO closure evidence, and its own court
        #     (`test_blocked_external.py` W03) refuses any, by name.
        native = next(b for b in load(BLOCKERS)["blockers"] if b["id"] == "NATIVE_MODELS")
        self.assertIsNone(native["closure_evidence"])
        self.assertTrue(native["required_artifact_schema"],
                        "the gate must name the artifact schema it will judge")

        # (2) the blocked-external court really does redden on a fixture closure:
        #     drive the REAL checker over a register whose gate claims one.
        import tempfile, shutil
        # imported through sys.path, exactly as the sibling courts do: a
        # spec_from_file_location load leaves the module unregistered and its
        # dataclasses unresolved.
        import blockers as blockers_module
        with tempfile.TemporaryDirectory() as tmp:
            tree = Path(tmp)
            for rel in ("docs/production-readiness/EXTERNAL_BLOCKERS.json",
                        "docs/production-readiness/BUILD_STATE.json",
                        "docs/production-readiness/TASKS.json",
                        "docs/production-readiness/ARCHITECTURE_INVARIANTS.json",
                        "docs/production/RELEASE_GATES_STATUS.json"):
                dest = tree / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(ROOT / rel, dest)
            register_path = tree / "docs/production-readiness/EXTERNAL_BLOCKERS.json"
            document = json.loads(register_path.read_text(encoding="utf-8"))
            for blocker in document["blockers"]:
                if blocker["id"] == "NATIVE_MODELS":
                    blocker["closure_evidence"] = "a fixture"
            register_path.write_text(json.dumps(document), encoding="utf-8")
            findings = blockers_module.findings(tree)
            self.assertTrue(any(f.startswith("gate-closed-by-fixture") for f in findings),
                            f"a fixture-closed NATIVE_MODELS gate was ACCEPTED: {findings}")

        # (3) the LIGHT artifact inspector really refuses a bundled model.
        from subprocess import run
        result = run(["python3", "scripts/inspect_android_artifacts.py", "--selftest"],
                     cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(0, result.returncode,
                         "the artifact inspector's own selftest failed:\n"
                         f"{result.stdout}\n{result.stderr}")
        self.assertIn("FAILED", result.stdout,
                      "the inspector's selftest must demonstrate a REFUSAL; a selftest "
                      "that only shows acceptance proves nothing")


class TheNativeGateStaysBlocked(unittest.TestCase):
    """W07-W08 -- absent artifacts keep the five tasks blocked."""

    def test_w07_the_gate_is_blocked_and_carries_no_closure_evidence(self):
        blockers = load(BLOCKERS)
        native = next(b for b in blockers["blockers"] if b["id"] == "NATIVE_MODELS")
        self.assertIsNone(native["closure_evidence"],
                          "NATIVE_MODELS carrieth closure evidence")
        self.assertTrue(native["required_artifact_schema"])
        self.assertTrue(native["verification_commands"])
        self.assertTrue(native["approved_source_or_human_role"])
        for task in NATIVE_TASKS:
            entry = load(BUILD_STATE)["completed_tasks"][task]
            self.assertEqual("BLOCKED_EXTERNAL", entry["status"], task)
            self.assertIsNone(entry.get("closure_evidence"),
                              f"{task} carrieth closure evidence")

    def test_w08_no_readiness_flag_is_flipped(self):
        invariants = load("docs/production-readiness/ARCHITECTURE_INVARIANTS.json")
        self.assertIs(False, invariants["readiness"].get("android_LINK_LAYER_READY"))
        self.assertIs(False, invariants["readiness"].get("ios_linkLayerReady"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
