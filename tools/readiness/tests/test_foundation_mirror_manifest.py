"""Clone-carried manifest inputs, generated-output independence and drift refusal."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / "scripts" / "sync_ios_foundation_package.py"
PACKAGE = "ios/Packages/GodstoneFoundation"
EXPECTATION = "Sources/GodstoneMesh/SQLCipherTrustedExpectation.swift"
MIRRORED = (
    ("ios/Godstone/Sources/GodstoneCore", "Sources/GodstoneCore", "CoreThing.swift"),
    ("ios/Godstone/Sources/GodstoneMesh", "Sources/GodstoneMesh", "MeshThing.swift"),
    ("ios/Godstone/Tests/GodstoneCoreTests", "Tests/GodstoneCoreTests", "CoreThingTests.swift"),
    ("ios/Godstone/Tests/GodstoneMeshTests", "Tests/GodstoneMeshTests", "MeshThingTests.swift"),
    ("ios/Godstone/Tests/LabMeshTests", "Tests/LabMeshTests", "LabThingTests.swift"),
)


class FoundationMirrorManifestLaw(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="gs-foundation-manifest-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "scripts" / SCRIPT.name).write_bytes(SCRIPT.read_bytes())
        (self.root / PACKAGE).mkdir(parents=True)
        (self.root / PACKAGE / "Package.swift").write_text("// package\n", encoding="utf-8")
        for canonical, mirror, name in MIRRORED:
            for directory in (canonical, f"{PACKAGE}/{mirror}"):
                path = self.root / directory / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"// source {name}\n", encoding="utf-8")
        (self.root / ".gitignore").write_text(
            f"ios/Godstone/{EXPECTATION}\n{PACKAGE}/{EXPECTATION}\n", encoding="utf-8")
        self.git("init", "-q")
        self.git("config", "user.email", "court@example.invalid")
        self.git("config", "user.name", "foundation manifest court")

    def git(self, *args: str) -> None:
        subprocess.run(["git", "-C", str(self.root), *args],
                       capture_output=True, text=True, check=True)

    def commit(self) -> None:
        self.git("add", "-A", ".")
        self.git("commit", "-q", "-m", "fixture")

    def sync(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, str(self.root / "scripts" / SCRIPT.name), *args],
                              capture_output=True, text=True, cwd=self.root, timeout=300)

    def seal(self) -> None:
        self.commit()
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.commit()
        baseline = self.sync("--check")
        self.assertEqual(baseline.returncode, 0, baseline.stderr)

    def expectation_paths(self) -> tuple[Path, Path]:
        return (self.root / "ios/Godstone" / EXPECTATION,
                self.root / PACKAGE / EXPECTATION)

    def place_expectation(self) -> None:
        for path in self.expectation_paths():
            path.write_text("// generated lane expectation\n", encoding="utf-8")

    def test_sealing_with_generated_output_survives_a_clean_checkout(self) -> None:
        self.place_expectation()
        self.seal()
        for path in self.expectation_paths():
            path.unlink()
        result = self.sync("--check")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_generated_output_does_not_change_a_sealed_manifest(self) -> None:
        self.seal()
        self.place_expectation()
        result = self.sync("--check")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_tracked_canonical_source_drift_is_refused(self) -> None:
        self.seal()
        victim = self.root / MIRRORED[0][0] / MIRRORED[0][2]
        victim.write_text("// changed canonical source\n", encoding="utf-8")
        result = self.sync("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn(str(Path(PACKAGE) / MIRRORED[0][1] / MIRRORED[0][2]), result.stderr)

    def test_tracked_mirror_source_drift_is_refused(self) -> None:
        self.seal()
        victim = self.root / PACKAGE / MIRRORED[1][1] / MIRRORED[1][2]
        victim.write_text("// changed mirror source\n", encoding="utf-8")
        result = self.sync("--check")
        self.assertEqual(result.returncode, 1)
        self.assertIn(str(Path(PACKAGE) / MIRRORED[1][1] / MIRRORED[1][2]), result.stderr)

    def test_a_false_manifest_digest_is_refused(self) -> None:
        self.seal()
        path = self.root / PACKAGE / "SOURCE_MANIFEST.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        manifest["files"][f"{MIRRORED[0][1]}/{MIRRORED[0][2]}"] = "0" * 64
        path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        self.assertEqual(self.sync("--check").returncode, 1)

    def test_new_sources_can_be_generated_but_must_be_staged_for_check(self) -> None:
        self.seal()
        source = self.root / MIRRORED[0][0] / "NewSource.swift"
        source.write_text("// new canonical source\n", encoding="utf-8")
        generated = self.sync()
        self.assertEqual(generated.returncode, 0, generated.stderr)
        self.assertEqual(self.sync("--check").returncode, 1)
        self.commit()
        committed = self.sync("--check")
        self.assertEqual(committed.returncode, 0, committed.stderr)


if __name__ == "__main__":
    unittest.main()
