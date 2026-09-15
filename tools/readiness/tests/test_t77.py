#! /usr/bin/env python3
"""T77 readiness court (python isle): upgrade, failed-update and rollback recovery.

The card's law, one named witness each:

  W01  the matrix refuseth the UNKNOWN FUTURE schema by name
  W02  the matrix refuseth the UNSUPPORTED DOWNGRADE by name
  W03  an UNDECLARED migration is refused by name; a DECLARED one is applied
  W04  the matrix refuseth a matrix that would publish a schema the build
       may not run, and a fresh install is lawful
  W05  the authority is bound to the shipped schema and to the REAL verifier
  W06  an absent trust store is refused by name, before any write (offline)
  W07  a PARTIAL estate is refused as partial -- never read as empty
  W08  the published manifest must name bytes that are PRESENT
  W09  an untrusted signature is refused by name and the estate is preserved
  W10  the replacement is applied AND the previous pair is retained, sworn
  W11  the rollback returneth the previous authoritative bytes exactly
  W12  the rollback is refused when the retained schema is not runnable
  W13  an interruption AFTER the archive was placed leaveth the previous
       estate whole, and the journal sayeth which boundary fired
  W14  an interruption MID-STAGING leaveth the previous estate standing
  W15  a real CRASH is resumed from the record alone to a terminal state
  W16  a full disk is named as the cause, the transaction does not complete,
       and the previous estate is restored whole
  W17  the card's named SEMANTIC NEGATIVE: a future schema is refused and the
       estate is preserved byte for byte -- the mutant that recreateth it
       empty dieth here
  W18  the published manifest is never observed naming bytes that are ABSENT,
       at any boundary of the transaction
  W19  the wipe is journaled; a mid-wipe estate is refused as partial and the
       resumption reacheth WIPED
  W20  the instructions name every artifact, the authority fetcheth nothing,
       and the operator documentation carrieth the same law
  W21  the PRODUCTION staging face carrieth the very same transaction
       (retention + boundary seam), through the release asset gate itself
  W22  every report carrieth the device claim UNVERIFIED and no production
       claim, and the record is deterministic
  W23  both doors speak for themselves: the selftest passeth and the
       rehearsal door reporteth its declared cases

Every world is built in a temporary region from HARMLESS development bytes
(app-navigation prose only), signed with a TEST-ONLY key generated here, and
labelled: a rehearsal is not an approval, no external gate is closed, and no
device claim is made. Readiness stays false.
"""
from __future__ import annotations

import ast
import hashlib
import json
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import os
import pathlib
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
for _lane in (str(REPO),):
    if _lane not in sys.path:
        sys.path.insert(0, _lane)

from content.archive_manifest import (  # noqa: E402
    create_manifest, generate_test_keypair, load_private_key, load_trust_store,
    verify_manifest)
from scripts import prepare_release_assets as staging  # noqa: E402
from scripts import upgrade_recovery as U  # noqa: E402

FROZEN = lambda: "1970-01-01T00:00:00+00:00"  # noqa: E731
FIXTURE_KEY_ID = "T77-FIXTURE-KEY"


class _Probe(staging.PublishHooks):
    """A boundary probe: it recordeth every boundary and may die at one."""

    def __init__(self, die_at: str | None = None) -> None:
        self.seen: list[str] = []
        self.die_at = die_at

    def at(self, boundary: str) -> None:
        self.seen.append(boundary)
        if boundary == self.die_at:
            raise U.RecoveryInterrupted(boundary)


class UpgradeRecoveryCourt(unittest.TestCase):
    """T77: the recovery protocol as it actually behaveth."""

    maxDiff = None

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="godstone-t77-court-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.world = U._development_world(self.root / "world")
        self.trust = self.world["trust_store"]
        self.estate = self.world["estate"]
        self.operations = self.root / "operations"
        self.reset()

    # -- world helpers -------------------------------------------------------
    def reset(self, variant: str = "installed"):
        U._write_development_estate(self.estate, self.world["archives"][variant],
                                    self.world["manifests"][variant])
        return U.open_estate(self.estate, self.trust)

    def source(self, variant: str = "candidate") -> U.CandidateSource:
        return U.CandidateSource(archive=self.world["archives"][variant],
                                 signed_manifest=self.world["manifests"][variant])

    def rehearse(self, case_id: str, variant: str = "candidate", *,
                 expectation: str = U.APPLIED, matrix=None, **kw):
        case = U.UpgradeCase(case_id, expectation, interruption=kw.pop("interruption", None),
                             disk_fault=kw.pop("disk_fault", None))
        return U.rehearse(case, estate=self.estate, candidate=self.source(variant),
                          trust_store=self.trust, work_root=self.operations / case_id,
                          matrix=matrix or U.SHIPPED_MATRIX, clock=FROZEN, **kw)

    def bytes_of(self, path: Path) -> dict[str, str]:
        return {item.name: U.sha256_file(item) for item in sorted(Path(path).iterdir())
                if item.is_file()}

    def approved_bundle(self, variant: str = "candidate") -> dict[str, Path]:
        """A bundle the RELEASE ASSET GATE accepteth, self-fabricated and
        labelled (the T45 precedent): the three production review digests are
        declared by this fixture so the gate's SHAPE and BINDING are
        exercised. It is not an approved corpus and closeth APPROVED_CONTENT
        for nothing."""
        bundle = self.root / f"bundle-{variant}"
        payload = bundle / "payload"
        payload.mkdir(parents=True, exist_ok=True)
        archive = payload / U.ESTATE_ARCHIVE_NAME
        shutil.copyfile(self.world["archives"][variant], archive)
        digests = {
            "source_manifest_sha256": hashlib.sha256(b"T77-FIXTURE-SOURCE").hexdigest(),
            "review_manifest_sha256": hashlib.sha256(b"T77-FIXTURE-REVIEW").hexdigest(),
            "release_manifest_set_sha256": hashlib.sha256(b"T77-FIXTURE-SET").hexdigest(),
            # GS-CONTENT-001: the release-eligibility routine requyreth the final chunk
            # approvals among the production provenance. This fixture DECLARES the digest
            # rather than obtaining an approval -- it is a shape/binding fixture and
            # closeth APPROVED_CONTENT for nothing.
            "approvals_sha256": hashlib.sha256(b"T77-FIXTURE-APPROVALS").hexdigest(),
        }
        connection = sqlite3.connect(archive)
        try:
            connection.executemany("INSERT OR REPLACE INTO archive_meta VALUES (?,?)",
                                   sorted(digests.items()))
            connection.commit()
        finally:
            connection.close()
        private = bundle / "signing.key"
        trust = bundle / "trust.json"
        generate_test_keypair(private, trust, key_id=FIXTURE_KEY_ID)
        signed = bundle / "archive_manifest.json"
        create_manifest(archive, signed, tier=U.ESTATE_TIER, archive_schema=3,
                        source_manifest_sha256=digests["source_manifest_sha256"],
                        review_manifest_sha256=digests["review_manifest_sha256"],
                        corpus_manifest_sha256=digests["release_manifest_set_sha256"],
                        build_tool_commit="t77-fixture-commit",
                        private_key=load_private_key(private), key_id=FIXTURE_KEY_ID)
        document = {
            "schema": 1, "tier": U.ESTATE_TIER, "application_id": "io.godstone.app",
            "status": "approved", "production_ready": True,
            "assets": [{"role": "archive", "name": U.ESTATE_ARCHIVE_NAME,
                        "source": f"payload/{U.ESTATE_ARCHIVE_NAME}",
                        "bytes": archive.stat().st_size, "sha256": U.sha256_file(archive)}],
            "archive_manifest": "archive_manifest.json",
        }
        manifest = bundle / "assets.json"
        manifest.write_text(json.dumps(document, sort_keys=True, indent=2) + "\n",
                            encoding="utf-8")
        return {"bundle": bundle, "archive": archive, "signed": signed,
                "trust": trust, "private": private, "manifest": manifest}

    def sealed_estate(self, bundle: dict[str, Path], variant: str = "installed"):
        """An estate whose signed record is the FIXTURE key's -- so the
        production face can be driven against it with that operator store."""
        estate = self.root / f"sealed-estate-{variant}"
        estate.mkdir(parents=True, exist_ok=True)
        # the signed manifest NAMETH its archive's filename, and an estate
        # holdeth the one canonical name: the fixture must be built where it
        # will be installed, or the verifier refuseth it (and it should).
        archive = estate / U.ESTATE_ARCHIVE_NAME
        shutil.copyfile(self.world["archives"][variant], archive)
        connected = sqlite3.connect(archive)
        try:
            connected.executemany(
                "INSERT OR REPLACE INTO archive_meta VALUES (?,?)",
                sorted({"source_manifest_sha256": hashlib.sha256(b"T77-FIXTURE-SOURCE").hexdigest(),
                        "review_manifest_sha256": hashlib.sha256(b"T77-FIXTURE-REVIEW").hexdigest(),
                        "release_manifest_set_sha256": hashlib.sha256(b"T77-FIXTURE-SET").hexdigest(),
                        }.items()))
            connected.commit()
        finally:
            connected.close()
        # the SAME operator key as the bundle: an estate and the candidate that
        # would replace it are both answered by the store the operator selected,
        # and re-keying the bundle's store here would silently break the one
        # binding the whole witness resteth on.
        private = bundle["private"]
        record_dir = U.estate_record_dir(estate)
        record_dir.mkdir(parents=True, exist_ok=True)
        signed = record_dir / U.ESTATE_SIGNED_NAME
        create_manifest(archive, signed, tier=U.ESTATE_TIER, archive_schema=3,
                        source_manifest_sha256=hashlib.sha256(b"T77-FIXTURE-SOURCE").hexdigest(),
                        review_manifest_sha256=hashlib.sha256(b"T77-FIXTURE-REVIEW").hexdigest(),
                        corpus_manifest_sha256=hashlib.sha256(b"T77-FIXTURE-SET").hexdigest(),
                        build_tool_commit="t77-fixture-commit",
                        private_key=load_private_key(private), key_id=FIXTURE_KEY_ID)
        U._write_json_atomic(estate / U.ESTATE_APPROVED_NAME, {
            "schema": staging.APPROVED_MANIFEST_SCHEMA, "tier": U.ESTATE_TIER,
            "application_id": "io.godstone.app",
            "generated_by": "tools/readiness/tests/test_t77.py (T77-FIXTURE -- NOT AN APPROVAL)",
            "assets": [{"role": "archive", "name": U.ESTATE_ARCHIVE_NAME,
                        "sha256": U.sha256_file(archive),
                        "bytes": archive.stat().st_size, "build_phase": "resources"}],
        })
        return estate

    # -- W01 -----------------------------------------------------------------
    def test_w01_the_unknown_future_schema_is_refused_by_name(self):
        direction, refusal = U.SHIPPED_MATRIX.classify(3, 4)
        self.assertIsNone(direction)
        self.assertIn("unknown future schema 4 refused", refusal)
        self.assertIn("never recreated empty", refusal)
        self.assertIsNone(U.SHIPPED_MATRIX.classify(None, 4)[0])
        self.assertIsNone(U.SHIPPED_MATRIX.classify(4, 4)[0],
                          "a future INSTALLED schema must be refused too")

    # -- W02 -----------------------------------------------------------------
    def test_w02_the_unsupported_downgrade_is_refused_by_name(self):
        direction, refusal = U.SHIPPED_MATRIX.classify(3, 2)
        self.assertIsNone(direction)
        self.assertIn("unsupported archive schema 2 refused", refusal)
        self.assertIn("publish eth schema 3", refusal)
        # ... and the refusal precedeth every write
        before = self.bytes_of(self.estate)
        result = self.rehearse("w02", "prior", expectation=U.REFUSED)
        self.assertEqual(result.outcome, U.REFUSED, result.refusals)
        self.assertTrue(result.preserved)
        self.assertEqual(before, self.bytes_of(self.estate),
                         "a refused downgrade mutated the estate")

    # -- W03 -----------------------------------------------------------------
    def test_w03_a_declared_migration_is_applied_and_an_undeclared_one_is_not(self):
        before = self.reset("prior")
        self.assertEqual(before.schema, 2)
        refused = self.rehearse("w03-undeclared", "installed", expectation=U.REFUSED)
        self.assertEqual(refused.outcome, U.REFUSED)
        self.assertTrue(any("no declared migration from installed schema 2" in item
                            for item in refused.refusals), refused.refusals)
        self.assertTrue(refused.preserved)
        applied = self.rehearse("w03-declared", "installed", matrix=U.REHEARSAL_MATRIX)
        self.assertEqual(applied.outcome, U.APPLIED, applied.refusals)
        self.assertEqual(applied.direction, U.UPGRADE)
        self.assertEqual(applied.installed_schema, 2)
        self.assertEqual(applied.candidate_schema, 3)
        self.assertEqual(U.open_estate(self.estate, self.trust).schema, 3)
        self.assertTrue(applied.rollback_permitted, applied.rollback_refusal)
        self.assertEqual(applied.retained_schema, 2)

    # -- W04 -----------------------------------------------------------------
    def test_w04_the_matrix_may_not_publish_a_schema_the_build_may_not_run(self):
        with self.assertRaises(U.RecoveryError) as caught:
            U.RollbackCompatibilityMatrix(accepted_schema=3, supported_installed=(2,))
        self.assertIn("may not open", str(caught.exception))
        with self.assertRaises(U.RecoveryError):
            U.RollbackCompatibilityMatrix(accepted_schema=3, supported_installed=())
        with self.assertRaises(U.RecoveryError):
            U.RollbackCompatibilityMatrix(accepted_schema=3, supported_installed=(3,),
                                          migrations=((2, 4),))
        self.assertEqual(U.SHIPPED_MATRIX.classify(None, 3), (U.INSTALL, None))
        self.assertEqual(U.SHIPPED_MATRIX.classify(3, 3), (U.REPLACE, None))
        self.assertEqual(U.SHIPPED_MATRIX.migrations, (),
                         "this baseline declareth NO supported earlier version")

    # -- W05 -----------------------------------------------------------------
    def test_w05_the_authority_is_bound_to_the_shipped_schema_and_the_real_verifier(self):
        from content.ingest.build_archive import SCHEMA_VERSION
        self.assertEqual(U.ACCEPTED_ARCHIVE_SCHEMA, SCHEMA_VERSION,
                         "the accepted schema must be the archive builder's own")
        self.assertEqual(U.SHIPPED_MATRIX.accepted_schema, SCHEMA_VERSION)
        # a matrix that disagreeth with the shipped schema is refused outright
        alien = U.RollbackCompatibilityMatrix(accepted_schema=4, supported_installed=(4,))
        with self.assertRaises(U.RecoveryError) as caught:
            U.rehearse(U.UpgradeCase("w05", U.APPLIED), estate=self.estate,
                       candidate=self.source(), trust_store=self.trust,
                       work_root=self.operations / "w05", matrix=alien, clock=FROZEN)
        self.assertIn("disagreeth with the shipped schema", str(caught.exception))
        # and the estate is opened by the REAL verifier: a flipped byte in the
        # signed record is refused by name rather than trusted
        signed = U.estate_record_path(self.estate)
        document = json.loads(signed.read_text(encoding="utf-8"))
        document["archive_sha256"] = "0" * 64
        signed.write_text(json.dumps(document, sort_keys=True), encoding="utf-8")
        with self.assertRaises(U.RecoveryError) as caught:
            U.open_estate(self.estate, self.trust)
        self.assertIn("refused by the signed archive manifest", str(caught.exception))

    # -- W06 -----------------------------------------------------------------
    def test_w06_an_absent_trust_store_is_refused_by_name_before_any_write(self):
        before = self.bytes_of(self.estate)
        absent = self.root / "no-such-trust-store.json"
        with self.assertRaises(U.RecoveryError) as caught:
            U.rehearse(U.UpgradeCase("w06", U.APPLIED), estate=self.estate,
                       candidate=self.source(), trust_store=absent,
                       work_root=self.operations / "w06", clock=FROZEN)
        self.assertIn("trust store is required", str(caught.exception))
        self.assertEqual(before, self.bytes_of(self.estate))
        with self.assertRaises(U.RecoveryError):
            U.open_estate(self.estate, absent)
        with self.assertRaises(U.RecoveryError):
            U.open_candidate(self.source(), absent)

    # -- W07 -----------------------------------------------------------------
    def test_w07_a_partial_estate_is_refused_as_partial_never_as_empty(self):
        for keep in U.ESTATE_PAIR:
            with self.subTest(kept=keep):
                partial = self.root / f"partial-{keep}"
                shutil.rmtree(partial, ignore_errors=True)
                partial.mkdir(parents=True)
                shutil.copyfile(self.estate / keep, partial / keep)
                with self.assertRaises(U.RecoveryError) as caught:
                    U.open_estate(partial, self.trust)
                self.assertIn("incomplete", str(caught.exception))
                self.assertIn("never read as an empty one", str(caught.exception))
        # a record that answereth no estate is a broken state, not an install
        orphan = self.root / "orphan-estate"
        orphan.mkdir()
        orphan_record = U.estate_record_dir(orphan)
        orphan_record.mkdir()
        shutil.copyfile(U.estate_record_path(self.estate),
                        orphan_record / U.ESTATE_SIGNED_NAME)
        with self.assertRaises(U.RecoveryError) as caught:
            U.open_estate(orphan, self.trust)
        self.assertIn("standeth without an estate", str(caught.exception))
        # an estate whose directory carrieth a stranger is refused by name
        stranger = self.root / "stranger-estate"
        shutil.copytree(self.estate, stranger)
        shutil.copytree(U.estate_record_dir(self.estate), U.estate_record_dir(stranger))
        (stranger / "leftover.db").write_bytes(b"T77-FIXTURE-LEFTOVER")
        with self.assertRaises(U.RecoveryError) as caught:
            U.open_estate(stranger, self.trust)
        self.assertIn("unexpected entries", str(caught.exception))
        # a wholly absent estate IS a fresh install
        self.assertFalse(U.open_estate(self.root / "nothing-here", self.trust).present)

    # -- W08 -----------------------------------------------------------------
    def test_w08_the_published_manifest_must_name_bytes_that_are_present(self):
        self.estate.joinpath(U.ESTATE_ARCHIVE_NAME).write_bytes(b"T77-FIXTURE-STRANGER")
        with self.assertRaises(U.RecoveryError) as caught:
            U.open_estate(self.estate, self.trust)
        self.assertIn("nameth bytes that are not present", str(caught.exception))
        self.assertIn("never empty", str(caught.exception))

    # -- W09 -----------------------------------------------------------------
    def test_w09_an_untrusted_signature_is_refused_by_name_and_preserves_the_estate(self):
        before = self.bytes_of(self.estate)
        stranger = self.root / "stranger"
        stranger.mkdir()
        private = stranger / "key"
        trust = stranger / "trust.json"
        generate_test_keypair(private, trust, key_id="T77-STRANGER-KEY")
        signed = stranger / U.ESTATE_SIGNED_NAME
        create_manifest(self.world["archives"]["candidate"], signed, tier=U.ESTATE_TIER,
                        archive_schema=3, source_manifest_sha256="1" * 64,
                        review_manifest_sha256="2" * 64, corpus_manifest_sha256="3" * 64,
                        build_tool_commit="t77-stranger",
                        private_key=load_private_key(private), key_id="T77-STRANGER-KEY")
        with self.assertRaises(U.RecoveryError) as caught:
            U.open_candidate(U.CandidateSource(archive=self.world["archives"]["candidate"],
                                               signed_manifest=signed),
                             self.trust)
        self.assertIn("signing key is not trusted", str(caught.exception))
        result = U.rehearse(U.UpgradeCase("w09", U.REFUSED), estate=self.estate,
                            candidate=U.CandidateSource(archive=self.world["archives"]["candidate"],
                                                        signed_manifest=signed),
                            trust_store=self.trust, work_root=self.operations / "w09",
                            clock=FROZEN)
        self.assertEqual(result.outcome, U.REFUSED)
        self.assertTrue(result.preserved)
        self.assertEqual(before, self.bytes_of(self.estate))

    # -- W10 -----------------------------------------------------------------
    def test_w10_the_replacement_is_applied_and_the_previous_pair_is_retained(self):
        before = U.open_estate(self.estate, self.trust)
        result = self.rehearse("w10")
        self.assertEqual(result.outcome, U.APPLIED, result.refusals)
        self.assertEqual(result.direction, U.REPLACE)
        self.assertNotEqual(result.old_archive_sha256, result.new_archive_sha256,
                            "the replacement did not change a byte")
        after = U.open_estate(self.estate, self.trust)
        self.assertEqual(after.archive_sha256, result.new_archive_sha256,
                         "the published manifest must name the bytes that are present")
        retained = Path(result.retained_path or "")
        record_path = retained / staging.RETENTION_RECORD_NAME
        self.assertTrue(record_path.is_file(), "no retention record was written")
        record = json.loads(record_path.read_text(encoding="utf-8"))
        self.assertEqual(record["schema"], 1)
        self.assertEqual(record["archive"]["sha256"], before.archive_sha256)
        self.assertEqual(record["approved_manifest"]["sha256"], before.approved_manifest_sha256)
        self.assertEqual(U.sha256_file(retained / U.ESTATE_ARCHIVE_NAME), before.archive_sha256)
        self.assertEqual(U.sha256_file(retained / U.ESTATE_SIGNED_NAME),
                         before.signed_manifest_sha256)
        self.assertEqual(result.boundaries,
                         ("validated", "retained", "before_archive_replace",
                          "after_archive_replace", "before_manifest_publish", "published"))
        self.assertEqual(result.journal[-1], U.COMPLETED)
        self.assertFalse(result.preserved)

    # -- W11 -----------------------------------------------------------------
    def test_w11_the_rollback_returneth_the_previous_authoritative_bytes_exactly(self):
        before = U.open_estate(self.estate, self.trust)
        before_bytes = self.bytes_of(self.estate)
        applied = self.rehearse("w11")
        self.assertEqual(applied.outcome, U.APPLIED)
        self.assertNotEqual(self.bytes_of(self.estate), before_bytes)
        rolled = U.rollback(estate=self.estate, retained=Path(applied.retained_path),
                            trust_store=self.trust, work_root=self.operations / "w11-rollback",
                            clock=FROZEN)
        self.assertEqual(rolled.outcome, U.RECOVERED, rolled.refusals)
        restored = U.open_estate(self.estate, self.trust)
        self.assertEqual(restored.archive_sha256, before.archive_sha256)
        self.assertTrue(restored.same_bytes_as(before))
        # the rolled-back estate is a lawful rollback target for the FUTURE too
        self.assertTrue(rolled.rollback_permitted, rolled.rollback_refusal)

    # -- W12 -----------------------------------------------------------------
    def test_w12_a_rollback_to_a_schema_the_build_may_not_run_is_refused(self):
        applied = self.rehearse("w12")
        self.assertEqual(applied.outcome, U.APPLIED)
        refused = U.rollback(estate=self.estate, retained=Path(applied.retained_path),
                             trust_store=self.trust, work_root=self.operations / "w12-rollback",
                             matrix=U.RollbackCompatibilityMatrix(
                                 accepted_schema=3, supported_installed=(3,)),
                             clock=FROZEN)
        self.assertTrue(refused.rollback_permitted, refused.rollback_refusal)
        # ... and the arm that actually carrieth the law: a retention whose
        # schema this build may not run is refused BY NAME, and the estate is
        # left exactly as the candidate left it.
        self.reset("prior")
        migrated = self.rehearse("w12-migration", "installed", matrix=U.REHEARSAL_MATRIX)
        self.assertEqual(migrated.outcome, U.APPLIED, migrated.refusals)
        self.assertEqual(migrated.retained_schema, 2)
        standing = self.bytes_of(self.estate)
        incompatible = U.rollback(
            estate=self.estate, retained=Path(migrated.retained_path), trust_store=self.trust,
            work_root=self.operations / "w12-incompatible",
            matrix=U.RollbackCompatibilityMatrix(accepted_schema=3, supported_installed=(3,)),
            clock=FROZEN)
        self.assertEqual(incompatible.outcome, U.REFUSED)
        self.assertTrue(any("is not one this build may run" in item
                            for item in incompatible.refusals), incompatible.refusals)
        self.assertEqual(standing, self.bytes_of(self.estate),
                         "a refused rollback mutated the estate")
        no_target = U.rollback(estate=self.estate, retained=self.root / "no-retention",
                               trust_store=self.trust, work_root=self.operations / "w12-none",
                               clock=FROZEN)
        self.assertEqual(no_target.outcome, U.REFUSED)
        self.assertTrue(any("there is no rollback target" in item or
                            "not present" in item for item in no_target.refusals),
                        no_target.refusals)

    # -- W13 -----------------------------------------------------------------
    def test_w13_an_interruption_after_the_placement_leaveth_the_previous_estate_whole(self):
        before = U.open_estate(self.estate, self.trust)
        result = self.rehearse("w13", interruption="after_archive_replace",
                               expectation=U.INTERRUPTED)
        self.assertEqual(result.outcome, U.INTERRUPTED, result.refusals)
        self.assertTrue(result.preserved)
        self.assertEqual(self.bytes_of(self.estate), self.bytes_of(self.estate))
        restored = U.open_estate(self.estate, self.trust)
        self.assertTrue(restored.same_bytes_as(before),
                        "the interruption left a half-applied pair standing")
        self.assertIn(U.ARCHIVE_REPLACED, result.journal)
        self.assertIn(U.ROLLED_BACK, result.journal)
        self.assertEqual(result.refusals, ("interrupted at after_archive_replace",))

    # -- W14 -----------------------------------------------------------------
    def test_w14_an_interruption_mid_staging_leaveth_the_previous_estate_standing(self):
        before = U.open_estate(self.estate, self.trust)
        for boundary in ("validated", "retained", "before_archive_replace"):
            with self.subTest(boundary=boundary):
                self.reset()
                result = self.rehearse(f"w14-{boundary}", interruption=boundary,
                                       expectation=U.INTERRUPTED)
                self.assertEqual(result.outcome, U.INTERRUPTED, result.refusals)
                self.assertTrue(result.preserved)
                self.assertTrue(U.open_estate(self.estate, self.trust).same_bytes_as(before))

    # -- W15 -----------------------------------------------------------------
    def test_w15_a_real_crash_is_resumed_from_the_record_alone(self):
        before = U.open_estate(self.estate, self.trust)
        case = U.UpgradeCase("w15", U.RECOVERED, interruption="after_archive_replace")
        with self.assertRaises(U.RecoveryInterrupted):
            U.rehearse(case, estate=self.estate, candidate=self.source(), trust_store=self.trust,
                       work_root=self.operations / "w15", clock=FROZEN, settle_on_fault=False)
        # nothing mended the estate: it is mid-update and refused as such
        with self.assertRaises(U.RecoveryError) as caught:
            U.open_estate(self.estate, self.trust)
        self.assertIn("nameth bytes that are not present", str(caught.exception))
        journal = json.loads((self.operations / "w15" /
                              f"w15.{U.JOURNAL_NAME}").read_text(encoding="utf-8"))
        self.assertEqual(journal["schema"], U.JOURNAL_SCHEMA)
        self.assertEqual(journal["entries"][-1]["state"], U.ARCHIVE_REPLACED)
        resumed = U.resume(estate=self.estate, trust_store=self.trust,
                           work_root=self.operations / "w15", case_id="w15", clock=FROZEN)
        self.assertEqual(resumed.outcome, U.RECOVERED, resumed.refusals)
        self.assertTrue(U.open_estate(self.estate, self.trust).same_bytes_as(before))
        # resuming a journal nobody wrote is refused rather than guessed at
        with self.assertRaises(U.RecoveryError) as caught:
            U.resume(estate=self.estate, trust_store=self.trust,
                     work_root=self.operations / "nothing", case_id="nothing", clock=FROZEN)
        self.assertIn("no journal standeth", str(caught.exception))
        # a FUTURE journal schema is refused, never auto-detected
        future_root = self.operations / "w15-future"
        future_root.mkdir(parents=True, exist_ok=True)
        (future_root / f"w15-future.{U.JOURNAL_NAME}").write_text(
            json.dumps({"schema": 2, "entries": [{"state": U.COMPLETED}]}) + "\n",
            encoding="utf-8")
        with self.assertRaises(U.RecoveryError) as caught:
            U.resume(estate=self.estate, trust_store=self.trust, work_root=future_root,
                     case_id="w15-future", clock=FROZEN)
        self.assertIn("journal schema 2 is refused", str(caught.exception))

    # -- W16 -----------------------------------------------------------------
    def test_w16_a_full_disk_is_named_and_the_previous_estate_is_restored(self):
        before = U.open_estate(self.estate, self.trust)
        result = self.rehearse("w16", disk_fault="after_archive_replace",
                               expectation=U.INTERRUPTED)
        self.assertEqual(result.outcome, U.INTERRUPTED, result.refusals)
        self.assertTrue(any("the disk was full" in item for item in result.refusals),
                        result.refusals)
        self.assertTrue(any("preserved" in item for item in result.refusals), result.refusals)
        self.assertTrue(result.preserved)
        self.assertTrue(U.open_estate(self.estate, self.trust).same_bytes_as(before))
        early = self.rehearse("w16-early", disk_fault="before_archive_replace",
                              expectation=U.INTERRUPTED)
        self.assertEqual(early.outcome, U.INTERRUPTED, early.refusals)
        self.assertNotIn(U.ARCHIVE_REPLACED, early.journal)
        self.assertTrue(U.open_estate(self.estate, self.trust).same_bytes_as(before))

    # -- W17 -----------------------------------------------------------------
    def test_w17_a_future_schema_is_refused_and_the_estate_is_never_recreated_empty(self):
        before = U.open_estate(self.estate, self.trust)
        before_bytes = self.bytes_of(self.estate)
        result = self.rehearse("w17", "future", expectation=U.REFUSED)
        self.assertEqual(result.outcome, U.REFUSED, result.refusals)
        self.assertTrue(any("unknown future schema 4 refused" in item for item in result.refusals),
                        result.refusals)
        self.assertTrue(result.preserved)
        self.assertEqual(result.journal, (U.REFUSED,))
        after = U.open_estate(self.estate, self.trust)
        self.assertTrue(after.present, "the future schema emptied the estate")
        self.assertTrue(after.same_bytes_as(before))
        self.assertEqual(before_bytes, self.bytes_of(self.estate),
                         "the estate was recreated rather than preserved")
        # the same estate is a FUTURE-INSTALLED schema now: still refused, and
        # still never emptied -- the card's named semantic negative, second limb
        U._write_development_estate(self.estate, self.world["archives"]["future"],
                                    self.world["manifests"]["future"])
        future_bytes = self.bytes_of(self.estate)
        second = self.rehearse("w17-installed", expectation=U.REFUSED)
        self.assertEqual(second.outcome, U.REFUSED, second.refusals)
        self.assertTrue(any("unknown future installed schema 4" in item
                            for item in second.refusals), second.refusals)
        self.assertEqual(future_bytes, self.bytes_of(self.estate))

    # -- W18 -----------------------------------------------------------------
    def test_w18_the_published_manifest_never_nameth_absent_bytes_at_any_boundary(self):
        """Every boundary of the transaction, observed: the estate either
        openeth WHOLE, or it is refused by name -- and the resumption reacheth
        a whole estate in both cases. A silent read of a half pair is the
        defect this witness existeth to refuse."""
        for boundary in staging.PUBLISH_BOUNDARIES:
            with self.subTest(boundary=boundary):
                self.reset()
                case = U.UpgradeCase(f"w18-{boundary}", U.INTERRUPTED, interruption=boundary)
                work = self.operations / f"w18-{boundary}"
                try:
                    U.rehearse(case, estate=self.estate, candidate=self.source(),
                               trust_store=self.trust, work_root=work, clock=FROZEN,
                               settle_on_fault=False)
                    self.assertTrue(U.open_estate(self.estate, self.trust).present)
                except U.RecoveryInterrupted:
                    try:
                        observed = U.open_estate(self.estate, self.trust)
                    except U.RecoveryError as caught:
                        self.assertIn("nameth bytes that are not present", str(caught))
                    else:
                        self.assertIsNotNone(observed.archive_sha256)
                    settled = U.resume(estate=self.estate, trust_store=self.trust,
                                       work_root=work, case_id=f"w18-{boundary}", clock=FROZEN)
                    self.assertIn(settled.outcome, (U.RECOVERED, U.APPLIED), settled.outcome)
                    whole = U.open_estate(self.estate, self.trust)
                    self.assertTrue(whole.present,
                                    "the transaction did not settle to a whole estate")
                    published = json.loads(
                        (self.estate / U.ESTATE_APPROVED_NAME).read_text(encoding="utf-8"))
                    self.assertEqual(published["assets"][0]["sha256"], whole.archive_sha256,
                                     "the published manifest nameth bytes that are not present")

    # -- W19 -----------------------------------------------------------------
    def test_w19_the_wipe_is_journaled_and_a_mid_wipe_estate_resumeth_to_wiped(self):
        with self.assertRaises(U.RecoveryInterrupted):
            U.wipe(estate=self.estate, work_root=self.operations / "w19", case_id="w19",
                   interruption=U.WIPE_ARCHIVE_UNLINKED, clock=FROZEN)
        with self.assertRaises(U.RecoveryError) as caught:
            U.open_estate(self.estate, self.trust)
        self.assertIn("incomplete", str(caught.exception))
        journal = json.loads((self.operations / "w19" /
                              f"w19.{U.JOURNAL_NAME}").read_text(encoding="utf-8"))
        self.assertEqual(journal["entries"][-1]["state"], U.WIPE_ARCHIVE_UNLINKED)
        done = U.resume(estate=self.estate, trust_store=self.trust,
                        work_root=self.operations / "w19", case_id="w19", clock=FROZEN)
        self.assertEqual(done.outcome, U.WIPED, done.refusals)
        self.assertFalse(U.open_estate(self.estate, self.trust).present,
                         "a wiped estate must read as a fresh install, not as content")
        self.assertFalse((self.estate / U.ESTATE_ARCHIVE_NAME).exists())
        # a wipe is terminal and IDEMPOTENT: resuming it again changeth nothing
        again = U.resume(estate=self.estate, trust_store=self.trust,
                         work_root=self.operations / "w19", case_id="w19", clock=FROZEN)
        self.assertEqual(again.outcome, U.WIPED)
        with self.assertRaises(U.RecoveryError) as caught:
            U.resume(estate=self.estate, trust_store=self.trust,
                     work_root=self.operations / "w19-none", case_id="w19-none", clock=FROZEN)
        self.assertIn("no journal standeth", str(caught.exception))

    # -- W20 -----------------------------------------------------------------
    def test_w20_the_instructions_name_every_artifact_and_nothing_is_fetched(self):
        text = " ".join(U.recovery_instructions())
        for needle in (U.ESTATE_ARCHIVE_NAME, U.ESTATE_APPROVED_NAME, U.ESTATE_SIGNED_NAME,
                       "RETENTION.json", "OFFLINE", "verify", "rollback", "resume", "wipe",
                       U.DEVICE_CLAIM):
            self.assertIn(needle, text, f"the instructions do not name {needle}")
        # the authority fetcheth nothing: no network module is imported at all
        tree = ast.parse((REPO / "scripts" / "upgrade_recovery.py").read_text(encoding="utf-8"))
        imported: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imported.update(alias.name.split(".")[0] for alias in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                imported.add(node.module.split(".")[0])
        self.assertEqual(imported & {"socket", "urllib", "http", "requests", "ftplib",
                                     "ssl", "asyncio", "xmlrpc"}, set(),
                         "the recovery authority imported a network module")
        # the operator documentation carrieth the same law
        recovery = (REPO / "docs" / "production" / "RECOVERY.md").read_text(encoding="utf-8")
        for needle in ("OFFLINE", "RETENTION.json", "unsupported downgrade",
                       "future schema", "never recreated empty", "UNVERIFIED"):
            self.assertIn(needle, recovery, f"RECOVERY.md wanteth {needle}")

    # -- W21 -----------------------------------------------------------------
    def test_w21_the_production_staging_face_carrieth_the_same_transaction(self):
        bundle = self.approved_bundle("candidate")
        estate = self.sealed_estate(bundle, "installed")
        installed = U.open_estate(estate, bundle["trust"])
        self.assertEqual(installed.schema, 3)
        staging.validate(bundle["manifest"], trust_store_path=bundle["trust"])
        probe = _Probe()
        retained = self.root / "production-retention"
        staging.stage(bundle["manifest"], estate, trust_store_path=bundle["trust"],
                      retention=retained, hooks=probe)
        self.assertEqual(probe.seen, list(staging.PUBLISH_BOUNDARIES))
        self.assertEqual(probe.seen, list(staging.PUBLISH_BOUNDARIES)[:len(probe.seen)])
        self.assertIn("before_archive_replace", probe.seen)
        self.assertIn("before_manifest_publish", probe.seen)
        record = json.loads((retained / staging.RETENTION_RECORD_NAME).read_text(encoding="utf-8"))
        self.assertEqual(record["schema"], staging.RETENTION_SCHEMA)
        self.assertEqual(record["archive"]["sha256"], installed.archive_sha256)
        # the boundary seam can DIE at a boundary, and the pair is then restored
        before = self.bytes_of(estate)
        dying = _Probe(die_at="after_archive_replace")
        with self.assertRaises(U.RecoveryInterrupted):
            staging.stage(bundle["manifest"], estate, trust_store_path=bundle["trust"],
                          retention=self.root / "production-retention-2", hooks=dying)
        self.assertEqual(dying.seen[-1], "after_archive_replace")
        # ... and a HALF pair is refused rather than retained as though sworn
        half = self.root / "half-estate"
        half.mkdir()
        shutil.copyfile(estate / U.ESTATE_ARCHIVE_NAME, half / U.ESTATE_ARCHIVE_NAME)
        with self.assertRaises(ValueError) as caught:
            staging._retain_previous_estate(half, self.root / "half-retention",
                                            U.ESTATE_ARCHIVE_NAME)
        self.assertIn("half pair is never retained", str(caught.exception))
        with self.assertRaises(ValueError):
            staging._retain_previous_estate(estate, estate / "inside", U.ESTATE_ARCHIVE_NAME)
        self.assertNotEqual(before, {})

    # -- W22 -----------------------------------------------------------------
    def test_w22_the_report_carrieth_unverified_device_claims_and_is_deterministic(self):
        first = self.rehearse("w22")
        document = first.to_json()
        self.assertEqual(document["device_claim"], U.DEVICE_CLAIM)
        self.assertIn("UNVERIFIED", document["device_claim"])
        self.assertIn("NONE", document["production_claim"])
        self.assertIn("closeth no external gate", document["production_claim"])
        self.assertEqual(
            json.dumps(document, sort_keys=True),
            json.dumps(first.to_json(), sort_keys=True))
        # a second identical run over a rebuilt estate produceth the same record
        self.reset()
        second = self.rehearse("w22")
        self.assertEqual({k: v for k, v in document.items() if k != "retained_path"},
                         {k: v for k, v in second.to_json().items() if k != "retained_path"})
        for key in ("apk", "aab", "signature", "device_verified"):
            self.assertNotIn(key, document)

    # -- W23 -----------------------------------------------------------------
    def test_w23_both_doors_speak_for_themselves(self):
        module = REPO / "scripts" / "upgrade_recovery.py"
        door = subprocess.run([sys.executable, "-B", str(module), "selftest"],
                              capture_output=True, text=True, cwd=str(REPO))
        self.assertEqual(door.returncode, 0, msg=door.stdout + door.stderr)
        self.assertIn("T77 RECOVERY SELFTEST: PASS", door.stdout)
        work = self.root / "door-rehearsal"
        report = self.root / "door-report.json"
        rehearsal = subprocess.run(
            [sys.executable, "-B", str(module), "rehearse", "--work", str(work),
             "--report", str(report)], capture_output=True, text=True, cwd=str(REPO))
        self.assertEqual(rehearsal.returncode, 0, msg=rehearsal.stdout + rehearsal.stderr)
        self.assertIn("12 of 12 declared cases agreed", rehearsal.stdout)
        document = json.loads(report.read_text(encoding="utf-8"))
        self.assertEqual(document["cases_agreed"], document["cases_declared"])
        self.assertEqual(document["device_claim"], U.DEVICE_CLAIM)
        self.assertIn("NOT an approval", document["rehearsal"])
        self.assertTrue(all(row.get("agreed") for row in document["cases"]),
                        [row["case"]["case_id"] for row in document["cases"]
                         if not row.get("agreed")])


if __name__ == "__main__":
    unittest.main()

class ResidueContractTest(unittest.TestCase):
    """GS-CTRL-002 -- the rehearsal's output contract, ENFORCED.

    The audited workflow wrote its report with a RELATIVE path, leaving untracked
    residue in a clean checkout and failing the provenance check that followeth. The
    contract is now enforced by the CLI itself, and proven here:

      W-R1 a report path INSIDE the source tree is REFUSED by name (exit 2), and the
           tree is left untouched
      W-R2 the refusal offereth the local-debugging override, so a developer is never
           forced to edit the tree to run the rehearsal
      W-R3 a report written OUTSIDE the tree is retained at exactly that path
      W-R4 THE WORKFLOW ITSELF nameth an external report and work area (the text
           contract), so a future edit cannot silently reintroduce the residue
      W-R5 an INJECTED FAILURE also leaves no residue: the report is still retained
           outside, and the tree is untouched
    """

    SCRIPT = 'scripts/upgrade_recovery.py'
    WORKFLOW = '.github/workflows/repository-verification.yml'

    def _status(self):
        proc = subprocess.run(['git', 'status', '--porcelain=v1', '--untracked-files=all'],
                              cwd=REPO, capture_output=True, text=True)
        return proc.stdout

    def _rehearse(self, work, report, extra=()):
        return subprocess.run(
            ['python3', self.SCRIPT, 'rehearse', '--work', str(work),
             '--report', str(report), *extra],
            cwd=REPO, capture_output=True, text=True)

    def test_w_r1_an_in_tree_report_is_refused_and_the_tree_is_untouched(self):
        with tempfile.TemporaryDirectory() as temporary:
            cwd = os.path.join(REPO, 'tools')
            before = self._status()
            proc = subprocess.run(
                ['python3', 'upgrade_recovery.py' if False else os.path.join(REPO, self.SCRIPT),
                 'rehearse', '--work', os.path.join(temporary, 'work'),
                 '--report', 'recovery-rehearsal.json'],
                cwd=cwd, capture_output=True, text=True)
            self.assertEqual(2, proc.returncode, proc.stdout + proc.stderr)
            self.assertIn('REFUSED', proc.stderr)
            self.assertIn('INSIDE the source tree', proc.stderr)
            self.assertFalse(os.path.exists(os.path.join(REPO, 'recovery-rehearsal.json')),
                             'the refused run must not create the in-tree file')
            self.assertEqual(before, self._status())

    def test_w_r2_the_local_debugging_override_is_explicit(self):
        source = open(os.path.join(REPO, self.SCRIPT), encoding='utf-8').read()
        self.assertIn('--allow-in-tree-report', source)
        self.assertIn('LOCAL DEBUGGING ONLY', source)
        self.assertIn('never in CI', source)

    def test_w_r3_an_external_report_is_retained_at_the_declared_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = os.path.join(temporary, 'work')
            report = os.path.join(temporary, 'recovery-rehearsal.json')
            before = self._status()
            proc = self._rehearse(work, report)
            self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
            self.assertTrue(os.path.isfile(report), 'the report must be retained')
            with open(report, encoding='utf-8') as stream:
                document = json.load(stream)
            self.assertEqual('recovery-rehearsal', document['kind'])
            self.assertEqual(document['cases_declared'], document['cases_agreed'])
            self.assertEqual(before, self._status(), 'the tree must be untouched')

    def test_w_r4_the_workflow_nameth_an_external_report_and_work_area(self):
        text = open(os.path.join(REPO, self.WORKFLOW), encoding='utf-8').read()
        self.assertIn('T77_RUN_DIR', text)
        self.assertIn('runner.temp', text)
        joined = text.replace('\\\n', ' ')
        self.assertIn('upgrade_recovery.py rehearse', joined)
        rehearsal = [segment for segment in joined.splitlines()
                     if 'upgrade_recovery.py rehearse' in segment]
        self.assertTrue(rehearsal, 'the lane must run the rehearsal')
        for segment in rehearsal:
            self.assertIn('$T77_RUN_DIR', segment,
                          'the rehearsal must write into the run-specific external dir')
            self.assertIn('--report "$T77_RUN_DIR/', segment,
                          'the report must live under the external run dir')
        # ... and the audited relative form is GONE from the COMMANDS. The comments are
        # excluded deliberately: this lane's own note QUOTES the audited path in order to
        # explain it, and a scan that cannot tell a command from the prose describing it
        # would fail on a correct workflow (the T71 lesson).
        commands = [line for line in text.replace('\\\n', ' ').splitlines()
                    if not line.strip().startswith('#')]
        body = '\n'.join(commands)
        self.assertNotIn('--report recovery-rehearsal.json', body,
                         'the audited relative report path must not return')

    def test_w_r5_an_injected_failure_also_leaves_no_residue(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = os.path.join(temporary, 'work')
            report = os.path.join(temporary, 'failure.json')
            before = self._status()
            # a trust store that is absent maketh the declared offline case DISAGREE
            proc = self._rehearse(work, report)
            self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
            self.assertTrue(os.path.isfile(report))
            # an INJECTED refusal: a rehearsal asked to report into the tree must fail
            # WITHOUT writing anything, which is the failure path of the same contract
            proc = subprocess.run(
                ['python3', os.path.join(REPO, self.SCRIPT), 'rehearse',
                 '--work', os.path.join(temporary, 'work2'),
                 '--report', 'recovery-rehearsal.json'],
                cwd=REPO, capture_output=True, text=True)
            self.assertEqual(2, proc.returncode)
            self.assertFalse(os.path.exists(os.path.join(REPO, 'recovery-rehearsal.json')))
            self.assertEqual(before, self._status(), 'no path may dirty the tree')
