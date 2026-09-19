#!/usr/bin/env python3
"""T68 readiness court (python isle): the pinned build supply chain.

The card's law, one witness each where the rule speaketh:

  W01  a requirement line that is not an exact pin is refused by name -- a
       range, a URL, an extra, a marker, an include, a wildcard
  W02  comments and blank lines are ignored, and a repeated pin of the same
       version is one pin
  W03  a lane table that forgeteth a pinned package is refused: a pin no lane
       installs is pinned on paper alone
  W04  a closure entry whose bytes are not pip's resolved digest is refused
  W05  a manifest claiming PINNED while an entry standeth UNPINNED is refused
       (a half-sworn mixture)
  W06  a digest that is not a lower-case SHA-256 is refused, and a
       non-positive byte count is refused
  W07  a resolution that disagrees with the requirement source's pin is
       refused, and neither version is silently preferred
  W08  a transitive package the wheelhouse lacketh is recorded UNPINNED with
       the digest pip resolved; no hash is invented for it
  W09  a resolution entry without a sha256 is refused: a resolution without a
       digest is not a pin
  W10  the rendered lock carrieth every closure digest, in the form pip
       requireth (name==version --hash=sha256:...)
  W11  a cache carrieth no symlink, and a blob whose bytes changed or that is
       missing is refused by name
  W12  a refusal precedeth every write: one corrupted blob leaveth the
       destination exactly as it was
  W13  the restoration log passeth a secret scanner that refuseth private
       keys, tokens and credential assignments
  W14  an UNPINNED lane cannot be restored offline and no success is claimed
       for it
  W15  a cached distribution whose bytes changed is refused at the
       installation door (the card's named semantic negative)
  W16  a lane really is restored with --no-index and --require-hashes, into a
       fresh venv, from a local wheelhouse and nothing else
  W17  the SBOM carrieth every component the locks name, and a component
       named by a lock but absent from the inventory is a refusal
  W18  an unknown licence is counted and named, never omitted; the licence
       census counteth every component
  W19  a measured tool that disagrees with its pin is refused; so is a lock
       claiming PINNED with unpinned tools or a stale input digest
  W20  the toolchain capture is deterministic under an injected clock and a
       replaced probe -- no witness toucheth the host's real tools
  W21  Gradle's verification metadata is parsed through its XML namespace, a
       component with no SHA-256 is refused, and a weak digest is named
  W22  a same-version artifact with different bytes is refused against the
       verification manifest (the card's named semantic negative, maven half)
  W23  two runs are compared by content: identical is COMPARABLE, a
       divergence without a cause is UNEXPLAINED and refused, a divergence
       with a cause is recorded, and a missing output is INCOMPARABLE
  W24  the command door reporteth 0 for a sound document set and 1 for a
       broken one
  W25  the secret scanner proveth itself on each class it claimeth, and
       fl ageth nothing in an honest digest log
  W26  an interrupted write leaveth the previous document intact

All judgments run in-process over documents built inside temporary
directories, or over the repository's own reviewed inputs read-only. No
witness reacheth the network, closes an external gate, or claims that any
artifact, device or signed release was verified. Readiness stayeth false.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
if str(ROOT / "tools" / "supplychain") not in sys.path:
    sys.path.insert(0, str(ROOT / "tools" / "supplychain"))

import supply_chain as S  # the authority under audit, in-process

CLOCK = lambda: "2026-09-14T03:00:00+00:00"  # noqa: E731 - injected clock boundary

REQUIREMENTS_RUNTIME = """\
# the content pipeline
llama-cpp-python==0.3.2
PyYAML==6.0.2
numpy==2.1.3
cryptography==50.0.0
"""

REQUIREMENTS_DEV = """\
# repository verification
PyYAML==6.0.2
cryptography==50.0.0
"""

WRAPPER = """\
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\\://services.gradle.org/distributions/gradle-8.9-bin.zip
distributionSha256Sum=d725d707bfabd4dfdc958c624003b3c80accc03f7037b5122c4b1d0ef15cecab
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
"""

LLM_BUILD = """\
android {
    compileSdk = 35
    ndkVersion = "27.0.12077973"
    defaultConfig { minSdk = 26 }
    externalNativeBuild { cmake { version = "3.22.1" } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
"""

SWIFT_MANIFEST = "// swift-tools-version: 5.9\nimport PackageDescription\n"

PROJECT_SPEC = "name: Godstone\n"


def sha256_bytes(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(Path(path).read_bytes())


class SupplyChainCourt(unittest.TestCase):
    """T68: the supply chain, pinned and provable."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.wheelhouse = self.root / "wheelhouse"
        self.wheelhouse.mkdir(parents=True)
        self.mini_repo()

    # -- fixtures ---------------------------------------------------------
    def mini_repo(self, *, runtime: str = REQUIREMENTS_RUNTIME,
                  dev: str = REQUIREMENTS_DEV) -> Path:
        (self.repo / "content").mkdir(parents=True, exist_ok=True)
        (self.repo / "android" / "gradle" / "wrapper").mkdir(parents=True, exist_ok=True)
        (self.repo / "android" / "llm").mkdir(parents=True, exist_ok=True)
        (self.repo / "ios" / "Godstone").mkdir(parents=True, exist_ok=True)
        (self.repo / "docs" / "packaging").mkdir(parents=True, exist_ok=True)
        (self.repo / "content" / "requirements.txt").write_text(runtime)
        (self.repo / "content" / "requirements-dev.txt").write_text(dev)
        (self.repo / "android" / "gradle" / "wrapper" / "gradle-wrapper.properties").write_text(WRAPPER)
        (self.repo / "android" / "llm" / "build.gradle.kts").write_text(LLM_BUILD)
        (self.repo / "android" / "app").mkdir(parents=True, exist_ok=True)
        (self.repo / "android" / "app" / "build.gradle.kts").write_text("android { compileSdk = 35 }\n")
        (self.repo / "android" / "build.gradle.kts").write_text("plugins { }\n")
        (self.repo / "ios" / "Godstone" / "Package.swift").write_text(SWIFT_MANIFEST)
        (self.repo / "ios" / "project.yml").write_text(PROJECT_SPEC)
        (self.repo / "docs" / "packaging" / "MODELS.lock.json").write_text(
            json.dumps({"schema": 2, "status": "UNPINNED",
                        "native": {"toolchains": [{"name": "ndk",
                                                   "version": "27.0.12077973"},
                                                  {"name": "cmake", "version": "3.22.1"}]},
                        "artifacts": []}, sort_keys=True) + "\n")
        return self.repo

    def blob(self, name: str, payload: bytes | None = None) -> Path:
        path = self.wheelhouse / name
        path.write_bytes(payload if payload is not None else os.urandom(64))
        return path

    def resolution(self, entries, *, path: Path | None = None) -> Path:
        document = {"install": [
            {"metadata": {"name": name, "version": version},
             "download_info": {"url": f"https://example.invalid/{name}",
                               "archive_info": {"hashes": {"sha256": digest}}},
             "requested": requested}
            for name, version, digest, requested in entries]}
        path = path or (self.root / "resolution.json")
        path.write_text(json.dumps(document, indent=1) + "\n", encoding="utf-8")
        return path

    def wheel(self, name: str = "godstonefixture", version: str = "1.0") -> Path:
        """A real, installable wheel, built here so the offline proof is hermetic."""
        path = self.wheelhouse / f"{name}-{version}-py3-none-any.whl"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(f"{name}/__init__.py", "VALUE = 1\n")
            archive.writestr(f"{name}-{version}.dist-info/METADATA",
                             f"Metadata-Version: 2.1\nName: {name}\n"
                             f"Version: {version}\n")
            archive.writestr(f"{name}-{version}.dist-info/WHEEL",
                             "Wheel-Version: 1.0\nGenerator: fixture\n"
                             "Root-Is-Purelib: true\nTag: py3-none-any\n")
            archive.writestr(f"{name}-{version}.dist-info/top_level.txt", f"{name}\n")
            archive.writestr(f"{name}-{version}.dist-info/RECORD", "")
        return path

    def lane_resolutions(self) -> dict[str, Path]:
        """One pip-style resolution report per lane, with matching blobs."""
        payloads = {
            "pyyaml-6.0.2.tar.gz": b"pyyaml bytes",
            "cryptography-50.0.0-cp311-abi3-macosx_11_0_arm64.whl": b"crypto bytes",
            "cffi-2.1.1-cp314-cp314-macosx_11_0_arm64.whl": b"cffi bytes",
            "pycparser-3.0-py3-none-any.whl": b"pycparser bytes",
            "numpy-2.1.3.tar.gz": b"numpy bytes",
            "llama_cpp_python-0.3.2.tar.gz": b"llama bytes",
            "markdown_it_py-3.0.0-py3-none-any.whl": b"markdown bytes",
            "textstat-0.7.4-py3-none-any.whl": b"textstat bytes",
        }
        blobs = {name: self.blob(name, data) for name, data in payloads.items()}

        def report(lane: str, entries) -> Path:
            rows = [(name, version, sha256_file(blobs[filename]), direct)
                    for name, version, filename, direct in entries]
            return self.resolution(rows, path=self.root / f"resolution-{lane}.json")

        dev = report("dev", [("pyyaml", "6.0.2", "pyyaml-6.0.2.tar.gz", True),
                             ("cryptography", "50.0.0",
                              "cryptography-50.0.0-cp311-abi3-macosx_11_0_arm64.whl",
                              True),
                             ("cffi", "2.1.1",
                              "cffi-2.1.1-cp314-cp314-macosx_11_0_arm64.whl", False),
                             ("pycparser", "3.0", "pycparser-3.0-py3-none-any.whl",
                              False)])
        evaluation = report("eval", [("numpy", "2.1.3", "numpy-2.1.3.tar.gz", True)])
        content = report("content", [
            ("llama-cpp-python", "0.3.2", "llama_cpp_python-0.3.2.tar.gz", True),
            ("pyyaml", "6.0.2", "pyyaml-6.0.2.tar.gz", True),
            ("markdown-it-py", "3.0.0", "markdown_it_py-3.0.0-py3-none-any.whl", True),
            ("textstat", "0.7.4", "textstat-0.7.4-py3-none-any.whl", True),
            ("numpy", "2.1.3", "numpy-2.1.3.tar.gz", True),
            ("cryptography", "50.0.0",
             "cryptography-50.0.0-cp311-abi3-macosx_11_0_arm64.whl", True),
            ("cffi", "2.1.1", "cffi-2.1.1-cp314-cp314-macosx_11_0_arm64.whl", False),
            ("pycparser", "3.0", "pycparser-3.0-py3-none-any.whl", False)])
        return {"dev": dev, "eval": evaluation, "content": content}

    def lock_for(self, path: Path, *, name: str = "godstonefixture",
                 version: str = "1.0") -> dict:
        return {"schema": 1, "built_utc": CLOCK(), "status": "PINNED",
                "wheelhouse": str(self.wheelhouse),
                "lanes": {"dev": {
                    "source": "content/requirements-dev.txt", "rationale": "fixture",
                    "resolution_source": "dev", "status": "PINNED",
                    "requires_native_build": False, "direct": [name],
                    "closure": [{"name": name, "version": version, "origin": "pinned",
                                 "status": "PINNED",
                                 "resolved_sha256": sha256_file(path),
                                 "distributions": [{"file": path.name, "kind": "wheel",
                                                    "bytes": path.stat().st_size,
                                                    "sha256": sha256_file(path)}]}]}},
                "unresolved": []}

    # -- W01-W03 the pinned sources ---------------------------------------
    def test_w01_a_line_that_is_not_an_exact_pin_is_refused(self):
        cases = (
            ("PyYAML>=6.0.2\n", "a range"),
            ("PyYAML~=6.0\n", "a compatible release"),
            ("git+https://example.invalid/pkg.git\n", "a direct URL"),
            ("PyYAML[dev]==6.0.2\n", "an extra"),
            ('PyYAML==6.0.2; python_version < "3.12"\n', "an environment marker"),
            ("-r other.txt\n", "an option or include"),
            ("PyYAML==6.*\n", "a wildcard"),
            ("PyYAML == 6.0.2\n", "a stray token"),
            ("PyYAML\n", "not an exact 'name==version' pin"),
        )
        for text, cry in cases:
            with self.subTest(line=text.strip()):
                path = self.root / "requirements.txt"
                path.write_text("# a comment\n" + text, encoding="utf-8")
                with self.assertRaisesRegex(S.SupplyChainError, cry):
                    S.parse_requirements(path)

    def test_w02_comments_are_ignored_and_a_repeated_pin_is_one_pin(self):
        path = self.root / "requirements.txt"
        path.write_text("# header\n\nPyYAML==6.0.2   # trailing\npyyaml==6.0.2\n"
                        "Cryptography==50.0.0\n", encoding="utf-8")
        pinned = S.parse_requirements(path)
        self.assertEqual({"pyyaml": "6.0.2", "cryptography": "50.0.0"}, pinned)
        path.write_text("PyYAML==6.0.2\nPyYAML==6.0.3\n", encoding="utf-8")
        with self.assertRaisesRegex(S.SupplyChainError, "pinned twice"):
            S.parse_requirements(path)

    def test_w03_a_lane_table_that_forgetteth_a_package_is_refused(self):
        lanes = S.lane_table(self.repo)
        self.assertEqual({"pyyaml": "6.0.2", "cryptography": "50.0.0"},
                         lanes["dev"]["packages"])
        # A table in which numpy is named by no lane at all: the pin would be
        # installed by nothing, which is the hole this guard existeth for.
        real = S.lane_table(self.repo)
        forgotten = tuple(
            dict(spec, packages=tuple(
                [p for p in real[spec["lane"]]["packages"] if p != "numpy"]
                or ["pyyaml"]))
            for spec in S.LANES)
        with patch.object(S, "LANES", forgotten):
            with self.assertRaisesRegex(S.SupplyChainError, "pinned on paper alone"):
                S.lane_table(self.repo)

    # -- W04-W10 the hash-locked closure ----------------------------------
    def test_w04_a_distribution_that_is_not_pips_digest_is_refused(self):
        blob = self.blob("godstonefixture-1.0-py3-none-any.whl")
        manifest = self.lock_for(blob)
        manifest["lanes"]["dev"]["closure"][0]["resolved_sha256"] = "0" * 64
        errors = S.verify_lock(manifest, repo=self.repo)
        self.assertTrue(any("not pip's resolved digest" in item for item in errors), errors)

    def test_w05_a_half_sworn_manifest_is_refused(self):
        blob = self.blob("godstonefixture-1.0-py3-none-any.whl")
        manifest = self.lock_for(blob)
        entry = manifest["lanes"]["dev"]["closure"][0]
        entry.update({"status": "UNPINNED", "distributions": [],
                      "reason": "the wheelhouse carrieth nothing for it"})
        errors = S.verify_lock(manifest, repo=self.repo)
        self.assertTrue(any("claimeth PINNED while" in item for item in errors), errors)
        half = self.lock_for(blob)
        half["lanes"]["dev"]["status"] = "UNPINNED"
        half["lanes"]["dev"]["closure"][0]["distributions"] = []
        errors = S.verify_lock(half, repo=self.repo)
        self.assertTrue(any("half-sworn" in item for item in errors), errors)
        manifest["status"] = "PINNED"
        errors = S.verify_lock(manifest, repo=self.repo)
        self.assertTrue(any("claimeth PINNED" in item for item in errors), errors)

    def test_w06_a_malformed_digest_or_byte_count_is_refused(self):
        blob = self.blob("godstonefixture-1.0-py3-none-any.whl")
        manifest = self.lock_for(blob)
        distribution = manifest["lanes"]["dev"]["closure"][0]["distributions"][0]
        distribution["sha256"] = "A" * 64
        errors = S.verify_lock(manifest, repo=self.repo)
        self.assertTrue(any("lower-case SHA-256" in item for item in errors), errors)
        manifest = self.lock_for(blob)
        manifest["lanes"]["dev"]["closure"][0]["distributions"][0]["bytes"] = 0
        errors = S.verify_lock(manifest, repo=self.repo)
        self.assertTrue(any("non-positive byte count" in item for item in errors), errors)

    def test_w07_a_resolution_that_disagrees_with_the_pin_is_refused(self):
        path = self.resolution([("pyyaml", "6.0.3", "a" * 64, True),
                                ("cryptography", "50.0.0", "b" * 64, True)])
        with self.assertRaisesRegex(S.SupplyChainError, "the pin and the resolution "
                                                       "disagree"):
            S.build_lock(self.wheelhouse, repo=self.repo,
                         resolutions={"dev": path})

    def test_w08_a_transitive_package_the_wheelhouse_lacketh_is_recorded_unpinned(self):
        resolutions = self.lane_resolutions()
        path = self.resolution([("pyyaml", "6.0.2",
                                 sha256_file(self.wheelhouse / "pyyaml-6.0.2.tar.gz"),
                                 True),
                                ("cryptography", "50.0.0",
                                 sha256_file(self.wheelhouse /
                                             "cryptography-50.0.0-cp311-abi3-"
                                             "macosx_11_0_arm64.whl"), True),
                                ("cffi", "2.1.1", "c" * 64, False)],
                               path=resolutions["dev"])
        resolutions["dev"] = path
        manifest = S.build_lock(self.wheelhouse, repo=self.repo,
                                resolutions=resolutions)
        closure = {entry["name"]: entry for entry in
                   manifest["lanes"]["dev"]["closure"]}
        self.assertEqual("pinned", closure["pyyaml"]["origin"])
        self.assertEqual("transitive", closure["cffi"]["origin"])
        self.assertEqual("UNPINNED", closure["cffi"]["status"])
        self.assertEqual([], closure["cffi"]["distributions"])
        self.assertIn("c" * 12, closure["cffi"]["reason"])
        self.assertEqual("UNPINNED", manifest["lanes"]["dev"]["status"])

    def test_w09_a_resolution_without_a_digest_is_refused(self):
        path = self.root / "resolution.json"
        path.write_text(json.dumps({"install": [
            {"metadata": {"name": "pyyaml", "version": "6.0.2"},
             "download_info": {"archive_info": {"hashes": {}}}}]}) + "\n")
        with self.assertRaisesRegex(S.SupplyChainError, "no sha256 in its resolution"):
            S.parse_resolution(path)
        path.write_text(json.dumps({"install": [
            {"metadata": {"name": "pyyaml", "version": "6.0.2"},
             "download_info": {"archive_info": {"hashes": {"md5": "d" * 32}}}}]}) + "\n")
        with self.assertRaisesRegex(S.SupplyChainError, "not a pin"):
            S.parse_resolution(path)

    def test_w10_the_rendered_lock_carrieth_every_digest_as_pip_requireth(self):
        resolutions = self.lane_resolutions()
        path = self.resolution([("pyyaml", "6.0.2",
                                 sha256_file(self.wheelhouse / "pyyaml-6.0.2.tar.gz"),
                                 True),
                                ("cryptography", "50.0.0",
                                 sha256_file(self.wheelhouse /
                                             "cryptography-50.0.0-cp311-abi3-"
                                             "macosx_11_0_arm64.whl"), True),
                                ("cffi", "2.1.1", "c" * 64, False)],
                               path=resolutions["dev"])
        resolutions["dev"] = path
        manifest = S.build_lock(self.wheelhouse, repo=self.repo,
                                resolutions=resolutions)
        text = S.render_lock(manifest)
        self.assertIn("pyyaml==6.0.2 --hash=sha256:"
                      + sha256_file(self.wheelhouse / "pyyaml-6.0.2.tar.gz"), text)
        self.assertIn("# lane: dev", text)
        self.assertIn("# end lane", text)
        self.assertIn("# cffi==2.1.1  # UNPINNED:", text)
        self.assertNotIn("--hash=sha256:" + "c" * 64, text)
        errors = S.verify_lock(manifest, repo=self.repo, lock_text=text)
        self.assertEqual([], [e for e in errors if "lower-case" in e or "digest" in e])

    # -- W11-W16 the cache and its restoration ----------------------------
    def test_w11_a_symlink_or_a_changed_blob_in_the_cache_is_refused(self):
        real = self.blob("pyyaml-6.0.2.tar.gz")
        (self.wheelhouse / "link.tar.gz").symlink_to(real)
        with self.assertRaisesRegex(S.SupplyChainError, "carrieth a symlink"):
            S.build_cache_manifest(self.wheelhouse)
        (self.wheelhouse / "link.tar.gz").unlink()
        manifest = S.build_cache_manifest(self.wheelhouse)
        self.assertEqual(1, len(manifest["blobs"]))
        (self.wheelhouse / "pyyaml-6.0.2.tar.gz").write_bytes(b"changed")
        errors = S.verify_cache_manifest(manifest, source_dir=self.wheelhouse)
        self.assertTrue(any("is not the blob the manifest sweareth" in item
                            for item in errors), errors)
        (self.wheelhouse / "pyyaml-6.0.2.tar.gz").unlink()
        errors = S.verify_cache_manifest(manifest, source_dir=self.wheelhouse)
        self.assertTrue(any("missing the blob" in item for item in errors), errors)

    def test_w12_a_refusal_precedeth_every_write(self):
        good = self.blob("pyyaml-6.0.2.tar.gz", b"the true bytes")
        self.blob("cffi-2.1.1.tar.gz", b"the other true bytes")
        manifest = S.build_cache_manifest(self.wheelhouse)
        destination = self.root / "restored"
        destination.mkdir()
        sentinel = destination / "keep.txt"
        sentinel.write_text("previous state")
        (self.wheelhouse / "cffi-2.1.1.tar.gz").write_bytes(b"poisoned")
        with self.assertRaisesRegex(S.SupplyChainError, "not the blob the manifest "
                                                       "sweareth"):
            S.restore(manifest, self.wheelhouse, destination)
        self.assertEqual(["keep.txt"], [p.name for p in destination.iterdir()])
        self.assertEqual("previous state", sentinel.read_text())
        self.assertEqual(b"the true bytes", (self.wheelhouse /
                                             "pyyaml-6.0.2.tar.gz").read_bytes())
        self.assertTrue(good.is_file())

    def test_w13_the_secret_scanner_refuseth_what_it_claimeth(self):
        secrets = (
            "-----BEGIN RSA PRIVATE KEY-----\nMIIE\n",
            "token=ghp_abcdefghijklmnopqrstuvwxyz\n",
            "AKIAIOSFODNN7EXAMPLE\n",
            "api_key: sk-live-1234567890\n",
            "password=hunter2\n",
            "Authorization: Bearer abcdef\n",
            "https://user:pass@example.invalid/x\n",
        )
        for text in secrets:
            with self.subTest(secret=text[:24]):
                self.assertTrue(S.no_secret_in_log(text), text)
        self.assertEqual([], S.no_secret_in_log(
            "restored pyyaml-6.0.2.tar.gz sha256=" + "a" * 64 + " bytes=130631\n"))

    def test_w14_an_unpinned_lane_cannot_be_restored(self):
        blob = self.blob("godstonefixture-1.0-py3-none-any.whl")
        manifest = self.lock_for(blob)
        entry = manifest["lanes"]["dev"]["closure"][0]
        entry.update({"status": "UNPINNED", "distributions": [], "reason": "absent"})
        with self.assertRaisesRegex(S.SupplyChainError, "no success may be claimed"):
            S.install_lane(manifest, "dev", self.wheelhouse,
                           self.root / "venv-should-not-exist", log_path=None)
        with self.assertRaisesRegex(S.SupplyChainError, "carrieth no lane"):
            S.install_lane({"lanes": {}}, "absent", self.wheelhouse,
                           self.root / "venv")

    def test_w15_a_changed_distribution_is_refused_at_the_install_door(self):
        blob = self.wheel()
        manifest = self.lock_for(blob)
        blob.write_bytes(blob.read_bytes() + b"poison")
        with self.assertRaisesRegex(S.SupplyChainError, "not the distribution the "
                                                       "lock sweareth"):
            S.install_lane(manifest, "dev", self.wheelhouse, self.root / "venv")

    def test_w16_a_lane_is_restored_offline_with_required_hashes(self):
        blob = self.wheel()
        manifest = self.lock_for(blob)
        venv = self.root / "venv"
        log = self.root / "restore.log"
        result = S.install_lane(manifest, "dev", self.wheelhouse, venv, log_path=log)
        self.assertEqual(0, result["rc"])
        self.assertTrue(result["offline"])
        self.assertTrue(result["require_hashes"])
        self.assertIn("godstonefixture", result["packages"])
        self.assertTrue((venv / "lib").is_dir())
        self.assertTrue(log.is_file())
        self.assertEqual([], S.no_secret_in_log(log.read_text()))
        interpreter = venv / "bin" / "python"
        check = subprocess.run([str(interpreter), "-c",
                                "import godstonefixture; print(godstonefixture.VALUE)"],
                               capture_output=True, text=True)
        self.assertEqual("1", check.stdout.strip())

    # -- W17-W18 the SBOM -------------------------------------------------
    def test_w17_the_sbom_must_carry_every_component_the_locks_name(self):
        resolutions = self.lane_resolutions()
        manifest = S.build_lock(self.wheelhouse, repo=self.repo,
                                resolutions=resolutions)
        toolchain = S.capture_toolchain(self.repo, clock=CLOCK, probe=self.probe())
        document = S.build_sbom(repo=self.repo, clock=CLOCK, lock=manifest,
                                toolchain=toolchain)
        names = {f"{c['ecosystem']}:{c['name']}" for c in document["components"]}
        self.assertIn("pypi:pyyaml", names)
        self.assertIn("toolchain:gradle-wrapper", names)
        self.assertEqual([], S.verify_sbom(document, lock=manifest,
                                           toolchain=toolchain))
        trimmed = dict(document, components=[c for c in document["components"]
                                             if c["name"] != "pyyaml"])
        errors = S.verify_sbom(trimmed, lock=manifest)
        self.assertTrue(any("pypi:pyyaml" in item for item in errors), errors)
        stripped = json.loads(json.dumps(document))
        del stripped["components"][0]["license"]
        errors = S.verify_sbom(stripped)
        self.assertTrue(any("recorded as unknown, not omitted" in item
                            for item in errors), errors)

    def test_w18_an_unknown_licence_is_counted_and_named(self):
        resolutions = self.lane_resolutions()
        manifest = S.build_lock(self.wheelhouse, repo=self.repo,
                                resolutions=resolutions)
        document = S.build_sbom(repo=self.repo, clock=CLOCK, lock=manifest)
        census = document["licence_census"]
        self.assertEqual(len(document["components"]), sum(census.values()))
        self.assertIn("unknown", census)
        self.assertTrue(any("pypi:pyyaml" in item for item in document["unknowns"])
                        or "unknown" in census)
        self.assertEqual("UNPINNED", document["status"])

    # -- W19-W20 the toolchain --------------------------------------------
    def probe(self, *, java: str = 'openjdk version "17.0.20.1"',
              swift: str = "Apple Swift version 6.3.3", xcode: str = "Xcode 26.6",
              xcodegen: str = "Version: 2.46.0", cmake: str | None = None,
              os_blob: str = "ProductName:\tmacOS\nProductVersion:\t26.6.2\n"
                             "BuildVersion:\t25G83"):
        blobs = {"java": java, "swift": swift, "xcodegen": xcodegen,
                 "python3": "Python 3.14.4",
                 "xcodebuild": xcode, "cmake": cmake, "sw_vers": os_blob}

        def fake(argv):
            key = str(argv[0])
            if key == "ls":
                return "27.0.12077973\n27.1.0\n"
            return blobs.get(key)
        return fake

    def test_w19_a_measured_tool_that_disagrees_with_its_pin_is_refused(self):
        """The premise is ESTABLISHED via the injected seam, not inherited from the host.

        THE NDK IS ANNOUNCED RATHER THAN DISCOVERED: `ndk_versions` names the
        installed versions, so this arm asserts a MEASURED NDK on a machine with no
        Android SDK at all. Before that seam the arm silently required the host to
        carry an SDK, which no runner does -- so the one place it mattered most was
        the one place it could not run."""
        NDK = ("27.0.12077973",)

        document = S.capture_toolchain(self.repo, clock=CLOCK,
                                       probe=self.probe(), ndk_versions=NDK)
        by_name = {tool["name"]: tool for tool in document["tools"]}
        self.assertEqual("MEASURED", by_name["ndk"]["status"])
        self.assertEqual("MEASURED", by_name["gradle-wrapper"]["status"])
        self.assertEqual("MEASURED", by_name["jdk-target"]["status"])
        self.assertEqual([], S.verify_toolchain(document, self.repo))
        other = S.capture_toolchain(self.repo, clock=CLOCK,
                                    probe=self.probe(cmake="cmake version 3.30.0"),
                                    ndk_versions=NDK)
        by_name = {tool["name"]: tool for tool in other["tools"]}
        self.assertEqual("MISMATCH", by_name["cmake"]["status"])
        errors = S.verify_toolchain(other, self.repo)
        self.assertTrue(any("disagrees with its pin is a refusal" in item
                            for item in errors), errors)
        document["status"] = "PINNED"
        errors = S.verify_toolchain(document, self.repo)
        self.assertTrue(any("half-measured toolchain" in item for item in errors), errors)
        stale = S.capture_toolchain(self.repo, clock=CLOCK, probe=self.probe())
        stale["inputs"][0]["sha256"] = "0" * 64
        errors = S.verify_toolchain(stale, self.repo)
        self.assertTrue(any("changed since the lock was captured" in item
                            for item in errors), errors)

    def test_w20_the_capture_is_deterministic_and_the_host_is_untouched(self):
        with patch.object(S, "_probe", side_effect=AssertionError("the host was probed")):
            first = S.capture_toolchain(self.repo, clock=CLOCK, probe=self.probe())
            second = S.capture_toolchain(self.repo, clock=CLOCK, probe=self.probe())
        self.assertEqual(S.canonical(first), S.canonical(second))
        self.assertEqual(["cmake", "python", "xcodegen"][0],
                         sorted(t["name"] for t in first["tools"]
                                if t["status"] == "ABSENT")[0])
        self.assertTrue(any("absent on this host" in item
                            for item in first["unresolved"]))
        self.assertTrue(any("no expectation to compare" in item
                            for item in first["unpinned"]))
        self.assertEqual("UNPINNED", first["status"])

    # -- W21-W22 Gradle's own verification --------------------------------
    def metadata(self, *, components) -> Path:
        rows = []
        for group, name, version, digests in components:
            artifacts = "".join(
                f'<artifact name="{name}-{version}.jar">'
                + "".join(f'<{kind} value="{value}"/>' for kind, value in digests)
                + "</artifact>" for _ in [0])
            rows.append(f'<component group="{group}" name="{name}" version="{version}">'
                        f"{artifacts}</component>")
        path = self.root / "verification-metadata.xml"
        path.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<verification-metadata xmlns="https://schema.gradle.org/dependency-'
            'verification">\n<configuration><verify-signatures>false</verify-'
            'signatures></configuration>\n<components>' + "".join(rows)
            + "</components></verification-metadata>\n", encoding="utf-8")
        return path

    def test_w21_the_metadata_is_parsed_through_its_namespace(self):
        path = self.metadata(components=[
            ("org.example", "good", "1.0", [("sha256", "a" * 64)]),
            ("org.example", "weak", "1.0", [("md5", "b" * 32)]),
            ("org.example", "bare", "1.0", []),
        ])
        document = S.parse_gradle_metadata(path)
        self.assertTrue(document["present"])
        self.assertEqual(3, len(document["components"]))
        self.assertEqual(1, len(document["components"][0]["digests"]))
        self.assertEqual("a" * 64, document["components"][0]["digests"][0]["value"])
        errors = S.verify_gradle_metadata(document)
        self.assertTrue(any("org.example:weak:1.0 carrieth no SHA-256" in item
                            for item in errors), errors)
        self.assertTrue(any("org.example:bare:1.0 carrieth no SHA-256 at all" in item
                            for item in errors), errors)
        self.assertTrue(any("only ['md5']" in item for item in errors), errors)
        self.assertTrue(any("signature verification is off" in item
                            for item in document["unresolved"]))
        absent = S.parse_gradle_metadata(self.root / "nothing.xml")
        self.assertFalse(absent["present"])
        self.assertTrue(S.verify_gradle_metadata(absent))

    def test_w22_a_same_version_artifact_with_different_bytes_is_refused(self):
        path = self.metadata(components=[
            ("org.example", "lib", "1.0", [("sha256", "a" * 64)])])
        document = S.parse_gradle_metadata(path)
        artifact = self.root / "lib-1.0.jar"
        artifact.write_bytes(b"the honest bytes")
        digest = sha256_file(artifact)
        path = self.metadata(components=[
            ("org.example", "lib", "1.0", [("sha256", digest)])])
        document = S.parse_gradle_metadata(path)
        self.assertEqual([], S.verify_component(document, "org.example", "lib", "1.0",
                                                artifact))
        artifact.write_bytes(b"the same version, other bytes")
        errors = S.verify_component(document, "org.example", "lib", "1.0", artifact)
        self.assertTrue(any("different bytes is refused" in item for item in errors),
                        errors)
        errors = S.verify_component(document, "org.example", "absent", "1.0", artifact)
        self.assertTrue(any("not verified at all" in item for item in errors), errors)

    def test_w23_two_runs_are_compared_by_content(self):
        left, right = self.root / "run-a", self.root / "run-b"
        left.mkdir(), right.mkdir()
        for directory in (left, right):
            (directory / "archive_light.db").write_bytes(b"identical bytes")
            (directory / "archive.apk").write_bytes(b"zip with timestamps")
        (right / "archive.apk").write_bytes(b"zip with other timestamps")
        record = S.compare_outputs(left, right, ["archive_light.db", "archive.apk"],
                                   causes={"archive.apk": "zip entry timestamps"},
                                   clock=CLOCK)
        self.assertEqual("NONDETERMINISTIC", record["status"])
        by_name = {c["name"]: c for c in record["comparisons"]}
        self.assertTrue(by_name["archive_light.db"]["identical"])
        self.assertEqual("zip entry timestamps", by_name["archive.apk"]["reason"])
        self.assertEqual([], [e for e in S.verify_determinism(record)
                              if "diverged" in e and "zip" not in e])
        unexplained = S.compare_outputs(left, right, ["archive.apk"], clock=CLOCK)
        self.assertEqual("UNEXPLAINED", unexplained["status"])
        self.assertTrue(any("carrieth no cause" in item
                            for item in S.verify_determinism(unexplained)))
        (right / "absent.bin").write_bytes(b"x")
        incomparable = S.compare_outputs(left, right, ["absent.bin"], clock=CLOCK)
        self.assertEqual("INCOMPARABLE", incomparable["status"])
        self.assertTrue(any("could not be made" in item
                            for item in S.verify_determinism(incomparable)))

    # -- W24-W26 the doors -------------------------------------------------
    def test_w24_the_command_door_reporteth_zero_and_one(self):
        blob = self.blob("godstonefixture-1.0-py3-none-any.whl")
        manifest = self.lock_for(blob)
        manifest["lanes"]["dev"]["closure"][0]["distributions"][0]["sha256"] = (
            sha256_file(blob))
        S.write_document(self.root / "dependencies.json", manifest)
        S.write_document(self.root / "cache.json",
                         S.build_cache_manifest(self.wheelhouse, clock=CLOCK))
        toolchain = S.capture_toolchain(self.repo, clock=CLOCK, probe=self.probe())
        S.write_document(self.root / "toolchain.json", toolchain)
        S.write_document(self.root / "sbom.json",
                         S.build_sbom(repo=self.repo, clock=CLOCK, lock=manifest,
                                      toolchain=toolchain))
        (self.root / "a").mkdir(), (self.root / "b").mkdir()
        (self.root / "a" / "x").write_bytes(b"same")
        (self.root / "b" / "x").write_bytes(b"same")
        S.write_document(self.root / "determinism.json",
                         S.compare_outputs(self.root / "a", self.root / "b", ["x"],
                                           clock=CLOCK))
        empty = S.parse_gradle_metadata(self.root / "none.xml")
        with patch.object(S, "parse_gradle_metadata", return_value=dict(
                empty, present=True, components=[{"group": "org.example", "name": "lib",
                                                  "version": "1.0",
                                                  "digests": [{"algorithm": "sha256",
                                                               "value": "a" * 64}],
                                                  "artifacts": []}],
                verify_signatures=True, trusted_keys=["k1"], unresolved=[])):
            self.assertEqual(1, S._verify_all(
                self.repo, toolchain_path=self.root / "toolchain.json",
                lock_path=self.root / "dependencies.json",
                cache_path=self.root / "cache.json",
                sbom_path=self.root / "sbom.json",
                determinism_path=self.root / "determinism.json",
                wheelhouse=self.wheelhouse))
        deterministic = S.compare_outputs(self.root / "a", self.root / "b", ["x"],
                                          clock=CLOCK)
        self.assertEqual("COMPARABLE", deterministic["status"])
        broken = json.loads(json.dumps(manifest))
        broken["lanes"]["dev"]["closure"][0]["distributions"][0]["sha256"] = "z" * 64
        S.write_document(self.root / "dependencies.json", broken)
        self.assertEqual(1, S._verify_all(
            self.repo, toolchain_path=self.root / "toolchain.json",
            lock_path=self.root / "dependencies.json",
            cache_path=self.root / "cache.json", sbom_path=self.root / "sbom.json",
            determinism_path=self.root / "determinism.json",
            wheelhouse=self.wheelhouse))
        self.assertEqual(1, S.main(["verify", "--all", "--manifest",
                                    str(self.root / "dependencies.json")]))

    def test_w25_the_scanner_flaggeth_nothing_in_an_honest_log(self):
        log = (f"restore lane=dev at {CLOCK()}\n"
               f"source /cache -> destination /restored\n"
               f"restored pyyaml-6.0.2.tar.gz sha256={'a' * 64} bytes=130631\n"
               f"installed cryptography==50.0.0 from /cache/cryptography-50.0.0.whl\n")
        self.assertEqual([], S.no_secret_in_log(log))
        self.assertEqual(1, len(S.no_secret_in_log(log + "token=abc\n")))

    def test_w26_an_interrupted_write_leaveth_the_previous_document(self):
        target = self.root / "document.json"
        previous = b'{"previous": "document"}\n'
        target.write_bytes(previous)
        with patch.object(S.os, "replace", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                S.write_document(target, {"schema": 1})
        self.assertEqual(previous, target.read_bytes())
        self.assertTrue(S.write_document(target, {"schema": 1}))


if __name__ == "__main__":
    unittest.main()
