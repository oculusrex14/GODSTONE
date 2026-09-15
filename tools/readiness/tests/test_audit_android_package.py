#! /usr/bin/env python3
"""GS-PACKAGE-002 — the Android AAB inspector must INSPECT its native payload.

The audit's Android arms, moved into the GREEN lane by the repair that made them pass, with their
assertions and their FIXTURE taken VERBATIM from the adopted probe suite (the subclass inherits
the audit's own judge()/bundle builders and the synthetic ELF helper).
"""
from __future__ import annotations

import json
import os
import sys
import unittest
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from scripts import inspect_android_release as A  # noqa: E402
from tools.readiness.audit_probes.test_audit_artifacts import AndroidTests  # noqa: E402


class AndroidArtifactCourt(AndroidTests):
    """The audit's Android arms, verbatim."""

    def test_valid_apk_control(self): self.assertEqual(self.judge()['verdict'],'PASS')

    def test_corrupt_aab_native_library_fails(self):
     aab=self.root/'bad.aab'
     with zipfile.ZipFile(aab,'w') as z:
      z.writestr('base/lib/arm64-v8a/libgodstone_sqlite.so',b'NOT-ELF')
      z.writestr('base/lib/arm64-v8a/libgodstone_core.so',b'NOT-ELF')
     report=self.judge(aab=aab)
     print('OBS corrupt AAB:',json.dumps({'verdict':report['verdict'],'AAB':report['AAB']}))
     self.assertEqual(report['verdict'],'FAIL','AAB receives PASS although both native libraries are not ELF images')

    def test_partial_aab_library_set_fails(self):
     aab=self.root/'partial.aab'
     with zipfile.ZipFile(aab,'w') as z: z.writestr('base/lib/arm64-v8a/libgodstone_core.so',A._synthetic_elf(16384))
     report=self.judge(aab=aab)
     self.assertEqual(report['verdict'],'FAIL','AAB lacks SQLite library but APK carries it: checking only presence of arm64 is insufficient')

    if __name__=='__main__': unittest.main(verbosity=2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
