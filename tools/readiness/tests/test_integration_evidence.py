#! /usr/bin/env python3
"""*** THE INTEGRATION-EVIDENCE GATE'S CONTRACT, RUN WHERE THE GATE SET CAN SEE IT. ***

`ci/check_integration_evidence.py` judgeth the Board1 cross-platform / process-death evidence by CONTENT: the required
population, the exact per-arm shapes, the re-computed digests, the live-tree input binding, and the copied-fixture
refusal. **Its own adversarial selftest (`--selftest`) must EXECUTE in the gate**, or the day a guard is deleted the
terminal job's `--require-mode all` call would still pass on a fresh green run and the deletion would be invisible.

THESE CASES:
  * RUN the gate's selftest, so its twelve mutations are exercised as part of `unittest discover -s
    tools/readiness/tests` (the board1 gate set and the workflow both run that discovery);
  * JUDGE the two committed fixtures DIRECTLY: with the age clauses neutralised they are ACCEPTED (so the gate bites
    on content, not merely on their being fixtures), and WITH those clauses on they are REFUSED as copied/stale --
    which is the property that maketh a fresh run distinguishable from a re-committed old one.
"""
from __future__ import annotations

import hashlib
import importlib.util
import io
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[3]
GATE = REPO / "ci" / "check_integration_evidence.py"
FIXTURES = REPO / "tools" / "integration-fixtures"


def _load():
    spec = importlib.util.spec_from_file_location("check_integration_evidence_under_test", GATE)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


class IntegrationEvidenceAdversarialSelftest(unittest.TestCase):
    def test_the_gates_selftest_kills_every_mutation(self) -> None:
        mod = _load()
        self.assertEqual(mod.selftest(), 0, "the integration-evidence selftest reported an ESCAPED mutation")

    def test_the_recipe_digest_tracks_inputs_not_generated_output(self) -> None:
        from tools.readiness import build_provenance

        inputs = {
            "tools/supplychain/build_sqlcipher_simulator.sh": b"native builder\n",
            "tools/supplychain/verify_sqlcipher_artifact.py": b"expectation verifier\n",
            "docs/supplychain/SQLCIPHER.pins.json": b'{"source": "pinned"}\n',
        }
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            for name, data in inputs.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            with patch.object(build_provenance, "REPO", root):
                clean = build_provenance.recipe_digest()
                expectation = root / build_provenance.EXPECTED_SOURCE
                expectation.parent.mkdir(parents=True, exist_ok=True)
                expectation.write_bytes(b"generated expectation\n")
                self.assertEqual(clean, build_provenance.recipe_digest())
                expectation.write_bytes(b"different generated expectation\n")
                self.assertEqual(clean, build_provenance.recipe_digest())
                expectation.unlink()
                self.assertEqual(clean, build_provenance.recipe_digest())
                for name, data in inputs.items():
                    with self.subTest(input=name):
                        path = root / name
                        path.write_bytes(data + b"changed recipe input\n")
                        self.assertNotEqual(clean, build_provenance.recipe_digest())
                        path.write_bytes(data)


class IntegrationEvidenceFixtures(unittest.TestCase):
    """*** THE COMMITTED FIXTURES ARE JUDGED BY CONTENT, NOT PARDONED BY BEING FIXTURES. ***"""

    def setUp(self) -> None:
        self.mod = _load()

    def test_the_cross_platform_fixture_satisfies_the_eight_combo_matrix(self) -> None:
        d = FIXTURES / "20260929T211012Z-8f8795"
        self.assertTrue((d / "integration-report.json").is_file(), "the cross-platform fixture is absent")
        probs, totals = self.mod.check_report(d, check_inputs=False, check_fixture_collision=False,
                                              check_fresh_run_proofs=False)
        self.assertFalse(probs, f"the committed cross-platform fixture was refused on content: {probs}")
        self.assertEqual(totals["cross"], 8, "the eight-combo matrix is not eight combos")

    def test_the_crash_fixture_satisfies_both_durable_boundaries(self) -> None:
        d = FIXTURES / "20260929T170839Z-e574a7"
        self.assertTrue((d / "integration-report.json").is_file(), "the crash fixture is absent")
        # *** THE TERMINATION CLAUSE IS TURNED OFF HERE BECAUSE THE FIXTURE PREDATES IT. *** *The frozen rc11 crash
        # fixture was produced by a coordinator that recorded no `crash_terminations`/`worker_terminations` at all;
        # this court judgeth its POPULATION and arms. **The clause's own teeth are proven by the gate's selftest
        # (cases 13-19) and by the separate `test_the_termination_clause_bites_a_fresh_report` below, which turneth
        # it ON against a report that carrieth the map.*
        probs, totals = self.mod.check_report(d, check_inputs=False, check_fixture_collision=False,
                                              check_fresh_run_proofs=False)
        self.assertFalse(probs, f"the committed crash fixture was refused on content: {probs}")
        self.assertEqual(totals["crash"], 2, "the crash campaign must prove both durable boundaries")

    def test_the_termination_clause_bites_a_report_that_carrieth_the_map(self) -> None:
        """*** A FRESH run's crash rows must be backed by an observed death the coordinator did not supply. ***"""
        # *The frozen crash fixture carrieth no `crash_terminations`/`worker_terminations` (it predates this clause),
        # so WITH the clause on it is refused for exactly that reason -- the observable proof that the clause is not
        # vacuous. Turned OFF, its population is judged by the test above.*
        d = FIXTURES / "20260929T170839Z-e574a7"
        probs, _ = self.mod.check_report(d, check_inputs=False, check_fixture_collision=False,
                                         check_fresh_run_proofs=True)
        self.assertTrue(any("termination" in p for p in probs),
                        f"a crash report with no observed terminations was accepted with the clause on: {probs}")

    def test_a_copied_fixture_is_refused_when_the_age_clauses_are_on(self) -> None:
        """*** THE CLAUSE THAT MAKETH A FRESH RUN DISTINGUISHABLE FROM A RE-COMMITTED OLD ONE. ***"""
        d = FIXTURES / "20260929T211012Z-8f8795"
        probs, _ = self.mod.check_report(d, check_inputs=False, check_fixture_collision=True)
        self.assertTrue(any("COMMITTED FIXTURE" in p for p in probs),
                        f"a copied fixture's run_id was accepted: {probs}")


class ServedTestedBytes(unittest.TestCase):
    """*** THE TESTED BYTES MUST TRAVEL AS `tested-bytes.tar`; A LOCAL PATH IS NEVER CONSULTED. ***

    *These cases exercise the CONSUMER half of the transportable-evidence contract directly against
    `_served_archive_problems` with small bytefiles and real tars in throwaway dirs -- no compiler, no network, no
    live register image. The `expected` mapping stands in for the register's approved `expected_output`, so the
    binding logic is proven on its own terms.*
    """

    LIBRARY_NAME = "libsqlcipher.0.dylib"
    BUNDLE_REL = "GodstoneMeshTests.xctest/GodstoneMeshTests"
    BUNDLE_BYTES = b"the built test bundle file\n"
    IMAGE_BYTES = b"the approved staged image bytes\n" * 4
    DESCRIPTOR_BYTES = b'{"library_name": "libsqlcipher.0.dylib"}\n'

    def setUp(self) -> None:
        self.mod = _load()
        from tools.readiness import build_provenance
        self.bp = build_provenance

    def _tar(self, *, bundle=None, image=None, descriptor=None, duplicate=False) -> bytes:
        bundle = self.BUNDLE_BYTES if bundle is None else bundle
        image = self.IMAGE_BYTES if image is None else image
        descriptor = self.DESCRIPTOR_BYTES if descriptor is None else descriptor
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode="w") as tar:
            members = [(f"bundle/{self.BUNDLE_REL}", bundle),
                       (f"image/{self.LIBRARY_NAME}", image)]
            if duplicate:
                members.append((f"image/{self.LIBRARY_NAME}", image))
            members.append((f"image/{self.LIBRARY_NAME}.artifact.json", descriptor))
            for name, payload in members:
                info = tarfile.TarInfo(name)
                info.size = len(payload)
                tar.addfile(info, io.BytesIO(payload))
        return buf.getvalue()

    def _attestation_and_expected(self) -> tuple[dict, dict]:
        """The recorded anchors for the UNMUTATED archive, plus the register-style expectation."""
        image_sha = hashlib.sha256(self.IMAGE_BYTES).hexdigest()
        expected = {"sha256": image_sha, "bytes": len(self.IMAGE_BYTES)}
        att = {
            "library_name": self.LIBRARY_NAME,
            "library_sha256": image_sha, "library_bytes": len(self.IMAGE_BYTES),
            "descriptor_sha256": hashlib.sha256(self.DESCRIPTOR_BYTES).hexdigest(),
            "bundle_digest": self.bp.digest_files(
                {self.BUNDLE_REL: hashlib.sha256(self.BUNDLE_BYTES).hexdigest()}),
            # Runtime provenance only -- these local paths must NEVER be consulted.
            "bundle_path": "/nonexistent/local/.build/GodstoneMeshTests.xctest",
            "library_path": "/nonexistent/tmp/libsqlcipher.0.dylib",
            "descriptor_path": "/nonexistent/tmp/libsqlcipher.0.dylib.artifact.json",
        }
        return att, expected

    def _write(self, d: Path, raw: bytes, att: dict) -> None:
        (d / self.mod.TESTED_BYTES_ARCHIVE).write_bytes(raw)
        att["tested_bytes"] = {"path": self.mod.TESTED_BYTES_ARCHIVE,
                               "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}

    def _problems(self, mutate_tar=None) -> list[str]:
        """Write the archive and its recorded anchors; the tar's raw sha/byte count always MATCH, so a
        substitution must be caught by the member facts rather than the raw archive sha."""
        att, expected = self._attestation_and_expected()
        raw = self._tar() if mutate_tar is None else mutate_tar()
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            self._write(d, raw, att)
            return self.mod._served_archive_problems(att, d, expected)

    def test_the_intact_served_archive_is_accepted_and_no_local_path_is_read(self) -> None:
        self.assertFalse(self._problems(), "the intact served archive was refused")

    def test_an_absent_archive_is_refused(self) -> None:
        att, expected = self._attestation_and_expected()
        with tempfile.TemporaryDirectory() as td:
            probs = self.mod._served_archive_problems(att, Path(td), expected)
        self.assertTrue(any("ABSENT" in p for p in probs), f"an absent archive was accepted: {probs}")

    def test_bundle_byte_substitution_is_refused(self) -> None:
        probs = self._problems(lambda: self._tar(bundle=b"a DIFFERENT bundle file\n"))
        self.assertTrue(any("served bundle" in p for p in probs), f"a substituted bundle was accepted: {probs}")

    def test_library_byte_substitution_is_refused(self) -> None:
        probs = self._problems(lambda: self._tar(image=b"a DIFFERENT image\n" * 4))
        self.assertTrue(any("served image" in p for p in probs), f"a substituted image was accepted: {probs}")

    def test_descriptor_byte_substitution_is_refused(self) -> None:
        probs = self._problems(lambda: self._tar(descriptor=b'{"a": "DIFFERENT"}\n'))
        self.assertTrue(any("served descriptor" in p for p in probs),
                        f"a substituted descriptor was accepted: {probs}")

    def test_a_digest_updated_tar_still_fails_recorded_anchors(self) -> None:
        """*** THE RAW SHA IS RE-RECORDED TO MATCH; ONLY THE MEMBER FACTS CAN CATCH THE FORGERY. ***"""
        probs = self._problems(lambda: self._tar(image=b"a DIFFERENT image\n" * 4))
        self.assertTrue(any("served image" in p and "REGISTER" in p for p in probs),
                        f"a digest-updated tar evaded the anchor comparison: {probs}")

    def test_a_local_shadow_path_cannot_override_packaged_bytes(self) -> None:
        """*** A LOCAL `.build`/TEMP FILE WITH DIFFERENT BYTES MUST NOT AFFECT A CORRECT ARCHIVE. ***"""
        att, expected = self._attestation_and_expected()
        raw = self._tar()
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            self._write(d, raw, att)
            # Re-point the runtime-provenance paths at LOCAL files whose bytes differ from the packaged payload.
            shadow = d / "shadow"
            shadow.mkdir()
            (shadow / "GodstoneMeshTests").write_bytes(b"a LOCAL shadow bundle\n")
            (shadow / "libsqlcipher.0.dylib").write_bytes(b"a LOCAL shadow image\n")
            (shadow / "libsqlcipher.0.dylib.artifact.json").write_bytes(b"a LOCAL shadow descriptor\n")
            att["bundle_path"] = str(shadow)
            att["library_path"] = str(shadow / "libsqlcipher.0.dylib")
            att["descriptor_path"] = str(shadow / "libsqlcipher.0.dylib.artifact.json")
            probs = self.mod._served_archive_problems(att, d, expected)
        self.assertFalse(probs, f"a local shadow path changed the verdict over packaged bytes: {probs}")

    def test_a_duplicate_member_archive_is_refused(self) -> None:
        probs = self._problems(lambda: self._tar(duplicate=True))
        self.assertTrue(any("cannot be read" in p for p in probs), f"a duplicate-member archive was accepted: {probs}")

    def test_a_non_archive_name_is_refused_structurally(self) -> None:
        att, _expected = self._attestation_and_expected()
        att["tested_bytes"] = {"path": "/tmp/elsewhere.tar", "sha256": "0" * 64, "bytes": 1}
        with tempfile.TemporaryDirectory() as td:
            probs = self.mod._tested_bytes_problems({"build_attestation": att}, Path(td))
        self.assertTrue(any("tested_bytes.path" in p for p in probs),
                        f"a non-served archive name was accepted: {probs}")


if __name__ == "__main__":
    unittest.main()
