#! /usr/bin/env python3
"""RED probe (NOT in a lane): the operator-staging pair carrieth NO journal.

AUDIT-004, GS-CONTENT-002 step 4: "Use the same publication owner for build and operator
staging, including approved manifest/evaluation receipts. Do not leave a second pair-of-renames
implementation behind."

`scripts/prepare_release_assets.py::publish_verified` replaceth its ARCHIVE and its APPROVED
MANIFEST with TWO INDEPENDENT `os.replace` calls (lines 536 and 548 of that file), with no
journal, no commit states and no recovery consumer -- while `build_archive.publish_pair` has all
three. A crash between those two replacements therefore leaveth an approved manifest describing
bytes that are not there, and NOTHING can resolve it. This probe killleth a REAL process at the
manifest's own replacement and then asks the SHARED recovery consumer (`build_archive.
recover_publication`, which the build face already calleth) to resolve the pair.

THIS ARM LIVES OUTSIDE THE CANONICAL LANE ON PURPOSE: it is RED on the current product, and the
lanes must never be red. It is a canonical-suite candidate for the round that repairs the second
pair-of-renames; run it with:

    python3 tools/readiness/audit_probes/python/audit004_operator_pair_probe.py

(It inheriteth the canonical court's fixtures, so run it AS A SCRIPT: its __main__ loadeth ONLY
the named probe method. `-m unittest <module>` would load the whole inherited suite.)

WHY IT IS NOT YET REPAIRED, MEASURED AND STATED PLAINLY: routing the staging pair through the
shared journal was IMPLEMENTED and WITHDRAWN BEFORE COMMIT (round 102), because the journal and
the rollback directory land INSIDE the operator output directory, which `stage()` enumerateth
exactly and which the T77 rehearsal court asserteth at EVERY publication boundary. That collision
produced 5 failures and 6 errors in the readiness lane and 1 error in the content lane. The
repair needs those courts' expectations updated together with the journal's location -- a whole
round, not a tail-end change.
"""
from __future__ import annotations

import contextlib
import hashlib
import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import unittest

REPO = pathlib.Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO))

from content.ingest import build_archive as archive_module          # noqa: E402
from content.tests.test_prepare_release_assets import ReleaseAssetTests  # noqa: E402
from scripts import prepare_release_assets as assets                # noqa: E402


class OperatorPairProbeTest(ReleaseAssetTests):
    """Only the explicitly named method below is loaded by __main__."""

    def pair_is_consistent(self):
        manifest = json.loads((self.output / assets.APPROVED_MANIFEST_NAME).read_text())
        actual = hashlib.sha256((self.output / "archive_light.db").read_bytes()).hexdigest()
        return manifest["assets"][0]["sha256"] == actual

    def test_the_operator_pair_is_resolvable_after_a_real_process_death(self):
        self.stage()
        self.assertTrue(self.pair_is_consistent(), "the fixture's first pair is already mixed")
        with contextlib.closing(sqlite3.connect(self.archive)) as db, db:
            db.execute("UPDATE archive_meta SET value=? WHERE key='corpus_sha256'", ("9" * 64,))
        self.refresh()
        old = (self.output / "archive_light.db").read_bytes()
        child = (
            "import os,sys\n"
            "from pathlib import Path\n"
            "from scripts import prepare_release_assets as prep\n"
            "_real = os.replace\n"
            "def guarded(src, dst):\n"
            "    if Path(dst).name == prep.APPROVED_MANIFEST_NAME:\n"
            "        os._exit(87)\n"
            "    return _real(src, dst)\n"
            "os.replace = guarded\n"
            "prep.stage(Path(sys.argv[1]), Path(sys.argv[2]), trust_store_path=Path(sys.argv[3]))\n")
        env = dict(os.environ, PYTHONPATH=str(REPO), PYTHONDONTWRITEBYTECODE="1")
        proc = subprocess.run(
            [sys.executable, "-c", child, str(self.manifest), str(self.output), str(self.trust)],
            cwd=str(REPO), env=env, capture_output=True, text=True, timeout=90)
        self.assertEqual(87, proc.returncode, proc.stdout + proc.stderr)
        self.assertNotEqual(old, (self.output / "archive_light.db").read_bytes(),
                            "the probe never reached the archive's replacement")
        archive_module.recover_publication(self.output / "archive_light.db")
        self.assertTrue(
            self.pair_is_consistent(),
            "after a real process death between the two replacements the operator pair is MIXED: "
            "the approved manifest describeth bytes that are not there, and no journal existeth "
            "for the staging pair -- a second pair-of-renames with no recovery consumer")


if __name__ == "__main__":
    suite = unittest.TestSuite()
    suite.addTests([OperatorPairProbeTest("test_the_operator_pair_is_resolvable_after_a_real_process_death")])
    raise SystemExit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
