#! /usr/bin/env python3
"""T46 readiness court: Bind content approval and manifest trust to final bytes.

The card's named defects, one witness each where the law speaketh:
  W1  one-word chunk change breaks the binding .................. the bytes
      that ship are no longer the bytes that were approved.
  W2  changed warning breaks the binding .................. the declaration
      moved; the harvest moved; the seal concludeth otherwise.
  W3  missing coverage .......................... wanting, unknown, foreign
  W4  expired rights ............ the clock is injected, never wall-watched
  W5  self-signed malicious bundle ......... the bundle nominates nothing;
      trust is configured independently or not at all
  W6  wrong tier/count/schema ...... manifest truths at the verifier's eye
  W7  path traversal ...... even a normpath does not make a rogue honest
  W8  duplicate manifest entries ...... the collapsing reader is a gap
  W9  the signed manifest is deterministic over the exact bytes
  W10 the whole route, with out-of-band reviewer trust
  W11 NONEMPTY IS NOT APPROVED -- the transplant of seals proveth it

Fixtures are harmless app-navigation prose with obvious FIXTURE markers;
the reviewer keys are TEST-ONLY fabrications generated in the court's own
temporary world (release_gate's documented test aids). No clinical
approval is proven; readiness stays false; no external gate is closed.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
import tempfile
import unittest
from dataclasses import replace as dc_replace
from datetime import date, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(REPO) not in sys.path:
    sys.path.insert(0, str(REPO))

import yaml  # noqa: E402
from cryptography.hazmat.primitives.asymmetric.ed25519 import (  # noqa: E402
    Ed25519PrivateKey)

from content import release_gate as rg  # noqa: E402
from content.archive_manifest import (  # noqa: E402
    create_manifest, generate_test_keypair, load_private_key,
    load_trust_store, verify_manifest)
from content.ingest import build_archive as ba  # noqa: E402
from content.release_gate import (  # noqa: E402
    ReleaseGateError, TrustPolicyError, TrustedReviewerKeySet,
    assert_independent_store, chunk_final_hashes, make_test_keyset_entry,
    set_digest, sign_final_approval_fields, verify_chunk_approvals,
    warning_sets_for, write_approvals_bundle, write_test_keyset)

DB_DIR = REPO / "content" / "db"
TODAY = date(2026, 8, 6)
REVIEWER = "Dr. T46 Fixture Reviewer"

BODY_A = """# FIXTURE power
Press and hold the power key beside the volume rocker for two seconds
until the banner appears; release. This passage is harmless app-navigation
text marked FIXTURE, never a medical instruction (blueprint s16).

# Warnings
Do not loosen the seal while the device is warm.

# Contraindications
Never submerge the charging contacts below water.
"""

BODY_B = """# FIXTURE scroll
Swipe down with one finger; the list scrolls. Swipe up to return to the
top. The status bar shows the battery and the clock.

# FIXTURE pairing
Open settings, choose the network entry, and the toggle turns blue when
the link is established.
"""


def _seed(root: Path, *, bodies: dict[str, str]) -> Path:
    seed = root / "seed"
    docs = seed / "docs"
    docs.mkdir(parents=True, exist_ok=True)
    (seed / "taxonomy.yaml").write_text(
        "domains:\n- id: navigation\n  label: Navigation\n",
        encoding="utf-8")
    for name, body in bodies.items():
        stem = name.split(".")[0]
        (docs / f"{stem}.md").write_text(
            "---\n"
            f"title: FIXTURE {stem}\n"
            "domain: navigation\n"
            f"source: T46-FIXTURE-{stem}\n"
            "licence: CC0-1.0\n"
            "revision: '1'\n"
            "tier_min: LIGHT\n"
            f"reviewed_by: {REVIEWER}\n"
            "reviewed_on: '2026-07-30'\n"
            "---\n"
            f"{body}\n", encoding="utf-8")
    return seed


def _media_manifest(seed: Path, entries: list[dict]) -> None:
    (seed / "media_manifest.yaml").write_text(
        yaml.safe_dump({"version": 3, "media": entries}, sort_keys=True),
        encoding="utf-8")


def _document_manifests(root: Path, seed: Path, today: date) -> tuple[Path, Path]:
    manifests = root / "manifests" / "documents"
    evidence = root / "manifests"
    manifests.mkdir(parents=True, exist_ok=True)
    for path in sorted((seed / "docs").rglob("*.md")):
        stem = path.name.split(".")[0]
        source_id = f"T46-FIXTURE-{stem}"
        (evidence / f"{stem}.rights.txt").write_text(
            "redistribution and derivatives permitted\n", encoding="utf-8")
        (evidence / f"{stem}.review.txt").write_text(
            "qualified reviewer approval\n", encoding="utf-8")
        (evidence / f"{stem}.chunks.txt").write_text(
            "all chunks reviewed with warnings attached\n", encoding="utf-8")
        record = {
            "schema": 1,
            "id": source_id,
            "status": "approved",
            "example": False,
            "source": {
                "title": f"FIXTURE {stem}", "publisher": "T46 Fixture Press",
                "edition": "1", "version": "2026.1",
                "source_date": "2026-01-10", "acquisition_date": "2026-02-01",
                "canonical_url": "https://fixture.invalid/" + stem,
                "source_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            },
            "rights": {
                "licence": "CC0-1.0", "attribution": "T46 fixture",
                "redistribution_permitted": True,
                "derivative_work_permitted": True,
                "evidence_file": f"{stem}.rights.txt",
                "evidence_sha256": hashlib.sha256(
                    (evidence / f"{stem}.rights.txt").read_bytes()).hexdigest(),
            },
            "review": {
                "reviewer_id": "t46-reviewer",
                "reviewer_role": "licensed clinician (fixture)",
                "reviewer_qualifications": "fixture qualification 0",
                "reviewer_identity_evidence": "fixture-identity-0",
                "reviewed_on": str(today - timedelta(days=7)),
                "review_scope":
                    "source transformation and every retrievable chunk",
                "expires_on": str(today + timedelta(days=200)),
                "approval_evidence_file": f"{stem}.review.txt",
                "approval_evidence_sha256": hashlib.sha256(
                    (evidence / f"{stem}.review.txt").read_bytes()).hexdigest(),
                "approval_signature": "fixture-signature-0",
            },
            "safety": {
                "warnings_required": True,
                "warning_sections": ["Warnings"],
                "contraindications_required": True,
                "contraindication_sections": ["Contraindications"],
                "chunk_boundary_approved": True,
                "chunk_approval_evidence_file": f"{stem}.chunks.txt",
                "chunk_approval_evidence_sha256": hashlib.sha256(
                    (evidence / f"{stem}.chunks.txt").read_bytes()).hexdigest(),
                "jurisdiction": "global general guidance (fixture)",
                "replacement_policy":
                    "replace on source revision or review expiry",
            },
        }
        (manifests / f"{source_id}.yaml").write_text(
            yaml.safe_dump(record, sort_keys=True), encoding="utf-8")
    (evidence / "README-do-not.txt").write_text(
        "reviewer credential evidence\n", encoding="utf-8")
    return manifests, evidence


class ApprovalCourtCase(unittest.TestCase):
    """The common world: seed, manifests, out-of-band keyset, signed
    bundles for both documents, built once by the control witness."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.out = self.root / "dist" / "archive_light.db"
        self.seed = _seed(self.root, bodies={"a": BODY_A, "b": BODY_B})
        _media_manifest(self.seed, [
            {"kind": "diagram", "source": "T46-FIXTURE-a",
             "path": "media/diagrams/panel.png", "caption": "The panel",
             "bytes": 8, "sha256": "a" * 64},
        ])
        self.manifests, self.evidence = _document_manifests(
            self.root, self.seed, TODAY)
        self.trust_home = self.root / "trust"          # OUT of the bundle
        self.approvals = self.root / "approvals"
        self.approvals.mkdir()
        self.reviewer_key = Ed25519PrivateKey.generate()
        write_test_keyset(self.trust_home / "reviewer_keys.json", [
            make_test_keyset_entry(
                self.reviewer_key, key_id="RV-1", reviewer_id=REVIEWER,
                valid_from=date(2026, 1, 1), valid_until=date(2027, 6, 1))])
        self.keyset = TrustedReviewerKeySet.load(
            self.trust_home / "reviewer_keys.json")
        self._credential_sha = None

    def tearDown(self) -> None:
        self._tmp.cleanup()

    # -- the maker's art: recompute the digests and re-sign the bundles --
    def harvest(self, stem: str, *, body: str | None = None,
                warning_sections: list[str] | None = None,
                contraindication_sections: list[str] | None = None):
        source = self.seed / "docs" / f"{stem}.md"
        text = source.read_text(encoding="utf-8") if body is None else body
        front, _, prose = text.split("---", 2)
        cfg = ba.TIERS["LIGHT"]
        chunks = list(ba.chunk_document(
            prose, max_tokens=cfg["chunk_tokens"],
            overlap_tokens=cfg["chunk_overlap"]))
        for ordinal, ch in enumerate(chunks, start=1):
            ch.chunk_id = ordinal
            ch.document_id = 1
        warnings, contras = warning_sets_for(
            chunks,
            warning_sections=(["Warnings"] if warning_sections is None
                              else warning_sections),
            contraindication_sections=(["Contraindications"]
                                       if contraindication_sections is None
                                       else contraindication_sections))
        hashes = chunk_final_hashes(
            source_id=f"T46-FIXTURE-{stem}",
            document_sha256=hashlib.sha256(
                (body.encode("utf-8") if body is not None
                 else source.read_bytes())).hexdigest()
            if body is not None
            else hashlib.sha256(source.read_bytes()).hexdigest(),
            chunks=chunks, warnings=warnings, contraindications=contras)
        return chunks, hashes, warnings, contras

    def rights_sha(self, stem: str) -> str:
        return hashlib.sha256(
            (self.evidence / f"{stem}.rights.txt").read_bytes()).hexdigest()

    def credential_sha(self) -> str:
        if self._credential_sha is None:
            self._credential_sha = hashlib.sha256(
                (self.evidence / "README-do-not.txt").read_bytes()).hexdigest()
        return self._credential_sha

    def sign_bundle(self, stem: str, *, hashes=None, warnings=None,
                    contras=None, reviewer: str = REVIEWER, key_id: str = "RV-1",
                    key: Ed25519PrivateKey | None = None,
                    valid_from: date = date(2026, 7, 1),
                    valid_until: date = date(2026, 12, 31),
                    reviewed_on: date | None = None) -> None:
        if hashes is None:
            _, hashes, warnings, contras = self.harvest(stem)
        record = sign_final_approval_fields(
            key or self.reviewer_key, source_id=f"T46-FIXTURE-{stem}",
            document_sha256=hashlib.sha256(
                (self.seed / "docs" / f"{stem}.md").read_bytes()).hexdigest(),
            rights_sha256=self.rights_sha(stem),
            reviewer_id=reviewer,
            reviewer_credential_evidence_file="README-do-not.txt",
            reviewer_credential_sha256=self.credential_sha(),
            reviewed_on=TODAY if reviewed_on is None else reviewed_on,
            valid_from=valid_from, valid_until=valid_until,
            warnings_sha256=set_digest(warnings or []),
            contraindications_sha256=set_digest(contras or []),
            chunk_final_sha256=hashes, key_id=key_id)
        write_approvals_bundle(
            self.approvals / f"T46-FIXTURE-{stem}.approvals.json", [record])

    def sign_all(self) -> None:
        for stem in ("a", "b"):
            self.sign_bundle(stem)

    def build_with_leg(self, **kw):
        kw.setdefault("embed", False)
        kw.setdefault("today", TODAY)
        kw.setdefault("manifests_root", self.manifests)
        kw.setdefault("evidence_root", self.evidence)
        kw.setdefault("seed_root", self.seed)
        kw.setdefault("db_dir", DB_DIR)
        return ba.build("LIGHT", self.out, embed=kw["embed"], release=True,
                        seed_root=kw["seed_root"], db_dir=kw["db_dir"],
                        manifests_root=kw["manifests_root"],
                        evidence_root=kw["evidence_root"], today=kw["today"],
                        approvals_dir=self.approvals,
                        reviewer_keyset=self.trust_home / "reviewer_keys.json",
                        **{k: v for k, v in kw.items() if k not in
                           ("embed", "today", "manifests_root", "evidence_root",
                            "seed_root", "db_dir")})

    def sentinel(self) -> None:
        self.out.parent.mkdir(parents=True, exist_ok=True)
        self.out.write_bytes(b"SENTINEL-OLD-BYTES")

    def no_residue(self, where: Path) -> None:
        strays = sorted(p.name for p in where.parent.iterdir()
                       if ".tmp-" in p.name) if where.parent.exists() else []
        self.assertEqual(strays, [], "the refused build left a residue")

    def verify_one(self, stem: str, *, chunks=None, hashes_check=None,
                   today=TODAY, keyset=None, warnings=None, contras=None,
                   warning_sections=None, contraindication_sections=None,
                   document_sha256: str | None = None):
        got_chunks, hashes, warnings, contras = self.harvest(
            stem, warning_sections=warning_sections,
            contraindication_sections=contraindication_sections)
        return verify_chunk_approvals(
            source_id=f"T46-FIXTURE-{stem}",
            document_sha256=document_sha256 or hashlib.sha256(
                (self.seed / "docs" / f"{stem}.md").read_bytes()).hexdigest(),
            rights_sha256=self.rights_sha(stem),
            manifest_path=self.manifests / f"T46-FIXTURE-{stem}.yaml",
            evidence_root=self.evidence,
            chunks=chunks if chunks is not None else got_chunks,
            approvals_dir=self.approvals,
            keyset=keyset or self.keyset, today=today)


class W1ChangedWord(ApprovalCourtCase):
    def testChangedWordBreaksTheApproval(self) -> None:
        """One word, altered in the bytes that ship, unbinds the seal."""
        self.sign_all()
        control = self.build_with_leg()
        self.assertTrue(control.validation.ok)
        # tamper deep: one word in a non-warning section of source a
        path = self.seed / "docs" / "a.md"
        text = path.read_text(encoding="utf-8")
        self.assertIn("volume rocker", text)
        path.write_text(text.replace("volume rocker", "volume tiller"),
                        encoding="utf-8")
        # (ii) nothing re-approved: the rights gate refuseth first, for
        # the document manifest bindeth the source version too
        self.sentinel()
        with self.assertRaises(ba.ArchiveApprovalError) as caught:
            self.build_with_leg()
        self.assertRegex(str(caught.exception), "release content gate refused")
        self.assertRegex(str(caught.exception), "source_sha256 mismatch")
        self.assertEqual(self.out.read_bytes(), b"SENTINEL-OLD-BYTES")
        self.no_residue(self.out)
        # (iii) the manifest re-declared but the seal not re-cut: the
        # approval leg proveth the bytes are no longer the approved ones
        mpath = self.manifests / "T46-FIXTURE-a.yaml"
        record = yaml.safe_load(mpath.read_text(encoding="utf-8"))
        record["source"]["source_sha256"] = hashlib.sha256(
            path.read_bytes()).hexdigest()
        mpath.write_text(yaml.safe_dump(record, sort_keys=True),
                         encoding="utf-8")
        with self.assertRaises(ba.ArchiveApprovalError) as caught:
            self.build_with_leg()
        words = str(caught.exception)
        self.assertTrue("document digests do not match" in words
                        or "unapproved" in words, words)
        self.assertEqual(self.out.read_bytes(), b"SENTINEL-OLD-BYTES")
        self.no_residue(self.out)
        # the same bytes, re-approved aright, pass again: resign first
        chunks_a, _, warns, contras = self.harvest("a")
        self.sign_bundle("a", hashes=chunk_final_hashes(
            source_id="T46-FIXTURE-a",
            document_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            chunks=chunks_a, warnings=warns, contraindications=contras),
            warnings=warns, contras=contras)
        again = self.build_with_leg()
        self.assertTrue(again.validation.ok)
        self.assertNotEqual(self.out.read_bytes(), b"SENTINEL-OLD-BYTES",
                            "the re-approved build did not replace")


class W2ChangedWarning(ApprovalCourtCase):
    def testChangedWarningBreaksTheApproval(self) -> None:
        """Move a declaration, and the harvest follows; the seal proves
        the warning sets were bound at signing, not read at delivery."""
        self.sign_all()
        _, _, warnings, contras = self.harvest("a")
        self.assertTrue(any("loosen" in w for w in warnings))
        # the chunk bytes stand still; only the DECLARATION is moved:
        # the warning section is re-declared as a contraindication
        path = self.manifests / "T46-FIXTURE-a.yaml"
        record = yaml.safe_load(path.read_text(encoding="utf-8"))
        record["safety"]["warning_sections"] = []
        record["safety"]["contraindication_sections"] = [
            "Contraindications", "Warnings"]
        path.write_text(yaml.safe_dump(record, sort_keys=True),
                        encoding="utf-8")
        with self.assertRaises(ReleaseGateError) as caught:
            self.verify_one("a")
        words = str(caught.exception)
        self.assertRegex(words, "warning sets changed")
        self.assertRegex(words, "contraindication sets changed")
        # (the chunk hashes bind the sets too, so coverage crieth out
        # with them: the named set-faults are the proof of binding)


class W3Coverage(ApprovalCourtCase):
    def testMissingCoverageIsRefused(self) -> None:
        """Wanting, unknown, foreign: coverage is proved both ways."""
        self.sign_all()
        # (a) wanting: the bundle is gone
        (self.approvals / "T46-FIXTURE-a.approvals.json").unlink()
        self.sentinel()
        with self.assertRaises(ba.ArchiveApprovalError) as caught:
            self.build_with_leg()
        self.assertRegex(str(caught.exception), "no approvals bundle")
        self.assertEqual(self.out.read_bytes(), b"SENTINEL-OLD-BYTES")
        self.no_residue(self.out)
        # (b) half a claim: one chunk omitted from the record
        chunks, hashes, warns, contras = self.harvest("a")
        self.assertGreater(len(hashes), 1)
        self.sign_bundle("a", hashes=hashes[:-1], warnings=warns,
                         contras=contras)
        with self.assertRaises(ReleaseGateError) as caught:
            self.verify_one("a")
        self.assertRegex(str(caught.exception),
                         r"\b1 chunk\(s\) are unapproved")
        # (c) a foreign claim: a digest no chunk of this corpus holds
        foreign = hashlib.sha256(b"not of this corpus").hexdigest()
        self.sign_bundle("a", hashes=[*hashes, foreign], warnings=warns,
                         contras=contras)
        with self.assertRaises(ReleaseGateError) as caught:
            self.verify_one("a")
        words = str(caught.exception)
        self.assertRegex(words, "not in this corpus")
        # (d) a chunk claimed twice is a double bargain refused
        record_a = json.loads((self.approvals / "T46-FIXTURE-a.approvals.json"
                              ).read_text(encoding="utf-8"))
        copy_of_first = json.loads(json.dumps(record_a["approvals"][0]))
        copy_of_first["chunk_final_sha256"] = sorted(
            record_a["approvals"][0]["chunk_final_sha256"][:1])
        copy_of_first["chunk_count"] = 1
        record_a["approvals"].append(copy_of_first)
        body = {"schema": 1, "approvals": record_a["approvals"]}
        (self.approvals / "T46-FIXTURE-a.approvals.json").write_bytes(
            rg.canonical_json(body) + b"\n")
        with self.assertRaises(ReleaseGateError) as caught:
            self.verify_one("a")
        self.assertRegex(str(caught.exception),
                         "claimed by more than one approval")


class W4Expiry(ApprovalCourtCase):
    def testExpiryIsRefusedBothWays(self) -> None:
        """The clock is injected, never wall-watched: expired and
        not-yet-in-force are both named, for the key and the record."""
        self.sign_all()
        # (a) tomorrow's eye sees an expired approval
        with self.assertRaises(ReleaseGateError) as caught:
            self.verify_one("a", today=date(2027, 1, 2))
        self.assertRegex(str(caught.exception), "approval expired")
        # (b) yesterday's eye sees none in force
        with self.assertRaises(ReleaseGateError) as caught:
            self.verify_one("a", today=date(2026, 6, 30))
        self.assertRegex(str(caught.exception), "not in force")
        # (c) the key itself is out of its window though the record is fresh
        stale_home = self.root / "trust-stale"
        write_test_keyset(stale_home / "reviewer_keys.json", [
            make_test_keyset_entry(
                self.reviewer_key, key_id="RV-1", reviewer_id=REVIEWER,
                valid_from=date(2026, 1, 1), valid_until=date(2026, 8, 1))])
        with self.assertRaises(ReleaseGateError) as caught:
            self.verify_one("a", keyset=TrustedReviewerKeySet.load(
                stale_home / "reviewer_keys.json"))
        self.assertRegex(str(caught.exception), "out of force")
        # (d) a review date outside the window is a fifth wheel refused
        chunks, hashes, warns, contras = self.harvest("a")
        self.sign_bundle("a", hashes=hashes, warnings=warns, contras=contras,
                         reviewed_on=date(2026, 6, 1))   # before valid_from
        with self.assertRaises(ReleaseGateError) as caught:
            self.verify_one("a")
        self.assertRegex(str(caught.exception),
                         "review date doth not fall within")


class W5SelfSigned(ApprovalCourtCase):
    def testSelfSignedBundleIsRefused(self) -> None:
        """The bundle nominateth nothing: keys self-sealed from within
        are refused, whoever signs."""
        # (a) signed by a key the operator never configured
        rogue = Ed25519PrivateKey.generate()
        chunks, hashes, warns, contras = self.harvest("a")
        self.sign_bundle("a", hashes=hashes, warnings=warns, contras=contras,
                         key=rogue, key_id="RV-BY-PAYLOAD")
        with self.assertRaises(ReleaseGateError) as caught:
            self.verify_one("a")
        self.assertRegex(str(caught.exception),
                         "not in the independently configured set")
        # (b) the very same key, adopted out of band, is admitted
        write_test_keyset(self.trust_home / "reviewer_keys.json", [
            make_test_keyset_entry(
                self.reviewer_key, key_id="RV-1", reviewer_id=REVIEWER,
                valid_from=date(2026, 1, 1), valid_until=date(2027, 6, 1)),
            make_test_keyset_entry(
                rogue, key_id="RV-BY-PAYLOAD", reviewer_id=REVIEWER,
                valid_from=date(2026, 1, 1), valid_until=date(2027, 6, 1))])
        self.keyset = TrustedReviewerKeySet.load(
            self.trust_home / "reviewer_keys.json")
        coverage = self.verify_one("a")
        self.assertEqual(coverage.chunk_approved, coverage.chunk_total)
        # (c) a trust store shipped inside the bundle is refused unread
        for label, forbidden in (("seed", self.seed),
                                 ("manifests", self.manifests.parent),
                                 ("approvals-home", self.approvals),
                                 ("destination", self.out.parent)):
            with self.subTest(root=label):
                forbidden.mkdir(parents=True, exist_ok=True)
                smuggled = forbidden / f"keys-{label}.json"
                shutil.copyfile(
                    self.trust_home / "reviewer_keys.json", smuggled)
                try:
                    with self.assertRaises(TrustPolicyError) as caught:
                        assert_independent_store(
                            smuggled, forbidden_roots=(forbidden,),
                            what=f"store under {label}")
                    self.assertRegex(str(caught.exception),
                                     "nominated from inside the bundle")
                finally:
                    smuggled.unlink()
        # (d) through the build the same fault is named, and the
        # destination standeth
        shutil.copyfile(self.trust_home / "reviewer_keys.json",
                        (inside := self.seed / "reviewer_keys.json"))
        self.sign_all()
        self.sentinel()
        with self.assertRaises(ba.ArchiveApprovalError) as caught:
            ba.build("LIGHT", self.out, embed=False, release=True,
                     seed_root=self.seed, db_dir=DB_DIR,
                     manifests_root=self.manifests,
                     evidence_root=self.evidence, today=TODAY,
                     approvals_dir=self.approvals,
                     reviewer_keyset=inside)
        self.assertRegex(str(caught.exception), "trust policy refused")
        self.assertEqual(self.out.read_bytes(), b"SENTINEL-OLD-BYTES")
        self.no_residue(self.out)
        inside.unlink()


class W6ManifestTruths(ApprovalCourtCase):
    def testWrongTierCountSchemaAreRefused(self) -> None:
        """The verifier's eye, thirded: tier, counts and schema all
        witness against the manifest, and are proved at the records."""
        self.sign_all()
        result = self.build_with_leg()
        self.assertTrue(result.validation.ok)
        keys = self.root / "signing"
        keys.mkdir()
        generate_test_keypair(keys / "signing.key", keys / "trust.json",
                             key_id="T46-RELEASE-KEY")
        oracle = rg.validate_release_corpus(
            ba.load_corpus("LIGHT", seed_root=self.seed), self.manifests,
            evidence_root=self.evidence, today=TODAY)
        manifest_path = self.root / "signed" / "archive_light.json"
        manifest_path.parent.mkdir()
        create_manifest(
            self.out, manifest_path, tier="LIGHT", archive_schema=3,
            source_manifest_sha256=oracle.source_set_sha256,
            review_manifest_sha256=oracle.review_set_sha256,
            corpus_manifest_sha256=oracle.manifest_set_sha256,
            build_tool_commit="t46-fixture-commit",
            private_key=load_private_key(keys / "signing.key"),
            key_id="T46-RELEASE-KEY")
        trust = load_trust_store(keys / "trust.json")
        ok = verify_manifest(manifest_path, self.out, trust,
                            expected_tier="LIGHT", expected_archive_schema=3)
        self.assertTrue(ok.ok, str(ok.errors))
        # wrong tier
        lie = verify_manifest(manifest_path, self.out, trust,
                             expected_tier="MEDIUM", expected_archive_schema=3)
        self.assertFalse(lie.ok)
        self.assertTrue(any("tier" in e for e in lie.errors), str(lie.errors))
        # wrong archive schema
        lie = verify_manifest(manifest_path, self.out, trust,
                             expected_tier="LIGHT", expected_archive_schema=2)
        self.assertFalse(lie.ok)
        self.assertTrue(any("incompatible" in e for e in lie.errors),
                        str(lie.errors))
        # doctored count: one more document than the database holds
        text = manifest_path.read_text(encoding="utf-8")
        import re as _re
        m = _re.search(r'"documents":([0-9]+)', text)
        self.assertIsNotNone(m, "the canonical text carrieth no count")
        doctored = (text[: m.start(1)] + str(int(m.group(1)) + 1)
                    + text[m.end(1):])
        tampered = self.root / "signed" / "doctored.json"
        tampered.write_text(doctored, encoding="utf-8")
        lie = verify_manifest(tampered, self.out, trust,
                             expected_tier="LIGHT", expected_archive_schema=3)
        self.assertFalse(lie.ok)
        self.assertTrue(any("documents count mismatch" in e for e in lie.errors),
                        str(lie.errors))
        # schema of the approval records: future-proofed at both stages
        bundle = self.approvals / "T46-FIXTURE-a.approvals.json"
        keep = bundle.read_bytes()
        try:
            # the record level (first occurrence)
            bundle.write_text(keep.decode("utf-8").replace(
                '"schema":1', '"schema":2', 1), encoding="utf-8")
            with self.assertRaises(ReleaseGateError) as caught:
                rg.load_final_chunk_approvals(self.approvals,
                                             "T46-FIXTURE-a")
            self.assertRegex(str(caught.exception), r"schema must be 1")
        finally:
            bundle.write_bytes(keep)
        try:
            text = keep.decode("utf-8")
            cut = text.rfind('"schema":1')
            self.assertNotEqual(cut, -1)
            bundle.write_text(text[:cut] + '"schema":9' +
                             text[cut + len('"schema":1'):], encoding="utf-8")
            with self.assertRaises(ReleaseGateError) as caught:
                rg.load_final_chunk_approvals(self.approvals, "T46-FIXTURE-a")
            self.assertRegex(str(caught.exception),
                             "unsupported future approvals schema 9")
        finally:
            bundle.write_bytes(keep)


class W7Traversal(ApprovalCourtCase):
    def testPathTraversalIsRefused(self) -> None:
        """Even a normpath does not make a rogue honest: the media warden
        refuseth at the gate, before any row is made."""
        self.sign_all()
        good = self.build_with_leg()
        self.assertTrue(good.validation.ok)
        before = self.out.read_bytes()
        rogues = ["../escape", "/abs/thing", "nul\0inside", r"win\dows",
                 "a//b", "./a/b", "media/../../outside", "~home/x",
                 "d:media/x.svg"]
        for rogue in rogues:
            with self.subTest(path=repr(rogue)):
                _media_manifest(self.seed, [
                    {"kind": "diagram", "source": "T46-FIXTURE-a",
                     "path": rogue, "caption": "rogue", "bytes": 3,
                     "sha256": "b" * 64}])
                with self.assertRaises(ba.ArchiveUnsafeContentError) as caught:
                    self.build_with_leg()
                self.assertRegex(str(caught.exception), "media path refused")
                self.assertEqual(self.out.read_bytes(), before,
                                 "the sentinel moved under a rogue path")
                self.no_residue(self.out)
        # duplicated paths are refused by the same warden
        _media_manifest(self.seed, [
            {"kind": "diagram", "source": "T46-FIXTURE-a",
             "path": "media/diagrams/panel.png", "caption": "one",
             "bytes": 8, "sha256": "a" * 64},
            {"kind": "diagram", "source": "T46-FIXTURE-b",
             "path": "media/diagrams/panel.png", "caption": "two",
             "bytes": 8, "sha256": "c" * 64},
        ])
        with self.assertRaises(ba.ArchiveUnsafeContentError) as caught:
            self.build_with_leg()
        self.assertRegex(str(caught.exception), "duplicate media path")
        # the clean form passes
        _media_manifest(self.seed, [
            {"kind": "diagram", "source": "T46-FIXTURE-a",
             "path": "media/diagrams/panel.png", "caption": "one",
             "bytes": 8, "sha256": "a" * 64},
            {"kind": "diagram", "source": "T46-FIXTURE-b",
             "path": "media/diagrams/other.png", "caption": "two",
             "bytes": 8, "sha256": "c" * 64},
        ])
        again = self.build_with_leg()
        self.assertTrue(again.validation.ok)


class W8Duplicates(ApprovalCourtCase):
    def testDuplicateManifestEntriesAreRefused(self) -> None:
        """The collapsing reader is a smuggling gap: duplicates are
        refused at the asset face, the archive face and the YAML face."""
        from scripts import prepare_release_assets as prep
        self.sign_all()
        good = self.build_with_leg()
        self.assertTrue(good.validation.ok)
        root2 = self.root / "payload"
        root2.mkdir()
        shutil.copyfile(self.out, root2 / "archive_light.db")
        (root2 / "generation.gguf").write_bytes(b"G" * 32)
        (root2 / "embedding.gguf").write_bytes(b"E" * 24)

        def digest_of(name: str) -> dict:
            p = root2 / name
            return {"bytes": p.stat().st_size,
                    "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}

        keys = self.root / "signing"
        keys.mkdir(exist_ok=True)
        generate_test_keypair(keys / "signing.key", keys / "trust.json",
                             key_id="T46-RELEASE-KEY")
        oracle = rg.validate_release_corpus(
            ba.load_corpus("LIGHT", seed_root=self.seed), self.manifests,
            evidence_root=self.evidence, today=TODAY)
        signed = self.root / "signed"
        signed.mkdir(exist_ok=True)
        manifest_path = signed / "archive_light.json"
        create_manifest(
            root2 / "archive_light.db", manifest_path, tier="LIGHT",
            archive_schema=3,
            source_manifest_sha256=oracle.source_set_sha256,
            review_manifest_sha256=oracle.review_set_sha256,
            corpus_manifest_sha256=oracle.manifest_set_sha256,
            build_tool_commit="t46-fixture-commit",
            private_key=load_private_key(keys / "signing.key"),
            key_id="T46-RELEASE-KEY")
        asset_doc = {
            "schema": 1, "tier": "LIGHT", "application_id": "io.godstone.app",
            "status": "approved", "production_ready": True,
            "archive_manifest": "signed/archive_light.json",
            "archive_trust_store": "signing/trust.json",
            "assets": [
                {"role": "archive", "name": "archive_light.db",
                 "source": "payload/archive_light.db",
                 **digest_of("archive_light.db")},
                {"role": "generation_model", "name": "generation.gguf",
                 "source": "payload/generation.gguf",
                 **digest_of("generation.gguf")},
                {"role": "embedding_model", "name": "embedding.gguf",
                 "source": "payload/embedding.gguf",
                 **digest_of("embedding.gguf")},
            ],
        }
        doc = root2.parent / "release.json"
        doc.write_bytes(rg.canonical_json(asset_doc) + b"\n")
        data, staged = prep.validate(doc)
        self.assertEqual(len(staged), 3, "the clean manifest stageth not")
        # (a) duplicate role / name / source at the asset face
        for fault, mutate in (
            ("duplicate asset", lambda d: d["assets"].append(
                json.loads(json.dumps(d["assets"][1])))),
        ):
            with self.subTest(fault=fault):
                clone = json.loads(json.dumps(asset_doc))
                mutate(clone)
                probe = root2.parent / f"probe-{abs(hash(fault))}.json"
                probe.write_bytes(rg.canonical_json(clone) + b"\n")
                try:
                    with self.assertRaises(ValueError) as caught:
                        prep.validate(probe)
                    for phrase in ("duplicate asset role",
                                   "duplicate asset name",
                                   "duplicate asset source"):
                        self.assertRegex(str(caught.exception), phrase)
                finally:
                    probe.unlink()
        # (b) duplicate JSON keys, top and deep, are refused unread
        text = doc.read_text(encoding="utf-8")
        smuggled = text.replace('"schema":1', '"schema":1,"schema":9', 1)
        self.assertNotEqual(smuggled, text)
        top = root2.parent / "smuggled-top.json"
        top.write_text(smuggled, encoding="utf-8")
        with self.assertRaises(ValueError) as caught:
            prep.validate(top)
        self.assertRegex(str(caught.exception), "duplicate key")
        # craft a true duplicate of 'bytes' inside the first asset
        first = text.index('{', text.index('"assets"'))
        insert_at = text.index('"bytes":', first)
        colon = text.index(":", insert_at)
        comma_at = min(x for x in (text.find(",", colon),
                                   text.find("}", colon)) if x != -1)
        value = text[colon + 1:comma_at].strip()
        deep = (text[:comma_at] + ',"bytes":' + value + text[comma_at:])
        self.assertEqual(deep.count('"bytes":'), text.count('"bytes":') + 1)
        bottom = root2.parent / "smuggled-deep.json"
        bottom.write_text(deep, encoding="utf-8")
        with self.assertRaises(ValueError) as caught:
            prep.validate(bottom)
        self.assertRegex(str(caught.exception), "duplicate key")
        # (c) the archive manifest face refuseth the same smuggling
        mtext = manifest_path.read_text(encoding="utf-8")
        at = mtext.index('"tier":"LIGHT"')
        dupe = mtext[: at + len('"tier":"LIGHT"')] + \
            ',' + '"tier":"LIGHT"' + mtext[at + len('"tier":"LIGHT"'):]
        fake = signed / "dupe.json"
        fake.write_text(dupe, encoding="utf-8")
        verdict = verify_manifest(
            fake, root2 / "archive_light.db",
            load_trust_store(keys / "trust.json"),
            expected_tier="LIGHT", expected_archive_schema=3)
        self.assertFalse(verdict.ok)
        self.assertTrue(any("duplicate key" in e for e in verdict.errors),
                        str(verdict.errors))
        # (d) the YAML face likewise: a duplicated document key
        ypath = self.manifests / "T46-FIXTURE-b.yaml"
        ytext = ypath.read_text(encoding="utf-8")
        self.assertTrue(ytext.startswith("example: false") or
                        "example:" in ytext)
        smuggled_yaml = ytext + "\nstatus: approved\n"
        ypath.write_text(smuggled_yaml, encoding="utf-8")
        try:
            with self.assertRaises(ReleaseGateError) as caught:
                rg.validate_document_manifest(
                    ypath, self.seed / "docs" / "b.md",
                    evidence_root=self.evidence, today=TODAY)
            self.assertRegex(str(caught.exception), "duplicate YAML key")
        finally:
            ypath.write_text(ytext, encoding="utf-8")
        # and the honest documents yet again give proof
        data, staged = prep.validate(doc)
        self.assertEqual(len(staged), 3)


class W9Determinism(ApprovalCourtCase):
    def testManifestIsDeterministicOverExactBytes(self) -> None:
        """Twice created, one face: the manifest speaketh of the exact
        bytes and no otherwise."""
        self.sign_all()
        result = self.build_with_leg()
        keys = self.root / "signing"
        keys.mkdir()
        generate_test_keypair(keys / "signing.key", keys / "trust.json",
                             key_id="T46-RELEASE-KEY")
        oracle = rg.validate_release_corpus(
            ba.load_corpus("LIGHT", seed_root=self.seed), self.manifests,
            evidence_root=self.evidence, today=TODAY)
        signed = self.root / "signed"
        signed.mkdir()
        first = signed / "a.json"
        second = signed / "b.json"
        private = load_private_key(keys / "signing.key")
        create_manifest(self.out, first, tier="LIGHT", archive_schema=3,
                       source_manifest_sha256=oracle.source_set_sha256,
                       review_manifest_sha256=oracle.review_set_sha256,
                       corpus_manifest_sha256=oracle.manifest_set_sha256,
                       build_tool_commit="t46-fixture-commit",
                       private_key=private, key_id="T46-RELEASE-KEY")
        create_manifest(self.out, second, tier="LIGHT", archive_schema=3,
                       source_manifest_sha256=oracle.source_set_sha256,
                       review_manifest_sha256=oracle.review_set_sha256,
                       corpus_manifest_sha256=oracle.manifest_set_sha256,
                       build_tool_commit="t46-fixture-commit",
                       private_key=private, key_id="T46-RELEASE-KEY")
        self.assertEqual(first.read_bytes(), second.read_bytes(),
                         "twice created, not one face")
        document = json.loads(first.read_text(encoding="utf-8"))
        self.assertEqual(
            document["archive_sha256"],
            hashlib.sha256(self.out.read_bytes()).hexdigest(),
            "the manifest doth not speak of the exact bytes")
        self.assertEqual(document["archive_bytes"], self.out.stat().st_size)
        # and the approvals proof rides in the meta rows, told true by
        # an independent recompute
        conn = ba.sqlite3.connect(
            f"file:{self.out}?mode=ro&immutable=1", uri=True)
        try:
            meta = {str(k): str(v) for k, v in conn.execute(
                "SELECT key, value FROM archive_meta")}
        finally:
            conn.close()
        per_source = [
            hashlib.sha256(b"".join(sorted(
                r.preimage() for r in rg.load_final_chunk_approvals(
                    self.approvals, f"T46-FIXTURE-{stem}")))).hexdigest()
            for stem in ("a", "b")]
        self.assertEqual(meta["approvals_sha256"],
                        set_digest(per_source))
        self.assertEqual(int(meta["approvals_covered"]),
                        int(meta["chunk_count"]))
        # one byte flipped and the verifier crieth out the lie
        forged = self.root / "dist" / "forged.db"
        forged.write_bytes(self.out.read_bytes()[:-1] +
                           bytes([self.out.read_bytes()[-1] ^ 0x01]))
        verdict = verify_manifest(
            first, forged, load_trust_store(keys / "trust.json"),
            expected_tier="LIGHT", expected_archive_schema=3)
        self.assertFalse(verdict.ok)
        self.assertTrue(any("SHA-256 mismatch" in e for e in verdict.errors),
                        str(verdict.errors))


class W10WholeRoute(ApprovalCourtCase):
    def testWholeRouteWithIndependentReviewerTrust(self) -> None:
        """Licensed source to final chunks to approval verification to
        immutable DB to signed manifest to staging -- the whole call
        path with the approval limb engaged, and its absence felt."""
        self.sign_all()
        result = self.build_with_leg()
        self.assertTrue(result.validation.ok)
        self.assertEqual(result.document_count, 2)
        conn = ba.sqlite3.connect(f"file:{result.destination}?mode=ro&immutable=1",
                                 uri=True)
        try:
            meta = {str(k): str(v) for k, v in conn.execute(
                "SELECT key, value FROM archive_meta")}
        finally:
            conn.close()
        self.assertIn("approvals_sha256", meta)
        self.assertEqual(int(meta["approvals_covered"]),
                        int(meta["chunk_count"]))
        keys = self.root / "signing"
        keys.mkdir()
        generate_test_keypair(keys / "signing.key", keys / "trust.json",
                             key_id="T46-RELEASE-KEY")
        oracle = rg.validate_release_corpus(
            ba.load_corpus("LIGHT", seed_root=self.seed), self.manifests,
            evidence_root=self.evidence, today=TODAY)
        signed = self.root / "signed"
        signed.mkdir()
        manifest_path = signed / "archive_light.json"
        created = create_manifest(
            result.destination, manifest_path, tier="LIGHT", archive_schema=3,
            source_manifest_sha256=oracle.source_set_sha256,
            review_manifest_sha256=oracle.review_set_sha256,
            corpus_manifest_sha256=oracle.manifest_set_sha256,
            build_tool_commit="t46-fixture-commit",
            private_key=load_private_key(keys / "signing.key"),
            key_id="T46-RELEASE-KEY")
        self.assertEqual(created["archive_sha256"], result.archive_sha256)
        verdict = verify_manifest(
            manifest_path, result.destination, load_trust_store(keys / "trust.json"),
            expected_tier="LIGHT", expected_archive_schema=3)
        self.assertTrue(verdict.ok, str(verdict.errors))
        # staging
        from scripts import prepare_release_assets as prep
        payload = self.root / "payload"
        payload.mkdir()
        shutil.copyfile(result.destination, payload / "archive_light.db")
        (payload / "generation.gguf").write_bytes(b"GGUF-GEN-BLOB\n" * 5)
        (payload / "embedding.gguf").write_bytes(b"GGUF-EMB-BLOB\n" * 3)

        def dig(name: str) -> dict:
            p = payload / name
            return {"bytes": p.stat().st_size,
                    "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}

        asset_doc = {
            "schema": 1, "tier": "LIGHT", "application_id": "io.godstone.app",
            "status": "approved", "production_ready": True,
            "archive_manifest": "signed/archive_light.json",
            "archive_trust_store": "signing/trust.json",
            "assets": [
                {"role": "archive", "name": "archive_light.db",
                 "source": "payload/archive_light.db", **dig("archive_light.db")},
                {"role": "generation_model", "name": "generation.gguf",
                 "source": "payload/generation.gguf", **dig("generation.gguf")},
                {"role": "embedding_model", "name": "embedding.gguf",
                 "source": "payload/embedding.gguf", **dig("embedding.gguf")},
            ],
        }
        doc = self.root / "release.json"
        doc.write_bytes(rg.canonical_json(asset_doc) + b"\n")
        data, staged = prep.validate(doc)
        self.assertEqual({name for _, name in staged},
                         {"archive_light.db", "generation.gguf",
                          "embedding.gguf"})
        # the absence felt: an empty approvals home refuseth the build
        emptied = self.root / "approvals-empty"
        emptied.mkdir()
        elsewhere = self.root / "dist2" / "archive_light.db"
        with self.assertRaises(ba.ArchiveApprovalError) as caught:
            ba.build("LIGHT", elsewhere, embed=False, release=True,
                     seed_root=self.seed, db_dir=DB_DIR,
                     manifests_root=self.manifests,
                     evidence_root=self.evidence, today=TODAY,
                     approvals_dir=emptied,
                     reviewer_keyset=self.trust_home / "reviewer_keys.json")
        self.assertRegex(str(caught.exception), "no approvals bundle")
        self.assertFalse(elsewhere.exists(),
                         "the refused build staged something anyway")


class W11Nonempty(ApprovalCourtCase):
    def testNonemptySignatureIsNotApproval(self) -> None:
        """The card's first named corruption: he that checketh only that
        approval_signature be nonempty proveth the ink, not the deed.
        A transplant of seals -- the proof that it is verification and
        not the length of the string that admitteth."""
        self.sign_all()
        self.assertTrue(self.build_with_leg().validation.ok)
        bundle_a = self.approvals / "T46-FIXTURE-a.approvals.json"
        bundle_b = self.approvals / "T46-FIXTURE-b.approvals.json"
        doc_a = json.loads(bundle_a.read_text(encoding="utf-8"))
        doc_b = json.loads(bundle_b.read_text(encoding="utf-8"))
        sig_a = doc_a["approvals"][0]["signature"]
        sig_b = doc_b["approvals"][0]["signature"]
        self.assertNotEqual(sig_a, sig_b)
        self.assertTrue(sig_a and sig_b, "the test proves nonempty by itself")
        # transplant: each record wears the other's seal -- both well
        # formed, both nonempty, both base64 -- and both are refused
        doc_a["approvals"][0]["signature"] = sig_b
        doc_b["approvals"][0]["signature"] = sig_a
        bundle_a.write_bytes(rg.canonical_json(doc_a) + b"\n")
        bundle_b.write_bytes(rg.canonical_json(doc_b) + b"\n")
        with self.assertRaises(ReleaseGateError) as caught:
            self.verify_one("a")
        self.assertRegex(str(caught.exception), "signature is invalid")
        with self.assertRaises(ReleaseGateError) as caught:
            self.verify_one("b")
        self.assertRegex(str(caught.exception), "signature is invalid")
        # and the very same records, re-sealed aright, give proof again
        self.sign_all()
        coverage = self.verify_one("a")
        self.assertEqual(coverage.chunk_approved, coverage.chunk_total)
        # the whole build feeleth the same fault
        self.sign_all()
        doc_a = json.loads(bundle_a.read_text(encoding="utf-8"))
        doc_a["approvals"][0]["signature"] = hashlib.sha256(
            b"nonempty is not approved").hexdigest()   # a long, plausible string
        bundle_a.write_bytes(rg.canonical_json(doc_a) + b"\n")
        self.sentinel()
        with self.assertRaises(ba.ArchiveApprovalError):
            self.build_with_leg()
        self.assertEqual(self.out.read_bytes(), b"SENTINEL-OLD-BYTES")
        self.no_residue(self.out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
