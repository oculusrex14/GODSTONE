#!/usr/bin/env python3
"""Unit tests for Swift test bundle resolution in run_board1_integration.py.

Validates that:
  1. The per-target layout (`GodstoneMeshTests.xctest`, Xcode 27 / Swift 6.4) is resolved.
  2. The merged package layout (`GodstoneFoundationPackageTests.xctest`, Xcode 16 / Swift 6.1) is resolved.
  3. When both exist, `GodstoneMeshTests.xctest` is deterministically preferred.
  4. An unrelated bundle (e.g. `GodstoneCoreTests.xctest`) is NOT accepted as the mesh test runner.
  5. Absence of either candidate raises Refused with all tried candidate paths in the message.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools.readiness import run_board1_integration as rbi


class DummyRunner:
    def __init__(self) -> None:
        self._swift_bundle: Path | None = None

    resolve_swift_bundle = rbi.Runner.resolve_swift_bundle


class TestBoard1BundleResolution(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.debug_dir = self.root / "ios" / "Packages" / "GodstoneFoundation" / ".build" / "debug"
        self.debug_dir.mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_per_target_bundle_resolved(self) -> None:
        mesh_bundle = self.debug_dir / "GodstoneMeshTests.xctest"
        mesh_bundle.mkdir()
        runner = DummyRunner()
        with patch.object(rbi, "REPO", self.root):
            resolved = runner.resolve_swift_bundle()
            self.assertEqual(resolved, mesh_bundle)

    def test_merged_package_bundle_resolved(self) -> None:
        pkg_bundle = self.debug_dir / "GodstoneFoundationPackageTests.xctest"
        pkg_bundle.mkdir()
        runner = DummyRunner()
        with patch.object(rbi, "REPO", self.root):
            resolved = runner.resolve_swift_bundle()
            self.assertEqual(resolved, pkg_bundle)

    def test_deterministic_priority_when_both_exist(self) -> None:
        mesh_bundle = self.debug_dir / "GodstoneMeshTests.xctest"
        mesh_bundle.mkdir()
        pkg_bundle = self.debug_dir / "GodstoneFoundationPackageTests.xctest"
        pkg_bundle.mkdir()
        runner = DummyRunner()
        with patch.object(rbi, "REPO", self.root):
            resolved = runner.resolve_swift_bundle()
            self.assertEqual(resolved, mesh_bundle)

    def test_unrelated_bundle_refused(self) -> None:
        core_bundle = self.debug_dir / "GodstoneCoreTests.xctest"
        core_bundle.mkdir()
        runner = DummyRunner()
        with patch.object(rbi, "REPO", self.root):
            with self.assertRaises(rbi.Refused) as ctx:
                runner.resolve_swift_bundle()
            self.assertIn("GodstoneMeshTests.xctest", str(ctx.exception))
            self.assertIn("GodstoneFoundationPackageTests.xctest", str(ctx.exception))

    def test_absence_refused_with_candidates_diagnostics(self) -> None:
        runner = DummyRunner()
        with patch.object(rbi, "REPO", self.root):
            with self.assertRaises(rbi.Refused) as ctx:
                runner.resolve_swift_bundle()
            msg = str(ctx.exception)
            self.assertIn("THE macOS TEST BUNDLE IS ABSENT", msg)
            self.assertIn(str(self.debug_dir / "GodstoneMeshTests.xctest"), msg)
            self.assertIn(str(self.debug_dir / "GodstoneFoundationPackageTests.xctest"), msg)


if __name__ == "__main__":
    unittest.main()
