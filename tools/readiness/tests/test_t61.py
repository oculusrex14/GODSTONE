#!/usr/bin/env python3
"""T61 readiness court (python isle): the model-provenance authority.

The card's law, one witness each where the rule speaketh -- the twin of
ReadinessT61Test.kt (jvm) and ReadinessT61Tests.swift (island):

  W01  a wrong digest is refused and nothing standeth promoted
  W02  a missing hash field is refused at the register door
  W02b a malformed digest length is refused at the register door
  W03  a mutable branch-head coordinate is refused (the named falsification:
       no coordinate is trusted that is not an immutable commit)
  W04  an absent licence oath is refused
  W05  path traversal is refused at both doors
  W05b a duplicate destination is refused (two ids, one destination)
  W06  a strange architecture is refused
  W07  a truncated container is refused by name though the name and the
       length agree
  W08  a repeated restore is determinist and leaveth no temporary
  W09  the filename and the length alone are not trusted (the card's named
       falsification: the incompatible-model fixture must fail)
  W10  a corrupt standing file is not overwritten by the sworn gate
  W11  a half-pinned register is refused (verify them all or none)
  W12  an UNPINNED lock may not name a verifier
  W13  the strict estate demandeth the native tale
  W14  the legacy estate knoweth not the native block
  W15  a legacy register with an empty native block is tolerated verbatim
  W16  the selftest is ever-living and refuseth all it telleth
  W17  a zero-sized sworn thing is refused
  W18  an unsworn context is refused
  W19  a legacy UNPINNED artifact must not carry a digest
  W20  unknown fields and future schemas are refused
  W21  the fetch is refused while the transport is unarmed
  W22  a native abi must be told by the native tale (the compatibility law)
  W23  the strict reader refuseth duplicate keys, fractional numbers,
       non-finite constants and trailing matter

All judgments run in-process upon the authority's own synthetics
(scripts/model_provenance.py -- _synth_gguf, _synth_artifact, _unsworn_blob,
_synth_lock, _write_lock); the fakes are deterministic; no witness toucheth
the network; no external gate is closed; readiness stayeth false; the
register of the house (docs/packaging/MODELS.lock.json) is read-only here.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
for _lane in (str(ROOT), str(ROOT / "scripts")):
    if _lane not in sys.path:
        sys.path.insert(0, _lane)

import model_provenance as M  # the authority under audit, in-process


class T61ProvenanceCourt(unittest.TestCase):
    """The court of the model-provenance authority, python isle."""

    def setUp(self):
        self._labs = []

    def tearDown(self):
        for lab in self._labs:
            shutil.rmtree(lab, ignore_errors=True)

    def _lab(self):
        home = tempfile.mkdtemp(prefix="t61-court-")
        self._labs.append(home)
        return Path(home)

    def _sworn(self, **over):
        return M._synth_artifact(**over)

    # ------------------------------------------------------------------ W01
    def test_w01_wrong_digest_is_refused_and_nothing_standeth_promoted(self):
        art, good = self._sworn()
        foul = bytearray(good)
        foul[len(foul) - 5] ^= 0x2A          # inside the last offset field
        dest = self._lab()
        with self.assertRaises(M.ProvenanceError):
            M.restore(art, bytes(foul), dest)
        self.assertFalse((dest / art.output_file).exists())
        self._no_parts(dest)

    def _no_parts(self, dest):
        for name in os.listdir(str(dest)):
            self.assertNotIn(".part", name)

    # ------------------------------------------------------------------ W02
    def test_w02_missing_hash_field_is_refused_at_the_register_door(self):
        rows = {k: v for k, v in M._unsworn_blob().items() if k != "sha256"}
        doc = M._synth_lock(status="UNPINNED", verified_on=None,
                            verified_by=None, artifacts=[rows])
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(doc))
        self.assertIn("wanteth field", str(ctx.exception))

    # ----------------------------------------------------------------- W02b
    def test_w02b_malformed_digest_length_is_refused_at_the_register_door(self):
        with self.assertRaises(M.ProvenanceError) as ctx:
            self._sworn(sha256="b" * 65)
        self.assertIn("64-character", str(ctx.exception))

    # ------------------------------------------------------------------ W03
    def test_w03_mutable_branch_head_coordinate_is_refused(self):
        with self.assertRaises(M.ProvenanceError) as ctx:
            self._sworn(source_commit="main")
        self.assertIn("source_commit", str(ctx.exception))

    # ------------------------------------------------------------------ W04
    def test_w04_absent_licence_oath_is_refused(self):
        with self.assertRaises(M.ProvenanceError) as ctx:
            self._sworn(license=None)
        self.assertIn("license", str(ctx.exception))

    # ------------------------------------------------------------------ W05
    def test_w05_path_traversal_is_refused_at_both_doors(self):
        with self.assertRaises(M.ProvenanceError) as ctx:
            self._sworn(output_file="../evil.gguf")
        self.assertIn("output_file", str(ctx.exception))
        with self.assertRaises(M.ProvenanceError) as ctx:
            self._sworn(source_file="deep/down/Synth.gguf")
        self.assertIn("source_file", str(ctx.exception))

    # ----------------------------------------------------------------- W05b
    def test_w05b_duplicate_destination_is_refused(self):
        first = self._sworn(id="generation-first")[0].asdict()
        twin = self._sworn(id="generation-second")[0].asdict()
        doc = M._synth_lock(artifacts=[first, twin])
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(doc))
        self.assertIn("duplicate output_file", str(ctx.exception))

    # ------------------------------------------------------------------ W06
    def test_w07b_duplicate_identifier_is_refused(self):
        twin = self._sworn()[0].asdict()
        doc = M._synth_lock(artifacts=[dict(twin), dict(twin)])
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(doc))
        self.assertIn("duplicate artifact id", str(ctx.exception))

    def test_w06_strange_architecture_is_refused(self):
        with self.assertRaises(M.ProvenanceError) as ctx:
            self._sworn(native_abi="riscv-9")
        self.assertIn("native_abi", str(ctx.exception))

    # ------------------------------------------------------------------ W07
    def test_w07_truncated_container_is_refused_though_name_and_length_agree(self):
        art, good = self._sworn()
        trunc = good[:-20]
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.gguf_verify(trunc)
        self.assertIn("truncated", str(ctx.exception))
        cries = M.verify_content_addressed(art, trunc)
        self.assertTrue(any("truncated" in cry for cry in cries),
                        "the header cry was silent: " + repr(cries))

    # ------------------------------------------------------------------ W08
    def test_w08_repeated_restore_is_determinist_and_leaveth_no_temporary(self):
        art, good = self._sworn()
        dest = self._lab()
        first = M.restore(art, good, dest)
        second = M.restore(art, good, dest)
        self.assertEqual("promoted", first["action"])
        self.assertEqual("reused", second["action"])
        self.assertEqual(first["path"], second["path"])
        self.assertEqual(first["digest"], second["digest"])
        self.assertEqual(hashlib.sha256(good).hexdigest(), first["digest"])
        standing = (dest / art.output_file).read_bytes()
        self.assertEqual(good, standing)
        self._no_parts(dest)

    # ------------------------------------------------------------------ W09
    def test_w09_name_and_length_alone_are_not_trusted(self):
        art, good = self._sworn()
        foul = bytearray(good)
        foul[len(foul) - 5] ^= 0x2A
        foul = bytes(foul)
        self.assertEqual(len(good), len(foul))
        cries = M.verify_content_addressed(art, foul)
        self.assertEqual(1, len(cries))
        self.assertIn("digest", cries[0])
        dest = self._lab()
        with self.assertRaises(M.ProvenanceError):
            M.restore(art, foul, dest)
        self.assertFalse((dest / art.output_file).exists())

    # ------------------------------------------------------------------ W10
    def test_w10_corrupt_standing_file_is_not_overwritten_by_the_sworn_gate(self):
        art, good = self._sworn()
        foul = bytearray(good)
        foul[len(foul) - 5] ^= 0x2A
        dest = self._lab()
        standing = dest / art.output_file
        standing.write_bytes(bytes(foul))
        with self.assertRaises(M.ProvenanceError):
            M.restore(art, good, dest)
        self.assertEqual(bytes(foul), standing.read_bytes())

    # ------------------------------------------------------------------ W11
    def test_w11_half_pinned_register_is_refused(self):
        rows = M._unsworn_blob(sha256="b" * 64, size_bytes=7)
        doc = M._synth_lock(status="UNPINNED", verified_on=None,
                            verified_by=None, artifacts=[rows])
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(doc))
        self.assertIn("verify them all or none", str(ctx.exception))

    # ------------------------------------------------------------------ W12
    def test_w12_unpinned_lock_may_not_name_a_verifier(self):
        doc = M._synth_lock(status="UNPINNED", verified_on="yesterday",
                            verified_by="the eye",
                            artifacts=[M._unsworn_blob()])
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(doc))
        self.assertIn("must not name a verifier", str(ctx.exception))

    # ------------------------------------------------------------------ W13
    def test_w13_strict_estate_demands_the_native_tale(self):
        doc = M._synth_lock(artifacts=[M._unsworn_blob()])
        doc.pop("native", None)
        doc["status"] = "UNPINNED"
        doc["verified_on"] = None
        doc["verified_by"] = None
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(doc))
        self.assertIn("wanteth field", str(ctx.exception))

    # ------------------------------------------------------------------ W14
    def test_w14_legacy_estate_knoweth_not_the_native_block(self):
        doc = M._synth_lock(schema=1, status="UNPINNED", verified_on=None,
                            verified_by=None,
                            artifacts=[{"id": "legacy-art", "tiers": ["LIGHT"],
                                       "repo": "court/synths",
                                       "source_file": "Legacy.gguf",
                                       "output_file": "legacy.gguf"}],
                            native={"abis": ["arm64-v8a"]})
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(doc))
        self.assertIn("knoweth no native block", str(ctx.exception))

    # ------------------------------------------------------------------ W15
    def test_w15_legacy_empty_native_is_tolerated_verbatim(self):
        doc = M._synth_lock(schema=1, status="UNPINNED", verified_on=None,
                            verified_by=None,
                            artifacts=[{"id": "legacy-art", "tiers": ["LIGHT"],
                                        "repo": "court/synths",
                                        "source_file": "Legacy.gguf",
                                        "output_file": "legacy.gguf"}],
                            native={})
        lock = M.ModelLockV1.load(M._write_lock(doc))
        self.assertEqual(1, len(lock.blobs))
        with self.assertRaises(M.ProvenanceError):
            lock.select_for_tier("ALL")

    # ------------------------------------------------------------------ W16
    def test_w16_the_selftest_refuseth_all_it_telleth(self):
        self.assertEqual(0, M._selftest())

    # ------------------------------------------------------------------ W17
    def test_w17_zero_sized_sworn_thing_is_refused(self):
        with self.assertRaises(M.ProvenanceError) as ctx:
            self._sworn(size_bytes=0)
        self.assertIn("positive integer", str(ctx.exception))

    # ------------------------------------------------------------------ W18
    def test_w18_unsworn_context_is_refused(self):
        with self.assertRaises(M.ProvenanceError) as ctx:
            self._sworn(context_tokens=0)
        self.assertIn("positive integer", str(ctx.exception))

    # ------------------------------------------------------------------ W19
    def test_w19_legacy_digests_must_stand_null(self):
        # the authority''s own words, carried verbatim by both twins: an
        # UNPINNED legacy loc may not carry a digest at all
        lawful = {"id": "legacy-art", "tiers": ["LIGHT"], "repo": "court/synths",
                  "source_file": "Legacy.gguf", "output_file": "legacy.gguf"}
        doc = M._synth_lock(schema=1, status="UNPINNED", verified_on=None,
                            verified_by=None, native=None, artifacts=[dict(lawful)])
        lock = M.ModelLockV1.load(M._write_lock(doc))
        self.assertEqual(1, len(lock.blobs))
        sworn = dict(lawful)
        sworn["sha256"] = "b" * 64
        doc = M._synth_lock(schema=1, status="UNPINNED", verified_on=None,
                            verified_by=None, native=None, artifacts=[sworn])
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(doc))
        self.assertIn("must keep sha256 null", str(ctx.exception))
        hollow = dict(lawful)
        hollow["sha256"] = None
        doc = M._synth_lock(schema=1, status="UNPINNED", verified_on=None,
                            verified_by=None, native=None, artifacts=[hollow])
        self.assertEqual(1, len(M.ModelLockV1.load(M._write_lock(doc)).blobs))

    def test_w20_unknown_fields_and_future_schemas_are_refused(self):
        art, _good = self._sworn()
        surcharged = art.asdict()
        surcharged["surcharge"] = True
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(M._synth_lock(artifacts=[surcharged])))
        self.assertIn("unknown field", str(ctx.exception))
        future = M._synth_lock(artifacts=[art.asdict()])
        future["schema"] = 3
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(future))
        self.assertIn("unsupported model-lock schema", str(ctx.exception))
        extra = M._synth_lock(artifacts=[art.asdict()])
        extra["orbits"] = "moon"
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(extra))
        self.assertIn("unknown top-level field", str(ctx.exception))

    # ------------------------------------------------------------------ W21
    def test_w21_the_fetch_preferreth_the_armed_transport_over_the_wire(self):
        art, good = self._sworn()
        lab = self._lab()
        mirror = lab / "transport"
        mirror.mkdir()
        (mirror / art.output_file).write_bytes(good)
        spoken = []

        def _opener(url, ceiling):
            spoken.append((url, ceiling))
            return good

        verdict = M.fetch(art, lab / "dest", transport_dir=mirror, opener=_opener)
        self.assertEqual("promoted", verdict["action"])
        self.assertEqual([], spoken)                     # the armed transport winneth
        self.assertEqual(good, (lab / "dest" / art.output_file).read_bytes())

        bare = lab / "bare-transport"
        bare.mkdir()
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.fetch(art, lab / "elsewhere", transport_dir=bare, opener=None)
        self.assertIn("transport mirror hath not", str(ctx.exception))

        # the wire is the last resort: boundèd by the sworn size, the immutable
        # commit told verbatim in the url; no witness of this court toucheth it
        recorded = []
        true_read = M._http_read

        def _spy(url, ceiling):
            recorded.append((url, ceiling))
            raise M.ProvenanceError("the wire is cold")

        M._http_read = _spy
        try:
            with self.assertRaises(M.ProvenanceError) as ctx:
                M.fetch(art, lab / "via-network")
        finally:
            M._http_read = true_read
        self.assertEqual(1, len(recorded))
        url, ceiling = recorded[0]
        self.assertTrue(url.startswith("https://"))
        self.assertIn("/resolve/" + art.source_commit + "/", url)
        self.assertEqual(art.size_bytes, ceiling)
        self.assertIn("the wire is cold", str(ctx.exception))

    def test_w22_native_abi_must_be_told_by_the_native_tale(self):
        off_tale = self._sworn(native_abi="x86-64")[0].asdict()
        doc = M._synth_lock(artifacts=[off_tale])
        with self.assertRaises(M.ProvenanceError) as ctx:
            M.ModelLockV1.load(M._write_lock(doc))
        self.assertIn("is not compatible", str(ctx.exception))

    # ------------------------------------------------------------------ W23
    def test_w23_the_strict_reader_refuseth_malformed_documents(self):
        with self.assertRaises(ValueError) as ctx:
            M._load_strict('{"a": 1, "a": 2}')
        self.assertIn("duplicate key", str(ctx.exception))
        with self.assertRaises(ValueError) as ctx:
            M._load_strict('{"a": 1.5}')
        self.assertIn("hath no place in a strict register", str(ctx.exception))
        with self.assertRaises(ValueError) as ctx:
            M._load_strict('{"a": NaN}')
        self.assertIn("hath no place in a strict register", str(ctx.exception))
        with self.assertRaises(ValueError) as ctx:
            M._load_strict('{"a": 1} trailing matter')
        self.assertTrue(len(str(ctx.exception)) > 0)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
