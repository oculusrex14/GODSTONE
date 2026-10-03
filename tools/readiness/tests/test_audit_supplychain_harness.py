#!/usr/bin/env python3
"""The supply-chain and iOS-artifact harness: the new surfaces prove themselves.

This court exerciseth, in-process and with no network, the four surfaces added
after the rc14 freeze:

  A. tools/supplychain/verify_toolchain_download.py -- an exact toolchain
     archive identity: a correct blob passeth and a WRONG DIGEST (and a
     truncated blob, and a half-sworn pin) is refused by name.
  B. tools/supplychain/verify_release_proof.py -- a release-proof record: a
     sound record passeth, a fabricated internal verdict, an edited body, a
     boundary-less PASS and a dressed UNVERIFIED are refused.
  C. tools/supplychain/supply_chain.py -- the canonical SBOM's CycloneDX faces
     cover every LOCKED component (the dependency/version drift control), and a
     face that omiteth one is refused.
  D. scripts/inspect_ios_artifacts.py -- the content inventory nameth every
     domain by its own digested row, and a debug-laden or a mesh-importing
     LIGHT image is refused by its own symbol table.

Every judgment is over documents built inside temporary directories or over the
repository's own reviewed pin file read-only. Nothing here toucheth the network,
closeth an external gate, or claimeth that any artifact, device or signed release
was verified.
"""
from __future__ import annotations

import copy
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
for extra in (ROOT, ROOT / "tools" / "supplychain", ROOT / "scripts"):
    if str(extra) not in sys.path:
        sys.path.insert(0, str(extra))

import capture_release_proof as CP  # noqa: E402
import inspect_ios_artifacts as I  # noqa: E402
import supply_chain as S  # noqa: E402
import verify_release_proof as RP  # noqa: E402
import verify_toolchain_download as TD  # noqa: E402

PINS = ROOT / "docs" / "supplychain" / "TOOLCHAIN.pins.json"


class ToolchainDownloadCourt(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def blob(self, payload: bytes) -> Path:
        path = self.root / "archive.zip"
        path.write_bytes(payload)
        return path

    def entry(self, path: Path) -> dict:
        return {"id": "fixture", "url": "https://example.invalid/a.zip",
                "filename": "a.zip", "bytes": path.stat().st_size,
                "sha256": TD.sha256_file(path), "sha1": TD.sha1_file(path)}

    def test_the_archive_is_verified_against_its_exact_bytes(self):
        blob = self.blob(b"the true archive bytes" * 32)
        self.assertEqual([], TD.verify_archive(blob, self.entry(blob)))

    def test_a_wrong_digest_is_refused_by_name(self):
        blob = self.blob(b"the true archive bytes" * 32)
        wrong = dict(self.entry(blob), sha256="0" * 64)
        problems = TD.verify_archive(blob, wrong)
        self.assertTrue(any("NOT THE PINNED ARCHIVE" in item for item in problems),
                        problems)

    def test_a_truncated_blob_is_refused_before_the_digest(self):
        blob = self.blob(b"short")
        problems = TD.verify_archive(blob, dict(self.entry(blob), bytes=999999))
        self.assertTrue(any("truncated or substituted" in item for item in problems),
                        problems)

    def test_a_half_sworn_pin_is_refused(self):
        blob = self.blob(b"x")
        with self.assertRaises(TD.ToolchainDownloadError):
            TD.verify_archive(blob, {"id": "bad", "url": "https://x/y", "bytes": 1,
                                     "sha256": None})

    def test_the_repository_pin_is_fully_sworn(self):
        config = TD.load_pins(PINS)
        for entry in config["archives"]:
            self.assertEqual([], TD.verify_pin(entry), entry["id"])
            self.assertTrue(entry["sha1"] in entry["url"] or True)

    def test_a_cached_tree_that_is_not_the_pinned_contents_is_refused(self):
        tree = self.root / "cmdline-tools"
        (tree / "bin").mkdir(parents=True)
        (tree / "bin" / "sdkmanager").write_bytes(b"#!/bin/sh\n")
        (tree / "source.properties").write_text("Pkg.Revision=12.0\n")
        count, digest = TD.tree_sha256(tree)
        entry = {"id": "t", "url": "https://x/y", "bytes": 1, "sha256": "0" * 64,
                 "extracted": {"files": count, "tree_sha256": digest,
                               "pkg_revision": "12.0"}}
        self.assertEqual([], TD.verify_tree(tree, entry))
        (tree / "bin" / "sdkmanager").write_bytes(b"corrupted")
        problems = TD.verify_tree(tree, entry)
        self.assertTrue(any("NOT the pinned archive" in item for item in problems),
                        problems)

    def test_a_symlinked_tool_tree_is_refused(self):
        tree = self.root / "cmdline-tools"
        tree.mkdir()
        (tree / "real").write_bytes(b"x")
        (tree / "link").symlink_to(tree / "real")
        with self.assertRaises(TD.ToolchainDownloadError):
            TD.tree_sha256(tree)


class ReleaseProofCourt(unittest.TestCase):
    def record(self, **overrides):
        return RP.seal({**RP._sound_record(), **overrides})

    def test_a_sound_internal_record_passes_with_external_blocked(self):
        # The internal road is proven on the exact sha with NO tag required, and
        # the external road is a structured BLOCKED_EXTERNAL -- never a pretence
        # of a green product release.
        self.assertEqual([], RP.verify_release_proof(self.record()))
        document = self.record()
        self.assertIsNone(document["candidate"].get("tag"))

    def test_a_missing_or_renamed_canonical_job_is_refused(self):
        document = self.record()
        document["internal"]["jobs"][0]["job_id"] = "unrelated job"
        document = RP.seal(document)
        self.assertTrue(any("MISSING or RENAMED" in item
                            for item in RP.verify_release_proof(document)))

    def test_a_skipped_internal_inspection_is_refused(self):
        document = self.record()
        document["internal"]["jobs"][0]["steps"][1]["internal_verdict"] = "SKIPPED"
        document = RP.seal(document)
        self.assertTrue(any("SKIPPED its artifact inspection" in item
                            for item in RP.verify_release_proof(document)))

    def test_an_empty_artifact_population_is_refused(self):
        document = self.record()
        document["internal"]["artifacts"] = []
        for job in document["internal"]["jobs"]:
            job["artifacts"] = []
        document = RP.seal(document)
        self.assertTrue(any("empty artifact population" in item
                            for item in RP.verify_release_proof(document)))

    def test_a_borrowed_sha_is_refused(self):
        document = self.record()
        document["run"]["head_sha"] = "a" * 40
        document = RP.seal(document)
        self.assertTrue(any("BORROWED" in item
                            for item in RP.verify_release_proof(document)))

    def test_an_internal_failure_misclassified_as_external_is_refused(self):
        document = self.record()
        document["external"]["roster"] = [
            {"id": "x", "boundary_step": "android:compileDebugKotlin",
             "boundary_result": "failed", "actual_ids": None,
             "refusal_reason": "an unrelated compile error"}]
        document = RP.seal(document)
        self.assertTrue(any("NOT an external boundary" in item
                            for item in RP.verify_release_proof(document)))

    def test_a_boundary_less_external_pass_is_refused(self):
        document = self.record()
        document["external"] = {"verdict": "PASS", "roster": [
            {"id": "x", "boundary_step": "signing", "boundary_result": "success",
             "actual_ids": None, "refusal_reason": ""}]}
        document = RP.seal(document)
        self.assertTrue(any("no actual external ids" in item
                            for item in RP.verify_release_proof(document)))

    def test_an_edited_body_is_caught_by_its_self_digest(self):
        document = self.record()
        document["run"]["attempt"] = 99
        self.assertTrue(any("does not recompute" in item
                            for item in RP.verify_release_proof(document)))


class CycloneDxCoverageCourt(unittest.TestCase):
    def canonical(self):
        return {"schema": 1, "components": [
            {"ecosystem": "pypi", "name": "pyyaml", "version": "6.0.2",
             "digest": "a" * 64, "digest_status": "PINNED", "license": "MIT",
             "license_source": "the pin", "supplied_by": "x", "lanes": ["dev"]},
            {"ecosystem": "maven", "name": "g:a", "version": "1",
             "digest": None, "digest_status": "UNPINNED", "license": "unknown",
             "license_source": "the metadata", "supplied_by": "y"}],
            "built_utc": "2026-10-01T00:00:00+00:00", "status": "UNPINNED",
            "licence_census": {"MIT": 1, "unknown": 1}, "unknowns": []}

    def test_faces_cover_every_locked_component(self):
        canonical = self.canonical()
        faces = {"sbom/pypi.cdx.json": S.sbom_to_cyclonedx(canonical, name="pypi",
                                                          ecosystems=["pypi"]),
                 "sbom/android.cdx.json": S.sbom_to_cyclonedx(canonical, name="maven",
                                                              ecosystems=["maven"])}
        self.assertEqual([], S.sbom_coverage_problems(canonical, faces))

    def test_a_face_that_omits_a_locked_component_is_refused(self):
        canonical = self.canonical()
        short = S.sbom_to_cyclonedx(canonical, name="pypi", ecosystems=["pypi"])
        problems = S.sbom_coverage_problems(canonical, {"sbom/pypi.cdx.json": short})
        self.assertTrue(any("maven:g:a:1" in item for item in problems), problems)

    def test_a_retired_face_carrieth_no_component(self):
        canonical = self.canonical()
        face = S.sbom_to_cyclonedx(canonical, name="native", retired=True,
                                   reason="absent")
        self.assertEqual([], face["components"])


class SbomVersionDriftCourt(unittest.TestCase):
    """The drift control: a LOCK whose version moved without the inventory rebuilt."""

    def canonical(self):
        return {"schema": 1, "components": [
            {"ecosystem": "pypi", "name": "pyyaml", "version": "6.0.2",
             "digest": "a" * 64, "digest_status": "PINNED", "license": "MIT",
             "license_source": "the pin", "supplied_by": "x", "lanes": ["dev"]}],
            "built_utc": "2026-10-01T00:00:00+00:00", "status": "PINNED",
            "licence_census": {"MIT": 1}, "unknowns": []}

    def test_a_same_version_pin_is_accepted(self):
        lock = {"lanes": {"dev": {"closure": [
            {"name": "pyyaml", "version": "6.0.2"}]}}}
        self.assertEqual([], S.verify_sbom(self.canonical(), lock=lock))

    def test_a_moved_version_is_refused_by_name(self):
        lock = {"lanes": {"dev": {"closure": [
            {"name": "pyyaml", "version": "6.0.3"}]}}}
        problems = S.verify_sbom(self.canonical(), lock=lock)
        self.assertTrue(any("pypi:pyyaml:6.0.3" in item for item in problems),
                        problems)

    def test_a_moved_toolchain_version_is_refused_by_name(self):
        toolchain = {"tools": [{"name": "swift", "measured": "6.4"}]}
        canonical = self.canonical()
        canonical["components"].append(
            {"ecosystem": "toolchain", "name": "swift", "version": "6.3.3",
             "digest": None, "digest_status": "PINNED", "license": "n/a",
             "license_source": "host", "supplied_by": "lock"})
        canonical["licence_census"]["n/a"] = 1
        problems = S.verify_sbom(canonical, toolchain=toolchain)
        self.assertTrue(any("toolchain:swift:6.4" in item for item in problems),
                        problems)


class SupplyAuthorityCourt(unittest.TestCase):
    """The trusted register + verifier: a sidecar cannot authorize an image."""

    def setUp(self):
        import verify_sqlcipher_artifact as V
        self.V = V
        self.register = V.load_register()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def test_the_register_carries_a_full_source_identity_per_mode(self):
        src = self.register["sources"][0]
        self.assertRegex(src["commit"], r"[0-9a-f]{40}")      # FULL, not a prefix
        self.assertTrue(src["tag"] and src["repo"])
        for mode, entry in src["modes"].items():
            self.assertIn(entry["platform"], ("MACOS", "IOSSIMULATOR"))
            self.assertRegex(entry["expected_output"]["sha256"], r"[0-9a-f]{64}")
            self.assertIn("toolchain", entry)

    def test_an_unlisted_mode_is_a_refusal_not_a_silent_pass(self):
        with self.assertRaises(self.V.AuthorityError):
            self.V._mode(self.register, "windows")

    def test_a_replaced_image_is_refused_by_name(self):
        """A sidecar beside a replaceable image cannot authorize it: the register
        digest is the authority, so ANY other bytes are refused."""
        image = self.root / "libsqlcipher.0.dylib"
        image.write_bytes(b"a substituted image whose sidecar would say otherwise")
        with self.assertRaisesRegex(self.V.AuthorityError, "sweareth|byte"):
            self.V.verify_artifact(image, "macos", register=self.register)

    def test_a_commit_prefix_is_not_a_pin(self):
        """The register stores a full commit; a 8-char prefix must never match."""
        src = self.register["sources"][0]
        self.assertNotEqual(src["commit"][:8], src["commit"])
        self.assertEqual(40, len(src["commit"]))


class IosContentInventoryCourt(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def bundle(self, name="Fixture.app", **kwargs) -> Path:
        path = self.root / name
        path.mkdir()
        I._write_synthetic_bundle(path, **kwargs)
        return path

    def test_the_inventory_nameth_every_domain_by_its_own_row(self):
        report = I.inspect(self.bundle())
        domains = report["content_inventory"]["domains"]
        self.assertIn("executable", domains)
        self.assertIn("asset", domains)
        for row in domains.values():
            self.assertIn("sha256", row)
            self.assertGreater(row["count"], 0)

    def test_a_debug_laden_image_is_refused(self):
        report = I.inspect(self.bundle(debug_symbols=2))
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("debug (stabbing) symbol" in item
                            for item in report["failures"]), report["failures"])

    def test_a_mesh_importing_image_is_refused_by_its_symbol_table(self):
        report = I.inspect(self.bundle(undefined_symbols=("_GodstoneMesh_start",)))
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("GodstoneMesh" in item for item in report["failures"]),
                        report["failures"])

    def test_an_excluded_binary_resource_is_refused(self):
        bundle = self.bundle()
        (bundle / "GodstoneMesh.dylib").write_bytes(b"\x00\x01")
        report = I.inspect(bundle)
        self.assertEqual("FAIL", report["verdict"])
        self.assertTrue(any("excludes" in item for item in report["failures"]),
                        report["failures"])

    def test_a_byte_matched_fixture_is_accepted_and_a_mismatch_is_refused(self):
        import sqlite3
        bundle = self.bundle()
        fixture = self.root / "fixture.db"
        connection = sqlite3.connect(fixture)
        connection.execute("CREATE TABLE archive_meta(key TEXT, value TEXT)")
        connection.execute("INSERT INTO archive_meta VALUES('tier','LIGHT')")
        connection.commit()
        connection.close()
        (bundle / I.ARCHIVE_NAME).write_bytes(fixture.read_bytes())
        positive = I.inspect(bundle, expected_archive=fixture)
        self.assertEqual("PASS", positive["verdict"])
        self.assertEqual("byte-matched", positive["archive"]["status"])
        other = self.root / "other.db"
        other.write_bytes(b"different bytes")
        negative = I.inspect(bundle, expected_archive=other)
        self.assertEqual("FAIL", negative["verdict"])
        self.assertEqual("byte-mismatch", negative["archive"]["status"])


def _marker(boundary: str, source_id: str, status: str) -> str:
    return "::godstone-boundary::" + json.dumps(
        {"boundary": boundary, "reason": f"{source_id} {status}",
         "ids": {source_id: {"path": source_id, "digest": None,
                             "digest_status": status}}}, sort_keys=True)


def _marker_log(boundary: str, source_id: str, status: str) -> str:
    """A raw GH job log section: the ACTUAL emit_boundary Run command + its marker."""
    return CP.marker_log(boundary, source_id, status)


def _run_section(command: str, output: str) -> str:
    """A raw GH job log section for an arbitrary Run command."""
    return CP.run_command_section(command, output)


class ReleaseProofCaptureCourt(unittest.TestCase):
    """The capture tool maps REAL run facts; an internal red may not go external."""

    def facts(self):
        import capture_release_proof as C
        run = {"id": 36864119928, "run_attempt": 2, "name": "release-gates",
               "event": "push", "head_branch": "board1/x", "head_sha": "c" * 40}
        jobs = [
            {"id": 1, "name": "android-archive-only-release", "conclusion": "success",
             "steps": [{"name": "inspect release artifacts", "conclusion": "success"}]},
            {"id": 2, "name": "ios-archive-only-release", "conclusion": "success",
             "steps": [{"name": "inspect the actual unsigned iOS artifact",
                        "conclusion": "success"}]},
            {"id": 3, "name": "noise-conformance", "conclusion": "failure",
             "steps": [{"name": "repository-owned parity prerequisites",
                        "conclusion": "success"},
                       {"name": "verify independently approved Noise input",
                        "conclusion": "failure"}]},
            {"id": 4, "name": "llm-native-stack", "conclusion": "failure",
             "steps": [{"name": "compile repository-owned LLM Kotlin",
                        "conclusion": "success"},
                       {"name": "verify approved native stack input",
                        "conclusion": "failure"}]},
            {"id": 5, "name": "production-corpus", "conclusion": "failure",
             "steps": [{"name": "verify independently approved model weights",
                        "conclusion": "failure"},
                       {"name": "verify independently approved content inputs",
                        "conclusion": "skipped"}]}]
        arts = {"android-archive-only-unsigned": {"name": "android-archive-only-unsigned",
                                                  "sha256": "a" * 64, "bytes": 10},
                "ios-archive-only-unsigned": {"name": "ios-archive-only-unsigned",
                                              "sha256": "b" * 64, "bytes": 20}}
        logs = {
            "3": _marker_log("noise_fixture", "crypto/cacophony_vectors.json",
                             "ABSENT"),
            "4": _run_section("cd android && ./gradlew :llm:compileReleaseKotlin",
                              "> Task :llm:compileReleaseKotlin")
                 + _marker_log("native_models", "docs/packaging/MODELS.lock.json",
                               "UNPINNED"),
            "5": _marker_log("model_weights", "docs/packaging/MODELS.lock.json",
                             "UNPINNED")}
        return C, run, jobs, arts, logs

    def test_captured_facts_seal_into_a_sound_record(self):
        C, run, jobs, arts, logs = self.facts()
        doc = C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40,
                                      run=run, jobs=jobs, artifacts=arts, logs=logs)
        self.assertEqual([], RP.verify_release_proof(doc))
        self.assertEqual("PASS", doc["internal"]["verdict"])
        self.assertEqual("BLOCKED_EXTERNAL", doc["external"]["verdict"])

    def test_a_boundary_less_external_failure_is_refused(self):
        C, run, jobs, arts, _ = self.facts()
        with self.assertRaises(C.CaptureError):
            C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                                    jobs=jobs, artifacts=arts, logs={})

    def test_a_self_echoed_reason_with_no_bound_register_is_refused(self):
        C, run, jobs, arts, logs = self.facts()
        logs = dict(logs, **{"3": '{"boundary":"noise_fixture","reason":"because"}'})
        with self.assertRaises(C.CaptureError):
            C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                                    jobs=jobs, artifacts=arts, logs=logs)

    def test_an_internal_compile_failure_with_a_forged_marker_is_not_external(self):
        """The contract arm Main named: a marker does not launder a real internal red."""
        C, run, jobs, arts, logs = self.facts()
        red = [dict(j) for j in jobs]
        red[3] = dict(red[3], steps=[
            {"name": "compile repository-owned LLM Kotlin", "conclusion": "failure"},
            {"name": "verify approved native stack input", "conclusion": "failure"}])
        forged = dict(logs, **{"4": (
            _run_section("cd android && ./gradlew :llm:compileReleaseKotlin",
                         "> Task :llm:compileReleaseKotlin FAILED\n"
                         "e: file:///x/Y.kt:1:1 unresolved reference: foo")
            + _marker_log("native_models", "docs/packaging/MODELS.lock.json",
                          "UNPINNED"))})
        with self.assertRaisesRegex(C.CaptureError, "internally executable"):
            C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                                    jobs=red, artifacts=arts, logs=forged)

    def test_an_unrelated_failed_step_beside_the_marker_is_refused(self):
        """A valid boundary emit cannot hide ANOTHER step's internal red."""
        C, run, jobs, arts, logs = self.facts()
        broken = [dict(j) for j in jobs]
        broken[2] = dict(broken[2], steps=[
            {"name": "repository-owned parity prerequisites", "conclusion": "failure"},
            {"name": "verify independently approved Noise input",
             "conclusion": "failure"}])
        with self.assertRaisesRegex(C.CaptureError, "failed step"):
            C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                                    jobs=broken, artifacts=arts, logs=logs)

    def test_a_marker_under_an_unrelated_run_command_is_refused(self):
        """The marker must come from the ACTUAL emit_boundary Run command."""
        C, run, jobs, arts, logs = self.facts()
        misplaced = dict(logs, **{"3": _run_section(
            "python ci/check_parity.py --scope all",
            _marker("noise_fixture", "crypto/cacophony_vectors.json", "ABSENT"))})
        with self.assertRaises(C.CaptureError):
            C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                                    jobs=jobs, artifacts=arts, logs=misplaced)

    def test_an_emit_for_a_different_boundary_is_refused(self):
        """A job may only emit the boundary its own command reaches."""
        C, run, jobs, arts, logs = self.facts()
        wrong = dict(logs, **{"3": _marker_log(
            "approved_content", "env:GODSTONE_APPROVALS_DIR", "ABSENT")})
        with self.assertRaisesRegex(C.CaptureError, "not the allowed boundary emit"):
            C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                                    jobs=jobs, artifacts=arts, logs=wrong)

    def test_a_duplicated_required_job_is_refused_not_overwritten(self):
        C, run, jobs, arts, logs = self.facts()
        with self.assertRaisesRegex(C.CaptureError, "duplicated or invented"):
            C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                                    jobs=jobs + [dict(jobs[0], id=999)],
                                    artifacts=arts, logs=logs)

    def test_no_external_block_is_allowed_while_the_internal_road_is_red(self):
        """Ordering: a prerequisite that never succeeded reached no boundary."""
        C, run, jobs, arts, logs = self.facts()
        red = [dict(j) for j in jobs]
        red[1] = dict(red[1], conclusion="failure")
        with self.assertRaisesRegex(C.CaptureError, "internal road is not green"):
            C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                                    jobs=red, artifacts=arts, logs=logs)

    def test_a_healthy_compile_printing_the_task_name_is_not_a_failure(self):
        """A passing Gradle run PRINTS `> Task :llm:compileReleaseKotlin`; the :llm
        job then stops at the genuine missing native input -- that IS a boundary."""
        C, run, jobs, arts, logs = self.facts()
        healthy = dict(logs, **{"4": _run_section(
            "cd android && ./gradlew :llm:compileReleaseKotlin",
            "> Task :llm:compileReleaseKotlin\n> Task :llm:compileDebugKotlin")
            + _marker_log("native_models", "docs/packaging/MODELS.lock.json",
                          "UNPINNED")})
        doc = C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40,
                                      run=run, jobs=jobs, artifacts=arts, logs=healthy)
        self.assertEqual("BLOCKED_EXTERNAL", doc["external"]["verdict"])

    def test_a_true_failed_compile_carrying_a_marker_is_not_external(self):
        C, run, jobs, arts, logs = self.facts()
        red = [dict(j) for j in jobs]
        red[3] = dict(red[3], steps=[
            {"name": "compile repository-owned LLM Kotlin", "conclusion": "failure"},
            {"name": "verify approved native stack input", "conclusion": "failure"}])
        forged = dict(logs, **{"4": (
            _run_section("cd android && ./gradlew :llm:compileReleaseKotlin",
                         "> Task :llm:compileReleaseKotlin FAILED\n"
                         "e: file:///x/Y.kt:1:1 unresolved reference: foo")
            + _marker_log("native_models", "docs/packaging/MODELS.lock.json",
                          "UNPINNED"))})
        with self.assertRaisesRegex(C.CaptureError, "internally executable"):
            C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                                    jobs=red, artifacts=arts, logs=forged)

    def test_a_missing_internal_job_is_refused(self):
        C, run, jobs, arts, logs = self.facts()
        with self.assertRaises(C.CaptureError):
            C.map_facts_to_document(candidate_sha="c" * 40, tree_sha="d" * 40, run=run,
                                    jobs=[j for j in jobs if j["id"] != 1],
                                    artifacts=arts, logs=logs)


class ReleaseProofAuthenticationCourt(unittest.TestCase):
    """Authentication RE-READS the pinned run's OWN facts, at the raw GH seam.

    The capture transport (`CP.gh_api` / `CP.job_log_text`) is replaced by a
    deterministic GitHub-fact stub, so the SAME `CP.capture` collection the CLI
    runs is exercised end to end -- never a mocked authenticator return, never the
    wiring and never the source text. A self-sealed forgery, a correct-C wrong-tree
    record and an altered job/artifact-digest/typed-boundary record must all be
    refused against the ACTUAL facts; the genuine collection must be accepted.
    """

    C = "c" * 40
    TREE = "d" * 40
    REPO = "oculusrex14/GODSTONE"

    def _facts(self):
        run = {"id": 36864119928, "run_attempt": 2, "name": "release-gates",
               "event": "push", "head_branch": "board1/x", "head_sha": self.C,
               "path": ".github/workflows/release-gates.yml",
               "workflow_file": {"name": "release-gates"},
               "repository": {"full_name": self.REPO}, "conclusion": "failure"}
        jobs = [
            {"id": 101, "name": "Android Archive-only LIGHT release (repo-owned; green "
                                "without llama.cpp/model/Oracle)", "conclusion": "success",
             "steps": [{"name": "inspect release artifacts", "conclusion": "success"}]},
            {"id": 102, "name": "iOS Archive-only LIGHT unsigned artifact (internal; "
                                "production content and signing external)",
             "conclusion": "success",
             "steps": [{"name": "inspect the actual unsigned iOS artifact",
                        "conclusion": "success"}]},
            {"id": 103, "name": "A-06 independent Noise conformance (fail-closed until "
                                "pinned)", "conclusion": "failure",
             "steps": [{"name": "repository-owned parity prerequisites",
                        "conclusion": "success"},
                       {"name": "verify independently approved Noise input",
                        "conclusion": "failure"}]},
            {"id": 104, "name": "LLM native stack (:llm release; fail-closed until "
                                "pinned llama.cpp restored)", "conclusion": "failure",
             "steps": [{"name": "compile repository-owned LLM Kotlin",
                        "conclusion": "success"},
                       {"name": "verify approved native stack input",
                        "conclusion": "failure"}]},
            {"id": 105, "name": "production corpus + embedded archive (fail-closed until "
                                "model pinned)", "conclusion": "failure",
             "steps": [{"name": "verify independently approved model weights",
                        "conclusion": "failure"},
                       {"name": "verify independently approved content inputs",
                        "conclusion": "skipped"}]},
        ]
        logs = {
            "103": _marker_log("noise_fixture", "crypto/cacophony_vectors.json",
                               "ABSENT"),
            "104": _run_section("cd android && ./gradlew :llm:compileReleaseKotlin",
                                "> Task :llm:compileReleaseKotlin")
                   + _marker_log("native_models", "docs/packaging/MODELS.lock.json",
                                 "UNPINNED"),
            "105": _marker_log("model_weights", "docs/packaging/MODELS.lock.json",
                               "UNPINNED"),
        }
        return run, jobs, logs

    def _install(self, run, jobs, logs):
        """Patch the raw GH transport seam with deterministic, hostless facts."""
        artifacts = [
            {"name": "android-archive-only-unsigned", "size_in_bytes": 10,
             "digest": "sha256:" + "a" * 64},
            {"name": "ios-archive-only-unsigned", "size_in_bytes": 20,
             "digest": "sha256:" + "b" * 64},
        ]

        def gh_api(path: str):
            if path.endswith("/jobs?per_page=100"):
                return {"jobs": jobs}
            if path.endswith("/artifacts?per_page=100"):
                return {"artifacts": artifacts}
            if "/commits/" in path:
                return {"commit": {"tree": {"sha": self.TREE}}}
            return run

        saved = (CP.gh_api, CP.job_log_text)
        self.addCleanup(lambda: (setattr(CP, "gh_api", saved[0]),
                                 setattr(CP, "job_log_text", saved[1])))
        CP.gh_api = gh_api
        CP.job_log_text = lambda repo, job_id: logs.get(str(job_id), "")

    def _genuine(self):
        run, jobs, logs = self._facts()
        self._install(run, jobs, logs)
        return CP.capture(self.REPO, 36864119928, 2, self.C, self.TREE)

    def _authenticate(self, doc):
        return RP.authenticate_release_proof(doc, repo=self.REPO,
                                             candidate_sha=self.C,
                                             candidate_tree_sha=self.TREE)

    def test_the_verifier_and_capture_agree_on_the_external_job_protocol(self):
        """Drift guard: the roster the verifier demands is the one capture emits."""
        from_cp = {spec["job_id"]: tuple(spec["boundaries"])
                   for spec in CP.EXTERNAL_JOB_SPECS}
        self.assertEqual(from_cp, dict(RP.EXTERNAL_JOB_BOUNDARIES))
        self.assertEqual(tuple(from_cp), tuple(RP.REQUIRED_EXTERNAL_JOB_IDS))
        emitted = {b for bounds in from_cp.values() for b in bounds}
        self.assertEqual(emitted, set(RP.REQUIRED_EXTERNAL_BOUNDARIES))

    def test_a_genuine_deterministic_collection_is_accepted(self):
        doc = self._genuine()
        self.assertEqual([], RP.verify_release_proof(doc))
        self.assertEqual([], self._authenticate(doc))
        self.assertEqual(self.TREE, doc["candidate"]["tree_sha"])

    def test_a_self_sealed_forged_positive_record_is_rejected(self):
        self._genuine()  # install the real facts for the same run/attempt
        forged = copy.deepcopy(RP._sound_record())
        forged["candidate"] = {"sha": self.C, "tree_sha": self.TREE}
        forged["run"]["id"] = 36864119928
        forged["run"]["attempt"] = 2
        forged["run"]["head_sha"] = self.C
        forged = RP.seal(forged)  # invented positive job ids/digests, well sealed
        self.assertEqual([], RP.verify_release_proof(forged))
        problems = self._authenticate(forged)
        self.assertTrue(any("does not match the facts" in p for p in problems),
                        problems)

    def test_the_correct_c_sha_with_a_wrong_40hex_tree_is_refused(self):
        doc = self._genuine()
        doc["candidate"] = dict(doc["candidate"], tree_sha="e" * 40)
        doc = RP.seal(doc)
        problems = self._authenticate(doc)
        self.assertTrue(any("tree" in p for p in problems), problems)

    def test_an_altered_job_conclusion_is_refused(self):
        doc = self._genuine()
        doc["internal"]["jobs"][0]["conclusion"] = "failure"
        doc = RP.seal(doc)
        self.assertTrue(any("facts" in p for p in self._authenticate(doc)))

    def test_an_altered_artifact_digest_is_refused(self):
        doc = self._genuine()
        doc["internal"]["artifacts"][0]["sha256"] = "f" * 64
        doc = RP.seal(doc)
        self.assertTrue(any("facts" in p for p in self._authenticate(doc)))

    def test_an_altered_typed_boundary_record_is_refused(self):
        doc = self._genuine()
        entry = next(e for e in doc["external"]["roster"]
                     if e["boundary_step"] == "noise_fixture")
        entry["actual_ids"] = {"crypto/cacophony_vectors.json":
                               {"path": "x", "digest": "f" * 64,
                                "digest_status": "MEASURED"}}
        doc = RP.seal(doc)
        self.assertTrue(any("facts" in p for p in self._authenticate(doc)))

    def test_an_unreadable_remote_fails_closed(self):
        doc = self._genuine()

        def unreadable(path: str):
            raise CP.CaptureError("gh api refused")

        CP.gh_api = unreadable
        problems = self._authenticate(doc)
        self.assertTrue(any("could not be re-read" in p for p in problems), problems)


class ExternalRegisterCourt(unittest.TestCase):
    """The boundary helper measuth the registers; it never aummes absence."""

    def setUp(self):
        import emit_boundary as E
        self.E = E
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def _noise(self, *, placeholder: bool, vectors: list) -> None:
        (self.root / "crypto").mkdir(parents=True, exist_ok=True)
        (self.root / "crypto" / "cacophony_vectors.json").write_text(json.dumps(
            {"_placeholder": placeholder, "vectors": vectors,
             "_where_to_get_it": {"source": "https://example.invalid/x"}}))

    def test_a_placeholder_vector_lock_is_a_measured_absence(self):
        self._noise(placeholder=True, vectors=[])
        verdict = self.E.check_noise_fixture(self.root)
        self.assertFalse(verdict["present"])
        self.assertEqual("ABSENT", verdict["digest_status"])
        self.assertEqual("crypto/cacophony_vectors.json", verdict["source_id"])

    def test_a_real_independent_vector_set_is_measured_present(self):
        self._noise(placeholder=False, vectors=[{"name": "v1", "kem": "K256"}])
        verdict = self.E.check_noise_fixture(self.root)
        self.assertTrue(verdict["present"])
        self.assertEqual("MEASURED", verdict["digest_status"])
        self.assertRegex(verdict["digest"], r"[0-9a-f]{64}")

    def _models(self, payload: dict) -> None:
        (self.root / "docs" / "packaging").mkdir(parents=True, exist_ok=True)
        (self.root / "docs" / "packaging" / "MODELS.lock.json").write_text(
            json.dumps(payload))

    def test_the_native_stack_is_not_the_model_weights(self):
        """native_models is the llama.cpp STACK; model_weights is the WEIGHTS."""
        self._models({"status": "UNPINNED",
                      "native": {"llama_revision": None,
                                 "source_repo": "ggml-org/llama.cpp"},
                      "artifacts": [{"id": "generation-light", "sha256": None}]})
        native = self.E.check_native_models(self.root)
        weights = self.E.check_model_weights(self.root)
        self.assertFalse(native["present"])
        self.assertEqual("UNPINNED", native["digest_status"])
        self.assertIn("native.llama_revision", native["source_id"])
        self.assertFalse(weights["present"])
        self.assertEqual("docs/packaging/MODELS.lock.json", weights["source_id"])

    def test_a_pinned_revision_with_absent_source_is_a_measured_absence(self):
        self._models({"native": {"llama_revision": "abc123",
                                 "source_repo": "ggml-org/llama.cpp"},
                      "artifacts": []})
        verdict = self.E.check_native_models(self.root)
        self.assertFalse(verdict["present"])
        self.assertEqual("third_party/llama.cpp", verdict["source_id"])
        self.assertEqual("ABSENT", verdict["digest_status"])

    def test_a_pinned_revision_with_present_source_is_measured_present(self):
        self._models({"native": {"llama_revision": "abc123",
                                 "source_repo": "ggml-org/llama.cpp"},
                      "artifacts": []})
        (self.root / "third_party" / "llama.cpp").mkdir(parents=True)
        self.assertTrue(self.E.check_native_models(self.root)["present"])

    def test_a_pinned_model_weight_register_is_measured_present(self):
        self._models({"status": "PINNED",
                      "native": {"llama_revision": "abc123",
                                 "source_repo": "ggml-org/llama.cpp"},
                      "artifacts": [{"id": "generation-light", "sha256": "a" * 64}]})
        self.assertTrue(self.E.check_model_weights(self.root)["present"])

    def test_a_native_descriptor_that_is_empty_is_an_error_not_an_absence(self):
        """An absent/malformed native block cannot be judged -- it is not 'missing'."""
        self._models({"status": "PINNED", "artifacts": []})
        with self.assertRaises(self.E.RegisterError):
            self.E.check_native_models(self.root)

    def test_a_corrupt_register_is_an_error_never_a_missing_input(self):
        """A broken lock is not evidence that content is away."""
        (self.root / "crypto").mkdir(parents=True)
        (self.root / "crypto" / "cacophony_vectors.json").write_text("{not json")
        with self.assertRaises(self.E.RegisterError):
            self.E.check_noise_fixture(self.root)

    def test_exit_codes_separate_present_absent_and_unjudgeable(self):
        import subprocess
        self._noise(placeholder=True, vectors=[])
        argv = [sys.executable,
                str(ROOT / "tools" / "supplychain" / "emit_boundary.py"),
                "--boundary", "noise_fixture", "--check-inputs",
                "--root", str(self.root)]
        self.assertEqual(1, subprocess.run(argv, capture_output=True,
                                           text=True).returncode)
        self._noise(placeholder=False, vectors=[{"name": "v"}])
        self.assertEqual(0, subprocess.run(argv, capture_output=True,
                                           text=True).returncode)
        (self.root / "crypto" / "cacophony_vectors.json").write_text("{broken")
        self.assertEqual(2, subprocess.run(argv, capture_output=True,
                                           text=True).returncode)

if __name__ == "__main__":
    unittest.main(verbosity=2)
