#! /usr/bin/env python3
"""GS-PACKAGE-001 — the iOS artifact inspector must REFUSE prohibited SIGNED entitlements and
non-iOS binaries.

The audit's iOS arms, moved into the GREEN lane by the repair that made them pass, with their
assertions and their FIXTURE taken VERBATIM from the adopted probe suite (the subclass inherits
the audit's own bundle() fixture and its OS boundary mock).
"""
from __future__ import annotations

import json
import os
import struct
import sys
import unittest
from unittest.mock import patch

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from scripts import inspect_ios_artifacts as I  # noqa: E402
from tools.readiness.audit_probes.test_audit_artifacts import IosTests  # noqa: E402


class IosArtifactCourt(IosTests):
    """The audit's iOS arms, verbatim."""

    def test_valid_source_bundle_control(self):
     with patch.object(I,'_signature_entitlements',return_value=None): report=I.inspect(self.bundle())
     self.assertEqual(report['verdict'],'PASS');self.assertEqual(report['classification'],'source-only-exclusion')

    def test_forbidden_actual_entitlements_fail(self):
     # The mock is only the codesign OS boundary; inspector policy is actual source.
     with patch.object(I,'_signature_entitlements',return_value={'get-task-allow':True, I.FORBIDDEN_ENTITLEMENT_KEYS[0]:True}): report=I.inspect(self.bundle())
     print('OBS signed entitlement:',json.dumps({'verdict':report['verdict'],'entitlements':report['entitlements']}))
     self.assertEqual(report['verdict'],'FAIL','forbidden actual signing entitlement is recorded without failing policy')

    def test_arm64_macos_binary_fails_ios_inspection(self):
     bundle=self.bundle();path=bundle/'Fixture';blob=bytearray(path.read_bytes());struct.pack_into('<I',blob,64,1);path.write_bytes(blob)
     with patch.object(I,'_signature_entitlements',return_value=None): report=I.inspect(bundle)
     print('OBS foreign platform:',json.dumps({'verdict':report['verdict'],'architectures':report['architectures']}))
     self.assertEqual(report['verdict'],'FAIL','arm64 macOS Mach-O accepted as an iPhoneOS application')


if __name__ == "__main__":
    unittest.main(verbosity=2)
