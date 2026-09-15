#! /usr/bin/env python3
"""GS-CONTENT-002 — the archive bytes and their receipt are published as ONE generation.

The audit's two independent probes (evidence/AUDIT-002/content/audit_content_tests.py) are
moved into the canonical suite with their assertions INTACT:

  W01 `test_sidecar_io_failure_must_preserve_previous_archive_and_receipt`: an I/O failure
      while writing the receipt must leave the PREVIOUS PAIR untouched -- the audit
      reproduced a replaced database beside a surviving old receipt
  W02 `test_interleaved_promotion_must_keep_receipt_bound_to_own_database`: a second build
      starting exactly after the first publishes must not produce a receipt combining one
      build's corpus identity with the other's bytes
  W03 the RECEIPT is bound to its OWN bytes: the reader REFUSES a mismatched pair
  W04 THE POSITIVE CONTROL: a successful build publishes a matching pair, and the receipt
      is computed from the operation's own staged bytes (never re-read from the destination)
  W05 the protocol is SERIALIZED ACROSS PROCESSES (an interprocess lock), journalled, and
      fsynced -- a process-wide threading lock cannot protect a parallel CLI invocation
"""
from __future__ import annotations

import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools" / "readiness"))

from content.ingest import build_archive as ba            # noqa: E402
from tools.readiness.tests.test_t46 import TODAY, DB_DIR  # noqa: E402
from tools.readiness.tests.test_t46 import ApprovalCourtCase  # noqa: E402


class PublicationPairTest(ApprovalCourtCase):
    """W01-W05: the pair is one generation, or the previous pair stands."""

    def ordinary_build(self, **kwargs):
        kwargs.setdefault("seed_root", self.seed)
        kwargs.setdefault("db_dir", DB_DIR)
        return ba.build("LIGHT", self.out, embed=False, **kwargs)

    def sidecar(self):
        return pathlib.Path(str(self.out) + ba.SIDECAR_SUFFIX)

    def test_w01_a_receipt_failure_preserves_the_previous_pair(self):
        """THE AUDIT'S ASSERTION, INTACT."""
        self.ordinary_build()
        old_archive = self.out.read_bytes()
        old_sidecar = self.sidecar().read_bytes()
        source = self.seed / "docs" / "a.md"
        source.write_text(source.read_text().replace("two seconds", "three seconds"))
        with patch.object(ba, "write_sidecar", side_effect=OSError("audit disk full")):
            with self.assertRaises(OSError):
                self.ordinary_build()
        self.assertEqual(self.out.read_bytes(), old_archive,
                         "Failed build replaced the previous archive")
        self.assertEqual(self.sidecar().read_bytes(), old_sidecar,
                         "Failed build replaced the previous receipt")

    def test_w02_an_interleaved_promotion_keeps_the_receipt_bound_to_its_own_bytes(self):
        """THE AUDIT'S SCHEDULE, INTACT: B starts exactly after A publishes."""
        nested = []

        def hook(stage):
            if stage == "after_publish":
                source = self.seed / "docs" / "a.md"
                source.write_text(source.read_text().replace("two seconds", "three seconds"))
                nested.append(self.ordinary_build())

        first = self.ordinary_build(fault_hook=hook)
        self.assertNotEqual(first.corpus_sha256, nested[0].corpus_sha256)
        with sqlite3.connect(self.out) as connection:
            actual = dict(connection.execute("SELECT key, value FROM archive_meta"))
        receipt = ba.read_sidecar(self.sidecar())
        self.assertEqual(receipt["corpus_sha256"], actual["corpus_sha256"],
                         "Sidecar combines A corpus identity with B archive bytes")
        self.assertNotEqual(first.archive_sha256, nested[0].archive_sha256,
                            "A falsely returns B hash as its own successful build")

    def test_w03_the_reader_refuses_a_mismatched_pair(self):
        self.ordinary_build()
        # the receipt is bound to the bytes beside it
        ba.read_sidecar(self.sidecar(), archive=self.out)
        record = json.loads(self.sidecar().read_text(encoding="utf-8"))
        record["archive_sha256"] = "0" * 64
        self.sidecar().write_text(json.dumps(record), encoding="utf-8")
        with self.assertRaises(ba.ArchiveBuildError) as caught:
            ba.read_sidecar(self.sidecar(), archive=self.out)
        self.assertIn("MISMATCHED", str(caught.exception))

    def test_w04_a_successful_build_publishes_a_matching_pair(self):
        result = self.ordinary_build()
        record = ba.read_sidecar(self.sidecar(), archive=self.out)
        self.assertEqual(record["archive_sha256"], result.archive_sha256)
        self.assertEqual(record["archive_bytes"], self.out.stat().st_size)
        self.assertEqual(record["corpus_sha256"], result.corpus_sha256)
        with sqlite3.connect(self.out) as connection:
            meta = dict(connection.execute("SELECT key, value FROM archive_meta"))
        self.assertEqual(record["corpus_sha256"], meta["corpus_sha256"],
                         "the receipt's identity is the DATABASE's own identity")

    def test_w05_the_protocol_is_interprocess_locked_journalled_and_fsynced(self):
        source = (ROOT / "content" / "ingest" / "build_archive.py").read_text(encoding="utf-8")
        self.assertIn("fcntl.flock", source,
                      "publication must be serialized ACROSS PROCESSES, not merely across "
                      "threads: a process-wide lock cannot protect a parallel CLI invocation")
        self.assertIn("_write_journal", source, "the publication must be journalled")
        self.assertIn("rolled_back", source,
                      "a failure must reach an explicit RECOVERY state")
        self.assertIn("_fsync_directory", source, "the published directory must be fsynced")
        self.assertIn("publish_archive_pair", source,
                      "the database and its receipt must be published as ONE generation")
        # ... and the receipt is never computed by re-reading the shared destination
        self.assertNotIn("final_bytes = destination.read_bytes()", source,
                         "the receipt must be computed from the operation's OWN staged bytes")


if __name__ == "__main__":
    unittest.main(verbosity=2)
