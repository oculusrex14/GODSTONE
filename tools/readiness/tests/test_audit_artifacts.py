"""The audit's FINAL NEGATIVE PROBES, adopted into the canonical suite (waves 3a and 8).

Source: AUDIT_FINAL_2026-09-15/evidence/AUDIT-003/audit_final_negative_tests.py -- the audit's
own 12-case suite. Their assertions are INTACT; only the imports and the repository root are
rebound to this checkout. They are the canonical REDs for:

  GS-SUPPLY-001  offline cache restore accepts traversal names and symlink sources
  GS-DIAG-001    diagnostics retain an unbounded map of historic relation keys
  GS-PACKAGE-001 the iOS artifact inspector accepts prohibited signed entitlements and
                 non-iOS binaries
  GS-PACKAGE-002 the Android artifact inspector validates AAB names but not its native payloads

Synthetic files only, confined to a TemporaryDirectory. No network, signing credentials or real
device is used, and no gate is closed by any of them.
"""
from __future__ import annotations

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if ROOT not in sys.path:
    sys.path.insert(0, ROOT)
import hashlib,json,plistlib,struct,tempfile,unittest,zipfile
from pathlib import Path
from unittest.mock import patch
from tools.supplychain import supply_chain as S
from tools.readiness.diagnostics import Diagnostics,DiagnosticsMode
from scripts import inspect_ios_artifacts as I
from scripts import inspect_android_release as A

class LocalCase(unittest.TestCase):
 def setUp(self):
  self.temp=tempfile.TemporaryDirectory(prefix='godstone-final-negative-')
  self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)

class CacheTests(LocalCase):
 def manifest(self,name,blob):
  return {'schema':S.SCHEMA,'blobs':[{'name':name,'bytes':len(blob),'sha256':hashlib.sha256(blob).hexdigest()}],'restore':{'network':'none'}}
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

class DiagnosticsTests(LocalCase):
 def test_ring_control_remains_bounded(self):
  d=Diagnostics(capacity=16);d.enable()
  for i in range(100): d.count('peers_seen',relation_key='same')
  self.assertEqual(d.ring_size,16);self.assertEqual(len(d._relation_by_key),1)
 def test_unique_peer_churn_does_not_retain_all_dead_relations(self):
  d=Diagnostics(capacity=16);d.enable()
  for i in range(10000): d.count('peers_seen',relation_key=f'audit-peer-{i}')
  print('OBS diagnostics:',json.dumps({'ring':d.ring_size,'retained_relation_keys':len(d._relation_by_key)}))
  self.assertLessEqual(len(d._relation_by_key),16,'drop-oldest ring retains every historic peer key in a second unbounded map')

class IosTests(LocalCase):
 def bundle(self):
  bundle=self.root/'Fixture.app';bundle.mkdir();I._write_synthetic_bundle(bundle);return bundle
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

class AndroidTests(LocalCase):
 def judge(self,**overrides):
  apk=A._write_synthetic_apk(self.root/'fixture.apk',abis=('arm64-v8a',),page_size=16384)
  opts=dict(merged_manifest=A._write_manifest(self.root),rules=A._write_rules(self.root),mapping=A._write_mapping(self.root),dependencies_text='+--- io.godstone:core:1.0\n')
  opts.update(overrides);return A.inspect(apk,**opts)
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
