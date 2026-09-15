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

AUDIT-004 (the independent review of the first GS-CONTENT-002 submission) reproduced a MIXED PAIR
that survived a REAL PROCESS DEATH, and it is adopted below with its assertions INTACT:

  W06 an `os._exit(87)` between the database's promotion and its receipt's write leaveth the new
      database beside the OLD receipt, and the public reader `read_sidecar` -- called with NO
      archive argument, exactly as the audit called it -- returned the STALE receipt. The pair
      must be RESOLVED before any reader proceeds: the journal is now consumed, and the retained
      complete previous generation is restored.
  W07 THE POSITIVE CONTROL for that arm: an UNDISTURBED build still publishes a matching pair and
      the reader still accepts it, so W06's demand cannot be satisfied by refusing everything.
  W08 the reader may not SILENTLY skip the pair check: `read_sidecar` deriveth the archive from
      the receipt's own name when no archive is furnished, so "archive=None" is no longer a way
      to read a stale receipt unchallenged.
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


    def test_w06_a_real_process_death_cannot_expose_a_mixed_pair(self):
        """THE AUDIT'S OWN PROBE, INTACT -- a REAL process exit, not a catchable exception.

        The child replaces the database and then dies at the receipt-write boundary with
        `os._exit(87)`, so NO handler of ours can run: that is the point. The parent then calls
        the PUBLIC reader with NO archive argument, exactly as the audit did, and demands that
        it never hand back a receipt describing bytes that are no longer there.
        """
        first = self.ordinary_build()
        old_sidecar = json.loads(self.sidecar().read_text(encoding="utf-8"))
        source = self.seed / "docs" / "a.md"
        source.write_text(source.read_text().replace("two seconds", "three seconds"))
        child = (
            "import os,sys\n"
            "from pathlib import Path\n"
            "from content.ingest import build_archive as ba\n"
            "ba.write_sidecar=lambda *a,**k:os._exit(87)\n"
            "ba.build('LIGHT',Path(sys.argv[1]),embed=False,seed_root=Path(sys.argv[2]),"
            "db_dir=Path(sys.argv[3]))\n")
        env = dict(os.environ, PYTHONPATH=str(ROOT), PYTHONDONTWRITEBYTECODE="1")
        proc = subprocess.run(
            [sys.executable, "-c", child, str(self.out), str(self.seed), str(DB_DIR)],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=90)
        self.assertEqual(87, proc.returncode, proc.stdout + proc.stderr)
        self.assertTrue(ba._journal_path(self.out).exists(),
                        "the crash fixture must have reached the prepared journal")
        # THE PUBLIC READER, with NO archive argument: it must not accept a stale receipt
        receipt = ba.read_sidecar(self.sidecar())
        actual = ba._sha256_file(self.out)
        self.assertEqual(receipt["archive_sha256"], actual,
                         "restart reader accepted the old receipt beside the newly published "
                         "database after a real process death")
        self.assertEqual(receipt["archive_bytes"], self.out.stat().st_size)
        # ... and the pair it handed back is the COMPLETE PREVIOUS GENERATION, not a mixture
        self.assertEqual(receipt["archive_sha256"], old_sidecar["archive_sha256"],
                         "the resolved pair must be one COMPLETE generation, old or new")

    def test_w07_an_undisturbed_build_still_publishes_a_readable_pair(self):
        """THE POSITIVE CONTROL: the refusal W06 demandeth must not come from a reader that
        could never accept anything."""
        result = self.ordinary_build()
        receipt = ba.read_sidecar(self.sidecar())
        self.assertEqual(receipt["archive_sha256"], result.archive_sha256)
        self.assertEqual(receipt["archive_bytes"], self.out.stat().st_size)

    def test_w08_the_reader_deriveth_the_archive_from_the_receipts_own_name(self):
        """`archive=None` may not be a way to read a stale receipt unchallenged."""
        self.ordinary_build()
        record = json.loads(self.sidecar().read_text(encoding="utf-8"))
        record["archive_sha256"] = "0" * 64
        self.sidecar().write_text(json.dumps(record), encoding="utf-8")
        with self.assertRaises(ba.ArchiveBuildError) as caught:
            ba.read_sidecar(self.sidecar())      # NO archive argument at all
        self.assertIn("MISMATCHED", str(caught.exception))

    # -- GS-CONTENT-002 step 5: DURABILITY (AUDIT-004) --------------------------------
    # "Fsync required staged/backup/journal files and directory transitions in the correct
    # order. Required durability failures must propagate; do not swallow them and report
    # success. Handle a failed journal-finalization write without leaving success/failure
    # ambiguity." Each arm below injects ONE refusal at a durability boundary and demands a
    # BEHAVIOURAL outcome, never a spelling.

    def _directory_fsync_guard(self):
        """fsync that REFUSES for a DIRECTORY fd and behaves normally for a file fd.

        The refusal is aimed at the exact boundary the card nameth, so an arm cannot pass
        merely because some unrelated fsync failed anywhere in the process.
        """
        import stat as _stat
        real = os.fsync

        def guarded(fd):
            if _stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError("audit: directory fsync refused")
            return real(fd)
        return guarded

    def test_w09_a_required_durability_failure_must_propagate(self):
        """A refusal at the durability boundary may not be SWALLOWED and reported as success."""
        with patch.object(ba.os, "fsync", side_effect=OSError("audit: fsync refused")):
            with self.assertRaises(OSError):
                ba._fsync_directory(self.out.parent)

    def test_w10_a_refused_durability_boundary_leaveth_the_destination_untouched(self):
        """The ROLLBACK TARGET and the JOURNAL must be durable BEFORE the destructive
        promotion: if that boundary is refused, the publication must not proceed to replace
        the very bytes it could no longer roll back to."""
        self.ordinary_build()
        before = self.out.read_bytes()
        source = self.seed / "docs" / "a.md"
        source.write_text(source.read_text().replace("two seconds", "three seconds"))
        with patch.object(ba.os, "fsync", self._directory_fsync_guard()):
            with self.assertRaises(OSError):
                self.ordinary_build()
        self.assertEqual(before, self.out.read_bytes(),
                         "a publication whose durability boundary was REFUSED still replaced "
                         "the destination: the rollback target was not durable first")

    def test_w11_a_failed_terminal_journal_write_is_unambiguous_and_recoverable(self):
        """The pair IS published when the TERMINAL journal record fails: the caller must be
        told exactly that -- not handed a bare failure -- and a later reader must still find a
        MATCHING pair. A raw exception here leaveth success/failure AMBIGUOUS."""
        self.ordinary_build()
        source = self.seed / "docs" / "a.md"
        source.write_text(source.read_text().replace("two seconds", "three seconds"))
        real = ba._write_journal
        state = {"terminal_refused": False}

        def refusing(destination, journal_state, previous):
            if journal_state == "published":
                state["terminal_refused"] = True
                raise OSError("audit: terminal journal record refused")
            return real(destination, journal_state, previous)

        raised = None
        with patch.object(ba, "_write_journal", refusing):
            try:
                self.ordinary_build()
            except Exception as exc:          # whatever the product raised: judged below
                raised = exc
            else:
                self.fail("a REFUSED terminal journal write reported SUCCESS")
        self.assertTrue(state["terminal_refused"], "the fixture never reached the terminal record")
        self.assertIsInstance(
            raised, ba.ArchiveBuildError,
            "the failure must be the product's OWN named error, not a bare OSError: %r" % (raised,))
        message = str(raised)
        self.assertIn("published", message,
                      "the error must say that the generation IS published and that only the "
                      "terminal record failed; a bare failure is ambiguous")
        receipt = ba.read_sidecar(self.sidecar())
        self.assertEqual(receipt["archive_sha256"], ba._sha256_file(self.out),
                         "after an ambiguous terminal write the reader must still resolve a "
                         "MATCHING pair")


if __name__ == "__main__":
    unittest.main(verbosity=2)
