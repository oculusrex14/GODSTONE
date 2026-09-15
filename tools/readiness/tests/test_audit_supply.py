#! /usr/bin/env python3
"""GS-SUPPLY-001 — the offline cache restore refuseth traversal names and symlink sources.

The audit's FOUR cache arms, moved into the GREEN lane by the repair that made them pass, with
their assertions and their FIXTURE taken VERBATIM from the adopted probe suite (the subclass
inherits the audit's own setUp and manifest helper, so nothing here re-invents its fixture).
"""
from __future__ import annotations

import json
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)

from tools.readiness.audit_probes.test_audit_artifacts import CacheTests  # noqa: E402
from tools.supplychain import supply_chain as S  # noqa: E402  (the arms name it directly)


class SupplyRestoreCourt(CacheTests):
    """The four audit cache arms, verbatim."""

    def test_valid_cache_restore(self):
     source=self.root/'source';source.mkdir();blob=b'audit synthetic wheel bytes';(source/'safe.whl').write_bytes(blob)
     S.restore(self.manifest('safe.whl',blob),source,self.root/'dest')
     self.assertEqual((self.root/'dest/safe.whl').read_bytes(),blob)

    def test_changed_bytes_refused_before_restore(self):
     source=self.root/'source';source.mkdir();(source/'safe.whl').write_bytes(b'changed')
     with self.assertRaises(S.SupplyChainError): S.restore(self.manifest('safe.whl',b'original'),source,self.root/'dest')
     self.assertFalse((self.root/'dest').exists())

    def test_parent_traversal_refused_before_outside_write(self):
     source=self.root/'source/cache';source.mkdir(parents=True);target=self.root/'target/cache';target.parent.mkdir()
     blob=b'LOCAL-ONLY-TRAVERSAL-SENTINEL';(source.parent/'escape.whl').write_bytes(blob)
     rejected=False
     try: S.restore(self.manifest('../escape.whl',blob),source,target)
     except S.SupplyChainError: rejected=True
     outside=target.parent/'escape.whl'
     print('OBS cache traversal:',json.dumps({'rejected':rejected,'wrote_outside_destination':outside.exists()}))
     self.assertTrue(rejected,'parent traversal accepted; wrote outside the requested destination')
     self.assertFalse(outside.exists())

    def test_source_symlink_refused_before_restore(self):
     source=self.root/'source';source.mkdir();blob=b'LOCAL-ONLY-SYMLINK';(self.root/'outside.whl').write_bytes(blob);(source/'safe.whl').symlink_to(self.root/'outside.whl')
     with self.assertRaises(S.SupplyChainError): S.restore(self.manifest('safe.whl',blob),source,self.root/'dest')


if __name__ == "__main__":
    unittest.main(verbosity=2)
